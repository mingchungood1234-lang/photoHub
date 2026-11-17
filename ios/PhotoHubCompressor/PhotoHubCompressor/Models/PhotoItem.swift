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
    case readyToDelete(savedBytes: Int64)
    case completed(savedBytes: Int64)
    case skipped(String)
    case failed(String)

    var label: String {
        switch self {
        case .pending:
            return "Tap to Select"
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
        case .readyToDelete(let savedBytes):
            let formatted = ByteCountFormatter.string(fromByteCount: max(0, savedBytes), countStyle: .file)
            return "Backed Up • Confirm Delete (\(formatted))"
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
        case .completed, .readyToDelete, .alreadyProxy, .skipped:
            return true
        default:
            return false
        }
    }
}

struct PhotoCandidate: Identifiable {
    let id: String
    let asset: PHAsset
    let mediaType: PHAssetMediaType
    let duration: TimeInterval
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    var thumbnail: UIImage?
    var state: PhotoCompressionState = .pending
    var isSelected: Bool = false

    var isVideo: Bool {
        mediaType == .video
    }

    var resolutionLabel: String {
        if isVideo {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            let durStr = String(format: "%d:%02d", mins, secs)
            if pixelWidth > 0 && pixelHeight > 0 {
                return "Video \(durStr) (\(pixelWidth)×\(pixelHeight))"
            }
            return "Video \(durStr)"
        }
        guard pixelWidth > 0 && pixelHeight > 0 else { return "Photo" }
        let mp = Double(pixelWidth * pixelHeight) / 1_000_000.0
        return String(format: "%.1f MP (%d×%d)", mp, pixelWidth, pixelHeight)
    }
}
