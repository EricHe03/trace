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

        dismissOnboardingIfNeeded(in: app)

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let captureRules = app.staticTexts["Capture Rules"]
        scrollToElementIfNeeded(captureRules, in: app)
        XCTAssertTrue(captureRules.waitForExistence(timeout: 5))
        captureRules.tap()
        XCTAssertTrue(app.navigationBars["Capture Rules"].waitForExistence(timeout: 5))
        tapBackButton(in: app)

        let captureMode = app.staticTexts["Capture Mode"]
        scrollToElementIfNeeded(captureMode, in: app)
        XCTAssertTrue(captureMode.waitForExistence(timeout: 5))
        captureMode.tap()
        let captureModeTitleExists = app.navigationBars["Capture Mode"].waitForExistence(timeout: 5)
            || app.navigationBars["Capture Settings"].waitForExistence(timeout: 2)
        XCTAssertTrue(captureModeTitleExists)
        tapBackButton(in: app)

        let advancedSettings = app.staticTexts["Advanced"]
        scrollToElementIfNeeded(advancedSettings, in: app)
        XCTAssertTrue(advancedSettings.waitForExistence(timeout: 5))
        advancedSettings.tap()
        XCTAssertTrue(app.navigationBars["Advanced Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func dismissOnboardingIfNeeded(in app: XCUIApplication) {
        let skipSetup = app.buttons["Skip Setup"]
        if skipSetup.waitForExistence(timeout: 2) {
            skipSetup.tap()
        }

        let getStarted = app.buttons["Get Started"]
        if getStarted.waitForExistence(timeout: 2) {
            getStarted.tap()
        }
    }

    @MainActor
    private func tapBackButton(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()
    }

    @MainActor
    private func scrollToElementIfNeeded(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 4) {
        guard !element.exists else { return }

        for _ in 0 ..< maxSwipes where !element.exists {
            app.swipeDown()
        }

        for _ in 0 ..< maxSwipes where !element.exists {
            app.swipeUp()
        }
    }
}
