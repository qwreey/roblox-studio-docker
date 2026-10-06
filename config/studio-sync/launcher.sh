#!/bin/sh
# Mounted at /usr/local/bin/studio-sync in code-docker. The real CLI comes in through a
# directory mount, so a pull of this repo reaches code-docker without recreating it - a
# file bind mount would keep pointing at the old file once git replaced it.
exec python3 /usr/local/lib/studio-sync/studio-sync "$@"
