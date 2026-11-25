# LumaRemote

A personal iOS app (display name "Luma") that replaces the DayBetter app for DayBetter Bluetooth LED
lights. SwiftUI + CoreBluetooth, sideloaded with xtool from Windows/WSL (no Mac, no Xcode).

## Commands

```bash
swift test --package-path Core   # protocol tests (Linux). Plain `swift test` at the root fails by design.
xtool dev build                  # the only type check for the app target
xtool dev run                    # build, sign, install on the iPhone; the USER runs this (`! xtool dev run`)
```

If the phone isn't detected, see `../YTadless/DEVICE-CONNECT.txt` (usbipd attach + usbmuxd).

## Layout

- `Core/` (`LumaCore`): pure Swift, no CoreBluetooth/SwiftUI. Frame building, CRC16-Modbus, effects,
  color correction, `LightState`/`LightScene`, the `Coalescer`. Everything testable lives here.
- `Sources/LumaRemote/BLE/LightManager.swift`: the single `@MainActor @Observable` owner of the
  `CBCentralManager` (queue `.main`, delegate methods `nonisolated` + `MainActor.assumeIsolated`),
  persistence (UserDefaults JSON), the write pipeline (60 ms coalescing per command) and the log.
- `Sources/LumaRemote/Views/`: Root (groups with preset chips, lights, nearby), GroupEditor, Control
  (`ControlTarget` .light/.group: power, brightness, per-group presets, Color [Wheel|Grid], White,
  Effects for strips), Settings, Diagnostics. `Components.swift` has `.glow` used for every light color.
- Groups: `LightGroup` (LumaCore) with per-group `LightPreset`s, persisted as "groups.v1"; the built-in
  All Lights group (`includesAllLights`) can't be deleted. Old "scenes.v1" is migrated once.
- Presets are per light: `LightPreset.lightStates[lightID]` (fallback `state` for lights added later);
  `savePreset`/`updatePreset` capture every ready member's current look. No built-in presets (old ones
  are removed once, flag "builtInPresetsRemoved"). Home screen = one Section per group with indented
  one-tap preset rows; group screen lists members, each opening `ControlTarget.light`.
- `Config/Info.plist`: partial plist merged by xtool. `NSBluetoothAlwaysUsageDescription` is required.

## Protocol

From github.com/grimsteel/daybetter-led-strip (MIT), written for DayBetter *strips*; assumed to match
the bulbs. VERIFIED: P09C bulbs expose service E09C / write A09C (writeNoResp) / notify F09C, i.e. UUIDs are
per model (E0xx/A0xx/F0xx), see `DayBetter.modelUUIDs`. Write `A0 cmd len payload CRC16-Modbus(LE)` to 0xA031, notifications
on 0xF031, discovery service 0xC031, control service 0xE031. Commands: 0x10 status, 0x11 power,
0x12 effect, 0x13 brightness (0–100), 0x15 color. Vector: red = `A0 15 06 FF 00 00 25 C0`.

### CCHIP lights (P09C bulbs) — decoded from a DayBetter-app capture with ../bletrace

Same framing, but the light ignores everything until a login: `A0 00 08 "CCHIP"` → light replies
`A1 00 0A "CCHIP" c0 c1` → send `A0 01 0A "CCHIP" c0^24 c1^4C` → `A1 01 09 "CCHIP" 00` = accepted.
Color: `A0 12 04 01` (color mode) + `A0 15 07 R G B 00`. White: `A0 12 04 00` + `A0 20 07 FF FF a 255-a`.
Status request payload is 01; status reply is 0x2D bytes (power at [3], brightness at [6]). No effects known.
Variant is detected at connect (`Light.variant`): challenge received → `.cchip`, 2 s silence → `.strip`.
`Encoder` builds frames per variant; `CchipTests` hold the captured vectors.
Unverified: which end of the white pair is warm (`Encoder.warmByteIsFirst`).

## Reading on-device state over USB

The installed bundle ID is `XTL-NUW48458NP.com.example.LumaRemote` (xtool prefixes the team ID).
With the phone attached (see DEVICE-CONNECT.txt) the app container is readable from WSL:

```bash
afcclient --container XTL-NUW48458NP.com.example.LumaRemote get /Documents/diagnostics.txt diag.txt   # lights, GATT, nearby, log
afcclient --container XTL-NUW48458NP.com.example.LumaRemote get /Library/Preferences/XTL-NUW48458NP.com.example.LumaRemote.plist prefs.plist
```

Screenshots (`idevicescreenshot`) don't work: they need a mounted Developer Disk Image.
