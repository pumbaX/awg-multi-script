"""instlink.py — одноразовая ссылка установки клиента WG + обфускатора для
AWG Manager (Keenetic).

Как у панели Phobos — https://хост/api/install/ТОКЕН: AWG Manager → «Phobos» →
поле «Ссылка установки Phobos». Он сам берёт ССЫЛКА/package.tar.gz — архив с
конфигом Phobos (WireGuard + [instance]). Сама ССЫЛКА — только страница-подсказка
(скрипта установки она не отдаёт и не тратится). Отдают оба сервера — Mini App и
веб-панель (у той — если панель доступна этому адресу), как и ссылки на конфиг
(share.py).

Безопасность:
  • ссылка — 192 случайных бита, на диске — только её SHA-256 (права 600);
  • срабатывает один раз (архив) и живёт сутки, «Отозвать» — раньше;
  • привязана к ключу клиента: клиент удалён или пересоздан — не отдаёт ничего;
  • предпросмотр ссылок (Telegram, мессенджеры) и браузеры её не тратят;
    HEAD не обслуживается;
  • неверные ссылки не стоят вызова awg2 и ограничены по частоте с адреса;
  • в журнал — кто создал и для кого, без самой ссылки.
"""

from __future__ import annotations

import fcntl
import hashlib
import html
import io
import logging
import math
import re
import secrets
import tarfile
import time
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import web

from . import api, share, store

log = logging.getLogger("awgbot.instlink")

TTL = 24 * 3600                 # сутки с создания
MAX_ACTIVE = 30                 # больше — старые уходят первыми
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
PATH = "/api/install/"
# Архив — всем, кроме предпросмотра ссылок; curl и wget у самой ссылки — отказ
# (не страница в «| bash»)
SCRIPT_UA = re.compile(r"^(curl|wget)/", re.I)
PREVIEW_UA = re.compile(r"bot|crawler|spider|preview|facebookexternalhit|whatsapp|viber|vkshare|slack|discord|skype"
                        r"|telegram", re.I)
MAX_FILE = 512 * 1024

HEADERS = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Robots-Tag": "noindex, nofollow",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
}


def _file() -> Path:
    return store.STATE_DIR / "wgobf-install.json"


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _save(data: dict) -> None:
    try:
        if not store.save(_file(), data):
            raise share.PersistenceError()
    except OSError as e:
        raise share.PersistenceError() from e


class _Lock:
    """Бот и веб-панель — два процесса с одним файлом ссылок."""

    def __enter__(self) -> "_Lock":
        self.f = None
        try:
            _file().parent.mkdir(parents=True, exist_ok=True)
            self.f = open(str(_file()) + ".lock", "a")
            fcntl.flock(self.f, fcntl.LOCK_EX)
        except OSError as e:
            if self.f is not None:
                self.f.close()
            raise share.PersistenceError() from e
        return self

    def __exit__(self, *exc: object) -> None:
        self.f.close()


def _load(now: float) -> dict[str, dict]:
    active = {}
    for k, v in store.load(_file()).items():
        if not isinstance(v, dict) or not re.fullmatch(r"[0-9a-f]{64}", k):
            continue
        try:
            exp, made = float(v.get("exp") or 0), float(v.get("made") or 0)
        except (TypeError, ValueError):
            continue
        if not math.isfinite(exp) or exp <= now or not math.isfinite(made):
            continue
        name, pub = v.get("name"), v.get("pub")
        if not isinstance(name, str) or not NAME_RE.match(name) or not isinstance(pub, str) or not pub:
            continue
        v["exp"], v["made"] = exp, made
        active[k] = v
    return active


def create(name: str, pub: str, by: str, now: float | None = None) -> tuple[str, str, int]:
    """Новая ссылка → (токен, id для отзыва, истекает). Токен — только в ответе."""
    if not NAME_RE.match(name) or not pub:
        raise ValueError("нет такого клиента")
    now = time.time() if now is None else now
    token = secrets.token_urlsafe(24)
    key = _digest(token)
    exp = int(now) + TTL
    with _Lock():
        data = _load(now)
        while len(data) >= MAX_ACTIVE:
            data.pop(min(data, key=lambda k: data[k].get("made", 0)))
        data[key] = {"name": name, "pub": pub, "exp": exp, "made": int(now), "by": by[:64]}
        _save(data)
    log.info("Ссылка установки %s создана (%s), до %s", name, by, time.strftime("%d.%m %H:%M", time.localtime(exp)))
    return token, key[:12], exp


def revoke(rid: str) -> bool:
    """Отозвать по id (первые 12 знаков отпечатка)."""
    if not re.fullmatch(r"[0-9a-f]{12}", rid or ""):
        return False
    with _Lock():
        data = _load(time.time())
        hit = [k for k in data if k.startswith(rid)]
        if not hit:
            return False
        for k in hit:
            log.info("Ссылка установки %s отозвана", data.pop(k).get("name"))
        _save(data)
    return True


def _peek(token: str) -> dict | None:
    if not TOKEN_RE.match(token or ""):
        return None
    with _Lock():
        rec = _load(time.time()).get(_digest(token))
    return dict(rec) if rec else None


def _consume(token: str, pub: str) -> bool:
    """Потратить ссылку: только если она ещё есть и того же клиента (два запроса
    разом — сработает один)."""
    key = _digest(token)
    with _Lock():
        data = _load(time.time())
        rec = data.get(key)
        if rec is None or rec.get("pub") != pub:
            return False
        data.pop(key)
        _save(data)
    return True


async def _bundle(rec: dict) -> dict[str, bytes] | None:
    """Файлы комплекта клиента — если клиент тот же (ключ совпадает)."""
    r = await api.call("wgobf", "bundle", rec["name"])
    if not r.ok or not isinstance(r.data, dict) or r.data.get("pub") != rec["pub"]:
        return None
    out = {}
    for f in r.data.get("files") or []:
        if not isinstance(f, dict) or f.get("name") not in ("phobos.conf", "README.txt"):
            continue
        try:
            with open(str(f.get("path") or ""), "rb") as fh:
                data = fh.read(MAX_FILE + 1)
        except OSError:
            continue
        if len(data) <= MAX_FILE:
            out[f["name"]] = data
    return out


def _resp(body: str | bytes, status: int = 200, ctype: str = "text/plain", extra: dict | None = None) -> web.Response:
    h = dict(HEADERS)
    h.update(extra or {})
    data = body.encode() if isinstance(body, str) else body
    return web.Response(body=data, status=status, content_type=ctype,
                        charset="utf-8" if ctype.startswith("text") else None, headers=h)


GONE = "Ссылка установки недействительна: истекла, уже сработала или её отозвали. Попросите новую.\n"
NOT_SCRIPT = "Это ссылка для AWG Manager (Keenetic) — вставьте её в поле «Ссылка установки Phobos».\n"

PAGE = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow">
<title>Установка клиента</title>
<style>:root{{color-scheme:light dark}}body{{margin:0;font:16px/1.5 system-ui,sans-serif}}main{{max-width:560px;margin:0 auto;padding:16px}}
code,pre{{font:13px/1.45 ui-monospace,Menlo,Consolas,monospace}}pre{{white-space:pre-wrap;word-break:break-all;padding:10px;
border:1px solid #8884;border-radius:10px}}.muted{{opacity:.7;font-size:14px}}</style></head>
<body><main><h1>Установка клиента {name}</h1>
<p>Это ссылка установки VPN-клиента (WG + обфускатор) для роутера Keenetic. Она срабатывает <b>один раз</b> —
откройте её не в браузере, а в AWG Manager:</p>
<p>AWG Manager → Новый туннель → «Phobos» → поле «Ссылка установки Phobos»: эта ссылка целиком.</p>
<pre>{url}</pre>
<p class="muted">Ссылка — это доступ к VPN: не пересылайте её никому.</p></main></body></html>
"""


def _guard(request: web.Request) -> tuple[str, dict] | web.Response:
    token = request.match_info.get("token", "")
    ip = request.remote or "?"
    if share._limited(ip):
        return _resp("Слишком много попыток — подождите\n", 429)
    try:
        rec = _peek(token)
    except share.PersistenceError as e:
        return _resp(f"{e}\n", 503)
    if rec is None:
        share._fail(ip)
        return _resp(GONE, 404)
    return token, rec


async def _give(request: web.Request, token: str, rec: dict) -> dict[str, bytes] | web.Response:
    files = await _bundle(rec)
    if not files or "phobos.conf" not in files:
        share._fail(request.remote or "?")
        return _resp(GONE, 404)
    try:
        if not _consume(token, rec["pub"]):
            return _resp(GONE, 404)
    except share.PersistenceError as e:
        return _resp(f"{e}\n", 503)
    log.info("Ссылка установки %s сработала: архив AWG Manager (%s)", rec["name"], request.remote or "?")
    return files


async def page(request: web.Request) -> web.Response:
    """Сама ссылка — подсказка, куда её вставить; не тратится."""
    got = _guard(request)
    if isinstance(got, web.Response):
        return got
    token, rec = got
    if SCRIPT_UA.match(request.headers.get("User-Agent", "")):
        return _resp(NOT_SCRIPT, 404)
    host = request.host if share.host_ok(request.host) else "сервер"
    url = f"https://{host}{PATH}{token}"
    return _resp(PAGE.format(name=html.escape(rec["name"]), url=html.escape(url)), ctype="text/html")


def _targz(entries: list[tuple[str, bytes]]) -> bytes:
    buf = io.BytesIO()
    now = int(time.time())
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, data in entries:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), 0o600, now
            tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


async def package(request: web.Request) -> web.Response:
    got = _guard(request)
    if isinstance(got, web.Response):
        return got
    token, rec = got
    if PREVIEW_UA.search(request.headers.get("User-Agent", "")):
        return _resp(GONE, 404)                  # предпросмотр ссылок — без траты
    files = await _give(request, token, rec)
    if isinstance(files, web.Response):
        return files
    # AWG Manager берёт первый .conf, в имени которого нет «obfuscator»
    conf = rec["name"] + ".conf" if "obfuscator" not in rec["name"].lower() else "client.conf"
    entries = [(conf, files["phobos.conf"])]
    if "README.txt" in files:
        entries.append(("README.txt", files["README.txt"]))
    return _resp(_targz(entries), ctype="application/gzip",
                 extra={"Content-Disposition": f'attachment; filename="{rec["name"]}.tar.gz"'})


def url_for(base: str, token: str) -> str:
    """https://хост[:порт]/api/install/ТОКЕН — без пути панели."""
    return f"https://{urlsplit(base).netloc}{PATH}{token}"


def setup(app: web.Application) -> None:
    """Маршруты — в корне сервера (не под секретным путём веб-панели)."""
    app.router.add_get(r"/api/install/{token:[A-Za-z0-9_-]{1,64}}", page, allow_head=False)
    app.router.add_get(r"/api/install/{token:[A-Za-z0-9_-]{1,64}}/package.tar.gz", package, allow_head=False)


def is_path(path: str) -> bool:
    return path.startswith(PATH)
