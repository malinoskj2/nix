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

## macbook (nix-darwin)

Nix on the Mac comes from the
[Determinate Nix installer](https://install.determinate.systems/), which owns
the daemon, `nix.conf` and garbage collection. That's why the host sets
`nix.enable = false`. Install Homebrew separately too: nix-darwin drives
`brew` for the declared casks but doesn't install it.

The host describes an existing account and doesn't create one. Check that
`username` at the top of
[`hosts/macbook/configuration.nix`](../hosts/macbook/configuration.nix) and the
home directory the host derives from it, `/Users/<username>`, match the
machine:

```sh
id -un
dscl . -read "/Users/$(id -un)" NFSHomeDirectory
uname -m    # arm64
```

If the name differs, change only `username`; the home path follows from it.
Don't add a UID, GID, groups or shell.

Build first, then check what activation would change:

```sh
nix run --inputs-from . nix-darwin#darwin-rebuild -- build --flake .#macbook
nix run nixpkgs#nvd -- diff /run/current-system result   # skip on first run
grep -nE 'dscl|scutil|systemsetup|networksetup|brew' result/activate
```

Stop if `result/activate` changes accounts, the hostname, system profiles,
security or network settings, or Homebrew packages that aren't declared here.
Otherwise, keep a second terminal open and switch with the `darwin-rebuild`
from the `nix-darwin` this flake locks:

```sh
sudo nix run --inputs-from . nix-darwin#darwin-rebuild -- switch --flake .#macbook
```
