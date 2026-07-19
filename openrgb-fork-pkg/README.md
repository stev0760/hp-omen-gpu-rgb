# openrgb-fork-pkg — why the system OpenRGB is a custom build

The installed `openrgb` package is **not** the Arch repo version. It's built from my
OpenRGB fork (`~/Projects/OpenRGB`, branch `hp-omen-gpu-controller`,
https://gitlab.com/stev0760/OpenRGB) and carries two things upstream doesn't have (yet):

1. **HPOmenGPUController** — controls the diamond RGB on the HP Omen RTX 4080 SUPER
   (i2c-3 addr 0x49) on non-HP boards.
2. **Patriot Viper Steel legacy detector** — direct quick-write probe of 0x77 on the
   AMD FCH SMBus; upstream's SPD-gated detector never finds these DIMMs.

Check what's installed: `openrgb --version` (fork shows branch `hp-omen-gpu-controller`).

## Why `pacman -Syu` never replaces it

The PKGBUILD sets `epoch=1`, so the installed `1:0.9.xxxx.g<hash>` always outranks the
repo's epoch-less version (`1.0rc3`, `1.0`, whatever). `-Syu` silently skips openrgb.
This is intentional. Update the system freely.

## "OpenRGB suddenly won't start after an update" — THIS is the expected failure

The binary links `qt5-base`, `hidapi`, `libusb`, `mbedtls`. When Arch bumps one of
those libraries' sonames, repo packages get rebuilt — this one doesn't. Symptom:

    openrgb: error while loading shared libraries: libXXX.so.N: cannot open shared object file

Fix (rebuild against current libs — the PKGBUILD pulls from the local clone):

    cd ~/Projects/openrgb-fork-pkg
    makepkg -sf
    sudo pacman -U openrgb-1:*.pkg.tar.zst

Same commands apply after committing new work on the branch. Note: `makepkg` clones the
local repo — it only sees **committed** files on `hp-omen-gpu-controller`.

## Config landmine: "ENE SMBus DRAM" must stay disabled

`"ENE SMBus DRAM": false` is required in the `Detectors` section of **every** config
that runs detection:

- `~/.config/OpenRGB/OpenRGB.json` (running as user — works thanks to packaged udev rules)
- `/root/.config/OpenRGB/OpenRGB.json` (running under sudo)

If it's ever `true`, its byte-read probe of 0x77 wedges the Viper Steel controller:
RAM shows up but won't change color, then disappears from detection entirely, and
stays broken across reboots (the chip is on standby power). Recovery = full cold
power-off: shutdown, PSU switch off, hold power button ~5 s, wait ~20 s, boot.
A fresh config (new user, deleted config) recreates the landmine — re-disable it.

## Going back to the repo package (after the upstream MR lands)

A plain `-Syu` can't downgrade past the epoch. Switch back deliberately:

    sudo pacman -Syuu        # allows the "downgrade" to the repo's epoch-less version

Only do this once a repo release actually contains both fixes, or the HP diamond and
the Viper Steel RAM stop working again.
