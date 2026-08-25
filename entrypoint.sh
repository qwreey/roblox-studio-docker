#!/usr/bin/env bash
set -euo pipefail

# Process supervision is supervisord's job from here on (config/supervisord.conf +
# config/supervisord.d/*.conf, see CLAUDE.md's "Process supervision: supervisord"
# section) - this script only does the setup that has to happen once, before
# supervisord spawns anything, and hands off via `exec` at the bottom.

export HOME="${HOME:-/root}"
export XDG_RUNTIME_DIR="/tmp/xdg-runtime"
# `docker restart` (including the automatic restart from `restart: unless-stopped`)
# reuses the same container writable layer - /tmp is NOT wiped between restarts, only
# the process/PID namespace is fresh. If labwc previously died (crash, OOM, a GPU
# driver hiccup - anything), a stale wayland-N socket/.lock file from that old process
# is still sitting here. wait-for-wayland.sh's socket-detection loop just finds *a*
# file matching `wayland-*` and declares the compositor up without checking it's
# actually backed by a live server - a stale file satisfies that instantly, before the
# new labwc has created its own socket, so wlr-randr/wayvnc immediately fail to connect
# and the container crash-loops forever. Wipe it on every start so only a genuinely
# fresh labwc's socket can be found here.
rm -rf "${XDG_RUNTIME_DIR}"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

# Wait for this container's default route before starting anything, when a network
# provider (code-docker's netinit-docker, see that project's
# .claude/backlog/netinit-docker-plan.md) is responsible for planting it. That agent runs
# on the host side and necessarily acts *after* this container has started, so without
# this wait there is a window in which Studio is already running with no egress policy in
# place - and Roblox Studio can make arbitrary outbound requests (HTTPService, plugins),
# which is exactly what the router boundary exists to constrain. Blocking here is what
# turns that race into a bounded wait.
#
# Deliberately fail-closed: if the route never appears we exit non-zero so
# `restart: unless-stopped` retries, rather than warning and carrying on unrouted. Note
# this needs no capability of its own - reading `ip route` is unprivileged; only the
# provider needs NET_ADMIN, and it lives outside this container on purpose.
#
# Off by default so this project still runs standalone, detached from code-docker, with
# no configuration at all (there is no router to wait for in that case). The code-docker
# overlay - roblox-studio-code-docker.yml - turns it on. The toggle does not weaken the
# fail-closed rule above: it says "this deployment has no provider to wait for", not
# "skip the wait even though one exists".
if [[ "${NETINIT_WAIT:-false}" == "true" ]]; then
	netinit_wait_timeout="${NETINIT_WAIT_TIMEOUT:-60}"
	netinit_waited=0
	while ! ip route show default 2>/dev/null | grep -q .; do
		if (( netinit_waited >= netinit_wait_timeout )); then
			echo >&2 "entrypoint: no default route after ${netinit_wait_timeout}s - the netinit provider never planted one. Refusing to start Studio unrouted; exiting so restart: unless-stopped retries."
			exit 1
		fi
		if (( netinit_waited == 0 )); then
			echo "entrypoint: waiting for the netinit provider to plant a default route..."
		fi
		sleep 2
		netinit_waited=$(( netinit_waited + 2 ))
	done
	echo "entrypoint: default route present ($(ip route show default | head -1)) - continuing"
fi

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER="${WLR_RENDERER:-gles2}"

# No real GNOME/KDE session here, so xdg-desktop-portal has no desktop-specific backend
# to auto-select via the modern portals.conf mechanism - XDG_CURRENT_DESKTOP=GNOME makes
# it fall back to matching each interface against installed .portal files' deprecated
# `UseIn=` key instead. Do NOT force XDG_DESKTOP_PORTAL_BACKEND=gtk (Vinegar's own
# troubleshooting doc suggests this, but it's Flatpak-specific guidance and breaks OpenURI
# resolution here - confirmed by testing).
export XDG_CURRENT_DESKTOP=GNOME

# Fixed, not discovered - unlike WAYLAND_DISPLAY (which depends on labwc actually being
# up), the D-Bus socket path only depends on XDG_RUNTIME_DIR above, so it can be exported
# once here and inherited by every supervisord child (dbus-service.sh creates the socket
# at this exact path; everything else just needs it set to connect).
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# Seed Vinegar's config with webview="" on first run only (never overwrite an existing
# one - the owner may deliberately change settings later via the GUI). Without this,
# a fresh ./data/vinegar-config volume hits the blank-WebView2-login bug documented in
# CLAUDE.md's "Milestone 3" section on its very first launch.
mkdir -p "${HOME}/.config/vinegar"
if [[ ! -f "${HOME}/.config/vinegar/config.toml" ]]; then
  cp /etc/vinegar-default-config.toml "${HOME}/.config/vinegar/config.toml"
fi

echo "[entrypoint] handing off to supervisord"
exec supervisord -n -c /etc/roblox-studio/supervisord.conf
