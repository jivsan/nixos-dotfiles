"""Regression tests for durable, confined inbox filing (no network required)."""
import importlib.util
import io
import json
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


def no_jev(*_):
    raise ValueError("no key")


def no_bridge(*_):
    raise AssertionError("capture handed to the bridge")


def jev(moc=0.9, folder=0.9):
    return lambda *_: {"folder": ("Areas", folder), "moc": ("Knowledge MOC", moc)}


class Reply:
    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return io.BytesIO(self.payload)

    def __exit__(self, *_):
        return False


class VaultCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vault = Path(self.temp.name)
        (self.vault / "_inbox").mkdir()
        (self.vault / "MOCs").mkdir()
        (self.vault / "MOCs/Home MOC.md").write_text("# Home MOC")
        self.source = self.vault / "_inbox/capture.md"
        self.source.write_text("A complete original capture.")

    def run_sweep(self, model=lambda *_: result(), place=no_jev, bridge=no_bridge, near=lambda *_: []):
        return inbox.sweep(self.vault, model, place, bridge, near)

    def reports(self):
        return list((self.vault / "Resources/Reports").glob("*.md"))


class FilingTests(VaultCase):
    def test_files_and_archives_full_original_and_reports(self):
        raw = "Facts exceeding the old 8000-byte truncation.\n" * 500
        self.source.write_text(raw)
        seen = []
        self.assertEqual(self.run_sweep(lambda text, *_: (seen.append(text), result())[1]), 0)
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

    def test_body_with_its_own_heading_is_not_given_a_second(self):
        self.assertEqual(self.run_sweep(lambda *_: {**result(), "body": "# Mine\n\nFacts."}), 0)
        filed = (self.vault / "Resources/A filed note.md").read_text()
        self.assertIn("---\n\n# Mine\n\nFacts.", filed)
        self.assertNotIn("# A filed note", filed)

    def test_invalid_model_data_keeps_capture_and_reports_failure(self):
        invalid = [[], {}, {**result(), "moc": "../../escape"},
                   {**result(), "title": "../escape"}, {**result(), "tags": [12]},
                   {**result(), "body": None}, {**result(), "folder": "_inbox"}]
        for response in invalid:
            with self.subTest(response=response):
                self.assertEqual(self.run_sweep(lambda *_: response), 1)
                self.assertTrue(self.source.exists())
        self.assertTrue(all("status: failed" in p.read_text() for p in self.reports()))

    def test_title_punctuation_is_repaired_instead_of_failing_the_capture(self):
        titles = {"Inbox: todo/jev requests [draft]": "Inbox — todo jev requests draft",
                  "  Notes:\n#one|two  ": "Notes — one two",
                  "x" * 200: "x" * 160}
        for given, filed in titles.items():
            with self.subTest(title=given):
                self.source.write_text("A complete original capture.")
                self.assertEqual(self.run_sweep(lambda *_: {**result(), "title": given}), 0)
                self.assertTrue((self.vault / "Resources" / (filed + ".md")).is_file())

    def test_unusable_title_is_named_in_the_report(self):
        for given in (None, "", "#[]", ".hidden", "../escape"):
            with self.subTest(title=given):
                self.assertEqual(self.run_sweep(lambda *_: {**result(), "title": given}), 1)
                self.assertTrue(self.source.exists())
        self.assertTrue(any("invalid model title: '../escape'" in p.read_text() for p in self.reports()))
        self.assertEqual(list(self.vault.glob("Resources/*.md")), [])

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
        def model(raw, *_):
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


class WriterTests(unittest.TestCase):
    def classify(self, raw, content):
        sent = []
        def urlopen(request, timeout):
            sent.append(json.loads(request.data))
            return Reply({"choices": [{"message": {"content": content}}]})
        with patch.dict(os.environ, {"OPENAI_API_KEY": "key"}), \
                patch.object(inbox.urllib.request, "urlopen", urlopen):
            return inbox.classify(raw, ["Home MOC"]), sent[0]["messages"][0]["content"]

    def test_fenced_or_chatty_reply_is_still_parsed(self):
        for content in (json.dumps(result()), "```json\n" + json.dumps(result()) + "\n```",
                        "Here is the note:\n" + json.dumps(result(), indent=2) + "\nDone."):
            with self.subTest(content=content):
                note, prompt = self.classify("A short capture", content)
                self.assertEqual(note, result())
                self.assertIn("body (clean markdown", prompt)

    def test_reply_without_json_reports_what_the_model_said(self):
        for content in ("I cannot file this.", None, "}{"):
            with self.subTest(content=content), self.assertRaises(ValueError) as caught:
                self.classify("A short capture", content)
        with self.assertRaises(ValueError) as caught:
            self.classify("A short capture", "I cannot file this.")
        self.assertIn("I cannot file this.", str(caught.exception))

    def test_existing_notes_are_offered_as_link_targets(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": "key"}), \
                patch.object(inbox.urllib.request, "urlopen") as urlopen:
            urlopen.return_value = Reply({"choices": [{"message": {"content": json.dumps(result())}}]})
            inbox.classify("A short capture", ["Home MOC"], ["Backups on odyn"])
        prompt = json.loads(urlopen.call_args.args[0].data)["messages"][0]["content"]
        self.assertIn('Existing notes: ["Backups on odyn"]', prompt)
        self.assertIn("related (0-4 titles", prompt)

    def test_long_capture_keeps_its_own_text(self):
        text = "# My heading\n\n" + "A fact worth keeping exactly.\n" * 100
        reply = {k: v for k, v in result().items() if k != "body"}
        note, prompt = self.classify("---\ntype: note\n---\n\n" + text, "```\n" + json.dumps(reply) + "\n```")
        self.assertEqual(note["body"], text.strip())
        self.assertNotIn("body (", prompt)


class PlacementTests(VaultCase):
    def setUp(self):
        super().setUp()
        (self.vault / "MOCs/Knowledge MOC.md").write_text(
            "---\ntype: moc\n---\n# Knowledge MOC\nHub for filed knowledge.\n\n- [[A note]]\n")

    def test_related_notes_are_linked_only_when_they_exist(self):
        (self.vault / "Resources").mkdir()
        (self.vault / "Resources/Backups on odyn.md").write_text("Backups.")
        seen = []
        def model(raw, mocs, notes):
            seen.append(notes)
            return {**result(), "related": ["Backups on odyn", "A note nobody wrote", "Backups on odyn", 7]}
        self.assertEqual(self.run_sweep(model), 0)
        self.assertEqual(seen, [["Backups on odyn"]])
        filed = (self.vault / "Resources/A filed note.md").read_text()
        self.assertIn("[[MOCs/Home MOC]]\n\nRelated: [[Backups on odyn]]\n\nOriginal: ", filed)
        self.assertNotIn("nobody wrote", filed)
        report = self.reports()[0].read_text()
        self.assertIn('- related: ["Backups on odyn"]', report)
        self.assertIn("- filed: [[Resources/A filed note]]", report)

    def test_notes_nearest_in_meaning_lead_the_list_the_writer_chooses_from(self):
        (self.vault / "Resources").mkdir()
        for index, name in enumerate(("Old note", "Backups on odyn", "Newest note")):
            (self.vault / f"Resources/{name}.md").write_text("Text.")
            os.utime(self.vault / f"Resources/{name}.md", (index, index))
        seen = []
        def model(raw, mocs, notes):
            seen.append(notes)
            return {**result(), "related": ["Backups on odyn"]}
        asked = []
        def near(text):
            asked.append(text)
            return ["Backups on odyn", "A note the index knows but the vault lost", "Backups on odyn"]
        self.assertEqual(self.run_sweep(model, near=near), 0)
        self.assertEqual(asked, ["A complete original capture."])
        self.assertEqual(seen, [["Backups on odyn", "Newest note", "Old note"]])
        self.assertIn("Related: [[Backups on odyn]]", (self.vault / "Resources/A filed note.md").read_text())

    def test_without_the_embedding_index_the_newest_notes_are_offered(self):
        (self.vault / "Resources").mkdir()
        (self.vault / "Resources/Backups on odyn.md").write_text("Text.")
        def down(_):
            raise OSError("bridge unreachable")
        for near in (down, lambda _: []):
            with self.subTest(near=near):
                seen = []
                self.source.write_text("A complete original capture.")
                self.assertEqual(self.run_sweep(lambda raw, mocs, notes: (seen.append(notes), result())[1], near=near), 0)
                self.assertEqual(seen[0][-1], "Backups on odyn")

    def test_nearest_asks_the_bridge_and_keeps_the_names(self):
        sent = []
        def urlopen(request, timeout):
            sent.append((request.full_url, json.loads(request.data)))
            return Reply({"notes": [{"path": "Areas/hermod.md", "name": "hermod", "score": 0.61}, "junk", {"name": 7}]})
        with patch.object(inbox.urllib.request, "urlopen", urlopen):
            self.assertEqual(inbox.nearest("x" * 5000), ["hermod"])
        self.assertTrue(sent[0][0].endswith("/bridge/similar"))
        self.assertEqual((len(sent[0][1]["text"]), sent[0][1]["k"]), (2000, inbox.NEAR))

    def test_note_without_related_notes_gets_no_related_line(self):
        self.assertEqual(self.run_sweep(lambda *_: {**result(), "related": "Home MOC"}), 0)
        self.assertNotIn("Related:", (self.vault / "Resources/A filed note.md").read_text())

    def test_generated_todo_board_is_never_offered_as_a_hub(self):
        (self.vault / "MOCs/TODO MOC.md").write_text("# TODO MOC\nEvery open checkbox in the vault.")
        seen = []
        self.assertEqual(self.run_sweep(lambda raw, mocs, notes: (seen.append(mocs), result())[1]), 0)
        self.assertEqual(seen, [["Home MOC", "Knowledge MOC"]])

    def test_jev_decides_folder_and_moc(self):
        seen = []
        def place(text, hubs):
            seen.append((text, hubs))
            return jev()(text, hubs)
        self.assertEqual(self.run_sweep(place=place), 0)
        self.assertEqual(seen, [("A complete original capture.",
                                 {"Home MOC": "Home MOC", "Knowledge MOC": "Hub for filed knowledge."})])
        self.assertIn("[[MOCs/Knowledge MOC]]", (self.vault / "Areas/A filed note.md").read_text())
        self.assertFalse((self.vault / "Resources/A filed note.md").exists())
        self.assertIn("jev (Knowledge MOC 0.90, Areas 0.90)", self.reports()[0].read_text())

    def test_jev_decision_is_reported_even_when_the_writer_fails(self):
        def fail(*_):
            raise TimeoutError("model timeout")
        self.assertEqual(self.run_sweep(fail, place=jev()), 1)
        report = self.reports()[0].read_text()
        self.assertIn("jev (Knowledge MOC 0.90, Areas 0.90)", report)
        self.assertIn("model timeout", report)

    def test_unsure_folder_keeps_the_writers_folder(self):
        self.assertEqual(self.run_sweep(place=jev(folder=0.2)), 0)
        self.assertIn("[[MOCs/Knowledge MOC]]", (self.vault / "Resources/A filed note.md").read_text())

    def test_unsure_moc_is_the_writers_call_and_nothing_is_parked(self):
        self.assertEqual(self.run_sweep(place=jev(moc=0.3)), 0)
        self.assertFalse(self.source.exists())
        self.assertFalse((self.vault / "_inbox/review").exists())
        self.assertIn("[[MOCs/Home MOC]]", (self.vault / "Areas/A filed note.md").read_text())
        report = self.reports()[0].read_text()
        self.assertIn("status: completed", report)
        self.assertIn("minimax (jev unsure: Knowledge MOC 0.30, Areas 0.90)", report)

    def test_edit_while_jev_decides_is_kept_for_the_next_sweep(self):
        def editing_place(*_):
            self.source.write_text("New user edit")
            return jev(moc=0.3)()
        self.assertEqual(self.run_sweep(place=editing_place), 1)
        self.assertEqual(self.source.read_text(), "New user edit")
        self.assertFalse((self.vault / "Areas/A filed note.md").exists())

    def test_padded_body_is_replaced_by_the_captures_own_words(self):
        self.source.write_text("---\ntype: note\n---\n\nMake a report of what changed today.")
        padded = "## Todo\n" + "- [ ] A step nobody asked for\n" * 20
        self.assertEqual(self.run_sweep(lambda *_: {**result(), "body": padded}), 0)
        filed = (self.vault / "Resources/A filed note.md").read_text()
        self.assertIn("\n\nMake a report of what changed today.\n\n", filed)
        self.assertNotIn("nobody asked for", filed)

    def test_jev_failure_falls_back_to_the_writers_choice(self):
        self.assertEqual(self.run_sweep(), 0)
        self.assertIn("[[MOCs/Home MOC]]", (self.vault / "Resources/A filed note.md").read_text())
        self.assertIn("minimax (jev: no key)", self.reports()[0].read_text())

    def test_locate_asks_jev_and_maps_choices_back(self):
        sent = []
        def urlopen(request, timeout):
            sent.append(json.loads(request.data))
            return Reply({"answers": {"folder": {"choice": "areas", "confidence": 0.8},
                                      "moc": {"choice": "knowledge_moc", "confidence": 0.7}}})
        hubs = {"Home MOC": "The top hub.", "Knowledge MOC": "Hub for filed knowledge."}
        with patch.dict(os.environ, {"OPENAI_API_KEY": "key"}), \
                patch.object(inbox.urllib.request, "urlopen", urlopen):
            self.assertEqual(inbox.locate("A capture", hubs),
                             {"folder": ("Areas", 0.8), "moc": ("Knowledge MOC", 0.7)})
        self.assertEqual(sent[0]["state"], {"capture": "A capture"})
        self.assertEqual(sent[0]["questions"]["moc"]["criteria"],
                         {"home_moc": "Home MOC: The top hub.",
                          "knowledge_moc": "Knowledge MOC: Hub for filed knowledge."})
        self.assertEqual(set(sent[0]["questions"]["folder"]["criteria"]), {"areas", "resources"})

    def test_locate_rejects_unknown_or_unscored_choices(self):
        replies = [{}, {"answers": {"folder": {"choice": "areas", "confidence": 0.8},
                                    "moc": {"choice": "elsewhere", "confidence": 0.9}}},
                   {"answers": {"folder": {"choice": "areas", "confidence": "high"},
                                "moc": {"choice": "home_moc", "confidence": 0.9}}}]
        for reply in replies:
            with self.subTest(reply=reply), patch.dict(os.environ, {"OPENAI_API_KEY": "key"}), \
                    patch.object(inbox.urllib.request, "urlopen", lambda *_, **__: Reply(reply)):
                with self.assertRaises(ValueError):
                    inbox.locate("A capture", {"Home MOC": "The top hub."})


class RequestTests(VaultCase):
    def setUp(self):
        super().setUp()
        self.source.write_text("todo: research my backup options")

    def answer(self, **extra):
        return {"answer": "Done.", "sources": [], "route": {"tier": "answer", "via": "jev"}, **extra}

    def test_task_goes_to_the_bridge_and_is_not_filed_as_a_note(self):
        seen = []
        def bridge(request):
            seen.append(request)
            self.assertFalse(self.source.exists())
            return self.answer(job="abc123", agent="hermes", route={"tier": "agent", "via": "jev"})
        def unexpected(*_):
            self.fail("request filed as a note")
        self.assertEqual(self.run_sweep(unexpected, unexpected, bridge), 0)
        self.assertEqual(seen, ["research my backup options"])
        self.assertFalse(self.source.exists())
        self.assertEqual(next(self.vault.glob("agents/inbox/archive/*/original.md")).read_text(),
                         "todo: research my backup options")
        self.assertFalse((self.vault / "Resources/A filed note.md").exists())
        report = self.reports()[0].read_text()
        self.assertIn("abc123 (hermes)", report)
        self.assertIn("agent via jev", report)
        self.assertEqual(self.run_sweep(unexpected, unexpected, bridge), 0)
        self.assertEqual(len(seen), 1)

    def test_question_behind_frontmatter_is_answered_in_the_report(self):
        self.source.write_text("---\ntype: note\nstatus: inbox\n---\n\nJev : what is hermod's address?\n")
        seen = []
        self.assertEqual(self.run_sweep(bridge=lambda r: (seen.append(r), self.answer(answer="10.0.20.21."))[1]), 0)
        self.assertEqual(seen, ["what is hermod's address?"])
        self.assertIn("\n10.0.20.21.\n", self.reports()[0].read_text())

    def test_unmarked_or_empty_requests_stay_ordinary_notes(self):
        for text in ("Remember todo: nothing", "# todo: heading", "todo:", "todolist: milk"):
            with self.subTest(text=text):
                self.assertIsNone(inbox.request_in(text))
        self.assertEqual(inbox.request_in("TODO:  fix it\nplease"), "fix it\nplease")

    def test_busy_bridge_keeps_request_without_failing(self):
        busy = self.answer(answer="Two agent jobs are already running.", busy=True,
                           route={"tier": "agent", "via": "jev"})
        self.assertEqual(self.run_sweep(bridge=lambda _: busy), 0)
        self.assertEqual(self.source.read_text(), "todo: research my backup options")
        self.assertIn("Two agent jobs are already running.", self.reports()[0].read_text())
        self.assertFalse((self.vault / "Resources/A filed note.md").exists())

    def test_bridge_failure_or_missing_agent_restores_request(self):
        def down(_):
            raise OSError("connection refused")
        no_agent = self.answer(answer="No agent is connected.", route={"tier": "agent", "via": "jev"})
        failed_skill = self.answer(answer="Could not start gardener.", action={"type": "run", "ok": False},
                                   route={"tier": "command", "via": "jev"})
        for bridge in (down, lambda _: no_agent, lambda _: failed_skill, lambda _: {"answer": "odd"}):
            with self.subTest(bridge=bridge):
                self.assertEqual(self.run_sweep(bridge=bridge), 1)
                self.assertEqual(self.source.read_text(), "todo: research my backup options")
        self.assertFalse((self.vault / "Resources/A filed note.md").exists())

    def test_started_skill_is_reported(self):
        started = self.answer(answer="Started gardener.", action={"type": "run", "skill": "gardener", "ok": True},
                              route={"tier": "command", "via": "jev"})
        self.assertEqual(self.run_sweep(bridge=lambda _: started), 0)
        self.assertFalse(self.source.exists())
        self.assertIn("Started gardener.", self.reports()[0].read_text())

    def test_request_jev_reads_as_a_note_is_filed(self):
        note = self.answer(answer="Captured to the inbox.", action={"type": "capture", "text": "x"},
                           route={"tier": "command", "via": "jev"})
        self.assertEqual(self.run_sweep(bridge=lambda _: note), 0)
        self.assertFalse(self.source.exists())
        self.assertTrue((self.vault / "Resources/A filed note.md").exists())
        self.assertEqual(next(self.vault.glob("agents/inbox/archive/*/original.md")).read_text(),
                         "todo: research my backup options")

    def test_note_like_request_with_unsure_moc_is_filed_from_the_archive(self):
        (self.vault / "MOCs/Knowledge MOC.md").write_text("# Knowledge MOC")
        note = self.answer(action={"type": "view", "view": "skills"}, route={"tier": "command", "via": "jev"})
        self.assertEqual(self.run_sweep(place=jev(moc=0.1), bridge=lambda _: note), 0)
        self.assertFalse(self.source.exists())
        self.assertFalse((self.vault / "_inbox/review").exists())
        self.assertIn("[[MOCs/Home MOC]]", (self.vault / "Areas/A filed note.md").read_text())
        self.assertEqual(next(self.vault.glob("agents/inbox/archive/*/original.md")).read_text(),
                         "todo: research my backup options")

    def test_note_like_request_that_fails_filing_is_restored(self):
        note = self.answer(action={"type": "capture", "text": "x"}, route={"tier": "command", "via": "jev"})
        def fail(*_):
            raise TimeoutError("model timeout")
        self.assertEqual(self.run_sweep(fail, bridge=lambda _: note), 1)
        self.assertEqual(self.source.read_text(), "todo: research my backup options")

    def test_overlong_request_is_never_sent(self):
        self.source.write_text("todo: " + "x" * (inbox.MAX_REQUEST + 1))
        self.assertEqual(self.run_sweep(), 1)
        self.assertTrue(self.source.exists())

    def test_dispatch_posts_the_request_to_the_bridge(self):
        sent = []
        def urlopen(request, timeout):
            sent.append((request.full_url, json.loads(request.data)))
            return Reply(self.answer())
        with patch.object(inbox.urllib.request, "urlopen", urlopen):
            self.assertEqual(inbox.dispatch("research backups"), self.answer())
        self.assertEqual(sent, [("http://127.0.0.1:8093/bridge/talk",
                                 {"text": "research backups", "target": "auto"})])


if __name__ == "__main__":
    unittest.main()
