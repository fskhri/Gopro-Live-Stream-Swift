# DESIGN.md — GoPro Rebuild iOS app shell

Direction: **Quik-feel chrome, no GoPro marks.** Owner asked for the official app's
look; owner then chose the option "rasa Quik, tanpa logo" after being shown that
GoPro's own brand policy forbids imitating their trade dress, colour scheme and
logos, and that this repo positions itself as clean-room and unaffiliated.

So: same *function* conventions (near-black chrome, blue accent, big shutter,
list-then-control flow), own visual footprint (no logo, no wordmark, no tagline,
no copied layout tracing).

## Sources for the palette (public, not invented)

- GoPro Design's own Quik shot on Dribbble publishes the app palette, incl.
  `#181A1B` (near-black), `#ABC6CD`, `#618396`, `#A3A8A9`, `#CFD2D3`, `#D96760`.
- GoPro's public brand blue is `#00AEEF`; the darker `#005DAC` appears in GoPro
  marketing chrome.
- Everything else here is platform-native (iOS system reds/greens) or a neutral
  step derived from the above. No value is invented brand art.

## Tokens

| Token | Value | Use |
|---|---|---|
| `background` | `#101213` | screen background |
| `surface` | `#181A1B` | cards, list rows, bars |
| `surfaceRaised` | `#22262A` | pills, chips |
| `textPrimary` | `#FFFFFF` | titles, values |
| `textSecondary` | `#CFD2D3` | subtitles |
| `textMuted` | `#A3A8A9` | captions, disabled |
| `accent` | `#00AEEF` | primary action, selection |
| `accentDeep` | `#005DAC` | pressed/edge |
| `onAccent` | `#0A0C0D` | label on accent fill |
| `record` | `#FF3B30` | recording, destructive |
| `ok` | `#30D158` | connected |
| `warn` | `#FF9F0A` | battery low |

Contrast (checked by hand, WCAG 2.1 relative luminance):

- `textPrimary` / `textSecondary` on `background`: ≥ 11:1. Pass (AAA).
- `textMuted` on `surface`: ≈ 6.7:1. Pass (AA normal text).
- `accent` on `background`: ≈ 7.4:1. Pass.
- White on `accent`: ≈ 2.6:1. **Fails.** Therefore the accent button label is
  `onAccent` (near-black), ≈ 7.9:1. White on blue is exactly the trap the
  official chrome walks into; this design does not copy it.

Colour budget: one accent (`accent`) plus three semantic colours (record/ok/warn)
plus a 4-step neutral ramp. No second decorative hue, no gradients.

## Typography

SF Pro only (system font, Dynamic Type styles, no custom face). Weight, not
colour, carries emphasis. Technical values (`RSSI`, battery %, free space) use
`.monospacedDigit()` so they stop jittering while they update.

## Structure

- **Scan** — navigation title "Find GoPro", trailing scan/stop button, list rows
  64pt min (icon, name, RSSI, paired chip), footer button "Connect via camera
  WiFi (10.5.5.9)" for the already-joined-hotspot case. States: scanning,
  connecting, empty, Bluetooth unavailable or denied, error banner with dismiss.
- **Control** — status strip (camera name + BLE/WiFi badge + battery pill),
  WiFi connect card while the hotspot is down, mode chips (Video / Photo /
  Timelapse), live preview card, SD free space, 88pt shutter, Sleep and
  Disconnect.
- **Live preview card** — 16:9 black surface. States: idle ("Start live
  preview"), waiting (camera starting the stream), streaming (LIVE badge,
  Stop), failed (error text + retry). Whole card is one accessibility element
  with label/value. Tapping starts the stream; nothing auto-starts. The hint
  "Join the camera's WiFi to use live preview." shows whenever the preview
  cannot run, so the card never pretends to be a broken player.
- Only screens that exist are reachable. The Android app's Media, Presets,
  Settings, Camera Info and TikTok screens are not ported yet, so there are no
  links to them (no dead affordances).
- Accessibility sizes (`dynamicTypeSize.isAccessibilitySize`) stack the rows
  that overflow horizontally: WiFi card, mode chips, preview card's
  storage/shutter/secondary row.

## Motion

System transitions only, no custom animation, no decorative motion. State change
is communicated by colour and text.

## Dials

ENERGY 2 / RHYTHM 1 / MOTION 1.

- ENERGY 2: one assertive saturated accent on a near-black field, a large shutter
  in the thumb zone. Not 1, because the reference chrome is deliberately punchy;
  not 3, because a camera remote should not compete with the footage.
- RHYTHM 1: predictable top-status → mode → shutter → secondary order on every
  visit. Nothing moves between launches.
- MOTION 1: one information state change per action; nothing animates for flair.

## Honest limits

- `NSBluetoothAlwaysUsageDescription` etc. are generated Info.plist keys; the
  Hotspot Configuration capability must be added in Xcode or `connectWiFi()`
  fails at runtime.
- The screenshot-level match to the real Quik app is unverified: no GoPro
  screenshot set was supplied. If a closer match is wanted, send screenshots.
- Live preview is silent: the stream's AAC track is not decoded yet.
- The preview decoder has no unit test (test SPS/PPS fixtures are not
  decodable frames), so picture quality is verified by eye on a real camera.
- No GoPro logo, icon or wordmark is present, by decision, not by omission.
