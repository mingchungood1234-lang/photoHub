import Foundation

enum APIClientError: LocalizedError {
    case invalidServerURL
    case httpError(Int, String)
    case checksumNotConfirmed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Invalid server URL in Settings."
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

struct WhoAmIResponse: Decodable {
    let success: Bool
    let userFolder: String?
    let indexedPhotos: Int
    let s3Enabled: Bool?
}

struct ServerPhoto: Codable, Identifiable, Hashable {
    let hash: String
    let originalName: String
    let size: Int64
    let photoDate: String
    let uploadedAt: String
    let savedPath: String
    let hasProxy: Bool?
    let proxyHash: String?
    let proxySize: Int64?
    let hasVideoProxy: Bool?
    let videoProxySize: Int64?

    var id: String { hash }

    var isVideo: Bool {
        let ext = URL(fileURLWithPath: originalName).pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "3gp", "avi"].contains(ext)
    }
}

private struct ServerPhotosResponse: Decodable {
    let success: Bool
    let total: Int
    let photos: [ServerPhoto]
}

struct CheckResponse: Decodable {
    let success: Bool
    let exists: Bool
    let isMaster: Bool?
    let isProxy: Bool?
    let canReplaceWithProxy: Bool?
    let masterHash: String?
    let savedPath: String?
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

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    private let allowSelfSignedHTTPS: Bool

    init(allowSelfSignedHTTPS: Bool = false, onProgress: @escaping (Double) -> Void = { _ in }) {
        self.allowSelfSignedHTTPS = allowSelfSignedHTTPS
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
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if allowSelfSignedHTTPS,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

final class PhotoHubAPIClient {
    private let settings: AppSettings
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(settings: AppSettings) {
        self.settings = settings
    }

    private func makeSession(onProgress: @escaping (Double) -> Void = { _ in }) -> URLSession {
        let delegate = UploadProgressDelegate(
            allowSelfSignedHTTPS: settings.allowSelfSignedHTTPS,
            onProgress: onProgress
        )
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }

    private func makeURL(_ path: String) throws -> URL {
        guard let base = settings.normalizedBaseURL else {
            throw APIClientError.invalidServerURL
        }
        return base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func applyAuth(to request: inout URLRequest) {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
    }

    func checkHealth() async throws -> HealthResponse {
        let url = try makeURL("/api/health")
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    func whoami() async throws -> WhoAmIResponse {
        let url = try makeURL("/api/whoami")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(WhoAmIResponse.self, from: data)
    }

    func fetchServerPhotos(limit: Int = 200, offset: Int = 0) async throws -> [ServerPhoto] {
        var components = URLComponents(url: try makeURL("/api/photos"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components?.url else {
            throw APIClientError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(ServerPhotosResponse.self, from: data)
        return decoded.photos
    }

    func downloadPhotoPreviewData(hash: String) async throws -> Data {
        let url = try makeURL("/api/photo/\(hash)/preview")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        return data
    }

    func downloadPhotoData(hash: String) async throws -> Data {
        let url = try makeURL("/api/photo/\(hash)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        return data
    }

    func downloadMasterToTempFile(
        hash: String,
        preferredFilename: String? = nil,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        try await downloadToTempFile(
            path: "/api/photo/\(hash)",
            preferredFilename: preferredFilename,
            fallbackFilename: "photo_\(String(hash.prefix(8))).jpg",
            onProgress: onProgress
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
        fallbackFilename: String,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        let url = try makeURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let session = makeSession(onProgress: onProgress)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, response) = try await session.download(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let errData = (try? Data(contentsOf: tempURL, options: .mappedIfSafe)) ?? Data()
            try? FileManager.default.removeItem(at: tempURL)
            try validateHTTP(response: response, data: errData)
        }

        let serverSuggestedName = extractFilename(from: response)
        let candidateName = preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFilename = (candidateName?.isEmpty == false ? candidateName : nil)
            ?? serverSuggestedName
            ?? fallbackFilename
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

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(CheckResponse.self, from: data)
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

        let session = makeSession(onProgress: onProgress)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
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

        let dateStr = createdAt.map { isoFormatter.string(from: $0) } ?? ""
        presignReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "fileName": filename,
            "mimeType": mimeType,
            "createdAt": dateStr,
            "expectedHash": expectedSha256,
        ])

        let metaSession = makeSession()
        defer { metaSession.finishTasksAndInvalidate() }

        let (presignData, presignResp) = try await metaSession.data(for: presignReq)
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

        let session = makeSession(onProgress: onProgress)
        defer { session.finishTasksAndInvalidate() }

        let (putData, putResp) = try await session.upload(for: putReq, fromFile: fileURL)
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

        let (confirmData, confirmResp) = try await metaSession.data(for: confirmReq)
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
        if let videoProxyURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: videoProxyURL.path),
           let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
           fileSize > 0,
           fileSize <= 25 * 1024 * 1024,
           let videoData = try? Data(contentsOf: videoProxyURL) {
            payload["videoProxyBase64"] = videoData.base64EncodedString()
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
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
