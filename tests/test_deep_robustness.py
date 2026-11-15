"""Deep negative tests: corrupt state, process races and malformed API envelopes.

No Telegram, VPN or host system commands are used. Run on Linux:
    python3 tests/test_deep_robustness.py
"""
import asyncio
import hashlib
import hmac
import json
import multiprocessing
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "awg_bot"))
from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402
from awgbot import admins, alerts, api, share, store, web as web_panel, webapp  # noqa: E402


def invite_process(token, uid, start, results):
    start.wait(15)
    try:
        results.put(admins.consume_invite(token, uid)[0])
    except Exception as exc:  # a worker failure must be visible to the parent
        results.put(repr(exc))


def notes_process(prefix, start, results):
    start.wait(15)
    try:
        for i in range(40):
            store.set_note(f"{prefix}-{i}", f"note {i}")
        results.put(True)
    except Exception as exc:
        results.put(repr(exc))


class CorruptStateTests(unittest.IsolatedAsyncioTestCase):
    async def test_share_numeric_string_is_normalized_and_page_opens(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(store, "STATE_DIR", Path(tmp)):
            token = "A" * 32
            key = share._digest(token)
            now = time.time()
            (Path(tmp) / "shares.json").write_text(json.dumps({key: {
                "name": "alice", "pub": "public", "exp": str(now + 300),
                "made": "broken", "by": "test", "opens": 0,
            }}))
            app = web.Application()
            share.setup(app)
            client = TestClient(TestServer(app))
            await client.start_server()
            self.addAsyncCleanup(client.close)
            response = await client.get("/s/" + token)
            self.assertEqual(response.status, 200, await response.text())
            self.assertIsInstance(share._lookup(token)["exp"], float)

    async def test_corrupt_admins_fields_do_not_break_owner_operations(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(admins, "ADMINS_FILE", str(Path(tmp) / "admins.json")):
            Path(admins.ADMINS_FILE).write_text(json.dumps({"version": 1, "admins": {
                "123": {"username": "alice", "added_by": "bad", "added_at": []},
                "-5": {"username": "invalid"},
            }, "invites": {"bad": {"by": 1, "exp": "broken"}}}))
            self.assertEqual(admins.pending_invites(), 0)
            rows = admins.list_invited()
            self.assertEqual(len(rows), 1)
            self.assertEqual(admins.invited_ids(), {123})
            self.assertEqual((rows[0].added_by, rows[0].added_at), (0, 0))
            token, _ = admins.create_invite(1)
            self.assertIsInstance(token, str)
            data = json.loads(Path(admins.ADMINS_FILE).read_text())
            data["invites"][admins._hash(token)]["by"] = "broken"
            Path(admins.ADMINS_FILE).write_text(json.dumps(data))
            self.assertTrue(admins.consume_invite(token, 456)[0])
            self.assertEqual(next(a for a in admins.list_invited() if a.uid == 456).added_by, 0)

    async def test_corrupt_alert_timestamps_and_backup_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(alerts, "CONFIG", Path(tmp) / "alerts.json"), \
                    patch.object(alerts, "BACKUP_STATE", Path(tmp) / "autobackup.json"):
                alerts.store.save(alerts.CONFIG, {"backup": {"mode": "day", "keep": 7}})
                alerts.store.save(alerts.BACKUP_STATE, {"last": "bad", "slot": [], "retry_at": {}})
                info = alerts.backup_info()
                self.assertIsNone(info["last"])
                self.assertIsNone(info["next"])
                state = {"support_since": "bad"}
                await alerts.support_tick(Mock(), state, int(time.time()))
                self.assertIsInstance(state["support_since"], int)

    async def test_corrupt_alert_counters_survive_failure_and_recovery(self):
        status = {"host": "test", "server": {"exists": True, "up": False},
                  "tunnels": {"warp_failed": True}}

        async def data(section, *args, **kwargs):
            if section == "status":
                return status
            if status["tunnels"].get("warp") == "up":
                return {"up": True, "ok": True}
            return {}

        state = {"down": "bad", "down_since": [], "warp_down": {}, "warp_since": "bad"}
        with patch.object(alerts.api, "data", side_effect=data), \
                patch.object(alerts, "notify", AsyncMock()), \
                patch.object(alerts, "_read", return_value=""), \
                patch.object(alerts, "cert_dates", return_value=None), \
                patch.object(alerts, "disk_pct", return_value=0):
            self.assertTrue(await alerts.tick(Mock(), state))
            self.assertIsInstance(state["down"], int)
            self.assertIsInstance(state["warp_down"], int)
            status["server"]["up"] = True
            status["tunnels"] = {"warp": "up"}
            state.update(down_sent=True, warp_sent=True, down_since=[], warp_since="bad")
            self.assertTrue(await alerts.tick(Mock(), state))
            for key in ("down", "down_since", "down_sent", "warp_down", "warp_since", "warp_sent"):
                self.assertNotIn(key, state)


class ProcessRaceTests(unittest.TestCase):
    def setUp(self):
        if "fork" not in multiprocessing.get_all_start_methods():
            self.skipTest("нужен Linux multiprocessing fork")
        self.ctx = multiprocessing.get_context("fork")

    def test_one_invite_succeeds_once_across_processes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(admins, "ADMINS_FILE", str(Path(tmp) / "admins.json")):
            for round_no in range(8):
                with self.subTest(round=round_no):
                    token, _ = admins.create_invite(1)
                    start, results = self.ctx.Event(), self.ctx.Queue()
                    workers = [self.ctx.Process(target=invite_process, args=(token, 1000 + round_no * 2 + i, start, results))
                               for i in range(2)]
                    for worker in workers:
                        worker.start()
                    start.set()
                    outcomes = [results.get(timeout=20) for _ in workers]
                    for worker in workers:
                        worker.join(20)
                        self.assertEqual(worker.exitcode, 0)
                    self.assertEqual(outcomes.count(True), 1, outcomes)
                    results.close()

    def test_parallel_notes_are_not_lost(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(store, "NOTES", Path(tmp) / "notes.json"):
            start, results = self.ctx.Event(), self.ctx.Queue()
            workers = [self.ctx.Process(target=notes_process, args=(prefix, start, results)) for prefix in ("a", "b")]
            for worker in workers:
                worker.start()
            start.set()
            outcomes = [results.get(timeout=30) for _ in workers]
            for worker in workers:
                worker.join(30)
                self.assertEqual(worker.exitcode, 0)
            self.assertEqual(outcomes, [True, True])
            self.assertEqual(len(store.notes()), 80)
            results.close()


class FakeProcess:
    def __init__(self, payload, returncode=1):
        self.payload = payload
        self.returncode = returncode

    async def communicate(self, data=None):
        return self.payload, b""


class ApiEnvelopeTests(unittest.IsolatedAsyncioTestCase):
    async def run_payload(self, value):
        payload = value if isinstance(value, bytes) else json.dumps(value).encode()
        with patch.object(api.asyncio, "create_subprocess_exec", AsyncMock(return_value=FakeProcess(payload))):
            return await api._run("status")

    async def test_non_object_and_invalid_fields_never_raise_or_report_success(self):
        for value in ([], None, "text", {"ok": "false", "rc": "bad", "log": [], "error": {"bad": True}}):
            with self.subTest(value=value):
                result = await self.run_payload(value)
                self.assertFalse(result.ok)
                self.assertIsInstance(result.rc, int)
                self.assertIsInstance(result.message, str)

    async def test_valid_envelope_is_unchanged(self):
        result = await self.run_payload({"ok": True, "rc": 0, "data": [1], "log": "ok", "error": ""})
        self.assertTrue(result.ok)
        self.assertEqual(result.data, [1])
        self.assertEqual(result.message, "ok")


class BackupRaceTests(unittest.IsolatedAsyncioTestCase):
    async def test_parallel_manual_and_scheduled_backup_run_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "backup.tar.gz"
            archive.write_bytes(b"backup")
            entered = asyncio.Event()
            release = asyncio.Event()

            async def create(*args, **kwargs):
                entered.set()
                await release.wait()
                return api.Result(True, data={"path": str(archive)})

            with patch.object(alerts, "CONFIG", root / "alerts.json"), \
                    patch.object(alerts, "BACKUP_STATE", root / "autobackup.json"), \
                    patch.object(alerts.api, "call", side_effect=create) as call, \
                    patch.object(alerts.access, "owners", return_value=[1]), \
                    patch.object(alerts, "_deliver", AsyncMock(return_value=True)):
                alerts.store.save(alerts.CONFIG, {"backup": {"mode": "day", "keep": 7}})
                first = asyncio.create_task(alerts.backup_due(Mock(), force=True))
                await asyncio.wait_for(entered.wait(), 5)
                self.assertEqual(await alerts.backup_due(Mock(), force=True), "busy")
                release.set()
                self.assertEqual(await first, "done")
                self.assertEqual(call.await_count, 1)


class AuthHardeningTests(unittest.TestCase):
    def signed_init_data(self, auth_date, token="1:token"):
        fields = {"auth_date": str(int(auth_date)), "query_id": "q",
                  "user": json.dumps({"id": 111}, separators=(",", ":"))}
        secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
        fields["hash"] = hmac.new(secret, "\n".join(f"{k}={v}" for k, v in sorted(fields.items())).encode(),
                                  hashlib.sha256).hexdigest()
        return urlencode(fields)

    def test_init_data_rejects_far_future_but_allows_clock_skew(self):
        now = 1_700_000_000
        token = "1:token"
        self.assertIsNone(webapp.check_init_data(self.signed_init_data(now + 301, token), token, now=now))
        self.assertIsNotNone(webapp.check_init_data(self.signed_init_data(now + 60, token), token, now=now))
        self.assertIsNone(webapp.check_init_data(self.signed_init_data(now - webapp.MAX_AGE - 1, token), token, now=now))

    def test_csrf_origin_requires_scheme_and_host(self):
        request = Mock(host="panel.example", scheme="https", headers={"Origin": "http://panel.example"})
        self.assertFalse(web_panel.same_origin(request))
        request.headers["Origin"] = "https://panel.example"
        self.assertTrue(web_panel.same_origin(request))
        request.headers["Origin"] = "https://evil.example"
        self.assertFalse(web_panel.same_origin(request))


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1], verbosity=2)
