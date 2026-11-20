import AppKit
import Foundation
import UniformTypeIdentifiers

struct Heading: Identifiable, Equatable {
    var title: String
    var level: Int
    var location: Int
    var id: Int { location }
}

enum Manuscript {
    struct Block: Equatable {
        enum Kind: Equatable {
            case paragraph, heading(Int), quote, code, equation, bullet, numbered, divider, table([[String]])
        }
        var kind: Kind
        var text: String
        var location: Int
        var sourceRange: NSRange? = nil
    }

    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$"#)
    private static let numberedPattern = try! NSRegularExpression(pattern: #"^\d+[.)]\s+"#)
    private static let commentPattern = try! NSRegularExpression(pattern: #"<!--(?s:.*?)-->"#)

    static func blocks(_ source: String) -> [Block] {
        var lines: [(text: String, location: Int)] = []
        let original = source as NSString
        var offset = 0
        while offset < original.length {
            let range = original.lineRange(for: NSRange(location: offset, length: 0))
            lines.append((original.substring(with: range).trimmingCharacters(in: .newlines), offset))
            offset = NSMaxRange(range)
        }
        var index = 0
        var output: [Block] = []
        var htmlComment = false
        while index < lines.count {
            let (raw, position) = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix("<!--") { htmlComment = true }
            if htmlComment {
                if line.contains("-->") { htmlComment = false }
                continue
            }
            if line.isEmpty || line.hasPrefix("%%") || line.hasPrefix("// ") { continue }

            if let fence = codeFence(in: line) {
                var code: [String] = []
                while index < lines.count {
                    let line = lines[index].text
                    index += 1
                    let closing = line.trimmingCharacters(in: .whitespaces)
                    if closing.count >= fence.count && closing.allSatisfy({ $0 == fence.first }) { break }
                    code.append(line)
                }
                let end = index < lines.count ? lines[index].location : original.length
                output.append(.init(kind: .code, text: code.joined(separator: "\n"), location: position,
                                    sourceRange: NSRange(location: position, length: end - position)))
                continue
            }

            if let equation = MathMarkup.wholeLine(line) {
                output.append(.init(kind: .equation, text: equation, location: position,
                                    sourceRange: NSRange(location: position, length: raw.utf16.count)))
                continue
            }
            if let delimiter = MathMarkup.blockDelimiter(line), line == delimiter.opening,
               let last = lines[index...].firstIndex(where: { $0.text.trimmingCharacters(in: .whitespaces) == delimiter.closing }) {
                let content = lines[index..<last].map(\.text).joined(separator: "\n")
                let end = lines[last].location + lines[last].text.utf16.count
                output.append(.init(kind: .equation, text: content, location: position,
                                    sourceRange: NSRange(location: position, length: end - position)))
                index = last + 1
                continue
            }

            if index < lines.count, line.contains("|"), separatorRow(lines[index].text) {
                var rows = [cells(line)]
                index += 1
                while index < lines.count, lines[index].text.contains("|"), !lines[index].text.isEmpty {
                    rows.append(Array(cells(lines[index].text).prefix(rows[0].count)))
                    index += 1
                }
                output.append(.init(kind: .table(rows), text: "", location: position))
                continue
            }

            let parsed = lineBlock(line)
            var text = parsed.text
            if parsed.kind == .paragraph {
                while index < lines.count {
                    let next = lines[index].text.trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || next.hasPrefix("%%") || next.hasPrefix("// ") || next.hasPrefix("<!--")
                        || codeFence(in: next) != nil || lineBlock(next).kind != .paragraph
                        || MathMarkup.wholeLine(next) != nil || MathMarkup.blockDelimiter(next).map({ next == $0.opening }) == true
                        || (next.contains("|") && index + 1 < lines.count && separatorRow(lines[index + 1].text)) {
                        break
                    }
                    text += "\n" + next
                    index += 1
                }
            }
            output.append(.init(kind: parsed.kind, text: text, location: position))
        }
        return output
    }

    private static func codeFence(in line: String) -> String? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let prefix = line.prefix(while: { $0 == marker })
        return prefix.count >= 3 ? String(prefix) : nil
    }

    private static func cells(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func separatorRow(_ line: String) -> Bool {
        let fields = cells(line)
        return fields.count > 1 && fields.allSatisfy {
            let trimmed = $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
        }
    }

    private static func lineBlock(_ line: String) -> (kind: Block.Kind, text: String) {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = headingPattern.firstMatch(in: line, range: range) {
            return (.heading(match.range(at: 1).length), ns.substring(with: match.range(at: 2)))
        }
        if let marker = line.first, "-*_".contains(marker),
           line.filter({ !$0.isWhitespace }).count >= 3,
           line.allSatisfy({ $0 == marker || $0.isWhitespace }) {
            return (.divider, "")
        }
        if line.hasPrefix(">") { return (.quote, String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        if ["- ", "* ", "+ "].contains(where: { line.hasPrefix($0) }) {
            let text = String(line.dropFirst(2))
            if text.lowercased().hasPrefix("[x] ") { return (.bullet, "☑ " + text.dropFirst(4)) }
            if text.hasPrefix("[ ] ") { return (.bullet, "☐ " + text.dropFirst(4)) }
            return (.bullet, text)
        }
        if let match = numberedPattern.firstMatch(in: line, range: range) {
            return (.numbered, ns.substring(from: NSMaxRange(match.range)))
        }
        return (.paragraph, line)
    }

    static func headings(_ source: String) -> [Heading] {
        headings(in: blocks(source))
    }

    static func headings(in blocks: [Block]) -> [Heading] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            return Heading(title: plainInline(block.text), level: level, location: block.location)
        }
    }

    static func standaloneTitle(_ draft: Draft) -> String? {
        guard draft.customTitle != nil else { return nil }
        return standaloneTitle(draft, first: blocks(draft.text).first)
    }

    private static func standaloneTitle(_ draft: Draft, first: Block?) -> String? {
        guard let title = draft.customTitle else { return nil }
        if let first, case .heading = first.kind, plainInline(first.text) == title { return nil }
        return title
    }

    static func plainText(_ source: String) -> String {
        plainText(in: blocks(source))
    }

    static func plainText(in blocks: [Block], forStatistics: Bool = false) -> String {
        func inline(_ source: String) -> String {
            if forStatistics { return plainInline(MathMarkup.inlineSubstitution(source) { _ in " " }) }
            return plainInline(source)
        }
        return blocks.map { block in
            switch block.kind {
            case .divider: ""
            case .code: block.text
            case .equation: forStatistics ? "" : block.text
            case .table(let rows): rows.map { $0.map(inline).joined(separator: "\t") }.joined(separator: "\n")
            default: inline(block.text)
            }
        }.joined(separator: "\n\n")
    }

    static func equation(in source: String, at location: Int) -> MathMarkup.Equation? {
        for block in blocks(source) {
            guard let range = block.sourceRange, NSLocationInRange(location, range) else { continue }
            if block.kind == .code { return nil }
            if block.kind == .equation { return MathMarkup.Equation(source: block.text, display: true, range: range) }
        }
        let ns = source as NSString
        guard (0..<ns.length).contains(location) else { return nil }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        return MathMarkup.inline(in: ns.substring(with: line)).map { equation in
            var result = equation
            result.range.location += line.location
            return result
        }.first { NSLocationInRange(location, $0.range) }
    }

    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\s)]+)\)"#)
    private static let customPattern = try! NSRegularExpression(pattern: #"==(\S(?:.*?\S)?)=="#)

    private static func replacing(_ text: String, pattern: NSRegularExpression, with transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let original = text as NSString
        let edited = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            edited.replaceCharacters(in: match.range, with: transform(match, original))
        }
        return edited as String
    }

    private static func markdownRuns(_ source: String) -> AttributedString {
        let input = commentPattern.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
        return (try? AttributedString(markdown: input, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(input)
    }

    private static func plainInline(_ source: String) -> String {
        let withoutImages = replacing(source, pattern: imagePattern) { match, original in original.substring(with: match.range(at: 1)) }
        let withoutMarks = replacing(withoutImages, pattern: customPattern) { match, original in original.substring(with: match.range(at: 1)) }
        return String(markdownRuns(withoutMarks).characters)
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private struct ProtectedEquation {
        var token: String
        var source: String
        var html: String
    }

    private static func regularInlineHTML(_ source: String, equations: [ProtectedEquation]) -> String {
        let attributed = markdownRuns(source)
        return attributed.runs.map { run in
            var fragment = escaped(String(attributed[run.range].characters))
            for equation in equations { fragment = fragment.replacingOccurrences(of: equation.token, with: equation.html) }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { fragment = "<code>\(fragment)</code>" }
                if intent.contains(.strikethrough) { fragment = "<del>\(fragment)</del>" }
                if intent.contains(.emphasized) { fragment = "<em>\(fragment)</em>" }
                if intent.contains(.stronglyEmphasized) { fragment = "<strong>\(fragment)</strong>" }
            }
            if let url = run.link, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""),
               !equations.contains(where: { url.absoluteString.contains($0.token) }) {
                fragment = "<a href=\"\(escaped(url.absoluteString))\">\(fragment)</a>"
            }
            return fragment
        }.joined()
    }

    private static func inlineHTML(_ source: String, assets: [String: String]) -> String {
        var equations: [ProtectedEquation] = []
        let protected = MathMarkup.inlineSubstitution(source) { equation in
            let token = "InkfolioEquation" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            equations.append(ProtectedEquation(token: token, source: equation.source,
                                               html: MathTeX.shared.render(equation.source, display: false).markup))
            return token
        }
        return inlineMarkupHTML(protected, assets: assets, equations: equations)
    }

    private static func inlineMarkupHTML(_ source: String, assets: [String: String], equations: [ProtectedEquation]) -> String {
        let images = imagePattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let marks = customPattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let ns = source as NSString
        let matches = (images + marks).sorted { $0.range.location < $1.range.location }
        var output = ""
        var index = 0
        for match in matches where match.range.location >= index {
            output += regularInlineHTML(ns.substring(with: NSRange(location: index, length: match.range.location - index)), equations: equations)
            let alt = ns.substring(with: match.range(at: 1))
            if match.numberOfRanges == 3 {
                let key = ns.substring(with: match.range(at: 2))
                let plainAlt = equations.reduce(alt) { $0.replacingOccurrences(of: $1.token, with: $1.source) }
                if let src = assets[key] {
                    output += "<img src=\"\(escaped(src))\" alt=\"\(escaped(plainAlt))\" />"
                } else {
                    output += escaped(plainAlt)
                }
            } else {
                output += "<mark>\(regularInlineHTML(alt, equations: equations))</mark>"
            }
            index = NSMaxRange(match.range)
        }
        return output + regularInlineHTML(ns.substring(from: index), equations: equations)
    }

    static func imageMIME(_ attachment: Attachment) -> String? {
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: attachment.name).pathExtension),
              type.conforms(to: .image), let mime = type.preferredMIMEType,
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else { return nil }
        return mime
    }

    static func embeddedImages(_ draft: Draft) -> [String: String] {
        var result: [String: String] = [:]
        for attachment in draft.attachments where draft.text.contains(attachment.reference) {
            if let mime = imageMIME(attachment) {
                result[attachment.reference] = "data:\(mime);base64,\(attachment.data.base64EncodedString())"
            }
        }
        return result
    }

    static func htmlBody(_ draft: Draft, assets: [String: String]) -> String {
        let blocks = blocks(draft.text)
        var elements = standaloneTitle(draft, first: blocks.first).map { ["<h1>\(escaped($0))</h1>"] } ?? []
        var list: String?
        var inQuote = false
        for block in blocks {
            let nextList: String?
            switch block.kind {
            case .bullet: nextList = "ul"
            case .numbered: nextList = "ol"
            default: nextList = nil
            }
            if list != nextList {
                if let list { elements.append("</\(list)>") }
                if let nextList { elements.append("<\(nextList)>") }
                list = nextList
            }
            let nextQuote = block.kind == .quote
            if inQuote != nextQuote {
                if inQuote { elements.append("</blockquote>") }
                if nextQuote { elements.append("<blockquote>") }
                inQuote = nextQuote
            }

            let value = block.kind == .code || block.kind == .equation ? "" : inlineHTML(block.text, assets: assets)
            switch block.kind {
            case .paragraph: elements.append("<p>\(value.replacingOccurrences(of: "\n", with: "<br />\n"))</p>")
            case .heading(let level):
                let tag = "h\(level)"
                elements.append("<\(tag)>\(value)</\(tag)>")
            case .quote: elements.append("<p>\(value)</p>")
            case .code: elements.append("<pre><code>\(escaped(block.text))</code></pre>")
            case .equation:
                elements.append("<div class=\"equation-display\">\(MathTeX.shared.render(block.text, display: true).markup)</div>")
            case .divider: elements.append("<hr />")
            case .bullet, .numbered: elements.append("<li>\(value)</li>")
            case .table(let rows):
                let content = rows.enumerated().map { index, row in
                    let tag = index == 0 ? "th" : "td"
                    return "<tr>" + row.map { "<\(tag)>\(inlineHTML($0, assets: assets))</\(tag)>" }.joined() + "</tr>"
                }.joined()
                elements.append("<table>\(content)</table>")
            }
        }
        if inQuote { elements.append("</blockquote>") }
        if let list { elements.append("</\(list)>") }
        return elements.joined(separator: "\n")
    }

    static let stylesheet = """
    :root { color-scheme: light dark; }
    body { margin: 2.8rem auto; padding: 0 2.2rem; max-width: 40em; color: #1d1d1f;
           background: #ffffff; font: 18px/1.9 -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", sans-serif;
           overflow-wrap: break-word; -webkit-font-smoothing: antialiased; }
    h1,h2,h3,h4,h5,h6 { color: #1d1d1f; line-height: 1.38; margin: 1.55em 0 .55em; font-weight: 600; }
    h1 { font-size: 2.0em; margin-top: .25em; }
    h2 { font-size: 1.48em; }
    h3 { font-size: 1.22em; }
    a { color: #0a7aff; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    blockquote { border-inline-start: 2.5px solid #0a7aff; margin: 1.2em 0; padding-inline: 1.15em; color: #636366; }
    blockquote p { margin: .45em 0; }
    code, pre { background: #f5f6f8; font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: .88em; border-radius: 6px; }
    code { padding: .14em .36em; } pre { white-space: pre-wrap; padding: 1em 1.2em; }
    pre code { padding: 0; background: transparent; border-radius: 0; }
    img { max-width: 100%; height: auto; border-radius: 8px; }
    math { font-size: 1.08em; }
    .equation-display { text-align: center; margin: 1.2em 0; overflow-x: auto; }
    table { border-collapse: collapse; width: 100%; margin: 1.2em 0; font-size: .94em; }
    th, td { border-bottom: 1px solid #e5e5ea; padding: .5em .8em; text-align: left; }
    th { font-weight: 600; border-bottom-width: 2px; }
    mark { background: rgba(208,122,59,.22); color: inherit; padding: .06em .24em; border-radius: 4px; }
    hr { border: 0; border-top: 1px solid #e5e5ea; margin: 2em 0; }
    article + article { border-block-start: 1px solid #e5e5ea; margin-top: 3em; padding-top: 1.5em; }
    @media (prefers-color-scheme:dark) {
      body { background: #18191b; color: #ebebf0; }
      h1,h2,h3,h4,h5,h6 { color: #f5f5f7; }
      a { color: #3a94ff; }
      blockquote { border-inline-start-color: #3a94ff; color: #a1a1a6; }
      code, pre { background: #232528; }
      th, td, hr, article + article { border-color: #2c2d31; }
      mark { background: rgba(230,156,99,.26); }
    }
    """

    static func previewBody(_ drafts: [Draft]) -> String {
        drafts.map { draft in
            "<article>\(htmlBody(draft, assets: embeddedImages(draft)))</article>"
        }.joined(separator: "\n")
    }

    static func html(_ drafts: [Draft], appearance: String? = nil) -> String {
        htmlDocument(title: drafts.first?.name ?? "MiMi", body: previewBody(drafts), appearance: appearance)
    }

    static func htmlDocument(title: String, body: String, appearance: String? = nil, extraStyle: String = "") -> String {
        let override: String
        switch appearance {
        case "dark":
            override = ":root { color-scheme: dark; } body { background:#18191b;color:#ebebf0; } h1,h2,h3,h4,h5,h6{color:#f5f5f7} a{color:#3a94ff} blockquote{border-inline-start-color:#3a94ff;color:#a1a1a6} code,pre{background:#232528} th,td,hr,article+article{border-color:#2c2d31} mark{background:rgba(230,156,99,.26)}"
        case "light":
            override = ":root { color-scheme: light; } body { background:#ffffff;color:#1d1d1f; } h1,h2,h3,h4,h5,h6{color:#1d1d1f} a{color:#0a7aff} blockquote{border-inline-start-color:#0a7aff;color:#636366} code,pre{background:#f5f6f8} th,td,hr,article+article{border-color:#e5e5ea} mark{background:rgba(208,122,59,.22)}"
        default: override = ""
        }
        return """
        <!doctype html>
        <html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <title>\(escaped(title))</title><style>\(stylesheet)\(override)\(extraStyle)</style></head>
        <body>\(body)</body></html>
        """
    }

    private static func serifExportFont(size: CGFloat, bold: Bool) -> NSFont {
        let latin = NSFont(name: bold ? "Georgia-Bold" : "Georgia", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let cjkName = bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
        if NSFont(name: cjkName, size: size) != nil {
            let cascade = NSFontDescriptor(name: cjkName, size: size)
            let descriptor = latin.fontDescriptor.addingAttributes([.cascadeList: [cascade]])
            if let combined = NSFont(descriptor: descriptor, size: size) { return combined }
        }
        return latin
    }

    static func attributed(_ drafts: [Draft]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let foreground = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.14, alpha: 1)
        let titleColor = NSColor(srgbRed: 0.16, green: 0.30, blue: 0.23, alpha: 1)
        let markColor = NSColor(srgbRed: 0.92, green: 0.84, blue: 0.65, alpha: 0.55)
        var listNumber = 0
        func append(_ text: String, size: CGFloat = 12, bold: Bool = false, monospace: Bool = false,
                    inset: CGFloat = 0, spacing: CGFloat = 12, markdown: Bool = true) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.lineSpacing = 4
            style.headIndent = inset
            style.firstLineHeadIndent = inset
            func appendChunk(_ raw: String, highlighted: Bool) {
                let attributed = markdown ? markdownRuns(raw) : AttributedString(raw)
                func appendRun(_ value: String, intent: InlinePresentationIntent?, link: URL? = nil) {
                    let strong = bold || intent?.contains(.stronglyEmphasized) == true
                    let font = monospace || intent?.contains(.code) == true
                        ? NSFont.monospacedSystemFont(ofSize: size, weight: strong ? .bold : .regular)
                        : serifExportFont(size: size, bold: strong)
                    let effectiveFont = intent?.contains(.emphasized) == true ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
                    var attributes: [NSAttributedString.Key: Any] = [.font: effectiveFont, .foregroundColor: bold ? titleColor : foreground, .paragraphStyle: style]
                    if highlighted { attributes[.backgroundColor] = markColor }
                    if intent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if let link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                        attributes[.link] = link
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    result.append(NSAttributedString(string: value, attributes: attributes))
                }
                for run in attributed.runs {
                    appendRun(String(attributed[run.range].characters), intent: run.inlinePresentationIntent, link: run.link)
                }
            }
            if markdown {
                let ns = text as NSString
                let matches = customPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
                var cursor = 0
                for match in matches where match.range.location >= cursor {
                    if match.range.location > cursor {
                        appendChunk(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), highlighted: false)
                    }
                    appendChunk(ns.substring(with: match.range(at: 1)), highlighted: true)
                    cursor = NSMaxRange(match.range)
                }
                if cursor < ns.length { appendChunk(ns.substring(from: cursor), highlighted: false) }
            } else {
                appendChunk(text, highlighted: false)
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: serifExportFont(size: size, bold: bold), .paragraphStyle: style]))
        }
        for (index, draft) in drafts.enumerated() {
            if index != 0 { append("", spacing: 22) }
            let blocks = blocks(draft.text)
            if let title = standaloneTitle(draft, first: blocks.first) {
                append(title, size: 26, bold: true, spacing: 18, markdown: false)
            }
            for block in blocks {
                if block.kind != .numbered { listNumber = 0 }
                switch block.kind {
                case .heading(let level): append(block.text, size: max(12, 22 - CGFloat(level) * 2), bold: true)
                case .quote: append(block.text, inset: 18)
                case .code: append(block.text, size: 10, monospace: true, inset: 12, markdown: false)
                case .equation: append(block.text, size: 11, monospace: true, inset: 12, markdown: false)
                case .bullet: append("•  " + block.text, inset: 14, spacing: 4)
                case .numbered:
                    listNumber += 1
                    append("\(listNumber).  " + block.text, inset: 14, spacing: 4)
                case .divider: append("────────", spacing: 14)
                case .table(let rows):
                    for (index, row) in rows.enumerated() { append(row.joined(separator: "   |   "), bold: index == 0, spacing: 5) }
                case .paragraph:
                    let ns = block.text as NSString
                    let match = imagePattern.firstMatch(in: block.text, range: NSRange(location: 0, length: ns.length))
                    if let match, match.range.length == ns.length,
                       let attachment = draft.attachments.first(where: { $0.reference == ns.substring(with: match.range(at: 2)) }),
                       let image = NSImage(data: attachment.data) {
                        let factor = min(1, 370 / max(image.size.width, 1), 225 / max(image.size.height, 1))
                        image.size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
                        let item = NSTextAttachment()
                        item.image = image
                        result.append(NSAttributedString(attachment: item))
                        append("")
                    } else {
                        let text = replacing(block.text, pattern: imagePattern) { match, original in original.substring(with: match.range(at: 1)) }
                        append(text)
                    }
                }
            }
        }
        if result.length == 0 { append("") }
        return result
    }
}
