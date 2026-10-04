"""Dead-link fixer tests: a temporary vault, no network."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("fixer", Path(__file__).with_name("dead-link-fixer.py"))
fixer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixer)


class DeadLinkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vault = Path(self.temp.name)
        self.write("MOCs/Home MOC.md", "# Home MOC")
        self.write("Resources/hella.md", "The Proxmox host. [[Home MOC]]")
        self.write("Areas/Scan 2026-07-11.md", "A security scan. [[Home MOC]]")

    def write(self, rel, text):
        (self.vault / rel).parent.mkdir(parents=True, exist_ok=True)
        (self.vault / rel).write_text(text)

    def found(self):
        return fixer.find_dead(fixer.scan(self.vault))

    def test_dead_and_misspelt_links_of_filed_notes_are_told_apart(self):
        self.write("Areas/Handoff.md",
                   "See [[heimdall]], [[Resources/hella]], [[Scan — 2026-07-11]] and [[hella|the host]].")
        self.assertEqual(self.found(), ({"Handoff": ["heimdall"]},
                                        {"Handoff": {"Scan — 2026-07-11": "Scan 2026-07-11"}}))

    def test_code_archive_links_and_logs_are_not_dead_links(self):
        self.write("Resources/Launcher.md",
                   "```bash\nif [[ ! -d \"${VENV}\" ]]; then\n```\nUse `[[ -f x ]]` and [[...]].\n"
                   "Original: [[agents/inbox/archive/abc/original]]")
        self.write("journal/2026-08-12.md", "The digest mentions [[heimdall]].")
        self.write("Resources/Talk logs/Talk 2026-10-03.md", "muninn said [[Inbox filing report]].")
        self.write("Resources/Gardener Report.md", "- [[Launcher]] links to missing [[nothing]]")
        self.assertEqual(self.found(), ({}, {}))

    def test_stub_takes_the_linked_name_and_never_overwrites(self):
        self.write("Areas/Handoff.md", "See [[heimdall]].")
        self.write("Areas/Another.md", "Also [[heimdall]].")
        self.assertTrue(fixer.create_stub(self.vault, "heimdall", ["Handoff", "Another"], "2026-10-04"))
        stub = (self.vault / "Resources/heimdall.md").read_text()
        for expected in ("type: stub", "# heimdall", "- [[Another]]\n- [[Handoff]]", "[[Home MOC]]"):
            self.assertIn(expected, stub)
        self.assertEqual(self.found(), ({}, {}))   # the link resolves now
        for name in ("heimdall", "a: b", "../escape"):
            self.assertFalse(fixer.create_stub(self.vault, name, ["Handoff"], "2026-10-04"))
        self.assertEqual((self.vault / "Resources/heimdall.md").read_text(), stub)

    def test_report_separates_missing_from_misspelt(self):
        dead, misspelt = {"Handoff": ["heimdall"]}, {"Handoff": {"Scan — 2026-07-11": "Scan 2026-07-11"}}
        fixer.write_report(self.vault, dead, misspelt, ["heimdall"], 4, "2026-10-04")
        report = (self.vault / "Resources/Dead Link Report.md").read_text()
        for expected in ("2 dead links in 1 of 4 notes", "## [[Handoff]]", "- Links to missing **heimdall**",
                         "- Links to **Scan — 2026-07-11**, which is probably [[Scan 2026-07-11]]",
                         "## Stubs created (1)", "- [[heimdall]]"):
            self.assertIn(expected, report)
        fixer.write_report(self.vault, {}, {}, [], 4, "2026-10-04")
        self.assertIn("no dead links found across 4 notes", (self.vault / "Resources/Dead Link Report.md").read_text())


if __name__ == "__main__":
    unittest.main()
