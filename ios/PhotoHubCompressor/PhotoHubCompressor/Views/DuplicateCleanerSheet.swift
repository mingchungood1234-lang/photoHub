import Photos
import SwiftUI
import UIKit

/// Interactive sheet that scans the local iPhone Photos library for duplicate photos/videos
/// (duplicate PhotoHub proxies, exact byte-for-byte duplicates, and visually identical copies)
/// and lets the user auto-remove all duplicates with one tap while always keeping the best copy.
struct DuplicateCleanerSheet: View {
    let onDuplicatesRemoved: (_ removedCount: Int, _ freedBytes: Int64) -> Void
    let onClose: () -> Void

    @State private var isScanning: Bool = true
    @State private var isDeleting: Bool = false
    @State private var progressCurrent: Int = 0
    @State private var progressTotal: Int = 1
    @State private var progressLabel: String = "Preparing duplicate scan…"
    @State private var scanResult: LocalDuplicateScanResult? = nil
    @State private var selectedDeleteIds: Set<String> = []
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var statusMessage: String? = nil
    @State private var errorMessage: String? = nil
    @State private var completedRemovedCount: Int = 0
    @State private var completedFreedBytes: Int64 = 0
    @State private var scanTask: Task<Void, Never>? = nil

    private let photoService = PhotoLibraryService()
    private let imageManager = PHCachingImageManager()

    private var selectedDeleteItems: [LocalDuplicateAssetItem] {
        guard let result = scanResult else { return [] }
        return result.groups
            .flatMap { $0.items }
            .filter { !$0.isKeep && selectedDeleteIds.contains($0.id) }
    }

    private var selectedFreedBytes: Int64 {
        selectedDeleteItems.reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    var body: some View {
        AdaptiveNavigationStack {
            ZStack {
                PhotoHubPalette.canvas.ignoresSafeArea()

                if isScanning {
                    scanningBody
                } else if let result = scanResult {
                    if result.groups.isEmpty {
                        cleanCompleteBody(scannedCount: result.scannedCount)
                    } else {
                        resultsBody(result: result)
                    }
                }
            }
            .navigationTitle("Duplicate Cleaner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        scanTask?.cancel()
                        onClose()
                    }
                    .disabled(isDeleting)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isScanning {
                        Button {
                            startScan()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isDeleting)
                    }
                }
            }
            .onAppear {
                if scanResult == nil {
                    startScan()
                }
            }
            .onDisappear {
                scanTask?.cancel()
            }
        }
    }

    private var scanningBody: some View {
        VStack(spacing: 20) {
            Spacer()
            SunnyMascotView(mood: .uploading, size: 118)
            Text("Scanning for Duplicates…")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(PhotoHubPalette.ink)
            Text(progressLabel)
                .font(.subheadline.weight(.medium))
                .foregroundColor(PhotoHubPalette.muted)
                .multilineTextAlignment(.center)
            ProgressView(
                value: Double(min(progressCurrent, max(1, progressTotal))),
                total: Double(max(1, progressTotal))
            )
            .tint(PhotoHubPalette.orange)
            .frame(maxWidth: 240)
            Text("Checks duplicate proxies, exact SHA-256 files & identical copies locally on your iPhone.")
                .font(.caption)
                .foregroundColor(PhotoHubPalette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding(24)
    }

    private func cleanCompleteBody(scannedCount: Int) -> some View {
        VStack(spacing: 18) {
            Spacer()
            SunnyMascotView(mood: .celebrate, size: 126)

            if completedRemovedCount > 0 {
                let freedStr = ByteCountFormatter.string(fromByteCount: completedFreedBytes, countStyle: .file)
                Text("Duplicates Removed!")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(PhotoHubPalette.ink)
                WarmStatPill(
                    icon: "sparkles",
                    text: "Moved \(completedRemovedCount) duplicate(s) · ~\(freedStr)",
                    tint: PhotoHubPalette.mint
                )
                Text("Moved safely to Apple Photos → Recently Deleted (recoverable for 30 days). The best copy of every photo was kept.")
                    .font(.subheadline)
                    .foregroundColor(PhotoHubPalette.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            } else {
                Text("No Duplicates Found")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(PhotoHubPalette.ink)
                Text("Scanned \(scannedCount) item(s) on your iPhone. Your photo library is spotless!")
                    .font(.subheadline)
                    .foregroundColor(PhotoHubPalette.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Button("Done") {
                onClose()
            }
            .buttonStyle(PhotoHubPrimaryButtonStyle())
            .padding(.top, 8)
            Spacer()
        }
        .padding(24)
    }

    private func resultsBody(result: LocalDuplicateScanResult) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: selectedFreedBytes, countStyle: .file)
                    WarmStatPill(
                        icon: "doc.on.doc.fill",
                        text: "\(result.groups.count) group(s) · \(selectedDeleteItems.count) duplicate(s)",
                        tint: PhotoHubPalette.orange
                    )
                    WarmStatPill(
                        icon: "sparkles",
                        text: "Free ~\(sizeStr)",
                        tint: PhotoHubPalette.mint
                    )
                    Spacer()
                }

                if let msg = statusMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(PhotoHubPalette.mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let err = errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(PhotoHubPalette.rose)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(PhotoHubPalette.card)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(result.groups) { group in
                        duplicateGroupCard(group: group)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                let count = selectedDeleteItems.count
                let sizeStr = ByteCountFormatter.string(fromByteCount: selectedFreedBytes, countStyle: .file)
                Button {
                    triggerAutoRemoveSelected()
                } label: {
                    HStack(spacing: 8) {
                        if isDeleting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "trash.fill")
                        }
                        Text(
                            isDeleting
                            ? "Removing Duplicates…"
                            : "Auto Remove \(count) Duplicate\(count == 1 ? "" : "s") (~\(sizeStr))"
                        )
                        .font(.headline.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PhotoHubPrimaryButtonStyle())
                .disabled(count == 0 || isDeleting)

                Text("Always keeps the best original · Removed copies go to Recently Deleted for 30 days")
                    .font(.caption2)
                    .foregroundColor(PhotoHubPalette.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
    }

    private func duplicateGroupCard(group: LocalDuplicateGroup) -> some View {
        let groupSizeStr = ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.reason.rawValue)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(PhotoHubPalette.softPeach, in: Capsule())
                    .foregroundColor(PhotoHubPalette.deepOrange)

                Text("\(group.items.count) copies")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(PhotoHubPalette.muted)

                Spacer()

                Text("Save ~\(groupSizeStr)")
                    .font(.caption.weight(.bold))
                    .foregroundColor(PhotoHubPalette.mint)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.items) { item in
                        duplicateThumbCard(item: item)
                            .onAppear {
                                loadThumbnailIfNeeded(for: item)
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

    private func duplicateThumbCard(item: LocalDuplicateAssetItem) -> some View {
        let isMarkedDelete = !item.isKeep && selectedDeleteIds.contains(item.id)
        let borderColor: Color = item.isKeep
            ? PhotoHubPalette.mint
            : (isMarkedDelete ? PhotoHubPalette.rose : PhotoHubPalette.cardBorder)
        let sizeStr = ByteCountFormatter.string(fromByteCount: max(0, item.sizeBytes), countStyle: .file)

        return Button {
            guard !item.isKeep else { return }
            if selectedDeleteIds.contains(item.id) {
                selectedDeleteIds.remove(item.id)
            } else {
                selectedDeleteIds.insert(item.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    if let thumb = thumbnails[item.id] {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(PhotoHubPalette.softPeach)
                            .frame(width: 96, height: 96)
                            .overlay(
                                Image(systemName: item.isVideo ? "video.fill" : "photo")
                                    .foregroundColor(PhotoHubPalette.orange)
                            )
                    }

                    Text(item.isKeep ? "KEEP" : (isMarkedDelete ? "REMOVE" : "SKIP"))
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            item.isKeep
                            ? PhotoHubPalette.mint
                            : (isMarkedDelete ? PhotoHubPalette.rose : Color.black.opacity(0.65)),
                            in: Capsule()
                        )
                        .foregroundColor(.white)
                        .padding(5)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(borderColor, lineWidth: 2.5)
                )

                Text(sizeStr)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(PhotoHubPalette.ink)
                    .lineLimit(1)

                Text(item.isProxy ? "Proxy" : "\(item.pixelWidth)×\(item.pixelHeight)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(PhotoHubPalette.muted)
                    .lineLimit(1)
            }
            .frame(width: 96)
        }
        .buttonStyle(.plain)
    }

    private func loadThumbnailIfNeeded(for item: LocalDuplicateAssetItem) {
        guard thumbnails[item.id] == nil else { return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        let assetId = item.id
        imageManager.requestImage(
            for: item.asset,
            targetSize: CGSize(width: 192, height: 192),
            contentMode: .aspectFill,
            options: opts
        ) { img, _ in
            guard let img else { return }
            DispatchQueue.main.async {
                thumbnails[assetId] = img
            }
        }
    }

    private func startScan() {
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        statusMessage = nil
        progressCurrent = 0
        progressTotal = 1
        progressLabel = "Requesting Photos access…"

        photoService.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                isScanning = false
                scanResult = LocalDuplicateScanResult(scannedCount: 0, groups: [])
                errorMessage = "Photos permission is required to scan for duplicates."
                return
            }

            scanTask = Task.detached(priority: .userInitiated) {
                let result = LocalDuplicateCleaner.scanForDuplicates(tracker: .shared) { current, total, label in
                    Task { @MainActor in
                        progressCurrent = current
                        progressTotal = max(1, total)
                        progressLabel = label
                    }
                }
                let defaultRemoveIds = Set(
                    result.groups.flatMap { $0.removableItems }.map { $0.id }
                )
                await MainActor.run {
                    scanResult = result
                    selectedDeleteIds = defaultRemoveIds
                    isScanning = false
                }
            }
        }
    }

    private func triggerAutoRemoveSelected() {
        let targets = selectedDeleteItems
        guard !targets.isEmpty, !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        statusMessage = nil

        let targetAssets = targets.map { $0.asset }
        let proxyIds = targets.filter { $0.isProxy }.map { $0.id }
        let expectedFreed = targets.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }

        photoService.deleteOriginalAssets(targetAssets) { result in
            Task { @MainActor in
                isDeleting = false
                switch result {
                case .success(.deleted(let deletedIds)):
                    let deletedSet = Set(deletedIds)
                    let deletedProxies = proxyIds.filter { deletedSet.contains($0) }
                    if !deletedProxies.isEmpty {
                        LocalProxyTracker.shared.clearProxyMappings(assetIds: deletedProxies)
                    }
                    completedRemovedCount += deletedSet.count
                    completedFreedBytes += expectedFreed
                    selectedDeleteIds.subtract(deletedSet)

                    if let current = scanResult {
                        let remainingGroups: [LocalDuplicateGroup] = current.groups.compactMap { group in
                            let kept = group.items.filter { !deletedSet.contains($0.id) }
                            guard kept.count >= 2 else { return nil }
                            return LocalDuplicateGroup(id: group.id, reason: group.reason, items: kept)
                        }
                        scanResult = LocalDuplicateScanResult(
                            scannedCount: current.scannedCount,
                            groups: remainingGroups
                        )
                    }
                    onDuplicatesRemoved(deletedSet.count, expectedFreed)

                case .success(.cancelledByUser):
                    statusMessage = "Removal cancelled — no duplicates were deleted."

                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        }
    }
}
