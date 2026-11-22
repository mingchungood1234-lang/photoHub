import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Uses `NavigationStack` on iOS 16+ and falls back cleanly to stacked `NavigationView` on iOS 15.
struct AdaptiveNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

/// Uses `ContentUnavailableView` on iOS 17+ and a clean custom empty state on iOS 15-16.
struct CompatibleEmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            } actions: {
                actions()
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                actions()
                    .padding(.top, 4)
            }
            .padding()
        }
    }
}

extension View {
    @ViewBuilder
    func compatibleAutocorrectionDisabled() -> some View {
        if #available(iOS 16.0, *) {
            autocorrectionDisabled(true)
        } else {
            disableAutocorrection(true)
        }
    }

    @ViewBuilder
    func compatibleHiddenNavBarBackground() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
        }
    }
}

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

func cleanupTempShareURL(_ url: URL) {
    let parent = url.deletingLastPathComponent()
    if parent.lastPathComponent.hasPrefix("photohub_share_") {
        try? FileManager.default.removeItem(at: parent)
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Native iOS Share Sheet wrapper with automatic completion/cancel callback for temp file cleanup.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        let finishShare = onComplete
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                finishShare()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct PickedMediaResult: Sendable {
    let assetId: String?
    let copiedFileURL: URL?
    let isVideo: Bool
}

/// Multi-select iOS 15+ PHPicker wrapper returning `[PickedMediaResult]` for checking gallery proxy/original status.
struct MultiPhotoPickerSheet: UIViewControllerRepresentable {
    var selectionLimit: Int = 25
    let onPickBatch: ([PickedMediaResult]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickBatch: onPickBatch, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPickBatch: ([PickedMediaResult]) -> Void
        private let onCancel: () -> Void

        init(onPickBatch: @escaping ([PickedMediaResult]) -> Void, onCancel: @escaping () -> Void) {
            self.onPickBatch = onPickBatch
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                onCancel()
                return
            }

            let finishBatch = onPickBatch
            let lock = NSLock()
            var loaded = Array<PickedMediaResult?>(repeating: nil, count: results.count)
            let group = DispatchGroup()

            for (idx, item) in results.enumerated() {
                group.enter()
                PhotoPickerItemLoader.loadPickedResult(from: item, skipCopyIfTracked: false) { picked in
                    lock.lock()
                    loaded[idx] = picked
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                finishBatch(loaded.compactMap { $0 })
            }
        }
    }
}

private enum PhotoPickerItemLoader {
    static func loadPickedResult(
        from result: PHPickerResult,
        skipCopyIfTracked: Bool,
        completion: @escaping (PickedMediaResult) -> Void
    ) {
        let assetId = result.assetIdentifier
        let provider = result.itemProvider
        let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)

        if skipCopyIfTracked,
           let assetId,
           LocalProxyTracker.shared.masterLookup(forAssetId: assetId) != nil {
            completion(PickedMediaResult(assetId: assetId, copiedFileURL: nil, isVideo: isVideo))
            return
        }

        let typeId: String
        if isVideo {
            typeId = UTType.movie.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            typeId = UTType.image.identifier
        } else {
            typeId = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
            var copiedURL: URL?
            if let url {
                let ext = url.pathExtension.isEmpty ? (isVideo ? "mp4" : "jpg") : url.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("photohub_pick_\(UUID().uuidString.prefix(8)).\(ext)")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    copiedURL = dest
                }
            }
            let out = PickedMediaResult(assetId: assetId, copiedFileURL: copiedURL, isVideo: isVideo)
            DispatchQueue.main.async {
                completion(out)
            }
        }
    }
}

/// iOS 15+ PHPicker wrapper returning `assetIdentifier` and (when needed) a temporary file copy for SHA-256 lookup.
struct PhotoPickerSheet: UIViewControllerRepresentable {
    let onPick: (PickedMediaResult) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (PickedMediaResult) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (PickedMediaResult) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let first = results.first else {
                onCancel()
                return
            }
            PhotoPickerItemLoader.loadPickedResult(
                from: first,
                skipCopyIfTracked: true,
                completion: onPick
            )
        }
    }
}
