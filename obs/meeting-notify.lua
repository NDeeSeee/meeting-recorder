-- meeting-notify.lua
--
-- 1. Notifies (banner + sound) when recording starts/stops.
-- 2. Parks OBS on an empty "Idle" scene whenever it is not recording, so OBS
--    stops rendering the screen and macOS calms down about it being shared.
--    Note the scene switch alone does NOT restart the video capture stream —
--    that is what item 5 exists for.
-- 3. Watchdog: if the recording looks abandoned, ask whether to keep going and
--    stop it automatically if nobody answers.
-- 4. Kicks off the transcribe/summarize pipeline. It MUST be spawned from OBS:
--    a launchd agent is blocked by macOS privacy from reading ~/Documents,
--    whereas a child of OBS inherits OBS's folder access.
-- 5. Rebuilds the macOS ScreenCaptureKit streams when they die, which otherwise
--    silently turns every later recording into frozen wallpaper with a digitally
--    silent system-audio track.

local obs = obslua

local ANSWER_FILE   = "/tmp/meeting-watchdog.answer"
local CHECK_EVERY   = 60      -- seconds between watchdog checks
local AWAY_SECS     = 15 * 60 -- keyboard/mouse idle that counts as "walked away"
local MIN_BEFORE    = 20 * 60 -- don't nag during the first stretch of a meeting
local HARD_CAP      = 180* 60 -- prompt regardless once a recording gets this long
local SNOOZE        = 30 * 60 -- after "Keep recording", stay quiet this long
local DIALOG_WAIT   = 180     -- seconds to answer before we assume you're gone
-- Gentle, non-blocking reminders for the case the modal triggers cannot catch:
-- you are still at the keyboard (so not "idle") and the call was in a browser
-- (so no Zoom process to notice quitting) but the meeting ended and you forgot.
-- A notification can never wrongly stop a real meeting, so this is safe to fire.
local REMIND_FIRST  = 60 * 60
local REMIND_EVERY  = 30 * 60

local elapsed       = 0       -- seconds recorded
local quiet_until   = 0       -- suppress prompts until this elapsed value
local prompting     = false
local zoom_at_start = false
local next_remind   = REMIND_FIRST

--------------------------------------------------------------------- helpers

local function sh(cmd)                       -- run a command, return its output
    local p = io.popen(cmd)
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

-- Messages can carry a source name, and the text lands inside an AppleScript
-- double-quoted string inside a shell single-quoted argument. An apostrophe,
-- a quote or a backslash in a source name would close one of those and silently
-- swallow the whole warning — the one failure this design must never have.
local function shq(s)
    local t = tostring(s)
    t = t:gsub("\\", "\\\\")
    t = t:gsub('"', '\\"')
    t = t:gsub("'", "'\\''")
    return t
end

local function notify(title, message, sound)
    os.execute(string.format(
        "/usr/bin/osascript -e 'display notification \"%s\" with title \"%s\" sound name \"%s\"' >/dev/null 2>&1 &",
        shq(message), shq(title), shq(sound)))
    os.execute(string.format(
        "date '+%%Y-%%m-%%d %%H:%%M:%%S' | tr -d '\\n' >> \"$HOME/Library/Logs/meeting-notify.log\"; echo ' %s' >> \"$HOME/Library/Logs/meeting-notify.log\"",
        shq(message)))
end

local function set_scene(name)
    local src = obs.obs_get_source_by_name(name)
    if src ~= nil then
        obs.obs_frontend_set_current_scene(src)
        obs.obs_source_release(src)
    end
end

local function run_pipeline()
    os.execute('/usr/bin/nohup "$HOME/.local/bin/meeting-process" >/dev/null 2>&1 &')
end

local function zoom_running()
    return sh("/usr/bin/pgrep -x zoom.us 2>/dev/null | head -1"):match("%d") ~= nil
end

-- A Bluetooth audio output (e.g. AirPods) makes macOS ScreenCaptureKit record
-- the *participants* as digital silence — only your mic survives. This is the
-- one moment the loss is preventable, so warn with a modal alert (a banner can
-- be missed, and by the time the pipeline notices, the audio is already gone).
local function warn_if_bluetooth_output()
    if sh('"$HOME/.local/bin/audio-output-kind" 2>/dev/null'):match("bluetooth") == nil then
        return
    end
    notify("⚠︎ Bluetooth output",
           "Participants may be recorded as SILENCE — switch output to built-in speakers", "Basso")
    -- Async modal so the OBS thread never blocks; stays up until dismissed.
    os.execute(
        "/usr/bin/osascript -e 'display alert \"Participants will NOT be recorded\" " ..
        "message \"Your audio OUTPUT is plain Bluetooth (e.g. AirPods). macOS records the " ..
        "other participants as silence in this mode. Fix it now: choose your Multi-Output " ..
        "device (AirPods + BlackHole) so capture works while you still hear everyone — or " ..
        "switch output to the built-in speakers. Your microphone can stay on AirPods.\" " ..
        "as critical' >/dev/null 2>&1 &")
end

-- Seconds since the last keyboard/mouse input. Needs no special permissions.
local function idle_seconds()
    local out = sh("/usr/sbin/ioreg -c IOHIDSystem 2>/dev/null | " ..
                   "/usr/bin/awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'")
    return tonumber(out) or 0
end

------------------------------------------------------- screen capture rebuild

-- macOS tears down a ScreenCaptureKit stream mid-session ("Stream stopped as no
-- capture source was not found." and error -3805 in the OBS log; the trigger was
-- never pinned down) and OBS never re-initialises it. The source keeps drawing
-- its last frame forever, so every recording made until OBS is restarted is
-- nothing but frozen wallpaper.
--
-- Switching scenes cannot repair this: the screen_capture plugin registers no
-- show/hide/activate callback at all, so visibility only decides whether the
-- (possibly dead) stream is drawn. The only path from a script down to the
-- plugin's destroy+init code is a settings *change* — an update with unchanged
-- settings is discarded by the plugin's own early-return. So we flip
-- show_cursor and flip it straight back: two real rebuilds, ending on the
-- user's original settings.
--
-- The two writes MUST land on different video frames. obs_source_update defers
-- video sources to the video thread and applies only the merged result, so a
-- flip and a restore issued from the same callback cancel out into a no-op.

-- Deliberately NOT detect-then-repair. The plugin's failure flag (its "Restart
-- Capture" button) clears at the *top* of the re-init path rather than on a
-- delivered frame, so our own failed repair reads back as healthy: the retry
-- never fires again and the alarm silently stands down. Reading it also stalls
-- the graphics thread on a shareable-content enumeration, and the audio source
-- may not expose it at all. So we do not ask whether the stream died — we just
-- rebuild both streams periodically while parked on Idle, and require a real
-- delivered frame as proof. Unconditional refresh has no state to get wrong.
local SCK_VIDEO_ID    = "screen_capture"
local SCK_AUDIO_ID    = "sck_audio_capture"
local SCK_RESTORE_MS  = 400       -- comfortably more than one video frame
local SCK_VERIFY_MS   = 6000      -- SCK needs a moment to deliver a first frame
local SCK_CYCLE_TICKS = 10        -- idle minutes between refreshes
local SCK_STALE_TICKS = 25        -- idle minutes without proof before we warn

local sck_pending   = nil         -- sources awaiting restore + verification
local sck_deferred  = false       -- a restore parked because recording started
local sck_idle_tick = 0           -- idle minutes since the last confirmed frame
local sck_since_try = 0           -- idle minutes since the last refresh attempt
local sck_broken    = false       -- the last refresh produced no frame

-- Both SCK sources, because one stream death kills both: every failure in the
-- logs is a *pair* of stop lines, and the recording that follows has frozen
-- wallpaper AND a digitally silent "Meeting audio" track (measured: -91.0 dB
-- mean and max, versus -26.4 dB on the BlackHole backup that quietly saved the
-- transcripts). Display captures only for video — the window/application variant
-- has no display to lose and reports width 0 forever, which would make the
-- liveness check below cry wolf on every pass.
local function sck_sources()
    local found = {}
    local sources = obs.obs_enum_sources()
    if sources == nil then return found end
    for _, src in ipairs(sources) do
        local id = obs.obs_source_get_id(src)
        if id == SCK_VIDEO_ID then
            local st = obs.obs_source_get_settings(src)
            if obs.obs_data_get_int(st, "type") == 0 then
                found[#found + 1] = {
                    name        = obs.obs_source_get_name(src),
                    video       = true,
                    show_cursor = obs.obs_data_get_bool(st, "show_cursor"),
                }
            end
            obs.obs_data_release(st)
        elseif id == SCK_AUDIO_ID then
            found[#found + 1] = { name = obs.obs_source_get_name(src), video = false }
        end
    end
    obs.source_list_release(sources)
    return found
end

local function sck_set_show_cursor(name, value)
    local src = obs.obs_get_source_by_name(name)
    if src == nil then return end
    -- Partial settings are merged, so display_uuid and friends survive untouched.
    local st = obs.obs_data_create()
    obs.obs_data_set_bool(st, "show_cursor", value)
    obs.obs_source_update(src, st)
    obs.obs_data_release(st)
    obs.obs_source_release(src)
end

-- The audio source has no early-return of its own, so any update at all is
-- already a destroy + init. It is audio-only, so this runs synchronously rather
-- than being deferred to the video thread.
local function sck_touch(name)
    local src = obs.obs_get_source_by_name(name)
    if src == nil then return end
    local st = obs.obs_data_create()
    obs.obs_source_update(src, st)
    obs.obs_data_release(st)
    obs.obs_source_release(src)
end

-- A rebuild resets the source's frame size to zero, and only a frame actually
-- delivered by ScreenCaptureKit makes it non-zero again. So a still-zero width
-- here means the new stream never started — the one case we must never let pass
-- quietly, because the recording would look fine and contain only wallpaper.
-- Only meaningful for video: an audio source has no frame size, and its silence
-- is caught downstream by the pipeline's own empty-track check.
local function sck_verify()
    obs.timer_remove(sck_verify)
    local dead, checked = {}, 0
    for _, s in ipairs(sck_pending or {}) do
        if s.video then
            local src = obs.obs_get_source_by_name(s.name)
            if src ~= nil then
                checked = checked + 1
                if obs.obs_source_get_width(src) == 0 then
                    dead[#dead + 1] = s.name
                end
                obs.obs_source_release(src)
            end
        end
    end
    sck_pending = nil
    if #dead > 0 then
        -- Edge-triggered: the next cycle retries anyway, so repeating the alert
        -- every ten minutes all night would only teach you to ignore it.
        if not sck_broken then
            notify("⚠︎ Screen capture DEAD",
                   string.format("%s is not producing frames — restart OBS or this records wallpaper only",
                                 table.concat(dead, ", ")),
                   "Basso")
        end
        sck_broken = true
    elseif checked > 0 then
        -- A real frame arrived: the only evidence worth clearing the alarm on.
        sck_idle_tick, sck_broken = 0, false
    end
    -- checked == 0 means no display capture is configured at all. Claim nothing:
    -- staleness will speak up on its own rather than us inventing a verdict.
end

local function sck_restore()
    obs.timer_remove(sck_restore)
    -- Never rebuild during a recording: this is a destroy+init on the graphics
    -- thread, and a wedged SCK would hang OBS holding the graphics context and
    -- cost the whole meeting. Wait it out; the inverted cursor flag is cosmetic.
    if obs.obs_frontend_recording_active() then
        obs.timer_add(sck_restore, SCK_RESTORE_MS)
        return
    end
    -- Armed before the restores so an error in them cannot strand sck_pending,
    -- which would silently disable the health check for the rest of the session.
    obs.timer_add(sck_verify, SCK_VERIFY_MS)
    for _, s in ipairs(sck_pending or {}) do
        if s.video then sck_set_show_cursor(s.name, s.show_cursor) end
    end
end

-- Rebuild every SCK source, healthy or not. Cheaper in every sense than asking
-- which one died: no properties enumeration to stall on, no per-source failure
-- flag to be wrong about, and the audio stream gets repaired even though it
-- exposes no failure flag of its own.
local function sck_refresh()
    if sck_pending ~= nil then return end       -- one already in flight
    if obs.obs_frontend_recording_active() then return end
    local srcs = sck_sources()
    if #srcs == 0 then return end
    sck_pending = srcs
    -- Armed before the flips, so an error in them cannot strand sck_pending and
    -- leave show_cursor inverted with nothing scheduled to put it back.
    obs.timer_add(sck_restore, SCK_RESTORE_MS)
    for _, s in ipairs(srcs) do
        if s.video then
            sck_set_show_cursor(s.name, not s.show_cursor)
        else
            sck_touch(s.name)
        end
    end
end

-- Driven by the idle branch of tick(), so these counters advance in idle minutes
-- and not wall-clock. That is deliberate: time spent recording is time we were
-- forbidden to check, and counting it would fire the "capture is dead" alert
-- after every long meeting on a perfectly healthy machine.
local function sck_health_check()
    if sck_pending ~= nil then return end
    sck_idle_tick = sck_idle_tick + 1
    sck_since_try = sck_since_try + 1
    if sck_since_try >= SCK_CYCLE_TICKS then
        sck_since_try = 0
        sck_refresh()
    end
end

-- A dead capture costs the entire visual record — unrecoverable, unlike the
-- Bluetooth case — so it earns the same async critical alert rather than a
-- banner that is easy to miss mid-meeting. "Not confirmed in a long while"
-- counts as suspect too, because silence is exactly how nine meetings were lost.
local function warn_if_capture_dead()
    if not (sck_broken or sck_idle_tick > SCK_STALE_TICKS) then return end
    notify("⚠︎ Screen capture suspect", "Video may be frozen wallpaper — restart OBS", "Basso")
    os.execute(
        "/usr/bin/osascript -e 'display alert \"Screen capture may be dead\" " ..
        "message \"The macOS screen capture stream has stopped and could not be " ..
        "confirmed working. If it is dead, the video of this meeting will be nothing " ..
        "but frozen wallpaper and the Meeting audio track will be silent. The BlackHole " ..
        "backup track still captures the participants, so the transcript survives, but " ..
        "the screen does not. To be safe: stop this recording, quit and reopen OBS, " ..
        "then start again.\" as critical' >/dev/null 2>&1 &")
end

-------------------------------------------------------------------- watchdog

-- Ask asynchronously so the OBS thread never blocks on the dialog.
local function ask(reason, mins)
    os.remove(ANSWER_FILE)
    prompting = true
    local msg = string.format(
        "Still recording (%d min). %s\\n\\nKeep recording, or stop and save now?",
        mins, reason)
    os.execute(string.format(
        "/usr/bin/osascript -e 'display dialog \"%s\" with title \"Meeting recorder\" " ..
        "buttons {\"Stop & save\", \"Keep recording\"} default button \"Keep recording\" " ..
        "with icon caution giving up after %d' > %s 2>&1 &",
        msg, DIALOG_WAIT, ANSWER_FILE))
end

local function read_answer()
    local fh = io.open(ANSWER_FILE, "r")
    if not fh then return nil end
    local s = fh:read("*a") or ""
    fh:close()
    if s == "" then return nil end
    -- No answer within the timeout => you are not at the machine => stop.
    if s:match("gave up:true") then return "stop" end
    if s:match("Stop & save")   then return "stop" end
    if s:match("Keep recording") then return "keep" end
    return nil
end

local function tick()
    if not obs.obs_frontend_recording_active() then
        -- The capture stream dies while OBS sits idle, so the repair has to
        -- happen here, minutes before anyone presses the record hotkey.
        sck_health_check()
        return
    end
    elapsed = elapsed + CHECK_EVERY

    if prompting then
        local ans = read_answer()
        if ans == "stop" then
            prompting = false
            os.remove(ANSWER_FILE)
            notify("■ Auto-stopped", "Recording stopped (no longer in a meeting)", "Submarine")
            obs.obs_frontend_recording_stop()
        elseif ans == "keep" then
            prompting = false
            os.remove(ANSWER_FILE)
            quiet_until = elapsed + SNOOZE
        end
        return
    end

    -- Passive reminder: never stops anything, just makes a forgotten recording
    -- visible while you are still working at the machine.
    if elapsed >= next_remind then
        notify("● Still recording",
               string.format("%d min so far — stop with Ctrl+Opt+Cmd+R if the meeting ended", math.floor(elapsed / 60)),
               "Tink")
        next_remind = elapsed + REMIND_EVERY
    end

    if elapsed < quiet_until then return end

    -- Signals that a recording has outlived its meeting.
    local reason = nil
    if zoom_at_start and not zoom_running() and elapsed > 5 * 60 then
        reason = "Zoom has quit, so the meeting looks over."
    elseif elapsed > MIN_BEFORE and idle_seconds() > AWAY_SECS then
        reason = "There has been no keyboard or mouse activity for a while."
    elseif elapsed > HARD_CAP then
        reason = "This has been running for a long time."
    end

    if reason then ask(reason, math.floor(elapsed / 60)) end
end

----------------------------------------------------------------------- events

local function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTING then
        -- A rebuild may still be in flight. Park it rather than finishing it:
        -- the restore is itself a destroy+init on the graphics thread, and a
        -- wedged SCK there would hang OBS and cost the whole meeting. Flushing
        -- it "quickly" would just move that hazard onto the recording path.
        if sck_pending ~= nil then
            obs.timer_remove(sck_restore)
            obs.timer_remove(sck_verify)
            sck_deferred = true
        end
        -- Leave Idle so the capture sources are rendered for this recording.
        set_scene("Meeting")
        -- Deliberately no repair attempt here, for the same reason. The idle
        -- check has had minutes to fix this; if it could not, warn loudly and
        -- let the recording proceed rather than risk having no recording.
        warn_if_capture_dead()
        warn_if_bluetooth_output()

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        elapsed, quiet_until, prompting = 0, 0, false
        next_remind = REMIND_FIRST
        zoom_at_start = zoom_running()
        notify("● REC Meeting", "Recording started", "Glass")

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        prompting = false
        os.remove(ANSWER_FILE)
        notify("■ Meeting saved", "Recording stopped — transcribing now", "Submarine")
        run_pipeline()
        -- Release the screen so macOS stops showing the sharing indicator.
        set_scene("Idle")
        -- Now that the graphics thread is safe to stall again, finish the
        -- rebuild that was parked when this recording started.
        if sck_deferred then
            sck_deferred = false
            if sck_pending ~= nil then obs.timer_add(sck_restore, SCK_RESTORE_MS) end
        end
    end
end

function script_description()
    return "Meeting recorder: notifications, idle-scene privacy, forgot-to-stop watchdog, auto-transcription."
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
    obs.timer_add(tick, CHECK_EVERY * 1000)
    -- OBS has just built its capture streams, so start from a clean slate.
    -- Without this the staleness clause would fire a false alarm on any
    -- recording started before the first refresh cycle completes.
    sck_idle_tick, sck_since_try, sck_broken = 0, 0, false
    -- Catch up on recordings left unprocessed (e.g. after an OBS crash).
    run_pipeline()
end

function script_unload()
    obs.obs_frontend_remove_event_callback(on_event)
    -- A refresh leaves show_cursor inverted for a fraction of a second. Quitting
    -- or reloading inside that window would persist the wrong value into the
    -- scene collection, so put it back before we go — unless a recording is
    -- running, because the restore is a destroy+init that would stall the
    -- graphics thread mid-meeting. A flipped cursor flag is the cheaper loss.
    if sck_pending ~= nil then
        obs.timer_remove(sck_restore)
        obs.timer_remove(sck_verify)
        if not obs.obs_frontend_recording_active() then
            for _, s in ipairs(sck_pending) do
                if s.video then sck_set_show_cursor(s.name, s.show_cursor) end
            end
        end
        sck_pending = nil
    end
end
