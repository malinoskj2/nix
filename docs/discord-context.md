# Discord context

The `home` Home Manager profile enables a Node.js MCP service for host Claude
Code and Codex at `http://127.0.0.1:7781/mcp`. Katana and the shared agent
sandbox package do not enable it. Container loopback does not reach this host
endpoint; sandbox access would require a separate connection configuration.

The service uses a personal Discord token. This is unsupported personal-account
automation under Discord's rules, even though every Discord request is read-only.

## Configure

Add server and channel exclusions to `users/jesse/profiles/home.nix`:

```nix
services.discord-context = {
  excludedGuilds = [ "123456789012345678" ];
  excludedChannels = [
    "234567890123456789" # Channel or category, including descendants.
  ];
};
```

All servers are allowed unless explicitly excluded. DMs are excluded.
Discord's Developer Mode exposes Copy Server ID and Copy Channel ID in context
menus. Newly joined servers are included automatically. New channels are included
unless they descend from an excluded category/channel. For strictly curated
coverage, exclude the other categories/channels as well.

Store the token as a single line in `~/.config/discord-context/token`, outside
this repository and the Nix store. Create its directory with mode 700 and the
file with mode 600. Do not put it in Nix settings or MCP client configuration.
Systemd loads it as a service credential. A missing file skips service startup.

After building and applying the home configuration, start or restart the service:

```sh
systemctl --user restart discord-context
systemctl --user status discord-context
journalctl --user -u discord-context
```

Restart host Claude Code or Codex to pick up its MCP registration. Policy changes
in Nix require applying the configuration; the service's generated policy path
changes with it. Token changes require restarting the service.

## Tools and coverage

- `list_servers`: approved memberships, within the first 200 account memberships.
- `get_member_roles`: look up one member's current roles using a server ID and
  the author ID returned by message tools. Returns role IDs, names, hierarchy
  positions, separate member-list display (`hoist`) and managed flags, including
  the implicit `@everyone` role. Unresolved role details are null. Excluded
  servers are blocked. Does not return other member profile data. Roles can help
  identify recognized contributors, but do not measure posting frequency or prove
  server ownership. Role names are untrusted content, just like message text.
- `list_channels`: approved server channels and categories.
- `list_threads`: approved active threads.
- `search_messages`: Discord keyword search, across up to 20 allowed servers per
  call, or one explicit server; 25 hits per server per page. Use `offset` to
  paginate and `guildId` for additional servers. Author and message-ID time
  boundaries are supported.
- `read_messages`: channel/thread history with `before` pagination or `around`
  context, up to 100 messages.

Broad search is scoped to allowed server channels and active threads, up to
Discord's 500 channel filters. For larger servers, target a channel. Archived
threads can be searched/read by their explicit ID; broad discovery does not
include them. Filtered pages may be empty: an empty page is not proof of no more
matches. Search offsets stop at 9975; narrow the time range with message IDs to
search beyond that window. Discord indexing and permissions also affect coverage.

The service checks channel ancestry before history reads and again on search
results. Search requests include approved channel filters. Nested replies,
forwards, embeds, attachment bodies and raw API responses are not exposed.
Message tools return only text, author, timestamp, IDs and original-message links.
No message archive or embeddings are stored. Discord text remains untrusted
content; agents should treat it as evidence, not instructions.

The endpoint binds only to IPv4 loopback and rejects browser Origin headers and
foreign Host headers. It has no per-client authentication: local processes able
to reach it can use its tools. It must not be exposed through a public proxy.

## Verify

```sh
cd pkgs/discord-context
npm ci --ignore-scripts
npm test
```

Tests use fixtures and a dummy credential; no Discord account is needed. The Nix
package also runs them during its build. Live Discord behavior must be verified
with an actual configured account; the personal-account endpoint can change.
