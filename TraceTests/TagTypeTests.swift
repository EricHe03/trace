//
//  TagTypeTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
import SwiftUI
@testable import TraceCore

final class TagTypeTests: XCTestCase {

    // MARK: - TagPriority Tests

    func testTagPriorityRawValues() {
        XCTAssertEqual(TagPriority.critical.rawValue, 0)
        XCTAssertEqual(TagPriority.high.rawValue, 1)
        XCTAssertEqual(TagPriority.medium.rawValue, 2)
        XCTAssertEqual(TagPriority.low.rawValue, 3)
    }

    func testTagPriorityComparable() {
        XCTAssertLessThan(TagPriority.critical, TagPriority.high)
        XCTAssertLessThan(TagPriority.high, TagPriority.medium)
        XCTAssertLessThan(TagPriority.medium, TagPriority.low)

        XCTAssertGreaterThan(TagPriority.low, TagPriority.medium)
        XCTAssertGreaterThan(TagPriority.medium, TagPriority.high)
        XCTAssertGreaterThan(TagPriority.high, TagPriority.critical)
    }

    func testTagPriorityEquality() {
        XCTAssertEqual(TagPriority.critical, TagPriority.critical)
        XCTAssertNotEqual(TagPriority.critical, TagPriority.high)
    }

    // MARK: - TagType Display Text Tests

    func testTagTypeDisplayTextProtocols() {
        XCTAssertEqual(TagType.h2.displayText, "H2")
        XCTAssertEqual(TagType.h3.displayText, "H3")
        XCTAssertEqual(TagType.ws.displayText, "WS")
        XCTAssertEqual(TagType.sse.displayText, "SSE")
        XCTAssertEqual(TagType.grpc.displayText, "gRPC")
        XCTAssertEqual(TagType.graphql.displayText, "GraphQL")
    }

    func testTagTypeDisplayTextReliability() {
        XCTAssertEqual(TagType.failed.displayText, "Failed")
        XCTAssertEqual(TagType.timeout.displayText, "Timeout")
        XCTAssertEqual(TagType.blocked.displayText, "Blocked")
        XCTAssertEqual(TagType.cancelled.displayText, "Cancelled")
        XCTAssertEqual(TagType.retry(count: 3).displayText, "Retry ×3")
        XCTAssertEqual(TagType.retry(count: 0).displayText, "Retry ×0")
    }

    func testTagTypeDisplayTextTLS() {
        XCTAssertEqual(TagType.tlsPassthrough(reason: nil).displayText, "TLS")
        XCTAssertEqual(TagType.tlsPassthrough(reason: "cert pinning").displayText, "TLS")
        XCTAssertEqual(TagType.pinned.displayText, "Pinned")
    }

    func testTagTypeDisplayTextPerformance() {
        XCTAssertEqual(TagType.slow(duration: 10.5).displayText, "Slow")
        XCTAssertEqual(TagType.throttled(profile: nil).displayText, "Throttled")
        XCTAssertEqual(TagType.stalled(duration: 5.0).displayText, "Stalled")
    }

    func testTagTypeDisplayTextCaching() {
        XCTAssertEqual(TagType.cached(source: nil).displayText, "Cached")
        XCTAssertEqual(TagType.cached(source: "disk").displayText, "Cached")
        XCTAssertEqual(TagType.stale.displayText, "Stale")
        XCTAssertEqual(TagType.redirected(count: 2).displayText, "Redirected")
        XCTAssertEqual(TagType.rewritten.displayText, "Rewritten")
    }

    func testTagTypeDisplayTextSource() {
        XCTAssertEqual(TagType.manual.displayText, "Manual")
        XCTAssertEqual(TagType.replayed.displayText, "Replayed")
        XCTAssertEqual(TagType.script(name: nil).displayText, "Script")
        XCTAssertEqual(TagType.script(name: "test.js").displayText, "Script")
        XCTAssertEqual(TagType.mock.displayText, "Mock")
    }

    func testTagTypeDisplayTextAnalysis() {
        XCTAssertEqual(TagType.large(size: 10000).displayText, "Large")
        XCTAssertEqual(TagType.binary.displayText, "Binary")
        XCTAssertEqual(TagType.breakpoint.displayText, "Breakpoint")
    }

    // MARK: - TagType Priority Tests

    func testTagTypePriorityCritical() {
        XCTAssertEqual(TagType.failed.priority, .critical)
        XCTAssertEqual(TagType.timeout.priority, .critical)
        XCTAssertEqual(TagType.blocked.priority, .critical)
        XCTAssertEqual(TagType.cancelled.priority, .critical)
        XCTAssertEqual(TagType.tlsPassthrough(reason: nil).priority, .critical)
        XCTAssertEqual(TagType.pinned.priority, .critical)
    }

    func testTagTypePriorityHigh() {
        XCTAssertEqual(TagType.slow(duration: 10).priority, .high)
        XCTAssertEqual(TagType.throttled(profile: nil).priority, .high)
        XCTAssertEqual(TagType.stalled(duration: 5).priority, .high)
        XCTAssertEqual(TagType.h2.priority, .high)
        XCTAssertEqual(TagType.h3.priority, .high)
        XCTAssertEqual(TagType.ws.priority, .high)
        XCTAssertEqual(TagType.sse.priority, .high)
        XCTAssertEqual(TagType.grpc.priority, .high)
        XCTAssertEqual(TagType.graphql.priority, .high)
    }

    func testTagTypePriorityMedium() {
        XCTAssertEqual(TagType.manual.priority, .medium)
        XCTAssertEqual(TagType.replayed.priority, .medium)
        XCTAssertEqual(TagType.script(name: nil).priority, .medium)
        XCTAssertEqual(TagType.mock.priority, .medium)
        XCTAssertEqual(TagType.cached(source: nil).priority, .medium)
        XCTAssertEqual(TagType.redirected(count: 1).priority, .medium)
        XCTAssertEqual(TagType.rewritten.priority, .medium)
    }

    func testTagTypePriorityLow() {
        XCTAssertEqual(TagType.retry(count: 1).priority, .low)
        XCTAssertEqual(TagType.large(size: 1000).priority, .low)
        XCTAssertEqual(TagType.binary.priority, .low)
        XCTAssertEqual(TagType.stale.priority, .low)
        XCTAssertEqual(TagType.breakpoint.priority, .low)
    }

    // MARK: - TagType Tooltip Tests

    func testTagTypeTooltipProtocols() {
        XCTAssertEqual(TagType.h2.tooltip, "HTTP/2 Protocol")
        XCTAssertEqual(TagType.h3.tooltip, "HTTP/3 over QUIC")
        XCTAssertEqual(TagType.ws.tooltip, "WebSocket Connection")
        XCTAssertEqual(TagType.sse.tooltip, "Server-Sent Events Stream")
        XCTAssertEqual(TagType.grpc.tooltip, "gRPC Protocol")
        XCTAssertEqual(TagType.graphql.tooltip, "GraphQL Request")
    }

    func testTagTypeTooltipReliability() {
        XCTAssertEqual(TagType.failed.tooltip, "Request Failed")
        XCTAssertEqual(TagType.timeout.tooltip, "Request Timed Out")
        XCTAssertEqual(TagType.blocked.tooltip, "Blocked by Filter/Rule")
        XCTAssertEqual(TagType.cancelled.tooltip, "Request Cancelled")
        XCTAssertEqual(TagType.retry(count: 2).tooltip, "Retried 2 time(s)")
    }

    func testTagTypeTooltipTLS() {
        XCTAssertTrue(TagType.tlsPassthrough(reason: nil).tooltip.contains("TLS Passthrough"))
        XCTAssertTrue(TagType.tlsPassthrough(reason: "pinning").tooltip.contains("pinning"))
        XCTAssertTrue(TagType.pinned.tooltip.contains("Certificate Pinning"))
    }

    func testTagTypeTooltipPerformance() {
        let slowTooltip = TagType.slow(duration: 10.5).tooltip
        XCTAssertTrue(slowTooltip.contains("10.5"))

        XCTAssertEqual(TagType.throttled(profile: nil).tooltip, "Throttled")
        XCTAssertTrue(TagType.throttled(profile: "3G").tooltip.contains("3G"))

        let stalledTooltip = TagType.stalled(duration: 5.2).tooltip
        XCTAssertTrue(stalledTooltip.contains("5.2"))
    }

    func testTagTypeTooltipCaching() {
        XCTAssertTrue(TagType.cached(source: nil).tooltip.contains("Cache"))
        XCTAssertTrue(TagType.cached(source: "disk").tooltip.contains("disk"))
        XCTAssertEqual(TagType.stale.tooltip, "Stale Cache Entry")
        XCTAssertEqual(TagType.redirected(count: 3).tooltip, "Redirected 3 time(s)")
        XCTAssertEqual(TagType.rewritten.tooltip, "URL/Headers Rewritten")
    }

    func testTagTypeTooltipSource() {
        XCTAssertEqual(TagType.manual.tooltip, "Manually Created Request")
        XCTAssertEqual(TagType.replayed.tooltip, "Replayed Request")
        XCTAssertEqual(TagType.script(name: nil).tooltip, "Generated by Script")
        XCTAssertTrue(TagType.script(name: "test.js").tooltip.contains("test.js"))
        XCTAssertEqual(TagType.mock.tooltip, "Mocked Response")
    }

    func testTagTypeTooltipAnalysis() {
        let largeTooltip = TagType.large(size: 10485760).tooltip // 10MB
        XCTAssertTrue(largeTooltip.contains("10"))

        XCTAssertEqual(TagType.binary.tooltip, "Binary Content")
        XCTAssertEqual(TagType.breakpoint.tooltip, "Breakpoint Active")
    }

    // MARK: - TagType Hashable Tests

    func testTagTypeHashableSimpleCases() {
        let tag1 = TagType.h2
        let tag2 = TagType.h2
        let tag3 = TagType.h3

        XCTAssertEqual(tag1, tag2)
        XCTAssertNotEqual(tag1, tag3)
    }

    func testTagTypeHashableWithAssociatedValues() {
        let retry1 = TagType.retry(count: 3)
        let retry2 = TagType.retry(count: 3)
        let retry3 = TagType.retry(count: 5)

        XCTAssertEqual(retry1, retry2)
        XCTAssertNotEqual(retry1, retry3)
    }

    func testTagTypeHashableWithOptionalAssociatedValues() {
        let tls1 = TagType.tlsPassthrough(reason: "pinning")
        let tls2 = TagType.tlsPassthrough(reason: "pinning")
        let tls3 = TagType.tlsPassthrough(reason: nil)

        XCTAssertEqual(tls1, tls2)
        XCTAssertNotEqual(tls1, tls3)
    }

    func testTagTypeHashableInSet() {
        var tagSet: Set<TagType> = []

        tagSet.insert(.h2)
        tagSet.insert(.h2) // Duplicate
        tagSet.insert(.h3)

        XCTAssertEqual(tagSet.count, 2)
    }

    func testTagTypeHashableInDictionary() {
        var tagDict: [TagType: String] = [:]

        tagDict[.failed] = "error"
        tagDict[.failed] = "updated" // Override
        tagDict[.timeout] = "slow"

        XCTAssertEqual(tagDict.count, 2)
        XCTAssertEqual(tagDict[.failed], "updated")
    }

    // MARK: - SelectVisibleTags Tests

    func testSelectVisibleTagsEmptyArray() {
        let result = selectVisibleTags(from: [], maxVisible: 3)
        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertEqual(result.overflow, 0)
    }

    func testSelectVisibleTagsLessThanMax() {
        let tags: [TagType] = [.h2, .failed]
        let result = selectVisibleTags(from: tags, maxVisible: 3)

        XCTAssertEqual(result.visible.count, 2)
        XCTAssertEqual(result.overflow, 0)
    }

    func testSelectVisibleTagsExactlyMax() {
        let tags: [TagType] = [.h2, .failed, .timeout]
        let result = selectVisibleTags(from: tags, maxVisible: 3)

        XCTAssertEqual(result.visible.count, 3)
        XCTAssertEqual(result.overflow, 0)
    }

    func testSelectVisibleTagsMoreThanMax() {
        let tags: [TagType] = [.h2, .h3, .ws, .sse]
        let result = selectVisibleTags(from: tags, maxVisible: 3)

        XCTAssertEqual(result.visible.count, 3)
        XCTAssertEqual(result.overflow, 1)
    }

    func testSelectVisibleTagsCriticalPriority() {
        let tags: [TagType] = [.failed, .timeout, .h2, .h3, .ws]
        let result = selectVisibleTags(from: tags, maxVisible: 3)

        // Critical tags should be included
        XCTAssertTrue(result.visible.contains(.failed))
        XCTAssertTrue(result.visible.contains(.timeout))
        XCTAssertEqual(result.visible.count, 3)
        XCTAssertEqual(result.overflow, 2)
    }

    func testSelectVisibleTagsAllCritical() {
        let tags: [TagType] = [.failed, .timeout, .blocked, .cancelled]
        let result = selectVisibleTags(from: tags, maxVisible: 2)

        // All critical, only first 2 visible
        XCTAssertEqual(result.visible.count, 2)
        XCTAssertEqual(result.overflow, 2)
    }

    func testSelectVisibleTagsPriorityOrder() {
        let tags: [TagType] = [.binary, .failed, .h2, .manual]
        let result = selectVisibleTags(from: tags, maxVisible: 3)

        // Critical first, then high, then medium
        XCTAssertTrue(result.visible.contains(.failed)) // critical
        XCTAssertTrue(result.visible.contains(.h2)) // high
        XCTAssertTrue(result.visible.contains(.manual)) // medium
        XCTAssertEqual(result.overflow, 1)
    }

    func testSelectVisibleTagsStableSort() {
        let tags: [TagType] = [.h2, .h3, .ws]
        let result1 = selectVisibleTags(from: tags, maxVisible: 2)
        let result2 = selectVisibleTags(from: tags, maxVisible: 2)

        // Results should be consistent
        XCTAssertEqual(result1.visible, result2.visible)
    }

    func testSelectVisibleTagsWithZeroMax() {
        let tags: [TagType] = [.h2, .failed]
        let result = selectVisibleTags(from: tags, maxVisible: 0)

        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertEqual(result.overflow, 2)
    }

    func testSelectVisibleTagsOnlyCritical() {
        let tags: [TagType] = [.failed]
        let result = selectVisibleTags(from: tags, maxVisible: 3)

        XCTAssertEqual(result.visible.count, 1)
        XCTAssertEqual(result.overflow, 0)
        XCTAssertEqual(result.visible.first, .failed)
    }

    // MARK: - Edge Cases

    func testTagTypeRetryWithZeroCount() {
        let tag = TagType.retry(count: 0)
        XCTAssertEqual(tag.displayText, "Retry ×0")
        XCTAssertEqual(tag.priority, .low)
    }

    func testTagTypeRetryWithNegativeCount() {
        let tag = TagType.retry(count: -1)
        XCTAssertEqual(tag.displayText, "Retry ×-1")
    }

    func testTagTypeTLSPassthroughWithEmptyReason() {
        let tag = TagType.tlsPassthrough(reason: "")
        XCTAssertTrue(tag.tooltip.contains("()"))
    }

    func testTagTypeSlowWithZeroDuration() {
        let tag = TagType.slow(duration: 0)
        XCTAssertEqual(tag.displayText, "Slow")
        XCTAssertEqual(tag.priority, .high)
    }

    func testTagTypeSlowWithNegativeDuration() {
        let tag = TagType.slow(duration: -1.0)
        XCTAssertEqual(tag.displayText, "Slow")
    }

    func testTagTypeStalledWithZeroDuration() {
        let tag = TagType.stalled(duration: 0)
        XCTAssertEqual(tag.displayText, "Stalled")
    }

    func testTagTypeCachedWithEmptySource() {
        let tag = TagType.cached(source: "")
        XCTAssertTrue(tag.tooltip.contains("Cache"))
    }

    func testTagTypeRedirectedWithZeroCount() {
        let tag = TagType.redirected(count: 0)
        XCTAssertEqual(tag.displayText, "Redirected")
        XCTAssertEqual(tag.tooltip, "Redirected 0 time(s)")
    }

    func testTagTypeScriptWithEmptyName() {
        let tag = TagType.script(name: "")
        XCTAssertEqual(tag.displayText, "Script")
    }

    func testTagTypeLargeWithZeroSize() {
        let tag = TagType.large(size: 0)
        XCTAssertEqual(tag.displayText, "Large")
    }

    func testTagTypeLargeWithNegativeSize() {
        let tag = TagType.large(size: -1)
        XCTAssertEqual(tag.displayText, "Large")
    }

    func testSelectVisibleTagsWithDuplicates() {
        let tags: [TagType] = [.h2, .h2, .h3]
        let result = selectVisibleTags(from: tags, maxVisible: 3)

        XCTAssertEqual(result.visible.count, 3)
        XCTAssertEqual(result.overflow, 0)
    }

    func testSelectVisibleTagsWithMaxOne() {
        let tags: [TagType] = [.failed, .h2, .manual]
        let result = selectVisibleTags(from: tags, maxVisible: 1)

        XCTAssertEqual(result.visible.count, 1)
        XCTAssertEqual(result.visible.first, .failed) // Critical priority
        XCTAssertEqual(result.overflow, 2)
    }

    func testSelectVisibleTagsWithLargeMax() {
        let tags: [TagType] = [.h2, .h3]
        let result = selectVisibleTags(from: tags, maxVisible: 100)

        XCTAssertEqual(result.visible.count, 2)
        XCTAssertEqual(result.overflow, 0)
    }
}
