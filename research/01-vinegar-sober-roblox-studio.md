# Vinegar / Sober architecture, GPU requirements, and container prior art

Scope: `vinegarhq/vinegar` (Roblox Studio bootstrapper) and `vinegarhq/sober` (Roblox
Player-only runtime), whether either has been containerized before, and what a
container would actually need to give Wine/Studio a working display + GPU path.

## 1. Vinegar (`vinegarhq/vinegar`) — architecture

Vinegar is "an open-source, configurable, fast bootstrapper for running Roblox Studio on
Linux" — Go, two windows (Manager for config, Bootstrapper for progress), source at
[github.com/vinegarhq/vinegar](https://github.com/vinegarhq/vinegar). It is **not**
Player-capable anymore in practice (see §5) — as of 2024 it is effectively a
Studio-only tool, even though the binary/docs still mention "Roblox."

- **Wine prefix**: created at `~/.local/share/vinegar/prefix/` by default; Vinegar manages
  prefix creation, registry settings, and DPI/WM settings itself
  ([DeepWiki: Getting Started](https://deepwiki.com/vinegarhq/vinegar/2-getting-started)).
- **Deployment**: downloads/updates the Roblox Studio Windows binary itself (channel-aware),
  no manual installer step.
- **FFlags**: user-editable via the Manager window ("Edit FFlags"); Vinegar also
  auto-generates renderer-selection FFlag pairs (see below) rather than requiring the user
  to hand-write them for basic renderer switching.
- **Renderer backends** — six selectable options, confirmed via
  [DeepWiki: Renderer and Graphics Settings](https://deepwiki.com/vinegarhq/vinegar/4.3-renderer-and-graphics-settings):
  - `D3D11` — Direct3D 11 via WineD3D (**default**), translated through Wine's own
    OpenGL-backed D3D implementation, not a modern translation layer.
  - `DXVK` (2.7.1 pinned) and `DXVK-Sarek` (1.11.0-async) — DirectX→Vulkan translation,
    downloaded/cached/extracted into the prefix by Vinegar automatically.
  - `Vulkan` — Roblox's own native Vulkan renderer path (an `FFlagDebugGraphicsPreferVulkan`
    flag, not a Wine/DXVK concept).
  - `D3D11FL10` — Direct3D 11 feature level 10, a compatibility fallback.
  - `OpenGL` — legacy WineD3D-over-OpenGL fallback. Roblox itself has stated the native
    OpenGL renderer is deprecated/being removed
    ([DevForum thread](https://devforum.roblox.com/t/opengl-screenshots-are-glitchy/3820540/3),
    referenced in [vinegar#679](https://github.com/vinegarhq/vinegar/issues/679)).
  - **No VKD3D** — Roblox's engine targets D3D11 (or its own native Vulkan path), never
    D3D12, so Vinegar has no VKD3D-Proton dependency at all. This differs from typical
    Proton/Steam game compatibility layers.
  - FFlags are generated per-renderer as `FFlagDebugGraphicsPrefer{X}` /
    `FFlagDebugGraphicsDisable{X}` pairs; DXVK/DXVK-Sarek both map to the `D3D11` FFlag
    since they're DX-translation layers, not a distinct Roblox-side renderer.
- **Env vars**: `WINE_D3D_CONFIG=renderer=vulkan` for the relevant modes,
  `DXVK_LOG_LEVEL`, `DXVK_STATE_CACHE_PATH`, `VK_LOADER_LAYERS_ENABLE` (custom Vulkan
  layer support).

Studio vs. Player at the architecture level: Studio is the same underlying Windows PE
binary/Wine-execution model as Player was, just a heavier GUI shell (dockable panels,
plugin system, toolbars) layered on the same DirectX/Vulkan-via-Wine rendering
foundation — there is no separate graphics stack for Studio, but Studio's docking/child-window
UI is specifically what breaks under several of the display-server workarounds below
(§5), in a way Player's fullscreen-only UI never triggered.

## 2. Sober (`vinegarhq/sober`) — Player only, fundamentally different tech

Sober's own README/site is explicit: **"Use Vinegar for Roblox Studio"** — Sober is
scoped to Player only, no Studio support exists or is planned
([Sober FAQ](https://vinegarhq.org/Sober/FAQ/index.html)).

Sober is **not** Wine-based at all. It's "a specialized runtime for the x86_64 Android
APK of Roblox" that "bridges the small gap between Android and Linux, allowing for a
native unofficial port" ([GamingOnLinux coverage](https://www.gamingonlinux.com/2024/08/sober-is-a-new-way-to-play-roblox-on-linux-from-the-vinegar-team/),
[tuananh.net writeup](https://tuananh.net/2024/02/01/roblox-on-linux/)). Concretely, from
a Sober crash log obtained in this research
([sober#1276](https://github.com/vinegarhq/sober/issues/1276)):

- It's an SDL2 application: `trying video backend preference: wayland,x11` /
  `using video backend: wayland` — SDL's own native Wayland backend is what gets it onto
  a Wayland session, with X11 as a fallback SDL backend, **not** XWayland-as-a-crutch.
  This is why Sober is correctly described as usable natively on both X11 and Wayland: it's
  an ordinary SDL/GTK Linux desktop app, same as any other cross-platform SDL title —
  there is no Windows binary involved and no Wine graphics-driver limitation to work around.
- It links Roblox's Android renderer directly against desktop EGL/Vulkan (`libEGL`,
  Mesa loader) rather than going through any Android emulation layer like Waydroid — a
  community comparison confirms Sober "works flawlessly on both X11 and Wayland" while
  Waydroid "requires Wayland" and has no Nvidia support at all (per
  [sober#762](https://github.com/vinegarhq/sober/issues/762) discussion and surrounding
  coverage).

**Conclusion for the user's Studio-in-container plan: Sober's Wayland-nativeness does not
carry over to Vinegar/Studio.** Sober is Wayland-native because it's a normal Linux SDL
app with no Windows binary in the loop. Studio's Wayland story is instead gated entirely
on **Wine's own graphics driver** (`winex11.drv` vs. the newer `winewayland.drv`), which is
a completely separate, much less mature axis — detailed in §5. There is no
Sober-derived shortcut Vinegar could adopt; the two projects share branding/org but not a
rendering stack.

## 3. Container/Docker prior art

**No dedicated Vinegar/Sober/Roblox-Studio Docker project exists.** Confirmed via GitHub
code + repo search (`vinegar roblox docker`, `roblox studio wine docker` → 0 repos) and
web search — nothing beyond generic Rojo/RCC build-tool containers (which don't run
Studio itself, just CLI build/sync tooling — e.g.
[snovikov/docker-rojo](https://github.com/snovikov/docker-rojo),
[worships/rcc-docker](https://github.com/worships/rcc-docker)) turned up.

The one directly on-topic discussion is
**[vinegarhq/vinegar#411 "Running roblox in a container?"](https://github.com/vinegarhq/vinegar/issues/411)**
(April 2024, closed): a user proposed running Roblox in a Windows container (citing
[dockur/windows](https://github.com/dockur/windows), a QEMU-in-Docker full Windows VM
project) as a way to dodge the incoming Wine ban. Maintainer `lunarlattice0` closed it
same-day with a single line: **"out of scope for vinegar."** No technical discussion
followed. Two things to note: (a) this predates the actual Wine block landing and was
about Player, not Studio; (b) the suggested workaround (a real Windows VM, not Wine) is a
fundamentally different approach than what this project wants (a Wine-based Linux
container) — it sidesteps Wine-detection entirely by running genuine Windows, at the cost
of needing full virtualization (KVM) rather than a plain container.

Generic (non-Roblox) prior art for "Wine GUI app in a headless Docker container +
browser-viewable display" is well-trodden and directly reusable as a pattern, e.g.
[solarkennedy/wine-x11-novnc-docker](https://github.com/solarkennedy/wine-x11-novnc-docker)
(Xvfb + x11vnc + noVNC) and `seancheung/alpinewine` on Docker Hub (Wine + Xvfb/X11/noVNC
on Alpine). None of these are Roblox/Vinegar-specific or address GPU acceleration — they
assume software-rendered Xvfb is good enough, which is very unlikely to be true for
Roblox Studio's viewport (see §4).

## 4. Minimum graphics requirement / what a container needs

Vinegar/Wine's default renderer (`D3D11` via WineD3D→OpenGL) and the DXVK/Vulkan
renderers both ultimately need a **real GPU device with a working Mesa/Vulkan driver
stack** reachable from inside the container — not because Xvfb/X11 itself does 3D, but
because Vulkan surface *presentation* (via `VK_KHR_xcb_surface`) is separate from Vulkan
*device/compute access* (via a DRM render node, `/dev/dri/renderD1xx`). Practically this
means: bind-mount `/dev/dri` into the container, install the matching Mesa/NVIDIA
userspace Vulkan ICD + OpenGL driver, and the actual window presentation surface (Xvfb,
a nested Xwayland, or a full compositor) is a mostly-orthogonal concern from GPU compute.

Evidence that this is a hard requirement, not just a performance nicety, from a Sober
crash under ChromeOS Crostini's `virgl` virtual GPU
([sober#1276](https://github.com/vinegarhq/sober/issues/1276)):

```
info: Roblox: ... [FLog::SurfaceController] Mode 6 failed: Unable to load Vulkan API
libEGL warning: failed to get driver name for fd -1
libEGL warning: MESA-LOADER: failed to retrieve device information
FATAL: Crash: Sober couldn't find a supported graphics device. You may need to install
additional drivers to make it work.
```

Vulkan initialization hard-failed on a `virgl` (SPICE/crosvm virtio-gpu) device even
though `glxinfo` reported a working `virgl` OpenGL renderer — Vulkan-over-virgl (i.e.
venus) either wasn't present or wasn't being picked up correctly in that environment. The
same issue's resolution was forcing OpenGL mode + Wayland backend via Flatpak
permissions, not fixing the virgl/Vulkan path itself — i.e. **the actual fix was "stop
requiring Vulkan," not "make Vulkan work under this virtual GPU."** This is a directly
relevant data point for the parallel virgl-focused research thread (`02-virgl-gpu-virtualization-feasibility.md`
in this same research set): a naive virgl setup without venus (Vulkan-over-virgl) support
is exactly the failure mode hit here.

Software rendering (llvmpipe, no GPU at all): explicitly discussed as a fallback in
[vinegar#679](https://github.com/vinegarhq/vinegar/issues/679) — a user with an Nvidia
GPU considered `llvmpipe` as a workaround for a driver bug and dismissed it themselves:
**"I could try llvmpipe, but that isn't performant."** No one in that thread reported
llvmpipe as literally non-functional for Studio's WineD3D/OpenGL path (unlike the Vulkan
case above, which hard-crashes without a real device) — so pure software rendering
*might* be usable for basic Studio UI/editing (not gameplay-speed viewport work) via the
OpenGL/WineD3D renderer specifically, but Vulkan/DXVK renderers should be assumed to
require a real GPU render node with a working Vulkan ICD, full stop.

**Bottom line for container design**: plan on passing through a real `/dev/dri` render
node with a functioning Vulkan ICD (Mesa RADV/ANV/Nvidia, or venus-backed virgl if that
research thread confirms it works) rather than relying on Xvfb/software rendering alone —
this matches the standard pattern used by cloud-rendering Docker setups (VirtualGL-style),
which is a separate, well-solved problem from the *display protocol* question in §5.

## 5. Known Wine/Studio-specific issues on Linux — window management, display server, and the anti-cheat risk

### Display server dependency — this is the single biggest open problem for Studio specifically

Vinegar today effectively **requires an X11 display** (a real Xorg session, or XWayland
under Wayland) — Wine's native Wayland driver (`winewayland.drv`) exists but is
explicitly called out by Vinegar's own docs and issue tracker as **not stable enough for
Studio yet**:

- Wine 9.22 (Nov 2024) enabled `winewayland.drv` by default in upstream Wine builds
  ([Phoronix](https://www.phoronix.com/news/Wine-9.22-Released)); Wine 10 improved it
  further. But per Vinegar's own
  [Troubleshooting page](https://vinegarhq.org/Vinegar/Troubleshooting.html) and
  [vinegar#263 RFC](https://github.com/vinegarhq/vinegar/issues/263): **"XWayland cannot
  simulate cursor locks or constraints, preventing the cursor from locking in Roblox
  Player under certain circumstances and breaking camera rotation in Roblox Studio's
  edit mode. ... Wine's Wayland driver currently doesn't support any of these
  functionalities [either]."** I.e. neither XWayland-rootless nor Wine's native Wayland
  driver correctly implement pointer-lock/constraint APIs that Studio's viewport camera
  needs — this is a real, currently-unsolved gap, not a config issue.
- **Docking is a second, separate, chronic problem**, independent of Wayland vs. X11:
  Studio's dockable panel/plugin-window system relies on Wine's "Virtual Desktop" mode
  (an emulated single-window desktop-in-a-window) as the standard workaround — plain
  rootless X11 without Virtual Desktop frequently breaks docking "for the vast majority
  of desktop environments" per the
  [Troubleshooting page](https://vinegarhq.org/Vinegar/Troubleshooting.html). Virtual
  Desktop itself has known bugs (menus turn invisible after interacting with another
  toplevel window; UI clipped if resized below configured resolution) — see
  [vinegar#805 "Replace Virtual Desktop with rootful Xwayland"](https://github.com/vinegarhq/vinegar/issues/805).
- A 2023–24 effort to fix both problems at once via **rootful Xwayland** (`Xwayland
  -host-grab`, nested X11 session with its own minimal WM, giving Wine a real X11
  environment even under a Wayland host) got promising results in prototyping — cursor
  locking was made to work via a software-cursor hack
  ([vinegar#263](https://github.com/vinegarhq/vinegar/issues/263)) — but **was never
  shipped**: a follow-on attempt to use Xephyr as a portable nested-X-server fallback for
  plain X11 sessions hit Wine crashing with DRI3 errors
  ([vinegar#805 comments](https://github.com/vinegarhq/vinegar/issues/805)), and there is
  no evidence in the current source tree or recent release notes (`v1.9.0`–`v1.9.4`,
  Oct 2025–Jun 2026) that rootful Xwayland integration ever landed — a GitHub code search
  for `xwayland` in the `vinegarhq/vinegar` repo returns nothing. As of today Vinegar
  users are still routed to manual workarounds (enable Virtual Desktop; or for X11,
  untick "Allow the window manager to control the windows"; or switch to a plain X11
  session).
- **Still-open, unresolved issue**: [vinegar#950 "Studio Docking Issue on XWayland"](https://github.com/vinegarhq/vinegar/issues/950)
  is open as of this research, confirming the problem persists in current releases.

**Implication for containerizing Studio**: Vinegar itself does not spawn/manage its own
nested display server the way one might hope — it's a thin bootstrapper that expects a
working `DISPLAY` (X11) to already exist, and its recommended fixes are host-desktop-environment
config tweaks, not something a container entrypoint can trivially replicate end-to-end.
A container-based deployment should plan to run a **real Xorg session or Xvfb acting as a
genuine X11 display** (not attempt Wine's Wayland driver, and not attempt a Wayland
compositor + XWayland-only setup) and additionally **enable Wine's Virtual Desktop mode**
for Studio specifically to get usable docking — this is a known, currently-recommended
workaround, not a novel one this project would be inventing. Expect docking/menu-visibility
glitches regardless per the open issues above; there is no fully-clean current
configuration for Studio's dockable UI on Linux.

There's no evidence Wine/Vinegar needs a display to be present at prefix-*creation* time
specifically (prefix creation is mostly registry/directory setup) — the display
requirement is a runtime rendering issue, not a bootstrap-time one. This wasn't
independently verified against source, but no issue or doc surfaced a "prefix creation
needs a display" failure mode distinct from the general "Studio needs a working X11
target to render into at all" requirement above.

### Anti-cheat / integrity check risk — the most important finding for this whole plan

**Roblox Player is actively blocked under Wine; Roblox Studio currently is not, but with
an explicit no-guarantee caveat from Roblox itself.** Per the
[2024 Roblox Block FAQ](https://vinegarhq.org/Home/rol_faq.html) (Vinegar's own official
page on this) and confirmed via
[vinegarhq/vinegar#397](https://github.com/vinegarhq/vinegar/issues/397):

- Since March 2, 2024, **Roblox Player is blocked from running under Wine at all** —
  Roblox's Byfron/Hyperion anti-cheat added a deliberate Wine-detection block, triggered
  by "Wine-based exploits... abusing the weakened version of Hyperion on Wine."
  Bypass attempts are described as leading to automatic account bans, with **no known
  working bypass** as of the FAQ's writing.
- **Roblox Studio is not currently protected by Hyperion at all** ("it's only used for
  game development") and continues to function under Wine via Vinegar.
- Direct quote carried in the FAQ: Roblox **"is not considering adding Hyperion to Studio
  currently, we cannot say that it will hold true in the future."** This is Roblox's own
  stated position, not speculation — Studio-under-Wine is explicitly a "works today, no
  promises tomorrow" situation from Roblox's side.
- Separately, the FAQ notes Roblox "may sometimes include breaking changes into Studio
  that result in several days of downtime" — Studio-on-Wine support is best-effort and
  can regress with any Roblox-side update, independent of anti-cheat.

**No evidence was found of any Studio-specific ban/detection risk today** (unlike
Player) — Studio genuinely has no active anti-cheat client-integrity layer as of this
research. But given the explicit "no guarantee for the future" statement, and that this
plan involves a **second, dedicated "AI" account** performing automated/scripted actions
(a pattern that trips fraud/anti-abuse heuristics on essentially every online platform
independent of anti-cheat), two risks are worth flagging even though neither is
Vinegar/Wine-specific and neither was confirmed in the sources gathered here:
1. Roblox could add Hyperion/Byfron to Studio at any point, per their own stated
   ambiguity, which would break this entire plan the same way it broke Player.
2. Running a second account through an automated/scripted (MCP-driven) workflow from a
   container/server environment is a distinct account-standing risk from the
   Wine-detection question — this is a general platform-ToS/fraud-detection concern, not
   something Vinegar's docs address at all, and wasn't independently researched here.

## Sources

- [github.com/vinegarhq/vinegar](https://github.com/vinegarhq/vinegar) — main repo/README
- [DeepWiki: vinegarhq/vinegar — Getting Started](https://deepwiki.com/vinegarhq/vinegar/2-getting-started)
- [DeepWiki: vinegarhq/vinegar — Renderer and Graphics Settings](https://deepwiki.com/vinegarhq/vinegar/4.3-renderer-and-graphics-settings)
- [github.com/vinegarhq/sober](https://github.com/vinegarhq/sober) — main repo/README
- [vinegarhq.org/Sober/FAQ](https://vinegarhq.org/Sober/FAQ/index.html)
- [vinegarhq.org/Vinegar/Troubleshooting](https://vinegarhq.org/Vinegar/Troubleshooting.html)
- [vinegarhq.org/Home/rol_faq.html](https://vinegarhq.org/Home/rol_faq.html) — 2024 Roblox Block FAQ
- [vinegarhq/vinegar#397 — Roblox on Linux Deprecation Notice](https://github.com/vinegarhq/vinegar/issues/397)
- [vinegarhq/vinegar#411 — Running roblox in a container?](https://github.com/vinegarhq/vinegar/issues/411) (closed, "out of scope")
- [vinegarhq/vinegar#263 — RFC: Xwayland rootful mode](https://github.com/vinegarhq/vinegar/issues/263)
- [vinegarhq/vinegar#805 — Replace Virtual Desktop with rootful Xwayland](https://github.com/vinegarhq/vinegar/issues/805)
- [vinegarhq/vinegar#950 — Studio Docking Issue on XWayland](https://github.com/vinegarhq/vinegar/issues/950) (open)
- [vinegarhq/vinegar#679 — NVIDIA OpenGL Does Not Work as an X11 WineD3D Renderer](https://github.com/vinegarhq/vinegar/issues/679)
- [vinegarhq/sober#1276 — Sober couldn't find a supported graphics device on Crostini virgl](https://github.com/vinegarhq/sober/issues/1276)
- [vinegarhq/sober#762 — Suggest Waydroid as an alternative](https://github.com/vinegarhq/sober/issues/762)
- [Phoronix — Wine 9.22 Enables Wayland Driver By Default](https://www.phoronix.com/news/Wine-9.22-Released)
- [GamingOnLinux — Sober is a new way to play Roblox on Linux](https://www.gamingonlinux.com/2024/08/sober-is-a-new-way-to-play-roblox-on-linux-from-the-vinegar-team/)
- [tuananh.net — Roblox on Linux](https://tuananh.net/2024/02/01/roblox-on-linux/)
- [devforum.roblox.com — Vinegar: The Better Way to Run Roblox on Linux](https://devforum.roblox.com/t/vinegar-the-better-way-to-run-roblox-on-linux/2224394)
- [devforum.roblox.com — OpenGL screenshots are glitchy (Roblox deprecating native OpenGL)](https://devforum.roblox.com/t/opengl-screenshots-are-glitchy/3820540/3)
- [github.com/snovikov/docker-rojo](https://github.com/snovikov/docker-rojo) — Rojo CLI container (build tooling only, not Studio)
- [github.com/worships/rcc-docker](https://github.com/worships/rcc-docker) — RCC container (unrelated to Studio GUI)
- [github.com/solarkennedy/wine-x11-novnc-docker](https://github.com/solarkennedy/wine-x11-novnc-docker) — generic Wine+Xvfb+noVNC pattern
- [github.com/dockur/windows](https://github.com/dockur/windows) — QEMU-based full Windows-in-Docker (suggested alternative in vinegar#411, not what this project wants)
