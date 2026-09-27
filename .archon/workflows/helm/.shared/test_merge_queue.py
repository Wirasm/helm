"""The queue's three decisions, without GitHub.

Run: PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .archon/workflows/helm/.shared
"""

import os
import tempfile
import unittest
from unittest import mock

import merge_queue
from merge_queue import BASE, Checks, Facts, checks_at, next_move, verify_merge

REQUIRED = ["build · test · format", "skill gates"]


def run(id_, name, status="completed", conclusion="success"):
    return {"id": id_, "name": name, "status": status, "conclusion": conclusion}


class ChecksAt(unittest.TestCase):
    def test_green_only_when_every_required_check_passed(self):
        runs = [run(1, "build · test · format"), run(2, "skill gates", conclusion="skipped")]
        self.assertEqual(checks_at(REQUIRED, runs).state, "green")

    def test_a_missing_required_check_is_not_green(self):
        # The 2026-09-25 lesson: "no failures" is not "all four passed".
        runs = [run(1, "build · test · format"), run(2, "unrelated")]
        self.assertEqual(checks_at(REQUIRED, runs), Checks("missing", ("skill gates",)))

    def test_the_latest_run_of_a_check_wins(self):
        rerun_passed = [run(1, "skill gates", conclusion="failure"), run(5, "skill gates"),
                        run(2, "build · test · format")]
        self.assertEqual(checks_at(REQUIRED, rerun_passed).state, "green")
        rerun_failed = [run(5, "skill gates", conclusion="cancelled"), run(1, "skill gates"),
                        run(2, "build · test · format")]
        self.assertEqual(checks_at(REQUIRED, rerun_failed), Checks("red", ("skill gates",), (5,)))

    def test_red_outranks_pending_and_pending_outranks_missing(self):
        runs = [run(1, "build · test · format", status="in_progress", conclusion=None),
                run(2, "skill gates", conclusion="failure")]
        self.assertEqual(checks_at(REQUIRED, runs), Checks("red", ("skill gates",), (2,), True))
        runs = [run(1, "build · test · format", status="queued", conclusion=None)]
        self.assertEqual(checks_at(REQUIRED, runs).state, "pending")


def facts(**over):
    base = dict(state="OPEN", is_draft=False, base=BASE, head_in_base=False, behind=False,
                base_pr_merged=False, merge_state="CLEAN", checks=Checks("green"))
    return Facts(**{**base, **over})


class NextMove(unittest.TestCase):
    def move(self, preview=False, may_kick=False, may_rerun=False, **over):
        return next_move(facts(**over), preview=preview, may_kick=may_kick, may_rerun=may_rerun)

    def test_up_to_date_and_green_merges_or_stops_at_tested_in_preview(self):
        self.assertEqual(self.move(), "merge")
        self.assertEqual(self.move(preview=True), "tested")

    def test_behind_updates_before_trusting_green_checks(self):
        # Green checks on a stale head are the stale-green case; the base must move first.
        self.assertEqual(self.move(merge_state="BEHIND"), "update")

    def test_a_red_on_a_head_behind_development_is_not_a_verdict(self):
        # Run 2 of 2026-09-27: #507 was 4 behind, GitHub still said UNKNOWN, and a check that
        # went red against the old base held it. Behind comes from compare, not mergeStateStatus.
        red = Checks("red", ("fmt · clippy · build · test",))
        self.assertEqual(self.move(behind=True, checks=red, merge_state="BLOCKED"), "update")
        # UNKNOWN may yet be DIRTY, and update-branch on a conflict fails: wait for the answer.
        self.assertEqual(self.move(behind=True, checks=red, merge_state="UNKNOWN"), "wait")
        self.assertEqual(self.move(behind=True, checks=red, merge_state="DIRTY"), "conflict")

    def test_red_on_an_up_to_date_head_reruns_only_when_allowed(self):
        red = Checks("red", ("skill gates",), (9,))
        self.assertEqual(self.move(checks=red, merge_state="BLOCKED", may_rerun=True), "rerun")
        self.assertEqual(self.move(checks=red, merge_state="BLOCKED"), "red")
        # A job cannot be re-run while its workflow run is still going: wait for it first.
        running = Checks("red", ("skill gates",), (9,), running=True)
        self.assertEqual(self.move(checks=running, merge_state="BLOCKED", may_rerun=True), "wait")

    def test_green_but_not_yet_mergeable_waits(self):
        for state in ("UNKNOWN", "BLOCKED"):
            self.assertEqual(self.move(merge_state=state), "wait")
            self.assertEqual(self.move(merge_state=state, preview=True), "wait")

    def test_a_head_already_in_development_has_landed(self):
        self.assertEqual(self.move(head_in_base=True, merge_state="BEHIND"), "landed")
        self.assertEqual(self.move(state="MERGED"), "landed")

    def test_stacked_pr_retargets_only_once_its_base_pr_merged(self):
        self.assertEqual(self.move(base="feat/lower", base_pr_merged=True), "retarget")
        self.assertEqual(self.move(base="feat/lower"), "stacked")

    def test_missing_checks_kick_only_when_allowed(self):
        missing = Checks("missing", ("skill gates",))
        self.assertEqual(self.move(checks=missing, merge_state="BLOCKED"), "wait")
        self.assertEqual(self.move(checks=missing, merge_state="BLOCKED", may_kick=True), "kick")

    def test_holds(self):
        self.assertEqual(self.move(state="CLOSED"), "closed")
        self.assertEqual(self.move(is_draft=True), "draft")
        self.assertEqual(self.move(merge_state="DIRTY"), "conflict")
        self.assertEqual(self.move(checks=Checks("red", ("skill gates",)), merge_state="BLOCKED"), "red")


FMT = "fmt · clippy · build · test"


class FakeGitHub:
    """Answers the gh calls `Queue.land` makes, one scripted poll per `facts()` read.

    A poll is (head, mergeStateStatus, compare status). Check runs are kept per commit, so a
    new head starts with none and a re-run appends to the head it ran on.
    """

    def __init__(self, polls, runs, on_rerun=None):
        self.polls, self.runs, self.on_rerun = list(polls), runs, on_rerun
        self.now = self.polls[0]
        self.calls = []

    def gh_json(self, *args):
        if args[:2] == ("pr", "view") and args[3] == "--json" and "mergeStateStatus" in args[4]:
            self.now = self.polls.pop(0)
            head, merge_state, _ = self.now
            return {"state": "OPEN", "isDraft": False, "baseRefName": BASE,
                    "headRefOid": head, "mergeStateStatus": merge_state}
        if args[:2] == ("pr", "view"):  # await_new_head: the head the next poll will see
            return {"headRefOid": self.polls[0][0]}
        if args[0] == "api" and "/check-runs" in args[1]:
            sha = args[1].split("/commits/")[1].split("/")[0]
            return self.runs.get(sha, [])
        raise AssertionError(f"unexpected gh {args}")

    def gh_text(self, *args):
        assert "/compare/" in args[1], args
        return self.now[2]

    def run(self, argv, ok=(0,)):
        self.calls.append(argv)
        if argv[:2] == ["gh", "api"] and argv[-1].endswith("/rerun"):
            self.on_rerun(self.runs)
        return merge_queue.subprocess.CompletedProcess(argv, 0, "", "")


class Landing(unittest.TestCase):
    """`land` against a scripted GitHub, in preview so a green head stops at `tested`."""

    def setUp(self):
        tmp = tempfile.mkdtemp()
        env = {"ARTIFACTS_DIR": os.path.join(tmp, "run"), "STATE_DIR": os.path.join(tmp, "state")}
        self.env = mock.patch.dict(os.environ, env)
        self.env.start()
        self.queue = merge_queue.Queue()
        self.queue.state = {"repo": "o/r", "mode": "preview", "required": [FMT], "base_sha": "tip",
                            "stopped": "", "items": [{"number": 507, "status": "queued", "reason": ""}]}

    def tearDown(self):
        self.env.stop()

    def land(self, gh):
        with mock.patch.object(merge_queue, "gh_json", gh.gh_json), \
             mock.patch.object(merge_queue, "gh_text", gh.gh_text), \
             mock.patch.object(merge_queue, "run", gh.run), \
             mock.patch.object(merge_queue.time, "sleep"):
            self.queue.step()
        return self.queue.items[0], self.queue.report()

    def test_a_stale_red_is_updated_and_the_new_head_judged(self):
        # #507 on 2026-09-27: red on an old head, 4 behind, GitHub still computing (UNKNOWN).
        gh = FakeGitHub(
            polls=[("old", "UNKNOWN", "diverged"), ("old", "BEHIND", "diverged"),
                   ("new", "BLOCKED", "ahead"), ("new", "CLEAN", "ahead")],
            runs={"old": [run(1, FMT, conclusion="failure")], "new": [run(2, FMT)]},
        )
        item, report = self.land(gh)
        self.assertIn(["gh", "pr", "update-branch", "507"], gh.calls)
        self.assertEqual((item["status"], item["head_sha"]), ("tested", "new"))
        self.assertEqual(report["reran"], [])

    def test_a_red_on_the_up_to_date_head_holds_after_its_one_rerun(self):
        def still_red(runs):
            runs["new"].append(run(3, FMT, conclusion="failure"))

        gh = FakeGitHub(
            polls=[("new", "BLOCKED", "ahead")] * 3,
            runs={"new": [run(2, FMT, conclusion="failure")]}, on_rerun=still_red,
        )
        item, report = self.land(gh)
        reruns = [c for c in gh.calls if c[-1].endswith("/rerun")]
        self.assertEqual(reruns, [["gh", "api", "-X", "POST", "repos/o/r/actions/jobs/2/rerun"]])
        self.assertEqual(item["status"], "held")
        self.assertIn("also after one re-run", item["reason"])
        self.assertEqual(report["reran"], [507])

    def test_a_rerun_that_never_starts_holds_only_that_pr(self):
        self.queue.state["items"].append({"number": 508, "status": "queued", "reason": ""})
        gh = FakeGitHub(
            polls=[("new", "BLOCKED", "ahead")],
            runs={"new": [run(2, FMT, conclusion="failure")]}, on_rerun=lambda runs: None,
        )
        item, report = self.land(gh)
        self.assertEqual((item["status"], report["stopped"]), ("held", ""))
        self.assertIn("no new run appeared", item["reason"])
        self.assertEqual((report["queued"], report["reran"]), ([508], [507]))

    def test_a_flake_that_passes_its_rerun_goes_on_and_is_reported(self):
        def passes(runs):
            runs["new"].append(run(3, FMT))

        gh = FakeGitHub(
            polls=[("new", "BLOCKED", "ahead"), ("new", "CLEAN", "ahead")],
            runs={"new": [run(2, FMT, conclusion="failure")]}, on_rerun=passes,
        )
        item, report = self.land(gh)
        self.assertEqual((item["status"], report["reran"]), ("tested", [507]))
        self.assertIn("re-ran a red check once for [507]", report["summary"])


class VerifyMerge(unittest.TestCase):
    def test_exactly_old_tip_then_tested_head(self):
        self.assertTrue(verify_merge(["tip", "head"], "tip", "head"))
        self.assertFalse(verify_merge(["head", "tip"], "tip", "head"))
        self.assertFalse(verify_merge(["other", "head"], "tip", "head"))
        self.assertFalse(verify_merge(["tip"], "tip", "head"))  # a squash or rebase landing


class AfterTheMergeCommand(unittest.TestCase):
    """Once `gh pr merge` has run, the PR may have merged: no failure may report it untouched."""

    def setUp(self):
        tmp = tempfile.mkdtemp()
        env = {"ARTIFACTS_DIR": os.path.join(tmp, "run"), "STATE_DIR": os.path.join(tmp, "state")}
        self.env = mock.patch.dict(os.environ, env)
        self.env.start()
        self.queue = merge_queue.Queue()
        self.queue.state = {"repo": "o/r", "mode": "merge", "required": [], "base_sha": "tip",
                            "stopped": "", "items": [{"number": 7, "status": "queued", "reason": ""}]}

    def tearDown(self):
        self.env.stop()

    def merge_with(self, view):
        done = merge_queue.subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(merge_queue, "gh_text", return_value="tip"), \
             mock.patch.object(merge_queue, "run", return_value=done), \
             mock.patch.object(merge_queue, "gh_json", side_effect=view), \
             mock.patch.object(merge_queue.time, "sleep"):
            self.queue.merge(self.queue.items[0], "head")
        return self.queue.items[0], self.queue.report()

    def test_a_failed_read_back_is_unverified_and_stops_the_batch(self):
        item, report = self.merge_with(RuntimeError("502 from GitHub"))
        self.assertEqual(item["status"], "merged_unverified")
        self.assertEqual(report["unverified"], [7])
        self.assertEqual(report["queued"], [])
        self.assertIn("could not be confirmed", report["stopped"])

    def test_a_merge_command_that_times_out_is_unverified(self):
        timed_out = merge_queue.Refusal("gh pr merge 7 did not answer in 120s")
        with mock.patch.object(merge_queue, "gh_text", return_value="tip"), \
             mock.patch.object(merge_queue, "run", side_effect=timed_out):
            self.queue.merge(self.queue.items[0], "head")
        report = self.queue.report()
        self.assertEqual((report["unverified"], report["held"]), ([7], []))

    def test_wrong_parents_are_unverified_and_a_clean_merge_is_merged(self):
        views = [{"state": "MERGED", "mergeCommit": {"oid": "m"}}, ["other", "head"]]
        item, report = self.merge_with(views)
        self.assertEqual((item["status"], report["unverified"]), ("merged_unverified", [7]))
        self.setUp()
        views = [{"state": "MERGED", "mergeCommit": {"oid": "m"}}, ["tip", "head"]]
        item, report = self.merge_with(views)
        self.assertEqual((item["status"], report["merged"], report["stopped"]), ("merged", [7], ""))


if __name__ == "__main__":
    unittest.main()
