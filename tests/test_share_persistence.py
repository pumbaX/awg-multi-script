"""Share storage failures, HTTP/Telegram responses and cross-process flock.

Uses temporary files and mocked API calls only; no VPN or system commands.
"""
import errno
import logging
import multiprocessing
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "awg_bot"))
from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402
from awgbot import api, panel, share, store  # noqa: E402
from awgbot.sections import clients  # noqa: E402


def consume(state, token, start, results):
    store.STATE_DIR = Path(state)
    share.OPENS_MAX = 7
    start.wait(15)
    results.put(sum(share._lookup(token, count=True) is not None for _ in range(10)))


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = patch.object(store, "STATE_DIR", Path(self.tmp.name))
        self.state.start()
        self.addCleanup(self.state.stop)
        share._fails.clear()

    def create(self):
        return share.create("alice", "TEST-PUBLIC", "test")

    def test_success_hash_permissions_revoke(self):
        token, rid, _ = self.create()
        raw = share._file().read_bytes()
        self.assertNotIn(token.encode(), raw)
        self.assertEqual(share._file().stat().st_mode & 0o777, 0o600)
        self.assertIsNotNone(share._lookup(token, count=True))
        self.assertTrue(share.revoke(rid))
        self.assertIsNone(share._lookup(token, count=True))
        self.assertFalse(share.revoke(rid))

    def test_failed_create_has_no_token_or_success_log(self):
        with patch.object(store, "save", return_value=False), patch.object(share.log, "info") as info:
            with self.assertRaisesRegex(RuntimeError, "хранилища"):
                self.create()
            info.assert_not_called()
        self.assertFalse(share._file().exists())

    def test_failed_revoke_preserves_bytes_and_does_not_log_success(self):
        token, rid, _ = self.create()
        raw = share._file().read_bytes()
        with patch.object(store, "save", return_value=False), patch.object(share.log, "info") as info:
            with self.assertRaisesRegex(RuntimeError, "хранилища"):
                share.revoke(rid)
            info.assert_not_called()
        self.assertEqual(share._file().read_bytes(), raw)
        self.assertIsNotNone(share._lookup(token))

    def test_failed_count_preserves_bytes_and_limit(self):
        token, _, _ = self.create()
        raw = share._file().read_bytes()
        with patch.object(store, "save", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "хранилища"):
                share._lookup(token, count=True)
        self.assertEqual(share._file().read_bytes(), raw)
        with patch.object(share, "OPENS_MAX", 2):
            self.assertIsNotNone(share._lookup(token, count=True))
            self.assertIsNotNone(share._lookup(token, count=True))
            self.assertIsNone(share._lookup(token, count=True))

    def test_disk_errors_leave_original_bytes_and_no_temporary_files(self):
        token, rid, _ = self.create()
        raw = share._file().read_bytes()
        for code in (errno.ENOSPC, errno.EIO):
            for op in (self.create, lambda: share.revoke(rid), lambda: share._lookup(token, count=True)):
                with self.subTest(errno=code, operation=op):
                    with patch.object(store.os, "replace", side_effect=OSError(code, "injected")):
                        with self.assertRaisesRegex(RuntimeError, "хранилища"):
                            op()
                    self.assertEqual(share._file().read_bytes(), raw)
                    self.assertEqual(list(Path(self.tmp.name).glob("*.tmp")), [])

    def test_raised_write_and_lock_errors(self):
        with patch.object(store, "save", side_effect=OSError(errno.EIO, "injected")):
            with self.assertRaisesRegex(RuntimeError, "хранилища"):
                self.create()
        with patch.object(share.fcntl, "flock", side_effect=OSError(errno.EIO, "injected")):
            with self.assertRaisesRegex(RuntimeError, "хранилища"):
                self.create()

    def test_missing_file_initializes_first_link(self):
        self.assertFalse(share._file().exists())
        token, rid, _ = self.create()
        self.assertIsNotNone(share._lookup(token))
        self.assertTrue(share.revoke(rid))

    def test_corrupt_or_wrong_type_state_is_never_overwritten(self):
        token, rid, _ = self.create()
        good = share._file().read_bytes()
        for raw in (b"{broken", b"\xff", b"[]", b"null", b"42"):
            for op in (self.create, lambda: share.revoke(rid), lambda: share._lookup(token),
                       lambda: share._lookup(token, count=True)):
                with self.subTest(raw=raw, operation=op):
                    share._file().write_bytes(raw)
                    with patch.object(store, "save", wraps=store.save) as save:
                        with self.assertRaises(share.PersistenceError):
                            op()
                        save.assert_not_called()
                    self.assertEqual(share._file().read_bytes(), raw)
        share._file().write_bytes(good)
        self.assertIsNotNone(share._lookup(token, count=True))
        self.assertTrue(share.revoke(rid))
        self.assertIsNotNone(share._lookup(self.create()[0]))

    def test_unreadable_state_is_never_overwritten(self):
        token, rid, _ = self.create()
        raw = share._file().read_bytes()
        for code in (errno.EIO, errno.EACCES):
            for op in (self.create, lambda: share.revoke(rid), lambda: share._lookup(token),
                       lambda: share._lookup(token, count=True)):
                with self.subTest(errno=code, operation=op):
                    with patch.object(Path, "read_text", side_effect=OSError(code, "injected")), \
                            patch.object(store, "save", wraps=store.save) as save:
                        with self.assertRaises(share.PersistenceError):
                            op()
                        save.assert_not_called()
                    self.assertEqual(share._file().read_bytes(), raw)
        self.assertIsNotNone(share._lookup(token, count=True))
        self.assertTrue(share.revoke(rid))

    def test_ttl(self):
        token, _, exp = self.create()
        with patch.object(share.time, "time", return_value=exp):
            self.assertIsNone(share._lookup(token, count=True))

    def test_two_processes_enforce_one_shared_open_limit(self):
        token, _, _ = self.create()
        ctx = multiprocessing.get_context("spawn")
        start, results = ctx.Event(), ctx.Queue()
        workers = [ctx.Process(target=consume, args=(self.tmp.name, token, start, results)) for _ in range(2)]
        try:
            for worker in workers:
                worker.start()
            start.set()
            counts = [results.get(timeout=30) for _ in workers]
            for worker in workers:
                worker.join(30)
                self.assertEqual(worker.exitcode, 0)
            self.assertEqual(sum(counts), 7)
            self.assertEqual(share._lookup(token)["opens"], 7)
        finally:
            for worker in workers:
                if worker.is_alive():
                    worker.terminate()
                worker.join()
            results.close()


class HandlerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        state = patch.object(store, "STATE_DIR", Path(self.tmp.name))
        state.start()
        self.addCleanup(state.stop)
        share._fails.clear()
        app = web.Application()
        share.setup(app)
        panel.setup(app, lambda request: {"web": True, "first_name": "test", "owner": True})
        self.http = TestClient(TestServer(app))
        await self.http.start_server()
        self.addAsyncCleanup(self.http.close)
        self.call = patch.object(api, "call", AsyncMock(return_value=api.Result(
            True, data=[{"name": "alice", "pub": "TEST-PUBLIC"}])))
        self.call.start()
        self.addCleanup(self.call.stop)

    async def test_http_create_and_revoke_report_503(self):
        token, rid, _ = share.create("alice", "TEST-PUBLIC", "test")
        for path, body in (("/api/client/share", {"name": "alice"}),
                           ("/api/client/share/revoke", {"id": rid})):
            with self.subTest(path=path), patch.object(store, "save", return_value=False):
                response = await self.http.post(path, json=body)
                data = await response.json()
                self.assertEqual(response.status, 503)
                self.assertIn("хранилищ", data["error"])
                self.assertFalse(data.get("ok"))
                self.assertNotIn("url", data)
        self.assertIsNotNone(share._lookup(token))

    async def test_http_never_fetches_or_returns_config_without_saved_count(self):
        token, _, _ = share.create("alice", "TEST-PUBLIC", "test")
        for kind in ("data", "file"):
            with self.subTest(kind=kind), patch.object(store, "save", return_value=False), \
                    patch.object(share, "_client", AsyncMock()) as fetch:
                response = await self.http.post(f"/s/{token}/{kind}")
                body = await response.json()
                self.assertEqual(response.status, 503)
                self.assertIn("хранилищ", body["error"])
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                self.assertNotIn("text", body)
                self.assertNotIn("qr", body)
                fetch.assert_not_awaited()
        self.assertFalse(share._fails)

    async def test_http_read_failures_are_503_without_config_or_writes(self):
        token, rid, _ = share.create("alice", "TEST-PUBLIC", "test")
        good = share._file().read_bytes()
        real_read = Path.read_text
        for raw, error in ((b"{broken", None), (b"[]", None), (good, OSError(errno.EIO, "injected"))):
            share._file().write_bytes(raw)
            for path, body in (("/api/client/share", {"name": "alice"}),
                               ("/api/client/share/revoke", {"id": rid}),
                               (f"/s/{token}", None), (f"/s/{token}/data", {}), (f"/s/{token}/file", {})):
                with self.subTest(path=path, raw=raw, error=error):
                    with patch.object(Path, "read_text", side_effect=error or real_read, autospec=True), \
                            patch.object(store, "save", wraps=store.save) as save, \
                            patch.object(share, "_client", AsyncMock()) as fetch:
                        response = (await self.http.get(path) if body is None
                                    else await self.http.post(path, json=body))
                        self.assertEqual(response.status, 503)
                        text = await response.text()
                        self.assertIn("хранилищ", (await response.json())["error"]
                                      if response.content_type == "application/json" else text)
                        self.assertNotIn('"text":', text)
                        self.assertNotIn('"qr":', text)
                        fetch.assert_not_awaited()
                        save.assert_not_called()
                    self.assertEqual(share._file().read_bytes(), raw)
        share._file().write_bytes(good)
        self.assertIsNotNone(share._lookup(token))
        self.assertFalse(share._fails)

    async def test_telegram_read_error_is_not_reported_as_missing_link(self):
        token, rid, _ = share.create("alice", "TEST-PUBLIC", "test")
        good = share._file().read_bytes()
        real_read = Path.read_text
        for raw, error in ((b"{broken", None), (good, OSError(errno.EACCES, "injected"))):
            share._file().write_bytes(raw)
            cb = Mock(answer=AsyncMock())
            with patch.object(Path, "read_text", side_effect=error or real_read, autospec=True), \
                    patch.object(clients, "card", AsyncMock()) as card:
                await clients._share_revoke(cb, None, f"alice|{rid}")
                text = cb.answer.call_args.args[0]
                self.assertIn("хранилищ", text)
                self.assertNotIn("Ссылка уже не действует", text)
                self.assertNotIn("Ссылка отозвана", text)
                card.assert_not_awaited()
            self.assertEqual(share._file().read_bytes(), raw)
        share._file().write_bytes(good)
        self.assertIsNotNone(share._lookup(token))

    async def test_http_success_and_recovery_after_failed_count(self):
        token, _, _ = share.create("alice", "TEST-PUBLIC", "test")
        with patch.object(store, "save", return_value=False):
            response = await self.http.post(f"/s/{token}/data")
            self.assertEqual(response.status, 503)
        with patch.object(share, "_client", AsyncMock(return_value=("alice", "test config"))):
            response = await self.http.post(f"/s/{token}/data")
            self.assertEqual(response.status, 200)
            self.assertEqual((await response.json())["text"], "test config")
            response = await self.http.post(f"/s/{token}/file")
            self.assertEqual(response.status, 200)
            self.assertEqual(await response.text(), "test config")
        self.assertEqual(share._lookup(token)["opens"], 2)

    async def test_http_lock_failure_is_unavailable(self):
        token, _, _ = share.create("alice", "TEST-PUBLIC", "test")
        with patch.object(share.fcntl, "flock", side_effect=OSError(errno.EIO, "injected")):
            response = await self.http.get(f"/s/{token}")
            self.assertEqual(response.status, 503)
            self.assertIn("хранилища", await response.text())
        self.assertFalse(share._fails)

    async def test_telegram_no_false_success_and_revoke_button_is_preserved(self):
        token, rid, _ = share.create("alice", "TEST-PUBLIC", "test")
        cb = Mock(from_user=Mock(id=111), answer=AsyncMock())
        with patch.object(store, "save", return_value=False), \
                patch.object(clients, "card", AsyncMock()) as card:
            await clients._share_revoke(cb, None, f"alice|{rid}")
            text = cb.answer.call_args.args[0]
            self.assertIn("хранилищ", text)
            self.assertNotIn("Ссылка отозвана", text)
            self.assertNotIn("Ссылка уже не действует", text)
            card.assert_not_awaited()
        self.assertIsNotNone(share._lookup(token))
        with patch.object(store, "save", return_value=False), \
                patch.object(clients, "client", AsyncMock(return_value={"pub": "TEST-PUBLIC"})), \
                patch.object(clients, "share_base", AsyncMock(return_value="https://example.test")), \
                patch.object(clients.ui, "render", AsyncMock()) as render:
            await clients._share(cb, None, "alice")
            self.assertIn("хранилищ", cb.answer.call_args.args[0])
            render.assert_not_awaited()


if __name__ == "__main__":
    logging.disable(logging.CRITICAL)
    unittest.main(argv=sys.argv[:1])
