//
//  HPACKEncoder.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Encodes and decodes HPACK header blocks.
public class HPACKCoder {
    // MARK: - Dynamic Table

    private var dynamicTable: [HPACKHeader] = []
    private var dynamicTableSize: Int = 0
    private var maxDynamicTableSize: Int = 4096
    private var maxAllowedDynamicTableSize: Int = 4096

    // MARK: - Table Tracking for Inspection

    /// Captures table events for debugging and inspection.
    private(set) var tableEvents: [HPACKTableEvent] = []

    /// Controls whether table events are recorded (disabled by default for performance).
    public var recordEvents: Bool = false

    /// Sets the maximum number of events to keep in history.
    public var maxEventHistory: Int = 100

    // MARK: - Static Table (RFC 7541 Appendix A)

    private static let staticTable: [HPACKHeader] = [
        HPACKHeader(name: ":authority", value: ""),
        HPACKHeader(name: ":method", value: "GET"),
        HPACKHeader(name: ":method", value: "POST"),
        HPACKHeader(name: ":path", value: "/"),
        HPACKHeader(name: ":path", value: "/index.html"),
        HPACKHeader(name: ":scheme", value: "http"),
        HPACKHeader(name: ":scheme", value: "https"),
        HPACKHeader(name: ":status", value: "200"),
        HPACKHeader(name: ":status", value: "204"),
        HPACKHeader(name: ":status", value: "206"),
        HPACKHeader(name: ":status", value: "304"),
        HPACKHeader(name: ":status", value: "400"),
        HPACKHeader(name: ":status", value: "404"),
        HPACKHeader(name: ":status", value: "500"),
        HPACKHeader(name: "accept-charset", value: ""),
        HPACKHeader(name: "accept-encoding", value: "gzip, deflate"),
        HPACKHeader(name: "accept-language", value: ""),
        HPACKHeader(name: "accept-ranges", value: ""),
        HPACKHeader(name: "accept", value: ""),
        HPACKHeader(name: "access-control-allow-origin", value: ""),
        HPACKHeader(name: "age", value: ""),
        HPACKHeader(name: "allow", value: ""),
        HPACKHeader(name: "authorization", value: ""),
        HPACKHeader(name: "cache-control", value: ""),
        HPACKHeader(name: "content-disposition", value: ""),
        HPACKHeader(name: "content-encoding", value: ""),
        HPACKHeader(name: "content-language", value: ""),
        HPACKHeader(name: "content-length", value: ""),
        HPACKHeader(name: "content-location", value: ""),
        HPACKHeader(name: "content-range", value: ""),
        HPACKHeader(name: "content-type", value: ""),
        HPACKHeader(name: "cookie", value: ""),
        HPACKHeader(name: "date", value: ""),
        HPACKHeader(name: "etag", value: ""),
        HPACKHeader(name: "expect", value: ""),
        HPACKHeader(name: "expires", value: ""),
        HPACKHeader(name: "from", value: ""),
        HPACKHeader(name: "host", value: ""),
        HPACKHeader(name: "if-match", value: ""),
        HPACKHeader(name: "if-modified-since", value: ""),
        HPACKHeader(name: "if-none-match", value: ""),
        HPACKHeader(name: "if-range", value: ""),
        HPACKHeader(name: "if-unmodified-since", value: ""),
        HPACKHeader(name: "last-modified", value: ""),
        HPACKHeader(name: "link", value: ""),
        HPACKHeader(name: "location", value: ""),
        HPACKHeader(name: "max-forwards", value: ""),
        HPACKHeader(name: "proxy-authenticate", value: ""),
        HPACKHeader(name: "proxy-authorization", value: ""),
        HPACKHeader(name: "range", value: ""),
        HPACKHeader(name: "referer", value: ""),
        HPACKHeader(name: "refresh", value: ""),
        HPACKHeader(name: "retry-after", value: ""),
        HPACKHeader(name: "server", value: ""),
        HPACKHeader(name: "set-cookie", value: ""),
        HPACKHeader(name: "strict-transport-security", value: ""),
        HPACKHeader(name: "transfer-encoding", value: ""),
        HPACKHeader(name: "user-agent", value: ""),
        HPACKHeader(name: "vary", value: ""),
        HPACKHeader(name: "via", value: ""),
        HPACKHeader(name: "www-authenticate", value: "")
    ]

    // MARK: - Decoding

    /// Decodes HPACK-compressed headers.
    public func decode(_ data: Data) throws -> [TraceHTTPHeader] {
        var headers: [TraceHTTPHeader] = []
        var offset = 0
        var seenHeaderField = false

        while offset < data.count {
            let byte = data[offset]

            if byte & 0x80 != 0 {
                let (index, bytesRead) = try decodeInteger(from: data, offset: offset, prefix: 7)
                let header = try getIndexedHeader(index)
                headers.append(TraceHTTPHeader(key: header.name, value: header.value, indexingPolicy: .incremental))
                offset += bytesRead
                seenHeaderField = true

            } else if byte & 0x40 != 0 {
                let (header, bytesRead) = try decodeLiteralHeader(from: data, offset: offset, prefix: 6, addToTable: true)
                headers.append(TraceHTTPHeader(key: header.name, value: header.value, indexingPolicy: .incremental))
                offset += bytesRead
                seenHeaderField = true

            } else if byte & 0x20 != 0 {
                if seenHeaderField {
                    throw HPACKError.invalidData
                }
                let (newSize, bytesRead) = try decodeInteger(from: data, offset: offset, prefix: 5)
                try updateDynamicTableSize(newSize)
                offset += bytesRead

            } else if byte & 0x10 != 0 {
                let (header, bytesRead) = try decodeLiteralHeader(from: data, offset: offset, prefix: 4, addToTable: false)
                headers.append(TraceHTTPHeader(key: header.name, value: header.value, indexingPolicy: .neverIndexed))
                offset += bytesRead
                seenHeaderField = true

            } else {
                let (header, bytesRead) = try decodeLiteralHeader(from: data, offset: offset, prefix: 4, addToTable: false)
                headers.append(TraceHTTPHeader(key: header.name, value: header.value, indexingPolicy: .withoutIndexing))
                offset += bytesRead
                seenHeaderField = true
            }
        }

        return headers
    }

    /// Decodes a literal header field.
    private func decodeLiteralHeader(from data: Data, offset: Int, prefix: Int, addToTable: Bool) throws -> (HPACKHeader, Int) {
        var currentOffset = offset

        let (index, indexBytes) = try decodeInteger(from: data, offset: currentOffset, prefix: prefix)
        currentOffset += indexBytes

        let name: String
        if index == 0 {
            let (decodedName, nameBytes) = try decodeString(from: data, offset: currentOffset)
            name = decodedName
            currentOffset += nameBytes
        } else {
            let indexedHeader = try getIndexedHeader(index)
            name = indexedHeader.name
        }

        let (value, valueBytes) = try decodeString(from: data, offset: currentOffset)
        currentOffset += valueBytes

        let header = HPACKHeader(name: name, value: value)

        if addToTable {
            addToDynamicTable(header)
        }

        return (header, currentOffset - offset)
    }

    /// Decodes an integer with a prefix.
    private func decodeInteger(from data: Data, offset: Int, prefix: Int) throws -> (Int, Int) {
        guard offset < data.count else {
            throw HPACKError.invalidData
        }

        let mask = UInt64((1 << prefix) - 1)
        var value = UInt64(data[offset] & UInt8(mask))
        var bytesRead = 1

        if value < mask {
            return (Int(value), bytesRead)
        }

        var m = 0
        var currentOffset = offset + 1

        guard currentOffset < data.count else {
            throw HPACKError.invalidData
        }

        var hasContinuation = false
        while currentOffset < data.count {
            let byte = data[currentOffset]
            if m >= 64 {
                throw HPACKError.integerOverflow
            }
            let add = UInt64(byte & 0x7F) << m
            if value > UInt64(Int.max) - add {
                throw HPACKError.integerOverflow
            }
            value += add
            bytesRead += 1
            currentOffset += 1

            hasContinuation = (byte & 0x80) != 0
            if !hasContinuation {
                break
            }

            m += 7
        }

        if hasContinuation {
            throw HPACKError.invalidData
        }

        if value > UInt64(Int.max) {
            throw HPACKError.integerOverflow
        }

        return (Int(value), bytesRead)
    }

    /// Decodes a string with optional Huffman coding.
    private func decodeString(from data: Data, offset: Int) throws -> (String, Int) {
        guard offset < data.count else {
            throw HPACKError.invalidData
        }

        let huffmanEncoded = (data[offset] & 0x80) != 0
        let (length, lengthBytes) = try decodeInteger(from: data, offset: offset, prefix: 7)

        let stringStart = offset + lengthBytes
        let stringEnd = stringStart + length

        guard stringEnd <= data.count else {
            throw HPACKError.invalidData
        }

        let stringData = data[stringStart ..< stringEnd]

        let string: String
        if huffmanEncoded {
            string = try HuffmanDecoder.decode(stringData)
        } else {
            guard let decoded = String(data: stringData, encoding: .utf8) else {
                throw HPACKError.invalidString
            }
            string = decoded
        }

        return (string, lengthBytes + length)
    }

    // MARK: - Encoding

    /// Encodes headers using HPACK.
    public func encode(_ headers: [TraceHTTPHeader]) throws -> Data {
        var data = Data()

        for header in headers {
            let hpackHeader = HPACKHeader(name: header.key.lowercased(), value: header.value)

            switch header.indexingPolicy {
            case .incremental:
                if let index = findExactMatch(hpackHeader) {
                    data.append(contentsOf: encodeInteger(index, prefix: 7, prefixBits: 0x80))
                } else if let index = findNameMatch(hpackHeader.name) {
                    data.append(contentsOf: encodeInteger(index, prefix: 6, prefixBits: 0x40))
                    data.append(contentsOf: encodeString(hpackHeader.value))
                    addToDynamicTable(hpackHeader)
                } else {
                    data.append(0x40) // Literal with incremental indexing
                    data.append(contentsOf: encodeString(hpackHeader.name))
                    data.append(contentsOf: encodeString(hpackHeader.value))
                    addToDynamicTable(hpackHeader)
                }
            case .withoutIndexing:
                data.append(contentsOf: encodeLiteralWithoutIndexing(hpackHeader))
            case .neverIndexed:
                data.append(contentsOf: encodeLiteralNeverIndexed(hpackHeader))
            }
        }

        return data
    }

    /// Encodes an integer with a prefix.
    private func encodeInteger(_ value: Int, prefix: Int, prefixBits: UInt8) -> Data {
        var data = Data()
        let mask = (1 << prefix) - 1

        if value < mask {
            data.append(prefixBits | UInt8(value))
        } else {
            data.append(prefixBits | UInt8(mask))
            var remaining = value - mask

            while remaining >= 128 {
                data.append(UInt8((remaining & 0x7F) | 0x80))
                remaining >>= 7
            }
            data.append(UInt8(remaining))
        }

        return data
    }

    /// Encodes a string with optional Huffman compression.
    /// - Parameters:
    ///   - string: The string to encode.
    ///   - useHuffman: Whether to attempt Huffman encoding (default: true).
    /// - Returns: Encoded string data with a length prefix.
    private func encodeString(_ string: String, useHuffman: Bool = true) -> Data {
        guard let stringData = string.data(using: .utf8) else {
            return Data([0]) // Empty string
        }

        if useHuffman && HuffmanEncoder.shouldEncode(stringData) {
            let huffmanData = HuffmanEncoder.encode(stringData)

            var data = encodeInteger(huffmanData.count, prefix: 7, prefixBits: 0x80)
            data.append(huffmanData)
            return data
        }

        var data = encodeInteger(stringData.count, prefix: 7, prefixBits: 0)
        data.append(stringData)
        return data
    }

    // MARK: - Table Management

    private func getIndexedHeader(_ index: Int) throws -> HPACKHeader {
        if index <= Self.staticTable.count {
            return Self.staticTable[index - 1]
        } else {
            let dynamicIndex = index - Self.staticTable.count - 1
            guard dynamicIndex < dynamicTable.count else {
                throw HPACKError.invalidIndex
            }
            return dynamicTable[dynamicIndex]
        }
    }

    private func findExactMatch(_ header: HPACKHeader) -> Int? {
        if let index = Self.staticTable.firstIndex(where: { $0 == header }) {
            return index + 1
        }

        if let index = dynamicTable.firstIndex(where: { $0 == header }) {
            return Self.staticTable.count + index + 1
        }

        return nil
    }

    private func findNameMatch(_ name: String) -> Int? {
        if let index = Self.staticTable.firstIndex(where: { $0.name == name }) {
            return index + 1
        }

        if let index = dynamicTable.firstIndex(where: { $0.name == name }) {
            return Self.staticTable.count + index + 1
        }

        return nil
    }

    private func addToDynamicTable(_ header: HPACKHeader) {
        let headerSize = header.size

        var evictedEntries: [(name: String, value: String, index: Int)] = []
        while dynamicTableSize + headerSize > maxDynamicTableSize && !dynamicTable.isEmpty {
            if let removed = dynamicTable.popLast() {
                dynamicTableSize -= removed.size
                if recordEvents {
                    let evictedIndex = Self.staticTable.count + dynamicTable.count + 1
                    evictedEntries.append((name: removed.name, value: removed.value, index: evictedIndex))
                }
            }
        }

        if headerSize <= maxDynamicTableSize {
            dynamicTable.insert(header, at: 0)
            dynamicTableSize += headerSize

            if recordEvents {
                for evicted in evictedEntries {
                    recordEvent(.entryEvicted(name: evicted.name, value: evicted.value, index: evicted.index))
                }

                let newIndex = Self.staticTable.count + 1
                recordEvent(.entryAdded(name: header.name, value: header.value, index: newIndex))
            }
        }
    }

    private func encodeLiteralWithoutIndexing(_ header: HPACKHeader) -> Data {
        encodeLiteral(header, prefixBits: 0x00)
    }

    private func encodeLiteralNeverIndexed(_ header: HPACKHeader) -> Data {
        encodeLiteral(header, prefixBits: 0x10)
    }

    private func encodeLiteral(_ header: HPACKHeader, prefixBits: UInt8) -> Data {
        var data = Data()

        if let nameIndex = findNameMatch(header.name) {
            data.append(contentsOf: encodeInteger(nameIndex, prefix: 4, prefixBits: prefixBits))
        } else {
            data.append(contentsOf: encodeInteger(0, prefix: 4, prefixBits: prefixBits))
            data.append(contentsOf: encodeString(header.name))
        }

        data.append(contentsOf: encodeString(header.value))
        return data
    }

    private func updateDynamicTableSize(_ newSize: Int) throws {
        guard newSize >= 0 else {
            throw HPACKError.invalidTableSize
        }
        guard newSize <= maxAllowedDynamicTableSize else {
            throw HPACKError.invalidTableSize
        }

        let oldSize = maxDynamicTableSize
        maxDynamicTableSize = newSize

        while dynamicTableSize > maxDynamicTableSize && !dynamicTable.isEmpty {
            if let removed = dynamicTable.popLast() {
                dynamicTableSize -= removed.size
            }
        }

        if recordEvents && oldSize != newSize {
            recordEvent(.tableSizeUpdated(newSize: newSize))
        }
    }

    /// Apply SETTINGS_HEADER_TABLE_SIZE cap for decoding.
    public func setMaxDynamicTableSize(_ newSize: Int) {
        maxAllowedDynamicTableSize = max(0, newSize)
        if maxDynamicTableSize > maxAllowedDynamicTableSize {
            maxDynamicTableSize = maxAllowedDynamicTableSize
        }

        while dynamicTableSize > maxDynamicTableSize && !dynamicTable.isEmpty {
            if let removed = dynamicTable.popLast() {
                dynamicTableSize -= removed.size
            }
        }
    }

    // MARK: - Table Inspection Methods

    /// Captures the current state of HPACK tables.
    public func captureSnapshot() -> HPACKTableSnapshot {
        let staticEntries = Self.staticTable.enumerated().map { (index: $0.offset + 1, name: $0.element.name, value: $0.element.value) }

        let dynamicEntries = dynamicTable.enumerated().map { (index: Self.staticTable.count + $0.offset + 1, name: $0.element.name, value: $0.element.value, size: $0.element.size) }

        return HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: dynamicEntries,
            currentSize: dynamicTableSize,
            maxSize: maxDynamicTableSize
        )
    }

    /// Records a table event with the current snapshot.
    private func recordEvent(_ eventType: HPACKTableEvent.EventType) {
        guard recordEvents else { return }

        let snapshot = captureSnapshot()
        let event = HPACKTableEvent(type: eventType, timestamp: Date(), tableSnapshot: snapshot)

        tableEvents.append(event)

        if tableEvents.count > maxEventHistory {
            tableEvents.removeFirst(tableEvents.count - maxEventHistory)
        }
    }

    /// Returns all table events.
    public func getTableEvents() -> [HPACKTableEvent] {
        tableEvents
    }

    /// Clears the table event history.
    public func clearEvents() {
        tableEvents.removeAll()
    }
}

// MARK: - HPACK Header

/// Represents an HPACK header field.
public struct HPACKHeader: Equatable, Sendable {
    public let name: String
    public let value: String

    /// Returns the size in octets (RFC 7541 Section 4.1).
    public var size: Int {
        name.utf8.count + value.utf8.count + 32
    }
}

// MARK: - HPACK Table Inspection

// MARK: - Huffman Decoder

public class HuffmanDecoder {
    private struct DecodeNode {
        var left: Int?
        var right: Int?
        var symbol: Int?
    }

    private static let decodeTree: [DecodeNode] = {
        var nodes: [DecodeNode] = [DecodeNode(left: nil, right: nil, symbol: nil)]

        for (sym, entry) in huffSymTable.enumerated() {
            let code = entry.code
            let nbits = Int(entry.nbits)
            var nodeIndex = 0

            for bitIndex in stride(from: nbits - 1, through: 0, by: -1) {
                let bit = (code >> bitIndex) & 1
                if bit == 0 {
                    if nodes[nodeIndex].left == nil {
                        nodes.append(DecodeNode(left: nil, right: nil, symbol: nil))
                        nodes[nodeIndex].left = nodes.count - 1
                    }
                    nodeIndex = nodes[nodeIndex].left ?? 0
                } else {
                    if nodes[nodeIndex].right == nil {
                        nodes.append(DecodeNode(left: nil, right: nil, symbol: nil))
                        nodes[nodeIndex].right = nodes.count - 1
                    }
                    nodeIndex = nodes[nodeIndex].right ?? 0
                }
            }

            nodes[nodeIndex].symbol = sym
        }

        return nodes
    }()

    /// Decodes Huffman-encoded data using RFC 7541 Appendix B.
    ///
    /// This implementation uses the nghttp2 Huffman decoding table which provides
    /// efficient bit-level decoding of HPACK Huffman-encoded strings.
    ///
    /// The decoder processes input nibble-by-nibble (4 bits at a time) using a
    /// finite state automaton (FSA) that walks through the Huffman tree.
    public static func decode(_ data: Data) throws -> String {
        if data.isEmpty {
            return ""
        }

        var result = Data()
        var nodeIndex = 0
        var pendingBits = 0
        var pendingAllOnes = true

        for byte in data {
            for bitIndex in stride(from: 7, through: 0, by: -1) {
                let bit = (byte >> bitIndex) & 1
                pendingBits += 1
                if bit == 0 {
                    pendingAllOnes = false
                }

                let nextIndex: Int? = if bit == 0 {
                    decodeTree[nodeIndex].left
                } else {
                    decodeTree[nodeIndex].right
                }

                guard let index = nextIndex else {
                    throw HPACKError.invalidString
                }

                nodeIndex = index

                if let sym = decodeTree[nodeIndex].symbol {
                    if sym == 256 {
                        throw HPACKError.invalidString
                    }
                    guard sym >= 0, sym <= 255 else {
                        throw HPACKError.invalidString
                    }
                    result.append(UInt8(sym))
                    nodeIndex = 0
                    pendingBits = 0
                    pendingAllOnes = true
                }
            }
        }

        if nodeIndex != 0 {
            if pendingBits > 7 || !pendingAllOnes {
                throw HPACKError.invalidString
            }
        }

        guard let string = String(data: result, encoding: .utf8) else {
            throw HPACKError.invalidString
        }

        return string
    }
}

// MARK: - Errors

/// Defines HPACK decoding and encoding errors.
public enum HPACKError: LocalizedError {
    case invalidData
    case invalidIndex
    case invalidString
    case invalidTableSize
    case integerOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidData: "Invalid HPACK data"
        case .invalidIndex: "Invalid table index"
        case .invalidString: "Invalid string encoding"
        case .invalidTableSize: "Invalid dynamic table size"
        case .integerOverflow: "Integer overflow in HPACK decoding"
        }
    }
}
