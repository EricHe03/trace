//
//  CustomActivitiesTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
import UIKit
@testable import Trace
@testable import TraceCore
@testable import TraceUI

final class CustomActivitiesTests: XCTestCase {
    // MARK: - CopyAsCurlActivity Tests

    func testCopyAsCurlActivity_ActivityType() {
        // Given
        let activity = CopyAsCurlActivity()

        // When
        let type = activity.activityType

        // Then
        XCTAssertEqual(type?.rawValue, "com.trace.copyAsCurl")
    }

    func testCopyAsCurlActivity_ActivityTitle() {
        // Given
        let activity = CopyAsCurlActivity()

        // When
        let title = activity.activityTitle

        // Then
        XCTAssertEqual(title, "Copy as cURL")
    }

    func testCopyAsCurlActivity_ActivityImage() {
        // Given
        let activity = CopyAsCurlActivity()

        // When
        let image = activity.activityImage

        // Then
        XCTAssertNotNil(image)
    }

    func testCopyAsCurlActivity_CanPerform_WithCurlCommand() {
        // Given
        let activity = CopyAsCurlActivity()
        let curlCommand = "curl -X GET https://example.com"
        let activityItems: [Any] = [curlCommand]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertTrue(canPerform)
    }

    func testCopyAsCurlActivity_CanPerform_WithNonCurlString() {
        // Given
        let activity = CopyAsCurlActivity()
        let nonCurlString = "Not a curl command"
        let activityItems: [Any] = [nonCurlString]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertFalse(canPerform)
    }

    func testCopyAsCurlActivity_CanPerform_WithEmptyArray() {
        // Given
        let activity = CopyAsCurlActivity()
        let activityItems: [Any] = []

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertFalse(canPerform)
    }

    func testCopyAsCurlActivity_CanPerform_WithURL() {
        // Given
        let activity = CopyAsCurlActivity()
        let url = URL(string: "https://example.com")!
        let activityItems: [Any] = [url]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertFalse(canPerform)
    }

    func testCopyAsCurlActivity_PrepareWithCurlCommand() {
        // Given
        let activity = CopyAsCurlActivity()
        let curlCommand = "curl -X POST https://example.com"
        let activityItems: [Any] = [curlCommand]

        // When
        activity.prepare(withActivityItems: activityItems)

        // Then - No crash and command is prepared
        XCTAssertTrue(true)
    }

    func testCopyAsCurlActivity_Perform_CopiesCommandToPasteboard() {
        // Given
        let activity = CopyAsCurlActivity()
        let curlCommand = "curl -X GET https://example.com"
        let activityItems: [Any] = [curlCommand]

        UIPasteboard.general.string = nil

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then
        XCTAssertEqual(UIPasteboard.general.string, curlCommand)
    }

    func testCopyAsCurlActivity_Perform_WithMultipleCurlCommands() {
        // Given
        let activity = CopyAsCurlActivity()
        let command1 = "curl -X GET https://example.com"
        let command2 = "curl -X POST https://example.org"
        let activityItems: [Any] = [command1, command2]

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then - Should copy the first curl command
        XCTAssertEqual(UIPasteboard.general.string, command1)
    }

    // MARK: - CopyURLActivity Tests

    func testCopyURLActivity_ActivityType() {
        // Given
        let activity = CopyURLActivity()

        // When
        let type = activity.activityType

        // Then
        XCTAssertEqual(type?.rawValue, "com.trace.copyURL")
    }

    func testCopyURLActivity_ActivityTitle() {
        // Given
        let activity = CopyURLActivity()

        // When
        let title = activity.activityTitle

        // Then
        XCTAssertEqual(title, "Copy URL")
    }

    func testCopyURLActivity_ActivityImage() {
        // Given
        let activity = CopyURLActivity()

        // When
        let image = activity.activityImage

        // Then
        XCTAssertNotNil(image)
    }

    func testCopyURLActivity_CanPerform_WithURL() {
        // Given
        let activity = CopyURLActivity()
        let url = URL(string: "https://example.com")!
        let activityItems: [Any] = [url]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertTrue(canPerform)
    }

    func testCopyURLActivity_CanPerform_WithHTTPString() {
        // Given
        let activity = CopyURLActivity()
        let urlString = "https://example.com"
        let activityItems: [Any] = [urlString]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertTrue(canPerform)
    }

    func testCopyURLActivity_CanPerform_WithNonURLString() {
        // Given
        let activity = CopyURLActivity()
        let nonURLString = "Not a URL"
        let activityItems: [Any] = [nonURLString]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertFalse(canPerform)
    }

    func testCopyURLActivity_Perform_CopiesURLToPasteboard() {
        // Given
        let activity = CopyURLActivity()
        let url = URL(string: "https://example.com")!
        let activityItems: [Any] = [url]

        UIPasteboard.general.string = nil

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then
        XCTAssertEqual(UIPasteboard.general.string, "https://example.com")
    }

    func testCopyURLActivity_Perform_WithStringURL() {
        // Given
        let activity = CopyURLActivity()
        let urlString = "https://example.org/path?query=value"
        let activityItems: [Any] = [urlString]

        UIPasteboard.general.string = nil

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then
        XCTAssertEqual(UIPasteboard.general.string, urlString)
    }

    // MARK: - ExportAsHARActivity Tests

    func testExportAsHARActivity_ActivityType() {
        // Given
        let activity = ExportAsHARActivity()

        // When
        let type = activity.activityType

        // Then
        XCTAssertEqual(type?.rawValue, "com.trace.exportAsHAR")
    }

    func testExportAsHARActivity_ActivityTitle() {
        // Given
        let activity = ExportAsHARActivity()

        // When
        let title = activity.activityTitle

        // Then
        XCTAssertEqual(title, "Export as HAR")
    }

    func testExportAsHARActivity_ActivityImage() {
        // Given
        let activity = ExportAsHARActivity()

        // When
        let image = activity.activityImage

        // Then
        XCTAssertNotNil(image)
    }

    func testExportAsHARActivity_CanPerform_WithoutHandler() {
        // Given
        let activity = ExportAsHARActivity()
        let activityItems: [Any] = ["test"]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertFalse(canPerform, "Should not perform without handler")
    }

    func testExportAsHARActivity_CanPerform_WithHandler() {
        // Given
        let activity = ExportAsHARActivity()
        activity.harExportHandler = {}
        let activityItems: [Any] = ["test"]

        // When
        let canPerform = activity.canPerform(withActivityItems: activityItems)

        // Then
        XCTAssertTrue(canPerform, "Should perform when handler is set")
    }

    func testExportAsHARActivity_Perform_CallsHandler() {
        // Given
        let expectation = self.expectation(description: "Handler called")
        let activity = ExportAsHARActivity()
        activity.harExportHandler = {
            expectation.fulfill()
        }
        let activityItems: [Any] = ["test"]

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then
        wait(for: [expectation], timeout: 1.0)
    }

    func testExportAsHARActivity_Perform_WithoutHandler() {
        // Given
        let activity = ExportAsHARActivity()
        let activityItems: [Any] = ["test"]

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then - Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - ActivityHelper Tests

    func testActivityHelper_DefaultExcludedActivityTypes() {
        // Given/When
        let excludedTypes = ActivityHelper.defaultExcludedActivityTypes()

        // Then
        XCTAssertFalse(excludedTypes.isEmpty)
        XCTAssertTrue(excludedTypes.contains(.postToFacebook))
        XCTAssertTrue(excludedTypes.contains(.postToTwitter))
        XCTAssertTrue(excludedTypes.contains(.assignToContact))
        XCTAssertTrue(excludedTypes.contains(.addToReadingList))
    }

    func testActivityHelper_DefaultExcludedActivityTypes_Count() {
        // Given/When
        let excludedTypes = ActivityHelper.defaultExcludedActivityTypes()

        // Then - Should have all specified types
        // Do not assert an exact count since system-provided activity types vary by OS version.
        XCTAssertGreaterThanOrEqual(excludedTypes.count, 10)
    }

    func testActivityHelper_CustomActivitiesForRequest() {
        // Given/When
        let activities = ActivityHelper.customActivitiesForRequest()

        // Then
        XCTAssertEqual(activities.count, 2)
        XCTAssertTrue(activities[0] is CopyAsCurlActivity)
        XCTAssertTrue(activities[1] is CopyURLActivity)
    }

    func testActivityHelper_CustomActivitiesWithHAR() {
        // Given
        var handlerCalled = false
        let handler = {
            handlerCalled = true
        }

        // When
        let activities = ActivityHelper.customActivitiesWithHAR(harHandler: handler)

        // Then
        XCTAssertEqual(activities.count, 3)
        XCTAssertTrue(activities[0] is CopyAsCurlActivity)
        XCTAssertTrue(activities[1] is CopyURLActivity)
        XCTAssertTrue(activities[2] is ExportAsHARActivity)

        // Test that the handler is set
        if let harActivity = activities[2] as? ExportAsHARActivity {
            harActivity.perform()
            XCTAssertTrue(handlerCalled)
        } else {
            XCTFail("Third activity should be ExportAsHARActivity")
        }
    }

    // MARK: - Integration Tests

    func testCustomActivities_AllHaveUniqueTypes() {
        // Given
        let curlActivity = CopyAsCurlActivity()
        let urlActivity = CopyURLActivity()
        let harActivity = ExportAsHARActivity()

        // When
        let types = [
            curlActivity.activityType,
            urlActivity.activityType,
            harActivity.activityType
        ]

        // Then
        let uniqueTypes = Set(types.compactMap { $0 })
        XCTAssertEqual(uniqueTypes.count, 3, "All activity types should be unique")
    }

    func testCustomActivities_AllHaveTitles() {
        // Given
        let activities: [UIActivity] = [
            CopyAsCurlActivity(),
            CopyURLActivity(),
            ExportAsHARActivity()
        ]

        // When/Then
        for activity in activities {
            XCTAssertNotNil(activity.activityTitle, "Activity should have a title")
            XCTAssertFalse(activity.activityTitle?.isEmpty ?? true, "Title should not be empty")
        }
    }

    func testCustomActivities_AllHaveImages() {
        // Given
        let activities: [UIActivity] = [
            CopyAsCurlActivity(),
            CopyURLActivity(),
            ExportAsHARActivity()
        ]

        // When/Then
        for activity in activities {
            XCTAssertNotNil(activity.activityImage, "Activity should have an image")
        }
    }

    // MARK: - Edge Cases

    func testCopyAsCurlActivity_WithComplexCurlCommand() {
        // Given
        let activity = CopyAsCurlActivity()
        let complexCommand = """
        curl -X POST https://example.com/api \\
          -H 'Content-Type: application/json' \\
          -H 'Authorization: Bearer token' \\
          -d '{"key": "value"}'
        """
        let activityItems: [Any] = [complexCommand]

        UIPasteboard.general.string = nil

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then
        XCTAssertEqual(UIPasteboard.general.string, complexCommand)
    }

    func testCopyURLActivity_WithURLContainingSpecialCharacters() {
        // Given
        let activity = CopyURLActivity()
        let urlString = "https://example.com/path?query=value&special=%20%21"
        let activityItems: [Any] = [urlString]

        UIPasteboard.general.string = nil

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then
        XCTAssertEqual(UIPasteboard.general.string, urlString)
    }

    func testCopyAsCurlActivity_WithMixedActivityItems() {
        // Given
        let activity = CopyAsCurlActivity()
        let curlCommand = "curl https://example.com"
        let url = URL(string: "https://example.org")!
        let activityItems: [Any] = [url, curlCommand, "random string"]

        UIPasteboard.general.string = nil

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then
        XCTAssertEqual(UIPasteboard.general.string, curlCommand)
    }

    func testCopyURLActivity_WithMultipleURLs() {
        // Given
        let activity = CopyURLActivity()
        let url1 = URL(string: "https://example.com")!
        let url2 = URL(string: "https://example.org")!
        let activityItems: [Any] = [url1, url2]

        UIPasteboard.general.string = nil

        // When
        activity.prepare(withActivityItems: activityItems)
        activity.perform()

        // Then - Should copy the first URL
        XCTAssertEqual(UIPasteboard.general.string, "https://example.com")
    }

    func testExportAsHARActivity_MultipleHandlerCalls() {
        // Given
        var callCount = 0
        let activity = ExportAsHARActivity()
        activity.harExportHandler = {
            callCount += 1
        }

        // When
        activity.perform()
        activity.perform()
        activity.perform()

        // Then
        XCTAssertEqual(callCount, 3)
    }

    func testActivityHelper_ExcludedTypes_ContainsSocialMedia() {
        // Given/When
        let excluded = ActivityHelper.defaultExcludedActivityTypes()

        // Then - Verify all social media types are excluded
        let socialTypes: [UIActivity.ActivityType] = [
            .postToFacebook,
            .postToTwitter,
            .postToWeibo,
            .postToVimeo,
            .postToFlickr,
            .postToTencentWeibo
        ]

        for type in socialTypes {
            XCTAssertTrue(excluded.contains(type), "\(type) should be excluded")
        }
    }

    func testActivityHelper_ExcludedTypes_ContainsContactAndReading() {
        // Given/When
        let excluded = ActivityHelper.defaultExcludedActivityTypes()

        // Then
        XCTAssertTrue(excluded.contains(.assignToContact))
        XCTAssertTrue(excluded.contains(.addToReadingList))
        XCTAssertTrue(excluded.contains(.openInIBooks))
        XCTAssertTrue(excluded.contains(.markupAsPDF))
    }

    // MARK: - Pasteboard Cleanup

    override func tearDown() {
        // Clean up pasteboard after each test
        UIPasteboard.general.string = nil
        super.tearDown()
    }
}
