# OV05C10 libcamera Tuning Profiles

This directory contains Software ISP tuning profiles for the Omnivision OV05C10 sensor on Intel Lunar Lake (LNL) laptops behind the Synaptics SVP7500 CVS bridge (e.g. Dell Pro 14 PB14250).

## Files
- `ov05c10.yaml` — **Factory Dell OEM calibrated CCM profile (active default)**.
  - Extracted directly from Intel's factory binary container `OV05C10_BBG501N3_LNL.aiqb` shipped in Dell's Ubuntu 24.04 OEM recovery image.
  - Contains exact, mathematically normalized Color Correction Matrices across 5 calibrated illuminants:
    - `6503K` (Overcast / D65)
    - `5562K` (Daylight)
    - `4571K` (Cool White)
    - `3759K` (Warm White)
    - `2595K` (Incandescent / Tungsten)
  - Provides accurate skin tones, correct white balance across all light temperatures, and natural color reproduction without artificial tint.
- `ov05c10.yaml.manual` — **Manual warm profile (backup)**.
  - Scaled blue row by `0.75x` and added `+10%` to red row.
  - Preserved for comparison and fallback.
- `ov05c10.yaml.orig` — **Original cold/bluish profile (backup)**.
  - High blue diagonal multiplier (`1.75`) without AWB blue damping.
  - Preserved for reference or regression testing.

## Installation Path
These files are installed to `/usr/share/libcamera/ipa/simple/ov05c10.yaml`.
After modifying or switching profiles, restart WirePlumber:
```bash
systemctl --user restart wireplumber
```
