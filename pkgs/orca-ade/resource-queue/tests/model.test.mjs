import { test } from 'node:test';
import assert from 'node:assert/strict';
import { adaptStatus } from '../src/adapter.mjs';
import { freshness, eligibleActions, diagnostic, filterJobs, journalQuery } from '../src/model.mjs';
import { render } from '../panel/view.mjs';
import { fixture, fixtureTime, jobId } from './fixtures.mjs';
const snapshot = (name) => adaptStatus(fixture(name));
const state = (data, extra = {}) => ({ snapshot: data, filters: {}, samples: [], identities: [], logs: [], ...extra });
test('versioned adapter rejects unsupported, disconnected and malformed state', () => {
  assert.throws(() => adaptStatus({ schema_version: 2 }), /Unsupported/);
  assert.throws(() => adaptStatus({ ...fixture(), connected: false }), /disconnected/);
  const malformed = fixture(); malformed.jobs[0].id = 'reused-unsafe-id';
  assert.throws(() => adaptStatus(malformed), /identity/);
});
test('unknown readings remain unknown; capacity is not double counted', () => {
  const data = snapshot();
  assert.equal(data.capacity.ram.actual, null);
  assert.equal(data.capacity.ram.available, 6);
  assert.equal(data.capacity.ram.reserved, 14);
  assert.equal(data.capacity.gpu.utilization, 73);
  assert.equal(data.jobs[0].request.cpu, 6);
  assert.equal(snapshot('partial').capacity.gpu.reserved, null);
});
test('stale and future snapshots disable all controls', () => {
  const data = snapshot();
  assert.equal(freshness(data, fixtureTime), 'live');
  assert.deepEqual(eligibleActions(data, data.jobs[2], fixtureTime), ['cancel']);
  assert.deepEqual(eligibleActions(data, data.jobs[0], fixtureTime), ['terminate']);
  assert.deepEqual(eligibleActions(data, data.jobs[0], fixtureTime + 20_000), []);
  assert.equal(freshness(data, fixtureTime - 20_000), 'stale');
  assert.deepEqual(eligibleActions(data, data.jobs[4], fixtureTime), []);
});
test('filters search identities and resource categories without changing ordering', () => {
  const data = snapshot();
  assert.equal(filterJobs(data.jobs, { resource: 'gpu' }).length, 2);
  assert.equal(filterJobs(data.jobs, { search: 'nixos' })[0].label, 'NixOS rebuild');
  assert.equal(filterJobs(data.jobs, { project: 'studio', agent: 'Claude' }).length, 2);
  assert.equal(filterJobs(data.jobs, { state: 'failed' }).length, 1);
});
test('all deterministic scenarios render without claiming unsupported live actions', () => {
  for (const scenario of ['empty','overlap','ram','vram','exclusive','game','resident','partial','hold']) {
    const html = render(state(snapshot(scenario)), fixtureTime);
    assert.match(html, /Resource Queue/);
    assert.match(html, /Backend support/);
    assert.match(html, /Managed model unloading/);
    assert.doesNotMatch(html, /data-action="unload"|data-action="priority"|data-action="game"/);
    assert.ok(!html.includes('NaN'));
  }
});
test('inspector escapes every backend label and shows exact wait reason', () => {
  const data = snapshot();
  data.jobs[2].label = '<img src=x onerror=alert(1)>';
  const html = render(state(data, { selected: jobId(3) }), fixtureTime);
  assert.ok(!html.includes('<img'));
  assert.match(html, /&lt;img/);
  assert.match(html, /Needs 10 GiB RAM/);
  assert.match(html, /Unknown peaks are not zero/);
  assert.match(html, /job inspector/i);
});
test('failed query preserves stale queue instead of claiming empty or live', () => {
  const html = render(state(snapshot(), { error: 'Socket unavailable' }), fixtureTime);
  assert.match(html, /Connection interrupted/);
  assert.match(html, /NixOS rebuild/);
  assert.doesNotMatch(html, /● Live|data-action="pause"|data-action="terminate"|data-action="cancel"/);
});
test('diagnostic exports use an explicit allowlist and bounded jobs/events', () => {
  const data = snapshot();
  data.jobs[0].environment = { TOKEN: 'secret' };
  data.jobs[0].command = ['secret'];
  data.jobs[0].events = Array.from({ length: 150 }, (_, i) => ({ at: i, label: 'Started' }));
  const output = diagnostic(data, data.jobs[0]);
  assert.equal(output.jobs[0].events.length, 100);
  assert.equal(output.jobs[0].environment, undefined);
  assert.ok(!JSON.stringify(output).includes('secret'));
  assert.match(journalQuery(jobId(1)), /RESOURCE_JOB_ID='/);
});
test('fresh responses cannot disguise stale telemetry and unknown jobs are not history', () => {
  const data = snapshot();
  data.sampledAt = new Date(fixtureTime - 60_000).toISOString();
  assert.equal(freshness(data, fixtureTime), 'stale');
  assert.deepEqual(eligibleActions(data, data.jobs[0], fixtureTime), []);
  data.jobs[0].state = 'unknown';
  const html = render(state(data), fixtureTime);
  assert.match(html, /Needs attention/);
  assert.match(html, /Recent history <span class="count">2/);
});
test('bounded lifecycle logs and admission snapshots use only allowlisted fields', () => {
  const raw = fixture();
  raw.jobs[0].events = Array.from({ length: 140 }, (_, i) => ({ timestamp: fixtureTime / 1000 - i, event: 'waiting', reason: 'Needs more RAM', environment: { TOKEN: 'secret' }, command: 'secret', snapshot: raw.telemetry }));
  const data = adaptStatus(raw);
  assert.equal(data.jobs[0].events.length, 100);
  assert.equal(data.jobs[0].logs.length, 100);
  assert.equal(data.jobs[0].admission.availableRam, 6);
  assert.ok(!JSON.stringify(data).includes('secret'));
});
test('Orca worktree IDs and legacy composite IDs resolve without inventing agent links', async () => {
  const { resolveWorkspace } = await import('../src/model.mjs');
  const workspace = { id: 'orca-worktree-12', path: '/home/jesse/nix' };
  assert.equal(resolveWorkspace([workspace], workspace.id), workspace);
  assert.equal(resolveWorkspace([workspace], workspace.path), workspace);
  assert.equal(resolveWorkspace([workspace], `repo-12::${workspace.path}`), workspace);
  assert.equal(resolveWorkspace([workspace], '/removed/worktree'), undefined);
});
test('history metrics exclude unknowns and ongoing jobs from measured facts', async () => {
  const { historyMetrics } = await import('../src/model.mjs');
  const data = snapshot();
  data.jobs[4].measured.ram = 2;
  assert.deepEqual(historyMetrics(data.jobs), { count: 2, queueSamples: 2, queueMean: 100, ramSamples: 1, ramRatio: 50, vramSamples: 0, vramRatio: null });
});
