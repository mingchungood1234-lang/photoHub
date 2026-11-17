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

            self.processNextItem(remainingIds: targetIds, failedCount: 0, apiClient: apiClient)
        }
    }

    private func processNextItem(
        remainingIds: [String],
        failedCount: Int,
        apiClient: PhotoHubAPIClient
    ) {
        guard let currentId = remainingIds.first else {
            DispatchQueue.main.async {
                self.isProcessing = false
                let savedStr = ByteCountFormatter.string(fromByteCount: self.totalSavedBytes, countStyle: .file)
                if !self.pendingDeleteAssets.isEmpty {
                    if self.settings.autoDeletePromptAfterUpload {
                        self.scheduleAutomaticDeletePrompt()
                    } else {
                        self.statusBanner = "Backed up & compressed! Tap the red 'Delete Original Photo(s)' button below to remove \(self.pendingDeleteAssets.count) original(s) (\(savedStr))."
                    }
                } else if failedCount > 0 && self.statusBanner == nil {
                    self.statusBanner = "Finished with \(failedCount) error(s). Space saved: \(savedStr)."
                } else if failedCount == 0 {
                    self.statusBanner = "Finished! Space saved: \(savedStr)."
                }
            }
            return
        }

        let restIds = Array(remainingIds.dropFirst())

        DispatchQueue.main.async {
            guard let index = self.candidates.firstIndex(where: { $0.id == currentId }) else {
                self.completedCount += 1
                self.processNextItem(remainingIds: restIds, failedCount: failedCount, apiClient: apiClient)
                return
            }

            let candidate = self.candidates[index]
            self.candidates[index].state = .hashing

            // Step 1: Export original master via callback
            self.photoService.exportOriginalMaster(for: candidate.asset) { [weak self] exportResult in
                guard let self = self else { return }

                switch exportResult {
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.updateState(id: currentId, state: .failed(error.localizedDescription))
                        self.statusBanner = error.localizedDescription
                        self.completedCount += 1
                        self.processNextItem(remainingIds: restIds, failedCount: failedCount + 1, apiClient: apiClient)
                    }

                case .success(let master):
                    // Step 2: Upload master & generate proxy on background Task
                    Task.detached(priority: .userInitiated) { [weak self] in
                        guard let self = self else {
                            try? FileManager.default.removeItem(at: master.fileURL)
                            return
                        }

                        do {
                            let checkResult = try await apiClient.checkHash(master.sha256)
                            let needsUpload = !(checkResult.exists && checkResult.isMaster == true && checkResult.canReplaceWithProxy == true)

                            if needsUpload {
                                self.updateStateOnMain(id: currentId, state: .uploading(0))
                                let progressHandler: (Double) -> Void = { [weak self] progress in
                                    self?.updateStateOnMain(id: currentId, state: .uploading(progress))
                                }

                                switch self.settings.uploadMode {
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

                            // Step 3: Create lightweight proxy
                            self.updateStateOnMain(id: currentId, state: .creatingProxy)
                            let format = self.settings.proxyFormat
                            let maxPx = self.settings.proxyMaxPixelSize
                            let quality = self.settings.proxyQuality

                            let proxy: GeneratedProxy
                            let previewFileForServer: URL?
                            let previewFormatForServer: String

                            if candidate.mediaType == .video {
                                proxy = try await ProxyGenerator.createVideoProxy(from: master.fileURL)
                                previewFileForServer = proxy.posterFileURL
                                previewFormatForServer = "jpeg"
                            } else {
                                proxy = try ProxyGenerator.createProxy(
                                    from: master.fileURL,
                                    format: format,
                                    maxPixelSize: maxPx,
                                    quality: quality
                                )
                                previewFileForServer = proxy.fileURL
                                previewFormatForServer = format.rawValue
                            }

                            try? FileManager.default.removeItem(at: master.fileURL)

                            // Step 4: Register proxy on server
                            try? await apiClient.registerProxy(
                                masterHash: master.sha256,
                                proxyHash: proxy.sha256,
                                assetId: candidate.id,
                                proxyFileURL: previewFileForServer,
                                proxyFormat: previewFormatForServer
                            )
                            if let posterURL = proxy.posterFileURL {
                                try? FileManager.default.removeItem(at: posterURL)
                            }

                            // Step 5: Save compressed proxy to Photos (if enabled), then stage original asset for synchronous user-tap deletion
                            let keepLocal = self.settings.keepLocalProxyInPhotos
                            let savedBytes = keepLocal
                                ? max(0, master.sizeBytes - proxy.sizeBytes)
                                : master.sizeBytes

                            if keepLocal {
                                self.updateStateOnMain(id: currentId, state: .replacingInPhotos)
                                DispatchQueue.main.async {
                                    self.photoService.saveCompressedProxyToPhotos(
                                        originalAsset: candidate.asset,
                                        mediaType: candidate.mediaType,
                                        proxyFileURL: proxy.fileURL
                                    ) { [weak self] saveResult in
                                        try? FileManager.default.removeItem(at: proxy.fileURL)
                                        guard let self = self else { return }

                                        switch saveResult {
                                        case .success(let newAssetId):
                                            if newAssetId != candidate.id {
                                                self.tracker.markAsProxy(assetId: newAssetId, proxySha256: proxy.sha256)
                                            }
                                            self.stageOriginalForDeletion(
                                                id: currentId,
                                                asset: candidate.asset,
                                                savedBytes: savedBytes
                                            )
                                            self.completedCount += 1
                                            self.processNextItem(remainingIds: restIds, failedCount: failedCount, apiClient: apiClient)

                                        case .failure(let error):
                                            self.updateState(id: currentId, state: .failed(error.localizedDescription))
                                            self.statusBanner = error.localizedDescription
                                            self.completedCount += 1
                                            self.processNextItem(remainingIds: restIds, failedCount: failedCount + 1, apiClient: apiClient)
                                        }
                                    }
                                }
                            } else {
                                try? FileManager.default.removeItem(at: proxy.fileURL)
                                DispatchQueue.main.async {
                                    self.stageOriginalForDeletion(
                                        id: currentId,
                                        asset: candidate.asset,
                                        savedBytes: savedBytes
                                    )
                                    self.completedCount += 1
                                    self.processNextItem(remainingIds: restIds, failedCount: failedCount, apiClient: apiClient)
                                }
                            }
                        } catch {
                            try? FileManager.default.removeItem(at: master.fileURL)
                            DispatchQueue.main.async {
                                self.updateState(id: currentId, state: .failed(error.localizedDescription))
                                self.statusBanner = error.localizedDescription
                                self.completedCount += 1
                                self.processNextItem(remainingIds: restIds, failedCount: failedCount + 1, apiClient: apiClient)
                            }
                        }
                    }
                }
            }
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
        statusBanner = "Backed up & compressed \(pendingDeleteAssets.count) item(s). Opening iOS delete confirmation…"

        // Wait briefly on the main runloop so SwiftUI finishes closing the progress bar
        // and photolibraryd finishes indexing newly saved proxies.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self,
                  self.isAwaitingDeleteConfirmation,
                  !self.pendingDeleteAssets.isEmpty else {
                return
            }

            guard UIApplication.shared.applicationState == .active else {
                self.isAwaitingDeleteConfirmation = false
                self.pendingAutoDeleteWhenActive = true
                self.statusBanner = "Backed up & compressed! Return to photoHub to confirm deleting \(self.pendingDeleteAssets.count) original(s)."
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

    func deleteOriginalsFromUserTap() {
        guard !pendingDeleteAssets.isEmpty, !isAwaitingDeleteConfirmation else { return }
        pendingAutoDeleteWhenActive = false
        isAwaitingDeleteConfirmation = true
        performDelete(assets: pendingDeleteAssets)
    }

    func deleteSingleOriginalFromUserTap(id: String) {
        guard !isAwaitingDeleteConfirmation,
              let asset = pendingDeleteAssets.first(where: { $0.localIdentifier == id })
                ?? candidates.first(where: { $0.id == id })?.asset else {
            return
        }

        pendingAutoDeleteWhenActive = false
        isAwaitingDeleteConfirmation = true
        performDelete(assets: [asset])
    }

    private func performDelete(assets: [PHAsset]) {
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
                self.statusBanner = "Original photo(s) kept on iPhone. Tap the red Delete button below anytime to delete them."

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
