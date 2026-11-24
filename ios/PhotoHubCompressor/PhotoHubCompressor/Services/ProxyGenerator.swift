import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ProxyGeneratorError: LocalizedError {
    case failedToOpenSource
    case failedToCreateThumbnail
    case failedToCreateDestination
    case failedToFinalize

    var errorDescription: String? {
        switch self {
        case .failedToOpenSource:
            return "Could not open original photo for proxy generation."
        case .failedToCreateThumbnail:
            return "Could not downsample original photo."
        case .failedToCreateDestination:
            return "Could not create proxy image file."
        case .failedToFinalize:
            return "Could not write compressed proxy image."
        }
    }
}

struct GeneratedProxy {
    let fileURL: URL
    let sha256: String
    let sizeBytes: Int64
    var posterFileURL: URL? = nil
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func tryTrigger() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

enum ProxyGenerator {
    static let proxyFilenamePrefix = "PHOTOHUB_PROXY_"
    static let proxyMarkerPrefix = "PhotoHubProxy:"

    static func proxyPrefixTag(forMasterHash masterHash: String) -> String {
        let hex = extractLowercaseHexPrefix(from: masterHash, maxLength: 16)
        return hex
    }

    /// Parses `PHOTOHUB_PROXY_<16hex>` (case-insensitive) from a local or iCloud-synced PHAssetResource filename.
    static func extractMasterHashPrefix(fromProxyFilename filename: String) -> String? {
        let baseName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let upper = baseName.uppercased()
        guard upper.hasPrefix(proxyFilenamePrefix) else { return nil }
        let suffixStart = baseName.index(baseName.startIndex, offsetBy: proxyFilenamePrefix.count)
        let suffix = String(baseName[suffixStart...])
        let hex = extractLowercaseHexPrefix(from: suffix, maxLength: 16)
        return hex.count >= 8 ? hex : nil
    }

    static func makeTaggedProxyTempURL(
        masterHash: String?,
        ext: String,
        fallbackPrefix: String = "proxy"
    ) -> URL {
        let fm = FileManager.default
        if let masterHash {
            let prefix = proxyPrefixTag(forMasterHash: masterHash)
            if prefix.count >= 8 {
                let subdir = fm.temporaryDirectory
                    .appendingPathComponent("phproxy_\(UUID().uuidString)", isDirectory: true)
                if (try? fm.createDirectory(at: subdir, withIntermediateDirectories: true)) != nil {
                    return subdir.appendingPathComponent("\(proxyFilenamePrefix)\(prefix).\(ext)")
                }
                return fm.temporaryDirectory
                    .appendingPathComponent("\(proxyFilenamePrefix)\(prefix)_\(UUID().uuidString.prefix(8)).\(ext)")
            }
        }
        return fm.temporaryDirectory
            .appendingPathComponent("\(fallbackPrefix)_\(UUID().uuidString).\(ext)")
    }

    static func cleanupTempFile(_ url: URL?) {
        guard let url else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("phproxy_") {
            try? fm.removeItem(at: parent)
        }
    }

    static func taggedImageProperties(masterHash: String?, quality: Double? = nil) -> [CFString: Any] {
        var props: [CFString: Any] = [:]
        if let quality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let cleanMaster = cleanMasterHashString(masterHash) {
            let marker = "\(proxyMarkerPrefix)\(cleanMaster)"
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFSoftware: "PhotoHub Proxy",
                kCGImagePropertyTIFFImageDescription: marker,
            ]
            props[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: marker,
            ]
        }
        return props
    }

    /// Writes server-downloaded proxy image bytes into a uniquely tagged temporary file so
    /// Apple Photos and iCloud preserve both `PHOTOHUB_PROXY_<prefix16>` and EXIF marker tags.
    static func writeTaggedProxyImageData(_ imageData: Data, masterHash: String) -> URL? {
        guard !imageData.isEmpty else { return nil }
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil) {
            let sourceTypeId = CGImageSourceGetType(source) as String?
            let ext = (sourceTypeId == UTType.heic.identifier) ? "heic" : "jpg"
            let destUTType = sourceTypeId ?? UTType.jpeg.identifier
            let taggedURL = makeTaggedProxyTempURL(masterHash: masterHash, ext: ext)

            if let destination = CGImageDestinationCreateWithURL(
                taggedURL as CFURL,
                destUTType as CFString,
                1,
                nil
            ) {
                let props = taggedImageProperties(masterHash: masterHash, quality: nil)
                CGImageDestinationAddImageFromSource(destination, source, 0, props as CFDictionary)
                if CGImageDestinationFinalize(destination) {
                    return taggedURL
                }
            }
            cleanupTempFile(taggedURL)
        }

        let fallbackURL = makeTaggedProxyTempURL(masterHash: masterHash, ext: "jpg")
        do {
            try imageData.write(to: fallbackURL, options: .atomic)
            return fallbackURL
        } catch {
            cleanupTempFile(fallbackURL)
            return nil
        }
    }

    static func writeTaggedVideoCopy(from videoURL: URL, masterHash: String) -> URL? {
        let taggedURL = makeTaggedProxyTempURL(masterHash: masterHash, ext: "mp4", fallbackPrefix: "video_proxy")
        do {
            try? FileManager.default.removeItem(at: taggedURL)
            try FileManager.default.copyItem(at: videoURL, to: taggedURL)
            return taggedURL
        } catch {
            cleanupTempFile(taggedURL)
            return nil
        }
    }

    /// Reads embedded PhotoHub EXIF / TIFF marker (`PhotoHubProxy:<masterHash>`) directly from image bytes
    /// without writing temporary files to disk.
    static func extractEmbeddedProxyMasterHash(fromImageData imageData: Data) -> String? {
        guard !imageData.isEmpty,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return extractEmbeddedMasterHash(fromImageProperties: props)
    }

    /// Reads embedded PhotoHub EXIF / TIFF / QuickTime marker (`PhotoHubProxy:<masterHash>`)
    /// from an exported file when synced via iCloud across devices.
    static func extractEmbeddedProxyMasterHash(fromFileURL fileURL: URL, isVideo: Bool) async -> String? {
        if !isVideo {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return nil
            }
            return extractEmbeddedMasterHash(fromImageProperties: props)
        }

        let avAsset = AVURLAsset(url: fileURL)
        let items: [AVMetadataItem]
        if #available(iOS 16.0, *) {
            items = (try? await avAsset.load(.commonMetadata)) ?? []
        } else {
            items = avAsset.commonMetadata
        }
        for item in items {
            if #available(iOS 16.0, *) {
                if let str = try? await item.load(.stringValue),
                   let parsed = parseMarkerHash(from: str) {
                    return parsed
                }
            } else if let str = item.stringValue,
                      let parsed = parseMarkerHash(from: str) {
                return parsed
            }
        }
        return findProxyMarkerInMP4File(fileURL)
    }

    static func findProxyMarkerInMP4Bytes(_ data: Data) -> String? {
        guard !data.isEmpty,
              let markerData = proxyMarkerPrefix.data(using: .utf8),
              let range = data.range(of: markerData) else {
            return nil
        }
        let start = range.upperBound
        let end = min(data.endIndex, start + 128)
        guard start < end,
              let tail = String(data: data[start..<end], encoding: .utf8)
                ?? String(data: data[start..<end], encoding: .isoLatin1) else {
            return nil
        }
        let hex = extractLowercaseHexPrefix(from: tail, maxLength: 64)
        return hex.count >= 8 ? hex : nil
    }

    private static func findProxyMarkerInMP4File(_ fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let probeSize = 256 * 1024
        let head = handle.readData(ofLength: probeSize)
        if let hit = findProxyMarkerInMP4Bytes(head) {
            return hit
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let totalSize = (attrs[.size] as? NSNumber)?.int64Value,
           totalSize > Int64(probeSize) {
            let tailOffset = UInt64(max(0, totalSize - Int64(probeSize)))
            try? handle.seek(toOffset: tailOffset)
            let tail = handle.readData(ofLength: probeSize)
            if let hit = findProxyMarkerInMP4Bytes(tail) {
                return hit
            }
        }
        return nil
    }

    private static func cleanMasterHashString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = extractLowercaseHexPrefix(from: raw, maxLength: 64)
        return hex.count >= 8 ? hex : nil
    }

    private static func extractLowercaseHexPrefix(from raw: String, maxLength: Int) -> String {
        var result = ""
        result.reserveCapacity(min(raw.count, maxLength))
        for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            guard ("0"..."9").contains(ch) || ("a"..."f").contains(ch) else {
                if !result.isEmpty { break }
                continue
            }
            result.append(ch)
            if result.count >= maxLength { break }
        }
        return result
    }

    private static func parseMarkerHash(from raw: String) -> String? {
        guard let range = raw.range(of: proxyMarkerPrefix, options: [.caseInsensitive]) else {
            return nil
        }
        let remainder = String(raw[range.upperBound...])
        let hex = extractLowercaseHexPrefix(from: remainder, maxLength: 64)
        return hex.count >= 8 ? hex : nil
    }

    private static func extractEmbeddedMasterHash(fromImageProperties props: [CFString: Any]) -> String? {
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let comment = exif[kCGImagePropertyExifUserComment] as? String,
           let parsed = parseMarkerHash(from: comment) {
            return parsed
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let desc = tiff[kCGImagePropertyTIFFImageDescription] as? String,
           let parsed = parseMarkerHash(from: desc) {
            return parsed
        }
        return nil
    }

    static func createProxy(
        from masterURL: URL,
        format: ProxyFormat,
        maxPixelSize: Int,
        quality: Double,
        masterHash: String? = nil
    ) throws -> GeneratedProxy {
        guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil) else {
            throw ProxyGeneratorError.failedToOpenSource
        }

        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let srcWidth = (metadata[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let srcHeight = (metadata[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longestEdge = max(srcWidth, srcHeight)

        // When maxPixelSize <= 0 (Auto mode), always scale down so every resolution (48MP, 24MP, 12MP, or smaller) produces a lightweight proxy
        let targetMaxPixelSize: Int
        if maxPixelSize <= 0 {
            if longestEdge > 4096 {
                targetMaxPixelSize = 1920
            } else if longestEdge > 2048 {
                targetMaxPixelSize = 1440
            } else if longestEdge > 1280 {
                targetMaxPixelSize = 1024
            } else if longestEdge > 0 {
                targetMaxPixelSize = max(640, Int(Double(longestEdge) * 0.75))
            } else {
                targetMaxPixelSize = 1440
            }
        } else {
            targetMaxPixelSize = longestEdge > 0 ? min(longestEdge, maxPixelSize) : maxPixelSize
        }

        let masterAttrs = try? FileManager.default.attributesOfItem(atPath: masterURL.path)
        let masterSize = (masterAttrs?[.size] as? NSNumber)?.int64Value ?? Int64.max

        // First pass with requested format/quality
        if let proxy = try? encodeThumbnail(
            source: source,
            metadata: metadata,
            format: format,
            maxPixelSize: targetMaxPixelSize,
            quality: quality,
            masterHash: masterHash
        ), proxy.sizeBytes < masterSize {
            return proxy
        }

        // Fallback pass: stronger compression in JPEG to guarantee a smaller proxy for any photo/screenshot
        let fallbackPx = max(512, Int(Double(targetMaxPixelSize) * 0.7))
        return try encodeThumbnail(
            source: source,
            metadata: metadata,
            format: .jpeg,
            maxPixelSize: fallbackPx,
            quality: min(0.5, quality),
            masterHash: masterHash
        )
    }

    private static func encodeThumbnail(
        source: CGImageSource,
        metadata baseMetadata: [CFString: Any],
        format: ProxyFormat,
        maxPixelSize: Int,
        quality: Double,
        masterHash: String? = nil
    ) throws -> GeneratedProxy {
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw ProxyGeneratorError.failedToCreateThumbnail
        }

        // Use clean encoding properties without copying raw {MakerApple}/LivePhoto/HDR/dimension dictionaries
        // from the original master (which cause photolibraryd to reject the proxy container during performChanges).
        // Creation date, GPS location, and favorite status are preserved directly via PHAssetChangeRequest.
        let encodeProps = taggedImageProperties(masterHash: masterHash, quality: quality)

        let utType: UTType = (format == .heic) ? .heic : .jpeg
        let ext = (format == .heic) ? "heic" : "jpg"
        let proxyURL = makeTaggedProxyTempURL(masterHash: masterHash, ext: ext, fallbackPrefix: "proxy")

        guard let destination = CGImageDestinationCreateWithURL(
            proxyURL as CFURL,
            utType.identifier as CFString,
            1,
            nil
        ) else {
            cleanupTempFile(proxyURL)
            throw ProxyGeneratorError.failedToCreateDestination
        }

        CGImageDestinationAddImage(destination, downsampledImage, encodeProps as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            cleanupTempFile(proxyURL)
            throw ProxyGeneratorError.failedToFinalize
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: proxyURL.path)
        let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let sha256 = try computeFileSHA256(url: proxyURL)

        return GeneratedProxy(fileURL: proxyURL, sha256: sha256, sizeBytes: sizeBytes)
    }

    static func createVideoProxy(
        from masterURL: URL,
        maxPixelSize: Int = 0,
        quality: Double = 0.72,
        masterHash: String? = nil
    ) async throws -> GeneratedProxy {
        let avAsset = AVURLAsset(url: masterURL)
        let compatiblePresets = Set(AVAssetExportSession.exportPresets(compatibleWith: avAsset))
        let masterAttrs = try? FileManager.default.attributesOfItem(atPath: masterURL.path)
        let masterSize = (masterAttrs?[.size] as? NSNumber)?.int64Value ?? Int64.max

        let preferredLadder: [String]
        if maxPixelSize > 0 && maxPixelSize <= 960 {
            preferredLadder = [AVAssetExportPreset640x480, AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality]
        } else if maxPixelSize == 0 {
            preferredLadder = quality < 0.59
                ? [AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality, AVAssetExportPreset640x480]
                : [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality]
        } else if maxPixelSize <= 1440 {
            preferredLadder = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality]
        } else {
            preferredLadder = quality < 0.59
                ? [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality]
                : [AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality]
        }

        let selectedPreset = preferredLadder.first(where: { compatiblePresets.contains($0) })
            ?? AVAssetExportPresetMediumQuality

        func runExport(preset: String) async throws -> (url: URL, sizeBytes: Int64) {
            let candidateURL = makeTaggedProxyTempURL(masterHash: masterHash, ext: "mp4", fallbackPrefix: "video_proxy")
            guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: preset) else {
                cleanupTempFile(candidateURL)
                throw ProxyGeneratorError.failedToOpenSource
            }
            exportSession.outputURL = candidateURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true
            if let cleanMaster = cleanMasterHashString(masterHash) {
                let descItem = AVMutableMetadataItem()
                descItem.identifier = .commonIdentifierDescription
                descItem.value = "\(proxyMarkerPrefix)\(cleanMaster)" as NSString
                let swItem = AVMutableMetadataItem()
                swItem.identifier = .commonIdentifierSoftware
                swItem.value = "PhotoHub Proxy" as NSString
                exportSession.metadata = [descItem, swItem]
            }

            let once = OnceFlag()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exportSession.exportAsynchronously {
                    guard once.tryTrigger() else { return }
                    continuation.resume()
                }
            }

            guard exportSession.status == .completed else {
                cleanupTempFile(candidateURL)
                throw exportSession.error ?? ProxyGeneratorError.failedToFinalize
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: candidateURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return (candidateURL, size)
        }

        var exported = try await runExport(preset: selectedPreset)
        if exported.sizeBytes >= masterSize && selectedPreset != AVAssetExportPresetMediumQuality {
            cleanupTempFile(exported.url)
            exported = try await runExport(preset: AVAssetExportPresetMediumQuality)
        }
        let proxyURL = exported.url

        // Also generate a small compressed JPEG poster frame so the Server tab can display a preview thumbnail
        var posterURL: URL?
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil),
           let jpgData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.65) {
            let pURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("video_poster_\(UUID().uuidString).jpg")
            if (try? jpgData.write(to: pURL)) != nil {
                posterURL = pURL
            }
        }

        let sha256 = try computeFileSHA256(url: proxyURL)

        return GeneratedProxy(
            fileURL: proxyURL,
            sha256: sha256,
            sizeBytes: exported.sizeBytes,
            posterFileURL: posterURL
        )
    }

    static func computeFileSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1 MB streaming chunks
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
