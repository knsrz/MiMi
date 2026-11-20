import Foundation

struct EditorMarkdown {
    enum BlockKind {
        case heading(Int, prefix: NSRange)
        case quote(prefix: NSRange)
        case list(prefix: NSRange)
        case code
        case codeFence
        case equation
        case comment
        case divider
        case table
    }

    struct Block {
        var kind: BlockKind
        var range: NSRange
    }

    struct Run {
        var range: NSRange
        var intent: InlinePresentationIntent = []
        var link = false
        var linkURL: URL? = nil
        var highlight = false
        var equation = false
        var image = false
    }

    struct Marker {
        var range: NSRange
        var taskBoxRange: NSRange? = nil
    }

    var blocks: [Block] = []
    var runs: [Run] = []
    var markers: [Marker] = []

    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
    private static let closingHeading = try! NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)
    private static let quote = try! NSRegularExpression(pattern: #"^ {0,3}(?:>[ \t]?)+[ \t]*"#)
    private static let list = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*]|\d{1,9}[.)])([ \t]+)(\[[ xX]\](?=[ \t]|$))?"#)
    private static let highlight = try! NSRegularExpression(pattern: #"(?<![\\=])==(?![ =])([^\r\n]+?)(?<![\\ =])==(?![=])"#)
    private static let imagePattern = try! NSRegularExpression(pattern: #"(?<!\\)!\[([^\]\r\n]*)\]\(([^\s)\r\n]+)\)"#)

    init(_ source: String, offset: Int = 0) {
        let text = source as NSString
        var location = 0
        var fence: (marker: Character, count: Int)?
        var equationEnd: String?
        var inComment = false

        while location < text.length, !Task.isCancelled {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let paragraph = NSRange(location: offset + location, length: end - location)
            let line = text.substring(with: NSRange(location: location, length: contentsEnd - location))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineLength = contentsEnd - location
            let lineRange = NSRange(location: 0, length: lineLength)
            let lineText = line as NSString
            let base = offset + location
            location = end

            if let current = fence {
                let count = trimmed.prefix(while: { $0 == current.marker }).count
                if count >= current.count && trimmed.dropFirst(count).allSatisfy(\.isWhitespace) {
                    fence = nil
                    blocks.append(Block(kind: .codeFence, range: paragraph))
                } else {
                    blocks.append(Block(kind: .code, range: paragraph))
                }
                continue
            }
            if inComment || trimmed.hasPrefix("<!--") {
                inComment = !trimmed.contains("-->")
                blocks.append(Block(kind: .comment, range: paragraph))
                continue
            }
            if let current = equationEnd {
                if trimmed == current { equationEnd = nil }
                blocks.append(Block(kind: .equation, range: paragraph))
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3, marker != "`" || !trimmed.dropFirst(count).contains("`") {
                    fence = (marker, count)
                    blocks.append(Block(kind: .codeFence, range: paragraph))
                    continue
                }
            }
            if let delimiter = MathMarkup.blockDelimiter(trimmed), trimmed == delimiter.opening {
                equationEnd = delimiter.closing
                blocks.append(Block(kind: .equation, range: paragraph))
                continue
            }
            if MathMarkup.wholeLine(trimmed) != nil {
                blocks.append(Block(kind: .equation, range: paragraph))
                continue
            }
            if trimmed.hasPrefix("%%") || trimmed.hasPrefix("// ") {
                blocks.append(Block(kind: .comment, range: paragraph))
                continue
            }

            var content = lineRange
            if let match = Self.heading.firstMatch(in: line, range: lineRange), NSMaxRange(match.range) < lineLength {
                let prefix = Self.shift(match.range, by: base)
                blocks.append(Block(kind: .heading(match.range(at: 1).length, prefix: prefix), range: paragraph))
                markers.append(Marker(range: prefix))
                content.location = NSMaxRange(match.range)
                if let trailing = Self.closingHeading.firstMatch(in: line, range: lineRange), trailing.range.location >= content.location {
                    markers.append(Marker(range: Self.shift(trailing.range, by: base)))
                    content.length = trailing.range.location - content.location
                } else {
                    content.length = lineLength - content.location
                }
            } else if let match = Self.quote.firstMatch(in: line, range: lineRange), NSMaxRange(match.range) < lineLength {
                let prefix = Self.shift(match.range, by: base)
                blocks.append(Block(kind: .quote(prefix: prefix), range: paragraph))
                markers.append(Marker(range: prefix))
                content = NSRange(location: NSMaxRange(match.range), length: lineLength - NSMaxRange(match.range))
            } else if let first = trimmed.first, "-*_".contains(first),
                      trimmed.filter({ !$0.isWhitespace }).count >= 3,
                      trimmed.allSatisfy({ $0 == first || $0.isWhitespace }) {
                blocks.append(Block(kind: .divider, range: paragraph))
                markers.append(Marker(range: Self.shift(lineRange, by: base)))
                continue
            } else if let match = Self.list.firstMatch(in: line, range: lineRange) {
                let marker = match.range(at: 2)
                let task = match.range(at: 4)
                var bodyStart = NSMaxRange(match.range)
                markers.append(Marker(range: Self.shift(marker, by: base)))
                if task.location != NSNotFound {
                    let box = Self.shift(task, by: base)
                    markers.append(Marker(range: box, taskBoxRange: box))
                    while bodyStart < lineLength, [9, 32].contains(lineText.character(at: bodyStart)) {
                        bodyStart += 1
                    }
                }
                let prefix = NSRange(location: base, length: bodyStart)
                blocks.append(Block(kind: .list(prefix: prefix), range: paragraph))
                content = NSRange(location: bodyStart, length: lineLength - bodyStart)
            } else if trimmed.hasPrefix("|"), trimmed.filter({ $0 == "|" }).count >= 2 {
                blocks.append(Block(kind: .table, range: paragraph))
            }
            if content.length > 0 {
                let body = lineText.substring(with: content)
                let start = base + content.location
                let math = MathMarkup.inline(in: body)
                if math.isEmpty {
                    inline(body, base: start)
                } else {
                    let bodyText = body as NSString
                    var previous = 0
                    for equation in math {
                        inline(bodyText.substring(with: NSRange(location: previous, length: equation.range.location - previous)),
                               base: start + previous)
                        runs.append(Run(range: Self.shift(equation.range, by: start), equation: true))
                        previous = NSMaxRange(equation.range)
                    }
                    inline(bodyText.substring(from: previous), base: start + previous)
                }
            }
        }
    }

    private static func shift(_ range: NSRange, by base: Int) -> NSRange {
        NSRange(location: range.location + base, length: range.length)
    }

    private mutating func inline(_ value: String, base: Int) {
        guard value.utf8.contains(where: { "*_~`[<\\=!".utf8.contains($0) }),
              let parsed = try? AttributedString(markdown: value,
                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true)) else { return }
        let text = value as NSString
        // Foundation reports one-based, inclusive UTF-8 columns. TextKit ranges are UTF-16.
        var offsets: [Int] = []
        offsets.reserveCapacity(value.utf8.count + 1)
        var utf16 = 0
        for scalar in value.unicodeScalars {
            offsets.append(contentsOf: repeatElement(utf16, count: scalar.utf8.count))
            utf16 += scalar.utf16.count
        }
        offsets.append(utf16)

        var previous = 0
        var priorLink = false
        var priorIntent: InlinePresentationIntent = []
        var codeRanges: [NSRange] = []
        for run in parsed.runs {
            guard let position = run.markdownSourcePosition, position.startLine == 1, position.endLine == 1,
                  offsets.indices.contains(position.startColumn - 1), offsets.indices.contains(position.endColumn) else { continue }
            let start = offsets[position.startColumn - 1]
            let end = offsets[position.endColumn]
            guard start >= previous, end > start else { continue }
            let intent = run.inlinePresentationIntent ?? []
            let link = run.link != nil
            let isStyled = !intent.isEmpty || link
            let wasStyled = !priorIntent.isEmpty || priorLink
            let interval = NSRange(location: start, length: end - start)
            if intent.contains(.code) { codeRanges.append(interval) }
            if isStyled {
                runs.append(Run(range: Self.shift(interval, by: base), intent: intent, link: link, linkURL: run.link))
            }
            let gap = NSRange(location: previous, length: start - previous)
            if gap.length > 0 {
                let delimiters = text.substring(with: gap)
                if Self.isMarker(delimiters, priorLink: priorLink, nextLink: link,
                                 styled: wasStyled || isStyled) {
                    markers.append(Marker(range: Self.shift(gap, by: base)))
                }
            }
            previous = end
            priorLink = link
            priorIntent = intent
        }
        if previous < text.length {
            let gap = NSRange(location: previous, length: text.length - previous)
            if Self.isMarker(text.substring(with: gap), priorLink: priorLink, nextLink: false, styled: !priorIntent.isEmpty) {
                markers.append(Marker(range: Self.shift(gap, by: base)))
            }
        }
        var imageRanges: [NSRange] = []
        if value.contains("![") {
            for match in Self.imagePattern.matches(in: value, range: NSRange(location: 0, length: text.length))
                where !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                imageRanges.append(match.range)
                let alt = match.range(at: 1)
                if alt.length > 0 {
                    runs.append(Run(range: Self.shift(alt, by: base), image: true))
                    markers.append(Marker(range: NSRange(location: base + match.range.location, length: 2)))
                    let tailStart = NSMaxRange(alt)
                    let tailLength = NSMaxRange(match.range) - tailStart
                    if tailLength > 0 {
                        markers.append(Marker(range: NSRange(location: base + tailStart, length: tailLength)))
                    }
                } else {
                    runs.append(Run(range: Self.shift(match.range, by: base), image: true))
                }
            }
        }

        for match in Self.highlight.matches(in: value, range: NSRange(location: 0, length: text.length))
            where !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                && !imageRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            let inner = match.range(at: 1)
            runs.append(Run(range: Self.shift(inner, by: base), highlight: true))
            markers.append(Marker(range: NSRange(location: base + match.range.location, length: 2)))
            markers.append(Marker(range: NSRange(location: base + NSMaxRange(inner), length: 2)))
        }
    }

    private static func isMarker(_ value: String, priorLink: Bool, nextLink: Bool, styled: Bool) -> Bool {
        if nextLink && (value == "[" || value == "<") { return true }
        if priorLink && value == ">" { return true }
        if priorLink, value.hasPrefix("]("), value.hasSuffix(")") || (nextLink && value.hasSuffix(")[")) { return true }
        return styled && value.allSatisfy { "*_~`".contains($0) }
    }
}
