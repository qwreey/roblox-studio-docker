#!/bin/sh
# Mounted at /usr/local/bin/studio-analysis in code-docker; see config/studio-sync/launcher.sh
# for why the real CLI comes in through a directory mount instead.
exec python3 /usr/local/lib/studio-analysis/studio-analysis "$@"
