# CRCut — iOS app

Native on-device port of the `crcut` auto-editor (see repo root README + `.omc/plans/2026-08-13-ios-crcut-app.md`). No server, no App Store — free Apple ID, sideload via Xcode, re-sign weekly.

## Status

**M0 skeleton** (this checkout): SwiftUI shell proving the I/O contour — pick a video (`PHPickerViewController` via `PhotosPicker`) → copy into `Documents/inbox/` → passthrough re-export (`AVAssetExportSession`, preset Passthrough — stands in for the real render pipeline) → save to Photos (add-only permission) → caption screen with Copy/Share stubs. No detection, no plan, no real render yet — those are M1-M3.

`ios/project.yml` is authored for the future: this Mac only has Xcode Command Line Tools (no full Xcode, no `xcodegen`), so the project can be **authored but not generated or built** here. That's expected, not a bug — verified instead via `swiftc -parse` per file, `project.yml` as YAML, `Info.plist` as a plist, and `make -n` for Makefile syntax.

`ios/Packages/` is intentionally empty right now — DetectKit/PlanKit/RenderKit/VoiceKit/MediaKit land there as separate work streams (plan §3). `project.yml`'s `packages:`/`dependencies:` sections have the wiring commented out; uncomment each package's block as it lands.

## Setup (once you have a Mac with Xcode)

1. Install Xcode from the App Store and open it once — it fetches its components on first launch. No `sudo xcode-select -s` needed: the Makefile sets `DEVELOPER_DIR` itself, so `make install` targets Xcode.app directly.
2. Install XcodeGen (generates the `.xcodeproj` from `project.yml`):
   ```
   brew install xcodegen
   ```
3. Plug in an iPhone (iOS 17+), trust this Mac on the phone if prompted, and open Xcode once to sign in with your (free) Apple ID under Settings → Accounts — that's what `-allowProvisioningUpdates` uses to mint the on-device provisioning profile.

## Day to day

```
cd ios
make install   # xcodegen generate + xcodebuild build + devicectl install onto the plugged-in phone
make test      # swift test across Packages/* (DetectKit/PlanKit) — no simulator needed, runs on the Mac
```

First `make install` on a clean checkout: budget ~10 min. Incremental rebuilds: ~3 min (plan A8).

On first launch, iOS will refuse to run the app until you trust the developer certificate: **Settings → General → VPN & Device Management → [your Apple ID] → Trust**.

## The weekly re-sign

A free Apple ID's provisioning profile expires after 7 days — the app simply stops launching until you re-sign. There's no separate "re-sign" step: just run `make install` again. Same command, same result, whether it's the first install or the tenth re-sign.

## Layout

```
ios/
  Makefile          make install / make test
  project.yml       XcodeGen spec (bundle id local.crcut, iOS 17.0 deployment target)
  CRCut/            SwiftUI app target
    App.swift
    Views/          ImportView, QueueView, ResultView
    Pipeline/       Pipeline.swift (passthrough export + save-to-Photos), QueueItem.swift
    Info.plist
    Resources/      music/, sfx/, memes/, fonts/ — populated in M5/M8
  Packages/         SPM packages land here (DetectKit, PlanKit, RenderKit, VoiceKit, MediaKit)
  Tests/GoldenTests/  XCTest comparing Swift output to tests/golden/*.json (M1+)
```
