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
the LLM backend for summaries and language work in the modules.
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

```sh
# Orchestrator + CLI tools
install -m 755 bin/*            ~/.local/bin/

# Enrichment modules
mkdir -p ~/.local/share/meeting-modules
cp modules/*                    ~/.local/share/meeting-modules/
chmod +x ~/.local/share/meeting-modules/[0-9]*

# OBS Lua hook + track merger
mkdir -p ~/.local/share/obs-scripts
cp obs/meeting-notify.lua obs/merge-tracks.py ~/.local/share/obs-scripts/

# Calendar matcher (Swift EventKit) — compile once
mkdir -p ~/.local/share/meeting-tools/calendar
swiftc tools/calendar/calquery.swift -o ~/.local/share/meeting-tools/calendar/calquery
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
