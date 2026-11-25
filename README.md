# Reverse-engineering the DayBetter P09C Bluetooth bulbs

How the Bluetooth protocol of the DayBetter P09C bulbs was worked out, from "can I write my own app?"
to Luma controlling both bulbs. Everything was done from Windows + WSL with an iPhone on a USB cable:
no Mac, no Android phone, no sniffer hardware.

**Result:** The bulbs use the same framing as DayBetter's older LED strips, plus a per-model set of
Bluetooth addresses and a challenge-response login that must happen before the bulb accepts any
command. The full protocol is at the end of this document.

---

## 1. Start from prior work

The DayBetter app talks Bluetooth LE (BLE) straight to the bulbs. Cheap BLE lights rarely encrypt
anything, so the first step was to look for someone who had already done the work.

- **[grimsteel/daybetter-led-strip](https://github.com/grimsteel/daybetter-led-strip)** (MIT) is a
  Python library for DayBetter **LED strips**. It documents:
  - The frame format: `A0 | cmd | len | payload | CRC16-Modbus (little-endian)`.
  - Commands: `0x10` status, `0x11` power, `0x12` effect, `0x13` brightness, `0x15` color.
  - GATT UUIDs: service `E031`, write characteristic `A031`, notify characteristic `F031`.
  - A published test vector: red = `A0 15 06 FF 00 00 25 C0`. I recomputed the CRC to confirm the
    algorithm before relying on it.
- **[THDayBetter/daybetter_service](https://github.com/THDayBetter/daybetter_service)**, DayBetter's
  official Home Assistant integration, lists the P09C as supported. Reading its source showed that it
  only uses DayBetter's **cloud** HTTP API. That's no help for a bulb that only has Bluetooth.

So the starting hypothesis was that the bulbs speak the strip protocol. The first version of Luma was
built on that assumption, with the protocol logic in a separate, unit-tested package
(`Core/`, `LumaCore`).

## 2. Instrument the app before guessing

The bulbs might not match the strips, so Luma shipped with a **Diagnostics** screen from day one:

- a list of every nearby BLE device, with its advertised services and signal strength
- the full GATT table (services, characteristics, properties) of each connected light
- a raw hex sender, with an optional automatic CRC
- a log of every byte sent and received

Without a Mac there's no way to see an iPhone's screen or console from WSL. `idevicescreenshot` fails
on iOS 17 and later unless a Developer Disk Image is mounted. However, a sideloaded app's own
files **are** readable over USB with libimobiledevice:

```bash
afcclient --container XTL-<TEAMID>.com.example.LumaRemote get /Documents/diagnostics.txt diag.txt
```

(xtool prefixes the bundle ID with `XTL-<team ID>`, which took a few tries to discover.) Luma
was changed to write `Documents/diagnostics.txt` continuously. From then on, every on-device result
could be read directly over the cable instead of described from screenshots.

## 3. Finding 1: the addresses are per model

The bulbs didn't appear in Luma's device list, because Luma filtered for the strips' advertised
service `C031`. In Diagnostics they showed up as **`P09C_C612`** and **`P09C_7DD2`**. After adding
them by hand, the pulled diagnostics file showed their GATT table:

```
service 1811              (standard Alert Notification, unused)
service E09C
  char A09C [writeNoResp]
  char F09C [writeNoResp, notify]
```

The strips use `E031 / A031 / F031`, and the strip model is P0**31**. The bulbs are model P0**9C** and use
`E09C / A09C / F09C`. **The last two hex digits of every UUID are the model number.** Luma was changed to
derive the UUIDs from the model (`DayBetter.modelUUIDs(forService:)`) and to recognize names that
contain a model code.

## 4. Finding 2: right address, still ignored

With the right characteristic, Luma's log showed it sending well-formed strip-protocol frames:

```
→ A0 10 04 00 21 21     status request
→ A0 11 04 00 70 E1     power off
→ A0 15 06 FF 64 8C …   color
```

The bulbs did nothing, and **sent no reply at all**. The strips acknowledge every command
(`A1 <cmd> 04 01`), so total silence meant the bulbs were rejecting the commands, not merely failing to
understand them. Guessing further would have been slow, so the next step was to record exactly what
the official app sends.

## 5. Capturing the official app's traffic on an iPhone

iOS doesn't let one app see another app's Bluetooth traffic. The bulb also accepts only one connection,
so a second app can't listen in. Apple does provide an official way to log it:

1. Install the **Bluetooth logging profile** from
   [developer.apple.com/bug-reporting/profiles-and-logs](https://developer.apple.com/bug-reporting/profiles-and-logs/)
   (free Apple ID sign-in), then restart the phone.
2. Close Luma, open the DayBetter app, and do one action at a time, about 3 seconds apart:
   off, on, red, green, blue, brightness 100 % and 10 %, then white.
3. Trigger a **sysdiagnose**: hold both volume buttons + the side button for about 1 s until the phone
   vibrates. Wait 5 to 10 minutes. (Settings › Privacy & Security › Analytics & Improvements › Analytics
   Data shows a `sysdiagnose_…` entry when it's done.)
4. Pull it over USB with `idevicecrashreport`. The tarball contains
   `logs/Bluetooth/bluetoothd-hci-latest.pklg`, an Apple PacketLogger file of every HCI packet.

## 6. bletrace: a tool for reading the capture

To decode the capture, and to have a tool for future devices, I built **`../bletrace`**: Python
standard library only, with a local web GUI.

- **Pull:** runs `idevicecrashreport -k -f sysdiagnose`, then reads only the `.pklg` members out of the
  tarball. Nothing is extracted to disk, because archive paths aren't trusted.
- **Parse:** reads PacketLogger (both byte orders exist) and Android btsnoop.
- **Decode:** HCI events (connections, advertising, disconnections) → ACL reassembly →
  L2CAP channel 4 → ATT. GATT discovery responses in the capture are used to map handles to UUIDs, so
  "handle 29" becomes `A09C`.
- **Analyze:** highlights bytes that changed since the previous packet of the same shape on the same
  characteristic. It groups packets by characteristic, length and first byte to show which positions
  are constant and which vary. It also tests the trailing bytes against common checksums (CRC-16
  Modbus/CCITT/XMODEM/…, CRC-8, sum, XOR).
- **GUI:** a trace strip of all packets over time, where each tap in the app shows up as a burst, plus a timeline,
  byte inspector, notes and handle labels.

The capture held about 40,000 HCI records. It decoded to 584 ATT packets across four devices: the two
bulbs and two unrelated gadgets.

## 7. Reading the capture

Filtered to the two bulbs (handle 29 = `A09C`, 31 = `F09C`), the first DayBetter-app session looked
like this:

```
→ A0 00 08 43 43 48 49 50 AC CA                     "CCHIP"
← A1 00 0A 43 43 48 49 50 06 03 6E EA               "CCHIP" + 06 03
→ A0 01 0A 43 43 48 49 50 22 4F 28 4A               "CCHIP" + 22 4F
← A1 01 09 43 43 48 49 50 00 16 E1                  "CCHIP" + 00
→ A0 10 04 01 E0 E1                                  status (payload 01, not 00)
← A1 10 2D 01 00 41 64 4F 28 FE 01 00 00 …           45-byte status
   … version, device info, time sync …
→ A0 11 04 00 70 E1   ← A1 11 04 01                 off   (identical to Luma's frame)
→ A0 11 04 01 B1 21   ← A1 11 04 01                 on
→ A0 12 04 01 41 21                                  color mode
→ A0 15 07 FE 01 00 00 6C 27                         red
→ A0 15 07 00 FF 00 00 3C 3F                         green
→ A0 15 07 00 00 FF 00 4D FF                         blue
→ A0 13 04 19 10 EB                                  brightness 25 %
→ A0 12 04 00 80 E1                                  white mode
→ A0 20 07 FF FF FE 01 88 2E                         white
→ A0 20 07 FF FF F0 0F 0D 8A                         white
→ A0 20 07 FF FF 00 FF 49 CE                         white
```

The capture also contained **Luma's own earlier attempt** (13:29). Its power frames were byte-for-byte
identical to the app's, and the bulb never answered them. The only thing the app did differently was
the `CCHIP` exchange at the start. So the bulbs require a login.

### Cracking the login

`43 43 48 49 50` is ASCII **"CCHIP"**. The bulb answers the first frame with 2 extra bytes that differ
in every session, which makes them a challenge. The app's next frame contains 2 different bytes, which
makes them the response. Comparing the pairs across all five logins in the capture:

| Bulb | Challenge | App's answer | Challenge XOR answer |
|---|---|---|---|
| …C612 | `06 03` | `22 4F` | `24 4C` |
| …C612 | `00 07` | `24 4B` | `24 4C` |
| …C612 | `06 02` | `22 4E` | `24 4C` |
| …7DD2 | `02 00` | `26 4C` | `24 4C` |
| …C612 | `04 03` | `20 4F` | `24 4C` |

**answer = challenge XOR `24 4C`**, a fixed key that's the same for both bulbs. The bulb then replies
`"CCHIP" 00`, meaning accepted.

### Other details

- **Checksum and length:** all 174 bulb frames in the capture satisfy the strip rules: CRC-16/MODBUS
  little-endian over all preceding bytes, and the length byte = total length − 2. bletrace's
  checksum detector found this on its own.
- **Color** has 4 payload bytes (`R G B 00`). The fourth is probably a white channel the app leaves at
  0. Red came through as `FE 01 00 00` because that's where the app's color wheel landed.
- **`0x12` changes meaning:** on strips it means "effect", on these bulbs it's the **mode switch**
  (`01` color, `00` white). Mixing the two dialects would send garbage, so Luma picks one per light.
- **White** is `FF FF a b` with `a + b = 255` in every sample (`FE+01`, `F0+0F`, `00+FF`, `98+67`):
  a warm/cool balance. Which byte is "warm" still needs confirming on the bulbs
  (`Encoder.warmByteIsFirst`).
- **Status reply** is 45 bytes: power at index 3, mode at 5 (`41` color, `80` white), brightness at 6,
  and the color or white values at 9 onward.
- Commands not needed for control, left alone: `0x41` (returns firmware "3.2.1"), `0x8A` (device ID),
  `0x8F`, `0x83`, and `0x31`, which is a time sync (`07 EA 0B 18 14 2A 16` = 2026-11-24 20:42:22 UTC).

## 8. Building it into Luma

- `Core/Sources/LumaCore/DayBetterProtocol.swift` gained `Login.hello()`, `Login.answer(challenge:)`,
  and parsing for the challenge, login result and long status.
- `Core/Sources/LumaCore/Encoder.swift` builds frames per variant: `.strip` (original) or `.cchip`
  (bulbs). The cchip variant uses 4-byte color, the mode switch, white, and no effects.
- **Variant detection** at connect: Luma sends the hello. If a challenge arrives, the light is `.cchip`
  and Luma answers it. If the light stays silent for 2 s, it's an older strip and is used without a login.
- The hello is sent only after notifications are confirmed on, otherwise the challenge would be lost.
- `Core/Tests/LumaCoreTests/CchipTests.swift` uses **frames copied from the capture** as test
  vectors, so the encoder must reproduce exactly what the official app sent.

First run after the change (pulled from `diagnostics.txt`):

```
→ A0 00 08 43 43 48 49 50 AC CA
← A1 00 0A 43 43 48 49 50 02 06 AC 29
→ A0 01 0A 43 43 48 49 50 26 4A EA 89      (02^24, 06^4C)
← A1 01 09 43 43 48 49 50 00 16 E1          accepted
• Ready (cchip protocol)
→ A0 11 04 00 70 E1
← A1 11 04 01 B0 DD                          the bulb acknowledges a command from Luma
```

---

## Protocol reference: DayBetter P09C ("CCHIP" variant)

| | |
|---|---|
| Advertised name | `P09C_XXXX` |
| Service / write / notify | `E09C` / `A09C` (write without response) / `F09C` (notify), i.e. `E0xx/A0xx/F0xx` for model P0xx |
| Frame | `A0 cmd len payload… crcLo crcHi`, where len = 3 + payload length and CRC = CRC-16/MODBUS over everything before it |
| Reply | `A1 cmd …`. A plain acknowledgement is `A1 cmd 04 01 crc crc` |

| Purpose | Send | Reply |
|---|---|---|
| Login 1 | `A0 00 08 "CCHIP"` | `A1 00 0A "CCHIP" c0 c1` |
| Login 2 | `A0 01 0A "CCHIP" c0^24 c1^4C` | `A1 01 09 "CCHIP" 00` (accepted) |
| Status | `A0 10 04 01` | `A1 10 2D` + 42 bytes (power [3], mode [5], brightness [6]) |
| Power | `A0 11 04 00/01` | ack |
| Mode | `A0 12 04 01` color / `00` white | ack |
| Brightness | `A0 13 04 <0–100>` | ack |
| Color | `A0 15 07 R G B 00` (after color mode) | ack |
| White | `A0 20 07 FF FF a 255−a` (after white mode) | ack |

## Doing this again for another gadget

1. Search GitHub and PyPI for the brand or app name. Prior work saves hours.
2. Build the app with a diagnostics screen and an on-device log you can pull over USB.
3. Read the GATT table: the UUIDs often encode the model, as they did here.
4. If commands are silently ignored, stop guessing and capture the official app: install the Bluetooth
   logging profile, perform one action every ~3 s, trigger a sysdiagnose, then use **bletrace → Pull capture from iPhone**.
5. Label the bursts and compare sessions. A field that changes every session and is echoed back in a
   transformed form is a challenge-response. XOR the pairs first.
6. Turn the captured frames into unit tests before touching the app.
