
# Deflect State Machine / 弹反与闪避状态机

本文描述当前 Scripts/main.lua 中每帧防守决策的实际控制流。实现采用多个时间戳、句柄集合和 pending 结构组合状态，而不是一个显式 enum；下图是逻辑状态模型，不表示源码中存在同名状态类。

## 1. Decision contract / 决策契约

每个有效游戏 tick 执行一次决策入口 tl.decide(pawn, deflect, input, gameTime)。它读取：

- Deflect Component 的最近有效 ReceiveFrame：GetNearestValidReceivedFrame(360.0, window, isDodge, -1, RT.out)。
- 可选的逐帧 ReceiveFrames 时间和类型：由 read_frames / fxScan 路径更新。
- 已跟踪的敌方 Ability、Montage、命中时间轴与数据快照。
- 玩家当前 Pawn、能力输入组件、无敌窗/动作锁、guard stance、PBZPerfectDefense ownership。
- 运行配置中的 parry/dodge mode、提前量、最小间隔、i-frame 覆盖和抓取参数。

执行的基本优先级是：

1. 先暂停不安全场景或失效角色上的决策。
2. 维护 guard、角色能力、时间轴和延迟动作。
3. 执行 dodge 路径（尤其是红色不可弹反命中）。
4. 执行 timed dodge。
5. 最后处理还未交给 dodge 的 parryable 命中。

**关键不变量：红色 dodge 必须先于 parry。** 把 parry 移到 dodge 之前可能使普通弹反路径抢走不可弹反的红色命中。

## 2. Logical state model / 逻辑状态模型

| Logical state | Current implementation | Meaning |
|---|---|---|
| Idle / scanning | 每帧 query ReceiveFrames / nearest frame | 当前没有有效候选，继续扫描 |
| Candidate found | 最近有效 hit handle、fxDue、fxType | 已发现待处理命中 |
| Dodge covered | tl.dodgeCovered、lastDodgePress、dodgeIframe | 上一次 dodge 的 i-frame 预计覆盖当前命中，不重复输入 |
| Dodge cooldown | tl.dodgeReady、lastDodgePress、dodgeGap | 上次 dodge 仍在动作间隔中 |
| Dodge deferred | tl.dodgeDefer、ROLL_LEAD、DODGE_AFTER_GUARD | 先推方向/解除 guard，等延迟点到达后发出 dodge |
| Timed dodge pending | timedDodge = {name, at} | 时间轴检测到需要在指定时刻执行的 dodge |
| Parry pending / hold | tl.tapPending、tapHold、tapEndAt | 弹反按键等待最小间隔、短暂保持或释放 |
| Resolved / consumed | parried[h]、dodged[h]、tl.done(h) | 已处理或已交给另一条路径的命中，避免重复响应 |
| Backoff / failed | parryFailed、dodgeFailed、tl.fails | 输入路径连续失败后短暂退避 |
| Suspended | tl.cutWhy、tl.resumeAt、currentPawn=nil | 对话、输入接管、角色切换等场景暂停防守决策 |

这些状态由局部变量、时间戳、表项和 helper 共同表达。不要通过在单一函数中重置其中一项，就假设整个防守状态已经被清空。

## 3. High-level flow / 主流程

~~~mermaid
flowchart TD
    A["tick begins"] --> B{"player + components valid?"}
    B -- No --> X["skip decision; retry next tick"]
    B -- Yes --> C{"cutscene / controls off / pawn changed?"}
    C -- Yes --> S["suspend and clean transient state"]
    C -- No --> D["refresh ownership and query frames"]
    D --> E{"dodge enabled and candidate found?"}
    E -- Yes --> F{"red or forced dodge?"}
    F -- Yes --> G["dodge route"]
    F -- No --> H{"previous dodge covers or is busy?"}
    H -- Covered --> I["mark consumed; no input"]
    H -- Busy + red --> I
    H -- Busy + parryable --> J["leave candidate for parry"]
    H -- Ready --> G
    E -- No --> K["timeline timed-dodge check"]
    G --> L["execute now or defer until guard/roll release"]
    I --> K
    J --> K
    K --> M{"timed dodge due?"}
    M -- Yes --> N["execute timed dodge"]
    M -- No --> O["parry stage"]
    N --> O
    O --> P{"parry allowed and candidate due?"}
    P -- No --> Q["wait for next tick"]
    P -- Yes --> R["tap/ability attempt and receipt tracking"]
~~~

上图为便于理解而压缩的流程。真实实现还包含 perfect tag、health tracking、enemy/stance hooks、Sát Khí recovery、guard release、manual dodge、failure backoff 和 ledger 记录。

## 4. Input gates / 输入前置门

弹反入口会先检查：

- parry 开关与 parry failure backoff。
- PBZPerfectDefense 是否拥有 guard；若对方 AutoGuard 正在持有防守，AD 不再争抢弹反输入。闸门读的是对方**磁盘配置 + 启用状态**（`pbzpd=yield` 时），不是跨进程锁。
- 当前是否有 special attack / black flash 已指定交由 dodge。
- 若 game-data 层可用，玩家当前无敌窗会跳过不必要的 parry。
- hit handle 是否有效且未被当前轮次标记为已处理。
- 玩家自己的动作锁：busy_skip 打开时，若命中仍有足够提前量且玩家未处于 stun window，可能等待动作锁解除。

闪避入口会先检查 dodge mode 与 failure backoff。被判为红色不可弹反的命中不会因 dodge cooldown 而转交给 parry；普通可弹反命中在 cooldown 中则可留给后续 parry 阶段。

所有真实输入、副作用和 tag 写入应经过 ad_input 的统一入口，并由 ad_policy 返回 allow/deny 与原因。决策算法不要绕开该门直接创建新的输入注入路径。

## 5. Dodge branch / 闪避分支

### 5.1 Candidate selection

tickDodge 根据 dodge mode 和 special state 选择查询类型：

- dodge=off：不进入自动闪避分支。
- dodge=red：先查询红色/不可弹反类型。
- dodge=all：也查询正常/可弹反类型。
- special attack 可把本来可弹反的类型路由到 dodge。

当前搜索窗以 dodgeLead() + ROLL_LEAD 为基础，随后使用 fxDue 估算距离命中时间。

### 5.2 Coverage and cooldown

候选命中会依次考虑：

1. 命中是否已交给 timeline dodge（例如 red hit 已由 tl.hitSoon 路径接管）。
2. 命中是否已经被上一段 dodge 的 i-frame 覆盖；若覆盖，标记为 consumed，不再次按键。
3. dodge 是否已 ready。若仍在动作间隔：
   - 红色命中不可弹反，当前实现记录为已处理并不发出新的按键。
   - 普通可弹反命中留给后面的 parry 阶段。
4. 若准备就绪，记录 dodged handle 并执行 dodge 或安排延迟 dodge。

这说明 dodge_gap_ms、dodge_iframe_ms 和 dodge_lead_ms 不是互相独立的数字：它们共同影响候选何时可以进入新输入、何时能由上一个 dodge 覆盖，以及红/普通命中的回退路径。

### 5.3 Execute now or defer

dodge(input, kind, handle, now) 尝试以下路径：

- 解析真实 IA_Dodge 输入 action。
- 若启用了横向翻滚方向控制且角色可用，先对移动方向做侧向设置，写入 dodgeDefer，并在 ROLL_LEAD 后执行。
- 若角色当前仍持有 deflect stance，则先释放 guard / end stance，再延迟到 DODGE_AFTER_GUARD 后执行。
- 否则尝试通过 Ability Input Component 激活 PerfectDodge ability。
- 若能力激活失败，走 Enhanced Input key injection fallback；必要时也注入 IA_PerfectDodge，并维护 dodge hold 窗口。
- 输出事件和 ledger 记录。

延迟执行由 tickGuardRelease / 主循环后续 tick 消费。Pawn 或 input object 失效时不会把旧对象当作有效输入继续使用。

### 5.4 Timed dodge

时间轴观察器可创建 timedDodge（名称 + 目标时间 at）。tickTimedDodge 每帧检查是否到期，到期后清空 pending 项，再检查 dodge mode 并调用 dodge。它与当前 ReceiveFrame 的即时 dodge 分支是两个入口；时间轴分支不应被误解为由 GetNearestValidReceivedFrame 的窗口自动产生。

## 6. Parry branch / 弹反分支

tickParry 在 dodge / timed dodge 阶段之后运行。它按如下顺序判断：

1. parry 必须开启，且不能处于 parry failure backoff。
2. PBZPerfectDefense ownership 不得阻止 AD 输入。
3. 若当前 special / black-flash 事件已由 dodge 接管，不发弹反。
4. 若 game-data 报告玩家当前处于有效无敌窗口，则不浪费弹反输入。
5. 计算动态 parry lead；搜索窗为 max(PARRY_WINDOW, lead + 0.06)。
6. 查找最近的非-dodge hit handle，并跳过无效/已处理 handle。
7. 若候选属于抓取帧且命中即将发生，使用 grabDodge 路径，而不是普通 parry。
8. 若存在精确 due 时间，则只在 due <= lead 时输入；过早的候选等待下一 tick。
9. 若缺少精确时间，则收窄到原有 PARRY_WINDOW 判断，避免提前过量按键。
10. busy_skip 开启且玩家动作锁仍生效时等待。
11. 标记 parried handle；若处于 black-flash rollout 的 noTapUntil 窗口则不发弹反。
12. 先释放可能残留的按键，再尝试时间轴 tapParry、已验证/缓存的 parryWorks 路径，或按候选 PARRY_TRIES 逐个尝试。

在输入路径未确定有效方法前，函数会通过候选策略寻找可用的弹反入口；不要把“尝试调用”当作“游戏必然接受了弹反”。receipt 开关用于额外确认游戏是否观察到输入/结果；它不是每个输入都已被确认的证明。

## 7. Perfect tag and modes / 完美标记与模式

perfectWanted / tickPerfect 维护当前 Pawn 的完美标记：

- perfect=false：移除或不再维持本模组的完美处理。
- perfect_mode=always：尽可能持续保持完美标记。
- perfect_mode=window：仅当普通 hit 即将进入完美窗口时短暂加标记。
- perfect_mode=give：不常驻标记；依赖游戏自己的弹反窗口/补偿逻辑，必要时在特定 black flash / bullet 窗口使用 tag。该模式的 guard 和 Sát Khí 处理更复杂。
- black_flash=dodge：黑闪优先交由 dodge；black_flash=parry 则可在 give 模式的黑闪窗口使用完美 tag。

PBZPerfectDefense ownership 对 perfect tag 与 guard press 有独立限制；不要把 perfect 与 parry 看成同一个 bool。完美标记的应用/清理由当前 Pawn 地址和 tag 状态跟踪，Pawn 重建或 cutscene 暂停时需要清理/重查。

## 8. Guard hold and release / 防守保持与释放

弹反输入可能在游戏端留下持续 guard。主要维护路径位于 tickGuardRelease：

- 处理 dodgeHoldUntil、dodgeDefer、dodgeWatch 和延迟移动方向。
- 维护 tapHold：若游戏没有把一次模拟 tap 识别成 key-down，必要时调用被动 stance 的 On Stance Key Down 补足。
- 对未被 ReceiveFrame 预告的命中，必要时重新抬起 guard。
- perfect_mode=give 下，在没有即将到来的 hit/tag/bullet 且持续时间达到阈值时释放 guard。
- guard_release 开启时，管理 sprint/dodge key 状态和冲刺期间 guard 释放。
- guard_release_combat_end > 0 时，若已超过静默阈值且没有附近攻击、受击或弹反，按战斗结束释放一次。
- guard_release_after > 0 时，releaseFrom 静默达到阈值且没有即将命中的攻击时释放。

注意：main.lua 中旧的 releaseHeldGuard 外围路径由 RELEASE_FROM_OUTSIDE=false 禁用，函数每次只调用 checkRelease 并清理 lastTap；不能将它当作主释放机制。真正的 guard 生命周期由 tickGuardRelease 管理。

## 9. State cleanup and failure handling / 清理与失败处理

| Trigger | Expected cleanup / 当前处理方向 |
|---|---|
| Hit handle resolved | 写入 parried/dodged 跟踪，避免下一 tick 重复 |
| Dodge deferred | 保留延迟输入信息，等待对应 at 时间点；执行前检查输入对象有效性 |
| parry turned off | 清空本模组 pending tap、tap hold、receipt；不强行释放外部 guard |
| read_frames toggled | 清理 FX / hit-frame cache |
| receipt toggled | 清理旧 receipt state |
| perf toggled | 重置性能统计窗口 |
| Pawn address changes | 暂停决策，清 FX / perfect tag 等易失状态，再等新角色稳定 |
| dialogue / input ignored | suspend decision chain；controls 恢复后等待 resume interval |
| repeated stage errors | stage guard 增加 backoff/pause，记录首个错误并避免每帧重复抛错 |
| parry/dodge failure | 使用独立的失败退避时钟；可由对应热键进行人工重试 |

状态清理应在其 owner 模块中完成。不要通过新建一个平行的 global state reset 函数去猜测并清空其他模块的私有字段。

## 10. Configuration mapping / 配置如何影响状态机

| Setting | Decision effect |
|---|---|
| perfect / perfect_mode / black_flash | 完美标记维护、黑闪分流与特殊窗口 |
| parry / parry_method / parry_lead / parry_lead_seconds | 弹反允许、执行 API 和弹反前置时间 |
| dodge / dodge_lead_ms / dodge_gap_ms / dodge_iframe_ms | 闪避候选范围、执行时间、重复间隔和覆盖判断 |
| pair_frames / read_frames | 时间轴命中与真实 ReceiveFrames 配对/读取 |
| min_gap_ms / grab_lead_ms | 弹反输入间距和抓取专门提前量 |
| dodge_cd / busy_skip / flurry_guard | dodge overlap、角色自身动作锁与多段攻击 guard 策略 |
| guard_release / guard_release_after / guard_release_combat_end | guard 释放条件 |
| pbzpd | 与 PBZPerfectDefense 的 guard ownership 协作策略 |
| data / data_tags | 是否启用 bundled game data 与招式标签过滤 |
| dodge_attacks | 实验性名称/标签匹配，指定攻击走 dodge 而非 parry |

字段范围、默认值和迁移规则见 [Configuration Reference](CONFIGURATION-REFERENCE.md)。

## 11. Verification and limitations / 验证要求与限制

- tools/test_integration.lua 可通过 fake deflect/input 驱动 tl.decide 的关键分支，但这是离线 UE4SS stub，不等于真实游戏战斗。
- tools/test_policy.lua 验证 intent allow/deny 规则；tools/test_timeline.lua 验证时间轴表和计数所有权；tools/test_menu_config.lua 验证配置约束。
- 实机验收必须覆盖红/蓝/普通命中、黑闪、抓取、多段连击、闪避覆盖、连续闪避 cooldown、PD AutoGuard、Pawn 切换、对话/过场和无 ReceiveFrame 的 fallback。
- 在修改顺序、提前量、dedupe 或 guard release 前，先记录相同场景的 decision ledger 与 perf_log；不要只凭平均时间判断稳定性。
- 与 PBZPerfectDefense 的让位是**共约**（cooperative hand-off）：读它的配置与启用状态后主动退让，**不是跨进程互斥**。两套运行时各自持有本地状态，没有握手也没有仲裁者；对方在我们判定之后才改动 guard 时，同一帧仍可能出现双方动作。`pbzpd=yield` 只保证「不去争抢一个它声明要守的 guard」，不保证无竞态。
- 反射生成的 SDK 声明不是 UE4SS Lua 调用成功的证据；Out 参数、输入回执和跨 build 行为需分别验证。

## Related documents / 相关文档

- [Architecture](ARCHITECTURE.md) — 系统模块与主循环总览。
- [Configuration Reference](CONFIGURATION-REFERENCE.md) — 配置项、范围和持久化/迁移。
- [Runtime Lifecycle](RUNTIME-LIFECYCLE.md) — 主循环、Hook、Delayed Actions 与暂停/恢复。
- [Module layout](MODULES.md) — 模块职责、intent 门和公开 API。
- [PBZ Game API Reference](PBZ-GAME-API-REFERENCE.md) — Deflect Component、Ability Input Component 和反射签名。
