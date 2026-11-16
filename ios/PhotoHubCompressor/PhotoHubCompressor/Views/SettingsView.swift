import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var connectionStatus: String?
    @State private var isTesting: Bool = false

    private let resolutions = [1280, 1920, 2048, 2560]

    var body: some View {
        NavigationStack {
            Form {
                Section("PhotoHub Server") {
                    TextField("Server URL (e.g. http://192.168.1.100:3000)", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API Key (optional)", text: $settings.apiKey)
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
                            Text("Test Server Connection")
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
            .navigationTitle("Settings")
        }
    }

    private func testConnection() async {
        isTesting = true
        connectionStatus = nil
        defer { isTesting = false }

        let client = PhotoHubAPIClient(settings: settings)
        do {
            let health = try await client.checkHealth()
            let s3Note = (health.s3Enabled == true) ? "S3 enabled" : "Direct VPS mode"
            connectionStatus = "Connected! (\(health.indexedPhotos) indexed photos, \(s3Note))"
        } catch {
            connectionStatus = "Failed: \(error.localizedDescription)"
        }
    }
}
