# Draft: Xwayland issue — warps are lost for absolute-only pointers (VNC/RDP)

Status: **draft, not filed.** For https://gitlab.freedesktop.org/xorg/xserver/-/issues.
Our patch (`config/pointer-warp/xwayland-absolute-motion-after-warp.patch`) stays in place
either way; see CLAUDE.md's "Camera drag over VNC".

---

**Title:** Xwayland: an X client's pointer warp is undone by the next motion from an
absolute-only pointer, so warp-to-anchor 3D cameras spin over VNC

**Setup:** a wlroots compositor (labwc 0.20.2, wlroots 0.20.2) on the headless backend,
input from wayvnc 0.10.2 through `zwlr_virtual_pointer_v1.motion_absolute`, Xwayland
24.1.13 rootless. The X client is Wine (winex11) running a Windows 3D editor whose
camera reads the pointer's distance from an anchor and `XWarpPointer`s back to the anchor
after every move. The cursor is hidden around the warp (XFixes), so Xwayland emulates the
warp with `zwp_locked_pointer_v1` + `set_cursor_position_hint`.

**What happens:** the virtual pointer only knows the viewer's position, so its next
`wl_pointer.motion` carries the viewer's absolute position, and `dispatch_absolute_motion`
puts the X pointer there. The client then reads the viewer's whole distance from the
anchor as one move. A drag of N pixels in k steps sums to roughly N·k/2 instead of N:
measured 20 px → 50, 110 or 210 "pixels" of camera motion in 4, 10 or 20 steps.

The compositor can't fix this on its own. It learns about the warp only through the lock's
cursor hint, which is surface-synced state and is frequently not applied yet when
Xwayland destroys the lock a few milliseconds later. We saw this with explicit sync in
use. Xwayland is the one place that sees the warp and the following motion in order.

**Suggested fix** (what we run, ~70 lines): for motion frames with an absolute position but
no `zwp_relative_pointer_v1` motion (an absolute-only device), remember the last position.
Once a client has warped (`CursorWarpedTo`), apply the device's movement since that
position to the sprite's current (warped) position instead of using the absolute position.
Keep doing so while a button is held, and resync on the next frame without a button held.
"Held" has to come from the `wl_pointer.button` events themselves: the device's
`buttonsDown` read 0 throughout a drag at that point (buttons are queued on
`get_pointer_device()` and processed later), which let a drag started without moving
since the previous release begin with a jump to the viewer's position.
Relative-only frames (sent while a lock is up) advance the remembered position, and a
frame with both kinds of motion marks the device as relative and turns this off. With
it, the same drags sum to N regardless of step count, and the pointer is back under the
viewer's after the drag.

**Repro without the editor:** `camprobe.c` next to this file (a Win32 program doing the
same warp-to-anchor loop), in a Wine virtual desktop under Xwayland, driven by any VNC
client or `vncdotool` against wayvnc.
