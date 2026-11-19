#!/usr/bin/env python3
"""Does the installed Claude Code still work the way Xylem expects?

    make check-claude

Runs the real claude a few times in a throwaway folder (cheap Haiku turns,
about a cent), captures its hook events, terminal output and transcripts,
then has Xylem's own parsers judge the result (XylemTests/
ClaudeCompatibilityTests.swift, via xcodebuild) and prints one line per
check: which Xylem feature is fine, broken, or worth a look.

Safe to run from inside a Xylem tab or a Claude Code session: the child
claude gets a clean environment, events go to a temp folder (never
~/.xylem/tab-events), keys go only to the claude this script started, and
cleanup removes only what this run created. The user's config is read, not
changed (Claude Code itself remembers the temp folder in .claude.json and
the typed prompts in its prompt history, as it does for any session).

Options:
    --keep              keep the temp folder with everything captured
    --judge-only DIR    judge an earlier capture again (no claude run)
    --no-app            skip the xcodebuild stage
CLAUDE_BIN=/path/to/claude overrides which claude is tested.
"""

import argparse
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import fcntl
import termios

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED_DATA = "/tmp/xylem-dd-tests"
LAST_PASS_FILE = os.path.join(REPO, ".claude-check-last-pass")
HOOK_EVENTS_FALLBACK = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                        "Stop", "Notification", "SessionEnd"]
# Flags every tab's claude is started with.
REQUIRED_FLAGS = ["--session-id", "--resume", "--fork-session", "--settings"]
STREAM_MIN_BATCHES = 5      # ClaudeTabState.streamMinBatches
STREAM_WINDOW = 1.5         # ClaudeTabState.streamWindow
TIME_LIMIT = 300            # seconds for every claude run together
RUNNING = []                # interactive claude still open, for the time limit

USE_COLOR = sys.stdout.isatty()


class OutOfTime(BaseException):
    """The overall time limit; not an OSError, so no I/O handler eats it."""


def color(code, text):
    return f"\033[{code}m{text}\033[0m" if USE_COLOR else text


results = []


def record(check_id, status, feature, detail):
    results.append({"id": check_id, "status": status, "feature": feature, "detail": detail})


def progress(text):
    print(color("2", "  " + text), flush=True)


# ---------------------------------------------------------------- environment

def login_shell_lookup():
    """claude path and CLAUDE_CONFIG_DIR as a tab's login shell sees them."""
    shell = os.environ.get("SHELL") or "/bin/zsh"
    script = 'printf "\\n@@XY@@%s@@%s@@\\n" "$(command -v claude)" "$CLAUDE_CONFIG_DIR"'
    # A temp file, not a pipe: a daemon an rc file starts can keep a pipe
    # open, and reading it to the end would wait for good.
    with tempfile.TemporaryFile(mode="w+") as out_file:
        try:
            subprocess.run([shell, "-l", "-i", "-c", script], stdout=out_file, stderr=subprocess.DEVNULL,
                           timeout=15, stdin=subprocess.DEVNULL, env=clean_env())
        except (subprocess.TimeoutExpired, OSError):
            pass
        out_file.seek(0)
        out = out_file.read()
    match = re.search(r"@@XY@@(.*?)@@(.*?)@@", out)
    if not match:
        return None, None
    return match.group(1).strip() or None, match.group(2).strip() or None


def clean_env(extra=None):
    """The environment a Xylem tab gives claude: no parent-session markers."""
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("CLAUDE") and k != "CLAUDE_CONFIG_DIR") and k != "XYLEM_TAB_ID"}
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    if extra:
        env.update(extra)
    return env


def encode_folder(path):
    """Claude Code's project folder name (ClaudeProjectPathResolver.encode)."""
    units = path.encode("utf-16-le")
    out = []
    for i in range(0, len(units), 2):
        unit = units[i] | (units[i + 1] << 8)
        ch = chr(unit) if unit < 128 else ""
        out.append(ch if ch and ch.isascii() and ch.isalnum() else "-")
    return "".join(out)


# ---------------------------------------------------------------- hooks

def write_hook_settings(work):
    """--settings like Xylem's, every event logged to its own file."""
    installed = os.path.expanduser("~/.xylem/hooks/settings.json")
    events = HOOK_EVENTS_FALLBACK
    try:
        with open(installed) as f:
            events = sorted(json.load(f)["hooks"].keys())
    except (OSError, ValueError, KeyError):
        pass
    logger = os.path.join(work, "log-event.sh")
    with open(logger, "w") as f:
        f.write('#!/bin/sh\n'
                '[ -n "$XYLEM_CHECK_EVENTS" ] || exit 0\n'
                'f=$(mktemp "$XYLEM_CHECK_EVENTS/ev.XXXXXX") || exit 0\n'
                'cat > "$f"\n'
                'echo "${f##*/}" >> "$XYLEM_CHECK_EVENTS/order.txt"\n'
                'exit 0\n')
    os.chmod(logger, 0o755)
    hook = {"hooks": [{"type": "command", "command": "/bin/sh '" + logger + "'"}]}
    settings = os.path.join(work, "settings.json")
    with open(settings, "w") as f:
        # Ask for Bash even when the user's settings allow it: the run needs
        # the permission question.
        json.dump({"hooks": {e: [hook] for e in events}, "permissions": {"ask": ["Bash"]}}, f, indent=2)
    return settings, events


def read_events(folder):
    try:
        names = [n for n in open(os.path.join(folder, "order.txt")).read().split() if n]
    except OSError:
        return []
    out = []
    for name in names:
        try:
            with open(os.path.join(folder, name)) as f:
                out.append(json.load(f))
        except (OSError, ValueError):
            pass
    return out


# ---------------------------------------------------------------- static checks

def check_cli(claude):
    feature = "Tabs start Claude"
    try:
        help_text = subprocess.run([claude, "--help"], capture_output=True, text=True, timeout=30,
                                   env=clean_env(), stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        record("cli.help", "fail", feature, f"claude --help didn't run: {error}")
        return False
    missing = [flag for flag in REQUIRED_FLAGS if flag not in help_text]
    if missing:
        record("cli.flags", "fail", feature,
               f"claude --help no longer lists {missing}; tabs start claude with them")
        return False
    record("cli.flags", "ok", feature, "the flags tabs start claude with are all there")
    return True


# ---------------------------------------------------------------- headless runs

def run_print(claude, cwd, args, prompt, events_dir, timeout=180):
    os.makedirs(events_dir, exist_ok=True)
    env = clean_env({"XYLEM_CHECK_EVENTS": events_dir, "XYLEM_TAB_ID": str(uuid.uuid4()).upper()})
    try:
        proc = subprocess.run([claude, "-p", prompt, "--model", "haiku"] + args, cwd=cwd, env=env,
                              capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return None, "", "timed out"


def headless(claude, cwd, settings, work, manifest):
    sessions, prompts = manifest["sessions"], manifest["prompts"]
    fresh = str(uuid.uuid4())
    prompts["fresh"] = "Reply with exactly the word pong and nothing else."
    progress("headless run: new session")
    code, out, err = run_print(claude, cwd, ["--session-id", fresh, "--settings", settings],
                               prompts["fresh"], os.path.join(work, "events-fresh"))
    feature = "Tabs start Claude"
    if code != 0:
        text = (err or out).strip().splitlines()
        reason = text[-1] if text else f"exit code {code}"
        if re.search(r"log ?in|auth|credential|api key", (err + out), re.I):
            record("run.fresh", "fail", feature, f"claude isn't logged in or can't reach its account: {reason}")
        else:
            record("run.fresh", "fail", feature, f"claude -p --session-id --settings failed: {reason}")
        return False
    record("run.fresh", "ok", feature, "claude started with --session-id and --settings and answered")
    sessions["fresh"] = fresh

    progress("headless run: resume")
    prompts["resume"] = "Reply with exactly the word again and nothing else."
    transcript = os.path.join(manifest["projectsDir"], encode_folder(cwd), fresh + ".jsonl")
    size_before = os.path.getsize(transcript) if os.path.exists(transcript) else -1
    code, out, err = run_print(claude, cwd, ["--resume", fresh, "--settings", settings],
                               prompts["resume"], os.path.join(work, "events-resume"))
    feature = "Tabs reopen their own conversation after a restart"
    if code != 0:
        record("run.resume", "fail", feature, f"claude --resume <id> failed: {(err or out).strip()[-200:]}")
    else:
        size_after = os.path.getsize(transcript) if os.path.exists(transcript) else -1
        if size_before >= 0 and size_after > size_before:
            record("run.resume", "ok", feature, "--resume continued the same transcript file")
        else:
            record("run.resume", "fail", feature,
                   "--resume didn't append to the session's own transcript; a restored tab would lose track of it")
        sessions["resumeRan"] = True

    progress("headless run: fork")
    fork = str(uuid.uuid4())
    prompts["fork"] = "Reply with exactly the word fork and nothing else."
    size_before = os.path.getsize(transcript) if os.path.exists(transcript) else -1
    code, out, err = run_print(claude, cwd, ["--resume", fresh, "--fork-session", "--session-id", fork,
                                             "--settings", settings],
                               prompts["fork"], os.path.join(work, "events-fork"))
    feature = "A conversation open in another app opens as a copy"
    fork_file = os.path.join(manifest["projectsDir"], encode_folder(cwd), fork + ".jsonl")
    if code != 0:
        record("run.fork", "fail", feature,
               f"--resume <id> --fork-session --session-id <new> failed: {(err or out).strip()[-200:]}")
    elif not os.path.exists(fork_file):
        record("run.fork", "fail", feature, "the fork didn't get its own transcript under the new id")
    elif os.path.getsize(transcript) != size_before:
        record("run.fork", "fail", feature, "the fork wrote into the original conversation's file")
    else:
        record("run.fork", "ok", feature, "fork got its own transcript, the original was left alone")
        sessions["fork"] = fork
    return True


# ---------------------------------------------------------------- interactive run

ANSI = re.compile(rb"\x1b\[[0-9;?<>=:]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-_]")


class Terminal:
    """A pty that answers claude's startup queries the way SwiftTerm does."""

    def __init__(self, argv, cwd, env, rows=40, cols=120):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.rows, self.cols = rows, cols
        self.buffer = b""
        self.batches = []          # (time, size)
        self.kitty_stack = []
        self.kitty_flags = 0
        self.kitty_pushed = []
        self.bracketed_paste = False
        self.alive = True

    def reply(self, data):
        if self.fd is None:
            return
        try:
            os.write(self.fd, data)
        except OSError:
            pass

    def answer_queries(self, chunk):
        for match in re.finditer(rb"\x1b\[(\??)([>=<]?)([0-9;:]*)(\$?)([a-zA-Z])", chunk):
            private, lead, params, dollar, final = match.groups()
            if final == b"q" and lead == b">":
                self.reply(b"\x1bP>|SwiftTerm 1.99.3:\x1b\\")
            elif final == b"u" and private == b"?":
                self.reply(b"\x1b[?%du" % self.kitty_flags)
            elif final == b"u" and lead == b">":
                self.kitty_stack.append(self.kitty_flags)
                self.kitty_flags = int(params.split(b";")[0] or b"0")
                self.kitty_pushed.append(self.kitty_flags)
            elif final == b"u" and lead == b"<":
                count = int(params or b"1")
                for _ in range(count):
                    self.kitty_flags = self.kitty_stack.pop() if self.kitty_stack else 0
            elif final == b"u" and lead == b"=":
                self.kitty_flags = int(params.split(b";")[0] or b"0")
            elif final == b"c" and not lead and not private and params in (b"", b"0"):
                self.reply(b"\x1b[?65;1;9c")
            elif final == b"n" and params == b"6":
                self.reply(b"\x1b[1;1R")
            elif final == b"p" and dollar == b"$" and private == b"?":
                self.reply(b"\x1b[?%s;0$y" % params)
            elif final == b"t" and params == b"18":
                self.reply(b"\x1b[8;%d;%dt" % (self.rows, self.cols))
            elif final == b"h" and private == b"?" and b"2004" in params.split(b";"):
                self.bracketed_paste = True
        for match in re.finditer(rb"\x1b\](1[01]);\?(\x07|\x1b\\)", chunk):
            value = b"rgb:cccc/cccc/cccc" if match.group(1) == b"10" else b"rgb:1818/1818/1818"
            self.reply(b"\x1b]" + match.group(1) + b";" + value + match.group(2))

    def pump(self, seconds):
        end = time.time() + seconds
        while self.alive and self.fd is not None and time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], min(0.05, max(0, end - time.time())))
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                self.alive = False
                return
            if not chunk:
                self.alive = False
                return
            self.batches.append((time.time(), len(chunk)))
            self.buffer = (self.buffer + chunk)[-400000:]
            self.answer_queries(chunk)

    def screen_text(self, tail=6000):
        return ANSI.sub(b"", self.buffer[-tail:]).decode("utf-8", "replace")

    def type(self, text):
        self.reply(text.encode())
        self.pump(0.4)
        self.reply(b"\r")

    def max_rate(self, start, end):
        """Most output batches in any STREAM_WINDOW inside [start, end]."""
        times = [t for t, _ in self.batches if start <= t <= end]
        best = 0
        for i, t in enumerate(times):
            j = i
            while j < len(times) and times[j] - t <= STREAM_WINDOW:
                j += 1
            best = max(best, j - i)
        return best

    def exited(self):
        if not self.alive:
            try:
                pid, _ = os.waitpid(self.pid, os.WNOHANG)
                return pid != 0
            except ChildProcessError:
                return True
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            return pid != 0
        except ChildProcessError:
            return True

    def kill(self):
        """Ends the child without ever blocking: an exiting claude waits for
        its terminal output to drain, so the master is read, then closed,
        before waiting (a blocking wait here hung the check for good)."""
        if self.fd is None:
            return
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        self.pump(1)
        fd, self.fd = self.fd, None
        try:
            os.close(fd)
        except OSError:
            pass
        self.alive = False
        end = time.time() + 5
        while time.time() < end:
            try:
                pid, _ = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return
            if pid:
                return
            time.sleep(0.1)
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def wait_for(term, events_dir, predicate, timeout, after=0):
    end = time.time() + timeout
    while time.time() < end and term.alive:
        term.pump(0.25)
        events = read_events(events_dir)[after:]
        for event in events:
            if predicate(event):
                return event, time.time()
    return None, None


def is_event(name, **fields):
    return lambda e: e.get("hook_event_name") == name and all(e.get(k) == v for k, v in fields.items())


def interactive(claude, cwd, settings, work, manifest):
    events_dir = os.path.join(work, "events-tui")
    os.makedirs(events_dir, exist_ok=True)
    session = str(uuid.uuid4())
    env = clean_env({"XYLEM_CHECK_EVENTS": events_dir, "XYLEM_TAB_ID": str(uuid.uuid4()).upper()})
    argv = [claude, "--session-id", session, "--settings", settings, "--model", "haiku",
            "--permission-mode", "default"]
    progress("interactive run: starting claude in a terminal")
    term = Terminal(argv, cwd, env)
    RUNNING.append(term)
    state = "Tab state (working, finished, needs permission)"
    try:
        # Trust question for a new folder, then SessionStart.
        trusted = False
        deadline = time.time() + 40
        start_event = None
        while time.time() < deadline and term.alive:
            term.pump(0.5)
            text = "".join(term.screen_text().lower().split())
            if not trusted and "trustthisfolder" in text:
                # The question starts on "No, exit": move to the "Yes"
                # option before confirming.
                for _ in range(4):
                    current = "".join(term.screen_text(800).lower().split())
                    if "❯yes" in current:
                        break
                    term.reply(b"\x1b[B")
                    term.pump(0.4)
                if "❯yes" not in "".join(term.screen_text(800).lower().split()):
                    record("tui.trust", "fail", "Tabs start Claude",
                           "couldn't pick \"Yes\" in the folder trust question; the question changed")
                    return
                # Xylem's loader goes when claude turns these on; the
                # question must not sit under it.
                manifest["trustShownAfterTakeover"] = bool(term.kitty_pushed or term.bracketed_paste)
                term.reply(b"\r")
                trusted = True
            start_event, _ = wait_for(term, events_dir, is_event("SessionStart"), 0.1)
            if start_event:
                break
        if not start_event:
            tail = " ".join(term.screen_text(1500).split())[-300:]
            record("tui.start", "fail", "Tabs start Claude",
                   f"interactive claude never reached its prompt (no SessionStart in 40 s). Screen: {tail}")
            return
        term.pump(3)
        record("tui.start", "ok", "Tabs start Claude", "interactive claude started"
               + (" (answered the folder trust question)" if trusted else ""))
        if trusted:
            if manifest.get("trustShownAfterTakeover"):
                record("tui.trustLoader", "ok", "Loader over a starting tab",
                       "claude takes over the terminal before asking to trust a folder, so the loader is gone by then")
            else:
                record("tui.trustLoader", "fail", "Loader over a starting tab",
                       "the trust question appears before claude turns on its keyboard mode: "
                       "it would sit under the loader for up to 10 s")
        manifest["sessions"]["tui"] = session

        # The command line other apps' Xylem checks read (open elsewhere -> fork).
        try:
            command = subprocess.run(["ps", "-ww", "-o", "command=", "-p", str(term.pid)],
                                     capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            command = ""
        if f"--session-id {session}" in command and "--settings" in command:
            record("tui.ps", "ok", "A conversation open in another app opens as a copy",
                   "the running claude shows its session id and --settings in ps")
        else:
            record("tui.ps", "fail", "A conversation open in another app opens as a copy",
                   f"ps shows \"{command.strip()[:120]}\": Xylem can't tell which session a running claude has open")

        # Keyboard protocol: SwiftTerm-style XTVERSION -> kitty flags.
        if term.kitty_pushed:
            flags = term.kitty_pushed[-1]
            if flags & 1 and flags & 4:
                record("tui.kitty", "ok", "Control keys on a Ukrainian layout (Ctrl+C, Ctrl+R)",
                       f"claude turned on the kitty keyboard protocol (flags {flags})")
            else:
                record("tui.kitty", "warn", "Control keys on a Ukrainian layout (Ctrl+C, Ctrl+R)",
                       f"kitty flags are {flags}, not 5: the base-layout key Xylem sends may be ignored")
        else:
            record("tui.kitty", "warn", "Control keys on a Ukrainian layout (Ctrl+C, Ctrl+R)",
                   "claude didn't turn on the kitty keyboard protocol; Xylem falls back to plain control bytes")
        record("tui.paste", "ok" if term.bracketed_paste else "warn",
               "Dropping files and Insert Path",
               "bracketed paste is on" if term.bracketed_paste
               else "bracketed paste stayed off: dropped paths are typed instead of pasted")

        # Turn 1: a tool that needs permission, a few seconds of work.
        manifest["prompts"]["tui"] = "Use the Bash tool to run exactly this command: sleep 4 && touch done-one.txt"
        progress("interactive run: a turn with a permission question")
        n = len(read_events(events_dir))
        term.type(manifest["prompts"]["tui"])
        submitted, _ = wait_for(term, events_dir, is_event("UserPromptSubmit"), 20, n)
        if not submitted:
            record("tui.turn", "fail", state, "typing a prompt and Return didn't submit it (no UserPromptSubmit)")
            return
        asked, _ = wait_for(term, events_dir, is_event("Notification", notification_type="permission_prompt"), 60, n)
        if asked:
            term.pump(1)
            term.reply(b"\r")
        pre, pre_at = wait_for(term, events_dir, is_event("PreToolUse"), 30, n)
        post, post_at = wait_for(term, events_dir, is_event("PostToolUse"), 40, n)
        stop, stop_at = wait_for(term, events_dir, is_event("Stop"), 60, n)
        if pre_at and post_at and post_at - pre_at > 2.5:
            rate = term.max_rate(pre_at + 0.5, post_at - 0.3)
            if rate >= STREAM_MIN_BATCHES:
                record("tui.spinner", "ok", "Yellow \"working\" ring while Claude works",
                       f"{rate} screen updates per {STREAM_WINDOW} s while a tool ran (needs {STREAM_MIN_BATCHES})")
            else:
                record("tui.spinner", "fail", "Yellow \"working\" ring while Claude works",
                       f"only {rate} screen updates per {STREAM_WINDOW} s while a tool ran; Xylem needs "
                       f"{STREAM_MIN_BATCHES} and would show the tab as idle mid-turn")
        else:
            record("tui.spinner", "skip", "Yellow \"working\" ring while Claude works",
                   "the tool didn't run long enough to measure")
        if stop_at:
            term.pump(3.5)
            rate = term.max_rate(stop_at + 1.5, stop_at + 3.5)
            if rate < STREAM_MIN_BATCHES:
                record("tui.quiet", "ok", "Blue \"finished\" dot", "the screen goes quiet after a turn ends")
            else:
                record("tui.quiet", "fail", "Blue \"finished\" dot",
                       f"{rate} screen updates per {STREAM_WINDOW} s after the turn ended: tabs would keep looking busy")

        # Turn 2: Esc in the middle of a tool.
        progress("interactive run: Esc in the middle of a turn")
        n = len(read_events(events_dir))
        # Not `sleep`: Claude Code refuses long sleeps, the tool would end at once.
        manifest["prompts"]["tui"] = "Use the Bash tool to run exactly this command: ping -c 40 -i 1 127.0.0.1 > /dev/null"
        term.type(manifest["prompts"]["tui"])   # now the tab's latest prompt
        asked, _ = wait_for(term, events_dir, is_event("Notification", notification_type="permission_prompt"), 60, n)
        if asked:
            term.pump(1)
            term.reply(b"\r")
        pre, pre_at = wait_for(term, events_dir, is_event("PreToolUse"), 30, n)
        term.pump(3)
        still_running = not any(e.get("hook_event_name") in ("PostToolUse", "Stop")
                                for e in read_events(events_dir)[n:])
        if pre_at and not still_running:
            record("tui.esc", "skip", "Tabs go idle after Esc", "the tool ended on its own before Esc could be tested")
        elif pre_at:
            esc_at = time.time()
            term.reply(b"\x1b[27u" if term.kitty_flags & 1 else b"\x1b")
            term.pump(6)
            after = [e.get("hook_event_name") for e in read_events(events_dir)[n:]]
            rate = term.max_rate(esc_at + 3, esc_at + 6)
            if rate >= STREAM_MIN_BATCHES:
                record("tui.esc", "fail", "Tabs go idle after Esc",
                       f"the screen keeps updating ({rate} per {STREAM_WINDOW} s) after Esc: the tab would stay \"working\"")
            elif "Stop" in after[after.index("PreToolUse") + 1:] if "PreToolUse" in after else False:
                record("tui.esc", "warn", "Tabs go idle after Esc",
                       "Esc now sends a Stop hook: an interrupted tab will show the blue \"finished\" dot instead of idle")
            else:
                record("tui.esc", "ok", "Tabs go idle after Esc", "Esc stops the turn and the screen goes quiet")
        else:
            record("tui.esc", "skip", "Tabs go idle after Esc", "the second tool call never started")
        term.pump(2)

        # The /effort picker the toolbar's effort menu drives (screen text
        # only; the app matches its wording): open it, move to "high", "s"
        # for this session only.
        progress("interactive run: the /effort picker")
        term.type("/effort")
        term.pump(2)
        manifest["effortPickerOpen"] = term.screen_text(3000)
        # One write, the way the app sends it.
        term.reply(b"\x1b[D" * 5 + b"\x1b[C" * 2 + b"s")
        term.pump(2)
        manifest["effortPickerDone"] = term.screen_text(3000)
        # Max is typed as "/effort max": it can't be a saved default, so it
        # should say "this session only" without the picker.
        before = len(term.buffer)
        term.type("/effort max")
        term.pump(2.5)
        manifest["effortTypedMax"] = ANSI.sub(b"", term.buffer[before:]).decode("utf-8", "replace")

        # /clear: new session id.
        progress("interactive run: /clear")
        n = len(read_events(events_dir))
        term.type("/clear")
        started, _ = wait_for(term, events_dir, is_event("SessionStart", source="clear"), 20, n)
        if started:
            manifest["sessions"]["tuiCleared"] = started.get("session_id")
        else:
            manifest["sessions"]["tuiCleared"] = ""
        term.pump(2)

        # Ctrl+C the way Xylem sends it on a Ukrainian layout.
        progress("interactive run: Ctrl+C as typed on a Ukrainian layout")
        n = len(read_events(events_dir))
        key = b"\x1b[1089::99;5u" if term.kitty_flags & 1 else b"\x03"
        term.reply(key)
        term.pump(0.6)
        term.reply(key)
        end = time.time() + 10
        while time.time() < end and not term.exited():
            term.pump(0.3)
        feature = "Control keys on a Ukrainian layout (Ctrl+C, Ctrl+R)"
        if term.exited():
            record("tui.ctrlc", "ok", feature, "two Ctrl+C sent the way Xylem sends them on Cyrillic ended claude")
        else:
            tail = " ".join(term.screen_text(1500).split())[-200:]
            record("tui.ctrlc", "fail", feature,
                   f"two Ctrl+C sent the way Xylem sends them on a Ukrainian layout ({key!r}, kitty flags "
                   f"{term.kitty_flags}) didn't end claude. Screen: {tail}")
        ended, _ = wait_for(term, events_dir, is_event("SessionEnd"), 3, n) if term.alive else (None, None)
        if not ended:
            ended = next((e for e in read_events(events_dir)[n:] if e.get("hook_event_name") == "SessionEnd"), None)
        if ended:
            record("tui.end", "ok", "Tabs notice Claude quit", f"SessionEnd arrived (reason {ended.get('reason')})")
        elif term.exited():
            record("tui.end", "fail", "Tabs notice Claude quit", "claude exited without a SessionEnd hook")
    finally:
        term.kill()
        RUNNING.remove(term)


# ---------------------------------------------------------------- app stage

def app_stage(work):
    """Xylem's own parsers judge the capture (ClaudeCompatibilityTests)."""
    progress("judging with Xylem's own code (xcodebuild, a minute or two)")
    log = os.path.join(work, "xcodebuild.log")
    env = dict(os.environ, TEST_RUNNER_XYLEM_CLAUDE_CHECK_DIR=work)
    env.pop("XYLEM_CLAUDE_CHECK_DIR", None)
    with open(log, "w") as out:
        code = subprocess.run(
            ["xcodebuild", "-project", os.path.join(REPO, "Xylem.xcodeproj"), "-scheme", "Xylem",
             "-configuration", "Debug", "test", "-only-testing:XylemTests/ClaudeCompatibilityTests",
             "-derivedDataPath", DERIVED_DATA, "-skipPackagePluginValidation",
             # Hostless tests need no signing team (anyone can run this).
             "DEVELOPMENT_TEAM=", "CODE_SIGN_IDENTITY=-"],
            cwd=REPO, env=env, stdout=out, stderr=subprocess.STDOUT).returncode
    path = os.path.join(work, "results-app.jsonl")
    if not os.path.exists(path):
        tail = open(log, errors="replace").read().splitlines()[-15:]
        errors = [l for l in tail if "error" in l.lower()] or tail[-3:]
        record("app.stage", "fail", "This check itself",
               f"Xylem's tests didn't run (xcodebuild exit {code}); log: {log}; " + " | ".join(errors)[:400])
        return
    for line in open(path):
        if line.strip():
            results.append(json.loads(line))


# ---------------------------------------------------------------- cleanup

def cleanup(manifest, work, keep):
    projects = manifest.get("projectsDir")
    cwd = manifest.get("cwd")
    if projects and cwd and "xylem-claude-check" in cwd:
        folder = os.path.join(projects, encode_folder(cwd))
        if os.path.dirname(folder) == projects.rstrip("/") and os.path.isdir(folder):
            if keep:
                # Moved next to the capture so --judge-only can read it.
                kept = os.path.join(work, "run-projects")
                os.makedirs(kept, exist_ok=True)
                shutil.move(folder, os.path.join(kept, encode_folder(cwd)))
                manifest["runProjectsDir"] = kept
                with open(os.path.join(work, "manifest.json"), "w") as f:
                    json.dump(manifest, f, indent=2)
            else:
                shutil.rmtree(folder, ignore_errors=True)
    root = manifest.get("configRoot")
    ids = [v for v in (manifest.get("sessions") or {}).values() if isinstance(v, str) and len(v) == 36]
    if root and ids:
        for child in ("file-history", "session-env", "todos", "shell-snapshots", "tasks", "debug"):
            base = os.path.join(root, child)
            if not os.path.isdir(base):
                continue
            for name in os.listdir(base):
                if any(name.startswith(i) for i in ids):
                    target = os.path.join(base, name)
                    shutil.rmtree(target, ignore_errors=True) if os.path.isdir(target) else os.remove(target)
    if keep:
        print(color("2", f"\n  Kept everything captured in {work}"))
    elif work and "xylem-claude-check" in work:
        shutil.rmtree(work, ignore_errors=True)


# ---------------------------------------------------------------- report

def report(version, last_pass):
    order = {"fail": 0, "warn": 1, "skip": 2, "ok": 3}
    marks = {"ok": color("32", "OK  "), "warn": color("33", "LOOK"), "fail": color("31", "FAIL"),
             "skip": color("2", "N/A ")}
    print()
    title = f"Claude Code {version}" + (f"  (last full pass: {last_pass})" if last_pass else "")
    print(color("1", title))
    print()
    for item in sorted(results, key=lambda r: order.get(r["status"], 9)):
        print(f"  {marks.get(item['status'], item['status'])}  {color('1', item['feature'])}")
        print(f"        {item['detail']}")
    fails = sum(r["status"] == "fail" for r in results)
    warns = sum(r["status"] == "warn" for r in results)
    print()
    if fails:
        print(color("31", f"{fails} broken, {warns} to look at."))
    elif warns:
        print(color("33", f"Nothing broken, {warns} to look at."))
    else:
        print(color("32", "Everything Xylem relies on works."))
    return fails


def main():
    parser = argparse.ArgumentParser(description="Check the installed Claude Code against what Xylem expects.")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--judge-only")
    parser.add_argument("--no-app", action="store_true")
    options = parser.parse_args()

    last_pass = open(LAST_PASS_FILE).read().strip() if os.path.exists(LAST_PASS_FILE) else None

    if options.judge_only:
        work = os.path.abspath(options.judge_only)
        manifest = json.load(open(os.path.join(work, "manifest.json")))
        for line in open(os.path.join(work, "results-live.jsonl")):
            if line.strip():
                results.append(json.loads(line))
        if os.path.exists(os.path.join(work, "results-app.jsonl")):
            os.remove(os.path.join(work, "results-app.jsonl"))
        if not options.no_app:
            app_stage(work)
        return 1 if report(manifest.get("claudeVersion", "?"), last_pass) else 0

    print(color("1", "Checking Claude Code against Xylem"))
    found, config_dir = login_shell_lookup()
    claude = os.environ.get("CLAUDE_BIN") or found
    if not claude or not os.path.exists(claude):
        record("cli.found", "fail", "Doctor and every tab",
               "claude isn't on your login shell's PATH: tabs can't start it")
        report("not found", last_pass)
        return 1
    try:
        version = subprocess.run([claude, "--version"], capture_output=True, text=True, timeout=30,
                                 env=clean_env(), stdin=subprocess.DEVNULL).stdout.split()[0]
    except (OSError, subprocess.TimeoutExpired, IndexError):
        version = "unknown"
    record("cli.found", "ok", "Doctor and every tab", f"{claude} ({version})")

    config_root = os.path.expanduser(config_dir) if config_dir else os.path.expanduser("~/.claude")
    global_config = os.path.join(config_root, ".claude.json") if config_dir else os.path.expanduser("~/.claude.json")
    projects_dir = os.path.realpath(os.path.join(config_root, "projects"))

    work = os.path.realpath(tempfile.mkdtemp(prefix="xylem-claude-check."))
    # Spaces, dots and underscores: Claude Code turns all of them into "-".
    cwd = os.path.join(work, "proj dir_v1.0")
    os.makedirs(cwd)
    subprocess.run(["git", "init", "-q", cwd], capture_output=True)
    settings, events = write_hook_settings(work)
    manifest = {
        "claudeVersion": version, "claudePath": claude,
        "binaryMtime": os.path.getmtime(os.path.realpath(claude)),
        "configRoot": config_root, "globalConfigFile": global_config, "projectsDir": projects_dir,
        "cwd": cwd, "subscribedEvents": events, "sessions": {}, "prompts": {},
    }
    def out_of_time(signum, frame):
        raise OutOfTime
    signal.signal(signal.SIGALRM, out_of_time)
    signal.alarm(TIME_LIMIT)
    interrupted = False
    try:
        if check_cli(claude):
            if headless(claude, cwd, settings, work, manifest):
                interactive(claude, cwd, settings, work, manifest)
            else:
                record("tui.skipped", "skip", "Everything that needs a running claude",
                       "not checked: claude couldn't run a single turn (see above)")
        else:
            record("run.skipped", "skip", "Everything that needs a running claude",
                   "not checked: claude doesn't take the flags tabs use (see above)")
        with open(os.path.join(work, "manifest.json"), "w") as f:
            json.dump(manifest, f, indent=2)
        with open(os.path.join(work, "results-live.jsonl"), "w") as f:
            for item in results:
                f.write(json.dumps(item) + "\n")
        signal.alarm(0)
        if not options.no_app:
            app_stage(work)
    except OutOfTime:
        record("check.timeout", "fail", "This check itself",
               f"a claude run didn't finish within {TIME_LIMIT // 60} minutes; the last step shown above is where it hung")
        progress("out of time, cleaning up")
    except KeyboardInterrupt:
        print("\nStopped.")
        interrupted = True
    finally:
        # Whatever happened: no claude left running, nothing left behind.
        signal.alarm(0)
        for child in list(RUNNING):
            child.kill()
        cleanup(manifest, work, options.keep)
    if interrupted:
        return 130
    fails = report(version, last_pass)
    if not fails and not options.no_app:
        with open(LAST_PASS_FILE, "w") as f:
            f.write(version + "\n")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
