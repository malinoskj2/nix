# GPU reservations

`gpu-run` coordinates the home desktop's GPU 0 across the host and all agent
sandboxes. It allows concurrent workloads with declared peak VRAM budgets,
and exclusive workloads for video generation and demanding games. It is
cooperative admission control: programs that bypass the launcher can still use
the GPU, and a reservation does not impose a driver memory limit.

```sh
gpu-run --vram 4GiB --name "small model" -- python small-model.py
gpu-run --exclusive --name "video generation" -- python generate-video.py
gpu-game --name "game" -- game-command
gpu-status
gpu-status --json
```

Use a conservative peak estimate, including weights, inference/KV caches,
activations, temporary allocations and a safety margin for the chosen context,
batch size or resolution. The scheduler does not estimate these for you. Known
peaks can use shared reservations even for larger models; unknown workloads and
video generation should use `--exclusive`. An oversized
shared request fails rather than waiting forever. `--timeout 60` limits time in
the queue; otherwise a request waits until admitted or interrupted. Commands
inside an existing reservation run directly; nested reservations are rejected.

For a demanding Steam game, set its Properties → General → Launch Options to:

```text
gpu-game --name "Gears E-Day" -- %command%
```

The launcher is installed in Steam's environment. Put it before any existing
launch wrapper so admission happens before Proton or the game allocates VRAM.
Games without this launch option do not reserve a slot. GameMode remains
responsible for CPU policy; its hooks cannot gate GPU allocations before launch.

## Queue and memory policy

- Running work finishes normally. A game request goes ahead of waiting model
  work, and blocks new model admissions until its turn is over. Games are FIFO
  among themselves; ordinary requests are FIFO. An exclusive request at the head
  blocks later shared requests, so a stream of small jobs cannot starve it.
- Shared admission counts each active job at the greater of its declared peak
  budget and attributed GPU usage. Unused budget remains reserved for inference,
  even while the model is idle or has not loaded yet. Memory outside active
  leases is counted separately, with a minimum 4096 MiB desktop allowance.
  For example, on a 32 GiB GPU, a model using 20 GiB with a 24 GiB peak budget
  can share with a 2 GiB job: 24 + 2 + 4 = 30 GiB. Loading more weights or
  inference buffers does not consume another reservation for the same job.
- A socket-activated host user service queries NVIDIA compute-process memory and
  reads each same-user process's `GPU_LEASE_ID` from host `/proc`. Workers from
  all sandbox PID namespaces can therefore be attributed without exposing host
  `/proc` inside containers. Only memory tagged with a currently running lease
  gets credit. Unknown processes, retired leases, missing metrics and unreadable
  process environments remain outside the leases. The socket accepts no commands
  or client-supplied paths and is accessible only to the user.
- If the host attribution service is unavailable or its response is invalid,
  admission falls back to adding all active peak budgets to measured GPU usage
  (or desktop headroom, whichever is larger). This deliberately double-counts
  loaded models until attribution is restored. If aggregate telemetry also
  fails, admission waits. Existing older clients keep their conservative policy.
- 4096 MiB is reserved for desktop use. Exclusive admission requires no active
  leases and measured usage at or below that allowance. The desktop, browser,
  OBS and display servers continue to run; exclusive means exclusive among
  participating workloads. It does not guarantee the entire physical VRAM.
- NVIDIA telemetry is checked under the admission lock before each grant.
  `gpu-status` reports memory, attributed allocations, running reservations,
  waiting jobs and the reason each job is blocked. Telemetry is a snapshot,
  not hardware isolation: jobs must honor their peak budgets.

Keep the command running until GPU cleanup is complete. Persistent model servers
must run inside their reservation for their whole resident lifetime. For a
per-request integration, unload the model before allowing the reserved command
to exit. Suspending a process does not free VRAM. No model servers are declared in
this repository, so unloading is currently the workload's responsibility rather
than a runtime-specific adapter.

## Shared leases and lifecycle

The host and sandboxes bind the same `/run/user/<uid>/gpu-scheduler` directory.
A short `flock` on `admission.lock` serializes updates. Each queued or running
request holds a separate locked JSON record. The launcher supervises its command
and adopts detached descendants, keeping the reservation until all of them exit.
The lease descriptor is also inherited by the command. Ordinary interrupts are
forwarded to the command's process group; its exit status is preserved.

After a process exits or is killed, records with no surviving lock holders are
reaped by the next scheduler command. No daemon restart can forget active leases.
Never remove the directory, admission lock, or lease files while workloads are
running: replacing an inode splits the coordination domain. This is a local
filesystem protocol for one user and one GPU, not a distributed lock service.
Programs must not escape supervision into unrelated existing services. A force
kill of a supervisor whose workers close inherited descriptors can lose the
reservation; measured memory remains a secondary check, not hardware isolation.

The sandbox launcher creates and binds the host directory into new containers.
A sandbox missing that mount fails closed rather than creating a private queue.
`GPU_SCHEDULER_DIR` exists for isolated tests; all production workloads use the
default shared directory.

## Agent configuration and rollout

Claude's global GPU rule and Codex's global `AGENTS.md` include the same policy:
reserve before GPU work, estimate peak VRAM, use exclusive mode when uncertain,
wait rather than bypass, and unload before releasing. The sandbox's system
Claude instructions include it too. Muse's default foreign personal-context
import reads Codex's global rules; if that import is disabled, import the GPU
rule into Muse's personal rules before using it for GPU work.

Build and apply the `home` configuration through the normal NixOS workflow, then
restart sandboxes to pick up the package and shared mount, restart agent sessions
to load the instructions, and set launch options on demanding Steam games.
Building alone does not activate these changes.
The `gpu-scheduler-telemetry.socket` user unit must be active for attribution;
an updated host and newly started sandboxes use it through the shared scheduler
directory. `systemctl --user status gpu-scheduler-telemetry.socket` checks it.

## Verification

```sh
python3 -m unittest discover -s pkgs/gpu-scheduler -v
nix build .#gpu-scheduler .#checks.x86_64-linux.gpu-scheduler
nix build .#nixosConfigurations.home.config.system.build.toplevel
```

Tests use a fake NVIDIA memory probe and real processes and file locks. They
cover concurrent grants, exclusive barriers, game priority, cancellation,
telemetry failure, descendant lifetime and command exit status without loading
models or allocating GPU memory.
