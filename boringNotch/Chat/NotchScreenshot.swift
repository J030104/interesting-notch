import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NotchScreenshot {
    static let limit = 3
    private static let maxBytes = 6 * 1024 * 1024

    static func encode(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = imageType(source) else { return nil }
        if type == .png, data.count <= maxBytes { return data }
        return thumbnailPNG(source)
    }

    static func encodeFile(_ url: URL, size: Int?) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = imageType(source) else { return nil }
        if type == .png, let size, size <= maxBytes, let data = try? Data(contentsOf: url) {
            return data
        }
        return thumbnailPNG(source)
    }

    private static func imageType(_ source: CGImageSource) -> UTType? {
        guard let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image) else { return nil }
        return type
    }

    private static func thumbnailPNG(_ source: CGImageSource) -> Data? {
        for pixels in [2400, 1600, 1200] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { break }
            let png = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(writer, image, nil)
            if CGImageDestinationFinalize(writer), png.length <= maxBytes { return png as Data }
        }
        return nil
    }
}
