# API 驱动的性能优化路线图

本文把 UE4SS、PBZModLoader SDK 和 PBZ USMAP 的接口发现结果映射到 PBZ Auto Defense 当前实现。目标不是最大化 API 调用数量，而是在保持防守行为的前提下，减少每帧开销、降低对象生命周期错误、提升 API 兼容性，并建立可复现的测量方法。

## 1. 优化原则

1. **先判断调用在哪条运行时。** UE4SS Lua、PBZModLoader JS 和 USMAP 工具链互不等价。
2. **优先低风险的框架级 API。** 帧调度、延迟动作 handle、对象缓存、低频查找通常比直接改游戏能力更容易验证。
3. **读优先、写谨慎。** 先读取游戏状态/反射结构，再评估是否要写入或触发能力。
4. **签名证据与调用证据分开。** reflection-generated 不是 call-verified。
5. **每次优化必须保留旧行为回退路径。** 没有实机验证的优化不应静默成为唯一防守路径。
6. **性能结论要基于同场景尾延迟。** 平均耗时变小，但 p95/p99 或防守时序变差，不算优化成功。

## 2. 当前已实现的 API 优化

### 2.1 主循环使用 EngineTick 帧调度

**旧实现：** 10 ms 轮询执行一次主循环。低于 100 FPS 时，同一渲染帧可能出现重复定时器回调；帧与回调节奏也不完全一致。

**当前实现：**
- 检测 EngineTickAvailable 和 LoopInGameThreadAfterFrames。
- 优先以 1 帧间隔执行防守决策。
- 当前 UE4SS 不可用或创建失败时，回退到 LoopInGameThreadWithDelay(10, callback)。
- 保存 delayed-action handle；看门狗重启前调用 CancelDelayedAction 取消旧循环。
- 保留 tl.loopId generation 检查，避免旧回调执行旧代逻辑。
- 日志只在调度模式切换/首次选择时说明 Frame 或 Timer。

**收益预期：** 决策更贴合游戏帧；避免无必要的帧间 timer wake-up 和同一帧重复采样。

**不能据此宣称：** FPS 一定提高、命中检测延迟下降或 p99 变好。回调每帧执行时本身仍占用当前帧预算。

### 2.2 缓解全局 UObject 扫描

UE4SS 文档明确说明 FindAllOf 很慢，需要遍历全局对象数组；ForEachUObject 也应视为全局对象遍历。

当前 ad_query.tagLibrary：
- 先按可能路径调用 StaticFindObject；
- 只有稳定路径没有找到时，才使用 ForEachUObject 兜底；
- 负查找设置 5 秒冷却，不在每个 tick 反复重扫；
- 找到后缓存 CDO，并在后续使用前检查 IsValid；
- 冷却到期后仍允许重试，兼容迟加载对象。

### 2.3 缓存玩家控制器

UEHelpers.GetPlayerController 的原始实现会 FindAllOf("PlayerController")。主模组已经加了一层缓存；player() 还将失效控制器的重查频率限制为 0.5 秒，菜单/加载阶段不会每帧全表扫描。

### 2.4 缺失 CDO 的安全降级

ad_query.ascOf 与 ad_query.nowOf 现在先检查 Pawn、Default Object 和调用结果：
- AbilitySystemBlueprintLibrary 不存在或 GetAbilitySystemComponent 失败时返回 nil；
- GameplayStatics 不存在或 GetTimeSeconds 失败时返回 0；
- 不把 nil CDO 直接解引用为 Lua 异常。

这不是防守算法改变，而是可选查询在启动/切换时的失败保护。上层仍应按 nil/0 对待“查询不可用”状态。

## 3. 现有热路径与 API 映射

| 热路径 | 当前 API/数据来源 | 当前策略 | 风险 |
|---|---|---|---|
| 玩家 Pawn 查询 | UEHelpers / Controller.Pawn | 缓存 Controller；失效后节流重查 | 角色重建时需刷新 |
| Deflect Component | Pawn["Deflect Component"] | 主循环持有当前 Pawn/组件 | 属性名和组件生命周期受游戏控制 |
| Ability Input Component | Pawn["Ability Input Component"] | 当前用于动作执行 | 可探索更精确的状态读取 |
| 最近受击帧 | GetNearestValidReceivedFrame | 返回 handle + MaxPreimpactTime 窗口 | OutFrame 未用于决策 |
| Received frame scan | ReceiveFrames TMap | 已用于读取命中时序/回执数据 | 容器 wrapper 和快照语义 |
| Ability System Component | AbilitySystemBlueprintLibrary CDO | StaticFindObject 缓存 | CDO 启动时可能缺失 |
| Gameplay time | GameplayStatics CDO | StaticFindObject 缓存 | 缺失时降级为 0 |
| Enemy ability tracking | UObject 遍历 + 20 s 扫描间隔 | 只在需要跟踪攻击时扫描 | 全局扫描成本需观测 |
| Attack hooks | RegisterHook | 目标对象出现后尝试安装 | Hook ID 生命周期可进一步完善 |
| Main loop | Delayed Actions | EngineTick 优先 + 10 ms fallback | 实际帧回调待游戏验证 |
| Logging/ledger | 文件写入 + buffered sink | 有上限/节流/独立 perf 采样 | 不得回到每帧同步写入 |

## 4. 下一阶段优化清单

### P0：只读验证，预计低风险

#### 4.1 AbilityInputComponent 状态字段

PBZ SDK 的 SGameInputSystem.d.ts 声明：
- InActionPhase
- ActionPhase
- ValidBufferInputs
- CurrentInputSets
- CanActivateExternalActionAbility(ActionPriority)

潜在收益：更准确判断玩家是否处于攻击、闪避或其它输入锁状态，减少“按键进入缓冲区但错过受击窗”的情况。

实施步骤：
1. 确认当前 Pawn 的 Ability Input Component 实例和 IsValid。
2. 在 idle、攻击、闪避、受击、抓投、暂停/菜单状态记录字段。
3. 与现有 montageState/playerBusy 结果比对。
4. 统计误判率、漏判率和字段刷新延迟。
5. 第一轮只写诊断，不改变 parry/dodge 决策。

未验证前不能把 InActionPhase 直接当成所有动作锁的等价布尔值，也不能猜 ActionPriority 的合法范围。

#### 4.2 ReceiveFrames 的只读批量访问

DeflectComponent 声明 ReceiveFrames 为 TMap<number, DeflectReceiveFrame>。可比较两种方法：
- 逐个 handle 调用现有查询函数；
- 只读遍历 ReceiveFrames，提取必要的时间/IsDodge/IsHit 元数据。

测量项：
- map.ForEach 总耗时；
- 每 tick 读取帧数；
- 查询结果与现有 nearest handle 是否一致；
- 遍历中 frame 被游戏更新时是否存在非一致快照；
- Lua userdata/RemoteUnrealParam 转换分配量。

若 ForEach 成本更高或数据一致性不清楚，保持当前方法。不能为了减少 API 次数而牺牲帧时序正确性。

#### 4.3 Hook 生命周期和重复安装审计

UE4SS RegisterHook 要求目标 UFunction 已在内存中，并返回 PreId/PostId；卸载需要 UnregisterHook(path, preId, postId)。

当前代码需要按 Hook 点核对：
- 目标函数的类和完整路径是否随游戏 build 变化；
- 重试逻辑是否会重复安装；
- Hook 安装结果是否持有 ID；
- 模组热重载/角色重建时是否需要 unregister；
- Hook callback 是否只做轻量采样并使用 RemoteUnrealParam:get()。

不要仅因为 RegisterHook 没抛异常就把它记为有效；应确认目标确实触发过回调。

### P1：单独实验后决定

#### 4.4 GetSelfResultData：补充防守结果

PBZDeflectSystem 声明 GetSelfResultData(handle, GameplayTag, out DeflectResultData)。它可能给 ledger 补充游戏侧的实际防守类型、源对象和命中时间。

前置条件：
- 确认正确 GameplayTag；
- 验证 UE4SS Lua out 参数写回；
- 明确 handle 是否仍有效；
- 不要为了诊断先调用 Consume/Stop frame；
- 对比 ledger 已有的“press/receipt/result”链。

只在结果字段能稳定读出且能解释实际防守结果时才接入正式日志。

#### 4.5 TryActivateExternalActionAbilityByTag

PBZ AbilityInputComponent 声明了 Try/Force API。Try API 可作为实验候选，但仍需验证：
- AbilityTag 的准确值；
- InputAction 对应的真实资产；
- ActionPriority 合法范围；
- 返回 true 是否确实激活能力；
- 是否与原输入注入或 PBZPerfectDefense 重复触发；
- 动作锁/缓冲/取消行为是否与游戏原生按键一致。

实验期间不能同时开启现有按键注入和新能力触发，避免一次输入被触发两次。

### P2：暂不实现

| API/做法 | 暂不实现原因 |
|---|---|
| 复用 GetNearestValidReceivedFrame 的同一个 OutFrame table | 未确认函数是否累积数据、失败是否清空、UE4SS 是否完整覆盖 table |
| ForceActivateExternalActionAbilityByTag | 强制语义可能绕过输入优先级/动作锁或别的 MOD 所有权 |
| FlushPlayerInput | 影响范围可能包括玩家和其他 MOD 输入，不能作为单次失败的恢复按钮 |
| StartContinuousInputInjectionForAction | 持续输入需要可靠停止及生命周期管理，反射声明没有给出已验证的端到端方案 |
| 直接写 DeflectComponent 内部字段 | 改变游戏运行状态，字段用途及不变量未逐项验证 |
| 把 USMAP 地址或布局偏移写入 Lua | 地址按 build 变化，不是运行时公开 API |

## 5. 性能测试方案

### 5.1 对照组

至少准备：
- Baseline：现有 main 分支（当前 EngineTick 优先版本）。
- Candidate：一次只打开一个新 API 探测或优化。
- Rollback：关闭 feature flag 后立即恢复现有路径。

不要一次同时启用批量帧读取、AbilityInput 新判断和 TryActivate 能力，否则无法归因差异。

### 5.2 固定条件

每次 A/B 应固定：
- Steam build、EXE SHA-256、UE4SS build；
- 分辨率、画质、FPS limit、VSync；
- 地图、玩家角色、武器和装备；
- 敌人、攻击招式、攻击距离和视角；
- 模组列表与 PBZPerfectDefense 配置；
- 每组样本时长和重复次数。

### 5.3 指标

| 指标 | 作用 |
|---|---|
| tick avg / p50 | 常态开销 |
| tick p95 / p99 | 尾延迟与偶发卡顿 |
| tick max / hitches | 最慢回调及帧间隔异常 |
| hook count / total / max | hook 成本 |
| Lua memory | 临时分配/泄漏线索 |
| decision ledger | 记录是否漏判、重复按键、错过窗口 |
| game frame time/FPS | 游戏整体表现，不能只看 Lua 自身 |

### 5.4 通过标准

候选优化要同时满足：
1. 不增加漏弹反/漏闪避；
2. 不产生重复输入或错误 guard 状态；
3. p95/p99 或 hitch 指标有稳定改善，或提供明确的稳定性收益；
4. 至少跨多次相同场景运行可复现；
5. 出现异常时 feature flag 可关闭并恢复旧路径。

如果只减少 API 调用次数却使防守时序变差，必须拒绝这项优化。

### 5.5 首次实测（2026-11-18 04:50–04:59）

条件：`perf=on`、`debug=on`、`loaded v1.6.4`、Lua 5.4 无 JIT、EngineTick 每帧调度；
9 分钟战斗共 26,926 ticks（≈52 Hz，同期游戏帧率同一量级）。样本取 `perf_log.txt` 里 04:58:26 的稳态块。

| 指标 | 读数 |
|---|---|
| tick 每帧开销 | avg 2.05 ms、p50 2 ms、p95 4 ms、p99 7 ms、max 34 ms |
| 最贵的三段 | `timeline` 0.808 ms（p95 2 / p99 5 / max 7）、`guard release` 0.563 ms（p95 2 / p99 4）、`dodge` 0.249 ms |
| 其余 stage | 全部 ≤ 0.05 ms avg；`frames probe` 0.107 ms 是 debug-only 探针，单次峰值 30 ms |
| hooks | 10 s 内 46 次，合计 51 ms，单次最大 34 ms |
| Lua 内存 | 启动 6.7 MB → 战斗 25–30 MB |
| hitches > 40 ms | 9 分钟共 103 次；最大 5708 ms（04:50:45 角色加载）、300 ms、238 ms |

读法：稳态 p50 2 ms 里 `timeline`+`guard release`+`dodge` 占约 1.6 ms，这三段是唯一值得优化的对象；
`max 34 ms` 与 `frames probe max 30 ms` 是同一件事（新目标类第一次探测，关掉 `debug` 即消失）；
hitches 集中在加载/换角色时刻，还不能归因到 Lua，需与游戏自身卡顿对照。

## 6. 当前测试覆盖

离线测试入口为：

~~~bash
bash tools/run_all.sh
~~~

新增/扩展测试：
- test_query.lua：PBZ Ability Library 负查找节流、迟加载成功缓存，以及缺失 AbilitySystem/GameplayStatics CDO 的安全降级；
- test_integration.lua：主循环优先 EngineTick、10 ms timer fallback、旧 scheduler handle 取消；
- 其它既有测试覆盖 policy、async、timeline、menu config、menu bridge。

这些是离线 stub/test，不会启动 PBZ，也不验证真实 UE4SS EngineTick、游戏帧时序、能力激活或实机性能。需要在实际游戏 build 中完成现场验收。

## 7. 对应源文件

- Scripts/main.lua：主循环、对象查询调用点、防守决策与性能计量
- Scripts/ad_query.lua：StaticFindObject 缓存、Tag Library 查找、组件/ASC/游戏时钟查询
- Scripts/ad_input.lua：统一输入入口
- Scripts/ad_policy.lua：输入/Tag 决策规则
- Scripts/ad_timeline.lua：命中时间线数据的单一持有者
- Scripts/ad_async.lua：只读事件环与分帧预算预热
- tools/test_query.lua：查询缓存和可选对象回归测试
- tools/test_integration.lua：主循环调度/handle 集成测试
- tools/run_all.sh：统一离线测试入口

## 8. SDK 与反射资源

开始使用新的游戏类型或函数前，先参阅 [PBZ SDK 与反射资源索引](PBZ-SDK-RESOURCES.md)；逐条签名核对、验证等级与新增候选见 [PBZ 游戏反射 API 参考](PBZ-GAME-API-REFERENCE.md)（§2 验证等级、§9 候选与「不应直接执行」、§9.3 仍未证实的字段）。其中区分 PBZModLoader 的 TypeScript Game API SDK、UE4SS C++ SDK Generator 和 PBZ USMAP 映射文件，并标明它们分别适用于哪种 MOD 运行时。

## 9. 上游 API 参考

- [UE4SS Delayed Actions](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/delayedactions.md)
- [UE4SS FindAllOf 性能说明](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/findallof.md)
- [UE4SS RegisterHook](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/registerhook.md)
- [PBZ DeflectSystem SDK](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/types/generated/PBZDeflectSystem.d.ts)
- [PBZ SGameInputSystem SDK](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/types/generated/SGameInputSystem.d.ts)
- [PBZ EnhancedInput SDK](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/types/generated/EnhancedInput.d.ts)
