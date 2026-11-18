#!/usr/bin/env python3
"""Prepare ignored runtime config fixtures for a clean-checkout integration test.

The gate must not depend on the player's own config: turning `read_frames` off in
the mod menu would otherwise decide whether the integration test passes. With
`--root` the same descriptor defaults are generated inside
`tools/run_integration.sh`'s temp copy, so the gate always runs against the
defaults the descriptor declares - locally and in CI alike.

Never overwrite an existing config. The generated files are ignored by Git and are
consumed only by the isolated temp copy.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def prepare(root: Path) -> int:
    descriptor = root / "pbz-auto-defense.modsmenu.json"
    config = root / "pbz-auto-defense.config.json"
    legacy = root / "auto_defense.txt"

    if not config.exists() and legacy.exists() and legacy.stat().st_size > 0:
        # Writing a default config next to an existing legacy TXT would shadow the
        # player's tuning: the mod imports the TXT only while the JSON is missing
        # (menu_config.py migration), so the old values would never be read again.
        raise SystemExit(
            "auto_defense.txt exists without pbz-auto-defense.config.json.\n"
            "Refusing to create a default config here: it would shadow the legacy "
            "TXT.\n"
            "Move the TXT aside, or run this script in a clean checkout."
        )
    if not config.exists():
        if not descriptor.exists():
            raise SystemExit(f"mod menu descriptor not found: {descriptor}")
        menu = json.loads(descriptor.read_text(encoding="utf-8"))
        settings = menu.get("settings")
        if not isinstance(settings, list) or not settings:
            raise SystemExit("mod menu descriptor has no settings list")
        defaults = {}
        for setting in settings:
            if (
                not isinstance(setting, dict)
                or "key" not in setting
                or "default" not in setting
            ):
                raise SystemExit("mod menu descriptor contains an invalid setting")
            defaults[setting["key"]] = setting["default"]
        config.write_text(
            json.dumps(defaults, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Created ignored default config fixture with {len(defaults)} settings.")
    else:
        print(
            "Keeping existing pbz-auto-defense.config.json; it will only be read "
            "by the temp-copy test."
        )

    if not legacy.exists():
        legacy.write_text("", encoding="utf-8")
        print("Created ignored empty legacy TXT fixture.")
    else:
        print(
            "Keeping existing auto_defense.txt; it will only be read by the "
            "temp-copy test."
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(ROOT),
        help="directory holding the descriptor and the fixtures (default: repo root)",
    )
    args = parser.parse_args(argv)
    return prepare(Path(args.root))


if __name__ == "__main__":
    raise SystemExit(main())
