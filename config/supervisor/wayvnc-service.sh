#!/usr/bin/env bash
set -eu

. /etc/roblox-studio/wait-for-wayland.sh
wait_for_wayland_socket

VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_BIND_ALIAS="${VNC_BIND_ALIAS:-}"
VNC_GPU="${VNC_GPU:-}"

# VNC_BIND_ALIAS lets wayvnc bind to one specific Docker network's IP instead of every
# attached network at once - groundwork for a future code-docker integration where this
# container sits on two networks (one for a future MCP bridge, one dedicated to VNC and
# shared only with a router-like container) and VNC must be unreachable from the other.
# Fails closed (exit 1, via `set -e` below) rather than silently falling back to
# 0.0.0.0 - a silent fallback would quietly defeat the whole point of this variable. See
# CLAUDE.md's "VNC_BIND_ALIAS" section and poc/code-docker-integration/ for the validated
# reference setup. Unset (the default) reproduces today's exact 0.0.0.0 behavior.
VNC_BIND_ADDR="0.0.0.0"
if [[ -n "${VNC_BIND_ALIAS}" ]]; then
  echo "[wayvnc-service] VNC_BIND_ALIAS=${VNC_BIND_ALIAS} set — resolving to bind wayvnc there instead of 0.0.0.0"
  RESOLVED=""
  for _ in $(seq 1 25); do
    RESOLVED="$(getent hosts "${VNC_BIND_ALIAS}" 2>/dev/null | awk '{print $1; exit}')"
    [[ -n "${RESOLVED}" ]] && break
    sleep 0.2
  done
  if [[ -z "${RESOLVED}" ]]; then
    echo "[wayvnc-service] FATAL: VNC_BIND_ALIAS=${VNC_BIND_ALIAS} did not resolve via 'getent hosts' — refusing to silently fall back to 0.0.0.0, since that would defeat the network segmentation this variable exists for. Check that this container is actually attached to the network that defines this alias." >&2
    exit 1
  fi
  VNC_BIND_ADDR="${RESOLVED}"
  echo "[wayvnc-service] binding wayvnc to ${VNC_BIND_ADDR} (resolved from ${VNC_BIND_ALIAS})"
fi

WAYVNC_ARGS=(--output=HEADLESS-1 "${VNC_BIND_ADDR}" "${VNC_PORT}")

# VNC_GPU turns on wayvnc's own --gpu ("enable features that need GPU"): DMA-BUF capture
# and hardware H.264 encoding through VAAPI. It is off by default, and that default is a
# measurement rather than caution about /dev/dri (which this container has had passed
# through all along, and which labwc already renders on):
#
#   - --gpu's H.264 is only used for a client that negotiates the open-h264 RFB encoding.
#     For a native client that means the client must implement it; for the noVNC path it
#     means noVNC's WebCodecs H.264 support, which needs (1) a secure context - over plain
#     HTTP `VideoDecoder` doesn't exist at all, so noVNC never even offers H.264, and
#     (2) a browser that can actually decode noVNC's own probe frame.
#   - Measured 2026-08-25 on this host (AMD HawkPoint/amdgpu, radeonsi VAAPI present,
#     neatvnc linked against libavcodec+libva - i.e. the encoder side is genuinely there):
#     even from a secure context, Chrome 151 failed that probe on the hardware decoder
#     (`prefer-software` decoded the same frame fine), so noVNC disabled H.264 and wayvnc
#     logged `Choosing tight encoding` with --gpu on. No crash, no visible difference -
#     just no benefit.
#
# So: harmless to turn on, worth trying from a different browser/GPU, but not something to
# default to as if it were free. wayvnc itself is unchanged in every other respect.
case "${VNC_GPU}" in
  1|true|TRUE|yes|YES|on|ON)
    echo "[wayvnc-service] VNC_GPU=${VNC_GPU} — enabling wayvnc --gpu (DMA-BUF capture + VAAPI H.264; only actually used if the client negotiates H.264)"
    WAYVNC_ARGS=(--gpu "${WAYVNC_ARGS[@]}")
    ;;
  ''|0|false|FALSE|no|NO|off|OFF) ;;
  *)
    echo "[wayvnc-service] WARNING: VNC_GPU=${VNC_GPU} is not a recognized boolean — treating it as off" >&2
    ;;
esac

if [[ -n "${VNC_PASSWORD}" ]]; then
  WAYVNC_CFG="/tmp/wayvnc.cfg"

  # wayvnc can advertise multiple RFB security types at once and let each client pick
  # whichever it supports, rather than only one - so generate credentials for both
  # RSA-AES (wayvnc's own default scheme; TigerVNC's vncviewer speaks it natively) and
  # VeNCrypt/TLS (a self-signed cert - much more broadly supported, e.g. by Remmina,
  # which doesn't implement RSA-AES). Persisted under /root/.config/wayvnc
  # (./data/wayvnc volume) so the RSA-AES TOFU fingerprint and TLS cert stay stable
  # across restarts - regenerating them every start would trip every client's "host key
  # changed" warning each time.
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
  echo "[wayvnc-service] WARNING: VNC_PASSWORD not set — running wayvnc with no authentication"
fi

echo "[wayvnc-service] starting wayvnc on port ${VNC_PORT}"
exec wayvnc "${WAYVNC_ARGS[@]}"
