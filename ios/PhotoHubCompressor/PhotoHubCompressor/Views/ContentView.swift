import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var authService: GoogleAuthService
    @ObservedObject private var bgManager: BackgroundBackupManager
    @ObservedObject private var incomingShare: IncomingShareCoordinator
    @StateObject private var viewModel: CompressorViewModel
    @State private var selectedTab: Int = 0

    init(settings: AppSettings) {
        self.settings = settings
        self._authService = ObservedObject(wrappedValue: GoogleAuthService.shared)
        self._bgManager = ObservedObject(wrappedValue: BackgroundBackupManager.shared)
        self._incomingShare = ObservedObject(wrappedValue: IncomingShareCoordinator.shared)
        _viewModel = StateObject(wrappedValue: CompressorViewModel(settings: settings))
    }

    var body: some View {
        Group {
            if settings.isSignedIn {
                TabView(selection: $selectedTab) {
                    LibraryView(viewModel: viewModel)
                        .tabItem {
                            Label("Backup", systemImage: "photo.stack.fill")
                        }
                        .tag(0)

                    ServerGalleryView(settings: settings)
                        .tabItem {
                            Label("Cloud", systemImage: "cloud.fill")
                        }
                        .tag(1)

                    SettingsView(settings: settings)
                        .tabItem {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .tag(2)
                }
                .tint(PhotoHubPalette.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .onAppear {
                    Task {
                        await authService.refreshGatewayRouteAndStorage(settings: settings)
                    }
                    LocalProxySyncManager.shared.syncFromServerOnLaunch(settings: settings)
                    if bgManager.pendingOpenCleanupFromNotification {
                        openDeletePromptFromNotification()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .photoHubOpenCleanupPrompt)) { _ in
                    openDeletePromptFromNotification()
                }
                .onChange(of: bgManager.pendingOpenCleanupFromNotification) { pending in
                    if pending {
                        openDeletePromptFromNotification()
                    }
                }
                .sheet(isPresented: $incomingShare.showingInAppPicker) {
                    MultiPhotoPickerSheet(
                        selectionLimit: 25,
                        skipCopyIfTracked: true,
                        onPickPending: { pending in
                            incomingShare.showingInAppPicker = false
                            incomingShare.enqueuePickerSelections(pending)
                        },
                        onPickBatch: { picked in
                            incomingShare.showingInAppPicker = false
                            incomingShare.enqueuePickedResults(picked)
                        },
                        onCancel: {
                            incomingShare.showingInAppPicker = false
                        }
                    )
                }
            } else {
                GoogleSignInGateView(settings: settings, authService: authService)
            }
        }
        .onOpenURL { url in
            incomingShare.handleIncomingURL(url)
        }
        .sheet(item: $incomingShare.activeSession, onDismiss: {
            incomingShare.dismiss()
        }) { session in
            ShareOriginalOverlaySheet(
                session: session,
                settings: settings,
                coordinator: incomingShare
            )
        }
    }

    private func openDeletePromptFromNotification() {
        selectedTab = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            viewModel.handleNotificationOpenCleanup()
        }
    }
}

private struct GoogleSignInGateView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var authService: GoogleAuthService
    @State private var appeared = false

    var body: some View {
        ZStack {
            PhotoHubPalette.sunriseBackdrop.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    SunnyMascotView(
                        mood: authService.isAuthenticating ? .uploading : .happy,
                        size: 132
                    )
                    .scaleEffect(appeared ? 1.0 : 0.85)
                    .opacity(appeared ? 1.0 : 0.0)

                    Text("photoHub")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundColor(PhotoHubPalette.ink)

                    HStack(spacing: 8) {
                        WarmStatPill(icon: "icloud.and.arrow.up", text: "Backup", tint: PhotoHubPalette.orange)
                        WarmStatPill(icon: "sparkles", text: "Compress", tint: PhotoHubPalette.warmAmber)
                        WarmStatPill(icon: "checkmark.seal.fill", text: "Free", tint: PhotoHubPalette.mint)
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        Task { await authService.signInWithGoogle(settings: settings) }
                    } label: {
                        HStack(spacing: 10) {
                            if authService.isAuthenticating {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "g.circle.fill")
                                    .font(.title3)
                            }
                            Text(authService.isAuthenticating ? "Signing in…" : "Continue with Google")
                                .font(.headline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PhotoHubPrimaryButtonStyle())
                    .disabled(authService.isAuthenticating || settings.gatewayURL == nil)

                    if let errorMessage = authService.errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(PhotoHubPalette.rose)
                            .multilineTextAlignment(.center)
                    }

                    if settings.gatewayURL == nil {
                        Text("Server URL not configured")
                            .font(.caption)
                            .foregroundColor(PhotoHubPalette.orange)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                appeared = true
            }
        }
    }
}
