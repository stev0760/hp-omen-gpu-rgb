# hp-omen-gpu-rgb

Direct Linux control of the **"diamond" RGB logo** on an **HP Omen–branded
NVIDIA RTX 4080 SUPER** — including on non-HP motherboards, where HP's own
OMEN Gaming Hub refuses to run.

![status: working — static colors + off confirmed](https://img.shields.io/badge/status-static%20color%20%2B%20off%20confirmed-brightgreen)
![license: GPL-2.0-or-later](https://img.shields.io/badge/license-GPL--2.0--or--later-blue)
![hardware: HP Omen RTX 4080 SUPER (103c:8cfd)](https://img.shields.io/badge/hardware-HP%20Omen%20RTX%204080%20SUPER%20(103c%3A8cfd)-orange)

## The short version

HP's OMEN Gaming Hub will only drive this card's RGB when it detects an HP
motherboard. Put the card in any other board and the diamond is stuck on its
factory walking-rainbow, with no official way to change it.

This project reverse-engineered the on-board RGB controller's I2C protocol from
HP's own Windows binary and drives it directly from Linux — no HP board, no
HP software. **Arbitrary static colors and off are confirmed working** across
the whole ring. The end goal is to contribute this upstream to **OpenRGB** so
the card is detected and controlled there natively.

> ℹ️ There is no public prior art for this card's protocol. The reason every
> generic RGB tool fails on it: HP uses a proprietary 4-byte command header
> (`06 81 f9 7e`) that none of the known NVIDIA RGB controller families
> (Manli/ENE/PNY/Aura/…) share.

## Hardware

| | |
|---|---|
| GPU | NVIDIA RTX 4080 SUPER (Ada Lovelace) |
| PCI | `10de:2702`, subsystem `103c:8cfd` (HP OEM) |
| Controller | on-board I2C device at `0x49` (7-bit), on the GPU's I2C bus |
| Tested on | ASRock X570 Pro4, Arch Linux, kernel 7.0.x-zen, NVIDIA open 595.x |

> ⚠️ **Tested scope.** Everything in this repo is confirmed on **one card
> only**: the HP Omen RTX 4080 SUPER (`103c:8cfd`). HP sells a range of
> Omen-branded NVIDIA GPUs that very likely share the same on-board RGB
> controller and protocol, so this should be **extensible to other HP Omen GPU
> SKUs** — but those have **not** been verified. If you have a different HP
> Omen GPU, please test and report back (see *Contributing* below); until then,
> treat the protocol as RTX-4080-SUPER-confirmed and otherwise unverified.

## Quick start

You need `i2c-tools` and the `i2c-dev` / `i2c_nvidia` modules loaded so the GPU
I2C busses appear as `/dev/i2c-*`. Most operations need `sudo` (raw bus access).

```bash
# 1. Confirm the controller is there (READ-ONLY, safe):
sudo i2cdetect -y 3        # 0x49 should show up

# 2. Set a solid color (whole ring). Defaults re-assert the write 8x so the
#    color lands clean with no leftover channels:
sudo ./diamond.sh static 255 0 0      # red
sudo ./diamond.sh static 0 255 0      # green
sudo ./diamond.sh static 0 0 255      # blue
sudo ./diamond.sh static 255 40 0     # amber

# 3. Off:
sudo ./diamond.sh off                 # dark
#    (equivalently: sudo ./diamond.sh static 0 0 0)

# 4. Dry-run (print the bytes without sending anything):
DRY=1 ./diamond.sh static 0 255 255
```

`diamond.sh` is self-documenting — run it with no arguments to see all
commands and the struct layout. Full protocol details: [`PROTOCOL.md`](PROTOCOL.md).

## Safety — read before running anything

This project pokes at live hardware over I2C. The rules that keep it safe:

1. **Never probe or write `i2c-0/1/2`** — those are the chipset SMBus carrying
   your **RAM SPD EEPROMs**. A stray write can leave the machine unable to POST.
   The RGB controller is only on the **NVIDIA GPU busses (`i2c-3`…`i2c-8`)**.
2. **Reads before writes.** Probe with `i2cdetect -r` / `i2cdump` first; never
   write to an address you haven't positively identified.
3. **Leave `0x50`/`0x51` alone** — those are EDID/EEPROM for connected monitors.
4. **Back up the VBIOS** (`nvflash --save` from Windows) before any write
   experiments. Writing a flash EEPROM is the one unrecoverable mistake.
5. **RGB writes are recoverable**: a bad state is cleared by a full **PSU
   power-cycle** (off, wait for caps to drain, on), which restores the factory
   rainbow. `diamond.sh` only ever talks to `0x49`.

## What works / what doesn't

| | |
|---|---|
| ✅ Solid color, whole ring, arbitrary RGB | confirmed |
| ✅ Off / dark | confirmed |
| ✅ Non-HP motherboard | confirmed (ASRock X570 Pro4) |
| ⚠️ Animated modes (rainbow/wave/blink/breathing) | mode IDs decoded, **not yet driven/verified** |
| ⚠️ Per-zone segmentation | untested — may be one logical LED group |
| ❌ Firmware-version readback decode | returns a fixed status word; not decoded |

See [`PROTOCOL.md`](PROTOCOL.md) §8 for the open questions.

## Roadmap: OpenRGB integration

This repo is staged to become an **OpenRGB upstream contribution**. The goal is
for OpenRGB to detect the HP Omen RTX 4080 SUPER by PCI ID and control its RGB
natively — on any board — without HP's software.

[`openrgb-integration.md`](openrgb-integration.md) contains the draft
contribution: the PCI ID additions, the `REGISTER_I2C_PCI_DETECTOR` entry, and a
controller class adapted from OpenRGB's existing `ManliGPUController` (same
`0x49` address family, same write-then-read commit idiom), with the HP-specific
deviations — proprietary header, no register byte, mandatory commit-read, and
the re-assertion requirement — called out.

`diamond.sh` is the reproducible proof that the protocol works; the integration
doc is the patch an OpenRGB maintainer can turn into a PR.

## How it was done

Static reverse-engineering of HP's OMEN Gaming Hub, no HP hardware or Windows
needed: pulled the MSIX from Microsoft's Windows Update delivery CDN by its
update category ID, decompiled the .NET assemblies with `ilspycmd`, disassembled
the native `NvidiaApi.dll` with `objdump`, and byte-verified the I2C command
headers and struct layout. Then replayed the exact transaction on Linux with
`i2ctransfer`. Full method in [`PROTOCOL.md`](PROTOCOL.md) §3.

## Contributing

The most useful thing you can add is a **second confirmed SKU**. If you have an
HP Omen GPU that isn't the RTX 4080 SUPER:

1. Confirm the controller is at `0x49` on one of the GPU I2C busses
   (`i2cdetect -y <bus>` — read-only, safe).
2. Try `diamond.sh` and report whether static colors / off work.
3. Note your PCI subsystem `vendor:device` (`lspci -nn -d 10de:`) so it can be
   added as another `REGISTER_I2C_PCI_DETECTOR` entry upstream.

Please open an issue with the results. Confirmed-working SKUs get folded into
the OpenRGB integration (see [`openrgb-integration.md`](openrgb-integration.md))
as additional PCI ID pairs — no new controller code needed if the protocol
matches.

## License

GPL-2.0-or-later — matching [OpenRGB](https://openrgb.org), which is the
upstream target, so this can be merged without relicensing.

## Acknowledgements

The reverse-engineering was greatly accelerated by OpenRGB's existing NVIDIA
I2C controller family (`ManliGPUController`, `EVGAGPUController`, …), which
established the `0x49` address and the write-then-read commit pattern this
protocol builds on.