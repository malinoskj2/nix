# Secure Boot via Limine
# https://github.com/limine-bootloader/limine
#
# HOW THIS WORKS:
#   Limine's secure boot signs the Limine EFI binary itself using sbctl.
#   Kernels and initrds are then protected via checksum validation —
#   Limine hashes them at build time and will refuse to boot anything
#   that doesn't match. This is different from lanzaboote, which signs
#   the kernel and initrd directly with UEFI keys.
#
# ============================================================
# ONE-TIME SETUP (do this before enabling Secure Boot in BIOS)
# ============================================================
#
#   1. Boot into BIOS/UEFI firmware settings and put Secure Boot into
#      "Setup Mode" (usually under Secure Boot -> clear/delete all keys).
#
#   2. Generate your custom Secure Boot keys (stored in /var/lib/sbctl):
#        sudo nix-shell -p sbctl -- sbctl create-keys
#
#   3. Enroll your keys AND Microsoft's keys (required for Windows/OEM
#      firmware on the other drive to keep working):
#        sudo nix-shell -p sbctl -- sbctl enroll-keys -m -f
#
#   4. Rebuild and switch:
#        nh os switch
#
#   5. Verify the Limine EFI binary is signed:
#        sudo sbctl verify
#
#   6. Reboot and enable Secure Boot in your BIOS/UEFI firmware settings.
#
# ============================================================
# ONGOING
# ============================================================
#
#   Limine will automatically sign its EFI binary and hash new
#   kernels/initrds on each system rebuild. No manual steps needed
#   after initial setup.
#
# ============================================================
# WINDOWS NOTE
# ============================================================
#
#   Because you select your OS at the BIOS boot device level
#   (not via a boot menu), Windows on the other SSD is entirely
#   independent. The -m flag above includes Microsoft's certificate
#   authorities, which is what allows Windows to continue booting
#   with Secure Boot enabled.

{ pkgs, ... }:
{
  boot.loader.limine = {
    enable = true;

    # EFI support is required for Secure Boot.
    efiSupport = true;

    # Secure Boot: signs the Limine EFI binary with sbctl.
    # Also automatically enforces enrollConfig, validateChecksums,
    # and panicOnChecksumMismatch so kernels cannot be swapped out.
    secureBoot.enable = true;

    # How many NixOS generations to show in the boot menu.
    maxGenerations = 10;

    # Optional: show the NixOS dark-gray wallpaper at boot.
    style.wallpapers = [
      pkgs.nixos-artwork.wallpapers.simple-dark-gray-bootloader.gnomeFilePath
    ];
  };

  # sbctl is the tool used to manage Secure Boot keys, sign binaries,
  # and check signing status. Keep it installed so you can run
  # `sbctl verify` and `sbctl status` at any time.
  environment.systemPackages = [ pkgs.sbctl ];
}
