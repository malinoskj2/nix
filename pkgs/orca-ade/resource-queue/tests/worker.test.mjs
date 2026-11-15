import { test } from 'node:test';
import assert from 'node:assert/strict';
import activate from '../src/worker.mjs';
test('worker uses supported host identity API and refuses unresolved historical owners', async () => {
  const handlers = new Map(), calls = [];
  const workspace = { id: 'repo::/work/nix', name: 'nix', path: '/work/nix', branch: 'feature' };
  activate({ panels: { handle(name, fn) { handlers.set(name, fn); } }, host: { async call(method, params) {
    calls.push({ method, params });
    if (method === 'workspace.list') return { workspaces: [workspace], truncated: false };
    if (method === 'workspace.open') return { opened: true };
    throw new Error('Unsupported host API');
  } } });
  const identities = await handlers.get('queue.identities')();
  assert.deepEqual(identities.workspaces, [workspace]);
  assert.deepEqual(await handlers.get('queue.openOwner')({ path: workspace.id }), { opened: true });
  assert.deepEqual(calls.at(-1), { method: 'workspace.open', params: { workspaceId: workspace.id } });
  await assert.rejects(handlers.get('queue.openOwner')({ path: '/deleted/worktree' }), /historical/);
  assert.equal(calls.filter((call) => call.method === 'workspace.open').length, 1);
});
