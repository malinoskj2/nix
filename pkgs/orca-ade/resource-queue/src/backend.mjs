import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { commands } from './config.mjs';
import { adaptStatus } from './adapter.mjs';
import { eligibleActions } from './model.mjs';
const execute = promisify(execFile);
export const runCommand = async (command, args) => {
  try {
    const { stdout } = await execute(command, args, { timeout: 8000, maxBuffer: 1024 * 1024, encoding: 'utf8', windowsHide: true });
    return stdout;
  } catch (error) {
    // CLI diagnostics are safe labels; do not expose raw process spawn arguments.
    if (error.code === 'ENOENT') throw new Error('Scheduler client is not installed. Rebuild with resourceSchedulerPackage configured.');
    if (error.killed || error.code === 'ETIMEDOUT') throw new Error('Scheduler request timed out. Reservations remain authoritative on the host.');
    throw new Error(String(error.stderr || 'Scheduler command failed; inspect host service logs.').trim().slice(0, 1024));
  }
};
export function createBackend({ run = runCommand, now = Date.now } = {}) {
  let snapshot = null;
  let pending = null;
  return {
    async status() {
      // Coalesce concurrent frames without maintaining another queue or reservation ledger.
      if (pending) return pending;
      pending = (async () => {
        const raw = JSON.parse(await run(commands.status, ['--json']));
        const next = adaptStatus(raw);
        if (snapshot && next.revision < snapshot.revision) throw new Error('Scheduler revision moved backwards; reconnect to verify host identity.');
        snapshot = next;
        return next;
      })();
      try { return await pending; } finally { pending = null; }
    },
    async acknowledge(input) {
      if (input?.confirm !== true || !/^[a-f0-9]{32}$/.test(input.id)) throw new Error('Confirm a specific completion notification.');
      await run(commands.job, ['ack', input.id, '--confirm']);
      return { snapshot: await this.status() };
    },
    async control(input) {
      if (!input || input.confirm !== true) throw new Error('Action must be explicitly confirmed.');
      const live = await this.status();
      const job = input.id ? live.jobs.find((j) => j.id === input.id) : null;
      if (input.id && (!job || job.revision !== input.revision)) throw new Error('Job changed since inspection. Refresh and confirm again.');
      if (!eligibleActions(live, job, now()).includes(input.action)) throw new Error('This action is unavailable, unsupported or telemetry is stale.');
      const args = [input.action];
      if (job) args.push(job.id, '--revision', String(job.revision));
      args.push('--confirm');
      // No shell. Action enum, stable UUID and backend revision are rechecked before execution.
      const output = await run(commands.control, args);
      return { accepted: true, detail: String(output).trim().slice(0, 1024), snapshot: await this.status() };
    }
  };
}
