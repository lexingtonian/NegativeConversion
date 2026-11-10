// Built only by the Swift package (Package.swift defines HEADLESS), never
// into the App Store app.
#if HEADLESS
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NegativeCore

/// Command-line mode, for testing the conversion on real files without the
/// window:
///
///     NegativeConverter --convert <output folder> <file> [<file> ...]
///
/// Each file is analysed and converted on its own, exactly as in the app, at
/// preview size. It writes `<name>_fit.jpg` and, when the frame shows clear
/// film, `<name>_exposure.jpg`, and prints what the analysis found.
enum Headless {
    /// `NegativeConverter --export jpeg|tiff <output folder> <file> [<file> ...]`
    /// writes each file at full size with the default settings, as the
    /// Convert button does.
    static func exportIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--export"), args.count > flag + 3,
              let format = OutputFormat(rawValue: args[flag + 1]) else { return }
        let folder = URL(fileURLWithPath: args[flag + 2], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in args[(flag + 3)...] {
            let url = URL(fileURLWithPath: path)
            let destination = folder.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + "_positive." + format.fileExtension)
            do {
                let preview = try ImagePipeline.makePreview(url: url)
                let analysis = preview.withPixels {
                    NegativeAnalyzer.analyze(half: $0, width: preview.width, height: preview.height,
                                             rowStride: preview.rowStride)
                }
                let start = Date()
                try ImagePipeline.export(source: url, analysis: analysis, settings: ConversionSettings(),
                                         destination: destination, format: format, quality: 0.95)
                print("\(url.lastPathComponent) -> \(destination.lastPathComponent)"
                      + String(format: " in %.1f s", Date().timeIntervalSince(start)))
            } catch {
                print("\(url.lastPathComponent): FAILED \(error.localizedDescription)")
            }
        }
        exit(0)
    }

    static func runIfRequested() {
        exportIfRequested()
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--convert"), args.count > flag + 2 else { return }
        let folder = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in args[(flag + 2)...] {
            let url = URL(fileURLWithPath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            do {
                let preview = try ImagePipeline.makePreview(url: url)
                let a = preview.withPixels {
                    NegativeAnalyzer.analyze(half: $0, width: preview.width, height: preview.height,
                                             rowStride: preview.rowStride)
                }
                print("\(url.lastPathComponent): \(preview.width)x\(preview.height)"
                      + " bw=\(a.isBlackAndWhite) chroma=\(f(a.chromaSpread)) extremes=\(f(a.chromaExtremes))"
                      + " clearFilm=\(a.clearFilmFound) holder=\(a.foundHolderBorder)"
                      + " backlight=\(a.foundBacklightBorder) fallback=\(a.usedFallbackRegion)")
                print("  area x \(f(a.pictureArea.x0))-\(f(a.pictureArea.x1)) y \(f(a.pictureArea.y0))-\(f(a.pictureArea.y1))")
                print("  base \(f(a.filmBaseDensity)) mono \(f(a.monoFilmBaseDensity))")
                print("  low  \(f(a.colorShadowDensity)) mono \(f(a.monoShadowDensity))")
                print("  high \(f(a.colorHighlightDensity)) mono \(f(a.monoHighlightDensity))")
                print("  dense \(f(a.colorDenseDensity)) mono \(f(a.monoDenseDensity))")
                print("  tones colour \(f(a.colorToneDensities)) mono \(f(a.monoToneDensities))")
                print("  layer contrast \(f(a.layerContrast))")

                print("  " + channelStats(preview))

                var fit = ConversionSettings()
                fit.toneMode = .fitToPicture
                try write(ImagePipeline.renderPreview(preview, analysis: a, settings: fit),
                          to: folder.appendingPathComponent(stem + "_fit.jpg"))
                var byExposure = ConversionSettings()
                byExposure.toneMode = .filmExposure
                if ConversionRecipe(analysis: a, settings: byExposure).usesFilmExposure {
                    try write(ImagePipeline.renderPreview(preview, analysis: a, settings: byExposure),
                              to: folder.appendingPathComponent(stem + "_exposure.jpg"))
                }
            } catch {
                print("\(url.lastPathComponent): FAILED \(error.localizedDescription)")
            }
        }
        exit(0)
    }

    /// Share of pixels at or below zero, and the 1 %, 50 % and 99 % values, per channel.
    private static func channelStats(_ image: HalfImage) -> String {
        var parts: [String] = []
        image.withPixels { pixels in
            for c in 0..<3 {
                var values: [Float] = []
                values.reserveCapacity(image.width * image.height)
                var notPositive = 0
                for y in 0..<image.height {
                    let row = pixels + y * image.rowStride
                    for x in 0..<image.width {
                        let v = HalfFloat.table[Int(row[x * 4 + c])]
                        if !(v > 0) { notPositive += 1 }
                        values.append(v.isFinite ? v : 0)
                    }
                }
                values.sort()
                let n = values.count
                parts.append(String(format: "%@ <=0: %.2f%%, 1%%=%.5f 50%%=%.5f 99%%=%.5f",
                                    ["R", "G", "B"][c], 100 * Double(notPositive) / Double(n),
                                    values[n / 100], values[n / 2], values[n * 99 / 100]))
            }
        }
        return parts.joined(separator: "\n  ")
    }

    private static func f(_ v: Float) -> String { String(format: "%.3f", v) }
    private static func f(_ v: SIMD3<Float>) -> String { String(format: "(%.3f %.3f %.3f)", v.x, v.y, v.z) }

    private static func write(_ image: CGImage?, to url: URL) throws {
        guard let image,
              let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PipelineError.cannotWrite(url.lastPathComponent) }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw PipelineError.cannotWrite(url.lastPathComponent) }
    }
}

/// `NegativeConverter --check-modes <file>`: loads one file through the same
/// model the window uses, switches the tone mode the way the picker does, and
/// reports whether the preview picture changed.
@MainActor
enum ModelCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--check-modes"), args.count > flag + 1 else { return }
        let model = AppModel()
        model.add(urls: [URL(fileURLWithPath: args[flag + 1])])
        Task { @MainActor in
            func pixels(_ image: CGImage?) -> Data? { image?.dataProvider?.data as Data? }
            while model.items.first?.stage == .waiting || model.items.first?.stage == .analyzing {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let item = model.items.first, item.stage == .ready else {
                print("could not load the file"); exit(1)
            }
            let before = pixels(item.rendered)
            print("clear film found: \(item.analysis?.clearFilmFound == true), mode \(item.settings.toneMode)")
            let binding = model.settingsBinding(for: item.id)
            var changed = binding.wrappedValue
            changed.toneMode = .filmExposure
            binding.wrappedValue = changed
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let after = pixels(model.items.first?.rendered)
            print("mode now \(model.items.first!.settings.toneMode), uses film exposure: \(model.items.first!.usesFilmExposure)")
            print("preview picture changed: \(before != after)")
            exit(0)
        }
        RunLoop.main.run()
    }
}
#endif
