import Foundation
import SwiftUI

enum ServerProtocol: String, CaseIterable, Identifiable {
    case http = "http"
    case https = "https"

    var id: String { rawValue }

    var displayName: String {
        rawValue.uppercased()
    }
}

enum UploadMode: String, CaseIterable, Identifiable {
    case directVPS = "direct_vps"
    case s3Presigned = "s3_presigned"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .directVPS: return "Direct to VPS"
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

final class AppSettings: ObservableObject {
    @AppStorage("serverProtocol") var serverProtocolRaw: String = ServerProtocol.http.rawValue
    @AppStorage("serverURL") var serverURL: String = "192.168.1.100:3000"
    @AppStorage("allowSelfSignedHTTPS") var allowSelfSignedHTTPS: Bool = false
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("uploadMode") var uploadModeRaw: String = UploadMode.directVPS.rawValue
    @AppStorage("proxyFormat") var proxyFormatRaw: String = ProxyFormat.heic.rawValue
    @AppStorage("proxyMaxPixelSize") var proxyMaxPixelSize: Int = 0 // 0 = Auto for all resolutions
    @AppStorage("proxyQuality") var proxyQuality: Double = 0.72
    @AppStorage("minimumOriginalSizeKB") var minimumOriginalSizeKB: Int = 500
    @AppStorage("keepLocalProxyInPhotos") var keepLocalProxyInPhotos: Bool = false

    var serverProtocol: ServerProtocol {
        get { ServerProtocol(rawValue: serverProtocolRaw) ?? .http }
        set { serverProtocolRaw = newValue.rawValue }
    }

    var uploadMode: UploadMode {
        get { UploadMode(rawValue: uploadModeRaw) ?? .directVPS }
        set { uploadModeRaw = newValue.rawValue }
    }

    var proxyFormat: ProxyFormat {
        get { ProxyFormat(rawValue: proxyFormatRaw) ?? .heic }
        set { proxyFormatRaw = newValue.rawValue }
    }

    var normalizedBaseURL: URL? {
        var host = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty else { return nil }

        // Strip any manually pasted scheme so the selected HTTP/HTTPS picker controls the protocol
        if host.lowercased().hasPrefix("https://") {
            host = String(host.dropFirst("https://".count))
        } else if host.lowercased().hasPrefix("http://") {
            host = String(host.dropFirst("http://".count))
        }

        return URL(string: "\(serverProtocol.rawValue)://\(host)")
    }
}
