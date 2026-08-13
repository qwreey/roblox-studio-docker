# Shared helper, sourced (not exec'd) by any service script that needs labwc's Wayland
# socket - wayvnc-service.sh and labwc-service.sh's own post-start step both need this
# independently, since supervisord runs every program as its own process with no shared
# mutable state between them (unlike the single flat entrypoint.sh script this replaced).
#
# Kept generic (globs for any wayland-*, not hardcoded to labwc's current wayland-0) for
# the same sway-revert-flexibility reason entrypoint.sh's original detection loop existed
# - see CLAUDE.md's "Window manager: labwc, not sway" section. `docker restart` reuses
# the same writable layer, so a stale socket from a previous crashed run could otherwise
# satisfy this check instantly - entrypoint.sh wipes $XDG_RUNTIME_DIR on every start
# before supervisord ever spawns labwc, so only a genuinely live socket can be found here.
wait_for_wayland_socket() {
  local candidate socket
  for _ in $(seq 1 50); do
    candidate="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -n1)"
    if [[ -n "${candidate}" ]]; then
      socket="$(basename "${candidate}")"
      export WAYLAND_DISPLAY="${socket}"
      echo "[wait-for-wayland] WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
      return 0
    fi
    sleep 0.2
  done
  echo "[wait-for-wayland] labwc failed to create a Wayland socket after 10s" >&2
  return 1
}
