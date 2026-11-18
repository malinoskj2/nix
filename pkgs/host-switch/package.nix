{
  coreutils,
  git,
  writeShellApplication,
}:

writeShellApplication {
  name = "host-switch";
  runtimeInputs = [
    coreutils
    git
  ];
  text = builtins.readFile ./host-switch.sh;
  meta = {
    description = "Ask home's host-switch service to build and activate main's head commit";
    platforms = [ "x86_64-linux" ];
  };
}
