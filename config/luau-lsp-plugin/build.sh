#!/usr/bin/env bash
set -euo pipefail

# Builds LuauLSP.rbxm: luau-lsp's own Studio plugin at LUAU_LSP_REF with
# studio-defaults.patch applied - default host roblox-studio-front (Studio's way to code-docker,
# where VS Code's luau-lsp extension listens on 3667), startAutomatically on, and a retry
# every 10 s while not connected, since the language server only exists while a VS Code
# window is open. `--fuzz=0`: a release that moves this code fails the build instead of
# being patched somewhere unexpected. LUAU_LSP_REF should match the luau-lsp extension
# installed in code-server, which speaks the same endpoints.
#
# Usage: build.sh [output.rbxm]   (needs git, patch and a rojo binary on PATH)

LUAU_LSP_REF="${LUAU_LSP_REF:-1.70.1}"
here="$(cd "$(dirname "$0")" && pwd)"
out="$(realpath -m "${1:-${here}/LuauLSP.rbxm}")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${LUAU_LSP_REF}" \
  https://github.com/JohnnyMorganz/luau-lsp.git "${work}/luau-lsp"
patch --quiet --fuzz=0 -p1 -d "${work}/luau-lsp" < "${here}/studio-defaults.patch"
(cd "${work}/luau-lsp/plugin" && rojo build default.project.json -o "${out}")
echo "built ${out} from luau-lsp ${LUAU_LSP_REF}"
