//
//  HPACKHuffmanEncoder.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Encodes data using the HPACK Huffman code table.
///
/// Discussion: Based on RFC 7541 Appendix B.
public class HuffmanEncoder {
    /// Encodes data using Huffman coding.
    /// - Parameter data: The data to encode.
    /// - Returns: Huffman-encoded data.
    public static func encode(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var result = Data()
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        let maskBuffer: (UInt64, Int) -> UInt64 = { buffer, count in
            guard count > 0 else { return 0 }
            if count >= 64 { return buffer }
            return buffer & ((UInt64(1) << count) - 1)
        }

        for byte in data {
            let sym = huffSymTable[Int(byte)]
            let nbits = Int(sym.nbits)
            let code = UInt64(sym.code)

            while bitCount + nbits > 64 {
                bitCount -= 8
                result.append(UInt8((bitBuffer >> bitCount) & 0xFF))
                bitBuffer = maskBuffer(bitBuffer, bitCount)
            }

            bitBuffer = (bitBuffer << nbits) | code
            bitCount += nbits

            // Flush complete bytes
            while bitCount >= 8 {
                bitCount -= 8
                result.append(UInt8((bitBuffer >> bitCount) & 0xFF))
                bitBuffer = maskBuffer(bitBuffer, bitCount)
            }
        }

        // Flush remaining bits with EOS padding (all 1s)
        if bitCount > 0 {
            bitBuffer = maskBuffer(bitBuffer, bitCount)
            let paddingBits = 8 - bitCount
            bitBuffer = (bitBuffer << paddingBits) | ((1 << paddingBits) - 1)
            result.append(UInt8(bitBuffer & 0xFF))
        }

        return result
    }

    /// Returns whether Huffman encoding would reduce size.
    /// - Parameter data: The data to evaluate.
    /// - Returns: `true` when Huffman encoding would reduce size.
    public static func shouldEncode(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }

        var totalBits = 0
        for byte in data {
            totalBits += Int(huffSymTable[Int(byte)].nbits)
        }

        let encodedBytes = (totalBits + 7) / 8
        return encodedBytes < data.count
    }
}

/// Represents a Huffman symbol table entry.
public struct HuffmanSymbol: Sendable {
    public let nbits: UInt32 // Number of bits in code.
    public let code: UInt32 // Huffman code (right-aligned).
}

/// Defines the Huffman encoding table from RFC 7541 Appendix B.
///
/// Each entry contains the bit length and code for that symbol.
let huffSymTable: [HuffmanSymbol] = [
    HuffmanSymbol(nbits: 13, code: 0x1FF8), // 0
    HuffmanSymbol(nbits: 23, code: 0x7FFFD8), // 1
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE2), // 2
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE3), // 3
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE4), // 4
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE5), // 5
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE6), // 6
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE7), // 7
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE8), // 8
    HuffmanSymbol(nbits: 24, code: 0xFFFFEA), // 9
    HuffmanSymbol(nbits: 30, code: 0x3FFF_FFFC), // 10
    HuffmanSymbol(nbits: 28, code: 0xFFFFFE9), // 11
    HuffmanSymbol(nbits: 28, code: 0xFFFFFEA), // 12
    HuffmanSymbol(nbits: 30, code: 0x3FFF_FFFD), // 13
    HuffmanSymbol(nbits: 28, code: 0xFFFFFEB), // 14
    HuffmanSymbol(nbits: 28, code: 0xFFFFFEC), // 15
    HuffmanSymbol(nbits: 28, code: 0xFFFFFED), // 16
    HuffmanSymbol(nbits: 28, code: 0xFFFFFEE), // 17
    HuffmanSymbol(nbits: 28, code: 0xFFFFFEF), // 18
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF0), // 19
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF1), // 20
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF2), // 21
    HuffmanSymbol(nbits: 30, code: 0x3FFF_FFFE), // 22
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF3), // 23
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF4), // 24
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF5), // 25
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF6), // 26
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF7), // 27
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF8), // 28
    HuffmanSymbol(nbits: 28, code: 0xFFFFFF9), // 29
    HuffmanSymbol(nbits: 28, code: 0xFFFFFFA), // 30
    HuffmanSymbol(nbits: 28, code: 0xFFFFFFB), // 31
    HuffmanSymbol(nbits: 6, code: 0x14), // 32
    HuffmanSymbol(nbits: 10, code: 0x3F8), // 33
    HuffmanSymbol(nbits: 10, code: 0x3F9), // 34
    HuffmanSymbol(nbits: 12, code: 0xFFA), // 35
    HuffmanSymbol(nbits: 13, code: 0x1FF9), // 36
    HuffmanSymbol(nbits: 6, code: 0x15), // 37
    HuffmanSymbol(nbits: 8, code: 0xF8), // 38
    HuffmanSymbol(nbits: 11, code: 0x7FA), // 39
    HuffmanSymbol(nbits: 10, code: 0x3FA), // 40
    HuffmanSymbol(nbits: 10, code: 0x3FB), // 41
    HuffmanSymbol(nbits: 8, code: 0xF9), // 42
    HuffmanSymbol(nbits: 11, code: 0x7FB), // 43
    HuffmanSymbol(nbits: 8, code: 0xFA), // 44
    HuffmanSymbol(nbits: 6, code: 0x16), // 45
    HuffmanSymbol(nbits: 6, code: 0x17), // 46
    HuffmanSymbol(nbits: 6, code: 0x18), // 47
    HuffmanSymbol(nbits: 5, code: 0x0), // 48
    HuffmanSymbol(nbits: 5, code: 0x1), // 49
    HuffmanSymbol(nbits: 5, code: 0x2), // 50
    HuffmanSymbol(nbits: 6, code: 0x19), // 51
    HuffmanSymbol(nbits: 6, code: 0x1A), // 52
    HuffmanSymbol(nbits: 6, code: 0x1B), // 53
    HuffmanSymbol(nbits: 6, code: 0x1C), // 54
    HuffmanSymbol(nbits: 6, code: 0x1D), // 55
    HuffmanSymbol(nbits: 6, code: 0x1E), // 56
    HuffmanSymbol(nbits: 6, code: 0x1F), // 57
    HuffmanSymbol(nbits: 7, code: 0x5C), // 58
    HuffmanSymbol(nbits: 8, code: 0xFB), // 59
    HuffmanSymbol(nbits: 15, code: 0x7FFC), // 60
    HuffmanSymbol(nbits: 6, code: 0x20), // 61
    HuffmanSymbol(nbits: 12, code: 0xFFB), // 62
    HuffmanSymbol(nbits: 10, code: 0x3FC), // 63
    HuffmanSymbol(nbits: 13, code: 0x1FFA), // 64
    HuffmanSymbol(nbits: 6, code: 0x21), // 65
    HuffmanSymbol(nbits: 7, code: 0x5D), // 66
    HuffmanSymbol(nbits: 7, code: 0x5E), // 67
    HuffmanSymbol(nbits: 7, code: 0x5F), // 68
    HuffmanSymbol(nbits: 7, code: 0x60), // 69
    HuffmanSymbol(nbits: 7, code: 0x61), // 70
    HuffmanSymbol(nbits: 7, code: 0x62), // 71
    HuffmanSymbol(nbits: 7, code: 0x63), // 72
    HuffmanSymbol(nbits: 7, code: 0x64), // 73
    HuffmanSymbol(nbits: 7, code: 0x65), // 74
    HuffmanSymbol(nbits: 7, code: 0x66), // 75
    HuffmanSymbol(nbits: 7, code: 0x67), // 76
    HuffmanSymbol(nbits: 7, code: 0x68), // 77
    HuffmanSymbol(nbits: 7, code: 0x69), // 78
    HuffmanSymbol(nbits: 7, code: 0x6A), // 79
    HuffmanSymbol(nbits: 7, code: 0x6B), // 80
    HuffmanSymbol(nbits: 7, code: 0x6C), // 81
    HuffmanSymbol(nbits: 7, code: 0x6D), // 82
    HuffmanSymbol(nbits: 7, code: 0x6E), // 83
    HuffmanSymbol(nbits: 7, code: 0x6F), // 84
    HuffmanSymbol(nbits: 7, code: 0x70), // 85
    HuffmanSymbol(nbits: 7, code: 0x71), // 86
    HuffmanSymbol(nbits: 7, code: 0x72), // 87
    HuffmanSymbol(nbits: 8, code: 0xFC), // 88
    HuffmanSymbol(nbits: 7, code: 0x73), // 89
    HuffmanSymbol(nbits: 8, code: 0xFD), // 90
    HuffmanSymbol(nbits: 13, code: 0x1FFB), // 91
    HuffmanSymbol(nbits: 19, code: 0x7FFF0), // 92
    HuffmanSymbol(nbits: 13, code: 0x1FFC), // 93
    HuffmanSymbol(nbits: 14, code: 0x3FFC), // 94
    HuffmanSymbol(nbits: 6, code: 0x22), // 95
    HuffmanSymbol(nbits: 15, code: 0x7FFD), // 96
    HuffmanSymbol(nbits: 5, code: 0x3), // 97
    HuffmanSymbol(nbits: 6, code: 0x23), // 98
    HuffmanSymbol(nbits: 5, code: 0x4), // 99
    HuffmanSymbol(nbits: 6, code: 0x24), // 100
    HuffmanSymbol(nbits: 5, code: 0x5), // 101
    HuffmanSymbol(nbits: 6, code: 0x25), // 102
    HuffmanSymbol(nbits: 6, code: 0x26), // 103
    HuffmanSymbol(nbits: 6, code: 0x27), // 104
    HuffmanSymbol(nbits: 5, code: 0x6), // 105
    HuffmanSymbol(nbits: 7, code: 0x74), // 106
    HuffmanSymbol(nbits: 7, code: 0x75), // 107
    HuffmanSymbol(nbits: 6, code: 0x28), // 108
    HuffmanSymbol(nbits: 6, code: 0x29), // 109
    HuffmanSymbol(nbits: 6, code: 0x2A), // 110
    HuffmanSymbol(nbits: 5, code: 0x7), // 111
    HuffmanSymbol(nbits: 6, code: 0x2B), // 112
    HuffmanSymbol(nbits: 7, code: 0x76), // 113
    HuffmanSymbol(nbits: 6, code: 0x2C), // 114
    HuffmanSymbol(nbits: 5, code: 0x8), // 115
    HuffmanSymbol(nbits: 5, code: 0x9), // 116
    HuffmanSymbol(nbits: 6, code: 0x2D), // 117
    HuffmanSymbol(nbits: 7, code: 0x77), // 118
    HuffmanSymbol(nbits: 7, code: 0x78), // 119
    HuffmanSymbol(nbits: 7, code: 0x79), // 120
    HuffmanSymbol(nbits: 7, code: 0x7A), // 121
    HuffmanSymbol(nbits: 7, code: 0x7B), // 122
    HuffmanSymbol(nbits: 15, code: 0x7FFE), // 123
    HuffmanSymbol(nbits: 11, code: 0x7FC), // 124
    HuffmanSymbol(nbits: 14, code: 0x3FFD), // 125
    HuffmanSymbol(nbits: 13, code: 0x1FFD), // 126
    HuffmanSymbol(nbits: 28, code: 0xFFFFFFC), // 127
    HuffmanSymbol(nbits: 20, code: 0xFFFE6), // 128
    HuffmanSymbol(nbits: 22, code: 0x3FFFD2), // 129
    HuffmanSymbol(nbits: 20, code: 0xFFFE7), // 130
    HuffmanSymbol(nbits: 20, code: 0xFFFE8), // 131
    HuffmanSymbol(nbits: 22, code: 0x3FFFD3), // 132
    HuffmanSymbol(nbits: 22, code: 0x3FFFD4), // 133
    HuffmanSymbol(nbits: 22, code: 0x3FFFD5), // 134
    HuffmanSymbol(nbits: 23, code: 0x7FFFD9), // 135
    HuffmanSymbol(nbits: 22, code: 0x3FFFD6), // 136
    HuffmanSymbol(nbits: 23, code: 0x7FFFDA), // 137
    HuffmanSymbol(nbits: 23, code: 0x7FFFDB), // 138
    HuffmanSymbol(nbits: 23, code: 0x7FFFDC), // 139
    HuffmanSymbol(nbits: 23, code: 0x7FFFDD), // 140
    HuffmanSymbol(nbits: 23, code: 0x7FFFDE), // 141
    HuffmanSymbol(nbits: 24, code: 0xFFFFEB), // 142
    HuffmanSymbol(nbits: 23, code: 0x7FFFDF), // 143
    HuffmanSymbol(nbits: 24, code: 0xFFFFEC), // 144
    HuffmanSymbol(nbits: 24, code: 0xFFFFED), // 145
    HuffmanSymbol(nbits: 22, code: 0x3FFFD7), // 146
    HuffmanSymbol(nbits: 23, code: 0x7FFFE0), // 147
    HuffmanSymbol(nbits: 24, code: 0xFFFFEE), // 148
    HuffmanSymbol(nbits: 23, code: 0x7FFFE1), // 149
    HuffmanSymbol(nbits: 23, code: 0x7FFFE2), // 150
    HuffmanSymbol(nbits: 23, code: 0x7FFFE3), // 151
    HuffmanSymbol(nbits: 23, code: 0x7FFFE4), // 152
    HuffmanSymbol(nbits: 21, code: 0x1FFFDC), // 153
    HuffmanSymbol(nbits: 22, code: 0x3FFFD8), // 154
    HuffmanSymbol(nbits: 23, code: 0x7FFFE5), // 155
    HuffmanSymbol(nbits: 22, code: 0x3FFFD9), // 156
    HuffmanSymbol(nbits: 23, code: 0x7FFFE6), // 157
    HuffmanSymbol(nbits: 23, code: 0x7FFFE7), // 158
    HuffmanSymbol(nbits: 24, code: 0xFFFFEF), // 159
    HuffmanSymbol(nbits: 22, code: 0x3FFFDA), // 160
    HuffmanSymbol(nbits: 21, code: 0x1FFFDD), // 161
    HuffmanSymbol(nbits: 20, code: 0xFFFE9), // 162
    HuffmanSymbol(nbits: 22, code: 0x3FFFDB), // 163
    HuffmanSymbol(nbits: 22, code: 0x3FFFDC), // 164
    HuffmanSymbol(nbits: 23, code: 0x7FFFE8), // 165
    HuffmanSymbol(nbits: 23, code: 0x7FFFE9), // 166
    HuffmanSymbol(nbits: 21, code: 0x1FFFDE), // 167
    HuffmanSymbol(nbits: 23, code: 0x7FFFEA), // 168
    HuffmanSymbol(nbits: 22, code: 0x3FFFDD), // 169
    HuffmanSymbol(nbits: 22, code: 0x3FFFDE), // 170
    HuffmanSymbol(nbits: 24, code: 0xFFFFF0), // 171
    HuffmanSymbol(nbits: 21, code: 0x1FFFDF), // 172
    HuffmanSymbol(nbits: 22, code: 0x3FFFDF), // 173
    HuffmanSymbol(nbits: 23, code: 0x7FFFEB), // 174
    HuffmanSymbol(nbits: 23, code: 0x7FFFEC), // 175
    HuffmanSymbol(nbits: 21, code: 0x1FFFE0), // 176
    HuffmanSymbol(nbits: 21, code: 0x1FFFE1), // 177
    HuffmanSymbol(nbits: 22, code: 0x3FFFE0), // 178
    HuffmanSymbol(nbits: 21, code: 0x1FFFE2), // 179
    HuffmanSymbol(nbits: 23, code: 0x7FFFED), // 180
    HuffmanSymbol(nbits: 22, code: 0x3FFFE1), // 181
    HuffmanSymbol(nbits: 23, code: 0x7FFFEE), // 182
    HuffmanSymbol(nbits: 23, code: 0x7FFFEF), // 183
    HuffmanSymbol(nbits: 20, code: 0xFFFEA), // 184
    HuffmanSymbol(nbits: 22, code: 0x3FFFE2), // 185
    HuffmanSymbol(nbits: 22, code: 0x3FFFE3), // 186
    HuffmanSymbol(nbits: 22, code: 0x3FFFE4), // 187
    HuffmanSymbol(nbits: 23, code: 0x7FFFF0), // 188
    HuffmanSymbol(nbits: 22, code: 0x3FFFE5), // 189
    HuffmanSymbol(nbits: 22, code: 0x3FFFE6), // 190
    HuffmanSymbol(nbits: 23, code: 0x7FFFF1), // 191
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE0), // 192
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE1), // 193
    HuffmanSymbol(nbits: 20, code: 0xFFFEB), // 194
    HuffmanSymbol(nbits: 19, code: 0x7FFF1), // 195
    HuffmanSymbol(nbits: 22, code: 0x3FFFE7), // 196
    HuffmanSymbol(nbits: 23, code: 0x7FFFF2), // 197
    HuffmanSymbol(nbits: 22, code: 0x3FFFE8), // 198
    HuffmanSymbol(nbits: 25, code: 0x1FFFFEC), // 199
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE2), // 200
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE3), // 201
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE4), // 202
    HuffmanSymbol(nbits: 27, code: 0x7FFFFDE), // 203
    HuffmanSymbol(nbits: 27, code: 0x7FFFFDF), // 204
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE5), // 205
    HuffmanSymbol(nbits: 24, code: 0xFFFFF1), // 206
    HuffmanSymbol(nbits: 25, code: 0x1FFFFED), // 207
    HuffmanSymbol(nbits: 19, code: 0x7FFF2), // 208
    HuffmanSymbol(nbits: 21, code: 0x1FFFE3), // 209
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE6), // 210
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE0), // 211
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE1), // 212
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE7), // 213
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE2), // 214
    HuffmanSymbol(nbits: 24, code: 0xFFFFF2), // 215
    HuffmanSymbol(nbits: 21, code: 0x1FFFE4), // 216
    HuffmanSymbol(nbits: 21, code: 0x1FFFE5), // 217
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE8), // 218
    HuffmanSymbol(nbits: 26, code: 0x3FFFFE9), // 219
    HuffmanSymbol(nbits: 28, code: 0xFFFFFFD), // 220
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE3), // 221
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE4), // 222
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE5), // 223
    HuffmanSymbol(nbits: 20, code: 0xFFFEC), // 224
    HuffmanSymbol(nbits: 24, code: 0xFFFFF3), // 225
    HuffmanSymbol(nbits: 20, code: 0xFFFED), // 226
    HuffmanSymbol(nbits: 21, code: 0x1FFFE6), // 227
    HuffmanSymbol(nbits: 22, code: 0x3FFFE9), // 228
    HuffmanSymbol(nbits: 21, code: 0x1FFFE7), // 229
    HuffmanSymbol(nbits: 21, code: 0x1FFFE8), // 230
    HuffmanSymbol(nbits: 23, code: 0x7FFFF3), // 231
    HuffmanSymbol(nbits: 22, code: 0x3FFFEA), // 232
    HuffmanSymbol(nbits: 22, code: 0x3FFFEB), // 233
    HuffmanSymbol(nbits: 25, code: 0x1FFFFEE), // 234
    HuffmanSymbol(nbits: 25, code: 0x1FFFFEF), // 235
    HuffmanSymbol(nbits: 24, code: 0xFFFFF4), // 236
    HuffmanSymbol(nbits: 24, code: 0xFFFFF5), // 237
    HuffmanSymbol(nbits: 26, code: 0x3FFFFEA), // 238
    HuffmanSymbol(nbits: 23, code: 0x7FFFF4), // 239
    HuffmanSymbol(nbits: 26, code: 0x3FFFFEB), // 240
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE6), // 241
    HuffmanSymbol(nbits: 26, code: 0x3FFFFEC), // 242
    HuffmanSymbol(nbits: 26, code: 0x3FFFFED), // 243
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE7), // 244
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE8), // 245
    HuffmanSymbol(nbits: 27, code: 0x7FFFFE9), // 246
    HuffmanSymbol(nbits: 27, code: 0x7FFFFEA), // 247
    HuffmanSymbol(nbits: 27, code: 0x7FFFFEB), // 248
    HuffmanSymbol(nbits: 28, code: 0xFFFFFFE), // 249
    HuffmanSymbol(nbits: 27, code: 0x7FFFFEC), // 250
    HuffmanSymbol(nbits: 27, code: 0x7FFFFED), // 251
    HuffmanSymbol(nbits: 27, code: 0x7FFFFEE), // 252
    HuffmanSymbol(nbits: 27, code: 0x7FFFFEF), // 253
    HuffmanSymbol(nbits: 27, code: 0x7FFFFF0), // 254
    HuffmanSymbol(nbits: 26, code: 0x3FFFFEE), // 255
    HuffmanSymbol(nbits: 30, code: 0x3FFF_FFFF) // 256
]
