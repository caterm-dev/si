#!/usr/bin/env swift
// Generates SI's original text-only input-source icon. Run from the repository root.
import AppKit

let size = NSSize(width: 32, height: 32)
let image = NSImage(size: size, flipped: false) { bounds in
    let text = "SI" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2,
                          y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
    return true
}
guard let data = image.tiffRepresentation else {
    fatalError("Could not render the input-source icon.")
}
let destination = URL(filePath: FileManager.default.currentDirectoryPath)
    .appending(path: "mac/SI/Resources/InputSourceIcon.tiff")
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: destination)
print("Generated \(destination.path)")
