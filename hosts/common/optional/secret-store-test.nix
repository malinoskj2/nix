{ inputs, pkgs }:
{
  name = "secret-store";

  node.specialArgs = { inherit inputs; };

  nodes.machine = {
    imports = [ ./agent-broker.nix ];

    environment.systemPackages = [
      pkgs.age
      pkgs.python3
      pkgs.sops
    ];

    users.users = {
      jesse.isNormalUser = true;
      other.isNormalUser = true;
    };

    secrets.host.user-token = {
      owner = "jesse";
      restartUnits = [ "host-consumer.service" ];
    };

    systemd.services.host-consumer = {
      wantedBy = [ "multi-user.target" ];
      after = [ "sops-install-secrets.service" ];
      unitConfig.ConditionPathExists = "/run/secrets/user-token";
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };

    agentBroker = {
      clients = [ "jesse" ];
      secrets = {
        test-token.inject.hosts = [ "api.example.com" ];
        later-token = { };
      };
      services.echo = {
        description = "Answer on a socket whether the broker can read its secret";
        secrets = [ "test-token" ];
        path = [ pkgs.python3 ];
        script = ''
          exec python3 - <<'PY'
          import os, socket
          path = os.path.join(os.environ["AGENT_BROKER_SOCKET_DIR"], "echo.sock")
          if os.path.exists(path):
              os.unlink(path)
          server = socket.socket(socket.AF_UNIX)
          server.bind(path)
          server.listen()
          while True:
              conn, _ = server.accept()
              with open("/run/secrets/test-token", "rb") as f:
                  conn.sendall(b"ok %d\n" % len(f.read()))
              conn.close()
          PY
        '';
      };
    };
  };

  testScript = ''
    import shlex

    connect = "python3 -c 'import socket; s = socket.socket(socket.AF_UNIX); s.connect(\"/run/agent-broker/echo/echo.sock\"); print(s.recv(64).decode().strip())'"

    def as_user(user, cmd):
        return f"su -s /bin/sh {user} -c {shlex.quote(cmd)}"

    machine.wait_for_unit("multi-user.target")

    def deployed(name):
        return machine.execute(f"test -e /run/secrets/{name}")[0] == 0

    def gone(name):
        machine.fail(f"test -e /run/secrets/{name}")
        machine.fail(f"ls /run/secrets.d/*/{name}")

    with subtest("a machine without the encrypted file boots and fails closed"):
        machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
        machine.fail("systemctl is-active sops-install-secrets.service")
        machine.fail("systemctl is-active agent-broker-echo.service")
        machine.fail("systemctl is-active host-consumer.service")
        gone("test-token")
        machine.succeed("test \"$(stat -c '%U %a' /var/lib/secrets)\" = 'root 700'")

    with subtest("agent-broker is a separate principal"):
        machine.succeed("id agent-broker")
        machine.succeed("test \"$(getent passwd agent-broker | cut -d: -f6,7)\" = '/var/empty:${pkgs.shadow}/bin/nologin'")
        groups = machine.succeed("id -nG jesse").split()
        assert "agent-broker" not in groups and "keys" not in groups, groups
        assert "agent-broker-clients" in groups, groups

    machine.succeed("age-keygen -o /root/recovery.txt")
    machine.succeed("secret init \"$(age-keygen -y /root/recovery.txt)\"")
    machine.succeed("stat -c '%U %a' /var/lib/sops-nix/key.txt | grep -qx 'root 600'")
    machine.succeed("printf 'fake-test-value' | secret add test-token")

    with subtest("secrets missing from the file don't hold back the others"):
        machine.succeed("secret apply")
        assert deployed("test-token")
        gone("later-token")
        gone("user-token")
        machine.wait_for_unit("agent-broker-echo.service")
        machine.fail("systemctl is-active host-consumer.service")
        listing = machine.succeed("secret list")
        print(listing)
        machine.succeed("secret list | grep -E '^later-token +broker +no +no'")
        machine.succeed("secret list | grep -E '^user-token +host +no +no'")
        machine.succeed("secret list | grep -E '^test-token +broker +yes +yes'")

    machine.succeed("printf 'fake-later-value' | secret add later-token")
    machine.succeed("printf 'fake-user-value' | secret add user-token")
    machine.succeed("secret apply")
    machine.wait_for_unit("host-consumer.service")

    with subtest("broker secrets are agent-broker's, host secrets their owner's"):
        machine.succeed("test \"$(stat -Lc '%U %G %a' /run/secrets/test-token)\" = 'agent-broker agent-broker 400'")
        machine.succeed("test \"$(cat /run/secrets/test-token)\" = fake-test-value")
        machine.fail(as_user("jesse", "cat /run/secrets/test-token"))
        machine.fail(as_user("jesse", "cat /run/secrets.d/*/test-token"))
        machine.fail(as_user("jesse", "cat /var/lib/secrets/secrets.yaml"))
        machine.fail(as_user("jesse", "cat /var/lib/sops-nix/key.txt"))
        machine.succeed("test \"$(stat -Lc '%U %G %a' /run/secrets/user-token)\" = 'jesse root 400'")
        machine.succeed(as_user("jesse", "cat /run/secrets/user-token") + " | grep -qx fake-user-value")
        machine.fail(as_user("other", "cat /run/secrets/user-token"))
        listing = machine.succeed("secret list")
        assert "fake-" not in listing, listing
    with subtest("broker sockets accept clients only"):
        machine.wait_for_unit("agent-broker-echo.service")
        machine.wait_for_file("/run/agent-broker/echo/echo.sock")
        assert machine.succeed(as_user("jesse", connect)).strip() == "ok 15"
        machine.fail(as_user("other", connect))
        machine.fail(as_user("jesse", "touch /run/agent-broker/echo/x"))
        machine.fail(as_user("jesse", "ls /run/agent-broker-echo"))

    with subtest("the broker service is hardened"):
        props = machine.succeed("systemctl show -p User,ProtectSystem,ProtectHome,NoNewPrivileges,PrivateTmp,CapabilityBoundingSet agent-broker-echo.service")
        for expected in ["User=agent-broker", "ProtectSystem=strict", "ProtectHome=yes", "NoNewPrivileges=yes", "PrivateTmp=yes", "CapabilityBoundingSet=\n"]:
            assert expected in props + "\n", props

    with subtest("rotation redeploys and restarts consumers"):
        before = machine.succeed("systemctl show -P InvocationID agent-broker-echo.service")
        machine.succeed("printf 'fake-rotated' | secret rotate test-token")
        machine.succeed("secret apply")
        machine.succeed("test \"$(cat /run/secrets/test-token)\" = fake-rotated")
        machine.wait_until_succeeds("test \"$(systemctl show -P InvocationID agent-broker-echo.service)\" != '" + before.strip() + "'")
        machine.wait_for_file("/run/agent-broker/echo/echo.sock")
        machine.wait_until_succeeds(as_user("jesse", connect) + " | grep -qx 'ok 12'")

    with subtest("a secret removed from the file is withdrawn alone"):
        machine.succeed("secret remove later-token")
        machine.succeed("secret apply")
        gone("later-token")
        assert deployed("test-token") and deployed("user-token")
        machine.succeed("systemctl is-active agent-broker-echo.service host-consumer.service")

    with subtest("withdrawing a secret stops its consumers only"):
        machine.succeed("secret remove test-token")
        machine.succeed("secret apply")
        gone("test-token")
        machine.wait_until_fails("systemctl is-active agent-broker-echo.service")
        machine.fail(as_user("jesse", connect))
        machine.succeed("systemctl is-active host-consumer.service")
        assert deployed("user-token")
        machine.succeed("printf 'fake-rotated' | secret add test-token")
        machine.succeed("printf 'fake-later-value' | secret add later-token")
        machine.succeed("secret apply")
        machine.wait_for_unit("agent-broker-echo.service")
        machine.wait_until_succeeds(as_user("jesse", connect) + " | grep -qx 'ok 12'")

    def assert_all_withdrawn():
        machine.wait_until_fails("systemctl is-active agent-broker-echo.service")
        machine.wait_until_fails("systemctl is-active host-consumer.service")
        machine.fail("systemctl is-failed sops-install-secrets.service")
        for name in ["test-token", "later-token", "user-token"]:
            gone(name)
        machine.fail(as_user("jesse", connect))
        machine.succeed("journalctl -u sops-install-secrets -o cat | grep -F 'every secret is withdrawn'")

    def assert_redeployed():
        machine.succeed("secret apply")
        machine.wait_for_unit("agent-broker-echo.service")
        machine.wait_for_unit("host-consumer.service")
        machine.wait_until_succeeds(as_user("jesse", connect) + " | grep -qx 'ok 12'")

    with subtest("removing the encrypted file withdraws every secret"):
        machine.succeed("mv /var/lib/secrets/secrets.yaml /root/secrets.yaml")
        machine.fail("secret apply")
        assert_all_withdrawn()
        machine.succeed("mv /root/secrets.yaml /var/lib/secrets/secrets.yaml")
        assert_redeployed()

    with subtest("removing the host key withdraws every secret"):
        machine.succeed("mv /var/lib/sops-nix/key.txt /root/key.txt")
        machine.fail("secret apply")
        assert_all_withdrawn()
        machine.succeed("mv /root/key.txt /var/lib/sops-nix/key.txt")
        assert_redeployed()

    with subtest("the recovery key decrypts the file"):
        machine.succeed("SOPS_AGE_KEY_FILE=/root/recovery.txt sops decrypt --extract '[\"later-token\"]' /var/lib/secrets/secrets.yaml | grep -qx fake-later-value")

    with subtest("the secrets survive a reboot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("agent-broker-echo.service")
        machine.succeed("test \"$(cat /run/secrets/test-token)\" = fake-rotated")
  '';
}
