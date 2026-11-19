import Photos
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var syncManager: LocalProxySyncManager
    @ObservedObject private var authService: GoogleAuthService

    init(settings: AppSettings) {
        self.settings = settings
        self._syncManager = ObservedObject(wrappedValue: LocalProxySyncManager.shared)
        self._authService = ObservedObject(wrappedValue: GoogleAuthService.shared)
    }

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
                accountSection
                storageLimitSection
                proxySettingsSection
                safetySection
                diagnosticsSection
                localCacheSection
            }
            .onAppear {
                photosAuthText = PhotoLibraryService.currentReadWriteAuthLabel()
                localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
                if settings.isSignedIn {
                    Task { await refreshAccountAndStorage() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .localProxyStoreDidChange)) { _ in
                localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.userName.isEmpty ? "Google Account" : settings.userName)
                        .font(.subheadline.weight(.semibold))
                    if !settings.userEmail.isEmpty {
                        Text(settings.userEmail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(settings.assignedNodeId)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .foregroundColor(.green)
            }

            Button {
                Task { await refreshAccountAndStorage() }
            } label: {
                HStack {
                    Text("Refresh Connection & Storage")
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

            Button(role: .destructive) {
                LocalProxySyncManager.shared.cancel()
                settings.signOut()
            } label: {
                Text("Sign Out")
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Automatically connected to your assigned PhotoHub server instance via Google Login.")
        }
    }

    @ViewBuilder
    private var storageLimitSection: some View {
        Section {
            if let storage = settings.serverStorage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(formatBytes(storage.usedBytes))
                            .font(.headline.monospacedDigit())
                        if let limit = storage.effectiveLimitBytes {
                            Text("of \(formatBytes(limit))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("used")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if storage.effectiveLimitBytes != nil {
                            Text("\(Int((storage.usageFraction * 100).rounded()))%")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(storageTintColor(storage.usageFraction))
                        }
                    }

                    if storage.effectiveLimitBytes != nil {
                        ProgressView(value: storage.usageFraction)
                            .tint(storageTintColor(storage.usageFraction))
                    }

                    HStack {
                        if let remaining = storage.remainingBytes {
                            Text(
                                storage.isFixedQuota
                                ? "\(formatBytes(remaining)) remaining"
                                : "\(formatBytes(remaining)) free on server"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let count = storage.itemCount {
                            Text("\(count) item\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                if let masters = storage.mastersBytes, let proxies = storage.proxiesBytes {
                    HStack {
                        Text("Originals · Proxies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formatBytes(masters)) · \(formatBytes(proxies))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView()
                        Text("Checking server storage...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap Refresh Connection & Storage to load your quota.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Server Storage Limit")
        } footer: {
            if let storage = settings.serverStorage, storage.isFixedQuota {
                Text("Uploads stop automatically when your assigned storage quota is reached so data integrity is always protected.")
            } else {
                Text("Shows your used backup storage and available capacity on your assigned server node.")
            }
        }
    }

    @ViewBuilder
    private var proxySettingsSection: some View {
        Section {
            Toggle("Auto Scan & Compress on App Open", isOn: $settings.autoCompressOnOpen)
            Toggle("Keep Compressed Proxy in iPhone Photos", isOn: $settings.keepLocalProxyInPhotos)

            Picker("Upload Mode", selection: $settings.uploadModeRaw) {
                ForEach(UploadMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

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
    }

    @ViewBuilder
    private var safetySection: some View {
        Section("How Safety Works") {
            Text("1. Your iPhone computes the SHA-256 checksum of the full-resolution original.\n2. The original is uploaded to your server (or S3/MinIO).\n3. Only after the backend confirms the exact SHA-256 checksum on disk does the app request deletion via iOS Photos.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
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
    }

    @ViewBuilder
    private var localCacheSection: some View {
        Section {
            Toggle("Auto-Save Proxies to iPhone Photos", isOn: $settings.autoSaveProxiesToPhotosApp)

            if syncManager.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(
                        syncManager.statusText.isEmpty
                        ? "Downloading (\(syncManager.completedCount)/\(syncManager.totalCount))..."
                        : syncManager.statusText
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        syncManager.cancel()
                    }
                    .font(.caption)
                }
            } else {
                Button {
                    LocalProxySyncManager.shared.downloadAllMissingToPhotos(settings: settings)
                } label: {
                    Label("Download All Proxies to iPhone Photos", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(settings.normalizedBaseURL == nil)

                if !syncManager.statusText.isEmpty {
                    Text(syncManager.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Cached Proxies in App")
                Spacer()
                Text(formatBytes(localProxyCacheBytes))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Toggle("Auto-Cache Proxies in App", isOn: $settings.autoDownloadLocalProxies)

            Toggle("Auto-Download Compressed Videos (.mp4)", isOn: $settings.autoDownloadLocalVideos)
                .disabled(!settings.autoDownloadLocalProxies && !settings.autoSaveProxiesToPhotosApp)

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
            Text("Compressed image previews and MP4 video proxies are saved into your iPhone Photos app automatically without re-uploading them or creating duplicates, and cached locally inside the app for instant browsing.")
        }
    }

    private func refreshAccountAndStorage() async {
        isTesting = true
        connectionStatus = nil
        defer { isTesting = false }

        await authService.refreshGatewayRouteAndStorage(settings: settings)
        guard settings.isSignedIn else { return }

        do {
            let info = try await PhotoHubAPIClient(settings: settings).whoami()
            settings.serverStorage = info.storage
            let folderNote = info.userFolder.map { "/\($0)" } ?? "/ (root)"
            let s3Note = (info.s3Enabled == true) ? "S3" : "Direct"
            connectionStatus = "Connected · Folder: \(folderNote) · \(info.indexedPhotos) items (\(s3Note))"
        } catch {
            connectionStatus = "Offline: \(error.localizedDescription)"
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

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func storageTintColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return .green
    }
}
