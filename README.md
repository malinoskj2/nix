# Nix Configuration

## External Dependencies

No external dotfiles repository is required to evaluate this flake.


## Hosts

The following hosts are managed by this configuration.

### home

My main desktop PC. A custom PC dualbooting Windows (gaming) and NixOS (everything else).

### katana

My Thinkpad x230. Don't use this much, but have it for when I need to be mobile. 

### pi

Used for network filesharing and any other service I want to be accessible to the devices on my network.

### macbook

An Apple-silicon MacBook managed with nix-darwin and Home Manager. The
configuration deliberately leaves the existing account, hostname, macOS
defaults, system profiles, security settings, network configuration, and
unrelated Homebrew inventory alone. Nix installs Alacritty, Zed, Claude Code,
Codex, and the command-line package set; Home Manager manages their reviewed settings.
Homebrew installs only the explicitly declared Chrome, Chromium, and OBS casks.

## Build

First build, from a clone of the repository:

```sh
sudo nixos-rebuild switch --flake '.#$YOUR_HOST' # home, katana, pi, or media
```

After that, [nh](https://github.com/nix-community/nh) is installed and knows
where the flake lives. It picks the host from the hostname:

```sh
nh os switch   # or: test, boot; add --ask to confirm the diff first
```

## First MacBook build

Install [Determinate Nix](https://install.determinate.systems/) using its macOS
installer. Determinate owns Nix, its daemon, certificates, and garbage
collection; the Darwin configuration therefore intentionally sets
`nix.enable = false`.

Homebrew must also be installed before activation because nix-darwin uses the
existing `brew` command to install the declared GUI casks; nix-darwin's
Homebrew module does not install Homebrew itself.

Before building, verify the existing account and architecture:

```sh
id -un
dscl . -read "/Users/$(id -un)" NFSHomeDirectory UserShell UniqueID PrimaryGroupID
uname -m
```

The checked-in values are `jmalinosky`, `/Users/jmalinosky`, and
`aarch64-darwin`. If the first two differ, update the two local values at the
top of `hosts/macbook/configuration.nix`. Do not add UID, GID, groups, shell,
or other account fields.

Build and inspect both Home Manager and the complete system before activation:

```sh
mac_user="$(id -un)"
nix build ".#darwinConfigurations.macbook.config.home-manager.users.${mac_user}.home.activationPackage"
nix build '.#darwinConfigurations.macbook.system'
```

Review the generated Home Manager targets against the existing dotfiles and
make a private backup. For the first activation, keep another terminal open
and run the release-matched nix-darwin tool explicitly:

```sh
sudo nix run 'github:nix-darwin/nix-darwin/nix-darwin-26.05#darwin-rebuild' -- \
  switch --flake '.#macbook'
```

Do not activate if the build proposes account, hostname, system profile,
security, network, or unrelated Homebrew changes.
