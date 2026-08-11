FROM archlinux:latest

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
      grim \
      waybar \
      wofi \
    && pacman -Scc --noconfirm \
    && rm -rf /var/cache/pacman/pkg/*

# Vinegar (Roblox Studio bootstrapper) — built from source, matching the AUR `vinegar`
# package's own PKGBUILD build steps (no prebuilt binary release exists). Manages its
# own Wine build ("Kombucha") automatically at first run — no system `wine` package
# needed.
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
COPY config/vinegar/config.toml /etc/vinegar-default-config.toml
RUN chmod +x /etc/xdg/labwc/autostart

# wofi's "drun" mode (the app launcher waybar's menu button triggers) lists installed
# .desktop entries — foot doesn't ship one by default, add a minimal one so the terminal
# shows up alongside Vinegar's own and the chromium-nosandbox one added above.
RUN printf '[Desktop Entry]\nVersion=1.0\nName=Terminal\nExec=foot\nTerminal=false\nIcon=utilities-terminal\nType=Application\nCategories=System;TerminalEmulator;\n' \
      > /usr/share/applications/foot.desktop

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5900

ENTRYPOINT ["/entrypoint.sh"]
