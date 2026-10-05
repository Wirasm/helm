#!/usr/bin/env python3
"""The copied-store UI fixture must leave its source contents and timestamps intact."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("store_fixture", Path(__file__).with_name("test-store-links.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class CopiedStoreTests(unittest.TestCase):
    def test_fixture_writes_leave_source_intact(self):
        for linked in (False, True):
            with self.subTest(linked=linked), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                source = root / "source"
                source.mkdir()
                (source / "broken-link").symlink_to("missing-target")
                referents = root / "referents"
                referents.mkdir()
                names = ["project.json", "report.md", "page.html", "sibling.js"]
                names += [f"recent-{index}.md" for index in range(25)]
                originals = []
                for index, name in enumerate(names):
                    original = (referents if linked else source) / name
                    original.write_text("ORIGINAL " + name)
                    if linked:
                        target = original if index % 2 == 0 else Path(os.path.relpath(original, source))
                        (source / name).symlink_to(target)
                    originals.append(original)
                reports = (referents if linked else source) / "reports"
                reports.mkdir()
                if linked:
                    (source / "reports").symlink_to(Path(os.path.relpath(reports, source)), target_is_directory=True)
                for name in ("launch-queue.md", "later.md"):
                    original = reports / name
                    original.write_text("ORIGINAL " + name)
                    originals.append(original)
                for original in originals:
                    os.utime(original, ns=(1_600_000_000_000_000_000,) * 2)
                before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in originals}

                copy = root / "copy"
                fixture.seed_store(source, copy, root / "workspace")
                # The agent stub creates this file after the initial chat inventory loads.
                (copy / "reports/later.md").write_text("# Created after chat opened\n")

                for original, state in before.items():
                    with self.subTest(path=original.name):
                        self.assertEqual((original.read_bytes(), original.stat().st_mtime_ns), state)
                self.assertEqual((copy / "reports/launch-queue.md").read_text(), "ORIGINAL launch-queue.md")
                self.assertIn("Markdown from benchd", (copy / "report.md").read_text())
                self.assertIn("Created after chat opened", (copy / "reports/later.md").read_text())
                self.assertFalse((copy / "broken-link").is_symlink())
                self.assertEqual((source / "broken-link").readlink(), Path("missing-target"))


if __name__ == "__main__":
    unittest.main()
