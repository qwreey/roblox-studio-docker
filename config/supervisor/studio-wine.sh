# Shared helpers, sourced (not exec'd) by anything that runs Wine in Studio's prefix -
# desktop-size.sh and config/mcp/studio-mcp-stdio.sh.

STUDIO_WINEPREFIX="${HOME:-/root}/.local/share/vinegar/prefixes/studio"
VINEGAR_CONFIG="${HOME:-/root}/.config/vinegar/config.toml"

# Prints the Wine Vinegar launches Studio with, which is the one anything else touching its
# prefix has to use: config.toml's wineroot when set (the Dockerfile's pinned Kombucha),
# else the Kombucha build Vinegar downloads and manages itself. A hardcoded path here went
# stale once already - when the pin landed, studio-mcp-stdio.sh kept using the old one and
# failed with `exec: wine: not found`.
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
