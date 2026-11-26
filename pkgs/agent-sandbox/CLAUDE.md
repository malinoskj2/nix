# Sandbox

You are running inside a Docker sandbox. You may read anything you can find in the container, including the directories mapped from the host:

- `~/projects`, `~/projects-archive`, `~/nix` and `~/orca/workspaces` (Orca's worktrees), read-write, at the same paths as on the host. Missing shared directories are created by the launcher.
- `~/.orca/bots`, read-write: Orca bots' homes. A bot other than Tohru runs in its own sandbox, started from its home.
- `~/Downloads`, read-write: the host's Downloads directory, at the same path as on the host
- `/tmp/screenshot`, read-only: the human's screenshots
- `~/.local/share/unreal-engine`, read-write: Epic's Linux Unreal Engine builds
- `~/.cache/img2char3d`, read-write: model weights for `~/projects/img2char3d`
- `~/.local/share/Steam/steamapps/common`, read-write: installed Steam games, at the same path as on the host. Its Proton, Steam Linux Runtime and Steamworks Shared folders are the sandbox's own, so updating them leaves the host's untouched
- `/mnt/media3/agent-sandbox`, read-write: the sandbox's directory on the media server's NFS share, at the same path as on the host. Use it to archive large files off the host's disk. It is missing when the media server was unreachable at startup. It is a soft mount, so a long copy can fail with I/O errors; copy with `rsync`, compare, and only then delete the source
- `/mnt/media3/agent`, read-write: inactive project assets, stored under the main repository's name. Keep active assets local. Bundle asset batches into local `.tar.zst` archives with `zstd -3 -T4`, keeping external manifests for browsing, then copy with `rsync`; use its transfer verification without a separate copy-back or checksum readback. Retrieve assets locally when needed again. The shared asset-storage rule describes indexing and retrieval. This mount is absent if the share was unavailable at startup.
- `~/.claude/projects`, read-write: auto-memory and session transcripts, shared with the human's sessions outside the sandbox
- `/nix/store`, read-only, shared with the host

The rest of the home directory belongs to the sandbox, not the host. Apart from logins, Steam, sccache and the Unreal shader cache, it is wiped about once a week, so keep work in the mapped directories. The NVIDIA GPU is available (`nvidia-smi`).

## Display

The displays below aren't running unless the sandbox was launched with `--display`. Before anything that needs one (`swaymsg`, `grim`, a window, the Playwright MCP's browser, Steam), run `sandbox-display up`, or `sandbox-display up --hyprland` for the nested Hyprland too; the `sandbox-wayland-display` skill covers it. It does nothing when they're already up, and `sandbox-display status` reports them. The Unreal editor wrapper starts the sway display itself.

A headless sway Wayland session serves `$WAYLAND_DISPLAY` with a single 1280x800 output, `HEADLESS-1`. Xwayland is enabled for X11-only apps. The human can watch and drive it over VNC, or in a browser at `$AGENT_SANDBOX_VNC_URL`, a link that opens on the host. `$XDG_RUNTIME_DIR/renderer` names the renderer sway started with, and its logs are in `$XDG_RUNTIME_DIR/logs`. Audio is virtual; see [Audio](#audio).

Work on this sandbox display unless the human explicitly asks you to use the host display.

Save screenshots, recordings and other development images or videos in the current
repository or worktree root's `.tmp/` directory, which is globally Git-ignored.
The repository mounts make these files available at the same absolute host paths.
Before capturing, set `repo_root=$(git rev-parse --show-toplevel)` and run
`mkdir -p "$repo_root/.tmp"`. Report each capture's absolute host path.

If the display doesn't work, tell the user straight away instead of working around it: that includes `sandbox-display up` failing, `swaymsg` or `grim` failing, or an app failing to open a window. Also mention it if the renderer is `pixman`, which means the GPU renderer failed and the display is rendered on the CPU. Include the relevant lines from `$XDG_RUNTIME_DIR/logs`.

- Launch an app: `swaymsg exec -- <command>`
- Screenshot: `grim "$repo_root/.tmp/screen.png"`, then read the image. Coordinates in the image are output pixels.
- Region screenshot: `grim -g "X,Y WxH" "$repo_root/.tmp/region.png"`
- Windows and geometry: `swaymsg -t get_tree`
- Move the pointer: `swaymsg seat - cursor set X Y`
- Click: `swaymsg seat - cursor press button1` then `swaymsg seat - cursor release button1`
- Scroll: `wlrctl pointer scroll DY DX`
- Type text: `wtype 'text'`; keys: `wtype -k Return`, chords: `wtype -M ctrl -k l -m ctrl`

### Nested Hyprland

A second headless sway, kept off `$WAYLAND_DISPLAY` and `$SWAYSOCK`, hosts a persistent Hyprland: the host desktop's pinned version, restarted whenever it exits. It draws to its own 1920x1080 output, `NESTED-1`, the size of the desktop's main monitor, and the human can watch and drive it over a second VNC port. It loads the desktop's `look.lua` from `/run/host-hypr` for session policy and the bundled compositor plugin. The focus, title-bar, chooser and recession settings for the Tohru plugin are in `look.lua` too. The display also uses the desktop's fonts, fontconfig settings, desktop entries, icon themes and time zone database. Its cursor hides 0.1 s after the pointer stops, because a headless output draws the cursor into screenshots and the desktop's screenshots never show it. Use it to try Hyprland configs, plugins and Tohru before they reach the host.

- Clients: set `WAYLAND_DISPLAY=hyprland-1`, e.g. `WAYLAND_DISPLAY=hyprland-1 foot &`
- Screenshot: `WAYLAND_DISPLAY=hyprland-1 grim -o NESTED-1 "$repo_root/.tmp/hypr.png"`
- Control it with `hyprctl`, which finds the instance on its own: `hyprctl monitors`, `hyprctl dispatch ...`, `hyprctl plugin load <path>`, `hyprctl reload`
- Its logs are `hyprland.log`, `nested-sway.log` and `wayvnc-hyprland.log` in `$XDG_RUNTIME_DIR/logs`. If it keeps crashing, `hyprland-restarts.log` there grows.

### Host display

The human's desktop Wayland socket is mounted at `$XDG_RUNTIME_DIR/host-wayland-1` when the sandbox started while the desktop was up. `WAYLAND_DISPLAY=host-wayland-1 <command>` puts windows on the human's actual screen, and `WAYLAND_DISPLAY=host-wayland-1 grim "$repo_root/.tmp/host.png"` screenshots it. Windows and input land in the human's live session next to their own apps, so use it only when explicitly asked. If it stops accepting connections, the desktop compositor restarted since the sandbox started; say so instead of retrying.

Don't delete sockets or lock files in `$XDG_RUNTIME_DIR`: the sway and Hyprland sessions only create them at startup, so removing one cuts off every new client until the sandbox restarts.

## Audio

PipeWire, with WirePlumber and its Pulse server, runs in every sandbox with only virtual devices: nothing reaches the host's speakers or microphones, and the live desktop voice is untouched. Its logs are `pipewire.log`, `wireplumber.log` and `pipewire-pulse.log` in `$XDG_RUNTIME_DIR/logs`.

- `sandbox-speaker` is the default sink. Record what apps play with `pw-record --target sandbox-speaker -P '{ stream.capture.sink=true }' out.wav` or `parec -d sandbox-speaker.monitor --file-format=wav out.wav`.
- `sandbox-mic` is the default source, a mono microphone that hears whatever plays into the `sandbox-mic-feed` sink and silence otherwise. Feed it a recording with `pw-play --target sandbox-mic-feed speech.wav` or `paplay -d sandbox-mic-feed speech.wav`.

For an end-to-end voice test, start the recorder on the speaker, then the app, which captures from the default source and plays to the default sink, then feed the microphone and stop the recorder with `kill -INT`. Pulse clients such as Tohru's voice (`parec`, `pacat`, `pactl`) and native PipeWire clients see the same devices. Loading a voice model still needs a `gpu-run` reservation.

## Preview sites

Each sandbox publishes five preview ports on every host interface, so other devices on the LAN can open them. Choose an unused port from `$AGENT_PREVIEW_PORTS` (`8080` through `8084`) and bind the server to `0.0.0.0`. If it is occupied, try another listed port; disable any automatic fallback outside this range. The matching `$AGENT_PREVIEW_URL_8080` through `$AGENT_PREVIEW_URL_8084` URL uses the host's LAN address and works in the sandbox, on the host and on the human's other devices: use it for sandbox browser checks and give it to the human, including any required path. The host port can differ from the sandbox port. Keep the server running; links last only while the server and sandbox are running.

Media galleries don't use these ports: `media-gallery serve` publishes them on the host's gallery hub, whose links outlive the sandbox.

## Tools

`codex --cloud` (or `sandbox codex --cloud` on the host) starts Codex with `tui_multi_backend` enabled, so the TUI's Cloud backend (Ctrl-X B, then Ctrl-X E) lists ChatGPT Work cloud environments; it is off otherwise.

`tiktok-search` collects TikTok video links and metadata through Chromium, with
local date and popularity filters. It runs only when invoked; use the
`tiktok-search` skill for limits, browser-session requirements and coverage.
`last30days` provides YouTube research and optional paid TikTok search;
an existing host `~/.config/last30days/.env` is mounted read-only for API keys.
`yt-dlp` downloads videos with FFmpeg and its JavaScript runtime supplied by Nix.
`media-transcribe` runs local faster-whisper transcription only when invoked,
then exits and releases its model. It has no background service. Follow the
`audio-transcribe` skill for GPU reservations and output paths.

The sandbox includes the host's Rust toolchain, Clang and LLDB, Nix tooling, media and texture tools (FFmpeg/ffprobe, ImageMagick, MediaInfo, KTX, mpv), document converters, archive utilities, and network and graphics diagnostics. Use commands on `PATH`; there is no need to search `/nix/store` for these executables. `mpvpaper` and `swaybg` are available for testing wallpapers on the sandbox display. GCC remains the default C compiler; invoke `clang` explicitly when needed.

Orca's CLI is `orca-ide`, which forwards to `~/.orca-relay/bin/orca`, the SSH bridge to the running desktop. If an older sandbox lacks `orca-ide`, use `~/.orca-relay/bin/orca` directly. Do not launch an Orca Electron binary from `/nix/store` for CLI commands. Worktree cleanup must target only the requested worktree, including its Orca state when managed by Orca.

Blender (Cycles with CUDA and OptiX) and a Python with torch (CUDA) and hy3dgen (Hunyuan3D) are installed; `~/projects/img2char3d` runs directly on them. Chromium is installed with its own sandbox off, since the container can't run it: open pages on the display with `swaymsg exec -- chromium <url>`, or render one without a window with `chromium --headless --screenshot=<file> --window-size=W,H <url>`. The Playwright MCP server drives its own Chromium, shown on the display, and the `playwright` CLI is installed. Nix talks to the host daemon.

Playwright works from plain Node scripts: `require("playwright")` resolves, and its browsers, including WebKit's GStreamer plugins for `<video>`, are configured in the environment. Playwright's default headless Chromium renders WebGL with SwiftShader, whose slow frames, ReadPixels stalls and input delay fail gesture and animation tests falsely. For GPU rendering, launch it through the `sandbox-playwright` module, which runs the full Chromium in new headless mode on ANGLE's Vulkan backend, with or without a display:

- Script: `const { chromium } = require("sandbox-playwright"); const browser = await chromium.launch({ headless: true });`
- A project's own Playwright: `chromium.launch(require("sandbox-playwright").chromiumLaunchOptions({ headless: true }))`
- `@playwright/test` config: spread `require("sandbox-playwright").use` into the Chromium project's `use`

The Playwright MCP's browser gets the same options. Without a Vulkan GPU, both warn and fall back to SwiftShader. A browser needs no `gpu-run` reservation. Headed WebKit can't launch, since nixpkgs ships only WebKit's headless WPE MiniBrowser; run WebKit headless. Outbound network is unrestricted, and `ssh` is installed for reaching remote hosts.

There is no apt. Prebuilt Linux binaries (a downloaded release, an npm or pip package's bundled executable) run through nix-ld, whose library set covers glibc, libstdc++, zlib, OpenSSL, curl, libffi, SQLite, GLib, Mesa, Vulkan, X11 and Wayland. Get a one-off tool from nixpkgs rather than searching `/nix/store`, and always single-quote the flake reference, since zsh treats `#` as a glob:

- One command: `nix run 'nixpkgs#<package>' -- <args>`, for example `nix run 'nixpkgs#dmidecode' -- --help`. It runs the package's main program.
- Several tools together, or a binary named differently from its package: `nix shell 'nixpkgs#a' 'nixpkgs#b' -c <command>`, for example `nix shell 'nixpkgs#sqlite' 'nixpkgs#jq' -c sh -c 'sqlite3 -json db.sqlite "select 1" | jq .'`.
- Find a package's name with `nix search nixpkgs <word>`. `nix-shell -p <package>` also works; `NIX_PATH` points at the flake's pinned nixpkgs.
- Python packages from PyPI, especially wheels with C or C++ extensions (numpy, Pillow, OpenCV, torch): use `uv`, not the Nix Python's pip. `uv venv` and `uv run --with numpy script.py` use uv's own managed Python, which runs through nix-ld so the wheels find libstdc++; a venv made from the Nix `python3` cannot. Prefer nixpkgs for command-line tools and uv for importable Python libraries or a project's own `pyproject.toml`. For Node, use the project's lockfile or `npx`.
- Version-specific toolchains (a project's Node, pnpm, Go or Rust) come from its own dev shell (`nix develop`) or lockfile, not the sandbox's.

Also installed: `flock` and `setsid` (util-linux), Lua 5.4 as `lua` and `lua5.4`, PostgreSQL's `initdb`, `pg_ctl`, `postgres` and `psql`, `redis-server` and `redis-cli`, and `tomli_w` in the Nix `python3`. Run databases as your own user in a scratch directory, listening on a Unix socket there. `docker` and `docker compose` are installed only to render and check Compose files: the sandbox has no Docker engine, so stacks and fresh sandboxes go through `sandbox-runner` (see [Disposable sandboxes and Compose stacks](#disposable-sandboxes-and-compose-stacks)).

`sandbox-smoke` checks a sandbox end to end: the tools above, `require('playwright')`, uv wheels, `nix run`, Chromium's WebGL renderer on ANGLE Vulkan, WebKit decoding a local video, and `sandbox-display` with a `grim` capture (those under `gpu-run`). `--full` adds the CPU torch wheel. If no GPU grant comes within `--gpu-wait` seconds (600 by default), it skips the GPU checks and exits 75 instead of 0. It also says whether this sandbox's image is older than the one the host now installs; a session picks up a new image only when it restarts.

nvcc and the CUDA toolkit aren't on `PATH`. For a CUDA build, such as a crate using candle or cudarc, enter the Nix repo's CUDA shell: `nix develop /home/jesse/nix#cuda`, or `nix develop /home/jesse/nix#cuda -c cargo build --features cuda`. It carries the CUDA release the host driver supports, sets `CUDA_PATH`, `CUDA_ROOT` and `CUDA_COMPUTE_CAP=120` for the RTX 5090, and puts the driver and toolkit libraries on `LD_LIBRARY_PATH`, so run the binaries it builds from inside it too. Running them on the GPU needs a `gpu-run` reservation.

Steam and Proton can run here: the container allows the unprivileged user namespaces their bubblewrap needs. Start the client with `swaymsg exec -- sandbox-steam`, and launch a game with `swaymsg exec -- sandbox-steam -applaunch <appid>`. `sandbox-steam` starts Steam in offline mode whenever a saved login allows it, so the game doesn't take the account's one game session from the human playing on the host; it says which mode it used, and a client that is already running keeps its mode until `steam -shutdown`. Use `sandbox-steam --online` only when a game can't run offline, and tell the human first, since an online launch ends a game they're playing on the host. The human signs in to Steam themselves: if it opens at the sign-in screen or account picker, stop and ask them to sign in with "Remember me" checked, giving them the full `$AGENT_SANDBOX_VNC_URL` link, then wait until they confirm. That client stays online, so before launching a game, quit it with `steam -shutdown` and start it again with `swaymsg exec -- sandbox-steam`, which then starts offline. Never type or ask for their Steam credentials. Every sandbox shares the home that keeps the login, so one sign-in covers later sandboxes, and offline mode works once that sign-in is saved. When no sandbox Steam is running, the launcher copies the host's app manifests into the sandbox home's `~/.local/share/Steam`, whose `steamapps/common` holds the host's installed games, so they show as installed. The copied manifests are set to update only on launch, so the client never updates shared games or Proton builds in the background. Don't verify or update a shared game, and don't launch one that needs an update, since the host's Steam uses the same files.

All sandboxes share a 64G memory limit, and 74G together with the host's Nix builds; past either the kernel kills the largest process. CPU contention between builds is fine, but memory is shared: start another cargo build or test, including across subagents and separate target dirs, only when both `/run/agent-sandbox-cgroup` (the sandboxes) and `/run/agent-cgroup` (sandboxes plus Nix builds) leave 20G, counting each as `memory.max - memory.current` plus `memory.stat`'s `inactive_file`, since linking peaks there. Check just before starting. If `/run/agent-cgroup` is missing, the sandbox predates it: require 44G in the sandbox slice instead, reserving Nix's 24G.

Read live shared memory stats from `/run/agent-sandbox-cgroup`, a read-only mount of the host's sandbox slice. `/run/agent-cgroup` is the same for its parent, which also holds the host's Nix builds. `memory.max` and `memory.current` give the RAM limit and aggregate usage in bytes across all sandboxes; `memory.swap.max` and `memory.swap.current` give the separate swap limit and usage. `memory.max - memory.current` estimates headroom before the shared limit, but reclaimable cache can be freed and other agents can consume it concurrently. `free` and `/proc/meminfo` report host memory, while `/sys/fs/cgroup` shows only this container and hides the parent limit. Check `memory.stat` for cache and shmem usage, and `memory.events` and `memory.pressure` for reclaim/OOM activity and stalls.

Cargo compiles through sccache, whose cache at `~/.cache/sccache` every sandbox shares, so a new worktree reuses the dependency crates another one already built. Don't delete it as scratch.

## Disposable sandboxes and Compose stacks

`sandbox-runner` asks a host-side runner, private to this sandbox, to start things on the host's Docker engine. Everything it starts belongs to this sandbox: another sandbox can't see or touch it, and it is removed when this sandbox exits or after 12 idle hours. Each sandbox may run 4 disposable sandboxes, 4 stacks and 4 candidate images at once.

A disposable sandbox is a fresh sibling with one Git worktree shared read-write at the same path, its own empty home, the GPU, and its own VNC and preview ports. It has no logins and none of the other shared directories.

- `sandbox-runner sandbox launch [--worktree DIR] [--display] [--no-gpu]` starts one from this sandbox's image and prints its ID, address, VNC and preview URLs.
- To review a sandbox image change, build it and launch from the result: `sandbox-runner sandbox launch --build "$(nix build --no-link --print-out-paths .#agent-sandbox.image)"`. `sandbox-runner image load <path>` loads one without launching.
- `sandbox-runner sandbox exec ID [--cwd DIR] [--env NAME=VALUE] [--timeout S] -- COMMAND...` runs a command there and exits with its status, for example `sandbox-runner sandbox exec ID -- sandbox-smoke`.
- `sandbox-runner sandbox logs ID` and `sandbox-runner sandbox rm ID`; `sandbox-runner ls` lists what this sandbox owns.

A stack runs a project's Compose file. The file is rendered here with `docker compose config`, so `.env`, profiles and variables work as usual, and the host checks the result against an allowlist before running it.

- `sandbox-runner compose [-f FILE]... [--profile P] [--name NAME] up [--build] [--wait] [SERVICE...]`, then `ps`, `logs [SERVICE...]`, `exec SERVICE -- COMMAND...`, `build` and `down`. `down` also removes the stack's volumes, networks and built images.
- `up` and `ps` print each service's address. This sandbox joins the stack's networks, so reach services at those addresses (`psql -h <postgres address>`); published ports bind only the host's loopback, which a sandbox can't reach.
- Refused: privileged mode, added capabilities, devices and GPUs, host or other containers' namespaces, relaxed `security_opt`, external or custom-named volumes and networks, volume driver options, bind mounts or build contexts outside the worktree or through a symlink, secrets from the host environment, build SSH and host networking, `container_name` and sandbox images. Every container gets `no-new-privileges`, the sandboxes' memory slice, a pids limit and `restart: no`. The error names the key to drop.

## Unreal Engine

Use Epic's UE 5.8+ Linux installed build. The runtime and helpers are installed;
the proprietary engine ZIP must be downloaded through the human's Epic account.
Install it once on the host with
`agent-sandbox-install-unreal ~/.local/share/unreal-engine/downloads/<filename>.zip`.
Every sandbox mounts that installation, so it is available immediately on startup.
`unreal-sandbox install /path/to/Linux.zip` also works inside a sandbox.
The default root is `~/.local/share/unreal-engine/current`; set `UE_ROOT` inside
the sandbox to use another extracted build in a shared directory.

- New content project: `unreal-sandbox init ~/projects/MyGame/MyGame.uproject`
- Existing project: `unreal-sandbox prepare /absolute/path/Game.uproject`
- Editor: `UnrealEditor /absolute/path/Game.uproject` (keep it running in a terminal)
- Live check: `unreal-sandbox doctor`, or `unreal-sandbox mcp-check` for only MCP
- Build/cook/package: `RunUAT BuildCookRun -project=/absolute/path/Game.uproject -platform=Linux -build -cook -stage -pak -package`

Preparation enables `ModelContextProtocol` and `AllToolsets` and persists auto-start
preferences. The editor wrapper selects Vulkan and the sandbox's Xwayland display,
starts MCP on `http://127.0.0.1:8000/mcp`, and keeps shader cache and temporary build
files under `~/.cache/unreal-engine`. The bundled SDK/toolchain is used for C++;
GCC is not a replacement for Unreal's Linux toolchain.

Claude Code, Codex and Antigravity (`agy`) have an `unreal-mcp` connection configured.
Codex and `agy` disable it by default. For Unreal work, start the editor, then launch
`codex -c mcp_servers.unreal-mcp.enabled=true` to enable it for that session, or run
`agy mcp enable unreal-mcp` before starting `agy`.
Start the editor before starting the agent, or reconnect MCP after editor startup
or restart. A configured connection alone does not prove the engine is available:
require `mcp-check` or a successful read-only `list_toolsets` call. Discover toolsets
with `list_toolsets`, inspect them with `describe_toolset`, then use `call_tool`.
Issue Unreal tool calls serially; the editor executes them on the game thread.
Run one editor per sandbox. MCP stays on container loopback and is not published
to the host. Host harnesses use their own loopback and need a local editor.

Epic recommends 32G for one editor, nearly half the 64G limit all sandboxes share.
Avoid simultaneous editors and heavy builds; a full source-engine build needs a separately sized
environment. Preserve the installed engine and reusable shader cache when cleaning
up a task, and report their size. See `docs/unreal-sandbox.md` in the Nix repo.

## Disk

`~/projects` is on the host's disk, so anything you leave behind stays there. `/tmp` is on the host's disk too, and is deleted when the sandbox exits.

Agents here run without permission prompts, but Claude Code still asks before an `rm` or `rmdir` that targets the working directory, one of its parents, `$HOME`, a top-level directory or a glob such as `dir/*`. Name the files or subdirectories to delete instead, for example `rm -rf target build` rather than `rm -rf ./*`.

- When a task finishes, delete the target dirs, worktrees, venvs, databases and other scratch you created for it. Leave only what the human needs to keep working.
- Before finishing, check what you added with `du -sh` and report anything over a few GB that you kept.

## Local model storage

New sandboxes mount the host's model root (`$MODEL_ROOT`, on `home`
`/mnt/ext-ssd/models`) and every other weight store it links into (on `home`
`/home/jesse/.local/share/model-stores/install`) read-only at the
same paths. `MODEL_ROOT`, `HF_HUB_CACHE`, `IMG2VIDEO_MODELS` and `SAM` are passed
explicitly; runtime/compilation caches remain writable outside this mount.
Read `$MODEL_ROOT/catalog.json`, `readiness.json` and `README.md` before use.
Host synchronization is asynchronous; catalog membership is not installation.
Existing containers must be recreated to receive this mount. If the catalog is
absent, the host integration has not been deployed. Request missing aliases with
`systemctl --user start local-models-sync.service` **on the host**. Do not run a
sandbox downloader or look for a token; the host credential is never mounted.
Claude's shared rules and Codex's context include the local-models policy.
