# SVP7500 + Intel IPU7 Camera Fix Pack

**What this is:** a set of DKMS kernel modules that make the built-in camera work
on Linux laptops where the webcam is a MIPI sensor behind a **Synaptics SVP7500
"CVS" bridge** (USB `06CB:0701`) wired to an **Intel IPU7** imaging unit —
recent Dell XPS / Dell Pro / Latitude and similar Meteor/Arrow/Lunar/Panther
Lake machines. **Who needs it:** anyone on those machines whose camera produces
no device at all, or a device that never delivers a frame, on a stock kernel.
**Who does not:** if your webcam is an ordinary USB UVC device — the vast
majority of laptops, including most non-Dell machines — nothing here applies and
you should not install it.

**Is it for your laptop? One command, 5 seconds, changes nothing:**

```bash
git clone https://github.com/jibsta210/svp7500-camera-fix-pack
cd svp7500-camera-fix-pack
./tools/check-hardware.sh
```

It ends with a verdict line — `APPLIES TO THIS MACHINE: yes — ...` or
`APPLIES TO THIS MACHINE: no — ...` with the reason — followed by what to do
next. If it says no, stop: nothing here will help you, and `install.sh` will
refuse to run anyway.

> ### Testing scope — please read
>
> **The author owns and verifies exactly one machine:** a Dell XPS 16 (DA16260,
> Panther Lake) on CachyOS, across kernels **7.0.5 through 7.2.0-rc4** including
> **stock `linux-cachyos` 7.1.4** — so a custom kernel is *not* required. On that
> one machine the full stack is verified end to end: RGB camera, IR camera
> streaming, and Howdy face unlock.
>
> **Everything else is third-party reports**, not something the author can
> reproduce or debug directly:
>
> | reporter | machine | distro | reported |
> |---|---|---|---|
> | @acmodeu | Dell Pro 14 PB14250 (CSI-2 port 1) | Arch / CachyOS | install OK; surfaced the port-1 difference |
> | @Aohzan | Dell Pro 14 (`INTC10DE` bridge) | Arch | surfaced the differing bridge ACPI id |
> | @dalandro | Dell Pro 14 Plus PB14250 | Ubuntu | RGB path, OV05C10 sensor |
> | @tverhaeghe | Dell XPS 16 DA16260 | Fedora 44 Silverblue | RGB working ([vision-drivers#37](https://github.com/intel/vision-drivers/issues/37)) |
>
> **IR streaming and Howdy face unlock have not been independently confirmed on
> hardware other than the author's.** The RGB path has. If you get IR working
> (or not) on a different machine, a report is genuinely valuable.
>
> The DKMS modules are plain C against the kernel API with no distro
> assumptions, so Fedora, Debian and stock Arch should work — untested by the
> author. On **Fedora Silverblue** you will likely need
> `rpm-ostree install dkms kernel-devel` and a reboot first; layering DKMS on an
> immutable OS is known-awkward.

---

## Step 0 — check your hardware FIRST (5 seconds)

```bash
./tools/check-hardware.sh
```

Read-only: it needs no root, installs nothing and changes nothing. It prints
what it found and ends with a verdict:

```
  CVS bridge on USB            06cb:0701
  bridge ACPI id               INTC10E1
  sensors in firmware          HIMX1092 INT3472 OVTI08F4
  Intel imaging unit           0000:00:05.0 0xb05d
  IPU6 machine                 no
  USB (uvcvideo) webcam        none bound

APPLIES TO THIS MACHINE: yes — found a CVS bridge or its ACPI id, plus a
sensor the firmware declares
```

Exit status: `0` this package applies, `1` it does not, `2` it must not be
installed (IPU6 machine). `install.sh` runs this same check and refuses to
continue when the answer is no, so you cannot install this on the wrong laptop
by accident.

### Reading the result

**This package is for you** if you see a CVS bridge *or* an `INTC10xx` ACPI id,
plus a sensor. The bridge id tells you your platform:

| ACPI id | platform |
|---|---|
| `INTC10CF` | Meteor Lake |
| `INTC10DE` | Lunar Lake |
| `INTC10E0` | Arrow Lake |
| `INTC10E1` | Panther Lake |

Sensors you may see: `OVTI08F4` (OV08x40, RGB), `OVTI05C1` (OV05C10, RGB),
`HIMX1092` (HM1092, IR). `INT3472` is the power/GPIO controller that owns the IR
illuminator. Many boards have **no IR sensor at all** — that is a supported,
complete configuration, not a missing piece.

**MIPI/IPU sensor vs UVC webcam** — this is the distinction that matters most:

| what you have | how you can tell | what you need |
|---|---|---|
| **MIPI CSI-2 sensor on an Intel IPU** | sensor appears in the media graph (`media-ctl -p`), bridge is USB **class 255 vendor-specific**, no UVC interface, `uvcvideo` binds nothing | **this repo** |
| **USB UVC webcam** | `lsusb -v` shows `bInterfaceClass 14 Video`, `uvcvideo` is bound, `/dev/video0` exists and works in any app | **not this repo.** For a UVC IR emitter use [linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter) |

On IPU platforms the sensor is not a USB webcam at all: it reaches the host over
MIPI CSI-2 through the IPU, and the Synaptics bridge exposes only a
vendor-specific bulk interface carrying an I2C tunnel. There is no UVC device to
send a control to, so UVC-based tools cannot possibly help — and conversely
nothing here applies to a UVC webcam.

### Machines this does NOT help

Stop here and do not install if any of these describe you:

- **`uvcvideo` is bound to your camera** — you have an ordinary USB webcam. If it
  is broken, this is not the cause.
- **No `06cb:0701` and no `INTC10xx`** — you do not have a CVS bridge. Some
  laptops have IPU cameras with a *different* bridge; this pack does not cover them.
- **IPU6 machines** (Tiger/Alder/Raptor Lake, `intel-ipu6` driver) — related
  stack, different target. See [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers).
- **AMD, Qualcomm/Snapdragon or Apple silicon laptops** — no Intel IPU.
- **Your camera already works.** This pack replaces core camera modules; there is
  no upside and a real downside.

---

## Step 1 — prerequisites

```bash
# Arch / CachyOS
sudo pacman -S dkms linux-headers v4l-utils libcamera pipewire-libcamera

# Fedora
sudo dnf install dkms kernel-devel v4l-utils libcamera pipewire-plugin-libcamera

# Debian / Ubuntu
sudo apt install dkms "linux-headers-$(uname -r)" v4l-utils libcamera-tools pipewire-libcamera
```

**`pipewire-libcamera` is not optional here, whatever your package manager
calls it.** PipeWire reaches libcamera through a separate SPA plugin
(`libspa-libcamera.so`) that ships in its own package, is an *optional*
dependency of `pipewire`, and that nothing else pulls in. Without it
WirePlumber's libcamera monitor runs and creates no devices, so `wpctl status`
shows an empty Video section and every browser and video-call app reports no
camera — while `cam --list` and `cam --capture` work perfectly, because they use
libcamera directly and never touch the plugin.

That split is worth remembering: the CLI test that looks authoritative is the
one that cannot see this failure. `verify.sh` checks for the plugin explicitly.

Optional but recommended on Btrfs: `sudo snapper create -d "pre-svp7500-fix"`.

## Step 2 — install

Rehearse first. `--dry-run` runs every check and prints every action it would
take, and changes nothing at all:

```bash
sudo ./install.sh --dry-run     # rehearsal — changes nothing
sudo ./install.sh               # add --kernel-only if you do not use Howdy
```

If the dry run ends in `Dry run found problems`, the real run would hit the same
ones. Fix them first; you have not touched anything yet.

`sudo ./install.sh --help` lists every flag. The ones worth knowing before you
start:

| flag | what it does |
|---|---|
| `--dry-run` | run every check, print every action, change nothing |
| `--kernel-only` | modules, psys patches, udev rules, initramfs — no Howdy |
| `--howdy-only` | Howdy integration only — no DKMS work, no reboot needed |
| `--no-initramfs` | you will rebuild the initramfs yourself. See the exit table below |
| `--mok-enrolled` | you sign modules yourself; do not fail on unsigned ones. See [Secure Boot](#secure-boot) |
| `--force` | continue past the two preflight refusals that are about your *machine* rather than the package: hardware that does not look like a supported board, and a running kernel with no build tree |

**`--force` is the one flag that can leave you worse off**, and it is the only
place where exit `0` does not also mean *this was a good idea*. On an IPU6 or
otherwise unrelated Intel MIPI laptop, two of these modules (`ipu-bridge-patched`,
`int3472-patched`) replace **in-tree** drivers and land in `updates/`, which
`depmod` prefers — so a forced install overrides working drivers system-wide.
The installer says so, loudly, and records the way back in its
`still needs your attention` list. Without `--force` it simply refuses, which is
what you want.

**You do not have to read the output to know whether it worked.** The exit
status is the contract:

| exit | meaning |
|---|---|
| `0` | everything selected actually happened |
| `1` | the install did not achieve what it set out to — the last screen names what did not happen |
| `2` | preflight refused, nothing was touched |

So `sudo ./install.sh && sudo reboot` is safe: a failed install will not let you
reboot into an unchanged system believing it worked.

**Three things can make exit `0` mean slightly less than that, and all three are
opt-in or self-announcing.** They are listed here because "exit 0 means
everything happened" has to survive being read literally:

| when | what exit `0` means then |
|---|---|
| `--no-initramfs` | everything **except** the initramfs, which you said you would rebuild yourself. The run's last screen is a `BEFORE YOU REBOOT` block naming the exact command you still owe |
| `--mok-enrolled` | everything except *proving* the modules will load. You told the installer you sign them yourself, so it took your word for it and did not check. If you then do not sign them, the kernel refuses every one at boot |
| `--force` | everything happened, but on a machine that failed the hardware check. This is the one place where exit `0` does not also mean *this was a good idea* — see below |

A phase with nothing to do is not an exception to the contract, and the run says
so plainly in `steps skipped`: if Howdy is not installed the Howdy phase is
skipped (there is no `video_capture.py` to hook into), and if you have no
`ipu7-drivers` DKMS tree the psys patches are skipped (there is no source to
patch). Neither is a step that failed; both are named on the last screen, with
the command to finish the job later.

"Actually happened" includes *will actually load*. If your kernel refuses
unsigned modules — Secure Boot with signature enforcement, which is the factory
setting on Dell laptops — and the modules it just built are unsigned, that is a
failure and it exits `1`, because every one of them would be rejected at boot
and nothing would be in effect. See [Secure Boot](#secure-boot) below.

**What to expect.** The installer builds every module against *every* installed
kernel, so you get one `✓` line per module per kernel, and each one is verified
against the `.ko` that actually landed on disk — not against DKMS's exit code:

On a machine with two installed kernels that is five modules x two kernels, ten
lines:

```
==> Installing DKMS modules
    ✓ <module> -> <kernel>  (verified: <ko names>)
    ✓ <module> -> <other kernel>  (verified: <ko names>)
    ...
```

The lines below are quoted exactly as the installer prints them — the package
selftest fails if any of this wording drifts from install.sh:

| line | meaning |
|---|---|
| `✓ <module> -> <kernel>  (verified: <ko names>)` | built, installed, and the module file was found on disk for that kernel |
| `✗ <module>: build FAILED for <kernel>` | build error — missing headers for *that* kernel is the usual cause. The run will exit non-zero |
| `! <module>: installed for <n> kernel(s), FAILED for: <kernels>` | partial. Booting the failed kernels leaves the camera broken, so this also exits non-zero |
| `✗ package is missing module '<name>' (no dkms/<name>-*/dkms.conf, no kernel/<name>/dkms.conf) — this clone/tarball is incomplete, re-download it` | **packaging bug — please report it.** This aborts in preflight with exit 2; nothing was touched |
| `✗ NOTHING WAS INSTALLED. Do not reboot expecting a change — nothing would be different.` | the run achieved nothing and says so. Exit 1 |
| `✗ the modules will not load on the next boot — this install is on disk but NOT in effect. Do not reboot expecting a working camera.` | Secure Boot / signature enforcement. See below. Exit 1 |
| `! <module> -> <kernel>: NOT installed — <kernel>'s in-tree intel_skl_int3472_discrete already registers the IR flood LED, and ours does not.` | **expected on kernels ≥ 7.1.** Your kernel is newer than this patch. See [int3472](#2-int3472-patched-dkms) below. Exit status unaffected |
| `✗ int3472-patched from an earlier run is still shadowing the in-tree driver on <n> kernel(s) — those kernels have no /sys/class/leds/*::ir_flood_led, so Howdy cannot light the illuminator there.` | an older run of this installer broke the illuminator on that kernel. The line above it gives the one `dkms remove` that fixes it. Exit 1 |

The psys section may legitimately say `! no ipu7-drivers package under DKMS ('dkms status' lists none, and /var/lib/dkms has none) — psys patches do not apply to this system`.
That is **fine and expected** if you do not have Intel's `ipu7-drivers` DKMS
package (many distros ship IPU7 in-kernel), and it does not affect the exit
status. By contrast `✗ psys-suspend-BC.patch is not in this package (looked in dkms/ and kernel/ipu7-psys-patches/) — packaging bug, nothing to do with your DKMS install`
is a bug on our side — report that one.

If you *do* have that DKMS package, check which revision before you blame this
pack for a camera that stops working: **`ipu7-drivers` r76 and later break psys
on any distro that ships the staging `intel_ipu7` with the kernel**
([intel/ipu7-drivers#93](https://github.com/intel/ipu7-drivers/issues/93)), and
the install can succeed on all counts while `/dev/ipu7-psys0` never appears.
`tools/install-ipu7-r74.sh --check` says which revision you are on and changes
nothing; see [r76+](#the-rgb-camera-died-after-a-package-update--ipu7-drivers-r76)
for the one-command recovery.

### Secure Boot

Dell ships these laptops with Secure Boot **on**, so read this before you
conclude the pack does not work on your machine.

Secure Boot on its own is not the problem, and the installer does not treat it
as one — plenty of kernels boot with it enabled and load unsigned modules
anyway. What matters is whether your kernel *enforces module signatures*
(`sig_enforce=Y`, or kernel lockdown in `[integrity]`/`[confidentiality]` mode).
Arch and CachyOS stock kernels do not; Ubuntu and Fedora do.

After the modules are built, the installer reads the signature off the `.ko`
files that actually landed and checks the signer against your enrolled keys.
Four outcomes, all printed under `==> Will this kernel load what was just
installed?` and summarised on the `module signing` line:

| what it prints | exit |
|---|---|
| `✓ this kernel does not enforce module signatures — nothing installed above needs to be signed` | `0` |
| `✓ Secure Boot is ENABLED, but this kernel does not enforce module signatures` … | `0` |
| `✗ the modules installed above are UNSIGNED and this kernel refuses unsigned modules` … | **`1`** |
| `!` signed, but the signing key was not found in `mokutil --list-enrolled` or `/proc/keys` | `0`, with a warning — a signature we cannot trace is not proof of anything |

The failing case is the one that used to exit `0`: every module builds, every
`.ko` lands, the installer proves all of it on disk, and then the kernel refuses
all five at boot with `Key was rejected by service`. You get three ways out:

1. **Sign them.** Configure DKMS module signing (`sign_tool` or
   `mok_signing_key` in `/etc/dkms/framework.conf`), re-run the installer, then
   `sudo mokutil --import <cert>` and enrol at the next boot.
2. **Turn Secure Boot off** in firmware.
3. **`sudo ./install.sh --mok-enrolled`** — if you sign modules yourself after
   the build (a DKMS signing hook that runs later, `sbctl`, a manual
   `kmodsign` pass). This downgrades the failure to a warning and takes your
   word for it. It does not sign anything.

`--dry-run` answers the same question in advance: with an enforcing kernel and
no DKMS signing configured, the rehearsal exits `1` rather than letting you find
out after the reboot.

## Step 3 — reboot, but only if step 2 succeeded

```bash
sudo reboot
```

**Do not reboot after a failed install.** Nothing will have changed, and the
reboot will look like the fix not working when in fact it was never applied.
The installer's last screen tells you which it was, and so does `echo $?`.

**A reboot is required, not optional** after a successful one. `hm1092` leaks
module references and can never be swapped live: unbind succeeds, the refcount
stays above zero, and `rmmod` reports the module in use.

---

## Verification

```bash
sudo ./tools/verify.sh
```

Run it as **root**. Without root the live capture test cannot run, and the
script says `UNDETERMINED` rather than passing you on a check it never made.

**You do not have to interpret the output.** The last line is a single verdict
and the exit status matches it:

| last line | exit | meaning |
|---|---|---|
| `RESULT: OK — ...` | `0` | the camera stack is healthy **for the sensors this board has** |
| `RESULT: BROKEN` | `1` | something is proven wrong. The lines under it name each one |
| `RESULT: UNDETERMINED — ...` | `2` | nothing is proven broken, but some checks could not run (usually: not root, or `v4l-utils` / `libcamera-tools` not installed). This is **not** a pass |

It only checks the sensors your board actually has. If you have no IR sensor —
most RGB-only boards, including the OV05C10 machines — the IR section reads
`n/a (no IR sensor on this board)` and the verdict is still `OK`. Nothing is
missing; that half of the package simply does not apply to you.

### What a HEALTHY RGB-only machine prints

```
-- IR camera / face unlock --
  IR path                          n/a (no IR sensor on this board)

-- live IR capture --
  capture test                     n/a (no IR sensor on this board)

RESULT: OK — RGB camera working, no IR sensor on this board
```

### What a HEALTHY machine with IR prints

```
=== IPU7 camera stack verification ===
  kernel                           7.2.0-rc4-1-cachyos
  fix-pack                         v0.9-12-g663f91b

-- core stack --
  module intel_ipu7                loaded (kernel)
  module intel_ipu7_psys           loaded (dkms)
  /dev/ipu7-psys0                  present
  loaded modules match disk        yes (7 checked)

-- RGB camera --
  module ov08x40                   loaded (kernel)
  libcamera (cam --list)           2 camera(s)

-- IR camera / face unlock --
  module hm1092                    loaded (dkms)
  link_frequency                   180480000 (correct)
  IR flood LED                     present (brightness=0) — 0 is correct while idle

-- live IR capture --
  CSI-2 port                       2 (followed from hm1092 16-0024's own link)
  SOF on csi2-2                    9 <-- STREAMING

RESULT: OK — RGB camera working, IR camera streaming
```

The CSI-2 port, the capture node and the sensor names are read out of the media
graph on your machine — port **1** on a Dell Pro 14, port **2** on an XPS 16, and
the tool follows the link rather than assuming. If it cannot resolve them it
prints `not tested` and refuses to run the capture, because a guessed port
produces a confident `NO FRAMES` on a camera that is working.

### What a BROKEN machine prints

```
  /dev/ipu7-psys0                  MISSING — the RGB camera cannot work without it
      intel_ipu7:      /lib/modules/<ver>/kernel/.../intel-ipu7.ko.zst  [kernel]
      intel_ipu7_psys: /lib/modules/<ver>/updates/dkms/intel-ipu7-psys.ko.zst  [dkms]
      -> SPLIT PROVENANCE: intel_ipu7 comes from your kernel package and
         intel_ipu7_psys from DKMS. ...
         Fix: sudo /home/you/svp7500-camera-fix-pack/dkms/ipu7-psys-patches/fix-psys-defer.sh
      kernel says:
           intel_ipu7_psys: probe deferred
      aux device: ABSENT (intel_ipu7 never created it)

RESULT: BROKEN
  * /dev/ipu7-psys0 does not exist — intel_ipu7_psys never bound
```

The diagnosis is derived, not assumed: if both modules come from the same place
this is *not* split provenance and it says so, and it will not offer you
`fix-psys-defer.sh` unless `dkms status` actually lists an `ipu7-drivers` tree
for it to patch.

Three failure modes worth naming, because all three cost real debugging hours:

1. **The psys bus is never registered — kernel 7.1 and newer.** `ipu-psys.c`
   puts its char device on a custom `intel-ipu7-psys` bus but registers itself
   with `module_auxiliary_driver()`, which registers only the auxiliary driver;
   `bus_register()` is called nowhere in the tree. Kernels up to about 7.0
   tolerated a device on an unregistered bus. 7.1 rejects it, so probe runs
   correctly all the way to its last step and fails:

   ```
   bus_add_device: cannot add device 'ipu7-psys0' to unregistered bus 'intel-ipu7-psys'
   intel-ipu7-psys ipu7-psys0: psys device_register failed
   probe with driver intel_ipu7_psys.psys failed with error -22
   ```

   Fix: `sudo ./dkms/ipu7-psys-patches/fix-psys-busreg.sh`, rebuild for every
   kernel, reboot. `install.sh` applies it for you. This is the most common
   cause of a missing `psys0` on a current kernel, and it is easy to misread as
   a libcamera or PipeWire fault because `cam -l` and `cam -c` keep working —
   only applications go blind, because PipeWire's libcamera monitor needs the
   device node.
2. **Split provenance.** `intel_ipu7` from the kernel + `intel_ipu7_psys` from
   DKMS means the two disagree about `struct ipu7_device`'s layout, so the
   readiness check reads the wrong offset and psys defers forever. `isys` binds
   normally because it ships with the kernel, which makes the failure look
   selective and sends people hunting the wrong component.
3. **Stale modules.** *A DKMS rebuild does not regenerate the initramfs.* If a
   module ships in the initramfs, the kernel keeps loading the **old** build no
   matter how many times you rebuild — and every downstream symptom points
   somewhere else. Fix with `sudo mkinitcpio -P` (Arch/CachyOS),
   `sudo dracut -f` (Fedora), or `sudo update-initramfs -u` (Debian/Ubuntu),
   then reboot.

For the RGB camera specifically:

```bash
cam --list                                         # expect 1 camera
cam --camera=1 --capture=5 --file=/tmp/test.raw    # expect 5 frames
```

For the IR node and CSI-2 port:

```bash
./tools/find-ir-node.sh
```

Everything it prints is followed from the sensor's own link in the media graph.
If it cannot follow that link it prints `UNDETECTED — not guessing` and exits
non-zero, rather than handing you a number that is right on somebody else's
laptop.

---

## Panther Lake vs Lunar Lake

Two IPU7 generations ship in these laptops and they behave differently. The
bridge's ACPI HID tells you which you have, and `verify.sh` prints it:

```
bridge ACPI id      INTC10E1     Panther Lake
bridge ACPI id      INTC10DE     Lunar Lake
```

Everything in this package works on both. The one thing that does not is the
**IPU7 libcamera pipeline handler** in
[ipu7-camera-linux](https://github.com/jibsta210/ipu7-camera-linux), which
gives you the hardware ISP and is the only known fix for browsers crashing at
scaled resolutions.

Its psys graph -- node resource ids, terminal ids, terminal buffer sizes and
links -- was traced off the Intel Camera HAL on Panther Lake and is submitted
verbatim; there is no platform-conditional code in it at all. Lunar Lake runs
different psys firmware with different program groups and rejects it:

```
intel-ipu7-psys ipu7-psys0: group 3, code 38, detail: 3, 0
intel-ipu7-psys ipu7-psys0: ipu7_psys_handle_graph_open_ack, num_items is 0
intel-ipu7-psys ipu7-psys0: Failed to set graph
ERROR IPU7 psys.cpp:162 GRAPH_OPEN failed: Invalid argument
```

**On Lunar Lake, do not build it expecting a fix.** Making it work there needs
a graph captured from LNL hardware, which nobody has done. Your camera still
works from the CLI at native resolution; only the scaled sizes browsers ask
for abort, and that abort is an upstream libcamera bug in the software ISP's
statistics path, not something this package can patch.

---

## Module load order

The sensors on these boards are not on a native I2C controller. They sit behind
the Synaptics SVP7500, which exposes an I2C tunnel over a USB bulk interface.
That whole chain — `usbio` → `i2c_usbio` → `intel_cvs` → `INT3472` — has to
exist **before** `intel_ipu7` goes looking for sensors.

`install.sh` writes `/etc/modprobe.d/99-ipu7-usbio-order.conf` for this. Without
it, everything binds correctly at boot and then falls apart a few seconds later:

```
intel-ipu7 0000:00:05.0: Found supported sensor HIMX1092:00
intel-ipu7 0000:00:05.0: Found supported sensor OVTI08F4:00
usbcore: registered new interface driver usbio-bridge     <- too late
Intel CVS driver i2c-INTC10E1:00: cvs_common_probe        <- too late
        ... ~9s later ...
usbio-bridge 3-3:1.0: Bulk out failed: -110
usb 3-3: USB disconnect, device number 2
```

after which the bridge re-enumerates and fails again, indefinitely, taking the
i2c adapters, both sensors and the media graph with it every cycle. Check your
own order with:

```bash
sudo dmesg | grep -E 'Found supported sensor|usbio-bridge|cvs_common_probe'
```

`Found supported sensor` appearing **before** `usbio-bridge` is the wrong order.
`verify.sh` checks for the softdep directly.

---

## The second half: making browsers work

This package fixes the **kernel** side — the sensors bind, `/dev/ipu7-psys0`
appears, and the cameras enumerate. That is necessary and it is not sufficient.

Stock libcamera falls back to its `simple` pipeline handler plus `SoftwareIsp`.
That works at the sensor's native resolution and **aborts at every other size**:

```
cam --stream width=640,height=480    -> Assertion '__n < this->size()' failed
cam --stream width=1280,height=720   -> Assertion '__n < this->size()' failed
cam --stream width=1920,height=1080  -> Assertion '__n < this->size()' failed
cam  (native)                        -> works
```

Below roughly half the sensor width libcamera selects the binned sensor mode,
and the statistics pass indexes past the end of a 64-bin array. Inside
WirePlumber that abort kills the process, and the application reports *"camera
in use by another application"*.

**Browsers ask for exactly those sizes.** So `cam --list` and `cam --capture`
look perfect while every real application fails — which is the single most
misleading state in this whole stack, because the test that looks authoritative
is the one that cannot see the problem. `LIBCAMERA_SOFTISP_MODE=cpu` does not
help; the bug is in the shared statistics path, reached from both debayer
backends.

The fix is a libcamera pipeline handler that drives the IPU7's **hardware ISP**
through `/dev/ipu7-psys0`:

| resolution | stock `simple` | `ipu7` handler |
|---|---|---|
| 1280x720  | crash | 28.57 fps |
| 1920x1080 | crash | 28.57 fps |
| native    | works | works |

It also costs far less CPU, since the ISP does the debayer instead of the host.

**https://github.com/jibsta210/ipu7-camera-linux** — see `libcamera-pipeline/BUILD.md`.

`verify.sh` reports which handler PipeWire is using and says so if you are on
the software one. Note it reads WirePlumber's journal, not `cam`: the CLI loads
your *system* libcamera and will say `simple` even when PipeWire is correctly
using the hardware handler.

⚠ The handler's ISP parameters were captured from the Intel Camera HAL for
**OV08X40**. On a board with a different RGB sensor (OV05C10, for instance) it
will need its own parameters and may not work unmodified. The kernel-side fixes
in this package are sensor-independent; this part is not.

---

## Removing it again

```bash
sudo ./uninstall.sh          # dry run — prints the plan, changes nothing
sudo ./uninstall.sh --go
sudo reboot
```

It removes only what this pack installs: its five DKMS modules, its two udev
rules, its three wireplumber drop-ins, and the psys source patches — restored
from the oldest backup the pack itself made and rebuilt for every kernel, so
psys goes back to upstream behaviour. It regenerates the initramfs at the end,
without which the old modules keep loading from it and the uninstall appears to
have done nothing.

It leaves the `ipu7-drivers` **package** alone — that belongs to your distro or
the AUR — along with any DKMS module it did not install and anything you
configured yourself, Howdy and PAM included.

`--keep-psys` removes the sensor modules but leaves `ipu7-drivers` patched.
That matters if suspend is your concern: until psys binds it never registers a
device, so it never takes part in system suspend. Once it does bind it joins
the suspend path for the first time, and on at least one board that surfaced a
resume failure which had been invisible until then. Restoring the psys source
is the specific thing that undoes it.

---

## Recovery — if the camera does not come back

**None of these modules is in the boot path.** They are camera modules:
`hm1092`, `intel_cvs`, `ipu-bridge`, `int3472`, `ov05c10`. A module that fails
to build or load costs you a camera, not a bootable system. There is no
scenario in which removing them is required to boot.

The one thing the installer does touch that *is* in the boot path is the
**initramfs**: it runs your distro's generator once at the end, because a DKMS
rebuild alone leaves the kernel loading the copy already in there. That is an
ordinary `mkinitcpio -P` / `dracut -f` / `update-initramfs -u` — the same
command a kernel update runs — and if it fails the installer says so and exits
non-zero rather than sending you to a reboot. `--no-initramfs` skips it
entirely if you would rather sequence that yourself. Note that a Btrfs snapshot
does **not** protect `/boot`; if you want a fallback there, keep a second
kernel installed.

**Your other kernels usually keep working copies.** The installer builds
per-kernel with `dkms install --force`, so a failure on one kernel does not
remove the module already installed for another, and picking a different
bootloader entry gets you back to a known state. The exception is named on
screen when it happens: if DKMS had the module registered against a *different*
source tree, that registration has to be replaced, and doing so removes it for
every kernel first. When a build then fails the installer says exactly that —
`not installed for ANY kernel — and its previous registration had to be
replaced` — rather than letting you believe the old copy survived.

To back the whole thing out:

```bash
for m in intel-cvs hm1092 int3472-patched ipu-bridge-patched ov05c10; do
  sudo dkms remove -m $m -v 1.0 --all 2>/dev/null
done
sudo rm -f /etc/udev/rules.d/99-svp7500-no-autosuspend.rules \
           /etc/udev/rules.d/99-hm1092-ir-led.rules
# the staged sources, and the .bak the installer leaves beside each of them
sudo rm -rf /usr/src/intel-cvs-1.0 /usr/src/hm1092-1.0 \
            /usr/src/int3472-patched-1.0 /usr/src/ipu-bridge-patched-1.0 \
            /usr/src/ov05c10-1.0 \
            /usr/src/intel-cvs-1.0.bak /usr/src/hm1092-1.0.bak \
            /usr/src/int3472-patched-1.0.bak /usr/src/ipu-bridge-patched-1.0.bak \
            /usr/src/ov05c10-1.0.bak
sudo udevadm control --reload-rules
sudo mkinitcpio -P      # or: dracut -f  /  update-initramfs -u
sudo reboot
```

The installer backs up anything it replaces. A previous
`/usr/src/<module>-<ver>` tree is moved to `/usr/src/<module>-<ver>.bak` — one
backup at a fixed path, overwritten each run, so re-running does not fill
`/usr/src` with copies. Howdy's `video_capture.py` and `config.ini`, and the
vendor `ipu-psys.c` before each patch, get a timestamped `.bak-<date>-<time>`
copy instead, because those are edited in place rather than replaced.

### The RGB camera died after a package update — `ipu7-drivers` r76+

This one is not caused by anything in this pack, it is the most common way the
camera dies after an ordinary `pacman -Syu` / `paru -Syu`, and nothing on the
screen names it. **Revisions r76 and later of Intel's `ipu7-drivers` break psys
on every distro that ships the staging `intel_ipu7` with the kernel** — Arch,
CachyOS, and anything else on a recent kernel. Upstream:
[intel/ipu7-drivers#93](https://github.com/intel/ipu7-drivers/issues/93).

The 2026-06-29 vendor drop appends two fields to `struct ipu7_bus_device` and
makes `ipu7_psys_probe()` write to one of them. That struct is allocated by
`intel_ipu7`, which came from your kernel and does not have the new fields — so
psys writes past the end of a kernel-owned allocation. `/dev/ipu7-psys0` never
appears and the RGB camera is gone. `isys` binds normally, because it ships
with the kernel, which is exactly what makes the failure look like a sensor or
a libcamera problem and sends people debugging the wrong component.

Am I affected? This changes nothing:

```bash
tools/install-ipu7-r74.sh --check
```

Recovery, one command — it downgrades `ipu7-drivers` to r74, re-applies the
psys patches, and rebuilds for **every** installed kernel (rebuilding only the
one you are on is how you get a working camera today and a dead one after the
next reboot into a different entry):

```bash
sudo tools/install-ipu7-r74.sh
sudo tools/install-ipu7-r74.sh --dry-run   # every step, nothing changed
```

Then keep it there. On Arch-family systems that means listing the package in
`IgnorePkg` in `/etc/pacman.conf`, or the next full upgrade puts r76 straight
back:

```
IgnorePkg = intel-ipu7-dkms-git
```

`install.sh` does **not** downgrade `ipu7-drivers` for you. It patches whatever
tree is registered with DKMS and verifies a psys module came out of it; on r76
that build can succeed and still leave you with no `/dev/ipu7-psys0`, which is
why this is a separate tool with its own check rather than a step folded into
the install.

The companion question — whether `int3472-patched` should be installed on a
given kernel at all — is answered the same way, and `install.sh` already asks
it per kernel before installing anything:

```bash
tools/int3472-needed.sh              # the kernel you are running
tools/int3472-needed.sh 7.1.4        # any installed kernel
```

Exit `0` means our copy is still needed there; exit `1` means that kernel's
in-tree `intel_skl_int3472_discrete` already registers the IR flood LED and
installing ours would take it away. See
[`int3472-patched`](#2-int3472-patched-dkms) below.

---

## Known-different hardware

The author's machine is **not** representative, and four things vary between
otherwise-similar laptops. All four are now discovered at runtime rather than
hardcoded:

| varies | example spread | how it is handled |
|---|---|---|
| **CSI-2 port** | port 2 on XPS 16 DA16260, **port 1** on Dell Pro 14 | followed from the sensor's own link in the media graph |
| **I2C bus number** | appears in the entity name (`hm1092 12-0024` vs `5-0024`) | entities resolved by name, never by bus |
| **Bridge ACPI id** | `INTC10E1` (PTL) vs **`INTC10DE`** (LNL), plus `INTC10CF`/`INTC10E0` | all four in the driver's match table |
| **IR LED ownership** | INT3472 owns the illuminator GPIO, not the sensor driver | udev rule grants the `video` group access so Howdy can fire it unprivileged |

`/dev/videoN`, `/dev/v4l-subdevN` and libcamera indexes **shuffle between boots**
even on one machine, so nothing should ever be hardcoded to a number.

These differences were only discoverable because people ran this on hardware the
author does not own and reported precisely what differed. Thanks to
**@acmodeu** (CSI-2 port 1 on the Dell Pro 14), **@Aohzan** (the `INTC10DE`
bridge id), and **@dalandro** (Dell Pro 14 Plus PB14250 on Ubuntu, OV05C10
sensor). Every one of those was a wrong assumption baked into the tooling.

---

## If it does not work, what to send me

First, run the package's own consistency check. It needs no hardware and no
root, and it catches the class of bug where the download itself is wrong — a
module the installer cannot find, a documented command that does not exist:

```bash
./tools/selftest.sh
```

If that fails, the package is broken rather than your machine, and the output
tells you which file is missing. Include it and stop there.

Otherwise, open an issue with the output of **all** of these. Every slow
diagnosis so far started with a report missing one of them — most often the
module paths, which are what reveal a stale or split-provenance install.

Nothing below clears your kernel log. `verify.sh` used to run `dmesg -C`, which
erased every boot-time probe message before step 5 could read it; it does not
any more, so you can run these in order.

```bash
# 1. the whole stack, one command (this is the important one)
sudo ./tools/verify.sh 2>&1 | tee /tmp/svp7500-report.txt

# 2. environment
uname -r; head -2 /etc/os-release

# 3. what DKMS thinks is installed, for which kernels
dkms status

# 4. WHERE each module is actually loaded from — kernel vs updates/dkms.
#    This is what exposes split provenance and stale builds.
for m in intel_ipu7 intel_ipu7_isys intel_ipu7_psys ipu_bridge intel_cvs hm1092 ov05c10; do
  printf '%-20s %s\n' "$m" "$(modinfo -n $m 2>&1)"
done

# 5. kernel messages from the camera stack
sudo dmesg | grep -iE 'ipu7|ipu-bridge|intel_cvs|hm1092|ov08x40|ov05c10|int3472'

# 6. the media graph (entity names, ports, links)
media-ctl -d /dev/media0 -p

# 7. your hardware ids
lsusb -d 06cb:0701; ls /sys/bus/i2c/devices/ | grep -i INTC
```

For reference, a healthy install on the author's machine shows this provenance in
step 4 — `intel_ipu7`/`isys` from the kernel tree and the rest from
`updates/dkms`:

```
intel_ipu7           /lib/modules/<ver>/kernel/drivers/staging/media/ipu7/intel-ipu7.ko.zst
intel_ipu7_isys      /lib/modules/<ver>/kernel/drivers/staging/media/ipu7/intel-ipu7-isys.ko.zst
intel_ipu7_psys      /lib/modules/<ver>/updates/dkms/intel-ipu7-psys.ko.zst
ipu_bridge           /lib/modules/<ver>/updates/dkms/ipu-bridge.ko.zst
intel_cvs            /lib/modules/<ver>/updates/dkms/intel_cvs.ko.zst
hm1092               /lib/modules/<ver>/updates/dkms/hm1092.ko.zst
```

Paths differ legitimately across distros (`.ko` vs `.ko.zst`, `extra/` vs
`updates/dkms/`); what matters is that a module is not loaded from two places
and not older than what you just built.

Issue tracker: [intel/vision-drivers#37](https://github.com/intel/vision-drivers/issues/37)

---

## What's in here

6 components, each fixing a different piece of the broken stack.

### 1. `intel-cvs` DKMS (the headline fix)
- Patches `cvs_init()` to remove a buggy `IRQF_ONESHOT` flag from `devm_request_irq()`. The flag was meaningless on a non-threaded handler and caused a kernel WARNING. **More importantly: it made IRQ delivery from the SVP7500 unreliable, which is why the bridge wedges itself after brief idle periods.**
- Adds verbatim Windows-format MIPI config payloads (RGB + IR), captured from USBPcap traces of Windows on identical hardware.
- Exposes a sysfs `cmd` interface (`echo state > cmd`, `echo mipi-ir > cmd`, etc.) for runtime experiments.

### 2. `int3472-patched` DKMS
- Adds support for GPIO type `0x02` (IR LED) — needed for HM1092 sensors.
- Adds an SSDB `controllogicid` fallback walk through the ACPI namespace. Required on USBIO platforms (where the `_DEP` chain is broken and `acpi_dev_get_next_consumer_dev()` returns NULL).
- **Only installed on kernels that need it, and most modern ones do not.**
  Mainline gained `skl_int3472_register_led`, so from roughly 7.1 the in-tree
  `intel_skl_int3472_discrete` already publishes
  `/sys/class/leds/<sensor>::ir_flood_led`. Ours does not register a
  `led_classdev` at all — it maps the GPIO to the sensor — and DKMS installs
  into `updates/`, which `depmod` prefers over `kernel/`. So on such a kernel
  installing it *removes* the LED node that `udev/99-hm1092-ir-led.rules`
  chgrps and `howdy/ir_reader.py` writes to: the illuminator then never fires
  for an unprivileged lock-screen auth, every frame is too dark, and face
  unlock times out while working perfectly under `sudo`.
  `install.sh` checks each installed kernel (`tools/int3472-needed.sh` answers
  the same question on its own) and skips the ones that already have it,
  saying so. If an earlier run already installed it on such a kernel, the
  installer now **fails** and gives you the `dkms remove` that restores the
  in-tree driver.

### 3. `ipu-bridge-patched` DKMS
- Adds `HIMX1092` to the `supported_sensors[]` array so the kernel actually enumerates the IR sensor.

### 4. `hm1092` DKMS
- New v4l2-subdev driver for Himax HM1092.
- 198-register init sequence reverse-engineered from a Windows USBPcap during Hello face auth.
- Lazy IR LED management: LED is OFF when the sensor is in standby, only turns ON during streaming. Matches Windows behavior. Stock implementations leave the LED ON 24/7 after module load.

### 5. `ov05c10` DKMS
- RGB sensor driver for boards that pair the SVP7500 bridge with the **OV05C10** (`OVTI05C1`) sensor — e.g. the **Dell Pro Plus 14 PB14250** — instead of the OV08x40 used on the DA16260.
- The driver is the out-of-tree Intel one from [`intel/ipu6-drivers`](https://github.com/intel/ipu6-drivers) (`drivers/media/i2c/ov05c10.c`); it was never mainlined, so affected boards have no RGB camera until it is installed. The bridge half already enumerates `OVTI05C1` — this supplies the missing sensor driver.
- Packaged as DKMS so it survives kernel upgrades. Builds clean against 6.18 / 7.0 / 7.1.
- **Not optional on a board that has that sensor.** If your firmware declares
  `OVTI05C1`, this is the only RGB driver your machine can use, so `install.sh`
  treats it as required there: a build failure is exit `1`, not a line in
  `steps skipped`. On every other board its absence changes nothing.

### 6. udev rules
- Disables USB autosuspend on the SVP7500. Bridge firmware has trouble with power state transitions; keeping it always-on prevents some failure modes.
- Grants the `video` group write access to the IR illuminator's brightness, so Howdy can fire it as an unprivileged user from a lock screen.

## Why this needed reverse engineering at all

The Synaptics SVP7500 is a proprietary MIPI bridge chip. Synaptics has not published its command reference publicly. Combined with the Intel IPU7 staging-driver stack (also fairly opaque), the camera "just doesn't work" on most Linux distros for affected laptops.

This fix pack is the result of three months of community reverse-engineering: USBPcap captures from Windows installs, Ghidra analysis of `Vision.sys`, kernel-side patches, and a lot of iteration.

### IR camera — SOLVED (2026-07-25)

The IR camera streams, and Howdy authenticates against it from the lock screen —
verified on the author's machine.

**Root cause: `V4L2_CID_LINK_FREQ` was set to the MIPI per-lane bit rate instead
of the DDR clock — exactly 2x too high.** `ipu7-isys` therefore programmed the
CSI-2 D-PHY at ~721 Mbps against a sensor transmitting at ~361. The clock lane
came up, but no data packet ever framed, so the port produced zero SOF forever.

```
648x368 @30, 1 lane, RAW10:
  LLP 1620 x FLL 740 x 30 fps          = 35,964,000 px/s   (pixel_rate)
  x 10 bpp                             = 359,640,000 bit/s (bit rate)
  V4L2_CID_LINK_FREQ = DDR clock       = 180,480,000        <-- correct
  what the driver published            = 360,960,000        <-- 2x too high
```

The wrong value came from the natural derivation — the sensor's own PLL
registers (`19.2 MHz x 94 / 5 = 360.96 MHz`). That is genuinely the PLL output;
it is just the bit clock, not what V4L2 wants. Anyone reverse-engineering this
sensor from its PLL configuration lands on the same number. It was finally
pinned down by extracting the mode-descriptor array from the Windows
`hm1092.sys`, where `pixel_rate = 36,000,000` sits beside `link = 360,960,000`,
making the factor of two unambiguous.

**Previous hypotheses in this README and in
[intel/vision-drivers#37](https://github.com/intel/vision-drivers/issues/37)
were wrong and are retracted:**

* The CVS bridge does **not** block the data lane. With the bridge given no MIPI
  link configuration at all, the sensor's clock still reaches the IPU.
* `HOST_SET_MIPI_CONFIG` (0x0830) is **not** needed for IR. Windows never sends
  one — every 0x0830 in all seven USB captures carries RGB geometry, and
  648x368 appears in no USB payload. This fix pack was sending one; Windows does
  not.
* The register init table was never wrong — it is byte-identical to Windows in
  content and order, confirmed both from the USB captures and by extracting the
  tables from `hm1092.sys` (all four Dell driver builds carry identical tables).
* There is no frame-trigger, sync or slave-mode register anywhere in the sensor
  or in any Windows driver build.

Full write-up: [IR-FINDINGS.md](IR-FINDINGS.md)

### Howdy integration

`howdy/ir_reader.py` is a Howdy recorder that reads the IR node directly.
It deliberately bypasses libcamera/PipeWire, because libcamera's SoftwareIsp
**debayers** this monochrome sensor (it is tagged SGRBG10) and PipeWire
renegotiates the stream to 1920x1080, landing the 648x368 payload in a
mostly-black buffer. It also drives the IR illuminator, which the sensor driver
cannot because INT3472 owns that GPIO.

Gotchas that cost real debugging time:

* The V4L2 control is **`link_frequency`, not `link_freq`** — the wrong name
  fails *silently* and yields convincing fake negatives. Always confirm the
  kernel's `config phy N ... mbps M` line actually changed.
* `/dev/videoN`, `/dev/v4l-subdevN` and libcamera indexes **shuffle between
  boots**. Resolve by entity name (`tools/find-ir-node.sh`), never hardcode.
* Howdy's `dark_threshold` is **not brightness** — it is the percentage of
  near-black pixels, and a frame is rejected when it *exceeds* the threshold.
  IR frames here are ~70-77% black, so the stock `60` rejects everything. Use 90.
* Howdy's recognition runs as the **unprivileged user** under a lock screen, so
  the illuminator needs `udev/99-hm1092-ir-led.rules` or it silently never fires
  and every frame is too dark to detect a face.

### Lunar Lake (LNL) RGB Support, Privacy LED Fix & On-Demand V4L2 Loopback

Recent Dell Lunar Lake laptops (such as the Dell Pro 14 PB14250, ACPI bridge ID `INTC10DE:00`) pair the Synaptics SVP7500 bridge with an OmniVision OV05C10 RGB sensor and Himax HM1092 IR sensor using **Bridge Protocol 1.0**.

Several platform-specific challenges were reverse-engineered and resolved in this fork:

#### 1. The Autonomous Privacy LED Latch & `SET_HOST_IDENTIFIER`
- **Symptom**: On Protocol 1.0 devices, the white privacy LED turned on upon the first camera frame and remained stuck ON continuously—even after closing the camera app, and even across `s2idle` Modern Standby (because Lunar Lake motherboards keep 5V VBUS power active to the internal USB hub during sleep).
- **Root cause**: The SVP7500 firmware implements an autonomous one-way hardware latch for the privacy LED. In upstream `intel_cvs`, the `SET_HOST_IDENTIFIER` (0x0805) command was guarded inside `if (icvs->magic_num_support)`. Because Protocol 1.0 devices report `magic_num_support = false`, `SET_HOST_IDENTIFIER` was never sent, leaving the bridge in autonomous control mode.
- **The Fix**: 
  - `SET_HOST_IDENTIFIER` is now dispatched unconditionally during probe across all protocol versions.
  - The payload explicitly sets `privacy_led_host = 1` and `rgbcamera_pwrup_host = 1`.
  - Setting `privacy_led_host = 1` commands the bridge firmware to relinquish autonomous LED control to the host OS. Since the Linux IPU7 driver does not drive the hardware LED, the latch is suppressed and the LED stays off permanently, preventing the persistent glare.
  - *Hardware requirement*: `rgbcamera_pwrup_host` MUST be kept set to `1`. Omitting or clearing this bit corrupts the SVP7500 MIPI PHY transmitter timing, leading to `Received packet is too long / short` errors and hardware stream timeouts in `intel_ipu7_isys`.
  - System privacy awareness is cleanly handled by userland indicators (e.g. the KDE Plasma / GNOME camera status icon), which accurately show when `ov05c10` is actively streaming.

#### 2. RGB Stream Activation & Low-Light Tuning (`ov05c10`)
- **Bridge Port 0 Forwarding**: `intel_cvs` exports `cvs_send_mipi_rgb_config()`, called directly from `ov05c10_start_streaming()` once MIPI clock lanes are live.
- **IR Stream Teardown Recovery**: In `hm1092_set_stream(0)`, the driver automatically restores port 0 RGB routing so that running IR face unlock does not disrupt subsequent RGB webcam sessions.
- **Analog Gain Calibration**: The default analog gain (`OV05C10_ANAL_GAIN_DEFAULT`) in `ov05c10.c` was raised from `0x10` (1x) to `0x40` (4x). This resolves severe underexposure under normal indoor room lighting without introducing digital noise.

#### 3. On-Demand V4L2 Loopback & Device Isolation (QRCA, WebRTC)
Modern browsers (Firefox, Chrome) and native Wayland applications talk directly to PipeWire ("Built-in Front Camera"), incurring **0% background CPU** when idle. However, legacy V4L2 apps and QtMultimedia applications (such as KDE's **Qrca** Wi-Fi QR code scanner) do not support the PipeWire camera portal directly and scan `/dev/video*`.

- **The Problem with 24/7 Loopback**: Running a background service like `camera-loopback.service` around the clock continuously feeds `/dev/video50`, which burns **30–40% CPU** on GStreamer/WirePlumber and keeps the camera sensor awake 24/7.
- **The Raw IPU7 Node Collision**: When V4L2 applications scan `/dev/video*`, they hit the 32 raw Intel IPU7 ISYS endpoints (`/dev/video0` through `/dev/video31`). These raw endpoints either return incompatible raw Bayer buffers (triggering segmentation faults in WebRTC's `libyuv` / `ARGBToUVRow_AVX2`) or bind to the monochrome IR sensor.
- **The Solution**:
  - `v4l2loopback` is configured with `exclusive_caps=1 card_label="Integrated Camera" video_nr=50` in `/etc/modprobe.d/v4l2loopback.conf`.
  - An on-demand wrapper (`scripts/qrca`, installed to `/usr/local/bin/qrca`) starts the PipeWire-to-loopback GStreamer feeder **only** while the application is active.
  - The wrapper uses **Bubblewrap (`bwrap`)** device isolation to mask `/dev/video0`..`/dev/video31` with `/dev/null`, exposing solely `/dev/video50` to the application.
  - Upon window closure, a bash `trap` cleanly kills the GStreamer feeder in under 50ms, returning camera sensor power and idle CPU consumption to **0%**.

## License

The DKMS modules contain code from Intel (`intel-cvs`, `ipu-bridge`), Himax (sensor reference), and original work on top. License terms inherit from each upstream component — primarily GPL-2.0.

## Credits

- @jibsta210 — patch development, reverse engineering, testing
- @tverhaeghe — USBPcap traces from Windows on matching hardware (the key dataset)
- @acmodeu, @Aohzan, @dalandro — testing on hardware the author does not own; between them they surfaced the CSI-2 port, bridge ACPI id and sensor differences that the tooling now discovers instead of assuming
- Intel `vision-drivers` and `ipu7-drivers` upstream maintainers — for the base code we patched
- Hans de Goede (@hdegoede) — Linux mainline IPU6/7 camera maintainer
