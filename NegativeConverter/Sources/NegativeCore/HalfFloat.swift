import Foundation

/// Decoding of IEEE 754 half-precision floats.
///
/// Images are handed to the core as 16-bit half-float RGBA. Half floats have
/// constant *relative* precision, which suits film density data (a logarithmic
/// quantity), and there are only 65,536 possible values per channel, so a whole
/// tone curve can be precomputed as a lookup table.
public enum HalfFloat {
    /// Converts one half-float bit pattern to a `Float`.
    public static func toFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exponent = UInt32(h >> 10) & 0x1F
        let mantissa = UInt32(h & 0x03FF)
        let bits: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                bits = sign
            } else {
                // Subnormal half: renormalise into a normal Float.
                var e: UInt32 = 113
                var m = mantissa
                while m & 0x0400 == 0 {
                    m <<= 1
                    e -= 1
                }
                bits = sign | (e << 23) | ((m & 0x03FF) << 13)
            }
        } else if exponent == 31 {
            bits = sign | 0x7F80_0000 | (mantissa << 13)   // inf / NaN
        } else {
            bits = sign | ((exponent + 112) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: bits)
    }

    /// `table[bits]` is the Float value of half-float bit pattern `bits`.
    public static let table: [Float] = (0..<65536).map { toFloat(UInt16($0)) }
}
