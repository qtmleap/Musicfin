#!/usr/bin/env swift
// TestFlight 提出に最低限必要な 1024x1024 のプレースホルダーアイコンを生成する。
// 正式なアイコンができるまでの繋ぎなので、外部依存なしで AppKit だけで描く。
//
//   swift scripts/make-app-icon.swift
//
// 出力先: Musicfin/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import AppKit

let size = 1024
let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outputURL =
  scriptDirectory
  .appendingPathComponent("../Musicfin/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
  .standardizedFileURL

// App Store はアルファ付きのアイコンを拒否するので、アルファを持たない (noneSkipLast) の
// CGContext に描く。ImageIO はこの alphaInfo を見て RGB 3 チャンネルの PNG を書く。
guard
  let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  )
else {
  FileHandle.standardError.write(Data("ビットマップを作れなかった\n".utf8))
  exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

let bounds = NSRect(x: 0, y: 0, width: size, height: size)

// 上がアクセントカラー（AccentColor.colorset と同値）、下が深いピンク。
let top = NSColor(srgbRed: 0.980, green: 0.176, blue: 0.325, alpha: 1)
let bottom = NSColor(srgbRed: 0.761, green: 0.094, blue: 0.357, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: -90)

// SF Symbols はスクリプトから使えないので、フォントの音符グリフで代用する。
// 太字のシステムフォントに ♪ が無ければ AppKit がフォールバックしてくれる。
let font = NSFont.systemFont(ofSize: 640, weight: .bold)
let note = NSAttributedString(
  string: "\u{266A}",
  attributes: [.font: font, .foregroundColor: NSColor.white]
)
// グリフの余白ぶんだけ視覚的にずれるので、描画矩形ではなくグリフの実寸で中央に合わせる。
let glyphBounds = note.boundingRect(with: bounds.size, options: [.usesLineFragmentOrigin])
let origin = NSPoint(
  x: (bounds.width - glyphBounds.width) / 2 - glyphBounds.minX,
  y: (bounds.height - glyphBounds.height) / 2 - glyphBounds.minY
)
note.draw(at: origin)

NSGraphicsContext.restoreGraphicsState()

guard
  let image = context.makeImage(),
  let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)
else {
  FileHandle.standardError.write(Data("PNG を書き出せなかった\n".utf8))
  exit(1)
}
CGImageDestinationAddImage(destination, image, nil)

guard CGImageDestinationFinalize(destination) else {
  FileHandle.standardError.write(Data("書き込みに失敗: \(outputURL.path)\n".utf8))
  exit(1)
}
print("wrote \(outputURL.path)")
