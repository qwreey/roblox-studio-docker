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
the WM (a real browser window, visibly usable over VNC) — nothing more.** Do not install
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
   - **Headless Wayland (`WLR_BACKENDS=headless` + `wayvnc`), NOT X11/Xvfb** —
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

## Window manager: `labwc`, not `sway` — switched 2026-08-11

Milestones 1–3 were built and verified with `sway` (a tiling WM). Switched to `labwc` (a
stacking/floating WM, wlroots-based like sway — think Openbox for Wayland) afterward, at
the owner's request: sway's borderless tiling is unfamiliar/unfriendly for typical users
compared to normal decorated, movable, resizable windows with a right-click app menu.
Re-verified working after the swap (GPU accel via `vkcube`, the app menu, and a full
Vinegar/Studio relaunch with login persisted — all confirmed). Both compositors are
wlroots-based, so this was a genuinely small change, not a re-architecture — same
`WLR_BACKENDS=headless`/`WLR_LIBINPUT_NO_DEVICES=1` mechanism, same GPU path, same
`wayvnc` capture mechanism. If labwc ever needs reverting, `sway`/`swaybg` +
`config/wm/sway-config` are one `git checkout` away (see git history at the commit before
this switch) — this was deliberately tried as a low-risk, easily-reversible experiment.

Concrete differences from the sway setup documented elsewhere in this file:
- Config lives at `/etc/xdg/labwc/rc.xml` (window/keybind behavior) and `/etc/xdg/labwc/
  menu.xml` (the right-click root menu — Terminal/Roblox Studio/Chromium entries),
  copied from `config/wm/labwc-rc.xml` and `config/wm/labwc-menu.xml`. Not `/etc/sway/
  config` anymore.
- The Wayland socket labwc creates is **`wayland-0`**, not sway's `wayland-1` —
  `entrypoint.sh`'s socket-detection loop already handles this generically (globs for any
  `wayland-*`), no fix needed there, but manual `docker exec` commands that hardcode
  `WAYLAND_DISPLAY=wayland-1` (including older text in this file/`SETUP.md` written
  during the sway era) need `wayland-0` instead now.
- The headless output is still named **`HEADLESS-1`** (this is `wlroots`' own headless
  backend, not compositor-specific — unchanged), but labwc doesn't have sway's simple
  `output * resolution ...` config directive to size it. `entrypoint.sh` now runs
  `wlr-randr --output HEADLESS-1 --custom-mode 1920x1080` after labwc starts — note
  **`--custom-mode`, not `--mode`**: the headless backend only pre-registers a default
  1280x720 mode with no fixed EDID mode list to pick from, so `--mode` (select from
  existing modes) fails with "unknown mode" where `--custom-mode` (define a new one)
  succeeds.
- No `swaymsg`-equivalent IPC tooling was set up for labwc (sway's own IPC protocol is
  sway-specific) — for scripted/debugging window inspection, use generic Wayland
  protocol tools (`wlr-randr` for outputs) rather than looking for a labwc IPC socket.
- Windows are **not maximized by default** (floating, sized by the app) — this is the
  actual point of the switch (real movable/resizable windows), not an oversight. Double-
  click a titlebar or `W-f` (per `config/wm/labwc-rc.xml`) to maximize/unmaximize.

### Taskbar: `waybar` + `wofi` added on top, same day

labwc itself ships no panel — the right-click menu alone didn't fully match what was
asked for ("application menu and window list... like lxqt"). Added a real always-visible
taskbar:
- **`waybar`** (bottom panel, `config/wm/waybar-config.jsonc` + `waybar-style.css` →
  `/etc/xdg/labwc/waybar-*`) — a `custom/launcher` module (left, "☰ Menu" button) and a
  `wlr/taskbar` module (center, live window list — click an entry to focus/toggle it,
  confirmed working) plus a clock (right).
- **`wofi --show drun`** is what the launcher button runs — a proper GTK app-launcher
  showing every installed `.desktop` entry (search-filterable). Confirmed: shows
  Terminal/Chromium/Vinegar as expected, but also every other `.desktop` file that
  happened to ship with unrelated dependency packages (Avahi browsers, Qt V4L2 utilities,
  `xgps`, `lstopo`, etc.) — cosmetic clutter, not a functional problem, not cleaned up.
- **Foot didn't ship its own `.desktop` file** — added a minimal one
  (`/usr/share/applications/foot.desktop`, generated inline in the `Dockerfile`) so the
  terminal actually shows up in wofi's list at all.
- Both are started via **labwc's own autostart mechanism**
  (`config/wm/labwc-autostart` → `/etc/xdg/labwc/autostart`, a plain shell script labwc
  runs on startup — same XDG-search-path pattern as `rc.xml`/`menu.xml`), not
  `entrypoint.sh` — matches labwc's own idiom for "launch my companion programs," keeps
  `entrypoint.sh` compositor-agnostic.
- **Wofi's list items need a double-click to launch**, not a single click (single click
  only *selects*/highlights the row — this matches a broader pattern already noted
  elsewhere in this file: some GTK-ish UI in this stack treats a first click as
  focus/select-only). Real VNC clients handle this fine (a normal double-click); only
  scripted single-click-based test tooling needs to account for it.

## Crash-loop bug: stale Wayland socket survives `docker restart` — fixed 2026-08-12

If the container ever gets into a tight restart loop with logs like `labwc is up on
WAYLAND_DISPLAY=wayland-0` immediately followed by `wlr-randr failed to set output mode`
and wayvnc's `Failed to connect to WAYLAND_DISPLAY` — this is the bug, not a new one.
Root cause: `docker restart` (including the automatic restart from `restart:
unless-stopped`, which is what actually triggered this) reuses the **same container
writable layer** — only the PID namespace is fresh, `/tmp` is not wiped. If labwc ever
dies for any reason (a GPU driver hiccup from something else hammering `/dev/dri`
concurrently — in the one confirmed case, Vinegar/Studio actually running — is one
plausible trigger, but the bug is in what happens *next*, not in whatever kills labwc
the first time), its old `wayland-0`/`wayland-0.lock` socket files are left behind in
`/tmp/xdg-runtime`. `entrypoint.sh`'s socket-detection loop just checks *a file matching
`wayland-*` exists* — a stale leftover satisfies that instantly, before the new labwc
process has created its own live socket, so every downstream client (`wlr-randr`,
`wayvnc`) immediately fails to connect against the dead file. Since the stale file
persists across restarts (same writable layer), **every subsequent restart re-triggers
the same failure in under a second, forever** — the container never recovers on its own
once this starts. Confirmed via `find`/timestamp comparison inside a live-but-crashing
container: `wayland-0`/`wayland-0.lock` had timestamps from an earlier run while `bus`
(dbus, recreated correctly by `entrypoint.sh` each start) had the current run's
timestamp. **Fix**: `entrypoint.sh` now does `rm -rf "${XDG_RUNTIME_DIR}"` before
`mkdir -p` at the very top, so no state from a previous crashed run can survive into the
next start. If this loop reappears, check whether that `rm -rf` line got reverted before
re-diagnosing from scratch. Recovery from an already-wedged container (pre-fix, or if a
future bug reintroduces this class of problem): `docker compose up -d --build` to force
recreation with a rebuilt image is *not* actually required — a plain `docker rm -f` +
`docker compose up -d` (full container recreation, not just `restart`) also clears it,
since recreation gets a fresh writable layer; rebuilding was done here anyway because
the fix itself lives in the image.

## VNC client compatibility: wayvnc needs both VeNCrypt and RSA-AES offered — fixed 2026-08-12

Setting only `enable_auth`/`username`/`password` in wayvnc's config (the original
Milestone 1 setup) makes wayvnc advertise **RSA-AES only** (RFB security types 129 and
5, confirmed via a raw handshake probe: `python3` connecting and reading the server's
security-type list directly). This is wayvnc's own default secure scheme and is exactly
what TigerVNC's `vncviewer` expects, but most other VNC clients don't implement it —
Remmina fails outright with "unknown authentication scheme". **Fix**: `entrypoint.sh` now
also generates a self-signed VeNCrypt/TLS cert (`openssl req -x509 ...`) alongside the
RSA-AES key (`ssh-keygen -m pem ...`), and sets all three of `rsa_private_key_file`,
`private_key_file`, `certificate_file` in wayvnc's config — wayvnc can advertise multiple
security types at once and let each client pick whichever it supports (confirmed:
handshake probe now shows types `[19, 129, 5]` — 19 is VeNCrypt). Both key/cert pairs are
persisted under `./data/wayvnc` (new volume) specifically so the RSA-AES TOFU fingerprint
and TLS cert stay stable across restarts — regenerating them every start would trip every
client's "host key changed" warning each time.

**Client compatibility — be precise about what's actually confirmed vs. inferred**:
**Remmina fails, confirmed directly** — first against RSA-AES alone ("unknown
authentication scheme"), then again after adding VeNCrypt (its X.509 handling wants a CA
file through a file-picker dialog rather than a plain accept/reject prompt, and this did
not end up working even with the self-signed cert supplied as its own CA — tried on both
the Flatpak and a description of native-package behavior). **A successful connection was
independently confirmed by the owner** using some other client (described as clicking
"OK" after seeing the self-signed cert's hash — consistent with GNOME's remote-desktop
client UX) — that client's exact identity was never pinned down (the owner referenced
`grdctl`, which is actually GNOME Remote Desktop's *server*-side config CLI, not a VNC
viewer, so treat this as "some other client worked," not a confirmed specific
recommendation). **TigerVNC's `vncviewer` was reasoned about but never actually
connection-tested**: confirmed wayvnc offers the right security types for it (raw RFB
handshake probe: types `[19, 129, 5]`) and confirmed the Flatpak build
(`org.tigervnc.vncviewer`) has the right sandbox permissions (`shared=network`), but no
one actually ran it against this server and watched it succeed — don't repeat "TigerVNC
is confirmed working" as fact without actually testing it first. If Remmina trouble comes
up again: don't sink more time into it specifically, it's a demonstrated
client-compatibility gap, not a misconfiguration on this side — try TigerVNC or whatever
client the owner already had success with. Username for any client is **`studio`**
(hardcoded, unrelated to the container's `root` OS user — easy to reach for `root` by
habit and get a confusing failure instead).

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
- **Switch process supervision from `entrypoint.sh`'s hand-rolled bash to `supervisord`,
  matching code-docker's own approach — requested 2026-08-13, explicitly deferred to a
  fresh session, not to be done in the same session that requested it.** `entrypoint.sh`
  has grown to juggle too much in one script: D-Bus, labwc, `wlr-randr`, wayvnc
  (including generating its RSA-AES/TLS credentials inline), and now the MCP bridge
  auto-start — all hand-supervised via a mix of `wait -n` (for the three processes whose
  death should kill the container) and a deliberately-excluded background job (the MCP
  bridge, which self-restarts on its own instead, see "Studio MCP bridge" above). The
  owner wants this replaced with `supervisord`, the same tool code-docker already uses —
  reasoning given: simpler than hand-rolled `wait -n` process-group logic, and splitting
  each responsibility into its own program entry makes both debugging (`supervisorctl
  status`/`tail` per-process instead of one merged log stream) and future changes easier.
  **Before starting this**: read code-docker's actual `supervisord.conf`
  (or equivalent) to match its conventions rather than inventing a new pattern — its
  exact location wasn't looked up as part of queuing this item, don't assume a path.
  Scope likely includes: a `[program:]` entry per current backgrounded process (dbus,
  labwc, wayvnc, mcp-bridge — Vinegar/Studio itself may or may not move in, given it's
  deliberately manual/interactive today, see "Conventions" below), preserving the
  existing behaviors that matter (container exits if labwc/wayvnc/dbus die, MCP bridge
  does NOT take the container down if it dies, wayvnc's cert-generation and
  `VNC_BIND_ALIAS` resolution logic still need to run before wayvnc itself starts).

## Future code-docker integration — groundwork only, added 2026-08-12

The owner is planning to eventually add this project's Roblox Studio container as a new
service inside `~/Projects/code-docker` (a separate, much larger infra project — see the
"standalone" note at the top of this file, which still holds: this project has zero
build/runtime dependency on code-docker, this section is about code-docker optionally
*consuming* this project later, not the reverse). The intended shape, confirmed with the
owner 2026-08-12: this container would join `code-docker-internal` (for a future MCP
bridge to Roblox Studio's official MCP server, and for routing Studio's `HTTPService`
calls through code-docker's router) **and** a second, dedicated `internal: true` network
shared only with code-docker's `router` container, for VNC — so that code-docker's own
Claude Code agent container (a broad, less-trusted input surface: arbitrary web browsing,
npm/pip installs, MCP tool calls) can never reach VNC, only a human via router. This
mirrors a real, fact-checked precedent in code-docker's own git history (commit `a2f0420`,
`code-docker-forwards` network — since reverted only because the original collision it
guarded against stopped being possible, not because the mechanism didn't work): a
dedicated `internal: true` network + a network alias on the sensitive container + that
container binding its service to the alias's own resolved IP (via `getent hosts`) instead
of `0.0.0.0`. Docker's network model makes this real L3 segmentation (a container on
network B has no route to network A's subnet unless also attached to A), not just policy.

**What's actually done here (this project only, nothing in code-docker touched):**

- **`VNC_BIND_ALIAS`** (`entrypoint.sh`, optional env var): when set, resolves via
  `getent hosts "$VNC_BIND_ALIAS"` and binds wayvnc to that specific IP instead of
  `0.0.0.0`. **Fails closed** — `exit 1` if the alias never resolves, rather than silently
  falling back to `0.0.0.0` (a silent fallback would quietly defeat the entire point of
  the variable). **Unset by default** in the root `docker-compose.yml` (passed through as
  `VNC_BIND_ALIAS: "${VNC_BIND_ALIAS:-}"`), which reproduces today's exact `0.0.0.0`
  behavior — zero regression to the working Milestone 1-3 standalone setup.
- **`poc/code-docker-integration/`**: a self-contained proof-of-concept, entirely within
  this repo, that mimics code-docker's relevant network shape with two mock `sleep
  infinity` containers (`router-mock`, `code-docker-mock`) standing in for code-docker's
  real `router`/agent containers, plus the *real* `roblox-studio` image (built from this
  repo's own root) with `VNC_BIND_ALIAS` set — validating the actual production
  `entrypoint.sh` code path, not a toy stand-in. `verify.sh` confirms, via
  `docker compose exec`: (a) `code-docker-mock` cannot even resolve the VNC-only alias
  (DNS-level isolation), (b) `code-docker-mock` cannot TCP-connect to the VNC port via the
  internal-network alias (bind-address isolation — nothing listens there), (c)
  `router-mock` *can* reach the VNC port via the VNC-only alias (isolation is targeted,
  not total breakage), (d) `code-docker-mock` can still resolve the plain internal-network
  alias (the internal network itself isn't broken). Confirmed passing 4/4, 2026-08-12 —
  see that directory's own compose file for the exact network/alias layout to copy from
  when the real code-docker-side integration eventually happens.

**Explicitly deferred, not part of this groundwork**: the real code-docker-side
attachment (editing code-docker's actual `docker-compose.yml`/networks — a separate
future task, deliberately not done here per the owner's own scope boundary). The MCP
bridge itself was originally deferred alongside it but was actually built the next day —
see "Studio MCP bridge" below; what's *still* deferred is wiring code-docker's own Claude
Code to it (that's a code-docker-side change, out of scope here for the same reason as
the network attachment). A dedicated low-privilege Roblox account (not the owner's own)
is the intended login for whatever eventually runs behind that MCP bridge — mirrors the
"agent-dedicated git account, separate from the owner's own" principle already documented
as a recommendation (not yet implemented) in code-docker's own
`.claude/backlog/agent-sandbox-hardening.md`.

## Studio MCP bridge — built and verified end-to-end, 2026-08-13

Roblox Studio's built-in MCP server (Assistant > "Manage MCP Servers") is stdio-only and
single-machine by design (see `research/roblox-mcp.md`). `supergateway` (stdio↔Streamable
HTTP) + `caddy` (bearer-token auth, the only published MCP port) now bridge it out —
`config/mcp/mcp-bridge.sh`, `config/mcp/studio-mcp-stdio.sh`, `config/mcp/Caddyfile`, full
walkthrough in `SETUP.md`'s "Studio MCP over the network" section. Auto-started by
`entrypoint.sh` whenever `MCP_TOKEN` is set (added 2026-08-13, after the initial build —
unlike Vinegar/Studio, nothing about the bridge itself requires Studio to already be
running, so there was no reason to keep it manual once proven stable) and
self-restarting on crash (`mcp-bridge.sh`'s own loop, not part of `entrypoint.sh`'s core
`wait -n` set — a bridge crash must never take down labwc/wayvnc/Studio). Confirmed by
killing `caddy` mid-session and watching both processes respawn within ~2s with the
connection still fully functional afterward. Two more things worth knowing if this needs
touching again:

- **`StudioMCP.exe` is invoked directly, not through the `mcp.bat` launcher Studio
  generates** (the path Roblox's own docs point Windows/macOS MCP clients at,
  `%LOCALAPPDATA%\Roblox\mcp.bat`). That `.bat`'s if/else has a real cmd.exe batch bug —
  `else` sits on its own line instead of the same line as the preceding `)`, which
  cmd.exe's parser requires. Confirmed by direct testing: it still runs `StudioMCP.exe`
  fine on the common path (the hardcoded version folder exists), but throws a stray
  "Syntax error: unexpected ELSE" once that process exits and control returns to the
  batch script. Not a risk worth taking on a channel `supergateway` parses as
  newline-delimited JSON-RPC. `studio-mcp-stdio.sh` gets `mcp.bat`'s one genuinely useful
  property (surviving a Vinegar/Studio version bump — Vinegar prunes old
  `versions/version-*` folders on update, per Milestone 3's install log) by globbing for
  the current version folder itself, without going through cmd.exe at all.
- **Verified with a real `tools/list` call, not just a handshake**: `curl` through Caddy's
  bearer-token gate → supergateway → `studio-mcp-stdio.sh` → `StudioMCP.exe` → WebSocket →
  Studio's own Assistant plugin returned genuine Studio-specific tools (`upload_image`,
  `search_game_tree`, etc.) — confirms the whole chain, not just that the proxy process
  starts. `StudioMCP.exe`'s own architecture is worth knowing if debugging this again: it
  hosts a WS server *and* connects to it as a client itself (self-loop) rather than the
  Studio plugin connecting directly — a "WS host connection error: Connection refused"
  logged immediately on startup is just that self-connect racing its own listener binding
  and retrying ~1.4s later, not a real failure.

## Conventions

- **Build/run**: `docker compose build`, then `VNC_PASSWORD=... docker compose up -d`
  (or copy `.env.example` to `.env`). Single service named `studio` in
  `docker-compose.yml`, image built from the root `Dockerfile`. VNC published on host
  port 5900 (override via `VNC_PORT`).
- **Base image**: `archlinux:latest` (matches host/owner's other infra). Milestones are
  added as straight-line layers in `Dockerfile` + startup logic in `entrypoint.sh` — no
  supervisord/multi-process-manager layer yet; `entrypoint.sh` backgrounds each core
  process (labwc, wayvnc, dbus) and `wait -n`s on **just those three**, so the container
  dies if any one of them dies. Revisit this if the process count grows enough to make
  that fragile (e.g. once Vinegar/Chrome are added). The Studio MCP bridge
  (`mcp-bridge.sh`, see its own section above) is a deliberate exception — it's
  backgrounded too but excluded from that `wait -n` set, since it's non-critical and
  already self-restarting on its own; a bridge crash must never take the whole container
  (and Studio's actual session) down with it.
- **Display server: `labwc` (headless) + `wayvnc`, not Xvfb/X11** — see the "Where to
  start" section above for the X11-vs-Wayland reasoning, and "Window manager: `labwc`,
  not `sway`" above for why labwc specifically (was sway through Milestone 3, switched
  after). Key env vars `entrypoint.sh` sets: `XDG_RUNTIME_DIR=/tmp/xdg-runtime` (Wayland
  requires this to exist and be writable — nothing works without it, including
  `vulkaninfo`/`vkcube`), `WLR_BACKENDS=headless`, `WLR_LIBINPUT_NO_DEVICES=1` (skips
  libinput device enumeration so wlroots never calls into libseat — no seatd/logind
  needed), `WLR_RENDERER=gles2` (real GPU accel via the render node once `/dev/dri` is
  passed through). The headless backend's virtual output is always named
  **`HEADLESS-1`** (this is wlroots' own naming, not compositor-specific) — `wayvnc`'s
  `--output=HEADLESS-1` and the `wlr-randr` resolution-setting call should hardcode this,
  it's stable as long as only one output is created. The Wayland *socket* labwc creates
  is `wayland-0`, not sway's old `wayland-1` — don't confuse the two.
- **`labwc`'s binary needs `CAP_SYS_NICE`** (`docker-compose.yml` → `cap_add:
  [SYS_NICE]`) — same as sway before it, ships with `cap_sys_nice=ep` as a file
  capability, which is not in Docker's default capability set even for a root process;
  without this, `exec()` fails outright with `Operation not permitted`, not a runtime
  error.
- **Config layout** (per `plan.md`'s proposed tree): `config/wm/labwc-rc.xml` →
  `/etc/xdg/labwc/rc.xml` (window/keybind behavior) and `config/wm/labwc-menu.xml` →
  `/etc/xdg/labwc/menu.xml` (right-click app menu) in the image. Other `config/*`
  subdirs (`remote/`, `claude/`) exist but are still empty — no `wayvnc` config file
  committed, since its password comes from `$VNC_PASSWORD` and `entrypoint.sh` generates
  `/tmp/wayvnc.cfg` at container start instead (same pattern as the old x11vnc setup:
  never bake a secret into the image/repo). `config/wm/sway-config` is still present in
  the repo (unused, kept only as the fallback path if labwc ever needs reverting — see
  "Window manager" section above).
- **Host Docker daemon requires a DNS override** to build/run at all on this host —
  `/etc/docker/daemon.json` → `{"dns": ["8.8.8.8"]}` (not project-specific config, outside
  this repo, but necessary to know if things start timing out again). This has been
  through two revisions — see "Resolved decisions" in `plan.md` for the first
  (build-time, `1.1.1.1`+`8.8.8.8` together) and "Milestone 3" above for the second
  (`1.1.1.1` turned out to be unreachable from this host's containers entirely, dropped).
  Current, correct value is `8.8.8.8` only.
- **Vinegar/Studio is not auto-started by `entrypoint.sh`** — it's launched manually
  (over VNC in real use, via the labwc right-click menu's "Roblox Studio (Vinegar)"
  entry; during development, via `docker exec`). To launch it from a shell, all of these
  env vars must be set (the ones `entrypoint.sh` itself exports for labwc/wayvnc aren't
  automatically visible to a fresh `docker exec` shell):
  ```
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-0 HOME=/root \
         DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/xdg-runtime/bus"
  vinegar &
  ```
  (Note `wayland-0`, not `wayland-1` — that was sway's socket name, labwc's is
  different.) Consider adding an autostart mechanism once the project is stable enough
  that always-launching-Studio-on-boot is actually wanted — not done yet since this was
  still under active iteration.
- **Verifying a headless Wayland milestone without a real VNC client**: `docker exec` in,
  `export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-0; grim /tmp/shot.png`
  (`grim` — not in the image by default, install ad hoc with
  `pacman -Sy --needed grim` inside the running container for a one-off check), then
  `docker cp` it out and view it. To test real GPU acceleration specifically, run
  `vkcube` (from `mesa-demos`) the same way — on a broken setup (e.g. the old
  Xvfb/X11 approach) it hard-crashes with "No DRI3 support detected"; on a working one it
  prints "Selected GPU 0: <real GPU name>" and renders. There's no `swaymsg`-equivalent
  IPC for labwc — use generic Wayland protocol tools instead (`wlr-randr` for output
  info/resolution, already used by `entrypoint.sh` itself).
