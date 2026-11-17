# Phantom Blade Zero SDK 与反射资源索引

> 先区分三种不同资源：USMAP 映射文件、PBZ 游戏 API TypeScript SDK、UE4SS 生成的 C++ SDK。它们解决的问题不同，不能互相替代。
>
> 核对日期：2026-11-17。以下是社区维护/生成的开发资源，不是 S-GAME 官方发布的游戏开发 SDK。

## 结论速览

| 资源 | 是否存在 | 内容 | 适合谁 | 能否直接用于当前 Lua MOD |
|---|---|---|---|---|
| PBZ USMAP | 有，v1.1 | 游戏 native + Blueprint 类型/属性映射文件 | FModel、UAssetGUI、CUE4Parse、资产分析 | 否；它不是 Lua API |
| PBZModLoader Game API SDK | 有，0.3.3 | PBZ 游戏反射生成的 TypeScript 声明、类型索引、验证报告 | PBZModLoader JS/TS MOD 作者；也可作为游戏 API 参考 | 不能直接 import 到 Lua；适合核对签名 |
| UE4SS C++ SDK Generator | 有，内置于 UE4SS | 从运行中游戏反射生成 C++ headers、结构布局和 enums | UE4SS C++ MOD 作者 | 否；这是 C++ SDK，不是 Lua 模块 |
| PBZ USMAP 源码工具链 | 有 | live/offline 类型采集、USMAP 转换、合并和质量检查 | 重建映射/研究反射的开发者 | 否；这是开发期工具 |

**针对 PBZ Auto Defense 当前 UE4SS Lua 版本：** 以 UE4SS Lua API 为实际运行时接口；以 PBZModLoader Game API SDK 作为游戏类型/函数的主要交叉参考；以 PBZ USMAP 作为字段类型和资产 schema 的辅助证据。不要把 TypeScript 声明当作 Lua binding 已验证的证明。

---

## 1. PBZ USMAP：有映射文件，没有独立游戏 API SDK

项目：[KintaroModding/phantombladezero_pbzusmap](https://github.com/KintaroModding/phantombladezero_pbzusmap)

该仓库的发布目标是完整 Unreal Mapping 文件和重建它的工具链。源码树没有独立的 PBZ Game API SDK 包、TypeScript declarations 或 C++ headers。仓库 README 中提到的 .NET 10 SDK 是构建 CUE4Parse offline reader 所需的 Microsoft .NET 编译工具链，不是 Phantom Blade Zero 的游戏 API SDK。

仓库包含：
- 当前游戏 build 的 USMAP v4；
- native 类型和包内 Blueprint class / user-defined struct / enum 的映射；
- PPTH 类型/包路径和 EATR flags 扩展；
- 只读 live process dumper；
- CUE4Parse offline package reader；
- JSONL → USMAP converter；
- 多来源 mapping merge；
- mapping coverage / integrity / consistency 检查。

### 当前 mapping release

- [USMAP File (Proper) v1.1](https://github.com/KintaroModding/phantombladezero_pbzusmap/releases/tag/v1.1)
- 适用：Steam build 26367565，CL-302256_JKS-17280，Unreal Engine 5.7.4。
- 文件：`ProjectPBZ-5.7.4-302256-full.usmap`。
- release 同时提供 ZIP、原始 .usmap 文件和 SHA256SUMS。
- v1.0 是较早 Steam build 26266538 的映射，不应与当前 build 混用。

USMAP 能解释资产字段类型、枚举、父类和包路径；它本身不提供 C++ 可编译头文件、不提供 Lua 函数调用层，也不代表某个 UFunction 已经过运行时调用测试。

---

## 2. PBZModLoader Game API SDK：现成的 PBZ 游戏 API 声明

项目：[KintaroModding/phantombladezero_pbzmodloader](https://github.com/KintaroModding/phantombladezero_pbzmodloader)

- [SDK README](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/README.md)
- [类型入口](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/index.d.ts)
- [完整类型索引](https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/type-index.json)

### 2.1 SDK 版本与目标 build

当前 Game API SDK 是 `@pbz-mod-loader/game-api 0.3.3`，对应：

| 项目 | 值 |
|---|---|
| 平台 | Steam Win64 |
| 游戏 changelist | CL-302256_JKS-17280 |
| EXE SHA-256 | `4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423` |
| 引擎 | Unreal Engine 5.7.4 |
| SDK 类型数 | 34,593 |
| Native / Asset 类型 | 18,457 / 16,136 |
| 函数声明 | 49,386 |
| 属性映射 | 119,282 |
| unresolved properties | 55 |

这些是当前捕获 registry 的统计，不代表所有未加载资产或所有 C++ API 都已覆盖。Steam build、CL changelist、EXE hash 是不同版本标识，升级核对时应一起记录。

### 2.2 SDK 包含什么

- `sdk/index.d.ts`：包入口和全局类型定义。
- `sdk/types/generated/*.d.ts`：按 Unreal module 分组的反射类型、类、结构、函数和属性声明。
- `sdk/type-index.json`：完整反射路径到类型文件/符号的索引。
- `sdk/api-surface.json`：SDK 覆盖与运行时验证状态。
- `sdk/generation-report.json`：生成来源、排除项、未解析项和 schema 变更。
- `sdk/binding-support-verification.json`：当前 build 的 binding 和调用验证记录。
- `sdk/property-mapping-verification.json`：属性映射验证历史。
- `sdk/README.md`：安装方法、用法、已知限制和中英文说明。

对 Auto Defense 最有价值的类型文件包括：
- `PBZDeflectSystem.d.ts`：DeflectComponent、DeflectReceiveFrame、DeflectSendFrame、DeflectResultData。
- `SGameInputSystem.d.ts`：AbilityInputComponent、输入缓冲和外部能力触发方法。
- `EnhancedInput.d.ts`：InputAction、输入值、输入注入相关声明。
- `GameplayAbilities.d.ts` / `GameplayTags.d.ts`：GAS 与 GameplayTag。
- `Engine.d.ts` / `CoreUObject.d.ts`：基础 UObject、Actor、World、容器和引擎结构。

### 2.3 从哪里下载

**推荐下载 developer ZIP：**

[PBZModLoader 2.1.0 Developer ZIP](https://github.com/KintaroModding/phantombladezero_pbzmodloader/releases/download/v2.1.0/PBZModLoader-2.1.0-developer.zip)

[PBZModLoader v2.1.0 Release](https://github.com/KintaroModding/phantombladezero_pbzmodloader/releases/tag/v2.1.0)

developer ZIP 面向 MOD 作者，包含 TypeScript 模板和 SDK；玩家使用的 win64 ZIP 不是 SDK 包。SDK 源码也可直接从仓库的 `sdk/` 目录查看。

### 2.4 TypeScript 模组中安装/使用

最简单方式是复制仓库中的 `templates/ts-mod/` 模板，按模板 README 执行：

~~~powershell
npm ci
npm run check
npm run build
~~~

既有 TypeScript 项目可在 PBZModLoader 仓库中生成离线 npm 包：

~~~powershell
npm run sdk:pack
~~~

随后将生成的 `build/sdk/pbz-mod-loader-game-api-0.3.3.tgz` 放入自己的 `vendor/`，并安装：

~~~powershell
npm install --save-dev ./vendor/pbz-mod-loader-game-api-0.3.3.tgz
~~~

推荐 tsconfig 核心设置：

~~~json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "CommonJS",
    "lib": ["ES2020"],
    "types": ["@pbz-mod-loader/game-api"],
    "strict": true,
    "noEmitOnError": true
  }
}
~~~

代码从游戏环境加载模块：

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

**重要：** `@pbz-mod-loader/game-api` 只有 TypeScript 声明，没有游戏 API runtime code。发布 MOD 时发布编译后的 JS，不要把 SDK 当成一个需要在游戏中加载的 DLL。也不要在 Node.js 中直接运行游戏 MOD 文件；`ue` 和 `puerts` 由游戏运行时提供。

### 2.5 它能否用于当前 UE4SS Lua 模组？

不能直接使用：
- Lua 文件不能 import TypeScript declaration package。
- PuerTS 的 `$ref/$unref` 不等价于 UE4SS 的 `RemoteUnrealParam:get()/set()`。
- SDK 的类名/签名可用于核对 PBZ 游戏反射。
- 但某个成员标为 `reflection-generated` 不代表 UE4SS Lua binding 一定能调用或读写。

对当前项目，SDK 最适合当作**反射签名和属性类型参考**，再用 UE4SS Lua 在同一游戏 build 下做独立验证。

---

## 3. UE4SS C++ SDK Generator：为当前运行游戏生成 C++ SDK

项目：[KintaroModding/ue4ss](https://github.com/KintaroModding/ue4ss)

- [UE4SS SDK Generator 文档](https://github.com/KintaroModding/ue4ss/blob/release/docs/feature-overview/sdk-generator.md)
- [GenerateSDK Lua API](https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/generatesdk.md)

### 3.1 输出内容

UE4SS SDK Generator 会从当前游戏中可见的反射信息生成 C++ headers，包括：
- reflected class 和 struct；
- enums；
- 成员变量和函数声明；
- 类/结构体大小、对齐和成员偏移；
- leading/inter-member/trailing padding；
- static arrays 和 bitfields；
- 对无法映射到已知 C++ 类型的属性，生成带正确大小/对齐的 placeholder。

它主要服务于 C++ MOD 开发，不是 TypeScript SDK，也不是 UE4SS Lua API 的安装包。

### 3.2 在游戏中生成

1. 安装与 PBZ 当前 build 兼容的 UE4SS。
2. 在 UE4SS 配置中确保 GUI Console 可见并启用。
3. 启动游戏。
4. 打开 UE4SS GUI Console 的 Dumpers 标签。
5. 点击 Generate SDK。
6. 按 SDK Generator 文档，在游戏目录 `Binaries/Win64` 下找到生成的 `UE4SS_SDK` 目录。
7. 将整个 `UE4SS_SDK` 目录复制进 C++ MOD 工程。

UE4SS 还公开 Lua 全局函数 `GenerateSDK()`，文档说明它会生成 C++ headers 到 `CXXHeaderDump` 目录；GUI 的 Generate SDK 工作流则是 SDK Generator 文档给出的标准 C++ MOD 项目输出路径。不同 UE4SS 版本/构建可能保留不同入口，按当前安装版本的 GUI 与文件输出核对。

### 3.3 C++ 工程接入

UE4SS 文档给出的 CMake 接入形式：

~~~cmake
add_subdirectory(UE4SS_SDK)
target_link_libraries(MyMod PRIVATE UE4SS_SDK)
~~~

然后在源码中 include 具体类型：

~~~cpp
#include <UE4SS_SDK/Script/Engine/Actor.hpp>
~~~

生成的 `UE4SS_SDK/LayoutAsserts.hpp` 含类型大小、对齐与成员偏移的 static_assert；`UE4SS_SDK/RuntimeSDKTest.hpp` 可对运行中的游戏布局进行 runtime 检查。建议在当前 PBZ 游戏 build 下保留这些检查，避免将旧 build 的 struct offset 误用到新版本。

### 3.4 对 Auto Defense 当前项目的意义

当前 Auto Defense 是 Lua 模组，并不是 C++ MOD，因此没有必要仅为使用 C++ SDK Generator 而迁移整个项目。

它仍然有两个用途：
- 通过当前游戏构建的生成结果交叉核对类型布局、字段名称和结构体成员。
- 若未来需要开发 C++ 插件/高频原生辅助模块，可作为 C++ backend 的基础。

C++ SDK 生成的字段偏移/结构布局不能直接拿来当 Lua 运行时地址；Lua 应仍通过 UE4SS object/property/function binding 访问对象。

---

## 4. 三类资源的推荐使用顺序

### 当前项目：UE4SS Lua 自动防御

1. 用 PBZModLoader Game API SDK 查询 DeflectComponent、AbilityInputComponent、GameplayTag 等真实游戏类型和成员签名。
2. 用 PBZ USMAP 核对 Blueprint/Struct/Enum 的 schema、容器元素类型和包路径。
3. 在 UE4SS Lua 环境验证 StaticFindObject、属性读取、UFunction 调用、RemoteUnrealParam 转换和对象生命周期。
4. 只有验证通过后，才把 API 接入 main.lua 的防守热路径。
5. 若需要 C++ 原生模块，再单独生成 UE4SS C++ SDK；不要把它混入 Lua 模组。

### 新 API 的准入规则

- **类型声明：** 可用于发现字段/方法候选。
- **USMAP schema：** 可用于核对字段类型和继承结构。
- **UE4SS SDK layout assert：** 可用于 C++ 结构布局验证。
- **Binding probe：** 证明目标运行时能解析成员。
- **Call probe：** 证明特定 build/状态下代表性调用可完成。
- **实机战斗验收：** 证明新调用没有破坏弹反、闪避、抓投和其他 MOD 协作。

以上证据不能互相替代。尤其 PBZModLoader 的 TypeScript SDK 已有 55 项未解析属性，游戏专用声明也可能只是反射生成，不能全部直接调用。

---

## 5. 相关项目与下载入口

| 资源 | 地址 |
|---|---|
| PBZ USMAP 源码 | https://github.com/KintaroModding/phantombladezero_pbzusmap |
| PBZ USMAP v1.1 mapping release | https://github.com/KintaroModding/phantombladezero_pbzusmap/releases/tag/v1.1 |
| PBZModLoader SDK 源码 | https://github.com/KintaroModding/phantombladezero_pbzmodloader/tree/release/sdk |
| PBZModLoader 2.1.0 developer ZIP | https://github.com/KintaroModding/phantombladezero_pbzmodloader/releases/download/v2.1.0/PBZModLoader-2.1.0-developer.zip |
| PBZModLoader SDK README | https://github.com/KintaroModding/phantombladezero_pbzmodloader/blob/release/sdk/README.md |
| PBZModLoader TypeScript 模板 | https://github.com/KintaroModding/phantombladezero_pbzmodloader/tree/release/templates/ts-mod |
| UE4SS SDK Generator 文档 | https://github.com/KintaroModding/ue4ss/blob/release/docs/feature-overview/sdk-generator.md |
| UE4SS GenerateSDK Lua API | https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/generatesdk.md |
| UE4SS DumpUSMAP Lua API | https://github.com/KintaroModding/ue4ss/blob/release/docs/lua-api/global-functions/dumpusmap.md |

---

## 6. 许可与分发注意事项

PBZModLoader fork 的仓库许可为 GPL-3.0，但其 Game API npm package 的 package.json 标注为 private 且 license 为 UNLICENSED。开发者应遵循 SDK 仓库自己的分发说明，不要因为 loader 的 GPL 许可就自行把 SDK 作为公开 npm 包重新发布。

PBZ USMAP 仓库为其 mapping 和工具链单独声明许可证；下载 mapping、复用工具代码、重新分发 mapping 和把 SDK 声明复制进其他项目是不同的使用行为。复用前检查每个上游项目的 LICENSE 和 release 条款。
