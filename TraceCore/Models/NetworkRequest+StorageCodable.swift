//
//  NetworkRequest+StorageCodable.swift
//  TraceCore
//

import Foundation

extension NetworkRequest: Codable {
    enum CodingKeys: String, CodingKey {
        case id, url, method, requestMethodRaw, statusCode, statusMessage, timestamp, duration
        case requestHeaders, responseHeaders, requestBody, responseBody, protocolVersion, sessionId
        case capturePath, captureFlowID, capturePolicyModeRaw, captureMetadataVersion
        case timingPhases, tlsInfo
        case wasThrottled, throttlingProfile
        case isDuplicate, duplicateOfRequestId
        case isManual
        case wasBlocked, wasCancelled, wasRewritten, isMocked, isReplayed
        case appliedScriptName, hitBreakpoint, retryAttempts
        case executionLog, executionErrors, appliedRuleIds
        case contentType, contentEncoding, userAgent, cacheControl
        case requestCookies, responseCookies
        case queryParameters, authorization, tlsAlerts
        case http2Streams, http2ConnectionInfo
        case redirectChain
        case curlExecutionMetadata
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case rawMethod
        case curlMetadata
    }

    private struct QueryItemStorage: Codable {
        let name: String
        let value: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.url = try container.decode(String.self, forKey: .url)
        self.method = try container.decode(HTTPMethod.self, forKey: .method)
        self.requestMethodRaw = try container.decodeIfPresent(String.self, forKey: .requestMethodRaw)
        self.statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.requestHeaders = try container.decode([TraceHTTPHeader].self, forKey: .requestHeaders)
        self.responseHeaders = try container.decode([TraceHTTPHeader].self, forKey: .responseHeaders)

        // Support legacy String? format for backward compatibility
        // Use try? to handle type mismatches (when it's actually a BodyStorage dictionary)
        if let bodyString = try? container.decode(String.self, forKey: .requestBody) {
            self.requestBody = BodyStorage.fromLegacyString(bodyString)
        } else {
            self.requestBody = try container.decodeIfPresent(BodyStorage.self, forKey: .requestBody) ?? .empty
        }

        if let bodyString = try? container.decode(String.self, forKey: .responseBody) {
            self.responseBody = BodyStorage.fromLegacyString(bodyString)
        } else {
            self.responseBody = try container.decodeIfPresent(BodyStorage.self, forKey: .responseBody) ?? .empty
        }

        self.protocolVersion = try container.decodeIfPresent(HTTPProtocolVersion.self, forKey: .protocolVersion)
        if let capturePathRaw = (try? container.decodeIfPresent(String.self, forKey: .capturePath)) ?? nil,
           let parsedCapturePath = NetworkCapturePath(rawValue: capturePathRaw) {
            self.capturePath = parsedCapturePath
        } else {
            self.capturePath = .unknown
        }
        self.captureFlowID = Self.decodeLossyUInt64(from: container, forKey: .captureFlowID)
        self.capturePolicyModeRaw = Self.decodeLossyUInt8(from: container, forKey: .capturePolicyModeRaw)
        self.captureMetadataVersion = Self.decodeLossyUInt8(from: container, forKey: .captureMetadataVersion)
        self.sessionId = try container.decodeIfPresent(UUID.self, forKey: .sessionId)

        self.timingPhases = try container.decodeIfPresent(NetworkTimingPhases.self, forKey: .timingPhases)
        self.tlsInfo = try container.decodeIfPresent(TLSConnectionInfo.self, forKey: .tlsInfo)
        self.wasThrottled = try container.decodeIfPresent(Bool.self, forKey: .wasThrottled) ?? false
        self.throttlingProfile = try container.decodeIfPresent(String.self, forKey: .throttlingProfile)
        self.isDuplicate = try container.decodeIfPresent(Bool.self, forKey: .isDuplicate) ?? false
        self.duplicateOfRequestId = try container.decodeIfPresent(UUID.self, forKey: .duplicateOfRequestId)
        self.isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        self.wasBlocked = try container.decodeIfPresent(Bool.self, forKey: .wasBlocked) ?? false
        self.wasCancelled = try container.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
        self.wasRewritten = try container.decodeIfPresent(Bool.self, forKey: .wasRewritten) ?? false
        self.isMocked = try container.decodeIfPresent(Bool.self, forKey: .isMocked) ?? false
        self.isReplayed = try container.decodeIfPresent(Bool.self, forKey: .isReplayed) ?? false
        self.appliedScriptName = try container.decodeIfPresent(String.self, forKey: .appliedScriptName)
        self.hitBreakpoint = try container.decodeIfPresent(Bool.self, forKey: .hitBreakpoint) ?? false
        self.retryAttempts = try container.decodeIfPresent(Int.self, forKey: .retryAttempts) ?? 0
        self.executionLog = try container.decodeIfPresent([ExecutionLogEntry].self, forKey: .executionLog) ?? []
        self.executionErrors = try container.decodeIfPresent([ExecutionError].self, forKey: .executionErrors) ?? []
        self.appliedRuleIds = try container.decodeIfPresent([UUID].self, forKey: .appliedRuleIds) ?? []
        self.contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        self.contentEncoding = try container.decodeIfPresent(String.self, forKey: .contentEncoding)
        self.userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        self.cacheControl = try container.decodeIfPresent(String.self, forKey: .cacheControl)
        self.requestCookies = try container.decodeIfPresent([HTTPCookie].self, forKey: .requestCookies)
        self.responseCookies = try container.decodeIfPresent([HTTPCookie].self, forKey: .responseCookies)
        if let storedQueryItems = try container.decodeIfPresent([QueryItemStorage].self, forKey: .queryParameters) {
            self.queryParameters = storedQueryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
        } else {
            self.queryParameters = nil
        }
        self.authorization = try container.decodeIfPresent(String.self, forKey: .authorization)
        self.tlsAlerts = try container.decodeIfPresent([TLSAlertMessage].self, forKey: .tlsAlerts)
        self.http2Streams = try container.decodeIfPresent([HTTP2StreamInfo].self, forKey: .http2Streams)
        self.http2ConnectionInfo = try container.decodeIfPresent(HTTP2ConnectionInfo.self, forKey: .http2ConnectionInfo)
        self.redirectChain = try container.decodeIfPresent([RedirectInfo].self, forKey: .redirectChain) ?? []
        self.curlExecutionMetadata = try container.decodeIfPresent(CurlExecutionMetadata.self, forKey: .curlExecutionMetadata)

        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if self.requestMethodRaw == nil {
            self.requestMethodRaw = try legacyContainer.decodeIfPresent(String.self, forKey: .rawMethod)
        }
        if self.curlExecutionMetadata == nil {
            // Accept either legacy CurlRequestMetadata ("options") or legacy-keyed
            // CurlExecutionMetadata ("effectiveOptions") payloads.
            if let legacyExecution = try? legacyContainer.decode(CurlExecutionMetadata.self, forKey: .curlMetadata) {
                self.curlExecutionMetadata = legacyExecution
            } else if let legacyMetadata = try? legacyContainer.decode(CurlRequestMetadata.self, forKey: .curlMetadata) {
                self.curlExecutionMetadata = legacyMetadata.asExecutionMetadata
            }
        }
    }

    private static func decodeLossyUInt64(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> UInt64? {
        if let value = (try? container.decodeIfPresent(UInt64.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil,
           value >= 0 {
            return UInt64(value)
        }
        return nil
    }

    private static func decodeLossyUInt8(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> UInt8? {
        if let value = (try? container.decodeIfPresent(UInt8.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil,
           (0 ... 255).contains(value) {
            return UInt8(value)
        }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(requestMethodRaw, forKey: .requestMethodRaw)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(duration, forKey: .duration)
        try container.encode(requestHeaders, forKey: .requestHeaders)
        try container.encode(responseHeaders, forKey: .responseHeaders)
        try container.encode(requestBody, forKey: .requestBody)
        try container.encode(responseBody, forKey: .responseBody)
        try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try container.encode(capturePath.rawValue, forKey: .capturePath)
        try container.encodeIfPresent(captureFlowID, forKey: .captureFlowID)
        try container.encodeIfPresent(capturePolicyModeRaw, forKey: .capturePolicyModeRaw)
        try container.encodeIfPresent(captureMetadataVersion, forKey: .captureMetadataVersion)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(timingPhases, forKey: .timingPhases)
        try container.encodeIfPresent(tlsInfo, forKey: .tlsInfo)
        try container.encode(wasThrottled, forKey: .wasThrottled)
        try container.encodeIfPresent(throttlingProfile, forKey: .throttlingProfile)
        try container.encode(isDuplicate, forKey: .isDuplicate)
        try container.encodeIfPresent(duplicateOfRequestId, forKey: .duplicateOfRequestId)
        try container.encode(isManual, forKey: .isManual)
        try container.encode(wasBlocked, forKey: .wasBlocked)
        try container.encode(wasCancelled, forKey: .wasCancelled)
        try container.encode(wasRewritten, forKey: .wasRewritten)
        try container.encode(isMocked, forKey: .isMocked)
        try container.encode(isReplayed, forKey: .isReplayed)
        try container.encodeIfPresent(appliedScriptName, forKey: .appliedScriptName)
        try container.encode(hitBreakpoint, forKey: .hitBreakpoint)
        try container.encode(retryAttempts, forKey: .retryAttempts)
        try container.encode(executionLog, forKey: .executionLog)
        try container.encode(executionErrors, forKey: .executionErrors)
        try container.encode(appliedRuleIds, forKey: .appliedRuleIds)
        try container.encodeIfPresent(contentType, forKey: .contentType)
        try container.encodeIfPresent(contentEncoding, forKey: .contentEncoding)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        try container.encodeIfPresent(requestCookies, forKey: .requestCookies)
        try container.encodeIfPresent(responseCookies, forKey: .responseCookies)
        let storedQueryItems = queryParameters?.map { QueryItemStorage(name: $0.name, value: $0.value) }
        try container.encodeIfPresent(storedQueryItems, forKey: .queryParameters)
        try container.encodeIfPresent(authorization, forKey: .authorization)
        try container.encodeIfPresent(tlsAlerts, forKey: .tlsAlerts)
        try container.encodeIfPresent(http2Streams, forKey: .http2Streams)
        try container.encodeIfPresent(http2ConnectionInfo, forKey: .http2ConnectionInfo)
        try container.encode(redirectChain, forKey: .redirectChain)
        try container.encodeIfPresent(curlExecutionMetadata, forKey: .curlExecutionMetadata)
    }
}

extension HTTPMethod: Codable {}
