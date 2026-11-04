# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A fully local macOS (Apple Silicon) meeting recorder + intelligence pipeline. OBS records meetings as multi-track `.mkv`; a Lua hook spawns `bin/meeting-process`, which transcribes with whisper.cpp (+ Silero VAD), separates speakers by audio track (mic = `You`, BlackHole system audio = `Participants` — not diarization), writes a Claude summary via the shared hardened `claude -p` helper (`modules/lib/llm.py`), then runs every executable file directly in `modules/` in filename order. This repo is the *tooling only*; recordings, transcripts, indexes, and routing tables are runtime data and must never be committed (see `.gitignore`).

## Critical: source vs. runtime split

Editing files here does NOT change the live pipeline. The code runs from installed copies:

| Source           | Runtime location                                |
|------------------|-------------------------------------------------|
| `bin/`           | `~/.local/bin/`                                 |
| `modules/`       | `~/.local/share/meeting-modules/`               |
| `modules/lib/`   | `~/.local/share/meeting-modules/lib/` (mode 644, never executable) |
| `obs/*.lua/.py`  | `~/.local/share/obs-scripts/`                   |
| `tools/*.swift`  | `~/.local/bin/<name>` (compiled with `swiftc -O`: `meeting-display`, `display-asleep`) |
| `launchd/*.plist`| `~/Library/LaunchAgents/` (`USERNAME` substituted) |

After editing, reinstall the changed file (e.g. `install -m 755 bin/meeting-process ~/.local/bin/`, or `install -m 755 modules/40-slides ~/.local/share/meeting-modules/`; `install` replaces the file rather than rewriting a possibly running script in place). Keep the exec bit as it is in the repo: `20-actions`, `60-threads` and `bin/meeting-maintenance` are deliberately non-executable (disabled) until the owner enables them, so never use `install -m 755 bin/*` or `chmod +x modules/*`. Full install steps: `docs/SETUP.md`.

The EventKit helper `calquery` is built by `70-calendar` itself from the copy embedded in that module (into `~/.local/share/meeting-tools/calendar/`, rebuilt when the embedded source changes). `tools/calendar/calquery.swift` is an older standalone copy without `--check`; don't compile it over the module's binary.

Shared runtime state (venvs, models, caches) lives under `~/.local/share/meeting-tools/` (`$MEETING_TOOLS`). Meetings live in `~/Recordings/Meetings/`; the pipeline log is `~/Library/Logs/meeting-process.log`.

## Commands

There is no build system or test suite. Everything is zsh/bash/Python scripts.

```sh
# Syntax-check after editing (match the file's interpreter — see its shebang)
zsh -n bin/meeting-process
bash -n modules/50-speakers
python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' modules/80-obsidian   # writes nothing; -m py_compile leaves modules/__pycache__ behind
swiftc -typecheck tools/meeting-display.swift
luajit -bl obs/meeting-notify.lua >/dev/null   # luac is not installed

# Run the whole pipeline manually (idempotent; finished meetings are skipped via .pipeline-done)
meeting-process            # or run a single module: <module> <MEETING_DIR>
MEETING_RESCAN=1 meeting-process   # ignore .pipeline-done stamps and re-run modules everywhere

# Dry-run the OBS watchdog (logs what it would do; leaves its state file alone)
DRY_RUN=1 obs-watchdog

# Watch a live run
tail -f ~/Library/Logs/meeting-process.log

# Other CLIs
meeting-search "topic"     # semantic search over past meetings (--rerank goes through lib/llm.py)
meeting-canary --check X.mkv   # one read-only capture-health check of a recording, JSON to stdout
meeting-maintenance        # corpus health checks / repair (repo copy is non-executable: owner decision pending)
meeting-name-speaker       # attach a real name to a speaker cluster

# Rebuild the two ML venvs (Python 3.12 pinned via uv; 3.14 is too new for torch)
uv venv --python 3.12 ~/.local/share/meeting-tools/index/venv
uv pip install --python ~/.local/share/meeting-tools/index/venv/bin/python -r requirements/index.txt
# (same pattern with speakers/venv + requirements/speakers.txt)
```

## Module contract (modules/README.md — read it before touching a module)

Modules are independent executables invoked as `<module> <MEETING_DIR>` with env vars `MEETING_DIR`, `MEETING_MKV`, `MEETING_BASE`, `MEETING_TXT`, `MEETING_SRT`, `MEETING_SUMMARY`, `MEETING_ROOT`, `MEETING_TOOLS`, `OBSIDIAN_VAULT`, `MEETING_LOG` (plus informational `MEETING_MEDIA_OFFLINE`, `MEETING_FREE_KB`). Non-negotiable rules:

1. **Idempotent, and cheap when done** — check for your output file first and exit 0 before doing any work; the orchestrator re-runs every module whenever a meeting's inputs or the installed module set change (`.pipeline-done` stores both).
2. **Never destroy** — never modify `MEETING_TXT`/`MEETING_SRT`/`MEETING_SUMMARY`; write new files. `MEETING_MKV` may be rewritten only via stream-copy to a temp file, verified with ffprobe (same duration AND same audio stream titles — speaker separation depends on those labels), then atomically `os.replace`d.
3. **Fail soft** — exit non-zero on error, but never leave half-written outputs: write to a temp file, then `mv` into place.
4. **Offline-first, no prompts** — runs unattended. Every LLM call goes through `modules/lib/llm.py` (no tools/MCP/plugins, no session persistence, bounded timeout, ledger at `$MEETING_TOOLS/llm/ledger.jsonl`); never call bare `claude -p`. The default model is the user's `~/.claude/settings.json` model; `MEETING_LLM_MODEL` / `MEETING_LLM_MODEL_<TASK>` / `MEETING_LLM_EFFORT` override it.
5. Modules run in filename order (10-chapters … 95-route; there is deliberately no `99-mp4`). Only plain executable files directly in the modules dir run (`*(N.x)`), so `lib/` and `README.md` are ignored. `90-title` renames the folder and any renamer must write the new path to `$MEETING_ROOT/.last-rename`.
6. Per-module venvs/models go under `$MEETING_TOOLS/<yourname>/`, created on first run.

Transcript lines look like `[00:01:47] Participants: …` / `[00:01:57] You: …`.

## Architecture notes that span files

- **Why OBS spawns the pipeline** (`obs/meeting-notify.lua`): a launchd agent is blocked by macOS privacy from `~/Documents`; a child of OBS inherits OBS's access. Don't "fix" this by moving to launchd.
- **Meeting discovery** (`bin/meeting-process`): a folder is a meeting if it has a `.meeting` marker or matches OBS's `*_meeting` naming. The marker is what allows `90-title` to rename folders without losing them. Guards: file-size-stable-for-10s check (OBS still writing), `MIN_DURATION=60` (accidental hotkey taps get a `.too-short` marker instead of a full pipeline run), and a self-healing PID lock at `$MEET_ROOT/.processing.lock`.
- **Speaker separation is track-based**: mic and system audio are separate `.mkv` tracks with titled streams; `50-speakers` adds diarization within the participants track. Anything that touches the mkv or ffmpeg invocations must preserve track titles.
- **Capture health** (`bin/meeting-canary`, spawned detached by the Lua hook at record start and on unpause): checks the growing `.mkv` for black/frozen/silent capture and writes `<meeting>/.capture-health.json` (`"file"` names the recording it judges; `"warned"` is cumulative). `bin/meeting-process` reads it only to avoid a duplicate black-video banner; its own `.video-qc` / `.video-black` markers drive the summary banner.
- **Display selection** (`obs/meeting-notify.lua` + `tools/meeting-display.swift`): file contract under `~/Library/Logs/` — `meeting-notify.display` (Lua → helper: sources, visibility, recording), `meeting-notify.display-request` (helper → Lua: one source name; the Lua claims it by rename), `meeting-notify.display-online` (helper → Lua: `{"online":[UUIDs],"main":UUID,"updated":epoch}`). Both sides pick preferred-if-online, else the main display, else any online one; missing/stale online data never causes a switch.
- Whisper model paths are hardcoded in `bin/meeting-process` (`~/.local/share/whisper/ggml-large-v3-turbo.bin` + Silero VAD model; VAD is optional but prevents hallucinated filler on silent stretches).
- `bin/audio-output-active` is a prebuilt Swift helper whose source is not tracked; the pipeline degrades gracefully without it.
