import ImageIO
import Photos
import SwiftUI

struct ServerGalleryView: View {
    @ObservedObject var settings: AppSettings
    @State private var photos: [ServerPhoto] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: ServerPhoto?
    @State private var imageCache: [String: UIImage] = [:]
    @State private var compressedDataCache: [String: Data] = [:]

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 3)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && photos.isEmpty {
                    ProgressView("Loading compressed server previews…")
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
                        Text("Photos you upload and compress will appear here as lightweight compressed previews.")
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
                                    await loadCompressedPreviewIfNeeded(for: photo)
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
                    initialImage: imageCache[photo.hash],
                    initialCompressedData: compressedDataCache[photo.hash]
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

    private func loadCompressedPreviewIfNeeded(for photo: ServerPhoto) async {
        guard imageCache[photo.hash] == nil else { return }
        let client = PhotoHubAPIClient(settings: settings)
        if let rawData = try? await client.downloadPhotoPreviewData(hash: photo.hash),
           let (smallImage, smallData) = Self.makeSmallCompressedPreview(from: rawData, maxPixelSize: 800, quality: 0.65) {
            imageCache[photo.hash] = smallImage
            compressedDataCache[photo.hash] = smallData
        }
    }

    static func makeSmallCompressedPreview(
        from data: Data,
        maxPixelSize: Int = 800,
        quality: CGFloat = 0.65
    ) -> (UIImage, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            guard let img = UIImage(data: data),
                  let jpg = img.jpegData(compressionQuality: quality) else { return nil }
            return (UIImage(data: jpg) ?? img, jpg)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let uiImg = UIImage(cgImage: cgImg)
        guard let smallJpg = uiImg.jpegData(compressionQuality: quality),
              let decodedSmall = UIImage(data: smallJpg) else {
            return (uiImg, data)
        }
        return (decodedSmall, smallJpg)
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

            Text("PROXY")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(4)
        }
    }
}

private struct ServerPhotoDetailView: View {
    let photo: ServerPhoto
    @ObservedObject var settings: AppSettings
    let initialImage: UIImage?
    let initialCompressedData: Data?

    @Environment(\.dismiss) private var dismiss
    @State private var previewImage: UIImage?
    @State private var compressedData: Data?
    @State private var isSaving: Bool = false
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let img = previewImage ?? initialImage {
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
                    if let saveMessage {
                        Text(saveMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(photo.originalName) (Compressed Demo)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            let smallBytes = Int64((compressedData ?? initialCompressedData)?.count ?? Int(photo.proxySize ?? 0))
                            let smallStr = smallBytes > 0
                                ? ByteCountFormatter.string(fromByteCount: smallBytes, countStyle: .file)
                                : "Small Proxy"
                            let masterStr = ByteCountFormatter.string(fromByteCount: photo.size, countStyle: .file)
                            Text("Preview: \(smallStr) • Original Master: \(masterStr)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Spacer()
                        Button {
                            Task { await saveCompressedPreviewToPhotos() }
                        } label: {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Label("Save Proxy", systemImage: "photo")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .disabled(isSaving)

                        Button {
                            Task { await restoreFullMasterToPhotos() }
                        } label: {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Label("Restore Original", systemImage: "arrow.down.circle.fill")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
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
                if previewImage == nil {
                    if let initialImage, let initialCompressedData {
                        previewImage = initialImage
                        compressedData = initialCompressedData
                        return
                    }
                    let client = PhotoHubAPIClient(settings: settings)
                    if let rawData = try? await client.downloadPhotoPreviewData(hash: photo.hash),
                       let (smallImg, smallJpg) = ServerGalleryView.makeSmallCompressedPreview(from: rawData, maxPixelSize: 800, quality: 0.65) {
                        previewImage = smallImg
                        compressedData = smallJpg
                    }
                }
            }
        }
    }

    private func saveCompressedPreviewToPhotos() async {
        isSaving = true
        saveMessage = nil
        defer { isSaving = false }

        do {
            let dataToSave: Data
            if let existing = compressedData ?? initialCompressedData {
                dataToSave = existing
            } else {
                let client = PhotoHubAPIClient(settings: settings)
                let raw = try await client.downloadPhotoPreviewData(hash: photo.hash)
                dataToSave = ServerGalleryView.makeSmallCompressedPreview(from: raw, maxPixelSize: 800, quality: 0.65)?.1 ?? raw
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: dataToSave, options: nil)
                }, completionHandler: { success, err in
                    if success {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: err ?? PhotoLibraryError.proxyReplacementFailed("Could not save preview"))
                    }
                })
            }
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(dataToSave.count), countStyle: .file)
            saveMessage = "Saved small compressed picture (\(sizeStr)) to Photos!"
        } catch {
            saveMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func restoreFullMasterToPhotos() async {
        isSaving = true
        saveMessage = nil
        defer { isSaving = false }

        do {
            let client = PhotoHubAPIClient(settings: settings)
            let masterData = try await client.downloadPhotoData(hash: photo.hash)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: masterData, options: nil)
                }, completionHandler: { success, err in
                    if success {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: err ?? PhotoLibraryError.proxyReplacementFailed("Could not restore original"))
                    }
                })
            }
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(masterData.count), countStyle: .file)
            saveMessage = "Restored full-resolution original (\(sizeStr)) to Photos!"
        } catch {
            saveMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}
