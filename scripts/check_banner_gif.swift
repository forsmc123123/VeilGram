import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct CheckBannerGIF {
    static func main() {
        let frameCount = 150
        let original = NSMutableData()
        let destination = CGImageDestinationCreateWithData(original as CFMutableData, UTType.gif.identifier as CFString, frameCount, nil)!
        let context = CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 48,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let properties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 0.04,
            kCGImagePropertyGIFUnclampedDelayTime: 0.04
        ]]
        for index in 0..<frameCount {
            context.setFillColor(red: CGFloat(index) / CGFloat(frameCount), green: 0.2, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        let source = CGImageSourceCreateWithData((original as Data) as CFData, nil)!
        precondition(CGImageSourceGetCount(source) > PolusGIF.frameLimit)

        let output = PolusGIF.normalize(source, byteLimit: 8 * 1024 * 1024)!
        let result = CGImageSourceCreateWithData(output as CFData, nil)!
        let count = CGImageSourceGetCount(result)
        precondition(count > 1 && count <= PolusGIF.frameLimit)
        let duration = (0..<count).reduce(0.0) { $0 + PolusGIF.delay(result, index: $1) }
        let originalDuration = (0..<frameCount).reduce(0.0) { $0 + PolusGIF.delay(source, index: $1) }
        precondition(abs(duration - min(originalDuration, PolusGIF.durationLimit)) < 0.8)
        precondition(PolusGIF.normalize(source, byteLimit: 1) == nil)
        print("Banner GIF normalization passed")
    }
}
