{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
in
{
  programs = {
    zsh = {
      enable = true;
      autosuggestion.enable = true;
      defaultKeymap = "emacs";

      history = {
        path = "/tmp/.zsh_history";
        size = 1000;
        save = 1000;
        ignoreDups = true;
        expireDuplicatesFirst = true;
        findNoDups = true;
        share = true;
        ignoreSpace = false;
      };

      setOptions = [
        "EXTENDED_GLOB"
        "INC_APPEND_HISTORY"
        "HIST_REDUCE_BLANKS"
        "NO_BEEP"
        "NO_FLOW_CONTROL"
        "LOCAL_TRAPS"
        "BSD_ECHO"
      ];

      localVariables = {
        ZSH_AUTOSUGGEST_USE_ASYNC = true;
      };

      shellAliases = {
        cmd = "type -m '*'";
        df = "df -H";
        cls = "clear";
        rgi = "rg -i";
        rgf = "rg --files --no-ignore --hidden -g";
        fd = "fd -H";
        du = "du -sh";
        ldate = ''date +"%I:%M %p"'';
        ls = "eza -1F";
        ll = "eza -llh";
        tree = "eza --long --tree --level=4";
        cat = "bat";
        cargotestbt = "RUST_BACKTRACE=1 cargo test -- --nocapture";
        cargorunbt = "RUST_BACKTRACE=1 cargo run";
        cargotestprint = "cargo test -- --nocapture";
        dockerc = "docker compose";
      }
      // lib.optionalAttrs isLinux {
        lsblk = "lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT";
      };

      completionInit = ''
        autoload -Uz compinit
        _zcd=${config.xdg.cacheHome}/zsh/zcompdump
        [[ -d ''${_zcd:h} ]] || mkdir -p ''${_zcd:h}
        _stale=( ''${~_zcd}(N.mh+24) )
        if [[ -s $_zcd && -z $_stale ]]; then
          compinit -C -d $_zcd        # fast path: trust the dump
        else
          compinit -d $_zcd && touch $_zcd   # full check, rebuilds if fpath changed
        fi
        [[ $_zcd.zwc -nt $_zcd ]] || zcompile $_zcd &!
        unset _zcd _stale
      '';

      initContent = ''
        zstyle ':completion:*' matcher-list "" 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'

        unset SSH_ASKPASS
        unset GIT_ASKPASS

        bindkey -r "^S"
        bindkey -r "^A"
        bindkey "^A" clear-screen
        bindkey '^H' backward-char
        bindkey '^J' down-line-or-history
        bindkey '^K' up-line-or-history
        bindkey '^L' autosuggest-accept
      '';
    };

    zoxide = {
      enable = true;
      options = [
        "--cmd"
        "j"
      ];
    };

    bat.enable = true;
  };

  home = {
    activation.zcompdump = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run rm -f ${config.xdg.cacheHome}/zsh/zcompdump{,.zwc}
    '';

    sessionVariables = {
      PAGER = "less -R";
      TERMINAL = "alacritty";
      LANG = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
      CHARSET = "UTF-8";
      LS_COLORS = "di=34:ex=35";
      SSH_ASKPASS_REQUIRE = "never";
      ANTHROPIC_MODEL = "claude-opus-5";
      LIBGIT2_SYS_USE_PKG_CONFIG = "1";
    }
    // lib.optionalAttrs isDarwin {
      BROWSER = "open";
      DOWNLOAD = "$HOME/Downloads";
    }
    // lib.optionalAttrs isLinux {
      BROWSER = "firefox";
      DOWNLOAD = "/media/scratch/download";
      MOZ_WEBRENDER = "1";
      _JAVA_AWT_WM_NONREPARENTING = "1";
    };

    sessionPath = [
      "$HOME/.cargo/bin"
      "$HOME/.local/bin"
    ];
  };
}
