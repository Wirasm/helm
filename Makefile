# helm build entry points. Two paths, both first-class:
#   - SPM (`make build` / `make run` / `make test`) for fast iteration
#   - XcodeGen (`make app`) for the real Helm.app bundle
# Makefile (not justfile) so there's zero extra tooling beyond xcodegen.

DERIVED_DATA := .build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/Helm.app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/Helm.app
INSTALLED := /Applications/Helm.app

.PHONY: build app install run test clean

build:
	swift build

app:
	xcodegen generate
	xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) build
	@echo "Built: $(abspath $(APP))"

# Put helm in /Applications so Launchpad and Spotlight can find it. Release, not Debug:
# `make app` builds Debug, which links -interposable and pulls in InjectionNext — right for
# iterating, wrong for the app you launch every day.
#
# A COPY, not a symlink: Launchpad wants a real bundle. Which means an installed helm goes
# stale the moment you rebuild — re-run this, it is part of the loop rather than a one-off.
#
# Refuses while helm is running rather than replacing a bundle whose process is live: the
# running app keeps its old code and the swap is invisible until something behaves oddly an
# hour later.
install:
	@if pgrep -x Helm >/dev/null 2>&1; then \
		echo "helm is running — quit it first (replacing a live bundle fails quietly)"; \
		exit 1; \
	fi
	xcodegen generate
	xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Release \
		-derivedDataPath $(DERIVED_DATA) build
	rm -rf $(INSTALLED)
	cp -R $(RELEASE_APP) $(INSTALLED)
	@echo "Installed: $(INSTALLED) — it is a copy, re-run after every rebuild"

run:
	swift run helm

test:
	swift test

format:
	scripts/check-format.sh --fix

lint:
	scripts/check-format.sh

clean:
	swift package clean
	rm -rf $(DERIVED_DATA) Helm.xcodeproj Info.plist
