{ config, pkgs, ... }:
let
  repo = "/home/jesse/nix";
  dir = "${repo}/.tmp/host-switch";
  switch = pkgs.writeShellScript "host-switch-service" ''
    set -uo pipefail
    status() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$(date -Is)" >"${dir}/status"; }
    commit=$(head -c 64 "${dir}/request" | tr -d '[:space:]')
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
      status invalid refused 2
      exit 0
    fi
    main=$(runuser -u jesse -- env HOME=/home/jesse git -C ${repo} rev-parse refs/heads/main)
    if [[ "$commit" != "$main" ]]; then
      # Only committed main is ever activated, never a working tree or another branch.
      status "$commit" refused 3
      exit 0
    fi
    log="${dir}/$commit.log"
    status "$commit" running -
    {
      toplevel=$(runuser -u jesse -- env HOME=/home/jesse \
        nix build --no-link --print-out-paths \
        "git+file://${repo}?ref=main&rev=$commit#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel") &&
        nix-env -p /nix/var/nix/profiles/system --set "$toplevel" &&
        "$toplevel/bin/switch-to-configuration" switch
    } >"$log" 2>&1
    code=$?
    chown jesse:users "$log"
    status "$commit" "$([[ $code == 0 ]] && echo "done" || echo "failed")" "$code"
  '';
in
{
  environment.systemPackages = [ pkgs.host-switch ];

  systemd.tmpfiles.rules = [
    "d ${repo}/.tmp 0755 jesse users -"
    "d ${dir} 0700 jesse users -"
  ];

  systemd.paths.host-switch = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "${dir}/request";
  };

  systemd.services.host-switch = {
    description = "Switch to the requested commit of main";
    path = [
      config.nix.package
      pkgs.coreutils
      pkgs.git
      pkgs.util-linux
    ];
    # Activation would otherwise stop this unit while it is the one activating.
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = switch;
    };
  };
}
