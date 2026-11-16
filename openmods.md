# PBZ Auto Defense

PBZ Auto Defense 是一款面向 **Phantom Blade Zero（影之刃零）** 的自动防御模组。它基于 UE4SS 和 Lua，通过运行时检测到的受击帧（hit frames）与敌方攻击时间线，判断何时进行弹反、闪避或应对抓投，而不是简单地使用固定反应延迟。

**当前源码版本：** v1.6.4  
**游戏数据快照：** Steam build 26367565  
**重要说明：** 此版本已通过离线测试和代码 lint 检查，但**尚未在实际游戏运行环境中完成验证**。因此，游戏内行为和性能表现仍未得到确认。

## 功能介绍

- **自动弹反：** 使用运行时报告的受击帧。在自动提前量模式下，根据已学习的时机窗口调整弹反提前量；对于未知招式，则回退到较保守的时间窗口。
- **自动闪避：** 根据招式时间线和闪避无敌帧窗口，判断红光与黑光攻击的闪避时机。同时考虑闪避间隔、动作锁定以及输入失败后的处理。
- **抓投应对：** 抓投使用独立的提前量设置，避免普通已知招式错误套用抓投提前量。
- **防御控制交接：** 可以检测 PBZPerfectDefense 的配置和启用状态，并在需要时让出与防御相关的控制权。这属于基于配置状态的协作机制，并非跨模组或跨进程互斥锁。
- **原生模组菜单配置：** 通过游戏内模组菜单集成提供设置项。共有 41 个配置字段，其中 38 个可在菜单中编辑；部分设置需要重启游戏后生效。
- **诊断信息：** 提供可选的决策记录、事件日志、性能百分位统计以及统一错误日志通道。

本模组不保证能够成功防御所有招式。时机数据通过游玩逐步学习；全新安装时，本地学习数据可能尚不完整。

## 安装方法

### 前置要求

- Phantom Blade Zero（影之刃零）。
- 已为游戏正确安装并运行 UE4SS。
- 如需使用游戏内配置菜单，还需要兼容版本的 PBZModsMenu 和 PBZModsMenuBridge 组件。

UE4SS 需要单独安装。本仓库只包含 PBZ Auto Defense 模组，不包含 UE4SS 或游戏本体。

### 安装模组

1. 下载并解压模组包。如果提供了 GitHub Release，请优先使用最新 Release 附带的压缩包；否则可使用仓库源码。
2. 将模组目录复制到游戏目录，使文件结构如下：

   ```text
   <game>/platform/steam/ue4ss/Mods/pbz-auto-defense/
     Scripts/
     data/
     enabled.txt
     pbz-auto-defense.modsmenu.json
   ```

   请保留目录名 `pbz-auto-defense`，并确保目录结构完整。
3. 确认模组目录中存在 `enabled.txt`。
4. 重新启动游戏。

模组会在需要时自动创建 `pbz-auto-defense.config.json`。安装了所需菜单组件后，可通过原生菜单集成管理配置。

### 更新模组

关闭游戏，将新版本文件覆盖到模组目录，然后重新启动游戏。如果需要方便地回滚，更新前请备份配置文件。不要使用压缩包中的示例配置或默认配置覆盖自己的配置。

### 卸载模组

关闭游戏，删除 `ue4ss/Mods` 下的 `pbz-auto-defense` 文件夹即可。如果其他模组也在使用 PBZModsMenu 或 PBZModsMenuBridge，请不要删除这些共享组件。

## 使用方法

安装完成后启动游戏并打开原生模组菜单，找到 **PBZ Auto Defense** 即可修改设置。

常用设置如下：

| 设置项 | 默认值 / 可选值 | 说明 |
|---|---|---|
| `perfect` / `parry` | on | 启用完美防御处理 / 自动弹反 |
| `parry_lead` | `auto` | 自动或手动弹反提前量模式 |
| `parry_lead_seconds` | 手动设置值 | 选择手动模式时使用的弹反提前量 |
| `dodge` | `red` | 闪避模式：`off`、`red` 或 `all`（`all` 包含黑光攻击） |
| `dodge_lead_ms` | `120` | 闪避提前量，单位为毫秒 |
| `dodge_gap_ms` | `220` | 两次闪避之间的最小间隔 |
| `grab_lead_ms` | `350` | 抓投应对提前量 |
| `min_gap_ms` | `90` | 两次弹反之间的最小间隔 |
| `pbzpd` | `auto` | PBZPerfectDefense 控制交接：`auto`、`yield` 或 `off` |
| `data` | `on` | 加载随模组附带的招式数据快照 |
| `perf` | `off` | 是否记录性能测量数据 |
| `events` | `on` | 是否写入事件日志 |
| `ledger` | `on` | 是否写入防御决策记录 |

部分选项只能在重启游戏后生效；具体字段请参考菜单和 [MENU-INTEGRATION.md](MENU-INTEGRATION.md)。建议通过游戏内菜单修改设置。修改仅支持重启生效的选项后，不要认为其会立即生效。

### 日志文件

模组会在自身目录中写入以下诊断文件：

| 文件 | 内容 |
|---|---|
| `auto_defense_log.txt` | 启动、配置、Hook 状态及错误信息 |
| `auto_defense_ledger.txt` | 防御决策、时机窗口、提前量和执行结果 |
| `ad_events.txt` | 事件日志 |
| `perf_log.txt` | 当 `perf=on` 时记录阶段耗时和 tick 百分位数据 |

运行时还会定期在日志中报告事件丢弃数量、规则请求与拒绝次数，以及 Lua 内存使用情况。

## 兼容性

- **游戏：** Phantom Blade Zero（影之刃零）。
- **游戏数据快照：** Steam build 26367565。
- **运行环境：** 支持 Lua 的 UE4SS。
- **可选集成：** PBZModsMenu 和 PBZModsMenuBridge，用于原生配置界面。
- **PBZPerfectDefense：** 通过协作式配置/启用状态交接实现支持。这不是互斥机制；在竞争条件下，两个模组仍可能在同一帧尝试执行动作。

招式数据快照位于 `data/ad_data.lua`。全新安装时，本地学习到的时机时间线为空；启用学习功能后，数据会在游玩过程中逐步积累。在某个招式尚未被学习之前，该招式基于时间线的闪避行为可能不可用；基于帧信息的弹反处理仍会使用较保守的回退策略。

## 已知问题与限制

- **尚未进行实机验证：** v1.6.4 已完成离线检查，但尚未测量实际游戏中的行为、时机准确度和 p95 性能。
- **没有跨模组互斥锁：** PBZPerfectDefense 交接机制会检查其配置和启用状态。如果另一个模组在 PBZ Auto Defense 作出判断后改变状态，两个模组仍可能在同一帧执行动作。
- **首次运行时学习数据为空：** 新安装没有本地学习到的受击时间线。学习过程和随附数据快照会逐步增加覆盖范围；在此之前，部分招式的时间线闪避行为可能受到限制。
- **数据快照固定：** 随附快照基于 Steam build 26367565 生成。用于生成快照的 PBZAssist 原始输入数据已不在本仓库中，因此重新生成快照需要重新取得该源数据。
- **性能记录默认关闭：** `perf` 默认值为 off。目前没有宣称任何实战环境下的 p95/p99 性能数据。

## 构建与测试

这是一个 Lua/UE4SS 模组。运行时文件由 Lua 脚本和数据组成，**无需编译**。发布压缩包由 `bash tools/package.sh` 生成（版本取自 `Scripts/main.lua` 的 `tl.VERSION`），产物为按“安装方法”一节所示目录结构打包的 `dist/pbz-auto-defense-v<version>.zip`；压缩包只含游戏要加载的文件（Scripts、data、enabled.txt、菜单 json），解压即可直接放进 `Mods/`；文档、测试与工具留在仓库，日志、账本、学习数据与个人配置一律不进包。

如需运行仓库的离线测试和 lint 检查：

1. 使用可运行 `luajit` 命令的 Bash 环境。
2. 如需执行代码 lint，请安装 `selene`；脚本会在检测到该可执行文件时运行它。
3. 在仓库根目录执行：

   ```bash
   bash tools/run_all.sh
   ```

该脚本会运行 policy、async、timeline、menu-configuration 和 integration 测试套件。集成测试会在隔离的临时副本中运行。安装了 Selene 时，还会对 `Scripts/` 执行 `selene Scripts/` 检查。

此命令只验证离线行为，不会启动游戏、证明实机兼容性，也不会生成发布压缩包。

## 作者与许可证

作者及维护者：High-cla。项目采用 [MIT License](LICENSE) 授权。

Phantom Blade Zero 及其游戏素材归各自权利人所有。PBZ Auto Defense 是独立的社区模组，与游戏开发者无隶属关系，也未获得其认可或背书。

---

# English

PBZ Auto Defense is an automatic defense mod for **Phantom Blade Zero**. It uses UE4SS and Lua to decide when to parry, dodge, or respond to a grab, using observed hit frames and attack timelines rather than a single fixed reaction delay.

**Current source version:** v1.6.4  
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

- **No live-game validation yet:** v1.6.4 has been checked offline, but actual in-game behavior, timing, and p95 performance have not been measured.
- **No cross-mod lock:** the PBZPerfectDefense hand-off checks its configuration and enabled state. If the other mod changes state after PBZ Auto Defense makes its decision, both mods may still act in the same frame.
- **Cold-start learning:** a new installation has no local learned hit timeline. Learning and the bundled data snapshot gradually fill in coverage; timeline-based dodge behavior may be limited until then.
- **Frozen data snapshot:** the bundled snapshot was generated for Steam build 26367565. Its original generator input from PBZAssist is no longer present in this repository, so regenerating the snapshot requires that source data.
- **Performance is opt-in:** `perf` is off by default. No real-session p95/p99 figures are claimed.

## How to build and test

This is a Lua/UE4SS mod. Its runtime files are Lua scripts and data; **there is no compilation step**. Release archives are produced by `bash tools/package.sh` (version read from `tl.VERSION` in `Scripts/main.lua`), which writes `dist/pbz-auto-defense-v<version>.zip` using the directory layout shown under [How to install](#how-to-install). The archive contains only what the game loads (Scripts, data, enabled.txt, menu json) and unpacks straight into `Mods/`; documentation, tests and tools stay in the repository, and logs, ledgers, learned data and personal configuration are never included.

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
