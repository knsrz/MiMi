import SwiftUI

struct GoalRing: View {
    var progress: Double
    var tint: Color
    var track: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct LibraryRail: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let palette: InkPalette
    let compact: Bool
    @State private var collapsed = Set<UUID>()
    @State private var hoveredShelf: Shelf?
    @State private var hoveredSection: String?
    @State private var hoveredHeaderButton: String?
    @State private var dropTargetShelf: Shelf?

    private struct Entry: Identifiable {
        var folder: Folder
        var depth: Int
        var id: UUID { folder.id }
    }

    private var floatingStyle: Bool { palette.theme == .paper }
    private let railCornerRadius: CGFloat = 15

    var body: some View {
        let content = VStack(spacing: 0) {
            railHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("笔记") {
                        railRow("全部", symbol: "tray.full", shelf: .all)
                        railRow("收藏", symbol: "star", shelf: .favorites, hideZero: true)
                        railRow("收件箱", symbol: "tray.and.arrow.down", shelf: .inbox)
                        railRow("最近七天", symbol: "clock", shelf: .recent, hideZero: true)
                        railRow("废纸篓", symbol: "trash", shelf: .trash, hideZero: true)
                            .contextMenu {
                                Button("清空废纸篓", role: .destructive) {
                                    model.purge(Set(store.library.matching(.trash).map(\.id)))
                                }.disabled(store.library.matching(.trash).isEmpty)
                            }
                    }

                    let groups = entries(projects: false)
                    section("分组", key: "groups") {
                        ForEach(groups) { entry in folderRow(entry) }
                    } action: {
                        model.dialog = .folder(parent: nil, project: false, editing: nil)
                    }

                    let projects = entries(projects: true)
                    section("项目", key: "projects") {
                        if projects.isEmpty {
                            Button {
                                model.dialog = .folder(parent: nil, project: true, editing: nil)
                            } label: {
                                Text("新建项目…")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(floatingStyle ? palette.leaf : palette.railText)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                                    .background(
                                        floatingStyle
                                            ? Color.primary.opacity(palette.dark ? 0.08 : 0.045)
                                            : palette.railActive.opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                            .padding(.horizontal, 4)
                        } else {
                            ForEach(projects) { entry in folderRow(entry) }
                        }
                    } action: {
                        model.dialog = .folder(parent: nil, project: true, editing: nil)
                    }

                    if !store.library.filters.isEmpty {
                        section("智能筛选", key: "filters") {
                            ForEach(store.library.filters) { filter in
                                railRow(filter.name, symbol: "line.3.horizontal.decrease.circle", shelf: .filter(filter.id))
                                    .contextMenu {
                                        Button("编辑智能筛选…") { model.dialog = .filter(folder: filter.folderID, editing: filter) }
                                        Button("删除筛选", role: .destructive) {
                                            store.deleteFilter(filter.id)
                                            if model.shelf == .filter(filter.id) { model.chooseShelf(.all) }
                                        }
                                    }
                            }
                        } action: {
                            model.dialog = .filter(folder: model.folder, editing: nil)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            railFooter
        }
        .frame(maxHeight: .infinity)
        .background {
            if floatingStyle && !reduceTransparency {
                FrostedSidebarBackdrop(cornerRadius: railCornerRadius)
                    .overlay(palette.paper.opacity(palette.dark ? 0.30 : 0.36))
                    .allowsHitTesting(false)
            } else {
                palette.rail
            }
        }
        .foregroundStyle(palette.railText)

        if floatingStyle {
            let shape = RoundedRectangle(cornerRadius: railCornerRadius, style: .continuous)
            content
                .clipShape(shape)
                .overlay {
                    shape
                        .strokeBorder(
                            palette.dark ? Color.white.opacity(0.09) : Color.black.opacity(0.055),
                            lineWidth: 0.5
                        )
                        .allowsHitTesting(false)
                }
                .padding(8)
                .background(palette.paper)
        } else {
            content
        }
    }

    private var railHeader: some View {
        let size: CGFloat = compact ? 28 : 32
        return HStack(spacing: compact ? 5 : 8) {
            Spacer()
            Menu {
                Button("新建分组…") { model.dialog = .folder(parent: model.folder, project: false, editing: nil) }
                Button("新建项目…") { model.dialog = .folder(parent: nil, project: true, editing: nil) }
                Button("新建智能筛选…") { model.dialog = .filter(folder: model.folder, editing: nil) }
                Divider()
                Button("新建文稿") { model.addDraft() }
                Button("新建素材") { model.addDraft(material: true) }
                Divider()
                Button("导入文件或文件夹…") { model.importWithPanel() }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.railIcon)
                    .frame(width: size, height: size)
                    .background(hoveredHeaderButton == "add" ? palette.railHover : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .accessibilityLabel("添加")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(palette.railIcon)
            .onHover { inside in hoveredHeaderButton = inside ? "add" : (hoveredHeaderButton == "add" ? nil : hoveredHeaderButton) }
            .help("新建分组、项目或导入")

            Button {
                model.layout = .manuscripts
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.railIcon)
                    .frame(width: size, height: size)
                    .background(hoveredHeaderButton == "sidebar" ? palette.railHover : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in hoveredHeaderButton = inside ? "sidebar" : (hoveredHeaderButton == "sidebar" ? nil : hoveredHeaderButton) }
            .help("隐藏文库侧栏 ⌘2")
            .accessibilityLabel("隐藏文库侧栏")
        }
        .padding(.horizontal, compact ? 7 : 10)
        .frame(height: floatingStyle ? 40 : 56)
    }

    private var railFooter: some View {
        HStack(spacing: 8) {
            if let error = store.statusMessage {
                Button { model.error = error } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accent)
                        Text("文库状态").font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .help(error)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.railMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("偏好设置 ⌘,")
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(height: 36)
    }

    private func section<Rows: View>(_ title: String, key: String? = nil, @ViewBuilder rows: () -> Rows, action: (() -> Void)? = nil) -> some View {
        let isHovered = key != nil && hoveredSection == key
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let action {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0.35)
                    .help("新建\(title)")
                    .accessibilityLabel("新建\(title)")
                }
            }
            .frame(minHeight: 20)
            .foregroundStyle(palette.railMuted)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            .onHover { inside in
                guard let key else { return }
                hoveredSection = inside ? key : (hoveredSection == key ? nil : hoveredSection)
            }
            rows()
        }
    }

    private func entries(projects: Bool) -> [Entry] {
        var result: [Entry] = []
        func visit(_ folder: Folder, depth: Int) {
            result.append(Entry(folder: folder, depth: depth))
            if !collapsed.contains(folder.id) {
                for child in store.library.folders where child.parentID == folder.id { visit(child, depth: depth + 1) }
            }
        }
        for root in store.library.folders where root.parentID == nil && root.project == projects { visit(root, depth: 0) }
        return result
    }

    private func iconColor(for symbol: String, custom: Bool) -> Color {
        guard floatingStyle, custom else { return palette.railIcon }
        switch symbol {
        case "pencil": return Color(nsColor: NSColor(srgbRed: 0.13, green: 0.66, blue: 0.78, alpha: 1))
        case "terminal": return Color(nsColor: NSColor(srgbRed: 0.16, green: 0.54, blue: 0.90, alpha: 1))
        case "sparkles": return Color(nsColor: NSColor(srgbRed: 0.18, green: 0.72, blue: 0.36, alpha: 1))
        case "lightbulb": return Color(nsColor: NSColor(srgbRed: 0.90, green: 0.58, blue: 0.14, alpha: 1))
        case "bookmark": return Color(nsColor: NSColor(srgbRed: 0.88, green: 0.36, blue: 0.28, alpha: 1))
        case "book.closed": return Color(nsColor: NSColor(srgbRed: 0.36, green: 0.35, blue: 0.82, alpha: 1))
        default: return palette.railIcon
        }
    }

    private func folderRow(_ entry: Entry) -> some View {
        let folder = entry.folder
        let hasChildren = store.library.folders.contains { $0.parentID == folder.id }
        let goalProgress: Double? = folder.goal > 0
            ? Double(model.folderWordCount(for: folder.id)) / Double(folder.goal)
            : nil
        let symbol = folder.icon ?? (folder.project ? "book.closed" : "doc.text")
        return railRow(folder.name,
                       symbol: symbol,
                       shelf: .folder(folder.id),
                       depth: entry.depth,
                       disclosure: hasChildren ? folder.id : nil,
                       goalProgress: goalProgress,
                       iconTint: iconColor(for: symbol, custom: folder.icon != nil || folder.project))
            .contextMenu {
                Button("新建子分组…") { model.dialog = .folder(parent: folder.id, project: false, editing: nil) }
                Button("新建组内筛选…") { model.dialog = .filter(folder: folder.id, editing: nil) }
                Button("编辑分组…") { model.dialog = .folder(parent: folder.parentID, project: folder.project, editing: folder) }
                Button("导出此分组…") { model.prepareExport(store.library.matching(.folder(folder.id))) }
                Divider()
                Button("删除分组…", role: .destructive) { model.removeFolder(folder) }
            }
    }

    private func railRow(_ title: String, symbol: String, shelf: Shelf, depth: Int = 0,
                         disclosure: UUID? = nil, hideZero: Bool = false, goalProgress: Double? = nil,
                         iconTint: Color? = nil) -> some View {
        let active = model.shelf == shelf
        let hovered = hoveredShelf == shelf
        let targeted = dropTargetShelf == shelf
        let count = store.library.count(for: shelf)
        let activeForeground: Color = floatingStyle ? .white : palette.railText
        let inactiveIcon = iconTint ?? palette.railIcon

        return HStack(spacing: 0) {
            if let disclosure {
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        if collapsed.remove(disclosure) == nil { collapsed.insert(disclosure) }
                    }
                } label: {
                    Image(systemName: collapsed.contains(disclosure) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 16, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(active ? activeForeground.opacity(0.85) : palette.railMuted)
                .accessibilityLabel(collapsed.contains(disclosure) ? "展开 \(title)" : "折叠 \(title)")
            } else if depth > 0 {
                Spacer().frame(width: 16)
            } else {
                Spacer().frame(width: 8)
            }
            Button { model.chooseShelf(shelf) } label: {
                HStack(spacing: compact ? 5 : 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 16.5, weight: .regular))
                        .foregroundStyle(active ? activeForeground : inactiveIcon)
                        .frame(width: compact ? 18 : 22)
                    Text(title)
                        .font(.system(size: 14, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? activeForeground : palette.railText)
                        .lineLimit(1)
                        .minimumScaleFactor(compact ? 0.85 : 1)
                        .layoutPriority(1)
                    Spacer(minLength: compact ? 3 : 6)
                    if let goalProgress {
                        GoalRing(progress: goalProgress,
                                 tint: active ? .white : (goalProgress >= 1 ? palette.accent : palette.leaf),
                                 track: active ? Color.white.opacity(0.32) : palette.railMuted.opacity(0.28),
                                 lineWidth: 2)
                            .frame(width: 13, height: 13)
                    }
                    if !hideZero || count > 0 {
                        Text("\(count)")
                            .font(.system(size: 12.5, weight: .regular))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(active ? activeForeground.opacity(0.9) : palette.railMuted)
                    }
                }
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
        }
        .padding(.leading, compact ? min(CGFloat(depth) * 8, 24) : CGFloat(depth) * 14)
        .padding(.trailing, compact ? 6 : 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? palette.railActive : (hovered ? palette.railHover : Color.clear))
        )
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.leaf, lineWidth: 1.5)
            }
        }
        .onHover { inside in
            hoveredShelf = inside ? shelf : (hoveredShelf == shelf ? nil : hoveredShelf)
        }
        .dropDestination(for: String.self) { values, _ in
            handleDrop(values, onto: shelf)
        } isTargeted: { inside in
            guard canAcceptDrop(on: shelf) else { return }
            dropTargetShelf = inside ? shelf : (dropTargetShelf == shelf ? nil : dropTargetShelf)
        }
    }

    private func canAcceptDrop(on shelf: Shelf) -> Bool {
        switch shelf {
        case .folder, .inbox, .favorites, .trash: true
        default: false
        }
    }

    private func handleDrop(_ values: [String], onto shelf: Shelf) -> Bool {
        let dragged = Set(values.flatMap { $0.split(separator: ",").compactMap { UUID(uuidString: String($0)) } })
        let valid = dragged.filter { store.draft($0)?.deleted == nil }
        guard !valid.isEmpty else { return false }
        switch shelf {
        case .folder(let id):
            store.move(valid, to: id)
            model.reconcileSearch()
            return true
        case .inbox:
            store.move(valid, to: nil)
            model.reconcileSearch()
            return true
        case .favorites:
            store.setFavorite(valid, true)
            return true
        case .trash:
            model.trash(valid)
            return true
        default:
            return false
        }
    }
}

struct DraftBrowser: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    let palette: InkPalette
    let compact: Bool
    @FocusState private var filterFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var hoveredDraft: UUID?
    @State private var dropBeforeDraft: UUID?
    @State private var dropAtEnd = false
    @State private var goalPopover = false
    @AppStorage("draftPreviewLines") private var previewLines = 3
    @AppStorage("showDraftDates") private var showDates = false

    private var showingFilterBar: Bool {
        model.showListFilter || !model.query.isEmpty
    }

    var body: some View {
        let items = model.items
        VStack(spacing: 0) {
            browserTopBar(items: items)
            shelfSubheader

            if let progress = model.folderWordCount, let group = store.library.folder(model.folder), group.goal > 0 {
                GeometryReader { geo in
                    let ratio = min(1, Double(progress) / Double(group.goal))
                    ZStack(alignment: .leading) {
                        palette.line
                        (ratio >= 1 ? palette.accent : palette.leaf)
                            .frame(width: max(2, geo.size.width * ratio))
                    }
                }
                .frame(height: 1.5)
                .padding(.horizontal, 14)
            } else {
                palette.line.frame(height: 0.5).padding(.horizontal, 14)
            }

            if showingFilterBar {
                filterBar
                palette.line.frame(height: 0.5).padding(.horizontal, 14)
            }

            if model.selected.count > 1 {
                multiSelectBar
                palette.line.frame(height: 0.5)
            }

            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { draft in
                                draftRow(draft, isLast: draft.id == items.last?.id).id(draft.id)
                            }
                            if model.sort == .manual, let last = items.last {
                                Color.clear
                                    .frame(height: 28)
                                    .overlay(alignment: .top) {
                                        if dropAtEnd {
                                            Capsule().fill(palette.leaf).frame(height: 2).padding(.horizontal, 12)
                                        }
                                    }
                                    .dropDestination(for: String.self) { values, _ in
                                        guard let candidate = firstDraggedID(values),
                                              candidate != last.id,
                                              store.draft(candidate)?.folderID == last.folderID,
                                              store.draft(candidate)?.deleted == last.deleted else { return false }
                                        store.reorder(candidate, after: last.id)
                                        return true
                                    } isTargeted: { targeted in
                                        dropAtEnd = targeted
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .accessibilityLabel("文稿列表")
                    .onKeyPress(.upArrow) { moveSelection(-1, items: items) }
                    .onKeyPress(.downArrow) { moveSelection(1, items: items) }
                    .onKeyPress(.return) {
                        if let id = model.primaryID { model.editor.focus(id) }
                        return .handled
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "\u{7f}\u{08}")) { press in
                        guard press.modifiers.contains(.command), !model.selected.isEmpty else { return .ignored }
                        if model.shelf == .trash {
                            model.purge(model.selected)
                        } else {
                            model.trash(model.selected)
                        }
                        return .handled
                    }
                    .onChange(of: model.primaryID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .background(palette.folios)
        .frame(maxHeight: .infinity)
        .onChange(of: model.showListFilter) { _, open in
            if open { DispatchQueue.main.async { filterFocused = true } }
        }
    }

    private func browserTopBar(items: [Draft]) -> some View {
        let buttonSize: CGFloat = compact ? 30 : 36
        return HStack(spacing: compact ? 4 : 8) {
            if model.layout == .manuscripts {
                if !model.isFullScreen {
                    Spacer().frame(width: 68)
                }
                CircleActionIcon("显示文库侧栏 ⌘1", symbol: "sidebar.left", palette: palette, size: buttonSize) {
                    model.layout = .library
                }
            }

            Spacer(minLength: 4)

            if model.shelf == .trash {
                if !items.isEmpty {
                    Button {
                        model.purge(Set(items.map(\.id)))
                    } label: {
                        if compact {
                            Image(systemName: "trash").accessibilityLabel("清空废纸篓")
                        } else {
                            Text("清空废纸篓")
                        }
                    }
                    .help("清空废纸篓")
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(palette.panel, in: Capsule())
                }
            } else {
                Menu {
                    Button {
                        model.toggleListFilter()
                    } label: {
                        Label(showingFilterBar ? "隐藏筛选栏" : "筛选当前列表…", systemImage: "magnifyingglass")
                    }
                    Divider()
                    Picker("排序方式", selection: $model.sort) {
                        ForEach(DraftSort.allCases, id: \.self) { sort in Text(sort.label).tag(sort) }
                    }
                    Picker("摘要行数", selection: $previewLines) {
                        Text("仅标题").tag(0)
                        ForEach(1...6, id: \.self) { Text("\($0) 行").tag($0) }
                    }
                    Toggle("显示编辑日期", isOn: $showDates)
                    Divider()
                    Button("导出当前列表…") { model.prepareExport(items) }
                        .disabled(!items.contains { !$0.material && $0.deleted == nil })
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(showingFilterBar ? palette.leaf : palette.ink.opacity(0.82))
                        .frame(width: buttonSize, height: buttonSize)
                        .modifier(GlassPillStyle(palette: palette, active: showingFilterBar))
                        .contentShape(Circle())
                        .accessibilityLabel("筛选与排序")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .tint(showingFilterBar ? palette.leaf : palette.ink.opacity(0.82))
                .help("筛选与排序选项")

                CircleActionIcon("新建文稿 ⌘N", symbol: "square.and.pencil", palette: palette, size: buttonSize) {
                    model.addDraft()
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .frame(height: 56)
    }

    private var shelfSubheader: some View {
        HStack(spacing: 8) {
            Text(model.shelfName)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 4)

            if let progress = model.folderWordCount, let group = store.library.folder(model.folder), group.goal > 0 {
                let ratio = Double(progress) / Double(group.goal)
                Button {
                    goalPopover.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if !compact {
                            Text("\(progress.formatted()) / \(group.goal.formatted())")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(palette.muted)
                        }
                        GoalRing(progress: ratio,
                                 tint: ratio >= 1 ? palette.accent : palette.leaf,
                                 track: palette.line,
                                 lineWidth: 2)
                            .frame(width: 14, height: 14)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("分组写作目标")
                .popover(isPresented: $goalPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            GoalRing(progress: ratio,
                                     tint: ratio >= 1 ? palette.accent : palette.leaf,
                                     track: palette.line,
                                     lineWidth: 4)
                                .frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("分组写作目标").font(.system(size: 12)).foregroundStyle(palette.muted)
                                Text("\(progress.formatted()) / \(group.goal.formatted()) 字")
                                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            }
                        }
                        HStack {
                            Text("已完成 \(Int(min(999, (ratio * 100).rounded())))%")
                                .font(.system(size: 12)).foregroundStyle(palette.muted)
                            Spacer()
                            Button("编辑目标…") {
                                goalPopover = false
                                model.dialog = .folder(parent: group.parentID, project: group.project, editing: group)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.leaf)
                        }
                    }
                    .padding(14)
                    .frame(width: 240)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.muted)
            TextField("筛选当前列表…", text: $model.query)
                .font(.system(size: 13.5))
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit { listFocused = true }
                .onKeyPress(.escape) {
                    model.query = ""
                    model.showListFilter = false
                    model.reconcileSearch()
                    return .handled
                }
                .onChange(of: model.query) { _, _ in model.reconcileSearch() }
            Button {
                model.query = ""
                model.showListFilter = false
                model.reconcileSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除筛选")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(palette.panel.opacity(0.65))
    }

    private var multiSelectBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(model.selected.count) 篇")
                .lineLimit(1)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.muted)
            Spacer()
            if model.shelf == .trash {
                Button("恢复") { model.restore(model.selected) }
                    .buttonStyle(.plain).foregroundStyle(palette.leaf)
                Button("删除") { model.purge(model.selected) }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
            } else {
                Button("合并") { model.merge() }
                    .buttonStyle(.plain).foregroundStyle(palette.leaf)
                Button("导出") { model.prepareExport() }
                    .buttonStyle(.plain).foregroundStyle(palette.leaf)
                Button("删除") { model.trash(model.selected) }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(palette.selected.opacity(0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.shelf == .trash ? "trash" : "doc.text")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(palette.muted.opacity(0.6))
            Text(model.query.isEmpty ? (model.shelf == .trash ? "废纸篓为空" : "暂无文稿") : "没有匹配的文稿")
                .font(.system(size: 14))
                .foregroundStyle(palette.muted)
            if model.query.isEmpty && model.shelf != .trash {
                Button("新建文稿") { model.addDraft() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(palette.leaf)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func moveSelection(_ direction: Int, items: [Draft]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == model.primaryID } ?? (direction < 0 ? items.count : -1)
        let next = max(0, min(items.count - 1, current + direction))
        model.choose(items[next].id, modifiers: [])
        return .handled
    }

    private func firstDraggedID(_ values: [String]) -> UUID? {
        values.first?.split(separator: ",").first.flatMap { UUID(uuidString: String($0)) }
    }

    private func dragPayload(for draft: Draft) -> String {
        if model.selected.contains(draft.id), model.selected.count > 1 {
            return model.selected.map(\.uuidString).joined(separator: ",")
        }
        return draft.id.uuidString
    }

    private func draftRow(_ draft: Draft, isLast: Bool) -> some View {
        let selected = model.selected.contains(draft.id)
        let hovered = hoveredDraft == draft.id
        let hasHeading = draft.hasExplicitHeading
        let summary = previewLines > 0 ? draft.excerpt : ""
        let hasMeta = draft.material || draft.stage != .draft || !draft.tags.isEmpty || draft.goal > 0 || showDates
        let cardMinHeight: CGFloat = previewLines == 0 ? 40 : CGFloat(28 + previewLines * 20)

        return VStack(alignment: .leading, spacing: 6) {
            if draft.isBlank {
                HStack {
                    Spacer(minLength: 0)
                    metaIcons(for: draft)
                }
            } else if hasHeading {
                HStack(spacing: 6) {
                    Text(draft.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    metaIcons(for: draft)
                }
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(selected ? palette.ink.opacity(0.78) : palette.muted)
                        .lineLimit(previewLines)
                        .lineSpacing(3.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Text(previewLines == 0 ? draft.name : draft.flowingPreview)
                        .font(.system(size: 14, weight: selected ? .medium : .regular))
                        .foregroundStyle(palette.ink)
                        .lineLimit(previewLines == 0 ? 1 : max(3, previewLines + 1))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metaIcons(for: draft)
                }
            }

            if hasMeta {
                HStack(spacing: 6) {
                    if draft.material {
                        Text("素材")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(selected ? palette.paper.opacity(0.6) : palette.panel, in: RoundedRectangle(cornerRadius: 4))
                    } else if draft.stage != .draft {
                        HStack(spacing: 3) {
                            Image(systemName: draft.stage.symbol).font(.system(size: 10))
                            Text(draft.stage.label)
                        }
                        .foregroundStyle(draft.stage == .ready ? palette.leaf : palette.accent)
                    }
                    ForEach(draft.tags.prefix(2), id: \.self) { value in
                        Text(value)
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(selected ? palette.paper.opacity(0.6) : palette.panel, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 2)
                    if draft.goal > 0 {
                        let words = store.analysis(of: draft).count.words
                        let ratio = Double(words) / Double(draft.goal)
                        GoalRing(progress: ratio,
                                 tint: ratio >= 1 ? palette.accent : palette.leaf,
                                 track: palette.line,
                                 lineWidth: 1.8)
                            .frame(width: 12, height: 12)
                    }
                    if showDates {
                        Text(draft.modified.formatted(.dateTime.month(.abbreviated).day()))
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.muted)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: cardMinHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? palette.selected : (hovered ? palette.hover : Color.clear))
        )
        .overlay(alignment: .top) {
            if dropBeforeDraft == draft.id {
                Capsule().fill(palette.leaf).frame(height: 2).padding(.horizontal, 6)
            }
        }
        .overlay(alignment: .bottom) {
            if !selected && !isLast {
                palette.line.opacity(0.8).frame(height: 0.5).padding(.horizontal, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 {
                model.choose(draft.id, modifiers: [])
                model.editor.focus(draft.id)
            } else {
                model.choose(draft.id, modifiers: NSEvent.modifierFlags)
                listFocused = true
            }
        }
        .onHover { inside in
            hoveredDraft = inside ? draft.id : (hoveredDraft == draft.id ? nil : hoveredDraft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .contextMenu { DraftActions(draft: draft) }
        .draggable(dragPayload(for: draft))
        .dropDestination(for: String.self) { values, _ in
            guard model.sort == .manual, let candidate = firstDraggedID(values),
                  candidate != draft.id,
                  store.draft(candidate)?.folderID == draft.folderID,
                  store.draft(candidate)?.deleted == draft.deleted else { return false }
            store.reorder(candidate, before: draft.id)
            return true
        } isTargeted: { targeted in
            guard model.sort == .manual else { return }
            dropBeforeDraft = targeted ? draft.id : (dropBeforeDraft == draft.id ? nil : dropBeforeDraft)
        }
    }

    @ViewBuilder
    private func metaIcons(for draft: Draft) -> some View {
        HStack(spacing: 4) {
            if !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted.opacity(0.8))
            }
            if !draft.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted.opacity(0.8))
            }
            if draft.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
            }
        }
    }
}

struct DraftActions: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    let draft: Draft

    var body: some View {
        let ids = model.selected.contains(draft.id) ? model.selected : [draft.id]
        if draft.deleted != nil {
            Button("恢复文稿") { model.restore(ids) }
            Button("永久删除…", role: .destructive) { model.purge(ids) }
        } else {
            if ids.count == 1 {
                Button("重命名…") { model.dialog = .rename(draft) }
            }
            Button(draft.favorite ? "从收藏中移除" : "添加到收藏") {
                model.setFavorite(ids, !draft.favorite)
            }
            Button(draft.material ? "转换为正文" : "标记为素材") {
                model.setMaterial(ids, !draft.material)
            }
            if ids.count == 1 {
                Button("制作副本") { if let id = store.duplicate(draft.id) { model.reveal(id) } }
            }
            Menu("移动到") {
                Button("收件箱") { model.move(ids, folder: nil) }
                ForEach(store.library.folders) { folder in
                    Button(store.library.path(to: folder.id).map(\.name).joined(separator: " / ")) {
                        model.move(ids, folder: folder.id)
                    }
                }
            }
            if ids.count > 1 { Button("合并所选文稿…") { model.merge() } }
            Divider()
            Button("导出…") { model.prepareExport(model.items.filter { ids.contains($0.id) }) }
            Button("复制为 Markdown") { model.copyMarkdown(model.items.filter { ids.contains($0.id) }) }
            Divider()
            Button("移到废纸篓", role: .destructive) { model.trash(ids) }
        }
    }
}
