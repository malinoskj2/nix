import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createBackend } from '../src/backend.mjs';
import { fixture, fixtureTime, jobId } from './fixtures.mjs';
function harness() {
  let raw = fixture();
  const calls = [];
  const backend = createBackend({ now: () => fixtureTime, run: async (command, args) => {
    calls.push({ command, args });
    if (args[0] === '--json') return JSON.stringify(raw);
    if (args[0] === 'cancel') { raw.jobs[2].state = 'cancelled'; raw.jobs[2].revision++; raw.revision++; }
    return '{"ok":true}';
  } });
  return { backend, calls, set: (next) => { raw = next; } };
}
test('confirmed cancellation uses immutable identity and fresh backend revision', async () => {
  const { backend, calls } = harness();
  const result = await backend.control({ action: 'cancel', id: jobId(3), revision: 1, confirm: true });
  assert.equal(result.accepted, true);
  assert.deepEqual(calls[1].args, ['cancel', jobId(3), '--revision', '1', '--confirm']);
  assert.equal(result.snapshot.jobs[2].state, 'cancelled');
});
test('stale revision, wrong lifecycle and unsupported actions never call control', async () => {
  for (const input of [
    { action: 'cancel', id: jobId(3), revision: 0 },
    { action: 'cancel', id: jobId(1), revision: 1 },
    { action: 'unload', id: jobId(2), revision: 1 },
    { action: 'terminate', id: jobId(999), revision: 1 },
    { action: 'pause; shutdown' },
  ]) {
    const { backend, calls } = harness();
    await assert.rejects(backend.control({ ...input, confirm: true }));
    assert.equal(calls.length, 1);
  }
});
test('explicit confirmation and freshness are required', async () => {
  const { backend, calls, set } = harness();
  await assert.rejects(backend.control({ action: 'pause' }), /confirmed/);
  assert.equal(calls.length, 0);
  set({ ...fixture(), generated_at: fixtureTime / 1000 - 60 });
  await assert.rejects(backend.control({ action: 'pause', confirm: true }), /stale/);
  assert.equal(calls.length, 1);
});
test('status coalesces readers and rejects backwards revisions', async () => {
  const { backend, calls, set } = harness();
  await Promise.all([backend.status(), backend.status()]);
  assert.equal(calls.length, 1);
  set({ ...fixture(), revision: 10 });
  await assert.rejects(backend.status(), /backwards/);
});
test('control process failure never becomes successful UI feedback', async () => {
  const backend = createBackend({ now: () => fixtureTime, run: async (_, args) => {
    if (args[0] === '--json') return JSON.stringify(fixture());
    throw new Error('owner permission denied');
  } });
  await assert.rejects(backend.control({ action: 'pause', confirm: true }), /permission denied/);
});
test('actual process boundary reports missing CLI and enforces bounded execution', async () => {
  const { runCommand } = await import('../src/backend.mjs');
  await assert.rejects(runCommand('/definitely-missing-resource-client', []), /not installed/);
  const output = await runCommand(process.execPath, ['-e', 'process.stdout.write("ok")']);
  assert.equal(output, 'ok');
  await assert.rejects(runCommand(process.execPath, ['-e', 'process.stderr.write("denied");process.exit(2)']), /denied/);
});

test('run controls send exact confirmed actions, IDs and revisions', async () => {
  for (const action of ['force-run', 'run-next', 'run-host']) {
    const { backend, calls } = harness();
    const result = await backend.control({ action, id: jobId(3), revision: 1, confirm: true });
    assert.equal(result.accepted, true);
    assert.deepEqual(calls[1].args, [action, jobId(3), '--revision', '1', '--confirm']);
  }
});

test('run controls reject old backends, stale confirmation and already released jobs', async () => {
  for (const action of ['force-run', 'run-next', 'run-host']) {
    for (const kind of ['unsupported', 'stale', 'pending', 'running']) {
      const { backend, calls, set } = harness();
      const raw = fixture();
      if (kind === 'unsupported') delete raw.capabilities[action.replace('-', '_')];
      if (kind === 'pending') { raw.jobs[2].state = 'pending'; raw.jobs[2].released = true; }
      if (kind === 'running') raw.jobs[2].state = 'running';
      set(raw);
      await assert.rejects(backend.control({ action, id: jobId(3), revision: kind === 'stale' ? 0 : 1, confirm: true }));
      assert.equal(calls.length, 1);
    }
  }
});
