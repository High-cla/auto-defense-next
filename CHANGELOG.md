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

代码审查（调度器/查询/门禁/发布工具链）修复：

- 调度器：`LoopInGameThreadWithDelay` 调用成功但返回 nil handle 时，旧代码记一行日志就 return——主循环完全没有被排程，而 `tl.loopSchedule` 还停在旧值；现在只要调用成功就算排程成功，`"failed"` 重新可达。取消旧 handle 失败时不再丢弃它，而是记入 `tl.loopStale` 并在下次启动重试（上限 8 个），避免旧循环整局空转。`tl.check(force)` 新增人工重试参数：热键走 `tl.check(true)`，会重置启动预算并清除 `tl.loopDead`，不再出现「按热键重试」却是空承诺。`alive:` 行新增 `loop <schedule>`，让调度方式可观测。
- 查询：`ascOf` 把 `IsValid` 探测失败当成「对象无效」，会静默关掉完美弹反/脱手/Sát Khí 且无日志；现在探测失败仍返回 wrapper，并按原因各记一次日志。`nowOf` 失败时记录一次并返回 0（时间决策读 0 至少可查）。`tagLibrary` 在返回前校验 UObject，不再把无效 CDO 交给 `setPerfect`。
- 门禁：selene 缺失不再静默跳过（`AD_REQUIRE_SELENE=1` 时视为失败，CI 三个 job 都装 selene 0.32.0 并启用）；判定同时要求 `0 errors` 与 `0 parse errors`，失败时打印 `error`/`warning` 行与结尾 Results，不再截断在 20 行；补跑 `tools/test_nexusmods_*.py`（本机 Windows Store 的 `python3` 是空壳，脚本改为按可用性挑解释器）；`tools/run_integration.sh` 加了 trap，成功即清理临时目录，失败保留以便排查。
- 发布工具链：新增 `tools/nexusmods_check_published.py`（`GET /mod-files/{file_id}/versions`，已发布则跳过 upload-action，响应不可解析时 fail closed）与 10 个离线断言；bootstrap 在 `versions_count` 缺失时拒绝上传；`ci_prepare_test_fixtures.py` 拒绝在旧 TXT 存在而 config 缺失时生成默认配置。
- 测试：集成套件新增 9 条（nil handle 仍排程、调度记录诚实、缺少 API 记 failed、取消失败入重试表、重试成功后清空、看门狗预算、人工重试重置、死标志清除）；query 套件新增 5 条（无效 walked 对象不外发、IsValid 探测失败仍返回 wrapper 并记一次日志、时钟失败降级为 0 并记录）。当前 365 断言 + selene 0 errors / 3 既有 warning。

### 静态检查与门禁说真话（审计 P0-1、P0-2、P1-5、P1-6、P1-7、P2-8）

- `selene` 范围从 `Scripts/` 扩到 `Scripts/ tools/`：此前 20 个 `incorrect_standard_library_use` 全部隐身（测试替身覆写 `os.clock`/`dofile`/`loadfile`、单参 `assert`、`package.config`），现按文件用 `-- selene: allow(...)` 显式声明。
- 运行时 Lua 版本从「间接证据」变成证据：启动日志新增 `runtime: <Lua 5.x> / <jit 版本> / ad_compat`；5.4 专有调用收进 `Scripts/ad_compat.lua`；`tools/run_all.sh` 在装有 `lua5.4` 时对 `Scripts/*.lua` 做编译 smoke，`AD_REQUIRE_LUA54=1` 时缺失即失败（CI 已装 lua5.4 并启用）。
- `ue4ss.yml` 补齐文档已列的 16 个全局（`NotifyOnNewObject`、`UnregisterHook`、Delayed Actions 全套、`TArray`/`TMap`/`RemoteUnrealParam` 等），删掉代码 0 引用的 `LoadAsset`/`CreateInvalidObject`；新增 `tools/check_std.py` 校验「文档里出现的 API 名都在 std 里」。
- 新增 `tools/check_docs.py`（配 9 个用例）：MODULES.md 的模块行数、版本三处（`tl.VERSION` / modsmenu.json / MODULES.md 标题）、`tl.api` 条数、README 的主运行时规模与模块数全部对着磁盘校验。断言数不再手抄进文档——门禁输出是唯一事实来源（MODULES.md 曾写 INTEGRATION 44 而实测 63）。
- CI：`nexusmods-publish.yml` 加 `push: [main]` 触发（只跑验证/门禁，上传与发布仍只由 `release`/`workflow_dispatch` 触发）；`pull_request.paths` 补 `Scripts/**`、`docs/**`、`*.md`、modsmenu 清单；validate job 加 `ruff check --select E,F tools/`。

### 错误不再被吞（审计 P0-4、P1-8）

- 新增 `tl.try(what, fn, ...)`：27 处裸 `pcall` 里的**动作**调用点（`pressTap`、`unpunish`、`noteWindow`、`injectKey`、`saveFlight`、`tickGuardBreak`、`holdGuard`、`pushNow`、`hookBullets`、`hookResults`、`learnFail`、`PD.refresh`、`K2_EndAbility`/`K2_CancelAbility`、Sát Khí 回气写回）改走唯一错误通道（同一 `what` 前 3 次记录、首次附 traceback、并 `emit("error", ...)`）。
- 无敌窗口提示从每 tick 一行改为 `tl.ledOnce(key, ...)`：同一 key 每局只写一次。

### 调度与关键路径可测（审计 P0-3、P1-1、P1-4）

- `tl.start` 的两条路径合并成一个 `schedule(kind)`，判据统一为「不抛错即已排程」（此前帧路径要求 `handle ~= nil`，与定时路径不一致）；两条路径都失败时原因同时入日志。新增 `tl.loopVerifyAt`：排程后 2 s 内没有 tick 就换另一条路径并记日志（由 `tl.check` 判定）。
- 每帧决策链抽成 `tl.decide(p, deflect, input, now)`；测试 marker 下暴露 `_G.__DECIDE`、`_G.__CHECK_RELEASE`、`_G.__RUNTIME`，离线门禁第一次能驱动「parry off / 守卫被接管 / 红招只闪 / 命中还远」等早退分支，而不是只断言循环存在。
- 5 处 `RegisterHook` 统一保存返回的 hook id（`tl.hookIds` / `RT.rememberHook`），新增 `RT.unhook` / `RT.unhookAll`（`UnregisterHook` 此前全库 0 次调用）。

### 热路径分配与名称归一化（审计 P1-2、P1-3、P1-9、P2-1、P2-2、P2-6、P2-7）

- 每 tick 的读探针从 `pcall(function() ... end)` 改为具名 `RT.*`（`pawnOf`/`curOf`/`hitTimeOf`/`isDodgeOf`/`sourceOf`/`bulletOf`/`classOf`/`fnameOf`/`tagStr`）；`nearest` 复用 `RT.out` 表；闪避 kinds 与 `{ false, true }` 提到 `RT` 常量；`fxOne`/`yawOf`/`resetPerfect` 不再每次分配闭包。
- `ad_query.tag(s)` 记忆化（同名返回同一表），`M.baseName` 成为唯一定义（去路径、去 `:ExecutionTimeline`、去掉重复的 `_C`）；`main.lua` 侧统一走 `RT.bname`（委托 `Q.baseName`，模块缺失时降级）。`hit_times.txt` 里 12 个还带 `_C` 的键在加载时归一化（2,506 个键归一无碰撞），学习到的新键同样归一化。
- 删掉无外部读者的 `tl.FX` 导出；`dofile` 路径统一正斜杠。

### toast 与时钟单位（审计 P2-3、P2-5）

- `Scripts/toast.lua` 不再常驻 100 ms 循环：按需一次 Delayed Action（优先 `RetriggerableExecuteInGameThreadWithDelay`），handle 保存，隐藏与再次显示时取消或重触发，配 `tools/test_toast.lua`。
- `tl.ALIVE_EVERY` 从 300 **ticks** 改为 5 **秒**（原来实际 2.1 s@144 Hz、6–7 s@50 Hz，注释却自称「秒」）。
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
