#!/usr/bin/env swift
// Generates SI's original rounded input-source badge. Run from the repository root.
import AppKit
import CoreText

// Input-source icons use a 16-point canvas, with separate 1x/2x bitmap representations.
// Center the visible glyphs rather than the font's line box (which includes baseline padding).
let size = NSSize(width: 16, height: 16)
func renderIcon(foreground: NSColor, background: NSColor) throws -> Data {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SI", attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        .foregroundColor: foreground,
    ]))
    let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let representations: [NSBitmapImageRep] = try [1, 2].map { scale in
        let pixels = Int(size.width) * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.coderInvalidValue)
        }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let badge = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 15, height: 15),
                           cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.setFillColor(background.cgColor)
        context.addPath(badge)
        context.fillPath()
        context.textPosition = CGPoint(x: (size.width - inkBounds.width) / 2 - inkBounds.minX,
                                       y: (size.height - inkBounds.height) / 2 - inkBounds.minY)
        CTLineDraw(line, context)
        guard let bitmap = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        let representation = NSBitmapImageRep(cgImage: bitmap)
        representation.size = size
        return representation
    }
    guard let data = NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
    }
    return data
}
let directory = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "mac/SI/Resources")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let charcoal = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
for (filename, foreground, background) in [
    ("InputSourceIcon.tiff", NSColor.white, charcoal),
    ("InputSourceIconSelected.tiff", charcoal, NSColor.white),
] {
    let destination = directory.appending(path: filename)
    try renderIcon(foreground: foreground, background: background).write(to: destination)
    print("Generated \(destination.path)")
}
