SCHEME := CRCut
PROJECT := CRCut.xcodeproj
DESTINATION := generic/platform=iOS

# Requires: full Xcode (not just Command Line Tools) + xcodegen.
# No global `sudo xcode-select -s` needed (this Mac has no sudo TTY) --
# DEVELOPER_DIR points every xcodebuild/xcrun call at Xcode.app directly,
# scoped to this Makefile only.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: install test generate clean

# One-command build + install to the plugged-in iPhone. Also how you
# re-sign: the free Apple ID cert expires every 7 days, and re-running
# `make install` re-signs and re-installs in one shot (plan §5).
install: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination "$(DESTINATION)" \
		-allowProvisioningUpdates build
	xcrun devicectl device install app --device-id "$$(xcrun devicectl list devices | awk '/./{last=$$0} END{print last}' | awk '{print $$NF}')" \
		"$$(find . -name '$(SCHEME).app' -path '*/Build/Products/*' | head -n1)"

# swift test on the pure-Swift packages (DetectKit/PlanKit) — no
# simulator, no signing, runs on the Mac (plan §9 V1 / A9).
test:
	@for pkg in Packages/*/; do \
		if [ -f "$$pkg/Package.swift" ]; then \
			echo "== swift test: $$pkg =="; \
			(cd "$$pkg" && swift test) || exit 1; \
		fi; \
	done

generate:
	xcodegen generate

clean:
	rm -rf build $(PROJECT)
