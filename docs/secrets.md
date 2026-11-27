# Secrets

All of a host's secrets live in one
[sops](https://github.com/getsops/sops)-encrypted file, decrypted by
[sops-nix](https://github.com/Mic92/sops-nix) into `/run/secrets` once jesse
logs in (see [Locked and unlocked](#locked-and-unlocked)). Each
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
| Host decryption key, wrapped | `/var/lib/sops-nix/key.sealed` | root, `0600`, directory `0700` |
| Host decryption key, while unlocked | `/run/secrets-key/key.txt` (ramfs) | root, `0600`, directory `0700` |
| Decrypted values | `/run/secrets/<name>` (ramfs, never on disk) | broker: `agent-broker`, `0400`; host: as declared |
| Broker sockets | `/run/agent-broker/<service>/` | `agent-broker:agent-broker-clients`, `2750` |
| Your recovery key | offline, in your password manager | you |

Each file is encrypted to two age keys:

- **The host key**, a dedicated age key that only root can read. `home` runs
  no SSH server, so it has no SSH host key to reuse. A dedicated key also
  keeps decryption separate from SSH identity, so rotating either one doesn't
  touch the other. At rest it is wrapped twice: with jesse's login password
  (scrypt and ChaCha20-Poly1305), then sealed with `systemd-creds` to this
  machine's TPM and its host credential secret. Unwrapping it needs both the
  password and this machine, so a copy of the disk or of the file alone is
  useless. See [Locked and unlocked](#locked-and-unlocked).
- **Your recovery key**, a personal age key with its own passphrase that
  never needs to be on the host. Day-to-day editing on the host decrypts with
  the host key, through `sudo`. You only need the recovery key to restore a
  backup onto a new or rebuilt machine, or to replace a host key nobody can
  unwrap any more.

## One-time setup on a host

1. On a trusted machine, create your recovery key and note its public half:

   ```sh
   nix shell 'nixpkgs#age' -c age-keygen
   ```

   It prints a `# public key: age1…` line and an `AGE-SECRET-KEY-1…` line.
   Save the whole output in your password manager under its own passphrase,
   and don't leave it on disk anywhere agents run. Skip this step if you
   already have one: one recovery key covers every host.

2. On the host, after switching to a configuration that imports the module,
   create the host key and `.sops.yaml`:

   ```sh
   secret init age1…your-recovery-public-key…
   ```

   It asks for your sudo password, then for jesse's login password twice.
   It creates the host key, wraps it into `/var/lib/sops-nix/key.sealed`,
   leaves it unlocked until the next reboot, and prints the host's public key.
   The host needs a working TPM (`systemd-creds has-tpm2` reports `yes`); the
   key is always sealed to it. If it reports anything else, stop: that is an
   unmet requirement for the owner to resolve, not something to work around.

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

### Moving a plain host key to a wrapped one

A host set up before login unlock has its host key unwrapped in
`/var/lib/sops-nix/key.txt`. Switching it to a configuration with
`secrets.unlock.enable` fails closed: the switch succeeds, but the store now
looks for the key in `/run/secrets-key`, finds none, and withdraws every
secret and stops every consumer until the key is wrapped. The plain key is
left where it is. `secret list` says so. Then:

```sh
secret migrate   # asks for jesse's login password twice
```

It checks that the plain key is the host recipient in `.sops.yaml` (the
first one, never the recovery key) and decrypts the file. It then wraps that
same key with the login password and the TPM and makes the wrap durable on
disk. Only after that does it unlock with the key, check it still decrypts the
file, delete the plain copy and deploy. A wrong password or any failed check
leaves the plain key in place and the secrets withdrawn.

If it is interrupted after the wrap is written, `secret list` keeps warning
while the plain key exists. Run `secret migrate` again: it asks for the
password once, checks that the existing wrap holds exactly the plain key, then
finishes. A wrap of any other key is refused, and the plain key is kept. If
the interruption came while the plain copy was being overwritten, so it is no
longer a key, `secret migrate` instead unwraps the existing wrap with your
password, checks that it is this host's recipient and decrypts the file, and
only then removes what's left of the plain copy. The key itself doesn't
change, so `.sops.yaml`, the file and its backups stay as they are. Deleting
the plain copy can't scrub it from the disk or its snapshots; if that matters,
replace the key with `secret reset-key` afterwards.

## Locked and unlocked

The secrets are locked whenever the unwrapped host key isn't in memory:

- **At boot** nothing is deployed. Every consumer, host or broker, stays
  stopped, and switches still succeed.
- **At login** on the Tohru greeter (greetd) or a text console (`login`),
  unlocking takes two PAM steps. While you authenticate, a hook reads the
  password you typed and unwraps the key into a staging directory under
  `/run/secrets-key` that only root can read. Only when PAM has accepted the
  login, password and account checks both, and opens the session does a
  second hook move it into place and deploy the secrets; consumers start a
  moment later. A rejected login, such as an old password after a change, or
  a locked or expired account, never opens a session, so its staged key is
  discarded within a minute and nothing deploys. The greeter only preselects
  jesse, it never logs in on its own, so this happens only when you type the
  password. The hooks never affect whether the login succeeds or make it
  wait: any failure in them just leaves the secrets locked, they give up after
  30 seconds, and while a `secret` command is working on the key (say a
  `secret rewrap` that hasn't finished) the login skips unlocking rather than
  waiting for it. A `secret` command sitting at its password prompt doesn't
  hold the key, so it doesn't get in the way. They never log, store or pass on the
  password.
- **The screen locker, `sudo` and SSH** don't unlock. SSH logins use keys,
  with no password to unwrap with.
- **Logging out** keeps the secrets unlocked until the next reboot.
  `secret lock` locks them again by hand, withdrawing every secret.
- **After a crash or power loss** the key and every decrypted value, which
  live only in ramfs, are gone; the next login unlocks again.
- **From an SSH session or a console that's already logged in**,
  `secret unlock` asks for the password and does the same.

When you change jesse's password with `passwd`, a hook rewraps the key with
the new password, as long as the secrets are unlocked at the time and the new
password is confirmed in `/etc/shadow`; a change the shadow file refused
keeps the old wrap. The new wrap is written beside the old one, checked to
unwrap to the same key, and only then replaces it, so the key is never left
unwrapped on disk and a failure part-way keeps the old wrap. If the secrets
are locked at the time (say the password was changed as root before you
logged in), or rewrapping fails, the old wrap stays, logins with the new
password succeed but leave the secrets locked, and the journal
(`journalctl -t secret-unlock`) and `secret list` say a rewrap is pending.
Then:

```sh
secret rewrap   # asks for the old password if locked, then the new one twice
secret apply
```

If nobody knows the old password any more, or the TPM was reset or replaced,
replace the host key using the recovery key. `reset-key` first checks that the
recovery key decrypts the file, then builds the new key, its wrap, the new
`.sops.yaml` and the re-encrypted file in a staging directory on
`/run/secrets-key`, and checks the new key decrypts the result. Only then does
it move them into place, one file at a time, keeping the old wrap until the
last step. Those moves aren't a single atomic step, but the file stays
encrypted to the recovery key throughout, so if it is interrupted, run it
again. Keep the recovery key on `/run/secrets-key`, the root-only ramfs
that holds the host key, which is never swapped:

```sh
sudo install -m 600 /dev/stdin /run/secrets-key/recovery.txt   # paste, then Ctrl-D
secret reset-key --identity /run/secrets-key/recovery.txt     # asks for the login password
sudo rm /run/secrets-key/recovery.txt
```

## Day-to-day commands

Every `secret` command elevates with `sudo`, and those that read or change
values need the secrets unlocked. None of them prints a
value except `show`, which prints one, and `edit`, which opens the decrypted
file in `$EDITOR`.

```sh
secret list                            # names, kinds, in the file, deployed
secret add github-token                # prompts twice, without echo
secret add gh-app-key --file key.pem
printf %s "$value" | secret add name   # or read from stdin
secret rotate github-token
secret remove github-token
secret show github-token               # prints this value
secret edit                            # shows every value
secret apply                           # deploy the file's current values now
secret unlock                          # unlock without logging in again
secret lock                            # withdraw everything until the next unlock
secret rewrap                          # rewrap the host key with a new login password
```

Editing the encrypted file doesn't change the system configuration, so a
switch doesn't redeploy it. `secret apply` decrypts it into
`/run/secrets` straight away, restarts the services that use a changed
secret, and starts any that were waiting for one. Unlocking at login deploys
it too.

### Reading a value

`secret show <name>` prints one secret from the encrypted file, of either
kind, deployed or not, and prints exactly its bytes, so
`token=$(secret show github-token)` and pipes get the stored value. On a
terminal it adds a newline and warns on stderr that the value may stay in
your scrollback. It needs the secrets unlocked, reads nothing from
`/run/secrets` and writes nothing to disk.

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

### The Venice API key

`home` declares `secrets.host.venice-api-key` for jesse, and plain `opencode`
reads it from `/run/secrets/venice-api-key` for its Venice models. Until it is
deployed, OpenCode still starts, and Venice requests fail with `VENICE_API_KEY
is not set`. To add or replace it:

```sh
secret add venice-api-key      # or rotate, to replace it; prompts without echo
secret apply
```

Then pick a Venice model in OpenCode's `/models`. OpenCode reads the key when
it loads its config, so after adding or rotating it, run `opencode service
restart` and reopen any running OpenCode.

OpenCode in an agent sandbox never sees that key. It gets the host's
`~/.config/opencode` read-only, and the image's `/etc/opencode/opencode.json`,
which outranks it, swaps the key for a placeholder. The egress proxy replaces
the `Authorization` header on requests to `api.venice.ai` with a separate broker
secret, `agentBroker.secrets.venice-api-key-agent`, so the two keys can be
rotated and revoked separately. To add or replace it:

```sh
secret add venice-api-key-agent   # or rotate; prompts without echo
secret apply
```

Use a separate Venice key for it, so revoking the agents' key leaves yours
working. Until the egress proxy runs, sandboxed Venice requests go out with the
placeholder and Venice refuses them as unauthenticated; with the proxy running
but the secret missing, the proxy answers them itself with a missing-secret
error. Local Qwen through `qwen-opencode` and everything else keeps working
either way.

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
2. Put your recovery key in a root-only file on the `/run/secrets-key`
   ramfs, use it, then delete it:

   ```sh
   sudo install -m 600 /dev/stdin /run/secrets-key/recovery.txt   # paste, then Ctrl-D
   secret restore /mnt/media3/backups/secrets/secrets-home-….yaml \
     --identity /run/secrets-key/recovery.txt
   sudo rm /run/secrets-key/recovery.txt
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

To replace the host key, for example because it may have leaked, use
`secret reset-key` with your recovery key, as in
[Locked and unlocked](#locked-and-unlocked), then rotate the secrets it could
decrypt.

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
- The encrypted file and the wrapped and unwrapped host key are root's, in
  `0700` directories. The unwrapped key and decrypted values live on ramfs,
  which the kernel never swaps. `secret-unlock` locks its memory
  (`mlockall`) and clears its password and key buffers after use, but
  `secret`'s other commands run `sops` and `age`, which don't lock theirs,
  so a value they handle can reach swap if the host has it. `home` currently
  has a 32 GiB unencrypted `/swapfile`, so that gap is open there; whether to
  encrypt or drop it is Jesse's call. The password itself also passes through
  the greeter, `login` and PAM before the helper sees it, and none of those
  lock their memory, so nothing here keeps it out of swap end to end.
- jesse can't `ptrace` or read the environment of `agent-broker`'s processes.
- `secret` needs jesse's sudo password.
- Your recovery key isn't on the host. If you ever put it on disk as jesse,
  any host agent can read it and decrypt every backup, so keep it in your
  password manager and use it only through a root-only file on
  `/run/secrets-key`, as in the restore steps.

This holds only against agents that can't become root. Some things give jesse
root, and through it everything above, so none of this isolates the secrets
from an adversarial agent on the host that uses them:

- **The `docker` group.** It is root-equivalent (`docker run -v /:/host`),
  and you chose to keep it. Any agent on the host as jesse can use it.
- **jesse's passwordless sudo for `nixos-rebuild` and `switch-to-configuration`.**
  Activating a configuration runs arbitrary code as root.
- **jesse's sudo password**, for anyone who has it. It is also the login
  password that unwraps the host key, so it guards both; anything that can
  capture it as you type it, such as a malicious program in your desktop
  session, can unwrap the key on this machine.

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
