// Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import Foundation

/// A rectangle expressed as fractions (0...1) of the image width and height,
/// with the origin at the top-left corner.
public struct NormalizedRect: Equatable, Sendable {
    public var x0: Float
    public var y0: Float
    public var x1: Float
    public var y1: Float

    public init(x0: Float, y0: Float, x1: Float, y1: Float) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    /// Which sides a drag moves. All four sides together move the whole rectangle.
    public struct Edges: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let top = Edges(rawValue: 2)
        public static let right = Edges(rawValue: 4)
        public static let bottom = Edges(rawValue: 8)
        public static let all: Edges = [.left, .top, .right, .bottom]
    }

    /// The rectangle after dragging `edges` by `dx`, `dy` (fractions of the
    /// image), kept inside the image and no smaller than `minSize` each way.
    public func dragged(_ edges: Edges, dx: Float, dy: Float, minSize: Float = 0.05) -> NormalizedRect {
        var r = self
        if edges == .all {
            let w = x1 - x0, h = y1 - y0
            r.x0 = min(max(x0 + dx, 0), 1 - w)
            r.y0 = min(max(y0 + dy, 0), 1 - h)
            r.x1 = r.x0 + w
            r.y1 = r.y0 + h
            return r
        }
        if edges.contains(.left) { r.x0 = min(max(x0 + dx, 0), x1 - minSize) }
        if edges.contains(.right) { r.x1 = max(min(x1 + dx, 1), x0 + minSize) }
        if edges.contains(.top) { r.y0 = min(max(y0 + dy, 0), y1 - minSize) }
        if edges.contains(.bottom) { r.y1 = max(min(y1 + dy, 1), y0 + minSize) }
        return r
    }
}

/// Everything the converter needs to know about one negative. Produced once per
/// image from a reduced-size copy; the same result drives both the preview and
/// the full-resolution export, so what is previewed is what gets saved.
///
/// "Density" here is `-log10(linear pixel value)`: the darker a spot on the
/// negative, the higher its density, and the brighter it is in the positive.
public struct NegativeAnalysis: Sendable {
    public var width: Int
    public var height: Int

    /// Per-channel (R, G, B) density that maps to black in the positive. This
    /// is the thin end of the negative; for colour film the differences between
    /// the three channels here *are* the orange mask.
    public var colorShadowDensity: SIMD3<Float>
    /// Per-channel density that maps to white in the positive.
    public var colorHighlightDensity: SIMD3<Float>

    /// Same two anchors for the single luminance channel used for black-and-white film.
    public var monoShadowDensity: Float
    public var monoHighlightDensity: Float

    /// Densities below which the darkest 20 %, 35 % and 50 % of the picture lie
    /// (green channel for colour, luminance for black-and-white). They tell the
    /// tone curve how the picture is distributed between the two anchors.
    public var colorToneDensities: SIMD3<Float>
    public var monoToneDensities: SIMD3<Float>

    /// Density of the clearest film found anywhere on the film in this frame,
    /// border included.
    public var filmBaseDensity: SIMD3<Float>
    public var monoFilmBaseDensity: Float
    /// True when the clearest part of the film is an even, featureless area of
    /// some size: an unexposed border, or a part of the scene that received no
    /// light. Only then can `filmBaseDensity` be taken as the film's base.
    public var clearFilmFound: Bool
    /// Density of the densest picture content, as measured (no sanity limits applied).
    public var colorDenseDensity: SIMD3<Float>
    /// Contrast of the three colour layers relative to green: (red, 1, blue).
    /// Density above the thin end rises this much faster or slower in red and
    /// blue than in green, taken over the whole picture.
    public var layerContrast: SIMD3<Float>
    public var monoDenseDensity: Float

    /// How much the colour channels move independently of each other across the
    /// picture, in density units. Near zero for black-and-white film.
    public var chromaSpread: Float
    /// The same between the most differently coloured parts of the picture
    /// (0.2 % at each end). A small coloured object shows up here only.
    public var chromaExtremes: Float
    public var isBlackAndWhite: Bool

    /// The part of the frame that was judged to be picture and used for measuring.
    public var pictureArea: NormalizedRect
    /// True when a dark surround (film holder / mask) was found and ignored.
    public var foundHolderBorder: Bool
    /// True when bare backlight (sprocket holes, gaps beside the film) was found and ignored.
    public var foundBacklightBorder: Bool
    /// True when border detection left too little to measure and the centre of the frame was used instead.
    public var usedFallbackRegion: Bool
}

public enum NegativeAnalyzer {

    // MARK: Tunable constants

    /// Fraction of picture pixels allowed to fall outside the measured range at
    /// each end. They are not clipped: the tone curve rolls off smoothly beyond
    /// the anchors (see `ToneCurve`). These exist so dust, scratches and tiny
    /// specular highlights do not dictate the tonal range of the whole picture.
    static let shadowPercentile = 0.004
    static let highlightPercentile = 0.998
    /// When fitting tones to the picture, white is taken from the bright parts
    /// of the picture that are larger than this (radius, as a fraction of the
    /// image's long side; things up to about twice this wide count as small).
    /// Smaller bright things, such as spotlights, table lamps, windows and sun
    /// glints, may then burn out instead of dimming everything else.
    static let smallHighlightRadius: Float = 0.025
    /// How far (density) small highlights may still raise white above the
    /// large bright areas: about half a stop.
    static let smallHighlightAllowance: Float = 0.15
    /// Ignoring small highlights lowers white by at most this much (density,
    /// about two stops: spot-lit stages need that much). In a dark scene whose only bright thing is mid-sized
    /// (a white boat on a dark lake), the "large bright areas" are the dark
    /// scene itself; without this limit it would be blown up to near white.
    static let maximumWhiteReduction: Float = 0.60
    /// Ignoring small highlights never leaves the picture with less range
    /// than this between black and white (density, about two and a half
    /// stops). In a night scene the lights are what gives the picture its
    /// range; without them the dark sky would be stretched into grey.
    static let minimumRangeWithoutSmallHighlights: Float = 0.75
    /// The clearest half percent of the film is taken as "clear film".
    static let clearFilmPercentile = 0.005
    /// Density width of the "heap" that clear film forms at the clear end of
    /// the histogram (it allows for uneven scan lighting).
    static let clearFilmEvenness: Float = 0.08

    /// A scene whose negative spans less than this density range (in green /
    /// luminance) is treated as genuinely low in contrast and is not stretched
    /// to full black-to-white. 0.55 is roughly a three-stop scene.
    static let minimumDensityRange: Float = 0.55

    /// Limits for the contrast of the red and blue layers relative to green.
    static let layerContrastLimits: ClosedRange<Float> = 0.6...1.6

    /// Upper limit of chroma spread for film to be taken as black-and-white.
    static let blackAndWhiteChromaSpread: Float = 0.09
    /// Upper limit, for black-and-white film, of the chroma spread between
    /// the most differently coloured parts of the picture (0.2 % at each end).
    /// Real black-and-white scans stayed below 0.13, colour ones above 0.25.
    static let blackAndWhiteChromaExtremes: Float = 0.18
    /// Colour is only judged where no channel is more than this far above the
    /// thin end; denser spots are too close to black on the scan.
    static let reliableDensityRange: Float = 2.5
    /// Blue density minus red density at the thin end, from which film is
    /// taken to have an orange mask.
    static let orangeMaskDensity: Float = 0.5

    // MARK: Entry point

    /// Analyses a negative.
    /// - Parameters:
    ///   - half: 16-bit half-float RGBA pixels, linear light, top row first.
    ///   - rowStride: number of `UInt16` elements from one row to the next (at least `width * 4`).
    ///   - pictureArea: the area to measure, chosen by hand. When nil the
    ///     picture area is found automatically. Holder and backlight are
    ///     left out of the measurement either way.
    public static func analyze(half: UnsafePointer<UInt16>, width: Int, height: Int, rowStride: Int,
                               pictureArea: NormalizedRect? = nil) -> NegativeAnalysis {
        precondition(width > 0 && height > 0 && rowStride >= width * 4)
        let n = width * height

        // ---- Linear RGB planes -------------------------------------------------
        var red = [Float](repeating: 0, count: n)
        var green = [Float](repeating: 0, count: n)
        var blue = [Float](repeating: 0, count: n)
        HalfFloat.table.withUnsafeBufferPointer { table in
            for y in 0..<height {
                let row = half + y * rowStride
                let base = y * width
                for x in 0..<width {
                    let p = row + x * 4
                    red[base + x] = table[Int(p[0])]
                    green[base + x] = table[Int(p[1])]
                    blue[base + x] = table[Int(p[2])]
                }
            }
        }

        // ---- Densities ---------------------------------------------------------
        // Values are floored four decades below each channel's bright level so
        // that noise around zero cannot produce absurd densities.
        let floorR = channelFloor(red)
        let floorG = channelFloor(green)
        let floorB = channelFloor(blue)
        let floorL = 0.2627 * floorR + 0.6780 * floorG + 0.0593 * floorB

        var dR = [Float](repeating: 0, count: n)
        var dG = [Float](repeating: 0, count: n)
        var dB = [Float](repeating: 0, count: n)
        var logL = [Float](repeating: 0, count: n)   // log10 of luminance: high = bright on the negative
        for i in 0..<n {
            let r = sanitized(red[i], floor: floorR)
            let g = sanitized(green[i], floor: floorG)
            let b = sanitized(blue[i], floor: floorB)
            dR[i] = -log10(r)
            dG[i] = -log10(g)
            dB[i] = -log10(b)
            logL[i] = log10(max(0.2627 * r + 0.6780 * g + 0.0593 * b, floorL))
        }

        var histL = Histogram(lowerBound: -9, upperBound: 3, binWidth: 0.005)
        for v in logL { histL.add(v) }
        let brightest = histL.percentile(0.999)

        var excluded = [UInt8](repeating: 0, count: n)

        // ---- Bare backlight (brighter than any film) ---------------------------
        let foundBacklight = markBacklight(logL: logL, dR: dR, dB: dB, hist: histL,
                                           brightest: brightest, width: width, height: height,
                                           excluded: &excluded)

        // ---- Film holder / mask (darker than any film, attached to the edge) ---
        var histFilm = Histogram(lowerBound: -9, upperBound: 3, binWidth: 0.005)
        for i in 0..<n where excluded[i] == 0 { histFilm.add(logL[i]) }
        let filmBright = histFilm.total > 0 ? histFilm.percentile(0.99) : brightest
        let foundHolder = markHolder(logL: logL, hist: histL, filmBright: filmBright,
                                     width: width, height: height, excluded: &excluded)

        // Grow the excluded areas a little to swallow blurred edges and glow.
        if foundBacklight || foundHolder {
            let radius = max(2, Int((0.006 * Float(max(width, height))).rounded()))
            dilate(&excluded, width: width, height: height, radius: radius)
        }

        // ---- Picture rectangle -------------------------------------------------
        let located = pictureRect(logL: logL, excluded: excluded, width: width, height: height)
        var rect = located.rect
        if let area = pictureArea {
            func pixel(_ v: Float, _ size: Int) -> Int { min(max(Int((v * Float(size)).rounded()), 0), size) }
            let x0 = min(pixel(area.x0, width), width - 1)
            let y0 = min(pixel(area.y0, height), height - 1)
            rect = IntRect(x0: x0, y0: y0,
                           x1: max(pixel(area.x1, width), x0 + 1),
                           y1: max(pixel(area.y1, height), y0 + 1))
        }

        // ---- Measuring set -----------------------------------------------------
        var usedFallback = false
        var count = 0
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 where excluded[y * width + x] == 0 { count += 1 }
        }
        if pictureArea != nil {
            // The area was chosen by hand: measure it even if it is small. Only
            // if holder or backlight cover nearly all of it is that ignored.
            if count < max(16, (rect.x1 - rect.x0) * (rect.y1 - rect.y0) / 20) {
                for y in rect.y0..<rect.y1 {
                    for x in rect.x0..<rect.x1 { excluded[y * width + x] = 0 }
                }
            }
        } else if count < n / 20 {
            // Border detection ate nearly everything: distrust it and use the centre.
            usedFallback = true
            for i in 0..<n { excluded[i] = 0 }
            rect = IntRect(x0: width / 10, y0: height / 10,
                           x1: max(width / 10 + 1, width - width / 10),
                           y1: max(height / 10 + 1, height - height / 10))
        }

        // Clearest film anywhere on the film (not just inside the picture).
        var filmR = Histogram(lowerBound: -3, upperBound: 9, binWidth: 0.002)
        var filmG = filmR
        var filmB = filmR
        var filmMono = filmR
        for y in 0..<height {
            let insideY = y >= rect.y0 && y < rect.y1
            for x in 0..<width {
                let i = y * width + x
                if excluded[i] != 0 { continue }
                if usedFallback && !(insideY && x >= rect.x0 && x < rect.x1) { continue }
                filmR.add(dR[i])
                filmG.add(dG[i])
                filmB.add(dB[i])
                filmMono.add(-logL[i])
            }
        }
        let filmBase = SIMD3<Float>(filmR.percentile(clearFilmPercentile),
                                    filmG.percentile(clearFilmPercentile),
                                    filmB.percentile(clearFilmPercentile))
        let monoFilmBase = filmMono.percentile(clearFilmPercentile)
        // Is the clearest density really clear film? Two signs, either is enough:
        // - a strip of clear film runs along a side of the frame (the unexposed
        //   border), or
        // - clear film piles up at one density: there is a distinct heap of
        //   pixels right at the clear end, with far fewer just beyond it. An
        //   ordinary scene, however dark its shadows, thins out gradually
        //   towards its clearest point instead.
        let step = clearFilmEvenness
        let atClearEnd = filmMono.count(below: monoFilmBase + step)
        let justBeyond = filmMono.count(from: monoFilmBase + step, to: monoFilmBase + 2 * step)
        let heapFound = atClearEnd * 100 >= filmMono.total && atClearEnd * 2 >= justBeyond * 5
        let clearFilmFound = !usedFallback && (located.clearBorderFound || heapFound)

        // The picture itself. Clear film that lies inside the measured area (a
        // sliver of border, the gap to the next frame) is not picture: left
        // in, it would set the black point, and the real shadows, which lie a
        // little above clear film, would come out grey. It is skipped unless
        // that would leave less than half of the area.
        var measured = 0
        var clear = 0
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let i = y * width + x
                if excluded[i] != 0 { continue }
                measured += 1
                if -logL[i] < monoFilmBase + step { clear += 1 }
            }
        }
        let skipClearFilm = clearFilmFound && clear * 2 < measured
        var histR = Histogram(lowerBound: -3, upperBound: 9, binWidth: 0.002)
        var histG = histR
        var histB = histR
        var histMono = histR
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let i = y * width + x
                if excluded[i] != 0 { continue }
                if skipClearFilm && -logL[i] < monoFilmBase + step { continue }
                histR.add(dR[i])
                histG.add(dG[i])
                histB.add(dB[i])
                histMono.add(-logL[i])
            }
        }

        var low = SIMD3<Float>(histR.percentile(shadowPercentile),
                               histG.percentile(shadowPercentile),
                               histB.percentile(shadowPercentile))
        var high = SIMD3<Float>(histR.percentile(highlightPercentile),
                                histG.percentile(highlightPercentile),
                                histB.percentile(highlightPercentile))
        let colorDense = high
        let colorThinEnd = low

        // Colour differences between channels, measured on small block averages
        // so that sensor noise and film grain do not masquerade as colour.
        let tooDense = colorThinEnd + SIMD3<Float>(repeating: reliableDensityRange)
        var histRG = Histogram(lowerBound: -4, upperBound: 4, binWidth: 0.002)
        var histBG = histRG
        let block = 8
        var by = rect.y0
        while by + block <= rect.y1 {
            var bx = rect.x0
            while bx + block <= rect.x1 {
                var sumRG: Float = 0
                var sumBG: Float = 0
                var clean = true
                scan: for y in by..<(by + block) {
                    for x in bx..<(bx + block) {
                        let i = y * width + x
                        if excluded[i] != 0 { clean = false; break scan }
                        // Nearly black on the scan: one channel or another is
                        // lost in sensor noise there, which looks like colour.
                        if dR[i] > tooDense.x || dG[i] > tooDense.y || dB[i] > tooDense.z {
                            clean = false
                            break scan
                        }
                        sumRG += dR[i] - dG[i]
                        sumBG += dB[i] - dG[i]
                    }
                }
                if clean {
                    histRG.add(sumRG / Float(block * block))
                    histBG.add(sumBG / Float(block * block))
                }
                bx += block
            }
            by += block
        }

        let colorTone = SIMD3<Float>(histG.percentile(0.20), histG.percentile(0.35), histG.percentile(0.50))
        let monoTone = SIMD3<Float>(histMono.percentile(0.20), histMono.percentile(0.35), histMono.percentile(0.50))
        var monoLow = histMono.percentile(shadowPercentile)
        var monoHigh = histMono.percentile(highlightPercentile)
        let monoDense = monoHigh

        // ---- White for "fit to picture": small highlights do not count --------
        // A few spotlights or lamps easily make up the densest 0.2 % of a
        // frame. Taken as white, they would push the whole picture down. Only
        // pixels up to a little above the large bright areas are considered.
        var whiteGreen = high.y
        if let large = largeAreaHighlight(logL: logL, excluded: excluded, rect: rect,
                                          width: width, height: height) {
            let cap = large + smallHighlightAllowance
            if monoHigh > cap {
                var capG = Histogram(lowerBound: -3, upperBound: 9, binWidth: 0.002)
                var capMono = capG
                for y in rect.y0..<rect.y1 {
                    for x in rect.x0..<rect.x1 {
                        let i = y * width + x
                        if excluded[i] != 0 { continue }
                        let d = -logL[i]
                        if skipClearFilm && d < monoFilmBase + step { continue }
                        if d > cap { continue }
                        capG.add(dG[i])
                        capMono.add(d)
                    }
                }
                if capMono.total > 0 {
                    whiteGreen = min(high.y, max(capG.percentile(highlightPercentile),
                                                 high.y - maximumWhiteReduction,
                                                 low.y + minimumRangeWithoutSmallHighlights))
                    monoHigh = min(monoHigh, max(capMono.percentile(highlightPercentile),
                                                 monoHigh - maximumWhiteReduction,
                                                 monoLow + minimumRangeWithoutSmallHighlights))
                }
            }
        }

        // ---- Sanity limits -----------------------------------------------------
        // The three colour layers of a film never differ wildly in contrast. If
        // the measured ranges do, the scene is dominated by one colour; limit
        // the ratio so that colour is not "corrected" into grey.
        let minRange: Float = 0.02
        let measuredGreenRange = max(whiteGreen - low.y, minRange)
        // Range of the whole picture, small highlights included, for telling
        // colour from black-and-white.
        let fullGreenRange = max(high.y - low.y, minRange)

        // How the red and blue layers relate to green is taken from the whole
        // picture, not from its densest spots alone: the brightest things in
        // a scene are often coloured (sky, lamps), and matching the channels
        // there tints everything else. Each pixel says how far red and blue
        // lie above the thin end for a given green; the best-fitting ratio
        // over all of them is the layer contrast.
        //
        // "Above the thin end" is counted from clear film when the frame shows
        // some: clear film is black by definition, whatever the scene.
        let origin = clearFilmFound ? filmBase : low
        var sumGG = 0.0
        var sumRG = 0.0
        var sumBG = 0.0
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let i = y * width + x
                if excluded[i] != 0 { continue }
                let g = dG[i] - origin.y
                if g < 0.05 || dG[i] > high.y { continue }
                sumGG += Double(g * g)
                sumRG += Double(g * (dR[i] - origin.x))
                sumBG += Double(g * (dB[i] - origin.z))
            }
        }
        var layerContrast = SIMD3<Float>(repeating: 1)
        if sumGG > 0 {
            layerContrast.x = min(max(Float(sumRG / sumGG), layerContrastLimits.lowerBound),
                                  layerContrastLimits.upperBound)
            layerContrast.z = min(max(Float(sumBG / sumGG), layerContrastLimits.lowerBound),
                                  layerContrastLimits.upperBound)
        }
        if clearFilmFound {
            // The black point lies as far above clear film in every layer.
            low = filmBase + layerContrast * (low.y - filmBase.y)
        }
        let range = layerContrast * measuredGreenRange
        high = low + range

        // Low-contrast scenes stay low in contrast instead of being stretched.
        if range.y < minimumDensityRange {
            let extra = minimumDensityRange / range.y - 1
            low -= range * (extra * 0.7)
            high += range * (extra * 0.3)
        }
        let monoRange = max(monoHigh - monoLow, minRange)
        monoHigh = monoLow + monoRange
        if monoRange < minimumDensityRange {
            let extra = minimumDensityRange - monoRange
            monoLow -= extra * 0.7
            monoHigh += extra * 0.3
        }

        // With too few blocks to judge, assume colour: converting black-and-white
        // film as colour still gives a usable picture, the reverse throws colour away.
        var chromaSpread: Float = 1
        // The same between the most differently coloured half percent of the
        // picture: a small coloured object in an otherwise grey scene (a red
        // buoy on a calm sea) leaves the bulk of the picture colourless.
        var chromaExtremes: Float = 1
        if histRG.total >= 24 {
            let spreadRG = histRG.percentile(0.95) - histRG.percentile(0.05)
            let spreadBG = histBG.percentile(0.95) - histBG.percentile(0.05)
            chromaSpread = max(spreadRG, spreadBG)
            let extremesRG = histRG.percentile(0.998) - histRG.percentile(0.002)
            let extremesBG = histBG.percentile(0.998) - histBG.percentile(0.002)
            chromaExtremes = max(extremesRG, extremesBG)
        }

        // Black-and-white film: the three channels move together across the
        // picture, and the film has no orange mask.
        //
        // The mask is checked first, because a picture of one flat tone (fog,
        // an empty sky, a plain wall) makes the channels move together on
        // colour film too. Colour negative film is orange: its thin end holds
        // back far more blue than red. Film like that is never taken for
        // black-and-white.
        //
        // The limit on chroma spread scales with the picture's own density
        // range, so that a hazy, low-contrast scene on unmasked colour film is
        // not mistaken for black-and-white. It leaves room for the uneven pink
        // or purple stain some black-and-white films keep.
        let hasOrangeMask = colorThinEnd.z - colorThinEnd.x >= orangeMaskDensity
        let chromaLimit = min(blackAndWhiteChromaSpread, 0.20 * fullGreenRange)
        let isBlackAndWhite = !hasOrangeMask && chromaSpread < chromaLimit
            && chromaExtremes < blackAndWhiteChromaExtremes

        return NegativeAnalysis(
            width: width,
            height: height,
            colorShadowDensity: low,
            colorHighlightDensity: high,
            monoShadowDensity: monoLow,
            monoHighlightDensity: monoHigh,
            colorToneDensities: colorTone,
            monoToneDensities: monoTone,
            filmBaseDensity: filmBase,
            monoFilmBaseDensity: monoFilmBase,
            clearFilmFound: clearFilmFound,
            colorDenseDensity: colorDense,
            layerContrast: layerContrast,
            monoDenseDensity: monoDense,
            chromaSpread: chromaSpread,
            chromaExtremes: chromaExtremes,
            isBlackAndWhite: isBlackAndWhite,
            pictureArea: NormalizedRect(x0: Float(rect.x0) / Float(width),
                                        y0: Float(rect.y0) / Float(height),
                                        x1: Float(rect.x1) / Float(width),
                                        y1: Float(rect.y1) / Float(height)),
            foundHolderBorder: foundHolder && !usedFallback,
            foundBacklightBorder: foundBacklight && !usedFallback,
            usedFallbackRegion: usedFallback
        )
    }

    /// Convenience for callers that hold the pixels in an array.
    public static func analyze(half: [UInt16], width: Int, height: Int,
                               pictureArea: NormalizedRect? = nil) -> NegativeAnalysis {
        precondition(half.count >= width * height * 4)
        return half.withUnsafeBufferPointer {
            analyze(half: $0.baseAddress!, width: width, height: height, rowStride: width * 4,
                    pictureArea: pictureArea)
        }
    }

    // MARK: - Helpers

    private static func sanitized(_ v: Float, floor: Float) -> Float {
        (v.isFinite && v > floor) ? v : floor
    }

    /// A value four decades below the channel's bright level.
    private static func channelFloor(_ plane: [Float]) -> Float {
        var maxValue: Float = 0
        // A coarse subsample is plenty for finding the bright level.
        let step = max(1, plane.count / 50_000)
        var samples: [Float] = []
        samples.reserveCapacity(plane.count / step + 1)
        var i = 0
        while i < plane.count {
            let v = plane[i]
            if v.isFinite && v > 0 { samples.append(v) }
            i += step
        }
        if !samples.isEmpty {
            samples.sort()
            maxValue = samples[min(samples.count - 1, Int(Double(samples.count) * 0.995))]
        }
        return max(maxValue * 1e-4, 1e-7)
    }

    private struct Valley {
        var position: Float
        var count: Int
    }

    /// Finds the emptiest spot of the histogram between `from` and `to`, i.e. the
    /// most natural place to separate two clusters of values.
    private static func findValley(_ hist: Histogram, from: Float, to: Float, halfWindow: Float = 0.05) -> Valley? {
        guard to > from else { return nil }
        var positions: [Float] = []
        var counts: [Int] = []
        var t = from
        while t <= to + 0.0001 {
            positions.append(t)
            counts.append(hist.count(from: t - halfWindow, to: t + halfWindow))
            t += 0.01
        }
        guard let minCount = counts.min(), let minIndex = counts.firstIndex(of: minCount) else { return nil }
        // Take the centre of the whole run of near-empty positions.
        let tolerance = minCount + max(2, hist.total / 5000)
        var a = minIndex
        var b = minIndex
        while a > 0 && counts[a - 1] <= tolerance { a -= 1 }
        while b < counts.count - 1 && counts[b + 1] <= tolerance { b += 1 }
        let mid = (a + b) / 2
        return Valley(position: positions[mid], count: counts[mid])
    }

    /// Bare backlight shows up as a tight cluster that is clearly brighter than
    /// the clearest film. The test is deliberately strict, because the deepest
    /// shadows of a contrasty scene also form a bright cluster on the negative
    /// and must not be mistaken for backlight.
    private static func markBacklight(logL: [Float], dR: [Float], dB: [Float], hist: Histogram,
                                      brightest: Float, width: Int, height: Int,
                                      excluded: inout [UInt8]) -> Bool {
        let n = logL.count
        guard let valley = findValley(hist, from: brightest - 0.45, to: brightest - 0.05) else { return false }
        let threshold = valley.position
        let clusterCount = hist.count(atLeast: threshold)
        guard clusterCount >= n / 500, clusterCount <= n * 85 / 100 else { return false }

        // The valley must be nearly empty compared with the cluster's own peak.
        var peak = 0
        var t = threshold + 0.05
        while t <= brightest + 0.1 {
            peak = max(peak, hist.count(from: t - 0.05, to: t + 0.05))
            t += 0.01
        }
        guard peak > 0, valley.count * 100 <= peak * 6 else { return false }

        // Statistics of the cluster and of the clearest film just below it.
        var clusterHist = Histogram(lowerBound: threshold - 0.01, upperBound: threshold + 1.5, binWidth: 0.005)
        var restHist = Histogram(lowerBound: threshold - 6, upperBound: threshold + 0.01, binWidth: 0.005)
        for v in logL {
            if v >= threshold { clusterHist.add(v) } else { restHist.add(v) }
        }
        guard restHist.total > 0 else { return false }
        let clusterLow = clusterHist.percentile(0.05)
        let clusterSpread = clusterHist.percentile(0.95) - clusterLow
        let restTop = restHist.percentile(0.995)
        let gap = clusterLow - restTop
        guard gap >= 0.12 else { return false }

        // Colour film: its base is orange, so compared with bare light it holds
        // back far more blue than red.
        var clusterChroma = 0.0
        var filmChroma = 0.0
        var filmCount = 0
        for i in 0..<n {
            let v = logL[i]
            if v >= threshold {
                clusterChroma += Double(dB[i] - dR[i])
            } else if v >= restTop - 0.1 {
                filmChroma += Double(dB[i] - dR[i])
                filmCount += 1
            }
        }
        guard filmCount > 0 else { return false }
        let chromaStep = Float(filmChroma / Double(filmCount) - clusterChroma / Double(clusterCount))

        let accepted: Bool
        if chromaStep >= 0.2 {
            accepted = true
        } else if abs(chromaStep) < 0.08 {
            // Neutral film (black-and-white): clear film and bare light look the
            // same apart from brightness, and so do the black parts of a
            // silhouette. Only the unmistakable pattern of sprocket holes is
            // accepted here.
            accepted = clusterSpread <= 0.12 && gap >= 0.15
                && looksLikeSprocketHoles(logL: logL, threshold: threshold, width: width, height: height)
        } else {
            accepted = false
        }
        guard accepted else { return false }

        for i in 0..<n where logL[i] >= threshold { excluded[i] = 1 }
        return true
    }

    /// True when the pixels at or above `threshold` form several separate
    /// patches of similar size, as sprocket holes do.
    private static func looksLikeSprocketHoles(logL: [Float], threshold: Float, width: Int, height: Int) -> Bool {
        let n = logL.count
        var seen = [UInt8](repeating: 0, count: n)
        var areas: [Int] = []
        var total = 0
        var stack: [Int32] = []
        for start in 0..<n where seen[start] == 0 && logL[start] >= threshold {
            seen[start] = 1
            stack.append(Int32(start))
            var area = 0
            while let last = stack.popLast() {
                let i = Int(last)
                area += 1
                let x = i % width
                let y = i / width
                if x > 0 && seen[i - 1] == 0 && logL[i - 1] >= threshold { seen[i - 1] = 1; stack.append(Int32(i - 1)) }
                if x < width - 1 && seen[i + 1] == 0 && logL[i + 1] >= threshold { seen[i + 1] = 1; stack.append(Int32(i + 1)) }
                if y > 0 && seen[i - width] == 0 && logL[i - width] >= threshold { seen[i - width] = 1; stack.append(Int32(i - width)) }
                if y < height - 1 && seen[i + width] == 0 && logL[i + width] >= threshold { seen[i + width] = 1; stack.append(Int32(i + width)) }
            }
            total += area
            areas.append(area)
        }
        // Ignore specks; holes are between 0.02 % and 1.5 % of the frame each.
        let holes = areas.filter { $0 * 5000 >= n && $0 * 1000 <= n * 15 }.sorted()
        guard holes.count >= 4 else { return false }
        let median = holes[holes.count / 2]
        let similar = holes.filter { $0 * 2 >= median && $0 * 10 <= median * 16 }
        let similarArea = similar.reduce(0, +)
        // Most holes alike (those cut by the frame edge are smaller), and
        // together they account for most of the bright pixels.
        return similar.count * 10 >= holes.count * 6 && similarArea * 10 >= total * 6
    }

    /// The film holder is far darker than the densest film, and it always
    /// reaches the edge of the frame. Dark picture content that does not touch
    /// the edge through other dark pixels is left alone.
    private static func markHolder(logL: [Float], hist: Histogram, filmBright: Float,
                                   width: Int, height: Int, excluded: inout [UInt8]) -> Bool {
        let n = logL.count
        // Something must be at least 1.7 density units darker than clear film...
        guard hist.count(below: filmBright - 1.7) >= n * 3 / 1000 else { return false }
        // ...and the split between holder and film is the emptiest level just
        // above the holder's own level. That level is the most populated one
        // among the dark pixels. A holder passes no light at all, so its
        // pixels are sensor noise around zero, which scatters over several
        // units on a density scale; everything more than three units darker
        // than clear film is therefore counted as one level, plain black.
        let black = filmBright - 3.0
        var holderLevel = black
        var holderCount = hist.count(below: black + 0.05)
        var level = black + 0.06
        while level <= filmBright - 1.7 {
            let count = hist.count(from: level - 0.05, to: level + 0.05)
            if count > holderCount {
                holderCount = count
                holderLevel = level
            }
            level += 0.01
        }
        guard let valley = findValley(hist, from: holderLevel + 0.15,
                                      to: min(holderLevel + 1.2, filmBright - 1.5)) else { return false }
        let threshold = valley.position

        // Flood fill from the frame edge through dark pixels.
        var mark = [UInt8](repeating: 0, count: n)
        var stack: [Int32] = []
        stack.reserveCapacity(4096)
        func seed(_ i: Int) {
            if mark[i] == 0 && logL[i] < threshold {
                mark[i] = 1
                stack.append(Int32(i))
            }
        }
        for x in 0..<width {
            seed(x)
            seed((height - 1) * width + x)
        }
        for y in 0..<height {
            seed(y * width)
            seed(y * width + width - 1)
        }
        var filled = stack.count
        while let last = stack.popLast() {
            let i = Int(last)
            let x = i % width
            let y = i / width
            if x > 0 {
                let j = i - 1
                if mark[j] == 0 && logL[j] < threshold { mark[j] = 1; stack.append(Int32(j)); filled += 1 }
            }
            if x < width - 1 {
                let j = i + 1
                if mark[j] == 0 && logL[j] < threshold { mark[j] = 1; stack.append(Int32(j)); filled += 1 }
            }
            if y > 0 {
                let j = i - width
                if mark[j] == 0 && logL[j] < threshold { mark[j] = 1; stack.append(Int32(j)); filled += 1 }
            }
            if y < height - 1 {
                let j = i + width
                if mark[j] == 0 && logL[j] < threshold { mark[j] = 1; stack.append(Int32(j)); filled += 1 }
            }
        }
        guard filled >= n * 3 / 1000, filled <= n * 9 / 10 else { return false }

        // A holder leaves a rectangular window. A very dense part of the
        // picture that happens to touch the edge (a blazing window behind a
        // backlit subject, say) leaves an irregular shape and is not a holder.
        var rowOpen = [Int](repeating: 0, count: height)
        var colOpen = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width where mark[y * width + x] == 0 {
                rowOpen[y] += 1
                colOpen[x] += 1
            }
        }
        let rowNeed = max(1, (rowOpen.max() ?? 0) / 2)
        let colNeed = max(1, (colOpen.max() ?? 0) / 2)
        guard let y0 = rowOpen.firstIndex(where: { $0 >= rowNeed }),
              let y1 = rowOpen.lastIndex(where: { $0 >= rowNeed }),
              let x0 = colOpen.firstIndex(where: { $0 >= colNeed }),
              let x1 = colOpen.lastIndex(where: { $0 >= colNeed }) else { return false }
        var openInside = 0
        for y in y0...y1 {
            for x in x0...x1 where mark[y * width + x] == 0 { openInside += 1 }
        }
        let windowArea = (y1 - y0 + 1) * (x1 - x0 + 1)
        guard openInside * 100 >= windowArea * 93 else { return false }

        for i in 0..<n where mark[i] != 0 { excluded[i] = 1 }
        return true
    }

    /// Grows the marked area by `radius` pixels in every direction (square kernel).
    /// Densest level reached by the large bright areas of the picture (in
    /// luminance density). The picture is reduced to about 400 cells across,
    /// then opened (minimum, then maximum, over a neighbourhood of
    /// `smallHighlightRadius`): small dense spots vanish, large areas keep
    /// their level. Returns nil when there is too little picture to judge.
    ///
    /// Clear film inside the area is kept in the map, although it does not
    /// count as picture elsewhere: a lamp in a black night sky must still be
    /// seen as small, surrounded by something, not as an island on its own.
    private static func largeAreaHighlight(logL: [Float], excluded: [UInt8], rect: IntRect,
                                           width: Int, height: Int) -> Float? {
        let longSide = max(width, height)
        let cell = max(1, Int((Float(longSide) / 400).rounded()))
        let cw = (rect.x1 - rect.x0 + cell - 1) / cell
        let ch = (rect.y1 - rect.y0 + cell - 1) / cell
        guard cw > 0, ch > 0 else { return nil }
        var grid = [Float](repeating: .nan, count: cw * ch)
        for cy in 0..<ch {
            for cx in 0..<cw {
                var sum: Float = 0
                var count = 0
                for y in (rect.y0 + cy * cell)..<min(rect.y1, rect.y0 + (cy + 1) * cell) {
                    for x in (rect.x0 + cx * cell)..<min(rect.x1, rect.x0 + (cx + 1) * cell) {
                        let i = y * width + x
                        if excluded[i] != 0 { continue }
                        sum += -logL[i]
                        count += 1
                    }
                }
                if count > 0 { grid[cy * cw + cx] = sum / Float(count) }
            }
        }
        let radius = max(1, Int((smallHighlightRadius * Float(longSide) / Float(cell)).rounded()))
        // One pass of a minimum or maximum filter along rows or columns.
        // Cells without picture (NaN) neither take part nor receive a value.
        func pass(_ input: [Float], horizontal: Bool, useMin: Bool) -> [Float] {
            var output = input
            for cy in 0..<ch {
                for cx in 0..<cw {
                    let i = cy * cw + cx
                    if input[i].isNaN { continue }
                    var best = input[i]
                    for k in -radius...radius where k != 0 {
                        let x = horizontal ? cx + k : cx
                        let y = horizontal ? cy : cy + k
                        if x < 0 || x >= cw || y < 0 || y >= ch { continue }
                        let v = input[y * cw + x]
                        if v.isNaN { continue }
                        best = useMin ? min(best, v) : max(best, v)
                    }
                    output[i] = best
                }
            }
            return output
        }
        var opened = pass(grid, horizontal: true, useMin: true)
        opened = pass(opened, horizontal: false, useMin: true)
        opened = pass(opened, horizontal: true, useMin: false)
        opened = pass(opened, horizontal: false, useMin: false)
        var hist = Histogram(lowerBound: -3, upperBound: 9, binWidth: 0.002)
        for v in opened where !v.isNaN { hist.add(v) }
        guard hist.total >= 16 else { return nil }
        return hist.percentile(highlightPercentile)
    }

    private static func dilate(_ mask: inout [UInt8], width: Int, height: Int, radius: Int) {
        var temp = [UInt8](repeating: 0, count: mask.count)
        var prefix = [Int](repeating: 0, count: max(width, height) + 1)
        for y in 0..<height {
            let base = y * width
            for x in 0..<width { prefix[x + 1] = prefix[x] + Int(mask[base + x]) }
            for x in 0..<width {
                let a = max(0, x - radius)
                let b = min(width, x + radius + 1)
                temp[base + x] = prefix[b] - prefix[a] > 0 ? 1 : 0
            }
        }
        for x in 0..<width {
            for y in 0..<height { prefix[y + 1] = prefix[y] + Int(temp[y * width + x]) }
            for y in 0..<height {
                let a = max(0, y - radius)
                let b = min(height, y + radius + 1)
                mask[y * width + x] = prefix[b] - prefix[a] > 0 ? 1 : 0
            }
        }
    }

    private struct IntRect {
        var x0: Int
        var y0: Int
        var x1: Int   // exclusive
        var y1: Int   // exclusive
    }

    /// Bounding box of the film, minus any unexposed film border (rebate), minus
    /// a small safety margin.
    private static func pictureRect(logL: [Float], excluded: [UInt8], width: Int, height: Int)
        -> (rect: IntRect, clearBorderFound: Bool) {
        var rowValid = [Int](repeating: 0, count: height)
        var colValid = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width where excluded[y * width + x] == 0 {
                rowValid[y] += 1
                colValid[x] += 1
            }
        }
        let rowNeed = max(1, (rowValid.max() ?? 0) / 2)
        let colNeed = max(1, (colValid.max() ?? 0) / 2)
        guard let y0 = rowValid.firstIndex(where: { $0 >= rowNeed }),
              let yLast = rowValid.lastIndex(where: { $0 >= rowNeed }),
              let x0 = colValid.firstIndex(where: { $0 >= colNeed }),
              let xLast = colValid.lastIndex(where: { $0 >= colNeed }) else {
            return (IntRect(x0: 0, y0: 0, x1: width, y1: height), false)
        }
        var rect = IntRect(x0: x0, y0: y0, x1: xLast + 1, y1: yLast + 1)

        // Clear-film level inside the box.
        var hist = Histogram(lowerBound: -9, upperBound: 3, binWidth: 0.005)
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 where excluded[y * width + x] == 0 { hist.add(logL[y * width + x]) }
        }
        guard hist.total > 0 else { return (rect, false) }
        let clearLevel = hist.percentile(0.995) - 0.10

        // A line counts as film border when nearly all of it is clear film.
        func isBorderRow(_ y: Int, _ r: IntRect) -> Bool {
            var valid = 0
            var clear = 0
            for x in r.x0..<r.x1 {
                let i = y * width + x
                if excluded[i] != 0 { continue }
                valid += 1
                if logL[i] >= clearLevel { clear += 1 }
            }
            if valid * 5 < (r.x1 - r.x0) { return true }   // mostly holes or holder
            return clear * 10 >= valid * 8
        }
        func isBorderColumn(_ x: Int, _ r: IntRect) -> Bool {
            var valid = 0
            var clear = 0
            for y in r.y0..<r.y1 {
                let i = y * width + x
                if excluded[i] != 0 { continue }
                valid += 1
                if logL[i] >= clearLevel { clear += 1 }
            }
            if valid * 5 < (r.y1 - r.y0) { return true }
            return clear * 10 >= valid * 8
        }

        // A border wider than a fifth of the film is not a border: it is a
        // black part of the scene, and is kept.
        let boxHeight = rect.y1 - rect.y0
        let maxRows = boxHeight / 5
        var top = 0
        while top < maxRows && isBorderRow(rect.y0 + top, rect) { top += 1 }
        if top >= maxRows { top = 0 }
        var bottom = 0
        while bottom < maxRows && isBorderRow(rect.y1 - 1 - bottom, rect) { bottom += 1 }
        if bottom >= maxRows { bottom = 0 }
        rect.y0 += top
        rect.y1 -= bottom

        let boxWidth = rect.x1 - rect.x0
        let maxCols = boxWidth / 5
        var left = 0
        while left < maxCols && isBorderColumn(rect.x0 + left, rect) { left += 1 }
        if left >= maxCols { left = 0 }
        var right = 0
        while right < maxCols && isBorderColumn(rect.x1 - 1 - right, rect) { right += 1 }
        if right >= maxCols { right = 0 }
        rect.x0 += left
        rect.x1 -= right
        // A strip of clear film along at least one side, at least 1 % deep.
        let clearBorderFound = max(top, bottom) >= max(3, boxHeight / 100)
            || max(left, right) >= max(3, boxWidth / 100)

        // Safety margin: 10 % of the shorter side on every side. It keeps thin
        // dense strips along the edges (holder, film edge) and edge falloff out
        // of the measurement; the picture's own blacks and whites are almost
        // never only in its outer tenth. The area can be set by hand if needed.
        let margin = max(2, Int((0.10 * Float(min(rect.x1 - rect.x0, rect.y1 - rect.y0))).rounded()))
        if rect.x1 - rect.x0 > margin * 4 && rect.y1 - rect.y0 > margin * 4 {
            rect.x0 += margin
            rect.x1 -= margin
            rect.y0 += margin
            rect.y1 -= margin
        }
        return (rect, clearBorderFound)
    }
}
