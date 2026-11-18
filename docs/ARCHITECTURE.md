
# Architecture / 项目架构

本文描述 PBZ Auto Defense 当前 UE4SS Lua 实现的模块边界、启动路径、每帧数据流和副作用控制点。它是代码导览，不表示所有机制在每个游戏 build 上都已实机验证。当前版本由 Scripts/main.lua 中的 tl.VERSION 定义。

## 1. System context / 系统边界

PBZ Auto Defense 是一个 UE4SS Lua 模组。战斗读取、Hook、输入注入、防守决策和菜单配置适配均运行在 UE4SS Lua 运行时中。

| Component | Role / 角色 | Boundary / 边界 |
|---|---|---|
| UE4SS Lua runtime | 加载 Lua 模组，提供 UObject、Hook、Delayed Actions、KeyBind 和游戏线程 API | 当前模组的真实运行时 |
| UEHelpers | 提供玩家控制器等辅助查询 | 主脚本包装 GetPlayerController 并缓存有效 controller |
| Phantom Blade Zero | 提供 Deflect Component、Ability Input Component、Gameplay Ability、ReceiveFrames 等游戏对象/API | 具体签名与可调用性需按游戏 build 验证 |
| PBZModsMenu | 提供原生设置 UI | 只负责展示/收集设置 |
| PBZModsMenuBridge | 菜单配置保存协议 | 负责将菜单提交内容写入模组 JSON |
| PBZPerfectDefense | 可协作的 guard ownership 状态源 | 配置/状态让位，不是跨模组互斥锁 |

PBZModLoader 的 TypeScript SDK 与 PBZ USMAP 是开发期参考，不是当前 Lua 运行时依赖，也不能替代 UE4SS Lua binding。

## 2. Module map / 模块关系

~~~mermaid
flowchart TD
    UE4SS["UE4SS Lua runtime"] --> MAIN["Scripts/main.lua<br/>orchestrator + combat logic"]
    UEH["UEHelpers"] --> MAIN
    MENU["PBZModsMenu UI"] --> BRIDGE["PBZModsMenuBridge"]
    BRIDGE --> SHIM["Scripts/ad_menu_bridge.lua<br/>filename compatibility only"]
    SHIM --> CONFIG["Scripts/menu_config.lua"]
    JSON["Scripts/ad_json.lua"] --> CONFIG
    CONFIG --> MAIN
    QUERY["Scripts/ad_query.lua<br/>read-only UObject queries"] --> MAIN
    DATA["data/ad_data.lua<br/>frozen snapshot + reference overlay"] --> MAIN
    SEED["Scripts/ad_seed.lua<br/>pure no-frame seed merge"] --> MAIN
    TL["Scripts/ad_timeline.lua<br/>learned timeline table"] --> MAIN
    POLICY["Scripts/ad_policy.lua<br/>allow / deny rules"] --> INPUT["Scripts/ad_input.lua<br/>controlled side effects"]
    INPUT --> MAIN
    ASYNC["Scripts/ad_async.lua<br/>event ring + warm-up queue"] --> MAIN
    COMPAT["Scripts/ad_compat.lua<br/>Lua version adapters"] --> MAIN
    INPUTSTATE["Scripts/ad_inputstate.lua<br/>game hold answer, key fallback"] --> MAIN
    WEAPON["Scripts/ad_weapon.lua<br/>read-only weapon / shachi / blue-shield readers"] --> MAIN
    COUNTER["Scripts/ad_counter.lua<br/>counter timing state machine"] --> MAIN
    TOAST["Scripts/toast.lua"] --> MAIN
    MAIN --> GAME["PBZ gameplay objects / hooks / input"]
    MAIN --> LOGS["logs + decision ledger + perf"]
~~~

### Runtime module responsibilities / 运行时模块职责

| Module | Owns / 职责 | Must not become / 不应变成 |
|---|---|---|
| Scripts/main.lua | 主初始化、tick 编排、攻击与结果 Hook、命中候选、完美弹反/弹反/闪避算法、账本、数据加载、热键 | 新的配置解析器或第二套副作用入口 |
| Scripts/ad_query.lua | 只读 UObject/属性/组件查询、有效性探测、名称归一化、稳定对象缓存 | 每帧无界 UObject 全表扫描；输入注入或属性写入 |
| Scripts/ad_timeline.lua | 学习时间轴表及其 key count；put/add/addRow/removeRow/recount | 被其他模块绕过 API 直接改表并维护计数 |
| Scripts/ad_policy.lua | 纯规则判断：intent → allow/deny + reason；记录拒绝统计 | 直接调用游戏对象或执行输入 |
| Scripts/ad_input.lua | guard press/release、stance end、tag、input injection 的统一门 | 自己重新实现防守算法；绕过 policy 直接操作游戏 |
| Scripts/ad_inputstate.lua | 读游戏自己的 hold 状态（`IsHolding/GetHoldTime`）并按注入窗口裁定是否采信；失败一律返回 nil | 缓存过期状态、把本模组注入的按键当成玩家按住、从 hook 里写游戏状态 |
| Scripts/ad_seed.lua | 纯 reference_noframe 索引与复制后合并：敌人类 + Ability + 距离精确匹配，时间邻近去重 | 读取游戏对象、持有攻击生命周期、修改全局 hitTimes 或执行输入 |
| Scripts/ad_weapon.lua | 只读游戏状态读取器：手里是不是别离残钩（武器名含 DualHook）、杀气多少、最近的蓝盾敌人在哪；读取函数由 main.lua 注入，结果按约 0.5 s 过期缓存，失败只计数一次原因 | 直接写游戏状态、执行输入、成为第二个 UObject 扫描点，或缓存过期读数 |
| Scripts/ad_counter.lua | 反制时序状态机：offer / nextPress / guardUp / poll / pending / stats，按注入时钟在 0.22–0.35 s 窗口内给出「等 / 按 / 放弃」，一次只允许一个在途反制 | 直接写游戏状态、自己注入按键，或拥有攻击生命周期 |
| Scripts/ad_async.lua | 只读事件环和预算化 warm-up 队列 | 在 hook 里直接做无界 IO/计算或改变防守判断 |
| Scripts/ad_json.lua | 受限扁平 JSON 编解码 | 接受任意嵌套 JSON 或承担 schema policy |
| Scripts/menu_config.lua | 配置 schema、校验、单位映射、持久化、热应用与 pending restart 状态 | 控制战斗算法或取代 Bridge 的菜单写入责任 |
| Scripts/ad_menu_bridge.lua | 兼容 Bridge pending/saved 文件名 | 解析/改写 JSON，成为第二配置写入者 |
| Scripts/ad_compat.lua | LuaJIT/Lua 5.4 差异封装 | 散落多个运行时版本分支 |
| Scripts/toast.lua | 一次性屏幕提示与对应 delayed action 管理 | 常驻高频显示轮询 |
| data/ad_data.lua | build 绑定的 PBZAssist 招式快照；独立 `reference_noframe` 命名空间保存带来源的少量缺帧参考时机 | 动态游戏 API、每帧生成的数据源，或用参考层替换原快照 |

tools/ 中脚本只属于离线测试、检查、打包和发布流程，不在游戏运行时加载。

## 3. Initialization order / 初始化顺序

以下按 Scripts/main.lua 的实际流程概括：

1. 加载 UEHelpers，并包装 GetPlayerController：缓存有效 controller，失效时重新寻找；避免每 tick 都触发全局对象遍历。
2. 加载 toast 模块，计算模组目录，建立 ad_query 与基础日志通道。
3. 尝试加载 ad_compat，记录 Lua 版本/JIT 信息；建立 runtime helpers。
4. 建立内存 settings 默认值，读取旧 auto_defense.txt 中被识别的字段。
5. 初始化 ad_json、可选 ad_menu_bridge shim 和 menu_config；调用 hk.menu:load(true) 读取已有 JSON，或仅在 JSON 不存在时把当前 settings 导入成首份 JSON。
6. 加载/构造事件观察、数据快照、命中帧和时间轴相关状态；把 `reference_noframe` 交给纯 `ad_seed` 适配器，失败时保持无参考种子的旧行为。
7. 加载 ad_policy 并绑定到 ad_input；把主脚本原始 press/release/end-stance 函数替换为受控入口。
8. 构造 warm-up、performance、watchdog 和 player state 运行结构。
9. 调用 tl.start() 启动主循环；注册 F7/F8/F9/F6 热键。
10. 随着玩家与组件出现，在 tick 中按需注册攻击、弹反帧、能力激活、子弹和结果 Hook。

部分模块在 do...end 块或第一次需要时加载；不要假设所有游戏 Hook 在 Lua 文件开始执行时都已存在。

## 4. Frame data flow / 每帧数据流

~~~mermaid
flowchart TD
    A["UE4SS delayed action callback"] --> B["tl.main(generation)"]
    B --> C["Config poll + menu bridge shim"]
    C --> D["Watchdog"]
    D --> E["Bounded event drain + one warm-up step"]
    E --> F["Drain result receipts"]
    F --> G{"Player available?"}
    G -- No --> Z["Return; retry player lookup later"]
    G -- Yes --> H{"Cutscene / control pause / new pawn?"}
    H -- Yes --> Y["Clear transient state / pause decisions"]
    H -- No --> I["Prune caches + refresh PD ownership"]
    I --> J["Resolve Deflect + Ability Input components"]
    J --> K["tickPerfect"]
    K --> L["tl.decide(pawn, deflect, input, gameTime)"]
    L --> M["Timeline + ReceiveFrames + health/enemy observers"]
    M --> N["Guard release / dodge stages"]
    N --> O["Timed dodge + tap hold + optional receipt"]
    O --> P["Parry stage"]
    P --> Q["Ledger / next tick"]
~~~

主循环并不等同于“每帧只做一次弹反查询”。每帧先进行配置、监视、观察和状态维护，然后按明确顺序执行战斗阶段。tl.main 先更新菜单配置和 Bridge shim，再 drain 事件/预热队列，然后检查玩家/场景，刷新 PD ownership 和组件，执行完美标记维护，最后进入 tl.decide。

tl.decide 的固定顺序：

| 顺序 | Stage | Purpose / 目的 |
|---:|---|---|
| 1 | timeline tracking（debug/experiments 时） | 记录敌方攻击/动画时间线 |
| 2 | read frames | 读取游戏的真实 ReceiveFrames 时间与类型 |
| 3 | health / enemy observers | 记录受击、观察敌人及能力激活 |
| 4 | release | 维护弹反后遗留的 guard 状态 |
| 5 | activation hook / stance / manual dodge | 观察能力激活、姿态和手动闪避 |
| 6 | Sát Khí recovery | 处理完美标记影响下的恢复逻辑 |
| 7 | guard release | 处理 guard key、延迟闪避和释放条件 |
| 8 | dodge | 先处理红色/需要闪避的当前 ReceiveFrame |
| 9 | timed dodge | 执行时间轴安排的延迟闪避 |
| 10 | tap hold | 处理弹反按键保持窗口 |
| 11 | receipt（可选） | 检查输入回执 |
| 12 | parry | 处理尚未交给闪避的普通/蓝色命中 |

反制层（`hook_counter` / `shield_counter`，默认都关）在时间轴候选到期时先试一次：`tl.counterTry` 把候选交给 `ad_counter`，读完 `ad_weapon` 的「武器在手 / 杀气达标 / 动作已解析」三个条件后给出 press、wait 或 nil。press 时本 tick 按住格挡姿态并在下一帧注入一次三角形，该候选不再进入 dodge/parry；wait 表示本 tick 太早、下一 tick 再算；nil 表示这段候选完全按 1.6.6 的闪避/弹反链走，两个开关都关时永远只得到 nil。

**红招先于弹反**是一个重要顺序约束：不能把 parry 放到 dodge 前，否则可能抢先处理红色不可弹反命中。

## 5. Data and decision flow / 数据与决策流

### Hit candidate inputs / 候选命中来源

- **ReceiveFrames / Deflect Component：** GetNearestValidReceivedFrame 查询最近有效命中句柄；read_frames 允许进一步读取真实命中时间与类型。
- **Enemy ability / montage timeline：** 攻击 hook 与跟踪器识别敌方 Ability 和动画时间线，结合打包/学习的数据估计后续命中时刻。
- **Game data snapshot：** data/ad_data.lua 带有 build 标识，冻结的 PBZAssist 表提供招式、闪避、无敌、抓取和标签等数据。
- **Reference no-frame overlay：** 同一文件的 `reference_noframe` 是独立、有来源的少量参考时机。`record` 只报告严格匹配；`on` 仅按敌人类 + Ability + 距离合并只闪避行，已有/学习行和真实 ReceiveFrame 优先。
- **Player state：** 当前 Pawn、能力输入组件、玩家动作锁、无敌窗、guard state、PD ownership 等用于过滤与路由。

### Decision → policy → execution / 决策到副作用

~~~mermaid
flowchart LR
    DECIDE["main.lua decision"] --> INTENT["intent"]
    INTENT --> POLICY["ad_policy.ask"]
    POLICY -->|allow| GATE["ad_input"]
    POLICY -->|deny + reason| EVENT["denial event / counter"]
    GATE --> MECHANIC["registered raw mechanic"]
    MECHANIC --> GAME["PBZ ability / Enhanced Input / tags"]
~~~

main.lua 负责决定“应该弹反还是闪避，以及何时做”。副作用边界被分为两层：

- ad_policy 当前集中管理 guard_press、perfect_tag、guard_release、stance_end 和 dodge_press 等规则。
- ad_input 再调用主脚本注册的具体 mechanic。
- 规则拒绝会保留原因并计数。
- 若 policy 未安装，输入模块按当前实现采取通过策略；初始化失败时主脚本安装 pass-through，避免接口为 nil。

### Observability is not authority / 观测不是决策源

ad_async 使用容量 512 的 ring buffer 收集只读事件，每 tick 最多 drain 16 条；warm-up 每 tick 最多推进一个任务。事件总线用于日志/诊断，不应成为同步决策依赖。events=false 使 event emission no-op；防守判断依然由主脚本和游戏状态完成。

## 6. Shared state and ownership / 共享状态所有权

- ad_timeline 独占时间轴表与 count。要插入/删除学习行，使用 put/add/addRow/removeRow/recount，不要只改表而不改 count。
- ad_query 的 tag 表是 memoized/shared read cache；调用者不得修改共享 TagName 表。
- main.lua 拥有 combat state、临时 pending 输入、handle caches、hook status、data indexes 和 ledger。
- ad_policy 拥有 allow/deny 规则与拒绝计数。
- ad_input 拥有 side-effect entry bindings，不拥有具体决策。
- ad_seed 只拥有规范化索引和纯合并规则；main.lua 继续拥有 q.tapped、ReceiveFrame 配对和时间轴生命周期。
- ad_weapon 只拥有读取缓存、失败原因和 stats；ad_counter 只拥有一次在途反制的时序（pending / pressOwed / 确认窗口）。按键注入、格挡保持和武器切换仍由 main.lua 执行。
- menu_config 的 raw 和 lastText 对应最近一份通过验证的 JSON；pending 对应本次运行需重启的字段。
- ad_menu_bridge 只拥有自己的文件名镜像统计和轮询节流，不拥有配置语义。

tl.api 是显式公开给其他模块/测试的表面（当前 31 个名称）；未列入 tl.api 的字段均为内部实现细节。测试全局只在带 .ad-menu-test-only 标记的隔离副本中导出，正常安装不暴露这些全局。

## 7. Persistence map / 持久化映射

| Artifact | Purpose / 用途 |
|---|---|
| pbz-auto-defense.config.json | Native menu/热键配置的权威持久化 |
| auto_defense.txt | 旧版 TXT 导入和回滚副本 |
| hit_times.txt / learned timing artifacts | 游戏攻击时间轴/学习相关数据（按主脚本加载路径管理） |
| data/ad_data.lua | 随发行包提供的 build-bound PBZAssist snapshot + provenance-bearing `reference_noframe` overlay |
| auto_defense_log.txt | 启动、hook、配置和错误日志 |
| auto_defense_ledger.txt | 防守候选、时机、意图与输入结果 |
| ad_events.txt | 批量写入的只读事件观察 |
| perf_log.txt | tick、hook、stage 的性能统计 |
| attacks_log.txt | debug 下的敌方攻击、帧、受击和响应诊断 |

生成文件、用户配置、日志和开发期工具输出不应被当成默认代码资源提交或打进发行包。

## 8. Design invariants / 架构不变量

1. 保持单一主循环；重启循环必须取消旧 handle 或使旧 generation 立即返回。
2. 游戏对象查询在 ad_query；不要把全局 UObject 扫描放进每帧热路径。
3. 所有防守副作用经过 policy/input 门；新增输入或 tag 写入前必须定义 intent。
4. dodge 执行在 parry 前；更改顺序必须有对应的红招回归测试。
5. 事件总线只承载观察，不得阻塞或改变实时防守决策。
6. Config JSON 是正常运行时权威来源；不要从 TXT 和 JSON 同时双向写入。
7. 修改游戏 API 签名时同时检查 UE4SS Lua binding、PBZ 反射声明的验证等级和实机证据。
8. 离线桩测试通过不等于真实游戏战斗/菜单/性能已经验证。

## Related documents / 相关文档

- [Configuration Reference](CONFIGURATION-REFERENCE.md) — 46 个配置键与迁移策略。
- [Deflect State Machine](DEFLECT-STATE-MACHINE.md) — 候选命中到弹反/闪避执行的详细状态流。
- [Runtime Lifecycle](RUNTIME-LIFECYCLE.md) — 游戏线程、主循环、Hook 与资源清理。
- [Module layout](MODULES.md) — 文件职责、公开表面和 intent 规则表。
- [Menu integration](MENU-INTEGRATION.md) — PBZModsMenu 与 Bridge 保存协议。
