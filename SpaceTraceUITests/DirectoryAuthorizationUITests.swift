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

        assertStatus("部分目录需要处理", in: app)
        XCTAssertTrue(app.buttons["reauthorize-directory-button-scope-ui-stale"].exists)
        XCTAssertTrue(app.buttons["revoke-directory-button-scope-ui-stale"].exists)
        XCTAssertFalse(app.buttons["refresh-directory-button-scope-ui-stale"].exists)
    }

    @MainActor
    func testUnavailableExternalScopeOffersRetryAndReauthorization() {
        let app = launch(scenario: "unavailable")
        openPermissions(in: app)

        assertStatus("部分目录需要处理", in: app)
        XCTAssertTrue(app.buttons["refresh-directory-button-scope-ui-unavailable"].exists)
        XCTAssertTrue(app.buttons["reauthorize-directory-button-scope-ui-unavailable"].exists)
    }

    @MainActor
    func testAuthorizedStateShowsExactRootAndRevocation() {
        let app = launch(scenario: "authorized")
        openPermissions(in: app)

        assertStatus("目录授权已就绪", in: app)
        XCTAssertTrue(app.staticTexts["/Volumes/SpaceTraceFixture/Selected"].exists)
        XCTAssertTrue(app.buttons["revoke-directory-button-scope-ui-authorized"].exists)
    }

    @MainActor
    func testMultipleScopesRemainIndependentlyActionable() {
        let app = launch(scenario: "multiple")
        openPermissions(in: app)

        assertStatus("部分目录需要处理", in: app)
        XCTAssertTrue(app.buttons["add-directory-button"].exists)
        XCTAssertTrue(app.buttons["revoke-directory-button-scope-ui-a"].exists)
        XCTAssertTrue(app.buttons["revoke-directory-button-scope-ui-b"].exists)
        XCTAssertTrue(app.buttons["reauthorize-directory-button-scope-ui-stale"].exists)
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
    func testOverviewShowsVolumeHistoryWithoutInventingDirectoryEvidence() {
        let app = launch(scenario: "authorized")

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "overview-history-loaded")
                .firstMatch
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.staticTexts["启动数据卷可用空间"].firstMatch.exists
        )
        XCTAssertTrue(
            app.staticTexts["可见目录逻辑大小"].firstMatch.exists
        )
        XCTAssertTrue(metric(containing: "磁盘少了多少", in: app).exists)
        XCTAssertTrue(
            metric(containing: "授权目录能解释：证据不足", in: app).exists
        )
        XCTAssertTrue(
            metric(containing: "仍无法归因：证据不足", in: app).exists
        )
    }

    @MainActor
    private func assertStatus(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = app.staticTexts["authorization-status-title"]
        XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
        let renderedValue = String(describing: element.value)
        XCTAssertTrue(renderedValue.contains(title), file: file, line: line)
    }

    @MainActor
    private func metric(
        containing text: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
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
