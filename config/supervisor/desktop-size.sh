# Shared helpers, sourced (not exec'd) by entrypoint.sh and desktop-resize-service.sh -
# everything about sizing Studio's Wine virtual desktop to the screen labwc shows. Why the
# desktop exists and why it is sized this way: CLAUDE.md's "Panels: Wine virtual desktop".

STUDIO_WINEPREFIX="${HOME:-/root}/.local/share/vinegar/prefixes/studio"
VINEGAR_CONFIG="${HOME:-/root}/.config/vinegar/config.toml"
DESKTOPS_KEY='[Software\\Wine\\Explorer\\Desktops]'

# Prints the virtual-desktop size for a screen of WxH: the screen minus waybar, which sits
# below the desktop rather than over it (a desktop the screen's exact size makes Wine go
# fullscreen and cover waybar). waybar's height comes from its own config so the two can't
# drift apart. Fails for a malformed size or one too small to be worth resizing Studio to.
desktop_size_for_screen() {
  local screen="$1" taskbar_height
  [[ "${screen}" =~ ^([0-9]+)x([0-9]+)$ ]] || return 1
  local width="${BASH_REMATCH[1]}" height="${BASH_REMATCH[2]}"
  taskbar_height="$(sed -n 's/^[[:space:]]*"height":[[:space:]]*\([0-9]\+\).*/\1/p' /etc/xdg/labwc/waybar-config.jsonc)"
  [[ -n "${taskbar_height}" ]] || return 1
  (( width >= 640 && height - taskbar_height >= 400 )) || return 1
  echo "${width}x$(( height - taskbar_height ))"
}

# True when Vinegar's config has a non-empty virtual_desktop - an empty value is Vinegar's
# own "off", and an owner who turned it off gets nothing resized behind their back.
virtual_desktop_enabled() {
  grep -q '^virtual_desktop[[:space:]]*=[[:space:]]*"[^"]\+"' "${VINEGAR_CONFIG}" 2>/dev/null
}

# Points Vinegar's next launch (`explorer /desktop=<uuid>,WxH`) at SIZE.
set_vinegar_desktop_size() {
  sed -i "s/^virtual_desktop[[:space:]]*=[[:space:]]*\"[^\"]\+\".*/virtual_desktop = \"$1\"/" "${VINEGAR_CONFIG}"
}

# The same Wine Vinegar launches Studio with - its config's wineroot, else the Kombucha
# build Vinegar manages itself. Mirrors config/mcp/studio-mcp-stdio.sh.
studio_wine_bin() {
  local wineroot
  wineroot="$(sed -n 's/^[[:space:]]*wineroot[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "${VINEGAR_CONFIG}" 2>/dev/null | tail -n1)"
  if [[ -n "${wineroot}" && -x "${wineroot}/bin/wine" ]]; then
    echo "${wineroot}/bin/wine"
  elif [[ -x "${HOME:-/root}/.local/share/vinegar/kombucha/bin/wine" ]]; then
    echo "${HOME:-/root}/.local/share/vinegar/kombucha/bin/wine"
  else
    return 1
  fi
}

# Sets HKCU\Software\Wine\Explorer\Desktops "Default" to SIZE in Studio's prefix - Wine
# only accepts a virtual-desktop size from a fixed list of standard resolutions plus this
# value, and silently stays at the screen size (fullscreen) otherwise. Through `wine reg`
# while the prefix's wineserver runs; as text otherwise, since `wine reg` would start Wine
# itself (and on a fresh Kombucha, update the prefix) outside Vinegar's control. A later
# section of a key overrides an earlier one when Wine loads user.reg, and Wine rewrites the
# file as one section on its next save, so the text path only ever appends.
set_wine_default_desktop_size() {
  local size="$1" user_reg="${STUDIO_WINEPREFIX}/user.reg" wine current
  [[ -f "${user_reg}" ]] || return 0
  if pgrep -x wineserver >/dev/null; then
    wine="$(studio_wine_bin)" || return 1
    WINEPREFIX="${STUDIO_WINEPREFIX}" WINEDEBUG=-all "${wine}" reg add \
      'HKCU\Software\Wine\Explorer\Desktops' /v Default /d "${size}" /f >/dev/null 2>&1
    return
  fi
  current="$(DESKTOPS_KEY="${DESKTOPS_KEY}" awk '
    BEGIN { key = ENVIRON["DESKTOPS_KEY"] }
    /^\[/ { in_key = ($0 == key || index($0, key " ") == 1); next }
    in_key && /^"Default"=/ { value = $0 }
    END { print value }
  ' "${user_reg}")"
  [[ "${current}" == "\"Default\"=\"${size}\"" ]] && return 0
  printf '\n%s\n"Default"="%s"\n' "${DESKTOPS_KEY}" "${size}" >> "${user_reg}"
}
