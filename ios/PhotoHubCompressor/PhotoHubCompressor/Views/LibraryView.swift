import SwiftUI
import UIKit

struct LibraryView: View {
    @ObservedObject var viewModel: CompressorViewModel
    @ObservedObject private var bgManager: BackgroundBackupManager
    @AppStorage("keepLocalProxyInPhotos") private var keepLocalProxyInPhotos: Bool = true

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
                        ProgressView(
                            value: Double(viewModel.completedCount),
                            total: Double(max(1, viewModel.totalToProcess))
                        )
                        Text("Processing \(viewModel.completedCount) of \(viewModel.totalToProcess) item(s)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                }

                if viewModel.candidates.isEmpty {
                    CompatibleEmptyStateView(
                        title: "No Photos Scanned",
                        systemImage: "photo.on.rectangle.angled",
                        description: (viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted)
                            ? "Photos permission is required. Open iOS Settings to allow access."
                            : "Tap Scan Library to prioritize your largest videos & photos, verify SHA-256 backups on your server, and reclaim space safely."
                    ) {
                        if viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted {
                            Button("Open iOS Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Scan Library") {
                                viewModel.scanLibrary()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isScanning)
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

                ToolbarItem(placement: .navigationBarTrailing) {
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
            }
            .onAppear {
                bgManager.pruneMissingAssetsFromStaged()
                if viewModel.candidates.isEmpty && viewModel.settings.autoCompressOnOpen {
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
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("SHA-256 verified before delete · Originals stay restorable")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.totalSavedBytes > 0 {
                    Text("Saved \(ByteCountFormatter.string(fromByteCount: viewModel.totalSavedBytes, countStyle: .file))")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.candidates.count) Items · Selected \(viewModel.selectedCount)")
                        .font(.subheadline.weight(.semibold))
                    let estStr = ByteCountFormatter.string(fromByteCount: viewModel.totalEligibleEstimatedBytes, countStyle: .file)
                    Text("Estimated iPhone space: ~\(estStr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

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

            Picker("After Backup Action", selection: $keepLocalProxyInPhotos) {
                Text("Replace Original w/ Proxy").tag(true)
                Text("Delete Original Only").tag(false)
            }
            .pickerStyle(.segmented)

            Text(
                keepLocalProxyInPhotos
                ? "After upload & SHA-256 verification: keeps a lightweight proxy in Apple Photos and prompts you to delete the large original."
                : "After upload & SHA-256 verification: prompts you to delete the original from Apple Photos completely (stays backed up on Server)."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
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
                }

                HStack(spacing: 8) {
                    Text(item.resolutionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let date = item.creationDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    if item.state.isIntegrityVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Text(item.state.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeColor(for: item.state))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleSelect()
        }
        .padding(.vertical, 4)
    }

    private func badgeColor(for state: PhotoCompressionState) -> Color {
        switch state {
        case .completed: return .green
        case .readyToDelete: return .orange
        case .alreadyProxy, .skipped: return .secondary
        case .failed: return .red
        case .uploading, .hashing, .verifyingChecksum, .creatingProxy, .replacingInPhotos: return .blue
        case .pending: return .secondary
        }
    }
}
