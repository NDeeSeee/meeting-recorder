# Meeting enrichment module contract

`meeting-process` transcribes a recording and writes a Claude summary. Everything
else is a **module**: an independent executable in this directory, run in
filename order against each meeting after the transcript + summary exist.

## Invocation

    <module> <MEETING_DIR>

The module is also given these environment variables:

| Variable          | Meaning                                                        |
|-------------------|----------------------------------------------------------------|
| `MEETING_DIR`     | The meeting folder (same as `$1`)                              |
| `MEETING_MKV`     | Absolute path to the recording                                 |
| `MEETING_BASE`    | Filename stem, e.g. `2026-07-14_12-33_meeting`                 |
| `MEETING_TXT`     | Speaker-labelled transcript (guaranteed non-empty)             |
| `MEETING_SRT`     | Subtitles for the participants track (may be empty/absent)     |
| `MEETING_SUMMARY` | Claude summary markdown (guaranteed non-empty)                 |
| `MEETING_ROOT`    | The Meetings root folder (all meetings live here)              |
| `MEETING_TOOLS`   | `~/.local/share/meeting-tools` — shared venvs/models/state     |
| `OBSIDIAN_VAULT`  | `~/Documents/Obsidian Vault`                                   |
| `MEETING_LOG`     | Pipeline log path (stdout/stderr are already appended to it)   |

## Transcript format

Lines look like:

    [00:01:47] Participants: And so, okay, two weeks.
    [00:01:57] You: When?

`You` = the person recording (microphone track). `Participants` = everyone else
(system-audio track). Timestamps are `HH:MM:SS` from the start of the recording.

## Rules

1. **Idempotent.** If your output already exists, exit 0 immediately. The
   pipeline re-runs over every meeting on every invocation.
2. **Never destroy.** Do not modify `MEETING_TXT`, `MEETING_SRT` or
   `MEETING_SUMMARY`. Write new files.

   `MEETING_MKV` may be rewritten ONLY to add metadata (e.g. chapter markers),
   and only under all of these conditions — the recording is irreplaceable:
   - stream-copy only (`-codec copy`), never a re-encode;
   - write to a temp file, then verify with ffprobe that the result has the same
     duration and the *same audio streams INCLUDING their titles* ("Microphone",
     "Meeting audio", ...) — downstream speaker separation depends on those
     labels, and a codec-only check will not notice them being dropped;
   - bound the ffmpeg call with a timeout;
   - only then `os.replace` it into place, atomically, within the same directory;
   - on ANY failure or mismatch, leave the original untouched.
3. **Fail soft.** Exit non-zero on real errors (the orchestrator logs and
   continues), but never leave a half-written output file behind — write to a
   temp file and `mv` into place.
4. **Offline-first.** Prefer local tools. `claude -p` (the Claude CLI, reads
   stdin, writes stdout) is available for anything needing an LLM and is the
   preferred way to do language work.
5. **No prompts.** Modules run unattended from a background process. Never
   block on input.
6. **Cheap when done.** The idempotency check must not be expensive — check for
   the output file first, before doing any work.

## Available tooling

`ffmpeg`, `ffprobe`, `jq`, `python3` (3.14 — too new for torch), `uv` (use this
to create isolated venvs with a pinned older Python for ML deps), `whisper-cli`,
`claude`. Homebrew is at `/opt/homebrew`. Apple Silicon (arm64), Metal available.

Put any venv/model under `$MEETING_TOOLS/<yourname>/` and create it on first run
if missing (guard so it is only built once).

## Naming / order

Modules run in filename order. Reserved slots:

| Prefix | Module          | Purpose                                            |
|--------|-----------------|----------------------------------------------------|
| 10     | chapters        | Topical chapters with timestamps                   |
| 20     | actions         | Action items -> rolling global file                |
| 30     | insights        | Questions / decisions / commitments extraction     |
| 40     | slides          | Distinct screen-share frames -> contact sheet      |
| 50     | speakers        | Speaker diarization + naming of the participants   |
| 60     | threads         | Cross-meeting topic threading                      |
| 70     | calendar        | Match to a calendar event for real title/attendees |
| 80     | obsidian        | Write the Obsidian note (consumes all of the above)|
| 85     | index           | Semantic search index                              |
| 90     | title           | Rename folder to a content-based name (runs LAST)  |

If a module renames `MEETING_DIR`, it MUST write the new absolute path to
`$MEETING_ROOT/.last-rename` so the orchestrator can follow it.
