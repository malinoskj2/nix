---
name: game-latency
description: Troubleshoot Linux game input latency and presentation on Hyprland, including tearing, direct scanout, Steam/Proton, GameMode and mouse handling. Use to observe or fix compositor and system latency for a particular game, rather than optimise its graphics preset.
---

# Game latency

Use the named game, workspace and symptoms from the user's request or invocation
arguments. Discover missing window/process details before asking the user.
The aim is to find avoidable delay in the Linux presentation and input path;
respect the user's chosen graphics settings and synchronisation tradeoffs.

## Observe without changing the experiment

- An observation request starts with read-only checks. If fixes are requested,
  make evidence-based changes within that scope and retain their rollback values.
- Query the physical desktop compositor, not an agent's nested Hyprland instance.
  Confirm the instance, output, workspace and game window before sampling.
- Keep the game focused. Do not switch workspaces, open overlays or move the mouse
  merely to inspect state. Those actions can change the path being measured.
- Use short, bounded samples during normal gameplay; extend only to answer a
  remaining question. Stop monitoring immediately when the user asks. Subsequent
  explanation or config work does not authorise resuming telemetry or captures.
- Avoid capture/recording and heavy builds during the measurement: these can
  change scanout eligibility or compete for CPU/GPU time. Save any requested
  images or videos under `/tmp/agent-media/` and report absolute host paths.
- Do not add Gamescope to solve latency or a background FPS cap by default.
  Nested Gamescope remains in the presentation path while focused too; its
  unfocused cap does not remove that extra stage when the game regains focus.

## Investigation

Read [references/checks.md](references/checks.md) for concrete commands and how
to interpret their results. This repository packages `game-latency-check` for
read-only discovery and bounded observation; use its findings and stated limits
to choose follow-up checks. Work through the branches relevant to the symptoms:

1. Identify the actual executable/PID, window class, native Wayland or XWayland,
   compositor build, driver, output mode, fullscreen state and launch wrappers.
   Read game settings from supplied evidence when available: VSync, frame caps,
   frame generation and Reflex. A menu's FPS is not gameplay performance.
2. Check live tearing and direct scanout independently. Record the actual blocker
   reasons, not just `allow_tearing`, fullscreen or a high FPS counter. Repeat
   briefly with the cursor in its natural gameplay state.
3. Inspect input settings and the identified mouse's device path. Check cursor
   blockers, raw/relative input where observable, USB interval and runtime power
   state without treating nominal polling rate as a latency measurement.
4. Inspect GameMode registration and helper failures, effective login groups,
   scheduler/affinity, CPU policy, GPU activity, memory pressure and driver errors.
   Follow evidence; avoid changing every possible performance setting.
5. If a compositor defect remains plausible, inspect the source for the running
   version and look for matching reports in primary upstream sources. Separate
   identical symptoms from proof of the same cause. Do not copy an old patch
   onto a different version without reviewing its control flow.

For `SW`/`HW_CURSOR` blockers or questions about tearing with a visible cursor,
read [references/cursor-tearing.md](references/cursor-tearing.md). Check the
compositor, display backend, Linux DRM restrictions and matching GPU driver;
separate support for tearing from support for cursor updates in a torn commit.
Do not remove compatibility checks based only on an asynchronous-flip capability.
Distinguish a visible desktop cursor from a game-drawn crosshair. For shooters,
check normal gameplay with the cursor hidden; menu fallback does not establish
a gameplay blocker. The cursor reference records a failed upstream workaround
and explains when further cursor work is relevant to the user's games.

These checks identify pipeline state and plausible delays. They do not measure
end-to-end input latency or prove that the entire system adds zero lag. State
that limit without diluting concrete findings.

## Fixes and persistence in this Nix repository

Read [references/aion-case.md](references/aion-case.md) when similar tearing or
Steam/GameMode symptoms appear. It records the original investigation and its
validation limits, not a prescribed fix for every game.

From the Nix repository root, inspect the current sources of truth:

- `hosts/home/gaming.nix`: Steam's automatic GameMode library, client/helper
  exclusions, the `gamemode` group and the desktop Hyprland package override.
- `hosts/home/steam-gamemode.patch` and `gamemode-ioprio.patch`: Steam client
  guards and the daemon's distinction between unset and explicit I/O priority.
- `hosts/home/tearing-first-frame.patch`: the version-specific tearing patch.
- `users/jesse/hyprland-desktop/hyprland/hyprland.lua`: input and game window rules.
- `users/jesse/hyprland-desktop/hyprland/look.lua`: tearing and scanout policy.
- `hosts/home/scheduler.nix`: CPU scheduling and hardware-specific preferences.
- `docs/updating.md`: coupled compositor packages and patch review requirements.

Prefer a game class/content-type rule over globally classifying every window as
a game. Steam-style classes and native game content hints cover many games, not
every executable or launcher. Discover the actual class for an uncovered title.
On the Lua configuration used here, `immediate = true` is a tearing rule; it is
not an instruction to apply all static properties to an existing window.
Content tagging may need a newly created window to take effect.

Separate reversible live experiments from persistent Nix changes. A live
`hyprctl eval`, manual GameMode registration or process affinity change is not a
declarative fix. Record which were restored and which last until process exit,
compositor restart or logout. New group membership requires a fresh login.
Steam environment changes require restarting Steam and its game processes.

For requested persistent fixes, follow the repository's activation policy:
stage new files so flakes can see them, format, inspect the diff and build the
affected host before proposing activation. Do not switch/restart the session
unless explicitly requested. Keep desktop DRM patches scoped to the physical
desktop, rather than silently changing agent compositor builds.

Report confirmed findings, unresolved checks, each change and its lifetime,
build results, and what still needs runtime verification after activation.
