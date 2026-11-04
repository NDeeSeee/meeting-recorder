# Setup

Target platform: **macOS on Apple Silicon (arm64)**. Homebrew at `/opt/homebrew`.
These are the installations and configurations the pipeline depends on. Versions
below are the ones this was built and verified against.

## 1. System dependencies (Homebrew)

```sh
# Recording + media
brew install --cask obs              # OBS Studio (screen + audio capture)
brew install --cask blackhole-2ch    # virtual audio device for system-audio capture

# Transcription + media tooling (formulae)
brew install whisper-cpp             # 1.9.1 — provides `whisper-cli`
brew install ffmpeg                  # 8.1.2 — mux/mkv, chapter markers, frame extraction
brew install jq uv                   # jq for module JSON; uv to build pinned Python envs
```

The Claude CLI (`claude`) must be installed and authenticated separately — it is
the LLM backend for summaries and language work in the modules. Every call goes
through `modules/lib/llm.py`, which runs it with no tools, no MCP servers, no
plugins and no session persistence, and passes the `model`/`effortLevel` from
`~/.claude/settings.json` explicitly (so the default model is unchanged).
Overrides: `MEETING_LLM_MODEL`, `MEETING_LLM_MODEL_<TASK>` (`SUMMARY`,
`CHAPTERS`, `INSIGHTS`, `TITLE`, `ROUTE`, `SEARCH`), `MEETING_LLM_EFFORT`,
`MEETING_SUMMARY_MODEL` (legacy); timeouts `SUMMARY_TIMEOUT`, `TITLE_TIMEOUT`,
`ROUTE_TIMEOUT`. Every call appends one line (model, tokens, cost, result) to
`~/.local/share/meeting-tools/llm/ledger.jsonl`.
Obsidian (with a vault at `~/Documents/Obsidian Vault`) is optional but required
by the `80-obsidian` module.

## 2. Whisper models

Download into `~/.local/share/whisper/` (paths are hardcoded in
`bin/meeting-process`):

```sh
mkdir -p ~/.local/share/whisper
# Transcription model (~1.6 GB) and Silero VAD model (~865 KB)
#   ggml-large-v3-turbo.bin
#   ggml-silero-v5.1.2.bin
# Fetch from the whisper.cpp model repo (ggerganov/whisper.cpp on Hugging Face).
```

If the VAD model is absent the pipeline still runs, just without silence gating.

## 3. Install the code

The exec bit is the on/off switch: `modules/20-actions`, `modules/60-threads`
and `bin/meeting-maintenance` are deliberately non-executable until enabled, so
never `install -m 755 bin/*` or `chmod +x` the modules wholesale. Use `install`
rather than `cp` over an existing copy: `install` writes a new file, while `cp`
rewrites the old one in place under a script that may be running.

```sh
# Orchestrator + CLI tools (meeting-canary: in-recording capture check, spawned by the Lua hook)
mkdir -p ~/.local/bin
install -m 755 bin/meeting-process bin/meeting-canary bin/meeting-search \
               bin/meeting-name-speaker bin/meeting-migrate bin/obs-watchdog ~/.local/bin/

# Enrichment modules + their shared helper (lib/ is never run as a module:
# the orchestrator only runs plain executable files directly in this dir)
mkdir -p ~/.local/share/meeting-modules/lib
install -m 755 modules/10-chapters modules/30-insights modules/40-slides modules/50-speakers \
               modules/70-calendar modules/80-obsidian modules/85-index modules/90-title \
               modules/95-route ~/.local/share/meeting-modules/
install -m 644 modules/20-actions modules/60-threads modules/README.md ~/.local/share/meeting-modules/
install -m 644 modules/lib/llm.py ~/.local/share/meeting-modules/lib/
rm -f ~/.local/share/meeting-modules/99-mp4     # removed module (never kept a file)

# OBS Lua hook + track merger
mkdir -p ~/.local/share/obs-scripts
cp obs/meeting-notify.lua obs/merge-tracks.py ~/.local/share/obs-scripts/

# Calendar matcher (Swift EventKit): nothing to do. 70-calendar compiles the
# copy embedded in the module into ~/.local/share/meeting-tools/calendar/ on
# first run, and rebuilds it when that source changes. (tools/calendar/
# calquery.swift is an older standalone copy without `--check`.)

# Display-sleep probe (Swift CoreGraphics) — compile once. Lets meeting-notify.lua
# skip the ScreenCaptureKit rebuild while the display is asleep, which otherwise
# hangs the OBS scripting thread (the deadlock obs-watchdog was added to catch).
swiftc -O tools/display-asleep.swift -o ~/.local/bin/display-asleep
```

Ensure `~/.local/bin` is on your `PATH`.

## 4. Python environments (transcription ML)

Two isolated environments live under `~/.local/share/meeting-tools/`. Python 3.14
(the current Homebrew default) is too new for torch, so build them with `uv`
against a pinned older Python:

```sh
cd ~/.local/share/meeting-tools

# Semantic search index (used by 85-index and `meeting-search`)
uv venv --python 3.12 index/venv
uv pip install --python index/venv/bin/python -r <path-to-repo>/requirements/index.txt

# Speaker diarization / embeddings (used by 50-speakers)
uv venv --python 3.12 speakers/venv
uv pip install --python speakers/venv/bin/python -r <path-to-repo>/requirements/speakers.txt
```

Key packages (full pins in `requirements/`): `torch 2.13`, `sentence-transformers`
+ `transformers` (index) and `speechbrain 1.1` + `torchaudio` (speakers).
Model weights are fetched from Hugging Face on first run and cached under each
env's `hf/` directory.

## 5. OBS configuration

1. **Audio routing** — create a BlackHole-based multi-output device (Audio MIDI
   Setup) so system audio reaches both your speakers and BlackHole. Set the app
   / system output to that multi-output device during meetings.
2. **Scene** — import `obs/scenes/Meetings.json` (rename `YOUR_USERNAME` paths
   inside to your home). It defines a `Meeting Audio (BlackHole)` source (system
   audio) and a microphone source on separate tracks, plus screen capture.
3. **Profile** — `obs/profiles/Meetings/basic.ini` records to
   `~/Recordings/Meetings` as multi-track `.mkv` (`RecTracks=15`). Adjust the
   `RecFilePath`.
4. **Hotkey** — bind **Start/Stop Recording** to `⌃⌥⌘R` (OBS global hotkey), so
   recording toggles without focusing OBS.
5. **Script hook** — in OBS → Tools → Scripts, add
   `~/.local/share/obs-scripts/meeting-notify.lua`. On "recording stopped" it
   spawns `meeting-process`. Running as an OBS child is deliberate: a launchd
   agent is blocked by macOS privacy from reading `~/Documents`, whereas a child
   of OBS inherits its granted access.
6. **OBS watchdog** (optional but recommended) — the Lua script's
   ScreenCaptureKit rebuild can block its own thread forever on a stuck macOS
   semaphore, silently freezing all repair/recovery for that OBS session. A
   separate launchd agent restarts OBS if that happens (never while a `.mkv`
   is actively being written):

   ```sh
   install -m 755 bin/obs-watchdog ~/.local/bin/
   sed "s/USERNAME/$(whoami)/g" launchd/com.meetingrecorder.obs-watchdog.plist \
       > ~/Library/LaunchAgents/com.meetingrecorder.obs-watchdog.plist
   launchctl load ~/Library/LaunchAgents/com.meetingrecorder.obs-watchdog.plist
   ```

   This agent only signals/relaunches OBS and stats files under `~/Library` and
   `~/Recordings` — it never touches `~/Documents`, so it doesn't run into the
   privacy restriction above.

   Restart schedule: the first restart happens as soon as the heartbeat is
   stale, the second no sooner than 10 min later, the third no sooner than
   20 min after that; 40 min after the third it gives up and shows an alert.
   `DRY_RUN=1 obs-watchdog` is a safe check: it logs `DRY_RUN: ...` lines to
   `~/Library/Logs/meeting-notify.log` but does not quit OBS or touch its state
   file. To exercise the state machine, also point `OBS_WATCHDOG_STATE` at a
   scratch file.
7. **Display switcher** (optional, for more than one monitor) — add one
   **macOS Screen Capture** source (Method: Display) per monitor to the
   **Meeting** scene, each fitted to the canvas, with only one visible. The
   visible one is what gets recorded. A menu-bar helper shows which display
   that is (red `●` while recording, `○` when idle) and switches on click;
   **Auto — follow Zoom window** (on by default) switches to the display that
   holds the largest Zoom window. It talks to `meeting-notify.lua` through
   three files in `~/Library/Logs/`: `meeting-notify.display` (the script's
   state), `meeting-notify.display-request` (a switch request) and
   `meeting-notify.display-online` (the connected displays and the main one,
   rewritten at least every 15 s).

   Recording never stays on an unplugged display: if the visible source's
   display goes offline (or is offline at record start), recording switches to
   the preferred display if it is connected, else the main display, else any
   connected one, with one notification per outage. When the preferred display
   (your last manual pick) comes back, recording returns to it unless Zoom
   follow is active. If the helper is not running, the online file goes stale
   after 2 min and the script keeps whatever is visible.

   ```sh
   swiftc -O tools/meeting-display.swift -o ~/.local/bin/meeting-display.new
   # Re-sign after linking: the linker's ad-hoc signature carries the temp name
   # and launchd refused it with OS_REASON_CODESIGNING (2026-11-04).
   codesign -s - -f ~/.local/bin/meeting-display.new
   mv -f ~/.local/bin/meeting-display.new ~/.local/bin/meeting-display
   sed "s/USERNAME/$(whoami)/g" launchd/com.meetingrecorder.meeting-display.plist \
       > ~/Library/LaunchAgents/com.meetingrecorder.meeting-display.plist
   launchctl load ~/Library/LaunchAgents/com.meetingrecorder.meeting-display.plist
   # Updating an already-loaded helper: launchctl kickstart -k gui/$(id -u)/com.meetingrecorder.meeting-display
   ```

   Every display source keeps its own capture stream open, so macOS "Currently
   Sharing" lists all of them. That is expected. Don't press **Stop Sharing**:
   it kills every OBS capture stream, meeting audio included.

8. **Capture canary** — nothing to configure beyond installing
   `bin/meeting-canary` (step 3). The Lua hook starts it detached at every
   recording start and unpause; it checks the growing `.mkv` about 45 s in and
   then every 10 min, and raises an alert for a black, frozen or silent
   capture. Its verdict goes to `<meeting>/.capture-health.json`.
   `meeting-canary --check <file.mkv>` runs one read-only check against any
   recording.

## 6. First run

Start a short recording, stop it, and watch:

```sh
tail -f ~/Library/Logs/meeting-process.log
```

A `~/Recordings/Meetings/<timestamp>_meeting/` folder should gain a transcript,
`summary.md`, and per-module artifacts. `meeting-search "some topic"` queries the
index once at least one meeting has been processed.

## Notes

- `bin/audio-output-active` is a small prebuilt Swift helper (checks the active
  CoreAudio output). Its source is not tracked here; the pipeline degrades
  gracefully without it.
- All runtime state (`route/projects.json`, `obsidian/entities.json`, the index,
  logs) is generated locally and gitignored — it is not part of this repo.
- Per-meeting marker files the pipeline writes (all hidden, in the meeting
  folder): `.meeting`, `.too-short`, `.video-qc`, `.video-black` (summary gets a
  black-screen banner), `.audio-incomplete` (participant-audio banner),
  `.capture-health.json` (meeting-canary), `.transcribe-state` /
  `.summary-state` / `.modules-state` (retry caps), `.pipeline-done` (finished
  for these inputs + this module set; `MEETING_RESCAN=1 meeting-process`
  ignores it), `.llm/` (rejected LLM replies, last 10), plus the module skip
  markers listed in `modules/README.md`.
