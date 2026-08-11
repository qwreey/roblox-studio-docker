# Research index

Five parallel research passes done 2026-08-10 (originally as part of the `code-docker`
project, since split out into this standalone project). **Start with `99-SYNTHESIS.md`**
— it's the actual reconciled recommendation. The numbered files below are the detailed
sub-reports it's built from (citations, quotes, full reasoning); only dig into one if you
need to verify a specific claim.

- `99-SYNTHESIS.md` — **read this first.** The reconciled recommendation: skip VirGL
  entirely, use X11 (not Wayland) for Roblox Studio specifically, direct `/dev/dri`
  passthrough, co-locate Chrome + Claude Code, and the risks to know about before
  investing implementation time.
- `01-vinegar-sober-roblox-studio.md` — Vinegar's renderer options, why Sober's
  Wayland-nativeness doesn't transfer to Studio, the cursor-lock/docking findings that
  drove the X11-over-Wayland decision, and the Hyperion/anti-cheat risk.
- `02-virgl-gpu-virtualization-feasibility.md` — why VirGL/Venus/GFXStream/rvgpu don't
  work outside a VM for production use, and what to do instead (`/dev/dri` for
  Intel/AMD, NVIDIA Container Toolkit for NVIDIA).
- `03-headless-wayland-compositor-vnc-rdp.md` — full Wayland compositor survey
  (sway/labwc/weston/cage/Hyprland/wayfire). Not the chosen path today (see synthesis),
  but kept as a ready reference if Wine's native Wayland driver matures later.
- `04-chrome-in-container-for-claude-mcp.md` — Claude-in-Chrome's native-messaging
  architecture and why Chrome + Claude Code must run in the same container; prior art
  for "real browser window streamed to a viewer" (neko/Kasm/linuxserver).
- `05-gpu-passthrough-comparison-and-architecture-fit.md` — Intel/AMD vs NVIDIA
  passthrough comparison. (Its container-topology section talks about `code-docker`'s
  dind/router structure, which no longer applies now that this is a standalone project —
  see `../plan.md` for the actual layout instead.)

## Note on scope drift from `code-docker`

This research was originally done to evaluate folding a GPU-accelerated Roblox Studio
container into `code-docker`'s existing `dind`/`router` topology. The owner decided
against that (dind's authz plugin makes nesting privileged/GUI workloads inside it
complicated, and `code-docker` is already large enough as a project) — this is now a
fully separate, standalone Docker project with no dependency on `code-docker`,
`code-docker-dind`, or any of its networks/conventions. Ignore any part of report `05`
that talks about placing this *inside* `code-docker`'s compose topology; the rest of the
technical findings (GPU passthrough mechanics, display-server choice, VirGL verdict,
Claude-in-Chrome constraint) are unaffected by that decision and still apply as-is.
