{
  inputs,
  lib,
  self,
  ...
}:
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
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          tohru-greeter-vm = pkgs.testers.runNixOSTest (
            import ../hosts/home/greeter-test.nix {
              inherit (inputs) tohru;
              greeter = self.nixosConfigurations.home.config.services.tohru-greeter;
            }
          );
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
                MODEL_ROOT = home.services.local-models.root;
                INSTALL_STORE = home.services.local-models.stores.install;
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
          council = self'.packages.council.tests.council;
          qwen-prompt = self'.packages.qwen-prompt.tests.launchers;
          unreal-sandbox = self'.packages.agent-sandbox.unrealTests;
          agent-sandbox-exec = self'.packages.agent-sandbox.execTests;
        };
    };
}
