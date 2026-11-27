{
  config,
  lib,
  pkgs,
  ...
}:
let
  repo = "/home/jesse/nix";
  dir = "${repo}/.tmp/host-switch";
  # Pushing here takes the host's credentials and passes the Betterleaks gate, so its main came
  # from the owner or Tohru, whatever a sandbox managed to write into the local repository.
  origin = "https://github.com/malinoskj2/nix.git";
  switch = pkgs.writeShellScript "host-switch-service" ''
    set -uo pipefail
    status() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$(date -Is)" >"${dir}/status"; }
    as_jesse() { runuser -u jesse -- env HOME=/home/jesse GIT_TERMINAL_PROMPT=0 "$@"; }
    git() { as_jesse git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }
    commit=$(head -c 64 "${dir}/request" | tr -d '[:space:]')
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
      status invalid refused 2
      exit 0
    fi
    log="${dir}/$commit.log"
    refuse() {
      echo "host-switch: $2" >>"$log"
      chown jesse:users "$log"
      status "$commit" refused "$1"
      exit 0
    }
    : >"$log"
    as_jesse ${lib.getExe pkgs.git-repo-guard} ${repo} >>"$log" 2>&1 ||
      refuse 4 "${repo}'s Git config or hooks would run programs"
    main=$(git -C ${repo} rev-parse refs/heads/main)
    # Only committed main is ever activated, never a working tree or another branch.
    [[ "$commit" == "$main" ]] || refuse 3 "$commit is not the head of main ($main)"
    published=$(cd / && timeout 60 git ls-remote ${origin} refs/heads/main 2>>"$log") ||
      refuse 5 "cannot read main from ${origin}"
    [[ "''${published%%[[:space:]]*}" == "$commit" ]] ||
      refuse 6 "$commit is not main on ${origin} (''${published%%[[:space:]]*}); push it first"
    status "$commit" running -
    {
      toplevel=$(as_jesse \
        nix build --no-link --print-out-paths \
        "git+file://${repo}?ref=main&rev=$commit#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel") &&
        nix-env -p /nix/var/nix/profiles/system --set "$toplevel" &&
        "$toplevel/bin/switch-to-configuration" switch
    } >>"$log" 2>&1
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
