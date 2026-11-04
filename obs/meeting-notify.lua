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
-- 5. Repairs macOS ScreenCaptureKit streams that die while OBS sits idle, which
--    otherwise silently turns every later recording into frozen wallpaper with a
--    digitally silent system-audio track. Repairs are targeted (one source, with
--    backoff) and happen only while idle — never at record start.
-- 6. Writes a heartbeat file every tick so bin/obs-watchdog (a separate launchd
--    agent) can tell this script is still alive. Necessary because step 5's
--    rebuild can block this thread forever on a stuck macOS semaphore — see the
--    comment on write_heartbeat() — and nothing inside a frozen Lua VM can
--    notice or recover from that itself.
-- 7. Keeps the recording on a connected display: publishes which display is
--    being recorded, applies switch requests from the tools/meeting-display
--    menu-bar helper, and falls back to a live display (preferred, else the
--    main display, else any) when the recorded one is unplugged — at record
--    start and mid-recording.
-- 8. Starts bin/meeting-canary (detached) for every recording, and again on
--    unpause (it stops watching once the file has not grown for 90 s): it
--    checks the growing .mkv itself for black/frozen video and silent audio,
--    which is the only check that cannot be fooled by a source that merely
--    looks alive.

local obs = obslua

local HOME           = os.getenv("HOME")
local ANSWER_FILE    = "/tmp/meeting-watchdog.answer"
local HEARTBEAT_FILE = HOME .. "/Library/Logs/meeting-notify.heartbeat"
local NOTIFY_LOG     = HOME .. "/Library/Logs/meeting-notify.log"
local CHECK_EVERY    = 60      -- seconds between watchdog checks
local AWAY_SECS      = 15 * 60 -- keyboard/mouse idle that counts as "walked away"
local MIN_BEFORE     = 20 * 60 -- don't nag during the first stretch of a meeting
local HARD_CAP       = 180* 60 -- prompt regardless once a recording gets this long
local SNOOZE         = 30 * 60 -- after "Keep recording", stay quiet this long
local DIALOG_WAIT    = 180     -- seconds to answer before we assume you're gone
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

-- A whole shell word, for paths handed to a spawned command.
local function sq(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Append to the log without a banner — for state changes worth a record but not
-- an interruption (e.g. confirming capture came back to life). Plain io, not a
-- shell: this runs on OBS's threads, and forking date/tr/echo for every line
-- cost a few ms each time for nothing.
local function log_line(message)
    local fh = io.open(NOTIFY_LOG, "a")
    if not fh then return end
    fh:write(os.date("%Y-%m-%d %H:%M:%S "), tostring(message), "\n")
    fh:close()
end

local function notify(title, message, sound)
    os.execute(string.format(
        "/usr/bin/osascript -e 'display notification \"%s\" with title \"%s\" sound name \"%s\"' >/dev/null 2>&1 &",
        shq(message), shq(title), shq(sound)))
    log_line(message)
end

-- Async modal that stays up until dismissed: for the failures that cost the
-- meeting's record if nobody acts within the first minute.
local function alert(title, message)
    os.execute(string.format(
        "/usr/bin/osascript -e 'display alert \"%s\" message \"%s\" as critical' >/dev/null 2>&1 &",
        shq(title), shq(message)))
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

-- The file OBS is writing right now, or nil (the canary then finds the newest).
local function recording_path()
    local out = obs.obs_frontend_get_recording_output()
    if out == nil then return nil end
    local st = obs.obs_output_get_settings(out)
    local path = st ~= nil and obs.obs_data_get_string(st, "path") or ""
    if st ~= nil then obs.obs_data_release(st) end
    obs.obs_output_release(out)
    if path == "" then return nil end
    return path
end

-- Detached, like the pipeline: it sleeps, runs ffmpeg on the growing file and
-- alerts by itself, none of which may ever happen on an OBS thread.
local function run_canary()
    local path = recording_path()
    os.execute(string.format(
        '/usr/bin/nohup "$HOME/.local/bin/meeting-canary" --watch %s >/dev/null 2>&1 &',
        path and sq(path) or ""))
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
    alert("Participants will NOT be recorded",
        "Your audio OUTPUT is plain Bluetooth (e.g. AirPods). macOS records the " ..
        "other participants as silence in this mode. Fix it now: choose your Multi-Output " ..
        "device (AirPods + BlackHole) so capture works while you still hear everyone — or " ..
        "switch output to the built-in speakers. Your microphone can stay on AirPods.")
end

-- Seconds since the last keyboard/mouse input. Needs no special permissions.
local function idle_seconds()
    local out = sh("/usr/sbin/ioreg -c IOHIDSystem 2>/dev/null | " ..
                   "/usr/bin/awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'")
    return tonumber(out) or 0
end

-------------------------------------------------------- displays: who is live

-- The Meeting scene holds one display-capture source per monitor, and exactly one
-- is visible — that is the display being recorded. Switching only shows/hides
-- scene items (every source keeps its own stream running), so it is instant and
-- never goes near the ScreenCaptureKit rebuild that can wedge this thread.
-- tools/meeting-display.swift (a menu-bar helper) talks to us through files,
-- like the watchdog's ANSWER_FILE: we publish the sources and which is visible,
-- it drops a request naming the source to show, and it publishes which displays
-- are connected right now.
local SCK_VIDEO_ID    = "screen_capture"
local SCK_AUDIO_ID    = "sck_audio_capture"
local DISPLAY_STATE   = HOME .. "/Library/Logs/meeting-notify.display"
local DISPLAY_REQUEST = HOME .. "/Library/Logs/meeting-notify.display-request"
local DISPLAY_ONLINE  = HOME .. "/Library/Logs/meeting-notify.display-online"
local DISPLAY_SCENE   = "Meeting"
local DISPLAY_POLL_MS = 500
local DISPLAY_REFRESH = 30   -- rewrite an unchanged state this often, so the helper can spot a hung script
local ONLINE_EVERY    = 4    -- polls between reads of the online-display file (2 s)
local ONLINE_STALE    = 120  -- seconds; an older online file means the helper is gone
local SAVE_DELAY_MS   = 1500 -- let a burst of switches settle before saving

local display_last      = nil   -- last state written, to skip identical rewrites
local display_wrote     = 0     -- os.time() of that write
local display_preferred = nil   -- source the user (or the helper) last chose
local display_visible   = nil   -- visible source as of the last poll
local display_polls     = 0
local display_candidate = nil   -- fallback target seen once; applied when seen twice
local display_none_said = false -- logged "no connected display" already
local display_lost_said = false -- notified about this outage already (reset on return)
local display_save_due  = false -- a switch is waiting to be written to disk

-- The helper's {"online":["UUID",...],"main":"UUID","updated":<epoch>}. Returns
-- nil plus a reason when it is missing, unreadable or stale: callers then keep
-- whatever is visible rather than guess. Missing data must never cause a switch.
-- A plain file read (microseconds), never a shell-out: this runs on OBS threads.
local function parse_online(text, now)
    local updated = tonumber(text:match('"updated"%s*:%s*(%d+)'))
    local list = text:match('"online"%s*:%s*%[(.-)%]')
    if updated == nil or list == nil then return nil, "unreadable" end
    if now - updated > ONLINE_STALE then return nil, "stale" end
    local set, n = {}, 0
    for uuid in list:gmatch('"([^"]+)"') do
        set[uuid:upper()] = true
        n = n + 1
    end
    -- No online display at all is not a state we can act on (lid closed with
    -- nothing attached); treat it as unknown rather than "everything is dead".
    if n == 0 then return nil, "empty" end
    return { set = set, main = (text:match('"main"%s*:%s*"([^"]*)"') or ""):upper(), count = n }
end

local function read_online()
    local fh = io.open(DISPLAY_ONLINE, "r")
    if not fh then return nil, "missing" end
    local text = fh:read("*a") or ""
    fh:close()
    return parse_online(text, os.time())
end

-- Which source should be visible: the preferred one if its display is online,
-- else the one on the main display (CGMainDisplayID, published by the helper),
-- else any online one. nil = no source shows a connected display. A source
-- with no display_uuid cannot be judged, so it counts as live (never switch away
-- from something on a guess). Pure function, so it can be tested outside OBS.
local function choose_display(items, online, preferred)
    local function live(it) return it.uuid == "" or online.set[it.uuid] == true end
    if preferred ~= nil then
        for _, it in ipairs(items) do
            if it.name == preferred and live(it) then return it.name end
        end
    end
    for _, it in ipairs(items) do
        if it.uuid ~= "" and it.uuid == online.main and live(it) then return it.name end
    end
    for _, it in ipairs(items) do
        if live(it) then return it.name end
    end
    return nil
end

local function json_str(s)
    return '"' .. (tostring(s):gsub('[%c"\\]', function(c)
        return string.format("\\u%04x", c:byte())
    end)) .. '"'
end

-- Calls fn(item, name, display_uuid, source) for each display capture in the
-- Meeting scene. Reads settings only, never properties: building the properties
-- would re-enumerate SCShareableContent (see sck_reenumerate) every half second.
local function each_display_item(fn)
    local scene_src = obs.obs_get_source_by_name(DISPLAY_SCENE)
    if scene_src == nil then return end
    local items = obs.obs_scene_enum_items(obs.obs_scene_from_source(scene_src))
    if items ~= nil then
        for _, item in ipairs(items) do
            local src = obs.obs_sceneitem_get_source(item)
            if obs.obs_source_get_id(src) == SCK_VIDEO_ID then
                local st = obs.obs_source_get_settings(src)
                if obs.obs_data_get_int(st, "type") == 0 then
                    fn(item, obs.obs_source_get_name(src), obs.obs_data_get_string(st, "display_uuid"), src)
                end
                obs.obs_data_release(st)
            end
        end
        obs.sceneitem_list_release(items)
    end
    obs.obs_source_release(scene_src)
end

-- Snapshot of the Meeting scene's display sources: name, upper-cased UUID,
-- visibility and current frame width (0 = no frame since the last rebuild).
local function display_items()
    local list, visible = {}, nil
    each_display_item(function(item, name, uuid, src)
        local vis = obs.obs_sceneitem_visible(item)
        list[#list + 1] = { name = name, uuid = (uuid or ""):upper(), visible = vis,
                            width = obs.obs_source_get_width(src) }
        if vis and visible == nil then visible = list[#list] end
    end)
    return list, visible
end

-- Writing the scene collection is OBS's job and it does it on scene changes, but
-- a visibility toggle from a script is not one: a switch made while idle lived
-- only in memory, and the next crash or watchdog restart brought the dead display
-- back (capture-05). obs_frontend_save only queues the save onto the UI thread,
-- so calling it from a timer is safe; it is deferred and skipped while recording
-- so no disk I/O lands on a meeting.
local function display_save()
    obs.timer_remove(display_save)
    if not display_save_due then return end
    if obs.obs_frontend_recording_active() then return end   -- RECORDING_STOPPED re-arms
    display_save_due = false
    obs.obs_frontend_save()
end

local function display_apply(want, why)
    local known, changed = false, false
    each_display_item(function(_, name) if name == want then known = true end end)
    if not known then
        log_line("display switch ignored: no display source named " .. want)
        return false
    end
    -- Show the new one before hiding the old, so no frame renders with neither.
    each_display_item(function(item, name)
        if name == want and not obs.obs_sceneitem_visible(item) then
            obs.obs_sceneitem_set_visible(item, true)
            changed = true
        end
    end)
    each_display_item(function(item, name)
        if name ~= want and obs.obs_sceneitem_visible(item) then
            obs.obs_sceneitem_set_visible(item, false)
            changed = true
        end
    end)
    display_visible = want
    if changed then
        log_line("recording display -> " .. want .. (why and (" (" .. why .. ")") or ""))
        display_save_due = true
        obs.timer_remove(display_save)
        obs.timer_add(display_save, SAVE_DELAY_MS)
    end
    return true
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
--
-- When to rebuild. The old design rebuilt every SCK source every 10 idle
-- minutes and again at record start whenever anything had ever failed. That
-- churn (3 enumerations and 5 inits per cycle) is what kept wedging OBS, and a
-- single hidden, unplugged display then latched the alarm on forever, so every
-- recording rebuilt the healthy visible stream as it started (blank first
-- seconds, inverted cursor) while the real failure was never reported
-- (capture-02/08). Now, only while idle:
--   * when you come back to the machine, rebuild the source the next recording
--     will use (plus the audio stream) — a display sleep is what kills streams
--     with a still-valid frame size, which nothing cheaper can detect;
--   * a source with no frame (width 0) whose display is connected gets retried
--     on its own, with exponential backoff.
-- A source whose display is unplugged is never rebuilt: it cannot succeed and
-- only floods the OBS log with "Invalid target display ID".
local SCK_RESTORE_MS  = 400       -- comfortably more than one video frame
local SCK_VERIFY_MS   = 6000      -- SCK needs a moment to deliver a first frame
local SCK_AWAY_SECS   = 120       -- input idle past this = stepped away, likely asleep
local SCK_RETURN_GAP  = 10        -- idle minutes between "you're back" refreshes
local SCK_RETRY_MAX   = 60        -- idle minutes; cap on a dead source's backoff
local POSTCHECK_MS    = 8000      -- after RECORDING_STARTED, re-check the frame size

local sck_pending     = nil       -- sources awaiting restore + verification
local sck_deferred    = false     -- a restore parked because recording started
local sck_was_away    = false     -- input was idle past SCK_AWAY_SECS last tick
local sck_slept_away  = false     -- display_asleep() seen true during this absence
local sck_return_due  = false     -- back after a sleep: refresh on the next idle tick
local sck_minute      = 0         -- idle minutes since load (the backoff clock)
local sck_last_return = -SCK_RETURN_GAP
local sck_state       = {}        -- name -> { status=, fails=, retry_at= }
local rec_alerted     = {}        -- "<class>:<source>" already alerted this recording

-- SCK sources, optionally only those named in `only` (a set). Display captures
-- only for video — the window/application variant has no display to lose and
-- reports width 0 forever, which would make the liveness check cry wolf.
local function sck_sources(only)
    local found = {}
    local sources = obs.obs_enum_sources()
    if sources == nil then return found end
    for _, src in ipairs(sources) do
        local id, name = obs.obs_source_get_id(src), obs.obs_source_get_name(src)
        if id == SCK_VIDEO_ID and (only == nil or only[name]) then
            local st = obs.obs_source_get_settings(src)
            if obs.obs_data_get_int(st, "type") == 0 then
                found[#found + 1] = {
                    name        = name,
                    video       = true,
                    show_cursor = obs.obs_data_get_bool(st, "show_cursor"),
                    uuid        = (obs.obs_data_get_string(st, "display_uuid") or ""):upper(),
                }
            end
            obs.obs_data_release(st)
        elseif id == SCK_AUDIO_ID and (only == nil or only[name] or only["*audio"]) then
            found[#found + 1] = { name = name, video = false }
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

-- The step that makes a rebuild actually stick. init_screen_stream re-filters the
-- new SCStream against a *cached* shareable-content snapshot (sc->shareable_content)
-- that nothing in the update/init path refreshes — so after a display-sleep death
-- it re-references the same dead SCDisplay and delivers no frames. The snapshot is
-- only rebuilt by the plugin's content_settings_changed callback, which fires from
-- obs_properties_apply_settings. Applying the source's own settings back through
-- its properties forces a fresh SCShareableContent enumeration; the plugin holds a
-- semaphore across that async fetch, so the subsequent init blocks until the new
-- snapshot has landed. (This is also why OBS's own "Restart Capture" only works
-- after its Properties dialog has been opened — the dialog does this apply for you.)
-- It blocks the caller briefly, so like every rebuild step it runs idle-only.
local function sck_reenumerate(name)
    local src = obs.obs_get_source_by_name(name)
    if src == nil then return end
    local settings = obs.obs_source_get_settings(src)
    local props    = obs.obs_source_properties(src)
    if props ~= nil and settings ~= nil then
        obs.obs_properties_apply_settings(props, settings)
    end
    if props ~= nil then obs.obs_properties_destroy(props) end
    if settings ~= nil then obs.obs_data_release(settings) end
    obs.obs_source_release(src)
end

-- True only when the display is provably asleep. A rebuild attempted then can
-- neither succeed (macOS drops a sleeping display from ScreenCaptureKit's list,
-- so init has nothing to attach to) nor return promptly: sck_reenumerate blocks
-- on the shareable-content semaphore and can wedge this thread for good — the
-- exact deadlock bin/obs-watchdog exists to catch, and the reason it spent whole
-- nights restarting OBS. Skipping the rebuild while asleep is therefore both the
-- correct thing (nothing to repair against) and what stops that thrashing.
-- Fails OPEN: a missing helper or any unexpected output reads as "awake", so a
-- machine without it behaves exactly as before. This is a shell-out, so it is
-- only ever called right before a rebuild or to classify a dead source — never
-- on a routine tick.
local function display_asleep()
    return sh('"$HOME/.local/bin/display-asleep" 2>/dev/null'):match("asleep") ~= nil
end

-- Why a display source has no frames. The advice differs completely: an
-- unplugged display needs a different source, a sleeping one needs waking, and
-- only a dead stream needs OBS restarted. The old code called all of them
-- "asleep", which is how a disconnected display went unreported for days.
local function classify_dead(uuid, online)
    if online ~= nil and uuid ~= "" and not online.set[uuid] then return "disconnected" end
    if display_asleep() then return "asleep" end
    return "dead"
end

local function sck_status(name)
    local st = sck_state[name]
    if st == nil then
        st = { status = "unknown", fails = 0, retry_at = 0 }
        sck_state[name] = st
    end
    return st
end

-- A rebuild resets the source's frame size to zero, and only a frame actually
-- delivered by ScreenCaptureKit makes it non-zero again. So a still-zero width
-- here means the new stream never started. Per source, so one hopeless source
-- (an unplugged monitor) can no longer poison the verdict on the others.
-- Only meaningful for video: an audio source has no frame size; its silence is
-- caught by meeting-canary and the pipeline's own empty-track check.
local function sck_verify()
    obs.timer_remove(sck_verify)
    local pending = sck_pending or {}
    sck_pending = nil
    local online = nil
    for _, s in ipairs(pending) do
        if s.video then
            local src = obs.obs_get_source_by_name(s.name)
            if src ~= nil then
                local w, h = obs.obs_source_get_width(src), obs.obs_source_get_height(src)
                obs.obs_source_release(src)
                local st = sck_status(s.name)
                if w > 0 then
                    -- A real frame arrived: the only evidence worth clearing on.
                    if st.fails > 0 then
                        log_line(string.format("%s recovered — live %dx%d", s.name, w, h))
                    end
                    st.status, st.fails, st.retry_at = "ok", 0, 0
                else
                    online = online or read_online()
                    local class = classify_dead(s.uuid or "", online)
                    st.fails = st.fails + 1
                    st.status = class
                    local wait = math.min(2 ^ st.fails, SCK_RETRY_MAX)
                    st.retry_at = sck_minute + wait
                    -- Escalating, not latched: log failures 1, 2, 4, 8, ... so a
                    -- long outage stays visible without flooding the log.
                    local f = st.fails
                    while f > 1 and f % 2 == 0 do f = f / 2 end
                    if f == 1 then
                        log_line(string.format("%s not producing frames (%s) — failure %d, retry in %d idle min",
                                               s.name, class, st.fails, wait))
                    end
                end
            end
        end
    end
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

-- Rebuild exactly the named sources (a set; "*audio" adds the SCK audio
-- stream). Idle-only, one rebuild in flight at a time, never against a
-- sleeping display. Returns true if a rebuild was started.
local function sck_refresh(only, why)
    if sck_pending ~= nil then return false end       -- one already in flight
    if obs.obs_frontend_recording_active() then return false end
    local srcs = sck_sources(only)
    if #srcs == 0 then return false end
    -- Never rebuild against a sleeping display: it cannot succeed and can hang
    -- this thread (see display_asleep). The wake will trigger the refresh instead.
    if display_asleep() then return false end
    sck_pending = srcs
    local names = {}
    for _, s in ipairs(srcs) do names[#names + 1] = s.name end
    log_line("rebuilding capture: " .. table.concat(names, ", ") .. " (" .. why .. ")")
    -- Refresh each source's shareable-content snapshot BEFORE rebuilding, so the
    -- new stream is filtered against a live display and not the dead cached one.
    -- Without this step the flip below rebuilds a stream that delivers no frames.
    for _, s in ipairs(srcs) do
        sck_reenumerate(s.name)
    end
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
    return true
end

-- Driven by the idle branch of tick(), so the backoff clock advances in idle
-- minutes and not wall-clock: time spent recording is time we were forbidden to
-- rebuild, and counting it would burn through the backoff for nothing.
local function sck_health_check()
    sck_minute = sck_minute + 1
    if sck_pending ~= nil then return end
    local away = idle_seconds() > SCK_AWAY_SECS
    -- Evidence, not a guess: only an absence during which the display was
    -- provably asleep can have killed the stream. One shell-out per idle tick
    -- while away, and none once the sleep has been seen.
    if away and not sck_slept_away and display_asleep() then sck_slept_away = true end
    local fire_return = sck_return_due and not away
    sck_return_due = false
    if sck_was_away and not away then
        -- Back. Wait one more tick rather than rebuilding now: the display is
        -- still waking, and this is when a meeting may be about to start, so
        -- the rebuild should not land on the record press.
        sck_return_due = sck_slept_away
        sck_slept_away = false
    end
    sck_was_away = away

    local online = read_online()
    local items, visible = display_items()

    -- Deliberate deviation from "rebuild only dead, non-visible sources"
    -- (plan T0-4), pending owner sign-off: a stream killed by display sleep
    -- keeps its last frame and size, so nothing else detects it, and the next
    -- recording would be frozen wallpaper. Hence one rebuild of the visible
    -- source (plus the audio stream that dies alongside it) after a proven
    -- sleep, not more often than every SCK_RETURN_GAP idle minutes.
    if fire_return and visible ~= nil and sck_minute - sck_last_return >= SCK_RETURN_GAP
       and (online == nil or visible.uuid == "" or online.set[visible.uuid]) then
        sck_last_return = sck_minute
        if sck_refresh({ [visible.name] = true, ["*audio"] = true }, "back after display sleep") then return end
    end

    -- Unplugged displays first: noted once, never rebuilt.
    local candidates = {}
    for _, it in ipairs(items) do
        local st = sck_status(it.name)
        if online ~= nil and it.uuid ~= "" and not online.set[it.uuid] then
            if st.status ~= "disconnected" then
                log_line(it.name .. ": display disconnected — not rebuilding until it returns")
            end
            st.status, st.retry_at = "disconnected", 0
        else
            if st.status == "disconnected" then st.status = "unknown" end
            if it.width == 0 and sck_minute >= st.retry_at then
                -- The visible one first: it is what the next recording uses.
                table.insert(candidates, it.visible and 1 or #candidates + 1, it.name)
            end
        end
    end
    -- Targeted retry: at most one source per tick.
    if #candidates > 0 then sck_refresh({ [candidates[1]] = true }, "no frames") end
end

-- One-shot, fired a moment after load so OBS has settled. Reloading the script
-- (Tools ▸ Scripts ▸ ↻) therefore repairs a stream that died since launch without
-- a full restart. Only the source the next recording will use. Removes itself.
local function sck_boot()
    obs.timer_remove(sck_boot)
    local online = read_online()
    local _, visible = display_items()
    if visible ~= nil and (online == nil or visible.uuid == "" or online.set[visible.uuid]) then
        sck_refresh({ [visible.name] = true, ["*audio"] = true }, "script loaded")
    end
end

-- A capture that is about to record nothing costs the meeting's entire visual
-- record, so it earns an async critical alert, once per class and source per
-- recording. The advice matches the cause.
local function warn_capture(class, name)
    local key = class .. ":" .. tostring(name)
    if rec_alerted[key] then return end
    rec_alerted[key] = true
    if class == "none" then
        notify("⚠︎ Nothing to record", "No display source is visible in the Meeting scene", "Basso")
        alert("No screen is being recorded",
            "The Meeting scene has no visible display capture, so the video will be empty. " ..
            "Pick a display in the menu-bar switcher (or enable one in OBS).")
    elseif class == "disconnected" then
        notify("⚠︎ Display disconnected", name .. " is not connected — video will be BLACK", "Basso")
        alert("Recording a disconnected display",
            "'" .. name .. "' is not connected and no source for a connected display " ..
            "could be selected, so the video of this meeting will be black. Pick a live " ..
            "display in the menu-bar switcher, or add a display capture for this screen in OBS.")
    elseif class == "asleep" then
        notify("⚠︎ Display asleep", name .. " is asleep — wake it so the screen is recorded", "Basso")
        alert("The recorded display is asleep",
            "'" .. name .. "' is asleep, so it delivers no picture. Wake it (move the mouse " ..
            "or press a key); capture resumes on its own once it is awake.")
    else
        notify("⚠︎ Screen capture dead", name .. " is not delivering frames — restart OBS", "Basso")
        alert("Screen capture is not working",
            "'" .. name .. "' is connected and awake but is not delivering frames, so the " ..
            "video of this meeting will be frozen or black. The BlackHole backup track " ..
            "still captures the participants, so the transcript survives, but the screen " ..
            "does not. To be safe: stop this recording, quit and reopen OBS, then start again.")
    end
end

-- Judge only what will actually be recorded: the Meeting scene's visible
-- display source. Hidden or unplugged sources no longer decide anything.
-- `skip_zero` covers the record-start case where a parked rebuild of this very
-- source has reset its width; the post-start check judges it a few seconds on.
local function check_visible_capture(skip_zero)
    local _, visible = display_items()
    if visible == nil then warn_capture("none", nil); return end
    local online = read_online()
    if online ~= nil and visible.uuid ~= "" and not online.set[visible.uuid] then
        warn_capture("disconnected", visible.name)
        return
    end
    if visible.width == 0 and not skip_zero then
        warn_capture(classify_dead(visible.uuid, online), visible.name)
    end
end

local function pending_has(name)
    for _, s in ipairs(sck_pending or {}) do
        if s.name == name then return true end
    end
    return false
end

-- A few seconds into the recording every live source has delivered a frame. A
-- width of 0 now means this recording has no picture; say so while it is still
-- early enough to fix. (A frozen-but-sized stream passes this; meeting-canary
-- looks at the file itself and catches that.)
local function capture_postcheck()
    obs.timer_remove(capture_postcheck)
    if not obs.obs_frontend_recording_active() then return end
    check_visible_capture(false)
end

----------------------------------------------------- display switcher (poll)

-- Choose the effective display and switch to it if it differs from what is
-- visible. `immediate` (record start) applies at once; the poll needs the same
-- answer twice in a row (~2-4 s) so a flapping cable does not flip sources on
-- every blip. Missing or stale online data never causes a switch.
local function display_follow(immediate, online, items, visible)
    if online == nil then return end
    local want = choose_display(items, online, display_preferred or (visible and visible.name))
    if want == nil then
        if not display_none_said then
            log_line("no display source shows a connected display — keeping " ..
                     (visible and visible.name or "nothing"))
            display_none_said = true
        end
        display_candidate = nil
        return
    end
    display_none_said = false
    if visible ~= nil and want == visible.name then display_candidate = nil; return end
    if not immediate and display_candidate ~= want then display_candidate = want; return end
    display_candidate = nil
    local why, lost = nil, false
    if visible == nil then
        why = "nothing was visible"
    elseif visible.uuid ~= "" and not online.set[visible.uuid] then
        why, lost = visible.name .. " disconnected", true
    else
        why = want .. " is back"
    end
    if display_apply(want, why) then
        -- The helper notifies only when it makes the switch itself; when this
        -- script gets there first (record start, or its poll beats the helper)
        -- the user must still learn that a different screen is being recorded.
        -- One banner per outage, so a flapping cable cannot spam.
        if lost and not display_lost_said then
            display_lost_said = true
            notify("⚠︎ Display disconnected",
                   visible.name .. " is disconnected — now recording " .. want, "Tink")
        elseif not lost then
            display_lost_said = false
        end
    end
end

-- At RECORDING_STARTING, before the Meeting scene goes live: a recording must
-- never start on an unplugged display (every recording for 2.5 days was black
-- because the visible source pointed at one). Visibility toggle only.
local function display_select_for_recording()
    local items, visible = display_items()
    local online, why = read_online()
    if online == nil then
        log_line("record start: online-display list " .. why ..
                 " (meeting-display helper not running?) — keeping " ..
                 (visible and visible.name or "nothing"))
        return
    end
    display_follow(true, online, items, visible)
end

local function display_poll()
    -- Claim the request by renaming it first: a request the helper renames into
    -- place between our read and a plain remove would otherwise be lost.
    local claimed = DISPLAY_REQUEST .. ".claimed"
    if os.rename(DISPLAY_REQUEST, claimed) then
        local fh = io.open(claimed, "r")
        local want = ""
        if fh then
            want = (fh:read("*l") or ""):match("^%s*(.-)%s*$")
            fh:close()
        end
        os.remove(claimed)
        -- A request is a choice (manual pick or the helper's follow): it becomes
        -- the preferred display that fallbacks return to.
        if want ~= "" and display_apply(want, "requested") then
            display_preferred = want
        end
    end

    local items, visible = display_items()
    -- A change made by hand in OBS (not through us) is a choice too.
    if visible ~= nil and display_visible ~= nil and visible.name ~= display_visible then
        display_preferred = visible.name
        log_line("recording display -> " .. visible.name .. " (changed in OBS)")
        display_save_due = true
        obs.timer_remove(display_save)
        obs.timer_add(display_save, SAVE_DELAY_MS)
    end
    if display_preferred == nil and visible ~= nil then display_preferred = visible.name end
    display_visible = visible and visible.name or nil

    -- Mid-recording (or idle) unplug: fall back; replug: return to preferred.
    display_polls = display_polls + 1
    if display_polls % ONLINE_EVERY == 0 then
        display_follow(false, read_online(), items, visible)
        items, visible = display_items()
        display_visible = visible and visible.name or nil
    end

    local sources = {}
    for _, it in ipairs(items) do
        -- display_uuid is published as OBS stores it; the helper compares upper-cased.
        sources[#sources + 1] = string.format('{"name":%s,"display_uuid":%s,"visible":%s}',
            json_str(it.name), json_str(it.uuid), tostring(it.visible))
    end
    local scene_name = ""
    local cur = obs.obs_frontend_get_current_scene()
    if cur ~= nil then
        scene_name = obs.obs_source_get_name(cur)
        obs.obs_source_release(cur)
    end
    local body = string.format('"recording":%s,"scene":%s,"sources":[%s]',
        tostring(obs.obs_frontend_recording_active()), json_str(scene_name), table.concat(sources, ","))

    local now = os.time()
    if body == display_last and now - display_wrote < DISPLAY_REFRESH then return end
    -- Write-then-rename so the helper never reads a half-written file.
    local tmp = DISPLAY_STATE .. ".tmp"
    local out = io.open(tmp, "w")
    if not out then return end
    out:write(string.format('{%s,"updated":%d}\n', body, now))
    out:close()
    if os.rename(tmp, DISPLAY_STATE) then
        display_last, display_wrote = body, now
    end
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

-- sck_reenumerate() blocks this thread on a plugin-internal semaphore with no
-- timeout (see its comment); if that async fetch never resolves, tick() never
-- returns and this script goes silent forever with OBS still "running". The
-- display_asleep() guard keeps that call from ever running while the display
-- is asleep, which was its overwhelmingly common trigger, and rebuilds are now
-- rare and targeted. This heartbeat + bin/obs-watchdog remain the backstop
-- for any residual wedge, since nothing inside a frozen Lua VM can notice one —
-- it can't inspect a frozen Lua VM, so it just checks whether this heartbeat is
-- still advancing. Plain io, not os.execute: must stay cheap since it runs
-- every tick, healthy or not.
local function write_heartbeat()
    local fh = io.open(HEARTBEAT_FILE, "w")
    if fh then
        fh:write(tostring(os.time()))
        fh:close()
    end
end

local function tick()
    write_heartbeat()
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
        rec_alerted = {}
        -- A comeback refresh due on the next idle tick would land right after
        -- this recording; the stream is being judged live now, so drop it.
        sck_return_due = false
        -- A rebuild may still be in flight. Park it rather than finishing it:
        -- the restore is itself a destroy+init on the graphics thread, and a
        -- wedged SCK there would hang OBS and cost the whole meeting. Flushing
        -- it "quickly" would just move that hazard onto the recording path.
        if sck_pending ~= nil then
            obs.timer_remove(sck_restore)
            obs.timer_remove(sck_verify)
            sck_deferred = true
        end
        -- Pick a live display BEFORE the Meeting scene goes live, so not even
        -- the first frame comes from an unplugged monitor. No rebuild here, ever:
        -- rebuilding at record start destroyed the healthy stream being recorded
        -- (blank first seconds) and left its cursor flag inverted all meeting.
        display_select_for_recording()
        -- Leave Idle so the capture sources are rendered for this recording.
        set_scene("Meeting")
        -- Alerts fire here regardless of any repair in flight: a suppressed
        -- alert at exactly this moment is how 12 black recordings went unnoticed.
        local _, visible = display_items()
        check_visible_capture(visible ~= nil and pending_has(visible.name))
        warn_if_bluetooth_output()

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        elapsed, quiet_until, prompting = 0, 0, false
        next_remind = REMIND_FIRST
        zoom_at_start = zoom_running()
        notify("● REC Meeting", "Recording started", "Glass")
        obs.timer_add(capture_postcheck, POSTCHECK_MS)
        run_canary()

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED then
        -- A pause longer than the canary's 90 s no-growth window ends its
        -- watch; start it again. Its per-recording lock makes this a no-op when
        -- the first watcher is still running.
        run_canary()

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        prompting = false
        obs.timer_remove(capture_postcheck)
        os.remove(ANSWER_FILE)
        notify("■ Meeting saved", "Recording stopped — transcribing now", "Submarine")
        run_pipeline()
        -- Release the screen so macOS stops showing the sharing indicator.
        set_scene("Idle")
        -- A display switch made mid-recording was not saved then; save it now.
        if display_save_due then obs.timer_add(display_save, SAVE_DELAY_MS) end
        -- Now that the graphics thread is safe to stall again, finish the
        -- rebuild that was parked when this recording started.
        if sck_deferred then
            sck_deferred = false
            if sck_pending ~= nil then obs.timer_add(sck_restore, SCK_RESTORE_MS) end
        end
    end
end

function script_description()
    return "Meeting recorder: notifications, idle-scene privacy, live-display fallback, " ..
           "capture canary, forgot-to-stop watchdog, auto-transcription."
end

function script_load(settings)
    write_heartbeat()  -- fresh immediately, so the watchdog can't misfire before the first tick
    obs.obs_frontend_add_event_callback(on_event)
    obs.timer_add(tick, CHECK_EVERY * 1000)
    -- OBS has just built its capture streams, so start from a clean slate.
    sck_state, sck_minute, sck_last_return = {}, 0, -SCK_RETURN_GAP
    display_preferred, display_visible, display_candidate = nil, nil, nil
    -- Heal a stream that died before this script came up (e.g. an in-place
    -- reload while the stream was already dead), rather than waiting a cycle.
    obs.timer_add(sck_boot, 2000)
    obs.timer_add(display_poll, DISPLAY_POLL_MS)
    -- Catch up on recordings left unprocessed (e.g. after an OBS crash).
    run_pipeline()
end

function script_unload()
    obs.obs_frontend_remove_event_callback(on_event)
    obs.timer_remove(display_poll)
    obs.timer_remove(display_save)
    obs.timer_remove(capture_postcheck)
    -- No state file = OBS is gone; the menu-bar helper shows that immediately
    -- instead of waiting for the state to go stale.
    os.remove(DISPLAY_STATE)
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
