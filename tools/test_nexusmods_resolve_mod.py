#!/usr/bin/env python3
"""Offline tests for the Nexus mod/file identity guard."""
from __future__ import annotations

import unittest

from nexusmods_resolve_mod import verify_file_belongs_to_mod


class VerifyFileBelongsToModTests(unittest.TestCase):
    def setUp(self) -> None:
        self.files = [
            {"id": "8404851", "name": "PBZ Auto Defense"},
            {"id": "8404852", "name": "Another Mod File"},
        ]

    def test_accepts_file_listed_under_target_mod(self) -> None:
        record = verify_file_belongs_to_mod(self.files, "8404851")
        self.assertEqual(record["name"], "PBZ Auto Defense")

    def test_rejects_file_id_from_another_mod(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "not found exactly once"):
            verify_file_belongs_to_mod(self.files, "9999999")

    def test_rejects_wrong_file_name(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "not 'PBZ Auto Defense'"):
            verify_file_belongs_to_mod(self.files, "8404852")

    def test_rejects_duplicate_file_ids(self) -> None:
        duplicated = self.files + [{"id": "8404851", "name": "PBZ Auto Defense"}]
        with self.assertRaisesRegex(RuntimeError, "not found exactly once"):
            verify_file_belongs_to_mod(duplicated, "8404851")

    def test_rejects_incomplete_api_response(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "mod_files list"):
            verify_file_belongs_to_mod(None, "8404851")


if __name__ == "__main__":
    unittest.main(verbosity=2)
