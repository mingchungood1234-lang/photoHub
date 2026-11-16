import Foundation
import SwiftUI

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
    @AppStorage("serverURL") var serverURL: String = "http://192.168.1.100:3000"
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("uploadMode") var uploadModeRaw: String = UploadMode.directVPS.rawValue
    @AppStorage("proxyFormat") var proxyFormatRaw: String = ProxyFormat.heic.rawValue
    @AppStorage("proxyMaxPixelSize") var proxyMaxPixelSize: Int = 2048
    @AppStorage("proxyQuality") var proxyQuality: Double = 0.72
    @AppStorage("minimumOriginalSizeKB") var minimumOriginalSizeKB: Int = 500

    var uploadMode: UploadMode {
        get { UploadMode(rawValue: uploadModeRaw) ?? .directVPS }
        set { uploadModeRaw = newValue.rawValue }
    }

    var proxyFormat: ProxyFormat {
        get { ProxyFormat(rawValue: proxyFormatRaw) ?? .heic }
        set { proxyFormatRaw = newValue.rawValue }
    }

    var normalizedBaseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: trimmed)
    }
}
