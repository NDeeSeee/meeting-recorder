# meeting-recorder

A fully local, privacy-first meeting recorder and intelligence pipeline for
macOS. Press one hotkey; when the meeting ends you get a speaker-labelled
transcript, a Claude-written summary, extracted decisions/actions, topical
chapters, a screen-share contact sheet, an Obsidian note, and a semantic search
index — with **no bot in the call and nothing sent to a third-party notetaker**.

It is a self-hosted alternative to tools like Granola: audio and video are
captured by OBS locally, transcription runs on-device with `whisper.cpp`, and the
only network call is to the Claude CLI for language work (which you control).

## How it works

```
        ⌃⌥⌘R (OBS global hotkey)
              │  start / stop
              ▼
  ┌───────────────────────────┐   multi-track .mkv
  │  OBS Studio                │   (mic + system audio via BlackHole,
  │  scene: "Meetings"         │    + screen video)
  │  + meeting-notify.lua      │
  └─────────────┬─────────────┘
                │ on "recording stopped", spawns (as an OBS child, so it
                │ inherits macOS privacy access to ~/Documents)
                ▼
  ┌───────────────────────────┐
  │  bin/meeting-process       │  1. discover finished recordings
  │                            │  2. whisper.cpp + Silero VAD  → transcript
  │                            │  3. mic vs system track       → speaker labels
  │                            │  4. claude -p                 → summary.md
  └─────────────┬─────────────┘
                │ then runs every executable in modules/ in filename order
                ▼
  10-chapters  20-actions  30-insights  40-slides  50-speakers  60-threads
  70-calendar  80-obsidian  85-index  90-title  95-route  99-mp4
```

Audio is captured on two tracks — your microphone (`You`) and everything else via
a **BlackHole** virtual output (`Participants`) — so speaker separation is a
track split, not fragile diarization. Silero VAD gates Whisper so it doesn't
hallucinate filler on silent stretches.

## Layout

| Path              | Installed to (runtime)                     | Contents                                    |
|-------------------|--------------------------------------------|---------------------------------------------|
| `bin/`            | `~/.local/bin/`                            | Orchestrator + CLI tools                     |
| `modules/`        | `~/.local/share/meeting-modules/`          | Enrichment modules (see `modules/README.md`) |
| `obs/`            | OBS scripts + `~/Library/Application Support/obs-studio/` | OBS Lua hook, scene, profile   |
| `tools/calendar/` | `~/.local/share/meeting-tools/calendar/`   | Swift EventKit calendar matcher              |
| `requirements/`   | two `uv`/`venv` envs under `meeting-tools/`| Pinned Python deps (transcription ML)        |

## Components

**`bin/`**
- `meeting-process` — the orchestrator (transcribe → summarize → run modules).
- `meeting-search` — semantic search across all past meetings (sentence-transformers).
- `meeting-name-speaker` — assign a real name to a diarized speaker cluster.
- `meeting-migrate` — move/organize meeting folders.
- `meeting-maintenance` — health checks and repair of the meeting corpus.

**`modules/`** — independent executables run in filename order; each reads the
transcript/summary and writes new artifacts. See `modules/README.md` for the full
contract (idempotent, fail-soft, never destroys the recording). Highlights:
`40-slides` extracts distinct screen-share frames into a contact sheet;
`80-obsidian` writes the note; `85-index` builds the semantic index;
`90-title` renames the folder to a content-based name.

## Setup

See **[docs/SETUP.md](docs/SETUP.md)** for the full install (Homebrew casks, models
to download, Python envs, OBS scene/hotkey configuration).

## Privacy

Everything stays on the machine except calls you make to the Claude CLI. Raw
recordings, transcripts, the semantic index, extracted entities, and your project
routing table are **excluded from version control** (see `.gitignore`) — this repo
is the *tooling*, not the data.

## Status

Personal tooling, shared as-is. macOS on Apple Silicon (arm64). No warranty.
