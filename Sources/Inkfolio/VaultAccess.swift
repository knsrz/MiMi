import CoreServices
import Foundation

final class VaultAccess: Sendable {
    struct Bookmark: Codable {
        var data: Data
        var scoped: Bool

        func open() throws -> VaultAccess {
            var stale = false
            let options: URL.BookmarkResolutionOptions = scoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            let access = VaultAccess(url)
            if scoped && !access.scoped { throw VaultError.unavailable(url.lastPathComponent) }
            return access
        }
    }

    let url: URL
    private let scoped: Bool

    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    func bookmark() throws -> Bookmark {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return Bookmark(data: data, scoped: true)
        }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return Bookmark(data: data, scoped: false)
    }
}

final class VaultObservation: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "local.inkfolio.folder-events")

    init(root: URL, onChange: @escaping () -> Void) {
        presentedItemURL = root
        self.onChange = onChange
        super.init()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<VaultObservation>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, UInt32(flags))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, eventQueue)
            FSEventStreamStart(stream)
        }
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            eventQueue.sync {}
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func presentedItemDidChange() { onChange() }
    func presentedItemDidMove(to newURL: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onChange()
        completionHandler(nil)
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}
