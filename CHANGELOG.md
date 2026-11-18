# Changelog

Versions are the `tl.VERSION` value in `Scripts/main.lua`; the release tag is `v<version>`.

## 1.6.6 — 2026-11-18

### 缺帧冷启动保护与参考数据层

- `data/ad_data.lua` 保留 PBZAssist build 26367565 的全部既有表，并新增独立、带来源的 `reference_noframe` 命名空间；根据 AutoPerfectDefense 1.1.4 的公开默认/学习文件，仅录入 BombMan 0.820/2.270 秒与 YanQianSui 3.441 秒三个高置信语义时机，映射为 5 条 actor-qualified Ability 行，不引入其代码或完整原始样本。
- 新增纯 `Scripts/ad_seed.lua`：严格匹配敌人类 + Ability，应用来源距离与 margin，按 ±0.15 秒让已有快照/玩家学习行优先，复制后合并并拒绝坏数据；不持有攻击生命周期、不修改全局 hitTimes、不直接执行输入。
- 新增热应用设置 `seed_fallback=off|record|on`，默认 `record`。record 只记录本可采用的精确候选而不动作；on 才把参考时机作为只闪避的一次性冷启动回退，真实 ReceiveFrame 在到期附近出现时由既有 pairTimeline 优先配对并取消参考输入。
- 原生菜单、旧 TXT 导入/回滚、配置参考、架构/状态机文档与离线门禁已同步；新增种子单元测试，并在集成测试中钉住 record 不动作、on 幂等合并和 off 无操作。

## 1.6.5 — 2026-11-18

基于 UE4SS、PBZModLoader 和 PBZ USMAP 上游文档进行 API 核对与运行时优化（详见 [UPSTREAM-API-GUIDE.md](docs/UPSTREAM-API-GUIDE.md)）。

- 主防守循环优先使用 UE4SS `LoopInGameThreadAfterFrames(1, ...)`，按 EngineTick 每帧运行；不可用或创建失败时回退到原 10 ms delayed loop。
- 主循环保存 delayed-action handle；看门狗重启前调用 `CancelDelayedAction` 取消旧循环，并保留 loop generation 检查防止旧回调继续执行。
- `ad_query.tagLibrary()` 对未找到的 PBZAbilityBlueprintLibrary 增加 5 秒负缓存，避免反复扫描全局 UObject 数组；成功结果继续缓存，并允许稍后加载时重试。
- 新增 query 负缓存测试；集成测试覆盖 EngineTick 调度、10 ms 兼容回退及旧循环取消。
- 通过 PBZModLoader 的 PBZDeflectSystem 反射声明交叉核对 `GetNearestValidReceivedFrame` 签名；未更改尚未实机验证的 out-frame 写回/复用行为。
- AbilitySystemBlueprintLibrary / GameplayStatics CDO 缺失时安全降级：ascOf 返回 nil，nowOf 返回 0；避免启动/切换阶段因 nil CDO 直接解引用而抛错。
- 新增四份详细开发文档：UE4SS Lua API 实战参考、PBZ 游戏反射 API 参考、PBZ USMAP 工具链指南，以及 API 优化路线图；README 已加入中英文索引。
- 进一步核实 SDK 资源：PBZ USMAP 仓库仅提供 mapping/工具链；新增 PBZ SDK 与反射资源索引，收录 PBZModLoader Game API SDK 0.3.3 的 developer ZIP、TypeScript 安装方式，以及 UE4SS C++ SDK Generator 的生成路径与适用范围。
- 新增四份 P0 工程文档：ARCHITECTURE（模块/启动/数据流）、DEFLECT-STATE-MACHINE（命中候选、闪避/弹反优先级与 guard 状态）、RUNTIME-LIFECYCLE（调度、Hook、暂停恢复及当前 Hook 注销缺口）和 CONFIGURATION-REFERENCE（41 项中英配置目录、类型/默认值/范围/持久化及 TXT→JSON 首次迁移）。README、UPSTREAM-API-GUIDE 与 MENU-INTEGRATION 已加入索引或同步字段数（41 项、39 项可编辑、2 项只读）。
- 文档整理：除 `README.md`、`CHANGELOG.md` 与 `openmods.md` 外，所有 Markdown 移入 `docs/`，README/CHANGELOG/文档之间的相对链接全部改写；顺带修正了一批原本指向 UE4SS 根目录（`<Mods/pbz-auto-defense/…>`）的断链，并把指向 `.gitignore` 文件中（配置 JSON、旧 TXT、`backup/`）的链接改成代码片段。`openmods.md` 必须留在根目录：openmods 的 `$schema` 明确写「Put this file at the root of your mod repository, next to openmods.md」，商店页正文靠这条相邻约定被发现。`tools/check_docs.py` 新增相对链接校验与 openmods 配对校验：断链或 `openmods.md` 被搬走都直接失败。


### SDK 覆盖审计三条建议落地（只读优先，待实机确认）

- **游戏自己的「按住」答案**：新增 `Scripts/ad_inputstate.lua`（90 行；无游戏 API、读取器注入、可离线测试），把 `pawn["Ability Input Component"].SGameInput.IsHolding(IA_Deflect)` / `GetHoldTime` 接在 `deflectKeyHeld()` 的键判之前。只有一条优先级规则 `pick(held, keyHeld, injecting)`：游戏说「松开」以游戏为准；游戏说「按住」而键说松开时，若本模组仍在注入窗口内（`tapHold` 或 `tl.injectAt` + `TAP_HOLD`）就当作自己按压的回读，回落到键判；拿不到组件/字段、调用抛错或返回非布尔都返回 nil 走键路径，且每种原因只记一行日志。`injectKey` 现在在注入点打 `tl.injectAt`（唯一时间戳来源）。DEBUG 下两者不一致时每秒最多一行 `deflect hold: game=… keys=… -> …`。
- **帧时间真值探针**：DEBUG 下每个招式类只读一次 `SendFrameTimes` / `PreHitPointDuration`（`PBZDeflectSystem.d.ts:169-175`），与 `hit_times.txt`+`ad_data.lua` 合成的时间线逐项相减，输出 `TMR <class> frames=[…] prehit=… timeline=[…] delta max=… spread=… -> same clock / constant offset / count differs / differs`。`constant offset` 表示两套时钟只差起点，`differs` 表示不能直接替换学习表——这是「`LEARN`+`learned_hits.txt` 能否退役」的证据，不是结论。
- **参数类型可见**：`onSendFrame` 第 2、3 参数由占位符改为 `bullet` / `rotation`；DEBUG 下每会话前 3 次（之后每 600 次）打印 `SENDARGS bullet=<type:class> rotation=<type> yaw=<值> yawrange=<min..max> kinds=…`。SDK 只钉顺序不钉类型，`AttackRotation.Yaw` 的实际读数范围是下一轮读帧逻辑的前提。
- `tl.api` 25 → 26（新增 `holdAsk(keyHeld, pawn)`）；`tools/test_api_contract.lua` 34 → 36 断言（2/3 位必须命名为 `bullet`/`rotation`，且探针只读这两个名字）；新增 `tools/test_inputstate.lua`（40 断言）并进 `tools/run_all.sh`；集成套件 123 → 139（无角色时回落键判、游戏答案覆盖键判、注入窗口内不采信、每次提问只读一次、`tl.api` 26 项都存在、帧时间比较的 5 种判定与日志格式）。门禁合计 621 断言。

### 探针退役，游戏 hold 答案改成幂等回退

- **游戏 hold 答案改成幂等 + 自动回退**：`tl.installInputState()` 已装即返回同一实例，模块加载失败只尝试一次
  （`tl.inputStateErr` 记原因，同一局不再重试）；`ad_inputstate` 连续 3 次「API 不可用」类故障（无 input component、
  无 `SGameInput`、`IsHolding` 抛错、返回非布尔）后自动回退到键判，也可 `o:disable(why)` 手动回退；「还没有角色」
  「还没有 input action」算暂时状态不计数，一次成功答案即重置连续计数。回退后 `tl.holdAsk` 返回键判且**不再读游戏**。
- 计数：`ad_inputstate.lua` 90 → 110 行；`tl.api` 26 → 27（`installInputState`）。门禁全绿、selene 0 errors、
  `check_docs` 一致；**各套断言数不写进文档**，以 `tools/run_all.sh` 输出为唯一来源（`tools/check_docs.py` 头注释：
  手抄的数字会漂，能推导的才写下来）。
- 测试证据：`ad_inputstate` 的回退语义先在 `tools/test_inputstate.lua` 上 RED（第 3 次故障后 `dead` 仍为 nil），再实现；
  集成侧两条断言用**变异验证**证明有牙：去掉 `holdAsk` 的 `IS.dead` 判断 → `a reverted adapter leaves the key answer alone` 失败，
  把 `installInputState` 改回每次都重建 → `a second install keeps the live adapter` 失败。

## 1.6.4 — 2026-11-17

修复：在模组菜单里改完设置保存不生效

- 新增 [Scripts/ad_menu_bridge.lua](Scripts/ad_menu_bridge.lua)：把完整的 loose 名 pending 逐字节镜像成 Bridge 认识的 exact 名；把 Bridge 写出的 `saved-<exact>.txt` 复制成 loose 名供菜单回读；`events-<loose>.txt` 作为 `menu_config` 的第二事件源。只在 loose 完整（CRLF 结尾）且 exact 不存在时动作，写后回读校验，失败保留原文件并计数、同一原因只记一行。0.5 s 节流；名字里没有 `%` 的模组自动 no-op；不改菜单、不改 Bridge、config 仍由 Bridge 唯一写入。
- 主循环每 tick 走一次 `guarded("menu bridge", …)`；启动日志新增 `menu bridge shim: pending-<loose>.json -> pending-<exact>.json`。

## 1.6.3 — 2026-11-16

审计驱动的稳定性/性能批次，行为对玩家保持不变。

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
