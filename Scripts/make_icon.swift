#!/usr/bin/env swift
// Renders the Vigil app icon with CoreGraphics into an Xcode asset catalog:
//   swift Scripts/make_icon.swift Resources/Assets.xcassets
// build.sh turns the PNGs into AppIcon.icns with iconutil (actool needs full Xcode).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets"
let iconset = outRoot + "/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)! }

/// Draws the icon on a 1024x1024 canvas (macOS icon grid: 824pt artwork, 100pt margin).
func draw(in ctx: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    ctx.clear(canvas)

    // Background tile
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0.08, 0.10, 0.24)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.20, 0.24, 0.52), rgb(0.05, 0.06, 0.20)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // soft glow behind the eye
    ctx.drawRadialGradient(gradient([rgb(0.25, 0.85, 0.80, 0.35), rgb(0.25, 0.85, 0.80, 0)]),
                           startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])
    ctx.restoreGState()

    // Almond-shaped open eye
    let left = CGPoint(x: 232, y: 512), right = CGPoint(x: 792, y: 512)
    let eye = CGMutablePath()
    eye.move(to: left)
    eye.addQuadCurve(to: right, control: CGPoint(x: 512, y: 812))
    eye.addQuadCurve(to: left, control: CGPoint(x: 512, y: 212))
    eye.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(0.30, 0.90, 0.85, 0.55))
    ctx.addPath(eye); ctx.setFillColor(rgb(0.93, 0.97, 1.0)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(eye); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1), rgb(0.72, 0.84, 1.0)]),
                           start: CGPoint(x: 512, y: 720), end: CGPoint(x: 512, y: 300), options: [])
    // iris
    let irisCenter = CGPoint(x: 512, y: 512)
    ctx.addEllipse(in: CGRect(x: irisCenter.x - 150, y: irisCenter.y - 150, width: 300, height: 300))
    ctx.saveGState(); ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0.40, 0.95, 0.85), rgb(0.12, 0.45, 0.95)]),
                           startCenter: CGPoint(x: 490, y: 540), startRadius: 0,
                           endCenter: irisCenter, endRadius: 160, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    // pupil + highlight
    ctx.setFillColor(rgb(0.03, 0.05, 0.14))
    ctx.fillEllipse(in: CGRect(x: 512 - 68, y: 512 - 68, width: 136, height: 136))
    ctx.setFillColor(rgb(1, 1, 1, 0.92))
    ctx.fillEllipse(in: CGRect(x: 545, y: 548, width: 46, height: 46))
    ctx.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

// (point size, scale) pairs required by an .appiconset / .iconset
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (size, scale) in variants {
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try writePNG(render(pixels: size * scale), to: iconset + "/" + name)
    images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: iconset + "/Contents.json"))
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(toFile: outRoot + "/Contents.json", atomically: true, encoding: .utf8)
print("Icon written to \(iconset)")
