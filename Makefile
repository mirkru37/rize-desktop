DESTINATION ?= platform=macOS
COVERAGE_THRESHOLD ?= 50
RESULT_BUNDLE := TestResults.xcresult

.PHONY: generate build test lint format ci coverage

generate:
	xcodegen generate

build: generate
	xcodebuild -project RizeDesktop.xcodeproj -scheme RizeDesktop -configuration Debug CODE_SIGNING_ALLOWED=NO build

test: generate
	xcodebuild -project RizeDesktop.xcodeproj -scheme RizeDesktop -configuration Debug CODE_SIGNING_ALLOWED=NO test

lint:
	swiftlint --strict
	swiftformat --lint .

format:
	swiftformat .

ci: generate build test lint

# RIZ-42: mirrors the CI coverage gate locally. Requires full Xcode (not
# just Command Line Tools) since it needs xcodebuild + xccov. Override the
# destination with DESTINATION=... (defaults to the local Mac).
coverage: generate
	rm -rf $(RESULT_BUNDLE)
	xcodebuild -project RizeDesktop.xcodeproj -scheme RizeDesktop -destination "$(DESTINATION)" \
		-configuration Debug CODE_SIGNING_ALLOWED=NO \
		-enableCodeCoverage YES -resultBundlePath $(RESULT_BUNDLE) \
		test
	COVERAGE_THRESHOLD=$(COVERAGE_THRESHOLD) scripts/coverage-check.sh $(RESULT_BUNDLE)
