//
//  ConversionLogicBW.swift
//  Negative Conversion
//
//  Created by Ari Jaaksi on 25.9.2025.
//
// Copyright (C) 2025 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.


import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers


// MARK: - Balanced mode tuning parameters
//
// Same philosophy as ConversionLogicColor — see that file for full comments.
// BW images use luminance directly (single channel), no Lab conversion needed.

private let bwTargetMedian:          Double = 0.78   // 0.0–1.0, middle grey
private let bwMaxBrightnessCorrection: Double = 0.65  // fraction of distance to target applied
private let bwTargetStd:             Double = 0.22   // luminance std dev target for contrast boost
private let bwMaxContrastK:          Float  = 6.0    // sigmoid steepness cap
private let bwContrastDeadzone:      Double = 0.85   // fraction of targetStd below which boost kicks in

// MARK: - Enums
enum ProcessingErrorBW: LocalizedError {
    case failedToLoadImage
    case failedToProcessImage
    case failedToAccessFile
    case failedToLoadRAWImage
    case failedToCreateCGImage
    case failedToCreateDestination
    case failedToSaveImage

    var errorDescription: String? {
        switch self {
        case .failedToLoadImage:         return "Failed to load image file"
        case .failedToProcessImage:      return "Failed to process image"
        case .failedToAccessFile:        return "Failed to access file"
        case .failedToLoadRAWImage:      return "Failed to load RAW image"
        case .failedToCreateCGImage:     return "Failed to create output image"
        case .failedToCreateDestination: return "Failed to create output file destination"
        case .failedToSaveImage:         return "Failed to save processed image"
        }
    }
}

// MARK: - BW Image Processor
class ImageProcessorBW {

    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace:  CGColorSpaceCreateDeviceRGB()
    ])

    // MARK: - Convert Negative (original, untouched)

    func convertImageBW(sourceURL: URL, outputDirectory: URL, outputFormat: OutputFormat = .jpeg, brightnessAdjust: Double = 0.0, contrastAdjust: Double = 0.0, saturationAdjust: Double = 0.0) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("⚫ BW Processing: \(sourceURL.lastPathComponent)")

        let inputImage = try loadImageBW(from: sourceURL)
        print("✓ BW Loaded: \(inputImage.extent.width)x\(inputImage.extent.height)")

        let grayNegative = try toGrayscaleKernel(inputImage)
        print("✓ BW Grayscale done")

        let (darkPoint, brightPoint) = try sampleEndpoints(grayNegative)
        print("📊 BW Negative — darkPoint: \(String(format: "%.4f", darkPoint))  brightPoint: \(String(format: "%.4f", brightPoint))")

        let stretchedNegative = try stretchKernel(grayNegative, lo: darkPoint, hi: brightPoint)
        print("✓ BW Negative stretched")

        let positive = try invertKernel(stretchedNegative)
        print("✓ BW Inverted to positive")

        var finalImage: CIImage = positive
        if brightnessAdjust != 0.0 || contrastAdjust != 0.0 {
            finalImage = try applyManualAdjustmentsBW(finalImage,
                brightness: brightnessAdjust, contrast: contrastAdjust)
            print("✓ BW Manual adjustments applied")
        }

        let outputURL = generateOutputURL(from: sourceURL, outputDirectory: outputDirectory, suffix: "_p", outputFormat: outputFormat)
        try saveImageBW(finalImage, to: outputURL, sourceURL: sourceURL, outputFormat: outputFormat)
        print("✓ BW Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Enhance Positive (new)

    func enhancePositiveBW(sourceURL: URL, outputDirectory: URL, outputFormat: OutputFormat = .jpeg, brightnessAdjust: Double = 0.0, contrastAdjust: Double = 0.0, saturationAdjust: Double = 0.0) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("⚫ BW ENHANCE: \(sourceURL.lastPathComponent)")

        let inputImage = try loadImageBW(from: sourceURL)
        print("✓ BW Enhance Loaded: \(inputImage.extent.width)x\(inputImage.extent.height)")

        let gray = try toGrayscaleKernel(inputImage)
        print("✓ BW Enhance Grayscale done")

        let (darkPoint, brightPoint) = try sampleEndpoints(gray)
        print("📊 BW Enhance — darkPoint: \(String(format: "%.4f", darkPoint))  brightPoint: \(String(format: "%.4f", brightPoint))")

        let stretched = try stretchKernel(gray, lo: darkPoint, hi: brightPoint)
        print("✓ BW Enhance stretched")

        // No inversion — image is already positive

        var finalImage: CIImage = stretched
        if brightnessAdjust != 0.0 || contrastAdjust != 0.0 {
            finalImage = try applyManualAdjustmentsBW(finalImage,
                brightness: brightnessAdjust, contrast: contrastAdjust)
            print("✓ BW Enhance Manual adjustments applied")
        }

        let outputURL = generateOutputURL(from: sourceURL, outputDirectory: outputDirectory, suffix: "_e", outputFormat: outputFormat)
        try saveImageBW(finalImage, to: outputURL, sourceURL: sourceURL, outputFormat: outputFormat)
        print("✓ BW Enhance Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Loading

    private func loadImageBW(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWImageBW(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw ProcessingErrorBW.failedToLoadImage
        }
        return image
    }

    private func loadRAWImageBW(from url: URL) throws -> CIImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ProcessingErrorBW.failedToLoadRAWImage
        }
        // Load full-resolution RAW — no thumbnail, no size cap
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ProcessingErrorBW.failedToLoadRAWImage
        }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Step 1: Grayscale kernel

    private func toGrayscaleKernel(_ image: CIImage) throws -> CIImage {
        let source = """
        kernel vec4 toGray(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);
            float lum = 0.299 * r + 0.587 * g + 0.114 * b;
            return vec4(lum, lum, lum, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image]
        ) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        return out
    }

    // MARK: - Step 2: Sample endpoints (shared by both pipelines)

    private func sampleEndpoints(_ image: CIImage) throws -> (Double, Double) {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(
            scaled,
            from: scaled.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { throw ProcessingErrorBW.failedToProcessImage }

        guard let provider = cgImage.dataProvider,
              let cfData   = provider.data,
              let data     = CFDataGetBytePtr(cfData) else {
            throw ProcessingErrorBW.failedToProcessImage
        }

        let width       = cgImage.width
        let height      = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bpp         = 4

        let x0 = Int(Double(width)  * 0.10);  let x1 = width  - x0
        let y0 = Int(Double(height) * 0.10);  let y1 = height - y0

        var values: [Float] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))

        for y in y0..<y1 {
            for x in x0..<x1 {
                let idx = y * bytesPerRow + x * bpp
                values.append(Float(data[idx]) / 255.0)
            }
        }

        guard values.count > 100 else {
            print("⚠️ BW: too few pixels, using full range")
            return (0.0, 1.0)
        }

        values.sort()
        let n = values.count
        let darkPoint   = Double(values[max(0,   Int(Float(n) * 0.005))])
        let brightPoint = Double(values[min(n-1, Int(Float(n) * 0.995))])
        return (darkPoint, brightPoint)
    }

    // MARK: - Step 3: Stretch kernel (shared by both pipelines)

    private func stretchKernel(_ image: CIImage, lo: Double, hi: Double) throws -> CIImage {
        guard hi > lo + 0.02 else {
            print("⚠️ BW Stretch: range too narrow (\(String(format: "%.4f", hi-lo))), skipping")
            return image
        }

        let gain = Float(1.0 / (hi - lo))
        let bias = Float(-lo / (hi - lo))
        print("📊 BW Stretch: gain=\(String(format: "%.3f", gain))  bias=\(String(format: "%.4f", bias))")

        let source = """
        kernel vec4 stretch(sampler src, float gain, float bias) {
            vec4 px = sample(src, samplerCoord(src));
            float v = clamp(px.r * gain + bias, 0.0, 1.0);
            return vec4(v, v, v, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image, gain as NSNumber, bias as NSNumber]
        ) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        return out
    }

    // MARK: - Step 4: Invert kernel (negative conversion only)

    private func invertKernel(_ image: CIImage) throws -> CIImage {
        let source = """
        kernel vec4 invert(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            float v = 1.0 - px.r;
            return vec4(v, v, v, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image]
        ) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        return out
    }

    // MARK: - Midtone normalization (optional last step)
    // Samples the median pixel value of the inner 80% and applies gamma
    // correction so the median maps to 0.5: output = input ^ (log(0.5) / log(median))

    // Measures median luminance. If far from middle grey, applies a partial gamma nudge.
    private func normalizeMidtonesKernel(_ image: CIImage) throws -> CIImage {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent,
                                                   format: .RGBA8,
                                                   colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cgImage.dataProvider,
              let cfData = provider.data,
              let data = CFDataGetBytePtr(cfData) else { throw ProcessingErrorBW.failedToProcessImage }
        let width = cgImage.width; let height = cgImage.height; let bpr = cgImage.bytesPerRow
        let x0 = Int(Double(width)*0.10); let x1 = width-x0
        let y0 = Int(Double(height)*0.10); let y1 = height-y0
        var values: [Double] = []
        values.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                values.append(Double(data[y*bpr + x*4]) / 255.0)
            }
        }
        values.sort()
        let median = values[values.count / 2]
        let mean   = values.reduce(0,+) / Double(values.count)
        let variance = values.map { ($0-mean)*($0-mean) }.reduce(0,+) / Double(values.count)
        let std = sqrt(variance)
        print("📊 BW Brightness analysis: median=\(String(format:"%.3f",median)) mean=\(String(format:"%.3f",mean)) std=\(String(format:"%.3f",std)) (target=\(bwTargetMedian))")

        let distance = bwTargetMedian - median
        guard abs(distance) > 0.02 else {
            print("ℹ️ BW Brightness: median within 0.02 of target, skipping")
            return image
        }
        let correctedMedian = median + distance * bwMaxBrightnessCorrection
        guard median > 0.01 && median < 0.99 else {
            print("⚠️ BW Brightness: median out of usable range, skipping")
            return image
        }
        let gamma = Float(log(correctedMedian) / log(median))
        print("📊 BW Brightness correction: distance=\(String(format:"%.3f",distance)) correctedTarget=\(String(format:"%.3f",correctedMedian)) gamma=\(String(format:"%.3f",gamma))")

        let source = """
        kernel vec4 normalizeBrightnessBW(sampler src, float gamma) {
            vec4 px = sample(src, samplerCoord(src));
            float v = clamp(px.r, 0.001, 1.0);
            float result = pow(v, gamma);
            return vec4(result, result, result, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else { throw ProcessingErrorBW.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, rect in rect },
                                     arguments: [image, gamma as NSNumber])
        else { throw ProcessingErrorBW.failedToProcessImage }
        return out
    }

    // MARK: - Manual adjustments BW (brightness + contrast only, saturation ignored)

    private func applyManualAdjustmentsBW(_ image: CIImage, brightness: Double, contrast: Double) throws -> CIImage {

        let gamma: Float
        if brightness >= 0 {
            gamma = Float(1.0 - brightness * (1.0 - 0.33))
        } else {
            gamma = Float(1.0 + (-brightness) * (3.0 - 1.0))
        }
        let k = Float(contrast * 6.0)

        print("📊 BW Manual adjustments — brightness gamma=\(String(format:"%.3f",gamma)) contrast k=\(String(format:"%.2f",k))")

        let source = """
        kernel vec4 manualAdjustBW(sampler src, float gamma, float k) {
            vec4 px = sample(src, samplerCoord(src));
            float v = clamp(px.r, 0.001, 0.999);

            // Brightness: gamma
            float vb = pow(v, gamma);

            // Contrast: S-curve (k=0 = no effect)
            float vc;
            if (abs(k) < 0.01) {
                vc = vb;
            } else {
                float s0 = 1.0/(1.0+exp( k*0.5));
                float s1 = 1.0/(1.0+exp(-k*0.5));
                float range = s1 - s0;
                vc = range > 0.001 ? (1.0/(1.0+exp(-k*(vb-0.5)))-s0)/range : vb;
            }
            float result = clamp(vc, 0.0, 1.0);
            return vec4(result, result, result, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else { throw ProcessingErrorBW.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, gamma as NSNumber, k as NSNumber])
        else { throw ProcessingErrorBW.failedToProcessImage }
        return out
    }

    // MARK: - Balance contrast (boost only — never reduces)
    // Measures luminance std of inner 80%. If below threshold, applies S-curve boost.
    // k proportional to how flat the image is, capped at bwMaxContrastK.

    func balanceContrastBW(_ image: CIImage) throws -> CIImage {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent,
                                                   format: .RGBA8,
                                                   colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cgImage.dataProvider,
              let cfData   = provider.data,
              let data     = CFDataGetBytePtr(cfData) else { throw ProcessingErrorBW.failedToProcessImage }
        let width = cgImage.width; let height = cgImage.height; let bpr = cgImage.bytesPerRow
        let x0 = Int(Double(width)*0.10); let x1 = width-x0
        let y0 = Int(Double(height)*0.10); let y1 = height-y0
        var values: [Double] = []
        values.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                values.append(Double(data[y*bpr + x*4]) / 255.0)
            }
        }
        let mean = values.reduce(0,+) / Double(values.count)
        let variance = values.map { ($0-mean)*($0-mean) }.reduce(0,+) / Double(values.count)
        let std = sqrt(variance)
        print("📊 BW Contrast analysis: std=\(String(format:"%.3f",std)) mean=\(String(format:"%.3f",mean)) (target=\(bwTargetStd))")

        let threshold = bwTargetStd * bwContrastDeadzone
        guard std < threshold else {
            print("ℹ️ BW Contrast: std=\(String(format:"%.3f",std)) >= threshold \(String(format:"%.3f",threshold)), skipping")
            return image
        }

        let k = Float(min(bwTargetStd / std * 2.0, Double(bwMaxContrastK)))
        print("📊 BW Contrast boost: std=\(String(format:"%.3f",std)) k=\(String(format:"%.2f",k))")

        let source = """
        kernel vec4 balanceContrastBW(sampler src, float k) {
            vec4 px = sample(src, samplerCoord(src));
            float s0 = 1.0 / (1.0 + exp( k * 0.5));
            float s1 = 1.0 / (1.0 + exp(-k * 0.5));
            float v = clamp(px.r, 0.0, 1.0);
            float result = (1.0 / (1.0 + exp(-k * (v - 0.5))) - s0) / (s1 - s0);
            return vec4(result, result, result, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else { throw ProcessingErrorBW.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, rect in rect },
                                     arguments: [image, k as NSNumber])
        else { throw ProcessingErrorBW.failedToProcessImage }
        return out
    }

    // MARK: - Save as True Grayscale JPEG or TIFF

    private func saveImageBW(_ image: CIImage, to url: URL, sourceURL: URL, outputFormat: OutputFormat) throws {
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)

        // Read source DPI and bit depth
        var dpiW: Double = 72; var dpiH: Double = 72; var bitDepth: Int = 8
        if let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            dpiW     = (props[kCGImagePropertyDPIWidth]  as? Double) ?? 72.0
            dpiH     = (props[kCGImagePropertyDPIHeight] as? Double) ?? 72.0
            bitDepth = (props[kCGImagePropertyDepth]     as? Int)    ?? 8
        }
        print("📐 BW Source metadata: \(Int(dpiW))×\(Int(dpiH)) DPI, \(bitDepth)-bit")

        // Use 16-bit context for TIFF when source is 16-bit
        let use16 = outputFormat == .tiff && bitDepth >= 16
        let bpc   = use16 ? 16 : 8
        let fmt: CIFormat = use16 ? .RGBAh : .RGBA8

        guard let rgbCGImage = context.createCGImage(image, from: image.extent, format: fmt,
                                                      colorSpace: CGColorSpaceCreateDeviceRGB())
        else { throw ProcessingErrorBW.failedToCreateCGImage }

        let grayBmi: UInt32 = use16
            ? CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue
            : CGImageAlphaInfo.none.rawValue

        guard let grayCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bpc,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: grayBmi)
        else { throw ProcessingErrorBW.failedToCreateCGImage }

        grayCtx.draw(rgbCGImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let grayCGImage = grayCtx.makeImage() else {
            throw ProcessingErrorBW.failedToCreateCGImage
        }

        let utType: CFString = outputFormat == .tiff
            ? UTType.tiff.identifier as CFString
            : UTType.jpeg.identifier as CFString

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil)
        else { throw ProcessingErrorBW.failedToCreateDestination }

        if outputFormat == .tiff {
            let destProps: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFXResolution:    NSNumber(value: dpiW),
                kCGImagePropertyTIFFYResolution:    NSNumber(value: dpiH),
                kCGImagePropertyTIFFResolutionUnit: NSNumber(value: 2)
            ] as [CFString: Any]]
            CGImageDestinationSetProperties(destination, destProps as CFDictionary)
            CGImageDestinationAddImage(destination, grayCGImage, nil)
        } else {
            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.95,
                kCGImagePropertyJFIFDictionary: [
                    kCGImagePropertyJFIFXDensity:    NSNumber(value: dpiW),
                    kCGImagePropertyJFIFYDensity:    NSNumber(value: dpiH),
                    kCGImagePropertyJFIFDensityUnit: NSNumber(value: 1)
                ] as [CFString: Any]
            ]
            CGImageDestinationAddImage(destination, grayCGImage, options as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingErrorBW.failedToSaveImage
        }

        let formatName = outputFormat == .tiff ? "TIFF" : "JPEG"
        print("\u{2713} BW: Saved as grayscale \(formatName) (\(w)x\(h), \(bpc)-bit, \(Int(dpiW))dpi)")
    }

    // MARK: - Output URL

    private func generateOutputURL(from sourceURL: URL, outputDirectory: URL, suffix: String, outputFormat: OutputFormat) -> URL {
        let baseName  = sourceURL.deletingPathExtension().lastPathComponent
        let ext       = outputFormat == .tiff ? "tiff" : "jpg"
        var counter   = 1
        var filename  = "\(baseName)\(suffix).\(ext)"
        var outputURL = outputDirectory.appendingPathComponent(filename)
        while FileManager.default.fileExists(atPath: outputURL.path) {
            filename  = "\(baseName)\(suffix)\(counter).\(ext)"
            outputURL = outputDirectory.appendingPathComponent(filename)
            counter  += 1
        }
        return outputURL
    }
}


/*
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

// MARK: - Enums
enum ProcessingErrorBW: LocalizedError {
    case failedToLoadImage
    case failedToProcessImage
    case failedToAccessFile
    case failedToLoadRAWImage
    case failedToCreateCGImage
    case failedToCreateDestination
    case failedToSaveImage

    var errorDescription: String? {
        switch self {
        case .failedToLoadImage:         return "Failed to load image file"
        case .failedToProcessImage:      return "Failed to process image"
        case .failedToAccessFile:        return "Failed to access file"
        case .failedToLoadRAWImage:      return "Failed to load RAW image"
        case .failedToCreateCGImage:     return "Failed to create output image"
        case .failedToCreateDestination: return "Failed to create output file destination"
        case .failedToSaveImage:         return "Failed to save processed image"
        }
    }
}

// MARK: - BW Image Processor
class ImageProcessorBW {

    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace:  CGColorSpaceCreateDeviceRGB()
    ])

    // MARK: - Convert Negative (original, untouched)

    func convertImageBW(sourceURL: URL, outputFormat: OutputFormat = .jpeg) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("⚫ BW Processing: \(sourceURL.lastPathComponent)")

        let inputImage = try loadImageBW(from: sourceURL)
        print("✓ BW Loaded: \(inputImage.extent.width)x\(inputImage.extent.height)")

        let grayNegative = try toGrayscaleKernel(inputImage)
        print("✓ BW Grayscale done")

        let (darkPoint, brightPoint) = try sampleEndpoints(grayNegative)
        print("📊 BW Negative — darkPoint: \(String(format: "%.4f", darkPoint))  brightPoint: \(String(format: "%.4f", brightPoint))")

        let stretchedNegative = try stretchKernel(grayNegative, lo: darkPoint, hi: brightPoint)
        print("✓ BW Negative stretched")

        let positive = try invertKernel(stretchedNegative)
        print("✓ BW Inverted to positive")

        let outputURL = generateOutputURL(from: sourceURL, suffix: "_p", outputFormat: outputFormat)
        try saveImageBW(positive, to: outputURL, outputFormat: outputFormat)
        print("✓ BW Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Enhance Positive (new)

    func enhancePositiveBW(sourceURL: URL, outputFormat: OutputFormat = .jpeg) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("⚫ BW ENHANCE: \(sourceURL.lastPathComponent)")

        let inputImage = try loadImageBW(from: sourceURL)
        print("✓ BW Enhance Loaded: \(inputImage.extent.width)x\(inputImage.extent.height)")

        // Step 1: Grayscale
        let gray = try toGrayscaleKernel(inputImage)
        print("✓ BW Enhance Grayscale done")

        // Step 2: Sample endpoints on the positive directly (no inversion needed)
        let (darkPoint, brightPoint) = try sampleEndpoints(gray)
        print("📊 BW Enhance — darkPoint: \(String(format: "%.4f", darkPoint))  brightPoint: \(String(format: "%.4f", brightPoint))")

        // Step 3: Stretch — image is already a positive, just expand tonal range
        let stretched = try stretchKernel(gray, lo: darkPoint, hi: brightPoint)
        print("✓ BW Enhance stretched")

        // No inversion — image is already positive

        let outputURL = generateOutputURL(from: sourceURL, suffix: "_e", outputFormat: outputFormat)
        try saveImageBW(stretched, to: outputURL, outputFormat: outputFormat)
        print("✓ BW Enhance Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Loading

    private func loadImageBW(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWImageBW(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw ProcessingErrorBW.failedToLoadImage
        }
        return image
    }

    private func loadRAWImageBW(from url: URL) throws -> CIImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ProcessingErrorBW.failedToLoadRAWImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
            return CIImage(cgImage: cgImage)
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ProcessingErrorBW.failedToLoadRAWImage
        }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Step 1: Grayscale kernel

    private func toGrayscaleKernel(_ image: CIImage) throws -> CIImage {
        let source = """
        kernel vec4 toGray(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);
            float lum = 0.299 * r + 0.587 * g + 0.114 * b;
            return vec4(lum, lum, lum, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image]
        ) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        return out
    }

    // MARK: - Step 2: Sample endpoints (shared by both pipelines)

    private func sampleEndpoints(_ image: CIImage) throws -> (Double, Double) {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(
            scaled,
            from: scaled.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { throw ProcessingErrorBW.failedToProcessImage }

        guard let provider = cgImage.dataProvider,
              let cfData   = provider.data,
              let data     = CFDataGetBytePtr(cfData) else {
            throw ProcessingErrorBW.failedToProcessImage
        }

        let width       = cgImage.width
        let height      = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bpp         = 4

        let x0 = Int(Double(width)  * 0.10);  let x1 = width  - x0
        let y0 = Int(Double(height) * 0.10);  let y1 = height - y0

        var values: [Float] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))

        for y in y0..<y1 {
            for x in x0..<x1 {
                let idx = y * bytesPerRow + x * bpp
                values.append(Float(data[idx]) / 255.0)
            }
        }

        guard values.count > 100 else {
            print("⚠️ BW: too few pixels, using full range")
            return (0.0, 1.0)
        }

        values.sort()
        let n = values.count
        let darkPoint   = Double(values[max(0,   Int(Float(n) * 0.005))])
        let brightPoint = Double(values[min(n-1, Int(Float(n) * 0.995))])
        return (darkPoint, brightPoint)
    }

    // MARK: - Step 3: Stretch kernel (shared by both pipelines)

    private func stretchKernel(_ image: CIImage, lo: Double, hi: Double) throws -> CIImage {
        guard hi > lo + 0.02 else {
            print("⚠️ BW Stretch: range too narrow (\(String(format: "%.4f", hi-lo))), skipping")
            return image
        }

        let gain = Float(1.0 / (hi - lo))
        let bias = Float(-lo / (hi - lo))
        print("📊 BW Stretch: gain=\(String(format: "%.3f", gain))  bias=\(String(format: "%.4f", bias))")

        let source = """
        kernel vec4 stretch(sampler src, float gain, float bias) {
            vec4 px = sample(src, samplerCoord(src));
            float v = clamp(px.r * gain + bias, 0.0, 1.0);
            return vec4(v, v, v, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image, gain as NSNumber, bias as NSNumber]
        ) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        return out
    }

    // MARK: - Step 4: Invert kernel (negative conversion only)

    private func invertKernel(_ image: CIImage) throws -> CIImage {
        let source = """
        kernel vec4 invert(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            float v = 1.0 - px.r;
            return vec4(v, v, v, px.a);
        }
        """
        guard let kernel = CIKernel(source: source) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image]
        ) else {
            throw ProcessingErrorBW.failedToProcessImage
        }
        return out
    }

    // MARK: - Save as True Grayscale JPEG or TIFF

    private func saveImageBW(_ image: CIImage, to url: URL, outputFormat: OutputFormat) throws {
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)

        guard let rgbCGImage = context.createCGImage(
            image,
            from: image.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { throw ProcessingErrorBW.failedToCreateCGImage }

        guard let grayCtx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw ProcessingErrorBW.failedToCreateCGImage }

        grayCtx.draw(rgbCGImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let grayCGImage = grayCtx.makeImage() else {
            throw ProcessingErrorBW.failedToCreateCGImage
        }

        let utType: CFString = outputFormat == .tiff
            ? UTType.tiff.identifier as CFString
            : UTType.jpeg.identifier as CFString

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, utType, 1, nil
        ) else { throw ProcessingErrorBW.failedToCreateDestination }

        let options: [CFString: Any] = outputFormat == .tiff
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.95]

        CGImageDestinationAddImage(destination, grayCGImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingErrorBW.failedToSaveImage
        }

        let formatName = outputFormat == .tiff ? "TIFF" : "JPEG"
        print("✓ BW: Saved as grayscale \(formatName) (\(w)x\(h))")
    }

    // MARK: - Output URL

    private func generateOutputURL(from sourceURL: URL, suffix: String, outputFormat: OutputFormat) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName  = sourceURL.deletingPathExtension().lastPathComponent
        let ext       = outputFormat == .tiff ? "tiff" : "jpg"
        var counter   = 1
        var filename  = "\(baseName)\(suffix).\(ext)"
        var outputURL = directory.appendingPathComponent(filename)
        while FileManager.default.fileExists(atPath: outputURL.path) {
            filename  = "\(baseName)\(suffix)\(counter).\(ext)"
            outputURL = directory.appendingPathComponent(filename)
            counter  += 1
        }
        return outputURL
    }
}

*/
