#!/usr/bin/env bash
set -eu

. /etc/roblox-studio/wait-for-wayland.sh

# Post-start setup (forcing the headless output's resolution, and pushing
# WAYLAND_DISPLAY into D-Bus's activation environment) can only run *after* labwc has
# created its socket, but labwc itself has to stay in the foreground so supervisord's
# stop signal reaches it directly via this script's own `exec` below - so this runs in a
# background subshell instead of blocking that exec. Exec doesn't disturb already-forked
# background jobs; this subshell just becomes a normal child of the now-labwc process.
(
  wait_for_wayland_socket

  # labwc (unlike sway) has no built-in output-resolution config directive - force it via
  # wlr-randr, a generic wlroots-protocol client that works regardless of compositor.
  # --custom-mode (not --mode) is required: the headless backend only pre-registers a
  # 1280x720 default and has no fixed EDID mode list to select from.
  wlr-randr --output HEADLESS-1 --custom-mode 1920x1080 \
    || echo "[labwc-service] WARNING: wlr-randr failed to set output mode" >&2

  # D-Bus service activation (xdg-desktop-portal and friends, started on-demand) uses
  # D-Bus's own "activation environment", fixed at dbus-daemon startup - it does NOT pick
  # up this later WAYLAND_DISPLAY export on its own, it has to be explicitly pushed.
  # Without this, an auto-activated portal never sees WAYLAND_DISPLAY and Chromium
  # (launched via the portal for Vinegar's "Login via Browser" flow) falls back to a
  # nonexistent X11 display and fails to start.
  dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS \
    2>/dev/null || true
) &

exec labwc
