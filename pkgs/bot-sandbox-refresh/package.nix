{
  agent-sandbox,
  coreutils,
  docker,
  gnugrep,
  gnused,
  iproute2,
  jq,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "bot-sandbox-refresh";
  runtimeInputs = [
    coreutils
    docker
    gnugrep
    gnused
    iproute2
    jq
  ];
  runtimeEnv = {
    AGENT_SANDBOX_IMAGE_REF = agent-sandbox.imageRef;
    AGENT_SANDBOX_PREVIEW_PORTS_TOOL = lib.getExe agent-sandbox.previewPorts;
  };
  text = builtins.readFile ./bot-sandbox-refresh.sh;
  meta = {
    description = "Restart idle Orca bots' sandboxes that run an outdated agent-sandbox image";
    platforms = lib.platforms.linux;
  };
}
