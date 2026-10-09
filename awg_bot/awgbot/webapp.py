"""webapp.py — HTTPS-сервер Mini App: страница и JSON API за подписью Telegram.

Mini App открывается кнопкой в боте. Telegram передаёт странице initData —
данные пользователя, подписанные токеном бота. Каждый запрос к API несёт их
в заголовке «Authorization: tma <initData>»; сервер проверяет подпись и
пускает только владельцев и приглашённых админов — как сам бот. Без
Telegram (просто браузером) API не ответит ничего, кроме отказа.

Сертификат выпускает awg2 (Let's Encrypt на IP или домен) в /etc/awg2/cert;
после продления сервер подхватывает новые файлы сам, без перезапуска.
Порт — WEBAPP_PORT в конфиге бота (off — выключено).

Пока сервер работает, кнопка «Меню» слева от поля ввода у владельцев и
приглашённых админов открывает панель; у остальных она прежняя (/start).
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import ssl
import time
from pathlib import Path
from urllib.parse import parse_qsl

from aiogram import Bot
from aiogram.exceptions import TelegramAPIError
from aiogram.types import MenuButtonDefault, MenuButtonWebApp, WebAppInfo
from aiohttp import web

from . import __version__, access, api, panel
from .config import CONF_PATH, _read_file

log = logging.getLogger("awgbot.webapp")

CERT_FULL = Path(os.environ.get("AWG_CERT_FULL", "/etc/awg2/cert/fullchain.pem"))
CERT_KEY = Path(os.environ.get("AWG_CERT_KEY", "/etc/awg2/cert/key.pem"))
STATIC = Path(__file__).with_name("webapp")
DEFAULT_PORT = 8443
MAX_AGE = 24 * 3600         # initData старше суток не принимаем
WATCH_EVERY = 60            # проверка обновлённого сертификата
MENU_TEXT = "Панель"        # кнопка «Меню» у админов


# ── Подпись Telegram ──────────────────────────────────────
def check_init_data(init_data: str, token: str, now: float | None = None) -> dict | None:
    """Пользователь из initData или None: подпись не сошлась, данные
    устарели, пользователя нет. Алгоритм — core.telegram.org/bots/webapps
    (секрет = HMAC-SHA256("WebAppData", токен))."""
    try:
        pairs = dict(parse_qsl(init_data or "", keep_blank_values=True, strict_parsing=True))
    except ValueError:
        return None
    got = pairs.pop("hash", "")
    if not got:
        return None
    secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()

    def sign(fields: dict[str, str]) -> str:
        check = "\n".join(f"{k}={v}" for k, v in sorted(fields.items()))
        return hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()

    # Поле signature (подпись для сторонних сервисов) клиенты Telegram то
    # включают в проверку hash, то нет — принимаем оба варианта
    no_sig = {k: v for k, v in pairs.items() if k != "signature"}
    if not (hmac.compare_digest(sign(pairs), got) or hmac.compare_digest(sign(no_sig), got)):
        return None
    try:
        auth = int(pairs.get("auth_date") or 0)
        user = json.loads(pairs.get("user") or "{}")
    except (ValueError, TypeError):
        return None
    if (now or time.time()) - auth > MAX_AGE or not isinstance(user, dict) or not user.get("id"):
        return None
    return user


def configured_port() -> int | None:
    """Порт из конфига бота; None — Mini App выключена."""
    raw = (_read_file(CONF_PATH).get("WEBAPP_PORT") or "").strip().strip("\"'")
    if raw == "off":
        return None
    return int(raw) if raw.isdigit() and 0 < int(raw) < 65536 else DEFAULT_PORT


# ── Сервер ────────────────────────────────────────────────
class MiniApp:
    def __init__(self) -> None:
        self.runner: web.AppRunner | None = None
        self.ctx: ssl.SSLContext | None = None
        self.url = ""
        self.error = ""
        self._mtime = 0.0
        self._watch: asyncio.Task | None = None
        self.bot: Bot | None = None
        self.menu_error = ""

    @property
    def running(self) -> bool:
        return self.runner is not None

    async def start(self, bot: Bot) -> None:
        """Поднять сервер, если есть сертификат и порт; иначе — причина в
        error. Кнопка «Меню» админов — вслед за сервером."""
        self.bot = bot
        await self._serve(bot)
        # Всегда: если сервер не поднялся (нет сертификата, порт занят), у
        # админов иначе остаётся кнопка «Меню» на мёртвый адрес с прошлого раза.
        await self.menu_all(bot)

    async def _serve(self, bot: Bot) -> None:
        await self.stop()
        port = configured_port()
        if port is None:
            self.error = "выключена (WEBAPP_PORT=off)"
            return
        cert = await api.data("cert", "status", default={}) or {}
        host = cert.get("name") or ""
        if not (CERT_FULL.is_file() and CERT_KEY.is_file() and host):
            self.error = "нет сертификата"
            return
        try:
            self.ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
            self.ctx.load_cert_chain(CERT_FULL, CERT_KEY)
            self._mtime = CERT_FULL.stat().st_mtime
            app = web.Application(client_max_size=64 * 1024)
            app["bot"] = bot
            app.on_response_prepare.append(self._headers)
            app.router.add_get("/", self._index)
            app.router.add_get("/app.js", self._static)
            app.router.add_get("/icons.js", self._static)
            app.router.add_post("/api/me", self._me)
            app.router.add_post("/api/status", self._status)
            panel.setup(app, self._user)
            self.runner = web.AppRunner(app, access_log=None)
            await self.runner.setup()
            await web.TCPSite(self.runner, "0.0.0.0", port, ssl_context=self.ctx).start()
        except (OSError, ssl.SSLError) as e:
            await self.stop()
            # ssl.SSLError — подкласс OSError, поэтому проверяем его первым
            self.error = f"сертификат: {e}" if isinstance(e, ssl.SSLError) else f"порт {port}: {e.strerror or e}"
            log.warning("Mini App не запущена: %s", self.error)
            return
        self.url = f"https://{host}" + ("" if port == 443 else f":{port}") + "/"
        self.error = ""
        self._watch = asyncio.create_task(self._watch_cert(), name="webapp-cert")
        log.info("Mini App: %s", self.url)

    async def shutdown(self) -> None:
        """Выключить совсем: сервер и кнопку «Меню» у админов."""
        await self.stop()
        if self.bot:
            await self.menu_all(self.bot)

    async def menu_all(self, bot: Bot) -> None:
        for uid in access.all_ids():
            await self.menu_for(bot, uid)

    async def menu_for(self, bot: Bot, chat_id: int) -> None:
        """Кнопка «Меню» в чате админа: панель, пока сервер работает, иначе
        обычный список команд. Отказ Telegram — в menu_error, не ошибка."""
        button = (MenuButtonWebApp(text=MENU_TEXT, web_app=WebAppInfo(url=self.url)) if self.running
                  else MenuButtonDefault())
        try:
            await bot.set_chat_menu_button(chat_id=chat_id, menu_button=button)
            self.menu_error = ""
        except TelegramAPIError as e:
            self.menu_error = str(e)
            log.warning("Кнопка «Меню» для %s не выставлена: %s", chat_id, e)

    async def stop(self) -> None:
        if self._watch:
            self._watch.cancel()
            self._watch = None
        if self.runner:
            await self.runner.cleanup()
            self.runner = None
        self.url = ""

    async def _watch_cert(self) -> None:
        """acme.sh продлил сертификат — новые подключения получат новый."""
        while True:
            await asyncio.sleep(WATCH_EVERY)
            try:
                mtime = CERT_FULL.stat().st_mtime
                if mtime != self._mtime and self.ctx:
                    self.ctx.load_cert_chain(CERT_FULL, CERT_KEY)
                    self._mtime = mtime
                    log.info("Mini App: сертификат обновлён")
            except (OSError, ssl.SSLError) as e:
                log.warning("Mini App: сертификат не перечитан: %s", e)

    # ── Обработчики ──
    @staticmethod
    def _user(request: web.Request) -> dict:
        """Пользователь запроса; иначе — 401 (нет подписи) или 403 (чужой)."""
        auth = request.headers.get("Authorization", "")
        init_data = auth[4:] if auth.startswith("tma ") else ""
        user = check_init_data(init_data, request.app["bot"].token)
        if user is None:
            raise web.HTTPUnauthorized(text=json.dumps({"error": "Открой панель из бота"}),
                                       content_type="application/json")
        if not access.authorized(int(user["id"])):
            log.warning("Mini App: отказ в доступе %s", user.get("id"))
            raise web.HTTPForbidden(text=json.dumps({"error": "Нет доступа"}), content_type="application/json")
        # «owner»/«web» ставит только веб-панель — из данных Telegram их не берём
        return {k: v for k, v in user.items() if k not in ("owner", "web")}

    @staticmethod
    async def _headers(request: web.Request, resp: web.StreamResponse) -> None:
        """Как у веб-панели, но рамку не запрещаем: Telegram Web открывает Mini App
        во фрейме; скрипт Telegram — с telegram.org."""
        resp.headers["Server"] = "awg"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["Referrer-Policy"] = "no-referrer"
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' https://telegram.org; connect-src 'self'; object-src 'none'; base-uri 'none'; "
            "form-action 'self'")

    @staticmethod
    async def _index(request: web.Request) -> web.StreamResponse:
        resp = web.FileResponse(STATIC / "index.html")
        resp.headers["Cache-Control"] = "no-store"
        return resp

    @staticmethod
    async def _static(request: web.Request) -> web.StreamResponse:
        resp = web.FileResponse(STATIC / request.path.lstrip("/"))
        resp.headers["Cache-Control"] = "no-store"
        return resp

    async def _me(self, request: web.Request) -> web.Response:
        user = self._user(request)
        return web.json_response({"id": user["id"], "name": user.get("first_name") or "",
                                  "owner": access.is_owner(int(user["id"])), "bot": __version__, "started": STARTED})

    async def _status(self, request: web.Request) -> web.Response:
        self._user(request)
        r = await api.call("status")
        if not r.ok:
            return web.json_response({"error": r.message}, status=502)
        return web.json_response(r.data)


SERVER = MiniApp()
STARTED = int(time.time())          # панель по нему видит, что бот перезапустился
