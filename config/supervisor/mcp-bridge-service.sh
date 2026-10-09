#!/usr/bin/env bash
set -u

# MCP_TOKEN gates the whole bridge (matches the pattern VNC_PASSWORD/wayvnc uses) - but
# unlike the old entrypoint.sh, which only backgrounded mcp-bridge.sh at all when
# MCP_TOKEN was set, supervisord expects every declared program to exist and be
# startable. So when the token is unset, idle instead of exiting - matches this
# codebase's own dns-local.default.sh idiom in code-docker for an intentionally-disabled
# feature (log once, sleep in a loop) rather than looping through supervisord's
# startretries/FATAL backoff for a condition that isn't actually a failure.
if [[ -z "${MCP_TOKEN:-}" ]]; then
  echo "[mcp-bridge-service] MCP_TOKEN not set — idling (see SETUP.md's 'Studio MCP over the network' section)"
  trap 'echo "[mcp-bridge-service] stopping (idle)"; exit 0' TERM INT
  # In the background and waited on: bash runs a trap only once the foreground command
  # returns, which for a plain `sleep 3600` is up to an hour after supervisord asked.
  while true; do sleep 3600 & wait $!; done
fi

# mcp-bridge.sh has its own internal restart loop (respawns supergateway/caddy on
# crash) and its own TERM/INT trap - exec here just avoids leaving a redundant wrapper
# shell between supervisord and it.
exec /usr/local/bin/mcp-bridge.sh
