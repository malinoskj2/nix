{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  zcompdump = "${config.xdg.cacheHome}/zsh/zcompdump";
in
{
  programs = {
    bat.enable = true;

    zoxide = {
      enable = true;

      options = [
        "--cmd"
        "j"
      ];
    };

    zsh = {
      enable = true;
      autosuggestion.enable = true;
      defaultKeymap = "emacs";

      history = {
        path = "/tmp/.zsh_history";
        size = 1000;
        save = 1000;
        expireDuplicatesFirst = true;
        findNoDups = true;
        ignoreSpace = false;
      };

      # The order reaches .zshrc, so this list stays unsorted.
      setOptions = [
        "EXTENDED_GLOB"
        "HIST_REDUCE_BLANKS"
        "NO_BEEP"
        "NO_FLOW_CONTROL"
        "LOCAL_TRAPS"
        "BSD_ECHO"
      ];

      plugins = [
        {
          name = "zsh-claude-command";
          src = pkgs.zsh-claude-command;
          file = "share/zsh-claude-command/zsh-claude-command.plugin.zsh";
        }
      ];

      shellAliases = {
        cargorunbt = "RUST_BACKTRACE=1 cargo run";
        cargotestbt = "RUST_BACKTRACE=1 cargo test -- --nocapture";
        cargotestprint = "cargo test -- --nocapture";
        cat = "bat";
        cls = "clear";
        cmd = "type -m '*'";
        df = "df -H";
        dockerc = "docker compose";
        du = "du -sh";
        fd = "fd -H";
        ldate = ''date +"%I:%M %p"'';
        ll = "eza -llh";
        ls = "eza -1F";
        rgf = "rg --files --no-ignore --hidden -g";
        rgi = "rg -i";
        tree = "eza --long --tree --level=4";
      }
      // lib.optionalAttrs isLinux {
        lsblk = "lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT";
      };

      # Skip compinit's checks when a dump exists; activation deletes it on every switch.
      completionInit = ''
        autoload -Uz compinit
        if [[ -s ${zcompdump} ]]; then
          compinit -C -d ${zcompdump}
        else
          compinit -d ${zcompdump}
        fi
      '';

      initContent = ''
        zstyle ':completion:*' matcher-list "" 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'

        # Prompt for passphrases in the terminal even when a parent process (NixOS exports an empty
        # SSH_ASKPASS; editor terminals set GIT_ASKPASS) points ssh or git at a helper.
        unset SSH_ASKPASS
        unset GIT_ASKPASS

        bindkey -r "^S"
        bindkey "^A" clear-screen
        bindkey '^H' backward-char
        bindkey '^J' down-line-or-history
        bindkey '^K' up-line-or-history
        bindkey '^L' autosuggest-accept
      '';
    };
  };

  home.activation.zcompdump = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${dirOf zcompdump}
    run rm -f ${zcompdump} ${zcompdump}.zwc
  '';
}
