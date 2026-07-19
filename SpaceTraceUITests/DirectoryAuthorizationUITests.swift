import XCTest

final class DirectoryAuthorizationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUnconfiguredStateOffersSystemPickerAction() {
        let app = launch(scenario: "unconfigured")
        openPermissions(in: app)

        assertStatus("尚未选择目录", in: app)
        XCTAssertTrue(app.buttons["choose-directory-button"].exists)
    }

    @MainActor
    func testStaleStateOffersReauthorizationWithoutSilentRefresh() {
        let app = launch(scenario: "stale")
        openPermissions(in: app)

        assertStatus("需要重新授权", in: app)
        XCTAssertTrue(app.buttons["reauthorize-directory-button"].exists)
        XCTAssertTrue(app.buttons["revoke-directory-button"].exists)
        XCTAssertFalse(app.buttons["refresh-directory-button"].exists)
    }

    @MainActor
    func testUnavailableExternalScopeOffersRetryAndReauthorization() {
        let app = launch(scenario: "unavailable")
        openPermissions(in: app)

        assertStatus("目录当前不可用", in: app)
        XCTAssertTrue(app.buttons["refresh-directory-button"].exists)
        XCTAssertTrue(app.buttons["reauthorize-directory-button"].exists)
    }

    @MainActor
    func testAuthorizedStateShowsExactRootAndRevocation() {
        let app = launch(scenario: "authorized")
        openPermissions(in: app)

        assertStatus("目录已授权", detail: "/Volumes/SpaceTraceFixture/Selected", in: app)
        XCTAssertTrue(app.buttons["revoke-directory-button"].exists)
    }

    @MainActor
    func testOverviewRoutesToPermissionManagementWithoutInventingScanData() {
        let app = launch(scenario: "unconfigured")

        let readiness = app.staticTexts["overview-readiness-title"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 3))
        XCTAssertTrue(String(describing: readiness.value).contains("先选择一个要观察的目录"))
        XCTAssertTrue(app.buttons["overview-permissions-button"].exists)
        XCTAssertFalse(app.staticTexts["24 小时变化"].exists)
    }

    @MainActor
    private func assertStatus(
        _ title: String,
        detail: String? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = app.staticTexts["authorization-status-title"]
        XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
        let renderedValue = String(describing: element.value)
        XCTAssertTrue(renderedValue.contains(title), file: file, line: line)
        if let detail {
            XCTAssertTrue(renderedValue.contains(detail), file: file, line: line)
        }
    }

    @MainActor
    private func openPermissions(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let destination = app.staticTexts["目录授权"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3), file: file, line: line)
        destination.click()
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SPACETRACE_UI_TEST_SCENARIO"] = scenario
        app.launch()
        return app
    }
}
