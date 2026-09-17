{ pkgs, ... }:
{
  home.packages = with pkgs; [
    clang
    ghidra
    gitleaks
    lldb
    mold
  ];
}
