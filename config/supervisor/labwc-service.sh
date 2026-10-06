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
  # 1280x720 default and has no fixed EDID mode list to select from. DESKTOP_RESOLUTION
  # is validated in entrypoint.sh; it's only the starting size - VNC clients resize the
  # output later, and desktop-resize-service.sh keeps Studio's desktop matched to it.
  wlr-randr --output HEADLESS-1 --custom-mode "${DESKTOP_RESOLUTION:-1920x1080}" \
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

# The /usr/local/bin builds carry config/pointer-warp/'s patches, which make a right-drag
# in Studio's viewport turn the camera by the distance the VNC viewer's pointer moved
# (see the Dockerfile and CLAUDE.md's "Camera drag over VNC"). VNC_POINTER_WARP_FIX=false
# runs the distro builds instead - the escape hatch if the patched ones misbehave.
# WLR_XWAYLAND is how wlroots is told which Xwayland to spawn; the default is the
# compiled-in /usr/bin/Xwayland.
case "${VNC_POINTER_WARP_FIX:-true}" in
  ''|1|true|TRUE|yes|YES|on|ON)
    export WLR_XWAYLAND=/usr/local/bin/Xwayland
    exec /usr/local/bin/labwc
    ;;
  0|false|FALSE|no|NO|off|OFF)
    echo "[labwc-service] VNC_POINTER_WARP_FIX=${VNC_POINTER_WARP_FIX} — running the distro labwc/Xwayland; dragging Studio's camera over VNC will spin it"
    exec /usr/bin/labwc
    ;;
  *)
    echo "[labwc-service] WARNING: VNC_POINTER_WARP_FIX=${VNC_POINTER_WARP_FIX} is not a recognized boolean — keeping the fix on" >&2
    export WLR_XWAYLAND=/usr/local/bin/Xwayland
    exec /usr/local/bin/labwc
    ;;
esac
