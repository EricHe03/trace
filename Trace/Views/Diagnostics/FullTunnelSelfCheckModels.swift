//
//  FullTunnelSelfCheckModels.swift
//  Trace
//
//  Created by Justin on 2026/03/06.
//

import SwiftUI

struct VPNEventLine: Decodable {
    let ts: Double
    let type: String
    let msg: String
}

enum CheckStatus {
    case pass
    case warn
    case fail

    var title: String {
        switch self {
        case .pass:
            "PASS"
        case .warn:
            "WARN"
        case .fail:
            "FAIL"
        }
    }

    var icon: String {
        switch self {
        case .pass:
            "checkmark.circle.fill"
        case .warn:
            "exclamationmark.triangle.fill"
        case .fail:
            "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass:
            .green
        case .warn:
            .orange
        case .fail:
            .red
        }
    }
}

struct SelfCheckReport {
    let sourceFileURL: URL?
    let generatedAt: Date
    let totalEvents: Int
    let parseErrorCount: Int
    let fullTunnelConfigured: Bool
    let transparentMITMIngressEnabled: Bool
    let routeMITMCount: Int
    let tunneledParsedCount: Int
    let pendingSavedCount: Int
    let completedRequestCount: Int
    let pendingOnlyCount: Int
    let savedSuccessCount: Int
    let savedFailureCount: Int
    let tunneledResponseCaptureCount: Int
    let httpUpstreamFailureCount: Int
    let pendingOnlyRequestIDs: [String]
    let upstreamFailureSamples: [String]

    static let empty = SelfCheckReport(
        sourceFileURL: nil,
        generatedAt: Date(),
        totalEvents: 0,
        parseErrorCount: 0,
        fullTunnelConfigured: false,
        transparentMITMIngressEnabled: false,
        routeMITMCount: 0,
        tunneledParsedCount: 0,
        pendingSavedCount: 0,
        completedRequestCount: 0,
        pendingOnlyCount: 0,
        savedSuccessCount: 0,
        savedFailureCount: 0,
        tunneledResponseCaptureCount: 0,
        httpUpstreamFailureCount: 0,
        pendingOnlyRequestIDs: [],
        upstreamFailureSamples: []
    )

    func withGeneratedNow(sourceFile: URL?) -> SelfCheckReport {
        SelfCheckReport(
            sourceFileURL: sourceFile,
            generatedAt: Date(),
            totalEvents: totalEvents,
            parseErrorCount: parseErrorCount,
            fullTunnelConfigured: fullTunnelConfigured,
            transparentMITMIngressEnabled: transparentMITMIngressEnabled,
            routeMITMCount: routeMITMCount,
            tunneledParsedCount: tunneledParsedCount,
            pendingSavedCount: pendingSavedCount,
            completedRequestCount: completedRequestCount,
            pendingOnlyCount: pendingOnlyCount,
            savedSuccessCount: savedSuccessCount,
            savedFailureCount: savedFailureCount,
            tunneledResponseCaptureCount: tunneledResponseCaptureCount,
            httpUpstreamFailureCount: httpUpstreamFailureCount,
            pendingOnlyRequestIDs: pendingOnlyRequestIDs,
            upstreamFailureSamples: upstreamFailureSamples
        )
    }

    var bypassRouteStatus: CheckStatus {
        if routeMITMCount > 0, tunneledParsedCount > 0 {
            return .pass
        }
        if routeMITMCount > 0 || tunneledParsedCount > 0 {
            return .warn
        }
        return .fail
    }

    var requestLifecycleStatus: CheckStatus {
        if pendingSavedCount == 0 {
            return .warn
        }
        if completedRequestCount == 0 {
            return .fail
        }
        if pendingOnlyCount > 0 {
            return .warn
        }
        return .pass
    }

    var responseCaptureStatus: CheckStatus {
        if tunneledResponseCaptureCount > 0 {
            return .pass
        }
        if tunneledParsedCount > 0 {
            return .warn
        }
        return .fail
    }

    var overallStatus: CheckStatus {
        guard fullTunnelConfigured, transparentMITMIngressEnabled else {
            return .fail
        }
        guard bypassRouteStatus != .fail else {
            return .fail
        }
        if requestLifecycleStatus == .fail || responseCaptureStatus == .fail {
            return .fail
        }
        if requestLifecycleStatus == .warn || responseCaptureStatus == .warn || parseErrorCount > 0 {
            return .warn
        }
        return .pass
    }
}
