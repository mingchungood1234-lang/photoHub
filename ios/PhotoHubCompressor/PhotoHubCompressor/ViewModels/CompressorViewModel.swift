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
        for idx in targetIndices {
            if Task.isCancelled { break }
            let ok = await processSingleCandidate(at: idx, apiClient: apiClient)
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
    private func processSingleCandidate(at index: Int, apiClient: PhotoHubAPIClient) async -> Bool {
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

            // 5. Replace original in native Photos app with lightweight proxy (triggers iOS Delete confirmation prompt!)
            candidates[index].state = .replacingInPhotos
            let newAssetId = try await photoService.replaceWithProxy(
                originalAsset: candidate.asset,
                proxyFileURL: proxy.fileURL
            )

            // 6. Register proxy hash & upload small compressed preview to server
            tracker.markAsProxy(assetId: newAssetId, proxySha256: proxy.sha256)
            try? await apiClient.registerProxy(
                masterHash: master.sha256,
                proxyHash: proxy.sha256,
                assetId: newAssetId,
                proxyFileURL: proxy.fileURL,
                proxyFormat: format.rawValue
            )

            let saved = max(0, master.sizeBytes - proxy.sizeBytes)
            totalSavedBytes += saved
            candidates[index].state = .completed(savedBytes: saved)
            candidates[index].isSelected = false
            return true
        } catch {
            candidates[index].state = .failed(error.localizedDescription)
            statusBanner = error.localizedDescription
            return false
        }
    }
}
