//
//  CurlParser.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Parser for cURL commands
public class CurlParser {
    public enum ParseError: LocalizedError, Equatable {
        case invalidCommand
        case missingURL
        case invalidURL
        case unsupportedOption(String)
        case invalidConfigFile(String)
        case invalidVariable(String)

        public var errorDescription: String? {
            switch self {
            case .invalidCommand:
                "Invalid cURL command format"
            case .missingURL:
                "Missing URL in cURL command"
            case .invalidURL:
                "Invalid URL format"
            case let .unsupportedOption(option):
                "Unsupported cURL option: \(option)"
            case let .invalidConfigFile(reason):
                "Invalid config file: \(reason)"
            case let .invalidVariable(reason):
                "Invalid variable: \(reason)"
            }
        }
    }

    private struct DataPart {
        enum Kind {
            case data
            case dataAscii
            case dataBinary
            case dataRaw
            case dataUrlEncode
        }

        let kind: Kind
        let value: String
        let isFileReference: Bool
    }

    private struct FormPart {
        let name: String
        let value: String?
        let filePath: String?
        let filename: String?
        let contentType: String?
        let encoder: String?
        let isFile: Bool
    }

    private struct TransferState {
        var method: HTTPMethod = .get
        var methodExplicit: Bool = false
        var headers: [TraceHTTPHeader] = []
        var dataParts: [DataPart] = []
        var formParts: [FormPart] = []
        var uploadFile: String?
        var urls: [String] = []
        var useGet: Bool = false
        var head: Bool = false
        var globOff: Bool = false
        var protocolVersion: HTTPProtocolVersion?
        var followRedirects: Bool = false
        var insecure: Bool = false
        var options: [String: [String]] = [:]

        mutating func addOption(_ name: String, value: String?) {
            if let value {
                options[name, default: []].append(value)
            } else {
                options[name, default: []].append("true")
            }
        }
    }

    private struct TokenStream {
        var tokens: [String]
        var index: Int = 0

        mutating func next() -> String? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            return token
        }

        mutating func peek() -> String? {
            guard index < tokens.count else { return nil }
            return tokens[index]
        }

        mutating func insert(_ newTokens: [String]) {
            guard !newTokens.isEmpty else { return }
            tokens.insert(contentsOf: newTokens, at: index)
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// Parse a cURL command string into a NetworkRequest
    public static func parse(_ curlCommand: String) throws -> NetworkRequest {
        let requests = try parseAll(curlCommand)
        guard let first = requests.first else {
            throw ParseError.missingURL
        }
        if requests.count > 1 {
            FeatureLog.export.debug("event=export.curl_parse outcome=warning reason=multiple_urls count=\(requests.count)")
        }
        return first
    }

    /// Parse a cURL command string into one or more NetworkRequests
    public static func parseAll(_ curlCommand: String) throws -> [NetworkRequest] {
        // Clean up the command
        var command = curlCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw ParseError.missingURL
        }

        // Remove leading "curl" if present
        if command.lowercased().hasPrefix("curl ") {
            command.removeFirst(5)
        } else if command.lowercased() == "curl" {
            throw ParseError.missingURL
        }

        var tokens = tokenize(command)
        if tokens.isEmpty {
            throw ParseError.missingURL
        }

        var stream = TokenStream(tokens: tokens)
        var variables: [String: String] = [:]
        var transfers: [TransferState] = [TransferState()]
        var endOfOptions = false

        while let token = stream.next() {
            if !endOfOptions, token == "--" {
                endOfOptions = true
                continue
            }

            if !endOfOptions, token == "--next" {
                if !transfers.last!.urls.isEmpty || !transfers.last!.dataParts.isEmpty || !transfers.last!.formParts.isEmpty || transfers.last!.uploadFile != nil {
                    transfers.append(TransferState())
                }
                continue
            }

            if !endOfOptions, token.hasPrefix("--") {
                handleLongOption(token, stream: &stream, transfers: &transfers, variables: &variables)
                continue
            }

            if !endOfOptions, token.hasPrefix("-") && token != "-" {
                if handleShortOption(token, stream: &stream, transfers: &transfers, variables: &variables) {
                    continue
                }
            }

            // URL or literal argument
            transfers[transfers.count - 1].urls.append(token)
        }

        var results: [NetworkRequest] = []
        for transfer in transfers {
            let built = try buildRequests(from: transfer)
            results.append(contentsOf: built)
        }

        if results.isEmpty {
            throw ParseError.missingURL
        }

        return results
    }

    // swiftlint:enable cyclomatic_complexity

    // MARK: - Tokenization

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var currentToken = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var escaped = false
        var justClosedQuote = false
        let chars = Array(command)
        var index = 0

        func appendTokenIfNeeded() {
            if justClosedQuote && currentToken.isEmpty {
                tokens.append("")
                justClosedQuote = false
            }
            if !currentToken.isEmpty {
                tokens.append(currentToken)
                currentToken = ""
            }
        }

        while index < chars.count {
            let char = chars[index]

            if escaped {
                currentToken.append(char)
                escaped = false
                index += 1
                continue
            }

            if char == "\\" {
                if inSingleQuotes {
                    currentToken.append(char)
                    index += 1
                    continue
                }
                if index + 1 < chars.count {
                    let next = chars[index + 1]
                    if next == "\n" || next == "\r" {
                        // Line continuation
                        index += 2
                        if next == "\r", index < chars.count, chars[index] == "\n" {
                            index += 1
                        }
                        continue
                    }
                }
                escaped = true
                index += 1
                continue
            }

            if char == "'" && !inDoubleQuotes {
                if inSingleQuotes {
                    inSingleQuotes = false
                    justClosedQuote = true
                } else {
                    inSingleQuotes = true
                    justClosedQuote = false
                }
                index += 1
                continue
            }

            if char == "\"" && !inSingleQuotes {
                if inDoubleQuotes {
                    inDoubleQuotes = false
                    justClosedQuote = true
                } else {
                    inDoubleQuotes = true
                    justClosedQuote = false
                }
                index += 1
                continue
            }

            if char.isWhitespace && !inSingleQuotes && !inDoubleQuotes {
                appendTokenIfNeeded()
                index += 1
                continue
            }

            if justClosedQuote {
                justClosedQuote = false
            }

            currentToken.append(char)
            index += 1
        }

        if justClosedQuote && currentToken.isEmpty {
            tokens.append("")
        }

        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }

        return tokens
    }

    // MARK: - Option Handling

    private static func handleLongOption(
        _ token: String,
        stream: inout TokenStream,
        transfers: inout [TransferState],
        variables: inout [String: String]
    ) {
        var optionToken = token
        var inlineValue: String?

        if let equalsIndex = optionToken.firstIndex(of: "=") {
            inlineValue = String(optionToken[optionToken.index(after: equalsIndex)...])
            optionToken = String(optionToken[..<equalsIndex])
        }

        if optionToken.hasPrefix("--expand-") {
            let expandedOption = "--" + optionToken.dropFirst("--expand-".count)
            let value = inlineValue ?? stream.next()
            let expandedValue = value.map { expandVariables(in: $0, variables: variables) }
            applyOption(String(expandedOption), value: expandedValue, transfers: &transfers, variables: &variables, stream: &stream)
            return
        }

        applyOption(optionToken, value: inlineValue, transfers: &transfers, variables: &variables, stream: &stream)
    }

    private static func handleShortOption(
        _ token: String,
        stream: inout TokenStream,
        transfers: inout [TransferState],
        variables: inout [String: String]
    ) -> Bool {
        if CurlOptionRegistry.isKnown(token) {
            applyOption(token, value: nil, transfers: &transfers, variables: &variables, stream: &stream)
            return true
        }

        guard token.count > 2 else { return false }

        let chars = Array(token.dropFirst())
        var index = 0
        while index < chars.count {
            let opt = "-" + String(chars[index])
            if CurlOptionRegistry.requiresValue(opt) || CurlOptionRegistry.hasOptionalValue(opt) {
                let value: String? = if index + 1 < chars.count {
                    String(chars[(index + 1)...])
                } else {
                    stream.next()
                }
                applyOption(opt, value: value, transfers: &transfers, variables: &variables, stream: &stream)
                return true
            } else {
                applyOption(opt, value: nil, transfers: &transfers, variables: &variables, stream: &stream)
            }
            index += 1
        }
        return true
    }

    private static func applyOption(
        _ optionToken: String,
        value: String?,
        transfers: inout [TransferState],
        variables: inout [String: String],
        stream: inout TokenStream
    ) {
        var option = optionToken
        var inlineValue = value
        var negated = false

        if option.hasPrefix("--no-") {
            let base = "--" + option.dropFirst(5)
            if CurlOptionRegistry.isKnown(String(base)) {
                option = String(base)
                negated = true
            }
        }

        let requiresValue = CurlOptionRegistry.requiresValue(option)
        let optionalValue = CurlOptionRegistry.hasOptionalValue(option)

        if requiresValue, inlineValue == nil {
            inlineValue = stream.next()
            if inlineValue == "=", let nextValue = stream.next() {
                inlineValue = nextValue
            }
        } else if optionalValue, inlineValue == nil {
            // Do not consume the next token for optional values
        }

        if option == "--config" || option == "-K" {
            if let file = inlineValue {
                if let configTokens = try? parseConfigFileTokens(from: file) {
                    stream.insert(configTokens)
                } else {
                    FeatureLog.export.debug("event=export.curl_parse outcome=warning reason=config_read_failed file=\(file)")
                }
            }
            return
        }

        if option == "--variable" {
            if let inlineValue {
                applyVariable(inlineValue, variables: &variables)
            }
            return
        }

        if option == "--url" {
            if let inlineValue {
                transfers[transfers.count - 1].urls.append(inlineValue)
            }
            return
        }

        // Track option usage for completeness
        transfers[transfers.count - 1].addOption(option, value: inlineValue)

        switch option {
        case "-X", "--request":
            if let inlineValue {
                let method = HTTPMethod(rawValue: inlineValue.uppercased()) ?? .get
                transfers[transfers.count - 1].method = method
                transfers[transfers.count - 1].methodExplicit = true
            }

        case "-I", "--head":
            transfers[transfers.count - 1].method = .head
            transfers[transfers.count - 1].methodExplicit = true
            transfers[transfers.count - 1].head = true

        case "-G", "--get":
            transfers[transfers.count - 1].useGet = !negated

        case "-g", "--globoff":
            transfers[transfers.count - 1].globOff = !negated

        case "-H", "--header":
            if let inlineValue {
                appendHeader(from: inlineValue, headers: &transfers[transfers.count - 1].headers)
            }

        case "-d", "--data", "--data-ascii":
            if let inlineValue {
                transfers[transfers.count - 1].dataParts.append(readDataPart(value: inlineValue, kind: .data))
                applyImplicitPost(for: &transfers[transfers.count - 1])
            }

        case "--data-binary":
            if let inlineValue {
                transfers[transfers.count - 1].dataParts.append(readDataPart(value: inlineValue, kind: .dataBinary))
                applyImplicitPost(for: &transfers[transfers.count - 1])
            }

        case "--data-raw":
            if let inlineValue {
                transfers[transfers.count - 1].dataParts.append(DataPart(kind: .dataRaw, value: inlineValue, isFileReference: false))
                applyImplicitPost(for: &transfers[transfers.count - 1])
            }

        case "--data-urlencode":
            if let inlineValue {
                transfers[transfers.count - 1].dataParts.append(readDataPart(value: inlineValue, kind: .dataUrlEncode))
                applyImplicitPost(for: &transfers[transfers.count - 1])
            }

        case "-F", "--form":
            if let inlineValue {
                if let formPart = parseFormPart(inlineValue, allowFileReference: true) {
                    transfers[transfers.count - 1].formParts.append(formPart)
                    applyImplicitPost(for: &transfers[transfers.count - 1])
                }
            }

        case "--form-string":
            if let inlineValue {
                if let formPart = parseFormPart(inlineValue, allowFileReference: false) {
                    transfers[transfers.count - 1].formParts.append(formPart)
                    applyImplicitPost(for: &transfers[transfers.count - 1])
                }
            }

        case "-T", "--upload-file":
            if let inlineValue {
                transfers[transfers.count - 1].uploadFile = inlineValue
                if !transfers[transfers.count - 1].methodExplicit {
                    transfers[transfers.count - 1].method = .put
                }
            }

        case "-u", "--user":
            if let inlineValue {
                let authHeader = basicAuthHeader(inlineValue)
                transfers[transfers.count - 1].headers.append(authHeader)
            }

        case "-A", "--user-agent":
            if let inlineValue {
                transfers[transfers.count - 1].headers.append(TraceHTTPHeader(key: "User-Agent", value: inlineValue))
            }

        case "-e", "--referer":
            if let inlineValue {
                transfers[transfers.count - 1].headers.append(TraceHTTPHeader(key: "Referer", value: inlineValue))
            }

        case "-b", "--cookie":
            if let inlineValue {
                appendCookie(from: inlineValue, headers: &transfers[transfers.count - 1].headers)
            }

        case "--compressed":
            if !negated {
                transfers[transfers.count - 1].headers.append(TraceHTTPHeader(key: "Accept-Encoding", value: "gzip, deflate, br"))
            }

        case "-L", "--location":
            transfers[transfers.count - 1].followRedirects = !negated

        case "-k", "--insecure":
            transfers[transfers.count - 1].insecure = !negated

        case "--http1.0", "-0":
            transfers[transfers.count - 1].protocolVersion = .http10

        case "--http1.1":
            transfers[transfers.count - 1].protocolVersion = .http11

        case "--http2", "--http2-prior-knowledge":
            transfers[transfers.count - 1].protocolVersion = .http2

        case "--http3":
            transfers[transfers.count - 1].protocolVersion = .http3

        default:
            break
        }
    }

    private static func applyImplicitPost(for transfer: inout TransferState) {
        if !transfer.methodExplicit, transfer.method == .get {
            transfer.method = .post
        }
    }

    // MARK: - Helpers

    private static func parseHeader(_ headerString: String) -> TraceHTTPHeader {
        let parts = headerString.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return TraceHTTPHeader(key: key, value: value)
    }

    private static func appendHeader(from value: String, headers: inout [TraceHTTPHeader]) {
        if value.hasPrefix("@") {
            let filePath = String(value.dropFirst())
            if let fileData = try? String(contentsOfFile: filePath, encoding: .utf8) {
                let lines = fileData.components(separatedBy: .newlines)
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    headers.append(parseHeader(line))
                }
            } else {
                headers.append(parseHeader(value))
            }
            return
        }
        headers.append(parseHeader(value))
    }

    private static func appendCookie(from value: String, headers: inout [TraceHTTPHeader]) {
        if value.hasPrefix("@") {
            let filePath = String(value.dropFirst())
            if let fileData = try? String(contentsOfFile: filePath, encoding: .utf8) {
                let cookieHeader = parseCookieFile(fileData)
                if !cookieHeader.isEmpty {
                    headers.append(TraceHTTPHeader(key: "Cookie", value: cookieHeader))
                    return
                }
            }
        }

        if FileManager.default.fileExists(atPath: value), let fileData = try? String(contentsOfFile: value, encoding: .utf8) {
            let cookieHeader = parseCookieFile(fileData)
            if !cookieHeader.isEmpty {
                headers.append(TraceHTTPHeader(key: "Cookie", value: cookieHeader))
                return
            }
        }

        headers.append(TraceHTTPHeader(key: "Cookie", value: value))
    }

    private static func parseCookieFile(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var cookies: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let parts = trimmed.components(separatedBy: "\t")
            if parts.count >= 7 {
                let name = parts[5]
                let value = parts[6]
                cookies.append("\(name)=\(value)")
            }
        }
        return cookies.joined(separator: "; ")
    }

    private static func basicAuthHeader(_ auth: String) -> TraceHTTPHeader {
        let credentials = auth.data(using: .utf8)?.base64EncodedString() ?? ""
        return TraceHTTPHeader(key: "Authorization", value: "Basic \(credentials)")
    }

    private static func readDataPart(value: String, kind: DataPart.Kind) -> DataPart {
        let supportsFileReference = switch kind {
        case .data, .dataAscii, .dataBinary, .dataUrlEncode:
            true
        case .dataRaw:
            false
        }

        if supportsFileReference, value.hasPrefix("@") {
            return DataPart(kind: kind, value: String(value.dropFirst()), isFileReference: true)
        }

        return DataPart(kind: kind, value: value, isFileReference: false)
    }

    private static func parseFormPart(_ input: String, allowFileReference: Bool) -> FormPart? {
        let segments = input.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = segments.first else { return nil }

        let nameValue = first.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard !nameValue.isEmpty else { return nil }

        let name = String(nameValue[0])
        let rawValue = nameValue.count > 1 ? String(nameValue[1]) : ""
        var value: String?
        var filePath: String?
        var isFile = false
        var filename: String?
        var contentType: String?
        var encoder: String?

        if allowFileReference, rawValue.hasPrefix("@") {
            isFile = true
            filePath = String(rawValue.dropFirst())
        } else if allowFileReference, rawValue.hasPrefix("<") {
            let filePath = String(rawValue.dropFirst())
            if let data = try? String(contentsOfFile: filePath, encoding: .utf8) {
                value = data
            } else {
                value = ""
            }
        } else {
            value = rawValue
        }

        for segment in segments.dropFirst() {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("type=") {
                contentType = String(trimmed.dropFirst("type=".count))
            } else if trimmed.hasPrefix("filename=") {
                filename = String(trimmed.dropFirst("filename=".count))
            } else if trimmed.hasPrefix("encoder=") {
                encoder = String(trimmed.dropFirst("encoder=".count))
            }
        }

        return FormPart(
            name: name,
            value: value,
            filePath: filePath,
            filename: filename,
            contentType: contentType,
            encoder: encoder,
            isFile: isFile
        )
    }

    private static func parseConfigFileTokens(from path: String) throws -> [String] {
        if path == "-" {
            return []
        }
        let fileURL = URL(fileURLWithPath: path)
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var tokens: [String] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if let parsed = parseConfigLine(trimmed) {
                tokens.append(contentsOf: parsed)
            }
        }

        return tokens
    }

    private static func parseConfigLine(_ line: String) -> [String]? {
        var option = ""
        var value: String?
        var separatorFound = false
        var inQuotes = false
        var current = ""
        var index = line.startIndex

        func flushCurrent() {
            if option.isEmpty {
                option = current
            } else {
                value = current
            }
            current = ""
        }

        while index < line.endIndex {
            let char = line[index]
            if char == "\"" {
                inQuotes.toggle()
                index = line.index(after: index)
                continue
            }
            if !inQuotes, char == "=" || char == ":" || char.isWhitespace {
                separatorFound = true
                flushCurrent()
                while index < line.endIndex, line[index].isWhitespace || line[index] == "=" || line[index] == ":" {
                    index = line.index(after: index)
                }
                continue
            }
            if char == "\\", inQuotes {
                let nextIndex = line.index(after: index)
                if nextIndex < line.endIndex {
                    let nextChar = line[nextIndex]
                    switch nextChar {
                    case "\"": current.append("\"")
                    case "t": current.append("\t")
                    case "n": current.append("\n")
                    case "r": current.append("\r")
                    case "v": current.append("\u{0B}")
                    case "\\": current.append("\\")
                    default: current.append(nextChar)
                    }
                    index = line.index(after: nextIndex)
                    continue
                }
            }

            current.append(char)
            index = line.index(after: index)
        }

        if !current.isEmpty {
            flushCurrent()
        }

        guard !option.isEmpty else { return nil }
        if !separatorFound {
            return [normalizeConfigOption(option)]
        }

        if option.hasPrefix("-") {
            if let value {
                return [option, value]
            }
            return [option]
        }

        let normalized = normalizeConfigOption(option)
        if let value {
            return [normalized, value]
        }
        return [normalized]
    }

    private static func normalizeConfigOption(_ option: String) -> String {
        if option.hasPrefix("-") {
            return option
        }
        return "--" + option
    }

    private static func buildRequests(from transfer: TransferState) throws -> [NetworkRequest] {
        guard !transfer.urls.isEmpty else {
            return []
        }

        var headers = transfer.headers
        var bodyData: Data?
        var bodyString: String?

        if !transfer.formParts.isEmpty {
            let boundary = "trace-boundary-\(UUID().uuidString)"
            let multipart = buildMultipartBody(transfer.formParts, boundary: boundary)
            bodyData = multipart.data(using: .utf8)
            if !headers.contains(where: { $0.key.lowercased() == "content-type" }) {
                headers.append(TraceHTTPHeader(key: "Content-Type", value: "multipart/form-data; boundary=\(boundary)"))
            }
        } else if !transfer.dataParts.isEmpty {
            bodyString = buildDataBody(transfer.dataParts)
            if !transfer.useGet {
                bodyData = bodyString?.data(using: .utf8)
            }
            if !transfer.useGet, shouldAddUrlEncodedContentType(transfer.dataParts, headers: headers) {
                headers.append(TraceHTTPHeader(key: "Content-Type", value: "application/x-www-form-urlencoded"))
            }
        } else if let uploadFile = transfer.uploadFile {
            if uploadFile == "-" {
                bodyData = nil
            } else if let fileData = try? Data(contentsOf: URL(fileURLWithPath: uploadFile)) {
                bodyData = fileData
            }
        }

        var results: [NetworkRequest] = []
        for rawUrl in transfer.urls {
            let expanded = transfer.globOff ? [rawUrl] : expandGlobs(in: rawUrl)
            for expandedUrl in expanded {
                var urlString = normalizeURL(expandedUrl)

                if transfer.useGet, let bodyString {
                    urlString = appendQuery(urlString, bodyString)
                }

                guard URL(string: urlString) != nil else {
                    throw ParseError.invalidURL
                }

                let finalMethod = transfer.useGet && !transfer.methodExplicit ? .get : transfer.method
                let request = NetworkRequest(
                    id: UUID(),
                    url: urlString,
                    method: transfer.head ? .head : finalMethod,
                    statusCode: 0,
                    statusMessage: nil,
                    timestamp: Date(),
                    duration: 0,
                    requestHeaders: headers,
                    responseHeaders: [],
                    requestBody: bodyData.flatMap { BodyStorage.from(data: $0) } ?? .empty,
                    responseBody: .empty,
                    protocolVersion: transfer.protocolVersion
                )

                var mutable = request
                mutable.isManual = true
                results.append(mutable)
            }
        }

        return results
    }

    private static func buildDataBody(_ parts: [DataPart]) -> String {
        var pieces: [String] = []
        for part in parts {
            if part.isFileReference {
                if let data = try? String(contentsOfFile: part.value, encoding: .utf8) {
                    pieces.append(processDataValue(data, kind: part.kind))
                }
                continue
            }
            pieces.append(processDataValue(part.value, kind: part.kind))
        }
        return pieces.joined(separator: "&")
    }

    private static func processDataValue(_ value: String, kind: DataPart.Kind) -> String {
        let unescaped = unescapeBackslashQuotedString(value)
        return switch kind {
        case .data, .dataAscii:
            unescaped
        case .dataRaw, .dataBinary:
            unescaped
        case .dataUrlEncode:
            encodeDataUrl(value)
        }
    }

    private static func unescapeBackslashQuotedString(_ value: String) -> String {
        // When users paste cURL commands out of logs or string literals, JSON bodies are often
        // double-escaped (e.g. `{\"key\":\"value\"}`). Normalise the common case.
        return value.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func encodeDataUrl(_ value: String) -> String {
        if value.hasPrefix("@") {
            let filePath = String(value.dropFirst())
            if let data = try? String(contentsOfFile: filePath, encoding: .utf8) {
                return urlEncode(data)
            }
        }

        if let atIndex = value.firstIndex(of: "@"), !value.hasPrefix("@"), !value.contains("=") {
            let name = String(value[..<atIndex])
            let filePath = String(value[value.index(after: atIndex)...])
            if let data = try? String(contentsOfFile: filePath, encoding: .utf8) {
                return "\(urlEncode(name))=\(urlEncode(data))"
            }
        }

        if let equalsIndex = value.firstIndex(of: "=") {
            let name = String(value[..<equalsIndex])
            let content = String(value[value.index(after: equalsIndex)...])
            let encodedName = urlEncode(name)
            let encodedValue: String
            if content.hasPrefix("@") {
                let filePath = String(content.dropFirst())
                if let data = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    encodedValue = urlEncode(data)
                } else {
                    encodedValue = urlEncode(content)
                }
            } else {
                encodedValue = urlEncode(content)
            }
            return "\(encodedName)=\(encodedValue)"
        }

        return urlEncode(value)
    }

    private static func shouldAddUrlEncodedContentType(_ parts: [DataPart], headers: [TraceHTTPHeader]) -> Bool {
        let hasContentType = headers.contains { $0.key.lowercased() == "content-type" }
        if hasContentType {
            return false
        }

        // `-d/--data` defaults to `application/x-www-form-urlencoded` for form-like payloads,
        // but it is also commonly used for JSON. Only add the content-type when the payload
        // looks like a query/form body.
        for part in parts {
            switch part.kind {
            case .dataUrlEncode:
                return true
            case .data, .dataAscii:
                let raw = part.value
                if raw.contains("=") || raw.contains("&") {
                    return true
                }
            case .dataBinary, .dataRaw:
                continue
            }
        }

        return false
    }

    private static func buildMultipartBody(_ parts: [FormPart], boundary: String) -> String {
        var lines: [String] = []
        for part in parts {
            lines.append("--\(boundary)")
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename ?? part.filePath?.split(separator: "/").last.map(String.init), part.isFile {
                disposition += "; filename=\"\(filename)\""
            }
            lines.append(disposition)
            if let contentType = part.contentType {
                lines.append("Content-Type: \(contentType)")
            }
            lines.append("")

            if part.isFile, let filePath = part.filePath, let data = try? String(contentsOfFile: filePath, encoding: .utf8) {
                lines.append(data)
            } else if let value = part.value {
                lines.append(value)
            }
        }
        lines.append("--\(boundary)--")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private static func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    private static func normalizeURL(_ raw: String) -> String {
        if raw.contains("://") {
            return raw
        }

        if raw.hasPrefix("//") {
            return "http:\(raw)"
        }

        let lower = raw.lowercased()
        let prefixes = [
            ("ftp.", "ftp://"),
            ("ftps.", "ftps://"),
            ("sftp.", "sftp://"),
            ("smtp.", "smtp://"),
            ("imap.", "imap://"),
            ("pop3.", "pop3://"),
            ("ldap.", "ldap://")
        ]

        for (prefix, scheme) in prefixes where lower.hasPrefix(prefix) {
            return scheme + raw
        }

        return "http://\(raw)"
    }

    private static func expandGlobs(in url: String) -> [String] {
        guard let range = findFirstGlob(in: url) else {
            return [url]
        }

        let prefix = String(url[..<range.lowerBound])
        let suffix = String(url[range.upperBound...])
        let globContent = String(url[range.lowerBound ... url.index(before: range.upperBound)])

        let expansions = expandGlobContent(globContent)
        if expansions.isEmpty {
            return [url]
        }

        var results: [String] = []
        for value in expansions {
            results.append(contentsOf: expandGlobs(in: prefix + value + suffix))
        }
        return results
    }

    private static func findFirstGlob(in url: String) -> Range<String.Index>? {
        var index = url.startIndex
        while index < url.endIndex {
            let char = url[index]
            if char == "{" {
                if let end = url[index...].firstIndex(of: "}") {
                    let afterEnd = url.index(after: end)
                    return index ..< afterEnd
                }
            } else if char == "[" {
                if let end = url[index...].firstIndex(of: "]") {
                    let afterEnd = url.index(after: end)
                    return index ..< afterEnd
                }
            }
            index = url.index(after: index)
        }
        return nil
    }

    private static func expandGlobContent(_ content: String) -> [String] {
        if content.hasPrefix("{"), content.hasSuffix("}") {
            let inner = String(content.dropFirst().dropLast())
            return inner.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        }

        if content.hasPrefix("["), content.hasSuffix("]") {
            let inner = String(content.dropFirst().dropLast())
            return expandRange(inner)
        }

        return []
    }

    private static func expandRange(_ value: String) -> [String] {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let rangePart = String(parts[0])
        let step = parts.count > 1 ? Int(parts[1]) ?? 1 : 1

        let bounds = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return [] }

        let start = String(bounds[0])
        let end = String(bounds[1])

        if let startInt = Int(start), let endInt = Int(end) {
            let width = max(start.count, end.count)
            let stepValue = max(step, 1)
            let stride = startInt <= endInt ? stepValue : -stepValue
            var values: [String] = []
            var current = startInt
            if stride > 0 {
                while current <= endInt {
                    values.append(String(format: "%0*d", width, current))
                    current += stride
                }
            } else {
                while current >= endInt {
                    values.append(String(format: "%0*d", width, current))
                    current += stride
                }
            }
            return values
        }

        if start.count == 1, end.count == 1, let startScalar = start.unicodeScalars.first, let endScalar = end.unicodeScalars.first {
            let stepValue = max(step, 1)
            let stride = startScalar.value <= endScalar.value ? stepValue : -stepValue
            var values: [String] = []
            var current = startScalar.value
            if stride > 0 {
                while current <= endScalar.value {
                    if let scalar = UnicodeScalar(current) {
                        values.append(String(Character(scalar)))
                    }
                    current += UInt32(stepValue)
                }
            } else {
                while current >= endScalar.value {
                    if let scalar = UnicodeScalar(current) {
                        values.append(String(Character(scalar)))
                    }
                    current -= UInt32(stepValue)
                }
            }
            return values
        }

        return []
    }

    private static func appendQuery(_ urlString: String, _ query: String) -> String {
        guard !query.isEmpty else { return urlString }
        if urlString.contains("?") {
            return urlString + "&" + query
        }
        return urlString + "?" + query
    }

    private static func applyVariable(_ input: String, variables: inout [String: String]) {
        if input.hasPrefix("%") {
            let remainder = String(input.dropFirst())
            let nameEnd = remainder.firstIndex(where: { $0 == "=" || $0 == "@" }) ?? remainder.endIndex
            let name = String(remainder[..<nameEnd])
            if let envValue = ProcessInfo.processInfo.environment[name] {
                variables[name] = envValue
                return
            }
            if let equalIndex = remainder.firstIndex(of: "=") {
                let value = String(remainder[remainder.index(after: equalIndex)...])
                variables[name] = value
                return
            }
            if let atIndex = remainder.firstIndex(of: "@") {
                let filePath = String(remainder[remainder.index(after: atIndex)...])
                if let data = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    variables[name] = data
                }
                return
            }
            return
        }

        let parts = input.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            variables[String(parts[0])] = String(parts[1])
            return
        }

        if input.contains("@"), let atIndex = input.firstIndex(of: "@") {
            let name = String(input[..<atIndex])
            let filePath = String(input[input.index(after: atIndex)...])
            if let data = try? String(contentsOfFile: filePath, encoding: .utf8) {
                variables[name] = data
            }
        }
    }

    private static func expandVariables(in value: String, variables: [String: String]) -> String {
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            if value[index] == "\\" {
                let next = value.index(after: index)
                let nextNext = next < value.endIndex ? value.index(after: next) : value.endIndex
                if next < value.endIndex, value[next] == "{", nextNext < value.endIndex, value[nextNext] == "{" {
                    result.append("{{")
                    index = value.index(after: nextNext)
                    continue
                }
                if next < value.endIndex, value[next] == "{" {
                    result.append("{")
                    index = value.index(after: next)
                    continue
                }
            }

            if value[index] == "{" {
                let next = value.index(after: index)
                if next < value.endIndex, value[next] == "{" {
                    var replaced = false
                    var search = value.index(after: next)
                    while search < value.endIndex {
                        if value[search] == "}" {
                            let nextClose = value.index(after: search)
                            if nextClose < value.endIndex, value[nextClose] == "}" {
                                let inner = value[value.index(after: next) ..< search]
                                result.append(resolveVariable(String(inner), variables: variables))
                                index = value.index(after: nextClose)
                                replaced = true
                                break
                            }
                        }
                        search = value.index(after: search)
                    }
                    if replaced {
                        continue
                    }
                }
            }

            result.append(value[index])
            index = value.index(after: index)
        }

        return result
    }

    private static func resolveVariable(_ expression: String, variables: [String: String]) -> String {
        let parts = expression.split(separator: ":", omittingEmptySubsequences: false)
        guard let name = parts.first.map(String.init) else { return "" }
        var value = variables[name] ?? ""

        for function in parts.dropFirst() {
            switch function {
            case "trim":
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "json":
                if let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) {
                    value = encoded
                }
            case "url":
                value = urlEncode(value)
            case "b64":
                value = Data(value.utf8).base64EncodedString()
            case "64dec":
                if let data = Data(base64Encoded: value), let decoded = String(data: data, encoding: .utf8) {
                    value = decoded
                }
            default:
                continue
            }
        }

        return value
    }

    /// Export a NetworkRequest as a cURL command
    public static func toCurl(_ request: NetworkRequest) -> String {
        CurlCommandGenerator.generate(from: request)
    }

    /// Parse multiple cURL commands (separated by newlines)
    public static func parseMultiple(_ commands: String) -> [(request: NetworkRequest?, error: Error?)] {
        let lines = commands.components(separatedBy: .newlines)
        var results: [(request: NetworkRequest?, error: Error?)] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            do {
                guard trimmed.lowercased().hasPrefix("curl") else {
                    throw ParseError.invalidCommand
                }

                let requests = try parseAll(trimmed)
                for request in requests {
                    results.append((request, nil))
                }
            } catch {
                results.append((nil, error))
            }
        }

        return results
    }
}
