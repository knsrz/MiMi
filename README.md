# MiMi · Inkfolio

MiMi 是用 SwiftUI 和 AppKit 编写的原生 macOS Markdown 写作应用。正文由系统 NSTextView 编辑，排版预览使用系统 WebKit。项目以本机的 Ulysses 40 为功能参考，采用独立的名称、图标和工作台界面。

## 安装与更新

从 [GitHub Releases](https://github.com/knsrz/MiMi/releases/latest) 下载最新的 `MiMi-X.Y.Z-universal.dmg`，打开后将 MiMi 拖到 Applications。支持 Apple Silicon 和 Intel，要求 macOS 14 或更新版本。也可以下载 ZIP 并解压到 Applications。

当前发布使用临时签名，尚未通过 Apple Developer ID 签名和公证。首次打开如被 macOS 拦截，请先尝试打开应用，再到「系统设置 → 隐私与安全性」为 MiMi 选择「仍要打开」。请只从本仓库的 Releases 下载。

在「MiMi → 设置 → 软件更新」或「MiMi → 检查更新…」手动检查新版本。发现新版后可以查看说明、下载并安装，随后重新启动应用。更新由 Sparkle 2.10.1 处理；更新源和 ZIP 均使用 EdDSA 签名校验，默认不自动检查或下载。文库、附件和本机偏好独立于应用包保存。

## 从源码构建

需要 Xcode 或 Xcode Command Line Tools。执行 `./build.sh` 生成 `dist/MiMi.app`，默认同时构建 Apple Silicon 和 Intel；本机开发可执行 `ARCHS=arm64 ./build.sh`。执行 `./scripts/test.sh` 验证主要功能和导出格式。可通过 `INKFOLIO_SDK` 指定与 Swift 编译器相匹配的 SDK。

构建会下载并校验固定版本的 Sparkle。Swift Package Manager 也声明了同一版本依赖；生成可分发的 `.app` 请使用 `build.sh`，以包含更新框架、资源和签名。

## 发布新版本（维护者）

首次发布已配置 GitHub Actions 的 `SPARKLE_PRIVATE_KEY` 仓库 Secret。更新私钥保存在发布机器钥匙串的 `MiMi-knsrz` 账户中，切勿提交到 Git、写入 README 或发给用户。请在钥匙串中安全备份此密钥；已有安装依赖对应的公钥，不能随意更换。

1. 修改代码，提交并推送到 `main`。
2. 执行 `./scripts/release.sh 1.3.1`（替换为大于当前版本的版本号）。脚本要求工作区干净，运行测试、递增 `CFBundleVersion`、提交版本号并推送版本标签。
3. 在 [Actions](https://github.com/knsrz/MiMi/actions) 查看构建结果。标签会触发双架构构建，生成 DMG、ZIP、签名的 `appcast.xml` 和 `SHA256SUMS`。全部上传成功后才公开 Release。
4. 用户在设置中检查更新，即可从 GitHub 下载并安装新版。安装包使用版本专属地址，检查入口固定指向最新 Release 的 `appcast.xml`。

本机仅准备安装包、不发布：执行 `./scripts/package-release.sh`，产物位于 `dist/release-X.Y.Z/`。默认从钥匙串取签名密钥；CI 通过 Secret 注入。发布前会启动真实 Sparkle 更新器检查配置，并验证归档中的版本、双架构二进制、应用签名、下载地址和 EdDSA 签名。`./scripts/check-updater.sh --online` 可额外检查线上更新源。

如果 Actions 失败且留下草稿 Release，请先排查日志，删除该次未公开的草稿并重新运行任务；不要覆盖已经公开的版本资产。每次正式发布使用新的版本号。

发布脚本目前采用临时应用签名。以后取得 Developer ID 证书后，应在生成更新 ZIP 前完成应用签名和公证，再发布新版本；EdDSA 更新密钥应保持一致。

## 写作和管理

- 以项目、嵌套分组、收件箱、收藏和废纸篓管理文稿。智能筛选可组合分组范围、正文或备注文本、关键词和状态。
- 用 `⌘N` 从正文直接开始写。文稿名自动取自正文首行，也可以从文稿菜单单独重命名。`⌘O` 快速打开，`⌘F` 查找正文，`⌥⌘F` 替换正文。
- 标题、强调、列表、任务、引用、分隔线、链接和代码在正文编辑区实时排版。Markdown 标记始终显示，移动光标不会改变标记或触发重新换行；标题和列表标记位于首行正文前，续行与正文对齐。列表项之间只使用行距。可在「设置 → 正文排版」单独恢复默认行距和段距。
- 用 `⇧⌘E` 打开完整分栏预览，布局用 `⌘1`、`⌘2`、`⌘3` 切换，`⌘4` 打开检查器。单击编辑区右下角的字数可查看统计详情。设置支持固定滚动位置、当前行标记、行距、段距和首行缩进。
- 在「设置 → 编辑器字体 → 选择字体」搜索系统字体，或导入 TTF、OTF 文件。选择的字体应用于编辑器，并保存在本机设置中。
- 用 `⌃⌘M` 打开方程编辑器，输入 LaTeX 即可预览。也可以直接在文稿中输入 `$x^2$`、`\(x^2\)` 或单独一行的 `$$x^2$$`，并使用多行块公式。在光标位于已有公式内时，方程编辑器会载入该公式。公式由随应用打包的 KaTeX 0.19.1 离线转换为 MathML。
- 检查器提供大纲跳转、关键词、附注、附件、文稿状态、写作目标和正文版本。列表可调整摘要行数和日期显示，支持拖动、排序、按住 `⌘` 或 `⇧` 多选。正文支持按光标拆分，选中文稿后可合并。
- 用 `⇧⌘I` 导入 Markdown、纯文本、RTF、Word、HTML、TextBundle 或文件夹。富文本导入保留可提取的文字，文件夹被导入为分组。
- 用 `⇧⌘P` 预览和导出 Markdown、TXT、HTML、PDF、DOCX、EPUB、RTF 或 TextBundle。可以导出单篇、所选文稿或整个分组。多篇导出排除素材。需要连同本地附件搬迁时，可使用 TextBundle。
## 文件夹文库

- 在首次启动页面或「文件」菜单打开已有文库、新建文库，或迁移旧版文库。迁移时选择目标位置，写入并回读核对后才打开新文库。原文件 `~/Library/Application Support/Inkfolio/Library.json` 会保留。
- 每篇正文是独立的 UTF-8 `.md`。收件箱、项目、嵌套分组和废纸篓对应真实文件夹。`MiMi数据` 保存标签、备注、写作目标、智能筛选、附件和历史版本。要搬迁完整文库，请复制整个目录，再用「打开文库文件夹」选中它。
- 把文库建在 iCloud Drive，其他 Mac 就可以打开同一目录。已下载的文稿可以离线编辑。遇到下载或访问问题时，界面会显示文库状态。发现同篇的并行正文改动时，编辑器会提供冲突副本入口。
- 「备份文库」可导出包含附件和历史版本的 JSON。「恢复文库」从 JSON 创建一个独立的文库。建议把备份文件保存在文库目录外。
- `./scripts/test.sh` 包含本地迁移、文件夹重开、并发保存、冲突副本和待保存事务恢复测试。同一 iCloud Drive 文库的双机验收需在两台 Mac 上进行。

## 兼容范围

当前版本提供 macOS 客户端和内建排版。iOS 客户端、第三方博客发布、Ulysses 专用文库和样式格式，以及完整的 Markdown XL 和高级校对功能尚未实现。从 Ulysses 迁移正文可使用它提供的 Markdown 或 TextBundle 导出入口。

网页和 EPUB 导出使用 MathML 排版方程。PDF、DOCX 和 RTF 导出目前以公式源码为主。

## 参考与验证

功能与交互参考 Ulysses 40 的公开说明及本机观察。MiMi 使用独立的名称、图标和源码；公式渲染依赖随应用分发的 KaTeX。应用更新使用 [Sparkle](https://sparkle-project.org/documentation/)，相关授权包含在应用资源中。

- [Ulysses 文库与编辑器](https://help.ulysses.app/en_US/getting-started/first-steps-library-editor)
- [Ulysses 写作目标](https://help.ulysses.app/the-dashboard/goals)
- [Ulysses 导出格式](https://help.ulysses.app/export)
- [Ulysses 方程](https://help.ulysses.app/en_US/dive-into-editing/writing-equations)
- [Ulysses 编辑器设置](https://help.ulysses.app/en_US/dive-into-editing/editor-customization-guide)
- [KaTeX 使用与授权](https://github.com/KaTeX/KaTeX/tree/v0.19.1)
