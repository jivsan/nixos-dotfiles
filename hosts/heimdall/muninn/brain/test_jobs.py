"""Lifecycle tests exercise real SQLite state and temporary vault report files."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from jobs import BusyError, JobStore


class JobLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.vault = self.root / "vault"
        self.vault.mkdir()
        self.database = self.root / "state" / "jobs.db"
        self.store = JobStore(self.database, self.vault, max_active=2)
        self.route = {"via": "jev", "tier": "agent", "executor": "codex", "confidence": 0.9}

    def create(self, text="Research backups", agent="codex"):
        return self.store.create(text, agent, self.route)

    def finish(self, job, status="done", answer="Findings and https://example.org/source"):
        job.update(status=status, answer=answer)
        self.store.finish(job)
        return self.store.get(job["id"])

    def test_admission_limit_releases_slot_only_after_terminal_state(self):
        first = self.create()
        second = self.create()
        with self.assertRaises(BusyError):
            self.create()
        self.assertEqual(self.store.get(second["id"])["status"], "running")
        self.finish(first)
        self.assertEqual(self.create()["status"], "running")

    def test_concurrent_admission_across_store_instances_respects_limit(self):
        stores = [JobStore(self.database, self.vault, max_active=2) for _ in range(8)]

        def submit(store):
            try:
                return store.create("Parallel request", "hermes", self.route)
            except BusyError:
                return None

        with ThreadPoolExecutor(max_workers=8) as pool:
            accepted = [job for job in pool.map(submit, stores) if job]
        self.assertEqual(len(accepted), 2)
        self.assertEqual(len({job["id"] for job in accepted}), 2)
        self.assertEqual(len(self.store.recent()), 2)

    def test_completed_job_and_report_survive_reopen(self):
        job = self.finish(self.create())
        reopened = JobStore(self.database, self.vault)
        self.assertEqual(reopened.get(job["id"]), job)
        report = (self.vault / job["report"]).read_text()
        self.assertTrue(job["report"].startswith("Resources/Reports/"))
        for expected in ("type: report", "status: done", "[[Agents MOC]]", "Research backups",
                         "Findings and https://example.org/source", '"via": "jev"', job["id"]):
            self.assertIn(expected, report)
        self.assertFalse(list((self.vault / "Resources/Reports").glob("*.tmp")))

    def test_failure_also_files_a_report(self):
        job = self.finish(self.create(), status="failed", answer="Executor timed out after making partial progress.")
        self.assertEqual(job["status"], "failed")
        report = (self.vault / job["report"]).read_text()
        self.assertIn("status: failed", report)
        self.assertIn("Executor timed out", report)

    def test_mutating_returned_jobs_cannot_change_saved_state(self):
        job = self.create()
        job["status"] = "done"
        self.assertEqual(self.store.get(job["id"])["status"], "running")
        fetched = self.store.get(job["id"])
        fetched["route"]["via"] = "changed"
        self.assertEqual(self.store.get(job["id"])["route"]["via"], "jev")

    def test_filing_keeps_job_running_until_report_is_ready(self):
        job = self.create()
        original = self.store.file_report

        def inspect_pending(terminal):
            saved = self.store.get(job["id"])
            self.assertEqual(saved["status"], "running")
            self.assertEqual(saved["result_status"], "done")
            self.assertTrue(saved["filing"])
            self.assertNotIn("report", saved)
            return original(terminal)

        with mock.patch.object(self.store, "file_report", side_effect=inspect_pending):
            final = self.finish(job)
        self.assertEqual(final["status"], "done")
        self.assertNotIn("filing", final)

    def test_report_error_preserves_result_and_marks_job_failed(self):
        with mock.patch.object(self.store, "file_report", side_effect=OSError("NFS unavailable")):
            job = self.finish(self.create(), answer="Useful result that must survive.")
        self.assertEqual(job["status"], "failed")
        self.assertIn("Useful result that must survive.", job["answer"])
        self.assertIn("Report filing failed", job["answer"])
        self.assertIn("NFS unavailable", job["report_error"])
        self.assertNotIn("report", job)
        self.assertEqual(JobStore(self.database, self.vault).get(job["id"]), job)

    def test_restart_marks_unfinished_work_failed_without_replay(self):
        job = self.create()
        finished = self.finish(self.create("Already completed"))
        reopened = JobStore(self.database, self.vault)
        reopened.recover()
        interrupted = reopened.get(job["id"])
        self.assertEqual(interrupted["status"], "failed")
        self.assertIn("partially executed", interrupted["answer"])
        self.assertTrue((self.vault / interrupted["report"]).is_file())
        self.assertEqual(reopened.get(finished["id"]), finished)
        snapshot = reopened.recent()
        reopened.recover()
        self.assertEqual(reopened.recent(), snapshot)

    def test_restart_finishes_pending_filing_without_losing_result(self):
        job = self.create()
        job.update(status="done", answer="Complete research findings.")
        # Model process death between durable output and report publication.
        with mock.patch.object(self.store, "_file_terminal", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.store.finish(job)
        reopened = JobStore(self.database, self.vault)
        self.assertTrue(reopened.get(job["id"])["filing"])
        reopened.recover()
        recovered = reopened.get(job["id"])
        self.assertEqual(recovered["status"], "done")
        self.assertEqual(recovered["answer"], "Complete research findings.")
        self.assertIn("Complete research findings.", (self.vault / recovered["report"]).read_text())

    def test_restart_filing_failure_still_releases_worker_slot(self):
        job = self.create()
        job.update(status="running", filing=True, result_status="done", answer="Retained result.")
        self.store.save(job)
        with mock.patch.object(self.store, "file_report", side_effect=OSError("NFS unavailable")):
            self.store.recover()
        self.assertEqual(self.store.get(job["id"])["status"], "failed")
        self.assertEqual(self.create()["status"], "running")

    def test_report_directory_symlink_cannot_redirect_writes(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.vault / "Resources").symlink_to(outside, target_is_directory=True)
        job = self.finish(self.create())
        self.assertEqual(job["status"], "failed")
        self.assertIn("symlink", job["report_error"])
        self.assertEqual(list(outside.iterdir()), [])

    def test_unknown_job_and_recent_limit(self):
        self.assertIsNone(self.store.get("missing"))
        first = self.finish(self.create())
        second = self.finish(self.create("Newer request"))
        self.assertEqual([job["id"] for job in self.store.recent(1)], [second["id"]])
        self.assertEqual(len(self.store.recent(0)), 1)
        self.assertEqual(len(self.store.recent(1000)), 2)
        self.assertNotEqual(first["id"], second["id"])


if __name__ == "__main__":
    unittest.main()
