import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { request } from 'node:http';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

test('HTTP MCP handshake, tools, policy reload and browser/host rejection', { timeout: 15000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'discord-context-test-'));
  const policy = join(dir, 'policy.json');
  await writeFile(policy, JSON.stringify({ excludedGuilds: ['1'] }));
  await writeFile(join(dir, 'token'), 'test-only-credential');
  const child = spawn(process.execPath, [new URL('./server.js', import.meta.url).pathname], {
    env: { ...process.env, PORT: '0', DISCORD_TOKEN_FILE: join(dir, 'token'), DISCORD_POLICY_FILE: policy },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  const exited = once(child, 'exit');
  t.after(async () => {
    child.kill();
    await exited;
    await rm(dir, { recursive: true, force: true });
  });
  const address = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', () => reject(new Error('Server exited before listening.')));
    child.stderr.on('data', chunk => {
      const match = chunk.toString().match(/127\.0\.0\.1:(\d+)/);
      if (match) resolve(`http://127.0.0.1:${match[1]}/mcp`);
    });
  });
  const transport = new StreamableHTTPClientTransport(new URL(address));
  const client = new Client({ name: 'test', version: '1' });
  t.after(() => client.close());
  await client.connect(transport);
  const tools = await client.listTools();
  assert.deepEqual(tools.tools.map(t => t.name).sort(), ['get_member_roles', 'list_channels', 'list_servers', 'list_threads', 'read_messages', 'search_messages']);
  assert.ok(tools.tools.every(t => t.annotations.readOnlyHint));
  const initial = await client.callTool({ name: 'search_messages', arguments: { query: 'test', guildId: '1' } });
  assert.equal(initial.isError, true);
  await writeFile(policy, JSON.stringify({ excludedGuilds: ['2'] }));
  const excluded = await client.callTool({ name: 'search_messages', arguments: { query: 'test', guildId: '2' } });
  assert.equal(excluded.isError, true);
  assert.equal(JSON.stringify(excluded).includes('test-only-credential'), false);
  const excludedRoles = await client.callTool({ name: 'get_member_roles', arguments: { guildId: '2', userId: '3' } });
  assert.equal(excludedRoles.isError, true);
  const invalidRoles = await client.callTool({ name: 'get_member_roles', arguments: { guildId: '1', userId: '../x' } });
  assert.equal(invalidRoles.isError, true);
  const invalid = await client.callTool({ name: 'read_messages', arguments: { channelId: '../x' } });
  assert.equal(invalid.isError, true);
  assert.equal((await fetch(address, { method: 'POST', headers: { Origin: 'https://example.com' } })).status, 403);
  const hostStatus = await new Promise((resolve, reject) => {
    const req = request(address, { method: 'POST', headers: { Host: 'example.com' } }, res => {
      res.resume();
      resolve(res.statusCode);
    });
    req.on('error', reject);
    req.end();
  });
  assert.equal(hostStatus, 403);
});
