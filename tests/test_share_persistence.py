"""Share storage failures, HTTP/Telegram responses and cross-process flock.

Uses temporary files and mocked API calls only; no VPN or system commands.
"""
import errno
import json
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
from awgbot import api, instlink, panel, share, store  # noqa: E402
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

    def test_ttl(self):
        token, _, exp = self.create()
        with patch.object(share.time, "time", return_value=exp):
            self.assertIsNone(share._lookup(token, count=True))

    def test_corrupt_records_do_not_break_valid_share(self):
        token, _, _ = self.create()
        key = share._digest(token)
        data = json.loads(share._file().read_text(encoding="utf-8"))
        for i, exp in enumerate(("broken", "inf", "NaN", [], {})):
            data[f"bad-{i}"] = {"name": "alice", "pub": "TEST-PUBLIC", "exp": exp}
        data[key]["opens"] = "broken"
        share._file().write_text(json.dumps(data), encoding="utf-8")

        rec = share._lookup(token, count=True)
        self.assertIsNotNone(rec)
        self.assertEqual(rec["opens"], 1)
        self.assertEqual(set(json.loads(share._file().read_text(encoding="utf-8"))), {key})

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


class InstallLinkTests(unittest.IsolatedAsyncioTestCase):
    """Одноразовая ссылка установки WG + обфускатора для AWG Manager (instlink.py)."""

    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = Path(self.tmp.name)
        state = patch.object(store, "STATE_DIR", d / "state")
        state.start()
        self.addCleanup(state.stop)
        share._fails.clear()
        files = []
        for name, body in (("install-linux.sh", "#!/bin/bash\nmain() { :; }\nmain \"$@\"\n"),
                           ("phobos.conf", "[Interface]\nPrivateKey = K\n\n[instance]\nkey = X\n"),
                           ("README.txt", "readme\n"), ("wg.conf", "[Interface]\n")):
            (d / name).write_text(body)
            files.append({"name": name, "path": str(d / name)})
        self.pub = "CPUB="
        self.calls = 0

        async def call(*args, **kw):
            self.calls += 1
            return api.Result(True, data={"name": args[2], "pub": self.pub, "files": files})
        p = patch.object(api, "call", call)
        p.start()
        self.addCleanup(p.stop)
        app = web.Application()
        instlink.setup(app)
        self.http = TestClient(TestServer(app))
        await self.http.start_server()
        self.addAsyncCleanup(self.http.close)

    def url(self, token):
        return f"/api/install/{token}"

    async def test_link_page_only_no_script_not_spent(self):
        token, rid, exp = instlink.create("kn1", "CPUB=", "test")
        self.assertRegex(token, r"^[A-Za-z0-9_-]{32}$")
        raw = (store.STATE_DIR / "wgobf-install.json").read_text()
        self.assertNotIn(token, raw)
        self.assertEqual((store.STATE_DIR / "wgobf-install.json").stat().st_mode & 0o777, 0o600)
        r = await self.http.get(self.url(token), headers={"User-Agent": "Mozilla/5.0"})
        page = await r.text()
        self.assertEqual(r.status, 200)
        self.assertIn("Установка клиента kn1", page)
        self.assertIn("AWG Manager", page)
        self.assertNotIn("sudo bash", page)
        self.assertNotIn("PrivateKey", page)
        # curl и wget скрипта не получают (ссылка — только для AWG Manager) и её не тратят
        for ua in ("curl/8.5.0", "Wget/1.21"):
            r = await self.http.get(self.url(token), headers={"User-Agent": ua})
            self.assertEqual(r.status, 404)
            body = await r.text()
            self.assertIn("AWG Manager", body)
            self.assertNotIn("#!/bin/bash", body)
            self.assertEqual(r.headers.get("Cache-Control"), "no-store")
        self.assertEqual(self.calls, 0)                       # без awg2
        self.assertIsNotNone(instlink._peek(token))
        self.assertTrue(instlink.revoke(rid))

    async def test_package_for_awg_manager_preview_not_spent(self):
        import io
        import tarfile
        token, _, _ = instlink.create("kn1", "CPUB=", "test")
        r = await self.http.get(self.url(token) + "/package.tar.gz",
                                headers={"User-Agent": "TelegramBot (like TwitterBot)"})
        self.assertEqual(r.status, 404)
        r = await self.http.get(self.url(token) + "/package.tar.gz", headers={"User-Agent": "Go-http-client/1.1"})
        self.assertEqual(r.status, 200)
        with tarfile.open(fileobj=io.BytesIO(await r.read()), mode="r:gz") as tf:
            names = tf.getnames()
            conf = tf.extractfile("kn1.conf").read().decode()
        self.assertEqual(names, ["kn1.conf", "README.txt"])     # установщика Linux в архиве нет
        self.assertIn("[instance]", conf)
        r = await self.http.get(self.url(token), headers={"User-Agent": "Wget/1.21"})
        self.assertEqual(r.status, 404)

    async def test_other_client_key_head_unknown_and_expired(self):
        token, _, _ = instlink.create("kn1", "OLD-PUB=", "test")
        pkg = self.url(token) + "/package.tar.gz"
        r = await self.http.get(pkg, headers={"User-Agent": "Go-http-client/1.1"})
        self.assertEqual(r.status, 404)                       # клиент пересоздан — ключ другой
        self.assertIsNotNone(instlink._peek(token))           # и ссылка не потрачена
        r = await self.http.head(pkg, headers={"User-Agent": "Go-http-client/1.1"})
        self.assertEqual(r.status, 405)
        r = await self.http.get(self.url("A" * 32) + "/package.tar.gz", headers={"User-Agent": "Go-http-client/1.1"})
        self.assertEqual(r.status, 404)
        self.assertEqual(self.calls, 1)                       # неверная ссылка — без awg2
        token2, _, _ = instlink.create("kn1", "CPUB=", "test", now=1000.0)
        self.assertIsNone(instlink._peek(token2))             # сутки прошли
        r = await self.http.get(self.url(token2) + "/package.tar.gz", headers={"User-Agent": "Go-http-client/1.1"})
        self.assertEqual(r.status, 404)

    async def test_panel_route_url_and_revoke(self):
        async def data(*args, **kw):
            return [{"name": "kn1", "pub": "CPUB="}] if args[:2] == ("wgobf", "clients") else None
        app = web.Application()
        panel.setup(app, lambda request: {"web": True, "first_name": "test", "owner": True})
        http = TestClient(TestServer(app))
        await http.start_server()
        try:
            with patch.object(api, "data", data):
                r = await http.post("/api/wgobf/install-link", json={"name": "kn1"})
                d = await r.json()
                r2 = await http.post("/api/wgobf/install-link", json={"name": "nobody"})
                rv = await (await http.post("/api/wgobf/install-link/revoke", json={"id": d["id"]})).json()
                rv2 = await (await http.post("/api/wgobf/install-link/revoke", json={"id": d["id"]})).json()
        finally:
            await http.close()
        self.assertEqual(r.status, 200)
        self.assertRegex(d["url"], r"^https://127\.0\.0\.1:\d+/api/install/[A-Za-z0-9_-]{32}$")
        self.assertNotIn("insecure", d)
        self.assertEqual(d["ttl"], 86400)
        self.assertEqual(r2.status, 404)
        # Отозвать уже недействующую — не ошибка, а «отзывать нечего»
        self.assertEqual(rv, {"ok": True, "revoked": True})
        self.assertEqual(rv2, {"ok": True, "revoked": False})

    async def test_obfuscator_in_name_and_url(self):
        token, _, _ = instlink.create("myobfuscator", "CPUB=", "test")
        r = await self.http.get(self.url(token) + "/package.tar.gz", headers={"User-Agent": "Go-http-client/1.1"})
        import io
        import tarfile
        with tarfile.open(fileobj=io.BytesIO(await r.read()), mode="r:gz") as tf:
            self.assertEqual(tf.getnames()[0], "client.conf")  # AWG Manager пропускает *obfuscator*
        self.assertEqual(instlink.url_for("https://vpn.example:8443/some/path/", "T"),
                         "https://vpn.example:8443/api/install/T")
        with self.assertRaises(ValueError):
            instlink.create("bad name", "CPUB=", "test")


if __name__ == "__main__":
    logging.disable(logging.CRITICAL)
    unittest.main(argv=sys.argv[:1])
