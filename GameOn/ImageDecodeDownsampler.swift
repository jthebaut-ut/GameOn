import ImageIO
import UIKit

/// Decode-time downsampling for display images.
///
/// Prefer ImageIO thumbnail creation over `UIImage(data:)` → full bitmap → resize.
/// Callers pass a semantic target so the same source URL can decode at different sizes
/// without sharing an undersized bitmap across large presentations.
nonisolated enum ImageDecodeDownsampler {

    /// Pixel caps already include Retina headroom (≈ display points × 3, plus modest slack).
    /// Derived from current FanGeo UI sizes — not arbitrary.
    enum DecodeTarget: String, Hashable, Sendable {
        /// Chat / list / map / profile circle avatars (typical 36–150 pt).
        case avatarSmall
        /// Venue / card / map preview thumbnails (typical ≤ ~390 pt wide on phone).
        case listThumbnail
        /// Full-screen viewer / large detail presentation.
        case detail

        /// Longest edge in pixels for `kCGImageSourceThumbnailMaxPixelSize`.
        var maxPixelSize: Int {
            switch self {
            case .avatarSmall: return 480
            // Covers phone-width cards/covers at 3× with headroom; still far below full-source decode.
            case .listThumbnail: return 1200
            case .detail: return 2048
            }
        }
    }

    struct DecodeResult: Sendable {
        let image: UIImage
        let sourcePixelWidth: Int
        let sourcePixelHeight: Int
        let decodedPixelWidth: Int
        let decodedPixelHeight: Int
        let usedDownsample: Bool
        let decodeMs: Double
    }

    /// Decodes `data` for `target`, downsampling when the source exceeds the target long edge.
    /// Falls back to `UIImage(data:)` only if ImageIO thumbnail creation fails.
    static func decode(data: Data, target: DecodeTarget) -> DecodeResult? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let sourceSize = sourcePixelSize(of: data)
        let maxEdge = target.maxPixelSize

        if let downsampled = downsampleWithImageIO(data: data, maxPixelSize: maxEdge) {
            let decoded = cgPixelSize(of: downsampled)
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            let usedDownsample = (sourceSize.width > maxEdge) || (sourceSize.height > maxEdge)
            ImagePerf.downsampleCompleted(
                bucket: target.rawValue,
                sourceWidth: sourceSize.width,
                sourceHeight: sourceSize.height,
                decodedWidth: decoded.width,
                decodedHeight: decoded.height,
                usedDownsample: usedDownsample,
                ms: ms
            )
            return DecodeResult(
                image: downsampled,
                sourcePixelWidth: sourceSize.width,
                sourcePixelHeight: sourceSize.height,
                decodedPixelWidth: decoded.width,
                decodedPixelHeight: decoded.height,
                usedDownsample: usedDownsample,
                decodeMs: ms
            )
        }

        // Preserve prior failure/success semantics: last-resort full decode.
        guard let full = UIImage(data: data) else { return nil }
        let decoded = cgPixelSize(of: full)
        let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        ImagePerf.downsampleFallbackFullDecode(
            bucket: target.rawValue,
            sourceWidth: sourceSize.width,
            sourceHeight: sourceSize.height,
            decodedWidth: decoded.width,
            decodedHeight: decoded.height,
            ms: ms
        )
        return DecodeResult(
            image: full,
            sourcePixelWidth: sourceSize.width,
            sourcePixelHeight: sourceSize.height,
            decodedPixelWidth: decoded.width,
            decodedPixelHeight: decoded.height,
            usedDownsample: false,
            decodeMs: ms
        )
    }

    /// Convenience when callers only need the UIImage.
    static func uiImage(from data: Data, target: DecodeTarget) -> UIImage? {
        decode(data: data, target: target)?.image
    }

    // MARK: - ImageIO

    private static func downsampleWithImageIO(data: Data, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func sourcePixelSize(of data: Data) -> (width: Int, height: Int) {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return (0, 0)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Orientation may swap display width/height; thumbnail-with-transform handles the bitmap.
        return (width, height)
    }

    private static func cgPixelSize(of image: UIImage) -> (width: Int, height: Int) {
        if let cg = image.cgImage {
            return (cg.width, cg.height)
        }
        return (
            Int(round(image.size.width * image.scale)),
            Int(round(image.size.height * image.scale))
        )
    }

    /// Rough RGBA8 footprint for instrumentation only.
    static func estimatedBitmapBytes(width: Int, height: Int) -> Int {
        max(0, width) * max(0, height) * 4
    }
}
