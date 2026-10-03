"""Regression tests for durable, confined inbox filing (no network required)."""
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("inbox", Path(__file__).with_name("inbox.py"))
inbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inbox)


def result():
    return dict(title="A filed note", folder="Resources", moc="Home MOC",
                tags=["homelab"], body="Preserved facts.")


class FilingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vault = Path(self.temp.name)
        (self.vault / "_inbox").mkdir()
        (self.vault / "MOCs").mkdir()
        (self.vault / "MOCs/Home MOC.md").write_text("# Home MOC")
        self.source = self.vault / "_inbox/capture.md"
        self.source.write_text("A complete original capture.")

    def run_sweep(self, model=lambda raw, mocs: result()):
        return inbox.sweep(self.vault, model)

    def reports(self):
        return list((self.vault / "Resources/Reports").glob("*.md"))

    def test_files_and_archives_full_original_and_reports(self):
        raw = "Facts exceeding the old 8000-byte truncation.\n" * 500
        self.source.write_text(raw)
        seen = []
        self.assertEqual(self.run_sweep(lambda text, mocs: (seen.append(text), result())[1]), 0)
        self.assertEqual(seen, [raw])
        self.assertFalse(self.source.exists())
        original = next(self.vault.glob("agents/inbox/archive/*/original.md"))
        self.assertEqual(original.read_text(), raw)
        self.assertEqual(original.with_name("snapshot.md").read_text(), raw)
        filed = (self.vault / "Resources/A filed note.md").read_text()
        self.assertIn("[[MOCs/Home MOC]]", filed)
        self.assertIn("agent: huginn", filed)
        self.assertIn("status: completed", self.reports()[0].read_text())
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(len(self.reports()), 1)

    def test_invalid_model_data_keeps_capture_and_reports_failure(self):
        invalid = [[], {}, {**result(), "moc": "../../escape"},
                   {**result(), "title": "../escape"}, {**result(), "tags": [12]},
                   {**result(), "body": None}, {**result(), "folder": "_inbox"}]
        for response in invalid:
            with self.subTest(response=response):
                self.assertEqual(self.run_sweep(lambda *_: response), 1)
                self.assertTrue(self.source.exists())
        self.assertTrue(all("status: failed" in p.read_text() for p in self.reports()))

    def test_public_notes_reports_and_private_archives_with_restrictive_umask(self):
        previous_umask = os.umask(0o077)
        try:
            self.assertEqual(self.run_sweep(lambda *_: {**result(), "folder": "Areas"}), 0)
        finally:
            os.umask(previous_umask)
        for name in ("Areas", "Resources", "Resources/Reports"):
            self.assertEqual(stat.S_IMODE((self.vault / name).stat().st_mode), 0o755)
        for note in (self.vault / "Areas/A filed note.md", self.reports()[0]):
            self.assertEqual(stat.S_IMODE(note.stat().st_mode), 0o644)
        snapshot = next(self.vault.glob("agents/inbox/archive/*/snapshot.md"))
        self.assertEqual(stat.S_IMODE(snapshot.stat().st_mode), 0o640)
        for directory in ("agents", "agents/inbox", "agents/inbox/archive"):
            self.assertEqual(stat.S_IMODE((self.vault / directory).stat().st_mode), 0o750)
        self.assertEqual(stat.S_IMODE(snapshot.parent.stat().st_mode), 0o750)

    def test_model_failure_keeps_source_and_is_reported(self):
        def fail(*_):
            raise TimeoutError("model timeout")
        self.assertEqual(self.run_sweep(fail), 1)
        self.assertTrue(self.source.exists())
        self.assertIn("model timeout", self.reports()[0].read_text())

    def test_one_failure_does_not_prevent_other_captures_filing(self):
        (self.vault / "_inbox/second.md").write_text("Second capture")
        def model(raw, _):
            if raw == "Second capture":
                return result()
            raise TimeoutError("model timeout")
        self.assertEqual(self.run_sweep(model), 1)
        self.assertTrue(self.source.exists())
        self.assertFalse((self.vault / "_inbox/second.md").exists())
        report = self.reports()[0].read_text()
        self.assertIn("model timeout", report)
        self.assertIn("Resources/A filed note.md", report)

    def test_missing_mocs_is_reported_and_retains_source(self):
        (self.vault / "MOCs/Home MOC.md").unlink()
        self.assertEqual(self.run_sweep(), 1)
        self.assertTrue(self.source.exists())
        self.assertIn("no regular MOC notes", self.reports()[0].read_text())

    def test_concurrent_edit_during_model_is_retained(self):
        def editing_model(*_):
            self.source.write_text("New user edit")
            return result()
        self.assertEqual(self.run_sweep(editing_model), 1)
        self.assertEqual(self.source.read_text(), "New user edit")
        self.assertFalse((self.vault / "Resources/A filed note.md").exists())

    def test_last_instant_replacement_is_archived_and_restored(self):
        rename = os.rename
        def racing_rename(*args, **kwargs):
            replacement = self.source.with_name("replacement.tmp")
            replacement.write_text("Last instant edit")
            os.replace(replacement, self.source)
            rename(*args, **kwargs)
        with patch.object(inbox.os, "rename", racing_rename):
            self.assertEqual(self.run_sweep(), 1)
        self.assertEqual(self.source.read_text(), "Last instant edit")
        self.assertEqual(next(self.vault.glob("agents/inbox/archive/*/original.md")).read_text(),
                         "Last instant edit")

    def test_new_capture_after_move_is_never_overwritten(self):
        rename = os.rename
        def racing_rename(*args, **kwargs):
            rename(*args, **kwargs)
            self.source.write_text("Fresh capture")
        with patch.object(inbox.os, "rename", racing_rename):
            self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(self.source.read_text(), "Fresh capture")

    def test_existing_editor_descriptor_remains_in_archive(self):
        with self.source.open("a") as editor:
            self.assertEqual(self.run_sweep(), 0)
            editor.write("\nLater edit")
        self.assertIn("Later edit", next(self.vault.glob("agents/inbox/archive/*/original.md")).read_text())

    def test_failed_output_restores_original(self):
        writer = inbox.write_new
        def failing_writer(directory, name, raw, **kwargs):
            if name == "A filed note.md":
                raise OSError("disk full")
            writer(directory, name, raw, **kwargs)
        with patch.object(inbox, "write_new", failing_writer):
            self.assertEqual(self.run_sweep(), 1)
        self.assertEqual(self.source.read_text(), "A complete original capture.")
        self.assertIn("disk full", self.reports()[0].read_text())

    def test_oversized_capture_is_not_truncated_or_sent(self):
        raw = "x" * (inbox.MAX_INPUT + 1)
        self.source.write_text(raw)
        def unexpected(*_):
            self.fail("oversized note sent to model")
        self.assertEqual(self.run_sweep(unexpected), 1)
        self.assertEqual(self.source.read_text(), raw)
        self.assertEqual(next(self.vault.glob("agents/inbox/archive/*/snapshot.md")).read_text(), raw)

    def test_source_symlink_is_not_read(self):
        outside = self.vault / "outside.md"
        outside.write_text("Private")
        self.source.unlink()
        self.source.symlink_to(outside)
        self.assertEqual(self.run_sweep(), 1)
        self.assertTrue(self.source.is_symlink())
        self.assertEqual(outside.read_text(), "Private")

    def test_destination_symlink_is_not_followed(self):
        outside = self.vault / "outside"
        outside.mkdir()
        (self.vault / "Areas").symlink_to(outside)
        self.assertEqual(self.run_sweep(lambda *_: {**result(), "folder": "Areas"}), 1)
        self.assertTrue(self.source.exists())
        self.assertEqual(list(outside.iterdir()), [])

    def test_moc_symlink_is_not_accepted(self):
        (self.vault / "MOCs/Fake.md").symlink_to(self.source)
        self.assertEqual(self.run_sweep(lambda *_: {**result(), "moc": "Fake"}), 1)
        self.assertTrue(self.source.exists())

    def test_destination_collision_preserves_existing_note(self):
        (self.vault / "Resources").mkdir()
        original = self.vault / "Resources/A filed note.md"
        original.write_text("Existing")
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(original.read_text(), "Existing")
        self.assertTrue((self.vault / "Resources/A filed note (2).md").exists())


if __name__ == "__main__":
    unittest.main()
