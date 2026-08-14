SCHEME := CRCut
PROJECT := CRCut.xcodeproj
DERIVED_DATA := /tmp/crcut-dd

# Requires: full Xcode (not just Command Line Tools) + xcodegen.
# No global `sudo xcode-select -s` needed (this Mac has no sudo TTY) --
# DEVELOPER_DIR points every xcodebuild/xcrun call at Xcode.app directly,
# scoped to this Makefile only.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

# Apple developer team (owner's personal team); override with `make install TEAM=...`.
TEAM ?= 7S35JBM2HH

.PHONY: install test generate clean

# One-command build + install to the plugged-in iPhone. Also how you
# re-sign: the free Apple ID cert expires every 7 days, and re-running
# `make install` re-signs and re-installs in one shot (plan §5).
#
# -derivedDataPath is forced to /tmp: this repo sits on ~/Desktop, which
# iCloud Desktop sync manages via the File Provider, and that stamps
# com.apple.FinderInfo / com.apple.fileprovider.fpfs#P xattrs on the
# freshly built .app that codesign then refuses ("resource fork, Finder
# information, or similar detritus not allowed") -- the xattrs can't be
# stripped after the fact, so building outside the synced tree is the
# only fix.
#
# Destination must be a concrete device id, not generic/platform=iOS:
# on first deploy the device has to register with the team, which only
# happens when xcodebuild targets a real, connected device.
install: generate
	DEVICE_ID="$$(xcrun devicectl list devices | awk '/connected/ { for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$$/) { print $$i; exit } }')"; \
	test -n "$$DEVICE_ID" || { echo "no connected iPhone"; exit 1; }; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination "platform=iOS,id=$$DEVICE_ID" \
		-derivedDataPath $(DERIVED_DATA) -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM) build && \
	xcrun devicectl device install app --device "$$DEVICE_ID" \
		"$(DERIVED_DATA)/Build/Products/Debug-iphoneos/$(SCHEME).app"

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
	rm -rf build $(PROJECT) $(DERIVED_DATA)
