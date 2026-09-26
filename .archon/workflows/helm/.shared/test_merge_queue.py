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
        self.assertEqual(checks_at(REQUIRED, rerun_failed), Checks("red", ("skill gates",)))

    def test_red_outranks_pending_and_pending_outranks_missing(self):
        runs = [run(1, "build · test · format", status="in_progress", conclusion=None),
                run(2, "skill gates", conclusion="failure")]
        self.assertEqual(checks_at(REQUIRED, runs).state, "red")
        runs = [run(1, "build · test · format", status="queued", conclusion=None)]
        self.assertEqual(checks_at(REQUIRED, runs).state, "pending")


def facts(**over):
    base = dict(state="OPEN", is_draft=False, base=BASE, head_in_base=False,
                base_pr_merged=False, merge_state="CLEAN", checks=Checks("green"))
    return Facts(**{**base, **over})


class NextMove(unittest.TestCase):
    def move(self, preview=False, may_kick=False, **over):
        return next_move(facts(**over), preview=preview, may_kick=may_kick)

    def test_up_to_date_and_green_merges_or_stops_at_tested_in_preview(self):
        self.assertEqual(self.move(), "merge")
        self.assertEqual(self.move(preview=True), "tested")

    def test_behind_updates_before_trusting_green_checks(self):
        # Green checks on a stale head are the stale-green case; the base must move first.
        self.assertEqual(self.move(merge_state="BEHIND"), "update")

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
