//
//  OrangeChallenge.swift
//  Negative Conversion
//
//  Created by Ari Jaaksi on 25.9.2025.
//
// Copyright (C) 2025 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.



import CoreImage
import Foundation
import UniformTypeIdentifiers

// MARK: - Orange Mask Removal Errors
enum OrangeMaskError: LocalizedError {
    case failedToRemoveOrangeMask
    case failedToAnalyzeOrangeMask
    case failedToCreateCGImage
    
    var errorDescription: String? {
        switch self {
        case .failedToRemoveOrangeMask: return "Failed to remove orange mask"
        case .failedToAnalyzeOrangeMask: return "Failed to analyze orange mask"
        case .failedToCreateCGImage: return "Failed to create CGImage for orange analysis"
        }
    }
}

// MARK: - Orange Mask Values
private struct OrangeMaskValues {
    let redCorrection: Double
    let greenCorrection: Double
    let blueCorrection: Double
}

// MARK: - Orange Mask Remover
class OrangeMaskRemover {
    private let context = CIContext()
    
    /// Removes the orange mask from a color negative image
    /// - Parameter image: The color negative image with orange mask
    /// - Returns: Image with orange mask removed, ready for normal inversion
    func removeOrangeMask(from image: CIImage, sourceURL: URL) throws -> CIImage {
        print("🍊 ORANGE: Starting orange mask detection and removal")
        
        // Step 1: Analyze the image to detect orange mask characteristics from brightest spots
        let analysisResult = try analyzeOrangeMask(in: image)
        let orangeValues = analysisResult.orangeValues
        let detectedColor = analysisResult.detectedOrangeColor
        
        print("🍊 ORANGE: Detected mask values - R:\(String(format: "%.3f", orangeValues.redCorrection)), G:\(String(format: "%.3f", orangeValues.greenCorrection)), B:\(String(format: "%.3f", orangeValues.blueCorrection))")
        
        // Step 2: Create test image showing detected orange color and save to output directory
        let outputDirectory = sourceURL.deletingLastPathComponent()
        try createOrangeMaskTestImage(detectedColor: detectedColor, outputDirectory: outputDirectory)
        
        // Step 3: ACTUALLY REMOVE the orange mask from the negative
        let cleanNegative = try applyOrangeMaskRemoval(to: image, with: orangeValues)
        print("✅ ORANGE: Orange mask removed from negative")
        
        // Step 4: Save the orange-removed negative for debugging
        try saveOrangeRemovedNegative(cleanNegative, outputDirectory: outputDirectory)
        
        print("✅ ORANGE: Returning clean negative for positive conversion")
        return cleanNegative
    }
    
    // MARK: - Orange Mask Analysis (IMPROVED - EXCLUDE CENTER AREAS)
    private func analyzeOrangeMask(in image: CIImage) throws -> (orangeValues: OrangeMaskValues, detectedOrangeColor: (r: Double, g: Double, b: Double)) {
        print("🔍 ORANGE: Analyzing brightest spots EXCLUDING CENTER (pure film base only)")
        
        // Scale down for faster analysis
        let scale = min(256.0 / image.extent.width, 256.0 / image.extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = image.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent),
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw OrangeMaskError.failedToCreateCGImage
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Create brightness map to find brightest areas
        var brightnessMap: [[Double]] = Array(repeating: Array(repeating: 0.0, count: width), count: height)
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                guard pixelIndex + 2 < cgImage.bytesPerRow * height else { continue }
                
                let red = Double(data[pixelIndex]) / 255.0
                let green = Double(data[pixelIndex + 1]) / 255.0
                let blue = Double(data[pixelIndex + 2]) / 255.0
                
                // Calculate brightness (luminance)
                let brightness = 0.299 * red + 0.587 * green + 0.114 * blue
                brightnessMap[y][x] = brightness
            }
        }
        
        // Find 95th percentile brightness threshold
        let allBrightness = brightnessMap.flatMap { $0 }
        let sortedBrightness = allBrightness.sorted()
        let brightnessThreshold = sortedBrightness[Int(Double(sortedBrightness.count) * 0.95)]
        
        print("📊 ORANGE: Using 95th percentile brightness threshold: \(String(format: "%.3f", brightnessThreshold))")
        
        // EXCLUDE CENTER AREA (like Python code does)
        let centerX = width / 2
        let centerY = height / 2
        
        // Try different exclusion percentages to find optimal (like Python code)
        let exclusionPercentages = [0, 20, 30, 40] // 0%, 20%, 30%, 40% of width
        var bestExclusionPercent = 0
        
        for exclusionPercent in exclusionPercentages {
            let exclusionWidth = Int(Double(width) * Double(exclusionPercent) / 100.0)
            
            var validPixelCount = 0
            var totalPixelCount = 0
            
            for y in 0..<height {
                for x in 0..<width {
                    // Skip center area
                    if abs(x - centerX) <= exclusionWidth {
                        continue
                    }
                    
                    totalPixelCount += 1
                    if brightnessMap[y][x] >= brightnessThreshold {
                        validPixelCount += 1
                    }
                }
            }
            
            let validRatio = Double(validPixelCount) / Double(totalPixelCount)
            print("📊 ORANGE: Exclusion \(exclusionPercent)% -> \(String(format: "%.1f", validRatio * 100))% bright pixels")
            
            // Stop when we have concentrated bright pixels (> 10% in non-center areas)
            if validRatio > 0.10 {
                bestExclusionPercent = exclusionPercent
                break
            }
        }
        
        let finalExclusionWidth = Int(Double(width) * Double(bestExclusionPercent) / 100.0)
        print("📊 ORANGE: Using \(bestExclusionPercent)% center exclusion (width: \(finalExclusionWidth) pixels)")
        
        // Collect RGB values from bright areas EXCLUDING CENTER
        var brightRValues: [Double] = []
        var brightGValues: [Double] = []
        var brightBValues: [Double] = []
        
        for y in 0..<height {
            for x in 0..<width {
                // Skip center area
                if abs(x - centerX) <= finalExclusionWidth {
                    continue
                }
                
                if brightnessMap[y][x] >= brightnessThreshold {
                    let pixelIndex = (y * width + x) * 4
                    guard pixelIndex + 2 < cgImage.bytesPerRow * height else { continue }
                    
                    let red = Double(data[pixelIndex]) / 255.0
                    let green = Double(data[pixelIndex + 1]) / 255.0
                    let blue = Double(data[pixelIndex + 2]) / 255.0
                    
                    brightRValues.append(red)
                    brightGValues.append(green)
                    brightBValues.append(blue)
                }
            }
        }
        
        guard !brightRValues.isEmpty else {
            throw OrangeMaskError.failedToAnalyzeOrangeMask
        }
        
        print("📊 ORANGE: Analyzing \(brightRValues.count) bright pixels from non-center areas")
        
        // Calculate mean RGB values (like Python code does)
        let meanRed = brightRValues.reduce(0, +) / Double(brightRValues.count)
        let meanGreen = brightGValues.reduce(0, +) / Double(brightGValues.count)
        let meanBlue = brightBValues.reduce(0, +) / Double(brightBValues.count)
        
        print("📊 ORANGE: Detected orange cast RGB: R:\(String(format: "%.3f", meanRed)), G:\(String(format: "%.3f", meanGreen)), B:\(String(format: "%.3f", meanBlue))")
        
        // NORMALIZE TO GREEN CHANNEL (like Python: ncast = cast/cast[1])
        let normalizedRed = meanRed / meanGreen
        let normalizedGreen = 1.0  // Green = 1.0 by definition
        let normalizedBlue = meanBlue / meanGreen
        
        print("📊 ORANGE: Normalized to green RGB: R:\(String(format: "%.3f", normalizedRed)), G:\(String(format: "%.3f", normalizedGreen)), B:\(String(format: "%.3f", normalizedBlue))")
        
        // CALCULATE UNCAST FACTORS (like Python: uncast = ncast[1]/ncast)
        let redCorrection = normalizedGreen / normalizedRed     // Green/Red
        let greenCorrection = normalizedGreen / normalizedGreen // Always 1.0
        let blueCorrection = normalizedGreen / normalizedBlue   // Green/Blue
        
        let orangeValues = OrangeMaskValues(
            redCorrection: redCorrection,
            greenCorrection: greenCorrection,
            blueCorrection: blueCorrection
        )
        
        let detectedColor = (r: meanRed, g: meanGreen, b: meanBlue)
        
        return (orangeValues: orangeValues, detectedOrangeColor: detectedColor)
    }
    
    // MARK: - Orange Mask Test Image Creation (UPDATED)
    private func createOrangeMaskTestImage(detectedColor: (r: Double, g: Double, b: Double), outputDirectory: URL) throws {
        print("🍊 ORANGE: Creating 200x200 test image with ACTUAL detected orange color")
        
        print("🍊 ORANGE: Using detected orange RGB - R:\(String(format: "%.3f", detectedColor.r)), G:\(String(format: "%.3f", detectedColor.g)), B:\(String(format: "%.3f", detectedColor.b))")
        
        // Create solid color image using the ACTUAL detected orange color
        let color = CIColor(red: detectedColor.r, green: detectedColor.g, blue: detectedColor.b)
        let colorFilter = CIFilter(name: "CIConstantColorGenerator")!
        colorFilter.setValue(color, forKey: kCIInputColorKey)
        
        guard let colorImage = colorFilter.outputImage else {
            throw OrangeMaskError.failedToRemoveOrangeMask
        }
        
        // Crop to 200x200 size
        let extent = CGRect(origin: .zero, size: CGSize(width: 200, height: 200))
        let croppedImage = colorImage.cropped(to: extent)
        
        // Save to same directory as output files
        try saveOrangeMaskTestImage(croppedImage, outputDirectory: outputDirectory)
    }
    
    private func saveOrangeMaskTestImage(_ image: CIImage, outputDirectory: URL) throws {
        let outputURL = outputDirectory.appendingPathComponent("OrangeMask.jpg")
        
        print("🔧 ORANGE: Saving orange mask test to output directory")
        
        // Create CGImage
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw OrangeMaskError.failedToCreateCGImage
        }
        
        // Save as JPEG
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw OrangeMaskError.failedToRemoveOrangeMask
        }
        
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw OrangeMaskError.failedToRemoveOrangeMask
        }
        
        print("✅ ORANGE: Test image saved as OrangeMask.jpg in output directory")
        print("🔍 ORANGE: Path: \(outputURL.path)")
        print("🔍 ORANGE: Check this image to see detected orange mask color")
    }
    
    // MARK: - Save Orange-Removed Negative for Debugging
    private func saveOrangeRemovedNegative(_ image: CIImage, outputDirectory: URL) throws {
        let outputURL = outputDirectory.appendingPathComponent("OrangeRemoved.jpg")
        
        print("🔧 ORANGE: Saving orange-removed negative for debugging")
        
        // Create CGImage
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw OrangeMaskError.failedToCreateCGImage
        }
        
        // Save as JPEG
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw OrangeMaskError.failedToRemoveOrangeMask
        }
        
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw OrangeMaskError.failedToRemoveOrangeMask
        }
        
        print("✅ ORANGE: Orange-removed negative saved as OrangeRemoved.jpg")
        print("🔍 ORANGE: This shows the negative AFTER orange removal but BEFORE positive conversion")
        print("🔍 ORANGE: Compare this to original to see orange removal effect")
    }
    
    // MARK: - Orange Mask Removal Application (MULTIPLICATIVE APPROACH)
    private func applyOrangeMaskRemoval(to image: CIImage, with orangeValues: OrangeMaskValues) throws -> CIImage {
        
        let kernelSource = """
        kernel vec4 removeOrangeMaskMultiplicative(sampler image, float redScale, float greenScale, float blueScale) {
            vec4 pixel = sample(image, samplerCoord(image));
            
            // MULTIPLICATIVE CORRECTION: Multiply each channel by its correction factor
            // This is like: rgb_img = rgb_img * uncast (from Python code)
            float correctedR = pixel.r * redScale;
            float correctedG = pixel.g * greenScale;
            float correctedB = pixel.b * blueScale;
            
            // Clamp to valid range
            correctedR = clamp(correctedR, 0.0, 1.0);
            correctedG = clamp(correctedG, 0.0, 1.0);
            correctedB = clamp(correctedB, 0.0, 1.0);
            
            return vec4(correctedR, correctedG, correctedB, pixel.a);
        }
        """
        
        guard let kernel = CIKernel(source: kernelSource) else {
            throw OrangeMaskError.failedToRemoveOrangeMask
        }
        
        print("🔧 ORANGE: Applying multiplicative orange correction")
        print("📊 ORANGE: Correction factors - R:\(String(format: "%.3f", orangeValues.redCorrection)), G:\(String(format: "%.3f", orangeValues.greenCorrection)), B:\(String(format: "%.3f", orangeValues.blueCorrection))")
        
        guard let output = kernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: [
            image,
            orangeValues.redCorrection as NSNumber,
            orangeValues.greenCorrection as NSNumber,
            orangeValues.blueCorrection as NSNumber
        ]) else {
            throw OrangeMaskError.failedToRemoveOrangeMask
        }
        
        return output
    }
}
