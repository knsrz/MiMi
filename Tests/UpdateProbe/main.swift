import AppKit
import Foundation
import Sparkle

final class UpdateProbe: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("FOUND_UPDATE version=\(item.versionString) display=\(item.displayVersionString)")
        exit(0)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        print("NO_UPDATE: \(error.localizedDescription)")
        exit(0)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        print("UPDATE_ERROR: \(error)")
        exit(1)
    }
}

// Exercise the real Sparkle runtime and packaged Info.plist without installing an update.
let application = NSApplication.shared
let bundle = Bundle(path: CommandLine.arguments[1])!
let delegate = UpdateProbe()
let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
do {
    try updater.start()
    if CommandLine.arguments.contains("--online") {
        updater.checkForUpdateInformation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { print("UPDATE_TIMEOUT"); exit(2) }
        application.run()
    } else {
        print("Sparkle updater started successfully with the packaged update configuration.")
    }
} catch {
    print("START_ERROR: \(error)")
    exit(1)
}
