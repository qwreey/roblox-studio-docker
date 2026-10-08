#!/bin/sh
set -eu

# roblox-studio-front: the only container on both roblox-studio-net and code-docker-internal.
# Studio itself sits on roblox-studio-net alone, so a plugin or script calling
# HttpService can't reach code-docker's nginx (code-server, webmanager) or dind's
# unauthenticated API. This forwards exactly two kinds of traffic across:
#
#   code-docker -> studio:8787                 Studio's MCP bridge (Caddy checks the token)
#   studio -> roblox-studio-front:<STUDIO_CODE_DOCKER_PORTS> -> code-docker   rojo serve, luau-lsp, ...
#
# Each listener is reachable from both networks, which grants nothing: from
# code-docker-internal, :34872 is code-docker's own port; from roblox-studio-net, :8787
# is Studio's own.
#
# Plain TCP (nginx stream), so HTTP and WebSocket both pass untouched. Upstreams are
# network-qualified (<container>.<network>) because this container answers to "studio"
# itself - a bare name could resolve back to it.

: "${STUDIO_UPSTREAM:?}" "${CODE_DOCKER_UPSTREAM:?}"
PORTS="${STUDIO_CODE_DOCKER_PORTS:-34872-34881 3667}"
CONF=/tmp/roblox-studio-front.conf

listens=""
for spec in ${PORTS}; do
  case "${spec}" in
    *[!0-9-]* | -* | *- | *-*-*)
      echo "[roblox-studio-front] STUDIO_CODE_DOCKER_PORTS: '${spec}' is not a port or a port range like 34872-34881" >&2
      exit 1
      ;;
  esac
  if [ "${spec%-*}" -le 8787 ] && [ "${spec#*-}" -ge 8787 ]; then
    echo "[roblox-studio-front] STUDIO_CODE_DOCKER_PORTS: '${spec}' includes 8787, which is Studio's MCP port" >&2
    exit 1
  fi
  listens="${listens}        listen ${spec};
"
done
[ -n "${listens}" ] || { echo "[roblox-studio-front] STUDIO_CODE_DOCKER_PORTS is empty" >&2; exit 1; }

cat > "${CONF}" <<EOF
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr notice;
events {}

stream {
    # A variable upstream, so it is re-resolved after the target is recreated with a new
    # IP; a literal hostname is resolved once, at startup.
    resolver 127.0.0.11 valid=10s ipv6=off;
    # Rojo's and other plugins' WebSockets sit idle between changes.
    proxy_timeout 1d;

    server {
        listen 8787;
        set \$upstream ${STUDIO_UPSTREAM}:8787;
        proxy_pass \$upstream;
    }

    server {
        # studio-sync's plugin probes roblox-studio-front:34880 every 2 s, which is usually closed;
        # at the default level each probe logs a connect() failure, and within a day the
        # log rotates away the startup line that lists the forwarded ports.
        error_log /dev/stderr crit;
${listens}        set \$upstream ${CODE_DOCKER_UPSTREAM}:\$server_port;
        proxy_pass \$upstream;
    }
}
EOF

echo "[roblox-studio-front] code-docker -> ${STUDIO_UPSTREAM}:8787; studio -> ${CODE_DOCKER_UPSTREAM}:{$(echo ${PORTS} | tr ' ' ',')}"
exec nginx -c "${CONF}" -g "daemon off;"
