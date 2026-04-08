//
//  NetworkInterceptor.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

// MARK: - Metrics Delegate

/// Captures URLSessionTaskMetrics for each forwarded task and delivers them to the waiting interceptor.
private final class NetworkInterceptorSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Maps task identifier → pending interceptor (weak to avoid retain cycles)
    private var pendingMetrics: [Int: URLSessionTaskMetrics] = [:]
    private var pendingInterceptors: [Int: NetworkInterceptor] = [:]
    private let lock = NSLock()

    func register(_ interceptor: NetworkInterceptor, for task: URLSessionTask) {
        lock.withLock {
            pendingInterceptors[task.taskIdentifier] = interceptor
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Relay data to the URLProtocol client — the session delegate intercepts data delivery,
        // so we must re-deliver it here.
        lock.withLock { pendingInterceptors[dataTask.taskIdentifier] }?
            .relayData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let interceptor = lock.withLock { pendingInterceptors.removeValue(forKey: task.taskIdentifier) }
        let metrics = lock.withLock { pendingMetrics.removeValue(forKey: task.taskIdentifier) }
        interceptor?.relayCompletion(response: task.response, error: error, metrics: metrics)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { pendingInterceptors[dataTask.taskIdentifier] }?
            .relayResponse(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { pendingMetrics[task.taskIdentifier] = metrics }
    }
}

// MARK: - NetworkInterceptor

/// Intercepts and captures network requests via URLProtocol.
class NetworkInterceptor: URLProtocol {
    // MARK: - Properties

    private var dataTask: URLSessionDataTask?
    private var accumulatedData = Data()
    private var startTime: Date?

    // Rule: Prevent re-entrancy to avoid recursive interception.
    private static let handledKey = "NetworkInterceptorHandled"

    private static let sessionDelegate = NetworkInterceptorSessionDelegate()

    private static let forwardingSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Rule: Exclude this protocol to avoid an interception loop.
        config.protocolClasses = config.protocolClasses?.filter { $0 != NetworkInterceptor.self }
        // Delegate is required to receive URLSessionTaskMetrics via didFinishCollecting.
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
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

        // The session delegate receives data/response/completion events and URLSessionTaskMetrics.
        let task = NetworkInterceptor.forwardingSession.dataTask(with: mutableRequest as URLRequest)
        NetworkInterceptor.sessionDelegate.register(self, for: task)
        dataTask = task
        task.resume()
    }

    /// Stops loading the request.
    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    // MARK: - Relay (called by the shared delegate)

    func relayResponse(_ response: URLResponse) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
    }

    func relayData(_ data: Data) {
        accumulatedData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func relayCompletion(response: URLResponse?, error: Error?, metrics: URLSessionTaskMetrics?) {
        if let error {
            captureRequest(response: response, error: error, metrics: metrics)
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            captureRequest(response: response, error: nil, metrics: metrics)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    // MARK: - Private Methods

    /// Capture the initiator stack trace at request start time, filtering out framework internals.
    private func captureInitiatorStackTrace() -> String? {
        let symbols = Thread.callStackSymbols
        let appFrames = symbols.dropFirst(2).prefix(10).filter { symbol in
            !symbol.contains("Foundation") &&
                !symbol.contains("Darwin") &&
                !symbol.contains("SwiftUI") &&
                !symbol.contains("NIOCore") &&
                !symbol.contains("AsyncHTTPClient") &&
                !symbol.contains("CoreFoundation")
        }
        let filtered = Array(appFrames)
        guard !filtered.isEmpty else { return nil }
        return filtered.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// Build real NetworkTimingPhases from URLSessionTaskMetrics.
    /// All values come directly from the URL Loading System — no estimates.
    private func timingPhases(from metrics: URLSessionTaskMetrics) -> NetworkTimingPhases? {
        // Use the last transaction (covers the final, non-redirect leg).
        guard let tx = metrics.transactionMetrics.last else { return nil }

        func interval(from start: Date?, to end: Date?) -> TimeInterval? {
            guard let s = start, let e = end, e > s else { return nil }
            return e.timeIntervalSince(s)
        }

        let dnsLookup = interval(from: tx.domainLookupStartDate, to: tx.domainLookupEndDate)
        let tcpConnection = interval(from: tx.connectStartDate, to: tx.connectEndDate)
        let tlsHandshake = interval(from: tx.secureConnectionStartDate, to: tx.secureConnectionEndDate)
        let requestSent = interval(from: tx.requestStartDate, to: tx.requestEndDate)
        let ttfb = interval(from: tx.requestEndDate, to: tx.responseStartDate)
        let contentDownload = interval(from: tx.responseStartDate, to: tx.responseEndDate)

        // Redirect time: sum of all transactions except the last.
        let redirectTransactions = metrics.transactionMetrics.dropLast()
        let redirectTime: TimeInterval? = if redirectTransactions.isEmpty {
            nil
        } else {
            redirectTransactions.compactMap { t in
                interval(from: t.fetchStartDate, to: t.responseEndDate)
            }.reduce(0, +)
        }

        let phases = NetworkTimingPhases(
            dnsLookup: dnsLookup,
            tcpConnection: tcpConnection,
            tlsHandshake: tlsHandshake,
            requestSent: requestSent,
            ttfb: ttfb,
            contentDownload: contentDownload,
            redirectTime: redirectTime
        )
        return phases.hasAnyData ? phases : nil
    }

    private func captureRequest(response: URLResponse?, error: Error?, metrics: URLSessionTaskMetrics?) {
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

        let data = accumulatedData
        let responseBodyStorage: BodyStorage
        if !data.isEmpty {
            let contentEncoding = responseHeaders.first { $0.key.lowercased() == "content-encoding" }?.value
            let charset = BodyStorage.extractCharset(from: responseHeaders)
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

        let realTimingPhases = metrics.flatMap { timingPhases(from: $0) }

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
            timingPhases: realTimingPhases,
            initiatorStackTrace: captureInitiatorStackTrace()
        )

        DispatchQueue.main.async {
            NetworkCaptureStore.shared.addRequest(networkRequest)
        }
    }
}
