#!/usr/bin/env bash
set -eu

VNC_PORT="${VNC_PORT:-5900}"
VNC_WEB_PORT="${VNC_WEB_PORT:-6080}"
VNC_BIND_ALIAS="${VNC_BIND_ALIAS:-}"

# websockify runs in this same container and speaks to wayvnc over plain TCP - resolve
# the same address wayvnc itself bound to (see wayvnc-service.sh), never hardcode
# "localhost": wayvnc only listens on the resolved VNC_BIND_ALIAS IP when that's set, not
# on loopback, so a "localhost" target would silently fail to connect in that case.
VNC_TARGET_HOST="localhost"
if [[ -n "${VNC_BIND_ALIAS}" ]]; then
  VNC_TARGET_HOST="${VNC_BIND_ALIAS}"
fi

# The noVNC web UI must be exposed under the same restriction wayvnc's raw RFB port is -
# otherwise it becomes a second, unrestricted path to the same VNC session, defeating
# VNC_BIND_ALIAS's whole point (see wayvnc-service.sh's own comment and CLAUDE.md's
# "VNC_BIND_ALIAS" section). Same fail-closed resolve-or-exit behavior, not a silent
# 0.0.0.0 fallback.
VNC_WEB_BIND_ADDR="0.0.0.0"
if [[ -n "${VNC_BIND_ALIAS}" ]]; then
  echo "[novnc-service] VNC_BIND_ALIAS=${VNC_BIND_ALIAS} set — resolving to bind the noVNC web UI there instead of 0.0.0.0"
  RESOLVED=""
  for _ in $(seq 1 25); do
    RESOLVED="$(getent hosts "${VNC_BIND_ALIAS}" 2>/dev/null | awk '{print $1; exit}')"
    [[ -n "${RESOLVED}" ]] && break
    sleep 0.2
  done
  if [[ -z "${RESOLVED}" ]]; then
    echo "[novnc-service] FATAL: VNC_BIND_ALIAS=${VNC_BIND_ALIAS} did not resolve via 'getent hosts' — refusing to silently fall back to 0.0.0.0. Check that this container is actually attached to the network that defines this alias." >&2
    exit 1
  fi
  VNC_WEB_BIND_ADDR="${RESOLVED}"
  echo "[novnc-service] binding noVNC web UI to ${VNC_WEB_BIND_ADDR} (resolved from ${VNC_BIND_ALIAS})"
fi

# wayvnc (priority=30, this program is priority=35 - see novnc.conf) can take a moment
# after supervisord starts it to actually bind its listening socket. Poll instead of
# racing it - a connection-refused websockify start would just exit and, per
# critical-watchdog's design, bring the whole container down needlessly.
echo "[novnc-service] waiting for wayvnc to accept connections on ${VNC_TARGET_HOST}:${VNC_PORT}"
for _ in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/${VNC_TARGET_HOST}/${VNC_PORT}") 2>/dev/null; then
    exec 3<&- 3>&-
    break
  fi
  sleep 0.2
done

echo "[novnc-service] starting websockify on ${VNC_WEB_BIND_ADDR}:${VNC_WEB_PORT} -> ${VNC_TARGET_HOST}:${VNC_PORT}"
exec /opt/websockify/run --web /opt/novnc "${VNC_WEB_BIND_ADDR}:${VNC_WEB_PORT}" "${VNC_TARGET_HOST}:${VNC_PORT}"
