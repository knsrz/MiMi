import Foundation

enum WorkspacePane: String, CaseIterable {
    case library, browser, inspector

    var preferenceKey: String { rawValue + "Width" }

    var defaultWidth: CGFloat {
        switch self {
        case .library: 240
        case .browser: 286
        case .inspector: 276
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .library: 330
        case .browser: 420
        case .inspector: 370
        }
    }

    func minimumWidth(showsLibrary: Bool) -> CGFloat {
        switch self {
        case .library: 156
        case .browser: showsLibrary ? 174 : 196
        case .inspector: 202
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .library: "调整文库侧栏宽度"
        case .browser: "调整文稿列表宽度"
        case .inspector: "调整检查器宽度"
        }
    }
}

struct WorkspaceSizing {
    static let windowFloor: CGFloat = 580
    private let active: [WorkspacePane]
    private let showsLibrary: Bool
    private let editorMinimum: CGFloat

    init(library: Bool, browser: Bool, inspector: Bool) {
        showsLibrary = library
        var panes: [WorkspacePane] = []
        if library { panes.append(.library) }
        if browser { panes.append(.browser) }
        if inspector { panes.append(.inspector) }
        active = panes
        editorMinimum = browser ? 234 : 314
    }

    var minimumWindowWidth: CGFloat {
        max(Self.windowFloor, editorMinimum + active.reduce(0) { $0 + minimum(for: $1) })
    }

    private func minimum(for pane: WorkspacePane) -> CGFloat {
        pane.minimumWidth(showsLibrary: showsLibrary)
    }

    func dragRange(for pane: WorkspacePane, in width: CGFloat) -> ClosedRange<CGFloat> {
        let otherMinimum = active.filter { $0 != pane }.reduce(0) { $0 + minimum(for: $1) }
        let lower = minimum(for: pane)
        return lower...max(lower, min(pane.maximumWidth, width - editorMinimum - otherMinimum))
    }

    struct Widths {
        let sides: [WorkspacePane: CGFloat]
        let editor: CGFloat

        subscript(_ pane: WorkspacePane) -> CGFloat { sides[pane, default: 0] }
    }

    func widths(in width: CGFloat, preferred: [WorkspacePane: CGFloat], priority: WorkspacePane?) -> Widths {
        let width = max(0, width)
        let budget = max(0, width - editorMinimum)
        let floor = active.reduce(CGFloat(0)) { $0 + minimum(for: $1) }

        func requested(_ pane: WorkspacePane) -> CGFloat {
            min(pane.maximumWidth, max(minimum(for: pane), preferred[pane] ?? pane.defaultWidth))
        }

        var sides: [WorkspacePane: CGFloat] = [:]
        if floor > budget {
            // A layout change can reach SwiftUI before the window applies its new minimum size.
            for pane in active { sides[pane] = minimum(for: pane) * budget / floor }
        } else {
            var remaining = active
            var remainingBudget = budget
            if let priority, remaining.contains(priority) {
                let reserved = min(requested(priority), dragRange(for: priority, in: width).upperBound)
                sides[priority] = reserved
                remainingBudget -= reserved
                remaining.removeAll { $0 == priority }
            }
            let remainingFloor = remaining.reduce(CGFloat(0)) { $0 + minimum(for: $1) }
            let flexibility = remaining.reduce(CGFloat(0)) { $0 + requested($1) - minimum(for: $1) }
            let fraction = flexibility > 0 ? min(1, max(0, remainingBudget - remainingFloor) / flexibility) : 0
            for pane in remaining {
                let base = minimum(for: pane)
                sides[pane] = base + (requested(pane) - base) * fraction
            }
        }
        return Widths(sides: sides, editor: max(0, width - sides.values.reduce(0, +)))
    }
}
