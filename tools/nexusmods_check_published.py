#!/usr/bin/env python3
"""Refuse to publish a version that already exists on the Nexus Mods file.

A GitHub Release can be deleted and re-published with the same tag, which fires
the `release: published` event again. Without this guard the same archive is
uploaded twice, so the check fails closed whenever the API response cannot prove
that the version is new.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

API = os.environ.get("NEXUSMODS_API_BASE", "https://api.nexusmods.com/v3").rstrip("/")
ENTRY_KEYS = ("versions", "mod_file_versions", "items")
LABEL_KEYS = ("version", "version_name", "name", "display_name")


def version_strings(payload: object) -> tuple[set[str], int]:
    """Version labels the API reported, plus how many entries were seen.

    Raises when the response cannot be interpreted: an unknown shape must not be
    read as "nothing published yet".
    """
    if payload is None:
        raise RuntimeError("file versions response is empty; refusing to risk a duplicate")
    entries = payload
    if isinstance(payload, dict):
        for key in ENTRY_KEYS:
            if isinstance(payload.get(key), list):
                entries = payload[key]
                break
        else:
            raise RuntimeError("file versions response has no versions list; refusing to risk a duplicate")
    if not isinstance(entries, list):
        raise RuntimeError("file versions response is not a list; refusing to risk a duplicate")
    labels: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for key in LABEL_KEYS:
            value = entry.get(key)
            if isinstance(value, str) and value.strip():
                labels.add(value.strip().lstrip("v"))
    return labels, len(entries)


def decide(payload: object, version: str) -> tuple[bool, str]:
    """True when this version is already published."""
    wanted = version.strip().lstrip("v")
    if not wanted:
        raise RuntimeError("release version is empty; refusing to risk a duplicate")
    labels, count = version_strings(payload)
    if wanted in labels:
        return True, f"version {wanted} is already published ({count} versions on this file); no upload made"
    if count == 0:
        return False, f"version {wanted} not published yet (the file has no versions)"
    return False, f"version {wanted} not published yet ({count} versions on this file)"


def fetch_versions(key: str, file_id: str) -> object:
    request = urllib.request.Request(
        f"{API}/mod-files/{file_id}/versions",
        headers={
            "apikey": key,
            "Accept": "application/json",
            "User-Agent": "PBZ-Auto-Defense-version-check",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GET /mod-files/{file_id}/versions: HTTP {exc.code}") from None
    except urllib.error.URLError:
        raise RuntimeError(f"GET /mod-files/{file_id}/versions: network error") from None
    if not raw:
        return None
    body = json.loads(raw)
    return body.get("data") if isinstance(body, dict) else body


def main() -> int:
    key = os.environ.get("NEXUSMODS_API_KEY", "").strip()
    file_id = os.environ.get("NEXUSMODS_FILE_ID", "").strip()
    version = os.environ.get("RELEASE_VERSION", "").strip()
    if not key or not file_id or not version:
        raise SystemExit("NEXUSMODS_API_KEY, NEXUSMODS_FILE_ID and RELEASE_VERSION are required")
    already, message = decide(fetch_versions(key, file_id), version)
    print(message)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write("## Nexus Mods version check\n- " + message + "\n")
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write(f"already_published={'true' if already else 'false'}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
