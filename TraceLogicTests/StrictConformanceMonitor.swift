//
//  StrictConformanceMonitor.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

@testable import TraceCore
import XCTest

struct StrictConformanceMonitor {
    struct Observation {
        let isEligible: Bool
        let policy: DualMITMPolicy
        let action: FailureOutcomeAction
    }

    private(set) var observations: [Observation] = []

    mutating func record(
        isEligible: Bool,
        policy: DualMITMPolicy,
        action: FailureOutcomeAction
    ) {
        observations.append(
            Observation(
                isEligible: isEligible,
                policy: policy,
                action: action
            )
        )
    }

    func assertNoStrictFailOpen(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for observation in observations where observation.policy == .strictMITM && observation.isEligible {
            switch observation.action {
            case .failOpenPassThrough, .failOpenDirect:
                XCTFail("Strict mode eligible flow failed open", file: file, line: line)
            default:
                continue
            }
        }
    }
}
