{ inputs, pkgs }:
{
  name = "gdrive";

  node.specialArgs = { inherit inputs; };

  nodes.machine = {
    imports = [
      ./secret-store.nix
      ./gdrive.nix
    ];

    environment.systemPackages = [ pkgs.age ];

    users.users.jesse.isNormalUser = true;

    gdrive = {
      enable = true;
      user = "jesse";
      cache.sizeMiB = 256;
    };

    # The VM has no network; refreshes go to this stand-in for Google's token endpoint instead.
    systemd.services.gdrive-mount.environment.RCLONE_CONFIG_GDRIVE_TOKEN_URL =
      "http://127.0.0.1:8099/token";
    systemd.services.fake-token = {
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.python3 ];
      script = ''
        exec python3 - <<'PY'
        import http.server, json
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"])).decode()
                print("refresh with the stored token" if "refresh_token=fake-refresh" in body else "unexpected request", flush=True)
                out = json.dumps({"access_token": "fresh", "token_type": "Bearer", "expires_in": 3600}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(out)
            def log_message(self, *args):
                pass
        http.server.HTTPServer(("127.0.0.1", 8099), H).serve_forever()
        PY
      '';
    };

    specialisation.changed.configuration.systemd.services.gdrive-mount.environment.GDRIVE_TEST_GENERATION =
      "2";
  };

  testScript = ''
    import shlex

    def as_jesse(cmd):
        return f"su -s /bin/sh jesse -c {shlex.quote(cmd)}"

    def state():
        return machine.succeed("systemctl show -P ActiveState gdrive-mount.service").strip()

    machine.wait_for_unit("multi-user.target")

    with subtest("without the secrets the mount stays down and boot doesn't fail"):
        machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
        machine.fail("journalctl -b -o cat | grep -F 'ordering cycle'")
        assert state() == "inactive", state()
        machine.succeed("systemctl show -P ConditionResult gdrive-mount.service | grep -qx no")
        machine.fail("findmnt /mnt/gdrive")

    with subtest("the cache is a size-capped filesystem of its own"):
        machine.succeed("findmnt -rn -o FSTYPE /var/cache/gdrive/vfs | grep -qx ext4")
        size = int(machine.succeed("findmnt -bn -o SIZE /var/cache/gdrive/vfs").strip())
        assert size <= 256 * 1024 * 1024, size
        machine.succeed("test \"$(stat -c '%U %a' /var/cache/gdrive/cache.img)\" = 'root 600'")
        machine.succeed("test \"$(stat -c '%U %G %a' /var/cache/gdrive)\" = 'root gdrive 750'")

    machine.succeed("age-keygen -o /root/recovery.txt")
    machine.succeed("secret init \"$(age-keygen -y /root/recovery.txt)\"")
    machine.succeed("printf 'fake-id.apps.googleusercontent.com' | secret add gdrive-client-id")
    machine.succeed("printf 'fake-client-secret' | secret add gdrive-client-secret")
    machine.succeed("secret apply")

    with subtest("one missing secret keeps the mount down and a switch still succeeds"):
        assert state() == "inactive", state()
        machine.succeed("/run/booted-system/specialisation/changed/bin/switch-to-configuration test")
        assert state() == "inactive", state()
        machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

    machine.succeed(
        "printf '%s' '{\"access_token\":\"stale\",\"token_type\":\"Bearer\",\"refresh_token\":\"fake-refresh\",\"expiry\":\"2020-01-01T00:00:00Z\"}'"
        " | secret add gdrive-token"
    )
    machine.succeed("secret apply")

    with subtest("with every secret it starts as gdrive and refreshes from the stored refresh token"):
        machine.wait_until_succeeds("journalctl -u fake-token -o cat | grep -qx 'refresh with the stored token'", timeout=60)
        machine.fail("journalctl -u fake-token -o cat | grep -F unexpected")
        machine.succeed("systemctl show -P User gdrive-mount.service | grep -qx gdrive")
        machine.succeed("test \"$(stat -c %U /mnt/gdrive)\" = gdrive")
        machine.succeed("test \"$(stat -c '%U %a' /var/cache/gdrive/vfs)\" = 'gdrive 700'")

    with subtest("offline it fails and keeps retrying with backoff"):
        machine.wait_until_succeeds("test \"$(systemctl show -P NRestarts gdrive-mount.service)\" -ge 1", timeout=120)
        machine.fail("systemctl is-failed gdrive-mount.service")

    with subtest("credentials stay with gdrive and off persistent disk"):
        for name in ["gdrive-client-id", "gdrive-client-secret", "gdrive-token"]:
            machine.succeed(f"test \"$(stat -Lc '%U %a' /run/secrets/{name})\" = 'gdrive 400'")
            machine.fail(as_jesse(f"cat /run/secrets/{name}"))
        machine.fail("grep -rqsF fake-refresh /etc /var /root /home /tmp")
        machine.fail("grep -rqsF fake-client-secret /etc /var /root /home /tmp")

    with subtest("withdrawing a secret stops the mount and keeps it down"):
        machine.succeed("secret remove gdrive-token")
        machine.succeed("secret apply")
        machine.wait_until_succeeds("systemctl show -P ActiveState gdrive-mount.service | grep -qx inactive", timeout=60)
        machine.sleep(15)
        assert state() == "inactive", state()
        machine.fail("findmnt /mnt/gdrive")
        machine.fail("test -e /run/gdrive-mount")
        machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
  '';
}
