{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.local-models;
  root = "${config.home.homeDirectory}/.local/share/models";
  executable = lib.getExe pkgs.local-models;
  source = builtins.fromJSON (builtins.readFile ../../../pkgs/local-models/catalog.json);
  packaged = model: {
    enabled = true;
    kind = "checkpoint";
    compatibility = "consumer-evidenced";
    loader = "realesrgan-ncnn-vulkan -m MODEL_ROOT/by-name/ALIAS -n ${model}";
    dependencies = [ ];
    files =
      map
        (suffix: {
          target = "${model}.${suffix}";
          storePath = "${pkgs.realesrgan-ncnn-vulkan}/share/models/${model}.${suffix}";
        })
        [
          "bin"
          "param"
        ];
  };
  catalog = pkgs.writeText "local-models-catalog.json" (
    builtins.toJSON (
      source
      // {
        importCaches = [
          "${config.home.homeDirectory}/.cache/huggingface/hub"
          "${config.xdg.dataHome}/agent-sandbox/home/.cache/huggingface/hub"
        ];
        entries =
          lib.mapAttrs (
            alias: entry:
            entry
            // {
              enabled = if lib.hasPrefix "historical-" alias then cfg.historical else entry.enabled;
            }
          ) source.entries
          // {
            realesrgan-x4plus = packaged "realesrgan-x4plus";
            realesrgan-x4plus-anime = packaged "realesrgan-x4plus-anime";
          };
      }
    )
  );
in
{
  options.services.local-models.historical = lib.mkEnableOption "historical TikTok model downloads";
  config = {
    home.packages = [ pkgs.local-models ];
    home.sessionVariables = {
      MODEL_ROOT = root;
      HF_HUB_CACHE = "${root}/huggingface";
      IMG2VIDEO_MODELS = "${root}/by-name/img2video";
      SAM = "${root}/by-name/sam2.1";
    };
    home.file.".local/share/models/catalog.json".source = catalog;
    home.file.".local/share/models/README.md".source = ../../../docs/local-models.md;
    home.file.".config/local-models/voice-compose.yaml".text = ''
      services:
        voice:
          volumes:
            - type: bind
              source: ${root}
              target: ${root}
              read_only: true
              bind: { create_host_path: false }
            - type: bind
              source: ${root}/by-name/voices
              target: /models
              read_only: true
              bind: { create_host_path: false }
    '';
    home.file.".config/local-models/comfyui.yaml".text = ''
      shared_models:
        base_path: ${root}/by-name
        loras: |
          ltx-pixel-upscaler
          voice-nefer-adapter/adapter
        diffusion_models: h3
        text_encoders: h3
        vae: h3
        latent_upscale_models: h3
    '';
    systemd.user.services.local-models-sync = {
      Unit = {
        Description = "Reconcile pinned host model files";
        X-SwitchMethod = "keep-old";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${executable} sync --root ${root}";
        LoadCredential = "hf-token:%h/.config/local-models/hf-token";
        # A non-secret fallback makes an absent source nonfatal (systemd.exec).
        SetCredential = "hf-token:unconfigured";
        Environment = [
          "MODEL_ROOT=${root}"
          "HF_HUB_DISABLE_TELEMETRY=1"
        ];
        UnsetEnvironment = [
          "HF_TOKEN"
          "HF_TOKEN_PATH"
        ];
        TimeoutStartSec = "infinity";
        UMask = "0022";
        NoNewPrivileges = true;
      };
    };
    systemd.user.paths.local-models-sync = {
      Unit = {
        Description = "Retain model sync requests made during downloads";
        X-SwitchMethod = "keep-old";
      };
      Path = {
        PathExists = "${root}/.state/pending";
        Unit = "local-models-sync.service";
      };
    };
    home.activation.localModels = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
      run mkdir -p ${root}/.state "$HOME/.config/local-models"
      run chmod 0700 "$HOME/.config/local-models"
      if [ -f "$HOME/.config/local-models/hf-token" ]; then
        run chmod 0600 "$HOME/.config/local-models/hf-token"
      fi
      run ${executable} request --root ${root}
      # Units/catalog have been linked and the user manager reloaded. No boot/timer job.
      if [ -z "''${DRY_RUN_CMD:-}" ]; then
        ${pkgs.systemd}/bin/systemctl --user start --no-block local-models-sync.path || true
        ${pkgs.systemd}/bin/systemctl --user start --no-block local-models-sync.service || true
        echo "Model synchronization requested; run local-models status or journalctl --user -u local-models-sync"
      fi
    '';
  };
}
