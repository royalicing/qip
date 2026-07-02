import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: swift tools/generate-photo-light-table-assets.swift <input-dir> <output-dir> [texture-size]\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: args[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: args[2], isDirectory: true)
let textureSize = args.count >= 4 ? (Int(args[3]) ?? 128) : 128
guard textureSize > 0 else {
    fputs("texture-size must be positive\n", stderr)
    exit(2)
}

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let inputFiles = try FileManager.default.contentsOfDirectory(
    at: inputURL,
    includingPropertiesForKeys: nil
).filter { url in
    let ext = url.pathExtension.lowercased()
    return ext == "jpg" || ext == "jpeg" || ext == "png"
}.sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !inputFiles.isEmpty else {
    fputs("no input photos found in \(inputURL.path)\n", stderr)
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

for (index, sourceURL) in inputFiles.enumerated() {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fputs("failed to decode \(sourceURL.path)\n", stderr)
        exit(1)
    }

    let side = min(image.width, image.height)
    let cropX = (image.width - side) / 2
    let cropY = (image.height - side) / 2
    let cropRect = CGRect(x: cropX, y: cropY, width: side, height: side)
    guard let cropped = image.cropping(to: cropRect) else {
        fputs("failed to crop \(sourceURL.path)\n", stderr)
        exit(1)
    }

    var pixels = [UInt8](repeating: 0, count: textureSize * textureSize * 4)
    let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
        guard let base = ptr.baseAddress,
              let ctx = CGContext(
                data: base,
                width: textureSize,
                height: textureSize,
                bitsPerComponent: 8,
                bytesPerRow: textureSize * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
              ) else {
            return false
        }

        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: textureSize, height: textureSize))
        return true
    }

    guard ok else {
        fputs("failed to rasterize \(sourceURL.path)\n", stderr)
        exit(1)
    }

    var output = Data([
        0, 0, 2,
        0, 0, 0, 0, 0,
        0, 0,
        0, 0,
        UInt8(textureSize & 0xFF), UInt8((textureSize >> 8) & 0xFF),
        UInt8(textureSize & 0xFF), UInt8((textureSize >> 8) & 0xFF),
        32,
        0x28,
    ])
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        output.append(pixels[offset + 2])
        output.append(pixels[offset + 1])
        output.append(pixels[offset])
        output.append(pixels[offset + 3])
    }

    let outputName = String(format: "%02d.tga", index)
    let destination = outputURL.appendingPathComponent(outputName)
    try output.write(to: destination, options: .atomic)
    print("\(sourceURL.lastPathComponent) -> \(destination.path)")
}
