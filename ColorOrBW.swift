//
//  ColorOrBW.swift
//  Negative Conversion
//
//  Created by Ari Jaaksi on 25.9.2025.
//
// Copyright (C) 2025 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.


import CoreImage
import Foundation

// MARK: - Image Type Detection
enum ImageType {
    case blackAndWhite
    case color
}

enum ImageAnalysisError: LocalizedError {
    case failedToAnalyzeImage
    case failedToCreateCGImage
    
    var errorDescription: String? {
        switch self {
        case .failedToAnalyzeImage: return "Failed to analyze image type"
        case .failedToCreateCGImage: return "Failed to create CGImage for analysis"
        }
    }
}

class ImageTypeAnalyzer {
    private let context = CIContext()
    
    func analyzeImageType(_ image: CIImage) throws -> ImageType {
        print("🔍 Analyzing image type...")
        
        // Scale down for faster analysis
        let scale = min(256.0 / image.extent.width, 256.0 / image.extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = image.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent),
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw ImageAnalysisError.failedToCreateCGImage
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Sample pixels across the image to check color variation
        var colorPixelCount = 0
        var sampledPixels = 0
        
        // Sample every 10th pixel for efficiency
        for y in stride(from: 0, to: height, by: 10) {
            for x in stride(from: 0, to: width, by: 10) {
                let pixelIndex = (y * width + x) * 4
                guard pixelIndex + 2 < cgImage.bytesPerRow * height else { continue }
                
                let red = data[pixelIndex]
                let green = data[pixelIndex + 1]
                let blue = data[pixelIndex + 2]
                
                // Check if this pixel has significant color information
                // A pixel is considered "color" if there's significant difference between R, G, B channels
                let maxChannel = max(red, green, blue)
                let minChannel = min(red, green, blue)
                let colorDifference = Int(maxChannel) - Int(minChannel)
                
                // Threshold for detecting color (adjust as needed)
                let colorThreshold = 15 // out of 255
                
                if colorDifference > colorThreshold {
                    colorPixelCount += 1
                }
                
                sampledPixels += 1
            }
        }
        
        // Calculate percentage of pixels that appear to have color
        let colorPercentage = Double(colorPixelCount) / Double(sampledPixels)
        
        print("📊 Color analysis: \(String(format: "%.1f", colorPercentage * 100))% of pixels show color information")
        
        // Threshold for determining if image is B&W vs Color
        // If less than 5% of pixels show significant color, treat as B&W
        let bwThreshold = 0.05
        
        let detectedType: ImageType = colorPercentage < bwThreshold ? .blackAndWhite : .color
        
        print("📋 Image type detected: \(detectedType == .blackAndWhite ? "BLACK & WHITE" : "COLOR")")
        
        return detectedType
    }
}
