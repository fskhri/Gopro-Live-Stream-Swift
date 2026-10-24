# GoPro Live Stream Swift

Native iOS app and Swift package for controlling GoPro Hero 6 cameras via BLE and streaming live video & audio directly to TikTok Live Studio over RTMP.

## Project Structure

- **`GoProRebuildApp/`**: SwiftUI iOS 16+ application shell.
  - BLE Camera Discovery & Connection (`ScanView.swift`).
  - Camera Remote Control, Settings & Shutter (`ControlView.swift`).
  - Low-latency Live Viewfinder surface using VideoToolbox (`PreviewSurface.swift`).
  - TikTok Live Studio Webcast Management & RTMP Streaming (`TikTokLiveView.swift`, `TikTokLoginView.swift`).
- **`GoProRebuildiOS/`**: Standalone `GoProKit` Swift Package.
  - **BLE**: CoreBluetooth central, fragment reassembly, TLV status parser, camera commands.
  - **WiFi**: `NEHotspotConfiguration` manager and HTTP camera API (`gpControl`).
  - **Preview**: UDP 8554 datagram receiver, MPEG-TS demuxer, VideoToolbox H.264 decompression.
  - **TikTok / RTMP**: Custom RTMP client, AMF0 encoding, FLV audio/video muxing, TikTok webcast API client, audio VU level meter.

## Getting Started

1. Open `GoProRebuildApp/GoProRebuildApp.xcodeproj` in Xcode 15+.
2. The Xcode project automatically resolves the local `GoProKit` package from `../GoProRebuildiOS`.
3. Select an iOS 16+ device or simulator and run.
4. For physical device runs with camera Wi-Fi join, enable the **Hotspot Configuration** capability under Signing & Capabilities.

## Tests

Run the package test suite:
```bash
cd GoProRebuildiOS
swift test
```
