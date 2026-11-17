
# Runtime Lifecycle / 运行时生命周期与资源管理

本文记录 PBZ Auto Defense 在 UE4SS Lua 运行时中的初始化、游戏线程调度、对象可用性、Hook 注册、错误隔离、暂停/恢复和当前清理边界。内容以 Scripts/main.lua 和各边界模块的现状为准。

## 1. Lifecycle overview / 生命周期总览

~~~mermaid
stateDiagram-v2
    [*] --> Loading
    Loading --> Configured: modules + settings loaded
    Configured --> Scheduling: tl.start()
    Scheduling --> Running: delayed action begins ticking
    Scheduling --> Fallback: frame scheduler unavailable / not ticking
    Fallback --> Running: timer scheduler begins ticking
    Running --> Suspended: no player / cutscene / input controlled elsewhere
    Suspended --> Running: controls restored + resume window
    Running --> Recovering: stage error / loop silent
    Recovering --> Running: backoff expires or scheduler restarted
    Running --> [*]: game or UE4SS process exits
~~~

当前脚本没有一个公开的、完整的模组 unload/shutdown 状态机。进程退出通常结束 Lua state 与 UE4SS mod-owned delayed actions，但不能据此推断每个 game hook 都已显式注销。详见本文件“Hook unregistration gap”。

## 2. Startup sequence / 启动流程

1. UE4SS 加载 Scripts/main.lua 并建立当前模组的 Lua state。
2. 加载 UEHelpers、toast、ad_query 和日志设施。
3. 尝试加载 ad_compat，记录 Lua runtime/JIT 版本，建立版本差异封装。
4. 建立运行时 settings，并解析旧 auto_defense.txt 中存在的字段。
5. 初始化 ad_json、ad_menu_bridge shim 和 menu_config；读取 JSON，必要时仅在 JSON 文件缺失时从 legacy settings 首次生成。
6. 准备 event bus、warm-up queue、数据 snapshot、timeline store、policy/input 门和战斗状态。
7. 调用 tl.start() 安排主循环。
8. 注册 F7/F8/F9/F6 热键；部分战斗 Hook 要等 Deflect Component 或目标 UFunction 可用后才注册。

**Initialization safety:** 启动时不要假定 PlayerController、Pawn、Deflect Component、Ability Input Component 或所有目标 UFunction 已存在。代码通过低频重试/按需 Hook 避免将“暂时不存在”永久视作不可用。

## 3. Main loop scheduling / 主循环调度

### Preferred and fallback paths

主循环每次启动都会增加 tl.loopId generation，并按以下优先级选择：

1. 如果 EngineTickAvailable 为 true 且 LoopInGameThreadAfterFrames 可用，优先调用 LoopInGameThreadAfterFrames(1, tick)，每个 EngineTick 帧运行一次。
2. 若帧调度不可用或调用抛错，尝试 LoopInGameThreadWithDelay(10, tick)，按 10 ms 间隔重复。
3. 两条路径都失败时将 tl.loopSchedule 标为 failed，并记录两条路径的具体原因。

调度 API 调用不抛错即记录为 scheduled；handle 可能为 nil，因此不能仅凭 handle 是否存在判断回调是否会运行。当前实现设置约 2 秒的验证窗口：若已安排但仍未见任何 tick，则在后续 tl.check 执行时尝试另一种调度方式。

### Handle ownership and generation guard

- 主循环保存 delayed-action handle（若 API 返回 handle）。
- 重新启动前先尝试 CancelDelayedAction(handle)。
- 取消成功后不再保留旧 handle；取消失败的 handle 放入 tl.loopStale，下一次 start 继续重试，最多保存 8 个旧 handle。
- tick callback 捕获 start 时的 generation id；tl.main(id) 在每帧入口比较 id 与当前 tl.loopId，旧回调即使晚到也不会继续跑战斗逻辑。
- 回调内部 pcall(tl.main, id)，避免单次 Lua 异常直接破坏调度器；相同错误文本只记录一次。

UE4SS 的 delayed actions 由创建它们的 Mod 持有。CancelDelayedAction 只取消当前 mod 所拥有的 handle；不要拿其他模组的 handle 调用，也不要把本模组 handle 泄漏给不相关 mod。

### Watchdog behavior and limit

- tl.check 在主循环每 tick 执行；若距离上次 tick 超过 tl.SILENT（10 秒），会尝试恢复。
- 在自动重启预算耗尽（tl.loopId 达到阈值）后，停止继续自动重启并设置 loopDead，防止无上限重启。
- 热键回调经 ExecuteInGameThread 调用 tl.check(true)，允许人工重试并重置预算。
- 由于 watchdog 本身在被监视的主循环内运行，若循环完全不再被调度，watchdog 无法自行执行；这种完全静默的失效仍需热键人工触发，不能称为完全自动恢复。

## 4. Game-thread boundary / 游戏线程边界

主循环的游戏对象读取、状态判断和输入操作应在 UE4SS 支持的游戏线程回调内执行。当前主循环由 LoopInGameThreadAfterFrames 或 LoopInGameThreadWithDelay 提供调度；热键动作则通过 ExecuteInGameThread 交付。

规范：

- 不要从自建 OS thread、任意 Lua callback 或未知线程直接访问/修改 UObject。
- 事件总线 subscriber 只处理已经复制出的诊断值，不应持有易失 UObject wrapper 跨线程。
- Hook callback 只做必要的轻量记录/状态采样；重计算、文件 IO 和对象全表扫描不应放进热路径。
- 不要把 ProcessEvent 每次调用和 EngineTick 每帧回调当成相同频率或用途。
- 修改 scheduler 前，先验证当前 UE4SS build 的 EngineTickAvailable 和 Delayed Actions API 是否存在，并检查日志中的实际 scheduler 选择。

### Timing domains

当前逻辑同时使用不同时间来源：

- os.clock()：Lua 侧超时、退避、调度间隔、perf 与轮询节流。
- GetTimeSeconds / nowOf(pawn)：游戏时间和命中时间对齐使用的游戏时钟。
- ReceiveFrame.HitGameTime：游戏暴露的命中时间字段。
- Montage position / ability timeline：从敌方攻击动画推算的命中时间。

不要直接比较未归一化的 wall/game/animation clock 数值。把秒和毫秒混用也是高风险：配置 JSON 的 *_ms 字段在读入 runtime 时会乘 0.001 转为秒。

## 5. Player, Pawn and component lifetime / 玩家对象与组件寿命

### PlayerController

UEHelpers.GetPlayerController 原本可能触发 FindAllOf("PlayerController")。main.lua 包装它并缓存有效 controller，以避免每 tick 重复全局扫描。player() 在 controller 不可用时使用约 0.5 秒节流重试，而不是每帧扫描。

### Pawn and components

- Pawn 地址会被用于发现角色切换；新 Pawn 出现后短暂暂停防守，清理易失 FX/perfect-tag 状态，再等待 resume interval。
- Deflect Component 和 Ability Input Component 每 tick 从当前 Pawn 的对应属性解析，不应跨 Pawn 长期缓存裸 wrapper。
- ad_query.valid 等 helper 用于有效性探测；组件/CDO 尚未出现时应返回不可用状态，而不是假设解引用成功。
- AbilitySystemBlueprintLibrary / GameplayStatics 等稳定 CDO 查询由 ad_query 缓存；无效对象/查询异常不能被当成永久成功结果。
- 玩家处于对话、Move/Look input ignored 等状态时，决策暂停；恢复后不会立即假设控制权已稳定，而是经过 resume window。

### Query caches

- StaticFindObject 的稳定路径结果由 ad_query 缓存，并在使用前检查有效性。
- PBZAbilityBlueprintLibrary 等低频/全表扫描 fallback 失败后采用约 5 秒负缓存，避免每帧重复遍历全局 UObject。
- tag() 对相同 tag name memoize；调用者不能修改其共享返回对象。
- Growable runtime caches 挂入 tl.prunable，由 tl.pruneHandles() 统一清理。
- 缓存 UObject 不等于缓存永生：对象失效、Pawn 更换或场景切换都要允许重新解析。

## 6. Hook lifecycle / Hook 生命周期

### Deferred registration

Hook 注册不应一律发生在脚本加载的最早时刻：

| Hook group | Registration trigger | Retry / gate |
|---|---|---|
| Stance frame | parry 相关状态进入 tickGuardRelease 路径时尝试 | 约每 5 秒尝试一次，目标类/函数不可用时继续重试 |
| Attack / montage timeline | Deflect Component 可用，且 debug 或实验跟踪需要时 | 失败后约 10 秒重试 |
| Ability activation | 已有 timeline 数据可用时调用 hookActivation | 每约 5 秒尝试，activationTries 到 12 后停止尝试 |
| Bullet / result hooks | 由 activation hook 初始化阶段触发 | 每个 hook 保存本次登记的状态，并记录失败原因 |

目标 UFunction 可能尚未进入内存；注册失败应被视作“尚不可用”，由相应低频重试策略处理，而不是把 false/nil 状态永久缓存。

### Hook unregistration / Hook 注销（已实现，尚未实机验证）

1.6.5 起每个 hook 站点都接收 `local ok, pre, post = pcall(RegisterHook, PATH, fn)`，并调用
`RT.rememberHook(key, path, pre, post)` 把 `{ path, pre, post }` 存入 `tl.hookIds`。此前只保存首个
返回值，post 半边永远留在引擎里——这正是审计 P1-4 的缺陷。

`RT.unhook(key)` 先按上游文档形式调用 `UnregisterHook(path, preId, postId)`；该形式在本机构建被
拒绝时回落到只带 preId 的旧形式，失败只记一次日志并返回 false（不吞错、不假装成功）。
`RT.unhookAll()` 遍历登记表；`post` 为 nil 时按“引擎没给这一侧”处理，如实记录而不是假定存在。

`tl.teardown(reason)` 是唯一的卸载入口，顺序固定为：取消本模组自己的 delayed action（含
`tl.loopStale` 里取消不掉的旧 handle，重试上限 8）→ `RT.unhookAll()` → 取消 toast 动作 →
flush ledger 与 event sink → 清掉迟到的回调仍可能触碰的句柄 → `tl.stopped = true`。
它幂等（第二次直接返回 false），`tl.main` 在 `tl.stopped` 时不做任何决策，看门狗判定“主循环
已死”时调用它而不是留下半套 hook，热键 `tl.check(true)` 会重新武装并记录一行日志。

仍未证实的部分（不要写成已完成）：
- 本次构建的 `RegisterHook` 是否在**每个**站点都返回两个 id；`post` 为 nil 时的实际行为。
- 三参 `UnregisterHook` 是否被本机 UE4SS 接受（离线测试用的是 stub，只能证明调用形状）。
- `RegisterKeyBind` 没有注销 API：teardown 后热键仍在，按下只会重新武装模组。
- 卸载/热重载是否会由 UE4SS 自己清理 hook（上游文档未明确）。实机验证方法仍是：注销后触发
  目标函数，确认 callback 不再执行；在没有这份日志之前，热更仍建议整进程重启。

### UE4SS upstream references

- [Delayed Actions API](https://github.com/ue4ss/RE-UE4SS/blob/main/docs/lua-api/global-functions/delayedactions.md)
- [RegisterHook](https://github.com/ue4ss/RE-UE4SS/blob/main/docs/lua-api/global-functions/registerhook.md)
- [UnregisterHook](https://github.com/ue4ss/RE-UE4SS/blob/main/docs/lua-api/global-functions/unregisterhook.md)

这些上游接口说明用于核对框架调用约定；目标游戏函数是否存在、PBZ wrapper 是否可用仍由当前游戏构建决定。

## 7. Delayed actions outside the main loop / 其他延迟任务

- 主防守循环是唯一持续高频的决策循环。
- toast.lua 使用一次性/短期 Delayed Action 管理显示提示；对象保存 handle，关闭/重触发时尝试取消旧任务，不用常驻无限轮询代替单次显示。
- ad_async warm-up queue 在主循环中按每 tick 一个 task step 推进；task 出错由 queue 记录，不应传播到战斗决策。
- Bridge shim 每 0.5 秒节流一次文件名镜像检查；menu_config JSON poll 名义上每秒一次。
- 这些低频任务均应保留 owner、handle（若适用）、停止条件和错误通道，不应复制一套独立的无限 loop。

## 8. Pause, recovery and errors / 暂停、恢复和错误处理

### Pause conditions

tl.paused 检查：
- 当前 Pawn 是否改变；
- Pawn 是否处于 dialogue control；
- controller 是否同时忽略 Move 与 Look input。

检测到暂停原因时，清 currentPawn 并暂缓 Hook/决策路径；新角色路径会清 FX 等瞬时状态。恢复需经过 tl.RESUME（当前为 1.5 秒）的等待，避免角色刚重建时立刻访问尚未稳定的组件。

### Stage-level error isolation

- 主 tick 外层 pcall 保护整帧回调。
- guarded(stage, fn, ...) 为独立阶段隔离异常；perf 开启时记录阶段耗时。
- 同一错误信息避免每帧重复记录；阶段连续错误可指数退避，最高 60 秒。
- parry/dodge 有独立 failure backoff；对应热键可人工重试。
- tl.try 为动作调用提供统一日志/事件通道；只读 probe 仍使用轻量 pcall 并按不可用值降级。
- 日志有上限；不要添加每帧无节流的重复 warning。

错误降级必须保留清晰语义：读取失败返回 nil/0/false 时，调用方应知道这是“不可用/unknown”，不要把它伪装成有效 hit 或有效 UObject。

## 9. Shutdown and safe maintenance / 停止与安全维护

`tl.teardown(reason)` 按“阻止新工作 → 取消 owned delayed actions → 注销全部 Hook → 清 pending
state / 输入残留 → 关闭文件句柄”的顺序执行，并且幂等。仍然：

- 不宣称热重载可安全清理 **KeyBind**（API 没有注销入口）与所有临时状态；热更后按一次热键即可
  重新武装，但旧绑定不会消失。
- 三参 `UnregisterHook` 与“引擎是否自动清理 hook”都需要实机日志确认；在此之前，代码调试/热更
  期间仍优先关闭游戏/UE4SS 进程后再替换脚本。
- 禁止尝试取消其他 Mod 创建的 delayed-action handle 或擅自注销其他 Mod 的 Hook。

## 10. Lifecycle verification checklist / 生命周期验收表

- [ ] 启动时 PlayerController 尚未出现：主循环继续运行，按节流频率重试，不发生每帧全局扫描。
- [ ] EngineTick 可用：日志确认选择每 1 frame 的 scheduler，且 tick 确实出现。
- [ ] EngineTick 不可用：10 ms timer fallback 能运行。
- [ ] 模拟 scheduler 调用不抛错但无 tick：约 2 秒后尝试另一条路径。
- [ ] 强制重启循环：旧 handle 被取消；若取消失败，仍保留 stale handle 并 generation-guard 旧回调。
- [ ] Pawn 切换/死亡复活/地图切换：旧组件不再被使用，短暂暂停后恢复。
- [ ] 过场/对话/输入接管：暂停防守，无过场中的 tag/输入残留。
- [ ] Hook 目标尚未加载：重试逻辑可恢复注册，且不会每帧扫描。
- [ ] Hook 注销测试（离线已覆盖调用形状）：实机确认 `UnregisterHook(path, preId, postId)` 被接受、注销后目标函数不再触发 callback、`post` 为 nil 的站点行为如实记录。
- [ ] Toast retrigger/expire：不遗留重复显示 loop。
- [ ] 日志和 stage error backoff 能定位问题，不发生每帧错误风暴。
- [ ] 退出游戏再启动：没有旧进程回调影响新会话。

离线 stub 测试能证明 Lua 分支和状态管理逻辑，不能证明 Unreal 对象寿命、引擎线程行为、真实 Hook 注销、或实际游戏帧预算。实机验收结果应独立记录，不要把模拟测试标注为 live-game validation。

## Related documents / 相关文档

- [Architecture](ARCHITECTURE.md) — 模块职责、启动次序和数据流。
- [Deflect State Machine](DEFLECT-STATE-MACHINE.md) — 弹反、闪避和 guard 状态模型。
- [Configuration Reference](CONFIGURATION-REFERENCE.md) — 41 个配置项与迁移行为。
- [UE4SS Lua API Reference](UE4SS-LUA-API-REFERENCE.md) — UObject、game thread、Delayed Actions 和 Hook API。
- [Module layout](MODULES.md) — 模块职责与运行时公开表面。
