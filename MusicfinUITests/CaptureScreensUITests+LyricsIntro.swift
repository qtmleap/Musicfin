import UIKit
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testCaptureReplyLyricsScreens() {
        launchApp()
        ensureSignedIn()
        captureReplyPlayerScreens()
        XCTAssertTrue(skippedScreens.isEmpty, "歌詞の比較画面を撮影できなかった")
    }

    /// 読み上げ用の見えない印だけでは通ってしまうため、前奏の丸を実際の画素で確かめる。
    @MainActor
    func assertLyricsIntroAppearance(_ intro: XCUIElement) {
        XCTAssertGreaterThan(intro.frame.width, 50, "前奏の印が見えない大きさのまま")
        XCTAssertGreaterThan(intro.frame.height, 8, "前奏の印が見えない大きさのまま")
        do {
            let count = try visibleIntroDots(in: XCUIScreen.main.screenshot().image, region: intro.frame)
            XCTAssertEqual(count, 3, "前奏に大きな丸が3個描画されていない")
        } catch {
            XCTFail("前奏の画素を確認できなかった: \(error)")
        }
    }

    @MainActor
    func lyricsIntroFrame(in region: CGRect) throws -> Data {
        let crop = try lyricsIntroCrop(in: XCUIScreen.main.screenshot().image, region: region)
        return try XCTUnwrap(UIImage(cgImage: crop.image).pngData())
    }

    @MainActor
    private func lyricsIntroCrop(in image: UIImage, region: CGRect) throws -> (image: CGImage, scale: CGFloat) {
        let window = app.windows.firstMatch.frame
        let raw = try XCTUnwrap(image.cgImage)
        let format = UIGraphicsImageRendererFormat()
        // 横向きでも UIImage の向きを適用し、要素の座標と画素の座標をそろえる。
        format.scale = sqrt(CGFloat(raw.width * raw.height) / (window.width * window.height))
        let upright = UIGraphicsImageRenderer(size: window.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: window.size))
        }
        let source = try XCTUnwrap(upright.cgImage)
        let scale = CGFloat(source.width) / window.width
        let crop = try XCTUnwrap(source.cropping(to: region.applying(CGAffineTransform(scaleX: scale, y: scale))))
        return (crop, scale)
    }

    @MainActor
    private func visibleIntroDots(in image: UIImage, region: CGRect) throws -> Int {
        let (crop, scale) = try lyricsIntroCrop(in: image, region: region)
        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(
                CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            )
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bright = (0..<(width * height)).map { index in
            let offset = index * 4
            let rgb = [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
            return rgb.min()! > 190 && Int(rgb.max()!) - Int(rgb.min()!) < 30
        }
        var count = 0
        for seed in bright.indices where bright[seed] {
            bright[seed] = false
            var pending = [seed]
            var minX = seed % width
            var maxX = minX
            var minY = seed / width
            var maxY = minY
            while let index = pending.popLast() {
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                for (nextX, nextY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                    let next = nextY * width + nextX
                    if bright[next] {
                        bright[next] = false
                        pending.append(next)
                    }
                }
            }
            let dotWidth = CGFloat(maxX - minX + 1) / scale
            let dotHeight = CGFloat(maxY - minY + 1) / scale
            // 小さな句読点や文字を数えず、参照の約15 ptの丸に相当する領域だけを拾う。
            if (8...22).contains(dotWidth), (8...22).contains(dotHeight), abs(dotWidth - dotHeight) < 3 {
                count += 1
            }
        }
        return count
    }
}
