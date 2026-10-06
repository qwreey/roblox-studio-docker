# Draft: vinegarhq/kombucha issue — winex11 crashes when XDG_SESSION_TYPE is unset

Status: **draft, not filed.** For https://github.com/vinegarhq/kombucha/issues. Our
workaround (`ENV XDG_SESSION_TYPE=wayland` in the Dockerfile) stays in place either way;
see CLAUDE.md's "Panels: Wine virtual desktop".

---

**Title:** winex11 fails to load when `XDG_SESSION_TYPE` is unset (NULL passed to strcmp)

`patches/stable/0017-winex11-Don-t-hide-cursor-under-X11-sessions.patch` (same in
`unstable`) adds to `__wine_unix_lib_init()` in `dlls/winex11.drv/x11drv_main.c`:

```c
xwayland = !strcmp(getenv("XDG_SESSION_TYPE"), "wayland");
```

When `XDG_SESSION_TYPE` isn't set, `getenv()` returns NULL and this segfaults inside
`strcmp`. The fault is caught, `winex11.drv` fails to initialize
(`warn:module:process_attach Initialization of L"winex11.drv" failed`, no other error), and
Wine silently falls back to the next graphics driver — winewayland if a Wayland socket is
reachable, otherwise `nodrv` ("The explorer process failed to start"). So the X11 driver is
unusable wherever nothing sets that variable — we hit it in a container, where no login
session manager runs.

**Repro:** in an X session, `env -u XDG_SESSION_TYPE WINEDEBUG=+seh,warn+module wine notepad`
— `handle_syscall_fault code=c0000005` right after
`Display settings are now handled by: NoRes`, then the initialization failure above; with the
variable set (we set `wayland`, running under XWayland) it loads normally. (Found with gdb: the faulting `strcmp`'s
second argument is the `"wayland"` literal in winex11.so's rodata.)

**Suggested fix:**

```c
const char *session_type = getenv("XDG_SESSION_TYPE");
xwayland = session_type && !strcmp(session_type, "wayland");
```

Seen on `stable+20261005101806` (wine-11.19) and `stable+20260809183117` (wine-11.15).
