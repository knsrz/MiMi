import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum FixedScroll: String, CaseIterable {
    case off, top, middle, bottom

    var label: String {
        switch self {
        case .off: "关"
        case .top: "顶部"
        case .middle: "中间"
        case .bottom: "底部"
        }
    }

    var proportion: CGFloat? {
        switch self {
        case .off: nil
        case .top: 0.20
        case .middle: 0.48
        case .bottom: 0.78
        }
    }

    static func resolve(_ setting: String, legacy: Bool) -> Self {
        Self(rawValue: setting) ?? (legacy ? .middle : .off)
    }
}

enum Markup: String, CaseIterable, Identifiable {
    case strong, emphasis, highlight, strike, heading, quote, bullet, task, link, code
    var id: Self { self }

    var label: String {
        switch self {
        case .strong: "粗体"
        case .emphasis: "斜体"
        case .highlight: "高亮"
        case .strike: "删除线"
        case .heading: "切换标题"
        case .quote: "引用"
        case .bullet: "无序列表"
        case .task: "待办列表"
        case .link: "链接"
        case .code: "行内代码"
        }
    }

    var symbol: String {
        switch self {
        case .strong: "bold"
        case .emphasis: "italic"
        case .highlight: "highlighter"
        case .strike: "strikethrough"
        case .heading: "number"
        case .quote: "text.quote"
        case .bullet: "list.bullet"
        case .task: "checklist"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tokens: (String, String) {
        switch self {
        case .strong: ("**", "**")
        case .emphasis: ("*", "*")
        case .highlight: ("==", "==")
        case .strike: ("~~", "~~")
        case .heading: ("## ", "")
        case .quote: ("> ", "")
        case .bullet: ("- ", "")
        case .task: ("- [ ] ", "")
        case .link: ("[", "](https://)")
        case .code: ("`", "`")
        }
    }
}

@MainActor
final class EditorBridge: ObservableObject {
    weak var view: NSTextView?
    var viewID: UUID?
    @Published var selectionWords = 0
    @Published var caretLocation = 0
    private var pendingFocus: (id: UUID, atEnd: Bool)?
    private struct Bookmark {
        var selection: NSRange
        var offset: CGPoint
    }
    private var bookmarks: [UUID: Bookmark] = [:]

    func attach(_ textView: NSTextView, id: UUID) {
        if let view, let viewID, view !== textView { remember(view, id: viewID) }
        view = textView
        viewID = id
        let pending = pendingFocus?.id == id ? pendingFocus : nil
        if pending != nil { pendingFocus = nil }
        let targetCaret: Int
        if let pending, pending.atEnd {
            let end = textView.string.utf16.count
            textView.setSelectedRange(NSRange(location: end, length: 0))
            targetCaret = end
        } else if let bookmark = bookmarks[id] {
            let length = textView.string.utf16.count
            let adjusted = min(bookmark.selection.location, length)
            textView.setSelectedRange(NSRange(location: adjusted, length: min(bookmark.selection.length, length - adjusted)))
            targetCaret = adjusted
        } else {
            targetCaret = textView.selectedRange().location
        }
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, self.view === textView else { return }
            if self.selectionWords != 0 { self.selectionWords = 0 }
            if self.caretLocation != targetCaret { self.caretLocation = targetCaret }
            if pending?.atEnd != true, let offset = self.bookmarks[id]?.offset, let scroll = textView.enclosingScrollView {
                if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
                let origin = scroll.contentView.constrainBoundsRect(CGRect(origin: offset, size: scroll.contentSize)).origin
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if pending != nil { textView.window?.makeFirstResponder(textView) }
        }
    }

    func remember(_ view: NSTextView, id: UUID) {
        if bookmarks.count >= 128, bookmarks[id] == nil { bookmarks.removeAll(keepingCapacity: true) }
        bookmarks[id] = Bookmark(selection: view.selectedRange(),
                                offset: view.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }

    func focus(_ id: UUID, atEnd: Bool = false) {
        if viewID == id, let view, let window = view.window {
            if atEnd {
                let end = view.string.utf16.count
                view.setSelectedRange(NSRange(location: end, length: 0))
            }
            window.makeFirstResponder(view)
        } else {
            pendingFocus = (id, atEnd)
        }
    }

    func insert(_ source: String, in id: UUID) {
        guard let view, viewID == id, view.isEditable else { return }
        let range = view.selectedRange()
        view.insertText(source, replacementRange: range)
        view.window?.makeFirstResponder(view)
    }

    func equationEdit(in draft: Draft) -> EquationEdit? {
        guard let view, viewID == draft.id, view.isEditable else { return nil }
        let original = view.string
        let selection = view.selectedRange()
        if let equation = Manuscript.equation(in: original, at: selection.location),
           NSMaxRange(selection) <= NSMaxRange(equation.range) {
            return EquationEdit(draftID: draft.id, range: equation.range, original: original,
                                source: equation.source, display: equation.display)
        }
        let selected = (original as NSString).substring(with: selection)
        let raw = original as NSString
        let line = raw.substring(with: raw.lineRange(for: selection)).trimmingCharacters(in: .whitespacesAndNewlines)
        return EquationEdit(draftID: draft.id, range: selection, original: original, source: selected,
                            display: selected.contains("\n") || line.isEmpty || line == "$$")
    }

    func insertEquation(_ source: String, display: Bool, edit: EquationEdit) -> Bool {
        guard let view, viewID == edit.draftID, view.isEditable, view.string == edit.original else { return false }
        let value = display ? isolatedBlock("$$\n" + source + "\n$$", in: view.string, replacing: edit.range)
            : #"\("# + source.replacingOccurrences(of: "\n", with: " ") + #"\)"#
        view.insertText(value, replacementRange: edit.range)
        view.window?.makeFirstResponder(view)
        return true
    }

    func insertBlock(_ source: String, in id: UUID) {
        guard let view, viewID == id, view.isEditable else { return }
        let selection = view.selectedRange()
        let value = isolatedBlock(source, in: view.string, replacing: NSRange(location: NSMaxRange(selection), length: 0))
        view.insertText(value, replacementRange: NSRange(location: NSMaxRange(selection), length: 0))
        view.window?.makeFirstResponder(view)
    }

    private func isolatedBlock(_ content: String, in source: String, replacing range: NSRange) -> String {
        let raw = source as NSString
        let start = range.location
        let end = NSMaxRange(range)
        let startsLine = start == 0 || [10, 13].contains(raw.character(at: start - 1))
        let endsLine = end == raw.length || [10, 13].contains(raw.character(at: end))
        return (startsLine ? "" : "\n") + content + (endsLine ? "" : "\n")
    }

    func format(_ markup: Markup, in id: UUID) {
        guard let view, viewID == id, view.isEditable else { return }
        let source = view.string as NSString
        let current = view.selectedRange()

        if markup == .heading {
            let lineRange = source.lineRange(for: NSRange(location: current.location, length: 0))
            let line = source.substring(with: lineRange)
            let trimmed = line.drop(while: { $0 == " " })
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            let leadSpaces = line.prefix(while: { $0 == " " }).count
            let afterHashes = trimmed.dropFirst(hashes)
            let hasHeading = (1...6).contains(hashes) && (afterHashes.first == " " || afterHashes.first == "\t")
            let existingLength = hasHeading ? (leadSpaces + hashes + 1) : 0
            let nextPrefix: String
            switch hasHeading ? hashes : 0 {
            case 0: nextPrefix = "## "
            case 2: nextPrefix = "### "
            case 3: nextPrefix = "# "
            default: nextPrefix = ""
            }
            let replaceRange = NSRange(location: lineRange.location, length: existingLength)
            view.insertText(nextPrefix, replacementRange: replaceRange)
            let delta = nextPrefix.utf16.count - existingLength
            let nextLocation = max(lineRange.location, current.location + delta)
            view.setSelectedRange(NSRange(location: min(nextLocation, view.string.utf16.count), length: current.length))
            view.window?.makeFirstResponder(view)
            return
        }

        let (start, end) = markup.tokens
        if end.isEmpty {
            let blockRange = source.lineRange(for: current)
            let selectedBlock = source.substring(with: blockRange)
            let lines = selectedBlock.components(separatedBy: "\n")
            let hasTrailingNewline = selectedBlock.hasSuffix("\n")
            let editableLines = hasTrailingNewline ? Array(lines.dropLast()) : lines
            let nonEmpty = editableLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allPrefixed = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(start) }
            let updated = editableLines.map { line -> String in
                if allPrefixed {
                    return line.hasPrefix(start) ? String(line.dropFirst(start.count)) : line
                } else {
                    return line.trimmingCharacters(in: .whitespaces).isEmpty && editableLines.count > 1 ? line : start + line
                }
            }
            let replacement = updated.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
            view.insertText(replacement, replacementRange: blockRange)
            if current.length == 0 {
                let delta = allPrefixed ? -start.utf16.count : start.utf16.count
                let pos = max(blockRange.location, min(view.string.utf16.count, current.location + delta))
                view.setSelectedRange(NSRange(location: pos, length: 0))
            } else {
                view.setSelectedRange(NSRange(location: blockRange.location, length: replacement.utf16.count - (hasTrailingNewline ? 1 : 0)))
            }
            view.window?.makeFirstResponder(view)
            return
        }

        if markup == .link {
            let content = source.substring(with: current)
            let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clipURL = (!clip.contains("\n") && (clip.hasPrefix("https://") || clip.hasPrefix("http://")) && URL(string: clip) != nil) ? clip : nil
            if current.length == 0 {
                let url = clipURL ?? "https://"
                view.insertText("[](\(url))", replacementRange: current)
                view.setSelectedRange(NSRange(location: current.location + 1, length: 0))
            } else if let clipURL {
                let inserted = "[\(content)](\(clipURL))"
                view.insertText(inserted, replacementRange: current)
                view.setSelectedRange(NSRange(location: current.location + inserted.utf16.count, length: 0))
            } else {
                let inserted = "[\(content)](https://)"
                view.insertText(inserted, replacementRange: current)
                let urlStart = current.location + 1 + content.utf16.count + 2
                view.setSelectedRange(NSRange(location: urlStart, length: "https://".utf16.count))
            }
            view.window?.makeFirstResponder(view)
            return
        }

        let content = source.substring(with: current)
        let opening = start.utf16.count
        let closing = end.utf16.count
        if content.hasPrefix(start), content.hasSuffix(end), content.utf16.count >= opening + closing {
            let inner = (content as NSString).substring(with: NSRange(location: opening, length: content.utf16.count - opening - closing))
            view.insertText(inner, replacementRange: current)
            view.setSelectedRange(NSRange(location: current.location, length: inner.utf16.count))
            view.window?.makeFirstResponder(view)
            return
        }
        if current.location >= opening, NSMaxRange(current) + closing <= source.length {
            let wider = NSRange(location: current.location - opening, length: current.length + opening + closing)
            if source.substring(with: wider) == start + content + end {
                view.insertText(content, replacementRange: wider)
                view.setSelectedRange(NSRange(location: wider.location, length: current.length))
                view.window?.makeFirstResponder(view)
                return
            }
        }
        view.insertText(start + content + end, replacementRange: current)
        view.setSelectedRange(NSRange(location: current.location + opening, length: current.length))
        view.window?.makeFirstResponder(view)
    }

    func jump(to location: Int, in id: UUID) {
        guard let view, viewID == id, location <= view.string.utf16.count else { return }
        let destination = NSRange(location: location, length: 0)
        view.setSelectedRange(destination)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.scrollRangeToVisible(destination)
        view.window?.makeFirstResponder(view)
    }

    func splitIndex(for draft: Draft) -> String.Index? {
        guard viewID == draft.id, let location = view?.selectedRange().location,
              location > 0, location < draft.text.utf16.count else { return nil }
        return Range(NSRange(location: location, length: 0), in: draft.text)?.lowerBound
    }
}

final class InkEditorScrollView: NSScrollView {
    var editorMaxWidth: CGFloat = 680 { didSet { if oldValue != editorMaxWidth { updateTextInsets() } } }
    var minHorizontalPadding: CGFloat = 36 { didSet { if oldValue != minHorizontalPadding { updateTextInsets() } } }
    var topPadding: CGFloat = 34 { didSet { if oldValue != topPadding { updateTextInsets() } } }
    var fixedScroll: FixedScroll = .off { didSet { if oldValue != fixedScroll { updateTextInsets() } } }

    override func layout() {
        super.layout()
        updateTextInsets()
    }

    func updateTextInsets() {
        guard let textView = documentView as? InkNativeTextView else { return }
        let width = contentSize.width
        let height = contentSize.height
        guard width > 0 else { return }
        let horizontal = max(minHorizontalPadding, floor((width - editorMaxWidth) / 2))
        let top: CGFloat
        let bottom: CGFloat
        if let proportion = fixedScroll.proportion, height > 120 {
            top = max(topPadding, floor(height * proportion))
            bottom = max(160, floor(height * (1 - proportion)))
        } else {
            top = topPadding
            bottom = 160
        }
        let targetInset = NSSize(width: max(0, horizontal - EditorSpacing.markerGutter), height: top)
        let insetChanged = abs(textView.textContainerInset.width - targetInset.width) > 0.5
            || abs(textView.textContainerInset.height - targetInset.height) > 0.5
        let overscrollChanged = abs(textView.bottomOverscroll - bottom) > 0.5
        if insetChanged || overscrollChanged {
            textView.bottomOverscroll = bottom
            if insetChanged { textView.textContainerInset = targetInset }
            textView.needsDisplay = true
            DispatchQueue.main.async { [weak textView] in
                textView?.sizeToFit()
            }
        }
    }
}

struct InkTextEditor: NSViewRepresentable {
    var draftID: UUID
    var text: String
    var palette: InkPalette
    var font: EditorFont
    var size: Double
    var maxWidth: Double
    var horizontalPadding: Double
    var topPadding: Double
    var fixedScroll: FixedScroll
    var spacing: EditorSpacing
    var markLine: Bool
    var spelling: Bool
    var editable: Bool
    var bridge: EditorBridge
    var onChange: (String) -> Void
    var onAttachImage: (Data, String) -> Void
    var onTypingActivity: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InkEditorScrollView {
        let view = InkNativeTextView()
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.drawsBackground = false
        view.setAccessibilityLabel("文稿正文")
        view.delegate = context.coordinator
        view.didFinishComposition = { [weak coordinator = context.coordinator, weak view] in
            guard let view, let coordinator, !view.hasMarkedText(), view.string != coordinator.owner.text else { return }
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        }
        view.onAttachImage = { [weak coordinator = context.coordinator] data, name in
            coordinator?.owner.onAttachImage(data, name)
        }
        let scroll = InkEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.editorMaxWidth = maxWidth
        scroll.minHorizontalPadding = horizontalPadding
        scroll.topPadding = topPadding
        scroll.fixedScroll = fixedScroll
        view.frame = CGRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: InkEditorScrollView, context: Context) {
        guard let view = scroll.documentView as? InkNativeTextView else { return }
        let coordinator = context.coordinator
        let repaginate = coordinator.owner.font != font || coordinator.owner.size != size
            || coordinator.owner.palette != palette || coordinator.owner.spacing != spacing
        coordinator.owner = self
        scroll.editorMaxWidth = maxWidth
        scroll.minHorizontalPadding = horizontalPadding
        scroll.topPadding = topPadding
        scroll.fixedScroll = fixedScroll
        scroll.updateTextInsets()
        view.isEditable = editable
        view.ruleColor = palette.leafNS.withAlphaComponent(0.32)
        view.codeBlockColor = palette.codeBgNS
        view.currentLineColor = markLine ? palette.leafNS.withAlphaComponent(palette.dark ? 0.09 : 0.055) : nil
        if view.isContinuousSpellCheckingEnabled != spelling { view.isContinuousSpellCheckingEnabled = spelling }
        if !view.hasMarkedText(), view.string != text || !coordinator.initialized {
            let previous = view.selectedRange()
            view.string = text
            view.undoManager?.removeAllActions()
            view.setSelectedRange(NSRange(location: min(previous.location, text.utf16.count), length: 0))
            coordinator.highlight(view)
            coordinator.initialized = true
        } else if repaginate && !view.hasMarkedText() {
            coordinator.highlight(view)
        }
        if bridge.view !== view { bridge.attach(view, id: draftID) }
    }

    static func dismantleNSView(_ scroll: InkEditorScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        coordinator.owner.bridge.remember(editor, id: coordinator.owner.draftID)
        coordinator.pendingHighlight?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: InkTextEditor
        var initialized = false
        var pendingHighlight: Task<Void, Never>?
        private let undo = UndoManager()
        private static let listLead = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+] |(\d+)\. )(\[[ xX]\] )?"#)
        private static let quoteLead = try! NSRegularExpression(pattern: #"^([ \t]*>[ \t]?)"#)

        init(_ owner: InkTextEditor) { self.owner = owner }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        private static func containsCJK(_ string: String) -> Bool {
            string.unicodeScalars.contains { scalar in
                (0x2E80...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
            }
        }

        func highlight(_ editor: NSTextView, plan: EditorMarkdown? = nil, scope: NSRange? = nil) {
            guard let storage = editor.textStorage else { return }
            let range = scope ?? NSRange(location: 0, length: storage.length)
            let markup = plan ?? EditorMarkdown(editor.string)
            let style = owner.spacing.paragraphStyle()
            let font = owner.font.font(size: owner.size)
            let base: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: style, .foregroundColor: owner.palette.inkNS
            ]
            let monospace = NSFont.monospacedSystemFont(ofSize: max(11, owner.size - 1.5), weight: .regular)
            let muted = owner.palette.mutedNS
            let leaf = owner.palette.leafNS
            let accent = owner.palette.accentNS

            editor.font = font
            editor.defaultParagraphStyle = style
            editor.insertionPointColor = leaf
            editor.selectedTextAttributes = [.backgroundColor: leaf.withAlphaComponent(0.22)]
            storage.beginEditing()
            storage.setAttributes(base, range: range)

            let fullNS = editor.string as NSString
            let gutter = EditorSpacing.markerGutter
            for block in markup.blocks {
                guard let paragraph = style.mutableCopy() as? NSMutableParagraphStyle else { continue }
                var attributes: [NSAttributedString.Key: Any] = [:]
                var headingPrefix: NSRange?
                switch block.kind {
                case .heading(let level, let prefix):
                    let scale = [1.58, 1.36, 1.21, 1.12, 1.07, 1.03][level - 1]
                    let headingFont = owner.font.font(size: (owner.size * scale).rounded(), weight: .semibold)
                    attributes[.font] = headingFont
                    if owner.font.needsFakeBold(headingFont) { attributes[.strokeWidth] = -1.6 }
                    attributes[.foregroundColor] = leaf
                    headingPrefix = prefix
                    EditorSpacing.placePrefix(fullNS.substring(with: prefix), font: font, before: gutter, in: paragraph)
                case .quote(let prefix):
                    attributes[.foregroundColor] = muted
                    attributes[.paragraphRule] = 1
                    EditorSpacing.placePrefix(fullNS.substring(with: prefix), font: font, before: gutter + 18, in: paragraph)
                case .list(let prefix):
                    EditorSpacing.placeListPrefix(fullNS.substring(with: prefix), font: font, in: paragraph)
                case .code:
                    attributes[.font] = monospace
                    attributes[.foregroundColor] = leaf
                    attributes[.fencedMarkup] = true
                    attributes[.codeBlockFill] = true
                    paragraph.headIndent = gutter + 14
                    paragraph.firstLineHeadIndent = paragraph.headIndent
                    paragraph.lineSpacing = max(3, owner.spacing.line - 2)
                case .codeFence:
                    attributes[.font] = monospace
                    attributes[.foregroundColor] = muted.withAlphaComponent(0.65)
                    attributes[.fencedMarkup] = true
                    attributes[.codeBlockFill] = true
                    paragraph.headIndent = gutter + 14
                    paragraph.firstLineHeadIndent = paragraph.headIndent
                    paragraph.lineSpacing = max(3, owner.spacing.line - 2)
                case .equation:
                    attributes[.font] = monospace
                    attributes[.foregroundColor] = accent
                    attributes[.fencedMarkup] = true
                    attributes[.codeBlockFill] = true
                    paragraph.headIndent = gutter + 14
                    paragraph.firstLineHeadIndent = paragraph.headIndent
                case .comment:
                    attributes[.foregroundColor] = muted.withAlphaComponent(0.72)
                    attributes[.fencedMarkup] = true
                case .divider:
                    paragraph.paragraphSpacingBefore = 8
                    paragraph.paragraphSpacing += 8
                case .table:
                    attributes[.font] = monospace
                    paragraph.firstLineHeadIndent = gutter
                    paragraph.lineSpacing = max(3, owner.spacing.line - 1)
                }
                attributes[.paragraphStyle] = paragraph
                storage.addAttributes(attributes, range: block.range)
                if let headingPrefix {
                    storage.addAttribute(.font, value: font, range: headingPrefix)
                    storage.removeAttribute(.strokeWidth, range: headingPrefix)
                }
            }

            for run in markup.runs {
                var attributes: [NSAttributedString.Key: Any] = [:]
                if run.equation {
                    attributes[.font] = monospace
                    attributes[.foregroundColor] = accent
                }
                if run.image {
                    attributes[.foregroundColor] = leaf
                    attributes[.backgroundColor] = leaf.withAlphaComponent(0.11)
                }
                if run.intent.contains(.code) {
                    attributes[.font] = monospace
                    attributes[.foregroundColor] = leaf
                    attributes[.backgroundColor] = leaf.withAlphaComponent(0.09)
                } else {
                    var traits: NSFontTraitMask = []
                    if run.intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                    if run.intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                    if !traits.isEmpty {
                        let baseFont = storage.attribute(.font, at: run.range.location, effectiveRange: nil) as? NSFont ?? font
                        let converted = owner.font.styled(baseFont, traits: traits)
                        attributes[.font] = converted
                        if traits.contains(.boldFontMask), owner.font.needsFakeBold(converted) {
                            attributes[.strokeWidth] = -1.6
                        }
                        if run.intent.contains(.emphasized) {
                            let snippet = NSMaxRange(run.range) <= fullNS.length ? fullNS.substring(with: run.range) : ""
                            let hasItalicTrait = NSFontManager.shared.traits(of: converted).contains(.italicFontMask)
                            if !hasItalicTrait || Self.containsCJK(snippet) {
                                attributes[.obliqueness] = 0.16
                            }
                        }
                    }
                }
                if run.intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = muted
                }
                if run.link {
                    attributes[.foregroundColor] = leaf
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    if let url = run.linkURL { attributes[.markdownLink] = url }
                }
                if run.highlight { attributes[.backgroundColor] = accent.withAlphaComponent(0.18) }
                storage.addAttributes(attributes, range: run.range)
            }

            for marker in markup.markers {
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: accent
                ]
                if let box = marker.taskBoxRange {
                    attributes[.taskToggleRange] = NSValue(range: box)
                }
                storage.addAttributes(attributes, range: marker.range)
            }
            storage.endEditing()
            editor.typingAttributes = base
            editor.setNeedsDisplay(editor.visibleRect)
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            let value = editor.string
            owner.onTypingActivity()
            owner.onChange(value)
            pendingHighlight?.cancel()
            if value.utf16.count <= 8_000 {
                highlight(editor)
                adjustFixedScroll(editor)
            } else {
                highlightEditedLine(editor, source: value)
                adjustFixedScroll(editor)
                pendingHighlight = Task { [weak self, weak editor] in
                    do { try await Task.sleep(for: .milliseconds(85)) } catch { return }
                    let worker = Task.detached(priority: .userInitiated) { EditorMarkdown(value) }
                    let plan = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard !Task.isCancelled, let self, let editor, editor.string == value, !editor.hasMarkedText() else { return }
                    self.highlight(editor, plan: plan)
                }
            }
        }

        private func highlightEditedLine(_ editor: NSTextView, source: String) {
            guard let storage = editor.textStorage, storage.length > 0 else { return }
            let position = min(editor.selectedRange().location, storage.length)
            let raw = source as NSString
            let range = raw.lineRange(for: NSRange(location: position, length: 0))
            guard (1...5_000).contains(range.length), NSMaxRange(range) <= storage.length,
                  storage.attribute(.fencedMarkup, at: range.location, effectiveRange: nil) == nil else { return }
            let local = EditorMarkdown(raw.substring(with: range), offset: range.location)
            highlight(editor, plan: local, scope: range)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if owner.markLine { editor.setNeedsDisplay(editor.visibleRect) }
            if owner.fixedScroll != .off { adjustFixedScroll(editor) }
            let selected = editor.selectedRange()
            let location = selected.location
            let count: Int
            if selected.length > 0 && selected.length <= 50_000 {
                let snippet = (editor.string as NSString).substring(with: selected)
                count = WritingCount(snippet).words
            } else {
                count = 0
            }
            let bridge = owner.bridge
            if bridge.caretLocation != location || bridge.selectionWords != count {
                DispatchQueue.main.async {
                    if bridge.caretLocation != location { bridge.caretLocation = location }
                    if bridge.selectionWords != count { bridge.selectionWords = count }
                }
            }
        }

        private func adjustFixedScroll(_ editor: NSTextView) {
            guard let proportion = owner.fixedScroll.proportion,
                  let editor = editor as? InkNativeTextView, let scroll = editor.enclosingScrollView,
                  let line = editor.insertionLine() else { return }
            let maxY = max(0, editor.frame.height - scroll.contentSize.height)
            let y = min(maxY, max(0, line.midY - scroll.contentSize.height * proportion))
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }

            if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
                return handleListIndent(textView, outdent: selector == #selector(NSResponder.insertBacktab(_:)))
            }

            guard selector == #selector(NSResponder.insertNewline(_:)), textView.selectedRange().length == 0 else { return false }
            let source = textView.string as NSString
            let position = textView.selectedRange().location
            let current = source.lineRange(for: NSRange(location: position, length: 0))
            let prefix = source.substring(with: NSRange(location: current.location, length: position - current.location))
            let text = prefix as NSString

            if let match = Self.listLead.firstMatch(in: prefix, range: NSRange(location: 0, length: text.length)) {
                let indent = text.substring(with: match.range(at: 1))
                if match.range.length == text.length {
                    if indent.count >= 2 {
                        textView.insertText("", replacementRange: NSRange(location: current.location, length: 2))
                    } else if indent.hasPrefix("\t") {
                        textView.insertText("", replacementRange: NSRange(location: current.location, length: 1))
                    } else {
                        textView.insertText("", replacementRange: NSRange(location: current.location, length: text.length))
                    }
                    return true
                }
                let digits = match.range(at: 3)
                let marker: String
                if digits.location != NSNotFound, let value = Int(text.substring(with: digits)), value < Int.max {
                    marker = "\(value + 1). "
                } else {
                    marker = text.substring(with: match.range(at: 2))
                }
                let task = match.range(at: 4).location == NSNotFound ? "" : "[ ] "
                textView.insertText("\n" + indent + marker + task, replacementRange: textView.selectedRange())
                return true
            }

            if let match = Self.quoteLead.firstMatch(in: prefix, range: NSRange(location: 0, length: text.length)) {
                if match.range.length == text.length {
                    textView.insertText("", replacementRange: NSRange(location: current.location, length: text.length))
                } else {
                    textView.insertText("\n" + text.substring(with: match.range(at: 1)), replacementRange: textView.selectedRange())
                }
                return true
            }
            return false
        }

        private func handleListIndent(_ textView: NSTextView, outdent: Bool) -> Bool {
            let source = textView.string as NSString
            let selected = textView.selectedRange()
            let lineRange = source.lineRange(for: selected)
            let block = source.substring(with: lineRange)
            let hasTrailingNewline = block.hasSuffix("\n")
            let rawLines = block.components(separatedBy: "\n")
            let lines = hasTrailingNewline ? Array(rawLines.dropLast()) : rawLines
            let isListContext = lines.contains { line in
                let ns = line as NSString
                return Self.listLead.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
            }
            guard isListContext else { return false }
            let updated = lines.map { line -> String in
                if outdent {
                    if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
                    if line.hasPrefix("\t") || line.hasPrefix(" ") { return String(line.dropFirst()) }
                    return line
                } else {
                    return "  " + line
                }
            }
            let replacement = updated.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
            textView.insertText(replacement, replacementRange: lineRange)
            if selected.length == 0 {
                let delta = replacement.utf16.count - block.utf16.count
                let pos = max(lineRange.location, min(textView.string.utf16.count, selected.location + delta))
                textView.setSelectedRange(NSRange(location: pos, length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: lineRange.location, length: max(0, replacement.utf16.count - (hasTrailingNewline ? 1 : 0))))
            }
            return true
        }
    }
}

final class InkNativeTextView: NSTextView {
    var didFinishComposition: (() -> Void)?
    var onAttachImage: ((Data, String) -> Void)?
    var ruleColor = NSColor.separatorColor
    var codeBlockColor = NSColor.quaternaryLabelColor
    var bottomOverscroll: CGFloat = 160
    private var adjustingFrame = false
    var currentLineColor: NSColor? {
        didSet { if oldValue != currentLineColor { setNeedsDisplay(visibleRect) } }
    }

    private static let wrapPairs: [String: String] = [
        "*": "*", "_": "_", "`": "`", "~": "~",
        "(": ")", "[": "]", "\"": "\"",
        "“": "”", "「": "」", "（": "）"
    ]

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL])
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard !adjustingFrame, let manager = layoutManager, let container = textContainer else {
            super.setFrameSize(newSize)
            return
        }
        adjustingFrame = true
        defer { adjustingFrame = false }
        let used = manager.usedRect(for: container)
        let minimumHeight = used.height + textContainerInset.height + bottomOverscroll
        let scrollHeight = enclosingScrollView?.contentSize.height ?? 0
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, minimumHeight, scrollHeight)))
    }

    override func unmarkText() {
        let composing = hasMarkedText()
        super.unmarkText()
        if composing { DispatchQueue.main.async { [weak self] in self?.didFinishComposition?() } }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if !hasMarkedText(),
           let raw = (insertString as? String) ?? (insertString as? NSAttributedString)?.string,
           let closing = Self.wrapPairs[raw],
           replacementRange.location == NSNotFound,
           selectedRange().length > 0 {
            let current = selectedRange()
            let selectedText = (string as NSString).substring(with: current)
            super.insertText(raw + selectedText + closing, replacementRange: current)
            setSelectedRange(NSRange(location: current.location + raw.utf16.count, length: current.length))
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { super.paste(sender); return }
        let board = NSPasteboard.general
        let current = selectedRange()
        if current.length > 0,
           let raw = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.contains("\n"),
           (raw.hasPrefix("https://") || raw.hasPrefix("http://")),
           URL(string: raw) != nil {
            let selected = (string as NSString).substring(with: current)
            if !selected.contains("\n") {
                insertText("[\(selected)](\(raw))", replacementRange: current)
                return
            }
        }
        if board.string(forType: .string) == nil {
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               let first = urls.first, handleDroppedImage(url: first) {
                return
            }
            if let image = NSImage(pasteboard: board),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: " ", with: "_")
                onAttachImage?(png, "剪贴板图片-\(stamp).png")
                return
            }
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isEditable, hasImageFile(in: sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isEditable,
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            var handled = false
            for url in urls where handleDroppedImage(url: url) { handled = true }
            if handled { return true }
        }
        return super.performDragOperation(sender)
    }

    private func hasImageFile(in board: NSPasteboard) -> Bool {
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        return urls.contains { isSupportedImageURL($0) }
    }

    private func isSupportedImageURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mime = type.preferredMIMEType else { return false }
        return ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
    }

    private func handleDroppedImage(url: URL) -> Bool {
        guard isSupportedImageURL(url), let data = try? Data(contentsOf: url) else { return false }
        onAttachImage?(data, url.lastPathComponent)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 {
            let point = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
            var fraction: CGFloat = 0
            let glyphIndex = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            if glyphIndex < manager.numberOfGlyphs {
                let charIndex = manager.characterIndexForGlyph(at: glyphIndex)
                if charIndex < storage.length {
                    if isEditable,
                       let taskValue = storage.attribute(.taskToggleRange, at: charIndex, effectiveRange: nil) as? NSValue {
                        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
                        if glyphRect.insetBy(dx: -8, dy: -4).contains(point) {
                            let boxRange = taskValue.rangeValue
                            if NSMaxRange(boxRange) <= (string as NSString).length {
                                let current = (string as NSString).substring(with: boxRange)
                                let next = current.lowercased() == "[x]" ? "[ ]" : "[x]"
                                insertText(next, replacementRange: boxRange)
                                return
                            }
                        }
                    }
                    if event.modifierFlags.contains(.command),
                       let url = storage.attribute(.markdownLink, at: charIndex, effectiveRange: nil) as? URL,
                       ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                        NSWorkspace.shared.open(url)
                        return
                    }
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caretRect = rect
        if !hasMarkedText(), let storage = textStorage, let manager = layoutManager {
            let location = selectedRange().location
            let activeFont: NSFont?
            if location < storage.length {
                activeFont = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            } else {
                activeFont = typingAttributes[.font] as? NSFont
            }
            if let activeFont {
                caretRect.size.height = min(rect.height, ceil(manager.defaultLineHeight(for: activeFont)))
            }
        }
        super.drawInsertionPoint(in: caretRect, color: color, turnedOn: flag)
    }

    func insertionLine() -> CGRect? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let caret = selectedRange().location
        let origin = textContainerOrigin
        let length = (string as NSString).length
        if caret == length {
            manager.ensureLayout(for: container)
            if manager.extraLineFragmentTextContainer == container {
                return manager.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            }
            if length == 0 {
                let activeFont = (typingAttributes[.font] as? NSFont) ?? font ?? NSFont.systemFont(ofSize: 19)
                let h = ceil(activeFont.ascender - activeFont.descender + activeFont.leading)
                return CGRect(x: origin.x, y: origin.y, width: container.size.width, height: h)
            }
        }
        guard manager.numberOfGlyphs > 0 else { return nil }
        let position = min(caret, length - 1)
        let glyph = manager.glyphIndexForCharacter(at: position)
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let origin = textContainerOrigin
        let gutter = EditorSpacing.markerGutter
        let columnX = origin.x + gutter
        if let currentLineColor, let line = insertionLine(), let container = textContainer {
            let caret = selectedRange().location
            let activeFont: NSFont
            if let storage = textStorage, storage.length > 0, caret < storage.length {
                activeFont = (storage.attribute(.font, at: caret, effectiveRange: nil) as? NSFont)
                    ?? (typingAttributes[.font] as? NSFont) ?? font ?? NSFont.systemFont(ofSize: 19)
            } else {
                activeFont = (typingAttributes[.font] as? NSFont) ?? font ?? NSFont.systemFont(ofSize: 19)
            }
            let glyphHeight = ceil(activeFont.ascender - activeFont.descender + activeFont.leading)
            let visualHeight = max(glyphHeight, min(line.height, glyphHeight))
            let vPad: CGFloat = 6
            let columnWidth = min(bounds.width - columnX * 2, container.size.width - gutter * 2)
            let marker = CGRect(
                x: max(12, columnX - 16),
                y: line.minY - vPad,
                width: min(bounds.width - 24, columnWidth + 32),
                height: visualHeight + vPad * 2
            )
            if marker.intersects(rect) {
                currentLineColor.setFill()
                NSBezierPath(roundedRect: marker, xRadius: 6, yRadius: 6).fill()
            }
        }
        guard let container = textContainer, let manager = layoutManager, let storage = textStorage,
              storage.length > 0 else { return }
        let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let columnWidth = max(1, min(bounds.width - columnX * 2, container.size.width - gutter * 2))

        manager.enumerateLineFragments(forGlyphRange: glyphs) { [self] line, _, _, range, _ in
            guard range.length > 0 else { return }
            let index = manager.characterIndexForGlyph(at: range.location)
            guard index < storage.length else { return }
            if storage.attribute(.codeBlockFill, at: index, effectiveRange: nil) as? Bool == true {
                codeBlockColor.setFill()
                let box = CGRect(x: columnX - 8, y: origin.y + line.minY, width: columnWidth + 16, height: line.height)
                NSBezierPath.fill(box)
            }
            let rule = storage.attribute(.paragraphRule, at: index, effectiveRange: nil) as? Int
            if rule == 1 {
                ruleColor.setFill()
                NSBezierPath.fill(CGRect(x: columnX - 8, y: origin.y + line.minY + 1,
                                         width: 2.5, height: max(1, line.height - 2)))
            }
        }
    }
}

struct WebPreview: NSViewRepresentable {
    let html: String
    var liveBody: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.setAccessibilityLabel("排版预览")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.body = liveBody
        if coordinator.shell != html {
            coordinator.shell = html
            coordinator.loaded = false
            coordinator.displayed = nil
            web.loadHTMLString(html, baseURL: nil)
        } else {
            coordinator.refresh(web)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shell: String?
        var body: String?
        var displayed: String?
        var loaded = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            refresh(webView)
        }

        func refresh(_ web: WKWebView) {
            guard loaded, let body, displayed != body else { return }
            displayed = body
            Task { @MainActor [weak self, weak web] in
                guard let self, let web, self.displayed == body else { return }
                do {
                    _ = try await web.callAsyncJavaScript(
                        "const offset = window.scrollY; document.body.innerHTML = fragment; requestAnimationFrame(() => window.scrollTo(0, offset));",
                        arguments: ["fragment": body], in: nil, contentWorld: .defaultClient
                    )
                } catch {
                    guard self.displayed == body, let shell = self.shell else { return }
                    self.loaded = false
                    web.loadHTMLString(shell.replacingOccurrences(of: "<body></body>", with: "<body>" + body + "</body>"),
                                       baseURL: nil)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
