#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/root}"
export XDG_RUNTIME_DIR="/tmp/xdg-runtime"
# `docker restart` (including the automatic restart from `restart: unless-stopped`)
# reuses the same container writable layer — /tmp is NOT wiped between restarts, only
# the process/PID namespace is fresh. If labwc previously died (crash, OOM, a GPU
# driver hiccup — anything), a stale wayland-N socket/.lock file from that old process
# is still sitting here. The socket-detection loop below finds *a* file matching
# `wayland-*` and declares the compositor up without checking it's actually backed by a
# live server — a stale file satisfies that check instantly, before the new labwc has
# created its own socket, so wlr-randr/wayvnc immediately fail to connect and the
# container crash-loops forever (every restart re-finds the same stale file in ~0.2s).
# Wipe it on every start so only a genuinely fresh labwc's socket can be found here.
rm -rf "${XDG_RUNTIME_DIR}"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER="${WLR_RENDERER:-gles2}"

VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_BIND_ALIAS="${VNC_BIND_ALIAS:-}"

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

# VNC_BIND_ALIAS lets wayvnc bind to one specific Docker network's IP instead of every
# attached network at once — groundwork for a future code-docker integration where this
# container sits on two networks (one for a future MCP bridge, one dedicated to VNC and
# shared only with a router-like container) and VNC must be unreachable from the other.
# Fails closed (exit 1) rather than silently falling back to 0.0.0.0 on resolution
# failure — a silent fallback would quietly defeat the whole point of this variable. See
# CLAUDE.md's "VNC_BIND_ALIAS" section and poc/code-docker-integration/ for the validated
# reference setup. Unset (the default) reproduces today's exact 0.0.0.0 behavior.
VNC_BIND_ADDR="0.0.0.0"
if [[ -n "${VNC_BIND_ALIAS}" ]]; then
  echo "[entrypoint] VNC_BIND_ALIAS=${VNC_BIND_ALIAS} set — resolving to bind wayvnc there instead of 0.0.0.0"
  RESOLVED=""
  for _ in $(seq 1 25); do
    RESOLVED="$(getent hosts "${VNC_BIND_ALIAS}" 2>/dev/null | awk '{print $1; exit}')"
    [[ -n "${RESOLVED}" ]] && break
    sleep 0.2
  done
  if [[ -z "${RESOLVED}" ]]; then
    echo "[entrypoint] FATAL: VNC_BIND_ALIAS=${VNC_BIND_ALIAS} did not resolve via 'getent hosts' — refusing to silently fall back to 0.0.0.0, since that would defeat the network segmentation this variable exists for. Check that this container is actually attached to the network that defines this alias." >&2
    exit 1
  fi
  VNC_BIND_ADDR="${RESOLVED}"
  echo "[entrypoint] binding wayvnc to ${VNC_BIND_ADDR} (resolved from ${VNC_BIND_ALIAS})"
fi

WAYVNC_ARGS=(--output=HEADLESS-1 "${VNC_BIND_ADDR}" "${VNC_PORT}")
if [[ -n "${VNC_PASSWORD}" ]]; then
  WAYVNC_CFG="/tmp/wayvnc.cfg"

  # wayvnc can advertise multiple RFB security types at once and let each client pick
  # whichever it supports, rather than only one — so generate credentials for both
  # RSA-AES (wayvnc's own default scheme; TigerVNC's vncviewer speaks it natively) and
  # VeNCrypt/TLS (a self-signed cert — much more broadly supported, e.g. by Remmina,
  # which doesn't implement RSA-AES and fails with "unknown authentication scheme"
  # against it alone). Persisted under /root/.config/wayvnc (./data/wayvnc volume) so
  # the RSA-AES TOFU fingerprint and TLS cert stay stable across restarts — regenerating
  # them every start would trip every client's "host key changed" warning each time.
  WAYVNC_KEYDIR="${HOME}/.config/wayvnc"
  mkdir -p "${WAYVNC_KEYDIR}"
  RSA_KEY="${WAYVNC_KEYDIR}/rsa_key.pem"
  TLS_KEY="${WAYVNC_KEYDIR}/tls_key.pem"
  TLS_CERT="${WAYVNC_KEYDIR}/tls_cert.pem"
  [[ -f "${RSA_KEY}" ]] || ssh-keygen -m pem -f "${RSA_KEY}" -t rsa -N "" -q
  if [[ ! -f "${TLS_KEY}" || ! -f "${TLS_CERT}" ]]; then
    openssl req -x509 -newkey rsa:2048 -keyout "${TLS_KEY}" -out "${TLS_CERT}" \
      -days 3650 -nodes -subj "/CN=roblox-studio" 2>/dev/null
  fi
  chmod 600 "${RSA_KEY}" "${TLS_KEY}"

  {
    echo "enable_auth=true"
    echo "username=studio"
    echo "password=${VNC_PASSWORD}"
    echo "rsa_private_key_file=${RSA_KEY}"
    echo "private_key_file=${TLS_KEY}"
    echo "certificate_file=${TLS_CERT}"
  } > "${WAYVNC_CFG}"
  chmod 600 "${WAYVNC_CFG}"
  WAYVNC_ARGS=(-C "${WAYVNC_CFG}" "${WAYVNC_ARGS[@]}")
else
  echo "[entrypoint] WARNING: VNC_PASSWORD not set — running wayvnc with no authentication"
fi

echo "[entrypoint] starting wayvnc on port ${VNC_PORT}"
wayvnc "${WAYVNC_ARGS[@]}" &
VNC_PID=$!

# Studio MCP bridge (mcp-bridge.sh) — auto-started whenever MCP_TOKEN is set (matches
# the pattern above: VNC_PASSWORD gates wayvnc's auth, MCP_TOKEN gates this). Unlike
# Vinegar/Studio, nothing here strictly requires Studio to already be running —
# supergateway/caddy come up regardless, and Studio's plugin just connects whenever
# Studio itself is later launched — so there's no reason to keep this manual once a
# token is configured. Deliberately NOT included in the `wait -n` set below: a crash in
# the bridge (which self-restarts internally anyway, see mcp-bridge.sh) should never take
# down labwc/wayvnc/Studio. Still reaped correctly on container shutdown via the `trap
# cleanup EXIT` at the top of this script, which kills every backgrounded job including
# this one. See SETUP.md's "Studio MCP over the network" section.
if [[ -n "${MCP_TOKEN:-}" ]]; then
  echo "[entrypoint] MCP_TOKEN is set — starting the Studio MCP bridge in the background"
  /usr/local/bin/mcp-bridge.sh > /tmp/mcp-bridge.log 2>&1 &
else
  echo "[entrypoint] MCP_TOKEN not set — Studio MCP bridge not started (see SETUP.md's 'Studio MCP over the network' section)"
fi

wait -n "${WM_PID}" "${VNC_PID}" "${DBUS_PID}"
