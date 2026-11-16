import Photos
import SwiftUI

struct ServerGalleryView: View {
    @ObservedObject var settings: AppSettings
    @State private var photos: [ServerPhoto] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: ServerPhoto?
    @State private var imageCache: [String: UIImage] = [:]

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 3)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && photos.isEmpty {
                    ProgressView("Loading server photos…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, photos.isEmpty {
                    ContentUnavailableView {
                        Label("Could Not Load Server Photos", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") {
                            Task { await loadPhotos() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if photos.isEmpty {
                    ContentUnavailableView {
                        Label("No Photos on Server", systemImage: "cloud")
                    } description: {
                        Text("Photos you upload and compress will appear here.")
                    } actions: {
                        Button("Refresh") {
                            Task { await loadPhotos() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
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
                                    await loadImageIfNeeded(for: photo)
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .refreshable {
                        await loadPhotos()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Server (\(photos.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadPhotos() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                if photos.isEmpty {
                    await loadPhotos()
                }
            }
            .fullScreenCover(item: $selectedPhoto) { photo in
                ServerPhotoDetailView(
                    photo: photo,
                    settings: settings,
                    initialImage: imageCache[photo.hash]
                )
            }
        }
    }

    private func loadPhotos() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = PhotoHubAPIClient(settings: settings)
        do {
            photos = try await client.fetchServerPhotos()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadImageIfNeeded(for photo: ServerPhoto) async {
        guard imageCache[photo.hash] == nil else { return }
        let client = PhotoHubAPIClient(settings: settings)
        if let data = try? await client.downloadPhotoData(hash: photo.hash),
           let uiImage = UIImage(data: data) {
            imageCache[photo.hash] = uiImage
        }
    }
}

private struct ServerThumbnailCell: View {
    let photo: ServerPhoto
    let image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                .clipped()

            if photo.hasProxy == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.55))
                    .clipShape(Circle())
                    .padding(4)
            }
        }
    }
}

private struct ServerPhotoDetailView: View {
    let photo: ServerPhoto
    @ObservedObject var settings: AppSettings
    let initialImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var isRestoring: Bool = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let img = fullImage ?? initialImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(photo.originalName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(ByteCountFormatter.string(fromByteCount: photo.size, countStyle: .file)) • \(photo.photoDate)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Spacer()
                        Button {
                            Task { await restoreToPhotos() }
                        } label: {
                            if isRestoring {
                                ProgressView().tint(.white)
                            } else {
                                Label("Save Original", systemImage: "square.and.arrow.down")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRestoring)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .task {
                if fullImage == nil {
                    let client = PhotoHubAPIClient(settings: settings)
                    if let data = try? await client.downloadPhotoData(hash: photo.hash),
                       let img = UIImage(data: data) {
                        fullImage = img
                    }
                }
            }
        }
    }

    private func restoreToPhotos() async {
        isRestoring = true
        restoreMessage = nil
        defer { isRestoring = false }

        do {
            let client = PhotoHubAPIClient(settings: settings)
            let data = try await client.downloadPhotoData(hash: photo.hash)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(photo.originalName)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tempURL)
            }
            restoreMessage = "Saved full-resolution original to Photos!"
        } catch {
            restoreMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}
