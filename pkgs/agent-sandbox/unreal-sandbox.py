"""Prepare and run Epic's Linux installed build inside the agent sandbox."""

import argparse
import asyncio
import builtins
from collections.abc import Iterator
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

import tomlkit

PORT = 8000
URL_PATH = "/mcp"
URL = os.environ.get("UNREAL_MCP_URL", f"http://127.0.0.1:{PORT}{URL_PATH}")
INSTALL_DIR = Path.home() / ".local/share/unreal-engine"
REQUIRED_PLUGINS = ("ModelContextProtocol", "AllToolsets")
MCP_SECTION = "[/Script/ModelContextProtocolEngine.ModelContextProtocolSettings]"
MCP_SETTINGS = {"bAutoStartServer": "True", "ServerPortNumber": str(PORT), "ServerUrlPath": URL_PATH}


def write(path: Path, content: str) -> None:
    """Replace atomically, preserving permissions and skipping unchanged content."""
    if path.exists() and path.read_text() == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as tmp:
        tmp.write(content)
    os.chmod(tmp.name, mode)
    os.replace(tmp.name, path)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text()) if path.exists() else {}


def write_json(path: Path, data: dict) -> None:
    write(path, json.dumps(data, indent=2) + "\n")


def sync_harnesses() -> None:
    home = Path.home()
    path = home / ".codex/config.toml"
    config = tomlkit.parse(path.read_text()) if path.exists() else tomlkit.document()
    config.setdefault("mcp_servers", {})["unreal-mcp"] = {
        "enabled": False,
        "url": URL,
        "startup_timeout_sec": 30,
        "tool_timeout_sec": 120,
    }
    write(path, tomlkit.dumps(config))


def engine_root() -> Path:
    return checked_engine(Path(os.environ.get("UE_ROOT", INSTALL_DIR / "current")).expanduser())


def checked_engine(root: Path) -> Path:
    editor = root / "Engine/Binaries/Linux/UnrealEditor"
    if not editor.is_file():
        raise RuntimeError(
            f"No UnrealEditor at {editor}. Install Epic's UE 5.8+ Linux ZIP with "
            "`unreal-sandbox install /path/to/Linux.zip`, or set UE_ROOT to an "
            "extracted build inside a shared directory."
        )
    version = load_json(root / "Engine/Build/Build.version")
    if (version.get("MajorVersion", 0), version.get("MinorVersion", 0)) < (5, 8):
        raise RuntimeError("Epic's native MCP requires Unreal Engine 5.8 or newer.")
    for name in REQUIRED_PLUGINS:
        if not any((root / "Engine/Plugins").rglob(f"{name}.uplugin")):
            raise RuntimeError(f"This engine build is missing the {name} plugin.")
    return root.resolve()


def install(archive: Path) -> None:
    archive = archive.resolve()
    if not archive.is_file() or not zipfile.is_zipfile(archive):
        raise RuntimeError("Provide the Linux installed-build ZIP downloaded from Epic.")
    target = INSTALL_DIR / archive.stem
    if target.exists():
        raise RuntimeError(f"Installation directory already exists: {target}")
    with zipfile.ZipFile(archive) as bundle:
        for info in bundle.infolist():
            path = Path(info.filename)
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError(f"Unsafe archive path: {info.filename}")
    target.mkdir(parents=True)
    # unzip preserves executable modes and symlinks used by the bundled toolchain.
    subprocess.run(["unzip", "-q", str(archive), "-d", str(target)], check=True)
    roots = [target, *[p for p in target.iterdir() if p.is_dir()]]
    root = next((p for p in roots if (p / "Engine/Binaries/Linux/UnrealEditor").is_file()), None)
    if root is None:
        raise RuntimeError(f"ZIP has no Linux UnrealEditor; extracted files remain at {target}")
    checked_engine(root)
    link = INSTALL_DIR / "current"
    temporary = INSTALL_DIR / f".current-{os.getpid()}"
    temporary.symlink_to(root)
    os.replace(temporary, link)
    print(f"Installed {root}; default build: {link}")


def enable_plugins(data: dict) -> None:
    plugins = data.setdefault("Plugins", [])
    for name in REQUIRED_PLUGINS:
        entry = next((p for p in plugins if p["Name"] == name), None)
        if entry is None:
            entry = {"Name": name}
            plugins.append(entry)
        entry["Enabled"] = True


def with_mcp_settings(lines: list[str]) -> list[str]:
    """Set the MCP settings without rewriting unrelated ini sections or keys."""
    settings = [f"{key}={value}" for key, value in MCP_SETTINGS.items()]
    result, in_section, found = [], False, False
    for line in lines:
        if line.strip().startswith("["):
            if in_section:
                result.extend(settings)
            in_section = line.strip() == MCP_SECTION
            found |= in_section
        if in_section and line.split("=", 1)[0].strip() in MCP_SETTINGS:
            continue
        result.append(line)
    if not found:
        result.extend(["", MCP_SECTION])
    if in_section or not found:
        result.extend(settings)
    return result


def prepare(project: Path, create: bool = False) -> Path:
    project = project.expanduser().resolve()
    if project.suffix != ".uproject":
        raise RuntimeError("Provide an explicit .uproject path.")
    if project.exists():
        data = load_json(project)
    elif create:
        data = {"FileVersion": 3, "EngineAssociation": "", "Category": "", "Description": ""}
    else:
        raise RuntimeError(f"Project does not exist: {project}; use `unreal-sandbox init`.")
    enable_plugins(data)
    write_json(project, data)
    ini = project.parent / "Saved/Config/LinuxEditor/EditorPerProjectUserSettings.ini"
    lines = ini.read_text().splitlines() if ini.exists() else []
    write(ini, "\n".join(with_mcp_settings(lines)) + "\n")
    print(f"Prepared {project}")
    return project


def runtime_environment() -> dict[str, str]:
    env = dict(os.environ)
    libraries = env.get("UNREAL_RUNTIME_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = libraries + ":" + env.get("LD_LIBRARY_PATH", "")
    # Discover the ICD explicitly: Nix's driver is not under /usr/share/vulkan.
    icd = Path("/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json")
    if icd.exists():
        env.setdefault("VK_DRIVER_FILES", str(icd))
    return env


def run_editor(project: Path, args: list[str]) -> None:
    root = engine_root()
    project = prepare(project)
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    subprocess.run(["swaymsg", "-t", "get_version"], check=True, stdout=subprocess.DEVNULL)
    env = runtime_environment()
    env["SDL_VIDEODRIVER"] = "x11"
    sockets = sorted(Path("/tmp/.X11-unix").glob("X*"))
    if "DISPLAY" not in env:
        if len(sockets) != 1:
            raise RuntimeError("Cannot identify the sandbox Xwayland display; set DISPLAY explicitly.")
        env["DISPLAY"] = ":" + sockets[0].name[1:]
    cache = Path.home() / ".cache/unreal-engine"
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "Temporary").mkdir(exist_ok=True)
    env["TMPDIR"] = str(cache / "Temporary")
    env["UE-LocalDataCachePath"] = str(cache / "DerivedDataCache")
    # Hold the port reservation for the editor lifetime, including after exec.
    lock = os.open(runtime / "unreal-editor.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        raise RuntimeError("An Unreal editor is already running in this sandbox.") from error
    os.set_inheritable(lock, True)
    command = [
        str(root / "Engine/Binaries/Linux/UnrealEditor"),
        str(project),
        "-vulkan",
        "-ModelContextProtocolStartServer",
        f"-ModelContextProtocolPort={PORT}",
        "-unattended",
        "-nosplash",
        *args,
    ]
    print("Editor MCP: " + URL, flush=True)
    os.execve(command[0], command, env)


def run_uat(args: list[str]) -> None:
    script = engine_root() / "Engine/Build/BatchFiles/RunUAT.sh"
    os.execve("/bin/bash", ["bash", str(script), *args], runtime_environment())


async def check_mcp() -> None:
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    async with streamable_http_client(URL) as (reader, writer, _):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = {t.name for t in tools.tools}
            if "list_toolsets" not in names:
                raise RuntimeError(f"No list_toolsets tool: {sorted(names)}. Enable AllToolsets.")
            result = await session.call_tool("list_toolsets", {})
            if result.isError:
                raise RuntimeError(f"Unreal read-only MCP call failed: {result}")
            print(result.model_dump_json(indent=2))
            print(f"Unreal MCP verified at {URL}")


def mcp_check() -> None:
    asyncio.run(asyncio.wait_for(check_mcp(), timeout=30))


def doctor() -> None:
    print(f"Engine: {engine_root()}", flush=True)
    for command in (["nvidia-smi"], ["vulkaninfo", "--summary"], ["swaymsg", "-t", "get_version"]):
        subprocess.run(command, check=True, env=runtime_environment())
    mcp_check()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("sync-harnesses", help="Refresh the Unreal MCP entry in Codex")
    sub.add_parser("doctor", help="Check the engine, GPU, display and live MCP tools")
    sub.add_parser("mcp-check", help="Make a read-only call to the running editor")
    sub.add_parser("install", help="Extract Epic's Linux installed build").add_argument("archive", type=Path)
    sub.add_parser("init").add_argument("project", type=Path)
    sub.add_parser("prepare").add_argument("project", type=Path)
    editor = sub.add_parser("editor")
    editor.add_argument("project", type=Path)
    editor.add_argument("args", nargs=argparse.REMAINDER)
    sub.add_parser("uat", help="Run the bundled automation tool").add_argument("args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    match args.command:
        case "sync-harnesses":
            sync_harnesses()
        case "doctor":
            doctor()
        case "mcp-check":
            mcp_check()
        case "install":
            install(args.archive)
        case "init" | "prepare":
            prepare(args.project, create=args.command == "init")
        case "editor":
            run_editor(args.project, args.args)
        case "uat":
            run_uat(args.args)


def exception_messages(group: builtins.ExceptionGroup) -> Iterator[str]:
    for cause in group.exceptions:
        if isinstance(cause, builtins.ExceptionGroup):
            yield from exception_messages(cause)
        else:
            yield str(cause)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, TimeoutError) as error:
        sys.exit(f"unreal-sandbox: {error}")
    except builtins.ExceptionGroup as error:
        sys.exit("unreal-sandbox: MCP check failed: " + "; ".join(exception_messages(error)))
