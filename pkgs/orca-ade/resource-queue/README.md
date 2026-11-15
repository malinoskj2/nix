# Resource Queue for Orca

The Nix-built Orca ships `jesse.resource-queue`, a dedicated gauge tab in the
right activity bar, alongside Usage Insights. The panel reads the host's Slurm
resource scheduler through the canonical clients. It never submits jobs or keeps
an independent reservation ledger.

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
on Orca >=1.4.248 (the repository pins 1.4.258). The HTML panel uses Orca theme
variables and the frame request bridge, as the bundled Usage Insights integration
does. Worktree IDs, legacy `repo::path` IDs and paths resolve to open workspaces;
removed worktrees retain their historical identity. This Orca API has no action to
focus a specific historical agent session, so the inspector displays its stable
agent/session identifier and links the containing worktree when it is resolvable.

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

Supported initial controls:

- `resource-control cancel ID --revision N --confirm`
- `resource-control terminate ID --revision N --confirm`
- `resource-control pause --confirm` and `resume --confirm`

The inspector includes bounded searchable structured lifecycle events, follow/pause,
known admission snapshots, requested versus measured peaks, exit/cleanup, safe JSON
exports and a copyable `journalctl RESOURCE_JOB_ID='…' -o json-pretty` query. Logs
come from allowlisted fields in status, never arbitrary journald messages.

## Scope and honest limitations

The initial backend does not support priority changes, managed model unload, model
residency/active-request telemetry or game requests from this panel. These are named
in the UI. Game/exclusive/pressure/manual modes and their real wait reasons are
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
