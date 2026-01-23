//
//  HPACKTypes.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Snapshot of HPACK table state at a point in time.
/// Mirrored from TraceVPN/HPACKEncoder.swift for decoding UI data in the app target.
public struct HPACKTableSnapshot: Codable {
    public let staticEntries: [(index: Int, name: String, value: String)]
    public let dynamicEntries: [(index: Int, name: String, value: String, size: Int)]
    public let currentSize: Int
    public let maxSize: Int
    public let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case staticEntries, dynamicEntries, currentSize, maxSize, timestamp
    }

    public init(
        staticEntries: [(index: Int, name: String, value: String)],
        dynamicEntries: [(index: Int, name: String, value: String, size: Int)],
        currentSize: Int,
        maxSize: Int,
        timestamp: Date = Date()
    ) {
        self.staticEntries = staticEntries
        self.dynamicEntries = dynamicEntries
        self.currentSize = currentSize
        self.maxSize = maxSize
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let staticData = try? container.decode([[AnyCodable]].self, forKey: .staticEntries) {
            var staticResult: [(index: Int, name: String, value: String)] = []
            staticResult.reserveCapacity(staticData.count)
            for (offset, entry) in staticData.enumerated() {
                if entry.count >= 3,
                   let idx = entry[0].value as? Int,
                   let name = entry[1].value as? String,
                   let value = entry[2].value as? String {
                    staticResult.append((index: idx, name: name, value: value))
                } else if entry.count >= 2,
                          let name = entry[0].value as? String,
                          let value = entry[1].value as? String {
                    staticResult.append((index: offset, name: name, value: value))
                }
            }
            staticEntries = staticResult
        } else {
            let staticData: [[String]] = try container.decode([[String]].self, forKey: .staticEntries)
            var staticResult: [(index: Int, name: String, value: String)] = []
            staticResult.reserveCapacity(staticData.count)
            for (offset, element) in staticData.enumerated() {
                staticResult.append((index: offset, name: element[0], value: element[1]))
            }
            staticEntries = staticResult
        }

        let dynamicData: [[AnyCodable]] = try container.decode([[AnyCodable]].self, forKey: .dynamicEntries)
        var dynamicResult: [(index: Int, name: String, value: String, size: Int)] = []
        dynamicResult.reserveCapacity(dynamicData.count)
        for entry in dynamicData {
            guard let idx = entry[0].value as? Int,
                  let name = entry[1].value as? String,
                  let value = entry[2].value as? String,
                  let size = entry[3].value as? Int else {
                throw DecodingError.dataCorruptedError(
                    forKey: .dynamicEntries,
                    in: container,
                    debugDescription: "Invalid dynamic entry format"
                )
            }
            dynamicResult.append((index: idx, name: name, value: value, size: size))
        }
        dynamicEntries = dynamicResult

        currentSize = try container.decode(Int.self, forKey: .currentSize)
        maxSize = try container.decode(Int.self, forKey: .maxSize)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        var staticData: [AnyCodableArray] = []
        staticData.reserveCapacity(staticEntries.count)
        for entry in staticEntries {
            let arr: [Any] = [entry.index, entry.name, entry.value]
            staticData.append(AnyCodableArray(arr))
        }
        try container.encode(staticData, forKey: .staticEntries)

        var dynamicData: [AnyCodableArray] = []
        dynamicData.reserveCapacity(dynamicEntries.count)
        for entry in dynamicEntries {
            let arr: [Any] = [entry.index, entry.name, entry.value, entry.size]
            dynamicData.append(AnyCodableArray(arr))
        }
        try container.encode(dynamicData, forKey: .dynamicEntries)

        try container.encode(currentSize, forKey: .currentSize)
        try container.encode(maxSize, forKey: .maxSize)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

/// Event that occurred on the HPACK table.
public struct HPACKTableEvent: Codable {
    public enum EventType: Codable {
        case entryAdded(name: String, value: String, index: Int)
        case entryEvicted(name: String, value: String, index: Int)
        case tableSizeUpdated(newSize: Int)

        private enum CodingKeys: String, CodingKey {
            case type, name, value, index, newSize
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type: String = try container.decode(String.self, forKey: .type)

            switch type {
            case "added":
                let name: String = try container.decode(String.self, forKey: .name)
                let value: String = try container.decode(String.self, forKey: .value)
                let index: Int = try container.decode(Int.self, forKey: .index)
                self = .entryAdded(name: name, value: value, index: index)
            case "evicted":
                let name: String = try container.decode(String.self, forKey: .name)
                let value: String = try container.decode(String.self, forKey: .value)
                let index: Int = try container.decode(Int.self, forKey: .index)
                self = .entryEvicted(name: name, value: value, index: index)
            case "sizeUpdated":
                let newSize: Int = try container.decode(Int.self, forKey: .newSize)
                self = .tableSizeUpdated(newSize: newSize)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown event type"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .entryAdded(name, value, index):
                try container.encode("added", forKey: .type)
                try container.encode(name, forKey: .name)
                try container.encode(value, forKey: .value)
                try container.encode(index, forKey: .index)
            case let .entryEvicted(name, value, index):
                try container.encode("evicted", forKey: .type)
                try container.encode(name, forKey: .name)
                try container.encode(value, forKey: .value)
                try container.encode(index, forKey: .index)
            case let .tableSizeUpdated(newSize):
                try container.encode("sizeUpdated", forKey: .type)
                try container.encode(newSize, forKey: .newSize)
            }
        }
    }

    public let type: EventType
    public let timestamp: Date
    public let tableSnapshot: HPACKTableSnapshot

    public init(type: EventType, timestamp: Date = Date(), tableSnapshot: HPACKTableSnapshot) {
        self.type = type
        self.timestamp = timestamp
        self.tableSnapshot = tableSnapshot
    }
}

private struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let stringValue = value as? String {
            try container.encode(stringValue)
        }
    }
}

private struct AnyCodableArray: Codable {
    let values: [Any]

    init(_ values: [Any]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var vals: [Any] = []

        while !container.isAtEnd {
            if let intValue = try? container.decode(Int.self) {
                vals.append(intValue)
            } else if let stringValue = try? container.decode(String.self) {
                vals.append(stringValue)
            }
        }

        values = vals
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()

        for value in values {
            if let intValue = value as? Int {
                try container.encode(intValue)
            } else if let stringValue = value as? String {
                try container.encode(stringValue)
            }
        }
    }
}
