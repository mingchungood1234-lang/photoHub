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
    @State private var showAdvancedDiagnostics: Bool = false
    @State private var showingOnboardingReplay: Bool = false

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
            ZStack {
                PhotoHubPalette.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        accountCard
                        storageCard
                        backupModeCard
                        autoBackupCard
                        proxyCard
                        restoreCard
                        cacheCard
                        shareOriginalCard
                        photosAccessCard
                        advancedDiagnosticsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
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
            .onChange(of: settings.wifiOnlyBackup) { _ in
                bgManager.scheduleNightlyBackupIfEnabled(settings: settings)
                if settings.nightlyAutoBackupEnabled {
                    bgManager.triggerSilentAutoUpload(settings: settings, isMovingToBackground: false)
                }
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
            .restoreOriginalsConfirmAlert(
                prompt: $restoreManager.confirmPrompt,
                onDeleteLeftoverProxies: { hashes in
                    restoreManager.deleteLeftoverCompressedProxies(hashes: hashes, settings: settings)
                },
                onConfirm: { targets, prompt in
                    restoreManager.startRestore(
                        targets: targets,
                        settings: settings,
                        additionalProxyCleanupHashes: prompt.leftoverProxyHashes
                    )
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingOnboardingReplay) {
                OnboardingView(
                    settings: settings,
                    isReplay: true,
                    onDismissReplay: {
                        showingOnboardingReplay = false
                    }
                )
            }
        }
    }

    // MARK: - Warm Card Helper

    @ViewBuilder
    private func card<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundColor(PhotoHubPalette.orange)
                Text(title)
                    .font(.caption.weight(.heavy))
                    .foregroundColor(PhotoHubPalette.muted)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Sections

    private var accountCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SunnyMascotView(
                    mood: bgManager.activeBackgroundUploadCount > 0 ? .uploading : .happy,
                    size: 56
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.userName.isEmpty ? "Account" : settings.userName)
                        .font(.headline.weight(.bold))
                        .foregroundColor(PhotoHubPalette.ink)
                        .lineLimit(1)
                    if !settings.userEmail.isEmpty {
                        Text(settings.userEmail)
                            .font(.caption)
                            .foregroundColor(PhotoHubPalette.muted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        let isOffline = (connectionStatus == "Offline")
                        WarmStatPill(
                            icon: isOffline ? "wifi.slash" : "checkmark.circle.fill",
                            text: isOffline ? "Offline" : "Online · Synced",
                            tint: isOffline ? PhotoHubPalette.rose : PhotoHubPalette.mint
                        )
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    Task { await refreshAccountAndStorage() }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .tint(PhotoHubPalette.deepOrange)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PhotoHubSoftButtonStyle())
                .disabled(isTesting)

                Button {
                    LocalProxySyncManager.shared.cancel()
                    restoreManager.reset()
                    settings.signOut()
                } label: {
                    Text("Sign Out")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(PhotoHubPalette.rose)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(PhotoHubPalette.rose.opacity(0.11), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
        )
    }

    private var storageCard: some View {
        card(title: "Storage", icon: "externaldrive.fill") {
            if let storage = settings.serverStorage {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatBytes(storage.usedBytes))
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.ink)
                    if let limit = storage.effectiveLimitBytes {
                        Text("/ \(formatBytes(limit))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(PhotoHubPalette.muted)
                    }
                    Spacer()
                    if storage.effectiveLimitBytes != nil {
                        Text("\(Int((storage.usageFraction * 100).rounded()))%")
                            .font(.caption.weight(.heavy).monospacedDigit())
                            .foregroundColor(storageTintColor(storage.usageFraction))
                    }
                }

                if storage.effectiveLimitBytes != nil {
                    ProgressView(value: storage.usageFraction)
                        .tint(storageTintColor(storage.usageFraction))
                }

                HStack {
                    if let remaining = storage.remainingBytes {
                        WarmStatPill(icon: "checkmark.circle.fill", text: "\(formatBytes(remaining)) free", tint: PhotoHubPalette.mint)
                    }
                    Spacer()
                    if let count = storage.itemCount {
                        Text("\(count) items")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundColor(PhotoHubPalette.muted)
                    }
                }

                if let masters = storage.mastersBytes, let proxies = storage.proxiesBytes {
                    HStack {
                        Text("Originals · Proxies")
                            .font(.caption)
                            .foregroundColor(PhotoHubPalette.muted)
                        Spacer()
                        Text("\(formatBytes(masters)) · \(formatBytes(proxies))")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundColor(PhotoHubPalette.ink)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView().tint(PhotoHubPalette.orange)
                    }
                    Text(isTesting ? "Loading…" : "Tap Refresh")
                        .font(.caption)
                        .foregroundColor(PhotoHubPalette.muted)
                }
            }
        }
    }

    private var backupModeCard: some View {
        card(title: "Backup Mode", icon: "checkmark.shield.fill") {
            Picker("Backup Mode", selection: Binding(
                get: { settings.backupStorageMode },
                set: { settings.applyBackupStorageMode($0) }
            )) {
                Text("Optimize Storage").tag(BackupStorageMode.optimizeStorage)
                Text("Backup Only").tag(BackupStorageMode.backupOnly)
            }
            .pickerStyle(.segmented)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: settings.isBackupOnlyMode ? "lock.shield.fill" : "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundColor(settings.isBackupOnlyMode ? PhotoHubPalette.mint : PhotoHubPalette.orange)
                    .padding(.top, 2)
                Text(settings.backupStorageMode.subtitle)
                    .font(.caption)
                    .foregroundColor(PhotoHubPalette.muted)
            }

            Button {
                showingOnboardingReplay = true
            } label: {
                Label("Replay Welcome Tutorial", systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PhotoHubSoftButtonStyle())
        }
    }

    private var autoBackupCard: some View {
        card(title: "Auto Backup", icon: "icloud.and.arrow.up.fill") {
            Toggle("Background Upload", isOn: $settings.nightlyAutoBackupEnabled)
                .tint(PhotoHubPalette.orange)
            if !settings.isBackupOnlyMode {
                Toggle("Delete Alerts", isOn: $settings.notifyWhenBackgroundUploadFinishes)
                    .tint(PhotoHubPalette.orange)
            }
            Toggle("Charger Only", isOn: $settings.nightlyRequiresCharging)
                .tint(PhotoHubPalette.orange)
                .disabled(!settings.nightlyAutoBackupEnabled)
            Toggle("Wi-Fi Only", isOn: $settings.wifiOnlyBackup)
                .tint(PhotoHubPalette.orange)
                .disabled(!settings.nightlyAutoBackupEnabled)

            if !settings.isBackupOnlyMode {
                HStack {
                    Text("Reminder")
                        .font(.subheadline)
                        .foregroundColor(PhotoHubPalette.ink)
                    Spacer()
                    Picker("Reminder", selection: $settings.morningReminderHour) {
                        ForEach(6...11, id: \.self) { hr in
                            Text("\(hr):00 AM").tag(hr)
                        }
                    }
                    .labelsHidden()
                    .tint(PhotoHubPalette.orange)
                    .disabled(!settings.nightlyAutoBackupEnabled)
                }

                HStack {
                    Text("Alerts")
                        .font(.subheadline)
                        .foregroundColor(PhotoHubPalette.ink)
                    Spacer()
                    let allowed = bgManager.notificationPermissionLabel == "Allowed"
                    WarmStatPill(
                        icon: allowed ? "bell.fill" : "bell.slash",
                        text: allowed ? "Allowed" : "Off",
                        tint: allowed ? PhotoHubPalette.mint : PhotoHubPalette.warmAmber
                    )
                }

                if !bgManager.stagedItems.isEmpty {
                    let bytesStr = formatBytes(bgManager.stagedSavedBytes)
                    WarmStatPill(
                        icon: "trash",
                        text: "\(bgManager.stagedItems.count) ready · ~\(bytesStr)",
                        tint: PhotoHubPalette.orange
                    )
                }
            } else {
                WarmStatPill(
                    icon: "checkmark.shield.fill",
                    text: "Originals stay untouched on iPhone",
                    tint: PhotoHubPalette.mint
                )
            }

            if !bgManager.lastRunSummary.isEmpty {
                Text(bgManager.lastRunSummary)
                    .font(.caption)
                    .foregroundColor(PhotoHubPalette.muted)
            }
        }
    }

    private var proxyCard: some View {
        card(title: "Proxy", icon: "sparkles") {
            Toggle("Auto Scan", isOn: $settings.autoCompressOnOpen)
                .tint(PhotoHubPalette.orange)
            if !settings.isBackupOnlyMode {
                Toggle("Keep Proxy", isOn: $settings.keepLocalProxyInPhotos)
                    .tint(PhotoHubPalette.orange)
            }

            pickerRow("Format") {
                Picker("Format", selection: $settings.proxyFormatRaw) {
                    ForEach(ProxyFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt.rawValue)
                    }
                }
                .labelsHidden()
            }

            pickerRow("Size") {
                Picker("Size", selection: resolutionBinding) {
                    ForEach(ProxyResolutionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
            }

            pickerRow("Quality") {
                Picker("Quality", selection: detailBinding) {
                    ForEach(ProxyDetailPreset.allCases) { detail in
                        Text(detail.title).tag(detail)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var restoreCard: some View {
        card(title: "Restore Originals", icon: "icloud.and.arrow.down.fill") {
            HStack {
                Text("Status")
                    .font(.subheadline)
                    .foregroundColor(PhotoHubPalette.ink)
                Spacer()
                if restoreManager.isLoadingSummary && !restoreManager.hasLoadedSummary {
                    ProgressView().tint(PhotoHubPalette.orange)
                } else if restoreManager.totalCount > 0 {
                    if restoreManager.unrestoredCount > 0 {
                        let sizeStr = formatBytes(restoreManager.unrestoredBytes)
                        WarmStatPill(icon: "arrow.down.circle", text: "\(restoreManager.unrestoredCount) · ~\(sizeStr)", tint: PhotoHubPalette.orange)
                    } else {
                        WarmStatPill(icon: "checkmark.seal.fill", text: "All \(restoreManager.totalCount)", tint: PhotoHubPalette.mint)
                    }
                } else {
                    Text("0 items")
                        .font(.caption)
                        .foregroundColor(PhotoHubPalette.muted)
                }
            }

            if let phoneFree = restoreManager.deviceAvailableBytes {
                let lowSpace = restoreManager.unrestoredBytes > 0
                    && phoneFree < restoreManager.unrestoredBytes + DeviceStorageHelper.minimumHeadroomBytes
                HStack {
                    Text("Phone Free")
                        .font(.subheadline)
                        .foregroundColor(PhotoHubPalette.ink)
                    Spacer()
                    WarmStatPill(
                        icon: lowSpace ? "exclamationmark.triangle.fill" : "iphone",
                        text: formatBytes(phoneFree),
                        tint: lowSpace ? PhotoHubPalette.rose : PhotoHubPalette.mint
                    )
                }
            }

            if restoreManager.isRestoring {
                HStack(spacing: 10) {
                    SunnyMascotView(mood: .uploading, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(restoreManager.completedCount)/\(restoreManager.batchTotalCount)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundColor(PhotoHubPalette.orange)
                        if !restoreManager.currentItemName.isEmpty {
                            Text(restoreManager.currentItemName)
                                .font(.caption2)
                                .foregroundColor(PhotoHubPalette.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Stop") { restoreManager.stopRestore() }
                        .font(.caption.weight(.bold))
                        .foregroundColor(PhotoHubPalette.rose)
                }
            } else {
                Button {
                    restoreManager.requestRestoreAll(settings: settings)
                } label: {
                    HStack {
                        if restoreManager.isLoadingSummary {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "icloud.and.arrow.down.fill")
                        }
                        Text("Restore All to Photos")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PhotoHubPrimaryButtonStyle())
                .disabled(
                    settings.normalizedBaseURL == nil
                    || !settings.isSignedIn
                    || restoreManager.isLoadingSummary
                )

                if let msg = restoreManager.statusMessage {
                    HStack(spacing: 8) {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(PhotoHubPalette.muted)
                        Spacer()
                        Button {
                            restoreManager.statusMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(PhotoHubPalette.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var cacheCard: some View {
        card(title: "Local Cache", icon: "internaldrive.fill") {
            Toggle("Save to Photos", isOn: $settings.autoSaveProxiesToPhotosApp)
                .tint(PhotoHubPalette.orange)
            Toggle("App Cache", isOn: $settings.autoDownloadLocalProxies)
                .tint(PhotoHubPalette.orange)
            Toggle("Cache Videos", isOn: $settings.autoDownloadLocalVideos)
                .tint(PhotoHubPalette.orange)
                .disabled(!settings.autoDownloadLocalProxies && !settings.autoSaveProxiesToPhotosApp)

            HStack {
                Text("Cache Size")
                    .font(.subheadline)
                    .foregroundColor(PhotoHubPalette.ink)
                Spacer()
                Text(formatBytes(localProxyCacheBytes))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundColor(PhotoHubPalette.orange)
            }

            if syncManager.isSyncing {
                HStack(spacing: 8) {
                    ProgressView().tint(PhotoHubPalette.orange)
                    Text("\(syncManager.completedCount)/\(syncManager.totalCount)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundColor(PhotoHubPalette.muted)
                    Spacer()
                    Button("Stop") { syncManager.cancel() }
                        .font(.caption.weight(.bold))
                        .foregroundColor(PhotoHubPalette.rose)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        LocalProxySyncManager.shared.downloadAllMissingToPhotos(settings: settings)
                    } label: {
                        Label("Sync Proxies", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PhotoHubSoftButtonStyle())
                    .disabled(settings.normalizedBaseURL == nil)

                    Button {
                        LocalProxySyncManager.shared.cancel()
                        LocalProxyStore.shared.clearAll()
                        localProxyCacheBytes = LocalProxyStore.shared.totalStorageBytes()
                    } label: {
                        Text("Clear")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(localProxyCacheBytes > 0 ? PhotoHubPalette.rose : PhotoHubPalette.muted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(PhotoHubPalette.rose.opacity(localProxyCacheBytes > 0 ? 0.11 : 0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(localProxyCacheBytes == 0)
                }
            }
        }
    }

    private var shareOriginalCard: some View {
        card(title: "Share Original", icon: "square.and.arrow.up.fill") {
            Button {
                IncomingShareCoordinator.shared.presentInAppPhotoPicker()
            } label: {
                Label("Pick & Share Original", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PhotoHubPrimaryButtonStyle())
            .disabled(!settings.isSignedIn || settings.normalizedBaseURL == nil)

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "shortcuts://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Shortcuts", systemImage: "command")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PhotoHubSoftButtonStyle())

                Button {
                    UIPasteboard.general.string = "photohub://share-original?from=clipboard"
                    copiedShortcutURLNotice = true
                } label: {
                    Label(copiedShortcutURLNotice ? "Copied" : "Copy URL", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PhotoHubSoftButtonStyle())
            }

            VStack(alignment: .leading, spacing: 5) {
                stepChip("1", "Shortcuts → Share Sheet")
                stepChip("2", "Get Details of Photos → Name")
                stepChip("3", "photoHub → Large Video")
            }
            .padding(.top, 2)
        }
    }

    private var photosAccessCard: some View {
        card(title: "Photos Access", icon: "photo.fill") {
            HStack {
                Text("Permission")
                    .font(.subheadline)
                    .foregroundColor(PhotoHubPalette.ink)
                Spacer()
                WarmStatPill(
                    icon: photosAuthText == "Full Access" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    text: photosAuthText,
                    tint: photosAuthText == "Full Access" ? PhotoHubPalette.mint : PhotoHubPalette.warmAmber
                )
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open iOS Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PhotoHubSoftButtonStyle())
        }
    }

    private var advancedDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showAdvancedDiagnostics) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            bgManager.sendTestMorningAlert(settings: settings)
                        } label: {
                            Label("Test Alert (5s)", systemImage: "bell.badge")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PhotoHubSoftButtonStyle())

                        Button {
                            runDeleteDiagnostic()
                        } label: {
                            HStack(spacing: 6) {
                                if isTestingDelete { ProgressView().tint(PhotoHubPalette.deepOrange) }
                                Text("Test Delete")
                                    .font(.caption.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PhotoHubSoftButtonStyle())
                        .disabled(isTestingDelete)
                    }

                    if let deleteDiagResult {
                        Text(deleteDiagResult)
                            .font(.caption)
                            .foregroundColor(PhotoHubPalette.muted)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.caption.weight(.bold))
                        .foregroundColor(PhotoHubPalette.muted)
                    Text("Advanced & Diagnostics")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(PhotoHubPalette.ink)
                }
            }
            .tint(PhotoHubPalette.orange)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func pickerRow<Content: View>(_ label: String, @ViewBuilder picker: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(PhotoHubPalette.ink)
            Spacer()
            picker()
                .tint(PhotoHubPalette.orange)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func stepChip(_ num: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(num)
                .font(.caption2.weight(.heavy))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(PhotoHubPalette.orange, in: Circle())
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundColor(PhotoHubPalette.muted)
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
            settings.applyServerCapabilities(storage: info.storage, s3Enabled: info.s3Enabled)
            connectionStatus = "Connected · \(info.indexedPhotos) items"
        } catch {
            connectionStatus = "Offline"
        }
    }

    private func runDeleteDiagnostic() {
        isTestingDelete = true
        deleteDiagResult = "Testing…"
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
        if fraction >= 0.9 { return PhotoHubPalette.rose }
        if fraction >= 0.75 { return PhotoHubPalette.orange }
        return PhotoHubPalette.mint
    }
}

extension View {
    func restoreOriginalsConfirmAlert(
        prompt: Binding<RestoreConfirmPrompt?>,
        onDeleteLeftoverProxies: ((_ hashes: Set<String>) -> Void)? = nil,
        onConfirm: @escaping (_ targets: [ServerPhoto], _ prompt: RestoreConfirmPrompt) -> Void
    ) -> some View {
        alert(
            prompt.wrappedValue?.effectiveTitle ?? "Restore Originals",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            presenting: prompt.wrappedValue
        ) { current in
            if !current.unrestoredTargets.isEmpty {
                if current.hasEnoughStorageForUnrestored {
                    Button("Restore \(current.unrestoredTargets.count)") {
                        onConfirm(current.unrestoredTargets, current)
                    }
                    if current.skippedCount > 0 && current.hasEnoughStorageForAll {
                        Button("All (\(current.allTargets.count))") {
                            onConfirm(current.allTargets, current)
                        }
                    }
                }
            } else {
                if current.isRestoreAll, current.leftoverProxyCount > 0, let onDeleteLeftoverProxies {
                    Button(
                        "Delete \(current.leftoverProxyCount) Proxies",
                        role: .destructive
                    ) {
                        onDeleteLeftoverProxies(current.leftoverProxyHashes)
                    }
                }
                if current.hasEnoughStorageForAll {
                    Button("Re-download (\(current.allTargets.count))") {
                        onConfirm(current.allTargets, current)
                    }
                }
            }
            Button(
                (!current.unrestoredTargets.isEmpty && !current.hasEnoughStorageForUnrestored) ? "OK" : "Cancel",
                role: .cancel
            ) {
                prompt.wrappedValue = nil
            }
        } message: { current in
            Text(current.messageText)
        }
    }
}
