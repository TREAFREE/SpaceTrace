SHELL := /bin/zsh

PROJECT := SpaceTrace.xcodeproj
SCHEME := SpaceTrace
DESTINATION := platform=macOS,arch=arm64
PACKAGE_PATH := Packages/SpaceTraceKit
DERIVED_DATA_ROOT := build/DerivedData

.PHONY: verify hygiene architecture-check package-test package-concurrency-audit xcode-list app-build-debug app-test-unit app-build-release

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

xcode-list:
	xcodebuild -list -project "$(PROJECT)" -clonedSourcePackagesDirPath "$(DERIVED_DATA_ROOT)/SourcePackages"

app-build-debug:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA_ROOT)/Debug" CODE_SIGNING_ALLOWED=NO build

app-test-unit:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA_ROOT)/Tests" CODE_SIGNING_ALLOWED=NO -only-testing:SpaceTraceTests test

app-build-release:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA_ROOT)/Release" CODE_SIGNING_ALLOWED=NO build
