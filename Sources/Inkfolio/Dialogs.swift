import AppKit
import SwiftUI

struct WorkspaceSheet: View {
    let dialog: WorkspaceDialog
    let palette: InkPalette

    var body: some View {
        switch dialog {
        case .search: QuickOpen(palette: palette)
        case .folder(let parent, let project, let editing):
            FolderForm(parent: parent, project: project, editing: editing)
        case .filter(let folder, let editing):
            FilterForm(folder: folder, editing: editing)
        case .export(let drafts):
            ExportSheet(drafts: drafts, palette: palette)
        case .equation(let edit):
            EquationSheet(edit: edit, palette: palette)
        case .rename(let draft):
            RenameSheet(draft: draft)
        }
    }
}

private struct RenameSheet: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    let draft: Draft
    @State private var name: String
    @FocusState private var editing: Bool

    init(draft: Draft) {
        self.draft = draft
        _name = State(initialValue: draft.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名文稿").font(.system(size: 16, weight: .semibold))
            TextField("留空时自动取自正文首行", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .onSubmit(save)
            HStack {
                if !draft.title.isEmpty {
                    Button("恢复自动命名") {
                        store.edit(draft.id) { $0.title = "" }
                        model.closeDialog(focusing: draft.id)
                    }
                }
                Spacer()
                Button("取消") { model.dialog = nil }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 385)
        .onAppear { editing = true }
    }

    private func save() {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        store.edit(draft.id) { $0.title = title }
        model.closeDialog(focusing: draft.id)
    }
}

private struct EquationSheet: View {
    @EnvironmentObject private var model: WorkspaceModel
    let edit: EquationEdit
    let palette: InkPalette
    @State private var source: String
    @State private var display: Bool
    @State private var rendered: MathTeX.Render?
    @FocusState private var editing: Bool

    private struct Request: Equatable {
        var source: String
        var display: Bool
    }

    private static let templates: [(label: String, snippet: String)] = [
        ("分数", #"\frac{a}{b}"#),
        ("根式", #"\sqrt{x}"#),
        ("求和", #"\sum_{i=1}^{n} x_i"#),
        ("积分", #"\int_{a}^{b} f(x)\,dx"#),
        ("对齐", "\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}")
    ]

    init(edit: EquationEdit, palette: InkPalette) {
        self.edit = edit
        self.palette = palette
        _source = State(initialValue: edit.source)
        _display = State(initialValue: edit.display)
    }

    private var previewShell: String {
        let displayStyle = "body{margin:0;padding:12px;max-width:none;min-height:98px;display:grid;place-items:center}math{font-size:1.22em}"
        return Manuscript.htmlDocument(title: "公式预览", body: "",
                                       appearance: palette.dark ? "dark" : "light", extraStyle: displayStyle)
    }

    var body: some View {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = Request(source: trimmed, display: display)
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("方程").font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("方程位置", selection: $display) {
                    Text("行内").tag(false)
                    Text("独立公式").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 158)
            }

            HStack(spacing: 6) {
                ForEach(Self.templates, id: \.label) { item in
                    Button(item.label) {
                        if source.isEmpty {
                            source = item.snippet
                        } else {
                            source += (source.hasSuffix(" ") || source.hasSuffix("\n") ? "" : " ") + item.snippet
                        }
                        if item.label == "对齐" { display = true }
                        editing = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                    .background(palette.panel, in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
            }

            ZStack(alignment: .topLeading) {
                if source.isEmpty {
                    Text(#"\frac{a}{b} = \sqrt{x}"#)
                        .font(.system(size: 13.5, design: .monospaced)).foregroundStyle(palette.muted.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 8).allowsHitTesting(false)
                }
                TextEditor(text: $source)
                    .focused($editing).font(.system(size: 13.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityLabel("LaTeX 源码")
            }
            .frame(height: 102)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line) }

            ZStack {
                WebPreview(html: previewShell, liveBody: rendered?.markup ?? "")
                    .opacity(rendered == nil ? 0 : 1)
                    .accessibilityLabel("公式预览")
                if rendered == nil {
                    Text("输入 LaTeX 实时预览").font(.system(size: 12)).foregroundStyle(palette.muted)
                }
            }
            .frame(height: 120)
            .background(palette.paper, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line) }

            if let error = rendered?.error {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.accent)
                    .lineLimit(3).accessibilityLabel("LaTeX 错误 \(error)")
            }

            HStack {
                Text("⌘↩ 插入").font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer()
                Button("取消") { model.closeDialog(focusing: edit.draftID) }.keyboardShortcut(.cancelAction)
                Button("完成") { model.insertEquation(trimmed, display: display, edit: edit) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { editing = true }
        .task(id: request) {
            if request.source.isEmpty { rendered = nil; return }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            let engine = Task.detached(priority: .userInitiated) { MathTeX.shared.render(request.source, display: request.display) }
            let result = await engine.value
            if !Task.isCancelled { rendered = result }
        }
    }
}

private struct QuickOpen: View {
    struct Result: Identifiable {
        enum Target: Hashable { case draft(UUID), shelf(Shelf), create(String) }
        var target: Target
        var name: String
        var subtitle: String
        var excerpt: String = ""
        var symbol: String
        var id: Target { target }
    }

    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    let palette: InkPalette
    @State private var search = ""
    @State private var cursor = 0
    @State private var hoveredIndex: Int?
    @FocusState private var focused: Bool

    private var results: [Result] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let drafts = store.library.matching(.all, query: keyword, sort: .modified).prefix(24)
        let matches = drafts.map { draft in
            let path = store.library.path(to: draft.folderID).map(\.name).joined(separator: " / ")
            return Result(target: .draft(draft.id), name: draft.name,
                          subtitle: path.isEmpty ? "收件箱" : path,
                          excerpt: draft.excerpt,
                          symbol: draft.material ? "paperclip" : "doc.text")
        }
        if keyword.isEmpty { return matches }
        let groups = store.library.folders.filter { $0.name.localizedStandardContains(keyword) }.prefix(10).map { folder in
            Result(target: .shelf(.folder(folder.id)), name: folder.name, subtitle: folder.project ? "项目" : "分组",
                   symbol: folder.project ? "book.closed" : "folder")
        }
        let filters = store.library.filters.filter { $0.name.localizedStandardContains(keyword) }.prefix(10).map { filter in
            Result(target: .shelf(.filter(filter.id)), name: filter.name, subtitle: "智能筛选", symbol: "line.3.horizontal.decrease.circle")
        }
        var combined = groups + filters + matches
        let exact = drafts.contains { $0.name.localizedCaseInsensitiveCompare(keyword) == .orderedSame }
        if !exact {
            combined.append(Result(target: .create(keyword), name: "新建文稿「\(keyword)」",
                                   subtitle: model.shelfName, symbol: "square.and.pencil"))
        }
        return combined
    }

    var body: some View {
        let entries = results
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(palette.leaf)
                TextField("搜索文稿、分组或输入标题新建…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onChange(of: search) { _, _ in cursor = 0 }
                    .onSubmit { if entries.indices.contains(cursor) { open(entries[cursor]) } }
                    .onKeyPress(.upArrow) { cursor = max(0, cursor - 1); return .handled }
                    .onKeyPress(.downArrow) { cursor = max(0, min(entries.count - 1, cursor + 1)); return .handled }
                ActionIcon("关闭快速打开", symbol: "xmark", palette: palette, compact: true) { model.dialog = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            palette.line.frame(height: 0.5)
            if entries.isEmpty {
                Text("没有匹配的项目或文稿").font(.system(size: 13)).foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                                let active = cursor == position
                                let hovered = hoveredIndex == position
                                Button {
                                    open(entry)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.symbol)
                                            .font(.system(size: 14.5))
                                            .frame(width: 20)
                                            .foregroundStyle(active ? palette.leaf : palette.muted)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.name)
                                                .font(.system(size: 14.5, weight: .medium))
                                                .lineLimit(1)
                                            if !entry.excerpt.isEmpty {
                                                Text(entry.excerpt)
                                                    .font(.system(size: 12.5))
                                                    .foregroundStyle(palette.muted)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        Text(entry.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(palette.muted)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, entry.excerpt.isEmpty ? 9 : 8)
                                    .background(active ? palette.selected : (hovered ? palette.hover : Color.clear),
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(position)
                                .onHover { inside in
                                    hoveredIndex = inside ? position : (hoveredIndex == position ? nil : hoveredIndex)
                                }
                                .accessibilityAddTraits(active ? .isSelected : [])
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: cursor) { _, index in proxy.scrollTo(index) }
                }
            }
        }
        .frame(width: 540, height: 390)
        .background(palette.paper)
        .foregroundStyle(palette.ink)
        .onAppear { focused = true }
    }

    private func open(_ result: Result) {
        switch result.target {
        case .draft(let id):
            model.reveal(id)
            model.closeDialog(focusing: id)
        case .shelf(let shelf):
            model.chooseShelf(shelf)
            model.closeDialog()
        case .create(let title):
            model.dialog = nil
            model.addDraft(initialTitle: title)
        }
    }
}

private struct FolderForm: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    let editing: Folder?
    @State private var name: String
    @State private var goal: String
    @State private var isProject: Bool
    @State private var parentID: UUID?
    @State private var icon: String?
    @FocusState private var focused: Bool

    private static let iconOptions: [String] = [
        "doc.text", "pencil", "book.closed", "folder",
        "terminal", "lightbulb", "bookmark", "sparkles"
    ]

    init(parent: UUID?, project: Bool, editing: Folder?) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        let currentGoal = editing?.goal ?? 0
        _goal = State(initialValue: currentGoal > 0 ? String(currentGoal) : "")
        _isProject = State(initialValue: editing?.project ?? project)
        _parentID = State(initialValue: editing?.parentID ?? parent)
        _icon = State(initialValue: editing?.icon)
    }

    private var trimmed: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
    private var value: Int? {
        let text = goal.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let number = Int(text), (0...10_000_000).contains(number) else { return nil }
        return number
    }

    private var availableParents: [Folder] {
        let forbidden = editing.map { store.library.descendants(of: $0.id) } ?? []
        return store.library.folders.filter { !forbidden.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((editing == nil ? "新建" : "编辑") + (isProject ? "项目" : "分组"))
                .font(.system(size: 16, weight: .semibold))
            Form {
                TextField("名称", text: $name).focused($focused)
                TextField("目标字数（可选）", text: $goal)
                Picker("类型", selection: $isProject) {
                    Text("分组").tag(false)
                    Text("项目").tag(true)
                }
                .onChange(of: isProject) { _, project in
                    if project { parentID = nil }
                }
                if !isProject {
                    Picker("上级位置", selection: $parentID) {
                        Text("顶层").tag(Optional<UUID>.none)
                        ForEach(availableParents) { folder in
                            Text(store.library.path(to: folder.id).map(\.name).joined(separator: " / "))
                                .tag(Optional(folder.id))
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text("图标").frame(width: 50, alignment: .leading)
                    ForEach(Self.iconOptions, id: \.self) { symbol in
                        let current = icon ?? (isProject ? "book.closed" : "doc.text")
                        let selected = current == symbol
                        Button { icon = symbol } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 14))
                                .frame(width: 28, height: 28)
                                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            HStack {
                Spacer()
                Button("取消") { model.dialog = nil }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || value == nil)
            }
        }
        .padding(22).frame(width: 440)
        .onAppear { focused = true }
    }

    private func save() {
        guard !trimmed.isEmpty, let value else { return }
        if let editing {
            store.editFolder(editing.id, name: trimmed, parentID: parentID, project: isProject, goal: value, icon: icon)
        } else {
            let id = store.addFolder(name: trimmed, parent: isProject ? nil : parentID, project: isProject, goal: value, icon: icon)
            model.chooseShelf(.folder(id))
        }
        model.dialog = nil
    }
}

private struct FilterForm: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var store: LibraryStore
    @State private var filter: SmartFilter
    @FocusState private var focused: Bool

    init(folder: UUID?, editing: SmartFilter?) {
        _filter = State(initialValue: editing ?? SmartFilter(name: "", query: "", tag: "", stage: nil, folderID: folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("智能筛选").font(.system(size: 16, weight: .semibold))
            Form {
                TextField("名称", text: $filter.name).focused($focused)
                Picker("查找范围", selection: $filter.folderID) {
                    Text("整个文库").tag(Optional<UUID>.none)
                    ForEach(store.library.folders) { folder in
                        Text(store.library.path(to: folder.id).map(\.name).joined(separator: " / ")).tag(Optional(folder.id))
                    }
                }
                TextField("包含文字", text: $filter.query)
                TextField("关键词", text: $filter.tag)
                Picker("文稿状态", selection: $filter.stage) {
                    Text("不限").tag(Optional<DraftStage>.none)
                    ForEach(DraftStage.allCases, id: \.self) { stage in
                        Text(stage.label).tag(Optional(stage))
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { model.dialog = nil }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    filter.name = String(filter.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                    filter.tag = filter.tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.saveFilter(filter)
                    model.chooseShelf(.filter(filter.id))
                    model.dialog = nil
                }.keyboardShortcut(.defaultAction)
                    .disabled(filter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 435)
        .onAppear { focused = true }
    }
}

private struct ExportSheet: View {
    @EnvironmentObject private var model: WorkspaceModel
    let drafts: [Draft]
    let palette: InkPalette
    @AppStorage("exportFormat") private var lastFormat = ExportFormat.pdf.rawValue
    @State private var copied = false

    private var format: ExportFormat { ExportFormat(rawValue: lastFormat) ?? .pdf }

    private var canCopyText: Bool {
        format == .markdown || format == .text || format == .html || format == .textbundle
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出预览").font(.system(size: 15, weight: .semibold))
                    Text(drafts.count == 1 ? (drafts.first?.name ?? "") : "\(drafts.count) 篇文稿")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                }
                Spacer()
                Picker("格式", selection: $lastFormat) {
                    ForEach(ExportFormat.allCases) { option in
                        Text("\(option.label) (.\(option.ext))").tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 170)

                if canCopyText {
                    Button(copied ? "已复制" : "复制") {
                        copyContent()
                    }
                }
                Button("取消") { model.dialog = nil }.keyboardShortcut(.cancelAction)
                Button("存储…") { model.export(drafts, format: format) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).frame(height: 56)
            palette.line.frame(height: 0.5)
            if format == .text || format == .markdown || format == .textbundle {
                let text = format == .text ? FileTransfer.plain(drafts)
                    : FileTransfer.markdown(drafts)
                ScrollView {
                    Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            } else {
                WebPreview(html: Manuscript.html(drafts, appearance: palette.dark ? "dark" : "light"))
            }
        }
        .background(palette.paper)
        .foregroundStyle(palette.ink)
        .frame(width: 760, height: 610)
    }

    private func copyContent() {
        let content: String
        switch format {
        case .text: content = FileTransfer.plain(drafts)
        case .html: content = Manuscript.html(drafts)
        default: content = FileTransfer.markdown(drafts)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
