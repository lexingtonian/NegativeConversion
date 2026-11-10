import Foundation
import Dispatch

public enum FilmType: String, CaseIterable, Sendable {
    /// Decide from the image whether it is colour or black-and-white film.
    case auto
    case color
    case blackAndWhite
}

/// Per-image choices made by the user. All sliders are neutral at 0 and run
/// from -2 to 2.
public enum ToneMode: String, CaseIterable, Sendable {
    /// Place tones by how far above clear film they sit, i.e. by the exposure
    /// the photographer gave. Needs clear film somewhere in the frame; without
    /// it the frame is converted as `fitToPicture`.
    case filmExposure
    /// Fit the picture's own range of densities into black-to-white.
    case fitToPicture
}

public struct ConversionSettings: Equatable, Sendable {
    public var filmType: FilmType = .auto
    public var toneMode: ToneMode = .fitToPicture
    public var brightness: Float = 0
    public var contrast: Float = 0
    public var saturation: Float = 0
    /// Positive is warmer (more yellow/red), negative cooler.
    public var warmth: Float = 0
    /// Positive is more magenta, negative more green.
    public var tint: Float = 0

    public init() {}

    public var isNeutral: Bool {
        brightness == 0 && contrast == 0 && saturation == 0 && warmth == 0 && tint == 0
    }
}

/// What a frame needs to know about its own film in order to be converted by
/// exposure rather than by its contents: where clear film lies on the frame's
/// density scale, and how the contrast of the red and blue colour layers
/// relates to green.
///
/// With this, tones are placed by how far above clear film they sit, which is
/// decided by the exposure the photographer gave. A correctly exposed subject
/// then comes out right whatever else is in the frame; a much brighter
/// background simply falls where it falls.
///
/// The reference is taken from the one frame alone. Frames are scanned one by
/// one with whatever exposure the scanning camera chose, so densities of
/// different frames cannot be compared.
public struct FilmReference: Equatable, Sendable {
    public var colorBaseDensity: SIMD3<Float>
    public var monoBaseDensity: Float
    /// Contrast of the three colour layers relative to green: (red, 1, blue).
    public var layerContrast: SIMD3<Float>

    /// Density above clear film (luminance) that is shown as white before
    /// the highlight roll-off, for black-and-white film. With this value a
    /// mid-grey subject exposed at box speed, about 0.7 above clear film, is
    /// shown as mid-grey. Not yet checked against real scans.
    public static let whiteDensityAboveBase: Float = 1.20
    /// The same for colour film (green). The dyes of colour film look thinner
    /// to a camera than to a densitometer: on real scans the middle of a
    /// daylight scene lay about 0.5 above clear film and white clothing in the
    /// sun about 1.0.
    public static let colorWhiteDensityAboveBase: Float = 1.00

    /// Returns nil when the frame shows no clear film to measure from.
    public init?(analysis: NegativeAnalysis) {
        guard analysis.clearFilmFound else { return nil }
        colorBaseDensity = analysis.filmBaseDensity
        monoBaseDensity = analysis.monoFilmBaseDensity

        layerContrast = analysis.layerContrast
    }
}

/// The curve that turns "position in the negative's density range" into a
/// display value.
///
/// Input `n` is 0 at the shadow anchor and 1 at the highlight anchor. Output is
/// an sRGB-encoded value in 0...1.
///
/// The curve is built in four steps:
/// 1. *Film:* density is turned back into the amount of light that reached the
///    film, using the usual shape of a negative's response, toe included:
///    `density above the thin end = filmContrast * log10(1 + exposure)`.
/// 2. *Display:* that light is encoded for the screen with a little less than
///    one-to-one contrast, as a print has.
/// 3. *Mid-tone contrast:* a slight S-curve.
/// 4. *Lift:* if large parts of the picture would still sit very low (a small
///    dark subject under a big bright sky, say), the mid-tones are raised.
enum ToneCurve {
    /// Width of the roll-off zones at the shadow and highlight ends, as
    /// fractions of the range. Beyond the anchors the curve flattens out
    /// smoothly instead of clipping.
    static let shadowRolloff: Float = 0.01
    static let highlightRolloff: Float = 0.06
    /// Wider highlight roll-off used when converting by film exposure: there
    /// the highlight anchor is a fixed density, and brighter things (an
    /// overexposed background) need room above it to fade towards white.
    static let exposureHighlightRolloff: Float = 0.15

    /// Typical contrast (gamma) of negative film: density gained per tenfold
    /// increase in exposure.
    static let filmContrast: Float = 0.6
    /// Scene light to sRGB-encoded value: print contrast 0.86 over display gamma 2.2.
    static let displayExponent: Float = 0.39
    /// Limits for the scene brightness range, in powers of ten.
    static let exposureRangeLimits: ClosedRange<Float> = 1.0...4.0

    /// Mid-tone contrast applied with the contrast slider at 0 (1 = none).
    static let baseContrast: Float = 1.3

    /// Brightness that the darkest 20 %, 35 % and 50 % of the picture should at
    /// least reach. These describe an ordinary, well-balanced photograph.
    static let liftTargets = SIMD3<Float>(0.17, 0.32, 0.47)
    /// Strongest lift allowed (0.5 = none; smaller = stronger).
    static let strongestLift: Float = 0.30

    static func exposureRange(forDensityRange range: Float) -> Float {
        min(max(range / filmContrast, exposureRangeLimits.lowerBound), exposureRangeLimits.upperBound)
    }

    /// Identity through the middle, then an exponential approach to 0 and 1.
    static func softClip(_ n: Float, highlightRolloff hi: Float = highlightRolloff) -> Float {
        let lo = shadowRolloff
        if n < lo { return lo * exp((n - lo) / lo) }
        if n > 1 - hi { return 1 - hi * exp(-(n - (1 - hi)) / hi) }
        return n
    }

    /// Mid-tone transfer: maps 0 to 0, 1 to 1 and `m` to 0.5, with a finite
    /// slope at black (unlike a gamma curve), so deep shadows and grain are
    /// not blown up.
    static func midtoneTransfer(_ m: Float, _ x: Float) -> Float {
        if m == 0.5 { return x }
        return (m - 1) * x / ((2 * m - 1) * x - m)
    }

    /// Steps 1 to 3.
    static func base(_ n: Float, exposureRange: Float, contrast: Float,
                     highlightRolloff: Float = highlightRolloff) -> Float {
        let u = softClip(n, highlightRolloff: highlightRolloff)
        let exposure = (pow(10, exposureRange * u) - 1) / (pow(10, exposureRange) - 1)
        var v = pow(min(max(exposure, 0), 1), displayExponent)
        if contrast != 1 {
            let a = pow(v, contrast)
            let b = pow(1 - v, contrast)
            if a + b > 0 { v = a / (a + b) }
        }
        return v
    }

    /// Chooses the lift (step 4) from where the darkest 20 %, 35 % and 50 % of
    /// the picture fall on the density scale. Returns 0.5 when no lift is needed.
    static func lift(quantiles: SIMD3<Float>, exposureRange: Float) -> Float {
        var m: Float = 0.5
        for i in 0..<3 {
            let x = max(base(quantiles[i], exposureRange: exposureRange, contrast: baseContrast), 1e-4)
            let y = liftTargets[i]
            if x < y {
                // The value of m that sends x to y.
                m = min(m, x * (1 - y) / (x + y - 2 * x * y))
            }
        }
        return max(m, strongestLift)
    }

    /// - Parameters:
    ///   - exposureRange: brightness range of the scene between the two
    ///     anchors, in powers of ten.
    ///   - lift: mid-tone lift, 0.5 = none.
    ///   - brightnessExponent: user brightness; 1 = neutral, below 1 brightens.
    ///   - contrast: 1 = no S-curve; above 1 steepens the mid-tones.
    static func evaluate(_ n: Float, exposureRange: Float, lift: Float,
                         brightnessExponent: Float, contrast: Float,
                         highlightRolloff: Float = highlightRolloff) -> Float {
        var v = base(n, exposureRange: exposureRange, contrast: contrast, highlightRolloff: highlightRolloff)
        v = midtoneTransfer(lift, v)
        if brightnessExponent != 1 { v = pow(v, brightnessExponent) }
        return min(max(v, 0), 1)
    }
}

/// A ready-to-run conversion for one image: analysis plus user settings, baked
/// into lookup tables.
public struct ConversionRecipe: @unchecked Sendable {
    public let isMonochrome: Bool
    /// True when tones are placed by film exposure, false when fitted to the picture.
    public let usesFilmExposure: Bool

    // Colour: one table per channel, indexed by half-float bit pattern, giving
    // the sRGB-encoded positive value directly.
    private let tableR: [Float]
    private let tableG: [Float]
    private let tableB: [Float]
    private let saturation: Float

    // Black-and-white: luminance is formed in linear light first, so the curve
    // is tabulated over density instead.
    private let monoTable: [Float]
    private let monoLow: Float
    private let monoScale: Float
    private static let monoTableSize = 8192
    private static let monoSpan: Float = 3   // table covers n in -1...2

    public init(analysis: NegativeAnalysis, settings: ConversionSettings = ConversionSettings()) {
        let filmReference = settings.toneMode == .filmExposure ? FilmReference(analysis: analysis) : nil
        usesFilmExposure = filmReference != nil
        let mono: Bool
        switch settings.filmType {
        case .auto: mono = analysis.isBlackAndWhite
        case .color: mono = false
        case .blackAndWhite: mono = true
        }
        isMonochrome = mono

        // Brightness works differently in the two tone modes. Fitted to the
        // picture, it bends the mid-tones between two fixed end points. By film
        // exposure, it acts like print exposure: the whole tone scale slides
        // along the density axis (up to about two and a half stops each way),
        // which keeps the separation between tones intact.
        let brightnessExponent: Float = filmReference == nil ? pow(2, -settings.brightness) : 1
        let exposureShift: Float = filmReference == nil ? 0 : settings.brightness * 0.45
        let contrast = ToneCurve.baseContrast * pow(2, settings.contrast * 0.7)
        // Upwards one step doubles the saturation; downwards the slider's
        // whole travel is used to reach grey at -2.
        saturation = settings.saturation >= 0 ? 1 + settings.saturation
                                              : max(0, 1 + settings.saturation / 2)

        if mono {
            tableR = []
            tableG = []
            tableB = []
            let low: Float
            let range: Float
            let lift: Float
            let rolloff: Float
            if let reference = filmReference {
                low = reference.monoBaseDensity - exposureShift
                range = FilmReference.whiteDensityAboveBase
                lift = 0.5
                rolloff = ToneCurve.exposureHighlightRolloff
            } else {
                low = analysis.monoShadowDensity
                range = max(analysis.monoHighlightDensity - analysis.monoShadowDensity, 0.02)
                let quantiles = (analysis.monoToneDensities - SIMD3<Float>(repeating: low)) / range
                lift = ToneCurve.lift(quantiles: quantiles,
                                      exposureRange: ToneCurve.exposureRange(forDensityRange: range))
                rolloff = ToneCurve.highlightRolloff
            }
            monoLow = low
            monoScale = 1 / range
            let exposureRange = ToneCurve.exposureRange(forDensityRange: range)
            let size = ConversionRecipe.monoTableSize
            let span = ConversionRecipe.monoSpan
            monoTable = (0...size).map { i in
                let n = Float(i) / Float(size) * span - 1
                return ToneCurve.evaluate(n, exposureRange: exposureRange, lift: lift,
                                          brightnessExponent: brightnessExponent, contrast: contrast,
                                          highlightRolloff: rolloff)
            }
        } else {
            monoTable = []
            monoLow = 0
            monoScale = 1
            let low: SIMD3<Float>
            let high: SIMD3<Float>
            let lift: Float
            let rolloff: Float
            if let reference = filmReference {
                low = reference.colorBaseDensity - reference.layerContrast * exposureShift
                high = low + reference.layerContrast * FilmReference.colorWhiteDensityAboveBase
                lift = 0.5
                rolloff = ToneCurve.exposureHighlightRolloff
            } else {
                low = analysis.colorShadowDensity
                high = analysis.colorHighlightDensity
                let greenRange = max(high.y - low.y, 0.02)
                let quantiles = (analysis.colorToneDensities - SIMD3<Float>(repeating: low.y)) / greenRange
                lift = ToneCurve.lift(quantiles: quantiles,
                                      exposureRange: ToneCurve.exposureRange(forDensityRange: greenRange))
                rolloff = ToneCurve.highlightRolloff
            }
            // One curve for all three channels (taken from green, the channel
            // the eye weighs most), so neutral greys stay neutral.
            let exposureRange = ToneCurve.exposureRange(forDensityRange: max(high.y - low.y, 0.02))
            // Warmth and tint shift the channels against each other.
            let w = settings.warmth * 0.10
            let t = settings.tint * 0.08
            let offsets = SIMD3<Float>(w + t * 0.5, -t, -w + t * 0.5)
            let half = HalfFloat.table
            func build(_ c: Int) -> [Float] {
                let lo = low[c]
                let scale = 1 / max(high[c] - lo, 0.02)
                let offset = offsets[c]
                return (0..<65536).map { bits in
                    let value = half[bits]
                    // Zero, negative or NaN input is treated as "no light at all".
                    let density = (value.isFinite && value > 1e-9) ? -log10(value) : 9
                    let n = (density - lo) * scale + offset
                    return ToneCurve.evaluate(n, exposureRange: exposureRange, lift: lift,
                                              brightnessExponent: brightnessExponent, contrast: contrast,
                                              highlightRolloff: rolloff)
                }
            }
            tableR = build(0)
            tableG = build(1)
            tableB = build(2)
        }
    }

    /// Converts a block of rows to 8 bits per channel.
    /// - Parameters:
    ///   - half: half-float RGBA source, linear light.
    ///   - rowStride: `UInt16` elements per source row.
    ///   - output: 8-bit RGBA destination (sRGB); alpha is written as 255.
    ///   - outputRowBytes: bytes per destination row.
    public func convert(half: UnsafePointer<UInt16>, width: Int, height: Int, rowStride: Int,
                        output: UnsafeMutablePointer<UInt8>, outputRowBytes: Int) {
        convertRows(half: half, width: width, height: height, rowStride: rowStride,
                    output: output, outputRowElements: outputRowBytes, channels: 4)
    }

    /// Same as `convert`, spread over all CPU cores. Use for full-size images.
    public func convertConcurrently(half: UnsafePointer<UInt16>, width: Int, height: Int, rowStride: Int,
                                    output: UnsafeMutablePointer<UInt8>, outputRowBytes: Int) {
        convertBands(half: half, width: width, height: height, rowStride: rowStride,
                     output: output, outputRowElements: outputRowBytes, channels: 4)
    }

    /// Converts to 16 bits per channel, spread over all CPU cores.
    /// - Parameters:
    ///   - output: 16-bit RGB destination (sRGB), three values per pixel, no alpha.
    ///   - outputRowElements: `UInt16` elements per destination row (at least `width * 3`).
    public func convertConcurrently16(half: UnsafePointer<UInt16>, width: Int, height: Int, rowStride: Int,
                                      output: UnsafeMutablePointer<UInt16>, outputRowElements: Int) {
        convertBands(half: half, width: width, height: height, rowStride: rowStride,
                     output: output, outputRowElements: outputRowElements, channels: 3)
    }

    /// Convenience for small images held in arrays (previews, tests).
    public func convert(half: [UInt16], width: Int, height: Int) -> [UInt8] {
        precondition(half.count >= width * height * 4)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        half.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                convert(half: src.baseAddress!, width: width, height: height, rowStride: width * 4,
                        output: dst.baseAddress!, outputRowBytes: width * 4)
            }
        }
        return out
    }

    /// 16-bit RGB version of the array convenience (three values per pixel).
    public func convert16(half: [UInt16], width: Int, height: Int) -> [UInt16] {
        precondition(half.count >= width * height * 4)
        var out = [UInt16](repeating: 0, count: width * height * 3)
        half.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                convertConcurrently16(half: src.baseAddress!, width: width, height: height, rowStride: width * 4,
                                      output: dst.baseAddress!, outputRowElements: width * 3)
            }
        }
        return out
    }

    // MARK: - Inner loops

    private func convertBands<T: OutputComponent>(half: UnsafePointer<UInt16>, width: Int, height: Int,
                                                  rowStride: Int, output: UnsafeMutablePointer<T>,
                                                  outputRowElements: Int, channels: Int) {
        let rowsPerBand = 64
        let bands = (height + rowsPerBand - 1) / rowsPerBand
        // Raw addresses are passed into the closure; each band touches only its own rows.
        let source = UInt(bitPattern: half)
        let destination = UInt(bitPattern: output)
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let y0 = band * rowsPerBand
            let rows = min(rowsPerBand, height - y0)
            let src = UnsafePointer<UInt16>(bitPattern: source)! + y0 * rowStride
            let dst = UnsafeMutablePointer<T>(bitPattern: destination)! + y0 * outputRowElements
            self.convertRows(half: src, width: width, height: rows, rowStride: rowStride,
                             output: dst, outputRowElements: outputRowElements, channels: channels)
        }
    }

    /// - Parameter channels: 4 writes R, G, B and an opaque alpha; 3 writes R, G, B only.
    private func convertRows<T: OutputComponent>(half: UnsafePointer<UInt16>, width: Int, height: Int,
                                                 rowStride: Int, output: UnsafeMutablePointer<T>,
                                                 outputRowElements: Int, channels: Int) {
        if isMonochrome {
            convertMono(half: half, width: width, height: height, rowStride: rowStride,
                        output: output, outputRowElements: outputRowElements, channels: channels)
        } else {
            convertColor(half: half, width: width, height: height, rowStride: rowStride,
                         output: output, outputRowElements: outputRowElements, channels: channels)
        }
    }

    private func convertColor<T: OutputComponent>(half: UnsafePointer<UInt16>, width: Int, height: Int,
                                                  rowStride: Int, output: UnsafeMutablePointer<T>,
                                                  outputRowElements: Int, channels: Int) {
        let s = saturation
        tableR.withUnsafeBufferPointer { tr in
            tableG.withUnsafeBufferPointer { tg in
                tableB.withUnsafeBufferPointer { tb in
                    for y in 0..<height {
                        var src = half + y * rowStride
                        var dst = output + y * outputRowElements
                        for _ in 0..<width {
                            var r = tr[Int(src[0])]
                            var g = tg[Int(src[1])]
                            var b = tb[Int(src[2])]
                            if s != 1 {
                                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                                r = luma + (r - luma) * s
                                g = luma + (g - luma) * s
                                b = luma + (b - luma) * s
                            }
                            dst[0] = T.encoded(r)
                            dst[1] = T.encoded(g)
                            dst[2] = T.encoded(b)
                            if channels == 4 { dst[3] = T.opaque }
                            src += 4
                            dst += channels
                        }
                    }
                }
            }
        }
    }

    private func convertMono<T: OutputComponent>(half: UnsafePointer<UInt16>, width: Int, height: Int,
                                                 rowStride: Int, output: UnsafeMutablePointer<T>,
                                                 outputRowElements: Int, channels: Int) {
        let size = Float(ConversionRecipe.monoTableSize)
        let span = ConversionRecipe.monoSpan
        let lastIndex = ConversionRecipe.monoTableSize - 1
        HalfFloat.table.withUnsafeBufferPointer { linear in
            monoTable.withUnsafeBufferPointer { curve in
                for y in 0..<height {
                    var src = half + y * rowStride
                    var dst = output + y * outputRowElements
                    for _ in 0..<width {
                        let luminance = 0.2627 * linear[Int(src[0])] + 0.6780 * linear[Int(src[1])]
                            + 0.0593 * linear[Int(src[2])]
                        let density = (luminance.isFinite && luminance > 1e-9) ? -log10(luminance) : 9
                        let n = (density - monoLow) * monoScale
                        // Linear interpolation in the curve table (n clamped to -1...2,
                        // far beyond where the curve has flattened out).
                        let position = min(max((n + 1) / span, 0), 1) * size
                        let index = min(Int(position), lastIndex)
                        let fraction = position - Float(index)
                        let v = curve[index] + (curve[index + 1] - curve[index]) * fraction
                        let value = T.encoded(v)
                        dst[0] = value
                        dst[1] = value
                        dst[2] = value
                        if channels == 4 { dst[3] = T.opaque }
                        src += 4
                        dst += channels
                    }
                }
            }
        }
    }
}

/// An output sample: 8 or 16 bits per channel.
protocol OutputComponent {
    /// Encodes a value in 0...1, rounded and clamped.
    static func encoded(_ v: Float) -> Self
    static var opaque: Self { get }
}

extension UInt8: OutputComponent {
    @inline(__always) static func encoded(_ v: Float) -> UInt8 {
        let scaled = v * 255 + 0.5
        if scaled <= 0 { return 0 }
        if scaled >= 255 { return 255 }
        return UInt8(scaled)
    }
    static var opaque: UInt8 { 255 }
}

extension UInt16: OutputComponent {
    @inline(__always) static func encoded(_ v: Float) -> UInt16 {
        let scaled = v * 65535 + 0.5
        if scaled <= 0 { return 0 }
        if scaled >= 65535 { return 65535 }
        return UInt16(scaled)
    }
    static var opaque: UInt16 { 65535 }
}
