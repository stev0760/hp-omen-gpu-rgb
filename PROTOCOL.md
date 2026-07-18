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
| 2 | `Speed` | animated modes only; HP uses exactly `0x01`=slow, `0x03`=medium, `0x07`=fast (`LedRunSpeed` switch in `DucatiTriumphLightingControl.RestartLighting`); `0x00` for static |
| 3 | `Monochrome` | `1` = ring shows one palette color at a time; `0` = palette spread spatially (HP sets `0` for static and for its rainbow Wave theme, `1` for all other animations) |
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

**The four "zone" slots are an animation color palette, not fixed ring
segments.** Decompiled `DucatiTriumphLightingControl.RestartLighting` fills
slots 0..N-1 with the selected theme's color list (HP themes carry 2–3
colors) and the firmware cycles/waves/blinks/breathes through the enabled
slots. HP's static path populates **slot 0 only** with `Monochrome=0`.
Whether static + `Monochrome=0` + multiple enabled slots lights distinct
sub-ring segments is untested — see §8.

HP's built-in theme palettes (embedded JSON resource
`ColorCycleTheme.json` in `HP.Omen.Background.TuringBg.dll`):

| Theme | Palette |
|---|---|
| Galaxy | `#FF0000 #00FF00 #0000FF` (the factory rainbow) |
| Volcano | `#F9350F #F9980F #F9CE0F` |
| Jungle | `#36F90F #A0C80F #F9BE0F` |
| Ocean | `#0FF9F9 #0F0FF9 #840FF9` |
| Unicorn | `#EC6EAD #CF4ED6 #6F48AA` |
| Valorant | `#2424FF #FFFFFF` |

Special case: **Wave + Galaxy is sent with `Monochrome=0`** (spatial
rainbow — the factory look); every other theme/animation combination uses
`Monochrome=1`.

### `LedMode` values

| Value | Mode |
|---|---|
| `0` | color cycle (cycles the whole ring through the palette) |
| `1` | wave (factory "walking rainbow" = wave + R/G/B palette + `Monochrome=0`) |
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
read channel returns real data for the first time. The response depends on the
command written (full matrix hardware-verified 2026-07-18):

| Transaction | 4-byte readback |
|---|---|
| set-lighting (`06 81 f9 7e` …) write-then-read | `01 5a fe a5` — "accepted" ack |
| get-version (`07 81 f8 7e` …) write-then-read | `03 5b fc a4` — version word (see §7) |
| bare read, no write in the same transaction | `ff ff ff ff` |
| get-version on the phantom bus (see §8) | `77 77 77 77` — junk echo |

The response is only armed **within** the write-then-read transaction
(repeated START). A standalone `r4@0x49` normally reads `0xff`s — a
post-write bare read returning `01 5a fe a5` was observed once on an earlier
driver (610.43.02) but does not survive a GPU reset and must not be relied on.

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

then a 4-byte read. The readback on this card is:

```
0x03 0x5b 0xfc 0xa4
```

This is a **distinct, stable version word**: it is returned repeatably, both
before and immediately after set-lighting writes, and differs from the
set-lighting ack (`01 5a fe a5`). Its field encoding is undecoded. (An early
capture on driver 610.43.02 saw the probe answer `01 5a fe a5` instead —
which of the two words a fresh probe returns appears to depend on controller
state after a GPU reset, so identification probes should accept either.)

**The get-version query is non-mutating**: hardware-verified (2026-07-18)
that repeated getver transactions leave the displayed lighting completely
untouched — the diamond held its static color throughout. It is therefore
safe as a detection probe. Note the readback survives a warm reboot
differently than the display state: after a GPU reset (driver reload, no
standby-power loss) the diamond keeps showing its last-written state, but
bare reads return to `0xff` until the next write-then-read.

---

## 8. Open questions

- **Per-zone static addressing.** The four slots are an animation *palette*
  (see §4); HP's app never sets more than slot 0 in static mode. Whether
  static + `Monochrome=0` + multiple enabled slots with different colors
  lights distinct sub-ring segments (i.e. the firmware repurposes the palette
  spatially, as it does for `Monochrome=0` wave) — or the extra slots are
  ignored — needs a split-test: `raw 06 81 f9 7e 04 ff 00 00 01 ff 00 00
  00 00 00 00 01 00 00 ff 00 00 00 00` (slot0 red + slot2 blue).
- **Animated modes.** Semantics decoded from `DucatiTriumphLightingControl`:
  palette in slots, speed ∈ {1, 3, 7}, brightness 255, `Monochrome=1`
  (except rainbow wave). Early tests that sent speed=50 and an all-black or
  single-color 4-slot palette showed only breathing working — consistent
  with the decode; visual verification with correct packets is in progress.
  Whether speed bytes other than 1/3/7 are valid is untested.
- **The phantom bus.** One of the GPU's I2C busses (observed at `i2c-7`,
  "NVIDIA i2c adapter 5") ACKs writes at **every** address and echoes junk on
  reads (`77 77 77 77` to the getver probe). Any scanner or detector must
  identify the real controller by an exact response word, not by ACK — on
  this card only the ack `01 5a fe a5` / version word `03 5b fc a4` qualify.
- **Readback word meaning.** The set-lighting ack `01 5a fe a5` and version
  word `03 5b fc a4` are undecoded (curiosity: they XOR to `02 01 02 01`).
  They are sufficient as "accepted"/identity sentinels.
- **Which word a fresh probe gets.** After the 610.43.03 driver update + warm
  reboot, getver consistently answers `03 5b fc a4`; on 610.43.02 the same
  probe answered `01 5a fe a5`. Whether that flip was driver behavior or
  controller state is unresolved — probes must accept both.

---

## 9. Recovery

RGB-controller writes are **recoverable**. If a bad write leaves the diamond in
an unwanted state: issue `off` (`LedMode=5`). If the controller becomes
unresponsive or latched in a bad way: a **full PSU power-cycle** (power off,
wait for capacitors to drain, power on) restores the factory walking-rainbow
default. Do **not** confuse this with VBIOS writes — those are not recoverable
this way, hence rule 5 in §2.