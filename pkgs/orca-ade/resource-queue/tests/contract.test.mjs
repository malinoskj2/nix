import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { adaptStatus } from '../src/adapter.mjs';
import { diagnostic, historyMetrics, journalQuery } from '../src/model.mjs';
import { capacityCard, render } from '../panel/view.mjs';

// Captured through real Backend.submit/tick/status, not a hand-written wire approximation.
const capture = JSON.parse(readFileSync(new URL('./backend-status-v1.json', import.meta.url)));
const adapted = (scenario) => adaptStatus(capture.scenarios[scenario]);
const state = (snapshot, selected) => ({ snapshot, selected, filters: {}, samples: [], identities: [], logs: [] });
const now = capture.scenarios.exclusive_running.generated_at * 1000;

test('real backend exclusive fixture keeps unknown requested VRAM separate from its effective allocation', () => {
  const raw = capture.scenarios.exclusive_running;
  const snapshot = adapted('exclusive_running');
  const job = snapshot.jobs[0];
  assert.equal(raw.jobs[0].requested.vram_mib, null);
  assert.equal(raw.jobs[0].vram_estimate, 'all-available');
  assert.equal(job.request.vram, null);
  assert.equal(job.effectiveBudget.vram, 15);
  assert.equal(job.vramEstimate, 'all-available');
  assert.equal(snapshot.capacity.gpu.reserved, 15);
  assert.equal(snapshot.capacity.gpu.reserved, raw.telemetry.gpu.reserved_mib / 1024);
  assert.equal(job.measured.vram, null);
  const html = render(state(snapshot, job.id), now);
  assert.match(html, /VRAM peak unknown · 15 GiB reserved/);
  assert.match(html, /<th>GPU VRAM<\/th><td>Unknown<\/td><td>15 GiB<\/td><td>Unknown<\/td>/);
  const exported = diagnostic(snapshot, job).jobs[0];
  assert.equal(exported.request.vram, null);
  assert.equal(exported.effectiveBudget.vram, 15);
  assert.equal(historyMetrics([{ ...job, state: 'completed', measured: { ...job.measured, vram: 10 } }]).vramSamples, 0);
});

test('queued exclusive has no invented allocation or peak before actual admission', () => {
  const snapshot = adapted('game_pending');
  const game = snapshot.jobs.find((job) => job.priority === 'game');
  assert.equal(game.request.vram, null);
  assert.equal(game.effectiveBudget.vram, null);
  const html = render(state(snapshot, game.id), now);
  assert.match(html, /VRAM peak unknown · allocation pending/);
  assert.equal(snapshot.capacity.gpu.reserved, 0);
  assert.equal(snapshot.capacity.cpu.reserved, 6);
});

test('real gaming fixture presents total reservations and effective background limit on distinct bases', () => {
  const snapshot = adapted('game_running');
  assert.equal(snapshot.capacity.cpu.total, 12);
  assert.equal(snapshot.capacity.cpu.reserved, 2);
  assert.equal(snapshot.capacity.cpu.effectiveBackground, 4);
  assert.equal(snapshot.capacity.cpu.gameActive, true);
  const card = capacityCard('cpu', snapshot.capacity.cpu);
  assert.match(card, /2<small> \/ 12/);
  assert.match(card, /All job reservations \/ configured capacity/);
  assert.match(card, /Game protection: background limit 4/);
  assert.doesNotMatch(card, /2<small> \/ 4/);
  // Total CPU reservations include game allocations: never use 4 as their denominator.
  assert.equal(snapshot.capacity.cpu.reserved, capture.scenarios.game_running.telemetry.cpu.reserved);
});

test('gaming protection errors are visible; external games do not look like ordinary sharing', () => {
  const raw = structuredClone(capture.scenarios.game_running);
  raw.mode = 'normal'; // External game discovery can activate protection without a queued game.
  raw.telemetry.cpu.game_protection_errors = ['Slurm CPU cgroup unavailable for test-job'];
  const snapshot = adaptStatus(raw);
  const html = render({ ...state(snapshot), tab: 'controls' }, now);
  assert.match(html, /Game protection active/);
  assert.match(capacityCard('cpu', snapshot.capacity.cpu), /protection degraded/);
  assert.match(html, /Slurm CPU cgroup unavailable for test-job/);
});

test('copied journal selector matches fields emitted by the actual backend native journal writer', () => {
  const native = capture.journal_submission;
  const event = JSON.parse(native.MESSAGE);
  assert.equal(native.RESOURCE_JOB_ID, event.job_id);
  assert.equal(native.SYSLOG_IDENTIFIER, 'resource-scheduler');
  assert.equal(native.RESOURCE_EVENT, 'submission');
  assert.equal(event.requested.vram_mib, null);
  assert.equal(event.vram_estimate, 'all-available');
  assert.equal(event.allocation, null);
  const query = journalQuery(event.job_id);
  assert.match(query, /SYSLOG_IDENTIFIER=resource-scheduler/);
  assert.ok(query.includes(`RESOURCE_JOB_ID='${native.RESOURCE_JOB_ID}'`));
  assert.doesNotMatch(query, /SLURM_JOB_ID|(?:^| )JOB_ID=/);
});

test('backend transport compaction remains visible rather than silently hiding historical gaps', () => {
  const raw = structuredClone(capture.scenarios.game_running);
  raw.truncated = { events: true, history: 4 };
  const snapshot = adaptStatus(raw);
  assert.ok(snapshot.limitations.some((text) => text.includes('omitted public lifecycle events')));
  assert.ok(snapshot.limitations.some((text) => text.includes('omitted 4 historical jobs')));
});
