-- meeting-notify.lua
--
-- 1. Notifies (banner + sound) when recording starts/stops.
-- 2. Parks OBS on an empty "Idle" scene whenever it is not recording, so OBS
--    releases ScreenCaptureKit and macOS stops reporting that the screen is
--    being shared. Switching back to "Meeting" at record time also gives each
--    recording a freshly-started capture stream, which is what prevents the
--    stale-SCK-audio bug (participants silently recorded as digital silence).
-- 3. Watchdog: if the recording looks abandoned, ask whether to keep going and
--    stop it automatically if nobody answers.
-- 4. Kicks off the transcribe/summarize pipeline. It MUST be spawned from OBS:
--    a launchd agent is blocked by macOS privacy from reading ~/Documents,
--    whereas a child of OBS inherits OBS's folder access.

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

local function notify(title, message, sound)
    os.execute(string.format(
        "/usr/bin/osascript -e 'display notification \"%s\" with title \"%s\" sound name \"%s\"' >/dev/null 2>&1 &",
        message, title, sound))
    os.execute(string.format(
        "date '+%%Y-%%m-%%d %%H:%%M:%%S' | tr -d '\\n' >> \"$HOME/Library/Logs/meeting-notify.log\"; echo ' %s' >> \"$HOME/Library/Logs/meeting-notify.log\"",
        message))
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
    if not obs.obs_frontend_recording_active() then return end
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
        -- Leave Idle so the capture sources start fresh for this recording.
        set_scene("Meeting")
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
    end
end

function script_description()
    return "Meeting recorder: notifications, idle-scene privacy, forgot-to-stop watchdog, auto-transcription."
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
    obs.timer_add(tick, CHECK_EVERY * 1000)
    -- Catch up on recordings left unprocessed (e.g. after an OBS crash).
    run_pipeline()
end

function script_unload()
    obs.obs_frontend_remove_event_callback(on_event)
end
