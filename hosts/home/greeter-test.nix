{ tohru, greeter }:
{
  name = "tohru-greeter";

  nodes.machine = {
    imports = [
      tohru.nixosModules.tohru-greeter
      ../common/optional/fonts.nix
    ];

    virtualisation = {
      memorySize = 4096;
      cores = 4;
      qemu.options = [
        "-vga none"
        "-device virtio-gpu-pci"
      ];
    };

    hardware.graphics.enable = true;
    # Hyprland's llvmpipe renderer can't import Pleamar's dmabuf frames; the host has a GPU.
    environment.variables.PLEAMAR_SWAPCHAIN = "1";

    programs.hyprland.enable = true;

    users.users.jesse = {
      isNormalUser = true;
      password = "tohru-test";
      # Keeps /run/user/1000 after the session ends, for Hyprland's log.
      linger = true;
    };

    services.tohru-greeter = {
      inherit (greeter)
        enable
        package
        compositor
        style
        preferredOutput
        defaultUser
        defaultSession
        monitors
        wallpaper
        ;
      # A hang should fail the test, not hide behind tuigreet.
      fallbackToTui = false;
    };
  };

  testScript = ''
    def dump_logs():
        for cmd in [
            "journalctl -b --no-pager -o short-monotonic -u greetd -n 60",
            "journalctl -b --no-pager -o short-monotonic _UID=$(id -u greeter) -n 100",
            "grep -hv aquamarine /run/user/*/hypr/*/hyprland.log | tail -n 60",
        ]:
            print(machine.execute(cmd)[1])

    try:
        machine.wait_for_unit("greetd.service")
        machine.wait_until_succeeds("pgrep -u greeter -f bin/pleamar", timeout=180)
        machine.sleep(15)
        machine.screenshot("greeter")
        machine.succeed("pgrep -u greeter -f bin/pleamar")

        machine.send_chars("tohru-test\n")
        machine.wait_until_succeeds(
            "journalctl -b --no-pager -o cat | grep -F 'pam_unix(greetd:session): session opened for user jesse'",
            timeout=60,
        )
        # Hyprland can't run this session without a GPU, but its log shows the session command reached it.
        machine.wait_until_succeeds("ls /run/user/1000/hypr/*/hyprland.log", timeout=60)
        machine.screenshot("session")
    except Exception:
        dump_logs()
        raise

    machine.succeed("chvt 2")
    machine.wait_for_unit("autovt@tty2.service")
    machine.wait_until_tty_matches("2", "login: ")
  '';
}
