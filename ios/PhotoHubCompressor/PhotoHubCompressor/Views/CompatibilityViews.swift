import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Uses `NavigationStack` on iOS 16+ and falls back cleanly to stacked `NavigationView` on iOS 15.
struct AdaptiveNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

/// Uses `ContentUnavailableView` on iOS 17+ and a clean custom empty state on iOS 15-16.
struct CompatibleEmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            } actions: {
                actions()
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                actions()
                    .padding(.top, 4)
            }
            .padding()
        }
    }
}

extension View {
    @ViewBuilder
    func compatibleAutocorrectionDisabled() -> some View {
        if #available(iOS 16.0, *) {
            autocorrectionDisabled(true)
        } else {
            disableAutocorrection(true)
        }
    }

    @ViewBuilder
    func compatibleHiddenNavBarBackground() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
        }
    }
}

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let fileURLs: [URL]

    var fileURL: URL { fileURLs[0] }

    init(fileURL: URL) {
        self.fileURLs = [fileURL]
    }

    init(fileURLs: [URL]) {
        precondition(!fileURLs.isEmpty)
        self.fileURLs = fileURLs
    }
}

func cleanupTempShareURL(_ url: URL) {
    let parent = url.deletingLastPathComponent()
    if parent.lastPathComponent.hasPrefix("photohub_share_")
        || parent.lastPathComponent.hasPrefix("photohub_incoming_") {
        try? FileManager.default.removeItem(at: parent)
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}

func cleanupTempShareURLs(_ urls: [URL]) {
    for url in urls {
        cleanupTempShareURL(url)
    }
}

/// Delays cleanup after UIActivityViewController finishes so async share extensions
/// (Save Video, AirDrop, WhatsApp) can finish reading large original video files first.
func scheduleTempShareCleanup(_ urls: [URL], delay: TimeInterval = 180) {
    guard !urls.isEmpty else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
        cleanupTempShareURLs(urls)
    }
}

func pruneStaleTempShareDirs(maxAge: TimeInterval = 3600) {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
    guard let entries = try? fm.contentsOfDirectory(
        at: tmp,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: .skipsHiddenFiles
    ) else { return }
    let cutoff = Date().addingTimeInterval(-maxAge)
    for url in entries {
        let name = url.lastPathComponent
        guard name.hasPrefix("photohub_share_") || name.hasPrefix("photohub_incoming_") else { continue }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if mod < cutoff {
            try? fm.removeItem(at: url)
        }
    }
}

/// Native iOS Share Sheet wrapper with delayed temp-file cleanup for large videos.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        let finishShare = onComplete
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                finishShare()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct PickedMediaResult: Sendable {
    let assetId: String?
    let copiedFileURL: URL?
    let isVideo: Bool
}

/// Multi-select iOS 15+ PHPicker wrapper returning `[PickedMediaResult]` for checking gallery proxy/original status.
struct MultiPhotoPickerSheet: UIViewControllerRepresentable {
    var selectionLimit: Int = 25
    var skipCopyIfTracked: Bool = false
    let onPickBatch: ([PickedMediaResult]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            skipCopyIfTracked: skipCopyIfTracked,
            onPickBatch: onPickBatch,
            onCancel: onCancel
        )
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let skipCopyIfTracked: Bool
        private let onPickBatch: ([PickedMediaResult]) -> Void
        private let onCancel: () -> Void

        init(
            skipCopyIfTracked: Bool,
            onPickBatch: @escaping ([PickedMediaResult]) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.skipCopyIfTracked = skipCopyIfTracked
            self.onPickBatch = onPickBatch
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                onCancel()
                return
            }

            let finishBatch = onPickBatch
            let skipCopy = skipCopyIfTracked
            let collector = PickedBatchCollector(count: results.count)
            let group = DispatchGroup()

            for (idx, item) in results.enumerated() {
                group.enter()
                PhotoPickerItemLoader.loadPickedResult(from: item, skipCopyIfTracked: skipCopy) { picked in
                    collector.store(picked, at: idx)
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                finishBatch(collector.snapshot())
            }
        }
    }
}

/// Thread-safe collector for batch `PHPickerResult` loading across callback closures.
private final class PickedBatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PickedMediaResult?]

    init(count: Int) {
        self.items = Array(repeating: nil, count: count)
    }

    func store(_ item: PickedMediaResult, at index: Int) {
        lock.lock()
        if items.indices.contains(index) {
            items[index] = item
        }
        lock.unlock()
    }

    func snapshot() -> [PickedMediaResult] {
        lock.lock()
        defer { lock.unlock() }
        return items.compactMap { $0 }
    }
}

enum PhotoPickerItemLoader {
    static func loadPickedResult(
        from result: PHPickerResult,
        skipCopyIfTracked: Bool,
        completion: @escaping (PickedMediaResult) -> Void
    ) {
        loadItemProvider(
            result.itemProvider,
            assetId: result.assetIdentifier,
            skipCopyIfTracked: skipCopyIfTracked,
            completion: completion
        )
    }

    static func loadItemProvider(
        _ provider: NSItemProvider,
        assetId: String?,
        skipCopyIfTracked: Bool,
        completion: @escaping (PickedMediaResult) -> Void
    ) {
        let videoTypeIds = [
            UTType.quickTimeMovie.identifier,
            UTType.mpeg4Movie.identifier,
            UTType.movie.identifier,
            UTType.video.identifier,
        ]
        let registeredVideoId = provider.registeredTypeIdentifiers.first { tid in
            if let ut = UTType(tid) {
                return ut.conforms(to: .movie) || ut.conforms(to: .video)
            }
            return false
        }
        let isVideo = registeredVideoId != nil || videoTypeIds.contains {
            provider.hasItemConformingToTypeIdentifier($0)
        }

        if skipCopyIfTracked, let assetId {
            if LocalProxyTracker.shared.masterLookup(forAssetId: assetId) != nil {
                completion(PickedMediaResult(assetId: assetId, copiedFileURL: nil, isVideo: isVideo))
                return
            }
            let rwAuth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if rwAuth == .authorized || rwAuth == .limited,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
               PhotoLibraryService.proxyHashPrefixFromAssetResources(asset) != nil {
                completion(PickedMediaResult(assetId: assetId, copiedFileURL: nil, isVideo: isVideo))
                return
            }
        }

        let typeId: String
        if isVideo {
            typeId = registeredVideoId
                ?? videoTypeIds.first { provider.hasItemConformingToTypeIdentifier($0) }
                ?? UTType.movie.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            typeId = provider.registeredTypeIdentifiers.first { tid in
                UTType(tid)?.conforms(to: .image) == true
            } ?? UTType.image.identifier
        } else {
            typeId = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        }

        func finishWithURL(_ sourceURL: URL?, rawData: Data? = nil, suggestedExt: String? = nil) {
            var copiedURL: URL?
            let fallbackExt = suggestedExt ?? (isVideo ? "mp4" : "jpg")
            let batchDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("photohub_incoming_\(UUID().uuidString.prefix(8))", isDirectory: true)
            if let sourceURL {
                let rawName = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseName: String
                if rawName.isEmpty {
                    baseName = "photohub_pick_\(UUID().uuidString.prefix(8)).\(fallbackExt)"
                } else if sourceURL.pathExtension.isEmpty {
                    baseName = "\(rawName).\(fallbackExt)"
                } else {
                    baseName = rawName
                }
                try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
                let dest = batchDir.appendingPathComponent(baseName)
                try? FileManager.default.removeItem(at: dest)
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                if (try? FileManager.default.copyItem(at: sourceURL, to: dest)) != nil {
                    copiedURL = dest
                }
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            } else if let rawData, !rawData.isEmpty {
                let rawHint = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let baseName = rawHint.isEmpty
                    ? "photohub_pick_\(UUID().uuidString.prefix(8)).\(fallbackExt)"
                    : (URL(fileURLWithPath: rawHint).pathExtension.isEmpty ? "\(rawHint).\(fallbackExt)" : rawHint)
                try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
                let dest = batchDir.appendingPathComponent(baseName)
                if (try? rawData.write(to: dest, options: .atomic)) != nil {
                    copiedURL = dest
                }
            }
            if copiedURL == nil {
                try? FileManager.default.removeItem(at: batchDir)
            }
            let out = PickedMediaResult(assetId: assetId, copiedFileURL: copiedURL, isVideo: isVideo)
            DispatchQueue.main.async {
                completion(out)
            }
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
            if let url {
                let ext = url.pathExtension.isEmpty
                    ? UTType(typeId)?.preferredFilenameExtension
                    : url.pathExtension
                finishWithURL(url, suggestedExt: ext)
                return
            }

            // Fallback when NSItemProvider exposes URL/Data (e.g. Shortcuts / Pasteboard videos)
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                if let itemURL = item as? URL {
                    finishWithURL(itemURL, suggestedExt: UTType(typeId)?.preferredFilenameExtension)
                } else if let data = item as? Data {
                    finishWithURL(nil, rawData: data, suggestedExt: UTType(typeId)?.preferredFilenameExtension)
                } else if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { objURL, _ in
                        finishWithURL(objURL, suggestedExt: UTType(typeId)?.preferredFilenameExtension)
                    }
                } else {
                    finishWithURL(nil)
                }
            }
        }
    }
}

/// iOS 15+ PHPicker wrapper returning `assetIdentifier` and (when needed) a temporary file copy for SHA-256 lookup.
struct PhotoPickerSheet: UIViewControllerRepresentable {
    let onPick: (PickedMediaResult) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (PickedMediaResult) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (PickedMediaResult) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let first = results.first else {
                onCancel()
                return
            }
            PhotoPickerItemLoader.loadPickedResult(
                from: first,
                skipCopyIfTracked: true,
                completion: onPick
            )
        }
    }
}

enum IncomingShareState {
    case needsSignIn
    case fetching(completed: Int, total: Int, statusText: String)
    case ready(
        resolved: [ResolvedOriginalDownload],
        unresolved: [OriginalShareInput],
        savedMessage: String?,
        isSavingToPhotos: Bool
    )
    case failed(message: String, unresolved: [OriginalShareInput])
}

struct IncomingShareSession: Identifiable {
    let id = UUID()
    let inputs: [OriginalShareInput]
    let cleanupDirs: [URL]
    var state: IncomingShareState
    var didAutoPresentShareSheet: Bool = false
}

/// Coordinates native Apple Photos / Shortcuts (`AppIntent`), `photohub://share-original`,
/// Files `"Open in photoHub"`, and in-app `"From Photos"` requests into a single share flow.
@MainActor
final class IncomingShareCoordinator: ObservableObject {
    static let shared = IncomingShareCoordinator()

    @Published var activeSession: IncomingShareSession?
    @Published var showingInAppPicker: Bool = false
    @Published var shareSheetItem: ShareSheetItem?

    private var activeTask: Task<Void, Never>?

    private init() {}

    func presentInAppPhotoPicker() {
        showingInAppPicker = true
    }

    func enqueuePickedResults(_ results: [PickedMediaResult]) {
        let inputs = results.map { item -> OriginalShareInput in
            OriginalShareInput(
                assetId: item.assetId,
                fileURL: item.copiedFileURL,
                filenameHint: item.copiedFileURL?.lastPathComponent,
                masterHashHint: nil,
                isVideo: item.isVideo
            )
        }
        let dirs = results.compactMap { $0.copiedFileURL?.deletingLastPathComponent() }
        enqueueInputs(inputs, cleanupDirs: dirs)
    }

    func enqueueInputs(_ inputs: [OriginalShareInput], cleanupDirs: [URL] = []) {
        cleanupActiveResources()
        activeTask?.cancel()
        activeTask = nil
        shareSheetItem = nil

        guard !inputs.isEmpty else {
            cleanupIncomingDirs(cleanupDirs)
            return
        }

        activeSession = IncomingShareSession(
            inputs: inputs,
            cleanupDirs: cleanupDirs,
            state: .fetching(
                completed: 0,
                total: inputs.count,
                statusText: inputs.count > 1
                    ? "Matching \(inputs.count) compressed items..."
                    : "Matching compressed item..."
            )
        )
    }

    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            handleIncomingFileURL(url)
            return
        }

        guard url.scheme?.lowercased() == "photohub" else { return }
        let host = url.host?.lowercased() ?? ""
        if host == "auth" { return }
        guard host == "share-original" else { return }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let hashParam = comps?.queryItems?.first(where: { $0.name == "hash" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nameParam = comps?.queryItems?.first(where: { $0.name == "name" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fromParam = comps?.queryItems?.first(where: { $0.name == "from" })?.value?.lowercased()

        if (hashParam != nil && !hashParam!.isEmpty) || (nameParam != nil && !nameParam!.isEmpty) {
            let ext = URL(fileURLWithPath: nameParam ?? "").pathExtension.lowercased()
            let isVideo = ["mp4", "mov", "m4v", "3gp", "avi"].contains(ext)
            enqueueInputs([
                OriginalShareInput(
                    assetId: nil,
                    fileURL: nil,
                    filenameHint: nameParam,
                    masterHashHint: hashParam,
                    isVideo: isVideo
                )
            ])
            return
        }

        let pb = UIPasteboard.general
        if fromParam == "clipboard" || !pb.itemProviders.isEmpty || pb.hasImages || pb.hasURLs {
            loadInputsFromPasteboard(openPickerIfEmpty: fromParam != "clipboard")
        } else {
            presentInAppPhotoPicker()
        }
    }

    private func handleIncomingFileURL(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default
        let batchDir = fm.temporaryDirectory
            .appendingPathComponent("photohub_incoming_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
        let baseName = url.lastPathComponent.isEmpty ? "media" : url.lastPathComponent
        let destURL = batchDir.appendingPathComponent(baseName)
        try? fm.removeItem(at: destURL)
        guard (try? fm.copyItem(at: url, to: destURL)) != nil else {
            try? fm.removeItem(at: batchDir)
            return
        }

        let ext = destURL.pathExtension.lowercased()
        let isVideo = UTType(filenameExtension: ext)?.conforms(to: .movie) == true
            || ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm"].contains(ext)
        enqueueInputs([
            OriginalShareInput(
                assetId: nil,
                fileURL: destURL,
                filenameHint: baseName,
                masterHashHint: nil,
                isVideo: isVideo
            )
        ], cleanupDirs: [batchDir])
    }

    private func loadInputsFromPasteboard(openPickerIfEmpty: Bool) {
        let providers = UIPasteboard.general.itemProviders
        if !providers.isEmpty {
            let collector = PickedBatchCollector(count: providers.count)
            let group = DispatchGroup()
            for (idx, provider) in providers.enumerated() {
                group.enter()
                PhotoPickerItemLoader.loadItemProvider(
                    provider,
                    assetId: nil,
                    skipCopyIfTracked: false
                ) { picked in
                    collector.store(picked, at: idx)
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                let picked = collector.snapshot().filter { $0.copiedFileURL != nil }
                if !picked.isEmpty {
                    self.enqueuePickedResults(picked)
                } else {
                    self.finishPasteboardFallback(openPickerIfEmpty: openPickerIfEmpty)
                }
            }
            return
        }

        finishPasteboardFallback(openPickerIfEmpty: openPickerIfEmpty)
    }

    private func finishPasteboardFallback(openPickerIfEmpty: Bool) {
        if let str = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            if ProxyGenerator.extractMasterHashPrefix(fromProxyFilename: str) != nil {
                let ext = URL(fileURLWithPath: str).pathExtension.lowercased()
                enqueueInputs([
                    OriginalShareInput(
                        assetId: nil,
                        fileURL: nil,
                        filenameHint: str,
                        masterHashHint: nil,
                        isVideo: ["mp4", "mov", "m4v", "3gp", "avi"].contains(ext)
                    )
                ])
                return
            }
            let hexOnly = str.lowercased().filter { $0.isHexDigit }
            if hexOnly.count >= 8 && hexOnly.count == str.count {
                enqueueInputs([
                    OriginalShareInput(
                        assetId: nil,
                        fileURL: nil,
                        filenameHint: nil,
                        masterHashHint: hexOnly,
                        isVideo: false
                    )
                ])
                return
            }
        }

        if let fileURLs = UIPasteboard.general.urls?.filter({ $0.isFileURL }),
           !fileURLs.isEmpty {
            let fm = FileManager.default
            let batchDir = fm.temporaryDirectory
                .appendingPathComponent("photohub_incoming_\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
            var urlInputs: [OriginalShareInput] = []
            for (idx, srcURL) in fileURLs.enumerated() {
                let rawName = srcURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseName = rawName.isEmpty ? "clipboard_\(idx + 1)" : rawName
                let dest = batchDir.appendingPathComponent(baseName)
                try? fm.removeItem(at: dest)
                let accessed = srcURL.startAccessingSecurityScopedResource()
                let copied = (try? fm.copyItem(at: srcURL, to: dest)) != nil
                if accessed { srcURL.stopAccessingSecurityScopedResource() }
                guard copied else { continue }
                let ext = dest.pathExtension.lowercased()
                let isVid = UTType(filenameExtension: ext)?.conforms(to: .movie) == true
                    || ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm"].contains(ext)
                urlInputs.append(
                    OriginalShareInput(
                        assetId: nil,
                        fileURL: dest,
                        filenameHint: baseName,
                        masterHashHint: nil,
                        isVideo: isVid
                    )
                )
            }
            if !urlInputs.isEmpty {
                enqueueInputs(urlInputs, cleanupDirs: [batchDir])
                return
            }
            try? fm.removeItem(at: batchDir)
        }

        let images = UIPasteboard.general.images ?? []
        if !images.isEmpty {
            let fm = FileManager.default
            let batchDir = fm.temporaryDirectory
                .appendingPathComponent("photohub_incoming_\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
            var inputs: [OriginalShareInput] = []
            for (idx, img) in images.enumerated() {
                guard let data = img.jpegData(compressionQuality: 0.92) else { continue }
                let dest = batchDir.appendingPathComponent("clipboard_\(idx + 1).jpg")
                if (try? data.write(to: dest, options: .atomic)) != nil {
                    inputs.append(
                        OriginalShareInput(
                            assetId: nil,
                            fileURL: dest,
                            filenameHint: dest.lastPathComponent,
                            masterHashHint: nil,
                            isVideo: false
                        )
                    )
                }
            }
            if !inputs.isEmpty {
                enqueueInputs(inputs, cleanupDirs: [batchDir])
                return
            }
            try? fm.removeItem(at: batchDir)
        }

        if openPickerIfEmpty {
            presentInAppPhotoPicker()
        } else {
            activeSession = IncomingShareSession(
                inputs: [],
                cleanupDirs: [],
                state: .failed(
                    message: "Clipboard did not contain a compressed photo, video, or PhotoHub proxy filename.",
                    unresolved: []
                )
            )
        }
    }

    func processIfNeeded(sessionId: UUID, settings: AppSettings) {
        guard var current = activeSession, current.id == sessionId else { return }
        if !settings.isSignedIn || settings.normalizedBaseURL == nil {
            current.state = .needsSignIn
            activeSession = current
            return
        }
        guard case .fetching = current.state else { return }

        let inputs = current.inputs
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            let outcome = await OriginalMediaResolver.resolveAndFetchBatch(
                inputs: inputs,
                settings: settings
            ) { [weak self] completed, total, stage in
                guard let self, var s = self.activeSession, s.id == sessionId else { return }
                s.state = .fetching(completed: completed, total: total, statusText: stage)
                self.activeSession = s
            }

            guard let self, var latest = self.activeSession, latest.id == sessionId, !Task.isCancelled else {
                return
            }

            if outcome.authExpired {
                LocalProxySyncManager.shared.cancel()
                settings.signOut()
                latest.state = .needsSignIn
                self.activeSession = latest
                return
            }

            if outcome.resolved.isEmpty {
                let errMsg = outcome.errorMessage
                    ?? "None of the selected items are linked to a backed-up PhotoHub original."
                latest.state = .failed(message: errMsg, unresolved: outcome.unresolved)
                self.activeSession = latest
                return
            }

            latest.state = .ready(
                resolved: outcome.resolved,
                unresolved: outcome.unresolved,
                savedMessage: nil,
                isSavingToPhotos: false
            )
            if !latest.didAutoPresentShareSheet {
                latest.didAutoPresentShareSheet = true
                self.activeSession = latest
                self.shareSheetItem = ShareSheetItem(fileURLs: outcome.resolved.map(\.fileURL))
            } else {
                self.activeSession = latest
            }
        }
    }

    func retry(settings: AppSettings) {
        guard var current = activeSession else { return }
        let total = current.inputs.count
        current.state = .fetching(
            completed: 0,
            total: total,
            statusText: total > 1 ? "Matching \(total) compressed items..." : "Matching compressed item..."
        )
        current.didAutoPresentShareSheet = false
        activeSession = current
        processIfNeeded(sessionId: current.id, settings: settings)
    }

    func presentResolvedShareSheet() {
        guard let current = activeSession,
              case .ready(let resolved, _, _, _) = current.state,
              !resolved.isEmpty else {
            return
        }
        shareSheetItem = ShareSheetItem(fileURLs: resolved.map(\.fileURL))
    }

    func presentFallbackCopyShareSheet() {
        guard let current = activeSession else { return }
        let fallbackURLs: [URL]
        switch current.state {
        case .ready(_, let unresolved, _, _):
            fallbackURLs = unresolved.compactMap(\.fileURL)
        case .failed(_, let unresolved):
            fallbackURLs = unresolved.compactMap(\.fileURL)
        default:
            fallbackURLs = []
        }
        guard !fallbackURLs.isEmpty else { return }
        shareSheetItem = ShareSheetItem(fileURLs: fallbackURLs)
    }

    func saveResolvedToPhotosAndProtect(settings: AppSettings) {
        guard var current = activeSession,
              case .ready(let resolved, let unresolved, _, let alreadySaving) = current.state,
              !alreadySaving,
              !resolved.isEmpty else {
            return
        }
        current.state = .ready(
            resolved: resolved,
            unresolved: unresolved,
            savedMessage: nil,
            isSavingToPhotos: true
        )
        activeSession = current
        let sessionId = current.id

        Task { [weak self] in
            let authorized = await PhotoLibraryService.requestWriteAuthorizationAsync()
            guard let self, var s = self.activeSession, s.id == sessionId else { return }
            guard authorized else {
                s.state = .ready(
                    resolved: resolved,
                    unresolved: unresolved,
                    savedMessage: "Photos permission is required to save originals.",
                    isSavingToPhotos: false
                )
                self.activeSession = s
                return
            }

            let client = PhotoHubAPIClient(settings: settings)
            var savedCount = 0
            var firstError: String?
            for item in resolved {
                do {
                    let savedId = try await PhotoLibraryService.saveRestoredOriginalToPhotosAsync(
                        isVideo: item.isVideo,
                        originalFilename: item.originalName,
                        creationDate: nil,
                        fileURL: item.fileURL
                    )
                    LocalProxyTracker.shared.markRestoredOriginal(
                        assetId: savedId.isEmpty ? nil : savedId,
                        masterHash: item.masterHash
                    )
                    _ = try? await client.setOriginalProtected(masterHash: item.masterHash, protected: true)
                    savedCount += 1
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }

            guard var latest = self.activeSession, latest.id == sessionId else { return }
            let message = savedCount > 0
                ? "Saved \(savedCount) original(s) to Photos & protected them from re-compression."
                : "Save failed: \(firstError ?? "Unknown error")"
            latest.state = .ready(
                resolved: resolved,
                unresolved: unresolved,
                savedMessage: message,
                isSavingToPhotos: false
            )
            self.activeSession = latest
            NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
        }
    }

    func dismiss() {
        activeTask?.cancel()
        activeTask = nil
        shareSheetItem = nil
        cleanupActiveResources()
        activeSession = nil
    }

    private func cleanupActiveResources() {
        guard let current = activeSession else { return }
        if case .ready(let resolved, _, _, _) = current.state {
            scheduleTempShareCleanup(resolved.map(\.fileURL))
        }
        cleanupIncomingDirs(current.cleanupDirs)
    }

    private func cleanupIncomingDirs(_ dirs: [URL]) {
        for dir in dirs {
            if dir.lastPathComponent.hasPrefix("photohub_incoming_") {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

struct ShareOriginalOverlaySheet: View {
    let session: IncomingShareSession
    let settings: AppSettings
    @ObservedObject var coordinator: IncomingShareCoordinator

    var body: some View {
        AdaptiveNavigationStack {
            VStack(spacing: 16) {
                headerBanner

                switch session.state {
                case .needsSignIn:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sign in to your photoHub account before sharing full-resolution originals from Apple Photos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Close") {
                            coordinator.dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }

                case .fetching(let completed, let total, let statusText):
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.1)
                        if total > 1 {
                            Text("Item \(min(completed + 1, total)) of \(total)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Cancel", role: .cancel) {
                            coordinator.dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)

                case .ready(let resolved, let unresolved, let savedMessage, let isSavingToPhotos):
                    let totalBytes = resolved.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
                    let sizeText = ByteCountFormatter.string(fromByteCount: max(0, totalBytes), countStyle: .file)
                    let summaryTitle = resolved.count == 1
                        ? resolved[0].originalName
                        : "\(resolved.count) full-resolution originals"

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title3)
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summaryTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(sizeText) original · Fetched from server")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

                        if !unresolved.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("\(unresolved.count) selected item(s) had no backed-up original on the server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let savedMessage {
                            Text(savedMessage)
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Button {
                            coordinator.presentResolvedShareSheet()
                        } label: {
                            Label(
                                resolved.count == 1 ? "Share Original" : "Share \(resolved.count) Originals",
                                systemImage: "square.and.arrow.up"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSavingToPhotos)

                        HStack(spacing: 10) {
                            Button {
                                coordinator.saveResolvedToPhotosAndProtect(settings: settings)
                            } label: {
                                HStack(spacing: 6) {
                                    if isSavingToPhotos {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                    }
                                    Text("Save to Photos")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSavingToPhotos)

                            Button("Done") {
                                coordinator.dismiss()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                case .failed(let message, let unresolved):
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                        if unresolved.contains(where: { $0.fileURL != nil }) {
                            Button {
                                coordinator.presentFallbackCopyShareSheet()
                            } label: {
                                Label("Share Selected Copy Instead", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack(spacing: 10) {
                            if !session.inputs.isEmpty {
                                Button("Retry") {
                                    coordinator.retry(settings: settings)
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                            }
                            Button("Close") {
                                coordinator.dismiss()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Share Original")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        coordinator.dismiss()
                    }
                }
            }
        }
        .onAppear {
            coordinator.processIfNeeded(sessionId: session.id, settings: settings)
        }
        .onChange(of: session.id) { newId in
            coordinator.processIfNeeded(sessionId: newId, settings: settings)
        }
        .sheet(item: $coordinator.shareSheetItem) { item in
            ShareSheet(activityItems: item.fileURLs) {
                coordinator.shareSheetItem = nil
            }
        }
    }

    private var headerBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("photoHub · Full-Resolution Original")
                    .font(.subheadline.weight(.semibold))
                Text("Auto-fetch & share from server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
