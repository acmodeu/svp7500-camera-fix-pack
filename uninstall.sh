#!/bin/bash
# ===========================================================================
# Remove everything this fix-pack installed, and put the psys source back.
#
#   sudo ./uninstall.sh          # DRY RUN -- prints the plan, changes nothing
#   sudo ./uninstall.sh --go     # do it
#   sudo ./uninstall.sh --go --keep-psys    # leave ipu7-drivers patched
#
# WHAT IT REMOVES
#   - the DKMS modules this pack owns: hm1092, intel-cvs, ipu-bridge-patched,
#     ov05c10, int3472-patched
#   - /etc/udev/rules.d/99-hm1092-ir-led.rules
#   - /etc/udev/rules.d/99-svp7500-no-autosuspend.rules
#   - the three wireplumber drop-ins under
#     /usr/share/wireplumber/wireplumber.conf.d/
#   - the psys source patches, by restoring the oldest backup this pack made
#     and rebuilding ipu7-drivers, so psys goes back to upstream behaviour
#
# WHAT IT DOES NOT TOUCH
#   - the ipu7-drivers PACKAGE itself. That usually comes from your distro or
#     the AUR, and removing it is your package manager's job, not this
#     script's. Only the local source patches are undone.
#   - any DKMS module this pack did not install (v4l2loopback, openrazer,
#     amneziawg and friends are left exactly as they are).
#   - Howdy, PAM configuration, or anything you configured yourself.
#
# WHY YOU MIGHT WANT THIS
#   Once psys actually binds, it starts taking part in system suspend for the
#   first time. On at least one board that surfaced a resume failure that was
#   previously invisible because psys never registered a device at all. If
#   suspend matters more to you than the camera, restoring the psys source is
#   the specific thing that undoes it.
# ===========================================================================
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GO=0; KEEP_PSYS=0
for a in "$@"; do
  case $a in
    --go) GO=1 ;;
    --keep-psys) KEEP_PSYS=1 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_OK=; C_WARN=; C_OFF=; }

step(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
did(){  printf '  %sremoved%s  %s\n' "$C_OK" "$C_OFF" "$*"; }
plan(){ printf '  would remove  %s\n' "$*"; }
plando(){ printf '  would do      %s\n' "$*"; }
done_(){ printf '  %sdone%s     %s\n' "$C_OK" "$C_OFF" "$*"; }
skip(){ printf '  not present   %s\n' "$*"; }
warn(){ printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

# Only modules this pack ships. Anything else on the system is not ours to
# remove -- a uninstaller that takes out a user's v4l2loopback or graphics
# tablet driver because it happened to be in `dkms status` is a bug.
OURS=(hm1092 intel-cvs ipu-bridge-patched ov05c10 int3472-patched)

step "DKMS modules"
for m in "${OURS[@]}"; do
  mapfile -t VERS < <(dkms status 2>/dev/null | sed -n "s|^${m}[/,] *\([^,]*\),.*|\1|p" | sort -u)
  if [[ ${#VERS[@]} -eq 0 ]]; then skip "$m"; continue; fi
  for v in "${VERS[@]}"; do
    if [[ $GO -eq 1 ]]; then
      dkms remove -m "$m" -v "$v" --all >/dev/null 2>&1
      rm -rf "/usr/src/${m}-${v}"
      did "$m/$v"
    else
      plan "$m/$v  (dkms remove --all, plus /usr/src/${m}-${v})"
    fi
  done
done

step "udev rules and modprobe.d configs"
for f in /etc/udev/rules.d/99-hm1092-ir-led.rules /etc/udev/rules.d/99-svp7500-no-autosuspend.rules \
         /etc/modprobe.d/99-ipu7-usbio-order.conf /etc/modprobe.d/v4l2loopback.conf; do
  if [[ -f $f ]]; then
    if [[ $GO -eq 1 ]]; then rm -f "$f"; did "$f"; else plan "$f"; fi
  else skip "$f"; fi
done

step "desktop integration and on-demand wrappers"
for f in /usr/local/bin/qrca /usr/local/share/applications/org.kde.qrca.desktop \
         /usr/local/share/applications/org.kde.qrca.wifi.desktop; do
  if [[ -f $f ]]; then
    if [[ $GO -eq 1 ]]; then rm -f "$f"; did "$f"; else plan "$f"; fi
  else skip "$f"; fi
done
if [[ $GO -eq 1 ]] && command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/local/share/applications 2>/dev/null || true
fi

step "wireplumber drop-ins"
WPD=/usr/share/wireplumber/wireplumber.conf.d
for c in 50-disable-v4l2-ipu7.conf 51-libcamera-pause-on-idle.conf 52-libcamera-longer-timeout.conf; do
  f=$WPD/$c
  if [[ -f $f ]]; then
    if [[ $GO -eq 1 ]]; then rm -f "$f"; did "$f"; else plan "$f"; fi
  else skip "$f"; fi
done

step "psys source patches"
if [[ $KEEP_PSYS -eq 1 ]]; then
  warn "--keep-psys given: leaving ipu7-drivers patched"
else
  IV=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers[/,] *\([^,]*\),.*|\1|p' | sort -u | head -1)
  if [[ -z ${IV:-} ]]; then
    skip "ipu7-drivers is not registered with DKMS"
  else
    PD=/usr/src/ipu7-drivers-$IV/drivers/media/pci/intel/ipu7/psys
    PSYSC=$PD/ipu-psys.c
    # The OLDEST backup is the one closest to pristine -- each patch script
    # takes its own snapshot, so the newest is merely "before the last patch".
    # NOTE: this restores the tree to the state before this pack's FIRST
    # patch, which is what matters here -- not necessarily to pristine vendor
    # source. If the tree was already modified before you ever ran install.sh,
    # reinstall the ipu7-drivers package instead for a guaranteed clean tree.
    OLDEST=$(ls -1tr "$PD"/ipu-psys.c.{orig,pre-*,before-*} 2>/dev/null | head -1)
    if [[ -z ${OLDEST:-} ]]; then
      warn "no backup of ipu-psys.c found in $PD"
      warn "reinstall the ipu7-drivers package to get a pristine source:"
      warn "  Arch/CachyOS:  sudo pacman -S --overwrite '*' intel-ipu7-dkms-git"
    elif [[ $GO -eq 1 ]]; then
      cp -a "$PSYSC" "$PSYSC.uninstall-$(date +%Y%m%d-%H%M%S)"
      cp -a "$OLDEST" "$PSYSC"
      done_ "restored $PSYSC from $(basename "$OLDEST")"
      for k in $(ls /lib/modules 2>/dev/null); do
        [[ -d /lib/modules/$k/build ]] || continue
        # build --force actually recompiles; install --force alone only
        # re-places a cached artifact, which would leave the patched module
        # in place and make this uninstall a no-op.
        dkms build   --force "ipu7-drivers/$IV" -k "$k" >/dev/null 2>&1
        dkms install --force "ipu7-drivers/$IV" -k "$k" >/dev/null 2>&1
        done_ "rebuilt ipu7-drivers/$IV for $k"
      done
    else
      plando "restore $PSYSC from $(basename "$OLDEST"), then rebuild for every kernel"
    fi
  fi
fi

step "initramfs"
if   command -v mkinitcpio       >/dev/null 2>&1; then IC="mkinitcpio -P"
elif command -v dracut           >/dev/null 2>&1; then IC="dracut --regenerate-all --force"
elif command -v update-initramfs >/dev/null 2>&1; then IC="update-initramfs -u -k all"
else IC=""; fi
if [[ -z $IC ]]; then
  warn "no initramfs generator found — regenerate it yourself before rebooting"
elif [[ $GO -eq 1 ]]; then
  # Without this the initramfs keeps loading the modules you just removed, and
  # the uninstall looks like it did nothing.
  if $IC; then
    done_ "initramfs regenerated ($IC)"
  else
    warn "$IC failed — run it by hand"
  fi
else
  plando "regenerate the initramfs ($IC)"
fi

if [[ $GO -eq 0 ]]; then
  cat <<EOF

  DRY RUN — nothing was changed. Re-run with --go to do it.

    sudo $0 --go

  Add --keep-psys to remove the sensor modules but leave ipu7-drivers patched.
EOF
else
  cat <<EOF

  Done. REBOOT to load the stock modules.

  After rebooting the RGB and IR cameras will be gone, and /dev/ipu7-psys0
  should be missing again — that is what an uninstall means here.

  To reinstall later:  sudo $HERE/install.sh
EOF
fi
