//
//  ProtobufSchema.swift
//  TraceCore
//
//  Runtime .proto file parser for field-name resolution.
//  Supports nested messages, oneof blocks, map<K,V> fields,
//  and repeated/optional/required modifiers.
//

import Foundation

// MARK: - ProtobufSchema

public struct ProtobufSchema: Sendable {
    // MARK: - MessageDescriptor

    public final class MessageDescriptor: @unchecked Sendable {
        public let name: String
        /// Map from field number → field name.
        public let fields: [Int: String]
        /// Nested message descriptors, keyed by message name.
        public let nested: [String: MessageDescriptor]

        public init(name: String, fields: [Int: String], nested: [String: MessageDescriptor]) {
            self.name = name
            self.fields = fields
            self.nested = nested
        }

        public func fieldName(number: Int) -> String? {
            fields[number]
        }
    }

    public struct RPCDescriptor: Sendable {
        public let name: String
        public let inputType: String
        public let outputType: String

        public init(name: String, inputType: String, outputType: String) {
            self.name = name
            self.inputType = inputType
            self.outputType = outputType
        }
    }

    public struct ServiceDescriptor: Sendable {
        public let name: String
        public let methods: [String: RPCDescriptor]

        public init(name: String, methods: [String: RPCDescriptor]) {
            self.name = name
            self.methods = methods
        }
    }

    // MARK: - Errors

    public enum ParseError: Error, LocalizedError {
        case emptyInput
        case noMessageFound

        public var errorDescription: String? {
            switch self {
            case .emptyInput: return "Proto text is empty"
            case .noMessageFound: return "No message definition found in proto text"
            }
        }
    }

    // MARK: - Properties

    /// All top-level message descriptors parsed from the .proto text.
    public let messages: [String: MessageDescriptor]
    /// All top-level service descriptors parsed from the .proto text.
    public let services: [String: ServiceDescriptor]

    // MARK: - Parsing

    /// Parse a .proto file text and build a `ProtobufSchema`.
    public static func parse(protoText: String) throws -> ProtobufSchema {
        guard !protoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.emptyInput
        }
        let tokens = tokenize(protoText)
        var index = 0
        var messages: [String: MessageDescriptor] = [:]
        var services: [String: ServiceDescriptor] = [:]
        while index < tokens.count {
            if tokens[index] == "message" {
                if let (descriptor, nextIndex) = parseMessage(tokens: tokens, from: index) {
                    messages[descriptor.name] = descriptor
                    index = nextIndex
                } else {
                    index += 1
                }
            } else if tokens[index] == "service" {
                if let (descriptor, nextIndex) = parseService(tokens: tokens, from: index) {
                    services[descriptor.name] = descriptor
                    index = nextIndex
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        if messages.isEmpty {
            throw ParseError.noMessageFound
        }
        return ProtobufSchema(messages: messages, services: services)
    }

    // MARK: - Private Parsing

    /// Tokenize proto text: splits on whitespace, braces, semicolons, angle brackets, equals, commas.
    private static func tokenize(_ text: String) -> [String] {
        // Remove line comments
        let withoutComments = text
            .components(separatedBy: "\n")
            .map { line -> String in
                if let commentRange = line.range(of: "//") {
                    return String(line[line.startIndex ..< commentRange.lowerBound])
                }
                return line
            }
            .joined(separator: "\n")

        // Replace delimiters with spaced versions
        let normalized = withoutComments
            .replacingOccurrences(of: "{", with: " { ")
            .replacingOccurrences(of: "}", with: " } ")
            .replacingOccurrences(of: ";", with: " ; ")
            .replacingOccurrences(of: "=", with: " = ")
            .replacingOccurrences(of: "<", with: " < ")
            .replacingOccurrences(of: ">", with: " > ")
            .replacingOccurrences(of: ",", with: " , ")
            .replacingOccurrences(of: "(", with: " ( ")
            .replacingOccurrences(of: ")", with: " ) ")

        return normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    /// Parse a single `message Name { ... }` block.
    /// Returns the descriptor and the index just past the closing `}`.
    private static func parseMessage(tokens: [String], from start: Int) -> (MessageDescriptor, Int)? {
        var index = start
        guard index < tokens.count, tokens[index] == "message" else { return nil }
        index += 1
        guard index < tokens.count else { return nil }
        let messageName = tokens[index]
        index += 1
        guard index < tokens.count, tokens[index] == "{" else { return nil }
        index += 1

        var fields: [Int: String] = [:]
        var nested: [String: MessageDescriptor] = [:]
        var depth = 1

        while index < tokens.count, depth > 0 {
            let token = tokens[index]

            if token == "{" {
                depth += 1
                index += 1
                continue
            }

            if token == "}" {
                depth -= 1
                index += 1
                if depth == 0 { break }
                continue
            }

            // Nested message
            if token == "message" {
                if let (nestedDesc, nextIndex) = parseMessage(tokens: tokens, from: index) {
                    nested[nestedDesc.name] = nestedDesc
                    index = nextIndex
                } else {
                    index += 1
                }
                continue
            }

            // oneof block — parse fields inside as regular fields
            if token == "oneof" {
                index += 1 // skip oneof name
                index += 1 // expect "{"
                // fields inside are parsed normally by continuing the outer loop
                continue
            }

            // enum block — skip
            if token == "enum" {
                var skipDepth = 0
                index += 1 // name
                index += 1 // "{"
                skipDepth = 1
                while index < tokens.count, skipDepth > 0 {
                    if tokens[index] == "{" { skipDepth += 1 }
                    if tokens[index] == "}" { skipDepth -= 1 }
                    index += 1
                }
                continue
            }

            // map<K,V> field: map < KeyType , ValueType > fieldName = fieldNumber ;
            if token == "map" {
                // skip "<", KeyType, ",", ValueType, ">"
                // then: fieldName = fieldNumber ;
                index += 1 // <
                index += 1 // KeyType
                index += 1 // ,
                index += 1 // ValueType
                index += 1 // >
                if index < tokens.count {
                    let mapFieldName = tokens[index]; index += 1
                    if index < tokens.count, tokens[index] == "=" { index += 1 }
                    if index < tokens.count, let num = Int(tokens[index]) {
                        fields[num] = mapFieldName
                        index += 1
                    }
                    if index < tokens.count, tokens[index] == ";" { index += 1 }
                }
                continue
            }

            // Skip option, reserved, import, syntax, package, extend
            if ["option", "reserved", "import", "syntax", "package", "extend"].contains(token) {
                while index < tokens.count, tokens[index] != ";" && tokens[index] != "}" {
                    index += 1
                }
                if index < tokens.count, tokens[index] == ";" { index += 1 }
                continue
            }

            // Regular field: [label] type fieldName = fieldNumber [options] ;
            // Labels: optional, required, repeated, or nothing (proto3 implicit)
            let possibleLabel = ["optional", "required", "repeated"].contains(token) ? token : nil
            var typeIndex = index
            if possibleLabel != nil {
                typeIndex = index + 1 // skip label
            }
            if typeIndex + 3 < tokens.count { // type fieldName = num
                let typeToken = tokens[typeIndex]
                // Skip if it looks like a keyword we don't handle
                let knownKeywords: Set<String> = ["message", "enum", "oneof", "map", "option",
                                                   "reserved", "import", "syntax", "package",
                                                   "extend", "service", "rpc", "returns", "stream"]
                guard !knownKeywords.contains(typeToken) else {
                    // Skip to semicolon
                    while index < tokens.count, tokens[index] != ";" && tokens[index] != "}" {
                        index += 1
                    }
                    if index < tokens.count, tokens[index] == ";" { index += 1 }
                    continue
                }

                let fieldNameIndex = typeIndex + 1
                let eqIndex = typeIndex + 2
                let numIndex = typeIndex + 3

                if numIndex < tokens.count,
                   tokens[eqIndex] == "=",
                   let fieldNumber = Int(tokens[numIndex]),
                   fieldNumber >= 1 {
                    let fieldName = tokens[fieldNameIndex]
                    fields[fieldNumber] = fieldName
                    index = numIndex + 1
                    // Skip optional [options] and ;
                    while index < tokens.count, tokens[index] != ";" && tokens[index] != "}" {
                        index += 1
                    }
                    if index < tokens.count, tokens[index] == ";" { index += 1 }
                    continue
                }
            }

            // Couldn't parse this token — skip to next semicolon or brace
            while index < tokens.count, tokens[index] != ";" && tokens[index] != "}" && tokens[index] != "{" {
                index += 1
            }
            if index < tokens.count, tokens[index] == ";" { index += 1 }
        }

        let descriptor = MessageDescriptor(name: messageName, fields: fields, nested: nested)
        return (descriptor, index)
    }

    private static func parseService(tokens: [String], from start: Int) -> (ServiceDescriptor, Int)? {
        var index = start
        guard index < tokens.count, tokens[index] == "service" else { return nil }
        index += 1
        guard index < tokens.count else { return nil }
        let serviceName = tokens[index]
        index += 1
        guard index < tokens.count, tokens[index] == "{" else { return nil }
        index += 1

        var methods: [String: RPCDescriptor] = [:]
        var depth = 1

        while index < tokens.count, depth > 0 {
            let token = tokens[index]

            if token == "{" {
                depth += 1
                index += 1
                continue
            }

            if token == "}" {
                depth -= 1
                index += 1
                if depth == 0 { break }
                continue
            }

            if depth == 1, token == "rpc" {
                if let (rpc, nextIndex) = parseRPC(tokens: tokens, from: index) {
                    methods[rpc.name] = rpc
                    index = nextIndex
                } else {
                    index += 1
                }
                continue
            }

            index += 1
        }

        return (ServiceDescriptor(name: serviceName, methods: methods), index)
    }

    private static func parseRPC(tokens: [String], from start: Int) -> (RPCDescriptor, Int)? {
        var index = start
        guard index < tokens.count, tokens[index] == "rpc" else { return nil }
        index += 1
        guard index < tokens.count else { return nil }
        let methodName = tokens[index]
        index += 1

        guard index < tokens.count, tokens[index] == "(" else { return nil }
        index += 1
        if index < tokens.count, tokens[index] == "stream" {
            index += 1
        }
        guard index < tokens.count else { return nil }
        let inputType = tokens[index]
        index += 1

        guard index < tokens.count, tokens[index] == ")" else { return nil }
        index += 1
        guard index < tokens.count, tokens[index] == "returns" else { return nil }
        index += 1
        guard index < tokens.count, tokens[index] == "(" else { return nil }
        index += 1
        if index < tokens.count, tokens[index] == "stream" {
            index += 1
        }
        guard index < tokens.count else { return nil }
        let outputType = tokens[index]
        index += 1

        guard index < tokens.count, tokens[index] == ")" else { return nil }
        index += 1

        if index < tokens.count, tokens[index] == "{" {
            var depth = 1
            index += 1
            while index < tokens.count, depth > 0 {
                if tokens[index] == "{" { depth += 1 }
                if tokens[index] == "}" { depth -= 1 }
                index += 1
            }
        } else {
            while index < tokens.count, tokens[index] != ";" && tokens[index] != "}" {
                index += 1
            }
            if index < tokens.count, tokens[index] == ";" {
                index += 1
            }
        }

        return (RPCDescriptor(name: methodName, inputType: inputType, outputType: outputType), index)
    }
}

extension ProtobufSchema {
    /// Convenience: look up the first top-level message descriptor by name.
    public func descriptor(named name: String) -> MessageDescriptor? {
        messages[name]
    }

    public func descriptor(forTypeReference typeReference: String) -> MessageDescriptor? {
        let normalized = normalizeQualifiedName(typeReference)
        if let descriptor = messages[normalized] {
            return descriptor
        }
        if let shortName = normalized.split(separator: ".").last.map(String.init),
           let descriptor = messages[shortName]
        {
            return descriptor
        }

        let matches = messages.compactMap { name, descriptor -> MessageDescriptor? in
            let candidate = normalizeQualifiedName(name)
            return normalized == candidate || normalized.hasSuffix(".\(candidate)") ? descriptor : nil
        }
        return matches.count == 1 ? matches.first : nil
    }

    public func rpcDescriptor(forMethodPath methodPath: String) -> RPCDescriptor? {
        let trimmedPath = methodPath
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? methodPath
        let components = trimmedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 2 else { return nil }

        let serviceName = components[components.count - 2]
        let methodName = components[components.count - 1]
        guard let service = serviceDescriptor(matching: serviceName) else { return nil }
        return service.methods[methodName]
    }

    /// Convenience: return the first message descriptor if only one exists.
    public var firstMessage: MessageDescriptor? {
        messages.count == 1 ? messages.values.first : nil
    }

    private func serviceDescriptor(matching serviceName: String) -> ServiceDescriptor? {
        let normalized = normalizeQualifiedName(serviceName)
        if let descriptor = services[normalized] {
            return descriptor
        }
        if let shortName = normalized.split(separator: ".").last.map(String.init),
           let descriptor = services[shortName]
        {
            return descriptor
        }

        let matches = services.compactMap { name, descriptor -> ServiceDescriptor? in
            let candidate = normalizeQualifiedName(name)
            return normalized == candidate || normalized.hasSuffix(".\(candidate)") ? descriptor : nil
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func normalizeQualifiedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }
}
