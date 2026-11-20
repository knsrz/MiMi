import Foundation

extension Smoke {
    static func workspaceSizing() throws {
        let preferred: [WorkspacePane: CGFloat] = [.library: 240, .browser: 286, .inspector: 276]
        let manuscripts = WorkspaceSizing(library: false, browser: true, inspector: true)
        let screenshotWidth: CGFloat = 649
        let narrow = manuscripts.widths(in: screenshotWidth, preferred: preferred, priority: nil)
        try check(narrow[.browser] < 286 && narrow[.inspector] < 276 && narrow.editor >= 234,
                  "窄窗口同时收缩文稿列表和检查器，保留可用的编辑宽度")
        let expanded = manuscripts.widths(in: 1100, preferred: preferred, priority: nil)
        try check(expanded[.browser] == 286 && expanded[.inspector] == 276,
                  "重新拉宽窗口时恢复两侧偏好宽度")

        let dragTarget = manuscripts.dragRange(for: .inspector, in: 700).upperBound - 6
        let dragged = manuscripts.widths(in: 700, preferred: [.browser: 286, .inspector: dragTarget], priority: .inspector)
        try check(abs(dragged[.inspector] - dragTarget) < 0.01 && dragged.editor >= 234,
                  "窄窗口中拖动分隔线时，优先采用拖到的位置")

        for (library, browser) in [(true, true), (false, true), (false, false)] {
            for inspector in [false, true] {
                let sizing = WorkspaceSizing(library: library, browser: browser, inspector: inspector)
                for width in [580, sizing.minimumWindowWidth, sizing.minimumWindowWidth + 70, 1500] {
                    let result = sizing.widths(in: width, preferred: preferred, priority: nil)
                    let total = result.editor + result.sides.values.reduce(0, +)
                    try check(abs(total - width) < 0.01 && result.editor >= (browser ? 234 : 314),
                              "工作台切换和窗口缩放时全部栏位都在窗口内")
                }
            }
        }
    }
}
