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
     upstream ever lands a fix for either of those issues. (Since 2026-10-05 Studio runs
     on winex11 inside a Wine virtual desktop instead, and rotation works there — see
     "Panels: Wine virtual desktop".)
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
Getting there required chasing down six independent, stacked bugs — all now fixed and
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
6. **`update-desktop-database` is never run for Vinegar's own `.desktop` file**, which
   breaks the *second half* of the browser login — found on the live deployment
   2026-08-28, long after the rest of this list (the first five were all found in one
   sitting on 2026-08-11; this one only surfaces on a *first* login, and until then every
   restart came back up on an already-persisted token). The handoff back from the browser
   is a `roblox-studio-auth:` deeplink claimed by `org.vinegarhq.Vinegar.desktop`, which
   Vinegar's `make install` installs but does not register: `update-desktop-database` is
   in Vinegar's separate `make host` target (a distro package's post-install hook territory
   — an image build has to call it itself). So `mimeinfo.cache` carried only the pacman-
   installed apps, GIO could not resolve the scheme, and the flow died exactly at the
   "Open Roblox Studio" click: Chromium opens, login succeeds, the button does nothing.
   The **only** trace anywhere was a single line in Vinegar's own log
   (`/root/.cache/vinegar/logs/<ts>.log`, mounted at `./data/vinegar-cache/logs/`):

   ```
   gio: roblox-studio-auth:/?code=...: The specified location is not supported
   ```

   (immediately preceded by Chromium's `dbus/xdg/request.cc … Request ended (non-user
   cancelled)` — Chromium tries the XDG portal first, then falls back to `xdg-open`, which
   under `XDG_CURRENT_DESKTOP=GNOME` — required by item 3 above — delegates to `gio open`.)
   Fixed in the `Dockerfile` with a `update-desktop-database` + explicit `xdg-mime default`
   step placed after every `.desktop` file, guarded by a `grep` on `mimeinfo.cache` so a
   future Vinegar upgrade that renames the association fails the build instead of shipping
   a silently broken login. **Do not diagnose this with `xdg-mime query default` — it reads
   the `.desktop` files directly and answers `org.vinegarhq.Vinegar.desktop` even while
   completely broken.** `gio mime x-scheme-handler/roblox-studio-auth` is the check that
   reflects reality ("No default applications for ..." when broken).

None of these are specific to *this* one login attempt — they're structural, and the fix
for each is now in the actual image/compose config (not something done ad hoc in a shell
that will be lost on rebuild). If Studio's login breaks again after a rebuild, suspect one
of these six having been silently reverted before re-investigating from scratch.

**Edit-mode camera rotation works** under the current setup (winex11 through XWayland,
inside a Wine virtual desktop — see "Panels: Wine virtual desktop"): a right-drag in an
open place's viewport turned the camera, measured over VNC 2026-10-05. The pointer-lock
limitation the Milestone 1/2 pivot accepted was about `winewayland.drv`, which Studio no
longer runs on. Not measured: whether the rotation speed feels right through a VNC
client's absolute pointer.

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
  `output * resolution ...` config directive to size it. `labwc-service.sh` runs
  `wlr-randr --output HEADLESS-1 --custom-mode "$DESKTOP_RESOLUTION"` after labwc starts
  (the starting size — VNC clients resize it later, see "Panels: Wine virtual desktop") — note
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
- **The menu button toggles rather than launching directly** (`config/wm/wofi-toggle.sh`
  → `/etc/xdg/labwc/wofi-toggle.sh`, added 2026-08-28). Waybar's `on-click` used to be
  `wofi --show drun` verbatim, so every click spawned another launcher stacked on the
  last one — clicking the button N times gave N identical menus (measured in a live
  container: 1 → 2 → 3 wofi processes on three clicks). wofi has no single-instance
  mode of its own, and the usual saving grace — wofi closing on focus loss — never
  fires here because the click that takes focus away lands on waybar's own *layer
  surface*, not a real window, so the open wofi keeps keyboard focus and simply gets
  buried. The wrapper is a one-liner (`pkill -x wofi || exec wofi --show drun`), which
  also gets normal start-menu behavior for free: a second click closes the menu.
  Verified in a live container — five clicks alternate 1/0/1/0/1, never 2.

### Titlebars were dead: one `<mousebind>` in `rc.xml` wiped labwc's whole default mouse table — fixed 2026-08-29

Reported as "탑바가 안 잡히고 X가 안 눌린다": windows could not be dragged by their
titlebar, the titlebar's close/minimize/maximize buttons did nothing, double-click-to-
maximize did nothing, and border/corner resizing was dead — on *every* window, since the
first day labwc landed. The right-click desktop menu kept working the whole time, which
is why this read as "some windows are broken" rather than "the mouse config is gone."

**Root cause**: labwc loads its built-in keybind/mousebind tables **only when `rc.xml`
declares none of its own in that category** — bindings in the config *replace* the
defaults, they do not add to them. `config/wm/labwc-rc.xml` carried exactly one
mousebind (`Root` + Right press → `ShowMenu root-menu`) and nothing else, so labwc kept
that single binding and dropped every default `Titlebar`/`TitleBar`/`Close`/`Iconify`/
`Maximize`/`Top`/`Bottom`/`Left`/`Right`/`*Corner` binding — i.e. all window management
that happens with the mouse. Same trap on the keyboard side: the four `<keybind>`s in
that file cost the defaults `A-F4` (close), `A-Space` (window menu), `A-S-Tab` and
`W-Left/Right/Up/Down` (snap/maximize). labwc ships **no** `/usr/share/labwc/rc.xml` to
compare against (the defaults are compiled in, `load_default_{key,mouse}_bindings()`),
and it logs nothing when it drops them, so there is no artifact anywhere pointing at
this — the config just looks like a small, reasonable file.

**Fix**: `<default />` as the first child of both `<keyboard>` and `<mouse>` in
`config/wm/labwc-rc.xml`. That loads the built-ins explicitly, after which everything
else in the file is additive. The custom `Root` right-click mousebind was then dropped
entirely — labwc's own defaults already bind desktop right-click to `root-menu`
(`menu.xml`), so it was redundant *and* destructive. **Do not remove those two
`<default />` lines**, and be aware that adding any future custom mousebind is only safe
because they are there.

**Verified end to end** against a live container driven over VNC with a raw RFB client
(pointer/key events straight into wayvnc, `grim` for verification), first with the config
bind-mounted for iteration, then re-run against a real `docker compose build` of the
image: titlebar drag, titlebar double-click maximize, close/minimize/maximize buttons,
left-border and corner resize, restore-from-taskbar, root right-click menu, titlebar
right-click window menu, `A-Space`, `A-F4`, `W-Return`, `W-Left` snap — all confirmed
working after, all confirmed dead (except the root menu) before. That RFB-client approach
is worth reaching for again: `grim` alone can only show you that nothing moved, it can't
tell you whether the click was delivered.

**Found in the same pass — waybar's window list only showed the focused window's title.**
Every other entry rendered as a blank button. Not a waybar config bug: `format` really was
`"{icon} {title}"` and the label was present (the buttons were full-width), but GTK's own
button styling beats the `color` inherited from `window#waybar` and dims an unfocused
button's label to nearly its own background. Fixed in `config/wm/waybar-style.css` with
explicit `#taskbar button label` / `#taskbar button.active label` colors (plus a brighter
`.active` background, since the old `#45475a`-vs-`#313244` pair was nearly
indistinguishable once both labels were legible).

**Applying this to a live deployment**: both files are `COPY`ed into the image, so a
`docker compose build` + container **recreate** is required — `docker restart` alone keeps
the old image's `/etc/xdg/labwc/*`. (For a quick check without a rebuild, bind-mount
`config/wm/labwc-rc.xml` over `/etc/xdg/labwc/rc.xml` and `pkill -HUP -x labwc` — labwc
re-reads its config on SIGHUP.)

## Panels: Wine virtual desktop over XWayland — 2026-10-05

Reported as: plugin windows can't be resized, and Studio's Qt panels can't be dragged out
and docked back. Studio now runs on `winex11.drv` through labwc's XWayland, inside a Wine
virtual desktop filling the screen above waybar. Each piece is load-bearing:

- **Why not plain Wayland (`winewayland.drv`, what Studio ran on before)**: Wayland never
  tells a client where its windows are, and only the compositor may move them. Qt's
  docking decides where a dragged panel lands from the panel's global position, so a
  torn-off panel was placed by labwc (centred), didn't follow the pointer, and never
  showed a drop target. Not fixable from this side.
- **Why not plain X11 windows either**: measured — a torn-off panel jumped to the
  top-left corner and stayed there. Only the virtual desktop, where Wine itself manages
  every Windows window like Windows does, made all three work: tear off (follows the
  pointer), dock back (drop on another panel's title bar or a dock edge; dropping into
  the middle of a panel's content doesn't dock), and resizing a floating panel by its
  edge. `winewayland.drv` silently ignores `explorer /desktop=`, so the virtual desktop
  needs winex11.
- **Why winex11 never worked before: a Kombucha bug.** Kombucha's own patch
  `0017-winex11-Don-t-hide-cursor-under-X11-sessions` does
  `strcmp(getenv("XDG_SESSION_TYPE"), "wayland")` with no NULL check. Nothing here sets
  `XDG_SESSION_TYPE`, so winex11 segfaulted during init (inside `__wine_unix_lib_init`,
  right after `Display settings are now handled by: NoRes`), the loader logged only
  `Initialization of L"winex11.drv" failed`, and Wine fell through to winewayland —
  which is also why this used to look like "Kombucha prefers Wayland". Fixed by
  `ENV XDG_SESSION_TYPE=wayland` in the Dockerfile. No registry `Graphics` key is needed:
  Wine's default order already tries x11 first. Found by putting gdb on the spawned
  `explorer.exe` (wrap `lib/wine/x86_64-unix/wine-preloader` in a script that `exec`s
  gdb for `*explorer*` argv) — the fault's `rsi` pointed at the string `"wayland"` in
  winex11.so's rodata. Report drafted, not filed:
  `research/upstream-reports/kombucha-xdg-session-type.md`.
- **Sized to the area above waybar, not the whole screen**: a virtual desktop exactly the
  screen's size makes Wine go fullscreen (`is_desktop_fullscreen`), covering waybar. One
  waybar-height shorter (`desktop-size.sh` reads the height from waybar's own config) stays
  an ordinary window, which `labwc-rc.xml`'s window rule pins to the top-left with no
  server-side titlebar.
- **Wine only accepts a desktop size it lists.** `explorer /desktop=<uuid>,WxH` asks for
  WxH, but the modes inside a virtual desktop are a fixed list of standard resolutions plus
  the screen size plus HKCU `Software\Wine\Explorer\Desktops` `"Default"`; anything else
  fails silently (`initialize_display_settings: Failed to set primary display settings`)
  and the desktop stays at the screen size — fullscreen again. So that `"Default"` value is
  kept equal to the desktop size (`set_wine_default_desktop_size`: `wine reg` while the
  prefix's wineserver runs, an appended `user.reg` section otherwise).
- **Following the VNC client's size.** Wine ignores window-manager resizes of the desktop
  window (`winex11.drv/window.c`, "ignore window manager config changes in virtual desktop
  mode"), so a resized `HEADLESS-1` (noVNC `resize=remote`, TigerVNC `SetDesktopSize`)
  alone leaves Studio cropped. The `desktop-resize` program
  (`desktop-resize-service.sh`) polls the output, waits for it to settle (a dragged
  browser window sends a burst), updates `"Default"` and Vinegar's `virtual_desktop`, and
  when Studio is up runs `desktop-resize.exe` (built from `config/desktop-resize/` in its
  own Dockerfile stage) inside Studio's desktop. It does the same for every newly launched
  Studio desktop, writing `"Default"` through the now-running wineserver first — the only
  way a fresh install's first launch (prefix and desktop created back to back) or a
  recreated prefix gets the right size. The tool reports `ok`/`refused` through
  `/tmp/desktop-resize.status`, since the `wine explorer` launcher drops its exit status.
  That tool's comments carry the three Wine
  quirks it works around — maximized windows aren't refitted, the taskbar isn't taken out
  of the new work area, and the desktop process resets the work area ~1s after the change
  — each found by tracing the tray rect and work area step by step. ~2s per resize;
  measured shrinking and growing with a place open (viewport kept rendering) and with a
  five-step burst (only the last size applied). Measurement trap: starting *anything* with
  `wine explorer /desktop=<existing name> <program>` resets that desktop's work area to the
  whole desktop, so a work area read by a tool launched that way says nothing about what
  Studio sees — desktop-resize.exe sets it last for exactly this reason.
- **Floating panels kept above the main window** (`wine-owned-popups`, a small X client
  run as its own supervisord program). A floating panel is a popup owned by Studio's main
  window, which Windows keeps above its owner; upstream Wine doesn't inside a virtual
  desktop. On focus, `winex11`'s `set_input_focus` raises the focused window's X window to
  the top of the desktop's X children with no regard for what it owns, and the Expose that
  follows makes the server move it above them in the win32 z-order too
  (`X11DRV_Expose` → `update_window_zorder`) — never through `SetWindowPos`, so its
  owned-popup handling never runs, and `SetWindowPos`/`BringWindowToTop` from outside
  can't undo it. Reproduced with a bare Win32 owner+popup on upstream wine-11.15 as well as
  Kombucha, so not Studio's doing. The daemon restacks any X window whose
  `WM_TRANSIENT_FOR` (Wine sets it to the owner's X window) sits above it directly above
  it again, and the resulting Expose fixes the win32 order the same way it broke it. Upstream
  report drafted, not filed: `research/upstream-reports/wine-owned-popup-zorder.md`
  (with a bare Win32 repro, `owned-popup-zorder-test.c`).
- **How the setting reaches existing deployments**: Vinegar's `virtual_desktop` key.
  `entrypoint.sh` adds it to `config.toml` once (marker
  `~/.config/vinegar/.virtual-desktop-added`, so an owner who deletes the line keeps it
  deleted — the first-run seeding never touches an existing file); `desktop-resize`
  keeps a present, non-empty value in step with the screen from then on. A Studio
  launched by `docker exec` needs `DISPLAY=:0`, or winex11 has no display and Wine falls
  back to winewayland (SETUP.md's launch snippet carries it). `entrypoint.sh` also clears
  stale `/tmp/.X*-lock` files, which `docker restart` keeps and which pushed XWayland to
  `:1`, `:2`, ...

Side effects worth knowing: the desktop covers the spot where labwc's right-click root
menu opens (waybar's "☰ Menu" launcher reaches the same apps) and puts Kombucha's Windows-style taskbar at its own bottom
edge, above waybar — that one lists Wine's windows, waybar only the desktop as a whole.
Floating panels never show up on it (they're tool windows, which a taskbar doesn't list);
the extra "RobloxStudio" entries it does show are some other Studio windows, unidentified,
and clicking them did nothing in testing. It stays because it's the only clean way back to a
minimized Studio. Turning it off would need a fixed desktop name (Kombucha defaults
`EnableShell` on for any desktop without its own registry key, and Vinegar names each one
with a fresh UUID), and was tried on a test desktop with `EnableShell=0`: a minimized window
becomes a Win3.x-style title bar at the desktop's bottom-left that does restore, but the
desktop doesn't repaint behind it — a black rectangle where its popup was, and the title
bar left drawn after restoring. With the shell on, neither happens.
"Plugins → Plugins Folder" opens Wine's own file browser inside the desktop.

**Turning it off**: delete the `virtual_desktop` line from `data/vinegar-config/config.toml`
(the marker keeps it deleted, and `desktop-resize` leaves a config without it alone) and
relaunch Studio. Docking and floating-panel resizing break again; everything else works.

**Seen once, not explained** — check these first if they come back:
- One launch hung on a white main window right after Studio loaded its built-in plugins
  (`[FLog::StudioHangMonitor] Hang Detected` in the Roblox log, `~/.local/share/vinegar/
  appdata/Roblox/logs/`). It was the first launch on a freshly copied data directory, in
  which Vinegar also updated the prefix and installed DXVK; killing everything and
  relaunching came up fine, and it didn't recur.
- On a fresh install's first launch, the resize that shrinks the fullscreen desktop to the
  area above waybar can leave an unrepainted white strip near the desktop's bottom until
  something redraws there.
- Not tested: a second `vinegar run` while Studio is up. Vinegar names every desktop with a
  fresh UUID, so it may open a second Wine desktop window rather than join the first
  (`desktop-resize` only follows the first one `pgrep` finds).

**Debugging it again**: drive the session with a scripted RFB client
(`vncdotool` from PyPI: `vncdo -s 127.0.0.1::<port> move X Y mousedown 1 ... mouseup 1`) and
read the result with `grim` — a VNC screenshot via vncdo came back unusable. `xwininfo
-root -tree` (pacman `xorg-xwininfo`, ad hoc) shows every Wine window as a child of its
`<uuid> - Wine Desktop` X window, in X stacking order; `xprop -id` on one shows its
`WM_TRANSIENT_FOR`. For the win32 side (z-order, work area, foreground), a few-line Win32
probe built with `x86_64-w64-mingw32-gcc` and started inside the desktop
(`wine explorer /desktop=<uuid> probe.exe`) answers what X can't — mind the work-area trap
above, and that a console probe started through `cmd /c` becomes the foreground window
itself.

**File manager**: the Linux-side one is Thunar. Nautilus is pulled in by
`xdg-desktop-portal-gnome` and refuses to run as root; the Dockerfile hides it from the
launcher, removes its `org.freedesktop.FileManager1` D-Bus service (Thunar ships its
own — two in one directory and activation picks either) and makes Thunar the
`inode/directory` handler. Untested: xdg-desktop-portal-gnome implements FileChooser and
its binary references `org.gnome.Nautilus`, so a GTK/Chromium file picker going through
the portal may still fail as root. Nothing here was seen using one.

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

## VNC embedding: noVNC + websockify added in front of wayvnc — 2026-08-19

Added a browser-reachable path alongside the native-client path above, not instead of
it. wayvnc itself is unchanged — still raw RFB-only on `VNC_PORT`, still the right choice
for TigerVNC/whatever client actually worked per the section above. `websockify`
(`config/supervisor/novnc-service.sh`, `[program:novnc]`) now also runs, proxying the
same wayvnc session as HTTP+WebSocket on `VNC_WEB_PORT` (default 6080) with noVNC's
static web client (`--web`) served alongside it — visit `/vnc.html` there for a
zero-install browser VNC session. Both noVNC and websockify are release tarballs
(`ARG NOVNC_VERSION`/`ARG WEBSOCKIFY_VERSION` in the Dockerfile), not distro packages
(neither is in Arch's official repos) — same "curl a tagged tarball, build/vendor it"
pattern Vinegar above already uses, not a `git clone` (avoids a `git` dependency for a
one-time checkout).

`novnc-service.sh` mirrors `wayvnc-service.sh`'s own `VNC_BIND_ALIAS` handling exactly,
independently, for both directions it needs it: (1) as the *target* address it connects
to (must resolve the same alias wayvnc itself bound to — "localhost" would silently fail
to connect once `VNC_BIND_ALIAS` is set, since wayvnc then only listens on that resolved
IP, not loopback) and (2) as its own *listen* address (same fail-closed
resolve-or-exit-1 behavior as wayvnc — if the noVNC web port bound `0.0.0.0` while
wayvnc's raw port stayed alias-restricted, that would reopen the exact isolation gap
`VNC_BIND_ALIAS` exists to close, just through the new HTTP path instead of the old raw
RFB one). One env var segments both paths identically — see docker-compose.yml's own
comment on `VNC_BIND_ALIAS`.

This is what makes the VNC session reachable from `code-docker-router`'s App Routes/Dev
Proxy at all — both are stock Caddy (HTTP/WS-only), and can't proxy raw RFB (a binary TCP
protocol) no matter how the target is allow-listed. See code-docker's own
`.claude/backlog/router-vnc-tab-plan.md` for the full router-side design/decision record
(noVNC chosen over KasmVNC/Guacamole/a Selkies rewrite — Selkies stays backlogged, revisit
only if noVNC's software-encoding CPU cost becomes a real problem in practice) and
`docs/dev-proxy.md`/`docs/app-routes.md`'s own `ROUTER_EXTRA_ALLOWED_TARGET_HOSTS` entry
for how a target like `roblox-studio-vnc:6080` gets past router's own self-SSRF allowlist without a
router code change.

**End-to-end verified, 2026-08-19**: real `docker compose build` + a live integrated
stack (this container + code-docker + router via `EXTRA_INCLUDE`), an actual App Routes
entry (`roblox-studio-vnc:6080` → `/app/studio-vnc/`) registered through router-manager's API, and
a real browser driven through that exact path — confirmed network isolation (code-docker
container can't even resolve `roblox-studio-vnc`; router can, gets a real `RFB 003.008` banner),
confirmed the noVNC static UI + all its relative assets resolve correctly under the
`/app/studio-vnc/` subpath (no path-rewrite issues), and confirmed a full connect with
live mouse-cursor movement through the tunnel ("Connected (unencrypted) to WayVNC").

**Real finding from that test — `VNC_PASSWORD` currently breaks the noVNC path**: with
`VNC_PASSWORD` set, the connection fails in the browser with `Unsupported security types
(types: 262)`. Root-caused, not just observed: wayvnc (v0.10.1 here) offers top-level RFB
security types `[19, 129, 5]` (VeNCrypt, plus two non-standard/legacy IDs — neither
matches noVNC's `securityTypeRA2ne = 6`, the modern RSA-AES type noVNC actually
implements), so noVNC picks VeNCrypt(19) and proceeds to VeNCrypt subtype negotiation —
where wayvnc offers only subtype 262 (`X509Plain`, TLS-wrapped, needs a real client-side
X.509/TLS stack). This bundled noVNC release (1.6.0's `core/rfb.js`) implements **no**
VeNCrypt TLS subtype at all (`_isSupportedSecurityType`'s list has no 256/257/258/260/261/
262 — the closest is `securityTypePlain = 256`, cleartext, which wayvnc never offers when
a cert is configured). This isn't a config mistake on this repo's side — it's a genuine
version/feature mismatch between this specific wayvnc build and this specific noVNC
build, confirmed by a raw RFB handshake probe (`python3` socket read of the security-type
bytes) alongside the browser console error. **With `VNC_PASSWORD` unset, wayvnc offers
only type `1` (None) and the connection succeeds cleanly** — that's how the live
end-to-end pass above was actually done (temporarily, then reverted).

**Practical implication — don't rely on `VNC_PASSWORD` as the noVNC path's access
control today.** Both websockify and wayvnc's raw RFB port serve the *same* wayvnc
process, so there's no way to require auth for the web path only while leaving the native
one open (or vice versa) short of running two wayvnc instances. Until this gets a real
fix (see below), the actual gate for the browser path should be
`code-docker-router`'s own App Routes `requireAuth` (tinyauth) — leave `VNC_PASSWORD` set
for the native-client path (TigerVNC etc. still works fine, per the section above) and
know that reaching it *through noVNC* currently means either (a) tinyauth-gate the App
Routes entry and run wayvnc passwordless, accepting that anyone who reaches the raw RFB
port directly still needs no credential either way, or (b) leave `VNC_PASSWORD` set and
accept noVNC just won't connect until this is fixed. Not resolved as of this writing —
options for a real fix, not yet evaluated in depth: a newer/different wayvnc build that
can be told to offer a subtype noVNC supports; patching in a VeNCrypt TLS subtype on the
noVNC side; or simply standardizing on tinyauth as documented above and treating wayvnc's
own auth as native-client-only.

## Crash: a 0x0 remote-resize request kills wayvnc and the container — patched 2026-08-25

Found while code-docker's router switched its noVNC viewer from `resize=scale` to
`resize=remote`. With remote resizing on, noVNC forwards its own viewport size to the
server as an RFB `SetDesktopSize`, **with no lower bound of its own** — a viewer laid out
at 0x0 (an iframe hidden with `display:none`, a page that never got a layout pass) duly
asks for a 0x0 desktop. wayvnc passes it straight through as a wlr-output-management
custom mode; wlroots rejects any mode with width/height ≤ 0 as a **protocol error**, and
libwayland treats a protocol error as fatal. `wayvnc -L debug`, verbatim:

```
Client resolution changed: 0x0, capturing output HEADLESS-1 which is headless: yes
Client requested resize to 0x0, result: 4
[destroyed object]: error 3: invalid custom mode
ERROR: ../wayvnc/src/wayland.c: 269: Failed to dispatch pending
```

wayvnc then exits **0**, `critical-watchdog` correctly shuts the whole container down, and
because the offending client reconnects on its own (`reconnect=1`), the container comes
back, gets asked for 0x0 again, and dies again — a restart loop that only ends when that
client is closed. Observed for real: 30+ `RestartCount` in a few minutes off a single
browser tab.

Fixed in the `Dockerfile` by patching the vendored noVNC (`core/rfb.js`,
`_requestRemoteResize`) to skip any request below 1x1 — see that RUN's own comment,
including why it's a `sed` with a `test` guard rather than a patch file (a
`NOVNC_VERSION` bump that moves the code must fail the build, not silently drop the
guard). Verified before/after against a live session: unpatched, hiding the viewer logged
`Client requested resize to 0x0` and killed wayvnc; patched, the same action produces no
request at all and wayvnc stays up, while a normal resize (1920x1080 → 960x634) still
works.

**The guard is client-side, so it only covers clients served by this container.** wayvnc
itself is still fatal-on-bad-mode for any *other* client that asks for 0x0 — including a
browser tab still running the pre-patch `rfb.js` from before a rebuild, which has to be
reloaded before it stops killing the container. Nothing in wayvnc clamps this
(`-R`/`--disable-resizing` is all-or-nothing), and making wayvnc's death non-fatal would
mean undoing this project's deliberate "container dies if wayvnc dies" design (see
`critical-watchdog`) — so this is knowingly a mitigation, not a complete fix.

## `VNC_GPU`: wayvnc `--gpu` is opt-in, and measurably a no-op for noVNC here — 2026-08-25

`VNC_GPU` (docker-compose env → `wayvnc-service.sh`) adds wayvnc's own `--gpu` flag
(DMA-BUF capture + hardware H.264 through VAAPI). **Off by default**, and that default is
a measurement, not caution — the encoder side is genuinely present in this image:

- `neatvnc` here is linked against `libavcodec`+`libva`, `radeonsi_drv_video.so` is
  installed, and `/dev/dri` (amdgpu `card1` + `renderD128`) has been passed through all
  along. `wayvnc --gpu` starts and captures fine — no crash, nothing to fix.
- But `--gpu`'s H.264 is only used for a client that **negotiates the open-h264 RFB
  encoding**. noVNC 1.6 does implement it (WebCodecs, `core/decoders/h264.js`), gated
  twice: `window.isSecureContext` — over plain HTTP `VideoDecoder` doesn't exist, so noVNC
  never even offers H.264 — and its own real-frame probe in `core/util/browser.js`, added
  to work around browsers that claim support they don't have.
- Measured against this host (Chrome 151, AMD HawkPoint): from a secure context
  (`localhost` port-forward) the probe still failed — `VideoDecoder.isConfigSupported`
  returned `supported: true`, but decoding noVNC's probe chunk threw
  `EncodingError: Decoding error` on the hardware decoder, while
  `hardwareAcceleration: 'prefer-software'` decoded the same chunk fine. noVNC therefore
  disabled H.264 entirely, and wayvnc logged `Choosing tight encoding` with `--gpu` on.

So the flag exists to be tried from a different browser/GPU (and it costs nothing to
leave off), not because turning it on speeds anything up here. This closes out the
"먼저 `--gpu`만 켜고 VAAPI가 실제로 동작하는지 확인" item in code-docker's own archived
`router-vnc-tab-plan-done.md`: the answer is that the *encoder* side is fine and the
*browser decoder* side is what blocks it — which is also why Selkies stays the real answer
for latency-sensitive 3D interaction, not this flag.

Related, same measurement session: client-side resize worked end to end — noVNC with
`resize=remote` moved `HEADLESS-1` to the browser viewport's size and tracked later
window resizes. Studio's Wine virtual desktop can't follow that by itself; the
`desktop-resize` program makes it (see "Panels: Wine virtual desktop").

## Wine 11.16 viewport regression — Kombucha pinned to 11.15, 2026-08-28

**Pin moved to `stable+20261005101806` (wine-11.19) on 2026-10-05**: the viewport renders
on it, under the winex11 + virtual desktop setup Studio runs on now ("Panels: Wine
virtual desktop"). Not established whether 11.19 fixed the regression itself or that
setup sidesteps it — a quick look at 11.19 on `winewayland.drv` was inconclusive (the
main window stopped repainting, which may be its own problem). The record below is kept
for the next time a bump breaks the viewport.

Roblox Studio's **3D viewport renders nothing** on Kombucha `stable+20260824153321`
(**wine-11.16**). Everything else about Studio is fine: it launches, logs in, the ribbon
and menus draw, a place opens (title bar, `RobloxIDEDoc::activate`, `SceneManager:
resizing main targets to 812x675` all normal) — only the editor's document area comes up
blank. Kombucha `stable+20260809183117` (**wine-11.15**) renders correctly. Pinned via the
Dockerfile's `KOMBUCHA_VERSION` block (installs to `/opt/kombucha-pinned`) plus `wineroot`
in `config/vinegar/config.toml`. **Anything else in this image that launches Wine has to
read that same `wineroot`, not a hardcoded path** — `config/mcp/studio-mcp-stdio.sh` had
`~/.local/share/vinegar/kombucha/bin` baked into `PATH` and silently stopped working the
moment this pin landed (`exec: wine: not found`, child exits 127, bridge stays up, remote
clients see only a timeout). It parses `wineroot` out of the live `config.toml` now, so
un-pinning later needs no second edit.

**What the symptom actually is** — stating this correctly took most of the debugging time,
and every wrong framing cost hours. It is *not* a GPU/driver failure, *not* the Start Page
covering the viewport, and *not* window placement. With `DXVK_HUD=devinfo,fps` in
`[studio.env]` you can see **two** HUDs — one on the ribbon's swapchain, one at the
document area's top-left — and that second one runs at 60+ fps over an otherwise empty
area. So the viewport's own swapchain *is* being presented, at full framerate, with DXVK
drawing its opaque HUD onto it; what fails is the composite of the engine's `main targets`
render target into that backbuffer, which comes out empty. Diagnose this class of bug with
the HUD, not with screenshots of "nothing there" — a viewport that was never created and
one that presents empty frames look identical otherwise.

**Eliminated before landing on Wine** (keep this list so none of it gets re-tested):

| Variable | Result |
|---|---|
| Studio 0.734 / 0.735 / 0.736 (pinned via `forced_version`) | all broken |
| DXVK vs Roblox's native Vulkan renderer (`renderer = "Vulkan"`) | both broken |
| `winex11.drv` vs `winewayland.drv` | both broken — **invalid**: winex11 crashed on load every time (no `XDG_SESSION_TYPE`), so both runs were winewayland |
| Wine virtual-desktop on/off | both broken — **invalid** for the same reason: winewayland ignores the virtual desktop |
| Output resolution, 576x888 → 1920x1080 | all broken |
| Image packages: Mesa 26.1.6 + labwc 0.20.1 vs Mesa 26.2.1 + labwc 0.20.2 | both broken |
| Repo commits (a 2026-08-12 build of this image reproduces) | broken |
| Server-side FFlag bucket | identical on both sides of the working/broken flip |
| **Kombucha wine-11.15 vs wine-11.16** | **11.15 works, 11.16 broken** |

The flip that settled it: one known-good `vinegar-data` directory, one container, one
image, one Studio build, one FFlag bucket — only `wineroot` changed between runs, and it
reproduced in both directions. A 11.15 pin also repairs a prefix that 11.16 already
created, so recovering an existing deployment needs no prefix wipe and no re-login.

**Bisected to a single upstream commit** (same day, by building upstream Wine 64-bit-only
— Studio is x86_64-only so no multilib is needed — at two adjacent commits and swapping
only `wineroot` between them):

```
2293b0e8ca1dc36f0c89a396309997f65e5759fa  win32u: Keep unused client surfaces around
                                          and reuse them if possible.        ← BAD
ec23c07b4514adb5e953dcd230ac061a0c6b5bf5  (parent)                           ← GOOD
```

`wine-11.15-30-g2293b0e8ca1` breaks it; `wine-11.15-29-gec23c07b451` does not. The commit
makes `win32u_vkCreateWin32SurfaceKHR` adopt a cached client surface
(`get_unused_client_surface`) instead of always creating a fresh one
(`pCreateClientSurface`). Studio's viewport is a child window that recreates its surface
during startup, so it presumably gets a reused surface that isn't in the state it expects.

Worth knowing: that commit's own message describes fixing the
"`VK_SUBOPTIMAL_KHR` makes applications recreate their `VkSurfaceKHR`" problem — which is
exactly [WineHQ bug 59640](https://bugs.winehq.org/show_bug.cgi?id=59640), *"Roblox
Studio's 3D-viewport turns blank or flickers (VK_SUBOPTIMAL_KHR)"*. So this is a fix for
Studio's intermittent blank viewport that turned it into a permanent one. Expect the real
upstream fix to land in that same area.

**Reported upstream as [WineHQ bug 60248](https://bugs.winehq.org/show_bug.cgi?id=60248)**
(*"Roblox Studio 0.736: the editor never appears after opening a place"*), with the
bisect, before/after screenshots and the engine/terminal logs from both builds attached.
Bump `KOMBUCHA_VERSION` only after opening a place on the new build and seeing the
viewport render; the Dockerfile's `wine --version` test only catches a tarball that isn't
the Wine it claims to be. To bisect a future break: `~/wine-bisect/` on the dev machine is a warm Wine build tree
(clone + ccache + both bisect builds) where `build.sh <commit> <name>` produces a testable
install in a few minutes.

**Vinegar facts learned while bisecting** (verified against `vinegar` 1.9.4's source, not
guessed):

- Roblox's own engine log is **not** in the Wine prefix. Vinegar redirects Windows' "Local
  AppData" out of it (`internal/dirs/dirs.go`, `cmd/vinegar/app_wine.go`), so the logs live
  at `~/.local/share/vinegar/appdata/Roblox/logs/*.log` — that's where `[FLog::Graphics]`,
  `[FLog::D3D11SwapChain]` and the FFlag bucket's `settingsUrl` are.
- Vinegar forces `DXVK_LOG_LEVEL=warn` unless `debug = true` is set at the *top level* of
  `config.toml`, which is why DXVK never names the adapter in a default run.
- `forced_version = "version-<guid>"` skips deployment lookup and installs that GUID
  directly. Past GUIDs are no longer obtainable from `DeployHistory.txt` (it serves
  `version-hidden`), but Vinegar's own logs record them — `grep 'Using Deployment'
  ~/.cache/vinegar/logs/*.log` on an old data directory recovers them.
- `channel = "..."` did **not** reliably repoint the FFlag bucket in testing; the registry
  write it is supposed to do (`HKCU\Software\ROBLOX Corporation\Environments\RobloxStudio\
  Channel`) never landed. Use `[studio.fflags]` if a specific flag needs overriding.
- Vinegar deletes Kombucha builds it did not choose out of
  `~/.local/share/vinegar/kombucha*`, so a pinned build has to live outside that directory
  — hence `/opt/kombucha-pinned`.
- Opening Vinegar's Manager (settings) window rewrites `config.toml` from its in-memory
  state, dropping comments and hand-added keys. Don't touch it while a pin is in place.

**Applying this to an already-deployed instance**: `entrypoint.sh` seeds `config.toml`
only when it doesn't already exist, so a rebuild alone will *not* add `wineroot` to a live
deployment. Add the line by hand to `data/vinegar-config/config.toml` and restart Studio.

Worth reporting upstream to `vinegarhq/kombucha` (or Wine directly) — the repro is narrow
enough to be actionable now: wine-11.15 vs wine-11.16, same everything else.

## DNS behind router: `dns-local` — added 2026-08-27

Attached to code-docker (`roblox-studio-code-docker.yml`) this container sits on
`internal: true` networks only. Docker's embedded DNS (`127.0.0.11`) still resolves
same-network names there — `roblox-studio-vnc`, `router`, `studio` — but has no route to forward
anything else, and answers those with an **immediate, definitive SERVFAIL** rather than a
timeout. Nothing here had ever written a second nameserver, so this container simply had
no external DNS: measured on the live deployment, 0/15 lookups of
`clientsettings.roblox.com`, and Vinegar failing at launch with

```
setup: fetch: user: Get "https://clientsettings.roblox.com/v2/user-channel?...":
dial tcp: lookup clientsettings.roblox.com: Temporary failure in name resolution
```

The fix is a `dns-local` supervisord program (`config/supervisor/dns-local-service.sh`,
`priority=5`) wrapping
[qwreey/router-docker-client](https://github.com/qwreey/router-docker-client)'s shared
`dns-local/`, fetched at build time like any other piece of that kit. It runs a local
`dnsmasq --strict-order` with `127.0.0.11` and router as its two upstreams and points
`/etc/resolv.conf` at *itself* alone.

Three things about that shape are load-bearing and easy to get wrong:

- **Two `nameserver` lines in `resolv.conf` are not a fix.** Only resolvers that retry
  past a definitive SERVFAIL fail over — glibc's NSS does (`getent`), `dig` and Node's
  runtime don't. code-docker learned this the hard way first (its own
  `.claude/archive/dns-local-servfail-fix-done.md`) and this container would have
  inherited the same half-fix.
- **Pointing at router alone is not a fix either.** `wayvnc-service.sh` and
  `novnc-service.sh` resolve `VNC_BIND_ALIAS` (`roblox-studio-vnc`) with `getent` and **fail
  closed** if it doesn't resolve — deliberately, since a silent `0.0.0.0` fallback would
  defeat the network segmentation. router's dnsmasq doesn't know compose aliases, so both
  upstreams are genuinely required. That is the whole reason a local strict-order
  forwarder exists instead of a `resolv.conf` line.
- **`--strict-order` itself.** Without it dnsmasq's default "fastest responder wins"
  picks `127.0.0.11`'s instant bogus SERVFAIL every time — worse than doing nothing.

`DNS_LOCAL_ENABLED` defaults to **false** here, unlike the shared script's own default:
standalone `docker compose up` has a working `127.0.0.11` and no router to forward to.
The code-docker overlay turns it on, exactly the same opt-in shape `NETINIT_WAIT` uses.
Deliberately *not* in `critical-watchdog.conf`'s `CRITICAL_PROGRAMS` — a resolver blip
must never take the whole stack down, and its own upkeep loop already survives router
being recreated (router's IP isn't stable across recreates; it's re-resolved every 5s).

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
- **`NETINIT_WAIT` / `NETINIT_WAIT_TIMEOUT`** (`entrypoint.sh`, added 2026-08-25 as part
  of the netinit-docker migration above): when `NETINIT_WAIT=true`, `entrypoint.sh`
  blocks before starting the rest of the container until `ip route show default` shows
  a route, polling every 2s up to `NETINIT_WAIT_TIMEOUT` seconds (default `60`). On
  timeout it `exit 1`s — fail-closed, so `restart: unless-stopped` retries rather than
  letting Studio run with no egress policy in place. Needed only because a host-side
  agent (code-docker's `code-docker-netinit-docker`) can plant the route only *after*
  this container has started, leaving a window where Studio would otherwise be up with
  arbitrary outbound (HTTPService/plugins) and no netgate in front of it yet.
  **`NETINIT_WAIT` defaults to `false`** so this project keeps working standalone
  (detached from code-docker) with zero configuration — there's no provider to wait for
  in that case. `roblox-studio-code-docker.yml` sets it `true`; a plain
  `docker-compose.yml` run never sees it change. Turning it off is never "skip the
  wait even though a provider exists" — it only ever means "this deployment has no
  provider to wait for" (a standalone run), which doesn't weaken the fail-closed rule.
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

**Concrete connection mechanism designed, 2026-08-13 — see
`code-docker-integration-plan.md`** (repo root): the owner proposed a Docker Compose
`include:` chain (code-docker's `docker-compose.yml` includes an `EXTRA_INCLUDE`-named
file defaulting to an empty placeholder; a user-created `extra-include.yml` overrides
that to pull in this repo's own new `roblox-studio-code-docker.yml`, which itself
includes this repo's `docker-compose.yml`) so code-docker's upstream compose file never
needs local edits and stays `git pull`-clean. Fully validated with real
`docker compose config` runs (env-var-interpolated `include: path:`, a 3-level chain
across two repos with correct relative build-context/volume resolution, `networks:`
merge semantics — an explicit override list cleanly replaces an implicit default
network instead of adding to it — and `ports: !reset []`/`!override [...]` to
clear/replace an included service's host-published ports when needed — note `!reset`
only ever clears to empty, it does NOT accept a replacement list; `!override` is the
tag for "replace with this value", confirmed the hard way via `docker compose config`
dropping the field entirely when `!reset` was given a non-empty list).
**`roblox-studio-code-docker.yml` already exists in this repo** and now covers both
phases: Phase 1 (`studio` on `code-docker-internal`) and **Phase 2, implemented
2026-08-13/14, end-to-end verified 2026-08-18** (VNC on its own `roblox-studio-vnc`
`internal: true` network, unreachable from code-docker's agent container, reachable
only via `code-docker-router`'s `forwards:`; `ports:` is `!reset []` — neither
`VNC_PORT` nor `MCP_PORT` is host-published in this topology, see the `MCP_PORT`
paragraph below for why that's fine). Turned out the earlier assumption that this
needed code-docker-side `forwards:`/netgate code changes was wrong — real testing (in
a code-docker session, against an actual built router image + test networks, not just
reading code) showed `forwards:` already resolves any hostname router is attached to
with zero code changes, and the host-level `DOCKER-INTERNAL` firewall chain doesn't
even apply to this traffic pattern (router relaying directly between two bridges it's
a member of bypasses that chain entirely — confirmed via `nft` counters staying at
zero through a successful connection). The actual blocker was that `internal: true`
networks get no default gateway route at all, so `studio` had no way to route a reply
back to the original client — fixed originally (2026-08-13/14) by giving `studio` the
same netinit-sidecar pattern code-docker/dind already use (`netinit/` in this repo,
vendored from code-docker's own `netinit/` subtree — new `studio-netinit` service,
`network_mode: service:studio` + `NET_ADMIN`, keeps studio's default route pointed at
router). See `code-docker-integration-plan.md`'s "2026-08-18 — 실제 end-to-end 테스트
결과" section for the full real-run results from that era (RFB banner received through
router's forward, isolation confirmed via `Connection refused` from code-docker, plus a
real `roblox-studio-vnc` network-naming bug found and fixed). code-docker's repo needed
zero code changes for this feature specifically (its earlier `EXTRA_INCLUDE`/
`include:` plumbing from Phase 1 was all that was needed).

**Superseded 2026-08-25 — the `studio-netinit` sidecar is gone, replaced by a
host-side, label-driven agent on the code-docker side.** `network_mode: service:studio`
made Compose pin the sidecar to studio's *container ID* at create time; a studio
*recreate* (new ID) left the sidecar permanently orphaned — "joining network namespace
of container: No such container: `<old-id>`", retried forever under
`restart: unless-stopped` — while studio itself stayed `Up` with silently no default
route and therefore no internet. This actually happened: studio had been in that state
for 9 hours before anyone noticed. `roblox-studio-code-docker.yml` no longer defines
`studio-netinit` at all; the same job is now done by `code-docker-netinit-docker`
(formerly `code-docker-netfilter-fix`, upstream `netinit-docker/` in
`qwreey/router-docker-client`, renamed from `netfilter-fix/`), a Docker-labels-driven
agent living entirely on the code-docker side that re-resolves each managed container's
network namespace (`SandboxKey`) every reconcile cycle instead of holding a stale
container-ID handle — the failure class above is structurally impossible for it.
Configuration moved from code-docker's own `.env`
(`NETFILTER_FIX_EXTRA_INTERNAL_NETWORKS`, deprecated but still honored as a one-cycle
fallback) to Docker labels this repo's own `roblox-studio-code-docker.yml` declares
directly: `studio` carries an opt-in `netinit.provider` label (that's the whole
contract on the workload side — which network is the egress path is declared by the
*network*, not the container, via `netinit.gateway`), and `roblox-studio-vnc` carries
`netinit.provider`/`netinit.exempt-forward` but deliberately **no** `netinit.gateway`,
so it's never treated as an egress path — only `code-docker-internal` declares one.
**Capability separation is unchanged**: studio still has **zero** capabilities;
`NET_ADMIN` never moved into studio. The route is planted from outside its network
namespace by an agent studio cannot reach — that separation (Studio can make arbitrary
outbound requests via HTTPService/plugins, so it must not be able to rewrite its own
default route past router's netgate) is the entire reason this design exists, sidecar
or agent. Because the host-side agent can only act *after* studio's container has
started, `entrypoint.sh` now has a fail-closed wait for the default route
(`NETINIT_WAIT`, `NETINIT_WAIT_TIMEOUT` — see below) closing the window where Studio
could otherwise run unrouted for a moment. Full design/rationale, rejected
alternatives, and the live measurements behind it: code-docker's
`.claude/backlog/netinit-docker-plan.md`. The local `netinit/` copy in this repo's own
root was unreferenced by any compose file and has been deleted (2026-08-25).

**`MCP_PORT` is not host-published once integrated with code-docker, and that's
correct, not a gap (owner decision, 2026-08-18).** In this topology `studio` ends up
with zero non-internal networks (`roblox-studio-net` and `roblox-studio-vnc` are
both `internal: true`), so Docker silently skips the host-publish DNAT for `MCP_PORT`
even before Phase 2 existed — confirmed live: connecting to the container's own IP on
8787 works, `127.0.0.1:8787` on the host doesn't. This doesn't matter because the
actual intended consumption path was never host-publish in the first place — it's
code-docker's own agent container reaching `studio:8787` over `code-docker-internal`
(confirmed reachable in the same 2026-08-18 test; since 2026-10-06 that name is
`studio-front`, see "Studio's own network" below). If MCP
access from *outside* code-docker is ever needed, wire it the same way as VNC —
`code-docker-router`'s netgate `forwards:` or Dev Proxy/App Routes — rather than
reviving host-publish, to stay consistent with this project's "only router crosses
the border" principle.

## Studio's own network: `roblox-studio-net` + `studio-front` — 2026-10-06

With code-docker, `studio` is **not** on `code-docker-internal` any more (it was from
Phase 1 until 2026-10-06; the sections above describe that era). It sits on its own
`internal: true` network, `roblox-studio-net`, with only `code-docker-router` (the
network's `netinit.gateway`, and dns-local's second upstream under `ROUTER_HOSTNAME`)
and `studio-front`.

- **Why.** Studio sends arbitrary HTTP through `HttpService` (any plugin, any script the
  agent runs, a Toolbox model's plugin), with headers it chooses, so browser-style
  Origin/CSRF checks don't apply. On `code-docker-internal` that reached code-docker's
  nginx (code-server with `auth: none`, webmanager whose login is opt-in) and dind's
  unauthenticated `:2375`. Measured 2026-10-06 from a container on that network:
  `code-docker/` 302, `/manager/api/terminal/sessions` 200.
- **`studio-front`** (`config/studio-front/entrypoint.sh`) is the only container on
  both networks. It's an nginx `stream` (plain TCP) forwarder, so HTTP and WebSocket
  pass untouched:
  - code-docker → `studio:8787` (MCP; Caddy still checks the token). `studio` is
    `studio-front`'s alias on `code-docker-internal`.
  - Studio → `code-docker:<STUDIO_CODE_DOCKER_PORTS>` (default `34872-34881 3667`:
    `rojo serve` and luau-lsp's Studio plugin). `code-docker` is `studio-front`'s alias
    on `roblox-studio-net`, so plugin host settings keep saying `code-docker`. The
    server on the code-docker side has to bind a non-loopback address
    (`rojo serve --address 0.0.0.0`).
  - Upstreams are network-qualified (`<container>.<network>`, which Docker's DNS
    answers), because a bare `studio`/`code-docker` could resolve to `studio-front`
    itself.
- **Measured on the test stack, from inside `studio`, 2026-10-06:**
  - `code-docker:80`, `:82`, and `router:80` were refused.
  - code-docker's and dind's `code-docker-internal` IPs timed out, because router drops
    the forward.
  - A listener on `code-docker:34875` answered 200, and the internet was reachable.
  - From code-docker, `studio:8787` reached a test listener inside `studio`.
  - router still reached `roblox-studio-vnc:6080`.
- **Chrome has the same problem.** code-docker-chrome's
  `.claude/backlog/next-pass-plan.md` §3 plans the same split. Its reverse direction is
  dev servers on arbitrary ports, not a fixed list.

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

## Process supervision: switched to `supervisord` — 2026-08-13

`entrypoint.sh` used to hand-supervise everything itself: background labwc/wayvnc/dbus,
`wait -n` on just those three (container dies if any one of them dies), plus a
deliberately-excluded background job for the MCP bridge (self-restarting on its own, must
never take the container down with it). This grew fragile as more pieces got added and
was replaced with `supervisord`, matching code-docker's own approach (its
`config/supervisord.default.conf` + `config/supervisord.d/*.conf` split was read first and
copied here, per the standing instruction to match its conventions rather than inventing a
new pattern) — see [[feedback-process-supervision]] in memory for the standing preference
behind this. `entrypoint.sh` is now just the one-time setup that has to happen before anything
starts (wiping `/tmp/xdg-runtime`, exporting `WLR_*`/`DBUS_SESSION_BUS_ADDRESS`, seeding
Vinegar's config) and ends with `exec supervisord -n -c /etc/roblox-studio/supervisord.conf`.

- **Layout**: `config/supervisord.conf` (top-level config, `[include]`s
  `config/supervisord.d/*.conf`) → `/etc/roblox-studio/supervisord.conf` +
  `/etc/roblox-studio/supervisord.d/`. One `[program:...]` file per process there
  (`dbus.conf`, `labwc.conf`, `wayvnc.conf`, `mcp-bridge.conf`, `critical-watchdog.conf`).
  No gitignored user-override glob like code-docker's second `[include]` entry — this
  project doesn't have a config-override mechanism anywhere else either, so one glob is
  enough; don't add a second one speculatively.
- **Service scripts**: `config/supervisor/*-service.sh` →
  `/etc/roblox-studio/*-service.sh`, one per program, plus a shared
  `wait-for-wayland.sh` helper (sourced, not exec'd) that both `labwc-service.sh`'s
  post-start step and `wayvnc-service.sh` use independently — supervisord runs every
  program as its own process with no shared mutable state between them, unlike the old
  single flat `entrypoint.sh` script, so "wait for labwc's socket, export
  `WAYLAND_DISPLAY`" had to become something each dependent script does for itself rather
  than something set once and inherited. Every service script either ends in `exec` (so
  supervisord's stop signal reaches the real daemon directly, no wrapper shell left in
  between — `dbus-service.sh`, `wayvnc-service.sh`, the `labwc`/`labwc` line at the end of
  `labwc-service.sh`) or, when it has to keep running as bash itself (the MCP bridge's
  idle-when-`MCP_TOKEN`-unset branch), installs an explicit `trap ... TERM INT` — same
  idiom code-docker's own `dns-local.default.sh` uses for its NETGATE-disabled idle
  branch. `mcp-bridge.sh` itself (unchanged) already had good TERM/INT trap handling of
  its own supergateway/caddy children — this migration only added the idle-gate wrapper
  around it, `config/supervisor/mcp-bridge-service.sh`.
- **Container-dies-if-a-critical-process-dies, replicated without `wait -n`**: supervisord
  itself has no built-in "shut the whole stack down if program X exits" directive, so
  `critical-watchdog.conf`/`critical-watchdog-service.sh` polls `supervisorctl status` for
  `dbus`/`labwc`/`wayvnc` every 2s (after an initial 5s startup grace period, so it
  doesn't false-positive on their normal STARTING window) and calls `supervisorctl
  shutdown` the moment any of them isn't `RUNNING`/`STARTING` — that brings down
  supervisord itself, which is `entrypoint.sh`'s `exec` target, i.e. the container's PID 1,
  reproducing the old `wait -n` behavior. Those three programs have `autorestart=false` +
  `startretries=0` so a first failure surfaces to the watchdog immediately rather than
  being quietly retried first. The MCP bridge is deliberately **not** in the watchdog's
  list — same "must never take the container down" requirement as before, now expressed
  as just not being on the polled list rather than not being in a `wait -n` set.
- **Debugging**: `docker exec roblox-studio supervisorctl status` shows every program's
  state at a glance. Per-program logs at `/var/log/<program>/stdout.log` and
  `stderr.log` inside the container (pre-created in the `Dockerfile` — supervisord does
  not create a logfile's parent directory itself, same reason code-docker's own
  `Dockerfile` pre-creates its `/var/log/<program>` dirs too).

## Conventions

- **Build/run**: `docker compose build`, then `VNC_PASSWORD=... docker compose up -d`
  (or copy `.env.example` to `.env`). Single service named `studio` in
  `docker-compose.yml`, image built from the root `Dockerfile`. VNC published on host
  port 5900 (override via `VNC_PORT`).
- **Base image**: `archlinux:latest` (matches host/owner's other infra). Milestones are
  added as straight-line layers in `Dockerfile`. Process supervision is `supervisord`'s
  job (see "Process supervision: switched to `supervisord`" above) — `entrypoint.sh` only
  does one-time setup and then `exec`s into it. dbus/labwc/wayvnc take the container down
  if any one of them dies (via `critical-watchdog`, see above); the Studio MCP bridge
  (`mcp-bridge.sh`, see its own section above) is a deliberate exception — non-critical
  and already self-restarting on its own, must never take the whole container (and
  Studio's actual session) down with it.
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
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 HOME=/root \
         DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/xdg-runtime/bus"
  vinegar &
  ```
  (`DISPLAY=:0` is required — see "Panels: Wine virtual desktop". Note `wayland-0`, not `wayland-1` — that was sway's socket name, labwc's is
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
