# Unreal Engine in the agent sandbox

The sandbox includes Linux runtime libraries, Vulkan diagnostics, the foreign ELF
loader, `UnrealEditor`, `RunUAT`, and `unreal-sandbox`. It uses Epic's native MCP
from UE 5.8+, with `ModelContextProtocol` and `AllToolsets` enabled per project.
The engine itself is supplied separately: Epic's Linux download requires an Epic
account and is not fetched or redistributed by this flake.

## Install and start

Apply the Nix configuration through the usual host workflow.
Download the UE 5.8+ Linux ZIP from [Epic's Linux page](https://www.unrealengine.com/linux)
and save it in `~/.local/share/unreal-engine/downloads/`. Install it once on the host:

```sh
agent-sandbox-install-unreal ~/.local/share/unreal-engine/downloads/<filename>.zip
```

Every sandbox then mounts that host installation at the same path. The engine
is already available when a sandbox starts; startup does not extract it again.
The editor still runs inside the sandbox and must be launched to serve MCP.
Existing running containers keep their previous image and mounts until restarted.
Inside a new sandbox:

```sh
unreal-sandbox init ~/projects/MyGame/MyGame.uproject
UnrealEditor ~/projects/MyGame/MyGame.uproject
```

Use `unreal-sandbox prepare /absolute/path/Game.uproject` for an existing project.
Both `prepare` and the editor wrapper update the project's plugin entries and
per-user MCP preferences, preserving other settings. `init` creates a minimal
content-only project; C++ projects should use an appropriate engine template.
Inspect the `.uproject` change before committing it.

The engine is extracted into `~/.local/share/unreal-engine/<archive-name>` and
selected by the `current` symlink. The host shares that directory with every
sandbox. Installation requires space for both the downloaded ZIP and extracted
engine; it refuses to replace an existing installation directory. An extraction
failure leaves the directory for inspection. Alternatively, set `UE_ROOT` inside
the sandbox to an extracted Linux build in `~/projects` or another shared path.
Source checkouts must already have a compiled editor and the required plugins.

The wrapper uses the sandbox display through Xwayland and the NVIDIA Vulkan ICD.
It keeps Derived Data Cache and temporary files in `~/.cache/unreal-engine` rather
than the 4G `/tmp` tmpfs. Cache persists in the sandbox home. Build scripts and
bundled compiler/.NET binaries use the sandbox's `nix-ld` loader and runtime
libraries. `RunUAT` forwards arguments to the engine's automation tool:

```sh
RunUAT BuildCookRun -project=/absolute/path/Game.uproject \
  -platform=Linux -build -cook -stage -pak -package
```

## Agents and verification

Claude Code's sandbox plugin, Codex, OpenCode and ZCode configure `unreal-mcp`
at `http://127.0.0.1:8000/mcp`. Codex and ZCode's persistent configs refresh the
managed entry on container startup, preserving other servers and agent settings.
OpenCode receives the connection through `OPENCODE_CONFIG_CONTENT`, while its
host config and plugins are mounted read-only when present. Home Manager also
configures the connection for each host harness; host loopback refers to a host
editor, not an editor inside Docker. No Unreal port is published from Docker.

Start the editor before the agent, or reconnect the agent's MCP after startup.
Editor restarts require reconnecting existing direct HTTP sessions. One editor
per sandbox is supported; the wrapper holds a lock for its lifetime.

```sh
unreal-sandbox doctor
unreal-sandbox mcp-check
```

`doctor` validates the selected engine, GPU, Vulkan, compositor and MCP. `mcp-check`
performs a real HTTP initialization, lists tools, and calls `list_toolsets`.
Agents use `list_toolsets`, `describe_toolset` and `call_tool` for on-demand
discovery. Issue calls serially, as required by Unreal's game-thread execution.
A visible configuration entry or successful protocol fixture test is insufficient
evidence that the real editor works.

Epic recommends 32G RAM. The current sandbox slice shares a 20G limit across all
containers. Run one editor/heavy build at a time; full source-engine compilation
requires a separately sized environment. Keep reusable engine/cache files and
report their disk footprint. Store captures in `/tmp/agent-media` and provide
their absolute host paths.

## Validation status

The runtime tools, project/config preservation and HTTP MCP client are testable
without Epic credentials. The flake's `unreal-sandbox` check exercises those with
a local MCP protocol fixture. Actual editor rendering, shader compilation,
C++ compilation, packaging and native toolsets still require an Epic Linux
engine build and must be verified with the commands above.

References: [Linux quickstart](https://dev.epicgames.com/documentation/unreal-engine/linux-development-quickstart-for-unreal-engine),
[native Unreal MCP](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor),
[Epic's MCP setup reference](https://github.com/EpicGames/unreal-engine-skills-for-claude-code-plugin/blob/main/skills/unreal-mcp/references/setup.md).
