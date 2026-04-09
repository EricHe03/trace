//
//  QUICEngineRuntime.swift
//  TraceQUIC
//
//  Created by Justin on 2026/02/18.
//

import Foundation

#if canImport(CQuicheFFI)
import CQuicheFFI
#endif

public enum QUICEngineAvailability: String, Sendable {
    case unavailable
    case available
}

public struct QUICEngineStatus: Sendable {
    public let availability: QUICEngineAvailability
    public let version: String
    public let usingQuicheFFI: Bool

    public init(
        availability: QUICEngineAvailability,
        version: String,
        usingQuicheFFI: Bool
    ) {
        self.availability = availability
        self.version = version
        self.usingQuicheFFI = usingQuicheFFI
    }
}

public enum QUICEngineRuntime {
    public static func currentStatus() -> QUICEngineStatus {
        #if canImport(CQuicheFFI)
        let rawVersion = String(cString: cquiche_version_string())
        let availability: QUICEngineAvailability = cquiche_runtime_available() ? .available : .unavailable
        let version: String = if availability == .available {
            rawVersion
        } else if rawVersion == "quiche-staged-action-api" {
            "quiche-artifacts-missing"
        } else {
            rawVersion
        }
        return QUICEngineStatus(
            availability: availability,
            version: version,
            usingQuicheFFI: true
        )
        #else
        return QUICEngineStatus(
            availability: .unavailable,
            version: "ffi-not-linked",
            usingQuicheFFI: false
        )
        #endif
    }
}
