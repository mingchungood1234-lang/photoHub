import AVKit
import Photos
import SwiftUI

private enum ServerGalleryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsProxy = "Needs Proxy"

    var id: String { rawValue }
}

private enum ServerMediaTypeFilter: String, CaseIterable, Identifiable {
    case all = "All Media"
    case photos = "Photos Only"
    case videos = "Videos Only"

    var id: String { rawValue }
}

private enum ServerTimelineGrouping: String, CaseIterable, Identifiable {
    case day = "Date & Year"
    case month = "Month & Year"
    case year = "Year Only"

    var id: String { rawValue }
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
}

struct ServerGalleryView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var syncManager: LocalProxySyncManager

    init(settings: AppSettings) {
        self.settings = settings
        self._syncManager = ObservedObject(wrappedValue: LocalProxySyncManager.shared)
    }

    @State private var photos: [ServerPhoto] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: ServerPhoto?
    @State private var imageCache: [String: UIImage] = [:]
    @State private var compressedDataCache: [String: Data] = [:]
    @State private var failedPreviewHashes: Set<String> = []
    @State private var filterMode: ServerGalleryFilter = .all
    @State private var mediaTypeFilter: ServerMediaTypeFilter = .all
    @State private var timelineGrouping: ServerTimelineGrouping = .day
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
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 2)
    ]

    private var unproxiedPhotos: [ServerPhoto] {
        photos.filter { $0.needsProxy }
    }

    private func isRestoredOrProtected(_ photo: ServerPhoto) -> Bool {
        photo.isProtectedOriginal || locallyProtectedHashes.contains(photo.hash.lowercased())
    }

    private var visiblePhotos: [ServerPhoto] {
        timelineData.sections.flatMap(\.photos)
    }

    private var selectedPhotos: [ServerPhoto] {
        guard !selectedPhotoHashes.isEmpty else { return [] }
        return photos.filter { selectedPhotoHashes.contains($0.hash.lowercased()) }
    }

    var body: some View {
        AdaptiveNavigationStack {
            Group {
                if isLoading && photos.isEmpty {
                    ProgressView("Loading photos...")
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
                        description: "Upload photos or store them on your PhotoHub server to browse them here."
                    ) {
                        Button("Refresh") {
                            Task { await loadPhotos() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollViewReader { scrollProxy in
                        VStack(spacing: 0) {
                            if timelineData.years.count > 1 {
                                yearQuickJumpBar(scrollProxy: scrollProxy)
                            }

                            ZStack(alignment: .trailing) {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                        if let errorMessage {
                                            HStack(spacing: 6) {
                                                Image(systemName: "wifi.slash")
                                                    .font(.caption)
                                                    .foregroundColor(.orange)
                                                Text("Offline cache · \(errorMessage)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                        }

                                        if !unproxiedPhotos.isEmpty || isBatchProxying || batchBannerMessage != nil {
                                            unproxiedBannerView
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                        }

                                        if isBatchRestoring || restoreBannerMessage != nil {
                                            restoreBannerView
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 4)
                                        }

                                        if isBatchDeleting || deleteBannerMessage != nil {
                                            deleteBannerView
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 4)
                                        }

                                        if syncManager.isSyncing {
                                            HStack(spacing: 8) {
                                                ProgressView()
                                                    .scaleEffect(0.85)
                                                Text(
                                                    syncManager.statusText.isEmpty
                                                    ? "Syncing proxies (\(syncManager.completedCount)/\(syncManager.totalCount))..."
                                                    : syncManager.statusText
                                                )
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                Spacer()
                                                Button("Stop") {
                                                    syncManager.cancel()
                                                }
                                                .font(.caption.weight(.medium))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                        }

                                        if timelineData.sections.isEmpty {
                                            VStack(spacing: 10) {
                                                Text(emptyFilteredMessage)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                if filterMode != .all || mediaTypeFilter != .all {
                                                    Button("Show All") {
                                                        filterMode = .all
                                                        mediaTypeFilter = .all
                                                    }
                                                    .font(.subheadline.weight(.medium))
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .padding(.vertical, 44)
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
                                                    LazyVGrid(columns: columns, spacing: 2) {
                                                        ForEach(section.photos) { photo in
                                                            let norm = photo.hash.lowercased()
                                                            let isSelected = selectedPhotoHashes.contains(norm)
                                                            let protectedOrRestored = isRestoredOrProtected(photo)
                                                            ServerThumbnailCell(
                                                                photo: photo,
                                                                image: imageCache[photo.hash],
                                                                showPlaceholder: failedPreviewHashes.contains(photo.hash) || (photo.isVideo && photo.needsProxy),
                                                                isSelectionMode: isSelectionMode,
                                                                isSelected: isSelected,
                                                                isRestoredOrProtected: protectedOrRestored
                                                            )
                                                            .contentShape(Rectangle())
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
                                                    .padding(.bottom, 6)
                                                } header: {
                                                    timelineSectionHeader(section)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.bottom, 12)
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
            .navigationTitle(isSelectionMode ? "\(selectedPhotoHashes.count) Selected" : "Server")
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
                        .disabled(photos.isEmpty || isBatchRestoring || isBatchProxying || isBatchDeleting)

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
                            let isFiltered = (filterMode != .all || mediaTypeFilter != .all)
                            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "ellipsis.circle")
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
            .onChange(of: mediaTypeFilter) { _ in
                rebuildTimeline()
            }
            .onChange(of: timelineGrouping) { _ in
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
                ServerPhotoDetailView(
                    photo: photo,
                    settings: settings,
                    initialImage: imageCache[photo.hash],
                    initialCompressedData: compressedDataCache[photo.hash],
                    onPhotoUpdated: { updated in
                        applyUpdatedPhoto(updated)
                    },
                    onPhotoDeleted: { deletedHash, deletedName in
                        applyDeletedHashes([deletedHash])
                        deleteBannerMessage = "Deleted \(deletedName) from server."
                    }
                )
            }
            .restoreOriginalsConfirmAlert(prompt: $restoreConfirmPrompt) { targets, prompt in
                startBatchRestore(targets: targets, exitSelectionAfter: !prompt.isRestoreAll)
            }
            .alert(
                "Delete from Server?",
                isPresented: Binding(
                    get: { deleteConfirmPrompt != nil },
                    set: { if !$0 { deleteConfirmPrompt = nil } }
                ),
                presenting: deleteConfirmPrompt
            ) { prompt in
                Button(
                    "Delete \(prompt.targets.count) Photo\(prompt.targets.count == 1 ? "" : "s")",
                    role: .destructive
                ) {
                    startBatchDelete(targets: prompt.targets)
                }
                Button("Cancel", role: .cancel) {
                    deleteConfirmPrompt = nil
                }
            } message: { prompt in
                let sizeStr = ByteCountFormatter.string(fromByteCount: max(0, prompt.totalBytes), countStyle: .file)
                Text(
                    "Permanently delete \(prompt.targets.count) backed-up original(s) (~\(sizeStr)) and their server proxies from your PhotoHub server? This cannot be undone."
                )
            }
        }
    }

    @ViewBuilder
    private var unproxiedBannerView: some View {
        HStack(spacing: 10) {
            if isBatchProxying {
                ProgressView()
                    .scaleEffect(0.85)
                Text("Creating proxies \(batchCompleted)/\(batchTotal)")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Stop") {
                    batchTask?.cancel()
                }
                .font(.caption.weight(.semibold))
            } else if !unproxiedPhotos.isEmpty {
                Button {
                    filterMode = (filterMode == .needsProxy) ? .all : .needsProxy
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                        Text(
                            filterMode == .needsProxy
                            ? "Showing \(unproxiedPhotos.count) unproxied · Tap for All"
                            : "\(unproxiedPhotos.count) missing proxy"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Proxy All") {
                    startBatchProxy()
                }
                .font(.caption.weight(.semibold))
                .disabled(isBatchRestoring || isBatchDeleting)
            } else if let msg = batchBannerMessage {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    batchBannerMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private var restoreBannerView: some View {
        HStack(spacing: 10) {
            if isBatchRestoring {
                ProgressView()
                    .scaleEffect(0.85)
                Text("Restoring originals \(restoreCompleted)/\(restoreTotal)")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Stop") {
                    restoreTask?.cancel()
                }
                .font(.caption.weight(.semibold))
            } else if let msg = restoreBannerMessage {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    restoreBannerMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private var deleteBannerView: some View {
        HStack(spacing: 10) {
            if isBatchDeleting {
                ProgressView()
                    .scaleEffect(0.85)
                Text("Deleting selected photos from server...")
                    .font(.caption.weight(.medium))
                Spacer()
            } else if let msg = deleteBannerMessage {
                Image(systemName: "trash.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    deleteBannerMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private var selectionRestoreBottomBar: some View {
        let selectedList = selectedPhotos
        let unrestored = selectedList.filter { !isRestoredOrProtected($0) }
        let targetBytes = unrestored.isEmpty
            ? selectedList.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
            : unrestored.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
        let sizeStr = ByteCountFormatter.string(fromByteCount: targetBytes, countStyle: .file)
        let actionsDisabled = selectedList.isEmpty || isBatchRestoring || isBatchProxying || isBatchDeleting

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedList.isEmpty ? "Tap photos to select" : "\(selectedList.count) selected (~\(sizeStr))")
                    .font(.subheadline.weight(.semibold))
                if !selectedList.isEmpty {
                    let alreadyCount = selectedList.count - unrestored.count
                    Text(
                        alreadyCount > 0
                        ? "\(unrestored.count) to restore · \(alreadyCount) already restored"
                        : "\(unrestored.count) original(s) to download"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer()
            Button(role: .destructive) {
                requestDeleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(actionsDisabled)

            Button {
                requestRestoreSelected()
            } label: {
                Label("Restore", systemImage: "icloud.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(actionsDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func enterSelectionMode(initialPhoto: ServerPhoto? = nil) {
        guard !isBatchRestoring, !isBatchProxying, !isBatchDeleting, !photos.isEmpty else { return }
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
        deleteConfirmPrompt = DeleteConfirmPrompt(targets: targets, totalBytes: totalBytes)
    }

    private func startBatchDelete(targets: [ServerPhoto]) {
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
                let result = try await client.deleteServerPhotosBatch(hashes: targetHashes)
                let removed = (result.deleted ?? []) + (result.missing ?? [])
                applyDeletedHashes(removed)

                let deletedCount = result.deleted?.count ?? 0
                let missingCount = result.missing?.count ?? 0
                let freedStr = ByteCountFormatter.string(fromByteCount: max(0, result.freedBytes ?? 0), countStyle: .file)
                isBatchDeleting = false
                if deletedCount > 0 && result.success {
                    deleteBannerMessage = "Deleted \(deletedCount) photo(s) from server (freed ~\(freedStr))."
                } else if deletedCount > 0 {
                    deleteBannerMessage = "Deleted \(deletedCount) photo(s) from server; some items failed."
                } else if missingCount > 0 {
                    deleteBannerMessage = "Removed \(missingCount) missing item(s) from gallery."
                } else {
                    deleteBannerMessage = "Delete failed on server."
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
        for key in Array(imageCache.keys) where removedSet.contains(key.lowercased()) {
            imageCache.removeValue(forKey: key)
        }
        for key in Array(compressedDataCache.keys) where removedSet.contains(key.lowercased()) {
            compressedDataCache.removeValue(forKey: key)
        }
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
        }
    }

    @ViewBuilder
    private func yearQuickJumpBar(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(timelineData.years) { yr in
                    let isSelected = selectedYearAnchor == yr.anchorId
                    Button {
                        selectedYearAnchor = yr.anchorId
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo(yr.anchorId, anchor: .top)
                        }
                    } label: {
                        Text(yr.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundColor(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func yearBannerHeader(for section: ServerTimelineSection) -> some View {
        let yearInfo = timelineData.years.first(where: { $0.label == section.yearLabel })
        HStack(alignment: .firstTextBaseline) {
            Text(section.yearLabel)
                .font(.title2.weight(.bold))
            Spacer()
            if let yearInfo {
                Text("\(yearInfo.itemCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func timelineSectionHeader(_ section: ServerTimelineSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
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
                .font(.caption.weight(.semibold))
            } else {
                Text("\(section.photos.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
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
                    .fill(isScrubbingTimeline ? Color.accentColor : Color.primary.opacity(0.28))
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
            photos: photos,
            filterMode: filterMode,
            mediaTypeFilter: mediaTypeFilter,
            grouping: timelineGrouping
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
            refreshLocallyProtectedHashes()
            rebuildTimeline()
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
            refreshLocallyProtectedHashes()
            rebuildTimeline()
            for photo in fetched where !photo.needsProxy {
                failedPreviewHashes.remove(photo.hash)
            }
            errorMessage = nil
            LocalProxySyncManager.shared.startPrefetchIfNeeded(for: fetched, settings: settings)
        } catch APIClientError.httpError(401, _) {
            LocalProxySyncManager.shared.cancel()
            settings.signOut()
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

    static func build(
        photos: [ServerPhoto],
        filterMode: ServerGalleryFilter,
        mediaTypeFilter: ServerMediaTypeFilter,
        grouping: ServerTimelineGrouping
    ) -> ServerTimelineData {
        let filtered = photos.filter { photo in
            if filterMode == .needsProxy && !photo.needsProxy {
                return false
            }
            switch mediaTypeFilter {
            case .all:
                return true
            case .photos:
                return !photo.isVideo
            case .videos:
                return photo.isVideo
            }
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if showPlaceholder {
                    Image(systemName: photo.isVideo ? "video" : "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.24))
                }
            }
            .overlay {
                if isSelected {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2.5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.isVideo && image != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.48), in: Circle())
                        .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if isSelectionMode {
                    Group {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white, Color.accentColor)
                        } else {
                            Image(systemName: "circle")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.45), radius: 2, x: 0, y: 1)
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isRestoredOrProtected {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(4)
                        .background(Color.black.opacity(0.48), in: Circle())
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if photo.needsProxy {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.85), lineWidth: 1)
                        )
                        .padding(6)
                }
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
    let onPhotoDeleted: (String, String) -> Void

    init(
        photo: ServerPhoto,
        settings: AppSettings,
        initialImage: UIImage?,
        initialCompressedData: Data?,
        onPhotoUpdated: @escaping (ServerPhoto) -> Void,
        onPhotoDeleted: @escaping (String, String) -> Void
    ) {
        self._currentPhoto = State(initialValue: photo)
        self.settings = settings
        self.initialImage = initialImage
        self.initialCompressedData = initialCompressedData
        self.onPhotoUpdated = onPhotoUpdated
        self.onPhotoDeleted = onPhotoDeleted
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
    @State private var showDeleteConfirm: Bool = false

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
                    } ?? (currentPhoto.needsProxy ? "No Proxy" : "Proxy")
                    let masterStr = ByteCountFormatter.string(fromByteCount: currentPhoto.size, countStyle: .file)

                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                currentPhoto.parsedCreationDate.map { Self.detailDateFormatter.string(from: $0) }
                                ?? currentPhoto.originalName
                            )
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                            Text("\(smallStr) proxy · \(masterStr) original")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text("SHA-256 verified (\(String(currentPhoto.hash.prefix(10)))…)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if isOriginalProtected {
                            Text("Original Kept")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.16), in: Capsule())
                                .foregroundColor(.blue)
                        }

                        Text(currentPhoto.needsProxy ? "Needs Proxy" : "Proxy Ready")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                (currentPhoto.needsProxy ? Color.orange : Color.green).opacity(0.16),
                                in: Capsule()
                            )
                            .foregroundColor(currentPhoto.needsProxy ? .orange : .green)
                    }

                    if isOriginalProtected {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.blue)
                            Text("Restored original is protected from auto re-compression.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Allow Re-Proxy") {
                                Task { await updateOriginalProtection(false) }
                            }
                            .font(.caption2.weight(.semibold))
                            .disabled(isBusy)
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if needsProxyAction {
                        Button {
                            Task { await createProxyForCurrentItem() }
                        } label: {
                            Label(currentPhoto.isVideo ? "Create Video Proxy" : "Create Proxy", systemImage: "wand.and.stars")
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

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete from Server", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle(currentPhoto.originalName)
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
            .alert("Delete from Server?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task { await deleteCurrentItemFromServer() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let masterStr = ByteCountFormatter.string(fromByteCount: currentPhoto.size, countStyle: .file)
                Text(
                    "Permanently delete \(currentPhoto.originalName) (~\(masterStr)) and its compressed proxies from your PhotoHub server? This cannot be undone."
                )
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
        defer {
            isBusy = false
            busyLabel = ""
        }

        let authorized = await PhotoLibraryService.requestWriteAuthorizationAsync()
        guard authorized else {
            saveMessage = "Photos library permission is required."
            return
        }

        if LocalProxyTracker.shared.liveProxyAssetId(forMasterHash: currentPhoto.hash) != nil {
            saveMessage = "Already saved in iPhone Photos."
            return
        }

        do {
            if currentPhoto.isVideo {
                var videoURL = localVideoProxyURL ?? LocalProxyStore.shared.videoProxyURLIfExists(forHash: currentPhoto.hash)
                var tempDownloadURL: URL?
                defer {
                    if let tempDownloadURL {
                        try? FileManager.default.removeItem(at: tempDownloadURL)
                    }
                }

                if videoURL == nil, !currentPhoto.needsProxy {
                    busyLabel = "Downloading compressed MP4 proxy..."
                    let client = PhotoHubAPIClient(settings: settings)
                    let downloaded = try await client.downloadVideoProxyToTempFile(hash: currentPhoto.hash)
                    if let cached = LocalProxyStore.shared.copyVideoProxy(from: downloaded, forHash: currentPhoto.hash) {
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
                        photo: currentPhoto,
                        videoURL: videoURL
                    )
                    let sizeBytes = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
                    saveMessage = "Saved compressed video proxy (\(sizeStr)) to Photos."
                    return
                }
            }

            var dataToSave = compressedData ?? initialCompressedData
            if dataToSave == nil {
                if let cached = LocalProxyStore.shared.previewData(forHash: currentPhoto.hash) {
                    dataToSave = LocalProxyStore.makeSmallCompressedPreview(from: cached, maxPixelSize: 800, quality: 0.65)?.1 ?? cached
                } else {
                    busyLabel = "Downloading compressed preview..."
                    let client = PhotoHubAPIClient(settings: settings)
                    if let raw = try? await client.downloadPhotoPreviewData(hash: currentPhoto.hash) {
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
                photo: currentPhoto,
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
                currentPhoto = updated
                onPhotoUpdated(updated)
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
            currentPhoto = updated
            onPhotoUpdated(updated)
            saveMessage = protected
                ? "Protected: this original won't be auto re-proxied."
                : "Unlocked: this photo can be compressed into a proxy again."
        } catch {
            saveMessage = "Failed to update protection: \(error.localizedDescription)"
        }
    }

    private func deleteCurrentItemFromServer() async {
        isBusy = true
        busyLabel = "Deleting from server..."
        saveMessage = nil
        defer {
            isBusy = false
            busyLabel = ""
        }

        do {
            let client = PhotoHubAPIClient(settings: settings)
            try await client.deleteServerPhoto(hash: currentPhoto.hash)
            player?.pause()
            player = nil
            let deletedHash = currentPhoto.hash
            let deletedName = currentPhoto.originalName
            onPhotoDeleted(deletedHash, deletedName)
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
