#!/usr/bin/env python3
"""Prove chat -> document -> back against an isolated benchd and a disposable simulator."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
PORT = 52247


def run(*args, **kwargs):
    return subprocess.run(args, check=True, timeout=900, **kwargs)


def ask(verb, args):
    with socket.create_connection(("127.0.0.1", PORT), timeout=2) as connection:
        request = {"id": "fixture", "verb": verb, "args": args, "by": {"kind": "helm"}}
        connection.sendall((json.dumps(request) + "\n").encode())
        return json.loads(connection.makefile().readline())


def main():
    # Let timeout's SIGTERM run the same cleanup as a test failure.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(124))
    # Refuse a port already in use before sending any test verb.
    with socket.socket() as available:
        available.bind(("127.0.0.1", PORT))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("--store", type=Path, help="Copy this real store into the isolated fixture")
    args = parser.parse_args()
    result = args.result.resolve()
    result.parent.mkdir(parents=True, exist_ok=True)
    derived = REPO / ".build/pocket-ui"
    with tempfile.TemporaryDirectory(prefix="pocket-links-", dir="/tmp") as scratch:
        home = Path(scratch).resolve()
        workspace = home / "Archon"
        workspace.mkdir()
        store = home / ".prp/fixture-1"
        if args.store:
            shutil.copytree(args.store.resolve(), store, symlinks=True)
            print("Copied real store into", store, flush=True)
        else:
            (store / "reports").mkdir(parents=True)
            (store / "reports/launch-queue.md").write_text("# Archon run launch queue\n\nA queued document from benchd.\n")
        # Only the owned copy is registered to the fixture workspace.
        (store / "project.json").write_text(json.dumps({"name": "fixture", "path": str(workspace)}))
        (store / "report.md").write_text("# Markdown from benchd\n\n**The plan** arrived over TCP.\n")
        (store / "page.html").write_text(
            '<!doctype html><html><meta name="viewport" content="width=device-width">'
            '<meta name="color-scheme" content="dark"><h1>HTML from benchd</h1><p id="sibling"></p><script src="sibling.js"></script></html>'
        )
        (store / "sibling.js").write_text('document.getElementById("sibling").textContent="Sibling script loaded";')
        for index in range(25):
            recent = store / f"recent-{index}.md"
            recent.write_text("# Newer document\n")
            now = time.time() + index
            os.utime(recent, (now, now))
        fake_bin = home / "bin"
        fake_bin.mkdir()
        stub = fake_bin / "claude"
        stub.write_text("#!" + sys.executable + "\n" + r'''import json, os, pathlib, select, sys, time
if "--version" in sys.argv:
    print("fixture")
    sys.exit(0)
home = pathlib.Path(os.environ["HOME"])
workspace = pathlib.Path.cwd()
session = sys.argv[sys.argv.index("--session-id") + 1]
registry = home / ".claude/sessions"
registry.mkdir(parents=True, exist_ok=True)
(registry / f"{os.getpid()}.json").write_text(json.dumps({
    "pid": os.getpid(), "sessionId": session, "cwd": str(workspace),
    "startedAt": int(time.time() * 1000), "status": "idle", "name": "pocket-links fixture",
}))
mangled = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(workspace))
projects = home / ".claude/projects" / mangled
projects.mkdir(parents=True)
store = home / ".prp/fixture-1"
messages = [("user", "Show the documents."),
            ("assistant", f"[Open markdown]({store}/report.md)"),
            ("assistant", "[Open HTML](~/.prp/fixture-1/page.html)"),
            ("assistant", str(store / "reports/launch-queue.md")),
            ("assistant", "`reports/launch-queue.md`"),
            ("assistant", "[Relative HTML](page.html)"),
            ("assistant", "reports/not-listed.md")]
transcript = projects / f"{session}.jsonl"
transcript.write_text("".join(
    json.dumps({"type": kind, "cwd": str(workspace), "timestamp": "2026-10-04T12:00:00.000Z",
                "message": {"role": kind, "content": text}}) + "\n" for kind, text in messages))
deadline = time.monotonic() + 850
while time.monotonic() < deadline:
    ready, _, _ = select.select([sys.stdin], [], [], 0.2)
    if ready and "create late document" in sys.stdin.readline():
        (store / "reports/later.md").write_text("# Created after chat opened\n")
        with transcript.open("a") as stream:
            stream.write(json.dumps({"type": "assistant", "cwd": str(workspace),
                "timestamp": "2026-10-04T12:01:00.000Z",
                "message": {"role": "assistant", "content": "`reports/later.md`"}}) + "\n")
''')
        stub.chmod(0o755)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("BENCH_") and key not in ("HELM_PANE", "PRP_HOME", "CLAUDE_CONFIG_DIR")}
        env.update(PATH=str(fake_bin) + os.pathsep + env["PATH"], HOME=str(home), BENCH_DIR=str(home / "bench"), BENCH_SUITE="pocket-links-test",
                   BENCH_LISTEN=f"127.0.0.1:{PORT}")
        simulator = None
        daemon = subprocess.Popen(["timeout", "900", str(REPO / "daemon/target/debug/benchd")], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 20
            while True:
                try:
                    answer = ask("workspace/open", {"path": str(workspace)})
                    assert answer["status"] == "ok", answer
                    break
                except OSError:
                    if time.monotonic() >= deadline or daemon.poll() is not None:
                        raise RuntimeError("isolated benchd did not start")
                    time.sleep(0.1)  # Let startup finish; the timeout bounds the wait.
            spawned = ask("spawn", {"agent": "claude", "cwd": str(workspace), "prompt": "fixture"})
            assert spawned["status"] == "ok", spawned
            deadline = time.monotonic() + 10
            while True:
                rows = ask("sessions/all", {"workspace": str(workspace)})
                if rows["status"] == "ok" and any(row.get("name") == "pocket-links fixture" for row in rows["data"]["rows"]):
                    break
                assert time.monotonic() < deadline, rows
                time.sleep(0.1)  # Let the stub publish its transcript, inside this deadline.
            print(json.dumps(rows), flush=True)
            stores = ask("prp/stores", {"workspace": str(workspace)})
            assert stores["status"] == "ok" and stores["data"]["workspace"] == "fixture-1", stores
            print("Workspace resolves to fixture-1", flush=True)
            inventory = ask("prp/artifacts", {"store": "fixture-1"})
            assert inventory["status"] == "ok", inventory
            print("Isolated artifact count:", len(inventory["data"]["files"]), flush=True)
            newest = inventory["data"]["files"][:20]
            assert not any(f["relative"] == "reports/launch-queue.md" for f in newest)
            print("launch-queue is outside the newest twenty", flush=True)
            simulator = subprocess.check_output([
                "xcrun", "simctl", "create", "Pocket links proof", "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                "com.apple.CoreSimulator.SimRuntime.iOS-26-3"], text=True, timeout=30).strip()
            print("Owned simulator:", simulator, flush=True)
            run("xcrun", "simctl", "boot", simulator)
            run("xcrun", "simctl", "bootstatus", simulator, "-b")
            run("xcodegen", "generate", "--spec", str(REPO / "Pocket/project.yml"))
            run("timeout", "720", "xcodebuild", "-quiet", "-project", str(REPO / "Pocket/Pocket.xcodeproj"), "-scheme", "Pocket",
                "-destination", f"platform=iOS Simulator,id={simulator}", "-derivedDataPath", str(derived),
                "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO", "test")
        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)
            if simulator:
                subprocess.run(["xcrun", "simctl", "shutdown", simulator], timeout=30, check=False)
                run("xcrun", "simctl", "delete", simulator)
            if derived.exists():
                shutil.rmtree(derived)
            print("Stopped fixture benchd; removed simulator and UI DerivedData.", flush=True)


if __name__ == "__main__":
    main()
