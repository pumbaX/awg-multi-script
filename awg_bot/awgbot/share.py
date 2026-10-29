"""share.py — ссылка на конфиг клиента, живёт 5 минут.

Админ создаёт ссылку в боте, Mini App или веб-панели и отправляет человеку;
тот открывает её и забирает конфиг: QR (если влезает), текст, файл имя.conf.
Отдают оба сервера — Mini App и веб-панель (у той ссылка откроется, только
если панель доступна этому человеку: «только через VPN» его не пустит).

Безопасность:
  • ссылка — 192 случайных бита (secrets), подобрать нельзя; на диске — только
    её SHA-256 (shares.json, права 600): файл не раскрывает действующих ссылок;
  • 5 минут с создания, «Отозвать» — раньше; ссылка привязана к ключу клиента:
    клиент удалён или под его именем уже другой — ссылка не отдаёт ничего;
  • по GET — только страница-оболочка, конфиг — по POST с неё: предпросмотр
    ссылок (Telegram, мессенджеры) и кэши конфиг не получают;
  • без кэша, не индексируется, без referrer на чужие адреса, во фрейм не встраивается;
  • неверные ссылки не стоят вызова awg2 и ограничены по частоте с адреса;
  • в журнал — кто создал и для кого, без самой ссылки.
"""

from __future__ import annotations

import base64
import fcntl
import hashlib
import ipaddress
import json
import logging
import re
import secrets
import time
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import web

from . import api, media, store, ui

log = logging.getLogger("awgbot.share")

TTL = 300                      # 5 минут с создания
MAX_ACTIVE = 30                # больше — старые уходят первыми
OPENS_MAX = 60                 # запросов конфига на одну ссылку
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
FAIL_WINDOW, FAIL_MAX = 600, 30  # неверных ссылок с адреса за 10 минут

HEADERS = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Robots-Tag": "noindex, nofollow",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": ("default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; "
                                "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"),
}


def _file() -> Path:
    return store.STATE_DIR / "shares.json"


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class PersistenceError(RuntimeError):
    """Состояние ссылок не удалось прочитать, сохранить или заблокировать."""

    def __init__(self) -> None:
        super().__init__("Ошибка хранилища ссылок. Попробуйте позже.")


def _save(data: dict) -> None:
    try:
        if not store.save(_file(), data):
            raise PersistenceError()
    except OSError as e:
        raise PersistenceError() from e


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
            raise PersistenceError() from e
        return self

    def __exit__(self, *exc: object) -> None:
        self.f.close()


def _load(now: float) -> dict[str, dict]:
    try:
        data = json.loads(_file().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, UnicodeError, json.JSONDecodeError) as e:
        raise PersistenceError() from e
    if not isinstance(data, dict):
        raise PersistenceError()
    return {k: v for k, v in data.items() if isinstance(v, dict) and float(v.get("exp") or 0) > now}


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
        data[key] = {"name": name, "pub": pub, "exp": exp, "made": int(now), "by": by[:64], "opens": 0}
        _save(data)
    log.info("Ссылка на конфиг %s создана (%s), до %s", name, by, time.strftime("%H:%M:%S", time.localtime(exp)))
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
        removed = [data.pop(k) for k in hit]
        _save(data)
        for rec in removed:
            log.info("Ссылка на конфиг %s отозвана", rec.get("name"))
    return bool(hit)


def _lookup(token: str, count: bool = False) -> dict | None:
    if not TOKEN_RE.match(token or ""):
        return None
    key = _digest(token)
    with _Lock():
        data = _load(time.time())
        rec = data.get(key)
        if rec is None or (count and int(rec.get("opens") or 0) >= OPENS_MAX):
            return None
        if count:
            rec["opens"] = int(rec.get("opens") or 0) + 1
            _save(data)
    return dict(rec)


def url_for(base: str, token: str) -> str:
    """https://хост[:порт]/s/ТОКЕН — без пути панели (секретный путь веб-панели не раскрываем)."""
    u = urlsplit(base)
    return f"https://{u.netloc}/s/{token}"


def host_ok(host: str) -> bool:
    """Host запроса годится в ссылку: имя или IP с необязательным портом."""
    try:
        u = urlsplit("//" + host)
        name, _ = u.hostname or "", u.port
    except ValueError:
        return False
    if not name or u.username or u.password or u.path or u.query or u.fragment:
        return False
    try:
        ipaddress.ip_address(name)
        return True
    except ValueError:
        return bool(re.fullmatch(r"(?=.{1,253}$)([a-z0-9-]{1,63}\.)*[a-z0-9-]{1,63}", name))


# ── Частота неверных ссылок с адреса ──────────────────────
_fails: dict[str, list[float]] = {}


def _limited(ip: str) -> bool:
    now = time.monotonic()
    hits = [t for t in _fails.get(ip, []) if now - t < FAIL_WINDOW]
    if hits:
        _fails[ip] = hits
    else:
        _fails.pop(ip, None)
    return len(hits) >= FAIL_MAX


def _fail(ip: str) -> None:
    _fails.setdefault(ip, []).append(time.monotonic())
    if len(_fails) > 5000:                     # поток с разных адресов — не копим без конца
        _fails.clear()


async def _client(rec: dict) -> tuple[str, str] | None:
    """(имя, текст конфига) — если клиент тот же (ключ совпадает)."""
    r = await api.call("clients", "list")
    rows = r.data if r.ok and isinstance(r.data, list) else []
    if not any(c.get("name") == rec["name"] and c.get("pub") == rec["pub"] for c in rows):
        return None
    r = await api.call("client", "conf", rec["name"])
    if not r.ok or not isinstance(r.data, dict) or not r.data.get("text"):
        return None
    return rec["name"], str(r.data["text"])


# ── Страница ──────────────────────────────────────────────
PAGE = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Конфиг AmneziaWG</title>
<style>
:root { color-scheme: light dark; --bg: #f4f4f1; --card: #fff; --text: #17181a; --muted: #6b6f76; --line: #e2e2dc;
  --acc: #0d9a5f; --bad: #c8332f; }
@media (prefers-color-scheme: dark) { :root { --bg: #111214; --card: #1b1d20; --text: #ececea; --muted: #9a9ea6;
  --line: #2c2f33; --acc: #33c28a; --bad: #ff6b66; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 440px; margin: 0 auto; padding: 16px 16px 40px; }
.top { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 20px; }
.top svg { width: 20px; height: 20px; flex: none; }
.top a { display: inline-flex; align-items: center; gap: 6px; padding: 8px 12px; border-radius: 999px; border: 1px solid var(--line);
  background: var(--card); color: var(--text); text-decoration: none; font-family: inherit; font-size: 14px; font-weight: 600;
  line-height: 1; white-space: nowrap; }
.top a.don { background: var(--acc); border-color: var(--acc); color: #fff; }
h1 { font-size: 24px; margin: 0 0 4px; }
.muted { color: var(--muted); font-size: 14px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 16px; margin-top: 16px; }
button { width: 100%; font-family: inherit; font-size: 16px; font-weight: 600; line-height: 1; padding: 14px; border-radius: 12px; border: 1px solid var(--line);
  background: var(--card); color: var(--text); margin-top: 10px; cursor: pointer; }
button.main { background: var(--acc); border-color: var(--acc); color: #fff; }
button:disabled { opacity: .5; }
img.qr { display: block; width: 100%; max-width: 320px; margin: 0 auto; image-rendering: pixelated; border-radius: 8px; background: #fff; }
pre { white-space: pre-wrap; word-break: break-all; font: 12px/1.4 ui-monospace, Menlo, Consolas, monospace; max-height: 220px;
  overflow: auto; background: var(--bg); border-radius: 10px; padding: 10px; margin: 12px 0 0; }
.bad { color: var(--bad); }
[hidden] { display: none !important; }
form { margin: 0; }
</style></head>
<body><main data-exp="{exp}">
{top}
<h1>Конфиг AmneziaWG</h1>
<div class="muted" id="left">{left}</div>
<div id="intro" class="card">
  <div>Здесь конфиг для подключения к VPN. Откройте его на устройстве, где стоит AmneziaWG или AmneziaVPN.</div>
  <button class="main" id="show">Показать QR и конфиг</button>
</div>
<div id="box" class="card" hidden>
  <div id="qrwrap"><img class="qr" id="qr" alt="QR-код конфига"></div>
  <div id="noqr" class="muted" hidden>Конфиг слишком большой для QR — скачайте файл или скопируйте текст.</div>
  <form method="post" action="/s/{token}/file"><button class="main" type="submit">⬇️ Скачать <span id="fname">.conf</span></button></form>
  <button id="copy">📋 Скопировать текстом</button>
  <pre id="text"></pre>
  <div class="muted" style="margin-top:12px">Импорт: AmneziaWG или AmneziaVPN → «+» → QR-код или файл.</div>
</div>
<div id="err" class="card bad" hidden></div>
</main><script src="/s.js"></script></body></html>
"""

GONE = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow">
<title>Ссылка недействительна</title>
<style>:root{color-scheme:light dark}body{margin:0;font:16px/1.45 system-ui,sans-serif}main{max-width:440px;margin:0 auto;padding:16px}
.top{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:20px}.top svg{width:20px;height:20px;flex:none}
.top a{display:inline-flex;align-items:center;gap:6px;padding:8px 12px;border-radius:999px;border:1px solid #8884;text-decoration:none;color:inherit;font-size:14px;font-weight:600;line-height:1;white-space:nowrap}
.top a.don{background:#0d9a5f;border-color:#0d9a5f;color:#fff}</style>
</head><body><main>{top}<h1>Ссылка недействительна</h1>
<p>Срок ссылки (5 минут) истёк или её отозвали. Попросите новую у того, кто её прислал.</p></main></body></html>
"""

# Шапка: Тулза в Telegram и «Поддержать» — те же адреса, что у кнопок бота
# Значок Telegram — свой SVG в странице (внешних файлов страница не грузит)
TG_ICON = ('<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="12" fill="#2AABEE"/>'
           '<path fill="#fff" d="M5.4 11.7l11.7-4.5c.6-.2 1 .1.9.9l-2 9.4c-.1.7-.6.8-1.1.5l-3.1-2.3-1.5 1.4c-.2.2-.3.3-.6.3'
           'l.2-3.1 5.7-5.2c.3-.2 0-.4-.4-.1l-7 4.4-3-.9c-.7-.2-.7-.6.2-.8z"/></svg>')
TOP = (f'<div class="top">'
       f'<a href="{ui.CHANNEL_URL}" target="_blank" rel="noopener noreferrer">{TG_ICON}Telegram</a>'
       f'<a class="don" href="{ui.SUPPORT_URL}" target="_blank" rel="noopener noreferrer">💙 Поддержать</a></div>')

JS = r"""(function () {
  var main = document.querySelector("main"), exp = +main.getAttribute("data-exp") * 1000;
  var token = location.pathname.split("/")[2] || "", left = document.getElementById("left");
  var errBox = document.getElementById("err"), text = "";
  function err(m) { errBox.textContent = m; errBox.hidden = false; }
  function tick() {
    var s = Math.max(0, Math.round((exp - Date.now()) / 1000));
    left.textContent = s ? "Ссылка действует ещё " + Math.floor(s / 60) + ":" + ("0" + s % 60).slice(-2) : "Срок ссылки истёк";
    if (!s) { document.querySelectorAll("button").forEach(function (b) { b.disabled = true; }); return; }
    setTimeout(tick, 1000);
  }
  tick();
  document.getElementById("show").onclick = function () {
    var b = this; b.disabled = true;
    fetch("/s/" + token + "/data", { method: "POST", credentials: "omit", headers: { "Content-Type": "application/json" }, body: "{}" })
      .then(function (r) { if (!r.ok) throw new Error(r.status >= 500 ? "Ошибка хранилища ссылок. Попробуйте позже." :
        r.status === 429 ? "Слишком много попыток — подождите" : "Ссылка недействительна или истекла"); return r.json(); })
      .then(function (d) {
        text = d.text; document.getElementById("text").textContent = d.text;
        document.getElementById("fname").textContent = d.file;
        if (d.qr) document.getElementById("qr").src = "data:image/png;base64," + d.qr;
        else { document.getElementById("qrwrap").hidden = true; document.getElementById("noqr").hidden = false; }
        document.getElementById("intro").hidden = true; document.getElementById("box").hidden = false;
      })
      .catch(function (e) { err(e.message); b.disabled = false; });
  };
  document.getElementById("copy").onclick = function () {
    var b = this, done = function () { b.textContent = "✅ Скопировано"; setTimeout(function () { b.textContent = "📋 Скопировать текстом"; }, 2000); };
    if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text).then(done, fallback); } else fallback();
    function fallback() {
      var t = document.createElement("textarea"); t.value = text; document.body.appendChild(t); t.select();
      try { document.execCommand("copy"); done(); } catch (e) { err("Не скопировалось — выделите текст ниже вручную"); }
      t.remove();
    }
  };
})();
"""


def _resp(body: str | bytes, status: int = 200, ctype: str = "text/html", extra: dict | None = None) -> web.Response:
    h = dict(HEADERS)
    h.update(extra or {})
    data = body.encode() if isinstance(body, str) else body
    return web.Response(body=data, status=status, content_type=ctype, charset="utf-8" if ctype.startswith("text") or
                        ctype.endswith("json") or ctype.endswith("javascript") else None, headers=h)


def _ip(request: web.Request) -> str:
    return request.remote or "?"


async def page(request: web.Request) -> web.Response:
    token = request.match_info.get("token", "")
    ip = _ip(request)
    if _limited(ip):
        return _resp("Слишком много попыток — подождите", 429, "text/plain")
    try:
        rec = _lookup(token)
    except PersistenceError as e:
        return _resp(str(e), 503, "text/plain")
    if rec is None:
        _fail(ip)
        return _resp(GONE.replace("{top}", TOP), 404)
    left = max(0, int(rec["exp"] - time.time()))
    # Форма «Скачать» — обычный POST: при no-referrer браузер шлёт её с Origin: null,
    # и веб-панель отвечает 403 «чужой сайт». same-origin — Origin свой; на чужие
    # адреса (Telegram, «Поддержать») ни Referer, ни ссылка по-прежнему не уходят
    return _resp(PAGE.replace("{top}", TOP).replace("{exp}", str(int(rec["exp"]))).replace("{token}", token)
                 .replace("{left}", f"Ссылка действует ещё {left // 60}:{left % 60:02d}"),
                 extra={"Referrer-Policy": "same-origin"})


async def _payload(request: web.Request) -> tuple[str, str] | web.Response:
    token = request.match_info.get("token", "")
    ip = _ip(request)
    if _limited(ip):
        return _resp('{"error": "слишком много попыток"}', 429, "application/json")
    try:
        rec = _lookup(token, count=True)
    except PersistenceError as e:
        return _resp(json.dumps({"error": str(e)}), 503, "application/json")
    got = await _client(rec) if rec else None
    if got is None:
        _fail(ip)
        return _resp('{"error": "ссылка недействительна"}', 404, "application/json")
    return got


async def data(request: web.Request) -> web.Response:
    got = await _payload(request)
    if isinstance(got, web.Response):
        return got
    name, text = got
    png = media.qr_png(text)
    return _resp(json.dumps({"file": f"{name}.conf", "text": text,
                             "qr": base64.b64encode(png).decode() if png else None}), ctype="application/json")


async def file(request: web.Request) -> web.Response:
    got = await _payload(request)
    if isinstance(got, web.Response):
        return got
    name, text = got
    return _resp(text, ctype="application/octet-stream",
                 extra={"Content-Disposition": f'attachment; filename="{name}.conf"'})


async def js(request: web.Request) -> web.Response:
    return _resp(JS, ctype="application/javascript", extra={"Cache-Control": "no-cache"})


def setup(app: web.Application) -> None:
    """Маршруты ссылок — в корне сервера (не под секретным путём веб-панели)."""
    app.router.add_get(r"/s/{token:[A-Za-z0-9_-]{1,64}}", page)
    app.router.add_post(r"/s/{token:[A-Za-z0-9_-]{1,64}}/data", data)
    app.router.add_post(r"/s/{token:[A-Za-z0-9_-]{1,64}}/file", file)
    app.router.add_get("/s.js", js)


def is_share_path(path: str) -> bool:
    return path == "/s.js" or path.startswith("/s/")

