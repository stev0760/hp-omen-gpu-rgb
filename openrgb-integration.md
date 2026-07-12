# OpenRGB integration sketch

This is a draft of the contribution the project is staged for: a native
OpenRGB controller for the HP Omen GPU "diamond" RGB, so OpenRGB can detect and
control the HP Omen RTX 4080 SUPER (and sibling HP Omen SKUs) **on non-HP
boards**, without HP's OMEN Gaming Hub.

It is adapted from OpenRGB's existing `ManliGPUController` (the closest analog
— same I2C address family `0x49`, same write-then-read commit idiom), with the
HP-specific deviations called out. The C++ below is a **faithful sketch**, not a
drop-in patch: pin it against the OpenRGB `main` branch at contribution time and
reconcile any API drift (mode enum names, `RGBController` base interface,
`i2c_smbus_interface` method signatures).

Protocol reference: `PROTOCOL.md`. License: GPL-2.0-or-later (matches OpenRGB).

---

## What changes upstream

Three additions to OpenRGB:

1. **PCI ID constants** in `pci_ids/pci_ids.h` (HP subsystem IDs are not yet
   defined there).
2. A new controller directory `Controllers/HPOmenGPUController/` with the five
   files below, mirroring the `ManliGPUController` layout.
3. A line in the controller `CMakeLists` / `controllers.mk` build list.

---

## 1. PCI ID additions (`pci_ids/pci_ids.h`)

Manli registers with NVIDIA's *subsystem* vendor `0x10DE`
(`NVIDIA_SUB_VEN`). The HP card presents **HP's own subsystem vendor `0x103C`**,
so a distinct subvendor constant is required, plus the subsystem device:

```c
#define HP_VEN                                  0x103C
#define HP_RTX4080S_OMEN_SUB_DEV                0x8CFD
```

(`NVIDIA_RTX4080S_DEV = 0x2702` already exists in `pci_ids.h`.)

---

## 2. Detector (`HPOmenGPUControllerDetect.cpp`)

The key difference from Manli's detector: the **probe is a write-then-read**,
because the HP controller returns all `0xff` on a naive read (block-protocol
signature — see PROTOCOL.md §2/§5). Manli's `i2c_write_block` then
`i2c_read_block` pattern already does this; HP just uses a different probe
header.

```cpp
/*---------------------------------------------------------*\
|  HPOmenGPUControllerDetect.cpp                             |
|  Detector for HP Omen GPU "diamond" RGB                   |
|  SPDX-License-Identifier: GPL-2.0-or-later                 |
\*---------------------------------------------------------*/

#include "Detector.h"
#include "HPOmenGPUController.h"
#include "RGBController_HPOmenGPU.h"
#include "i2c_smbus.h"
#include "pci_ids.h"
#include "LogManager.h"

void DetectHPOmenGPUControllers(i2c_smbus_interface* bus, u8 i2c_addr, const std::string& name)
{
    // Probe = HP "set lighting" header + a zeroed struct, then a read.
    // The controller answers a write-then-read; a bare read returns 0xff.
    u8 data_pkt[24] = { 0x06, 0x81, 0xF9, 0x7E,           // set-lighting header
                        0x05, 0x00, 0x00, 0x00,           // LedMode=5 (off), rest 0
                        0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00 };

    if(bus->i2c_write_block(i2c_addr, sizeof(data_pkt), data_pkt) < 0)
    {
        return;
    }

    u8  rdata_pkt[I2C_SMBUS_BLOCK_MAX] = { 0x00 };
    int rdata_len                       = sizeof(rdata_pkt);

    if(bus->i2c_read_block(i2c_addr, &rdata_len, rdata_pkt) >= 0)
    {
        // Optional: reject if readback is all 0xff (not the real device).
        // Confirmed-good readback on the RTX 4080 SUPER is 0x01 0x5a 0xfe 0xa5.
        bool all_ff = true;
        for(int i = 0; i < rdata_len && i < 4; i++)
            if(rdata_pkt[i] != 0xFF) { all_ff = false; break; }
        if(all_ff)
        {
            LOG_ERROR("[%s] HP Omen RGB probe returned all 0xFF — not registering", name.c_str());
            return;
        }

        HPOmenGPUController*     controller     = new HPOmenGPUController(bus, i2c_addr, name);
        RGBController_HPOmenGPU* rgb_controller = new RGBController_HPOmenGPU(controller);
        ResourceManager::get()->RegisterRGBController(rgb_controller);
    }
}

// HP presents its own subsystem vendor 0x103C (unlike Manli, which uses 0x10DE).
REGISTER_I2C_PCI_DETECTOR("HP OMEN GeForce RTX 4080 SUPER",
                          DetectHPOmenGPUControllers,
                          NVIDIA_VEN, NVIDIA_RTX4080S_DEV,
                          HP_VEN, HP_RTX4080S_OMEN_SUB_DEV,
                          0x49);
```

⚠️ **Probe-write caveat.** The detector above sends a real `off` command to
probe. That momentarily blanks the diamond. If upstream prefers a non-mutating
probe, use the **get-firmware-version** header `07 81 f8 7e` (see PROTOCOL.md §7)
with the documented 20-byte body instead — it is a read-only query and should
not change lighting state. Verify on hardware before submitting.

---

## 3. Controller (`HPOmenGPUController.h` / `.cpp`)

Deviations from the Manli template, all grounded in PROTOCOL.md:

- **No register byte.** HP uses `regAddrSize=0`; the command lives in the first
  4 payload bytes. Use `i2c_write_block` (raw) rather than
  `i2c_smbus_write_i2c_block_data` (which prepends a register byte). The whole
  24-byte packet is `header(4) + struct(20)`.
- **Mandatory trailing read.** Every write must be followed by a 4-byte read to
  commit (write-then-read). Without it the controller ignores writes.
- **Re-assertion.** A single write-then-read updates channels only partially
  (PROTOCOL.md §6). `SetMode` re-asserts the transaction `N` times (8 proven)
  with a short sleep so all RGB channels flush to the target.

```cpp
/*---------------------------------------------------------*\
|  HPOmenGPUController.h                                     |
|  SPDX-License-Identifier: GPL-2.0-or-later                 |
\*---------------------------------------------------------*/
#pragma once
#include <string>
#include "i2c_smbus.h"
#include "RGBController.h"

// HP proprietary command headers (byte-confirmed in OMEN Gaming Hub)
#define HP_OMEN_HDR_SET_LIGHTING    0x06, 0x81, 0xF9, 0x7E
#define HP_OMEN_HDR_GET_VERSION     0x07, 0x81, 0xF8, 0x7E

enum
{
    HP_OMEN_GPU_MODE_COLOR_CYCLE  = 0x00,
    HP_OMEN_GPU_MODE_WAVE         = 0x01,
    HP_OMEN_GPU_MODE_STROBE       = 0x02,
    HP_OMEN_GPU_MODE_BREATHING    = 0x03,
    HP_OMEN_GPU_MODE_STATIC       = 0x04,
    HP_OMEN_GPU_MODE_OFF          = 0x05,
};

struct HPOmenGPUState
{
    u8          mode        = HP_OMEN_GPU_MODE_STATIC;
    u8          brightness = 0xFF;
    u8          speed       = 0x00;
    u8          monochrome  = 0x01;
    RGBColor    zones[4]    = { 0, 0, 0, 0 };   // one color per zone
};

class HPOmenGPUController
{
public:
    HPOmenGPUController(i2c_smbus_interface* bus, u8 dev, std::string dev_name);
    ~HPOmenGPUController();

    std::string GetDeviceLocation();
    std::string GetName();
    std::string GetVersion();

    bool SetState(HPOmenGPUState state);

private:
    i2c_smbus_interface*    bus;
    u8                      dev;
    std::string             name;
    std::string             version;

    bool SendCommit(const u8 pkt[24]);   // write-then-read, the commit primitive
};
```

```cpp
/*---------------------------------------------------------*\
|  HPOmenGPUController.cpp                                   |
|  SPDX-License-Identifier: GPL-2.0-or-later                 |
\*---------------------------------------------------------*/
#include "HPOmenGPUController.h"

HPOmenGPUController::HPOmenGPUController(i2c_smbus_interface* bus, u8 dev, std::string dev_name)
{
    this->bus  = bus;
    this->dev  = dev;
    this->name = dev_name;
}

bool HPOmenGPUController::SendCommit(const u8 pkt[24])
{
    // Raw 24-byte write (no register byte — regAddrSize=0 in HP's native call).
    if(bus->i2c_write_block(dev, 24, const_cast<u8*>(pkt)) < 0)
        return false;

    // Mandatory trailing 4-byte read commits the transaction (write-then-read).
    u8  rdata[I2C_SMBUS_BLOCK_MAX] = { 0 };
    int rlen = sizeof(rdata);
    if(bus->i2c_read_block(dev, &rlen, rdata) < 0)
        return false;

    return true;   // readback is a fixed 0x01 0x5a 0xfe 0xa5 "accepted" word
}

bool HPOmenGPUController::SetState(HPOmenGPUState s)
{
    u8 pkt[24] = { HP_OMEN_HDR_SET_LIGHTING,                  // bytes 0-3
                   s.mode, s.brightness, s.speed, s.monochrome };  // 4-7
    for(int z = 0; z < 4; z++)
    {
        pkt[8 + z*4] = 0x01;                                  // LedEnableN
        pkt[9 + z*4] = RGBGetRValue(s.zones[z]);
        pkt[10+ z*4] = RGBGetGValue(s.zones[z]);
        pkt[11+ z*4] = RGBGetBValue(s.zones[z]);
    }

    // A single write-then-read updates channels only partially (PROTOCOL §6).
    // Re-assert 8x so all channels flush — mirrors HP's native ~3000x loop.
    for(int i = 0; i < 8; i++)
    {
        if(!SendCommit(pkt))
            return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return true;
}

std::string HPOmenGPUController::GetDeviceLocation()
{
    char addr[5]; snprintf(addr, 5, "0x%02X", dev);
    return ("I2C: " + std::string(bus->device_name) + ", address " + addr);
}
std::string HPOmenGPUController::GetName()    { return name; }
std::string HPOmenGPUController::GetVersion() { return version; }
```

---

## 4. RGBController wrapper (`RGBController_HPOmenGPU.h` / `.cpp`)

Standard OpenRGB `RGBController` subclass: one zone, four LEDs (or one led,
whole-ring), modes mapped from the `HP_OMEN_GPU_MODE_*` enum. Static + off are
verified; color cycle / wave / breathing / strobe should be registered but
flagged experimental until the speed/brightness scaling is confirmed on
hardware (PROTOCOL §8). Brightness is applied by scaling `Brightness` byte
(`0x00`–`0xFF`, HP uses ×2.55 from a 0–100 UI value).

This wrapper is intentionally not fully fleshed out here — it is boilerplate
against the current `RGBController` base and is best finalized against the
OpenRGB `main` branch at PR time. The controller above is the non-obvious part;
the wrapper is mechanical.

---

## Notes for the upstream PR

- Confirm the **non-mutating probe** question (get-version header vs off) on
  hardware before submitting — detectors run for every matching PCI device at
  startup and ideally should not blank a user's lighting.
- The HP card's subsystem vendor is `0x103C`, **not** NVIDIA's `0x10DE`. Getting
  this wrong is the one-line bug that would make detection silently fail.
- The re-assertion loop (8×, 50 ms) is what makes color changes clean. Dropping
  it reproduces the "partial channel update" lag. If upstream prefers fewer
  writes, a smaller count (≥4) likely still works; 1 does not.
- Related HP Omen SKUs (other RTX 40-series HP OEM cards) likely share the
  protocol. If so, add their `(dev, subdev)` pairs as additional
  `REGISTER_I2C_PCI_DETECTOR` lines rather than copying the controller.