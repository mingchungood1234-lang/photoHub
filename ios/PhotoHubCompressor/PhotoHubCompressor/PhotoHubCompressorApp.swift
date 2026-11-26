#if canImport(AppIntents)
import AppIntents
#endif
import Foundation
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
struct FetchAndShareByNameIntent: AppIntent {
    static var title: LocalizedStringResource = "Fetch & Share Original (Large Video)"
    static var description = IntentDescription(
        "Zero-copy original fetch using only Photo/Video Name from Apple Shortcuts. Works reliably for large videos without exporting video bytes."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Photo or Video Names")
    var names: String?

    @Parameter(title: "Creation Date")
    var creationDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult {
        let expandedNames: [String] = (names ?? "")
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !expandedNames.isEmpty else {
            IncomingShareCoordinator.shared.presentInAppPhotoPicker()
            return .result()
        }

        let singleDateHint = expandedNames.count == 1 ? creationDate : nil
        let inputs: [OriginalShareInput] = expandedNames.map { name in
            let baseName = URL(fileURLWithPath: name).lastPathComponent
            let prefix = ProxyGenerator.extractMasterHashPrefix(fromProxyFilename: baseName)
            let ext = URL(fileURLWithPath: baseName).pathExtension.lowercased()
            let isVideo = ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm"].contains(ext)
            return OriginalShareInput(
                assetId: nil,
                fileURL: nil,
                filenameHint: baseName,
                masterHashHint: prefix,
                isVideo: isVideo,
                creationDateHint: singleDateHint
            )
        }

        IncomingShareCoordinator.shared.enqueueInputs(inputs)
        return .result()
    }
}

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
        var createdBatchDir = false

        var inputs: [OriginalShareInput] = []
        for (idx, file) in media.enumerated() {
            autoreleasepool {
                let rawName = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseName = URL(fileURLWithPath: rawName.isEmpty ? "media_\(idx + 1)" : rawName).lastPathComponent
                let ext = URL(fileURLWithPath: baseName).pathExtension.lowercased()
                let utType = file.type ?? UTType(filenameExtension: ext)
                let isVideo = utType?.conforms(to: .movie) == true
                    || ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm"].contains(ext)

                // Zero-copy fast path: if filename already carries PHOTOHUB_PROXY_<prefix16>,
                // never copy fileURL or load file.data into RAM (works instantly for huge videos).
                if let prefix = ProxyGenerator.extractMasterHashPrefix(fromProxyFilename: baseName) {
                    inputs.append(
                        OriginalShareInput(
                            assetId: nil,
                            fileURL: nil,
                            filenameHint: baseName,
                            masterHashHint: prefix,
                            isVideo: isVideo
                        )
                    )
                    return
                }

                if !createdBatchDir {
                    try? fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
                    createdBatchDir = true
                }

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
                if !saved && file.fileURL == nil && !isVideo {
                    // Never materialize an unknown video into RAM via IntentFile.data (causes Jetsam OOM).
                    saved = (try? file.data.write(to: destURL, options: .atomic)) != nil
                }

                if saved {
                    inputs.append(
                        OriginalShareInput(
                            assetId: nil,
                            fileURL: destURL,
                            filenameHint: baseName,
                            masterHashHint: nil,
                            isVideo: isVideo
                        )
                    )
                } else if !rawName.isEmpty {
                    // Even if Shortcuts could not pass file bytes for a huge video, preserve the
                    // filename so zero-copy server/Photos metadata matching can still resolve it.
                    inputs.append(
                        OriginalShareInput(
                            assetId: nil,
                            fileURL: nil,
                            filenameHint: baseName,
                            masterHashHint: nil,
                            isVideo: isVideo
                        )
                    )
                }
            }
        }

        if inputs.isEmpty {
            if createdBatchDir {
                try? fm.removeItem(at: batchDir)
            }
            if !media.isEmpty {
                IncomingShareCoordinator.shared.reportIncomingLoadFailure(
                    "Apple Shortcuts hit its memory limit exporting this large video. Update your Shortcut to pass Name (Get Details of Photos -> Name) into \"Fetch & Share Original (Large Video)\", or use photoHub -> Pick Photos or Videos to Share Original."
                )
            } else {
                IncomingShareCoordinator.shared.presentInAppPhotoPicker()
            }
        } else {
            IncomingShareCoordinator.shared.enqueueInputs(
                inputs,
                cleanupDirs: createdBatchDir ? [batchDir] : []
            )
        }
        return .result()
    }
}

@available(iOS 16.4, *)
struct PhotoHubAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FetchAndShareByNameIntent(),
            phrases: [
                "Share original with \(.applicationName)"
            ],
            shortTitle: "Share Original",
            systemImageName: "square.and.arrow.up"
        )
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
                BackgroundUploadTransport.shared.reconcileOrphanedTasks()
                BackgroundBackupManager.shared.pruneMissingAssetsFromStaged()
                BackgroundBackupManager.shared.triggerSilentAutoUpload(settings: settings, isMovingToBackground: false)
            }
        }
    }
}
