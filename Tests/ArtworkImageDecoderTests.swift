import CoreGraphics
import Foundation
import ImageIO

struct ArtworkImageDecoderTests {
    static func run() throws {
        // 向きの情報だけが異なる JPEG を復号し、寸法だけでなく赤青の配置も比較する。
        let normal = ArtworkImageDecoder.decode(try jpeg(orientation: 1))!
        let mirrored = ArtworkImageDecoder.decode(try jpeg(orientation: 2))!
        let clockwise = ArtworkImageDecoder.decode(try jpeg(orientation: 6))!
        let counterclockwise = ArtworkImageDecoder.decode(try jpeg(orientation: 8))!
        assert(normal.width == 24 && normal.height == 12)
        assert(mirrored.width == 24 && mirrored.height == 12)
        assert(clockwise.width == 12 && clockwise.height == 24)
        assert(counterclockwise.width == 12 && counterclockwise.height == 24)
        let normalColor = try firstHalfColor(normal)
        let mirroredColor = try firstHalfColor(mirrored)
        let clockwiseColor = try firstHalfColor(clockwise)
        let counterclockwiseColor = try firstHalfColor(counterclockwise)
        assert(normalColor > 0 && mirroredColor < 0, "EXIF horizontal reflection was lost")
        assert(
            clockwiseColor * counterclockwiseColor < 0,
            "EXIF clockwise and counterclockwise rotations produced the same pixels")
        print("ArtworkImageDecoder: EXIF reflections, rotations and original dimensions passed")
    }

    private enum FixtureFailure: Error { case image }

    private static func jpeg(orientation: Int) throws -> Data {
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard
            let context = CGContext(
                data: nil, width: 24, height: 12, bitsPerComponent: 8, bytesPerRow: 96,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap.rawValue)
        else { throw FixtureFailure.image }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 12, y: 0, width: 12, height: 12))
        let data = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { throw FixtureFailure.image }
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: 1.0,
            ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureFailure.image }
        return data as Data
    }

    /// 左半分、または縦長なら最初の半分にある赤と青の差を測る。JPEG の丸めには依存しない。
    private static func firstHalfColor(_ image: CGImage) throws -> Int {
        let width = image.width
        let height = image.height
        let bitmap = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap.rawValue)
        else { throw FixtureFailure.image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw FixtureFailure.image }
        var color = 0
        for y in 0..<height {
            for x in 0..<width where width > height ? x < width / 2 : y < height / 2 {
                let start = (y * width + x) * 4
                color += Int(bytes[start]) - Int(bytes[start + 2])
            }
        }
        return color
    }
}
