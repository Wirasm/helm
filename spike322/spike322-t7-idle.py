#!/usr/bin/env python3
"""spike322 T7 — assumption 4's decisive half.

An agent that has finished and is sitting at a prompt is not running a loop at all. Prove it:
drive a REAL interactive Claude Code session in a pty, tell it to poll its mailbox every 60
seconds, then stop typing and count invocations for six minutes.

Every child is killed by this script's own deadline; nothing is left behind.
"""
import os, pty, select, signal, subprocess, sys, time

CLI = "/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322/bench-mail-logged"
LOG = sys.argv[1]
MODE = sys.argv[2]            # "naive" | "blocking"
WATCH_S = int(sys.argv[3])    # seconds to watch after the turn goes quiet
HARD_DEADLINE = time.time() + WATCH_S + 300

if MODE == "naive":
    PROMPT = (
        f"You have a mailbox. Run this command now: {CLI} check "
        f"— then from now on run that same command every 60 seconds to stay reachable. "
        f"I will not prompt you again. Keep polling."
    )
else:
    PROMPT = (
        f"You have a mailbox. Stay reachable for the next 5 minutes by running "
        f"`{CLI} check` every 60 seconds. You may block in a shell loop to do it "
        f"(for example: for i in 1 2 3 4 5; do {CLI} check; sleep 60; done). Do it now."
    )

def count():
    try:
        with open(LOG) as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0

env = dict(os.environ)
env["HELM_DEFAULTS_SUITE"] = "spike322"
env["SPIKE322_LOG"] = LOG
env["TERM"] = "xterm-256color"

work = f"/tmp/spike322-idle-{MODE}"
os.makedirs(work, exist_ok=True)

master, slave = pty.openpty()
os.set_blocking(master, False)
proc = subprocess.Popen(
    ["claude", "--dangerously-skip-permissions"],
    stdin=slave, stdout=slave, stderr=slave, cwd=work, env=env,
    preexec_fn=os.setsid,
)
os.close(slave)

def drain(seconds):
    end = time.time() + seconds
    buf = b""
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.3)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
    return buf

def kill():
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        time.sleep(1)
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        pass

try:
    print(f"[t7:{MODE}] waiting for the TUI to come up", flush=True)
    drain(12)
    print(f"[t7:{MODE}] typing the instruction (len={len(PROMPT)})", flush=True)
    os.write(master, PROMPT.encode())
    time.sleep(1.5)
    os.write(master, b"\r")

    # Let the turn run. Note when the invocation count stops moving — that is "the turn is done".
    t_start = time.time()
    last, still_since = count(), None
    while time.time() - t_start < 240 and time.time() < HARD_DEADLINE:
        drain(3)
        n = count()
        if n != last:
            print(f"[t7:{MODE}] t+{int(time.time()-t_start)}s invocations={n}", flush=True)
            last, still_since = n, None
        elif n > 0:
            if still_since is None:
                still_since = time.time()
            elif time.time() - still_since > 45:
                break
    turn_end = time.time()
    at_turn_end = count()
    print(f"[t7:{MODE}] TURN QUIET at t+{int(turn_end-t_start)}s with {at_turn_end} invocation(s)", flush=True)

    # Now: nobody types anything. Does the poll happen?
    print(f"[t7:{MODE}] watching {WATCH_S}s with NO further input", flush=True)
    watch_end = min(time.time() + WATCH_S, HARD_DEADLINE)
    while time.time() < watch_end:
        drain(5)
        n = count()
        if n != at_turn_end:
            print(f"[t7:{MODE}] +{int(time.time()-turn_end)}s AFTER TURN END: invocations={n}", flush=True)
            at_turn_end = n
    print(f"[t7:{MODE}] RESULT invocations_total={count()} process_alive={proc.poll() is None}", flush=True)
finally:
    kill()
    print(f"[t7:{MODE}] child killed; final count={count()}", flush=True)
