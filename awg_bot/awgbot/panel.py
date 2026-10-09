"""panel.py — JSON API полной панели Mini App.

Все запросы — POST с JSON (архив бэкапа — телом запроса); подпись Telegram
и доступ проверяет webapp (user_of). Панель делает то же, что бот, и тем же
путём — через awg2 api; сверх него здесь то, что ведёт сам бот: заметки и
мониторинг клиентов, QR, файлы в чат, приём архива бэкапа с телефона. Права —
как в боте: владельческое (удаление всего, удаление бота, сертификат и порт
Mini App) — только владельцам.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import re
from typing import Any, Callable

from aiogram.types import BufferedInputFile, FSInputFile
from aiohttp import web

from . import __version__, access, admins, alerts, api, icons, media, store
from .sections import backup as bk
from .sections import botself
from .sections import clients as cls
from .sections import main as main_menu
from .sections import wgobf

# Команды awg2 api, открытые панели; первое слово — раздел
ALLOWED = {"status", "version", "server", "module", "clients", "client", "mimicry", "diag", "backup",
           "tunnels", "warp", "xray", "t2s", "exits", "cascade", "dns", "wgobf", "update", "log", "bot",
           "cert", "uninstall", "traffic", "antiscan"}
# backup create auto — ротация автобэкапов: «auto 1» стёр бы все, кроме одного;
# log web — журнал входов веб-панели (адреса, введённые логины), как раздел «Веб-панель» в боте
OWNER_ONLY = (("uninstall",), ("bot", "uninstall"), ("bot", "webapp", "port"), ("cert", "issue"),
              ("cert", "use"), ("cert", "remove"), ("backup", "create", "auto"), ("log", "web"))
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
MAX_ARGS, MAX_ARG = 32, 4000       # правка всех параметров 3.1 — 23 аргумента
TIMEOUT_MAX = 900
UPLOAD_MAX = 20 * 1024 * 1024       # как у файлов, присланных боту

UserOf = Callable[[web.Request], dict]


def _bad(text: str) -> web.HTTPBadRequest:
    return web.HTTPBadRequest(text=json.dumps({"error": text}, ensure_ascii=False), content_type="application/json")


def _is_owner(user: dict) -> bool:
    """Владелец бота — или вошедший в веб-панель (там один пользователь, root сервера)."""
    return bool(user.get("owner")) or access.is_owner(int(user["id"]))


def _owner(user: dict) -> None:
    if not _is_owner(user):
        raise web.HTTPForbidden(text='{"error": "только владелец"}', content_type="application/json")


def _bot(request: web.Request):  # type: ignore[no-untyped-def]
    """Бот для отправки в Telegram; в веб-панели его нет — там файлы скачиваются."""
    bot = request.app.get("bot")
    if bot is None:
        raise web.HTTPConflict(text='{"error": "это делает Telegram-бот — в веб-панели недоступно"}',
                               content_type="application/json")
    return bot


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def _conf_zip(data: dict, client: str) -> tuple[bytes, str]:
    """Конфиг клиента в ZIP для веб-панели: внутри «имя.conf» — так его берёт AmneziaWG на телефоне."""
    conf = os.path.basename(data.get("file") or f"{client}.conf")
    if not conf.endswith(".conf"):
        conf = f"{client}.conf"
    return media.zip_data({conf: ((data.get("text") or "") + "\n").encode()}), conf[:-5] + ".zip"


_tasks: set[asyncio.Task] = set()       # отложенный перезапуск сервера панели


async def _body(request: web.Request) -> dict:
    try:
        body = await request.json()
    except ValueError:
        raise _bad("нужен JSON") from None
    if not isinstance(body, dict):
        raise _bad("нужен JSON-объект")
    return body


def _name(body: dict, key: str = "name") -> str:
    name = str(body.get(key) or "")
    if not NAME_RE.match(name):
        raise _bad("имя клиента: латиница, цифры, _ и -, до 32")
    return name


def _args(body: dict) -> list[str]:
    args = body.get("args")
    if (not isinstance(args, list) or not args or len(args) > MAX_ARGS
            or not all(isinstance(a, (str, int)) and len(str(a)) <= MAX_ARG for a in args)):
        raise _bad("args — список строк")
    return [str(a) for a in args]


def _check(user: dict, args: list[str]) -> None:
    if args[0] not in ALLOWED:
        raise web.HTTPForbidden(text='{"error": "команда недоступна панели"}', content_type="application/json")
    if any(tuple(args[:len(p)]) == p for p in OWNER_ONLY) and not _is_owner(user):
        raise web.HTTPForbidden(text='{"error": "только владелец"}', content_type="application/json")


def _result(r: api.Result) -> web.Response:
    return web.json_response({"ok": r.ok, "data": r.data, "log": (r.log or "")[-8000:],
                              "error": "" if r.ok else r.message})


def setup(app: web.Application, user_of: UserOf) -> None:
    """Маршруты панели. user_of(request) — пользователь или 401/403."""

    def route(path: str):  # type: ignore[no-untyped-def]
        def deco(fn: Callable[[web.Request, dict, dict], Any]):  # type: ignore[no-untyped-def]
            async def handler(request: web.Request) -> web.StreamResponse:
                user = user_of(request)
                return await fn(request, user, await _body(request))
            app.router.add_post(path, handler)
            return fn
        return deco

    # ── Общий вызов awg2 api и задачи ──
    @route("/api/call")
    async def _call(request: web.Request, user: dict, body: dict) -> web.Response:
        args = _args(body)
        _check(user, args)
        try:
            timeout = float(body.get("timeout") or 120)
        except (TypeError, ValueError):
            timeout = 120.0
        # Отрицательное или NaN сработало бы сразу — и api.call убил бы awg2
        # посреди изменения конфига.
        if not timeout >= 1:
            timeout = 120.0
        timeout = min(timeout, TIMEOUT_MAX)
        stdin = body.get("stdin")
        # Адрес того, кто включает антисканер: если он внутри списков, awg2
        # сохранит его в исключения. Только адрес соединения — заголовок
        # X-Forwarded-For подделает кто угодно. Только включение и обновление
        # списков: при «allow del» свой адрес иначе тут же вернулся бы обратно.
        env = ({"AWG_CLIENT_IP": request.remote}
               if tuple(args[:2]) in (("antiscan", "on"), ("antiscan", "update"), ("antiscan", "lists")) and request.remote
               else None)
        return _result(await api.call(*args, stdin=stdin if isinstance(stdin, str) else None, timeout=timeout, env=env))

    @route("/api/job")
    async def _job(request: web.Request, user: dict, body: dict) -> web.Response:
        args = _args(body)
        _check(user, args)
        stdin = body.get("stdin")
        return _result(await api.job_start(*args, stdin=stdin if isinstance(stdin, str) else None))

    @route("/api/job/status")
    async def _job_status(request: web.Request, user: dict, body: dict) -> web.Response:
        job_id = str(body.get("id") or "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", job_id):
            raise _bad("id задачи")
        offset = body.get("offset") or 0
        return _result(await api.job_status(job_id, int(offset) if str(offset).isdigit() else 0))

    # ── Клиенты: то, что знает только бот ──
    @route("/api/clients")
    async def _clients(request: web.Request, user: dict, body: dict) -> web.Response:
        # Три вызова awg2 — одновременно, а не по очереди
        r, route_, info = await asyncio.gather(api.call("clients", "list"), cls.active_route(),
                                               api.data("server", "info", default={}))
        if not r.ok:
            return _result(r)
        rows = r.data if isinstance(r.data, list) else []
        notes = store.notes()
        for c in rows:
            raw = notes.get(c["name"], "")
            c["note"] = store.strip_tag(raw)
            c["mon"] = store.MONITOR_TAG in raw.lower()
            c["route"] = cls.route_of(c, route_)
            c["exit_choice"] = cls.exit_of(c, route_) if route_.get("kind") == "exits" else None
        info = info or {}
        return web.json_response({"ok": True, "rows": rows, "route": route_, "profile": info.get("profile") or "",
                                  "sort": store.setting("clients_sort", "activity")})

    @route("/api/client/note")
    async def _note(request: web.Request, user: dict, body: dict) -> web.Response:
        name, text = _name(body), store.strip_tag(str(body.get("text") or "").strip())[:store.NOTE_MAX]
        if store.monitored(name):
            text = f"{text[:store.NOTE_MAX - len(store.MONITOR_TAG) - 1]} {store.MONITOR_TAG}".strip()
        store.set_note(name, text)
        return web.json_response({"ok": True})

    @route("/api/client/mon")
    async def _mon(request: web.Request, user: dict, body: dict) -> web.Response:
        store.set_monitored(_name(body), bool(body.get("on")))
        return web.json_response({"ok": True})

    @route("/api/client/qr")
    async def _qr(request: web.Request, user: dict, body: dict) -> web.Response:
        r = await api.call("client", "conf", _name(body))
        if not r.ok or not isinstance(r.data, dict):
            return _result(r)
        text = r.data.get("text") or ""
        png = media.qr_png(text)
        return web.json_response({"ok": True, "text": text, "file": os.path.basename(r.data.get("file") or ""),
                                  "png": base64.b64encode(png).decode() if png else None})

    @route("/api/client/add")
    async def _add(request: web.Request, user: dict, body: dict) -> web.Response:
        name = _name(body)
        args = ["client", "add", name, f"mimicry={body.get('mimicry') or 'server'}"]
        if body.get("expire"):
            args.append(f"expire={body['expire']}")
        r = await api.call(*args)
        if r.ok:
            store.drop_note(name)       # заметка от удалённого тёзки не наследуется
        return _result(r)

    @route("/api/client/rename")
    async def _rename(request: web.Request, user: dict, body: dict) -> web.Response:
        old, new = _name(body, "old"), _name(body, "new")
        r = await api.call("client", "rename", old, new)
        if r.ok:
            store.rename_note(old, new)
        return _result(r)

    @route("/api/client/del")
    async def _del(request: web.Request, user: dict, body: dict) -> web.Response:
        names = body.get("names")
        if not isinstance(names, list) or not names or not all(isinstance(n, str) and NAME_RE.match(n) for n in names):
            raise _bad("names — список имён")
        r = await (api.call("client", "del", names[0]) if len(names) == 1
                   else api.call("clients", "del", ",".join(names), timeout=600))
        gone = names if len(names) == 1 and r.ok else (r.data if isinstance(r.data, list) else [])
        for n in gone:
            store.drop_note(n)
        return _result(r)

    @route("/api/settings")
    async def _settings(request: web.Request, user: dict, body: dict) -> web.Response:
        if body.get("sort") in cls.SORTS:
            store.set_setting("clients_sort", body["sort"])
        return web.json_response({"ok": True})

    # ── Уведомления о сервере и автобэкап ──
    @route("/api/alerts")
    async def _alerts(request: web.Request, user: dict, body: dict) -> web.Response:
        """Без полей — прочитать; kind+on, backup_mode, backup_keep — изменить
        (только владелец: автобэкап уходит владельцам, уведомления — всем)."""
        if any(k in body for k in ("kind", "backup_mode", "backup_keep", "backup_now")):
            _owner(user)
            if body.get("kind") in alerts.KIND_IDS:
                alerts.set_enabled(body["kind"], bool(body.get("on")))
            mode, keep = body.get("backup_mode"), body.get("backup_keep")
            if mode is not None and mode not in alerts.BACKUP_MODES:
                raise _bad("backup_mode: off | day | week")
            if keep is not None and keep not in alerts.BACKUP_KEEP:
                raise _bad("backup_keep: 3 | 7 | 14 | 30")
            alerts.set_backup(mode=mode, keep=keep)
            now = await alerts.backup_due(_bot(request), force=True) if body.get("backup_now") else ""
            return web.json_response({"ok": True, "owner": True, "backup_now": now, **alerts.overview()})
        return web.json_response({"ok": True, "owner": _is_owner(user), **alerts.overview()})

    # ── Файлы — в чат с ботом ──
    @route("/api/send")
    async def _send(request: web.Request, user: dict, body: dict) -> web.Response:
        bot, uid, what = _bot(request), int(user["id"]), body.get("what")
        if what == "conf":
            ok = await cls.send_config(bot, uid, _name(body))
            return web.json_response({"ok": ok, "error": "" if ok else "Конфига нет — подробности в чате с ботом"})
        if what == "export":
            r = await api.call("clients", "export")
            if not r.ok or not isinstance(r.data, dict):
                return _result(r)
            await bot.send_document(uid, FSInputFile(r.data["file"]), caption="📦 Все конфиги клиентов")
            return web.json_response({"ok": True})
        if what == "zip":
            names = body.get("names")
            if not isinstance(names, list) or not all(isinstance(n, str) and NAME_RE.match(n) for n in names):
                raise _bad("names — список имён")
            rows = await cls.clients() or []
            files = [c["file"] for c in rows if c["name"] in set(names) and c.get("file")]
            await bot.send_document(uid, BufferedInputFile(media.zip_files(files), filename="awg_clients.zip"),
                                    caption=f"📦 Конфиги: {len(files)}")
            return web.json_response({"ok": True})
        if what == "backup":
            # Только бэкап из списка на сервере: иначе это чтение любого файла
            path = str(body.get("path") or "")
            rows = await api.data("backup", "list", default=[]) or []
            if not path or path not in {b.get("path") for b in rows}:
                raise _bad("такого бэкапа на сервере нет")
            data, name = await asyncio.to_thread(bk.pack, path)
            await bot.send_document(uid, BufferedInputFile(data, filename=name),
                                    caption="💾 В бэкапе приватные ключи — храни как пароль")
            return web.json_response({"ok": True})
        if what in ("wgobf", "wgobf_zip"):
            send = wgobf.send_bundle if what == "wgobf" else wgobf.send_archive
            await send(bot, uid, _name(body))
            return web.json_response({"ok": True})
        raise _bad("what: conf | export | zip | backup | wgobf | wgobf_zip")

    # ── Файлы — скачиванием (веб-панель) ──
    def _file(data: bytes, name: str, ctype: str = "application/octet-stream") -> web.Response:
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:120] or "file"
        return web.Response(body=data, content_type=ctype,
                            headers={"Content-Disposition": f'attachment; filename="{safe}"'})

    @route("/api/download")
    async def _download(request: web.Request, user: dict, body: dict) -> web.Response:
        what = body.get("what")
        if what == "conf":
            r = await api.call("client", "conf", _name(body))
            if not r.ok or not isinstance(r.data, dict):
                return _result(r)
            name = os.path.basename(r.data.get("file") or f"{body['name']}.conf")
            # Не text/plain: браузер телефона сохранил бы «имя.conf.txt», а AmneziaWG такой не берёт
            return _file(((r.data.get("text") or "") + "\n").encode(), name)
        if what == "conf_zip":
            r = await api.call("client", "conf", _name(body))
            if not r.ok or not isinstance(r.data, dict):
                return _result(r)
            return _file(*_conf_zip(r.data, body["name"]), "application/zip")
        if what == "export":
            r = await api.call("clients", "export")
            if not r.ok or not isinstance(r.data, dict):
                return _result(r)
            with open(r.data["file"], "rb") as f:
                return _file(f.read(), os.path.basename(r.data["file"]), "application/zip")
        if what == "zip":
            names = body.get("names")
            if not isinstance(names, list) or not all(isinstance(n, str) and NAME_RE.match(n) for n in names):
                raise _bad("names — список имён")
            rows = await cls.clients() or []
            files = [c["file"] for c in rows if c["name"] in set(names) and c.get("file")]
            return _file(media.zip_files(files), "awg_clients.zip", "application/zip")
        if what == "backup":
            path = str(body.get("path") or "")
            rows = await api.data("backup", "list", default=[]) or []
            if not path or path not in {b.get("path") for b in rows}:
                raise _bad("такого бэкапа на сервере нет")
            data, name = await asyncio.to_thread(bk.pack, path)
            return _file(data, name, "application/gzip")
        if what in ("wgobf", "wgobf_zip"):
            r = await api.call("wgobf", "bundle", _name(body))
            if not r.ok or not isinstance(r.data, dict):
                return _result(r)
            files = {f["name"]: f["path"] for f in r.data.get("files") or []}
            if what == "wgobf":
                conf = _read(files.get("phobos.conf", ""))
                if not conf:
                    raise _bad("у клиента нет phobos.conf")
                return _file((conf + "\n").encode(), f"{body['name']}.conf")
            return _file(media.zip_files(list(files.values())), f"wgobf-{body['name']}.zip", "application/zip")
        raise _bad("what: conf | conf_zip | export | zip | backup | wgobf | wgobf_zip")

    # ── WG + обфускатор: комплект клиента на экран ──
    @route("/api/wgobf/bundle")
    async def _wgobf_bundle(request: web.Request, user: dict, body: dict) -> web.Response:
        r = await api.call("wgobf", "bundle", _name(body))
        if not r.ok or not isinstance(r.data, dict):
            return _result(r)
        files = {f["name"]: f["path"] for f in r.data.get("files") or []}
        direct = _read(files.get("wg-direct.conf", ""))
        png = media.qr_png(direct) if direct else None
        return web.json_response({"ok": True, "link": (r.data.get("phobos") or "").strip(),
                                  "conf": _read(files.get("phobos.conf", "")), "direct": direct,
                                  "png": base64.b64encode(png).decode() if png else None,
                                  "mon": store.monitored(store.WGOBF + body["name"])})

    @route("/api/wgobf/mon")
    async def _wgobf_mon(request: web.Request, user: dict, body: dict) -> web.Response:
        store.set_monitored(store.WGOBF + _name(body), bool(body.get("on")))
        return web.json_response({"ok": True})

    # ── Бот: админы, оформление, сервер панели ──
    @route("/api/bot/info")
    async def _bot_info(request: web.Request, user: dict, body: dict) -> web.Response:
        from . import webapp                                # webapp сам подключает панель
        owner = _is_owner(user)
        st = await api.data("bot", "status", default={}) or {}
        srv = webapp.SERVER
        port = webapp.configured_port()
        if request.app.get("bot") is None:
            # Веб-панель: Mini App живёт в процессе бота — состояние по сертификату и службе
            cert = await api.data("cert", "status", default={}) or {}
            host = cert.get("name") or ""
            run = bool(st.get("active")) and bool(host) and port is not None
            wa = {"running": run, "url": (f"https://{host}" + ("" if port == 443 else f":{port}") + "/") if run else "",
                  "error": "" if run else ("выключена" if port is None else "нет сертификата" if not host
                                           else "бот не запущен"), "port": port}
        else:
            wa = {"running": srv.running, "url": srv.url, "error": srv.error, "port": port}
        d: dict[str, Any] = {
            "ok": True, "version": __version__, "owner": owner, "proxy": st.get("proxy") or "",
            "active": st.get("active", True), "owners": len(access.owners()), "invited": len(admins.invited_ids()),
            "icons": {"active": icons.active(), "pack": icons.pack(), "count": len(icons.mapping()),
                      "total": len(icons.TEMPLATE), "default": icons.DEFAULT_PACK},
            "webapp": wa,
        }
        if owner:
            d["admins"] = {"owners": sorted(access.owners()), "pending": admins.pending_invites(),
                           "invited": [{"uid": a.uid, "username": a.username, "added_at": a.added_at}
                                       for a in admins.list_invited()]}
        return web.json_response(d)

    @route("/api/bot/invite")
    async def _invite(request: web.Request, user: dict, body: dict) -> web.Response:
        _owner(user)
        # Сначала бот и его имя: в веб-панели бота нет (409), а Telegram может не
        # ответить — приглашение, созданное до этого, осталось бы невидимым
        me = await _bot(request).me()
        token, exp = admins.create_invite(int(user["id"]))
        if token is None:
            raise _bad(str(exp))
        return web.json_response({"ok": True, "expires": exp,
                                  "link": f"https://t.me/{me.username}?start={admins.INVITE_PREFIX}{token}"})

    @route("/api/bot/admin/del")
    async def _admin_del(request: web.Request, user: dict, body: dict) -> web.Response:
        _owner(user)
        uid = str(body.get("uid") or "")
        if not uid.isdigit():
            raise _bad("uid — число")
        ok, msg = admins.remove(int(uid), removed_by=int(user["id"]))
        return web.json_response({"ok": ok, "message": msg, "error": "" if ok else msg})

    @route("/api/bot/invites/revoke")
    async def _revoke(request: web.Request, user: dict, body: dict) -> web.Response:
        _owner(user)
        return web.json_response({"ok": True, "revoked": admins.revoke_invites()})

    @route("/api/bot/icons")
    async def _icons(request: web.Request, user: dict, body: dict) -> web.Response:
        """Иконки custom emoji в боте: включить набор и проверить на деле —
        пробным сообщением в чат (не показал Telegram — middleware выключит)."""
        _owner(user)
        bot, uid, action = _bot(request), int(user["id"]), body.get("action")
        if action == "off":
            icons.disable("выключены владельцем")
            return web.json_response({"ok": True, "active": False})
        if action == "pack":
            m = botself.PACK_RE.search(str(body.get("name") or icons.DEFAULT_PACK).strip())
            if not m:
                raise _bad("нужна ссылка вида t.me/addemoji/ИМЯ")
            name, mapping = await botself.pack_icons(bot, m.group(1))
            if not mapping:
                raise _bad(name)
        elif action == "on":
            name, mapping = icons.pack(), icons.mapping()
            if not mapping:
                raise _bad("набор иконок ещё не выбран")
        else:
            raise _bad("action: pack | on | off")
        icons.save(name, mapping, True)
        sample = [e for e in icons.TEMPLATE if e in mapping][:8]
        await bot.send_message(uid, "🎨 Проверка иконок из панели: " + " ".join(sample))
        have, miss = icons.coverage(mapping)
        return web.json_response({"ok": True, "active": icons.active(), "pack": name, "have": have, "miss": miss})

    @route("/api/bot/menu")
    async def _menu(request: web.Request, user: dict, body: dict) -> web.Response:
        """Главное меню бота новым сообщением в самый низ чата."""
        await main_menu.send_menu(_bot(request), int(user["id"]))
        return web.json_response({"ok": True})

    @route("/api/bot/webapp/restart")
    async def _webapp_restart(request: web.Request, user: dict, body: dict) -> web.Response:
        """Сервер панели — заново (новый сертификат, порт, удаление): ответ
        уходит сейчас, перезапуск — через секунду."""
        _owner(user)
        from . import webapp
        bot = _bot(request)

        async def later() -> None:
            await asyncio.sleep(1)
            await webapp.SERVER.start(bot)
        task = asyncio.get_running_loop().create_task(later())
        _tasks.add(task)
        task.add_done_callback(_tasks.discard)
        return web.json_response({"ok": True})

    # ── Архив бэкапа с телефона: тело запроса — сам файл ──
    async def _upload(request: web.Request) -> web.Response:
        user_of(request)
        if (request.content_length or 0) > UPLOAD_MAX:
            raise _bad("файл больше 20 МБ")
        data = bytearray()
        async for chunk in request.content.iter_chunked(1 << 16):
            data += chunk
            if len(data) > UPLOAD_MAX:
                raise _bad("файл больше 20 МБ")
        if not data:
            raise _bad("пустой файл")
        path = await asyncio.to_thread(bk.save_upload, bytes(data))
        return web.json_response({"ok": True, "path": str(path)})

    app.router.add_post("/api/backup/upload", _upload)
