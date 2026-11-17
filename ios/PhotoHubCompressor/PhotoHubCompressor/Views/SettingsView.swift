import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var connectionStatus: String?
    @State private var isTesting: Bool = false

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
                    Text("1. Your iPhone computes the SHA-256 checksum of the full-resolution original.\n2. The original is uploaded to your server (or S3/MinIO).\n3. Only after the backend confirms the exact SHA-256 checksum on disk does the app replace the local photo with a lightweight proxy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
}
