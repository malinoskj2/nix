import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DiscordContext, discordApi, policySchema } from './discord.js';

function fixture(policy = {}) {
  const calls = [];
  const channels = {
    '10': { id: '10', guild_id: '1', type: 4 },
    '11': { id: '11', guild_id: '1', parent_id: '10' },
    '12': { id: '12', guild_id: '1', parent_id: '11' },
    '20': { id: '20', guild_id: '1' },
    '21': { id: '21', guild_id: '2' },
    '22': { id: '22', type: 1 },
  };
  const message = (id, channel_id) => ({ id, channel_id, hit: true, content: 'hello', author: { id: '3', username: 'user' }, referenced_message: { content: 'secret' }, message_snapshots: [{ content: 'secret' }] });
  const api = async (path, params) => {
    calls.push([path, params]);
    if (path === '/users/@me/guilds') return [{ id: '1', name: 'allowed' }, { id: '2', name: 'secret' }];
    if (path === '/guilds/1/channels') return Object.values(channels).filter(c => c.guild_id === '1');
    if (path === '/guilds/1/threads/active') return { threads: [channels['12']] };
    if (path.endsWith('/messages/search')) return { total_results: 999, messages: [[message('30', '12')], [message('31', '20')], [message('32', '21')]] };
    if (path.endsWith('/messages')) return [message('31', '20')];
    return channels[path.split('/').at(-1)];
  };
  return { calls, context: new DiscordContext(api, { allowedGuilds: ['1'], excludedChannels: ['10'], ...policy }) };
}

test('category exclusions cover child channels and threads on every read path', async () => {
  const { context, calls } = fixture();
  assert.deepEqual((await context.listChannels('1')).map(c => c.id), ['20']);
  assert.deepEqual(await context.listThreads('1'), []);
  for (const channelId of ['10', '11', '12', '21', '22'])
    await assert.rejects(context.readMessages({ channelId }));
  assert.equal(calls.some(([p]) => p.endsWith('/messages')), false);
});

test('search drops excluded channels, foreign guilds, counts and nested content', async () => {
  const { context, calls } = fixture();
  const output = await context.search({ query: 'hello' });
  assert.deepEqual(output.results[0].messages.map(m => m.id), ['31']);
  assert.equal(JSON.stringify(output).includes('secret'), false);
  assert.equal(JSON.stringify(output).includes('999'), false);
  assert.equal(output.results[0].nextOffset, 25);
  assert.deepEqual(calls.find(([path]) => path.endsWith('/messages/search'))[1].getAll('channel_id'), ['20']);
});

test('excluded servers override allowed servers; empty allowlist denies search', async () => {
  const { context, calls } = fixture({ excludedGuilds: ['1'] });
  assert.deepEqual(await context.listServers(), []);
  await assert.rejects(context.search({ query: 'hello', guildId: '1' }));
  assert.deepEqual((await fixture({ allowedGuilds: [] }).context.search({ query: 'hello' })).results, []);
  assert.equal(calls.some(([p]) => p.includes('/messages')), false);
});

test('explicit excluded channel is rejected before search or message fetching', async () => {
  const { context, calls } = fixture();
  await assert.rejects(context.search({ query: 'hello', guildId: '1', channelId: '12' }));
  assert.equal(calls.some(([p]) => p.includes('/messages')), false);
});

test('read output contains links but no nested reply or forwarded content', async () => {
  const { context } = fixture();
  const messages = await context.readMessages({ channelId: '20', around: '31' });
  assert.equal(messages[0].url, 'https://discord.com/channels/1/20/31');
  assert.equal(JSON.stringify(messages).includes('secret'), false);
});

test('policy rejects malformed IDs and unknown configuration', () => {
  assert.throws(() => policySchema.parse({ allowedGuilds: ['../x'] }));
  assert.throws(() => policySchema.parse({ allowedGuilds: [], allowAll: true }));
});

test('HTTP uses only GET, serializes requests and does not expose error bodies', async () => {
  let active = 0;
  const api = discordApi('credential', async (_url, options) => {
    assert.equal(options.method, undefined);
    assert.equal(options.headers.Authorization, 'credential');
    assert.equal(++active, 1);
    await new Promise(resolve => setTimeout(resolve, 1));
    active--;
    return new Response('sensitive body', { status: 403 });
  });
  const results = await Promise.allSettled([api('/a'), api('/b')]);
  for (const result of results) {
    assert.equal(result.status, 'rejected');
    assert.equal(result.reason.message, 'Discord request failed (HTTP 403).');
  }
});

test('rate limits retry with a bound and reject long waits', async () => {
  let requests = 0;
  const api = discordApi('credential', async () => {
    requests++;
    return Response.json(requests === 1 ? { retry_after: 0 } : { ok: true }, { status: requests === 1 ? 429 : 200 });
  });
  assert.deepEqual(await api('/a'), { ok: true });
  const blocked = discordApi('credential', async () => Response.json({ retry_after: 60 }, { status: 429 }));
  await assert.rejects(blocked('/a'), /retry this tool later/);
});
