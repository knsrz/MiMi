import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceLayout: String, CaseIterable {
    case library, manuscripts, focus

    var label: String {
        switch self {
        case .library: "完整工作台"
        case .manuscripts: "文稿和编辑器"
        case .focus: "专注写作"
        }
    }

    var symbol: String {
        switch self {
        case .library: "rectangle.split.3x1"
        case .manuscripts: "rectangle.split.2x1"
        case .focus: "rectangle"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .library: "1"
        case .manuscripts: "2"
        case .focus: "3"
        }
    }
}

enum WorkspaceDialog: Identifiable {
    case search
    case folder(parent: UUID?, project: Bool, editing: Folder?)
    case filter(folder: UUID?, editing: SmartFilter?)
    case export([Draft])
    case equation(EquationEdit)
    case rename(Draft)

    var id: String {
        switch self {
        case .search: "search"
        case .folder: "folder"
        case .filter: "filter"
        case .export: "export"
        case .equation: "equation"
        case .rename: "rename"
        }
    }
}

enum PreviewMode: String, CaseIterable {
    case writing, live, reading

    var label: String {
        switch self {
        case .writing: "仅编辑"
        case .live: "实时预览"
        case .reading: "仅预览"
        }
    }

    var symbol: String {
        switch self {
        case .writing: "pencil"
        case .live: "rectangle.split.2x1"
        case .reading: "doc.richtext"
        }
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview, outline, annotations, history
    var id: Self { self }

    var label: String {
        switch self {
        case .overview: "概览与目标"
        case .outline: "文稿大纲"
        case .annotations: "附注与附件"
        case .history: "版本历史"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.needle"
        case .outline: "list.bullet.indent"
        case .annotations: "paperclip"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum EditorTheme: String, CaseIterable, Identifiable {
    case paper, pine
    var id: Self { self }

    var label: String {
        switch self {
        case .paper: "素纸（极简）"
        case .pine: "松墨（暖纸）"
        }
    }
}

struct EquationEdit {
    var draftID: UUID
    var range: NSRange
    var original: String
    var source: String
    var display: Bool
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var shelf: Shelf {
        didSet { if oldValue != shelf { preferences?.set(shelf.savedValue, forKey: "lastShelf") } }
    }
    @Published var selected: Set<UUID>
    @Published var primaryID: UUID? {
        didSet { if oldValue != primaryID { preferences?.set(primaryID?.uuidString, forKey: "lastDraft") } }
    }
    @Published var query = ""
    @Published var showListFilter = false
    @Published var zenFaded = false
    @Published var isFullScreen = false
    @Published var layout = WorkspaceLayout.library {
        didSet {
            if oldValue != layout {
                focusInspector = false
                zenFaded = false
                if layout == .focus { previewMode = .writing }
                preferences?.set(layout.rawValue, forKey: "workspaceLayout")
            }
        }
    }
    @Published var inspector = false {
        didSet { if oldValue != inspector { preferences?.set(inspector, forKey: "workspaceInspector") } }
    }
    @Published var dashboardTab = DashboardTab.overview {
        didSet { if oldValue != dashboardTab { preferences?.set(dashboardTab.rawValue, forKey: "dashboardTab") } }
    }
    @Published var libraryWidth: CGFloat = WorkspacePane.library.defaultWidth {
        didSet { if oldValue != libraryWidth { preferences?.set(Double(libraryWidth), forKey: WorkspacePane.library.preferenceKey) } }
    }
    @Published var browserWidth: CGFloat = WorkspacePane.browser.defaultWidth {
        didSet { if oldValue != browserWidth { preferences?.set(Double(browserWidth), forKey: WorkspacePane.browser.preferenceKey) } }
    }
    @Published var inspectorWidth: CGFloat = WorkspacePane.inspector.defaultWidth {
        didSet { if oldValue != inspectorWidth { preferences?.set(Double(inspectorWidth), forKey: WorkspacePane.inspector.preferenceKey) } }
    }
    @Published private var focusInspector = false
    @Published var previewMode = PreviewMode.writing
    @Published var sort = DraftSort.manual {
        didSet { if oldValue != sort { preferences?.set(sort.rawValue, forKey: "draftSort") } }
    }
    @Published var dialog: WorkspaceDialog?
    @Published var error: String?
    @Published private(set) var history: [UUID] = []
    @Published private(set) var historyPosition = -1
    let store: LibraryStore
    let editor = EditorBridge()
    private let preferences: UserDefaults?
    private var focusAfterDialog: UUID?

    init(store: LibraryStore, preferences: UserDefaults? = nil) {
        self.store = store
        self.preferences = preferences
        let defaultShelf = store.library.folders.first(where: \.project).map { Shelf.folder($0.id) } ?? .all
        let initialShelf = preferences?.string(forKey: "lastShelf").flatMap(Shelf.init(savedValue:))
            .flatMap { $0.exists(in: store.library) ? $0 : nil } ?? defaultShelf
        let initialSort = preferences?.string(forKey: "draftSort").flatMap(DraftSort.init(rawValue:)) ?? .manual
        let candidates = store.library.matching(initialShelf, sort: initialSort)
        let lastID = preferences?.string(forKey: "lastDraft").flatMap(UUID.init(uuidString:))
        let initialDraft = candidates.first { $0.id == lastID }?.id ?? candidates.first?.id
        shelf = initialShelf
        sort = initialSort
        primaryID = initialDraft
        selected = initialDraft.map { [$0] } ?? []
        layout = preferences?.string(forKey: "workspaceLayout").flatMap(WorkspaceLayout.init(rawValue:)) ?? .library
        inspector = preferences?.bool(forKey: "workspaceInspector") ?? false
        dashboardTab = preferences?.string(forKey: "dashboardTab").flatMap(DashboardTab.init(rawValue:)) ?? .overview
        for pane in WorkspacePane.allCases {
            if let saved = preferences?.object(forKey: pane.preferenceKey) as? NSNumber, saved.doubleValue.isFinite {
                let minimum = pane.minimumWidth(showsLibrary: true)
                setPaneWidth(min(pane.maximumWidth, max(minimum, CGFloat(saved.doubleValue))), for: pane)
            }
        }
        if let initialDraft { pushHistory(initialDraft) }
    }

    var items: [Draft] { store.library.matching(shelf, query: query, sort: sort) }
    var current: Draft? { store.draft(primaryID) }
    var preview: Bool {
        get { previewMode == .reading }
        set {
            if newValue { previewMode = .reading }
            else if previewMode == .reading { previewMode = .writing }
        }
    }
    var showsInspector: Bool { layout == .focus ? focusInspector : inspector }

    var paneSizing: WorkspaceSizing {
        WorkspaceSizing(library: layout == .library, browser: layout != .focus, inspector: showsInspector && current != nil)
    }

    var preferredPaneWidths: [WorkspacePane: CGFloat] {
        [.library: libraryWidth, .browser: browserWidth, .inspector: inspectorWidth]
    }

    func setPaneWidth(_ width: CGFloat, for pane: WorkspacePane) {
        switch pane {
        case .library: if width != libraryWidth { libraryWidth = width }
        case .browser: if width != browserWidth { browserWidth = width }
        case .inspector: if width != inspectorWidth { inspectorWidth = width }
        }
    }

    func setInspector(_ visible: Bool) {
        if layout == .focus { focusInspector = visible }
        else { inspector = visible }
    }

    private func validHistoryIndex(offset: Int) -> Int? {
        var position = historyPosition + offset
        while history.indices.contains(position) {
            if let draft = store.draft(history[position]), draft.deleted == nil { return position }
            position += offset
        }
        return nil
    }

    var canGoBack: Bool { validHistoryIndex(offset: -1) != nil }
    var canGoForward: Bool { validHistoryIndex(offset: 1) != nil }

    var folder: UUID? {
        switch shelf {
        case .folder(let id): id
        case .filter(let id): store.library.filters.first { $0.id == id }?.folderID
        default: nil
        }
    }

    var shelfName: String {
        switch shelf {
        case .all: "全部文稿"
        case .inbox: "收件箱"
        case .favorites: "收藏"
        case .recent: "最近七天"
        case .trash: "废纸篓"
        case .folder(let id): store.library.folder(id)?.name ?? "分组"
        case .filter(let id): store.library.filters.first { $0.id == id }?.name ?? "智能筛选"
        }
    }

    func folderWordCount(for id: UUID) -> Int {
        store.library.matching(.folder(id)).lazy.filter { !$0.material }.reduce(0) {
            $0 + store.analysis(of: $1).count.words
        }
    }

    var folderWordCount: Int? {
        guard case .folder(let id) = shelf, let group = store.library.folder(id), group.goal > 0 else { return nil }
        return folderWordCount(for: id)
    }

    func toggleListFilter() {
        if layout == .focus { layout = .manuscripts }
        showListFilter.toggle()
        if !showListFilter {
            query = ""
            reconcileSearch()
        }
    }

    func chooseShelf(_ value: Shelf) {
        shelf = value
        query = ""
        showListFilter = false
        setPrimary(items.first?.id)
    }

    func choose(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let primaryID,
           let start = items.firstIndex(where: { $0.id == primaryID }),
           let end = items.firstIndex(where: { $0.id == id }) {
            selected = Set(items[min(start, end)...max(start, end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selected.remove(id) != nil {
                if primaryID == id { primaryID = items.first { selected.contains($0.id) }?.id }
            } else {
                selected.insert(id)
                primaryID = id
                pushHistory(id)
            }
        } else {
            setPrimary(id)
        }
    }

    func reconcileSearch() {
        let visible = Set(items.map(\.id))
        selected.formIntersection(visible)
        if let primaryID, visible.contains(primaryID) { return }
        setPrimary(items.first?.id)
    }

    private func setPrimary(_ id: UUID?, record: Bool = true) {
        primaryID = id
        selected = id.map { [$0] } ?? []
        if let id, record { pushHistory(id) }
    }

    private func pushHistory(_ id: UUID) {
        if history.indices.contains(historyPosition), history[historyPosition] == id { return }
        history = Array(history.prefix(historyPosition + 1))
        history.append(id)
        if history.count > 128 { history.removeFirst() }
        historyPosition = history.count - 1
    }

    func go(_ offset: Int) {
        guard let position = validHistoryIndex(offset: offset) else { return }
        historyPosition = position
        reveal(history[position], record: false)
    }

    func reveal(_ id: UUID, record: Bool = true) {
        guard let draft = store.draft(id) else { return }
        if !items.contains(where: { $0.id == id }) {
            shelf = draft.deleted != nil ? .trash : (draft.folderID.map(Shelf.folder) ?? .all)
            query = ""
            showListFilter = false
        }
        setPrimary(id, record: record)
    }

    func addDraft(material: Bool = false, initialTitle: String = "") {
        let target = folder
        let initialText = initialTitle.isEmpty ? "" : "# \(initialTitle)\n\n"
        let id = store.addDraft(folder: target, text: initialText, material: material)
        switch shelf {
        case .trash, .favorites, .filter:
            shelf = target.map(Shelf.folder) ?? .inbox
        default: break
        }
        query = ""
        showListFilter = false
        preview = false
        setPrimary(id)
        editor.focus(id, atEnd: !initialText.isEmpty)
    }

    func move(_ id: UUID, folder: UUID?) {
        store.move(id, to: folder)
        reveal(id)
    }

    func move(_ ids: Set<UUID>, folder: UUID?) {
        guard !ids.isEmpty else { return }
        if ids.count == 1, let single = ids.first {
            move(single, folder: folder)
            return
        }
        store.move(ids, to: folder)
        reconcileSearch()
    }

    func setFavorite(_ ids: Set<UUID>, _ value: Bool) {
        store.setFavorite(ids, value)
        reconcileSearch()
    }

    func setMaterial(_ ids: Set<UUID>, _ value: Bool) {
        store.setMaterial(ids, value)
    }

    func trash(_ ids: Set<UUID>) {
        store.trash(ids)
        reconcileSearch()
    }

    func restore(_ ids: Set<UUID>) {
        store.restore(ids)
        reconcileSearch()
    }

    func purge(_ ids: Set<UUID>) {
        guard !ids.isEmpty, confirm("永久删除文稿？", details: "将永久删除所选的 \(ids.count) 篇文稿。", action: "永久删除") else { return }
        store.purge(ids)
        reconcileSearch()
    }

    func removeFolder(_ group: Folder) {
        guard confirm("删除「\(group.name)」？", details: "这个分组和下级分组将被移除，文稿会进入废纸篓。", action: "删除分组") else { return }
        store.removeFolder(group.id)
        chooseShelf(.all)
    }

    func split() {
        guard let draft = current, let at = editor.splitIndex(for: draft), let id = store.split(draft.id, at: at) else {
            error = "将光标放在正文中要拆分的位置。"
            return
        }
        reveal(id)
        editor.focus(id)
    }

    func merge() {
        let visible = items.filter { selected.contains($0.id) }
        guard visible.count > 1,
              confirm("合并 \(visible.count) 篇文稿？", details: "按列表顺序合并到第一篇，其余文稿移入废纸篓。", action: "合并") else { return }
        if let first = store.merge(visible.map(\.id)) { reveal(first) }
    }

    func format(_ markup: Markup) {
        guard let id = primaryID, !preview else { return }
        editor.format(markup, in: id)
    }

    func openEquation() {
        guard let draft = current, draft.deleted == nil, !preview,
              let edit = editor.equationEdit(in: draft) else { return }
        dialog = .equation(edit)
    }

    func insertBlock(_ text: String) {
        guard let id = primaryID, !preview else { return }
        editor.insertBlock(text, in: id)
    }

    func insertEquation(_ source: String, display: Bool, edit: EquationEdit) {
        guard let draft = store.draft(edit.draftID), draft.text == edit.original, draft.deleted == nil,
              editor.insertEquation(source, display: display, edit: edit) else {
            dialog = nil
            error = "文稿内容已变化。请重新选择方程的插入位置。"
            return
        }
        closeDialog(focusing: edit.draftID)
    }

    func closeDialog(focusing id: UUID? = nil) {
        focusAfterDialog = id
        dialog = nil
    }

    func finishDialog() {
        guard let id = focusAfterDialog else { return }
        focusAfterDialog = nil
        if primaryID == id, !preview { editor.focus(id) }
    }

    func findInDraft(replacing: Bool = false) {
        guard let id = primaryID, !preview else { return }
        editor.focus(id)
        let sender = NSMenuItem()
        sender.tag = (replacing ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        editor.view?.performTextFinderAction(sender)
    }

    func prepareExport(_ requested: [Draft]? = nil) {
        let values = requested ?? items.filter { selected.contains($0.id) }
        let active = values.filter { !$0.material && $0.deleted == nil }
        guard !active.isEmpty else { error = "请选择至少一篇可导出的文稿。素材与废纸篓中的文稿会被排除。"; return }
        dialog = .export(active)
    }

    func export(_ items: [Draft], format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = filename(items.first?.name ?? "文稿") + "." + format.ext
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileTransfer.export(items, as: format, to: url)
            dialog = nil
        } catch {
            dialog = nil
            self.error = error.localizedDescription
        }
    }

    func copyMarkdown(_ requested: [Draft]? = nil) {
        let list = requested ?? items.filter { selected.contains($0.id) }
        guard !list.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(FileTransfer.markdown(list), forType: .string)
    }

    func printDraft() {
        guard let current, current.deleted == nil, !current.material else { return }
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 475, height: 600))
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.textStorage?.setAttributedString(Manuscript.attributed([current]))
        let operation = NSPrintOperation(view: text)
        operation.jobTitle = current.name
        operation.run()
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        panel.message = "选择 Markdown、纯文本、Word、RTF、HTML、TextBundle 或包含文稿的文件夹。"
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func importURLs(_ urls: [URL]) {
        perform {
            let batch = try FileTransfer.importFiles(urls, into: folder)
            store.applyImport(batch)
            if let id = batch.drafts.first?.id { reveal(id) }
        }
    }

    func addAttachment(to id: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加附件"
        guard panel.runModal() == .OK else { return }
        addAttachmentURLs(panel.urls, to: id)
    }

    func addAttachmentURLs(_ urls: [URL], to id: UUID) {
        perform {
            let attachments = try urls.map(FileTransfer.attachment)
            guard !attachments.isEmpty else { return }
            store.edit(id) { $0.attachments.append(contentsOf: attachments) }
        }
    }

    func attachImage(data: Data, name: String, into id: UUID) {
        guard data.count <= 25_000_000 else { error = LibraryError.largeAttachment.localizedDescription; return }
        let item = Attachment(name: name, data: data)
        store.edit(id) { $0.attachments.append(item) }
        insertImage(item, into: id)
    }

    func saveAttachment(_ item: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(item.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try item.data.write(to: url, options: .atomic) }
    }

    func insertImage(_ item: Attachment, into id: UUID) {
        let title = item.name.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "[", with: "")
        editor.insertBlock("![\(title)](\(item.reference))", in: id)
    }

    func snapshot() {
        guard let draft = current, draft.deleted == nil else { return }
        store.snapshot(draft.id)
        dashboardTab = .history
        setInspector(true)
    }

    func restoreRevision(_ revision: Revision, in draft: Draft) {
        guard confirm("恢复此版本？", details: "当前正文将保存为一个新版本。", action: "恢复") else { return }
        store.revert(draft.id, to: revision)
    }

    func deleteRevision(_ revision: Revision, in draft: Draft) {
        store.deleteRevision(revision.id, in: draft.id)
    }

    func backup() {
        store.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MiMi文库备份.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try store.exportBackup(to: url) }
    }

    func reopenSavedFolder() async {
        if await store.reopenSavedFolder() { selectOpenedLibrary(usePreferences: true) }
    }

    func reconcileFolderSelection() {
        guard shelf.exists(in: store.library) else { chooseShelf(.all); return }
        reconcileSearch()
    }

    private func selectOpenedLibrary(usePreferences: Bool) {
        store.cancelEditorStatistics()
        let savedShelf = usePreferences ? preferences?.string(forKey: "lastShelf").flatMap(Shelf.init(savedValue:)) : nil
        let saved = usePreferences ? preferences?.string(forKey: "lastDraft").flatMap(UUID.init(uuidString:)) : nil
        let requested = savedShelf.flatMap { $0.exists(in: store.library) ? $0 : nil }
        history = []
        historyPosition = -1
        chooseShelf(requested ?? (store.library.folders.first(where: \.project).map { Shelf.folder($0.id) } ?? .all))
        if let saved, items.contains(where: { $0.id == saved }) { setPrimary(saved) }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "选择文件夹"
        panel.message = "选择已有的 MiMi 文库文件夹，或选择一个空文件夹创建文库。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(.open(VaultAccess(url)))
    }

    func createFolder() {
        chooseDestination(title: "新建 MiMi 文库", name: "MiMi文库", source: nil)
    }

    func migrateFolder() {
        chooseDestination(title: "迁移原有 MiMi 文库", name: "MiMi文库", source: store.file)
    }

    private func chooseDestination(title: String, name: String, source: URL?) {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "创建文库"
        panel.message = "为文库文件夹命名，并选择本机或 iCloud Drive 中的保存位置。"
        panel.nameFieldStringValue = name
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(.create(url, parent: VaultAccess(url.deletingLastPathComponent()), source: source))
    }

    private func open(_ action: LibraryStore.FolderAction) {
        Task {
            do {
                let previous = store.folderURL
                try await store.selectFolder(action)
                if previous != store.folderURL { selectOpenedLibrary(usePreferences: false) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "选择备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if store.usesFolder {
            chooseDestination(title: "将备份恢复为新文库", name: "MiMi文库（恢复）", source: url)
        } else if confirm("恢复文库备份？", details: "这会备份当前文库并打开所选备份。", action: "恢复文库") {
            perform {
                try store.restoreBackup(from: url)
                selectOpenedLibrary(usePreferences: false)
            }
        }
    }

    func confirm(_ title: String, details: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }

    private func filename(_ value: String) -> String {
        let cleaned = String(value.components(separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters))
            .joined(separator: "_").drop(while: { $0 == "." }).prefix(120))
        return cleaned.isEmpty ? "文稿" : cleaned
    }
}

struct InkPalette: Equatable {
    var dark: Bool
    var theme: EditorTheme = .paper

    private func color(_ paperLight: UInt32, _ paperDark: UInt32, _ pineLight: UInt32, _ pineDark: UInt32) -> Color {
        Color(nsColor: ns(paperLight, paperDark, pineLight, pineDark))
    }

    private func ns(_ paperLight: UInt32, _ paperDark: UInt32, _ pineLight: UInt32, _ pineDark: UInt32) -> NSColor {
        let hex: UInt32
        switch (theme, dark) {
        case (.paper, false): hex = paperLight
        case (.paper, true): hex = paperDark
        case (.pine, false): hex = pineLight
        case (.pine, true): hex = pineDark
        }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                       green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    var rail: Color { color(0xf3f6fa, 0x1e1f22, 0x22382f, 0x16261f) }
    var railText: Color { color(0x1d1d1f, 0xf2f2f7, 0xf2efe0, 0xeae7d1) }
    var railIcon: Color { color(0x2c2c2e, 0xe5e5ea, 0xdce4d0, 0xcad6be) }
    var railMuted: Color { color(0x86868b, 0x8e8e93, 0xa8b8a0, 0x99ab94) }
    var railActive: Color { color(0x0a7aff, 0x2382f7, 0x355041, 0x2a4033) }
    var railHover: Color { color(0xe8ecf2, 0x292b30, 0x2c4538, 0x21352a) }
    var railLine: Color { color(0xe2e6ec, 0x32343a, 0x385042, 0x2a3d31) }

    var paper: Color { color(0xffffff, 0x18191b, 0xfdfaf2, 0x21251f) }
    var folios: Color { color(0xffffff, 0x18191b, 0xf4f1e6, 0x262b23) }
    var inspector: Color { color(0xfafafc, 0x1c1d20, 0xf7f4ea, 0x262b23) }
    var panel: Color { color(0xf2f3f6, 0x25262a, 0xfaf7ec, 0x2e352b) }
    var hover: Color { color(0xf3f4f7, 0x242529, 0xebe8da, 0x2f362c) }
    var selected: Color { color(0xdcdce0, 0x2e3036, 0xe2e9d6, 0x364431) }
    var line: Color { color(0xeaeaee, 0x2c2d31, 0xe2ddc9, 0x3a4236) }

    var glassFill: Color {
        if theme == .pine { return panel }
        return dark ? Color(white: 0.21, opacity: 0.90) : Color.white.opacity(0.95)
    }
    var glassHoverFill: Color {
        if theme == .pine { return hover }
        return dark ? Color(white: 0.26, opacity: 0.95) : Color(white: 0.965, opacity: 1.0)
    }
    var glassBorder: Color {
        if theme == .pine { return line }
        return dark ? Color.white.opacity(0.14) : Color.black.opacity(0.065)
    }
    var glassShadow: Color {
        dark ? Color.black.opacity(0.36) : Color.black.opacity(0.085)
    }

    var ink: Color { Color(nsColor: inkNS) }
    var muted: Color { Color(nsColor: mutedNS) }
    var leaf: Color { Color(nsColor: leafNS) }
    var accent: Color { Color(nsColor: accentNS) }
    var paperNS: NSColor { ns(0xffffff, 0x18191b, 0xfdfaf2, 0x21251f) }
    var inkNS: NSColor { ns(0x1d1d1f, 0xebebf0, 0x292d25, 0xeae6d5) }
    var mutedNS: NSColor { ns(0x86868b, 0x8e8e93, 0x6a6e62, 0xaab09d) }
    var leafNS: NSColor { ns(0x0a7aff, 0x3a94ff, 0x34553f, 0xbcd4a4) }
    var accentNS: NSColor { ns(0xd07a3b, 0xe69c63, 0x925239, 0xd6a07f) }
    var codeBgNS: NSColor { ns(0xf5f6f8, 0x232528, 0xf3f0e4, 0x292f26) }
}
