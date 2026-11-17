// A small presentation model; only adapter.mjs understands the backend wire format.
export const MAX_JOBS = 200;
export const MAX_EVENTS = 100;
export const STALE_MS = 15_000;
export const escape = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
export const amount = (value, unit = 'GiB') => Number.isFinite(value) ? `${new Intl.NumberFormat('en', { maximumFractionDigits: 1 }).format(value)}${unit ? ` ${unit}` : ''}` : 'Unknown';
export const duration = (seconds) => !Number.isFinite(seconds) ? 'Unknown' : seconds < 60 ? `${Math.floor(seconds)}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m ${Math.floor(seconds % 60)}s` : `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
export const freshness = (snapshot, now = Date.now()) => {
  if (!snapshot) return 'disconnected';
  const times = [snapshot.at, ...(snapshot.sampledAt ? [snapshot.sampledAt] : [])];
  return times.some((at) => !Number.isFinite(Date.parse(at)) || now - Date.parse(at) > STALE_MS || Date.parse(at) > now + 5000) ? 'stale' : 'live';
};
export function resourceUsage(key, item) {
  const total = key === 'cpu' ? item.hostTotal : item.total;
  const used = key === 'cpu' ? item.hostActual : key === 'gpu' ? item.used
    : Number.isFinite(total) && Number.isFinite(item.available) && item.available <= total ? total - item.available : null;
  let managed = item.actual;
  let external = key === 'ram'
    ? Number.isFinite(used) && Number.isFinite(managed) && managed <= used ? used - managed : null
    : item.external;
  // Independently sampled counters can disagree; do not invent a partition.
  if (!Number.isFinite(used) || (managed ?? 0) + (external ?? 0) > used + 1e-6) {
    managed = null;
    external = null;
  }
  const unattributed = Number.isFinite(used) ? Math.max(0, used - (managed ?? 0) - (external ?? 0)) : null;
  return { total, used, managed, external, unattributed };
}
export function filterJobs(jobs, filters) {
  const search = (filters.search ?? '').trim().toLowerCase();
  return jobs.filter((j) => (!search || [j.label, j.id, j.owner.agent, j.owner.worktree, j.owner.project, j.owner.repo, j.owner.worktreeName, j.owner.parentWorktreeName, j.model?.name].join(' ').toLowerCase().includes(search))
    && (!filters.state || j.state === filters.state)
    && (!filters.project || j.owner.project === filters.project)
    && (!filters.worktree || j.owner.worktree === filters.worktree)
    && (!filters.agent || j.owner.agent === filters.agent)
    && (!filters.host || j.owner.host === filters.host)
    && (!filters.resource || (filters.resource === 'gpu' ? j.request.vram > 0 || j.exclusive : j.request[filters.resource] > 0)));
}
export function orderJobs(jobs) {
  return [...jobs].sort((a, b) => Number(a.state === 'waiting') - Number(b.state === 'waiting')
    || (a.state === 'waiting' ? (a.queuePosition ?? 0) - (b.queuePosition ?? 0) : 0)
    || (Date.parse(a.submittedAt) || 0) - (Date.parse(b.submittedAt) || 0) || a.id.localeCompare(b.id));
}
export function eligibleActions(snapshot, job, now = Date.now()) {
  if (freshness(snapshot, now) !== 'live') return [];
  return (job?.actions ?? snapshot.actions ?? []).filter((action) => ['cancel', 'terminate', 'force-run', 'run-next', 'run-host', 'run-sandbox', 'priority', 'unload', 'pause', 'resume', 'queue-on', 'queue-off', 'game'].includes(action));
}
export function journalQuery(id) {
  // Quote the field value for a shell; never insert command labels or raw arguments.
  return `journalctl SYSLOG_IDENTIFIER=resource-scheduler RESOURCE_JOB_ID='${String(id).replace(/'/g, "'\\''")}' -o json-pretty`;
}
export function diagnostic(snapshot, job) {
  // Explicit allowlist: no raw command, environment, prompts or arbitrary metadata.
  const safeJob = (j) => ({ id: j.id, label: j.label, state: j.state, execution: j.execution, explore: j.explore, largeGpuLane: j.largeGpuLane, memoryPolicy: j.memoryPolicy, ramAdmission: j.ramAdmission, profileAutomatic: j.profileAutomatic, profile: j.profile, failure: j.failure, hostPhase: j.hostPhase, queuePosition: j.queuePosition, owner: j.owner, request: j.request, effectiveBudget: j.effectiveBudget, model: j.model, vramEstimate: j.vramEstimate, measured: j.measured, wait: j.wait, submittedAt: j.submittedAt, startedAt: j.startedAt, finishedAt: j.finishedAt, exit: j.exit, allocation: j.allocation, unit: j.unit, cleanup: j.cleanup, admission: j.admission, events: j.events?.slice(-MAX_EVENTS) });
  return { schemaVersion: 1, exportedAt: new Date().toISOString(), at: snapshot.at, policy: snapshot.policy, host: snapshot.host, mode: snapshot.mode, capacity: snapshot.capacity, swap: snapshot.swap, limitations: snapshot.limitations, jobs: (job ? [job] : snapshot.jobs).slice(0, MAX_JOBS).map(safeJob) };
}

export const resolveWorkspace = (workspaces, identity) => workspaces.find((workspace) => workspace.id === identity || workspace.path === identity || identity.endsWith(`::${workspace.path}`));
export function historyMetrics(jobs) {
  const terminal = jobs.filter((job) => ['completed', 'failed', 'cancelled'].includes(job.state));
  const reserved = terminal.filter((job) => !['host', 'sandbox'].includes(job.execution) && !job.explore);
  const delays = reserved.filter((job) => job.startedAt && job.submittedAt).map((job) => Math.max(0, (Date.parse(job.startedAt) - Date.parse(job.submittedAt)) / 1000));
  const ram = reserved.filter((job) => job.request.ram > 0 && Number.isFinite(job.measured.ram)).map((job) => job.measured.ram / job.request.ram * 100);
  const vram = reserved.filter((job) => job.request.vram > 0 && Number.isFinite(job.measured.vram)).map((job) => job.measured.vram / job.request.vram * 100);
  const mean = (values) => values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
  return { count: terminal.length, queueSamples: delays.length, queueMean: mean(delays), ramSamples: ram.length, ramRatio: mean(ram), vramSamples: vram.length, vramRatio: mean(vram) };
}

export const worktreeLabel = (owner) => owner.worktreeName || owner.worktree.split('/').filter(Boolean).pop() || 'Unknown worktree';
export const ownerLabel = (owner) => [owner.repo || owner.project, [owner.parentWorktreeName, worktreeLabel(owner)].filter(Boolean).join(' → ')].filter(Boolean).join(' · ');
