#!/usr/bin/env python3
"""Build the release archive: dist/pbz-auto-defense-v<version>.zip

The archive holds only what the game loads, laid out so a player can unzip it
straight into <game>/platform/steam/ue4ss/Mods/:

    pbz-auto-defense/
      Scripts/*.lua
      data/ad_data.lua
      enabled.txt
      pbz-auto-defense.modsmenu.json

Documentation, tests, generators and the packager itself stay in the
repository and are deliberately not shipped. Runtime state (logs, ledger,
events, learned timelines, config, backups) belongs to the player and must
never leak into a release either.

    bash tools/package.sh          # writes dist/pbz-auto-defense-v<ver>.zip
"""
import hashlib
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOLDER = "pbz-auto-defense"

INCLUDE = [
    "enabled.txt",
    "pbz-auto-defense.modsmenu.json",
    "data/ad_data.lua",
]
GLOBS = [("Scripts", r"^[A-Za-z0-9_]+\.lua$")]


def version():
    with open(os.path.join(ROOT, "Scripts", "main.lua"), encoding="utf-8") as fh:
        for line in fh:
            hit = re.search(r'tl\.VERSION = "([^"]+)"', line)
            if hit:
                return hit.group(1)
    sys.exit("package: tl.VERSION not found in Scripts/main.lua")


def relpaths():
    for name in INCLUDE:
        yield name
    for folder, pattern in GLOBS:
        rx = re.compile(pattern)
        for name in sorted(os.listdir(os.path.join(ROOT, folder))):
            if rx.match(name):
                yield folder + "/" + name


def main():
    ver = version()
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "pbz-auto-defense-v%s.zip" % ver)
    missing, written = [], 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in relpaths():
            src = os.path.join(ROOT, rel.replace("/", os.sep))
            if not os.path.isfile(src):
                missing.append(rel)
                continue
            info = zipfile.ZipInfo(FOLDER + "/" + rel, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(src, "rb") as fh:
                zf.writestr(info, fh.read())
            written += 1
        root = zipfile.ZipInfo(FOLDER + "/", date_time=(1980, 1, 1, 0, 0, 0))
        root.external_attr = (0o40755 << 16) | 0x10
        zf.writestr(root, b"")
    size = os.path.getsize(out)
    with open(out, "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()
    print("package: v%s -> %s" % (ver, os.path.relpath(out, ROOT)))
    print("package: %d files, %d bytes, sha256 %s" % (written, size, digest))
    if missing:
        print("package: missing (skipped): " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
