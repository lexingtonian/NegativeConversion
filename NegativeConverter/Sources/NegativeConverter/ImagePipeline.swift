import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import NegativeCore

enum PipelineError: LocalizedError {
    case cannotDecode(String)
    case unexpectedPixelFormat(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .cannotDecode(let name):
            return "Could not read \(name). The file may be damaged, or this camera's raw format may not be supported by this version of macOS."
        case .unexpectedPixelFormat(let detail):
            return "Core Image returned an unexpected pixel format (\(detail))."
        case .cannotWrite(let name):
            return "Could not write \(name)."
        }
    }
}

/// File formats the positive can be saved in.
enum OutputFormat: String, CaseIterable, Sendable {
    /// 8 bits per channel, lossy.
    case jpeg
    /// 16 bits per channel, lossless.
    case tiff

    var type: UTType { self == .jpeg ? .jpeg : .tiff }
    var fileExtension: String { self == .jpeg ? "jpg" : "tif" }
}

/// Half-float RGBA pixels in linear light, top row first.
final class HalfImage: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Number of `UInt16` elements from the start of one row to the next.
    let rowStride: Int
    private let data: CFData

    init(width: Int, height: Int, rowStride: Int, data: CFData) {
        self.width = width
        self.height = height
        self.rowStride = rowStride
        self.data = data
    }

    func withPixels<R>(_ body: (UnsafePointer<UInt16>) throws -> R) rethrows -> R {
        let bytes = CFDataGetBytePtr(data)!
        return try bytes.withMemoryRebound(to: UInt16.self, capacity: rowStride * height) { try body($0) }
    }
}

/// Decoding (Core Image), rendering and JPEG writing. Nothing here touches the
/// user interface; everything may be called from a background thread.
enum ImagePipeline {

    /// Linear-light working space with wide primaries. The orange of a colour
    /// negative is very saturated; in a small space such as sRGB its blue
    /// channel would go negative and the density maths would break down.
    static let linearSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static let outputSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .cacheIntermediates: false,
    ])

    /// Long side of the reduced copy used for analysis and on-screen preview.
    static let previewLongSide: CGFloat = 1600

    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "ori",
        "rw2", "rwl", "pef", "srw", "3fr", "fff", "iiq", "mos", "erf", "mrw", "x3f", "dcr", "kdc", "gpr",
    ]

    static func isRaw(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .rawImage) { return true }
        return false
    }

    static func isSupportedImage(_ url: URL) -> Bool {
        if isRaw(url) { return true }
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            return type.conforms(to: .image)
        }
        return false
    }

    // MARK: Decoding

    /// Loads an image as linear light.
    ///
    /// Raw files are developed "flat": no tone curve, no local tone mapping and
    /// a fixed white balance, so pixel values stay proportional to the light
    /// that came through the film. That proportionality is what makes the
    /// density calculations meaningful. JPEG and TIFF files are simply decoded;
    /// whatever tone curve the camera or scanner software baked in cannot be
    /// undone, so raw files give the most faithful results.
    static func loadLinear(url: URL, previewLongSide: CGFloat?) throws -> CIImage {
        if isRaw(url), let filter = CIRAWFilter(imageURL: url) {
            filter.boostAmount = 0                 // no tone curve: linear response
            // By default Core Image subtracts a small constant from every pixel
            // to deepen the blacks. On a negative the densest parts are nearly
            // black, so that constant removes a large share of their light
            // (most of the blue channel under an orange mask) and the measured
            // densities come out far too high.
            filter.shadowBias = 0
            filter.isGamutMappingEnabled = false
            if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
            // A fixed daylight balance instead of the camera's guess, so the
            // same film always decodes the same way.
            filter.neutralTemperature = 5000
            filter.neutralTint = 0
            if let target = previewLongSide {
                filter.isDraftModeEnabled = true
                let native = max(filter.nativeSize.width, filter.nativeSize.height)
                if native > 0 {
                    // Decode at roughly twice the preview size; the rest of the
                    // reduction is done with a proper resampling filter.
                    filter.scaleFactor = Float(min(1, max(0.05, 2 * target / native)))
                }
            }
            if let image = filter.outputImage, !image.extent.isInfinite, !image.extent.isEmpty {
                return image
            }
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              !image.extent.isInfinite, !image.extent.isEmpty else {
            throw PipelineError.cannotDecode(url.lastPathComponent)
        }
        return image
    }

    /// Renders a Core Image image into half-float pixels in `linearSpace`.
    static func render(_ image: CIImage, rect: CGRect) throws -> HalfImage {
        guard rect.width >= 1, rect.height >= 1,
              let cg = context.createCGImage(image, from: rect, format: .RGBAh,
                                             colorSpace: linearSpace, deferred: false) else {
            throw PipelineError.cannotDecode("image")
        }
        let info = cg.bitmapInfo
        let alpha = cg.alphaInfo
        guard cg.bitsPerComponent == 16, cg.bitsPerPixel == 64,
              info.contains(.floatComponents),
              info.intersection(.byteOrderMask) != .byteOrder16Big,
              alpha == .premultipliedLast || alpha == .last || alpha == .noneSkipLast,
              let data = cg.dataProvider?.data else {
            throw PipelineError.unexpectedPixelFormat(
                "\(cg.bitsPerComponent) bits per component, \(cg.bitsPerPixel) bits per pixel, bitmap info \(info.rawValue)")
        }
        return HalfImage(width: cg.width, height: cg.height, rowStride: cg.bytesPerRow / 2, data: data)
    }

    /// Reduced-size linear copy of the image, for analysis and preview.
    static func makePreview(url: URL) throws -> HalfImage {
        var image = try loadLinear(url: url, previewLongSide: previewLongSide)
        let extent = image.extent
        let scale = previewLongSide / max(extent.width, extent.height)
        var rect = extent.integral
        if scale < 1 {
            // Clamp first so the resampling filter does not blend the outermost
            // pixels with transparency and create a dark rim.
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image.clampedToExtent()
            filter.scale = Float(scale)
            filter.aspectRatio = 1
            if let scaled = filter.outputImage {
                image = scaled
                let x0 = (extent.minX * scale).rounded(.up)
                let y0 = (extent.minY * scale).rounded(.up)
                let x1 = (extent.maxX * scale).rounded(.down)
                let y1 = (extent.maxY * scale).rounded(.down)
                rect = CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
            }
        }
        return try render(image, rect: rect)
    }

    // MARK: Conversion

    /// Converts the preview copy with the given settings.
    static func renderPreview(_ preview: HalfImage, analysis: NegativeAnalysis,
                              settings: ConversionSettings) -> CGImage? {
        let recipe = ConversionRecipe(analysis: analysis, settings: settings)
        let width = preview.width
        let height = preview.height
        let bytesPerRow = width * 4
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        preview.withPixels { source in
            recipe.convertConcurrently(half: source, width: width, height: height, rowStride: preview.rowStride,
                                       output: output, outputRowBytes: bytesPerRow)
        }
        return makeImage(taking: output, width: width, height: height)
    }

    /// Converts the full-resolution file and writes it in the given format.
    ///
    /// The output has exactly as many pixels as the decoded original, and the
    /// original's print resolution (dots per inch), when it states one.
    static func export(source: URL, analysis: NegativeAnalysis, settings: ConversionSettings,
                       destination: URL, format: OutputFormat, quality: Double) throws {
        let recipe = ConversionRecipe(analysis: analysis, settings: settings)
        let positive: CGImage
        do {
            // Scoped so the large linear buffer is released before encoding.
            let image = try loadLinear(url: source, previewLongSide: nil)
            let half = try render(image, rect: image.extent.integral)
            let width = half.width
            let height = half.height
            let made: CGImage?
            switch format {
            case .jpeg:
                let bytesPerRow = width * 4
                let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
                half.withPixels { pixels in
                    recipe.convertConcurrently(half: pixels, width: width, height: height,
                                               rowStride: half.rowStride,
                                               output: output, outputRowBytes: bytesPerRow)
                }
                made = makeImage(taking: output, width: width, height: height)
            case .tiff:
                let rowElements = width * 3
                let output = UnsafeMutablePointer<UInt16>.allocate(capacity: rowElements * height)
                half.withPixels { pixels in
                    recipe.convertConcurrently16(half: pixels, width: width, height: height,
                                                 rowStride: half.rowStride,
                                                 output: output, outputRowElements: rowElements)
                }
                made = makeImage16(taking: output, width: width, height: height)
            }
            guard let made else { throw PipelineError.cannotWrite(destination.lastPathComponent) }
            positive = made
        }
        guard let target = CGImageDestinationCreateWithURL(destination as CFURL,
                                                           format.type.identifier as CFString, 1, nil) else {
            throw PipelineError.cannotWrite(destination.lastPathComponent)
        }
        var properties: [CFString: Any] = [:]
        switch format {
        case .jpeg:
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        case .tiff:
            // LZW: lossless, and read by everything.
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        }
        if let dpi = printResolution(of: source) {
            properties[kCGImagePropertyDPIWidth] = dpi.width
            properties[kCGImagePropertyDPIHeight] = dpi.height
        }
        CGImageDestinationAddImage(target, positive, properties as CFDictionary)
        guard CGImageDestinationFinalize(target) else {
            throw PipelineError.cannotWrite(destination.lastPathComponent)
        }
    }

    /// Dots per inch stated by a file, if it states any.
    static func printResolution(of url: URL) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Wraps 16-bit RGB pixels (sRGB, three values per pixel) in a CGImage.
    /// Takes ownership of `words`.
    private static func makeImage16(taking words: UnsafeMutablePointer<UInt16>, width: Int, height: Int) -> CGImage? {
        let count = width * height * 6
        let data = Data(bytesNoCopy: words, count: count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little)
        return CGImage(width: width, height: height,
                       bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                       space: outputSpace, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Wraps 8-bit RGBX pixels (sRGB) in a CGImage. Takes ownership of `bytes`.
    private static func makeImage(taking bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> CGImage? {
        let count = width * height * 4
        let data = Data(bytesNoCopy: bytes, count: count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: outputSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
