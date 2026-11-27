{ inputs, pkgs }:
{
  name = "agent-broker";

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

    with subtest("a machine without the encrypted file boots and fails closed"):
        machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
        machine.fail("systemctl is-active sops-install-secrets.service")
        machine.fail("systemctl is-active agent-broker-echo.service")
        machine.fail("test -e /run/secrets/test-token")
        machine.succeed("test \"$(stat -c '%U %a' /var/lib/agent-secrets)\" = 'root 700'")

    with subtest("agent-broker is a separate principal"):
        machine.succeed("id agent-broker")
        machine.succeed("test \"$(getent passwd agent-broker | cut -d: -f6,7)\" = '/var/empty:${pkgs.shadow}/bin/nologin'")
        groups = machine.succeed("id -nG jesse").split()
        assert "agent-broker" not in groups and "keys" not in groups, groups
        assert "agent-broker-clients" in groups, groups

    machine.succeed("age-keygen -o /root/recovery.txt")
    machine.succeed("agent-secret init \"$(age-keygen -y /root/recovery.txt)\"")
    machine.succeed("stat -c '%U %a' /var/lib/sops-nix/key.txt | grep -qx 'root 600'")
    machine.succeed("printf 'fake-test-value' | agent-secret add test-token")

    with subtest("a declared secret missing from the file skips deployment"):
        machine.fail("agent-secret apply")
        machine.fail("systemctl is-failed sops-install-secrets.service")
        machine.fail("test -e /run/secrets/test-token")
        machine.succeed("agent-secret list | grep -E '^later-token +no +yes'")

    machine.succeed("printf 'fake-later-value' | agent-secret add later-token")
    machine.succeed("agent-secret apply")

    with subtest("secrets decrypt into agent-broker-owned files"):
        machine.succeed("test \"$(stat -Lc '%U %G %a' /run/secrets/test-token)\" = 'agent-broker agent-broker 400'")
        machine.succeed("test \"$(cat /run/secrets/test-token)\" = fake-test-value")
        machine.fail(as_user("jesse", "cat /run/secrets/test-token"))
        machine.fail(as_user("jesse", "cat /run/secrets.d/*/test-token"))
        machine.fail(as_user("jesse", "cat /var/lib/agent-secrets/secrets.yaml"))
        machine.fail(as_user("jesse", "cat /var/lib/sops-nix/key.txt"))
        listing = machine.succeed("agent-secret list")
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
        machine.succeed("printf 'fake-rotated' | agent-secret rotate test-token")
        machine.succeed("agent-secret apply")
        machine.succeed("test \"$(cat /run/secrets/test-token)\" = fake-rotated")
        machine.wait_until_succeeds("test \"$(systemctl show -P InvocationID agent-broker-echo.service)\" != '" + before.strip() + "'")
        machine.wait_for_file("/run/agent-broker/echo/echo.sock")
        machine.wait_until_succeeds(as_user("jesse", connect) + " | grep -qx 'ok 12'")

    with subtest("the recovery key decrypts the file"):
        machine.succeed("SOPS_AGE_KEY_FILE=/root/recovery.txt sops decrypt --extract '[\"later-token\"]' /var/lib/agent-secrets/secrets.yaml | grep -qx fake-later-value")

    with subtest("the secrets survive a reboot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("agent-broker-echo.service")
        machine.succeed("test \"$(cat /run/secrets/test-token)\" = fake-rotated")
  '';
}
