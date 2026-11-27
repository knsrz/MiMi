import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct InkfolioApp: App {
    @StateObject private var store: LibraryStore
    @StateObject private var model: WorkspaceModel
    @StateObject private var updater = AppUpdater()
    @AppStorage("appearance") private var appearance = "system"
    @NSApplicationDelegateAdaptor(InkfolioDelegate.self) private var delegate

    init() {
        let override = ProcessInfo.processInfo.environment["INKFOLIO_LIBRARY"].map { URL(fileURLWithPath: $0) }
        let store = override.map { LibraryStore(file: $0) } ?? LibraryStore()
        _store = StateObject(wrappedValue: store)
        _model = StateObject(wrappedValue: WorkspaceModel(store: store, preferences: override == nil ? .standard : nil))
    }

    private var scheme: ColorScheme? {
        if appearance == "dark" { return .dark }
        if appearance == "light" { return .light }
        return nil
    }

    private var minimumWorkspaceWidth: CGFloat {
        guard !store.needsFolder else { return WorkspaceSizing.windowFloor }
        return model.paneSizing.minimumWindowWidth
    }

    var body: some Scene {
        Window("MiMi", id: "workspace") {
            Group {
                if store.needsFolder {
                    FolderSetupView()
                } else {
                    WorkspaceView()
                        .disabled(store.openingFolder)
                }
            }
            .environmentObject(model)
            .environmentObject(store)
            .preferredColorScheme(scheme)
            .frame(minWidth: minimumWorkspaceWidth, minHeight: 460)
            .onAppear { delegate.store = store }
            .task { await model.reopenSavedFolder() }
            .onOpenURL { url in
                if !store.needsFolder { model.importURLs([url]) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in store.saveSoon() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.queueRefresh() }
            .alert("MiMi", isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .defaultSize(width: 1300, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            InkCommands(model: model, store: store)
            CommandGroup(after: .appInfo) {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            InkSettings(updater: updater, store: store, model: model).preferredColorScheme(scheme)
        }
    }
}

final class InkfolioDelegate: NSObject, NSApplicationDelegate {
    weak var store: LibraryStore?
    private var confirmingQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !store.openingFolder, !confirmingQuit else { return .terminateCancel }
        confirmingQuit = true
        defer { confirmingQuit = false }
        guard !store.flush() else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "文库还有未保存的修改"
        let reason = store.saveError ?? "当前文库无法保存。"
        alert.informativeText = "\(reason)\n可以将当前文库保存为 JSON 副本。直接退出可能丢失尚未写入磁盘的修改。"
        alert.addButton(withTitle: "继续打开 MiMi")
        alert.addButton(withTitle: "保存副本并退出…")
        alert.addButton(withTitle: "直接退出").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return saveRecoveryBackup(store) ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    @MainActor
    private func saveRecoveryBackup(_ store: LibraryStore) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MiMi文库恢复.json"
        panel.prompt = "保存并退出"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try store.exportBackup(to: url, recoveringUnsavedChanges: true)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法保存文库副本"
            alert.runModal()
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) { store?.stopWatchingFolder() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct InkCommands: Commands {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: LibraryStore
    @AppStorage("fontSize") private var fontSize = 19.0

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建文稿") { model.addDraft() }.keyboardShortcut("n")
            Button("新建素材") { model.addDraft(material: true) }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("新建分组…") { model.dialog = .folder(parent: model.folder, project: false, editing: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("新建项目…") { model.dialog = .folder(parent: nil, project: true, editing: nil) }
            Button("新建智能筛选…") { model.dialog = .filter(folder: model.folder, editing: nil) }
            Divider()
            Button("快速打开…") { model.dialog = .search }.keyboardShortcut("o")
            Button("导入文件或文件夹…") { model.importWithPanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            if store.usesFolder {
                Button("新建文库…") { model.createFolder() }.disabled(store.openingFolder)
                Button("打开文库文件夹…") { model.openFolder() }.disabled(store.openingFolder)
                if store.canMigrate {
                    Button("迁移原有文库…") { model.migrateFolder() }.disabled(store.openingFolder)
                }
                Button("在 Finder 中显示文库") {
                    if let url = store.folderURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.disabled(store.folderURL == nil)
                Divider()
            }
            Button("保存文库") { store.flush() }.keyboardShortcut("s").disabled(store.needsFolder || store.openingFolder)
            Button("导出…") { model.prepareExport() }.keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.current == nil)
            Button("备份文库…") { model.backup() }.disabled(store.needsFolder || store.openingFolder)
            Button("恢复文库…") { model.restoreBackup() }.disabled(store.openingFolder)
        }
        CommandGroup(replacing: .printItem) {
            Button("打印…") { model.printDraft() }.keyboardShortcut("p")
                .disabled(model.current?.material != false || model.current?.deleted != nil)
        }
        CommandGroup(after: .textEditing) {
            Button("在正文中查找…") { model.findInDraft() }.keyboardShortcut("f").disabled(model.current == nil || model.preview)
            Button("在正文中替换…") { model.findInDraft(replacing: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model.current == nil || model.current?.deleted != nil || model.preview)
            Button("筛选文稿列表") { model.toggleListFilter() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("插入") {
            Group {
                Button("方程…") { model.openEquation() }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                Button("表格") { model.insertBlock("| 列一 | 列二 |\n| --- | --- |\n|  |  |") }
                Button("分隔线") { model.insertBlock("---") }
            }.disabled(model.current == nil || model.current?.deleted != nil || model.preview)
        }
        CommandMenu("写作") {
            Button("保存正文版本") { model.snapshot() }.keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.current == nil || model.current?.deleted != nil)
            Button("在光标处拆分文稿") { model.split() }.disabled(model.current == nil || model.preview || model.current?.deleted != nil)
            Button("合并所选文稿") { model.merge() }.disabled(model.selected.count < 2 || model.shelf == .trash)
            Button("复制为 Markdown") { model.copyMarkdown() }.disabled(model.current == nil)
            Divider()
            ForEach(Markup.allCases) { markup in
                formatButton(markup)
            }
        }
        CommandGroup(after: .toolbar) {
            ForEach(WorkspaceLayout.allCases, id: \.self) { layout in
                Button(layout.label) { model.layout = layout }.keyboardShortcut(layout.shortcut)
            }
            Divider()
            Button("上一篇浏览过的文稿") { model.go(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Button("下一篇浏览过的文稿") { model.go(1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
            Divider()
            Button("放大正文字号") { fontSize = min(32, fontSize + 1) }.keyboardShortcut("+", modifiers: .command)
            Button("缩小正文字号") { fontSize = max(13, fontSize - 1) }.keyboardShortcut("-", modifiers: .command)
            Button("重置正文字号") { fontSize = 19 }.keyboardShortcut("0", modifiers: .command)
            Divider()
            Button(model.showsInspector ? "隐藏概览与检查器" : "显示概览与检查器") {
                model.setInspector(!model.showsInspector)
            }.keyboardShortcut("4")
            Picker("编辑与预览", selection: $model.previewMode) {
                ForEach(PreviewMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
            }
            .disabled(model.current == nil)
            Button(model.previewMode == .live ? "关闭实时预览" : "实时预览") {
                model.previewMode = model.previewMode == .live ? .writing : .live
            }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.current == nil)
        }
    }

    @ViewBuilder private func formatButton(_ markup: Markup) -> some View {
        let button = Button(markup.label) { model.format(markup) }
            .disabled(model.current == nil || model.current?.deleted != nil || model.preview)
        switch markup {
        case .strong: button.keyboardShortcut("b")
        case .emphasis: button.keyboardShortcut("i")
        case .highlight: button.keyboardShortcut("h", modifiers: [.command, .shift])
        case .strike: button.keyboardShortcut("x", modifiers: [.command, .shift])
        case .heading: button.keyboardShortcut("\\", modifiers: .command)
        case .quote: button.keyboardShortcut("'", modifiers: .command)
        case .bullet: button.keyboardShortcut("l", modifiers: .command)
        case .task: button.keyboardShortcut("l", modifiers: [.command, .shift])
        case .link: button.keyboardShortcut("k")
        case .code: button.keyboardShortcut("c", modifiers: [.command, .control])
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.colorScheme) private var scheme
    @AppStorage("editorTheme") private var themeRaw = EditorTheme.paper.rawValue
    @State private var resizedPane: WorkspacePane?

    private var palette: InkPalette {
        InkPalette(dark: scheme == .dark, theme: EditorTheme(rawValue: themeRaw) ?? .paper)
    }

    var body: some View {
        GeometryReader { geometry in
            let sizing = model.paneSizing
            let width = geometry.size.width
            let panes = sizing.widths(in: width, preferred: model.preferredPaneWidths, priority: resizedPane)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if model.layout == .library {
                        LibraryRail(palette: palette, compact: panes[.library] < 174)
                            .frame(width: panes[.library])
                            .clipped()
                    }
                    if model.layout != .focus {
                        DraftBrowser(palette: palette, compact: panes[.browser] < 250)
                            .frame(width: panes[.browser])
                            .clipped()
                    }
                    WritingCanvas(palette: palette, editorBridge: model.editor,
                                  compact: panes.editor < (model.layout == .focus ? 420 : 328))
                        .frame(width: panes.editor)
                        .frame(maxHeight: .infinity)
                        .clipped()
                    if model.showsInspector, let draft = model.current {
                        InspectorView(draft: draft, palette: palette, editorBridge: model.editor,
                                      compact: panes[.inspector] < 228)
                            .id(draft.id)
                            .frame(width: panes[.inspector])
                            .clipped()
                    }
                }

                if panes[.library] > 0 {
                    divider(.library, at: panes[.library], width: width, height: geometry.size.height, panes: panes)
                }
                if panes[.browser] > 0 {
                    divider(.browser, at: panes[.library] + panes[.browser], width: width, height: geometry.size.height, panes: panes)
                }
                if panes[.inspector] > 0 {
                    divider(.inspector, at: width - panes[.inspector], width: width, height: geometry.size.height, panes: panes)
                }
            }
        }
        .background(palette.paper)
        .background(WindowChromeObserver { fullScreen in
            if model.isFullScreen != fullScreen { model.isFullScreen = fullScreen }
        })
        .foregroundStyle(palette.ink)
        .tint(palette.leaf)
        .ignoresSafeArea(edges: .top)
        .onAppear {
            if let id = model.primaryID { DispatchQueue.main.async { model.editor.focus(id) } }
        }
        .sheet(item: $model.dialog, onDismiss: model.finishDialog) { dialog in
            WorkspaceSheet(dialog: dialog, palette: palette)
                .environmentObject(model)
                .environmentObject(store)
        }
        .onChange(of: store.library.folders.map(\.id)) { _, _ in model.reconcileFolderSelection() }
        .onChange(of: store.library.drafts.map(\.id)) { _, _ in model.reconcileFolderSelection() }
    }
    private func divider(_ pane: WorkspacePane, at boundary: CGFloat, width: CGFloat, height: CGFloat,
                         panes: WorkspaceSizing.Widths) -> some View {
        let showLine = pane != .library || palette.theme != .paper
        return PaneDivider(pane: pane, width: panes[pane], range: model.paneSizing.dragRange(for: pane, in: width),
                           color: showLine ? NSColor(palette.line) : .clear, highlight: palette.leafNS) { preferred in
            resizedPane = pane
            model.setPaneWidth(preferred, for: pane)
        }
        .frame(width: PaneDivider.hitWidth, height: height)
        .offset(x: boundary - PaneDivider.hitWidth / 2)
        .zIndex(2)
    }

}

struct FolderSetupView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder").font(.system(size: 36, weight: .light))
            Text("选择 MiMi 文库").font(.title2)
            Text("文稿保存在你选择的文件夹中。选择 iCloud Drive 文件夹即可在设备间同步。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if store.openingFolder {
                ProgressView().controlSize(.small)
            } else {
                HStack {
                    Button("打开文库文件夹…") { model.openFolder() }
                    if store.canMigrate {
                        Button("迁移原有文库…") { model.migrateFolder() }.buttonStyle(.borderedProminent)
                        Button("新建文库…") { model.createFolder() }
                    } else {
                        Button("新建文库…") { model.createFolder() }.buttonStyle(.borderedProminent)
                    }
                }
                if let error = store.saveError {
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PaneDivider: NSViewRepresentable {
    static let hitWidth: CGFloat = 18

    let pane: WorkspacePane
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    let color: NSColor
    let highlight: NSColor
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> Handle { Handle(self) }

    func updateNSView(_ view: Handle, context: Context) {
        view.owner = self
        view.needsDisplay = true
    }

    final class Handle: NSView {
        var owner: PaneDivider
        private var tracking: NSTrackingArea?
        private var start: (x: CGFloat, width: CGFloat)?

        init(_ owner: PaneDivider) {
            self.owner = owner
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.splitter)
            setAccessibilityLabel(owner.pane.accessibilityLabel)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
            needsDisplay = true
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

        override func mouseEntered(with event: NSEvent) {
            needsDisplay = true
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                owner.onResize(owner.pane.defaultWidth)
                return
            }
            start = (event.locationInWindow.x, owner.width)
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let movement = event.locationInWindow.x - start.x
            let delta = owner.pane == .inspector ? -movement : movement
            let width = (start.width + delta).rounded()
            owner.onResize(min(owner.range.upperBound, max(owner.range.lowerBound, width)))
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let pointerInside = window.map {
                $0.isKeyWindow && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
            } ?? false
            let active = start != nil || pointerInside
            let thickness: CGFloat = active ? 1.5 : 0.5
            (active ? owner.highlight.withAlphaComponent(0.65) : owner.color).setFill()
            NSRect(x: bounds.midX - thickness / 2, y: bounds.minY, width: thickness, height: bounds.height).fill()
        }
    }
}

private struct WindowChromeObserver: NSViewRepresentable {
    var onFullScreenChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFullScreenChange: onFullScreenChange) }

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onAttach = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFullScreenChange = onFullScreenChange
    }

    final class ObserverView: NSView {
        var onAttach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onAttach?(window)
        }
    }

    final class Coordinator: NSObject {
        var onFullScreenChange: (Bool) -> Void
        private weak var observedWindow: NSWindow?

        init(onFullScreenChange: @escaping (Bool) -> Void) {
            self.onFullScreenChange = onFullScreenChange
        }

        func attach(to window: NSWindow?) {
            if observedWindow === window { return }
            NotificationCenter.default.removeObserver(self)
            observedWindow = window
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            let current = window.styleMask.contains(.fullScreen)
            DispatchQueue.main.async { [weak self] in self?.onFullScreenChange(current) }
            NotificationCenter.default.addObserver(self, selector: #selector(willEnter), name: NSWindow.willEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(didExit), name: NSWindow.didExitFullScreenNotification, object: window)
        }

        @objc private func willEnter() { DispatchQueue.main.async { [weak self] in self?.onFullScreenChange(true) } }
        @objc private func didExit() { DispatchQueue.main.async { [weak self] in self?.onFullScreenChange(false) } }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct FrostedSidebarBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat = 15

    final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}

struct GlassPillStyle: ViewModifier {
    let palette: InkPalette
    var active = false
    var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(active ? palette.leaf.opacity(palette.dark ? 0.24 : 0.12)
                          : (hovering ? palette.glassHoverFill : palette.glassFill))
                    .shadow(color: palette.glassShadow.opacity(0.65), radius: 2, x: 0, y: 1)
                    .shadow(color: palette.glassShadow, radius: 8, x: 0, y: 3)
            }
            .overlay {
                Capsule()
                    .strokeBorder(active ? palette.leaf.opacity(0.35) : palette.glassBorder, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct CircleActionIcon: View {
    let title: String
    let symbol: String
    let palette: InkPalette
    let active: Bool
    let size: CGFloat
    var action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, palette: InkPalette, active: Bool = false, size: CGFloat = 36, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.palette = palette
        self.active = active
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .frame(width: size, height: size)
                .modifier(GlassPillStyle(palette: palette, active: active, hovering: hovering))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? palette.leaf : palette.ink.opacity(hovering ? 1.0 : 0.82))
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
        .help(title)
    }
}

struct ActionIcon: View {
    let title: String
    let symbol: String
    let palette: InkPalette
    var active = false
    var compact = false
    var action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, palette: InkPalette, active: Bool = false, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.palette = palette
        self.active = active
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 11.5 : 13.5, weight: .regular))
                .frame(width: compact ? 24 : 28, height: 28)
                .background(active ? palette.selected : (hovering ? palette.hover : Color.clear),
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? palette.leaf : (hovering ? palette.ink : palette.muted))
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
        .help(title)
    }
}

struct InkSettings: View {
    @ObservedObject var updater: AppUpdater
    @ObservedObject var store: LibraryStore
    let model: WorkspaceModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("editorTheme") private var editorTheme = EditorTheme.paper.rawValue
    @AppStorage("font") private var font = EditorFont.system.rawValue
    @AppStorage("fontSize") private var size = 19.0
    @AppStorage("typewriter") private var legacyTypewriter = false
    @AppStorage("fixedScroll") private var fixedScroll = ""
    @AppStorage("markCurrentLine") private var markCurrentLine = false
    @AppStorage("editorLineSpacing") private var lineSpacing = EditorSpacing.regular.line
    @AppStorage("editorParagraphSpacing") private var paragraphSpacing = EditorSpacing.regular.paragraph
    @AppStorage("editorIndent") private var indent = 0.0
    @AppStorage("editorWidth") private var editorWidth = 620.0
    @AppStorage("spelling") private var spelling = false
    @State private var choosingFont = false
    @State private var libraryError: String?

    var body: some View {
        Form {
            if store.usesFolder {
                Section("文库") {
                    LabeledContent("当前文库") {
                        if let url = store.folderURL {
                            Text((url.path as NSString).abbreviatingWithTildeInPath)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(url.path)
                        } else {
                            Text("尚未选择")
                        }
                    }
                    if store.openingFolder {
                        ProgressView("正在打开文库…").controlSize(.small)
                    } else {
                        Button("选择文库文件夹…") {
                            model.openFolder { libraryError = $0 }
                        }
                    }
                }
            }
            Section("外观与风格") {
                Picker("明暗模式", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Picker("界面风格", selection: $editorTheme) {
                    ForEach(EditorTheme.allCases) { theme in Text(theme.label).tag(theme.rawValue) }
                }
            }
            Section("编辑器字体") {
                Picker("字体", selection: $font) {
                    ForEach(EditorFont.presets, id: \.self) { face in Text(face.label).tag(face.rawValue) }
                    if let face = EditorFont(rawValue: font), !face.isPreset {
                        Text(face.label).tag(font)
                    }
                }
                Button("选择字体…") { choosingFont = true }
                Stepper("正文字号 \(Int(size)) pt", value: $size, in: 13...32)
                Stepper("正文最大宽度 \(Int(editorWidth)) pt", value: $editorWidth, in: 460...920, step: 20)
                Toggle("边键入边检查拼写", isOn: $spelling)
            }
            Section("正文排版") {
                Stepper("行距 \(Int(lineSpacing)) pt", value: $lineSpacing, in: 0...20)
                Stepper("段距 \(Int(paragraphSpacing)) pt", value: $paragraphSpacing, in: 0...28)
                Button("恢复默认行距和段距", action: resetSpacing)
                Stepper("首行缩进 \(Int(indent)) pt", value: $indent, in: 0...48, step: 2)
                Button("恢复默认清爽排版") {
                    font = EditorFont.system.rawValue
                    size = 19
                    editorWidth = 620
                    resetSpacing()
                    indent = 0
                }
            }
            Section("打字机模式") {
                Picker("固定滚动", selection: Binding(
                    get: { FixedScroll.resolve(fixedScroll, legacy: legacyTypewriter) },
                    set: { fixedScroll = $0.rawValue }
                )) {
                    ForEach(FixedScroll.allCases, id: \.self) { position in Text(position.label).tag(position) }
                }
                Toggle("标记当前行", isOn: $markCurrentLine)
            }
            Section("软件更新") {
                LabeledContent("当前版本", value: updater.version)
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Text("手动检查新版本，确认后下载、安装并重新启动 MiMi。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("查看版本与更新说明", destination: URL(string: "https://github.com/knsrz/MiMi/releases")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 760)
        .alert("无法打开文库", isPresented: Binding(
            get: { libraryError != nil },
            set: { if !$0 { libraryError = nil } }
        )) {
            Button("好", role: .cancel) { libraryError = nil }
        } message: { Text(libraryError ?? "") }
        .sheet(isPresented: $choosingFont) {
            EditorFontPicker(current: EditorFont(rawValue: font) ?? .system) { selection in
                font = selection.rawValue
            }
        }
    }

    private func resetSpacing() {
        lineSpacing = EditorSpacing.regular.line
        paragraphSpacing = EditorSpacing.regular.paragraph
    }
}

private struct EditorFontPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: EditorFont?
    @State private var entries: [Entry] = []
    @State private var importing = false
    @State private var error: String?
    let onChoose: (EditorFont) -> Void

    private struct Entry: Identifiable {
        let font: EditorFont
        let name: String
        let postScriptName: String
        var id: EditorFont { font }

        init(_ font: EditorFont) {
            self.font = font
            name = font.label
            postScriptName = font.font(size: 12).fontName
        }
    }

    init(current: EditorFont, onChoose: @escaping (EditorFont) -> Void) {
        _selection = State(initialValue: current.isPreset ? nil : current)
        self.onChoose = onChoose
    }

    private var visible: [Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedStandardContains(query) || $0.postScriptName.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择字体").font(.headline)
            TextField("搜索字体", text: $search)
                .textFieldStyle(.roundedBorder)
            List(visible, selection: $selection) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    if case .imported = entry.font {
                        Text("已导入").foregroundStyle(.secondary)
                    }
                }
                .tag(entry.font)
            }
            .overlay {
                if visible.isEmpty { Text("没有匹配的字体").foregroundStyle(.secondary) }
            }
            if let selection {
                Text("春风又绿江南岸 · AaBb 123")
                    .font(Font(selection.font(size: 22)))
                    .lineLimit(1)
                    .padding(.vertical, 4)
                    .accessibilityLabel("字体预览")
            }
            HStack {
                Button("从文件导入…", action: importFont)
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用字体") {
                    if let selection { choose(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .disabled(importing)
        }
        .padding(18)
        .interactiveDismissDisabled(importing)
        .frame(width: 440, height: 410)
        .onAppear {
            let installed = NSFontManager.shared.availableFonts
                .filter { !$0.hasPrefix(".") }
                .map(EditorFont.installed)
            entries = (EditorFontLibrary.shared.importedFonts() + installed)
                .map(Entry.init)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        .alert("无法导入字体", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func importFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = EditorFontLibrary.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "导入并使用"
        panel.message = "选择 TTF 或 OTF 字体文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let font = try await Task.detached(priority: .userInitiated) {
                    try EditorFontLibrary.shared.importFont(from: url)
                }.value
                choose(font)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func choose(_ font: EditorFont) {
        onChoose(font)
        dismiss()
    }
}
