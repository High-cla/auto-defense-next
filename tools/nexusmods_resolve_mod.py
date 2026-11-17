#!/usr/bin/env python3
"""Resolve the Nexus API mod identifier used by /mods/{id}/changelogs.

NEXUSMODS_MOD_ID is the numeric game-scoped ID from the public site URL.
The upload-action changelog endpoint uses the API's internal mod ID instead.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("NEXUSMODS_API_BASE", "https://api.nexusmods.com/v3").rstrip("/")
GAME = "phantombladezero"


def main() -> int:
    key = os.environ.get("NEXUSMODS_API_KEY", "").strip()
    site_id = os.environ.get("NEXUSMODS_MOD_ID", "").strip()
    if not key:
        raise RuntimeError("Missing NEXUSMODS_API_KEY Secret.")
    if not re.fullmatch(r"[0-9]+", site_id):
        raise RuntimeError("NEXUSMODS_MOD_ID must be the numeric mod ID from the site URL.")

    request = urllib.request.Request(
        f"{BASE}/games/{GAME}/mods/{site_id}",
        headers={"apikey": key, "Accept": "application/json",
                 "User-Agent": "PBZ-Auto-Defense-mod-id-resolver"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # Do not print response URLs or request headers.
        detail = exc.read().decode("utf-8", errors="replace")[:800]
        detail = re.sub(r"https?://\S+", "[URL redacted]", detail)
        raise RuntimeError(f"Get Mod failed: HTTP {exc.code}: {detail}") from None
    except urllib.error.URLError:
        raise RuntimeError("Get Mod failed: network error") from None

    mod = payload.get("data")
    if not isinstance(mod, dict):
        raise RuntimeError("Get Mod response did not contain a data object.")
    if str(mod.get("game_scoped_id", "")) != site_id:
        raise RuntimeError("Resolved mod does not match NEXUSMODS_MOD_ID.")
    api_id = str(mod.get("id", "")).strip()
    if not api_id:
        raise RuntimeError("Get Mod response did not contain the API mod ID.")

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"api_mod_id={api_id}\n")
    print("Resolved Nexus API mod ID for changelog publishing.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
