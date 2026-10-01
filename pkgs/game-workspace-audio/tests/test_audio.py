import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from game_workspace_audio import Controller, hidden_games, process_game, streams


def window(app="42", workspace=5, pid=123):
    return {"class": "steam_app_" + app, "pid": pid, "workspace": {"id": workspace}}


def stream(identity="10", key="game", mute=False, app="42", node=20):
    return {identity: {"id": node, "key": key, "app": app, "mute": mute}}


class AudioTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "mute.json"
        self.calls = []
        self.controller = Controller(self.path, lambda node, mute: self.calls.append((node, mute)))

    def tearDown(self):
        self.directory.cleanup()

    def test_hidden_on_start_and_return(self):
        self.controller.reconcile(stream(), {"42"})
        self.assertEqual(self.calls, [(20, True)])
        self.controller.reconcile(stream(mute=True), set())
        self.assertEqual(self.calls, [(20, True), (20, False)])
        self.assertEqual(self.controller.saved, {})

    def test_new_stream_while_hidden(self):
        self.controller.reconcile({}, {"42"})
        self.controller.reconcile(stream(), {"42"})
        self.assertEqual(self.calls, [(20, True)])

    def test_manual_premute_is_preserved(self):
        self.controller.reconcile(stream(mute=True), {"42"})
        self.controller.reconcile(stream(mute=True), set())
        self.assertEqual(self.calls, [])

    def test_mixed_manual_mutes_on_same_application(self):
        current = stream() | stream(identity="11", mute=True, node=21)
        self.controller.reconcile(current, {"42"})
        current["10"]["mute"] = True
        self.controller.reconcile(current, set())
        self.assertEqual(self.calls, [(20, True), (20, False)])

    def test_recreated_stream_remembered_by_wireplumber(self):
        self.controller.reconcile(stream(), {"42"})
        self.controller.reconcile({}, {"42"})
        new = stream(identity="11", mute=True, node=21)
        self.controller.reconcile(new, {"42"})
        self.controller.reconcile(new, set())
        self.assertEqual(self.calls, [(20, True), (21, False)])

    def test_game_exit_hidden_and_restart(self):
        self.controller.reconcile(stream(), {"42"})
        self.controller.reconcile({}, set())
        restarted = Controller(self.path, lambda node, mute: self.calls.append((node, mute)))
        restarted.reconcile(stream(identity="new-core", mute=True, node=21), set())
        self.assertEqual(self.calls, [(20, True), (21, False)])

    def test_daemon_restart_recovers_existing_mute(self):
        self.controller.reconcile(stream(), {"42"})
        restarted = Controller(self.path, lambda node, mute: self.calls.append((node, mute)))
        restarted.reconcile(stream(mute=True), set())
        self.assertEqual(self.calls, [(20, True), (20, False)])

    def test_reused_node_for_unrelated_game_is_untouched(self):
        self.controller.reconcile(stream(), {"42"})
        self.controller.reconcile(stream(identity="new", key="other-game", app="99", mute=True), set())
        self.assertEqual(self.calls, [(20, True)])

    def test_ownership_is_journaled_before_mute_failure(self):
        def fail(_node, _mute):
            raise OSError("audio server disappeared")

        controller = Controller(self.path, fail)
        with self.assertRaises(OSError):
            controller.reconcile(stream(), {"42"})
        self.assertTrue(Controller(self.path).saved)

    def test_changed_identity_aborts_before_wpctl(self):
        controller = Controller(self.path)
        with (
            patch("game_workspace_audio.command", return_value=b"[]") as run,
            patch("game_workspace_audio.streams", return_value={}),
        ):
            with self.assertRaises(OSError):
                controller.reconcile(stream(), {"42"})
        run.assert_called_once_with("pw-dump")
        self.assertTrue(controller.saved)

    def test_verified_identity_changes_only_stream_mute(self):
        controller = Controller(self.path)
        with (
            patch("game_workspace_audio.command", return_value=b"[]") as run,
            patch("game_workspace_audio.streams", return_value=stream()),
        ):
            controller.reconcile(stream(), {"42"})
        self.assertEqual(run.call_args_list[-1].args, ("wpctl", "set-mute", 20, 1))

    def test_visibility_including_side_monitor_focus(self):
        monitors = [
            {"activeWorkspace": {"id": 5}, "focused": False},
            {"activeWorkspace": {"id": -1337}, "focused": True},
        ]
        self.assertEqual(hidden_games([window()], monitors, lambda _: None), set())
        monitors[0]["activeWorkspace"]["id"] = 2
        self.assertEqual(hidden_games([window()], monitors, lambda _: None), {"42"})
        # Moving any game window out of workspace 5 restores its audio.
        self.assertEqual(hidden_games([window(workspace=2)], monitors, lambda _: None), set())

    def test_custom_native_class_and_steam_ui(self):
        native = {"class": "native-game", "pid": 1, "workspace": {"id": 5}}
        steam = {"class": "steam", "pid": 2, "workspace": {"id": 5}}
        self.assertEqual(hidden_games([native, steam], [], lambda _: "42"), {"42"})
        self.assertEqual(hidden_games([steam], [], lambda _: "42"), set())

    def test_process_steam_id_and_helper_exclusion(self):
        with (
            patch("pathlib.Path.read_text", return_value="wine64-preloader"),
            patch("pathlib.Path.read_bytes", return_value=b"SteamAppId=42\0SteamGameId=42\0"),
        ):
            self.assertEqual(process_game(123), "42")
        with patch("pathlib.Path.read_text", return_value="steamwebhelper"):
            self.assertIsNone(process_game(123))

    def test_snapshot_only_steam_playback_and_stable_identity(self):
        props = {
            "media.class": "Stream/Output/Audio",
            "application.process.id": 123,
            "application.name": "Game",
            "object.serial": 50,
        }
        snapshot = [
            {"type": "PipeWire:Interface:Core", "info": {"cookie": 100}},
            {
                "id": 20,
                "type": "PipeWire:Interface:Node",
                "info": {"props": props, "params": {"Props": [{"mute": False}]}},
            },
        ]
        actual = streams(snapshot, lambda _: "42")
        self.assertEqual(len(actual), 1)
        self.assertEqual(next(iter(actual.values()))["app"], "42")
        other_core = copy.deepcopy(snapshot)
        other_core[0]["info"]["cookie"] = 101
        self.assertNotEqual(set(actual), set(streams(other_core, lambda _: "42")))
        self.assertEqual(streams(snapshot, lambda _: None), {})
        props["media.class"] = "Stream/Input/Audio"
        self.assertEqual(streams(snapshot, lambda _: "42"), {})


if __name__ == "__main__":
    unittest.main()
