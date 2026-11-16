{ lib, self, ... }:
{
  perSystem =
    {
      pkgs,
      self',
      system,
      ...
    }:
    let
      hostsOnSystem = lib.filterAttrs (
        _: host: host.pkgs.stdenv.hostPlatform.system == system
      ) self.nixosConfigurations;
      localPackages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
        import ../pkgs { inherit pkgs; }
      );
      unexported = lib.subtractLists (lib.attrNames self'.packages) (lib.attrNames localPackages);
      hostChecks = lib.mapAttrs' (
        name: host: lib.nameValuePair "host-${name}" host.config.system.build.toplevel
      ) hostsOnSystem;
    in
    {
      checks =
        assert lib.assertMsg (unexported == [ ])
          "pkgs/ packages missing from exportedPackages in flake.nix: ${lib.concatStringsSep ", " unexported}";
        hostChecks
        // {
          local-models = self'.packages.local-models.tests.sync;
          devshell = self'.devShells.default;
          gpu-scheduler = self'.packages.gpu-scheduler.tests.scheduler;
          cargo-preferences = self'.packages.cargo-preferences;
          zsh-claude-command = self'.packages.zsh-claude-command.tests.widget;
          resource-scheduler = self'.packages.resource-scheduler.tests.scheduler;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          resource-scheduler-vm = pkgs.testers.runNixOSTest (
            import ../hosts/home/resource-scheduler-test.nix { inherit pkgs; }
          );
          resource-scheduler-config =
            let
              staged = self.nixosConfigurations.home.config;
            in
            pkgs.runCommand "resource-scheduler-config-tests"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  staged.services.slurm.package
                ];
                POLICY = staged.environment.etc."resource-scheduler/config.json".source;
                SLURM_CONFIG = staged.services.slurm.etcSlurm;
                DAEMON = pkgs.writeText "resource-scheduler-service.json" (
                  builtins.toJSON staged.systemd.services.resource-scheduler.serviceConfig
                );
                GAME_SERVICE = pkgs.writeText "resource-scheduler-game-service.json" (
                  builtins.toJSON staged.systemd.services.agent-sandbox-gaming.serviceConfig
                );
                MUSE_MERGER = ../users/jesse/muse-resources.py;
                GUIDANCE = ../users/jesse/claude/rules/resources.md;
                COMPAT = self.nixosConfigurations.home.pkgs.gpu-scheduler;
                SCHEDULER = staged.services.resourceScheduler.package;
              }
              ''
                python ${../hosts/home/test_resource_scheduler_config.py}
                # Parse with native Slurm without starting a controller. The
                # isolated builder has no slurm account; only that identity is
                # substituted. All scheduling/plugin syntax remains generated.
                cp -rL "$SLURM_CONFIG" config
                chmod -R u+w config
                sed -i 's/^SlurmUser=slurm$/SlurmUser=root/' config/slurm.conf
                SLURM_CONF="$PWD/config/slurm.conf" scontrol show hostnames home > nodes
                test "$(cat nodes)" = home
                touch "$out"
              '';
          local-models-activation =
            let
              home = self.nixosConfigurations.home.config.home-manager.users.jesse;
            in
            pkgs.runCommand "local-models-activation-tests"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.systemd
                ];
                ACTIVATION = pkgs.writeText "local-models-activation" home.home.activation.localModels.data;
                SERVICE = pkgs.writeText "local-models-service.json" (
                  builtins.toJSON home.systemd.user.services.local-models-sync
                );
                PATH_UNIT = pkgs.writeText "local-models-path.json" (
                  builtins.toJSON home.systemd.user.paths.local-models-sync
                );
                SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";
                TEST_BASH = "${pkgs.bash}/bin/bash";
              }
              ''
                export XDG_RUNTIME_DIR="$TMPDIR/runtime"
                mkdir -m700 "$XDG_RUNTIME_DIR"
                mkdir units
                cp ${
                  home.xdg.configFile."systemd/user/local-models-sync.service".source
                } units/local-models-sync.service
                cp ${home.xdg.configFile."systemd/user/local-models-sync.path".source} units/local-models-sync.path
                for unit in basic.target shutdown.target paths.target; do
                  cat > "units/$unit" <<EOF
                [Unit]
                Description=Verification fixture
                DefaultDependencies=no
                EOF
                done
                SYSTEMD_LOG_TARGET=console SYSTEMD_UNIT_PATH="$PWD/units" systemd-analyze --user verify units/local-models-sync.service units/local-models-sync.path
                python -B ${../pkgs/local-models/test_activation.py}
                touch "$out"
              '';
          unreal-sandbox = self'.packages.agent-sandbox.unrealTests;
        };
    };
}
