#!/usr/bin/env python3
import argparse
import asyncio
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
from typing import Awaitable, Callable
from urllib.parse import urlsplit
import uuid

DUMMY_TOKEN = "agent-sandbox-relay"
MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 64 * 1024 * 1024
MAX_CONNECTIONS = 16
MAX_ID = 256
MAX_IN_FLIGHT = 4096
REFRESH_INTERVAL = 1.0
OWNERSHIP_TTL = 2.0
UPSTREAM_TIMEOUT = 15.0
LINEAGE_DEPTH = 8
SANDBOX_AGENTS = frozenset({"claude", "codex", "antigravity", "opencode"})
PREVIEW_PROFILE_LABEL = "Agent sandbox previews"
SESSION_PREFIX = "orca_session_id:"
EVIDENCE_KEYS = ("terminalHandle", "paneKey", "launchToken", "agentSessionId")


class Denied(Exception):
    pass


class Unavailable(Exception):
    pass


@dataclass(frozen=True)
class Identity:
    """Who this sandbox is, as Orca's launch told the launcher on the host."""

    session_id: str = ""
    terminal: str = ""
    pane_key: str = ""
    launch_token: str = ""
    worktree_id: str = ""

    @classmethod
    def from_env(cls, env) -> "Identity":
        def value(name: str) -> str:
            raw = (env.get(name) or "").strip()
            return raw if len(raw) <= 512 else ""

        session = value("ORCA_AGENT_SESSION_ID").removeprefix(SESSION_PREFIX)
        return cls(
            session_id=session,
            terminal=value("ORCA_TERMINAL_HANDLE"),
            pane_key=value("ORCA_PANE_KEY"),
            launch_token=value("ORCA_AGENT_LAUNCH_TOKEN"),
            worktree_id=value("ORCA_WORKTREE_ID"),
        )

    @property
    def known(self) -> bool:
        return bool(self.session_id or self.terminal)

    @property
    def session_address(self) -> str:
        return f"{SESSION_PREFIX}{self.session_id}" if self.session_id else ""

    def handles(self) -> set[str]:
        """The strings Orca records as this sandbox's terminal or session address."""
        return {value for value in (self.terminal, self.session_address) if value}

    def senders(self) -> set[str]:
        return {value for value in (self.session_address, self.session_id, self.terminal) if value}

    def panes(self) -> set[str]:
        return {self.pane_key} if self.pane_key else set()

    def sessions(self) -> set[str]:
        return {value for value in (self.session_id, self.session_address) if value}

    def evidence(self) -> dict:
        values = (self.terminal, self.pane_key, self.launch_token, self.session_id)
        return {key: value for key, value in zip(EVIDENCE_KEYS, values) if value}


@dataclass
class Owned:
    """What a sandbox may read or act on in Orca's orchestration records."""

    runs: set[str] = field(default_factory=set)
    dispatches: set[str] = field(default_factory=set)
    terminals: set[str] = field(default_factory=set)
    tasks: set[str] = field(default_factory=set)
    worktrees: set[str] = field(default_factory=set)


OWNERSHIP_SQL = """
WITH RECURSIVE
  me(handle) AS (SELECT value FROM json_each(:handles)),
  coordinated(id) AS (
    SELECT id FROM runs
     WHERE (:session <> '' AND coordinator_orca_session_id = :session)
        OR coordinator_handle IN (SELECT handle FROM me)
    UNION SELECT run_id FROM run_coordinator_handles WHERE terminal_handle IN (SELECT handle FROM me)
  ),
  mine(id, run_id, task_id) AS (
    SELECT id, run_id, task_id FROM dispatch_contexts
     WHERE assignee_handle IN (SELECT handle FROM me)
        OR (:pane <> '' AND assignee_pane_key = :pane)
        OR (:pane_pattern <> '' AND assignee_pane_key LIKE :pane_pattern ESCAPE '\\')
  ),
  created(id, run_id, task_id, assignee) AS (
    SELECT id, run_id, task_id, assignee_handle FROM dispatch_contexts
     WHERE creator_handle IN (SELECT handle FROM me) OR run_id IN (SELECT id FROM coordinated)
    UNION
    SELECT d.id, d.run_id, d.task_id, d.assignee_handle
      FROM dispatch_contexts d JOIN created c ON d.creator_handle = c.assignee
  )
SELECT 'runs', id FROM coordinated
UNION SELECT 'runs', run_id FROM mine
UNION SELECT 'runs', run_id FROM created
UNION SELECT 'dispatches', id FROM mine
UNION SELECT 'dispatches', id FROM created
UNION SELECT 'tasks', task_id FROM mine
UNION SELECT 'tasks', task_id FROM created
UNION SELECT 'tasks', id FROM tasks WHERE run_id IN (SELECT id FROM coordinated)
UNION SELECT 'tasks', id FROM tasks
       WHERE created_by_terminal_handle IN (SELECT handle FROM me)
          OR created_by_terminal_handle IN (SELECT assignee FROM created)
UNION SELECT 'terminals', assignee FROM created WHERE assignee IS NOT NULL
UNION SELECT 'terminals', agent_terminal_handle FROM worker_dispatches
       WHERE agent_terminal_handle IS NOT NULL AND dispatch_id IN (SELECT id FROM created)
UNION SELECT 'terminals', terminal_handle FROM worker_terminal_resources
       WHERE owner_dispatch_id IN (SELECT id FROM created)
UNION SELECT 'worktrees', worktree_id FROM worker_dispatches
       WHERE worktree_id IS NOT NULL
         AND (dispatch_id IN (SELECT id FROM created) OR dispatch_id IN (SELECT id FROM mine))
"""


def like_literal(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


class Ownership:
    """Tells what a sandbox owns from Orca's orchestration database, opened read-only on the host.

    A root coordinator owns every Dispatch in the Runs it coordinates. A worker owns its own
    Dispatches and, recursively, the ones it and its workers created."""

    def __init__(self, database: Path, identity: Identity):
        self.database = database
        self.identity = identity
        self.cached: tuple[float, Owned] | None = None

    def query(self) -> Owned:
        owned = Owned(terminals={self.identity.terminal} - {""})
        if self.identity.worktree_id:
            owned.worktrees.add(self.identity.worktree_id)
        if not self.identity.known:
            return owned
        pane_pattern = (
            f"structured-agent-session-{like_literal(self.identity.session_id)}:%" if self.identity.session_id else ""
        )
        try:
            connection = sqlite3.connect(f"file:{self.database}?mode=ro", uri=True, timeout=5)
            try:
                rows = connection.execute(
                    OWNERSHIP_SQL,
                    {
                        "handles": json.dumps(sorted(self.identity.handles())),
                        "session": self.identity.session_id,
                        "pane": self.identity.pane_key,
                        "pane_pattern": pane_pattern,
                    },
                ).fetchall()
            finally:
                connection.close()
        except sqlite3.Error as error:
            raise Unavailable(f"Orca's orchestration records can't be read: {error}") from error
        for bucket, value in rows:
            if isinstance(value, str) and value:
                getattr(owned, bucket).add(value)
        return owned

    def get(self, fresh: bool = False) -> Owned:
        now = time.monotonic()
        if fresh or self.cached is None or now - self.cached[0] > OWNERSHIP_TTL:
            self.cached = (now, self.query())
        return self.cached[1]

    def owns(self, bucket: str, value: str) -> bool:
        # A Dispatch or Task created a moment ago isn't in the cached view yet.
        return value in getattr(self.get(), bucket) or value in getattr(self.get(fresh=True), bucket)


Upstream = Callable[[str, dict | None], Awaitable[object]]
ResultFilter = Callable[[object], object]


@dataclass
class Admitted:
    params: dict | None
    evidence: dict | None = None
    on_result: ResultFilter | None = None


@dataclass(frozen=True)
class Spec:
    """One reviewed RPC method: the params it may carry, those naming its caller, those naming
    what it acts on, values forced on the way through, and any further check."""

    keys: frozenset[str] = frozenset()
    callers: tuple[tuple[str, str], ...] = ()
    targets: tuple[tuple[str, str], ...] = ()
    force: tuple[tuple[str, object], ...] = ()
    check: Callable | None = None
    null_params: bool = False
    needs_identity: bool = False
    bot_only: bool = False
    evidence: str | None = None


def spec(*keys: str, callers=None, targets=None, force=None, **options) -> Spec:
    callers, targets, force = callers or {}, targets or {}, force or {}
    return Spec(
        keys=frozenset(keys) | set(callers) | set(targets) | set(force),
        callers=tuple(callers.items()),
        targets=tuple(targets.items()),
        force=tuple(force.items()),
        **options,
    )


def orchestration(*keys: str, **options) -> Spec:
    return spec(*keys, needs_identity=True, evidence="orchestration", **options)


def owned(*keys: str, **options) -> Spec:
    return spec(*keys, needs_identity=True, **options)


def bot(*keys: str, callers=None, **options) -> Spec:
    callers = callers if callers is not None else {"callerSessionId": "session"}
    return spec(*keys, callers=callers, needs_identity=True, bot_only=True, evidence="session", **options)


async def check_worker_start(policy: "Policy", admitted: Admitted) -> None:
    params = admitted.params
    if "agent" not in params and policy.agent in SANDBOX_AGENTS:
        params["agent"] = policy.agent
    policy.check_agent(params.get("agent"))
    if params.get("worktree") not in (None, "current", "new-child", "new-top-level"):
        await policy.check_worktree(params["worktree"])


async def check_worktree_create(policy: "Policy", admitted: Admitted) -> None:
    params = admitted.params
    policy.check_agent(params.get("startupAgent"))
    policy.check_agent(params.get("createdWithAgent"))
    for key in ("parentWorktree", "cwdParentWorktree", "envParentWorkspace"):
        if params.get(key) not in (None, ""):
            await policy.check_worktree(params[key])
    admitted.on_result = policy.note_worktree


async def local_host(policy: "Policy", admitted: Admitted) -> None:
    if admitted.params.get("hostId") not in (None, "local"):
        raise Denied("Sandboxes act only on this machine's own worktrees.")


async def check_tab_create(policy: "Policy", admitted: Admitted) -> None:
    policy.check_url(admitted.params.get("url"))
    admitted.params["profileId"] = await policy.preview_profile()
    admitted.on_result = policy.note_tab


async def check_goto(policy: "Policy", admitted: Admitted) -> None:
    policy.check_url(admitted.params.get("url"))


async def own_tabs(policy: "Policy", admitted: Admitted) -> None:
    admitted.on_result = policy.only_own_tabs


async def owned_workers(policy: "Policy", admitted: Admitted) -> None:
    admitted.on_result = policy.only_owned("workers", "dispatchId", "dispatches")


async def owned_tasks(policy: "Policy", admitted: Admitted) -> None:
    admitted.on_result = policy.only_owned("tasks", "id", "tasks")


async def own_inbox(policy: "Policy", admitted: Admitted) -> None:
    # Without a recipient, inbox lists every party's mail.
    admitted.params["terminal"] = policy.identity.terminal or policy.identity.session_address


async def own_bot(policy: "Policy", admitted: Admitted) -> None:
    for key in ("botId", "bot"):
        if admitted.params.get(key) not in (None, "") and admitted.params[key] != await policy.own_bot_id():
            raise Denied("A sandboxed bot acts only for itself: omit --bot.")


async def only_own_bot(policy: "Policy", admitted: Admitted) -> None:
    await own_bot(policy, admitted)
    admitted.params["botId"] = await policy.own_bot_id()


TERMINAL = {"terminal": "terminal"}
DISPATCH = {"dispatch": "dispatch"}
ITEM_WRITE = ("retryRequest",)

METHODS: dict[str, Spec] = {
    "status.get": spec(),
    "repo.list": spec("repos"),
    "repo.show": spec("repo", "repoHostId"),
    "repo.searchRefs": spec("limit", "namespace", "query", "repo"),
    "worktree.list": spec("limit", "repo"),
    "worktree.show": spec("worktree", "matchFolderWorkspaces"),
    "worktree.lineageList": spec(null_params=True),
    "folderWorkspace.list": spec(null_params=True),
    "projectGroup.list": spec(null_params=True),
    "worktree.resolveCallerParent": spec(
        "comment",
        "cwdParentAmbiguous",
        "cwdParentWorktree",
        "envParentWorkspace",
        callers={"callerTerminalHandle": "sender"},
    ),
    "skills.discover": spec(),
    "bots.list": spec(null_params=True),
    "bots.roster": spec("allComputers", "withoutChats", callers={"callerSessionId": "session"}),
    "terminal.read": owned("cursor", "limit", "screen", targets=TERMINAL),
    "terminal.show": owned(targets=TERMINAL),
    "terminal.wait": owned("for", "timeoutMs", targets=TERMINAL),
    "terminal.resolveIdentity": owned(targets=TERMINAL),
    "terminal.rename": owned("title", targets=TERMINAL),
    "terminal.setPaneTitle": owned("title", targets=TERMINAL),
    "terminal.focus": owned("navigation", targets=TERMINAL),
    "agentSession.rename": owned("name", "legacyAlias", callers={"sessionId": "session"}),
    "worktree.set": owned(
        "displayName",
        "comment",
        "workspaceStatus",
        "isUnread",
        "isPinned",
        "linkedIssue",
        "linkedPR",
        "acknowledgeAttention",
        "matchFolderWorkspaces",
        targets={"worktree": "worktree"},
    ),
    "worktree.activate": owned("navigation", "notifyClients", targets={"worktree": "worktree"}),
    # Archive hooks from a repository's orca.yaml would run on the host.
    "worktree.rm": owned(
        "deleteBranch",
        "force",
        "allowUnverifiedPtyStop",
        "waitForBackgroundRemoval",
        "approvedNestedWorktrees",
        "allowFailedArchiveHook",
        "hostId",
        targets={"worktree": "worktree"},
        force={"runHooks": False},
        check=local_host,
    ),
    # Setup scripts and startup commands would run on the host; startup agents run sandboxed.
    "worktree.create": owned(
        "repo",
        "repoHostId",
        "name",
        "nameWasGenerated",
        "baseBranch",
        "compareBaseRef",
        "branchNameOverride",
        "branchIntent",
        "comment",
        "displayName",
        "displayNameKind",
        "workspaceStatus",
        "activate",
        "navigation",
        "parentWorktree",
        "cwdParentWorktree",
        "cwdParentAmbiguous",
        "envParentWorkspace",
        "noParent",
        "matchFolderWorkspaces",
        "startupAgent",
        "startupPrompt",
        "createdWithAgent",
        "launchSource",
        "telemetrySource",
        "clientMutationId",
        "creationId",
        "cliProvenanceRequest",
        callers={"callerTerminalHandle": "sender", "callerAgentSessionId": "session"},
        force={"setupDecision": "skip", "runHooks": False},
        check=check_worktree_create,
    ),
    "orchestration.callerShow": orchestration(null_params=True),
    "orchestration.check": orchestration(
        "unread",
        "peek",
        "all",
        "types",
        "format",
        "ack",
        "compatibilityAck",
        "compatibilityQuestionAck",
        "compatibilityCliCommand",
        "wait",
        "timeoutMs",
        callers={"terminal": "sender", "terminalPaneKey": "pane"},
        targets={"run": "run"},
    ),
    "orchestration.send": orchestration(
        "to",
        "subject",
        "body",
        "type",
        "priority",
        "threadId",
        "payload",
        "waitForLifecycleSettlement",
        "devMode",
        callers={"from": "sender", "senderPaneKey": "pane"},
        targets={"run": "run"},
    ),
    "orchestration.ask": orchestration(
        "to",
        "question",
        "resume",
        "options",
        "timeoutMs",
        "wait",
        "compatibilityCliCommand",
        "compatibilityWindowsCommand",
        callers={"from": "sender"},
        targets={"run": "run"},
    ),
    "orchestration.reply": orchestration("id", "body", callers={"from": "sender"}, targets={"run": "run"}),
    "orchestration.inbox": orchestration("limit", "terminal", targets={"run": "run"}, check=own_inbox),
    "orchestration.runCurrent": orchestration(callers={"from": "sender"}),
    "orchestration.runShow": orchestration("removed", "cursor", callers={"from": "sender"}, targets={"id": "run"}),
    "orchestration.runCreate": orchestration("objective", callers={"from": "sender"}),
    "orchestration.runUse": orchestration(callers={"from": "sender"}, targets={"id": "run"}),
    "orchestration.taskCreate": orchestration(
        "spec",
        "taskTitle",
        "displayName",
        callers={"callerTerminalHandle": "sender"},
        targets={"run": "run", "parent": "task", "deps": "tasks"},
    ),
    "orchestration.taskList": orchestration(
        "status",
        "ready",
        "brief",
        callers={"callerTerminalHandle": "sender"},
        targets={"run": "run"},
        check=owned_tasks,
    ),
    "orchestration.taskUpdate": orchestration(
        "status", "result", callers={"callerTerminalHandle": "sender"}, targets={"id": "task", "run": "run"}
    ),
    "orchestration.dispatchShow": orchestration(
        "preamble", "devMode", callers={"from": "sender"}, targets={"task": "task"}
    ),
    "orchestration.workerStart": orchestration(
        "spec",
        "taskTitle",
        "worktree",
        "name",
        "repo",
        "baseBranch",
        "displayName",
        "comment",
        "agent",
        "model",
        "effort",
        "timeoutMs",
        "origin",
        "devMode",
        callers={"from": "sender"},
        targets={"task": "task", "parent": "task", "deps": "tasks", "run": "run", "retryOf": "dispatch"},
        # A repository's committed setup script would run on the host.
        force={"setup": "skip"},
        check=check_worker_start,
    ),
    "orchestration.workerList": orchestration(
        "cursor", "limit", "paginate", "terminalState", targets={"run": "run"}, check=owned_workers
    ),
    "orchestration.workerShow": orchestration(targets=DISPATCH),
    "orchestration.workerRead": orchestration("cursor", "limit", "source", targets=DISPATCH),
    "orchestration.workerTranscript": orchestration(targets=DISPATCH),
    "orchestration.workerStop": orchestration(targets=DISPATCH),
    "orchestration.workerRelease": orchestration(targets=DISPATCH),
    "orchestration.workerRetain": orchestration(targets=DISPATCH),
    "orchestration.workerAbandon": orchestration(targets=DISPATCH),
    "orchestration.approvalAnswer": orchestration(
        "decision", "prompt", "reason", callers={"from": "sender"}, targets=DISPATCH
    ),
    "orchestration.requestShow": orchestration("request"),
    "orchestration.gateCreate": orchestration(
        "options", "question", callers={"from": "sender"}, targets={"run": "run", "task": "task"}
    ),
    "orchestration.gateResolve": orchestration("id", "resolution", callers={"from": "sender"}, targets={"run": "run"}),
    "orchestration.gateList": orchestration(
        "status", callers={"from": "sender"}, targets={"run": "run", "task": "task"}
    ),
    # Orca's browser only shows the human this sandbox's preview pages, in a profile with no
    # sign-ins. Agents drive pages with the Chromium inside their sandbox.
    "browser.tabCreate": spec(
        "url", "activate", "placement", "worktree", "waitForRegistration", check=check_tab_create
    ),
    "browser.tabList": spec("worktree", check=own_tabs),
    "browser.goto": spec("url", "worktree", targets={"page": "page"}, check=check_goto),
    "browser.tabClose": spec("worktree", targets={"page": "page"}),
    "bots.chats": bot("all", "botId", check=own_bot),
    "bots.items.list": bot("all", "botId", "chat", "cursor", "here", "limit", "link", "statuses", check=own_bot),
    "bots.items.show": bot("after", "botId", "item", "limit", check=own_bot),
    # Orca checks each item write against the session the relay names. Attached files would be
    # read from the host.
    "bots.items.add": bot(
        "bot", "chat", "description", "doneMeans", "forBot", "links", "status", "title", *ITEM_WRITE, check=own_bot
    ),
    "bots.items.set": bot(
        "ask", "comment", "description", "doneMeans", "item", "note", "reason", "status", "title", *ITEM_WRITE
    ),
    "bots.items.comment": bot("item", "text", *ITEM_WRITE),
    "bots.items.done": bot("item", "note", *ITEM_WRITE),
    "bots.items.cancel": bot("item", "reason", *ITEM_WRITE),
    "bots.items.link": bot("item", "refs", *ITEM_WRITE),
    "bots.memory.edit": bot("fact", "text", "botId", check=only_own_bot),
    "bots.memory.forget": bot("fact", "botId", check=only_own_bot),
    "bots.memory.history": bot("botId", check=only_own_bot),
    "bots.memory.undo": bot("id", "botId", check=only_own_bot),
    "connector.reply": bot("replyId", "text", "review", callers={"paneKey": "pane", "sessionId": "session"}),
    "connector.react": bot("emoji", callers={"sessionId": "session"}),
    "connector.act": bot("args", "ref", "verb", callers={"sessionId": "session"}),
}
# Bot memory and connector schemas have no callerSessionId; Orca binds them by botId or sessionId.
SESSIONLESS_BOT_METHODS = frozenset(
    {
        "bots.memory.edit",
        "bots.memory.history",
        "bots.memory.undo",
        "connector.reply",
        "connector.react",
        "connector.act",
    }
)


class Policy:
    def __init__(
        self,
        agent: str,
        identity: Identity,
        bot: bool,
        preview_file: Path | None,
        ownership: Ownership,
        upstream: Upstream,
    ):
        self.agent = agent
        self.identity = identity
        self.bot = bot
        self.preview_file = preview_file
        self.ownership = ownership
        self.upstream = upstream
        self.pages: set[str] = set()
        self.worktrees: set[str] = set()
        self.bot_id: str | None = None
        self.profile_id: str | None = None

    def preview_origins(self) -> set[str]:
        if self.preview_file is None:
            return set()
        try:
            text = self.preview_file.read_text(encoding="utf-8")
        except OSError:
            return set()
        return {origin for line in text.splitlines() if (origin := normalize_origin(line.strip()))}

    def check_url(self, url) -> None:
        if not isinstance(url, str) or normalize_origin(url) not in self.preview_origins():
            raise Denied("Orca's browser opens only this sandbox's $AGENT_PREVIEW_URL_* addresses.")

    def check_agent(self, agent) -> None:
        if agent is not None and agent not in SANDBOX_AGENTS:
            raise Denied(
                f"Sandboxed agents start only {', '.join(sorted(SANDBOX_AGENTS))}, which Orca runs in a sandbox."
            )

    def check_evidence(self, evidence) -> None:
        """The CLI's own caller evidence must name this sandbox's launch, or it names someone else."""
        if evidence is None:
            return
        if not isinstance(evidence, dict):
            raise Denied("Malformed caller evidence.")
        own = self.identity.evidence()
        for key, value in evidence.items():
            if key not in EVIDENCE_KEYS:
                raise Denied(f"Caller evidence from a sandbox can't carry {key}.")
            if value not in (None, "") and value != own.get(key):
                raise Denied("Caller evidence must name this sandbox's own Orca session.")

    def check_caller(self, key: str, kind: str, value) -> None:
        if value in (None, ""):
            return
        allowed = {
            "sender": self.identity.senders,
            "pane": self.identity.panes,
            "session": self.identity.sessions,
        }[kind]()
        if value not in allowed:
            raise Denied(f"{key} must name this sandbox's own Orca session.")

    async def check_target(self, key: str, kind: str, value) -> None:
        # Orca acts on the user's current tab when no page is named.
        if kind == "page" and not (isinstance(value, str) and value):
            raise Denied("Name the tab with --page: sandboxed agents manage only the Orca browser tabs they opened.")
        if value in (None, ""):
            return
        if not isinstance(value, str):
            raise Denied(f"Malformed {key}.")
        if kind == "page":
            if value not in self.pages:
                raise Denied("Sandboxed agents manage only the Orca browser tabs they opened.")
        elif kind == "worktree":
            await self.check_worktree(value)
        elif kind == "tasks":
            for task in filter(None, (part.strip() for part in value.split(","))):
                await self.check_target(key, "task", task)
        else:
            bucket = {"run": "runs", "dispatch": "dispatches", "task": "tasks", "terminal": "terminals"}[kind]
            if not self.ownership.owns(bucket, value):
                raise Denied(f"{key} {value} isn't this sandbox's own or one of its workers'.")

    async def check_worktree(self, selector) -> None:
        """Owned: this sandbox's worktree, its workers', ones it created, and their descendants."""
        if not isinstance(selector, str) or not selector:
            raise Denied("Malformed worktree selector.")
        owned = self.ownership.get(fresh=True).worktrees | self.worktrees
        query = selector
        for _ in range(LINEAGE_DEPTH):
            if query.startswith("id:") and query[3:] in owned:
                return
            try:
                result = await self.upstream("worktree.show", {"worktree": query})
            except Unavailable as error:
                raise Denied(f"worktree {selector} can't be checked: {error}") from error
            worktree = result.get("worktree") if isinstance(result, dict) else None
            if not isinstance(worktree, dict) or not isinstance(worktree.get("id"), str):
                break
            if worktree["id"] in owned:
                return
            parent = worktree.get("parentWorktreeId")
            if not isinstance(parent, str) or not parent:
                break
            query = f"id:{parent}"
        raise Denied(f"worktree {selector} isn't this sandbox's own worktree or one of its descendants.")

    async def own_bot_id(self) -> str:
        if self.bot_id is None:
            try:
                chats = await self.upstream("bots.chats", {"callerSessionId": self.identity.session_id})
                listed = await self.upstream("bots.list", None)
            except Unavailable as error:
                raise Denied(f"This sandbox's bot can't be identified: {error}") from error
            name = chats.get("bot") if isinstance(chats, dict) else None
            entries = listed.get("bots") if isinstance(listed, dict) else None
            matches = [
                entry["id"]
                for entry in entries or []
                if isinstance(entry, dict) and entry.get("name") == name and isinstance(entry.get("id"), str)
            ]
            if not name or len(matches) != 1:
                raise Denied("This sandbox's bot can't be identified.")
            self.bot_id = matches[0]
        return self.bot_id

    async def preview_profile(self) -> str:
        if self.profile_id is None:
            try:
                listed = await self.upstream("browser.profileList", None)
                profiles = listed.get("profiles") if isinstance(listed, dict) else None
                found = [
                    profile["id"]
                    for profile in profiles or []
                    if isinstance(profile, dict)
                    and profile.get("label") == PREVIEW_PROFILE_LABEL
                    and profile.get("scope") == "isolated"
                    and isinstance(profile.get("id"), str)
                ]
                if not found:
                    created = await self.upstream(
                        "browser.profileCreate", {"label": PREVIEW_PROFILE_LABEL, "scope": "isolated"}
                    )
                    profile = created.get("profile") if isinstance(created, dict) else None
                    if not isinstance(profile, dict) or not isinstance(profile.get("id"), str):
                        raise Unavailable("Orca created no profile")
                    found = [profile["id"]]
            except Unavailable as error:
                raise Denied(f"Orca's isolated preview profile is unavailable: {error}") from error
            self.profile_id = found[0]
        return self.profile_id

    def note_tab(self, result):
        if isinstance(result, dict) and isinstance(result.get("browserPageId"), str):
            self.pages.add(result["browserPageId"])
        return result

    def note_worktree(self, result):
        worktree = result.get("worktree") if isinstance(result, dict) else None
        if isinstance(worktree, dict) and isinstance(worktree.get("id"), str):
            self.worktrees.add(worktree["id"])
        return result

    def only_own_tabs(self, result):
        if not isinstance(result, dict) or not isinstance(result.get("tabs"), list):
            raise ValueError("unexpected tab list")
        tabs = [tab for tab in result["tabs"] if isinstance(tab, dict) and tab.get("browserPageId") in self.pages]
        return {**result, "tabs": tabs}

    def only_owned(self, collection: str, key: str, bucket: str) -> ResultFilter:
        def keep(result):
            if not isinstance(result, dict) or not isinstance(result.get(collection), list):
                raise ValueError(f"unexpected {collection} list")
            mine = getattr(self.ownership.get(fresh=True), bucket)
            items = [item for item in result[collection] if isinstance(item, dict) and item.get(key) in mine]
            return {**result, collection: items}

        return keep

    async def admit(self, method: str, params) -> Admitted:
        """Return what to forward upstream, or raise Denied. Unknown methods and params are refused."""
        spec = METHODS.get(method)
        if spec is None or (spec.bot_only and not self.bot):
            raise Denied(f"'{method}' is not available to sandboxed agents.")
        if spec.needs_identity and not self.identity.known:
            raise Denied("This sandbox was started without an Orca session, so it can't act as one.")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            raise Denied("Malformed params.")
        if spec.null_params and params:
            raise Denied(f"'{method}' takes no params.")
        unknown = sorted(set(params) - spec.keys)
        if unknown:
            raise Denied(f"'{method}' from a sandbox can't set {', '.join(unknown)}.")
        for key, kind in spec.callers:
            self.check_caller(key, kind, params.get(key))
        for key, kind in spec.targets:
            await self.check_target(key, kind, params.get(key))
        admitted = Admitted(dict(params))
        if spec.bot_only and method not in SESSIONLESS_BOT_METHODS:
            admitted.params["callerSessionId"] = self.identity.session_id
        if method.startswith("connector."):
            admitted.params.pop("paneKey", None)
            admitted.params["sessionId"] = self.identity.session_id
        admitted.params.update(spec.force)
        if spec.check is not None:
            await spec.check(self, admitted)
        if spec.evidence == "orchestration":
            admitted.evidence = self.identity.evidence()
        elif (spec.evidence == "session" or method.startswith("browser.")) and self.identity.session_id:
            admitted.evidence = {"agentSessionId": self.identity.session_id}
        if spec.null_params:
            admitted.params = None
        return admitted


def normalize_origin(url: str) -> str | None:
    try:
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            return None
        port = parts.port or (443 if parts.scheme == "https" else 80)
    except ValueError:
        return None
    return f"{parts.scheme}://{parts.hostname.lower()}:{port}"


def bounded_string(value) -> bool:
    return isinstance(value, str) and 0 < len(value) <= MAX_ID


class Relay:
    def __init__(self, host_data: Path, data: Path, container_data: str, policy: Policy):
        self.host_data = host_data
        self.data = data
        self.socket = data / "relay.sock"
        self.container_socket = f"{container_data}/relay.sock"
        self.policy = policy
        self.slots = asyncio.Semaphore(MAX_CONNECTIONS)
        self.last: tuple | None = None

    def host_metadata(self) -> dict | None:
        try:
            metadata = json.loads((self.host_data / "orca-runtime.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return metadata if isinstance(metadata, dict) else None

    def host_socket(self, metadata: dict) -> str | None:
        for transport in metadata.get("transports") or []:
            if (
                isinstance(transport, dict)
                and transport.get("kind") == "unix"
                and isinstance(transport.get("endpoint"), str)
            ):
                return transport["endpoint"]
        return None

    def upstream_endpoint(self) -> tuple[str, str]:
        metadata = self.host_metadata()
        endpoint = self.host_socket(metadata) if metadata else None
        token = metadata.get("authToken") if metadata else None
        if not endpoint or not isinstance(token, str) or not token:
            raise Unavailable("Orca is not running on the host.")
        return endpoint, token

    async def call(self, method: str, params: dict | None) -> object:
        """One request of the relay's own, for the checks it makes before forwarding."""
        endpoint, token = self.upstream_endpoint()
        request = {"id": f"relay-{uuid.uuid4()}", "authToken": token, "method": method}
        if params is not None:
            request["params"] = params
        try:
            reader, writer = await asyncio.open_unix_connection(endpoint, limit=MAX_RESPONSE)
        except OSError as error:
            raise Unavailable("Could not reach Orca on the host.") from error
        try:
            writer.write(json.dumps(request).encode() + b"\n")
            await writer.drain()
            async with asyncio.timeout(UPSTREAM_TIMEOUT):
                while True:
                    frame = json.loads(await reader.readuntil(b"\n"))
                    if isinstance(frame, dict) and frame.get("id") == request["id"]:
                        break
        except (OSError, ValueError, TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError) as error:
            raise Unavailable(f"{method} failed") from error
        finally:
            writer.close()
        if frame.get("ok") is not True:
            error = frame.get("error") if isinstance(frame.get("error"), dict) else {}
            raise Unavailable(f"{method}: {error.get('code', 'error')}")
        return frame.get("result")

    def write(self, name: str, content: bytes, mode: int) -> None:
        target = self.data / name
        temp = target.with_name(f".{target.name}.tmp")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
        with os.fdopen(fd, "wb") as file:
            file.write(content)
        os.chmod(temp, mode)
        os.replace(temp, target)

    def refresh(self) -> None:
        """Mirror the desktop's runtime identity, never its token, into the sandbox's profile."""
        metadata = self.host_metadata()
        shim = self.host_data / "linux-orca-cli-shim" / "orca"
        try:
            shim_content = shim.read_bytes()
        except OSError:
            shim_content = None
        key = (json.dumps(metadata, sort_keys=True) if metadata else None, shim_content)
        if key == self.last:
            return
        self.last = key
        if metadata and self.host_socket(metadata):
            synthetic = {
                "runtimeId": metadata.get("runtimeId"),
                "pid": metadata.get("pid"),
                "transports": [{"kind": "unix", "endpoint": self.container_socket}],
                "authToken": DUMMY_TOKEN,
                "startedAt": metadata.get("startedAt"),
            }
            self.write("orca-runtime.json", json.dumps(synthetic).encode(), 0o600)
        else:
            (self.data / "orca-runtime.json").unlink(missing_ok=True)
        if shim_content is not None:
            (self.data / "linux-orca-cli-shim").mkdir(mode=0o755, exist_ok=True)
            self.write("linux-orca-cli-shim/orca", shim_content, 0o755)

    async def refresh_loop(self) -> None:
        while True:
            try:
                self.refresh()
            except OSError as error:
                print(f"orca-relay: refresh failed: {error}", file=sys.stderr, flush=True)
            await asyncio.sleep(REFRESH_INTERVAL)

    def refusal(self, request_id, code: str, message: str, runtime_id) -> bytes:
        frame = {
            "id": request_id if bounded_string(request_id) else "unknown",
            "ok": False,
            "error": {"code": code, "message": message},
            "_meta": {"runtimeId": runtime_id},
        }
        return json.dumps(frame).encode() + b"\n"

    async def envelope(self, request: dict, token: str) -> tuple[dict, Admitted]:
        """The upstream request, built from known fields only and naming this sandbox's launch."""
        method = request.get("method")
        if not isinstance(method, str) or not method:
            raise Denied("Missing RPC method.")
        for key in ("orchestrationPeerRun", "executionHost"):
            if request.get(key) is not None:
                raise Denied(f"A sandbox can't send {key}.")
        self.policy.check_evidence(request.get("orchestrationCompatibilityEvidence"))
        admitted = await self.policy.admit(method, request.get("params"))
        upstream = {"id": request["id"], "authToken": token, "method": method}
        if admitted.params is not None:
            upstream["params"] = admitted.params
        version = request.get("orchestrationContractVersion")
        if isinstance(version, int) and not isinstance(version, bool):
            upstream["orchestrationContractVersion"] = version
        for key in ("orchestrationRequestId", "compatibilityInvocationId"):
            if bounded_string(request.get(key)):
                upstream[key] = request[key]
        if admitted.evidence:
            upstream["orchestrationCompatibilityEvidence"] = admitted.evidence
        return upstream, admitted

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self.slots.locked():
            writer.close()
            return
        async with self.slots:
            upstream_writer = None
            pump = None
            # Orca answers by request ID and allows duplicates, so each forwarded request gets an ID
            # of the relay's own that maps back to the caller's ID and the answer's filter.
            pending: dict[str, tuple[str, ResultFilter | None]] = {}
            try:
                while True:
                    try:
                        line = await reader.readuntil(b"\n")
                    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError):
                        return
                    if not line.strip():
                        continue
                    metadata = self.host_metadata()
                    runtime_id = metadata.get("runtimeId") if metadata else None
                    try:
                        request = json.loads(line)
                        if not isinstance(request, dict) or not bounded_string(request.get("id")):
                            raise ValueError
                    except ValueError:
                        writer.write(self.refusal(None, "bad_request", "Invalid JSON request", runtime_id))
                        await writer.drain()
                        return
                    request_id, method = request["id"], request.get("method")
                    try:
                        endpoint, token = self.upstream_endpoint()
                    except Unavailable as error:
                        writer.write(self.refusal(request_id, "runtime_unavailable", str(error), runtime_id))
                        await writer.drain()
                        continue
                    try:
                        upstream, admitted = await self.envelope(request, token)
                    except (Denied, Unavailable) as denied:
                        print(f"orca-relay: denied {method}: {denied}", file=sys.stderr, flush=True)
                        writer.write(self.refusal(request_id, "forbidden", str(denied), runtime_id))
                        await writer.drain()
                        continue
                    if upstream_writer is None:
                        try:
                            upstream_reader, upstream_writer = await asyncio.open_unix_connection(
                                endpoint, limit=MAX_RESPONSE
                            )
                        except OSError:
                            writer.write(
                                self.refusal(
                                    request_id, "runtime_unavailable", "Could not reach Orca on the host.", runtime_id
                                )
                            )
                            await writer.drain()
                            return
                        pump = asyncio.create_task(self.pump(upstream_reader, writer, pending))
                    if len(pending) >= MAX_IN_FLIGHT:
                        writer.write(self.refusal(request_id, "bad_request", "Too many requests", runtime_id))
                        await writer.drain()
                        return
                    upstream["id"] = f"relay-{uuid.uuid4()}"
                    pending[upstream["id"]] = (request_id, admitted.on_result)
                    upstream_writer.write(json.dumps(upstream).encode() + b"\n")
                    await upstream_writer.drain()
                    print(f"orca-relay: {method}", file=sys.stderr, flush=True)
            except (OSError, asyncio.CancelledError):
                pass
            finally:
                # The CLI closes once it has its answer; a long poll it abandons ends with it.
                if pump is not None:
                    pump.cancel()
                if upstream_writer is not None:
                    upstream_writer.close()
                writer.close()

    async def pump(
        self,
        upstream: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        pending: dict[str, tuple[str, ResultFilter | None]],
    ) -> None:
        try:
            while True:
                try:
                    line = await upstream.readuntil(b"\n")
                except asyncio.IncompleteReadError:
                    break
                line = self.rewrite(line, pending)
                if line is not None:
                    writer.write(line)
                    await writer.drain()
        except (OSError, asyncio.LimitOverrunError):
            pass
        finally:
            try:
                writer.write_eof()
            except OSError:
                pass

    def rewrite(self, line: bytes, pending: dict[str, tuple[str, ResultFilter | None]]) -> bytes | None:
        """Give an answer back its caller's ID, filtered; drop what answers no forwarded request."""
        try:
            frame = json.loads(line)
        except ValueError:
            return None
        if not isinstance(frame, dict):
            return None
        if "id" not in frame:
            return line if frame.get("_keepalive") is True else None
        if frame["id"] not in pending:
            return None
        # Streaming methods answer one request with several frames, so the mapping stays for the connection.
        frame["id"], on_result = pending[frame["id"]]
        if on_result is None or frame.get("ok") is not True:
            return json.dumps(frame).encode() + b"\n"
        try:
            frame["result"] = on_result(frame.get("result"))
        except (Unavailable, ValueError) as error:
            print(f"orca-relay: withheld an answer it couldn't check: {error}", file=sys.stderr, flush=True)
            meta = frame.get("_meta") if isinstance(frame.get("_meta"), dict) else {}
            return self.refusal(
                frame["id"], "forbidden", "The relay couldn't check Orca's answer.", meta.get("runtimeId")
            )
        return json.dumps(frame).encode() + b"\n"

    async def serve(self) -> None:
        self.socket.unlink(missing_ok=True)
        self.refresh()
        server = await asyncio.start_unix_server(self.handle, path=str(self.socket), limit=MAX_REQUEST + 1)
        os.chmod(self.socket, 0o600)
        refresher = asyncio.create_task(self.refresh_loop())
        async with server:
            try:
                await server.serve_forever()
            finally:
                refresher.cancel()


def build(
    host_data: Path,
    data: Path,
    container_data: str,
    agent: str,
    identity: Identity,
    bot: bool,
    preview_file: Path | None,
) -> Relay:
    relay: Relay | None = None

    async def upstream(method: str, params: dict | None) -> object:
        return await relay.call(method, params)

    policy = Policy(agent, identity, bot, preview_file, Ownership(host_data / "orchestration.db", identity), upstream)
    relay = Relay(host_data, data, container_data, policy)
    return relay


def main() -> None:
    parser = argparse.ArgumentParser(prog="orca-relay")
    parser.add_argument("--host-data", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--container-data", required=True)
    parser.add_argument("--agent", default="")
    parser.add_argument("--bot", action="store_true")
    parser.add_argument("--preview-file", type=Path)
    args = parser.parse_args()
    # Orca's launch variables as the launcher on the host received them; the sandbox can't change them.
    identity = Identity.from_env(os.environ)
    relay = build(args.host_data, args.data, args.container_data, args.agent, identity, args.bot, args.preview_file)
    asyncio.run(relay.serve())


if __name__ == "__main__":
    main()
