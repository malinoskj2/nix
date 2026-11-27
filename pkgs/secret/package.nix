{
  age,
  coreutils,
  gnugrep,
  jq,
  python3Packages,
  sops,
  symlinkJoin,
  systemd,
  util-linux,
  writeShellApplication,
  writers,
  yq-go,
}:

let
  unlock = writers.writePython3Bin "secret-unlock" {
    libraries = [ python3Packages.cryptography ];
    flakeIgnore = [
      "E203"
      "E501"
    ];
  } (builtins.readFile ./secret-unlock.py);
  cli = writeShellApplication {
    name = "secret";
    runtimeInputs = [
      age
      coreutils
      gnugrep
      jq
      sops
      systemd
      unlock
      util-linux
      yq-go
    ];
    text = builtins.readFile ./secret.sh;
  };
in
symlinkJoin {
  name = "secret";
  paths = [
    cli
    unlock
  ];
  meta = {
    description = "Manage the host's sops-encrypted secrets without printing them";
    mainProgram = "secret";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
