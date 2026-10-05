# Howdy integration

The HM1092 is a **monochrome** sensor that the driver tags `SGRBG10` (Bayer
GRBG), because that is what the Windows driver and the IPU graph settings
declare. Anything that honours the tag -- OpenCV, libcamera's SoftwareIsp, and
therefore PipeWire -- debayers mono data and produces mush. The Intel IPU7 ISYS
capture node offers no monochrome pixel format at all (only Bayer, YUV and RGB),
so there is no way to fix this by selecting a different format: the consumer has
to know that the payload is really 10-bit greyscale.

`ir_reader.py` is that consumer. It reads the V4L2 node directly, shifts the
10-bit values down to 8-bit grey, and keeps the sensor's native 648x368.

## Which patch to use

| File | Applies to | Use it |
|---|---|---|
| `ir-recorder-video_capture.patch` | Howdy 3.0.0 / `d3ab993` / git | **yes** (for Howdy 3.x) |
| `ir-recorder-video_capture-2.6.patch` | Howdy 2.6.x (stable release tag) | **yes** (for Howdy 2.6.x) |
| `ir-recorder-meson.patch` | stock upstream Howdy | when building from source |
| `video_capture.patch` | legacy local branch with pipewire | no -- kept for reference only |
| `pam_auth.sh` | PAM helper script (Python 3) | **yes** (for modern Linux PAM) |

`install.sh` automatically tests and applies the correct patch for your installed Howdy version and auto-detects `device_path` using `tools/lib-detect.sh`.

## PAM Configuration (Sudo, Lock Screen, Login)

Modern distributions (such as Arch / CachyOS) have removed Python 2, so the legacy `pam_python.so` is not available. This repository includes `pam_auth.sh`, a universal Python 3 PAM wrapper that works with `pam_exec.so`.

Add the following line to the top of the desired PAM service in `/etc/pam.d/`:

```text
auth       sufficient   pam_exec.so quiet /usr/lib/security/howdy/pam_auth.sh
```

### Recommended Services:
- **Sudo (`/etc/pam.d/sudo`)**: enables face authentication in terminal commands.
- **KDE Lock Screen (`/etc/pam.d/kde`)**: unlocks KDE Plasma upon wake/keypress in ~0.5s.
- **Plasma Login / SDDM (`/etc/pam.d/plasmalogin` or `/etc/pam.d/sddm`)**: logs in upon booting the laptop.

> [!TIP]
> **KDE Wallet (KWallet) with Face Login**: When logging in via facial recognition instead of typing your user password, KWallet cannot automatically decrypt stored secrets (like saved Wi-Fi or Chrome passwords). To avoid a secondary KWallet prompt upon desktop load, either set your KWallet password to blank in **KWalletManager** (*Change Password -> leave blank*), or disable the KWallet subsystem in **System Settings -> KDE Wallet**.

## Note on the illuminator

Since the `devm_led_get` change to `hm1092` (tag `nixos-pin-2026-08-27`), the
sensor driver drives the IR flood illuminator itself around streaming. The
reader still sets it, which is now a harmless double-write, and it remains
necessary on any kernel without that change.
