#!/bin/bash
# ===========================================================================
# pam_auth.sh — Howdy face authentication PAM helper for Linux (Python 3)
#
# Supports both root callers (polkit, sddm, plasmalogin, su) and
# non-root callers (kscreenlocker) with NOPASSWD or root privileges.
# ===========================================================================
set -u

USER="${PAM_USER:-${1:-}}"
[ -z "$USER" ] && exit 1

HOWDY_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
[ ! -f "$HOWDY_DIR/models/${USER}.dat" ] && exit 1

if [ "$(id -u)" -eq 0 ]; then
    exec /usr/bin/python3 -W ignore "$HOWDY_DIR/compare.py" "$USER"
else
    exec sudo -n /usr/bin/python3 -W ignore "$HOWDY_DIR/compare.py" "$USER"
fi
