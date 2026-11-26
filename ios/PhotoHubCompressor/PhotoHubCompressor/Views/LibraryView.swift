import Photos
import SwiftUI
import UIKit

struct LibraryView: View {
    @ObservedObject var viewModel: CompressorViewModel
    @ObservedObject private var bgManager: BackgroundBackupManager
    @AppStorage("keepLocalProxyInPhotos") private var keepLocalProxyInPhotos: Bool = true
    @State private var showingProxyDetectorPicker: Bool = false

    init(viewModel: CompressorViewModel) {
        self.viewModel = viewModel
        self._bgManager = ObservedObject(wrappedValue: BackgroundBackupManager.shared)
    }

    private var activeBgCount: Int {
        max(viewModel.backgroundActiveCount, bgManager.activeBackgroundUploadCount)
    }

    private var heroMood: MascotMood {
        if viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted {
            return .alert
        }
        if viewModel.isScanning || viewModel.isProcessing || activeBgCount > 0 {
            return .uploading
        }
        if !bgManager.stagedItems.isEmpty || viewModel.totalSavedBytes > 0 {
            return .celebrate
        }
        return .happy
    }

    var body: some View {
        AdaptiveNavigationStack {
            ZStack {
                PhotoHubPalette.canvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        if viewModel.permissionStatus == .limited {
                            compactBanner(tint: PhotoHubPalette.warmAmber) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(PhotoHubPalette.warmAmber)
                                Text("Limited Access")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(PhotoHubPalette.ink)
                                Spacer()
                                Button("Allow All") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(PhotoHubPalette.orange, in: Capsule())
                                .foregroundColor(.white)
                            }
                        }

                        if !bgManager.stagedItems.isEmpty && !viewModel.isProcessing && !viewModel.isAwaitingDeleteConfirmation {
                            overnightReadyBanner
                        }

                        if activeBgCount > 0 {
                            compactBanner(tint: PhotoHubPalette.orange) {
                                AnimatedPulseDot(color: PhotoHubPalette.orange)
                                let pct = Int((bgManager.liveBackgroundProgress * 100).rounded())
                                Text(pct > 0 ? "Uploading \(activeBgCount) · \(pct)%" : "Uploading \(activeBgCount)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundColor(PhotoHubPalette.ink)
                                Spacer()
                                if bgManager.liveBackgroundProgress > 0 {
                                    ProgressView(value: bgManager.liveBackgroundProgress)
                                        .tint(PhotoHubPalette.orange)
                                        .frame(width: 72)
                                }
                            }
                        }

                        if viewModel.recentlyDeletedNoticeCount > 0 {
                            recentlyDeletedWarningBanner
                        }

                        if let banner = viewModel.statusBanner, !banner.isEmpty {
                            compactBanner(tint: PhotoHubPalette.orange) {
                                Image(systemName: "sparkles")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(PhotoHubPalette.orange)
                                Text(banner)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(PhotoHubPalette.ink)
                                    .lineLimit(2)
                                Spacer()
                            }
                        }

                        if viewModel.isProcessing {
                            activeProcessingCard
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isProcessing)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bgManager.stagedItems.count)

                    if viewModel.candidates.isEmpty {
                        emptyHeroView
                    } else {
                        summaryHeader
                            .padding(.top, 8)
                        List {
                            ForEach(viewModel.candidates) { item in
                                PhotoCandidateRow(
                                    item: item,
                                    onToggleSelect: {
                                        viewModel.toggleSelection(for: item.id)
                                    }
                                )
                                .listRowBackground(PhotoHubPalette.card)
                                .onAppear {
                                    viewModel.loadThumbnailIfNeeded(for: item.id)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .overlay {
                if viewModel.isInspectingGalleryPicks {
                    ZStack {
                        Color.black.opacity(0.40).ignoresSafeArea()
                        VStack(spacing: 12) {
                            SunnyMascotView(mood: .uploading, size: 74)
                            Text("Checking…")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(PhotoHubPalette.ink)
                        }
                        .padding(24)
                        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: PhotoHubPalette.orange.opacity(0.22), radius: 18, y: 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        viewModel.scanLibrary()
                    } label: {
                        if viewModel.isScanning {
                            ProgressView()
                                .tint(PhotoHubPalette.orange)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isScanning || viewModel.isProcessing)
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showingProxyDetectorPicker = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(viewModel.isInspectingGalleryPicks || viewModel.isProcessing)

                    if !viewModel.candidates.isEmpty {
                        Menu {
                            Picker("Sort", selection: Binding(
                                get: { viewModel.sortMode },
                                set: { viewModel.setSortMode($0) }
                            )) {
                                ForEach(CandidateSortMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }

                            if !viewModel.pendingVideoCandidates.isEmpty {
                                Button {
                                    viewModel.selectTopVideos()
                                } label: {
                                    Label("Top Videos", systemImage: "video.fill")
                                }
                            }

                            Button("Select All") { viewModel.selectAllEligible(true) }
                            Button("Clear") { viewModel.selectAllEligible(false) }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .disabled(viewModel.isProcessing)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.selectedCount > 0 {
                    actionBar
                }
            }
            .sheet(isPresented: $showingProxyDetectorPicker) {
                MultiPhotoPickerSheet(
                    selectionLimit: 25,
                    onPickBatch: { picked in
                        showingProxyDetectorPicker = false
                        viewModel.inspectPickedGalleryItems(picked)
                    },
                    onCancel: {
                        showingProxyDetectorPicker = false
                    }
                )
            }
            .sheet(isPresented: Binding(
                get: { viewModel.galleryInspectionItems != nil },
                set: { if !$0 { viewModel.dismissGalleryInspection() } }
            )) {
                GalleryProxyInspectionSheet(
                    items: viewModel.galleryInspectionItems ?? [],
                    busyItemId: viewModel.inspectionBusyId,
                    actionMessage: viewModel.inspectorActionMessage,
                    shareSheetItem: $viewModel.inspectorShareItem,
                    onRestore: { item in
                        viewModel.restoreOriginalFromDetectedProxy(
                            itemId: item.id,
                            rawMasterHash: item.masterHash,
                            originalFilename: item.originalName,
                            isVideo: item.isVideo
                        )
                    },
                    onShareOriginal: { item in
                        viewModel.shareOriginalFromDetectedProxy(
                            itemId: item.id,
                            rawMasterHash: item.masterHash,
                            originalFilename: item.originalName,
                            isVideo: item.isVideo
                        )
                    },
                    onClose: {
                        viewModel.dismissGalleryInspection()
                    }
                )
            }
            .alert(
                "Delete Original",
                isPresented: Binding(
                    get: { viewModel.deleteErrorAlertMessage != nil },
                    set: { if !$0 { viewModel.deleteErrorAlertMessage = nil } }
                )
            ) {
                if !viewModel.pendingDeleteAssets.isEmpty {
                    Button("Retry") {
                        viewModel.deleteErrorAlertMessage = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            viewModel.retryPendingDeleteAlert()
                        }
                    }
                }
                Button("Settings") {
                    viewModel.dismissPendingDeleteAfterError()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("OK", role: .cancel) {
                    viewModel.dismissPendingDeleteAfterError()
                }
            } message: {
                Text(viewModel.deleteErrorAlertMessage ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                viewModel.onAppBecameActive()
                viewModel.syncBackgroundStateToCandidates()
            }
            .onReceive(NotificationCenter.default.publisher(for: .photoHubUploadCoordinatorDidChange)) { _ in
                viewModel.syncBackgroundStateToCandidates()
            }
            .onAppear {
                bgManager.pruneMissingAssetsFromStaged()
                if viewModel.candidates.isEmpty {
                    viewModel.scanAndAutoCompressIfEnabled()
                }
            }
        }
    }

    @ViewBuilder
    private func compactBanner<Content: View>(
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
    }

    private var emptyHeroView: some View {
        VStack(spacing: 18) {
            Spacer()

            SunnyMascotView(mood: heroMood, size: 130)

            Text(
                (viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted)
                ? "Photos Access"
                : (viewModel.isScanning ? "Scanning…" : (activeBgCount > 0 ? "Syncing…" : "Ready"))
            )
            .font(.system(size: 26, weight: .heavy, design: .rounded))
            .foregroundColor(PhotoHubPalette.ink)

            if viewModel.totalSavedBytes > 0 {
                WarmStatPill(
                    icon: "sparkles",
                    text: "Saved \(ByteCountFormatter.string(fromByteCount: viewModel.totalSavedBytes, countStyle: .file))",
                    tint: PhotoHubPalette.mint
                )
            }

            if viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted {
                Button("Allow Photos") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(PhotoHubPrimaryButtonStyle())
            } else {
                VStack(spacing: 10) {
                    Button {
                        viewModel.scanAndAutoCompressIfEnabled(forceNow: true)
                    } label: {
                        Label("Auto Backup", systemImage: "bolt.fill")
                            .frame(minWidth: 210)
                    }
                    .buttonStyle(PhotoHubPrimaryButtonStyle())
                    .disabled(viewModel.isScanning || viewModel.isProcessing)

                    HStack(spacing: 10) {
                        Button {
                            viewModel.scanLibrary()
                        } label: {
                            Label("Pick", systemImage: "checklist")
                        }
                        .buttonStyle(PhotoHubSoftButtonStyle())
                        .disabled(viewModel.isScanning || viewModel.isProcessing)

                        Button {
                            showingProxyDetectorPicker = true
                        } label: {
                            Label("Check Proxy", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(PhotoHubSoftButtonStyle())
                        .disabled(viewModel.isInspectingGalleryPicks || viewModel.isProcessing)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeProcessingCard: some View {
        let pct = Int((viewModel.overallProgressFraction * 100).rounded())
        return HStack(spacing: 12) {
            SunnyMascotView(mood: .uploading, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(pct)%")
                        .font(.subheadline.weight(.heavy).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.orange)
                    Text("· \(viewModel.completedCount)/\(viewModel.totalToProcess)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.muted)
                    Spacer()
                }
                ProgressView(value: viewModel.overallProgressFraction, total: 1.0)
                    .tint(PhotoHubPalette.orange)
            }
        }
        .padding(12)
        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
        )
    }

    private var overnightReadyBanner: some View {
        let sizeStr = ByteCountFormatter.string(fromByteCount: bgManager.stagedSavedBytes, countStyle: .file)
        return compactBanner(tint: PhotoHubPalette.mint) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(PhotoHubPalette.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(bgManager.stagedItems.count) Ready")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(PhotoHubPalette.ink)
                Text("Free ~\(sizeStr)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(PhotoHubPalette.muted)
            }
            Spacer()
            Button("Delete") {
                viewModel.triggerStagedOvernightCleanupPrompt()
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(PhotoHubPalette.orangeGradient, in: Capsule())
            .foregroundColor(.white)

            Button {
                bgManager.clearAllStagedItems()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(PhotoHubPalette.muted)
            }
            .buttonStyle(.plain)
        }
    }

    private var recentlyDeletedWarningBanner: some View {
        let sizeStr = ByteCountFormatter.string(fromByteCount: viewModel.recentlyDeletedNoticeBytes, countStyle: .file)
        return compactBanner(tint: PhotoHubPalette.warmAmber) {
            Image(systemName: "trash.fill")
                .foregroundColor(PhotoHubPalette.orange)
            Text("Empty Trash · ~\(sizeStr)")
                .font(.caption.weight(.semibold))
                .foregroundColor(PhotoHubPalette.ink)
            Spacer()
            Button("Photos") {
                if let url = URL(string: "photos-redirect://") {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption.weight(.bold))
            .foregroundColor(PhotoHubPalette.deepOrange)

            Button {
                viewModel.dismissRecentlyDeletedNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(PhotoHubPalette.muted)
            }
            .buttonStyle(.plain)
        }
    }

    private var summaryHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                let estStr = ByteCountFormatter.string(fromByteCount: viewModel.totalEligibleEstimatedBytes, countStyle: .file)
                WarmStatPill(icon: "photo.stack", text: "\(viewModel.candidates.count) · ~\(estStr)", tint: PhotoHubPalette.orange)

                if viewModel.totalSavedBytes > 0 {
                    WarmStatPill(
                        icon: "sparkles",
                        text: ByteCountFormatter.string(fromByteCount: viewModel.totalSavedBytes, countStyle: .file),
                        tint: PhotoHubPalette.mint
                    )
                }

                Spacer()

                if !viewModel.pendingVideoCandidates.isEmpty && !viewModel.isProcessing {
                    let vidStr = ByteCountFormatter.string(fromByteCount: viewModel.pendingVideoEstimatedBytes, countStyle: .file)
                    Button {
                        viewModel.selectTopVideos()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "video.fill")
                                .font(.caption2)
                            Text(vidStr)
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(PhotoHubPalette.softPeach, in: Capsule())
                        .foregroundColor(PhotoHubPalette.deepOrange)
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.isCheckingServerProxies {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(PhotoHubPalette.orange)
                    Text("Checking proxies…")
                        .font(.caption2)
                        .foregroundColor(PhotoHubPalette.muted)
                    Spacer()
                }
            }

            Picker("Mode", selection: $keepLocalProxyInPhotos) {
                Text("Keep Proxy").tag(true)
                Text("Delete Only").tag(false)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PhotoHubPalette.card)
    }

    private var actionBar: some View {
        Button {
            viewModel.startProcessingSelectedPhotos()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: keepLocalProxyInPhotos ? "sparkles" : "icloud.and.arrow.up.fill")
                Text(
                    keepLocalProxyInPhotos
                    ? "Compress \(viewModel.selectedCount)"
                    : "Backup \(viewModel.selectedCount)"
                )
                .font(.headline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PhotoHubPrimaryButtonStyle())
        .disabled(viewModel.isProcessing)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct PhotoCandidateRow: View {
    let item: PhotoCandidate
    let onToggleSelect: () -> Void

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(item.isSelected ? PhotoHubPalette.orange : PhotoHubPalette.muted.opacity(0.55))
                .font(.title3)
                .scaleEffect(item.isSelected ? 1.08 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.65), value: item.isSelected)
                .opacity(item.state.isFinished ? 0.3 : 1.0)

            ZStack(alignment: .bottomTrailing) {
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(PhotoHubPalette.softPeach)
                        .frame(width: 56, height: 56)
                }

                if item.isVideo {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(PhotoHubPalette.orange)
                        .clipShape(Circle())
                        .padding(3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.filename)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(PhotoHubPalette.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(item.estimatedSizeLabel)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundColor(item.isVideo ? PhotoHubPalette.orange : PhotoHubPalette.muted)
                        .lineLimit(1)
                }

                Text(subtitleLineText)
                    .font(.caption2)
                    .foregroundColor(PhotoHubPalette.muted)
                    .lineLimit(1)

                if item.state != .pending || item.isBackedUpOnServer {
                    HStack(spacing: 5) {
                        if item.state.isIntegrityVerified || item.isBackedUpOnServer {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundColor(PhotoHubPalette.mint)
                        }
                        Text(statusLineText)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(item.state == .pending && item.isBackedUpOnServer ? PhotoHubPalette.mint : badgeColor(for: item.state))
                            .lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !item.state.isFinished {
                onToggleSelect()
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitleLineText: String {
        if let date = item.creationDate {
            return "\(item.resolutionLabel) · \(Self.dateFormatter.string(from: date))"
        }
        return item.resolutionLabel
    }

    private var statusLineText: String {
        if item.state == .pending && item.isBackedUpOnServer {
            return "Backed Up"
        }
        return item.state.label
    }

    private func badgeColor(for state: PhotoCompressionState) -> Color {
        switch state {
        case .completed: return PhotoHubPalette.mint
        case .readyToDelete: return PhotoHubPalette.warmAmber
        case .alreadyProxy: return PhotoHubPalette.orange
        case .skipped: return PhotoHubPalette.muted
        case .failed: return PhotoHubPalette.rose
        case .uploading, .uploadingInBackground, .hashing, .verifyingChecksum, .creatingProxy, .replacingInPhotos:
            return PhotoHubPalette.orange
        case .pending: return PhotoHubPalette.muted
        }
    }
}

private struct GalleryProxyInspectionSheet: View {
    let items: [GalleryProxyInspectionItem]
    let busyItemId: String?
    let actionMessage: String?
    @Binding var shareSheetItem: ShareSheetItem?
    let onRestore: (GalleryProxyInspectionItem) -> Void
    let onShareOriginal: (GalleryProxyInspectionItem) -> Void
    let onClose: () -> Void

    private var proxyCount: Int {
        items.filter { $0.kind == .proxy }.count
    }

    var body: some View {
        AdaptiveNavigationStack {
            List {
                if let actionMessage, !actionMessage.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundColor(PhotoHubPalette.orange)
                            Text(actionMessage)
                                .font(.caption)
                        }
                    }
                }

                Section {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                PHAssetThumbView(assetId: item.assetId, isVideo: item.isVideo)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.originalName ?? item.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)

                                    verdictBadge(for: item.kind)
                                }
                            }

                            let localStr = ByteCountFormatter.string(fromByteCount: item.localSizeBytes, countStyle: .file)
                            let origStr = item.originalSizeBytes.flatMap { sz in
                                sz > 0 ? " → \(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))" : nil
                            } ?? ""

                            Text("\(localStr)\(origStr)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(PhotoHubPalette.muted)

                            if item.kind == .proxy, item.masterHash != nil {
                                HStack(spacing: 10) {
                                    Button {
                                        onShareOriginal(item)
                                    } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                            .font(.caption.weight(.bold))
                                    }
                                    .buttonStyle(PhotoHubSoftButtonStyle())
                                    .disabled(busyItemId != nil)

                                    Button {
                                        onRestore(item)
                                    } label: {
                                        if busyItemId == item.id {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Label(
                                                item.isProtectedOriginal ? "Restored" : "Restore",
                                                systemImage: "icloud.and.arrow.down"
                                            )
                                            .font(.caption.weight(.bold))
                                        }
                                    }
                                    .buttonStyle(PhotoHubPrimaryButtonStyle())
                                    .disabled(busyItemId != nil)
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text(proxyCount > 0 ? "\(proxyCount) Proxy · \(items.count) Checked" : "\(items.count) Original")
                }
            }
            .navigationTitle("Proxy Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onClose() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .sheet(item: $shareSheetItem) { item in
            ShareSheet(activityItems: item.fileURLs) {
                scheduleTempShareCleanup(item.fileURLs)
                shareSheetItem = nil
            }
        }
    }

    @ViewBuilder
    private func verdictBadge(for kind: GalleryMediaKind) -> some View {
        let (title, color): (String, Color) = {
            switch kind {
            case .proxy: return ("PROXY", PhotoHubPalette.orange)
            case .originalBackedUp: return ("ORIGINAL · SYNCED", PhotoHubPalette.mint)
            case .originalUnbacked: return ("ORIGINAL", PhotoHubPalette.muted)
            case .unknown: return ("UNKNOWN", PhotoHubPalette.muted)
            }
        }()
        Text(title)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundColor(color)
    }
}

private struct PHAssetThumbView: View {
    let assetId: String?
    let isVideo: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PhotoHubPalette.softPeach)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: isVideo ? "video.fill" : "photo.fill")
                    .foregroundColor(PhotoHubPalette.orange.opacity(0.7))
            }
        }
        .frame(width: 48, height: 48)
        .task(id: assetId ?? "") {
            guard image == nil, let assetId else { return }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
                return
            }
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 120, height: 120),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                if let img {
                    DispatchQueue.main.async {
                        self.image = img
                    }
                }
            }
        }
    }
}
