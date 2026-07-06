.PHONY: generate build test lint format ci

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
