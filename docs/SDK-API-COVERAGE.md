# PBZ Auto Defense × PBZModLoader Game API SDK 0.3.3 覆盖审计

审计类型：只读核对；代码改动仅限「把已确认的契约固化成离线断言」（见文末）。
完整取证报告（含逐行签名、双基准行号、curl 复现命令）是 `tools/out/sdk-coverage.md`，
该目录不入库；本文件是随仓库走的结论与待办。

## 0. 索引与验证等级

- SDK：`@pbz-mod-loader/game-api 0.3.3`，仓库 `KintaroModding/phantombladezero_pbzmodloader` 分支
  `release`，HEAD `531d564f`；`api-surface.json` 记录 build `CL-302256_JKS-17280`、engine 5.7.4、
  `testedAt 2026-11-04`。本机**没有** SDK 副本，全部从 raw 取回后按 sha256 校验。
- 最相关两份：`sdk/types/generated/PBZDeflectSystem.d.ts`、`SGameInputSystem.d.ts`。
- `api-surface.json` 的 `verificationLevels` 只有三级：`reflection-generated`（签名由反射元数据生成，
  未逐项调用测试）、`binding-confirmed`（成员能被解析）、`call-verified`（在 2026-11-04 那套环境里
  representative call 通过）。`binding-support-verification.json` 的 scope 原文写明
  *“No gameplay method callability guarantee.”*
- **因此 SDK 的作用是签名/字段/枚举的权威索引，不是运行时担保**；AD 的 Deflect 热路径全部属于
  `reflection-generated`。

## 1. 结论一：6 个核心调用签名逐位吻合（没有隐藏的签名错误）

| AD 调用点 | SDK 声明 | 结论 |
|---|---|---|
| `Scripts/main.lua:445` | `DeflectComponent.GetNearestValidReceivedFrame(DeflectAngle, MaxPreimpactTime, IsDodge, CurrentHandle, OutFrame)`（PBZDeflectSystem.d.ts:21） | 5 参逐位吻合；空结果返回值（-1 还是 0）SDK 未写，AD 用 `tonumber(...) or -1` 兜住 |
| `Scripts/main.lua:4383` `onSendFrame` | `DeflectComponent.SendDeflectFrame(Action, Bullet, AttackRotation, DeflectRadius, DeflectAngle, Strength, Direction, DeflectKnockback, HitPoint, IsDodge, CounterAbility)`（:25） | 11 参逐位吻合，占位符正好落在 2/3/4/5/8/9 位 |
| `Scripts/main.lua:1152` `ReceiveFrames:ForEach` | `ReceiveFrames: TMap<number, DeflectReceiveFrame>`（:8） | 类型吻合；`ForEach` 是 UE4SS 容器 API（PuerTS 的 TMap 没有这个方法） |
| `Scripts/main.lua:1912` / `:2208` | `AbilityInputComponent.TryActivateExternalActionAbilityInterruptLowerByTag(AbilityTag, InputAction, ActionPriority)`（SGameInputSystem.d.ts:59） | 签名吻合；`-5` 的优先级语义 SDK 不解释 |
| `Scripts/main.lua:1848` / `:3141` | `InjectInputVectorForAction(Action, Value: Vector, Modifiers, Triggers)`（EnhancedInput.d.ts:333） | 吻合；数字量注入到布尔动作的映射仍未验证，故有回执闭环 |
| `Scripts/main.lua:1742-1745` | `AddLooseGameplayTag(Actor, GameplayTag, bShouldReplicate): boolean` / `RemoveLooseGameplayTag(...)`（ProjectPBZ.d.ts:6117/:6142） | 与 AD 的 3 参调用完全一致 |

## 2. 结论二：两套运行时不能混用

| 维度 | AD（UE4SS 注入，Lua 5.4） | SDK 描述的对象（PBZModLoader，PuerTS/JS） |
|---|---|---|
| 对象查找 | `StaticFindObject` / `FindAllOf` / `ForEachUObject` | `Class.Load` / `Object.Load` / `NewObject` |
| 出参 | Lua table / `RemoteUnrealParam` | `$Ref<T>` + `$unref` |
| 容器 | UE4SS 的 TArray/TMap userdata，有 `ForEach` | TMap 有 `Num/GetKey/Get/GetRef/Set`，**没有 ForEach** |
| 名称 | `GetFName`/`GetFullName`/`GetAddress` | `GetName`，路径走 `KismetSystemLibrary` |
| 类型判断 | `obj:IsA(cls)` | **没有 Cast** |

所以「SDK 里查不到」的调用绝大多数是 UE4SS 运行时（hook、对象扫描、`GetAddress`、`FName`、UMG 构造），
属于工具边界而不是缺口。**没有任何一处是「AD 调了 SDK 里不存在的游戏函数」。**

唯一的名字差异：`DeflectBulletType` 在 C++ 基类（`LGAAction_DurationBulletWithDeflectBase`）与蓝图子类
（`GAA_DelayDeflectProjectileBullet_C."Deflect Bullet Type"`）上不同名。AD 的双名回退是**正确**的，不要删。

## 3. 结论三：AD 实际上只在极少数调用上有运行时背书

`api-surface.json` 的 `modules.ue` 手写子集里的 `GameplayStatics.GetTimeSeconds`、`Actor.GetVelocity`、
`Pawn.GetController` 等属于 runtime-surface；Deflect / 输入 / 标签 / 动画全部只有 reflection-generated。
这意味着：**行为正确性仍靠 AD 自己的 ledger 与回执，不能引用 SDK 当担保。**

## 4. 新增候选（SDK 已声明、AD 未用）

按收益排序，全部先只读、再替换：

| 候选 | SDK 声明 | 能替掉 AD 的什么 | 前置/风险 |
|---|---|---|---|
| `SendFrameTimes / StartBulletTimes / EndBulletTimes` | PBZDeflectSystem.d.ts:173-175 | `data/ad_data.lua` + `hit_times.txt` + `learned_hits.txt` 的离线学习（运行时真值） | 数组单位（动作秒 vs 帧号）未验证；**已落地为 DEBUG 探针（§7）** |
| `PreHitPointDuration / RuntimePreHitPointDuration` | :169-170 | parry lead 的「45% 猜测」换成真值 | 两字段差异需实机 |
| `BulletRepetitions / BulletDuration` | :167-168 | `flurry_guard`、连发判断 | 只读 |
| `SGameInputComponent.IsHolding / GetHoldTime / HoldingInputs` | SGameInputSystem.d.ts:299-302 | `IsInputKeyDown + QueryKeysMappedToAction` 反推「键还按着」 | 取法 `pawn["Ability Input Component"].SGameInput`；**IsHolding/GetHoldTime 已落地，键判保留为回落（§7）** |
| `DeflectComponent.GetSelfResultData(Handle, DeflectResult, OutResultData)` | PBZDeflectSystem.d.ts:22 | ledger「结果」列靠血条推测 | Out 参数与 tag 取值未验证 |
| `SendFrames: TMap<number, DeflectSendFrame>` | :7 | 发送侧帧（`HitGameTime/Receivers/IgnoredActors/Paused`） | 只读；是「已发出」不是「会命中」 |
| `AbilityInputComponent.InActionPhase / ActionPhase` | SGameInputSystem.d.ts:42-43 | `busy_skip` / montage 状态 | 时序语义未验证 |
| `BasicAttributeSet.ShachiRegen / ShachiRegenCooldown` | CharacterBasics.d.ts:124-125 | 常量 `REGEN_PER_SEC = 0.33` | 语义未验证；只读比对后再决定 |
| `BP_PlayerDeflectPassive_C."Hold Deflect Ability Tag/Action Priority"` | blueprints.d.ts:218827/218833 | `PARRY_TRIES` 一类硬编码 | 只读 |
| `BPL_DeflectUtils_C."Is Controlled Bullet"` | blueprints.d.ts:219523 | 红眼/必闪类的判读 | Out 参数 |

## 5. 明确不要做（SDK 依据）

- `InjectInputForAction` / `StartContinuousInputInjectionForAction`：`RawValue: InputActionValue` 在 SDK 里是
  **没有字段的空结构体**（EnhancedInput.d.ts:504-510），JS/Lua 侧都无法构造。AD 继续用
  `InjectInputVectorForAction`。
- `SendDeflectFrame`、`PauseSendFrame/ResumeSendFrame`、`ConsumeReceivedFrame`、
  `StopReceiveDeflectFrame`、`SetFrameHitActorByBullet`、`UpdateFrameBroadcastRange`：都会改游戏帧状态机；
  AD 是被防守方，伪造帧等于自伤。
- `ForceActivateExternalActionAbilityByTag/ByClass`：绕过 `Try` 的条件检查，与 PBZPerfectDefense 的
  守卫所有权（`tl.guardOwned()`）冲突。
- 全模组**风险最高的一处写**仍是 `Shachi.BaseValue/CurrentValue = v`（`Scripts/main.lua:4470` 附近）：
  SDK 只声明字段，没有任何写担保；它靠 `tl.try` + 回读兜底，替换前必须先有 `ShachiRegen` 的只读比对。

## 6. 已落地的门禁

`tools/test_api_contract.lua`（36 断言，进 `tools/run_all.sh` 与 CI）把三件「错了也不报错」的契约钉死：

1. `onSendFrame` 的 11 个参数顺序与 `SendDeflectFrame` 一致（2/3 位命名为 `bullet`/`rotation` 供调试探针读，其余非 SDK 位必须是占位符）；
2. `tl.BULLET_TYPES` 的 0..5 名称与 `EDeflectBulletType` 枚举一致；
3. `GetNearestValidReceivedFrame` 仍是 5 参，角度 360.0、当前 handle 哨兵 `-1`。

## 7. 三条建议已落地（只读优先，待实机确认）

| # | 实现 | 代码位置 | 判据 / 仍需实机确认的部分 |
|---|---|---|---|
| 1 | 帧时间真值探针：DEBUG 下每个招式类读一次 `SendFrameTimes` / `PreHitPointDuration`，与 `hit_times.txt`+`ad_data.lua` 的时间线逐项相减，输出 `TMR … -> same clock / constant offset / count differs / differs` | `Scripts/main.lua` 的 `tl.tmrNums/tmrProbe`，由帧扫描（`tl.probeFrames`）在源招式首次出现时调用 | 单位（动作秒 vs 帧号）仍未证实：`constant offset` 才说明两套时钟可换算，`differs` 说明不能直接替换学习表 |
| 2 | `IsHolding(IA_Deflect)` / `GetHoldTime` 接在 `deflectKeyHeld()` 之前，键判保留为回落 | 新模块 `Scripts/ad_inputstate.lua`（读取器注入、可离线测）+ `tl.holdAsk(keyHeld, pawn)` | 组件字段名 `SGameInput` 是否可读、`IsHolding` 是否把注入算作按住——探针行 `deflect hold: game=… keys=… -> …`（DEBUG，每秒最多一行）直接给出差异 |
| 3 | `onSendFrame` 第 2/3 参数命名并在 DEBUG 下打印类型与 `AttackRotation.Yaw` 范围 | `tl.probeSend`（前 3 次 + 每 600 次一行 `SENDARGS …`），契约由 `tools/test_api_contract.lua` 钉住 | `yawrange` 的实际读数（是否 0..360、是否随朝向变化）决定下一轮能否用它判定「背对 / 绕后」 |

> 三条都只读，不改决策：游戏答不上来（无组件、无字段、调用抛错、返回非布尔）一律返回 nil 并走原键判，
> 每种原因只记一行日志。`LEARN` + `learned_hits.txt` 的退役与 `IsHolding` 的全面采信都保持「有证据再改」的状态。

### 7.1 首次实机读数（2026-11-18 04:50–04:59，`debug=on`）

会话事实：`loaded v1.6.4`、`runtime: Lua 5.4 / no JIT`、`tl api: 26 public names of 249 fields`、
26,926 ticks、`results: mod deflect Perfect 51, you deflect Perfect 6`。

| # | 读数 | 为什么它答不了问题 | 已做的修正 |
|---|---|---|---|
| 1 | `TMR` **1 行**：`LGAAction_DurationBulletWithDeflect frames=[0.000] prehit=0.300 timeline=[] … -> not in the timeline`；同一局 66 条 `FRAME+` 的 `src=` **全部**是这一个类 | 帧扫描拿到的 `SourceAction` 是 LGA 动作包装类，不是 timeline 的键（`GA_*`/montage 名），判词必然落到 `not in the timeline` | 探针改在 `onActivate` 里对激活的敌人招式调用（那里同时有 `GA_*` 名与 `SendFrameTimes`），每局最多 40 个类 |
| 2 | `deflect hold` **0 行**、`input state unavailable` **0 行** | 模块装上且没报失败，但「一致时不打日志」让「游戏答不上来」与「答案和键判一致」同形 | 前 3 次回答无论是否一致都打一行；5 s 的 `metrics:` 行加 `hold=known/asks` |
| 3 | `SENDARGS` **0 行**、`attack seen` **0 行**、`attacks_log` 里 `SEND ` **0 行**，而同局的 `FRAME+` 有 66 行 | 探针原本在「自家 component 早退」之后，整局都没走到——看起来和「hook 没触发」一模一样 | 探针移到函数第一行（契约测试钉住位置），并加 `own/enemy` 计数，经 `metrics: … send=n/enemy` 暴露 |

> 结论：三条**仍未取得实机结论**，需要重启游戏用当前构建再跑一局（`debug=on`）。
> 这一轮的收获不是 SDK 行为，而是「探针会沉默」：没调用、被门挡住、答案一致，三种沉默必须能被日志区分开。

### 7.2 第二次实机（2026-11-18 05:15:54–05:17:36，探针可见性修复后）

同样的 `debug=on`，这次三条探针都有输出，其中两条直接给出了结论：

| # | 读数 | 结论 |
|---|---|---|
| 3 | `SENDARGS n=1 own=0 enemy=0 bullet=userdata:BP_Bullet_BaiheDisciple_FishingNet_Grenade_C rotation=userdata yaw=0.00 yawrange=0.0..0.0 kinds=userdata:BP_Bullet_…Grenade_C`（n=2、3 同理） | **参数类型确认**：`bullet` 是对象 userdata（`:GetClass()` 读得到具体 `BP_Bullet_*` 类），`rotation` 是 userdata 但四次读法全得 `0.00` —— 三个样本都是弹丸/延迟弹反类攻击，方向不在这条参数上。`own=0 enemy=2`：本模组自家 component 一次都没走这条 hook，之前「早退挡住探针」的猜测**未被证实**，真正的原因是探针位置在日志点之后。 |
| 2 | `deflect hold: game=false keys=false -> false (game, held -1.00s)` ×3；`metrics: … hold=1450/1450` | **`SGameInput.IsHolding(IA_Deflect)` 可读、有答案**：组件字段名正确，返回值是布尔，`GetHoldTime` 未按住时给 `-1`。1450 次提问全部拿到游戏答案（`known==asks`）。仍缺「`IsHolding` 是否看见本模组注入」的证据：需要一次**注入窗口内**的采样。 |
| 1 | `TMR GA_…_C frames=[] prehit=? -> frames unreadable` ×8（另 1 行仍是 `LGAAction_*`） | **招式对象上没有这些字段**：`SendFrameTimes`/`PreHitPointDuration` 不在 `GA_*` 上。这与 SDK 声明一致（见 7.3），不是游戏行为问题。 |

### 7.3 静态结论：时间点在 action 上，不在 ability 上

`sdk/types/generated/PBZDeflectSystem.d.ts` 的 `LGAAction_DurationBulletWithDeflectBase`（`data.SourceAction` 的运行时类
`LGAAction_DurationBulletWithDeflect` 正是它）声明了全部时间字段：

```
PreHitPointDuration, RuntimePreHitPointDuration: number
SendFrameTimes, StartBulletTimes, EndBulletTimes: TArray<number>
BulletDuration: number, BulletRepetitions: number
DeflectBulletType: EDeflectBulletType
AttackDirection: Rotator, DeflectRadius/Angle/Knockback: number
CounterAbility: Class, Bullets: TArray<BulletInterface>
GetEffectiveBulletData();  $Static.GetTimes(Array, ElapsedTime, Next, End, $Ref<TArray<number>>)
```

而 `DeflectReceiveFrame`（帧扫描读到的那张表）**没有** `AttackDirection`，只有 `DeflectSendFrame` 有——
所以「`rotation` 的 Yaw 总是 0」与「方向要从 action 取」是同一件事。

据此把探针改成 `ACTN` 行（`tl.tmrAction`）：读 `SendFrameTimes/StartBulletTimes/EndBulletTimes`、
`Pre/RuntimePreHitPointDuration`、`BulletDuration/Repetitions`、`AttackDirection.Yaw`，
并沿 Outer 链找第一个等于 timeline 键的外层类，把该 action 的时间数组与 `hit_times.txt` 逐项比较，
判词与 `TMR` 相同。动作发送期间数组才填值，所以每局最多 8 个 action 会在首帧到达 0.6 s 后二次读取。
这一条真正要回答的问题是：**`hit_times.txt` 能否退役**（若 `same clock`/`constant offset` 成立即可）。

