import CryptoKit
import Foundation

enum VaultError: LocalizedError {
    case occupied, unavailable(String), invalid(String), incomplete, changed(String)

    var errorDescription: String? {
        switch self {
        case .occupied: "请选择一个尚未使用的文库名称，或一个空文件夹。"
        case .unavailable(let name): "「\(name)」暂时不可用，请检查目录权限或 iCloud 下载状态。"
        case .invalid(let name): "无法识别「\(name)」的文库格式。"
        case .incomplete: "部分文库文件尚未就绪，无法创建完整备份。"
        case .changed(let name): "「\(name)」在其他位置有改动。修改已保留，文库重新可用后可以重试。"
        }
    }
}

struct VaultContents {
    var library = Library()
    var waiting: Set<UUID> = []
    var warnings: [String] = []
    var conflicts: [UUID: [UUID]] = [:]
}

// Callers retain directory access and serialize all operations on a vault instance.
final class FolderVault: @unchecked Sendable {
    static let dataName = "MiMi数据"
    static let inbox = "收件箱"
    static let trash = "废纸篓"
    private static let groupMarker = "分组.json"
    private static let rankStep = 1024.0

    private struct Header: Codable {
        var id = UUID()
        var version = 1
    }

    private struct Group: Codable, Equatable {
        var item: Folder
        var rank: Double
    }

    private struct Asset: Codable {
        let id: UUID
        let name: String
    }

    private struct History: Codable {
        let id: UUID
        let date: Date
        let title: String
    }

    private struct Note: Codable {
        let id: UUID
        var originalFolder: UUID?
        var fileTitle: String?
        var conflictOf: UUID?
        var title: String
        var stage: DraftStage
        var note: String
        var tags: [String]
        var assets: [Asset]
        var history: [History]
        var favorite: Bool
        var material: Bool
        var goal: Int
        var created: Date
        var modified: Date
        var deleted: Date?
        var rank: Double

        init(_ draft: Draft, rank: Double, fileTitle: String?, conflictOf: UUID?) {
            id = draft.id
            originalFolder = draft.folderID
            self.fileTitle = fileTitle
            self.conflictOf = conflictOf
            title = draft.title
            stage = draft.stage
            note = draft.note
            tags = draft.tags
            assets = draft.attachments.map { Asset(id: $0.id, name: $0.name) }
            history = draft.revisions.map { History(id: $0.id, date: $0.date, title: $0.title) }
            favorite = draft.favorite
            material = draft.material
            goal = draft.goal
            created = draft.created
            modified = draft.modified
            deleted = draft.deleted
            self.rank = rank
        }

        func draft(text: String, folder: UUID?, trashed: Bool, attachments: [Attachment], revisions: [Revision]) -> Draft {
            Draft(id: id, folderID: folder, title: title, text: text, stage: stage,
                  note: note, tags: tags, attachments: attachments, revisions: revisions,
                  favorite: favorite, material: material, goal: goal, created: created,
                  modified: modified, deleted: trashed ? (deleted ?? modified) : nil)
        }
    }

    private struct Entry<Value: Codable & Equatable>: Codable {
        var before: Value?
        var after: Value?
    }

    private struct ChangeSet: Codable {
        var drafts: [UUID: Entry<Draft>]
        var folders: [UUID: Entry<Folder>]
        var filters: [UUID: Entry<SmartFilter>]
        var oldDraftOrder: [UUID]
        var draftOrder: [UUID]
        var oldGroupOrder: [UUID]
        var groupOrder: [UUID]
        var oldFilterOrder: [UUID]
        var filterOrder: [UUID]

        init(from base: Library, to desired: Library) {
            drafts = Self.changes(base.drafts, desired.drafts)
            folders = Self.changes(base.folders, desired.folders)
            filters = Self.changes(base.filters, desired.filters)
            oldDraftOrder = base.drafts.map(\.id)
            draftOrder = desired.drafts.map(\.id)
            oldGroupOrder = base.folders.map(\.id)
            groupOrder = desired.folders.map(\.id)
            oldFilterOrder = base.filters.map(\.id)
            filterOrder = desired.filters.map(\.id)
        }

        private static func changes<T: Identifiable & Codable & Equatable>(_ old: [T], _ new: [T]) -> [UUID: Entry<T>] where T.ID == UUID {
            var previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            var result: [UUID: Entry<T>] = [:]
            for item in new {
                let before = previous.removeValue(forKey: item.id)
                if before != item { result[item.id] = Entry(before: before, after: item) }
            }
            for (id, item) in previous { result[id] = Entry(before: item, after: nil) }
            return result
        }
    }

    private struct Scan {
        var notes: [UUID: Note] = [:]
        var bodies: [UUID: URL] = [:]
        var bodyGroups: [UUID: UUID] = [:]
        var trashedBodies: Set<UUID> = []
        var drafts: [UUID: Draft] = [:]
        var groups: [UUID: Group] = [:]
        var directories: [UUID: URL] = [:]
        var filters: [UUID: SmartFilter] = [:]
        var filterRanks: [UUID: Double] = [:]
        var tombstones: Set<UUID> = []
        var purgedBodies: [UUID: [URL]] = [:]
        var deletedGroups: Set<UUID> = []
        var duplicates: Set<UUID> = []
        var waiting: Set<UUID> = []
        var warnings: [String] = []

        var contents: VaultContents {
            var library = Library()
            let draftOrder = FolderVault.ordered(drafts.keys, rank: { notes[$0]?.rank ?? 0 })
            library.drafts = draftOrder.compactMap { drafts[$0] }
            library.folders = FolderVault.ordered(groups.keys, rank: { groups[$0]?.rank ?? 0 }).compactMap { groups[$0]?.item }
            library.filters = FolderVault.ordered(filters.keys, rank: { filterRanks[$0] ?? 0 }).compactMap { filters[$0] }
            var conflicts: [UUID: [UUID]] = [:]
            for id in draftOrder {
                if let original = notes[id]?.conflictOf { conflicts[original, default: []].append(id) }
            }
            return VaultContents(library: library, waiting: waiting, warnings: warnings, conflicts: conflicts)
        }
    }

    let root: URL
    weak var presenter: (any NSFilePresenter)?
    let id: UUID
    private let journal: URL?
    private let fm = FileManager.default
    private var conflictFiles: [URL: [NSFileVersion]] = [:]
    private var coordinator: NSFileCoordinator?
    // Immutable resources are usually unchanged across editor saves. Cache their bytes
    // without relying on timestamps to compare a draft's canonical Markdown.
    private let assetCache = NSCache<NSURL, CachedAsset>()
    private final class CachedAsset {
        let key: AssetKey
        let data: Data
        init(key: AssetKey, data: Data) { self.key = key; self.data = data }
    }
    private struct AssetKey: Equatable {
        let date: Date
        let size: Int
        let identity: NSObject
    }

    init(root: URL, journalDirectory: URL? = nil) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        let header = try Self.coordinate(self.root, writing: false) { url in
            let dirs = [url, url.appending(path: Self.dataName, directoryHint: .isDirectory)]
            for directory in dirs { try Self.requireDirectory(directory) }
            let headerURL = dirs[1].appending(path: "文库.json")
            try Self.requireAvailable(headerURL)
            return try JSONDecoder().decode(Header.self, from: Data(contentsOf: headerURL))
        }
        guard header.version == 1 else { throw VaultError.invalid(root.lastPathComponent) }
        id = header.id
        journal = journalDirectory?.appending(path: "\(header.id.uuidString).json")
        assetCache.totalCostLimit = 32_000_000
    }

    static func create(at destination: URL, with library: Library, journalDirectory: URL? = nil) throws -> FolderVault {
        let validated = try library.validated()
        let fm = FileManager.default
        let target = destination.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        let staging = parent.appending(path: ".MiMi暂存-\(UUID().uuidString)", directoryHint: .isDirectory)
        let header = Header()
        try requireDirectory(parent)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for directory in [inbox, trash, dataName] {
            try fm.createDirectory(at: staging.appending(path: directory, directoryHint: .isDirectory), withIntermediateDirectories: false)
        }
        try JSONEncoder().encode(header).write(to: staging.appending(path: dataName).appending(path: "文库.json"), options: .atomic)
        let vault = try FolderVault(root: staging)
        let roundtrip = try vault.save(from: Library(), to: validated)
        guard roundtrip.warnings.isEmpty, roundtrip.waiting.isEmpty, roundtrip.library == validated else {
            throw VaultError.incomplete
        }
        try coordinate(target, writing: true) { coordinated in
            if fm.fileExists(atPath: coordinated.path) {
                try requireDirectory(coordinated)
                guard try fm.contentsOfDirectory(atPath: coordinated.path).allSatisfy({ $0 == ".DS_Store" }) else {
                    throw VaultError.occupied
                }
                // Publishing into an existing empty folder must still leave a recognizable
                // library only after all of its contents have been prepared.
                _ = try fm.replaceItemAt(coordinated, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: coordinated)
            }
        }
        return try FolderVault(root: target, journalDirectory: journalDirectory)
    }

    func open() throws -> VaultContents {
        if let journal, fm.fileExists(atPath: journal.path) {
            let pending = try JSONDecoder().decode(ChangeSet.self, from: Data(contentsOf: journal))
            return try commit(pending, journalAlreadyWritten: true)
        }
        return try coordinatedVault { url in
            var scan = try self.scan(url)
            try self.preserveSystemConflicts(in: url, scan: &scan)
            return scan.contents
        }
    }

    func save(from base: Library, to desired: Library) throws -> VaultContents {
        _ = try desired.validated()
        return try commit(ChangeSet(from: base, to: desired), journalAlreadyWritten: false)
    }

    private func commit(_ changes: ChangeSet, journalAlreadyWritten: Bool) throws -> VaultContents {
        if !journalAlreadyWritten, let journal {
            try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded(changes).write(to: journal, options: .atomic)
        }
        let result = try coordinatedVault { url in
            var scan = try self.scan(url)
            try self.preserveSystemConflicts(in: url, scan: &scan)
            try self.apply(changes, to: &scan, at: url)
            return try self.scan(url).contents
        }
        if let journal, fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
        return result
    }

    private func coordinatedVault<T>(_ work: (URL) throws -> T) throws -> T {
        try Self.requireDirectory(root)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        return try Self.coordinate(root, writing: true, using: coordinator) { url in
            self.coordinator = coordinator
            defer { self.coordinator = nil }
            return try work(url)
        }
    }

    private static func coordinate<T>(_ url: URL, writing: Bool, using existing: NSFileCoordinator? = nil,
                                      options: NSFileCoordinator.WritingOptions = .forMerging,
                                      work: (URL) throws -> T) throws -> T {
        let coordinator = existing ?? NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: options, error: &error) { coordinated in
                result = Result { try work(coordinated) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { coordinated in
                result = Result { try work(coordinated) }
            }
        }
        if let error { throw error }
        guard let result else { throw VaultError.unavailable(url.lastPathComponent) }
        return try result.get()
    }

    private static func requireAvailable(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isSymbolicLink != true else { throw VaultError.invalid(url.lastPathComponent) }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw VaultError.unavailable(url.lastPathComponent)
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        try requireAvailable(url)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw VaultError.unavailable(url.lastPathComponent)
        }
    }

    private func children(_ directory: URL) throws -> [URL] {
        try Self.requireDirectory(directory)
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                          options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { directory.appending(path: $0.lastPathComponent, directoryHint: $0.hasDirectoryPath ? .isDirectory : .notDirectory) }
    }

    private func bytes(_ url: URL, immutable: Bool = false) throws -> Data {
        try checkParents(of: url)
        try Self.requireAvailable(url)
        return try Self.coordinate(url, writing: false, using: coordinator) { url in
            try Self.requireAvailable(url)
            if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty {
                conflictFiles[url] = versions
            }
            guard immutable else { return try Data(contentsOf: url) }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
            guard let date = values.contentModificationDate, let size = values.fileSize,
                  let identity = values.fileResourceIdentifier as? NSObject else { return try Data(contentsOf: url) }
            let key = AssetKey(date: date, size: size, identity: identity)
            if let cached = assetCache.object(forKey: url as NSURL), cached.key == key { return cached.data }
            let data = try Data(contentsOf: url)
            assetCache.setObject(CachedAsset(key: key, data: data), forKey: url as NSURL, cost: data.count)
            return data
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: bytes(url))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private enum ExpectedBytes {
        case any, missing, exact(Data)
    }

    private func write(_ data: Data, at url: URL, expected: ExpectedBytes = .any) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try Self.coordinate(url, writing: true, using: coordinator) { url in
            let old: Data?
            if fm.fileExists(atPath: url.path) {
                try Self.requireAvailable(url)
                old = try Data(contentsOf: url)
            } else { old = nil }
            if old == data { return }
            switch expected {
            case .any: break
            case .missing where old == nil: break
            case .exact(let bytes) where bytes == old: break
            default: throw VaultError.changed(url.lastPathComponent)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    private func checkParents(of url: URL) throws {
        var directory = url.deletingLastPathComponent()
        while true {
            try Self.requireDirectory(directory)
            if directory.path == root.path || directory.resolvingSymlinksInPath().path == root.path { return }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw VaultError.invalid(url.lastPathComponent) }
            directory = parent
        }
    }

    private func makeDirectory(_ url: URL) throws {
        if url.path == root.path || url.resolvingSymlinksInPath().path == root.path {
            try Self.requireDirectory(url)
            return
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw VaultError.invalid(url.lastPathComponent) }
        try makeDirectory(parent)
        if fm.fileExists(atPath: url.path) { try Self.requireDirectory(url); return }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
    }

    private func data(_ root: URL, _ section: String) -> URL {
        root.appending(path: Self.dataName, directoryHint: .isDirectory).appending(path: section, directoryHint: .isDirectory)
    }

    private func record(_ root: URL, _ section: String, _ id: UUID, ext: String = "json") -> URL {
        data(root, section).appending(path: "\(id.uuidString).\(ext)")
    }

    private func resource(_ root: URL, _ section: String, _ draft: UUID, _ name: String) -> URL {
        data(root, section).appending(path: draft.uuidString, directoryHint: .isDirectory).appending(path: name)
    }

    private func assetName(_ id: UUID, _ original: String) -> String {
        let ext = (original as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 12, ext.unicodeScalars.allSatisfy({
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }) else { return id.uuidString }
        return "\(id.uuidString).\(ext)"
    }

    private static func ordered(_ ids: some Sequence<UUID>, rank: (UUID) -> Double) -> [UUID] {
        ids.sorted {
            let a = rank($0), b = rank($1)
            return a == b ? $0.uuidString < $1.uuidString : a < b
        }
    }

    private static func bodyID(_ url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "md", name.count > 38,
              name.dropLast(36).hasSuffix("--") else { return nil }
        return UUID(uuidString: String(name.suffix(36)))
    }

    private static func name(_ value: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let raw = value.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "." })
        var safe = ""
        for character in raw {
            guard safe.utf8.count + String(character).utf8.count <= 160 else { break }
            safe.append(character)
        }
        return safe.isEmpty ? fallback : safe
    }
}

extension FolderVault {
    private struct RankedFilter: Codable {
        var item: SmartFilter
        var rank: Double
    }

    private func scan(_ root: URL) throws -> Scan {
        conflictFiles.removeAll()
        try Self.requireDirectory(root.appending(path: Self.dataName))
        let header = try decode(Header.self, at: root.appending(path: Self.dataName).appending(path: "文库.json"))
        guard header.id == id, header.version == 1 else { throw VaultError.invalid(root.lastPathComponent) }
        var scan = Scan()
        for (section, isGroup) in [("已删除文稿", false), ("已删除分组", true)] {
            let directory = data(root, section)
            let files = fm.fileExists(atPath: directory.path) ? try children(directory) : []
            for url in files where url.pathExtension == "json" {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                    if isGroup { scan.deletedGroups.insert(id) }
                    else { scan.tombstones.insert(id) }
                }
            }
        }
        try inspectDirectory(root, parent: nil, mode: .root, into: &scan)
        let metadata = data(root, "文稿")
        if fm.fileExists(atPath: metadata.path) {
            for url in try children(metadata) where url.pathExtension == "json" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !scan.tombstones.contains(id) else { continue }
                do {
                    let note = try decode(Note.self, at: url)
                    guard note.id == id, note.rank.isFinite else { throw VaultError.invalid(url.lastPathComponent) }
                    scan.notes[id] = note
                    if scan.bodies[id] == nil { scan.waiting.insert(id) }
                } catch { scan.waiting.insert(id) }
            }
        }
        for (id, url) in scan.bodies where !scan.tombstones.contains(id) {
            guard let note = scan.notes[id] else { scan.waiting.insert(id); continue }
            do {
                let text = try markdown(at: url)
                let trashed = scan.trashedBodies.contains(id)
                let folder = trashed ? note.originalFolder.flatMap { scan.groups[$0] == nil ? nil : $0 } : scan.bodyGroups[id]
                scan.drafts[id] = try loadDraft(note, text: text, folder: folder, trashed: trashed, at: root)
            } catch { scan.waiting.insert(id) }
        }
        let filters = data(root, "智能筛选")
        if fm.fileExists(atPath: filters.path) {
            for url in try children(filters) where url.pathExtension == "json" {
                do {
                    let filter = try decode(RankedFilter.self, at: url)
                    guard filter.item.id.uuidString == url.deletingPathExtension().lastPathComponent,
                          filter.rank.isFinite,
                          filter.item.folderID.map({ scan.groups[$0] != nil }) ?? true else {
                        throw VaultError.invalid(url.lastPathComponent)
                    }
                    scan.filters[filter.item.id] = filter.item
                    scan.filterRanks[filter.item.id] = filter.rank
                } catch { scan.warnings.append("智能筛选「\(url.lastPathComponent)」暂时不可用。") }
            }
        }
        if !scan.waiting.isEmpty { scan.warnings.append("\(scan.waiting.count) 篇文稿的文件尚未就绪。") }
        return scan
    }

    private func loadDraft(_ note: Note, text: String, folder: UUID?, trashed: Bool, at root: URL) throws -> Draft {
        let attachments = try note.assets.map { asset in
            let data = try bytes(resource(root, "附件", note.id, assetName(asset.id, asset.name)), immutable: true)
            return Attachment(id: asset.id, name: asset.name, data: data)
        }
        let revisions = try note.history.map { version in
            let text = try markdown(at: resource(root, "历史版本", note.id, "\(version.id.uuidString).md"), immutable: true)
            return Revision(id: version.id, date: version.date, title: version.title, text: text)
        }
        return note.draft(text: text, folder: folder, trashed: trashed, attachments: attachments, revisions: revisions)
    }

    private enum DirectoryMode { case root, group, inbox, trash }

    private func inspectDirectory(_ directory: URL, parent: UUID?, mode: DirectoryMode, into scan: inout Scan) throws {
        let entries = try children(directory)
        if mode == .root {
            try inspectDirectory(directory.appending(path: Self.inbox, directoryHint: .isDirectory), parent: nil, mode: .inbox, into: &scan)
            try inspectDirectory(directory.appending(path: Self.trash, directoryHint: .isDirectory), parent: nil, mode: .trash, into: &scan)
        }
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            if mode != .root, let id = Self.bodyID(entry), values.isDirectory != true {
                if scan.tombstones.contains(id) {
                    scan.purgedBodies[id, default: []].append(entry)
                } else if scan.bodies[id] == nil {
                    scan.bodies[id] = entry
                    scan.bodyGroups[id] = parent
                    if mode == .trash { scan.trashedBodies.insert(id) }
                } else {
                    scan.duplicates.insert(id)
                    scan.warnings.append("「\(entry.lastPathComponent)」出现同一文稿的多个文件。已保留磁盘上的各份文件。")
                }
            }
            guard mode == .root || mode == .group, values.isDirectory == true,
                  ![Self.dataName, Self.inbox, Self.trash].contains(entry.lastPathComponent) || mode != .root else { continue }
            let marker = entry.appending(path: Self.groupMarker)
            do {
                let nested = try children(entry)
                guard nested.contains(where: { $0.lastPathComponent == Self.groupMarker }) else { continue }
                var group = try decode(Group.self, at: marker)
                let id = group.item.id
                guard !scan.deletedGroups.contains(id) else { continue }
                guard scan.groups[id] == nil, group.rank.isFinite else { throw VaultError.invalid(entry.lastPathComponent) }
                group.item.parentID = parent
                scan.groups[id] = group
                scan.directories[id] = entry
                try inspectDirectory(entry, parent: id, mode: .group, into: &scan)
            } catch {
                scan.warnings.append("分组「\(entry.lastPathComponent)」暂时不可用。")
            }
        }
    }

    private func markdown(at url: URL, immutable: Bool = false) throws -> String {
        guard let text = String(data: try bytes(url, immutable: immutable), encoding: .utf8) else {
            throw VaultError.invalid(url.lastPathComponent)
        }
        return text
    }

    private func ranks(old: [UUID], new: [UUID], saved: [UUID: Double]) -> [UUID: Double] {
        guard old != new else { return [:] }
        let difference = new.difference(from: old)
        let inserted = Set(difference.insertions.compactMap { change -> UUID? in
            if case .insert(_, let id, _) = change { return id }
            return nil
        })
        var result: [UUID: Double] = [:]
        var previous: Double?
        var index = 0
        while index < new.count {
            let id = new[index]
            if !inserted.contains(id), let rank = saved[id] {
                previous = rank
                index += 1
                continue
            }
            let start = index
            while index < new.count, inserted.contains(new[index]) || saved[new[index]] == nil { index += 1 }
            let count = index - start
            let next = index < new.count ? saved[new[index]] : nil
            let lower = previous ?? (next.map { $0 - Self.rankStep * Double(count + 1) } ?? 0)
            let step = next.map { ($0 - lower) / Double(count + 1) } ?? Self.rankStep
            if step <= 0 || lower + step == lower {
                return Dictionary(uniqueKeysWithValues: new.enumerated().map { ($0.element, Double($0.offset + 1) * Self.rankStep) })
            }
            for offset in 0..<count { result[new[start + offset]] = lower + step * Double(offset + 1) }
            previous = result[new[index - 1]]
        }
        return result
    }

    private func apply(_ changes: ChangeSet, to scan: inout Scan, at root: URL) throws {
        let groupRanks = ranks(old: changes.oldGroupOrder, new: changes.groupOrder, saved: scan.groups.mapValues(\.rank))
        // Parents must be available before creating or moving their children.
        var remaining = changes.groupOrder.filter { changes.folders[$0]?.after != nil || groupRanks[$0] != nil }
        while !remaining.isEmpty {
            let pending = Set(remaining)
            let ready = remaining.filter { id in
                let group = changes.folders[id]?.after ?? scan.groups[id]?.item
                return group?.parentID.map { !pending.contains($0) } ?? true
            }
            guard !ready.isEmpty else { throw VaultError.invalid(root.lastPathComponent) }
            for id in ready {
                let prior = changes.folders[id]?.before
                guard let group = changes.folders[id]?.after ?? scan.groups[id]?.item else { continue }
                let current = scan.groups[id]?.item
                if let entry = changes.folders[id], current != entry.before, current != entry.after {
                    // A directory move can already have reached the filesystem while the
                    // group marker still reflects the previous settings.
                    var moved = entry.before
                    moved?.parentID = entry.after?.parentID
                    guard current == moved, !scan.deletedGroups.contains(id) else { throw VaultError.changed(group.name) }
                }
                guard !scan.deletedGroups.contains(id) else { throw VaultError.changed(group.name) }
                let rank = groupRanks[id] ?? scan.groups[id]?.rank ?? 0
                try putGroup(Group(item: group, rank: rank), previous: prior, into: &scan, at: root)
            }
            let completed = Set(ready)
            remaining.removeAll { completed.contains($0) }
        }

        let noteRanks = ranks(old: changes.oldDraftOrder, new: changes.draftOrder, saved: scan.notes.mapValues(\.rank))
        let changed = changes.draftOrder.filter { changes.drafts[$0]?.after != nil || noteRanks[$0] != nil }
        let creations = changed.filter { changes.drafts[$0] != nil && changes.drafts[$0]?.before == nil }
        let edits = changed.filter { !creations.contains($0) }
        for id in creations + edits {
            let entry = changes.drafts[id]
            var actual = scan.drafts[id]
            guard let draft = entry?.after ?? actual else { continue }
            guard !scan.duplicates.contains(id) else { throw VaultError.changed(draft.name) }
            if scan.waiting.contains(id) {
                let interruptedCreation = entry?.before == nil && scan.bodies[id] == nil &&
                    scan.notes[id]?.id == id && !scan.tombstones.contains(id)
                guard interruptedCreation else { throw VaultError.unavailable(draft.name) }
            }
            let rank = noteRanks[id] ?? scan.notes[id]?.rank ?? 0
            if let entry {
                if let before = entry.before, before.deleted == nil, draft.deleted != nil,
                   scan.trashedBodies.contains(id), scan.notes[id]?.deleted == nil {
                    actual?.deleted = draft.deleted
                }
                if scan.tombstones.contains(id) || (actual == nil && entry.before != nil) {
                    try putConflict(draft, original: id, at: root, scan: &scan)
                    continue
                }
                if let actual, let before = entry.before, actual != before, actual != draft {
                    if let merged = Self.mergeDraft(before: before, local: draft, disk: actual) {
                        try putDraft(merged, rank: rank, at: root, scan: &scan)
                    } else {
                        try putConflict(draft, original: id, at: root, scan: &scan)
                    }
                    continue
                }
                if let actual, entry.before == nil, actual != draft {
                    try putConflict(draft, original: id, at: root, scan: &scan)
                    continue
                }
            }
            try putDraft(draft, rank: rank, at: root, scan: &scan)
        }
        for (id, entry) in changes.drafts where entry.after == nil {
            guard !scan.waiting.contains(id), !scan.duplicates.contains(id) else {
                throw VaultError.unavailable(entry.before?.name ?? id.uuidString)
            }
            if let current = scan.drafts[id], current != entry.before {
                try putConflict(current, original: id, at: root, scan: &scan)
            }
            try write(try encoded(id), at: record(root, "已删除文稿", id))
            let bodies = scan.bodies[id].map { [$0] } ?? scan.purgedBodies[id] ?? []
            for body in bodies {
                let text = try markdown(at: body)
                if var original = entry.before, text != original.text, text != scan.drafts[id]?.text {
                    original.text = text
                    try putConflict(original, original: id, at: root, scan: &scan)
                }
                try remove(body, expected: Data(text.utf8))
            }
            for url in [record(root, "文稿", id), data(root, "附件").appending(path: id.uuidString),
                        data(root, "历史版本").appending(path: id.uuidString)] {
                try remove(url)
            }
            scan.tombstones.insert(id)
        }

        let filterRanks = ranks(old: changes.oldFilterOrder, new: changes.filterOrder, saved: scan.filterRanks)
        for id in Set(changes.filters.keys).union(filterRanks.keys) {
            let entry = changes.filters[id]
            let current = scan.filters[id]
            let url = record(root, "智能筛选", id)
            if let entry, current != entry.before, current != entry.after { throw VaultError.changed(entry.after?.name ?? entry.before?.name ?? "智能筛选") }
            if let filter = entry == nil ? current : entry?.after {
                try write(try encoded(RankedFilter(item: filter, rank: filterRanks[id] ?? scan.filterRanks[id] ?? 0)), at: url)
            } else if fm.fileExists(atPath: url.path) {
                try remove(url)
            }
        }
        let removed = changes.folders.filter { $0.value.after == nil }.keys.sorted {
            (scan.directories[$0]?.pathComponents.count ?? 0) > (scan.directories[$1]?.pathComponents.count ?? 0)
        }
        for id in removed {
            guard let url = scan.directories[id], !scan.deletedGroups.contains(id) else { continue }
            guard scan.groups[id]?.item == changes.folders[id]?.before,
                  !scan.directories.contains(where: { $0.key != id && $0.value.pathComponents.starts(with: url.pathComponents) }),
                  !(try children(url)).contains(where: { Self.bodyID($0) != nil }) else {
                throw VaultError.changed(url.lastPathComponent)
            }
            try write(try encoded(id), at: record(root, "已删除分组", id))
            try remove(url.appending(path: Self.groupMarker))
            if try fm.contentsOfDirectory(atPath: url.path).isEmpty { try remove(url) }
            scan.directories.removeValue(forKey: id)
            scan.groups.removeValue(forKey: id)
        }
    }

    private func putGroup(_ group: Group, previous: Folder?, into scan: inout Scan, at root: URL) throws {
        let id = group.item.id
        let parent: URL
        if let parentID = group.item.parentID {
            guard let directory = scan.directories[parentID] else { throw VaultError.unavailable(group.item.name) }
            parent = directory
        } else { parent = root }
        let current = scan.directories[id]
        let wantsMove = current == nil || (previous != nil && (previous?.name != group.item.name || previous?.parentID != group.item.parentID))
        let destination: URL
        if wantsMove {
            let name = Self.name(group.item.name, fallback: "分组")
            let plain = parent.appending(path: name, directoryHint: .isDirectory)
            let reserved = parent.path == root.path && [Self.inbox, Self.trash, Self.dataName].contains(name)
            if reserved || (fm.fileExists(atPath: plain.path) && !sameItem(plain, current)) {
                destination = parent.appending(path: "\(name)--\(id.uuidString)", directoryHint: .isDirectory)
            } else { destination = plain }
        } else if let current { destination = current }
        else { throw VaultError.unavailable(group.item.name) }
        if let current, current.path != destination.path {
            try move(current, to: destination)
            for (key, url) in scan.directories where url.path.hasPrefix(current.path + "/") {
                scan.directories[key] = URL(fileURLWithPath: destination.path + String(url.path.dropFirst(current.path.count)), isDirectory: true)
            }
            for (key, url) in scan.bodies where url.path.hasPrefix(current.path + "/") {
                scan.bodies[key] = URL(fileURLWithPath: destination.path + String(url.path.dropFirst(current.path.count)))
            }
        } else if current == nil {
            let staging = parent.appending(path: ".MiMi分组-\(id.uuidString)", directoryHint: .isDirectory)
            if !fm.fileExists(atPath: staging.path) {
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            }
            try write(try encoded(group), at: staging.appending(path: Self.groupMarker))
            try move(staging, to: destination)
        }
        try write(try encoded(group), at: destination.appending(path: Self.groupMarker))
        scan.directories[id] = destination
        scan.groups[id] = group
    }

    private func putDraft(_ draft: Draft, rank: Double, conflictOf: UUID? = nil, at root: URL, scan: inout Scan) throws {
        let id = draft.id
        let previous = scan.notes[id]
        let oldBody = scan.bodies[id]
        var fileTitle = previous?.fileTitle
        if previous == nil || previous?.title != draft.title || fileTitle == nil {
            fileTitle = draft.isBlank ? nil : draft.name
        }
        let parent: URL
        if draft.deleted != nil { parent = root.appending(path: Self.trash, directoryHint: .isDirectory) }
        else if let folder = draft.folderID {
            guard let directory = scan.directories[folder] else { throw VaultError.unavailable(draft.name) }
            parent = directory
        } else { parent = root.appending(path: Self.inbox, directoryHint: .isDirectory) }
        let filename: String
        if fileTitle == previous?.fileTitle, let oldBody { filename = oldBody.lastPathComponent }
        else { filename = "\(Self.name(fileTitle ?? "", fallback: "未命名文稿"))--\(id.uuidString).md" }
        let destination = parent.appending(path: filename)
        let note = Note(draft, rank: rank, fileTitle: fileTitle, conflictOf: conflictOf ?? previous?.conflictOf)
        let existingAttachments = Dictionary(scan.drafts[id]?.attachments.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        for attachment in draft.attachments where attachment != existingAttachments[attachment.id] {
            let url = resource(root, "附件", id, assetName(attachment.id, attachment.name))
            try write(attachment.data, at: url)
        }
        let existingRevisions = Dictionary(scan.drafts[id]?.revisions.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        for version in draft.revisions where version != existingRevisions[version.id] {
            try write(Data(version.text.utf8), at: resource(root, "历史版本", id, "\(version.id.uuidString).md"))
        }
        let metadata = record(root, "文稿", id)
        if oldBody == nil {
            try write(try encoded(note), at: metadata)
            // A coordinated write may have published the marker before the body
            // on a previous attempt. It is safe to finish that same creation.
            try write(Data(draft.text.utf8), at: destination, expected: .missing)
        } else if let oldBody {
            let expected = scan.drafts[id].map { ExpectedBytes.exact(Data($0.text.utf8)) } ?? .any
            try write(Data(draft.text.utf8), at: oldBody, expected: expected)
            if oldBody.path != destination.path { try move(oldBody, to: destination) }
            try write(try encoded(note), at: metadata)
        }
        // Unreferenced resources are left in place until a permanent purge.
        // Another device may still be reading the prior metadata record.
        scan.bodies[id] = destination
        scan.notes[id] = note
        scan.drafts[id] = draft
        scan.waiting.remove(id)
    }

    private func sameItem(_ first: URL, _ second: URL?) -> Bool {
        guard let second else { return false }
        if first.path == second.path { return true }
        let a = (try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        let b = (try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        return a != nil && a == b
    }

    private func move(_ source: URL, to destination: URL) throws {
        let coordinator = self.coordinator ?? NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination,
                               options: .forReplacing, error: &coordinationError) { source, destination in
            result = Result {
                guard !fm.fileExists(atPath: destination.path) || sameItem(source, destination) else { throw VaultError.occupied }
                try Self.requireAvailable(source)
                try fm.moveItem(at: source, to: destination)
                coordinator.item(at: source, didMoveTo: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw VaultError.unavailable(source.lastPathComponent) }
        try result.get()
    }

    private func remove(_ url: URL, expected: Data? = nil) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        try checkParents(of: url)
        try Self.coordinate(url, writing: true, using: coordinator, options: .forDeleting) { url in
            try Self.requireAvailable(url)
            if let expected, try Data(contentsOf: url) != expected {
                throw VaultError.changed(url.lastPathComponent)
            }
            try fm.removeItem(at: url)
        }
    }

    // Three-way comparison of independent fields keeps, for example, a remote
    // body edit and a local tag edit. A competing value is kept as a copy.
    static func mergeDraft(before: Draft, local: Draft, disk: Draft) -> Draft? {
        var output = disk
        var conflicted = false
        func merge<Value: Equatable>(_ key: WritableKeyPath<Draft, Value>) {
            guard local[keyPath: key] != before[keyPath: key] else { return }
            if disk[keyPath: key] != before[keyPath: key], disk[keyPath: key] != local[keyPath: key] {
                conflicted = true
            }
            output[keyPath: key] = local[keyPath: key]
        }
        merge(\.text)
        merge(\.title)
        merge(\.note)
        merge(\.stage)
        merge(\.tags)
        merge(\.attachments)
        merge(\.revisions)
        merge(\.favorite)
        merge(\.material)
        merge(\.goal)
        merge(\.created)
        merge(\.folderID)
        merge(\.deleted)
        output.modified = max(local.modified, disk.modified)
        return conflicted ? nil : output
    }

    private func putConflict(_ candidate: Draft, original: UUID, at root: URL, scan: inout Scan) throws {
        let hash = SHA256.hash(data: try encoded(candidate))
        let parts = Array(hash.prefix(16))
        let id = UUID(uuid: (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7],
                             parts[8], parts[9], parts[10], parts[11], parts[12], parts[13], parts[14], parts[15]))
        guard scan.drafts[id] == nil, !scan.tombstones.contains(id) else { return }
        var copy = candidate
        copy.id = id
        copy.title = candidate.name + "（冲突副本）"
        copy.deleted = nil
        if let folder = copy.folderID, scan.groups[folder] == nil { copy.folderID = nil }
        try putDraft(copy, rank: scan.notes[original]?.rank ?? 0, conflictOf: original, at: root, scan: &scan)
    }

    private func preserveSystemConflicts(in root: URL, scan: inout Scan) throws {
        let conflicts = conflictFiles
        for (url, versions) in conflicts {
            for version in versions {
                guard let versionURL = version.url as URL? else { continue }
                let payload = try Data(contentsOf: versionURL)
                let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                if let id = Self.bodyID(url), var draft = scan.drafts[id],
                   let text = String(data: payload, encoding: .utf8) {
                    if text != draft.text {
                        draft.text = text
                        draft.modified = version.modificationDate ?? draft.modified
                        try putConflict(draft, original: id, at: root, scan: &scan)
                    }
                } else if url.deletingLastPathComponent().lastPathComponent == "文稿",
                          let metadata = try? JSONDecoder().decode(Note.self, from: payload),
                          let draft = scan.drafts[metadata.id],
                          var alternate = try? loadDraft(metadata, text: draft.text, folder: draft.folderID,
                                                        trashed: draft.deleted != nil, at: root) {
                    alternate.modified = draft.modified
                    if alternate != draft {
                        alternate.modified = metadata.modified
                        try putConflict(alternate, original: draft.id, at: root, scan: &scan)
                    }
                } else {
                    let name = Self.name(url.lastPathComponent, fallback: "文件")
                    let archived = data(root, "同步冲突").appending(path: "\(hash)--\(name)")
                    try write(payload, at: archived)
                    scan.warnings.append("「\(url.lastPathComponent)」的同步冲突版本已保存到「\(Self.dataName)/同步冲突」。")
                }
                version.isResolved = true
            }
        }
    }
}
