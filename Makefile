SHELL := /bin/zsh

PROJECT := SpaceTrace.xcodeproj
SCHEME := SpaceTrace
DESTINATION := platform=macOS,arch=arm64
PACKAGE_PATH := Packages/SpaceTraceKit
DERIVED_DATA_ROOT := build/DerivedData

.PHONY: verify hygiene architecture-check historical-ledger-privacy-test historical-ledger-privacy released-schema-fixtures package-test package-concurrency-audit package-background-lifecycle-qualification package-background-soak-qualification package-apfs-image-qualification package-apfs-reconciliation-qualification persistence-benchmark package-release-candidate package-release-candidate-test qualify-release-candidate xcode-list app-build-debug app-test-unit app-test-ui app-build-release

verify: hygiene architecture-check historical-ledger-privacy-test historical-ledger-privacy released-schema-fixtures package-test package-concurrency-audit xcode-list app-build-debug app-test-unit app-build-release

hygiene:
	git diff --check
	git diff-tree --check --root -r -m HEAD
	! rg --line-number '[[:blank:]]+$$' --glob '!docs/research/*.html' .

architecture-check:
	./Scripts/check-architecture.sh

historical-ledger-privacy-test:
	bash Scripts/Tests/check-historical-ledger-privacy-tests.sh

historical-ledger-privacy:
	./Scripts/check-historical-ledger-privacy.sh

released-schema-fixtures:
	bash Scripts/verify-released-schema-fixtures.sh

package-test:
	swift test --package-path "$(PACKAGE_PATH)"

package-concurrency-audit:
	swift test --package-path "$(PACKAGE_PATH)" -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

package-background-lifecycle-qualification:
	swift test --package-path "$(PACKAGE_PATH)" --filter StorageHistoryBackgroundCoordinatorTests
	swift test --package-path "$(PACKAGE_PATH)" --filter StartupVolume24HourStatusQueryTests

package-background-soak-qualification:
	swift test --package-path "$(PACKAGE_PATH)" --filter StorageHistorySoakDiagnosticsTests
	swift test --package-path "$(PACKAGE_PATH)" --filter BoundedStorageHistorySoakLogWriterTests
	swift test --package-path "$(PACKAGE_PATH)" --filter InstrumentsActivityMonitorReportTests
	swift build --package-path "$(PACKAGE_PATH)" --product SpaceTraceSoakAnalyzer
	swift build --package-path "$(PACKAGE_PATH)" --product SpaceTraceInstrumentsAnalyzer

package-apfs-image-qualification:
	SPACETRACE_RUN_APFS_IMAGE_TESTS=1 swift test --package-path "$(PACKAGE_PATH)" --filter APFSDiskImageLifecycleIntegrationTests

package-apfs-reconciliation-qualification:
	SPACETRACE_RUN_APFS_RECONCILIATION_TESTS=1 swift test --package-path "$(PACKAGE_PATH)" --filter ReconciliationKPIIntegrationTests

persistence-benchmark:
	swift run --package-path "$(PACKAGE_PATH)" -c release SpaceTracePersistenceBenchmark 500000
	swift run --package-path "$(PACKAGE_PATH)" -c release SpaceTracePersistenceBenchmark 1000000

package-release-candidate:
	@test -n "$(VERSION)" || (echo "VERSION is required" >&2; exit 64)
	@test -n "$(OUTPUT)" || (echo "OUTPUT is required" >&2; exit 64)
	./Scripts/package-release-candidate.sh --version "$(VERSION)" --output "$(OUTPUT)"

package-release-candidate-test:
	@test -n "$(VERSION)" || (echo "VERSION is required" >&2; exit 64)
	./Scripts/test-release-candidate-packaging.sh "$(VERSION)"

qualify-release-candidate:
	@test -n "$(PRIMARY_APP)" || (echo "PRIMARY_APP is required" >&2; exit 64)
	@test -n "$(REPLACEMENT_APP)" || (echo "REPLACEMENT_APP is required" >&2; exit 64)
	./Scripts/qualify-release-candidate.sh --primary "$(PRIMARY_APP)" --replacement "$(REPLACEMENT_APP)"

xcode-list:
	xcodebuild -list -project "$(PROJECT)" -clonedSourcePackagesDirPath "$(DERIVED_DATA_ROOT)/SourcePackages"

app-build-debug:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA_ROOT)/Debug" CODE_SIGNING_ALLOWED=NO build

app-test-unit:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA_ROOT)/Tests" CODE_SIGNING_ALLOWED=NO -only-testing:SpaceTraceTests test

app-test-ui:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA_ROOT)/UITests" -only-testing:SpaceTraceUITests/DirectoryAuthorizationUITests test

app-build-release:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA_ROOT)/Release" CODE_SIGNING_ALLOWED=NO build
