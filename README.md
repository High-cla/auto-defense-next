# PBZ Auto Defense

《Phantom Blade Zero》自动防守 mod：UE4SS + Lua，靠真实受击帧与招式时间线决定「弹反 / 闪避 / 抓投应对」，并接入原生模组菜单配置。

**v1.6.4** · 离线验证：6 套测试共 327 断言全绿、`selene` 0 errors · **尚未做游戏内验证**（见「已知限制」）。

## 功能

- **自动弹反**：由 `ReceiveFrames` 的真实命中帧驱动，提前量在 auto 模式下按实测窗口自适应（最多短窗优于宽窗），未学习到的招式退回保守窗口。
- **自动闪避**：红/黑闪时序判定 + 招式时间线，检查无敌帧覆盖；带闪避间隔、动作锁避让与失败丢弃。
- **抓投应对**：独立提前量，已收录的非抓投招式不会误用抓投提前量。
- **防守让位**：`pbzpd=auto` 检测 PBZPerfectDefense 的配置文件与启用状态，自动交出 guard 相关控制，保留闪避与时间线闪避。
- **原生菜单**：41 个字段（38 个可编辑），热改约 1 秒内生效；重启项在菜单与本文档中都标注。
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
| `perfect` / `parry` | on | 完美弹反 / 自动弹反总开关（热改） |
| `parry_lead` | auto | 弹反提前量模式；`parry_lead_seconds` 为手动值 |
| `dodge` | red | 闪避模式：`off` / `red` / `all`（`all` 同时处理黑闪） |
| `dodge_lead_ms` | 120 | 闪避提前量 |
| `dodge_gap_ms` | 220 | 两次闪避最小间隔 |
| `grab_lead_ms` | 350 | 抓投提前量 |
| `min_gap_ms` | 90 | 弹反最小间隔 |
| `pbzpd` | auto | PBZPerfectDefense 让位（auto / yield / off，重启项） |
| `data` | on | 加载招式数据快照（重启项） |
| `perf` | off | 性能日志：分段 p50/p95/p99 |
| `events` | on | 事件日志 `ad_events.txt` |
| `ledger` | on | 决策账本 `auto_defense_ledger.txt` |

完整字段与重启/只读限制见 [MENU-INTEGRATION.md](MENU-INTEGRATION.md)。

## 架构

主运行时 `Scripts/main.lua`（4,839 行）+ 8 个边界模块，决策与执行分离：策略产出防守意图 → `ad_policy` 统一裁决 → `ad_input` 受控入口注入按键，按键/标签/解除都走同一道门。

| 模块 | 职责 |
|---|---|
| `ad_query` | 只读游戏查询（名称、模板、组件、时钟），注入式日志 |
| `ad_timeline` | 学习时间线的唯一持有者与计数者 |
| `ad_policy` | 共享规则：意图 → 允许/拒绝 + 拒绝原因 |
| `ad_input` | 受控入口：先问规则再执行，统计 ask/deny |
| `ad_async` | 事件环（512、丢新不丢旧）+ 每 tick 预算的预热任务 |
| `ad_json` | 严格扁平 JSON（菜单配置用） |
| `menu_config` | 菜单字段映射、跨字段不变量、回读校验式落盘 |
| `toast` | 屏幕提示 |

数据层：`data/ad_data.lua` 是冻结的招式快照（build 26367565），提供命中时段、无敌窗、真实射程、爆风半径、抓投标记等；读取走名称归一化，未命中时保持原行为。

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
bash tools/run_all.sh        # POLICY/ASYNC/TIMELINE/MENU/INTEGRATION + selene
git commit                   # pre-commit 自动跑同一道门禁
```

`selene` 走 `selene.toml` + `ue4ss.yml`（自定义 std：lua51 + UE4SS 全局）。注意 selene 有 warning 时退出码也是 1，门禁读 `0 errors` 行。

## 已知限制

- 本版只做过离线验证，游戏内行为与真实 p95 尚未测；`perf` 默认关。
- 与 PBZPerfectDefense 的让位是**共约**（读取它的配置与启用状态），不是跨进程互斥：它若在我们判定之后改动，仍可能出现同一帧双方动作。
- 数据快照不能原地重生成：生成器读取的 PBZAssist 脚本目录已不在本机，快照仍可用于运行时。
- 时间线来自运行时的 `hit_times.txt`，属运行时状态、不进本仓库（本机现有 2,683 条）。全新安装从空表开始：`learn` 与数据层冷启动会逐步补齐，期间时间线闪避不生效，帧驱动的弹反应对照常工作；遇到未收录招式一律退回保守窗口并记录。

## 文档

- [MODULES.md](MODULES.md)：模块表、意图→规则表、`tl.api` / `tl.prunable` 契约、未搬项
- [ASYNC-OBSERVABILITY.md](ASYNC-OBSERVABILITY.md)：事件环契约、事件表、sink 格式、perf 与错误通道
- [MENU-INTEGRATION.md](MENU-INTEGRATION.md)：菜单字段、重启项、只读项、集成链
- [AUDIT-2026-11-16.md](AUDIT-2026-11-16.md)：P0–P2 审计项的处置与延后理由

## License

MIT（见 [LICENSE](LICENSE)）。
