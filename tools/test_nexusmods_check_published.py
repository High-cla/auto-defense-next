#!/usr/bin/env python3
"""Offline tests for the published-version guard."""
from __future__ import annotations

import unittest

from nexusmods_check_published import decide, version_strings


class VersionStringsTests(unittest.TestCase):
    def test_reads_labels_from_a_plain_list(self) -> None:
        labels, count = version_strings(
            [{"version": "1.6.4"}, {"version_name": "v1.6.3"}]
        )
        self.assertEqual(labels, {"1.6.4", "1.6.3"})
        self.assertEqual(count, 2)

    def test_reads_labels_from_the_data_envelope(self) -> None:
        labels, _ = version_strings({"versions": [{"name": "1.6.4"}], "total": 1})
        self.assertEqual(labels, {"1.6.4"})

    def test_ignores_entries_without_a_label(self) -> None:
        labels, count = version_strings([{}, {"id": "1"}, "junk"])
        self.assertEqual(labels, set())
        self.assertEqual(count, 3)

    def test_rejects_an_empty_response(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "refusing to risk"):
            version_strings(None)

    def test_rejects_an_unknown_envelope(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "no versions list"):
            version_strings({"items_total": 3})

    def test_rejects_a_non_list_payload(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "not a list"):
            version_strings("nope")


class DecideTests(unittest.TestCase):
    def test_an_existing_version_skips_the_upload(self) -> None:
        already, message = decide([{"version": "1.6.4"}], "v1.6.4")
        self.assertTrue(already)
        self.assertIn("already published", message)

    def test_a_new_version_is_allowed(self) -> None:
        already, message = decide([{"version": "1.6.3"}], "1.6.4")
        self.assertFalse(already)
        self.assertIn("not published yet", message)

    def test_a_file_without_versions_is_allowed(self) -> None:
        already, message = decide([], "1.6.4")
        self.assertFalse(already)
        self.assertIn("no versions", message)

    def test_an_empty_version_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "refusing to risk"):
            decide([], "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
