//
//  PortScopeUITests.swift
//  PortScopeUITests
//
//  End-to-end UI tests that drive the live app and exercise the
//  navigation/settings surface. They run against whatever Mac is hosting
//  the test, so we assert on chassis-independent strings (Refresh menu,
//  Preferences window title, sidebar subgroup headers that are always
//  present) rather than anything that depends on what's plugged in.
//

import XCTest

final class PortScopeUITests: XCTestCase {

    /// Launches the app freshly each test. UI tests share the host process
    /// across `XCTestCase` instances by default, but `XCUIApplication.launch`
    /// terminates and relaunches — so each test gets a clean window.
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Argument prefixed with `--uitest` is ignored by `CLIRequest.from`
        // (the unknown-argv fall-through), but having a marker makes it
        // easy to spot launches from the test runner in any future logging.
        app.launchArguments = ["--uitest"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Launch

    @MainActor
    func testAppLaunchesAndShowsMainWindow() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Main window didn't appear within 10 s")
        // ContentView has a `frame(minWidth: 980, minHeight: 600)` modifier,
        // so the window must always exceed that size. If it doesn't we've
        // regressed the split view's intrinsic content sizing.
        XCTAssertGreaterThanOrEqual(window.frame.width, 980,
                                    "Window width below the 980 minWidth declared in ContentView")
    }

    // MARK: - Sidebar

    @MainActor
    func testSidebarRendersAtLeastOnePortSubgroup() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Any real Mac ships at least one of these subgroups — the
        // SidebarView assembles them under the Physical Device section by
        // walking the chassis's accessories. We don't assume which subset
        // exists (a laptop has USB-C + MagSafe; a Studio has USB-C + USB-A
        // + HDMI + SD + Ethernet) — just that *some* connector subgroup is
        // present.
        let possibleHeaders = ["USB-C", "USB-A", "HDMI", "SD Card",
                               "Ethernet", "Power", "MagSafe"]
        let found = possibleHeaders.contains { header in
            app.staticTexts[header].waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, """
        Expected at least one of \(possibleHeaders) as a sidebar subgroup \
        header. This means SidebarView didn't render any connector-family \
        subgroup for the current chassis.
        """)
    }

    @MainActor
    func testSidebarShowsContentUnavailableUntilSelection() throws {
        // No selection at launch → ContentView shows ContentUnavailableView
        // with the title "Select a port or device".
        let prompt = app.staticTexts["Select a port or device"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5),
                      "Empty-state prompt should render before any sidebar row is selected")
    }

    // MARK: - Refresh command

    @MainActor
    func testRefreshKeyboardShortcutDoesNotCrashTheApp() throws {
        // ⌘R fires the Refresh notification (`portScopeApp.swift`). We can't
        // assert state from the outside, but if the shortcut crashed the
        // app the next assertion would fail.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("r", modifierFlags: .command)

        // Window survives the refresh.
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "Main window vanished after ⌘R — Refresh handler probably crashed")
    }

    // MARK: - Preferences

    @MainActor
    func testPreferencesWindowExposesEveryToggle() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Open Settings via the standard ⌘, shortcut. PortScopeApp declares
        // a `Settings { SettingsView() }` scene so this opens the SwiftUI
        // settings window.
        app.typeKey(",", modifierFlags: .command)

        // SettingsView labels each toggle with a stable string. We don't
        // toggle anything (that would mutate user defaults and pollute the
        // host) — just check the labels render. Each toggle's *label* is a
        // visible static text node alongside the actual control.
        let toggles = [
            "Show Hardware Buses",
            "Show All Devices",
            "Show Built-in Devices",
            "Show Intermediate USB Hubs"
        ]
        for label in toggles {
            let row = app.staticTexts[label]
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "Settings window is missing toggle label '\(label)'")
        }
    }

    // MARK: - Performance

    @MainActor
    func testLaunchPerformance() throws {
        // Measures cold-launch performance. The host bundle includes ten
        // scanners running on startup, several of which spawn `system_profiler`
        // — so this is a useful regression guard against accidentally slipping
        // a heavy synchronous scan into `application(_:didFinishLaunching)`.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
