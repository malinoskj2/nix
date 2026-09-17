# Misc
{ pkgs, ... }:

{
  environment.sessionVariables = {
    # rust-analyzer can't resolve into std without the library sources
    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
  };

  # 16 GiB swapfile on ext4 root; NixOS creates /swapfile on activation.
  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024;
    }
  ];
}
