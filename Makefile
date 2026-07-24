# helm build entry points. Two paths, both first-class:
#   - SPM (`make build` / `make run` / `make test`) for fast iteration
#   - XcodeGen (`make app`) for the real Helm.app bundle
# Makefile (not justfile) so there's zero extra tooling beyond xcodegen.

DERIVED_DATA := .build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/Helm.app

.PHONY: build app run test clean

build:
	swift build

app:
	xcodegen generate
	xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) build
	@echo "Built: $(abspath $(APP))"

run:
	swift run helm

test:
	swift test

clean:
	swift package clean
	rm -rf $(DERIVED_DATA) Helm.xcodeproj Info.plist
