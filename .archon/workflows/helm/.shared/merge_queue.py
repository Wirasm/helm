"""helm's merge queue: every node's work. Each script under merge-queue/scripts/ is one node
and calls `entry` with its action.

The forge is the gate. `development` is strict-protected, so a PR can merge only when its head
is up to date with `development` and every required check passed on that head. The queue
therefore does not build or test anything itself: `gh pr update-branch` makes the composed
commit, CI tests it, and the queue sequences PRs, pins the merge to the head it watched go
green, and reads the merge back.

The invariant: a PR merges only at the exact head SHA every required check passed on, and the
merge commit's parents are exactly [the development tip before the merge, that head]. Anything
else stops the batch.

State is one file, queue.json under $ARTIFACTS_DIR, rewritten after every transition. Across
runs the record is $STATE_DIR/merge-queue/ledger.jsonl, one appended line per transition.

The decisions live in three pure functions (`checks_at`, `next_move`, `verify_merge`) so they
can be tested without GitHub; `Queue` is the I/O around them.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

BASE = "development"
POLL_SECONDS = 20
PR_DEADLINE_SECONDS = 50 * 60
# How long a head may show no run for a required check before the queue closes and reopens
# the PR to start CI. A retarget does not start helm's CI; a push or a reopen does.
KICK_GRACE_SECONDS = 180
MERGE_READBACK_SECONDS = 90
MAX_PRS = 20  # the loop's max_iterations

PASSING = {"success", "neutral", "skipped"}
MERGEABLE = {"CLEAN", "UNSTABLE", "HAS_HOOKS"}


class Refusal(Exception):
    """A condition the queue will not proceed past. The message is the evidence."""


# --- pure decisions ----------------------------------------------------------------------


@dataclass(frozen=True)
class Checks:
    state: Literal["green", "pending", "missing", "red"]
    names: tuple[str, ...] = ()  # the red, pending or missing ones


def checks_at(required: list[str], runs: list[dict[str, Any]]) -> Checks:
    """Judge the required checks from the check runs reported for one commit.

    The latest run per name wins (a re-run supersedes the failure it replaced). Red outranks
    pending, pending outranks missing: a red check is final, and a missing one may still be
    about to start while another is running.
    """
    latest: dict[str, dict[str, Any]] = {}
    for run in runs:
        name = run["name"]
        if name not in latest or run["id"] > latest[name]["id"]:
            latest[name] = run
    red, pending, missing = [], [], []
    for name in required:
        run = latest.get(name)
        if run is None:
            missing.append(name)
        elif run["status"] != "completed":
            pending.append(name)
        elif run.get("conclusion") not in PASSING:
            red.append(name)
    if red:
        return Checks("red", tuple(red))
    if pending:
        return Checks("pending", tuple(pending))
    if missing:
        return Checks("missing", tuple(missing))
    return Checks("green")


@dataclass(frozen=True)
class Facts:
    state: str  # OPEN, CLOSED, MERGED
    is_draft: bool
    base: str
    head_in_base: bool  # the head is already an ancestor of development
    base_pr_merged: bool  # for a stacked PR: the PR its base branch belongs to has merged
    merge_state: str  # GitHub's mergeStateStatus
    checks: Checks


Move = Literal[
    "landed",  # head already in development: close as landed through another PR
    "closed",
    "draft",
    "retarget",
    "stacked",  # based on a PR that has not merged
    "conflict",
    "update",
    "red",
    "wait",
    "kick",
    "tested",  # preview: up to date and green, stop here
    "merge",
]


def next_move(f: Facts, *, preview: bool, may_kick: bool) -> Move:
    if f.state == "MERGED" or f.head_in_base:
        return "landed"
    if f.state != "OPEN":
        return "closed"
    if f.is_draft:
        return "draft"
    if f.base != BASE:
        return "retarget" if f.base_pr_merged else "stacked"
    if f.merge_state == "DIRTY":
        return "conflict"
    if f.merge_state == "BEHIND":
        return "update"
    if f.checks.state == "red":
        return "red"
    if f.checks.state == "missing":
        return "kick" if may_kick else "wait"
    if f.checks.state == "pending":
        return "wait"
    # Green, but GitHub has not yet agreed the PR is mergeable: UNKNOWN is computed lazily
    # and can hide BEHIND, and BLOCKED lags a check finishing. Waiting is cheap; merging
    # early prints a hint and merges nothing.
    if f.merge_state not in MERGEABLE:
        return "wait"
    return "tested" if preview else "merge"


def verify_merge(parents: list[str], old_tip: str, head: str) -> bool:
    """A `--merge` landing is exactly one merge commit on top of the tip that was current."""
    return parents == [old_tip, head]


# --- I/O --------------------------------------------------------------------------------


def run(argv: list[str], *, ok: tuple[int, ...] = (0,)) -> subprocess.CompletedProcess[str]:
    # Captured: a node's stderr reaches the operator, and gh is chatty there.
    result = subprocess.run(argv, capture_output=True, text=True, check=False)  # noqa: S603
    if result.returncode not in ok:
        raise Refusal(
            f"{' '.join(argv)} exited {result.returncode}: "
            f"{(result.stderr or result.stdout).strip()[-1500:]}"
        )
    return result


def gh_json(*args: str) -> Any:
    return json.loads(run(["gh", *args]).stdout)


def gh_text(*args: str) -> str:
    """For a `--jq` that selects a string, which gh prints raw rather than as JSON."""
    return run(["gh", *args]).stdout.strip()


def say(line: str) -> None:
    """Progress for whoever follows the run (`archon workflow logs <id> --follow`)."""
    print(line, file=sys.stderr, flush=True)


def now() -> float:
    return time.monotonic()


class Queue:
    def __init__(self) -> None:
        self.artifacts = Path(os.environ["ARTIFACTS_DIR"])
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.run_id = self.artifacts.name  # Archon names the artifacts dir after the run
        state_dir = Path(os.environ["STATE_DIR"]) / "merge-queue"
        state_dir.mkdir(parents=True, exist_ok=True)
        self.ledger_path = state_dir / "ledger.jsonl"
        self.path = self.artifacts / "queue.json"
        self.state: dict[str, Any] = json.loads(self.path.read_text()) if self.path.exists() else {}

    @property
    def repo(self) -> str:
        return self.state["repo"]

    @property
    def items(self) -> list[dict[str, Any]]:
        return self.state["items"]

    def save(self) -> None:
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self.state, indent=2))
        tmp.replace(self.path)

    def ledger(self, event: str, item: dict[str, Any]) -> None:
        line = {
            "ts": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
            "run": self.run_id,
            "event": event,
            "pr": item["number"],
            "title": item.get("title", ""),
            "head_sha": item.get("head_sha", ""),
            "merge_sha": item.get("merge_sha", ""),
            "reason": item.get("reason", ""),
        }
        with self.ledger_path.open("a") as out:
            out.write(json.dumps(line) + "\n")

    def settle(self, item: dict[str, Any], status: str, reason: str = "") -> None:
        item.update(status=status, reason=reason)
        self.save()
        self.ledger(status, item)
        say(f"#{item['number']}: {status}{': ' + reason if reason else ''}")

    # --- intake --------------------------------------------------------------------------

    def intake(self, numbers: list[int], mode: str) -> dict[str, Any]:
        if not numbers:
            raise Refusal("no pull request numbers given")
        if len(numbers) > MAX_PRS:
            raise Refusal(f"{len(numbers)} PRs is more than one run lands ({MAX_PRS})")
        if len(set(numbers)) != len(numbers):
            raise Refusal("a PR number appears twice")
        if mode not in ("merge", "preview"):
            raise Refusal(f"mode is {mode!r}; it is 'merge' or 'preview'")
        repo = gh_json("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
        required = gh_json(
            "api",
            f"repos/{repo}/branches/{BASE}/protection",
            "--jq",
            ".required_status_checks.contexts",
        )
        if not required:
            raise Refusal(f"{BASE} names no required checks; the queue has no gate to wait on")
        base_sha = gh_text("api", f"repos/{repo}/branches/{BASE}", "--jq", ".commit.sha")
        items = []
        for number in numbers:
            view = gh_json("pr", "view", str(number), "--json", "number,title,url,headRefOid")
            items.append(
                {
                    "number": number,
                    "title": view["title"],
                    "url": view["url"],
                    "head_sha": view["headRefOid"],
                    "status": "queued",
                    "reason": "",
                }
            )
        self.state = {
            "version": 1,
            "repo": repo,
            "mode": mode,
            "required": required,
            "base_sha": base_sha,
            "stopped": "",
            "items": items,
        }
        self.save()
        for item in items:
            self.ledger("queued", item)
        return {
            "queued": numbers,
            "base_sha": base_sha,
            "summary": f"{BASE} at {base_sha[:8]}; queued {numbers}; required {required}",
        }

    # --- one PR per iteration --------------------------------------------------------------

    def step(self) -> dict[str, Any]:
        item = next((i for i in self.items if i["status"] == "queued"), None)
        if item is None or self.state["stopped"]:
            return {"done": True, "number": 0, "status": "none", "summary": "nothing left"}
        try:
            self.land(item)
        except Refusal as refusal:
            # An unexpected gh failure leaves the PR in a state the queue did not observe
            # (it may even have merged), so the batch stops rather than building on it.
            self.state["stopped"] = f"#{item['number']}: {refusal}"
            self.settle(item, "held", self.state["stopped"])
        remaining = any(i["status"] == "queued" for i in self.items)
        return {
            "done": bool(self.state["stopped"]) or not remaining,
            "number": item["number"],
            "status": item["status"],
            "summary": f"#{item['number']} {item['status']}"
            + (f": {item['reason']}" if item["reason"] else ""),
        }

    def facts(self, number: int) -> tuple[Facts, str]:
        view = gh_json(
            "pr",
            "view",
            str(number),
            "--json",
            "state,isDraft,baseRefName,headRefOid,mergeStateStatus",
        )
        head = view["headRefOid"]
        compare = gh_text("api", f"repos/{self.repo}/compare/{BASE}...{head}", "--jq", ".status")
        base_pr_merged = False
        if view["baseRefName"] != BASE:
            owners = gh_json(
                "pr", "list", "--head", view["baseRefName"], "--state", "all",
                "--json", "number,state", "--limit", "1",
            )
            base_pr_merged = bool(owners) and owners[0]["state"] == "MERGED"
        # One page: a helm head carries a handful of runs, far under 100.
        runs = gh_json(
            "api", f"repos/{self.repo}/commits/{head}/check-runs?per_page=100",
            "--jq", "[.check_runs[] | {id, name, status, conclusion}]",
        )
        return (
            Facts(
                state=view["state"],
                is_draft=view["isDraft"],
                base=view["baseRefName"],
                head_in_base=compare in ("behind", "identical"),
                base_pr_merged=base_pr_merged,
                merge_state=view["mergeStateStatus"],
                checks=checks_at(self.state["required"], runs),
            ),
            head,
        )

    def land(self, item: dict[str, Any]) -> None:
        number = item["number"]
        preview = self.state["mode"] == "preview"
        deadline = now() + PR_DEADLINE_SECONDS
        head_since: dict[str, float] = {}
        kicked: set[str] = set()
        last_move = ""
        while True:
            f, head = self.facts(number)
            item["head_sha"] = head
            head_since.setdefault(head, now())
            may_kick = head not in kicked and now() - head_since[head] > KICK_GRACE_SECONDS
            move = next_move(f, preview=preview, may_kick=may_kick)
            if move != last_move:
                say(f"#{number} at {head[:8]}: {move} ({f.merge_state}, checks {f.checks.state})")
                last_move = move

            if move == "landed":
                if f.state == "OPEN":
                    run(["gh", "pr", "close", str(number), "--comment",
                         f"Landed through `{BASE}`: head {head} is already in it."])
                return self.settle(item, "landed_through", f"head {head[:8]} is already in {BASE}")
            if move == "closed":
                return self.settle(item, "held", f"PR is {f.state}")
            if move == "draft":
                return self.settle(item, "held", "PR is a draft")
            if move == "stacked":
                return self.settle(item, "held", f"stacked on {f.base}, whose PR has not merged")
            if move == "conflict":
                return self.settle(item, "held", f"conflicts with {BASE}")
            if move == "red":
                return self.settle(item, "held", "red: " + ", ".join(f.checks.names))
            if move == "tested":
                return self.settle(item, "tested")
            if move == "merge":
                return self.merge(item, head)

            if now() > deadline:
                why = f"checks {f.checks.state}: {', '.join(f.checks.names)}" if f.checks.names else f.merge_state
                return self.settle(item, "held", f"timeout after {PR_DEADLINE_SECONDS // 60} min ({why})")
            if move == "retarget":
                run(["gh", "pr", "edit", str(number), "--base", BASE])
                continue
            if move == "update":
                run(["gh", "pr", "update-branch", str(number)])
                self.await_new_head(number, head)
                continue
            if move == "kick":
                kicked.add(head)
                run(["gh", "pr", "close", str(number)])
                run(["gh", "pr", "reopen", str(number)])
            time.sleep(POLL_SECONDS)

    def await_new_head(self, number: int, old: str) -> None:
        for _ in range(12):
            time.sleep(10)
            view = gh_json("pr", "view", str(number), "--json", "headRefOid")
            if view["headRefOid"] != old:
                return
        raise Refusal(f"#{number}: update-branch reported success but the head stayed {old[:8]}")

    def merge(self, item: dict[str, Any], head: str) -> None:
        number = item["number"]
        old_tip = gh_text("api", f"repos/{self.repo}/branches/{BASE}", "--jq", ".commit.sha")
        # Exit status is not the answer: on a PR GitHub will not merge, gh can print a hint
        # and merge nothing. The PR's state is the answer.
        attempt = run(
            ["gh", "pr", "merge", str(number), "--merge", "--match-head-commit", head], ok=tuple(range(256))
        )
        view: dict[str, Any] = {}
        for _ in range(MERGE_READBACK_SECONDS // 5):
            view = gh_json("pr", "view", str(number), "--json", "state,mergeCommit")
            if view["state"] == "MERGED":
                break
            time.sleep(5)
        if view.get("state") != "MERGED":
            said = (attempt.stderr or attempt.stdout).strip()[-300:]
            self.state["stopped"] = f"#{number}: merge did not land ({said or 'no output'})"
            return self.settle(item, "held", self.state["stopped"])
        merge_sha = view["mergeCommit"]["oid"]
        item["merge_sha"] = merge_sha
        parents = gh_json("api", f"repos/{self.repo}/commits/{merge_sha}", "--jq", "[.parents[].sha]")
        if not verify_merge(parents, old_tip, head):
            self.state["stopped"] = (
                f"#{number}: merged as {merge_sha[:8]} with parents "
                f"{[p[:8] for p in parents]}, expected [{old_tip[:8]}, {head[:8]}]; "
                f"inspect {BASE} before landing anything else"
            )
            return self.settle(item, "merged_unverified", self.state["stopped"])
        self.settle(item, "merged")

    # --- report ----------------------------------------------------------------------------

    def report(self) -> dict[str, Any]:
        if not self.state:
            # Intake refused (its reason is on that node); there is nothing to report on.
            return {"mode": "", "base_sha": "", "merged": [], "tested": [], "landed_through": [],
                    "held": [], "queued": [], "reasons": {}, "stopped": "intake refused",
                    "summary": "intake refused; nothing ran"}

        def by(*statuses: str) -> list[int]:
            return [i["number"] for i in self.items if i["status"] in statuses]

        reasons = {str(i["number"]): i["reason"] for i in self.items if i["reason"]}
        out = {
            "mode": self.state["mode"],
            "base_sha": self.state["base_sha"],
            "merged": by("merged"),
            "tested": by("tested"),
            "landed_through": by("landed_through"),
            "held": by("held", "merged_unverified"),
            "queued": by("queued"),
            "reasons": reasons,
            "stopped": self.state["stopped"],
        }
        out["summary"] = (
            f"{out['mode']}: {BASE} was {out['base_sha'][:8]}; merged {out['merged']}; "
            f"tested {out['tested']}; landed through {out['landed_through']}; held {out['held']}"
            + (f"; not reached {out['queued']}" if out["queued"] else "")
            + (f"; stopped: {out['stopped']}" if out["stopped"] else "")
        )
        return out


def entry(action: str) -> int:
    queue = Queue()
    try:
        if action == "intake":
            numbers = [int(n) for n in os.environ["INPUTS_PRS"].replace(",", " ").split()]
            out = queue.intake(numbers, os.environ.get("INPUTS_MODE", "merge"))
        elif action == "step":
            out = queue.step()
        elif action == "report":
            out = queue.report()
        else:
            raise Refusal(f"unknown action {action!r}")
    except (Refusal, ValueError) as refusal:
        print(str(refusal), file=sys.stderr)
        return 1
    print(json.dumps(out))
    return 0
