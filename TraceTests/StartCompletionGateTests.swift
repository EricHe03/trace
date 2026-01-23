//
//  StartCompletionGateTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/11.
//

#if !targetEnvironment(simulator)
import XCTest
@testable import TraceVPN

final class StartCompletionGateTests: XCTestCase {
    func testAllowsOnlyFirstCompletionPerInvocation() async {
        let gate = StartCompletionGate()

        await gate.begin(invocationID: "first")
        let firstResult = await gate.shouldComplete(invocationID: "first")
        let secondResult = await gate.shouldComplete(invocationID: "first")

        XCTAssertTrue(firstResult)
        XCTAssertFalse(secondResult)
    }

    func testResetsForNewInvocation() async {
        let gate = StartCompletionGate()

        await gate.begin(invocationID: "first")
        _ = await gate.shouldComplete(invocationID: "first")

        await gate.begin(invocationID: "second")
        let oldResult = await gate.shouldComplete(invocationID: "first")
        let newResult = await gate.shouldComplete(invocationID: "second")

        XCTAssertFalse(oldResult)
        XCTAssertTrue(newResult)
    }
}
#else
import XCTest

final class StartCompletionGateTests: XCTestCase {
    func testStartCompletionGateUnavailableOnSimulator() throws {
        throw XCTSkip("StartCompletionGate lives in the TraceVPN app extension, which is not linked into simulator unit tests.")
    }
}
#endif
