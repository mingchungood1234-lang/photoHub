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

struct ServerPhoto: Decodable, Identifiable, Hashable {
    let hash: String
    let originalName: String
    let size: Int64
    let photoDate: String
    let uploadedAt: String
    let savedPath: String
    let hasProxy: Bool?
    let proxyHash: String?

    var id: String { hash }
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

    init(onProgress: @escaping (Double) -> Void) {
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
        let (data, response) = try await URLSession.shared.data(from: url)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
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

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(ServerPhotosResponse.self, from: data)
        return decoded.photos
    }

    func downloadPhotoData(hash: String) async throws -> Data {
        let url = try makeURL("/api/photo/\(hash)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
        return data
    }

    func checkHash(_ sha256: String) async throws -> CheckResponse {
        let url = try makeURL("/api/check/\(sha256)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
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

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
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

        let (presignData, presignResp) = try await URLSession.shared.data(for: presignReq)
        try validateHTTP(response: presignResp, data: presignData)
        let presign = try JSONDecoder().decode(PresignResponse.self, from: presignData)

        if presign.alreadyExists == true {
            let existing = UploadConfirmResponse(
                success: true,
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

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
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

        let (confirmData, confirmResp) = try await URLSession.shared.data(for: confirmReq)
        try validateHTTP(response: confirmResp, data: confirmData)
        let confirmed = try JSONDecoder().decode(UploadConfirmResponse.self, from: confirmData)
        try ensureChecksumConfirmed(confirmed, expectedSha256: expectedSha256)
        return confirmed
    }

    func registerProxy(masterHash: String, proxyHash: String, assetId: String) async throws {
        let url = try makeURL("/api/proxy/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "masterHash": masterHash,
            "proxyHash": proxyHash,
            "assetId": assetId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data)["error"])
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw APIClientError.httpError(http.statusCode, msg)
        }
    }

    private func ensureChecksumConfirmed(_ result: UploadConfirmResponse, expectedSha256: String) throws {
        guard result.success,
              result.checksumVerified == true,
              result.canReplaceWithProxy == true,
              let serverHash = result.serverSha256?.lowercased(),
              serverHash == expectedSha256.lowercased() else {
            throw APIClientError.checksumNotConfirmed(result.error ?? "Hash mismatch or unverified")
        }
    }
}
