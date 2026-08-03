# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A fully local macOS (Apple Silicon) meeting recorder + intelligence pipeline. OBS records meetings as multi-track `.mkv`; a Lua hook spawns `bin/meeting-process`, which transcribes with whisper.cpp (+ Silero VAD), separates speakers by audio track (mic = `You`, BlackHole system audio = `Participants` — not diarization), writes a Claude summary via `claude -p`, then runs every executable in `modules/` in filename order. This repo is the *tooling only*; recordings, transcripts, indexes, and routing tables are runtime data and must never be committed (see `.gitignore`).

## Critical: source vs. runtime split

Editing files here does NOT change the live pipeline. The code runs from installed copies:

| Source           | Runtime location                                |
|------------------|-------------------------------------------------|
| `bin/`           | `~/.local/bin/`                                 |
| `modules/`       | `~/.local/share/meeting-modules/`               |
| `obs/*.lua/.py`  | `~/.local/share/obs-scripts/`                   |
| `tools/calendar/`| `~/.local/share/meeting-tools/calendar/` (compiled with `swiftc`) |

After editing, reinstall the changed file (e.g. `install -m 755 bin/meeting-process ~/.local/bin/`, or `cp modules/40-slides ~/.local/share/meeting-modules/`). Full install steps: `docs/SETUP.md`.

Shared runtime state (venvs, models, caches) lives under `~/.local/share/meeting-tools/` (`$MEETING_TOOLS`). Meetings live in `~/Recordings/Meetings/`; the pipeline log is `~/Library/Logs/meeting-process.log`.

## Commands

There is no build system or test suite. Everything is zsh/bash/Python scripts.

```sh
# Syntax-check after editing (match the file's interpreter — see its shebang)
zsh -n bin/meeting-process
bash -n modules/50-speakers
python3 -m py_compile modules/80-obsidian

# Run the whole pipeline manually (idempotent; re-scans all meetings)
meeting-process            # or run a single module: <module> <MEETING_DIR>

# Watch a live run
tail -f ~/Library/Logs/meeting-process.log

# Other CLIs
meeting-search "topic"     # semantic search over past meetings
meeting-maintenance        # corpus health checks / repair
meeting-name-speaker       # attach a real name to a speaker cluster

# Rebuild the two ML venvs (Python 3.12 pinned via uv; 3.14 is too new for torch)
uv venv --python 3.12 ~/.local/share/meeting-tools/index/venv
uv pip install --python ~/.local/share/meeting-tools/index/venv/bin/python -r requirements/index.txt
# (same pattern with speakers/venv + requirements/speakers.txt)
```

## Module contract (modules/README.md — read it before touching a module)

Modules are independent executables invoked as `<module> <MEETING_DIR>` with env vars `MEETING_DIR`, `MEETING_MKV`, `MEETING_BASE`, `MEETING_TXT`, `MEETING_SRT`, `MEETING_SUMMARY`, `MEETING_ROOT`, `MEETING_TOOLS`, `OBSIDIAN_VAULT`, `MEETING_LOG`. Non-negotiable rules:

1. **Idempotent, and cheap when done** — check for your output file first and exit 0 before doing any work; the orchestrator re-runs everything on every invocation.
2. **Never destroy** — never modify `MEETING_TXT`/`MEETING_SRT`/`MEETING_SUMMARY`; write new files. `MEETING_MKV` may be rewritten only via stream-copy to a temp file, verified with ffprobe (same duration AND same audio stream titles — speaker separation depends on those labels), then atomically `os.replace`d.
3. **Fail soft** — exit non-zero on error, but never leave half-written outputs: write to a temp file, then `mv` into place.
4. **Offline-first, no prompts** — runs unattended; `claude -p` (stdin→stdout) is the sanctioned LLM call.
5. Modules run in filename order (10-chapters … 99-mp4); `90-title` renames the folder last and any renamer must write the new path to `$MEETING_ROOT/.last-rename`.
6. Per-module venvs/models go under `$MEETING_TOOLS/<yourname>/`, created on first run.

Transcript lines look like `[00:01:47] Participants: …` / `[00:01:57] You: …`.

## Architecture notes that span files

- **Why OBS spawns the pipeline** (`obs/meeting-notify.lua`): a launchd agent is blocked by macOS privacy from `~/Documents`; a child of OBS inherits OBS's access. Don't "fix" this by moving to launchd.
- **Meeting discovery** (`bin/meeting-process`): a folder is a meeting if it has a `.meeting` marker or matches OBS's `*_meeting` naming. The marker is what allows `90-title` to rename folders without losing them. Guards: file-size-stable-for-10s check (OBS still writing), `MIN_DURATION=60` (accidental hotkey taps get a `.too-short` marker instead of a full pipeline run), and a self-healing PID lock at `$MEET_ROOT/.processing.lock`.
- **Speaker separation is track-based**: mic and system audio are separate `.mkv` tracks with titled streams; `50-speakers` adds diarization within the participants track. Anything that touches the mkv or ffmpeg invocations must preserve track titles.
- Whisper model paths are hardcoded in `bin/meeting-process` (`~/.local/share/whisper/ggml-large-v3-turbo.bin` + Silero VAD model; VAD is optional but prevents hallucinated filler on silent stretches).
- `bin/audio-output-active` is a prebuilt Swift helper whose source is not tracked; the pipeline degrades gracefully without it.
