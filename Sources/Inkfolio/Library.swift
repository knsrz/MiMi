import Foundation

enum DraftStage: String, Codable, CaseIterable {
    case draft, revision, ready
    var label: String {
        switch self {
        case .draft: "草稿"
        case .revision: "修订中"
        case .ready: "已完成"
        }
    }

    var symbol: String {
        switch self {
        case .draft: "circle.dotted"
        case .revision: "circle.lefthalf.filled"
        case .ready: "checkmark.circle.fill"
        }
    }
}

struct Revision: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var text: String
}

struct Attachment: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var data: Data

    var reference: String { "attachment:" + id.uuidString }
}

struct Draft: Codable, Equatable, Identifiable {
    var id = UUID()
    var folderID: UUID?
    var title = ""
    var text = ""
    var stage = DraftStage.draft
    var note = ""
    var tags: [String] = []
    var attachments: [Attachment] = []
    var revisions: [Revision] = []
    var favorite = false
    var material = false
    var goal = 0
    var created = Date()
    var modified = Date()
    var deleted: Date?

    var customTitle: String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var isBlank: Bool {
        customTitle == nil && text.allSatisfy(\.isWhitespace)
    }

    var hasExplicitHeading: Bool {
        if customTitle != nil { return true }
        var foundHeading = false
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return }
            foundHeading = trimmed.hasPrefix("#")
            stop = true
        }
        return foundHeading
    }

    var flowingPreview: String {
        displayExcerpt(limit: 260, skipping: nil, includeHeadings: true, separator: "\n")
    }

    var name: String {
        if let customTitle { return customTitle }
        return displayLine(excludingHeadings: false, limit: 65) ?? "未命名文稿"
    }

    var excerpt: String {
        displayExcerpt(limit: 240, skipping: customTitle == nil ? name : nil, includeHeadings: false, separator: " ")
    }

    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\([^\s)]+\)"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\([^\s)]+\)"#)
    private static let inlineMarkupRegex = try! NSRegularExpression(pattern: #"(\*\*|__|~~|==|`|\*|_)"#)
    private static let listPrefixRegex = try! NSRegularExpression(pattern: #"^(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)+"#)

    private static func cleanLine(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        let headingTrimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        value = value.hasPrefix("#") ? headingTrimmed : value
        value = listPrefixRegex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        value = imageRegex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        value = linkRegex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "$1")
        value = inlineMarkupRegex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayLine(excludingHeadings: Bool, limit: Int, skipping previewTitle: String? = nil) -> String? {
        var output: String?
        var inCode = false
        var inEquation = false
        var inComment = false
        text.enumerateLines { line, stop in
            let value = line.trimmingCharacters(in: .whitespaces)
            if inComment || value.hasPrefix("<!--") { inComment = !value.contains("-->"); return }
            if value.hasPrefix("```") || value.hasPrefix("~~~") { inCode.toggle(); return }
            if !inCode && (value == "$$" || value == #"\["# || value == #"\]"#) { inEquation.toggle(); return }
            if inCode || inEquation || value.hasPrefix("%%") || value.hasPrefix("// ")
                || (excludingHeadings && value.hasPrefix("#")) { return }
            if let first = value.first, "-*_".contains(first),
               value.filter({ !$0.isWhitespace }).count >= 3,
               value.allSatisfy({ $0 == first || $0.isWhitespace }) { return }
            let visible = Self.cleanLine(value)
            guard !visible.isEmpty, visible != previewTitle else { return }
            output = String(visible.prefix(limit))
            stop = true
        }
        return output
    }

    private func displayExcerpt(limit: Int, skipping previewTitle: String?, includeHeadings: Bool = false, separator: String = " ") -> String {
        var parts: [String] = []
        var total = 0
        var inCode = false
        var inEquation = false
        var inComment = false
        var skippedTitle = previewTitle == nil
        text.enumerateLines { line, stop in
            let value = line.trimmingCharacters(in: .whitespaces)
            if inComment || value.hasPrefix("<!--") { inComment = !value.contains("-->"); return }
            if value.hasPrefix("```") || value.hasPrefix("~~~") { inCode.toggle(); return }
            if !inCode && (value == "$$" || value == #"\["# || value == #"\]"#) { inEquation.toggle(); return }
            if inCode || inEquation || value.isEmpty || value.hasPrefix("%%") || value.hasPrefix("// ") { return }
            if let first = value.first, "-*_".contains(first),
               value.filter({ !$0.isWhitespace }).count >= 3,
               value.allSatisfy({ $0 == first || $0.isWhitespace }) { return }
            if !includeHeadings && value.hasPrefix("#") {
                if !skippedTitle, Self.cleanLine(value) == previewTitle { skippedTitle = true }
                return
            }
            let visible = Self.cleanLine(value)
            guard !visible.isEmpty else { return }
            if !skippedTitle && visible == previewTitle { skippedTitle = true; return }
            parts.append(visible)
            total += visible.count + 1
            if total >= limit { stop = true }
        }
        let joined = parts.joined(separator: separator)
        return joined.count > limit ? String(joined.prefix(limit)) : joined
    }
}

struct Folder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var parentID: UUID?
    var project = false
    var goal = 0
    var icon: String? = nil
}

struct SmartFilter: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
    var tag: String
    var stage: DraftStage?
    var folderID: UUID?
}

enum Shelf: Hashable {
    case all, inbox, favorites, recent, trash, folder(UUID), filter(UUID)

    init?(savedValue: String) {
        let components = savedValue.split(separator: "/", maxSplits: 1)
        if components.count == 2, let id = UUID(uuidString: String(components[1])) {
            if components[0] == "folder" { self = .folder(id); return }
            if components[0] == "filter" { self = .filter(id); return }
            return nil
        }
        switch savedValue {
        case "all": self = .all
        case "inbox": self = .inbox
        case "favorites": self = .favorites
        case "recent": self = .recent
        case "trash": self = .trash
        default: return nil
        }
    }

    var savedValue: String {
        switch self {
        case .all: "all"
        case .inbox: "inbox"
        case .favorites: "favorites"
        case .recent: "recent"
        case .trash: "trash"
        case .folder(let id): "folder/" + id.uuidString
        case .filter(let id): "filter/" + id.uuidString
        }
    }

    func exists(in library: Library) -> Bool {
        switch self {
        case .folder(let id): library.folders.contains { $0.id == id }
        case .filter(let id): library.filters.contains { $0.id == id }
        default: true
        }
    }
}

enum DraftSort: String, Codable, CaseIterable {
    case manual, modified, created, title
    var label: String {
        switch self {
        case .manual: "手动排序"
        case .modified: "最近编辑"
        case .created: "创建时间"
        case .title: "文稿标题"
        }
    }
}

struct Library: Codable, Equatable {
    var version = 1
    var drafts: [Draft] = []
    var folders: [Folder] = []
    var filters: [SmartFilter] = []

    static var example: Library {
        let project = Folder(name: "海岸手记", project: true, goal: 2500)
        let research = Folder(name: "观察与资料", parentID: project.id)
        let personal = Folder(name: "日常随笔")
        let first = Draft(
            folderID: project.id, title: "潮水退去之前",
            text: """
            ## 一封写给潮线的信

            清晨六点，渔港还没有完全醒来。岸边的石阶被夜里的潮水洗过，留下一道深色的水痕。我带着笔记本走到防波堤尽头，想在海风变强之前记下几件小事。

            石缝里的螃蟹先于我发现了日出。它停了一会儿，把两只钳子举到光里，然后侧着身子钻回阴影。一只海鸟沿着水线低飞。远处发动机的声音来得很慢，像有人隔着很厚的墙在说话。

            > 如果把每天的潮线画在同一张纸上，海岸会是什么样子？

            ## 归途

            我把这个问题写在最后一页。等再次抬头，海水已经退到另一块礁石之后。卖早餐的人刚拉开卷帘门，街上有了第一阵热气。
            """,
            note: "第二节可以补一段回到街上的声音。", tags: ["海岸", "随笔"], favorite: true, goal: 700
        )
        return Library(drafts: [
            first,
            Draft(folderID: project.id, title: "沿着旧堤走", text: "沿着旧堤走，石板的排列在转弯处变了。\n\n## 取景\n\n从堤岸背面看渔港。", stage: .revision, tags: ["海岸"]),
            Draft(folderID: project.id, title: "写在灯塔下", text: "入夜以后，灯塔把海面分成一小片光和一整片黑。", tags: ["海岸"]),
            Draft(folderID: research.id, title: "港口观察清单", text: "- 潮汐时间\n- 旧堤的修缮记录\n- 清晨的街道", material: true),
            Draft(folderID: personal.id, title: "给下周的自己", text: "把日程空出一小块，留给一次没有路线的散步。", stage: .ready),
            Draft(title: "待整理的灵感", text: "试着写一段只用声音描述地点的文字。")
        ], folders: [project, research, personal])
    }

    func folder(_ id: UUID?) -> Folder? {
        folders.first { $0.id == id }
    }

    func descendants(of id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var queue = [id]
        while let current = queue.popLast() {
            for child in folders where child.parentID == current {
                if found.insert(child.id).inserted { queue.append(child.id) }
            }
        }
        return found
    }

    func path(to id: UUID?) -> [Folder] {
        var result: [Folder] = []
        var visited = Set<UUID>()
        var next = id
        while let folder = folder(next), visited.insert(folder.id).inserted {
            result.append(folder)
            next = folder.parentID
        }
        return result.reversed()
    }

    var allTags: [String] {
        var counts: [String: Int] = [:]
        var canonical: [String: String] = [:]
        for draft in drafts where draft.deleted == nil {
            for tag in draft.tags {
                let key = tag.lowercased()
                counts[key, default: 0] += 1
                if canonical[key] == nil { canonical[key] = tag }
            }
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return (canonical[lhs.key] ?? lhs.key).localizedStandardCompare(canonical[rhs.key] ?? rhs.key) == .orderedAscending
        }.compactMap { canonical[$0.key] }
    }

    func count(for shelf: Shelf) -> Int {
        matching(shelf).count
    }

    func matching(_ shelf: Shelf, query: String = "", sort: DraftSort = .manual) -> [Draft] {
        let active = drafts.filter { $0.deleted == nil }
        let candidates: [Draft]
        switch shelf {
        case .all: candidates = active
        case .inbox: candidates = active.filter { $0.folderID == nil }
        case .favorites: candidates = active.filter(\.favorite)
        case .recent:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            candidates = active.filter { $0.modified >= cutoff }
        case .trash: candidates = drafts.filter { $0.deleted != nil }
        case .folder(let id):
            let members = descendants(of: id)
            candidates = active.filter { $0.folderID.map(members.contains) == true }
        case .filter(let id):
            guard let filter = filters.first(where: { $0.id == id }) else { return [] }
            let members = filter.folderID.map(descendants)
            let terms = filter.query.split(whereSeparator: \.isWhitespace)
            candidates = active.filter { draft in
                let inFolder = members.map { draft.folderID.map($0.contains) == true } ?? true
                let tagMatches = filter.tag.isEmpty || draft.tags.contains { $0.localizedCaseInsensitiveCompare(filter.tag) == .orderedSame }
                return inFolder && tagMatches && (filter.stage == nil || filter.stage == draft.stage)
                    && matches(draft, terms: terms)
            }
        }
        let terms = query.split(whereSeparator: \.isWhitespace)
        let filtered = terms.isEmpty ? candidates : candidates.filter { matches($0, terms: terms) }
        switch sort {
        case .manual: return filtered
        case .modified: return filtered.sorted { $0.modified > $1.modified }
        case .created: return filtered.sorted { $0.created > $1.created }
        case .title: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func matches(_ draft: Draft, terms: [Substring]) -> Bool {
        if terms.isEmpty { return true }
        let fields = [draft.name, draft.text, draft.note] + draft.tags
        return terms.allSatisfy { term in
            fields.contains { $0.localizedStandardContains(term) }
        }
    }

    func validated() throws -> Library {
        let folderIDs = Set(folders.map(\.id))
        guard version == 1,
              folderIDs.count == folders.count,
              Set(drafts.map(\.id)).count == drafts.count,
              Set(filters.map(\.id)).count == filters.count,
              drafts.allSatisfy({ $0.folderID.map(folderIDs.contains) ?? true }),
              filters.allSatisfy({ $0.folderID.map(folderIDs.contains) ?? true }) else {
            throw LibraryError.invalidBackup
        }
        for folder in folders {
            var ancestors: Set<UUID> = [folder.id]
            var next = folder.parentID
            while let id = next {
                guard ancestors.insert(id).inserted, let parent = self.folder(id) else {
                    throw LibraryError.invalidBackup
                }
                next = parent.parentID
            }
        }
        return self
    }
}

enum LibraryError: LocalizedError {
    case invalidBackup, largeAttachment, unsupportedImport(String), unsafeImport, invalidExport

    var errorDescription: String? {
        switch self {
        case .invalidBackup: "备份的版本或文库结构无法识别。"
        case .largeAttachment: "单个附件的大小上限为 25 MB。"
        case .unsupportedImport(let name): "无法读取「\(name)」的文本格式。"
        case .unsafeImport: "所选来源包含过多文件，或嵌套层次过深。"
        case .invalidExport: "导出未能生成完整的文件。"
        }
    }
}

