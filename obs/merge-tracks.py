#!/usr/bin/env python3
"""Merge two Whisper SRT files (mic = "You", meeting = "Participants") into a
single speaker-labelled transcript, ordered by timestamp.

Usage: merge-tracks.py you.srt participants.srt out.txt
Empty/missing inputs are tolerated (a silent track just contributes nothing).

The output is written to a temp file beside out.txt and renamed into place, so
a crash never leaves a partial transcript that the pipeline would mistake for a
finished one. Exit status: 0 on success (even if no speech was found — the
caller checks for an empty file), 2 on bad usage, 1 on any I/O error.
"""
import os
import re
import sys
import tempfile


def parse_srt(path, speaker):
    segs = []
    try:
        # errors="replace": Whisper can cut a multi-byte character at a segment
        # boundary; one bad byte must not cost the whole transcript.
        with open(path, encoding="utf-8", errors="replace") as fh:
            blocks = re.split(r"\n\s*\n", fh.read().replace("\r\n", "\n").strip())
    except FileNotFoundError:
        return segs
    for b in blocks:
        lines = [l for l in b.splitlines() if l.strip()]
        if len(lines) < 2:
            continue
        m = re.search(r"(\d\d):(\d\d):(\d\d)[,.](\d+)\s*-->", b)
        if not m:
            continue
        h, mm, s, ms = (int(x) for x in m.groups())
        start = h * 3600 + mm * 60 + s + ms / 1000.0
        # Text is every line after the timestamp line.
        idx = next(i for i, l in enumerate(lines) if "-->" in l)
        text = " ".join(lines[idx + 1:]).strip()
        if text:
            segs.append((start, speaker, text))
    return segs


def hms(t):
    return "%02d:%02d:%02d" % (t // 3600, (t % 3600) // 60, t % 60)


def write_atomic(path, data):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.chmod(tmp, 0o644)  # mkstemp creates 0600; match a normal file
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main():
    if len(sys.argv) != 4:
        doc = (__doc__ or "").strip().splitlines()
        print(doc[3] if len(doc) > 3 else "usage: merge-tracks.py YOU.srt PART.srt OUT", file=sys.stderr)
        return 2
    you_srt, part_srt, out = sys.argv[1], sys.argv[2], sys.argv[3]
    segs = parse_srt(you_srt, "You") + parse_srt(part_srt, "Participants")
    segs.sort(key=lambda x: x[0])
    try:
        write_atomic(out, "".join("[%s] %s: %s\n" % (hms(st), sp, tx) for st, sp, tx in segs))
    except OSError as e:
        print("merge-tracks: cannot write %s: %s" % (out, e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
