import AVKit
import ImageIO
import Photos
import SwiftUI

struct ServerGalleryView: View {
    @ObservedObject var settings: AppSettings

    @State private var photos: [ServerPhoto] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: ServerPhoto?
    @State private var imageCache: [String: UIImage] = [:]
    @State private var compressedDataCache: [String: Data] = [:]

    @State private var showingPhotoPicker: Bool = false
    @State private var isResolvingPick: Bool = false
    @State private var pickStatusText: String = "Preparing original..."
    @State private var pickerErrorMessage: String?
    @State private var shareSheetItem: ShareSheetItem?

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 3)
    ]

    var body: some View {
        AdaptiveNavigationStack {
            Group {
                if isLoading && photos.isEmpty {
                    ProgressView("Loading compressed proxies...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, photos.isEmpty {
                    CompatibleEmptyStateView(
                        title: "Could Not Connect",
                        systemImage: "wifi.exclamationmark",
                        description: errorMessage
                    ) {
                        Button("Retry") {
                            Task { await loadPhotos() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if photos.isEmpty {
                    CompatibleEmptyStateView(
                        title: "No Backups Yet",
                        systemImage: "cloud",
                        description: "Compress and upload photos on the Compress tab to see your compressed proxies here."
                    ) {
                        Button("Refresh") {
                            Task { await loadPhotos() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        if let errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "wifi.slash")
                                    .foregroundStyle(.orange)
                                Text("Showing local proxy cache (\(errorMessage))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.top, 6)
                        }

                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(photos) { photo in
                                ServerThumbnailCell(
                                    photo: photo,
                                    image: imageCache[photo.hash]
                                )
                                .onTapGesture {
                                    selectedPhoto = photo
                                }
                                .task(id: photo.hash) {
                                    await loadCompressedPreviewIfNeeded(for: photo)
                                }
                            }
                        }
                        .padding(3)
                    }
                    .refreshable {
                        await loadPhotos()
                    }
                }
            }
            .overlay {
                if isResolvingPick {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(pickStatusText)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .navigationTitle("Server (\(photos.count))")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("From Photos", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(isResolvingPick)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await loadPhotos() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                }
            }
            .onAppear {
                loadFromLocalStore()
                Task { await loadPhotos() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .localProxyStoreDidChange)) { _ in
                loadFromLocalStore()
            }
            .sheet(item: $selectedPhoto) { photo in
                ServerPhotoDetailView(
                    photo: photo,
                    settings: settings,
                    initialImage: imageCache[photo.hash],
                    initialCompressedData: compressedDataCache[photo.hash]
                )
            }
            .sheet(isPresented: $showingPhotoPicker) {
                PhotoPickerSheet(
                    onPick: { picked in
                        showingPhotoPicker = false
                        Task { await handlePickedMedia(picked) }
                    },
                    onCancel: {
                        showingPhotoPicker = false
                    }
                )
            }
            .sheet(item: $shareSheetItem) { item in
                ShareSheet(activityItems: [item.fileURL]) {
                    cleanupTempShareURL(item.fileURL)
                    shareSheetItem = nil
                }
            }
            .alert("Cannot Resolve Original", isPresented: Binding(
                get: { pickerErrorMessage != nil },
                set: { if !$0 { pickerErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { pickerErrorMessage = nil }
            } message: {
                Text(pickerErrorMessage ?? "")
            }
        }
    }

    private func loadFromLocalStore() {
        let cached = LocalProxyStore.shared.cachedPhotos(
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey
        )
        if !cached.isEmpty || photos.isEmpty {
            photos = cached
        }
        for photo in cached {
            if imageCache[photo.hash] == nil,
               let data = LocalProxyStore.shared.previewData(forHash: photo.hash),
               let img = UIImage(data: data) {
                imageCache[photo.hash] = img
                compressedDataCache[photo.hash] = data
            }
        }
    }

    private func loadPhotos() async {
        isLoading = true
        defer { isLoading = false }
        let client = PhotoHubAPIClient(settings: settings)
        do {
            let fetched = try await client.fetchServerPhotos()
            LocalProxyStore.shared.savePhotos(
                fetched,
                baseURL: settings.normalizedBaseURL,
                apiKey: settings.apiKey
            )
            photos = fetched
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCompressedPreviewIfNeeded(for photo: ServerPhoto) async {
        guard imageCache[photo.hash] == nil else { return }

        if let cachedData = LocalProxyStore.shared.previewData(forHash: photo.hash),
           let cachedImg = UIImage(data: cachedData) {
            imageCache[photo.hash] = cachedImg
            compressedDataCache[photo.hash] = cachedData
            return
        }

        let client = PhotoHubAPIClient(settings: settings)
        if let rawData = try? await client.downloadPhotoPreviewData(hash: photo.hash),
           let (smallImage, smallData) = Self.makeSmallCompressedPreview(from: rawData, maxPixelSize: 800, quality: 0.65) {
            imageCache[photo.hash] = smallImage
            compressedDataCache[photo.hash] = smallData
            LocalProxyStore.shared.savePreviewData(smallData, forHash: photo.hash)
        }
    }

    private func handlePickedMedia(_ picked: PickedMediaResult) async {
        isResolvingPick = true
        pickStatusText = "Matching selected item..."
        defer {
            if let tempURL = picked.copiedFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            isResolvingPick = false
        }

        let tracker = LocalProxyTracker()
        let client = PhotoHubAPIClient(settings: settings)

        var resolvedMasterHash: String?
        var resolvedFilename: String?

        if let assetId = picked.assetId,
           let match = tracker.masterLookup(forAssetId: assetId) {
            resolvedMasterHash = match.masterHash
            resolvedFilename = match.originalName
        }

        if resolvedMasterHash == nil, let fileURL = picked.copiedFileURL {
            do {
                let sha = try ProxyGenerator.computeFileSHA256(url: fileURL)
                if let knownMaster = tracker.masterHash(forProxySha256: sha) {
                    resolvedMasterHash = knownMaster
                } else {
                    let check = try await client.checkHash(sha)
                    if check.exists {
                        resolvedMasterHash = check.masterHash ?? sha
                    }
                }
            } catch {
                pickerErrorMessage = error.localizedDescription
                return
            }
        }

        guard let masterHash = resolvedMasterHash else {
            pickerErrorMessage = "This item is not linked to an uploaded PhotoHub master on the server. Back it up on the Compress tab or pick it from the Server gallery."
            return
        }

        if resolvedFilename == nil,
           let matchingPhoto = photos.first(where: { $0.hash.lowercased() == masterHash.lowercased() }) {
            resolvedFilename = matchingPhoto.originalName
        }

        do {
            pickStatusText = "Downloading original..."
            let tempMasterURL = try await client.downloadMasterToTempFile(
                hash: masterHash,
                preferredFilename: resolvedFilename
            )
            shareSheetItem = ShareSheetItem(fileURL: tempMasterURL)
        } catch {
            pickerErrorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    static func makeSmallCompressedPreview(
        from data: Data,
        maxPixelSize: Int = 800,
        quality: CGFloat = 0.65
    ) -> (UIImage, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            guard let img = UIImage(data: data),
                  let jpg = img.jpegData(compressionQuality: quality) else { return nil }
            return (UIImage(data: jpg) ?? img, jpg)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let uiImg = UIImage(cgImage: cgImg)
        guard let smallJpg = uiImg.jpegData(compressionQuality: quality),
              let decodedSmall = UIImage(data: smallJpg) else {
            return nil
        }
        return (decodedSmall, smallJpg)
    }
}

private struct ServerThumbnailCell: View {
    let photo: ServerPhoto
    let image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ProgressView()
                }

                if photo.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                Text(photo.isVideo ? "VIDEO" : "PROXY")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65))
                    .foregroundStyle(.white)
                    .cornerRadius(4)
                    .padding(4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct ServerPhotoDetailView: View {
    let photo: ServerPhoto
    @ObservedObject var settings: AppSettings
    let initialImage: UIImage?
    let initialCompressedData: Data?

    @Environment(\.dismiss) private var dismiss
    @State private var previewImage: UIImage?
    @State private var compressedData: Data?
    @State private var player: AVPlayer?
    @State private var localVideoProxyURL: URL?
    @State private var isLoadingVideo: Bool = false
    @State private var videoUnavailableNote: String?

    @State private var isBusy: Bool = false
    @State private var busyLabel: String = ""
    @State private var saveMessage: String?
    @State private var shareSheetItem: ShareSheetItem?

    var body: some View {
        AdaptiveNavigationStack {
            VStack(spacing: 12) {
                Spacer()
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .cornerRadius(12)
                        .padding(.horizontal)
                } else if let img = previewImage ?? initialImage {
                    ZStack(alignment: .bottom) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(.horizontal)

                        if isLoadingVideo {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("Loading compressed video proxy...")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .padding(.bottom, 10)
                        }
                    }
                } else {
                    ProgressView("Loading compressed proxy...")
                }

                if let videoUnavailableNote {
                    Text(videoUnavailableNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                if isBusy && !busyLabel.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(busyLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("\(photo.originalName) (Local Compressed Proxy)")
                        .font(.headline)
                        .lineLimit(1)

                    let localVideoBytes: Int64? = {
                        guard let url = localVideoProxyURL,
                              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                            return nil
                        }
                        return Int64(size)
                    }()
                    let dataBytes = (compressedData ?? initialCompressedData).map { Int64($0.count) }
                    let previewBytes = localVideoBytes ?? dataBytes ?? photo.videoProxySize ?? photo.proxySize
                    let smallStr = previewBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "Compressed"
                    let masterStr = ByteCountFormatter.string(fromByteCount: photo.size, countStyle: .file)
                    Text("Local Proxy: \(smallStr) • Original Master: \(masterStr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await shareFullMasterOriginal() }
                    } label: {
                        Label("Share Original", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)

                    HStack(spacing: 12) {
                        Button {
                            Task { await saveCompressedProxyToPhotos() }
                        } label: {
                            Label("Save Proxy", systemImage: photo.isVideo ? "video" : "photo")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || (!photo.isVideo && (compressedData ?? initialCompressedData) == nil && previewImage == nil))

                        Button {
                            Task { await restoreFullMasterToPhotos() }
                        } label: {
                            Label("Restore", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Server Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if previewImage == nil {
                    if let initialImage, let initialCompressedData {
                        previewImage = initialImage
                        compressedData = initialCompressedData
                    } else if let cachedData = LocalProxyStore.shared.previewData(forHash: photo.hash),
                              let cachedImg = UIImage(data: cachedData) {
                        previewImage = cachedImg
                        compressedData = cachedData
                    } else {
                        let client = PhotoHubAPIClient(settings: settings)
                        if let rawData = try? await client.downloadPhotoPreviewData(hash: photo.hash),
                           let (smallImg, smallJpg) = ServerGalleryView.makeSmallCompressedPreview(from: rawData, maxPixelSize: 800, quality: 0.65) {
                            previewImage = smallImg
                            compressedData = smallJpg
                            LocalProxyStore.shared.savePreviewData(smallJpg, forHash: photo.hash)
                        }
                    }
                }

                if photo.isVideo {
                    await prepareVideoProxyIfNeeded()
                }
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .sheet(item: $shareSheetItem) { item in
                ShareSheet(activityItems: [item.fileURL]) {
                    cleanupTempShareURL(item.fileURL)
                    shareSheetItem = nil
                }
            }
        }
    }

    private func prepareVideoProxyIfNeeded() async {
        if let cachedURL = LocalProxyStore.shared.videoProxyURLIfExists(forHash: photo.hash) {
            localVideoProxyURL = cachedURL
            let avPlayer = AVPlayer(url: cachedURL)
            player = avPlayer
            avPlayer.play()
            return
        }

        isLoadingVideo = true
        defer { isLoadingVideo = false }
        let client = PhotoHubAPIClient(settings: settings)
        do {
            let tempVideo = try await client.downloadVideoProxyToTempFile(hash: photo.hash)
            defer { cleanupTempShareURL(tempVideo) }
            if let persistedURL = LocalProxyStore.shared.copyVideoProxy(from: tempVideo, forHash: photo.hash) {
                localVideoProxyURL = persistedURL
                let avPlayer = AVPlayer(url: persistedURL)
                player = avPlayer
                avPlayer.play()
            }
        } catch {
            videoUnavailableNote = "No compressed video proxy on server yet. Tap Share Original or Restore to fetch the full video."
        }
    }

    private func shareFullMasterOriginal() async {
        isBusy = true
        busyLabel = "Fetching full-resolution original..."
        saveMessage = nil
        defer {
            isBusy = false
            busyLabel = ""
        }

        do {
            let client = PhotoHubAPIClient(settings: settings)
            let tempURL = try await client.downloadMasterToTempFile(
                hash: photo.hash,
                preferredFilename: photo.originalName
            )
            shareSheetItem = ShareSheetItem(fileURL: tempURL)
        } catch {
            saveMessage = "Share failed: \(error.localizedDescription)"
        }
    }

    private func saveCompressedProxyToPhotos() async {
        isBusy = true
        busyLabel = "Saving proxy to Photos..."
        saveMessage = nil

        if photo.isVideo, let videoURL = localVideoProxyURL ?? LocalProxyStore.shared.videoProxyURLIfExists(forHash: photo.hash) {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }) { success, error in
                DispatchQueue.main.async {
                    isBusy = false
                    busyLabel = ""
                    if success {
                        let sizeBytes = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                        let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
                        saveMessage = "Saved compressed video proxy (\(sizeStr)) to Photos."
                    } else {
                        saveMessage = "Failed: \(error?.localizedDescription ?? "Unknown error")"
                    }
                }
            }
            return
        }

        var dataToSave = compressedData ?? initialCompressedData
        if dataToSave == nil {
            let client = PhotoHubAPIClient(settings: settings)
            if let raw = try? await client.downloadPhotoPreviewData(hash: photo.hash) {
                dataToSave = ServerGalleryView.makeSmallCompressedPreview(from: raw, maxPixelSize: 800, quality: 0.65)?.1 ?? raw
            }
        }
        guard let dataToSave else {
            isBusy = false
            busyLabel = ""
            saveMessage = "Preview still loading."
            return
        }

        PHPhotoLibrary.shared().performChanges({
            if let img = UIImage(data: dataToSave) {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            } else {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: dataToSave, options: nil)
            }
        }) { success, error in
            DispatchQueue.main.async {
                isBusy = false
                busyLabel = ""
                if success {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(dataToSave.count), countStyle: .file)
                    saveMessage = "Saved compressed proxy (\(sizeStr)) to Photos."
                } else {
                    saveMessage = "Failed: \(error?.localizedDescription ?? "Unknown error")"
                }
            }
        }
    }

    private func restoreFullMasterToPhotos() async {
        isBusy = true
        busyLabel = "Downloading full-resolution original..."
        saveMessage = nil

        do {
            let client = PhotoHubAPIClient(settings: settings)
            let tempURL = try await client.downloadMasterToTempFile(
                hash: photo.hash,
                preferredFilename: photo.originalName
            )
            let fileSize = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? photo.size
            let isVideo = photo.isVideo

            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
                } else {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: tempURL, options: nil)
                }
            }) { success, error in
                cleanupTempShareURL(tempURL)
                DispatchQueue.main.async {
                    isBusy = false
                    busyLabel = ""
                    if success {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
                        saveMessage = "Restored full-resolution original (\(sizeStr)) to iPhone Photos."
                    } else {
                        saveMessage = "Restore failed: \(error?.localizedDescription ?? "Unknown error")"
                    }
                }
            }
        } catch {
            isBusy = false
            busyLabel = ""
            saveMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}
