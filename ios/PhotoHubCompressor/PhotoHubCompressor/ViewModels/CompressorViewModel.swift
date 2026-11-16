import Foundation
import Photos
import SwiftUI

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
                if failedCount > 0 && self.statusBanner == nil {
                    self.statusBanner = "Finished with \(failedCount) error(s). Space saved: \(savedStr)."
                } else if failedCount == 0 {
                    self.statusBanner = "Finished! Space saved: \(savedStr). Empty 'Recently Deleted' in Photos to reclaim storage immediately."
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

                            // Step 5: Invoke PhotoKit replace/delete on a background queue (NEVER DispatchQueue.main!)
                            let keepLocal = self.settings.keepLocalProxyInPhotos
                            self.updateStateOnMain(id: currentId, state: .replacingInPhotos)

                            DispatchQueue.global(qos: .userInitiated).async {
                                self.photoService.replaceWithProxy(
                                    originalAsset: candidate.asset,
                                    mediaType: candidate.mediaType,
                                    proxyFileURL: proxy.fileURL,
                                    keepLocalProxy: keepLocal
                                ) { [weak self] replaceResult in
                                    try? FileManager.default.removeItem(at: proxy.fileURL)
                                    guard let self = self else { return }

                                    switch replaceResult {
                                    case .success(let newAssetId):
                                        self.tracker.markAsProxy(assetId: candidate.id, proxySha256: proxy.sha256)
                                        self.tracker.markAsProxy(assetId: newAssetId, proxySha256: proxy.sha256)

                                        let saved = keepLocal
                                            ? max(0, master.sizeBytes - proxy.sizeBytes)
                                            : master.sizeBytes
                                        self.totalSavedBytes += saved
                                        self.candidates.removeAll { $0.id == currentId }
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
