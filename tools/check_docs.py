#!/usr/bin/env python3
"""Doc truth check: the numbers the docs state must be the numbers on disk.

Why: MODULES.md once said INTEGRATION 44 while the gate said 63, ad_query 107
while the file had 155 lines, and README counted 2,683 timeline entries while
hit_times.txt had 2,507. Every one of those was a hand copy. What can be derived
is derived here instead; what cannot (assertion counts) is no longer written into
the docs at all - the gate output is the single source of truth.

Usage: python tools/check_docs.py [--root DIR]
Exit: 0 all consistent, 1 any mismatch (printed one per line), 2 unreadable input.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

MODULE_ROW = re.compile(
    r"^\|\s*`([^`]+)`(?:\s*/\s*`([^`]+)`)?\s*\|\s*"
    r"([\d,]+)(?:\s*/\s*([\d,]+))?\s*\|",
    re.M,
)
VERSION_LUA = re.compile(r'tl\.VERSION\s*=\s*"([^"]+)"')
VERSION_MD = re.compile(r"^#\s+Module layout\s+\(([^)]+)\)", re.M)
API_NAMES = re.compile(r"tl\.api\s*=\s*\{(.*?)\}", re.S)
API_CLAIM = re.compile(r"tl\.api`?\s+lists\s+the\s+(\d+)\s+names", re.I)
README_LINES = re.compile(r"主运行时\s*`Scripts/main\.lua`（约\s*([\d,]+)\s*行）")
README_MODULES = re.compile(r"\+\s*(\d+)\s*个边界模块")
LINK = re.compile(r"\]\(<?([^)>\s]+)>?\)")


def lua_lines(path: Path) -> int:
    with path.open("rb") as f:
        return f.read().count(b"\n")


def api_count(source: str) -> int:
    block = API_NAMES.search(source)
    if not block:
        raise SystemExit("check_docs: tl.api block not found in Scripts/main.lua")
    return len(re.findall(r'"[^"]+"', block.group(1)))


def check(root: Path) -> list[str]:
    bad: list[str] = []
    main_lua = root / "Scripts/main.lua"
    if not main_lua.is_file():
        raise SystemExit("check_docs: Scripts/main.lua not found")

    modules = (root / "docs/MODULES.md").read_text(encoding="utf-8")
    for left, right, nleft, nright in MODULE_ROW.findall(modules):
        for name, claimed in ((left, nleft), (right, nright)):
            if not name or not claimed:
                continue
            path = root / name.replace("\\", "/")
            if not path.is_file():
                hint = " (write the repo-relative path, e.g. Scripts/menu_config.lua)" if "/" not in name else ""
                bad.append(f"MODULES.md names a file that does not exist: {name}{hint}")
                continue
            want = int(claimed.replace(",", ""))
            got = lua_lines(path)
            if want != got:
                bad.append(f"MODULES.md line count {name}: doc {want}, disk {got}")

    source = main_lua.read_text(encoding="utf-8", errors="replace")
    versions = {}
    m = VERSION_LUA.search(source)
    if m:
        versions["Scripts/main.lua"] = m.group(1)
    else:
        bad.append("Scripts/main.lua has no tl.VERSION")
    menu_json = root / "pbz-auto-defense.modsmenu.json"
    if menu_json.is_file():
        descriptor = json.loads(menu_json.read_text(encoding="utf-8"))
        versions["pbz-auto-defense.modsmenu.json"] = descriptor.get("version", "?")
    m = VERSION_MD.search(modules)
    if m:
        versions["MODULES.md"] = m.group(1)
    else:
        bad.append("MODULES.md has no '# Module layout (x.y.z)' heading")
    distinct = sorted(set(versions.values()))
    if len(distinct) > 1:
        detail = ", ".join(f"{k} {v}" for k, v in sorted(versions.items()))
        bad.append(f"version strings disagree: {detail}")

    want_api = api_count(source)
    m = API_CLAIM.search(modules)
    if not m:
        bad.append("MODULES.md does not state the tl.api name count")
    elif int(m.group(1)) != want_api:
        bad.append(f"tl.api count: doc {m.group(1)}, code {want_api}")

    # a new module nobody wrote down is how ad_compat.lua went missing for a day
    listed = {left for left, _r, _a, _b in MODULE_ROW.findall(modules)}
    listed |= {right for _l, right, _a, _b in MODULE_ROW.findall(modules) if right}
    listed = {name.replace("\\", "/") for name in listed}
    for path in sorted((root / "Scripts").glob("*.lua")):
        rel = f"Scripts/{path.name}"
        if rel not in listed:
            bad.append(f"MODULES.md does not list {rel}")

    readme = (root / "README.md").read_text(encoding="utf-8")
    m = README_LINES.search(readme)
    if not m:
        bad.append("README does not state the main runtime size")
    else:
        want = int(m.group(1).replace(",", ""))
        got = lua_lines(main_lua)
        if abs(want - got) > 60:
            bad.append(
                f"README main runtime size: doc ~{want}, disk {got} (tolerance 60)"
            )
    m = README_MODULES.search(readme)
    if not m:
        bad.append("README does not state the module count")
    else:
        want = int(m.group(1))
        scripts = root / "Scripts"
        got = sum(
            len(list(scripts.glob(pattern)))
            for pattern in ("ad_*.lua", "menu_config.lua", "toast.lua")
        )
        if want != got:
            bad.append(f"README module count: doc {want}, disk {got}")

    # openmods.schema.json: "Put this file at the root of your mod repository, next to openmods.md"
    if (root / "openmods.json").is_file() and not (root / "openmods.md").is_file():
        bad.append(
            "openmods.json is at the root but openmods.md is not next to it "
            "(the openmods schema requires both at the repository root)"
        )

    # a doc moved without its links is a doc nobody can navigate
    for md in sorted(set(root.glob("*.md")) | set((root / "docs").glob("*.md"))):
        bad.extend(relative_links(md, root))
    return bad


def relative_links(path: Path, root: Path) -> list[str]:
    broken: list[str] = []
    rel = path.relative_to(root).as_posix()
    for target in LINK.findall(path.read_text(encoding="utf-8", errors="replace")):
        if target.startswith(("http://", "https://", "mailto:", "#", "//")):
            continue
        part = target.split("#")[0].strip()
        if part and not (path.parent / part).exists():
            broken.append(f"{rel} links to a path that does not exist: {target}")
    return broken


def main(argv: list[str]) -> int:
    if "--root" in argv:
        root = Path(argv[argv.index("--root") + 1])
    else:
        root = Path(__file__).resolve().parent.parent
    bad = check(root)
    for line in bad:
        print(f"DOC MISMATCH: {line}")
    if bad:
        return 1
    print("docs consistent with disk")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
