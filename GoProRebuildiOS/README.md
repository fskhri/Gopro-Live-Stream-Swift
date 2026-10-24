# GoPro Rebuild iOS

Native Swift port of the Android `gopro_rebuild` app: BLE control, WiFi hotspot
join, HTTP camera API. Clean-room rebuild from Open GoPro / gpControl, no cloud.

## Status

| Layer | Android | iOS | State |
|---|---|---|---|
| BLE scan / connect / commands | Kable | CoreBluetooth | Ported |
| BLE frame reassembly | GoProBlePacketAccumulator | GoProFrameAccumulator | Ported, tested |
| WiFi hotspot join | WifiNetworkSpecifier | NEHotspotConfiguration | Ported |
| HTTP API (gpControl + Open GoPro) | OkHttp | URLSession | Ported |
| Media list / thumbnail / delete / download | OkHttp | URLSession | Ported |
| Settings / presets / models tables | Kotlin enums | Swift enums | Ported, tested |
| Live preview (UDP MPEG-TS 8554) | ExoPlayer | Own demuxer + VideoToolbox | Ported, tested |
| TikTok live | OkHttp | not yet | Separate task |
| SwiftUI screens | Compose | Scan + Control | Ported |

`swift build` and `swift test` are clean. The GoPro-facing logic (byte
commands, frame defragmentation, TLV parsing, model names, battery bars) is
unit tested against the same inputs the Android app handles.

## Package layout

```
Sources/GoProKit/
├── BLE/
│   ├── GoProBLEConstants.swift    # Service + characteristic UUIDs
│   ├── GoProCommands.swift        # Command bytes, setting/status IDs
│   ├── GoProFrameAccumulator.swift# BLE fragment reassembly
│   ├── GoProTLVParser.swift       # Status/settings frame parsing
│   ├── GoProBluetoothCentral.swift# Single CBCentralManager owner
│   ├── GoProScanner.swift         # Camera discovery
│   ├── GoProBLEConnection.swift   # GATT client
│   └── GoProModels.swift          # Device, credentials, states, errors
├── WiFi/
│   ├── WifiConnectionManager.swift# NEHotspotConfiguration + reachability probe
│   └── GoProWifiAPI.swift         # HTTP client, models, media download
├── Camera/
│   ├── GoProCamera.swift          # BLE/WiFi routing controller
│   ├── CameraSettings.swift       # Setting option tables
│   └── GoProModel.swift           # Model name mapping
├── Preview/
│   ├── GoProPreviewConfiguration.swift # Stream host/port, keepalive payload
│   ├── GoProDatagramStripper.swift# 12-byte GoPro header removal
│   ├── GoProTsDemuxer.swift       # PAT/PMT, PES, H.264 AU assembly
│   ├── GoProUdpReceiver.swift     # DispatchSourceRead UDP socket
│   ├── GoProStreamKeepAlive.swift # Heartbeat so the camera keeps sending
│   ├── GoProH264Decoder.swift     # VideoToolbox decompression session
│   └── GoProPreviewPlayer.swift   # Orchestrates the pipeline, observable state
└── Repository/
    └── GoProServices.swift        # Shared services + connected camera (replaces Hilt)
```

## Drop into an Xcode app

1. Create an iOS App project in Xcode (iOS 16 or later).
2. File > Add Package Dependencies > Add Local... > select this folder.
3. Add the `GoProKit` library to the app target.
4. Info.plist keys:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Scan for and control your GoPro camera.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Talk to the camera over its own WiFi hotspot.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Needed on iOS to join the camera's WiFi hotspot.</string>
```

5. Capabilities > add **Hotspot Configuration**. Without it
   `NEHotspotConfigurationManager.apply` fails at runtime.
6. Wire the app:

```swift
import GoProKit

@main
struct GoProApp: App {
    @StateObject private var services = GoProServices()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(services)
        }
    }
}
```

```swift
// Scan and connect
try await services.scanner.startScan()
let devices = services.scanner.devices
let camera = await services.connect(to: devices[0])

// Control without WiFi
try await camera.startRecording()
try await camera.setSetting(settingId: SettingIds.resolution, value: VideoResolution.res1080.id)
await camera.keepAlive()   // keep BLE session alive while idle

// Media (needs WiFi)
try await camera.connectWiFi()
let list = try await camera.api.getMediaList()
try await camera.api.download(
    directory: list.media[0].directory,
    filename: list.media[0].files[0].name,
    to: FileManager.default.temporaryDirectory.appendingPathComponent("clip.mp4")
)

// Live preview (needs WiFi)
camera.preview.start()   // state flips to .waitingForStream, then .streaming
```

In SwiftUI, host the display layer with a `UIViewRepresentable` that adds the
player's layer as a sublayer and sizes it in `layoutSubviews` (see
`GoProRebuildApp/PreviewSurface.swift`).

## iOS differences from Android

These are platform constraints, not missing ports:

- **No MAC address.** Cameras are identified by `CBPeripheral.identifier`,
  stable per iPhone but not reusable across devices.
- **No paired-device list.** Android could list bonded Bluetooth devices; iOS
  cannot. Discovery is scan-only.
- **No process-to-network binding.** Android bound the process to the GoPro
  network; iOS routes automatically to the joined hotspot. Reachability is
  decided by probing `http://10.5.5.9` instead.
- **Hotspot join needs a user prompt.** `NEHotspotConfiguration` shows the
  system dialog once; after that the camera network is remembered.
- **Local network permission.** First HTTP request to `10.5.5.9` triggers the
  iOS local network prompt. If it is denied, every camera call fails.

## Live preview

The camera streams MPEG-TS over UDP 8554, one 12-byte GoPro header per
datagram. iOS has no ExoPlayer equivalent, so the pipeline is built from
system pieces only:

```
UDP 8554 -> GoProUdpReceiver -> GoProDatagramStripper -> GoProTsDemuxer
         -> GoProH264Decoder (VideoToolbox) -> AVSampleBufferDisplayLayer
```

- `GoProDatagramStripper` carries over the header-stripping rules from
  `GoProUdpDataSource.kt`, byte for byte, including its fallbacks.
- `GoProTsDemuxer` is pure Swift with no AVFoundation dependency, so it builds
  and tests on macOS too. NAL splitting follows the `media3` rule used on
  Android: the scanner finds the three-byte `00 00 01`, and a zero before it
  is the extra byte of a four-byte delimiter.
- A continuity-counter gap salvages the complete previous PES, then discards
  until the next payload-unit-start instead of clearing the partial PES.
- `GoProStreamKeepAlive` sends `_GPHD_:0:0:2:0.000000\n` to `10.5.5.9` every
  2s on a connected socket that is reopened on send failure, so the camera
  starts sending before the hotspot join finishes.
- No control timebase: frames display as soon as they decode. Non-keyframes
  are dropped while the display layer is not ready for more media data.
- AAC is dropped for now; v1 preview is silent.

`GoProUdpRelay.kt` is not ported: its only consumers are the ffmpeg and
ExoPlayer paths, and iOS has neither.

Known limits:

- Preview must be started by tapping Start; it does not begin on connect.
- Audio is not played.
- The decoder has no unit test (test SPS/PPS fixtures are not decodable), so
  decode quality is verified manually on device.

## Build and test

```bash
swift build
swift test
```

Unit tests cover the byte-level protocol: frame defragmentation, TLV parsing,
command bytes, model-name mapping, battery bars, media list decoding, plus the
preview pipeline (header stripping, PAT/PMT, PES assembly, continuity gaps,
NAL splitting).

Camera-facing behavior needs a real GoPro (HERO9 or later tested on Android)
plus a device with Bluetooth permission granted.

## Legal

Clean-room reverse engineering for educational purposes.
Not affiliated with GoPro, Inc. MIT licensed.
