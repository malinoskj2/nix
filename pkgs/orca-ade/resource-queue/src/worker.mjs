import { createBackend } from './backend.mjs';
import { resolveWorkspace } from './model.mjs';
export default function activate(orca) {
  const backend = createBackend();
  orca.panels.handle('queue.status', async () => backend.status());
  orca.panels.handle('queue.control', async (input) => backend.control(input));
  orca.panels.handle('queue.identities', async () => {
    const result = await orca.host.call('workspace.list');
    return { workspaces: result.workspaces.map(({ id, path, name, branch }) => ({ id, path, name, branch })) };
  });
  orca.panels.handle('queue.openOwner', async (input) => {
    if (!input || typeof input.path !== 'string') throw new Error('Missing worktree path');
    const result = await orca.host.call('workspace.list');
    const workspace = resolveWorkspace(result.workspaces, input.path);
    if (!workspace) throw new Error('This historical worktree is no longer open in Orca.');
    return orca.host.call('workspace.open', { workspaceId: workspace.id });
  });
}
