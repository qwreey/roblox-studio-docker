#!/usr/bin/env bash
set -eu

# Keeps Studio's floating panels above its main window - see wine-owned-popups.c for why
# Wine itself doesn't. Not critical: if this dies, a click on the main window can bury a
# floating panel again until it restarts.

. /etc/roblox-studio/wait-for-wayland.sh
wait_for_wayland_socket

# labwc's XWayland, the display Studio's Wine runs on: whatever labwc exported to the
# programs it started (waybar, via its autostart), :0 when that isn't readable yet.
# Connecting starts XWayland if labwc hasn't yet, and keeps it up.
display=""
for _ in $(seq 1 50); do
  waybar_pid="$(pgrep -x waybar | head -n1 || true)"
  if [[ -n "${waybar_pid}" ]]; then
    display="$(tr '\0' '\n' < "/proc/${waybar_pid}/environ" | sed -n 's/^DISPLAY=//p')"
    [[ -n "${display}" ]] && break
  fi
  sleep 0.2
done
export DISPLAY="${display:-:0}"
echo "[wine-owned-popups] watching DISPLAY=${DISPLAY}"
exec /usr/local/bin/wine-owned-popups
