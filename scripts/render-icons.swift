#!/usr/bin/env swift

// Renders the app icon (iOS only) into Sources/FlextunnelApp/Assets.xcassets/
// AppIcon.appiconset and emits a source-of-truth icon.svg, mirroring the flow in
// ../s3player-app/scripts/render-icons.swift — minus the macOS sizes and the
// separate debug variant (this app is iOS-only).
//
// Run:  swift scripts/render-icons.swift
//
// Motif: a globe (it's a browser) in a single bold white glyph over a
// tunnel-blue gradient, with dark and tinted appearance variants for iOS.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024

// MARK: - Asset-catalog Contents.json model

struct Contents: Encodable {
    let images: [IconImage]
    let info: Info
}

struct IconImage: Encodable {
    let appearances: [Appearance]?
    let filename: String
    let idiom: String
    let platform: String?
    let size: String
}

struct Appearance: Encodable {
    let appearance: String
    let value: String
}

struct Info: Encodable {
    let author: String
    let version: Int
}

// MARK: - Paths

func absoluteURL(for path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    return url.path.hasPrefix("/")
        ? url
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
}

let repoRoot = absoluteURL(for: CommandLine.arguments[0])
    .standardizedFileURL
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let outDir = repoRoot.appendingPathComponent("Sources/FlextunnelApp/Assets.xcassets/AppIcon.appiconset")

// MARK: - Drawing

func makeContext(size: Int) -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 4 * size,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func savePNG(_ context: CGContext, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func fillGradient(in context: CGContext, size: Int, top: CGColor, bottom: CGColor) {
    let s = CGFloat(size)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
}

/// A globe: outer ring, equator + prime-meridian lines, and one ellipse on each
/// axis — the classic browser glyph. Inner lines are clipped to the ring.
func drawGlobe(in context: CGContext, size: Int, color: CGColor) {
    let s = CGFloat(size)
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = s * 0.33
    let circleRect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)

    context.saveGState()
    context.setStrokeColor(color)
    context.setLineCap(.round)

    // Inner graticule, clipped to the globe.
    context.saveGState()
    context.addEllipse(in: circleRect)
    context.clip()
    context.setLineWidth(s * 0.032)

    let lines = CGMutablePath()
    lines.move(to: CGPoint(x: c.x, y: c.y - r));  lines.addLine(to: CGPoint(x: c.x, y: c.y + r))   // meridian
    lines.move(to: CGPoint(x: c.x - r, y: c.y));  lines.addLine(to: CGPoint(x: c.x + r, y: c.y))   // equator
    context.addPath(lines)
    context.strokePath()

    context.addEllipse(in: CGRect(x: c.x - r * 0.5, y: c.y - r, width: r, height: 2 * r))          // vertical oval
    context.addEllipse(in: CGRect(x: c.x - r, y: c.y - r * 0.5, width: 2 * r, height: r))          // horizontal oval
    context.strokePath()
    context.restoreGState()

    // Crisp outer ring on top.
    context.setLineWidth(s * 0.05)
    context.addEllipse(in: circleRect)
    context.strokePath()
    context.restoreGState()
}

func render(filename: String, background: (top: CGColor, bottom: CGColor)?, glyph: CGColor) {
    let context = makeContext(size: canvas)
    if let background {
        fillGradient(in: context, size: canvas, top: background.top, bottom: background.bottom)
    } else {
        context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }
    drawGlobe(in: context, size: canvas, color: glyph)
    savePNG(context, to: outDir.appendingPathComponent(filename))
}

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}
let white = rgb(1, 1, 1)

// MARK: - SVG source of truth

func writeSVG(to url: URL) throws {
    let s = Double(canvas)
    let c = s / 2
    let r = s * 0.33
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
      <defs>
        <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0" stop-color="rgb(16%,49%,96%)"/>
          <stop offset="1" stop-color="rgb(10%,30%,78%)"/>
        </linearGradient>
      </defs>
      <rect width="\(canvas)" height="\(canvas)" fill="url(#bg)"/>
      <g fill="none" stroke="white" stroke-linecap="round">
        <g stroke-width="\(s * 0.032)">
          <line x1="\(c)" y1="\(c - r)" x2="\(c)" y2="\(c + r)"/>
          <line x1="\(c - r)" y1="\(c)" x2="\(c + r)" y2="\(c)"/>
          <ellipse cx="\(c)" cy="\(c)" rx="\(r * 0.5)" ry="\(r)"/>
          <ellipse cx="\(c)" cy="\(c)" rx="\(r)" ry="\(r * 0.5)"/>
        </g>
        <circle cx="\(c)" cy="\(c)" r="\(r)" stroke-width="\(s * 0.05)"/>
      </g>
    </svg>

    """
    try svg.data(using: .utf8)!.write(to: url, options: .atomic)
}

// MARK: - Contents.json

func writeContentsJSON() throws {
    let contents = Contents(
        images: [
            IconImage(appearances: nil, filename: "icon-light.png", idiom: "universal", platform: "ios", size: "1024x1024"),
            IconImage(
                appearances: [Appearance(appearance: "luminosity", value: "dark")],
                filename: "icon-dark.png", idiom: "universal", platform: "ios", size: "1024x1024"),
            IconImage(
                appearances: [Appearance(appearance: "luminosity", value: "tinted")],
                filename: "icon-tinted.png", idiom: "universal", platform: "ios", size: "1024x1024"),
        ],
        info: Info(author: "xcode", version: 1))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(contents)
    data.append(0x0A)
    try data.write(to: outDir.appendingPathComponent("Contents.json"), options: .atomic)
}

// MARK: - Run

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

render(filename: "icon-light.png", background: (rgb(0.16, 0.49, 0.96), rgb(0.10, 0.30, 0.78)), glyph: white)
render(filename: "icon-dark.png", background: (rgb(0.10, 0.13, 0.30), rgb(0.03, 0.05, 0.16)), glyph: rgb(0.85, 0.92, 1.0))
render(filename: "icon-tinted.png", background: nil, glyph: white)
try writeSVG(to: repoRoot.appendingPathComponent("icon.svg"))
try writeContentsJSON()

print("rendered icons to \(outDir.path)")
