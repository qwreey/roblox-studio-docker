#!/usr/bin/env bash
# poc/code-docker-integration/verify.sh
#
# Run after `docker compose up -d --build` from this directory. Produces clear
# PASS/FAIL output for the four properties the poc exists to validate. Exits non-zero
# if any check fails.
set -uo pipefail   # deliberately no -e: keep running through all checks and report all results
cd "$(dirname "${BASH_SOURCE[0]}")"

PASS_COUNT=0
FAIL_COUNT=0

report() {
  local ok="$1" desc="$2"
  if [[ "${ok}" == "0" ]]; then
    echo "[PASS] ${desc}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "[FAIL] ${desc}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- wait for wayvnc to actually be up before testing the "should succeed" case ---
# Docker's embedded DNS resolves aliases immediately at container start, but wayvnc
# itself only starts listening after labwc + wlr-randr + dbus have finished (a few
# seconds). Poll router-mock's own TCP check rather than sleeping blindly.
echo "waiting up to 30s for wayvnc to start accepting connections on the VNC-only network..."
WAYVNC_UP=1
for _ in $(seq 1 15); do
  if docker compose exec -T router-mock timeout 2 bash -c \
      'echo > /dev/tcp/roblox-studio-vnc/5900' >/dev/null 2>&1; then
    WAYVNC_UP=0
    break
  fi
  sleep 2
done
if [[ "${WAYVNC_UP}" != "0" ]]; then
  echo "wayvnc never came up — check 'docker compose logs roblox-studio' before trusting the checks below"
fi

# (a) DNS: the VNC-only alias must NOT resolve from code-docker-mock — it's not
#     attached to that network at all.
docker compose exec -T code-docker-mock getent hosts roblox-studio-vnc >/dev/null 2>&1
report "$([[ $? -ne 0 ]] && echo 0 || echo 1)" \
  "(a) code-docker-mock cannot resolve 'roblox-studio-vnc' (VNC-only alias) — DNS-level isolation"

# (b) TCP: even if a stale IP were hardcoded, nothing is listening on the internal
#     network's IP for wayvnc (it's bound only to the VNC-only-network IP) — connect via
#     the internal-network alias must fail.
docker compose exec -T code-docker-mock timeout 2 bash -c \
  'echo > /dev/tcp/roblox-studio/5900' >/dev/null 2>&1
report "$([[ $? -ne 0 ]] && echo 0 || echo 1)" \
  "(b) code-docker-mock cannot reach port 5900 via 'roblox-studio' (internal-network alias) — bind-address isolation"

# (c) TCP: router-mock, attached to the VNC-only network, must reach wayvnc there.
docker compose exec -T router-mock timeout 5 bash -c \
  'echo > /dev/tcp/roblox-studio-vnc/5900' >/dev/null 2>&1
report "$([[ $? -eq 0 ]] && echo 0 || echo 1)" \
  "(c) router-mock CAN reach port 5900 via 'roblox-studio-vnc' (VNC-only-network alias) — VNC reachable as intended"

# (d) Sanity: the internal network itself isn't broken — code-docker-mock can still
#     resolve roblox-studio's internal-network alias (no fake listener needed; any
#     future MCP listener bound there would be reachable the same way TCP was reachable
#     in (c), just on a different, currently-unused port).
docker compose exec -T code-docker-mock getent hosts roblox-studio >/dev/null 2>&1
report "$([[ $? -eq 0 ]] && echo 0 || echo 1)" \
  "(d) code-docker-mock CAN resolve 'roblox-studio' (internal-network alias) — internal network itself intact, isolation is VNC-specific, not total"

echo
echo "${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" == "0" ]]
