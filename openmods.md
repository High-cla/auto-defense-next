# PBZ Auto Defense

PBZ Auto Defense 是一款面向 **Phantom Blade Zero（影之刃零）** 的自动防御模组。它基于 UE4SS 和 Lua，通过运行时检测到的受击帧（hit frames）与敌方攻击时间线，判断何时进行弹反、闪避或应对抓投，而不是简单地使用固定反应延迟。

**当前源码版本：** v1.6.3  
**游戏数据快照：** Steam build 26367565  

## 功能介绍

- **自动弹反：** 使用运行时报告的受击帧。在自动提前量模式下，根据已学习的时机窗口调整弹反提前量；对于未知招式，则回退到较保守的时间窗口。
- **自动闪避：** 根据招式时间线和闪避无敌帧窗口，判断红光与黑光攻击的闪避时机。同时考虑闪避间隔、动作锁定以及输入失败后的处理。
- **抓投应对：** 抓投使用独立的提前量设置，避免普通已知招式错误套用抓投提前量。
- **防御控制交接：** 可以检测 PBZPerfectDefense 的配置和启用状态，并在需要时让出与防御相关的控制权。这属于基于配置状态的协作机制，并非跨模组或跨进程互斥锁。
- **原生模组菜单配置：** 通过游戏内模组菜单集成提供设置项。共有 41 个配置字段，其中 38 个可在菜单中编辑；部分设置需要重启游戏后生效。
- **诊断信息：** 提供可选的决策记录、事件日志、性能百分位统计以及统一错误日志通道。

本模组不保证能够成功防御所有招式。时机数据通过游玩逐步学习；全新安装时，本地学习数据可能尚不完整。

### 前置要求

- Phantom Blade Zero（影之刃零）。
- 已为游戏正确安装并运行 UE4SS。
- 如需使用游戏内配置菜单，还需要兼容版本的 PBZModsMenu 和 PBZModsMenuBridge 组件。

UE4SS 需要单独安装。本仓库只包含 PBZ Auto Defense 模组，不包含 UE4SS 或游戏本体。

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

---

# English

PBZ Auto Defense is an automatic defense mod for **Phantom Blade Zero**. It uses UE4SS and Lua to decide when to parry, dodge, or respond to a grab, using observed hit frames and attack timelines rather than a single fixed reaction delay.

**Current source version:** v1.6.3  
**Game data snapshot:** Steam build 26367565  

## What it does

- **Automatic parry:** uses the hit frames reported by the runtime. In automatic lead mode it adapts the parry lead to the learned timing window; unknown moves fall back to a conservative window.
- **Automatic dodge:** evaluates red- and black-flash timing against the move timeline and dodge invulnerability window. It observes dodge spacing, action locks, and failed-input handling.
- **Grab response:** uses a separate lead time for grabs, so known non-grab moves do not inherit the grab lead.
- **Defense hand-off:** can detect the configuration and enabled state of PBZPerfectDefense and yield guard-related control to it. This is a cooperative configuration check, not a cross-mod or cross-process lock.
- **Native mod-menu configuration:** exposes settings through the game's mod menu integration. There are 41 configuration fields; 38 are editable in the menu. Some settings require a game restart.
- **Diagnostics:** optional decision ledger, event log, performance percentiles, and a unified error channel.

The mod does not guarantee a successful defense against every move. Timing data is learned and may be incomplete on a fresh installation.

### Requirements

- Phantom Blade Zero.
- UE4SS installed and working for the game.
- For the in-game configuration menu, the compatible PBZModsMenu and PBZModsMenuBridge components.

Install UE4SS separately. This repository contains the PBZ Auto Defense mod, not a copy of UE4SS or the game.

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

Phantom Blade Zero and its game assets belong to their respective rights holders. PBZ Auto Defense is an independent community mod and is not affiliated with or endorsed by the game's developers.
