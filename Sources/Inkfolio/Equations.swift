import Foundation
import JavaScriptCore

enum MathMarkup {
    struct Equation: Equatable {
        var source: String
        var display: Bool
        var range: NSRange
    }

    private static let inlinePattern = try! NSRegularExpression(pattern:
        #"(?<![\\$])\$\$(?!\$)((?:\\.|[^$\\\r\n])+?)(?<!\\)\$\$(?!\$)|(?<![\\$])\$(?![\s$])((?:\\.|[^$\\\r\n])+?)(?<![\\\s])\$(?![$\d])|(?<!\\)\\\(([^\r\n]+?)(?<!\\)\\\)"#
    )
    private static let codePattern = try! NSRegularExpression(
        pattern: #"(?<!`)(`+)(?!`)[^\r\n]*?\1(?!`)"#
    )

    static func inline(in text: String) -> [Equation] {
        guard text.contains("$") || text.contains(#"\("#) else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let code = text.contains("`") ? codePattern.matches(in: text, range: whole).map(\.range) : []
        return inlinePattern.matches(in: text, range: whole).compactMap { match in
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let content = (1..<match.numberOfRanges).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return nil }
            let source = ns.substring(with: content).trimmingCharacters(in: .whitespaces)
            return source.isEmpty ? nil : Equation(source: source, display: false, range: match.range)
        }
    }

    static func inlineSubstitution(_ text: String, replacement: (Equation) -> String) -> String {
        let matches = inline(in: text)
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: text)
        for equation in matches.reversed() {
            output.replaceCharacters(in: equation.range, with: replacement(equation))
        }
        return output as String
    }

    static func blockDelimiter(_ line: String) -> (opening: String, closing: String)? {
        if line.hasPrefix("$$"), !line.hasPrefix("$$$") { return ("$$", "$$") }
        if line.hasPrefix(#"\["#) { return (#"\["#, #"\]"#) }
        return nil
    }

    static func wholeLine(_ line: String) -> String? {
        guard let delimiter = blockDelimiter(line), line.count > 4, line.hasSuffix(delimiter.closing) else { return nil }
        let inner = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        if delimiter.opening == "$$", inner.contains("$$") { return nil }
        return inner.isEmpty ? nil : inner
    }
}

final class MathTeX {
    struct Render {
        var markup: String
        var error: String?
    }

    static let shared = MathTeX()
    private let context: JSContext?
    private let lock = NSLock()
    private var cache: [Key: Render] = [:]

    private struct Key: Hashable {
        var source: String
        var display: Bool
    }

    private init() {
        #if INKFOLIO_TESTS
        let resource = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Sources/Inkfolio/Resources/KaTeX/katex.min.js")
        #elseif SWIFT_PACKAGE
        let resource = Bundle.module.resourceURL?.appending(path: "KaTeX/katex.min.js")
        #else
        let resource = Bundle.main.resourceURL?.appending(path: "KaTeX/katex.min.js")
        #endif

        #if INKFOLIO_TESTS
        let file: URL? = resource
        #else
        let file = resource
        #endif

        guard let file, let library = try? String(contentsOf: file, encoding: .utf8), let runtime = JSContext() else {
            context = nil
            return
        }
        runtime.evaluateScript(library, withSourceURL: file)
        runtime.evaluateScript("""
        function renderInkfolioEquation(source, display) {
            try {
                return {value: katex.renderToString(source, {
                    displayMode: display, output: "mathml",
                    throwOnError: true, strict: "ignore", trust: false,
                    maxExpand: 350, maxSize: 35
                })};
            } catch (error) {
                return {error: String(error.message || error)};
            }
        }
        """)
        context = runtime
    }

    func render(_ source: String, display: Bool) -> Render {
        let fallback = "<code>" + Manuscript.escaped(source) + "</code>"
        guard source.utf16.count <= 8_000 else {
            return Render(markup: fallback, error: "单个方程最多支持 8,000 个字符。")
        }
        let key = Key(source: source, display: display)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        let response = context?.objectForKeyedSubscript("renderInkfolioEquation")
            .call(withArguments: [source, display])
        let value = response?.objectForKeyedSubscript("value")
        let result: Render
        if let value, value.isString, let markup = value.toString() {
            result = Render(markup: markup, error: nil)
        } else {
            let error = response?.objectForKeyedSubscript("error")
            result = Render(markup: fallback, error: error?.isString == true ? error?.toString() : "公式渲染器未能载入。")
        }
        if cache.count >= 384 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }
}
