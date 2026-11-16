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
        var pendingReplacements: [PhotoLibraryService.PendingProxyReplacement] = []
        var succeededIndices: [Int] = []

        for idx in targetIndices {
            if Task.isCancelled { break }
            if let pending = await processSingleCandidate(at: idx, apiClient: apiClient) {
                pendingReplacements.append(pending)
                succeededIndices.append(idx)
            } else {
                failedCount += 1
            }
            completedCount += 1
        }

        // Apply replacement or deletion in a single atomic PhotoKit transaction (prompts iOS Delete confirmation once)
        if !pendingReplacements.isEmpty {
            let keepLocal = settings.keepLocalProxyInPhotos
            do {
                let createdProxyIds = try await photoService.applyBatchReplacementOrDeletion(
                    items: pendingReplacements,
                    keepLocalProxy: keepLocal
                )

                for (i, item) in pendingReplacements.enumerated() {
                    totalSavedBytes += item.savedBytes
                    tracker.markAsProxy(assetId: item.originalAsset.localIdentifier, proxySha256: item.proxySha256)
                    if i < createdProxyIds.count {
                        tracker.markAsProxy(assetId: createdProxyIds[i], proxySha256: item.proxySha256)
                    }
                }

                let completedAssetIds = Set(pendingReplacements.map { $0.originalAsset.localIdentifier })
                candidates.removeAll { completedAssetIds.contains($0.id) }
            } catch {
                for idx in succeededIndices where idx < candidates.count {
                    candidates[idx].state = .failed("Deletion cancelled: \(error.localizedDescription)")
                }
                statusBanner = error.localizedDescription
            }
        }

        isProcessing = false
        let savedStr = ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)
        if failedCount > 0 && statusBanner == nil {
            statusBanner = "Finished with \(failedCount) error(s). Space saved: \(savedStr)."
        } else if failedCount == 0 && statusBanner == nil {
            statusBanner = "Finished! Space saved: \(savedStr). Empty 'Recently Deleted' in Photos to reclaim storage immediately."
        }
    }

    private func processSingleCandidate(
        at index: Int,
        apiClient: PhotoHubAPIClient
    ) async -> PhotoLibraryService.PendingProxyReplacement? {
        let candidate = candidates[index]
        var masterTempURL: URL?
        var proxyTempURL: URL?

        defer {
            if let masterTempURL { try? FileManager.default.removeItem(at: masterTempURL) }
            if let proxyTempURL { try? FileManager.default.removeItem(at: proxyTempURL) }
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

            // 4. Backend checksum confirmed! Generate lightweight local proxy
            candidates[index].state = .creatingProxy
            let format = settings.proxyFormat
            let maxPx = settings.proxyMaxPixelSize
            let quality = settings.proxyQuality

            let proxy = try await Task.detached(priority: .userInitiated) {
                try ProxyGenerator.createProxy(
                    from: master.fileURL,
                    format: format,
                    maxPixelSize: maxPx,
                    quality: quality
                )
            }.value
            proxyTempURL = proxy.fileURL
            let proxyData = try Data(contentsOf: proxy.fileURL)

            // 5. Register proxy hash & upload small compressed preview to server
            candidates[index].state = .replacingInPhotos
            try? await apiClient.registerProxy(
                masterHash: master.sha256,
                proxyHash: proxy.sha256,
                assetId: candidate.id,
                proxyFileURL: proxy.fileURL,
                proxyFormat: format.rawValue
            )

            let saved = settings.keepLocalProxyInPhotos
                ? max(0, master.sizeBytes - proxy.sizeBytes)
                : master.sizeBytes

            return PhotoLibraryService.PendingProxyReplacement(
                originalAsset: candidate.asset,
                proxyData: proxyData,
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
