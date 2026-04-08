//
//  NetworkInterceptor.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Intercepts and captures network requests via URLProtocol.
class NetworkInterceptor: URLProtocol {
    // MARK: - Properties

    private var dataTask: URLSessionDataTask?
    private var receivedData: Data?
    private var response: URLResponse?
    private var startTime: Date?

    // Rule: Prevent re-entrancy to avoid recursive interception.
    private static let handledKey = "NetworkInterceptorHandled"

    private static let forwardingSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Rule: Exclude this protocol to avoid an interception loop.
        config.protocolClasses = config.protocolClasses?.filter { $0 != NetworkInterceptor.self }
        return URLSession(configuration: config)
    }()

    // MARK: - URLProtocol Overrides

    /// Determines whether this protocol can handle the given request.
    override class func canInit(with request: URLRequest) -> Bool {
        // Rule: Do not intercept requests that already passed through this protocol.
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }

        // Rule: Intercept only HTTP/S traffic.
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        return true
    }

    /// Returns a canonical version of the request.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Starts loading the request.
    override func startLoading() {
        startTime = Date()

        // Rule: Mark the request before forwarding to avoid recursion.
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: NetworkInterceptor.handledKey, in: mutableRequest)

        // Performance: Reuse a shared session to avoid per-request session creation.
        dataTask = NetworkInterceptor.forwardingSession.dataTask(with: mutableRequest as URLRequest) { [weak self] data, response, error in
            guard let self else { return }

            self.response = response
            self.receivedData = data

            if let error {
                self.captureRequest(error: error)
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }

            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            }

            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }

            self.captureRequest()

            self.client?.urlProtocolDidFinishLoading(self)
        }

        dataTask?.resume()
    }

    /// Stops loading the request.
    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    // MARK: - Private Methods

    /// Capture the initiator stack trace, filtering out framework internals
    private func captureInitiatorStackTrace() -> String? {
        let symbols = Thread.callStackSymbols

        // Filter out framework internals and keep only app code frames
        let appFrames = symbols.dropFirst(2).prefix(10).filter { symbol in
            // Keep frames from the app/Trace targets, filter out Foundation/NIO
            !symbol.contains("Foundation") &&
                !symbol.contains("Darwin") &&
                !symbol.contains("SwiftUI") &&
                !symbol.contains("NIOCore") &&
                !symbol.contains("AsyncHTTPClient") &&
                !symbol.contains("CoreFoundation")
        }

        let filtered = Array(appFrames)
        guard !filtered.isEmpty else { return nil }

        // Format stack trace as readable string with line breaks
        return filtered.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// Compute timing phases from URLProtocol data
    /// For URLProtocol, we can estimate phases based on response characteristics
    private func computeTimingPhases(duration: TimeInterval, statusCode: Int?) -> NetworkTimingPhases? {
        // URLProtocol measures wall-clock time, but doesn't break down DNS/TCP/TLS
        // We distribute the duration heuristically:
        // - requestSent: ~5-10% of total time (send to server)
        // - ttfb: ~25-50% of total time (waiting for response)
        // - contentDownload: remainder

        guard duration > 0 else { return nil }

        // Conservative estimates for timing breakdown
        let requestSent = duration * 0.08 // ~8% for sending request
        let ttfb = duration * 0.35 // ~35% waiting for first byte
        let contentDownload = duration - requestSent - ttfb

        return NetworkTimingPhases(
            requestSent: requestSent > 0.001 ? requestSent : nil,
            ttfb: ttfb > 0.001 ? ttfb : nil,
            contentDownload: contentDownload > 0.001 ? contentDownload : nil
        )
    }

    private func captureRequest(error: Error? = nil) {
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime ?? endTime)

        let url = request.url?.absoluteString ?? ""
        let method = HTTPMethod(rawValue: request.httpMethod ?? "GET") ?? .get

        var requestHeaders = request.allHTTPHeaderFields?.map { key, value in
            TraceHTTPHeader(key: key, value: value)
        } ?? []

        let requestBodyStorage: BodyStorage
        if let bodyData = request.httpBody {
            requestBodyStorage = BodyStorage.from(data: bodyData)
        } else if request.httpBodyStream != nil {
            // Note: We cannot safely read the stream without consuming it; record a note instead.
            requestHeaders.append(
                TraceHTTPHeader(key: "X-Trace-Note", value: "Streamed body not captured")
            )
            requestBodyStorage = .empty
        } else {
            requestBodyStorage = .empty
        }

        var statusCode: Int?
        var responseHeaders: [TraceHTTPHeader] = []
        let statusMessage = error?.localizedDescription

        if let httpResponse = response as? HTTPURLResponse {
            statusCode = httpResponse.statusCode
            responseHeaders = HTTPHeaderNormalizer.flatten(httpResponse.allHeaderFields)
        }

        let responseBodyStorage: BodyStorage
        if let data = receivedData {
            let contentEncoding = responseHeaders.first { $0.key.lowercased() == "content-encoding" }?.value

            let charset = BodyStorage.extractCharset(from: responseHeaders)

            // Rule: Only pretty-print JSON when the payload is not compressed.
            if contentEncoding == nil || contentEncoding?.lowercased() == "identity",
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]) {
                responseBodyStorage = BodyStorage.from(data: prettyData, charset: charset, contentEncoding: contentEncoding)
            } else {
                responseBodyStorage = BodyStorage.from(data: data, charset: charset, contentEncoding: contentEncoding)
            }
        } else {
            responseBodyStorage = .empty
        }

        let networkRequest = NetworkRequest(
            url: url,
            method: method,
            statusCode: statusCode,
            statusMessage: statusMessage,
            timestamp: startTime ?? Date(),
            duration: duration,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBodyStorage,
            responseBody: responseBodyStorage,
            timingPhases: computeTimingPhases(duration: duration, statusCode: statusCode),
            initiatorStackTrace: captureInitiatorStackTrace()
        )

        // Concurrency: NetworkCaptureStore updates run on the MainActor.
        DispatchQueue.main.async {
            NetworkCaptureStore.shared.addRequest(networkRequest)
        }
    }
}
