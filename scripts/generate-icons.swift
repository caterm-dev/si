#!/usr/bin/env swift
// Generates SI's original input-source template badge. Run from the repository root.
import AppKit
import CoreText

// Input-source icons use a 16-point canvas, with separate 1x/2x bitmap representations.
// Center the visible glyphs rather than the font's line box (which includes baseline padding).
let size = NSSize(width: 16, height: 16)
func renderIcon() throws -> Data {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SI", attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        .foregroundColor: NSColor.black,
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
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(badge)
        context.fillPath()
        // A template is an alpha mask: cut letters out instead of painting them opaque white.
        // This keeps the badge and readable lettering when macOS tints the menu-bar image.
        context.setBlendMode(.destinationOut)
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
let destination = directory.appending(path: "InputSourceIconTemplate.tiff")
try renderIcon().write(to: destination)
print("Generated \(destination.path)")
