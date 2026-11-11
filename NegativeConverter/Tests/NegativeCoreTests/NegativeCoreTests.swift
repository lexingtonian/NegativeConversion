// Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import XCTest
@testable import NegativeCore

final class NegativeCoreTests: XCTestCase {

    // MARK: Helpers

    /// Float to half-float bits (round to nearest), enough for test data.
    private func half(_ value: Float) -> UInt16 {
        if value <= 0 { return 0 }
        var best: UInt16 = 0
        var lo = 0
        var hi = 0x7BFF   // largest finite positive half
        while lo <= hi {
            let mid = (lo + hi) / 2
            if HalfFloat.table[mid] <= value { best = UInt16(mid); lo = mid + 1 } else { hi = mid - 1 }
        }
        if best < 0x7BFF, abs(HalfFloat.table[Int(best) + 1] - value) < abs(HalfFloat.table[Int(best)] - value) {
            best += 1
        }
        return best
    }

    private struct Scan {
        var width: Int
        var height: Int
        var pixels: [UInt16]
    }

    /// Builds a scan of a negative from a function giving scene brightness
    /// (0...1, per channel) at each position of the picture.
    private func makeScan(width: Int = 240, height: Int = 160, color: Bool,
                          holderBorder: Int = 0, clearBorder: Int = 0,
                          scene: (Float, Float) -> SIMD3<Float>) -> Scan {
        let filmGamma: SIMD3<Float> = color ? [0.50, 0.60, 0.68] : [0.62, 0.62, 0.62]
        let baseDensity: SIMD3<Float> = color ? [0.25, 0.60, 0.95] : [0.28, 0.28, 0.28]
        let light: Float = 0.85
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value = SIMD3<Float>(repeating: 0.001)   // holder
                let inside = x >= holderBorder && x < width - holderBorder
                    && y >= holderBorder && y < height - holderBorder
                if inside {
                    let edge = holderBorder + clearBorder
                    let inPicture = x >= edge && x < width - edge && y >= edge && y < height - edge
                    let u = Float(x - edge) / Float(width - 2 * edge - 1)
                    let v = Float(y - edge) / Float(height - 2 * edge - 1)
                    // Outside the picture the film is unexposed: clear film.
                    let exposure = inPicture ? scene(u, v) : SIMD3<Float>(repeating: 0)
                    for c in 0..<3 {
                        let density = baseDensity[c] + filmGamma[c] * log10(1 + exposure[c] / 0.004)
                        value[c] = light * pow(10, -density)
                    }
                }
                let i = (y * width + x) * 4
                pixels[i] = half(value.x)
                pixels[i + 1] = half(value.y)
                pixels[i + 2] = half(value.z)
                pixels[i + 3] = half(1)
            }
        }
        return Scan(width: width, height: height, pixels: pixels)
    }

    /// Settings for the "fit to picture" tone mode, which most tests exercise.
    private var fitted: ConversionSettings {
        var settings = ConversionSettings()
        settings.toneMode = .fitToPicture
        return settings
    }

    /// Settings for the "by film exposure" tone mode.
    private var byFilmExposure: ConversionSettings {
        var settings = ConversionSettings()
        settings.toneMode = .filmExposure
        return settings
    }

    private func convert(_ scan: Scan, settings: ConversionSettings? = nil)
        -> (analysis: NegativeAnalysis, recipe: ConversionRecipe, output: [UInt8]) {
        let settings = settings ?? fitted
        let analysis = NegativeAnalyzer.analyze(half: scan.pixels, width: scan.width, height: scan.height)
        let recipe = ConversionRecipe(analysis: analysis, settings: settings)
        return (analysis, recipe, recipe.convert(half: scan.pixels, width: scan.width, height: scan.height))
    }

    private func pixel(_ output: [UInt8], _ scan: Scan, _ x: Int, _ y: Int) -> SIMD3<Int> {
        let i = (y * scan.width + x) * 4
        return [Int(output[i]), Int(output[i + 1]), Int(output[i + 2])]
    }

    /// Grey ramp from left (dark) to right (bright), modulated a little vertically.
    private func greyRamp(_ u: Float, _ v: Float) -> SIMD3<Float> {
        SIMD3<Float>(repeating: 0.002 + 0.9 * u * u * (0.8 + 0.2 * v))
    }

    // MARK: Tests

    func testHalfFloatDecoding() {
        XCTAssertEqual(HalfFloat.toFloat(0x0000), 0)
        XCTAssertEqual(HalfFloat.toFloat(0x3C00), 1)
        XCTAssertEqual(HalfFloat.toFloat(0x3800), 0.5)
        XCTAssertEqual(HalfFloat.toFloat(0xC000), -2)
        XCTAssertEqual(HalfFloat.toFloat(0x0001), Float(sign: .plus, exponent: -24, significand: 1))
        XCTAssertEqual(HalfFloat.toFloat(0x7C00), .infinity)
        XCTAssertTrue(HalfFloat.toFloat(0x7E00).isNaN)
    }

    func testToneCurveKeepsRisingAndStaysInRange() {
        var previous: Float = -1
        var n: Float = -0.5
        while n <= 1.5 {
            let v = ToneCurve.evaluate(n, exposureRange: 2.0, lift: 0.4, brightnessExponent: 1,
                                       contrast: ToneCurve.baseContrast)
            XCTAssertGreaterThanOrEqual(v, previous, "curve must never fall, n = \(n)")
            // From just below the shadow anchor to well past the highlight
            // anchor every step must still produce a different value.
            if n > -0.03 && n < 1.3 {
                XCTAssertGreaterThan(v, previous, "curve must keep rising at n = \(n)")
            }
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
            previous = v
            n += 0.01
        }
    }

    func testDarkSubjectUnderBrightSkyIsLifted() {
        // 60 % of the frame is bright sky; the subject is three to five stops darker.
        let scan = makeScan(color: false) { u, v in
            u < 0.6 ? SIMD3<Float>(repeating: 0.7 + 0.2 * v) : SIMD3<Float>(repeating: 0.03 + 0.05 * v)
        }
        let result = convert(scan)
        let subject = pixel(result.output, scan, 200, 80).y
        let sky = pixel(result.output, scan, 60, 80).y
        XCTAssertGreaterThan(subject, 45, "the subject must not be buried in black")
        XCTAssertGreaterThan(sky, 200)
        XCTAssertLessThan(sky, 255)
    }

    func testColorNegativeBecomesNeutralPositive() {
        let scan = makeScan(color: true, scene: greyRamp)
        let result = convert(scan)
        XCTAssertFalse(result.analysis.isBlackAndWhite)
        XCTAssertFalse(result.recipe.isMonochrome)

        // The negative is strongly orange...
        let i = (80 * scan.width + 120) * 4
        XCTAssertGreaterThan(HalfFloat.table[Int(scan.pixels[i])], 2 * HalfFloat.table[Int(scan.pixels[i + 2])])

        // ...and a grey scene must come out grey, dark on the left and bright on the right.
        var lastGreen = -1
        for x in stride(from: 10, to: scan.width - 10, by: 10) {
            let p = pixel(result.output, scan, x, 80)
            XCTAssertLessThanOrEqual(abs(p.x - p.y), 6, "red/green cast at x = \(x): \(p)")
            XCTAssertLessThanOrEqual(abs(p.z - p.y), 6, "blue/green cast at x = \(x): \(p)")
            XCTAssertGreaterThanOrEqual(p.y, lastGreen)
            lastGreen = p.y
        }
        XCTAssertLessThan(pixel(result.output, scan, 6, 80).y, 30)
        XCTAssertGreaterThan(pixel(result.output, scan, scan.width - 6, 80).y, 215)
    }

    func testBlackAndWhiteIsDetected() {
        let scan = makeScan(color: false, scene: greyRamp)
        let result = convert(scan)
        XCTAssertTrue(result.analysis.isBlackAndWhite)
        XCTAssertTrue(result.recipe.isMonochrome)
        let p = pixel(result.output, scan, 120, 80)
        XCTAssertEqual(p.x, p.y)
        XCTAssertEqual(p.y, p.z)
    }

    func testSmallColouredObjectMakesTheFrameColour() {
        // A plain grey scene with one small red object (a buoy on a calm sea),
        // on film without an orange mask. The object covers about 1 % of the frame.
        func scene(withObject: Bool) -> Scan {
            makeScan(color: false) { u, v in
                let grey = 0.2 + 0.2 * u
                if withObject && abs(u - 0.6) < 0.05 && abs(v - 0.5) < 0.05 {
                    return SIMD3<Float>(0.5, 0.08, 0.06)
                }
                return SIMD3<Float>(repeating: grey)
            }
        }
        XCTAssertTrue(convert(scene(withObject: false)).analysis.isBlackAndWhite)
        XCTAssertFalse(convert(scene(withObject: true)).analysis.isBlackAndWhite)
    }

    func testFilmTypeOverride() {
        let scan = makeScan(color: true, scene: greyRamp)
        var settings = fitted
        settings.filmType = .blackAndWhite
        XCTAssertTrue(convert(scan, settings: settings).recipe.isMonochrome)
    }

    func testHolderBorderDoesNotChangeThePicture() {
        let plain = makeScan(width: 240, height: 160, color: true, scene: greyRamp)
        let framed = makeScan(width: 300, height: 220, color: true, holderBorder: 30, scene: greyRamp)
        let a = convert(plain)
        let b = convert(framed)
        XCTAssertFalse(a.analysis.foundHolderBorder)
        XCTAssertTrue(b.analysis.foundHolderBorder)
        // The measured picture area lies inside the film.
        XCTAssertGreaterThanOrEqual(b.analysis.pictureArea.x0, 30.0 / 300.0)
        XCTAssertLessThanOrEqual(b.analysis.pictureArea.x1, 270.0 / 300.0)
        // Same anchors, so the same picture, with or without the surround.
        for c in 0..<3 {
            XCTAssertEqual(a.analysis.colorShadowDensity[c], b.analysis.colorShadowDensity[c], accuracy: 0.03)
            XCTAssertEqual(a.analysis.colorHighlightDensity[c], b.analysis.colorHighlightDensity[c], accuracy: 0.03)
        }
    }

    func testLowContrastSceneIsNotStretchedToFullRange() {
        // A scene spanning barely one stop.
        let scan = makeScan(color: true) { u, _ in SIMD3<Float>(repeating: 0.25 + 0.2 * u) }
        let result = convert(scan)
        let dark = pixel(result.output, scan, 12, 80).y
        let bright = pixel(result.output, scan, scan.width - 12, 80).y
        XCTAssertGreaterThan(dark, 40, "the darkest tone of a flat scene must not be pushed to black")
        XCTAssertLessThan(bright, 240, "the brightest tone of a flat scene must not be pushed to white")
        XCTAssertGreaterThan(bright, dark)
    }

    func testAdjustmentsMoveTheResultInTheExpectedDirection() {
        let scan = makeScan(color: true, scene: greyRamp)
        let neutral = pixel(convert(scan).output, scan, 120, 80)

        var settings = fitted
        settings.brightness = 0.5
        XCTAssertGreaterThan(pixel(convert(scan, settings: settings).output, scan, 120, 80).y, neutral.y)

        settings = fitted
        settings.warmth = 0.5
        let warm = pixel(convert(scan, settings: settings).output, scan, 120, 80)
        XCTAssertGreaterThan(warm.x, neutral.x)
        XCTAssertLessThan(warm.z, neutral.z)
    }

    /// A subject exposed correctly (mid-grey about 0.7 density units above
    /// clear film) in front of a background four to five stops brighter.
    private func backlitSubject(_ u: Float, _ v: Float) -> SIMD3<Float> {
        let inSubject = u > 0.3 && u < 0.7 && v > 0.25
        return SIMD3<Float>(repeating: inSubject ? 0.055 * (0.8 + 0.4 * v) : 1.3 + 0.6 * u)
    }

    func testFilmExposureKeepsACorrectlyExposedSubjectRight() {
        // The holder border leaves a strip of clear film visible around the picture.
        func scan(clearBorder: Int) -> Scan {
            makeScan(width: 300, height: 220, color: false, holderBorder: 20, clearBorder: clearBorder,
                     scene: backlitSubject)
        }
        let withBorder = scan(clearBorder: 8)
        let byExposure = convert(withBorder, settings: byFilmExposure)
        XCTAssertTrue(byExposure.analysis.clearFilmFound)
        XCTAssertTrue(byExposure.recipe.usesFilmExposure)
        let subject = pixel(byExposure.output, withBorder, 150, 150).y
        XCTAssertGreaterThan(subject, 95, "a correctly exposed subject must come out as a mid-tone")
        XCTAssertLessThan(subject, 160)
        XCTAssertGreaterThan(pixel(byExposure.output, withBorder, 40, 60).y, 235, "the background goes near white")

        // Fitted to the picture, the bright background drags the same subject down.
        let fittedResult = convert(withBorder, settings: fitted)
        XCTAssertFalse(fittedResult.recipe.usesFilmExposure)
        XCTAssertLessThan(pixel(fittedResult.output, withBorder, 150, 150).y, subject)

        // Brightness slides the whole scale, like print exposure.
        var darker = byFilmExposure
        darker.brightness = -0.5
        XCTAssertLessThan(pixel(convert(withBorder, settings: darker).output, withBorder, 150, 150).y, subject)
    }

    func testFilmExposureFallsBackWithoutClearFilm() {
        // No border and no unexposed part of the scene: nothing to measure from.
        let scan = makeScan(color: true) { u, v in SIMD3<Float>(repeating: 0.05 + 0.4 * u + 0.4 * v) }
        let result = convert(scan, settings: byFilmExposure)
        XCTAssertFalse(result.analysis.clearFilmFound)
        XCTAssertFalse(result.recipe.usesFilmExposure)
        XCTAssertTrue(result.output == convert(scan, settings: fitted).output,
                      "without clear film the result must equal the fitted conversion")
    }

    func testDensePictureAreaAtTheEdgeIsNotTakenForTheHolder() {
        // An irregular, very bright part of the scene touching the frame edge.
        let scan = makeScan(color: true) { u, v in
            let blazing = v < 0.5 && abs(u - 0.5) < 0.15 + 0.25 * v
            return SIMD3<Float>(repeating: blazing ? 6.0 : 0.02 + 0.3 * u)
        }
        XCTAssertFalse(convert(scan).analysis.foundHolderBorder)
    }

    func testConcurrentConversionMatchesSerial() {
        let scan = makeScan(width: 320, height: 200, color: true, scene: greyRamp)
        let result = convert(scan)
        var parallel = [UInt8](repeating: 0, count: scan.width * scan.height * 4)
        scan.pixels.withUnsafeBufferPointer { source in
            parallel.withUnsafeMutableBufferPointer { destination in
                result.recipe.convertConcurrently(half: source.baseAddress!, width: scan.width, height: scan.height,
                                                  rowStride: scan.width * 4,
                                                  output: destination.baseAddress!, outputRowBytes: scan.width * 4)
            }
        }
        XCTAssertEqual(parallel, result.output)
    }

    // MARK: Measured area chosen by hand

    func testDraggedAreaStaysInsideTheImageAndKeepsAMinimumSize() {
        let r = NormalizedRect(x0: 0.2, y0: 0.2, x1: 0.6, y1: 0.7)
        let moved = r.dragged(.all, dx: 0.9, dy: -0.5)
        XCTAssertEqual(moved.x1, 1, accuracy: 1e-6)
        XCTAssertEqual(moved.x1 - moved.x0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(moved.y0, 0, accuracy: 1e-6)
        XCTAssertEqual(moved.y1 - moved.y0, 0.5, accuracy: 1e-6)
        let squeezed = r.dragged([.left, .top], dx: 0.9, dy: 0.9, minSize: 0.05)
        XCTAssertEqual(squeezed.x0, 0.55, accuracy: 1e-6)
        XCTAssertEqual(squeezed.y0, 0.65, accuracy: 1e-6)
        XCTAssertEqual(squeezed.x1, 0.6, accuracy: 1e-6)
        let widened = r.dragged(.right, dx: 2, dy: 0)
        XCTAssertEqual(widened.x1, 1, accuracy: 1e-6)
        XCTAssertEqual(widened.x0, 0.2, accuracy: 1e-6)
    }

    func testHandChosenAreaIsWhatGetsMeasured() {
        // Dim left half, bright right half.
        let scan = makeScan(color: false) { u, _ in SIMD3<Float>(repeating: u < 0.5 ? 0.02 : 0.8) }
        let automatic = NegativeAnalyzer.analyze(half: scan.pixels, width: scan.width, height: scan.height)
        let area = NormalizedRect(x0: 0.1, y0: 0.2, x1: 0.4, y1: 0.8)
        let chosen = NegativeAnalyzer.analyze(half: scan.pixels, width: scan.width, height: scan.height,
                                              pictureArea: area)
        XCTAssertEqual(chosen.pictureArea.x0, area.x0, accuracy: 0.01)
        XCTAssertEqual(chosen.pictureArea.x1, area.x1, accuracy: 0.01)
        XCTAssertEqual(chosen.pictureArea.y0, area.y0, accuracy: 0.01)
        XCTAssertEqual(chosen.pictureArea.y1, area.y1, accuracy: 0.01)
        XCTAssertFalse(chosen.usedFallbackRegion)
        // Only the dim half was measured, so its densest content is thinner
        // than that of the whole picture.
        XCTAssertLessThan(chosen.monoHighlightDensity, automatic.monoHighlightDensity - 0.2)
    }
}
