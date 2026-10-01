# Bootstrapping a host

## NixOS

A fresh install has no git and no flakes. Enable both for the session, then
clone the flake and switch to it:

```sh
nix-shell -p git
export NIX_CONFIG='experimental-features = nix-command flakes'
git clone https://github.com/malinoskj2/nix /home/jesse/nix
cd /home/jesse/nix
nixos-rebuild switch --sudo --flake .#<host>
```

`/home/jesse/nix` is the flake path [`nh`](https://github.com/nix-community/nh)
is configured with. `pi` has no `jesse` account, so clone it anywhere and pass
that checkout to nh explicitly: `nh os switch <path>`.

`--sudo` builds as your user, so `git` and `NIX_CONFIG` stay in effect, and
uses sudo only to activate. After the first switch, both are installed and
configured, and `nh os switch` applies the flake from the checkout.

For a new machine:

1. Add `hosts/<host>/configuration.nix`, with `networking.hostName` set to
   `<host>`.
2. Save the output of `nixos-generate-config --show-hardware-config` next to it
   as `hardware-configuration.nix`.
3. Add the host to the list in [`flake.nix`](../flake.nix).
4. If jesse logs in to it, import
   [`hosts/common/users/jesse`](../hosts/common/users/jesse).
5. If it gets Home Manager, also import
   [`hosts/common/users/jesse/interactive.nix`](../hosts/common/users/jesse/interactive.nix)
   and add `users/jesse/profiles/<host>.nix`. The profile is looked up by
   `networking.hostName`, so the file name must match it.
6. `git add` the new files.

### `media`

`media` has no checkout of this repository. It's deployed from another host,
which pushes the configuration to it:

```sh
nh os switch ~/nix -H media --target-host media --build-host media
```

`media` is the `~/.ssh/config` alias (jesse, port 2222). nh asks for jesse's
sudo password on `media`. Its containers aren't part of this configuration:
the private media-stack repository deploys them.

Skin Trader's existing containers are recovered by
`skin-trader-startup.service` after Docker and `/mnt/media3` are available. This
keeps the `nofail` data disk from leaving the application stopped when Docker
tries its restart policies before the disk mounts. The unit validates the
project and bind mounts, waits up to ten minutes for PostgreSQL health, then
starts the API and workers. Failed attempts retry without stopping PostgreSQL.
It creates no containers or data and does not change other Docker services.
The application repository's `deploy.sh` still builds and updates the containers.

Verify the boot recovery script locally with
`python3 hosts/media/test-skin-trader-startup.py`. After activating the host,
check `systemctl status skin-trader-startup.service` and
`systemctl show skin-trader-startup.service -p RequiresMountsFor -p After`.
If the disk failed to mount, restore it and start the service explicitly with
`sudo systemctl start skin-trader-startup.service`; a failed mount dependency
prevents the service from executing its own retry loop.

For a new install, install NixOS with SSH and jesse's key, then, before the
first deploy, create jesse's password hash. Accounts come only from the
config, so without this file jesse's password is locked and sudo stops
working:

```sh
sudo sh -c 'umask 077; mkpasswd -m yescrypt > /secret/jesse.passwd'
```

### `home`: Secure Boot

`home` boots through Limine with Secure Boot, and the Limine installer stops if
no sbctl keys exist. Before the first switch, follow the one-time setup at the
top of [`hosts/home/boot.nix`](../hosts/home/boot.nix). Its switch step is the
`nixos-rebuild switch` above, and until that switch installs sbctl, run it
through `nix-shell -p sbctl`.

### `home`: SSH into agent sandboxes

`~/.ssh/config` is hand-written, and Home Manager puts the `sandbox-*` host
entry for [`agent-sandbox`](../users/jesse/agent-sandbox.nix) in
`~/.ssh/config.d/`. Add this line to the top of `~/.ssh/config`, above any
`Host` block, so that the entry applies to every host:

```
Include config.d/*
```

Then `ssh sandbox-<name>` starts the `agent-sandbox@sandbox-<name>` user unit
and connects to its container.
