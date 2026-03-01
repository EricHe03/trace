//
//  NIOMITMSSECaptureState.swift
//  TraceProxy
//

import Foundation
import NIOCore
import NIOHTTP1
import TraceCore

final class NIOMITMSSECaptureState: @unchecked Sendable {
    static let persistenceQueue = DispatchQueue(
        label: "com.trace.proxy.nio.sse.capture.persist",
        qos: .utility
    )

    let lock = NSLock()
    let baseRequest: NetworkRequest
    var responseStatusCode: Int?
    var responseStatusMessage: String?
    var responseHeaders: [TraceHTTPHeader] = []
    var connection: SSEConnection?
    var parser = SSEParser()
    var utf8Remainder = Data()
    var publishThrottle = SSECapturePublishThrottle()
    var finished = false

    let maxEvents = 1000
    let maxTotalBytes = 10 * 1024 * 1024

    init(baseRequest: NetworkRequest) {
        self.baseRequest = baseRequest
    }

    func beginResponse(head: HTTPResponseHead, captureConfig: CaptureConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        responseStatusCode = Int(head.status.code)
        responseStatusMessage = head.status.reasonPhrase
        responseHeaders = captureConfig.captureHeaders
            ? head.headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
            : []

        if connection == nil {
            connection = SSEConnection(
                id: UUID(),
                url: baseRequest.url,
                startTime: Date(),
                status: .streaming,
                requestHeaders: captureConfig.captureHeaders ? baseRequest.requestHeaders : [],
                responseHeaders: responseHeaders
            )
            if let snapshot = connection {
                persist(snapshot)
            }
        } else {
            connection?.responseHeaders = responseHeaders
        }
    }

    func consume(
        bodyChunk: Data,
        captureConfig: CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?
    ) {
        guard !bodyChunk.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard var snapshot = connection else { return }

        snapshot.totalBytesReceived += bodyChunk.count
        if snapshot.events.count >= maxEvents || snapshot.totalBytesReceived >= maxTotalBytes {
            if !snapshot.isTruncated {
                snapshot.isTruncated = true
                connection = snapshot
                persist(snapshot)
                emitRequestSnapshotLocked(
                    connection: snapshot,
                    captureConfig: captureConfig,
                    onRequestCaptured: onRequestCaptured
                )
            }
            return
        }

        guard let decoded = decodeUTF8ChunkLocked(bodyChunk), !decoded.isEmpty else {
            connection = snapshot
            return
        }

        let events = parser.parse(decoded)
        if !events.isEmpty {
            for event in events {
                snapshot.addEvent(event)
            }
            connection = snapshot
            if publishThrottle.shouldPublish(connection: snapshot) {
                persist(snapshot)
                emitRequestSnapshotLocked(
                    connection: snapshot,
                    captureConfig: captureConfig,
                    onRequestCaptured: onRequestCaptured
                )
            }
        } else {
            connection = snapshot
        }
    }

    func finish(
        succeeded: Bool,
        captureConfig: CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true

        var snapshot = connection ?? SSEConnection(
            id: UUID(),
            url: baseRequest.url,
            startTime: Date(),
            status: .streaming,
            requestHeaders: captureConfig.captureHeaders ? baseRequest.requestHeaders : [],
            responseHeaders: responseHeaders
        )
        snapshot.status = succeeded ? .closed : .failed
        snapshot.endTime = Date()
        connection = snapshot
        persist(snapshot)
        emitRequestSnapshotLocked(
            connection: snapshot,
            captureConfig: captureConfig,
            onRequestCaptured: onRequestCaptured
        )
    }

    func decodeUTF8ChunkLocked(_ data: Data) -> String? {
        let combined = utf8Remainder + data
        if let decoded = String(data: combined, encoding: .utf8) {
            utf8Remainder.removeAll(keepingCapacity: false)
            return decoded
        }

        var splitIndex = combined.count
        var decodedString: String?
        let maxTail = min(3, combined.count)
        for drop in 1 ... maxTail {
            let endIndex = combined.count - drop
            guard endIndex > 0 else { break }
            if let candidate = String(data: combined.subdata(in: 0 ..< endIndex), encoding: .utf8) {
                decodedString = candidate
                splitIndex = endIndex
                break
            }
        }

        guard let decodedString else {
            utf8Remainder = combined
            return nil
        }

        utf8Remainder = combined.subdata(in: splitIndex ..< combined.count)
        return decodedString
    }

    func emitRequestSnapshotLocked(
        connection: SSEConnection,
        captureConfig: CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?
    ) {
        guard let onRequestCaptured else { return }

        var snapshot = baseRequest
        snapshot.statusCode = responseStatusCode ?? 200
        snapshot.statusMessage = responseStatusMessage ?? "OK"
        snapshot.responseHeaders = captureConfig.captureHeaders ? responseHeaders : []
        if captureConfig.captureBody, captureConfig.maxBodySize > 0 {
            let payload = SSEPayloadSerializer.serialize(events: connection.events)
            if payload.isEmpty {
                snapshot.responseBody = .empty
            } else {
                let charset = BodyStorage.extractCharset(from: snapshot.responseHeaders)
                snapshot.responseBody = BodyStorage.from(
                    string: payload,
                    charset: charset,
                    maxSize: max(0, captureConfig.maxBodySize)
                )
            }
        } else {
            snapshot.responseBody = .empty
        }
        snapshot.duration = Date().timeIntervalSince(snapshot.timestamp)
        snapshot.extractHTTPFields()
        NetworkThrottlingController.shared.applyMetadata(to: &snapshot)
        onRequestCaptured(snapshot)
    }

    func persist(_ snapshot: SSEConnection) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.saveSSEConnection(snapshot)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_sse_capture_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
