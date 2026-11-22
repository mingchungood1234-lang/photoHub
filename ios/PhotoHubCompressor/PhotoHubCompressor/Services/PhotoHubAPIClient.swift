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

    private static func makeSharedSession(allowSelfSigned: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
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

    private func fetchServerPhotosPage(limit: Int, offset: Int, sync: Bool) async throws -> ServerPhotosResponse {
        var components = URLComponents(url: try makeURL("/api/photos"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if sync {
            queryItems.append(URLQueryItem(name: "sync", value: "1"))
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
            proxy = try await ProxyGenerator.createVideoProxy(from: masterURL)
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

    func downloadMasterToTempFile(
        hash: String,
        preferredFilename: String? = nil
    ) async throws -> URL {
        try await downloadToTempFile(
            path: "/api/photo/\(hash)",
            preferredFilename: preferredFilename,
            fallbackFilename: "photo_\(String(hash.prefix(8))).jpg"
        )
    }

    func downloadVideoProxyToTempFile(hash: String) async throws -> URL {
        try await downloadToTempFile(
            path: "/api/photo/\(hash)/video-proxy",
            preferredFilename: "\(String(hash.prefix(16))).mp4",
            fallbackFilename: "\(String(hash.prefix(16))).mp4"
        )
    }

    private func downloadToTempFile(
        path: String,
        preferredFilename: String?,
        fallbackFilename: String
    ) async throws -> URL {
        let url = try makeURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (tempURL, response) = try await pooledSession.download(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let errData = (try? Data(contentsOf: tempURL, options: .mappedIfSafe)) ?? Data()
            try? FileManager.default.removeItem(at: tempURL)
            try validateHTTP(response: response, data: errData)
        }

        let serverSuggestedName = extractFilename(from: response)
        let nonEmptyPreferred: String? = {
            guard let trimmed = preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }()
        let rawFilename = nonEmptyPreferred ?? serverSuggestedName ?? fallbackFilename
        let safeFilename = URL(fileURLWithPath: rawFilename).lastPathComponent
        let destFilename = safeFilename.isEmpty ? fallbackFilename : safeFilename

        let shareDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photohub_share_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        let destURL = shareDir.appendingPathComponent(destFilename)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    private func extractFilename(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        guard let range = disposition.range(of: "filename=") else {
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
        request.timeoutInterval = 300
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
        request.timeoutInterval = 300
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
