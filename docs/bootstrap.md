# Bootstrapping a host

## NixOS

A fresh install has no git and no flakes. Enable both for the session, then
clone to `/home/jesse/nix`, the flake path
[`nh`](https://github.com/nix-community/nh) is configured with:

```sh
nix-shell -p git
export NIX_CONFIG='experimental-features = nix-command flakes'
git clone https://github.com/malinoskj2/nix /home/jesse/nix
cd /home/jesse/nix
nixos-rebuild switch --sudo --flake .#<host>
```

`--sudo` builds as your user, so `git` and `NIX_CONFIG` stay in effect, and
uses sudo only to activate. After the first switch, both are installed and
configured, and `nh os switch` applies the flake from that path. `pi` has no
`jesse` account, so there, pass the checkout explicitly:
`nh os switch <path>`.

For a new machine, add `hosts/<host>/` with the output of
`nixos-generate-config --show-hardware-config`, add the host to the list in
[`flake/hosts.nix`](../flake/hosts.nix), and, if it has Home Manager, give it
a profile under [`users/jesse/hosts/`](../users/jesse/hosts). Then `git add`
the new files.

### `home`: Secure Boot keys first

`home` boots through Limine with Secure Boot, and the Limine installer stops
if no sbctl keys exist yet. Create them before the first switch:

```sh
nix-shell -p sbctl --run 'sudo sbctl create-keys'
```

Enrolling the keys and turning Secure Boot on in firmware come after the
switch. Follow the steps at the top of
[`hosts/home/boot.nix`](../hosts/home/boot.nix).

## macbook (nix-darwin)

Nix on the Mac comes from the
[Determinate Nix installer](https://install.determinate.systems/), which owns
the daemon, `nix.conf` and garbage collection. That's why the host sets
`nix.enable = false`. Install Homebrew separately too: nix-darwin drives
`brew` for the declared casks but doesn't install it.

The host describes an existing account and doesn't create one. Check that the
username and home directory at the top of
[`hosts/macbook/configuration.nix`](../hosts/macbook/configuration.nix) match
the machine:

```sh
id -un
dscl . -read "/Users/$(id -un)" NFSHomeDirectory
uname -m    # arm64
```

If they differ, change those two values only. Don't add a UID, GID, groups or
shell.

Build first, then check what activation would change:

```sh
nix run --inputs-from . nix-darwin#darwin-rebuild -- build --flake .#macbook
nix run nixpkgs#nvd -- diff /run/current-system result   # skip on the first activation
grep -nE 'dscl|scutil|systemsetup|networksetup|brew' result/activate
```

Stop if `result/activate` changes accounts, the hostname, system profiles,
security or network settings, or Homebrew packages that aren't declared here.
Otherwise, keep a second terminal open and switch with the `darwin-rebuild`
from the `nix-darwin` this flake locks:

```sh
sudo nix run --inputs-from . nix-darwin#darwin-rebuild -- switch --flake .#macbook
```
