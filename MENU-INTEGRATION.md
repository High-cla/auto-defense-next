# PBZ Auto Defense 1.6.0 — 原生模组菜单接入

## 已确认的边界

保留 UE4SS Lua 防守运行时；原生 PBZModsMenu 0.9.8 负责配置 UI，已安装的 PBZModsMenuBridge 负责保存。没有迁移成 JavaScript，也没有复制 API 目录、修改菜单本体、原生加载器或其他模组。API 目录是作者文档和范例，不是要拷贝的运行库。

本轮对接的是 **UE4SS 原生配置协议**，不是 JS 模组加载协议。AD 菜单 id 为 `ue4ss/pbz-auto-defense`。

## 配置与迁移

- 唯一配置源：[pbz-auto-defense.config.json](<Mods/pbz-auto-defense/pbz-auto-defense.config.json>)；菜单描述：[pbz-auto-defense.modsmenu.json](<Mods/pbz-auto-defense/pbz-auto-defense.modsmenu.json>)。
- 首次缺 JSON 时，将原有 [auto_defense.txt](<Mods/pbz-auto-defense/auto_defense.txt>) 导入，之后不再同步写 TXT；已有 JSON 不覆盖。TXT 留作回滚。
- 当前配置已生成，保留了 perfect=false、dodge=red、parry=true、parry_reach=3、guard_release_after=1、guard_release_combat_end=1，热键 F7/F8/F9/F6。没有改成源码的 on/8/0+8 默认。
- 40 个 JSON 字段与描述符逐项对应，38 个菜单可编辑，2 个自由文本只读。原生菜单没有任意字符串编辑器，不能声称全部字段都能在菜单输入文本。
- `parry_lead` 分成 auto/manual 模式；手动值在 `parry_lead_seconds`。其余 `*_ms` 在 JSON/菜单用毫秒，内部转换为秒。
- 未知平面字段保留；非法 JSON、错误类型、越界数值和嵌套对象/数组拒绝应用并保留最后有效运行态，不偷偷覆盖坏文件。
- 首次迁移失败会显示 pending 状态并重试；在有效 JSON 可用前热键不回写坏配置。运行中恢复时仍不会热应用重启项。

## 参数生效表

“下次配置检查”是在已有游戏线程循环中、输入决策之前读取，名义间隔 1 秒。无额外异步线程；同一文本不重复解析。这里不是实测的墙钟延迟保证。

| `perfect` | 完美弹反 | 下次配置检查 |
| `perfect_mode` | 完美模式 | 重启游戏 |
| `black_flash` | 黑闪处理 | 重启游戏 |
| `dodge` | 闪避模式 | 重启游戏 |
| `parry` | 自动弹反 | 下次配置检查 |
| `parry_method` | 弹反输入方式 | 重启游戏 |
| `parry_reach` | 弹反距离（米） | 下次配置检查 |
| `guard_release` | 冲刺解除防守 | 下次配置检查 |
| `guard_release_after` | 静默解除防守（秒） | 下次配置检查 |
| `guard_release_combat_end` | 战斗结束静默（秒） | 下次配置检查 |
| `lang` | 提示语言 | 下次配置检查 |
| `hotkey_message` | 热键屏幕提示 | 下次配置检查 |
| `learn` | 学习新命中 | 下次配置检查 |
| `debug` | 详细诊断日志 | 下次配置检查 |
| `perf` | 性能日志 | 下次配置检查 |
| `read_frames` | 读取真实命中帧 | 下次配置检查 |
| `parry_lead` | 弹反提前量模式 | 下次配置检查 |
| `parry_lead_seconds` | 手动弹反提前量（秒） | 下次配置检查 |
| `dodge_lead_ms` | 闪避提前量（毫秒） | 下次配置检查 |
| `dodge_gap_ms` | 闪避间隔（毫秒） | 下次配置检查 |
| `dodge_iframe_ms` | 闪避覆盖窗（毫秒） | 下次配置检查 |
| `pair_frames` | 配对时间轴与真实帧 | 下次配置检查 |
| `receipt` | 检查输入回执 | 下次配置检查 |
| `receipt_retry` | 未收到回执时重试（实验） | 下次配置检查 |
| `latency` | 输入延迟自校准 | 下次配置检查 |
| `ledger` | 防守决策账本 | 下次配置检查 |
| `min_gap_ms` | 弹反最小间隔（毫秒） | 下次配置检查 |
| `grab_lead_ms` | 抓取提前量（毫秒） | 下次配置检查 |
| `dodge_cd` | 避免闪避动作重叠 | 下次配置检查 |
| `busy_skip` | 动作锁期间等待 | 下次配置检查 |
| `flurry_guard` | 连续攻击按住防守 | 重启游戏 |
| `pbzpd` | PBZPerfectDefense 防守让位 | 重启游戏 |
| `data` | 加载游戏招式数据 | 重启游戏 |
| `data_tags` | 使用招式要求标签 | 重启游戏 |
| `dodge_attacks` | 实验闪避关键字 | JSON 手动编辑 |
| `data_off` | 旧数据排除清单（当前无效果） | JSON 手动编辑 |
| `key_perfect` | 完美弹反热键 | 重启游戏 |
| `key_dodge` | 闪避模式热键 | 重启游戏 |
| `key_parry` | 自动弹反热键 | 重启游戏 |
| `key_snapshot` | 诊断快照热键 | 重启游戏 |

### 必须理解的例外

- F8 保留旧版即时切换闪避模式行为；菜单修改 `dodge` 则保守地等重启。其他装载期或共享防守状态项同样保守标重启，部分是风险策略而非 Lua 语法硬限制。
- F9 同时是模组菜单默认开启键，建议在 AD 菜单把 `key_parry` 改为 CTRL+F9 或另一键后重启。本轮没有擅自改变现有按键。
- `data_off` 在原 AD 中只有保存/读取，没有实际消费点；已修复其迁移解析错误，但没有假装它能过滤数据。
- `learn` 仅控制 learned_hits 的新学习；不是固定关闭的 LEARN 实验，也不会清空旧学习记录。
- parry off 取消 AD 的待发弹反、连续注入、旧回执，并在按键入口再次检查开关。不会无条件释放人工/PBZPerfectDefense 按住的防守；独立 perfect 与 dodge 开关不随之关闭。
- read_frames/receipt 切换清旧 FX/回执；DEBUG、弹反间隔和抓取提前量更新其缓存镜像。latency off 不再扣旧延迟样本；perf 切换重置统计。
- 热键先读取最新 JSON，仅改目标开关，保留菜单刚写的其他设置、待重启值及未知字段。写失败不会先改变运行态。

## 保存与事件

菜单经 Bridge 保存 JSON，然后写 `events-pbz%2dauto%2ddefense.txt`。AD 只消费完整事件的 Changed 序号；重复事件不重复应用。残缺事件不阻塞独立 JSON 校验轮询与手工修复。没有添加 action 行，故没有动作双通道去重复杂度。

AD 自己的热键写入先生成临时文件，比对读取时的原文，再执行带回滚的文件替换。Windows 上不能把这称为跨进程锁或严格 CAS：比对与 rename 之间仍有并发窗口，菜单/热键同时保存须现场验证。菜单自己的 Bridge 保存机制保持原样。

## 重新分析后的架构

`PBZModsMenu UI → 既有 Bridge → AD JSON → menu_config 校验/迁移/生效边界 → Lua 防守循环`

- [Scripts/main.lua](<Mods/pbz-auto-defense/Scripts/main.lua>)：保持游戏 API、命中预测、防守输入、已有主循环。
- [Scripts/menu_config.lua](<Mods/pbz-auto-defense/Scripts/menu_config.lua>)：统一配置边界、字段单位转换、待重启配置与运行配置分离、热键合并、恢复策略。
- [Scripts/ad_json.lua](<Mods/pbz-auto-defense/Scripts/ad_json.lua>)：限定平面 JSON 编解码；无其他模组 Lua 库依赖。
- 描述符：仅声明 UI，不夹带游戏决策；Bridge 不负责防守。

| 候选 | 收益 | 代价/结论 |
|---|---|---|
| 继续 TXT + 外部/自制设置 UI | 不改配置路径 | 重复造菜单与同步层；不满足原生接入目标 |
| **保留 Lua + 原生描述符/Bridge** | 复用既有部署与防守代码，隔离配置边界 | 依赖 Bridge，受菜单自由文本限制；本轮采用 |
| 全量移植 JS 加载器 | 单一 JS 运行环境，可用 JS 回调 | 需重写并验证大量 UE4SS API/防守时序；本轮未授权、无收益证据 |

推荐的演进顺序：先验证本轮配置边界和现场保存，再按真实故障/维护需求抽取防守模块或仲裁器。不要仅为菜单接入进行全量迁移。Lua chunk 曾触及 200 活跃局部变量上限；本轮保持新增功能在 do 块/模块中，编译通过。顶层 local 行计数不是可用槽位证明。

未确认事实：实战帧预算、全游戏状态兼容、Bridge 实际 GUI 保存、换图与共同按键持有场景。本报告不为这些给虚构性能分数或必然成功承诺。

## 验证证据与现场验收

离线验证：主脚本及两个新 Lua 模块 loadfile 通过；[tools/test_menu_config.lua](<Mods/pbz-auto-defense/tools/test_menu_config.lua>) 61 条断言通过；隔离临时目录的 [tools/test_integration.lua](<Mods/pbz-auto-defense/tools/test_integration.lua>) 25 条计数断言通过（整文件装载、无玩家 tick、迁移、镜像/清理、待重启值、热键合并、TXT 不变）。测试使用 UE4SS 桩，不等于 UE4SS 游戏运行或 GUI 验证。

测试调试过程中曾在实装目录运行离线加载并生成初始 JSON；该次日志是桩化加载记录，**不可视作实战证据**。随后给集成测试加入专用测试目录标记，最终在隔离副本通过。原 TXT 的 SHA-256 与备份一致，旧用户配置未丢。

建议现场验收：
1. 重启游戏，打开系统设置 → 模组菜单，找到“PBZ 自动防守”。若行只读，确认既有 Bridge 真正加载而不仅仅是文件存在。
2. 改 `parry_reach` 为临时测试值，检查 JSON 已保存，再恢复原值；检查运行日志没有 menu config error。
3. 改 `key_parry` 为 CTRL+F9，确认日志标 restart required，重启后验证新按键；旧 F9 的菜单冲突应消失。
4. 切换 parry/read_frames/receipt，确认停用后不发陈旧弹反；更换地图、角色、死亡复活后再验证。
5. 在 PBZPerfectDefense AutoGuard 开启时测试蓝/红/黑闪/抓取；检查 AD 不抢对方防守。pbzpd 的 AD 策略改变需重启。
6. 检查菜单保存与热键接近同时触发的结果，不拿离线 mock 当并发保证。

## 回滚与更新

精确改前备份：[Scripts/main.lua.bak-before-menu-1.6.0](<Mods/pbz-auto-defense/Scripts/main.lua.bak-before-menu-1.6.0>)、[auto_defense.txt.bak-before-menu-1.6.0](<Mods/pbz-auto-defense/auto_defense.txt.bak-before-menu-1.6.0>)。关闭游戏后恢复它们，可回到本轮接入前的 Lua/TXT；JSON 和描述符可移出 AD 目录以隐藏本轮菜单配置。不要覆盖其他模组或重新打包菜单/加载器文件。

发布时只打包自己的代码、描述符和文档；不要把本机生成的用户 JSON 当默认文件随更新覆盖，也不要打包运行日志/备份/测试临时目录。
