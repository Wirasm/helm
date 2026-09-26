#!/usr/bin/env python3
"""The mail ring (#358): real agents, spawned by benchd, pass a number around by mail.

Each hop adds one, so an echo cannot fake it. Every hop is cross-provider when the ring mixes
harnesses, and every delivery goes through benchd: the hook at a tool call when the recipient is
busy, the harness's own turn channel (Claude's inbox socket, pi's extension, codex's app-server)
when it is idle. Nothing is typed into a pty. Per-hop latency is read from benchd's own log.

Two passes, which set the recipients up; the table says which channel each hop took:
  idle  every agent has ended its turn when its mail lands, so delivery is a push.
  busy  every agent is first mailed an instruction to run `sleep` tool calls, so ring mail
        lands mid-turn and is handed out by the hook at the next tool call.

Columns: sent->delivered is `mail/sent` to benchd's `mail/delivered`; delivered->turn is that to
the recipient's next report of being busy (for a push; codex's `turn/start` answer is the turn
starting, so it reads 0); sent->reply is the whole hop, model included, to the recipient's own
`mail/sent`.

Runs against its own suite (`BENCH_SUITE=ring<pid>`, root `~/.bench-ring<pid>`), never the
operator's bench, and removes that root afterwards unless --keep. Every child is bounded: benchd
runs under `timeout`, and `bench stop` closes every session it spawned. Spends model tokens.
"""

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

DAEMON_DIR = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(DAEMON_DIR, "target", "debug")
BENCH = os.path.join(TARGET, "bench")
BENCHD = os.path.join(TARGET, "benchd")
SEED = 100
# The `channel` values benchd logs on `mail/delivered` (benchd/src/hook.rs: `hand_out` and `push`).
CHANNELS = {"hook", "socket", "pi", "codex"}
DEFAULT_MODELS = {"claude": "haiku", "pi": "minimax/MiniMax-M2.7-highspeed"}


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ring", default="claude,codex,pi", help="agents in ring order (claude, codex, pi)")
    p.add_argument("--passes", default="idle,busy", help="comma-separated: idle, busy")
    p.add_argument("--cwd", default=os.path.dirname(DAEMON_DIR),
                   help="where the agents run; claude and codex must already trust it")
    p.add_argument("--model", action="append", default=[], metavar="AGENT=MODEL",
                   help="model per agent (defaults: claude=haiku, pi=MiniMax-M2.7-highspeed)")
    p.add_argument("--hop-timeout", type=int, default=240, help="seconds to wait for the ring to close")
    p.add_argument("--keep", action="store_true", help="keep the suite root for inspection")
    return p.parse_args()


def at(event):
    return datetime.datetime.fromisoformat(event["at"].replace("Z", "+00:00")).timestamp()


class Bench:
    """One isolated benchd and the `bench` CLI pointed at it."""

    def __init__(self, suite):
        self.suite = suite
        self.root = os.path.expanduser(f"~/.bench-{suite}")
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("BENCH_DIR", "BENCH_SESSION", "BENCH_HANDLE", "HELM_PANE")}
        self.env["BENCH_SUITE"] = suite
        self.daemon = None
        self.log = os.path.join(tempfile.gettempdir(), f"benchd-{suite}.log")

    def __call__(self, *args, check=True):
        out = subprocess.run([BENCH, *args], env=self.env, capture_output=True, text=True, timeout=30)
        if check and out.returncode != 0:
            died = self.daemon and self.daemon.poll() is not None
            sys.exit(f"mail-ring: bench {' '.join(args)} exited {out.returncode}: {out.stderr.strip()}"
                     + (f"\nmail-ring: benchd exited {self.daemon.returncode}; its log: {self.log}" if died else ""))
        return json.loads(out.stdout) if out.stdout.strip() else {}

    def start(self):
        if os.path.exists(self.root):
            sys.exit(f"mail-ring: {self.root} already exists; pick another suite")
        self.daemon = subprocess.Popen(["timeout", "1800", BENCHD], env=self.env,
                                       stdout=subprocess.DEVNULL, stderr=open(self.log, "w"))
        for _ in range(100):
            if self("status", check=False):
                return
            time.sleep(0.1)
        sys.exit("mail-ring: benchd never answered")

    def stop(self, keep):
        if self.daemon:
            self("stop", check=False)
            try:
                self.daemon.wait(15)
            except subprocess.TimeoutExpired:
                # TERM, not KILL: `timeout` passes TERM on to benchd, and dies alone on KILL.
                self.daemon.terminate()
                self.daemon.wait()
        if keep:
            print(f"mail-ring: kept {self.root} and {self.log}")
        else:
            shutil.rmtree(self.root, ignore_errors=True)
            if os.path.exists(self.log):
                os.remove(self.log)

    def events(self):
        with open(os.path.join(self.root, "events.jsonl")) as f:
            return [json.loads(line) for line in f if line.strip()]


def brief(handle, nxt, stop_at):
    return (
        f"You are {handle}, one agent in a mail ring run through the bench.\n"
        f"When you learn you have mail (a line 'You have mail from <sender>: <path>'), run `cat <path>`. "
        f"The last line of that file is an integer N. If N+1 is less than {stop_at}, run "
        f"`bench mail send --to {nxt} --body <N+1>`; otherwise run "
        f"`bench mail send --to operator --body <N+1>`. Use the actual number. "
        f"Handle each piece of ring mail exactly once, and never send mail otherwise.\n"
        "Right now, reply READY and end your turn. Mail will start a new turn."
    )


# The busy pass's instruction, sent as mail so every harness starts it the same way: through
# its own channel while idle. Subject `busy`, so the report leaves it out.
BUSY = (
    "This is not ring mail; send nothing for it. Start now: run the shell command `sleep 5` as "
    "separate tool calls, one at a time, until you have run it 14 times. Handle ring mail as soon "
    "as you learn of it, between two sleeps, then continue the sleeps. After the last sleep, reply "
    "DONE and end your turn."
)


def settle(bench, handles, want, after_seq, wait):
    """Wait until every agent's hooks, since `after_seq`, have said busy and last said `want`:
    a turn that started and, for `idle`, ended."""
    deadline = time.time() + wait
    while True:
        state, worked = {}, set()
        for e in bench.events():
            if e["kind"] == "agent/state" and e["seq"] > after_seq:
                state[e["data"]["handle"]] = e["data"]["activity"]["kind"]
                if state[e["data"]["handle"]] == "busy":
                    worked.add(e["data"]["handle"])
        if all(state.get(h) == want and h in worked for h in handles):
            return
        if time.time() > deadline:
            # A codex turn refused by a usage limit fires no Stop, so its hooks last said busy.
            # Go on anyway: benchd asks the thread's own status once mail is waiting for it.
            print(f"mail-ring: going on although not every agent reported {want}: {state}")
            return
        time.sleep(1)


def run_pass(bench, ring, handles, cwd, models, busy, timeout):
    prompts = tempfile.mkdtemp(prefix="ring-")
    stop_at = SEED + len(ring) + 1
    sessions = []
    for i, agent in enumerate(ring):
        path = os.path.join(prompts, f"{handles[i]}.md")
        with open(path, "w") as f:
            f.write(brief(handles[i], handles[(i + 1) % len(ring)], stop_at))
        args = ["spawn", "--agent", agent, "--cwd", cwd, "--name", handles[i], "--prompt-file", path]
        if models.get(agent):
            args += ["--model", models[agent]]
        sessions.append(bench(*args)["session"])

    # Each agent's first turn ends: idle, after having been busy.
    start = bench.events()[-1]["seq"]
    settle(bench, handles, "idle", start, 90)
    if busy:
        mark = bench.events()[-1]["seq"]
        for h in handles:
            bench("mail", "send", "--to", h, "--from", "operator", "--subject", "busy", "--body", BUSY)
        settle(bench, handles, "busy", mark, 90)
        time.sleep(3)  # into the sleeps
    seeded = bench("mail", "send", "--to", handles[0], "--from", "operator", "--body", str(SEED))["id"]
    print(f"mail-ring [{('busy' if busy else 'idle')}]: seeded {SEED} -> {handles[0]} ({seeded})")

    final = stop_at
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = [m for m in bench("mail", "list", "--handle", "operator").get("mail", [])
               if m.get("from") == handles[0]]
        if got:
            body = bench("mail", "read", got[0]["id"], "--handle", "operator")["body"].strip().splitlines()[-1]
            if body != str(final):
                sys.exit(f"mail-ring: the ring closed with {body}, expected {final}")
            print(f"mail-ring: {final} arrived from {handles[0]}")
            break
        time.sleep(1)
    else:
        report(bench, handles, busy)
        sys.exit("mail-ring: TIMEOUT waiting for the ring to close")
    for s in sessions:
        bench("close", s, check=False)
    shutil.rmtree(prompts, ignore_errors=True)
    return report(bench, handles, busy)


def report(bench, handles, busy):
    """One row per hop, from the log: mail/sent -> mail/delivered -> the recipient's next busy."""
    events = bench.events()
    rows, ok = [], True
    for e in events:
        if e["kind"] != "mail/sent" or e["data"]["to"] not in handles or e["data"]["subject"] == "busy":
            continue
        mid, to = e["data"]["id"], e["data"]["to"]
        delivered = next((d for d in events if d["kind"] == "mail/delivered"
                          and mid in d["data"]["mail"]), None)
        after = at(delivered) if delivered else None
        busy_at = next((at(s) for s in events if after and s["kind"] == "agent/state"
                        and s["data"]["handle"] == to and s["data"]["activity"]["kind"] == "busy"
                        and at(s) >= after), None)
        reply = next((at(s) for s in events if after and s["kind"] == "mail/sent"
                      and s["data"]["from"] == to and at(s) > after), None)
        channel = delivered["data"]["channel"] if delivered else "-"
        # Which channel a hop takes is the recipient's state when the mail lands, and that is
        # the model's doing: the pass sets it up, the table reports it. What must hold is that
        # benchd delivered it through one of its channels.
        ok &= channel in CHANNELS
        ms = lambda a, b: f"{(a - b) * 1000:.0f}" if a is not None and b is not None else "-"
        rows.append((f"{e['data']['from']} -> {to}", channel,
                     (delivered or {}).get("data", {}).get("event", "-"),
                     ms(after, at(e)), ms(busy_at, after) if channel != "hook" else "-", ms(reply, at(e))))
    head = ("hop", "channel", "at", "sent->delivered ms", "delivered->turn ms", "sent->reply ms")
    width = [max(len(str(r[i])) for r in rows + [head]) for i in range(len(head))]
    for r in [head] + rows:
        print("  " + "  ".join(str(c).ljust(width[i]) for i, c in enumerate(r)))
    pasted = [e["kind"] for e in events if e["kind"] in ("agent/woken", "wake/pasted")]
    if pasted:
        ok = False
        print(f"mail-ring: a notice was pasted into a pty: {pasted}")
    if not ok:
        print("mail-ring: a hop was not delivered through any of benchd's channels")
    return ok


def main():
    args = parse_args()
    ring = [a.strip() for a in args.ring.split(",") if a.strip()]
    models = dict(DEFAULT_MODELS)
    models.update(dict(m.split("=", 1) for m in args.model))
    passes = [p.strip() for p in args.passes.split(",") if p.strip()]
    subprocess.run(["cargo", "build", "-q", "--workspace"], cwd=DAEMON_DIR, check=True)
    ok = True
    for name in passes:
        bench = Bench(f"ring{os.getpid()}{name}")
        passed = False
        try:
            bench.start()
            handles = [f"ring-{a}" for a in ring]
            passed = run_pass(bench, ring, handles, args.cwd, models, name == "busy", args.hop_timeout)
            ok &= passed
        finally:
            # A failed pass keeps its root and benchd's log to read.
            bench.stop(args.keep or not passed)
    print("mail-ring: clean" if ok else "mail-ring: FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
