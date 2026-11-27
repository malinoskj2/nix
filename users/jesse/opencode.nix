{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  shared = import ./agent-shared.nix {
    inherit lib;
    isHome = (osConfig.networking.hostName or null) == "home";
  };
  veniceKey = osConfig.secrets.host.venice-api-key.path;
  model = name: context: output: {
    inherit name;
    limit = { inherit context output; };
  };
in
{
  programs.opencode = {
    enable = true;
    package = pkgs.unstable.opencode;
    inherit (shared) context skills;

    # OpenCode merges this under qwen-opencode's own config, whose enabled_providers hides Venice there.
    settings = {
      update = "disable";
      providers.venice = {
        # A missing file reads as an empty key: OpenCode still starts, and Venice requests fail as unauthenticated.
        settings.apiKey = "{file:${veniceKey}}";
        models = {
          deepseek-v4-1-flash-uncensored = model "DeepSeek V4.1 Flash Uncensored" 1000000 131072;
          deepseek-v4-1-flash-1017-uncensored = model "DeepSeek V4.1 Flash 1017 Uncensored" 1000000 131072;
          deepseek-v4-1-flash = model "DeepSeek V4.1 Flash" 1000000 262144;
          deepseek-v4-pro = model "DeepSeek V4 Pro" 1000000 262144;
          deepseek-v4-pro-0813 = model "DeepSeek V4 Pro 0813" 1000000 262144;
          glm-5-3-flash-uncensored = model "GLM 5.3 Flash Uncensored" 1048576 131072;
          qwen-3-6-plus = model "Qwen 3.6 Plus Uncensored" 1000000 65536;
          venice-uncensored-1-2 = model "Venice Uncensored 1.2" 128000 8192;
          kimi-k3 = model "Kimi K3" 1000000 131072;
        };
      };
    };
  };
}
