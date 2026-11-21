import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var authService: GoogleAuthService
    @ObservedObject private var bgManager: BackgroundBackupManager
    @StateObject private var viewModel: CompressorViewModel
    @State private var selectedTab: Int = 0

    init(settings: AppSettings) {
        self.settings = settings
        self._authService = ObservedObject(wrappedValue: GoogleAuthService.shared)
        self._bgManager = ObservedObject(wrappedValue: BackgroundBackupManager.shared)
        _viewModel = StateObject(wrappedValue: CompressorViewModel(settings: settings))
    }

    var body: some View {
        Group {
            if settings.isSignedIn {
                TabView(selection: $selectedTab) {
                    LibraryView(viewModel: viewModel)
                        .tabItem {
                            Label("Compress", systemImage: "photo.stack")
                        }
                        .tag(0)

                    ServerGalleryView(settings: settings)
                        .tabItem {
                            Label("Server", systemImage: "cloud")
                        }
                        .tag(1)

                    SettingsView(settings: settings)
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tag(2)
                }
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
            } else {
                GoogleSignInGateView(settings: settings, authService: authService)
            }
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

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                Text("photoHub")
                    .font(.largeTitle.weight(.bold))

                Text("Back up full-resolution originals safely and keep lightweight proxies in iPhone Photos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

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
                        Text(authService.isAuthenticating ? "Signing in..." : "Continue with Google")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(authService.isAuthenticating || settings.gatewayURL == nil)

                if let errorMessage = authService.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                if settings.gatewayURL == nil {
                    Text("Server gateway URL is not configured in this build.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 28)

            Spacer()

            Text("Connected server routing & storage limits are managed automatically via your Google account.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
