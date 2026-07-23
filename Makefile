SHELL := /bin/zsh

PROJECT := SpaceTrace.xcodeproj
SCHEME := SpaceTrace
DESTINATION := platform=macOS,arch=arm64
PACKAGE_PATH := Packages/SpaceTraceKit
DERIVED_DATA_ROOT := build/DerivedData

.PHONY: verify hygiene architecture-check package-test package-concurrency-audit package-apfs-image-qualification persistence-benchmark xcode-list app-build-debug app-test-unit app-test-ui app-build-release

verify: hygiene architecture-check package-test package-concurrency-audit xcode-list app-build-debug app-test-unit app-build-release

hygiene:
	git diff --check
	git diff-tree --check --root -r -m HEAD
	! rg --line-number '[[:blank:]]+$$' --glob '!docs/research/*.html' .

architecture-check:
	./Scripts/check-architecture.sh

package-test:
	swift test --package-path "$(PACKAGE_PATH)"

package-concurrency-audit:
	swift test --package-path "$(PACKAGE_PATH)" -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

package-apfs-image-qualification:
	SPACETRACE_RUN_APFS_IMAGE_TESTS=1 swift test --package-path "$(PACKAGE_PATH)" --filter APFSDiskImageLifecycleIntegrationTests

persistence-benchmark:
	swift run --package-path "$(PACKAGE_PATH)" -c release SpaceTracePersistenceBenchmark 500000
	swift run --package-path "$(PACKAGE_PATH)" -c release SpaceTracePersistenceBenchmark 1000000

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
