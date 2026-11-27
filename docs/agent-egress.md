# Agent sandbox egress

With `agentBroker.egress.enable`, agent sandboxes lose their direct route to
the network. Each one runs on an internal Docker network, and the only way out
is an HTTP proxy that `agent-broker` runs on the host. The proxy logs every
connection, applies an allowlist, and adds [broker secrets](secrets.md) to
requests for the hosts they are bound to, so a sandbox can use a credential
without ever holding it. Pushes to GitHub go through a separate push gateway
that holds a GitHub App key.

`home` enables it. Without the option the launcher keeps Docker's default
bridge and published ports, as before.

## How it works

- **Network.** Sandboxes join `agent-sandbox`, an internal Docker network on
  the bridge `br-asb`. Docker gives internal networks no route out, and the
  `agent-sandbox-netfilter` unit adds an nftables table (`inet agent_sandbox`)
  that drops anything from a `br-asb*` bridge to the host itself or to another
  interface. A sandbox can't reach host services through the bridge's gateway
  address either.
- **Proxy.** `agent-broker-egress-proxy` runs mitmdump on `127.0.0.1:3128`
  with the broker's addon. It decrypts TLS only for hosts that have a
  credential bound or are listed in `agentBroker.egress.inspect`; everything
  else passes through as an opaque tunnel, so sandboxes see the real
  certificates. Every decision is made on the address the proxy actually
  connects to: HTTPS has to come through `CONNECT`, a request's `Host` header
  has to name its connection's target (`421` otherwise), and on connections
  the proxy reads as TLS (web ports, and hosts it decrypts) the SNI has to
  match the `CONNECT` target; other ports pass as opaque TCP, unparsed. The
  proxy resolves each name once and connects to the address it checked. It
  refuses every address of the host itself (loopback, its LAN addresses,
  Docker bridge gateways, in any IPv4 or IPv6 spelling, including
  IPv4-mapped, IPv4-compatible, NAT64 and 6to4 forms) and link-local
  addresses such as cloud metadata in every mode, except a sandbox's own
  preview ports.
- **Gate.** `agent-broker-egress-gate` gives each sandbox its own Unix socket,
  `/run/agent-broker/egress-gate/sandbox/<name>/proxy.sock`, mounted in the
  sandbox at `/run/agent-egress`. The gate forwards each socket to the proxy
  from a loopback address of its own, and the proxy names the sandbox by that
  address. A process on the host that binds the same address isn't believed:
  the proxy also checks that the connection belongs to `agent-broker`. The
  launcher registers a sandbox when it starts and unregisters it when it
  exits; the gate also drops any whose launcher has died.
- **Inside the sandbox.** The entrypoint listens on `127.0.0.1:3128` and
  forwards to the socket. `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and their
  lowercase forms point there, with
  `NO_PROXY=localhost,127.0.0.1,::1,172.16.0.0/12`. The last is Docker's
  bridge pool, so siblings and stack services are reached directly on their
  internal networks; reach them by the address `sandbox-runner` prints, since
  a container name sent to the proxy doesn't resolve on the host. Clients
  that don't understand a CIDR range in `NO_PROXY` send those addresses to
  the proxy instead, which lets a sandbox reach the networks it is on (see
  [Private addresses](#private-addresses)); see [Runtimes](#runtimes) for
  which do.
  `/etc/ssh/ssh_config` sends SSH through the proxy with `socat`, so
  `ssh media` and `git@github.com:` keep working. DNS for outside names
  doesn't resolve in the sandbox, which is expected: clients hand the name to
  the proxy.
- **Certificates.** The proxy's CA is made on the host on first start and its
  key never leaves `/var/lib/agent-broker-egress`. Sandboxes get only the
  certificate, in `/run/agent-egress/ca.pem`, and a bundle of the system CAs
  plus that certificate in `/run/agent-egress/ca-bundle.crt`.
  `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`,
  `GIT_SSL_CAINFO`, `CARGO_HTTP_CAINFO`, `PIP_CERT` and `CODEX_CA_CERTIFICATE`
  name the bundle; `NODE_EXTRA_CA_CERTS` names the certificate, and
  `NODE_USE_ENV_PROXY=1` makes Node's `fetch` use the proxy. Chromium keeps
  its own trust store, which is fine because it only meets the broker's CA on
  hosts with a bound credential.
- **Ingress.** Published ports don't reach an internal network, so the
  launcher listens on the same host ports itself (VNC and noVNC on
  `127.0.0.1`, previews on every interface) and forwards each connection to a
  Unix socket the sandbox's entrypoint serves in `/run/agent-ingress`. VNC and
  preview URLs are unchanged. A sandbox reaching its own preview URL, or that
  of a disposable sandbox it started, goes through the proxy, which allows a
  sandbox those preview ports and no others on the host's addresses.
- **Browsers.** `sandbox-playwright` and the Playwright MCP pass the proxy to
  Chromium explicitly.
- **Media galleries.** `media-gallery` trusts the host hub's `hub.json` while
  the hub keeps refreshing it, instead of probing the hub's LAN address.
- **Disposable sandboxes** from `sandbox-runner` get the same network, their
  own gate socket and their own ingress forwarders. A sandbox behind the
  proxy can't start a `--steam` sibling.
- **The Codex image server** that `codex-image` uses runs on the same network
  behind its own gate socket. Its turns default to read-only without
  approvals; a client connecting to its socket could ask for more, which
  reaches no further than the sandbox it runs in, since the server shares
  the sandbox home and network.
- **Compose stacks** have every network made internal and named `br-asb-*`,
  so the nftables table covers them too. Image pulls are done by dockerd and
  still work; stack containers have no egress at runtime.

### Runtimes

Measured in a sandbox, fetching an outside host by name and a sibling's
`172.x` address:

| Client | Uses the proxy variables | `172.16.0.0/12` in `NO_PROXY` |
| --- | --- | --- |
| curl, Git, Nix, cargo, uv, pip | yes | honoured, goes direct |
| Go `net/http` (`ProxyFromEnvironment`) | yes | honoured |
| Python `requests` | yes | honoured |
| Python `urllib`, `httpx` | yes | ignored, sent to the proxy |
| Python `aiohttp` | only with `ClientSession(trust_env=True)`; otherwise DNS fails | ignored |
| Python `websockets` 15 and newer | yes | not checked |
| Node 24 `fetch`, `http`/`https` | only with `NODE_USE_ENV_PROXY=1`, which the sandbox sets | ignored |
| Deno 2 | yes | honoured |
| Bun 1.4 | yes | honoured |
| Chromium via `sandbox-playwright` | given the proxy explicitly, with `NO_PROXY` as its bypass list | honoured |

Clients that open raw sockets, `ws` and older `websockets` releases, gRPC
without `grpc_proxy`, and anything that resolves the name itself before
connecting fail with a DNS error for outside names. Give them the proxy
explicitly.

## The allowlist

`agentBroker.egress.mode` starts as `"log"`: everything is let through, and
each connection the allowlist wouldn't allow is logged as `would-deny`. In
`"enforce"` those connections are refused with `403`.

Entries in `agentBroker.egress.allow`:

| Entry | Matches |
| --- | --- |
| `github.com` | that host, ports 80 and 443 |
| `*.githubusercontent.com` | the domain and every subdomain, ports 80 and 443 |
| `media:2222` | that host and port (SSH and other non-web ports) |
| `example.com:*` | every port |

Hosts with a bound credential are always allowed.

### Building the list

1. Run in log mode for **3 weeks**, so at least two weekly sandbox-home wipes
   are covered: the week after a wipe shows the hosts that only cold caches
   reach (npm, uv, pip, Playwright browsers, harness updates). Extend it to
   **4 weeks** if no Steam or Unreal session happened in the window, since
   those reach hosts nothing else does.
2. Review what was seen:

   ```sh
   agent-egress report                  # host:port, requests, sandboxes, decisions
   agent-egress report --since '4 weeks ago'
   ```

3. Print a Nix list of everything not yet allowed. Domains with three or more
   subdomains in the log collapse to `*.domain` (`--wildcard-after N` changes
   that); raw IP addresses are left out for you to judge.

   ```sh
   agent-egress report --nix
   ```

4. Review the list, add it to `agentBroker.egress.allow` in
   `hosts/home/configuration.nix`, and switch. Keep watching
   `agent-egress report` for `would-deny` entries for a few more days.
5. Set `agentBroker.egress.mode = "enforce";` and switch. The proxy rereads
   its policy on the next connection, so a switch doesn't drop open
   connections.

### Allowing a host without a switch

```sh
agent-egress allow pypi.org --for 2h      # s, m, h, d or w
agent-egress allow example.com:8443 --forever
agent-egress revoke pypi.org
agent-egress status                       # mode, runtime entries, credentials
```

These need sudo and take effect on the next connection. Runtime entries live
in `/var/lib/agent-broker-egress/allow.json`; add anything you want to keep to
the Nix list.

### The log

`journalctl -u agent-broker-egress-proxy` holds JSON lines with the sandbox,
host, port and decision. A tunnel the proxy doesn't decrypt, the usual case,
gets a `CONNECT` line and a `close` line with its duration. A decrypted or
plain-HTTP request also gets the method, the path without its query, which
credential was added, the status and byte counts. Headers and bodies are
never logged. `agent-broker-egress-gate`'s journal records registrations and
Steam exceptions.

### Private addresses

The proxy refuses private, LAN and CGNAT destinations in every mode, log
included: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`
and `fc00::/7`. It decides on the address the name resolves to, checks every
address in the answer, and connects to the one it checked, so a name that
resolves to a LAN address is refused like the address itself. IPv6 forms
that carry an IPv4 address (mapped, compatible, 6to4, NAT64 `64:ff9b::/96`
and Teredo) are judged by that address. The host's own addresses, loopback
and link-local (`169.254.0.0/16`, including the cloud metadata address, and
`fe80::/10`) are refused outright and can't be listed. Refusals return `502`
and log `deny-private` or `deny-internal`.

Two things open a private address:

- **The sandbox's own networks.** The launcher and `sandbox-runner` register
  the subnets of the Docker network a sandbox is on, and `sandbox-runner`
  adds each Compose stack's networks (`br-asb-*`) for the sandbox that
  brought it up, dropping them when it comes down. The proxy lets that
  sandbox reach them. It could reach them directly anyway; this only covers
  clients that send them to the proxy despite `NO_PROXY`. Another sandbox's
  networks stay refused.
- **`agentBroker.egress.allowPrivate`**, which starts empty:

  | Entry | Matches |
  | --- | --- |
  | `media.lan:8096` | that name and port, or `*.domain:port`; the name's addresses may be private |
  | `192.168.1.5:2222` | that address and port |
  | `10.0.0.0/8:443` | every address in the range, on that port |
  | `[fd00::/8]:*` | an IPv6 range in brackets, every port |
  | `192.168.1.5` | no port: 80 and 443 |

  A listed destination is still subject to the allowlist and `mode`.

None of Phase 3's own paths needs an entry: a sandbox's preview URL is the
host's address, which the proxy allows a sandbox for its own preview ports;
ingress, VNC and the Orca relay come in through the launcher's sockets;
`media-gallery` reads the hub's `hub.json` instead of calling it; siblings
are on the sandbox's own network, and stacks on networks registered for it.

## Credential injection

Bind a broker secret to hosts with `inject`:

```nix
agentBroker.secrets.github-token.inject = {
  hosts = [ "api.github.com" ];
  header = "Authorization";   # default
  format = "Bearer {}";       # default; {} is the value
};
```

Add the value with `secret add github-token` and run `secret apply` (see
[secrets.md](secrets.md)). For a request to a bound host the proxy removes any
header of that name the sandbox sent and adds its own. Inside the sandbox the
tool needs no credential, or any placeholder it insists on.

- Bound hosts are always decrypted, and only HTTPS gets the header: a plain
  HTTP request to a bound host is refused.
- If the value isn't deployed, requests to the host get `503` with
  `{"error":"credential_unavailable"}` instead of going out without it.
- A rotated value is picked up on the next request, without a restart.
- Bind credentials only to APIs that never echo request headers back, since
  whatever the API returns, the sandbox reads.

## Steam sandboxes

`sandbox --steam` keeps Docker's default bridge, because Steam's client
honours proxy settings only partly. The launcher says so on stderr, and the
gate logs an `exception` record. Traffic from a Steam sandbox is neither
logged nor filtered.

## Push gateway

`agent-broker-push` pushes a sandbox's branch to GitHub with a short-lived
GitHub App token. In a sandbox:

```sh
sandbox-push              # the current branch, to origin's GitHub repository
sandbox-push feature-x --repo owner/name
```

The client bundles the commits GitHub doesn't have and sends them to
`/run/agent-push/push.sock`. The gateway:

- refuses repositories not in `agentBroker.push.repos`, the repository's
  default branch, `agentBroker.push.protectedBranches` (`main` and `master`),
  and always `main` of malinoskj2/nix;
- refuses anything that isn't a fast-forward; it never force-pushes;
- runs a Betterleaks scan over the new commits, merges included, and refuses
  if it finds anything, printing redacted findings; `gitleaks:allow` and
  `betterleaks:allow` comments are ignored;
- mints a token for that one repository with only `contents: write`, hands it
  to git through `GIT_ASKPASS`, and revokes it after the push.

Until it is set up, every push is refused with a message saying what is
missing. Every sandbox shares the gateway's socket, so its journal names the
pushing process's host pid rather than a sandbox.

### Setting it up

1. On GitHub, create a GitHub App under your account (Settings → Developer
   settings → GitHub Apps → New GitHub App). Turn off webhooks. Under
   repository permissions, set **Contents** to *Read and write*; leave
   everything else at *No access*.
2. Install it on your account, choosing only the repositories sandboxes may
   push to. Note the installation ID from the installation's URL
   (`…/settings/installations/<id>`) and the App ID from the App's page.
3. Generate a private key on the App's page and add it on the host:

   ```sh
   secret add github-app-key --file ~/Downloads/<app>.private-key.pem
   shred -u ~/Downloads/<app>.private-key.pem
   ```

4. In `hosts/home/configuration.nix`:

   ```nix
   agentBroker.push = {
     appId = 123456;
     installationId = 7890123;
     repos = [ "malinoskj2/nix" ];
   };
   ```

5. Switch, then run `secret apply`. Declaring `appId` declares the
   `github-app-key` broker secret, which is why the key is added first.
6. Check from a sandbox: `sandbox-push` on a test branch, then delete the
   branch on GitHub.
7. On each repository, add a ruleset that protects the default branch and
   doesn't list the App as a bypass actor, so GitHub refuses the App's pushes
   there even if the gateway were wrong.

To rotate the key, generate a new one on the App's page, `secret rotate
github-app-key --file <new key>`, `secret apply`, then delete the old key on GitHub.

## Turning it off

Set `agentBroker.egress.enable = false;` and switch. New sandboxes start on
the default bridge again, and the services and nftables table go away. The
`agent-sandbox` Docker network stays, since running sandboxes keep the
network they started with until they restart; remove it afterwards with
`docker network rm agent-sandbox`.

## What the proxy doesn't close

- **nix-daemon.** Sandboxes talk to the host's daemon, which fetches from
  substituters and builds fixed-output derivations on the host with full
  network access. A sandbox can ask it to fetch any URL, so this is an
  unfiltered path out. Closing it would take a separate daemon for sandboxes
  with `allowed-uris` and a fixed substituter list, refusing fixed-output
  builds, at the cost of `nix build` and `nix run` of anything not already
  cached.
- **BuildKit `RUN` steps** in `sandbox-runner compose` builds run on dockerd's
  network. `agentBroker.egress.buildNetwork` (on in log mode, off in enforce
  mode) decides whether they get one; when off, builds whose `RUN` steps need
  the network fail.
- **dockerd's own fetches.** Even with `buildNetwork` off, BuildKit fetches
  `ADD <url>` and `ADD <git repo>` sources, `# syntax=` frontends and
  `FROM` images, and Compose pulls `image:`, from the host's network, so a
  build can send data out in a URL and read the answer back in an image.
  Closing it would take pointing dockerd and BuildKit at the egress proxy
  with their own allowlist (registries only), or having the runner refuse
  Dockerfiles with URL sources or `# syntax=` lines and images from
  registries not on a list.
- **Allowed hosts.** Anything allowed can carry data out: gists, issue
  comments, package registries, pastebins. The allowlist limits where, not
  what.
- **Echoing APIs.** A bound credential is only as private as the API is
  reflective; see [Credential injection](#credential-injection).
- **Log mode.** Until the allowlist is enforced, every public address is
  reachable, and the log only records it.
- **Steam sandboxes**, which keep the bridge.
