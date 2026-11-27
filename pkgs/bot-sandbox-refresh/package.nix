{
  agent-sandbox,
  coreutils,
  docker,
  gnugrep,
  gnused,
  iproute2,
  jq,
  lib,
  python3,
  runCommand,
  util-linux,
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
  passthru.tests.notify =
    runCommand "bot-sandbox-refresh-tests"
      {
        nativeBuildInputs = [
          coreutils
          gnugrep
          gnused
          jq
          python3
          util-linux
        ];
      }
      ''
        python3 -B ${./test.py} ${./bot-sandbox-refresh.sh} ${../agent-sandbox/agent-sandbox-preview-ports.sh} -v
        touch "$out"
      '';
  meta = {
    description = "Restart idle Orca bots' sandboxes that run an outdated agent-sandbox image";
    platforms = lib.platforms.linux;
  };
}
