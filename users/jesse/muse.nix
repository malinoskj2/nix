{
  config,
  lib,
  pkgs,
  ...
}:
let
  mergeResources = pkgs.writeScript "muse-resource-instructions" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./muse-resources.py}
  '';
  instructions = pkgs.writeText "muse-resource-instructions.md" (
    builtins.readFile ./claude/rules/gpu.md + "\n" + builtins.readFile ./claude/rules/resources.md
  );
in
{
  # Muse's supported run.developer_prompt setting carries the same canonical
  # guidance as Claude rules and Codex context, including in existing sandboxes.
  home.activation.museResources = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${mergeResources} ${instructions} ${lib.escapeShellArg "${config.xdg.configHome}/muse/settings.json"}
    sandboxSettings=${lib.escapeShellArg "${config.xdg.dataHome}/agent-sandbox/home/.config/muse/settings.json"}
    if [ -f "$sandboxSettings" ]; then
      run ${mergeResources} ${instructions} "$sandboxSettings"
    fi
  '';
}
