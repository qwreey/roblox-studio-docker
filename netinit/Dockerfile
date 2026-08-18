# netinit - vendored from code-docker's netinit/ subtree (see
# ~/Projects/code-docker/netinit/CLAUDE.md - "a future sidecar wanting the same pattern
# can point docker-compose.yml's build.context at this directory too"). This repo stays
# standalone (code-docker-integration-plan.md's own principle), so rather than reaching
# across repos for a build context, this is a plain one-time copy of
# netinit/{Dockerfile,script/} - re-copy by hand if code-docker's own netinit/ changes in
# a way that matters here (no automated vendor script for a cross-repo copy like this,
# unlike code-docker's own vendor-netshare.sh which stays within one repo).
#
# Only used via roblox-studio-code-docker.yml (code-docker integration overlay) as
# `network_mode: service:studio` + NET_ADMIN, to keep studio's own default route pointed
# at code-docker-router - studio is treated as the same trust tier as code-docker itself
# (both are agent-adjacent dev containers with arbitrary outbound needs; Roblox Studio has
# its own HTTPService/plugin permissions), just split into its own container so nothing
# else needs direct /dev/dri access. Never used by the standalone docker-compose.yml.
FROM alpine:latest
RUN apk add --no-cache iproute2
COPY script/netshare /netshare
COPY script/netinit-entrypoint.sh /netinit-entrypoint.sh
ENTRYPOINT ["/netinit-entrypoint.sh"]
