//
//  JSONCoding.swift
//  TraceCore
//
//  Created by Justin on 2026/02/04.
//

import Foundation

/// Centralized JSON encoder/decoder configuration for Trace persistence.
///
/// Policy:
/// - Encode using ISO-8601 dates (stable and human-readable).
/// - Decode with ISO-8601 first, then fall back to Foundation's default Date coding for legacy files.
public enum JSONCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            // Preferred: ISO-8601 strings (Trace policy).
            if let string = try? container.decode(String.self) {
                // Accept both fractional and non-fractional seconds.
                let isoWithFractional = ISO8601DateFormatter()
                isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = isoWithFractional.date(from: string) { return date }

                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                if let date = iso.date(from: string) { return date }
            }

            // Backward compatibility: Foundation default `Date` coding encodes as a number of seconds
            // since the reference date.
            if let double = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: double)
            }
            if let int = try? container.decode(Int.self) {
                return Date(timeIntervalSinceReferenceDate: Double(int))
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date encoding"
            )
        }
        return decoder
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            // Backward compatibility: older persisted files may have used default Date coding.
            let fallback = JSONDecoder()
            return try fallback.decode(type, from: data)
        }
    }
}
