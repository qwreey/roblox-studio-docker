# Running a real, GPU-accelerated, remotely-viewable Chrome for Claude-in-Chrome alongside a containerized Roblox Studio

Research date: 2026-08-10. Pure research, no code changes.

## Bottom line up front

**There is no fundamental blocker**, but there is one hard architectural constraint that determines
how you must deploy it: **Claude Code and the Chrome browser it controls must run as processes on
the *same* OS/container instance.** Claude-in-Chrome is built on Chrome's Native Messaging API,
which is a local stdio-pipe IPC mechanism — the browser directly `exec()`s a native-host binary
declared in a per-browser manifest file on disk. It is *not* a network protocol, has no remote-host
concept, and Anthropic has explicitly declined to add one (see the closed devcontainer issue below).

The good news for this project: your target topology (Chrome + Roblox Studio + Claude Code **all
inside the same headless-compositor container**, streamed out to a human via VNC/WebRTC) is exactly
the case where this constraint is a non-issue — Claude Code, the native-messaging host it installs,
and Chrome are all co-located on one filesystem/OS by construction. This is a fundamentally different
(and easier) situation than the common complaint threads online, which are all about a *split*
topology (Chrome on a developer's host machine, Claude Code in a separate devcontainer/VPS/WSL guest).
Don't build a cross-boundary bridge — you don't need one if you install and run Claude Code inside
the same container as Chrome.

The second requirement is just as important: Claude-in-Chrome needs a **real, visible, non-headless**
Chrome window (it screenshots it, reads `system.display`, and drives it via
`chrome.debugger.attach`/CDP under the hood) — not `--headless` mode and not a bare
`--remote-debugging-port` setup with no display. This lines up naturally with the neko/Kasm/
linuxserver-style architecture: a normal windowed Chrome process rendering into a virtual/off-screen
Wayland or X11 display, which a separate compositor-side capture path streams out. This is a different
lineage from Selenium's `standalone-chrome-debug`/`chrome-devtools-mcp`, which target headless CDP
automation with no real GUI to stream — see below for why that lineage doesn't fit here.

---

## 1. How Claude in Chrome / Claude Code's `--chrome` integration actually works

- It's a Manifest V3 Chrome extension (`fcoeoabgfenejglbffodgkkbkcdhcgfn` in the Chrome Web Store)
  that opens a side panel and drives the active tab.
- Two communication paths exist depending on client:
  - **Claude Desktop**: the extension talks to the Anthropic API directly from the browser
    (`dangerouslyAllowBrowser: true`), authenticating via OAuth or an API key.
  - **Claude Code / VS Code extension** (the relevant one here): Claude Code installs a **native
    messaging host** — a manifest JSON file that tells Chrome "when the extension calls
    `chrome.runtime.connectNative('com.anthropic.claude_code_browser_extension')`, spawn *this*
    local binary and talk to it over stdin/stdout." Chrome then relays commands over a Unix socket
    to the running Claude Code process. This is described in a reverse-engineering writeup of the
    extension internals (gist by sshh12) and matches Anthropic's own troubleshooting docs, which
    list the exact native-host manifest paths per OS/browser (e.g. on Linux:
    `~/.config/google-chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json`).
  - Once connected, individual tool calls (`navigate`, `computer`, `read_page`, screenshot, etc.)
    are exposed to Claude Code as an MCP server (`claude-in-chrome`), and under the hood the
    extension drives the tab using `chrome.debugger.attach(tabId, "1.3")` (Chrome DevTools
    Protocol) plus the `scripting`/`system.display` extension permissions — i.e. it needs to know
    real viewport/screen dimensions and take real screenshots, which implies a real rendered
    window, not a detached/offscreen headless renderer.
- **System requirements** (official docs): Chrome, Edge, or another Chromium browser (Brave, Arc,
  Vivaldi, Opera also auto-detected) with the extension v1.0.36+; Claude Code; a **direct** Anthropic
  plan (Pro/Max/Team/Enterprise) — API-key or long-lived-token auth explicitly disables Chrome
  integration entirely, even with `--chrome`, because "the browser extension can't authenticate with
  those credentials." Not available via Bedrock/Vertex/Foundry. **Explicitly not supported on WSL.**
- **Why WSL is broken is instructive**: Chrome on Windows looks for its native host under the
  Windows registry, but Claude Code (running inside the WSL Linux guest) writes/checks the Linux-side
  native-messaging config path instead — the two environments don't share the OS-level
  install/lookup mechanism. This is the same class of problem as a container split, and Anthropic
  has not fixed it despite it being filed as both a bug and a feature request.
- **The devcontainer case is confirmed broken and explicitly declined**, not just undocumented:
  [anthropics/claude-code#25506](https://github.com/anthropics/claude-code/issues/25506) — Chrome on
  host macOS, Claude Code inside a VS Code DevContainer — fails with "Browser extension is not
  connected" because the native-messaging subprocess only speaks stdio, exposes no TCP port, and
  Claude Code's own connections are all outbound-only. Closed as not planned/stale; the reporter's
  suggested fixes (an opt-in `--chrome-port` TCP listener, a relay through Anthropic's own
  infrastructure) were not adopted.
- **No official remote/network mode exists.** Confirmed by [anthropics/claude-code#21299](https://github.com/anthropics/claude-code/issues/21299)
  ("Support remote/SSH usage (Claude Code on VPS, Chrome on local machine)") and by the docs' own
  silence on the topic.
- **Unofficial community bridges exist** for the cross-boundary case specifically —
  [`vaclavpavek/claude-code-remote-chrome`](https://github.com/vaclavpavek/claude-code-remote-chrome)
  (socat in the container forwards the native-messaging Unix socket over TCP to a Node.js relay on
  the host that re-attaches it to the real Chrome) and
  [`stolot0mt0m/claude-chromium-native-messaging`](https://github.com/stolot0mt0m/claude-chromium-native-messaging).
  These are proof-of-concept, unofficial, and fragile to any upstream protocol change — **you should
  not need them** if Claude Code runs inside the same container as Chrome, which is your actual plan.

Sources: [code.claude.com/docs/en/chrome](https://code.claude.com/docs/en/chrome),
[support.claude.com – Get started with Claude in Chrome](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome),
[Claude for Chrome Extension Internals gist](https://gist.github.com/sshh12/e352c053627ccbe1636781f73d6d715b),
[claude-code#25506](https://github.com/anthropics/claude-code/issues/25506),
[claude-code#21299](https://github.com/anthropics/claude-code/issues/21299),
[claude-code#41625 (WSL2 implementation notes)](https://github.com/anthropics/claude-code/issues/41625),
[claude-code#14445 / #23907 (WSL not-supported reports)](https://github.com/anthropics/claude-code/issues/14445),
[vaclavpavek/claude-code-remote-chrome](https://github.com/vaclavpavek/claude-code-remote-chrome).

---

## 2. Prior art: browser-in-a-container, streamed to a viewer

| Project | Display tech | Remote viewing | GPU |
|---|---|---|---|
| **neko** (m1k1o/neko) | Runs a real X server (or a full DE like XFCE/KDE) inside the container; Chrome/Firefox is just a normal windowed app on it. Not inherently tied to a browser — "anything that runs on Linux" works, it periodically captures the display. | **WebRTC** (multi-viewer, low-latency, built for watch-parties/live co-browsing) | Software by default; GPU passthrough is possible (it's just an X server) but not baked in — depends on your base image/driver setup. |
| **Kasm Workspaces / KasmVNC** | KasmVNC ships **its own Xorg server with a virtual framebuffer** in userspace — i.e. a full X11 stack that doesn't need a physical display, so it runs headless on a server. | KasmVNC protocol (VNC-derived, web client + native VNC client both work) | Real GPU acceleration via **DRI3** + VirtualGL/EGL, using `/dev/dri/renderD*`. Driver support matters: open-source Intel/AMD DRI3 drivers work; proprietary NVIDIA only works via Nouveau, not the closed driver — closed-driver NVIDIA GPU accel needs VirtualGL specifically. Desktop *compositing* must be disabled for DRI3 to work well. |
| **linuxserver/chromium** (and the shared `docker-baseimage-selkies`/webtop family) | Historically X11+PulseAudio; **as of the Selkies/"webtop 4.0" rework, default stack moved to Wayland** (their own compositor via Selkies/pixelflux), with legacy X11 still selectable. Wayland mode requires an AVX2 CPU (Haswell+). | Web (noVNC-style HTML5 client) + VNC, same underlying display either way | GPU accel via DRI3/DRM in both modes; in their Wayland mode, "a Wayland Compositor handles all the heavy lifting Xvfb used to do," with EGL/DMABUF-based rendering contexts on Intel/AMD/NVIDIA. |
| **jlesage/docker-chromium** (jlesage/docker-baseimage-gui family) | X11 (Xvfb-class virtual display) | Web client (noVNC-derived, port 5800) **and** raw VNC (port 5900) simultaneously, same underlying X display for both | Not GPU-accelerated by design — this baseimage line targets lightweight single-app kiosks, not 3D/video-heavy workloads; software rendering. |
| **selenium/standalone-chrome[-debug]** | Real X11 + VNC display too, actually — but the *intended* use is headless CDP automation via the WebDriver/Selenium server (port 4444), with VNC (port 5900) offered only as a debugging side-channel for watching test runs, not a first-class streaming product. Chrome here is launched by Selenium's own driver logic, which **ignores/overrides** manually-passed flags like `--remote-debugging-port`, so it's not a good fit for something else (Claude-in-Chrome, or your own tooling) attaching to a specific CDP port. Image line is deprecated (merged into plain `standalone-chrome`). | VNC (secondary/debug-only) | Software; not the point of this image family. |

**Why Selenium-style images are the wrong lineage for this project**: they're built around Selenium's
own driver spawning and owning the Chrome process/flags for test-automation purposes, actively
fighting anything else (like Claude-in-Chrome's native-messaging extension) that wants a
normal, extension-capable, user-driven Chrome session. neko/Kasm/linuxserver's family are the right
lineage: they run Chrome as an ordinary interactive browser with extensions, just pointed at a virtual
display instead of a physical one, which is exactly what Claude-in-Chrome needs (real window, real
extension, real CDP attach via `chrome.debugger`, real screenshots).

Sources: [n.eko.moe](https://neko.m1k1o.net/), [m1k1o/neko](https://github.com/m1k1o/neko),
[KasmVNC GPU Acceleration docs](https://kasmweb.com/kasmvnc/docs/master/gpu_acceleration.html),
[LinuxServer.io Webtop 4.0 blog (Wayland stack)](https://www.linuxserver.io/blog/webtop-4-0-wayland-is-here-engage-the-reality-engine),
[docs.linuxserver.io/images/docker-chromium](https://docs.linuxserver.io/images/docker-chromium/),
[jlesage/docker-chromium](https://github.com/jlesage/docker-chromium),
[jlesage/docker-baseimage-gui](https://github.com/jlesage/docker-baseimage-gui),
[SeleniumHQ/docker-selenium port-forwarding issue](https://github.com/SeleniumHQ/docker-selenium/issues/989),
[selenium/standalone-chrome-debug (Docker Hub, deprecated)](https://hub.docker.com/r/selenium/standalone-chrome-debug).

---

## 3. Chrome's native-Wayland support: relevant flags and rough edges

- Native (non-XWayland) Ozone/Wayland backend: `--ozone-platform=wayland` (older Chrome versions
  also needed `--enable-features=UseOzonePlatform`; recent stable Chrome/Chromium has this on by
  default when a `WAYLAND_DISPLAY` is present, but pinning the flag explicitly is still the reliable
  way to force it in a container). This is the multi-year "Waylandification" effort at Igalia.
- GPU acceleration on Wayland has historically been the rough part, not basic windowing:
  - Vulkan + `--ozone-platform=wayland` had compatibility problems that silently fell back to a
    software/GL compositor path in some Chrome versions (community reports as recent as 2026 on the
    Arch forums and Chromium's own issue tracker).
  - For VAAPI hardware video decode specifically, expect to need
    `--enable-features=VaapiVideoDecoder` (or `VaapiVideoDecodeLinux` on newer builds) plus
    `--disable-features=UseChromeOSDirectVideoDecoder` in some configurations, and possibly
    `--ignore-gpu-blocklist`/`chrome://flags/#enable-gpu-rasterization` if the sandboxed driver
    detection misfires on an unusual (headless-compositor) GPU/driver combo. Treat this as
    "usually fine on mainline Intel/AMD Mesa, needs troubleshooting on NVIDIA," consistent with the
    KasmVNC DRI3/NVIDIA caveat above.
  - Compositor protocol support varies: Chrome's screen-sharing (`getDisplayMedia`) and certain
    window-management behaviors depend on the compositor implementing specific Wayland protocols
    (e.g. `wlr-screencopy-unstable-v1` for wlroots compositors, or the `xdg-desktop-portal` +
    PipeWire path more generally). A GNOME/Mutter-only protocol won't work under a wlroots
    compositor and vice versa — since your sibling research is steering toward a wlroots-family
    compositor (sway/cage/weston-adjacent), Chrome's `wlr-screencopy`-based path is the one that
    matters, and it's well-supported there. You likely don't need `getDisplayMedia` at all for this
    use case (Claude-in-Chrome takes tab-level screenshots via CDP/extension APIs, not a
    desktop-capture API), so this is a minor/optional concern, not a blocker.
  - Minimal/kiosk-style wlroots compositors (cage in particular, which is single-window/kiosk by
    design) can be a poor fit if Chrome needs to spawn secondary top-level windows (e.g. some
    permission prompts, picture-in-picture, or DevTools-as-a-window) — worth flagging back to the
    sibling compositor research, since a multi-window-capable compositor (sway, weston) is safer for
    Chrome than a strict single-window kiosk compositor.

Sources: [Chrome/Chromium on Wayland — Waylandification project (Igalia)](https://blogs.igalia.com/msisov/chrome-on-wayland-waylandification-project/),
[electron/electron#50462 (GPU process lacks --ozone-platform/DrmSyncobj flags)](https://github.com/electron/electron/issues/50462),
[Chromium issuetracker 343352540 (HW accel unavailable with ozone-platform-hint=wayland)](https://issuetracker.google.com/issues/343352540),
[Arch forums: No GPU acceleration on Chromium Wayland](https://bbs.archlinux.org/viewtopic.php?id=305664),
[Arch forums: chromium VAAPI thread](https://bbs.archlinux.org/viewtopic.php?id=244031),
[ArchWiki Screen capture](https://wiki.archlinux.org/title/Screen_capture).

---

## 4. Can Chrome and Wine/DXVK (Roblox Studio) coexist in one compositor session?

- At the kernel/DRM level this is not a fundamental conflict: modern Linux GPU drivers expose
  **render nodes** (`/dev/dri/renderD*`) specifically so that *multiple unprivileged processes* can
  each open their own GPU context concurrently for rendering/GPGPU without needing exclusive
  "DRM master" ownership of the display (that exclusivity model is what the older `/dev/dri/card0`
  path had, and is not what Chrome or DXVK use for off-screen/composited rendering). Two independent
  GPU-accelerated processes (a Chromium GPU process and a DXVK/Wine `wined3d`↔Vulkan process) sharing
  one GPU via render nodes under one compositor is the same basic pattern as any modern Linux desktop
  running a browser and a game simultaneously — not exotic.
- What actually matters is the **display server layer**, not the GPU sharing itself:
  - **Xvfb cannot GPU-accelerate anything** — it's software-only. If either Chrome or the Wine/DXVK
    path ends up rendering through plain Xvfb (e.g. via XWayland misconfigured to fall back, or a
    base image that only ships Xvfb), you lose acceleration for that app regardless of the other one.
    This reinforces the sibling compositor research's direction (a real Wayland compositor +
    XWayland with DRI3, not bare Xvfb).
  - The one concretely-documented friction point found is narrower than "GPU contention": a note
    (from the gamescope project's own issue tracker) about **cross-process rendering/embedding**
    being awkward for Chromium/CEF-based apps specifically when composited unconventionally (e.g.
    game-store overlays), requiring workarounds — this is about window compositing/embedding
    quirks, not raw GPU resource contention, and doesn't obviously apply to Chrome and Roblox Studio
    running as two independent top-level windows (not embedded inside each other) under a
    general-purpose compositor like sway/weston.
  - No source found documents Wine/DXVK and Chromium specifically refusing to coexist under one
    compositor; the closest concrete data point is general "Wayland compositors don't handle
    non-fullscreen multi-window cases as gracefully as X11 in some corner cases" commentary, plus the
    usual ~10-15% NVIDIA Wayland performance tax reported in gaming-focused threads — a performance
    note, not a stability/functional blocker.
- Practical implication: budget for one shared GPU across two GPU-accelerated clients (Chrome +
  Roblox Studio via DXVK) — that's a capacity/perf planning question (don't starve either one), not
  an architectural incompatibility.

Sources: [render-nodes – Ponyhof](https://dvdhrm.wordpress.com/tag/render-nodes/),
[x11docker wiki: Hardware acceleration](https://github.com/mviereck/x11docker/wiki/Hardware-acceleration),
[Xvfb — Wikipedia](https://en.wikipedia.org/wiki/Xvfb),
[ValveSoftware/gamescope#1107 (Wine native Wayland driver / CEF cross-process rendering note)](https://github.com/ValveSoftware/gamescope/issues/1107),
[NVIDIA Developer Forums: Wine-wayland/SDL-wayland performance loss thread](https://forums.developer.nvidia.com/t/performance-loss-wine-walyand-sdl-wayland/353495/7).

---

## 5. Recommendation

1. **Run Chrome (real, non-headless) inside the same container/compositor session as Claude Code and
   Roblox Studio.** This is the one choice that sidesteps Claude-in-Chrome's hard architectural
   limitation entirely — do not build or rely on the unofficial TCP native-messaging bridges; they
   exist only because other setups keep Chrome and Claude Code apart, which you don't need to do.
2. **Install Claude Code inside that same container** (same OS/filesystem as Chrome) so the native
   messaging host manifest Claude Code writes and the Chrome extension's `connectNative()` call
   resolve to the same local filesystem/socket, exactly like a normal desktop install — no bridging
   needed.
3. **Give Chrome a real display to render into** — the same compositor (sway/weston-class, not a
   strict single-window kiosk like bare cage, given Chrome's occasional secondary-window needs) your
   sibling research is landing on for Roblox Studio. Launch Chrome normally (no `--headless` flag);
   let the compositor's own capture path (whatever wayvnc/WebRTC mechanism the sibling research
   picks) stream that same output to the human viewer — this reuses the exact same streaming pipe
   the Roblox Studio window already needs, no separate VNC/noVNC stack required just for Chrome.
4. Add `--ozone-platform=wayland` explicitly (don't rely on autodetection inside a container) to get
   Chrome on the native Wayland path rather than falling back to XWayland, and validate VAAPI/GPU
   flags empirically on the actual target GPU/driver — this is the area most likely to need
   iteration (see rough edges above), especially if the GPU is NVIDIA.
5. Don't reach for KasmVNC's own bundled Xorg+DRI3+VirtualGL stack or neko's X-server model unless
   the sibling compositor research's Wayland-first choice falls through — they're solid prior art for
   "GPU-accelerated browser streamed to a viewer" in general, but layering a second, X11-centric
   display stack alongside a Wayland compositor chosen for Roblox Studio would duplicate
   infrastructure for no benefit; reuse one compositor and one capture pipeline for both apps.
6. **Flag to the user explicitly**: this is a newer product surface with thin official documentation
   on unattended/server/container deployment specifically (nothing found describing "Claude in
   Chrome running against an intentionally-headless-hosted-but-still-real-window Chrome," which is
   exactly this use case) — the co-located-container approach is *architecturally* sound based on
   how native messaging works, but should still be smoke-tested early (install extension, run
   `claude --chrome`, confirm `/chrome` reports "Enabled"/"Installed" inside the actual target
   container) rather than assumed, since Anthropic could tighten host-fingerprinting or add
   anti-automation checks that specifically target unusual (virtual-display) environments without
   documenting it.
