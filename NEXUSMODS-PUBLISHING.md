# Nexus Mods 发布设置 — PBZ Auto Defense

本仓库将首次文件创建与后续版本更新分开处理：

- **首次创建**：手动运行 Nexus Mods publish workflow。workflow 先运行项目测试，再下载现有 GitHub Release `v1.6.4` 的 ZIP，并校验已发布的文件大小和 SHA-256；随后通过 Nexus Mods v3 单段上传 API 上传该 ZIP，并创建第一条 Main file 记录；若该 file entry 已存在但没有版本，则为它创建首个版本。
- **后续更新**：每次发布 GitHub Release，workflow 使用官方 Nexus-Mods/upload-action 为既有 file entry 追加新版本。

合并 PR 不会自动上传。首次上传需要维护者手动运行 workflow，并把确认项设置为 true。

## 已提供的 ID

| 类型 | 值 | 使用方式 |
|---|---:|---|
| Mod page ID | 45586782881016 | Phantom Blade Zero 页面 URL 中的数字 ID，配置为 NEXUSMODS_MOD_ID |
| Candidate file ID | 8404851 | 候选文件 ID；首次上传脚本会先确认它属于该 mod 且文件名为 PBZ Auto Defense |

这两个 ID 不可互换。若 8404851 不属于该模组，脚本不会使用它；如果目标文件记录尚不存在，API 创建 Main file 后会返回新的 file ID。

NEXUSMODS_MOD_ID 保存的是网站 URL 中的 game-scoped 数字 ID。首次创建 file entry 时，Create Mod File 请求使用 Get Mod 响应中的 game_scoped_id；后续 upload-action 写 changelog 时使用 /mods/{id}/changelogs 所需的内部 API mod ID。后续发布 job 会运行 tools/nexusmods_resolve_mod.py，从 GET /games/phantombladezero/mods/{NEXUSMODS_MOD_ID} 自动解析内部 ID，不要把两个 ID 当作同一个值。

## 1. 配置 GitHub Secrets / Variables

进入仓库 Settings → Secrets and variables → Actions，配置：

| 类型 | 名称 | 值 |
|---|---|---|
| Repository Secret | NEXUSMODS_API_KEY | Nexus Mods 用户 API key |
| Repository Variable | NEXUSMODS_MOD_ID | 45586782881016 |
| Repository Variable | NEXUSMODS_FILE_ID_CANDIDATE | 8404851 |

首次上传完成后，workflow Summary 会给出实际 file ID。把 Summary 中的 ID 保存为 Repository Variable：

| 类型 | 名称 | 值 |
|---|---|---|
| Repository Variable | NEXUSMODS_FILE_ID | 首次上传工作流返回的实际 file ID |

API key 只能保存在 Secret，不能写入 YAML、脚本、Variables 或日志。

建议创建 GitHub Environment：nexusmods-production，并按需设置 required reviewers。首次和后续发布 job 都绑定该 Environment。

## 2. 首次上传 v1.6.4

PR 合并到 main 后：

1. 打开仓库 Actions。
2. 选择 Nexus Mods publish。
3. 点击 Run workflow，Branch 选择 main。
4. 将 confirm_initial_upload 设置为 true。
5. 确认 API key、mod ID 和候选 file ID 配置正确，再运行。

workflow 将会：

1. 安装 LuaJIT 并运行 bash tools/run_all.sh。
2. 下载现有 GitHub Release `v1.6.4` 的 `pbz-auto-defense-v1.6.4.zip`，校验大小为 `285,737` bytes、SHA-256 为 `eb4745588ca311dc26e84680a2a3b1aa2ae338d0e73cd09a2b992296d221a705`。
3. 运行首次上传脚本的 ZIP 白名单和完整性检查。
4. 调用 GET /games/phantombladezero/mods/45586782881016 验证游戏 mod 页面。
5. 查询该 mod 的 file list，并核对候选 file ID 8404851。
6. 如果 PBZ Auto Defense 文件记录已存在但没有版本，为该记录创建首个版本；如果不存在，创建新的 Main file。
7. 使用单段 POST /uploads 上传 ZIP，finalise 后轮询至 available，再创建 file/version 记录。
8. 在 workflow Summary 输出最终 file ID、file version ID（API 有返回时）、版本和 ZIP SHA-256。

当前已发布 v1.6.4 ZIP 为 285,737 bytes（约 279 KiB），小于单段上传的 100 MiB 限制。首次上传使用 GitHub Release 中的原始 ZIP，而不是从当前 main 重打包：v1.6.4 tag 之后 main 上的源码有改动，但版本字符串仍为 1.6.4；直接打包 main 会造成同版本不同内容。脚本会在创建上传会话时发送 MD5 十六进制值，并在预签名 PUT 时发送同一摘要的 Base64 Content-MD5；同时发送签名要求的 Content-Disposition。这样也兼容官方 schema 公告的 2026-12-01 单段上传 md5 必填变更。

脚本在上传前检查现有 file list。如果 PBZ Auto Defense 已有版本，它只报告 file ID 并停止，不重复上传。如果候选 file ID 属于其他文件，则 fail closed，不会误更新其他模组文件。

注意：当前官方 OpenAPI 将 POST /mod-files（创建全新 file entry）标记为 Experimental。若 Nexus Mods 服务端拒绝创建新 file entry，可以在 Nexus Mods Files 页面手动上传同一 ZIP 并创建 Main file，然后将 Nexus 页面给出的 file ID 保存到 NEXUSMODS_FILE_ID。不要盲目重跑一个结果未知的创建请求。

## 3. 后续版本自动发布

首次上传完成并设置 NEXUSMODS_FILE_ID 后，未来每次发布按以下流程：

1. 更新 Scripts/main.lua 中的 tl.VERSION。
2. 在 CHANGELOG.md 中添加版本小节，标题形如 ## 1.6.5 — YYYY-MM-DD。
3. 本地运行 bash tools/run_all.sh 和 bash tools/package.sh。
4. 创建匹配的 Git tag / GitHub Release，例如 v1.6.5。
5. 发布 GitHub Release 后，workflow 自动运行测试、打包，并检查 Release tag 与包内 tl.VERSION 一致。
6. workflow 通过 tools/nexusmods_resolve_mod.py 把页面数字 ID 解析为 API 内部 mod ID，再提取 CHANGELOG.md 当前版本小节，调用官方 Nexus-Mods/upload-action 上传到 NEXUSMODS_FILE_ID 并写 changelog。
7. workflow Summary 记录 Nexus file version ID。

不要用首次 bootstrap workflow 发布常规更新。后续更新只由 release.published 触发。

## 4. 首次文件设置

- 文件名：PBZ Auto Defense
- 版本：打包脚本读取的 tl.VERSION（当前 1.6.4）
- File category：main
- Primary mod manager download：开启
- Mod manager download：允许
- Requirements popup：关闭
- Mod page version：同步文件版本

ZIP 只包含游戏运行时文件：Scripts/*.lua、data/ad_data.lua、enabled.txt、pbz-auto-defense.modsmenu.json。不会把 UE4SS、Mods Menu、游戏本体、文档、测试、生成器、日志、玩家配置或学习数据一起上传。

## 5. 安全与重试

- API key 通过 apikey 请求头传输；预签名 URL 不打印、不持久化。
- 手动首次上传需要 confirm_initial_upload=true；合并 PR 不触发首次上传。
- 上传会话创建后，如果后续 API 请求失败，可能留下未完成的会话。重试前检查 Nexus Mods 页面和 workflow Summary。
- Changelog API 是追加式。后续 Action 部分成功后重跑可能重复追加 changelog；重试前先检查现有记录。
- 文件描述保持在 255 字符以内。

## 参考资料

- https://api-docs.nexusmods.com/
- https://github.com/Nexus-Mods/Vortex/blob/master/packages/nexus-api-v3/schema/openapi.yaml
- https://github.com/Nexus-Mods/upload-action
- https://github.com/Nexus-Mods/API-Example
- https://github.com/High-cla/auto-defense-next/releases/tag/v1.6.4
