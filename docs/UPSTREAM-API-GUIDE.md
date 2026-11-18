# 上游 API 与集成参考（UE4SS / PBZModLoader / USMAP）


## 完整开发文档索引

此前版本仅概述了三个上游项目和本轮代码变更。详细 API 参考现已拆分成独立手册，建议按“UE4SS 运行时 → PBZ 游戏 API → USMAP 反射工具 → 优化路线图”的顺序阅读。

| 文档 | 内容 | 适用场景 |
|---|---|---|
| [UE4SS Lua API 实战参考](UE4SS-LUA-API-REFERENCE.md) | 模组生命周期、UObject 查询与缓存、RemoteUnrealParam、FName、Delayed Actions、EngineTick、RegisterHook、TArray/TMap、输入与性能反模式 | 开发和维护当前 Lua 模组 |
| [PBZ 游戏反射 API 参考](PBZ-GAME-API-REFERENCE.md) | DeflectComponent、Receive/Send frames、DeflectResultData、AbilityInputComponent、Enhanced Input、PBZModLoader SDK 验证等级、Lua/JS 对照 | 查找游戏类和战斗/输入 API |
| [PBZ USMAP 工具链指南](PBZ-USMAP-TOOLCHAIN.md) | Live/Offline dump、PBZ 特殊反射布局、USMAP v4/CEXT/PPTH/EATR、合并优先级、质量检查、build.ps1 和排错 | 游戏更新、反射采集和 schema 核验 |
| [PBZ SDK 与反射资源索引](PBZ-SDK-RESOURCES.md) | 区分 PBZ USMAP、PBZModLoader TypeScript Game API SDK、UE4SS C++ SDK Generator；包含 developer ZIP 下载和安装方法 | 为 Lua/TS/C++ MOD 选择正确的 API 类型资源 |
| [API 优化路线图](API-OPTIMIZATION-ROADMAP.md) | 当前代码 API 映射、已完成优化、候选 API、风险等级、性能 A/B 方法和实机验收标准 | 决定下一项性能/稳定性改进 |

## 工程开发手册 / Engineering guides

下列 P0 文档描述项目自身的实现与维护方式，与上游 API 字典互补：

| 文档 | 内容 | 适用场景 |
|---|---|---|
| [项目架构](ARCHITECTURE.md) | 系统边界、模块关系、初始化顺序、每帧数据流、决策/副作用边界、持久化映射 | 初次接手项目或修改模块边界 |
| [防守状态机](DEFLECT-STATE-MACHINE.md) | ReceiveFrame 候选、红招先闪避、普通命中弹反、时间轴闪避、guard hold/release 和状态清理 | 修改命中判定、时机、输入优先级 |
| [运行时生命周期](RUNTIME-LIFECYCLE.md) | 主循环调度、Delayed Actions、Hook 注册与当前注销缺口、Pawn/组件寿命、暂停恢复和错误隔离 | 排查循环、Hook、对象失效和重载问题 |
| [配置参考](CONFIGURATION-REFERENCE.md) | 46 个字段的中英说明、类型、默认值、取值范围、生效时机、持久化和 TXT→JSON 迁移 | 修改配置 schema 或排查设置未生效 |

推荐先读项目架构，再读防守状态机和运行时生命周期；需要更改菜单或 JSON 时，配合配置参考与 [MENU-INTEGRATION.md](MENU-INTEGRATION.md)。

## 推荐阅读路径

1. 先读 [UE4SS Lua API 实战参考](UE4SS-LUA-API-REFERENCE.md)，理解当前运行时的对象、线程和 Hook 语义。
2. 再读 [PBZ 游戏反射 API 参考](PBZ-GAME-API-REFERENCE.md)，定位 DeflectComponent、AbilityInputComponent 和 SDK 的真实验证等级。
3. 游戏更新或查字段时使用 [PBZ USMAP 工具链指南](PBZ-USMAP-TOOLCHAIN.md) 核对 native/live/package 映射。
4. 开始改代码前查看 [API 优化路线图](API-OPTIMIZATION-ROADMAP.md)，避免把未经实测的 Force/Input/Out 参数写入热路径。

### API 变更的证据规则

- UE4SS 文档用于确认框架提供的 Lua API、生命周期和调度行为。
- PBZModLoader SDK 用于读取当前捕获游戏 build 的类和函数声明；必须看 reflection-generated / binding-confirmed / call-verified 的状态注释。
- PBZ USMAP 用于核对映射结构、字段类型和来源覆盖，不证明 UE4SS Lua 能调用某个函数。
- 最终集成仍要通过离线测试、Lua binding 探针、实机战斗验证和性能 A/B。


本文记录 PBZ Auto Defense 对照以下三个上游仓库后采用的接口边界、性能策略和验证限制。文档以 2026-11-17 可读取的 `release` / `main` 分支为参考；上游更新后应重新核对函数签名与游戏构建号。

## 结论：当前运行时仍使用 UE4SS Lua

PBZ Auto Defense 的防守决策、输入、hook 和 Mods Menu 配置都运行在 UE4SS Lua 状态中。PBZModLoader 是另一套运行时：在游戏自己的脚本引擎中运行 JavaScript/TypeScript 编译产物，提供 `ue` 与 `puerts` 模块。它不是 UE4SS Lua API 的替代函数库，不能把 PBZModLoader 的 TypeScript 声明直接 `require` 到 Lua 模组中。

因此本轮采取的策略是：

- 在 Lua 当前运行时内使用 UE4SS 已公开且版本可探测的调度、对象查询和 hook API。
- 用 PBZModLoader 的反射 SDK 对游戏类、属性和函数签名做交叉核对，不把“生成了类型声明”误当成“函数已经通过实机调用验证”。
- 用 PBZ USMAP 工具辅助核对当前游戏构建的反射布局；不把外部进程读取工具或映射文件作为模组运行时依赖。
- 不为追求 API 数量而迁移整个模组到 JavaScript，也不把未经验证的参数/输出结构写入防守热路径。

## 1. UE4SS Lua API：当前代码采用的方式

上游：[KintaroModding/ue4ss](https://github.com/KintaroModding/ue4ss)

### 1.1 主循环按 EngineTick 调度

UE4SS 的 Delayed Actions API 提供：

- `LoopInGameThreadAfterFrames(frames, callback)`：按帧重复，在 `EngineTickAvailable` 为 true 时可用。
- `LoopInGameThreadWithDelay(delayMs, callback)`：按毫秒间隔重复。
- `CancelDelayedAction(handle)`：取消当前模组创建的延迟动作/循环。
- `ExecuteInGameThread(callback)`：将一次性工作排到游戏线程。

防守判断采样的是游戏帧拥有的命中帧、角色组件和时间线状态，故当前主循环优先使用每 1 个 EngineTick 帧执行一次，而不是每 10 ms 触发一次定时回调。这样避免帧率低于 100 FPS 时出现同一帧被重复采样的情况，也避免游戏帧间无必要的 timer wake-up。若当前 UE4SS 构建没有 EngineTick 调度能力，或创建帧循环失败，则回退到原来的 10 ms 循环。

主循环保存延迟动作 handle；看门狗重启时先调用 `CancelDelayedAction` 取消上一个循环，再创建新循环。即使旧回调晚到，`tl.loopId` 仍会拒绝旧 generation，作为第二层保护。Toast 的 100 ms 显示轮询不参与防守决策，暂时保留毫秒调度。

```lua
local function startDefenseLoop(callback)
    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function" then
        local ok, handle = pcall(LoopInGameThreadAfterFrames, 1, callback)
        if ok and handle ~= nil then return handle, "frame" end
    end

    local ok, handle = pcall(LoopInGameThreadWithDelay, 10, callback)
    if ok and handle ~= nil then return handle, "timer" end
    return nil, "unavailable"
end
```

此片段说明选择顺序；实际实现还包含旧 handle 取消、错误隔离、generation 检查和只记录一次的 scheduler 日志。不要将 `LoopAsync` / `ExecuteAsync` 与新 Delayed Actions API 混用；上游升级指南已将旧接口标记为 deprecated。

### 1.2 UObject 查找：静态对象与实例分开

- `StaticFindObject(fullName)`：用于查找当前内存中的对象；推荐用于非实例对象，如 UClass、UFunction 和 Blueprint Function Library 的 Default Object。
- `FindFirstOf(className)`：寻找第一个非默认实例；不能用于 Default Object。
- `FindAllOf(className)`：扫描全局 UObject 数组，非常慢，不应放在每帧路径。
- `ForEachUObject(callback)`：同样属于全局对象遍历，只用于低频诊断/兜底，不应在每次防守判断时执行。
- `UObject:IsValid()`、`IsA()`、`GetFName()` 和 `GetFullName()` 用于对象有效性、类型和诊断；全量扫描中优先比较缓存的 FName，避免对每个对象构造完整名称字符串。

当前 `Scripts/ad_query.lua` 已通过 `StaticFindObject` 缓存稳定路径。无法解析 `PBZAbilityBlueprintLibrary` 时，才使用一次 `ForEachUObject` 兜底扫描。此前负查找没有缓存，组件缺失时可能反复全表扫描；现在负查找有 5 秒重试冷却，既允许稍后加载的对象被发现，也把全表扫描频率限制在低频范围。成功找到后仍缓存对象并逐次检查有效性。

玩家控制器也已在 `Scripts/main.lua` 缓存：原始 `UEHelpers.GetPlayerController` 可能每次调用都执行 `FindAllOf("PlayerController")`，主循环不应重复触发这种全局查找。不要移除有效性检查，也不要将任意过期 Pawn/Component 指针无限期缓存。

### 1.3 RegisterHook 的使用边界

`RegisterHook(functionPath, preCallback, postCallback)` 要求目标 UFunction 在安装 hook 时已经存在。对于 `/Script/` 路径，第 2 个参数是 pre 回调，第 3 个参数是 post 回调；回调的 Context 和函数参数是 `RemoteUnrealParam`，需要用 `:get()` 读取底层值。函数返回 PreId/PostId，卸载时应将两者传给 `UnregisterHook`。

因此：

- 不要在目标 UFunction 尚未加载时假设 hook 已成功安装；必要时等到类/对象出现后重试。
- 保存 hook ID，并让卸载/重载路径可执行 `UnregisterHook`。
- hook 回调中避免无界对象扫描、文件 IO 和重计算；只捕获必要状态或入队延后处理。
- nil 返回值不覆盖原函数返回值；除非有明确、经过验证的理由，不通过 hook 修改游戏函数的返回值。

### 1.4 USMAP 导出入口

UE4SS 提供 `DumpUSMAP(includeBlueprintTypes)`。传入 `false` 只导出 native 类型；默认/true 还包括 Blueprint 类、结构和枚举。PBZ 当前游戏分支有特殊的 UE5.7 反射布局和历史 enum 边界问题，生成完整映射时应同时参考下节的 PBZ 专用工具说明，不能把普通游戏的固定偏移照搬过来。

## 2. Phantom Blade Zero USMAP 工具链

上游：[KintaroModding/phantombladezero_pbzusmap](https://github.com/KintaroModding/phantombladezero_pbzusmap)

这个仓库提供的是开发期反射映射工具，不是 Lua/JavaScript 游戏 API：

- `usmap_io.py` 读写 usmap v4，并处理 CEXT、PPTH、EATR 扩展；支持读取 v0–v4。
- `usmap_live.py` 从正在运行的游戏进程读取已加载类型，输出 Blueprint 类型和 native 类型。其进程访问权限是 `PROCESS_VM_READ` / `PROCESS_QUERY_INFORMATION`，用途为只读采集。
- `usmap_offline` 使用 CUE4Parse 从游戏包中提取 class/struct/enum；`usmap_offline.py` 转成 mapping；`usmap_merge.py` 合并 native、live 和 package mappings；`usmap_quality.py` 比较覆盖和一致性。
- 游戏的 UStruct/FField 布局与通用 UE5.7 模板不同；对象数组和 FName block 地址也会随游戏构建变化。工具通过当前 EXE 的签名与数据定位，不应把某个 build 的绝对地址写入模组。
- 构建完整映射需要 Windows、Python、.NET 10 SDK、游戏 Paks、AES key 和 Oodle；仅运行已有模组不需要这些工具。

在 PBZ Auto Defense 的工作流里，USMAP 主要用于确认 `DeflectComponent`、Gameplay Ability、Blueprint 属性和字段类型，辅助更新 `data/ad_data.lua` 或排查游戏更新后的反射差异。除非某个运行时功能确实需要映射文件，否则不把 `.usmap`、外部进程扫描器或 AES key 打进 release ZIP。

## 3. PBZModLoader 的 JavaScript/TypeScript API

上游：[KintaroModding/phantombladezero_pbzmodloader](https://github.com/KintaroModding/phantombladezero_pbzmodloader)

PBZModLoader 在游戏自身脚本引擎中运行 `main.js`，模块入口包括 `require('ue')`、`require('puerts')` 和 `require('Library/TsHelper')`。它的 `@pbz-mod-loader/game-api` 包是 TypeScript 类型声明，不包含运行时代码；发布时要发布编译后的 JS 模组，而不是把 SDK 类型包当作 runtime。

该分支的 SDK README 标示 0.3.3，目标为 Steam Win64 `CL-302256_JKS-17280`（本模组数据快照对应 build 26367565）。生成声明可以提供补全和静态检查，但声明状态可能只是 `reflection-generated`，不代表函数已单独进行运行时调用验证。使用前应查看 `sdk/api-surface.json`、`sdk/binding-support-verification.json` 和目标声明顶部的验证注释。

### 与当前防守组件有关的反射签名

`sdk/types/generated/PBZDeflectSystem.d.ts` 声明了：

```ts
GetNearestValidReceivedFrame(
  DeflectAngle: number,
  MaxPreimpactTime: number,
  IsDodge: boolean,
  CurrentHandle: number,
  OutFrame: $Ref<UE.DeflectReceiveFrame>
): number;
```

`DeflectReceiveFrame` 声明字段包括 `HitGameTime`、`IsDodge`、`IsHit`、`SourceAction`、`Bullet`、`DeflectStrength`、`DeflectDirection` 和 `CounterAbility`。这与当前 Lua 路径调用的函数名称和参数顺序吻合，是有价值的反射交叉核对；但该类型文件将组件和方法标为 reflection-generated、not individually call-tested。它不能证明 PuerTS 的 out-reference 写回行为、Lua 的 `{}` 参数写回行为，或不同游戏构建的参数布局都相同。

当前 Lua 代码没有读取 out-frame 结构，靠函数返回的 handle 和 MaxPreimpactTime 窗口作决定。此前审计已将复用 out-table 标为待验证事项；在受控实机实验确认引擎不会累积/复用旧数据之前，不应为了减少分配而复用同一个输出表。

### 何时考虑移植

如果未来要另做 PBZModLoader 后端，应从上游 `templates/ts-mod/` 开始，严格使用 SDK 指定的 `ue` / `puerts` 环境，并实现与 Lua 版本隔离的独立 mod entry。热重载前导出并完成 `stop()`，取消本模组创建的定时器和事件订阅。不可把 TypeScript 声明导入现有 Lua mod，也不可假设所有反射生成方法在运行时都已验证。

## 4. 当前实现和验证状态

本次依据上述文档完成的代码变更：

1. **主循环帧同步**：若 `EngineTickAvailable` 且 `LoopInGameThreadAfterFrames` 可用，使用 `LoopInGameThreadAfterFrames(1, callback)`；否则回退到 `LoopInGameThreadWithDelay(10, callback)`。
2. **循环生命周期**：保存延迟动作 handle；看门狗重启时使用 `CancelDelayedAction(handle)` 取消旧循环，并保留 `tl.loopId` generation 检查。
3. **低频全表扫描**：`ad_query.tagLibrary()` 在负查找后进入 5 秒冷却，防止全局 UObject 扫描反复进入高频路径；缓存成功结果并周期重试，以兼容迟加载对象。
4. **回归测试**：添加 query 负缓存测试；集成测试覆盖 frame scheduler、10 ms fallback 和旧 handle cancel。

当前测试均为离线桩测试。它们不能证明实际游戏中 EngineTick 可用、每帧回调抖动、游戏线程帧预算或 hook 行为。实机验收时建议在相同场景对比 `perf=on` 的 tick p50/p95/p99、帧数与 decision ledger；先确认无防守行为回归，再评估性能差异。若 EngineTick 不可用，日志应出现 `10 ms compatibility timer`；若可用，应出现 `EngineTick, every 1 frame`。

## 上游原始文档

### UE4SS

- [Delayed Actions](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/delayedactions.md)
- [ExecuteInGameThread](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/executeingamethread.md)
- [StaticFindObject](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/staticfindobject.md)
- [FindFirstOf](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/findfirstof.md)
- [FindAllOf performance notes](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/findallof.md)
- [RegisterHook](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/registerhook.md)
- [UnregisterHook](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/unregisterhook.md)
- [DumpUSMAP](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/dumpusmap.md)

### PBZModLoader

- [Loader README / mod author guide](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/README.md)
- [Game API SDK README](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/README.md)
- [DeflectSystem declarations](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/types/generated/PBZDeflectSystem.d.ts)
- [Binding support verification](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/binding-support-verification.json)

### PBZ USMAP

- [Developer README](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/README.md)
- [USMAP reader/writer](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/src/usmap_io.py)
- [Live process mapping reader](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/src/usmap_live.py)
