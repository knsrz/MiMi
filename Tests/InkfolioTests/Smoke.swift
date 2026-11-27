import AppKit
import Foundation
import PDFKit

struct CheckFailure: LocalizedError {
    let label: String
    var errorDescription: String? { label }
}

@main
enum Smoke {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Inkfolio-Tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try documents(directory)
        try editorPreview()
        try editorSpacing()
        try editorFonts(directory)
        try workspaceSizing()
        try equations(directory)
        try lifecycle(directory)
        try folderVault(directory)
        try await emptyFolderWorkspace(directory)
        try await folderWorkspace(directory)
        try await unavailableVaultOnQuit(directory)
        if let cloudRoot = ProcessInfo.processInfo.environment["INKFOLIO_TEST_ICLOUD_FOLDER"] {
            try await folderProvider(URL(fileURLWithPath: cloudRoot, isDirectory: true))
        }
        try await backgroundSaving(directory)
        try export(directory)
        print("验证通过：编辑器内 Markdown 排版、正文自动命名、离线 LaTeX、本地文件夹文库、冲突恢复与后台保存，以及八种导出格式。")
    }

    @MainActor
    static func editorSpacing() throws {
        let source = "正文\n正文\n## 标题需要换行标题需要换行\n* 列表需要换行列表需要换行\n* 另一项\n\t* 嵌套需要换行嵌套需要换行\n12. 编号列表\n- [x] 完成项"
        let raw = source as NSString
        let plan = EditorMarkdown(source)
        let font = NSFont.systemFont(ofSize: 16)
        let headingFont = NSFont.systemFont(ofSize: 23, weight: .semibold)
        let spacing = EditorSpacing(line: 11, paragraph: 19, indent: 0)
        let style = spacing.paragraphStyle()
        let storage = NSTextStorage(string: source, attributes: [.font: font, .paragraphStyle: style])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 210, height: 2000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(origin: .zero, size: container.size), textContainer: container)

        var prefixes: [(range: NSRange, wraps: Bool)] = []
        for block in plan.blocks {
            let paragraph = spacing.paragraphStyle()
            switch block.kind {
            case .heading(_, let prefix):
                EditorSpacing.placePrefix(raw.substring(with: prefix), font: font, before: EditorSpacing.markerGutter, in: paragraph)
                storage.addAttribute(.font, value: headingFont, range: NSRange(location: NSMaxRange(prefix), length: block.range.length - prefix.length))
                prefixes.append((prefix, true))
            case .list(let prefix):
                let literal = raw.substring(with: prefix)
                EditorSpacing.placeListPrefix(literal, font: font, in: paragraph)
                prefixes.append((prefix, raw.substring(with: block.range).contains("需要换行")))
                try check(paragraph.lineSpacing == spacing.line && paragraph.paragraphSpacing == 0, "列表仅使用行距：\(literal)")
            default:
                continue
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: block.range)
        }
        layout.ensureLayout(for: container)
        func position(_ glyph: Int) -> NSPoint {
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let offset = layout.location(forGlyphAt: glyph)
            return NSPoint(x: line.minX + offset.x, y: line.minY + offset.y)
        }
        let bodyX = position(0).x
        let secondBody = layout.glyphIndexForCharacter(at: ("正文\n" as NSString).length)
        let secondList = raw.range(of: "* 另一项").location
        let precedingLine = layout.glyphIndexForCharacter(at: secondList - 2)
        let nextItem = layout.glyphIndexForCharacter(at: secondList)
        let bodyStep = position(secondBody).y - position(0).y
        let listStep = position(nextItem).y - position(precedingLine).y
        try check(abs(bodyStep - listStep - spacing.paragraph) < 1,
                  "实际布局中列表项之间不叠加段距")
        for (prefix, wraps) in prefixes {
            let marker = layout.glyphIndexForCharacter(at: prefix.location)
            let body = layout.glyphIndexForCharacter(at: NSMaxRange(prefix))
            let bodyPosition = position(body)
            try check(position(marker).x < bodyPosition.x && position(marker).y == bodyPosition.y,
                      "标记位于首行正文前：\(raw.substring(with: prefix))")
            if prefix.location == prefixes.first?.range.location {
                try check(abs(bodyPosition.x - bodyX) < 1, "标题正文与普通正文左对齐")
            }
            var glyphLine = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: body, effectiveRange: &glyphLine)
            if wraps {
                try check(abs(position(NSMaxRange(glyphLine)).x - bodyPosition.x) < 1,
                          "续行对齐首行正文：\(raw.substring(with: prefix))")
            }
            view.setSelectedRange(NSRange(location: NSMaxRange(prefix), length: 0))
            layout.ensureLayout(for: container)
            try check(position(body) == bodyPosition && !layout.propertyForGlyph(at: marker).contains(.null),
                      "光标移动后标记可见且排版不变")
        }
        try check(view.string == source && EditorSpacing.regular.paragraphStyle().paragraphSpacing == 0,
                  "不改写源码，默认不叠加段距")
    }

    @MainActor
    static func editorPreview() throws {
        let source = #"""
        # 编辑区标题
        😀 **粗体与 *斜体***、~~删除~~、==高亮==、[链接](https://example.com) 和 `**原样**`。
        * 普通项目
        - [x] 已完成
        > 引用文字
        ```swift
        **代码里的标记**
        ```
        \*转义\* 和 **未完成
        """#
        let raw = source as NSString
        let plan = EditorMarkdown(source)
        let tokens = plan.markers.map { raw.substring(with: $0.range) }
        try check(tokens.contains("# ") && tokens.contains("](https://example.com)") && tokens.contains("> "), "定位标题、链接和引用标记")
        try check(tokens.contains("*") && tokens.contains("[x]"), "保留原始列表和任务标记")
        try check(plan.runs.contains {
            raw.substring(with: $0.range) == "斜体" && $0.intent.contains(.emphasized) && $0.intent.contains(.stronglyEmphasized)
        }, "表情与中文之后的嵌套粗斜体")
        try check(plan.runs.contains {
            raw.substring(with: $0.range) == "**原样**" && $0.intent.contains(.code)
        }, "保留行内代码里的标记")
        let incomplete = raw.range(of: "**未完成")
        let fenced = raw.range(of: "**代码里的标记**")
        try check(plan.markers.allSatisfy {
            NSIntersectionRange($0.range, incomplete).length == 0 && NSIntersectionRange($0.range, fenced).length == 0
        }, "代码块和未闭合标记保持可见")

        // Verify image markers, table blocks, and task box ranges
        let extended = "![封面](attachment:abc-123)\n- [ ] 待办\n| 甲 | 乙 |"
        let extPlan = EditorMarkdown(extended)
        let extRaw = extended as NSString
        try check(extPlan.runs.contains(where: { $0.image && extRaw.substring(with: $0.range) == "封面" }), "识别图片语法并提取替代文字")
        try check(extPlan.markers.contains(where: { extRaw.substring(with: $0.range) == "](attachment:abc-123)" }), "识别图片附件引用定界符")
        try check(extPlan.markers.contains(where: { $0.taskBoxRange.map({ extRaw.substring(with: $0) }) == "[ ]" }), "记录待办复选框范围")
        try check(extPlan.blocks.contains(where: { if case .table = $0.kind { return true } else { return false } }), "识别表格行")
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw CheckFailure(label: label) }
    }

    static func documents(_ directory: URL) throws {
        let sample = """
        # 春天

        **Wind** / _sea_ / ==很轻==

        > quote

        - [ ] todo

        | 早 | 晚 |
        | --- | --- |
        | a | b |

        ```swift
        # this is code
        ```

        %% this is a comment

        [unsafe](javascript:alert) <script>alert(1)</script>
        """
        try check(Manuscript.headings(sample).map(\.title) == ["春天"], "大纲误识别代码块")
        try check(WritingCount("春风 two words").words == 4, "中英文混合计数")
        try check(!Manuscript.plainText(sample).contains("this is a comment"), "注释出现在纯文本中")
        let html = Manuscript.html([Draft(title: "A < B", text: sample)])
        try check(html.contains("<strong>Wind</strong>") && html.contains("<table>") && html.contains("<mark>很轻</mark>"), "Markdown 渲染")
        try check(!html.contains("<script>") && !html.contains("href=\"javascript:"), "HTML 未转义")
        let untitled = Draft(text: "# 从正文取标题\n\n正文")
        try check(Manuscript.htmlBody(untitled, assets: [:]).components(separatedBy: "<h1>").count == 2,
                  "自动推断出的标题不应重复显示")
        try check(untitled.title.isEmpty && untitled.name == "从正文取标题" && untitled.excerpt == "正文", "正文自动命名")
        try check(FileTransfer.markdown([Draft(title: "同一标题", text: "# 同一标题\n正文")]) == "# 同一标题\n正文",
                  "从 Markdown 导入的标题不应在导出时重复")
        let file = directory.appending(path: "潮线.md")
        try Data("# 定稿\n正文".utf8).write(to: file)
        let batch = try FileTransfer.importFiles([file], into: nil)
        try check(batch.drafts.first?.name == "潮线" && batch.drafts.first?.text.contains("正文") == true, "Markdown 导入")

        // Verify clean multi-line Markdown-stripped excerpt & sentence count
        let empty = Draft()
        try check(empty.isBlank && empty.flowingPreview.isEmpty && empty.excerpt.isEmpty, "新建空白文稿不应填充占位文案")
        let rich = Draft(title: "摘要测试", text: "**第一句**与[链接](https://example.com)。\n\n第二段内容！")
        try check(rich.excerpt == "第一句与链接。 第二段内容！", "摘要应剥离 Markdown 标记并衔接多段")
        let stats = WritingCount("第一句。第二句！Third sentence?")
        try check(stats.sentences == 3 && stats.charactersWithSpaces > stats.characters, "句子与含空格字符统计")

        // Verify consecutive blockquotes merge into a single blockquote
        let quotesHTML = Manuscript.htmlBody(Draft(text: "> 第一行\n> 第二行"), assets: [:])
        try check(quotesHTML.components(separatedBy: "<blockquote>").count == 2 && quotesHTML.contains("第二行"), "相邻引用应合并为单个 blockquote")

        // Verify highlight renders background color in attributed output
        let attr = Manuscript.attributed([Draft(text: "普通 ==高亮文字== 普通")])
        let markRange = (attr.string as NSString).range(of: "高亮文字")
        try check(markRange.location != NSNotFound && attr.attribute(.backgroundColor, at: markRange.location, effectiveRange: nil) != nil,
                  "富文本/PDF 导出应保留高亮背景")
    }

    static func equations(_ directory: URL) throws {
        let source = #"""
        ## 方程

        行内 **$x^2$**，另一式 $$x_i$$，以及 \(y^3\)。
        价格 $20 和 $30，转义 \$k\$，代码 `$notMath$`。

        $$
        \frac{a}{b} = \sqrt{x}
        $$

        \[
        \begin{aligned}
        a &= b \\
        c &= d
        \end{aligned}
        \]

        ```text
        $notMath$
        ```
        """#
        let doc = Draft(text: source)
        let html = Manuscript.html([doc])
        try check(html.components(separatedBy: "<math ").count == 6, "行内、独立、转义和代码中的方程识别")
        try check(html.contains("<mfrac>") && html.contains("<msqrt>") && html.contains("<mtable"), "KaTeX 未按 MathML 排版分数、根式和对齐公式")
        try check(html.contains("<strong><span class=\"katex\">") && html.contains("<code>$notMath$</code>"),
                  "行内公式影响了 Markdown 样式")
        let location = (source as NSString).range(of: #"\frac"#).location
        let selected = Manuscript.equation(in: source, at: location)
        try check(selected?.display == true && selected?.source.contains(#"\sqrt"#) == true, "识别光标所在的多行公式")
        try check(MathTeX.shared.render(#"\frac{"#, display: true).error != nil, "无效 LaTeX 应给出错误")
        let external = MathTeX.shared.render(#"\href{https://example.test}{x}"#, display: false)
        try check(!external.markup.contains("href="), "未信任的 TeX 可生成可点击的链接")
        try check(WritingCount("前后 $x^2$").words == 2, "方程源码应独立于正文统计")
        let target = directory.appending(path: "Equations.html")
        try FileTransfer.export([doc], as: .html, to: target)
        let exported = try String(contentsOf: target, encoding: .utf8)
        try check(exported.contains("<mfrac>"), "HTML 导出缺少 MathML")
    }

    @MainActor
    static func backgroundSaving(_ directory: URL) async throws {
        let file = directory.appending(path: "Background.json")
        let store = LibraryStore(file: file)
        let id = store.addDraft(folder: nil, text: "自动保存旧内容")
        store.edit(id) { $0.text = "自动保存最新内容" }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: file.path),
               LibraryStore(file: file).draft(id)?.text == "自动保存最新内容" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(LibraryStore(file: file).draft(id)?.text == "自动保存最新内容", "后台自动保存未写入最新内容")
        let backup = directory.appending(path: "BackgroundBackup.json")
        try store.exportBackup(to: backup)
        store.edit(id) { $0.text = "还在等待自动保存的编辑" }
        try store.restoreBackup(from: backup)
        try await Task.sleep(for: .milliseconds(400))
        try check(LibraryStore(file: file).draft(id)?.text == "自动保存最新内容", "后台自动保存覆盖了已恢复的备份")
    }

    @MainActor
    static func lifecycle(_ directory: URL) throws {
        let url = directory.appending(path: "Library.json")
        let original = LibraryStore(file: url)
        let project = original.addFolder(name: "测试项目", parent: nil, project: true, goal: 100)
        let child = original.addFolder(name: "第二章", parent: project, project: false, goal: 0)
        let id = original.addDraft(folder: child, text: "第一节\n\n第二节")
        original.edit(id) { $0.tags = ["测试"]; $0.favorite = true }
        let filter = SmartFilter(name: "测试筛选", query: "第二节", tag: "测试", stage: .draft, folderID: project)
        original.saveFilter(filter)
        try check(original.library.matching(.filter(filter.id)).map(\.id) == [id], "嵌套组内智能筛选")
        let text = original.draft(id)!.text
        let at = text.firstIndex(of: "\n")!
        guard let second = original.split(id, at: at) else { throw CheckFailure(label: "拆分文稿") }
        try check(original.draft(second)?.text == "\n\n第二节", "拆分位置")
        try check(original.merge([id, second]) == id, "合并文稿")
        try check(original.library.matching(.trash).contains { $0.id == second }, "分稿合并后保留在废纸篓")
        original.snapshot(id)
        let snapshot = original.draft(id)!.revisions[0]
        original.edit(id) { $0.text = "编辑后的新内容" }
        original.revert(id, to: snapshot)
        try check(original.draft(id)?.text.contains("第二节") == true, "恢复正文版本")
        let beforeDeleteCount = original.draft(id)!.revisions.count
        original.deleteRevision(snapshot.id, in: id)
        try check(original.draft(id)!.revisions.count == beforeDeleteCount - 1, "删除历史版本")
        // Folder edit cycle guard & batch operations
        original.editFolder(project, name: "测试项目", parentID: child, project: false, goal: 200)
        try check(original.library.folder(project)?.parentID == nil && original.library.folder(project)?.goal == 200, "分组编辑防止循环嵌套")
        try check(original.library.allTags.contains("测试") && original.library.allTags.contains("海岸"), "汇总全库关键词")
        original.setMaterial([id], true)
        try check(original.draft(id)?.material == true, "批量标记素材")
        original.setMaterial([id], false)
        original.trash([id])
        original.restore([id])
        original.flush()
        let reopened = LibraryStore(file: url)
        try check(reopened.library == original.library, "重开后文库变化")
        let backup = directory.appending(path: "Backup.json")
        try reopened.exportBackup(to: backup)
        reopened.trash([id])
        try reopened.restoreBackup(from: backup)
        try check(reopened.draft(id)?.deleted == nil, "恢复文库备份")
        let malformed = directory.appending(path: "Broken.json")
        try Data("damaged".utf8).write(to: malformed)
        let recovered = LibraryStore(file: malformed)
        try check(recovered.recoveredFile != nil && recovered.saveError != nil, "保留无法读取的文库")
    }

    static func export(_ directory: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CheckFailure(label: "无法创建测试图片")
        }
        let green = NSColor(deviceRed: 0.2, green: 0.55, blue: 0.32, alpha: 1)
        for x in 0..<8 { for y in 0..<8 { bitmap.setColor(green, atX: x, y: y) } }
        guard let image = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(label: "无法编码测试图片")
        }
        let attachment = Attachment(name: "图 片.png", data: image)
        let item = Draft(title: "导出测试",
                         text: "## 第一章\n\n**原生导出** with text.\n\n![小图](\(attachment.reference))\n\n"
                               + (0..<82).map { "第 \($0) 段。这里有正文内容，用于验证分页后全部段落都能保留。" }.joined(separator: "\n\n"),
                         attachments: [attachment])
        for type in ExportFormat.allCases {
            let target = directory.appending(path: "Manuscript." + type.ext)
            try FileTransfer.export([item], as: type, to: target)
            if type == .textbundle {
                let copy = try FileTransfer.importFiles([target], into: nil).drafts[0]
                try check(copy.attachments.first?.data == image && copy.text.contains(copy.attachments[0].reference), "TextBundle 附件回读")
                continue
            }
            let data = try Data(contentsOf: target)
            try check(!data.isEmpty, "\(type.ext) 为空")
            switch type {
            case .pdf:
                let pdf = PDFDocument(data: data)
                try check((pdf?.pageCount ?? 0) > 1, "PDF 未分页")
                try check(pdf?.string?.contains("导出测试") == true && pdf?.string?.contains("81") == true, "PDF 正文不完整")
            case .docx:
                try check(data.starts(with: [0x50, 0x4B]), "DOCX 容器无效")
                let imported = try FileTransfer.importFiles([target], into: nil)
                try check(imported.drafts.first?.text.contains("原生导出") == true, "DOCX 无法回读")
            case .epub:
                try check(data.starts(with: [0x50, 0x4B]), "EPUB 容器无效")
                let archive = Process()
                archive.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                archive.arguments = ["-tq", target.path]
                archive.standardOutput = FileHandle.nullDevice
                try archive.run()
                archive.waitUntilExit()
                try check(archive.terminationStatus == 0, "EPUB ZIP 完整性失败")
            case .html:
                try check(String(decoding: data, as: UTF8.self).contains("data:image/png;base64"), "HTML 未嵌入附件")
            default: break
            }
        }
    }
}
