# GPU passthrough options for code-docker: comparison + architecture fit

Research task, 2026-08-10. Scope: compare GPU-access mechanisms for running
Wine/Vinegar (Roblox Studio) + Chrome under a headless Wayland compositor
inside code-docker's stack, and recommend where the capability should live
topologically. A sibling report does the deep VirGL/vtest technical-feasibility
dive; this report treats that path as a black box and focuses on comparison +
placement.

## 1. Direct `/dev/dri` passthrough (Mesa in-container)

For AMD (RADV) and Intel (ANV), passthrough is close to uniform:

- The container needs `--device /dev/dri` (or a specific
  `/dev/dri/renderD12x` node) plus render-group membership. No host driver
  binary is copied into the container — Mesa userspace lives entirely inside
  the image, talking to the host kernel's DRM uAPI (`amdgpu`/`i915`/`xe`),
  which is a stable, versioned kernel ABI. As long as the in-container Mesa
  is "new enough" for the GPU generation, host and container Mesa versions
  do **not** need to match. This is exactly the same "uniform via upstream
  Mesa" argument the task description already anticipated, and the search
  results back it: Intel/AMD guidance across multiple current writeups
  (Jellyfin, Tdarr, DiyMediaServer, home-lab guides) is uniformly "map
  `/dev/dri`, install `mesa-va-drivers`/`intel-media-va-driver` in the
  image, add render group" — no host-version pinning step anywhere.
  [Jellyfin Docker GPU Passthrough guide](https://jellywatch.app/blog/jellyfin-docker-gpu-passthrough-intel-nvidia-amd-2026),
  [DiyMediaServer GPU passthrough](https://diymediaserver.com/post/install-docker-debian-gpu-passthrough-transcoding/),
  [Tdarr hardware transcoding docs](https://docs.tdarr.io/docs/installation/docker/hardware-transcoding/)
- NVIDIA is the real special case: the proprietary driver requires the
  **exact same driver version** inside the container as installed on the
  host (the kernel module and the userspace libraries are one matched pair,
  unlike Mesa's stable-DRM-uAPI model), mediated by the NVIDIA Container
  Toolkit which bind-mounts the host's own driver libraries into the
  container at runtime rather than shipping them in the image. This is a
  fundamentally different mechanism (`--gpus all` / CDI device requests vs.
  a plain `--device` bind), and confirmed by search results: "containers
  will use the host's GPU drivers automatically" via the toolkit, as opposed
  to Intel/AMD where "you don't need to install GPU drivers inside the
  container" at all beyond Mesa itself.
  [docker/cli GPU flag issue](https://github.com/docker/cli/issues/2063),
  [GPU passthrough home-lab writeup](https://www.virtualizationhowto.com/2025/10/how-to-run-gpu-enabled-containers-in-your-home-lab/)

**Conclusion for §1: yes, the "per-GPU variance" problem is overwhelmingly
an NVIDIA-only problem.** A single image built with a reasonably current
Mesa (RADV + ANV both ship in the same `mesa` package, selected
automatically by the Vulkan ICD loader based on which PCI device is
present) already covers Intel and AMD hosts uniformly with zero
per-host-vendor branching. NVIDIA is the one host-GPU-vendor that would
force either (a) a separate image variant with the NVIDIA Container Toolkit
wired in and a driver-version compatibility contract with the host, or (b)
falling back to software rendering / VirGL on NVIDIA hosts specifically. If
the user's actual fleet is Intel/AMD-heavy with NVIDIA as a minority case,
plain `/dev/dri` passthrough + "detect vendor, use NVIDIA toolkit path only
if present" is a smaller amount of engineering than standing up a full
VirGL provider architecture just to paper over one vendor.

## 2. VirGL/Venus "GPU provider" container — architectural evaluation

The pattern the user describes (one privileged container owns the real
`/dev/dri` + driver stack; other containers reach it purely over a
socket/protocol, no direct device access) is a real, existing pattern
class, not a speculative one — it's precisely what virglrenderer's
**vtest-server** and Venus's **render-server proxy mode** already do, just
not historically marketed for "container-to-container" use — their designed
use case is "let a guest/test process get GPU acceleration without a full
VM," which is architecturally identical to "let a client container get GPU
acceleration without touching `/dev/dri` directly":

- vtest-server: "a lightweight way to perform headless testing without
  requiring a full virtual machine... operates as a test server that
  communicates with Mesa drivers" over a Unix socket — this is the
  general-purpose Gallium/OpenGL(-ish) transport.
  [virglrenderer-test-server (Fedora)](https://packages.fedoraproject.org/pkgs/virglrenderer/virglrenderer-test-server/index.html),
  [VirGL — Mesa docs](https://docs.mesa3d.org/drivers/virgl.html)
- Venus render-server proxy mode: "Venus has a 'proxy mode' where it will
  forward commands to another process called the render server for its
  execution, to improve security... virglrenderer spawn[s] a render server
  automatically, taking care to pass it an IPC socket to communicate over."
  This is the Vulkan-specific transport, and it's explicitly designed with
  process-isolation as a first-class goal (i.e., the "server never trusts
  the client" security posture this kind of architecture needs).
  [Virtio-GPU Venus — Mesa docs](https://docs.mesa3d.org/drivers/venus.html)
- Real-world precedent for exactly this "one process owns the GPU, others
  reach it over Venus/virglrenderer with zero vendor-specific client
  config" shape already exists in production-adjacent form: Podman's
  macOS GPU acceleration path runs Vulkan calls inside a Linux container,
  serializes them with the Venus protocol over virtio-gpu, and the *host*
  side (outside the client container) deserializes and calls into
  MoltenVK/Metal — the client container itself only ever speaks the
  generic Venus/virtio-gpu ICD, never anything Apple-Metal-specific.
  [Red Hat: AI inference in Podman on macOS](https://developers.redhat.com/articles/2025/06/05/how-we-improved-ai-inference-macos-podman-containers)

**What a calling (client) container would need:** just the Mesa
`virtio_gpu`/`virpipe` Vulkan ICD (or virgl Gallium driver for GL) and a
socket path to reach the provider — no AMD/Intel/NVIDIA-specific package at
all. That is the actual mechanism that would deliver the user's
"one mechanism, no per-host-GPU-vendor container config" goal, because the
vendor-specific complexity (RADV vs. ANV vs. NVIDIA proprietary + Container
Toolkit) collapses down into a single place: the provider container, built
once per host and swapped, while every *client* container's Dockerfile/image
stays identical regardless of host GPU vendor. This is the one part of the
comparison where VirGL/Venus is doing something plain `/dev/dri` passthrough
structurally cannot: it moves the NVIDIA-vs-Mesa branching out of the
per-workload image and into a single provider image, at the cost of the
extra hop and protocol-completeness risk the sibling report is evaluating.

Caveat surfaced during this research that the sibling feasibility report
should weigh: DXVK (needed for D3D11-based Roblox rendering paths) requires
**Vulkan 1.3 conformance plus `VK_EXT_robustness2` and
`VK_EXT_transform_feedback`**, and Roblox's own *native* Vulkan renderer
(which would sidestep DXVK) is reported as having known swapchain
presentation bugs (`VK_ERROR_OUT_OF_DATE_KHR`) independent of any
virtualization layer.
[DXVK driver support wiki](https://github.com/doitsujin/dxvk/wiki/Driver-support),
[Vinegar renderer docs (DeepWiki)](https://deepwiki.com/vinegarhq/vinegar/4.3-renderer-and-graphics-settings)
Venus's extension coverage is actively evolving and vendor/version-dependent
— Collabora has written specifically about gaps here.
[A look at Vulkan extensions in Venus — Collabora](https://www.collabora.com/news-and-blog/blog/2022/10/19/a-look-at-vulkan-extensions-in-venus/)
This doesn't change the *architectural* verdict in this section (the pattern
is sound and has real precedent), but it's a concrete reason the "does it
actually work well enough for DXVK-based Roblox Studio" question can't be
assumed away — that's exactly the sibling report's job.

## 3. Software rendering fallback (llvmpipe/lavapipe)

Uniform (pure CPU, zero vendor variance) but the performance data says it's
not viable for an interactive 3D editor:

- "Lavapipe struggles with highly dynamic interactive scenarios where frame
  time can exceed 1 second, but achieves good fps (30-60) while
  panning/rotating **static** scenes." That "1 second frame time" case is
  precisely what an interactive editor like Roblox Studio does constantly
  (live viewport manipulation, script execution, property panel updates) —
  not the panning-a-static-scene case where it does okay.
  [Lavapipe performance question — mesa-dev mailing list](https://www.mail-archive.com/mesa-dev/msg224521.html),
  [Sketchy Vulkan benchmarks: Lavapipe vs SwiftShader](https://airlied.blogspot.com/2021/03/sketchy-vulkan-benchmarks-lavapipe-vs.html)
- For Chrome-only workloads (2D UI, video, WebGL-light pages), llvmpipe is
  a materially better story: Chromium's own compositor is far less
  frame-time-sensitive than a 3D editor, and community benchmarking shows
  llvmpipe beating SwiftShader (Chromium's other software path) by a wide
  margin on CPU cost for exactly this use case (~49% CPU reduction in one
  measured case).
  [Mesa llvmpipe vs SwiftShader: Cut Chromium CPU by 49%](https://botbrowser.io/en/blog/mesa-llvmpipe-vs-swiftshader-chromium-linux/)

**Conclusion for §3:** llvmpipe/lavapipe is a reasonable no-GPU degrade
path *for Chrome specifically*, but should not be relied on as the primary
path for Roblox Studio — confirms the task's prior. It's worth keeping as
an automatic fallback (same "graceful degradation for non-essential setup"
pattern this project already uses elsewhere) rather than a hard requirement
to solve, though.

## 4. VirtualGL (X11 GLX forwarding) — noted, likely not the fit here

VirtualGL is a different pattern class entirely: it doesn't virtualize the
GPU protocol, it runs the real GL/GLX calls against a real X server that
has the GPU, then captures and forwards the rendered *pixels* to a
separate display X server. Its own docs frame the use case as "server-side
hardware-accelerated 3D rendering for remote desktop setups... where the X
server that handles the application... cannot access the graphics
hardware," i.e., thin-client/remote-desktop image streaming, not
inter-container API virtualization.
[VirtualGL 2.0 User's Guide](https://virtualgl.org/vgldoc/2_0/)
This only becomes relevant to code-docker if the eventual compositor choice
(a sibling research task) ends up being X11/XWayland-based rather than
Wayland-native — in a Wayland-native design there's no GLX/X server
boundary for VirtualGL to sit at, so it doesn't compete with §1/§2 as a
primary mechanism here. Noted per the task's request, not recommended
further without knowing the compositor decision.

## Architecture fit: where should this live in code-docker's topology?

**Recommendation: a new sibling subtree, e.g. `code-gpu/` → service
`code-docker-gpu`, attached only to `code-docker-internal` — not folded
into `code-docker-dind`, and not exposed to `code-docker-external`.**

Reasoning, working through the three options the task posed:

**(a) Folded into `code-docker-dind` itself — recommend against, despite
matching the user's stated preference.** The user's instinct ("group it
with dind, since dind is already privileged and isolated") is sound on the
*trust-tier* axis — dind is indeed already the highest-privilege container
short of router — but conflates trust tier with process/responsibility
identity. This repo has an explicit precedent for exactly this
distinction: router keeps netgate/tailscale/dev-proxy/tinyauth as **separate
supervisord programs within one container**, not because they need
different trust levels (they're all "router-tier trusted"), but because
they're independently restartable, independently configurable, and
independently debuggable services that happen to share a trust tier and a
network position. Folding a GPU-accelerated Wine/Roblox Studio + Chrome GUI
workload directly into `code-docker-dind` would mean:
- `dockerd` (the actual reason dind is privileged) and a heavyweight,
  crash-prone GUI/Wine stack now share fault domains — a Wine/DXVK crash or
  an OOM from a memory-hungry Studio session risks the same container that
  hosts every nested `docker` container's daemon.
  `code-dind/CLAUDE.md` already frames dind as "meaningfully more trusted...
  changes here should be held to that higher trust bar" — adding a large,
  novel, third-party-app-shaped attack/crash surface (Wine, a compositor, a
  proprietary or semi-maintained game client) directly into that
  container's blast radius works against that stated bar, not with it.
- It muddies `code-dind/`'s stated scope (`Dockerfile` build source for
  "the privileged Docker-in-Docker daemon code-docker talks to") with an
  unrelated GUI-rendering responsibility, the same kind of scope creep this
  repo's per-feature-subtree convention (`router/`, `code-dind/`,
  `netinit/`) exists to avoid.
- It does **not** actually require folding to get the "reachable from
  inside dind" property the user wants — see below.

**(b) A new sibling container — recommended.** This preserves everything
the user actually wants functionally while keeping the separation this
repo's architecture already insists on elsewhere:
- **Trust tier / privilege**: it needs `/dev/dri` access (a `--device`
  bind, not `privileged: true`) plus whatever the compositor needs
  (likely no `NET_ADMIN`, no Docker socket, no host-namespace access at
  all) — a materially *lower* privilege footprint than dind's, so grouping
  it at dind's trust tier by folding it in would actually be
  over-privileging it, not matching it correctly.
- **Network**: it should stay on `code-docker-internal` only, same
  reasoning code-docker/dind already use — it's a rendering/compute
  service being *called*, not something that needs to originate internet
  connections at all. It doesn't need `code-docker-external`; nothing about
  local GPU rendering requires egress, and giving it egress would be an
  unnecessary widening of router's filtered boundary for no functional
  gain.
- **"Reachable from inside dind" without folding in**: give the new
  service (e.g. `gpu`) a `code-docker-internal` network alias, the same
  pattern `dind` and `router`/`forward` already use for cross-container
  addressing in this repo. Anything running *inside* dind's nested Docker
  daemon reaches it the same way it already reaches anything else outside
  its own private inner network — `gpu:<published-port>` — which is exactly
  the existing "dind:<published-port>" idiom this repo's CLAUDE.md already
  documents for the reverse direction. This gets the user's actual goal
  (GPU capability usable from processes running inside dind) without
  merging two unrelated fault/responsibility domains into one container.
- **Structure**: follow the `router/`/`code-dind/` convention exactly — own
  `Dockerfile`, own `CLAUDE.md`, own `config/<program>/` per-feature
  folders (e.g. `config/compositor/`, `config/gpu-provider/` if the VirGL
  provider pattern from §2 is adopted), own default/override pairs, added
  as its own service block in the root `docker-compose.yml` with an
  env-configurable volume under `data/gpu` (matching the `data/`
  consolidation already done for dind/code/sshd/router).
- If the VirGL/Venus provider pattern from §2 is what the sibling
  feasibility report lands on, this new container is also the natural
  place for it to live: it becomes the one image built per-host-GPU-vendor
  (owns `/dev/dri`, the matched Mesa or NVIDIA driver stack, and the
  provider process), while every client (Wine/Roblox Studio, Chrome, and
  anything else) — whether running directly in this container or inside
  dind's nested daemon reaching it over the network alias — stays on one
  vendor-agnostic client image, which is exactly the "one mechanism, no
  per-host-GPU-vendor container config" property the user asked for.

**(c) Something else** — not indicated by this research; (b) satisfies the
stated goals without inventing a new topology primitive this repo doesn't
already use elsewhere.

## Bottom line

1. Per-GPU variance is overwhelmingly an NVIDIA-only problem; Intel/AMD via
   plain `/dev/dri` + Mesa is already uniform.
2. If NVIDIA hosts are common enough in the user's actual fleet to justify
   the extra hop/complexity, the VirGL/Venus provider pattern is
   architecturally sound and has real precedent (vtest-server, Venus
   render-server proxy mode, Podman-on-macOS's Venus-over-virtio-gpu path)
   — it genuinely delivers a vendor-agnostic client image, at the cost of
   protocol-completeness risk (DXVK's Vulkan 1.3 + robustness2 +
   transform_feedback requirement) that the sibling feasibility report
   needs to confirm.
3. llvmpipe/lavapipe is a reasonable Chrome-only fallback, not viable as
   the primary path for Roblox Studio.
4. VirtualGL is the wrong pattern class unless the compositor decision
   lands on X11/XWayland.
5. Build this as its own sibling subtree/container (`code-gpu/` →
   `code-docker-gpu`), `code-docker-internal`-only, network-aliased so it's
   reachable from inside dind's nested daemon without folding the GUI/Wine
   workload into dind's own fault domain — matching this repo's existing
   `router`/`code-dind` per-feature-subtree convention rather than
   conflating dind's Docker-daemon responsibility with a new,
   unrelated GPU-rendering one.
