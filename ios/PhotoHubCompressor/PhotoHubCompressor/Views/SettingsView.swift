import Photos
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var connectionStatus: String?
    @State private var isTesting: Bool = false
    @State private var deleteDiagResult: String?
    @State private var isTestingDelete: Bool = false
    @State private var photosAuthText: String = PhotoLibraryService.currentReadWriteAuthLabel()
    @State private var localProxyCacheBytes: Int64 = LocalProxyStore.shared.totalStorageBytes()

    private let resolutions = [0, 1280, 1920, 2048, 2560]

    var body: some View {
        AdaptiveNavigationStack {
            Form {
                Section {
                    Picker("Protocol", selection: $settings.serverProtocolRaw) {
                        ForEach(ServerProtocol.allCases) { proto in
                            Text(proto.displayName).tag(proto.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Host / IP (e.g. 10.8.0.1:3000 or photos.domain.com)", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .compatibleAutocorrectionDisabled()

                    if let resolved = settings.normalizedBaseURL {
                        Text("Using: \(resolved.absoluteString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if settings.serverProtocol == .https {
                        Toggle("Allow Self-Signed HTTPS (VPN / Testing)", isOn: $settings.allowSelfSignedHTTPS)
                    }

                    SecureField("User Key / API Key (e.g. mingchun)", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .compatibleAutocorrectionDisabled()

                    Picker("Upload Mode", selection: $settings.uploadModeRaw) {
                        ForEach(UploadMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Server & Key")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting)

                    if let connectionStatus {
                        Text(connectionStatus)
                            .font(.footnote)
                            .foregroundStyle(connectionStatus.hasPrefix("Connected") ? .green : .red)
                    }
                } header: {
                    Text("PhotoHub Server")
                } footer: {
                    Text("Your User Key (from .env USER_KEYS) determines which folder on the server stores and lists your photos.")
                }

                Section {
                    Toggle("Auto Scan & Compress on App Open", isOn: $settings.autoCompressOnOpen)
                    Toggle("Keep Compressed Proxy in iPhone Photos", isOn: $settings.keepLocalProxyInPhotos)

                    Picker("Format", selection: $settings.proxyFormatRaw) {
                        ForEach(ProxyFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt.rawValue)
                        }
                    }

                    Picker("Proxy Target Size", selection: $settings.proxyMaxPixelSize) {
                        ForEach(resolutions, id: \.self) { px in
                            if px == 0 {
                                Text("Auto (All Resolutions)").tag(0)
                            } else {
                                Text("\(px) px").tag(px)
                            }
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Compression Quality: \(Int(settings.proxyQuality * 100))%")
                        Slider(value: $settings.proxyQuality, in: 0.4...0.95, step: 0.05)
                    }
                } header: {
                    Text("Lightweight Proxy Settings")
                } footer: {
                    Text("When 'Keep Compressed Proxy in iPhone Photos' is ON, the original photo is replaced with a small proxy in Photos. Turn it OFF to delete the photo from your iPhone completely after uploading to the Server tab.")
                }

                Section("How Safety Works") {
                    Text("1. Your iPhone computes the SHA-256 checksum of the full-resolution original.\n2. The original is uploaded to your server (or S3/MinIO).\n3. Only after the backend confirms the exact SHA-256 checksum on disk does the app request deletion via iOS Photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("iOS Photos Diagnostics") {
                    HStack {
                        Text("Photos Permission")
                        Spacer()
                        Text(photosAuthText)
                            .foregroundStyle(photosAuthText == "Full Access" ? .green : .orange)
                    }

                    Button {
                        runDeleteDiagnostic()
                    } label: {
                        HStack {
                            Text("Test Native Delete Alert (Latest Photo)")
                            Spacer()
                            if isTestingDelete { ProgressView() }
                        }
                    }
                    .disabled(isTestingDelete)

                    Button("Open iOS Settings for photoHub") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }

                    if let deleteDiagResult {
                        Text(deleteDiagResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Text("Cached Proxies on iPhone")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: localProxyCacheBytes, countStyle: .file))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Auto-Download Proxied Photos Locally", isOn: $settings.autoDownloadLocalProxies)

                    Toggle("Auto-Download Compressed Videos (.mp4)", isOn: $settings.autoDownloadLocalVideos)
                        .disabled(!settings.autoDownloadLocalProxies)

                    Button(role: .destructive) {
                        LocalProxySyncManager.shared.cancel()
                        LocalProxyStore.shared.clearAll()
                        localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
                    } label: {
                        Text("Clear Local Proxy Cache")
                    }
                    .disabled(localProxyCacheBytes == 0)
                } header: {
                    Text("Local Proxy Storage")
                } footer: {
                    Text("Compressed image previews and compressed MP4 video proxies are saved locally inside the app so the Server tab opens them immediately. Clearing the cache does not delete any originals on your server or proxies saved in iPhone Photos.")
                }
            }
            .onAppear {
                photosAuthText = PhotoLibraryService.currentReadWriteAuthLabel()
                localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
            }
            .onReceive(NotificationCenter.default.publisher(for: .localProxyStoreDidChange)) { _ in
                localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func testConnection() async {
        isTesting = true
        connectionStatus = nil
        defer { isTesting = false }

        let client = PhotoHubAPIClient(settings: settings)
        do {
            let info = try await client.whoami()
            let folderLabel = info.userFolder.map { "Folder: \($0)" } ?? "Root folder"
            let s3Note = (info.s3Enabled == true) ? "S3 enabled" : "Direct VPS"
            connectionStatus = "Connected! \(folderLabel) (\(info.indexedPhotos) photos, \(s3Note))"
        } catch {
            connectionStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func runDeleteDiagnostic() {
        isTestingDelete = true
        deleteDiagResult = "Requesting native iOS delete alert for newest photo (tap Don't Allow if you want to keep it)…"
        PhotoLibraryService().testDeletePromptOnLatestAsset { message in
            isTestingDelete = false
            photosAuthText = PhotoLibraryService.currentReadWriteAuthLabel()
            deleteDiagResult = message
        }
    }
}
