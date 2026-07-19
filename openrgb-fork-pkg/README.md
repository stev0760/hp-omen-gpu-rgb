# openrgb-fork-pkg: why the system OpenRGB is a custom build

The installed `openrgb` package is not the Arch repo version. It's built from my
OpenRGB fork (`~/Projects/OpenRGB`, branch `hp-omen-gpu-controller`,
https://gitlab.com/stev0760/OpenRGB) and carries two things upstream doesn't
have yet:

1. **HPOmenGPUController**: controls the diamond RGB on the HP Omen RTX 4080
   SUPER (i2c-3, address 0x49) on non-HP boards.
2. **Patriot Viper Steel legacy detector**: a direct quick-write probe of 0x77
   on the AMD FCH SMBus. Upstream's SPD-gated detector never finds these DIMMs.

Check what's installed with `openrgb --version`. The fork reports branch
`hp-omen-gpu-controller`.

## Why `pacman -Syu` never replaces it

The PKGBUILD sets `epoch=1`, so the installed `1:0.9.xxxx.g<hash>` always
outranks the repo's epoch-less version (`1.0rc3`, `1.0`, whatever comes next).
`-Syu` silently skips openrgb. This is intentional; update the system freely.

## OpenRGB suddenly won't start after an update

This is the expected failure for this setup. The binary links `qt5-base`,
`hidapi`, `libusb`, and `mbedtls`. When Arch bumps one of those libraries'
sonames, repo packages get rebuilt but this one doesn't, and openrgb fails
with:

    openrgb: error while loading shared libraries: libXXX.so.N: cannot open shared object file

The fix is to rebuild against the current libs. The PKGBUILD pulls from the
local clone:

    cd ~/Projects/openrgb-fork-pkg
    makepkg -sf
    sudo pacman -U openrgb-1:*.pkg.tar.zst

The same commands apply after committing new work on the branch. Note that
`makepkg` clones the local repo, so it only sees committed files on
`hp-omen-gpu-controller`.

## Config landmine: "ENE SMBus DRAM" must stay disabled

`"ENE SMBus DRAM": false` is required in the `Detectors` section of every
config that runs detection:

- `~/.config/OpenRGB/OpenRGB.json` when running as a user, which works thanks
  to the packaged udev rules
- `/root/.config/OpenRGB/OpenRGB.json` when running under sudo

If it's ever `true`, its byte-read probe of 0x77 wedges the Viper Steel
controller: the RAM shows up but won't change color, then disappears from
detection entirely, and stays broken across reboots because the chip is on
standby power. Recovery is a full cold power-off: shutdown, PSU switch off,
hold the power button about 5 seconds, wait about 20 seconds, boot. A fresh
config (new user, deleted config) recreates the landmine, so re-disable it.

## Going back to the repo package (after the upstream MR lands)

A plain `-Syu` can't downgrade past the epoch. Switch back deliberately:

    sudo pacman -Syuu        # allows the "downgrade" to the repo's epoch-less version

Only do this once a repo release actually contains both fixes, or the HP
diamond and the Viper Steel RAM stop working again.
