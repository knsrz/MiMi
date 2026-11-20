import AppKit
import CoreText
import CryptoKit

enum EditorFont: RawRepresentable, Hashable, Sendable {
    case serif, system, mono
    case installed(String)
    case imported(String)

    static let presets: [Self] = [.serif, .system, .mono]

    init?(rawValue: String) {
        switch rawValue {
        case "serif": self = .serif
        case "system": self = .system
        case "mono": self = .mono
        case let value where value.hasPrefix("installed:"):
            let name = String(value.dropFirst("installed:".count))
            guard !name.isEmpty else { return nil }
            self = .installed(name)
        case let value where value.hasPrefix("imported:"):
            let filename = String(value.dropFirst("imported:".count))
            guard EditorFontLibrary.isImportedFilename(filename) else { return nil }
            self = .imported(filename)
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .serif: "serif"
        case .system: "system"
        case .mono: "mono"
        case .installed(let name): "installed:" + name
        case .imported(let filename): "imported:" + filename
        }
    }

    var label: String {
        switch self {
        case .serif: "衬线"
        case .system: "系统无衬线"
        case .mono: "等宽"
        case .installed(let name): NSFont(name: name, size: 12)?.displayName ?? name
        case .imported(let filename): EditorFontLibrary.shared.font(filename, size: 12)?.displayName ?? "导入的字体不可用"
        }
    }

    var isPreset: Bool { Self.presets.contains(self) }

    func font(size: CGFloat, weight: NSFont.Weight = .regular, library: EditorFontLibrary = .shared) -> NSFont {
        switch self {
        case .serif:
            let bold = weight.rawValue >= NSFont.Weight.medium.rawValue
            let latin = NSFont(name: bold ? "Georgia-Bold" : "Georgia", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight)
            let cjkName = bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
            if NSFont(name: cjkName, size: size) != nil {
                let cascade = NSFontDescriptor(name: cjkName, size: size)
                let descriptor = latin.fontDescriptor.addingAttributes([.cascadeList: [cascade]])
                if let combined = NSFont(descriptor: descriptor, size: size) { return combined }
            }
            return latin
        case .system:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .installed(let name):
            guard let font = NSFont(name: name, size: size) else { return NSFont.systemFont(ofSize: size, weight: weight) }
            return weight.rawValue >= NSFont.Weight.medium.rawValue ? styled(font, traits: .boldFontMask) : font
        case .imported(let filename):
            return library.font(filename, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        }
    }

    func styled(_ font: NSFont, traits: NSFontTraitMask) -> NSFont {
        if case .imported = self { return font }
        let alternate = NSFontManager.shared.convert(font, toHaveTrait: traits)
        return isPreset || alternate.familyName == font.familyName ? alternate : font
    }

    func needsFakeBold(_ font: NSFont) -> Bool {
        !isPreset && !NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }
}

// The directory is immutable and NSCache coordinates concurrent access.
final class EditorFontLibrary: @unchecked Sendable {
    static let supportedExtensions = ["ttf", "otf"]
    static let shared = EditorFontLibrary(directory: URL.applicationSupportDirectory
        .appending(path: "Inkfolio/Editor Fonts", directoryHint: .isDirectory))

    let directory: URL
    private let cache = NSCache<NSString, CGFont>()

    init(directory: URL) {
        self.directory = directory
        cache.countLimit = 6
    }

    static func isImportedFilename(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 64, supportedExtensions.contains(String(parts[1])) else { return false }
        return parts[0].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func font(_ filename: String, size: CGFloat) -> NSFont? {
        guard Self.isImportedFilename(filename) else { return nil }
        let key = filename as NSString
        if let graphics = cache.object(forKey: key) {
            return CTFontCreateWithGraphicsFont(graphics, size, nil, nil) as NSFont
        }
        let url = directory.appending(path: filename)
        guard let provider = CGDataProvider(url: url as CFURL), let graphics = CGFont(provider) else { return nil }
        cache.setObject(graphics, forKey: key)
        return CTFontCreateWithGraphicsFont(graphics, size, nil, nil) as NSFont
    }

    func importFont(from url: URL) throws -> EditorFont {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw FontImportError.unsupported }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let provider = CGDataProvider(data: data as CFData),
              let graphics = CGFont(provider), graphics.postScriptName != nil else {
            throw FontImportError.unsupported
        }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = hash + "." + ext
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: filename)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        cache.setObject(graphics, forKey: filename as NSString)
        return .imported(filename)
    }

    func importedFonts() -> [EditorFont] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                               options: .skipsHiddenFiles)) ?? []
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard font(name, size: 12) != nil else { return nil }
            return .imported(name)
        }
    }

    private enum FontImportError: LocalizedError {
        case unsupported

        var errorDescription: String? { "无法读取字体文件，请选择有效的 TTF 或 OTF 字体。" }
    }
}
