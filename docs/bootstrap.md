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

### `home`: Secure Boot

`home` boots through Limine with Secure Boot, and the Limine installer stops if
no sbctl keys exist. Before the first switch, follow the one-time setup at the
top of [`hosts/home/boot.nix`](../hosts/home/boot.nix). Its switch step is the
`nixos-rebuild switch` above, and until that switch installs sbctl, run it
through `nix-shell -p sbctl`.

## macbook (Home Manager)

The Mac has no system configuration, only a standalone Home Manager profile.
Nix comes from the
[Determinate Nix installer](https://install.determinate.systems/), which owns
the daemon, `nix.conf` and garbage collection.

The profile describes an existing account. Check that `home.username` and
`home.homeDirectory` in
[`users/jesse/profiles/macbook.nix`](../users/jesse/profiles/macbook.nix)
match the machine:

```sh
id -un
dscl . -read "/Users/$(id -un)" NFSHomeDirectory
uname -m    # arm64
```

Build first, then switch with the `home-manager` from the Home Manager this
flake locks. `-b hm-bak` moves aside any existing dotfile Home Manager would
replace:

```sh
nix run --inputs-from . home-manager -- build --flake .#macbook
nix run --inputs-from . home-manager -- switch -b hm-bak --flake .#macbook
```

After the first switch, `home-manager` is on the `PATH`.
