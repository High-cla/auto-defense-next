# PBZModsMenu 菜单 API 参考

写给**接入菜单的模组作者**。内容由菜单自带的作者文档（Mods Menu 0.9.8 的 `api/ExampleMod-FOR-MOD-AUTHORS.md` 与 `api/ExampleMod-README.md`）整理而来，并逐条对照本机实现
`ProjectPBZ/Content/JavaScript/PBZModsMenu/Mods/PBZModsMenu/main.js` 核对过行号。上游原始文档随菜单下载分发，不在本仓库里。

> 本文描述的是**菜单的契约**，不是本模组的实现。本模组如何对齐这些契约，见 [MENU-INTEGRATION.md](MENU-INTEGRATION.md) 与 `Scripts/ad_menu_bridge.lua`。

## 1. 菜单做什么、不做什么

- 在游戏自己的设置面板末尾加一个 **Mods Menu 标签页**。标题界面和游戏内 System 菜单都能进。
- 每个注册的模组得到一个分区：一行标题、每个设置一行、一行 Restore defaults。行是游戏原生设置行，键鼠与手柄行为一致。
- 菜单**只改设置文件，然后通知模组**；模组自己读文件、自己决定何时生效。
- 不写模组的进程内状态、不调用模组的函数（JS 路线除外：`run`/`onChange`/`check` 由菜单在游戏线程调）。
- 覆盖游戏脚本的 pak 在 2026-11-04 之后的版本会被游戏拒绝（标题界面坏掉），只能走 JS 路线。

## 2. 两条接入路线

| | JavaScript 模组 | UE4SS Lua 模组 |
|---|---|---|
| 位置 | `ProjectPBZ/Content/JavaScript/PBZModsMenu/Mods/<Id>/main.js` | `PBZ/platform/<store>/ue4ss/Mods/<ModName>/` |
| 声明方式 | `(globalThis.PBZModsMenu ||= []).push({...})` | 描述符文件 `<ModName>.modsmenu.json` |
| 设置文件 | `Paks/~mods/<file>`（`.txt`/`.ini`），或 `store:"saved"` 时 `Saved/PBZModsMenu/Settings/<file>` | `<ModName>.config.json`（扁平 JSON） |
| 能用的字段 | 全部，外加 `run`/`onChange`/`check`（函数） | 全部，除上述三个（JSON 里放不了函数） |
| 生效方式 | 菜单在游戏线程回调，或模组自己轮询 | 控制台命令 + `events-<enc>.txt` 事件文件 |

两条路线的 settings 字段描述完全相同。

## 3. 目录、加载与关闭

- 菜单本体是 `ProjectPBZ/Content/JavaScript/PBZModsMenu/Mods/PBZModsMenu/main.js`；原生 loader 是 `platform/<store>/hid.dll`（0.6.0 起，0.5.x 是 `version.dll`）。
- 每次启动扫描 `Mods` 目录，结果写 `PBZModsMenu/discovered.txt`（不要手改，也没有 manifest 要交）。
- 文件夹名规则：首字母开头，其余 `[A-Za-z0-9_-]`，≤64 字符，忽略大小写唯一；`main.js` 必须是真文件（不能是链接/junction）、严格 UTF-8、≤4 MiB。
- 单个坏文件夹不再拖垮其它（0.5.4 起）：loader 跳过它并在日志写 `skipped folder in Mods` 与原因。多于 128 个条目（含菜单）或菜单自身缺失/损坏时**整体不安装**（`not installed, game unchanged`）。
- 启动顺序：游戏 MainStart → 菜单 → 其它文件夹按名字顺序（大写在小写前），用 `require("PBZModsMenu/Mods/<Id>/main")` 在游戏线程加载。
- 一个条目在 `require` 不抛异常时算启动成功；想让日志显示 `loaded <Id>`，末尾写 `exports.ready = true` 或 `globalThis.__PBZLoaderEntries["<Id>"] = "loaded"`。
- 日志：`%LOCALAPPDATA%\ProjectPBZ\Saved\PBZModsMenuLoader-log.txt`（loader）、`PBZModsMenu-log.txt`（菜单，保留 200 行，main.js:318）。
- 玩家关闭某个模组：在 `Paks/~mods/PBZModsMenuLoader.txt` 写 `<Id>=Off`（或 `0`/`false`/`no`）；`[loader] Enabled=Off` 关掉全部。菜单自己有一行 "Load at next start" 分区（id `PBZModsMenuLoader`）会写这个文件。
- 热重载（0.7.0 起，默认关）：`[loader] HotReload=On` 后按 **左 Ctrl+F5** 在游戏内重载；每个模组最多 64 次/会话；`stop()` 是导出函数，返回 Promise 时最多等 5 s；失败/超时的模组本次会话不再重载。

## 4. settings 字段表

| 字段 | 必需 | 说明 |
|---|---|---|
| `key` | 是 | 设置文件名。字母、数字、`_` |
| `type` | 是 | `toggle` / `choice` / `number` / `key` / `action` / `heading` |
| `label` | 是 | 行标题 |
| `help` | 否 | 焦点时右侧详情面板里的说明 |
| `default` | 是（`action`/`heading` 除外） | 新文件与 Restore defaults 用的值 |
| `options` | 仅 `choice` | `[{value,label}, ...]`；文件存 `value`，行显示 `label`。txt 里值不能含 `;` 或 `#`（会被当注释） |
| `min`/`max`/`step` | 仅 `number` | 左/右按 `step` 步进并停在 `min`/`max`；按住加速 1→2→5 步；拖动吸附到网格 |
| `slider` | 否 | `number` 同时有 `min`/`max` 时画成滑条；`false` 强制箭头；`choice` 在所有 option 值都是数字（至多一头是词）时画成滑条 |
| `restart` | 否 | `true` 时 help 末尾加 "Applies after a restart"，**只是文案**，不改任何行为 |
| `image` | 否 | 详情面板配图，`/Game` 路径的贴图，533×300 显示框（做 16:9）。加载失败只记一次日志 |
| `run` | JS only | `action` 行被确认时调用 |
| `onChange` | JS only | 每次保存后调用 `(key, value)` |
| `check` | JS only | `(values) => { key: reason }`，给行加警告行 |

## 5. 各 type 落盘的值

| type | 写入文件的值 |
|---|---|
| `toggle` | txt：`On`/`Off`；JSON：`true`/`false` |
| `choice` | 选项的 `value` 原文。读回时先精确匹配，再在只有唯一候选时容忍大小写/数字写法差异（`2.0` ↔ `2`） |
| `number` | 按 `step` 的小数位四舍五入，去掉尾零（`1.50` 写 `1.5`） |
| `key` | 引擎键名（`F5`、`PageUp`、`NumPadZero`）或 `None` |
| `action` | 什么都不写；结果在行上显示 3 s |
| `heading` | 什么都不写；分区内的分组标题（0.9.8 起可按确认折叠） |

`key` 行可选键受游戏限制：None、F1–F9、F12、PageUp/PageDown/Home/End/Insert/Delete、NumPadZero–NumPadNine（除 NumPadThree）、Multiply/Add/Subtract/Decimal/Divide、G/H/J/L/N/U/Y/Zero/Nine。**上游建议 key 行的 default 不要用 F9**（菜单自己默认用 F9 打开标签页）。本模组目前 `key_parry=F9`，如实测与开页冲突，改 `key_parry` 即可。

## 6. 多语言文本

`title`/`description`/`label`/`help`/选项 `label`/`check` 理由/`run` 返回的字符串，都可以写成按语言的表：

```json
{ "en": "Damage multiplier", "zh-Hans": "伤害倍率", "zh-Hant": "傷害倍率" }
```

- 语言码：`en`、`de`、`es-419`、`es-ES`、`fr`、`it`、`ja`、`ko`、`pt-BR`、`pt-PT`、`ru`、`th`、`vi`、`zh-Hans`、`zh-Hant`；另有 `zhHans`/`zh-CN`、`zhHant`/`zh-TW`、`es`、`pt`、`de-DE` 之类别名。同语言同时给码与别名时**码优先**。
- `en` 必需；没有 `en` 视同没写该字段。
- 显示顺序：菜单语言的你的文本 → 菜单内置词表里与你英文完全相同的条目（On/Off 之类自动翻译）→ 你的英文。
- 设置文件永远存 `value`，不存 label。

## 7. 设置文件

### 7.1 txt（`Paks/~mods/<file>`）

```ini
; My Mod settings. Change a value and save; the game picks it up within 2 seconds.
Enabled=On
Damage=1.5
Mode=Normal
```

- 一行一个 `Key=value`，`;` 开头是注释行。菜单只改 `Key=` 之后的文本；注释、行序、行尾符与它不认识的键都保留；UTF-8 BOM 被丢弃。
- 缺键追加到末尾；文件不存在时用默认值新建（首行注释）。
- 玩家能手改，所以**一切值都当不可信**：数字要 clamp，读不懂就回退默认。

### 7.2 Saved 目录（`store: "saved"`，0.8.0 起）

- 路径 `%LOCALAPPDATA%\ProjectPBZ\Saved\PBZModsMenu\Settings\<file>`。
- 首次注册时若 `~mods\<file>` 存在则复制过去，**读回逐字节相同**才作数，并写标记文件 `~copied-<file>`；从此只读写 Saved 那份，永不移动/删除 `~mods` 原件。
- 复制失败则继续用 `~mods`，下次启动再试；没有标记的 Saved 文件永远不赢过 `~mods`。
- 模组必须读"菜单实际用的那份"：用 `PBZModsMenu.values(id)` 或 `settingsPath(id)`，不要自己拼 `~mods` 路径。

### 7.3 UE4SS 的 `<ModName>.config.json`

- 扁平 JSON 对象，值只有 bool/数字/字符串；菜单保存时键序与空白可能变。菜单保留它不显示的键。
- **默认不要随包发布这个文件**（会覆盖玩家设置）；模组自己缺文件时按默认值创建，之后菜单负责写。

## 8. 变更与动作事件（UE4SS 路线）

菜单同时用两种方式通知：

1. **控制台命令**（仅在 hook 了游戏控制台的 UE4SS 构建上可用）：
   `ModsMenuChanged_<enc> <n>`、`ModsMenuAction_<enc> <key> <n>`
2. **事件文件**（所有构建都可用）：`Mods/PBZModsMenuBridge/events-<enc>.txt`

`<enc>` 的编码规则：`[A-Za-z0-9_]` 原样，其它每个字节变 `%xx`（小写），所以 `My-Mod` → `My%2dMod`。

事件文件格式（CRLF，`;` 注释，最后一行 `End=1`；没有 `End=1` 表示还在写，下次再读）：

```ini
; Mods Menu events for MyMod: numbers only grow, one per event.
Changed=1761998400123
Action=1761998412345 UnlockAll
Action=1761998413020 UnlockAll
End=1
```

- 编号单调递增，两种投递带**同一个编号**，所以按编号去重：change 只看大于已处理的最大值；action 要记已执行的编号（控制台命令可能先到或后到）。
- 文件最多保留最新 16 条 action；模组把已处理的最大编号写进 `done-<enc>.txt` 的 `Action=<n>`，菜单下次写文件时丢掉这些。
- 菜单写文件在 config 落盘之后，所以读事件时新值已在文件里。

## 9. 桥（PBZModsMenuBridge）的写盘契约

游戏脚本写不了 `<Name>.config.json`——EasyCsv 只写"一个点"的文件名（`X.config.json` 曾写成 `X.json`，main.js:306-311）。桥是**唯一写入者**：

1. 菜单把整份配置发到 `Mods/PBZModsMenuBridge/pending-<enc>.json`，首行 `Save=<id>`，正文是设置 JSON（main.js:1496）。
2. 桥只认`<enc>`名、要求文件以 `\r\n` 收尾、目标 config 已存在；写入方式：写 `.new` → 校验 → 删旧 → rename（原子替换，从不覆盖原文件）。
3. 桥写确认 `saved-<enc>.txt`：注释行 + `Save=<id>` + `End=1`。
4. 菜单用 `250 ms × 8 次`（约 2 s）等这个确认；等不到就把值退回去并在 `PBZModsMenu-log.txt` 记 `settings not saved`，同时把事件发出去。

由此推出两条硬约束：

- **名字必须逐字节对上**：桥按 `encodeName` 拼路径，磁盘上真名若丢了 `%`（`pending-pbz2dauto2ddefense.json`），桥永远不匹配。本仓库用 `Scripts/ad_menu_bridge.lua` 在模组侧做名字镜像垫片（见 MENU-INTEGRATION.md）。
- **没有桥时 UE4SS 模组的设置是只读行**，但 action 行仍会发控制台命令。

## 10. JS 侧 API 对象

```js
const api = globalThis.PBZModsMenu && globalThis.PBZModsMenu.api; // 0.8.0 之前为 undefined
api.version   // 2（0.9.8）；0.8.0–0.9.7 为 1
api.features  // 冻结数组
api.has("toast") // 按名字判断，不按版本号
```

现役 feature 名（main.js:69）：`push`、`value`、`open`、`values`、`settingsPath`、`store.saved`、`hub.keybind`、`toast`。

| 函数 | 语义 |
|---|---|
| `PBZModsMenu.push(reg)` | 注册一个分区（见字段表） |
| `value(id, key)` / `values(id)` | 读菜单持有的值（含尚未落盘的改动）；未知 id/键返回 `undefined`。每次调用都读文件，别每帧调 |
| `settingsPath(id)` | 该模组实际使用的设置文件全路径；hub 模组返回 `undefined` |
| `open(id)` | 打开设置面板并跳到该模组分区；成功 `true`，不能开时 `false`（不在过场/战斗/对话/其它菜单里） |
| `toast(text)` | 0.9.8 起的短提示；按菜单语言取词，截 200 字符；从不向模组抛异常 |

UE4SS 模组在菜单里的 id 是 `ue4ss/<ModName>`；菜单自己的行用 `PBZModsMenu`。

## 11. 失败可见性

| 现象 | 去哪看 |
|---|---|
| 分区末尾 "Not shown" + 原因 | 菜单标签页末尾；同一行也进 `PBZModsMenu-log.txt` |
| 描述符无法使用的原因 | `file ../MyMod.txt`、`no usable setting (Damage: default 9)` 之类 |
| 保存失败 | `PBZModsMenu-log.txt` 的 `settings not saved` |
| 要玩家提供诊断 | 菜单自己的 "Write support report" 行写 `Saved/PBZModsMenu-report.txt`（版本、语言、每个 loader 条目状态、每个分区、Not shown 列表 + 三段日志尾部；路径里的用户名/SteamID 会被脱敏） |

## 12. 已知坑（都踩过或核对过）

| 坑 | 事实 | 规避 |
|---|---|---|
| EasyCsv 只写一个点 | `X.config.json` 会写成 `X.json`（main.js:306-311） | 所有要写的文件名只留一个点；桥就是为此存在 |
| EasyCsv 不读 ≤10 字符的文件 | 读回文本可能为空 | 新文件/日志首行永远写一条注释行 |
| 注释行必须留 | 玩家手改后文件可能只剩 `A=1` | 写入时始终带首行注释 |
| 文件名必须匹配 | 菜单/桥按 `encodeName` 拼路径 | 不要自己拼；用 `settingsPath` 或垫片 |
| `;` 与 `#` | txt 里是注释起始，值里不能含 | 值里需要就改用 JSON 路线 |
| 大小写唯一 | 文件夹名忽略大小写唯一，冲突时**全部跳过** | 一个 id 只放一份 |
| 128 上限 | 含菜单最多 128 个条目 | 不要给每个变体建文件夹 |
| `restart` 只是文案 | 菜单不会替你重启或重载 | 模组自己要读启动时的值 |
| `key` 行默认值 | 上游建议避开 F9 | 本模组 `key_parry=F9`，若冲突改配置 |

## 13. 本仓库的对齐实现

本模组是 UE4SS 路线 + 桥。仓库里相关的三处：

- `pbz-auto-defense.modsmenu.json`：41 行描述符（38 可编辑 + 3 只读/文本行），`default` 与 `Scripts/main.lua` 的 `settings` 初值、`pbz-auto-defense.config.json` 三处同源。
- `Scripts/menu_config.lua`：描述符 → 配置读写的适配层（1 Hz 轮询、热更新、跨字段不变量、未知键只报一次、写盘后回读校验）。
- `Scripts/ad_menu_bridge.lua`：`encodeName` 折叠名镜像垫片（`pending-<loose>.json` ↔ `pending-<exact>.json`、`saved-<exact>.txt` → `saved-<loose>.txt`），不改菜单也不改桥。

实机核对（2026-11-17）：`auto_defense_log.txt` 出现 `menu bridge shim: queued …` 与 `copied the bridge's confirmation …`，`config.json` 被桥改写（905 → 913 B），菜单保存落地。

## 14. 核对记录

| 结论 | 依据 |
|---|---|
| feature 名单与 `api.version = 2` | `Mods/PBZModsMenu/main.js:69`、`:760` |
| `toast` / `settingsPath` 实现 | main.js:764、:766 |
| 一个点写入限制 | main.js:306-311、`:1496` |
| 事件文件写法 | main.js:1620 |
| 菜单日志保留 200 行 | main.js:318 |
| 描述符文件名与 config 文件名 | main.js:876、:890 |
| `file` 字段只允许 `.txt`/`.ini` | main.js:672 |
| `saved` 确认与 2 s 超时 | main.js:1511-1549、`:76` |

上游原文若与本文冲突，以**本机 main.js 行为**为准，并回来改这张表。
