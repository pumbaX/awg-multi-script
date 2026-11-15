"""web.py — веб-панель AWG Toolza: та же панель, что Mini App, но в браузере
по логину и паролю, без Telegram (служба awg-web: python -m awgbot.web).

Защита:
- только HTTPS: сертификат Тулзы (/etc/awg2/cert, Let's Encrypt на IP или
  домен, готовый) или самоподписанный — свой, если первого нет;
- панель живёт по секретному пути (https://IP:порт/<путь>/), всё остальное —
  404: сканеры не видят даже страницу входа;
- пароль хранится только хешем scrypt (/etc/awg-web.conf, права 600);
- перебор: 5 неверных паролей с адреса — блокировка на 15 минут (каждая
  следующая вдвое дольше, до суток); много неверных паролей со всех адресов
  сразу — ответы замедляются для всех;
- сессия — случайный токен в cookie HttpOnly + Secure + SameSite=Strict, на
  сервере хранится только его хеш; 12 часов без действий или 7 дней — вход
  заново; смена пароля завершает остальные сессии;
- запросы с чужих сайтов (CSRF) отклоняются по Origin; заголовки CSP,
  X-Frame-Options, Referrer-Policy;
- входы и блокировки — в журнал /var/log/awg-web.log, а если настроен
  Telegram-бот — сообщением владельцам;
- доступ можно сузить (awg2 → Веб-панель → Доступ): только с указанных
  адресов или только через свой VPN. Порт закрывает правило файрвола awg2, а
  панель ещё и сама проверяет адрес по тому же списку — чужим 404, даже если
  правило кто-то снял; раз в 5 минут она возвращает правило на место.

Всё остальное — то же API панели (panel.py), что у Mini App: awg2 api.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import html
import ipaddress
import json
import logging
import os
import random
import secrets
import ssl
import subprocess
import time
from collections import deque
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import web

from . import __version__, api, assets, panel, share

log = logging.getLogger("awgbot.web")

CONF = Path(os.environ.get("AWG_WEB_CONF", "/etc/awg-web.conf"))
LOG_FILE = Path(os.environ.get("AWG_WEB_LOG", "/var/log/awg-web.log"))
SELF_DIR = Path(os.environ.get("AWG_WEB_DIR", "/etc/awg-web"))
CERT_FULL = Path(os.environ.get("AWG_CERT_FULL", "/etc/awg2/cert/fullchain.pem"))
CERT_KEY = Path(os.environ.get("AWG_CERT_KEY", "/etc/awg2/cert/key.pem"))
STATIC = Path(__file__).with_name("webapp")
NETS_FILE = Path(os.environ.get("AWG_WEB_NETS", "/etc/awg-web/access.nets"))
FW_SCRIPT = os.environ.get("AWG_WEB_FW", "")
FW_EVERY = 300                  # проверка правила доступа в файрволе
COOKIE = "awg_web"
IDLE = 12 * 3600                # без действий — вход заново
LIFETIME = 7 * 24 * 3600        # и не дольше недели
SESSIONS_MAX = 32
FAILS_MAX = 5                   # неверных паролей с адреса до блокировки
SCRYPT_PARALLEL = 4             # одновременных проверок пароля
LOCK_FIRST = 15 * 60
LOCK_MAX = 24 * 3600
STORM_WINDOW, STORM_FAILS = 600, 30     # неверных паролей со всех адресов за 10 минут
PASS_MIN = 10
WATCH_EVERY = 60
STARTED = int(time.time())


# ── Конфиг ────────────────────────────────────────────────
def read_conf() -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = CONF.read_text(encoding="utf-8")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("\"'")
    return out


def write_conf(updates: dict[str, str]) -> None:
    """Поменять ключи конфига на месте; файл — только root (600), атомарно."""
    lines, seen = [], set()
    try:
        old = CONF.read_text(encoding="utf-8").splitlines()
    except OSError:
        old = []
    for line in old:
        k = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else ""
        if k in updates:
            lines.append(f"{k}={updates[k]}")
            seen.add(k)
        else:
            lines.append(line)
    lines += [f"{k}={v}" for k, v in updates.items() if k not in seen]
    tmp = CONF.with_name(CONF.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, CONF)


def base_path(conf: dict[str, str]) -> str:
    p = "".join(ch for ch in conf.get("WEB_PATH", "") if ch.isalnum() or ch in "-_")
    return f"/{p}/" if p else "/"


# ── Пароль: scrypt ────────────────────────────────────────
SCRYPT_N, SCRYPT_R, SCRYPT_P = 2 ** 14, 8, 1


def hash_password(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P, dklen=32)
    b64 = lambda b: base64.b64encode(b).decode()  # noqa: E731
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${b64(salt)}${b64(dk)}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, n, r, p, salt, want = stored.split("$")
        if algo != "scrypt":
            return False
        n_, r_, p_ = int(n), int(r), int(p)
        if not (2 ** 10 <= n_ <= 2 ** 20 and 1 <= r_ <= 16 and 1 <= p_ <= 4):
            return False
        dk = hashlib.scrypt(password.encode(), salt=base64.b64decode(salt), n=n_, r=r_, p=p_,
                            dklen=len(base64.b64decode(want)), maxmem=256 * 1024 * 1024)
        return hmac.compare_digest(dk, base64.b64decode(want))
    except (ValueError, TypeError):
        return False


_DUMMY = hash_password(secrets.token_hex(8))      # для неверного логина: время ответа то же


# ── Перебор ───────────────────────────────────────────────
class Guard:
    def __init__(self) -> None:
        self.ips: dict[str, dict[str, float]] = {}
        self.storm: deque[float] = deque()

    def locked(self, ip: str, now: float | None = None) -> int:
        """Сколько секунд адрес ещё заблокирован (0 — нет)."""
        e = self.ips.get(ip)
        now = now or time.time()
        return max(0, int(e["until"] - now)) if e else 0

    def storming(self, now: float | None = None) -> bool:
        now = now or time.time()
        while self.storm and now - self.storm[0] > STORM_WINDOW:
            self.storm.popleft()
        return len(self.storm) >= STORM_FAILS

    def fail(self, ip: str, now: float | None = None) -> int:
        """Неверный пароль; вернуть срок блокировки, если она началась."""
        now = now or time.time()
        self.storm.append(now)
        if len(self.ips) > 5000:            # перебор с тысяч адресов — память не растёт без конца
            for k in [k for k, v in self.ips.items() if v["until"] < now and v["fails"] < 2]:
                self.ips.pop(k, None)
        e = self.ips.setdefault(ip, {"fails": 0, "until": 0, "level": 0})
        e["fails"] += 1
        if e["fails"] >= (3 if self.storming(now) else FAILS_MAX):
            lock = min(LOCK_FIRST * 2 ** int(e["level"]), LOCK_MAX)
            e.update(fails=0, until=now + lock, level=e["level"] + 1)
            return int(lock)
        return 0

    def ok(self, ip: str) -> None:
        self.ips.pop(ip, None)
        if self.storm:                      # попытка засчитана заранее — верный вход не перебор
            self.storm.pop()


# ── Сессии ────────────────────────────────────────────────
class Sessions:
    def __init__(self) -> None:
        self.items: dict[str, dict] = {}

    @staticmethod
    def _key(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def new(self, user: str, ip: str, ua: str) -> str:
        token = secrets.token_urlsafe(32)
        now = time.time()
        if len(self.items) >= SESSIONS_MAX:
            oldest = min(self.items, key=lambda k: self.items[k]["seen"])
            self.items.pop(oldest, None)
        self.items[self._key(token)] = {"user": user, "created": now, "seen": now, "ip": ip, "ua": ua[:160]}
        return token

    def get(self, token: str, now: float | None = None, touch: bool = True) -> dict | None:
        """touch=False — фоновый опрос панели: проверяет, но не продлевает простой."""
        if not token or len(token) > 100:
            return None
        key = self._key(token)
        s = self.items.get(key)
        now = now or time.time()
        if s and (now - s["seen"] > IDLE or now - s["created"] > LIFETIME):
            self.items.pop(key, None)
            return None
        if s and touch:
            s["seen"] = now
        return s

    def drop(self, token: str) -> None:
        self.items.pop(self._key(token or ""), None)

    def drop_others(self, token: str) -> int:
        keep = self._key(token or "")
        gone = [k for k in self.items if k != keep]
        for k in gone:
            self.items.pop(k, None)
        return len(gone)


# ── Доступ по адресам ─────────────────────────────────────
def client_ip(raw: str | None) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        a = ipaddress.ip_address((raw or "").split("%")[0])
    except ValueError:
        return None
    return a.ipv4_mapped if a.version == 6 and a.ipv4_mapped else a


def from_self(request: web.Request) -> bool:
    """С самого сервера по 127.0.0.1 / ::1 (SSH-туннель) — при любом доступе.
    С внешнего адреса сервера на него же — нет: так приходят пользователи прокси
    на этом сервере (3x-ui и т. п.), и «по адресам» и «только через VPN» они бы
    обходили. Пускать их — адрес сервера в списке «по адресам»."""
    a = client_ip(request.remote)
    return a is not None and a.is_loopback


class Access:
    """Кому можно открыть панель. Режим (WEB_ACCESS: all | ip | vpn) — из
    конфига, подсети — из файла, который пишет правило файрвола awg2 (тот же
    список: адреса из WEB_ALLOW и свой VPN). Режим ограничен, а файла нет —
    не пускаем никого, кроме самого сервера: вернуть «для всех» — из SSH
    (awg2 → Веб-панель → Доступ) или Telegram-бота."""

    def __init__(self) -> None:
        self.key: tuple = ()
        self.mode = "all"
        self.nets: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []

    def refresh(self) -> None:
        # Время, размер и inode: два изменения в один тик часов не сливаются
        try:
            st = CONF.stat()
            ck: tuple = (st.st_mtime_ns, st.st_size, st.st_ino)
        except OSError:
            ck = ()
        try:
            st = NETS_FILE.stat()
            nk: tuple = (st.st_mtime_ns, st.st_size, st.st_ino)
        except OSError:
            nk = ()
        if (ck, nk) == self.key:
            return
        mode = read_conf().get("WEB_ACCESS", "all")
        nets = []
        if mode in ("ip", "vpn") and nk:
            try:
                for line in NETS_FILE.read_text(encoding="utf-8").splitlines():
                    try:
                        nets.append(ipaddress.ip_network(line.strip(), strict=False))
                    except ValueError:
                        continue
            except OSError:
                pass
        self.key, self.mode, self.nets = (ck, nk), mode if mode in ("ip", "vpn") else "all", nets

    def allowed(self, raw: str | None) -> bool:
        self.refresh()
        if self.mode == "all":
            return True
        a = client_ip(raw)
        if a is None:
            return False
        return a.is_loopback or any(a.version == n.version and a in n for n in self.nets)


# ── Журнал и уведомления ──────────────────────────────────
def journal(event: str, ip: str, extra: str = "") -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {event} {ip} {extra}".rstrip()
    log.info(line)
    try:
        fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


class Notifier:
    """Сообщения владельцам в Telegram, если бот настроен. Без бота — молча."""

    def __init__(self) -> None:
        self.bot = None
        self.owners: list[int] = []
        try:
            from aiogram import Bot
            from aiogram.client.default import DefaultBotProperties

            from . import net
            from .config import load_config
            cfg = load_config()
            self.bot = Bot(token=cfg.token, session=net.build_session(cfg.proxy),
                           default=DefaultBotProperties(parse_mode="HTML", link_preview_is_disabled=True))
            self.owners = sorted(cfg.admins)
        except (Exception, SystemExit) as e:        # бота нет или конфиг неполный (load_config — SystemExit)
            self.bot = None
            log.info("Уведомления в Telegram выключены: %s", str(e).splitlines()[0] if str(e) else e)

    def send(self, text: str) -> None:
        if not self.bot or not self.owners:
            return

        async def go() -> None:
            for uid in self.owners:
                try:
                    await asyncio.wait_for(self.bot.send_message(uid, text), 15)
                except Exception as e:          # noqa: BLE001 — уведомление не главное
                    log.warning("Уведомление не ушло: %s", e)
        task = asyncio.get_running_loop().create_task(go())
        _bg.add(task)
        task.add_done_callback(_bg.discard)


_bg: set[asyncio.Task] = set()


# ── Сертификат ────────────────────────────────────────────
def cert_files() -> tuple[Path, Path, str]:
    """Сертификат Тулзы или самоподписанный (создаётся при первом запуске)."""
    if CERT_FULL.is_file() and CERT_KEY.is_file():
        return CERT_FULL, CERT_KEY, "toolza"
    crt, key = SELF_DIR / "self.crt", SELF_DIR / "self.key"
    if not (crt.is_file() and key.is_file()):
        SELF_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(SELF_DIR, 0o700)
        ip = public_ip()
        san = f"IP:{ip}" if ip else "DNS:localhost"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                        "-subj", "/CN=AWG Toolza", "-addext", f"subjectAltName={san}",
                        "-keyout", str(key), "-out", str(crt)], check=True, capture_output=True)
        os.chmod(key, 0o600)
    return crt, key, "self"


def public_ip() -> str:
    try:
        out = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"], capture_output=True, text=True,
                             timeout=5).stdout.split()
        ip = out[out.index("src") + 1]
        ipaddress.ip_address(ip)
        return ip
    except (ValueError, IndexError, OSError, subprocess.SubprocessError):
        return ""


# ── Сервер ────────────────────────────────────────────────
INDEX_TG = '<script src="https://telegram.org/js/telegram-web-app.js"></script>'


class WebPanel:
    def __init__(self) -> None:
        self.conf = read_conf()
        self.base = base_path(self.conf)
        self.guard = Guard()
        self.sessions = Sessions()
        # scrypt — 16 МБ и заметное время CPU на проверку: не больше SCRYPT_PARALLEL
        # разом, иначе поток неверных паролей съедает память и пул потоков
        self.scrypt_slots = asyncio.Semaphore(SCRYPT_PARALLEL)
        self.csrf_logged = 0.0
        self.deny_logged = 0.0
        self.access = Access()
        self.notify = Notifier()
        self.assets = assets.Assets(index_fix=lambda h: h.replace(INDEX_TG, '<script src="web.js"></script>'))
        self._prefetch: set[asyncio.Task] = set()
        self.ctx: ssl.SSLContext | None = None
        self.cert_kind = ""
        self._mtime = 0.0

    # ── пользователь запроса ──
    def user_of(self, request: web.Request) -> dict:
        s = self.sessions.get(request.cookies.get(COOKIE, ""), touch=request.headers.get("X-Awg-Bg") != "1")
        if not s:
            raise web.HTTPUnauthorized(text=json.dumps({"error": "Нужен вход", "login": True}),
                                       content_type="application/json")
        return {"id": 0, "first_name": s["user"], "owner": True, "web": True}

    # ── безопасность каждого ответа и запроса ──
    @web.middleware
    async def guard_mw(self, request: web.Request, handler):  # type: ignore[no-untyped-def]
        # Адрес не из разрешённых — как незнакомый путь: 404, страница входа не видна
        if not self.access.allowed(request.remote):
            now = time.monotonic()
            if now - self.deny_logged >= 10:
                self.deny_logged = now
                journal("DENY", request.remote or "?", "не из разрешённых адресов")
            raise web.HTTPNotFound()
        if request.method == "POST" and not same_origin(request):
            # Без входа и с любым Origin — поэтому не чаще раза в 10 с и коротко:
            # иначе поток таких запросов забивает журнал и диск
            now = time.monotonic()
            if now - self.csrf_logged >= 10:
                self.csrf_logged = now
                journal("CSRF", request.remote or "?", request.headers.get("Origin", "")[:80].encode(
                    "ascii", "backslashreplace").decode())
            raise web.HTTPForbidden(text='{"error": "чужой сайт"}', content_type="application/json")
        resp = await handler(request)
        return resp

    @staticmethod
    async def headers(request: web.Request, resp: web.StreamResponse) -> None:
        resp.headers["Server"] = "awg"
        if share.is_share_path(request.path):
            return                      # у ссылок на конфиг свои заголовки, строже
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["X-Frame-Options"] = "DENY"
        resp.headers["Referrer-Policy"] = "no-referrer"
        # Всё — без кэша, кроме шрифтов (свой Cache-Control у их ответа)
        resp.headers.setdefault("Cache-Control", "no-store")
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; "
            "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")

    # ── страницы ──
    async def index(self, request: web.Request) -> web.Response:
        # Вошедший открыл панель: сводку и клиентов awg2 начинает собирать уже
        # сейчас, пока браузер грузит скрипты, — экран получит их из кэша. Только
        # для живой сессии: чужим открытие страницы не стоит ни одного вызова awg2
        if self.sessions.get(request.cookies.get(COOKIE, ""), touch=False):
            for args in (("status",), ("clients", "list"), ("server", "info")):
                self._prefetch.add(t := asyncio.create_task(api.call(*args)))
                t.add_done_callback(self._prefetch.discard)
        return self.assets.response(request, "index.html")

    async def web_js(self, request: web.Request) -> web.Response:
        cfg = {"base": self.base, "version": __version__}
        return web.Response(text=f"window.AWG_WEB = {json.dumps(cfg)};\n", content_type="application/javascript")

    async def static(self, request: web.Request) -> web.Response:
        return self.assets.response(request, request.match_info["file"])

    async def font(self, request: web.Request) -> web.StreamResponse:
        """Шрифт оформления «Карточки» (IBM Plex, OFL): имя — только из списка
        в маршруте; файлы между версиями не меняются — браузер держит неделю."""
        f = STATIC / "fonts" / request.match_info["file"]
        if not f.is_file():
            raise web.HTTPNotFound()
        resp = web.FileResponse(f, headers={"Content-Type": "font/woff2"})
        resp.headers["Cache-Control"] = "public, max-age=604800"
        return resp

    # ── вход и выход ──
    async def login(self, request: web.Request) -> web.Response:
        ip = request.remote or "?"
        try:
            body = await request.json()
            user, password = str(body.get("user") or "")[:64], str(body.get("password") or "")[:256]
        except (ValueError, AttributeError):
            raise web.HTTPBadRequest(text='{"error": "нужен JSON"}', content_type="application/json") from None
        # Блокировка проверяется и попытка засчитывается подряд, без await между
        # ними (тело запроса уже прочитано): иначе запросы, посланные разом,
        # проходили locked() все до первого fail(), и лимит FAILS_MAX не работал.
        # Верный пароль счёт сбрасывает (guard.ok).
        wait = self.guard.locked(ip)
        if wait:
            return web.json_response({"error": f"Слишком много неверных паролей — вход закрыт ещё на "
                                      f"{max(1, wait // 60)} мин."}, status=429)
        lock = self.guard.fail(ip)
        if self.guard.storming():
            await asyncio.sleep(3)
        self.conf = read_conf()
        want_user, stored = self.conf.get("WEB_USER", ""), self.conf.get("WEB_PASS", "")
        user_ok = bool(want_user) and hmac.compare_digest(user.encode(), want_user.encode())
        async with self.scrypt_slots:
            pass_ok = await asyncio.to_thread(verify_password, password, stored if user_ok and stored else _DUMMY)
        if not (user_ok and pass_ok and stored):
            journal("FAIL", ip, f"user={user[:32]!r}")
            if lock:
                journal("LOCK", ip, f"{lock // 60} мин")
                self.notify.send(f"🚫 Веб-панель: неверные пароли с адреса <code>{html.escape(ip)}</code> — "
                                 f"вход для него закрыт на {lock // 60} мин.")
            await asyncio.sleep(0.4 + random.random() * 0.4)
            return web.json_response({"error": "Неверный логин или пароль"}, status=401)
        self.guard.ok(ip)
        token = self.sessions.new(user, ip, request.headers.get("User-Agent", ""))
        journal("LOGIN", ip, f"user={user}")
        self.notify.send(f"🔐 Вход в веб-панель: <b>{html.escape(user)}</b> с адреса <code>{html.escape(ip)}</code>")
        resp = web.json_response({"ok": True})
        resp.set_cookie(COOKIE, token, path=self.base, secure=True, httponly=True, samesite="Strict",
                        max_age=LIFETIME)
        return resp

    async def logout(self, request: web.Request) -> web.Response:
        self.sessions.drop(request.cookies.get(COOKIE, ""))
        resp = web.json_response({"ok": True})
        resp.del_cookie(COOKIE, path=self.base)
        return resp

    async def me(self, request: web.Request) -> web.Response:
        u = self.user_of(request)
        bot = Path(os.environ.get("AWG_BOT_UNIT", "/etc/systemd/system/awg-bot.service")).is_file()
        return web.json_response({"id": 0, "name": u["first_name"], "owner": True, "bot": __version__,
                                  "started": STARTED, "web": True, "tg_bot": bot})

    async def status(self, request: web.Request) -> web.Response:
        self.user_of(request)
        r = await api.call("status")
        if not r.ok:
            return web.json_response({"error": r.message}, status=502)
        return web.json_response(r.data)

    async def account(self, request: web.Request) -> web.Response:
        """Сведения о веб-панели: адрес, сертификат, сессии, последние входы."""
        u = self.user_of(request)
        tail = []
        try:
            tail = LOG_FILE.read_text(encoding="utf-8").splitlines()[-30:]
        except OSError:
            pass
        sessions = [{"ip": s["ip"], "ua": s["ua"], "created": int(s["created"]), "seen": int(s["seen"]),
                     "me": k == Sessions._key(request.cookies.get(COOKIE, ""))}
                    for k, s in sorted(self.sessions.items.items(), key=lambda kv: -kv[1]["seen"])]
        st = await api.data("web", "status", default={}) or {}
        self.access.refresh()   # awg2 не ответил — режим из конфига, а не «для всех»
        me = client_ip(request.remote)
        vpn = []
        for n in st.get("vpn_nets") or []:
            try:
                vpn.append(ipaddress.ip_network(n, strict=False))
            except ValueError:
                continue
        return web.json_response({"ok": True, "user": u["first_name"], "base": self.base,
                                  "port": self.conf.get("WEB_PORT", ""), "cert": self.cert_kind,
                                  "sessions": sessions, "log": tail[::-1],
                                  "access": {"mode": st.get("access") or self.access.mode, "allow": st.get("allow") or [],
                                             "vpn_url": st.get("vpn_url") or "", "me": str(me) if me else "",
                                             "me_vpn": bool(me and any(me.version == n.version and me in n
                                                                       for n in vpn)),
                                             "me_self": from_self(request)}})

    async def set_access(self, request: web.Request) -> web.Response:
        """Доступ: all | ip (список) | vpn. Тот же awg2 api web access, но с
        адресом этого запроса: режим, который отрезал бы его, awg2 не поставит."""
        self.user_of(request)
        try:
            body = await request.json()
            mode = str(body.get("mode") or "")
            raw = body.get("allow") or []
            if not isinstance(raw, list):
                raise TypeError
            allow = [str(a)[:64] for a in raw][:64]
        except (ValueError, AttributeError, TypeError):
            raise web.HTTPBadRequest(text='{"error": "нужен JSON"}', content_type="application/json") from None
        if mode not in ("all", "ip", "vpn"):
            return web.json_response({"error": "Доступ: all | ip | vpn"}, status=400)
        # С самого сервера панель открывается при любом режиме — проверять нечего
        me = None if from_self(request) else client_ip(request.remote)
        r = await api.call("web", "access", mode, *(allow if mode == "ip" else []),
                           env={"AWG_CLIENT_IP": str(me) if me else ""})
        if not r.ok:
            return web.json_response({"error": r.message, "log": r.log}, status=400)
        journal("ACCESS", request.remote or "?", mode + (" " + ",".join(allow) if mode == "ip" else ""))
        self.notify.send(f"🛡 Веб-панель: доступ — {html.escape({'all': 'для всех', 'ip': 'по адресам и через VPN', 'vpn': 'только через VPN'}[mode])}"
                         f" (адрес <code>{html.escape(request.remote or '?')}</code>)")
        self.access.key = ()
        return web.json_response({"ok": True, "log": r.log})

    async def password(self, request: web.Request) -> web.Response:
        u = self.user_of(request)
        ip = request.remote or "?"
        try:
            body = await request.json()
            old, new = str(body.get("old") or "")[:256], str(body.get("new") or "")[:256]
        except (ValueError, AttributeError):
            raise web.HTTPBadRequest(text='{"error": "нужен JSON"}', content_type="application/json") from None
        self.conf = read_conf()
        if not await asyncio.to_thread(verify_password, old, self.conf.get("WEB_PASS", "")):
            lock = self.guard.fail(ip)
            journal("FAIL", ip, "смена пароля: неверный текущий")
            if lock:
                self.sessions.drop(request.cookies.get(COOKIE, ""))
            return web.json_response({"error": "Текущий пароль неверный"}, status=403)
        if len(new) < PASS_MIN or new == old or new.lower() == u["first_name"].lower():
            return web.json_response({"error": f"Новый пароль — не короче {PASS_MIN} символов и не равен "
                                      "прежнему или логину"}, status=400)
        write_conf({"WEB_PASS": await asyncio.to_thread(hash_password, new)})
        self.conf = read_conf()
        gone = self.sessions.drop_others(request.cookies.get(COOKIE, ""))
        journal("PASSWD", ip, f"другие сессии завершены: {gone}")
        self.notify.send(f"🔑 Веб-панель: пароль сменён (адрес <code>{html.escape(ip)}</code>)")
        return web.json_response({"ok": True, "dropped": gone})

    async def drop_sessions(self, request: web.Request) -> web.Response:
        self.user_of(request)
        gone = self.sessions.drop_others(request.cookies.get(COOKIE, ""))
        journal("SESSIONS", request.remote or "?", f"завершены другие: {gone}")
        return web.json_response({"ok": True, "dropped": gone})

    # ── сборка ──
    def build(self) -> web.Application:
        if self.base == "/":
            raise SystemExit(f"WEB_PATH в {CONF} пуст — панель без секретного пути не запускается")
        app = web.Application(client_max_size=64 * 1024, middlewares=[self.guard_mw])
        app.on_response_prepare.append(self.headers)
        sub = web.Application(client_max_size=64 * 1024)
        sub["bot"] = None                       # отправки в Telegram — только из бота
        sub.router.add_get("/", self.index)
        sub.router.add_get("/web.js", self.web_js)
        sub.router.add_get(r"/{file:(app|icons)\.js}", self.static)
        sub.router.add_get(r"/fonts/{file:[a-z0-9-]{1,40}\.woff2}", self.font)
        sub.router.add_post("/api/login", self.login)
        sub.router.add_post("/api/logout", self.logout)
        sub.router.add_post("/api/me", self.me)
        sub.router.add_post("/api/status", self.status)
        sub.router.add_post("/api/web/account", self.account)
        sub.router.add_post("/api/web/password", self.password)
        sub.router.add_post("/api/web/sessions/drop", self.drop_sessions)
        sub.router.add_post("/api/web/access", self.set_access)
        panel.setup(sub, self.user_of)

        # Адрес без «/» в конце — на панель (знающему путь; остальным — 404).
        # Раньше подприложения: иначе его префикс перехватит адрес.
        async def to_base(request: web.Request) -> web.StreamResponse:
            raise web.HTTPFound(self.base)
        app.router.add_get(self.base.rstrip("/"), to_base)
        # Ссылки на конфиг — в корне, не под секретным путём: путь панели в них не попадает.
        # Доступ по адресам (guard_mw) действует и на них: панель «только через VPN» их не отдаст
        share.setup(app)
        app.add_subapp(self.base.rstrip("/"), sub)
        return app

    def tls(self) -> ssl.SSLContext:
        crt, key, kind = cert_files()
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(crt, key)
        self.ctx, self.cert_kind, self._mtime = ctx, kind, crt.stat().st_mtime
        return ctx

    async def watch_fw(self) -> None:
        """Правило доступа в файрволе на месте и список свежий (сменилась подсеть
        VPN) — иначе awg2 ставит заново. Сама проверка адреса в панели — всегда."""
        if not FW_SCRIPT or not os.path.isfile(FW_SCRIPT):
            return
        while True:
            await asyncio.sleep(FW_EVERY)
            try:
                ok = await asyncio.to_thread(subprocess.run, [FW_SCRIPT, "check"], capture_output=True, timeout=60)
                if ok.returncode:
                    r = await asyncio.to_thread(subprocess.run, [FW_SCRIPT, "apply"], capture_output=True,
                                                text=True, errors="replace", timeout=120)
                    log.info("Правило доступа обновлено (rc=%s) %s", r.returncode, (r.stderr or "").strip()[:200])
                    self.access.key = ()
            except Exception as e:      # noqa: BLE001 — любой сбой не должен молча останавливать возврат правила
                log.warning("Правило доступа не проверено: %s", e)

    async def watch_cert(self) -> None:
        """Продлили сертификат или появился настоящий вместо самоподписанного —
        новые подключения получат его без перезапуска."""
        while True:
            await asyncio.sleep(WATCH_EVERY)
            try:
                crt, key, kind = cert_files()
                if self.ctx and (kind != self.cert_kind or crt.stat().st_mtime != self._mtime):
                    self.ctx.load_cert_chain(crt, key)
                    self.cert_kind, self._mtime = kind, crt.stat().st_mtime
                    log.info("Сертификат обновлён (%s)", kind)
            except (OSError, ssl.SSLError, subprocess.SubprocessError) as e:
                log.warning("Сертификат не перечитан: %s", e)


def same_origin(request: web.Request) -> bool:
    """POST только со страницы самой панели: Origin (его шлют все браузеры)
    совпадает с адресом панели; без Origin — Sec-Fetch-Site."""
    origin = request.headers.get("Origin")
    if origin:
        u = urlsplit(origin)
        return u.scheme == request.scheme and u.netloc == request.host
    return request.headers.get("Sec-Fetch-Site", "same-origin") in ("same-origin", "none")


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    srv = WebPanel()
    conf = srv.conf
    if not (conf.get("WEB_USER") and conf.get("WEB_PASS", "").startswith("scrypt$")):
        raise SystemExit(f"В {CONF} нет WEB_USER/WEB_PASS — задай их: sudo awg2 → Веб-панель")
    port = int(conf.get("WEB_PORT") or 0)
    if not 0 < port < 65536:
        raise SystemExit(f"WEB_PORT в {CONF}: 1-65535")
    runner = web.AppRunner(srv.build(), access_log=None)
    await runner.setup()
    await web.TCPSite(runner, conf.get("WEB_LISTEN") or "0.0.0.0", port, ssl_context=srv.tls()).start()
    log.info("Веб-панель: порт %s, путь %s, сертификат %s", port, srv.base, srv.cert_kind)
    watch = asyncio.create_task(srv.watch_cert())
    fw = asyncio.create_task(srv.watch_fw())
    try:
        await asyncio.Event().wait()
    finally:
        watch.cancel()
        fw.cancel()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
