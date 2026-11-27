import AVKit
import Photos
import SwiftUI

private enum ServerGalleryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsProxy = "Needs Proxy"

    var id: String { rawValue }
}

private enum ServerMediaTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case favorites = "♥ Favorites"
    case protectedOnly = "Protected"
    case trash = "Trash"

    var id: String { rawValue }
}

private enum ServerTimelineGrouping: String, CaseIterable, Identifiable {
    case day = "Date & Year"
    case month = "Month & Year"
    case year = "Year Only"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .day: return "Day"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
}

private enum BatchProxyOutcome: Sendable {
    case updated(ServerPhoto)
    case failed(String)

    var displayName: String {
        switch self {
        case .updated(let photo): return photo.originalName
        case .failed(let name): return name
        }
    }
}

private struct DeleteConfirmPrompt {
    let targets: [ServerPhoto]
    let totalBytes: Int64
    let isPermanent: Bool
}

struct ServerGalleryView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var syncManager: LocalProxySyncManager

    init(settings: AppSettings) {
        self.settings = settings
        self._syncManager = ObservedObject(wrappedValue: LocalProxySyncManager.shared)
    }

    @State private var photos: [ServerPhoto] = []
    @State private var trashPhotos: [ServerPhoto] = []
    @State private var trashCount: Int = 0
    @State private var trashBytes: Int64 = 0
    @State private var isLoadingTrash: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: ServerPhoto?
    @State private var thumbCacheRevision: Int = 0
    @State private var failedPreviewHashes: Set<String> = []
    @State private var filterMode: ServerGalleryFilter = .all
    @State private var mediaTypeFilter: ServerMediaTypeFilter = .all
    @State private var timelineGrouping: ServerTimelineGrouping = .day
    @State private var searchQuery: String = ""
    @State private var timelineData: ServerTimelineData = .empty
    @State private var selectedYearAnchor: String?
    @State private var isScrubbingTimeline: Bool = false
    @State private var scrubSectionIndex: Int?
    @State private var scrubFraction: CGFloat = 0

    @State private var isSelectionMode: Bool = false
    @State private var selectedPhotoHashes: Set<String> = []
    @State private var locallyProtectedHashes: Set<String> = []

    @State private var isBatchProxying: Bool = false
    @State private var batchCompleted: Int = 0
    @State private var batchTotal: Int = 0
    @State private var batchStatusText: String = ""
    @State private var batchBannerMessage: String?
    @State private var batchTask: Task<Void, Never>?

    @State private var isBatchRestoring: Bool = false
    @State private var restoreCompleted: Int = 0
    @State private var restoreTotal: Int = 0
    @State private var restoreStatusText: String = ""
    @State private var restoreBannerMessage: String?
    @State private var restoreTask: Task<Void, Never>?
    @State private var restoreConfirmPrompt: RestoreConfirmPrompt?

    @State private var isBatchDeleting: Bool = false
    @State private var deleteBannerMessage: String?
    @State private var deleteConfirmPrompt: DeleteConfirmPrompt?

    private let columns = [
        GridItem(.adaptive(minimum: 102, maximum: 145), spacing: 6)
    ]

    private var isViewingTrash: Bool {
        mediaTypeFilter == .trash
    }

    private var activeSourcePhotos: [ServerPhoto] {
        isViewingTrash ? trashPhotos : photos
    }

    private var unproxiedPhotos: [ServerPhoto] {
        photos.filter { $0.needsProxy }
    }

    private var favoriteCount: Int {
        photos.reduce(into: 0) { count, p in
            if p.isFavorited { count += 1 }
        }
    }

    private var protectedCount: Int {
        photos.reduce(into: 0) { count, p in
            if isRestoredOrProtected(p) { count += 1 }
        }
    }

    private var videoCount: Int {
        photos.reduce(into: 0) { count, p in
            if p.isVideo { count += 1 }
        }
    }

    private var photoCount: Int {
        max(0, photos.count - videoCount)
    }

    private var totalServerBytes: Int64 {
        photos.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
    }

    private var activeHeroMood: MascotMood {
        if isBatchProxying || isBatchRestoring || syncManager.isSyncing || isLoading {
            return .uploading
        }
        if errorMessage != nil {
            return .alert
        }
        return .happy
    }

    private var greetingTitle: String {
        let trimmed = settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.split(separator: " ").first, !first.isEmpty {
            return "Hi, \(first)"
        }
        return "Your Cloud Photos"
    }

    private var hasActiveFilter: Bool {
        filterMode != .all || mediaTypeFilter != .all || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isRestoredOrProtected(_ photo: ServerPhoto) -> Bool {
        photo.isProtectedOriginal || locallyProtectedHashes.contains(photo.hash.lowercased())
    }

    private var visiblePhotos: [ServerPhoto] {
        timelineData.sections.flatMap(\.photos)
    }

    private var selectedPhotos: [ServerPhoto] {
        guard !selectedPhotoHashes.isEmpty else { return [] }
        return activeSourcePhotos.filter { selectedPhotoHashes.contains($0.hash.lowercased()) }
    }

    var body: some View {
        AdaptiveNavigationStack {
            ZStack {
                PhotoHubPalette.canvas.ignoresSafeArea()

                Group {
                    if isLoading && photos.isEmpty {
                        CloudLoadingSkeletonView()
                    } else if let errorMessage, photos.isEmpty {
                        VStack(spacing: 14) {
                            SunnyMascotView(mood: .alert, size: 118)
                            Text("Could Not Reach Cloud")
                                .font(.title3.weight(.heavy))
                                .foregroundColor(PhotoHubPalette.ink)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundColor(PhotoHubPalette.muted)
                                .lineLimit(3)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                            Button {
                                Task { await loadPhotos() }
                            } label: {
                                Label("Retry Connection", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PhotoHubPrimaryButtonStyle())
                            .padding(.top, 4)
                        }
                        .padding(24)
                        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if photos.isEmpty && !isViewingTrash && trashCount == 0 {
                        VStack(spacing: 14) {
                            SunnyMascotView(mood: .sleeping, size: 120)
                            Text("No Cloud Backups Yet")
                                .font(.title3.weight(.heavy))
                                .foregroundColor(PhotoHubPalette.ink)
                            Text("Head to the Backup tab to upload your first full-resolution photos & videos.")
                                .font(.subheadline)
                                .foregroundColor(PhotoHubPalette.muted)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                            Button {
                                Task { await loadPhotos() }
                            } label: {
                                Label("Refresh Cloud", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PhotoHubPrimaryButtonStyle())
                            .padding(.top, 4)
                        }
                        .padding(24)
                        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                    ScrollViewReader { scrollProxy in
                        ZStack(alignment: .trailing) {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    // Web-matched Warm Sunset Hero & Storage Summary Card
                                    cloudHeroStorageCard
                                        .padding(.horizontal, 12)
                                        .padding(.top, 8)
                                        .padding(.bottom, 10)

                                    // Web-matched Search, Filter Pills, Grouping & Year Quick Jump Card
                                    cloudControlBar(scrollProxy: scrollProxy)
                                        .padding(.horizontal, 12)
                                        .padding(.bottom, 10)

                                    if let errorMessage {
                                        HStack(spacing: 8) {
                                            Image(systemName: "wifi.slash")
                                                .font(.caption.weight(.bold))
                                                .foregroundColor(PhotoHubPalette.orange)
                                            Text("Offline cache · \(errorMessage)")
                                                .font(.caption.weight(.medium))
                                                .foregroundColor(PhotoHubPalette.ink)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(PhotoHubPalette.softPeach, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(PhotoHubPalette.orange.opacity(0.32), lineWidth: 1)
                                        )
                                        .padding(.horizontal, 12)
                                        .padding(.bottom, 8)
                                    }

                                    if !unproxiedPhotos.isEmpty || isBatchProxying || batchBannerMessage != nil {
                                        unproxiedBannerView
                                            .padding(.horizontal, 12)
                                            .padding(.bottom, 8)
                                    }

                                    if isBatchRestoring || restoreBannerMessage != nil {
                                        restoreBannerView
                                            .padding(.horizontal, 12)
                                            .padding(.bottom, 8)
                                    }

                                    if isBatchDeleting || deleteBannerMessage != nil {
                                        deleteBannerView
                                            .padding(.horizontal, 12)
                                            .padding(.bottom, 8)
                                    }

                                    if isViewingTrash {
                                        trashInfoBannerView
                                            .padding(.horizontal, 12)
                                            .padding(.bottom, 8)
                                    }

                                    if syncManager.isSyncing {
                                        HStack(spacing: 10) {
                                            ProgressView()
                                                .tint(PhotoHubPalette.orange)
                                                .scaleEffect(0.85)
                                            Text(
                                                syncManager.statusText.isEmpty
                                                ? "Syncing previews (\(syncManager.completedCount)/\(syncManager.totalCount))…"
                                                : syncManager.statusText
                                            )
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(PhotoHubPalette.ink)
                                            .lineLimit(1)
                                            Spacer()
                                            Button("Stop") {
                                                syncManager.cancel()
                                            }
                                            .font(.caption.weight(.bold))
                                            .foregroundColor(PhotoHubPalette.deepOrange)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                                        )
                                        .padding(.horizontal, 12)
                                        .padding(.bottom, 8)
                                    }

                                    if timelineData.sections.isEmpty {
                                        VStack(spacing: 12) {
                                            SunnyMascotView(mood: .sleeping, size: 84)
                                            Text("No Matching Items")
                                                .font(.headline.weight(.bold))
                                                .foregroundColor(PhotoHubPalette.ink)
                                            Text(emptyFilteredMessage)
                                                .font(.caption)
                                                .foregroundColor(PhotoHubPalette.muted)
                                                .multilineTextAlignment(.center)
                                            if hasActiveFilter {
                                                Button("Clear Filters") {
                                                    filterMode = .all
                                                    mediaTypeFilter = .all
                                                    searchQuery = ""
                                                }
                                                .buttonStyle(PhotoHubSoftButtonStyle())
                                                .padding(.top, 4)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 36)
                                        .padding(.horizontal, 24)
                                    } else {
                                        ForEach(timelineData.sections) { section in
                                            if section.startsNewYear && timelineGrouping != .year {
                                                yearBannerHeader(for: section)
                                                    .id("year-\(section.yearLabel)")
                                            } else if timelineGrouping == .year {
                                                Color.clear
                                                    .frame(height: 0)
                                                    .id("year-\(section.yearLabel)")
                                            }

                                            Color.clear
                                                .frame(height: 0)
                                                .id(section.anchorId)

                                            Section {
                                                LazyVGrid(columns: columns, spacing: 6) {
                                                    ForEach(section.photos) { photo in
                                                        let norm = photo.hash.lowercased()
                                                        let isSelected = selectedPhotoHashes.contains(norm)
                                                        let protectedOrRestored = isRestoredOrProtected(photo)
                                                        let _ = thumbCacheRevision
                                                        ServerThumbnailCell(
                                                            photo: photo,
                                                            image: ThumbnailMemoryCache.shared.image(forHash: photo.hash),
                                                            showPlaceholder: failedPreviewHashes.contains(photo.hash) || (photo.isVideo && photo.needsProxy),
                                                            isSelectionMode: isSelectionMode,
                                                            isSelected: isSelected,
                                                            isRestoredOrProtected: protectedOrRestored
                                                        )
                                                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                                        .onTapGesture {
                                                            if isSelectionMode {
                                                                toggleSelection(for: photo)
                                                            } else {
                                                                selectedPhoto = photo
                                                            }
                                                        }
                                                        .onLongPressGesture {
                                                            if !isSelectionMode && !isBatchRestoring && !isBatchProxying && !isBatchDeleting {
                                                                enterSelectionMode(initialPhoto: photo)
                                                            }
                                                        }
                                                        .task(id: "\(photo.hash)-\(photo.needsProxy ? 0 : 1)") {
                                                            await loadCompressedPreviewIfNeeded(for: photo)
                                                        }
                                                    }
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.bottom, 14)
                                            } header: {
                                                timelineSectionHeader(section)
                                            }
                                        }
                                    }
                                }
                                .padding(.bottom, isSelectionMode ? 90 : 20)
                            }
                            .refreshable {
                                await loadPhotos()
                            }

                            if timelineData.sections.count >= 6 {
                                immichTimelineScrubber(scrollProxy: scrollProxy)
                            }
                        }
                    }
                }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionRestoreBottomBar
                }
            }
            .navigationTitle(isSelectionMode ? "\(selectedPhotoHashes.count) Selected" : "Cloud")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectionMode {
                        let visible = visiblePhotos
                        let allSelected = !visible.isEmpty && visible.allSatisfy { selectedPhotoHashes.contains($0.hash.lowercased()) }
                        Button(allSelected ? "Clear" : "Select All") {
                            if allSelected {
                                selectedPhotoHashes.removeAll()
                            } else {
                                selectedPhotoHashes = Set(visible.map { $0.hash.lowercased() })
                            }
                        }
                    } else {
                        Button {
                            IncomingShareCoordinator.shared.presentInAppPhotoPicker()
                        } label: {
                            Label("From Photos", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelectionMode {
                        Button("Done") {
                            exitSelectionMode()
                        }
                        .font(.body.weight(.semibold))
                    } else {
                        Button("Select") {
                            enterSelectionMode()
                        }
                        .disabled(activeSourcePhotos.isEmpty || isBatchRestoring || isBatchProxying || isBatchDeleting)

                        Menu {
                            if !photos.isEmpty {
                                Button {
                                    enterSelectionMode()
                                } label: {
                                    Label("Select Photos to Restore or Delete", systemImage: "checkmark.circle")
                                }
                                .disabled(isBatchRestoring || isBatchProxying || isBatchDeleting)

                                Divider()
                            }

                            Picker("Timeline View", selection: $timelineGrouping) {
                                ForEach(ServerTimelineGrouping.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }

                            Picker("Media Type", selection: $mediaTypeFilter) {
                                ForEach(ServerMediaTypeFilter.allCases) { media in
                                    Text(media.rawValue).tag(media)
                                }
                            }

                            if !unproxiedPhotos.isEmpty || filterMode == .needsProxy {
                                Picker("Proxy Status", selection: $filterMode) {
                                    Text("All (\(photos.count))").tag(ServerGalleryFilter.all)
                                    Text("Needs Proxy (\(unproxiedPhotos.count))").tag(ServerGalleryFilter.needsProxy)
                                }
                            }
                        } label: {
                            Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "ellipsis.circle")
                        }

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
            }
            .onAppear {
                loadFromLocalStore()
                Task { await loadPhotos() }
            }
            .onChange(of: filterMode) { _ in
                rebuildTimeline()
            }
            .onChange(of: mediaTypeFilter) { newFilter in
                selectedPhotoHashes.removeAll()
                rebuildTimeline()
                if newFilter == .trash {
                    Task { await loadTrashPhotos() }
                }
            }
            .onChange(of: timelineGrouping) { _ in
                rebuildTimeline()
            }
            .onChange(of: searchQuery) { _ in
                rebuildTimeline()
            }
            .onDisappear {
                batchTask?.cancel()
                restoreTask?.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .localProxyStoreDidChange)) { _ in
                loadFromLocalStore()
            }
            .sheet(item: $selectedPhoto) { photo in
                let galleryList = visiblePhotos.isEmpty ? [photo] : visiblePhotos
                ServerPhotoDetailView(
                    photo: photo,
                    allPhotos: galleryList,
                    isTrashMode: isViewingTrash || photo.isTrashed,
                    settings: settings,
                    onPhotoUpdated: { updated in
                        applyUpdatedPhoto(updated)
                    },
                    onPhotoDeleted: { deletedHash, deletedName, wasPermanent in
                        if wasPermanent {
                            let norm = deletedHash.lowercased()
                            trashPhotos.removeAll { $0.hash.lowercased() == norm }
                            trashCount = trashPhotos.count
                            if isViewingTrash { rebuildTimeline() }
                            deleteBannerMessage = "Permanently deleted \(deletedName)."
                        } else {
                            applyDeletedHashes([deletedHash])
                            trashCount += 1
                            deleteBannerMessage = "Moved \(deletedName) to Trash (kept 30 days)."
                        }
                    },
                    onPhotoRestoredFromTrash: { restoredHash, restoredName in
                        let norm = restoredHash.lowercased()
                        trashPhotos.removeAll { $0.hash.lowercased() == norm }
                        trashCount = trashPhotos.count
                        if isViewingTrash { rebuildTimeline() }
                        deleteBannerMessage = "Restored \(restoredName) to Cloud library."
                        Task { await loadPhotos() }
                    }
                )
            }
            .restoreOriginalsConfirmAlert(prompt: $restoreConfirmPrompt) { targets, prompt in
                startBatchRestore(targets: targets, exitSelectionAfter: !prompt.isRestoreAll)
            }
            .alert(
                deleteConfirmPrompt?.isPermanent == true ? "Delete Permanently?" : "Move to Trash?",
                isPresented: Binding(
                    get: { deleteConfirmPrompt != nil },
                    set: { if !$0 { deleteConfirmPrompt = nil } }
                ),
                presenting: deleteConfirmPrompt
            ) { prompt in
                Button(
                    prompt.isPermanent
                        ? "Delete Forever (\(prompt.targets.count))"
                        : "Move to Trash (\(prompt.targets.count))",
                    role: .destructive
                ) {
                    startBatchDelete(targets: prompt.targets, permanent: prompt.isPermanent)
                }
                Button("Cancel", role: .cancel) {
                    deleteConfirmPrompt = nil
                }
            } message: { prompt in
                let sizeStr = ByteCountFormatter.string(fromByteCount: max(0, prompt.totalBytes), countStyle: .file)
                if prompt.isPermanent {
                    Text(
                        "Permanently delete \(prompt.targets.count) item(s) (~\(sizeStr)) from your server? This cannot be undone."
                    )
                } else {
                    Text(
                        "Move \(prompt.targets.count) item(s) (~\(sizeStr)) to Trash? You can restore them anytime within 30 days."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var unproxiedBannerView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if isBatchProxying {
                    ProgressView()
                        .tint(PhotoHubPalette.orange)
                        .scaleEffect(0.85)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Creating proxies \(batchCompleted)/\(batchTotal)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundColor(PhotoHubPalette.ink)
                        if !batchStatusText.isEmpty {
                            Text(batchStatusText)
                                .font(.caption2)
                                .foregroundColor(PhotoHubPalette.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Stop") {
                        batchTask?.cancel()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundColor(PhotoHubPalette.deepOrange)
                } else if !unproxiedPhotos.isEmpty {
                    Button {
                        filterMode = (filterMode == .needsProxy) ? .all : .needsProxy
                    } label: {
                        HStack(spacing: 8) {
                            AnimatedPulseDot(color: PhotoHubPalette.orange)
                            Text(
                                filterMode == .needsProxy
                                ? "Showing \(unproxiedPhotos.count) unproxied · Tap for All"
                                : "\(unproxiedPhotos.count) item\(unproxiedPhotos.count == 1 ? "" : "s") missing proxy"
                            )
                            .font(.caption.weight(.bold))
                            .foregroundColor(PhotoHubPalette.ink)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        startBatchProxy()
                    } label: {
                        Text("Proxy All")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(PhotoHubPalette.orangeGradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBatchRestoring || isBatchDeleting)
                } else if let msg = batchBannerMessage {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(PhotoHubPalette.mint)
                    Text(msg)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(PhotoHubPalette.ink)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        batchBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(PhotoHubPalette.muted)
                            .padding(6)
                            .background(PhotoHubPalette.softPeach, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if isBatchProxying && batchTotal > 0 {
                let frac = min(1.0, max(0.04, Double(batchCompleted) / Double(batchTotal)))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PhotoHubPalette.softPeach)
                        Capsule()
                            .fill(PhotoHubPalette.orangeGradient)
                            .frame(width: geo.size.width * frac)
                            .animation(.easeOut(duration: 0.25), value: frac)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var restoreBannerView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if isBatchRestoring {
                    ProgressView()
                        .tint(PhotoHubPalette.orange)
                        .scaleEffect(0.85)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restoring originals \(restoreCompleted)/\(restoreTotal)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundColor(PhotoHubPalette.ink)
                        if !restoreStatusText.isEmpty {
                            Text(restoreStatusText)
                                .font(.caption2)
                                .foregroundColor(PhotoHubPalette.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Stop") {
                        restoreTask?.cancel()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundColor(PhotoHubPalette.deepOrange)
                } else if let msg = restoreBannerMessage {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(PhotoHubPalette.mint)
                    Text(msg)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(PhotoHubPalette.ink)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        restoreBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(PhotoHubPalette.muted)
                            .padding(6)
                            .background(PhotoHubPalette.softPeach, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if isBatchRestoring && restoreTotal > 0 {
                let frac = min(1.0, max(0.04, Double(restoreCompleted) / Double(restoreTotal)))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PhotoHubPalette.softPeach)
                        Capsule()
                            .fill(PhotoHubPalette.orangeGradient)
                            .frame(width: geo.size.width * frac)
                            .animation(.easeOut(duration: 0.25), value: frac)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PhotoHubPalette.orange.opacity(0.32), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var deleteBannerView: some View {
        HStack(spacing: 10) {
            if isBatchDeleting {
                ProgressView()
                    .tint(PhotoHubPalette.rose)
                    .scaleEffect(0.85)
                Text("Deleting selected photos from server…")
                    .font(.caption.weight(.bold))
                    .foregroundColor(PhotoHubPalette.ink)
                Spacer()
            } else if let msg = deleteBannerMessage {
                Image(systemName: "trash.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(PhotoHubPalette.rose)
                Text(msg)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(PhotoHubPalette.ink)
                    .lineLimit(2)
                Spacer()
                Button {
                    deleteBannerMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(PhotoHubPalette.muted)
                        .padding(6)
                        .background(PhotoHubPalette.softPeach, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PhotoHubPalette.rose.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var trashInfoBannerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.circle.fill")
                .font(.title3)
                .foregroundColor(PhotoHubPalette.rose)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trash · 30-Day Safety Bin")
                    .font(.caption.weight(.heavy))
                    .foregroundColor(PhotoHubPalette.ink)
                if isLoadingTrash {
                    Text("Loading deleted items…")
                        .font(.caption2)
                        .foregroundColor(PhotoHubPalette.muted)
                } else if trashPhotos.isEmpty {
                    Text("No deleted items.")
                        .font(.caption2)
                        .foregroundColor(PhotoHubPalette.muted)
                } else {
                    let sz = ByteCountFormatter.string(fromByteCount: max(0, trashBytes), countStyle: .file)
                    Text("\(trashPhotos.count) item(s) · ~\(sz) · Auto-removed after 30 days")
                        .font(.caption2)
                        .foregroundColor(PhotoHubPalette.muted)
                }
            }
            Spacer()
            if !trashPhotos.isEmpty {
                Button {
                    requestEmptyTrashAll()
                } label: {
                    Text("Empty")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(PhotoHubPalette.rose, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isBatchDeleting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PhotoHubPalette.rose.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PhotoHubPalette.rose.opacity(0.28), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var selectionRestoreBottomBar: some View {
        let selectedList = selectedPhotos
        let unrestored = selectedList.filter { !isRestoredOrProtected($0) }
        let targetBytes = isViewingTrash
            ? selectedList.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
            : (unrestored.isEmpty
                ? selectedList.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
                : unrestored.reduce(into: Int64(0)) { $0 += max(0, $1.size) })
        let sizeStr = ByteCountFormatter.string(fromByteCount: targetBytes, countStyle: .file)
        let actionsDisabled = selectedList.isEmpty || isBatchRestoring || isBatchProxying || isBatchDeleting

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedList.isEmpty ? "Tap photos to select" : "\(selectedList.count) selected")
                    .font(.subheadline.weight(.heavy).monospacedDigit())
                    .foregroundColor(PhotoHubPalette.ink)
                if !selectedList.isEmpty {
                    if isViewingTrash {
                        Text("~\(sizeStr) in Trash")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(PhotoHubPalette.muted)
                            .lineLimit(1)
                    } else {
                        let alreadyCount = selectedList.count - unrestored.count
                        Text(
                            alreadyCount > 0
                            ? "~\(sizeStr) · \(unrestored.count) new"
                            : "~\(sizeStr) · \(unrestored.count) original\(unrestored.count == 1 ? "" : "s")"
                        )
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.muted)
                        .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)

            Button {
                requestDeleteSelected()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.bold))
                    Text(isViewingTrash ? "Delete" : "Trash")
                        .font(.caption.weight(.bold))
                }
                .foregroundColor(PhotoHubPalette.rose)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(PhotoHubPalette.rose.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(PhotoHubPalette.rose.opacity(0.32), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .opacity(actionsDisabled ? 0.45 : 1.0)
            .disabled(actionsDisabled)

            Button {
                if isViewingTrash {
                    restoreSelectedFromTrash()
                } else {
                    requestRestoreSelected()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isViewingTrash ? "arrow.uturn.backward" : "icloud.and.arrow.down")
                        .font(.caption.weight(.bold))
                    Text("Restore")
                        .font(.caption.weight(.bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(PhotoHubPalette.orangeGradient, in: Capsule())
                .shadow(color: PhotoHubPalette.orange.opacity(actionsDisabled ? 0 : 0.30), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .opacity(actionsDisabled ? 0.45 : 1.0)
            .disabled(actionsDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(PhotoHubPalette.card, in: Capsule())
        .overlay(
            Capsule()
                .stroke(PhotoHubPalette.orange.opacity(0.75), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func enterSelectionMode(initialPhoto: ServerPhoto? = nil) {
        guard !isBatchRestoring, !isBatchProxying, !isBatchDeleting, !activeSourcePhotos.isEmpty else { return }
        if let initialPhoto {
            selectedPhotoHashes = [initialPhoto.hash.lowercased()]
        } else {
            selectedPhotoHashes = []
        }
        isSelectionMode = true
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedPhotoHashes = []
    }

    private func toggleSelection(for photo: ServerPhoto) {
        let key = photo.hash.lowercased()
        if selectedPhotoHashes.contains(key) {
            selectedPhotoHashes.remove(key)
        } else {
            selectedPhotoHashes.insert(key)
        }
    }

    private func requestRestoreSelected() {
        let targets = selectedPhotos
        guard !isBatchRestoring, !isBatchProxying, !isBatchDeleting, !targets.isEmpty else { return }
        restoreConfirmPrompt = buildRestoreConfirmPrompt(
            title: "Restore Selected Originals",
            targets: targets,
            isRestoreAll: false
        )
    }

    private func requestDeleteSelected() {
        let targets = selectedPhotos
        guard !isBatchRestoring, !isBatchProxying, !isBatchDeleting, !targets.isEmpty else { return }
        let totalBytes = targets.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
        deleteConfirmPrompt = DeleteConfirmPrompt(targets: targets, totalBytes: totalBytes, isPermanent: isViewingTrash)
    }

    private func requestEmptyTrashAll() {
        guard !trashPhotos.isEmpty, !isBatchDeleting else { return }
        let totalBytes = trashPhotos.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
        deleteConfirmPrompt = DeleteConfirmPrompt(targets: trashPhotos, totalBytes: totalBytes, isPermanent: true)
    }

    private func loadTrashPhotos() async {
        guard !isLoadingTrash else { return }
        isLoadingTrash = true
        defer { isLoadingTrash = false }
        do {
            let res = try await PhotoHubAPIClient(settings: settings).fetchTrashPhotos()
            trashPhotos = res.photos
            trashCount = res.total
            trashBytes = res.trashBytes
            if isViewingTrash {
                rebuildTimeline()
            }
        } catch {
            deleteBannerMessage = "Could not load Trash: \(error.localizedDescription)"
        }
    }

    private func restoreSelectedFromTrash() {
        let targets = selectedPhotos
        guard isViewingTrash, !targets.isEmpty, !isBatchDeleting else { return }
        exitSelectionMode()
        isBatchDeleting = true
        deleteBannerMessage = nil
        let targetHashes = targets.map(\.hash)
        let settings = self.settings
        Task {
            do {
                let restored = try await PhotoHubAPIClient(settings: settings).restoreServerPhotosFromTrash(hashes: targetHashes)
                let restoredSet = Set(restored.map { $0.lowercased() })
                trashPhotos.removeAll { restoredSet.contains($0.hash.lowercased()) }
                trashCount = trashPhotos.count
                trashBytes = trashPhotos.reduce(0) { $0 + max(0, $1.size) }
                isBatchDeleting = false
                if isViewingTrash { rebuildTimeline() }
                deleteBannerMessage = "Restored \(restored.count) item(s) to Cloud library."
                await loadPhotos()
            } catch {
                isBatchDeleting = false
                deleteBannerMessage = "Restore failed: \(error.localizedDescription)"
            }
        }
    }

    private func startBatchDelete(targets: [ServerPhoto], permanent: Bool) {
        guard !isBatchDeleting, !isBatchRestoring, !isBatchProxying, !targets.isEmpty else { return }
        deleteConfirmPrompt = nil
        exitSelectionMode()
        deleteBannerMessage = nil
        isBatchDeleting = true

        let targetHashes = targets.map(\.hash)
        let settings = self.settings
        Task {
            do {
                let client = PhotoHubAPIClient(settings: settings)
                if permanent {
                    let result = try await client.emptyServerTrash(hashes: targetHashes)
                    let removedSet = Set((result.deleted ?? []).map { $0.lowercased() })
                    trashPhotos.removeAll { removedSet.contains($0.hash.lowercased()) }
                    trashCount = trashPhotos.count
                    trashBytes = trashPhotos.reduce(0) { $0 + max(0, $1.size) }
                    if isViewingTrash { rebuildTimeline() }
                    let freedStr = ByteCountFormatter.string(fromByteCount: max(0, result.freedBytes ?? 0), countStyle: .file)
                    isBatchDeleting = false
                    deleteBannerMessage = "Permanently deleted \(result.deleted?.count ?? 0) item(s) (freed ~\(freedStr))."
                } else {
                    let result = try await client.moveServerPhotosToTrash(hashes: targetHashes)
                    let removed = (result.deleted ?? []) + (result.missing ?? [])
                    applyDeletedHashes(removed)
                    let count = result.deleted?.count ?? 0
                    trashCount += count
                    isBatchDeleting = false
                    deleteBannerMessage = "Moved \(count) item(s) to Trash (kept 30 days)."
                }
            } catch APIClientError.httpError(401, _) {
                isBatchDeleting = false
                LocalProxySyncManager.shared.cancel()
                settings.signOut()
            } catch {
                isBatchDeleting = false
                deleteBannerMessage = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyDeletedHashes(_ rawHashes: [String]) {
        let removedSet = Set(
            rawHashes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !removedSet.isEmpty else { return }

        photos.removeAll { removedSet.contains($0.hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        ThumbnailMemoryCache.shared.remove(hashes: removedSet)
        thumbCacheRevision &+= 1
        failedPreviewHashes = failedPreviewHashes.filter { !removedSet.contains($0.lowercased()) }
        selectedPhotoHashes = selectedPhotoHashes.filter { !removedSet.contains($0.lowercased()) }
        refreshLocallyProtectedHashes()
        rebuildTimeline()
    }

    private func buildRestoreConfirmPrompt(
        title: String,
        targets: [ServerPhoto],
        isRestoreAll: Bool
    ) -> RestoreConfirmPrompt {
        RestoreConfirmPrompt.build(
            title: title,
            targets: targets,
            locallyProtectedHashes: locallyProtectedHashes,
            isRestoreAll: isRestoreAll
        )
    }

    private func startBatchRestore(targets: [ServerPhoto], exitSelectionAfter: Bool) {
        guard !isBatchRestoring, !isBatchProxying, !targets.isEmpty else { return }
        restoreConfirmPrompt = nil
        if exitSelectionAfter {
            exitSelectionMode()
        }
        restoreTask?.cancel()
        restoreBannerMessage = nil
        restoreCompleted = 0
        restoreTotal = targets.count
        restoreStatusText = "Preparing..."
        isBatchRestoring = true

        restoreTask = Task {
            let authorized = await PhotoLibraryService.requestWriteAuthorizationAsync()
            guard authorized else {
                isBatchRestoring = false
                restoreStatusText = ""
                restoreTask = nil
                restoreBannerMessage = "Photos permission is required to save originals."
                return
            }

            let client = PhotoHubAPIClient(settings: settings)
            let summary = await BatchRestoreRunner.run(
                targets: targets,
                client: client
            ) { completed, _, displayName, updatedPhoto in
                if let updatedPhoto {
                    applyUpdatedPhoto(updatedPhoto)
                }
                restoreCompleted = completed
                restoreStatusText = displayName
            }

            isBatchRestoring = false
            restoreStatusText = ""
            restoreTask = nil
            refreshLocallyProtectedHashes()
            restoreBannerMessage = summary.message
        }
    }

    private func refreshLocallyProtectedHashes() {
        locallyProtectedHashes = Set(
            photos.map { $0.hash.lowercased() }
                .filter { LocalProxyTracker.shared.isRestoredMasterHash($0) }
        )
    }

    private func startBatchProxy() {
        guard !isBatchProxying, !isBatchRestoring else { return }
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

            var succeeded = 0
            var failed = 0

            await withTaskGroup(of: BatchProxyOutcome?.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        await Self.processNextBatchProxyItem(
                            queue: queue,
                            client: client,
                            videoSemaphore: videoSemaphore
                        )
                    }
                }

                for await outcome in group {
                    guard let outcome else { continue }
                    switch outcome {
                    case .updated(let updated):
                        applyUpdatedPhoto(updated)
                        succeeded += 1
                    case .failed:
                        failed += 1
                    }
                    batchCompleted += 1
                    batchStatusText = outcome.displayName

                    if !Task.isCancelled {
                        group.addTask {
                            await Self.processNextBatchProxyItem(
                                queue: queue,
                                client: client,
                                videoSemaphore: videoSemaphore
                            )
                        }
                    }
                }
            }

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
            if succeeded > 0 && !cancelled {
                LocalProxySyncManager.shared.startPrefetchIfNeeded(for: photos, settings: settings)
            }
            if unproxiedPhotos.isEmpty && filterMode == .needsProxy {
                filterMode = .all
            }
        }
    }

    private static func processNextBatchProxyItem(
        queue: AsyncWorkQueue<ServerPhoto>,
        client: PhotoHubAPIClient,
        videoSemaphore: AsyncSemaphore
    ) async -> BatchProxyOutcome? {
        guard !Task.isCancelled, let item = await queue.next() else {
            return nil
        }
        if item.isVideo {
            await videoSemaphore.acquire()
        }
        do {
            let updated = try await client.createAndRegisterProxy(for: item)
            if item.isVideo {
                await videoSemaphore.release()
            }
            return .updated(updated)
        } catch {
            if item.isVideo {
                await videoSemaphore.release()
            }
            return .failed(item.originalName)
        }
    }

    private var emptyFilteredMessage: String {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No backed-up items match \"\(searchQuery)\"."
        }
        if filterMode == .needsProxy && unproxiedPhotos.isEmpty {
            return "All photos on your server have compressed proxies."
        }
        switch mediaTypeFilter {
        case .all:
            return "No items match the current filter."
        case .photos:
            return "No photos match the current filter."
        case .videos:
            return "No videos match the current filter."
        case .favorites:
            return "Tap the ♥ heart on any photo in the viewer to add it to Favorites."
        case .protectedOnly:
            return "No restored originals are protected yet."
        case .trash:
            return "Your Trash is empty. Deleted items stay here for 30 days."
        }
    }

    @ViewBuilder
    private var cloudHeroStorageCard: some View {
        let storage = settings.serverStorage
        let usedBytes = storage?.usedBytes ?? totalServerBytes
        let usedStr = ByteCountFormatter.string(fromByteCount: max(0, usedBytes), countStyle: .file)
        let quotaBytes = storage?.quotaBytes ?? 0
        let hasQuota = quotaBytes > 0
        let fillFraction: Double = {
            if hasQuota {
                return min(1.0, max(0.03, Double(usedBytes) / Double(quotaBytes)))
            }
            if let diskTotal = storage?.diskTotalBytes, diskTotal > 0 {
                return min(1.0, max(0.04, Double(usedBytes) / Double(diskTotal)))
            }
            return usedBytes > 0 ? 0.22 : 0.04
        }()
        let quotaRightLabel: String = {
            if hasQuota {
                let qStr = ByteCountFormatter.string(fromByteCount: quotaBytes, countStyle: .file)
                let pct = Int((fillFraction * 100).rounded())
                return "\(qStr) (\(pct)%)"
            }
            if let free = storage?.diskFreeBytes, free > 0 {
                let freeStr = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                return "\(freeStr) free"
            }
            return "Unlimited"
        }()
        let splitSubtitle: String = {
            if let masters = storage?.mastersBytes, let proxies = storage?.proxiesBytes {
                let mStr = ByteCountFormatter.string(fromByteCount: max(0, masters), countStyle: .file)
                let pStr = ByteCountFormatter.string(fromByteCount: max(0, proxies), countStyle: .file)
                return "Originals \(mStr) · Proxies \(pStr)"
            }
            return "Originals & compressed proxies synced"
        }()

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SunnyMascotView(mood: activeHeroMood, size: 54)

                VStack(alignment: .leading, spacing: 5) {
                    Text(greetingTitle)
                        .font(.title3.weight(.heavy))
                        .foregroundColor(PhotoHubPalette.ink)
                        .lineLimit(1)

                    Text("\(photos.count) total · \(photoCount) photos · \(videoCount) videos")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // Warm Storage Meter Bar (matches webpage `.storage-meter-wrap`)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(usedStr) used")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.ink)
                    Spacer()
                    Text(quotaRightLabel)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.muted)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PhotoHubPalette.softPeach)
                            .overlay(
                                Capsule()
                                    .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                            )
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [PhotoHubPalette.warmAmber, PhotoHubPalette.orange, PhotoHubPalette.deepOrange],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, geo.size.width * fillFraction))
                            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fillFraction)
                    }
                }
                .frame(height: 9)

                Text(splitSubtitle)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundColor(PhotoHubPalette.muted)
            }
        }
        .padding(16)
        .background(
            ZStack {
                PhotoHubPalette.card
                LinearGradient(
                    colors: [PhotoHubPalette.orange.opacity(0.07), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
        )
        .shadow(color: PhotoHubPalette.orange.opacity(0.08), radius: 14, y: 6)
    }

    @ViewBuilder
    private func cloudControlBar(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Search Input + Compact Grouping Segmented Pill
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.bold))
                        .foregroundColor(PhotoHubPalette.muted)
                    TextField("Search name, date, month, camera…", text: $searchQuery)
                        .font(.caption.weight(.medium))
                        .foregroundColor(PhotoHubPalette.ink)
                        .compatibleAutocorrectionDisabled()
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(PhotoHubPalette.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(PhotoHubPalette.canvas, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                )

                // Segmented Grouping Pill (`Day | Month | Year`)
                HStack(spacing: 2) {
                    ForEach(ServerTimelineGrouping.allCases) { mode in
                        let isSelected = timelineGrouping == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                timelineGrouping = mode
                            }
                        } label: {
                            Text(mode.shortLabel)
                                .font(.caption2.weight(.bold))
                                .foregroundColor(isSelected ? PhotoHubPalette.ink : PhotoHubPalette.muted)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? PhotoHubPalette.card : Color.clear,
                                    in: Capsule()
                                )
                                .shadow(color: Color.black.opacity(isSelected ? 0.08 : 0), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(PhotoHubPalette.softPeach, in: Capsule())
                .overlay(Capsule().stroke(PhotoHubPalette.cardBorder, lineWidth: 1))
            }

            // Filter Pills (`All`, `Photos`, `Videos`, `♥ Favorites`, `Protected`, `Trash`, + `Needs Proxy`)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ServerMediaTypeFilter.allCases) { media in
                        let isSelected = (mediaTypeFilter == media && filterMode == .all)
                        let isTrashPill = (media == .trash)
                        let label: String = {
                            if media == .favorites && favoriteCount > 0 {
                                return "\(media.rawValue) (\(favoriteCount))"
                            }
                            if media == .protectedOnly && protectedCount > 0 {
                                return "\(media.rawValue) (\(protectedCount))"
                            }
                            if media == .trash && trashCount > 0 {
                                return "\(media.rawValue) (\(trashCount))"
                            }
                            return media.rawValue
                        }()
                        let activeBg = isTrashPill ? PhotoHubPalette.rose : PhotoHubPalette.orange
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                filterMode = .all
                                mediaTypeFilter = media
                            }
                        } label: {
                            Text(label)
                                .font(.caption.weight(.bold))
                                .foregroundColor(isSelected ? .white : (isTrashPill && trashCount > 0 ? PhotoHubPalette.rose : PhotoHubPalette.muted))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? activeBg : PhotoHubPalette.canvas,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? activeBg : PhotoHubPalette.cardBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if !unproxiedPhotos.isEmpty || filterMode == .needsProxy {
                        let isSelected = filterMode == .needsProxy
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                filterMode = isSelected ? .all : .needsProxy
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isSelected ? Color.white : PhotoHubPalette.orange)
                                    .frame(width: 6, height: 6)
                                Text("Needs Proxy (\(unproxiedPhotos.count))")
                                    .font(.caption.weight(.bold).monospacedDigit())
                            }
                            .foregroundColor(isSelected ? .white : PhotoHubPalette.deepOrange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? PhotoHubPalette.orange : PhotoHubPalette.softPeach,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? PhotoHubPalette.orange : PhotoHubPalette.orange.opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Year Quick Jump Pills (`2026 · 412`, `2025 · 801`, ...)
            if timelineData.years.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(timelineData.years) { yr in
                            let isSelected = selectedYearAnchor == yr.anchorId
                            Button {
                                selectedYearAnchor = yr.anchorId
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    scrollProxy.scrollTo(yr.anchorId, anchor: .top)
                                }
                            } label: {
                                Text("\(yr.label) · \(yr.itemCount)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(
                                        isSelected ? PhotoHubPalette.orange : PhotoHubPalette.softPeach,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(isSelected ? PhotoHubPalette.orange : PhotoHubPalette.cardBorder, lineWidth: 1)
                                    )
                                    .foregroundColor(isSelected ? .white : PhotoHubPalette.ink)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func yearBannerHeader(for section: ServerTimelineSection) -> some View {
        let yearInfo = timelineData.years.first(where: { $0.label == section.yearLabel })
        HStack(alignment: .center) {
            Text(section.yearLabel)
                .font(.title2.weight(.heavy))
                .foregroundColor(PhotoHubPalette.ink)
            Spacer()
            if let yearInfo {
                Text("\(yearInfo.itemCount) items")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundColor(PhotoHubPalette.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(PhotoHubPalette.softPeach, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func timelineSectionHeader(_ section: ServerTimelineSection) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.subheadline.weight(.heavy))
                .foregroundColor(PhotoHubPalette.ink)
            Spacer()
            if isSelectionMode {
                let secHashes = section.photos.map { $0.hash.lowercased() }
                let allSecSelected = !secHashes.isEmpty && secHashes.allSatisfy { selectedPhotoHashes.contains($0) }
                Button(allSecSelected ? "Clear" : "Select") {
                    if allSecSelected {
                        for h in secHashes { selectedPhotoHashes.remove(h) }
                    } else {
                        for h in secHashes { selectedPhotoHashes.insert(h) }
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundColor(PhotoHubPalette.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(PhotoHubPalette.softPeach, in: Capsule())
            } else {
                Text("\(section.photos.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundColor(PhotoHubPalette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PhotoHubPalette.softPeach.opacity(0.85), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(PhotoHubPalette.canvas.opacity(0.94))
    }

    @ViewBuilder
    private func immichTimelineScrubber(scrollProxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let totalHeight = max(1, geo.size.height)
            let handleSpan = max(1, totalHeight - 36)
            let halfBubbleSpan = max(0, totalHeight / 2 - 20)
            let count = timelineData.sections.count

            ZStack(alignment: .topTrailing) {
                Capsule()
                    .fill(isScrubbingTimeline ? PhotoHubPalette.orange : PhotoHubPalette.muted.opacity(0.45))
                    .frame(width: isScrubbingTimeline ? 6 : 4, height: 36)
                    .padding(.trailing, 3)
                    .offset(y: max(0, min(handleSpan, scrubFraction * handleSpan)))
            }
            .frame(width: 24, height: totalHeight, alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.y / totalHeight))
                        scrubFraction = fraction
                        isScrubbingTimeline = true
                        let idx = min(count - 1, max(0, Int((fraction * CGFloat(count - 1)).rounded())))
                        if scrubSectionIndex != idx {
                            scrubSectionIndex = idx
                            let target = timelineData.sections[idx]
                            selectedYearAnchor = "year-\(target.yearLabel)"
                            scrollProxy.scrollTo(target.anchorId, anchor: .top)
                        }
                    }
                    .onEnded { _ in
                        isScrubbingTimeline = false
                    }
            )
            .overlay(alignment: .leading) {
                if isScrubbingTimeline,
                   let idx = scrubSectionIndex,
                   timelineData.sections.indices.contains(idx) {
                    let sec = timelineData.sections[idx]
                    Text(sec.scrubLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .shadow(radius: 4)
                        .fixedSize()
                        .offset(
                            x: -138,
                            y: max(-halfBubbleSpan, min(halfBubbleSpan, (scrubFraction - 0.5) * totalHeight))
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 24)
        .padding(.vertical, 40)
        .padding(.trailing, 2)
    }

    private func rebuildTimeline() {
        let built = ServerTimelineBuilder.build(
            photos: activeSourcePhotos,
            filterMode: filterMode,
            mediaTypeFilter: mediaTypeFilter,
            grouping: timelineGrouping,
            searchQuery: searchQuery,
            locallyProtectedHashes: locallyProtectedHashes
        )
        timelineData = built
        if let selectedYearAnchor,
           built.years.contains(where: { $0.anchorId == selectedYearAnchor }) {
            return
        }
        selectedYearAnchor = built.years.first?.anchorId
    }

    private func applyUpdatedPhoto(_ updated: ServerPhoto) {
        if let idx = photos.firstIndex(where: { $0.hash.lowercased() == updated.hash.lowercased() }) {
            photos[idx] = updated
            rebuildTimeline()
        }
        refreshLocallyProtectedHashes()
        failedPreviewHashes.remove(updated.hash)
        let targetHash = updated.hash
        Task.detached(priority: .utility) {
            if let data = LocalProxyStore.shared.previewData(forHash: targetHash),
               let thumb = ThumbnailMemoryCache.decodeGridThumbnail(from: data, maxPixelSize: 360) {
                ThumbnailMemoryCache.shared.setImage(thumb, forHash: targetHash)
                await MainActor.run {
                    thumbCacheRevision &+= 1
                }
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
            refreshLocallyProtectedHashes()
            rebuildTimeline()
        }
        // Grid cells decode 360px thumbnails lazily off the main thread via ThumbnailMemoryCache
        // so opening huge libraries stays instant and memory-bounded (~64 MB cap).
        thumbCacheRevision &+= 1
    }

    private func loadPhotos() async {
        isLoading = true
        defer { isLoading = false }
        let client = PhotoHubAPIClient(settings: settings)
        async let whoamiTask: WhoAmIResponse? = try? await client.whoami()
        do {
            let fetched = try await client.fetchAllServerPhotos(sync: true) { partial, tc in
                Task { @MainActor in
                    trashCount = tc
                    if partial.count >= 300 {
                        photos = partial
                        if !isViewingTrash { rebuildTimeline() }
                    }
                }
            }
            LocalProxyStore.shared.savePhotos(
                fetched,
                baseURL: settings.normalizedBaseURL,
                apiKey: settings.apiKey
            )
            // Link any already-present Apple Photos assets by local metadata (zero iCloud download)
            // so grid thumbnails & videos load directly from native Photos without server downloads.
            await Task.detached(priority: .utility) {
                PhotoLibraryService.reconcileExistingNativeGalleryAssets(for: fetched)
            }.value
            photos = fetched
            refreshLocallyProtectedHashes()
            rebuildTimeline()
            thumbCacheRevision &+= 1
            for photo in fetched where !photo.needsProxy {
                failedPreviewHashes.remove(photo.hash)
            }
            errorMessage = nil
            if let who = await whoamiTask {
                settings.applyServerCapabilities(storage: who.storage, s3Enabled: who.s3Enabled)
                settings.updateResolvedNode(
                    serverUrl: "",
                    nodeId: who.nodeId,
                    folderName: who.userFolder,
                    email: who.email,
                    name: who.name
                )
            }
            LocalProxySyncManager.shared.startPrefetchIfNeeded(for: fetched, settings: settings)
        } catch APIClientError.httpError(401, _) {
            LocalProxySyncManager.shared.cancel()
            settings.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCompressedPreviewIfNeeded(for photo: ServerPhoto) async {
        guard ThumbnailMemoryCache.shared.image(forHash: photo.hash) == nil else { return }

        let targetHash = photo.hash

        // 1. Check Native Apple Photos FIRST (zero network download, zero duplicate app cache!)
        if let nativeThumb = await PhotoLibraryService.loadNativeGalleryThumbnail(forMasterHash: targetHash, maxPixelSize: 360) {
            ThumbnailMemoryCache.shared.setImage(nativeThumb, forHash: targetHash)
            failedPreviewHashes.remove(targetHash)
            thumbCacheRevision &+= 1
            return
        }

        // 2. Check local app preview cache (for items not currently in this phone's Photos library)
        let decodedLocal: UIImage? = await Task.detached(priority: .utility) {
            guard let cachedData = LocalProxyStore.shared.previewData(forHash: targetHash) else {
                return nil
            }
            return ThumbnailMemoryCache.decodeGridThumbnail(from: cachedData, maxPixelSize: 360)
        }.value

        if let decodedLocal {
            ThumbnailMemoryCache.shared.setImage(decodedLocal, forHash: targetHash)
            failedPreviewHashes.remove(targetHash)
            thumbCacheRevision &+= 1
            return
        }

        // Un-proxied videos do not have a server preview image yet; avoid pulling gigabytes of video via /preview.
        if photo.isVideo && photo.needsProxy {
            failedPreviewHashes.insert(targetHash)
            return
        }

        // 3. On-demand fallback to server preview (only for cloud-only items not on this phone)
        let client = PhotoHubAPIClient(settings: settings)
        if let rawData = try? await client.downloadPhotoPreviewData(hash: targetHash) {
            let thumb: UIImage? = await Task.detached(priority: .utility) {
                guard let (_, smallData) = LocalProxyStore.shared.cacheDownloadedPreview(rawData, forHash: targetHash) else {
                    return nil
                }
                return ThumbnailMemoryCache.decodeGridThumbnail(from: smallData, maxPixelSize: 360)
            }.value
            if let thumb {
                ThumbnailMemoryCache.shared.setImage(thumb, forHash: targetHash)
                failedPreviewHashes.remove(targetHash)
                thumbCacheRevision &+= 1
                return
            }
        }
        failedPreviewHashes.insert(targetHash)
    }
}

private struct ServerTimelineYearSummary: Identifiable, Equatable {
    let year: Int?
    let label: String
    let anchorId: String
    let itemCount: Int
    let videoCount: Int

    var id: String { anchorId }
}

private struct ServerTimelineSection: Identifiable {
    let id: String
    let anchorId: String
    let year: Int?
    let yearLabel: String
    let startsNewYear: Bool
    let title: String
    let scrubLabel: String
    let subtitle: String
    let photos: [ServerPhoto]
}

private struct ServerTimelineData {
    let sections: [ServerTimelineSection]
    let years: [ServerTimelineYearSummary]

    static let empty = ServerTimelineData(sections: [], years: [])
}

@MainActor
private enum ServerTimelineBuilder {
    private static let sameYearDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()

    private static let otherYearDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }()

    private static let scrubMonthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMM")
        return f
    }()

    private static let monthFullSearchFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM MMM yyyy"
        return f
    }()

    static func build(
        photos: [ServerPhoto],
        filterMode: ServerGalleryFilter,
        mediaTypeFilter: ServerMediaTypeFilter,
        grouping: ServerTimelineGrouping,
        searchQuery: String = "",
        locallyProtectedHashes: Set<String> = []
    ) -> ServerTimelineData {
        let tokens = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let filtered = photos.filter { photo in
            if filterMode == .needsProxy && !photo.needsProxy {
                return false
            }
            let isProtected = photo.isProtectedOriginal || locallyProtectedHashes.contains(photo.hash.lowercased())
            switch mediaTypeFilter {
            case .all, .trash:
                break
            case .photos:
                if photo.isVideo { return false }
            case .videos:
                if !photo.isVideo { return false }
            case .favorites:
                if !photo.isFavorited { return false }
            case .protectedOnly:
                if !isProtected { return false }
            }
            if !tokens.isEmpty {
                let monthMeta = photo.parsedCreationDate.map { monthFullSearchFormatter.string(from: $0).lowercased() } ?? ""
                let haystack = [
                    photo.originalName.lowercased(),
                    photo.photoDate.lowercased(),
                    photo.savedPath.lowercased(),
                    (photo.cameraModel ?? "").lowercased(),
                    monthMeta,
                    photo.isVideo ? "video videos clip" : "photo photos image picture",
                    photo.isFavorited ? "fav favorite favorites heart" : "",
                    isProtected ? "protected original" : "",
                ].joined(separator: " ")
                for tok in tokens {
                    if !haystack.contains(tok) { return false }
                }
            }
            return true
        }
        guard !filtered.isEmpty else { return .empty }

        let paired = filtered.map { ($0, $0.parsedCreationDate) }.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case let (ld?, rd?):
                if ld != rd { return ld > rd }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            if lhs.0.originalName != rhs.0.originalName {
                return lhs.0.originalName > rhs.0.originalName
            }
            return lhs.0.hash > rhs.0.hash
        }

        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        struct TempBucket {
            let key: String
            let year: Int?
            let yearLabel: String
            let title: String
            let scrubLabel: String
            var photos: [ServerPhoto]
        }

        var buckets: [TempBucket] = []

        for (photo, date) in paired {
            let key: String
            let year: Int?
            let yearLabel: String
            let title: String
            let scrubLabel: String

            if let date {
                let comps = calendar.dateComponents([.year, .month, .day], from: date)
                let y = comps.year ?? currentYear
                let m = comps.month ?? 1
                let d = comps.day ?? 1
                year = y
                yearLabel = String(y)

                switch grouping {
                case .day:
                    key = String(format: "%04d-%02d-%02d", y, m, d)
                    if calendar.isDateInToday(date) {
                        title = "Today"
                    } else if calendar.isDateInYesterday(date) {
                        title = "Yesterday"
                    } else if y == currentYear {
                        title = sameYearDayFormatter.string(from: date)
                    } else {
                        title = otherYearDayFormatter.string(from: date)
                    }
                    scrubLabel = otherYearDayFormatter.string(from: date)
                case .month:
                    key = String(format: "%04d-%02d", y, m)
                    title = monthYearFormatter.string(from: date)
                    scrubLabel = scrubMonthYearFormatter.string(from: date)
                case .year:
                    key = String(y)
                    title = String(y)
                    scrubLabel = String(y)
                }
            } else {
                key = "undated"
                year = nil
                yearLabel = "Undated"
                title = "Undated"
                scrubLabel = "Undated"
            }

            if let lastIdx = buckets.indices.last, buckets[lastIdx].key == key {
                buckets[lastIdx].photos.append(photo)
            } else {
                buckets.append(
                    TempBucket(
                        key: key,
                        year: year,
                        yearLabel: yearLabel,
                        title: title,
                        scrubLabel: scrubLabel,
                        photos: [photo]
                    )
                )
            }
        }

        var sections: [ServerTimelineSection] = []
        sections.reserveCapacity(buckets.count)

        var yearSummaries: [ServerTimelineYearSummary] = []
        var yearIndexMap: [String: Int] = [:]
        var prevYearLabel: String?

        for bucket in buckets {
            let startsNewYear = (bucket.yearLabel != prevYearLabel)
            prevYearLabel = bucket.yearLabel

            let totalCount = bucket.photos.count
            let videoCount = bucket.photos.reduce(into: 0) { count, item in
                if item.isVideo { count += 1 }
            }
            let photoCount = max(0, totalCount - videoCount)

            let subtitle: String
            if photoCount > 0 && videoCount > 0 {
                subtitle = "\(photoCount) photo\(photoCount == 1 ? "" : "s") · \(videoCount) video\(videoCount == 1 ? "" : "s")"
            } else if videoCount > 0 {
                subtitle = "\(videoCount) video\(videoCount == 1 ? "" : "s")"
            } else {
                subtitle = "\(photoCount) photo\(photoCount == 1 ? "" : "s")"
            }

            sections.append(
                ServerTimelineSection(
                    id: bucket.key,
                    anchorId: "sec-\(bucket.key)",
                    year: bucket.year,
                    yearLabel: bucket.yearLabel,
                    startsNewYear: startsNewYear,
                    title: bucket.title,
                    scrubLabel: bucket.scrubLabel,
                    subtitle: subtitle,
                    photos: bucket.photos
                )
            )

            if let existingIdx = yearIndexMap[bucket.yearLabel] {
                let prev = yearSummaries[existingIdx]
                yearSummaries[existingIdx] = ServerTimelineYearSummary(
                    year: prev.year,
                    label: prev.label,
                    anchorId: prev.anchorId,
                    itemCount: prev.itemCount + totalCount,
                    videoCount: prev.videoCount + videoCount
                )
            } else {
                yearIndexMap[bucket.yearLabel] = yearSummaries.count
                yearSummaries.append(
                    ServerTimelineYearSummary(
                        year: bucket.year,
                        label: bucket.yearLabel,
                        anchorId: "year-\(bucket.yearLabel)",
                        itemCount: totalCount,
                        videoCount: videoCount
                    )
                )
            }
        }

        return ServerTimelineData(sections: sections, years: yearSummaries)
    }
}

private struct ServerThumbnailCell: View {
    let photo: ServerPhoto
    let image: UIImage?
    let showPlaceholder: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let isRestoredOrProtected: Bool

    private let tileShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity.animation(.easeOut(duration: 0.22)))
                } else if showPlaceholder {
                    tileShape
                        .fill(PhotoHubPalette.softPeach)
                    VStack(spacing: 4) {
                        Image(systemName: photo.isVideo ? "video.fill" : "photo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(PhotoHubPalette.muted)
                        Text(photo.isVideo ? "Video" : "Photo")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(PhotoHubPalette.muted)
                    }
                } else {
                    WarmShimmerView(cornerRadius: 12)
                }

                if isSelected {
                    tileShape
                        .fill(PhotoHubPalette.orange.opacity(0.24))
                }
            }
            .clipShape(tileShape)
            .overlay {
                if isSelected {
                    tileShape
                        .stroke(PhotoHubPalette.orange, lineWidth: 2.5)
                } else {
                    tileShape
                        .stroke(PhotoHubPalette.cardBorder.opacity(0.45), lineWidth: 0.5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if photo.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("Video")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color(red: 0.08, green: 0.06, blue: 0.05).opacity(0.72), in: Capsule())
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.isFavorited {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(PhotoHubPalette.rose.opacity(0.92), in: Circle())
                        .shadow(color: Color.black.opacity(0.28), radius: 2, y: 1)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if isSelectionMode {
                    ZStack {
                        Circle()
                            .fill(isSelected ? PhotoHubPalette.orange : Color.black.opacity(0.45))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 1.8)
                            )
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .heavy))
                                .foregroundColor(.white)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                    .padding(7)
                } else if photo.isTrashed {
                    let days = photo.daysRemaining ?? 30
                    Text("\(days)d")
                        .font(.system(size: 9.5, weight: .heavy).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(PhotoHubPalette.rose.opacity(0.92), in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if isRestoredOrProtected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(PhotoHubPalette.mint.opacity(0.92), in: Circle())
                            .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
                    }
                    if photo.needsProxy {
                        Circle()
                            .fill(PhotoHubPalette.orange)
                            .frame(width: 9, height: 9)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.9), lineWidth: 1.2)
                            )
                    }
                }
                .padding(6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(isSelected ? 0.95 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isSelected)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct ServerPhotoDetailView: View {
    @State private var photosList: [ServerPhoto]
    @State private var currentIndex: Int
    let isTrashMode: Bool
    @ObservedObject var settings: AppSettings
    let onPhotoUpdated: (ServerPhoto) -> Void
    let onPhotoDeleted: (String, String, Bool) -> Void
    let onPhotoRestoredFromTrash: (String, String) -> Void

    init(
        photo: ServerPhoto,
        allPhotos: [ServerPhoto],
        isTrashMode: Bool,
        settings: AppSettings,
        onPhotoUpdated: @escaping (ServerPhoto) -> Void,
        onPhotoDeleted: @escaping (String, String, Bool) -> Void,
        onPhotoRestoredFromTrash: @escaping (String, String) -> Void
    ) {
        let list = allPhotos.isEmpty ? [photo] : allPhotos
        let idx = list.firstIndex(where: { $0.hash.lowercased() == photo.hash.lowercased() }) ?? 0
        self._photosList = State(initialValue: list)
        self._currentIndex = State(initialValue: idx)
        self.isTrashMode = isTrashMode
        self.settings = settings
        self.onPhotoUpdated = onPhotoUpdated
        self.onPhotoDeleted = onPhotoDeleted
        self.onPhotoRestoredFromTrash = onPhotoRestoredFromTrash
    }

    @Environment(\.dismiss) private var dismiss
    @State private var previewImagesByHash: [String: UIImage] = [:]
    @State private var compressedDataByHash: [String: Data] = [:]
    @State private var player: AVPlayer?
    @State private var localVideoProxyURL: URL?
    @State private var isLoadingVideo: Bool = false
    @State private var videoUnavailableNote: String?

    @State private var showChrome: Bool = true
    @State private var showInfoSheet: Bool = false
    @State private var showShareLinkSheet: Bool = false
    @State private var isBusy: Bool = false
    @State private var busyLabel: String = ""
    @State private var saveMessage: String?
    @State private var shareSheetItem: ShareSheetItem?
    @State private var showDeleteConfirm: Bool = false
    @State private var prefetchTask: Task<Void, Never>? = nil

    private var currentPhoto: ServerPhoto {
        let safeIdx = min(max(0, currentIndex), max(0, photosList.count - 1))
        return photosList[safeIdx]
    }

    private static let detailDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var needsProxyAction: Bool {
        currentPhoto.needsProxy || (currentPhoto.isVideo && localVideoProxyURL == nil && currentPhoto.hasVideoProxy != true && !isLoadingVideo)
    }

    private var isOriginalProtected: Bool {
        currentPhoto.isProtectedOriginal || LocalProxyTracker.shared.isRestoredMasterHash(currentPhoto.hash)
    }

    private var isActiveItemTrashed: Bool {
        isTrashMode || currentPhoto.isTrashed
    }

    private let lightboxBg = Color(red: 0.055, green: 0.039, blue: 0.031) // #0E0A08 deep warm espresso
    private let lightboxCardBg = Color(red: 0.125, green: 0.094, blue: 0.078) // #201814
    private let lightboxBorder = Color.white.opacity(0.12)
    private let lightboxInk = Color(red: 1.0, green: 0.969, blue: 0.941) // #FFF7F0
    private let lightboxMuted = Color(red: 0.78, green: 0.70, blue: 0.65)

    var body: some View {
        ZStack {
            lightboxBg.ignoresSafeArea()

            // Full-bleed Swipeable Pager Stage
            TabView(selection: $currentIndex) {
                ForEach(Array(photosList.enumerated()), id: \.element.hash) { idx, item in
                    let isCurrent = (idx == currentIndex)
                    ZStack {
                        if isCurrent, let player {
                            VideoPlayer(player: player)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal, 14)
                        } else if let img = previewImagesByHash[item.hash]
                            ?? ThumbnailMemoryCache.shared.image(forHash: item.hash) {
                            ZStack(alignment: .bottom) {
                                ZoomableLightboxImageView(
                                    image: img,
                                    onSingleTap: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            showChrome.toggle()
                                        }
                                    }
                                )

                                if isCurrent && isLoadingVideo {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .tint(PhotoHubPalette.orange)
                                            .scaleEffect(0.85)
                                        Text("Loading video proxy…")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(lightboxInk)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(lightboxCardBg.opacity(0.92), in: Capsule())
                                    .overlay(Capsule().stroke(lightboxBorder, lineWidth: 1))
                                    .padding(.bottom, 12)
                                }
                            }
                        } else if item.isVideo && item.needsProxy {
                            VStack(spacing: 12) {
                                SunnyMascotView(mood: .happy, size: 78)
                                Text("No Video Proxy Yet")
                                    .font(.headline.weight(.bold))
                                    .foregroundColor(lightboxInk)
                                Text("Tap Create Video Proxy below to generate a lightweight playable MP4 & thumbnail.")
                                    .font(.caption)
                                    .foregroundColor(lightboxMuted)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 28)
                            }
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
                            }
                        } else {
                            VStack(spacing: 12) {
                                SunnyMascotView(mood: .uploading, size: 74)
                                Text("Loading preview…")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(lightboxMuted)
                            }
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Chrome Overlay (Top Header + Bottom Control Sheet; fades smoothly on single tap)
            VStack(spacing: 10) {
                if showChrome {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentPhoto.originalName)
                                .font(.subheadline.weight(.heavy))
                                .foregroundColor(lightboxInk)
                                .lineLimit(1)
                            let dateStr = currentPhoto.parsedCreationDate.map { Self.detailDateFormatter.string(from: $0) }
                                ?? (currentPhoto.photoDate.isEmpty ? "Undated" : currentPhoto.photoDate)
                            let masterSizeStr = ByteCountFormatter.string(fromByteCount: currentPhoto.size, countStyle: .file)
                            let posStr = photosList.count > 1 ? " · \(currentIndex + 1)/\(photosList.count)" : ""
                            Text("\(dateStr) · \(masterSizeStr)\(posStr)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundColor(lightboxMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)

                        if !isActiveItemTrashed {
                            Button {
                                Task { await toggleFavoriteCurrentItem() }
                            } label: {
                                Image(systemName: currentPhoto.isFavorited ? "heart.fill" : "heart")
                                    .font(.caption.weight(.heavy))
                                    .foregroundColor(currentPhoto.isFavorited ? PhotoHubPalette.rose : lightboxInk)
                                    .frame(width: 34, height: 34)
                                    .background(Color.white.opacity(0.12), in: Circle())
                                    .overlay(Circle().stroke(lightboxBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            showInfoSheet = true
                        } label: {
                            Image(systemName: "info")
                                .font(.caption.weight(.heavy))
                                .foregroundColor(lightboxInk)
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.12), in: Circle())
                                .overlay(Circle().stroke(lightboxBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.heavy))
                                .foregroundColor(lightboxInk)
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.12), in: Circle())
                                .overlay(Circle().stroke(lightboxBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [lightboxBg.opacity(0.88), lightboxBg.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .transition(.opacity)
                }

                Spacer()

                if showChrome {
                    VStack(spacing: 8) {
                        if let videoUnavailableNote {
                            Text(videoUnavailableNote)
                                .font(.caption)
                                .foregroundColor(PhotoHubPalette.warmAmber)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }

                        if isBusy && !busyLabel.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(PhotoHubPalette.orange)
                                    .scaleEffect(0.85)
                                Text(busyLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(lightboxInk)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(lightboxCardBg, in: Capsule())
                            .overlay(Capsule().stroke(PhotoHubPalette.orange.opacity(0.4), lineWidth: 1))
                        }

                        if let saveMessage {
                            Text(saveMessage)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(PhotoHubPalette.mint)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }

                        // Frosted Dark Bottom Control Sheet
                        VStack(alignment: .leading, spacing: 11) {
                            let localVideoBytes: Int64? = {
                                guard let url = localVideoProxyURL,
                                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                                    return nil
                                }
                                return Int64(size)
                            }()
                            let dataBytes = compressedDataByHash[currentPhoto.hash].map { Int64($0.count) }
                            let previewBytes = localVideoBytes ?? dataBytes ?? currentPhoto.videoProxySize ?? currentPhoto.proxySize
                            let smallStr = previewBytes.map {
                                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                            }

                            // Clean Pill Badges Row (SHA-256 & technical EXIF tucked into `(i)` Details sheet)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    if currentPhoto.isVideo {
                                        Text("Video")
                                            .font(.caption2.weight(.bold))
                                            .foregroundColor(PhotoHubPalette.orange)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(PhotoHubPalette.orange.opacity(0.18), in: Capsule())
                                    }

                                    if currentPhoto.isFavorited {
                                        Text("♥ Favorite")
                                            .font(.caption2.weight(.bold))
                                            .foregroundColor(PhotoHubPalette.rose)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(PhotoHubPalette.rose.opacity(0.18), in: Capsule())
                                    }

                                    if isOriginalProtected {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.shield.fill")
                                                .font(.caption2)
                                            Text("Protected")
                                                .font(.caption2.weight(.bold))
                                        }
                                        .foregroundColor(PhotoHubPalette.mint)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(PhotoHubPalette.mint.opacity(0.18), in: Capsule())
                                    }

                                    if isActiveItemTrashed {
                                        let days = currentPhoto.daysRemaining ?? 30
                                        Text("In Trash · \(days)d left")
                                            .font(.caption2.weight(.bold))
                                            .foregroundColor(PhotoHubPalette.rose)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(PhotoHubPalette.rose.opacity(0.18), in: Capsule())
                                    } else {
                                        let proxyTint = currentPhoto.needsProxy ? PhotoHubPalette.warmAmber : PhotoHubPalette.mint
                                        Text(currentPhoto.needsProxy ? "Needs Proxy" : (smallStr.map { "Proxy \($0)" } ?? "Proxy Ready"))
                                            .font(.caption2.weight(.bold).monospacedDigit())
                                            .foregroundColor(proxyTint)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(proxyTint.opacity(0.18), in: Capsule())
                                    }
                                }
                            }

                            if isActiveItemTrashed {
                                HStack(spacing: 10) {
                                    Button {
                                        Task { await restoreCurrentItemFromTrash() }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.uturn.backward")
                                            Text("Restore to Cloud")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(PhotoHubPalette.orangeGradient, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)

                                    Button {
                                        showDeleteConfirm = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "trash.fill")
                                            Text("Delete")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundColor(PhotoHubPalette.rose)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .background(PhotoHubPalette.rose.opacity(0.16), in: Capsule())
                                        .overlay(Capsule().stroke(PhotoHubPalette.rose.opacity(0.36), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)
                                }
                            } else {
                                if isOriginalProtected {
                                    HStack(spacing: 8) {
                                        Image(systemName: "lock.shield.fill")
                                            .font(.caption)
                                            .foregroundColor(PhotoHubPalette.mint)
                                        Text("Protected from auto re-compression.")
                                            .font(.caption2.weight(.medium))
                                            .foregroundColor(lightboxMuted)
                                        Spacer()
                                        Button("Allow Re-Proxy") {
                                            Task { await updateOriginalProtection(false) }
                                        }
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(PhotoHubPalette.orange)
                                        .disabled(isBusy)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(PhotoHubPalette.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                if needsProxyAction {
                                    Button {
                                        Task { await createProxyForCurrentItem() }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "wand.and.stars")
                                            Text(currentPhoto.isVideo ? "Create Video Proxy" : "Create Proxy")
                                        }
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(PhotoHubPalette.warmAmber)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(PhotoHubPalette.warmAmber.opacity(0.14), in: Capsule())
                                        .overlay(Capsule().stroke(PhotoHubPalette.warmAmber.opacity(0.38), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)
                                }

                                // Primary Sunset Gradient CTA (`Share Original`)
                                Button {
                                    Task { await shareFullMasterOriginal() }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.subheadline.weight(.bold))
                                        Text("Share Original")
                                            .font(.subheadline.weight(.bold))
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(PhotoHubPalette.orangeGradient, in: Capsule())
                                    .shadow(color: PhotoHubPalette.orange.opacity(0.32), radius: 10, y: 4)
                                }
                                .buttonStyle(.plain)
                                .opacity(isBusy ? 0.5 : 1.0)
                                .disabled(isBusy)

                                // Secondary Action Pills (`Link`, `Save Proxy`, `Restore`, `Trash`)
                                HStack(spacing: 8) {
                                    Button {
                                        showShareLinkSheet = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "link")
                                                .font(.caption.weight(.bold))
                                            Text("Link")
                                                .font(.caption.weight(.bold))
                                        }
                                        .foregroundColor(lightboxInk)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.white.opacity(0.10), in: Capsule())
                                        .overlay(Capsule().stroke(lightboxBorder, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)

                                    Button {
                                        Task { await saveCompressedProxyToPhotos() }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: currentPhoto.isVideo ? "video" : "photo")
                                                .font(.caption.weight(.bold))
                                            Text("Proxy")
                                                .font(.caption.weight(.bold))
                                        }
                                        .foregroundColor(lightboxInk)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.white.opacity(0.10), in: Capsule())
                                        .overlay(Capsule().stroke(lightboxBorder, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(isBusy ? 0.45 : 1.0)
                                    .disabled(isBusy)

                                    Button {
                                        Task { await restoreFullMasterToPhotos() }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down.circle")
                                                .font(.caption.weight(.bold))
                                            Text("Restore")
                                                .font(.caption.weight(.bold))
                                        }
                                        .foregroundColor(lightboxInk)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.white.opacity(0.10), in: Capsule())
                                        .overlay(Capsule().stroke(lightboxBorder, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(isBusy ? 0.45 : 1.0)
                                    .disabled(isBusy)

                                    Button {
                                        showDeleteConfirm = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption.weight(.bold))
                                            .foregroundColor(PhotoHubPalette.rose)
                                            .frame(width: 42, height: 36)
                                            .background(PhotoHubPalette.rose.opacity(0.16), in: Capsule())
                                            .overlay(Capsule().stroke(PhotoHubPalette.rose.opacity(0.36), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(isBusy ? 0.45 : 1.0)
                                    .disabled(isBusy)
                                }
                            }
                        }
                        .padding(14)
                        .background(lightboxCardBg.opacity(0.94), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(lightboxBorder, lineWidth: 1)
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                    .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: currentPhoto.hash) {
            await loadCurrentItemMediaAndNeighbors()
        }
        .onChange(of: currentIndex) { _ in
            player?.pause()
            player = nil
            localVideoProxyURL = nil
            videoUnavailableNote = nil
            saveMessage = nil
        }
        .onDisappear {
            prefetchTask?.cancel()
            prefetchTask = nil
            player?.pause()
            player = nil
        }
        .sheet(item: $shareSheetItem) { item in
            ShareSheet(activityItems: item.fileURLs) {
                scheduleTempShareCleanup(item.fileURLs)
                shareSheetItem = nil
            }
        }
        .sheet(isPresented: $showInfoSheet) {
            PhotoInfoDetailSheet(
                photo: currentPhoto,
                isProtected: isOriginalProtected
            )
        }
        .sheet(isPresented: $showShareLinkSheet) {
            ShareLinkModalSheet(
                photo: currentPhoto,
                settings: settings
            )
        }
        .alert(
            isActiveItemTrashed ? "Delete Permanently?" : "Move to Trash?",
            isPresented: $showDeleteConfirm
        ) {
            Button(isActiveItemTrashed ? "Delete Forever" : "Move to Trash", role: .destructive) {
                Task { await deleteCurrentItemFromServer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let masterStr = ByteCountFormatter.string(fromByteCount: currentPhoto.size, countStyle: .file)
            if isActiveItemTrashed {
                Text("Permanently delete \(currentPhoto.originalName) (~\(masterStr)) from your server? This cannot be undone.")
            } else {
                Text("Move \(currentPhoto.originalName) (~\(masterStr)) to Trash? You can restore it anytime within 30 days.")
            }
        }
    }

    private func replaceCurrentPhoto(_ updated: ServerPhoto) {
        if photosList.indices.contains(currentIndex) {
            photosList[currentIndex] = updated
        }
        onPhotoUpdated(updated)
    }

    private func loadPreviewForPhoto(_ item: ServerPhoto) async {
        let hash = item.hash
        if previewImagesByHash[hash] != nil { return }

        if let nativeImg = await PhotoLibraryService.loadNativeGalleryPreviewImage(forMasterHash: hash, maxPixelSize: 1600) {
            previewImagesByHash[hash] = nativeImg
            return
        }
        if let cachedData = LocalProxyStore.shared.previewData(forHash: hash),
           let cachedImg = UIImage(data: cachedData) {
            previewImagesByHash[hash] = cachedImg
            compressedDataByHash[hash] = cachedData
            return
        }
        if !(item.isVideo && item.needsProxy) {
            let client = PhotoHubAPIClient(settings: settings)
            if let rawData = try? await client.downloadPhotoPreviewData(hash: hash),
               let (smallImg, smallJpg) = LocalProxyStore.shared.cacheDownloadedPreview(rawData, forHash: hash) {
                previewImagesByHash[hash] = smallImg
                compressedDataByHash[hash] = smallJpg
            }
        }
    }

    private func loadCurrentItemMediaAndNeighbors() async {
        let photoSnapshot = currentPhoto
        await loadPreviewForPhoto(photoSnapshot)

        // Preload adjacent items (±1) for silky-smooth swipe transitions
        let prevIdx = currentIndex - 1
        let nextIdx = currentIndex + 1
        if photosList.indices.contains(nextIdx) {
            let nextItem = photosList[nextIdx]
            Task { await loadPreviewForPhoto(nextItem) }
        }
        if photosList.indices.contains(prevIdx) {
            let prevItem = photosList[prevIdx]
            Task { await loadPreviewForPhoto(prevItem) }
        }

        prefetchTask?.cancel()
        let detailClient = PhotoHubAPIClient(settings: settings)
        let prefetchLimit: Int64 = photoSnapshot.isVideo ? 15 * 1024 * 1024 : 40 * 1024 * 1024
        prefetchTask = Task(priority: .utility) {
            await detailClient.warmConnectionIfNeeded()
            guard !Task.isCancelled,
                  photoSnapshot.size > 0,
                  photoSnapshot.size <= prefetchLimit else {
                return
            }
            _ = try? await OriginalDownloadCache.shared.getOrFetchOriginal(
                hash: photoSnapshot.hash,
                preferredFilename: photoSnapshot.originalName,
                expectedSizeBytes: photoSnapshot.size,
                isVideo: photoSnapshot.isVideo,
                client: detailClient
            )
        }

        if photoSnapshot.isVideo {
            await prepareVideoProxyIfNeeded()
        }
    }

    private func toggleFavoriteCurrentItem() async {
        let nextFav = !currentPhoto.isFavorited
        do {
            let updated = try await PhotoHubAPIClient(settings: settings).setPhotoFavorite(
                masterHash: currentPhoto.hash,
                favorite: nextFav
            )
            replaceCurrentPhoto(updated)
            saveMessage = nextFav ? "Added to Favorites ♥" : "Removed from Favorites"
        } catch {
            saveMessage = "Favorite update failed: \(error.localizedDescription)"
        }
    }

    private func restoreCurrentItemFromTrash() async {
        isBusy = true
        busyLabel = "Restoring from Trash…"
        saveMessage = nil
        defer {
            isBusy = false
            busyLabel = ""
        }
        do {
            let targetHash = currentPhoto.hash
            let targetName = currentPhoto.originalName
            _ = try await PhotoHubAPIClient(settings: settings).restoreServerPhotosFromTrash(hashes: [targetHash])
            player?.pause()
            player = nil
            onPhotoRestoredFromTrash(targetHash, targetName)
            dismiss()
        } catch {
            saveMessage = "Restore failed: \(error.localizedDescription)"
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
            replaceCurrentPhoto(updated)

            if let cachedData = LocalProxyStore.shared.previewData(forHash: updated.hash),
               let cachedImg = UIImage(data: cachedData) {
                previewImagesByHash[updated.hash] = cachedImg
                compressedDataByHash[updated.hash] = cachedData
            }
            if updated.isVideo,
               let videoURL = LocalProxyStore.shared.videoProxyURLIfExists(forHash: updated.hash) {
                localVideoProxyURL = videoURL
                let avPlayer = AVPlayer(url: videoURL)
                player = avPlayer
                avPlayer.play()
            }

            saveMessage = "Compressed proxy created and stored on server & local cache."
        } catch {
            saveMessage = "Proxy creation failed: \(error.localizedDescription)"
        }
    }

    private func prepareVideoProxyIfNeeded() async {
        if let nativePlayerItem = await PhotoLibraryService.loadNativeGalleryAVPlayerItem(forMasterHash: currentPhoto.hash) {
            let avPlayer = AVPlayer(playerItem: nativePlayerItem)
            player = avPlayer
            avPlayer.play()
            return
        }

        if let cachedURL = LocalProxyStore.shared.videoProxyURLIfExists(forHash: currentPhoto.hash) {
            localVideoProxyURL = cachedURL
            let avPlayer = AVPlayer(url: cachedURL)
            player = avPlayer
            avPlayer.play()
            return
        }

        guard !currentPhoto.needsProxy else { return }

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
            videoUnavailableNote = "No compressed video proxy on server yet. Tap Create Video Proxy below, or Share Original."
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
            await client.warmConnectionIfNeeded()
            let tempURL = try await OriginalDownloadCache.shared.getOrFetchShareCopy(
                hash: currentPhoto.hash,
                preferredFilename: currentPhoto.originalName,
                expectedSizeBytes: currentPhoto.size > 0 ? currentPhoto.size : nil,
                isVideo: currentPhoto.isVideo,
                client: client
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
        defer {
            isBusy = false
            busyLabel = ""
        }

        let authorized = await PhotoLibraryService.requestWriteAuthorizationAsync()
        guard authorized else {
            saveMessage = "Photos library permission is required."
            return
        }

        let photo = currentPhoto
        let alreadyInNativePhotos = await Task.detached(priority: .userInitiated) {
            if LocalProxyTracker.shared.hasAnyLiveGalleryAsset(forMasterHash: photo.hash) {
                return true
            }
            let prefix = ProxyGenerator.proxyPrefixTag(forMasterHash: photo.hash)
            if !prefix.isEmpty, let existingProxyId = PhotoLibraryService.scanExistingProxyPrefixesInPhotos()[prefix] {
                LocalProxyTracker.shared.markAsProxy(
                    assetId: existingProxyId,
                    proxySha256: photo.proxyHash ?? "",
                    masterHash: photo.hash,
                    originalName: photo.originalName
                )
                return true
            }
            if let existingOrigId = PhotoLibraryService.findMatchingOriginalAssetIdInPhotos(for: photo) {
                LocalProxyTracker.shared.markUploadedOriginal(assetId: existingOrigId, masterHash: photo.hash)
                return true
            }
            return false
        }.value

        if alreadyInNativePhotos {
            saveMessage = "Already in iPhone Photos (duplicate avoided)."
            return
        }

        do {
            if photo.isVideo {
                var videoURL = localVideoProxyURL ?? LocalProxyStore.shared.videoProxyURLIfExists(forHash: photo.hash)
                var tempDownloadURL: URL?
                defer {
                    if let tempDownloadURL {
                        try? FileManager.default.removeItem(at: tempDownloadURL)
                    }
                }

                if videoURL == nil, !photo.needsProxy {
                    busyLabel = "Downloading compressed MP4 proxy..."
                    let client = PhotoHubAPIClient(settings: settings)
                    let downloaded = try await client.downloadVideoProxyToTempFile(hash: photo.hash)
                    if let cached = LocalProxyStore.shared.copyVideoProxy(from: downloaded, forHash: photo.hash) {
                        videoURL = cached
                        localVideoProxyURL = cached
                        try? FileManager.default.removeItem(at: downloaded)
                    } else {
                        tempDownloadURL = downloaded
                        videoURL = downloaded
                    }
                }

                if let videoURL {
                    busyLabel = "Saving video proxy to Photos..."
                    _ = try await PhotoLibraryService.saveServerProxyToPhotosAsync(
                        photo: photo,
                        videoURL: videoURL
                    )
                    let sizeBytes = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
                    saveMessage = "Saved compressed video proxy (\(sizeStr)) to Photos."
                    return
                }
            }

            var dataToSave = compressedDataByHash[photo.hash]
            if dataToSave == nil {
                if let cached = LocalProxyStore.shared.previewData(forHash: photo.hash) {
                    dataToSave = LocalProxyStore.makeSmallCompressedPreview(from: cached, maxPixelSize: 800, quality: 0.65)?.1 ?? cached
                } else {
                    busyLabel = "Downloading compressed preview..."
                    let client = PhotoHubAPIClient(settings: settings)
                    if let raw = try? await client.downloadPhotoPreviewData(hash: photo.hash) {
                        dataToSave = LocalProxyStore.makeSmallCompressedPreview(from: raw, maxPixelSize: 800, quality: 0.65)?.1 ?? raw
                    }
                }
            }

            guard let dataToSave else {
                saveMessage = "Preview still loading."
                return
            }

            busyLabel = "Saving proxy to Photos..."
            _ = try await PhotoLibraryService.saveServerProxyToPhotosAsync(
                photo: photo,
                imageData: dataToSave
            )
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(dataToSave.count), countStyle: .file)
            saveMessage = "Saved compressed proxy (\(sizeStr)) to Photos."
        } catch {
            saveMessage = "Failed: \(error.localizedDescription)"
        }
    }

    private func restoreFullMasterToPhotos() async {
        isBusy = true
        busyLabel = "Downloading full-resolution original..."
        saveMessage = nil
        defer {
            isBusy = false
            busyLabel = ""
        }

        let authorized = await PhotoLibraryService.requestWriteAuthorizationAsync()
        guard authorized else {
            saveMessage = "Photos permission is required to save originals."
            return
        }

        do {
            let client = PhotoHubAPIClient(settings: settings)
            let (updated, fileSize) = try await PhotoLibraryService.restoreMasterToPhotos(
                photo: currentPhoto,
                client: client
            )
            if let updated {
                replaceCurrentPhoto(updated)
            }

            let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            saveMessage = "Restored original (\(sizeStr)) to Photos & protected it from re-proxying."
        } catch {
            saveMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func updateOriginalProtection(_ protected: Bool) async {
        isBusy = true
        busyLabel = protected ? "Protecting original..." : "Allowing re-proxy..."
        saveMessage = nil
        defer {
            isBusy = false
            busyLabel = ""
        }

        if !protected {
            LocalProxyTracker.shared.clearRestoredProtection(masterHash: currentPhoto.hash)
        }
        do {
            let client = PhotoHubAPIClient(settings: settings)
            let updated = try await client.setOriginalProtected(masterHash: currentPhoto.hash, protected: protected)
            replaceCurrentPhoto(updated)
            saveMessage = protected
                ? "Protected: this original won't be auto re-proxied."
                : "Unlocked: this photo can be compressed into a proxy again."
        } catch {
            saveMessage = "Failed to update protection: \(error.localizedDescription)"
        }
    }

    private func deleteCurrentItemFromServer() async {
        let permanent = isActiveItemTrashed
        isBusy = true
        busyLabel = permanent ? "Deleting permanently..." : "Moving to Trash..."
        saveMessage = nil
        defer {
            isBusy = false
            busyLabel = ""
        }

        do {
            let client = PhotoHubAPIClient(settings: settings)
            let deletedHash = currentPhoto.hash
            let deletedName = currentPhoto.originalName
            if permanent {
                _ = try await client.emptyServerTrash(hashes: [deletedHash])
            } else {
                _ = try await client.moveServerPhotosToTrash(hashes: [deletedHash])
            }
            player?.pause()
            player = nil
            onPhotoDeleted(deletedHash, deletedName, permanent)
            dismiss()
        } catch APIClientError.httpError(401, _) {
            LocalProxySyncManager.shared.cancel()
            settings.signOut()
            dismiss()
        } catch {
            saveMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}

private struct ZoomableLightboxImageView: View {
    let image: UIImage
    let onSingleTap: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let next = min(4.0, max(1.0, lastScale * value))
                            scale = next
                            if next <= 1.01 {
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                        .onEnded { _ in
                            if scale < 1.05 {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            } else {
                                lastScale = scale
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: scale > 1.02 ? 4 : 9999)
                        .onChanged { value in
                            guard scale > 1.02 else { return }
                            let maxX = geo.size.width * (scale - 1.0) / 2.0
                            let maxY = geo.size.height * (scale - 1.0) / 2.0
                            let nx = min(maxX, max(-maxX, lastOffset.width + value.translation.width))
                            let ny = min(maxY, max(-maxY, lastOffset.height + value.translation.height))
                            offset = CGSize(width: nx, height: ny)
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        if scale > 1.2 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
                .onTapGesture(count: 1) {
                    onSingleTap()
                }
        }
    }
}

private struct PhotoInfoDetailSheet: View {
    let photo: ServerPhoto
    let isProtected: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var copiedHash: Bool = false

    private static let infoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    private var takenText: String {
        photo.parsedCreationDate.map { Self.infoDateFormatter.string(from: $0) }
            ?? (photo.photoDate.isEmpty ? "Undated" : photo.photoDate)
    }

    var body: some View {
        AdaptiveNavigationStack {
            List {
                Section("Media") {
                    infoRow("Filename", photo.originalName)
                    infoRow("Type", photo.isVideo ? "Video" : "Photo")
                    infoRow("Date Taken", takenText)
                    if let camera = photo.cameraModel, !camera.isEmpty {
                        infoRow("Camera", camera)
                    }
                    infoRow(
                        "Original Size",
                        ByteCountFormatter.string(fromByteCount: max(0, photo.size), countStyle: .file)
                    )
                    if let proxySz = photo.videoProxySize ?? photo.proxySize, proxySz > 0 {
                        infoRow(
                            "Proxy Size",
                            ByteCountFormatter.string(fromByteCount: proxySz, countStyle: .file)
                        )
                    }
                    infoRow("Original Protection", isProtected ? "Protected on Device" : "Standard")
                }

                Section("Verification") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SHA-256 Checksum")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(photo.hash)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copiedHash ? "Copied SHA-256" : "Copy SHA-256") {
                            UIPasteboard.general.string = photo.hash
                            copiedHash = true
                        }
                        .font(.caption.weight(.bold))
                        .foregroundColor(PhotoHubPalette.orange)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ShareLinkModalSheet: View {
    let photo: ServerPhoto
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var titleText: String
    @State private var expiresHours: Int = 168
    @State private var passcodeText: String = ""
    @State private var isCreating: Bool = false
    @State private var createdLink: ShareLinkResult?
    @State private var errorText: String?
    @State private var copiedLink: Bool = false
    @State private var showActivityShare: Bool = false

    init(photo: ServerPhoto, settings: AppSettings) {
        self.photo = photo
        self.settings = settings
        self._titleText = State(initialValue: photo.originalName)
    }

    var body: some View {
        AdaptiveNavigationStack {
            Form {
                if let link = createdLink {
                    Section("Public Share Link Ready") {
                        Text(link.url)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        if link.hasPasscode == true {
                            Label("Protected with passcode", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundColor(PhotoHubPalette.mint)
                        }
                        HStack(spacing: 10) {
                            Button {
                                UIPasteboard.general.string = link.url
                                copiedLink = true
                            } label: {
                                Label(copiedLink ? "Copied!" : "Copy Link", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PhotoHubSoftButtonStyle())

                            Button {
                                showActivityShare = true
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PhotoHubPrimaryButtonStyle())
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Link Options") {
                        TextField("Title", text: $titleText)
                        Picker("Expires In", selection: $expiresHours) {
                            Text("24 Hours").tag(24)
                            Text("7 Days").tag(168)
                            Text("30 Days").tag(720)
                        }
                        SecureField("Optional Passcode", text: $passcodeText)
                    }

                    if let errorText {
                        Section {
                            Text(errorText)
                                .font(.caption)
                                .foregroundColor(PhotoHubPalette.rose)
                        }
                    }

                    Section {
                        Button {
                            Task { await createLink() }
                        } label: {
                            HStack {
                                if isCreating {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "link.badge.plus")
                                }
                                Text(isCreating ? "Creating…" : "Create Share Link")
                                    .font(.headline.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PhotoHubPrimaryButtonStyle())
                        .disabled(isCreating)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Share Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showActivityShare) {
                if let urlStr = createdLink?.url {
                    let items: [Any] = URL(string: urlStr).map { [$0] } ?? [urlStr]
                    ShareSheet(activityItems: items) {
                        showActivityShare = false
                    }
                }
            }
        }
    }

    private func createLink() async {
        isCreating = true
        errorText = nil
        defer { isCreating = false }
        do {
            let link = try await PhotoHubAPIClient(settings: settings).createShareLink(
                hashes: [photo.hash],
                title: titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? photo.originalName : titleText,
                expiresInHours: expiresHours,
                passcode: passcodeText
            )
            createdLink = link
        } catch {
            errorText = error.localizedDescription
        }
    }
}
