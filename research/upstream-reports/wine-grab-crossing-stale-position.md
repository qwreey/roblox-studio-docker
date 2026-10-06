# Draft: WineHQ bug — SetCursorPos in a virtual desktop jumps back to the old position

Status: **draft, not filed.** For https://bugs.winehq.org (component winex11.drv). Our
patch (`config/pointer-warp/winex11-grab-crossing.patch`) stays in place either way; see
CLAUDE.md's "Camera drag over VNC".

---

**Title:** winex11: in a virtual desktop, the grab in SetCursorPos sends the pre-warp
position back as mouse input

**Version:** wine-11.19 (Kombucha `stable+20261005133651`; the code is the same upstream).

`X11DRV_SetCursorPos` does `XGrabPointer(root_window)`, `XWarpPointer`, `XUngrabPointer`.
In a virtual desktop `root_window` is the desktop's X window, and the pointer is in one
of its children. So the grab generates an `EnterNotify` on the desktop window (mode
`NotifyGrab`, detail `NotifyInferior`) carrying the position *before* the warp.

The desktop window belongs to explorer's thread. `is_old_motion_event()` compares against
that thread's `warp_serial`, which only the warping thread set, so the event isn't
recognised as old. `X11DRV_EnterNotify` then sends the stale position through
`send_mouse_input`, and the cursor jumps back to where it was just warped from.

`WINEDEBUG=+event,+cursor` excerpt (the app thread is 00e0, explorer is 00cc; the desktop
is 0x20020, the app window 0x10058):

```
00e0:trace:cursor:X11DRV_MotionNotify hwnd 0x10058/e00001 pos (410,300) is_hint 0 serial 168
00e0:trace:cursor:X11DRV_SetCursorPos warped to 500,400 serial 172
00cc:trace:cursor:X11DRV_EnterNotify hwnd 0x20020/800007 pos (510,400) detail 2
```

**Effect:** a program that warps the cursor back to an anchor after every move and reads
each move as the distance from the anchor reads every move twice. 3D viewport cameras
work this way, Roblox Studio's for one. The repro program `camprobe.c` (next to this
file) summed 70-79 px for a 40 px drag, and exactly 40 with the fix below.

**Suggested fix:** in `X11DRV_EnterNotify`, ignore crossings whose `mode` is `NotifyGrab`
or `NotifyUngrab`. They don't represent pointer motion; the motion arrives as
`MotionNotify` either way. An alternative is to make the warp serial process-wide rather
than per thread.
