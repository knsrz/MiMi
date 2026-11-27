import Foundation

extension Smoke {
    static func folderVault(_ directory: URL) throws {
        let fm = FileManager.default
        let root = directory.appending(path: "迁移测试", directoryHint: .isDirectory)
        let journal = directory.appending(path: "文库恢复测试", directoryHint: .isDirectory)
        let project = Folder(name: "研究项目", project: true, goal: 900, icon: "book")
        let group = Folder(name: "第二章", parentID: project.id)
        let sameGroup = Folder(name: "第二章", parentID: project.id)
        let attachment = Attachment(name: "图.png", data: Data([0, 1, 2, 255]))
        let history = Revision(title: "旧标题", text: "旧正文")
        let draft = Draft(folderID: group.id, title: "同名", text: "![图](\(attachment.reference))\n原样正文\n",
                          note: "备注", tags: ["中文"], attachments: [attachment], revisions: [history], favorite: true, goal: 80)
        let second = Draft(folderID: group.id, title: draft.title, text: "# 第二篇")
        let blank = Draft()
        let filter = SmartFilter(name: "图片", query: "正文", tag: "中文", stage: .draft, folderID: project.id)
        let filter2 = SmartFilter(name: "另一个筛选", query: "", tag: "", folderID: nil)
        let legacy = Library(drafts: [second, draft, blank], folders: [project, group, sameGroup], filters: [filter, filter2])

        let vault = try FolderVault.create(at: root, with: legacy, journalDirectory: journal)
        try check(try vault.open().library == legacy, "迁移完整保留旧文库字段、字节与手动排序")
        let nested = root.appending(path: "研究项目/第二章", directoryHint: .isDirectory)
        let body = nested.appending(path: "同名--\(draft.id.uuidString).md")
        let secondBody = nested.appending(path: "同名--\(second.id.uuidString).md")
        let secondBytes = try Data(contentsOf: secondBody)
        try check(try Data(contentsOf: body) == Data(draft.text.utf8), "同名 Markdown 独立保存且正文无注入")
        try check(try Data(contentsOf: root.appending(path: "\(FolderVault.dataName)/附件/\(draft.id.uuidString)/\(attachment.id.uuidString).png")) == attachment.data,
                  "附件在文库中以原始字节保存")
        try check(try String(contentsOf: root.appending(path: "\(FolderVault.dataName)/历史版本/\(draft.id.uuidString)/\(history.id.uuidString).md"), encoding: .utf8) == history.text,
                  "历史版本在文库中以 Markdown 保存")
        let beforeDate = try fm.attributesOfItem(atPath: secondBody.path)[.modificationDate] as? Date

        // Separate sessions use the same observations before one of them edits.
        let other = try FolderVault(root: root)
        var changed = legacy
        changed.drafts[1].text = "Mac A 的正文"
        try check(try vault.save(from: legacy, to: changed).library == changed, "只保存发生变化的文稿")
        try check(try Data(contentsOf: secondBody) == secondBytes &&
                  fm.attributesOfItem(atPath: secondBody.path)[.modificationDate] as? Date == beforeDate, "旁边的文稿没有被重写")
        var simultaneous = legacy
        simultaneous.drafts[0].text = "Mac B 的另一篇正文"
        let combined = try other.save(from: legacy, to: simultaneous).library
        try check(combined.drafts.map(\.text) == ["Mac B 的另一篇正文", "Mac A 的正文", ""], "不同文稿的并发修改均保留")
        var tags = legacy
        tags.drafts[1].tags.append("并发标签")
        let merged = try other.save(from: legacy, to: tags).library
        try check(merged.drafts[1].text == "Mac A 的正文" && merged.drafts[1].tags.contains("并发标签"), "合并同篇不同字段")
        var divergent = legacy
        divergent.drafts[1].text = "Mac B 的冲突正文"
        let conflict = try other.save(from: legacy, to: divergent)
        let copies = conflict.conflicts[draft.id] ?? []
        try check(copies.count == 1 && conflict.library.drafts.contains { $0.id == copies[0] && $0.text == "Mac B 的冲突正文" },
                  "同篇不同正文保留独立冲突副本")
        try check(try other.save(from: legacy, to: divergent).conflicts[draft.id] == copies, "重试同一冲突不产生多份副本")

        let movedBase = try vault.open().library
        var moved = movedBase
        moved.folders[0].name = "新项目"
        moved.drafts[moved.drafts.firstIndex { $0.id == draft.id }!].folderID = nil
        moved.drafts[moved.drafts.firstIndex { $0.id == draft.id }!].title = "显式改名"
        let movedResult = try vault.save(from: movedBase, to: moved).library
        try check(movedResult == moved, "项目改名级联目录与文稿改名移动")
        let movedURL = root.appending(path: "收件箱/显式改名--\(draft.id.uuidString).md")
        try check(fm.fileExists(atPath: movedURL.path) && !fm.fileExists(atPath: body.path), "改名移动后正文只有一个位置")
        try Data("外部编辑器内容".utf8).write(to: movedURL, options: .atomic)
        let afterExternalEdit = try vault.open().library
        try check(afterExternalEdit.drafts.first { $0.id == draft.id }?.text == "外部编辑器内容", "能够重新载入外部 Markdown 编辑")

        var trashed = afterExternalEdit
        let index = trashed.drafts.firstIndex { $0.id == second.id }!
        trashed.drafts[index].deleted = Date()
        let trashedResult = try vault.save(from: afterExternalEdit, to: trashed).library
        try check(trashedResult == trashed, "移到废纸篓时保留原分组")
        try check(fm.fileExists(atPath: root.appending(path: "废纸篓/同名--\(second.id.uuidString).md").path), "废纸篓有真实正文文件")
        try check(try vault.save(from: trashed, to: afterExternalEdit).library == afterExternalEdit, "恢复到原分组")
        let deleted = try vault.save(from: afterExternalEdit, to: trashed).library
        var purged = deleted
        purged.drafts.removeAll { $0.id == second.id }
        try check(try vault.save(from: deleted, to: purged).library == purged, "永久删除文稿")
        var editedOldCopy = afterExternalEdit
        editedOldCopy.drafts[editedOldCopy.drafts.firstIndex { $0.id == second.id }!].text = "离线编辑"
        let afterPurge = try other.save(from: afterExternalEdit, to: editedOldCopy)
        try check(!afterPurge.library.drafts.contains { $0.id == second.id } && afterPurge.conflicts[second.id]?.count == 1,
                  "离线修改以副本保留且已删除文稿没有复活")

        let beforeFailure = try vault.open().library
        var afterFailure = beforeFailure
        afterFailure.drafts[afterFailure.drafts.firstIndex { $0.id == blank.id }!].text = "首次标题"
        let temporary = root.deletingLastPathComponent().appending(path: "暂不可用")
        try fm.moveItem(at: root, to: temporary)
        do {
            _ = try vault.save(from: beforeFailure, to: afterFailure)
            throw CheckFailure(label: "目录离线时保存应失败")
        } catch is VaultError {
            // Pending data is held outside the vault until it is usable again.
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {}
        try fm.moveItem(at: temporary, to: root)
        let reopened = try FolderVault(root: root, journalDirectory: journal)
        try check(try reopened.open().library == afterFailure, "重启后重新提交本机待保存事务")
        let firstTitle = root.appending(path: "收件箱/首次标题--\(blank.id.uuidString).md")
        try check(fm.fileExists(atPath: firstTitle.path), "空白文稿首次取得自动文件名")
        var more = afterFailure
        more.drafts[more.drafts.firstIndex { $0.id == blank.id }!].text = "新的第一行"
        _ = try reopened.save(from: afterFailure, to: more)
        try check(fm.fileExists(atPath: firstTitle.path), "继续编辑正文时保持文件名")

        // A missing companion file is reported as pending and never regenerated
        // as an empty document by another open session.
        let sidecar = root.appending(path: "\(FolderVault.dataName)/文稿/\(blank.id.uuidString).json")
        let delayed = directory.appending(path: "delayed.json")
        try fm.moveItem(at: sidecar, to: delayed)
        try check(try reopened.open().waiting.contains(blank.id), "半下载文稿标记为等待")
        try fm.moveItem(at: delayed, to: sidecar)
        try check(try reopened.open().library == more, "配套文件到齐后恢复文稿")

        let occupied = directory.appending(path: "非空目录", directoryHint: .isDirectory)
        try fm.createDirectory(at: occupied, withIntermediateDirectories: false)
        let unmanaged = occupied.appending(path: "我的文件.txt")
        try Data("保留此文件".utf8).write(to: unmanaged)
        do {
            _ = try FolderVault.create(at: occupied, with: legacy)
            throw CheckFailure(label: "不应覆盖非空目录")
        } catch VaultError.occupied {}
        try check(try Data(contentsOf: unmanaged) == Data("保留此文件".utf8), "建库保护目录中的现有文件")
        do {
            _ = try FolderVault.openOrCreate(at: occupied, journalDirectory: journal)
            throw CheckFailure(label: "打开普通非空目录时不应初始化文库")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {}
        try check(!fm.fileExists(atPath: occupied.appending(path: FolderVault.dataName).path), "打开普通目录后没有写入文库数据")
        let empty = directory.appending(path: "空目录", directoryHint: .isDirectory)
        try fm.createDirectory(at: empty, withIntermediateDirectories: false)
        try check(try FolderVault.create(at: empty, with: Library()).open().library == Library(), "可以在现有空目录创建文库")
    }

    @MainActor
    static func emptyFolderWorkspace(_ directory: URL) async throws {
        let suite = "Inkfolio-Test-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = directory.appending(path: "空文件夹文库", directoryHint: .isDirectory)
        let journal = directory.appending(path: "empty-workspace-pending", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        try Data().write(to: root.appending(path: ".DS_Store"))

        let store = LibraryStore(preferences: preferences, journalDirectory: journal)
        defer { store.stopWatchingFolder() }
        try await store.selectFolder(.open(VaultAccess(root)))
        try check(store.library == Library(), "打开只有 Finder 元数据的空文件夹时初始化文库")

        let id = store.addDraft(folder: nil)
        let inbox = root.appending(path: FolderVault.inbox, directoryHint: .isDirectory)
        let blank = inbox.appending(path: "未命名文稿--\(id.uuidString).md")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !fm.fileExists(atPath: blank.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(fm.fileExists(atPath: blank.path), "空白文稿通过自动保存写入 Markdown")
        try check(store.flush() && store.draft(id) != nil, "自动保存后空白文稿仍在工作台")
        store.edit(id) { $0.text = "重开后保留这篇正文" }
        try check(store.flush(), "空白文稿可以继续编辑")
        let body = inbox.appending(path: "重开后保留这篇正文--\(id.uuidString).md")
        let metadata = root.appending(path: FolderVault.dataName, directoryHint: .isDirectory)
        let note = metadata.appending(path: "文稿/\(id.uuidString).json")
        let unmanaged = root.appending(path: "其他文件.txt")
        try Data("用户文件".utf8).write(to: unmanaged)
        try check(try root.resourceValues(forKeys: [.isHiddenKey]).isHidden == false, "新文库可在 Finder 中显示")

        // Model the flags left by the older iCloud Drive creation flow.
        store.stopWatchingFolder()
        var hidden = URLResourceValues()
        hidden.isHidden = true
        for var url in [root, inbox, root.appending(path: FolderVault.trash), metadata, body, note, unmanaged] {
            try url.setResourceValues(hidden)
            try check(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden == true, "测试文件确实带隐藏标记")
        }

        let reopen = LibraryStore(preferences: preferences, journalDirectory: journal)
        defer { reopen.stopWatchingFolder() }
        let reopened = await reopen.reopenSavedFolder()
        try check(reopened && reopen.draft(id)?.text == "重开后保留这篇正文", "重开隐藏文库时回读正文和元数据")
        for url in [root, inbox, body] {
            try check(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden == false, "旧文库和正文恢复 Finder 可见性")
        }
        try check(try unmanaged.resourceValues(forKeys: [.isHiddenKey]).isHidden == true, "保留用户文件的隐藏设置")
        reopen.edit(id) { $0.text = "恢复后的修改" }
        try check(reopen.flush() && (try String(contentsOf: body, encoding: .utf8)) == "恢复后的修改",
                  "仍带隐藏标记的元数据支持继续保存正文")
    }

    @MainActor
    static func folderWorkspace(_ directory: URL) async throws {
        let suite = "Inkfolio-Test-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let legacy = directory.appending(path: "LibrarySeed.json")
        let source = Library(drafts: [Draft(title: "旧库", text: "原始正文")])
        let original = try JSONEncoder().encode(source)
        try original.write(to: legacy)
        let journal = directory.appending(path: "workspace-pending", directoryHint: .isDirectory)
        let root = directory.appending(path: "workspace-vault", directoryHint: .isDirectory)
        let store = LibraryStore(preferences: preferences, legacyFile: legacy, journalDirectory: journal)
        defer { store.stopWatchingFolder() }
        try await store.selectFolder(.create(root, parent: VaultAccess(directory), source: legacy))
        try check(store.folderURL != nil && store.library == source, "工作台可选定迁移后的文件夹文库")
        try check(try root.resourceValues(forKeys: [.isHiddenKey]).isHidden == false, "创建的新文库文件夹在 Finder 中可见")
        try check(try Data(contentsOf: legacy) == original, "迁移后原始 JSON 完整保留")
        let id = source.drafts[0].id
        store.edit(id) { $0.text = "正在编辑第一版" }
        store.edit(id) { $0.text = "后台保存应保留最后一次输入" }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let body = root.appending(path: "收件箱/旧库--\(id.uuidString).md")
        while ContinuousClock.now < deadline {
            if (try? String(contentsOf: body, encoding: .utf8)) == "后台保存应保留最后一次输入" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(try String(contentsOf: body, encoding: .utf8) == "后台保存应保留最后一次输入", "工作台后台保存独立 Markdown")
        let saved = directory.appending(path: "workspace-backup.json")
        try store.exportBackup(to: saved)
        let reopen = LibraryStore(preferences: preferences, legacyFile: legacy, journalDirectory: journal)
        defer { reopen.stopWatchingFolder() }
        let didReopen = await reopen.reopenSavedFolder()
        try check(didReopen && reopen.library == store.library, "重启后依靠书签打开原文库")
        let restored = directory.appending(path: "workspace-restored", directoryHint: .isDirectory)
        try await reopen.selectFolder(.create(restored, parent: VaultAccess(directory), source: saved))
        try check(reopen.folderURL != store.folderURL && reopen.library == store.library, "备份可以恢复为独立的新文库")
    }

    static func folderProvider(_ provider: URL) async throws {
        let parent = provider.appending(path: "Inkfolio-Storage-Check-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = parent.appending(path: "测试文库", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: parent) }
        let group = Folder(name: "测试分组")
        let draft = Draft(folderID: group.id, title: "同步检查", text: "MiMi iCloud Drive storage test")
        let seed = Library(drafts: [draft], folders: [group])
        let vault = try FolderVault.create(at: root, with: seed)
        var updated = seed
        updated.drafts[0].text = "iCloud Drive incremental save check"
        try check(try vault.save(from: seed, to: updated).library == updated, "iCloud Drive 目录可建库并保存")
        try check(try FolderVault(root: root).open().library == updated, "从 iCloud Drive 重开并回读")
        let body = root.appending(path: "测试分组/同步检查--\(draft.id.uuidString).md")
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            // New URLs keep the File Provider attributes fresh.
            let values = try URL(fileURLWithPath: body.path).resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
            if values.ubiquitousItemIsUploaded == true {
                print("iCloud Drive 目录验证通过，系统已报告测试正文上传完成。")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("iCloud Drive 目录读写和重开通过，未在测试时限内取得上传完成状态。")
    }

}
