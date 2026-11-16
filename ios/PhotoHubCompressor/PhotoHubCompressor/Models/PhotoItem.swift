import Foundation
import Photos
import UIKit

enum PhotoCompressionState: Equatable {
    case pending
    case hashing
    case alreadyProxy
    case uploading(Double)
    case verifyingChecksum
    case creatingProxy
    case replacingInPhotos
    case completed(savedBytes: Int64)
    case skipped(String)
    case failed(String)

    var label: String {
        switch self {
        case .pending:
            return "Ready"
        case .hashing:
            return "Hashing…"
        case .alreadyProxy:
            return "Already Proxy"
        case .uploading(let progress):
            return "Uploading \(Int(progress * 100))%"
        case .verifyingChecksum:
            return "Verifying Checksum…"
        case .creatingProxy:
            return "Compressing Proxy…"
        case .replacingInPhotos:
            return "Replacing in Photos…"
        case .completed(let savedBytes):
            let formatted = ByteCountFormatter.string(fromByteCount: max(0, savedBytes), countStyle: .file)
            return "Saved \(formatted)"
        case .skipped(let reason):
            return reason
        case .failed(let message):
            return "Error: \(message)"
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .alreadyProxy, .skipped:
            return true
        default:
            return false
        }
    }
}

struct PhotoCandidate: Identifiable {
    let id: String
    let asset: PHAsset
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    var thumbnail: UIImage?
    var state: PhotoCompressionState = .pending
    var isSelected: Bool = true

    var resolutionLabel: String {
        guard pixelWidth > 0 && pixelHeight > 0 else { return "Photo" }
        let mp = Double(pixelWidth * pixelHeight) / 1_000_000.0
        return String(format: "%.1f MP (%d×%d)", mp, pixelWidth, pixelHeight)
    }
}
