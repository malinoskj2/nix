# Nix Configuration

## External Dependencies

The following external dependencies are required to build the flake provided by this repository.

- my [dot files repository](https://github.com/malinoskj2/dot) must be present
  for the remaining shared shell and application dotfiles. The `home` Hyprland
  and Noctalia desktop configuration no longer reads from it.


## Hosts

The following hosts are managed by this configuration.

### home

My main desktop PC. A custom PC dualbooting Windows (gaming) and NixOS (everything else).

### katana

My Thinkpad x230. Don't use this much, but have it for when I need to be mobile. 

### pi

Used for network filesharing and any other service I want to be accessible to the devices on my network.


## Build

First build, from a clone of the repository:

```sh
sudo nixos-rebuild switch --impure --flake '.#$YOUR_HOST' # home, katana, pi, or media
```

After that, [nh](https://github.com/nix-community/nh) is installed and knows
where the flake lives. It picks the host from the hostname:

```sh
nh os switch --impure   # or: test, boot; add --ask to confirm the diff first
```
