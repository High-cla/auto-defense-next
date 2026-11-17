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
| `SendFrameTimes / StartBulletTimes / EndBulletTimes` | PBZDeflectSystem.d.ts:173-175 | `data/ad_data.lua` + `hit_times.txt` + `learned_hits.txt` 的离线学习（运行时真值） | 数组单位（动作秒 vs 帧号）未验证 |
| `PreHitPointDuration / RuntimePreHitPointDuration` | :169-170 | parry lead 的「45% 猜测」换成真值 | 两字段差异需实机 |
| `BulletRepetitions / BulletDuration` | :167-168 | `flurry_guard`、连发判断 | 只读 |
| `SGameInputComponent.IsHolding / GetHoldTime / HoldingInputs` | SGameInputSystem.d.ts:299-302 | `IsInputKeyDown + QueryKeysMappedToAction` 反推「键还按着」 | 取法 `pawn["Ability Input Component"].SGameInput` |
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

`tools/test_api_contract.lua`（34 断言，进 `tools/run_all.sh` 与 CI）把三件「错了也不报错」的契约钉死：

1. `onSendFrame` 的 11 个参数顺序与 `SendDeflectFrame` 一致（占位符必须落在 2/3/4/5/8/9 位）；
2. `tl.BULLET_TYPES` 的 0..5 名称与 `EDeflectBulletType` 枚举一致；
3. `GetNearestValidReceivedFrame` 仍是 5 参，角度 360.0、当前 handle 哨兵 `-1`。

## 7. 待决定（尚未实施，纯建议）

| # | 建议 | 收益 | 成本/风险 | 验证方法 |
|---|---|---|---|---|
| 1 | 运行时的帧时间探针：读 `SendFrameTimes / PreHitPointDuration` 与 `data/ad_data.lua` 逐条比对 | 若吻合，`LEARN` + `learned_hits.txt` 这套子系统可退役（本仓库最大复杂度来源之一） | 只读探针，低风险；需要一局实机 | 探针日志与 `hit_times.txt` 对齐率 |
| 2 | 用 `SGameInputComponent.IsHolding(IA_Deflect) / GetHoldTime` 替换按键推断 | 收尾准确性（`releaseHeldKey/standDown`） | 只读替换，但要先对比一周 ledger | 两种来源在同一局的差异计数 |
| 3 | `Debug` 时打印 `Bullet` 与 `AttackRotation.Yaw` 的实际类型/范围 | 让参数错位一眼可辨（第 6 节已挡顺序，类型仍未验证） | 只改 DEBUG 日志 | 实机日志抽样 |

> 三条都需要实机数据才能判定，按「先度量后优化」的原则留给下一轮；当前代码**未采用任何新增 SDK 符号**
> （`grep -n 'IsHolding|GetHoldTime|SendFrameTimes|PreHitPointDuration|SGameInput|GetSelfResultData' Scripts/*.lua` = 0 命中）。
