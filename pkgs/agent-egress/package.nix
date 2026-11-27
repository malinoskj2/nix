{
  coreutils,
  lib,
  libpsl,
  openssl,
  python3,
  runCommand,
  socat,
  curl,
  symlinkJoin,
  writeShellApplication,
}:
let
  python = python3.withPackages (ps: [ ps.mitmproxy ]);

  proxy = writeShellApplication {
    name = "agent-egress-proxy";
    runtimeInputs = [
      coreutils
      openssl
      python
    ];
    runtimeEnv = {
      AGENT_EGRESS_ADDON = "${./addon.py}";
    };
    text = builtins.readFile ./proxy.sh;
  };

  gate = writeShellApplication {
    name = "agent-egress-gate";
    text = ''exec ${lib.getExe python3} -I ${./gate.py} "$@"'';
  };

  cli = writeShellApplication {
    name = "agent-egress";
    runtimeInputs = [ libpsl ];
    text = ''exec ${lib.getExe python3} -I ${./agent_egress.py} "$@"'';
  };
in
symlinkJoin {
  name = "agent-egress";
  paths = [
    proxy
    gate
    cli
  ];
  passthru.tests.egress =
    runCommand "agent-egress-tests"
      {
        nativeBuildInputs = [
          curl
          python
          socat
        ];
      }
      ''
        cp ${./addon.py} addon.py
        cp ${./gate.py} gate.py
        cp ${./agent_egress.py} agent_egress.py
        cp ${./test_egress.py} test_egress.py
        HOME=$TMPDIR MITMDUMP=${python}/bin/mitmdump python -B test_egress.py -v
        touch "$out"
      '';
  meta = {
    description = "The agent sandboxes' egress proxy, per-sandbox gate and allowlist tools, run by agent-broker";
    platforms = lib.platforms.linux;
    mainProgram = "agent-egress";
  };
}
