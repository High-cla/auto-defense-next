
# Configuration Reference / 配置参考

本文以当前运行时代码为准，列出所有配置键的中英文说明、类型、默认值、范围、生效时机、持久化和迁移行为。当前源码版本由 Scripts/main.lua 中的 tl.VERSION 定义；配置 schema 位于 Scripts/menu_config.lua，原生菜单元数据位于仓库根目录的 pbz-auto-defense.modsmenu.json。

> **配置权威来源：** 原生菜单集成可用时，pbz-auto-defense.config.json 是唯一运行配置源。auto_defense.txt 仅作为首次导入来源和人工回滚副本，不与 JSON 双向同步。

## 1. 文件与职责 / Files and ownership

| 文件 | 职责 |
|---|---|
| Scripts/menu_config.lua | 46 个字段的 schema、运行时类型与范围校验、单位转换、重启项隔离、热键读改写 |
| pbz-auto-defense.modsmenu.json | 原生菜单 UI 元数据：中英标签、帮助文本、默认值、选项、数值范围和 restart 标记 |
| Scripts/main.lua | 运行时设置初值、旧 TXT 读取、配置加载顺序，以及热应用时需重置的内部状态 |
| Scripts/ad_json.lua | 只接受扁平 JSON object；负责编码、解码和输入大小限制 |
| Scripts/ad_menu_bridge.lua | 只处理 PBZModsMenuBridge 文件名兼容，不负责 JSON 解析，也不直接写主配置文件 |
| docs/MENU-INTEGRATION.md | 菜单与 Bridge 协议、故障记录及现场验收 |

用户配置位于模组目录：

    <UE4SS>/Mods/pbz-auto-defense/pbz-auto-defense.config.json
    <UE4SS>/Mods/pbz-auto-defense/auto_defense.txt
    <UE4SS>/Mods/pbz-auto-defense/pbz-auto-defense.modsmenu.json

发行包不应包含某位玩家的运行时 JSON，也不应在更新时覆盖玩家自己的配置文件。

## 2. 完整配置字段 / Complete setting catalog

表中的“菜单类型”对应描述符的 type；“运行时类型”是 JSON 校验后的 Lua 类型。Restart 表示通过菜单修改后先保存、下次启动才写入本次运行时设置。自由文本字段在菜单中只读，需编辑 JSON。

### 2.1 功能与防守行为 / Defense behavior

| Key | 菜单标签（中文 / English） | 类型 / 默认值 | 约束 / 选项 | 生效 / Apply | 注释 / Description |
|---|---|---|---|---|---|
| perfect | 完美弹反 / perfect | boolean / false | true 或 false | Live | 开启模组的完美弹反处理；具体策略由 perfect_mode 决定。 / Enables the mod's perfect-deflect handling; behavior is selected by perfect_mode. |
| perfect_mode | 完美模式 / perfect_mode | string choice / "give" | always、give、window | Restart | always 持续维持完美标记；give 不常驻标记，而通过游戏窗口处理普通弹反并仅在特定黑闪/子弹窗口使用标记；window 在检测到近时命中时短暂加标记。window 是保留的实验模式。 / Selects always-on, give-window, or hit-window perfect handling. |
| black_flash | 黑闪处理 / black_flash | string choice / "dodge" | dodge、parry | Restart | 主要用于 perfect_mode="give"：黑闪走闪避，或以完美标记处理弹反。hook_counter=on 且条件满足时黑光改走反制，不再看本项。 / In give mode, choose to dodge a black flash or handle it with the perfect tag. With hook_counter=on and its conditions met, a black flash is countered instead, and this setting is not consulted. |
| hook_counter | 别离残钩反制 / hook_counter | string choice / "off" | off、on | Live | 关闭时不改变任何行为。开启后：手持别离残钩（武器名含 DualHook）且杀气不低于 hook_counter_shachi 时，黑光（PowerAttack）判定改为「按住格挡＋三角形」反制，不再按黑闪设置闪避/弹反；条件不满足时仍按 black_flash 处理。 / Off changes nothing. On: with a DualHook weapon in hand and shachi at or above hook_counter_shachi, a black-flash (PowerAttack) check becomes a block-and-triangle counter instead of what black_flash picks; when a condition fails, black_flash still decides. |
| hook_counter_shachi | 反制杀气阈值（%） / hook_counter_shachi | number / 37 | 0–100，步进 1（%） | Live | 仅 hook_counter=on 时读取；杀气低于该值的黑光仍按 black_flash 处理。 / Read only while hook_counter is on; a black flash below it still follows black_flash. |
| shield_counter | 蓝色护盾反制 / shield_counter | string choice / "off" | off、on | Live | 测试中；关闭时不扫描、不换武器，行为与之前完全一致。开启后：shield_counter_range 内有带蓝色护盾（AttributeSetBase.Shield > 0）的敌人时，自动切到别离残钩并对它的可格挡攻击放反制；附近有这种敌人时不会把别离残钩切走。 / Experimental; off scans nothing and switches nothing. On: a blue-shielded enemy (AttributeSetBase.Shield > 0) within shield_counter_range makes the mod switch to the DualHook, counter that enemy's blockable attacks, and keep the hook in hand while such an enemy is near. |
| shield_counter_range | 蓝盾扫描距离（公分） / shield_counter_range | number / 1500 | 0–3000，步进 50 cm | Live | 仅 shield_counter=on 时读取；热改后下一次扫描即用新半径。 / Read only while shield_counter is on; a hot change applies to the next scan. |
| dodge | 闪避模式 / dodge | string choice / "red" | off、red、all | Restart* | off 关闭自动闪避；red 处理红色不可弹反命中；all 扩展到正常/可弹反命中。特定实验攻击与黑闪仍有专门分支。 / Disables dodging, dodges red hits, or broadens dodge handling to all queried hit kinds. |
| parry | 自动弹反 / parry | boolean / true | true 或 false | Live | 自动查询可弹反命中并执行弹反。关闭时会清除本模组待发的弹反/重复注入状态，不会强行释放玩家或其他模组持有的防守。 / Enables automatic parry; turning it off clears this mod's pending/repeated injections, not a player- or other-mod-owned guard. |
| parry_method | 弹反输入方式 / parry_method | string choice / "key" | key、ability | Restart | key 模拟弹反按键；ability 直接尝试调用弹反能力，可能留下持续防守姿态。 / Use a deflect-key tap or direct ability activation; direct activation can leave a held guard stance. |
| parry_reach | 弹反距离（米） / parry_reach | number / 0.5 | 0–100，步进 0.5 m | Live | 用于时间轴弹反的距离门槛：攻击者仍很远且游戏尚未发布命中帧时，可跳过过早输入；0 关闭该距离限制。 / Distance gate for timeline parries when no hit frame has been announced; 0 disables this gate. |
| guard_release | 冲刺解除防守 / guard_release | boolean / true | true 或 false | Live | 允许通过冲刺/闪避键释放本模组遗留的持续防守。 / Allows sprint/dodge input to release a guard held by this mod. |
| guard_release_after | 静默解除防守（秒） / guard_release_after | number / 0.5 | 0–120，步进 0.5 s；0 关闭 | Live | 最后一次相关动作后静默达到该时间，且没有即将到来的命中时释放防守。 / Releases the guard after this quiet interval when no incoming hit is imminent. |
| guard_release_combat_end | 战斗结束静默（秒） / guard_release_combat_end | number / 0.5 | 0–120，步进 0.5 s；0 关闭 | Live | 一段时间没有附近敌方攻击、受击或弹反后，按战斗结束处理并降低防守。 / Treats combat as over after this interval without nearby attacks, damage, or parries. |

* 菜单修改 dodge 被标为 Restart；F8 热键保留旧行为，会立即在 off → red → all → off 之间切换并写入 JSON。

### 2.2 输入、时序与观测 / Input, timing and observability

| Key | 菜单标签（中文 / English） | 类型 / 默认值 | 约束 / 选项 | 生效 / Apply | 注释 / Description |
|---|---|---|---|---|---|
| lang | 提示语言 / lang | string choice / "en" | en、vi | Live | 游戏内提示语言。当前运行时只实现英文和越南文；菜单的中文标签不代表运行时提示支持中文。 / In-game message language; runtime choices are English and Vietnamese, not Chinese. |
| hotkey_message | 热键屏幕提示 / hotkey_message | boolean / true | true 或 false | Live | 是否在屏幕显示热键切换提示；关闭后仍保留日志行为。 / Shows or hides on-screen hotkey notifications; logging remains separate. |
| learn | 学习新命中 / learn | boolean / true | true 或 false | Live | 控制 learned_hits 的新增学习，不等于关闭代码中独立的固定 LEARN 实验分支，也不会清空已有学习数据。 / Controls new learned_hits lessons; it does not disable the separate fixed LEARN experiment or erase existing lessons. |
| debug | 详细诊断日志 / debug | boolean / false | true 或 false | Live | 启用详细攻击/时间轴诊断及快照相关路径；会增加日志与探测开销。 / Enables verbose attack/timeline diagnostics and snapshot-related paths, with additional logging/probe cost. |
| perf | 性能日志 / perf | boolean / false | true 或 false | Live | 记录主 tick、hook 和阶段耗时的 avg、p50、p95、p99、max 及 hitch 计数，输出到 perf_log.txt。 / Records tick, hook and stage timing percentiles plus hitch counts in perf_log.txt. |
| events | 事件日志 / events log | boolean / true | true 或 false | Live | 通过只读事件总线写入 ad_events.txt；按批次/时间刷新并有行数上限。关闭后 emit 不再发布事件。 / Writes read-only events through the event bus to ad_events.txt; disabling it makes event emission a no-op. |
| read_frames | 读取真实命中帧 / read_frames | boolean / true | true 或 false | Live | 读取 Deflect Component 的 ReceiveFrames 时间/类型，用于更精确地判断命中时刻；关闭后主要依赖最近有效帧查询。 / Reads ReceiveFrames timing/type for hit-specific timing; off relies more heavily on nearest-valid-frame queries. |
| parry_lead | 弹反提前量模式 / parry_lead | string choice / "auto" | auto、manual | Live | auto 使用动态/学习到的提前量；manual 使用 parry_lead_seconds。 / Selects adaptive lead or the manual lead value below. |
| parry_lead_seconds | 手动弹反提前量（秒） / parry_lead_seconds | number / 0.08 | 0–1，步进 0.01 s | Live | 仅当 parry_lead="manual" 时使用。 / Used only when parry_lead is manual. |
| dodge_lead_ms | 闪避提前量（毫秒） / dodge_lead_ms | number / 80 | 0–1000，步进 10 ms | Live | 闪避输入相对于预计命中时刻的提前量；内部转换为秒。 / Dodge input lead relative to the expected hit; converted to seconds internally. |
| dodge_gap_ms | 闪避间隔（毫秒） / dodge_gap_ms | number / 120 | 0–2000，步进 10 ms | Live | 最近一次闪避之后的最小再闪避间隔；内部转换为秒。 / Minimum interval between dodge presses; converted to seconds internally. |
| dodge_iframe_ms | 闪避覆盖窗（毫秒） / dodge_iframe_ms | number / 260 | 描述符 0–2000、步进 10；运行时校验至少 40 ms | Live | 估计上一次闪避的无敌帧可覆盖后续命中的时间；小于 40 ms 会被配置校验拒绝。 / Estimated invulnerability coverage of the previous dodge; values below 40 ms are rejected at runtime. |
| pair_frames | 配对时间轴与真实帧 / pair_frames | boolean / true | true 或 false | Live | 将攻击时间轴命中与游戏实际发布的 ReceiveFrames 配对。 / Pairs learned/announced timeline hits with the game's received hit frames. |
| receipt | 检查输入回执 / receipt | boolean / false | true 或 false | Live | 检查游戏是否实际观察到输入/弹反结果；打开或关闭时会清理旧回执状态。 / Checks whether the game observed the input/deflect result; toggling clears stale receipt state. |
| receipt_retry | 未收到回执时重试（实验） / receipt_retry | boolean / false | true 或 false | Live | 实验性地在未收到回执后重试输入；需要结合 receipt 与实机验证使用。 / Experimental retry when a receipt is missing; use with receipt and validate in-game. |
| latency | 输入延迟自校准 / latency | boolean / true | true 或 false | Live | 根据观测到的输入延迟调整弹反提前量；关闭时不再继续应用旧延迟样本。 / Adjusts parry lead using observed input latency; off stops applying old latency samples. |
| ledger | 防守决策账本 / ledger | boolean / true | true 或 false | Live | 写入每次防守判断、候选命中、时间窗、输入结果等诊断信息；关闭时刷新待写缓冲。 / Writes defense decisions, hit candidates, timing windows and input results; disabling flushes buffered entries. |
| min_gap_ms | 弹反最小间隔（毫秒） / min_gap_ms | number / 120 | 0–1000，步进 10 ms | Live | 两次弹反输入之间的最小间隔；内部使用秒。 / Minimum interval between parry presses; converted to seconds internally. |
| grab_lead_ms | 抓取提前量（毫秒） / grab_lead_ms | number / 240 | 0–2000，步进 10 ms | Live | 抓取应对使用的专用提前量；内部使用秒。 / Dedicated lead time used by grab responses; converted to seconds internally. |
| dodge_cd | 避免闪避动作重叠 / dodge_cd | boolean / false | true 或 false | Live | 避免在上一段闪避动作仍进行时再次启动重叠闪避。 / Prevents starting overlapping dodge actions while a previous dodge is still active. |
| busy_skip | 动作锁期间等待 / busy_skip | boolean / false | true 或 false | Live | 当预计命中仍较远且角色处于自身动作锁时，延后弹反而不是立即输入。 / Defers a parry when the player is action-locked and the hit is still sufficiently far away. |
| flurry_guard | 连续攻击按住防守 / flurry_guard | boolean / true | true 或 false | Restart | 对连续攻击采用持续防守策略，而不是每个命中都独立点按。 / Uses a held-guard strategy for multi-hit flurries rather than an isolated tap per hit. |
| pbzpd | PBZPerfectDefense 防守让位 / pbzpd | string choice / "auto" | auto、yield、off | Restart | 控制与 PBZPerfectDefense 的协作让位策略；这是协作式状态判断，不是跨模组互斥锁。 / Selects the cooperative hand-off policy with PBZPerfectDefense; it is not a cross-mod mutex. |

### 2.3 游戏数据与热键 / Game data and hotkeys

| Key | 菜单标签（中文 / English） | 类型 / 默认值 | 约束 / 选项 | 生效 / Apply | 注释 / Description |
|---|---|---|---|---|---|
| data | 加载游戏招式数据 / data | boolean / true | true 或 false | Restart | 启用随模组分发的游戏招式数据快照；切换后重启以重新构造数据索引。 / Loads the bundled game-move data snapshot; restart to rebuild the data layer. |
| seed_fallback | 缺帧参考种子 / seed_fallback | string choice / "record" | off、record、on | Live | 依赖 data=true。off 禁用；record 只记录敌人类 + Ability + 距离精确匹配而不产生动作；on 合并只闪避的参考时机。已有快照/玩家学习行优先，真实 ReceiveFrame 会配对并取消参考输入。 / Requires data=true. Off disables it; record reports exact actor/ability/distance matches without acting; on enables dodge-only reference seeds. Existing/learned rows and real ReceiveFrames keep priority. |
| data_tags | 使用招式要求标签 / data_tags | boolean / false | true 或 false | Restart | 在使用招式数据时进一步应用招式要求/标签信息。 / Applies move requirement tags when the game-data layer is enabled. |
| dodge_attacks | 实验闪避关键字 / dodge_attacks | string（菜单只读）/ "" | 最长 4096 字节；禁止 CR/LF；手动 JSON 编辑 | Restart | 逗号/空白分隔的敌方 Ability 名称或标签匹配词；实验性地把命中改走闪避而非弹反。 / Comma/space-separated enemy ability names or tags that experimentally route matching attacks to dodge instead of parry. |
| data_off | 旧数据排除清单（当前无效果） / data_off | string（菜单只读）/ "" | 最长 4096 字节；禁止 CR/LF；手动 JSON 编辑 | Restart | 兼容保留字段，会被解析/保存，但当前运行时没有消费点，不会过滤数据。 / Preserved legacy field; parsed and persisted but currently not consumed by the defense runtime. |
| key_perfect | 完美弹反热键 / key_perfect | string choice / "F7" | 共用热键选项 | Restart | 切换完美弹反处理。 / Toggles perfect-deflect handling. |
| key_dodge | 闪避模式热键 / key_dodge | string choice / "F8" | 共用热键选项 | Restart | 循环切换闪避模式；默认 F8。 / Cycles the dodge mode; defaults to F8. |
| key_parry | 自动弹反热键 / key_parry | string choice / "F9" | 共用热键选项 | Restart | 切换自动弹反；F9 也可能与模组菜单快捷键冲突，建议使用 CTRL+F9 或其他键。 / Toggles automatic parry; F9 may conflict with the Mods Menu key, so CTRL+F9 or another key is recommended. |
| key_snapshot | 诊断快照热键 / key_snapshot | string choice / "F6" | 共用热键选项 | Restart | 触发诊断快照；需要 debug 路径启用。 / Captures a diagnostic snapshot; the debug path must be enabled. |

共用热键选项（描述符下拉列表）：

    none
    F1 ... F12
    A ... Z
    CTRL+F6 ... CTRL+F12

运行时 hk.parse() 还会通过 UE4SS 的 Key / ModifierKey 表解析键名，并支持额外修饰键形式（例如 SHIFT+ 或 ALT+）；这些扩展形式不一定出现在原生菜单下拉列表中。手动 JSON 请优先使用描述符列出的值。

## 3. 类型、范围与跨字段校验 / Validation rules

menu_config.validate 对完整配置按以下规则校验：

1. Toggle 必须是 JSON boolean；字符串 "true" / "false" 不接受。
2. Number 必须是 JSON number，且在 schema 定义的范围内；NaN/Infinity 不会通过校验。
3. Choice 必须与枚举值精确匹配（大小写敏感）。
4. Key 字段必须是字符串，且能被 hk.parse 解析；成功后转换为大写并去除空白，none 保持小写。
5. Read-only text 字段必须是字符串，最大 4096 字节且不能包含回车/换行。
6. 跨字段不变量：
   - dodge_lead_ms < dodge_gap_ms。
   - dodge_iframe_ms >= 40 ms（即使菜单描述符的 min 是 0）。
   - grab_lead_ms >= min_gap_ms。
7. 一个字段校验失败会拒绝整份新配置，不会只应用剩余字段。
8. 未知的顶层扁平字段不会被删除；每个未知键每次运行只记录一次 warning。热键读改写会保留这些字段。

Scripts/ad_json.lua 只支持顶层 JSON object 和标量值（string/number/boolean/null），不支持嵌套 object 或 array；最大读取/编码长度为 65536 字节，最多 256 个键。当前 schema 使用 46 个已知键，因此仍允许少量未来扩展键。

示例：

~~~json
{
  "perfect": false,
  "parry": true,
  "parry_lead": "manual",
  "parry_lead_seconds": 0.08,
  "dodge_lead_ms": 80,
  "dodge_gap_ms": 120,
  "dodge_iframe_ms": 260,
  "key_parry": "CTRL+F9"
}
~~~

parry_lead_seconds 以秒为单位；其余 *_ms 在 JSON 中以毫秒表达。

## 4. 生效时机 / Apply semantics

menu_config.apply 对每行的 restart 标记做区别：

- **Live fields：** 新 JSON 校验通过后，在主循环下一次配置轮询时写入运行时 settings，并调用 hk.menu.onApply 处理需要刷新的缓存或状态。
- **Restart fields：** 文件立即保存；本次运行只记录 pending 项，不覆盖当前运行设置。日志会给出 restart required 的字段名列表；下次启动的初始加载会应用。
- **Initial load：** 启动时所有字段（包括 Restart 字段）都会应用。
- **Poll cadence：** menu_config.poll 名义上每 1 秒检查一次；配置变化在游戏线程主循环中、输入决策前处理。这不是墙钟延迟保证。
- **Manual edits：** 即使没有 Bridge 事件，轮询仍比较 JSON 文件文本并加载，因此有效的手工 JSON 编辑也能被发现。

热应用时 main.lua 还会按字段清理状态：例如 read_frames 切换会清旧 FX，receipt 切换会清旧回执，关闭 parry 会清待发/重复弹反状态；perf 切换会重置统计窗口。

### 热键例外 / Hotkey exception

F7/F8/F9 等热键只支持本地动作；配置菜单的重启项仍然遵守 Restart 规则。F8 的闪避热键会先读取最新 JSON，只更新 dodge 并立即同步当前运行态，保留其他菜单变更和未知字段。不要把该例外推演为所有 Restart 字段都能热应用。

## 5. 持久化与保存路径 / Persistence

### Native menu save / 原生菜单保存

1. 玩家在 PBZModsMenu 修改菜单项。
2. PBZModsMenuBridge 接收 pending 文件并负责写入模组配置 JSON。
3. 当前游戏构建曾出现模组名编码文件名丢失 % 的情况；ad_menu_bridge.lua 只把 loose 名称镜像成 Bridge 期望的 exact 名称，并镜像 saved 确认文件。
4. Bridge 仍是菜单保存配置的所有者；shim 不解析、不重写配置 JSON。
5. 游戏循环内 menu_config.poll 每 1 秒检查配置文本；完整事件仅用来读取 Changed 序号，文件本身才是配置内容来源。

### Hotkey writes / 热键写入

menu_config.toggle 会先重新读取最新 JSON，只修改 perfect、parry 或 dodge，再通过本模块的写入器保存，避免覆盖刚由菜单写入的其他字段。

写入过程：
- 写到同目录 .ad-tmp 临时文件并关闭。
- 比较磁盘原文是否仍等于读取时的 expected 文本。
- 已存在目标文件时先重命名为 .ad-backup，再将临时文件重命名为正式文件。
- 重新读取正式文件并逐字节比较；不一致则尝试回滚备份。
- 写成功后保留上一份备份，下一次写入会先移除这个 adapter 自己的旧备份。

**并发边界：** 这不是跨进程锁或严格 CAS。读取比较与 rename 之间仍存在并发窗口；菜单保存和热键写入几乎同时发生时仍需实机验收。不要将文件替换描述为具备跨进程事务保证。

## 6. Legacy migration / 旧配置迁移

当前实现是一次性 **TXT → JSON 导入**，不是带 schema version 的迁移框架。

### First launch when JSON is absent / 首次 JSON 缺失

1. main.lua 先读取 auto_defense.txt，把已识别的旧键解析进内存 settings；文件缺失时使用源码默认值。
2. menu_config:load(true) 尝试读取 pbz-auto-defense.config.json。
3. 仅当 JSON 文件不存在（Windows 文件不存在错误码 2）时，适配器才从当前内存设置构造 46 个新 schema 字段。
4. 新字段经过相同校验后，编码为扁平 JSON 并创建配置文件。
5. 配置成功后，JSON 成为唯一权威来源；当菜单适配器已启用时，旧 saveSettings 不再写回 TXT。

旧 TXT 作为回滚副本保留，不会自动删除。首次迁移失败不会覆盖旧 TXT；失败原因会记录为配置错误。

### Existing JSON / JSON 已存在

- JSON 优先级高于 TXT；即使 TXT 中某个值不同，也会由 JSON 覆盖。
- JSON 缺少某个已知字段时，该字段在内存中补 schema 默认值。
- 1.6.6 之前的 JSON 不含 hook_counter / hook_counter_shachi / shield_counter / shield_counter_range：这四项按 schema 默认值补齐（off / 37 / off / 1500），所以升级后行为与 1.6.6 完全一致，无需手工迁移；下次菜单或热键保存时它们才写进文件。
- 未知扁平字段保留并记录一次 warning。
- 错误 JSON、类型错误、范围错误或跨字段不变量失败时，拒绝整份新配置并保留最后有效运行态；不会偷偷用 TXT 覆盖一个已经存在但损坏的 JSON。
- 运行中修复 JSON 后，下一次轮询可重新加载；Restart 字段仍只会在下次游戏启动时应用。

### No schema-version migration yet / 尚无版本化迁移

当前 JSON 不含 schema_version 字段，也没有旧 JSON key alias、字段重命名、删除字段转换或多版本升级步骤。未知字段只保留，不代表旧字段语义仍受支持。

未来要重命名或改变字段语义时，必须显式加入迁移步骤和测试；不能只修改 schema key 后期待旧用户 JSON 自动迁移。推荐流程：

1. 增加显式 schema version 或可判定的旧字段签名。
2. 复制原文件到独立备份（不复用临时写入器的短期 .ad-backup 作为版本档案）。
3. 逐版本把旧字段映射为新字段，处理单位/枚举变化。
4. 对迁移结果执行全部类型、范围和跨字段校验。
5. 原子写入新 JSON 并读回验证；失败时保留原配置和运行态。
6. 用旧版 fixture、新版 fixture、未知字段和损坏文件补充 tools/test_menu_config.lua。

## 7. 新增或修改字段的检查表 / Setting change checklist

每次配置 schema 变更应同步检查：

- [ ] Scripts/menu_config.lua：key、runtime field、kind、default、limits、restart、scale。
- [ ] pbz-auto-defense.modsmenu.json：key、type、default、restart、options/min/max/step。
- [ ] 描述符 label/help 同时提供 en 和 zh-Hans。
- [ ] Scripts/main.lua：初始运行值、旧 TXT parser、热应用副作用（如需要）。
- [ ] 本文：字段表、边界、单位、生效策略和迁移说明。
- [ ] tools/test_menu_config.lua：默认值、有效边界、非法输入、跨字段不变量、Restart/live 行为、JSON 保存与未知键。
- [ ] docs/MENU-INTEGRATION.md、README 中的字段数量和快捷说明。
- [ ] 运行 bash tools/run_all.sh；离线测试不替代原生菜单保存和实机防守验收。

## 8. 当前 schema 快照 / Current schema snapshot

当前配置 schema 为 **46 个字段**：**44 个可在原生菜单编辑**，dodge_attacks 与 data_off 两个自由文本字段菜单只读、需手动编辑 JSON。若代码和文档数字不一致，以 menu_config.lua 与 pbz-auto-defense.modsmenu.json 为准，并应修复本文及对应测试，而不是默默接受漂移。
