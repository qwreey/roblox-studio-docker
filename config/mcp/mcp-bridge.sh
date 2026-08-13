#!/usr/bin/env bash
set -uo pipefail

# Exposes Roblox Studio's built-in MCP server (stdio-only, single-machine-only by
# design — see research/roblox-mcp.md) to remote MCP clients: supergateway wraps the
# stdio process as Streamable HTTP, Caddy adds bearer-token auth and is the only port
# actually published (see config/mcp/Caddyfile).
#
# Auto-started by entrypoint.sh whenever MCP_TOKEN is set (see entrypoint.sh's own
# comment on this) — unlike Vinegar/Studio, nothing here strictly requires Studio to
# already be running: supergateway/caddy come up regardless, and StudioMCP.exe just
# waits for Studio's Assistant plugin to connect whenever Studio itself is launched.
# Can still be run manually too (e.g. `docker exec -e MCP_TOKEN=... roblox-studio
# mcp-bridge.sh`) — see SETUP.md's "Studio MCP over the network" section.
#
# Self-restarting: the loop below respawns supergateway+caddy if either exits/crashes,
# rather than letting the whole script (and whatever's supervising it) die — deliberately
# NOT `set -e` for this reason, a single failed iteration should retry, not abort.

: "${MCP_TOKEN:?MCP_TOKEN must be set — the bearer token remote clients must send. Generate one with: openssl rand -hex 32}"

# Defaults to studio-mcp-stdio.sh, which resolves and launches StudioMCP.exe directly
# (see that script's own header comment for why it bypasses Studio's mcp.bat launcher).
# Override only if you have a good reason to point at something else.
STUDIO_MCP_STDIO_CMD="${STUDIO_MCP_STDIO_CMD:-/usr/local/bin/studio-mcp-stdio.sh}"

MCP_UPSTREAM_PORT="${MCP_UPSTREAM_PORT:-8808}"
MCP_PORT="${MCP_PORT:-8787}"
export MCP_TOKEN MCP_PORT MCP_UPSTREAM_PORT

STOP=0
SG_PID=""
CADDY_PID=""

shutdown() {
  STOP=1
  echo "[mcp-bridge] stopping (received signal)"
  [[ -n "${SG_PID}" ]] && kill "${SG_PID}" 2>/dev/null
  [[ -n "${CADDY_PID}" ]] && kill "${CADDY_PID}" 2>/dev/null
}
trap shutdown INT TERM

echo "[mcp-bridge] starting (self-restarting on crash — send SIGINT/SIGTERM to stop for real)"

while [[ "${STOP}" -eq 0 ]]; do
  echo "[mcp-bridge] starting supergateway (stdio -> Streamable HTTP) on 127.0.0.1:${MCP_UPSTREAM_PORT}"
  echo "[mcp-bridge]   wrapping: ${STUDIO_MCP_STDIO_CMD}"
  npx -y supergateway \
    --stdio "${STUDIO_MCP_STDIO_CMD}" \
    --outputTransport streamableHttp \
    --stateful \
    --port "${MCP_UPSTREAM_PORT}" \
    --healthEndpoint /healthz &
  SG_PID=$!

  echo "[mcp-bridge] starting caddy (bearer-token auth) on 0.0.0.0:${MCP_PORT} -> /mcp"
  caddy run --config /etc/mcp-bridge/Caddyfile --adapter caddyfile &
  CADDY_PID=$!

  wait -n "${SG_PID}" "${CADDY_PID}"

  [[ "${STOP}" -eq 1 ]] && break

  echo "[mcp-bridge] one of supergateway/caddy exited unexpectedly — restarting both in 2s"
  kill "${SG_PID}" "${CADDY_PID}" 2>/dev/null
  wait "${SG_PID}" 2>/dev/null
  wait "${CADDY_PID}" 2>/dev/null
  sleep 2
done

echo "[mcp-bridge] stopped"
