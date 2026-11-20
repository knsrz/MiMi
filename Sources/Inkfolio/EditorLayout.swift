import AppKit

extension NSAttributedString.Key {
    static let paragraphRule = NSAttributedString.Key("Inkfolio.ParagraphRule")
    static let fencedMarkup = NSAttributedString.Key("Inkfolio.FencedMarkup")
    static let codeBlockFill = NSAttributedString.Key("Inkfolio.CodeBlockFill")
    static let markdownLink = NSAttributedString.Key("Inkfolio.MarkdownLink")
    static let taskToggleRange = NSAttributedString.Key("Inkfolio.TaskToggleRange")
}

struct EditorSpacing: Equatable {
    static let regular = Self(line: 11, paragraph: 0, indent: 0)
    static let markerGutter: CGFloat = 28

    var line: Double
    var paragraph: Double
    var indent: Double

    func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = line
        style.paragraphSpacing = paragraph
        style.headIndent = Self.markerGutter
        style.firstLineHeadIndent = Self.markerGutter + indent
        style.tailIndent = -Self.markerGutter
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func placePrefix(_ prefix: String, font: NSFont, before bodyIndent: CGFloat,
                            in style: NSMutableParagraphStyle) {
        let width = (prefix as NSString).size(withAttributes: [.font: font]).width
        style.firstLineHeadIndent = max(0, bodyIndent - width)
        style.headIndent = style.firstLineHeadIndent + width
    }

    static func placeListPrefix(_ prefix: String, font: NSFont, in style: NSMutableParagraphStyle) {
        style.paragraphSpacing = 0
        style.firstLineHeadIndent = markerGutter + 24
        let tabInterval: CGFloat = 24
        style.tabStops = []
        style.defaultTabInterval = tabInterval
        var position = style.firstLineHeadIndent
        for (index, part) in prefix.components(separatedBy: "\t").enumerated() {
            if index > 0 { position = (floor(position / tabInterval) + 1) * tabInterval }
            position += (part as NSString).size(withAttributes: [.font: font]).width
        }
        style.headIndent = position
    }
}
