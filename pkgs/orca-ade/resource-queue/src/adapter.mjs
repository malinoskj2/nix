import { MAX_JOBS, MAX_EVENTS } from './model.mjs';
const gib = (mib) => typeof mib === 'number' && Number.isFinite(mib) && mib >= 0 ? mib / 1024 : null;
const metric = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;
const text = (value, fallback = '') => typeof value === 'string' ? value.slice(0, 2048) : fallback;
const date = (value) => typeof value === 'number' && Number.isFinite(value) && Math.abs(value) <= 8640000000000 ? new Date(value * 1000).toISOString() : null;
const states = new Set(['queued', 'pending', 'running', 'completed', 'failed', 'cancelled', 'unknown']);
const modes = new Set(['normal', 'manual_hold', 'pressure_hold', 'game_pending', 'game_running', 'exclusive_pending', 'exclusive_running']);
const modelStates = new Set(['loading', 'ready', 'busy', 'idle', 'unloaded']);
function reportedModel(raw) {
  if (!raw || !modelStates.has(raw.state) || raw.attribution_confidence !== 'owner-reported') return null;
  return { name: text(raw.label, 'Unnamed model'), state: raw.state, provenance: 'owner-reported',
    loadStartedAt: date(raw.load_started_at), loadedAt: date(raw.loaded_at), loadSeconds: metric(raw.load_seconds), unloadedAt: date(raw.unloaded_at) };
}
export function adaptStatus(raw) {
  if (!raw || raw.schema_version !== 1) throw new Error(`Unsupported resource-status schema: ${raw?.schema_version ?? 'missing'}`);
  if (raw.connected !== true) throw new Error('Scheduler reports disconnected');
  if ((!Number.isSafeInteger(raw.revision) || raw.revision < 0) || !date(raw.generated_at) || !Array.isArray(raw.jobs) || !Array.isArray(raw.history) || !modes.has(raw.mode)) throw new Error('Malformed resource-status v1 response');
  const caps = raw.capabilities ?? {};
  const actions = Object.keys(caps).filter((key) => caps[key] === true).map((key) => ({ force_run: 'force-run', run_next: 'run-next', run_host: 'run-host', run_sandbox: 'run-sandbox' })[key] || key);
  const toJob = (job) => {
    if (!job || !/^[a-f0-9]{32}$/.test(job.id) || (!Number.isSafeInteger(job.revision) || job.revision < 0) || !states.has(job.state)) throw new Error('Malformed job identity, revision or lifecycle state');
    const state = job.state === 'queued' || job.state === 'pending' ? 'waiting' : job.state;
    const lifecycle = Array.isArray(job.events) ? job.events.slice(-MAX_EVENTS).map((event) => ({
      at: date(event.timestamp), label: text(event.event, 'Unknown event').replaceAll('_', ' ') + (typeof event.event === 'string' && event.event.startsWith('model_') && event.model?.attribution_confidence === 'owner-reported' ? ' · owner-reported' : ''),
      message: [text(event.reason), text(event.action), event.exit_code == null ? '' : `Exit ${text(String(event.exit_code))}`, text(event.cleanup)].filter(Boolean).join(' · '),
      snapshot: event.snapshot ? { availableRam: gib(event.snapshot.ram?.available_mib), freeVram: gib(event.snapshot.gpu?.free_mib), ramHeadroom: gib(event.snapshot.ram?.headroom_mib), vramHeadroom: gib(event.snapshot.gpu?.headroom_mib), ramReserved: gib(event.snapshot.ram?.reserved_mib), vramReserved: gib(event.snapshot.gpu?.reserved_mib) } : null
    })).filter((event) => event.at) : [];
    const owner = { repo: text(job.repo), worktreeName: text(job.worktree_name), parentWorktreeName: text(job.parent_worktree_name), agent: text(job.agent, 'Unknown agent'), worktree: text(job.worktree, 'Unknown worktree'), project: text(job.project, 'Unknown project'), host: text(job.origin, 'Host'), uid: Number.isSafeInteger(job.owner_uid) && job.owner_uid >= 0 ? job.owner_uid : null };
    return {
      id: job.id, revision: job.revision, label: text(job.label, 'Untitled workload'), state, backendState: job.state, category: text(job.category, 'other'), priority: text(job.priority, 'background'), owner,
      request: { cpu: metric(job.requested?.cpu), ram: gib(job.requested?.ram_mib), vram: gib(job.requested?.vram_mib) },
      effectiveBudget: { cpu: metric(job.allocation?.cpu), ram: gib(job.allocation?.ram_mib), vram: gib(job.allocation?.vram_mib) },
      vramEstimate: text(job.vram_estimate, job.vram_auto ? 'all-available' : 'declared-peak'),
      measured: { cpu: metric(job.observed?.cpu_percent), ram: gib(job.observed?.ram_peak_mib), vram: gib(job.observed?.vram_peak_mib), confidence: text(job.observed?.attribution_confidence, 'Unavailable') },
      queuePosition: Number.isSafeInteger(job.queue_position) && job.queue_position > 0 ? job.queue_position : null,
      execution: ['host', 'sandbox', 'large'].includes(job.execution) ? job.execution : 'slurm', hostPhase: text(job.host_phase),
      largeGpuLane: job.execution === 'large' || job.large_gpu_lane === true,
      profileAutomatic: job.profile_automatic === true,
      memoryPolicy: text(job.memory_policy),
      ramAdmission: job.ram_admission ? { growth: gib(job.ram_admission.growth_mib), basis: text(job.ram_admission.basis), runs: metric(job.ram_admission.learned_runs) } : null,
      explore: job.explore === true, profile: job.profile && ['project', 'name', 'variant'].every((key) => typeof job.profile[key] === 'string') ? { project: text(job.profile.project), name: text(job.profile.name), variant: text(job.profile.variant) } : null, failure: text(job.failure),
      runNextRequested: date(job.run_next_requested_at),
      exclusive: job.mode === 'exclusive', wait: text(job.wait_reason, state === 'waiting' ? 'Waiting for scheduler admission; detailed reason unavailable.' : ''),
      submittedAt: date(job.created_at), startedAt: date(job.started_at), finishedAt: date(job.ended_at), allocation: job.slurm_job_id == null ? null : String(job.slurm_job_id),
      unit: text(job.systemd_unit) || null, cleanup: text(job.cleanup) || null, exit: job.exit_code == null ? null : String(job.exit_code), model: reportedModel(job.model),
      events: lifecycle.length ? lifecycle : [{ at: date(job.created_at), label: 'Submitted' }, { at: date(job.started_at), label: 'Started' }, { at: date(job.ended_at), label: `Finished · ${state}` }].filter((e) => e.at).slice(-MAX_EVENTS),
      logs: lifecycle.map((event) => ({ at: event.at, event: event.label, message: event.message })),
      admission: [...lifecycle].reverse().find((event) => event.snapshot)?.snapshot ?? null,
      actions: ['host', 'sandbox', 'large'].includes(job.execution) ? actions.filter((a) => job.state !== 'completed' && job.state !== 'failed' && job.state !== 'cancelled' && (a === 'terminate' || (a === 'cancel' && job.host_phase === 'cancelling-slurm'))) : state === 'waiting' ? actions.filter((a) => a === 'cancel' || (job.state === 'queued' && !job.released && job.cleanup !== 'cancellation-requested' && ['force-run', 'run-next', 'run-host', 'run-sandbox'].includes(a) && (a !== 'run-sandbox' || /^agent-sandbox-[A-Za-z0-9_.-]{1,128}$/.test(job.origin)))) : state === 'running' ? actions.filter((a) => a === 'terminate') : []
    };
  };
  const telemetry = raw.telemetry ?? {};
  const cpu = telemetry.cpu ?? {}, ram = telemetry.ram ?? {}, gpu = telemetry.gpu ?? {};
  return {
    notifications: (Array.isArray(raw.notifications) ? raw.notifications : []).filter((n) => /^[a-f0-9]{32}$/.test(n.id) && ['pending', 'sending', 'unavailable'].includes(n.notification?.state) && (n.ready || n.notification.state !== 'pending')).slice(0, 100).map((n) => ({ id: n.id, label: text(n.label, 'Job'), state: text(n.state), delivery: n.notification.state, detail: text(n.notification.detail), exit: n.exit_code, failure: text(n.failure) })),
    notificationCount: Number.isSafeInteger(raw.notification_count) ? raw.notification_count : 0,
    schemaVersion: 1, revision: raw.revision, at: date(raw.generated_at), sampledAt: date(telemetry.sampled_at), policy: String(raw.policy_version ?? 'Unknown'), host: text(raw.host, 'Shared host'),
    mode: raw.mode, actions: actions.filter((a) => a === 'pause' || a === 'resume'),
    capacity: {
      cpu: { total: metric(cpu.capacity), reserved: metric(cpu.reserved), actual: metric(cpu.actual), hostActual: metric(cpu.host_actual), hostTotal: metric(cpu.logical_cpus), external: metric(cpu.external), attribution: text(cpu.attribution_confidence, 'Unavailable'), headroom: null, effectiveBackground: metric(cpu.effective_background_capacity), gameActive: cpu.game_active === true, gameProtectionErrors: Array.isArray(cpu.game_protection_errors) ? cpu.game_protection_errors.filter((error) => typeof error === 'string').map((error) => error.slice(0, 1024)).slice(0, 20) : [] },
      ram: { hostGrowth: gib(ram.growth_buffer_mib), policy: text(ram.admission_policy), growth: gib(ram.growth_allowance_mib), slurmCapacity: gib(ram.slurm_capacity_mib), total: gib(ram.total_mib), reserved: gib(ram.reserved_mib), actual: gib(ram.managed_actual_mib), available: gib(ram.available_mib), swapUsed: gib(ram.swap_used_mib), external: null, headroom: gib(ram.headroom_mib) },
      gpu: { total: gib(gpu.total_mib), reserved: gib(gpu.reserved_mib), actual: gib(gpu.managed_actual_mib), used: gib(gpu.used_mib), available: gib(gpu.free_mib), external: gib(gpu.external_mib), attribution: text(gpu.attribution_confidence, 'Unavailable'), headroom: gib(gpu.headroom_mib), utilization: metric(gpu.utilization_percent) }
    },
    swap: { pagesIn: metric(telemetry.swap?.pages_in), pagesOut: metric(telemetry.swap?.pages_out) },
    jobs: [...raw.jobs, ...raw.history].slice(0, MAX_JOBS).map(toJob), pressure: telemetry.pressure ?? {},
    limitations: [...(raw.errors ?? []), ...(telemetry.errors ?? []), ...(Array.isArray(cpu.game_protection_errors) ? cpu.game_protection_errors : []), ...(raw.truncated?.events === true ? ['Backend omitted public lifecycle events to keep status within its transport bound; inspect the journal for full records.'] : []), ...(Number.isSafeInteger(raw.truncated?.history) && raw.truncated.history > 0 ? [`Backend omitted ${raw.truncated.history} historical jobs to keep status bounded.`] : []), ...(raw.jobs.length + raw.history.length > MAX_JOBS ? [`Panel display capped at ${MAX_JOBS} jobs; the host retains additional records.`] : [])].filter((s) => typeof s === 'string').slice(0, 20).map((s) => s.slice(0, 1024)),
    unsupported: ['Priority changes', 'Managed model unloading', 'Game requests', 'Model residency telemetry', 'Historical policy recommendations'].filter((_, i) => i === 0 ? !caps.priority : i === 1 ? !caps.unload : i === 3 ? caps.model_reports !== true && ![...raw.jobs, ...raw.history].some((job) => reportedModel(job.model)) : true)
  };
}
