{
  agent-sandbox,
  coreutils,
  docker,
  jq,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "bot-sandbox-refresh";
  runtimeInputs = [
    coreutils
    docker
    jq
  ];
  runtimeEnv.AGENT_SANDBOX_IMAGE_REF = agent-sandbox.imageRef;
  text = builtins.readFile ./bot-sandbox-refresh.sh;
  meta = {
    description = "Restart idle Orca bots' sandboxes that run an outdated agent-sandbox image";
    platforms = lib.platforms.linux;
  };
}
