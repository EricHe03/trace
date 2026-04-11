//
//  ProtobufDecoder.swift
//  TraceCore
//
//  Pure-Swift, zero-dependency protobuf wire-format decoder.
//  Supports best-effort (schema-free) and schema-aware decoding.
//

import Foundation

// MARK: - Public Types

public enum ProtobufDecoder {
    // MARK: - Value

    public indirect enum Value: Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case string(String)
        case bytes(Data)
        case submessage([Field])
        case repeated([Value])
    }

    // MARK: - Field

    public struct Field: Identifiable, Sendable {
        public let id: UUID
        public let fieldNumber: Int
        public let wireType: Int
        public let value: Value
        public var name: String?

        init(fieldNumber: Int, wireType: Int, value: Value, name: String? = nil) {
            self.id = UUID()
            self.fieldNumber = fieldNumber
            self.wireType = wireType
            self.value = value
            self.name = name
        }

        public var displayName: String {
            name ?? "field_\(fieldNumber)"
        }
    }

    // MARK: - Public API

    /// Decode raw protobuf binary data into a list of fields.
    /// - Parameters:
    ///   - data: Raw protobuf binary (without gRPC frame header).
    ///   - descriptor: Optional message descriptor for field-name resolution.
    ///   - depth: Recursion depth guard (max 4).
    /// - Returns: Decoded fields, or empty array if decoding fails entirely.
    public static func decode(
        _ data: Data,
        descriptor: ProtobufSchema.MessageDescriptor? = nil,
        depth: Int = 0
    ) -> [Field] {
        guard depth < 5 else { return [] }
        var fields: [Field] = []
        var repeated: [Int: [Value]] = [:]
        var cursor = data.startIndex

        while cursor < data.endIndex {
            guard let (tag, afterTag) = readVarint(data, from: cursor) else { break }
            cursor = afterTag

            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            guard fieldNumber > 0 && fieldNumber <= 536_870_911 else { break }

            let value: Value
            switch wireType {
            case 0: // varint
                guard let (v, next) = readVarint(data, from: cursor) else { return fields }
                value = .varint(v)
                cursor = next

            case 1: // 64-bit fixed
                guard let next = data.index(cursor, offsetBy: 8, limitedBy: data.endIndex) else { return fields }
                let slice = data[cursor ..< next]
                var raw: UInt64 = 0
                for (i, byte) in slice.enumerated() {
                    raw |= UInt64(byte) << (i * 8)
                }
                value = .fixed64(raw)
                cursor = next

            case 2: // length-delimited
                guard let (len, afterLen) = readVarint(data, from: cursor) else { return fields }
                guard len <= UInt64(data.endIndex - afterLen) else { return fields }
                let payloadEnd = data.index(afterLen, offsetBy: Int(len))
                let payload = data[afterLen ..< payloadEnd]
                cursor = payloadEnd
                value = interpretLengthDelimited(Data(payload), depth: depth, descriptor: descriptor, fieldNumber: fieldNumber)

            case 5: // 32-bit fixed
                guard let next = data.index(cursor, offsetBy: 4, limitedBy: data.endIndex) else { return fields }
                let slice = data[cursor ..< next]
                var raw: UInt32 = 0
                for (i, byte) in slice.enumerated() {
                    raw |= UInt32(byte) << (i * 8)
                }
                value = .fixed32(raw)
                cursor = next

            default:
                // Unknown wire type — stop; we can't safely skip.
                return fields
            }

            // Collect repeated fields
            if repeated[fieldNumber] != nil {
                repeated[fieldNumber]!.append(value)
            } else if fields.last?.fieldNumber == fieldNumber && fields.last?.wireType == wireType {
                // Upgrade last field to repeated
                if case let .repeated(existing) = fields.last!.value {
                    repeated[fieldNumber] = existing + [value]
                } else {
                    repeated[fieldNumber] = [fields.last!.value, value]
                }
                fields.removeLast()
            } else {
                if let pending = repeated[fieldNumber] {
                    let name = descriptor?.fieldName(number: fieldNumber)
                    fields.append(Field(fieldNumber: fieldNumber, wireType: wireType, value: .repeated(pending), name: name))
                    repeated.removeValue(forKey: fieldNumber)
                }
                let name = descriptor?.fieldName(number: fieldNumber)
                fields.append(Field(fieldNumber: fieldNumber, wireType: wireType, value: value, name: name))
            }
        }

        // Flush any remaining repeated fields
        for (num, values) in repeated.sorted(by: { $0.key < $1.key }) {
            let name = descriptor?.fieldName(number: num)
            let wireType = fields.first(where: { $0.fieldNumber == num })?.wireType ?? 2
            fields.append(Field(fieldNumber: num, wireType: wireType, value: .repeated(values), name: name))
        }

        return fields
    }

    /// Strip gRPC 5-byte frame headers and decode each message payload.
    /// Skips embedded gRPC-Web trailer frames (flag & 0x80 != 0).
    public static func decodeGRPCMessages(
        from data: Data,
        contentType: String? = nil,
        descriptor: ProtobufSchema.MessageDescriptor? = nil
    ) -> [[Field]] {
        let frameData = normalizedGRPCBody(data, contentType: contentType)
        var results: [[Field]] = []
        var offset = frameData.startIndex
        while offset + 5 <= frameData.endIndex {
            let flag = frameData[offset]
            let len = Int(frameData[offset + 1]) << 24
                | Int(frameData[offset + 2]) << 16
                | Int(frameData[offset + 3]) << 8
                | Int(frameData[offset + 4])
            guard len >= 0,
                  let next = frameData.index(offset, offsetBy: 5 + len, limitedBy: frameData.endIndex) else { break }
            if flag & 0x80 == 0 {
                let payload = frameData[(offset + 5) ..< next]
                results.append(decode(Data(payload), descriptor: descriptor))
            }
            offset = next
        }
        return results
    }

    // MARK: - Helpers

    private static func interpretLengthDelimited(
        _ payload: Data,
        depth: Int,
        descriptor: ProtobufSchema.MessageDescriptor?,
        fieldNumber: Int
    ) -> Value {
        if payload.isEmpty {
            return .string("")
        }
        // 1. Try valid UTF-8 string
        if let str = String(data: payload, encoding: .utf8), str.unicodeScalars.allSatisfy({ $0.value < 0xFFFD }) {
            return .string(str)
        }
        // 2. Try recursive protobuf decode (depth guard applied in decode())
        if depth < 4 {
            let nested = decode(payload, descriptor: nil, depth: depth + 1)
            if isPlausibleProtoMessage(nested, originalSize: payload.count) {
                return .submessage(nested)
            }
        }
        // 3. Raw bytes fallback
        return .bytes(payload)
    }

    /// Heuristic: a parsed result is a plausible protobuf message if it has fields
    /// and all field numbers are in the valid range.
    private static func isPlausibleProtoMessage(_ fields: [Field], originalSize: Int) -> Bool {
        guard !fields.isEmpty else { return false }
        guard fields.allSatisfy({ $0.fieldNumber >= 1 && $0.fieldNumber <= 536_870_911 }) else { return false }
        return true
    }

    /// Decode a varint from data starting at `from`. Returns (value, nextCursor) or nil on failure.
    static func readVarint(_ data: Data, from start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift = 0
        var cursor = start
        while cursor < data.endIndex {
            let byte = data[cursor]
            cursor = data.index(after: cursor)
            result |= UInt64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 {
                return (result, cursor)
            }
            if shift >= 70 { return nil } // Max 10 bytes for 64-bit varint
        }
        return nil
    }

    private static func normalizedGRPCBody(_ data: Data, contentType: String?) -> Data {
        guard isGRPCWebText(contentType: contentType) else { return data }
        return Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data()
    }

    private static func isGRPCWebText(contentType: String?) -> Bool {
        guard let contentType else { return false }
        let normalized = contentType.lowercased()
        return normalized.contains("grpc-web-text") || normalized.contains("grpc-web+text")
    }
}

// MARK: - Value Display Helpers

extension ProtobufDecoder.Value {
    public var previewText: String {
        switch self {
        case let .varint(v): return "\(v)"
        case let .fixed64(v): return "0x\(String(v, radix: 16))"
        case let .fixed32(v): return "0x\(String(v, radix: 16))"
        case let .string(s): return s.prefix(80).description + (s.count > 80 ? "…" : "")
        case let .bytes(d): return hexPreview(d)
        case let .submessage(fields): return "{\(fields.count) field\(fields.count == 1 ? "" : "s")}"
        case let .repeated(values): return "[\(values.count) item\(values.count == 1 ? "" : "s")]"
        }
    }

    public var typeLabel: String {
        switch self {
        case .varint: return "varint"
        case .fixed64: return "fixed64"
        case .fixed32: return "fixed32"
        case .string: return "string"
        case .bytes: return "bytes"
        case .submessage: return "message"
        case .repeated: return "repeated"
        }
    }

    private func hexPreview(_ data: Data) -> String {
        let preview = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > 16 ? preview + "…" : preview
    }
}
