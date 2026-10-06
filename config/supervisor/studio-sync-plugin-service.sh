#!/usr/bin/env bash
set -u

# Puts studio-sync's plugin (built into the image, see the Dockerfile and
# config/studio-sync/) into Studio's local Plugins folder, or takes it out again.
# STUDIO_SYNC_PLUGIN is on only in the code-docker overlay: the plugin polls
# code-docker:34880, which doesn't exist standalone.
#
# Runs once per boot. Studio loads local plugins when it starts, so a plugin installed or
# updated while Studio is running takes effect on Studio's next start.

. /etc/roblox-studio/studio-wine.sh

BUNDLED=/usr/local/lib/roblox-studio/StudioSync.rbxm
ROBLOX_DIR="${STUDIO_WINEPREFIX}/drive_c/users/$(id -un)/AppData/Local/Roblox"
TARGET="${ROBLOX_DIR}/Plugins/StudioSync.rbxm"

if [[ "${STUDIO_SYNC_PLUGIN:-false}" != "true" ]]; then
  if [[ -f "${TARGET}" ]]; then
    rm -f "${TARGET}"
    echo "[studio-sync-plugin] STUDIO_SYNC_PLUGIN is off - removed ${TARGET}"
  fi
  exit 0
fi

# Vinegar creates the prefix, and Studio its Roblox folder, on the first launch - which
# can be long after boot on a fresh install.
if [[ ! -d "${ROBLOX_DIR}" ]]; then
  echo "[studio-sync-plugin] waiting for Studio's first launch to create ${ROBLOX_DIR}"
  until [[ -d "${ROBLOX_DIR}" ]]; do sleep 10; done
fi

if cmp -s "${BUNDLED}" "${TARGET}"; then
  echo "[studio-sync-plugin] ${TARGET} is up to date"
  exit 0
fi
mkdir -p "$(dirname "${TARGET}")"
cp "${BUNDLED}" "${TARGET}"
echo "[studio-sync-plugin] installed ${TARGET} - a running Studio picks it up when it next starts"
