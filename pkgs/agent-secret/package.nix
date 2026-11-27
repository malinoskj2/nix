{
  age,
  coreutils,
  jq,
  sops,
  systemd,
  writeShellApplication,
  yq-go,
}:

writeShellApplication {
  name = "agent-secret";
  runtimeInputs = [
    age
    coreutils
    jq
    sops
    systemd
    yq-go
  ];
  text = builtins.readFile ./agent-secret.sh;
  meta = {
    description = "Manage the host's sops-encrypted agent-broker secrets without printing them";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
