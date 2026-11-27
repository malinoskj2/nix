{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.gdrive;
  secretNames = [
    "gdrive-client-id"
    "gdrive-client-secret"
    "gdrive-token"
  ];
  secretPath = name: config.secrets.host.${name}.path;
  vfsDir = "${cfg.cache.dir}/vfs";
  image = "${cfg.cache.dir}/cache.img";
  # rclone's cap is checked once a minute and ignores open files, so it sits well inside the image.
  vfsMaxMiB = cfg.cache.sizeMiB * 4 / 5;
  vfsMinFreeMiB = cfg.cache.sizeMiB / 20;

  makeImage = pkgs.writeShellApplication {
    name = "gdrive-cache-image";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.e2fsprogs
    ];
    text = ''
      umask 077
      img=${lib.escapeShellArg image}
      install -d -o root -g gdrive -m 0750 -- "$(dirname -- "$img")"
      [[ -e $img ]] && exit 0
      rm -f -- "$img.new"
      fallocate -l ${toString cfg.cache.sizeMiB}MiB "$img.new"
      mkfs.ext4 -q -F -m 0 -L gdrive-cache "$img.new"
      mv -- "$img.new" "$img"
    '';
  };

  prepare = pkgs.writeShellApplication {
    name = "gdrive-mount-prepare";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      mp=${lib.escapeShellArg cfg.mountPoint}
      if findmnt -rn --mountpoint "$mp" >/dev/null; then
        umount -l -- "$mp"
      fi
      install -d -o gdrive -g gdrive -m 0755 -- "$mp"
      install -d -o gdrive -g gdrive -m 0700 -- ${lib.escapeShellArg vfsDir}
    '';
  };

  release = pkgs.writeShellApplication {
    name = "gdrive-mount-release";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      mp=${lib.escapeShellArg cfg.mountPoint}
      if findmnt -rn --mountpoint "$mp" >/dev/null; then
        umount -l -- "$mp"
      fi
    '';
  };

  mountScript = pkgs.writeShellApplication {
    name = "gdrive-mount";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.rclone
    ];
    text = ''
      line() {
        local value
        value=$(<"$1")
        [[ -n $value && $value != *$'\n'* ]] || {
          echo "gdrive-mount: $1 must hold one non-empty line" >&2
          exit 1
        }
        printf '%s' "$value"
      }
      client_id=$(line ${secretPath "gdrive-client-id"})
      client_secret=$(line ${secretPath "gdrive-client-secret"})
      token=$(line ${secretPath "gdrive-token"})
      conf=$RUNTIME_DIRECTORY/rclone.conf
      printf '[gdrive]\ntype = drive\nscope = drive\nclient_id = %s\nclient_secret = %s\ntoken = %s\n' \
        "$client_id" "$client_secret" "$token" >"$conf"
      unset client_secret token
      exec rclone mount gdrive: ${lib.escapeShellArg cfg.mountPoint} \
        --config "$conf" \
        --log-systemd --log-level NOTICE \
        --cache-dir ${lib.escapeShellArg vfsDir} \
        --vfs-cache-mode full \
        --vfs-cache-max-size ${toString vfsMaxMiB}Mi \
        --vfs-cache-min-free-space ${toString vfsMinFreeMiB}Mi \
        --vfs-cache-max-age 168h \
        --dir-cache-time 1h \
        --allow-other --default-permissions \
        --uid "$(id -u ${cfg.user})" --gid "$(id -g ${cfg.user})" --umask 077
    '';
  };

  signin = pkgs.writeShellApplication {
    name = "gdrive-signin";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.rclone
      pkgs.secret
    ];
    text = ''
      umask 077
      die() {
        echo "gdrive-signin: $*" >&2
        exit 1
      }
      in_file() {
        secret list | grep -E "^$1 +host +yes " >/dev/null
      }
      for name in gdrive-client-id gdrive-client-secret; do
        in_file "$name" || die "$name isn't in the secret store yet; run 'secret add $name' first"
      done
      client_id=$(secret show gdrive-client-id) || die "couldn't read gdrive-client-id"
      client_secret=$(secret show gdrive-client-secret) || die "couldn't read gdrive-client-secret"
      [[ -n $client_id && -n $client_secret ]] || die "the client ID or secret is empty"

      echo "Approve rclone in the browser window that opens. Nothing is saved until you do." >&2
      out=$(RCLONE_DRIVE_CLIENT_ID=$client_id RCLONE_DRIVE_CLIENT_SECRET=$client_secret RCLONE_DRIVE_SCOPE=drive \
        rclone authorize drive --config /dev/null) || die "sign-in didn't finish; nothing was saved"
      unset client_secret
      token=$(printf '%s\n' "$out" | sed -n '/^Paste the following/{n;p;q}')
      unset out
      printf '%s' "$token" | jq -e '.refresh_token | type == "string" and length > 0' >/dev/null ||
        die "Google returned no refresh token; nothing was saved"

      if in_file gdrive-token; then
        printf '%s' "$token" | secret rotate gdrive-token
      else
        printf '%s' "$token" | secret add gdrive-token
      fi
      unset token
      secret apply
    '';
  };
in
{
  options.gdrive = {
    enable = lib.mkEnableOption "Google Drive mounted through rclone, with credentials from the secret store";
    user = lib.mkOption {
      type = lib.types.str;
      description = "The only user who can use the mount; files appear as theirs.";
    };
    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/gdrive";
    };
    cache = {
      dir = lib.mkOption {
        type = lib.types.str;
        default = "/var/cache/gdrive";
      };
      sizeMiB = lib.mkOption {
        type = lib.types.ints.between 256 1048576;
        default = 20480;
        description = "Size of the preallocated image holding rclone's VFS cache, which caps it. Changing it takes effect once the old image is deleted.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    secrets.host = lib.genAttrs secretNames (_: {
      owner = "gdrive";
      restartUnits = [ "gdrive-mount.service" ];
    });

    users.users.gdrive = {
      isSystemUser = true;
      group = "gdrive";
      description = "rclone Google Drive mount";
    };
    users.groups.gdrive = { };

    programs.fuse.userAllowOther = true;

    systemd.services.gdrive-cache-image = {
      description = "Create the size-capped image for the Google Drive cache";
      unitConfig.RequiresMountsFor = [ cfg.cache.dir ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe makeImage;
      };
    };

    systemd.mounts = [
      {
        description = "Size-capped Google Drive cache";
        what = image;
        where = vfsDir;
        type = "ext4";
        # nofail drops the implicit Before=local-fs.target, which would order it ahead of its own image.
        options = "loop,noatime,nodev,nosuid,noexec,nofail";
        requires = [ "gdrive-cache-image.service" ];
        after = [ "gdrive-cache-image.service" ];
      }
    ];

    systemd.services.gdrive-mount = {
      description = "Google Drive at ${cfg.mountPoint}";
      wantedBy = [ "multi-user.target" ];
      # Not network-online.target: multi-user.target would wait on it at boot.
      after = [ "network.target" ];
      # fusermount3 from the setuid wrapper, ahead of the store copy rclone's wrapper appends.
      path = [ "/run/wrappers" ];
      unitConfig = {
        RequiresMountsFor = [ vfsDir ];
        StartLimitIntervalSec = 0;
      };
      # No mount namespacing: ProtectSystem and friends would hide the FUSE mount from everyone else,
      # and NoNewPrivileges, or anything implying it, breaks the setuid fusermount3.
      serviceConfig = {
        Type = "notify";
        User = "gdrive";
        Group = "gdrive";
        UMask = "0077";
        # rclone saves each refreshed access token back to its config, so the config lives in this
        # tmpfs, assembled from the secrets on every start. Environment variables would do too, but
        # rclone names the remote, and so its cache directory, after a hash of their values.
        RuntimeDirectory = "gdrive-mount";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = "+${lib.getExe prepare}";
        ExecStart = lib.getExe mountScript;
        ExecStopPost = "+${lib.getExe release}";
        Restart = "on-failure";
        RestartSec = "5s";
        RestartSteps = 6;
        RestartMaxDelaySec = "5min";
        TimeoutStartSec = "30s";
        TimeoutStopSec = "20s";
      };
    };

    environment.systemPackages = [ signin ];
  };
}
