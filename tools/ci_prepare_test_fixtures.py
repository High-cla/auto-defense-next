#!/usr/bin/env python3
"""Prepare ignored runtime config fixtures for a clean-checkout integration test.

Never overwrite an existing player config. The generated files are ignored by
Git and are consumed only by tools/run_integration.sh's isolated temp copy.
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESCRIPTOR = ROOT / "pbz-auto-defense.modsmenu.json"
CONFIG = ROOT / "pbz-auto-defense.config.json"
LEGACY = ROOT / "auto_defense.txt"


def main() -> int:
    if not CONFIG.exists() and LEGACY.exists() and LEGACY.stat().st_size > 0:
        # Writing a default config next to an existing legacy TXT would shadow the
        # player's tuning: the mod imports the TXT only while the JSON is missing
        # (menu_config.py migration), so the old values would never be read again.
        raise SystemExit(
            "auto_defense.txt exists without pbz-auto-defense.config.json.\n"
            "Refusing to create a default config here: it would shadow the legacy TXT.\n"
            "Move the TXT aside, or run this script in a clean checkout."
        )
    if not CONFIG.exists():
        descriptor = json.loads(DESCRIPTOR.read_text(encoding="utf-8"))
        settings = descriptor.get("settings")
        if not isinstance(settings, list) or not settings:
            raise SystemExit("mod menu descriptor has no settings list")
        defaults = {}
        for setting in settings:
            if not isinstance(setting, dict) or "key" not in setting or "default" not in setting:
                raise SystemExit("mod menu descriptor contains an invalid setting")
            defaults[setting["key"]] = setting["default"]
        CONFIG.write_text(
            json.dumps(defaults, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Created ignored default config fixture with {len(defaults)} settings.")
    else:
        print("Keeping existing pbz-auto-defense.config.json; it will only be read by the temp-copy test.")

    if not LEGACY.exists():
        LEGACY.write_text("", encoding="utf-8")
        print("Created ignored empty legacy TXT fixture.")
    else:
        print("Keeping existing auto_defense.txt; it will only be read by the temp-copy test.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
