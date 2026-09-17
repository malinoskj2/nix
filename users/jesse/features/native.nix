# Native toolchain, debugging and binary analysis.
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
