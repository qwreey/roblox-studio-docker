#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/root}"
export XDG_RUNTIME_DIR="/tmp/xdg-runtime"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER="${WLR_RENDERER:-gles2}"

VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"

# Seed Vinegar's config with webview="" on first run only (never overwrite an existing
# one — the owner may deliberately change settings later via the GUI). Without this,
# a fresh ./data/vinegar-config volume hits the exact blank-WebView2-login bug documented
# in CLAUDE.md's "Milestone 3" section on its very first launch.
mkdir -p "${HOME}/.config/vinegar"
if [[ ! -f "${HOME}/.config/vinegar/config.toml" ]]; then
  cp /etc/vinegar-default-config.toml "${HOME}/.config/vinegar/config.toml"
fi

cleanup() {
  echo "[entrypoint] shutting down"
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# D-Bus session bus — required for xdg-desktop-portal (used by Vinegar's "Login via
# Browser" flow) and to avoid GTK apps warning about a missing machine-id. The WM and
# everything it execs inherit this via $XDG_RUNTIME_DIR/bus, the standard fallback
# location GDBus checks when DBUS_SESSION_BUS_ADDRESS isn't explicitly set.
if [[ ! -s /etc/machine-id ]]; then
  dbus-uuidgen > /etc/machine-id
fi
dbus-daemon --session --address="unix:path=${XDG_RUNTIME_DIR}/bus" --nofork --nopidfile &
DBUS_PID=$!
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# No real GNOME/KDE session here, so xdg-desktop-portal has no desktop-specific backend
# to auto-select via the modern portals.conf mechanism — XDG_CURRENT_DESKTOP=GNOME makes
# it fall back to matching each interface against installed .portal files' deprecated
# `UseIn=` key instead. Both xdg-desktop-portal-gtk and -gnome are installed; in practice
# gnome.portal is what actually ends up providing OpenURI (via its AppChooser impl) —
# gtk.portal's own backend process fails to start for several interfaces in this minimal
# environment. Do NOT force XDG_DESKTOP_PORTAL_BACKEND=gtk (Vinegar's own troubleshooting
# doc suggests this, but it's Flatpak-specific guidance and breaks OpenURI resolution
# here — confirmed by testing).
export XDG_CURRENT_DESKTOP=GNOME

echo "[entrypoint] starting labwc (headless)"
labwc &
WM_PID=$!

WAYLAND_SOCKET=""
for _ in $(seq 1 50); do
  CANDIDATE="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -n1)"
  if [[ -n "${CANDIDATE}" ]]; then
    WAYLAND_SOCKET="$(basename "${CANDIDATE}")"
    break
  fi
  sleep 0.2
done
if [[ -z "${WAYLAND_SOCKET}" ]]; then
  echo "[entrypoint] labwc failed to create a Wayland socket" >&2
  exit 1
fi
export WAYLAND_DISPLAY="${WAYLAND_SOCKET}"
echo "[entrypoint] labwc is up on WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"

# labwc (unlike sway) has no built-in output-resolution config directive — force it via
# wlr-randr, a generic wlroots-protocol client that works regardless of compositor.
# --custom-mode (not --mode) is required: the headless backend only pre-registers a
# 1280x720 default and doesn't have a fixed EDID-provided mode list to select from.
wlr-randr --output HEADLESS-1 --custom-mode 1920x1080 2>&1 || echo "[entrypoint] WARNING: wlr-randr failed to set output mode"

# D-Bus service activation (xdg-desktop-portal and friends, started on-demand the first
# time something calls a portal method) uses D-Bus's own "activation environment", which
# is fixed at dbus-daemon startup and does NOT pick up later `export`s in this script —
# it has to be explicitly pushed. Without this, an auto-activated portal never sees
# WAYLAND_DISPLAY and Chromium (launched via the portal for Vinegar's "Login via Browser"
# flow) falls back to a nonexistent X11 display and fails to start.
dbus-update-activation-environment --systemd \
  WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS \
  2>/dev/null || true

WAYVNC_ARGS=(--output=HEADLESS-1 0.0.0.0 "${VNC_PORT}")
if [[ -n "${VNC_PASSWORD}" ]]; then
  WAYVNC_CFG="/tmp/wayvnc.cfg"
  {
    echo "enable_auth=true"
    echo "username=studio"
    echo "password=${VNC_PASSWORD}"
  } > "${WAYVNC_CFG}"
  chmod 600 "${WAYVNC_CFG}"
  WAYVNC_ARGS=(-C "${WAYVNC_CFG}" "${WAYVNC_ARGS[@]}")
else
  echo "[entrypoint] WARNING: VNC_PASSWORD not set — running wayvnc with no authentication"
fi

echo "[entrypoint] starting wayvnc on port ${VNC_PORT}"
wayvnc "${WAYVNC_ARGS[@]}" &
VNC_PID=$!

wait -n "${WM_PID}" "${VNC_PID}" "${DBUS_PID}"
