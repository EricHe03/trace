//
//  Punycode.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Punycode encoder/decoder for Internationalized Domain Names in Applications (IDNA)
public enum Punycode {
    // MARK: - Constants (from RFC 3492)

    private static let base: Int = 36
    private static let tmin: Int = 1
    private static let tmax: Int = 26
    private static let skew: Int = 38
    private static let damp: Int = 700
    private static let initialBias: Int = 72
    private static let initialN: Int = 0x80
    private static let delimiter: Character = "-"
    private static let prefix = "xn--"
    private static let cacheLimit = 256
    private nonisolated(unsafe) static var decodeCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    // MARK: - Public API

    /// Encode a Unicode string to Punycode (ASCII-compatible encoding)
    /// - Parameter input: Unicode string to encode
    /// - Returns: Punycode-encoded string, or nil if encoding fails
    public static func encode(_ input: String) -> String? {
        // If the string is already ASCII, no encoding needed
        if input.allSatisfy(\.isASCII) {
            return input
        }

        var output = ""

        let scalars = Array(input.unicodeScalars)

        // Extract and append all basic code points (ASCII) by scalar
        let basicScalars = scalars.filter(\.isASCII)
        output.append(String(String.UnicodeScalarView(basicScalars)))

        let handledCount = basicScalars.count
        let inputLength = scalars.count

        // If we handled all characters, we're done
        if handledCount == inputLength {
            return input
        }

        // Append delimiter if there were basic code points
        if handledCount > 0 {
            output.append(delimiter)
        }

        var n = initialN
        var delta = 0
        var bias = initialBias
        var h = handledCount

        while h < inputLength {
            // Find the minimum code point >= n in the input
            let codePoints: [Int] = scalars.map { Int($0.value) }
            let filtered: [Int] = codePoints.filter { $0 >= n }
            let m: Int = filtered.min() ?? Int.max

            if m == Int.max {
                return nil
            }

            // Increase delta by (m - n) * (h + 1)
            delta += (m - n) * (h + 1)
            n = m

            for scalar in scalars {
                let c = Int(scalar.value)

                if c < n {
                    delta += 1
                } else if c == n {
                    // Encode delta
                    var q = delta
                    var k = base

                    while true {
                        let t: Int = if k <= bias {
                            tmin
                        } else if k >= bias + tmax {
                            tmax
                        } else {
                            k - bias
                        }

                        if q < t {
                            break
                        }

                        let digit: Int = t + ((q - t) % (base - t))
                        output.append(encodeDigit(digit))
                        q = (q - t) / (base - t)
                        k += base
                    }

                    output.append(encodeDigit(q))
                    bias = adapt(delta, h + 1, h == handledCount)
                    delta = 0
                    h += 1
                }
            }

            delta += 1
            n += 1
        }

        if output != input {
            cacheLock.lock()
            if decodeCache.count >= cacheLimit {
                decodeCache.removeAll(keepingCapacity: true)
            }
            decodeCache[output] = input
            cacheLock.unlock()
        }

        return output
    }

    /// Decode a Punycode string to Unicode
    /// - Parameter input: Punycode-encoded string
    /// - Returns: Decoded Unicode string, or nil if decoding fails
    public static func decode(_ input: String) -> String? {
        if input.allSatisfy(\.isASCII),
           !input.contains(delimiter),
           input.rangeOfCharacter(from: .decimalDigits) == nil {
            cacheLock.lock()
            let cached = decodeCache[input]
            cacheLock.unlock()
            return cached ?? input
        }

        var output: [UnicodeScalar] = []

        // Find the last delimiter
        let lastDelimiterIndex = input.lastIndex(of: delimiter)

        // Extract basic code points (everything before last delimiter)
        if let delimiterIndex = lastDelimiterIndex {
            let basicPart = input[..<delimiterIndex]
            for char in basicPart {
                guard let scalar = char.unicodeScalars.first else {
                    return nil
                }
                output.append(scalar)
            }
        }

        let encoded = lastDelimiterIndex.map { input[input.index(after: $0)...] } ?? input[...]

        var n = initialN
        var i = 0
        var bias = initialBias
        var pos = 0

        while pos < encoded.count {
            let oldi = i
            var w = 1
            var k = base

            while pos < encoded.count {
                let char = encoded[encoded.index(encoded.startIndex, offsetBy: pos)]
                pos += 1

                guard let digit = decodeDigit(char) else {
                    return nil
                }

                i += digit * w

                let t: Int = if k <= bias {
                    tmin
                } else if k >= bias + tmax {
                    tmax
                } else {
                    k - bias
                }

                if digit < t {
                    break
                }

                w *= (base - t)
                k += base
            }

            bias = adapt(i - oldi, output.count + 1, oldi == 0)
            n += i / (output.count + 1)
            i %= (output.count + 1)

            guard let scalar = UnicodeScalar(n) else {
                return nil
            }

            output.insert(scalar, at: i)
            i += 1
        }

        return String(String.UnicodeScalarView(output))
    }

    /// Encode a domain name using IDNA (Internationalized Domain Names in Applications)
    /// - Parameter domain: Domain name to encode
    /// - Returns: IDNA-encoded domain name
    public static func encodeDomain(_ domain: String) -> String {
        let labels = domain.split(separator: ".")
        let encodedLabels = labels.map { label -> String in
            let labelString = String(label)

            // Only encode if it contains non-ASCII characters
            if labelString.allSatisfy(\.isASCII) {
                return labelString
            }

            // Encode and add prefix
            if let encoded = encode(labelString) {
                return prefix + encoded
            }

            return labelString
        }

        return encodedLabels.joined(separator: ".")
    }

    /// Decode a domain name from IDNA format
    /// - Parameter domain: IDNA-encoded domain name
    /// - Returns: Decoded domain name
    public static func decodeDomain(_ domain: String) -> String {
        let labels = domain.split(separator: ".")
        let decodedLabels = labels.map { label -> String in
            let labelString = String(label)

            // Check if it starts with the punycode prefix
            if labelString.lowercased().hasPrefix(prefix) {
                let encoded = String(labelString.dropFirst(prefix.count))
                return decode(encoded) ?? labelString
            }

            return labelString
        }

        return decodedLabels.joined(separator: ".")
    }

    // MARK: - Helper Functions

    private static func adapt(_ delta: Int, _ numPoints: Int, _ firstTime: Bool) -> Int {
        var delta = delta

        if firstTime {
            delta /= damp
        } else {
            delta /= 2
        }

        delta += delta / numPoints

        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= (base - tmin)
            k += base
        }

        return k + ((base - tmin + 1) * delta) / (delta + skew)
    }

    private static func encodeDigit(_ digit: Int) -> Character {
        let scalarValue: Int = if digit < 26 {
            // a-z
            digit + 97
        } else {
            // 0-9
            digit - 26 + 48
        }

        // Defensive: The mapping above always yields valid ASCII scalars.
        return Character(UnicodeScalar(scalarValue) ?? "?")
    }

    private static func decodeDigit(_ char: Character) -> Int? {
        guard let scalar = char.unicodeScalars.first else {
            return nil
        }

        let value = Int(scalar.value)

        if value >= 48 && value <= 57 {
            // 0-9
            return value - 48 + 26
        } else if value >= 65 && value <= 90 {
            // A-Z
            return value - 65
        } else if value >= 97 && value <= 122 {
            // a-z
            return value - 97
        }

        return nil
    }
}
