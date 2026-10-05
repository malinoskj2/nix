import asyncio
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import tomlkit

spec = importlib.util.spec_from_file_location("unreal", Path(__file__).with_name("unreal-sandbox.py"))
unreal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(unreal)


class UnrealSandboxTests(unittest.TestCase):
    def test_refresh_preserves_config_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, HOME=directory):
            home = Path(directory)
            codex = home / ".codex/config.toml"
            unreal.write(
                codex,
                '# personal settings\nmodel = "custom"\n[projects."/project"]\ntrust_level = "trusted"\n[mcp_servers.other]\ncommand = "other"\n[mcp_servers.unreal-mcp]\ncommand = "obsolete"\n',
            )
            zcode = home / ".zcode/cli/config.json"
            unreal.write_json(
                zcode, {"logging": {"level": "debug"}, "mcp": {"servers": {"other": {"command": "other"}}}}
            )
            unreal.sync_harnesses()
            first = codex.read_text(), zcode.read_text()
            unreal.sync_harnesses()
            self.assertEqual(first, (codex.read_text(), zcode.read_text()))
            data = tomlkit.parse(first[0])
            self.assertIn("# personal settings", first[0])
            self.assertEqual(data["model"], "custom")
            self.assertEqual(data["projects"]["/project"]["trust_level"], "trusted")
            self.assertEqual(data["mcp_servers"]["other"]["command"], "other")
            self.assertNotIn("command", data["mcp_servers"]["unreal-mcp"])
            self.assertEqual(json.loads(first[1])["logging"]["level"], "debug")
            self.assertEqual(json.loads(first[1])["mcp"]["servers"]["unreal-mcp"]["type"], "http")

    def test_prepare_preserves_project_and_ini_preferences(self):
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()):
            project = Path(directory) / "Game.uproject"
            unreal.write_json(
                project,
                {
                    "Modules": [{"Name": "Game"}],
                    "Plugins": [{"Name": "Other", "Enabled": True}, {"Name": "ModelContextProtocol", "Enabled": False}],
                },
            )
            ini = project.parent / "Saved/Config/LinuxEditor/EditorPerProjectUserSettings.ini"
            unreal.write(
                ini,
                "[Other]\nOption=Keep\n[/Script/ModelContextProtocolEngine.ModelContextProtocolSettings]\nbAutoStartServer=False\nUnrelated=Keep\n[After]\nOption=Keep\n",
            )
            unreal.prepare(project)
            first = project.read_text(), ini.read_text()
            unreal.prepare(project)
            self.assertEqual(first, (project.read_text(), ini.read_text()))
            data = json.loads(first[0])
            self.assertEqual(data["Modules"], [{"Name": "Game"}])
            self.assertEqual(len(data["Plugins"]), 3)
            self.assertTrue(all(p["Enabled"] for p in data["Plugins"]))
            self.assertIn("Unrelated=Keep", first[1])
            self.assertIn("[After]\nOption=Keep", first[1])
            self.assertEqual(first[1].count("bAutoStartServer=True"), 1)

    def test_engine_rejects_old_build_and_missing_toolsets(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, UE_ROOT=directory):
            root = Path(directory)
            unreal.write(root / "Engine/Binaries/Linux/UnrealEditor", "fixture")
            version = root / "Engine/Build/Build.version"
            unreal.write_json(version, {"MajorVersion": 5, "MinorVersion": 7})
            with self.assertRaisesRegex(RuntimeError, "5.8"):
                unreal.engine_root()
            unreal.write_json(version, {"MajorVersion": 5, "MinorVersion": 8})
            unreal.write(root / "Engine/Plugins/Experimental/ModelContextProtocol/ModelContextProtocol.uplugin", "{}")
            with self.assertRaisesRegex(RuntimeError, "AllToolsets"):
                unreal.engine_root()

    def test_live_http_handshake_and_read_only_call(self):
        # Exercise the real MCP SDK against a local protocol fixture, not an editor.
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        code = f"""
from mcp.server.fastmcp import FastMCP
server = FastMCP("test-unreal", host="127.0.0.1", port={port})
@server.tool()
def list_toolsets() -> list[str]:
    return ["ActorTools", "SceneTools"]
server.run(transport="streamable-http")
"""
        with subprocess.Popen(
            [sys.executable, "-c", code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ) as server:
            try:
                for _ in range(100):
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        if server.poll() is not None:
                            self.fail("MCP fixture failed to start")
                        time.sleep(0.05)
                output = io.StringIO()
                with patch.object(unreal, "URL", f"http://127.0.0.1:{port}/mcp"), redirect_stdout(output):
                    asyncio.run(asyncio.wait_for(unreal.check_mcp(), timeout=10))
                self.assertIn("ActorTools", output.getvalue())
                self.assertIn("Unreal MCP verified", output.getvalue())
            finally:
                server.terminate()
                server.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
