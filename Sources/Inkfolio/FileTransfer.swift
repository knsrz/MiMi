import AppKit
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, text, html, pdf, docx, epub, rtf, textbundle
    var id: Self { self }

    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .text: "纯文本"
        case .html: "网页"
        case .pdf: "PDF"
        case .docx: "Word"
        case .epub: "电子书"
        case .rtf: "富文本"
        case .textbundle: "TextBundle"
        }
    }

    var ext: String {
        switch self {
        case .markdown: "md"
        case .text: "txt"
        default: rawValue
        }
    }

    var type: UTType { UTType(filenameExtension: ext) ?? .data }
}

enum FileTransfer {
    private static let textExtensions: Set<String> = ["md", "markdown", "mdown", "mmd", "mkdn", "txt", "text"]
    private static let richExtensions: Set<String> = ["rtf", "rtfd", "docx", "html", "htm"]

    static func importFiles(_ urls: [URL], into folder: UUID?) throws -> Library {
        var result = Library()
        var remaining = 1000
        for url in urls { try read(url, folder: folder, depth: 0, remaining: &remaining, result: &result, explicit: true) }
        guard !result.drafts.isEmpty else { throw LibraryError.unsupportedImport("所选文件") }
        return result
    }

    private static func read(_ url: URL, folder: UUID?, depth: Int, remaining: inout Int,
                             result: inout Library, explicit: Bool) throws {
        guard remaining > 0, depth < 20 else { throw LibraryError.unsafeImport }
        remaining -= 1
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey])
        guard values.isSymbolicLink != true else {
            if explicit { throw LibraryError.unsupportedImport(url.lastPathComponent) }
            return
        }
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        if ext == "textbundle", values.isDirectory == true {
            var draft = Draft(folderID: folder, title: title, text: try decodeText(url.appending(path: "text.md")))
            let assets = url.appending(path: "assets", directoryHint: .isDirectory)
            if let files = try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) {
                for file in files {
                    let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { continue }
                    guard remaining > 0 else { throw LibraryError.unsafeImport }
                    remaining -= 1
                    let item = try attachment(file)
                    draft.text = draft.text.replacingOccurrences(of: "(assets/" + item.name + ")", with: "(" + item.reference + ")")
                        .replacingOccurrences(of: "(assets/" + encodedPath(item.name) + ")", with: "(" + item.reference + ")")
                    draft.attachments.append(item)
                }
            }
            result.drafts.append(draft)
        } else if values.isDirectory == true, values.isPackage != true, !richExtensions.contains(ext) {
            let group = Folder(name: url.lastPathComponent, parentID: folder)
            result.folders.append(group)
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                try read(child, folder: group.id, depth: depth + 1, remaining: &remaining, result: &result, explicit: false)
            }
        } else if textExtensions.contains(ext) {
            result.drafts.append(Draft(folderID: folder, title: title, text: try decodeText(url)))
        } else if richExtensions.contains(ext) {
            let temporary = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = temporary.appending(path: "import.txt")
            try run("/usr/bin/textutil", ["-convert", "txt", "-noload", "-nostore", "-output", output.path, url.path])
            result.drafts.append(Draft(folderID: folder, title: title, text: try decodeText(output)))
        } else if explicit {
            throw LibraryError.unsupportedImport(url.lastPathComponent)
        }
    }

    private static func decodeText(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 25_000_000 else { throw LibraryError.unsupportedImport(url.lastPathComponent) }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let text = String(data: data, encoding: .utf16) { return text }
        throw LibraryError.unsupportedImport(url.lastPathComponent)
    }

    static func attachment(_ url: URL) throws -> Attachment {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw LibraryError.unsupportedImport(url.lastPathComponent) }
        guard (values.fileSize ?? 0) <= 25_000_000 else { throw LibraryError.largeAttachment }
        return Attachment(name: url.lastPathComponent, data: try Data(contentsOf: url))
    }

    static func export(_ items: [Draft], as format: ExportFormat, to url: URL) throws {
        guard !items.isEmpty else { throw LibraryError.invalidExport }
        switch format {
        case .markdown:
            try markdown(items).write(to: url, atomically: true, encoding: .utf8)
        case .text:
            try plain(items).write(to: url, atomically: true, encoding: .utf8)
        case .html:
            try Manuscript.html(items).write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            let temporary = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = temporary.appending(path: "pages.pdf")
            try writePDF(Manuscript.attributed(items), to: output)
            try Data(contentsOf: output).write(to: url, options: [.atomic])
        case .rtf, .docx:
            let document = Manuscript.attributed(items)
            let range = NSRange(location: 0, length: document.length)
            if format == .rtf {
                let data = try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: url, options: [.atomic])
            } else {
                let temporary = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: temporary) }
                let wrapper = try document.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                let input = temporary.appending(path: "Manuscript.rtfd")
                let output = temporary.appending(path: "Manuscript.docx")
                try wrapper.write(to: input, options: .atomic, originalContentsURL: nil)
                try run("/usr/bin/textutil", ["-convert", "docx", "-output", output.path, input.path])
                try Data(contentsOf: output).write(to: url, options: [.atomic])
            }
        case .epub:
            try writeEPUB(items, to: url)
        case .textbundle:
            try writeTextBundle(items, to: url)
        }
    }

    static func markdown(_ items: [Draft]) -> String {
        items.map { draft in
            let body = draft.attachments.reduce(draft.text) { text, item in
                text.replacingOccurrences(of: "(" + item.reference + ")", with: "(" + encodedPath(item.name) + ")")
            }
            return withTitle(draft, body: body, prefix: "# ")
        }.joined(separator: "\n\n")
    }

    static func plain(_ items: [Draft]) -> String {
        items.map { withTitle($0, body: Manuscript.plainText($0.text), prefix: "") }.joined(separator: "\n\n")
    }

    private static func withTitle(_ draft: Draft, body: String, prefix: String) -> String {
        guard let title = Manuscript.standaloneTitle(draft) else { return body }
        return prefix + title + "\n\n" + body
    }

    private static func encodedPath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    private static func safeFilename(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "_")
        return String(cleaned.drop(while: { $0 == "." }).prefix(130))
    }

    private static func writeTextBundle(_ drafts: [Draft], to url: URL) throws {
        var files: [String: FileWrapper] = [:]
        var names = Set<String>()
        var paths: [String: String] = [:]
        for item in drafts.flatMap(\.attachments) where paths[item.reference] == nil {
            let original = safeFilename(item.name)
            let candidate = original.isEmpty ? "attachment" : original
            let name = names.insert(candidate.lowercased()).inserted ? candidate : "\(item.id.uuidString)-\(candidate)"
            names.insert(name.lowercased())
            files[name] = FileWrapper(regularFileWithContents: item.data)
            paths[item.reference] = "assets/" + encodedPath(name)
        }
        let source = drafts.map { draft in
            let body = paths.reduce(draft.text) { $0.replacingOccurrences(of: "(" + $1.key + ")", with: "(" + $1.value + ")") }
            return withTitle(draft, body: body, prefix: "# ")
        }.joined(separator: "\n\n")
        let metadata = Data(#"{"version":2,"type":"net.daringfireball.markdown","creatorIdentifier":"local.inkfolio.mac"}"#.utf8)
        let bundle = FileWrapper(directoryWithFileWrappers: [
            "text.md": FileWrapper(regularFileWithContents: Data(source.utf8)),
            "info.json": FileWrapper(regularFileWithContents: metadata),
            "assets": FileWrapper(directoryWithFileWrappers: files)
        ])
        try bundle.write(to: url, options: .atomic, originalContentsURL: nil)
    }

    private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else { throw LibraryError.invalidExport }
        let layout = NSLayoutManager()
        let storage = NSTextStorage(attributedString: text)
        storage.addLayoutManager(layout)
        let margin: CGFloat = 58
        let usable = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)
        var covered = 0
        let total = layout.numberOfGlyphs
        while covered < total {
            let container = NSTextContainer(size: usable)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            guard range.length > 0 else {
                context.closePDF()
                throw LibraryError.invalidExport
            }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: margin, y: page.height - margin)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: .zero)
            layout.drawGlyphs(forGlyphRange: range, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            covered = NSMaxRange(range)
        }
        context.closePDF()
        guard covered > 0 else { throw LibraryError.invalidExport }
    }

    private static func writeEPUB(_ items: [Draft], to url: URL) throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let files = temp.appending(path: "contents", directoryHint: .isDirectory)
        let meta = files.appending(path: "META-INF", directoryHint: .isDirectory)
        let book = files.appending(path: "EPUB", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        func write(_ text: String, in folder: URL, name: String) throws {
            try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        try write("application/epub+zip", in: files, name: "mimetype")
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
        <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """, in: meta, name: "container.xml")
        let title = Manuscript.escaped(items[0].name)
        var entries = ""
        var manifest = """
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="style" href="book.css" media-type="text/css"/>
        """
        var spine = ""
        var images: [String: String] = [:]
        for item in items.flatMap(\.attachments) where images[item.reference] == nil {
            guard let mime = Manuscript.imageMIME(item), let ext = UTType(mimeType: mime)?.preferredFilenameExtension else { continue }
            let id = "image-" + item.id.uuidString
            let name = id + "." + ext
            try item.data.write(to: book.appending(path: name))
            manifest += "<item id=\"\(id)\" href=\"\(name)\" media-type=\"\(mime)\"/>"
            images[item.reference] = name
        }
        func xhtml(title: String, body: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh">
            <head><title>\(title)</title><link rel="stylesheet" type="text/css" href="book.css" /></head>
            <body>\(body)</body></html>
            """
        }
        for (index, draft) in items.enumerated() {
            let id = "chapter-\(index + 1)"
            let name = id + ".xhtml"
            let label = Manuscript.escaped(draft.name)
            entries += "<li><a href=\"\(name)\">\(label)</a></li>"
            let body = Manuscript.htmlBody(draft, assets: images)
            let property = body.contains("<math ") ? " properties=\"mathml\"" : ""
            manifest += "<item id=\"\(id)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"\(property)/>"
            spine += "<itemref idref=\"\(id)\"/>"
            try write(xhtml(title: label, body: body), in: book, name: name)
        }
        try write(xhtml(title: "目录", body: "<nav epub:type=\"toc\" id=\"toc\"><h1>目录</h1><ol>\(entries)</ol></nav>"), in: book, name: "nav.xhtml")
        try write(Manuscript.stylesheet, in: book, name: "book.css")
        let date = ISO8601DateFormatter().string(from: Date())
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString)</dc:identifier>
        <dc:title>\(title)</dc:title><dc:language>zh</dc:language><meta property="dcterms:modified">\(date)</meta>
        </metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """, in: book, name: "package.opf")
        let archive = temp.appending(path: "book.epub")
        try run("/usr/bin/zip", ["-q", "-X", "-0", archive.path, "mimetype"], directory: files)
        try run("/usr/bin/zip", ["-q", "-X", "-r", archive.path, "META-INF", "EPUB"], directory: files)
        try Data(contentsOf: archive).write(to: url, options: [.atomic])
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Inkfolio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationReason == .exit, task.terminationStatus == 0 else { throw LibraryError.invalidExport }
    }
}
