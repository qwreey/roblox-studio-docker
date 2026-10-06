#!/usr/bin/env bash
set -u

# Puts the Studio plugins built into the image (see the Dockerfile) into Studio's local
# Plugins folder, or takes them out again. Both only make sense with code-docker, so their
# switches are on only in the code-docker overlay:
#
#   StudioSync.rbxm   STUDIO_SYNC_PLUGIN       studio-sync's Studio half (config/studio-sync/);
#                                              polls studio-front:34880
#   LuauLSP.rbxm      STUDIO_LUAU_LSP_PLUGIN   luau-lsp's companion plugin
#                                              (config/luau-lsp-plugin/); sends the DataModel
#                                              to studio-front:3667
#
# Runs once per boot. Studio loads local plugins when it starts, so a plugin installed or
# updated while Studio is running takes effect on Studio's next start.

. /etc/roblox-studio/studio-wine.sh

BUNDLED_DIR=/usr/local/lib/roblox-studio
ROBLOX_DIR="${STUDIO_WINEPREFIX}/drive_c/users/$(id -un)/AppData/Local/Roblox"
PLUGINS_DIR="${ROBLOX_DIR}/Plugins"

# Prints install, remove or keep for a switch's value.
decide() {
  case "$2" in
    1|true|TRUE|yes|YES|on|ON) echo install ;;
    ''|0|false|FALSE|no|NO|off|OFF) echo remove ;;
    *)
      # Neither installed nor removed: a typo shouldn't delete a plugin someone relies on.
      echo "[studio-plugins] WARNING: $1=$2 is not a recognized boolean - leaving that plugin as it is" >&2
      echo keep
      ;;
  esac
}

failed=0
waited=0
for entry in "StudioSync.rbxm:STUDIO_SYNC_PLUGIN" "LuauLSP.rbxm:STUDIO_LUAU_LSP_PLUGIN"; do
  file="${entry%%:*}" switch="${entry#*:}"
  target="${PLUGINS_DIR}/${file}"
  case "$(decide "${switch}" "${!switch:-false}")" in
    remove)
      if [[ -f "${target}" ]]; then
        rm -f "${target}" || { failed=1; continue; }
        echo "[studio-plugins] ${switch} is off - removed ${target}"
      fi
      ;;
    install)
      # Vinegar creates the prefix, and Studio its Roblox folder, on the first launch -
      # which can be long after boot on a fresh install.
      if [[ ! -d "${ROBLOX_DIR}" && "${waited}" -eq 0 ]]; then
        echo "[studio-plugins] waiting for Studio's first launch to create ${ROBLOX_DIR}"
        until [[ -d "${ROBLOX_DIR}" ]]; do sleep 10; done
      fi
      waited=1
      if cmp -s "${BUNDLED_DIR}/${file}" "${target}"; then
        echo "[studio-plugins] ${target} is up to date"
      elif mkdir -p "${PLUGINS_DIR}" && cp "${BUNDLED_DIR}/${file}" "${target}"; then
        echo "[studio-plugins] installed ${target} - takes effect when Studio next starts"
      else
        echo "[studio-plugins] could not install ${target}" >&2
        failed=1
      fi
      ;;
  esac
done
exit "${failed}"
