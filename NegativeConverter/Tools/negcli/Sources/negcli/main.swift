// Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import Foundation
import NegativeCore

// usage: negcli in.half out.rgba [auto|color|bw]
//        negcli --roll a.half b.half ...   (writes a.fit.rgba and a.trust.rgba for each)
func load(_ path: String) -> (w: Int, h: Int, half: [UInt16]) {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) })
    let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) })
    var half = [UInt16](repeating: 0, count: w * h * 4)
    half.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[8..<(8 + w*h*8)])) } }
    return (w, h, half)
}
func f(_ v: SIMD3<Float>) -> String { String(format: "(%.3f %.3f %.3f)", v.x, v.y, v.z) }
func run(_ recipe: ConversionRecipe, _ img: (w: Int, h: Int, half: [UInt16]), _ out: String) {
    var o = [UInt8](repeating: 0, count: img.w * img.h * 4)
    img.half.withUnsafeBufferPointer { src in o.withUnsafeMutableBufferPointer { dst in
        recipe.convertConcurrently(half: src.baseAddress!, width: img.w, height: img.h, rowStride: img.w * 4, output: dst.baseAddress!, outputRowBytes: img.w * 4) } }
    try! Data(o).write(to: URL(fileURLWithPath: out))
}
let args = CommandLine.arguments
if args[1] == "--roll" {
    for path in args[2...] {
        let img = load(path)
        let a = NegativeAnalyzer.analyze(half: img.half, width: img.w, height: img.h)
        let stem = String(path.dropLast(5))
        var fit = ConversionSettings(); fit.toneMode = .fitToPicture
        run(ConversionRecipe(analysis: a, settings: fit), img, stem + ".fit.rgba")
        let trust = ConversionRecipe(analysis: a)
        run(trust, img, stem + ".trust.rgba")
        print("\(path.split(separator: "/").last!): bw=\(a.isBlackAndWhite) clearFilm=\(a.clearFilmFound) usesExposure=\(trust.usesFilmExposure) base=\(f(a.filmBaseDensity)) dense=\(f(a.colorDenseDensity)) holder=\(a.foundHolderBorder) backlight=\(a.foundBacklightBorder)")
    }
} else {
    let img = load(args[1])
    let a = NegativeAnalyzer.analyze(half: img.half, width: img.w, height: img.h)
    var s = ConversionSettings()
    if args.count > 3 { s.filmType = args[3] == "bw" ? .blackAndWhite : (args[3] == "color" ? .color : .auto) }
    run(ConversionRecipe(analysis: a, settings: s), img, args[2])
    print("\(args[1].split(separator: "/").last!): bw=\(a.isBlackAndWhite) chroma=\(String(format: "%.3f", a.chromaSpread)) holder=\(a.foundHolderBorder) backlight=\(a.foundBacklightBorder) fallback=\(a.usedFallbackRegion)")
}
