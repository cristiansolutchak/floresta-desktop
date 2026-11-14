// Renders the Floresta app icon at every size the desktop platforms need.
//
//   swift tool/brand/render_app_icon.swift
//
// Source of truth: the brand symbol in assets/icon.svg (six rectangles on a
// 4.546-unit grid), drawn in white on the deep teal of the announcement
// render (assets/app-icon/img-announcement-post1.png, sampled 2026-10-26:
// lit #2D6062, edges #0D2D2E, light from the top right). The 3D render
// itself is not used: its glass edges, perspective and flare do not survive
// 16-48 px. Writes:
//   assets/app-icon/app-icon-1024.png   master render
//   assets/app-icon/app-icon-256.png    in-app/window icon
//   macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
//   windows/runner/resources/app_icon.ico (16-256, PNG-compressed)
//   linux/icons/hicolor/<n>x<n>/apps/floresta-desktop.png
// macOS-only tool (CoreGraphics); the outputs are committed.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : FileManager.default.currentDirectoryPath)

// assets/icon.svg, viewBox 0 0 27 25 (y down).
let symbol: [CGRect] = [
  CGRect(x: 4.54609, y: 0, width: 4.54608, height: 4.54609),
  CGRect(x: 0, y: 4.54609, width: 4.54609, height: 4.54608),
  CGRect(x: 4.54609, y: 9.09217, width: 4.54608, height: 4.54613),
  CGRect(x: 9.09217, y: 13.6383, width: 4.54613, height: 10.6075),
  CGRect(x: 9.09217, y: 4.54609, width: 17.42663, height: 4.54608),
  CGRect(x: 9.09217, y: 13.6383, width: 10.60753, height: 4.546),
]
let symbolW = 26.5188, symbolH = 24.2458, unit = 4.54609

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
          green: CGFloat((hex >> 8) & 0xff) / 255,
          blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draws the icon on a size x size transparent canvas.
/// `fullBleed`: no macOS grid margin (Windows/Linux icons fill the square).
func render(_ size: Int, fullBleed: Bool) -> CGImage {
  let s = CGFloat(size)
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  // Flip to y-down so the SVG coordinates apply directly.
  ctx.translateBy(x: 0, y: s)
  ctx.scaleBy(x: 1, y: -1)

  // Body: Apple's 824/1024 grid on macOS; small sizes keep a 1 px margin.
  let margin: CGFloat = fullBleed
    ? (size <= 32 ? 1 : (s * 0.04).rounded())
    : (size <= 32 ? 1 : (s * 100 / 1024).rounded())
  let body = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
  let radius = body.width * 0.225
  let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

  // Soft shadow under the body (macOS style), only where it can be seen.
  if size >= 64 && !fullBleed {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.025,
                  color: rgb(0x000000, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x0D2D2E))
    ctx.fillPath()
    ctx.restoreGState()
  }

  // Teal gradient, light from the top right like the render.
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            colors: [rgb(0x2D6062), rgb(0x174142), rgb(0x0D2D2E)] as CFArray,
                            locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(gradient,
                         start: CGPoint(x: body.maxX, y: body.minY),
                         end: CGPoint(x: body.minX, y: body.maxY), options: [])
  if size >= 64 {
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: body.maxX - body.width * 0.12,
                                                y: body.minY + body.height * 0.08),
                           startRadius: 0,
                           endCenter: CGPoint(x: body.maxX - body.width * 0.12,
                                              y: body.minY + body.height * 0.08),
                           endRadius: body.width * 0.7, options: [])
  }
  ctx.restoreGState()

  // Symbol: half the body width at large sizes; at 16-64 px a whole number
  // of pixels per grid cell so its edges stay sharp.
  let scale: CGFloat
  switch size {
  case ...16: scale = 2 / unit
  case ...24: scale = 3 / unit
  case ...32: scale = 3 / unit
  case ...48: scale = 5 / unit
  case ...64: scale = 6 / unit
  default: scale = body.width * 0.5 / symbolW
  }
  var ox = body.midX - symbolW * scale / 2
  var oy = body.midY - symbolH * scale / 2
  if size <= 64 { ox = ox.rounded(); oy = oy.rounded() }
  ctx.setFillColor(rgb(0xFFFFFF))
  for r in symbol {
    var rect = CGRect(x: ox + r.minX * scale, y: oy + r.minY * scale,
                      width: r.width * scale, height: r.height * scale)
    if size <= 64 { rect = rect.integral }
    ctx.fill(rect)
  }
  return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
  let data = NSMutableData()
  let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  return data as Data
}

func write(_ data: Data, _ path: String) throws {
  let url = root.appendingPathComponent(path)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                          withIntermediateDirectories: true)
  try data.write(to: url)
  print("wrote \(path)")
}

// Master renders.
try write(png(render(1024, fullBleed: false)), "assets/app-icon/app-icon-1024.png")
try write(png(render(256, fullBleed: true)), "assets/app-icon/app-icon-256.png")

// macOS.
for n in [16, 32, 64, 128, 256, 512, 1024] {
  try write(png(render(n, fullBleed: false)),
            "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_\(n).png")
}

// Linux hicolor theme.
for n in [16, 24, 32, 48, 64, 128, 256, 512] {
  try write(png(render(n, fullBleed: true)),
            "linux/icons/hicolor/\(n)x\(n)/apps/floresta-desktop.png")
}

// Windows ICO with PNG entries (supported since Vista).
let icoSizes = [16, 24, 32, 48, 64, 128, 256]
let entries = icoSizes.map { png(render($0, fullBleed: true)) }
var ico = Data([0, 0, 1, 0, UInt8(icoSizes.count), 0])
var offset = 6 + 16 * icoSizes.count
func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
for (n, data) in zip(icoSizes, entries) {
  ico.append(contentsOf: [UInt8(n == 256 ? 0 : n), UInt8(n == 256 ? 0 : n), 0, 0])
  ico.append(contentsOf: le16(1) + le16(32) + le32(data.count) + le32(offset))
  offset += data.count
}
for data in entries { ico.append(data) }
try write(ico, "windows/runner/resources/app_icon.ico")
