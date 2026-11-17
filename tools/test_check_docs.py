#!/usr/bin/env python3
"""Tests for tools/check_docs.py - a doc gate that cannot fail is decoration."""
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load():
    spec = importlib.util.spec_from_file_location("check_docs", HERE / "check_docs.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MAIN = "tl.VERSION = \"1.6.5\"\ntl.api = { \"a\", \"b\" }\n" + "x\n" * 8
MODULES = """# Module layout (1.6.5)

| File | Lines | Owns |
| --- | ---: | --- |
| `Scripts/main.lua` | 10 | everything |
| `Scripts/ad_json.lua` / `Scripts/menu_config.lua` | 3 / 4 | json; menu |

`tl.api` lists the 2 names other code may use.
"""
README = "主运行时 `Scripts/main.lua`（约 10 行）+ 2 个边界模块"


class DocCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "Scripts").mkdir()
        (self.root / "Scripts/main.lua").write_text(MAIN, encoding="utf-8")
        (self.root / "Scripts/ad_json.lua").write_text("a\nb\nc\n", encoding="utf-8")
        (self.root / "Scripts/menu_config.lua").write_text(
            "a\nb\nc\nd\n", encoding="utf-8"
        )
        (self.root / "docs").mkdir()
        (self.root / "docs/MODULES.md").write_text(MODULES, encoding="utf-8")
        (self.root / "README.md").write_text(README, encoding="utf-8")
        (self.root / "pbz-auto-defense.modsmenu.json").write_text(
            '{"version": "1.6.5"}', encoding="utf-8"
        )
        (self.root / "tools").mkdir()
        self.mod = load()

    def tearDown(self):
        self.tmp.cleanup()

    def test_consistent_tree_passes(self):
        self.assertEqual(self.mod.check(self.root), [])

    def test_line_count_drift_is_named(self):
        (self.root / "Scripts/ad_json.lua").write_text(
            "a\nb\nc\nd\ne\n", encoding="utf-8"
        )
        bad = self.mod.check(self.root)
        self.assertTrue(any("ad_json" in b and "doc 3" in b for b in bad), bad)

    def test_missing_file_is_named(self):
        (self.root / "Scripts/menu_config.lua").unlink()
        bad = self.mod.check(self.root)
        self.assertTrue(
            any("does not exist" in b and "menu_config" in b for b in bad), bad
        )

    def test_version_disagreement_is_named(self):
        (self.root / "pbz-auto-defense.modsmenu.json").write_text(
            '{"version": "1.6.4"}', encoding="utf-8"
        )
        bad = self.mod.check(self.root)
        self.assertTrue(any("version strings disagree" in b for b in bad), bad)

    def test_api_claim_drift_is_named(self):
        (self.root / "docs/MODULES.md").write_text(
            MODULES.replace("the 2 names", "the 5 names"), encoding="utf-8"
        )
        bad = self.mod.check(self.root)
        self.assertTrue(any("tl.api count" in b for b in bad), bad)

    def test_readme_size_drift_is_named(self):
        (self.root / "README.md").write_text(
            README.replace("10 行", "900 行"), encoding="utf-8"
        )
        bad = self.mod.check(self.root)
        self.assertTrue(any("main runtime size" in b for b in bad), bad)

    def test_module_count_drift_is_named(self):
        (self.root / "README.md").write_text(
            README.replace("2 个边界模块", "3 个边界模块"), encoding="utf-8"
        )
        bad = self.mod.check(self.root)
        self.assertTrue(any("module count" in b for b in bad), bad)

    def test_broken_relative_link_is_named(self):
        (self.root / "docs/EXTRA.md").write_text(
            "see [main](../Scripts/missing.lua) and [ok](../Scripts/main.lua)\n",
            encoding="utf-8",
        )
        bad = self.mod.check(self.root)
        self.assertTrue(
            any("docs/EXTRA.md links to a path" in b for b in bad), bad
        )
        self.assertFalse(any("Scripts/main.lua" in b and "EXTRA" in b for b in bad), bad)

    def test_openmods_pair_must_stay_together(self):
        (self.root / "openmods.json").write_text('{"openmods": 1}', encoding="utf-8")
        bad = self.mod.check(self.root)
        self.assertTrue(any("openmods.md is not next to it" in b for b in bad), bad)
        (self.root / "openmods.md").write_text("# mod page\n", encoding="utf-8")
        self.assertEqual(self.mod.check(self.root), [])

    def test_external_and_anchor_links_are_ignored(self):
        (self.root / "docs/EXTRA.md").write_text(
            "see [up](https://example.com/x) and [toc](#top) and [mail](mailto:a@b)\n",
            encoding="utf-8",
        )
        self.assertEqual(self.mod.check(self.root), [])

    def test_api_count_reads_the_block_not_the_log(self):
        src = 'tl.api = { "a", "b", "c" }\nlog("tl api: %d", #tl.api)'
        self.assertEqual(self.mod.api_count(src), 3)

    def test_missing_api_block_is_an_error(self):
        with self.assertRaises(SystemExit):
            self.mod.api_count("local x = 1")


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=1))
