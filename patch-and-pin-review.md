# Patch and pin review — 2026-11-21 (revised against `main`)

**Base:** local `main` at `acd427c`. That's 122 commits past the first draft's base `af254ad`: j2bar is replaced by Tohru, and new pins and patches were added. The worktree couldn't be reset (the reset was refused), so `main` was read with `git archive main` and `git diff af254ad main`.

**Method:** versions come from `nix eval` against each nixpkgs rev:

| Rev | Branch / role |
|---|---|
| `c56a87d` | locked `nixos-26.05` |
| `f9a75f4` | locked `nixos-unstable` (= `nixpkgs-firefox`) |
| `2786a2a` | `nixos-unstable` HEAD |
| `8ce4ef6` | `nixpkgs-hyprland` |

Upstream repos and registries were checked on 2026-11-21, and Orca against a `v1.4.268` checkout. Nothing was built, and no tracked file was changed.

## Top recommendations

1. **Update `apple-fonts` now.**
   - Apple replaced `SF-Pro.dmg` on 2026-11-04, and upstream HEAD `58b7ab5` has new `sf-pro` and `sf-compact` hashes.
   - The pinned `3861e22` fails to fetch on any machine or CI runner without the old file.
2. **Bump `nixpkgs-unstable`, then drop two overrides.**
   - nixos-unstable HEAD has **claude-code 2.1.329** (≥2.1.319) and **codex 0.171.0** (≥0.169.1).
   - Delete `overlays/claude-code/manifest.zst.json` and its `manifest =` line, but keep the `alsa-lib` override.
   - Delete `overlays/codex/`.
   - This closes task #27.
3. **Antigravity CLI: 1.5.12 → 1.5.14.**
   - The `latest` pointer says 1.5.14, and unstable HEAD has 1.5.13.
   - Bump the pin now, or drop the override once unstable reaches the version you want.
4. **Next Hyprland bump: drop `tearing-first-frame.patch`.**
   - Upstream [hyprwm/Hyprland#16572](https://github.com/hyprwm/Hyprland/pull/16572) (`b04e606`, in 0.57.x) removes the `isTearingBlocked()` check that the patch works around.
   - The bump is now blocked on **Tohru's plugin**: its flake says "Keep the optional plugin on E's reviewed Hyprland 0.56.2 package set". j2bar no longer blocks it.
5. **Orca (for the 1.4.268 worker; `main` is on 1.4.261):**
   - Use `pnpm_12`, which is in nixpkgs-unstable now (12.9.0).
   - Bump Discord presence to `ae77473` (1.1.0); all `--replace-fail` anchors still match.
   - Orca's new data-only plugin themes and syntaxes could replace `catppuccin.patch` and `nix-syntax.patch`.
   - Both new patches (`pending-below-main`, `sandbox-codex-history`) are still needed on 1.4.268.
6. **Stale vendor and tool pins:**

   | Package | Pinned | Latest |
   |---|---|---|
   | Muse | 1.4.2-R4684.1 | **1.4.24-R9131.1** |
   | deepsec | 2.3.12 | **2.3.16** |
   | last30days | 3.39.0 | **v4.5.0** |

   last30days' pinned rev also isn't the `v3.39.0` tag commit (see B).
7. **NVIDIA: wait for nixpkgs `production` to reach R620.**
   - R620 is NVIDIA's production branch (620.73.04, 2026-11-18), but nixpkgs `production` is still 595.112.07.
   - No release notes say the 615 memory-clock hitch is fixed.
8. **Firefox 160 + WaveFox `0.9.160` are ready.** It's the usual paired move, with the manual UI checks.
9. **Delete the retired Hyprland plugin sources now.** Tohru has replaced them, and nothing builds them into a host:
   - `pkgs/hyprglass` (+2 patches), `pkgs/hyprrecede`, `pkgs/hyprsheet`
   - `overlays/patches/hyprbars/*`, `overlays/patches/hyprfocus/*`
   - Update `flake.nix` `exportedPackages` and the stale mentions in `docs/design.md`, `look.lua` and `file-chooser/default.nix`.
10. **Patches to upstream:**
    - GameMode's ioprio and D-Bus fixes
    - arRPC's bridge-mod dispatcher match
    - pyghidra-mcp's stdio isolation
    - mpv's Vulkan hwdec unmap deadlock fix (part of `libmpv-vulkan.patch`)
    - Orca: read-only Claude settings, extra Codex homes, a source-commit env override, chmod after SSH extract, Nix syntax

## Summary table

### A. Patches and overrides

| Item | Recommendation | Effort |
|---|---|---|
| `hosts/home/tearing-first-frame.patch` | **Drop** with Hyprland ≥0.57 (fixed upstream) | S |
| `overlays/codex/` (0.169.1) | **Drop** after an unstable bump (0.171.0) | S |
| claude-code `manifest` override | **Drop** after an unstable bump; keep `alsa-lib` | S |
| `pkgs/antigravity-cli` override | Bump to 1.5.14, or drop when unstable catches up | S |
| Retired hyprglass/hyprrecede/hyprsheet + hyprbars/hyprfocus patches (7) | **Delete** (dead since Tohru) | S |
| `pkgs/agent-sandbox/aquamarine-nested.patch` | Keep (aquamarine 0.16.0 is unchanged); rebase on the Hyprland bump | S |
| `hosts/home/gamemode-ioprio.patch` | Keep; **upstream** | S |
| `hosts/home/steam-gamemode.patch` | Keep; upstream the D-Bus hunk | S |
| `pkgs/htop-vim-navigation/vim-navigation.patch` | Keep | — |
| `pkgs/htop-vim-navigation/vram-meter.patch` (new) | Keep; htop only has DRM-fdinfo GPU stats, which NVIDIA doesn't feed | — |
| `pkgs/mpvpaper-vk/libmpv-vulkan.patch` (new) | Keep; mpv has no Vulkan render API (only open RFCs); upstream the hwdec-unmap fix | — |
| `pkgs/mpvpaper-vk/mpvpaper-vulkan.patch` (new) | Keep; mpvpaper 1.9 is still EGL-only | — |
| `media-transcribe` ctranslate2 arch substitution (new) | Drop once nixpkgs ctranslate2 ≥4.9.0 (unstable has 4.8.5) | S |
| `qwen-prompt` llama-cpp sm_120 override (new) | Keep (build-cost choice) | — |
| `frame-interpolation` substitutions (new) | Keep (all upstream repos are at the pinned commits) | — |
| `users/jesse/arrpc/bridge-mod.patch` | Keep; **upstream** | S |
| `pkgs/pyghidra-mcp/stdio-stdout.patch` | Keep; **upstream** | S |
| hy3dgen `trust_remote_code` postPatch + torch overrides | Keep | — |
| deepsec postPatch | Keep | — |
| Orca `catppuccin.patch` | **Simplify** with a bundled data-only theme plugin | M |
| Orca `nix-syntax.patch` | **Simplify** with a bundled `syntaxes` plugin, or upstream it | S–M |
| Orca `open-video-externally.patch` | Optional drop (in-app video preview + Shift+Ctrl-click system open) | S |
| Orca `pending-below-main.patch` (new) | Keep (1.4.268 still places pending creates "atop"); upstream as an option | — |
| Orca `sandbox-codex-history.patch` (new) | Keep (no setting for extra Codex homes); upstreamable | — |
| Orca `claude-hooks`, `glass-titlebar`, `clipboard-shared-media`, `bundled-plugins`, `approved-plugins`, `structured-sandbox-*`, `agent-resume-wrapper`, `terminal-container-indicators` | Keep | — |
| Orca postPatch (`keepComputerAwake…`, source commit, glibc floor, AppImage Node, Wayland clipboard Docker, SSH chmod) | Keep; upstream the source-commit env and SSH chmod | — |

### B. Pins

| Pin | Current | Latest | Recommendation | Effort |
|---|---|---|---|---|
| `apple-fonts` | `3861e22` (09-14) | `58b7ab5` (11-05) | **Update now** (hash rot) | S |
| `nixpkgs-unstable` | `f9a75f4` (11-05) | `2786a2a` | **Update**, enables the drops above | S |
| claude-code manifest | 2.1.319 | unstable 2.1.329, npm 2.1.330 | **Drop** | S |
| Codex overlay | 0.169.1 | unstable 0.171.0, npm 0.171.0 | **Drop** | S |
| Antigravity CLI | 1.5.12 | 1.5.14 (unstable 1.5.13) | **Update** | S |
| Muse | 1.4.2-R4684.1 | 1.4.24-R9131.1 | **Update** | S |
| deepsec | 2.3.12 | 2.3.16 | **Update** (needs a lockfile regen) | S |
| last30days | 3.39.0 (`f087650`) | v4.5.0 | Update; review the major bump | M |
| Discord presence plugin | `f0ac386` | `ae77473` (1.1.0) | **Update** with Orca | S |
| Usage Insights plugin | v1.2.1 `eae3fa0` | v1.2.1 | Leave (current) | — |
| Orca pnpm | `pnpm_11` | `pnpm_12` 12.9.0 | **Switch** with 1.4.268 | S |
| `nixpkgs-firefox` + `wavefox` | 159.0.1 / 0.9.159 | 160.0.1 / 0.9.160 | Update, with the UI checklist | M |
| NVIDIA | 615.78.08 (NFB) | 620.73.04 production; nixpkgs prod 595.112.07 | **Wait** | S |
| `nixpkgs-hyprland` (0.56.2) + `tohru` | `8ce4ef6` / tohru `937918f` | Hyprland 0.57.2 | **Wait** for the Tohru plugin port | L |
| `nixos-hardware` | `d40fd26` | `3347596` | Update with a `pi` test | M |
| Eisvogel | v3.4.0 | v3.5.1 | Leave (no `sourcesans` in texlive) | — |
| hy3dgen / xatlas | `f8db630` / cp313 | same / no cp314 | Leave; blocker for the next release | — |
| frame-interpolation sources (4) | — | all HEAD = pin | Leave | — |
| pyghidra-mcp, ghidrecomp, arRPC commit, htop, GameMode | — | current | Leave | — |
| mpvpaper-vk base | release mpvpaper 1.8, mpv 0.41.0 | mpvpaper 1.9, mpv 0.42.0 | Not a pin; rebase the patches when the release moves | — |

---

## A. Patches and overrides

### tearing-first-frame.patch — drop on the Hyprland bump
- **What it does:** the first async frame isn't marked torn yet, so `isTearingBlocked()` reported `TC_NOT_TORN` and blocked the solitary redraw.
- **Upstream:** [#16572](https://github.com/hyprwm/Hyprland/pull/16572) "window: remove incorrect check, fix tearing" (merged 2026-10-20, `b04e606`) removes `!PMONITOR->isTearingBlocked()` from that condition. At v0.57.2 it's `src/desktop/view/window/Window.cpp:1812`, gated only on `HADDAMAGE`.
- **Action:** delete the patch and its assertion in `hosts/home/gaming.nix` once `nixpkgs-hyprland` is ≥0.57.

### Codex and claude-code overrides — drop after an unstable bump
- `overlays/codex/default.nix` carries the TODO "drop the override once nixpkgs-unstable reaches 0.169.1". Unstable HEAD has 0.171.0, which matches npm latest.
- The claude-code TODO ("drop the manifest once nixpkgs-unstable reaches 2.1.319") is met by 2.1.329.
- The `alsa-lib` part stays (glibc mismatch with release libasound users, per docs/updating.md).
- Afterwards, remove the docs/updating.md "Codex" section and the claude-code manifest sentence.

### Antigravity CLI — bump or drop
- `https://storage.googleapis.com/antigravity-public/antigravity-cli/latest` says `1.5.14`; the pin is 1.5.12, and unstable HEAD has `antigravity-cli` 1.5.13.
- Bump `version`, `build` and both `sha512`s from `<version>/manifest.json`.
- Once unstable carries the version you want, only the `AGY_CLI_DISABLE_AUTO_UPDATE` wrapper needs to stay.

### Retired Hyprland plugins — delete now
- `users/jesse/hyprland-desktop/tohru.nix` and the `tohru` input supply focus dips, title bars, chooser sheets and launcher recession.
- `pkgs/hyprglass` (0.8.1, plus `layer-shape.patch` and `panel-contrast.patch`), `pkgs/hyprrecede` and `pkgs/hyprsheet` are still in `exportedPackages`, but no host installs them.
- `overlays/patches/hyprbars/{unload-listeners,transformed-pass}.patch` and `overlays/patches/hyprfocus/{render-shrink,combined-modes,class-filter}.patch` aren't referenced by any `.nix` file.
- The only remaining mentions are prose: `docs/design.md:153-200`, `hyprland/look.lua:44,73` and `file-chooser/default.nix:47`.
- **Action:** delete the directories and the `exportedPackages` entries, and reword those comments in terms of Tohru.

### aquamarine-nested.patch — keep
At aquamarine v0.16.0, `src/backend/Wayland.cpp:125` still binds `xdg_wm_base` version 6, and `GBM.cpp` still requests LINEAR and records `attrs.modifier = modifier`. A bind of `min(advertised, 6)` is upstreamable.

### GameMode patches — keep, upstream parts
- GameMode's latest release is still 1.8.2 (2024-08-19).
- Master has neither the `IOPRIO_CLASS_NONE` → niceness mapping nor any change to `client_loader.c`.
- Upstream the ioprio fix (a real bug) and the NULL pending-call check. The SteamAppId gating is local policy.
- With j2bar gone, `gaming.nix` no longer has `j2bar.gameEngine`, and `gpu-scheduler` is added to GameMode `extraPackages`. Neither affects the patches.

### htop patches — keep
- **vim-navigation:** htop `main` has no h/j/k/l mode.
- **vram-meter (new, 263 lines):** dlopens NVML (`/run/opengl-driver/lib/libnvidia-ml.so.1`) for NVIDIA VRAM and usage meters. Upstream htop's `linux/GPU.c` only reads DRM fdinfo (`drm-*` keys), which the NVIDIA driver doesn't fill in, and there's no NVML meter upstream.

### mpvpaper-vk patches (new) — keep
- mpv master has no Vulkan render API: `include/mpv/render.h` has no Vulkan entries, and `render_vk.h` doesn't exist.
- The related PRs are open RFCs: [#16818](https://github.com/mpv-player/mpv/pull/16818), [#17828](https://github.com/mpv-player/mpv/pull/17828), [#18607](https://github.com/mpv-player/mpv/pull/18607), [#18845](https://github.com/mpv-player/mpv/pull/18845).
- mpvpaper 1.9 (2026-07-18) is the latest and still EGL.
- The base is release mpvpaper 1.8 / mpv 0.41.0; mpv 0.42.0 (2026-11-05) is in unstable, so expect a rebase on the next release.
- The `AVVkFrame` unmap-after-render deadlock fix is a good standalone mpv PR.

### media-transcribe ctranslate2 substitution (new) — drop later
- CTranslate2 v4.9.0 (2026-11-10) dropped `cuda_select_nvcc_arch_flags(ARCH_FLAGS …)` for `CMAKE_CUDA_ARCHITECTURES`. It's still present through v4.8.0.
- nixpkgs has 4.7.2 in the release and 4.8.5 in unstable, so the `--replace-fail` is needed for now.
- **Action:** once nixpkgs ctranslate2 is ≥4.9, replace the substitution with `CMAKE_CUDA_ARCHITECTURES=120` (or drop it if nixpkgs sets it from `cudaCapabilities`).

### frame-interpolation and qwen-prompt (new) — keep
- `mamba-ssm`'s transformers-5 import fix, ComfyUI-Frame-Interpolation's ckpts path, and ToonCrafter's `weights_only` and OpenCLIP fixes all patch upstreams that haven't moved: every repo's HEAD equals the pin.
- `qwen-prompt`'s sm_120-only llama-cpp is a build-cost choice.

### arRPC bridge-mod.patch — keep, upstream
The last change to `examples/bridge_mod.js` is `3c4e1ce` (2026-04-08), which is our pin. The Proxy-matching bug is still upstream.

### pyghidra-mcp stdio-stdout.patch — keep, upstream
`server.py` on main only routes logging to stderr; Ghidra and ghidrecomp output on fd 1 still corrupts stdio.

### hy3dgen — keep
Hunyuan3D-2 HEAD = pin. The release's diffusers is 0.38.0, so `trust_remote_code` is still required. `main` only adds `passthru.pythonPackages`, for frame-interpolation.

### Orca (main 1.4.261; evaluated against v1.4.268)
1.4.268 moved many files; the 1.4.268 worker has to retarget the paths.

- **catppuccin.patch → simplify.**
  - 1.4.268 has public, additive-only plugin `appThemes`: `PLUGIN_APP_THEME_TOKENS`, diff and link tokens, and VS Code-shaped `tokenColors` that feed Monaco (`plugin-monaco-theme.ts`).
  - A bundled data-only Catppuccin Mocha plugin, selected with `pluginAppThemeDark` and the code-editor theme in `globalSettings`, could replace the source patch.
  - Compare screenshots first: the public token list may miss surfaces the patch maps.
  - The built-in `match-terminal` slot plus the shipped "Catppuccin Mocha" terminal theme covers the chrome but not Monaco syntax colours.
- **nix-syntax.patch → simplify or upstream.** 1.4.268 accepts plugin `syntaxes`. Upstream already registers zig, nim, lean and others, so a `register-nix.ts` PR is the clean drop.
- **open-video-externally.patch → optional drop.** 1.4.268 has a `video` file-preview kind, and Shift+Ctrl-click opens with the system default. A plain click would preview in Orca instead of opening mpv.
- **pending-below-main.patch (new):** 1.4.268 `group-sections.ts:204` still says "Place in-progress creates atop their own repo". Keep; propose upstream as an option.
- **sandbox-codex-history.patch (new):** `getHostCodexHomePathsForSessionDiscovery()` in 1.4.268 only adds Orca-managed, system and per-account homes, with no configurable extras. Keep; upstreamable as an "extra Codex homes" setting.
- **Unchanged findings:**
  - `claude-hooks`: upstream still edits `~/.claude/settings.json`.
  - `glass-titlebar`: material is `off` unless terminal opacity < 1.
  - `clipboard-shared-media`: still OS temp; a `TMPDIR` override would leak into child shells.
  - `bundled-plugins`/`approved-plugins`: the stablyai publisher check remains, with no policy list.
  - The sandbox patches: no upstream analogue.
  - postPatch anchors: all still present.
  - `keepComputerAwakeWhileAgentsRun`: setting it via `globalSettings` would force it, so keep the default substitution.
- **Build inputs:** `packageManager` is `pnpm@12.18.0` (use unstable's `pnpm_12` 12.9.0; docs/updating.md still says it's missing). `electron` is 43.8.10, which `electron_43` covers. `engines.node` is 24.
- **Bundled plugins:** Discord presence `f0ac386` → `ae77473` (12 commits: stalled-connect fixes, 1.1.0 panel). All five `--replace-fail` anchors match; two match twice, harmlessly, in validation paths. Usage Insights `eae3fa0` = v1.2.1, the latest.

## B. Pins

### apple-fonts — update now
The `sf-pro` and `sf-compact` narHashes differ between the pin and HEAD `58b7ab5` (2026-11-05). `SF-Pro.dmg` has `Last-Modified: 2026-11-04`. `main`'s newest commit makes Apple fonts the fontconfig defaults, so fresh builds now depend on them even more.

### nixpkgs-unstable — update
Locked `f9a75f4` (2026-11-05) → HEAD `2786a2a`. This brings claude-code 2.1.329, codex 0.171.0, antigravity-cli 1.5.13 and mpv 0.42.0 to `pkgs.unstable` users.

### Muse / deepsec / last30days — update
- **Muse:** the channel `https://api.meta.ai/muse-code/channels/muse-stable` says `1.4.24-R9131.1`. Refresh both artifact hashes and check `contributorModel`.
- **deepsec:** npm latest is 2.3.16. Regenerate `package-lock.json` and `npmDepsHash`.
- **last30days:**
  - The pin is `version = "3.39.0"` at `f0876504`, but the tag `v3.39.0` peels to `f918b49`, so the version label doesn't match the commit.
  - The latest tag is `v4.5.0` (`8ede659`); main is still active (HEAD commit 2026-11-21).
  - Re-pin to a tag commit, and review the 4.x changes before bumping.

### NVIDIA — wait
- **Pinned:** 615.78.08, which is nixpkgs' `new_feature`.
- **NVIDIA:** R620 is production ([620.70.06](https://phoronix.com/news/NVIDIA-620.70.06-Linux-Driver), [620.73.04](https://phoronix.com/news/NVIDIA-620.73.04-Linux), 2026-11-18). The NFB stays at 615.78.08 ([comss.ru](https://www.comss.ru/page.php?id=22952)).
- **nixpkgs:** `production` is still 595.112.07, at both the locked and HEAD unstable.
- No 620 notes mention the memory-clock hitch, and a [forum report](https://forums.developer.nvidia.com/t/620-release-feedback-discussion/388030?page=3) of multi-monitor trouble on 620.70.06 was fixed by going back to 615.78.08.
- **Recommendation:** wait for nixpkgs `production` = 620, then test against `docs/nvidia-memory-clock.md`. Task #62 should now track 620.73.04.

### Firefox + WaveFox — update with checks
Firefox 160.0.1 is at nixos-unstable `2786a2a` (and in nixos-26.05), and WaveFox tag `0.9.160` = `db74fb4`. Move them together, then run the docs checklist (Nova, WaveFox CSS, cascade layers, the 159 horizontal-tab overrides, arRPC AutoConfig).

### Hyprland 0.56.2 + tohru — wait
- nixos-unstable has Hyprland 0.57.2 (aquamarine 0.16.0, portal 1.5.0).
- The `tohru` input follows `github:malinoskj2/tohru` main (locked `937918f`, 2026-11-21). Its `hyprland-nixpkgs` follows `nixpkgs-hyprland`.
- Tohru's own flake still says "Keep the optional plugin on E's reviewed Hyprland 0.56.2 package set" and locks `8ce4ef6`. The plugin must be ported and reviewed for 0.57 first.
- The local `~/projects/tohru` is 8 commits ahead of `origin/main`, so `nix flake update tohru` won't see those until they're pushed.
- **Order:** Tohru plugin port → bump `nixpkgs-hyprland` → drop the tearing patch → rebase `aquamarine-nested.patch` → update the `supportedHyprland` assertion (`hyprland/default.nix:10`) and the `gaming.nix` assertion.
- Tohru's separate `nixpkgs` (`nixpkgs_2`, `4fe25e1`) is deliberate (docs: keeps the Pleamar build cached).

### nixos-hardware — update with a pi test
Since `d40fd26`:
- Pi kernel 6.18.50 → 6.18.60 (`4f3084d`)
- a fix for Linux 7.3 headers (`73ff92f`)
- firmware migrations for audio and PWM (`e2035d2`, `5d01b9f`); `hosts/pi` sets neither

### Eisvogel — leave
v3.5.1 is the latest. `texlive.pkgs.sourcesans` is absent at every rev checked; only `sourcesanspro` 2.8 exists.

### hy3dgen / xatlas — leave; upcoming blocker
- The release's Python is 3.13, so the cp313 wheel is fine.
- nixos-unstable is on Python 3.14.10, and xatlas 0.0.11 has no cp314 manylinux wheel.
- The next NixOS release breaks hy3dgen, and through `passthru.pythonPackages` also frame-interpolation, unless xatlas publishes one or it's built from the sdist with the submodule fetched.

### Current or no action
- **pyghidra-mcp** 0.3.0 and **ghidrecomp** 0.5.9 are the latest on PyPI.
- **arRPC** bridge commit = HEAD.
- **htop** assertion covers 3.5.3 (latest).
- **GameMode** 1.8.2 is the latest.
- **Usage Insights** is at v1.2.1, the latest.
- **frame-interpolation**'s four sources are at HEAD.
- **media-gallery**'s fontsource npm fetches are minor and unreviewed.

### Doc drift
- docs/updating.md: "`pnpm_12`, which `nixpkgs-unstable` doesn't have yet" is false (12.9.0 is present).
- `docs/design.md`, `hyprland/look.lua` and `file-chooser/default.nix` still describe hyprfocus, hyprbars, hyprglass, hyprsheet and hyprrecede as the effect providers.
- After the drops above: remove the docs' Codex section and the claude-code manifest sentence.
