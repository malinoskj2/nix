# Agent Sandbox Credential-Proxy & Secretless Auth Plan

## 1. Goal & Threat Model

Move every credential currently accessible inside `agent-sandbox` containers onto the host, behind host-side proxies that inject authentication on the fly and enforce destination/operation policy.

### Security properties

- **Prevents:**
  - **Raw secret exfiltration:** prompt injection, malicious build scripts/dependencies, accidental logs, or `cat`/`env` dumps inside a container can never read real API keys, OAuth refresh tokens, GitHub tokens, or SSH private keys.
  - **Post-session persistence:** stopping a container or revoking its session token leaves zero reusable credentials behind.
  - **Unbounded lateral movement:** every outbound credential use is bound to an explicit host allowlist and (where protocol-aware) an explicit repo/path/method/command policy enforced outside the container—not merely harness-level prompt rules that `curl`, Python, or `--dangerously-bypass-approvals-and-sandbox` can skip.
  - **Cross-tool credential bleed:** a container running Codex cannot read Claude's or `last30days`'s secrets, and a sentinel token for one provider is never substituted on another provider's host.
- **Does not prevent (by itself):**
  - **In-session capability abuse (confused deputy):** if a proxy allows `POST` to an endpoint or `git push` to a repo, a compromised agent can invoke that allowed capability while alive. Mitigation: narrow scopes, method/path/command allowlists, and host-side confirmation gates on destructive/mutating operations.
  - **Data exfiltration of mounted workspaces** (`~/projects`, `~/nix`, `~/orca/workspaces`) over arbitrary internet hosts unless paired with Phase 5 egress restrictions.

### Alignment with existing repository patterns

This repository already follows host-side boundary isolation for several subsystems:
- `users/jesse/features/local-models.nix`: keeps `hf-token` strictly on the host via systemd `LoadCredential` (`local-models-sync.service`), never mounted in the sandbox.
- `users/jesse/features/discord-context.nix`: runs a hardened host systemd user service (`LoadCredential`, `ProtectHome = "tmpfs"`, `NoNewPrivileges = true`) enforcing guild/channel policy on the host.
- `pkgs/agent-sandbox/hook-proxy.py` & `agent-sandbox-exec.sh`: exposes a private host Unix socket into the container and inspects/rewrites HTTP traffic on the host.
- `hosts/common/optional/resource-scheduler.nix`: keeps Munge/Slurm credentials on the host and exposes a read-only bind-mounted socket directory (`/run/resource-scheduler`) so container reconnects survive daemon restarts.

The auth gateway extends this exact model to every remaining credentialed surface in `agent-sandbox`.

---

## 2. Current Auth & Secret Inventory in `agent-sandbox`

Audited from `pkgs/agent-sandbox/agent-sandbox.sh`, `agent-sandbox-clean.sh`, `agent-sandbox-exec.sh`, `agent-sandbox-codex-server.sh`, `package.nix`, `users/jesse/git.nix`, and `users/jesse/features/`.

| Surface | Current mechanism in sandbox | Secret exposure today | Target mechanism |
|---|---|---|---|
| **`last30days` API keys** | `mount_readonly "$HOME/.config/last30days/.env"` (`agent-sandbox.sh:453`) | **High** — raw multi-provider `.env` readable by any process | Synthetic placeholder `.env` + selective HTTPS egress proxy |
| **Claude Code** | `~/.claude/.credentials.json`, `.claude.json` in `$sandbox_home`; Chat forwards `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK` & writable `CLAUDE_CONFIG_DIR` (`agent-sandbox.sh:400-409,464-476`) | **High** — live API/OAuth tokens inside container | Reverse proxy (`ANTHROPIC_BASE_URL`) + host-managed OAuth token broker; separate credentials from transcript dirs |
| **Codex (OpenAI)** | `copy_if_newer ~/.codex/auth.json` into `$sandbox_home` (`agent-sandbox.sh:133`); shared `agent-sandbox-codex-server` mounts `$sandbox_home`; Chat mounts writable `CODEX_HOME` | **High** — live OpenAI/ChatGPT tokens in container | Reverse proxy (`base_url` / `OPENAI_BASE_URL`) or selective HTTPS proxy + host OAuth refresh broker |
| **Antigravity (`agy`) / Gemini** | `copy_if_newer ~/.gemini/antigravity-cli/antigravity-oauth-token` (`agent-sandbox.sh:152`); `.gemini/oauth_creds.json` kept in `$sandbox_home` | **High** — live Google OAuth token in container | Selective HTTPS/HTTP2 proxy + host OAuth refresh broker (verify gRPC/TLS behavior per harness) |
| **OpenCode / ZCode** | `.local/share/opencode/auth.json`, `.zcode/cli/config.json` kept in `agent-sandbox-clean.sh:13-14` | **Medium/High** — provider API keys if logged in | Reverse/egress proxy with placeholder keys (`qwen-prompt` uses local `llama.cpp` and needs no cloud auth) |
| **Git HTTPS & `gh` CLI** | `gh` installed (`package.nix:330`), `git` uses `credential.helper = cache` (`git.nix:23`); any `gh auth login` or git push writes tokens into `$sandbox_home` | **High** — broad GitHub OAuth token if authenticated | Git credential helper + `GH_TOKEN` placeholder + host HTTPS proxy injecting fine-grained PAT / GitHub App token with repo/method policy |
| **Git SSH & Outbound SSH** | `openssh` installed; `.ssh` kept in `$sandbox_home` (`agent-sandbox-clean.sh:15`); host has SSH access to `media`, `pi`, `katana`, `mac-vm`, GitHub | **High** if keys placed in `$sandbox_home/.ssh`; **Unusable** cleanly without keys | Two-layer SSH: (1) filtered `ssh-agent` proxy with destination constraints + (2) terminating SSH bastion proxy for command/repo policy |
| **Git Commit Signing** | `git.nix:5-8` sets OpenPGP key `6E46C98F55BE7FF3`; `~/.gnupg` is not mounted | **Low** (currently unavailable in sandbox) | Optional `SSHSIG`-only key in filtered `ssh-agent` proxy (cannot be used for SSH login), or keep sandbox commits unsigned |
| **Orca Hook & CLI Tokens** | Env vars `ORCA_AGENT_HOOK_TOKEN`, `ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_AGENT_SESSION_SPAWN_TOKEN`, `ORCA_PAIRING_CODE` (`agent-sandbox.sh:388-392`); `mount_readonly ~/.config/orca` (`agent-sandbox.sh:456`) | **Medium** — hook token & any state files in `~/.config/orca` readable in container | Inject `ORCA_AGENT_HOOK_TOKEN` inside host `hook-proxy.py`; narrow `~/.config/orca` mount to runtime socket + non-secret metadata |
| **Package Registries (Cargo, npm, PyPI, GHCR)** | Ad-hoc tokens in `$sandbox_home` if ever used; Nix builds already use host `/nix/var/nix/daemon-socket` | **Medium** if logged in; Nix daemon already host-side | Egress proxy injection for private reads (incl. Nix flake GitHub fetches); block/approve publish (`PUT`/`POST`) |
| **Discord Context MCP** | Already host-side (`127.0.0.1:7781/mcp`, `LoadCredential`) | **None** (not currently bridged into container bridge network) | Bridge host `127.0.0.1:7781` into sandbox via bind-mounted Unix socket |
| **Local Models (HuggingFace)** | Already host-side (`local-models-sync.service`, `LoadCredential`) | **None** | Keep strictly host-side; no change needed |
| **SOPS / Age** | `sops` & `ssh-to-age` installed (`package.nix:402,404`); private keys not mounted | **None** | Keep private decryption keys strictly off the sandbox (public-key encryption only) |
| **Steam** | Saved login in `$sandbox_home/.local/share/Steam`, offline-by-default via `sandbox-steam` | **Low/Accepted** — proprietary binary CM protocol, isolated from host Steam | Documented exception; ensure HTTPS proxy passes `*.steampowered.com` through without MITM |
| **Chromium / Playwright / `tiktok-search`** | Isolated browser profile in `$sandbox_home`, wiped weekly | **Low/Accepted** — ephemeral sandbox-only cookies | Documented exception; never mount host Firefox/Chromium profiles |

---

## 3. Target Architecture

Run a single host-side user daemon (`agent-sandbox-authd`, or modular systemd user services under one package `pkgs/agent-sandbox-auth/`) that holds all real credentials via systemd `LoadCredential` and exposes **only Unix domain sockets** into containers—zero host TCP listeners for auth.

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Docker Container (agent-sandbox) — ZERO real credentials in env or disk      │
│                                                                              │
│  [Claude/Codex/agy]       [git / gh / last30days / nix]   [ssh / git-ssh]    │
│           │                            │                         │           │
│           ▼                            ▼                         ▼           │
│   127.0.0.1:18000              127.0.0.1:18001           SSH_AUTH_SOCK       │
│  (reverse proxy via           (HTTPS forward proxy       + ~/.ssh/config     │
│   socat -> unix sock)          via socat -> unix sock)   ProxyCommand -> sock│
│           │                            │                         │           │
└───────────┼────────────────────────────┼─────────────────────────┼───────────┘
            │ bind-mounted per-session socket dir (:ro dir / unix sockets)
            ▼ (/run/user/$UID/agent-sandbox-auth/<session-id>/)
┌──────────────────────────────────────────────────────────────────────────────┐
│ Host User Service: agent-sandbox-authd (hardened systemd user unit)          │
│  • Resolves container session -> (agent, repo, selected Orca account)        │
│  • Loads real secrets from LoadCredential / ~/.config/agent-sandbox-auth/    │
│                                                                              │
│  ┌────────────────────┐  ┌─────────────────────────┐  ┌───────────────────┐  │
│  │ HTTP Reverse Proxy │  │ Selective-MITM Forward  │  │ SSH Auth Layer    │  │
│  │ (no CA needed)     │  │ Proxy (CONNECT)         │  │ 1) Filtered Agent │  │
│  │ • Anthropic        │  │ • MITM ONLY allowlisted │  │    (dest-bound +  │  │
│  │ • OpenAI / Codex   │  │   credential hosts      │  │     SSHSIG-only)  │  │
│  │ • Local MCP bridge │  │ • Passthrough all other │  │ 2) Terminating    │  │
│  │   (discord-context)│  │   HTTPS (Steam, crates, │  │    SSH Bastion    │  │
│  │                    │  │   Nix, web browsing)    │  │    (cmd/repo ACL) │  │
│  └────────────────────┘  └─────────────────────────┘  └───────────────────┘  │
│                                      │                                       │
│             Policy Engine + OAuth Refresh Manager + JSONL Audit Log          │
│                   + Optional Desktop Approval Prompt (Hyprland)              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Why per-session Unix sockets (just like `hook-proxy.py`)

`agent-sandbox-exec.sh` already creates a private per-launch socket directory under `/run/user/$UID/agent-sandbox-orca/session.XXXXXXXX`. Using the same pattern for `/run/user/$UID/agent-sandbox-auth/<session-id>/` (or registering a session token with a persistent daemon via an admin control socket at launch time):
- Eliminates any need for a host TCP port (nothing on `127.0.0.1` or LAN for other processes or containers to hit).
- Binds every request cryptographically/structurally to **which container made it**:
  - Agent type (`claude`, `codex`, `antigravity`, `codex-server`) — a Codex container cannot access Claude's account or vice versa.
  - Repository identity (derived from `git rev-parse --git-common-dir`, already computed in `agent-sandbox-exec.sh:27`) — enables repo-scoped Git/GitHub write policies (e.g. allow pushing only to the active repo's non-default branches).
  - Orca Chat selected account (from `CODEX_HOME` / `CLAUDE_CONFIG_DIR` at launch) — preserves multi-account Chat support.
- Survives daemon restarts if the daemon binds sockets inside a mounted directory (or uses a persistent daemon directory + per-session bearer/proxy auth header).

### In-container loopback bridge & CA trust

1. **Loopback bridge for HTTP(S) proxies:** Many runtimes (Node.js, Python `urllib`/`requests`, Go, Rust `reqwest`, `gh`) expect `http://127.0.0.1:<port>` in `HTTP_PROXY`/`HTTPS_PROXY` and `*_BASE_URL`, not `unix://`. `entrypoint.sh` already runs `socat` (`entrypoint.sh:53`); start two lightweight loopback bridges in `entrypoint.sh`:
   - `127.0.0.1:18000` -> `/run/agent-sandbox-auth/reverse.sock`
   - `127.0.0.1:18001` -> `/run/agent-sandbox-auth/forward.sock`
2. **Selective MITM CA trust (only for hosts needing header substitution on hardcoded URLs):**
   - Generate a **host-local root CA** once on the host (`~/.local/share/agent-sandbox/auth-proxy/ca/ca.key` mode `0600` host-only, `ca.crt` public cert). Never commit it, never put it in the Nix store, and never mount `ca.key` into any container.
   - Build a combined bundle (`cacert` + `ca.crt`) on the host at launcher startup and bind-mount it read-only over:
     - `/etc/ssl/certs/ca-bundle.crt`
     - `/etc/ssl/certs/ca-certificates.crt`
   - Set env vars in the container:
     - `SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt`
     - `NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt`
     - `NODE_EXTRA_CA_CERTS=/run/agent-sandbox-auth/ca.crt`
     - `REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt`
     - `CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt`
   - **Critical rule — selective MITM only:** On `CONNECT host:443`, the forward proxy **only terminates TLS for hosts in its configured `mitm_hosts` allowlist** (the specific API domains where secret substitution or path policy applies). Every other host (`*.steampowered.com`, `cache.nixos.org`, `crates.io` downloads, arbitrary websites) is spliced straight through as opaque TCP. This avoids breaking certificate-pinned apps (Steam, Chromium) and eliminates overhead on bulk downloads.

---

## 4. Per-Surface Design Details

### 4.1 `last30days` & Research Helper API Keys (Quickest Win)

- **Remove** `mount_readonly "$HOME/.config/last30days/.env"` from `agent-sandbox.sh:453`.
- **Replace** with a launcher-generated synthetic `.env` (mounted read-only at `$HOME/.config/last30days/.env`) containing the exact same key names mapped to non-secret sentinel values, e.g.:
  ```dotenv
  OPENAI_API_KEY=sbx_placeholder_last30days_openai
  XAI_API_KEY=sbx_placeholder_last30days_xai
  SCRAPECREATORS_API_KEY=sbx_placeholder_last30days_scrapecreators
  YOUTUBE_API_KEY=sbx_placeholder_last30days_youtube
  ```
- **Host proxy rule:** For each sentinel, declare the exact allowed `(host, header_or_query_param, allowed_methods)` tuple. If a sentinel appears in a request to any non-allowlisted host, **refuse and log a security alert** (never substitute).
- **Zero changes required** inside `pkgs/last30days`.

### 4.2 Git, GitHub CLI (`gh`), and GitHub Operations

Handle GitHub through the HTTP proxy (simplest and richest policy surface) and optionally also through the SSH bastion for repos configured with `git@github.com:` remotes.

1. **HTTPS path (recommended default for GitHub):**
   - Configure inside the sandbox (`/etc/gitconfig` or generated `~/.config/git/sandbox-auth`):
     ```ini
     [url "https://github.com/"]
         insteadOf = git@github.com:
         insteadOf = ssh://git@github.com/
     [credential "https://github.com"]
         helper = /usr/bin/agent-sandbox-git-credential
     ```
   - `agent-sandbox-git-credential` outputs `username=x-access-token` and `password=sbx_placeholder_github`.
   - Set `GH_TOKEN=sbx_placeholder_github` in the container environment (so `gh pr`, `gh issue`, `gh api` work automatically with no `~/.config/gh/hosts.yml`).
   - Host proxy substitutes the placeholder **only** on `github.com`, `api.github.com`, and `uploads.github.com` with a **host-held fine-grained PAT or short-lived GitHub App installation token** (preferred: auto-minted 1-hour installation tokens scoped to selected repos).
2. **Host-enforced Git/GitHub policy (unbypassable by any harness or script):**
   - **Reads:** allow `git-upload-pack` (`fetch`/`clone`/`pull`) and `GET` on `api.github.com` for allowlisted orgs/repos.
   - **Writes:**
     - Inspect `git-receive-pack` pkt-line ref updates on the host proxy (or reject non-fast-forward / protected-branch pushes like `refs/heads/main`, `refs/heads/master`, `refs/tags/*`, or ref deletions `0000000...`).
     - Optionally require host approval for any `git-receive-pack` (replacing the bypassable harness-level `ask = [ "Bash(git push:*)" ]` with a real boundary).
     - On `api.github.com`: allow PR/issue comments and draft PR creation on allowlisted repos; deny `DELETE /repos/*`, branch protection mutations, secret/deploy-key mutations, and `.github/workflows/` pushes unless explicitly approved.
3. **Git commit signing (`users/jesse/git.nix`):**
   - Never mount `~/.gnupg`.
   - Two clean choices:
     - **Option A (recommended if signed commits are wanted):** Switch sandbox git config to `gpg.format = ssh` with a dedicated **signing-only Ed25519 key** held in the host filtered `ssh-agent` proxy, restricted strictly to the `SSHSIG` protocol with namespace `git` (it refuses every SSH server login challenge). Add that public key to GitHub as a Signing Key (not an Authentication Key).
     - **Option B (simplest):** Set `commit.gpgsign = false` inside the sandbox and sign on the host during review / `/recommit`.

### 4.3 Outbound SSH (Git Remotes, NixOS Fleet `media`/`pi`/`katana`/`mac-vm`, Remote Builders)

Use **two complementary host-side SSH proxies**, both mounted into the container as Unix sockets under `/run/agent-sandbox-auth/` (no TCP ports, no private keys ever inside `$sandbox_home/.ssh`).

#### Layer 1: Filtered `ssh-agent` proxy (`ssh-agent.sock` -> `SSH_AUTH_SOCK`)
- Never mount the host's real `$SSH_AUTH_SOCK` (`programs.ssh.startAgent = true`).
- The host daemon implements the OpenSSH agent protocol (`SSH_AGENTC_REQUEST_IDENTITIES`, `SSH_AGENTC_SIGN_REQUEST`, `SSH_AGENTC_EXTENSION` for `session-bind@openssh.com`):
  - **Key isolation:** Exposes only explicitly configured sandbox keys (or a narrow subset of host keys)—never your master personal key by default.
  - **Destination constraints:** Requires OpenSSH `session-bind@openssh.com` (supported by the sandbox's `openssh`) and verifies the target server's **pinned host public key** + username against policy before signing. A compromised container cannot trick the agent into signing a challenge for an unauthorized host.
  - **Purpose separation:** Separate keys (and strict request-blob parsing) for `SSHSIG` (`git` commit signing) vs. SSH userauth (`SSH_MSG_USERAUTH_REQUEST`).
  - **Audit & approval:** Logs `(session_id, container, key_fp, target_host, target_user, decision)` on every sign request; sensitive hosts can block pending host approval.

#### Layer 2: Terminating SSH bastion proxy (`ssh-bastion.sock`)
An `ssh-agent` proxy controls *where* you can authenticate, not *what commands* you run after login. For fine-grained command/repo control, configure sandbox `~/.ssh/config` to route hosts through the terminating bastion:

```sshconfig
Host github.com
  ProxyCommand socat - UNIX-CONNECT:/run/agent-sandbox-auth/ssh-bastion.sock
  User git
  IdentityFile /dev/null
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile /run/agent-sandbox-auth/bastion_known_hosts

Host media pi katana mac-vm
  ProxyCommand socat - UNIX-CONNECT:/run/agent-sandbox-auth/ssh-bastion.sock
  IdentityFile /dev/null
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile /run/agent-sandbox-auth/bastion_known_hosts
```

- Inside the container, `ssh` authenticates to the local bastion (over the private per-session Unix socket, using a throwaway per-session key or socket peer identity—zero real credentials).
- The host bastion terminates the inner SSH session, parses the target host/user and requested channel/exec/subsystem, enforces policy, and opens the real upstream SSH connection using host-held keys (or short-lived SSH certificates):
  - **For `git@github.com` (if SSH Git is preferred over HTTPS rewrite):**
    - Allow only `exec` channels matching `^git-(upload|receive)-pack '([^']+)'$`.
    - Deny PTY allocation, interactive shells, `sftp`, and all TCP/agent forwarding (`direct-tcpip`, `tcpip-forward`, `auth-agent-req`).
    - Enforce repo allowlist and (for `git-receive-pack`) inspect pkt-line ref updates before forwarding.
  - **For NixOS fleet hosts (`media`, `pi`, `katana`, `mac-vm`):**
    - Default **deny** unless explicitly enabled in policy per host.
    - **Read-only diagnostic profile** (e.g. `media`, `pi`): allow only non-interactive `exec` matching an explicit command allowlist (e.g. `journalctl`, `systemctl status`, `docker ps`, `docker logs`, `df`, `free`, `uname`)—no shell, no `sudo`, no port forwarding.
    - **Nix remote build / deploy profile** (e.g. `nh os switch --target-host` or Nix store copy): allow `nix-store --serve` / `nix-daemon --stdio`, or gate mutating deployments on explicit human approval (consistent with the existing `host-switch` rule!).
    - **Docker-over-SSH (`media-stack`)**: never grant unrestricted Docker socket SSH to sandboxes by default; require explicit opt-in or approval per session.

#### Layer 3: Server-side defense in depth on your own NixOS hosts
In `hosts/common/users/jesse/` (or per-host `hosts/media/`, `hosts/pi/`):
- Add a dedicated **sandbox SSH CA** (`services.openssh.settings.TrustedUserCAKeys`) or dedicated restricted authorized key with `restrict,command="..."` / `AuthorizedPrincipalsFile` so `agent-sandbox-authd` mints **5-minute SSH certificates** with narrow principals (e.g. `agent-diag`, `agent-nix-builder`) instead of holding a permanent unrestricted root-capable SSH key for fleet hosts.
- Even if a bug existed in the bastion's command parser, the target server itself enforces the restriction.

### 4.4 AI Harnesses & LLM Providers (Claude Code, Codex, Antigravity, OpenCode)

This is the most nuanced category because some harnesses use **API keys** while others use **OAuth subscription tokens** with client-side refresh/claim inspection.

#### Group A: API-key & Base-URL configurable flows (cleanest — no MITM needed)
- **Claude Code (API key / Bedrock / custom endpoint):**
  - Container env gets `ANTHROPIC_BASE_URL=http://127.0.0.1:18000/anthropic` and `ANTHROPIC_API_KEY=sbx_placeholder_anthropic`.
  - Host reverse proxy replaces `x-api-key` (or `Authorization: Bearer`) and forwards to `https://api.anthropic.com`.
  - Remove `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK` from `agent-sandbox.sh:403-404`; pass the selected profile ID to the host daemon instead.
- **Codex (API key mode):**
  - Configure `base_url = "http://127.0.0.1:18000/openai"` + `OPENAI_API_KEY=sbx_placeholder_openai`.
  - Host reverse proxy injects real `Authorization: Bearer` and forwards to `https://api.openai.com`.
- **OpenCode / ZCode (API key providers):**
  - Same reverse-proxy endpoints (`/anthropic`, `/openai`, `/google`, etc.) with placeholder keys.

#### Group B: OAuth subscription logins (Claude Max/Pro, Codex ChatGPT OAuth, Antigravity `agy`)
OAuth CLIs typically read a JSON/token file (`~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.gemini/antigravity-cli/antigravity-oauth-token`), check `expires_at` locally, sometimes decode non-secret JWT claims (email/account ID/plan), and send `Authorization: Bearer <access_token>` (plus occasional refresh POSTs to the OAuth token endpoint).

**Design:**
1. **Host-side OAuth Token Broker** inside `agent-sandbox-authd`:
   - Owns the real credential files on the host (never copied into `$sandbox_home`!).
   - Performs token refresh on the host before expiry and persists refreshed tokens back to the host store (solving the current `copy_if_newer` race between concurrent sandboxes too!).
2. **Synthetic credential file in the container:**
   - Launcher writes a tiny read-only synthetic file containing a **placeholder access token** (and, where a CLI parses JWT payload claims locally, a **unsigned/dummy JWT** with non-secret display claims + a far-future `exp` so the CLI doesn't constantly try to refresh, and **no refresh token**).
3. **Header substitution in the host proxy:**
   - On allowlisted provider API hosts (`api.anthropic.com`, `chatgpt.com` / `api.openai.com`, Google/Antigravity API endpoints), the proxy swaps the placeholder `Authorization: Bearer` (and any session cookie/header) for the live host-managed access token.
   - Requests to OAuth token/revocation endpoints from inside the container are either intercepted (returning a fresh synthetic token while the host refreshes the real one) or blocked.
4. **Orca Chat multi-account compatibility (`CODEX_HOME` / `CLAUDE_CONFIG_DIR`) & `agent-sandbox-codex-server`:**
   - Currently `agent-sandbox.sh:461-476` bind-mounts the entire `$CODEX_HOME` or `$CLAUDE_CONFIG_DIR` writable because Orca Chat stores *both* credentials (`auth.json` / `.credentials.json`) and transcripts/sessions in the same directory.
   - To keep Orca's **Continue in chat** and `Usage Insights` working without exposing real auth files:
     - Mount the account directory as today **and over-mount** the specific credential file (`$CODEX_HOME/auth.json` or `$CLAUDE_CONFIG_DIR/.credentials.json`) with a read-only bind of the launcher's synthetic credential file! (Docker bind mounts honor child mounts overriding parent mounts, just as `agent-sandbox.sh:73` already relies on.)
     - Register the real host account path with `agent-sandbox-authd` for that session so the proxy injects that exact account's token.
     - Route `agent-sandbox-codex-server.service` through the same proxy socket and over-mount its `$sandbox_home/.codex/auth.json` as well.
5. **Pragmatic rollout / fallback note for closed-source CLIs:**
   - Each OAuth harness (`claude`, `codex`, `agy`) must be tested individually for HTTP/2 / gRPC framing, custom TLS roots, or local JWT signature checks.
   - If a specific harness uses a custom TLS stack that ignores `SSL_CERT_FILE`/`NODE_EXTRA_CA_CERTS` or verifies JWT signatures client-side, keep a **documented per-harness fallback** during rollout: host broker writes **short-lived access-token-only** credentials (never the refresh token) into a tmpfs file until full proxying works for that harness.

### 4.5 Orca Desktop Hooks, Orca CLI, and Discord Context MCP

- **Orca hook token (`pkgs/agent-sandbox/hook-proxy.py`):**
  - Currently `ORCA_AGENT_HOOK_TOKEN` is passed into the container (`agent-sandbox.sh:389`) even though every hook request already passes through host-side `hook-proxy.py`!
  - Update `agent-sandbox-exec.sh` + `hook-proxy.py` so the container receives `ORCA_AGENT_HOOK_TOKEN=sbx_placeholder_orca_hook`, and `hook-proxy.py` replaces the placeholder in headers/body with the real host token before forwarding to `127.0.0.1:$ORCA_AGENT_HOOK_PORT`.
  - Audit `ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_AGENT_SESSION_SPAWN_TOKEN`, and `ORCA_PAIRING_CODE` to see which are truly needed inside the container vs. only used by host-side Orca tooling.
- **Orca runtime directory (`~/.config/orca`):**
  - Audit what files live under `~/.config/orca` (`agent-sandbox.sh:456`). If it contains account tokens or credentials alongside the CLI Unix socket, narrow the mount to only the socket and non-secret runtime metadata (or proxy the CLI socket).
- **Discord Context MCP (`users/jesse/features/discord-context.nix`):**
  - Already holds its Discord token strictly on the host via `LoadCredential`.
  - Expose `http://127.0.0.1:7781/mcp` into containers through the reverse proxy (`http://127.0.0.1:18000/mcp/discord-context` -> host `127.0.0.1:7781/mcp`) so sandboxed Claude/Codex can use read-only Discord context without `--network=host` and without any secret in the container.

### 4.6 Package Registries, Nix, and Cloud/Dev Tools

- **Nix (`nix` CLI + host `nix-daemon`):**
  - Builds and substituters already execute via `/nix/var/nix/daemon-socket` on the host.
  - For client-side flake fetches against private GitHub repos or rate-limited GitHub APIs, configure Nix inside the image (`etc/nix/nix.conf`) with `access-tokens = github.com=sbx_placeholder_github` and let the HTTPS forward proxy inject the real read-only GitHub token.
- **Cargo, npm, PyPI, Docker/GHCR:**
  - If/when private registries or publishing are needed: place placeholder tokens in container configs (`~/.cargo/credentials.toml`, `~/.npmrc`, `~/.docker/config.json`) and inject real tokens in the host proxy with **read-only by default** (`GET`/`HEAD` allowed; `PUT`/`POST`/`DELETE` publish calls denied or approval-gated).

---

## 5. Network Egress Hardening (Phased)

Placeholder substitution prevents **credential theft** even while outbound networking remains open, because the container never possesses real secrets. However, locking down network egress completes the story by preventing:
1. Direct access from containers to **host LAN services** (notably `hosts/home/configuration.nix:53` sets `networking.firewall.enable = false`, so default Docker bridge containers can reach host LAN ports, `media`, `pi`, and router interfaces directly).
2. Bypassing the proxy's audit logs or exfiltrating private repo code to arbitrary internet hosts.

### Phased network plan
- **Phases 1–4 (Drop-in, zero workflow breakage):** Keep Docker's existing network so VNC (`5900`/`5901`/`6080`), preview ports (`8080`–`8084`), and Steam continue working identically while migrating every credential behind the host proxies.
- **Phase 5 (Strict egress & LAN isolation):**
  - Put sandboxes on a dedicated Docker `--internal` network (no direct default route to internet or LAN!) **or** add explicit `nftables`/Docker `DOCKER-USER` rules blocking container egress to RFC1918/LAN/host-except-published-ports and forcing all internet HTTP/HTTPS/SSH through the host proxy Unix sockets.
  - **Keep previews & VNC working:** Docker `--publish` works with `DOCKER-USER` egress filtering (allowing `ESTABLISHED,RELATED` inbound replies to published preview/VNC ports while dropping new container-initiated connections to LAN/internet).
  - **Allowlist mode vs. audit mode:** Start in **proxy-mandatory + full audit logging** (all domains logged, credential injection only on allowlisted hosts), with an optional `--strict-egress` flag (or per-repo policy) that restricts outbound domains to an explicit allowlist (LLM APIs, GitHub, Nix/Cargo/npm/PyPI registries).

---

## 6. Secret Storage, Systemd Hardening & Audit/Approval UX

### Host secret storage
- Store raw credentials strictly on the host under `~/.config/agent-sandbox-auth/` (`0700` dir, `0600` files) or encrypted via `systemd-creds encrypt` (`LoadCredentialEncrypted=`).
- Never store secrets in `/home/jesse/nix`, `/nix/store`, or `$XDG_DATA_HOME/agent-sandbox/home/`.
- Clean up `agent-sandbox-clean.sh`: once a harness is migrated off in-sandbox credential files, remove its credential paths (`.claude/.credentials.json`, `.codex/auth.json`, `.gemini/antigravity-cli/antigravity-oauth-token`, `.gemini/oauth_creds.json`, `.ssh`) from the `keep=()` array and scrub existing copies from `$sandbox_home`.

### Systemd unit hardening (`users/jesse/agent-sandbox.nix`)
Follow the same hardening pattern as `discord-context.nix` and `local-models.nix`:
- `NoNewPrivileges = true`
- `PrivateTmp = true`
- `ProtectSystem = "strict"`
- `ProtectHome = "tmpfs"` (with `BindReadOnlyPaths` only for secret/config dirs or `LoadCredential`, and `BindPaths` for `%t/agent-sandbox-auth` and audit log dir)
- `UMask = "0077"`
- `RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ]`
- `X-SwitchMethod = "keep-old"` (matching `agent-sandbox@.service` and `local-models-sync.service` so switches don't kill active sandboxes mid-request)

### Audit logging & interactive host approvals
- **Audit log:** Append structured JSONL records to `~/.local/state/agent-sandbox-auth/audit.jsonl` (never mounted into containers) with: timestamp, container/session ID, agent harness, repo, protocol (`http-reverse`, `http-mitm`, `ssh-agent`, `ssh-bastion`), target host, method/path or SSH command, credential profile injected, and decision (`allow`/`deny`/`approved`/`rejected`).
- **Interactive approval gate (optional, for high-risk ops):**
  - For sensitive actions (`git push` / `git-receive-pack`, SSH to `media`/`pi`, registry publish), the host proxy can pause the request (with a configurable timeout, e.g. 60s) and trigger a host desktop prompt (via `notify-send`/Tohru action or a small `agent-sandbox-auth approve <id>` CLI / Orca notification).
  - Non-interactive/unattended runs fail closed cleanly with an explicit HTTP `403` / SSH denial message explaining why it was blocked.

---

## 7. Implementation Options & Recommendation

| Option | Pros | Cons |
|---|---|---|
| **Option A: Single custom Go binary (`pkgs/agent-sandbox-auth/`)** | Stdlib `net/http` + `crypto/tls` + `golang.org/x/crypto/ssh` (`agent` + `ssh` server/client) in one small static binary; trivial selective-MITM CONNECT proxy, native `ssh-agent` + `session-bind@openssh.com`, native terminating SSH bastion, and Git pkt-line parser; zero runtime dependencies; easy unit/integration tests | Requires writing & maintaining ~1,500–2,500 lines of Go (not currently the primary language in `pkgs/`) |
| **Option B: Single custom Rust binary (`pkgs/agent-sandbox-auth/`)** | Matches repo's Rust expertise (`cargo-nextest`, `rust-build-jesse`), strong type safety, low memory footprint (`hyper` + `rustls` + `russh`) | `russh` + custom MITM CONNECT + `ssh-agent` protocol ergonomics are slightly heavier to implement than Go's `x/crypto/ssh` |
| **Option C: Compose off-the-shelf tools** (`mitmproxy` or Envoy + `ssh-agent-filter` + `sshpiper` + custom scripts) | Fast prototype for Phase 1 | 3–4 separate daemons, harder to share per-session identity/policy/OAuth broker/audit logs, heavier RAM footprint (`mitmproxy` is Python + high memory) |

**Recommendation:** **Option A (Go)** or **Option B (Rust)** as a single local package `pkgs/agent-sandbox-auth/` (registered in `flake.nix`'s `exportedPackages`, wired in `users/jesse/agent-sandbox.nix`), starting with a minimal core (config loader + session registry + reverse/selective-MITM HTTP proxy + audit log), then adding the `ssh-agent` and SSH bastion listeners into the same binary so all protocols share one policy file, one session table, and one audit log.

### Declarative policy schema (Nix-generated JSON, secrets referenced by name only)

Policies live declaratively in Nix (`users/jesse/agent-sandbox.nix`), referencing secret *names* resolved by `LoadCredential`—never secret *values*:

```json
{
  "http": {
    "reverse": {
      "anthropic": { "upstream": "https://api.anthropic.com", "credential": "anthropic_api_key", "header": "x-api-key" },
      "discord_mcp": { "upstream": "http://127.0.0.1:7781", "auth": "none" }
    },
    "placeholders": [
      {
        "sentinel": "sbx_placeholder_last30days_xai",
        "credential": "last30days_xai",
        "allowed_hosts": ["api.x.ai"],
        "inject": { "header": "Authorization", "prefix": "Bearer " },
        "allowed_methods": ["GET", "POST"]
      },
      {
        "sentinel": "sbx_placeholder_github",
        "credential": "github_app_or_pat",
        "allowed_hosts": ["github.com", "api.github.com", "uploads.github.com"],
        "policy": "github-repo-scoped"
      }
    ]
  },
  "ssh_agent": {
    "keys": [
      { "name": "git-signing", "credential": "ssh_git_sign_key", "allow_sshsig_namespaces": ["git"], "allow_login": false },
      { "name": "fleet-diag", "credential": "ssh_fleet_diag_key", "destinations": ["jesse@media", "pi@pi"] }
    ]
  },
  "ssh_bastion": {
    "hosts": {
      "github.com": { "user": "git", "mode": "git-pack", "allow_push_branches": ["!main", "!master"] },
      "media": { "user": "jesse", "mode": "exec-allowlist", "commands": ["journalctl *", "systemctl status *", "docker ps*", "docker logs *"] }
    }
  }
}
```

---

## 8. Phased Rollout & Verification Plan

### Phase 1 — Foundation + Quickest Secret Removals (`last30days`, Orca Hook Token, Discord MCP)
- Build `pkgs/agent-sandbox-auth` core:
  - Per-session socket registration (`agent-sandbox.sh` / `agent-sandbox-exec.sh`).
  - Reverse proxy + selective-MITM forward proxy with host-generated local CA.
  - `entrypoint.sh` `socat` loopback bridges + combined CA bundle mount + `SSL_CERT_FILE`/`NODE_EXTRA_CA_CERTS`/`REQUESTS_CA_BUNDLE`.
  - JSONL audit log.
- Remove `mount_readonly "$HOME/.config/last30days/.env"` and switch to synthetic `.env` + placeholder substitution.
- Move `ORCA_AGENT_HOOK_TOKEN` injection into host `hook-proxy.py` (placeholder in container).
- Bridge `discord-context` MCP (`127.0.0.1:7781`) through the reverse proxy.
- **Verify:**
  - `last30days` works end-to-end inside a sandbox.
  - `cat ~/.config/last30days/.env` shows only placeholders.
  - `curl -H "Authorization: Bearer sbx_placeholder_last30days_xai" https://httpbin.org/headers` delivers only the placeholder (or is blocked + logged).
  - Steam and Chromium still work (non-MITM passthrough confirmed).
  - Orca hooks still report `SessionStart`/status with HTTP 204.

### Phase 2 — Git, `gh`, and GitHub Policy
- Add sandbox git config (`insteadOf` HTTPS rewrite + `agent-sandbox-git-credential` helper) and `GH_TOKEN` placeholder.
- Add GitHub credential injection (fine-grained PAT or GitHub App token minter) + `git-receive-pack` pkt-line policy (block force-push / `main` push / repo deletion).
- Add Nix `access-tokens` placeholder for private/rate-limited GitHub flake fetches.
- **Verify:**
  - `git fetch`, `git push` to a feature branch, and `gh pr view` work inside the sandbox.
  - `git push --force` and `git push origin HEAD:main` are rejected at the host proxy (even from raw `git` or `curl` under Codex `--dangerously-bypass-approvals-and-sandbox`).
  - `gh auth token` returns only the placeholder string.

### Phase 3 — Two-Layer Outbound SSH (Filtered `ssh-agent` + Terminating Bastion + Fleet Defense-in-Depth)
- Implement filtered `ssh-agent` listener (`SSH_AUTH_SOCK`) with `session-bind@openssh.com` destination constraints and `SSHSIG`-only git commit signing support.
- Implement terminating SSH bastion listener (`ssh-bastion.sock`) + sandbox `~/.ssh/config`.
- Add read-only diagnostic profiles (and optional SSH CA `TrustedUserCAKeys`) for `media`, `pi`, `katana`, `mac-vm`.
- Remove `.ssh` from `agent-sandbox-clean.sh`'s `keep` list (after migrating any sandbox-only keys to the host).
- **Verify:**
  - `ssh media 'systemctl status docker'` succeeds; `ssh media` (interactive shell), `ssh media 'rm -rf /tmp/x'`, and `ssh -L 8080:127.0.0.1:22 media` are rejected and logged.
  - Signing a git commit with the `SSHSIG`-only key succeeds; attempting to use that same key to SSH into any host is rejected by the agent proxy.
  - Attempting to forward a challenge from an unauthorized host fails `session-bind` verification.

### Phase 4 — AI Harness Auth (Claude Code, Codex, Antigravity, OpenCode)
- Migrate one harness at a time (recommended order: **Claude Code** -> **Codex + `agent-sandbox-codex-server`** -> **Antigravity (`agy`)**):
  1. Add host OAuth refresh broker + reverse/selective-MITM route for the harness.
  2. Over-mount credential files (`auth.json`, `.credentials.json`, `antigravity-oauth-token`) with synthetic read-only files while keeping writable transcript/config dirs intact for Orca Chat.
  3. Test interactive CLI, Orca terminal launch, Orca Chat (`CODEX_HOME` / `CLAUDE_CONFIG_DIR`), `codex-image`, and session resume / **Continue in chat**.
  4. Remove `copy_if_newer` and forwarded `ANTHROPIC_*` / `CLAUDE_CODE_OAUTH_TOKEN` env vars from `agent-sandbox.sh`, and prune kept credential files from `agent-sandbox-clean.sh`.
- **Verify:**
  - Zero real OAuth/API tokens anywhere in `env`, `/proc/*/environ`, or `$sandbox_home`.
  - Concurrent sandboxes refresh tokens cleanly without clobbering each other.
  - Orca Chat multi-account selection and **Continue in chat** still route to the right account.

### Phase 5 — Egress & Host-LAN Isolation + Optional Approval Gate
- Add container egress rules (`DOCKER-USER` / dedicated Docker bridge subnet) blocking direct container-initiated connections to host LAN / RFC1918 (`media`, `pi`, router, host services) while preserving published VNC/preview inbound replies.
- Force outbound HTTP/HTTPS/SSH through the host proxy sockets.
- Add optional desktop approval flow for mutating actions (`git push`, SSH deploy/diagnostic escalation, package publish).
- **Verify:**
  - Direct `curl http://<media-ip>` or `nc <host-lan-ip> <port>` from inside the container fails.
  - Preview URLs (`$AGENT_PREVIEW_URL_8080`) and noVNC (`$AGENT_SANDBOX_VNC_URL`) still open from host and LAN devices.
  - `nix flake check` passes and unit/integration tests cover every proxy policy path.

---

## 9. Decisions to Confirm Before Implementation

1. **Implementation language:** Single **Go** binary (fastest path for `x/crypto/ssh` agent + bastion + HTTP MITM) vs. **Rust** binary (matches repo preference).
2. **Git commit signing in sandboxes:** Enable `SSHSIG`-only signing via the filtered `ssh-agent` proxy, or leave sandbox commits unsigned and sign on the host?
3. **GitHub credential backend:** Fine-grained PAT on the host (simpler setup) vs. personal GitHub App minting 1-hour installation tokens (stronger least privilege)?
4. **Fleet SSH scope (`media`, `pi`, `katana`, `mac-vm`):** Which hosts should sandboxes be allowed to reach at all, and read-only diagnostics only vs. also Nix remote builds / deploys (with approval)?
5. **Phase 5 LAN isolation:** Confirm whether to add `DOCKER-USER` / firewall rules blocking container-to-LAN egress (while keeping `home`'s host-side preview/VNC publishing intact).
