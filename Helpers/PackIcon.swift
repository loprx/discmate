import Foundation
import AppKit

// ICNS container only: keep each pre-sized PNG byte-for-byte, including alpha.
// Modern macOS reads PNG representations for these standard size/scale types.
let arguments = CommandLine.arguments
precondition(arguments.count == 3, "Usage: PackIcon iconset-directory output.icns")
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2])
let entries: [(String, String, Int)] = [
    ("icp4", "icon_16x16.png", 16), ("ic11", "icon_16x16@2x.png", 32),
    ("icp5", "icon_32x32.png", 32), ("ic12", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128), ("ic13", "icon_128x128@2x.png", 256),
    ("ic08", "icon_256x256.png", 256), ("ic14", "icon_256x256@2x.png", 512),
    ("ic09", "icon_512x512.png", 512), ("ic10", "icon_512x512@2x.png", 1024)
]
func chunk(_ kind: String, _ payload: Data) -> Data {
    precondition(payload.count <= Int(UInt32.max) - 8)
    var size = UInt32(payload.count + 8).bigEndian
    var result = Data(kind.utf8)
    withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
}
var content = Data()
for (type, filename, size) in entries {
    let png = try Data(contentsOf: folder.appendingPathComponent(filename))
    guard let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide == size,
          bitmap.pixelsHigh == size, bitmap.hasAlpha else {
        fatalError("Invalid icon representation: \(filename)")
    }
    content.append(chunk(type, png))
}
let icon = chunk("icns", content)
try icon.write(to: output, options: .atomic)
guard let decoded = NSImage(contentsOf: output), decoded.isValid else {
    fatalError("macOS could not decode the generated ICNS")
}
print("ICNS ready: \(entries.count) PNG representations, alpha preserved")
