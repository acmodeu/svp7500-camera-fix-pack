# AI Agent Guide & Repository Context

Welcome, AI agent! This repository contains reverse-engineered kernel drivers, userspace wrappers, and tooling to enable the webcam and IR face-unlock sensor on Intel IPU7 laptops behind a Synaptics SVP7500 CVS bridge.

## Primary Task Documentation
For a complete technical breakdown of the reverse-engineering work, architecture, resolved bugs, and hardware details for Intel Lunar Lake (LNL) and the Dell Pro 14 PB14250, read:
👉 **[`docs/TASK-LUNAR-LAKE.md`](docs/TASK-LUNAR-LAKE.md)**

## Key Rules & Guardrails
1. **Bridge Protocol 1.0 & Privacy LED:**
   - In `intel_cvs.c`, `SET_HOST_IDENTIFIER` (0x0805) must remain dispatched unconditionally with `privacy_led_host = 1` and `rgbcamera_pwrup_host = 1`.
   - Never clear `rgbcamera_pwrup_host = 1` (it corrupts MIPI PHY clock timing).
2. **INT3472 & Modern Kernels (>= 7.1):**
   - Do NOT install `int3472-patched` if `tools/int3472-needed.sh` returns exit code 1.
   - The in-tree `intel_skl_int3472_discrete` driver already provides `/sys/class/leds/*::ir_flood_led`. Overwriting it breaks Howdy face authentication.
3. **No Silent Initramfs Calls:**
   - Never redirect initramfs commands to `/dev/null` (`mkinitcpio -P`, `dracut`, etc.). Distros like CachyOS have interactive bootloader hooks (e.g. Limine) in `/usr/local/bin/mkinitcpio` that block on `read` if stdout/stderr are suppressed.
4. **V4L2 Device Isolation:**
   - Never expose raw IPU7 ISYS endpoints (`/dev/video0..31`) to legacy V4L2 / Qt / WebRTC applications. Always route through `scripts/qrca` using Bubblewrap (`bwrap`) isolation and `/dev/video50` (`v4l2loopback`).

## Essential Commands
- **Check Hardware Compatibility:** `./tools/check-hardware.sh`
- **Verify Camera Stack:** `sudo ./tools/verify.sh`
- **Install Fix Pack:** `sudo ./install.sh`
- **Clean Uninstall:** `sudo ./install.sh --uninstall --go`
