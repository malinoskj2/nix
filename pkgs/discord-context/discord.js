import { z } from 'zod';

const id = z.string().regex(/^\d{1,20}$/);
export const policySchema = z.object({
  excludedGuilds: z.array(id).default([]),
  excludedChannels: z.array(id).default([]),
}).strict();

// One queue across all clients prevents concurrent agents from multiplying requests.
export function discordApi(token, fetcher = fetch) {
  let queue = Promise.resolve();
  return (path, params = new URLSearchParams()) => {
    const run = async () => {
      for (let attempt = 0; attempt < 3; attempt++) {
        const response = await fetcher(`https://discord.com/api/v10${path}?${params}`, {
          headers: { Authorization: token },
          signal: AbortSignal.timeout(15_000),
          redirect: 'error',
        });
        if (response.status === 429 || response.status === 202) {
          const body = await response.json();
          const delay = Number(body.retry_after ?? 1);
          if (!Number.isFinite(delay) || delay < 0 || delay > 5 || attempt === 2)
            throw new Error('Discord is busy; retry this tool later.');
          await new Promise(resolve => setTimeout(resolve, Math.max(250, delay * 1000)));
          continue;
        }
        if (!response.ok) throw new Error(`Discord request failed (HTTP ${response.status}).`);
        return response.json();
      }
    };
    const result = queue.then(run);
    queue = result.catch(() => {});
    return result;
  };
}

export class DiscordContext {
  constructor(api, policy) {
    this.api = api;
    this.policy = policySchema.parse(policy);
    this.channels = new Map();
  }

  guildAllowed(guildId) {
    return !this.policy.excludedGuilds.includes(guildId);
  }

  requireGuild(guildId) {
    if (!this.guildAllowed(guildId)) throw new Error('Server is outside the allowed policy.');
  }

  async channelAllowed(channelId, guildId, seen = new Set()) {
    if (this.policy.excludedChannels.includes(channelId) || seen.has(channelId) || seen.size >= 4) return false;
    seen.add(channelId);
    let channel = this.channels.get(channelId);
    if (!channel) {
      channel = await this.api(`/channels/${channelId}`);
      this.channels.set(channelId, channel);
    }
    // Missing guilds (including DMs) fail closed.
    if (!channel.guild_id || !this.guildAllowed(channel.guild_id) || (guildId && channel.guild_id !== guildId)) return false;
    return !channel.parent_id || this.channelAllowed(channel.parent_id, channel.guild_id, seen);
  }

  async requireChannel(channelId, guildId) {
    if (!await this.channelAllowed(channelId, guildId)) throw new Error('Channel is outside the allowed policy.');
  }

  async listServers() {
    const guilds = await this.api('/users/@me/guilds', new URLSearchParams({ limit: '200' }));
    return guilds.filter(g => this.guildAllowed(g.id)).map(g => ({ id: g.id, name: g.name }));
  }

  async getMemberRoles(guildId, userId) {
    this.requireGuild(guildId);
    const member = await this.api(`/guilds/${guildId}/members/${userId}`);
    const roles = await this.api(`/guilds/${guildId}/roles`);
    const byId = new Map(roles.map(role => [role.id, role]));
    // @everyone is implicit in Discord's member role list.
    const assigned = [...new Set([guildId, ...member.roles])].map(id => {
      const role = byId.get(id);
      return {
        id, name: role?.name ?? null, position: role?.position ?? null,
        hoist: role?.hoist ?? null, managed: role?.managed ?? null,
      };
    });
    assigned.sort((a, b) => (b.position ?? -1) - (a.position ?? -1));
    return { guildId, userId, roles: assigned };
  }

  async listChannels(guildId) {
    this.requireGuild(guildId);
    const channels = await this.api(`/guilds/${guildId}/channels`);
    for (const channel of channels) this.channels.set(channel.id, { ...channel, guild_id: guildId });
    const result = [];
    for (const channel of channels) {
      if (await this.channelAllowed(channel.id, guildId))
        result.push({ id: channel.id, name: channel.name, type: channel.type, parentId: channel.parent_id });
    }
    return result;
  }

  message(message, guildId) {
    // Never return nested replies, forwards, embeds or mentions: they can carry excluded content.
    return {
      id: message.id, channelId: message.channel_id, guildId,
      author: { id: message.author?.id, name: message.author?.global_name ?? message.author?.username },
      timestamp: message.timestamp, content: message.content,
      url: `https://discord.com/channels/${guildId}/${message.channel_id}/${message.id}`,
    };
  }

  async readMessages({ channelId, before, around, limit = 25 }) {
    await this.requireChannel(channelId);
    const query = new URLSearchParams({ limit: String(limit) });
    if (before) query.set('before', before);
    if (around) query.set('around', around);
    const messages = await this.api(`/channels/${channelId}/messages`, query);
    const guildId = this.channels.get(channelId).guild_id;
    return messages.filter(m => m.channel_id === channelId).map(m => this.message(m, guildId));
  }

  async listThreads(guildId) {
    this.requireGuild(guildId);
    const { threads } = await this.api(`/guilds/${guildId}/threads/active`);
    const result = [];
    for (const thread of threads) {
      this.channels.set(thread.id, { ...thread, guild_id: guildId });
      if (await this.channelAllowed(thread.id, guildId))
        result.push({ id: thread.id, name: thread.name, parentId: thread.parent_id });
    }
    return result;
  }

  async search({ query, guildId, channelId, authorId, before, after, offset = 0 }) {
    const guilds = guildId ? [guildId] : (await this.listServers()).map(g => g.id);
    for (const guild of guilds) this.requireGuild(guild);
    const results = [];
    for (const guild of guilds.slice(0, 20)) {
      let channelIds;
      if (channelId) {
        await this.requireChannel(channelId, guild);
        channelIds = [channelId];
      } else {
        const channels = await this.listChannels(guild);
        const threads = await this.listThreads(guild);
        channelIds = [...new Set([...channels.filter(c => c.type !== 4), ...threads].map(c => c.id))];
      }
      if (channelIds.length > 500) throw new Error('Too many channels; narrow the search to a channel.');
      if (channelIds.length === 0) {
        results.push({ guildId: guild, messages: [], nextOffset: null });
        continue;
      }
      const params = new URLSearchParams({ content: query, offset: String(offset), limit: '25', sort_by: 'timestamp', sort_order: 'desc' });
      for (const channel of channelIds) params.append('channel_id', channel);
      for (const [key, value] of [['author_id', authorId], ['max_id', before], ['min_id', after]])
        if (value) params.set(key, value);
      const data = await this.api(`/guilds/${guild}/messages/search`, params);
      const messages = [];
      for (const group of data.messages ?? []) {
        for (const message of group) {
          if (message.hit === false || messages.some(m => m.id === message.id)) continue;
          if (await this.channelAllowed(message.channel_id, guild)) messages.push(this.message(message, guild));
        }
      }
      // Do not expose Discord's counts, which include excluded channels.
      results.push({ guildId: guild, messages, nextOffset: offset < 9975 ? Math.min(9975, offset + 25) : null });
    }
    return { results, serverLimitReached: guilds.length > 20 };
  }
}

export const snowflake = id;
