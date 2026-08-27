#!/usr/bin/env bash
set -eu

# roblox-studio's side of the shared dns-local program (the resolver itself,
# and the writeup of the bug it exists for, live in
# qwreey/router-docker-client's dns-local/, fetched at build time by this
# image's Dockerfile).
#
# Why this container needs it at all: attached to code-docker's networks it
# sits on `internal: true` networks only, where Docker's embedded DNS
# (127.0.0.11) resolves same-network names but answers everything else with
# an immediate, definitive SERVFAIL - and nothing had ever written a second
# nameserver here, so external DNS was simply absent. Measured on a live
# deployment (2026-08-27): 0/15 lookups of clientsettings.roblox.com from
# this container, and Vinegar failing at launch with "setup: fetch: user:
# ... Temporary failure in name resolution". code-docker itself had already
# been fixed this exact way in 2026-08-10; this container was never wired
# up because it had no reason to think about DNS until it went behind
# router.
#
# It cannot simply point at router either: wayvnc-service.sh and
# novnc-service.sh both resolve VNC_BIND_ALIAS (`vnc-only`) with `getent`
# and *fail closed* if it doesn't resolve, and router's dnsmasq doesn't know
# compose aliases. Both upstreams are genuinely needed, which is the whole
# reason the shared script exists rather than a resolv.conf line.
#
# DNS_LOCAL_ENABLED defaults to false here, unlike the shared script's own
# default: standalone `docker compose up` (this repo's own docker-compose.yml,
# no router anywhere) has a perfectly working 127.0.0.11 and nothing to
# forward to. The code-docker overlay turns it on, exactly like NETINIT_WAIT.
export DNS_LOCAL_ENABLED="${DNS_LOCAL_ENABLED:-false}"
export NETSHARE_DIR="${NETSHARE_DIR:-/etc/roblox-studio/router-client/netshare}"

exec /etc/roblox-studio/router-client/dns-local/dns-local.sh
