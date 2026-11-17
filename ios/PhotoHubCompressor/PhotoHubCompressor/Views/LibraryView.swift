import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: CompressorViewModel
    @AppStorage("keepLocalProxyInPhotos") private var keepLocalProxyInPhotos: Bool = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.permissionStatus == .limited {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Limited Photos Access: iOS blocks deleting originals in Limited mode.")
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
                        Text("Processing \(viewModel.completedCount) of \(viewModel.totalToProcess) photos…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                }

                if viewModel.candidates.isEmpty {
                    ContentUnavailableView {
                        Label("No Photos Scanned", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        if viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted {
                            Text("Photos permission is required. Open iOS Settings to allow access.")
                        } else {
                            Text("Tap Scan Library to find full-resolution photos that can be backed up and replaced with lightweight proxies.")
                        }
                    } actions: {
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
                                },
                                onDeleteOriginal: {
                                    viewModel.deleteSingleOriginalFromUserTap(id: item.id)
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
            .navigationTitle("photoHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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

                ToolbarItem(placement: .topBarTrailing) {
                    if !viewModel.candidates.isEmpty {
                        Menu {
                            Button("Select All") { viewModel.selectAllEligible(true) }
                            Button("Deselect All") { viewModel.selectAllEligible(false) }
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .disabled(viewModel.isProcessing)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.selectedCount > 0 || !viewModel.pendingDeleteAssets.isEmpty {
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
                Button("OK", role: .cancel) {
                    viewModel.deleteErrorAlertMessage = nil
                }
            } message: {
                Text(viewModel.deleteErrorAlertMessage ?? "")
            }
            .onAppear {
                if viewModel.candidates.isEmpty && viewModel.settings.autoCompressOnOpen {
                    viewModel.scanAndAutoCompressIfEnabled()
                }
            }
        }
    }

    private var summaryHeader: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.candidates.count) Photos & Videos")
                        .font(.headline)
                    Text("Selected: \(viewModel.selectedCount) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.totalSavedBytes > 0 {
                    Text("Saved \(ByteCountFormatter.string(fromByteCount: viewModel.totalSavedBytes, countStyle: .file))")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
            }

            Picker("After Upload Action", selection: $keepLocalProxyInPhotos) {
                Text("Replace with Proxy").tag(true)
                Text("Delete from iPhone").tag(false)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if !viewModel.pendingDeleteAssets.isEmpty {
                Button(role: .destructive) {
                    viewModel.deleteOriginalsFromUserTap()
                } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete \(viewModel.pendingDeleteAssets.count) Original Photo(s) from iPhone")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            if viewModel.selectedCount > 0 {
                Button {
                    viewModel.startProcessingSelectedPhotos()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Upload & Compress \(viewModel.selectedCount) Item(s)")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

private struct PhotoCandidateRow: View {
    let item: PhotoCandidate
    let onToggleSelect: () -> Void
    let onDeleteOriginal: () -> Void

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
                Text(item.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

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

                Text(item.state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeColor(for: item.state))
            }

            Spacer()

            if case .readyToDelete = item.state {
                Button(role: .destructive) {
                    onDeleteOriginal()
                } label: {
                    Label("Delete", systemImage: "trash.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .readyToDelete = item.state {
                onDeleteOriginal()
            } else {
                onToggleSelect()
            }
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
