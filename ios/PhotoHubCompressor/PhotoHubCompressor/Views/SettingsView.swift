import Photos
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var syncManager: LocalProxySyncManager
    @ObservedObject private var restoreManager: OriginalRestoreManager
    @ObservedObject private var authService: GoogleAuthService
    @ObservedObject private var bgManager: BackgroundBackupManager

    init(settings: AppSettings) {
        self.settings = settings
        self._syncManager = ObservedObject(wrappedValue: LocalProxySyncManager.shared)
        self._restoreManager = ObservedObject(wrappedValue: OriginalRestoreManager.shared)
        self._authService = ObservedObject(wrappedValue: GoogleAuthService.shared)
        self._bgManager = ObservedObject(wrappedValue: BackgroundBackupManager.shared)
    }

    @State private var connectionStatus: String?
    @State private var isTesting: Bool = false
    @State private var deleteDiagResult: String?
    @State private var isTestingDelete: Bool = false
    @State private var photosAuthText: String = PhotoLibraryService.currentReadWriteAuthLabel()
    @State private var localProxyCacheBytes: Int64 = LocalProxyStore.shared.totalStorageBytes()
    @State private var copiedShortcutURLNotice: Bool = false

    private var currentResolutionPreset: ProxyResolutionPreset {
        ProxyResolutionPreset.fromStoredPixels(settings.proxyMaxPixelSize)
    }

    private var detailBinding: Binding<ProxyDetailPreset> {
        Binding(
            get: { ProxyDetailPreset.fromStoredQuality(settings.proxyQuality) },
            set: { settings.proxyQuality = $0.qualityValue }
        )
    }

    private var resolutionBinding: Binding<ProxyResolutionPreset> {
        Binding(
            get: { ProxyResolutionPreset.fromStoredPixels(settings.proxyMaxPixelSize) },
            set: { settings.proxyMaxPixelSize = $0.rawValue }
        )
    }

    var body: some View {
        AdaptiveNavigationStack {
            Form {
                accountSection
                storageLimitSection
                overnightBackupSection
                proxySettingsSection
                safetySection
                diagnosticsSection
                localCacheSection
                restoreOriginalsSection
                applePhotosShareSection
            }
            .onAppear {
                photosAuthText = PhotoLibraryService.currentReadWriteAuthLabel()
                localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
                bgManager.refreshNotificationPermissionLabel()
                restoreManager.loadCachedSummary(settings: settings)
                if settings.isSignedIn {
                    Task {
                        await refreshAccountAndStorage()
                        await restoreManager.refreshFromServer(settings: settings)
                    }
                }
            }
            .onChange(of: settings.nightlyAutoBackupEnabled) { enabled in
                if enabled {
                    bgManager.requestNotificationPermissionAndSchedule(settings: settings)
                    bgManager.triggerSilentAutoUpload(settings: settings, isMovingToBackground: false)
                } else {
                    bgManager.scheduleNightlyBackupIfEnabled(settings: settings)
                }
            }
            .onChange(of: settings.nightlyRequiresCharging) { _ in
                bgManager.scheduleNightlyBackupIfEnabled(settings: settings)
            }
            .onChange(of: settings.notifyWhenBackgroundUploadFinishes) { enabled in
                if enabled {
                    bgManager.requestNotificationPermissionIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .localProxyStoreDidChange)) { _ in
                localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
                restoreManager.loadCachedSummary(settings: settings)
            }
            .restoreOriginalsConfirmAlert(prompt: $restoreManager.confirmPrompt) { targets, _ in
                restoreManager.startRestore(targets: targets, settings: settings)
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
                    if let nodeURL = settings.normalizedBaseURL?.absoluteString {
                        Text(nodeURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                restoreManager.reset()
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
    private var overnightBackupSection: some View {
        Section {
            Toggle("Silent Auto Background Upload", isOn: $settings.nightlyAutoBackupEnabled)

            Toggle("Notify When Ready to Delete Originals", isOn: $settings.notifyWhenBackgroundUploadFinishes)

            Toggle("Require Charger for Large Batches", isOn: $settings.nightlyRequiresCharging)
                .disabled(!settings.nightlyAutoBackupEnabled)

            Picker("Overnight Reminder Time", selection: $settings.morningReminderHour) {
                ForEach(6...11, id: \.self) { hr in
                    Text("\(hr):00 AM").tag(hr)
                }
            }
            .disabled(!settings.nightlyAutoBackupEnabled)

            HStack {
                Text("Notification Permission")
                Spacer()
                Text(bgManager.notificationPermissionLabel)
                    .foregroundStyle(bgManager.notificationPermissionLabel == "Allowed" ? .green : .secondary)
            }

            if !bgManager.stagedItems.isEmpty {
                let bytesStr = formatBytes(bgManager.stagedSavedBytes)
                Text("Ready to Delete on iPhone: \(bgManager.stagedItems.count) original\(bgManager.stagedItems.count == 1 ? "" : "s") (free ~\(bytesStr))")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.indigo)
            }

            if !bgManager.lastRunSummary.isEmpty {
                Text(bgManager.lastRunSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Send Test 'Delete Originals' Alert (5s)") {
                bgManager.sendTestMorningAlert(settings: settings)
            }
        } header: {
            Text("Silent Background Upload & Delete Alerts")
        } footer: {
            Text("Just like Google Photos, new photos & videos upload quietly in the background without progress banners or interruptions. Once backups are SHA-256 verified and ready to remove, photoHub sends a notification so you can tap once to delete original photos from your iPhone.")
        }
    }

    @ViewBuilder
    private var proxySettingsSection: some View {
        Section {
            Toggle("Auto Scan & Upload on App Open", isOn: $settings.autoCompressOnOpen)
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

            Picker("Resolution (Photo & Video)", selection: resolutionBinding) {
                ForEach(ProxyResolutionPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }

            Picker("File Size vs Detail", selection: detailBinding) {
                ForEach(ProxyDetailPreset.allCases) { detail in
                    Text(detail.title).tag(detail)
                }
            }

            Text(currentResolutionPreset.resolutionHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Lightweight Proxy Settings")
        } footer: {
            Text("Full-resolution originals always upload first untouched. Lower resolution (e.g. 480p or 720p) keeps local proxies and preview transfers super lightweight while freeing maximum space.")
        }
    }

    @ViewBuilder
    private var safetySection: some View {
        Section("How Safety & Original Deletion Works") {
            Text("1. Your iPhone computes the SHA-256 checksum of the full-resolution original.\n2. The original uploads to your server in the foreground or background (iOS 26+ continued tasks & scheduled Wi-Fi runs).\n3. Only after your server verifies the exact SHA-256 checksum on disk does photoHub save the proxy and ask you to delete the original photo from your iPhone.\n4. Apple moves deleted originals to Photos → Recently Deleted for 30 days (tap Delete All there to free space right away), while full-resolution originals remain restorable anytime.")
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

    @ViewBuilder
    private var restoreOriginalsSection: some View {
        Section {
            HStack {
                Text("Originals Status")
                Spacer()
                if restoreManager.isLoadingSummary && !restoreManager.hasLoadedSummary {
                    ProgressView()
                } else if restoreManager.totalCount > 0 {
                    if restoreManager.unrestoredCount > 0 {
                        let sizeStr = formatBytes(restoreManager.unrestoredBytes)
                        Text("\(restoreManager.unrestoredCount) of \(restoreManager.totalCount) not restored (~\(sizeStr))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("All \(restoreManager.totalCount) protected/restored")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                } else if restoreManager.hasLoadedSummary {
                    Text("0 items on server")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap Restore to check")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if restoreManager.isRestoring {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Restoring originals (\(restoreManager.completedCount)/\(restoreManager.batchTotalCount))…")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Stop") {
                            restoreManager.stopRestore()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    if !restoreManager.currentItemName.isEmpty {
                        Text(restoreManager.currentItemName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    restoreManager.requestRestoreAll(settings: settings)
                } label: {
                    HStack {
                        Label("Restore All Originals to Photos", systemImage: "icloud.and.arrow.down")
                        Spacer()
                        if restoreManager.isLoadingSummary {
                            ProgressView()
                        }
                    }
                }
                .disabled(
                    settings.normalizedBaseURL == nil
                    || !settings.isSignedIn
                    || restoreManager.isLoadingSummary
                )

                if let msg = restoreManager.statusMessage {
                    HStack(spacing: 8) {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            restoreManager.statusMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            Text("Restore Originals")
        } footer: {
            Text("Downloads full-resolution originals from your server into Apple Photos and marks them protected so automatic proxy cleanup will not re-compress them.")
        }
    }

    @ViewBuilder
    private var applePhotosShareSection: some View {
        Section {
            Button {
                IncomingShareCoordinator.shared.presentInAppPhotoPicker()
            } label: {
                Label("Pick Photos to Share Original Now", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(!settings.isSignedIn || settings.normalizedBaseURL == nil)

            Button {
                if let url = URL(string: "shortcuts://") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Apple Shortcuts App", systemImage: "command")
            }

            Button {
                UIPasteboard.general.string = "photohub://share-original?from=clipboard"
                copiedShortcutURLNotice = true
            } label: {
                Label("Copy iOS 15 Shortcut URL Scheme", systemImage: "doc.on.doc")
            }

            if copiedShortcutURLNotice {
                Text("Copied: photohub://share-original?from=clipboard")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("1-Tap Setup from Apple Photos Share Sheet:")
                    .font(.caption.weight(.semibold))
                Text("1. Open Shortcuts -> tap + -> tap (i) Details -> enable Show in Share Sheet (Images & Media).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("2. Add action: photoHub -> Fetch & Share Original (pass Shortcut Input).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("3. On iOS 15: add Copy to Clipboard, then Open URLs (photohub://share-original?from=clipboard).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Share Original from Apple Photos")
        } footer: {
            Text("Uses Apple Shortcuts inside the main app (1 App ID, zero App Groups/extensions) so it works reliably on Free Apple Accounts & sideloaded installs.")
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

extension View {
    func restoreOriginalsConfirmAlert(
        prompt: Binding<RestoreConfirmPrompt?>,
        onConfirm: @escaping (_ targets: [ServerPhoto], _ prompt: RestoreConfirmPrompt) -> Void
    ) -> some View {
        alert(
            prompt.wrappedValue?.title ?? "Restore Originals",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            presenting: prompt.wrappedValue
        ) { current in
            if !current.unrestoredTargets.isEmpty {
                Button("Restore \(current.unrestoredTargets.count)") {
                    onConfirm(current.unrestoredTargets, current)
                }
                if current.skippedCount > 0 {
                    Button("Include \(current.skippedCount) Already Restored (\(current.allTargets.count))") {
                        onConfirm(current.allTargets, current)
                    }
                }
            } else {
                Button("Re-download All (\(current.allTargets.count))") {
                    onConfirm(current.allTargets, current)
                }
            }
            Button("Cancel", role: .cancel) {
                prompt.wrappedValue = nil
            }
        } message: { current in
            Text(current.messageText)
        }
    }
}
