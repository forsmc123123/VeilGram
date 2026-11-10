import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PolusGIF {
    static let durationLimit: TimeInterval = 12
    static let frameLimit = 120

    static func delay(_ source: CGImageSource, index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        let timing = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let value = (timing?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
            ?? (timing?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0.1
        return max(0.02, min(value.isFinite ? value : 0.1, 1))
    }

    static func normalize(_ source: CGImageSource, byteLimit: Int) -> Data? {
        var frames: [(index: Int, duration: TimeInterval)] = []
        var elapsed: TimeInterval = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let remaining = self.durationLimit - elapsed
            if remaining <= 0.001 { break }
            let delay = min(remaining, self.delay(source, index: index))
            if frames.count < self.frameLimit && (frames.last?.duration ?? 0.1) >= 0.1 {
                frames.append((index, delay))
            } else {
                frames[frames.count - 1].duration += delay
            }
            elapsed += delay
        }
        guard !frames.isEmpty else { return nil }

        for maximumSize in [384, 256, 160] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSize,
                kCGImageSourceShouldCache: false
            ]
            for frame in frames {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, frame.index, options as CFDictionary) else { return nil }
                let properties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frame.duration,
                    kCGImagePropertyGIFUnclampedDelayTime: frame.duration
                ]]
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            }
            if CGImageDestinationFinalize(destination), output.length > 0, output.length <= byteLimit {
                return output as Data
            }
        }
        return nil
    }
}
