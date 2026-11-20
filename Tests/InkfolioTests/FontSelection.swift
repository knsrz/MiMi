import AppKit
import CoreText

extension Smoke {
    @MainActor
    static func editorFonts(_ directory: URL) throws {
        for preset in EditorFont.presets {
            try check(EditorFont(rawValue: preset.rawValue) == preset, "保留旧版预设字体设置")
        }
        let installed = EditorFont.installed("Menlo-Regular")
        try check(EditorFont(rawValue: installed.rawValue)?.font(size: 19).fontName == "Menlo-Regular",
                  "按 PostScript 名称恢复系统字体")
        try check(EditorFont(rawValue: "imported:../escape.ttf") == nil, "导入字体标识不能引用文库外的路径")

        guard let path = ProcessInfo.processInfo.environment["INKFOLIO_TEST_FONT"] else { return }
        let url = URL(fileURLWithPath: path)
        let library = EditorFontLibrary(directory: directory.appending(path: "Editor Fonts", directoryHint: .isDirectory))
        let choice = try library.importFont(from: url)
        guard case .imported(let filename) = choice, let savedChoice = EditorFont(rawValue: choice.rawValue) else {
            throw CheckFailure(label: "持久化导入的字体")
        }
        let stored = library.directory.appending(path: filename)
        try check(try Data(contentsOf: stored) == Data(contentsOf: url), "保留导入字体的原始字节")
        try check(try library.importFont(from: url) == choice, "重复导入同一个文件重用副本")

        let reopened = EditorFontLibrary(directory: library.directory)
        let bodyFont = savedChoice.font(size: 19, library: reopened)
        let heading = savedChoice.font(size: 30, weight: .semibold, library: reopened)
        try check(bodyFont.fontName == "LxgwWenKaiGB-Regular" && bodyFont.pointSize == 19, "重开后正文使用霞鹜文楷 GB")
        try check(heading.fontName == bodyFont.fontName && heading.pointSize == 30, "Markdown 标题沿用导入的字体")

        let sample = "春风又绿江南岸"
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        view.textStorage?.setAttributedString(NSAttributedString(string: sample, attributes: [.font: bodyFont]))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let actual = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let characters = Array(sample.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        try check(actual?.fontName == bodyFont.fontName &&
                  CTFontGetGlyphsForCharacters(bodyFont as CTFont, characters, &glyphs, characters.count),
                  "NSTextView 以导入字体渲染中文样例")
        print("霞鹜文楷 GB 验证通过。")
    }
}
