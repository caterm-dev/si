#!/usr/bin/env swift
// Generates SI's original text-only input-source icon. Run from the repository root.
import AppKit
import CoreText

// Input-source icons use a 16-point canvas, with separate 1x/2x bitmap representations.
// Center the visible glyphs rather than the font's line box (which includes baseline padding).
let size = NSSize(width: 16, height: 16)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SI", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
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
    context.textPosition = CGPoint(x: (size.width - inkBounds.width) / 2 - inkBounds.minX,
                                   y: (size.height - inkBounds.height) / 2 - inkBounds.minY)
    CTLineDraw(line, context)
    guard let bitmap = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
    let representation = NSBitmapImageRep(cgImage: bitmap)
    representation.size = size
    return representation
}
guard let data = NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [:]) else {
    fatalError("Could not render the input-source icon.")
}
let destination = URL(filePath: FileManager.default.currentDirectoryPath)
    .appending(path: "mac/SI/Resources/InputSourceIcon.tiff")
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: destination)
print("Generated \(destination.path)")
