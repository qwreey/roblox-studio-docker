# Shared helpers, sourced (not exec'd) by entrypoint.sh and desktop-resize-service.sh -
# everything about sizing Studio's Wine virtual desktop to the screen labwc shows. Why the
# desktop exists and why it is sized this way: CLAUDE.md's "Panels: Wine virtual desktop".

. /etc/roblox-studio/studio-wine.sh
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

# Sets HKCU\Software\Wine\Explorer\Desktops "Default" to SIZE in Studio's prefix - Wine
# only accepts a virtual-desktop size from a fixed list of standard resolutions plus this
# value, and silently stays at the screen size (fullscreen) otherwise. Through `wine reg`
# while the prefix's wineserver runs; as text otherwise, since `wine reg` would start Wine
# itself (and on a fresh Kombucha, update the prefix) outside Vinegar's control. A later
# section of a key overrides an earlier one when Wine loads user.reg, and Wine rewrites the
# file as one section on its next save, so the text path only ever appends.
# Returns 2 when Vinegar hasn't created the prefix yet, 1 when writing failed.
set_wine_default_desktop_size() {
  local size="$1" user_reg="${STUDIO_WINEPREFIX}/user.reg" current
  [[ -f "${user_reg}" ]] || return 2
  if pgrep -x wineserver >/dev/null; then
    wine_reg_set_default_desktop_size "${size}"
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
  # A wineserver that started between the check above and the append has already loaded
  # user.reg without the new value, and will rewrite the file without it - tell it directly.
  if pgrep -x wineserver >/dev/null; then
    wine_reg_set_default_desktop_size "${size}"
  fi
}

wine_reg_set_default_desktop_size() {
  local wine
  wine="$(studio_wine_bin)" || return 1
  WINEPREFIX="${STUDIO_WINEPREFIX}" WINEDEBUG=-all "${wine}" reg add \
    'HKCU\Software\Wine\Explorer\Desktops' /v Default /d "$1" /f >/dev/null 2>&1
}
