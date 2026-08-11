# Headless Wayland compositor + VNC/RDP for Roblox Studio (Wine) + Chrome in Docker

Research date: 2026-08-10. Goal: replace a failed GNOME/mutter-in-Docker attempt with a
lightweight Wayland compositor that runs genuinely headless (no systemd/logind, no real
GPU output attached) inside a plain Docker container, remotely controllable over VNC or
RDP, hosting both Roblox Studio (via Wine) and Chrome.

## TL;DR recommendation

**Primary: `sway` (or `labwc`) with `WLR_BACKENDS=headless` + `wayvnc`, no systemd/seatd
required.** Both are real tiling/stacking window managers, so one compositor instance can
host Roblox Studio and Chrome as two normal windows side by side — no need for two
containers. Multiple public Docker prior-art projects already run exactly this
configuration with zero systemd/logind/dbus dependency:

- `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman` (or `gles2` if
  `/dev/dri` is passed through) is sufficient to start sway with no seat manager running
  at all — no seatd, no logind, no elogind. `WLR_LIBINPUT_NO_DEVICES=1` is the key flag:
  it skips libinput's physical-device enumeration (the actual reason wlroots would
  otherwise call into libseat), and the headless backend never opens a DRM device either,
  so libseat/seatd is simply never invoked in this mode.
  ([e42.uk](https://e42.uk/fancyhtml/techiestuff/swayonheadlesslinux.html),
  [bbusse/swayvnc](https://github.com/bbusse/swayvnc),
  [bbusse/swayvnc-firefox](https://github.com/bbusse/swayvnc-firefox))
- `muayyad-alsadi/containerized-gui-wayland` runs the same headless pattern with a choice
  of sway, labwc, river, wayfire, hikari, or phoc/phosh, wayvnc on :5900, and a noVNC web
  client on :8080, in a plain `podman run`/`docker run` with no compose/systemd unit
  needed. ([GitHub](https://github.com/muayyad-alsadi/containerized-gui-wayland))
- `XT-Martinez/labwc-headless-docker` runs labwc headless with wayvnc + Sunshine, driven
  by `docker compose`, no systemd inside the container.
  ([GitHub](https://github.com/XT-Martinez/labwc-headless-docker))

**Secondary / fallback: `weston --backend=headless-backend.so --backend=rdp-backend.so`.**
Weston is not wlroots-based but is a full reference compositor (not kiosk-only), so it can
also host multiple windows. Its major advantage: **RDP is a built-in backend**
(`rdp-backend.so`, FreeRDP under the hood) — no separate wayvnc/xrdp process, no
wlr-screencopy protocol dependency at all. `docker run -p 3390:3389 technic93/weston-rdp`
is working prior art. ([technic/docker-weston-rdp](https://github.com/technic/docker-weston-rdp))
Trade-off: weston does not implement wlr-screencopy/virtual-keyboard/virtual-pointer, so
**wayvnc cannot attach to weston** — you get RDP only, not a choice of both protocols.

**Not recommended for this use case:**
- **cage** — explicitly single-app kiosk only ("A kiosk runs a single, maximized
  application" — [cage-kiosk.github.io](https://cage-kiosk.github.io/cage/)). Hosting
  Roblox Studio + Chrome would require two cage instances (two containers, two VNC ports),
  which is strictly more moving parts than one sway/labwc instance with two windows, for
  no isolation benefit the user asked for. Worth keeping in your back pocket only if you
  later want one app pinned fullscreen per container for resource isolation.
- **Hyprland** — confirmed to be the most systemd/dbus-coupled of the group. Its docs
  describe `dbus-update-activation-environment --systemd --all` and
  `systemctl --user start hyprland-session.target` as the expected startup path, and
  `HYPRLAND_NO_SD_VARS`/`AQ_NO_KMS_REQUIREMENT` exist specifically as escape hatches from
  that default systemd-oriented behavior — i.e. it assumes systemd and has to be told not
  to. Its own headless mode has also had regressions (`hyprwm/Hyprland#7917`, "Headless
  mode no longer works", citing seatd backend failures).
  ([Hyprland Wiki](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/),
  [GitHub issue](https://github.com/hyprwm/Hyprland/issues/7917)) Avoid, matches the
  user's suspicion.
- **wayfire** — technically wlroots-based and capable of the same headless trick as sway,
  but has materially less Docker/headless prior art in the wild than sway/labwc, and its
  own maintainers note in wayfire#1183 that docs are stale about needing
  systemd/elogind/seatd ("nowadays wlroots requires just seatd") — i.e. the project's own
  documentation lags reality, a bad sign for reliably reproducing a no-systemd setup from
  its docs alone. Sway remains the better-trodden path.
  ([wayfire#1183](https://github.com/WayfireWM/wayfire/issues/1183))

## 1. Compositor comparison

| Compositor | Type | Headless flag | systemd/dbus needed? | Multi-window? | wayvnc-compatible? | Docker prior art |
|---|---|---|---|---|---|---|
| **sway** | wlroots, tiling WM | `WLR_BACKENDS=headless` | No — `WLR_LIBINPUT_NO_DEVICES=1` avoids libseat entirely | Yes (i3-style tiling) | Yes (reference impl target) | Multiple (see above) |
| **labwc** | wlroots, stacking WM (openbox-like) | `WLR_BACKENDS=headless` | No, same as sway | Yes (floating/stacking, more "normal desktop" feel) | Yes | `XT-Martinez/labwc-headless-docker` |
| **wayfire** | wlroots, compositing WM | `WLR_BACKENDS=headless` | No in theory, docs are stale/inconsistent | Yes | Yes (screencopy implemented) | Sparse |
| **cage** | wlroots, kiosk | Runs headless if not on a TTY/existing session | No | **No — single app only, by design** | Yes, but reports of `wayvnc`+`cage` virtual-pointer protocol errors (cage-kiosk/cage#173) | `containerized-gui-wayland` includes it as one option |
| **Hyprland** | wlroots-derived (own `aquamarine` backend) | `AQ_NO_KMS_REQUIREMENT=1` | Effectively yes by default; needs explicit opt-outs (`HYPRLAND_NO_SD_VARS`) to avoid | Yes | Yes (has screencopy protocol support) | Little; headless mode reported broken in places |
| **weston** | reference compositor (not wlroots) | `--backend=headless-backend.so` | No — headless backend never opens a DRM device, so libseat/seatd/logind is never invoked; only the DRM/KMS backend needs libseat | Yes (real desktop shell, not kiosk-only) | **No** — weston doesn't implement wlr-screencopy/virtual-keyboard/virtual-pointer | `technic/docker-weston-rdp` |

## 2. Remote protocol options

### wayvnc (VNC)
- Requires the compositor to implement `wlr-screencopy-unstable-v1` (or the newer
  `ext-image-copy-capture-v1`/`ext-image-capture-source-v1`, which Wayland merged as the
  standardized successor — wayvnc has already adopted the new protocol in recent commits,
  e.g. March 2025 output-capture backend work) plus `xdg-output` and
  `virtual-keyboard`/`wlr-virtual-pointer` for input injection.
  ([Phoronix](https://www.phoronix.com/news/Wayland-Merges-Screen-Capture),
  [wayvnc commit](https://github.com/any1/wayvnc/commit/6f40c7f182b7b1d2a26bc9b7fcaa82fb354957a5))
  Sway, labwc, wayfire, and Hyprland all implement these. **Weston and cage are the
  exceptions** — weston lacks them outright; cage (despite being wlroots-based) has had
  reported virtual-pointer interop bugs with wayvnc (`cage-kiosk/cage#173`).
- Does **not** need a real DRM/GPU device — it operates purely on the compositor's
  in-memory frame buffer via the screencopy protocol, which is exactly why the
  `WLR_BACKENDS=headless` + wayvnc combination works with zero physical display attached.
- `--disable-input` flag exists if you only want to view, not control.
  ([Arch man page](https://man.archlinux.org/man/wayvnc.1))
- Resource usage: lightweight, single small daemon; no independent findings of concerning
  overhead in the sources reviewed.

### weston's built-in RDP backend (`rdp-backend.so`)
- No separate server process — RDP support is compiled directly into weston.
- Flags: `--address=<addr>` (default `0.0.0.0`), `--port=<port>` (default `3389`),
  `--rdp-tls-key=<file>`/`--rdp-tls-cert=<file>` for TLS, `--rdp4-key=<file>` for legacy
  RDP security (explicitly documented as insecure, avoid in production),
  `--no-remotefx-codec`, `--no-resizeable`. Multi-seat aware: each connecting RDP client
  gets its own seat. ([Arch man page](https://man.archlinux.org/man/extra/weston/weston-rdp.7.en))
- Official docs explicitly warn plain "RDP security" mode is insecure and TLS mode should
  be used for anything beyond a trusted local/VPN network — treat as roughly
  production-viable *only* behind your existing reverse-proxy/VPN boundary, same posture
  code-docker already takes with code-server's `auth: none`.
- No separate username/password auth layer documented at the weston level — again, treat
  network-boundary auth (this repo's router/tailscale/tinyauth layer) as the actual gate,
  not RDP's own security.
- Maturity: present in weston since ~2013 (an "overview of the RDP backend in weston" post
  from Collabora-adjacent authors dates to 2013), so it is a long-lived, well-exercised
  backend, not a recent experiment.
  ([hardening-consulting.com](https://www.hardening-consulting.com/en/posts/20131006an-overview-of-the-rdp-backend-in-weston.html))

### xrdp (X11-era bridge)
- Explicitly flagged in current sources as "an X11-era bridge" whose Wayland-compositor
  screen-capture integration is fragile and regressing — one report notes the approach
  that used to work on wayfire "no longer works on labwc."
  ([Stackademic, 2025](https://stackademic.com/blog/remote-desktop-on-wayland-in-2025-what-changed-for-linux-support-engineers))
  Not recommended as a primary path; only relevant as a last-resort fallback if you decide
  to run an XWayland-rootful session instead of native Wayland clients.

### GNOME Remote Desktop (RDP/VNC)
- Ships RDP support tied into GDM/GNOME session machinery — inherits exactly the
  systemd/logind coupling the user already hit and is explicitly trying to avoid.
  Deprioritized per the task brief; not investigated further.

### waypipe
- A different class of tool entirely: it's Wayland-protocol forwarding over SSH (the
  spiritual equivalent of `ssh -X`), not a full remote-desktop/framebuffer protocol —
  `waypipe ssh remote-host app` runs the app remotely and displays it in a **local**
  Wayland compositor on the client machine, transmitting Wayland protocol messages and
  buffer diffs rather than raw pixels.
  ([Ubuntu man page](https://manpages.ubuntu.com/manpages/jammy/man1/waypipe.1.html))
  Doesn't fit this use case directly (there's no local Wayland compositor on whatever
  device the user/Claude's browser tooling would view this from) but is the right tool if
  the viewing device is itself a Linux Wayland desktop and only SSH access is available.
  Not competitive with VNC/RDP for "viewable by both a human and Claude's browser
  automation tooling," since it isn't a framebuffer-over-network protocol a generic RDP/VNC
  client (or a browser-based noVNC/RDP-in-browser client) can consume.

## 3. Wine on Wayland status (relevant to Roblox Studio via DXVK/VKD3D)

- Wine gained an **experimental native Wayland driver (`winewayland.drv`)** starting Wine
  8.4 (2023), developed primarily by Collabora, with the explicit long-term goal of
  removing the XWayland dependency for Windows-app compatibility.
  ([Neowin](https://www.neowin.net/news/wine-84-released-with-initial-native-support-for-wayland/),
  [Collabora](https://www.collabora.com/news-and-blog/news-and-events/a-wayland-driver-for-wine.html))
- As of mid-2026 it is **still actively developed but still described as experimental** —
  recent work (alpha-modifier-v1 protocol support, merged into the Wine 11.11 dev release)
  is still landing core compositing features. A concrete, currently-open bug
  (`GloriousEggroll/proton-ge-custom#544`) documents `winewayland.drv` creating a
  `wl_surface` role conflict with Vulkan swapchains on NVIDIA's Wayland driver (Mesa
  tolerates it, NVIDIA's stricter Wayland protocol enforcement rejects it), causing
  **gray/hung windows specifically in D3D11 apps** — i.e. exactly the DXVK-via-Vulkan path
  Roblox Studio would use. ([GitHub issue](https://github.com/GloriousEggroll/proton-ge-custom/issues/544))
- **Practical conclusion: for a real app like Roblox Studio today, run it via XWayland
  (the default/fallback path Wine already uses automatically when `winewayland.drv` isn't
  explicitly forced), not the native Wayland driver.** This is the safer, far more
  battle-tested path.
- XWayland itself is lightweight and does **not** pull in systemd/dbus — it's just an X11
  server implementation that proxies to the Wayland compositor as a client; sway, labwc,
  and wayfire all support running it on demand (`xwayland enable` in sway config, on by
  default in most). This does not reintroduce the systemd/logind coupling that broke the
  GNOME/mutter attempt — that coupling was specific to gnome-shell/mutter's session
  machinery (GDM, systemd-logind session tracking, geoclue/portal dbus services), not to
  XWayland as a protocol-translation layer.

## 4. Chrome on Wayland status

- Chrome/Chromium's Ozone/Wayland backend has matured significantly:
  **Chrome 140 (stable, August 2025) flipped `--ozone-platform-hint` to `auto` by
  default**, meaning Chrome now auto-detects and uses native Wayland when available,
  falling back to X11 otherwise — no manual flag needed anymore.
  ([Phoronix](https://www.phoronix.com/news/Chrome-Auto-Ozone-Platform),
  [OMG! Ubuntu](https://www.omgubuntu.co.uk/2025/08/chrome-140-wayland-auto-detection-linux))
  By 2026 this should be reliable on sway/labwc/wayfire (all implement the base
  xdg-shell/xdg-decoration protocols Chrome's Ozone/Wayland backend needs) — no XWayland
  needed for Chrome specifically, only for the Wine/Roblox Studio side.

## 5. GPU/rendering — orthogonal but important caveat

None of the sources above solve GPU acceleration by themselves — that's a separate,
compositor-independent decision:
- `WLR_BACKENDS=headless` with no `/dev/dri` passthrough forces software rendering
  (llvmpipe/pixman) for the compositor's own compositing, and Vulkan calls from
  DXVK/VKD3D would similarly fall back to Lavapipe (software Vulkan) with no GPU — almost
  certainly too slow for real Roblox Studio 3D viewport use, though fine for basic
  automation/screenshot purposes.
- For usable performance, pass the host GPU through with `--device /dev/dri` (works
  "flawlessly" with Mesa on both host and in-container per x11docker's own hardware
  acceleration wiki) or the NVIDIA Container Toolkit if on an NVIDIA host.
  ([x11docker wiki](https://github.com/mviereck/x11docker/wiki/Hardware-acceleration))
  This is independent of which compositor you pick — sway/labwc/weston can all use
  `/dev/dri` for GPU-accelerated rendering while *still* running their headless-output
  backend (no monitor attached), since headless-output and GPU-accelerated compositing are
  orthogonal: the headless backend just means "no real display sink," not "no GPU."

## 6. Recommended architecture for code-docker-style use

Given this repo's existing per-feature-container conventions (one compose service per
concern, `config/<program>/` override pattern):

1. **One container, one compositor instance**: sway (or labwc if a more "normal desktop"
   feel — floating windows by default — is preferred over sway's tiling-first UX) started
   with `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1`, GPU passed through via
   `/dev/dri` for real performance, running as a plain supervisord program the same way
   this repo already runs `code`/`sshd`/`webmanager`. No seatd, no systemd, no dbus system
   bus required for the compositor itself.
2. **wayvnc** as a second supervisord program in the same container, attached to that
   compositor's Wayland socket, exposing VNC on a published port — directly reusable by a
   human VNC client and by any VNC-capable browser automation tooling (e.g. noVNC in an
   iframe, matching this repo's own iframe-embedding conventions for router).
3. **Roblox Studio via Wine (XWayland, not `winewayland.drv`)** and **Chrome (native
   Wayland via Ozone auto-detect)** launched as two ordinary windows inside that one sway/
   labwc session — sway's tiling or labwc's floating window management handles
   "side-by-side" natively, no extra machinery needed.
4. Treat **weston + built-in RDP** as the fallback/alternative if RDP is specifically
   preferred over VNC (e.g. better clipboard/dynamic-resize UX for a human user) — but
   note it forfeits wayvnc entirely, so pick one remote protocol family up front rather
   than trying to run both against the same compositor.
5. Keep **cage** in reserve only if a later requirement emerges for strict single-app
   process isolation (e.g. sandboxing Roblox Studio away from Chrome for security/crash
   containment) — that would mean two containers, two cage instances, two VNC ports, which
   is more infrastructure than the sway/labwc single-instance design for no gain given the
   user's stated goal is *not* isolation but "Roblox Studio + Chrome side by side."

## Sources

- https://e42.uk/fancyhtml/techiestuff/swayonheadlesslinux.html
- https://github.com/bbusse/swayvnc
- https://github.com/bbusse/swayvnc-firefox
- https://github.com/muayyad-alsadi/containerized-gui-wayland
- https://github.com/XT-Martinez/labwc-headless-docker
- https://github.com/technic/docker-weston-rdp
- https://cage-kiosk.github.io/cage/
- https://github.com/cage-kiosk/cage/issues/173
- https://github.com/WayfireWM/wayfire/issues/1183
- https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/
- https://github.com/hyprwm/Hyprland/issues/7917
- https://man.archlinux.org/man/wayvnc.1
- https://man.archlinux.org/man/extra/weston/weston-rdp.7.en
- https://wayland.pages.freedesktop.org/weston/toc/running-weston.html
- https://www.hardening-consulting.com/en/posts/20131006an-overview-of-the-rdp-backend-in-weston.html
- https://stackademic.com/blog/remote-desktop-on-wayland-in-2025-what-changed-for-linux-support-engineers
- https://manpages.ubuntu.com/manpages/jammy/man1/waypipe.1.html
- https://www.neowin.net/news/wine-84-released-with-initial-native-support-for-wayland/
- https://www.collabora.com/news-and-blog/news-and-events/a-wayland-driver-for-wine.html
- https://github.com/GloriousEggroll/proton-ge-custom/issues/544
- https://www.phoronix.com/news/Chrome-Auto-Ozone-Platform
- https://www.omgubuntu.co.uk/2025/08/chrome-140-wayland-auto-detection-linux
- https://github.com/mviereck/x11docker/wiki/Hardware-acceleration
- https://www.phoronix.com/news/Wayland-Merges-Screen-Capture
- https://github.com/any1/wayvnc/commit/6f40c7f182b7b1d2a26bc9b7fcaa82fb354957a5
- https://devforum.roblox.com/t/the-new-roblox-64-bit-byfron-client-forbids-wine-users-from-using-it-most-likely-unintentional/2305528
- https://devforum.roblox.com/t/roblox-studio-broken-after-introduction-of-byfron/2331618
