#!/usr/bin/env python3
"""Merge two Whisper SRT files (mic = "You", meeting = "Participants") into a
single speaker-labelled transcript, ordered by timestamp.

Usage: merge-tracks.py you.srt participants.srt out.txt
Empty/missing inputs are tolerated (a silent track just contributes nothing).
"""
import re
import sys


def parse_srt(path, speaker):
    segs = []
    try:
        with open(path, encoding="utf-8") as fh:
            blocks = re.split(r"\n\s*\n", fh.read().strip())
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


def main():
    you_srt, part_srt, out = sys.argv[1], sys.argv[2], sys.argv[3]
    segs = parse_srt(you_srt, "You") + parse_srt(part_srt, "Participants")
    segs.sort(key=lambda x: x[0])
    with open(out, "w", encoding="utf-8") as fh:
        for start, speaker, text in segs:
            fh.write("[%s] %s: %s\n" % (hms(start), speaker, text))


if __name__ == "__main__":
    main()
