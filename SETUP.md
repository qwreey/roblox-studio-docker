# Setup & operator's guide

This is the practical, human-facing guide: how to build/run the container, connect to it,
log in, and debug it if something breaks. For *why* things are built this way — the
architecture decisions and the specific bugs that had to be fixed to get here — see
`CLAUDE.md` and `plan.md`. This file is the "how do I actually use it" complement to
those.

## Status as of 2026-08-11

Working end-to-end and verified with a real account: headless Wayland compositor, real
AMD GPU acceleration, Roblox Studio installed and running via Vinegar/Wine, browser-based
login, and a full 3D place open and rendering correctly (verified: the built-in Studio
Tour's carnival scene — carousel, trees, buildings, sky — rendering in real time with
mouse interaction working). Login state and the Wine/Studio install both survive
container restarts.

Not yet done: Milestone 4 (a standalone Chrome-works check — Chrome already works fine as
part of the login flow, just not separately verified per the original plan), Chrome's own
profile isn't persisted (not needed yet — see `plan.md` §5), and edit-mode camera
rotation specifically hasn't been stress-tested (this was a known, accepted risk from the
Wayland architecture decision — see `CLAUDE.md` — but interaction in general is now
working well, better than that pessimistic baseline expected).

## Build & run

```sh
cp .env.example .env   # then edit VNC_PASSWORD in it — see below
docker compose build
docker compose up -d
```

The container publishes VNC on `${VNC_PORT:-5900}` (host port, default 5900).

**Set `VNC_PASSWORD`** in `.env` (or as an env var) before exposing this beyond
`localhost` — if it's unset, `wayvnc` runs with *no authentication at all*. Fine for a
quick local test, not fine for anything reachable off the host.

Roblox Studio itself is **not auto-started**. Once the container's up, either launch it
yourself over VNC (open a terminal in the desktop — see "Connecting" below — and run
`vinegar`), or from the host:

```sh
docker exec roblox-studio bash -c '
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-1 HOME=/root \
         DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/xdg-runtime/bus"
  vinegar &
'
```

## Connecting with a real VNC client

This is a genuine remote desktop, not a screenshot tool — connect with any standard VNC
viewer (TigerVNC, RealVNC, Remmina, macOS's built-in "Screen Sharing" via `vnc://`, a
browser-based noVNC client, etc.):

- **Address**: `<host-running-the-container>:5900` (or whatever `VNC_PORT` was set to).
  If you're on the same machine, `localhost:5900`.
- **Password**: whatever `VNC_PASSWORD` was set to. If it was left unset, connect with no
  password.
- You should see a plain desktop (sway, no taskbar/panel by default) with whatever
  windows are currently open — Roblox Studio, a terminal, etc. There's no window
  decoration chrome beyond a plain titlebar; use `Mod4` (Super/Windows key) + `Return` to
  open a terminal (`foot`) if you need a shell inside the session itself, or just
  `docker exec` from the host as shown above.
- Mouse and keyboard both work through the VNC connection normally. (During development,
  scripted/synthetic VNC input from a hand-rolled test client had a reproducible issue
  where certain buttons wouldn't register clicks — that was specific to the test tooling,
  not a real limitation; a real VNC client's mouse and keyboard both work fine, including
  inside Wine/Roblox Studio windows.)

## First-time Roblox login

1. Connect over VNC (above) and make sure Vinegar/Studio is running (see "Build & run").
2. Studio's login will likely fail once automatically on a truly first launch — this is
   normal, not a bug (Roblox Studio's built-in login page currently doesn't render inside
   this container's Wine/Wayland setup — see `CLAUDE.md`'s "Milestone 3" section for
   why). Click **"Login via Browser"** on the "Launch Failed" screen instead.
3. A real Chromium window opens to Roblox's actual login page. Log in there normally
   (with the dedicated account you want Studio to use — **read `CLAUDE.md`'s business-risk
   notes about anti-cheat and fraud-detection first if you haven't**, this is a real
   account login, not a test).
4. After authorizing, Chromium redirects back and Studio picks up the login
   automatically — you'll land on Studio's normal dashboard, logged in.
5. This only needs to happen once — the login token persists across container restarts
   (confirmed: a full `docker compose down && up` came back up already logged in).

## Debugging without a VNC client (for Claude Code sessions / headless checks)

Useful when iterating on the container itself and a full VNC client isn't handy — takes a
real screenshot of the actual compositor output (pixel-identical to what a VNC client
would show, since it reads the same buffer `wayvnc` does):

```sh
docker exec roblox-studio bash -c '
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-1
  grim /tmp/shot.png
'
docker cp roblox-studio:/tmp/shot.png ./shot.png
```

`grim` isn't in the image by default (it's a debug tool, not a runtime dependency) —
install it ad hoc first if needed: `docker exec roblox-studio pacman -Sy --noconfirm
--needed grim`.

To check *why* something isn't rendering (GPU vs. software fallback), the sharpest test
is a real Vulkan render, not just a screenshot of a blank window:

```sh
docker exec roblox-studio pacman -Sy --noconfirm --needed mesa-demos
docker exec roblox-studio bash -c '
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-1
  vkcube
'
```

On a working setup this prints `Selected GPU 0: <real GPU name>` and actually renders; on
a broken one (e.g. the original Xvfb/X11 approach this project moved away from) it
crashes outright with a DRI3 error — see `CLAUDE.md` for that whole story.

## If something breaks

Check, in this order (all are documented in more depth in `CLAUDE.md`'s "Milestone 3"
section — this was hard-won, don't rediscover it from scratch):

1. **DNS speed inside the container**: `docker exec roblox-studio bash -c 'time getent
   hosts roblox.com'` — should be well under 200ms. If it's ~4s, the host's
   `/etc/docker/daemon.json` DNS config has regressed (should be `{"dns": ["8.8.8.8"]}`
   only — no `1.1.1.1`, it's unreachable from this host's containers and silently makes
   *everything* flaky, including Roblox Studio's own login).
2. **Vinegar's config**: `docker exec roblox-studio cat /root/.config/vinegar/
   config.toml` should show `webview = ""` under `[studio]`. If it's missing or reset,
   Studio's login will show a blank/unusable window instead of the working
   "Login via Browser" fallback.
3. **Container logs**: `docker compose logs` for compositor/wayvnc-level issues; Vinegar's
   own log is wherever you redirected its stdout (see "Build & run" above) plus its own
   deeper per-run log files under `/root/.local/share/vinegar/appdata/Roblox/logs/` inside
   the container (Roblox Studio's *own* detailed engine log, more informative than
   Vinegar's wrapper output for login/auth-specific issues).

## Where things live (persisted across restarts, in `./data/`, gitignored)

- `./data/vinegar-data` — Kombucha Wine build, Roblox Studio install, Wine prefixes. The
  big one (~2GB).
- `./data/vinegar-config` — Vinegar's `config.toml` (including the `webview=""` fix) and
  any overlays.
- `./data/vinegar-cache` — download cache and Vinegar's own log history.

Deleting any of these and restarting just re-creates them from scratch (re-downloads
Studio/Wine, reseeds the default config) — safe, just slow (a few minutes).
