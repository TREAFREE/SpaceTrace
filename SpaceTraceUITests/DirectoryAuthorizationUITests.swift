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
            identifier: "historical-finding-invalidated-original-4",
            in: app
        )
        XCTAssertTrue(invalidated.waitForExistence(timeout: 3))
    }

    @MainActor
    func testOverviewShowsTypedReconciliationReadinessWithoutRelyingOnColor() {
        let authorized = launch(scenario: "authorized")
        let current = element(
            identifier: "reconciliation-status-scope-ui-authorized",
            in: authorized
        )
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(String(describing: current.value).contains("已校准至修订 8"))
        authorized.terminate()

        let stale = launch(scenario: "stale")
        let permission = element(
            identifier: "reconciliation-status-scope-ui-stale",
            in: stale
        )
        XCTAssertTrue(permission.waitForExistence(timeout: 5))
        XCTAssertTrue(String(describing: permission.value).contains("需要重新授权"))
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
        XCTAssertTrue(
            element(identifier: "reconciliation-status-scope-ui-authorized", in: app)
                .exists
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
    func testDiagnosticExportDefaultsToRedactionAndRequiresFreshRawPathConsent() {
        let app = launch(scenario: "authorized")
        let destination = app.staticTexts["诊断导出"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        destination.click()

        XCTAssertTrue(
            element(identifier: "diagnostic-export-page", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element(identifier: "diagnostic-export-path-mode", in: app).exists
        )
        XCTAssertTrue(
            element(identifier: "diagnostic-export-no-upload", in: app).exists
        )
        XCTAssertTrue(
            element(identifier: "diagnostic-export-section-coverage", in: app).exists
        )
        XCTAssertTrue(
            element(identifier: "diagnostic-export-section-selected_findings", in: app).exists
        )

        let rawPaths = app.buttons["diagnostic-export-full-paths-button"]
        XCTAssertTrue(rawPaths.isHittable)
        rawPaths.click()

        let consent = app.buttons["仅本次导出完整路径"]
        XCTAssertTrue(consent.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts[
                "完整路径可能包含用户名、项目名和私人目录名。授权只绑定当前这一次导出，下一次必须重新确认。"
            ].exists
        )
        app.sheets.firstMatch.buttons["保持默认脱敏"].click()
        XCTAssertFalse(consent.exists)
    }

    @MainActor
    func testSignedSandboxSavesARealRedactedDiagnosticExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-UI-DiagnosticExport-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let app = launch(scenario: "authorized", exportDirectory: directory)
        let destination = app.staticTexts["诊断导出"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        destination.click()

        let save = app.buttons["diagnostic-export-save-button"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()

        let savePanel = app.windows["save-panel"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 5))
        let confirmSave = savePanel.buttons["OKButton"]
        XCTAssertTrue(confirmSave.waitForExistence(timeout: 3))
        confirmSave.click()

        XCTAssertTrue(
            element(identifier: "diagnostic-export-saved", in: app)
                .waitForExistence(timeout: 5)
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let output = try XCTUnwrap(
            files.first { $0.pathExtension == "json" }
        )
        let data = try Data(contentsOf: output)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertLessThanOrEqual(data.count, 2 * 1_024 * 1_024)
        XCTAssertFalse(text.contains("SpaceTraceFixture"))
        XCTAssertFalse(text.contains("Cache"))
        XCTAssertTrue(text.contains("\"pathMode\" : \"redacted\""))
        XCTAssertTrue(text.contains("\"uploadsAutomatically\" : false"))
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
    private func launch(
        scenario: String,
        exportDirectory: URL? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SPACETRACE_UI_TEST_SCENARIO"] = scenario
        if let exportDirectory {
            app.launchEnvironment[
                "SPACETRACE_UI_TEST_EXPORT_DIRECTORY"
            ] = exportDirectory.path
        }
        app.launch()
        return app
    }
}
