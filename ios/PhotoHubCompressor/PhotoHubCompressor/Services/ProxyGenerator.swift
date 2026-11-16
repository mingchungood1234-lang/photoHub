import CryptoKit
import Foundation
import ImageIO
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
}

enum ProxyGenerator {
    static func createProxy(
        from masterURL: URL,
        format: ProxyFormat,
        maxPixelSize: Int,
        quality: Double
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
            quality: quality
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
            quality: min(0.5, quality)
        )
    }

    private static func encodeThumbnail(
        source: CGImageSource,
        metadata baseMetadata: [CFString: Any],
        format: ProxyFormat,
        maxPixelSize: Int,
        quality: Double
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

        // Preserve EXIF/GPS/Creation metadata while resetting orientation to 1 (already applied by transform)
        var metadata = baseMetadata
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImageDestinationLossyCompressionQuality] = quality

        let utType: UTType = (format == .heic) ? .heic : .jpeg
        let ext = (format == .heic) ? "heic" : "jpg"
        let proxyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy_\(UUID().uuidString).\(ext)")

        guard let destination = CGImageDestinationCreateWithURL(
            proxyURL as CFURL,
            utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ProxyGeneratorError.failedToCreateDestination
        }

        CGImageDestinationAddImage(destination, downsampledImage, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: proxyURL)
            throw ProxyGeneratorError.failedToFinalize
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: proxyURL.path)
        let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let sha256 = try computeFileSHA256(url: proxyURL)

        return GeneratedProxy(fileURL: proxyURL, sha256: sha256, sizeBytes: sizeBytes)
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
