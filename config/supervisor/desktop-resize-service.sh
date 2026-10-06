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
STATUS_FILE=/tmp/desktop-resize.status
STATUS_FILE_WIN='Z:\tmp\desktop-resize.status'

current_screen() {
  wlr-randr --output HEADLESS-1 2>/dev/null | sed -n 's/^[[:space:]]*\([0-9]\+x[0-9]\+\) px.*(current).*/\1/p' | head -n1
}

# Studio's desktop, if it's up: Vinegar launches it as `explorer /desktop=<uuid>,WxH`
# (our own `explorer /desktop=<uuid> <program>` launches below have no `,` and don't match).
studio_desktop_pid() {
  pgrep -f 'explorer\.exe /desktop=[^,]+,' | head -n1
}

# Resizes the running desktop (pid $2) to SIZE ($1) from inside it.
resize_studio_desktop() {
  local size="$1" pid="$2" desktop display wine
  desktop="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n 's/.*\/desktop=\([^, ]*\),.*/\1/p')"
  display="$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p')"
  if [[ -z "${desktop}" || -z "${display}" ]]; then
    echo "[desktop-resize] could not read Studio's desktop name/DISPLAY from pid ${pid}" >&2
    return 1
  fi
  wine="$(studio_wine_bin)" || { echo "[desktop-resize] no Wine found to resize Studio's desktop with" >&2; return 1; }

  rm -f "${STATUS_FILE}"
  DISPLAY="${display}" WINEPREFIX="${STUDIO_WINEPREFIX}" WINEDEBUG=-all \
    "${wine}" explorer "/desktop=${desktop}" "${RESIZE_EXE}" "${size%x*}" "${size#*x}" "${STATUS_FILE_WIN}" >/dev/null 2>&1
  # The launcher returns before the tool finishes (a few seconds, see desktop-resize.c), and
  # doesn't pass its exit status on - the tool reports through the status file instead.
  for _ in $(seq 1 75); do
    [[ -s "${STATUS_FILE}" ]] && break
    sleep 0.2
  done
  case "$(cat "${STATUS_FILE}" 2>/dev/null)" in
    ok) echo "[desktop-resize] Studio's desktop resized to ${size}" ;;
    refused) echo "[desktop-resize] Wine refused a ${size} desktop - Explorer\\Desktops \"Default\" probably isn't ${size}" >&2; return 1 ;;
    *) echo "[desktop-resize] desktop-resize.exe didn't report back within 15s (resizing to ${size})" >&2; return 1 ;;
  esac
}

applied_screen=""   # screen size Vinegar's config (and, once it exists, the prefix) was set for
applied_desktop=""  # Studio desktop pid last resized to it
default_pending=0   # the prefix didn't exist yet when the screen size was applied
seen_desktop=""     # Studio desktop pid first seen at seen_at - left alone while it starts up
seen_at=0
while true; do
  screen="$(current_screen)"
  desktop_pid="$(studio_desktop_pid)"
  if [[ "${desktop_pid}" != "${seen_desktop}" ]]; then
    seen_desktop="${desktop_pid}"
    seen_at="${SECONDS}"
  fi

  if [[ -n "${screen}" && "${screen}" != "${applied_screen}" ]]; then
    # A browser window being dragged produces a burst of sizes; act on the one it settles on.
    sleep 0.8
    [[ "$(current_screen)" == "${screen}" ]] || continue
    applied_screen="${screen}"
    applied_desktop=""
    if size="$(desktop_size_for_screen "${screen}")" && virtual_desktop_enabled; then
      set_vinegar_desktop_size "${size}"
      default_pending=1
      echo "[desktop-resize] screen ${screen}: Studio's desktop should be ${size}"
    else
      echo "[desktop-resize] screen ${screen}: too small for Studio, or virtual_desktop is off - leaving the desktop as it is"
      size=""
      default_pending=0
    fi
  fi

  if [[ -n "${size:-}" ]]; then
    if (( default_pending )); then
      set_wine_default_desktop_size "${size}"
      case $? in
        0) default_pending=0 ;;
        2) ;;  # no prefix yet - Vinegar creates it on first launch; retried every pass
        *) echo "[desktop-resize] could not set Wine's default desktop size to ${size}" >&2; default_pending=0 ;;
      esac
    fi
    # A desktop that is simply new gets resized too, not only one that was already up when
    # the screen changed - it may have come up before its prefix had the right "Default" (a
    # fresh install's first launch creates the prefix and the desktop back to back, or a
    # prefix was recreated), so "Default" is written first, through the now-running wineserver.
    if [[ -n "${desktop_pid}" && "${desktop_pid}" != "${applied_desktop}" ]] \
       && (( SECONDS - seen_at >= 3 )); then
      set_wine_default_desktop_size "${size}" && default_pending=0
      resize_studio_desktop "${size}" "${desktop_pid}"
      applied_desktop="${desktop_pid}"
    fi
  fi
  sleep 0.5
done
