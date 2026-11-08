# Locus

Free and open-source iPhone location teleport. Tap the map, search a place, or drive a route — Locus injects coordinates through Apple’s **developer location service** into `locationd`, so Maps and other apps see the spoofed GPS (not just a Wi‑Fi lookup that outdoor GPS will overwrite).

<p align="center">
  <img src="docs/screenshots/map.png" alt="Locus map with spoof pin" width="180" />
  <img src="docs/screenshots/spoofing.png" alt="Locus spoofing in 3D" width="180" />
  <img src="docs/screenshots/joystick.png" alt="Locus joystick controls" width="180" />
  <img src="docs/screenshots/route.png" alt="Locus route on map" width="180" />
</p>

## Features

- One-tap teleport (map pin or place search)
- Live joystick — walk / run / cycle / drive with light speed variation
- Walk/Drive routing on real roads & footpaths (MapKit)
- Draw a path or import / export GPX
- Background keep-alive + live status bar + drop alerts
- Favorites & recents
- First-run setup walkthrough
- Fully on-device — no analytics, nothing uploaded

## Install

See [SETUP.md](SETUP.md) for full steps. Grab a prebuilt IPA from [Releases](https://github.com/ChrisMack32/Locus/releases), or build from source below.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often don’t work inside LiveContainer. Use one of these:

1. Long-press **Locus** → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share the pairing file **into LiveContainer → Locus**.
3. Copy the RPPairing plist contents → in Locus use **Paste RPPairing from clipboard** (setup or Settings).

## How it works

Locus uses the MIT-licensed [idevice](https://github.com/jkcoxson/idevice) FFI to talk to Apple’s DVT location simulation over an on-device developer tunnel (the same class of mechanism Xcode uses).

**iOS 27:** Settings → **Pair on this iPhone** advertises `_remotepairing-pairable-host._tcp`. Confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host — no computer.

**iOS 18–26:** import an **RPPairing** file once from [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).

Also install **[LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)** (loopback tunnel, default `10.7.0.1`), then sideload Locus.

The developer tunnel must remain reachable for continued writes. Starting on
Wi‑Fi does not guarantee continuity on cellular. On the tested iPhone 13 with
iOS 18.1.1 and LocalDevVPN 1.3.0, both `10.7.0.1` and `127.0.0.1` failed after
Wi‑Fi was disabled. The last coordinate remains cached, but cannot be written
to the system until a working tunnel is available.

If mobile internet through another device is acceptable, try connecting the
iPhone running Locus to a second phone's cellular hotspot. This keeps the
target iPhone associated with Wi-Fi while internet traffic uses the hotspot
phone's mobile data. This is a workaround to validate on the device, not a
verified fix for cellular-only operation. See [the hotspot setup and checks](SETUP.md#5-mobile-data-through-another-phones-hotspot).

The native location and tunnel operations have deadlines, so a silent peer
returns an error and the last target can be retried on a fresh connection.
Manual teleports use the same asynchronous writer and do not block the UI.

While active, Locus re-sends the selected coordinates every 2 seconds and first
reuses the existing developer session when the network changes. A failed write
retries after 1 second, then every 2 seconds; requests never overlap. These are
scheduling intervals, and a slow tunnel call can take longer.
Automatic connection failures appear in the status bar instead of repeatedly
opening an alert. Reconnecting does not mean a coordinate was successfully written.

The status bar shows the last successful location-service write and its count.
For a separate diagnostic test of direct Wi‑Fi-to-cellular continuity, establish a teleport on Wi‑Fi, leave
LocalDevVPN connected, disconnect Wi‑Fi, and check that the time and count keep
advancing. Also verify the position in Maps and repeat with Locus in the background.
Keep Wi‑Fi connected during normal hotspot use; this diagnostic deliberately
tests the unsupported cellular-only path.
A connected VPN alone does not confirm that its local tunnel is reachable;
if iOS blocks that route or suspends Locus, continued writes cannot be guaranteed.

### Pokémon GO & similar games

Locus spoofs location the same way Xcode’s developer tools do: it tells iOS “you’re here,” and other apps read that from the system. Apps that just trust GPS (Apple Maps, etc.) will follow it.

**Pokémon GO is different.** It runs its own location checks and often rejects developer / simulated GPS (e.g. “Failed to detect location”). That’s expected with this method, not a Locus bug, and there’s no supported fix for it in this app.

Tools like **iPogo** (and similar modified clients such as SpooferPro) work differently: they’re a **modified Pokémon GO app**, not a system-wide location spoof. Features live *inside* that altered game client, instead of feeding coordinates through iOS for every app. Locus never patches or replaces Pokémon GO; it only changes what the system reports. So those tools can appear to “work in Pokémon GO” while Locus correctly drives Maps but still gets blocked by Pokémon GO’s checks.

Locus is for system-level teleporting. It isn’t a Pokémon GO client or an anti-cheat bypass.

## Build

Building from source needs an Apple Developer account (free or paid) for code signing. The published IPA does **not** — just sideload it.

Before building this branch, run `bash Vendor/idevice/build-locus-library.sh`
with Xcode and Rust installed. This rebuilds the pinned native dependency with
the deadline patch and runs its stalled-peer regression checks. The Swift
wrapper requires the patched library; the original binary is insufficient.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if needed: `brew install xcodegen`
2. Set your **Team ID** in `project.yml` (`DEVELOPMENT_TEAM`), *or* pick your team under Xcode → Signing & Capabilities after generating the project.
3. Generate and open:

```bash
xcodegen generate
open Locus.xcodeproj
```

Or build from the CLI (replace with your Team ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership):

```bash
xcodegen generate
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

## License

MIT. `Vendor/idevice` contains the idevice FFI (MIT). Locus is an independent open-source project and is not affiliated with Mirage / Wapixel.
