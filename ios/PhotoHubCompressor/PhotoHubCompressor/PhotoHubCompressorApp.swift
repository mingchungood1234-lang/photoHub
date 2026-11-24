#if canImport(AppIntents)
import AppIntents
#endif
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
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

#if canImport(AppIntents)
@available(iOS 16.0, *)
struct FetchAndShareOriginalIntent: AppIntent {
    static var title: LocalizedStringResource = "Fetch & Share Original"
    static var description = IntentDescription(
        "Matches compressed photoHub proxies from Apple Photos or Shortcuts and opens the iOS Share Sheet with full-resolution originals."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Photos or Videos", default: [])
    var media: [IntentFile]

    @MainActor
    func perform() async throws -> some IntentResult {
        if media.isEmpty {
            IncomingShareCoordinator.shared.presentInAppPhotoPicker()
            return .result()
        }

        let fm = FileManager.default
        let batchDir = fm.temporaryDirectory
            .appendingPathComponent("photohub_incoming_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: batchDir, withIntermediateDirectories: true)

        var inputs: [OriginalShareInput] = []
        for (idx, file) in media.enumerated() {
            autoreleasepool {
                let rawName = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseName = URL(fileURLWithPath: rawName.isEmpty ? "media_\(idx + 1)" : rawName).lastPathComponent
                let destURL = batchDir.appendingPathComponent("\(idx + 1)_\(baseName)")
                var saved = false
                if let srcURL = file.fileURL {
                    try? fm.removeItem(at: destURL)
                    let accessed = srcURL.startAccessingSecurityScopedResource()
                    defer {
                        if accessed {
                            srcURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    saved = (try? fm.copyItem(at: srcURL, to: destURL)) != nil
                }
                if !saved && file.fileURL == nil {
                    // Only materialize in-memory IntentFile.data when no backing fileURL was provided,
                    // avoiding Jetsam OOM crashes on huge videos.
                    saved = (try? file.data.write(to: destURL, options: .atomic)) != nil
                }
                guard saved else { return }
                let ext = destURL.pathExtension.lowercased()
                let utType = file.type ?? UTType(filenameExtension: ext)
                let isVideo = utType?.conforms(to: .movie) == true
                    || ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm"].contains(ext)
                inputs.append(
                    OriginalShareInput(
                        assetId: nil,
                        fileURL: destURL,
                        filenameHint: baseName,
                        masterHashHint: nil,
                        isVideo: isVideo
                    )
                )
            }
        }

        if inputs.isEmpty {
            try? fm.removeItem(at: batchDir)
            if !media.isEmpty {
                IncomingShareCoordinator.shared.reportIncomingLoadFailure(
                    "Could not read the selected photo/video from Apple Shortcuts (iOS memory or security-scope limit for huge files). Open photoHub -> Pick Photos or Videos to Share Original instead."
                )
            } else {
                IncomingShareCoordinator.shared.presentInAppPhotoPicker()
            }
        } else {
            IncomingShareCoordinator.shared.enqueueInputs(inputs, cleanupDirs: [batchDir])
        }
        return .result()
    }
}
#endif

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
                pruneStaleTempShareDirs()
                BackgroundBackupManager.shared.pruneMissingAssetsFromStaged()
                BackgroundBackupManager.shared.triggerSilentAutoUpload(settings: settings, isMovingToBackground: false)
            }
        }
    }
}
