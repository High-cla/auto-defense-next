#!/usr/bin/env python3
"""Offline tests for the std/reference alignment check."""
from __future__ import annotations

import unittest

import check_std

STD = """\
base: lua51
globals:
  NotifyOnNewObject:
    args:
      - type: any
  ClearAllDelayedActions:
    args: []
"""

DOC = """\
## 2.5 NotifyOnNewObject

`NotifyOnNewObject("/Script/Engine.PlayerController", fn)` runs on construction.

| `ClearAllDelayedActions()` | drops every action |
"""


class ParseStdGlobalsTests(unittest.TestCase):
    def test_reads_block_entries(self) -> None:
        self.assertEqual(
            check_std.parse_std_globals(STD),
            {"NotifyOnNewObject", "ClearAllDelayedActions"},
        )

    def test_reads_inline_values(self) -> None:
        text = "globals:\n  Foo: any\n  Bar: {any: true}\n"
        self.assertEqual(check_std.parse_std_globals(text), {"Foo", "Bar"})

    def test_ignores_comments_and_entry_fields(self) -> None:
        text = (
            "# a comment\n"
            "base: lua51\n"
            "globals:\n"
            "  # an entry comment\n"
            "  Foo:\n"
            "    any: true\n"
            "    args:\n"
            "      - type: any\n"
        )
        self.assertEqual(check_std.parse_std_globals(text), {"Foo"})

    def test_rejects_a_file_without_a_globals_section(self) -> None:
        with self.assertRaisesRegex(ValueError, "no globals"):
            check_std.parse_std_globals("base: lua51\n")

    def test_rejects_a_malformed_entry(self) -> None:
        with self.assertRaisesRegex(ValueError, "cannot read a global entry"):
            check_std.parse_std_globals("globals:\n  not an entry\n")

    def test_deduplicates_a_repeated_entry(self) -> None:
        text = "globals:\n  Foo:\n    any: true\n  Foo:\n    any: true\n"
        self.assertEqual(check_std.parse_std_globals(text), {"Foo"})


class ExtractDocApiNamesTests(unittest.TestCase):
    def test_reads_spans_links_and_headings(self) -> None:
        text = DOC + "[TArray](https://example.test/tarray.md)\n### 6.2 TMap\n"
        self.assertEqual(
            check_std.extract_doc_api_names(text),
            {"NotifyOnNewObject", "ClearAllDelayedActions", "TArray", "TMap"},
        )

    def test_ignores_lowercase_and_member_spans(self) -> None:
        text = "Use `pcall(fn)` and `obj:IsValid()` and `Key.F1`.\n"
        self.assertEqual(check_std.extract_doc_api_names(text), {"Key"})

    def test_an_empty_document_documents_nothing(self) -> None:
        self.assertEqual(check_std.extract_doc_api_names(""), set())


class FindGlobalUsesTests(unittest.TestCase):
    NAMES = {"NotifyOnNewObject", "IsValid", "LoopInGameThreadAfterFrames"}

    def test_reads_a_plain_global_read(self) -> None:
        code = "local ok = type(NotifyOnNewObject) == 'function'\n"
        self.assertEqual(
            check_std.find_global_uses(code, self.NAMES), {"NotifyOnNewObject"}
        )

    def test_ignores_comments_strings_and_member_calls(self) -> None:
        code = (
            "-- with a NotifyOnNewObject watch the loop never ran\n"
            "--[[ IsValid() inside a long comment ]]\n"
            "local ok = obj:IsValid()\n"
            "local msg = 'LoopInGameThreadAfterFrames is gone'\n"
            "local raw = [[NotifyOnNewObject]]\n"
        )
        self.assertEqual(check_std.find_global_uses(code, self.NAMES), set())


class CheckTests(unittest.TestCase):
    def test_aligned_inputs_pass(self) -> None:
        report = check_std.check(STD, DOC, {"main.lua": "NotifyOnNewObject('x', fn)\n"})
        self.assertEqual(report.missing, [])

    def test_a_documented_call_missing_from_the_std_fails(self) -> None:
        report = check_std.check(
            "globals:\n  ClearAllDelayedActions:\n    args: []\n",
            DOC,
            {"main.lua": "NotifyOnNewObject('x', fn)\n"},
        )
        self.assertEqual(report.missing, ["NotifyOnNewObject"])
        self.assertEqual(report.usage["NotifyOnNewObject"], ("main.lua",))

    def test_a_call_the_reference_does_not_document_is_ignored(self) -> None:
        report = check_std.check(STD, DOC, {"main.lua": "SomeUndocumentedThing(1)\n"})
        self.assertEqual(report.missing, [])
        self.assertEqual(report.usage, {})

    def test_an_empty_reference_documents_nothing(self) -> None:
        report = check_std.check(STD, "", {"main.lua": "NotifyOnNewObject('x', fn)\n"})
        self.assertEqual(report.missing, [])
        self.assertEqual(report.doc_names, frozenset())

    def test_two_scripts_reading_one_name_report_it_once(self) -> None:
        report = check_std.check(
            "globals:\n  ClearAllDelayedActions:\n    args: []\n",
            DOC,
            {
                "main.lua": "NotifyOnNewObject('x', fn)\n",
                "ad_query.lua": "NotifyOnNewObject('y', fn)\n",
            },
        )
        self.assertEqual(report.missing, ["NotifyOnNewObject"])
        self.assertEqual(
            report.usage["NotifyOnNewObject"], ("ad_query.lua", "main.lua")
        )

    def test_a_broken_std_file_raises(self) -> None:
        with self.assertRaisesRegex(ValueError, "no globals"):
            check_std.check("base: lua51\n", DOC, {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
