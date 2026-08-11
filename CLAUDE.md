# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## What this is

A standalone Docker-based environment for running **Roblox Studio on Linux** (via
[Vinegar](https://github.com/vinegarhq/vinegar), a Wine-based bootstrapper), with GPU
acceleration, exposed over VNC for GUI access. The purpose is to get a real, usable
Roblox Studio session running headlessly on a server so the owner can remotely: install
and configure [Rojo](https://rojo.space/) (a Studio-sync tool) and an MCP-based
workflow, and log in and configure a dedicated "AI" Roblox account — with a human able to
watch the same session over VNC.

**Chrome + Claude-in-Chrome scope, clarified 2026-08-11 — read this before touching
Milestone 4**: the *original* motivation for wanting Chrome in this container was to
enable Claude Code's `--chrome` integration (Claude-in-Chrome) against a browser running
here. **That integration is not happening in this project, for now.** Claude-in-Chrome
is a local stdio Native Messaging connection, not a hostable/remote MCP server — there is
no way to point a Claude Code session running elsewhere at a Chrome instance inside this
container, and the owner has confirmed this is not something to solve here. Milestone 4
is scoped down to: **install Chrome, confirm it launches and renders correctly under
sway (a real browser window, visibly usable over VNC) — nothing more.** Do not install
Claude Code inside this container, do not attempt `claude --chrome`, do not build
anything to wire the two together. See "Backlog / explicitly deferred" near the bottom
of this file for the (not-currently-planned) future item.

**This project is deliberately standalone** — it has no dependency on, and must not
affect, `~/Projects/code-docker` (a separate, much larger personal infra project the
owner also maintains). It was originally scoped as a possible addition to code-docker's
`dind`/`router` container topology, but the owner decided against that: nesting a
privileged/GUI-heavy workload inside `code-docker-dind` runs into that project's authz
plugin restrictions, and `code-docker` is already large enough. Do not add any
dependency on code-docker's containers, networks, or compose files here. Plain Docker /
Docker Compose, self-contained, is the whole point.

## Where to start

1. **Read `research/99-SYNTHESIS.md` first** — it's a full research pass (5 parallel
   investigations, done 2026-08-10) into exactly this problem, with a reconciled final
   recommendation and citations. Its VirGL verdict is load-bearing and confirmed by
   implementation; **its X11-vs-Wayland verdict was overturned during implementation on
   2026-08-11 — see below, this is the current, correct architecture, not the synthesis
   doc's original text:**
   - **No VirGL / GPU-virtualization layer** (synthesis conclusion, confirmed). Use
     direct `/dev/dri` device passthrough instead (uniform for Intel/AMD via Mesa — no
     host-driver-version pinning needed; NVIDIA needs the separate NVIDIA Container
     Toolkit/CDI path — that's the one real per-vendor branch). This host has AMD
     (`amdgpu`) — plain Mesa `vulkan-radeon`, no NVIDIA CDI path needed here.
   - **Headless Wayland (`sway`, `WLR_BACKENDS=headless` + `wayvnc`), NOT X11/Xvfb** —
     this reverses the synthesis's original recommendation. Reason: empirical testing
     during Milestone 1/2 build-out found the synthesis's core claim ("DRI3 works
     identically under Xvfb+X11") is simply false — `Xvfb` has **zero** DRI3/GLX/Vulkan
     acceleration (confirmed via a real `vkcube` swapchain test: hard failure, "No DRI3
     support detected", no software fallback exists for Vulkan X11 presentation). The
     "obvious" fix, a real Xorg with the `modesetting`/`amdgpu` driver, was also tested:
     DRM master is *not* a conflict (good), but it fundamentally cannot create a virtual
     display without a real connected output (physical monitor/dummy-HDMI dongle) or
     fragile kernel connector-forcing — a dead end for "many Studio containers sharing
     one host GPU with no spare ports," which is the actual target deployment shape
     (owner's own words). A headless Wayland compositor's virtual-output backend has
     neither problem (no connector needed, GPU access via GBM/EGL on the render node
     directly, `wayvnc` captures via `wlr-screencopy` with no display attached at all) —
     see `research/03`. **Accepted tradeoff, explicitly chosen by the owner over the
     alternatives (a from-scratch rootful-XWayland-under-headless-Wayland prototype, or
     a physical dummy-HDMI-dongle-per-container hack):** Roblox Studio's edit-mode
     camera rotation is expected to be broken under this setup, because Wine's
     `winewayland.drv` and rootless XWayland both lack pointer-lock/cursor-constraint
     support (open upstream issues: `vinegarhq/vinegar#950`, `#805`, `#263`) — usable for
     scripted/MCP/Rojo workflows, not for manually orbiting the 3D viewport. Revisit if
     upstream ever lands a fix for either of those issues.
2. **Read `plan.md`** — the concrete build-out plan (directory layout, milestones,
   smoke-test order) derived from the synthesis **as amended by the Wayland pivot
   above** — plan.md's own "Resolved decisions" section has the full record. This is
   where actual implementation should start.
3. `research/01` through `research/05` have the full detail/citations behind each part
   of the original synthesis, if you need to verify a specific claim before building on
   it — but for the X11-vs-Wayland question specifically, trust point 1 above (and
   `research/03`) over `99-SYNTHESIS.md`'s own prose, which is now stale on that one
   point.
4. **Read `SETUP.md`** for the human-facing operator's guide — how to build/run, connect
   over VNC, do the first-time Roblox login, and debug it if something breaks. This file
   (CLAUDE.md) and `plan.md` are about *why* things are built the way they are; `SETUP.md`
   is about *how to actually use the thing*.

## Milestone 3 (Vinegar + Roblox Studio + real login) — DONE, 2026-08-11

Roblox Studio launches, renders, and a real account can log in end-to-end (verified:
Studio's dashboard loaded with "Welcome, &lt;username&gt;", real thumbnails, working UI).
Getting there required chasing down five independent, stacked bugs — all now fixed and
baked into the Dockerfile/entrypoint.sh/docker-compose.yml. Record kept here because none
of these are obvious and every one of them will silently break again if undone:

1. **A second host DNS problem, distinct from the build-time one.** `1.1.1.1` (set as a
   Docker daemon DNS server during Milestone 1) is completely unreachable from this
   host's containers — `1.1.1.1:53` times out after 3s, `8.8.8.8:53` responds in ~90ms.
   Docker's embedded resolver tries servers in order, so *every single DNS lookup in
   every container on this host* was paying a ~4s tax waiting for `1.1.1.1` to fail
   before falling back. This is what actually broke Roblox Studio's login — one specific
   API call (`usermoderation.roblox.com`) has an ~3s client-side timeout, just under that
   ~4s DNS tax, so login would get an OAuth token successfully and then fail on
   "Failed to fetch moderation status" almost every time. Fixed by dropping `1.1.1.1`
   entirely: `/etc/docker/daemon.json` → `{"dns": ["8.8.8.8"]}`, `systemctl restart
   docker`. If DNS-flavored flakiness reappears, check this first — `time getent hosts
   <anything>` should be well under 200ms from inside the container; if it's ~4s, this is
   back.
2. **Roblox Studio's login *always* tries an embedded WebView2 browser control first**,
   regardless of Vinegar's own "Web Pages" setting — that setting only controls whether
   *Vinegar* pre-installs/manages the WebView2 runtime for you. With it installed, the
   embedded login page loads correctly at the network level (real 200 responses,
   confirmed via Studio's own log) but renders as a blank/broken window — a known Wine+
   WebView2-on-Wayland compositing bug, not a network or config issue, no fix found (see
   Vinegar's own troubleshooting docs, which describe exactly this and recommend the
   workaround below). With Vinegar's WebView install disabled (`webview = ""` — see
   below), Studio correctly falls back to its native "Launch Failed → Login via Browser"
   screen instead, which is the path that actually works. **Set `webview = ""` under
   `[studio]` in Vinegar's config** (`/root/.config/vinegar/config.toml`, persisted via
   the `./data/vinegar-config` volume) — do not leave this at the default, the embedded
   path is a dead end here.
3. **"Login via Browser" needs a real working `org.freedesktop.portal.OpenURI`**, which
   needs: (a) a D-Bus session bus (`entrypoint.sh` starts one, generates `/etc/
   machine-id` if missing), (b) **`xdg-desktop-portal-gnome` installed** —
   `xdg-desktop-portal-gtk` alone does *not* implement OpenURI (confirmed by reading its
   own `.portal` file's `Interfaces=` list — no `AppChooser`/`OpenURI` in it at all;
   `xdg-desktop-portal-gnome`'s does), and (c) **the D-Bus *activation* environment must
   have `WAYLAND_DISPLAY` explicitly pushed into it** via `dbus-update-activation-
   environment` after sway starts — D-Bus service activation uses the environment
   `dbus-daemon` had at *its own* startup, not whatever the shell exports afterward, so a
   portal auto-activated later never sees a later `export WAYLAND_DISPLAY=...` unless
   this is done explicitly. Do **not** force `XDG_DESKTOP_PORTAL_BACKEND=gtk` — Vinegar's
   own troubleshooting doc suggests this (it's Flatpak-specific guidance) but it actively
   breaks OpenURI resolution here; `XDG_CURRENT_DESKTOP=GNOME` alone (letting the portal
   fall back per-interface across both installed backends) is what actually works.
4. **Chromium (launched via the portal for the login page) needs `--no-sandbox`** —
   everything in this container runs as root (no non-root user set up anywhere), and
   Chromium's zygote sandbox unconditionally refuses to start as root without it. Fixed
   with a custom `/usr/share/applications/chromium-nosandbox.desktop` registered as the
   default handler for `http`/`https`/`text/html` (the stock `chromium.desktop` can't be
   edited in place safely, so a parallel one was added instead) — **also carries
   `--ozone-platform=wayland`**, since Chromium does not reliably autodetect Wayland from
   `$WAYLAND_DISPLAY` alone here and silently falls back to a nonexistent X11 backend
   otherwise (`Missing X server or $DISPLAY`, hard exit).
5. **Docker's default 64MB `/dev/shm` is far too small.** Once Chromium actually got a
   window open, its page (and separately, Studio's own login page assets) failed to load
   most CSS/JS with `net::ERR_INSUFFICIENT_RESOURCES` — the exact same URLs loaded fine
   from a normal host browser, isolating it to a container resource limit, not a network/
   CDN issue. Fixed with `shm_size: '2gb'` in `docker-compose.yml`.

None of these are specific to *this* one login attempt — they're structural, and the fix
for each is now in the actual image/compose config (not something done ad hoc in a shell
that will be lost on rebuild). If Studio's login breaks again after a rebuild, suspect one
of these five having been silently reverted before re-investigating from scratch.

**Still-unverified, expected-broken item**: edit-mode camera rotation (the Wayland/
XWayland pointer-lock limitation accepted back in the Milestone 1/2 pivot). Not yet
actually tested inside a real place/experience — only the dashboard has been confirmed
so far. Worth a real check next time the container's up, but this is the *expected*,
already-accepted failure mode, not a new bug to chase.

**Confirmed as a bonus**: login state itself persists correctly across container
restarts — a later full rebuild + `docker compose down/up` cycle came back up already
logged in ("Welcome, qwreey_selene") with zero re-auth needed, via the existing
`./data/vinegar-data` volume (Milestone 5 was already partly done for exactly this
reason). The `webview=""` config fix is now also baked in as an image default (`config/
vinegar/config.toml` → `/etc/vinegar-default-config.toml`, seeded by `entrypoint.sh` into
`~/.config/vinegar/config.toml` only if that file doesn't already exist) — a genuinely
fresh `./data/vinegar-config` won't hit the blank-WebView2 bug on its first-ever launch.

## Key constraints to keep in mind while building

- **GPU is a hard requirement, not a nice-to-have**, for Roblox Studio's DXVK/native-Vulkan
  renderers specifically — a real `/dev/dri` render node with a working Vulkan ICD is
  needed; software rendering (llvmpipe/lavapipe) hard-fails for Vulkan renderers and is
  "not performant" even for the OpenGL fallback path, per Vinegar's own issue tracker.
- **Two real, live business risks, independent of anything technical built here** — flag
  these to the owner again before investing heavily, don't just silently assume they're
  fine:
  1. Roblox Studio currently has no anti-cheat (unlike Player, which has been
     Wine-blocked by Hyperion/Byfron since March 2024), but Roblox's own FAQ is
     explicitly non-committal about adding it to Studio in the future.
  2. A dedicated, automation/MCP-driven "AI" Roblox account is a distinct
     fraud-detection risk from the Wine-detection question — not researched in depth,
     worth the owner's own judgment call.
## Backlog / explicitly deferred

- **Claude-in-Chrome integration (`claude --chrome` against a Chrome instance running in
  this container) — not currently planned, do not build.** This was the *original*
  motivation for wanting Chrome in this project at all (see git history / early
  research), but the owner confirmed (2026-08-11) it isn't achievable the way initially
  hoped: Claude-in-Chrome is a local stdio Native Messaging connection between Chrome and
  a Claude Code process on the *same* machine — it has no hostable/remote-MCP-server
  mode, so a Claude Code session running elsewhere can't reach into this container to
  drive Chrome here. The only way to satisfy the constraint would be running Claude Code
  itself inside this container too (co-located with Chrome), which is a real option if
  priorities change later, but is explicitly out of scope for now — don't install Claude
  Code in the image, don't wire anything together, don't smoke-test `claude --chrome`
  here. If this becomes wanted again, `research/04-chrome-in-container-for-claude-mcp.md`
  already has the full architectural analysis (co-location requirement, native-messaging
  mechanics, prior art) — start there rather than re-researching.

## Conventions

- **Build/run**: `docker compose build`, then `VNC_PASSWORD=... docker compose up -d`
  (or copy `.env.example` to `.env`). Single service named `studio` in
  `docker-compose.yml`, image built from the root `Dockerfile`. VNC published on host
  port 5900 (override via `VNC_PORT`).
- **Base image**: `archlinux:latest` (matches host/owner's other infra). Milestones are
  added as straight-line layers in `Dockerfile` + startup logic in `entrypoint.sh` — no
  supervisord/multi-process-manager layer yet; `entrypoint.sh` backgrounds each process
  and `wait -n`s on them so the container dies if any one of them dies. Revisit this if
  the process count grows enough to make that fragile (e.g. once Vinegar/Chrome are
  added).
- **Display server: `sway` headless + `wayvnc`, not Xvfb/X11** — see the "Where to
  start" section above for why. Key env vars `entrypoint.sh` sets: `XDG_RUNTIME_DIR=
  /tmp/xdg-runtime` (Wayland requires this to exist and be writable — nothing works
  without it, including `vulkaninfo`/`vkcube`), `WLR_BACKENDS=headless`,
  `WLR_LIBINPUT_NO_DEVICES=1` (skips libinput device enumeration so wlroots never calls
  into libseat — no seatd/logind needed), `WLR_RENDERER=gles2` (real GPU accel via the
  render node once `/dev/dri` is passed through). The headless backend's virtual output
  is always named **`HEADLESS-1`** — `wayvnc`'s `--output=HEADLESS-1` and any future
  `swaymsg`/`swaybg` output-targeting config should hardcode this, it's stable as long as
  only one output is created.
- **`sway`'s binary needs `CAP_SYS_NICE`** (`docker-compose.yml` → `cap_add: [SYS_NICE]`)
  — it ships with `cap_sys_nice=ep` as a file capability, which is not in Docker's
  default capability set even for a root process; without this, `exec()` of `sway` fails
  outright with `Operation not permitted`, not a runtime error.
- **Config layout** (per `plan.md`'s proposed tree, confirmed working as of Milestone
  1+2): `config/wm/sway-config` is copied to `/etc/sway/config` in the image. Other
  `config/*` subdirs (`remote/`, `vinegar/`, `claude/`) exist but are still empty — no
  `wayvnc` config file committed, since its password comes from `$VNC_PASSWORD` and
  `entrypoint.sh` generates `/tmp/wayvnc.cfg` at container start instead (same pattern as
  the old x11vnc setup: never bake a secret into the image/repo).
- **Host Docker daemon requires a DNS override** to build/run at all on this host —
  `/etc/docker/daemon.json` → `{"dns": ["8.8.8.8"]}` (not project-specific config, outside
  this repo, but necessary to know if things start timing out again). This has been
  through two revisions — see "Resolved decisions" in `plan.md` for the first
  (build-time, `1.1.1.1`+`8.8.8.8` together) and "Milestone 3" above for the second
  (`1.1.1.1` turned out to be unreachable from this host's containers entirely, dropped).
  Current, correct value is `8.8.8.8` only.
- **Vinegar/Studio is not auto-started by `entrypoint.sh`** — it's launched manually
  (over VNC in real use; during development, via `docker exec`). To launch it from a
  shell, all of these env vars must be set (the ones `entrypoint.sh` itself exports for
  sway/wayvnc aren't automatically visible to a fresh `docker exec` shell):
  ```
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-1 HOME=/root \
         DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/xdg-runtime/bus"
  vinegar &
  ```
  Consider adding `exec vinegar` as a sway autostart line once the project is stable
  enough that always-launching-Studio-on-boot is actually wanted — not done yet since
  this was still under active iteration.
- **Verifying a headless Wayland milestone without a real VNC client**: `docker exec` in,
  `export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-1; grim /tmp/shot.png`
  (`grim` — not in the image by default, install ad hoc with
  `pacman -Sy --needed grim` inside the running container for a one-off check), then
  `docker cp` it out and view it. To test real GPU acceleration specifically, run
  `vkcube` (from `mesa-demos`) the same way — on a broken setup (e.g. the old
  Xvfb/X11 approach) it hard-crashes with "No DRI3 support detected"; on a working one it
  prints "Selected GPU 0: <real GPU name>" and renders. `swaymsg`/`sway-ipc` commands
  need `SWAYSOCK` explicitly set (find it via
  `find /tmp/xdg-runtime -name 'sway-ipc.*.sock'`) — `WAYLAND_DISPLAY` alone isn't
  enough for sway's own IPC socket, only for Wayland clients.
