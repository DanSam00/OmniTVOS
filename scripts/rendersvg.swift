import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let outW = Int(args[3]) else {
    FileHandle.standardError.write("usage: rendersvg <in.svg> <out.png> <width>\n".data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let image = NSImage(contentsOf: inURL) else {
    FileHandle.standardError.write("could not load SVG\n".data(using: .utf8)!); exit(1)
}
let size = image.size
guard size.width > 0, size.height > 0 else {
    FileHandle.standardError.write("zero size\n".data(using: .utf8)!); exit(1)
}
let outH = Int((Double(outW) * Double(size.height) / Double(size.width)).rounded())

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = NSSize(width: outW, height: outH)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.clear.set()
NSRect(x: 0, y: 0, width: outW, height: outH).fill()
image.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH),
           from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: outURL)
print("rendered \(outW)x\(outH) (svg intrinsic \(Int(size.width))x\(Int(size.height)))")
