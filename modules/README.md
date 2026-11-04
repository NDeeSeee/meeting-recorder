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
| `MEETING_MEDIA_OFFLINE` | `1` if `MEETING_MKV` is unreachable (e.g. unmounted archive volume), else `0` |
| `MEETING_FREE_KB` | Free space on the Meetings volume at the start of this pass, in KiB |

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
4. **Offline-first.** Prefer local tools. For anything needing an LLM, go
   through the shared helper `lib/llm.py` (see "Shared helpers" below), never a
   bare `claude -p`: transcripts are other people's speech, and a bare call runs
   a full agent with tools, MCP servers and plugins, and keeps a copy of the
   transcript under `~/.claude/projects`.
5. **No prompts.** Modules run unattended from a background process. Never
   block on input.
6. **Cheap when done.** The idempotency check must not be expensive — check for
   the output file first, before doing any work.
7. **Record deterministic skips.** If a meeting can never produce your output
   (black video, no participants track, no timestamps, Calendar access denied),
   write a small marker and honour it in the idempotency check, so the next pass
   does not repeat the expensive work only to give up again. Key the marker on
   its input when that input can change (e.g. the SRT's mtime). Never write a
   marker for a transient condition: recording offline, network or model
   missing, a tool error.
8. **Leave the folder alone when there is nothing to do.** Do not create and
   delete temp files inside `MEETING_DIR` on a pass that publishes nothing: it
   bumps the folder's mtime on every run. Use `$TMPDIR` for scratch, and stage
   inside `MEETING_DIR` only to publish a finished output atomically.

### Skip markers in use

| Marker (in `MEETING_DIR` unless noted) | Module      | Meaning                                                     |
|----------------------------------------|-------------|-------------------------------------------------------------|
| `.slides-status` (JSON)                | 40-slides   | `black` / `no-candidates` / `no-video` / `too-short`: no slides |
| `.speakers-skip`                       | 50-speakers | Nothing to diarize; line 1 keys it to the SRT's mtime:size  |
| `$MEETING_TOOLS/calendar/denied`       | 70-calendar | Calendar access missing; for 24 h each meeting only runs an instant `calquery --check` and skips unless access is now granted. Skipped meetings are stamped done by the orchestrator: after granting, run `MEETING_RESCAN=1 meeting-process` once |
| `$MEETING_TOOLS/index/state.json` `chunks:0` | 85-index | Neither transcript nor SRT has timestamped lines        |

Delete a marker to force that module to retry.

A module may also need the recording when it is offline (e.g. a symlink into an
unmounted archive volume). Treat that as transient: exit 0 without a marker, and
do not log it as a failure when your files already exist (see 10-chapters).

## Shared helpers (`lib/`)

`lib/` holds shared, **non-executable** code (mode 644), installed to
`~/.local/share/meeting-modules/lib/`. The orchestrator only runs plain
executable files directly in this directory (`*(N.x)`), so nothing in `lib/`
is ever run as a module, and it is not part of the module-set signature in
`.pipeline-done`.

`lib/llm.py` is the one hardened `claude -p` call (no tools, no MCP, no
plugins, no session persistence, private empty cwd, bounded timeout, one retry
on overload, a ledger line per call in `$MEETING_TOOLS/llm/ledger.jsonl`):

    # Python: sys.path.insert(0, <this module's dir>/lib); import llm
    r = llm.call(prompt, stdin_text=..., task="chapters", schema=SCHEMA,
                 timeout=900, archive_dir=meeting_dir + "/.llm")
    # shell:
    python3 "${0:A:h}/lib/llm.py" call --task title --prompt '...' --stdin FILE \
        [--schema JSON] [--timeout SECS] [--archive-dir "$MEETING_DIR/.llm"]

It also provides `write_atomic(path, text, mode=0o644)`. Exit codes, model
overrides (`MEETING_LLM_MODEL`, `MEETING_LLM_MODEL_<TASK>`,
`MEETING_LLM_EFFORT`) and details are in its docstring.

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
| 90     | title           | Rename folder to a content-based name              |
| 95     | route           | Symlink views by project/person/thread (follows the rename) |

There is deliberately no MP4 module. The former `99-mp4` remuxed every
recording on every pass and never kept a file (the MP4 muxer drops the audio
track titles, so its own verification always failed). `meeting-maintenance`
owns the archive format. For a QuickTime-playable copy on demand, remux outside
the meeting folder, e.g.
`ffmpeg -i <base>.mkv -map 0:v -map 0:a -c copy "$TMPDIR/<base>.mp4"`.

If a module renames `MEETING_DIR`, it MUST write the new absolute path to
`$MEETING_ROOT/.last-rename` so the orchestrator can follow it.
