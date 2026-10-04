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
