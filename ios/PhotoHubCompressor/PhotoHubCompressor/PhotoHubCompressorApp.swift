import SwiftUI
import UIKit

final class PhotoHubAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadTransport.shared.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct PhotoHubCompressorApp: App {
    @UIApplicationDelegateAdaptor(PhotoHubAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings: AppSettings

    init() {
        let initialSettings = AppSettings()
        _settings = StateObject(wrappedValue: initialSettings)
        BackgroundBackupManager.shared.register(settings: initialSettings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                BackgroundBackupManager.shared.scheduleNightlyBackupIfEnabled(settings: settings)
                BackgroundBackupManager.shared.triggerSilentAutoUpload(settings: settings, isMovingToBackground: true)
            } else if phase == .active {
                BackgroundBackupManager.shared.pruneMissingAssetsFromStaged()
                BackgroundBackupManager.shared.triggerSilentAutoUpload(settings: settings, isMovingToBackground: false)
            }
        }
    }
}
