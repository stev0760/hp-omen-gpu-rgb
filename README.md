# hp-omen-gpu-rgb

Direct Linux control of the "diamond" RGB logo on an HP Omen-branded NVIDIA
RTX 4080 SUPER, including on non-HP motherboards where HP's own OMEN Gaming
Hub refuses to run.

![status: working, all modes confirmed](https://img.shields.io/badge/status-all%20modes%20working-brightgreen)
![license: GPL-2.0-or-later](https://img.shields.io/badge/license-GPL--2.0--or--later-blue)
![hardware: HP Omen RTX 4080 SUPER (103c:8cfd)](https://img.shields.io/badge/hardware-HP%20Omen%20RTX%204080%20SUPER%20(103c%3A8cfd)-orange)

## The short version

HP's OMEN Gaming Hub will only drive this card's RGB when it detects an HP
motherboard. Put the card in any other board and the diamond is stuck on its
factory walking-rainbow with no official way to change it.

This project reverse-engineered the on-board RGB controller's I2C protocol from
HP's own Windows binary and drives it directly from Linux. No HP board or HP
software is involved. Static colors, off, and all of the animated modes
(breathing, blink, wave, color cycle, with speed control) are confirmed working
on hardware. The protocol is also implemented as a native controller in my
[OpenRGB](https://openrgb.org) fork (see below); upstreaming it is the next
step.

There is no public prior art for this card's protocol. Every generic RGB tool
fails on it because HP uses a proprietary 4-byte command header (`06 81 f9 7e`)
that none of the known NVIDIA RGB controller families (Manli/ENE/PNY/Aura/...)
share.

## Why this exists

I bought this card on eBay from an OEM PC spare-parts reseller, taking a slight
gamble. It was a good deal and looked brand new. I didn't know the diamond logo
was RGB until
it lit up in factory rainbow, and it was annoying to discover there was no way
to control it: HP's software refuses to run on a non-HP board, and no generic
RGB tool knew the protocol.

If you bought an HP Omen GPU the same way, or did a motherboard swap on an HP
Omen tower and kept the card, this repo is for you.

Full disclosure: I leaned on AI (Anthropic's Claude) heavily throughout, for
the decompilation analysis, the protocol work, and the OpenRGB controller.
This was niche enough that I would not have gotten there on my own.

## Hardware

| | |
|---|---|
| GPU | NVIDIA RTX 4080 SUPER (Ada Lovelace) |
| PCI | `10de:2702`, subsystem `103c:8cfd` (HP OEM) |
| Controller | on-board I2C device at `0x49` (7-bit), on the GPU's I2C bus |
| Tested on | ASRock X570 Pro4, Arch Linux, kernel 7.1.x-zen, NVIDIA open 610.43.x |

**Tested scope:** everything in this repo is confirmed on one card only, the
HP Omen RTX 4080 SUPER (`103c:8cfd`). HP sells a range of Omen-branded NVIDIA
GPUs that very likely share the same on-board RGB controller and protocol, so
this should extend to other HP Omen GPU SKUs, but those have not been
verified. If you have a different HP Omen GPU, please test and report back
(see *Contributing* below). Until then, treat the protocol as confirmed on the
RTX 4080 SUPER and otherwise unverified.

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

Run `diamond.sh` with no arguments to see all commands and the struct layout.
Full protocol details: [`PROTOCOL.md`](PROTOCOL.md).

## Safety: read before running anything

This project pokes at live hardware over I2C. The rules that keep it safe:

1. **Never probe or write `i2c-0/1/2`.** Those are the chipset SMBus carrying
   your RAM SPD EEPROMs, and a stray write can leave the machine unable to
   POST. The RGB controller is only on the NVIDIA GPU busses (`i2c-3` through
   `i2c-8`).
2. Reads before writes. Probe with `i2cdetect -r` / `i2cdump` first, and never
   write to an address you haven't positively identified.
3. Leave `0x50`/`0x51` alone. Those are EDID/EEPROM for connected monitors.
4. Back up the VBIOS (`nvflash --save` from Windows) before any write
   experiments. Writing a flash EEPROM is the one unrecoverable mistake.
5. RGB writes are recoverable: fix a bad state by committing a new one. Note
   that the committed state persists in the controller's NVRAM, so a PSU
   power-cycle does not reset it, and the factory rainbow is just the
   never-written default (the wave mode with its default red/green/blue
   palette reproduces it). `diamond.sh` only ever talks to `0x49`.

## What works / what doesn't

| | |
|---|---|
| Solid color, whole ring, arbitrary RGB | confirmed |
| Off / dark | confirmed |
| Non-HP motherboard | confirmed (ASRock X570 Pro4) |
| Animated modes: breathing, blink, wave, color cycle, three speed steps | confirmed, via the OpenRGB fork controller |
| Per-zone static segmentation | ruled out: the ring is one logical LED, and the four color slots in the struct are an animation palette, not ring segments |
| Firmware-version readback | replies with a stable version word (`03 5B FC A4`); the field meanings are not decoded |

The scripts in this repo are Linux-only. The OpenRGB fork controller builds and
works on both Linux and Windows (its NvAPI backend matches HP's native call
pattern). See [`PROTOCOL.md`](PROTOCOL.md) §8 for the remaining open questions.

## OpenRGB fork (not yet upstream)

The protocol is implemented as a native OpenRGB controller
(`HPOmenGPUController`) in my fork:
[gitlab.com/stev0760/OpenRGB](https://gitlab.com/stev0760/OpenRGB), branch
`hp-omen-gpu-controller`. It detects the card by PCI subsystem ID and drives
every mode listed above, tested on both Linux and Windows. This has not been
merged upstream yet; an MR against CalcProgrammer1/OpenRGB is the next step.
Until it lands, build the fork with the standard OpenRGB qmake build.

[`openrgb-integration.md`](openrgb-integration.md) is the design doc behind the
controller: the PCI ID additions, the `REGISTER_I2C_PCI_DETECTOR` entry, and a
controller class adapted from OpenRGB's existing `ManliGPUController` (same
`0x49` address family, same write-then-read commit idiom), with the HP-specific
deviations called out: proprietary header, no register byte, mandatory
commit-read, and the re-assertion requirement.

`diamond.sh` (Linux) is the minimal, reproducible proof that the protocol
works without any of the OpenRGB machinery.

## How it was done

Static reverse-engineering of HP's OMEN Gaming Hub, with no HP hardware or
Windows needed: pulled the MSIX from Microsoft's Windows Update delivery CDN by
its update category ID, decompiled the .NET assemblies with `ilspycmd`,
disassembled the native `NvidiaApi.dll` with `objdump`, and byte-verified the
I2C command headers and struct layout. Then replayed the exact transaction on
Linux with `i2ctransfer`. Full method in [`PROTOCOL.md`](PROTOCOL.md) §3.

The rough progression: read-only bus scans located the controller at `0x49` on
the GPU bus (the same address the Manli/EVGA/Palit controller family uses);
the decompiled lighting DLLs gave up the proprietary header and the 30-byte
state struct; replaying that on Linux produced the first working static
colors; and a second decompile pass on HP's `DucatiTriumphLightingControl`
decoded the animated-mode semantics (the speed byte takes 1/3/7, the four
color slots are an animation palette, and a monochrome flag selects between
palette animation and the factory walking rainbow). The response-word matrix
in [`PROTOCOL.md`](PROTOCOL.md) §5 came from hardware testing after an NVIDIA
driver update changed I2C readback behavior mid-project.

## Contributing

The most useful thing you can add is a second confirmed SKU. If you have an
HP Omen GPU that isn't the RTX 4080 SUPER:

1. Confirm the controller is at `0x49` on one of the GPU I2C busses
   (`i2cdetect -y <bus>`, which is read-only and safe).
2. Try `diamond.sh` and report whether static colors / off work.
3. Note your PCI subsystem `vendor:device` (`lspci -nn -d 10de:`) so it can be
   added as another `REGISTER_I2C_PCI_DETECTOR` entry upstream.

Please open an issue with the results. Confirmed-working SKUs get folded into
the OpenRGB integration (see [`openrgb-integration.md`](openrgb-integration.md))
as additional PCI ID pairs. If the protocol matches, no new controller code is
needed.

## License

GPL-2.0-or-later, matching [OpenRGB](https://openrgb.org), which is the
upstream target, so this can be merged without relicensing.

## Acknowledgements

The reverse-engineering was greatly accelerated by OpenRGB's existing NVIDIA
I2C controller family (`ManliGPUController`, `EVGAGPUController`, ...), which
established the `0x49` address and the write-then-read commit pattern this
protocol builds on.
