//
//  JSONPathEvaluator.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct JSONPathEvaluator {
    public init() {}

    public func get(json: Data, path: String) -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: json, options: []) else { return nil }
        let segments = parse(path: path)
        return value(at: segments, in: object)
    }

    public func set(json: Data, path: String, value: Any) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: json, options: [])
        let segments = parse(path: path)
        let updated = try setValue(at: segments, in: object, newValue: value)
        return try JSONSerialization.data(withJSONObject: updated, options: [])
    }

    public func delete(json: Data, path: String) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: json, options: [])
        let segments = parse(path: path)
        let updated = try deleteValue(at: segments, in: object)
        return try JSONSerialization.data(withJSONObject: updated, options: [])
    }

    private enum Segment {
        case key(String)
        case index(Int)
    }

    private func parse(path: String) -> [Segment] {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") {
            trimmed.removeFirst()
        }
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }

        var segments: [Segment] = []
        var current = ""
        var inBracket = false
        var bracketContent = ""

        for char in trimmed {
            if char == "." && !inBracket {
                if !current.isEmpty {
                    segments.append(.key(current))
                    current = ""
                }
                continue
            }
            if char == "[" {
                inBracket = true
                if !current.isEmpty {
                    segments.append(.key(current))
                    current = ""
                }
                continue
            }
            if char == "]" {
                inBracket = false
                let cleaned = bracketContent.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let index = Int(cleaned) {
                    segments.append(.index(index))
                } else if !cleaned.isEmpty {
                    segments.append(.key(cleaned))
                }
                bracketContent = ""
                continue
            }

            if inBracket {
                bracketContent.append(char)
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            segments.append(.key(current))
        }
        return segments
    }

    private func value(at segments: [Segment], in object: Any) -> Any? {
        guard !segments.isEmpty else { return object }
        var current: Any? = object
        for segment in segments {
            switch segment {
            case let .key(key):
                if let dict = current as? [String: Any] {
                    current = dict[key]
                } else {
                    return nil
                }
            case let .index(index):
                if let array = current as? [Any], array.indices.contains(index) {
                    current = array[index]
                } else {
                    return nil
                }
            }
        }
        return current
    }

    private func setValue(at segments: [Segment], in object: Any, newValue: Any) throws -> Any {
        guard let first = segments.first else { return newValue }
        var remaining = segments
        remaining.removeFirst()

        switch first {
        case let .key(key):
            var dict = (object as? [String: Any]) ?? [:]
            let current = dict[key]
            dict[key] = remaining.isEmpty ? newValue : try setValue(at: remaining, in: current ?? [:], newValue: newValue)
            return dict
        case let .index(index):
            var array = (object as? [Any]) ?? []
            if array.indices.contains(index) {
                array[index] = remaining.isEmpty ? newValue : try setValue(at: remaining, in: array[index], newValue: newValue)
            } else if index == array.count {
                try array.append(remaining.isEmpty ? newValue : setValue(at: remaining, in: [:], newValue: newValue))
            }
            return array
        }
    }

    private func deleteValue(at segments: [Segment], in object: Any) throws -> Any {
        guard let first = segments.first else { return object }
        var remaining = segments
        remaining.removeFirst()

        switch first {
        case let .key(key):
            var dict = (object as? [String: Any]) ?? [:]
            if remaining.isEmpty {
                dict.removeValue(forKey: key)
            } else {
                if let current = dict[key] {
                    dict[key] = try deleteValue(at: remaining, in: current)
                }
            }
            return dict
        case let .index(index):
            var array = (object as? [Any]) ?? []
            if array.indices.contains(index) {
                if remaining.isEmpty {
                    array.remove(at: index)
                } else {
                    array[index] = try deleteValue(at: remaining, in: array[index])
                }
            }
            return array
        }
    }
}
