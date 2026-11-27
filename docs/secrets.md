# Secrets

All of a host's secrets live in one
[sops](https://github.com/getsops/sops)-encrypted file, decrypted at boot by
[sops-nix](https://github.com/Mic92/sops-nix) into `/run/secrets`. Each
secret has exactly one kind of consumer:

- **Host**: a host user or service, such as jesse's own tools (the Venice API
  key for OpenCode) or a system service. It is decrypted to
  `/run/secrets/<name>` with the owner and mode you declare, for example
  jesse `0400`.
- **Broker**: only `agent-broker` can read it, a system user that neither
  jesse nor any agent runs as. Services running as `agent-broker` use it on
  the agents' behalf: an egress proxy that adds it to requests, or a push
  gateway ([agent-egress.md](agent-egress.md)). This is the only way agents
  ever get to use a secret; it is never mounted or readable in a sandbox.

A secret can't be both. Evaluation fails if one name is declared as both
kinds, if two secrets share a key in the file, if a broker secret's owner,
group or mode is changed from `agent-broker:agent-broker 0400`, if a host
secret belongs to `agent-broker` or gives other users access, or if a secret's
name or path is overridden away from `/run/secrets/<name>`. sops-nix
templates aren't supported, since one could copy a broker secret into a file
someone else owns.

Nothing secret is ever committed, not even ciphertext: the repository is
public. It only names the secrets and their consumers. A flake check
(`no-committed-secrets`) fails if sops or age ciphertext, or an age private
key, is ever tracked. It recognises only those encodings: a plaintext token or
another encrypted format gets past it, and the Betterleaks scan on push
([git-push-gate.md](git-push-gate.md)) is the check for those.

`home` uses it today. Another host opts in by importing
[`hosts/common/optional/secret-store.nix`](../hosts/common/optional/secret-store.nix)
for host secrets, or
[`agent-broker.nix`](../hosts/common/optional/agent-broker.nix), which adds
broker secrets and services on top.

## Where everything lives

| What | Path | Owner and mode |
| --- | --- | --- |
| Encrypted secrets | `/var/lib/secrets/secrets.yaml` | root, directory `0700` |
| Recipients (public keys) | `/var/lib/secrets/.sops.yaml` | root |
| Host decryption key | `/var/lib/sops-nix/key.txt` | root, `0600`, directory `0700` |
| Decrypted values | `/run/secrets/<name>` (ramfs, never on disk) | broker: `agent-broker`, `0400`; host: as declared |
| Broker sockets | `/run/agent-broker/<service>/` | `agent-broker:agent-broker-clients`, `2750` |
| Your recovery key | offline, in your password manager | you |

Each file is encrypted to two age keys:

- **The host key**, a dedicated age key that only root can read. `home` runs
  no SSH server, so it has no SSH host key to reuse. A dedicated key also
  keeps decryption separate from SSH identity, so rotating either one doesn't
  touch the other.
- **Your recovery key**, a personal age key that never needs to be on the
  host. Day-to-day editing on the host decrypts with the host key, through
  `sudo`. You only need the recovery key to restore a backup onto a new or
  rebuilt machine.

## One-time setup on a host

1. On a trusted machine, create your recovery key and note its public half:

   ```sh
   nix shell 'nixpkgs#age' -c age-keygen
   ```

   It prints a `# public key: age1…` line and an `AGE-SECRET-KEY-1…` line.
   Save the whole output in your password manager, and don't leave it on disk
   anywhere agents run. Skip this step if you already have one: one recovery
   key covers every host.

2. On the host, after switching to a configuration that imports the module,
   create the host key and `.sops.yaml`:

   ```sh
   secret init age1…your-recovery-public-key…
   ```

   It asks for your sudo password, writes `/var/lib/sops-nix/key.txt` if
   there isn't one, and prints the host's public key.

3. Add the first secret (see below), then back the file up.

Before this, or whenever the file or the host key is missing, switches still
succeed and nothing is deployed: the reason is logged to
`journalctl -u sops-install-secrets`, and every consumer stays stopped.
Nothing falls back to an unprotected copy. A secret that is declared but not
in the file only affects itself: everything else deploys, and only that
secret's consumers stay stopped.

These checks run at boot, on `secret apply`, and on a switch that changes the
declared secrets. If one of them finds something gone that was deployed
before, it withdraws it: a missing file or key deletes every secret from
`/run/secrets` and stops every consumer; a secret removed from the file
deletes that secret and stops its consumers only. Deleting the file or the key
on its own changes nothing until one of those runs, so run `secret apply`
afterwards.

## Day-to-day commands

Every `secret` command elevates with `sudo`. None of them prints a
value except `edit`, which opens the decrypted file in `$EDITOR`.

```sh
secret list                              # names, kinds, in the file, deployed
secret add github-token            # prompts twice, without echo
secret add gh-app-key --file key.pem
printf %s "$value" | secret add name   # or read from stdin
secret rotate github-token
secret remove github-token
secret edit                        # shows every value
secret apply                       # deploy the file's current values now
```

Editing the encrypted file doesn't change the system configuration, so a
switch doesn't redeploy it. `secret apply` decrypts it into
`/run/secrets` straight away, restarts the services that use a changed
secret, and starts any that were waiting for one. Boot deploys it too.

### Adding a secret

1. `secret add <name>` (letters, digits, `-` and `_`).
2. Declare it in the host configuration with its consumer kind. For a host
   user or service:

   ```nix
   secrets.host.venice-api-key = {
     owner = "jesse";
     mode = "0400";                         # the default
     restartUnits = [ "some.service" ];     # optional
   };
   ```

   Its path is `config.secrets.host.venice-api-key.path`, and Home Manager
   reads it as `osConfig.secrets.host.venice-api-key.path`. For a secret only
   agent-broker uses:

   ```nix
   agentBroker.secrets.github-token.inject = {
     hosts = [ "api.github.com" ];
     header = "Authorization";
     format = "Bearer {}";
   };
   ```

   `inject` says how the egress proxy adds it to requests; leave it out for
   secrets a broker service reads itself.

3. Commit the declaration and have Tohru switch; then run `secret apply`. The
   order doesn't matter: a declared secret that isn't in the file yet just
   stays undeployed until you add it and apply.
4. Back the file up.

### Rotating a secret

1. Create the new credential at the provider, leaving the old one valid.
2. `secret rotate <name>`, then `secret apply`. Services that use
   it restart with the new value.
3. Check the consumer works with it (`systemctl status <service>`, its
   journal, a request through the proxy, or the tool that reads it).
4. Revoke the old credential at the provider. Until you do, anyone who copied
   it can still use it.
5. Back the file up.

If a value may have leaked, revoke it first and accept the downtime.

### Removing a secret

1. Remove its `secrets.host.<name>` or `agentBroker.secrets.<name>`
   declaration and every consumer's reference to it; commit and switch.
2. `secret remove <name>`, then `secret apply`.
3. Revoke it at the provider, and back the file up.

Removing it from the file first also works: it is withdrawn on the next
apply, and `secret list` shows it as declared but not in the file until the
declaration is gone too.

## Backup and restore

The encrypted file is useless without the host key or your recovery key, so
a copy of it is safe on private storage. Losing it means re-adding every
secret, so back it up after every change:

```sh
mkdir -p /mnt/media3/backups/secrets
secret backup /mnt/media3/backups/secrets
```

This copies `secrets-<host>-<time>.yaml` and the matching `.sops.yaml`
without overwriting earlier copies. Keep backups out of `/mnt/media3/agent`
and `/mnt/media3/agent-sandbox`, which sandboxes mount, and out of every git
repository. If the share squashes root, back up to a local directory and copy
it there as jesse: the copy is ciphertext, so jesse being able to read it is
fine. The host key isn't backed up: if it's lost, restore with your recovery
key.

To restore onto a new or rebuilt host:

1. Switch it to a configuration that imports the module, then run
   `secret init age1…your-recovery-public-key…`.
2. Put your recovery key in a root-only file on tmpfs, use it, then delete
   it:

   ```sh
   sudo install -m 600 /dev/stdin /run/secrets-recovery.txt   # paste, then Ctrl-D
   secret restore /mnt/media3/backups/secrets/secrets-home-….yaml \
     --identity /run/secrets-recovery.txt
   sudo rm /run/secrets-recovery.txt
   secret apply
   ```

   `restore` re-encrypts the copy to this host's key and your recovery key,
   and keeps any existing file as `secrets.yaml.<time>.bak`.

## Adding a machine or a key

Each host has its own file, encrypted to its own key and your recovery key,
holding only what that host needs. For a new machine, run the one-time setup
there, then add its secrets, or restore another host's backup and remove what
it doesn't need.

To add another recipient, such as a second recovery key:

```sh
secret recipient-add age1…
```

It updates `.sops.yaml` and re-encrypts the file. To drop a recipient, edit
`.sops.yaml` with `sudoedit /var/lib/secrets/.sops.yaml`, then run
`secret rekey`. Dropping a key stops it from decrypting future versions;
any copy it could decrypt before stays readable to it, so rotate the secrets
if the key was compromised.

To replace the host key:

```sh
sudo age-keygen -o /var/lib/sops-nix/key.new
secret recipient-add "$(sudo age-keygen -y /var/lib/sops-nix/key.new)"
sudo mv /var/lib/sops-nix/key.new /var/lib/sops-nix/key.txt
sudoedit /var/lib/secrets/.sops.yaml   # remove the old host key
secret rekey
secret apply
```

## How consumers use secrets

A host secret is a plain file: point the tool or service at its `path`, and
list services that read it in `restartUnits`. Each of those services gets an
ordering after `sops-install-secrets` and a condition on the path of every
secret that names it, so it starts only once all of them are deployed,
restarts when one changes, stops when one is withdrawn, and stays stopped
through `secret apply` until it is back. Its owner can
read it, so anything running as that owner can too, including agents on the
host as jesse for jesse-owned secrets.

A broker service is declared with `agentBroker.services.<name>`. It runs as
`agent-broker`, hardened: `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
`PrivateDevices`, `NoNewPrivileges`, no capabilities, and a
`@system-service` syscall filter without `@privileged` and `@resources`.
`serviceConfig` overrides any of these for a service that needs it.

```nix
agentBroker.services.proxy = {
  description = "Egress proxy for agent sandboxes";
  secrets = [ "github-token" ];
  script = ''
    exec my-proxy --listen "$AGENT_BROKER_SOCKET_DIR/proxy.sock" \
      --token-file ${config.agentBroker.secrets.github-token.path}
  '';
};
```

- It only starts once all of its `secrets` are deployed, and restarts when
  one of them changes, so a missing secret leaves it stopped.
- It reads values from `config.agentBroker.secrets.<name>.path`. The
  `inject` settings are in `config.agentBroker.secrets.<name>.inject`, and in
  `/etc/secrets/config.json` (never the values) for the proxy to read.
- Its sockets go in `$AGENT_BROKER_SOCKET_DIR`, `/run/agent-broker/<name>`.
  The directory is owned by `agent-broker`, with group `agent-broker-clients`
  and the setgid bit, so sockets created there belong to that group; the
  service's `0007` umask makes them group-writable, which is what connecting
  needs. Members of the group, `agentBroker.clients` (jesse on `home`), can
  connect but can't create, rename or remove files there. Everything else the
  service writes is `agent-broker`'s own. Its private runtime directory is
  `/run/agent-broker-<name>`, mode `0700`.
- Sandbox containers get the socket directory through a bind mount and the
  group through `docker run --group-add`, which dockerd applies whatever
  groups the launching session has.

## What agents can and can't see

**Sandboxed agents** see none of these values, of either kind. The launcher
never mounts `/run/secrets`, `/var/lib/secrets` or `/var/lib/sops-nix`, and the
`agent-sandbox-no-secret-mounts` flake check fails if its source ever names
those paths or binds all of `/run` or `/var`. That check reads the launcher's
source for known patterns; it doesn't prove what a running container can
reach, so a mount built some other way would get past it. With the egress
proxy ([agent-egress.md](agent-egress.md)), a sandbox sees only placeholders
and broker sockets: a request to a bound host gets its header added on the
way out, and the value never enters the container.

**Agents on the host, running as jesse,** can read host secrets owned by
jesse, since they are jesse's by design, but not broker secrets:

- Broker secrets are `agent-broker`'s, mode `0400`, inside sops-nix's
  `root:keys` directory, and jesse is in neither `agent-broker` nor `keys`. A
  NixOS assertion keeps every user but `agent-broker` out of both groups.
- The encrypted file and the host key are root's, in `0700` directories.
- jesse can't `ptrace` or read the environment of `agent-broker`'s processes.
- `secret` needs jesse's sudo password.
- Your recovery key isn't on the host. If you ever put it on disk as jesse,
  any host agent can read it and decrypt every backup, so keep it in your
  password manager and use it only through a root-only file on `/run`, as in
  the restore steps.

This holds only against agents that can't become root. Some things give jesse
root, and through it everything above, so none of this isolates the secrets
from an adversarial agent on the host that uses them:

- **The `docker` group.** It is root-equivalent (`docker run -v /:/host`),
  and you chose to keep it. Any agent on the host as jesse can use it.
- **jesse's passwordless sudo for `nixos-rebuild` and `switch-to-configuration`.**
  Activating a configuration runs arbitrary code as root.
- **jesse's sudo password**, for anyone who has it.

Broker services also must not log values: jesse can read the system journal.

## Candidates to move here

These secrets are readable by jesse today, so host agents can read them. None
has been moved yet. Agents use them, so each moves as a broker secret.

| Secret | Today | Moving it |
| --- | --- | --- |
| Hugging Face token | `~/.config/local-models/hf-token`, read by the `local-models-sync` user service through `LoadCredential` | `secret add hf-token`, declare it with `inject.hosts = [ "huggingface.co" ]` and let the sync's downloads go through the egress proxy, or run the sync as a broker service writing to the model store. Then delete the home copy and revoke the old token, which also leaked into old transcripts. |
| discord-context token | `~/.config/discord-context/token`, read by the `discord-context` user service through `LoadCredential` | Run the MCP server as an `agentBroker.services` unit reading `/run/secrets/discord-context-token`, keeping its loopback port. Then delete the home copy and reset the bot token. |
| Tohru's Anthropic API key | `~/.config/tohru/anthropic-key` or `ANTHROPIC_API_KEY` | Bind it to `api.anthropic.com` with `inject` (`header = "x-api-key"`, `format = "{}"`) and point Tohru's quick voice at the proxy, so Tohru holds a placeholder. Then rotate the key. |
| Tohru's Discord token | `~/.config/tohru/discord-token` | Same as the Anthropic key, bound to `discord.com`, if Tohru's Discord client can use a proxy; otherwise keep it until Tohru gains a broker socket. |
| last30days API keys | `~/.config/last30days/.env`, mounted into sandboxes when present | `inject` per API host, then stop mounting the `.env`. |

For each, add the value with `secret add`, declare it, switch and
`apply`, check the consumer works, then delete the old file and rotate the
credential, since its old value was readable by agents.
