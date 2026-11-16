import Foundation
import Photos
import SwiftUI

@MainActor
final class CompressorViewModel: ObservableObject {
    @Published var candidates: [PhotoCandidate] = []
    @Published var isScanning: Bool = false
    @Published var isProcessing: Bool = false
    @Published var permissionStatus: PHAuthorizationStatus = .notDetermined
    @Published var statusBanner: String?
    @Published var totalSavedBytes: Int64 = 0
    @Published var completedCount: Int = 0
    @Published var totalToProcess: Int = 0
    @Published var readyToDeleteItems: [PhotoLibraryService.PendingProxyReplacement] = []
    @Published var isDeletingOriginals: Bool = false

    let settings: AppSettings
    private let photoService = PhotoLibraryService()
    private let tracker = LocalProxyTracker()

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

            // Run fetch on background queue, then assign on main thread
            let service = self.photoService
            let tracker = self.tracker
            DispatchQueue.global(qos: .userInitiated).async {
                let scanned = service.scanCandidates(tracker: tracker)
                DispatchQueue.main.async {
                    self.candidates = scanned
                    self.isScanning = false
                    if scanned.isEmpty {
                        self.statusBanner = "No photos found in photo library."
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
                        Task { await self.processSelectedPhotos() }
                    }
                }
            }
        }
    }

    func loadThumbnailIfNeeded(for id: String) async {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              candidates[index].thumbnail == nil else {
            return
        }
        let asset = candidates[index].asset
        if let thumb = await photoService.loadThumbnail(for: asset) {
            if let currentIndex = candidates.firstIndex(where: { $0.id == id }) {
                candidates[currentIndex].thumbnail = thumb
            }
        }
    }

    func toggleSelection(for id: String) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        if case .readyToDelete = candidates[idx].state {
            deleteReadyOriginalsFromDevice()
            return
        }
        guard !candidates[idx].state.isFinished else { return }
        candidates[idx].isSelected.toggle()
    }

    func selectAllEligible(_ selected: Bool) {
        for idx in candidates.indices where !candidates[idx].state.isFinished {
            candidates[idx].isSelected = selected
        }
    }

    func processSelectedPhotos() async {
        let targetIndices = candidates.indices.filter {
            candidates[$0].isSelected && !candidates[$0].state.isFinished
        }
        guard !targetIndices.isEmpty else { return }

        isProcessing = true
        completedCount = 0
        totalToProcess = targetIndices.count
        statusBanner = nil

        let apiClient = PhotoHubAPIClient(settings: settings)

        do {
            _ = try await apiClient.whoami()
        } catch {
            isProcessing = false
            statusBanner = "Server/Key check failed (\(settings.serverURL)): \(error.localizedDescription). Check Server URL and User Key in Settings."
            return
        }

        var failedCount = 0
        for idx in targetIndices {
            if Task.isCancelled { break }
            if let pending = await processSingleCandidate(at: idx, apiClient: apiClient) {
                readyToDeleteItems.append(pending)
                candidates[idx].state = .readyToDelete(savedBytes: pending.savedBytes)
                candidates[idx].isSelected = false
            } else {
                failedCount += 1
            }
            completedCount += 1
        }

        isProcessing = false

        guard !readyToDeleteItems.isEmpty else {
            if failedCount > 0 && statusBanner == nil {
                statusBanner = "Finished with \(failedCount) error(s)."
            }
            return
        }

        statusBanner = "Backed up \(readyToDeleteItems.count) item(s)! Tap the red 'Delete' button below to remove the original(s) from your iPhone."
    }

    func deleteReadyOriginalsFromDevice() {
        let items = readyToDeleteItems
        guard !items.isEmpty else {
            statusBanner = "No backed-up items waiting for deletion."
            return
        }

        isDeletingOriginals = true
        statusBanner = "Asking iOS Photos to delete \(items.count) original item(s)…"

        let keepLocal = settings.keepLocalProxyInPhotos
        photoService.performBatchDeleteAndOptionalProxySave(
            items: items,
            keepLocalProxy: keepLocal
        ) { [weak self] result in
            guard let self = self else { return }
            self.isDeletingOriginals = false
            switch result {
            case .success(let createdProxyIds):
                for (i, item) in items.enumerated() {
                    self.totalSavedBytes += item.savedBytes
                    self.tracker.markAsProxy(
                        assetId: item.originalAsset.localIdentifier,
                        proxySha256: item.proxySha256
                    )
                    if i < createdProxyIds.count {
                        self.tracker.markAsProxy(
                            assetId: createdProxyIds[i],
                            proxySha256: item.proxySha256
                        )
                    }
                }

                let completedAssetIds = Set(items.map { $0.originalAsset.localIdentifier })
                self.candidates.removeAll { completedAssetIds.contains($0.id) }
                self.readyToDeleteItems.removeAll()

                let savedStr = ByteCountFormatter.string(fromByteCount: self.totalSavedBytes, countStyle: .file)
                self.statusBanner = "Success! Deleted \(items.count) original photo(s). Space saved: \(savedStr)."

            case .failure(let error):
                self.statusBanner = "Delete error: \(error.localizedDescription)"
            }
        }
    }

    private func processSingleCandidate(
        at index: Int,
        apiClient: PhotoHubAPIClient
    ) async -> PhotoLibraryService.PendingProxyReplacement? {
        let candidate = candidates[index]
        var masterTempURL: URL?
        var proxyImageTempURL: URL?
        var posterTempURL: URL?

        defer {
            if let masterTempURL { try? FileManager.default.removeItem(at: masterTempURL) }
            if let proxyImageTempURL { try? FileManager.default.removeItem(at: proxyImageTempURL) }
            if let posterTempURL { try? FileManager.default.removeItem(at: posterTempURL) }
        }

        do {
            // 1. Export full-resolution original & compute SHA-256
            candidates[index].state = .hashing
            let master = try await photoService.exportOriginalMaster(for: candidate.asset)
            masterTempURL = master.fileURL

            // 2. Check server to see if master is already backed up
            let checkResult = try await apiClient.checkHash(master.sha256)

            // 3. Upload full-resolution original if not already verified on backend
            let needsUpload = !(checkResult.exists && checkResult.isMaster == true && checkResult.canReplaceWithProxy == true)
            if needsUpload {
                candidates[index].state = .uploading(0)
                let progressHandler: (Double) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        guard let self, index < self.candidates.count else { return }
                        self.candidates[index].state = .uploading(progress)
                    }
                }

                switch settings.uploadMode {
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

            // 4. Backend checksum confirmed! Generate lightweight local proxy (Photo or Video)
            candidates[index].state = .creatingProxy
            let format = settings.proxyFormat
            let maxPx = settings.proxyMaxPixelSize
            let quality = settings.proxyQuality

            let proxy: GeneratedProxy
            let proxyData: Data?
            let proxyVideoURL: URL?
            let previewFileForServer: URL?
            let previewFormatForServer: String

            if candidate.mediaType == .video {
                proxy = try await ProxyGenerator.createVideoProxy(from: master.fileURL)
                posterTempURL = proxy.posterFileURL
                proxyData = nil
                proxyVideoURL = proxy.fileURL
                previewFileForServer = proxy.posterFileURL
                previewFormatForServer = "jpeg"
            } else {
                proxy = try await Task.detached(priority: .userInitiated) {
                    try ProxyGenerator.createProxy(
                        from: master.fileURL,
                        format: format,
                        maxPixelSize: maxPx,
                        quality: quality
                    )
                }.value
                proxyImageTempURL = proxy.fileURL
                proxyData = try Data(contentsOf: proxy.fileURL)
                proxyVideoURL = nil
                previewFileForServer = proxy.fileURL
                previewFormatForServer = format.rawValue
            }

            // 5. Register proxy hash & upload small compressed preview to server
            candidates[index].state = .replacingInPhotos
            try? await apiClient.registerProxy(
                masterHash: master.sha256,
                proxyHash: proxy.sha256,
                assetId: candidate.id,
                proxyFileURL: previewFileForServer,
                proxyFormat: previewFormatForServer
            )

            let saved = settings.keepLocalProxyInPhotos
                ? max(0, master.sizeBytes - proxy.sizeBytes)
                : master.sizeBytes

            return PhotoLibraryService.PendingProxyReplacement(
                originalAsset: candidate.asset,
                mediaType: candidate.mediaType,
                proxyData: proxyData,
                proxyVideoURL: proxyVideoURL,
                proxySha256: proxy.sha256,
                savedBytes: saved
            )
        } catch {
            candidates[index].state = .failed(error.localizedDescription)
            statusBanner = error.localizedDescription
            return nil
        }
    }
}
