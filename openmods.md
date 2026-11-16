# PBZ Auto Defense

PBZ Auto Defense is an automatic defense mod for **Phantom Blade Zero**. It uses UE4SS and Lua to decide when to parry, dodge, or respond to a grab, using observed hit frames and attack timelines rather than a single fixed reaction delay.

**Current source version:** v1.6.3  
**Game data snapshot:** Steam build 26367565  
**Important:** this version has passed offline tests and lint checks, but has **not yet been verified in a live game session**. Treat in-game behavior and performance as unconfirmed.

## What it does

- **Automatic parry:** uses the hit frames reported by the runtime. In automatic lead mode it adapts the parry lead to the learned timing window; unknown moves fall back to a conservative window.
- **Automatic dodge:** evaluates red- and black-flash timing against the move timeline and dodge invulnerability window. It observes dodge spacing, action locks, and failed-input handling.
- **Grab response:** uses a separate lead time for grabs, so known non-grab moves do not inherit the grab lead.
- **Defense hand-off:** can detect the configuration and enabled state of PBZPerfectDefense and yield guard-related control to it. This is a cooperative configuration check, not a cross-mod or cross-process lock.
- **Native mod-menu configuration:** exposes settings through the game's mod menu integration. There are 41 configuration fields; 38 are editable in the menu. Some settings require a game restart.
- **Diagnostics:** optional decision ledger, event log, performance percentiles, and a unified error channel.

The mod does not guarantee a successful defense against every move. Timing data is learned and may be incomplete on a fresh installation.

## How to install

### Requirements

- Phantom Blade Zero.
- UE4SS installed and working for the game.
- For the in-game configuration menu, the compatible PBZModsMenu and PBZModsMenuBridge components.

Install UE4SS separately. This repository contains the PBZ Auto Defense mod, not a copy of UE4SS or the game.

### Install the mod

1. Download and unpack the mod package. If a GitHub release package is available, use the archive attached to the latest release; otherwise, use the repository source.
2. Copy the mod folder so the game has this layout:

   ```text
   <game>/platform/steam/ue4ss/Mods/pbz-auto-defense/
     Scripts/
     data/
     tools/
     enabled.txt
     pbz-auto-defense.modsmenu.json
   ```

   Keep the folder name `pbz-auto-defense` and preserve the directory structure.
3. Make sure `enabled.txt` is present in the mod folder.
4. Restart the game.

The mod creates `pbz-auto-defense.config.json` when needed. The configuration is managed by the native menu integration when the required menu components are installed.

### Update

Close the game, replace the mod's files with those from the new version, and start the game again. Back up your configuration before updating if you want an easy rollback. Do not overwrite the configuration with a sample/default file from a package.

### Remove

Close the game and delete the `pbz-auto-defense` folder from `ue4ss/Mods`. If you also installed PBZModsMenu or PBZModsMenuBridge for other mods, do not remove those shared components.

## How to use

After installation, start the game and open the native mod menu. Find **PBZ Auto Defense** to change its settings.

Common settings:

| Setting | Default / values | Purpose |
|---|---|---|
| `perfect` / `parry` | on | Enable perfect-defense handling / automatic parry |
| `parry_lead` | `auto` | Automatic or manual parry lead mode |
| `parry_lead_seconds` | manual value | Parry lead when manual mode is selected |
| `dodge` | `red` | Dodge mode: `off`, `red`, or `all` (`all` includes black flash) |
| `dodge_lead_ms` | `120` | Dodge lead time in milliseconds |
| `dodge_gap_ms` | `220` | Minimum interval between dodges |
| `grab_lead_ms` | `350` | Grab-response lead time |
| `min_gap_ms` | `90` | Minimum interval between parries |
| `pbzpd` | `auto` | PBZPerfectDefense hand-off: `auto`, `yield`, or `off` |
| `data` | `on` | Load the bundled move-data snapshot |
| `perf` | `off` | Write performance measurements |
| `events` | `on` | Write the event log |
| `ledger` | `on` | Write the defense decision ledger |

Some options are restart-only; the menu and [MENU-INTEGRATION.md](MENU-INTEGRATION.md) identify those fields. The in-game menu is the recommended way to edit settings. Do not assume that a restart-only option takes effect immediately after changing it.

### Logs

The mod writes diagnostic files in its mod folder:

| File | Contents |
|---|---|
| `auto_defense_log.txt` | Startup, configuration, hooks, and errors |
| `auto_defense_ledger.txt` | Defense decisions, timing windows, lead values, and results |
| `ad_events.txt` | Event log |
| `perf_log.txt` | Stage and tick percentiles when `perf=on` |

The runtime also periodically reports event drops, rule asks/denials, and Lua memory in its log.

## Compatibility

- **Game:** Phantom Blade Zero.
- **Game data snapshot:** Steam build 26367565.
- **Runtime:** UE4SS with Lua support.
- **Optional integration:** PBZModsMenu and PBZModsMenuBridge for the native configuration UI.
- **PBZPerfectDefense:** supported through a cooperative configuration/enabled-state hand-off. This is not mutual exclusion; both mods can still attempt an action in the same frame in a race.

The move-data snapshot is bundled in `data/ad_data.lua`. On a fresh installation, learned timing data starts empty and is populated during play when learning is enabled. Until a move has been learned, timeline-based dodge behavior may be unavailable for that move; frame-driven parry handling continues with a conservative fallback.

## Known issues and limitations

- **No live-game validation yet:** v1.6.3 has been checked offline, but actual in-game behavior, timing, and p95 performance have not been measured.
- **No cross-mod lock:** the PBZPerfectDefense hand-off checks its configuration and enabled state. If the other mod changes state after PBZ Auto Defense makes its decision, both mods may still act in the same frame.
- **Cold-start learning:** a new installation has no local learned hit timeline. Learning and the bundled data snapshot gradually fill in coverage; timeline-based dodge behavior may be limited until then.
- **Frozen data snapshot:** the bundled snapshot was generated for Steam build 26367565. Its original generator input from PBZAssist is no longer present in this repository, so regenerating the snapshot requires that source data.
- **Performance is opt-in:** `perf` is off by default. No real-session p95/p99 figures are claimed.

## How to build and test

This is a Lua/UE4SS mod. Its runtime files are Lua scripts and data; **there is no compilation step and this repository currently has no release-archive packaging script**. A distributable package consists of the mod directory structure shown under [How to install](#how-to-install).

To run the repository's offline test and lint gate:

1. Use a Bash environment with LuaJIT available as `luajit`.
2. Install `selene` if you also want the linter check; the script runs it when the executable is available.
3. From the repository root, run:

   ```bash
   bash tools/run_all.sh
   ```

The script runs the policy, async, timeline, menu-configuration, and integration test suites. The integration test runs against an isolated temporary copy. The linter check uses `selene Scripts/` when Selene is installed.

This command validates offline behavior; it does not launch the game, prove runtime compatibility, or create a release archive.

## Credits and license

Created and maintained by High-cla. Licensed under the [MIT License](LICENSE).

Phantom Blade Zero and its game assets belong to their respective rights holders. PBZ Auto Defense is an independent community mod and is not affiliated with or endorsed by the game's developers.
