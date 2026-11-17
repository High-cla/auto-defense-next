# UE4SS Lua API 实战参考

> 适用对象：PBZ Auto Defense 的 UE4SS Lua 运行时。本文不是 UE4SS 全部 Lua API 的逐项抄录，而是围绕当前模组真正使用的对象查询、游戏线程调度、UFunction Hook、输入、容器和性能约束整理的开发手册。
>
> API 来源：KintaroModding/ue4ss 的 `release` 分支。目标 UE4SS 版本/构建必须在游戏中确认；“文档存在”不等于当前安装版本一定导出了该函数。

## 目录

1. [运行模型和模组生命周期](#1-运行模型和模组生命周期)
2. [对象查询与缓存](#2-对象查询与缓存)
3. [属性、RemoteUnrealParam 与 FName](#3-属性remoteunrealparam-与-fname)
4. [游戏线程、定时器与帧调度](#4-游戏线程定时器与帧调度)
5. [UFunction Hook 与构造通知](#5-ufunction-hook-与构造通知)
6. [数组、映射和结构体](#6-数组映射和结构体)
7. [按键绑定与输入安全](#7-按键绑定与输入安全)
8. [异常、日志和资源生命周期](#8-异常日志和资源生命周期)
9. [性能预算与常见反模式](#9-性能预算与常见反模式)
10. [PBZ Auto Defense 中的 API 对照](#10-pbz-auto-defense-中的-api-对照)
11. [升级/兼容性核对表](#11-升级兼容性核对表)

---

## 1. 运行模型和模组生命周期

UE4SS Lua MOD 是放在 UE4SS 的 Mods 目录中的 Lua 脚本，由 UE4SS 加载到游戏进程内。脚本通过 UE4SS 暴露的 Lua API 访问 Unreal 对象、属性和 UFunction。它不是 PBZModLoader 的 JavaScript 运行时，也不是普通桌面 Lua 程序。

典型结构：

```text
ue4ss/
  Mods/
    ExampleMod/
      enabled.txt
      Scripts/
        main.lua
        helper.lua
```

PBZ Auto Defense 的入口加载辅助模块，随后建立查询/策略/输入等模块边界：

```lua
local UEHelpers = require("UEHelpers")
local Q = dofile(MOD_DIR .. "Scripts/ad_query.lua")
local TL = dofile(MOD_DIR .. "Scripts/ad_timeline.lua")
local Policy = dofile(MOD_DIR .. "Scripts/ad_policy.lua")
```

开发时优先使用 `require` 管理可复用模块；本模组的文件路径/部署布局兼容既有打包结构，因此部分源文件采用 `dofile`。路径要用正斜杠或经过正确转义的 Windows 路径；Lua 字符串中的 `\a`、`\t` 等会被解释为转义字符，不能随意写裸 Windows 路径。

UE4SS 支持热重载 Lua MOD。重载前应确保旧的计时器、Hook、回调和持有的对象引用不会继续产生副作用；不要把“脚本文件被重新执行”误认为所有 UE 对象、输入状态和外部 Hook 自动清理完成。

## 2. 对象查询与缓存

### 2.1 StaticFindObject 与实例查找的区别

| API | 目标 | 典型用途 | 性能/边界 |
|---|---|---|---|
| `StaticFindObject(fullName)` | 当前内存中的任意 UObject | UClass、UFunction、CDO、Blueprint Function Library 默认对象 | 稳定对象路径适合缓存；可能返回无效对象 |
| `FindFirstOf(className)` | 首个非默认实例 | 查找某类运行时 Actor/Component | 类名是短名；不能取 Default Object |
| `FindAllOf(className)` | 全部非默认实例 | 低频诊断/枚举 | 文档明确说明很慢，会遍历全局 UObject 数组 |
| `ForEachUObject(fn)` | 全局对象集合 | 最后手段的诊断或兜底发现 | 线性遍历；不要放每帧路径 |
| `NotifyOnNewObject(classPath, fn)` | 后续新构造对象 | 在目标类尚未出现时监听加载/创建 | 可避免反复扫描；回调可返回 true 注销 |

`StaticFindObject` 的标准使用形式是不带类型前缀的完整路径：

```lua
local cdo = StaticFindObject(
    "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
)
if cdo and cdo:IsValid() then
    -- 调用已经核对过签名的只读/游戏查询函数
end
```

注意：`StaticFindObject` 是查找内存中已有的对象，不是“加载任意资产”的通用保证。资产加载有独立 API；不要仅凭路径看似正确就认为对象必然存在。

### 2.2 查找运行时实例

`FindFirstOf` / `FindAllOf` 使用类短名，例如：

```lua
local controller = FindFirstOf("PlayerController")
if controller and controller:IsValid() then
    local pawn = controller.Pawn
    if pawn and pawn:IsValid() then
        local location = pawn:K2_GetActorLocation()
    end
end
```

`FindAllOf` 是慢操作。UE4SS 文档明确指出它完整遍历全局对象数组；对象多时，不要在遍历中做大量名称转换或复杂工作。优先使用更具体的类名，能用 `FindFirstOf` 就不要用 `FindAllOf`，并将查询结果缓存到合理的生命周期内。

### 2.3 Default Object 与实例生命周期

Unreal 中常见的 CDO（Class Default Object）属于类默认模板，不是正在战斗的角色实例。查找 Blueprint Function Library 时通常应使用 `StaticFindObject("/Script/Module.Default__Library")`；查找当前玩家或敌人时才使用实例查找/已有 Actor 引用。

对每个缓存对象至少考虑：

- 每次使用前是否需要 `IsValid()`。
- 切图、重生、角色切换后对象是否会被销毁并重建。
- 缓存的是稳定 CDO、类对象，还是临时 Pawn/Component。
- 查找失败是否会每帧重试，造成昂贵的负查找循环。
- 若目标晚加载，使用低频重试或 `NotifyOnNewObject`，而不是无限频率扫描。

### 2.4 推荐缓存模式

稳定路径：缓存成功结果，失效时重新解析。

```lua
local cache = {}

local function findCached(path)
    local obj = cache[path]
    if obj ~= nil then
        local ok, valid = pcall(function() return obj:IsValid() end)
        if ok and valid then return obj end
        cache[path] = nil
    end

    local ok, found = pcall(StaticFindObject, path)
    if ok and found ~= nil then
        local okValid, valid = pcall(function() return found:IsValid() end)
        if okValid and valid then
            cache[path] = found
            return found
        end
    end
    return nil
end
```

负缓存（查找失败后的冷却）适合不常变化的对象路径，但必须留出迟加载重试策略。PBZ Auto Defense 的 `tagLibrary()` 采用 5 秒重试冷却：成功就缓存；失败后不在每个 tick 重扫全局 UObject；冷却到期再试一次。

### 2.5 NotifyOnNewObject：晚加载对象

UE4SS 的 `NotifyOnNewObject` 可在指定类实例被构造时回调，而且目标类在注册时不必已存在。回调返回 true 可移除该监听。

```lua
local found = nil
NotifyOnNewObject("/Script/Engine.PlayerController", function(obj)
    if obj and obj:IsValid() then
        found = obj
    end
    -- 一旦找到第一个满足条件的对象，就停止监听
    return found ~= nil
end)
```

不要为同一类重复注册大量独立监听；UE4SS 文档明确提醒重复注册同类通知会造成额外开销。若要对同类对象做多项初始化，集中在一个回调中。

## 3. 属性、RemoteUnrealParam 与 FName

### 3.1 UObject 属性访问

UE4SS 允许通过对象索引读取属性或 UFunction：

```lua
local component = pawn["Deflect Component"]
local abilityInput = pawn["Ability Input Component"]

if component and component:IsValid() then
    local receiveFrames = component.ReceiveFrames
end
```

PBZ 的 Blueprint 属性可能包含空格或大小写敏感的实际名称；必须使用反射/现场确认的拼写，不应根据 C++ 风格自行猜名。

`pcall` 适合用于已知会因对象生命周期/可选属性/跨版本差异失败的边界，但不要把每个普通 Lua 运算都包在 pcall 闭包中。热路径可将 getter 提取为局部函数以减少闭包创建，并在边界集中处理异常。

### 3.2 RemoteUnrealParam

UFunction Hook 的 Context 和参数可能是 `RemoteUnrealParam` 包装器，而不是原生 Lua 值。使用 `:get()` 取得底层值；如果需要写回参数，才使用 `:set(value)`。

```lua
local function readParam(param)
    if param == nil then return nil end
    local ok, value = pcall(function() return param:get() end)
    if ok then return value end
    return nil
end
```

不能默认每一个 UE4SS 参数都要 `get()`：普通属性读取、已 unwrap 的 Lua number/string、LocalUnrealParam 和 UObject 本体的语义不同。根据实际 userdata 类型和 API 文档处理。

### 3.3 FName 与名称比较

FName 是 Unreal 的名称索引对象，不等价于普通 Lua string。UE4SS 提供 `FName:ToString()` 与 `GetComparisonIndex()`。做频繁比较时，缓存要比较的 FName/ComparisonIndex，避免每帧反复转换完整名称。

```lua
local expected = FName("Default__PBZAbilityBlueprintLibrary")
local function hasExpectedName(obj)
    if not obj or not obj:IsValid() then return false end
    local name = obj:GetFName()
    return name:ToString() == expected:ToString()
end
```

如果只做低频诊断，`GetFullName()` 很方便；全局遍历中的每个对象都调用 `GetFullName()` 会产生大量字符串构造。UE4SS 的 FindAllOf 文档建议优先通过 FName 和类/父类链判断类型。

### 3.4 UObject 有效性不等于业务状态有效

`IsValid()` 只说明 UE 对象是否仍然是有效对象，不代表：
- 对象当前属于玩家而不是旧 Pawn；
- 对象处于战斗而不是菜单/暂停；
- Component 已注册/可用；
- Ability 当前允许激活；
- 输入状态没有被其他模组接管。

业务条件必须独立判定。PBZ Auto Defense 的循环在暂停/无 Pawn 时清除当前角色上下文，并每 2 秒重读一次 PBZPerfectDefense 协作状态（`tl.pd.tick` 的节流间隔），而不只依赖 UObject 有效性。

## 4. 游戏线程、定时器与帧调度

### 4.1 ExecuteInGameThread

`ExecuteInGameThread(callback)` 将一次性回调提交到游戏线程，在引擎有时间执行时运行。对于按键回调或外部上下文触发、但会读写 Unreal 对象的工作，应切换到游戏线程。

```lua
RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local pawn = player()
        if pawn and pawn:IsValid() then
            -- 这里只做已经验证的游戏对象操作
        end
    end)
end)
```

游戏线程 API 不会让耗时任务变得廉价。长时间解析、文件扫描或全对象遍历仍会阻塞游戏线程，应拆成增量任务或放到不访问 UObject 的纯 Lua 部分处理。

### 4.2 新 Delayed Actions API

UE4SS 的 Delayed Actions API 在游戏线程执行，返回当前模组所属的 handle：

| API | 语义 |
|---|---|
| `ExecuteInGameThreadWithDelay(ms, fn)` | 延迟一次执行 |
| `RetriggerableExecuteInGameThreadWithDelay(handle, ms, fn)` | 同 handle 再次触发会重置计时，适合 debounce |
| `LoopInGameThreadWithDelay(ms, fn)` | 按毫秒循环 |
| `ExecuteInGameThreadAfterFrames(n, fn)` | 延迟 n 帧执行；需要 EngineTick |
| `LoopInGameThreadAfterFrames(n, fn)` | 每 n 帧循环；需要 EngineTick |
| `MakeActionHandle()` | 创建用户管理的唯一 handle |
| `CancelDelayedAction(handle)` | 取消动作/循环 |
| `PauseDelayedAction(handle)` / `UnpauseDelayedAction(handle)` | 暂停/恢复 |
| `ResetDelayedActionTimer(handle)` / `SetDelayedActionTimer(handle, ms)` | 重置/修改时长 |
| `IsDelayedActionActive(handle)` | 查询活动状态 |
| `GetDelayedActionTimeRemaining(handle)` | 查询剩余时间 |
| `ClearAllDelayedActions()` | 清除当前 MOD 拥有的动作 |

### 4.3 EngineTick 与毫秒轮询的选择

全帧采样应优先帧调度；低频 UI/文件检查仍适合毫秒定时器。

- `EngineTickAvailable` 用于判断帧钩子是否可用。
- `LoopInGameThreadAfterFrames(1, callback)` 可建立每帧循环。
- 不可用时用 `LoopInGameThreadWithDelay(10, callback)` 等兼容路径。
- 返回的 handle 要保存；重启/替换循环前取消旧 handle。
- 仍应保留 generation/token 检查，防止已经排入队列的旧回调在切换边界执行。

不要简单把 10 ms timer 换成“每帧”便宣称提升 FPS。帧同步主要消除帧间重复采样和不必要唤醒；实际收益需要用同场景的帧间隔、p95/p99、tick 成本和 hitch 数据测量。1 帧回调仍然会消耗当前帧预算。

### 4.4 推荐生命周期模板

```lua
local loopHandle
local generation = 0

local function cancelLoop()
    local old = loopHandle
    loopHandle = nil
    if old ~= nil and type(CancelDelayedAction) == "function" then
        pcall(CancelDelayedAction, old)
    end
end

local function startLoop(tick)
    generation = generation + 1
    local id = generation
    cancelLoop()

    local function guardedTick()
        if id ~= generation then return false end
        local ok, err = pcall(tick, id)
        if not ok then
            -- 错误应限流记录；不能让同一异常每帧刷屏
        end
        return false
    end

    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function" then
        local ok, handle = pcall(LoopInGameThreadAfterFrames, 1, guardedTick)
        if ok and handle ~= nil then
            loopHandle = handle
            return "frame"
        end
    end

    if type(LoopInGameThreadWithDelay) == "function" then
        local ok, handle = pcall(LoopInGameThreadWithDelay, 10, guardedTick)
        if ok and handle ~= nil then
            loopHandle = handle
            return "timer"
        end
    end
    return "unavailable"
end
```

本模板为生命周期说明；循环回调是否由返回值停止应按所安装 UE4SS 版本的 Delayed Actions 实现确认，不要用返回 true/false 代替明确的 `CancelDelayedAction` 清理。

### 4.5 旧接口

`ExecuteAsync` / `LoopAsync` 仍可能在旧代码中可用，但上游升级指南已将其标记为 deprecated，推荐迁移到 Delayed Actions。新代码不要再依赖旧接口的无 handle 生命周期；既有代码迁移前需要确认旧 UE4SS 版本兼容窗口。

## 5. UFunction Hook 与构造通知

### 5.1 RegisterHook

`RegisterHook(fullFunctionPath, preCallback, postCallback)` 注册 UFunction Hook，并返回 PreId/PostId。目标 UFunction 必须在安装时已经存在；不支持 Delegate 函数。

- `/Script/` 路径：第 2 个参数是 pre callback，第 3 个参数是 post callback。
- 非 `/Script/` 路径：第 2 个参数按文档是 post callback；第 3 个参数不承担通常的 post 参数意义。
- Hook 参数是 Remote/Local Unreal Param；按文档要求用 `:get()` 取得值。
- 返回 nil/不返回值表示不覆盖原函数返回值；返回其他值可能尝试覆盖 UE 返回值。

```lua
local path = "/Script/Engine.PlayerController:ClientRestart"
local preId, postId

preId, postId = RegisterHook(path, function(context, newPawn)
    local controller = context:get()
    local pawn = newPawn:get()
    if controller and controller:IsValid() and pawn and pawn:IsValid() then
        -- 只捕获必要的状态
    end
    -- nil：不更改原函数返回值
end)

-- 在卸载或不再需要时：
if preId then
    UnregisterHook(path, preId, postId)
    preId, postId = nil, nil
end
```

实战要求：先确认 UFunction 已加载；安装失败记录具体函数路径；保存 ID；卸载时反注册；不在高频 Hook 中进行磁盘 IO、全局对象扫描或大量格式化日志。Hook 是对其他模组也可能使用的公共函数的拦截点，不能随意更改返回值或参数。

### 5.2 Hook 重试与安装时机

目标函数尚未进入内存时注册会失败。可选策略：

1. 在明确的初始化时机注册（如 InitGameState/BeginPlay 后）。
2. 用低频定时器重试，直到确认安装成功后停止。
3. 对动态创建对象使用 NotifyOnNewObject 找到对象后再探测其函数。
4. 安装失败保留状态并允许稍后重试；不能把“尝试过一次”标成“Hook 已工作”。

UE4SS 提供 `RegisterInitGameStatePostHook`、`RegisterBeginPlayPostHook` 等生命周期 Hook。要选择与对象初始化顺序相符的时点，并注意同一游戏状态可能在切图时重建。

### 5.3 Hook 回调参数与返回值

UE4SS 文档中 RemoteUnrealParam 包装器的 `get()/set()` 只解决传参表示，不会自动证明参数的实际业务类型。PBZ 的游戏 UFunction 参数最好与当前构建的反射 SDK 对照，并进行只读的实机探针。

除非有明确需求，不覆盖游戏函数返回值。若需要修改输入参数，应：
- 检查类型、可空性和生命周期；
- 记录原值并限定写入范围；
- 能在 Hook 结束后恢复的状态要可靠恢复；
- 与 PBZPerfectDefense/其他输入 MOD 的写入顺序进行冲突测试。

## 6. 数组、映射和结构体

### 6.1 TArray

UE4SS 暴露的 TArray 按 Lua 习惯采用 1-based 索引。可用 `#array`、`array[index]`，或 `ForEach(callback)`。ForEach 的元素可能是 Remote/Local Unreal Param，使用 `:get()` 读取，`:set()` 写入；回调返回 true 可提前结束。

```lua
local frames = deflect.ReceiveFrames
if frames and frames:IsValid() then
    frames:ForEach(function(key, frameParam)
        local frame = frameParam:get()
        if frame and frame.HitGameTime then
            -- 只读检查当前元素
        end
    end)
end
```

### 6.2 TMap

TMap 使用 `Find(key)`、`Contains(key)`、`Add(key, value)`、`Remove(key)`、`ForEach(callback)`。`Find` 在 key 不存在时会抛异常，应先 `Contains` 或用 pcall；ForEach 的 key/value 需要按 Remote/Local Param 包装规则解包。

```lua
local map = deflect.ReceiveFrames
if map and map:Contains(handle) then
    local ok, value = pcall(function() return map:Find(handle):get() end)
    if ok then
        -- 读取找到的 frame
    end
end
```

不要在遍历中修改正在遍历的键；UE4SS 文档指出修改 key 属于未定义行为。

### 6.3 Lua 表作为 Unreal 结构体参数

UE4SS 允许在参数位置传入普通 Lua table 代表结构体，例如 FVector：

```lua
local location = { X = 100.0, Y = 20.0, Z = 5.0 }
```

这只是在 UE4SS 支持的结构体参数转换范围内方便构造参数，不代表任何 Blueprint struct 都能无损自动构造。复杂嵌套结构、Optional、FieldPath 或带特殊参数的函数必须有对应绑定验证。

## 7. 按键绑定与输入安全

### 7.1 RegisterKeyBind

UE4SS `RegisterKeyBind` 支持：
- `RegisterKeyBind(Key.F1, callback)`
- `RegisterKeyBind(Key.F1, { ModifierKey.CONTROL }, callback)`

回调只会在游戏或 Debug Console 获得焦点时触发。若回调要读写 Unreal 对象，应在 callback 中调用 `ExecuteInGameThread`。

### 7.2 输入动作不是单个 API

在 PBZ 自动防守场景中，要区分：
1. 物理按键绑定（UE4SS 注册的 MOD 热键）；
2. Enhanced Input 的 InputAction；
3. 游戏内部 AbilityInputComponent；
4. 由能力系统/DeflectComponent 管理的受击帧与防守结果；
5. PBZPerfectDefense 等外部 MOD 的 guard ownership。

不能因为 `RegisterKeyBind` 可用，就认为它和游戏内部的 InputAction/Ability 输入是同一条输入链。修改/注入输入之前必须核对目标组件和输入优先级，并通过统一策略门控，避免多模组同时发起防守动作。

### 7.3 PBZ Auto Defense 的输入边界

`Scripts/ad_input.lua` 集中处理 guard press、guard release、stance end、tag 和 dodge inject。每次调用先经 `ad_policy` 判定，再执行绑定进来的底层动作。新代码不应绕过 `tl.input` 直接调用旧的 press/inject 函数。

## 8. 异常、日志和资源生命周期

- 对可能因切图/重生失效的 UObject 调用，要做有效性检查。
- 对跨版本/可选对象查询使用受控 pcall；错误日志按原因去重/限流。
- 日志不要每帧输出；应采用固定上限、缓冲与低频 flush。
- 每个 Loop/Delayed Action 保存 handle，避免匿名无限循环失控。
- 每个 RegisterHook 保存两个 hook id；生命周期结束时 UnregisterHook。
- 订阅事件后要有明确取消/清理路径，不能在热重载时累积订阅者。
- 文件读写、JSON 解析、全量数据索引构建应尽量放到加载期或低频预算中，不要在 parry/dodge 决策点同步做磁盘 IO。

PBZ Auto Defense 的 `ad_async` 是进程内观测事件环，不是 UE4SS 异步线程。事件环只保存固定字段、每 tick 限量 drain；不得在 press 路径里执行磁盘写入。

## 9. 性能预算与常见反模式

| 反模式 | 为什么有问题 | 推荐替代 |
|---|---|---|
| 每帧 `FindAllOf` | 全局对象数组扫描 | 使用已存在对象引用，或缓存 FindFirstOf/StaticFindObject 结果 |
| 对每个对象调用 `GetFullName()` | 高频字符串分配/格式化 | 用 FName、类对象、IsA |
| 查找失败后每帧重试 | 稳定失败会变成常驻高成本 | 负缓存 + 低频重试/NotifyOnNewObject |
| 无 handle 的无限循环 | 无法可靠取消、重载时可能残留 | 新 Delayed Actions + handle 管理 |
| 一个 Hook 安装失败后永不重试 | 目标类晚加载时功能永久缺失 | 检测状态、有限重试、清晰日志 |
| 每个 Hook 都写日志/文件 | IO 与格式化挤占帧预算 | 环形 buffer / 异步 sink / 低频 flush |
| 多个 MOD 直接调用同一个输入组件 | 同帧抢占、重复输入、guard 状态冲突 | 统一策略门控和 owner 检测 |
| 未验证 out 参数就复用表 | 可能累积旧数据或读取不完整字段 | 先实机验证输出结构与覆盖语义 |
| 未检查对象有效性就长时间缓存 | 切图/重生后 stale reference | 每次边界检查并重建缓存 |

### 9.1 性能测量

性能比较必须在同一个游戏构建、同一场景、同一画面设置、相同敌人/招式序列下进行。记录：
- 每 tick 执行成本的 avg、p50、p95、p99、max；
- tick 间隔/hitches；
- Lua 内存；
- hook 调用次数与累计耗时；
- 防守决策是否缺失、重复或延迟；
- 游戏实际帧率和帧时间（游戏/外部工具测量）。

只降低 Lua tick 时间但漏掉命中帧的优化不合格。只减少定时器回调也不能证明提升了平均 FPS。

## 10. PBZ Auto Defense 中的 API 对照

| 功能 | 当前实现 | API/模块边界 | 主要约束 |
|---|---|---|---|
| 玩家控制器 | UEHelpers 查询并缓存 | UEHelpers / UObject IsValid | 原始 helper 可能全局扫描 |
| 稳定 CDO 查找 | `ad_query.obj` | StaticFindObject + 缓存 | 路径受游戏构建影响 |
| PBZ 能力库 | `ad_query.tagLibrary` | StaticFindObject 优先，ForEachUObject 兜底 | 5 秒负缓存，失败兜底不进每帧路径 |
| Deflect Component | Pawn 属性查询 | UObject 属性访问 | Blueprint 属性名带空格 |
| Ability Input Component | Pawn 属性查询 | UObject 属性访问 | 运行时行为还需游戏验证 |
| 命中帧扫描 | `ReceiveFrames` | TMap/TArray 包装器 | 不复用未验证 out-frame |
| 命中帧查询 | `GetNearestValidReceivedFrame` | PBZDeflectSystem SDK 签名交叉核对 | SDK 标记 reflection-generated |
| 游戏时间 | GameplayStatics | CDO 方法调用 | 需有效 World/Pawn |
| 热键 | RegisterKeyBind | 按键回调 + ExecuteInGameThread | 焦点限制 |
| 主循环 | LoopInGameThreadAfterFrames 优先 | EngineTick delayed action | handle 取消 + generation |
| 兼容回退 | 10 ms delayed loop | LoopInGameThreadWithDelay | 老 UE4SS 构建 |
| 自有规则 | ad_policy | 纯 Lua 规则 | 不直接调用 UE 游戏 API |
| 输入执行 | ad_input | 统一门控 | 禁止新增旁路 |
| 观测 | ad_async | 固定环形队列 + 限量 drain | 不参与决策 |

## 11. 升级/兼容性核对表

每次更新 UE4SS 或游戏后，按顺序确认：

- [ ] UE4SS Lua MOD 能正常启动，`require("UEHelpers")` 可用。
- [ ] 当前版本是否提供 `LoopInGameThreadAfterFrames`、`EngineTickAvailable` 和 `CancelDelayedAction`。
- [ ] 帧调度失败时是否记录 fallback 日志并仍有 10 ms timer。
- [ ] `StaticFindObject` 对必需 CDO 返回有效对象。
- [ ] PlayerController/Pawn/Deflect Component 在菜单、暂停、切图、重生阶段的生命周期正确。
- [ ] 所有 RegisterHook 的路径在目标时刻已加载，安装 ID 可取消。
- [ ] Hook 参数使用正确的 get/set 转换，没有把包装器当普通 Lua 值。
- [ ] PBZDeflectSystem 的函数参数/字段名与当前游戏 build 反射一致。
- [ ] 输入动作没有与 PBZPerfectDefense/其他 MOD 发生同帧冲突。
- [ ] 离线测试与 Selene 通过。
- [ ] 通过实机 ledger/perf 与指定敌人序列验证行为和尾延迟。

## 原始资料

- [UE4SS 创建 Lua MOD](https://github.com/KintaroModding/ue4ss/blob/release/docs/guides/creating-a-lua-mod.md)
- [UE4SS Lua API 总览](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api.md)（总览页自身提示过时，逐项 API 文档优先）
- [Delayed Actions](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/delayedactions.md)
- [ExecuteInGameThread](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/executeingamethread.md)
- [StaticFindObject](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/staticfindobject.md)
- [FindFirstOf](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/findfirstof.md)
- [FindAllOf](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/findallof.md)
- [NotifyOnNewObject](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/notifyonnewobject.md)
- [RegisterHook](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/registerhook.md)
- [UnregisterHook](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/unregisterhook.md)
- [TArray](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/classes/tarray.md)
- [TMap](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/classes/tmap.md)
- [FName](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/classes/fname.md)
- [RemoteUnrealParam](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/classes/remoteunrealparam.md)
