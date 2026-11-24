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

    var body: some View {
        AdaptiveNavigationStack {
            VStack(spacing: 0) {
                if viewModel.permissionStatus == .limited {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Limited Photos Access: Switch to Full Access in iOS Settings to scan and delete all originals.")
                            .font(.caption)
                        Spacer()
                        Button("Full Access") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                }

                if !bgManager.stagedItems.isEmpty && !viewModel.isProcessing && !viewModel.isAwaitingDeleteConfirmation {
                    overnightReadyBanner
                }

                if viewModel.backgroundActiveCount > 0 {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Background upload running for \(viewModel.backgroundActiveCount) item\(viewModel.backgroundActiveCount == 1 ? "" : "s") — automatically skipped from manual upload to prevent duplicates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.08))
                }

                if viewModel.recentlyDeletedNoticeCount > 0 {
                    recentlyDeletedWarningBanner
                }

                if let banner = viewModel.statusBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text(banner)
                            .font(.footnote)
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.1))
                }

                if viewModel.isProcessing {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: viewModel.overallProgressFraction, total: 1.0)
                        let pct = Int((viewModel.overallProgressFraction * 100).rounded())
                        Text("Uploading & Compressing \(pct)% (\(viewModel.completedCount)/\(viewModel.totalToProcess))…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                }

                if viewModel.candidates.isEmpty {
                    CompatibleEmptyStateView(
                        title: "Ready to Back Up & Free Space",
                        systemImage: "photo.on.rectangle.angled",
                        description: (viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted)
                            ? "Photos permission is required. Open iOS Settings to allow access."
                            : "New photos & videos upload silently in the background, and photoHub notifies you when originals are ready to delete — or tap below to scan and free space now."
                    ) {
                        if viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted {
                            Button("Open iOS Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            VStack(spacing: 10) {
                                Button("Auto-Upload New Photos & Videos") {
                                    viewModel.scanAndAutoCompressIfEnabled(forceNow: true)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isScanning || viewModel.isProcessing)

                                Button("Scan & Choose Manually") {
                                    viewModel.scanLibrary()
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isScanning || viewModel.isProcessing)

                                Button {
                                    showingProxyDetectorPicker = true
                                } label: {
                                    Label("Detect Proxy in Photos", systemImage: "magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isInspectingGalleryPicks || viewModel.isProcessing)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    summaryHeader
                    List {
                        ForEach(viewModel.candidates) { item in
                            PhotoCandidateRow(
                                item: item,
                                onToggleSelect: {
                                    viewModel.toggleSelection(for: item.id)
                                }
                            )
                            .onAppear {
                                viewModel.loadThumbnailIfNeeded(for: item.id)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .overlay {
                if viewModel.isInspectingGalleryPicks {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Detecting Proxy vs Original status…")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Compress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        viewModel.scanLibrary()
                    } label: {
                        if viewModel.isScanning {
                            ProgressView()
                        } else {
                            Label("Scan", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isScanning || viewModel.isProcessing)
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showingProxyDetectorPicker = true
                    } label: {
                        Label("Detect Proxy", systemImage: "magnifyingglass")
                    }
                    .disabled(viewModel.isInspectingGalleryPicks || viewModel.isProcessing)

                    if !viewModel.candidates.isEmpty {
                        Menu {
                            Picker("Sort Order", selection: Binding(
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
                                    Label("Select Largest Videos", systemImage: "video.fill")
                                }
                            }

                            Button("Select All") { viewModel.selectAllEligible(true) }
                            Button("Deselect All") { viewModel.selectAllEligible(false) }
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
                "Delete Original Photo",
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
                Button("Open Settings") {
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

    private var overnightReadyBanner: some View {
        let sizeStr = ByteCountFormatter.string(fromByteCount: bgManager.stagedSavedBytes, countStyle: .file)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(bgManager.stagedItems.count) Original\(bgManager.stagedItems.count == 1 ? "" : "s") Backed Up & Ready to Delete")
                    .font(.subheadline.weight(.semibold))
                Text("Safely uploaded & SHA-256 verified on your server. Delete the original file\(bgManager.stagedItems.count == 1 ? "" : "s") from iPhone to free ~\(sizeStr).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete Originals") {
                viewModel.triggerStagedOvernightCleanupPrompt()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.small)

            Button {
                bgManager.clearAllStagedItems()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.indigo.opacity(0.1))
    }

    private var recentlyDeletedWarningBanner: some View {
        let sizeStr = ByteCountFormatter.string(fromByteCount: viewModel.recentlyDeletedNoticeBytes, countStyle: .file)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("One More Step to Free ~\(sizeStr) Right Now")
                    .font(.caption.weight(.semibold))
                Text("iPhone Photos moved the \(viewModel.recentlyDeletedNoticeCount) deleted original photo(s) to Recently Deleted for 30 days. Open Photos -> Utilities -> Recently Deleted -> Delete All to reclaim that space immediately.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Open Photos") {
                        if let url = URL(string: "photos-redirect://") {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption.weight(.semibold))

                    Button("Dismiss") {
                        viewModel.dismissRecentlyDeletedNotice()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    private var summaryHeader: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.candidates.count) Items · Selected \(viewModel.selectedCount)")
                        .font(.subheadline.weight(.semibold))
                    let estStr = ByteCountFormatter.string(fromByteCount: viewModel.totalEligibleEstimatedBytes, countStyle: .file)
                    Text("Est. space: ~\(estStr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if viewModel.totalSavedBytes > 0 {
                    Text("Saved \(ByteCountFormatter.string(fromByteCount: viewModel.totalSavedBytes, countStyle: .file))")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }

                if !viewModel.pendingVideoCandidates.isEmpty && !viewModel.isProcessing {
                    let vidStr = ByteCountFormatter.string(fromByteCount: viewModel.pendingVideoEstimatedBytes, countStyle: .file)
                    Button {
                        viewModel.selectTopVideos()
                    } label: {
                        Label("Videos (~\(vidStr))", systemImage: "video.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if viewModel.isCheckingServerProxies {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Filtering out already-compressed proxies…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Picker("After Backup Action", selection: $keepLocalProxyInPhotos) {
                Text("Replace Original w/ Proxy").tag(true)
                Text("Delete Original Only").tag(false)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
                Text(
                    keepLocalProxyInPhotos
                    ? "SHA-256 verified before delete · Keeps a lightweight proxy in Apple Photos"
                    : "SHA-256 verified before delete · Removes local copy (stays on Server)"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var actionBar: some View {
        Button {
            viewModel.startProcessingSelectedPhotos()
        } label: {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                Text(
                    keepLocalProxyInPhotos
                    ? "Upload, Compress & Delete \(viewModel.selectedCount) Original\(viewModel.selectedCount == 1 ? "" : "s")"
                    : "Back Up & Delete \(viewModel.selectedCount) Original\(viewModel.selectedCount == 1 ? "" : "s")"
                )
                .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.isProcessing)
        .padding()
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
                .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                .font(.title3)
                .opacity(item.state.isFinished ? 0.3 : 1.0)

            ZStack(alignment: .bottomTrailing) {
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 56, height: 56)
                }

                if item.isVideo {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.65))
                        .clipShape(Circle())
                        .padding(3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(item.estimatedSizeLabel)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(item.isVideo ? .orange : .secondary)
                        .lineLimit(1)
                }

                Text(subtitleLineText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if item.state != .pending || item.isBackedUpOnServer {
                    HStack(spacing: 5) {
                        if item.state.isIntegrityVerified || item.isBackedUpOnServer {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        Text(statusLineText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.state == .pending && item.isBackedUpOnServer ? .green : badgeColor(for: item.state))
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
            return "Backed up on Server"
        }
        return item.state.label
    }

    private func badgeColor(for state: PhotoCompressionState) -> Color {
        switch state {
        case .completed: return .green
        case .readyToDelete: return .orange
        case .alreadyProxy: return .blue
        case .skipped: return .secondary
        case .failed: return .red
        case .uploading, .uploadingInBackground, .hashing, .verifyingChecksum, .creatingProxy, .replacingInPhotos: return .blue
        case .pending: return .secondary
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
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
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
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)

                                    verdictBadge(for: item.kind)
                                }
                            }

                            let localStr = ByteCountFormatter.string(fromByteCount: item.localSizeBytes, countStyle: .file)
                            let origStr = item.originalSizeBytes.flatMap { sz in
                                sz > 0 ? " · Server Original: \(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))" : nil
                            } ?? ""
                            let signalText = item.signals.isEmpty
                                ? "No proxy tag or server proxy match found"
                                : "Detected via: \(item.signals.joined(separator: ", "))"

                            Text("Local size: \(localStr)\(origStr)\n\(signalText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if item.kind == .proxy, item.masterHash != nil {
                                HStack(spacing: 10) {
                                    Button {
                                        onShareOriginal(item)
                                    } label: {
                                        Label("Share Original", systemImage: "square.and.arrow.up")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(busyItemId != nil)

                                    Button {
                                        onRestore(item)
                                    } label: {
                                        if busyItemId == item.id {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label(
                                                item.isProtectedOriginal ? "Restored" : "Restore",
                                                systemImage: "icloud.and.arrow.down"
                                            )
                                            .font(.caption.weight(.semibold))
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(busyItemId != nil)
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text(
                        proxyCount > 0
                        ? "Detected \(proxyCount) compressed proxy of \(items.count) item(s)"
                        : "All \(items.count) checked item(s) look like originals"
                    )
                }
            }
            .navigationTitle("Gallery Proxy Check")
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
            case .proxy: return ("COMPRESSED PROXY", .orange)
            case .originalBackedUp: return ("ORIGINAL (BACKED UP)", .green)
            case .originalUnbacked: return ("ORIGINAL (NOT BACKED UP)", .secondary)
            case .unknown: return ("ORIGINAL / UNKNOWN (OFFLINE)", .secondary)
            }
        }()
        Text(title)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct PHAssetThumbView: View {
    let assetId: String?
    let isVideo: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.16))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: isVideo ? "video" : "photo")
                    .foregroundStyle(.secondary)
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
