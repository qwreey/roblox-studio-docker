# Setup & operator's guide

This is the practical, human-facing guide: how to build/run the container, connect to it,
log in, and debug it if something breaks. For *why* things are built this way — the
architecture decisions and the specific bugs that had to be fixed to get here — see
`CLAUDE.md` and `plan.md`. This file is the "how do I actually use it" complement to
those.

## Status as of 2026-08-13

Working end-to-end and verified with a real account: headless Wayland compositor
(`labwc`), real AMD GPU acceleration, Roblox Studio installed and running via
Vinegar/Wine, browser-based login, and a full 3D place open and rendering correctly
(verified: the built-in Studio Tour's carnival scene — carousel, trees, buildings, sky —
rendering in real time with mouse interaction working). Login state and the Wine/Studio
install both survive container restarts. Also verified since: VNC access with a real
client over a properly negotiated encrypted connection (see "Connecting with a real VNC
client" below), and the remote Studio MCP bridge end-to-end, including auto-restart on
crash (see "Studio MCP over the network" below).

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
yourself over VNC (right-click the desktop → "Roblox Studio (Vinegar)" — see "Connecting"
below), or from the host:

```sh
docker exec roblox-studio bash -c '
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-0 HOME=/root \
         DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/xdg-runtime/bus"
  vinegar &
'
```

## Connecting with a real VNC client

This is a genuine remote desktop, not a screenshot tool — connect with a real VNC viewer.

- **Address**: `<host-running-the-container>:5900` (or whatever `VNC_PORT` was set to).
  If you're on the same machine, `localhost:5900`.
- **Username**: `studio` (hardcoded — see `entrypoint.sh`'s wayvnc config generation).
  Not your OS username, not `root` — VNC auth is unrelated to the Linux user the
  container's processes run as.
- **Password**: whatever `VNC_PASSWORD` was set to. If it was left unset, `wayvnc` runs
  with *no authentication at all* (connect with no username/password, and see the
  warning below).

### Which client to use

When `VNC_PASSWORD` is set, `wayvnc` advertises **three** RFB security types at once and
lets the client pick whichever it supports: VeNCrypt/TLS (a self-signed cert), and two
RSA-AES variants. Confirmed via a raw RFB handshake probe. Client compatibility varies:

- **TigerVNC's `vncviewer`** — recommended on paper: it's the client wayvnc's own docs
  are written and tested against, its RFB security types line up (confirmed via the
  handshake probe below), and the Flatpak build's sandbox permissions check out
  (`shared=network`). **Caveat: not actually connection-tested end-to-end** — no one has
  run it against this server and watched it succeed yet, only reasoned about
  compatibility. Install via `pacman -S tigervnc`, or as a Flatpak (`flatpak install
  flathub org.tigervnc.vncviewer`). Connect: `vncviewer <host>:5900` (or `flatpak run
  org.tigervnc.vncviewer <host>:5900`). If you try this, it's worth confirming it
  actually works and noting the result here.
- **Some other client worked in practice** — the owner connected successfully with a
  client described as showing the self-signed cert's hash and a simple "OK" to accept
  (consistent with GNOME's remote-desktop client UX), but its exact identity was never
  pinned down (`grdctl` was mentioned, but that's actually GNOME Remote Desktop's
  *server*-config CLI, not a VNC viewer client — so treat "some client worked" as
  confirmed, not a specific product recommendation).
- **Remmina** — confirmed *not* to work smoothly here. It rejects the RSA-AES types
  outright ("unknown authentication scheme"), and even after negotiating VeNCrypt/TLS,
  its self-signed-certificate handling wants a CA file supplied through a file-picker
  dialog rather than a simple accept/reject prompt — this did **not** end up working
  reliably in testing (including with the self-signed cert supplied as its own CA, and
  regardless of whether Remmina was the Flatpak or a native build). If you only have
  Remmina available, install one of the clients above instead rather than fighting this
  further — it's a real client-compatibility gap, not a misconfiguration on this side.
  If you want to try anyway, the cert lives at
  `./data/wayvnc/tls_cert.pem` (or `docker cp roblox-studio:/root/.config/wayvnc/tls_cert.pem .`
  if `./data/wayvnc` isn't mounted where you're working).
- **KRDC** (`pacman -S krdc`) — not tested here, but supports both VNC+RDP with generally
  solid cert-trust UX; a reasonable option if you'd rather not use TigerVNC.

The RSA-AES key and TLS cert are persisted under `./data/wayvnc` (see "Where things live"
below) so the fingerprint stays stable across container restarts — you won't get a
scary "host key changed" warning every time the container comes back up.

### Once connected

- You should see a normal-feeling desktop (`labwc` — decorated windows with a titlebar
  you can drag/resize) with a **taskbar at the bottom**: a "☰ Menu" button on the left
  (opens a searchable app launcher — every installed app, including Terminal/Roblox
  Studio/Chromium), a live window list in the center (click an entry to focus/switch to
  it), and a clock on the right. Right-clicking the desktop background also opens a
  simpler menu with just Terminal/Roblox Studio/Chromium. `Mod4` (Super/Windows key) +
  `Return` opens a terminal (`foot`) directly. Double-click a titlebar (or `Mod4+F`) to
  maximize/unmaximize a window.
- **In the app launcher specifically, single-click only selects an item — double-click
  (or select + Enter) actually launches it.** Easy to miss the first time.
- Mouse and keyboard both work through the VNC connection normally. (During development,
  scripted/synthetic VNC input from a hand-rolled test client had a reproducible issue
  where certain buttons wouldn't register clicks — that was specific to the test tooling,
  not a real limitation; a real VNC client's mouse and keyboard both work fine, including
  inside Wine/Roblox Studio windows.)
- **Resizing the client window resizes the remote desktop to match** (the RFB
  `SetDesktopSize` extension — TigerVNC and most modern clients support requesting this,
  and wayvnc's headless-Wayland backend can resize its virtual output live to fulfill it).
- Disconnecting the VNC client does **not** stop anything — labwc, Studio, Vinegar, the
  MCP bridge all keep running exactly as before. wayvnc is just a capture/input frontend
  over an already-running compositor output (`wlr-screencopy`); it doesn't own the
  session's lifecycle. Reconnect any time and pick up where things were left.

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
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-0
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
  export XDG_RUNTIME_DIR=/tmp/xdg-runtime WAYLAND_DISPLAY=wayland-0
  vkcube
'
```

On a working setup this prints `Selected GPU 0: <real GPU name>` and actually renders; on
a broken one (e.g. the original Xvfb/X11 approach this project moved away from) it
crashes outright with a DRI3 error — see `CLAUDE.md` for that whole story.

## Studio MCP over the network (remote MCP bridge) — verified working 2026-08-13

Roblox Studio ships a built-in MCP server (Assistant > "Manage MCP Servers"), but by
design it only ever speaks **stdio** to a client process running on the *same* machine —
there's no network mode, no port flag, nothing to point a remote client at (see
`research/roblox-mcp.md`). This project bridges it out: `supergateway` wraps the stdio
process as Streamable HTTP, and `caddy` fronts that with bearer-token auth as the only
port actually published. Auto-started by `entrypoint.sh` whenever `MCP_TOKEN` is set, and
self-restarts on crash — see `config/mcp/mcp-bridge.sh`'s own header comment. Confirmed
end-to-end with a real `tools/list` call returning genuine
Studio-specific tools (`upload_image`, `search_game_tree`, etc.) through the full chain:
curl → Caddy (bearer auth) → supergateway → `StudioMCP.exe` → WebSocket → Studio's own
Assistant plugin.

### 1. One-time interactive step — must be done over VNC, no CLI equivalent exists

1. Connect over VNC (see "Connecting" above) and make sure Roblox Studio is running and
   logged in.
2. Open the **Assistant** panel inside Studio.
3. Click **…** > **Manage MCP Servers**.
4. Toggle **Enable Studio as MCP server** on.

If the Assistant panel or this toggle isn't there at all, this Studio build/account may
not have the feature rolled out yet — that's a real possibility, not verified in advance
for this project; nothing further below will work until it's available.

This generates `StudioMCP.exe` under the *current* Studio version folder
(`./data/vinegar-data/versions/version-*/StudioMCP.exe`) plus a `mcp.bat` launcher under
`./data/vinegar-data/appdata/Roblox/mcp.bat` (Vinegar's own `%LOCALAPPDATA%\Roblox`
mapping — not the traditional Wine-prefix path). Nothing else to do here manually —
`config/mcp/studio-mcp-stdio.sh` (baked into the image, see its own header comment)
resolves the current version folder itself and launches `StudioMCP.exe` directly, and is
`mcp-bridge.sh`'s default `STUDIO_MCP_STDIO_CMD`. It deliberately does **not** go through
`mcp.bat`/`cmd.exe`: that generated batch file has a real cmd.exe parser bug (`else` on
its own line, which cmd.exe's batch parser rejects) — confirmed by testing, it still runs
`StudioMCP.exe` fine on the common path, but throws a stray "Syntax error: unexpected
ELSE" once that process exits, and that's not a risk worth taking on a channel
`supergateway` parses as newline-delimited JSON-RPC.

### 2. The bridge starts itself — nothing to run manually

supervisord's `mcp-bridge` program starts `mcp-bridge.sh` automatically whenever
`MCP_TOKEN` is set (same pattern as `VNC_PASSWORD` gating wayvnc's auth) — as soon as the
container is up with `MCP_TOKEN` configured in `.env`, the bridge is already listening,
independent of whether Studio itself has been launched yet (it just waits for Studio's
plugin to connect once Studio is up). If `MCP_TOKEN` isn't set, the program idles instead
(see CLAUDE.md's "Process supervision: supervisord" section) rather than not starting at
all — check `docker exec roblox-studio supervisorctl status mcp-bridge` if you're not sure
which state it's in. It's also **self-restarting**: if `supergateway` or `caddy` crash,
`mcp-bridge.sh`'s own loop respawns both within ~2s — confirmed by killing `caddy`
mid-session and watching it come back with fresh PIDs, connection still fully functional
afterward. Logs land at `/var/log/mcp-bridge/stdout.log` inside the container
(`docker exec roblox-studio tail -f /var/log/mcp-bridge/stdout.log`).

To run it manually instead (e.g. to test a config change without restarting the whole
container):

```sh
docker exec -e MCP_TOKEN="${MCP_TOKEN:?set in .env}" roblox-studio mcp-bridge.sh
```

### 3. Connect a remote MCP client

The bridge exposes MCP over **Streamable HTTP** at `http://<host>:${MCP_PORT:-8787}/mcp`,
gated by `Authorization: Bearer <MCP_TOKEN>`.

- **Claude Code, native remote-MCP support** (recent versions speak Streamable HTTP
  directly — no `mcp-remote` needed). Verified working end-to-end against this bridge:
  ```sh
  claude mcp add --transport http roblox-studio \
    http://<host>:8787/mcp \
    --header "Authorization: Bearer <MCP_TOKEN>"
  ```
  Confirm it's actually connected (not just registered) — `claude mcp list` should show
  `roblox-studio: http://<host>:8787/mcp (HTTP) - ✔ Connected`; `claude mcp get
  roblox-studio` shows the full config. Default scope is `local` (private to you, in this
  project's `~/.claude.json` — not committed to the repo, same trust level as the token
  itself); pass `-s user` or `-s project` if you want it available more broadly (`-s
  project` writes to a committed `.mcp.json` — don't do that with a real token baked into
  the URL/headers unless you mean to share it). Remove with `claude mcp remove
  roblox-studio -s local` (match whatever scope you added it with).
- **A stdio-only MCP client** (older tooling that can't speak remote HTTP/SSE itself):
  wrap it with `mcp-remote` on the client side instead —
  ```sh
  npx mcp-remote http://<host>:8787/mcp --header "Authorization: Bearer <MCP_TOKEN>"
  ```
  `mcp-remote` is a *client-side* proxy (stdio-only client → already-remote HTTP server);
  `supergateway` is what does the actual server-side stdio→HTTP wrapping inside this
  container. They solve opposite ends of the same problem — see `research/roblox-mcp.md`
  §4.1 if this distinction matters for your client choice.

### Security notes (read before exposing beyond `localhost`)

- **`MCP_TOKEN` gates arbitrary Luau code execution inside Roblox Studio** — the MCP
  tools this exposes are not read-only. Treat the token like a credential, not a
  convenience password. `mcp-bridge.sh` fails closed (refuses to start) if it's unset —
  don't work around that.
- Only Caddy's port (`MCP_PORT`, default 8787) is published from the container;
  supergateway's own upstream port has no auth of its own and must never be published
  directly (see `config/mcp/Caddyfile`'s header comment).
- Everything above describes **standalone** usage (this repo's own `docker-compose.yml`
  alone, no code-docker attached) — `MCP_PORT` really is published to the host in that
  mode. When run *with* code-docker instead (`roblox-studio-code-docker.yml`, see
  CLAUDE.md's "MCP_PORT is not host-published once integrated with code-docker" note),
  `MCP_PORT` is intentionally not published at all — code-docker's own agent container
  reaches the bridge directly over `code-docker-internal` instead, and outside access (if
  ever needed) goes through `code-docker-router`, not a host-published port.

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
3. **Process status**: `docker exec roblox-studio supervisorctl status` — every managed
   process (`dbus`, `labwc`, `wayvnc`, `mcp-bridge`, `critical-watchdog`) should show
   `RUNNING`. Per-program logs live at `/var/log/<program>/stdout.log` and `stderr.log`
   inside the container (e.g. `docker exec roblox-studio tail -f /var/log/labwc/stderr.log`)
   — see CLAUDE.md's "Process supervision: supervisord" section. `docker compose logs`
   still shows supervisord's own top-level log line plus everything written before the
   handoff to it.
4. **Container stuck in a fast restart loop** (`docker ps` shows `Restarting (1)` every
   couple seconds): see `CLAUDE.md`'s "Crash-loop bug: stale Wayland socket survives
   `docker restart`" section — a known, fixed class of bug (stale `/tmp/xdg-runtime`
   state surviving a restart). If it's back, that fix likely got reverted. Also possible:
   `critical-watchdog` shutting the container down because `dbus`/`labwc`/`wayvnc`
   actually failed to start — check `supervisorctl status` and that program's own
   stderr.log for the real underlying error before assuming it's the stale-socket bug.
5. **MCP bridge not responding**: `docker exec roblox-studio tail -50
   /var/log/mcp-bridge/stdout.log`. If it's idling instead of running, confirm `MCP_TOKEN`
   is actually set in `.env` (the bridge idles without it, by design) and that the
   container was recreated (not just left running from before `MCP_TOKEN` was added) —
   see "Studio MCP over the network" below.

## Where things live (persisted across restarts, in `./data/`, gitignored)

- `./data/vinegar-data` — Kombucha Wine build, Roblox Studio install, Wine prefixes. The
  big one (~2GB).
- `./data/vinegar-config` — Vinegar's `config.toml` (including the `webview=""` fix) and
  any overlays.
- `./data/vinegar-cache` — download cache and Vinegar's own log history.
- `./data/wayvnc` — wayvnc's RSA-AES key and self-signed VeNCrypt/TLS cert (see
  "Connecting with a real VNC client" above). Deleting this just means every VNC client
  sees a "host key changed"-style warning on next connect (a new cert gets generated) —
  not destructive, just mildly annoying.

Deleting any of these and restarting just re-creates them from scratch (re-downloads
Studio/Wine, reseeds the default config) — safe, just slow (a few minutes). Deleting
`./data/vinegar-data` specifically also removes the generated `StudioMCP.exe`/`mcp.bat` —
you'd need to re-enable Assistant's MCP toggle once Studio is back up (see "Studio MCP
over the network" below).
