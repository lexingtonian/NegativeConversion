//
//  ConversionLogicColor.swift
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
// Brightness: nudges mean L toward targetLMean (50.0 = middle grey in Lab).
// maxBrightnessCorrection: fraction of the distance to target actually applied.
// 0.0 = no effect, 1.0 = full push to middle grey. 0.35 = gentle nudge.
//
// Contrast: boosts contrast only when L std dev is below targetLStd (flat image).
// Images at or above targetLStd are left untouched.
// maxContrastK: caps sigmoid steepness (higher = stronger S-curve effect).
// contrastDeadzone: images within this fraction of targetLStd get no boost.

private let targetLMean:          Double = 78.0  // Lab L*, middle grey
private let maxBrightnessCorrection: Double = 0.65  // 0.0–1.0
private let targetLStd:           Double = 22.0  // L* std dev target (flat images boosted toward this)
private let maxContrastK:         Float  = 6.0   // sigmoid steepness cap
private let contrastDeadzone:     Double = 0.85  // fraction of targetLStd below which boost kicks in

// Reference image brightness influence.
// 0.0 = no effect (current behavior — reference brightness ignored entirely)
// 0.5 = moderate nudge toward reference brightness
// 1.0 = full match to reference mean L* (may be too strong)
// Always applied when a reference is present and strength > 0.0.
private let referenceBrightnessStrength: Double = 0.5

// MARK: - Errors

enum ProcessingErrorColor: LocalizedError {
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

// MARK: - Supporting types

struct LabStats {
    var lMean: Double = 0; var lStd: Double = 1
    var aMean: Double = 0; var aStd: Double = 1
    var bMean: Double = 0; var bStd: Double = 1
}

typealias RGBPixel   = (r: Double, g: Double, b: Double)
typealias RGBPixelXY = (x: Double, y: Double, r: Double, g: Double, b: Double)

// MARK: - Color Image Processor

class ImageProcessorColor {

    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace:  CGColorSpaceCreateDeviceRGB()
    ])

    // MARK: - Convert Negative

    func convertImageColor(sourceURL: URL, outputDirectory: URL, referenceURL: URL? = nil, outputFormat: OutputFormat = .jpeg, normalizeMidtones: Bool = false, transferLuminance: Bool = false, balanceContrast: Bool = false, sourceIsGrayscale: Bool = false) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("🎨 COLOR Processing: \(sourceURL.lastPathComponent)")

        let negative = try loadImage(from: sourceURL)
        print("✓ Loaded: \(negative.extent.width)x\(negative.extent.height)")

        let detectedOrange = try detectOrangeFromFilmBase(negative)
        print("🟠 Orange — R:\(String(format:"%.3f",detectedOrange.r)) G:\(String(format:"%.3f",detectedOrange.g)) B:\(String(format:"%.3f",detectedOrange.b))")

        let orangeRemoved = try removeOrange(negative, orange: detectedOrange)
        print("✓ Orange removed")

        let stretchedNegative = try stretchChannels(orangeRemoved)
        print("✓ Tonal stretch done")

        let roughPositive = try invert(stretchedNegative)
        print("✓ Inverted")

        var finalPositive: CIImage
        let loadedReference: CIImage? = referenceURL.flatMap { CIImage(contentsOf: $0) }
        if let refURL = referenceURL, let reference = loadedReference {
            print("📂 Applying reference from: \(refURL.lastPathComponent)")
            if transferLuminance {
                // Color source + BW reference: desaturate then histogram match L
                let desaturated = try desaturate(roughPositive)
                print("✓ Step 1: desaturated")
                finalPositive = try histogramMatchLuminance(desaturated, reference: reference)
                print("✓ Step 2: luminance matched to reference")
            } else if sourceIsGrayscale {
                // BW source + color reference: transfer a+b channels from reference (Lab)
                finalPositive = try applyLabABTransfer(roughPositive, reference: reference)
                print("✓ Lab a+b color transfer applied")
            } else {
                // Color source + color reference: contrast match + color temperature + stretch
                finalPositive = try applyReference(roughPositive, reference: reference)
                print("✓ Reference applied")
            }
        } else {
            finalPositive = roughPositive
            print("ℹ️ No reference — skipping")
        }

        // Apply reference brightness nudge — always applied when reference is present
        if let reference = loadedReference, referenceBrightnessStrength > 0.0 {
            print("📊 Applying reference brightness nudge...")
            finalPositive = try applyReferenceBrightness(finalPositive, reference: reference)
        }

        if normalizeMidtones {
            finalPositive = try normalizeMidtonesColor(finalPositive)
            print("✓ Midtones normalized")
        }
        if balanceContrast {
            finalPositive = try balanceContrastColor(finalPositive)
            print("✓ Contrast balanced")
        }

        let outputURL = generateOutputURL(from: sourceURL, outputDirectory: outputDirectory, suffix: "_p", outputFormat: outputFormat)
        try saveImage(finalPositive, to: outputURL, sourceURL: sourceURL, outputFormat: outputFormat)
        print("✓ Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Enhance Positive

    func enhancePositiveColor(sourceURL: URL, outputDirectory: URL, referenceURL: URL? = nil, outputFormat: OutputFormat = .jpeg, normalizeMidtones: Bool = false, transferLuminance: Bool = false, balanceContrast: Bool = false, sourceIsGrayscale: Bool = false) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("🎨 COLOR ENHANCE: \(sourceURL.lastPathComponent)")

        let positive = try loadImage(from: sourceURL)
        print("✓ Enhance Loaded: \(positive.extent.width)x\(positive.extent.height)")

        let stretched = try stretchChannels(positive)
        print("✓ Enhance tonal stretch done")

        var finalImage: CIImage
        let loadedReferenceE: CIImage? = referenceURL.flatMap { CIImage(contentsOf: $0) }
        if let refURL = referenceURL, let reference = loadedReferenceE {
            print("📂 Enhance applying reference from: \(refURL.lastPathComponent)")
            if transferLuminance {
                // Color source + BW reference: desaturate then histogram match L
                let desaturated = try desaturate(stretched)
                print("✓ Enhance Step 1: desaturated")
                finalImage = try histogramMatchLuminance(desaturated, reference: reference)
                print("✓ Enhance Step 2: luminance matched to reference")
            } else if sourceIsGrayscale {
                // BW source + color reference: transfer a+b channels from reference (Lab)
                finalImage = try applyLabABTransfer(stretched, reference: reference)
                print("✓ Enhance Lab a+b color transfer applied")
            } else {
                // Color source + color reference: contrast match + color temperature + stretch
                finalImage = try applyReference(stretched, reference: reference)
                print("✓ Enhance reference applied")
            }
        } else {
            finalImage = stretched
            print("ℹ️ Enhance no reference — skipping")
        }

        // Apply reference brightness nudge — always applied when reference is present
        if let reference = loadedReferenceE, referenceBrightnessStrength > 0.0 {
            print("📊 Applying enhance reference brightness nudge...")
            finalImage = try applyReferenceBrightness(finalImage, reference: reference)
        }

        if normalizeMidtones {
            finalImage = try normalizeMidtonesColor(finalImage)
            print("✓ Enhance Midtones normalized")
        }
        if balanceContrast {
            finalImage = try balanceContrastColor(finalImage)
            print("✓ Enhance Contrast balanced")
        }

        let outputURL = generateOutputURL(from: sourceURL, outputDirectory: outputDirectory, suffix: "_e", outputFormat: outputFormat)
        try saveImage(finalImage, to: outputURL, sourceURL: sourceURL, outputFormat: outputFormat)
        print("✓ Enhance Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Loading

    private func loadImage(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWImage(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw ProcessingErrorColor.failedToLoadImage
        }
        return image
    }

    private func loadRAWImage(from url: URL) throws -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ProcessingErrorColor.failedToLoadRAWImage
        }
        // Load full-resolution RAW — no thumbnail, no size cap
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProcessingErrorColor.failedToLoadRAWImage
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Orange detection

    private func detectOrangeFromFilmBase(_ image: CIImage) throws -> RGBPixel {
        let pixels = try samplePixels(image, border: 0.10)
        let withLum = pixels.map { p -> (Double, RGBPixel) in
            let lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b
            return (lum, p)
        }.sorted { $0.0 > $1.0 }
        let topCount = max(1, Int(Double(withLum.count) * 0.05))
        let topPixels = withLum.prefix(topCount).map { $0.1 }
        let rAvg = topPixels.map { $0.r }.reduce(0,+) / Double(topPixels.count)
        let gAvg = topPixels.map { $0.g }.reduce(0,+) / Double(topPixels.count)
        let bAvg = topPixels.map { $0.b }.reduce(0,+) / Double(topPixels.count)
        return (r: rAvg, g: gAvg, b: bAvg)
    }

    // MARK: - Orange removal

    private func removeOrange(_ image: CIImage, orange: RGBPixel) throws -> CIImage {
        let rRaw = Float(1.0 / max(orange.r, 0.001))
        let gRaw = Float(1.0 / max(orange.g, 0.001))
        let bRaw = Float(1.0 / max(orange.b, 0.001))
        let maxG = max(rRaw, gRaw, bRaw)
        let rG = rRaw / maxG; let gG = gRaw / maxG; let bG = bRaw / maxG
        print("📊 Orange gains (normalised) — R:\(String(format:"%.3f",rG)) G:\(String(format:"%.3f",gG)) B:\(String(format:"%.3f",bG))")
        let src = """
        kernel vec4 removeOrange(sampler src, float rG, float gG, float bG) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rG,0.0,1.0), clamp(px.g*gG,0.0,1.0), clamp(px.b*bG,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, rG as NSNumber, gG as NSNumber, bG as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Invert

    private func invert(_ image: CIImage) throws -> CIImage {
        let src = """
        kernel vec4 invert(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(1.0-px.r, 1.0-px.g, 1.0-px.b, px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Per-channel tonal stretch

    private func stretchChannels(_ image: CIImage) throws -> CIImage {
        let pixels = try samplePixels(image, border: 0.10)
        var reds   = pixels.map { Float($0.r) }
        var greens = pixels.map { Float($0.g) }
        var blues  = pixels.map { Float($0.b) }
        reds.sort(); greens.sort(); blues.sort()
        let n = reds.count
        let loIdx = max(0,   Int(Float(n) * 0.005))
        let hiIdx = min(n-1, Int(Float(n) * 0.995))
        let rLo = reds[loIdx];   let rHi = reds[hiIdx]
        let gLo = greens[loIdx]; let gHi = greens[hiIdx]
        let bLo = blues[loIdx];  let bHi = blues[hiIdx]
        print("📊 Stretch — R:[\(String(format:"%.3f",rLo)),\(String(format:"%.3f",rHi))] G:[\(String(format:"%.3f",gLo)),\(String(format:"%.3f",gHi))] B:[\(String(format:"%.3f",bLo)),\(String(format:"%.3f",bHi))]")
        let rGain = Float(rHi > rLo + 0.01 ? 1.0 / Double(rHi - rLo) : 1.0)
        let gGain = Float(gHi > gLo + 0.01 ? 1.0 / Double(gHi - gLo) : 1.0)
        let bGain = Float(bHi > bLo + 0.01 ? 1.0 / Double(bHi - bLo) : 1.0)
        let rBias = -rLo * rGain; let gBias = -gLo * gGain; let bBias = -bLo * bGain
        let src = """
        kernel vec4 stretch(sampler src, float rGain, float rBias, float gGain, float gBias, float bGain, float bBias) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rGain+rBias,0.0,1.0), clamp(px.g*gGain+gBias,0.0,1.0), clamp(px.b*bGain+bBias,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, rGain as NSNumber, rBias as NSNumber,
                                                 gGain as NSNumber, gBias as NSNumber,
                                                 bGain as NSNumber, bBias as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Desaturate (drive color to gray in Lab space)

    private func desaturate(_ image: CIImage) throws -> CIImage {
        let src = """
        kernel vec4 desaturate(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            float lum = px.r*0.2126 + px.g*0.7152 + px.b*0.0722;
            return vec4(lum, lum, lum, px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Reference matching
    //
    // Strategy:
    //   1. Sample the middle 80% of the tonal range (ignore darkest+brightest 10%)
    //      from both source and reference — outliers and clipped areas don't influence matching
    //   2. Compute per-channel std deviation from that stable zone
    //      → use std ratio as contrast gain (no bias, no brightness shift)
    //   3. Apply per-channel color temperature correction from the same stable zone
    //      → gains capped at 1.0 so channels can only be pulled down, never clipped up
    //   4. Stretch the output to full [0,1] range per channel
    //      → reference brightness is irrelevant; output always has full tonal range
    //
    // Result: the reference controls contrast shape and color balance only.
    //         Output brightness is always self-determined by the source content.

    private func applyReference(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcPixels = try samplePixels(image, border: 0.15)
        let refPixels = try samplePixels(reference, border: 0.15)

        // ── Helper: filter pixels to middle 80% of luminance ──
        func middlePixels(_ pixels: [RGBPixel]) -> [RGBPixel] {
            let lums = pixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }
            let sorted = lums.sorted()
            let lo = sorted[Int(Float(sorted.count) * 0.10)]
            let hi = sorted[Int(Float(sorted.count) * 0.90)]
            return zip(pixels, lums).compactMap { px, l in
                (l >= lo && l <= hi) ? px : nil
            }
        }

        let srcMid = middlePixels(srcPixels)
        let refMid = middlePixels(refPixels)
        guard !srcMid.isEmpty && !refMid.isEmpty else { return image }

        // ── Per-channel means from stable zone ──
        func mean(_ arr: [RGBPixel], _ ch: KeyPath<RGBPixel, Double>) -> Float {
            Float(arr.map { $0[keyPath: ch] }.reduce(0, +) / Double(arr.count))
        }
        let srcMeanR = mean(srcMid, \.r); let srcMeanG = mean(srcMid, \.g); let srcMeanB = mean(srcMid, \.b)
        let refMeanR = mean(refMid, \.r); let refMeanG = mean(refMid, \.g); let refMeanB = mean(refMid, \.b)

        // ── Per-channel std deviation from stable zone ──
        func std(_ arr: [RGBPixel], _ ch: KeyPath<RGBPixel, Double>, _ m: Float) -> Float {
            let v = arr.map { (Float($0[keyPath: ch]) - m) * (Float($0[keyPath: ch]) - m) }
            return sqrt(v.reduce(0, +) / Float(arr.count))
        }
        let srcStdR = std(srcMid, \.r, srcMeanR); let refStdR = std(refMid, \.r, refMeanR)
        let srcStdG = std(srcMid, \.g, srcMeanG); let refStdG = std(refMid, \.g, refMeanG)
        let srcStdB = std(srcMid, \.b, srcMeanB); let refStdB = std(refMid, \.b, refMeanB)

        // ── Contrast gain per channel (std ratio, capped at 1.5) ──
        // Pivoted around 0.5: output = (input - 0.5) * gain + 0.5
        // = input * gain + (0.5 - 0.5 * gain)
        // This expands contrast symmetrically around the midpoint,
        // so soft negatives don't get pushed entirely into highlights.
        let gainR = srcStdR > 0.001 ? min(refStdR / srcStdR, 1.5) : 1.0
        let gainG = srcStdG > 0.001 ? min(refStdG / srcStdG, 1.5) : 1.0
        let gainB = srcStdB > 0.001 ? min(refStdB / srcStdB, 1.5) : 1.0
        let biasR = 0.5 - 0.5 * gainR
        let biasG = 0.5 - 0.5 * gainG
        let biasB = 0.5 - 0.5 * gainB

        // ── Color temperature: per-channel mean ratio from stable zone, capped at 1.0 ──
        let ctR = srcMeanR > 0.001 ? min(refMeanR / srcMeanR, 1.0) : 1.0
        let ctG = srcMeanG > 0.001 ? min(refMeanG / srcMeanG, 1.0) : 1.0
        let ctB = srcMeanB > 0.001 ? min(refMeanB / srcMeanB, 1.0) : 1.0

        print("📊 Reference match — contrast R:\(String(format:"%.3f",gainR)) G:\(String(format:"%.3f",gainG)) B:\(String(format:"%.3f",gainB))")
        print("📊 Color temp      — gains   R:\(String(format:"%.3f",ctR)) G:\(String(format:"%.3f",ctG)) B:\(String(format:"%.3f",ctB))")

        // ── Step 1: apply contrast (pivot around 0.5) then color temp ──
        // contrast: output = input * gainX + biasX
        // color temp applied after: multiply by ctX
        // combined: output = (input * gainX + biasX) * ctX
        //                  = input * (gainX * ctX) + biasX * ctX
        let rG = gainR * ctR;  let rB = biasR * ctR
        let gG = gainG * ctG;  let gB = biasG * ctG
        let bG = gainB * ctB;  let bB = biasB * ctB

        let gainKernel = """
        kernel vec4 applyGain(sampler src, float rG, float rB, float gG, float gB, float bG, float bB) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(px.r*rG+rB, px.g*gG+gB, px.b*bG+bB, px.a);
        }
        """
        guard let gk = CIKernel(source: gainKernel) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let gained = gk.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image,
                                                 rG as NSNumber, rB as NSNumber,
                                                 gG as NSNumber, gB as NSNumber,
                                                 bG as NSNumber, bB as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }

        // ── Step 2: stretch output to full [0,1] per channel ──
        // Sample the gained image to find actual min/max per channel
        let gainedPixels = try samplePixels(gained, border: 0.01)
        var rs = gainedPixels.map { Float($0.r) }.sorted()
        var gs = gainedPixels.map { Float($0.g) }.sorted()
        var bs = gainedPixels.map { Float($0.b) }.sorted()
        let n = rs.count
        let loIdx = max(0,   Int(Float(n) * 0.005))
        let hiIdx = min(n-1, Int(Float(n) * 0.995))
        let rLo = rs[loIdx]; let rHi = rs[hiIdx]
        let gLo = gs[loIdx]; let gHi = gs[hiIdx]
        let bLo = bs[loIdx]; let bHi = bs[hiIdx]

        let sRG = rHi > rLo + 0.01 ? Float(1.0 / Double(rHi - rLo)) : 1.0
        let sGG = gHi > gLo + 0.01 ? Float(1.0 / Double(gHi - gLo)) : 1.0
        let sBG = bHi > bLo + 0.01 ? Float(1.0 / Double(bHi - bLo)) : 1.0
        let sRB = -rLo * sRG; let sGB = -gLo * sGG; let sBiasB = -bLo * sBG

        print("📊 Output stretch  — R:[\(String(format:"%.3f",rLo)),\(String(format:"%.3f",rHi))] G:[\(String(format:"%.3f",gLo)),\(String(format:"%.3f",gHi))] B:[\(String(format:"%.3f",bLo)),\(String(format:"%.3f",bHi))]")

        let stretchKernel = """
        kernel vec4 stretchOut(sampler src, float rG, float rB, float gG, float gB, float bG, float bB) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rG+rB,0.0,1.0), clamp(px.g*gG+gB,0.0,1.0), clamp(px.b*bG+bB,0.0,1.0), px.a);
        }
        """
        guard let sk = CIKernel(source: stretchKernel) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let stretched = sk.apply(extent: gained.extent, roiCallback: { _, r in r },
                                        arguments: [gained,
                                                    sRG as NSNumber, sRB as NSNumber,
                                                    sGG as NSNumber, sGB as NSNumber,
                                                    sBG as NSNumber, sBiasB as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return stretched
    }

    // MARK: - Lab regional analysis

    private func analyseLabRegions(_ sizeRef: CIImage, image: CIImage) throws -> [LabStats] {
        let pixels = try samplePixelsXY(image, border: 0.10)
        var buckets = Array(repeating: [(Double, Double, Double)](), count: 9)
        for p in pixels {
            let col = min(2, Int(p.x * 3))
            let row = min(2, Int(p.y * 3))
            let lab = rgbToLab(r: p.r, g: p.g, b: p.b)
            buckets[row * 3 + col].append(lab)
        }
        return buckets.map { pts -> LabStats in
            guard !pts.isEmpty else { return LabStats() }
            var s = LabStats()
            s.lMean = pts.map { $0.0 }.reduce(0,+) / Double(pts.count)
            s.aMean = pts.map { $0.1 }.reduce(0,+) / Double(pts.count)
            s.bMean = pts.map { $0.2 }.reduce(0,+) / Double(pts.count)
            s.lStd  = stdDev(pts.map { $0.0 }, mean: s.lMean)
            s.aStd  = stdDev(pts.map { $0.1 }, mean: s.aMean)
            s.bStd  = stdDev(pts.map { $0.2 }, mean: s.bMean)
            return s
        }
    }

    // MARK: - Lab transfer (a+b channels only — preserves source luminance)

    private func applyLabABTransfer(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcStats = try analyseLabRegions(image, image: image)
        let refStats = try analyseLabRegions(image, image: reference)

        func combined(_ s: [LabStats]) -> LabStats {
            let n = Double(s.count)
            var r = LabStats()
            r.lMean = s.map{$0.lMean}.reduce(0,+)/n
            r.aMean = s.map{$0.aMean}.reduce(0,+)/n
            r.bMean = s.map{$0.bMean}.reduce(0,+)/n
            r.lStd  = s.map{$0.lStd }.reduce(0,+)/n
            r.aStd  = s.map{$0.aStd }.reduce(0,+)/n
            r.bStd  = s.map{$0.bStd }.reduce(0,+)/n
            return r
        }

        let src = combined(srcStats)
        let ref = combined(refStats)

        print("📊 Src Lab — L:\(String(format:"%.1f",src.lMean))±\(String(format:"%.1f",src.lStd)) a:\(String(format:"%.1f",src.aMean)) b:\(String(format:"%.1f",src.bMean))")
        print("📊 Ref Lab — L:\(String(format:"%.1f",ref.lMean))±\(String(format:"%.1f",ref.lStd)) a:\(String(format:"%.1f",ref.aMean)) b:\(String(format:"%.1f",ref.bMean))")

        // Transfer a+b only — L untouched (lGain=1, lBias=0)
        let aGain = Float(src.aStd > 0.001 ? ref.aStd / src.aStd : 1.0)
        let bGain = Float(src.bStd > 0.001 ? ref.bStd / src.bStd : 1.0)
        let aBias = Float(ref.aMean - Double(aGain) * src.aMean)
        let bBias = Float(ref.bMean - Double(bGain) * src.bMean)

        print("📊 Lab a+b transfer — aGain:\(String(format:"%.3f",aGain)) aBias:\(String(format:"%.2f",aBias)) bGain:\(String(format:"%.3f",bGain)) bBias:\(String(format:"%.2f",bBias))")

        let kernelSrc = """
        kernel vec4 labABTransfer(sampler src,
                                  float aGain, float aBias,
                                  float bGain, float bBias) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);

            float x = r*0.4124564 + g*0.3575761 + b*0.1804375;
            float y = r*0.2126729 + g*0.7151522 + b*0.0721750;
            float z = r*0.0193339 + g*0.1191920 + b*0.9503041;

            float xn = x/0.95047; float yn = y/1.00000; float zn = z/1.08883;
            float fx = xn > 0.008856 ? pow(xn,0.333333) : 7.787*xn+0.137931;
            float fy = yn > 0.008856 ? pow(yn,0.333333) : 7.787*yn+0.137931;
            float fz = zn > 0.008856 ? pow(zn,0.333333) : 7.787*zn+0.137931;
            float L = 116.0*fy - 16.0;
            float A = 500.0*(fx - fy);
            float B = 200.0*(fy - fz);

            // Transfer a+b only — L unchanged
            A = clamp(A * aGain + aBias, -128.0, 127.0);
            B = clamp(B * bGain + bBias, -128.0, 127.0);

            float fy2 = (L+16.0)/116.0;
            float fx2 = A/500.0 + fy2;
            float fz2 = fy2 - B/200.0;
            float x2 = fx2 > 0.206897 ? fx2*fx2*fx2 : (fx2-0.137931)/7.787;
            float y2 = fy2 > 0.206897 ? fy2*fy2*fy2 : (fy2-0.137931)/7.787;
            float z2 = fz2 > 0.206897 ? fz2*fz2*fz2 : (fz2-0.137931)/7.787;
            x2 *= 0.95047; y2 *= 1.00000; z2 *= 1.08883;

            float ro = x2*3.2404542 - y2*1.5371385 - z2*0.4985314;
            float go = -x2*0.9692660 + y2*1.8760108 + z2*0.0415560;
            float bo = x2*0.0556434 - y2*0.2040259 + z2*1.0572252;

            float knee = 0.9;
            float rs = ro <= knee ? ro : knee + (1.0-knee)*(1.0-exp(-(ro-knee)/(1.0-knee)));
            float gs = go <= knee ? go : knee + (1.0-knee)*(1.0-exp(-(go-knee)/(1.0-knee)));
            float bs = bo <= knee ? bo : knee + (1.0-knee)*(1.0-exp(-(bo-knee)/(1.0-knee)));
            float shadow = 0.1;
            float rf = rs >= shadow ? rs : shadow*(1.0-exp(-rs/shadow));
            float gf = gs >= shadow ? gs : shadow*(1.0-exp(-gs/shadow));
            float bf = bs >= shadow ? bs : shadow*(1.0-exp(-bs/shadow));

            return vec4(clamp(rf,0.0,1.0), clamp(gf,0.0,1.0), clamp(bf,0.0,1.0), px.a);
        }
        """

        guard let kernel = CIKernel(source: kernelSrc) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image,
                        aGain as NSNumber, aBias as NSNumber,
                        bGain as NSNumber, bBias as NSNumber]
        ) else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - RGB → Lab helpers

    private func rgbToLab(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let x = r*0.4124564 + g*0.3575761 + b*0.1804375
        let y = r*0.2126729 + g*0.7151522 + b*0.0721750
        let z = r*0.0193339 + g*0.1191920 + b*0.9503041
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t,1.0/3.0) : 7.787*t+16.0/116.0 }
        let fx = f(x/0.95047); let fy = f(y/1.00000); let fz = f(z/1.08883)
        return (116.0*fy-16.0, 500.0*(fx-fy), 200.0*(fy-fz))
    }

    private func stdDev(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 1.0 }
        let v = values.map { ($0-mean)*($0-mean) }.reduce(0,+) / Double(values.count)
        return max(sqrt(v), 0.001)
    }

    // MARK: - BW luminance matching (used for desaturated color source + BW reference)
    //
    // Same stable-zone philosophy as applyReference:
    // Uses middle 80% of tonal range, contrast gain only (no bias), then stretches output.

    private func histogramMatchLuminance(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcPixels = try samplePixels(image, border: 0.15)
        let refPixels = try samplePixels(reference, border: 0.15)
        let srcLums = srcPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()
        let refLums = refPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()

        // Middle 80% of each
        func middle80(_ arr: [Float]) -> [Float] {
            let lo = arr[Int(Float(arr.count) * 0.10)]
            let hi = arr[Int(Float(arr.count) * 0.90)]
            return arr.filter { $0 >= lo && $0 <= hi }
        }
        let srcMid = middle80(srcLums)
        let refMid = middle80(refLums)
        guard !srcMid.isEmpty && !refMid.isEmpty else { return image }

        let srcMean = srcMid.reduce(0, +) / Float(srcMid.count)
        let refMean = refMid.reduce(0, +) / Float(refMid.count)
        let srcStd  = sqrt(srcMid.map { ($0-srcMean)*($0-srcMean) }.reduce(0,+) / Float(srcMid.count))
        let refStd  = sqrt(refMid.map { ($0-refMean)*($0-refMean) }.reduce(0,+) / Float(refMid.count))

        // Contrast gain, capped at 1.5, pivoted around 0.5
        // output = (input - 0.5) * gain + 0.5 = input * gain + (0.5 - 0.5 * gain)
        let gain = srcStd > 0.001 ? min(refStd / srcStd, 1.5) : 1.0
        let bias = 0.5 - 0.5 * gain

        print("📊 BW luminance match — srcStd: \(String(format:"%.3f",srcStd)) refStd: \(String(format:"%.3f",refStd)) gain: \(String(format:"%.3f",gain))")

        // Build LUT: output = input * gain + bias, clamped
        let bins = 256
        var mapping = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            let x = Float(i) / Float(bins - 1)
            mapping[i] = min(1.0, max(0.0, x * gain + bias))
        }

        // Apply mapping
        let mapped = try applyLuminanceMapping(image, mapping: mapping, bins: bins)

        // Stretch output to full range
        let mappedPixels = try samplePixels(mapped, border: 0.01)
        var lums2 = mappedPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()
        let n = lums2.count
        let loVal = lums2[max(0, Int(Float(n) * 0.005))]
        let hiVal = lums2[min(n-1, Int(Float(n) * 0.995))]
        guard hiVal > loVal + 0.01 else { return mapped }
        let sGain = Float(1.0 / Double(hiVal - loVal))
        let sBias = -loVal * sGain

        print("📊 BW output stretch — [\(String(format:"%.3f",loVal)),\(String(format:"%.3f",hiVal))]")

        let stretchKernel = """
        kernel vec4 stretchBW(sampler src, float sG, float sB) {
            vec4 px = sample(src, samplerCoord(src));
            float v = clamp(px.r*sG+sB, 0.0, 1.0);
            return vec4(v, v, v, px.a);
        }
        """
        guard let sk = CIKernel(source: stretchKernel) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = sk.apply(extent: mapped.extent, roiCallback: { _, r in r },
                                  arguments: [mapped, sGain as NSNumber, sBias as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

        // Apply a 256-entry luminance mapping to full-res image on CPU.
    // Scales RGB channels proportionally to preserve color ratios.
    // Used by the BW reference path (desaturate + L match).
    private func applyLuminanceMapping(_ image: CIImage, mapping: [Float], bins: Int) throws -> CIImage {
        guard let cg = context.createCGImage(image, from: image.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data else {
            throw ProcessingErrorColor.failedToProcessImage
        }

        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let dataLen = h * bpr
        var pixels = [UInt8](repeating: 0, count: dataLen)
        CFDataGetBytes(cfData, CFRange(location: 0, length: dataLen), &pixels)

        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                let r = Float(pixels[i])   / 255.0
                let g = Float(pixels[i+1]) / 255.0
                let b = Float(pixels[i+2]) / 255.0
                let lum = r * 0.2126 + g * 0.7152 + b * 0.0722
                if lum > 0.001 {
                    let bin = min(bins-1, Int(lum * Float(bins)))
                    let ratio = mapping[bin] / lum
                    pixels[i]   = UInt8(min(255, max(0, Int(r * ratio * 255.0 + 0.5))))
                    pixels[i+1] = UInt8(min(255, max(0, Int(g * ratio * 255.0 + 0.5))))
                    pixels[i+2] = UInt8(min(255, max(0, Int(b * ratio * 255.0 + 0.5))))
                } else {
                    // Very dark pixels: map directly via lookup, no ratio needed
                    let mapped = mapping[0]
                    let v = UInt8(min(255, max(0, Int(mapped * 255.0 + 0.5))))
                    pixels[i] = v; pixels[i+1] = v; pixels[i+2] = v
                }
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ProcessingErrorColor.failedToProcessImage
        }
        let data = Data(pixels)
        return try data.withUnsafeBytes { ptr -> CIImage in
            guard let base = ptr.baseAddress,
                  let newProvider = CGDataProvider(dataInfo: nil, data: base, size: dataLen,
                                                   releaseData: { _, _, _ in }),
                  let newCG = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: bpr, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: newProvider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent)
            else { throw ProcessingErrorColor.failedToProcessImage }
            return CIImage(cgImage: newCG)
        }
    }

    // MARK: - Pixel sampling

    private func samplePixels(_ image: CIImage, border: Double) throws -> [RGBPixel] {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data,
              let data = CFDataGetBytePtr(cfData) else { throw ProcessingErrorColor.failedToProcessImage }
        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let x0 = Int(Double(w)*border); let x1 = w-x0
        let y0 = Int(Double(h)*border); let y1 = h-y0
        var result: [RGBPixel] = []
        result.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y*bpr + x*4
                result.append((r: Double(data[i])/255.0,
                               g: Double(data[i+1])/255.0,
                               b: Double(data[i+2])/255.0))
            }
        }
        return result
    }


    private func samplePixelsXY(_ image: CIImage, border: Double) throws -> [RGBPixelXY] {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data,
              let data = CFDataGetBytePtr(cfData) else { throw ProcessingErrorColor.failedToProcessImage }
        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let x0 = Int(Double(w)*border); let x1 = w-x0
        let y0 = Int(Double(h)*border); let y1 = h-y0
        let innerW = Double(x1-x0); let innerH = Double(y1-y0)
        var result: [RGBPixelXY] = []
        result.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y*bpr + x*4
                let nx = Double(x-x0) / innerW
                let ny = Double(y-y0) / innerH
                result.append((x: nx, y: ny,
                               r: Double(data[i])/255.0,
                               g: Double(data[i+1])/255.0,
                               b: Double(data[i+2])/255.0))
            }
        }
        return result
    }

    // MARK: - Reference brightness nudge
    //
    // Measures mean Lab L* of the reference and the source image, computes the
    // difference, and applies a partial gamma correction to the source midtones.
    // Controlled by referenceBrightnessStrength (0.0 = no effect, 1.0 = full match).
    //
    // Works on L channel only in Lab space — highlights near L*=100 and shadows
    // near L*=0 are barely touched, so no information is lost at either end.
    // The final stretch in each reference path runs before this function is called,
    // so this nudge is applied to a fully-stretched image and its effect survives.

    private func applyReferenceBrightness(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcPixels = try samplePixels(image, border: 0.10)
        let refPixels = try samplePixels(reference, border: 0.10)

        let srcLMean = srcPixels.map { rgbToLab(r: $0.r, g: $0.g, b: $0.b).0 }.reduce(0,+) / Double(srcPixels.count)
        let refLMean = refPixels.map { rgbToLab(r: $0.r, g: $0.g, b: $0.b).0 }.reduce(0,+) / Double(refPixels.count)

        print("📊 Ref brightness — srcL=\(String(format:"%.1f",srcLMean)) refL=\(String(format:"%.1f",refLMean)) strength=\(referenceBrightnessStrength)")

        let distance = refLMean - srcLMean
        guard abs(distance) > 1.0 else {
            print("ℹ️ Ref brightness: within 1.0 L* of reference, skipping")
            return image
        }

        // Partial correction: move only a fraction of the distance toward reference L*
        let correctedL = srcLMean + distance * referenceBrightnessStrength
        let lNorm   = srcLMean / 100.0
        let lTarget = correctedL / 100.0
        guard lNorm > 0.01 && lNorm < 0.99 else { return image }

        let gamma = Float(log(lTarget) / log(lNorm))
        print("📊 Ref brightness correction: distance=\(String(format:"%.1f",distance)) correctedL=\(String(format:"%.1f",correctedL)) gamma=\(String(format:"%.3f",gamma))")

        let src = """
        kernel vec4 refBrightnessLab(sampler src, float gamma) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);
            // RGB -> XYZ -> Lab
            float x = r*0.4124564 + g*0.3575761 + b*0.1804375;
            float y = r*0.2126729 + g*0.7151522 + b*0.0721750;
            float z = r*0.0193339 + g*0.1191920 + b*0.9503041;
            float xn=x/0.95047; float yn=y/1.00000; float zn=z/1.08883;
            float fx = xn>0.008856 ? pow(xn,0.333333) : 7.787*xn+0.137931;
            float fy = yn>0.008856 ? pow(yn,0.333333) : 7.787*yn+0.137931;
            float fz = zn>0.008856 ? pow(zn,0.333333) : 7.787*zn+0.137931;
            float L = 116.0*fy - 16.0;
            float A = 500.0*(fx - fy);
            float B = 200.0*(fy - fz);
            // Apply gamma to L only
            float Ln = clamp(L/100.0, 0.001, 0.999);
            float Lnew = clamp(pow(Ln, gamma) * 100.0, 0.0, 100.0);
            // Lab -> XYZ -> RGB
            float fy2 = (Lnew+16.0)/116.0;
            float fx2 = A/500.0 + fy2;
            float fz2 = fy2 - B/200.0;
            float x2 = fx2>0.206897 ? fx2*fx2*fx2 : (fx2-0.137931)/7.787;
            float y2 = fy2>0.206897 ? fy2*fy2*fy2 : (fy2-0.137931)/7.787;
            float z2 = fz2>0.206897 ? fz2*fz2*fz2 : (fz2-0.137931)/7.787;
            x2*=0.95047; y2*=1.00000; z2*=1.08883;
            float ro = x2* 3.2404542 - y2*1.5371385 - z2*0.4985314;
            float go = x2*-0.9692660 + y2*1.8760108 + z2*0.0415560;
            float bo = x2* 0.0556434 - y2*0.2040259 + z2*1.0572252;
            return vec4(clamp(ro,0.0,1.0), clamp(go,0.0,1.0), clamp(bo,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, gamma as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Normalize midtones

    // Measures mean Lab L* of the image. If far from middle grey (50.0),
    // applies a partial gamma correction to L only — a and b channels untouched.
    private func normalizeMidtonesColor(_ image: CIImage) throws -> CIImage {
        let pixels = try samplePixels(image, border: 0.10)
        let lValues = pixels.map { rgbToLab(r: $0.r, g: $0.g, b: $0.b).0 }
        let meanL = lValues.reduce(0, +) / Double(lValues.count)
        let stdL  = stdDev(lValues, mean: meanL)
        print("📊 COLOR Brightness analysis: meanL=\(String(format:"%.1f",meanL)) stdL=\(String(format:"%.1f",stdL)) (target=\(targetLMean))")

        let distance = targetLMean - meanL   // positive = image too dark, negative = too bright
        guard abs(distance) > 2.0 else {
            print("ℹ️ COLOR Brightness: meanL within 2.0 of target, skipping")
            return image
        }

        // Partial correction: move only a fraction of the distance to target
        let correctedMeanL = meanL + distance * maxBrightnessCorrection
        // Express as gamma on L/100 scale
        let lNorm = meanL / 100.0
        let lTarget = correctedMeanL / 100.0
        guard lNorm > 0.01 && lNorm < 0.99 else {
            print("⚠️ COLOR Brightness: meanL out of usable range, skipping")
            return image
        }
        let gamma = Float(log(lTarget) / log(lNorm))
        print("📊 COLOR Brightness correction: distance=\(String(format:"%.1f",distance)) correctedTarget=\(String(format:"%.1f",correctedMeanL)) gamma=\(String(format:"%.3f",gamma))")

        let src = """
        kernel vec4 balanceBrightnessLab(sampler src, float gamma) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);
            // RGB -> XYZ
            float x = r*0.4124564 + g*0.3575761 + b*0.1804375;
            float y = r*0.2126729 + g*0.7151522 + b*0.0721750;
            float z = r*0.0193339 + g*0.1191920 + b*0.9503041;
            // XYZ -> Lab
            float xn=x/0.95047; float yn=y/1.00000; float zn=z/1.08883;
            float fx = xn>0.008856 ? pow(xn,0.333333) : 7.787*xn+0.137931;
            float fy = yn>0.008856 ? pow(yn,0.333333) : 7.787*yn+0.137931;
            float fz = zn>0.008856 ? pow(zn,0.333333) : 7.787*zn+0.137931;
            float L = 116.0*fy - 16.0;
            float A = 500.0*(fx - fy);
            float B = 200.0*(fy - fz);
            // Apply gamma to L only (normalised to 0-1 range)
            float Ln = clamp(L/100.0, 0.001, 1.0);
            float Lnew = clamp(pow(Ln, gamma) * 100.0, 0.0, 100.0);
            // Lab -> XYZ
            float fy2 = (Lnew+16.0)/116.0;
            float fx2 = A/500.0 + fy2;
            float fz2 = fy2 - B/200.0;
            float x2 = fx2>0.206897 ? fx2*fx2*fx2 : (fx2-0.137931)/7.787;
            float y2 = fy2>0.206897 ? fy2*fy2*fy2 : (fy2-0.137931)/7.787;
            float z2 = fz2>0.206897 ? fz2*fz2*fz2 : (fz2-0.137931)/7.787;
            x2*=0.95047; y2*=1.00000; z2*=1.08883;
            // XYZ -> RGB
            float ro = x2* 3.2404542 - y2*1.5371385 - z2*0.4985314;
            float go = x2*-0.9692660 + y2*1.8760108 + z2*0.0415560;
            float bo = x2* 0.0556434 - y2*0.2040259 + z2*1.0572252;
            return vec4(clamp(ro,0.0,1.0), clamp(go,0.0,1.0), clamp(bo,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, gamma as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Balance contrast
    //
    // Boosts contrast only — never reduces. Works on Lab L only so color is unaffected.
    // Flat images (L std dev below targetLStd * contrastDeadzone) get an S-curve boost.
    // Images with sufficient contrast are left untouched.

    func balanceContrastColor(_ image: CIImage) throws -> CIImage {
        let pixels = try samplePixels(image, border: 0.10)
        let lValues = pixels.map { rgbToLab(r: $0.r, g: $0.g, b: $0.b).0 }
        let meanL = lValues.reduce(0, +) / Double(lValues.count)
        let stdL  = stdDev(lValues, mean: meanL)
        print("📊 COLOR Contrast analysis: stdL=\(String(format:"%.1f",stdL)) meanL=\(String(format:"%.1f",meanL)) (target stdL=\(targetLStd))")

        let threshold = targetLStd * contrastDeadzone
        guard stdL < threshold else {
            print("ℹ️ COLOR Contrast: stdL=\(String(format:"%.1f",stdL)) >= threshold \(String(format:"%.1f",threshold)), skipping")
            return image
        }

        // k proportional to how flat the image is, capped at maxContrastK
        let k = Float(min(targetLStd / stdL * 2.0, Double(maxContrastK)))
        print("📊 COLOR Contrast boost: stdL=\(String(format:"%.1f",stdL)) k=\(String(format:"%.2f",k))")

        // S-curve applied to L only in Lab space
        let src = """
        kernel vec4 balanceContrastLab(sampler src, float k) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);
            // RGB -> XYZ -> Lab
            float x = r*0.4124564 + g*0.3575761 + b*0.1804375;
            float y = r*0.2126729 + g*0.7151522 + b*0.0721750;
            float z = r*0.0193339 + g*0.1191920 + b*0.9503041;
            float xn=x/0.95047; float yn=y/1.00000; float zn=z/1.08883;
            float fx = xn>0.008856 ? pow(xn,0.333333) : 7.787*xn+0.137931;
            float fy = yn>0.008856 ? pow(yn,0.333333) : 7.787*yn+0.137931;
            float fz = zn>0.008856 ? pow(zn,0.333333) : 7.787*zn+0.137931;
            float L = 116.0*fy - 16.0;
            float A = 500.0*(fx - fy);
            float B = 200.0*(fy - fz);
            // S-curve on L (normalised 0-1, pivot at 0.5)
            float Ln = L / 100.0;
            float s0 = 1.0/(1.0+exp( k*0.5));
            float s1 = 1.0/(1.0+exp(-k*0.5));
            float Lnew = clamp(((1.0/(1.0+exp(-k*(Ln-0.5)))-s0)/(s1-s0)) * 100.0, 0.0, 100.0);
            // Lab -> XYZ -> RGB
            float fy2 = (Lnew+16.0)/116.0;
            float fx2 = A/500.0 + fy2;
            float fz2 = fy2 - B/200.0;
            float x2 = fx2>0.206897 ? fx2*fx2*fx2 : (fx2-0.137931)/7.787;
            float y2 = fy2>0.206897 ? fy2*fy2*fy2 : (fy2-0.137931)/7.787;
            float z2 = fz2>0.206897 ? fz2*fz2*fz2 : (fz2-0.137931)/7.787;
            x2*=0.95047; y2*=1.00000; z2*=1.08883;
            float ro = x2* 3.2404542 - y2*1.5371385 - z2*0.4985314;
            float go = x2*-0.9692660 + y2*1.8760108 + z2*0.0415560;
            float bo = x2* 0.0556434 - y2*0.2040259 + z2*1.0572252;
            return vec4(clamp(ro,0.0,1.0), clamp(go,0.0,1.0), clamp(bo,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, k as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Save

    private func saveImage(_ image: CIImage, to url: URL, sourceURL: URL, outputFormat: OutputFormat) throws {
        let w = Int(image.extent.width); let h = Int(image.extent.height)

        // Read source DPI and bit depth
        var dpiW: Double = 72; var dpiH: Double = 72; var bitDepth: Int = 8
        if let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            dpiW     = (props[kCGImagePropertyDPIWidth]  as? Double) ?? 72.0
            dpiH     = (props[kCGImagePropertyDPIHeight] as? Double) ?? 72.0
            bitDepth = (props[kCGImagePropertyDepth]     as? Int)    ?? 8
        }
        print("📐 Source metadata: \(Int(dpiW))×\(Int(dpiH)) DPI, \(bitDepth)-bit")

        // Use 16-bit context for TIFF when source is 16-bit
        let use16 = outputFormat == .tiff && bitDepth >= 16
        let bpc   = use16 ? 16 : 8
        let fmt: CIFormat   = use16 ? .RGBAh : .RGBA8
        let bmi: UInt32     = use16
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let rgbCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bpc,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: bmi)
        else { throw ProcessingErrorColor.failedToCreateCGImage }
        guard let ciCG = context.createCGImage(image, from: image.extent, format: fmt,
                                               colorSpace: CGColorSpaceCreateDeviceRGB())
        else { throw ProcessingErrorColor.failedToCreateCGImage }
        rgbCtx.draw(ciCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = rgbCtx.makeImage() else { throw ProcessingErrorColor.failedToCreateCGImage }

        let utType: CFString = outputFormat == .tiff ? UTType.tiff.identifier as CFString : UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil)
        else { throw ProcessingErrorColor.failedToCreateDestination }

        if outputFormat == .tiff {
            // Set TIFF resolution at destination level — CGImageDestinationSetProperties
            // writes file-level IFD tags which Preview reads correctly
            let destProps: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFXResolution:    NSNumber(value: dpiW),
                kCGImagePropertyTIFFYResolution:    NSNumber(value: dpiH),
                kCGImagePropertyTIFFResolutionUnit: NSNumber(value: 2)   // inches
            ] as [CFString: Any]]
            CGImageDestinationSetProperties(dest, destProps as CFDictionary)
            CGImageDestinationAddImage(dest, cg, nil)
        } else {
            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.95,
                kCGImagePropertyJFIFDictionary: [
                    kCGImagePropertyJFIFXDensity:    NSNumber(value: dpiW),
                    kCGImagePropertyJFIFYDensity:    NSNumber(value: dpiH),
                    kCGImagePropertyJFIFDensityUnit: NSNumber(value: 1)
                ] as [CFString: Any]
            ]
            CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ProcessingErrorColor.failedToSaveImage }
        let fmt2 = outputFormat == .tiff ? "TIFF" : "JPEG"
        print("\u{2713} COLOR: Saved as \(fmt2) (\(bpc)-bit, \(Int(dpiW))dpi)")
    }

    // MARK: - Generate output URL

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

// MARK: - Errors

enum ProcessingErrorColor: LocalizedError {
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

// MARK: - Supporting types

typealias RGBPixel   = (r: Double, g: Double, b: Double)
typealias RGBPixelXY = (x: Double, y: Double, r: Double, g: Double, b: Double)

// MARK: - Color Image Processor

class ImageProcessorColor {

    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace:  CGColorSpaceCreateDeviceRGB()
    ])

    // MARK: - Convert Negative

    func convertImageColor(sourceURL: URL, referenceURL: URL? = nil, outputFormat: OutputFormat = .jpeg, normalizeMidtones: Bool = false, transferLuminance: Bool = false, balanceContrast: Bool = false) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("🎨 COLOR Processing: \(sourceURL.lastPathComponent)")

        let negative = try loadImage(from: sourceURL)
        print("✓ Loaded: \(negative.extent.width)x\(negative.extent.height)")

        let detectedOrange = try detectOrangeFromFilmBase(negative)
        print("🟠 Orange — R:\(String(format:"%.3f",detectedOrange.r)) G:\(String(format:"%.3f",detectedOrange.g)) B:\(String(format:"%.3f",detectedOrange.b))")

        let orangeRemoved = try removeOrange(negative, orange: detectedOrange)
        print("✓ Orange removed")

        let stretchedNegative = try stretchChannels(orangeRemoved)
        print("✓ Tonal stretch done")

        let roughPositive = try invert(stretchedNegative)
        print("✓ Inverted")

        var finalPositive: CIImage
        if let refURL = referenceURL,
           let reference = CIImage(contentsOf: refURL) {
            print("📂 Applying reference from: \(refURL.lastPathComponent)")
            if transferLuminance {
                // Color source + BW reference: desaturate then histogram match L
                let desaturated = try desaturate(roughPositive)
                print("✓ Step 1: desaturated")
                finalPositive = try histogramMatchLuminance(desaturated, reference: reference)
                print("✓ Step 2: luminance matched to reference")
            } else {
                // Color source + color reference: histogram match L + color temperature
                let lMatched = try histogramMatchLuminance(roughPositive, reference: reference)
                finalPositive = try matchColorTemperature(lMatched, reference: reference)
                print("✓ Reference applied (luminance + color temperature)")
            }
        } else {
            finalPositive = roughPositive
            print("ℹ️ No reference — skipping")
        }

        if normalizeMidtones {
            finalPositive = try normalizeMidtonesColor(finalPositive)
            print("✓ Midtones normalized")
        }
        if balanceContrast {
            finalPositive = try balanceContrastColor(finalPositive)
            print("✓ Contrast balanced")
        }

        let outputURL = generateOutputURL(from: sourceURL, suffix: "_p", outputFormat: outputFormat)
        try saveImage(finalPositive, to: outputURL, outputFormat: outputFormat)
        print("✓ Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Enhance Positive

    func enhancePositiveColor(sourceURL: URL, referenceURL: URL? = nil, outputFormat: OutputFormat = .jpeg, normalizeMidtones: Bool = false, transferLuminance: Bool = false, balanceContrast: Bool = false) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("🎨 COLOR ENHANCE: \(sourceURL.lastPathComponent)")

        let positive = try loadImage(from: sourceURL)
        print("✓ Enhance Loaded: \(positive.extent.width)x\(positive.extent.height)")

        let stretched = try stretchChannels(positive)
        print("✓ Enhance tonal stretch done")

        var finalImage: CIImage
        if let refURL = referenceURL,
           let reference = CIImage(contentsOf: refURL) {
            print("📂 Enhance applying reference from: \(refURL.lastPathComponent)")
            if transferLuminance {
                // Color source + BW reference: desaturate then histogram match L
                let desaturated = try desaturate(stretched)
                print("✓ Enhance Step 1: desaturated")
                finalImage = try histogramMatchLuminance(desaturated, reference: reference)
                print("✓ Enhance Step 2: luminance matched to reference")
            } else {
                // Color source + color reference: histogram match L + color temperature
                let lMatched = try histogramMatchLuminance(stretched, reference: reference)
                finalImage = try matchColorTemperature(lMatched, reference: reference)
                print("✓ Enhance reference applied (luminance + color temperature)")
            }
        } else {
            finalImage = stretched
            print("ℹ️ Enhance no reference — skipping")
        }

        if normalizeMidtones {
            finalImage = try normalizeMidtonesColor(finalImage)
            print("✓ Enhance Midtones normalized")
        }
        if balanceContrast {
            finalImage = try balanceContrastColor(finalImage)
            print("✓ Enhance Contrast balanced")
        }

        let outputURL = generateOutputURL(from: sourceURL, suffix: "_e", outputFormat: outputFormat)
        try saveImage(finalImage, to: outputURL, outputFormat: outputFormat)
        print("✓ Enhance Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Loading

    private func loadImage(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWImage(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw ProcessingErrorColor.failedToLoadImage
        }
        return image
    }

    private func loadRAWImage(from url: URL) throws -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ProcessingErrorColor.failedToLoadRAWImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProcessingErrorColor.failedToLoadRAWImage
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Orange detection

    private func detectOrangeFromFilmBase(_ image: CIImage) throws -> RGBPixel {
        let pixels = try samplePixels(image, border: 0.10)
        let withLum = pixels.map { p -> (Double, RGBPixel) in
            let lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b
            return (lum, p)
        }.sorted { $0.0 > $1.0 }
        let topCount = max(1, Int(Double(withLum.count) * 0.05))
        let topPixels = withLum.prefix(topCount).map { $0.1 }
        let rAvg = topPixels.map { $0.r }.reduce(0,+) / Double(topPixels.count)
        let gAvg = topPixels.map { $0.g }.reduce(0,+) / Double(topPixels.count)
        let bAvg = topPixels.map { $0.b }.reduce(0,+) / Double(topPixels.count)
        return (r: rAvg, g: gAvg, b: bAvg)
    }

    // MARK: - Orange removal

    private func removeOrange(_ image: CIImage, orange: RGBPixel) throws -> CIImage {
        let rRaw = Float(1.0 / max(orange.r, 0.001))
        let gRaw = Float(1.0 / max(orange.g, 0.001))
        let bRaw = Float(1.0 / max(orange.b, 0.001))
        let maxG = max(rRaw, gRaw, bRaw)
        let rG = rRaw / maxG; let gG = gRaw / maxG; let bG = bRaw / maxG
        print("📊 Orange gains (normalised) — R:\(String(format:"%.3f",rG)) G:\(String(format:"%.3f",gG)) B:\(String(format:"%.3f",bG))")
        let src = """
        kernel vec4 removeOrange(sampler src, float rG, float gG, float bG) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rG,0.0,1.0), clamp(px.g*gG,0.0,1.0), clamp(px.b*bG,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, rG as NSNumber, gG as NSNumber, bG as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Invert

    private func invert(_ image: CIImage) throws -> CIImage {
        let src = """
        kernel vec4 invert(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(1.0-px.r, 1.0-px.g, 1.0-px.b, px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Per-channel tonal stretch

    private func stretchChannels(_ image: CIImage) throws -> CIImage {
        let pixels = try samplePixels(image, border: 0.10)
        var reds   = pixels.map { Float($0.r) }
        var greens = pixels.map { Float($0.g) }
        var blues  = pixels.map { Float($0.b) }
        reds.sort(); greens.sort(); blues.sort()
        let n = reds.count
        let loIdx = max(0,   Int(Float(n) * 0.005))
        let hiIdx = min(n-1, Int(Float(n) * 0.995))
        let rLo = reds[loIdx];   let rHi = reds[hiIdx]
        let gLo = greens[loIdx]; let gHi = greens[hiIdx]
        let bLo = blues[loIdx];  let bHi = blues[hiIdx]
        print("📊 Stretch — R:[\(String(format:"%.3f",rLo)),\(String(format:"%.3f",rHi))] G:[\(String(format:"%.3f",gLo)),\(String(format:"%.3f",gHi))] B:[\(String(format:"%.3f",bLo)),\(String(format:"%.3f",bHi))]")
        let rGain = Float(rHi > rLo + 0.01 ? 1.0 / Double(rHi - rLo) : 1.0)
        let gGain = Float(gHi > gLo + 0.01 ? 1.0 / Double(gHi - gLo) : 1.0)
        let bGain = Float(bHi > bLo + 0.01 ? 1.0 / Double(bHi - bLo) : 1.0)
        let rBias = -rLo * rGain; let gBias = -gLo * gGain; let bBias = -bLo * bGain
        let src = """
        kernel vec4 stretch(sampler src, float rGain, float rBias, float gGain, float gBias, float bGain, float bBias) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rGain+rBias,0.0,1.0), clamp(px.g*gGain+gBias,0.0,1.0), clamp(px.b*bGain+bBias,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, rGain as NSNumber, rBias as NSNumber,
                                                 gGain as NSNumber, gBias as NSNumber,
                                                 bGain as NSNumber, bBias as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Desaturate (drive color to gray in Lab space)

    private func desaturate(_ image: CIImage) throws -> CIImage {
        let src = """
        kernel vec4 desaturate(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            float lum = px.r*0.2126 + px.g*0.7152 + px.b*0.0722;
            return vec4(lum, lum, lum, px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - 3-point tone curve luminance matching
    //
    // Samples the 5th, 50th, and 95th percentile luminance of source and reference.
    // Builds a smooth monotonic curve through those three anchor points.
    // Applies it by scaling RGB proportionally — preserves color ratios, no new clipping.
    //
    // Why 3 points:
    //   5th  percentile → blacks:    if ref has deep blacks, output will too
    //   50th percentile → midtones:  overall brightness matches
    //   95th percentile → whites:    if ref has bright whites, output will too

    private func histogramMatchLuminance(_ image: CIImage, reference: CIImage) throws -> CIImage {
        // Sample luminance values
        let srcPixels = try samplePixels(image, border: 0.15)
        let refPixels = try samplePixels(reference, border: 0.15)
        var srcLums = srcPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()
        var refLums = refPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()

        func percentile(_ arr: [Float], _ p: Double) -> Float {
            let idx = min(arr.count-1, max(0, Int(Double(arr.count) * p)))
            return arr[idx]
        }

        // Anchor points: (source luminance) → (target luminance)
        let sx0 = percentile(srcLums, 0.05);  let tx0 = percentile(refLums, 0.05)
        let sx1 = percentile(srcLums, 0.50);  let tx1 = percentile(refLums, 0.50)
        let sx2 = percentile(srcLums, 0.95);  let tx2 = percentile(refLums, 0.95)

        print("📊 Tone curve — shadows: \(String(format:"%.3f",sx0))→\(String(format:"%.3f",tx0))  mids: \(String(format:"%.3f",sx1))→\(String(format:"%.3f",tx1))  highlights: \(String(format:"%.3f",sx2))→\(String(format:"%.3f",tx2))")

        // Build a 256-entry lookup table by interpolating through the 3 anchor points.
        // We clamp anchors to ensure strict monotonicity.
        // Segments: [0..sx0], [sx0..sx1], [sx1..sx2], [sx2..1]
        // Each segment uses a smooth cubic Hermite between its endpoints.
        let bins = 256
        var mapping = [Float](repeating: 0, count: bins)

        for i in 0..<bins {
            let x = Float(i) / Float(bins - 1)
            let t: Float
            if x <= sx0 {
                // Below shadow anchor: linear scale from 0
                t = sx0 > 0.0001 ? (x / sx0) * tx0 : tx0
            } else if x <= sx1 {
                // Shadow → midtone segment
                let seg = sx1 > sx0 ? (x - sx0) / (sx1 - sx0) : 0
                t = smoothStep(tx0, tx1, seg)
            } else if x <= sx2 {
                // Midtone → highlight segment
                let seg = sx2 > sx1 ? (x - sx1) / (sx2 - sx1) : 0
                t = smoothStep(tx1, tx2, seg)
            } else {
                // Above highlight anchor: linear scale toward 1
                let remaining = 1.0 - sx2
                let targetRemaining = 1.0 - tx2
                t = remaining > 0.0001 ? tx2 + ((x - sx2) / remaining) * targetRemaining : tx2
            }
            mapping[i] = min(1.0, max(0.0, t))
        }

        return try applyLuminanceMapping(image, mapping: mapping, bins: bins)
    }

    // Smooth cubic Hermite interpolation (smoothstep) between two values
    private func smoothStep(_ a: Float, _ b: Float, _ t: Float) -> Float {
        let s = t * t * (3 - 2 * t)  // smoothstep
        return a + s * (b - a)
    }

    // Apply a 256-entry luminance mapping to full-res image on CPU.
    // Scales RGB channels proportionally to preserve color ratios.
    private func applyLuminanceMapping(_ image: CIImage, mapping: [Float], bins: Int) throws -> CIImage {
        guard let cg = context.createCGImage(image, from: image.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data else {
            throw ProcessingErrorColor.failedToProcessImage
        }

        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let dataLen = h * bpr
        var pixels = [UInt8](repeating: 0, count: dataLen)
        CFDataGetBytes(cfData, CFRange(location: 0, length: dataLen), &pixels)

        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                let r = Float(pixels[i])   / 255.0
                let g = Float(pixels[i+1]) / 255.0
                let b = Float(pixels[i+2]) / 255.0
                let lum = r * 0.2126 + g * 0.7152 + b * 0.0722
                if lum > 0.001 {
                    let bin = min(bins-1, Int(lum * Float(bins)))
                    let ratio = mapping[bin] / lum
                    pixels[i]   = UInt8(min(255, max(0, Int(r * ratio * 255.0 + 0.5))))
                    pixels[i+1] = UInt8(min(255, max(0, Int(g * ratio * 255.0 + 0.5))))
                    pixels[i+2] = UInt8(min(255, max(0, Int(b * ratio * 255.0 + 0.5))))
                } else {
                    // Very dark pixels: map directly via lookup, no ratio needed
                    let mapped = mapping[0]
                    let v = UInt8(min(255, max(0, Int(mapped * 255.0 + 0.5))))
                    pixels[i] = v; pixels[i+1] = v; pixels[i+2] = v
                }
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ProcessingErrorColor.failedToProcessImage
        }
        let data = Data(pixels)
        return try data.withUnsafeBytes { ptr -> CIImage in
            guard let base = ptr.baseAddress,
                  let newProvider = CGDataProvider(dataInfo: nil, data: base, size: dataLen,
                                                   releaseData: { _, _, _ in }),
                  let newCG = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: bpr, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: newProvider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent)
            else { throw ProcessingErrorColor.failedToProcessImage }
            return CIImage(cgImage: newCG)
        }
    }

    // MARK: - Color temperature matching
    // Computes per-channel mean of source and reference, applies a shift
    // so source means match reference means. Monotonic — cannot clip.

    private func matchColorTemperature(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcPixels = try samplePixels(image, border: 0.15)
        let refPixels = try samplePixels(reference, border: 0.15)

        let srcR = Float(srcPixels.map { $0.r }.reduce(0,+) / Double(srcPixels.count))
        let srcG = Float(srcPixels.map { $0.g }.reduce(0,+) / Double(srcPixels.count))
        let srcB = Float(srcPixels.map { $0.b }.reduce(0,+) / Double(srcPixels.count))
        let refR = Float(refPixels.map { $0.r }.reduce(0,+) / Double(refPixels.count))
        let refG = Float(refPixels.map { $0.g }.reduce(0,+) / Double(refPixels.count))
        let refB = Float(refPixels.map { $0.b }.reduce(0,+) / Double(refPixels.count))

        // Gain per channel (multiplicative shift preserves black point)
        let rGain = srcR > 0.001 ? refR / srcR : 1.0
        let gGain = srcG > 0.001 ? refG / srcG : 1.0
        let bGain = srcB > 0.001 ? refB / srcB : 1.0

        print("📊 Color temp — gains R:\(String(format:"%.3f",rGain)) G:\(String(format:"%.3f",gGain)) B:\(String(format:"%.3f",bGain))")

        let src = """
        kernel vec4 colorTemp(sampler src, float rG, float gG, float bG) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rG,0.0,1.0), clamp(px.g*gG,0.0,1.0), clamp(px.b*bG,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, rGain as NSNumber, gGain as NSNumber, bGain as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Pixel sampling

    private func samplePixels(_ image: CIImage, border: Double) throws -> [RGBPixel] {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data,
              let data = CFDataGetBytePtr(cfData) else { throw ProcessingErrorColor.failedToProcessImage }
        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let x0 = Int(Double(w)*border); let x1 = w-x0
        let y0 = Int(Double(h)*border); let y1 = h-y0
        var result: [RGBPixel] = []
        result.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y*bpr + x*4
                result.append((r: Double(data[i])/255.0,
                               g: Double(data[i+1])/255.0,
                               b: Double(data[i+2])/255.0))
            }
        }
        return result
    }

    // MARK: - Normalize midtones

    private func normalizeMidtonesColor(_ image: CIImage) throws -> CIImage {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent,
                                                   format: .RGBA8,
                                                   colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cgImage.dataProvider,
              let cfData   = provider.data,
              let data     = CFDataGetBytePtr(cfData) else { throw ProcessingErrorColor.failedToProcessImage }
        let width = cgImage.width; let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let x0 = Int(Double(width)*0.10); let x1 = width-x0
        let y0 = Int(Double(height)*0.10); let y1 = height-y0
        var lums: [Float] = []
        lums.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y*bytesPerRow + x*4
                let r = Float(data[i])/255.0; let g = Float(data[i+1])/255.0; let b = Float(data[i+2])/255.0
                lums.append(0.299*r + 0.587*g + 0.114*b)
            }
        }
        lums.sort()
        let median = Double(lums[lums.count/2])
        guard median > 0.01 && median < 0.99 else {
            print("⚠️ COLOR Midtone: median \(String(format:"%.3f",median)) out of range, skipping")
            return image
        }
        let gamma = Float(min(log(0.5)/log(median), 2.0))
        print("📊 COLOR Midtone: median=\(String(format:"%.3f",median)) gamma=\(String(format:"%.3f",gamma))")
        let src = """
        kernel vec4 normalizeMidtones(sampler src, float gamma) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(pow(clamp(px.r,0.001,1.0),gamma), pow(clamp(px.g,0.001,1.0),gamma), pow(clamp(px.b,0.001,1.0),gamma), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, gamma as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Balance contrast

    func balanceContrastColor(_ image: CIImage) throws -> CIImage {
        let targetStd: Float = 0.30
        let scale = min(512.0/image.extent.width, 512.0/image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent,
                                                   format: .RGBA8,
                                                   colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cgImage.dataProvider,
              let cfData   = provider.data,
              let data     = CFDataGetBytePtr(cfData) else { throw ProcessingErrorColor.failedToProcessImage }
        let width = cgImage.width; let height = cgImage.height; let bpr = cgImage.bytesPerRow
        let x0 = Int(Double(width)*0.10); let x1 = width-x0
        let y0 = Int(Double(height)*0.10); let y1 = height-y0
        var lums: [Float] = []
        lums.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y*bpr + x*4
                let r = Float(data[i])/255.0; let g = Float(data[i+1])/255.0; let b = Float(data[i+2])/255.0
                lums.append(0.299*r + 0.587*g + 0.114*b)
            }
        }
        let mean = lums.reduce(0,+)/Float(lums.count)
        let variance = lums.map { ($0-mean)*($0-mean) }.reduce(0,+)/Float(lums.count)
        let std = sqrt(variance)
        guard std < targetStd else {
            print("📊 COLOR Contrast sufficient (std=\(String(format:"%.3f",std))), skipping")
            return image
        }
        let k = Float(min(Double(4.0*targetStd/std), 12.0))
        print("📊 COLOR Balance contrast: std=\(String(format:"%.3f",std)) k=\(String(format:"%.2f",k))")
        let src = """
        kernel vec4 balanceContrast(sampler src, float k) {
            vec4 px = sample(src, samplerCoord(src));
            float s0 = 1.0/(1.0+exp(k*0.5)); float s1 = 1.0/(1.0+exp(-k*0.5)); float range = s1-s0;
            float r = (1.0/(1.0+exp(-k*(clamp(px.r,0.0,1.0)-0.5)))-s0)/range;
            float g = (1.0/(1.0+exp(-k*(clamp(px.g,0.0,1.0)-0.5)))-s0)/range;
            float b = (1.0/(1.0+exp(-k*(clamp(px.b,0.0,1.0)-0.5)))-s0)/range;
            return vec4(r, g, b, px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, k as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Save

    private func saveImage(_ image: CIImage, to url: URL, outputFormat: OutputFormat) throws {
        let w = Int(image.extent.width); let h = Int(image.extent.height)
        guard let rgbCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ProcessingErrorColor.failedToCreateCGImage }
        guard let ciCG = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                               colorSpace: CGColorSpaceCreateDeviceRGB())
        else { throw ProcessingErrorColor.failedToCreateCGImage }
        rgbCtx.draw(ciCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = rgbCtx.makeImage() else { throw ProcessingErrorColor.failedToCreateCGImage }
        let utType: CFString = outputFormat == .tiff ? UTType.tiff.identifier as CFString : UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil)
        else { throw ProcessingErrorColor.failedToCreateDestination }
        let options: [CFString: Any] = outputFormat == .tiff ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ProcessingErrorColor.failedToSaveImage }
        print("✓ COLOR: Saved as \(outputFormat == .tiff ? "TIFF" : "JPEG")")
    }

    // MARK: - Generate output URL

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


/*
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers


// MARK: - Balanced mode tuning parameters
//
// Brightness: nudges mean L toward targetLMean (50.0 = middle grey in Lab).
// maxBrightnessCorrection: fraction of the distance to target actually applied.
// 0.0 = no effect, 1.0 = full push to middle grey. 0.35 = gentle nudge.
//
// Contrast: boosts contrast only when L std dev is below targetLStd (flat image).
// Images at or above targetLStd are left untouched.
// maxContrastK: caps sigmoid steepness (higher = stronger S-curve effect).
// contrastDeadzone: images within this fraction of targetLStd get no boost.

private let targetLMean:          Double = 78.0  // Lab L*, middle grey
private let maxBrightnessCorrection: Double = 0.65  // 0.0–1.0
private let targetLStd:           Double = 22.0  // L* std dev target (flat images boosted toward this)
private let maxContrastK:         Float  = 6.0   // sigmoid steepness cap
private let contrastDeadzone:     Double = 0.85  // fraction of targetLStd below which boost kicks in

// MARK: - Errors

enum ProcessingErrorColor: LocalizedError {
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

// MARK: - Supporting types

struct LabStats {
    var lMean: Double = 0; var lStd: Double = 1
    var aMean: Double = 0; var aStd: Double = 1
    var bMean: Double = 0; var bStd: Double = 1
}

typealias RGBPixel   = (r: Double, g: Double, b: Double)
typealias RGBPixelXY = (x: Double, y: Double, r: Double, g: Double, b: Double)

// MARK: - Color Image Processor

class ImageProcessorColor {

    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace:  CGColorSpaceCreateDeviceRGB()
    ])

    // MARK: - Convert Negative

    func convertImageColor(sourceURL: URL, outputDirectory: URL, referenceURL: URL? = nil, outputFormat: OutputFormat = .jpeg, normalizeMidtones: Bool = false, transferLuminance: Bool = false, balanceContrast: Bool = false, sourceIsGrayscale: Bool = false) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("🎨 COLOR Processing: \(sourceURL.lastPathComponent)")

        let negative = try loadImage(from: sourceURL)
        print("✓ Loaded: \(negative.extent.width)x\(negative.extent.height)")

        let detectedOrange = try detectOrangeFromFilmBase(negative)
        print("🟠 Orange — R:\(String(format:"%.3f",detectedOrange.r)) G:\(String(format:"%.3f",detectedOrange.g)) B:\(String(format:"%.3f",detectedOrange.b))")

        let orangeRemoved = try removeOrange(negative, orange: detectedOrange)
        print("✓ Orange removed")

        let stretchedNegative = try stretchChannels(orangeRemoved)
        print("✓ Tonal stretch done")

        let roughPositive = try invert(stretchedNegative)
        print("✓ Inverted")

        var finalPositive: CIImage
        if let refURL = referenceURL,
           let reference = CIImage(contentsOf: refURL) {
            print("📂 Applying reference from: \(refURL.lastPathComponent)")
            if transferLuminance {
                // Color source + BW reference: desaturate then histogram match L
                let desaturated = try desaturate(roughPositive)
                print("✓ Step 1: desaturated")
                finalPositive = try histogramMatchLuminance(desaturated, reference: reference)
                print("✓ Step 2: luminance matched to reference")
            } else if sourceIsGrayscale {
                // BW source + color reference: transfer a+b channels from reference (Lab)
                finalPositive = try applyLabABTransfer(roughPositive, reference: reference)
                print("✓ Lab a+b color transfer applied")
            } else {
                // Color source + color reference: contrast match + color temperature + stretch
                finalPositive = try applyReference(roughPositive, reference: reference)
                print("✓ Reference applied")
            }
        } else {
            finalPositive = roughPositive
            print("ℹ️ No reference — skipping")
        }

        if normalizeMidtones {
            finalPositive = try normalizeMidtonesColor(finalPositive)
            print("✓ Midtones normalized")
        }
        if balanceContrast {
            finalPositive = try balanceContrastColor(finalPositive)
            print("✓ Contrast balanced")
        }

        let outputURL = generateOutputURL(from: sourceURL, outputDirectory: outputDirectory, suffix: "_p", outputFormat: outputFormat)
        try saveImage(finalPositive, to: outputURL, outputFormat: outputFormat)
        print("✓ Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Enhance Positive

    func enhancePositiveColor(sourceURL: URL, outputDirectory: URL, referenceURL: URL? = nil, outputFormat: OutputFormat = .jpeg, normalizeMidtones: Bool = false, transferLuminance: Bool = false, balanceContrast: Bool = false, sourceIsGrayscale: Bool = false) async throws {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        print("🎨 COLOR ENHANCE: \(sourceURL.lastPathComponent)")

        let positive = try loadImage(from: sourceURL)
        print("✓ Enhance Loaded: \(positive.extent.width)x\(positive.extent.height)")

        let stretched = try stretchChannels(positive)
        print("✓ Enhance tonal stretch done")

        var finalImage: CIImage
        if let refURL = referenceURL,
           let reference = CIImage(contentsOf: refURL) {
            print("📂 Enhance applying reference from: \(refURL.lastPathComponent)")
            if transferLuminance {
                // Color source + BW reference: desaturate then histogram match L
                let desaturated = try desaturate(stretched)
                print("✓ Enhance Step 1: desaturated")
                finalImage = try histogramMatchLuminance(desaturated, reference: reference)
                print("✓ Enhance Step 2: luminance matched to reference")
            } else if sourceIsGrayscale {
                // BW source + color reference: transfer a+b channels from reference (Lab)
                finalImage = try applyLabABTransfer(stretched, reference: reference)
                print("✓ Enhance Lab a+b color transfer applied")
            } else {
                // Color source + color reference: contrast match + color temperature + stretch
                finalImage = try applyReference(stretched, reference: reference)
                print("✓ Enhance reference applied")
            }
        } else {
            finalImage = stretched
            print("ℹ️ Enhance no reference — skipping")
        }

        if normalizeMidtones {
            finalImage = try normalizeMidtonesColor(finalImage)
            print("✓ Enhance Midtones normalized")
        }
        if balanceContrast {
            finalImage = try balanceContrastColor(finalImage)
            print("✓ Enhance Contrast balanced")
        }

        let outputURL = generateOutputURL(from: sourceURL, outputDirectory: outputDirectory, suffix: "_e", outputFormat: outputFormat)
        try saveImage(finalImage, to: outputURL, outputFormat: outputFormat)
        print("✓ Enhance Saved: \(outputURL.lastPathComponent)")
    }

    // MARK: - Loading

    private func loadImage(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWImage(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw ProcessingErrorColor.failedToLoadImage
        }
        return image
    }

    private func loadRAWImage(from url: URL) throws -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ProcessingErrorColor.failedToLoadRAWImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProcessingErrorColor.failedToLoadRAWImage
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Orange detection

    private func detectOrangeFromFilmBase(_ image: CIImage) throws -> RGBPixel {
        let pixels = try samplePixels(image, border: 0.10)
        let withLum = pixels.map { p -> (Double, RGBPixel) in
            let lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b
            return (lum, p)
        }.sorted { $0.0 > $1.0 }
        let topCount = max(1, Int(Double(withLum.count) * 0.05))
        let topPixels = withLum.prefix(topCount).map { $0.1 }
        let rAvg = topPixels.map { $0.r }.reduce(0,+) / Double(topPixels.count)
        let gAvg = topPixels.map { $0.g }.reduce(0,+) / Double(topPixels.count)
        let bAvg = topPixels.map { $0.b }.reduce(0,+) / Double(topPixels.count)
        return (r: rAvg, g: gAvg, b: bAvg)
    }

    // MARK: - Orange removal

    private func removeOrange(_ image: CIImage, orange: RGBPixel) throws -> CIImage {
        let rRaw = Float(1.0 / max(orange.r, 0.001))
        let gRaw = Float(1.0 / max(orange.g, 0.001))
        let bRaw = Float(1.0 / max(orange.b, 0.001))
        let maxG = max(rRaw, gRaw, bRaw)
        let rG = rRaw / maxG; let gG = gRaw / maxG; let bG = bRaw / maxG
        print("📊 Orange gains (normalised) — R:\(String(format:"%.3f",rG)) G:\(String(format:"%.3f",gG)) B:\(String(format:"%.3f",bG))")
        let src = """
        kernel vec4 removeOrange(sampler src, float rG, float gG, float bG) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rG,0.0,1.0), clamp(px.g*gG,0.0,1.0), clamp(px.b*bG,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, rG as NSNumber, gG as NSNumber, bG as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Invert

    private func invert(_ image: CIImage) throws -> CIImage {
        let src = """
        kernel vec4 invert(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(1.0-px.r, 1.0-px.g, 1.0-px.b, px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Per-channel tonal stretch

    private func stretchChannels(_ image: CIImage) throws -> CIImage {
        let pixels = try samplePixels(image, border: 0.10)
        var reds   = pixels.map { Float($0.r) }
        var greens = pixels.map { Float($0.g) }
        var blues  = pixels.map { Float($0.b) }
        reds.sort(); greens.sort(); blues.sort()
        let n = reds.count
        let loIdx = max(0,   Int(Float(n) * 0.005))
        let hiIdx = min(n-1, Int(Float(n) * 0.995))
        let rLo = reds[loIdx];   let rHi = reds[hiIdx]
        let gLo = greens[loIdx]; let gHi = greens[hiIdx]
        let bLo = blues[loIdx];  let bHi = blues[hiIdx]
        print("📊 Stretch — R:[\(String(format:"%.3f",rLo)),\(String(format:"%.3f",rHi))] G:[\(String(format:"%.3f",gLo)),\(String(format:"%.3f",gHi))] B:[\(String(format:"%.3f",bLo)),\(String(format:"%.3f",bHi))]")
        let rGain = Float(rHi > rLo + 0.01 ? 1.0 / Double(rHi - rLo) : 1.0)
        let gGain = Float(gHi > gLo + 0.01 ? 1.0 / Double(gHi - gLo) : 1.0)
        let bGain = Float(bHi > bLo + 0.01 ? 1.0 / Double(bHi - bLo) : 1.0)
        let rBias = -rLo * rGain; let gBias = -gLo * gGain; let bBias = -bLo * bGain
        let src = """
        kernel vec4 stretch(sampler src, float rGain, float rBias, float gGain, float gBias, float bGain, float bBias) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rGain+rBias,0.0,1.0), clamp(px.g*gGain+gBias,0.0,1.0), clamp(px.b*bGain+bBias,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, rGain as NSNumber, rBias as NSNumber,
                                                 gGain as NSNumber, gBias as NSNumber,
                                                 bGain as NSNumber, bBias as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Desaturate (drive color to gray in Lab space)

    private func desaturate(_ image: CIImage) throws -> CIImage {
        let src = """
        kernel vec4 desaturate(sampler src) {
            vec4 px = sample(src, samplerCoord(src));
            float lum = px.r*0.2126 + px.g*0.7152 + px.b*0.0722;
            return vec4(lum, lum, lum, px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Reference matching
    //
    // Strategy:
    //   1. Sample the middle 80% of the tonal range (ignore darkest+brightest 10%)
    //      from both source and reference — outliers and clipped areas don't influence matching
    //   2. Compute per-channel std deviation from that stable zone
    //      → use std ratio as contrast gain (no bias, no brightness shift)
    //   3. Apply per-channel color temperature correction from the same stable zone
    //      → gains capped at 1.0 so channels can only be pulled down, never clipped up
    //   4. Stretch the output to full [0,1] range per channel
    //      → reference brightness is irrelevant; output always has full tonal range
    //
    // Result: the reference controls contrast shape and color balance only.
    //         Output brightness is always self-determined by the source content.

    private func applyReference(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcPixels = try samplePixels(image, border: 0.15)
        let refPixels = try samplePixels(reference, border: 0.15)

        // ── Helper: filter pixels to middle 80% of luminance ──
        func middlePixels(_ pixels: [RGBPixel]) -> [RGBPixel] {
            let lums = pixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }
            let sorted = lums.sorted()
            let lo = sorted[Int(Float(sorted.count) * 0.10)]
            let hi = sorted[Int(Float(sorted.count) * 0.90)]
            return zip(pixels, lums).compactMap { px, l in
                (l >= lo && l <= hi) ? px : nil
            }
        }

        let srcMid = middlePixels(srcPixels)
        let refMid = middlePixels(refPixels)
        guard !srcMid.isEmpty && !refMid.isEmpty else { return image }

        // ── Per-channel means from stable zone ──
        func mean(_ arr: [RGBPixel], _ ch: KeyPath<RGBPixel, Double>) -> Float {
            Float(arr.map { $0[keyPath: ch] }.reduce(0, +) / Double(arr.count))
        }
        let srcMeanR = mean(srcMid, \.r); let srcMeanG = mean(srcMid, \.g); let srcMeanB = mean(srcMid, \.b)
        let refMeanR = mean(refMid, \.r); let refMeanG = mean(refMid, \.g); let refMeanB = mean(refMid, \.b)

        // ── Per-channel std deviation from stable zone ──
        func std(_ arr: [RGBPixel], _ ch: KeyPath<RGBPixel, Double>, _ m: Float) -> Float {
            let v = arr.map { (Float($0[keyPath: ch]) - m) * (Float($0[keyPath: ch]) - m) }
            return sqrt(v.reduce(0, +) / Float(arr.count))
        }
        let srcStdR = std(srcMid, \.r, srcMeanR); let refStdR = std(refMid, \.r, refMeanR)
        let srcStdG = std(srcMid, \.g, srcMeanG); let refStdG = std(refMid, \.g, refMeanG)
        let srcStdB = std(srcMid, \.b, srcMeanB); let refStdB = std(refMid, \.b, refMeanB)

        // ── Contrast gain per channel (std ratio, capped at 1.5) ──
        // Pivoted around 0.5: output = (input - 0.5) * gain + 0.5
        // = input * gain + (0.5 - 0.5 * gain)
        // This expands contrast symmetrically around the midpoint,
        // so soft negatives don't get pushed entirely into highlights.
        let gainR = srcStdR > 0.001 ? min(refStdR / srcStdR, 1.5) : 1.0
        let gainG = srcStdG > 0.001 ? min(refStdG / srcStdG, 1.5) : 1.0
        let gainB = srcStdB > 0.001 ? min(refStdB / srcStdB, 1.5) : 1.0
        let biasR = 0.5 - 0.5 * gainR
        let biasG = 0.5 - 0.5 * gainG
        let biasB = 0.5 - 0.5 * gainB

        // ── Color temperature: per-channel mean ratio from stable zone, capped at 1.0 ──
        let ctR = srcMeanR > 0.001 ? min(refMeanR / srcMeanR, 1.0) : 1.0
        let ctG = srcMeanG > 0.001 ? min(refMeanG / srcMeanG, 1.0) : 1.0
        let ctB = srcMeanB > 0.001 ? min(refMeanB / srcMeanB, 1.0) : 1.0

        print("📊 Reference match — contrast R:\(String(format:"%.3f",gainR)) G:\(String(format:"%.3f",gainG)) B:\(String(format:"%.3f",gainB))")
        print("📊 Color temp      — gains   R:\(String(format:"%.3f",ctR)) G:\(String(format:"%.3f",ctG)) B:\(String(format:"%.3f",ctB))")

        // ── Step 1: apply contrast (pivot around 0.5) then color temp ──
        // contrast: output = input * gainX + biasX
        // color temp applied after: multiply by ctX
        // combined: output = (input * gainX + biasX) * ctX
        //                  = input * (gainX * ctX) + biasX * ctX
        let rG = gainR * ctR;  let rB = biasR * ctR
        let gG = gainG * ctG;  let gB = biasG * ctG
        let bG = gainB * ctB;  let bB = biasB * ctB

        let gainKernel = """
        kernel vec4 applyGain(sampler src, float rG, float rB, float gG, float gB, float bG, float bB) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(px.r*rG+rB, px.g*gG+gB, px.b*bG+bB, px.a);
        }
        """
        guard let gk = CIKernel(source: gainKernel) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let gained = gk.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image,
                                                 rG as NSNumber, rB as NSNumber,
                                                 gG as NSNumber, gB as NSNumber,
                                                 bG as NSNumber, bB as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }

        // ── Step 2: stretch output to full [0,1] per channel ──
        // Sample the gained image to find actual min/max per channel
        let gainedPixels = try samplePixels(gained, border: 0.01)
        var rs = gainedPixels.map { Float($0.r) }.sorted()
        var gs = gainedPixels.map { Float($0.g) }.sorted()
        var bs = gainedPixels.map { Float($0.b) }.sorted()
        let n = rs.count
        let loIdx = max(0,   Int(Float(n) * 0.005))
        let hiIdx = min(n-1, Int(Float(n) * 0.995))
        let rLo = rs[loIdx]; let rHi = rs[hiIdx]
        let gLo = gs[loIdx]; let gHi = gs[hiIdx]
        let bLo = bs[loIdx]; let bHi = bs[hiIdx]

        let sRG = rHi > rLo + 0.01 ? Float(1.0 / Double(rHi - rLo)) : 1.0
        let sGG = gHi > gLo + 0.01 ? Float(1.0 / Double(gHi - gLo)) : 1.0
        let sBG = bHi > bLo + 0.01 ? Float(1.0 / Double(bHi - bLo)) : 1.0
        let sRB = -rLo * sRG; let sGB = -gLo * sGG; let sBiasB = -bLo * sBG

        print("📊 Output stretch  — R:[\(String(format:"%.3f",rLo)),\(String(format:"%.3f",rHi))] G:[\(String(format:"%.3f",gLo)),\(String(format:"%.3f",gHi))] B:[\(String(format:"%.3f",bLo)),\(String(format:"%.3f",bHi))]")

        let stretchKernel = """
        kernel vec4 stretchOut(sampler src, float rG, float rB, float gG, float gB, float bG, float bB) {
            vec4 px = sample(src, samplerCoord(src));
            return vec4(clamp(px.r*rG+rB,0.0,1.0), clamp(px.g*gG+gB,0.0,1.0), clamp(px.b*bG+bB,0.0,1.0), px.a);
        }
        """
        guard let sk = CIKernel(source: stretchKernel) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let stretched = sk.apply(extent: gained.extent, roiCallback: { _, r in r },
                                        arguments: [gained,
                                                    sRG as NSNumber, sRB as NSNumber,
                                                    sGG as NSNumber, sGB as NSNumber,
                                                    sBG as NSNumber, sBiasB as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return stretched
    }

    // MARK: - Lab regional analysis

    private func analyseLabRegions(_ sizeRef: CIImage, image: CIImage) throws -> [LabStats] {
        let pixels = try samplePixelsXY(image, border: 0.10)
        var buckets = Array(repeating: [(Double, Double, Double)](), count: 9)
        for p in pixels {
            let col = min(2, Int(p.x * 3))
            let row = min(2, Int(p.y * 3))
            let lab = rgbToLab(r: p.r, g: p.g, b: p.b)
            buckets[row * 3 + col].append(lab)
        }
        return buckets.map { pts -> LabStats in
            guard !pts.isEmpty else { return LabStats() }
            var s = LabStats()
            s.lMean = pts.map { $0.0 }.reduce(0,+) / Double(pts.count)
            s.aMean = pts.map { $0.1 }.reduce(0,+) / Double(pts.count)
            s.bMean = pts.map { $0.2 }.reduce(0,+) / Double(pts.count)
            s.lStd  = stdDev(pts.map { $0.0 }, mean: s.lMean)
            s.aStd  = stdDev(pts.map { $0.1 }, mean: s.aMean)
            s.bStd  = stdDev(pts.map { $0.2 }, mean: s.bMean)
            return s
        }
    }

    // MARK: - Lab transfer (a+b channels only — preserves source luminance)

    private func applyLabABTransfer(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcStats = try analyseLabRegions(image, image: image)
        let refStats = try analyseLabRegions(image, image: reference)

        func combined(_ s: [LabStats]) -> LabStats {
            let n = Double(s.count)
            var r = LabStats()
            r.lMean = s.map{$0.lMean}.reduce(0,+)/n
            r.aMean = s.map{$0.aMean}.reduce(0,+)/n
            r.bMean = s.map{$0.bMean}.reduce(0,+)/n
            r.lStd  = s.map{$0.lStd }.reduce(0,+)/n
            r.aStd  = s.map{$0.aStd }.reduce(0,+)/n
            r.bStd  = s.map{$0.bStd }.reduce(0,+)/n
            return r
        }

        let src = combined(srcStats)
        let ref = combined(refStats)

        print("📊 Src Lab — L:\(String(format:"%.1f",src.lMean))±\(String(format:"%.1f",src.lStd)) a:\(String(format:"%.1f",src.aMean)) b:\(String(format:"%.1f",src.bMean))")
        print("📊 Ref Lab — L:\(String(format:"%.1f",ref.lMean))±\(String(format:"%.1f",ref.lStd)) a:\(String(format:"%.1f",ref.aMean)) b:\(String(format:"%.1f",ref.bMean))")

        // Transfer a+b only — L untouched (lGain=1, lBias=0)
        let aGain = Float(src.aStd > 0.001 ? ref.aStd / src.aStd : 1.0)
        let bGain = Float(src.bStd > 0.001 ? ref.bStd / src.bStd : 1.0)
        let aBias = Float(ref.aMean - Double(aGain) * src.aMean)
        let bBias = Float(ref.bMean - Double(bGain) * src.bMean)

        print("📊 Lab a+b transfer — aGain:\(String(format:"%.3f",aGain)) aBias:\(String(format:"%.2f",aBias)) bGain:\(String(format:"%.3f",bGain)) bBias:\(String(format:"%.2f",bBias))")

        let kernelSrc = """
        kernel vec4 labABTransfer(sampler src,
                                  float aGain, float aBias,
                                  float bGain, float bBias) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);

            float x = r*0.4124564 + g*0.3575761 + b*0.1804375;
            float y = r*0.2126729 + g*0.7151522 + b*0.0721750;
            float z = r*0.0193339 + g*0.1191920 + b*0.9503041;

            float xn = x/0.95047; float yn = y/1.00000; float zn = z/1.08883;
            float fx = xn > 0.008856 ? pow(xn,0.333333) : 7.787*xn+0.137931;
            float fy = yn > 0.008856 ? pow(yn,0.333333) : 7.787*yn+0.137931;
            float fz = zn > 0.008856 ? pow(zn,0.333333) : 7.787*zn+0.137931;
            float L = 116.0*fy - 16.0;
            float A = 500.0*(fx - fy);
            float B = 200.0*(fy - fz);

            // Transfer a+b only — L unchanged
            A = clamp(A * aGain + aBias, -128.0, 127.0);
            B = clamp(B * bGain + bBias, -128.0, 127.0);

            float fy2 = (L+16.0)/116.0;
            float fx2 = A/500.0 + fy2;
            float fz2 = fy2 - B/200.0;
            float x2 = fx2 > 0.206897 ? fx2*fx2*fx2 : (fx2-0.137931)/7.787;
            float y2 = fy2 > 0.206897 ? fy2*fy2*fy2 : (fy2-0.137931)/7.787;
            float z2 = fz2 > 0.206897 ? fz2*fz2*fz2 : (fz2-0.137931)/7.787;
            x2 *= 0.95047; y2 *= 1.00000; z2 *= 1.08883;

            float ro = x2*3.2404542 - y2*1.5371385 - z2*0.4985314;
            float go = -x2*0.9692660 + y2*1.8760108 + z2*0.0415560;
            float bo = x2*0.0556434 - y2*0.2040259 + z2*1.0572252;

            float knee = 0.9;
            float rs = ro <= knee ? ro : knee + (1.0-knee)*(1.0-exp(-(ro-knee)/(1.0-knee)));
            float gs = go <= knee ? go : knee + (1.0-knee)*(1.0-exp(-(go-knee)/(1.0-knee)));
            float bs = bo <= knee ? bo : knee + (1.0-knee)*(1.0-exp(-(bo-knee)/(1.0-knee)));
            float shadow = 0.1;
            float rf = rs >= shadow ? rs : shadow*(1.0-exp(-rs/shadow));
            float gf = gs >= shadow ? gs : shadow*(1.0-exp(-gs/shadow));
            float bf = bs >= shadow ? bs : shadow*(1.0-exp(-bs/shadow));

            return vec4(clamp(rf,0.0,1.0), clamp(gf,0.0,1.0), clamp(bf,0.0,1.0), px.a);
        }
        """

        guard let kernel = CIKernel(source: kernelSrc) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image,
                        aGain as NSNumber, aBias as NSNumber,
                        bGain as NSNumber, bBias as NSNumber]
        ) else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - RGB → Lab helpers

    private func rgbToLab(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let x = r*0.4124564 + g*0.3575761 + b*0.1804375
        let y = r*0.2126729 + g*0.7151522 + b*0.0721750
        let z = r*0.0193339 + g*0.1191920 + b*0.9503041
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t,1.0/3.0) : 7.787*t+16.0/116.0 }
        let fx = f(x/0.95047); let fy = f(y/1.00000); let fz = f(z/1.08883)
        return (116.0*fy-16.0, 500.0*(fx-fy), 200.0*(fy-fz))
    }

    private func stdDev(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 1.0 }
        let v = values.map { ($0-mean)*($0-mean) }.reduce(0,+) / Double(values.count)
        return max(sqrt(v), 0.001)
    }

    // MARK: - BW luminance matching (used for desaturated color source + BW reference)
    //
    // Same stable-zone philosophy as applyReference:
    // Uses middle 80% of tonal range, contrast gain only (no bias), then stretches output.

    private func histogramMatchLuminance(_ image: CIImage, reference: CIImage) throws -> CIImage {
        let srcPixels = try samplePixels(image, border: 0.15)
        let refPixels = try samplePixels(reference, border: 0.15)
        let srcLums = srcPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()
        let refLums = refPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()

        // Middle 80% of each
        func middle80(_ arr: [Float]) -> [Float] {
            let lo = arr[Int(Float(arr.count) * 0.10)]
            let hi = arr[Int(Float(arr.count) * 0.90)]
            return arr.filter { $0 >= lo && $0 <= hi }
        }
        let srcMid = middle80(srcLums)
        let refMid = middle80(refLums)
        guard !srcMid.isEmpty && !refMid.isEmpty else { return image }

        let srcMean = srcMid.reduce(0, +) / Float(srcMid.count)
        let refMean = refMid.reduce(0, +) / Float(refMid.count)
        let srcStd  = sqrt(srcMid.map { ($0-srcMean)*($0-srcMean) }.reduce(0,+) / Float(srcMid.count))
        let refStd  = sqrt(refMid.map { ($0-refMean)*($0-refMean) }.reduce(0,+) / Float(refMid.count))

        // Contrast gain, capped at 1.5, pivoted around 0.5
        // output = (input - 0.5) * gain + 0.5 = input * gain + (0.5 - 0.5 * gain)
        let gain = srcStd > 0.001 ? min(refStd / srcStd, 1.5) : 1.0
        let bias = 0.5 - 0.5 * gain

        print("📊 BW luminance match — srcStd: \(String(format:"%.3f",srcStd)) refStd: \(String(format:"%.3f",refStd)) gain: \(String(format:"%.3f",gain))")

        // Build LUT: output = input * gain + bias, clamped
        let bins = 256
        var mapping = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            let x = Float(i) / Float(bins - 1)
            mapping[i] = min(1.0, max(0.0, x * gain + bias))
        }

        // Apply mapping
        let mapped = try applyLuminanceMapping(image, mapping: mapping, bins: bins)

        // Stretch output to full range
        let mappedPixels = try samplePixels(mapped, border: 0.01)
        var lums2 = mappedPixels.map { Float($0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722) }.sorted()
        let n = lums2.count
        let loVal = lums2[max(0, Int(Float(n) * 0.005))]
        let hiVal = lums2[min(n-1, Int(Float(n) * 0.995))]
        guard hiVal > loVal + 0.01 else { return mapped }
        let sGain = Float(1.0 / Double(hiVal - loVal))
        let sBias = -loVal * sGain

        print("📊 BW output stretch — [\(String(format:"%.3f",loVal)),\(String(format:"%.3f",hiVal))]")

        let stretchKernel = """
        kernel vec4 stretchBW(sampler src, float sG, float sB) {
            vec4 px = sample(src, samplerCoord(src));
            float v = clamp(px.r*sG+sB, 0.0, 1.0);
            return vec4(v, v, v, px.a);
        }
        """
        guard let sk = CIKernel(source: stretchKernel) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = sk.apply(extent: mapped.extent, roiCallback: { _, r in r },
                                  arguments: [mapped, sGain as NSNumber, sBias as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

        // Apply a 256-entry luminance mapping to full-res image on CPU.
    // Scales RGB channels proportionally to preserve color ratios.
    // Used by the BW reference path (desaturate + L match).
    private func applyLuminanceMapping(_ image: CIImage, mapping: [Float], bins: Int) throws -> CIImage {
        guard let cg = context.createCGImage(image, from: image.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data else {
            throw ProcessingErrorColor.failedToProcessImage
        }

        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let dataLen = h * bpr
        var pixels = [UInt8](repeating: 0, count: dataLen)
        CFDataGetBytes(cfData, CFRange(location: 0, length: dataLen), &pixels)

        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                let r = Float(pixels[i])   / 255.0
                let g = Float(pixels[i+1]) / 255.0
                let b = Float(pixels[i+2]) / 255.0
                let lum = r * 0.2126 + g * 0.7152 + b * 0.0722
                if lum > 0.001 {
                    let bin = min(bins-1, Int(lum * Float(bins)))
                    let ratio = mapping[bin] / lum
                    pixels[i]   = UInt8(min(255, max(0, Int(r * ratio * 255.0 + 0.5))))
                    pixels[i+1] = UInt8(min(255, max(0, Int(g * ratio * 255.0 + 0.5))))
                    pixels[i+2] = UInt8(min(255, max(0, Int(b * ratio * 255.0 + 0.5))))
                } else {
                    // Very dark pixels: map directly via lookup, no ratio needed
                    let mapped = mapping[0]
                    let v = UInt8(min(255, max(0, Int(mapped * 255.0 + 0.5))))
                    pixels[i] = v; pixels[i+1] = v; pixels[i+2] = v
                }
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ProcessingErrorColor.failedToProcessImage
        }
        let data = Data(pixels)
        return try data.withUnsafeBytes { ptr -> CIImage in
            guard let base = ptr.baseAddress,
                  let newProvider = CGDataProvider(dataInfo: nil, data: base, size: dataLen,
                                                   releaseData: { _, _, _ in }),
                  let newCG = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: bpr, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: newProvider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent)
            else { throw ProcessingErrorColor.failedToProcessImage }
            return CIImage(cgImage: newCG)
        }
    }

    // MARK: - Pixel sampling

    private func samplePixels(_ image: CIImage, border: Double) throws -> [RGBPixel] {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data,
              let data = CFDataGetBytePtr(cfData) else { throw ProcessingErrorColor.failedToProcessImage }
        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let x0 = Int(Double(w)*border); let x1 = w-x0
        let y0 = Int(Double(h)*border); let y1 = h-y0
        var result: [RGBPixel] = []
        result.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y*bpr + x*4
                result.append((r: Double(data[i])/255.0,
                               g: Double(data[i+1])/255.0,
                               b: Double(data[i+2])/255.0))
            }
        }
        return result
    }


    private func samplePixelsXY(_ image: CIImage, border: Double) throws -> [RGBPixelXY] {
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent,
                                              format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB()),
              let provider = cg.dataProvider,
              let cfData = provider.data,
              let data = CFDataGetBytePtr(cfData) else { throw ProcessingErrorColor.failedToProcessImage }
        let w = cg.width; let h = cg.height; let bpr = cg.bytesPerRow
        let x0 = Int(Double(w)*border); let x1 = w-x0
        let y0 = Int(Double(h)*border); let y1 = h-y0
        let innerW = Double(x1-x0); let innerH = Double(y1-y0)
        var result: [RGBPixelXY] = []
        result.reserveCapacity((x1-x0)*(y1-y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y*bpr + x*4
                let nx = Double(x-x0) / innerW
                let ny = Double(y-y0) / innerH
                result.append((x: nx, y: ny,
                               r: Double(data[i])/255.0,
                               g: Double(data[i+1])/255.0,
                               b: Double(data[i+2])/255.0))
            }
        }
        return result
    }

    // MARK: - Normalize midtones

    // Measures mean Lab L* of the image. If far from middle grey (50.0),
    // applies a partial gamma correction to L only — a and b channels untouched.
    private func normalizeMidtonesColor(_ image: CIImage) throws -> CIImage {
        let pixels = try samplePixels(image, border: 0.10)
        let lValues = pixels.map { rgbToLab(r: $0.r, g: $0.g, b: $0.b).0 }
        let meanL = lValues.reduce(0, +) / Double(lValues.count)
        let stdL  = stdDev(lValues, mean: meanL)
        print("📊 COLOR Brightness analysis: meanL=\(String(format:"%.1f",meanL)) stdL=\(String(format:"%.1f",stdL)) (target=\(targetLMean))")

        let distance = targetLMean - meanL   // positive = image too dark, negative = too bright
        guard abs(distance) > 2.0 else {
            print("ℹ️ COLOR Brightness: meanL within 2.0 of target, skipping")
            return image
        }

        // Partial correction: move only a fraction of the distance to target
        let correctedMeanL = meanL + distance * maxBrightnessCorrection
        // Express as gamma on L/100 scale
        let lNorm = meanL / 100.0
        let lTarget = correctedMeanL / 100.0
        guard lNorm > 0.01 && lNorm < 0.99 else {
            print("⚠️ COLOR Brightness: meanL out of usable range, skipping")
            return image
        }
        let gamma = Float(log(lTarget) / log(lNorm))
        print("📊 COLOR Brightness correction: distance=\(String(format:"%.1f",distance)) correctedTarget=\(String(format:"%.1f",correctedMeanL)) gamma=\(String(format:"%.3f",gamma))")

        let src = """
        kernel vec4 balanceBrightnessLab(sampler src, float gamma) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);
            // RGB -> XYZ
            float x = r*0.4124564 + g*0.3575761 + b*0.1804375;
            float y = r*0.2126729 + g*0.7151522 + b*0.0721750;
            float z = r*0.0193339 + g*0.1191920 + b*0.9503041;
            // XYZ -> Lab
            float xn=x/0.95047; float yn=y/1.00000; float zn=z/1.08883;
            float fx = xn>0.008856 ? pow(xn,0.333333) : 7.787*xn+0.137931;
            float fy = yn>0.008856 ? pow(yn,0.333333) : 7.787*yn+0.137931;
            float fz = zn>0.008856 ? pow(zn,0.333333) : 7.787*zn+0.137931;
            float L = 116.0*fy - 16.0;
            float A = 500.0*(fx - fy);
            float B = 200.0*(fy - fz);
            // Apply gamma to L only (normalised to 0-1 range)
            float Ln = clamp(L/100.0, 0.001, 1.0);
            float Lnew = clamp(pow(Ln, gamma) * 100.0, 0.0, 100.0);
            // Lab -> XYZ
            float fy2 = (Lnew+16.0)/116.0;
            float fx2 = A/500.0 + fy2;
            float fz2 = fy2 - B/200.0;
            float x2 = fx2>0.206897 ? fx2*fx2*fx2 : (fx2-0.137931)/7.787;
            float y2 = fy2>0.206897 ? fy2*fy2*fy2 : (fy2-0.137931)/7.787;
            float z2 = fz2>0.206897 ? fz2*fz2*fz2 : (fz2-0.137931)/7.787;
            x2*=0.95047; y2*=1.00000; z2*=1.08883;
            // XYZ -> RGB
            float ro = x2* 3.2404542 - y2*1.5371385 - z2*0.4985314;
            float go = x2*-0.9692660 + y2*1.8760108 + z2*0.0415560;
            float bo = x2* 0.0556434 - y2*0.2040259 + z2*1.0572252;
            return vec4(clamp(ro,0.0,1.0), clamp(go,0.0,1.0), clamp(bo,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, gamma as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Balance contrast
    //
    // Boosts contrast only — never reduces. Works on Lab L only so color is unaffected.
    // Flat images (L std dev below targetLStd * contrastDeadzone) get an S-curve boost.
    // Images with sufficient contrast are left untouched.

    func balanceContrastColor(_ image: CIImage) throws -> CIImage {
        let pixels = try samplePixels(image, border: 0.10)
        let lValues = pixels.map { rgbToLab(r: $0.r, g: $0.g, b: $0.b).0 }
        let meanL = lValues.reduce(0, +) / Double(lValues.count)
        let stdL  = stdDev(lValues, mean: meanL)
        print("📊 COLOR Contrast analysis: stdL=\(String(format:"%.1f",stdL)) meanL=\(String(format:"%.1f",meanL)) (target stdL=\(targetLStd))")

        let threshold = targetLStd * contrastDeadzone
        guard stdL < threshold else {
            print("ℹ️ COLOR Contrast: stdL=\(String(format:"%.1f",stdL)) >= threshold \(String(format:"%.1f",threshold)), skipping")
            return image
        }

        // k proportional to how flat the image is, capped at maxContrastK
        let k = Float(min(targetLStd / stdL * 2.0, Double(maxContrastK)))
        print("📊 COLOR Contrast boost: stdL=\(String(format:"%.1f",stdL)) k=\(String(format:"%.2f",k))")

        // S-curve applied to L only in Lab space
        let src = """
        kernel vec4 balanceContrastLab(sampler src, float k) {
            vec4 px = sample(src, samplerCoord(src));
            float r = clamp(px.r, 0.0, 1.0);
            float g = clamp(px.g, 0.0, 1.0);
            float b = clamp(px.b, 0.0, 1.0);
            // RGB -> XYZ -> Lab
            float x = r*0.4124564 + g*0.3575761 + b*0.1804375;
            float y = r*0.2126729 + g*0.7151522 + b*0.0721750;
            float z = r*0.0193339 + g*0.1191920 + b*0.9503041;
            float xn=x/0.95047; float yn=y/1.00000; float zn=z/1.08883;
            float fx = xn>0.008856 ? pow(xn,0.333333) : 7.787*xn+0.137931;
            float fy = yn>0.008856 ? pow(yn,0.333333) : 7.787*yn+0.137931;
            float fz = zn>0.008856 ? pow(zn,0.333333) : 7.787*zn+0.137931;
            float L = 116.0*fy - 16.0;
            float A = 500.0*(fx - fy);
            float B = 200.0*(fy - fz);
            // S-curve on L (normalised 0-1, pivot at 0.5)
            float Ln = L / 100.0;
            float s0 = 1.0/(1.0+exp( k*0.5));
            float s1 = 1.0/(1.0+exp(-k*0.5));
            float Lnew = clamp(((1.0/(1.0+exp(-k*(Ln-0.5)))-s0)/(s1-s0)) * 100.0, 0.0, 100.0);
            // Lab -> XYZ -> RGB
            float fy2 = (Lnew+16.0)/116.0;
            float fx2 = A/500.0 + fy2;
            float fz2 = fy2 - B/200.0;
            float x2 = fx2>0.206897 ? fx2*fx2*fx2 : (fx2-0.137931)/7.787;
            float y2 = fy2>0.206897 ? fy2*fy2*fy2 : (fy2-0.137931)/7.787;
            float z2 = fz2>0.206897 ? fz2*fz2*fz2 : (fz2-0.137931)/7.787;
            x2*=0.95047; y2*=1.00000; z2*=1.08883;
            float ro = x2* 3.2404542 - y2*1.5371385 - z2*0.4985314;
            float go = x2*-0.9692660 + y2*1.8760108 + z2*0.0415560;
            float bo = x2* 0.0556434 - y2*0.2040259 + z2*1.0572252;
            return vec4(clamp(ro,0.0,1.0), clamp(go,0.0,1.0), clamp(bo,0.0,1.0), px.a);
        }
        """
        guard let kernel = CIKernel(source: src) else { throw ProcessingErrorColor.failedToProcessImage }
        guard let out = kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                     arguments: [image, k as NSNumber])
        else { throw ProcessingErrorColor.failedToProcessImage }
        return out
    }

    // MARK: - Save

    private func saveImage(_ image: CIImage, to url: URL, outputFormat: OutputFormat) throws {
        let w = Int(image.extent.width); let h = Int(image.extent.height)
        guard let rgbCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ProcessingErrorColor.failedToCreateCGImage }
        guard let ciCG = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                               colorSpace: CGColorSpaceCreateDeviceRGB())
        else { throw ProcessingErrorColor.failedToCreateCGImage }
        rgbCtx.draw(ciCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = rgbCtx.makeImage() else { throw ProcessingErrorColor.failedToCreateCGImage }
        let utType: CFString = outputFormat == .tiff ? UTType.tiff.identifier as CFString : UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil)
        else { throw ProcessingErrorColor.failedToCreateDestination }
        let options: [CFString: Any] = outputFormat == .tiff ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ProcessingErrorColor.failedToSaveImage }
        print("✓ COLOR: Saved as \(outputFormat == .tiff ? "TIFF" : "JPEG")")
    }

    // MARK: - Generate output URL

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

*/
