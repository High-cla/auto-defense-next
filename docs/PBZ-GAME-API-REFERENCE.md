# Phantom Blade Zero 游戏反射 API 参考

> 本文基于 PBZModLoader SDK 的反射声明、运行时验证清单和当前 PBZ Auto Defense Lua 调用整理。重点是说明“有哪些游戏 API、签名是什么、如何验证”，不是把反射声明全部视为可安全调用的承诺。

## 1. 三套工具与运行时的边界

| 项目 | 作用 | 当前模组中的角色 |
|---|---|---|
| UE4SS | UE4/5 注入式框架，提供 Lua API、UObject 访问、Hook、游戏线程执行 | 当前运行时 |
| PBZModLoader | 在游戏脚本引擎中运行 JavaScript MOD；提供 TypeScript SDK | 反射/类型参考；未来可独立做 JS 后端 |
| PBZ USMAP | 生成、读取、合并 PBZ 专用 Unreal Mapping 文件 | 开发期反射采集和 schema 核对 |

PBZModLoader 的 ue、puerts 模块不能直接从 UE4SS Lua 中调用。SDK TypeScript 声明也不是 Lua 库。PBZ USMAP 是反射数据格式和采集工具，不是运行时战斗 API。

SDK 的完整下载入口、离线 npm 安装方法、UE4SS C++ SDK Generator 与 USMAP 的区别，见 [PBZ SDK 与反射资源索引](PBZ-SDK-RESOURCES.md)。当前 0.3.3 类型声明随 PBZModLoader developer ZIP 提供，不能用玩家版 win64 ZIP 代替。

## 2. SDK 版本、覆盖和验证等级

当前可读的 PBZModLoader SDK README 标示版本 0.3.3，目标 Steam Win64 游戏构建为 CL-302256_JKS-17280，引擎版本 5.7.4-302256+b7c82f11b864，EXE SHA-256：

~~~text
4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423
~~~

该 SDK 报告的覆盖统计：

| 指标 | 数量 |
|---|---:|
| 总类型 | 34,593 |
| Native / Asset 类型 | 18,457 / 16,136 |
| Class / Struct / Enum | 22,921 / 8,419 / 3,253 |
| 函数 / 属性声明 | 49,386 / 119,282 |
| omitted entries | 5,425 |
| unresolved properties | 55 |
| excluded types | 377 |

这些数字是当前捕获集合，不代表所有游戏资产、未加载 Blueprint、未反射 C++ 函数或所有运行时状态都已覆盖。当前 Auto Defense 的数据快照标识为 Steam build 26367565；不要把 build number 与 CL build 字符串混为一谈。

### 2.1 三种验证等级

| 状态 | 准确含义 | 可接受用途 |
|---|---|---|
| reflection-generated | 从捕获的反射元数据生成签名 | 搜索成员、核对参数和字段类型 |
| binding-confirmed | 代表性成员在运行时解析到 binding | 可确认绑定存在，尚不能保证调用正确 |
| call-verified | 在记录的 build/地图/状态完成调用并检查结果 | 在相同前置条件下谨慎采用 |

PBZDeflectSystem.d.ts 和 SGameInputSystem.d.ts 中的游戏专用类大多标注 reflection-generated, not individually call-tested。TypeScript 能编译通过不等于游戏函数已被成功调用。

SDK 记录的代表性运行时验证包括 Vector 构造、KismetMathLibrary.BreakVector、Add_Int64Int64、容器访问、native class、soft class、Blueprint 和 enum。一次生成 API 探针记录 10 项检查通过，但测试发生在 PBZ_Fujizhilin_WP 地图的菜单 UI 状态；不代表战斗和地图切换已验证。

SDK 还记录了排除项：
- Controller.GetPawn 在探针中返回 pc.GetPawn is not a function；使用 GameplayStatics.GetPlayerPawn(context, index)。
- 全局 Cast 未定义，不能假设 PuerTS 暴露了 UE C++ Cast。
- 只验证 NewObject(Class) 一个参数的形式；不要猜构造参数。
- 55 个 unresolved properties 不应改成 any。其中存在 getter/setter 已绑定但读取仍为 undefined 的 Optional/字符串属性。

### 2.2 查找类型与证据

按这个顺序查 API：
1. sdk/type-index.json：完整反射路径映射到声明文件、符号和验证状态。
2. sdk/types/generated/<Module>.d.ts：具体成员签名。
3. 声明顶部注释：是否单独测试过。
4. sdk/api-surface.json：SDK 覆盖与运行时验证状态。
5. sdk/binding-support-verification.json：字段和 binding 探针的证据。
6. scripts/sdk-supplemental.json：人工补充的已验证子集与限制。

---

## 3. DeflectComponent：自动防守核心 API

来源：sdk/types/generated/PBZDeflectSystem.d.ts

### 3.1 属性表

| 属性 | 反射类型 | 含义/使用注意 |
|---|---|---|
| SendFrames | TMap<number, DeflectSendFrame> | 当前发送的防御帧 |
| ReceiveFrames | TMap<number, DeflectReceiveFrame> | 接收的命中/防御帧 |
| ProbChannels | TArray<EObjectTypeQuery> | 查询过滤通道 |
| IgnoreAngleDistance | number | 角度/距离过滤参数 |
| PerfectDodgeResultData | DeflectResultData | 完美闪避结果信息 |
| PoolSubsystem | ObjectPoolSubsystem? | 对象池 |
| AbilitySystem | AbilitySystemComponent? | GAS 能力系统 |
| FactionComponent | FactionComponent? | 阵营组件 |
| LocomotionDriver | LocomotionDriverComponent? | 移动驱动组件 |
| CounterAbilityGrants | TMap<Class?, DeflectCounterAbilityGrant> | 反击能力授予状态 |

这些是反射到的字段，不表示每个字段都可安全写入。特别是与能力、帧广播和反击能力授予相关的字段，不应被当成普通配置变量修改。

### 3.2 关键方法签名

~~~ts
interface DeflectComponent {
  ConsumeReceivedFrame(Handle: number): void;
  FindSendFrame(
    Handle: number,
    OutFrame: $Ref<DeflectSendFrame>
  ): boolean;
  FindSendFrameForBullet(
    Bullet: BulletInterface | null,
    OutFrame: $Ref<DeflectSendFrame>
  ): number;
  GetNearestValidReceivedFrame(
    DeflectAngle: number,
    MaxPreimpactTime: number,
    IsDodge: boolean,
    CurrentHandle: number,
    OutFrame: $Ref<DeflectReceiveFrame>
  ): number;
  GetSelfResultData(
    Handle: number,
    DeflectResult: GameplayTag,
    OutResultData: $Ref<DeflectResultData>
  ): void;
  PauseSendFrame(Handle: number): void;
  ResumeSendFrame(Handle: number): void;
  StopReceiveDeflectFrame(Handle: number, Consume: boolean): void;
  StopSendDeflectFrame(Handle: number, Consume: boolean): void;
}
~~~

GetNearestValidReceivedFrame 是当前模组最重要的游戏查询。SDK 的函数名、参数顺序与当前 Lua 调用吻合：

~~~lua
local handle = deflect:GetNearestValidReceivedFrame(
    360.0,  -- DeflectAngle
    window, -- MaxPreimpactTime
    isDodge,
    -1      -- CurrentHandle
)
~~~

当前 Lua 路径只依赖返回的 handle（`>= 0` 即有效）与查询窗口，第 5 个实参 OutFrame 不传：SDK 的 $Ref<DeflectReceiveFrame> 是 PuerTS 参数引用，UE4SS Lua 里读不回来。

**OutFrame 风险：** 在确认 Lua binding 每次调用都会完整覆盖输出字段、失败时的清空语义、table 转换成本之前，不应复用同一表，也不应把上次结果当作本次结果。减少分配必须通过受控 A/B 测试证明，不可臆测。

### 3.3 Deflect 数据结构

~~~ts
interface DeflectReceiveFrame {
  SourceAction: LGAAction | null;
  Bullet: BulletInterface | null;
  DeflectStrength: GameplayTag;
  DeflectDirection: GameplayTag;
  DeflectKnockback: number;
  HitGameTime: number;
  IsDodge: boolean;
  IsHit: boolean;
  CounterAbility: Class | null;
}
~~~

~~~ts
interface DeflectSendFrame {
  SourceAction: LGAAction | null;
  Bullet: BulletInterface | null;
  AttackDirection: Rotator;
  DeflectStrength: GameplayTag;
  DeflectDirection: GameplayTag;
  DeflectRadius: number;
  DeflectAngle: number;
  DeflectKnockback: number;
  HitGameTime: number;
  IsDodge: boolean;
  CounterAbility: Class | null;
  Receivers: TArray<Actor | null>;
  IgnoredActors: TArray<Actor | null>;
  CurrentHitActor: Actor | null;
  Paused: boolean;
}
~~~

~~~ts
interface DeflectResultData {
  SourceAction: LGAAction | null;
  SourceBullet: BulletInterface | null;
  SourceAvatar: Actor | null;
  DefenderAvatar: Actor | null;
  DeflectStrength: GameplayTag;
  DeflectDirection: GameplayTag;
  DeflectResult: GameplayTag;
  DeflectKnockback: number;
  HitGameTime: number;
  IsHit: boolean;
  CounterAbility: Class | null;
}
~~~

这些字段可以指导未来 ledger 归因探针，但均不能因为 TypeScript 声明存在就直接认定 Lua wrapper 可以读到同样的结构。

### 3.4 其他 Deflect 方法的风险

| 方法 | 用途候选 | 风险 |
|---|---|---|
| ConsumeReceivedFrame(handle) | 消费接收帧 | 会改变游戏帧状态 |
| FindSendFrame(handle, out) | 查发送帧 | Out 参数待验证 |
| FindSendFrameForBullet(bullet, out) | 从弹体反查发送帧 | 参数/Out 映射待验证 |
| GetSelfResultData(handle, tag, out) | 读防守者结果 | 可用于 ledger 探针，但 out 参数未验证 |
| PauseSendFrame / ResumeSendFrame | 暂停/恢复帧 | 会改变游戏逻辑状态 |
| SendDeflectFrame | 主动发送防御帧 | 高风险，不应仅凭声明调用 |
| StopReceiveDeflectFrame / StopSendDeflectFrame | 终止帧 | 可能破坏游戏帧生命周期 |

建议先读 ReceiveFrames 与查询返回值；涉及创建、暂停、停止、消费帧的函数必须单独验证，不要放到自动防御默认路径。

---

## 4. AbilityInputComponent：能力输入状态与触发候选

来源：sdk/types/generated/SGameInputSystem.d.ts

### 4.1 属性和方法签名

~~~ts
interface AbilityInputComponent {
  SGameInput: SGameInputComponent | null;
  AbilitySystem: AbilitySystemComponent | null;
  Controller: PlayerController | null;

  ValidBufferInputs: TArray<InputAction | null>;
  InputSets: TMap<GameplayTag, InputSet | null>;
  InputBindings: TMap<InputAction | null, SortedInputBindingList>;
  CurrentInputSets: TArray<RuntimeInputSet>;

  InActionPhase: boolean;
  ActionPhase: GameplayTag;
  OnInputFailed: MulticastDelegate<(InputAction: InputAction | null) => void>;

  CanActivateExternalActionAbility(ActionPriority: number): boolean;
  EnableInputBuffer(Refresh: boolean): void;

  ForceActivateExternalActionAbilityByClass(
    Class: Class | null, InputAction: InputAction | null, ActionPriority: number
  ): boolean;
  ForceActivateExternalActionAbilityByClassWithEvent(
    Class: Class | null, InputAction: InputAction | null,
    ActionPriority: number, EventData: GameplayEventData
  ): boolean;
  ForceActivateExternalActionAbilityByTag(
    AbilityTag: GameplayTag, InputAction: InputAction | null,
    ActionPriority: number
  ): boolean;

  TryActivateExternalActionAbilityByClass(
    Class: Class | null, InputAction: InputAction | null, ActionPriority: number
  ): boolean;
  TryActivateExternalActionAbilityByTag(
    AbilityTag: GameplayTag, InputAction: InputAction | null, ActionPriority: number
  ): boolean;
  TryActivateExternalActionAbilityInterruptLowerByTag(
    AbilityTag: GameplayTag, InputAction: InputAction | null,
    ActionPriority: number
  ): boolean;

  GetOffsetTags(): GameplayTagContainer;
  OnRestarted(Pawn: Pawn | null): void;
  PopDisableInterrupt(): void;
  PushDisableInterrupt(): void;
  RegisterActionInputBindings(Bindings: TMap<InputAction | null, InputActionBinding | null>): void;
  UnregisterActionInputBindings(Bindings: TMap<InputAction | null, InputActionBinding | null>): void;
  RemoveBufferedInputs(Inputs: TArray<InputAction | null>): void;
  StopInputBuffer(): void;
  TriggerBufferedInputs(Stop: boolean): void;
  StoreOffsetTags(Ability: GameplayAbility | null): void;
  UpdateActionPriority(Handle: GameplayAbilitySpecHandle, NewActionPriority: number): void;
  UseInputSet(InputSet: GameplayTag): void;
}
~~~

### 4.2 只读优先

InActionPhase、ActionPhase、ValidBufferInputs、CurrentInputSets 有潜力用于更可靠地判断动作锁和输入阶段；但当前声明并未提供“每一字段的时序/状态含义已通过战斗场景验证”的保证。

推荐先完成只读探针：
1. 确认对象属于当前玩家 Pawn，且切图/重生后会更新。
2. 在 idle、攻击、闪避、受击、抓投、菜单/暂停状态记录这些字段。
3. 和现有 montageState / playerBusy 结果对照。
4. 只有发现稳定且更准确的增益，才考虑将其接入决策。

### 4.3 Try 与 Force 的区别

- TryActivate... 是按正常条件尝试触发能力。
- ForceActivate... 名称表明具有强制语义。
- ...InterruptLower... 会涉及优先级更低的动作打断。
- CanActivateExternalActionAbility(priority) 是查询候选，但 priority 的取值语义必须先核对。

**不建议直接用 Force API 替换当前按键注入。** 自动触发能力可能绕过正常输入缓冲、动作取消窗口或其他 MOD 的所有权。如果要探测，必须在单独实验分支/feature flag 下执行，确认返回值、能力状态、动画和输入回执，并能立即恢复原路径。

---

## 5. Enhanced Input API

来源：sdk/types/generated/EnhancedInput.d.ts。声明中可见的候选成员包括：

| API | 用途 | 风险/前置条件 |
|---|---|---|
| EnhancedInputLibrary.GetBoundActionValue(Actor, Action) | 读取当前输入动作值 | 先确认 Actor 与 Action 来源 |
| Conv_InputActionValueToBool/Axis1D/Axis2D/Axis3D | 转换输入值 | 确认 ValueType |
| FlushPlayerInput(PlayerController) | 清空玩家输入 | 可能影响玩家/其他 MOD 的输入 |
| InjectInputForAction(Action, RawValue, Modifiers, Triggers) | 注入一次动作值 | 需正确创建 UE 容器与修饰器/触发器 |
| StartContinuousInputInjectionForAction | 持续注入 | 必须有对应 stop/cleanup，防止残留 |
| UpdateValueOfContinuousInputInjectionForAction | 更新持续注入值 | 需存在有效持续注入实例 |

这些方法标为反射生成并未逐项 call-test。尤其不要把 FlushPlayerInput 当成某次自动闪避失败后的通用恢复方法，也不要在不知道持续注入的停止语义时调用 StartContinuous。

---

## 6. PBZModLoader SDK 中已记录的基础运行时 API

api-surface.json 记录的基础成员包括：

| 模块 | 已记录成员 |
|---|---|
| GameplayStatics | GetCurrentLevelName、GetGameInstance、GetGameMode、GetGameState、GetPlayerController、GetPlayerPawn、GetPlayerCharacter、GetPlayerCameraManager、GetTimeSeconds、GetRealTimeSeconds、GetWorldDeltaSeconds、IsGamePaused |
| KismetSystemLibrary | GetObjectName、GetPathName、GetDisplayName、IsValid、GetEngineVersion、GetGameName |
| Actor | K2_GetActorLocation、K2_GetActorRotation、GetActorScale3D、GetVelocity |
| Pawn | GetController |
| GameInstance | GetWorld |
| puerts | argv.getByName、argv.getByIndex、$ref、$unref、$set |
| GameUserSettings | GetGameUserSettings、GetScreenResolution、GetFullscreenMode |

已知调用陷阱：SDK 探针确认 Controller.GetPawn() 不存在；应使用 GameplayStatics.GetPlayerPawn(GameInstance, index)。不要把 TypeScript assertion 当作运行时 cast；as SomeType 不会改变对象。

### 6.1 TypeScript 只读示例

~~~ts
import * as UE from "ue";
import { argv, $ref, $unref } from "puerts";

const gi = argv.getByName("GameInstance");
if (!gi) throw new Error("GameInstance missing");

const pawn = UE.GameplayStatics.GetPlayerPawn(gi, 0);
if (pawn && UE.KismetSystemLibrary.IsValid(pawn)) {
  const x = $ref(0);
  const y = $ref(0);
  const z = $ref(0);
  UE.KismetMathLibrary.BreakVector(
    pawn.K2_GetActorLocation(), x, y, z
  );
  console.log($unref(x), $unref(y), $unref(z));
}
~~~

PBZModLoader 的 SDK 是类型声明包，没有需要在模组中 import 的 runtime 代码；运行时应直接加载游戏的 ue 和 puerts 模块。不要加入 DOM 或 Node.js 类型。

---

## 7. Lua 与 PBZModLoader API 对照

| 功能 | UE4SS Lua | PBZModLoader JS/TS |
|---|---|---|
| 玩家 Pawn | UEHelpers/UE4SS 对象查找 | GameplayStatics.GetPlayerPawn |
| UObject 有效性 | obj:IsValid() | KismetSystemLibrary.IsValid(obj) |
| 对象路径 | GetFullName / GetFName | KismetSystemLibrary.GetPathName/GetObjectName |
| UFunction Hook | RegisterHook / UnregisterHook | 不可假定存在同名 UE4SS Hook API |
| 游戏线程回调 | ExecuteInGameThread / Delayed Actions | 应依据 loader/game runtime 自身模型 |
| out 参数 | RemoteUnrealParam 或 Lua 结构体转换（逐项验证） | PuerTS $ref / $unref |
| 容器 | UE4SS TArray/TMap userdata | 游戏原生容器对象，非 JS 数组/Map |
| 生命周期函数 | UE4SS Lua mod reload | main.js 与 stop() |

PBZModLoader 模组热重载时会调用并等待 stop()。应在 stop 中清除 interval、取消事件订阅、停止持续输入注入、取消延迟动作并释放自己创建的资源。若 stop 缺失/失败，Loader 文档说明旧实例会保留而新版本不加载。

---

## 8. PBZ Auto Defense 当前调用映射

| 功能 | 当前实现位置 | 相关 API | 结论 |
|---|---|---|---|
| 自动弹反查询 | Scripts/main.lua nearest()/tickParry | DeflectComponent.GetNearestValidReceivedFrame | 函数名/参数序列经 SDK 交叉核对 |
| 自动闪避查询 | Scripts/main.lua nearest(..., true, ...) | 同上 IsDodge 参数 | 具体游戏判定仍需实机 |
| 读取帧表 | fxScan / ReceiveFrames | DeflectComponent.ReceiveFrames | Lua wrapper 读取路径应继续验证 |
| 游戏输入组件 | Ability Input Component 属性 | AbilityInputComponent | SDK 声明存在，方法未逐项调用验证 |
| Perfect Dodge 结果 | 目前未直接消费 | PerfectDodgeResultData / DeflectResultData | 可做只读探针，不直接改字段 |
| Tag Library | ad_query.tagLibrary() | PBZ Blueprint Function Library | 静态查找 + 降频全局扫描兜底 |
| 输入执行 | ad_input + ad_policy | UE4SS 输入与游戏 Ability Input | 保持统一策略入口，不新增旁路 |

PBZ 游戏 API 与 UE4SS API 要分清：
- RegisterHook 是 UE4SS API。
- GetNearestValidReceivedFrame 是 PBZ 游戏函数。
- TryActivateExternalActionAbilityByTag 是 PBZ 游戏函数。
- RemoteUnrealParam:get() 是 UE4SS Lua wrapper 方法。
- PuerTS $ref/$unref 是 PBZModLoader JavaScript binding 机制。

---

## 9. 优化候选、收益与风险

| 候选 | 潜在收益 | 风险 | 当前建议 |
|---|---|---|---|
| 读取 InActionPhase / ActionPhase | 更精确识别动作锁，减少缓冲区误输入 | 状态时序未验证 | 先只读记录，与 montage 判断对比 |
| CanActivateExternalActionAbility | 输入前判断能力是否可触发 | priority 语义未核对 | 独立探针 |
| TryActivateExternalActionAbilityByTag | 走游戏能力输入系统 | Tag/InputAction/优先级组合未验证 | 不替换当前输入路径 |
| ForceActivateExternalActionAbilityByTag | 强制发起能力 | 可能绕过原生状态/优先级和其他 MOD | 高风险，不作为默认自动防守方案 |
| GetSelfResultData | 为 ledger 补游戏侧结果 | Out 参数和 Tag 语义待验证 | 单独验证后再考虑 |
| FindSendFrame | 发送帧归因 | Out 参数未验证 | 未使用 |
| 批量读取 ReceiveFrames | 少量查询调用合并 | 表快照/迭代与更新竞争 | 做性能与一致性 A/B |
| Enhanced Input 注入 | 使用原生 InputAction | Modifier/Trigger/持续输入清理复杂 | 不做默认迁移 |
| FlushPlayerInput | 清理输入状态 | 会影响玩家或其他 MOD | 不用作失败回滚 |

### 9.1 当前可以安全继续的优化

1. 对 Pawn/Component 查询做生命周期内缓存，每次使用前检查 IsValid；Pawn 更换时强制重建。
2. 在不改变行为的情况下记录 InActionPhase / ActionPhase 与当前 montage、输入结果的关联。
3. 只读检查 ReceiveFrames 的 ForEach 路径，比较每帧 cost 与现有按 handle 查询路径。
4. 通过游戏侧返回的 DeflectResultData 研究 ledger 归因，但先验证 Out 参数和 Tag。
5. 只对已验证的稳定对象缓存；Pawn/Component 随切图/重生重建。

### 9.2 不应直接执行

- 不复用尚未验证的 OutFrame table。
- 不将帧 handle 跨地图/角色生命周期长期缓存。
- 不把 Force API 当作按键注入的“一键升级”。
- 不用 FlushPlayerInput 解决一次 parry/dodge 没有回执。
- 不把内部 TMap/属性布局当固定内存结构。
- 不直接写 DeflectComponent 未验证字段。
- 不把 USMAP 的外部内存地址用于运行时。
- 不拿另一个游戏 build 的 SDK 覆盖当前构建的签名。

### 9.3 仍未证实的字段（2026-11-18 两次实机会话后）

下列三条**只有静态声明、没有实机读数**，用之前需要重新埋点（一次性、DEBUG 门控，不要常驻）：

- `SGameInputComponent.IsHolding / GetHoldTime` 已在实机可读（返回布尔；未按住时 `GetHoldTime` = `-1`），但**看不看见本模组的注入**还没采到样本——旧探针只在注入窗口外提问，答案必然 `false`。想确认就在 `holdAsk` 的注入窗口内打一行。
- `LGAAction_DurationBulletWithDeflectBase.SendFrameTimes / StartBulletTimes / EndBulletTimes` 的**单位**（动作秒 vs 帧号）未证实；与 `hit_times.txt` 能否对齐（`same clock` / `constant offset` / `differs`）决定学习表能否退役。
- `DeflectSendFrame.AttackDirection.Yaw` 的实际范围未采到——已观测的样本全是弹丸类，四次读法都得 `0.00`；方向要从 action 的 `AttackDirection` 取，不是从 `DeflectReceiveFrame`（它根本没有这个字段）。

> 教训：「探针会沉默」——没调用、被门挡住、答案一致三种沉默必须能在日志里区分，否则读数比没有读数更误导。

---
## 10. 游戏更新后的核对流程

1. 记录游戏 build 字符串、Steam build number、EXE SHA-256、引擎版本和 UE4SS/PBZModLoader 版本。
2. 重新采集 native/live/asset 反射数据。
3. 在 type-index.json 检索 DeflectComponent、AbilityInputComponent、相关 Ability 类和 InputAction。
4. 比较方法参数顺序、返回类型、Out 参数、属性名、父类和 nullable。
5. 标出 reflection-generated、binding-confirmed、call-verified 的差异。
6. 在 UE4SS Lua 环境单独验证 UObject 属性读取与函数调用；JS/TS 验证不能代替 Lua。
7. 先只读探测，再做单次调用，再做重复调用；最后才测试持续输入。
8. 测试蓝色/普通攻击、红攻击、黑闪、多段攻击、抓投、动作锁、菜单暂停、切图、死亡复活。
9. 用 ledger + perf 比较防守准确性、tick p50/p95/p99、hitches 与内存。
10. 保留 feature flag 和旧行为回退点。

## 上游源文件

- [PBZModLoader README](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/README.md)
- [TypeScript game API SDK README](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/README.md)
- [PBZDeflectSystem.d.ts](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/types/generated/PBZDeflectSystem.d.ts)
- [SGameInputSystem.d.ts](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/types/generated/SGameInputSystem.d.ts)
- [EnhancedInput.d.ts](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/types/generated/EnhancedInput.d.ts)
- [api-surface.json](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/api-surface.json)
- [binding-support-verification.json](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/binding-support-verification.json)
- [sdk-supplemental.json](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/scripts/sdk-supplemental.json)
