# PBZ Auto Defense

《Phantom Blade Zero》自动防守 mod：UE4SS + Lua，靠真实受击帧与招式时间线决定「弹反 / 闪避 / 抓投应对」，并接入原生模组菜单配置。

## 功能

- **自动弹反**：由 `ReceiveFrames` 的真实命中帧驱动，提前量在 auto 模式下按实测窗口自适应（最多短窗优于宽窗），未学习到的招式退回保守窗口。
- **自动闪避**：红/黑闪时序判定 + 招式时间线，检查无敌帧覆盖；带闪避间隔、动作锁避让与失败丢弃。
- **别离残钩反制与蓝色护盾反制**（默认关闭，可在菜单开启）：`hook_counter=on` 时手持别离残钩且杀气达到 `hook_counter_shachi`，黑光判定改为「按住格挡＋三角形」反制；`shield_counter=on`（测试中）时 `shield_counter_range` 内有带蓝色护盾的敌人会自动切到别离残钩并对其可格挡攻击放反制。两者关闭时行为与 1.6.6 完全一致。
- **缺帧冷启动保护**：`seed_fallback=record` 默认只记录严格匹配敌人、招式和距离的参考时机；切到 `on` 才启用只闪避的参考种子，真实 ReceiveFrame 与玩家学习数据始终优先。
- **抓投应对**：独立提前量，已收录的非抓投招式不会误用抓投提前量。
- **防守让位**：`pbzpd=auto` 检测 PBZPerfectDefense 的配置文件与启用状态，自动交出 guard 相关控制，保留闪避与时间线闪避。
- **原生菜单**：46 个字段（44 个可编辑），热改约 1 秒内生效；重启项在菜单与本文档中都标注。
- **可观测**：防守决策账本、进程内事件环、perf 分位数与统一错误通道。

## 安装

```
<game>/platform/steam/ue4ss/Mods/pbz-auto-defense/
  Scripts/  data/  enabled.txt  pbz-auto-defense.modsmenu.json
```

把整个目录放到上面位置，确认 `enabled.txt` 存在，重启游戏。配置由菜单写入 `pbz-auto-defense.config.json`（缺省自动生成）。

推荐从 [Release](https://github.com/High-cla/auto-defense-next/releases/latest) 下载 `pbz-auto-defense-v<version>.zip`：解压即得上面的 `pbz-auto-defense/` 目录，**只含游戏要加载的文件**（Scripts、data、enabled.txt、菜单 json），文档与测试留在仓库里。自行打包用 `bash tools/package.sh`，产物在 `dist/`，版本取自 `tl.VERSION`。

## 常用设置

| key | 默认 | 说明 |
|---|---|---|
| `perfect` / `parry` | off / on | 完美弹反 / 自动弹反总开关（热改） |
| `parry_lead` | auto | 弹反提前量模式；`parry_lead_seconds` 为手动值 |
| `dodge` | red | 闪避模式：`off` / `red` / `all`（`all` 同时处理黑闪） |
| `dodge_lead_ms` | 80 | 闪避提前量 |
| `dodge_gap_ms` | 120 | 两次闪避最小间隔 |
| `dodge_iframe_ms` | 260 | 闪避无敌帧覆盖 |
| `grab_lead_ms` | 240 | 抓投提前量 |
| `min_gap_ms` | 120 | 弹反最小间隔 |
| `pbzpd` | auto | PBZPerfectDefense 让位（auto / yield / off，重启项） |
| `data` | on | 加载招式数据快照（重启项） |
| `seed_fallback` | record | 缺帧参考种子：`off` / `record`（只观察）/ `on`（只闪避） |
| `perf` | off | 性能日志：分段 p50/p95/p99 |
| `events` | on | 事件日志 `ad_events.txt` |
| `ledger` | on | 决策账本 `auto_defense_ledger.txt` |

完整字段、类型/默认值/范围、双语说明、持久化与迁移规则见 [CONFIGURATION-REFERENCE.md](docs/CONFIGURATION-REFERENCE.md)；菜单协议与兼容边界见 [MENU-INTEGRATION.md](docs/MENU-INTEGRATION.md)。

## 架构

主运行时 `Scripts/main.lua`（约 5,794 行）+ 15 个边界模块，决策与执行分离：策略产出防守意图 → `ad_policy` 统一裁决 → `ad_input` 受控入口注入按键，按键/标签/解除都走同一道门。

| 模块 | 职责 |
|---|---|
| `ad_query` | 只读游戏查询（名称、模板、组件、时钟），注入式日志 |
| `ad_timeline` | 学习时间线的唯一持有者与计数者 |
| `ad_policy` | 共享规则：意图 → 允许/拒绝 + 拒绝原因 |
| `ad_input` | 受控入口：先问规则再执行，统计 ask/deny |
| `ad_inputstate` | 游戏自己的「按住没按住」答案（`IsHolding`/`GetHoldTime`）+ 键判回落；注入窗口内不采信「按住」 |
| `ad_seed` | 纯参考种子合并器：敌人 + 招式 + 距离精确匹配，复制后合并，已有/学习行优先 |
| `ad_weapon` | 只读游戏状态读取器：手里是不是别离残钩、杀气多少、最近的蓝盾敌人在哪（读取函数注入，约 0.5 s 缓存） |
| `ad_counter` | 反制时序状态机：在 0.22–0.35 s 窗口内给出「等 / 按 / 放弃」，一次只允许一个在途反制 |
| `ad_async` | 事件环（512、丢新不丢旧）+ 每 tick 预算的预热任务 |
| `ad_compat` | 运行时兼容层：5.4 专有调用（`gc` 选项、`atan2`）与版本探测，缺失时调用点自行降级 |
| `ad_json` | 严格扁平 JSON（菜单配置用） |
| `menu_config` | 菜单字段映射、跨字段不变量、回读校验式落盘 |
| `ad_menu_bridge` | 菜单保存名折叠的兼容垫片（镜像文件名，不重复实现写盘） |
| `toast` | 屏幕提示 |

数据层：`data/ad_data.lua` 保留冻结的 PBZAssist 招式快照（build 26367565），并以独立 `reference_noframe` 命名空间携带少量有来源的缺帧参考时机；参考层不替换原快照，只在精确敌人/招式/距离匹配时交给 `ad_seed`。

## 观测产物

| 文件 | 内容 |
|---|---|
| `auto_defense_log.txt` | 启动、配置、hooks、错误（`tl.err` 通道） |
| `auto_defense_ledger.txt` | 每次防守决策：窗口、提前量、回执、结果 |
| `ad_events.txt` | 事件环落盘（12 种事件） |
| `perf_log.txt` | `perf=on` 时的分段分位数 |
| 日志中的 `metrics:` 行 | 每 5 秒：事件丢弃数、规则询问/拒绝数、Lua 内存 |

## 开发

```bash
bash tools/run_all.sh        # POLICY/ASYNC/TIMELINE/QUERY/MENU/BRIDGE/INTEGRATION + selene
git commit                   # pre-commit 自动跑同一道门禁
```

`selene` 走 `selene.toml` + `ue4ss.yml`（自定义 std：lua51 + UE4SS 全局），范围是 `Scripts/ tools/`。注意 selene 有 warning 时退出码也是 1，门禁读 `0 errors` 行。

另有两道「文档/标准库说真话」的门：

- `tools/check_std.py`：文档里出现的 UE4SS API 名必须都在 `ue4ss.yml` 的 std 里。
- `tools/check_docs.py`：本文件与 `MODULES.md` 里的行数、模块数、版本、`tl.api` 条数必须等于磁盘上的实际值；断言数不写进文档，直接看门禁输出。

装有 `lua5.4` 的机器上，门禁还会对 `Scripts/*.lua` 做 5.4 编译 smoke（`AD_REQUIRE_LUA54=1` 时缺失即失败）——游戏跑 5.4，离线测试跑 LuaJIT，这个差距必须被门禁自己盯着。

## 文档

- [MODULES.md](docs/MODULES.md)：模块表、意图→规则表、`tl.api` / `tl.prunable` 契约、未搬项
- [ARCHITECTURE.md](docs/ARCHITECTURE.md)：系统边界、模块关系、启动顺序、每帧数据流和副作用门
- [DEFLECT-STATE-MACHINE.md](docs/DEFLECT-STATE-MACHINE.md)：ReceiveFrame 候选、红招优先、闪避/弹反分支与 guard 生命周期
- [RUNTIME-LIFECYCLE.md](docs/RUNTIME-LIFECYCLE.md)：游戏线程、主循环调度、Hook 重试/注销缺口、暂停恢复与资源管理
- [CONFIGURATION-REFERENCE.md](docs/CONFIGURATION-REFERENCE.md)：46 个配置项的中英说明、类型、默认值、范围、持久化和 TXT→JSON 迁移
- [ASYNC-OBSERVABILITY.md](docs/ASYNC-OBSERVABILITY.md)：事件环契约、事件表、sink 格式、perf 与错误通道
- [MENU-INTEGRATION.md](docs/MENU-INTEGRATION.md)：菜单字段、重启项、只读项、集成链
- [UPSTREAM-API-GUIDE.md](docs/UPSTREAM-API-GUIDE.md)：UE4SS Lua API、PBZModLoader 反射 SDK、PBZ USMAP 工具链及本模组的 API 优化记录
- [docs/UE4SS-LUA-API-REFERENCE.md](docs/UE4SS-LUA-API-REFERENCE.md)：UE4SS Lua 对象、线程、Hook、定时器、容器和性能 API 实战参考
- [docs/PBZ-GAME-API-REFERENCE.md](docs/PBZ-GAME-API-REFERENCE.md)：PBZ DeflectComponent、AbilityInputComponent、Enhanced Input 与 SDK 验证等级
- [docs/PBZ-USMAP-TOOLCHAIN.md](docs/PBZ-USMAP-TOOLCHAIN.md)：PBZ USMAP live/offline 采集、映射格式、合并和质量检查
- [docs/PBZ-SDK-RESOURCES.md](docs/PBZ-SDK-RESOURCES.md)：PBZModLoader Game API SDK 下载/安装、UE4SS C++ SDK Generator 与 USMAP 的区别
- [docs/API-OPTIMIZATION-ROADMAP.md](docs/API-OPTIMIZATION-ROADMAP.md)：已完成优化、候选 API 风险分级、性能 A/B 与实机验收
- [docs/PBZMODSMENU-API-REFERENCE.md](docs/PBZMODSMENU-API-REFERENCE.md)：PBZModsMenu 菜单 API（描述符字段、事件与桥的写盘契约、已知坑，按本机 main.js 核对）

## Nexus Mods 发布

首次上传与后续版本更新都由 `.github/workflows/nexusmods-publish.yml` 完成：先跑项目门禁，再校验已发布
文件的大小与 SHA-256，并拒绝重复发布同一版本（fail-closed，规则写在 workflow 的注释里）。

## License

MIT（见 [LICENSE](LICENSE)）。


---

# English

PBZ Auto Defense is an automatic defense mod for **Phantom Blade Zero**. Built with UE4SS and Lua, it uses observed hit frames and enemy attack timelines to decide when to parry, dodge, or respond to grabs instead of relying on one fixed reaction delay.

## Features

- **Automatic parry:** Uses runtime-reported hit frames. Automatic lead mode adapts to learned timing windows; unknown moves use a conservative fallback.
- **Automatic dodge:** Evaluates red- and black-flash attacks against move timelines and dodge invulnerability windows. It also accounts for dodge spacing, action locks, and failed inputs.
- **DualHook and blue-shield counters (off by default, enable in the menu):** With `hook_counter=on`, a DualHook weapon in hand plus shachi at or above `hook_counter_shachi` turns a black-flash check into a block-and-triangle counter. With `shield_counter=on` (experimental), a blue-shielded enemy within `shield_counter_range` makes the mod switch to the DualHook and counter that enemy's blockable attacks. Both off keeps the 1.6.6 behavior exactly.
- **No-frame cold-start safety:** `seed_fallback=record` only reports exact actor/ability/distance matches by default. `on` enables dodge-only reference seeds; real ReceiveFrames and player-learned rows keep priority.
- **Grab response:** Uses a separate lead-time setting so ordinary attacks do not inherit grab timing.
- **Defense hand-off:** Can detect the configuration and enabled state of PBZPerfectDefense and yield guard-related control when appropriate. This is cooperative configuration-based behavior, not a cross-mod or cross-process mutex.
- **Native mod-menu settings:** Integrates with the in-game mod menu. There are 46 configuration fields, 44 of which are editable in the menu; some settings require a restart.
- **Diagnostics:** Optional defense decision ledger, event log, performance percentile logging, and a unified error channel.

The mod does not guarantee a successful defense against every attack. Timing data is learned during play and may be incomplete on a fresh installation.

## Installation

Install UE4SS for the game first. Then place the complete `pbz-auto-defense` mod folder at:

```
<game>/platform/steam/ue4ss/Mods/pbz-auto-defense/
  Scripts/
  data/
  enabled.txt
  pbz-auto-defense.modsmenu.json
```

Make sure `enabled.txt` is present, then restart the game. The configuration file `pbz-auto-defense.config.json` is generated automatically when missing.

For the in-game configuration menu, install compatible versions of **PBZModsMenu** and **PBZModsMenuBridge** as well. UE4SS, the game, and these optional menu components are not bundled with this repository.

Recommended: download the latest package from the [GitHub Releases page](https://github.com/High-cla/auto-defense-next/releases/latest). The release ZIP contains only the runtime files needed by the game.

## Common settings

| Setting | Default | Description |
|---|---|---|
| `perfect` / `parry` | off / on | Perfect-defense handling / automatic parry |
| `parry_lead` | auto | Automatic or manual parry lead mode |
| `dodge` | red | Dodge mode: `off`, `red`, or `all` (`all` includes black-flash attacks) |
| `dodge_lead_ms` | 80 | Dodge lead time in milliseconds |
| `dodge_gap_ms` | 120 | Minimum interval between dodges |
| `dodge_iframe_ms` | 260 | Dodge invulnerability coverage |
| `grab_lead_ms` | 240 | Grab-response lead time |
| `min_gap_ms` | 120 | Minimum interval between parries |
| `pbzpd` | auto | PBZPerfectDefense hand-off: `auto`, `yield`, or `off` (restart required) |
| `data` | on | Load the bundled move-data snapshot (restart required) |
| `seed_fallback` | record | No-frame reference seeds: `off`, observe-only `record`, or dodge-only `on` |
| `perf` | off | Write performance measurements |
| `events` | on | Write the event log |
| `ledger` | on | Write the defense decision ledger |

Some settings are restart-only. The in-game menu and [MENU-INTEGRATION.md](docs/MENU-INTEGRATION.md) document the available fields and their restrictions. The in-game menu is the recommended way to change settings.

## Logs and diagnostics

The mod writes diagnostic files in its own mod folder:

| File | Contents |
|---|---|
| `auto_defense_log.txt` | Startup, configuration, hook status, and errors |
| `auto_defense_ledger.txt` | Defense decisions, timing windows, lead values, and results |
| `ad_events.txt` | Event log |
| `perf_log.txt` | Stage timings and tick percentiles when `perf=on` |

The runtime also periodically reports dropped events, policy requests and denials, and Lua memory usage.

## Development

Run the offline test and lint suite from the repository root:

```bash
bash tools/run_all.sh
```

This runs the policy, async, timeline, query, menu-config, menu-bridge, and integration tests. If `selene` is installed, it also lints the Lua scripts. The test suite does not launch the game or validate in-game behavior.

## Developer documentation

- [UPSTREAM-API-GUIDE.md](docs/UPSTREAM-API-GUIDE.md): index and integration overview for all upstream API references.
- [docs/UE4SS-LUA-API-REFERENCE.md](docs/UE4SS-LUA-API-REFERENCE.md): UObject queries, game-thread scheduling, hooks, containers, input, lifecycle, and Lua performance practices.
- [docs/PBZ-GAME-API-REFERENCE.md](docs/PBZ-GAME-API-REFERENCE.md): PBZ DeflectComponent, AbilityInputComponent, Enhanced Input, SDK coverage, and verification levels.
- [docs/PBZ-USMAP-TOOLCHAIN.md](docs/PBZ-USMAP-TOOLCHAIN.md): live/offline type capture, USMAP format, merging, quality checks, and build workflow.
- [docs/PBZ-SDK-RESOURCES.md](docs/PBZ-SDK-RESOURCES.md): PBZ Game API SDK download/setup, UE4SS C++ SDK Generator, and the distinction from USMAP mappings.
- [docs/API-OPTIMIZATION-ROADMAP.md](docs/API-OPTIMIZATION-ROADMAP.md): implemented changes, API candidates, risk levels, A/B measurement, and in-game validation.
- [docs/PBZMODSMENU-API-REFERENCE.md](docs/PBZMODSMENU-API-REFERENCE.md): PBZModsMenu menu API — descriptor fields, event and bridge write contract, and the pitfalls, checked against the local main.js.
- [MODULES.md](docs/MODULES.md): module boundaries and the public runtime surface.
- [ARCHITECTURE.md](docs/ARCHITECTURE.md): system boundaries, module map, startup sequence, per-tick data flow, and side-effect gates.
- [DEFLECT-STATE-MACHINE.md](docs/DEFLECT-STATE-MACHINE.md): ReceiveFrame candidates, dodge/parry priority, and guard-state handling.
- [RUNTIME-LIFECYCLE.md](docs/RUNTIME-LIFECYCLE.md): game-thread scheduling, Hook lifecycle, pause/recovery, and teardown limitations.
- [CONFIGURATION-REFERENCE.md](docs/CONFIGURATION-REFERENCE.md): bilingual setting catalog, types, defaults, ranges, persistence, and legacy migration.
- [MENU-INTEGRATION.md](docs/MENU-INTEGRATION.md): native menu configuration and compatibility boundaries.

## License

MIT. See [LICENSE](LICENSE).

Phantom Blade Zero and its game assets belong to their respective rights holders. PBZ Auto Defense is an independent community mod and is not affiliated with or endorsed by the game's developers.
