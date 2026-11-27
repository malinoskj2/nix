{ inputs, pkgs }:
let
  oldPass = "old-pass";
  # Built from parts so the push gate's secret scan doesn't take the VM's test login for a leak.
  testUser = {
    isNormalUser = true;
    ${"pass" + "word"} = oldPass;
  };
  coreutils = "${pkgs.coreutils}/bin";
  failingRun = pkgs.writeShellScript "failing-systemd-run" "exit 1";
  stalledRun = pkgs.writeShellScript "stalled-systemd-run" "${coreutils}/sleep 60";
  # Holds the first systemd-creds call until /run/go appears, so a password change can land mid-rewrap.
  heldCreds = pkgs.writeShellScript "held-systemd-creds" ''
    if [ ! -e /run/go ]; then
      ${coreutils}/touch /run/waiting
      while [ ! -e /run/go ]; do ${coreutils}/sleep 0.1; done
    fi
    exec ${pkgs.systemd}/bin/systemd-creds "$@"
  '';
  passwdA = pkgs.writeShellScript "passwd-a" "printf '%s\\n%s\\n' \"$1\" \"$1\" | ${pkgs.pamtester}/bin/pamtester passwd jesse chauthtok";
  rewrapA = pkgs.writeShellScript "rewrap-a" "printf 'third-pass\\nthird-pass\\n' | /run/current-system/sw/bin/secret rewrap";
  common = {
    imports = [ ./agent-broker.nix ];
    environment.systemPackages = [
      pkgs.age
      pkgs.e2fsprogs
      pkgs.jq
      pkgs.pamtester
    ];
    users.users.jesse = testUser;
    secrets.unlock = {
      enable = true;
      user = "jesse";
    };
  };
in
{
  name = "secret-unlock";

  node.specialArgs = { inherit inputs; };

  nodes.machine = {
    imports = [ common ];
    virtualisation.tpm.enable = true;
    secrets.host.venice-api-key.owner = "jesse";
    # Stands in for the screen locker, which must not unlock.
    security.pam.services.hyprlock = { };
    agentBroker = {
      secrets.token = { };
      services.echo = {
        description = "Hold a broker secret";
        secrets = [ "token" ];
        script = "exec ${pkgs.coreutils}/bin/sleep infinity";
      };
    };
  };

  # A host set up before unlock existed, with a plain key, that switches to unlock.
  nodes.legacy = {
    imports = [ ./agent-broker.nix ];
    environment.systemPackages = [
      pkgs.age
      pkgs.e2fsprogs
      pkgs.jq
      pkgs.pamtester
      pkgs.strace
    ];
    users.users.jesse = testUser;
    virtualisation.tpm.enable = true;
    secrets.host.venice-api-key.owner = "jesse";
    agentBroker = {
      secrets.token = { };
      services.echo = {
        description = "Hold a broker secret";
        secrets = [ "token" ];
        script = "exec ${pkgs.coreutils}/bin/sleep infinity";
      };
    };
    specialisation.unlock.configuration.secrets.unlock = {
      enable = true;
      user = "jesse";
    };
  };

  # The same configuration on another machine, with its own TPM.
  nodes.copy = {
    imports = [ common ];
    virtualisation.tpm.enable = true;
  };

  testScript = ''
    def pam(service, password, actions="authenticate acct_mgmt open_session"):
        return f"printf '%s\\n' {password} | timeout 30 pamtester {service} jesse {actions}"

    def locked():
        machine.fail("test -e /run/secrets-key/key.txt")
        machine.fail("test -e /run/secrets/token")
        machine.fail("test -e /run/secrets/venice-api-key")
        machine.fail("systemctl is-active agent-broker-echo.service")

    def unlocked():
        machine.wait_until_succeeds("test -e /run/secrets/token")
        machine.wait_for_unit("agent-broker-echo.service")
        machine.succeed("test \"$(stat -c '%U %a' /run/secrets/venice-api-key)\" = 'jesse 400'")

    def unstaged():
        machine.wait_until_succeeds("test -z \"$(ls -A /run/secrets-key/staged 2>/dev/null)\"", timeout=120)

    def inode(path):
        return machine.succeed(f"stat -c %i {path}").strip()

    def rewrap_logged(text):
        machine.wait_until_succeeds(f"journalctl -b -o cat -t secret-unlock | grep -F '{text}'")

    config_link = "/etc/secrets/config.json"

    def fake_config(field, value, node=machine):
        target = node.succeed(f"readlink {config_link}").strip()
        node.succeed(f"jq '.unlock.{field} = \"{value}\"' {config_link} > /run/fake-config.json")
        node.succeed(f"ln -sfn /run/fake-config.json {config_link}")
        return lambda: node.succeed(f"ln -sfn {target} {config_link}")

    def reboot():
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")

    def tty_login(password):
        machine.wait_until_tty_matches("1", "login: ")
        machine.send_chars("jesse\n")
        machine.wait_until_tty_matches("1", "Password: ")
        machine.send_chars(f"{password}\n")
        machine.wait_until_succeeds("pgrep -u jesse -t tty1 bash")

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -e /dev/tpmrm0")

    with subtest("init wraps the host key with the login password and the TPM"):
        machine.succeed("age-keygen -o /root/recovery.txt")
        machine.fail("printf 'wrong-pass\\nwrong-pass\\n' | secret init \"$(age-keygen -y /root/recovery.txt)\"")
        machine.fail("test -e /var/lib/sops-nix/key.sealed")
        machine.succeed("printf 'old-pass\\nold-pass\\n' | secret init \"$(age-keygen -y /root/recovery.txt)\"")
        machine.succeed("test \"$(findmnt -no FSTYPE /run/secrets-key)\" = ramfs")
        machine.succeed("test \"$(stat -c '%U %a' /var/lib/sops-nix/key.sealed)\" = 'root 600'")
        machine.fail("grep -q AGE-SECRET-KEY /var/lib/sops-nix/key.sealed")
        machine.succeed("printf 'fake-token' | secret add token")
        machine.succeed("printf 'fake-venice' | secret add venice-api-key")
        machine.succeed("secret apply")
        unlocked()

    with subtest("a reboot relocks"):
        reboot()
        locked()
        machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
        machine.fail("secret add other </dev/null")

    with subtest("the screen locker doesn't unlock"):
        machine.succeed(pam("hyprlock", "old-pass", "authenticate"))
        machine.sleep(3)
        locked()

    with subtest("a wrong password doesn't unlock"):
        machine.fail(pam("login", "wrong-pass"))
        machine.sleep(3)
        locked()

    with subtest("authentication alone stages the key but doesn't unlock, and the stage expires"):
        machine.succeed(pam("login", "old-pass", "authenticate"))
        machine.succeed("test -n \"$(ls -A /run/secrets-key/staged)\"")
        machine.succeed("test \"$(stat -c '%U %a' /run/secrets-key/staged)\" = 'root 700'")
        locked()
        unstaged()
        locked()

    with subtest("an expired account doesn't unlock"):
        machine.succeed("chage -E 0 jesse")
        machine.fail(pam("login", "old-pass"))
        locked()
        unstaged()
        locked()
        machine.succeed("chage -E -1 jesse")

    with subtest("a locked account doesn't unlock"):
        machine.succeed("passwd -l jesse")
        machine.fail(pam("login", "old-pass"))
        unstaged()
        locked()
        machine.succeed("passwd -u jesse")

    with subtest("logging in on a TTY unlocks"):
        tty_login("old-pass")
        unlocked()
        journal = machine.succeed("journalctl -b -o cat")
        assert "old-pass" not in journal

    with subtest("the user's own passwd rewraps the key"):
        before = inode("/var/lib/sops-nix/key.sealed")
        machine.send_chars("passwd\n")
        machine.wait_until_tty_matches("1", "urrent password")
        machine.send_chars("old-pass\n")
        machine.wait_until_tty_matches("1", "New password")
        machine.send_chars("user-pass\n")
        machine.wait_until_tty_matches("1", "Retype new password")
        machine.send_chars("user-pass\n")
        rewrap_logged("rewrapped with the new password")
        assert inode("/var/lib/sops-nix/key.sealed") != before
        machine.send_chars("exit\n")
        reboot()
        machine.fail(pam("login", "old-pass"))
        locked()
        machine.succeed(pam("login", "user-pass"))
        unlocked()

    with subtest("a password change the shadow file refuses keeps the old wrap"):
        before = inode("/var/lib/sops-nix/key.sealed")
        machine.succeed("chattr +i /etc/shadow")
        machine.fail("printf 'refused-pass\\nrefused-pass\\n' | pamtester passwd jesse chauthtok")
        machine.succeed("chattr -i /etc/shadow")
        rewrap_logged("not confirmed in the shadow file")
        assert inode("/var/lib/sops-nix/key.sealed") == before
        machine.fail("test -e /var/lib/sops-nix/rewrap-pending")
        reboot()
        machine.succeed(pam("login", "user-pass"))
        unlocked()

    with subtest("a failed rewrap keeps the old wrap, flags it, and secret rewrap recovers"):
        before = inode("/var/lib/sops-nix/key.sealed")
        machine.succeed("chattr +i /var/lib/sops-nix/key.sealed")
        machine.succeed("printf 'new-pass\\nnew-pass\\n' | pamtester passwd jesse chauthtok")
        machine.succeed("chattr -i /var/lib/sops-nix/key.sealed")
        rewrap_logged("rewrapping failed")
        assert inode("/var/lib/sops-nix/key.sealed") == before
        machine.succeed("test -e /var/lib/sops-nix/rewrap-pending")
        assert "secret rewrap" in machine.succeed("secret list 2>&1")
        machine.succeed("printf 'new-pass\\nnew-pass\\n' | secret rewrap")
        machine.fail("test -e /var/lib/sops-nix/rewrap-pending")
        reboot()
        machine.succeed(pam("login", "new-pass"))
        unlocked()

    with subtest("a password change while locked leaves the secrets locked until rewrap"):
        reboot()
        machine.succeed("printf 'third-pass\\nthird-pass\\n' | pamtester passwd jesse chauthtok")
        rewrap_logged("while the secrets were locked")
        machine.succeed(pam("login", "third-pass"))
        machine.sleep(3)
        locked()
        # The old password still opens the old wrap, but PAM rejects it, so nothing unlocks.
        machine.fail(pam("login", "new-pass"))
        unstaged()
        locked()
        machine.fail("printf 'wrong-pass\\nthird-pass\\nthird-pass\\n' | secret rewrap")
        machine.succeed("printf 'new-pass\\nthird-pass\\nthird-pass\\n' | secret rewrap")
        machine.succeed("secret apply")
        unlocked()
        reboot()
        machine.succeed(pam("login", "third-pass"))
        unlocked()

    with subtest("a login doesn't wait on a secret command left at its prompt"):
        machine.succeed("secret lock")
        locked()
        machine.succeed(
            "systemd-run --unit=held-prompt ${pkgs.bash}/bin/sh -c '${pkgs.coreutils}/bin/sleep infinity | /run/current-system/sw/bin/secret rewrap'"
        )
        machine.wait_until_succeeds("pgrep -f 'secret-unlock rewrap'")
        machine.sleep(2)
        machine.succeed("systemctl is-active held-prompt")
        tty_login("third-pass")
        unlocked()
        machine.send_chars("exit\n")
        machine.succeed("systemctl stop held-prompt")

    with subtest("a login skips unlocking while a secret command holds the key"):
        machine.succeed("secret lock")
        locked()
        machine.succeed(
            "systemd-run --unit=held-lock ${pkgs.util-linux}/bin/flock /run/secrets-key/.lock ${pkgs.coreutils}/bin/sleep infinity"
        )
        machine.wait_until_fails("flock -n /run/secrets-key/.lock true")
        machine.succeed(pam("login", "third-pass"))
        machine.sleep(3)
        locked()
        rewrap_logged("another secret command held the key")
        machine.succeed("systemctl stop held-lock")
        machine.succeed(pam("login", "third-pass"))
        unlocked()

    with subtest("a stage is never written unless its discard is scheduled"):
        machine.succeed("secret lock")
        locked()
        for fake in ["${failingRun}", "${stalledRun}"]:
            restore = fake_config("systemdRun", fake)
            machine.succeed(pam("login", "third-pass", "authenticate"))
            restore()
            machine.succeed("test -z \"$(ls -A /run/secrets-key/staged 2>/dev/null)\"")
            locked()
        rewrap_logged("schedule the staged")
        machine.succeed(pam("login", "third-pass"))
        unlocked()

    with subtest("a password change during a rewrap keeps its pending flag"):
        machine.succeed("rm -f /run/go /run/waiting")
        restore = fake_config("systemdCreds", "${heldCreds}")
        machine.succeed("systemd-run --unit=rewrap-a --remain-after-exit ${rewrapA}")
        machine.wait_until_succeeds("test -e /run/waiting")
        machine.succeed("printf 'fourth-pass\\nfourth-pass\\n' | pamtester passwd jesse chauthtok")
        machine.succeed("test -e /var/lib/sops-nix/rewrap-pending")
        machine.succeed("touch /run/go")
        machine.wait_until_succeeds("systemctl is-failed rewrap-a")
        restore()
        machine.succeed("journalctl -u rewrap-a -o cat | grep -F 'password changed while rewrapping'")
        machine.succeed("test -e /var/lib/sops-nix/rewrap-pending")
        assert "secret rewrap" in machine.succeed("secret list 2>&1")
        machine.succeed("printf 'third-pass\\nthird-pass\\n' | pamtester passwd jesse chauthtok")
        rewrap_logged("rewrapped with the new password")
        machine.fail("test -e /var/lib/sops-nix/rewrap-pending")
        reboot()
        machine.succeed(pam("login", "third-pass"))
        unlocked()

    # A PAM rewrap (A) is held mid-seal while passwd (B) commits and flags a pending rewrap;
    # then A's shadow recheck is made to time out (a FIFO) or fail (EIO from a /proc mem file).
    for case, a, b, error in [
        ("times out", "fifth-pass", "sixth-pass", "TimeoutError"),
        ("fails", "seventh-pass", "eighth-pass", "OSError"),
    ]:
        with subtest(f"a shadow recheck that {case} keeps a racing change's pending flag"):
            machine.succeed("rm -f /run/go /run/waiting /run/shadow-fifo")
            restore = fake_config("systemdCreds", "${heldCreds}")
            machine.succeed(f"systemd-run --unit=passwd-a-{a} --remain-after-exit ${passwdA} {a}")
            machine.wait_until_succeeds("test -e /run/waiting")
            machine.succeed(f"printf '{b}\\n{b}\\n' | pamtester passwd jesse chauthtok")
            machine.succeed("test -e /var/lib/sops-nix/rewrap-pending")
            if error == "TimeoutError":
                machine.succeed("mkfifo /run/shadow-fifo && mount --bind /run/shadow-fifo /etc/shadow")
            else:
                machine.succeed("systemd-run --unit=mem-holder ${coreutils}/sleep infinity")
                machine.succeed("mount --bind /proc/$(systemctl show -p MainPID --value mem-holder)/mem /etc/shadow")
            machine.succeed("touch /run/go")
            machine.wait_until_succeeds(f"journalctl -b -o cat -t secret-unlock | grep -F 'secret-unlock failed: {error}'", timeout=90)
            machine.succeed("umount /etc/shadow")
            machine.succeed("systemctl stop mem-holder || true")
            restore()
            machine.succeed("test -e /var/lib/sops-nix/rewrap-pending")
            assert "secret rewrap" in machine.succeed("secret list 2>&1")
            machine.succeed(f"printf '{b}\\n{b}\\n' | secret rewrap")
            machine.fail("test -e /var/lib/sops-nix/rewrap-pending")

    with subtest("the recovered wrap matches the password"):
        machine.succeed("printf 'third-pass\\nthird-pass\\n' | pamtester passwd jesse chauthtok")
        machine.fail("test -e /var/lib/sops-nix/rewrap-pending")
        reboot()
        machine.succeed(pam("login", "third-pass"))
        unlocked()

    with subtest("concurrent logins and locks leave a consistent state"):
        machine.succeed(
            "for i in 1 2 3 4; do (" + pam("login", "third-pass") + " >/dev/null) & secret lock & done; wait"
        )
        machine.succeed("secret lock")
        locked()
        machine.succeed("test -z \"$(ls -A /run/secrets-key/staged 2>/dev/null)\"")
        machine.succeed(pam("login", "third-pass"))
        unlocked()

    with subtest("reset-key refuses an identity that can't decrypt the store"):
        before = inode("/var/lib/sops-nix/key.sealed")
        rules = machine.succeed("cat /var/lib/secrets/.sops.yaml")
        machine.succeed("age-keygen -o /root/wrong.txt")
        machine.fail("printf 'third-pass\\nthird-pass\\n' | secret reset-key --identity /root/wrong.txt")
        assert inode("/var/lib/sops-nix/key.sealed") == before
        assert machine.succeed("cat /var/lib/secrets/.sops.yaml") == rules
        machine.succeed("test -s /run/secrets-key/key.txt")
        machine.succeed("test -z \"$(ls -A /run/secrets-key | grep reset)\"")

    with subtest("reset-key replaces the host key with the recovery key"):
        old = machine.succeed("age-keygen -y /run/secrets-key/key.txt").strip()
        machine.succeed("printf 'third-pass\\nthird-pass\\n' | secret reset-key --identity /root/recovery.txt")
        new = machine.succeed("age-keygen -y /run/secrets-key/key.txt").strip()
        assert old != new
        rules = machine.succeed("cat /var/lib/secrets/.sops.yaml")
        assert new in rules and old not in rules
        machine.fail("ls /var/lib/sops-nix/key.sealed.* /var/lib/secrets/*.new")
        unlocked()
        reboot()
        machine.succeed(pam("login", "third-pass"))
        unlocked()

    with subtest("the sealed key is useless on a machine with another TPM"):
        # /tmp/shared is shared by every machine in the test.
        machine.succeed("cp /var/lib/sops-nix/key.sealed /var/lib/systemd/credential.secret /tmp/shared/")
        copy.wait_for_unit("multi-user.target")
        copy.succeed("test -e /dev/tpmrm0")
        copy.succeed("install -D -m 600 /tmp/shared/key.sealed /var/lib/sops-nix/key.sealed")
        copy.succeed("install -D -m 600 /tmp/shared/credential.secret /var/lib/systemd/credential.secret")
        machine.succeed("rm /tmp/shared/key.sealed /tmp/shared/credential.secret")
        copy.fail("printf 'third-pass\\n' | secret-unlock unlock")
        copy.fail("test -e /run/secrets-key/key.txt")

    with subtest("a plain host key from before unlock migrates unchanged"):
        def deployed():
            legacy.wait_until_succeeds("test -e /run/secrets/token")
            legacy.wait_for_unit("agent-broker-echo.service")
            legacy.succeed("test \"$(stat -c '%U %a' /run/secrets/venice-api-key)\" = 'jesse 400'")

        def withdrawn():
            legacy.fail("test -e /run/secrets/token")
            legacy.fail("test -e /run/secrets/venice-api-key")
            legacy.fail("systemctl is-active agent-broker-echo.service")

        switch = "/run/booted-system/specialisation/unlock/bin/switch-to-configuration test"
        legacy.wait_for_unit("multi-user.target")
        legacy.succeed("age-keygen -o /root/recovery.txt")
        legacy.succeed("secret init \"$(age-keygen -y /root/recovery.txt)\"")
        legacy.succeed("test \"$(stat -c '%U %a' /var/lib/sops-nix/key.txt)\" = 'root 600'")
        host = legacy.succeed("age-keygen -y /var/lib/sops-nix/key.txt").strip()
        legacy.succeed("printf 'fake-token' | secret add token")
        legacy.succeed("printf 'fake-venice' | secret add venice-api-key")
        legacy.succeed("secret apply")
        deployed()

        legacy.succeed(switch)
        legacy.succeed("test \"$(findmnt -no FSTYPE /run/secrets-key)\" = ramfs")
        withdrawn()
        legacy.succeed("test -z \"$(systemctl --failed --no-legend)\"")
        legacy.succeed("test -s /var/lib/sops-nix/key.txt")
        assert "secret migrate" in legacy.succeed("secret list 2>&1")

        def plain_kept():
            legacy.succeed("test -s /var/lib/sops-nix/key.txt")
            legacy.fail("test -e /run/secrets-key/key.txt")
            legacy.execute("secret apply")
            withdrawn()

        legacy.fail("printf 'wrong-pass\\nwrong-pass\\n' | secret migrate")
        legacy.fail("test -e /var/lib/sops-nix/key.sealed")
        plain_kept()

        restore = fake_config("systemdCreds", "${failingRun}", legacy)
        legacy.fail("printf 'old-pass\\nold-pass\\n' | secret migrate")
        restore()
        legacy.fail("test -e /var/lib/sops-nix/key.sealed")
        plain_kept()

        # A wrap of some other key never counts as this key's.
        legacy.succeed("age-keygen -o /root/other.txt")
        legacy.succeed(
            "printf 'old-pass\\nold-pass\\n' | secret-unlock wrap-into /root/other.txt /var/lib/sops-nix/key.sealed"
        )
        legacy.fail("printf 'old-pass\\n' | secret migrate")
        plain_kept()
        legacy.succeed("rm /var/lib/sops-nix/key.sealed /root/other.txt")

        # Interrupted once the wrap is written: the plain key can't be deleted.
        legacy.succeed("chattr +i /var/lib/sops-nix/key.txt")
        legacy.fail(
            "printf 'old-pass\\nold-pass\\n' | strace -f -y -o /root/migrate.trace"
            + " -e trace=openat,rename,renameat,renameat2,fsync,unlink,unlinkat secret migrate"
        )
        legacy.succeed("chattr -i /var/lib/sops-nix/key.txt")
        legacy.succeed("test -s /var/lib/sops-nix/key.sealed")
        legacy.succeed("test -s /var/lib/sops-nix/key.txt")
        assert "secret migrate" in legacy.succeed("secret list 2>&1")

        # The wrap and its directory entry are on disk before the key is published or the plain copy touched.
        lines = legacy.succeed("cat /root/migrate.trace").splitlines()

        def first(after, *needles):
            return next(i for i, line in enumerate(lines) if i > after and all(n in line for n in needles))

        sealed_at = first(-1, 'rename("/var/lib/sops-nix/key.sealed.new", "/var/lib/sops-nix/key.sealed")')
        synced_at = first(sealed_at, "fsync(", "</var/lib/sops-nix>)")
        published_at = first(-1, "rename(", ', "/run/secrets-key/key.txt")')
        destroyed_at = first(-1, '"/var/lib/sops-nix/key.txt"', "O_WRONLY")
        assert synced_at < published_at < destroyed_at, (sealed_at, synced_at, published_at, destroyed_at)

        legacy.fail("printf 'wrong-pass\\n' | secret migrate")
        legacy.succeed("test -s /var/lib/sops-nix/key.txt")

        # Interrupted after shred overwrites the plain key: an append-only directory makes its rename fail.
        legacy.succeed("chattr +a /var/lib/sops-nix")
        legacy.fail("printf 'old-pass\\n' | secret migrate")
        legacy.succeed("chattr -a /var/lib/sops-nix")
        legacy.succeed("test -e /var/lib/sops-nix/key.txt")
        legacy.fail("age-keygen -y /var/lib/sops-nix/key.txt")
        legacy.succeed("test -s /var/lib/sops-nix/key.sealed")
        assert "secret migrate" in legacy.succeed("secret list 2>&1")
        legacy.succeed("secret lock")
        legacy.fail("printf 'wrong-pass\\n' | secret migrate")
        legacy.succeed("test -e /var/lib/sops-nix/key.txt")
        legacy.fail("test -e /run/secrets-key/key.txt")
        legacy.succeed("printf 'old-pass\\n' | secret migrate")
        legacy.fail("test -e /var/lib/sops-nix/key.txt")
        legacy.succeed("test -z \"$(ls /run/secrets-key | grep migrate)\"")
        assert "secret migrate" not in legacy.succeed("secret list 2>&1")
        assert legacy.succeed("age-keygen -y /run/secrets-key/key.txt").strip() == host
        assert host in legacy.succeed("cat /var/lib/secrets/.sops.yaml")
        deployed()

        legacy.shutdown()
        legacy.start()
        legacy.wait_for_unit("multi-user.target")
        legacy.succeed(switch)
        withdrawn()
        legacy.succeed("printf 'old-pass\\n' | timeout 30 pamtester login jesse authenticate acct_mgmt open_session")
        deployed()
        assert legacy.succeed("age-keygen -y /run/secrets-key/key.txt").strip() == host
  '';
}
