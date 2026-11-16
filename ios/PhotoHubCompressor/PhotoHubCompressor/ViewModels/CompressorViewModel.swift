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
        guard !candidates[idx].state.isFinished else { return }
        candidates[idx].isSelected.toggle()
    }

    func selectAllEligible(_ selected: Bool) {
        for idx in candidates.indices where !candidates[idx].state.isFinished {
            candidates[idx].isSelected = selected
        }
    }

    func processSelectedPhotos() async {
        let targetIds = candidates
            .filter { $0.isSelected && !$0.state.isFinished }
            .map { $0.id }
        guard !targetIds.isEmpty else { return }

        isProcessing = true
        completedCount = 0
        totalToProcess = targetIds.count
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
        for itemId in targetIds {
            if Task.isCancelled { break }
            let ok = await processSingleCandidate(id: itemId, apiClient: apiClient)
            if !ok { failedCount += 1 }
            completedCount += 1
        }

        isProcessing = false
        let savedStr = ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)
        if failedCount > 0 && statusBanner == nil {
            statusBanner = "Finished with \(failedCount) error(s). Space saved: \(savedStr)."
        } else if failedCount == 0 {
            statusBanner = "Finished! Space saved: \(savedStr). Empty 'Recently Deleted' in Photos to reclaim storage immediately."
        }
    }

    @discardableResult
    private func processSingleCandidate(
        id: String,
        apiClient: PhotoHubAPIClient
    ) async -> Bool {
        guard let initialIndex = candidates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let candidate = candidates[initialIndex]
        var masterTempURL: URL?
        var proxyTempURL: URL?
        var posterTempURL: URL?

        func updateState(_ newState: PhotoCompressionState) {
            if let idx = candidates.firstIndex(where: { $0.id == id }) {
                candidates[idx].state = newState
            }
        }

        defer {
            if let masterTempURL { try? FileManager.default.removeItem(at: masterTempURL) }
            if let proxyTempURL { try? FileManager.default.removeItem(at: proxyTempURL) }
            if let posterTempURL { try? FileManager.default.removeItem(at: posterTempURL) }
        }

        do {
            // 1. Export full-resolution original & compute SHA-256
            updateState(.hashing)
            let master = try await photoService.exportOriginalMaster(for: candidate.asset)
            masterTempURL = master.fileURL

            // 2. Check server to see if master is already backed up
            let checkResult = try await apiClient.checkHash(master.sha256)

            // 3. Upload full-resolution original if not already verified on backend
            let needsUpload = !(checkResult.exists && checkResult.isMaster == true && checkResult.canReplaceWithProxy == true)
            if needsUpload {
                updateState(.uploading(0))
                let progressHandler: (Double) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        guard let self, let idx = self.candidates.firstIndex(where: { $0.id == id }) else { return }
                        self.candidates[idx].state = .uploading(progress)
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
            updateState(.creatingProxy)
            let format = settings.proxyFormat
            let maxPx = settings.proxyMaxPixelSize
            let quality = settings.proxyQuality

            let proxy: GeneratedProxy
            let previewFileForServer: URL?
            let previewFormatForServer: String

            if candidate.mediaType == .video {
                proxy = try await ProxyGenerator.createVideoProxy(from: master.fileURL)
                posterTempURL = proxy.posterFileURL
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
                previewFileForServer = proxy.fileURL
                previewFormatForServer = format.rawValue
            }
            proxyTempURL = proxy.fileURL

            // 5. Register proxy hash & upload small compressed preview to server BEFORE PhotoKit prompt
            try? await apiClient.registerProxy(
                masterHash: master.sha256,
                proxyHash: proxy.sha256,
                assetId: candidate.id,
                proxyFileURL: previewFileForServer,
                proxyFormat: previewFormatForServer
            )

            // 6. Delete original & save lightweight proxy in native Photos app
            updateState(.replacingInPhotos)
            let newAssetId = try await photoService.replaceWithProxy(
                originalAsset: candidate.asset,
                mediaType: candidate.mediaType,
                proxyFileURL: proxy.fileURL,
                keepLocalProxy: settings.keepLocalProxyInPhotos
            )

            tracker.markAsProxy(assetId: candidate.id, proxySha256: proxy.sha256)
            tracker.markAsProxy(assetId: newAssetId, proxySha256: proxy.sha256)

            let saved = settings.keepLocalProxyInPhotos
                ? max(0, master.sizeBytes - proxy.sizeBytes)
                : master.sizeBytes
            totalSavedBytes += saved
            candidates.removeAll { $0.id == id }
            return true
        } catch {
            updateState(.failed(error.localizedDescription))
            statusBanner = error.localizedDescription
            return false
        }
    }
}
