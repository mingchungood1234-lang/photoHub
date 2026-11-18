import Foundation
import Photos
import SwiftUI
import UIKit

final class CompressorViewModel: ObservableObject {
    @Published var candidates: [PhotoCandidate] = []
    @Published var pendingDeleteAssets: [PHAsset] = []
    @Published var isAwaitingDeleteConfirmation: Bool = false
    @Published var deleteErrorAlertMessage: String?
    @Published var isScanning: Bool = false
    @Published var isProcessing: Bool = false
    @Published var permissionStatus: PHAuthorizationStatus = .notDetermined
    @Published var statusBanner: String?
    @Published var totalSavedBytes: Int64 = 0
    @Published var completedCount: Int = 0
    @Published var totalToProcess: Int = 0

    let settings: AppSettings
    private let photoService = PhotoLibraryService()
    private let tracker = LocalProxyTracker()
    private var pendingAutoDeleteWhenActive: Bool = false

    init(settings: AppSettings) {
        self.settings = settings
        self.permissionStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var selectedCount: Int {
        candidates.filter { $0.isSelected && !$0.state.isFinished }.count
    }

    func scanLibrary() {
        guard !isScanning else { return }
        isScanning = true
        statusBanner = nil

        photoService.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            self.permissionStatus = status

            guard status == .authorized || status == .limited else {
                self.isScanning = false
                self.statusBanner = "Please allow Photos access in iOS Settings to scan your library."
                return
            }

            let service = self.photoService
            let tracker = self.tracker
            DispatchQueue.global(qos: .userInitiated).async {
                let scanned = service.scanCandidates(tracker: tracker)
                DispatchQueue.main.async {
                    self.candidates = scanned
                    self.pendingDeleteAssets.removeAll()
                    self.pendingAutoDeleteWhenActive = false
                    self.isScanning = false
                    if scanned.isEmpty {
                        self.statusBanner = "No uncompressed photos or videos found."
                    }
                }
            }
        }
    }

    func scanAndAutoCompressIfEnabled() {
        guard !isScanning && !isProcessing else { return }
        isScanning = true
        statusBanner = nil

        photoService.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            self.permissionStatus = status
            guard status == .authorized || status == .limited else {
                self.isScanning = false
                return
            }

            let service = self.photoService
            let tracker = self.tracker
            DispatchQueue.global(qos: .userInitiated).async {
                let scanned = service.scanCandidates(tracker: tracker)
                DispatchQueue.main.async {
                    self.candidates = scanned
                    self.isScanning = false
                    if !scanned.isEmpty && self.settings.autoCompressOnOpen {
                        self.selectAllEligible(true)
                        self.startProcessingSelectedPhotos()
                    }
                }
            }
        }
    }

    func loadThumbnailIfNeeded(for id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              candidates[index].thumbnail == nil else {
            return
        }
        let asset = candidates[index].asset
        photoService.loadThumbnail(for: asset) { [weak self] thumb in
            guard let self = self,
                  let thumb = thumb,
                  let currentIndex = self.candidates.firstIndex(where: { $0.id == id }) else {
                return
            }
            if self.candidates[currentIndex].thumbnail == nil {
                self.candidates[currentIndex].thumbnail = thumb
            }
        }
    }

    func toggleSelection(for id: String) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        guard !candidates[idx].state.isFinished else { return }
        candidates[idx].isSelected.toggle()
    }

    func selectAllEligible(_ selected: Bool) {
        for idx in candidates.indices where !candidates[idx].state.isFinished {
            candidates[idx].isSelected = selected
        }
    }

    func startProcessingSelectedPhotos() {
        guard !isProcessing else { return }
        let targetIds = candidates
            .filter { $0.isSelected && !$0.state.isFinished }
            .map { $0.id }
        guard !targetIds.isEmpty else { return }

        isProcessing = true
        completedCount = 0
        totalToProcess = targetIds.count
        statusBanner = nil

        let apiClient = PhotoHubAPIClient(settings: settings)
        let format = settings.proxyFormat
        let maxPx = settings.proxyMaxPixelSize
        let quality = settings.proxyQuality
        let uploadMode = settings.uploadMode
        let keepLocal = settings.keepLocalProxyInPhotos
        let normalizedBaseURL = settings.normalizedBaseURL
        let apiKey = settings.apiKey

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            do {
                _ = try await apiClient.whoami()
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusBanner = "Server/Key check failed (\(self.settings.serverURL)): \(error.localizedDescription)"
                }
                return
            }

            let queue = AsyncWorkQueue(targetIds)
            let videoSemaphore = AsyncSemaphore(value: 1)
            let photosSaveSemaphore = AsyncSemaphore(value: 1)
            let workerCount = min(3, targetIds.count)

            let failedCount = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        var workerFailures = 0
                        while let nextId = await queue.next() {
                            let ok = await self.processSingleCandidate(
                                id: nextId,
                                apiClient: apiClient,
                                format: format,
                                maxPx: maxPx,
                                quality: quality,
                                uploadMode: uploadMode,
                                keepLocal: keepLocal,
                                normalizedBaseURL: normalizedBaseURL,
                                apiKey: apiKey,
                                videoSemaphore: videoSemaphore,
                                photosSaveSemaphore: photosSaveSemaphore
                            )
                            if !ok {
                                workerFailures += 1
                            }
                        }
                        return workerFailures
                    }
                }

                var totalFailures = 0
                for await workerFailures in group {
                    totalFailures += workerFailures
                }
                return totalFailures
            }

            await MainActor.run {
                self.isProcessing = false
                let savedStr = ByteCountFormatter.string(fromByteCount: self.totalSavedBytes, countStyle: .file)
                if !self.pendingDeleteAssets.isEmpty {
                    self.scheduleAutomaticDeletePrompt()
                } else if failedCount > 0 && self.statusBanner == nil {
                    self.statusBanner = "Finished with \(failedCount) error(s). Space saved: \(savedStr)."
                } else if failedCount == 0 {
                    self.statusBanner = "Finished! Space saved: \(savedStr)."
                }
            }
        }
    }

    private func processSingleCandidate(
        id currentId: String,
        apiClient: PhotoHubAPIClient,
        format: ProxyFormat,
        maxPx: Int,
        quality: Double,
        uploadMode: UploadMode,
        keepLocal: Bool,
        normalizedBaseURL: URL?,
        apiKey: String,
        videoSemaphore: AsyncSemaphore,
        photosSaveSemaphore: AsyncSemaphore
    ) async -> Bool {
        let candidate: PhotoCandidate? = await MainActor.run {
            guard let index = self.candidates.firstIndex(where: { $0.id == currentId }) else {
                return nil
            }
            self.candidates[index].state = .hashing
            return self.candidates[index]
        }

        guard let candidate else {
            await MainActor.run { self.completedCount += 1 }
            return true
        }

        do {
            // Step 1: Export full-resolution original & compute SHA-256
            let master = try await photoService.exportOriginalMasterAsync(for: candidate.asset)
            defer { try? FileManager.default.removeItem(at: master.fileURL) }

            // Step 2: Check server & upload if not already backed up
            let checkResult = try await apiClient.checkHash(master.sha256)
            let needsUpload = !(checkResult.exists && checkResult.isMaster == true && checkResult.canReplaceWithProxy == true)

            if needsUpload {
                self.updateStateOnMain(id: currentId, state: .uploading(0))
                let progressHandler: (Double) -> Void = { [weak self] progress in
                    self?.updateStateOnMain(id: currentId, state: .uploading(progress))
                }

                switch uploadMode {
                case .directVPS:
                    _ = try await apiClient.uploadMasterDirect(
                        fileURL: master.fileURL,
                        filename: master.filename,
                        mimeType: master.mimeType,
                        createdAt: candidate.creationDate,
                        expectedSha256: master.sha256,
                        onProgress: progressHandler
                    )
                case .s3Presigned:
                    _ = try await apiClient.uploadMasterPresigned(
                        fileURL: master.fileURL,
                        filename: master.filename,
                        mimeType: master.mimeType,
                        createdAt: candidate.creationDate,
                        expectedSha256: master.sha256,
                        onProgress: progressHandler
                    )
                }
            }

            // Step 3: Create lightweight proxy (limit heavy video transcoding to 1 at a time)
            self.updateStateOnMain(id: currentId, state: .creatingProxy)
            let proxy: GeneratedProxy
            let previewFileForServer: URL?
            let previewFormatForServer: String
            let videoProxyFileForServer: URL?

            if candidate.mediaType == .video {
                await videoSemaphore.acquire()
                do {
                    proxy = try await ProxyGenerator.createVideoProxy(from: master.fileURL)
                    await videoSemaphore.release()
                } catch {
                    await videoSemaphore.release()
                    throw error
                }
                previewFileForServer = proxy.posterFileURL
                previewFormatForServer = "jpeg"
                videoProxyFileForServer = proxy.fileURL
            } else {
                proxy = try ProxyGenerator.createProxy(
                    from: master.fileURL,
                    format: format,
                    maxPixelSize: maxPx,
                    quality: quality
                )
                previewFileForServer = proxy.fileURL
                previewFormatForServer = format.rawValue
                videoProxyFileForServer = nil
            }

            try? FileManager.default.removeItem(at: master.fileURL)
            defer {
                try? FileManager.default.removeItem(at: proxy.fileURL)
                if let posterURL = proxy.posterFileURL {
                    try? FileManager.default.removeItem(at: posterURL)
                }
            }

            // Step 4: Register proxy on server (streams video proxy binary) & persist in LocalProxyStore
            try? await apiClient.registerProxy(
                masterHash: master.sha256,
                proxyHash: proxy.sha256,
                assetId: candidate.id,
                proxyFileURL: previewFileForServer,
                proxyFormat: previewFormatForServer,
                videoProxyURL: videoProxyFileForServer
            )

            if let previewURL = previewFileForServer {
                LocalProxyStore.shared.copyPreviewFile(from: previewURL, forHash: master.sha256)
            }
            if candidate.mediaType == .video {
                LocalProxyStore.shared.copyVideoProxy(from: proxy.fileURL, forHash: master.sha256)
            }

            let iso = ISO8601DateFormatter()
            let nowISO = iso.string(from: Date())
            let photoISO = candidate.creationDate.map { iso.string(from: $0) } ?? nowISO
            let posterSize: Int64? = {
                guard let previewURL = previewFileForServer,
                      let values = try? previewURL.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize else {
                    return nil
                }
                return Int64(size)
            }()
            LocalProxyStore.shared.upsertPhoto(
                ServerPhoto(
                    hash: master.sha256,
                    originalName: master.filename,
                    size: master.sizeBytes,
                    photoDate: photoISO,
                    uploadedAt: nowISO,
                    savedPath: checkResult.savedPath ?? master.filename,
                    hasProxy: true,
                    hasPreview: previewFileForServer != nil,
                    proxyHash: proxy.sha256,
                    proxySize: candidate.mediaType == .video ? posterSize : proxy.sizeBytes,
                    hasVideoProxy: candidate.mediaType == .video,
                    videoProxySize: candidate.mediaType == .video ? proxy.sizeBytes : nil
                ),
                baseURL: normalizedBaseURL,
                apiKey: apiKey
            )

            // Step 5: Save compressed proxy to Photos (serialized for photolibraryd stability)
            let savedBytes = keepLocal
                ? max(0, master.sizeBytes - proxy.sizeBytes)
                : master.sizeBytes

            if keepLocal {
                self.updateStateOnMain(id: currentId, state: .replacingInPhotos)
                await photosSaveSemaphore.acquire()
                let newAssetId: String
                do {
                    newAssetId = try await photoService.saveCompressedProxyToPhotosAsync(
                        originalAsset: candidate.asset,
                        mediaType: candidate.mediaType,
                        proxyFileURL: proxy.fileURL
                    )
                    await photosSaveSemaphore.release()
                } catch {
                    await photosSaveSemaphore.release()
                    throw error
                }

                if newAssetId != candidate.id {
                    self.tracker.markAsProxy(
                        assetId: newAssetId,
                        proxySha256: proxy.sha256,
                        masterHash: master.sha256,
                        originalName: master.filename
                    )
                }
            }

            await MainActor.run {
                self.stageOriginalForDeletion(
                    id: currentId,
                    asset: candidate.asset,
                    savedBytes: savedBytes
                )
                self.completedCount += 1
            }
            return true
        } catch {
            await MainActor.run {
                self.updateState(id: currentId, state: .failed(error.localizedDescription))
                self.statusBanner = error.localizedDescription
                self.completedCount += 1
            }
            return false
        }
    }

    private func stageOriginalForDeletion(id: String, asset: PHAsset, savedBytes: Int64) {
        if let idx = candidates.firstIndex(where: { $0.id == id }) {
            candidates[idx].state = .readyToDelete(savedBytes: savedBytes)
            candidates[idx].isSelected = false
        }
        if !pendingDeleteAssets.contains(where: { $0.localIdentifier == asset.localIdentifier }) {
            pendingDeleteAssets.append(asset)
        }
        totalSavedBytes += savedBytes
    }

    /// Automatically pops up the native iOS delete confirmation dialog shortly after upload + proxy save completes.
    func scheduleAutomaticDeletePrompt() {
        guard !pendingDeleteAssets.isEmpty, !isAwaitingDeleteConfirmation else { return }

        isAwaitingDeleteConfirmation = true
        statusBanner = "Backed up & compressed \(pendingDeleteAssets.count) item(s). Opening iOS delete alert…"

        // Wait briefly on the main runloop so SwiftUI finishes closing the progress bar
        // and photolibraryd finishes indexing newly saved proxies.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self,
                  self.isAwaitingDeleteConfirmation,
                  !self.pendingDeleteAssets.isEmpty else {
                return
            }

            guard UIApplication.shared.applicationState == .active else {
                self.isAwaitingDeleteConfirmation = false
                self.pendingAutoDeleteWhenActive = true
                self.statusBanner = "Backed up & compressed! Return to photoHub to confirm the iOS delete alert for \(self.pendingDeleteAssets.count) original(s)."
                return
            }

            self.performDelete(assets: self.pendingDeleteAssets)
        }
    }

    func onAppBecameActive() {
        guard pendingAutoDeleteWhenActive,
              !pendingDeleteAssets.isEmpty,
              !isAwaitingDeleteConfirmation,
              !isProcessing else {
            return
        }
        pendingAutoDeleteWhenActive = false
        scheduleAutomaticDeletePrompt()
    }

    func retryPendingDeleteAlert() {
        guard !pendingDeleteAssets.isEmpty, !isAwaitingDeleteConfirmation else { return }
        pendingAutoDeleteWhenActive = false
        isAwaitingDeleteConfirmation = true
        performDelete(assets: pendingDeleteAssets)
    }

    func dismissPendingDeleteAfterError() {
        let pendingIds = Set(pendingDeleteAssets.map { $0.localIdentifier })
        for idx in candidates.indices where pendingIds.contains(candidates[idx].id) {
            candidates[idx].state = .skipped("Backed up • Original kept")
            candidates[idx].isSelected = false
        }
        pendingDeleteAssets.removeAll()
        pendingAutoDeleteWhenActive = false
        deleteErrorAlertMessage = nil
    }

    private func performDelete(assets: [PHAsset]) {
        let targetIds = Set(assets.map { $0.localIdentifier })
        photoService.deleteOriginalAssets(assets) { [weak self] result in
            guard let self = self else { return }
            self.isAwaitingDeleteConfirmation = false

            switch result {
            case .success(.deleted(let deletedIds)):
                let deletedSet = Set(deletedIds)
                self.candidates.removeAll { deletedSet.contains($0.id) }
                self.pendingDeleteAssets.removeAll { deletedSet.contains($0.localIdentifier) }

                let savedStr = ByteCountFormatter.string(fromByteCount: self.totalSavedBytes, countStyle: .file)
                if self.pendingDeleteAssets.isEmpty {
                    self.statusBanner = "Deleted \(deletedSet.count) original(s) from iPhone! Space saved: \(savedStr). Empty 'Recently Deleted' in Photos to reclaim storage immediately."
                } else {
                    self.statusBanner = "Deleted \(deletedSet.count) original(s). \(self.pendingDeleteAssets.count) item(s) still remain."
                }

            case .success(.cancelledByUser):
                for idx in self.candidates.indices where targetIds.contains(self.candidates[idx].id) {
                    self.candidates[idx].state = .skipped("Backed up • Kept on iPhone")
                    self.candidates[idx].isSelected = false
                }
                self.pendingDeleteAssets.removeAll { targetIds.contains($0.localIdentifier) }
                self.statusBanner = "Kept original photo(s) on iPhone."

            case .failure(let error):
                self.statusBanner = error.localizedDescription
                self.deleteErrorAlertMessage = error.localizedDescription
            }
        }
    }

    private func updateState(id: String, state: PhotoCompressionState) {
        if let idx = candidates.firstIndex(where: { $0.id == id }) {
            candidates[idx].state = state
        }
    }

    private func updateStateOnMain(id: String, state: PhotoCompressionState) {
        DispatchQueue.main.async { [weak self] in
            self?.updateState(id: id, state: state)
        }
    }
}
