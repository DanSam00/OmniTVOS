//
//  QRCode.swift
//  NuvioTV
//
//  CoreImage-based QR code rendering (replaces Android's zxing QrCodeGenerator).
//

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import CoreImage.CIFilterBuiltins

enum QRCode {
    /// Generates a crisp QR code image for the given string, or nil on failure.
    static func image(from string: String, scale: CGFloat = 12) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
