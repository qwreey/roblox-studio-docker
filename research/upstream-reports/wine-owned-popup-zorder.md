# Draft: WineHQ Bugzilla report — owned popups fall behind their owner in a virtual desktop

Status: **draft, not filed.** For https://bugs.winehq.org/ (Product: Wine, Component:
winex11.drv). Attach `owned-popup-zorder-test.c` (and a built `.exe`) from this directory.
Our workaround (`config/wine-owned-popups/`) stays in place either way; see CLAUDE.md's
"Panels: Wine virtual desktop" for how this was found.

---

**Summary:** winex11: in a virtual desktop, activating a window raises it above its owned
popups

**Version:** wine-11.19 (also wine-11.15; code unchanged on master as of 2026-10-05)

**Description:**

In a virtual desktop (`explorer /desktop=name,WxH`), clicking an owner window raises it
above the popups it owns, so the popups disappear behind it. On Windows an owned window is
always kept above its owner. Only tested in virtual-desktop mode, where every top-level is
an unmanaged child of the desktop's X window; outside it the window manager stacks these
windows instead (Wine sets WM_TRANSIENT_FOR on the popup).

Real-world impact: Roblox Studio's floating panels (owned `WS_POPUP` tool windows) vanish
behind the main window as soon as the main window is clicked, and can only be brought
back by minimizing and restoring the main window.

**Steps to reproduce** (attached `owned-popup-zorder-test.c`; build with
`x86_64-w64-mingw32-gcc -municode -mwindows -o ztest.exe owned-popup-zorder-test.c -luser32 -lgdi32`):

1. `wine explorer /desktop=zt,1200x800 ztest.exe`
   It creates an overlapped owner window and a `WS_POPUP` window owned by it, overlapping
   it, and logs every 500 ms (to `Z:\tmp\ztest.log`) which of the two is higher in the
   z-order (`GetTopWindow`/`GW_HWNDNEXT`).
2. Click the owner window somewhere the popup doesn't cover.

**Expected:** the popup stays above the owner (log: `popup-above-owner`).

**Actual:** the popup goes behind the owner, visually and in the win32 z-order (log:
`OWNER-above-popup`). With Roblox Studio's windows, calling
`SetWindowPos(popup, HWND_TOP, ...)` or `BringWindowToTop(popup)` from another process
afterwards returned TRUE but did not change the order (not tried with the test program).

**Analysis:**

With `WINEDEBUG=+win,+x11drv,+event`, the click produces no `SetWindowPos` call at all —
only `set_foreground_window`/`set_active_window`, then FocusIn, ConfigureNotify and an
Expose on the owner covering exactly the popup's rectangle. The order changes through two
steps, neither of which goes through `set_window_pos()` and its `swp_owner_popups()`:

1. `dlls/winex11.drv/event.c`, `set_input_focus()`: for an unmanaged window (every
   top-level in a virtual desktop) it does
   `XConfigureWindow(..., CWStackMode = Above)` on the focused window's X window, putting
   it at the top of the desktop window's X children regardless of the windows it owns.
2. The X server then exposes the part of the owner the popup used to cover, and
   `X11DRV_Expose()` sends `update_window_zorder` for that rectangle. The server
   (`set_window_rect_visible()`) moves the owner above the windows overlapping it, which
   makes the X stacking the win32 z-order.

The same mechanism also works in the other direction: restacking the popup's X window
above the owner's (e.g. `xdotool windowraise <popup>`) makes the next Expose move the popup
back above the owner in the win32 z-order. That is what our workaround does: an X client
that keeps every window whose `WM_TRANSIENT_FOR` points at a sibling stacked directly
above that sibling.

A fix in Wine itself could have `set_input_focus()` restack the window's owned popups above
it after raising it, or have it use `SetWindowPos(HWND_TOP)` (which already runs
`swp_owner_popups()`) instead of raising the X window directly.

**Environment:** Arch Linux container, labwc 0.20.2 (wlroots) with XWayland, Mesa
radv/radeonsi; reproduced with both upstream wine-11.15 (64-bit only build) and Kombucha
`stable+20261005101806` (wine-11.19).
