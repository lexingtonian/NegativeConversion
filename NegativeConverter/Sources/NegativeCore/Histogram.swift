// Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import Foundation

/// A fixed-range histogram used for robust percentile estimates.
struct Histogram {
    let lowerBound: Float
    let binWidth: Float
    private let scale: Float
    private(set) var bins: [Int]
    private(set) var total = 0

    init(lowerBound: Float, upperBound: Float, binWidth: Float) {
        self.lowerBound = lowerBound
        self.binWidth = binWidth
        self.scale = 1 / binWidth
        let count = max(1, Int(((upperBound - lowerBound) / binWidth).rounded(.up)))
        self.bins = [Int](repeating: 0, count: count)
    }

    private func index(_ value: Float) -> Int {
        let i = Int(((value - lowerBound) * scale).rounded(.down))
        return min(max(i, 0), bins.count - 1)
    }

    mutating func add(_ value: Float) {
        bins[index(value)] += 1
        total += 1
    }

    /// Value below which the given fraction (0...1) of the samples lie.
    func percentile(_ fraction: Double) -> Float {
        guard total > 0 else { return lowerBound }
        let target = fraction * Double(total)
        var running = 0.0
        for (i, c) in bins.enumerated() where c > 0 {
            let next = running + Double(c)
            if next >= target {
                let inside = Float((target - running) / Double(c))
                return lowerBound + (Float(i) + min(max(inside, 0), 1)) * binWidth
            }
            running = next
        }
        return lowerBound + Float(bins.count) * binWidth
    }

    /// Number of samples with a value in `[from, to)`.
    func count(from: Float, to: Float) -> Int {
        guard to > from else { return 0 }
        let a = index(from)
        let b = index(to)
        guard b > a else { return 0 }
        var sum = 0
        for i in a..<b { sum += bins[i] }
        return sum
    }

    /// Number of samples with a value of at least `value`.
    func count(atLeast value: Float) -> Int {
        var sum = 0
        for i in index(value)..<bins.count { sum += bins[i] }
        return sum
    }

    /// Number of samples with a value below `value`.
    func count(below value: Float) -> Int {
        total - count(atLeast: value)
    }
}
