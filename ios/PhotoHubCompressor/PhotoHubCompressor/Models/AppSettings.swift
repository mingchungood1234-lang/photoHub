import Foundation
import SwiftUI

enum UploadMode: String, CaseIterable, Identifiable {
    case directVPS = "direct_vps"
    case s3Presigned = "s3_presigned"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .directVPS: return "Direct to Server"
        case .s3Presigned: return "S3 / MinIO Pre-signed URL"
        }
    }
}

enum ProxyFormat: String, CaseIterable, Identifiable {
    case heic = "heic"
    case jpeg = "jpeg"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heic: return "HEIC (Smallest)"
        case .jpeg: return "JPEG (Universal)"
        }
    }
}

struct ServerStorageInfo: Codable, Equatable, Sendable {
    let usedBytes: Int64
    let mastersBytes: Int64?
    let proxiesBytes: Int64?
    let itemCount: Int?
    let quotaBytes: Int64?
    let remainingBytes: Int64?
    let diskTotalBytes: Int64?
    let diskFreeBytes: Int64?

    var effectiveLimitBytes: Int64? {
        if let quotaBytes, quotaBytes > 0 { return quotaBytes }
        if let diskTotalBytes, diskTotalBytes > 0 { return diskTotalBytes }
        return nil
    }

    var isFixedQuota: Bool {
        (quotaBytes ?? 0) > 0
    }

    var usageFraction: Double {
        guard let limit = effectiveLimitBytes, limit > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(limit)))
    }
}

final class AppSettings: ObservableObject {
    private enum SessionKeys {
        static let authToken = "sessionToken"
        static let assignedServerURL = "assignedServerURL"
        static let assignedNodeId = "assignedNodeId"
        static let userEmail = "userEmail"
        static let userName = "userName"
        static let userFolder = "userFolder"
        static let all = [authToken, assignedServerURL, assignedNodeId, userEmail, userName, userFolder]
    }

    // Build-time server gateway & TLS pins configured in project.yml / Info.plist / CI variables
    static let buildGatewayURLString: String = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "PhotoHubGatewayURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return raw
    }()

    static let buildPinnedCertHashes: [String] = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PhotoHubPinnedCertSHA256") as? [String] ?? []
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }()

    @AppStorage("uploadMode") var uploadModeRaw: String = UploadMode.directVPS.rawValue
    @AppStorage("proxyFormat") var proxyFormatRaw: String = ProxyFormat.heic.rawValue
    @AppStorage("proxyMaxPixelSize") var proxyMaxPixelSize: Int = 0 // 0 = Auto for all resolutions
    @AppStorage("proxyQuality") var proxyQuality: Double = 0.72
    @AppStorage("minimumOriginalSizeKB") var minimumOriginalSizeKB: Int = 500
    @AppStorage("keepLocalProxyInPhotos") var keepLocalProxyInPhotos: Bool = true
    @AppStorage("autoCompressOnOpen") var autoCompressOnOpen: Bool = false
    @AppStorage("autoDownloadLocalProxies") var autoDownloadLocalProxies: Bool = true
    @AppStorage("autoDownloadLocalVideos") var autoDownloadLocalVideos: Bool = true
    @AppStorage("autoSaveProxiesToPhotosApp") var autoSaveProxiesToPhotosApp: Bool = true
    @AppStorage("nightlyAutoBackupEnabled") var nightlyAutoBackupEnabled: Bool = true
    @AppStorage("nightlyRequiresCharging") var nightlyRequiresCharging: Bool = false
    @AppStorage("notifyWhenBackgroundUploadFinishes") var notifyWhenBackgroundUploadFinishes: Bool = true
    @AppStorage("morningReminderHour") var morningReminderHour: Int = 8
    @AppStorage("candidateSortMode") var candidateSortModeRaw: String = CandidateSortMode.largestVideosFirst.rawValue

    @Published private(set) var authToken: String
    @Published private(set) var assignedServerURLString: String
    @Published private(set) var assignedNodeId: String
    @Published private(set) var userEmail: String
    @Published private(set) var userName: String
    @Published private(set) var userFolder: String
    @Published var serverStorage: ServerStorageInfo?

    init() {
        self.authToken = KeychainStore.get(SessionKeys.authToken) ?? ""
        self.assignedServerURLString = KeychainStore.get(SessionKeys.assignedServerURL) ?? ""
        self.assignedNodeId = KeychainStore.get(SessionKeys.assignedNodeId) ?? "primary"
        self.userEmail = KeychainStore.get(SessionKeys.userEmail) ?? ""
        self.userName = KeychainStore.get(SessionKeys.userName) ?? ""
        self.userFolder = KeychainStore.get(SessionKeys.userFolder) ?? ""
    }

    var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var allowSelfSignedHTTPS: Bool {
        false
    }

    var uploadMode: UploadMode {
        get { UploadMode(rawValue: uploadModeRaw) ?? .directVPS }
        set { uploadModeRaw = newValue.rawValue }
    }

    var proxyFormat: ProxyFormat {
        get { ProxyFormat(rawValue: proxyFormatRaw) ?? .heic }
        set { proxyFormatRaw = newValue.rawValue }
    }

    var candidateSortMode: CandidateSortMode {
        get { CandidateSortMode(rawValue: candidateSortModeRaw) ?? .largestVideosFirst }
        set { candidateSortModeRaw = newValue.rawValue }
    }

    var gatewayURL: URL? {
        Self.normalizeURL(Self.buildGatewayURLString)
    }

    /// Automatic storage server endpoint assigned by the gateway after login (falls back to gateway URL).
    var normalizedBaseURL: URL? {
        Self.normalizeURL(assignedServerURLString) ?? gatewayURL
    }

    /// Stable account cache scope key (never stores the raw JWT inside filenames).
    var apiKey: String {
        if !userFolder.isEmpty { return userFolder }
        if !userEmail.isEmpty { return userEmail }
        return authToken
    }

    @MainActor
    func applyGoogleSession(
        token: String,
        serverUrl: String,
        nodeId: String?,
        email: String,
        name: String,
        folderName: String
    ) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanServer = serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanNode = (nodeId ?? "primary").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFolder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)

        KeychainStore.set(cleanToken, forKey: SessionKeys.authToken)
        KeychainStore.set(cleanServer, forKey: SessionKeys.assignedServerURL)
        KeychainStore.set(cleanNode, forKey: SessionKeys.assignedNodeId)
        KeychainStore.set(cleanEmail, forKey: SessionKeys.userEmail)
        KeychainStore.set(cleanName, forKey: SessionKeys.userName)
        KeychainStore.set(cleanFolder, forKey: SessionKeys.userFolder)

        authToken = cleanToken
        assignedServerURLString = cleanServer
        assignedNodeId = cleanNode.isEmpty ? "primary" : cleanNode
        userEmail = cleanEmail
        userName = cleanName
        userFolder = cleanFolder
    }

    @MainActor
    func updateResolvedNode(
        serverUrl: String,
        nodeId: String?,
        folderName: String?,
        email: String?,
        name: String?
    ) {
        let cleanServer = serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cleanServer.isEmpty && cleanServer != assignedServerURLString {
            KeychainStore.set(cleanServer, forKey: SessionKeys.assignedServerURL)
            assignedServerURLString = cleanServer
        }
        if let nodeId, !nodeId.isEmpty, nodeId != assignedNodeId {
            KeychainStore.set(nodeId, forKey: SessionKeys.assignedNodeId)
            assignedNodeId = nodeId
        }
        if let folderName, folderName != userFolder {
            KeychainStore.set(folderName, forKey: SessionKeys.userFolder)
            userFolder = folderName
        }
        if let email, !email.isEmpty, email != userEmail {
            KeychainStore.set(email, forKey: SessionKeys.userEmail)
            userEmail = email
        }
        if let name, !name.isEmpty, name != userName {
            KeychainStore.set(name, forKey: SessionKeys.userName)
            userName = name
        }
    }

    @MainActor
    func signOut() {
        KeychainStore.clearKeys(SessionKeys.all)
        authToken = ""
        assignedServerURLString = ""
        assignedNodeId = "primary"
        userEmail = ""
        userName = ""
        userFolder = ""
        serverStorage = nil
    }

    private static func normalizeURL(_ raw: String) -> URL? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://\(trimmed)")
    }
}
