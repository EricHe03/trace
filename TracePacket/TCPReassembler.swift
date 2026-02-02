//
//  TCPReassembler.swift
//  TracePacket
//
//  Created by Justin on 2026/01/19.
//

import Foundation

public struct FlowKey: Hashable, Sendable, CustomStringConvertible {
    public let sourceIP: IPAddress
    public let destinationIP: IPAddress
    public let sourcePort: UInt16
    public let destinationPort: UInt16

    public var description: String {
        "\(sourceIP):\(sourcePort)->\(destinationIP):\(destinationPort)"
    }
}

public final class TCPReassembler: @unchecked Sendable {
    public struct Output: Sendable {
        public let flow: FlowKey
        public let data: Data
        public let isFinal: Bool
    }

    private struct FlowState {
        var nextExpectedSeq: UInt32?
        var buffered: [UInt32: Data] = [:]
        var lastSeen: Date = .init()
        var isClosed = false
    }

    private let lock = NSLock()
    private var flows: [FlowKey: FlowState] = [:]
    private let idleTimeout: TimeInterval
    private let maxBufferedPerFlow: Int

    public init(idleTimeout: TimeInterval = 60, maxBufferedPerFlow: Int = 256) {
        self.idleTimeout = idleTimeout
        self.maxBufferedPerFlow = max(1, maxBufferedPerFlow)
    }

    public func process(
        ipPacket: IPPacket,
        tcpPacket: TCPPacket
    ) -> [Output] {
        let flow = FlowKey(
            sourceIP: ipPacket.source,
            destinationIP: ipPacket.destination,
            sourcePort: tcpPacket.sourcePort,
            destinationPort: tcpPacket.destinationPort
        )

        let now = Date()
        lock.lock()
        evictExpired(now: now)
        var state = flows[flow] ?? FlowState()
        state.lastSeen = now

        let payload = tcpPacket.payload
        let synOffset: UInt32 = tcpPacket.flags.contains(.syn) ? 1 : 0
        let fin = tcpPacket.flags.contains(.fin) || tcpPacket.flags.contains(.rst)

        var outputs: [Output] = []

        if !payload.isEmpty {
            var dataSeq = tcpPacket.sequenceNumber &+ synOffset
            if state.nextExpectedSeq == nil {
                state.nextExpectedSeq = dataSeq
            }

            if let expected = state.nextExpectedSeq {
                if dataSeq < expected {
                    let overlap = expected &- dataSeq
                    if overlap >= payload.count {
                        flows[flow] = state
                        lock.unlock()
                        return outputs
                    }
                    dataSeq = expected
                    let trimmed = payload.dropFirst(Int(overlap))
                    insertSegment(state: &state, seq: dataSeq, data: Data(trimmed))
                } else {
                    insertSegment(state: &state, seq: dataSeq, data: payload)
                }

                outputs.append(contentsOf: drainSegments(state: &state, flow: flow))
            }
        }

        if fin {
            state.isClosed = true
            if !outputs.isEmpty {
                outputs[outputs.count - 1] = Output(flow: flow, data: outputs.last!.data, isFinal: true)
            } else {
                outputs.append(Output(flow: flow, data: Data(), isFinal: true))
            }
        }

        flows[flow] = state
        lock.unlock()
        return outputs
    }

    private func insertSegment(state: inout FlowState, seq: UInt32, data: Data) {
        guard state.buffered.count < maxBufferedPerFlow else { return }
        if let existing = state.buffered[seq] {
            if existing.count >= data.count { return }
        }
        state.buffered[seq] = data
    }

    private func drainSegments(state: inout FlowState, flow: FlowKey) -> [Output] {
        var outputs: [Output] = []
        guard var expected = state.nextExpectedSeq else { return outputs }

        while true {
            if let data = state.buffered.removeValue(forKey: expected) {
                outputs.append(Output(flow: flow, data: data, isFinal: false))
                expected = expected &+ UInt32(data.count)
                continue
            }

            // If we have an overlapping segment that spans the expected sequence, trim it forward to
            // the expected boundary so draining can continue.
            if let (seq, data) = findSegmentSpanningExpected(buffered: state.buffered, expected: expected) {
                state.buffered.removeValue(forKey: seq)
                let overlap = expected &- seq
                if overlap < data.count {
                    let trimmed = data.dropFirst(Int(overlap))
                    state.buffered[expected] = Data(trimmed)
                    continue
                }
            }

            break
        }

        pruneBufferedSegmentsBehindExpected(state: &state, expected: expected)
        state.nextExpectedSeq = expected
        return outputs
    }

    private func findSegmentSpanningExpected(
        buffered: [UInt32: Data],
        expected: UInt32
    ) -> (seq: UInt32, data: Data)? {
        var bestSeq: UInt32?
        var bestData: Data?

        for (seq, data) in buffered {
            guard seq < expected else { continue }
            let end = seq &+ UInt32(data.count)
            guard end > expected else { continue }
            if let currentBest = bestSeq, currentBest > seq {
                continue
            }
            bestSeq = seq
            bestData = data
        }

        if let bestSeq, let bestData {
            return (bestSeq, bestData)
        }
        return nil
    }

    private func pruneBufferedSegmentsBehindExpected(state: inout FlowState, expected: UInt32) {
        guard !state.buffered.isEmpty else { return }

        var toRemove: [UInt32] = []
        var toReinsert: [(UInt32, Data)] = []

        for (seq, data) in state.buffered {
            let end = seq &+ UInt32(data.count)
            if end <= expected {
                toRemove.append(seq)
                continue
            }
            if seq < expected {
                let overlap = expected &- seq
                if overlap < data.count {
                    toRemove.append(seq)
                    let trimmed = data.dropFirst(Int(overlap))
                    toReinsert.append((expected, Data(trimmed)))
                }
            }
        }

        for seq in toRemove {
            state.buffered.removeValue(forKey: seq)
        }
        for (seq, data) in toReinsert {
            if let existing = state.buffered[seq] {
                if existing.count >= data.count { continue }
            }
            state.buffered[seq] = data
        }
    }

    private func evictExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-idleTimeout)
        flows = flows.filter { $0.value.lastSeen >= cutoff }
    }
}
