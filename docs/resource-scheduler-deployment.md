# Resource scheduler deployment and migration

Every workstation host runs the scheduler daemon
(`services.resourceScheduler.enable`, on by default through `workstation.nix`),
which executes `resource-run` jobs and reports their outcomes to the Orca
sessions that submitted them. Only `home` enables the Slurm queue itself with
`services.resourceScheduler.queue.enable = true` and a 28-CPU admission ceiling.
Without the queue, katana and mac-vm install no Slurm, Munge, mode marker,
completion notifier or legacy GPU adapter, and run every job directly on the
host. Their Claude and Codex configuration omits the queue rules and the
skills that depend on it (`audio-transcribe`, `qwen-prompt`,
`qwen-uncensored-prompt`, `work-queue`), so agents there never learn of it.
On `home`, `resource-control queue-off --confirm` switches the queue off at
runtime; new and waiting jobs then run directly where they were submitted. Applying this configuration activates
Slurm and replaces legacy GPU admission; follow the drained cutover below before
switching. Editing or building the configuration does not activate it.
The exported `nixosModules.resource-scheduler` module is also available to consumers.

Policy 4 adds CPU-only backfill around exclusive GPU work, explicit sandbox
calibration and persistent workload profiles. It also attributes graphics GPU
processes, not only compute contexts. Existing jobs retain their allocations;
this is not live reservation resizing. No switch is performed by editing it.

## Declared deployment

After the validation and drain below, enable the normal host path with:

```nix
services.resourceScheduler = {
  queue.enable = true;
  cpuCapacity = 28;
  policyVersion = "4";
};
```

This installs the backend, starts a single-node Slurm controller and executor,
generates a private host Munge key on first start, exposes the owner-authenticated
Unix socket at `/run/resource-scheduler/control.sock`, and declares
`/etc/resource-scheduler/mode` as `slurm`. The default owner is UID 1000/GID 100;
verify these against `id jesse` before deploying. The node topology is the home
workstation: 16 cores, two threads each and one NVIDIA device at `/dev/nvidia0`.
Other machines must override the Slurm node/GRES definitions and capacity.

The `resource` partition uses `RootOnly=YES`, `AllowGroups=root` and strict partition
limit enforcement to reject direct unprivileged submissions. The root backend
submits trusted bootstrap jobs; clients never receive Munge keys, arbitrary root
Slurm submission capability or the root state directory. The control socket uses
peer credentials. Slurm RPC ports 6817/6818 are filtered to loopback using a narrow
nftables table, including on the home host where the general firewall is disabled.

The daemon needs host PID visibility, Docker inspection and namespace entry. Its
state is root-only and its unit protects kernel tunables, modules, logs and clock.
Do not add `PrivateUsers`, a private `/tmp`, restricted `/proc` or capability limits
without testing the namespace bootstrap. Untrusted environment and commands must
only become effective after privilege drop; review this boundary before rollout.

The home policy is 28 Slurm CPU units, matching the idle sandbox pool's logical CPU count, a 24576 MiB static Slurm RAM ceiling,
4096 MiB additional RAM headroom, 3072 MiB additional VRAM headroom, and a 32768 MiB
cooperative VRAM shard pool. The JSON policy is generated at
`/etc/resource-scheduler/config.json`. The backend samples every two seconds and
requires ten stable seconds before resuming admissions. It retains 500 recent jobs.
CPU requests use Slurm accounting units with SMT/core allocation rounding, not a
promise of 28 physical cores. During a managed game or external GameMode session,
background admission and aggregate CPU quota fall to four units. Existing background
jobs receive proportional cgroup CPU quotas and lower weight; game allocations keep
their own Slurm CPU limits. Quotas/weights restore when gaming ends, including after
daemon recovery. The external root GameMode hook retains its existing sandbox CCD
affinity and also maintains `/run/resource-scheduler-game-active`; sandbox affinity
alone does not constrain Slurm jobs. Dynamic CPU quota changes do not reclaim memory
or change Slurm child cpusets. Review this tentative tuning against measured latency.
GameMode's preferred V-Cache mask remains a best-effort preference inside the Slurm
allocation. The kernel applies only a nonempty intersection with the job's allowed
CPUs; no code widens that allocation. V-Cache placement is not guaranteed. If the
intersection is empty, GameMode 1.8.2 logs `Failed to pin thread` and continues with
the allowed CPUs rather than preventing launch. Inspect
`journalctl --user -u gamemoded.service` for the initial affinity error and inspect
the actual task affinity/cpuset before claiming placement was applied. This behavior
was checked against the pinned GameMode source's `game_mode_apply_core_pinning` and
`apply_affinity_mask` functions; recurring affinity retries may be silent.
Slurm's static RAM ceiling does **not** solve dynamic desktop memory pressure: the
backend must additionally gate admissions against available RAM and unused
reservations without subtracting existing actual use twice. Swap is not capacity.
Shard budgets are cooperative; they do not fence per-process VRAM or GPU compute.
Nix options expose normal/game CPU capacity, static RAM ceiling, RAM/VRAM safety
margins, cooperative GPU pool size and the stability interval. Bump
`services.resourceScheduler.policyVersion` with reviewed tuning changes so telemetry
can distinguish policies; do not automatically replace conservative peaks with averages.

Journald uses persistent storage, capped at 1 GiB and 30 days, leaving 2 GiB free.
Files rotate at most daily. Slurm completion records rotate daily/at 32 MiB with
30 compressed generations. Private Slurm/controller/backend state remains separate
from these logs. Export summaries before journal/history rotation for longer-term
analysis; do not reconstruct reservations from logs. Job labels and IDs are safe
metadata; prompts, environment and raw command arguments are not log payloads.

## Host and sandbox adoption

The backend package is exported by the flake. New sandbox images include the CLI.
After the mode marker is deployed, new sandboxes bind the resolved host configuration
files and socket directory read-only at their canonical paths. Resolving the files
avoids dangling NixOS `/etc/static` symlinks inside containers. A directory bind survives
socket replacement during daemon recovery. A missing socket yields an actionable
failure; it never starts a second queue. Each container receives its exact Docker
name in `AGENT_SANDBOX_INSTANCE`, including unnamed interactive launches.

Claude rules, Codex global context and the sandbox's managed instructions share
`users/jesse/claude/rules/resources.md`. The shared guidance explicitly
keeps legacy GPU rules in force before the cutover.

Use `resource-run --cpu N --ram SIZE [--vram SIZE|--exclusive] --name LABEL -- command`.
The examples, priority, status, revision-guarded cancellation, nesting, foreground
cleanup and missing-service rules live in the canonical agent guidance and backend
[reference](resource-scheduler.md). Nix/container daemons and pre-existing model
servers can execute outside the allocation cgroup; admission alone is not proof of
physical containment. Keep these resources conservatively budgeted for their full
lifetime and validate a dedicated bounded workflow where enforcement is required.
The legacy GPU adapters use one Slurm CPU and 4 GiB RAM and print a migration warning;
these defaults are not safe estimates for every model or game. Review Steam launch
options and project launchers before cutover and replace them with `resource-run`
using explicit measured budgets. Compatibility is a temporary command adapter, not
a promise that formerly unbounded CPU/RAM workloads fit those default limits.

## Validation before activation

Build/evaluate the combined backend, UI and configuration changes before activation:

```sh
nix build .#packages.x86_64-linux.resource-scheduler
nix build .#checks.x86_64-linux.resource-scheduler-config
nix build .#checks.x86_64-linux.resource-scheduler-vm
nix build .#nixosConfigurations.home.config.system.build.toplevel
```

The configuration check evaluates the enabled home host directly,
checks generated policy/service/Slurm/cgroup/GRES files and parses the Slurm config
with the packaged native CLI. It does not start host services or touch GPU leases.
The VM check starts real Slurm and Docker with CPU-only probes and simulated GPU
device declarations. It checks namespace identity, retained Slurm cgroup ownership,
privilege drop, environment/cwd, exact exit status and shared historical job identity.
It can run with TCG when KVM is unavailable and does not use production services.
It also exercises an existing busy background job across external/managed game entry,
daemon restart and exit, observing actual CPU throttling and quota/weight restoration;
checks revision guards and detached descendant termination; and overlaps two native
Slurm shard allocations before admitting a whole-device allocation. GPU capacity,
utilization and device identity in this test are explicit fixtures. This proves the
Slurm/control paths, not physical NVIDIA memory attribution, isolation or throughput.

Before approval to activate, exercise the backend's staging tests against an
isolated CPU-only Slurm instance/VM. Demonstrate host and Docker submissions,
same queue identity, cwd/environment fidelity, correct target namespaces, retained
Slurm cgroup ownership after `nsenter`, privilege drop, denied foreign UID access,
and detached-descendant cleanup. Test daemon recovery, cancellation and stale
revision rejection. No actual GPU inference or competing production resource
ledger is needed. Use fake resources for GPU admission scenarios. Any actual GPU
work must run within an existing production GPU reservation through cleanup.

## Drained cutover

1. Schedule a quiet window and stop new heavy submissions through existing agent
   sessions. Inspect `gpu-status --json` and all existing CPU-slot helpers. Allow
   every resident model/job to finish and unload. Do not delete lockfiles, suspend
   holders, kill another workload or reset the queue to force a drain.
2. Exit old sandbox sessions after their workloads finish. Old processes and store
   wrappers cannot be retroactively upgraded by replacing a Nix profile. Verify
   host agents and launchers will resolve the new compatibility commands as well.
3. Confirm no running or waiting legacy reservation remains. Inspect the old
   directory under `/run/user/1000/gpu-scheduler`, and drain the e-day CPU helpers
   listed below. A GPU utilization snapshot cannot establish this condition.
4. Build the enabled configuration and review the service changes and installed
   instructions. Confirm mode-aware `gpu-run`, `gpu-game` and `gpu-status` delegate
   exclusively to the same resource backend after cutover. Do not retain both
   old admission and new admission against the same physical capacity.
5. With explicit deployment authorization, activate the enabled configuration.
   Confirm `resource-status --json` reports schema version 1, the configured policy
   and real telemetry. Start fresh sandboxes; verify the same job ID is visible on
   host and sandbox. Run a bounded CPU job before GPU work.
6. Complete the external repository helper migration as one rollout. An unresolved
   legacy helper is a rollout blocker, not authorization to run two authorities.

Rollback also requires a drain: hold new admissions, finish/unload managed jobs,
verify cleanup, stop the new authority, then restore the legacy configuration and
fresh clients. Disabling the module while new allocations still run can strand
their supervision. Never erase controller/backend state to make rollback appear
clean. This change does not grant permission to perform either activation.

## External repository helper migration

Inspected the top-level `AGENTS.md`/`CLAUDE.md` files under `/home/jesse/projects`.
The matching CPU-slot policy is in
`/home/jesse/projects/e-day-ports/AGENTS.md`, the “Shared compute and integration
verification” section. Its authoritative helper paths are:

- `/home/jesse/projects/e-day-ports/.tmp/shared-resource-slots/cargo-slot`
- `/home/jesse/projects/e-day-ports/.tmp/shared-resource-slots/run-slot`
- `/home/jesse/projects/e-day-ports/.tmp/shared-resource-slots/pick-slot`

The 2026-11-15 cutover migrated these existing local helpers in place after
confirming their numbered and global locks were drained. Originals are retained
under `.tmp/shared-resource-slots/pre-slurm-2026-11-15/` in that checkout.

`cargo-slot` now submits through `resource-run --project e-day-ports --category
build`. Callers must set `RESOURCE_SLOT_RAM` to their conservative peak; there is
no implicit RAM budget for either mode. `RESOURCE_SLOT_CPU` defaults to three and
sets the matching `CARGO_BUILD_JOBS`; `CARGO_INCREMENTAL=0` remains enforced.
`pick-slot` and `run-slot` delegate to `cargo-slot light`. The global shared/exclusive
lock remains solely for shared verifier scratch protection, inside the resource
allocation; numbered resource-slot admission is removed. Nested reservations and
pre-cutover/missing-service execution fail without a legacy fallback. The main
checkout's compute guidance was updated while preserving unrelated local changes.

For example, declare a suitable measured RAM peak before invoking a helper:

```sh
RESOURCE_SLOT_RAM=8GiB .tmp/shared-resource-slots/cargo-slot light cargo check
```

The example is a declared budget, not evidence that every build fits 8 GiB.
Exclusive verifier batches still use `heavy` and need their own conservative RAM
estimate. Preserve the designated verifier and scratch-isolation requirements.

This inventory covers the named main-checkout helpers and top-level guidance,
not every linked worktree, archived project, binary or private automation. Check
active project launchers and older worktree instructions during future rollouts.

Job introspection adds `resource-job` to the scheduler package. Home Manager enables
`resource-job-notifications.service` for the graphical session only when the
NixOS resource scheduler is enabled. It runs the pinned `resource-notify` and
Orca CLI as the user, separate from the privileged scheduler. After an authorized
switch, check `systemctl --user status resource-job-notifications`; disconnected
Orca delivery remains visible through `resource-job notifications`. Rebuild old
sandboxes to receive the updated clients. Implementation commits do not activate
this service or switch the running system.
