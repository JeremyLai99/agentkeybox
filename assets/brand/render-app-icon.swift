// Renders the macOS app icon set from the brand masters.
//
//   swift assets/brand/render-app-icon.swift <brand-dir> <output-iconset-dir>
//
// Every size is placed on Apple's icon grid: the rounded-square shape is 824/1024 of the canvas,
// centered, with transparent corners and a soft drop shadow, so the icon matches other apps in
// the Dock and Finder and does not change size between resolutions.
//
// Large sizes come from the detailed raster master (`agentkeybox-app-icon.png`), which is opaque
// and sits on a light backdrop; its rounded square is detected, cropped, and masked here.
// 16–64 px come from the pixel-aware SVGs, as BRAND.md requires, instead of downscaling.
import AppKit

let brand = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let gridFraction: CGFloat = 824.0 / 1024.0
/// The master artwork's own corners measure about 25% of its width (rounder than Apple's 22.4%),
/// so the mask uses 26%; a smaller radius would let the light backdrop show along the corner arc.
let cornerFraction: CGFloat = 0.26

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("render-app-icon: \(message)\n".utf8))
  exit(1)
}

/// The master's rounded square, found by scanning the middle row and column for pixels that are
/// clearly darker than the near-white backdrop.
func shapeBounds(of image: CGImage) -> CGRect {
  guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
    fail("cannot read master pixels")
  }
  let bpp = image.bitsPerPixel / 8
  let row = image.bytesPerRow
  func isShape(_ x: Int, _ y: Int) -> Bool {
    let p = y * row + x * bpp
    return (Int(bytes[p]) + Int(bytes[p + 1]) + Int(bytes[p + 2])) / 3 < 200
  }
  let w = image.width
  let h = image.height
  guard let left = (0..<w).first(where: { isShape($0, h / 2) }),
    let right = (0..<w).last(where: { isShape($0, h / 2) }),
    let top = (0..<h).first(where: { isShape(w / 2, $0) }),
    let bottom = (0..<h).last(where: { isShape(w / 2, $0) })
  else { fail("no icon shape found in master") }
  return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
}

func makeContext(_ size: Int) -> CGContext {
  guard
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fail("cannot create bitmap context") }
  context.interpolationQuality = .high
  return context
}

func shapeRect(canvas: Int) -> CGRect {
  let side = CGFloat(canvas) * gridFraction
  let origin = (CGFloat(canvas) - side) / 2
  // Nudged up slightly so the drop shadow below has room, as in Apple's template.
  return CGRect(x: origin, y: origin + CGFloat(canvas) * 0.01, width: side, height: side)
}

func roundedPath(_ rect: CGRect) -> CGPath {
  let radius = rect.width * cornerFraction
  return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawShadow(_ context: CGContext, _ rect: CGRect, canvas: Int) {
  let scale = CGFloat(canvas) / 1024
  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
    color: NSColor.black.withAlphaComponent(0.28).cgColor)
  context.addPath(roundedPath(rect))
  context.setFillColor(NSColor.black.cgColor)
  context.fillPath()
  context.restoreGState()
}

func write(_ context: CGContext, _ name: String) {
  guard let image = context.makeImage(),
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  else { fail("cannot encode \(name)") }
  try! png.write(to: output.appendingPathComponent(name))
}

func renderMaster(_ size: Int, as name: String) {
  guard let source = NSImage(contentsOf: brand.appendingPathComponent("agentkeybox-app-icon.png")),
    let master = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
  else { fail("missing agentkeybox-app-icon.png") }
  let bounds = shapeBounds(of: master)
  // Crop a hair inside the detected edge so none of the light backdrop survives the mask.
  let inset = bounds.width * 0.004
  guard let cropped = master.cropping(to: bounds.insetBy(dx: inset, dy: inset)) else {
    fail("cannot crop master")
  }
  let context = makeContext(size)
  let rect = shapeRect(canvas: size)
  drawShadow(context, rect, canvas: size)
  context.addPath(roundedPath(rect))
  context.clip()
  context.draw(cropped, in: rect)
  write(context, name)
}

/// Draws an SVG whose own rounded square spans `shapeInViewBox` of its viewBox width.
func renderSVG(_ file: String, shapeInViewBox: CGFloat, size: Int, as name: String) {
  guard let svg = NSImage(contentsOf: brand.appendingPathComponent(file)) else {
    fail("missing \(file)")
  }
  let context = makeContext(size)
  let rect = shapeRect(canvas: size)
  if size >= 64 { drawShadow(context, rect, canvas: size) }
  // Scale the whole viewBox so its shape lands exactly on the grid rect.
  let box = rect.width / shapeInViewBox
  let drawRect = CGRect(
    x: rect.midX - box / 2, y: rect.midY - box / 2, width: box, height: box)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  svg.draw(in: drawRect)
  NSGraphicsContext.restoreGraphicsState()
  write(context, name)
}

// AppIcon-Tiny.svg: shape is 30 of 32 units. AppIcon-Simplified.svg: 120 of 128.
renderSVG("app-icon/AppIcon-Tiny.svg", shapeInViewBox: 30.0 / 32.0, size: 16, as: "icon_16x16.png")
renderSVG("app-icon/AppIcon-Tiny.svg", shapeInViewBox: 30.0 / 32.0, size: 32, as: "icon_16x16@2x.png")
renderSVG("app-icon/AppIcon-Tiny.svg", shapeInViewBox: 30.0 / 32.0, size: 32, as: "icon_32x32.png")
renderSVG(
  "app-icon/AppIcon-Simplified.svg", shapeInViewBox: 120.0 / 128.0, size: 64,
  as: "icon_32x32@2x.png")
renderMaster(128, as: "icon_128x128.png")
renderMaster(256, as: "icon_128x128@2x.png")
renderMaster(256, as: "icon_256x256.png")
renderMaster(512, as: "icon_256x256@2x.png")
renderMaster(512, as: "icon_512x512.png")
renderMaster(1024, as: "icon_512x512@2x.png")
print("Rendered app icon set at \(output.path)")
