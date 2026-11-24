# Nix commands

- Single-quote flake references in every `nix run`, `nix shell` or `nix build` command you suggest or write into a script, such as `nix run 'nixpkgs#dmidecode'`. zsh's extended globbing treats an unquoted `#` as a glob operator and fails with "no matches found".
