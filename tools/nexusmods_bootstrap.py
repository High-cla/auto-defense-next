#!/usr/bin/env python3
"""One-time Nexus Mods bootstrap for PBZ Auto Defense."""
from __future__ import annotations
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

API = os.environ.get("NEXUSMODS_API_BASE", "https://api.nexusmods.com/v3").rstrip("/")
GAME = "phantombladezero"
FILE_NAME = "PBZ Auto Defense"
MAX_SINGLE = 100 * 1024 * 1024


def safe_error(raw: bytes) -> str:
    value = raw.decode("utf-8", errors="replace")
    value = re.sub(r"https?://\S+", "[URL redacted]", value)
    value = re.sub(r'"(presigned_url|complete_presigned_url)"\s*:\s*"[^"]+"',
                   r'"\1":"[redacted]"', value)
    return value[:1000]


def api(key: str, method: str, path: str, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    headers = {"apikey": key, "User-Agent": "PBZ-Auto-Defense-bootstrap",
               "Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"{method} {path}: HTTP {exc.code}: {safe_error(exc.read())}") from None
    except urllib.error.URLError:
        raise RuntimeError(f"{method} {path}: network error") from None
    return json.loads(raw) if raw else {}


def put_signed(url: str, filename: str, data: bytes, md5_b64: str):
    req = urllib.request.Request(
        url, data=data, method="PUT",
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(data)),
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Content-MD5": md5_b64,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            if response.status not in (200, 201, 204):
                raise RuntimeError(f"Storage PUT failed: HTTP {response.status}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Storage PUT failed: HTTP {exc.code}: {safe_error(exc.read())}") from None
    except urllib.error.URLError:
        raise RuntimeError("Storage PUT failed; presigned URL redacted") from None


def output(values):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            for key, value in values.items():
                f.write(f"{key}={value}\n")


def summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")


def main():
    if os.environ.get("CONFIRM_INITIAL_UPLOAD", "").lower() != "true":
        raise RuntimeError("Set confirm_initial_upload=true to authorize the first upload.")
    key = os.environ.get("NEXUSMODS_API_KEY", "").strip()
    mod_id = os.environ.get("NEXUSMODS_MOD_ID", "").strip()
    candidate = os.environ.get("NEXUSMODS_FILE_ID_CANDIDATE", "").strip()
    if not key:
        raise RuntimeError("Missing NEXUSMODS_API_KEY Secret.")
    if not re.fullmatch(r"[0-9]+", mod_id):
        raise RuntimeError("NEXUSMODS_MOD_ID must be the numeric mod page ID.")
    if candidate and not re.fullmatch(r"[0-9]+", candidate):
        raise RuntimeError("NEXUSMODS_FILE_ID_CANDIDATE must be numeric.")
    if len(sys.argv) != 2:
        raise RuntimeError("Usage: nexusmods_bootstrap.py <release-zip>")

    archive_path = Path(sys.argv[1])
    match = re.fullmatch(r"pbz-auto-defense-v([A-Za-z0-9.-]+)\.zip", archive_path.name)
    if not archive_path.is_file() or not match:
        raise RuntimeError("Expected dist/pbz-auto-defense-v<version>.zip.")
    version = match.group(1)
    data = archive_path.read_bytes()
    if not data or len(data) >= MAX_SINGLE:
        raise RuntimeError("Single-part bootstrap requires a non-empty ZIP smaller than 100 MiB.")
    with zipfile.ZipFile(archive_path) as z:
        bad = z.testzip()
        if bad:
            raise RuntimeError(f"Corrupt ZIP member: {bad}")
        names = set(z.namelist())
        required = {
            "pbz-auto-defense/enabled.txt",
            "pbz-auto-defense/pbz-auto-defense.modsmenu.json",
            "pbz-auto-defense/data/ad_data.lua",
            "pbz-auto-defense/Scripts/main.lua",
        }
        if required - names:
            raise RuntimeError("ZIP is missing required runtime files: " + ", ".join(sorted(required - names)))
        forbidden = [n for n in names if any(x in n.lower() for x in
                     ("auto_defense_log", "auto_defense_ledger", "ad_events",
                      "perf_log", "hit_times", "learned_hits", ".config.json",
                      "/backup/", "/tests/", "/tools/"))]
        if forbidden:
            raise RuntimeError("ZIP contains runtime state or development files: " + ", ".join(forbidden[:8]))

    # Resolve and validate the URL-facing, game-scoped mod ID.
    print(f"Checking Phantom Blade Zero mod {mod_id}.")
    mod = api(key, "GET", f"/games/{GAME}/mods/{mod_id}").get("data")
    if not isinstance(mod, dict) or str(mod.get("game_scoped_id", "")) != mod_id:
        raise RuntimeError("NEXUSMODS_MOD_ID did not resolve to this Phantom Blade Zero mod.")
    internal_id = str(mod.get("id", "")).strip()
    if not internal_id:
        raise RuntimeError("Get Mod response did not contain its internal ID.")

    files = api(key, "GET", f"/mods/{internal_id}/files").get("data", {}).get("mod_files")
    if not isinstance(files, list):
        raise RuntimeError("Get Mod Files response incomplete; refusing to risk a duplicate.")
    candidate_record = None
    named = []
    for item in files:
        if not isinstance(item, dict):
            continue
        if candidate and str(item.get("id", "")) == candidate:
            candidate_record = item
        if item.get("name") == FILE_NAME:
            named.append(item)
    if candidate_record and candidate_record.get("name") != FILE_NAME:
        raise RuntimeError("Candidate file ID exists but belongs to a different file name.")
    if len(named) > 1:
        raise RuntimeError("Multiple PBZ Auto Defense file entries found; resolve duplicates manually.")
    if named and candidate and str(named[0].get("id", "")) != candidate:
        raise RuntimeError("Existing PBZ Auto Defense file ID differs from the supplied candidate ID.")
    if named and "versions_count" not in named[0]:
        # Absence is not zero: treating it as "no versions yet" silently creates a
        # second version of a file that may already have releases (review P1-1).
        raise RuntimeError("Get Mod Files response has no versions_count; refusing to risk a duplicate upload.")
    if named and int(named[0].get("versions_count", 0) or 0) > 0:
        file_id = str(named[0]["id"])
        output({"file_id": file_id, "file_version_id": "", "already_uploaded": "true"})
        summary(["## Existing PBZ Auto Defense file detected",
                 f"- File ID: {file_id}", "- No upload was made.",
                 "- Save this as the repository variable NEXUSMODS_FILE_ID."])
        print(f"Existing file already has versions: {file_id}; no upload performed.")
        return 0

    existing_empty_id = str(named[0]["id"]) if named else ""
    digest = hashlib.md5(data, usedforsecurity=False).digest()
    md5_hex = digest.hex()
    md5_b64 = base64.b64encode(digest).decode("ascii")
    filename = archive_path.name
    print(f"Creating upload session for {filename} ({len(data)} bytes).")
    up = api(key, "POST", "/uploads",
             {"filename": filename, "size_bytes": len(data), "md5": md5_hex}).get("data")
    if not isinstance(up, dict) or not up.get("id") or not up.get("presigned_url"):
        raise RuntimeError("Create Upload response missing upload ID or presigned URL.")
    upload_id = str(up["id"])
    put_signed(str(up["presigned_url"]), filename, data, md5_b64)
    api(key, "POST", f"/uploads/{upload_id}/finalise")

    delay = 2.0
    for attempt in range(60):
        state_data = api(key, "GET", f"/uploads/{upload_id}").get("data", {})
        state = str(state_data.get("state", "")) if isinstance(state_data, dict) else ""
        if state == "available":
            break
        if state not in ("created", ""):
            raise RuntimeError(f"Unexpected upload state: {state}")
        if attempt < 59:
            time.sleep(delay)
            delay = min(delay * 1.5, 15)
    else:
        raise RuntimeError("Upload did not reach available before polling limit.")

    payload = {
        "upload_id": upload_id,
        "name": FILE_NAME,
        "version": version,
        "description": (f"PBZ Auto Defense {version} for Phantom Blade Zero (Steam build 26367565). "
                        "Requires UE4SS v4.0.0 or newer.")[:255],
        "file_category": "main",
        "primary_mod_manager_download": True,
        "allow_mod_manager_download": True,
        "show_requirements_pop_up": False,
        "update_mod_version": True,
    }
    if existing_empty_id:
        result = api(key, "POST", f"/mod-files/{existing_empty_id}/versions", payload).get("data")
        file_id = existing_empty_id
        operation = "created first version on existing empty file entry"
    else:
        # The OpenAPI CreateModFileRequest expects the game-scoped ID obtained from Get Mod.
        payload["mod_id"] = str(mod["game_scoped_id"])
        result = api(key, "POST", "/mod-files", payload).get("data")
        file_id = str(result.get("id", "")) if isinstance(result, dict) else ""
        operation = "created new Main file entry"
    if not file_id:
        raise RuntimeError("Create file response did not contain a file ID.")
    version_id = str(result.get("id", "")) if existing_empty_id and isinstance(result, dict) else ""
    output({"file_id": file_id, "file_version_id": version_id, "already_uploaded": "false"})
    sha = hashlib.sha256(data).hexdigest()
    summary(["## PBZ Auto Defense first Nexus Mods upload complete",
             f"- Mod page: https://www.nexusmods.com/{GAME}/mods/{mod_id}",
             f"- Version: {version}", f"- File ID: {file_id}",
             f"- File version ID: {version_id or 'not returned'}",
             f"- Operation: {operation}", f"- Archive: {filename}",
             f"- SHA-256: {sha}", "",
             "Save the File ID above as repository variable NEXUSMODS_FILE_ID before future GitHub Releases."])
    print(f"First upload complete. File ID: {file_id}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
