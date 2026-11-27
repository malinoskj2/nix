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
  name = "secret";
  runtimeInputs = [
    age
    coreutils
    jq
    sops
    systemd
    yq-go
  ];
  text = builtins.readFile ./secret.sh;
  meta = {
    description = "Manage the host's sops-encrypted secrets without printing them";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
