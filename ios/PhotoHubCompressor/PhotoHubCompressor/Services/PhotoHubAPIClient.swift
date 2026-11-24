import CryptoKit
import Foundation
import Security

enum APIClientError: LocalizedError {
    case invalidServerURL
    case httpError(Int, String)
    case checksumNotConfirmed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Server connection is not configured for this build."
        case .httpError(let code, let message):
            return "Server returned HTTP \(code): \(message)"
        case .checksumNotConfirmed(let detail):
            return "Backend did not confirm master checksum: \(detail)"
        case .invalidResponse:
            return "Unexpected response from PhotoHub server."
        }
    }
}

struct HealthResponse: Decodable {
    let success: Bool
    let status: String
    let indexedPhotos: Int
    let s3Enabled: Bool?
}

struct AuthUserProfile: Decodable {
    let email: String
    let name: String
    let folderName: String
}

struct GoogleExchangeResponse: Decodable {
    let success: Bool
    let token: String
    let serverUrl: String
    let nodeId: String?
    let user: AuthUserProfile
}

struct AuthResolveUser: Decodable {
    let email: String?
    let name: String?
    let folderName: String?
}

struct AuthResolveResponse: Decodable {
    let success: Bool
    let serverUrl: String
    let nodeId: String?
    let user: AuthResolveUser?
}

struct WhoAmIResponse: Decodable {
    let success: Bool
    let userFolder: String?
    let email: String?
    let name: String?
    let nodeId: String?
    let indexedPhotos: Int
    let s3Enabled: Bool?
    let storage: ServerStorageInfo?
}

struct ServerPhoto: Codable, Identifiable, Hashable, Sendable {
    let hash: String
    let originalName: String
    let size: Int64
    let photoDate: String
    let takenAt: String?
    let uploadedAt: String
    let savedPath: String
    let hasProxy: Bool?
    let hasPreview: Bool?
    let proxyHash: String?
    let proxySize: Int64?
    let hasVideoProxy: Bool?
    let videoProxySize: Int64?
    let keepOriginalOnDevice: Bool?

    var id: String { hash }

    var isProtectedOriginal: Bool {
        keepOriginalOnDevice == true
    }

    var isVideo: Bool {
        let ext = URL(fileURLWithPath: originalName).pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "3gp", "avi"].contains(ext)
    }

    var needsProxy: Bool {
        (hasProxy != true) || (hasPreview == false)
    }

    var parsedCreationDate: Date? {
        Self.parseDate(takenAt)
            ?? Self.parseDate(photoDate)
            ?? Self.parseDayFromSavedPath(savedPath)
            ?? Self.parseDate(uploadedAt)
    }

    private static let dateParserLock = NSLock()
    private static let pathDayRegex = try? NSRegularExpression(
        pattern: #"(?:^|/)(\d{4})[-_/](\d{2})[-_/](\d{2})(?:/|$)"#
    )
    private static let isoWithFractionFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dayOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parseDayFromSavedPath(_ savedPath: String) -> Date? {
        guard let regex = pathDayRegex else { return nil }
        let norm = savedPath.replacingOccurrences(of: "\\", with: "/")
        let nsRange = NSRange(norm.startIndex..<norm.endIndex, in: norm)
        guard let match = regex.firstMatch(in: norm, range: nsRange),
              match.numberOfRanges >= 4,
              let rY = Range(match.range(at: 1), in: norm),
              let rM = Range(match.range(at: 2), in: norm),
              let rD = Range(match.range(at: 3), in: norm) else {
            return nil
        }
        return parseDate("\(norm[rY])-\(norm[rM])-\(norm[rD])")
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        dateParserLock.lock()
        defer { dateParserLock.unlock() }
        if let d = isoWithFractionFormatter.date(from: trimmed) ?? isoPlainFormatter.date(from: trimmed) {
            return d
        }
        if let day = dayOnlyFormatter.date(from: trimmed) {
            return day.addingTimeInterval(12 * 3600)
        }
        return nil
    }
}

private struct ServerPhotosResponse: Decodable {
    let success: Bool
    let total: Int
    let hasMore: Bool?
    let photos: [ServerPhoto]
}

struct CheckResponse: Decodable {
    let success: Bool
    let exists: Bool
    let isMaster: Bool?
    let isProxy: Bool?
    let hasProxy: Bool?
    let proxySize: Int64?
    let isProtectedOriginal: Bool?
    let keepOriginalOnDevice: Bool?
    let canReplaceWithProxy: Bool?
    let masterHash: String?
    let savedPath: String?
    let originalName: String?
    let size: Int64?
}

private struct BatchCheckResponse: Decodable {
    let success: Bool
    let results: [String: CheckResponse]?
}

private struct ProtectOriginalResponse: Decodable {
    let success: Bool
    let keepOriginalOnDevice: Bool?
    let photo: ServerPhoto?
}

struct DeletePhotosResult: Decodable, Sendable {
    let success: Bool
    let deleted: [String]?
    let missing: [String]?
    let freedBytes: Int64?
}

struct UploadConfirmResponse: Decodable {
    let success: Bool
    let canDelete: Bool?
    let checksumVerified: Bool?
    let canReplaceWithProxy: Bool?
    let serverSha256: String?
    let hash: String?
    let savedPath: String?
    let error: String?
}

private struct PresignResponse: Decodable {
    let success: Bool
    let alreadyExists: Bool?
    let checksumVerified: Bool?
    let canReplaceWithProxy: Bool?
    let serverSha256: String?
    let uploadUrl: String?
    let objectKey: String?
    let error: String?
}

enum TrustPinningHelper {
    private static let rsa2048SpkiHeader: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
        0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00,
    ]
    private static let rsa4096SpkiHeader: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
        0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00,
    ]
    private static let ecP256SpkiHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02,
        0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ]
    private static let ecP384SpkiHeader: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02,
        0x01, 0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
    ]

    static func evaluate(
        challenge: URLAuthenticationChallenge,
        allowSelfSignedHTTPS: Bool,
        pinnedHashes: [String],
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if allowSelfSignedHTTPS {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        guard !pinnedHashes.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let policies = [SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)]
        SecTrustSetPolicies(serverTrust, policies as CFTypeRef)
        guard SecTrustEvaluateWithError(serverTrust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let pinSet = Set(pinnedHashes)
        let certificates = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate]) ?? []
        for cert in certificates {
            let certHash = sha256Base64(SecCertificateCopyData(cert) as Data)
            if pinSet.contains(certHash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
            if let key = SecCertificateCopyKey(cert),
               let rawKeyData = SecKeyCopyExternalRepresentation(key, nil) as Data? {
                let rawHash = sha256Base64(rawKeyData)
                if pinSet.contains(rawHash) {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }
                if let spkiHeader = spkiHeader(for: key) {
                    var spkiData = Data(spkiHeader)
                    spkiData.append(rawKeyData)
                    if pinSet.contains(sha256Base64(spkiData)) {
                        completionHandler(.useCredential, URLCredential(trust: serverTrust))
                        return
                    }
                }
            }
        }

        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    private static func sha256Base64(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func spkiHeader(for key: SecKey) -> [UInt8]? {
        guard let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let keyType = attrs[kSecAttrKeyType] as? String,
              let keySize = attrs[kSecAttrKeySizeInBits] as? Int else {
            return nil
        }
        if keyType == (kSecAttrKeyTypeRSA as String) {
            if keySize == 2048 { return rsa2048SpkiHeader }
            if keySize == 4096 { return rsa4096SpkiHeader }
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            if keySize == 256 { return ecP256SpkiHeader }
            if keySize == 384 { return ecP384SpkiHeader }
        }
        return nil
    }
}

private final class SessionTrustDelegate: NSObject, URLSessionDelegate {
    let allowSelfSignedHTTPS: Bool
    let pinnedHashes: [String]

    init(allowSelfSignedHTTPS: Bool, pinnedHashes: [String]) {
        self.allowSelfSignedHTTPS = allowSelfSignedHTTPS
        self.pinnedHashes = pinnedHashes
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        TrustPinningHelper.evaluate(
            challenge: challenge,
            allowSelfSignedHTTPS: allowSelfSignedHTTPS,
            pinnedHashes: pinnedHashes,
            completionHandler: completionHandler
        )
    }
}

private final class TaskUploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    private let allowSelfSignedHTTPS: Bool
    private let pinnedHashes: [String]

    init(
        allowSelfSignedHTTPS: Bool = false,
        pinnedHashes: [String] = AppSettings.buildPinnedCertHashes,
        onProgress: @escaping (Double) -> Void
    ) {
        self.allowSelfSignedHTTPS = allowSelfSignedHTTPS
        self.pinnedHashes = pinnedHashes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1.0, max(0.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        TrustPinningHelper.evaluate(
            challenge: challenge,
            allowSelfSignedHTTPS: allowSelfSignedHTTPS,
            pinnedHashes: pinnedHashes,
            completionHandler: completionHandler
        )
    }
}

private struct GenerateProxyResponse: Decodable {
    let success: Bool
    let photo: ServerPhoto?
}

final class PhotoHubAPIClient {
    private static let sharedStandardSession: URLSession = makeSharedSession(allowSelfSigned: false)
    private static let sharedSelfSignedSession: URLSession = makeSharedSession(allowSelfSigned: true)
    private static let warmLock = NSLock()
    private static var lastWarmTimestamps: [String: Date] = [:]

    private static func makeSharedSession(allowSelfSigned: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 10
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        return URLSession(
            configuration: config,
            delegate: SessionTrustDelegate(
                allowSelfSignedHTTPS: allowSelfSigned,
                pinnedHashes: AppSettings.buildPinnedCertHashes
            ),
            delegateQueue: nil
        )
    }

    private let settings: AppSettings
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(settings: AppSettings) {
        self.settings = settings
    }

    private var pooledSession: URLSession {
        settings.allowSelfSignedHTTPS ? Self.sharedSelfSignedSession : Self.sharedStandardSession
    }

    /// Pre-establishes TCP/TLS socket cleanly before original fetches start.
    func warmConnectionIfNeeded() async {
        guard let url = try? makeURL("/api/health") else { return }
        let key = url.absoluteString
        let now = Date()
        let shouldWarm: Bool = {
            Self.warmLock.lock()
            defer { Self.warmLock.unlock() }
            if let prev = Self.lastWarmTimestamps[key], now.timeIntervalSince(prev) < 30.0 {
                return false
            }
            Self.lastWarmTimestamps[key] = now
            return true
        }()
        guard shouldWarm else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        _ = try? await pooledSession.data(for: req)
    }

    private func makeURL(_ path: String) throws -> URL {
        guard let base = settings.normalizedBaseURL else {
            throw APIClientError.invalidServerURL
        }
        return base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func applyAuth(to request: inout URLRequest) {
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    func checkHealth() async throws -> HealthResponse {
        let url = try makeURL("/api/health")
        let (data, response) = try await pooledSession.data(from: url)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    func exchangeGoogleAuthCode(
        code: String,
        codeVerifier: String,
        gatewayURL: URL
    ) async throws -> GoogleExchangeResponse {
        let url = gatewayURL.appendingPathComponent("api/auth/exchange")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "codeVerifier": codeVerifier,
        ])
        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(GoogleExchangeResponse.self, from: data)
    }

    func resolveAssignedNode(gatewayURL: URL) async throws -> AuthResolveResponse {
        let url = gatewayURL.appendingPathComponent("api/auth/resolve")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(AuthResolveResponse.self, from: data)
    }

    func whoami() async throws -> WhoAmIResponse {
        let url = try makeURL("/api/whoami")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(WhoAmIResponse.self, from: data)
    }

    func fetchServerPhotos(limit: Int = 500, offset: Int = 0, sync: Bool = false) async throws -> [ServerPhoto] {
        let page = try await fetchServerPhotosPage(limit: limit, offset: offset, sync: sync)
        return page.photos
    }

    func fetchAllServerPhotos(sync: Bool = true) async throws -> [ServerPhoto] {
        var collected: [ServerPhoto] = []
        var seenHashes = Set<String>()
        var offset = 0
        let pageSize = 500

        while true {
            let page = try await fetchServerPhotosPage(
                limit: pageSize,
                offset: offset,
                sync: sync && offset == 0
            )
            for item in page.photos {
                let key = item.hash.lowercased()
                if seenHashes.insert(key).inserted {
                    collected.append(item)
                }
            }
            if page.photos.isEmpty {
                break
            }
            offset += page.photos.count
            let serverHasMore = page.hasMore ?? (offset < page.total)
            if !serverHasMore || offset >= page.total {
                break
            }
        }
        return collected
    }

    func lookupPhotoByHashPrefix(_ rawPrefix: String) async throws -> ServerPhoto? {
        let cleanPrefix = rawPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isHexDigit }
        guard cleanPrefix.count >= 8 else { return nil }

        let page = try await fetchServerPhotosPage(limit: 50, offset: 0, sync: false, prefix: cleanPrefix)
        if let direct = page.photos.first(where: { $0.hash.lowercased().hasPrefix(cleanPrefix) }) {
            return direct
        }
        let serverHasMore = page.hasMore ?? (page.photos.count < page.total)
        guard serverHasMore else { return nil }

        // Fallback for older server instances that ignore ?prefix=.
        let all = try await fetchAllServerPhotos(sync: true)
        return all.first(where: { $0.hash.lowercased().hasPrefix(cleanPrefix) })
    }

    private func fetchServerPhotosPage(
        limit: Int,
        offset: Int,
        sync: Bool,
        prefix: String? = nil
    ) async throws -> ServerPhotosResponse {
        var components = URLComponents(url: try makeURL("/api/photos"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if sync {
            queryItems.append(URLQueryItem(name: "sync", value: "1"))
        }
        if let prefix, !prefix.isEmpty {
            queryItems.append(URLQueryItem(name: "prefix", value: prefix))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw APIClientError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(ServerPhotosResponse.self, from: data)
    }

    /// Generates a proxy on-demand: tries fast server-side compression (`POST /api/proxy/generate`) first
    /// so large masters stay on server disk; transparently falls back to iPhone-side compression if needed.
    func createAndRegisterProxy(for photo: ServerPhoto) async throws -> ServerPhoto {
        if let serverUpdated = try? await generateProxyOnServer(for: photo) {
            if let previewData = try? await downloadPhotoPreviewData(hash: serverUpdated.hash),
               !previewData.isEmpty {
                _ = LocalProxyStore.shared.cacheDownloadedPreviewData(previewData, forHash: serverUpdated.hash)
            }
            if settings.autoDownloadLocalVideos,
               serverUpdated.isVideo,
               serverUpdated.hasVideoProxy == true,
               LocalProxyStore.shared.videoProxyURLIfExists(forHash: serverUpdated.hash) == nil,
               let tempVideo = try? await downloadVideoProxyToTempFile(hash: serverUpdated.hash) {
                _ = LocalProxyStore.shared.copyVideoProxy(from: tempVideo, forHash: serverUpdated.hash)
                cleanupTempShareURL(tempVideo)
            }
            LocalProxyStore.shared.updatePhoto(
                serverUpdated,
                baseURL: settings.normalizedBaseURL,
                apiKey: settings.apiKey,
                notify: false
            )
            return serverUpdated
        }

        let masterURL = try await downloadMasterToTempFile(
            hash: photo.hash,
            preferredFilename: photo.originalName
        )
        defer { cleanupTempShareURL(masterURL) }

        let proxy: GeneratedProxy
        let previewURL: URL?
        let previewFormat: String
        let videoProxyURL: URL?

        if photo.isVideo {
            proxy = try await ProxyGenerator.createVideoProxy(
                from: masterURL,
                maxPixelSize: settings.proxyMaxPixelSize,
                quality: settings.proxyQuality
            )
            previewURL = proxy.posterFileURL
            previewFormat = "jpeg"
            videoProxyURL = proxy.fileURL
        } else {
            proxy = try ProxyGenerator.createProxy(
                from: masterURL,
                format: settings.proxyFormat,
                maxPixelSize: settings.proxyMaxPixelSize,
                quality: settings.proxyQuality
            )
            previewURL = proxy.fileURL
            previewFormat = settings.proxyFormat.rawValue
            videoProxyURL = nil
        }

        defer {
            try? FileManager.default.removeItem(at: proxy.fileURL)
            if let posterURL = proxy.posterFileURL {
                try? FileManager.default.removeItem(at: posterURL)
            }
        }
        cleanupTempShareURL(masterURL)

        try await registerProxy(
            masterHash: photo.hash,
            proxyHash: proxy.sha256,
            assetId: "",
            proxyFileURL: previewURL,
            proxyFormat: previewFormat,
            videoProxyURL: videoProxyURL
        )

        if let previewURL {
            LocalProxyStore.shared.copyPreviewFile(from: previewURL, forHash: photo.hash)
        }
        if photo.isVideo {
            LocalProxyStore.shared.copyVideoProxy(from: proxy.fileURL, forHash: photo.hash)
        }

        let posterSize: Int64? = {
            guard let previewURL,
                  let values = try? previewURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else {
                return nil
            }
            return Int64(size)
        }()

        let updated = ServerPhoto(
            hash: photo.hash,
            originalName: photo.originalName,
            size: photo.size,
            photoDate: photo.photoDate,
            takenAt: photo.takenAt,
            uploadedAt: photo.uploadedAt,
            savedPath: photo.savedPath,
            hasProxy: true,
            hasPreview: previewURL != nil,
            proxyHash: proxy.sha256,
            proxySize: photo.isVideo ? posterSize : proxy.sizeBytes,
            hasVideoProxy: photo.isVideo ? true : photo.hasVideoProxy,
            videoProxySize: photo.isVideo ? proxy.sizeBytes : photo.videoProxySize,
            keepOriginalOnDevice: photo.keepOriginalOnDevice
        )

        LocalProxyStore.shared.updatePhoto(
            updated,
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey,
            notify: false
        )
        return updated
    }

    private func generateProxyOnServer(for photo: ServerPhoto) async throws -> ServerPhoto {
        let url = try makeURL("/api/proxy/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "masterHash": photo.hash,
            "maxPixelSize": settings.proxyMaxPixelSize,
            "quality": settings.proxyQuality,
        ])

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(GenerateProxyResponse.self, from: data)
        guard decoded.success, let updated = decoded.photo else {
            throw APIClientError.invalidResponse
        }
        return updated
    }

    func downloadPhotoPreviewData(hash: String) async throws -> Data {
        let url = try makeURL("/api/photo/\(hash)/preview")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        return data
    }

    func downloadPhotoData(hash: String) async throws -> Data {
        let url = try makeURL("/api/photo/\(hash)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        return data
    }

    private enum SegmentedDownloadFallback: Error {
        case unsupported
    }

    private static let smallSingleStreamThresholdBytes: Int64 = 1_500_000
    private static let largeSequentialStreamingThresholdBytes: Int64 = 64 * 1024 * 1024
    private static let initialRangeBytes: Int64 = 1_048_576
    private static let maxExtraParallelSegments: Int = 4

    private final class DownloadProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var bytesCompleted: Int64 = 0
        private var totalBytes: Int64?
        private var lastReportTime: CFAbsoluteTime = 0
        private var lastReportedBytes: Int64 = 0
        private let onProgress: (@Sendable (Int64, Int64?) -> Void)?

        init(totalBytes: Int64?, onProgress: (@Sendable (Int64, Int64?) -> Void)?) {
            self.totalBytes = totalBytes
            self.onProgress = onProgress
        }

        func add(_ delta: Int64) {
            guard delta > 0, let onProgress else { return }
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            bytesCompleted += delta
            let current = bytesCompleted
            let total = totalBytes
            let shouldEmit = (now - lastReportTime >= 0.2)
                || (current - lastReportedBytes >= 512 * 1024)
                || (total != nil && current >= total!)
            if shouldEmit {
                lastReportTime = now
                lastReportedBytes = current
            }
            lock.unlock()
            if shouldEmit {
                onProgress(current, total)
            }
        }
    }

    private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let partURL: URL
        private let appendOffset: Int64
        private let expectedStatus206Only: Bool
        private let onProgress: (@Sendable (Int64, Int64?) -> Void)?

        private var continuation: CheckedContinuation<URLResponse, Error>?
        private var pendingResult: Result<URLResponse, Error>?
        private var fileHandle: FileHandle?
        private var httpResponse: HTTPURLResponse?
        private var errorBuffer = Data()
        private var receivedBytes: Int64
        private var totalExpectedBytes: Int64?
        private var lastProgressTime: CFAbsoluteTime = 0
        private var lastProgressBytes: Int64 = 0
        private var writeError: Error?

        init(
            partURL: URL,
            appendOffset: Int64 = 0,
            knownTotalBytes: Int64? = nil,
            expectedStatus206Only: Bool = false,
            onProgress: (@Sendable (Int64, Int64?) -> Void)?
        ) {
            self.partURL = partURL
            self.appendOffset = appendOffset
            self.receivedBytes = appendOffset
            self.totalExpectedBytes = knownTotalBytes
            self.expectedStatus206Only = expectedStatus206Only
            self.onProgress = onProgress
        }

        func attachContinuation(_ cont: CheckedContinuation<URLResponse, Error>) {
            lock.lock()
            if let ready = pendingResult {
                pendingResult = nil
                lock.unlock()
                cont.resume(with: ready)
                return
            }
            self.continuation = cont
            lock.unlock()
        }

        func failWithCancellation(_ error: Error) {
            closeHandle()
            resumeOnce(.failure(error))
        }

        private func closeHandle() {
            lock.lock()
            let handle = fileHandle
            fileHandle = nil
            lock.unlock()
            try? handle?.close()
        }

        private func resumeOnce(_ result: Result<URLResponse, Error>) {
            lock.lock()
            if let cont = continuation {
                continuation = nil
                lock.unlock()
                cont.resume(with: result)
                return
            }
            if pendingResult == nil {
                pendingResult = result
            }
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                resumeOnce(.failure(APIClientError.invalidResponse))
                completionHandler(.cancel)
                return
            }

            lock.lock()
            httpResponse = http
            if totalExpectedBytes == nil && response.expectedContentLength > 0 {
                totalExpectedBytes = appendOffset + response.expectedContentLength
            }
            lock.unlock()

            if expectedStatus206Only && http.statusCode != 206 {
                resumeOnce(.failure(SegmentedDownloadFallback.unsupported))
                completionHandler(.cancel)
                return
            }

            if !(200...299).contains(http.statusCode) {
                completionHandler(.allow)
                return
            }

            do {
                let fm = FileManager.default
                if appendOffset == 0 {
                    try fm.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: partURL)
                    guard fm.createFile(atPath: partURL.path, contents: nil) else {
                        throw APIClientError.invalidResponse
                    }
                }
                let handle = try FileHandle(forUpdating: partURL)
                if appendOffset > 0 {
                    try handle.seek(toOffset: UInt64(appendOffset))
                }
                lock.lock()
                fileHandle = handle
                lock.unlock()
                completionHandler(.allow)
            } catch {
                lock.lock()
                writeError = error
                lock.unlock()
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let handle = fileHandle
            let http = httpResponse
            lock.unlock()

            guard let http else { return }
            if !(200...299).contains(http.statusCode) {
                lock.lock()
                if errorBuffer.count < 65_536 {
                    errorBuffer.append(data.prefix(65_536 - errorBuffer.count))
                }
                lock.unlock()
                return
            }

            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                let now = CFAbsoluteTimeGetCurrent()
                lock.lock()
                receivedBytes += Int64(data.count)
                let current = receivedBytes
                let total = totalExpectedBytes
                let shouldEmit = (now - lastProgressTime >= 0.2) || (current - lastProgressBytes >= 512 * 1024)
                if shouldEmit {
                    lastProgressTime = now
                    lastProgressBytes = current
                }
                lock.unlock()
                if shouldEmit {
                    onProgress?(current, total)
                }
            } catch {
                lock.lock()
                writeError = error
                lock.unlock()
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            closeHandle()

            lock.lock()
            let savedWriteErr = writeError
            let http = httpResponse
            let errBuf = errorBuffer
            let finalBytes = receivedBytes
            let total = totalExpectedBytes
            lock.unlock()

            if let savedWriteErr {
                resumeOnce(.failure(savedWriteErr))
                return
            }
            if let error {
                resumeOnce(.failure(error))
                return
            }
            guard let http else {
                resumeOnce(.failure(APIClientError.invalidResponse))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = (try? JSONSerialization.jsonObject(with: errBuf) as? [String: Any])?["error"] as? String
                    ?? String(data: errBuf, encoding: .utf8)
                    ?? "Unknown error"
                resumeOnce(.failure(APIClientError.httpError(http.statusCode, msg)))
                return
            }
            onProgress?(finalBytes, total ?? finalBytes)
            resumeOnce(.success(http))
        }
    }

    func downloadMasterToTempFile(
        hash: String,
        preferredFilename: String? = nil,
        expectedSizeBytes: Int64? = nil,
        isVideo: Bool = false,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let shareDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photohub_share_\(UUID().uuidString.prefix(8))", isDirectory: true)
        return try await downloadMasterToDirectory(
            hash: hash,
            destinationDir: shareDir,
            preferredFilename: preferredFilename,
            expectedSizeBytes: expectedSizeBytes,
            isVideo: isVideo,
            onProgress: onProgress
        )
    }

    func downloadMasterToDirectory(
        hash: String,
        destinationDir: URL,
        preferredFilename: String? = nil,
        expectedSizeBytes: Int64? = nil,
        isVideo: Bool = false,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let path = "/api/photo/\(hash)"
        let inferredFallback = isVideo
            ? "video_\(String(hash.prefix(8))).mp4"
            : "photo_\(String(hash.prefix(8))).jpg"

        if let expectedSizeBytes, expectedSizeBytes > 0 {
            if expectedSizeBytes < Self.smallSingleStreamThresholdBytes
                || expectedSizeBytes >= Self.largeSequentialStreamingThresholdBytes {
                return try await downloadToDirectory(
                    path: path,
                    destinationDir: destinationDir,
                    preferredFilename: preferredFilename,
                    fallbackFilename: inferredFallback,
                    expectedSizeBytes: expectedSizeBytes,
                    onProgress: onProgress
                )
            }
        }

        do {
            return try await downloadWithParallelRanges(
                path: path,
                destinationDir: destinationDir,
                preferredFilename: preferredFilename,
                fallbackFilename: inferredFallback,
                onProgress: onProgress
            )
        } catch SegmentedDownloadFallback.unsupported {
            return try await downloadToDirectory(
                path: path,
                destinationDir: destinationDir,
                preferredFilename: preferredFilename,
                fallbackFilename: inferredFallback,
                expectedSizeBytes: expectedSizeBytes,
                onProgress: onProgress
            )
        }
    }

    func downloadVideoProxyToTempFile(hash: String) async throws -> URL {
        let shareDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photohub_share_\(UUID().uuidString.prefix(8))", isDirectory: true)
        return try await downloadToDirectory(
            path: "/api/photo/\(hash)/video-proxy",
            destinationDir: shareDir,
            preferredFilename: "\(String(hash.prefix(16))).mp4",
            fallbackFilename: "\(String(hash.prefix(16))).mp4"
        )
    }

    private func streamRequest(
        _ request: URLRequest,
        toPartURL partURL: URL,
        appendOffset: Int64 = 0,
        knownTotalBytes: Int64? = nil,
        expectedStatus206Only: Bool = false,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URLResponse {
        let delegate = StreamingDownloadDelegate(
            partURL: partURL,
            appendOffset: appendOffset,
            knownTotalBytes: knownTotalBytes,
            expectedStatus206Only: expectedStatus206Only,
            onProgress: onProgress
        )
        let task = pooledSession.dataTask(with: request)
        task.delegate = delegate

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attachContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
            delegate.failWithCancellation(CancellationError())
        }
    }

    private func downloadWithParallelRanges(
        path: String,
        destinationDir: URL,
        preferredFilename: String?,
        fallbackFilename: String,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let url = try makeURL(path)
        var initialReq = URLRequest(url: url)
        initialReq.httpMethod = "GET"
        applyAuth(to: &initialReq)
        initialReq.setValue("bytes=0-\(Self.initialRangeBytes - 1)", forHTTPHeaderField: "Range")

        let (initialTempURL, response) = try await pooledSession.download(for: initialReq)
        var cleanupInitial = true
        defer {
            if cleanupInitial {
                try? FileManager.default.removeItem(at: initialTempURL)
            }
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 416 {
                throw SegmentedDownloadFallback.unsupported
            }
            if !(200...299).contains(http.statusCode) {
                let errData = (try? Data(contentsOf: initialTempURL, options: .mappedIfSafe)) ?? Data()
                try validateHTTP(response: response, data: errData)
            }
        }

        let destFilename = resolveDestinationFilename(
            response: response,
            preferredFilename: preferredFilename,
            fallbackFilename: fallbackFilename
        )
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let destURL = destinationDir.appendingPathComponent(destFilename)

        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        let rangeInfo = (http.statusCode == 206)
            ? parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
            : nil

        // If server sent full 200 OK or the whole file fit inside the initial 1 MB segment, move directly.
        if rangeInfo == nil || rangeInfo!.start != 0 || rangeInfo!.end + 1 >= rangeInfo!.total {
            if http.statusCode != 200 && rangeInfo == nil {
                throw SegmentedDownloadFallback.unsupported
            }
            try? FileManager.default.removeItem(at: destURL)
            cleanupInitial = false
            try FileManager.default.moveItem(at: initialTempURL, to: destURL)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
               let sz = (attrs[.size] as? NSNumber)?.int64Value {
                onProgress?(sz, sz)
            }
            return destURL
        }

        let parsedRange = rangeInfo!
        let totalSize = parsedRange.total

        let partURL = destinationDir.appendingPathComponent(".part_\(UUID().uuidString.prefix(8))")
        try? FileManager.default.removeItem(at: partURL)
        defer {
            try? FileManager.default.removeItem(at: partURL)
        }

        let resolvedURL = http.url ?? url
        let sameHost = (resolvedURL.host?.lowercased() == url.host?.lowercased())
        let bearerToken = sameHost ? settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        // If Content-Range reveals a huge file (>= 64 MB), switch immediately to zero-duplicate sequential streaming
        // starting right after the initial 1 MB segment we already have (eliminates 2x disk usage & HDD seek thrashing).
        if totalSize >= Self.largeSequentialStreamingThresholdBytes {
            try FileManager.default.moveItem(at: initialTempURL, to: partURL)
            cleanupInitial = false
            let nextStart = parsedRange.end + 1
            onProgress?(nextStart, totalSize)

            var tailReq = URLRequest(url: resolvedURL)
            tailReq.httpMethod = "GET"
            tailReq.setValue("bytes=\(nextStart)-\(totalSize - 1)", forHTTPHeaderField: "Range")
            if !bearerToken.isEmpty {
                tailReq.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }

            _ = try await streamRequest(
                tailReq,
                toPartURL: partURL,
                appendOffset: nextStart,
                knownTotalBytes: totalSize,
                expectedStatus206Only: true,
                onProgress: onProgress
            )

            let finalAttrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
            let writtenTotal = (finalAttrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard writtenTotal == totalSize else {
                throw SegmentedDownloadFallback.unsupported
            }

            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: partURL, to: destURL)
            return destURL
        }

        let maxSegs = totalSize >= 32 * 1024 * 1024 ? 2 : Self.maxExtraParallelSegments
        let remainingRanges = Self.buildRemainingRanges(
            startOffset: parsedRange.end + 1,
            totalSize: totalSize,
            maxSegments: maxSegs
        )

        let fd = open(partURL.path, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw SegmentedDownloadFallback.unsupported
        }
        var fdClosed = false
        defer {
            if !fdClosed {
                close(fd)
            }
        }

        if ftruncate(fd, off_t(totalSize)) != 0 {
            throw SegmentedDownloadFallback.unsupported
        }

        let progressTracker = DownloadProgressTracker(totalBytes: totalSize, onProgress: onProgress)
        let expectedInitialBytes = parsedRange.end - parsedRange.start + 1
        let wroteInitial = try Self.streamFile(initialTempURL, toDescriptor: fd, atOffset: 0)
        if wroteInitial != expectedInitialBytes {
            throw SegmentedDownloadFallback.unsupported
        }
        progressTracker.add(wroteInitial)

        let session = pooledSession

        try await withThrowingTaskGroup(of: Void.self) { group in
            for segRange in remainingRanges {
                group.addTask {
                    try await Self.downloadRangeSegment(
                        session: session,
                        targetURL: resolvedURL,
                        bearerToken: bearerToken,
                        range: segRange,
                        fd: fd,
                        progressTracker: progressTracker
                    )
                }
            }
            try await group.waitForAll()
        }

        close(fd)
        fdClosed = true

        let finalAttrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
        let writtenTotal = (finalAttrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard writtenTotal == totalSize else {
            throw SegmentedDownloadFallback.unsupported
        }

        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: partURL, to: destURL)
        onProgress?(totalSize, totalSize)
        return destURL
    }

    private static func downloadRangeSegment(
        session: URLSession,
        targetURL: URL,
        bearerToken: String,
        range: ClosedRange<Int64>,
        fd: Int32,
        progressTracker: DownloadProgressTracker
    ) async throws {
        var req = URLRequest(url: targetURL)
        req.httpMethod = "GET"
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        if !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (segTempURL, response) = try await session.download(for: req)
        defer {
            try? FileManager.default.removeItem(at: segTempURL)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SegmentedDownloadFallback.unsupported
        }
        if http.statusCode == 401 {
            throw APIClientError.httpError(401, "Session expired")
        }
        guard http.statusCode == 206 else {
            throw SegmentedDownloadFallback.unsupported
        }

        let expectedLen = (range.upperBound - range.lowerBound) + 1
        let written = try streamFile(segTempURL, toDescriptor: fd, atOffset: range.lowerBound)
        guard written == expectedLen else {
            throw SegmentedDownloadFallback.unsupported
        }
        progressTracker.add(written)
    }

    private static func streamFile(_ fileURL: URL, toDescriptor fd: Int32, atOffset offset: Int64) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var cursor = offset
        var totalWritten: Int64 = 0
        let chunkSize = 256 * 1024

        while true {
            var shouldBreak = false
            try autoreleasepool {
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    shouldBreak = true
                    return
                }
                try chunk.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    var sent = 0
                    let count = rawBuf.count
                    while sent < count {
                        let wrote = pwrite(
                            fd,
                            base.advanced(by: sent),
                            count - sent,
                            off_t(cursor + Int64(sent))
                        )
                        if wrote < 0 {
                            if errno == EINTR { continue }
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                        sent += wrote
                    }
                }
                let len = Int64(chunk.count)
                cursor += len
                totalWritten += len
            }
            if shouldBreak { break }
        }
        return totalWritten
    }

    private func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = trimmed.dropFirst(6)
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start, total > end else {
            return nil
        }
        return (start, end, total)
    }

    private static func buildRemainingRanges(
        startOffset: Int64,
        totalSize: Int64,
        maxSegments: Int
    ) -> [ClosedRange<Int64>] {
        let remaining = totalSize - startOffset
        guard remaining > 0, maxSegments > 0 else { return [] }
        let minSegmentBytes: Int64 = 1_048_576
        let count = min(maxSegments, max(1, Int(remaining / minSegmentBytes)))
        if count <= 1 {
            return [startOffset...(totalSize - 1)]
        }
        let step = (remaining + Int64(count) - 1) / Int64(count)
        var ranges: [ClosedRange<Int64>] = []
        ranges.reserveCapacity(count)
        var cursor = startOffset
        while cursor < totalSize {
            let end = min(totalSize - 1, cursor + step - 1)
            ranges.append(cursor...end)
            cursor = end + 1
        }
        return ranges
    }

    private func downloadToDirectory(
        path: String,
        destinationDir: URL,
        preferredFilename: String?,
        fallbackFilename: String,
        expectedSizeBytes: Int64? = nil,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let url = try makeURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let partURL = destinationDir.appendingPathComponent(".stream_\(UUID().uuidString.prefix(8))")
        defer {
            try? FileManager.default.removeItem(at: partURL)
        }

        let response = try await streamRequest(
            request,
            toPartURL: partURL,
            appendOffset: 0,
            knownTotalBytes: expectedSizeBytes.flatMap { $0 > 0 ? $0 : nil },
            expectedStatus206Only: false,
            onProgress: onProgress
        )

        let destFilename = resolveDestinationFilename(
            response: response,
            preferredFilename: preferredFilename,
            fallbackFilename: fallbackFilename
        )
        let destURL = destinationDir.appendingPathComponent(destFilename)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: partURL, to: destURL)
        return destURL
    }

    private func resolveDestinationFilename(
        response: URLResponse,
        preferredFilename: String?,
        fallbackFilename: String
    ) -> String {
        let serverSuggestedName = extractFilename(from: response)
        let nonEmptyPreferred: String? = {
            guard let trimmed = preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }()
        let preferredHasExt = nonEmptyPreferred.map { !URL(fileURLWithPath: $0).pathExtension.isEmpty } ?? false
        let mimeFallback = inferFilenameFromMime(response, fallback: fallbackFilename)
        let rawFilename: String
        if let nonEmptyPreferred, preferredHasExt {
            rawFilename = nonEmptyPreferred
        } else if let serverSuggestedName, !URL(fileURLWithPath: serverSuggestedName).pathExtension.isEmpty {
            rawFilename = serverSuggestedName
        } else {
            rawFilename = mimeFallback
        }
        let safeFilename = URL(fileURLWithPath: rawFilename).lastPathComponent
        return safeFilename.isEmpty ? mimeFallback : safeFilename
    }

    private func inferFilenameFromMime(_ response: URLResponse, fallback: String) -> String {
        guard let mime = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return fallback
        }
        let stem = URL(fileURLWithPath: fallback).deletingPathExtension().lastPathComponent
        switch mime {
        case "video/mp4": return "\(stem).mp4"
        case "video/quicktime": return "\(stem).mov"
        case "video/x-m4v": return "\(stem).m4v"
        case "video/3gpp": return "\(stem).3gp"
        case "image/heic": return "\(stem).heic"
        case "image/png": return "\(stem).png"
        case "image/webp": return "\(stem).webp"
        case "image/jpeg": return "\(stem).jpg"
        default: return fallback
        }
    }

    private func extractFilename(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        if let utf8Range = disposition.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            var val = String(disposition[utf8Range.upperBound...])
            if let semi = val.firstIndex(of: ";") {
                val = String(val[..<semi])
            }
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return val.removingPercentEncoding ?? val
        }
        guard let range = disposition.range(of: "filename=", options: .caseInsensitive) else {
            return nil
        }
        var value = String(disposition[range.upperBound...])
        if let semi = value.firstIndex(of: ";") {
            value = String(value[..<semi])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return value.removingPercentEncoding ?? value
    }

    func checkHash(_ sha256: String) async throws -> CheckResponse {
        let url = try makeURL("/api/check/\(sha256)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(CheckResponse.self, from: data)
    }

    func checkHashesBatch(_ hashes: [String]) async throws -> [String: CheckResponse] {
        var seen = Set<String>()
        let cleaned: [String] = hashes.compactMap { raw in
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty, seen.insert(norm).inserted else { return nil }
            return norm
        }
        guard !cleaned.isEmpty else { return [:] }

        var merged: [String: CheckResponse] = [:]
        var idx = 0
        while idx < cleaned.count {
            let end = min(cleaned.count, idx + 500)
            let chunk = Array(cleaned[idx..<end])
            idx = end

            let url = try makeURL("/api/check/batch")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(to: &request)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["hashes": chunk])

            let (data, response) = try await pooledSession.data(for: request)
            try validateHTTP(response: response, data: data)
            let decoded = try JSONDecoder().decode(BatchCheckResponse.self, from: data)
            if let results = decoded.results {
                for (hashKey, checkItem) in results {
                    merged[hashKey.lowercased()] = checkItem
                }
            }
        }
        return merged
    }

    func setOriginalProtected(masterHash: String, protected: Bool) async throws -> ServerPhoto {
        let url = try makeURL("/api/photo/\(masterHash)/protect-original")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "keepOriginalOnDevice": protected,
        ])

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(ProtectOriginalResponse.self, from: data)
        guard decoded.success, let updated = decoded.photo else {
            throw APIClientError.invalidResponse
        }
        LocalProxyStore.shared.updatePhoto(
            updated,
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey,
            notify: true
        )
        return updated
    }

    func deleteServerPhoto(hash: String) async throws {
        let cleanHash = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHash.isEmpty else {
            throw APIClientError.invalidResponse
        }
        let url = try makeURL("/api/photo/\(cleanHash)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)

        LocalProxyStore.shared.removePhoto(
            hash: cleanHash,
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey,
            notify: true
        )
        LocalProxyTracker.shared.clearRestoredProtection(masterHash: cleanHash)
        OriginalDownloadCache.shared.removeCachedOriginals(hashes: [cleanHash])
    }

    func deleteServerPhotosBatch(hashes: [String]) async throws -> DeletePhotosResult {
        var seen = Set<String>()
        let cleaned = hashes.compactMap { raw -> String? in
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty, seen.insert(norm).inserted else { return nil }
            return norm
        }
        guard !cleaned.isEmpty else {
            return DeletePhotosResult(success: true, deleted: [], missing: [], freedBytes: 0)
        }

        var allDeleted: [String] = []
        var allMissing: [String] = []
        var totalFreed: Int64 = 0
        var anyFailed = false

        var idx = 0
        while idx < cleaned.count {
            let end = min(cleaned.count, idx + 200)
            let chunk = Array(cleaned[idx..<end])
            idx = end

            let url = try makeURL("/api/photos/delete")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(to: &request)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["hashes": chunk])

            let (data, response) = try await pooledSession.data(for: request)
            try validateHTTP(response: response, data: data)
            let decoded = try JSONDecoder().decode(DeletePhotosResult.self, from: data)
            if !decoded.success {
                anyFailed = true
            }
            if let deleted = decoded.deleted {
                allDeleted.append(contentsOf: deleted)
            }
            if let missing = decoded.missing {
                allMissing.append(contentsOf: missing)
            }
            totalFreed += decoded.freedBytes ?? 0
        }

        let toEvict = allDeleted + allMissing
        if !toEvict.isEmpty {
            LocalProxyStore.shared.removePhotos(
                hashes: toEvict,
                baseURL: settings.normalizedBaseURL,
                apiKey: settings.apiKey,
                notify: true
            )
            for h in toEvict {
                LocalProxyTracker.shared.clearRestoredProtection(masterHash: h)
            }
            OriginalDownloadCache.shared.removeCachedOriginals(hashes: toEvict)
        }

        return DeletePhotosResult(
            success: !anyFailed,
            deleted: allDeleted,
            missing: allMissing,
            freedBytes: totalFreed
        )
    }

    func uploadMasterDirect(
        fileURL: URL,
        filename: String,
        mimeType: String,
        createdAt: Date?,
        expectedSha256: String,
        onProgress: @escaping (Double) -> Void
    ) async throws -> UploadConfirmResponse {
        let url = try makeURL("/api/upload")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        applyAuth(to: &request)

        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename,
            forHTTPHeaderField: "X-File-Name"
        )
        request.setValue(expectedSha256, forHTTPHeaderField: "X-File-Sha256")
        request.setValue("strict", forHTTPHeaderField: "X-Verify-Checksum")
        if let createdAt {
            request.setValue(isoFormatter.string(from: createdAt), forHTTPHeaderField: "X-Photo-Date")
        }

        let progressDelegate = TaskUploadProgressDelegate(
            allowSelfSignedHTTPS: settings.allowSelfSignedHTTPS,
            onProgress: onProgress
        )
        let (data, response) = try await pooledSession.upload(for: request, fromFile: fileURL, delegate: progressDelegate)
        try validateHTTP(response: response, data: data)

        let decoded = try JSONDecoder().decode(UploadConfirmResponse.self, from: data)
        try ensureChecksumConfirmed(decoded, expectedSha256: expectedSha256)
        return decoded
    }

    func uploadMasterPresigned(
        fileURL: URL,
        filename: String,
        mimeType: String,
        createdAt: Date?,
        expectedSha256: String,
        onProgress: @escaping (Double) -> Void
    ) async throws -> UploadConfirmResponse {
        // 1. Request pre-signed PUT URL
        let presignURL = try makeURL("/api/upload/presign")
        var presignReq = URLRequest(url: presignURL)
        presignReq.httpMethod = "POST"
        presignReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &presignReq)

        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let dateStr = createdAt.map { isoFormatter.string(from: $0) } ?? ""
        presignReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "fileName": filename,
            "mimeType": mimeType,
            "createdAt": dateStr,
            "expectedHash": expectedSha256,
            "fileSize": fileSize,
        ])

        let (presignData, presignResp) = try await pooledSession.data(for: presignReq)
        try validateHTTP(response: presignResp, data: presignData)
        let presign = try JSONDecoder().decode(PresignResponse.self, from: presignData)

        if presign.alreadyExists == true {
            let existing = UploadConfirmResponse(
                success: true,
                canDelete: true,
                checksumVerified: presign.checksumVerified,
                canReplaceWithProxy: presign.canReplaceWithProxy,
                serverSha256: presign.serverSha256,
                hash: presign.serverSha256,
                savedPath: nil,
                error: nil
            )
            try ensureChecksumConfirmed(existing, expectedSha256: expectedSha256)
            return existing
        }

        guard let uploadUrlStr = presign.uploadUrl,
              let putURL = URL(string: uploadUrlStr),
              let objectKey = presign.objectKey else {
            throw APIClientError.invalidResponse
        }

        // 2. Upload directly to S3/MinIO pre-signed URL
        var putReq = URLRequest(url: putURL)
        putReq.httpMethod = "PUT"
        putReq.timeoutInterval = 300

        let progressDelegate = TaskUploadProgressDelegate(
            allowSelfSignedHTTPS: settings.allowSelfSignedHTTPS,
            onProgress: onProgress
        )
        let (putData, putResp) = try await pooledSession.upload(for: putReq, fromFile: fileURL, delegate: progressDelegate)
        try validateHTTP(response: putResp, data: putData)

        // 3. Ask backend to verify checksum of uploaded S3 object
        let confirmURL = try makeURL("/api/upload/confirm")
        var confirmReq = URLRequest(url: confirmURL)
        confirmReq.httpMethod = "POST"
        confirmReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &confirmReq)
        confirmReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "objectKey": objectKey,
            "expectedHash": expectedSha256,
            "fileName": filename,
            "createdAt": dateStr,
        ])

        let (confirmData, confirmResp) = try await pooledSession.data(for: confirmReq)
        try validateHTTP(response: confirmResp, data: confirmData)
        let confirmed = try JSONDecoder().decode(UploadConfirmResponse.self, from: confirmData)
        try ensureChecksumConfirmed(confirmed, expectedSha256: expectedSha256)
        return confirmed
    }

    func registerProxy(
        masterHash: String,
        proxyHash: String,
        assetId: String,
        proxyFileURL: URL? = nil,
        proxyFormat: String = "heic",
        videoProxyURL: URL? = nil
    ) async throws {
        let url = try makeURL("/api/proxy/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        var payload: [String: Any] = [
            "masterHash": masterHash,
            "proxyHash": proxyHash,
            "assetId": assetId,
            "proxyFormat": proxyFormat,
        ]
        if let proxyFileURL, let data = try? Data(contentsOf: proxyFileURL) {
            payload["proxyBase64"] = data.base64EncodedString()
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await pooledSession.data(for: request)
        try validateHTTP(response: response, data: data)

        // Stream raw binary MP4 proxy from disk directly (avoids ~33% base64 JSON bloat & 25MB limit).
        if let videoProxyURL {
            do {
                try await uploadVideoProxyBinary(
                    masterHash: masterHash,
                    proxyHash: proxyHash,
                    assetId: assetId,
                    videoProxyURL: videoProxyURL
                )
            } catch APIClientError.httpError(404, _) {
                // Backward-compatible fallback for older backends without POST /api/proxy/:masterHash/video
                if let attrs = try? FileManager.default.attributesOfItem(atPath: videoProxyURL.path),
                   let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
                   fileSize > 0,
                   fileSize <= 25 * 1024 * 1024,
                   let videoData = try? Data(contentsOf: videoProxyURL) {
                    payload["videoProxyBase64"] = videoData.base64EncodedString()
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    let (fallbackData, fallbackResp) = try await pooledSession.data(for: request)
                    try validateHTTP(response: fallbackResp, data: fallbackData)
                }
            }
        }
    }

    private func uploadVideoProxyBinary(
        masterHash: String,
        proxyHash: String,
        assetId: String,
        videoProxyURL: URL
    ) async throws {
        let url = try makeURL("/api/proxy/\(masterHash)/video")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(proxyHash, forHTTPHeaderField: "X-Proxy-Hash")
        if !assetId.isEmpty {
            request.setValue(assetId, forHTTPHeaderField: "X-Asset-Id")
        }
        applyAuth(to: &request)

        let (data, response) = try await pooledSession.upload(for: request, fromFile: videoProxyURL)
        try validateHTTP(response: response, data: data)
    }

    private struct ServerErrorPayload: Decodable {
        let error: String?
        let message: String?
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(ServerErrorPayload.self, from: data)
            let msg = payload?.error
                ?? payload?.message
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw APIClientError.httpError(http.statusCode, msg)
        }
    }

    private func ensureChecksumConfirmed(_ result: UploadConfirmResponse, expectedSha256: String) throws {
        let confirmedHash = (result.serverSha256 ?? result.hash)?.lowercased()
        let verifiedFlag = (result.checksumVerified == true) || (result.canDelete == true)
        guard result.success,
              verifiedFlag,
              let serverHash = confirmedHash,
              serverHash == expectedSha256.lowercased() else {
            let detail = result.error ?? "Server hash (\(confirmedHash ?? "nil")) did not match local master (\(expectedSha256.prefix(12))...)"
            throw APIClientError.checksumNotConfirmed(detail)
        }
    }
}
