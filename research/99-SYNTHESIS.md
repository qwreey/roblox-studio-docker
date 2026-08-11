# Synthesis: Roblox Studio in a container, for code-docker

Written 2026-08-10 after 5 parallel research passes (see `01`–`05` in this directory).
This is the actual recommendation — read this first, dive into the sub-reports for
citations/detail on any specific claim.

## Top-line verdict

**Feasible, but not the way originally imagined.** Two of the user's starting
assumptions don't survive contact with the research and had to be overturned:

1. **VirGL is a dead end.** It's a VM-transport technology (crosses a KVM/hypervisor
   boundary), not a plain-Docker-container technology. The one non-VM escape hatch
   (`vtest`) is virglrenderer's own upstream-acknowledged *testing/CI harness*, carries
   only OpenGL at usable quality, and its Vulkan path (Venus-over-vtest) is explicitly a
   developer convenience with no production users found anywhere. Roblox Studio's
   DXVK/native-Vulkan renderers need real Vulkan — a Sober (sibling project) crash log
   on ChromeOS Crostini's own virgl device shows exactly this failure mode: OpenGL
   worked over virgl, Vulkan hard-failed. → **02, 05**
2. **A Wayland compositor is the wrong display layer for Roblox Studio specifically**,
   even though it's the *right* answer in isolation for "headless GUI container without
   systemd." Vinegar/Wine currently has no working cursor-lock/pointer-constraint
   support under either Wine's native Wayland driver *or* rootless XWayland — this
   breaks Studio's edit-mode camera rotation, a core interaction, not an edge case. A
   2023–24 effort to fix this via rootful Xwayland got promising prototype results but
   was never shipped upstream (still open: `vinegarhq/vinegar#950`). Vinegar's own
   currently-recommended workaround is Wine's "Virtual Desktop" mode, which works on
   plain X11 just as well as under XWayland — so the Wayland layer buys nothing for the
   one app (Studio) whose display requirements are actually the hard part of this
   project. → **01** vs **03** (03 didn't have this Vinegar-specific finding when it
   made its recommendation — see "Reconciling 01 vs 03" below)

Both of these push the design toward something *simpler* than what was originally
proposed, not more complex: **plain X11 (Xvfb + a lightweight window manager) with
direct `/dev/dri` passthrough**, no Wayland compositor, no GPU-virtualization layer.

## Reconciling 01 vs 03: X11, not Wayland, for this specific app

Report 03 did a thorough, correct survey of headless Wayland compositors and landed on
sway/labwc + wayvnc as the best answer to "how do I avoid GNOME's systemd problem" — and
that framing is right. But report 01 separately discovered that **Vinegar/Wine-hosted
Roblox Studio has app-specific display-server requirements that a generic Wayland
recommendation doesn't satisfy**: neither rootless XWayland nor `winewayland.drv`
support pointer lock/constraints, so Studio's camera rotation breaks under both. The
fix Vinegar itself currently ships and recommends (Wine's Virtual Desktop mode — an
emulated single-window desktop-in-a-window) is orthogonal to Wayland vs. X11; it works
the same either way. Once Virtual Desktop mode is in play regardless, the extra
complexity of a Wayland compositor + XWayland stack stops buying anything for Studio
specifically, while still carrying Wine-Wayland's own immaturity risk (report 03's own
finding: an *open* NVIDIA bug causes gray/hung `winewayland.drv` windows in D3D11/DXVK
apps — exactly Studio's renderer class).

**Revised recommendation: skip the Wayland compositor for this project entirely.** Use
what report 01 independently flagged as already-proven prior art
(`solarkennedy/wine-x11-novnc-docker` — Xvfb + a WM + x11vnc, cited in 01 §3) instead:

- **Xvfb** (virtual X11 framebuffer) — zero systemd/logind/dbus coupling, has been run
  in minimal Docker containers for over a decade. This is *not* the same failure mode
  that broke GNOME: GNOME's problem was gnome-shell/mutter's session machinery (GDM,
  systemd-logind session tracking, dbus portals), not "X11 vs Wayland" as an axis. Bare
  Xvfb has none of that machinery.
- **A lightweight EWMH window manager** (openbox, i3, or fluxbox — anything that isn't
  a full desktop shell) for basic window placement/tiling, so Roblox Studio's Virtual
  Desktop window and a normal Chrome window can sit side by side.
- **x11vnc** (or a KasmVNC-style X11 VNC server, per report 04's prior-art table) for
  remote viewing — the direct X11 equivalent of wayvnc, with no compositor-compatibility
  matrix to worry about (unlike wayvnc, which only works with wlroots-family
  compositors).
- **xrdp** is a legitimate RDP option here too, and *specifically more solid on X11 than
  on Wayland* — report 03 flagged xrdp's Wayland-compositor screen-capture path as
  fragile/regressing (broke on labwc after working on wayfire); its original,
  best-supported mode is exactly Xvfb/Xvnc-backed X11, which is what this design uses.
- **Wine, via Vinegar, targeting this X11 display directly** (no XWayland translation
  layer needed at all — Wine's default `winex11.drv` talks to a real X server natively),
  with **Virtual Desktop mode enabled for Studio specifically** per Vinegar's own current
  guidance. Expect the known-open docking/menu-visibility rough edges (`vinegar#950`,
  `vinegar#805`) — there is currently no fully clean configuration for Studio's dockable
  UI on any Linux display stack, container or not; this is not something the container
  design can fix, only Vinegar upstream can.
- **Chrome** — runs perfectly well on plain X11 (its X11 backend is by far its most
  mature Linux path, far more so than the newer Wayland/Ozone backend report 03 found
  still has rough GPU-acceleration edges). No native-Wayland requirement being given up;
  X11 was always going to work fine for Chrome too.

GPU acceleration is unaffected by this change — `/dev/dri` passthrough + DRI3 (the
mechanism report 05 and KasmVNC's own docs describe) works identically under Xvfb+X11 as
it would under a Wayland compositor; report 01 §4 already establishes this is the
correct GPU path regardless of display-server choice, and its Vulkan-hard-requirement
finding (DXVK/native-Vulkan renderers need a real device — no software-render fallback)
stands as-is.

*If Wine's native Wayland driver matures enough to fix pointer-lock (watch
`vinegarhq/vinegar#950` and `#263`) this recommendation should be revisited — the
Wayland/wayvnc research in report 03 remains valid and ready to reuse at that point,
just not the right choice today.*

## Recommended architecture (concrete)

```
New sibling container: code-docker-studio (subtree e.g. code-studio/, own Dockerfile/CLAUDE.md
— matches this repo's router/, code-dind/ convention. Naming is illustrative, not decided.)

Attached to: code-docker-internal ONLY (no code-docker-external — this is a rendering/compute
service being reached, not something that needs internet egress itself)
Network alias: e.g. "studio" — reachable as studio:<port> from code-docker, and from processes
running *inside* dind's own nested Docker daemon, without folding this into dind itself.

Inside the container (all as supervisord programs, following this repo's per-feature-program
pattern):
  - Xvfb                          (virtual X11 display, no GPU/monitor needed)
  - a lightweight WM (i3/openbox) (window placement — Studio + Chrome side by side)
  - x11vnc  and/or  xrdp          (remote viewing/control — human + browser-automation tooling)
  - Vinegar (Roblox Studio)       (Virtual Desktop mode on, DXVK or native-Vulkan renderer)
  - Chrome                        (real windowed instance, extensions enabled)
  - Claude Code (with --chrome)   (MUST be co-located with Chrome — see below)

GPU: /dev/dri device passthrough (Intel/AMD: works uniformly via in-container Mesa, no host
driver-version pinning needed) OR NVIDIA Container Toolkit/CDI (NVIDIA hosts only — the one
real per-vendor branch). Detected once, not hand-tuned per host. No VirGL/vtest anywhere.
```

**Why not fold into `code-docker-dind`, despite the user's instinct to group it there**
(report 05's reasoning, which holds independent of the X11-vs-Wayland change above): dind
is already the highest-privilege container in the stack (`privileged: true`, owns the
inner Docker daemon) and this repo's own docs already frame that as a trust bar to be
protective of, not casual about. A Wine/DXVK/browser stack is a large, crash-prone,
third-party-app attack surface that has nothing to do with `dockerd` — bundling it in
mixes fault domains for no benefit. This repo already has the answer for "group
functionality under one trust tier without merging containers": router keeps
netgate/tailscale/dev-proxy/tinyauth as *separate supervisord programs* sharing one
container only because they genuinely share both trust tier *and* the boundary-crossing
network position. The GPU/Studio container shares neither of dind's actual reasons for
being privileged (no Docker socket, no `NET_ADMIN`, no host-namespace access) — it just
needs `/dev/dri` and a published VNC/RDP port. "Reachable from inside dind" is fully
achieved via the network alias, without paying dind's fault-domain cost.

## Critical risks to flag before investing implementation effort

These are business/product risks, not solved by any container design choice — surfaced
by report 01 and worth the user's explicit attention:

1. **Roblox Studio has no anti-cheat today, but Roblox's own stated position is
   non-committal about the future.** Player has been Wine-blocked (Hyperion/Byfron)
   since March 2024 with automatic bans for bypass attempts; Roblox's own FAQ says of
   Studio: *"we are not considering adding Hyperion to Studio currently, we cannot say
   that it will hold true in the future."* This entire plan works today and could break
   with zero notice, independent of anything built here.
2. **A dedicated, MCP/automation-driven "AI" account is a distinct fraud-detection risk**
   from the Wine-detection question above — scripted account behavior trips anti-abuse
   heuristics on most platforms regardless of anti-cheat. Not researched in depth here
   (out of scope for infra research), but worth the user's own risk assessment before
   committing real account infrastructure to this.
3. **Claude-in-Chrome's native-messaging architecture is a hard requirement, not a
   nice-to-have**: Chrome and the Claude Code process it talks to *must* run as
   processes on the same OS/container (confirmed via Anthropic's own closed-as-declined
   devcontainer issue, `anthropics/claude-code#25506`, and the WSL unsupported case,
   which is the identical failure class). This is why Claude Code is listed as a
   component *inside* the new container above, not on the host or in `code-docker`
   itself — there is no supported remote-bridge mode, and the unofficial community
   bridges found are fragile proof-of-concepts not worth depending on. This constraint
   is satisfied by construction once everything is co-located, but is worth
   understanding *why* before changing the topology later.
4. This is a thinly-documented deployment shape for Claude-in-Chrome (a "real window,
   but on a virtual/remote display" setup) — smoke-test the extension connection
   (`claude --chrome`, confirm it reports Enabled/Installed) early in the actual target
   container, before building anything else on top of the assumption that it works.

## What each sub-report is for (if you need the detail/citations)

- `01-vinegar-sober-roblox-studio.md` — Vinegar's renderer options (DXVK/DXVK-Sarek/
  native Vulkan/D3D11FL10/OpenGL, no VKD3D), why Sober's Wayland-nativeness doesn't
  transfer, the cursor-lock/docking display-server findings that drove the X11 decision
  above, and the anti-cheat risk.
- `02-virgl-gpu-virtualization-feasibility.md` — full technical case for why virgl/
  Venus/GFXStream/rvgpu don't work outside a VM in production, and what Distrobox
  actually does instead (direct `/dev/dri` for Intel/AMD, NVIDIA Container Toolkit for
  NVIDIA).
- `03-headless-wayland-compositor-vnc-rdp.md` — the Wayland compositor survey (sway/
  labwc/weston/cage/Hyprland/wayfire compared), still valid/reusable reference if
  Wine's native Wayland driver matures later; not the chosen path for now per the
  reconciliation above.
- `04-chrome-in-container-for-claude-mcp.md` — Claude-in-Chrome's native-messaging
  architecture, why co-location is mandatory, and the neko/Kasm/linuxserver prior-art
  comparison for "real browser window streamed to a viewer."
- `05-gpu-passthrough-comparison-and-architecture-fit.md` — the Intel/AMD-vs-NVIDIA
  passthrough comparison and the original sibling-container placement reasoning (still
  valid; only its tentative endorsement of a VirGL-provider pattern is superseded by
  02's harder "no" verdict).

## Suggested next step (not started — research only, per instructions)

When ready to move from research to implementation: read this synthesis plus the 5
sub-reports, then plan a new subtree (own `Dockerfile`/`CLAUDE.md`/`config/` following
the `router/`/`code-dind/` convention) implementing the architecture above, starting
with a minimal smoke test in this order: (1) Xvfb + WM + x11vnc alone, confirm remote
viewing works; (2) add `/dev/dri` passthrough, confirm `glxinfo`/`vulkaninfo` see the
real GPU inside the container; (3) add Vinegar + Roblox Studio, confirm it launches and
renders with Virtual Desktop mode on; (4) add Chrome + Claude Code, confirm
`claude --chrome` connects; (5) only then wire it into `docker-compose.yml` as a real
service with the internal-only network + alias.
