{ inputs, pkgs }:
let
  probe = pkgs.dockerTools.buildImage {
    name = "egress-probe";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "egress-probe-root";
      paths = [
        pkgs.busybox
        pkgs.curl
        pkgs.socat
      ];
    };
  };
in
{
  name = "agent-egress";

  node.specialArgs = { inherit inputs; };

  nodes.outside = {
    networking.firewall.enable = false;
    systemd.services.web = {
      wantedBy = [ "multi-user.target" ];
      script = "exec ${pkgs.python3}/bin/python3 -m http.server 8000 --bind 0.0.0.0 --directory /etc";
    };
    systemd.services.web-lan = {
      wantedBy = [ "multi-user.target" ];
      script = "exec ${pkgs.python3}/bin/python3 -m http.server 8001 --bind 0.0.0.0 --directory /etc";
    };
  };

  nodes.machine = {
    imports = [
      ./agent-broker.nix
      ./agent-egress.nix
      ./docker.nix
    ];

    virtualisation.memorySize = 2048;

    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
      pkgs.nftables
      pkgs.openssl
      pkgs.python3
      pkgs.socat
    ];

    users.users = {
      jesse = {
        isNormalUser = true;
        extraGroups = [ "docker" ];
      };
      other.isNormalUser = true;
    };

    agentBroker = {
      clients = [ "jesse" ];
      egress = {
        enable = true;
        allow = [ "allowed.test:8000" ];
        allowPrivate = [
          "192.168.1.2:8000"
          "lan.test:8001"
        ];
      };
    };

    networking.hosts = {
      "192.168.1.2" = [
        "allowed.test"
        "unlisted.test"
        "lan.test"
      ];
      "::ffff:192.168.1.1" = [ "mapped.test" ];
    };
  };

  testScript = ''
    import json
    import shlex

    def as_user(user, cmd):
        return f"su -s /bin/sh {user} -c {shlex.quote(cmd)}"

    def control(user, request):
        script = (
            "import json, socket, sys; s = socket.socket(socket.AF_UNIX); "
            "s.connect('/run/agent-broker/egress-gate/control.sock'); "
            "s.sendall(sys.argv[1].encode() + b'\\n'); print(s.makefile().readline())"
        )
        return json.loads(machine.succeed(as_user(user, f"python3 -c {shlex.quote(script)} {shlex.quote(json.dumps(request))}")))

    def raw(request):
        script = (
            "import socket, sys; s = socket.create_connection(('127.0.0.1', 13128)); "
            "s.sendall(sys.argv[1].encode()); print(s.recv(200).decode().split(chr(13))[0])"
        )
        return machine.succeed(f"python3 -c {shlex.quote(script)} {shlex.quote(request)}").strip()

    def records():
        lines = machine.succeed("journalctl -u agent-broker-egress-proxy.service -o cat").splitlines()
        return [json.loads(line) for line in lines if line.startswith("{")]

    outside.wait_for_open_port(8000)
    outside.wait_for_open_port(8001)
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("agent-broker-egress-proxy.service")
    machine.wait_for_unit("agent-broker-egress-gate.service")
    machine.wait_for_unit("agent-broker-push.service")
    machine.wait_for_file("/run/agent-broker/egress-gate/control.sock")
    machine.wait_for_open_port(3128, "127.0.0.1")

    with subtest("the host boots with every unit up"):
        machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
        machine.succeed("systemctl is-active agent-sandbox-netfilter.service agent-sandbox-network.service")

    with subtest("the CA's key stays with agent-broker and only its certificate is published"):
        machine.succeed("test \"$(stat -c '%a' /run/agent-broker/egress-proxy/ca.pem)\" = 644")
        machine.succeed(as_user("jesse", "openssl x509 -noout -in /run/agent-broker/egress-proxy/ca.pem"))
        machine.fail(as_user("jesse", "ls /var/lib/agent-broker-egress/mitmproxy"))
        machine.fail(as_user("jesse", "grep -l PRIVATE /run/agent-broker/egress-proxy/ca.pem"))

    with subtest("the sandbox network is internal and its bridge is filtered"):
        network = json.loads(machine.succeed("docker network inspect agent-sandbox"))[0]
        assert network["Internal"] is True, network
        assert network["Options"]["com.docker.network.bridge.name"] == "br-asb", network
        machine.succeed("nft list table inet agent_sandbox | grep -q br-asb")
        gateway = network["IPAM"]["Config"][0]["Gateway"]

    machine.succeed("python3 -m http.server 8000 --bind 0.0.0.0 --directory /etc >/dev/null 2>&1 &")
    machine.wait_for_open_port(8000)
    machine.succeed("sleep infinity >/dev/null 2>&1 & echo $! > /tmp/launcher.pid")
    pid = int(machine.succeed("cat /tmp/launcher.pid"))

    with subtest("only broker clients register sandboxes"):
        assert not control("other", {"op": "register", "name": "sbx-other", "pid": pid})["ok"]
        reply = control("jesse", {"op": "register", "name": "sbx-test", "pid": pid})
        assert reply["ok"], reply
        machine.succeed("test \"$(stat -c '%G %a' /run/agent-broker/egress-gate/sandbox/sbx-test)\" = 'agent-broker-clients 2750'")
        machine.fail(as_user("other", "ls /run/agent-broker/egress-gate/sandbox/sbx-test"))

    machine.succeed(as_user("jesse", "socat TCP-LISTEN:13128,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/agent-broker/egress-gate/sandbox/sbx-test/proxy.sock >/dev/null 2>&1 &"))
    machine.wait_for_open_port(13128, "127.0.0.1")
    via_sandbox = "curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:13128 "

    with subtest("log mode lets unlisted hosts through and records them"):
        assert machine.succeed(via_sandbox + "http://allowed.test:8000/hostname") == "200"
        assert machine.succeed(via_sandbox + "http://unlisted.test:8000/hostname") == "200"
        decisions = {(r.get("sandbox"), r.get("host"), r.get("decision")) for r in records()}
        assert ("sbx-test", "allowed.test", "allow") in decisions, decisions
        assert ("sbx-test", "unlisted.test", "would-deny") in decisions, decisions

    with subtest("the host's own addresses are refused even in log mode"):
        assert machine.succeed(via_sandbox + "http://127.0.0.1:8000/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://localhost:8000/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://192.168.1.1:8000/hostname") == "502"
        assert machine.succeed(via_sandbox + f"http://{gateway}:8000/hostname") == "502"
        for target in ("[::ffff:192.168.1.1]", "[::ffff:c0a8:101]", "[::192.168.1.1]", "[::ffff:127.0.0.1]", "mapped.test", "3232235777"):
            assert machine.succeed(via_sandbox + f"http://{target}:8000/hostname") == "502", target
        assert ("sbx-test", "192.168.1.1", "deny-internal") in {(r.get("sandbox"), r.get("host"), r.get("decision")) for r in records()}

    with subtest("private addresses need an allowPrivate entry, even in log mode"):
        assert machine.succeed(via_sandbox + "http://lan.test:8001/hostname") == "200"
        assert machine.succeed(via_sandbox + "http://allowed.test:8001/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://192.168.1.2:8001/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://[::ffff:192.168.1.2]:8001/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://[64:ff9b::c0a8:102]:8001/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://10.20.30.40:8000/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://169.254.169.254/latest/meta-data/") == "502"
        decisions = {(r.get("sandbox"), r.get("host"), r.get("decision")) for r in records()}
        assert ("sbx-test", "allowed.test", "deny-private") in decisions, decisions
        assert ("sbx-test", "10.20.30.40", "deny-private") in decisions, decisions
        assert ("sbx-test", "169.254.169.254", "deny-internal") in decisions, decisions

    with subtest("a sandbox reaches its own and its siblings' preview ports on the host, and no other sandbox's"):
        machine.succeed("sleep infinity >/dev/null 2>&1 & echo $! > /tmp/preview-launcher.pid")
        reply = control("jesse", {"op": "register", "name": "sbx-preview", "pid": int(machine.succeed("cat /tmp/preview-launcher.pid")), "preview": {"address": "192.168.1.1", "ports": [8000]}})
        assert reply["ok"], reply
        machine.succeed(as_user("jesse", "socat TCP-LISTEN:13129,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/agent-broker/egress-gate/sandbox/sbx-preview/proxy.sock >/dev/null 2>&1 &"))
        machine.wait_for_open_port(13129, "127.0.0.1")
        own = "curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:13129 "
        assert machine.succeed(own + "http://192.168.1.1:8000/hostname") == "200"
        assert machine.succeed(own + "http://[::ffff:192.168.1.1]:8000/hostname") == "502"
        assert machine.succeed(via_sandbox + "http://192.168.1.1:8000/hostname") == "502"
        control("jesse", {"op": "unregister", "name": "sbx-preview"})
        child = {"op": "register", "name": "sbx-child", "pid": pid, "owner": "sbx-test", "preview": {"address": "192.168.1.1", "ports": [8000]}}
        assert control("jesse", child)["ok"]
        assert machine.succeed(via_sandbox + "http://192.168.1.1:8000/hostname") == "200"
        assert machine.succeed(via_sandbox + "http://192.168.1.1:8001/hostname") == "502"
        control("jesse", {"op": "unregister", "name": "sbx-child"})
        assert machine.succeed(via_sandbox + "http://192.168.1.1:8000/hostname") == "502"

    with subtest("the Host header can't redirect a request past the allowlist"):
        assert machine.succeed(via_sandbox + "-H 'Host: allowed.test:8000' http://unlisted.test:8000/hostname") == "421"
        assert raw("GET https://allowed.test:8000/ HTTP/1.1\r\nHost: allowed.test:8000\r\n\r\n") == "HTTP/1.1 403 Forbidden"
        decisions = {(r.get("sandbox"), r.get("host"), r.get("decision")) for r in records()}
        assert ("sbx-test", "unlisted.test", "deny-misdirected") in decisions, decisions
        assert ("sbx-test", "allowed.test", "deny-absolute-https") in decisions, decisions

    with subtest("connections that don't come through a sandbox's socket are refused"):
        assert machine.succeed(as_user("other", "curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:3128 http://allowed.test:8000/hostname")) == "403"
        assert machine.succeed(as_user("other", "python3 -c 'import socket; s = socket.socket(); s.bind((\"127.77.0.2\", 0)); s.connect((\"127.0.0.1\", 3128)); s.sendall(b\"GET http://allowed.test:8000/hostname HTTP/1.1\\r\\nHost: allowed.test:8000\\r\\n\\r\\n\"); print(s.recv(12).decode())'")).strip() == "HTTP/1.1 403"

    with subtest("agent-egress report proposes the unlisted host"):
        machine.succeed("journalctl --sync")
        report = machine.succeed("agent-egress report --nix --since '1 hour ago'")
        assert '"unlisted.test:8000"' in report and "allowed.test" not in report, report

    with subtest("enforce mode denies unlisted hosts after a runtime allow expires"):
        original = machine.succeed("readlink /etc/agent-broker/egress.json").strip()
        machine.succeed("jq '.mode = \"enforce\"' /etc/agent-broker/egress.json > /var/lib/egress-enforce.json")
        machine.succeed("ln -sfn /var/lib/egress-enforce.json /etc/agent-broker/egress.json")
        machine.wait_until_succeeds(via_sandbox + "http://unlisted.test:8000/hostname | grep -qx 403")
        assert machine.succeed(via_sandbox + "http://allowed.test:8000/hostname") == "200"
        machine.succeed("agent-egress allow unlisted.test:8000 --for 1h")
        assert machine.succeed(via_sandbox + "http://unlisted.test:8000/hostname") == "200"
        machine.succeed("agent-egress revoke unlisted.test:8000")
        assert machine.succeed(via_sandbox + "http://unlisted.test:8000/hostname") == "403"
        machine.succeed(f"ln -sfn {original} /etc/agent-broker/egress.json")

    with subtest("a container on the sandbox network gets out only through its socket"):
        machine.succeed("docker load < ${probe}")
        gid = machine.succeed("getent group agent-broker-clients | cut -d: -f3").strip()
        uid = machine.succeed("id -u jesse").strip()
        machine.succeed("sleep infinity >/dev/null 2>&1 & echo $! > /tmp/container-launcher.pid")
        subnet = network["IPAM"]["Config"][0]["Subnet"]
        reply = control("jesse", {"op": "register", "name": "sbx-ctr", "pid": int(machine.succeed("cat /tmp/container-launcher.pid")), "networks": [subnet]})
        assert reply["ok"], reply
        machine.succeed(as_user("jesse", "mkdir -m 700 /tmp/ingress"))
        machine.succeed(
            f"docker run -d --name ctr --network agent-sandbox --user {uid}:100 --group-add {gid} "
            f"-v {reply['dir']}:/run/agent-egress:ro -v /tmp/ingress:/run/agent-ingress egress-probe:latest "
            "sh -c 'socat TCP-LISTEN:8080,bind=127.0.0.1,fork,reuseaddr SYSTEM:\"echo inside\" & "
            "socat UNIX-LISTEN:/run/agent-ingress/8080.sock,fork TCP:127.0.0.1:8080 & "
            "exec socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/agent-egress/proxy.sock'"
        )
        machine.wait_until_succeeds("docker exec ctr sh -c 'nc -z 127.0.0.1 3128'")
        assert machine.succeed("docker exec ctr curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:3128 http://allowed.test:8000/hostname") == "200"
        machine.fail("docker exec ctr curl -s -m 5 http://192.168.1.1:8000/hostname")
        machine.fail("docker exec ctr curl -s -m 5 http://192.168.1.2:8000/hostname")
        machine.fail(f"docker exec ctr curl -s -m 5 http://{gateway}:8000/hostname")
        assert ("sbx-ctr", "allowed.test", "allow") in {(r.get("sandbox"), r.get("host"), r.get("decision")) for r in records()}

    with subtest("through the proxy a sandbox reaches its own network's containers, and no other sandbox does"):
        machine.succeed("docker run -d --name sibling --network agent-sandbox egress-probe:latest sh -c 'mkdir -p /srv && echo sibling > /srv/index.html && exec httpd -f -p 8081 -h /srv'")
        sibling = machine.succeed("docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' sibling").strip()
        machine.wait_until_succeeds(f"docker exec ctr nc -z {sibling} 8081")
        assert machine.succeed(f"docker exec ctr curl -s -x http://127.0.0.1:3128 http://{sibling}:8081/").strip() == "sibling"
        assert machine.succeed(via_sandbox + f"http://{sibling}:8081/") == "502"
        assert ("sbx-test", sibling, "deny-private") in {(r.get("sandbox"), r.get("host"), r.get("decision")) for r in records()}
        machine.succeed("docker rm -f sibling")

    with subtest("a stack's networks are reachable through the proxy for their owner only, until it comes down"):
        machine.succeed("docker network create --internal --opt com.docker.network.bridge.name=br-asb-test stack-net")
        stack_subnet = json.loads(machine.succeed("docker network inspect stack-net"))[0]["IPAM"]["Config"][0]["Subnet"]
        machine.succeed("docker run -d --name service --network stack-net egress-probe:latest sh -c 'mkdir -p /srv && echo service > /srv/index.html && exec httpd -f -p 8082 -h /srv'")
        machine.succeed("docker network connect stack-net ctr")
        service = machine.succeed("docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' service").strip()
        machine.wait_until_succeeds(f"docker exec ctr nc -z {service} 8082")
        assert machine.succeed(f"docker exec ctr curl -s -o /dev/null -w '%{{http_code}}' -x http://127.0.0.1:3128 http://{service}:8082/") == "502"
        assert not control("other", {"op": "networks", "name": "sbx-ctr", "networks": [stack_subnet]})["ok"]
        assert control("jesse", {"op": "networks", "name": "sbx-ctr", "networks": [stack_subnet]})["ok"]
        assert machine.succeed(f"docker exec ctr curl -s -x http://127.0.0.1:3128 http://{service}:8082/").strip() == "service"
        assert machine.succeed(via_sandbox + f"http://{service}:8082/") == "502"
        assert control("jesse", {"op": "networks", "name": "sbx-ctr", "networks": []})["ok"]
        assert machine.succeed(f"docker exec ctr curl -s -o /dev/null -w '%{{http_code}}' -x http://127.0.0.1:3128 http://{service}:8082/") == "502"
        machine.succeed("docker rm -f service && docker network disconnect stack-net ctr && docker network rm stack-net")

    with subtest("published ports reach the container through its ingress socket"):
        machine.wait_for_file("/tmp/ingress/8080.sock")
        machine.succeed(as_user("jesse", "socat TCP-LISTEN:18080,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/tmp/ingress/8080.sock >/dev/null 2>&1 &"))
        machine.wait_for_open_port(18080, "127.0.0.1")
        assert machine.succeed("socat -T 5 - TCP:127.0.0.1:18080 </dev/null").strip() == "inside"
        machine.succeed("docker rm -f ctr")
        # Compose stacks keep their loopback ports: on internal networks, which must not fail to start.
        machine.succeed("docker run -d --name published --network agent-sandbox -p 127.0.0.1:18091:8080 egress-probe:latest sleep 60")
        machine.succeed("docker rm -f published")

    with subtest("a sandbox whose launcher exits loses its socket"):
        machine.succeed("kill $(cat /tmp/launcher.pid)")
        machine.succeed("systemctl restart agent-broker-egress-gate.service")
        machine.wait_for_file("/run/agent-broker/egress-gate/control.sock")
        machine.wait_until_fails("test -e /run/agent-broker/egress-gate/sandbox/sbx-test")
        assert "sbx-test" not in machine.succeed("cat /run/agent-broker/egress-gate/peers.json")

    with subtest("the push gateway refuses until the owner sets it up"):
        script = (
            "import json, socket; s = socket.socket(socket.AF_UNIX); s.connect('/run/agent-broker/push/push.sock'); "
            "s.sendall(json.dumps({'op': 'prepare', 'repo': 'owner/repo', 'branch': 'feature'}).encode() + b'\\n'); "
            "print(s.makefile().readline())"
        )
        reply = json.loads(machine.succeed(as_user("jesse", f"python3 -c {shlex.quote(script)}")))
        assert not reply["ok"] and "agentBroker.push.repos" in reply["error"], reply
  '';
}
