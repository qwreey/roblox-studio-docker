#!/usr/bin/env bash
set -u

# Keeps one StudioMCP.exe running for as long as the container is up, with no MCP client
# of its own. The bridge (mcp-bridge.sh) starts a StudioMCP.exe per client session, and
# whichever of them binds 127.0.0.1:13469 first is the one Studio connects to; the rest
# reach Studio through it. Without a long-lived one, nothing listened between sessions:
# Studio showed "no client", and a new session's first `list_roblox_studios` came back
# empty because Studio only retries every 3 s and hadn't reconnected yet - agents took
# that as "no place is open" and stopped. With this one holding the port, Studio stays
# connected and every session sees it from its first call.

if [[ -z "${MCP_TOKEN:-}" ]]; then
  echo "[studio-mcp-host] MCP_TOKEN not set - the bridge is off, so idling"
  trap 'exit 0' TERM INT
  # In the background and waited on: bash runs a trap only once the foreground command
  # returns, which for a plain `sleep 3600` is up to an hour after supervisord asked.
  while true; do sleep 3600 & wait $!; done
fi

. /etc/roblox-studio/studio-wine.sh

newest_exe() {
  ls -td /root/.local/share/vinegar/versions/*/StudioMCP.exe 2>/dev/null | head -n1
}

# StudioMCP.exe serves MCP on stdin/stdout and exits at EOF on stdin. A FIFO this shell
# holds open read-write gives it a stdin that never ends and never sends anything.
STDIN_FIFO=/tmp/studio-mcp-host.stdin
rm -f "${STDIN_FIFO}"
mkfifo "${STDIN_FIFO}"
exec 3<>"${STDIN_FIFO}"

pid=""
trap '[[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null; exit 0' TERM INT

said_waiting=""
while true; do
  exe="$(newest_exe)"
  wine="$(studio_wine_bin)" || wine=""
  if [[ -z "${exe}" || -z "${wine}" ]]; then
    if [[ -z "${said_waiting}" ]]; then
      [[ -z "${exe}" ]] && echo "[studio-mcp-host] no StudioMCP.exe yet - it appears once Studio's Assistant > Manage MCP Servers > \"Enable Studio as MCP server\" has been turned on; checking every 30 s"
      [[ -z "${wine}" ]] && echo "[studio-mcp-host] no Wine to run StudioMCP.exe with yet - checking every 30 s"
      said_waiting=1
    fi
    sleep 30 &
    wait $!
    continue
  fi
  said_waiting=""

  echo "[studio-mcp-host] running ${exe}"
  # Its stdout is MCP traffic for a client it doesn't have; stderr goes to the log.
  WINEPREFIX="${STUDIO_WINEPREFIX}" "${wine}" "${exe}" <&3 >/dev/null &
  pid=$!
  # A Studio update installs a new StudioMCP.exe and Vinegar deletes the old version's
  # folder, so follow it rather than keep running the old one.
  while kill -0 "${pid}" 2>/dev/null; do
    sleep 10 &
    wait $!
    if [[ "$(newest_exe)" != "${exe}" ]]; then
      echo "[studio-mcp-host] Studio was updated - restarting StudioMCP.exe from the new version"
      kill "${pid}" 2>/dev/null
      break
    fi
  done
  wait "${pid}" 2>/dev/null
  echo "[studio-mcp-host] StudioMCP.exe exited (status $?) - starting it again in 5 s"
  pid=""
  sleep 5 &
  wait $!
done
