import Combine
import Foundation

struct WritingCount: Equatable {
    var words: Int
    var characters: Int
    var charactersWithSpaces: Int
    var paragraphs: Int
    var sentences: Int
    var readingMinutes: Int { words == 0 ? 0 : max(1, Int(ceil(Double(words) / 240))) }
    var speakingMinutes: Int { words == 0 ? 0 : max(1, Int(ceil(Double(words) / 150))) }

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}]|(?:(?![\p{Han}\p{Hiragana}\p{Katakana}])[\p{L}\p{M}\p{N}])+(?:[’'-](?:(?![\p{Han}\p{Hiragana}\p{Katakana}])[\p{L}\p{M}\p{N}])+)*"#
    )
    private static let sentencePattern = try! NSRegularExpression(
        pattern: #"[^.!?。！？\n]+(?:[.!?。！？]+|$)"#
    )

    init(_ source: String) { self.init(blocks: Manuscript.blocks(source)) }

    init(blocks: [Manuscript.Block]) {
        let visible = Manuscript.plainText(in: blocks, forStatistics: true)
        words = Self.wordPattern.numberOfMatches(in: visible, range: NSRange(visible.startIndex..., in: visible))
        characters = visible.lazy.filter { !$0.isWhitespace }.count
        charactersWithSpaces = visible.lazy.filter { !$0.isNewline }.count
        paragraphs = blocks.filter { $0.kind == .paragraph || $0.kind == .quote }.count
        let ns = visible as NSString
        sentences = Self.sentencePattern.matches(in: visible, range: NSRange(location: 0, length: ns.length)).reduce(0) { count, match in
            let piece = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            return count + (piece.isEmpty ? 0 : 1)
        }
    }
}

struct DraftAnalysis {
    var count: WritingCount
    var headings: [Heading]

    init(_ text: String) {
        let blocks = Manuscript.blocks(text)
        count = WritingCount(blocks: blocks)
        headings = Manuscript.headings(in: blocks)
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library: Library
    @Published var saveError: String?
    @Published private(set) var recoveredFile: URL?
    let file: URL
    static let support = URL.applicationSupportDirectory.appending(path: "Inkfolio", directoryHint: .isDirectory)
    private static let bookmarkKey = "libraryFolderBookmark"
    @Published private(set) var folderURL: URL?
    @Published private(set) var openingFolder = false
    @Published private(set) var folderWarnings: [String] = []
    @Published private(set) var conflictCopies: [UUID: [UUID]] = [:]
    var usesFolder: Bool { preferences != nil }
    var needsFolder: Bool { usesFolder && folderURL == nil }
    var canMigrate: Bool { FileManager.default.fileExists(atPath: file.path) }
    private let preferences: UserDefaults?
    private let journalDirectory: URL?
    private var access: VaultAccess?
    private var vault: FolderVault?
    private var observation: VaultObservation?
    private var folderBase = Library()
    private var waiting: Set<UUID> = []
    private var folderJob: FolderJob?
    private var retry: FolderJob?
    private var refreshTask: Task<Void, Never>?
    private var triedBookmark = false

    private struct Selection: Codable {
        let id: UUID
        let bookmark: VaultAccess.Bookmark
    }

    // The writer publishes result before leaving finished. The main actor reads it after that signal.
    private final class FolderJob: @unchecked Sendable {
        let base: Library
        let input: Library
        let refresh: Bool
        let finished = DispatchGroup()
        var result: Result<VaultContents, Error>?

        init(base: Library, input: Library, refresh: Bool) {
            self.base = base
            self.input = input
            self.refresh = refresh
        }
    }
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var persistedGeneration = 0
    private let writer = DispatchQueue(label: "local.inkfolio.library", qos: .utility)
    private final class CachedAnalysis {
        let text: String
        let value: DraftAnalysis

        init(_ text: String) {
            self.text = text
            value = DraftAnalysis(text)
        }
    }
    private let statistics: NSCache<NSUUID, CachedAnalysis> = {
        let cache = NSCache<NSUUID, CachedAnalysis>()
        cache.countLimit = 650
        cache.totalCostLimit = 16_000_000
        return cache
    }()
    private var pendingStatistics: [UUID: (text: String, work: Task<Void, Never>)] = [:]

    init(preferences: UserDefaults = .standard, legacyFile: URL? = nil, journalDirectory: URL? = nil) {
        self.preferences = preferences
        self.journalDirectory = journalDirectory ?? Self.support.appending(path: "待保存", directoryHint: .isDirectory)
        file = legacyFile ?? Self.support.appending(path: "Library.json")
        library = Library()
        writeLocked = true
    }

    // Compatibility with explicit legacy fixtures and the JSON backup format.
    init(file: URL) {
        preferences = nil
        journalDirectory = nil
        self.file = file
        self.library = .example
        guard FileManager.default.fileExists(atPath: self.file.path) else { return }
        do {
            library = try Self.read(self.file)
        } catch {
            let recovered = self.file.deletingLastPathComponent().appending(path: "Recovered-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: self.file, to: recovered)
                recoveredFile = recovered
                library = Library()
                saveError = "文库无法读取。已保留原文件副本，路径为 \(recovered.path)"
            } catch {
                saveError = "文库无法读取，且未能保留原文件副本。写入已暂停。"
                writeLocked = true
                library = Library()
            }
        }
    }

    private var writeLocked = false

    func cancelEditorStatistics() {
        for item in pendingStatistics.values { item.work.cancel() }
        pendingStatistics.removeAll()
        statistics.removeAllObjects()
    }

    var statusMessage: String? { saveError ?? (folderWarnings.isEmpty ? nil : folderWarnings.joined(separator: "\n")) }

    var hasRecoverableChanges: Bool {
        guard let retry, retry.input == library, let id = vault?.id, let journalDirectory else { return false }
        return FileManager.default.fileExists(atPath: journalDirectory.appending(path: "\(id.uuidString).json").path)
    }

    func stopWatchingFolder() {
        refreshTask?.cancel()
        observation?.stop()
    }

    func draft(_ id: UUID?) -> Draft? { library.drafts.first { $0.id == id } }

    func analysis(of draft: Draft) -> DraftAnalysis {
        let key = draft.id as NSUUID
        if let cached = statistics.object(forKey: key) {
            if cached.text == draft.text { return cached.value }
            if draft.text.utf16.count > 12_000 {
                refreshLongDraftStatistics(draft)
                return cached.value
            }
        }
        let cached = CachedAnalysis(draft.text)
        statistics.setObject(cached, forKey: key, cost: draft.text.utf8.count + 64)
        return cached.value
    }

    private func refreshLongDraftStatistics(_ draft: Draft) {
        let id = draft.id
        let text = draft.text
        if pendingStatistics[id]?.text == text { return }
        pendingStatistics[id]?.work.cancel()
        let work = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(190)) } catch { return }
            let worker = Task.detached(priority: .utility) { CachedAnalysis(text) }
            let updated = await worker.value
            guard !Task.isCancelled, let self, self.pendingStatistics[id]?.text == text else { return }
            self.pendingStatistics[id] = nil
            guard self.draft(id)?.text == text else { return }
            self.statistics.setObject(updated, forKey: id as NSUUID, cost: min(16_000_000, text.utf8.count + 64))
            self.objectWillChange.send()
        }
        pendingStatistics[id] = (text: text, work: work)
    }

    @discardableResult
    func addDraft(folder: UUID?, title: String = "", text: String = "", material: Bool = false) -> UUID {
        let draft = Draft(folderID: folder, title: title, text: text, material: material)
        change { $0.drafts.insert(draft, at: 0) }
        return draft.id
    }

    func addFolder(name: String, parent: UUID?, project: Bool, goal: Int, icon: String? = nil) -> UUID {
        let folder = Folder(name: name, parentID: parent, project: project, goal: goal, icon: icon)
        change { $0.folders.append(folder) }
        return folder.id
    }

    func editFolder(_ id: UUID, name: String, goal: Int) {
        change { library in
            guard let index = library.folders.firstIndex(where: { $0.id == id }) else { return }
            library.folders[index].name = name
            library.folders[index].goal = goal
        }
    }

    func editFolder(_ id: UUID, name: String, parentID: UUID?, project: Bool, goal: Int, icon: String? = nil) {
        change { library in
            guard let index = library.folders.firstIndex(where: { $0.id == id }) else { return }
            let forbidden = library.descendants(of: id)
            let safeParent = parentID.flatMap { forbidden.contains($0) ? nil : $0 }
            library.folders[index].name = name
            library.folders[index].parentID = project ? nil : safeParent
            library.folders[index].project = project
            library.folders[index].goal = goal
            library.folders[index].icon = icon
        }
    }

    func removeFolder(_ id: UUID) {
        change { library in
            let removed = library.descendants(of: id)
            library.folders.removeAll { removed.contains($0.id) }
            library.filters.removeAll { $0.folderID.map(removed.contains) == true }
            for index in library.drafts.indices where library.drafts[index].folderID.map(removed.contains) == true {
                library.drafts[index].folderID = nil
                if library.drafts[index].deleted == nil { library.drafts[index].deleted = Date() }
            }
        }
    }

    func saveFilter(_ filter: SmartFilter) {
        change {
            if let index = $0.filters.firstIndex(where: { $0.id == filter.id }) {
                $0.filters[index] = filter
            } else {
                $0.filters.append(filter)
            }
        }
    }

    func deleteFilter(_ id: UUID) { change { $0.filters.removeAll { $0.id == id } } }

    func edit(_ id: UUID, _ apply: (inout Draft) -> Void) {
        change { library in
            guard let index = library.drafts.firstIndex(where: { $0.id == id }) else { return }
            let prior = library.drafts[index]
            apply(&library.drafts[index])
            if library.drafts[index] != prior { library.drafts[index].modified = Date() }
        }
    }

    func trash(_ ids: Set<UUID>) {
        change { library in
            for index in library.drafts.indices where ids.contains(library.drafts[index].id) {
                library.drafts[index].deleted = Date()
            }
        }
    }

    func restore(_ ids: Set<UUID>) {
        change { library in
            for index in library.drafts.indices where ids.contains(library.drafts[index].id) {
                library.drafts[index].deleted = nil
            }
        }
    }

    func purge(_ ids: Set<UUID>) {
        change { $0.drafts.removeAll { $0.deleted != nil && ids.contains($0.id) } }
    }

    func duplicate(_ id: UUID) -> UUID? {
        guard var copy = draft(id), copy.deleted == nil else { return nil }
        let title = copy.name
        copy.id = UUID()
        copy.title = title + "（副本）"
        copy.created = Date()
        copy.modified = Date()
        copy.revisions = []
        change { $0.drafts.insert(copy, at: 0) }
        return copy.id
    }

    func move(_ id: UUID, to folder: UUID?) { edit(id) { $0.folderID = folder } }

    func move(_ ids: Set<UUID>, to folder: UUID?) {
        change { library in
            let now = Date()
            for index in library.drafts.indices where ids.contains(library.drafts[index].id) && library.drafts[index].deleted == nil {
                if library.drafts[index].folderID != folder {
                    library.drafts[index].folderID = folder
                    library.drafts[index].modified = now
                }
            }
        }
    }

    func setFavorite(_ ids: Set<UUID>, _ value: Bool) {
        change { library in
            let now = Date()
            for index in library.drafts.indices where ids.contains(library.drafts[index].id) && library.drafts[index].deleted == nil {
                if library.drafts[index].favorite != value {
                    library.drafts[index].favorite = value
                    library.drafts[index].modified = now
                }
            }
        }
    }

    func setMaterial(_ ids: Set<UUID>, _ value: Bool) {
        change { library in
            let now = Date()
            for index in library.drafts.indices where ids.contains(library.drafts[index].id) && library.drafts[index].deleted == nil {
                if library.drafts[index].material != value {
                    library.drafts[index].material = value
                    library.drafts[index].modified = now
                }
            }
        }
    }

    func reorder(_ moving: UUID, before anchor: UUID) {
        guard moving != anchor else { return }
        change { library in
            guard let source = library.drafts.firstIndex(where: { $0.id == moving }),
                  library.drafts.contains(where: { $0.id == anchor }) else { return }
            let draft = library.drafts.remove(at: source)
            if let target = library.drafts.firstIndex(where: { $0.id == anchor }) {
                library.drafts.insert(draft, at: target)
            }
        }
    }

    func reorder(_ moving: UUID, after anchor: UUID) {
        guard moving != anchor else { return }
        change { library in
            guard let source = library.drafts.firstIndex(where: { $0.id == moving }),
                  library.drafts.contains(where: { $0.id == anchor }) else { return }
            let draft = library.drafts.remove(at: source)
            if let target = library.drafts.firstIndex(where: { $0.id == anchor }) {
                library.drafts.insert(draft, at: min(target + 1, library.drafts.count))
            }
        }
    }

    func snapshot(_ id: UUID) {
        edit(id) {
            let snapshot = Revision(title: $0.title, text: $0.text)
            $0.revisions.insert(snapshot, at: 0)
        }
    }

    func deleteRevision(_ revisionID: UUID, in draftID: UUID) {
        edit(draftID) {
            $0.revisions.removeAll { $0.id == revisionID }
        }
    }

    func revert(_ id: UUID, to revision: Revision) {
        edit(id) {
            $0.revisions.insert(Revision(title: $0.title, text: $0.text), at: 0)
            $0.title = revision.title
            $0.text = revision.text
        }
    }

    func split(_ id: UUID, at index: String.Index) -> UUID? {
        guard let original = draft(id), original.deleted == nil, index > original.text.startIndex,
              index < original.text.endIndex else { return nil }
        let second = Draft(folderID: original.folderID, text: String(original.text[index...]),
                           stage: original.stage, tags: original.tags, attachments: original.attachments, material: original.material)
        change { library in
            guard let position = library.drafts.firstIndex(where: { $0.id == id }) else { return }
            library.drafts[position].revisions.insert(Revision(title: original.title, text: original.text), at: 0)
            library.drafts[position].text = String(original.text[..<index])
            library.drafts[position].modified = Date()
            library.drafts.insert(second, at: position + 1)
        }
        return second.id
    }

    func merge(_ ids: [UUID]) -> UUID? {
        let items = ids.compactMap(draft).filter { $0.deleted == nil }
        guard let first = items.first, items.count > 1 else { return nil }
        let remaining = Array(items.dropFirst())
        let others = Set(remaining.map(\.id))
        var merged = first
        merged.revisions.insert(Revision(title: first.title, text: first.text), at: 0)
        merged.title = first.name
        merged.text = items.map(\.text).joined(separator: "\n\n")
        merged.modified = Date()
        for item in remaining {
            for tag in item.tags where !merged.tags.contains(tag) { merged.tags.append(tag) }
            for file in item.attachments where !merged.attachments.contains(where: { $0.id == file.id }) {
                merged.attachments.append(file)
            }
        }
        change { library in
            for index in library.drafts.indices {
                let id = library.drafts[index].id
                if id == first.id { library.drafts[index] = merged }
                if others.contains(id) { library.drafts[index].deleted = Date() }
            }
        }
        return merged.id
    }

    func applyImport(_ batch: Library) {
        change {
            $0.folders.append(contentsOf: batch.folders)
            $0.drafts.insert(contentsOf: batch.drafts, at: 0)
        }
    }

    func exportBackup(to destination: URL, recoveringUnsavedChanges: Bool = false) throws {
        if let folderURL {
            if !recoveringUnsavedChanges {
                guard flush() else { throw VaultError.incomplete }
                if let refresh = startFolderJob(refresh: true) {
                    refresh.finished.wait()
                    finish(refresh)
                }
                guard saveError == nil, waiting.isEmpty, folderWarnings.isEmpty else { throw VaultError.incomplete }
            }
            let root = folderURL.resolvingSymlinksInPath().path
            let target = destination.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard target != root, !target.hasPrefix(root + "/") else { throw VaultError.occupied }
        }
        let snapshot = library
        try writer.sync { try Self.write(snapshot, to: destination) }
    }

    func restoreBackup(from url: URL) throws {
        guard !usesFolder else { throw LibraryError.invalidBackup }
        let restored = try Self.read(url)
        guard !writeLocked else { throw LibraryError.invalidBackup }
        let current = library
        let destination = file
        try writer.sync {
            if !current.drafts.isEmpty || !current.folders.isEmpty || FileManager.default.fileExists(atPath: destination.path) {
                let fallback = destination.deletingLastPathComponent().appending(path: "Before-Restore-\(UUID().uuidString).json")
                try Self.write(current, to: fallback)
            }
            try Self.write(restored, to: destination)
        }
        pending?.cancel()
        library = restored
        generation += 1
        persistedGeneration = generation
        saveError = nil
    }

    private func change(_ apply: (inout Library) -> Void) {
        guard !writeLocked, !openingFolder else { return }
        var output = library
        apply(&output)
        guard output != library else { return }
        library = output
        generation += 1
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveInBackground()
        }
    }

    @discardableResult
    func flush() -> Bool {
        if vault != nil {
            pending?.cancel()
            while let job = folderJob ?? startFolderJob() {
                job.finished.wait()
                finish(job)
                if retry != nil { return false }
            }
            return retry == nil && library == folderBase
        }
        guard generation != persistedGeneration, !writeLocked else { return true }
        pending?.cancel()
        let snapshot = library
        let destination = file
        let result = writer.sync { Result { try Self.write(snapshot, to: destination) } }
        complete(result, version: generation)
        return persistedGeneration == generation
    }

    func saveSoon() { saveInBackground() }

    private func saveInBackground() {
        if vault != nil { _ = startFolderJob(); return }
        guard generation != persistedGeneration, !writeLocked else { return }
        let snapshot = library
        let version = generation
        let destination = file
        writer.async { [weak self] in
            let result = Result { try Self.write(snapshot, to: destination) }
            Task { @MainActor [weak self] in self?.complete(result, version: version) }
        }
    }

    private func complete(_ result: Result<Void, Error>, version: Int) {
        guard generation == version else { return }
        switch result {
        case .success:
            persistedGeneration = version
            if saveError != nil { saveError = nil }
        case .failure(let error):
            saveError = "自动保存失败。\(error.localizedDescription)"
        }
    }

    private nonisolated static func read(_ url: URL) throws -> Library {
        try JSONDecoder().decode(Library.self, from: Data(contentsOf: url)).validated()
    }

    private nonisolated static func write(_ library: Library, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: url, options: [.atomic])
    }
}

extension LibraryStore {
    enum FolderAction: Sendable {
        case open(VaultAccess)
        case create(URL, parent: VaultAccess, source: URL?)

        var destination: URL {
            switch self {
            case .open(let access): access.url
            case .create(let target, _, _): target
            }
        }
    }

    func reopenSavedFolder() async -> Bool {
        guard !triedBookmark, vault == nil else { return false }
        triedBookmark = true
        guard let data = preferences?.data(forKey: Self.bookmarkKey) else { return false }
        do {
            let selection = try JSONDecoder().decode(Selection.self, from: data)
            try await selectFolder(.open(selection.bookmark.open()), expectedID: selection.id)
            return true
        } catch {
            saveError = "无法重新打开上次使用的文库。\(error.localizedDescription)"
            return false
        }
    }

    func selectFolder(_ action: FolderAction, expectedID: UUID? = nil) async throws {
        guard !openingFolder else { return }
        if let folderURL, case .create = action {
            let path = action.destination.resolvingSymlinksInPath().path
            guard !path.hasPrefix(folderURL.resolvingSymlinksInPath().path + "/") else { throw VaultError.occupied }
        }
        var requiredID = expectedID
        if !flush() {
            guard case .open = action, hasRecoverableChanges, let id = vault?.id else {
                throw VaultError.changed(folderURL?.lastPathComponent ?? "文库")
            }
            requiredID = id
        }
        openingFolder = true
        defer { openingFolder = false }
        let journalDirectory = self.journalDirectory
        let selectedID = requiredID
        let mounted: (FolderVault, VaultAccess, VaultContents, Data) = try await withCheckedThrowingContinuation { continuation in
            writer.async {
                continuation.resume(with: Result {
                    let vault: FolderVault
                    let access: VaultAccess
                    switch action {
                    case .open(let selected):
                        access = selected
                        if selectedID == nil {
                            vault = try FolderVault.openOrCreate(at: access.url, journalDirectory: journalDirectory)
                        } else {
                            vault = try FolderVault(root: access.url, journalDirectory: journalDirectory)
                        }
                    case .create(let target, let parent, let source):
                        vault = try withExtendedLifetime(parent) {
                            let library = try source.map(Self.read) ?? Library()
                            return try FolderVault.create(at: target, with: library, journalDirectory: journalDirectory)
                        }
                        access = VaultAccess(vault.root)
                    }
                    if let selectedID, vault.id != selectedID { throw VaultError.invalid(vault.root.lastPathComponent) }
                    let bookmark = try JSONEncoder().encode(Selection(id: vault.id, bookmark: access.bookmark()))
                    return (vault, access, try vault.open(), bookmark)
                })
            }
        }
        refreshTask?.cancel()
        observation?.stop()
        vault = mounted.0
        access = mounted.1
        folderBase = mounted.2.library
        library = mounted.2.library
        conflictCopies = mounted.2.conflicts
        waiting = mounted.2.waiting
        folderWarnings = mounted.2.warnings
        saveError = nil
        writeLocked = false
        folderURL = mounted.0.root
        preferences?.set(mounted.3, forKey: Self.bookmarkKey)
        retry = nil
        let observer = VaultObservation(root: mounted.0.root) { [weak self] in
            DispatchQueue.main.async { self?.queueRefresh() }
        }
        mounted.0.presenter = observer
        observation = observer
        queueRefresh()
    }

    func queueRefresh() {
        guard vault != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            if self.folderJob != nil {
                self.queueRefresh()
            } else {
                _ = self.startFolderJob(refresh: true)
            }
        }
    }

    private func startFolderJob(refresh: Bool = false) -> FolderJob? {
        guard let vault, folderJob == nil, !openingFolder else { return nil }
        let job: FolderJob
        if let retry {
            job = FolderJob(base: retry.base, input: retry.input, refresh: retry.refresh)
        } else {
            guard refresh || library != folderBase else { return nil }
            job = FolderJob(base: folderBase, input: library, refresh: library == folderBase)
        }
        folderJob = job
        job.finished.enter()
        writer.async { [weak self] in
            job.result = Result {
                if job.refresh { return try vault.open() }
                return try vault.save(from: job.base, to: job.input)
            }
            job.finished.leave()
            DispatchQueue.main.async { [weak self] in self?.finish(job) }
        }
        return job
    }

    private func finish(_ job: FolderJob) {
        guard folderJob === job, let result = job.result else { return }
        folderJob = nil
        switch result {
        case .success(let contents):
            retry = nil
            var refreshed = contents.library
            let availableGroups = Set(refreshed.folders.map(\.id))
            for (index, previous) in folderBase.drafts.enumerated() where contents.waiting.contains(previous.id) {
                var retained = previous
                if let group = retained.folderID, !availableGroups.contains(group) { retained.folderID = nil }
                refreshed.drafts.insert(retained, at: min(index, refreshed.drafts.count))
            }
            let rebased = Self.rebase(disk: refreshed, submitted: job.input, latest: library)
            folderBase = rebased.base
            if library != rebased.desired { library = rebased.desired }
            if waiting != contents.waiting { waiting = contents.waiting }
            if conflictCopies != contents.conflicts { conflictCopies = contents.conflicts }
            if folderWarnings != contents.warnings { folderWarnings = contents.warnings }
            if saveError != nil { saveError = nil }
            if library != folderBase { _ = startFolderJob() }
        case .failure(let error):
            retry = job.refresh ? nil : job
            saveError = "文库暂时无法\(job.refresh ? "刷新" : "保存")。\(error.localizedDescription)"
        }
    }

    private static func rebase(disk: Library, submitted: Library, latest: Library) -> (base: Library, desired: Library) {
        var base = disk
        var output = disk
        (base.drafts, output.drafts) = rebaseItems(
            disk.drafts, submitted.drafts, latest.drafts, merge: FolderVault.mergeDraft
        )
        (base.folders, output.folders) = rebaseItems(disk.folders, submitted.folders, latest.folders)
        (base.filters, output.filters) = rebaseItems(disk.filters, submitted.filters, latest.filters)
        return (base, output)
    }

    private static func rebaseItems<T: Identifiable & Equatable>(
        _ actual: [T], _ sent: [T], _ latest: [T], merge: ((T, T, T) -> T?)? = nil
    ) -> ([T], [T]) where T.ID == UUID {
        guard sent != latest else { return (actual, actual) }
        var base = Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) })
        var output = base
        let submitted = Dictionary(uniqueKeysWithValues: sent.map { ($0.id, $0) })
        let edited = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
        for id in Set(submitted.keys).union(edited.keys) where submitted[id] != edited[id] {
            if let prior = submitted[id], let local = edited[id], let remote = base[id],
               let merged = merge?(prior, local, remote) {
                output[id] = merged
            } else {
                if base[id] != edited[id] { base[id] = submitted[id] }
                output[id] = edited[id]
            }
        }
        let defaultOrder = actual.map(\.id)
        let sentOrder = sent.map(\.id)
        let latestOrder = latest.map(\.id)
        let order = sentOrder == latestOrder ? defaultOrder : latestOrder
        func sorted(_ values: [UUID: T], preferred: [UUID]) -> [T] {
            var retained = values
            return preferred.compactMap { retained.removeValue(forKey: $0) }
                + defaultOrder.compactMap { retained.removeValue(forKey: $0) }
                + sentOrder.compactMap { retained.removeValue(forKey: $0) }
        }
        return (sorted(base, preferred: defaultOrder), sorted(output, preferred: order))
    }
}
