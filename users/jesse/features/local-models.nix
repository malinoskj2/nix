{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.local-models;
  inherit (cfg) root stores;
  storePaths = lib.unique (lib.attrValues stores);
  extraStores = lib.filter (path: path != root) storePaths;
  mountedPaths = map (name: stores.${name}) cfg.mountedStores;
  creatableStores = lib.filter (path: !lib.elem path mountedPaths) extraStores;
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
  sourceCatalog = pkgs.writeText "local-models-source.json" (
    builtins.toJSON (
      source
      // {
        inherit stores;
        inherit (cfg) defaultStore mountedStores;
        storeReserves = lib.mapAttrs (_: gib: gib * 1024 * 1024 * 1024) cfg.storeReserves;
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
  # Disabled entries leave the consumer catalog; their files are only retained.
  catalog = pkgs.runCommand "local-models-catalog" { } ''
    ${executable} split ${sourceCatalog} "$out"
  '';
in
{
  options.services.local-models = {
    historical = lib.mkEnableOption "historical TikTok model downloads";
    root = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/models";
      description = "Directory holding the catalog, readiness, views and by-name aliases. Activation skips it while it can't be created.";
    };
    stores = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default.main = root;
      description = "Weight stores by name, each an absolute directory holding `huggingface/` and `files/`. A catalog entry's `store` picks one; views under the root link into it.";
    };
    defaultStore = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Store for catalog entries without a `store` field.";
    };
    mountedStores = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Stores that are mount points of another filesystem, such as an NFS share. Sync never creates them and treats them as unavailable unless that filesystem is mounted.";
    };
    storeReserves = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.unsigned;
      default = { };
      description = "Free space in GiB that downloads and imports must leave on a store's filesystem, beyond the usual 2 GiB.";
    };
  };
  config = {
    home.packages = [
      pkgs.local-models
      pkgs.qwen-prompt
    ];
    home.sessionVariables = {
      MODEL_ROOT = root;
      HF_HUB_CACHE = "${root}/huggingface";
      IMG2VIDEO_MODELS = "${root}/by-name/img2video";
      SAM = "${root}/by-name/sam2.1";
    };
    assertions = [
      {
        assertion = stores ? ${cfg.defaultStore};
        message = "services.local-models.defaultStore must name one of services.local-models.stores";
      }
      {
        assertion = lib.all (lib.hasPrefix "/") storePaths;
        message = "services.local-models.stores must be absolute paths";
      }
      {
        assertion = lib.all (name: stores ? ${name}) (cfg.mountedStores ++ lib.attrNames cfg.storeReserves);
        message = "services.local-models.mountedStores and storeReserves must name stores";
      }
      {
        assertion = !lib.elem root mountedPaths;
        message = "services.local-models.root can't be a mounted store";
      }
    ];
    xdg.configFile."local-models/root".text = root;
    xdg.configFile."local-models/stores".text = lib.concatMapStrings (path: "${path}\n") extraStores;
    home.file.".config/local-models/voice-compose.yaml".text =
      let
        bind = source: target: {
          type = "bind";
          inherit source target;
          read_only = true;
          bind.create_host_path = false;
        };
      in
      builtins.toJSON {
        services.voice.volumes = map (path: bind path path) ([ root ] ++ extraStores) ++ [
          (bind "${root}/by-name/voices" "/models")
        ];
      };
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
      run mkdir -p "$HOME/.config/local-models"
      run chmod 0700 "$HOME/.config/local-models"
      if [ -f "$HOME/.config/local-models/hf-token" ]; then
        run chmod 0600 "$HOME/.config/local-models/hf-token"
      fi
      if ! run mkdir -p ${root}/.state 2>/dev/null; then
        echo "Model root ${root} is unavailable; skipping model synchronization"
      else
        for store in ${lib.escapeShellArgs creatableStores}; do
          run mkdir -p "$store" 2>/dev/null || echo "Model store $store is unavailable; its entries stay missing"
        done
        run ln -sfn ${catalog}/catalog.json ${root}/catalog.json
        run ln -sfn ${catalog}/retained.json ${root}/.state/retained.json
        run ln -sfn ${../../../docs/local-models.md} ${root}/README.md
        run ${executable} request --root ${root}
        # Units have been linked and the user manager reloaded. No boot/timer job.
        if [ -z "''${DRY_RUN_CMD:-}" ]; then
          ${pkgs.systemd}/bin/systemctl --user start --no-block local-models-sync.path || true
          ${pkgs.systemd}/bin/systemctl --user start --no-block local-models-sync.service || true
          echo "Model synchronization requested; run local-models status or journalctl --user -u local-models-sync"
        fi
      fi
    '';
  };
}
