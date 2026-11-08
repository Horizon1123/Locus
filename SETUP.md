# Locus — install & first teleport

## 1. Sideload the IPA

Install the latest IPA from [Releases](https://github.com/ChrisMack32/Locus/releases) (or build from source) with Feather, SideStore, AltStore, Sideloadly, or LiveContainer.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often break inside LiveContainer. Do one of the following:

1. Long-press **Locus** in LiveContainer → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share / open the pairing file **into LiveContainer → Locus** (iOS share sheet).
3. Copy the RPPairing plist contents, open Locus → **Paste RPPairing from clipboard** (setup or Settings).

## 2. Pairing

### On iOS 27 — no computer

1. Open Locus → **Settings → Pair on this iPhone** → **Start pairing**.
2. Allow **Local Network** (and Location / Notifications if asked).
3. Leave Locus open. Go to **Settings › Privacy & Security › Developer Mode › Pair with Host**.
4. Pick **Locus** → **Pair**.
5. Enter your **iPhone unlock passcode** first (authorizes pairing).
6. When the second prompt appears, type the **6-digit code** Locus shows (also sent as a notification).
7. Done — RPPairing file is saved on-device.

### On iOS 18–26

1. On a computer, download [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).
2. Plug in your iPhone, unlock, Trust.
3. Generate an **RPPairing** file (not lockdown / SideStore `.mobiledevicepairing`).
4. AirDrop / Share → Open in **Locus**, **Import**, or **Paste from clipboard**.

## 3. LocalDevVPN

Install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044), connect it (default tunnel IP `10.7.0.1`).

## 4. Teleport

While connected to Wi‑Fi, drop a pin → **Teleport**. Confirm that the **Written**
time and count advance, then check the selected location in Apple Maps. Keep the
developer tunnel reachable while using the joystick, routes, or GPX tracks.
Turning off Wi‑Fi can break continued writes even if LocalDevVPN stays connected.

## 5. Mobile data through another phone's hotspot

For an iPhone 13 on iOS 18.1.1, the recorded Wi‑Fi-off test failed with both
`10.7.0.1` and `127.0.0.1` (LocalDevVPN 1.3.0). LocalDevVPN's maintainers also
[report that cellular-only operation is unsupported](https://github.com/jkcoxson/LocalDevVPN/issues/31).
Repeated connection attempts cannot make an unreachable local service available.

If you can use another phone, try this arrangement:

```text
Hotspot phone's cellular data → Wi-Fi hotspot → iPhone 13 running Locus
                                                 └─ LocalDevVPN → location service
```

The iPhone 13 stays connected to Wi‑Fi; internet traffic uses the **hotspot
phone's SIM/data plan**. This is a proposed workaround, pending verification
on the target phone. It does not add direct cellular-only support to Locus.

1. Enable mobile data and the personal hotspot on the second phone. For an
   iPhone hotspot, enable **Settings → Personal Hotspot → Allow Others to Join**.
2. On the iPhone 13, join that hotspot under **Settings → Wi‑Fi** and confirm it
   remains connected. Merely leaving the Wi‑Fi switch on is insufficient.
3. On the iPhone 13, open LocalDevVPN and connect it. If an earlier connection
   has stalled after switching networks, disconnect and reconnect LocalDevVPN.
4. Return to Locus. Keep the same tunnel IP and port that worked on ordinary
   Wi‑Fi; do **not** replace them with the hotspot router's address. The default
   tunnel IP is `10.7.0.1`; use your previously working port.
5. Select a location and tap **Teleport**. Keep the hotspot connected for the
   duration of the session.

Apple documents how a personal hotspot shares the host iPhone's cellular
connection in [its hotspot guide](https://support.apple.com/en-us/111785).

### Verify actual location writes

- In the foreground, confirm that the **Written** timestamp and count keep
  advancing. Locus normally schedules a resend every 2 seconds; slow native
  operations can make this take longer.
- Move to a second, distinct target. In Apple Maps on the same iPhone, use the
  current-location button and confirm that the location follows both targets.
  A saved pin or a connected VPN is not sufficient evidence.
- Leave Locus in the background while viewing Maps for at least a minute, then
  return and check the last write time. Check again after a lock/unlock cycle
  if that is part of your intended use; foreground success does not establish
  background reliability.
- If writes fail, record the Locus status/error, last **Written** time/count,
  LocalDevVPN version, tunnel IP/port, and whether the iPhone still shows a
  Wi‑Fi connection to the hotspot. Do not share the pairing file.

Until these checks pass on the iPhone 13, treat hotspot operation as unverified.
