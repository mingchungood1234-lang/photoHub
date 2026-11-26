import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum GoogleAuthError: LocalizedError {
    case missingGatewayURL
    case cancelled
    case oauthError(String)
    case missingAuthCode

    var errorDescription: String? {
        switch self {
        case .missingGatewayURL:
            return "App build does not have PhotoHubGatewayURL configured in Info.plist."
        case .cancelled:
            return "Sign-in was cancelled."
        case .oauthError(let message):
            return message
        case .missingAuthCode:
            return "Google sign-in did not return an authorization code."
        }
    }
}

@MainActor
final class GoogleAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuthService()

    @Published private(set) var isAuthenticating: Bool = false
    @Published var errorMessage: String?

    private var activeSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
    }

    func signInWithGoogle(settings: AppSettings) async {
        guard !isAuthenticating else { return }
        guard let gatewayURL = settings.gatewayURL else {
            errorMessage = GoogleAuthError.missingGatewayURL.localizedDescription
            return
        }

        isAuthenticating = true
        errorMessage = nil
        defer {
            isAuthenticating = false
            activeSession = nil
        }

        do {
            let codeVerifier = Self.generateCodeVerifier()
            let codeChallenge = Self.makeCodeChallenge(from: codeVerifier)
            let callbackScheme = "photohub"
            let redirectUri = "\(callbackScheme)://auth/callback"

            var components = URLComponents(
                url: gatewayURL.appendingPathComponent("api/auth/google/start"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "redirect_uri", value: redirectUri),
            ]
            guard let startURL = components?.url else {
                throw GoogleAuthError.missingGatewayURL
            }

            let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: startURL,
                    callbackURLScheme: callbackScheme
                ) { url, error in
                    if let error {
                        let nsErr = error as NSError
                        if nsErr.domain == ASWebAuthenticationSessionErrorDomain,
                           nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            continuation.resume(throwing: GoogleAuthError.cancelled)
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: GoogleAuthError.missingAuthCode)
                        return
                    }
                    continuation.resume(returning: url)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.activeSession = session
                session.start()
            }

            let cbComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            if let oauthErr = cbComponents?.queryItems?.first(where: { $0.name == "error" })?.value,
               !oauthErr.isEmpty {
                throw GoogleAuthError.oauthError(oauthErr)
            }
            guard let oneTimeCode = cbComponents?.queryItems?.first(where: { $0.name == "code" })?.value,
                  !oneTimeCode.isEmpty else {
                throw GoogleAuthError.missingAuthCode
            }

            let client = PhotoHubAPIClient(settings: settings)
            let exchange = try await client.exchangeGoogleAuthCode(
                code: oneTimeCode,
                codeVerifier: codeVerifier,
                gatewayURL: gatewayURL
            )

            settings.applyGoogleSession(
                token: exchange.token,
                serverUrl: exchange.serverUrl,
                nodeId: exchange.nodeId,
                email: exchange.user.email,
                name: exchange.user.name,
                folderName: exchange.user.folderName
            )

            // Fetch storage usage/limit & S3 mode immediately from assigned node
            let nodeClient = PhotoHubAPIClient(settings: settings)
            if let info = try? await nodeClient.whoami() {
                settings.applyServerCapabilities(storage: info.storage, s3Enabled: info.s3Enabled)
            }
            LocalProxySyncManager.shared.syncFromServerOnLaunch(settings: settings)
        } catch let authErr as GoogleAuthError {
            if case .cancelled = authErr {
                errorMessage = nil
            } else {
                errorMessage = authErr.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshGatewayRouteAndStorage(settings: AppSettings) async {
        guard settings.isSignedIn, let gatewayURL = settings.gatewayURL else { return }
        let client = PhotoHubAPIClient(settings: settings)
        do {
            let resolved = try await client.resolveAssignedNode(gatewayURL: gatewayURL)
            settings.updateResolvedNode(
                serverUrl: resolved.serverUrl,
                nodeId: resolved.nodeId,
                folderName: resolved.user?.folderName,
                email: resolved.user?.email,
                name: resolved.user?.name
            )
            let info = try await PhotoHubAPIClient(settings: settings).whoami()
            settings.applyServerCapabilities(storage: info.storage, s3Enabled: info.s3Enabled)
        } catch APIClientError.httpError(401, _) {
            // Token expired or revoked on server; require clean re-authentication
            LocalProxySyncManager.shared.cancel()
            settings.signOut()
        } catch {
            // Keep existing cached session/node offline; update storage if assigned node directly reachable
            if let info = try? await PhotoHubAPIClient(settings: settings).whoami() {
                settings.applyServerCapabilities(storage: info.storage, s3Enabled: info.s3Enabled)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
                    return keyWindow
                }
            }
            if let firstWindow = scenes.first?.windows.first {
                return firstWindow
            }
            return ASPresentationAnchor()
        }
    }

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return base64URLEncode(Data(bytes))
    }

    private static func makeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
