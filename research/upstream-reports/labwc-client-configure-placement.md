# Draft: labwc issue — an X11 window's own resize is lost on the next output change

Status: **draft, not filed.** For https://github.com/labwc/labwc/issues. Our patch
(`config/labwc-placement/labwc-client-configure-placement.patch`) stays in place either
way; see CLAUDE.md's "Panels: Wine virtual desktop".

---

**Title:** Xwayland view moved/resized by its own ConfigureRequest snaps back on output layout change

**Version:** labwc 0.20.2 (wlroots 0.20.2); `src/xwayland.c` is unchanged on master as of
2026-10-20. Headless backend, output mode set by wayvnc.

`handle_request_configure()` honors a floating view's request through
`xwayland_view_configure()`, which never calls `view_save_last_placement()` -
`view_move_resize()` does, but only compositor-initiated moves go through it. On the
next output layout change, `view_adjust_for_layout_change()` moves the view to
`last_placement.relative_geo`, i.e. wherever it was before the client moved or resized
itself (for a window that only ever resized itself, its map-time geometry).

A layout change doesn't need a different mode: wayvnc applying a client's
SetDesktopSize for the size the output already has is enough.

**Repro:** a floating X11 window that resizes itself after mapping (here a Wine virtual
desktop, `wine explorer /desktop=x,1920x1048 notepad`, resized from inside Wine with
`ChangeDisplaySettingsEx` to 2048x991), then a VNC client sending wayvnc a SetDesktopSize
for the output's current mode: the window is back to 1920x1048. With the patch it keeps
2048x991. (Measured that way only; `wlr-randr --custom-mode` to the current mode is
untested.)

**Suggested fix:** save the placement after honoring the request, the way
`view_move_resize()` does:

```c
		xwayland_view_configure(view, box);
		if (view->mapped && !view->adjusting_for_layout_change) {
			view_save_last_placement(view);
		}
```

(`view->mapped`: before map there is no usable output yet, and map saves it anyway.)
