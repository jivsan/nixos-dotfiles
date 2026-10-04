"""Embedding index tests: a temporary note index and a fake model, no network."""
import array
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

import embed


def vec(*head):
    """A full-length unit vector that starts with the given numbers."""
    return embed.shorten(list(head) + [0.0] * (embed.DIM - len(head)))


class Reply:
    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return io.BytesIO(self.payload)

    def __exit__(self, *_):
        return False


class EmbedCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.index, self.store = str(root / "index.db"), str(root / "embeddings.db")
        db = sqlite3.connect(self.index)
        db.execute("CREATE TABLE notes (path TEXT PRIMARY KEY, mtime INTEGER, title TEXT, body TEXT, tags TEXT)")
        db.commit()
        db.close()
        embed._QUERIES.clear()
        embed._LOADED.update(stamp=None, rows=[])
        # the notes here are a few words long; the tests about near-empty notes set the real floor
        floor = mock.patch.object(embed, "MIN_SUBSTANCE", 0)
        floor.start()
        self.addCleanup(floor.stop)

    def note(self, path, mtime=1, title="", body="Text."):
        db = sqlite3.connect(self.index)
        db.execute("INSERT OR REPLACE INTO notes VALUES (?, ?, ?, ?, '')", (path, mtime, title, body))
        db.commit()
        db.close()

    def drop(self, path):
        db = sqlite3.connect(self.index)
        db.execute("DELETE FROM notes WHERE path = ?", (path,))
        db.commit()
        db.close()

    def sync(self, embedder):
        return embed.sync(embedder, self.index, self.store, log=lambda _: None)

    def stored(self):
        return {path for path, _ in embed.vectors(self.store)}


class SyncTests(EmbedCase):
    def test_notes_are_embedded_once_and_again_only_when_they_change(self):
        self.note("Areas/hermod.md", title="hermod", body="The Hermes VM.")
        self.note("Resources/Backups.md", body="Backups on odyn.")
        seen = []
        def model(text):
            seen.append(text)
            return vec(1.0)
        self.assertEqual(self.sync(model), (2, 0))
        self.assertEqual(seen, ["hermod\n\nThe Hermes VM.", "Backups\n\nBackups on odyn."])   # title, else the file name
        self.assertEqual(self.sync(model), (0, 0))
        self.note("Resources/Backups.md", mtime=2, body="Backups moved to PBS.")
        self.assertEqual(self.sync(model), (1, 0))
        self.assertEqual(seen[-1], "Backups\n\nBackups moved to PBS.")

    def test_logs_are_left_out_and_deleted_notes_are_removed(self):
        for path in ("Areas/hermod.md", "Resources/Talk logs/Talk 2026-10-03.md",
                     "Resources/Reports/inbox-2026-10-03.md", "Resources/Reports/alert-x.md",
                     "_inbox/capture.md", "Resources/Reports/A real report (8a1f2879).md"):
            self.note(path)
        self.assertEqual(self.sync(lambda _: vec(1.0)), (2, 0))
        self.assertEqual(self.stored(), {"Areas/hermod.md", "Resources/Reports/A real report (8a1f2879).md"})
        self.drop("Areas/hermod.md")
        self.assertEqual(self.sync(lambda _: vec(1.0)), (0, 1))
        self.assertEqual(self.stored(), {"Resources/Reports/A real report (8a1f2879).md"})

    def test_notes_that_say_nothing_and_files_about_the_vault_are_left_out(self):
        quiet = "\n# 2026-09-10\n\n## huginn digest (23:04)\n- Quiet day — no notes changed.\n\n[[Home MOC]]\n"
        stub = ("\n# heimdall\n\n> [!missing] This note was auto-created because it was linked but missing.\n\n"
                "Linked from:\n- [[Nexterm SSH Key Rollout and Fleet Inventory 2026-08-12]]\n\nSee also: [[Homelab MOC]]\n")
        capture = "\n# Save to vault request\n\nsave it to my vault\n\nSee also: [[MOCs/Home MOC]]\n\nOriginal: [[agents/inbox/archive/9441/original]]\n"
        short = "\n# Codex and Claude login on heimdall\n\nLogging into Codex and Claude on heimdall is done.\n\nSee also: [[MOCs/Agents MOC]]\n"
        notes = {"journal/2026-09-10.md": quiet, "Resources/heimdall.md": stub, "Resources/Save to vault request.md": capture,
                 "CLAUDE.md": "Vault conventions for agents, a long enough text to count as a note.",
                 "Home.md": "The dashboard of the vault, a long enough text to count as a note.",
                 "journal/README.md": "Daily notes; huginn appends a digest each night, long enough to count.",
                 "Resources/Codex and Claude login on heimdall.md": short,
                 "Areas/CLAUDE.md notes.md": "A note of hers that only happens to have a similar name, with real text in it."}
        for path, body in notes.items():
            self.note(path, body=body)
        with mock.patch.object(embed, "MIN_SUBSTANCE", 40):
            self.assertEqual(self.sync(lambda _: vec(1.0)), (2, 0))
            # a short note that states a fact is still a note
            self.assertEqual(self.stored(), {"Resources/Codex and Claude login on heimdall.md", "Areas/CLAUDE.md notes.md"})
            # a stub that someone has filled in is a note again
            self.note("Resources/heimdall.md", mtime=2, body="\n# heimdall\n\nThe services VM on hella: bridge, huginn, Grafana and Immich.\n")
            self.assertEqual(self.sync(lambda _: vec(1.0)), (1, 0))
            self.assertIn("Resources/heimdall.md", self.stored())

    def test_a_note_that_becomes_empty_loses_its_vector(self):
        self.note("Areas/a.md", body="A note with enough in it to be about something real.")
        with mock.patch.object(embed, "MIN_SUBSTANCE", 40):
            self.assertEqual(self.sync(lambda _: vec(1.0)), (1, 0))
            self.note("Areas/a.md", mtime=2, body="# a\n\nSee also: [[Home MOC]]\n")
            self.assertEqual(self.sync(lambda _: vec(1.0)), (0, 1))
        self.assertEqual(self.stored(), set())

    def test_substance_is_what_a_note_says_in_its_own_words(self):
        self.assertEqual(embed.substance("# Title\n\nUp: [[Agents MOC]]\nRelated: [[a]] · [[b]]\n- [[only a link]]\n"), "")
        self.assertEqual(embed.substance("## Notes\nThe switch is at 10.0.20.2, see [[bifrost]].\n\nOriginal: [[x/original]]"),
                         "The switch is at 10 0 20 2 see")

    def test_work_done_before_the_server_went_away_is_kept(self):
        self.note("Areas/a.md")
        self.note("Areas/b.md")
        def flaky(text):
            if text.startswith("b"):
                raise OSError("mimir unreachable")
            return vec(1.0)
        with self.assertRaises(OSError):
            self.sync(flaky)
        self.assertEqual(self.stored(), {"Areas/a.md"})
        self.assertEqual(self.sync(lambda _: vec(1.0)), (1, 0))   # only the one that was missing

    def test_another_model_means_every_note_is_embedded_again(self):
        self.note("Areas/a.md")
        self.sync(lambda _: vec(1.0))
        with mock.patch.object(embed, "MODEL", "another-model"):
            self.assertEqual(embed.vectors(self.store), [])   # vectors of two models are never compared
            self.assertEqual(self.sync(lambda _: vec(1.0)), (1, 0))
            self.assertEqual(self.stored(), {"Areas/a.md"})


class SearchTests(EmbedCase):
    def setUp(self):
        super().setUp()
        self.by_text = {"hermod": vec(1.0, 0.0), "Backups": vec(0.0, 1.0), "Proxmox": vec(0.6, 0.8)}
        for name in self.by_text:
            self.note(f"Areas/{name}.md")
        self.sync(lambda text: self.by_text[text.split("\n")[0]])

    def test_notes_are_ranked_by_similarity(self):
        ranked = embed.nearest(vec(0.0, 1.0), 2, self.store)
        self.assertEqual([path for path, _ in ranked], ["Areas/Backups.md", "Areas/Proxmox.md"])
        self.assertAlmostEqual(ranked[0][1], 1.0, places=5)
        self.assertAlmostEqual(ranked[1][1], 0.8, places=5)

    def test_a_question_is_embedded_once_with_the_instruction(self):
        with mock.patch.object(embed, "embed", return_value=vec(1.0, 0.1)) as model:
            first = embed.similar("  where does hermes run?  ", 1, store=self.store)
            embed.similar("where does hermes run?", 3, store=self.store)
        self.assertEqual(first[0][0], "Areas/hermod.md")
        model.assert_called_once()
        self.assertEqual(model.call_args.args[0], embed.INSTRUCT + "where does hermes run?")
        # questions have their own instance: one that is embedding a note makes them wait for it
        self.assertEqual(model.call_args.args[2], embed.QUERY_URL)
        self.assertNotEqual(embed.QUERY_URL, embed.URL)

    def test_no_server_or_no_vectors_means_no_results_not_an_error(self):
        with mock.patch.object(embed, "embed", side_effect=OSError("mimir unreachable")):
            self.assertEqual(embed.similar("anything", store=self.store), [])
        with mock.patch.object(embed, "embed") as model:
            self.assertEqual(embed.similar("anything", store=self.store + ".missing"), [])
            self.assertEqual(embed.similar("   ", store=self.store), [])
        model.assert_not_called()


class RequestTests(unittest.TestCase):
    def test_long_text_is_cut_and_the_vector_shortened_to_unit_length(self):
        full = [3.0, 4.0] + [0.0] * (embed.DIM - 2) + [9.0] * 100    # the tail beyond DIM is dropped
        with mock.patch.object(embed.urllib.request, "urlopen", return_value=Reply({"data": [{"embedding": full}]})) as urlopen:
            vector = embed.embed("x" * (embed.MAX_CHARS + 500))
        sent = json.loads(urlopen.call_args.args[0].data)
        self.assertEqual((sent["model"], len(sent["input"])), (embed.MODEL, embed.MAX_CHARS))
        self.assertTrue(urlopen.call_args.args[0].full_url.endswith("/v1/embeddings"))
        self.assertEqual(len(vector), embed.DIM)
        self.assertIsInstance(vector, array.array)
        self.assertAlmostEqual(vector[0], 0.6, places=5)
        self.assertAlmostEqual(vector[1], 0.8, places=5)

    def test_an_empty_vector_is_an_error(self):
        with self.assertRaises(ValueError):
            embed.shorten([0.0] * 2560)


if __name__ == "__main__":
    unittest.main()
