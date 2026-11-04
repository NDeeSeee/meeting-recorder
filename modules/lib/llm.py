"""Shared, hardened `claude -p` call for the meeting pipeline (and write_atomic).

Lives in modules/lib/, a subdirectory, and is not executable: the orchestrator
runs only plain executable files directly in the modules dir (`*(N.x)`), so it
is never mistaken for a module. Installed next to the modules, at
~/.local/share/meeting-modules/lib/llm.py.

Why every LLM call goes through here
------------------------------------
Transcript text is spoken by other people, so it is untrusted input. A bare
`claude -p` runs a full agent: Bash, every MCP server in the user's config
(Gmail send, Drive, Slack), plugins and hooks, and it persists the whole
transcript into ~/.claude/projects. It also loads 45-60k tokens of tool
definitions for what is often a 30-token answer. The invocation below turns all
of that off (each flag was checked against `claude --help`, v2.1.318):

  --tools ''                     no built-in tools at all
  --strict-mcp-config            ignore every MCP config except ...
  --mcp-config '{"mcpServers":{}}'   ... this empty one
  --setting-sources ''           no user/project/local settings, so no plugins
                                 or plugin hooks (claude-mem once injected a
                                 "Memory outage" notice into a summary)
  --no-session-persistence       no transcript copy under ~/.claude/projects
  --disable-slash-commands       no skills
  --permission-prompts none      anything that would prompt is denied
  --output-format json           is_error/subtype/usage/cost for the ledger

`--max-turns` is NOT used: this CLI version does not list it, and an unknown
flag would break every call. With no tools there is nothing to loop on anyway.

The working directory is an empty private directory under $TMPDIR, so no
CLAUDE.md is discovered and the session cannot see the meeting folder.

Model: skipping the user settings would also drop the user's chosen default
model and effort, silently changing which model writes the summaries. So unless
MEETING_LLM_MODEL (or MEETING_LLM_MODEL_<TASK>, e.g. MEETING_LLM_MODEL_TITLE)
is set, the `model` and `effortLevel` from ~/.claude/settings.json are passed
explicitly — the same model as before hardening.

Usage from Python (modules put this directory on sys.path):
    import llm
    r = llm.call(prompt, stdin_text=transcript, task="chapters",
                 schema=SCHEMA, timeout=900, archive_dir=meeting_dir + "/.llm")
    if r.ok: r.text / r.structured

Usage from shell:
    python3 lib/llm.py call --task title --prompt '...' --stdin FILE \
        [--schema JSON] [--timeout SECS] [--archive-dir DIR] [--model M] \
        [--no-refusal-check] [--meeting LABEL]
  stdout: the reply text, or the structured JSON object when --schema is given.
  exit:   0 ok, 3 reply rejected (error/refusal/no structured output),
          124 timed out, 127 claude not found, 1 other failure, 2 usage.
  stderr: one diagnostic line on failure; the full raw reply is archived to
          --archive-dir as <task>-llm-<ts>.txt, or appended to stderr when no
          archive dir is given.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

EMPTY_MCP = '{"mcpServers":{}}'
HARDENED_FLAGS = [
    "--tools", "",
    "--strict-mcp-config", "--mcp-config", EMPTY_MCP,
    "--setting-sources", "",
    "--no-session-persistence",
    "--disable-slash-commands",
    "--permission-prompts", "none",
    "--output-format", "json",
]
EFFORT_LEVELS = {"low", "medium", "high", "xhigh", "max"}

# API errors worth one more try after a pause; anything else fails at once.
TRANSIENT_STATUS = {408, 429, 500, 502, 503, 504, 529}
TRANSIENT_TEXT = re.compile(r"overloaded|rate.?limit|timed? ?out|ECONNRESET|ETIMEDOUT|socket hang up", re.I)

# Lead-in phrases that mean "this is not an answer". Only the text before the
# first Markdown heading / JSON bracket is screened, so a real answer may still
# quote someone saying "I won't". Mirrors summary_problem in meeting-process.
REFUSAL = re.compile(
    r"api error|execution error|prompt is too long|credit balance|invalid api key|/login|"
    r"usage limit|safety check|memory outage|claude-mem|i won't|i can't help|i cannot help|"
    r"i'm unable to|i am unable to", re.I)

ARCHIVE_KEEP = 10  # rejected replies kept per task per meeting


class Result:
    def __init__(self, ok, rc, text="", structured=None, reason="", raw="", stderr="", meta=None):
        self.ok, self.rc, self.text, self.structured = ok, rc, text, structured
        self.reason, self.raw, self.stderr, self.meta = reason, raw, stderr, meta or {}

    def __repr__(self):
        return f"Result(ok={self.ok}, rc={self.rc}, reason={self.reason!r})"


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def write_atomic(path, text, mode=0o644):
    """Write text to path via a same-directory temp file + rename.

    mkstemp creates 0600 files; outputs are meant to be readable like every
    other file in the meeting folder, hence the explicit chmod.
    """
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=f".{os.path.basename(path)}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def claude_bin():
    """The pipeline's PATH may omit ~/.local/bin, where claude is installed."""
    found = shutil.which("claude")
    if found:
        return found
    fallback = os.path.expanduser("~/.local/bin/claude")
    return fallback if os.access(fallback, os.X_OK) else None


def _user_defaults():
    """model / effortLevel from the user's settings.json — what a plain
    `claude -p` used. Read at call time so a settings change still applies."""
    try:
        with open(os.path.expanduser("~/.claude/settings.json"), encoding="utf-8") as fh:
            s = json.load(fh)
    except (OSError, ValueError):
        return None, None
    model = s.get("model") if isinstance(s.get("model"), str) and s.get("model").strip() else None
    effort = s.get("effortLevel") if s.get("effortLevel") in EFFORT_LEVELS else None
    return model, effort


def resolve_model(task, explicit=None):
    """(model, effort) for a task. Precedence: explicit argument,
    MEETING_LLM_MODEL_<TASK>, MEETING_LLM_MODEL, then the user's settings."""
    user_model, user_effort = _user_defaults()
    key = "MEETING_LLM_MODEL_" + re.sub(r"[^A-Z0-9]", "_", (task or "").upper())
    model = explicit or os.environ.get(key) or os.environ.get("MEETING_LLM_MODEL") or user_model
    effort = os.environ.get("MEETING_LLM_EFFORT") or user_effort
    if effort not in EFFORT_LEVELS:
        effort = None
    return model, effort


def _empty_cwd():
    """A private directory that is guaranteed empty.

    One stable directory rather than a fresh one per call: the CLI creates a
    (small) ~/.claude/projects/<cwd> entry per working directory, and a new
    temp dir per call would leave hundreds of them behind.
    """
    d = os.path.join(tempfile.gettempdir(), f"meeting-llm-cwd-{os.getuid()}")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        st = os.lstat(d)
        if (os.path.isdir(d) and not os.path.islink(d) and st.st_uid == os.getuid()
                and not os.listdir(d)):
            return d, False
    except OSError:
        pass
    return tempfile.mkdtemp(prefix="meeting-llm-cwd-"), True


def _tools_dir():
    return os.environ.get("MEETING_TOOLS") or os.path.expanduser("~/.local/share/meeting-tools")


def _ledger(entry):
    """Append one JSON line per call; never let accounting break a call."""
    try:
        d = os.path.join(_tools_dir(), "llm")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "ledger.jsonl")
        fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _archive(archive_dir, task, res, cmd_desc):
    """Keep a rejected reply (stdout + stderr + rc) for diagnosis, rotated."""
    if not archive_dir:
        return None
    try:
        os.makedirs(archive_dir, mode=0o700, exist_ok=True)
        # "-llm-" (not "-rejected-"): meeting-process archives its own
        # validation rejections as summary-rejected-<ts>.txt in the same dir.
        p = os.path.join(archive_dir, f"{task}-llm-{int(time.time())}.txt")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(f"# task={task} rc={res.rc} reason={res.reason}\n# cmd={cmd_desc}\n")
            fh.write("# --- stderr ---\n" + (res.stderr or "") + "\n# --- stdout ---\n" + (res.raw or "") + "\n")
        old = sorted(f for f in os.listdir(archive_dir) if f.startswith(f"{task}-llm-"))
        for f in old[:-ARCHIVE_KEEP]:
            os.remove(os.path.join(archive_dir, f))
        return p
    except OSError:
        return None


def _lead_in(text):
    out = []
    for line in text.splitlines():
        s = line.lstrip()
        if s.startswith(("#", "{", "[")):
            break
        out.append(line)
    return "\n".join(out)


def looks_like_refusal(text):
    return bool(REFUSAL.search(_lead_in(text or "")[:600]))


# --------------------------------------------------------------------------
# the call
# --------------------------------------------------------------------------

def _run_once(cmd, stdin_text, timeout, cwd):
    """Run claude in its own process group so a timeout (or our own TERM)
    kills everything it started, not just the top process."""
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, cwd=cwd,
                            env=_child_env(), start_new_session=True)

    def _kill_group():
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    # The orchestrator stops a module with SIGTERM to *its* process group; the
    # claude child is in a new session, so forward the stop explicitly.
    prev = {}

    def _on_signal(signum, _frame):
        _kill_group()
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            prev[sig] = signal.signal(sig, _on_signal)
        except (ValueError, OSError):  # not the main thread
            pass
    try:
        out, err = proc.communicate(stdin_text or "", timeout=timeout)
        return proc.returncode, out, err, False
    except subprocess.TimeoutExpired:
        _kill_group()
        out, err = proc.communicate()
        return 124, out or "", err or "", True
    finally:
        for sig, h in prev.items():
            signal.signal(sig, h)


def _child_env():
    env = dict(os.environ)
    # When run from inside a Claude Code session (testing), do not let the
    # child think it is nested in it.
    env.pop("CLAUDECODE", None)
    return env


def _parse(rc, out, err, timed_out, schema, refusal_check):
    """Turn one CLI run into a Result."""
    if timed_out:
        return Result(False, 124, reason="timed out", raw=out, stderr=err)
    try:
        j = json.loads(out) if out.strip() else None
    except ValueError:
        j = None
    if not isinstance(j, dict):
        # Not the JSON envelope: an auth/CLI error printed as text, or a crash.
        why = f"claude exited {rc}" if rc else "reply was not a JSON envelope"
        return Result(False, rc or 1, reason=why, raw=out, stderr=err)

    meta = {k: j.get(k) for k in ("is_error", "subtype", "num_turns", "total_cost_usd",
                                  "api_error_status", "duration_ms", "stop_reason", "safety_stops")}
    meta["models"] = sorted((j.get("modelUsage") or {}).keys())
    u = j.get("usage") or {}
    meta["tokens"] = {k: u.get(k) for k in ("input_tokens", "cache_creation_input_tokens",
                                            "cache_read_input_tokens", "output_tokens")}
    result = j.get("result")
    text = result if isinstance(result, str) else ""
    structured = j.get("structured_output")

    if j.get("is_error") or rc:
        why = f"claude error ({j.get('subtype')}, api status {j.get('api_error_status')}): {text[:160]}"
        return Result(False, rc or 3, text=text, reason=why, raw=out, stderr=err, meta=meta)
    if schema is not None:
        if structured is None:
            # Older CLI or the model skipped the structured channel: accept the
            # text only if it is itself the JSON object.
            try:
                structured = json.loads(text.strip())
            except ValueError:
                return Result(False, 3, text=text, reason="no structured output",
                              raw=out, stderr=err, meta=meta)
        return Result(True, 0, text=json.dumps(structured, ensure_ascii=False),
                      structured=structured, raw=out, stderr=err, meta=meta)
    if not text.strip():
        return Result(False, 3, reason="empty reply", raw=out, stderr=err, meta=meta)
    if refusal_check and looks_like_refusal(text):
        return Result(False, 3, text=text, reason="refusal or error text: " + _lead_in(text)[:120],
                      raw=out, stderr=err, meta=meta)
    return Result(True, 0, text=text, raw=out, stderr=err, meta=meta)


def _transient(res):
    if res.ok or res.rc == 124:
        return False
    if res.meta.get("api_error_status") in TRANSIENT_STATUS:
        return True
    return bool(TRANSIENT_TEXT.search((res.reason or "") + " " + (res.stderr or "")[-400:]))


def call(prompt, stdin_text="", task="llm", schema=None, timeout=600, model=None,
         archive_dir=None, retries=1, backoff=30, refusal_check=True, meeting=None):
    """One hardened `claude -p` call. Never raises for model/CLI failures.

    retries/backoff apply only to transient API errors (overload, rate limit,
    5xx); a malformed answer is the caller's to retry with a firmer prompt.
    """
    exe = claude_bin()
    if not exe:
        return Result(False, 127, reason="claude CLI not found on PATH or in ~/.local/bin")
    mdl, effort = resolve_model(task, model)
    cmd = [exe, "-p", prompt, *HARDENED_FLAGS]
    if mdl:
        cmd += ["--model", mdl]
    if effort:
        cmd += ["--effort", effort]
    if schema is not None:
        cmd += ["--json-schema", schema if isinstance(schema, str) else json.dumps(schema)]
    cmd_desc = f"claude -p <prompt {len(prompt)} chars> hardened model={mdl} effort={effort} schema={schema is not None}"

    cwd, cwd_is_temp = _empty_cwd()
    deadline = time.monotonic() + timeout
    attempt = 0
    try:
        while True:
            attempt += 1
            t0 = time.time()
            left = max(1.0, deadline - time.monotonic())
            rc, out, err, timed_out = _run_once(cmd, stdin_text, left, cwd)
            res = _parse(rc, out, err, timed_out, schema, refusal_check)
            _ledger({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "task": task,
                     "meeting": meeting or (os.path.basename(os.path.dirname(archive_dir)) if archive_dir else None),
                     "model_requested": mdl, "effort": effort, "attempt": attempt,
                     "ok": res.ok, "rc": res.rc, "reason": res.reason[:200],
                     "secs": round(time.time() - t0, 1), "stdin_chars": len(stdin_text or ""),
                     **res.meta})
            if res.ok or attempt > retries or not _transient(res):
                break
            if deadline - time.monotonic() < backoff + 30:
                break
            time.sleep(backoff * attempt)
    finally:
        if cwd_is_temp:
            shutil.rmtree(cwd, ignore_errors=True)
    if not res.ok:
        _archive(archive_dir, task, res, cmd_desc)
    return res


# --------------------------------------------------------------------------
# CLI (for the shell modules and meeting-process)
# --------------------------------------------------------------------------

def _main(argv):
    ap = argparse.ArgumentParser(prog="llm.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("call", help="one hardened claude -p call")
    c.add_argument("--task", required=True)
    g = c.add_mutually_exclusive_group(required=True)
    g.add_argument("--prompt")
    g.add_argument("--prompt-file")
    c.add_argument("--stdin", help="file whose content is sent on stdin ('-' = our stdin)")
    c.add_argument("--schema", help="JSON Schema string for structured output")
    c.add_argument("--timeout", type=int, default=600)
    c.add_argument("--retries", type=int, default=1)
    c.add_argument("--model")
    c.add_argument("--archive-dir")
    c.add_argument("--meeting", help="label for the ledger (default: from --archive-dir)")
    c.add_argument("--no-refusal-check", action="store_true")
    a = ap.parse_args(argv)

    try:
        if a.prompt_file:
            with open(a.prompt_file, encoding="utf-8", errors="replace") as fh:
                prompt = fh.read()
        else:
            prompt = a.prompt
        stdin_text = ""
        if a.stdin == "-":
            stdin_text = sys.stdin.read()
        elif a.stdin:
            with open(a.stdin, encoding="utf-8", errors="replace") as fh:
                stdin_text = fh.read()
        if a.schema:
            json.loads(a.schema)  # fail fast on a broken schema literal
    except (OSError, ValueError) as exc:
        print(f"llm[{a.task}]: bad input: {exc}", file=sys.stderr)
        return 2

    res = call(prompt, stdin_text=stdin_text, task=a.task, schema=a.schema,
               timeout=a.timeout, model=a.model, archive_dir=a.archive_dir,
               retries=a.retries, refusal_check=not a.no_refusal_check, meeting=a.meeting)
    if res.ok:
        sys.stdout.write(res.text if res.text.endswith("\n") else res.text + "\n")
        return 0
    first = (res.text or res.raw or res.stderr or "").replace("\n", " ")[:200]
    print(f"llm[{a.task}]: {res.reason} (rc={res.rc}) — first output: {first}", file=sys.stderr)
    if not a.archive_dir:
        # The caller keeps stderr (meeting-process archives it); give it the
        # whole reply so the failure can be diagnosed.
        sys.stderr.write("--- raw reply ---\n" + (res.raw or "")[:20000] + "\n--- claude stderr ---\n"
                         + (res.stderr or "")[:4000] + "\n")
    return res.rc if res.rc in (3, 124, 127) else 1


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
