import AVKit
import Photos
import SwiftUI

private enum ServerGalleryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsProxy = "Needs Proxy"

    var id: String { rawValue }
}

struct ServerGalleryView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var syncManager = LocalProxySyncManager.shared

    @State private var photos: [ServerPhoto] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: ServerPhoto?
    @State private var imageCache: [String: UIImage] = [:]
    @State private var compressedDataCache: [String: Data] = [:]
    @State private var failedPreviewHashes: Set<String> = []
    @State private var filterMode: ServerGalleryFilter = .all

    @State private var isBatchProxying: Bool = false
    @State private var batchCompleted: Int = 0
    @State private var batchTotal: Int = 0
    @State private var batchStatusText: String = ""
    @State private var batchBannerMessage: String?
    @State private var batchTask: Task<Void, Never>?

    @State private var showingPhotoPicker: Bool = false
    @State private var isResolvingPick: Bool = false
    @State private var pickStatusText: String = "Preparing original..."
    @State private var pickerErrorMessage: String?
    @State private var shareSheetItem: ShareSheetItem?

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 3)
    ]

    private var unproxiedPhotos: [ServerPhoto] {
        photos.filter { $0.needsProxy }
    }

    private var displayedPhotos: [ServerPhoto] {
        switch filterMode {
        case .all:
            return photos
        case .needsProxy:
            return unproxiedPhotos
        }
    }

    var body: some View {
        AdaptiveNavigationStack {
            Group {
                if isLoading && photos.isEmpty {
                    ProgressView("Loading all server photos...")
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
                        description: "Upload photos or store them on your PhotoHub server to browse and proxy them here."
                    ) {
                        Button("Refresh") {
                            Task { await loadPhotos() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            if let errorMessage {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi.slash")
                                        .foregroundColor(.orange)
                                    Text("Showing local proxy cache (\(errorMessage))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .padding(.top, 6)
                            }

                            if !unproxiedPhotos.isEmpty || isBatchProxying || batchBannerMessage != nil {
                                unproxiedBannerView
                                    .padding(.horizontal)
                                    .padding(.top, 4)
                            }

                            if syncManager.isSyncing && syncManager.totalCount > 0 {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Auto-downloading local proxies (\(syncManager.completedCount)/\(syncManager.totalCount))...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Stop") {
                                        syncManager.cancel()
                                    }
                                    .font(.caption)
                                }
                                .padding(.horizontal)
                                .padding(.top, 2)
                            }

                            if !unproxiedPhotos.isEmpty {
                                Picker("Filter", selection: $filterMode) {
                                    Text("All (\(photos.count))").tag(ServerGalleryFilter.all)
                                    Text("Needs Proxy (\(unproxiedPhotos.count))").tag(ServerGalleryFilter.needsProxy)
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal)
                            }

                            if displayedPhotos.isEmpty {
                                Text("All photos on your server have compressed proxies.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 32)
                            } else {
                                LazyVGrid(columns: columns, spacing: 3) {
                                    ForEach(displayedPhotos) { photo in
                                        ServerThumbnailCell(
                                            photo: photo,
                                            image: imageCache[photo.hash],
                                            showPlaceholder: failedPreviewHashes.contains(photo.hash) || (photo.isVideo && photo.needsProxy)
                                        )
                                        .onTapGesture {
                                            selectedPhoto = photo
                                        }
                                        .task(id: "\(photo.hash)-\(photo.needsProxy ? 0 : 1)") {
                                            await loadCompressedPreviewIfNeeded(for: photo)
                                        }
                                    }
                                }
                                .padding(3)
                            }
                        }
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
            .onDisappear {
                batchTask?.cancel()
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
                ) { updated in
                    applyUpdatedPhoto(updated)
                }
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

    @ViewBuilder
    private var unproxiedBannerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBatchProxying {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Creating Proxies (\(batchCompleted)/\(batchTotal))")
                            .font(.subheadline.weight(.semibold))
                        if !batchStatusText.isEmpty {
                            Text(batchStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Stop") {
                        batchTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            } else if !unproxiedPhotos.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(unproxiedPhotos.count) server item(s) need proxies")
                            .font(.subheadline.weight(.semibold))
                        Text("Create lightweight previews & MP4 video proxies cleanly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Proxy Missing") {
                        startBatchProxy()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if let batchBannerMessage {
                Text(batchBannerMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func startBatchProxy() {
        guard !isBatchProxying else { return }
        let targets = unproxiedPhotos
        guard !targets.isEmpty else { return }

        batchTask?.cancel()
        batchBannerMessage = nil
        batchCompleted = 0
        batchTotal = targets.count
        batchStatusText = "Preparing..."
        isBatchProxying = true

        batchTask = Task {
            let client = PhotoHubAPIClient(settings: settings)
            let queue = AsyncWorkQueue(targets)
            let videoSemaphore = AsyncSemaphore(value: 1)
            let workerCount = min(3, targets.count)

            let counts: (Int, Int) = await withTaskGroup(of: (Int, Int).self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        var workerOk = 0
                        var workerFail = 0

                        while !Task.isCancelled, let item = await queue.next() {
                            await MainActor.run {
                                batchStatusText = item.originalName
                            }
                            if item.isVideo {
                                await videoSemaphore.acquire()
                            }
                            do {
                                let updated = try await client.createAndRegisterProxy(for: item)
                                if item.isVideo {
                                    await videoSemaphore.release()
                                }
                                await MainActor.run {
                                    applyUpdatedPhoto(updated)
                                    batchCompleted += 1
                                }
                                workerOk += 1
                            } catch {
                                if item.isVideo {
                                    await videoSemaphore.release()
                                }
                                await MainActor.run {
                                    batchCompleted += 1
                                }
                                workerFail += 1
                            }
                        }
                        return (workerOk, workerFail)
                    }
                }

                var totalOk = 0
                var totalFail = 0
                for await (ok, fail) in group {
                    totalOk += ok
                    totalFail += fail
                }
                return (totalOk, totalFail)
            }

            let succeeded = counts.0
            let failed = counts.1
            let cancelled = Task.isCancelled
            isBatchProxying = false
            batchStatusText = ""
            batchTask = nil
            if cancelled {
                batchBannerMessage = "Stopped after creating \(succeeded) proxy(s)."
            } else if failed > 0 {
                batchBannerMessage = "Created \(succeeded) proxy(s); \(failed) failed."
            } else {
                batchBannerMessage = "Created compressed proxies for all \(succeeded) item(s)."
            }
            if unproxiedPhotos.isEmpty && filterMode == .needsProxy {
                filterMode = .all
            }
        }
    }

    private func applyUpdatedPhoto(_ updated: ServerPhoto) {
        if let idx = photos.firstIndex(where: { $0.hash.lowercased() == updated.hash.lowercased() }) {
            photos[idx] = updated
        }
        failedPreviewHashes.remove(updated.hash)
        if let data = LocalProxyStore.shared.previewData(forHash: updated.hash),
           let img = UIImage(data: data) {
            imageCache[updated.hash] = img
            compressedDataCache[updated.hash] = data
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
            let fetched = try await client.fetchAllServerPhotos(sync: true)
            LocalProxyStore.shared.savePhotos(
                fetched,
                baseURL: settings.normalizedBaseURL,
                apiKey: settings.apiKey
            )
            photos = fetched
            for photo in fetched where !photo.needsProxy {
                failedPreviewHashes.remove(photo.hash)
            }
            errorMessage = nil
            LocalProxySyncManager.shared.startPrefetchIfNeeded(for: fetched, settings: settings)
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
            failedPreviewHashes.remove(photo.hash)
            return
        }

        // Un-proxied videos do not have a server preview image yet; avoid pulling gigabytes of video via /preview.
        if photo.isVideo && photo.needsProxy {
            failedPreviewHashes.insert(photo.hash)
            return
        }

        let client = PhotoHubAPIClient(settings: settings)
        if let rawData = try? await client.downloadPhotoPreviewData(hash: photo.hash),
           let (smallImage, smallData) = LocalProxyStore.shared.cacheDownloadedPreview(rawData, forHash: photo.hash) {
            imageCache[photo.hash] = smallImage
            compressedDataCache[photo.hash] = smallData
            failedPreviewHashes.remove(photo.hash)
        } else {
            failedPreviewHashes.insert(photo.hash)
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
}

private struct ServerThumbnailCell: View {
    let photo: ServerPhoto
    let image: UIImage?
    let showPlaceholder: Bool

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
                } else if showPlaceholder {
                    VStack(spacing: 4) {
                        Image(systemName: photo.isVideo ? "video.fill" : "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                }

                if photo.isVideo && image != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                Text(photo.needsProxy ? "NO PROXY" : (photo.isVideo ? "VIDEO" : "PROXY"))
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(photo.needsProxy ? Color.orange.opacity(0.9) : Color.black.opacity(0.65))
                    .foregroundColor(.white)
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
    @State private var currentPhoto: ServerPhoto
    @ObservedObject var settings: AppSettings
    let initialImage: UIImage?
    let initialCompressedData: Data?
    let onPhotoUpdated: (ServerPhoto) -> Void

    init(
        photo: ServerPhoto,
        settings: AppSettings,
        initialImage: UIImage?,
        initialCompressedData: Data?,
        onPhotoUpdated: @escaping (ServerPhoto) -> Void
    ) {
        self._currentPhoto = State(initialValue: photo)
        self.settings = settings
        self.initialImage = initialImage
        self.initialCompressedData = initialCompressedData
        self.onPhotoUpdated = onPhotoUpdated
    }

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

    private var needsProxyAction: Bool {
        currentPhoto.needsProxy || (currentPhoto.isVideo && localVideoProxyURL == nil && currentPhoto.hasVideoProxy != true && !isLoadingVideo)
    }

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
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .padding(.bottom, 10)
                        }
                    }
                } else if currentPhoto.isVideo && currentPhoto.needsProxy {
                    VStack(spacing: 10) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 52))
                            .foregroundColor(.orange)
                        Text("No compressed video proxy yet")
                            .font(.headline)
                        Text("Tap Create Compressed Proxy below to generate a small playable MP4 & thumbnail.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
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
                    Text("\(currentPhoto.originalName) \(currentPhoto.needsProxy ? "(Needs Proxy)" : "(Local Compressed Proxy)")")
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
                    let previewBytes = localVideoBytes ?? dataBytes ?? currentPhoto.videoProxySize ?? currentPhoto.proxySize
                    let smallStr = previewBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? (currentPhoto.needsProxy ? "Not created yet" : "Compressed")
                    let masterStr = ByteCountFormatter.string(fromByteCount: currentPhoto.size, countStyle: .file)
                    Text("Local Proxy: \(smallStr) • Original Master: \(masterStr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if needsProxyAction {
                        Button {
                            Task { await createProxyForCurrentItem() }
                        } label: {
                            Label(currentPhoto.isVideo ? "Create Compressed Video Proxy" : "Create Compressed Proxy", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(isBusy)
                    }

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
                            Label("Save Proxy", systemImage: currentPhoto.isVideo ? "video" : "photo")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || (!currentPhoto.isVideo && (compressedData ?? initialCompressedData) == nil && previewImage == nil))

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
                    } else if let cachedData = LocalProxyStore.shared.previewData(forHash: currentPhoto.hash),
                              let cachedImg = UIImage(data: cachedData) {
                        previewImage = cachedImg
                        compressedData = cachedData
                    } else if !(currentPhoto.isVideo && currentPhoto.needsProxy) {
                        let client = PhotoHubAPIClient(settings: settings)
                        if let rawData = try? await client.downloadPhotoPreviewData(hash: currentPhoto.hash),
                           let (smallImg, smallJpg) = LocalProxyStore.shared.cacheDownloadedPreview(rawData, forHash: currentPhoto.hash) {
                            previewImage = smallImg
                            compressedData = smallJpg
                        }
                    }
                }

                if currentPhoto.isVideo && !currentPhoto.needsProxy {
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

    private func createProxyForCurrentItem() async {
        isBusy = true
        busyLabel = currentPhoto.isVideo
            ? "Creating compressed MP4 video proxy..."
            : "Creating compressed proxy..."
        saveMessage = nil
        videoUnavailableNote = nil
        defer {
            isBusy = false
            busyLabel = ""
        }

        do {
            let client = PhotoHubAPIClient(settings: settings)
            let updated = try await client.createAndRegisterProxy(for: currentPhoto)
            currentPhoto = updated

            if let cachedData = LocalProxyStore.shared.previewData(forHash: updated.hash),
               let cachedImg = UIImage(data: cachedData) {
                previewImage = cachedImg
                compressedData = cachedData
            }
            if updated.isVideo,
               let videoURL = LocalProxyStore.shared.videoProxyURLIfExists(forHash: updated.hash) {
                localVideoProxyURL = videoURL
                let avPlayer = AVPlayer(url: videoURL)
                player = avPlayer
                avPlayer.play()
            }

            onPhotoUpdated(updated)
            saveMessage = "Compressed proxy created and stored on server & local cache."
        } catch {
            saveMessage = "Proxy creation failed: \(error.localizedDescription)"
        }
    }

    private func prepareVideoProxyIfNeeded() async {
        if let cachedURL = LocalProxyStore.shared.videoProxyURLIfExists(forHash: currentPhoto.hash) {
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
            let tempVideo = try await client.downloadVideoProxyToTempFile(hash: currentPhoto.hash)
            defer { cleanupTempShareURL(tempVideo) }
            if let persistedURL = LocalProxyStore.shared.copyVideoProxy(from: tempVideo, forHash: currentPhoto.hash) {
                localVideoProxyURL = persistedURL
                let avPlayer = AVPlayer(url: persistedURL)
                player = avPlayer
                avPlayer.play()
            }
        } catch {
            videoUnavailableNote = "No compressed video proxy on server yet. Tap Create Compressed Video Proxy above, or Share Original."
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
                hash: currentPhoto.hash,
                preferredFilename: currentPhoto.originalName
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

        if currentPhoto.isVideo,
           let videoURL = localVideoProxyURL ?? LocalProxyStore.shared.videoProxyURLIfExists(forHash: currentPhoto.hash) {
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
            if let raw = try? await client.downloadPhotoPreviewData(hash: currentPhoto.hash) {
                dataToSave = LocalProxyStore.makeSmallCompressedPreview(from: raw, maxPixelSize: 800, quality: 0.65)?.1 ?? raw
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
                hash: currentPhoto.hash,
                preferredFilename: currentPhoto.originalName
            )
            let fileSize = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? currentPhoto.size
            let isVideo = currentPhoto.isVideo

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
