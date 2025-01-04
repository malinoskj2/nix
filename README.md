# Nix Configuration

## External Dependencies

The following external dependencies are required to build the flake provided by this repository.

- `/secret/secrets.nix` must exist with correct schema. See [example](secrets.nix.example).
- my [dot files repository](https://github.com/malinoskj2/dot) must be present on the system
- `/secret/fonts` directory must exist with required fonts


## Hosts

The following hosts are managed by this configuration.

### home

My main desktop PC. A custom PC dualbooting Windows (gaming) and NixOS (everything else).

### katana

My Thinkpad x230. Don't use this much, but have it for when I need to be mobile. 

### pi

Used for network filesharing and any other service I want to be accessible to the devices on my network.


## Build

1. Clone the repository
2. `cd` into the repository

```sh
sudo nixos-rebuild switch --impure --flake '.#$YOUR_HOST' # home, katana, or pi
```
