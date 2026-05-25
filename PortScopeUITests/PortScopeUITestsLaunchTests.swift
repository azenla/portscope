//
//  PortScopeUITestsLaunchTests.swift
//  PortScopeUITests
//
//  Launch-screenshot smoke test. Xcode Test Plans can use this to detect
//  visual regressions (the screenshot is attached to the test result and
//  kept across runs).
//

import XCTest

final class PortScopeUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        // PortScope has no per-target UI configurations (light/dark are user
        // prefs, not configurations), so this could be false. Leaving it true
        // means if a future test plan adds a Dark Mode UI config, the launch
        // screenshot is captured for both automatically.
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Wait for the main window before screenshotting — Apple Silicon
        // hosts sometimes take a beat to set up the IOKit notification
        // matching dictionaries, and a screenshot taken too early would
        // capture an empty window.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "App didn't show a main window within 10 s")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
