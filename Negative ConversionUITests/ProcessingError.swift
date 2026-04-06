//
//  ProcessingError.swift
//  Negative Conversion
//
//  Created by Ari Jaaksi on 25.9.2025.
//


//
//  ConversionLogic.swift
//  Negative Conversion
//
//  Created by Ari Jaaksi on 25.9.2025.
//
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

// MARK: - Enums and Types
enum ProcessingError: LocalizedError {
    case failedToLoadImage
    case failedToProcessImage
    case failedToAccessFile
    case failedToLoadRAWImage
    case failedToCreateCGImage
    case failedToCreateDestination
    case failedToSaveImage
    
    var errorDescription: String? {
        switch self {
        case .failedToLoadImage: return "Failed to load image file"
        case .failedToProcessImage: return "Failed to process image"
        case .failedToAccessFile: return "Failed to access file"
        case .failedToLoadRAWImage: return "Failed to load RAW image"
        case .failedToCreateCGImage: return "Failed to create output image"
        case .failedToCreateDestination: return "Failed to create output file destination"
        case .failedToSaveImage: return "Failed to save processed image"
        }
    }
}

enum ConversionAlgorithm {
    case simpleInversion
    case hybridAutoCorrection
}

enum NegativeType {
    case blackAndWhite
    case colorNegative
}

struct ImageStats {
    let redMean: Double
    let greenMean: Double
    let blueMean: Double
    let colorVariance: Double
    let orangeMaskStrength: Double
}

// MARK: - Image Processor
class ImageProcessor {
    private let context = CIContext()
    
    func convertImage(sourceURL: URL) async throws {
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ProcessingError.failedToAccessFile
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        
        print("Processing: \(sourceURL.lastPathComponent)")
        
        let inputImage = try loadImage(from: sourceURL)
        print("✓ Loaded: \(inputImage.extent.width)x\(inputImage.extent.height)")
        
        let processedImage = try applyHybridAutoCorrection(inputImage)
        print("✓ Processed")
        
        let outputURL = generateOutputURL(from: sourceURL)
        try saveImage(processedImage, to: outputURL)
        print("✓ Saved: \(outputURL.lastPathComponent)")
    }
    
    // MARK: - Image Loading
    private func loadImage(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWImage(from: url)
        } else {
            guard let image = CIImage(contentsOf: url) else {
                throw ProcessingError.failedToLoadImage
            }
            return image
        }
    }
    
    private func loadRAWImage(from url: URL) throws -> CIImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ProcessingError.failedToLoadRAWImage
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
            throw ProcessingError.failedToLoadRAWImage
        }
        
        return CIImage(cgImage: cgImage)
    }
    
    // MARK: - Main Algorithm
    private func applyHybridAutoCorrection(_ image: CIImage) throws -> CIImage {
        print("🔍 Starting hybrid auto-correction...")
        
        // Step 1: Analyze the ORIGINAL NEGATIVE (before inversion!)
        let originalStats = try analyzeImage(image)
        let negativeType = detectNegativeType(from: originalStats)
        
        print("📊 Detected: \(negativeType)")
        print("📊 Original negative RGB means: R:\(String(format: "%.2f", originalStats.redMean)) G:\(String(format: "%.2f", originalStats.greenMean)) B:\(String(format: "%.2f", originalStats.blueMean))")
        
        // Step 2: Basic inversion
        var result = try simpleInversion(image)
        print("✓ Basic inversion applied")
        
        // Step 3: Remove orange mask for color negatives
        if negativeType == .colorNegative {
            result = try removeOrangeMask(result, stats: originalStats)
            print("✓ Orange mask removed")
        }
        
        // Step 4: Apply histogram-based tone mapping
        result = try applyHistogramNormalization(result)
        print("✓ Histogram-based tone mapping applied")
        
        return result
    }
    
    private func simpleInversion(_ image: CIImage) throws -> CIImage {
        let filter = CIFilter.colorInvert()
        filter.inputImage = image
        
        guard let output = filter.outputImage else {
            throw ProcessingError.failedToProcessImage
        }
        
        return output
    }
    
    // MARK: - Tone-Preserving Analysis
    private func applyHistogramNormalization(_ image: CIImage) throws -> CIImage {
        print("📊 Analyzing negative's tonal richness for preservation...")
        
        // Get detailed histogram analysis
        let histogram = try calculateHistogram(image)
        let toneAnalysis = analyzeTonalDistribution(histogram)
        
        print("📊 Tonal analysis: shadows=\(String(format: "%.1f", toneAnalysis.shadowDensity))%, midtones=\(String(format: "%.1f", toneAnalysis.midtoneDensity))%, highlights=\(String(format: "%.1f", toneAnalysis.highlightDensity))%")
        print("📊 Contrast richness: \(String(format: "%.2f", toneAnalysis.contrastRichness))")
        
        // Instead of forcing to arbitrary targets, preserve the original's tonal distribution
        return try applyTonePreservingMapping(image, analysis: toneAnalysis)
    }
    
    private struct TonalAnalysis {
        let shadowDensity: Double      // % of pixels in shadows (0-33%)
        let midtoneDensity: Double     // % of pixels in midtones (33-66%)
        let highlightDensity: Double   // % of pixels in highlights (66-100%)
        let contrastRichness: Double   // How spread out the tones are (0-1)
        let shadowPoint: Double        // Where meaningful shadows start
        let highlightPoint: Double     // Where meaningful highlights start
        let midtoneCenter: Double      // Center of midtone mass
    }
    
    private func analyzeTonalDistribution(_ histogram: [Int]) -> TonalAnalysis {
        let totalPixels = histogram.reduce(0, +)
        
        // Calculate density in each third
        let shadowPixels = histogram[0..<85].reduce(0, +)   // 0-33% = shadows
        let midtonePixels = histogram[85..<170].reduce(0, +) // 33-66% = midtones
        let highlightPixels = histogram[170..<256].reduce(0, +) // 66-100% = highlights
        
        let shadowDensity = Double(shadowPixels) / Double(totalPixels) * 100
        let midtoneDensity = Double(midtonePixels) / Double(totalPixels) * 100
        let highlightDensity = Double(highlightPixels) / Double(totalPixels) * 100
        
        // Calculate how spread out the histogram is (contrast richness)
        var weightedSum = 0.0
        var pixelSum = 0
        for (value, count) in histogram.enumerated() {
            weightedSum += Double(value * count)
            pixelSum += count
        }
        let mean = weightedSum / Double(pixelSum)
        
        var variance = 0.0
        for (value, count) in histogram.enumerated() {
            variance += Double(count) * pow(Double(value) - mean, 2)
        }
        variance /= Double(pixelSum)
        let contrastRichness = min(1.0, sqrt(variance) / 64.0) // Normalize to 0-1
        
        // Find meaningful points (where substantial content exists)
        let shadowPoint = Double(findPercentile(histogram, percentile: 0.10)) / 255.0
        let highlightPoint = Double(findPercentile(histogram, percentile: 0.90)) / 255.0
        let midtoneCenter = Double(findPercentile(histogram, percentile: 0.50)) / 255.0
        
        return TonalAnalysis(
            shadowDensity: shadowDensity,
            midtoneDensity: midtoneDensity,
            highlightDensity: highlightDensity,
            contrastRichness: contrastRichness,
            shadowPoint: shadowPoint,
            highlightPoint: highlightPoint,
            midtoneCenter: midtoneCenter
        )
    }
    
    private func applyTonePreservingMapping(_ image: CIImage, analysis: TonalAnalysis) throws -> CIImage {
        print("📊 Applying tone-preserving mapping to maintain richness...")
        
        // Base the target range on the image's own characteristics
        let targetShadow = max(0.02, 0.15 - analysis.contrastRichness * 0.10)    // Rich images can have deeper shadows
        let targetHighlight = min(0.98, 0.85 + analysis.contrastRichness * 0.10) // Rich images can have brighter highlights
        
        print("📊 Adaptive targets: shadows=\(String(format: "%.3f", targetShadow)), highlights=\(String(format: "%.3f", targetHighlight))")
        
        // Use a curve that preserves midtone relationships instead of linear stretching
        return try applyAdaptiveCurve(image,
                                    inputShadow: analysis.shadowPoint,
                                    inputHighlight: analysis.highlightPoint,
                                    inputMidtone: analysis.midtoneCenter,
                                    outputShadow: targetShadow,
                                    outputHighlight: targetHighlight,
                                    contrastRichness: analysis.contrastRichness)
    }
    
    private func applyAdaptiveCurve(_ image: CIImage,
                                  inputShadow: Double, inputHighlight: Double, inputMidtone: Double,
                                  outputShadow: Double, outputHighlight: Double,
                                  contrastRichness: Double) throws -> CIImage {
        
        print("📊 Building adaptive curve: input[\(String(format: "%.3f", inputShadow))-\(String(format: "%.3f", inputMidtone))-\(String(format: "%.3f", inputHighlight))] → output[\(String(format: "%.3f", outputShadow))-0.50-\(String(format: "%.3f", outputHighlight))]")
        
        // Create a smooth curve that maintains tonal relationships
        guard let curvesFilter = CIFilter(name: "CIToneCurve") else {
            print("⚠️ Tone curves not available, using gentle linear adjustment")
            return try applyGentleLinearAdjustment(image, inputShadow: inputShadow, inputHighlight: inputHighlight,
                                                 outputShadow: outputShadow, outputHighlight: outputHighlight)
        }
        
        // Calculate midtone target to preserve relationships
        let outputMidtone = 0.5 // Keep midtones centered, let shadows/highlights do the work
        
        // Build curve points that preserve tonal spacing
        curvesFilter.setValue(image, forKey: kCIInputImageKey)
        curvesFilter.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0") // Pure black → pure black
        curvesFilter.setValue(CIVector(x: inputShadow, y: outputShadow), forKey: "inputPoint1") // Shadow mapping
        curvesFilter.setValue(CIVector(x: inputMidtone, y: outputMidtone), forKey: "inputPoint2") // Midtone preservation
        curvesFilter.setValue(CIVector(x: inputHighlight, y: outputHighlight), forKey: "inputPoint3") // Highlight mapping
        curvesFilter.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4") // Pure white → pure white
        
        guard let curved = curvesFilter.outputImage else {
            print("⚠️ Curve creation failed, using linear fallback")
            return try applyGentleLinearAdjustment(image, inputShadow: inputShadow, inputHighlight: inputHighlight,
                                                 outputShadow: outputShadow, outputHighlight: outputHighlight)
        }
        
        // Apply additional contrast boost based on the image's natural richness
        let contrastBoost = 1.0 + (contrastRichness * 0.3) // Rich images get more contrast
        print("📊 Applying richness-based contrast boost: \(String(format: "%.2f", contrastBoost))")
        
        guard let contrastFilter = CIFilter(name: "CIColorControls") else {
            return curved
        }
        
        contrastFilter.setValue(curved, forKey: kCIInputImageKey)
        contrastFilter.setValue(contrastBoost, forKey: kCIInputContrastKey)
        contrastFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        contrastFilter.setValue(1.1, forKey: kCIInputSaturationKey) // Slight saturation boost
        
        guard let final = contrastFilter.outputImage else {
            return curved
        }
        
        print("✓ Applied tone-preserving curve with richness boost")
        return final
    }
    
    private func applyGentleLinearAdjustment(_ image: CIImage, inputShadow: Double, inputHighlight: Double,
                                           outputShadow: Double, outputHighlight: Double) throws -> CIImage {
        let inputRange = inputHighlight - inputShadow
        let outputRange = outputHighlight - outputShadow
        
        let contrast = min(2.0, outputRange / max(0.1, inputRange))
        let brightness = outputShadow - inputShadow * contrast
        
        guard let filter = CIFilter(name: "CIColorControls") else {
            throw ProcessingError.failedToProcessImage
        }
        
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(1.0, forKey: kCIInputSaturationKey)
        
        guard let output = filter.outputImage else {
            throw ProcessingError.failedToProcessImage
        }
        
        print("✓ Applied gentle linear tone mapping")
        return output
    }
    

    
    private func applyMinimalContrast(_ image: CIImage) throws -> CIImage {
        print("📊 Applying minimal contrast for problematic histogram")
        
        guard let filter = CIFilter(name: "CIColorControls") else {
            throw ProcessingError.failedToProcessImage
        }
        
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.2, forKey: kCIInputContrastKey)    // Very gentle
        filter.setValue(0.0, forKey: kCIInputBrightnessKey)  // No brightness change
        filter.setValue(1.0, forKey: kCIInputSaturationKey)
        
        guard let output = filter.outputImage else {
            throw ProcessingError.failedToProcessImage
        }
        
        print("✓ Applied minimal contrast boost")
        return output
    }
    
    // MARK: - Histogram Calculation (Core Area Only)
    private func calculateHistogram(_ image: CIImage) throws -> [Int] {
        // Create a smaller version for histogram calculation
        let scale = min(256.0 / image.extent.width, 256.0 / image.extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = image.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent),
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw ProcessingError.failedToProcessImage
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Calculate core area bounds (excluding 10% border on each side)
        let borderPercent = 0.10
        let leftBorder = Int(Double(width) * borderPercent)
        let rightBorder = width - Int(Double(width) * borderPercent)
        let topBorder = Int(Double(height) * borderPercent)
        let bottomBorder = height - Int(Double(height) * borderPercent)
        
        print("📊 Building histogram from core area only (excluding film edges)")
        
        // Create luminance histogram (0-255) from core area only
        var histogram = Array(repeating: 0, count: 256)
        
        for y in topBorder..<bottomBorder {
            for x in leftBorder..<rightBorder {
                let pixelIndex = (y * width + x) * 4
                
                // Safety check for bounds
                guard pixelIndex + 2 < cgImage.bytesPerRow * height else { continue }
                
                let red = Int(data[pixelIndex])
                let green = Int(data[pixelIndex + 1])
                let blue = Int(data[pixelIndex + 2])
                
                // Calculate luminance using standard weights
                let luminance = Int(0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue))
                let clampedLuminance = max(0, min(255, luminance))
                
                histogram[clampedLuminance] += 1
            }
        }
        
        let totalCorePixels = histogram.reduce(0, +)
        print("📊 Histogram built from \(totalCorePixels) core pixels (film edges excluded)")
        
        return histogram
    }
    
    private func findPercentile(_ histogram: [Int], percentile: Double) -> Int {
        let totalPixels = histogram.reduce(0, +)
        let targetPixels = Int(Double(totalPixels) * percentile)
        
        var accumulatedPixels = 0
        
        for (value, count) in histogram.enumerated() {
            accumulatedPixels += count
            if accumulatedPixels >= targetPixels {
                return value
            }
        }
        
        return 255 // Fallback
    }
    
    // MARK: - Image Analysis (Core Area Only)
    private func analyzeImage(_ image: CIImage) throws -> ImageStats {
        // Scale down for faster analysis
        let scale = min(512.0 / image.extent.width, 512.0 / image.extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = image.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent),
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw ProcessingError.failedToProcessImage
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Calculate core area bounds (excluding 10% border on each side)
        let borderPercent = 0.10
        let leftBorder = Int(Double(width) * borderPercent)
        let rightBorder = width - Int(Double(width) * borderPercent)
        let topBorder = Int(Double(height) * borderPercent)
        let bottomBorder = height - Int(Double(height) * borderPercent)
        
        let coreWidth = rightBorder - leftBorder
        let coreHeight = bottomBorder - topBorder
        let corePixels = coreWidth * coreHeight
        
        print("📊 Analyzing core area: \(coreWidth)x\(coreHeight) (excluding 10% borders)")
        print("📊 Core area: (\(leftBorder),\(topBorder)) to (\(rightBorder),\(bottomBorder))")
        
        let step = max(1, corePixels / 5000) // Sample ~5k pixels from core area
        
        var redSum = 0.0, greenSum = 0.0, blueSum = 0.0
        var sampleCount = 0
        
        // Only analyze pixels within the core area
        for y in stride(from: topBorder, to: bottomBorder, by: max(1, Int(sqrt(Double(step))))) {
            for x in stride(from: leftBorder, to: rightBorder, by: max(1, Int(sqrt(Double(step))))) {
                let pixelIndex = (y * width + x) * 4
                
                // Safety check for bounds
                guard pixelIndex + 2 < cgImage.bytesPerRow * height else { continue }
                
                let red = Double(data[pixelIndex]) / 255.0
                let green = Double(data[pixelIndex + 1]) / 255.0
                let blue = Double(data[pixelIndex + 2]) / 255.0
                
                redSum += red
                greenSum += green
                blueSum += blue
                sampleCount += 1
            }
        }
        
        guard sampleCount > 0 else {
            throw ProcessingError.failedToProcessImage
        }
        
        let count = Double(sampleCount)
        let redMean = redSum / count
        let greenMean = greenSum / count
        let blueMean = blueSum / count
        
        let colorVariance = sqrt(pow(redMean - greenMean, 2) + pow(greenMean - blueMean, 2) + pow(blueMean - redMean, 2))
        let orangeMaskStrength = (redMean + greenMean) / 2.0 - blueMean
        
        print("📊 Core analysis complete: \(sampleCount) samples from core image area")
        
        return ImageStats(
            redMean: redMean,
            greenMean: greenMean,
            blueMean: blueMean,
            colorVariance: colorVariance,
            orangeMaskStrength: orangeMaskStrength
        )
    }
    
    private func detectNegativeType(from stats: ImageStats) -> NegativeType {
        if stats.orangeMaskStrength > 0.15 || stats.colorVariance > 0.10 {
            return .colorNegative
        } else {
            return .blackAndWhite
        }
    }
    
    private func removeOrangeMask(_ image: CIImage, stats: ImageStats) throws -> CIImage {
        guard let colorMatrix = CIFilter(name: "CIColorMatrix") else {
            throw ProcessingError.failedToProcessImage
        }
        
        colorMatrix.setValue(image, forKey: kCIInputImageKey)
        
        let strength = stats.orangeMaskStrength
        colorMatrix.setValue(CIVector(x: 1.0 - strength * 0.3, y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrix.setValue(CIVector(x: 0, y: 1.0 - strength * 0.2, z: 0, w: 0), forKey: "inputGVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: 1.0 + strength * 0.5, w: 0), forKey: "inputBVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        
        guard let output = colorMatrix.outputImage else {
            throw ProcessingError.failedToProcessImage
        }
        
        return output
    }
    
    // MARK: - Save Image
    private func saveImage(_ image: CIImage, to url: URL) throws {
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw ProcessingError.failedToCreateCGImage
        }
        
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ProcessingError.failedToCreateDestination
        }
        
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingError.failedToSaveImage
        }
    }
    
    private func generateOutputURL(from sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        
        var counter = 1
        var filename = "\(baseName)_p.jpg"
        var outputURL = directory.appendingPathComponent(filename)
        
        while FileManager.default.fileExists(atPath: outputURL.path) {
            filename = "\(baseName)_p\(counter).jpg"
            outputURL = directory.appendingPathComponent(filename)
            counter += 1
        }
        
        return outputURL
    }
}
