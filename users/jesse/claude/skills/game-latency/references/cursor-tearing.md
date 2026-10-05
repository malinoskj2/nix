# Visible cursors, tearing and direct scanout

Read this when investigating `SW`/`HW_CURSOR` blockers, a scanout change when the
cursor appears, or whether a GPU needs Hyprland's software-cursor policy.

## Findings on the home desktop, 30 September 2026

The investigated stack was Hyprland 0.56.2, Aquamarine 0.15.0, Linux 6.18.50 and
NVIDIA's open kernel driver 615.71.09 on an RTX 5090. AION used XWayland on
DP-2 at 1920×1080/360 Hz. These are version-specific findings, not a universal
requirement for NVIDIA or Linux games.

Hyprland 0.56.2 has two independent checks in `src/output/Monitor.cpp`:

- `shouldUseSoftwareCursors()` returns true whenever tearing is active, before
  reading the cursor override. `cursor:no_hardware_cursors = 0` cannot bypass it.
- `isTearingBlocked()` sets `TC_HW_CURSOR` for a visible hardware cursor, with
  the comment: “TODO: remove this when kernel allows tearing + hw cursor updated”.

Both remain in the latest release, 0.56.2, and development commit
`e82631720b5d585d7ca09f567cb321063b7c7ab2`, checked on 30 September 2026.
See the [release source](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/output/Monitor.cpp)
and [checked development source](https://github.com/hyprwm/Hyprland/blob/e82631720b5d585d7ca09f567cb321063b7c7ab2/src/output/Monitor.cpp).

A read-only `DRM_IOCTL_GET_CAP` query on the physical NVIDIA card returned:

| Capability | Value |
| --- | --- |
| `DRM_CAP_ASYNC_PAGE_FLIP` | 1 |
| `DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP` | 1 |
| `DRM_CAP_CURSOR_WIDTH` / `HEIGHT` | 256 / 256 |

These establish advertised tearing and hardware-cursor capabilities separately.
They do not promise arbitrary cursor changes during an asynchronous commit.
See the [DRM capability definitions](https://docs.kernel.org/gpu/drm-uapi.html#drm-cap-atomic-async-page-flip).

## Why the guard still matters on this stack

In Linux 6.18.50, `drm_atomic_set_property()` allows no-op properties and a
restricted set of plane changes during `DRM_MODE_PAGE_FLIP_ASYNC`. A changed
cursor X/Y position is rejected with `-EINVAL`, before the driver's display
commit. Changing a non-primary plane's framebuffer also requires an accepting
`atomic_async_check` hook. The exact 6.18.50 implementation was compared with
6.18 and was identical. See
[Linux 6.18.50 source](https://github.com/gregkh/linux/blob/v6.18.50/drivers/gpu/drm/drm_atomic_uapi.c#L1080).

NVIDIA 615.71.09's `nv_plane_helper_funcs` supplies `atomic_check` but no
`atomic_async_check`. Its tearing selection applies to the primary plane.
Thus the advertised async capability does not remove the cursor-plane image
restriction either. See the
[matching NVIDIA driver](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/615.71.09/kernel-open/nvidia-drm/nvidia-drm-crtc.c#L2355).

Aquamarine 0.15.0's atomic backend adds pending cursor position/shape properties
to the same request as the frame. `moveCursor()` schedules a frame, rather
than submitting an independent cursor-position update. Immediate buffer
presentation adds `DRM_MODE_PAGE_FLIP_ASYNC`. Combining that flag with a changed
cursor position follows the rejected Linux path. See
[atomic cursor handling](https://github.com/hyprwm/aquamarine/blob/v0.15.0/src/backend/drm/impl/Atomic.cpp#L217)
and [DRM output handling](https://github.com/hyprwm/aquamarine/blob/v0.15.0/src/backend/drm/DRM.cpp).
The ordinary output commit path treats commits without a new primary buffer as
blocking. Moving submission to a worker thread is not itself an independent,
unsynchronised display update.

The conclusion is about this submission path: simply removing Hyprland's two
checks leaves invalid updates. It does not establish a fundamental RTX 5090
hardware limitation. Separate cursor commits were initially suggested here as
a candidate, but subsequent upstream research found a failed implementation;
see below. A stationary hardware cursor is not proof that moving, showing,
hiding or replacing it is supported through the same path.

Here “kernel” means Linux's DRM/KMS display subsystem together with NVIDIA's
`nvidia-drm` kernel module, not a GPU compute kernel.

## Upstream already tried separate cursor commits

[Hyprland PR #10020](https://github.com/hyprwm/Hyprland/pull/10020) included an
[experimental patch](https://github.com/hyprwm/Hyprland/commit/4c3b65d1e503b266a099a099985dd26a83d70ee8)
that submitted cursor movement independently of the tearing frame. This was
an implemented experiment, not just a proposed design.

On 25 June 2025, the author reported that cursor updates appeared restricted
to the refresh rate, limiting frame delivery during movement and causing
temporary stuttering. On 30 June, a tester reported choppy mouse-camera motion
and half refresh rate in Minecraft; the author attributed it to the incorrect
workaround. The author subsequently removed it and disabled hardware cursors
during tearing. See the
[synchronisation report](https://github.com/hyprwm/Hyprland/pull/10020#issuecomment-3006469895),
[regression discussion](https://github.com/hyprwm/Hyprland/pull/10020#issuecomment-3020380014)
and [removal/policy update](https://github.com/hyprwm/Hyprland/pull/10020#issuecomment-3048110422).
The corresponding upstream
[hard-override commit](https://github.com/hyprwm/Hyprland/commit/d4fbedcd355c06269f4a6207c119a546a5553526)
was made on 16 July 2025.

These historical results explain why separate commits are not an established
fix. They do not prove that every alternative fails on NVIDIA 615.71.09; that
driver was not tested with the historical workaround during this investigation.
A proper fix likely needs a Linux DRM mechanism and GPU-driver support that
avoid cursor/game synchronization stalls, then Aquamarine/Hyprland integration.
That is an engineering inference from the inspected path, not proof that a
kernel patch alone suffices or that every compositor-only alternative is
impossible. Review a supported path before proposing implementation or testing.

## Relevance to shooter gameplay

Upstream merged
[PR #13155](https://github.com/hyprwm/Hyprland/pull/13155) on 7 February 2026,
allowing tearing plus direct scanout with an invisible cursor. The investigated
build includes this change; hidden-cursor scanout was observed in AION.

During shooter gameplay that locks the mouse and hides the desktop cursor,
there is no visible cursor plane to update. A crosshair rendered in the game
frame is separate from the desktop cursor. Mouse movement still reaches the
game; hiding the cursor does not disable relative input. CS2 is an expected
fit for this path, but was not run or verified locally in this session.

Confirm the actual game's cursor state, fullscreen/content rules and remaining
scanout blockers during gameplay before claiming tearing and scanout work.
Opening menus can show a cursor and restore compositing without establishing a
problem during normal aiming. Prioritise presentation and mouse delivery in the
user's chosen shooters; do not pursue a visible-cursor kernel workaround solely
for hidden-cursor gameplay. Visible-cursor play in AION or other games remains
a relevant, unresolved case. Hidden-cursor scanout does not prove zero latency
or rule out unrelated mouse-delivery issues.

## What the observed fallback means

The visible cursor was rendered into the compositor's output and blocked direct
scanout. A hidden cursor allowed scanout to resume. `SW` is Hyprland's software
renders/cursors blocker; a GPU-drawn software cursor is not CPU software
rendering. PointerManager uses `hardwareFailed` for forced software fallback
too, so that flag alone does not prove a hardware failure.

Hyprland's composited renderer still selects immediate presentation when
`shouldTear` is true. Falling back from scanout therefore adds compositor work,
but does not inherently add a full refresh wait. The session measured neither
that overhead nor cursor/input latency. See
[renderer presentation selection](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/render/Renderer.cpp#L2253)
and [pointer handling](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/pointer/PointerManager.cpp).

The cursor investigation used source inspection and capability queries only.
No guards were removed, no DRM master/modes/properties were set, and no live
hardware-cursor-plus-tearing experiment was performed.

## Re-checking another version or machine

Identify the running kernel, driver, compositor and linked display backend.
Inspect the actual cursor override and tearing/scanout checks; then compare
backend submission with DRM property restrictions and the driver's plane hooks.
An old TODO or a newer driver version alone is insufficient evidence of support.

Keep direct scanout, tearing, cursor presentation and measured latency separate.
Do not disable explicit sync or globally change cursor/tearing policy just to
silence a blocker. A proposed experiment needs a supported submission path and
a rollback, within the user's requested scope; a patched build alone does not
validate runtime behaviour.
