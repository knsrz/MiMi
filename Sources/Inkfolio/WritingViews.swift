import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WritingCanvas: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var editorBridge: EditorBridge
    @AppStorage("font") private var font = EditorFont.system.rawValue
    @AppStorage("fontSize") private var size = 19.0
    @AppStorage("editorWidth") private var editorWidth = 620.0
    @AppStorage("typewriter") private var legacyTypewriter = false
    @AppStorage("fixedScroll") private var fixedScroll = ""
    @AppStorage("markCurrentLine") private var markCurrentLine = false
    @AppStorage("showCounter") private var showCounter = true
    @AppStorage("editorLineSpacing") private var lineSpacing = EditorSpacing.regular.line
    @AppStorage("editorParagraphSpacing") private var paragraphSpacing = EditorSpacing.regular.paragraph
    @AppStorage("editorIndent") private var indent = 0.0
    @AppStorage("spelling") private var spelling = false
    @State private var statisticsOpen = false
    @State private var hoveringTopBar = false
    let palette: InkPalette
    let compact: Bool

    init(palette: InkPalette, editorBridge: EditorBridge, compact: Bool) {
        self.palette = palette
        self.compact = compact
        self._editorBridge = ObservedObject(wrappedValue: editorBridge)
    }

    private var scrollBinding: Binding<FixedScroll> {
        Binding(get: { FixedScroll.resolve(fixedScroll, legacy: legacyTypewriter) },
                set: { fixedScroll = $0.rawValue })
    }

    private var toolbarOpacity: Double {
        if model.layout == .focus && model.zenFaded && !hoveringTopBar { return 0.0 }
        return 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            canvasToolbar
                .opacity(toolbarOpacity)
                .animation(.easeInOut(duration: 0.25), value: toolbarOpacity)
                .background(palette.paper)
                .onHover { inside in
                    hoveringTopBar = inside
                    if inside { model.zenFaded = false }
                }

            if let draft = model.current {
                draftCanvas(draft)
            } else {
                emptyCanvas
            }
        }
        .background(palette.paper)
    }

    private var emptyCanvas: some View {
        VStack(spacing: 16) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(palette.muted.opacity(0.65))
            Text("选择一篇文稿，或开始新的写作")
                .font(.system(size: 14.5))
                .foregroundStyle(palette.muted)
            Button("新建文稿") { model.addDraft() }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.leaf)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canvasToolbar: some View {
        let buttonSize: CGFloat = compact ? 32 : 36
        return HStack(spacing: compact ? 7 : 10) {
            if model.layout == .focus {
                if !model.isFullScreen {
                    Spacer().frame(width: 68)
                }
                CircleActionIcon("显示文稿列表 ⌘2", symbol: "sidebar.left", palette: palette, size: buttonSize) {
                    model.layout = .manuscripts
                }
            }

            if !compact {
                HStack(spacing: 0) {
                    Button { model.go(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(model.canGoBack ? palette.ink.opacity(0.85) : palette.muted.opacity(0.38))
                            .frame(width: 37, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canGoBack)
                    .help("上一篇浏览过的文稿 ⌘[")
                    .accessibilityLabel("上一篇浏览过的文稿")

                    palette.line.frame(width: 0.5, height: 16)

                    Button { model.go(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(model.canGoForward ? palette.ink.opacity(0.85) : palette.muted.opacity(0.38))
                            .frame(width: 37, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canGoForward)
                    .help("下一篇浏览过的文稿 ⌘]")
                    .accessibilityLabel("下一篇浏览过的文稿")
                }
                .modifier(GlassPillStyle(palette: palette))

            }

            if !compact, model.layout == .focus, let draft = model.current, !draft.isBlank {
                Text(draft.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .padding(.leading, 6)
            }

            Spacer(minLength: 8)

            CircleActionIcon("导出 ⇧⌘P", symbol: "square.and.arrow.up", palette: palette, size: buttonSize) {
                model.prepareExport()
            }
            .disabled(model.current == nil)
            .opacity(model.current == nil ? 0.38 : 1)

            CircleActionIcon("快速打开 ⌘O", symbol: "magnifyingglass", palette: palette, size: buttonSize) {
                model.dialog = .search
            }

            Menu {
                if compact {
                    Button("上一篇浏览过的文稿") { model.go(-1) }.disabled(!model.canGoBack)
                    Button("下一篇浏览过的文稿") { model.go(1) }.disabled(!model.canGoForward)
                    Divider()
                }
                Section("布局与视图") {
                    ForEach(WorkspaceLayout.allCases, id: \.self) { layout in
                        Button { model.layout = layout } label: { Label(layout.label, systemImage: layout.symbol) }
                    }
                    Picker("编辑与预览", selection: $model.previewMode) {
                        ForEach(PreviewMode.allCases, id: \.self) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .disabled(model.current == nil)
                }
                Divider()
                Section("编辑选项") {
                    Toggle("显示字数统计", isOn: $showCounter)
                    Toggle("标记当前行", isOn: $markCurrentLine)
                    Picker("固定滚动", selection: scrollBinding) {
                        ForEach(FixedScroll.allCases, id: \.self) { position in Text(position.label).tag(position) }
                    }
                }
                if let draft = model.current {
                    if draft.deleted == nil, !model.preview {
                        Divider()
                        Button { model.openEquation() } label: { Label("插入或编辑方程…", systemImage: "function") }
                        Menu("格式") {
                            ForEach(Markup.allCases) { markup in
                                Button { model.format(markup) } label: { Label(markup.label, systemImage: markup.symbol) }
                            }
                        }
                        Menu("插入") {
                            Button("表格") { model.insertBlock("| 列一 | 列二 |\n| --- | --- |\n|  |  |") }
                            Button("分隔线") { model.insertBlock("---") }
                        }
                    }
                    Divider()
                    DraftActions(draft: draft)
                }
            } label: {
                Image(systemName: model.previewMode == .writing ? "ellipsis" : model.previewMode.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(model.previewMode == .writing ? palette.ink.opacity(0.82) : palette.leaf)
                    .frame(width: buttonSize, height: buttonSize)
                    .modifier(GlassPillStyle(palette: palette, active: model.previewMode != .writing))
                    .contentShape(Circle())
                    .accessibilityLabel("更多与视图选项")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(model.previewMode == .writing ? palette.ink.opacity(0.82) : palette.leaf)
            .help("预览、方程、格式与视图选项")

            CircleActionIcon("概览与检查器 ⌘4", symbol: "sidebar.right", palette: palette, active: model.showsInspector, size: buttonSize) {
                model.setInspector(!model.showsInspector)
            }
        }
        .padding(.horizontal, compact ? 12 : 18)
        .frame(height: 56)
    }

    private func draftCanvas(_ draft: Draft) -> some View {
        VStack(spacing: 0) {
            if draft.deleted != nil {
                HStack(spacing: 12) {
                    Label(compact ? "废纸篓（只读）" : "此文稿在废纸篓中（只读）", systemImage: "trash")
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                    Spacer()
                    Button { model.restore([draft.id]) } label: {
                        if compact {
                            Image(systemName: "arrow.uturn.backward").accessibilityLabel("恢复文稿")
                        } else {
                            Text("恢复文稿")
                        }
                    }
                    .help("恢复文稿")
                    .buttonStyle(.plain).foregroundStyle(palette.leaf)
                    Button { model.purge([draft.id]) } label: {
                        if compact {
                            Image(systemName: "trash").accessibilityLabel("永久删除")
                        } else {
                            Text("永久删除…")
                        }
                    }
                    .help("永久删除")
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(palette.panel)
                palette.line.frame(height: 0.5)
            }

            ZStack(alignment: .topTrailing) {
                GeometryReader { geometry in
                    let stacked = model.previewMode == .live && geometry.size.width < 580
                    let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                    layout {
                        editor(draft)
                        if model.previewMode == .live {
                            palette.line.frame(width: stacked ? nil : 0.5, height: stacked ? 0.5 : nil)
                            LiveDraftPreview(draft: draft, compact: true, dark: palette.dark)
                        }
                    }
                }
                .opacity(model.preview ? 0 : 1)
                .allowsHitTesting(!model.preview)
                .accessibilityHidden(model.preview)

                if model.preview {
                    LiveDraftPreview(draft: draft, compact: false, dark: palette.dark)
                }

                if showCounter || draft.material || store.statusMessage != nil || store.conflictCopies[draft.id] != nil {
                    topRightStatus(draft)
                }
            }
        }
        .onChange(of: model.previewMode) { old, mode in
            if old == .reading && mode != .reading { model.editor.focus(draft.id) }
        }
    }

    private func editor(_ draft: Draft) -> some View {
        let side: Double = compact ? 20 : (model.previewMode == .live ? 28 : (model.layout == .focus ? 64 : 44))
        let top: Double = showCounter ? 48 : 34
        return InkTextEditor(
            draftID: draft.id,
            text: draft.text,
            palette: palette,
            font: EditorFont(rawValue: font) ?? .system,
            size: size,
            maxWidth: editorWidth,
            horizontalPadding: side,
            topPadding: top,
            fixedScroll: FixedScroll.resolve(fixedScroll, legacy: legacyTypewriter),
            spacing: EditorSpacing(line: lineSpacing, paragraph: paragraphSpacing, indent: indent),
            markLine: markCurrentLine,
            spelling: spelling,
            editable: draft.deleted == nil,
            bridge: model.editor,
            onChange: { text in store.edit(draft.id) { $0.text = text } },
            onAttachImage: { data, name in model.attachImage(data: data, name: name, into: draft.id) },
            onTypingActivity: {
                if model.layout == .focus && !model.zenFaded {
                    model.zenFaded = true
                }
            }
        )
        .id(draft.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func topRightStatus(_ draft: Draft) -> some View {
        let count = store.analysis(of: draft).count
        let selWords = editorBridge.selectionWords
        let goalRatio: Double? = draft.goal > 0 ? Double(count.words) / Double(draft.goal) : nil
        let dimmed = model.layout == .focus && model.zenFaded && !statisticsOpen

        return HStack(spacing: 10) {
            if let error = store.statusMessage {
                Button { model.error = error } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .help(error)
                .accessibilityLabel("自动保存状态")
            }

            if let copies = store.conflictCopies[draft.id], !copies.isEmpty {
                Menu {
                    ForEach(copies, id: \.self) { id in
                        if let copy = store.draft(id) {
                            Button(copy.name) { model.reveal(id) }
                        }
                    }
                } label: {
                    Label("同步冲突", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .medium))
                }
                .fixedSize()
                .help("此文稿的不同改动已另存为副本")
            }

            if draft.material {
                Text("素材")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(palette.panel, in: Capsule())
            }

            if showCounter {
                Button {
                    statisticsOpen.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if let goalRatio {
                            GoalRing(progress: goalRatio,
                                     tint: goalRatio >= 1 ? palette.accent : palette.leaf,
                                     track: palette.line,
                                     lineWidth: 1.8)
                                .frame(width: 13, height: 13)
                        }
                        if selWords > 0 {
                            Text("已选 \(selWords.formatted()) / \(count.words.formatted()) 字")
                                .monospacedDigit()
                        } else if draft.goal > 0 {
                            Text("\(count.words.formatted()) / \(draft.goal.formatted()) 字")
                                .monospacedDigit()
                        } else {
                            Text("\(count.words.formatted()) 字")
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(statisticsOpen ? palette.leaf : palette.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(statisticsOpen ? palette.panel : palette.paper.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("文稿统计")
                .accessibilityLabel("文稿统计 \(count.words.formatted()) 字")
                .popover(isPresented: $statisticsOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 8) {
                            if selWords > 0 {
                                GridRow {
                                    Text("选中字词").foregroundStyle(palette.leaf)
                                    Text(selWords.formatted()).monospacedDigit().foregroundStyle(palette.leaf)
                                }
                            }
                            GridRow { Text("字词数"); Text(count.words.formatted()).monospacedDigit() }
                            GridRow { Text("字符（不含空白）"); Text(count.characters.formatted()).monospacedDigit() }
                            GridRow { Text("字符（含空格）"); Text(count.charactersWithSpaces.formatted()).monospacedDigit() }
                            GridRow { Text("段落"); Text(count.paragraphs.formatted()).monospacedDigit() }
                            GridRow { Text("句子"); Text(count.sentences.formatted()).monospacedDigit() }
                            GridRow { Text("阅读时间"); Text("约 \(count.readingMinutes) 分钟") }
                            GridRow { Text("朗读时间"); Text("约 \(count.speakingMinutes) 分钟") }
                        }
                        .font(.system(size: 13))
                        Divider()
                        HStack {
                            if draft.goal > 0 {
                                Text("目标 \(draft.goal.formatted()) 字（\(Int(min(999, (Double(count.words) / Double(draft.goal) * 100).rounded())))%）")
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.muted)
                            } else {
                                Text("尚未设定目标").font(.system(size: 12)).foregroundStyle(palette.muted)
                            }
                            Spacer()
                            Button(draft.goal > 0 ? "调整目标" : "设定目标") {
                                statisticsOpen = false
                                model.dashboardTab = .overview
                                model.setInspector(true)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.leaf)
                        }
                    }
                    .padding(16)
                    .frame(minWidth: 250)
                }
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 24)
        .opacity(dimmed ? 0.25 : 1)
        .animation(.easeInOut(duration: 0.25), value: dimmed)
    }
}

struct LiveDraftPreview: View {
    let draft: Draft
    let compact: Bool
    let dark: Bool
    @State private var fragment: String?
    @State private var renderedID: UUID?

    private struct Content: Equatable {
        var id: UUID
        var text: String
        var title: String
        var attachments: [Attachment]
    }

    var body: some View {
        let theme = dark ? "dark" : "light"
        let insets = compact ? "body { margin-top: 2.2rem; padding-inline: 1.6rem; }" : ""
        let document = Manuscript.htmlDocument(title: "实时预览", body: "", appearance: theme, extraStyle: insets)
        let request = Content(id: draft.id, text: draft.text, title: draft.title, attachments: draft.attachments)
        WebPreview(html: document, liveBody: renderedID == draft.id ? fragment : nil)
            .id(draft.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: request) {
                if renderedID == draft.id {
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                }
                let render = Task.detached(priority: .userInitiated) { Manuscript.previewBody([draft]) }
                let body = await render.value
                guard !Task.isCancelled else { return }
                fragment = body
                renderedID = draft.id
            }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var editorBridge: EditorBridge
    let draft: Draft
    let palette: InkPalette
    let compact: Bool
    @State private var tag = ""
    @State private var goalText = ""
    @State private var showGoal = false
    @State private var hoveredHeading: Int?
    @State private var dropAttachmentTargeted = false

    init(draft: Draft, palette: InkPalette, editorBridge: EditorBridge, compact: Bool) {
        self.draft = draft
        self.palette = palette
        self.compact = compact
        self._editorBridge = ObservedObject(wrappedValue: editorBridge)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            palette.line.frame(height: 0.5)
            ScrollView {
                Group {
                    switch model.dashboardTab {
                    case .overview: overviewTab
                    case .outline: outlineTab
                    case .annotations: annotationsTab
                    case .history: historyTab
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .frame(maxHeight: .infinity)
        .background(palette.inspector)
        .disabled(draft.deleted != nil)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(DashboardTab.allCases) { tab in
                let active = model.dashboardTab == tab
                let hasDot = (tab == .annotations && (!draft.note.isEmpty || !draft.attachments.isEmpty || !draft.tags.isEmpty))
                    || (tab == .history && !draft.revisions.isEmpty)
                Button {
                    model.dashboardTab = tab
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15.5, weight: active ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .foregroundStyle(active ? palette.leaf : palette.ink.opacity(0.68))
                            .background(active ? palette.leaf.opacity(palette.dark ? 0.22 : 0.12) : Color.clear,
                                        in: Capsule())
                            .contentShape(Rectangle())
                        if hasDot && !active {
                            Circle()
                                .fill(palette.leaf.opacity(0.85))
                                .frame(width: 5, height: 5)
                                .offset(x: -7, y: 4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(tab.label)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .modifier(GlassPillStyle(palette: palette))
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        let count = store.analysis(of: draft).count
        let ratio = draft.goal > 0 ? Double(count.words) / Double(draft.goal) : 0

        return VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 10) {
                Button { editGoal() } label: {
                    ZStack {
                        if draft.goal > 0 {
                            GoalRing(progress: ratio,
                                     tint: ratio >= 1 ? palette.accent : palette.leaf,
                                     track: palette.line,
                                     lineWidth: 6.5)
                                .frame(width: 102, height: 102)
                            VStack(spacing: 3) {
                                Text("\(Int(min(999, (ratio * 100).rounded())))%")
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(ratio >= 1 ? palette.accent : palette.ink)
                                Text("\(count.words.formatted()) / \(draft.goal.formatted())")
                                    .font(.system(size: 11.5))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.muted)
                            }
                        } else {
                            Circle()
                                .stroke(palette.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                                .frame(width: 96, height: 96)
                            VStack(spacing: 4) {
                                Image(systemName: "scope")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundStyle(palette.leaf)
                                Text("设定目标")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(palette.leaf)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(draft.goal > 0 ? "点击调整写作目标" : "设定写作目标")
                .popover(isPresented: $showGoal, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("目标字数").font(.system(size: 14, weight: .semibold))
                        TextField("例如 1000", text: $goalText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitGoal)
                        HStack {
                            Button("移除") { store.edit(draft.id) { $0.goal = 0 }; showGoal = false }
                                .disabled(draft.goal == 0)
                            Spacer()
                            Button("保存", action: commitGoal)
                                .keyboardShortcut(.defaultAction)
                                .disabled(parsedGoal == nil)
                        }
                    }
                    .padding(14)
                    .frame(width: 210)
                }

                if draft.goal > 0 {
                    let remaining = max(0, draft.goal - count.words)
                    Text(remaining == 0 ? "已达成写作目标" : "距离目标还差 \(remaining.formatted()) 字")
                        .font(.system(size: 12))
                        .foregroundStyle(remaining == 0 ? palette.accent : palette.muted)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(palette.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("统计")
                VStack(spacing: 8) {
                    statRow("字词数", value: count.words.formatted())
                    statRow("字符（不含空白）", value: count.characters.formatted())
                    statRow("字符（含空格）", value: count.charactersWithSpaces.formatted())
                    statRow("段落", value: count.paragraphs.formatted())
                    statRow("句子", value: count.sentences.formatted())
                    statRow("预计阅读", value: "\(count.readingMinutes) 分钟")
                    statRow("预计朗读", value: "\(count.speakingMinutes) 分钟")
                }
            }

            palette.line.frame(height: 0.5)

            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("文稿属性")
                HStack(spacing: 5) {
                    ForEach(DraftStage.allCases, id: \.self) { stage in
                        let selected = draft.stage == stage
                        Button {
                            store.edit(draft.id) { $0.stage = stage }
                            model.reconcileSearch()
                        } label: {
                            HStack(spacing: 4) {
                                if !compact { Image(systemName: stage.symbol).font(.system(size: 10.5)) }
                                Text(stage.label)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .foregroundStyle(selected ? palette.leaf : palette.muted)
                            .background(selected ? palette.selected : palette.panel, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Toggle("添加到收藏", isOn: Binding(
                    get: { draft.favorite },
                    set: { value in
                        store.edit(draft.id) { $0.favorite = value }
                        model.reconcileSearch()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 13))

                Toggle("标记为素材（导出时排除）", isOn: Binding(
                    get: { draft.material },
                    set: { value in store.edit(draft.id) { $0.material = value } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            }

            palette.line.frame(height: 0.5)

            VStack(alignment: .leading, spacing: 7) {
                statRow("创建于", value: draft.created.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))
                statRow("修改于", value: draft.modified.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))
            }
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(palette.muted)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(palette.ink)
        }
        .font(.system(size: 13))
    }

    // MARK: - Outline Tab

    private var outlineTab: some View {
        let headings = store.analysis(of: draft).headings
        let activeLocation = headings.last { $0.location <= editorBridge.caretLocation }?.location

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("文稿大纲")
            if headings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(palette.muted.opacity(0.6))
                    Text("使用 # 添加标题后，大纲将自动显示在此处。")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(headings) { heading in
                        let isActive = heading.location == activeLocation
                        let isHovered = hoveredHeading == heading.location
                        Button {
                            if model.preview {
                                model.preview = false
                                DispatchQueue.main.async { model.editor.jump(to: heading.location, in: draft.id) }
                            } else {
                                model.editor.jump(to: heading.location, in: draft.id)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Text("H\(heading.level)")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(isActive ? palette.leaf : palette.muted.opacity(0.65))
                                    .frame(width: 20, alignment: .leading)
                                Text(heading.title)
                                    .font(.system(size: heading.level <= 2 ? 14 : 13.5,
                                                  weight: isActive || heading.level == 1 ? .semibold : .regular))
                                    .foregroundStyle(isActive ? palette.leaf : palette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10 + 8)
                            .padding(.trailing, 8)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isActive ? palette.selected : (isHovered ? palette.hover : Color.clear))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            hoveredHeading = inside ? heading.location : (hoveredHeading == heading.location ? nil : hoveredHeading)
                        }
                        .help("跳转到「\(heading.title)」")
                    }
                }
            }
        }
    }

    // MARK: - Annotations Tab

    private var annotationsTab: some View {
        let suggestions = store.library.allTags.filter { candidate in
            !draft.tags.contains { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame }
        }.prefix(8)

        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("关键词")
                if !draft.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(draft.tags, id: \.self) { value in
                            HStack(spacing: 5) {
                                Text(value).lineLimit(1)
                                Button {
                                    store.edit(draft.id) { $0.tags.removeAll { $0 == value } }
                                    model.reconcileSearch()
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除关键词 \(value)")
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(palette.leaf)
                            .padding(.horizontal, 10).padding(.vertical, 4.5)
                            .background(palette.selected, in: Capsule())
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("添加关键词…", text: $tag)
                        .textFieldStyle(.plain)
                        .onSubmit { addTag(tag) }
                        .font(.system(size: 13))
                    Button { addTag(tag) } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.leaf)
                    .accessibilityLabel("添加关键词")
                    .disabled(tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 0.75) }

                if !suggestions.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(suggestions), id: \.self) { value in
                            Button {
                                addTag(value)
                            } label: {
                                Text("+ \(value)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.muted)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(palette.panel, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            palette.line.frame(height: 0.5)

            VStack(alignment: .leading, spacing: 9) {
                sectionHeader("附注")
                ZStack(alignment: .topLeading) {
                    if draft.note.isEmpty {
                        Text("记录灵感、修改要点或资料来源…")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.muted.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(
                        get: { store.draft(draft.id)?.note ?? "" },
                        set: { value in store.edit(draft.id) { $0.note = value } }
                    ))
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                    .accessibilityLabel("附注")
                }
                .frame(minHeight: 165)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 0.75) }
            }

            palette.line.frame(height: 0.5)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    sectionHeader("附件")
                    Spacer()
                    Button { model.addAttachment(to: draft.id) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.leaf)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("添加附件")
                    .accessibilityLabel("添加附件")
                }

                VStack(alignment: .leading, spacing: 7) {
                    if draft.attachments.isEmpty {
                        Text("拖放文件到此处，或点击右上角添加附件。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(palette.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        ForEach(draft.attachments) { item in
                            attachmentRow(item)
                        }
                    }
                }
                .overlay {
                    if dropAttachmentTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(palette.leaf, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    model.addAttachmentURLs(urls, to: draft.id)
                    return !urls.isEmpty
                } isTargeted: { targeted in
                    dropAttachmentTargeted = targeted
                }
            }
        }
    }

    private func attachmentRow(_ item: Attachment) -> some View {
        let isImage = Manuscript.imageMIME(item) != nil
        return HStack(spacing: 9) {
            if isImage, let image = NSImage(data: item.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.muted)
                    .frame(width: 34, height: 34)
                    .background(palette.panel, in: RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 2)
            Menu {
                if isImage {
                    Button("插入到正文") { model.insertImage(item, into: draft.id) }.disabled(model.preview)
                }
                Button("另存附件…") { model.saveAttachment(item) }
                Divider()
                Button("移除附件", role: .destructive) {
                    if model.confirm("移除附件？", details: "保存的附件会从这篇文稿移除。", action: "移除") {
                        store.edit(draft.id) { $0.attachments.removeAll { $0.id == item.id } }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .accessibilityLabel("附件操作")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(palette.muted)
        }
        .padding(7)
        .background(palette.panel.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("版本历史")
                Spacer()
                Button { model.snapshot() } label: {
                    Label("保存版本", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.leaf)
                }
                .buttonStyle(.plain)
                .help("保存当前正文快照 ⌥⌘S")
            }

            if draft.revisions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(palette.muted.opacity(0.6))
                    Text("按 ⌥⌘S 或点击右上角随时保存当前正文的里程碑版本。")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(draft.revisions) { revision in
                        let words = WritingCount(revision.text).words
                        let snippet = Draft(title: revision.title, text: revision.text).excerpt
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(revision.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                    .font(.system(size: 13, weight: .semibold))
                                    .monospacedDigit()
                                Spacer()
                                Text("\(words.formatted()) 字")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.muted)
                            }
                            if !snippet.isEmpty {
                                Text(snippet)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(palette.muted)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 12) {
                                Button {
                                    model.restoreRevision(revision, in: draft)
                                } label: {
                                    Label("恢复", systemImage: "arrow.uturn.backward")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(palette.leaf)
                                Spacer()
                                Button {
                                    if model.confirm("删除此版本？", details: "此操作无法撤销。", action: "删除") {
                                        model.deleteRevision(revision, in: draft)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(palette.muted)
                                .help("删除此版本")
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.top, 2)
                        }
                        .padding(11)
                        .background(palette.panel.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.muted)
    }

    private var parsedGoal: Int? {
        guard let value = Int(goalText.trimmingCharacters(in: .whitespaces)), (1...10_000_000).contains(value) else { return nil }
        return value
    }

    private func editGoal() {
        goalText = draft.goal == 0 ? "" : String(draft.goal)
        showGoal = true
    }

    private func commitGoal() {
        guard let value = parsedGoal else { return }
        store.edit(draft.id) { $0.goal = value }
        showGoal = false
    }

    private func addTag(_ raw: String) {
        let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !value.isEmpty else { return }
        store.edit(draft.id) {
            if !$0.tags.contains(where: { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }) { $0.tags.append(value) }
        }
        tag = ""
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 220
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
