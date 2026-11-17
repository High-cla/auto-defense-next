# Phantom Blade Zero USMAP 工具链指南

> 本文说明 KintaroModding/phantombladezero_pbzusmap 的数据模型、脚本职责、构建流程、合并规则、质量检查和适用边界。USMAP 是开发期反射映射文件，不是 PBZ Auto Defense 的游戏内 Lua API，也不是每帧运行时依赖。

## 1. USMAP 的用途和边界

USMAP（Unreal Mapping file）用于把名称、类型、结构体属性、枚举及其关系映射到可供反射/资产解析工具使用的 schema。它主要解决“一个包中的字段是什么类型、结构体如何排列、枚举名称和值如何解释”等开发期问题。

对于 Phantom Blade Zero，USMAP 工作流可帮助 MOD 作者：
- 查找 PBZ native 模块中的类/结构/枚举；
- 理解 Blueprint 类型的字段和父类；
- 核对 DeflectComponent、AbilityInputComponent、Gameplay Ability 和输入相关结构；
- 在游戏更新后比较类型覆盖、结构差异和遗漏；
- 为生成 SDK、资产检查、游戏数据分析提供映射基础。

USMAP 不等于 Lua 可调用的 API 注册表，不证明 UFunction 一定存在或可被 UE4SS Hook，不证明某个方法已在当前游戏场景中成功调用，也不是一组可硬编码到游戏进程的地址。

PBZ Auto Defense 当前直接使用 UE4SS Lua 反射对象访问。它不需要在每帧读取 .usmap，也不应将外部进程扫描脚本塞进发布 ZIP。USMAP 只帮助开发者理解和核对游戏 schema。

## 2. 工具仓库结构

上游：KintaroModding/phantombladezero_pbzusmap

| 路径 | 职责 | 输出/输入 |
|---|---|---|
| src/usmap_io.py | USMAP 读写器与 schema 数据类 | .usmap ↔ 内存模型 |
| src/process_memory.py | 只读进程枚举/内存读取基础设施 | 供 live dumper 使用 |
| src/usmap_live.py | 从正在运行的 PBZ 进程采集当前加载类型 | live/native .usmap |
| src/usmap_offline/ | C# / CUE4Parse 包类型读取器 | 每个类型一行 JSONL |
| src/usmap_offline.py | 将 JSONL 转换为 USMAP | packages.usmap |
| src/usmap_merge.py | 合并 native、live、package 映射 | full .usmap + merge report |
| src/usmap_quality.py | 对多个映射文件测覆盖/完整性/一致性 | quality report |
| tests/test_usmap.py | 文件格式、转换、合并与地址查找测试 | 离线测试 |

该工具链分为两类采集：
- Live：只能看到当前游戏进程当时已加载的对象/类型，适合获得动态 Blueprint 和 transient 类型。
- Offline：从游戏 Paks 的包资产中枚举/读取类型，不要求相应 Blueprint 已在当前游戏地图加载，但依赖正确游戏包、AES Key、Oodle 和 CUE4Parse 工具链。

最终完整 mapping 通常由 native dump、可选 live dumps 与 offline package types 合并而成。

## 3. PBZ 的特殊反射布局

PBZ 使用的引擎基于 UE 5.7，但游戏的部分反射结构布局相对通用 UE5.7 模板有定制差异。上游 README 明确记录：
- UStruct 的 ChildProperties 后方增加了 0x50 字节。
- FField 的 Next 和 Owner 字段位置互换。
- FFieldClass 名称位于 +0x30。
- 某些 EnumProperty 没有关联的 UEnum，游戏实际把它当作底层数字类型存储。
- GUObjectArray 与 FName block table 会随游戏构建移动，不能使用旧 build 的固定绝对地址。
- UE4SS 上游为 PBZ 增加了对应兼容修正；相关问题/PR 在 UE4SS-RE/RE-UE4SS #1483、#1484。

不要把一般 UE5.7 内存偏移抄入 PBZ 工具，更不要把工具里的地址常量搬入 Auto Defense。上游 live reader 会通过游戏 EXE 签名和当前进程查找相关全局结构；签名无法唯一匹配时应停止采集并报告版本不兼容，而不是继续猜测地址。

上游 README 标示已针对 Steam build 26266538 与 26367565 的相同结构布局进行支持。新的游戏更新仍须重新核验签名、字段布局和 build。

## 4. 映射文件格式

### 4.1 USMAP 基础内容

src/usmap_io.py 实现 USMAP 二进制读写，类型数据结构包括：
- Enum：枚举名称、数值和成员名称；
- Struct：类型名、父类型、属性列表、包路径、结构种类与 flags；
- Prop：属性 index、array_dim、名称、属性类型 tuple 和 flags；
- Usmap：版本、Enums、Structs、extensions、null-name 计数与文件大小。

工具识别的属性类型包括 Byte、Bool、Int、Float、Object、Name、Delegate、Double、Array、Struct、Str、Text、Interface、MulticastDelegate、WeakObject、LazyObject、SoftObject、UInt64/32/16、Int64/16/8、Map、Set、Enum、FieldPath、Optional、Utf8Str、AnsiStr。

容器类型递归携带内部类型：Array<T>、Set<T>、Optional<T>、Map<K,V>、Struct<Name>、Enum<UnderlyingType, EnumName>。

### 4.2 文件版本和扩展

当前 writer 生成 USMAP v4，使用未压缩数据，并按照 UE4SS 写出方式包含扩展块：

| 扩展 | 作用 |
|---|---|
| CEXT | 显式枚举值扩展头信息 |
| PPTH | 枚举和 struct/class 的包/类型路径 |
| EATR | enum flags、struct/class flags、property flags |

读取器支持版本 0–4。当前实现遇到 compression method 非 0 会拒绝读取，不能假定任意第三方压缩 USMAP 都能直接读。

缺失名称索引（0xFFFFFFFF）用于表示缺失名称。读取器会把无效 name index 转换为 None 并统计 null_names。合并器还会处理一些读写器不友好的悬空引用，确保输出中的引用更可读。

### 4.3 名称规则与 schema 对齐

Unreal FName 忽略大小写比较；工具在 merge 时会将属性名称和类型名做不区分大小写的 schema 比较。部分枚举成员使用 Foo::Bar 形式，USMAP 名称规范化会从第一个 :: 之后截取最终枚举项名。

属性 schema index 是 array_dim 的累计值。若一个字段数组维度为多元素，其后字段的 schema index 需按元素数量递增，不是简单按字段个数加 1。

## 5. 从游戏/包中采集类型

### 5.1 Live dump

usmap_live.py 从正在运行的 PBZ 游戏进程读取 UObject、UStruct、FField、UEnum 等反射信息。README 记录它仅申请 PROCESS_VM_READ 和 PROCESS_QUERY_INFORMATION，不向目标进程写内存。

用途：
- 采集当前地图已经加载的类型；
- native-only 模式下只采集 Native 类型；
- 普通 live 模式增加当时加载的 Blueprint 类型和动态类型；
- 用当前游戏构建定位 GUObjectArray 与 FName block table。

命令示例：

~~~powershell
python -I src/usmap_live.py <PBZ.exe-path> native.usmap --native-only
python -I src/usmap_live.py <PBZ.exe-path> current-live.usmap
~~~

第二条命令在目标游戏运行时执行。工具必须匹配唯一的 GUObjectArray signature，并找到有效 FName block table；无法唯一匹配时会退出并要求检查游戏构建。

Live dump 的限制：
- 只反映采集当时已加载的对象/类型；
- 地图和加载顺序会影响 Blueprint 覆盖；
- live dump 不是所有游戏包 Blueprint 的完整清单；
- 目标进程关闭、权限不足、模块名不匹配或签名变化都会失败；
- 采集后的 .usmap 仍要与 native/offline mapping 比较。

### 5.2 Offline package dump

src/usmap_offline/ 是 C# console tool，基于 CUE4Parse 读取 Paks 中的 class、struct 和 enum exports，输出 JSONL，每行一个类型记录。

然后使用：

~~~powershell
python -I src/usmap_offline.py dist/work/packages.jsonl dist/work/packages.usmap
~~~

Offline dump 的优点是能读包内未加载的 Blueprint 类型。缺点是依赖正确的游戏 Paks 路径、对应版本 AES Key、Oodle DLL、兼容的 CUE4Parse/.NET 环境以及构建脚本/解析器版本。

CUE4Parse 读取包内容与 live reader 读取当前运行进程是两套途径，产物应分别保留，便于分析两种来源的差异。

## 6. 多来源合并规则

usmap_merge.py 合并 native、live 和 package mapping。合并规则并非简单覆盖：

1. 类型按名称去重；Unreal 名称比较不区分大小写。
2. 若同名候选中存在 /Script/ native 类型，优先 native。
3. 若都是 asset 类型，选择在最多输入文件中出现的 schema。
4. 数量相同时，优先属性更多的 schema；仍相同时保留输入顺序中先出现的类型。
5. schema 冲突列入 .merge.txt 报告，不应静默认为冲突不存在。
6. 合并最后一轮修复悬空引用：未定义的 EnumProperty 退化为其底层数字类型；缺失 struct name 写为 None；super type 不存在的类型会被剔除并记录。
7. 输出重新写成 USMAP v4，并附 PPTH/EATR。

建议把 native dump 放在第一位，随后传入 live dump 和 package dump；第一个输入文件也决定输出的基础类型顺序。

命令：

~~~powershell
python -I src/usmap_merge.py full.usmap native.usmap live-a.usmap live-b.usmap packages.usmap
~~~

一定保留生成的 .merge.txt。出现 schema conflict 时，应先核查来源 build、包版本、类型是否动态变更，不应只看“输出文件写成功”就判定合并质量正确。

## 7. 质量和一致性检查

usmap_quality.py 用于比较一组 mapping file，主要分析每个 mapping 的类型数量、文件内部完整性、类型覆盖率、Blueprint 覆盖（根据给定游戏文件列表）和 schema 一致程度。

命令：

~~~powershell
python -I src/usmap_quality.py <retoc-file-list> native.usmap live.usmap full.usmap
~~~

file list 是 retoc list --path 的游戏容器文件列表。质量比较的用途是量化映射文件差异，不是检验每个 UFunction 都可通过 Lua/PuerTS 调用。

建议比较：
- native dump vs live dump；
- native + live vs offline package types；
- merge 前输入与 merge 后 full mapping；
- 当前 build 与新 build 的 mapping 版本。

覆盖数量上升时，还要检查冲突类型、缺失父类、未解析属性和无法解码字段；覆盖率高不必然意味着所有类型都正确。

## 8. 完整构建与单步执行

### 8.1 build.ps1

完整构建脚本执行：
1. dotnet build 编译 offline C# reader；
2. 解析 Paks 输出 packages.jsonl；
3. 把 JSONL 转换成 packages.usmap；
4. 合并 native dump、live dumps 和 package types；
5. 执行输出映射与 quality/报告流程；
6. 生成 dist 下的 USMAP ZIP 和 SHA256SUMS.txt。

示例（路径使用 Windows 正斜杠形式，PowerShell 可接受）：

~~~powershell
powershell -ExecutionPolicy Bypass -File ./build.ps1 -PaksDir <game>/ProjectPBZ/Content/Paks -AesKey <key> -Native <native.usmap> -Oodle <oo2core_9_win64.dll> -Live <dump1.usmap>,<dump2.usmap> -Dotnet <dotnet.exe>
~~~

Live 参数可选，允许把当前运行游戏的 Blueprint/dynamic types 加入 package/native mapping。

### 8.2 依赖

上游 README 当前列出的构建依赖：
- Windows PowerShell 5.1；
- Python 3.11 或更高；
- .NET 10 SDK（README 中 CUE4Parse 版本目标 net10.0）；
- Oodle oo2core_9_win64.dll；
- 游戏 Paks；
- 正确 AES Key；
- native .usmap。

这些是开发期完整生成映射的要求，不是玩家安装 PBZ Auto Defense 的要求。

### 8.3 单步运行

| 目标 | 命令 |
|---|---|
| native live dump | python -I src/usmap_live.py <exe> native.usmap --native-only |
| offline package read | usmap_offline.exe <Paks> <AES key> <native.usmap> <Oodle DLL> <out.jsonl> |
| JSONL → USMAP | python -I src/usmap_offline.py <in.jsonl> <out.usmap> |
| merge mappings | python -I src/usmap_merge.py <out.usmap> <in1.usmap> [in2.usmap ...] |
| quality report | python -I src/usmap_quality.py <file list> <a.usmap> <b.usmap> ... |

单步执行适合定位是包读取、转换、合并还是覆盖质量环节失败；生产级映射建议保留整个 build.ps1 流程与中间产物。

## 9. 测试、产物和可复现性

离线测试：

~~~powershell
python -I tests/test_usmap.py
~~~

上游测试覆盖 usmap_io.py、usmap_offline.py、usmap_merge.py，以及 usmap_live.py 的地址定位逻辑；它不要求启动游戏作为测试前提。

可复现性方面：
- offline JSONL 的并行读取可能无固定顺序，转换脚本会排序 package/type/class，确保相同输入可产生稳定输出；
- merge 输出保留输入类型顺序；
- 保留原始 JSONL、native/live dumps、merge report 和 SHA256SUMS；
- 记录源文件版本、工具版本、Paks build 和 EXE SHA。

不能只保留最终 .usmap 而删除输入：出现 schema 差异时，缺少来源文件会显著增加排错难度。

## 10. 与 PBZ Auto Defense 的开发流程

推荐的使用顺序：

1. 先从 SDK/反射声明定位 DeflectComponent、AbilityInputComponent、AbilitySystem 及相关结构。
2. USMAP 核验字段：确认类型名、字段名、属性类型、容器内层类型、父类路径。
3. 与 PBZModLoader SDK 对照：检查函数签名及当前 build 的验证等级。
4. 在 UE4SS Lua 环境探测：确认 StaticFindObject/属性路径/RemoteUnrealParam 和函数调用形式。
5. 最后才做行为变更：新增运行逻辑、测试输入和 ledger，使用 feature flag 保留回滚。

特别注意：
- USMAP 证明的是 schema 信息，不是 Lua binding 行为。
- SDK 函数签名也不等于 UE4SS Lua out-parameter 转换行为。
- 读取进程内对象的外部工具不会自动给游戏线程同步语义。
- 不应把 USMAP 中的字段偏移写入 Lua，也不应在模组中用 process_memory.py 扫描游戏。

对 Auto Defense 的价值主要是反射核对和新版本迁移：
- DeflectComponent.ReceiveFrames、SendFrames 的元素类型；
- DeflectReceiveFrame / DeflectSendFrame / DeflectResultData 字段；
- AbilityInputComponent 的状态属性和方法；
- GameplayTag、InputAction、Ability class 等引用类型；
- 新游戏版本是否改了字段/父类/枚举定义。

## 11. 安全、版本和常见失败

### 11.1 AES Key 和游戏包

完整 offline dump 需要 AES Key。不要将个人/共享 AES Key 提交到公开仓库、issue、README、日志或发布 ZIP；只在本机受控环境使用。命令行参数有可能出现在本地 shell 历史或进程命令行列表中，按本机安全策略管理。

USMAP 工具的 live reader 只读打开目标进程；不要把它改成写进程内存的工具。不要将外部采集工具当作 Auto Defense runtime code。

### 11.2 常见失败

| 症状 | 可能原因 | 下一步 |
|---|---|---|
| GUObjectArray signature 匹配 0 次 | 游戏 build 更新/签名变化/EXE 路径不对 | 确认 EXE build，更新签名并保留失败日志 |
| signature 多次匹配 | 签名不再唯一 | 停止采集，修正 pattern，不要选第一个继续 |
| 找不到 FName block table | 布局/权限/构建变化 | 确认模块映射和 writable section |
| 某 struct 被排除 | 属性链读取不稳定或字段中断 | 检查报告中的 struct left out |
| EnumProperty 没有 enum | 游戏数据本身缺 UEnum 指针 | 按底层数字类型解释并记录 |
| merge conflicts 增多 | 输入来源不同 build 或类型定义变更 | 逐项检查 merge report |
| output mapping 无法读取 | 压缩/版本/扩展格式不支持 | 核对 USMAP version 与 compression |
| 质量覆盖提升但 SDK 仍缺类型 | 类型未被 SDK 捕获/加载或生成规则排除 | 对照 type-index/generation-report，不直接推断 |

### 11.3 版本标记必须成组记录

一次有效对比至少记录 Steam build number（例如 26367565）、EXE build 字符串（例如 CL-302256_JKS-17280）、EXE SHA-256、Engine version、native/live/offline mapping 生成日期、PBZModLoader SDK 版本和 UE4SS 构建版本。

只写“UE5.7”不足以证明两个 mapping 可互换。

## 12. 上游源文件

- [Developer README](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/README.md)
- [USMAP reader/writer](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/src/usmap_io.py)
- [Live process mapping reader](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/src/usmap_live.py)
- [Offline package reader](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/src/usmap_offline.py)
- [Merge tool](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/src/usmap_merge.py)
- [Quality tool](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/src/usmap_quality.py)
- [USMAP tests](https://github.com/KintaroModding/phantombladezero_pbzusmap/blob/main/tests/test_usmap.py)
- [UE4SS DumpUSMAP API](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/dumpusmap.md)
