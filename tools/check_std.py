#!/usr/bin/env python3
"""Keep the selene std (ue4ss.yml) aligned with the UE4SS Lua API reference.

selene only complains about a name it cannot resolve, and it only looks at names
the scripts actually read. A global that the API reference documents but the std
forgets therefore stays invisible until someone writes the call - at which point
working code fails the linter. This offline check closes that gap: every name
that docs/UE4SS-LUA-API-REFERENCE.md documents AND Scripts/*.lua reads as a
global must be declared in ue4ss.yml.

Exit code 0 means aligned, 1 means at least one documented call has no std entry.
"""
from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STD_PATH = ROOT / "ue4ss.yml"
DOC_PATH = ROOT / "docs" / "UE4SS-LUA-API-REFERENCE.md"
SCRIPTS_DIR = ROOT / "Scripts"

API_NAME = r"[A-Z][A-Za-z0-9_]*"
# A documented name starts a code span (`NotifyOnNewObject(path, fn)`), a link
# label ("[TArray](...)") or a section heading ("### 6.1 TArray").
DOC_SPAN = re.compile(r"`([^`\n]+)`")
DOC_LEADING = re.compile(r"^(" + API_NAME + r")(?![A-Za-z0-9_])")
DOC_LINK = re.compile(r"\[(" + API_NAME + r")\]\(")
DOC_HEADING = re.compile(
    r"^#{2,6}[ \t]+(?:[0-9]+(?:\.[0-9]+)*[ \t]+)?"  # optional "4.2 " numbering
    r"(" + API_NAME + r")(?![A-Za-z0-9_])",
    re.MULTILINE,
)
STD_ENTRY = re.compile(r"^ {2}([A-Za-z_][A-Za-z0-9_]*):")
LONG_BRACKET = re.compile(r"\[(=*)\[")


@dataclass(frozen=True)
class Report:
    """What the check found. missing is what fails the gate."""

    std_names: frozenset[str]
    doc_names: frozenset[str]
    usage: Mapping[str, tuple[str, ...]]

    @property
    def missing(self) -> list[str]:
        """Documented names the scripts read that the std does not declare."""
        return sorted(set(self.usage) - set(self.std_names))


def parse_std_globals(text: str) -> set[str]:
    """Global names declared under the globals: key of a selene std file.

    Raises ValueError when there is no globals section or a line that is neither
    an entry nor a field of one: an empty result from a file that was never read
    would silently disable the check.
    """
    names: set[str] = set()
    in_globals = False
    has_section = False
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            key, _, value = line.partition(":")
            in_globals = key.strip() == "globals"
            has_section = has_section or in_globals
            if in_globals and value.strip() not in ("", "{}"):
                raise ValueError(f"globals must be a block mapping (line {number})")
            continue
        if not in_globals or line.startswith("    "):
            continue  # a field of the entry above: any:, args:, ...
        match = STD_ENTRY.match(line)
        if match is None:
            raise ValueError(
                f"cannot read a global entry on line {number}: {line.strip()!r}"
            )
        names.add(match.group(1))
    if not has_section:
        raise ValueError("no globals: section, so there is no std to check")
    return names


def extract_doc_api_names(text: str) -> set[str]:
    """API names the reference documents, reduced to their bare identifier."""
    names: set[str] = set()
    for span in DOC_SPAN.findall(text):
        match = DOC_LEADING.match(span.strip())
        if match is not None:
            names.add(match.group(1))
    names.update(DOC_LINK.findall(text))
    names.update(DOC_HEADING.findall(text))
    return names


def _skip_long_bracket(code: str, opening: re.Match[str]) -> int:
    closing = "]" + opening.group(1) + "]"
    end = code.find(closing, opening.end())
    return len(code) if end < 0 else end + len(closing)


def strip_lua_noise(code: str) -> str:
    """Blank out comments and string literals, keeping the surrounding code.

    A name that only appears in a comment, a doc string or a log message is not a
    global read, so it must not drag an entry into the std.
    """
    out: list[str] = []
    index = 0
    length = len(code)
    while index < length:
        char = code[index]
        if char == "-" and code.startswith("--", index):
            opening = LONG_BRACKET.match(code, index + 2)
            if opening is None:
                end = code.find("\n", index)
                index = length if end < 0 else end
                continue
            index = _skip_long_bracket(code, opening)
            out.append(" ")
        elif char == "[":
            opening = LONG_BRACKET.match(code, index)
            if opening is None:
                out.append(char)
                index += 1
                continue
            index = _skip_long_bracket(code, opening)
            out.append(" ")
        elif char in "\"'":
            index += 1
            while index < length and code[index] != char:
                index += 2 if code[index] == "\\" else 1
            index += 1
            out.append(" ")
        else:
            out.append(char)
            index += 1
    return "".join(out)


def find_global_uses(code: str, names: Iterable[str]) -> set[str]:
    """Names this source reads as a plain global.

    obj:IsValid() and table.Field are member access and stay out, and so does
    anything inside a comment or a string.
    """
    stripped = strip_lua_noise(code)
    used: set[str] = set()
    for name in names:
        pattern = re.compile(r"(?<![\w.:])" + re.escape(name) + r"(?![\w])")
        if pattern.search(stripped) is not None:
            used.add(name)
    return used


def check(std_text: str, doc_text: str, scripts: Mapping[str, str]) -> Report:
    """Compare the std, the reference and the scripts (see module docstring)."""
    std_names = parse_std_globals(std_text)
    doc_names = extract_doc_api_names(doc_text)
    usage: dict[str, list[str]] = {}
    for path, code in sorted(scripts.items()):
        for name in find_global_uses(code, doc_names):
            usage.setdefault(name, []).append(path)
    return Report(
        std_names=frozenset(std_names),
        doc_names=frozenset(doc_names),
        usage={name: tuple(paths) for name, paths in usage.items()},
    )


def main() -> int:
    try:
        report = check(
            STD_PATH.read_text(encoding="utf-8"),
            DOC_PATH.read_text(encoding="utf-8"),
            {
                path.name: path.read_text(encoding="utf-8")
                for path in sorted(SCRIPTS_DIR.glob("*.lua"))
            },
        )
    except (OSError, ValueError) as error:
        print(f"FAILED: {error}")
        return 1
    print(
        f"std {len(report.std_names)} globals; reference documents "
        f"{len(report.doc_names)} names, {len(report.usage)} of them read by Scripts/"
    )
    missing = report.missing
    if missing:
        print("FAILED: documented API names missing from ue4ss.yml:")
        for name in missing:
            print(f"  {name}  (read by {', '.join(report.usage[name])})")
        return 1
    print("OK: every documented API name the scripts read is declared in ue4ss.yml")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
