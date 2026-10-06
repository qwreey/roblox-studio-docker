#!/usr/bin/env bash
set -euo pipefail

# Builds StudioSync.rbxm: Rojo's own plugin, unmodified, at ROJO_REF, with its UI entry
# point (plugin/src/init.server.lua) swapped for StudioSync.server.lua. Nothing of Rojo's
# is patched, so following a Rojo release is changing ROJO_REF. The plugin talks to
# whatever `rojo serve` a project pins as long as the protocol matches: 4 for Rojo
# 7.0-7.6, 5 from 7.7.0 (WebSocket transport).
#
# Usage: build.sh [output.rbxm]   (needs git, python3 and a rojo binary on PATH)

ROJO_REF="${ROJO_REF:-v7.7.1}"
here="$(cd "$(dirname "$0")" && pwd)"
out="$(realpath -m "${1:-${here}/StudioSync.rbxm}")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${ROJO_REF}" --recurse-submodules --shallow-submodules \
  https://github.com/rojo-rbx/rojo.git "${work}/rojo"

# Without init.server.lua, plugin/src becomes a plain Folder of modules; StudioSync is
# added beside it. The root keeps the name "Rojo", which Rojo's modules look up.
rm "${work}/rojo/plugin/src/init.server.lua"
cp "${here}/StudioSync.server.lua" "${work}/rojo/StudioSync.server.lua"
python3 - "${work}/rojo/plugin.project.json" <<'EOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    project = json.load(f)
project["tree"]["StudioSync"] = {"$path": "StudioSync.server.lua"}
with open(path, "w") as f:
    json.dump(project, f, indent=2)
EOF

(cd "${work}/rojo" && rojo build plugin.project.json -o "${out}")
echo "built ${out} from Rojo ${ROJO_REF}"
