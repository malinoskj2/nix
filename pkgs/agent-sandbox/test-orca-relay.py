#!/usr/bin/env python3
"""Verify the sandbox Orca relay's policy and forwarding against a fake runtime."""

import asyncio
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("orca_relay", Path(__file__).with_name("orca-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

SESSION = "5f0c9a52-0000-4000-8000-000000000001"
TERMINAL = "structworker_mine"
ROOT = "5f0c9a52-0000-4000-8000-0000000000aa"
PREVIEW = "http://192.0.2.10:18080"
ME = relay.Identity(session_id=SESSION, terminal=TERMINAL, launch_token="launch-secret")

SCHEMA = """
CREATE TABLE runs (id TEXT PRIMARY KEY, coordinator_handle TEXT, coordinator_orca_session_id TEXT);
CREATE TABLE run_coordinator_handles (run_id TEXT, terminal_handle TEXT);
CREATE TABLE dispatch_contexts (
  id TEXT PRIMARY KEY, run_id TEXT, task_id TEXT, assignee_handle TEXT, assignee_pane_key TEXT,
  creator_handle TEXT, status TEXT);
CREATE TABLE worker_dispatches (dispatch_id TEXT PRIMARY KEY, agent_terminal_handle TEXT, worktree_id TEXT);
CREATE TABLE worker_terminal_resources (owner_dispatch_id TEXT, terminal_handle TEXT);
CREATE TABLE tasks (id TEXT PRIMARY KEY, run_id TEXT, created_by_terminal_handle TEXT);
"""


def orchestration_db(path: Path) -> None:
    """A root coordinator's Run in which this sandbox is a nested coordinator, beside a sibling."""
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.executemany(
        "INSERT INTO runs VALUES (?, ?, ?)",
        [("run_root", None, ROOT), ("run_other", "term_other", "someone-else")],
    )
    dispatches = [
        # id, run, task, assignee, pane, creator, status
        ("ctx_coord", "run_root", "task_coord", "structworker_coord", None, None, "dispatched"),
        (
            "ctx_mine",
            "run_root",
            "task_mine",
            TERMINAL,
            f"structured-agent-session-{SESSION}:1",
            "structworker_coord",
            "dispatched",
        ),
        ("ctx_child", "run_root", "task_child", "structworker_child", None, TERMINAL, "dispatched"),
        ("ctx_grand", "run_root", "task_grand", "structworker_grand", None, "structworker_child", "completed"),
        ("ctx_sibling", "run_root", "task_sibling", "structworker_sibling", None, "structworker_coord", "dispatched"),
        (
            "ctx_sibling_done",
            "run_root",
            "task_sibling_done",
            "structworker_old",
            None,
            "structworker_coord",
            "completed",
        ),
        ("ctx_other", "run_other", "task_other", "term_x", None, "term_other", "completed"),
    ]
    db.executemany("INSERT INTO dispatch_contexts VALUES (?, ?, ?, ?, ?, ?, ?)", dispatches)
    db.executemany(
        "INSERT INTO worker_dispatches VALUES (?, ?, ?)",
        [
            ("ctx_mine", TERMINAL, "repo::/w/mine"),
            ("ctx_child", "structworker_child", "repo::/w/child"),
            ("ctx_sibling", "structworker_sibling", "repo::/w/sibling"),
        ],
    )
    db.executemany(
        "INSERT INTO worker_terminal_resources VALUES (?, ?)",
        [("ctx_child", "structworker_child"), ("ctx_sibling", "structworker_sibling")],
    )
    db.executemany(
        "INSERT INTO tasks VALUES (?, ?, ?)",
        [(row[2], row[1], row[5]) for row in dispatches] + [("task_draft", "run_root", TERMINAL)],
    )
    db.commit()
    db.close()


WORKTREES = {
    "repo::/w/mine": {"id": "repo::/w/mine", "parentWorktreeId": "repo::/w/coord"},
    "repo::/w/child": {"id": "repo::/w/child", "parentWorktreeId": "repo::/w/mine"},
    "repo::/w/nested": {"id": "repo::/w/nested", "parentWorktreeId": "repo::/w/child"},
    "repo::/w/sibling": {"id": "repo::/w/sibling", "parentWorktreeId": "repo::/w/coord"},
    "repo::/w/coord": {"id": "repo::/w/coord", "parentWorktreeId": None},
}


class FakeOrca:
    """The upstream answers the relay's own checks read."""

    def __init__(self):
        self.calls = []
        self.profiles = []

    async def __call__(self, method, params):
        self.calls.append((method, params))
        if method == "worktree.show":
            selector = params["worktree"]
            key = selector.removeprefix("id:").removeprefix("path:")
            key = key if key in WORKTREES else f"repo::{key}"
            if key not in WORKTREES:
                raise relay.Unavailable("worktree_not_found")
            return {"worktree": WORKTREES[key]}
        if method == "bots.chats":
            return {"bot": "Kanna" if params["callerSessionId"] == SESSION else "Elma", "chats": []}
        if method == "bots.list":
            return {"bots": [{"id": "bot-kanna", "name": "Kanna"}, {"id": "bot-elma", "name": "Elma"}]}
        if method == "browser.profileList":
            return {"profiles": self.profiles}
        if method == "browser.profileCreate":
            self.profiles.append({"id": "profile-preview", "label": params["label"], "scope": params["scope"]})
            return {"profile": self.profiles[-1]}
        raise AssertionError(method)


class PolicyTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.database = root / "orchestration.db"
        orchestration_db(self.database)
        self.origins = root / "preview-origins"
        self.origins.write_text(PREVIEW + "\n")
        self.orca = FakeOrca()

    def tearDown(self):
        self.directory.cleanup()

    def policy(self, identity=ME, bot=False):
        ownership = relay.Ownership(self.database, identity)
        return relay.Policy("claude", identity, bot, self.origins, ownership, self.orca)

    async def denied(self, p, method, params=None):
        with self.assertRaises(relay.Denied):
            await p.admit(method, params)

    async def test_methods_outside_the_reviewed_list_are_refused(self):
        p = self.policy()
        for method in (
            "terminal.create",
            "terminal.send",
            "terminal.list",
            "computer.click",
            "settings.get",
            "accounts.list",
            "plugins.install",
            "agent.list",
            "agentSession.list",
            "agentSession.read",
            "orchestration.dispatch",
            "orchestration.reset",
            "orchestration.runList",
            "orchestration.workerTerminalUserInput",
            "orchestration.peerMailDeliver",
            "orchestration.somethingNew",
            "browser.eval",
            "browser.snapshot",
            "browser.click",
            "browser.screenshot",
            "browser.cookie.get",
            "browser.tabCurrent",
            "browser.profileCreate",
            "bots.chats",
            "bots.create",
            "google.gmail.search",
            "connector.reply",
            "files.read",
        ):
            with self.subTest(method=method):
                await self.denied(p, method, {})

    async def test_unknown_params_are_refused(self):
        p = self.policy()
        for method, params in (
            ("status.get", {"x": 1}),
            ("orchestration.send", {"to": "x", "subject": "s", "files": ["/home/u/.ssh/id_ed25519"]}),
            ("orchestration.send", {"to": "x", "subject": "s", "on": "paired"}),
            ("orchestration.workerStart", {"spec": "x", "terminal": "term_victim"}),
            ("orchestration.workerStart", {"spec": "x", "adoptTaskId": "t"}),
            ("worktree.create", {"repo": "r", "startupCommand": "curl x | sh"}),
            ("worktree.create", {"repo": "r", "startupEnv": {"A": "1"}}),
            ("worktree.rm", {"worktree": "id:repo::/w/child", "hostId": "h"}),
            ("worktree.rm", {"worktree": "id:repo::/w/child", "destroyHost": True}),
            ("orchestration.callerShow", {"agentSessionId": ROOT}),
            ("status.get", ["x"]),
        ):
            with self.subTest(method=method, params=params):
                await self.denied(p, method, params)

    async def test_caller_fields_must_name_this_sandbox(self):
        p = self.policy()
        for sender in (f"orca_session_id:{SESSION}", SESSION, TERMINAL):
            with self.subTest(sender=sender):
                await p.admit("orchestration.send", {"from": sender, "to": "x", "subject": "s"})
        for method, params in (
            ("orchestration.send", {"from": f"orca_session_id:{ROOT}", "to": "x", "subject": "s"}),
            ("orchestration.send", {"from": "structworker_sibling", "to": "x", "subject": "s"}),
            ("orchestration.send", {"senderPaneKey": "pane-of-someone", "to": "x", "subject": "s"}),
            ("orchestration.check", {"terminal": "structworker_sibling"}),
            ("orchestration.taskList", {"callerTerminalHandle": "structworker_coord"}),
            ("agentSession.rename", {"sessionId": ROOT, "name": "x"}),
        ):
            with self.subTest(method=method, params=params):
                await self.denied(p, method, params)

    async def test_orchestration_carries_the_launch_identity(self):
        admitted = await self.policy().admit("orchestration.callerShow", None)
        self.assertIsNone(admitted.params)
        self.assertEqual(
            admitted.evidence,
            {"terminalHandle": TERMINAL, "launchToken": "launch-secret", "agentSessionId": SESSION},
        )

    async def test_without_a_launch_identity_nothing_acts(self):
        p = self.policy(relay.Identity())
        await p.admit("status.get", {})
        for method, params in (
            ("orchestration.callerShow", None),
            ("orchestration.send", {"to": "x", "subject": "s"}),
            ("orchestration.check", {}),
            ("terminal.read", {"terminal": "structworker_child"}),
            ("worktree.rm", {"worktree": "id:repo::/w/child"}),
        ):
            with self.subTest(method=method):
                await self.denied(p, method, params)

    async def test_reads_reach_only_owned_dispatches(self):
        p = self.policy()
        for method in ("orchestration.workerShow", "orchestration.workerRead", "orchestration.workerTranscript"):
            for dispatch in ("ctx_mine", "ctx_child", "ctx_grand"):
                with self.subTest(method=method, dispatch=dispatch):
                    await p.admit(method, {"dispatch": dispatch})
            for dispatch in ("ctx_coord", "ctx_sibling", "ctx_sibling_done", "ctx_other", "ctx_missing"):
                with self.subTest(method=method, dispatch=dispatch):
                    await self.denied(p, method, {"dispatch": dispatch})

    async def test_destructive_worker_calls_reach_only_owned_dispatches(self):
        p = self.policy()
        for method in (
            "orchestration.workerStop",
            "orchestration.workerRelease",
            "orchestration.workerAbandon",
            "orchestration.workerRetain",
        ):
            with self.subTest(method=method):
                await p.admit(method, {"dispatch": "ctx_child"})
                await self.denied(p, method, {"dispatch": "ctx_sibling"})
                await self.denied(p, method, {"dispatch": "ctx_sibling_done"})
        await self.denied(p, "orchestration.workerStart", {"spec": "x", "retryOf": "ctx_sibling"})
        await self.denied(p, "orchestration.taskUpdate", {"id": "task_sibling", "status": "completed"})
        await p.admit("orchestration.taskUpdate", {"id": "task_child", "status": "completed"})
        await p.admit("orchestration.taskUpdate", {"id": "task_draft", "status": "completed"})

    async def test_terminals_are_this_sandboxs_and_its_workers(self):
        p = self.policy()
        for terminal in (TERMINAL, "structworker_child", "structworker_grand"):
            with self.subTest(terminal=terminal):
                await p.admit("terminal.read", {"terminal": terminal})
        for terminal in ("structworker_coord", "structworker_sibling", "structworker_old", "term_x", "active"):
            with self.subTest(terminal=terminal):
                await self.denied(p, "terminal.read", {"terminal": terminal})
                await self.denied(p, "terminal.wait", {"terminal": terminal, "for": "exit"})

    async def test_a_root_coordinator_owns_its_runs(self):
        p = self.policy(relay.Identity(session_id=ROOT))
        for dispatch in ("ctx_coord", "ctx_mine", "ctx_sibling", "ctx_sibling_done", "ctx_grand"):
            with self.subTest(dispatch=dispatch):
                await p.admit("orchestration.workerRead", {"dispatch": dispatch})
        await p.admit("orchestration.runShow", {"id": "run_root"})
        await self.denied(p, "orchestration.workerRead", {"dispatch": "ctx_other"})
        await self.denied(p, "orchestration.runShow", {"id": "run_other"})
        await self.denied(p, "terminal.read", {"terminal": "term_x"})

    async def test_lists_keep_only_owned_entries(self):
        p = self.policy()
        admitted = await p.admit("orchestration.workerList", {})
        listed = {"workers": [{"dispatchId": d} for d in ("ctx_mine", "ctx_child", "ctx_sibling", "ctx_other")]}
        self.assertEqual([w["dispatchId"] for w in admitted.on_result(listed)["workers"]], ["ctx_mine", "ctx_child"])
        admitted = await p.admit("orchestration.taskList", {"run": "run_root"})
        tasks = admitted.on_result({"tasks": [{"id": "task_child"}, {"id": "task_sibling"}]})["tasks"]
        self.assertEqual(tasks, [{"id": "task_child"}])
        with self.assertRaises(ValueError):
            admitted.on_result({"unexpected": []})
        admitted = await p.admit("orchestration.inbox", {"limit": 5})
        self.assertEqual(admitted.params["terminal"], TERMINAL)
        await self.denied(p, "orchestration.inbox", {"run": "run_other"})

    async def test_worker_start_runs_sandboxed_agents_without_setup(self):
        p = self.policy()
        await self.denied(p, "orchestration.workerStart", {"spec": "x", "agent": "gemini"})
        admitted = await p.admit("orchestration.workerStart", {"spec": "x", "from": SESSION, "worktree": "current"})
        self.assertEqual(
            admitted.params, {"spec": "x", "from": SESSION, "worktree": "current", "setup": "skip", "agent": "claude"}
        )
        await p.admit("orchestration.workerStart", {"spec": "x", "worktree": "id:repo::/w/child"})
        await p.admit("orchestration.workerStart", {"spec": "x", "worktree": "new-child"})
        await self.denied(p, "orchestration.workerStart", {"spec": "x", "worktree": "id:repo::/w/sibling"})

    async def test_worktrees_are_this_sandboxs_and_their_descendants(self):
        p = self.policy()
        for selector in ("id:repo::/w/mine", "id:repo::/w/child", "id:repo::/w/nested", "path:/w/nested"):
            with self.subTest(selector=selector):
                admitted = await p.admit("worktree.rm", {"worktree": selector, "runHooks": True})
                self.assertIs(admitted.params["runHooks"], False)
        for selector in ("id:repo::/w/sibling", "id:repo::/w/coord", "active", "path:/w/missing"):
            with self.subTest(selector=selector):
                await self.denied(p, "worktree.rm", {"worktree": selector})
                await self.denied(p, "worktree.set", {"worktree": selector, "comment": "x"})
        admitted = await p.admit("worktree.create", {"repo": "r", "setupDecision": "run", "startupAgent": "codex"})
        self.assertEqual(admitted.params["setupDecision"], "skip")
        await self.denied(p, "worktree.create", {"repo": "r", "startupAgent": "gemini"})
        await self.denied(p, "worktree.create", {"repo": "r", "parentWorktree": "id:repo::/w/sibling"})
        admitted.on_result({"worktree": {"id": "repo::/w/new"}})
        await p.admit("worktree.rm", {"worktree": "id:repo::/w/new"})

    async def test_browser_shows_only_preview_tabs_in_an_isolated_profile(self):
        p = self.policy()
        admitted = await p.admit("browser.tabCreate", {"url": PREVIEW + "/index.html"})
        self.assertEqual(admitted.params["profileId"], "profile-preview")
        self.assertEqual(self.orca.profiles[0]["scope"], "isolated")
        admitted.on_result({"browserPageId": "page-1"})
        for url in ("file:///etc/passwd", "https://github.com/", "http://127.0.0.1:6768/", "about:blank", 42):
            with self.subTest(url=url):
                await self.denied(p, "browser.tabCreate", {"url": url})
        await self.denied(p, "browser.tabCreate", {"url": PREVIEW, "profileId": "default"})
        await p.admit("browser.goto", {"page": "page-1", "url": PREVIEW + "/other"})
        await self.denied(p, "browser.goto", {"page": "page-1", "url": "https://example.com"})
        await self.denied(p, "browser.goto", {"page": "someone-else", "url": PREVIEW})
        await p.admit("browser.tabClose", {"page": "page-1"})
        await self.denied(p, "browser.tabClose", {"page": "someone-else"})
        for page in ({}, {"page": None}, {"page": ""}):
            with self.subTest(page=page):
                await self.denied(p, "browser.tabClose", page)
                await self.denied(p, "browser.goto", {"url": PREVIEW, **page})
        admitted = await p.admit("browser.tabList", {})
        tabs = admitted.on_result({"tabs": [{"browserPageId": "page-1"}, {"browserPageId": "users-bank"}]})
        self.assertEqual(tabs["tabs"], [{"browserPageId": "page-1"}])
        await self.policy().admit("browser.tabCreate", {"url": PREVIEW})
        self.assertEqual(len(self.orca.profiles), 1)

    async def test_bot_sandboxes_reach_only_their_own_bot(self):
        await self.denied(self.policy(), "bots.chats", {})
        p = self.policy(bot=True)
        admitted = await p.admit("bots.chats", {"callerSessionId": SESSION})
        self.assertEqual(admitted.params["callerSessionId"], SESSION)
        self.assertEqual(admitted.evidence, {"agentSessionId": SESSION})
        await p.admit("bots.chats", {"botId": "bot-kanna"})
        await self.denied(p, "bots.chats", {"botId": "bot-elma"})
        await self.denied(p, "bots.chats", {"callerSessionId": ROOT})
        admitted = await p.admit("bots.memory.edit", {"fact": "f", "text": "t"})
        self.assertEqual(admitted.params["botId"], "bot-kanna")
        await self.denied(p, "bots.memory.edit", {"fact": "f", "text": "t", "botId": "bot-elma"})
        await self.denied(p, "bots.items.set", {"item": "1", "files": ["/home/u/.ssh/id_ed25519"]})
        await self.denied(p, "bots.items.comment", {"item": "1", "text": "x", "files": ["/etc/shadow"]})
        admitted = await p.admit("connector.reply", {"paneKey": None, "replyId": "r", "text": "hi"})
        self.assertEqual(admitted.params, {"replyId": "r", "text": "hi", "sessionId": SESSION})
        await self.denied(p, "connector.react", {"sessionId": ROOT, "emoji": "x"})
        for method in ("bots.tools.connect", "bots.composio.key", "bots.import.plan", "google.drive.upload"):
            with self.subTest(method=method):
                await self.denied(p, method, {})

    async def test_unreadable_records_fail_closed(self):
        self.database.unlink()
        self.database.write_bytes(b"not a database")
        with self.assertRaises(relay.Unavailable):
            await self.policy().admit("orchestration.workerRead", {"dispatch": "ctx_child"})


class FakeRuntime:
    def __init__(self, path: Path):
        self.path = path
        self.requests = []

    async def handle(self, reader, writer):
        while line := await reader.readline():
            request = json.loads(line)
            self.requests.append(request)
            meta = {"runtimeId": "runtime-1"}
            if request["authToken"] != "real-token":
                frame = {"id": request["id"], "ok": False, "error": {"code": "unauthorized", "message": "x"}}
            elif request["method"] == "browser.profileList":
                frame = {
                    "id": request["id"],
                    "ok": True,
                    "result": {
                        "profiles": [
                            {"id": "profile-preview", "label": relay.PREVIEW_PROFILE_LABEL, "scope": "isolated"}
                        ]
                    },
                }
            elif request["method"] == "browser.tabCreate":
                frame = {"id": request["id"], "ok": True, "result": {"browserPageId": "page-1"}}
            elif request["method"] == "browser.tabList":
                frame = {
                    "id": request["id"],
                    "ok": True,
                    "result": {"tabs": [{"browserPageId": "page-1"}, {"browserPageId": "users-tab"}]},
                }
            else:
                writer.write(b'{"_keepalive":true}\n')
                frame = {"id": request["id"], "ok": True, "result": {"echo": request.get("params")}}
            writer.write(json.dumps({**frame, "_meta": meta}).encode() + b"\n")
            await writer.drain()
        writer.close()


class RelayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.host = root / "host"
        self.data = root / "data"
        self.host.mkdir()
        self.data.mkdir()
        orchestration_db(self.host / "orchestration.db")
        (self.host / "linux-orca-cli-shim").mkdir()
        (self.host / "linux-orca-cli-shim" / "orca").write_text("#!/bin/sh\n")
        self.runtime = FakeRuntime(root / "o.sock")
        self.upstream = await asyncio.start_unix_server(self.runtime.handle, path=str(self.runtime.path))
        self.write_metadata("runtime-1")
        origins = root / "preview-origins"
        origins.write_text(PREVIEW + "\n")
        self.relay = relay.build(self.host, self.data, "/home/test/.config/orca", "claude", ME, False, origins)
        self.serving = asyncio.create_task(self.relay.serve())
        for _ in range(100):
            if self.relay.socket.exists():
                break
            await asyncio.sleep(0.01)

    async def asyncTearDown(self):
        self.serving.cancel()
        self.upstream.close()
        self.directory.cleanup()

    def write_metadata(self, runtime_id):
        metadata = {
            "runtimeId": runtime_id,
            "pid": 7,
            "transports": [
                {"kind": "unix", "endpoint": str(self.runtime.path)},
                {"kind": "websocket", "endpoint": "ws://0.0.0.0:6768"},
            ],
            "authToken": "real-token",
            "startedAt": 1,
        }
        (self.host / "orca-runtime.json").write_text(json.dumps(metadata))

    def forwarded(self, method):
        return [r for r in self.runtime.requests if r["method"] == method]

    async def call(self, *requests):
        reader, writer = await asyncio.open_unix_connection(str(self.relay.socket))
        frames = []
        for request in requests:
            writer.write(json.dumps({"authToken": relay.DUMMY_TOKEN, **request}).encode() + b"\n")
            await writer.drain()
            while True:
                frame = json.loads(await reader.readline())
                frames.append(frame)
                if "_keepalive" not in frame:
                    break
        writer.close()
        return frames

    def test_synthetic_profile_names_the_relay_and_never_the_token(self):
        synthetic = json.loads((self.data / "orca-runtime.json").read_text())
        self.assertEqual(synthetic["authToken"], relay.DUMMY_TOKEN)
        self.assertEqual(synthetic["runtimeId"], "runtime-1")
        self.assertEqual(synthetic["transports"], [{"kind": "unix", "endpoint": "/home/test/.config/orca/relay.sock"}])
        self.assertEqual((self.data / "linux-orca-cli-shim" / "orca").read_text(), "#!/bin/sh\n")
        self.assertNotIn("real-token", "".join(p.read_text() for p in self.data.rglob("*") if p.is_file()))
        self.write_metadata("runtime-2")
        self.relay.refresh()
        self.assertEqual(json.loads((self.data / "orca-runtime.json").read_text())["runtimeId"], "runtime-2")
        (self.host / "orca-runtime.json").unlink()
        self.relay.refresh()
        self.assertFalse((self.data / "orca-runtime.json").exists())

    async def test_allowed_calls_carry_the_real_token_and_stream_back(self):
        frames = await self.call({"id": "1", "method": "terminal.read", "params": {"terminal": TERMINAL}})
        self.assertEqual(frames[0], {"_keepalive": True})
        self.assertEqual(frames[1]["result"], {"echo": {"terminal": TERMINAL}})
        self.assertEqual(self.runtime.requests[0]["authToken"], "real-token")

    async def test_the_envelope_is_rebuilt_with_the_launch_identity(self):
        await self.call(
            {
                "id": "1",
                "method": "orchestration.callerShow",
                "orchestrationContractVersion": 3,
                "compatibilityInvocationId": "inv-1",
                "orchestrationCompatibilityEvidence": {"agentSessionId": SESSION, "terminalHandle": TERMINAL},
                "expectedRuntimeSource": {"anything": True},
                "somethingNew": {"agentSessionId": ROOT},
            }
        )
        (sent,) = self.forwarded("orchestration.callerShow")
        self.assertTrue(sent.pop("id").startswith("relay-"))
        self.assertEqual(
            sent,
            {
                "authToken": "real-token",
                "method": "orchestration.callerShow",
                "orchestrationContractVersion": 3,
                "compatibilityInvocationId": "inv-1",
                "orchestrationCompatibilityEvidence": {
                    "terminalHandle": TERMINAL,
                    "launchToken": "launch-secret",
                    "agentSessionId": SESSION,
                },
            },
        )

    async def test_forged_caller_evidence_never_reaches_orca(self):
        frames = await self.call(
            {
                "id": "1",
                "method": "orchestration.callerShow",
                "orchestrationCompatibilityEvidence": {"agentSessionId": ROOT},
            },
            {
                "id": "2",
                "method": "orchestration.callerShow",
                "orchestrationCompatibilityEvidence": {"host": {"kind": "ssh"}},
            },
            {"id": "3", "method": "orchestration.check", "orchestrationPeerRun": {"runId": "run_root"}},
            {"id": "4", "method": "orchestration.check", "executionHost": "remote"},
            {"id": "5", "method": "status.get"},
        )
        self.assertEqual([f["error"]["code"] for f in frames[:4]], ["forbidden"] * 4)
        self.assertEqual([r["method"] for r in self.runtime.requests], ["status.get"])
        self.assertNotIn("orchestrationCompatibilityEvidence", self.runtime.requests[0])

    async def test_refused_calls_never_reach_orca(self):
        frames = await self.call(
            {"id": "1", "method": "terminal.create", "params": {}},
            {"id": "2", "method": "orchestration.workerRead", "params": {"dispatch": "ctx_sibling"}},
            {"id": "3", "method": "status.get"},
        )
        self.assertEqual(frames[0]["error"]["code"], "forbidden")
        self.assertEqual(frames[1]["error"]["code"], "forbidden")
        self.assertEqual(frames[0]["_meta"], {"runtimeId": "runtime-1"})
        self.assertEqual([r["method"] for r in self.runtime.requests], ["status.get"])

    async def test_params_are_rewritten_before_forwarding(self):
        await self.call({"id": "1", "method": "orchestration.workerStart", "params": {"spec": "x", "setup": "run"}})
        (sent,) = self.forwarded("orchestration.workerStart")
        self.assertEqual(sent["params"], {"spec": "x", "setup": "skip", "agent": "claude"})

    async def test_tabs_are_created_isolated_and_listed_as_own(self):
        frames = await self.call(
            {"id": "1", "method": "browser.goto", "params": {"page": "page-1", "url": PREVIEW}},
            {"id": "2", "method": "browser.tabCreate", "params": {"url": PREVIEW}},
            {"id": "3", "method": "browser.goto", "params": {"page": "page-1", "url": PREVIEW}},
            {"id": "4", "method": "browser.tabList", "params": {}},
        )
        frames = [frame for frame in frames if "_keepalive" not in frame]
        self.assertEqual(frames[0]["error"]["code"], "forbidden")
        self.assertTrue(frames[2]["ok"])
        self.assertEqual(frames[3]["result"]["tabs"], [{"browserPageId": "page-1"}])
        (created,) = self.forwarded("browser.tabCreate")
        self.assertEqual(created["params"]["profileId"], "profile-preview")

    async def test_reused_request_ids_keep_their_own_answers_and_filters(self):
        reader, writer = await asyncio.open_unix_connection(str(self.relay.socket))
        requests = [
            {"id": "reused", "method": "browser.tabCreate", "params": {"url": PREVIEW}},
            {"id": "reused", "method": "browser.tabList", "params": {}},
            {"id": "reused", "method": "status.get"},
            {"id": "reused", "method": "orchestration.workerList", "params": {}},
            {"id": "reused", "method": "orchestration.check", "params": {}},
        ]
        for request in requests:
            writer.write(json.dumps({"authToken": relay.DUMMY_TOKEN, **request}).encode() + b"\n")
        await writer.drain()
        frames = []
        while len(frames) < len(requests):
            frame = json.loads(await asyncio.wait_for(reader.readline(), 5))
            if "_keepalive" not in frame:
                frames.append(frame)
        writer.close()
        self.assertEqual({frame["id"] for frame in frames}, {"reused"})
        upstream_ids = [r["id"] for r in self.runtime.requests if r["method"] != "browser.profileList"]
        self.assertEqual(len(set(upstream_ids)), len(requests))
        tabs = [f["result"]["tabs"] for f in frames if "tabs" in f.get("result", {})]
        self.assertEqual(tabs, [[{"browserPageId": "page-1"}]])
        self.assertNotIn("users-tab", json.dumps(frames))

    async def test_answers_to_no_forwarded_request_are_dropped(self):
        pending = {"relay-1": ("mine", None)}
        self.assertIsNone(self.relay.rewrite(b'{"id":"relay-2","ok":true,"result":{}}\n', pending))
        self.assertIsNone(self.relay.rewrite(b"not json\n", pending))
        self.assertEqual(self.relay.rewrite(b'{"_keepalive":true}\n', pending), b'{"_keepalive":true}\n')
        self.assertEqual(json.loads(self.relay.rewrite(b'{"id":"relay-1","ok":true}\n', pending))["id"], "mine")

    async def test_missing_runtime_is_reported(self):
        (self.host / "orca-runtime.json").unlink()
        frames = await self.call({"id": "1", "method": "status.get"})
        self.assertEqual(frames[0]["error"]["code"], "runtime_unavailable")

    async def test_invalid_json_is_refused(self):
        reader, writer = await asyncio.open_unix_connection(str(self.relay.socket))
        writer.write(b"{nope\n")
        frame = json.loads(await reader.readline())
        writer.close()
        self.assertEqual(frame["error"]["code"], "bad_request")
        self.assertEqual(self.runtime.requests, [])


if __name__ == "__main__":
    unittest.main()
