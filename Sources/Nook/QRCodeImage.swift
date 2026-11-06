import AppKit
import CoreImage
import SwiftUI

// A QR code as a picture, for what a person has to carry from the Mac to another device: Nook Remoto's pairing link (`RemoteSettingsPane`).
//
// Core Image's `CIQRCodeGenerator` makes the code: one pixel to a module, with a quiet border of a single module, which is less of a margin than a scanner is promised (the standard
// asks for four). Its modules are read back from that picture and drawn again here at a whole number of device pixels each, with the full quiet zone, black on white whatever the
// theme. Nothing is scaled, so every module has the same size and hard edges, which is what a camera held at arm's length needs from a screen. The code is made at level M, the usual
// one: on a screen there is no dirt to survive, only glare, and a higher level would only make the modules smaller.
//
//   QRCode       the modules and the picture (plain values and Core Graphics, so the tests read the picture back with the system's own detector)
//   QRCodeView   the picture on its white paper, as large as a whole number of the screen's pixels to a module lets it be

enum QRCode {
    /// Modules of white around the symbol, which the QR standard asks for.
    static let quietZone = 4

    /// A code is a few dozen pixels: the processor draws it, with no need to wake the graphics card.
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// The dark modules of the code for `text`, row by row from the top; nil when the text does not fit in a code or Core Image cannot make one.
    static func modules(for text: String) -> [[Bool]]? {
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, let picture = context.createCGImage(output, from: output.extent) else { return nil }
        let width = picture.width, height = picture.height
        guard width == height, width > 2 else { return nil }
        // One pixel to a module, drawn into a bitmap whose rows run from the top.
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            bitmap.interpolationQuality = .none
            bitmap.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The symbol is what is dark: its box is found, whatever border the generator leaves around it.
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxX - minX == maxY - minY else { return nil }
        return (minY...maxY).map { y in (minX...maxX).map { x in pixels[y * width + x] < 128 } }
    }

    /// How many modules a side of the picture has: the symbol's and the quiet zone's on both sides.
    static func modulesAcross(_ modules: [[Bool]]) -> Int { modules.count + 2 * quietZone }

    /// The whole number of pixels to a module that makes the picture as large as it can be within `side` points on a screen of `scale` pixels to the point (1 at the least).
    static func pixelsPerModule(fitting side: CGFloat, scale: CGFloat, modulesAcross: Int) -> Int {
        guard modulesAcross > 0, side > 0, scale > 0 else { return 1 }
        return max(1, Int((side * scale / CGFloat(modulesAcross)).rounded(.down)))
    }

    /// The picture of `modules` with the quiet zone around them, `pixelsPerModule` pixels to a module, black on white.
    static func image(modules: [[Bool]], pixelsPerModule: Int) -> CGImage? {
        guard !modules.isEmpty, pixelsPerModule > 0 else { return nil }
        let across = modulesAcross(modules), side = across * pixelsPerModule
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        bitmap.setShouldAntialias(false)
        bitmap.interpolationQuality = .none
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: side, height: side))
        bitmap.setFillColor(gray: 0, alpha: 1)
        for (row, line) in modules.enumerated() {
            for (column, dark) in line.enumerated() where dark {
                // Core Graphics counts up from the bottom: the first row is the top one.
                bitmap.fill(CGRect(x: (column + quietZone) * pixelsPerModule, y: side - (row + quietZone + 1) * pixelsPerModule, width: pixelsPerModule, height: pixelsPerModule))
            }
        }
        return bitmap.makeImage()
    }

    /// The picture for `text`, `pixelsPerModule` pixels to a module.
    static func image(for text: String, pixelsPerModule: Int) -> CGImage? {
        modules(for: text).flatMap { image(modules: $0, pixelsPerModule: pixelsPerModule) }
    }

    /// The picture for `text` as large as a whole number of pixels to a module lets it be within `side` points, and where in a square of `side` points it goes so that its pixels
    /// land on the screen's (`inset`, from the top and the left).
    static func picture(for text: String, fitting side: CGFloat, scale: CGFloat) -> (image: CGImage, points: CGFloat, inset: CGFloat)? {
        guard let modules = modules(for: text) else { return nil }
        let step = pixelsPerModule(fitting: side, scale: scale, modulesAcross: modulesAcross(modules))
        guard let image = image(modules: modules, pixelsPerModule: step) else { return nil }
        let pixels = CGFloat(image.width), scale = max(scale, 1)
        return (image, pixels / scale, ((side * scale - pixels) / 2).rounded(.down) / scale)
    }
}

/// A code on its white paper: `side` points square, rounded, with the picture centred on the screen's pixels. The paper is white in both themes (a scanner reads dark on light, and
/// the quiet zone is part of the picture), with a hairline so it does not vanish into the light theme's card. It is one element for VoiceOver, with `label` and `value`.
struct QRCodeView: View {
    var text: String
    var side: CGFloat
    var label: String
    var value: String
    /// What the paper says when the code cannot be drawn.
    var missing: String
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color.white)
            if let picture = QRCode.picture(for: text, fitting: side, scale: scale) {
                Image(decorative: picture.image, scale: max(scale, 1)).resizable().interpolation(.none)
                    .frame(width: picture.points, height: picture.points)
                    .padding(.leading, picture.inset).padding(.top, picture.inset)
            } else {
                Text(missing).font(.system(size: 10.5)).foregroundStyle(Color.black.opacity(0.6)).multilineTextAlignment(.center).padding(20)
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .overlay(shape.strokeBorder(Color.nookWash(0.14), lineWidth: 0.6))
        // The settings card puts a shadow on everything inside it, a leaf at a time: left like that, the opaque picture would cast its own over the paper's margin. As one piece, only the paper does.
        .compositingGroup()
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isImage).accessibilityLabel(label).accessibilityValue(value)
    }
}
