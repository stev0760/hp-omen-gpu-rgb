# HP Omen GPU "diamond" RGB — I2C Protocol Specification

Reverse-engineered protocol for driving the RGB "diamond" logo on an
**HP Omen–branded NVIDIA RTX 4080 SUPER** from Linux, including on non-HP
motherboards where HP's own OMEN Gaming Hub refuses to run.

This document is the authoritative spec. It is intended to be sufficient for an
OpenRGB contributor to implement a native controller class (see
`openrgb-integration.md`) — or for anyone to drive the device directly over I2C
(see `diamond.sh`).

---

## 1. Hardware target

| Field | Value |
|---|---|
| GPU | NVIDIA RTX 4080 SUPER (Ada Lovelace) |
| PCI vendor:device | `10de:2702` |
| PCI subsystem vendor:device | `103c:8cfd` (HP OEM) |
| Test motherboard | ASRock X570 Pro4 (non-HP) |
| RGB element | "diamond" logo on the card's shroud |
| Controller | on-board I2C device at address `0x49` (7-bit) |

The same HP Omen branding/RGB scheme appears across HP's NVIDIA GPU SKUs. The
protocol here is confirmed working on the RTX 4080 SUPER; related SKUs are
likely to follow it, but only `103c:8cfd` has been verified on live hardware.

---

## 2. I2C bus map and safety

⚠️ **Read this before touching any I2C bus.** This project pokes at live
hardware and the cost of a mistake is an unrecoverable brick or a machine that
won't POST.

On a typical Arch + NVIDIA-open system the I2C busses are:

| Bus | Carries | Off-limits? |
|---|---|---|
| `i2c-0`, `i2c-1`, `i2c-2` | chipset SMBus → **RAM SPD EEPROMs** | **YES — never probe or write.** A stray write can leave the machine unable to POST. |
| `i2c-3` … `i2c-8` | NVIDIA GPU I2C (EDID, thermal, **RGB controller**) | target lives here |

The RGB controller is on **`i2c-3`, address `0x49`** on this card. Addresses
`0x50`/`0x51` on the GPU busses are EDID/EEPROM for the connected DisplayPort
monitors — **leave them alone.**

Hard rules:

1. Never probe or write `i2c-0/1/2`.
2. Reads before writes — probe with `i2cdetect -y -r` / `i2cdump` first.
3. Never write to `0x50`/`0x51`.
4. Confirm the exact command and target address before any I2C write.
5. Back up the VBIOS (`nvflash --save` from Windows) before any write
   experiments. Writing a flash EEPROM is the one unrecoverable mistake;
   RGB-controller writes are recoverable via a full **PSU power-cycle**
   (switch off, wait for caps to drain, switch on).

`i2cdetect` will show `0x49` responding on `i2c-3`. On a naive byte-read it
returns all `0xff` — that is **not** a dead device; it is the signature of a
**block-protocol controller** that only answers a write-then-read transaction
(see §5). `0x25` on `i2c-4` is thermal/power telemetry, unrelated.

---

## 3. How the protocol was recovered

Static reverse-engineering of HP's own Windows binary — no HP hardware or
Windows required:

1. Downloaded the OMEN Gaming Hub MSIX from Microsoft's Windows Update FE3
   delivery CDN, keyed by its `WuCategoryId` (SOAP: `GetCookie` →
   `SyncUpdates` → `GetExtendedUpdateInfo2`). No HP board needed.
2. Decompiled the managed (.NET) assemblies with `ilspycmd`. The GPU diamond
   driver is `HP.Omen.Background.TuringBg.dll`, class `DucatiTriumphLightingControl`,
   which fills a 20-byte `Rtxi2CLightingData` struct and calls
   `NvApiWrapper.SetNvidiaI2CLighting` → P/Invokes native `NvidiaApi.dll!NvidiaI2CLighting`.
3. Disassembled `NvidiaApi.dll` with `objdump`. The native code issues an
   **NvAPI I2C transaction** (`NV_I2C_INFO_V3`, version `0x30040`):
   - `i2cDevAddress = 0x92` → 7-bit `0x49` (matches the probed address)
   - `regAddrSize = 0` → **no register byte** (raw write, the command is in the payload itself)
   - `cbSize = 24`
   - 100 kHz, retried up to ~3000× in a poll loop
4. Byte-verified the HP command headers and the struct layout directly in the
   binary, then replayed the transaction on Linux with `i2ctransfer`.

This is why every prior public attempt (Manli/ENE/PNY/Aura-style) failed: they
all lead with the wrong header bytes. HP uses its own proprietary 4-byte
command header.

---

## 4. On-wire format

Every set-lighting transaction is a **24-byte raw I2C write to `0x49`**
(register address size = 0 — the "command" is the first 4 payload bytes),
immediately followed by a **4-byte read** (see §5 for why the read is mandatory).

```
[ 4-byte HP command header ][ 20-byte Rtxi2CLightingData struct ]
```

### Command headers (byte-confirmed in the binary)

| Command | Header bytes |
|---|---|
| Set lighting | `06 81 f9 7e` |
| Get firmware version | `07 81 f8 7e` |

### `Rtxi2CLightingData` struct (20 bytes, sequential, no padding)

| Byte | Field | Notes |
|---|---|---|
| 0 | `LedMode` | mode enum, see below |
| 1 | `Brightness` | `0x00`–`0xff` (HP scales 0–100 → ×2.55) |
| 2 | `Speed` | effect speed for animated modes; `0x00` for static |
| 3 | `Monochrome` | `1` = all zones share one color; `0` = per-zone |
| 4 | `LedEnable0` | zone 0 enable (`0`/`1`) |
| 5 | `Red0` | |
| 6 | `Green0` | |
| 7 | `Blue0` | |
| 8 | `LedEnable1` | zone 1 enable |
| 9–11 | `Red1 Green1 Blue1` | |
| 12 | `LedEnable2` | zone 2 enable |
| 13–15 | `Red2 Green2 Blue2` | |
| 16 | `LedEnable3` | zone 3 enable |
| 17–19 | `Red3 Green3 Blue3` | |

The diamond exposes 4 logical zones around the ring. For a solid whole-ring
color, set all four zones' enable=1 and RGB to the same value, with
`Monochrome=1`. (HP's exact single-zone path uses `Monochrome=0` and only
zone 0 populated; whether per-zone addressing produces distinct sub-ring
segments has not yet been split-tested — see §8.)

### `LedMode` values

| Value | Mode |
|---|---|
| `0` | color cycle (the factory "walking rainbow") |
| `1` | wave |
| `2` | blink / strobe |
| `3` | breathing |
| `4` | static color |
| `5` | off |

### Example: solid red, full brightness, whole ring

```
header:  06 81 f9 7e
struct:  04 ff 00 01   01 ff 00 00   01 ff 00 00   01 ff 00 00   01 ff 00 00
         |mode|bri|spd|mono| z0(en,R,G,B) |  z1  |    z2    |    z3    |
```

---

## 5. The commit mechanism: write-then-read (mandatory)

A lone 24-byte write with the correct header **freezes the default walking
rainbow and latches the controller** into host-control mode, but **does not
reliably commit the new state.** Subsequent lone writes are then ignored.

The fix, recovered from HP's native code, is to **append a 4-byte I2C read**
to every write — a write-then-read transaction with a repeated START:

```
i2ctransfer -y 3 w24@0x49 <24 payload bytes> r4@0x49
```

This mirrors HP's native "poll until nonzero" loop. With the trailing read, the
read channel returns real data for the first time:

```
0x01 0x5a 0xfe 0xa5
```

This is a fixed status/ID word (constant across set-lighting, get-version, and
bare reads). It is not the firmware version; the nonzero value is what satisfies
HP's success check. Earlier probing only ever saw `0xff` because it never
performed the write-then-read.

**This trailing read is required on every command.** `diamond.sh` does it by
default (`RD=1`).

---

## 6. Re-assertion: a single write updates channels only partially

Even with the commit read in place, **a single write-then-read updates the
controller's RGB channels only partially.** Observed symptom: issuing
`static 0 0 0` (blue) immediately after a red/amber state produced **magenta** —
the red channel was stale from the previous state and only the blue channel
updated. The same lag is what makes a color change look like "it switches off,
then the right color cycles in."

HP's native driver does **not** write once — it re-asserts the same transaction
in its retry loop (up to ~3000×) until the readback pins. Reproducing that is
the cure: **send the write-then-read several times in quick succession** so all
channels flush to the target. `diamond.sh` defaults to `REP=8` (8 re-asserts
with a 50 ms gap), which produces clean, immediate color changes with no stale
channels. A single-shot write is recoverable but visually laggy; re-asserting
is the correct behavior and matches HP.

---

## 7. Get firmware version

Header `07 81 f8 7e` followed by the 20-byte body recovered from the
`NvidiaI2CFwVersion` disassembly:

```
07 81 f8 7e
04 00 01 01   01 00 00 00   01 00 00 00   01 00 00 00   01 00 00 00
```

then a 4-byte read. The readback on this card is still `0x01 0x5a 0xfe 0xa5`
(the same fixed status word), so a distinct firmware-version decode is not yet
confirmed — the meaningful "version" may require a different query body or a
longer read. The set-lighting path does not depend on this.

---

## 8. Open questions

- **Per-zone addressing.** All four zones set together (Monochrome=1) produces a
  solid whole-ring color. Whether populating zones individually (Monochrome=0,
  only some `LedEnable`=1) drives distinct sub-ring segments — or whether the
  diamond is physically a single LED group that ignores zone separation — has
  not been split-tested. Worth a quick `zone0 R G B` experiment.
- **Animated modes.** Mode IDs 0–3 (color cycle / wave / blink / breathing) are
  decoded from the struct but have **not** been driven and visually verified.
  Speed and brightness scaling for each are unknown. Static + off are
  confirmed; effects are a follow-up.
- **Readback word meaning.** `0x01 0x5a 0xfe 0xa5` is constant; its fields are
  undecoded. It is sufficient as an "accepted" sentinel.

---

## 9. Recovery

RGB-controller writes are **recoverable**. If a bad write leaves the diamond in
an unwanted state: issue `off` (`LedMode=5`). If the controller becomes
unresponsive or latched in a bad way: a **full PSU power-cycle** (power off,
wait for capacitors to drain, power on) restores the factory walking-rainbow
default. Do **not** confuse this with VBIOS writes — those are not recoverable
this way, hence rule 5 in §2.