import SwiftUI

@main
struct PhotoHubCompressorApp: App {
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
            } else if phase == .active {
                BackgroundBackupManager.shared.pruneMissingAssetsFromStaged()
            }
        }
    }
}
