import Combine
import Foundation
import Sparkle

/// One updater shared by the application menu and Settings, alive for the whole app session.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        // Start on the next run loop so the App and its delegate finish initialization first.
        DispatchQueue.main.async { [weak self] in self?.controller.startUpdater() }
    }

    var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
