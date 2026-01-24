//
//  TraceUITests.swift
//  TraceUITests
//
//  Created by Justin on 2026/01/10.
//

import XCTest

final class TraceUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Smoke check to ensure the app is running in the foreground.
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testSettingsNavigation() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let captureOptions = app.tables.staticTexts["Capture Options"]
        XCTAssertTrue(captureOptions.waitForExistence(timeout: 5))
        captureOptions.tap()
        XCTAssertTrue(app.navigationBars["Capture Options"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let domainFilters = app.tables.staticTexts["Domain Filters"]
        XCTAssertTrue(domainFilters.waitForExistence(timeout: 5))
        domainFilters.tap()
        XCTAssertTrue(app.navigationBars["Domain Filters"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let advancedSettings = app.tables.staticTexts["Advanced Settings"]
        XCTAssertTrue(advancedSettings.waitForExistence(timeout: 5))
        advancedSettings.tap()
        XCTAssertTrue(app.navigationBars["Advanced Settings"].waitForExistence(timeout: 5))
    }
}
