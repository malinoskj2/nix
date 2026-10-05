import os
import pathlib
import shutil
import subprocess
import tempfile

binary = pathlib.Path("engine-test").resolve()
base = {
    key: value
    for key, value in os.environ.items()
    if not key.startswith("GAME_BACKGROUND_") and key not in ("SteamAppId", "SteamGameId", "LD_PRELOAD")
}


def check(expected, executable=binary, **values):
    result = subprocess.check_output([str(executable), "--guard"], env=base | values, text=True)
    assert result.strip() == expected, (values, result)


check("0 0")
check("0 0", GAME_BACKGROUND_LIMIT_AUTO="1", SteamAppId="0")
check("0 0", GAME_BACKGROUND_LIMIT_AUTO="1", SteamAppId="12x")
check("1 32", GAME_BACKGROUND_LIMIT_AUTO="1", SteamAppId="730")
check("1 32", GAME_BACKGROUND_LIMIT_AUTO="1", SteamGameId="123456789123456789")
check("0 0", GAME_BACKGROUND_LIMIT_AUTO="1", SteamAppId="730", GAME_BACKGROUND_LIMIT="0")
check("1 32", GAME_BACKGROUND_FORCE="1")
check("0 0", GAME_BACKGROUND_FORCE="1", GAME_BACKGROUND_LIMIT="0")
check("0 32", GAME_BACKGROUND_FORCE="1", GAME_BACKGROUND_LIMIT_SOCKET="/" + "a" * 120)
with tempfile.TemporaryDirectory() as directory:
    helper = pathlib.Path(directory) / "steamwebhelper"
    shutil.copy2(binary, helper)
    check("0 0", helper, GAME_BACKGROUND_LIMIT_AUTO="1", SteamAppId="730")
print("early graphics initialization, automatic guards and helper exclusions passed")
