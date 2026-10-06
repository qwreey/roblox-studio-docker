#!/usr/bin/env bash
set -u

# Keeps Studio's Wine virtual desktop the size of the screen. A VNC client asking for its
# own window size (noVNC's resize=remote, TigerVNC's SetDesktopSize) makes wayvnc resize
# HEADLESS-1, and Wine ignores window-manager resizes of a virtual desktop - so this
# watches the output and resizes the desktop from inside Wine (desktop-resize.exe).
# Not critical: if this dies, the desktop just stops following the screen.

. /etc/roblox-studio/wait-for-wayland.sh
. /etc/roblox-studio/desktop-size.sh
wait_for_wayland_socket || exit 1

RESIZE_EXE='Z:\usr\local\lib\roblox-studio\desktop-resize.exe'

current_screen() {
  wlr-randr --output HEADLESS-1 2>/dev/null | sed -n 's/^[[:space:]]*\([0-9]\+x[0-9]\+\) px.*(current).*/\1/p' | head -n1
}

apply() {
  local screen="$1" size explorer_pid desktop display wine
  if ! size="$(desktop_size_for_screen "${screen}")"; then
    echo "[desktop-resize] screen ${screen} is too small for Studio - leaving its desktop as it is"
    return
  fi
  virtual_desktop_enabled || return
  set_vinegar_desktop_size "${size}"
  set_wine_default_desktop_size "${size}" || echo "[desktop-resize] could not set Wine's default desktop size" >&2

  # Studio's desktop, if it's up: Vinegar launched it as `explorer /desktop=<uuid>,WxH`.
  explorer_pid="$(pgrep -f 'explorer\.exe /desktop=[^,]+,' | head -n1)"
  if [[ -z "${explorer_pid}" ]]; then
    echo "[desktop-resize] screen ${screen}: next Studio launch gets a ${size} desktop"
    return
  fi
  desktop="$(tr '\0' ' ' < "/proc/${explorer_pid}/cmdline" | sed -n 's/.*\/desktop=\([^, ]*\),.*/\1/p')"
  display="$(tr '\0' '\n' < "/proc/${explorer_pid}/environ" | sed -n 's/^DISPLAY=//p')"
  wine="$(studio_wine_bin)" || { echo "[desktop-resize] no Wine found to resize Studio's desktop with" >&2; return; }
  if [[ -z "${desktop}" || -z "${display}" ]]; then
    echo "[desktop-resize] could not read Studio's desktop name/DISPLAY from pid ${explorer_pid}" >&2
    return
  fi

  DISPLAY="${display}" WINEPREFIX="${STUDIO_WINEPREFIX}" WINEDEBUG=-all \
    "${wine}" explorer "/desktop=${desktop}" "${RESIZE_EXE}" "${size%x*}" "${size#*x}" >/dev/null 2>&1
  # The launcher returns before the tool finishes (~2s, see desktop-resize.c); wait so two
  # resizes never run at once.
  for _ in $(seq 1 50); do
    pgrep -f 'desktop-resize\.exe' >/dev/null || break
    sleep 0.2
  done
  echo "[desktop-resize] screen ${screen}: Studio's desktop resized to ${size}"
}

applied=""
while true; do
  screen="$(current_screen)"
  if [[ -n "${screen}" && "${screen}" != "${applied}" ]]; then
    # A browser window being dragged produces a burst of sizes; act on the one it settles on.
    sleep 0.8
    if [[ "$(current_screen)" == "${screen}" ]]; then
      apply "${screen}"
      applied="${screen}"
    fi
  fi
  sleep 0.5
done
