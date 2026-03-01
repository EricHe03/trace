//
//  QUICFlowRouter+State.swift
//  TraceVPN
//

import Darwin
import Dispatch
import Foundation
import OSLog
import Security
import TraceCore
import TracePacket
import TraceProxy
import TraceQUIC
import TraceSecurity

extension QUICFlowRouter {
    func shouldEmitRouteDecisionEvent(flowID: UUID?, signature: String) -> Bool {
        guard let flowID else { return true }

        return stateQueue.sync {
            if routeDecisionLogSignaturesByFlowID[flowID] == signature {
                return false
            }
            routeDecisionLogSignaturesByFlowID[flowID] = signature
            trimRouteDecisionLogsLocked()

            if let flowKey = flowStates.first(where: { $0.value.flowID == flowID })?.key,
               var state = flowStates[flowKey] {
                state.lastRouteDecisionLogSignature = signature
                flowStates[flowKey] = state
            }
            return true
        }
    }

    /// Attempts to consume an upstream QUIC datagram for an active intercepted flow.
    ///
    /// Returns `true` when the datagram was handed to the intercept engine and should
    /// not be written directly back to the app. Returns `false` when no active
    /// intercepted flow matches and normal forwarding should continue.
    @discardableResult
    func parseHeaderMetadata(payload: Data) -> ParsedHeaderMetadata {
        guard let first = payload.first else {
            return ParsedHeaderMetadata(
                version: nil,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: nil
            )
        }

        // QUIC long headers expose version and connection ID lengths.
        guard (first & 0x80) == 0x80, payload.count >= 6 else {
            return ParsedHeaderMetadata(
                version: nil,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: nil
            )
        }

        let versionRaw =
            (UInt32(payload[1]) << 24) |
            (UInt32(payload[2]) << 16) |
            (UInt32(payload[3]) << 8) |
            UInt32(payload[4])
        let version = String(format: "0x%08X", versionRaw)

        var index = 5
        guard payload.count > index else {
            return ParsedHeaderMetadata(
                version: version,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: nil
            )
        }

        let destinationConnectionIDLength = Int(payload[index])
        index += 1
        guard payload.count >= index + destinationConnectionIDLength + 1 else {
            return ParsedHeaderMetadata(
                version: version,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: destinationConnectionIDLength
            )
        }

        index += destinationConnectionIDLength
        let sourceConnectionIDLength = Int(payload[index])
        index += 1
        guard payload.count >= index + sourceConnectionIDLength else {
            return ParsedHeaderMetadata(
                version: version,
                sourceConnectionIDLength: sourceConnectionIDLength,
                destinationConnectionIDLength: destinationConnectionIDLength
            )
        }

        return ParsedHeaderMetadata(
            version: version,
            sourceConnectionIDLength: sourceConnectionIDLength,
            destinationConnectionIDLength: destinationConnectionIDLength
        )
    }

    func updateNoProgressSnapshot(
        flowKey: FlowKey,
        flowID: UUID,
        fromClient: Bool,
        ingestResult: QUICMitmIngestResult,
        now: Date
    ) -> NoProgressSnapshot? {
        stateQueue.sync {
            guard var state = flowStates[flowKey], state.flowID == flowID else {
                return nil
            }

            if fromClient {
                state.clientDatagramsSeen += 1
            }

            if ingestResult.processedStreams > 0 {
                state.processedStreamCount += ingestResult.processedStreams
            }

            if ingestResult.processedStreams > 0 ||
                !ingestResult.datagramsToClient.isEmpty ||
                !ingestResult.datagramsToUpstream.isEmpty {
                state.lastProgressAt = now
            }

            flowStates[flowKey] = state
            return NoProgressSnapshot(
                budgetStartAt: state.noProgressBudgetStartAt,
                establishedAt: state.establishedAt,
                lastProgressAt: state.lastProgressAt,
                clientDatagramsSeen: state.clientDatagramsSeen,
                processedStreams: state.processedStreamCount
            )
        }
    }

    func datagramContext(for flowKey: FlowKey, flowID: UUID) -> QUICFlowDatagramContext? {
        stateQueue.sync {
            guard let state = flowStates[flowKey], state.flowID == flowID else {
                return nil
            }
            return QUICFlowDatagramContext(
                flowID: state.flowID,
                clientIP: state.clientIP,
                clientPort: state.clientPort,
                serverIP: state.serverIP,
                serverPort: state.serverPort,
                upstreamForwardingDecision: state.upstreamForwardingDecision
            )
        }
    }
}
