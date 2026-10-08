# Kombucha's Wine version and the vinegarhq/kombucha commit its pinned release was built
# from (that release's `created_at`, matched against the repository's history). Global
# because both the runtime stage's Kombucha pin and winex11-build below need them; move them
# together with KOMBUCHA_VERSION and KOMBUCHA_SHA256 (in the runtime stage).
ARG KOMBUCHA_WINE_VERSION=wine-11.19
ARG KOMBUCHA_PATCHES_REF=cdf42b8f1f3a87d8952e072d6a46a0d6aef659e6

# desktop-resize.exe - the Windows-side half of keeping Studio's Wine virtual desktop the
# size of the screen (config/desktop-resize/desktop-resize.c, run by
# desktop-resize-service.sh). Built in its own stage so the mingw toolchain never reaches
# the runtime image.
FROM archlinux:latest AS desktop-resize-build
RUN pacman -Syu --noconfirm --needed mingw-w64-gcc
COPY config/desktop-resize/desktop-resize.c /src/desktop-resize.c
RUN x86_64-w64-mingw32-gcc -municode -mwindows -O2 -s -Wall -Werror \
      -o /src/desktop-resize.exe /src/desktop-resize.c -luser32 -lshell32

# StudioSync.rbxm - the Studio half of studio-sync (config/studio-sync/): Rojo's own plugin
# at the same release, with its UI entry point swapped (plugin/build.sh). The plugin talks
# to any `rojo serve` with the same protocol - 5, Rojo 7.7.0 and later - so this pin moves
# only when a project needs a newer protocol. Built in its own stage so git, python and
# rojo never reach the runtime image.
# winex11.so for the pinned Kombucha, rebuilt from the same Wine release and Kombucha
# patch set plus config/pointer-warp/winex11-grab-crossing.patch, and copied over the
# release's own in the runtime stage. Why: that patch's own comment and CLAUDE.md's "Camera
# drag over VNC". Only the unix-side winex11.so changes, so only it is built (a few
# minutes, against Wine's own headers; it talks to the release's win32u.so through the
# same version's interface).
FROM archlinux:latest AS winex11-build
ARG KOMBUCHA_WINE_VERSION
ARG KOMBUCHA_PATCHES_REF
RUN pacman -Syu --noconfirm --needed base-devel mingw-w64-gcc libx11 libxext libxfixes libxi \
      libxrandr libxrender libxcursor libxcomposite libxkbcommon wayland wayland-protocols \
      vulkan-headers vulkan-icd-loader freetype2 fontconfig gnutls
ADD https://github.com/vinegarhq/kombucha.git#${KOMBUCHA_PATCHES_REF}:patches/stable /src/kombucha-patches
COPY config/pointer-warp/winex11-grab-crossing.patch /src/
RUN v="${KOMBUCHA_WINE_VERSION#wine-}" \
    && mkdir -p /src/wine \
    && curl -fsSL "https://dl.winehq.org/wine/source/${v%%.*}.x/wine-${v}.tar.xz" \
         | tar xJ -C /src/wine --strip-components=1 \
    && cd /src/wine \
    && for p in /src/kombucha-patches/*.patch; do patch -p1 --fuzz=0 -s < "$p" || exit 1; done \
    && patch -p1 --fuzz=0 < /src/winex11-grab-crossing.patch \
    && ./configure --enable-archs=x86_64 --with-mingw --disable-tests --disable-win16 \
         --without-oss --without-alsa --without-pulse --without-gstreamer --without-cups \
         --without-sane --without-krb5 --without-netapi --without-v4l2 --without-pcap \
         --without-usb --without-sdl --without-capi --without-gphoto --without-opencl > /dev/null \
    && make -j"$(nproc)" dlls/winex11.drv/winex11.so > /dev/null \
    && install -Dm755 dlls/winex11.drv/winex11.so /out/winex11.so \
    && strip --strip-unneeded /out/winex11.so

FROM archlinux:latest AS studio-sync-plugin-build
ARG ROJO_VERSION=7.7.1
RUN pacman -Syu --noconfirm --needed git python unzip
ADD --checksum=sha256:00feb4fa0829a1dd72b49df2639da519a352bfe13cadcd83969e2ba2bb5693c4 \
    https://github.com/rojo-rbx/rojo/releases/download/v${ROJO_VERSION}/rojo-${ROJO_VERSION}-linux-x86_64.zip /tmp/rojo.zip
RUN unzip -q /tmp/rojo.zip -d /usr/local/bin && chmod +x /usr/local/bin/rojo
COPY config/studio-sync/plugin /src
RUN ROJO_REF="v${ROJO_VERSION}" /src/build.sh /src/StudioSync.rbxm

# LuauLSP.rbxm - luau-lsp's Studio companion plugin, with studio-defaults.patch (default
# host roblox-studio-front, auto-connect with retries). Reuses the stage above for git and rojo.
# LUAU_LSP_REF should match the luau-lsp extension version installed in code-server.
FROM studio-sync-plugin-build AS luau-lsp-plugin-build
ARG LUAU_LSP_REF=1.70.1
RUN pacman -S --noconfirm --needed patch
COPY config/luau-lsp-plugin /src-luau-lsp
RUN LUAU_LSP_REF="${LUAU_LSP_REF}" /src-luau-lsp/build.sh /src-luau-lsp/LuauLSP.rbxm

FROM archlinux:latest AS base

RUN pacman -Syu --noconfirm --needed \
      labwc \
      wlr-randr \
      wayvnc \
      xorg-xwayland \
      foot \
      ttf-dejavu \
      bash \
      procps-ng \
      curl \
      mesa \
      vulkan-radeon \
      vulkan-icd-loader \
      mesa-utils \
      vulkan-tools \
      hicolor-icon-theme \
      libxcursor \
      libxfixes \
      libxkbcommon \
      libxkbcommon-x11 \
      libx11 \
      wayland \
      libadwaita \
      gtk4 \
      xdg-utils \
      glib2 \
      base-devel \
      go \
      vulkan-headers \
      wayland-protocols \
      dbus \
      xdg-desktop-portal \
      xdg-desktop-portal-gtk \
      xdg-desktop-portal-gnome \
      chromium \
      thunar \
      grim \
      waybar \
      wofi \
      nodejs \
      npm \
      caddy \
      supervisor \
      dnsmasq \
      python \
    && pacman -Scc --noconfirm \
    && rm -rf /var/cache/pacman/pkg/*

# labwc and Xwayland rebuilt with config/pointer-warp/'s two patches. They make a dragged 3D
# camera usable through VNC's absolute pointer - what each one fixes: the patches' own
# comments and CLAUDE.md's "Camera drag over VNC". This stage starts FROM base, so the
# sources are those of exactly the labwc/xorg-xwayland (and wlroots) the runtime image
# installed, and the build-only packages never reach it; only the two binaries are copied.
# `--fuzz=0` makes a release that moved the patched code fail the build instead of applying
# a hunk somewhere else.
FROM base AS pointer-warp-build
RUN pacman -S --noconfirm --needed meson ninja xorgproto xtrans libxkbfile xorg-font-util
COPY config/pointer-warp/ /tmp/pointer-warp/
RUN pkgver() { pacman -Q "$1" | awk '{print $2}' | sed 's/^[0-9]*://; s/-[^-]*$//'; } \
    && LABWC_VERSION="$(pkgver labwc)" && XWAYLAND_VERSION="$(pkgver xorg-xwayland)" \
    && mkdir -p /tmp/pointer-warp/labwc /tmp/pointer-warp/xwayland \
    && curl -fsSL "https://github.com/labwc/labwc/archive/refs/tags/${LABWC_VERSION}.tar.gz" \
         | tar xz -C /tmp/pointer-warp/labwc --strip-components=1 \
    && curl -fsSL "https://xorg.freedesktop.org/archive/individual/xserver/xwayland-${XWAYLAND_VERSION}.tar.xz" \
         | tar xJ -C /tmp/pointer-warp/xwayland --strip-components=1 \
    && patch -d /tmp/pointer-warp/labwc -p1 --fuzz=0 < /tmp/pointer-warp/labwc-locked-absolute-motion.patch \
    && patch -d /tmp/pointer-warp/xwayland -p1 --fuzz=0 < /tmp/pointer-warp/xwayland-absolute-motion-after-warp.patch \
    && meson setup /tmp/pointer-warp/labwc/build /tmp/pointer-warp/labwc --buildtype=release \
         -Dxwayland=enabled -Dman-pages=disabled -Dnls=disabled -Dlabnag=disabled -Dsystemd-session=disabled \
    && ninja -C /tmp/pointer-warp/labwc/build \
    && meson setup /tmp/pointer-warp/xwayland/build /tmp/pointer-warp/xwayland --buildtype=release \
         -Dipv6=true -Dxvfb=false -Dxdmcp=false -Dxcsecurity=true -Ddri3=true -Dglamor=true -Dlibdecor=true \
         -Dxkb_dir=/usr/share/X11/xkb -Dxkb_output_dir=/var/lib/xkb \
    && ninja -C /tmp/pointer-warp/xwayland/build \
    && install -Dm755 /tmp/pointer-warp/labwc/build/labwc /out/labwc \
    && install -Dm755 /tmp/pointer-warp/xwayland/build/hw/xwayland/Xwayland /out/Xwayland \
    && /out/labwc --version | grep -q "^labwc ${LABWC_VERSION} (+xwayland" \
    && /out/Xwayland -version 2>&1 | grep -q "Xwayland Version ${XWAYLAND_VERSION} "

FROM base

# Vinegar (Roblox Studio bootstrapper) — built from source, matching the AUR `vinegar`
# package's own PKGBUILD build steps (no prebuilt binary release exists). Manages its
# own Wine build ("Kombucha") automatically at first run — no system `wine` package
# needed, though that auto-download is overridden by the pin below.
ARG VINEGAR_VERSION=1.9.4
RUN curl -fsSL "https://github.com/vinegarhq/vinegar/archive/refs/tags/v${VINEGAR_VERSION}.tar.gz" -o /tmp/vinegar.tar.gz \
    && tar xzf /tmp/vinegar.tar.gz -C /tmp \
    && cd "/tmp/vinegar-${VINEGAR_VERSION}" \
    && make clean \
    && sed -i '/gtk-update-icon-cache/d' Makefile \
    && make PREFIX=/usr all \
    && make PREFIX=/usr install \
    && cd / \
    && rm -rf "/tmp/vinegar-${VINEGAR_VERSION}" /tmp/vinegar.tar.gz /root/go /root/.cache

# Kombucha (Vinegar's own Wine build) — PINNED here rather than left to Vinegar's
# auto-download, so a new Kombucha release can't change the Wine under a working
# deployment without a rebuild. Two releases have done exactly that: wine-11.16 blanked
# Studio's 3D viewport (CLAUDE.md's "Wine 11.16 viewport regression"), and every release
# carries a winex11 patch that crashes without XDG_SESSION_TYPE (the `ENV
# XDG_SESSION_TYPE` comment below). Before moving it, open a place on the new build and
# check the viewport renders and panels still dock.
#
# Kombucha deletes a release once a newer one is out (only one release exists at a time),
# so the pinned tarball is fetched from this repository's own copy first - a GitHub release
# named after it (KOMBUCHA_MIRROR) - and from upstream only if that's missing. Either way it
# has to match KOMBUCHA_SHA256. Moving the pin means mirroring the new tarball first:
# CLAUDE.md's "Wine 11.16 viewport regression" has the steps.
#
# Installed under /opt, NOT into Vinegar's own data directory: Vinegar manages
# `~/.local/share/vinegar/kombucha*` itself and deletes a build there that isn't the one
# it wants — observed 2026-08-28, pointing `wineroot` at a sibling directory made it
# remove the pinned build on the very next launch. `config/vinegar/config.toml` points
# `wineroot` here, so moving this pin needs no config change on existing deployments.
# The `wine --version` test makes a KOMBUCHA_VERSION bump fail the build loudly when the
# tarball isn't the Wine it claims to be. KOMBUCHA_VERSION is URL-encoded (%2B for the
# `+` in the real tag name, `stable+20261005133651`) because it appears in both the
# release tag and the asset filename, and GitHub serves neither unencoded. The copy's
# release tag and asset name use `-` instead (`kombucha-stable-20261005133651`).
ARG KOMBUCHA_VERSION=stable%2B20261005133651
ARG KOMBUCHA_SHA256=45280181cdcf72bf2d7855a8330b359e3cc98c0acb309c5337665d7f1c8326d6
ARG KOMBUCHA_MIRROR=https://github.com/qwreey/roblox-studio-docker/releases/download
ARG KOMBUCHA_WINE_VERSION
RUN copy="kombucha-$(printf '%s' "${KOMBUCHA_VERSION}" | sed 's/%2B/-/')" \
    && { curl -fsSL "${KOMBUCHA_MIRROR}/${copy}/${copy}.tar.xz" -o /tmp/kombucha.tar.xz \
         || curl -fsSL "https://github.com/vinegarhq/kombucha/releases/download/${KOMBUCHA_VERSION}/kombucha-${KOMBUCHA_VERSION}.tar.xz" -o /tmp/kombucha.tar.xz; } \
    && echo "${KOMBUCHA_SHA256}  /tmp/kombucha.tar.xz" | sha256sum -c - \
    && mkdir -p /tmp/kombucha \
    && tar xJf /tmp/kombucha.tar.xz -C /tmp/kombucha \
    && mv "$(dirname "$(dirname "$(find /tmp/kombucha -type f -name wine -path '*/bin/*' | head -1)")")" /opt/kombucha-pinned \
    && rm -rf /tmp/kombucha /tmp/kombucha.tar.xz \
    && test "$(WINEPREFIX=/tmp/wine-version-probe /opt/kombucha-pinned/bin/wine --version)" = "${KOMBUCHA_WINE_VERSION}" \
    && rm -rf /tmp/wine-version-probe
# The release's winex11.so, replaced by winex11-build's (see that stage).
COPY --from=winex11-build /out/winex11.so /opt/kombucha-pinned/lib/wine/x86_64-unix/winex11.so

# Not cosmetic: Kombucha's winex11 does `strcmp(getenv("XDG_SESSION_TYPE"), "wayland")`
# with no NULL check (its "Don't hide cursor under X11 sessions" patch), so with this
# unset the X11 driver segfaults during init and Wine silently falls back to
# winewayland - which can't do Studio's virtual desktop. An image ENV rather than an
# entrypoint.sh export so a `docker exec` launch and the MCP bridge's Wine get it too.
ENV XDG_SESSION_TYPE=wayland

# noVNC + websockify — see CLAUDE.md's "VNC embedding" section. wayvnc itself stays raw
# RFB-only on VNC_PORT (unchanged, still the right choice for native clients like
# TigerVNC/KRDC, see SETUP.md); this adds a second, parallel path that puts a browser-
# reachable HTTP+WebSocket front end in front of the same session, which is what lets
# code-docker-router's App Routes (HTTP/WS-only Caddy, can't proxy raw RFB) embed it. No
# distro package for either (not in Arch's official repos or a reasonable AUR pin) — grab
# tagged release tarballs the same way Vinegar above is built from source, not from git
# (avoids adding a `git` dependency just for a release checkout). websockify needs only
# python3 (already required for other tooling; no numpy — this isn't the perf-sensitive
# multi-client-broadcast use case numpy exists for).
ARG NOVNC_VERSION=1.6.0
ARG WEBSOCKIFY_VERSION=0.13.0
RUN curl -fsSL "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" -o /tmp/novnc.tar.gz \
    && mkdir -p /opt/novnc \
    && tar xzf /tmp/novnc.tar.gz -C /opt/novnc --strip-components=1 \
    && rm /tmp/novnc.tar.gz \
    && curl -fsSL "https://github.com/novnc/websockify/archive/refs/tags/v${WEBSOCKIFY_VERSION}.tar.gz" -o /tmp/websockify.tar.gz \
    && mkdir -p /opt/websockify \
    && tar xzf /tmp/websockify.tar.gz -C /opt/websockify --strip-components=1 \
    && rm /tmp/websockify.tar.gz

# noVNC hardening: never ask the server for a 0x0 desktop. With remote resizing on
# (noVNC's `resize=remote`, which is what code-docker-router's VNC tab now defaults to)
# noVNC forwards its own viewport size to the server as an RFB SetDesktopSize request,
# with no lower bound of its own - and a viewer that is laid out at 0x0 (an iframe hidden
# with display:none, a page that never got a layout pass) duly requests 0x0. wayvnc then
# passes that straight through as a wlr-output-management custom mode, wlroots rejects
# any mode with width/height <= 0 as a *protocol error*, and libwayland treats a protocol
# error as fatal: wayvnc dies, critical-watchdog sees it and shuts the whole container
# down, and a client that reconnects on its own turns that into a restart loop. Observed
# for real (2026-08-25, `wayvnc -L debug`):
#
#   Client resolution changed: 0x0, capturing output HEADLESS-1 which is headless: yes
#   Client requested resize to 0x0, result: 4
#   [destroyed object]: error 3: invalid custom mode
#   ERROR: ../wayvnc/src/wayland.c: 269: Failed to dispatch pending
#
# Requesting a 0x0 desktop is meaningless in the first place, so the guard goes in
# unconditionally rather than being made configurable. Kept as a sed rather than a
# vendored patch file because it's one line and has to survive a NOVNC_VERSION bump
# legibly - the trailing `test` is what makes a bump that moves this code *fail the
# build* instead of silently dropping the guard.
RUN sed -i '/_requestRemoteResize() {/,/^    }$/ s#^\( *\)const size = this\._screenSize();#\1const size = this._screenSize();\n\1// PATCHED (roblox-studio-docker): never request a 0x0 desktop - see Dockerfile.\n\1if (size.w < 1 || size.h < 1) { return; }#' /opt/novnc/core/rfb.js \
    && test "$(grep -c 'PATCHED (roblox-studio-docker)' /opt/novnc/core/rfb.js)" = 1

# Default browser for xdg-desktop-portal's OpenURI (used by Vinegar's "Login via
# Browser" flow). Everything in this container runs as root (no non-root user set up),
# and Chromium's zygote sandbox refuses to start as root without --no-sandbox — so the
# stock chromium.desktop can't be used directly; register one that always passes it.
# --ozone-platform=wayland is also required explicitly: Chromium does not reliably
# autodetect Wayland from $WAYLAND_DISPLAY alone in this environment and falls back to
# its X11 backend (which then fails outright — no Xwayland display is exported for it).
RUN printf '[Desktop Entry]\nVersion=1.0\nName=Chromium\nExec=/usr/bin/chromium --no-sandbox --ozone-platform=wayland %%U\nTerminal=false\nIcon=chromium\nType=Application\nCategories=Network;WebBrowser;\nMimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;\n' \
      > /usr/share/applications/chromium-nosandbox.desktop \
    && xdg-mime default chromium-nosandbox.desktop x-scheme-handler/http x-scheme-handler/https text/html

COPY config/wm/labwc-rc.xml /etc/xdg/labwc/rc.xml
COPY config/wm/labwc-menu.xml /etc/xdg/labwc/menu.xml
COPY config/wm/labwc-autostart /etc/xdg/labwc/autostart
COPY config/wm/waybar-config.jsonc /etc/xdg/labwc/waybar-config.jsonc
COPY config/wm/waybar-style.css /etc/xdg/labwc/waybar-style.css
COPY config/wm/wofi-toggle.sh /etc/xdg/labwc/wofi-toggle.sh
COPY config/vinegar/config.toml /etc/vinegar-default-config.toml
RUN chmod +x /etc/xdg/labwc/autostart /etc/xdg/labwc/wofi-toggle.sh

# wofi's "drun" mode (the app launcher waybar's menu button triggers) lists installed
# .desktop entries — foot doesn't ship one by default, add a minimal one so the terminal
# shows up alongside Vinegar's own and the chromium-nosandbox one added above.
RUN printf '[Desktop Entry]\nVersion=1.0\nName=Terminal\nExec=foot\nTerminal=false\nIcon=utilities-terminal\nType=Application\nCategories=System;TerminalEmulator;\n' \
      > /usr/share/applications/foot.desktop

# Thunar, not Nautilus, is the file manager. Nautilus is only here as a dependency of
# xdg-desktop-portal-gnome (needed for OpenURI, see entrypoint.sh) and refuses to start
# as root ("Running as root is not supported") — and everything in this container runs
# as root. Hidden from the launcher, its org.freedesktop.FileManager1 D-Bus service
# removed (Thunar ships one too; with both installed in the same directory, D-Bus
# activation picks either), and directories handed to Thunar instead.
RUN sed -i '/^\[Desktop Entry\]$/a NoDisplay=true' /usr/share/applications/org.gnome.Nautilus.desktop \
    && test "$(grep -c '^NoDisplay=true' /usr/share/applications/org.gnome.Nautilus.desktop)" = 1 \
    && rm /usr/share/dbus-1/services/org.freedesktop.FileManager1.service \
    && xdg-mime default thunar.desktop inode/directory

# Rebuild the desktop-file MIME association cache — this must come *after* every
# .desktop file above, Vinegar's included. Vinegar's `make install` installs its
# org.vinegarhq.Vinegar.desktop (which is what claims
# `x-scheme-handler/roblox-studio-auth`, the deeplink Roblox's web login hands back
# to Studio) but deliberately does *not* run update-desktop-database — that lives in
# its separate `make host` target, which a distro package's post-install hook would
# normally run and an image build has to do itself. Without this, mimeinfo.cache
# still reflects only the pacman-installed apps and GIO cannot resolve the scheme at
# all, which breaks the *second half* of the "Login via Browser" flow while leaving
# the first half working perfectly: Chromium opens the Roblox login page, the user
# authenticates, clicks "Open Roblox Studio" — and nothing happens. Observed on the
# live deployment 2026-08-28, with the only trace being one line in Vinegar's own log:
#
#   gio: roblox-studio-auth:/?code=...: The specified location is not supported
#
# `xdg-mime query default x-scheme-handler/roblox-studio-auth` answers
# `org.vinegarhq.Vinegar.desktop` even while broken (it reads the .desktop files
# directly), so it is *not* a usable check for this — `gio mime
# x-scheme-handler/roblox-studio-auth` is, and it's the lookup that actually runs:
# with XDG_CURRENT_DESKTOP=GNOME (required, see CLAUDE.md's Milestone 3 item 3)
# xdg-open delegates to `gio open`.
#
# The explicit xdg-mime default is belt-and-braces on top: update-desktop-database
# alone is verified sufficient, but this pins Vinegar as the handler in
# /root/.config/mimeapps.list rather than relying on it being the only registered
# claimant forever. The test guard fails the build loudly if a Vinegar upgrade ever
# renames or drops the association instead of silently shipping a broken login.
RUN update-desktop-database /usr/share/applications \
    && xdg-mime default org.vinegarhq.Vinegar.desktop \
         x-scheme-handler/roblox-studio-auth x-scheme-handler/roblox-studio \
    && grep -q '^x-scheme-handler/roblox-studio-auth=org.vinegarhq.Vinegar.desktop' \
         /usr/share/applications/mimeinfo.cache

COPY config/mcp/Caddyfile /etc/mcp-bridge/Caddyfile
COPY config/mcp/mcp-bridge.sh /usr/local/bin/mcp-bridge.sh
COPY config/mcp/studio-mcp-stdio.sh /usr/local/bin/studio-mcp-stdio.sh
COPY config/mcp/mcp-shared-notice.py /usr/local/bin/mcp-shared-notice.py
COPY config/mcp/mcp-shared-notice.md /etc/mcp-bridge/mcp-shared-notice.md
RUN chmod +x /usr/local/bin/mcp-bridge.sh /usr/local/bin/studio-mcp-stdio.sh /usr/local/bin/mcp-shared-notice.py

# Process supervision: supervisord — see CLAUDE.md's "Process supervision: supervisord"
# section. One [program:...] file per process (config/supervisord.d/) plus each
# program's own service script (config/supervisor/), same split code-docker itself uses.
# Log directories are pre-created here because supervisord does not create the parent
# directory for a stdout_logfile/stderr_logfile path itself — matches code-docker's own
# Dockerfile, which does the same for the same reason.
RUN mkdir -p /etc/roblox-studio/supervisord.d \
      /var/log/dbus /var/log/labwc /var/log/wayvnc /var/log/novnc /var/log/mcp-bridge /var/log/critical-watchdog \
      /var/log/dns-local /var/log/desktop-resize /var/log/wine-owned-popups /var/log/studio-plugins /var/log/studio-output
COPY config/supervisord.conf /etc/roblox-studio/supervisord.conf
COPY config/supervisord.d/*.conf /etc/roblox-studio/supervisord.d/
COPY config/supervisor/wait-for-wayland.sh /etc/roblox-studio/wait-for-wayland.sh
COPY config/supervisor/dbus-service.sh /etc/roblox-studio/dbus-service.sh
COPY config/supervisor/labwc-service.sh /etc/roblox-studio/labwc-service.sh
COPY config/supervisor/wayvnc-service.sh /etc/roblox-studio/wayvnc-service.sh
COPY config/supervisor/novnc-service.sh /etc/roblox-studio/novnc-service.sh
COPY config/supervisor/mcp-bridge-service.sh /etc/roblox-studio/mcp-bridge-service.sh
COPY config/supervisor/critical-watchdog-service.sh /etc/roblox-studio/critical-watchdog-service.sh
COPY config/supervisor/dns-local-service.sh /etc/roblox-studio/dns-local-service.sh
COPY config/supervisor/studio-wine.sh /etc/roblox-studio/studio-wine.sh
COPY config/supervisor/desktop-size.sh /etc/roblox-studio/desktop-size.sh
COPY config/supervisor/desktop-resize-service.sh /etc/roblox-studio/desktop-resize-service.sh
COPY --from=desktop-resize-build /src/desktop-resize.exe /usr/local/lib/roblox-studio/desktop-resize.exe
COPY config/supervisor/wine-owned-popups-service.sh /etc/roblox-studio/wine-owned-popups-service.sh
COPY config/supervisor/studio-plugins-service.sh /etc/roblox-studio/studio-plugins-service.sh
COPY config/studio-output/studio-output-service.py /usr/local/lib/roblox-studio/studio-output-service.py
COPY --from=studio-sync-plugin-build /src/StudioSync.rbxm /usr/local/lib/roblox-studio/StudioSync.rbxm
COPY --from=luau-lsp-plugin-build /src-luau-lsp/LuauLSP.rbxm /usr/local/lib/roblox-studio/LuauLSP.rbxm
# Built here rather than in a separate stage: gcc (base-devel) and libX11 are already in
# this image. What it does and why: its own header comment.
COPY config/wine-owned-popups/wine-owned-popups.c /tmp/wine-owned-popups.c
RUN gcc -O2 -Wall -Wextra -Werror -o /usr/local/bin/wine-owned-popups /tmp/wine-owned-popups.c -lX11 \
    && rm /tmp/wine-owned-popups.c
RUN chmod +x /etc/roblox-studio/*-service.sh

# The patched labwc/Xwayland from the pointer-warp-build stage above; the distro builds
# stay in /usr/bin and labwc-service.sh picks one by VNC_POINTER_WARP_FIX.
COPY --from=pointer-warp-build /out/labwc /out/Xwayland /usr/local/bin/

# qwreey/router-docker-client's own subdirectories, fetched directly at build
# time, pinned to that repo's release tag (see its own CLAUDE.md;
# code-docker's dev-bump-router-client.sh moves this default) rather than
# vendored - the same way code-docker pulls them in.
#
# dns-local is what gives this container working DNS when it's attached to
# code-docker's `internal: true` networks; see config/supervisor/
# dns-local-service.sh for why it's needed and why pointing at router alone
# would break VNC_BIND_ALIAS. netshare comes along only for its wait_until
# helper, which dns-local uses for a bounded, well-logged first wait on
# router (it retries fine without it, the log is just less obvious).
ARG ROUTER_CLIENT_REF=v0.1.0
ADD https://github.com/qwreey/router-docker-client.git#${ROUTER_CLIENT_REF}:dns-local /etc/roblox-studio/router-client/dns-local
ADD https://github.com/qwreey/router-docker-client.git#${ROUTER_CLIENT_REF}:netshare /etc/roblox-studio/router-client/netshare
RUN chmod +x /etc/roblox-studio/router-client/dns-local/dns-local.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5900 6080 8787

ENTRYPOINT ["/entrypoint.sh"]
