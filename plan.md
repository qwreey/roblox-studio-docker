# Build plan: Roblox Studio in a standalone Docker container

Status: **Milestones 1, 2, 3, 7, 8, and 9 done — session hand-off point, 2026-08-13.**
Headless Wayland + wayvnc + real GPU acceleration (verified with a real `vkcube` Vulkan
render). Vinegar + Roblox Studio + a real account login all working end-to-end, confirmed
with a full 3D place open and rendering correctly (the built-in Studio Tour's carnival
scene, real-time GPU-rendered, mouse interaction working over a real VNC client) — see
CLAUDE.md's "Milestone 3" section for the five stacked bugs that had to be fixed to get
there. Milestone 5 (persistence) also partly done ahead of schedule, and Milestone 6
(setup docs) mostly done — see `SETUP.md` for the practical build/run/connect/debug guide.
Since then: the VNC network-segmentation groundwork (Milestone 7), the Studio MCP bridge
(Milestone 8 — built 2026-08-13, re-verified live this session with a real Luau execution
through the full published-bridge chain against an actually-open Studio place), and the
`entrypoint.sh` → `supervisord` process-supervision migration (Milestone 9 — built and
live-verified this session: killing `labwc` correctly brought the whole container down and
recovered cleanly, killing the MCP bridge's own process only restarted that one program).
Originally derived from `research/99-SYNTHESIS.md`; the display-server choice was
corrected by empirical testing early on — see CLAUDE.md's "Where to start" section for
that reasoning, this file just carries the practical consequences. Standalone project — no
dependency on `code-docker` or any of its containers/networks.

**Remaining for a future session**: Chrome profile persistence (still open, see §5 —
deliberately deferred, not currently needed), Rojo install/config (genuinely not
started), an explicit camera-rotation stress-test in a real viewport (the one
originally-expected-broken item from the Wayland decision — interaction has turned out
to work better than that pessimistic baseline, but this specific case hasn't been
deliberately tried), and the actual code-docker-side network attachment plus wiring
code-docker's own Claude Code to the MCP bridge (both deliberately deferred — see
Milestone 7/8 below; code-docker itself hasn't been touched by any of this project's
work). Milestone 4 (Chrome standalone verify) done as of 2026-08-13 — see below.

## Resolved decisions (were open questions below; keeping them here so they aren't
re-litigated)

- **Base distro: Arch Linux** — matches the host and the owner's other infra.
- **GPU: AMD** (host has `amdgpu`/`renderD128`) — plain Mesa `vulkan-radeon` passthrough
  via `/dev/dri`, no NVIDIA Container Toolkit/CDI path needed.
- **Host Docker daemon needed a DNS fix — final value `{"dns": ["8.8.8.8"]}` only.** The
  host resolves via Tailscale MagicDNS (100.100.100.100), which isn't reachable from
  container network namespaces, so `pacman` inside any build/container hung/timed out on
  mirror hostname lookups until a public resolver was set (Milestone 1). The first fix
  used `["1.1.1.1", "8.8.8.8"]` together, which was *wrong*: `1.1.1.1` turned out to be
  completely unreachable from this host's containers (`1.1.1.1:53` times out after 3s,
  every time), so every DNS lookup in every container was paying a ~4s tax waiting for it
  to fail before falling back to `8.8.8.8` — this is what actually broke Roblox Studio's
  login during Milestone 3 (one login-flow API call has a ~3s client timeout, just under
  that ~4s tax). Dropped `1.1.1.1` entirely once found; `8.8.8.8` alone resolves in
  ~90ms. This is a host-level fix (outside the repo) — if rebuilding on a fresh host and
  hitting DNS timeouts or unexplained flakiness, check `/etc/docker/daemon.json` and
  `time getent hosts <anything>` from inside a container first (should be well under
  200ms).
- **Display server: headless Wayland (`sway` + `wayvnc`), not X11/Xvfb — reverses the
  synthesis's original recommendation.** Discovered during Milestone 1/2 implementation
  (2026-08-11): `Xvfb` has zero DRI3/GLX/Vulkan acceleration (empirically confirmed —
  `vkcube` hard-fails against it, "No DRI3 support detected", no fallback), and a real
  Xorg with GPU acceleration needs a physically-connected display output, which doesn't
  scale to "many Studio containers sharing one host GPU" (the actual target deployment —
  owner confirmed multiple containers will run on one host). A headless Wayland
  compositor's virtual-output backend has neither problem. **Accepted, owner-confirmed
  tradeoff**: Roblox Studio's edit-mode camera rotation will be broken (known upstream
  Wine/Vinegar pointer-lock gap under Wayland/XWayland) — acceptable for scripted/MCP/
  Rojo workflows, revisit if upstream fixes it. Full reasoning + citations: CLAUDE.md
  point 1, `research/03-headless-wayland-compositor-vnc-rdp.md`.

## Goal

One Docker container (or small docker-compose stack) that:
1. Boots a real headless Wayland desktop (`sway`, `WLR_BACKENDS=headless` — no physical
   display, no systemd/logind).
2. Runs Roblox Studio via Vinegar with real GPU acceleration (accepting the known camera-
   rotation limitation noted above).
3. Runs a real Chrome instance, confirmed launching and rendering correctly under sway.
   **Not** wired up to Claude Code / `claude --chrome` — see CLAUDE.md's "Backlog /
   explicitly deferred" section, that integration isn't achievable remotely and is
   explicitly out of scope for this project right now.
4. Is reachable over VNC (`wayvnc`) for the owner to do first-time setup (Rojo install,
   MCP config, Roblox login for a dedicated AI account) and later, ongoing use.
5. Persists state (Wine prefix, Roblox Studio data/plugins, Chrome profile) across
   container rebuilds via volumes.

## Proposed directory layout

```
roblox-studio-docker/
├── CLAUDE.md
├── plan.md                    (this file)
├── research/                  (moved from code-docker's research pass — read first)
├── docker-compose.yml         (top-level: the one service + volumes + published ports)
├── Dockerfile
├── entrypoint.sh              (starts sway (headless), wayvnc, then Vinegar/Chrome — see below)
├── config/
│   ├── wm/                    (sway config — window layout: Studio + Chrome side by side)
│   ├── remote/                (wayvnc config)
│   ├── vinegar/                (Vinegar config — renderer choice, FFlags, Virtual Desktop mode on)
│   └── claude/                (Claude Code config seeding, if any container-specific bits needed)
└── data/                      (gitignored — runtime volumes: wine prefix, chrome profile, etc.)
```

Not committing to this layout being final — code-docker uses a `<name>.default.*` +
`<name>.override.*` per-file pattern for everything, which is a good idea to *consider*
reusing here for consistency with the owner's other infra, but this project is small
enough that a flatter structure may be entirely sufficient. Decide once the first
container actually boots and it's clear what needs to be overridable.

## Build-out milestones (in order — each should be independently verifiable before moving on)

### 1. Bare headless Wayland + remote access
- Base image: Arch Linux (resolved above).
- `sway` started with `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1` (no seatd, no
  logind, no dbus — see `research/03` §1) + `wayvnc` attached to the same compositor's
  Wayland socket for remote viewing/control.
- **Verify**: connect with a VNC client from another machine, see the compositor's
  virtual output with sway running (e.g. launch a terminal and confirm it appears/can be
  moved).
- No GPU yet at this stage — confirm the plumbing (compositor, remote access) works
  before adding any acceleration complexity.

### 2. GPU passthrough
- Add `--device /dev/dri` (or specific `/dev/dri/renderD1xx`) to the compose file, plus
  render-group membership.
- Install Mesa (`mesa`, `vulkan-icd-loader`, and the vendor driver — `vulkan-radeon` for
  AMD, `vulkan-intel` for Intel; if targeting NVIDIA, this is the one branch-point — use
  the NVIDIA Container Toolkit / CDI mechanism instead of a plain `--device` bind, see
  `research/05-gpu-passthrough-comparison-and-architecture-fit.md` §1).
- **Verify**: `glxinfo | grep renderer` and `vulkaninfo | grep deviceName` inside the
  running container both report the real host GPU, not `llvmpipe`/`lavapipe`.
- **Decide up front**: what GPU(s) does the actual target host(s) have? If it's
  known/fixed (single server), just hardcode the right driver package instead of
  building generic multi-vendor detection — no need to over-engineer this if there's
  only one real deployment target.

### 3. Vinegar + Roblox Studio — DONE, 2026-08-11
- Built Vinegar from source (no prebuilt binary release exists — matched the AUR
  `vinegar` package's own PKGBUILD build steps). Manages its own Wine build ("Kombucha")
  automatically at first run — no system `wine` package needed.
- In practice, Wine ended up using its **native `winewayland.drv`** (not XWayland as
  originally planned here) — Vinegar/Wine auto-detected `WAYLAND_DISPLAY` and preferred
  it; `xorg-xwayland` is still installed but wasn't what actually got used. Doesn't change
  the accepted camera-rotation tradeoff (research already established both paths have the
  same pointer-lock gap).
- Renderer: `DXVK` (Vinegar's default). Real Vulkan acceleration confirmed via Wine's own
  diagnostic log line (`winediag:wined3d_dll_init Using the Vulkan renderer`).
- **Verify — done**: Studio launches, renders its full UI correctly (splash screen,
  dashboard, real thumbnails), and **a real account successfully logged in** end-to-end
  via the "Login via Browser" flow. See CLAUDE.md's "Milestone 3" section for the five
  bugs fixed to get there. Camera rotation itself (the accepted-broken item) is not yet
  separately verified — only the dashboard has been tested so far, not an actual
  place/experience's 3D viewport.

### 4. Chrome — DONE, 2026-08-13
- Install a real Chrome/Chromium (not headless) — Chrome's Ozone/Wayland backend
  auto-detects and uses native Wayland by default (Chrome 140+, per `research/03` §4),
  no XWayland needed for Chrome specifically.
- **Verify**: Chrome launches and renders a real page correctly under sway, visible and
  usable over VNC. That's the entire scope of this milestone — **no Claude Code
  installation, no `claude --chrome`, no wiring the two together.** See CLAUDE.md's
  "Backlog / explicitly deferred" section for why (short version: Claude-in-Chrome can't
  be driven remotely, only from a co-located Claude Code process, and the owner has
  confirmed that's not a goal here for now).
- **Confirmed 2026-08-13**, separately from the login-flow usage this already got
  incidentally in Milestone 3: launched `chromium --no-sandbox
  --ozone-platform=wayland https://example.com` by hand against the already-running
  container (labwc, not sway — the WM had already switched by the time this milestone
  was actually revisited), captured via `grim`. Real decorated floating window, correct
  page render, live waybar taskbar entry, Roblox Studio still visible and unaffected
  running behind it. Closed cleanly afterward (`pkill chromium`) with no side effects on
  the live session. No further action needed on window-layout arrangement (labwc's
  floating/movable windows make manual side-by-side placement a non-issue, unlike sway's
  tiling — see CLAUDE.md's "Window manager: labwc" section).

### 5. Persistence — Vinegar/Wine side DONE, 2026-08-11; Chrome profile still open
- Done: `./data/vinegar-data` → `/root/.local/share/vinegar` (Kombucha Wine, Studio
  install, Wine prefixes), `./data/vinegar-config` → `/root/.config/vinegar` (config.toml,
  including the `webview = ""` setting from Milestone 3 — must survive restarts),
  `./data/vinegar-cache` → `/root/.cache/vinegar` (download cache, logs). **Verified**:
  survived a full `docker compose down && up` (forced by a Docker daemon restart mid-
  session) with zero re-download and the `webview=""` config intact.
- Still open: Chrome's own profile directory (`/root/.config/chromium`) isn't volume-
  mounted yet — not yet needed since Chrome is only used transiently for the OAuth login
  handoff (no persistent Chrome-side login state to preserve so far), but revisit if that
  changes (e.g. if the same Chrome profile needs to stay logged into the Roblox website
  across restarts for a smoother browser-login flow).

### 6. First-time setup docs — VNC/login/debugging done, 2026-08-11; Rojo/MCP still open
- `SETUP.md` now covers: build/run, connecting with a real VNC client, the first-time
  Roblox login walkthrough (verified working end-to-end with a real account), debugging
  without a VNC client (the `grim`/`vkcube` techniques used throughout Milestone 3), and
  a "if something breaks, check these in order" list covering the DNS/config regressions
  most likely to recur.
- **Not yet written**: Rojo install/configuration and the MCP connection setup — neither
  has been attempted yet. Both are still genuinely manual, GUI-driven steps per the
  original plan; add to `SETUP.md` once actually done once, don't write speculative
  instructions ahead of doing it.

### 7. VNC network segmentation groundwork — done, 2026-08-12
- Added `VNC_BIND_ALIAS` to `entrypoint.sh` (optional env var; when set, binds wayvnc to
  that alias's resolved IP instead of `0.0.0.0`; fails closed if it can't resolve) —
  groundwork for a future integration into `~/Projects/code-docker` where this container
  would sit on two Docker networks (one for a future MCP bridge, one dedicated to VNC and
  shared only with a router-like container), and VNC must be unreachable from the other.
  See CLAUDE.md's "Future code-docker integration" section for the full reasoning.
- Validated via a new self-contained proof-of-concept, `poc/code-docker-integration/`
  (mock containers standing in for code-docker's `router`/agent containers, plus the real
  `roblox-studio` image) — `verify.sh` confirms 4/4: DNS- and TCP-level VNC isolation from
  the "agent" side, real VNC reachability from the "router" side, and that the shared
  network itself isn't broken (isolation is VNC-specific, not total).
- Zero regression to the standalone path: `VNC_BIND_ALIAS` is unset by default in the root
  `docker-compose.yml`, reproducing today's exact `0.0.0.0` behavior.
- **Still open / explicitly deferred**: the real code-docker-side attachment (editing
  code-docker's actual `docker-compose.yml`/networks — separate future task, code-docker
  itself was deliberately not touched in this pass) and wiring code-docker's own Claude
  Code to the bridge. The MCP bridge itself was originally deferred alongside this but was
  actually built the next day — see Milestone 8 below.
- **Concrete connection mechanism now designed, 2026-08-13**: `code-docker-integration-
  plan.md` (repo root) — a Docker Compose `include:` chain (validated end-to-end with
  real `docker compose config` runs, see that doc's "검증 방법" section) that lets
  code-docker's own `docker-compose.yml` stay untouched/upstream-clean while pulling in
  this repo's services. `roblox-studio-code-docker.yml` (new, repo root) implements
  both phases now: "Phase 1" (attaches `studio` to `code-docker-internal`) and
  "Phase 2" (2026-08-13/14, done — VNC on its own `roblox-studio-vnc` `internal: true`
  network, reachable only via `code-docker-router`'s `forwards:`; new `studio-netinit`
  sidecar keeps `studio`'s default route pointed at router, same pattern
  code-docker/dind use). Turned out no code-docker-side code changes were needed after
  all — real testing showed `forwards:`/the host firewall don't actually constrain
  this the way the code comments suggested; the real fix was entirely on this repo's
  side (the netinit sidecar). See `code-docker-integration-plan.md`'s "Phase 2 — 구현
  완료" section. Still open: a real end-to-end run with the actual Studio image and a
  VNC client, not done yet (config/component-level only so far).

### 8. Studio MCP bridge — done, 2026-08-13
- Roblox Studio's built-in MCP server (stdio-only, single-machine by design) bridged out
  over the network: `supergateway` (stdio↔Streamable HTTP) + `caddy` (bearer-token auth,
  the only published MCP port) — `config/mcp/mcp-bridge.sh`, `config/mcp/
  studio-mcp-stdio.sh`, `config/mcp/Caddyfile`. Full walkthrough in `SETUP.md`'s "Studio
  MCP over the network" section, full bug/architecture record in CLAUDE.md's "Studio MCP
  bridge" section.
- **Verified twice, not just built**: once at build time with a real `tools/list` call
  through the full chain (curl → Caddy → supergateway → `StudioMCP.exe` → Studio's
  Assistant plugin), and again live in a hand-over check (2026-08-13) with a real Claude
  Code session executing Luau inside an actually-open Studio place ("Place1") through the
  published bridge and getting a real result back — confirms the whole chain works for an
  actual remote MCP client, not just a synthetic curl probe.
- **Still open / explicitly deferred**: wiring code-docker's own Claude Code to this
  bridge (a code-docker-side change, out of scope here — see Milestone 7 above) and Rojo
  install/config (see "Remaining for a future session" above, genuinely not started).

### 9. Process supervision: switched to `supervisord` — done, 2026-08-13
- `entrypoint.sh`'s hand-rolled `wait -n`/background-job process supervision replaced with
  `supervisord`, matching code-docker's own `supervisord.conf` + `supervisord.d/*.conf`
  split — full record in CLAUDE.md's "Process supervision: switched to `supervisord`"
  section (layout, service-script conventions, the `critical-watchdog` program that
  replicates the old "container dies if labwc/wayvnc/dbus dies" behavior since supervisord
  has no built-in equivalent).
- **Verified live**, not just built: killing `labwc` with `SIGKILL` brought the whole
  container down and `restart: unless-stopped` cleanly recovered it (confirmed via
  `RestartCount` and supervisord's own log); killing the `mcp-bridge` wrapper process
  directly only restarted that one program (supervisord's `autorestart=true`) without
  touching `dbus`/`labwc`/`wayvnc` or the container's uptime, and the bridge came back
  healthy within seconds.

### 10. VNC embedding: noVNC + websockify added in front of wayvnc — done, e2e-verified with one known open issue, 2026-08-19
- `[program:novnc]` (websockify, `--web` serving noVNC's static client) now runs
  alongside `wayvnc`, proxying the same session as HTTP+WebSocket on `VNC_WEB_PORT`
  (default 6080) instead of raw RFB — this is what lets code-docker-router's App
  Routes/Dev Proxy (stock Caddy, HTTP/WS-only) reach it at all, since raw RFB can't be
  proxied by either. wayvnc itself is unchanged (still the native-client path,
  `VNC_PORT`). Full design/isolation reasoning in CLAUDE.md's "VNC embedding" section;
  router-side decision record (why noVNC over KasmVNC/Guacamole/Selkies) in
  code-docker's own `.claude/backlog/router-vnc-tab-plan.md`.
- **Verified live, 2026-08-19**: real build, a real integrated stack (this repo +
  code-docker + router via `EXTRA_INCLUDE`), a real App Routes entry
  (`vnc-only:6080` → `/app/studio-vnc/`), and a real browser driven through that path —
  confirmed network isolation (only router can reach `vnc-only`), confirmed the noVNC UI
  and all its assets resolve correctly under the App Routes subpath, and confirmed a full
  connect with live mouse-cursor movement through the tunnel.
- **Known open issue found by that test**: with `VNC_PASSWORD` set, the browser
  connection fails (`Unsupported security types (types: 262)`) — a real version mismatch
  between wayvnc's offered RFB security types and what this noVNC release implements, not
  a wiring bug. Full root-cause and the recommended interim mitigation (gate the App
  Routes entry with tinyauth instead of relying on `VNC_PASSWORD` for the web path) are in
  CLAUDE.md's "VNC embedding" section — not yet fixed, tracked there.

## Open questions (resolve before or during implementation, not blocking the plan itself)

- ~~sway vs labwc for the compositor~~ — **resolved 2026-08-11: switched to `labwc`.**
  Built and verified with sway through Milestone 3, then switched at the owner's request
  — sway's borderless tiling is unfriendly for typical users vs. labwc's decorated,
  movable/resizable floating windows + right-click app menu. Re-verified working after
  the switch (GPU accel, app menu, full Vinegar/Studio relaunch with login persisted).
  See CLAUDE.md's "Window manager: `labwc`, not `sway`" section for the concrete
  differences (socket name, config paths, output-resolution mechanism) and revert path.
- VNC vs RDP vs both — `wayvnc` is the natural default for a wlroots headless compositor
  (`research/03` §2); weston's built-in RDP backend is the documented fallback if RDP is
  specifically wanted later, but note it forfeits wayvnc entirely (weston doesn't
  implement `wlr-screencopy`) — pick one remote-protocol family, don't try to run both
  against the same compositor.
- All previously-open base-distro/GPU-vendor questions are resolved — see "Resolved
  decisions" above.
