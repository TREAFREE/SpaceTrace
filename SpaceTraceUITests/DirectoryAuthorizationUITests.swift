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
    func testUnconfiguredStateExposesAccessibleActionAndPrivacyBoundary() {
        let app = launch(scenario: "unconfigured")
        openPermissions(in: app)

        let action = app.buttons["choose-directory-button"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertEqual(action.label, "选择目录…")
        XCTAssertTrue(action.isHittable)

        let detail = app.staticTexts["authorization-status-detail"]
        XCTAssertTrue(detail.exists)
        XCTAssertTrue(
            String(describing: detail.value)
                .contains("系统目录选择器只会授权你明确确认的位置")
        )

        let privacy = app.descendants(matching: .any)
            .matching(identifier: "authorization-privacy-note")
            .firstMatch
        XCTAssertTrue(privacy.exists)
        let privacyValue = String(describing: privacy.value)
        XCTAssertTrue(privacyValue.contains("授权为只读"))
        XCTAssertTrue(privacyValue.contains("不会删除"))
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

        let change = app.buttons["reauthorize-directory-button-scope-ui-authorized"]
        XCTAssertTrue(change.exists)
        XCTAssertEqual(change.label, "更换目录…")
        XCTAssertTrue(change.isHittable)

        let revoke = app.buttons["revoke-directory-button-scope-ui-authorized"]
        XCTAssertTrue(revoke.exists)
        XCTAssertEqual(revoke.label, "移除授权")
        XCTAssertTrue(revoke.isHittable)
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
    func testOverviewSeparatesCurrentFindingsFromInvalidatedAuditEvidence() {
        let app = launch(scenario: "authorized")

        let loaded = element(
            identifier: "historical-findings-loaded",
            in: app
        )
        XCTAssertTrue(loaded.waitForExistence(timeout: 5))
        let firstFinding = metric(containing: "Cache · 增长", in: app)
        scrollToHittable(firstFinding, in: app)
        XCTAssertTrue(firstFinding.exists)
        XCTAssertTrue(
            metric(containing: "规则 logs.fixture v1", in: app).exists
        )
        XCTAssertTrue(
            metric(containing: "完整证据", in: app).exists
        )
        XCTAssertTrue(
            metric(containing: "After · 位置变化", in: app).exists
        )
        XCTAssertTrue(
            metric(containing: "Old · 已观测到消失", in: app).exists
        )
        XCTAssertFalse(
            metric(containing: "Invalidated · 增长", in: app).exists
        )

        let disclosure = app.buttons[
            "historical-findings-invalidated-disclosure"
        ]
        scrollToHittable(disclosure, in: app)
        XCTAssertTrue(disclosure.isHittable)
        disclosure.click()
        let expanded = NSPredicate(format: "value == %@", "已展开")
        expectation(for: expanded, evaluatedWith: disclosure)
        waitForExpectations(timeout: 3)

        let invalidated = element(
            identifier: "historical-finding-invalidated-4",
            in: app
        )
        XCTAssertTrue(invalidated.waitForExistence(timeout: 3))
    }

    @MainActor
    func testHistoryDisabledRemainsTypedAndCanBeReenabled() {
        let app = launch(scenario: "history-disabled")

        XCTAssertTrue(
            element(identifier: "historical-findings-history-disabled", in: app)
                .waitForExistence(timeout: 5)
        )
        let enable = app.buttons["enable-path-history"]
        scrollToHittable(enable, in: app)
        XCTAssertTrue(enable.isHittable)
        XCTAssertFalse(
            element(identifier: "historical-finding-current-1", in: app).exists
        )
    }

    @MainActor
    func testBaselineUnavailableIsNotPresentedAsAnEmptyHistory() {
        let app = launch(scenario: "baseline-unavailable")

        XCTAssertTrue(
            element(identifier: "historical-findings-baseline-unavailable", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            element(identifier: "historical-findings-empty", in: app).exists
        )
    }

    @MainActor
    func testHistoryOffRequiresExplicitDestructiveConfirmation() {
        let app = launch(scenario: "authorized")

        let disable = app.buttons["disable-path-history"]
        scrollToHittable(disable, in: app)
        XCTAssertTrue(disable.isHittable)
        disable.click()

        let confirmation = app.buttons["confirm-history-off"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertEqual(confirmation.label, "关闭并清除历史")
        XCTAssertTrue(
            app.staticTexts[
                "这会删除路径历史、历史基线、变化记录和证据已失效的审计记录，且无法撤销。目录授权、当前监控状态和不含路径的卷空间记录会保留。"
            ].exists
        )
        app.sheets.firstMatch.buttons["取消"].click()
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
    private func element(
        identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    @MainActor
    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        let scrollView = app.scrollViews.allElementsBoundByIndex.max {
            $0.frame.width < $1.frame.width
        } ?? app.scrollViews.firstMatch
        for _ in 0..<20 where element.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -120)
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
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SPACETRACE_UI_TEST_SCENARIO"] = scenario
        app.launch()
        return app
    }
}
