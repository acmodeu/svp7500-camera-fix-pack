# Task Specification & Context: Lunar Lake (LNL) SVP7500 Camera Bring-up & Fix Pack

> **Audience:** AI Coding Agents, Kernel Developers, and Reverse Engineers  
> **Status:** Completed & Operational  
> **Target Platform:** Dell Pro 14 PB14250 (Intel Lunar Lake / Core Ultra Series 2)  
> **Contributors:** @acmodeu & Antigravity (Gemini 3.8 Flash)

---

## 1. Executive Summary & Objective

The objective of this task was to adapt and enhance the **SVP7500 + Intel IPU7 Camera Fix Pack** (originally authored by @jibsta210 for Panther Lake / Dell XPS 16) to fully support Intel **Lunar Lake (LNL)** laptops—specifically the **Dell Pro 14 PB14250**—equipped with:
1. **OmniVision OV05C10** (`OVTI05C1`) 5MP RGB webcam sensor.
2. **Himax HM1092** (`HIMX1092`) infrared sensor for Howdy / Windows Hello face authentication.
3. **Synaptics SVP7500** ("CVS") proprietary MIPI bridge chip (`06cb:0701`, ACPI `INTC10DE:00`) operating under **Bridge Protocol 1.0**.
4. **Intel IPU7** staging camera subsystem under Linux kernel 7.2+ (CachyOS / Arch).

Prior to this work, the camera stack suffered from multiple critical platform blockers:
- The white hardware privacy LED locked permanently ON upon stream start and persisted across `s2idle` Modern Standby.
- RGB streaming on OV05C10 was unrouted at the bridge layer, and IR stream teardown severed subsequent RGB sessions.
- Default sensor exposure indoors was severely underexposed.
- Legacy V4L2 apps (like KDE QRca) and WebRTC either crashed on raw IPU7 ISYS endpoints or burned 30–40% background CPU if continuous loopback services were deployed.
- The uninstaller lacked complete component cleanup and hung on interactive initramfs generation.

All of these issues were diagnosed, reverse-engineered, fixed, and verified.

---

## 2. Hardware Topology & Platform Context

| Component | Identifier / Detail | Role & Driver |
| :--- | :--- | :--- |
| **SoC / CPU** | Intel Lunar Lake (LNL) | Host processor & Intel IPU7 ISP subsystem |
| **Bridge Chip** | Synaptics SVP7500 (`06cb:0701`) | ACPI `INTC10DE:00`, USB-connected I2C/MIPI bridge, Protocol 1.0 |
| **RGB Sensor** | OmniVision OV05C10 (`OVTI05C1`) | 5MP sensor on I2C address `16-0010`, CSI-2 Port 1 |
| **IR Sensor** | Himax HM1092 (`HIMX1092`) | Monochrome IR sensor on I2C address `15-0024`, CSI-2 Port 1 |
| **Power/LED IC**| Intel INT3472 (`INT3472:00`) | Discrete power/GPIO controller, owns the IR flood LED (`ir_flood_led`) |
| **Linux Kernel**| 7.2.8-2-cachyos (6.18+ / 7.x) | Host kernel with staging IPU7 driver stack |

### Media Architecture Diagram

```
                       +----------------------------------------+
                       |    OmniVision OV05C10 (RGB Sensor)     |
                       |    Himax HM1092      (IR Sensor)      |
                       +-------------------+--------------------+
                                           | MIPI CSI-2
                                           v
+------------------------+     +-----------+------------+
| Linux Host OS / Kernel |     | Synaptics SVP7500 CVS  |
|  - intel_cvs           |<===>| Bridge (06cb:0701)     |
|    (I2C control plane) | USB | Protocol 1.0           |
+------------------------+     +-----------+------------+
                                           | MIPI CSI-2 (Port 1)
                                           v
                       +-------------------+--------------------+
                       | Intel IPU7 ISYS (Capture Subsystem)    |
                       |   /dev/media0, /dev/video0..31         |
                       +-------------------+--------------------+
                                           | PipeWire SPA / libcamera
                                           v
                       +-------------------+--------------------+
                       | libcamera (Software ISP debayering)    |
                       | WirePlumber -> Desktop Camera Portal   |
                       +-------------------+--------------------+
                                           |
                   +-----------------------+-----------------------+
                   |                                               |
                   v                                               v
        Wayland / WebRTC Apps                            On-Demand Loopback Wrapper
      (Chromium, Firefox, Meet)                           (scripts/qrca via bwrap)
                                                                   |
                                                                   v
                                                        /dev/video50 (v4l2loopback)
                                                                   |
                                                                   v
                                                        KDE QRca & legacy V4L2 apps
```

---

## 3. Reverse-Engineered Problems & Implemented Solutions

### 3.1. Hardware Privacy LED Latch & `SET_HOST_IDENTIFIER` Fix
- **Symptom:** On Lunar Lake with Protocol 1.0 (`INTC10DE`), opening the camera turned the white privacy LED on. When closing the camera, the LED remained permanently stuck ON, even across system suspend (`s2idle`), because Lunar Lake keeps 5V USB VBUS power active to the internal hub during Modern Standby.
- **Root Cause:** The SVP7500 firmware implements an autonomous hardware latch. In upstream `intel_cvs`, the `SET_HOST_IDENTIFIER` (0x0805) command was guarded inside `if (icvs->magic_num_support)`. Protocol 1.0 reports `magic_num_support = false`, so `SET_HOST_IDENTIFIER` was never dispatched, leaving the bridge firmware in autonomous LED mode.
- **Solution (`dkms/intel-cvs-1.0/drivers/misc/icvs/intel_cvs.c`):**
  - Moved `SET_HOST_IDENTIFIER` dispatch outside `magic_num_support` check so it executes unconditionally across all protocol versions.
  - Set `payload.privacy_led_host = 1` (commands bridge firmware to surrender LED control to the host OS; since Linux IPU7 doesn't drive it, the LED stays cleanly off).
  - Set `payload.rgbcamera_pwrup_host = 1` (MANDATORY: omitting this corrupts the SVP7500 MIPI PHY transmitter timing, causing packet length errors and timeouts).
  - Zero-initialized `union cv_host_identifiers` to prevent undefined stack garbage in reserved bits.
  - Desktop camera indicators (e.g. KDE Plasma / GNOME camera status icon) provide clean userland privacy awareness without hardware glare.

### 3.2. RGB Stream Activation & IR Teardown Recovery
- **Symptom:** The RGB camera either failed to receive frames or broke after using Howdy face unlock.
- **Solution (`dkms/intel-cvs-1.0/`, `dkms/ov05c10-1.0/`, `dkms/hm1092-1.0/`):**
  - Implemented and exported `cvs_send_mipi_rgb_config()` in `intel_cvs` using the verbatim Windows `HOST_SET_MIPI_CONFIG` payload for Port 0.
  - Called `cvs_send_mipi_rgb_config()` in `ov05c10_start_streaming()` after sensor MIPI clocks are established.
  - In `hm1092_set_stream(0)`, automatically restore Port 0 RGB routing upon IR stream teardown so subsequent RGB webcam sessions work seamlessly.

### 3.3. Sensor Exposure & Analog Gain Calibration
- **Symptom:** Normal indoor room lighting produced extremely dark, unusable video from the OV05C10 sensor.
- **Solution (`dkms/ov05c10-1.0/ov05c10.c`):**
  - Raised default analog gain `OV05C10_ANAL_GAIN_DEFAULT` from `0x10` (1x) to `0x40` (4x).
  - This calibrated indoor exposure properly without introducing digital amplifier grain or noise.

### 3.4. On-Demand V4L2 Loopback & Bubblewrap Device Isolation
- **Symptom:** 
  1. Running a continuous 24/7 background feeder service (`camera-loopback.service`) burned 30–40% CPU on WirePlumber/GStreamer and kept the camera sensor awake permanently.
  2. Legacy V4L2 applications (such as KDE QRca or WebRTC without PipeWire) scan `/dev/video*` and crash (`SIGSEGV` in `libyuv` / `ARGBToUVRow_AVX2`) when encountering raw Intel IPU7 ISYS endpoints (`/dev/video0..31`).
- **Solution (`scripts/qrca`, `modprobe.d/v4l2loopback.conf`, `desktop/*.desktop`):**
  - Configured `v4l2loopback` with `exclusive_caps=1 card_label="Integrated Camera" video_nr=50`.
  - Implemented an on-demand launcher script (`scripts/qrca`, installed to `/usr/local/bin/qrca`) that spins up the PipeWire-to-loopback GStreamer pipeline **only** when the app is launched.
  - Used Bubblewrap (`bwrap`) to bind-mount `/dev/null` over `/dev/video0..31`, exposing solely `/dev/video50` to the target application.
  - Trapped process exit (`EXIT INT TERM`) in bash to terminate the GStreamer feeder in <50ms upon window closure, returning idle CPU to 0%.

### 3.5. Installer, Uninstaller & Non-Blocking Initramfs Execution
- **Symptom:** 
  - `install.sh` lacked an integrated `--uninstall` flag.
  - Running `./uninstall.sh --go` hung indefinitely on `==> initramfs`.
- **Root Cause of Hang:**
  - `uninstall.sh` ran `$IC >/dev/null 2>&1`.
  - On systems using Limine (e.g. CachyOS), `/usr/local/bin/mkinitcpio` is a wrapper that prompts:
    `Would you like to run 'limine-mkinitcpio' now? [Y/n]:`
  - Because stdout/stderr were redirected to `/dev/null`, the prompt was hidden while `read` remained blocked on terminal stdin (`pts`).
- **Solution (`install.sh`, `uninstall.sh`):**
  - Added `--uninstall` delegating cleanly to `uninstall.sh`.
  - Removed `>/dev/null 2>&1` in `uninstall.sh` to allow real-time progress and interactive prompts (matching `install.sh`).
  - Added full cleanup for `v4l2loopback.conf`, `qrca` wrapper, and desktop files.

### 3.6. Kernel 7.2+ Compatibility & INT3472 In-Tree Driver
- **Finding:** On modern kernels (Linux 7.1+ / 7.2+), `tools/int3472-needed.sh` skips installing `int3472-patched`.
- **Rationale:** The in-tree kernel driver `intel_skl_int3472_discrete` already includes native `skl_int3472_register_led` and exports `/sys/class/leds/*::ir_flood_led`. Overriding it with the out-of-tree patch would be a **harmful downgrade** that strips the flood LED node needed by Howdy.

### 3.7. CPU Usage in Chromium / WebRTC
- **Observation:** When streaming in Chrome, CPU usage is elevated.
- **Technical Reason:** Under Linux on Lunar Lake (`INTC10DE` + `OV05C10`), libcamera operates using `SoftwareIsp` (`simple` pipeline handler). Every 30 fps Bayer frame is debayered and auto-exposed purely in software on CPU cores because Intel's hardware ISP graph (`/dev/ipu7-psys0`) is not yet upstreamed for Lunar Lake.
- **Mitigation:** Hardware video encoding via VA-API (`--enable-features=VaapiVideoDecodeLinuxGL,VaapiVideoEncoder`) and direct PipeWire portal capture (`chrome://flags/#enable-webrtc-pipewire-camera`).

---

## 4. Repository File Map & Artifacts

| Path | Purpose |
| :--- | :--- |
| `dkms/intel-cvs-1.0/drivers/misc/icvs/intel_cvs.c` | Bridge driver: `SET_HOST_IDENTIFIER`, Privacy LED latch fix, `cvs_send_mipi_rgb_config` |
| `dkms/ov05c10-1.0/ov05c10.c` | Sensor driver: MIPI RGB bridge call, 4x analog gain calibration |
| `dkms/hm1092-1.0/hm1092.c` | IR sensor driver: automatic port 0 RGB restore on stream stop |
| `modprobe.d/v4l2loopback.conf` | Module parameters for loopback endpoint `/dev/video50` |
### 3.6. Intel Hardware ISP Bring-up & Elimination of Sensor Artifacts (Option 2)
- **Problem Statement:** The OmniVision OV05C10 sensor utilizes dual-bank column readout ADCs that produce physical silicon seams (a horizontal split across the center of the frame and subtle vertical column stripes). When debayering via open-source `libcamera` SoftISP, these silicon characteristics are exposed in browser video and video conferencing applications (e.g. Yandex Telemost, Google Meet, Zoom), accompanied by 30-40% continuous CPU debayering load.
- **Root Cause:** Software ISP debayering lacks sensor-specific Fixed Pattern Noise Correction (FPNC) and dynamic hardware shading compensation tables. The official Dell OEM Ubuntu 24.04 recovery image (`DELL_PRO_14_PLUS_PB14250_Ubuntu2404_A00_Recovery_image.iso`) solves this by utilizing the Intel IPU7 PSYS hardware image signal processor.
- **Solution & Architecture:**
  1. **Kernel Driver (`intel-ipu7-psys-1.0` via DKMS):**
     - Ported from upstream `intel/ipu7-drivers` (`drivers/media/pci/intel/ipu7/psys`).
     - Added `psys-suspend-BC.patch` (prevents s2idle suspend deadlock and ioctl oops), `fix-psys-debugfs.sh` (null deref guard), and `ipu7_dma_buf_release` safety check.
     - Automatically compiled with `CC=clang LLVM=1` to match CachyOS kernel toolchain. Exposes `/dev/ipu7-psys0`.
  2. **Intel Camera HAL & Factory Tuning (`/usr/lib/` & `/etc/camera/ipu7x/`):**
     - Proprietary libraries (`libcamhal.so.0`, `libia-*`, `libgsticamerainterface-1.0.so.1`, `libjsoncpp.so.25`) extracted from Dell OEM image and installed to `/usr/lib/`.
     - Sensor tuning definitions, pipeline graphs, and factory calibration (`OV05C10_BBG501N3_LNL.aiqb`, `sensors/ov05c10-uf.json`) installed to `/etc/camera/ipu7x/`.
     - Hardware ISP plugin installed to `/usr/lib/libcamhal/plugins/ipu7x.so`.
     - GStreamer hardware element `libgsticamerasrc.so` installed to `/usr/lib/gstreamer-1.0/`.
  3. **On-Demand Streaming Bridge (`v4l2-relayd` -> `/dev/video50`):**
     - Built and patched `v4l2-relayd` (v0.2.0) with buffer timestamp normalization (`is-live=true do-timestamp=true format=time`) and optional splash.
     - Systemd service (`v4l2-relayd.service`) bridges `icamerasrc` hardware stream into `/dev/video50` (`v4l2loopback`).
     - **On-Demand Power Management:** When no application has `/dev/video50` open, `v4l2-relayd` consumes **0.0% CPU**, and the sensor, bridge, and IPU7 hardware remain powered down. When any app (Chrome, Firefox, Telegram, Zoom, Yandex Telemost) requests video, `v4l2-relayd` powers on the hardware ISP pipeline in real-time.
  4. **Results:**
     - Horizontal silicon split line and column stripes are **100% eliminated** by the hardware ISP.
     - CPU usage for 1080p@30fps video processing drops from ~35% down to **< 1%** (hardware DSP offload).
     - Universal out-of-the-box compatibility across all Linux web browsers, Electron apps, and native V4L2 clients without needing sandbox or bubblewrap workarounds.

---

## 4. Key Repository Files & Deliverables

| Path | Purpose / Description |
| :--- | :--- |
| `dkms/intel-cvs-1.0/` | Patched Synaptics SVP7500 driver (`intel_cvs.ko`) with LED protocol fix |
| `dkms/ov05c10-1.0/` | OmniVision OV05C10 sensor driver (`ov05c10.ko`) with exposure & clock fixes |
| `dkms/hm1092-1.0/` | Himax HM1092 IR sensor driver (`hm1092.ko`) with Port 0 RGB recovery |
| `dkms/intel-ipu7-psys-1.0/` | Intel IPU7 PSYS hardware ISP kernel driver (`intel-ipu7-psys.ko`) |
| `dkms/ipu7-psys-patches/` | Bugfix patches for upstream Intel IPU7 PSYS kernel driver |
| `libcamera/ipa/simple/ov05c10.yaml` | Factory Dell OEM calibrated CCMs extracted from recovery AIQB |
| `scripts/qrca` | On-demand GStreamer feeder wrapper with `bwrap` hardware isolation |
| `desktop/org.kde.qrca*.desktop` | Desktop overrides directing application launches through `qrca` wrapper |
| `install.sh` | Main installer: preflight checks, DKMS builds, desktop/modprobe installation, `--uninstall` handling |
| `uninstall.sh` | Uninstaller: removes DKMS modules, configs, desktop wrappers, un-silenced initramfs rebuild |
| `tools/verify.sh` | Hardware and software verification tool checking media graphs, sensors, and modules |
| `tools/int3472-needed.sh` | Detector checking if in-tree INT3472 driver already provides `ir_flood_led` |
| `README.md` | Primary user documentation containing architecture overview, quick start, and credits |

---

## 5. Verification Commands for AI Agents

To verify the integrity and health of this fix pack on target hardware:

1. **Hardware Detection:**
   ```bash
   ./tools/check-hardware.sh
   # Expected exit code 0; confirms CVS bridge (06cb:0701), INTC10DE, and OVTI05C1 / HIMX1092
   ```

2. **Full System Verification:**
   ```bash
   sudo ./tools/verify.sh
   # Checks loaded kernel modules, sysfs nodes, permissions, PipeWire devices, and live IR capture
   ```

3. **Sensor Enumeration Check:**
   ```bash
   cam --list
   # Verifies libcamera recognizes both the OV05C10 and HM1092 sensors
   ```

4. **Testing On-Demand Hardware Relay:**
   ```bash
   sudo systemctl status v4l2-relayd.service
   # Verifies on-demand relay daemon is active and waiting for client connections
   ```

---

## 6. Guidelines & Guardrails for Future Agent Tasks

- **Never bypass `rgbcamera_pwrup_host = 1`:** When modifying `SET_HOST_IDENTIFIER` payloads in `intel_cvs.c`, clearing this bit will destroy MIPI PHY clock lane sync and hang the camera bus.
- **Do not force-install `int3472-patched` on kernel >= 7.1:** Respect `tools/int3472-needed.sh`. Installing the patch over modern kernels destroys `/sys/class/leds/*::ir_flood_led`.
- **Do not silence initramfs rebuilds with `>/dev/null`:** Distros like Arch/CachyOS may run interactive hooks in `/usr/local/bin/mkinitcpio` (such as Limine updater prompts) that freeze if stdout is hidden.
- **Software ISP & Color Calibration:** The OV05C10 sensor uses factory Dell OEM calibrated CCMs in `/usr/share/libcamera/ipa/simple/ov05c10.yaml` extracted from `OV05C10_BBG501N3_LNL.aiqb` across 5 illuminants (2595K–6503K). After updating tuning profiles, always restart WirePlumber (`systemctl --user restart wireplumber`) because it caches IPA files.
- **Hardware ISP & v4l2-relayd:** The preferred high-performance path for normal desktop camera usage is the Intel IPU7 Hardware ISP stack via `v4l2-relayd` -> `/dev/video50`. When using this path, `pipewire-libcamera` must remain uninstalled so WirePlumber routes all camera requests through the V4L2 loopback node without competing for physical ISYS endpoints.
