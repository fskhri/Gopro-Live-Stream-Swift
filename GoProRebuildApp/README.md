# GoPro Rebuild — iOS app shell

SwiftUI shell over the `GoProKit` package in `../GoProRebuildiOS`. Direction and tokens live in `DESIGN.md`.

Only two screens exist: **Scan** (discover/connect) and **Control** (WiFi join, mode switch, live preview, shutter, sleep, disconnect). Media, Presets, Settings, Camera Info and TikTok live are not ported, and nothing links to them.

## Open and run

1. Open `GoProRebuildApp.xcodeproj`. The local package `../GoProRebuildiOS` is referenced by path; keep the two folders siblings.
2. Select the `GoProRebuildApp` scheme and an iOS 16+ simulator or device.
3. Build. No CocoaPods/SPM remote dependencies, code signing must be set only for device runs.

Build settings of note:

- Deployment target iOS 16.0, `TARGETED_DEVICE_FAMILY = 1,2` (iPhone + iPad).
- `GENERATE_INFOPLIST_FILE = YES` with `INFOPLIST_KEY_NS*UsageDescription` entries for Bluetooth, Local Network and Location When In Use.

## Permissions and capabilities

- **Bluetooth / Local Network / Location When In Use** — provided as generated Info.plist keys.
- **Hotspot Configuration** entitlement — *not* enabled in this project. Without `com.apple.developer.networking.wifi-info`-adjacent Hotspot Configuration entitlement, `NEHotspotConfiguration` joins fail at runtime. Add the capability in Signing & Capabilities before testing the WiFi path on a real camera.
- The camera HTTP host is fixed at `10.5.5.9`; preview streaming is UDP port 8554 with a 12-byte GoPro header per datagram, received in-process by `GoProKit` and decoded with VideoToolbox.

## Debug render check

The iOS simulator has no Bluetooth radio (`central.state == .unsupported`), so the control screen never renders there on its own. A DEBUG-only harness fabricates a camera so the layout can be reviewed at real device size and Dynamic Type sizes:

```
xcrun simctl launch <udid> com.gopro.rebuild.ios -control-screen-check        # top of control screen
xcrun simctl launch <udid> com.gopro.rebuild.ios -control-screen-check-bottom # scrolled to bottom
```

Toggle Dynamic Type with `xcrun simctl ui <udid> content_size <size>` (e.g. `large`, `accessibility-extra-extra-extra-large`) and relaunch. The harness is compiled out of release builds and shows a fake link state; it is a review aid, not product behaviour.

## Layout notes

- Control screen rows that hold equal-width labels (`modeSelector`, `secondaryActions`) switch from side-by-side to stacked at accessibility text sizes; otherwise intrinsic one-line width overflows the screen.
- The WiFi card is stacked (icon+title row, caption, full-width Connect) rather than a horizontal row, so the caption never gets squeezed at large sizes.
- Status strip carries only link state + firmware; the camera name is the navigation title.
- Buttons use near-black labels on the accent fill (`Theme.onAccent`): white on `#00AEEF` is 2.6:1 contrast.

## Live preview

- The 16:9 card hosts `player.displayLayer` through `PreviewSurface.swift`. The player owns the layer; the view only sizes it, so frame enqueues survive SwiftUI rebuilds.
- Start is explicit: tapping Start calls `api.startPreview()`, opens the UDP receiver, then the keepalive. Nothing starts on connect.
- The card also stacks its storage/shutter/secondary row at accessibility text sizes.
- Preview is silent (AAC track dropped) and does not verify its own decoder; first picture on a real camera is the real test.
