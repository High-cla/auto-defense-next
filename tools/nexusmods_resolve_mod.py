#!/usr/bin/env python3
"""Resolve and verify the Nexus API mod/file IDs before publishing an update.

The public Nexus mod page URL contains a game-scoped mod ID. The official
upload-action also needs the API's internal mod ID for its changelog request.
The file ID is checked against that mod's own file list before it is emitted.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any

BASE = os.environ.get("NEXUSMODS_API_BASE", "https://api.nexusmods.com/v3").rstrip("/")
GAME = "phantombladezero"
EXPECTED_FILE_NAME = "PBZ Auto Defense"


def verify_file_belongs_to_mod(files: Any, file_id: str) -> dict[str, Any]:
    """Return the configured file only when it is listed under the resolved mod."""
    if not isinstance(files, list):
        raise RuntimeError("Get Mod Files response did not contain a mod_files list.")

    matches = [
        item for item in files
        if isinstance(item, dict) and str(item.get("id", "")).strip() == file_id
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"NEXUSMODS_FILE_ID {file_id} was not found exactly once in this "
            "mod's file list."
        )

    record = matches[0]
    actual_name = str(record.get("name", "")).strip()
    if actual_name != EXPECTED_FILE_NAME:
        raise RuntimeError(
            f"NEXUSMODS_FILE_ID {file_id} belongs to file {actual_name!r}, "
            f"not {EXPECTED_FILE_NAME!r}."
        )
    return record


def api_get(key: str, path: str) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{BASE}{path}",
        headers={
            "apikey": key,
            "Accept": "application/json",
            "User-Agent": "PBZ-Auto-Defense-mod-id-resolver",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        detail = re.sub(r"https?://\S+", "[URL redacted]", detail)
        detail = re.sub(
            r'(?i)(apikey|api_key|token|signature)([=: ]+)[^,\s"\']+',
            r"\1\2[redacted]",
            detail,
        )
        raise RuntimeError(
            f"Nexus Mods API GET {path}: HTTP {exc.code}: {detail[:800]}"
        ) from None
    except urllib.error.URLError:
        raise RuntimeError(f"Nexus Mods API GET {path}: network error") from None
    except json.JSONDecodeError:
        raise RuntimeError(
            f"Nexus Mods API GET {path}: invalid JSON response"
        ) from None

    if not isinstance(payload, dict):
        raise RuntimeError(f"Nexus Mods API GET {path}: unexpected response type.")
    return payload


def main() -> int:
    key = os.environ.get("NEXUSMODS_API_KEY", "").strip()
    site_id = os.environ.get("NEXUSMODS_MOD_ID", "").strip()
    file_id = os.environ.get("NEXUSMODS_FILE_ID", "").strip()
    if not key:
        raise RuntimeError("Missing NEXUSMODS_API_KEY Secret.")
    if not re.fullmatch(r"[0-9]+", site_id):
        raise RuntimeError(
            "NEXUSMODS_MOD_ID must be the numeric mod ID from the site URL."
        )
    if not re.fullmatch(r"[0-9]+", file_id):
        raise RuntimeError(
            "NEXUSMODS_FILE_ID must be the numeric File ID returned by the "
            "first upload."
        )

    mod_response = api_get(key, f"/games/{GAME}/mods/{site_id}")
    mod = mod_response.get("data")
    if not isinstance(mod, dict):
        raise RuntimeError("Get Mod response did not contain a data object.")
    if str(mod.get("game_scoped_id", "")) != site_id:
        raise RuntimeError("Resolved mod does not match NEXUSMODS_MOD_ID.")
    api_mod_id = str(mod.get("id", "")).strip()
    if not api_mod_id:
        raise RuntimeError("Get Mod response did not contain the API mod ID.")

    files_response = api_get(key, f"/mods/{api_mod_id}/files")
    files_data = files_response.get("data")
    if not isinstance(files_data, dict):
        raise RuntimeError("Get Mod Files response did not contain a data object.")
    verify_file_belongs_to_mod(files_data.get("mod_files"), file_id)

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"api_mod_id={api_mod_id}\n")
            stream.write(f"verified_file_id={file_id}\n")
    print(
        f"Verified Nexus file {file_id} ({EXPECTED_FILE_NAME}) belongs to "
        f"Phantom Blade Zero mod {site_id}."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
