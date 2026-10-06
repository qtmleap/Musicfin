import UIKit
import XCTest

extension CaptureScreensUITests {
    /// 要素の位置だけでは選択行に重なる枠を見逃すため、操作後の画素で長いアクセント色の線を検出する。
    @MainActor
    func testPadSidebarSelectionHasNoRectangularOutline() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp()
        ensureSignedIn()

        for destination in ["albums", "artists", "songs", "home"] {
            let row = padSidebarRow("sidebar.\(destination)")
            XCTAssertTrue(row.waitForExistence(timeout: 15), "選択する行が表示されなかった")
            row.tap()
            settle()
            XCTAssertTrue(row.isSelected, "選択状態が読み上げに伝わらなかった")
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "sidebar-selection-\(destination)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let window = app.windows.firstMatch.frame
            let region = CGRect(x: 10, y: row.frame.minY - 8, width: 269.5, height: row.frame.height + 16)
            let lineLength = try longestAccentLine(in: screenshot.image, region: region, window: window)
            // 文字や記号にも同じ色を使うが、60 pt を超える水平線は持たない。枠の辺だけを区別する。
            XCTAssertLessThan(lineLength, 60, "\(destination) の周囲に \(lineLength) pt の枠線が残った")
        }
    }

    @MainActor
    private func longestAccentLine(in image: UIImage, region: CGRect, window: CGRect) throws -> CGFloat {
        let raw = try XCTUnwrap(image.cgImage)
        let format = UIGraphicsImageRendererFormat()
        // 横向きの screenshot も CGImage は縦向きのままなので、UIImage の向きを適用してから座標を合わせる。
        format.scale = sqrt(CGFloat(raw.width * raw.height) / (window.width * window.height))
        let upright = UIGraphicsImageRenderer(size: window.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: window.size))
        }
        let source = try XCTUnwrap(upright.cgImage)
        let scale = CGFloat(source.width) / window.width
        let crop = try XCTUnwrap(source.cropping(to: region.applying(CGAffineTransform(scaleX: scale, y: scale))))
        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let longest = try pixels.withUnsafeMutableBytes { bytes -> Int in
            let context = try XCTUnwrap(
                CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            )
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            let buffer = bytes.bindMemory(to: UInt8.self)
            var longest = 0
            for y in 0..<height {
                var run = 0
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let red = Int(buffer[offset])
                    let green = Int(buffer[offset + 1])
                    let blue = Int(buffer[offset + 2])
                    if red > 150, red > green * 2, red * 10 > blue * 13 {
                        run += 1
                        longest = max(longest, run)
                    } else {
                        run = 0
                    }
                }
            }
            return longest
        }
        return CGFloat(longest) / scale
    }
}
