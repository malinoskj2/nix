# Links x86_64 Linux Rust builds with mold, which users/jesse/features/native.nix installs.
{
  home.sessionVariables.CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
}
