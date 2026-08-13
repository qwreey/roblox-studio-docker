#!/usr/bin/env bash
set -eu

# D-Bus session bus - required for xdg-desktop-portal (used by Vinegar's "Login via
# Browser" flow) and to avoid GTK apps warning about a missing machine-id.
if [[ ! -s /etc/machine-id ]]; then
  dbus-uuidgen > /etc/machine-id
fi

# --nofork keeps dbus-daemon in the foreground, so this script's own `exec` below hands
# it supervisord's SIGTERM/SIGINT directly - no wrapper shell left in between to swallow
# or need to forward the signal itself.
exec dbus-daemon --session --address="unix:path=${XDG_RUNTIME_DIR}/bus" --nofork --nopidfile
