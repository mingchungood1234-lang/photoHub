import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var connectionStatus: String?
    @State private var isTesting: Bool = false

    private let resolutions = [1280, 1920, 2048, 2560]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL (e.g. http://192.168.1.100:3000)", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("User Key / API Key (e.g. mingchun)", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

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

                Section("Lightweight Proxy Settings") {
                    Picker("Format", selection: $settings.proxyFormatRaw) {
                        ForEach(ProxyFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt.rawValue)
                        }
                    }

                    Picker("Max Dimension", selection: $settings.proxyMaxPixelSize) {
                        ForEach(resolutions, id: \.self) { px in
                            Text("\(px) px").tag(px)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Compression Quality: \(Int(settings.proxyQuality * 100))%")
                        Slider(value: $settings.proxyQuality, in: 0.4...0.95, step: 0.05)
                    }

                    Stepper(
                        "Skip photos under \(settings.minimumOriginalSizeKB) KB",
                        value: $settings.minimumOriginalSizeKB,
                        in: 100...5000,
                        step: 100
                    )
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
