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
          media-web = self'.packages.media-web.tests.stubs;
          devshell = self'.devShells.default;
          # Secrets stay on each host; the repository is public, so not even ciphertext goes in.
          no-committed-secrets =
            pkgs.runCommand "no-committed-secrets" { nativeBuildInputs = [ pkgs.ripgrep ]; }
              ''
                if rg --files-with-matches --hidden --text \
                  -e 'ENC\[AES256_GCM,' \
                  -e '^age-encryption\.org/v1$' \
                  -e '-{5}BEGIN AGE ENCRYPTED FILE-{5}' \
                  -e 'AGE-SECRET-KEY-1[0-9A-Z]{58}' \
                  ${self}; then
                  echo "these tracked files hold sops or age ciphertext or keys; keep them on the host instead" >&2
                  exit 1
                fi
                touch "$out"
              '';
          agent-sandbox-no-secret-mounts =
            pkgs.runCommand "agent-sandbox-no-secret-mounts" { nativeBuildInputs = [ pkgs.ripgrep ]; }
              ''
                if rg --line-number --glob '*.{sh,py,nix}' \
                  -e '/run/secrets' \
                  -e '/run/agent-broker-' \
                  -e '/var/lib/(agent-secrets|sops-nix)' \
                  -e '(src=|--volume "?|-v "?|mount_readonly "?)/(run|var|var/lib)?[:,"[:space:]]' \
                  ${../pkgs/agent-sandbox}; then
                  echo "the sandbox must never mount decrypted secrets, the encrypted file or the host key" >&2
                  exit 1
                fi
                touch "$out"
              '';
          gpu-scheduler = self'.packages.gpu-scheduler.tests.scheduler;
          cargo-preferences = self'.packages.cargo-preferences;
          rust-lints-library = self'.packages.rust-lints.lintLibrary;
          rust-lints-fixture = self'.packages.rust-lints.tests.fixture;
          ts-lints = self'.packages.ts-lints;
          zsh-claude-command = self'.packages.zsh-claude-command.tests.widget;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          agent-broker-vm = pkgs.testers.runNixOSTest (
            import ../hosts/common/optional/agent-broker-test.nix { inherit inputs pkgs; }
          );
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
          agent-sandbox-codex = self'.packages.agent-sandbox.codexTests;
          agent-sandbox-runner = self'.packages.agent-sandbox.runnerTests;
          agent-sandbox-root-guard = self'.packages.agent-sandbox.rootGuardTests;
          sandbox-display = self'.packages.agent-sandbox.displayTests;
        };
    };
}
