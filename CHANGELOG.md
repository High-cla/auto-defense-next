# Changelog

Versions are the `tl.VERSION` value in `Scripts/main.lua`; the release tag is `v<version>`.

## Unreleased

基于 UE4SS、PBZModLoader 和 PBZ USMAP 上游文档进行 API 核对与运行时优化（详见 [UPSTREAM-API-GUIDE.md](UPSTREAM-API-GUIDE.md)）。

- 主防守循环优先使用 UE4SS `LoopInGameThreadAfterFrames(1, ...)`，按 EngineTick 每帧运行；不可用或创建失败时回退到原 10 ms delayed loop。
- 主循环保存 delayed-action handle；看门狗重启前调用 `CancelDelayedAction` 取消旧循环，并保留 loop generation 检查防止旧回调继续执行。
- `ad_query.tagLibrary()` 对未找到的 PBZAbilityBlueprintLibrary 增加 5 秒负缓存，避免反复扫描全局 UObject 数组；成功结果继续缓存，并允许稍后加载时重试。
- 新增 query 负缓存测试；集成测试覆盖 EngineTick 调度、10 ms 兼容回退及旧循环取消。
- 通过 PBZModLoader 的 PBZDeflectSystem 反射声明交叉核对 `GetNearestValidReceivedFrame` 签名；未更改尚未实机验证的 out-frame 写回/复用行为。
- AbilitySystemBlueprintLibrary / GameplayStatics CDO 缺失时安全降级：ascOf 返回 nil，nowOf 返回 0；避免启动/切换阶段因 nil CDO 直接解引用而抛错。
- 新增四份详细开发文档：UE4SS Lua API 实战参考、PBZ 游戏反射 API 参考、PBZ USMAP 工具链指南，以及 API 优化路线图；README 已加入中英文索引。

## 1.6.4 — 2026-11-17

修复：在模组菜单里改完设置保存不生效（`Saved/PBZModsMenu-log.txt` 里三次 `ue4ss/pbz-auto-defense: settings not saved`）。

- 根因：菜单按 `encodeName` 把模组名编码成 `pbz%2dauto%2ddefense` 后写 `Mods/PBZModsMenuBridge/pending-<enc>.json`，但本机落盘的文件名丢了 `%`（`pending-pbz2dauto2ddefense.json`）；Bridge 只认带 `%` 的名字，于是永不匹配——config 不写、`saved-<enc>.txt` 不生成，菜单 8×250 ms 后判定未保存。
- 新增 [Scripts/ad_menu_bridge.lua](<Mods/pbz-auto-defense/Scripts/ad_menu_bridge.lua>)：把完整的 loose 名 pending 逐字节镜像成 Bridge 认识的 exact 名；把 Bridge 写出的 `saved-<exact>.txt` 复制成 loose 名供菜单回读；`events-<loose>.txt` 作为 `menu_config` 的第二事件源。只在 loose 完整（CRLF 结尾）且 exact 不存在时动作，写后回读校验，失败保留原文件并计数、同一原因只记一行。0.5 s 节流；名字里没有 `%` 的模组自动 no-op；不改菜单、不改 Bridge、config 仍由 Bridge 唯一写入。
- 主循环每 tick 走一次 `guarded("menu bridge", …)`；启动日志新增 `menu bridge shim: pending-<loose>.json -> pending-<exact>.json`。
- 默认参数改为本版实机调过的那一组，三处同源：config JSON（41 键）、描述符每行 `default`、`Scripts/main.lua` 的 `settings` 初值。变化项：perfect=false、perfect_mode=give、parry_reach=0.5、guard_release_after=0.5、guard_release_combat_end=0.5、parry_lead_seconds=0.08、dodge_lead_ms=80、dodge_gap_ms=120、dodge_iframe_ms=260、min_gap_ms=120、grab_lead_ms=240、receipt=false、dodge_cd=false、busy_skip=false（其余保持原默认，热键仍 F7/F8/F9/F6）。
- 版本 1.6.4：`tl.VERSION`、描述符 `version`、集成测试断言同步；台账首行随版本变化。

## 1.6.3 — 2026-11-16

审计驱动的稳定性/性能批次（见 [AUDIT-2026-11-16.md](AUDIT-2026-11-16.md)），行为对玩家保持不变。

- 度量：`perf=on` 时逐阶段环形采样，输出 tick 与每个 stage 的 p50/p95/p99；hitches 改为计数。
- 错误：统一 `tl.err` 通道（同源前三次记日志、首次带 traceback，并进事件日志），三处 hook 失败不再静默。
- 单向门修复：攻击帧 hook 失败后可重试，不再整局放弃；看门狗进主循环并在重启无果时只报一次。
- 时间线：`ad_timeline` 独占表与计数（`add/addRow/removeRow/recount`），删除会和主表漂移的 `addCount`。
- 受控入口：闪避注入改走 `tl.input.inject`，规则拒绝会进事件日志并计数。
- 配置：跨字段不变量、未知键只报一次、写盘后回读校验并回滚。
- 观测：每 5 秒一行 `metrics:`（事件丢弃、规则询问/拒绝、Lua 内存）；账本上限 6000 行并留截断标记。
- 工程：`git` 仓库化、`tools/run_all.sh` 一条命令出门禁、`selene` 配置、备份集中到 `backup/`。

## 1.6.2 — 2026-11-16

- 真实模块切分：`ad_query`（只读查询）、`ad_timeline`（时间线）、`ad_policy`（共享规则）、`ad_input`（受控入口）。
- 决策与执行分离：策略产出意图 → 规则裁决 → 受控入口注入；所有既有调用点走同一道门。

## 1.6.1 — 2026-11-16

- 进程内只读事件环 `ad_async`（512 环、丢新不丢旧、每 tick 16 条、坏订阅 pcall 剔除）与 `ad_events.txt` 落盘。
- 每 tick 预算的预热任务框架（当前用于建立招式索引，不参与决策）。
- 新增热开关 `events`。

## 1.6.0 — 2026-11-16

- 原生模组菜单集成：41 个字段（38 可编辑），配置写入 `pbz-auto-defense.config.json`，与旧 `auto_defense.txt` 迁移。
- 严格扁平 JSON（`ad_json`）、配置写入带备份与回滚、重启项与只读项标注。

## 1.5.x — 2026-11-16

- 1.5.0 游戏数据层：命中时段、无敌窗、真实射程、爆风半径、抓投标记、多段/不可防标签接入决策。
- 1.5.1 PBZPerfectDefense 协作让位（`pbzpd=auto/yield/off`）。

## 1.4.x — 2026-11-14 …16

- 决策账本、真实受击帧读取、自适应弹反提前量、输入回执校验、闪避覆盖窗与间隔、时间线/真实帧配对。
