# Resource Queue for Orca

The Nix-built Orca ships `jesse.resource-queue`, a dedicated gauge tab in the
right activity bar, alongside Usage Insights. The panel reads the host's Slurm
resource scheduler through the canonical clients. It never creates an independent reservation ledger. Explicit run controls act on
existing waiting jobs through the backend.

## Installation and authority

`pkgs/orca-ade/package.nix` copies this directory into the bundled plugin launch
index and hashes the final content. It removes `tests/` before hashing and packaging.
Set `resourceSchedulerPackage = pkgs.resource-scheduler` on the Orca override to
embed absolute store paths for `resource-status` and `resource-control`; this avoids
GUI-process PATH differences. The default `null` leaves development clients on PATH
and reports a missing client explicitly.

This is a trusted Node worker running as the Orca user. Approval grants host process
execution plus `workspace:read` and `workspace:write`, used only to resolve identities
and open the owning worktree. Standard Orca consent applies unless Nix explicitly
lists `jesse.resource-queue` in `approvedPlugins`. User disablement still wins.
There are no new private UI APIs, launch hooks, cloud calls or network requests.

The worker uses supported `panels.handle`, `workspace.list` and `workspace.open` APIs
on Orca >=1.4.248 (the repository pins 1.4.261). The HTML panel uses Orca theme
variables and the frame request bridge, as the bundled Usage Insights integration
does. Worktree IDs, legacy `repo::path` IDs and paths resolve to open workspaces;
removed worktrees retain their historical identity. This Orca API has no action to
focus a specific historical agent session, so the inspector displays its stable
agent/session identifier and links the containing worktree when it is resolvable.

## Panel layout

Queue, Resources, History and Controls tabs separate active work, capacity readings,
completed jobs and scheduler admission controls. Controls contains the queue on/off
switch, the sharing status and pause/resume action; cancel/terminate remain in the
job inspector. While the queue is off, the header reads "All work on host · Queue
off", the Queue tab says so, and jobs show a "direct, no queue" execution badge.
On a host without the Slurm queue, the switch and pause are hidden and every job
appears this way. Tabs support
arrow keys, Home and End, and survive status refreshes.
Job inspection opens on selection. Routine disclaimers, the host pressure expander
and diagnostics export controls are omitted. Connection errors and actual backend
telemetry failures remain visible.

The resource cards show whole-host CPU, host RAM and device VRAM usage. A shared
legend identifies queue usage (green), other/system usage (amber) and unattributed
usage (striped). Reservations remain separate facts, never stacked onto usage.
RAM in use is total minus Linux MemAvailable, excluding reclaimable memory; its
other/system amount is the remainder after measured queue usage. Incomplete or
inconsistent attribution stays unknown. CPU uses the backend's `logical_cpus`,
not the smaller Slurm admission capacity; older backends show unknown host capacity.
Memory trends remain explicitly labeled queue reservations and queue measurements.

Waiting rows offer **Run via Slurm**, **Run in sandbox**, **Run on host**, and **Run next**, each with
named confirmation and revision checking. Run via Slurm bypasses admission policy
but preserves Slurm allocation limits. Run in sandbox is available only for
sandbox-origin jobs: it confirms Slurm cancellation and runs in the original
sandbox without a Slurm reservation. Sandbox validation failure stops execution;
there is no host fallback. Run on host confirms cancellation of the
held Slurm job before starting an unmanaged host process, outside the sandbox;
its badge and inspector explicitly say that requested budgets are not enforced.
All run paths retain output and termination through the original job identity.
Pending Slurm allocations cannot be launched again. Reordering follows backend
`queue_position`; unsupported controls remain hidden on older backends.

Exploratory jobs carry a visible trial badge and an inspector explanation of
the bounded CPU/RAM allocation, cooperative GPU trial budget and 30-minute limit.
Workload profile identifiers and classified failure outcomes are shown when
available. Suggestions are retrieved using `resource-profile`; the panel does
not silently resize allocations. Exploratory results are excluded from reservation
accuracy metrics. Older backends remain supported without these optional fields.

## Wire contract and controls

`src/adapter.mjs` is the only backend-format boundary. It accepts exactly
`resource-status --json` schema_version 1, validates IDs/revisions/lifecycle,
converts MiB to GiB, bounds the displayed jobs to 200 and lifecycle events to 100,
and preserves null measurements. The backend currently retains at most 64 events
per job. Other schema versions and errors are visible, never empty-queue success.
The backend is the authority for wait reasons, allocations and resource budgets.

The panel polls while visible every two seconds, with bounded exponential reconnect
backoff up to 30 seconds. This backend has no event stream; the adapter can adopt
one without changing the presentation model. Concurrent reads in a worker coalesce;
requests have an eight-second process deadline and a 1 MiB output limit. The panel
keeps at most 60 observations, marking telemetry gaps. Both status generation time
and telemetry sample time expire after 15 seconds. Failed reads retain the last
snapshot with a stale warning and remove controls. New jobs are never inferred
from charts or journal history.

Controls are shown only when the backend advertises them. Every disruptive action
requires a named confirmation; the worker re-reads status and checks immutable UUID,
job revision, lifecycle and freshness before executing an argument array without a
shell. The host backend independently authorizes the UID and checks revisions.
A zero exit from the control client confirms acceptance, and the following status
query determines the displayed outcome. An accepted termination is never presented
as proof of descendant cleanup. No command output, environment or prompt is read.

Supported controls (shown only when advertised by the backend):

- `resource-control cancel ID --revision N --confirm`
- `resource-control terminate ID --revision N --confirm`
- `resource-control pause --confirm` and `resume --confirm`
- `resource-control queue-off --confirm` and `queue-on --confirm`
- `resource-control run-next ID --revision N --confirm`
- `resource-control force-run ID --revision N --confirm`
- `resource-control run-host ID --revision N --confirm`
- `resource-control run-sandbox ID --revision N --confirm`

The inspector includes bounded searchable structured lifecycle events, follow/pause,
known admission snapshots, requested versus measured peaks, exit/cleanup and a copyable `journalctl SYSLOG_IDENTIFIER=resource-scheduler RESOURCE_JOB_ID='…' -o json-pretty` query. Logs
come from allowlisted fields in status, never arbitrary journald messages.

## Scope and honest limitations

The initial backend does not support priority changes, managed model unload, verified model
residency/active-request telemetry or game requests from this panel. Unsupported controls are omitted. Game/exclusive/pressure/manual modes and their real wait reasons are
visible; games can be submitted through the canonical CLI by an authorized owner.
The current machine has one GPU and the v1 schema describes one device. No idle model
is inferred from device utilization. Managed/external attribution remains unknown
when the backend cannot provide it; observed usage is never added to reservations.

History and resource trends describe only retained outcomes and observations from
the open panel. They are not a long-term metrics store. The history summary excludes
unknown samples and labels sample counts; it does not recommend lowering budgets.
Model load overhead, overlap throughput, policy comparisons and long-term starvation
reports need backend metrics that are not available in v1. No completion predictions
are manufactured. Unknown Slurm job state appears under **Needs attention**, never
under completed history.

## Verification

Run small dependency-free tests:

```sh
node --test pkgs/orca-ade/resource-queue/tests/*.test.mjs
orca plugin validate pkgs/orca-ade/resource-queue --json
orca plugin inspect pkgs/orca-ade/resource-queue --json
orca plugin test pkgs/orca-ade/resource-queue --json
orca plugin check pkgs/orca-ade/resource-queue --json
```

`plugin check` validates HTML panels but does not render them (`panels: []`); browser
checks provide the HTML evidence. Tests cover stale/schema failures, exact wait
reasons, unknown telemetry, injection escaping, revision/lifecycle guards, process
errors, safe bounded exports/events, history statistics and real Orca identity API
shapes. The Nix package runs these Node tests before bundling.

For deterministic browser evidence, serve this directory on an unused reserved
sandbox preview port, binding 0.0.0.0, and use its `AGENT_PREVIEW_URL_<port>` URL:

- `tests/preview.html?scenario=overlap&inspect` (dark wide)
- `tests/responsive.html` (390 px light panel)
- scenarios: empty, ram, vram, exclusive, game, resident, partial, hold, stale,
  disconnected and error
- `tests/browser-harness.html`, then evaluate
  `import('./browser-check.mjs').then(module => module.check())` through Orca's
  browser CLI. This explicitly labeled test bridge exercises the production panel's
  inspection, confirmation, cancellation, search/focus, disconnect/reconnect and
  admission pause flow without executing any host control commands.

All fixture pages/bridges live under `tests/` and are excluded from the production
plugin; the production entry does not read fixture query parameters. Browser
screenshots belong in the worktree-root `.tmp/` and review batches use media-gallery.
A normal `nix build .#packages.x86_64-linux.orca-ade --no-link` validates the full
reproducible application build without activating it or restarting Orca.

## Exclusive budgets and gaming protection contract

An all-available exclusive GPU job exposes `requested.vram_mib = null` and
`vram_estimate = "all-available"`. The peak estimate stays **Unknown**. The separate
`allocation.vram_mib` is null before admission and becomes the frozen effective
admission budget when released. Rows and the inspector distinguish that allocation
from requested peaks and measured use.
Unknown requested peaks are excluded from peak/request accuracy statistics. The
GPU reservation total comes directly from `telemetry.gpu.reserved_mib`, including
exclusive allocations, and is never reconstructed from unknown request fields.

CPU `capacity` is the configured Slurm capacity and `reserved` includes all active
job allocations, including game jobs. `effective_background_capacity` is a separate
background admission/protection limit. The CPU card shows whole-host usage over the host logical CPU count. Queue
reservations, configured Slurm capacity and the reduced background limit remain
separate facts, including in the compact view. `game_active` can reflect external game discovery even when
queue mode is normal. Protection errors are visible as degraded protection and
partial telemetry notices; no successful throttling is inferred from game mode.

The latest backend public status retains up to eight lifecycle events per job,
omits their admission snapshots, and may omit events or old history to stay below
900000 serialized bytes. The UI surfaces `truncated.events` and `truncated.history`.
The native journal contains the deeper records; the copied query matches its real
`SYSLOG_IDENTIFIER` and `RESOURCE_JOB_ID` fields. If native journald delivery is
unavailable, the backend's service stdout fallback contains the JSON event inside
`MESSAGE` and cannot be selected by `RESOURCE_JOB_ID`; inspect
`journalctl -u resource-scheduler.service -o cat` in that degraded environment.

`tests/backend-status-v1.json` is captured from the actual backend serializer,
submission and tick code with injected Slurm and deterministic host telemetry.
It is not evidence of a live host deployment. Its provenance includes the source
SHA-256. Regenerate it without starting a service or writing to the journal:

```sh
python3 pkgs/orca-ade/resource-queue/tests/capture-backend-status.py \
  /path/to/pkgs/resource-scheduler/resource_scheduler.py \
  pkgs/orca-ade/resource-queue/tests/backend-status-v1.json
```

The capture also records a real native journal datagram through an intercepted
socket, allowing contract tests to verify the copied selector against the backend's
actual structured field names. No credentials, environment, command arguments or
real host paths are present in the captured public fixture.

## Sampled telemetry and owner-reported models

Managed CPU actual, whole-host actual and external CPU are shown as **CPU equiv.**:
logical CPU-seconds per second, where 1 means one fully busy logical CPU. These
readings are separate from configured/reserved Slurm CPU counts and do not measure
physical-core performance. Per-job CPU percent retains its own unit (100% = one
CPU). Host CPU requires two `/proc/stat` samples; cgroup CPU requires two valid
job counter samples. Missing samples/attribution remain Unknown, and the frontend
never derives an external value from incomplete measurements. Attribution is shown.

GPU external use comes directly from `external_mib` and is converted to GiB;
managed compute memory, device-wide used memory, reservations and GPU compute
percent remain separate. Swap used is GiB; `telemetry.swap.pages_in/pages_out`
are cumulative pages since boot, never rates or extra admission capacity.

`capabilities.model_reports=true` advertises owner reporting even with no reports.
A validated `job.model` has a model label, loading/ready/busy/idle/unloaded state,
load-start/ready/unloaded timestamps, load seconds and the explicit provenance
`owner-reported`. Rows, search, inspector and allowlisted exports retain that
provenance. Busy/idle/residency are not observed or verified by this report. A
reported unload does not verify memory release or end the reservation, and no
unload control is offered. Missing/invalid provenance is displayed as no validated
report; the presence of a nullable model field alone does not establish support.
