import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: CompressorViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                                Task { await viewModel.scanLibrary() }
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
                            PhotoCandidateRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.toggleSelection(for: item.id)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("PhotoHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await viewModel.scanLibrary() }
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
                if viewModel.selectedCount > 0 {
                    actionBar
                }
            }
        }
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.candidates.count) Photos Found")
                    .font(.headline)
                Text("Selected: \(viewModel.selectedCount) photos")
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
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var actionBar: some View {
        Button {
            Task { await viewModel.processSelectedPhotos() }
        } label: {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                Text("Upload & Compress \(viewModel.selectedCount) Photos")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .background(.ultraThinMaterial)
        .disabled(viewModel.isProcessing)
    }
}

private struct PhotoCandidateRow: View {
    let item: PhotoCandidate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                .font(.title3)
                .opacity(item.state.isFinished ? 0.3 : 1.0)

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
        }
        .padding(.vertical, 4)
    }

    private func badgeColor(for state: PhotoCompressionState) -> Color {
        switch state {
        case .completed: return .green
        case .alreadyProxy, .skipped: return .secondary
        case .failed: return .red
        case .uploading, .hashing, .verifyingChecksum, .creatingProxy, .replacingInPhotos: return .blue
        case .pending: return .secondary
        }
    }
}
