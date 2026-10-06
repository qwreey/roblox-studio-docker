# Draft: labwc issue — absolute pointers can't move a locked pointer

Status: **draft, not filed.** For https://github.com/labwc/labwc/issues. Our patch
(`config/pointer-warp/labwc-locked-absolute-motion.patch`) stays in place either way; see
CLAUDE.md's "Camera drag over VNC".

---

**Title:** Absolute pointer motion is dropped entirely while a pointer lock is active

**Version:** labwc 0.20.2 (wlroots 0.20.2), headless backend, input from wayvnc's
`zwlr_virtual_pointer_v1.motion_absolute`.

`handle_motion_absolute()` turns the event into a delta from the cursor and calls
`preprocess_cursor_motion()`, which returns early when `cursor_locked()`. Unlike
`handle_motion()`, it never calls `wlr_relative_pointer_manager_v1_send_relative_motion()`.
So while a client holds a `zwp_locked_pointer_v1`, an absolute device produces no events
at all. Xwayland takes such a lock whenever an X client warps a hidden cursor (its
pointer-warp emulation). A VNC/RDP user's mouse is then dead for as long as the client
keeps the cursor hidden, for example a 3D view or game in mouse-look.

**Suggested fix:** remember each absolute device's last layout position. While the
pointer is locked, send the movement since that position as relative motion. Nothing
else changes: the cursor stays put, as a lock requires. ~25 lines including clearing the
remembered device when it goes away. With it, a Wine/X11 test program that hides its
cursor and warps it back to an anchor on every move gets the drag distance exactly
(through Xwayland's warp emulator); without it, it gets nothing after the first event.

(sway takes the other path for absolute devices: it sends relative motion computed against
the *cursor* position. Under a lock the cursor doesn't move, so every event's "delta" is
the device's whole distance from the lock point.)
