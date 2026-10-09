"""Туннели и DNS: WARP, Xray, tun2socks, AWG exit-ноды, каскад портов,
шифрованный DNS и аварийный сброс — пункты меню «Туннели и DNS» awg2."""

from __future__ import annotations

import re

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import api, ask, jobs, ui
from ..ui import esc
from . import clients

router = Router()
tun = ui.Actions(router, "tun")
tc = ui.Actions(router, "tc")
warp = ui.Actions(router, "warp")
xr = ui.Actions(router, "xr")
t2s = ui.Actions(router, "t2s")
ex = ui.Actions(router, "ex")
cas = ui.Actions(router, "cas")
dns = ui.Actions(router, "dns")

IP_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")


async def quick(target: ui.Target, title: str, back_to: str, *args: str) -> None:
    """Быстрая команда: «⏳», затем итог с журналом awg2."""
    await ui.render(target, f"⏳ {esc(title)}…")
    await ui.result(target, await api.call(*args), title, back_to)


# ── Меню туннелей ─────────────────────────────────────────
@tun()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    d = await api.data("tunnels", "status", default={}) or {}

    names = [("warp", "WARP", "warp"), ("xray", "Xray", "xr"), ("tun2socks", "tun2socks", "t2s"),
             ("exits", "Exit-ноды WG", "ex"), ("dns", "Шифр. DNS", "dns")]
    n = d.get("cascade", 0)
    lines = [f"{ui.state_icon(d.get(k, 'none'))} {label} — {ui.state_word(d.get(k, 'none'))}" for k, label, _ in names]
    lines.insert(4, f"{'🟢' if n else '▫️'} Каскад портов — {'правил: ' + str(n) if n else 'правил нет'}")
    text = ("<b>🌐 Туннели и DNS</b>\n\nОдновременно работает только один туннель для клиентов."
            + (f"\nСейчас: <b>{esc(d['active'])}</b>" if d.get("active") else "")
            + "\n\n" + "\n".join(lines)
            + "\n\n<i>🚨 Всё напрямую — аварийно выключить туннели, настройки сохранятся</i>")
    buttons = [(f"{ui.state_icon(d.get(k, 'none'))} {label}", to) for k, label, to in names]
    buttons.insert(4, (f"{'🟢' if n else '▫️'} Каскад", "cas"))
    await ui.render(cb, text, ui.kb(buttons, ("🚨 Всё напрямую", tun.data("panic")), ui.back()))


@tun("panic")
async def _panic(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Выключить все туннели (WARP, Xray, tun2socks, exit-ноды)? Клиенты пойдут напрямую "
                         "через сервер, настройки сохранятся.",
                     ("🚨 Да, выключить", tun.data("panicok")), "tun")


@tun("panicok")
async def _panic_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Аварийный сброс", "tun", "tunnels", "panic")


# ── Клиенты туннеля (WARP, Xray) ──────────────────────────
@tc()
async def clients_screen(cb: CallbackQuery, state: FSMContext, kind: str, page: int = 0) -> None:
    rows = await api.data("tunnels", "clients", kind, default=[]) or []
    back_to = "warp" if kind == "warp" else "xr"
    if not rows:
        await ui.render(cb, "Клиентов нет.", ui.kb(ui.back(back_to)))
        return
    await ui.render(cb, f"<b>👥 Клиенты в {'WARP' if kind == 'warp' else 'Xray'}</b>\n"
                        "✅ — через туннель, ➖ — напрямую. Нажатие переключает.",
                    ui.kb(ui.paged([(f"{'✅' if r['on'] else '➖'} {r['name']}",
                                     tc.data("t", f"{kind}|{r['name']}|{page}")) for r in rows],
                                   page, lambda p: tc.data("pg", f"{kind}|{p}")),
                          ("✅ Все в туннель", tc.data("a", f"{kind}|all")),
                          ("➖ Все напрямую", tc.data("a", f"{kind}|none")),
                          ui.back(back_to)))


@tc("pg")
async def _page(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    kind, _, page = arg.partition("|")
    await clients_screen(cb, state, kind, int(page) if page.isdigit() else 0)


@tc("t")
async def _toggle(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    kind, name, page = (arg.split("|") + ["", "0"])[:3]
    rows = await api.data("tunnels", "clients", kind, default=[]) or []
    on = next((r["on"] for r in rows if r["name"] == name), False)
    r = await api.call("tunnels", "client", kind, name, "off" if on else "on")
    if not r.ok:
        await cb.answer(r.message[:190], show_alert=True)
    await clients_screen(cb, state, kind, int(page) if page.isdigit() else 0)


@tc("a")
async def _all(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    kind, _, what = arg.partition("|")
    r = await api.call("tunnels", "client", kind, what)
    if not r.ok:
        await cb.answer(r.message[:190], show_alert=True)
    await clients_screen(cb, state, kind)


# ── WARP ──────────────────────────────────────────────────
@warp()
async def warp_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    r = await api.call("warp", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "WARP"), ui.kb(ui.back("tun")))
        return
    d = r.data
    wg = d.get("backend") == "wg"
    conf = d.get("configured")
    hints = [f"📦 — {'переустановить' if conf else 'установить'} и зарегистрировать (бэкенд {esc(d.get('backend') or '?')})"]
    if conf:
        hints.append("✅ Health-check — сам перезапускает WARP, если тот перестал отвечать")
    if wg:
        hints.append("📥 Импорт — свой wgcf-profile.conf, если регистрация отсюда не проходит")
    await ui.render(cb, "<b>☁️ WARP (Cloudflare)</b>\n" + ui.pre(r.log, 1500, tail=False)
                    + "\n<i>" + "\n".join(hints) + "</i>", ui.kb(
        ("📦 Переустановить" if conf else "📦 Установить", warp.data("install")),
        ("▶️ Включить", warp.data("up")) if conf and not d.get("up") else None,
        ("⏹ Выключить", warp.data("down")) if d.get("up") else None,
        ("👥 Клиенты", tc.data("", "warp")) if conf else None,
        (f"{'✅' if d.get('health') else '⬜️'} Health-check",
         warp.data("health", "off" if d.get("health") else "on")) if conf else None,
        ("🔑 Ключ Warp+", warp.data("key")) if wg and conf else None,
        ("📥 Импорт профиля", warp.data("import")) if wg else None,
        ("🔎 Поиск endpoint", warp.data("ep")) if wg and conf else None,
        ("🔀 Сменить бэкенд", warp.data("backend")),
        ("🗑 Удалить", warp.data("rm")) if conf else None,
        ui.back("tun")))


@warp("install")
async def _warp_install(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Установка WARP", "warp", "install", back_to="warp")


@warp("up")
async def _warp_up(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Включение WARP", "warp", "up", back_to="warp")


@warp("down")
async def _warp_down(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Выключение WARP", "warp", "warp", "down")


@warp("health")
async def _warp_health(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    r = await api.call("warp", "health", v)
    if not r.ok:
        await cb.answer(r.message[:190], show_alert=True)
    await warp_screen(cb, state)


@warp("key")
async def _warp_key(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "warp_key", "Ключ Warp+ — в приложении 1.1.1.1: Аккаунт → Ключ.\n"
                                         "Формат: <code>xxxxxxxx-xxxxxxxx-xxxxxxxx</code>", "warp")


@ask.on("warp_key")
async def _warp_key_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    key = ask.text_of(msg)
    if not re.fullmatch(r"[A-Za-z0-9]+-[A-Za-z0-9]+-[A-Za-z0-9]+", key):
        await ask.retry(msg, state, ctx, "Неверный формат ключа")
        return
    await quick(msg, "Warp+", "warp", "warp", "license", key)


@warp("import")
async def _warp_import(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "warp_import",
                  "Зарегистрируй профиль там, где Cloudflare доступен (например, shell.cloud.google.com):\n"
                  "<code>./wgcf register --accept-tos &amp;&amp; ./wgcf generate</code>\n\n"
                  "Пришли <code>wgcf-profile.conf</code> файлом или текстом.", "warp")


@ask.on("warp_import")
async def _warp_import_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    data = await ask.file_of(msg)
    text = data.decode(errors="replace") if data else ask.text_of(msg)
    if "[Interface]" not in text or "[Peer]" not in text:
        await ask.retry(msg, state, ctx, "Это не похоже на wgcf-profile.conf")
        return
    await ui.render(msg, "⏳ Импортирую профиль…")
    await ui.result(msg, await api.call("warp", "import", stdin=text), "Импорт профиля WARP", "warp")


@warp("ep")
async def _warp_ep(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "warp_ep", "Страна выхода — две буквы (<code>DE</code>, <code>NL</code>) "
                                        "или любая.", "warp", [("🌍 Любая страна", warp.data("epgo"))])


@ask.on("warp_ep")
async def _warp_ep_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    cc = ask.text_of(msg).upper()
    if not re.fullmatch(r"[A-Z]{2}", cc):
        await ask.retry(msg, state, ctx, "Две латинские буквы, например DE")
        return
    await jobs.start(msg, f"Поиск endpoint WARP ({cc})", "warp", "endpoint", cc, back_to="warp")


@warp("epgo")
async def _warp_ep_any(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Поиск endpoint WARP", "warp", "endpoint", back_to="warp")


@warp("backend")
async def _warp_backend(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    d = await api.data("warp", "status", default={}) or {}
    cur = d.get("backend")
    await ui.render(cb, f"<b>🔀 Бэкенд WARP</b>\nСейчас: <b>{esc(cur or '?')}</b>\n\n"
                        "• wg — WireGuard ядра, быстрее\n• usque — MASQUE (HTTP/3), когда WireGuard к Cloudflare режут",
                    ui.kb(("wg — WireGuard", warp.data("be", "wg")) if cur != "wg" and d.get("wg_possible") else None,
                          ("usque — MASQUE", warp.data("be", "usque"))
                          if cur != "usque" and d.get("usque_possible") else None,
                          ui.back("warp")))


@warp("be")
async def _warp_be(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    await jobs.start(cb, f"WARP: бэкенд {v}", "warp", "backend", v, back_to="warp")


@warp("rm")
async def _warp_rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Удалить WARP: аккаунт, профиль, службы?", ("🗑 Удалить WARP", warp.data("rmok")), "warp")


@warp("rmok")
async def _warp_rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Удаление WARP", "tun", "warp", "remove")


# ── Xray ──────────────────────────────────────────────────
BALANCERS = [("random", "случайный выход"), ("roundRobin", "по очереди"), ("leastPing", "наименьший пинг"),
             ("leastLoad", "наименьшая нагрузка"), ("off", "выключить")]


@xr()
async def xray_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    r = await api.call("xray", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "Xray"), ui.kb(ui.back("tun")))
        return
    d = r.data
    inst, up, tags = d.get("installed"), d.get("up"), d.get("tags") or []
    text = "<b>🛰 Xray</b>\n" + ui.pre(r.log, 1500, tail=False)
    if inst:
        text += ("\n<i>➕ Добавить выход — ссылкой vless://, vmess://, trojan://, ss://, hysteria2://\n"
                 "✅ РФ напрямую — российские сайты мимо Xray"
                 + (f"\n⚖️ — как делить трафик между выходами (сейчас {esc(d.get('balancer') or '?')})"
                    if len(tags) > 1 else "") + "</i>")
    await ui.render(cb, text, ui.kb(
        (f"📦 {'Обновить' if inst else 'Установить'}", xr.data("install")),
        ("➕ Добавить выход", xr.data("add")) if inst else None,
        ("➖ Удалить выход", xr.data("del")) if tags else None,
        ("⚖️ Балансировщик", xr.data("bal")) if len(tags) > 1 else None,
        ("▶️ Включить", xr.data("up")) if inst and tags and not up else None,
        ("⏹ Выключить", xr.data("down")) if up else None,
        ("🔄 Перезапустить", xr.data("restart")) if up else None,
        ("👥 Клиенты", tc.data("", "xray")) if inst else None,
        (f"{'✅' if d.get('ru') else '⬜️'} РФ напрямую", xr.data("ru", "off" if d.get("ru") else "on")) if inst else None,
        ("🩺 Диагностика", xr.data("diag")) if inst else None,
        ("🛠 Починить", xr.data("fix")) if inst else None,
        ("🗑 Удалить", xr.data("rm")) if inst else None,
        ui.back("tun")))


@xr("install")
async def _xr_install(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Установка Xray", "xray", "install", back_to="xr")


@xr("add")
async def _xr_add(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "xr_link", "Ссылка на сервер: <code>vless://</code>, <code>vmess://</code>, "
                                        "<code>trojan://</code>, <code>ss://</code> или <code>hysteria2://</code>",
                  "xr")


@ask.on("xr_link")
async def _xr_link(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    link = ask.text_of(msg)
    if not re.match(r"^(vless|vmess|trojan|ss|hysteria2|hy2)://", link):
        await ask.retry(msg, state, ctx, "Это не ссылка Xray")
        return
    await quick(msg, "Выход Xray", "xr", "xray", "add", link)


@xr("del")
async def _xr_del(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    tags = (await api.data("xray", "status", default={}) or {}).get("tags") or []
    await ui.remember(state, "xtags", tags)
    await ui.render(cb, "<b>➖ Удалить выход</b>", ui.kb([(t, xr.data("delq", str(i))) for i, t in enumerate(tags)],
                                                      ui.back("xr")))


# Удаление переспрашивает, как WARP, Xray целиком и клиенты: кнопки списка — рядом
@xr("delq")
async def _xr_del_ask(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    tag = await ui.recall(state, "xtags", idx)
    if not tag:
        await _xr_del(cb, state, "")
        return
    await ui.confirm(cb, f"Удалить выход Xray <b>{esc(tag)}</b>?", ("🗑 Удалить", xr.data("delok", idx)), xr.data("del"))


@xr("delok")
async def _xr_del_ok(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    tag = await ui.recall(state, "xtags", idx)
    if tag:
        await quick(cb, f"Удаление выхода {tag}", "xr", "xray", "del", tag)


@xr("bal")
async def _xr_bal(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "<b>⚖️ Балансировщик выходов</b>\n\n"
                        + "\n".join(f"• <b>{k}</b> — {label}" for k, label in BALANCERS),
                    ui.kb([(k, xr.data("balset", k)) for k, _ in BALANCERS], ui.back("xr")))


@xr("balset")
async def _xr_bal_set(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    await quick(cb, f"Балансировщик: {v}", "xr", "xray", "balancer", v)


@xr("up")
async def _xr_up(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Включение Xray", "xray", "up", back_to="xr")


@xr("down")
async def _xr_down(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Выключение Xray", "xr", "xray", "down")


@xr("restart")
async def _xr_restart(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Перезапуск Xray", "xray", "restart", back_to="xr")


@xr("ru")
async def _xr_ru(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    await jobs.start(cb, f"РФ-сайты напрямую: {'вкл' if v == 'on' else 'выкл'}", "xray", "ru", v, back_to="xr")


@xr("diag")
async def _xr_diag(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Диагностика Xray", "xray", "diag", back_to="xr")


@xr("fix")
async def _xr_fix(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Исправление конфига Xray", "xr", "xray", "fix")


@xr("rm")
async def _xr_rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Удалить Xray: бинарь, конфиг с выходами, службы?", ("🗑 Удалить Xray", xr.data("rmok")), "xr")


@xr("rmok")
async def _xr_rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Удаление Xray", "tun", "xray", "remove")


# ── tun2socks ─────────────────────────────────────────────
@t2s()
async def t2s_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    d = await api.data("t2s", "status", default={}) or {}
    proxy = d.get("proxy") or ""
    await ui.render(cb, "<b>🧦 tun2socks</b>\nВсе клиенты выходят через внешний SOCKS5-прокси.\n\n"
                        f"Статус: {'🟢 включён' if d.get('up') else '⚪️ выключен'}"
                        + (f"\nПрокси: <code>{esc(proxy)}</code>" if proxy else ""),
                    ui.kb(("▶️ Включить", t2s.data("up")) if not d.get("up") else None,
                          ("⏹ Выключить", t2s.data("down")) if d.get("up") else None,
                          ("📜 Журнал", "diag:log:tun2socks|t2s"),
                          ("🗑 Удалить", t2s.data("rm")) if proxy else None,
                          ui.back("tun")))


@t2s("up")
async def _t2s_up(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    proxy = (await api.data("t2s", "status", default={}) or {}).get("proxy") or ""
    await ask.ask(cb, state, "t2s_proxy", "Адрес SOCKS5-прокси: <code>IP:ПОРТ</code>, например 5.6.7.8:1080",
                  "t2s", [(f"Прежний: {proxy}", t2s.data("go"))] if proxy else None)


@ask.on("t2s_proxy")
async def _t2s_proxy(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not re.fullmatch(r"[A-Za-z0-9._-]+:\d{1,5}", v):
        await ask.retry(msg, state, ctx, "Нужен адрес вида IP:ПОРТ")
        return
    await jobs.start(msg, "Включение tun2socks", "t2s", "up", v, back_to="t2s")


@t2s("go")
async def _t2s_go(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Включение tun2socks", "t2s", "up", back_to="t2s")


@t2s("down")
async def _t2s_down(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Выключение tun2socks", "t2s", "t2s", "down")


@t2s("rm")
async def _t2s_rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Удалить tun2socks (служба, бинарь, адрес прокси)?", ("🗑 Удалить", t2s.data("rmok")), "t2s")


@t2s("rmok")
async def _t2s_rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Удаление tun2socks", "tun", "t2s", "remove")


# ── AWG exit-ноды ─────────────────────────────────────────
@ex()
async def exits_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    r = await api.call("exits", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "Exit-ноды"), ui.kb(ui.back("tun")))
        return
    d = r.data
    nodes, up = d.get("nodes") or [], d.get("up")
    await ui.render(cb, "<b>🚪 AWG exit-ноды</b>\nКлиенты выходят в интернет через другие AWG/WG-серверы.\n"
                        + ui.pre(r.log, 1800, tail=False)
                        + ("\n<i>Маршруты: ▶️ все клиенты через ноды · 🎯 только выбранные клиенты</i>"
                           if nodes else ""), ui.kb(
        ("➕ Добавить ноду", ex.data("add")),
        ("➖ Удалить ноду", ex.data("del")) if nodes else None,
        ("▶️ Все клиенты", ex.data("up", "all")) if nodes and (not up or d.get("mode") != "all") else None,
        ("🎯 Выбранные", ex.data("up", "peers")) if nodes and (not up or d.get("mode") != "peers") else None,
        ("⏹ Выключить", ex.data("down")) if up else None,
        ("⚖️ Балансировка", ex.data("bal")) if nodes else None,
        ("👥 Клиенты и ноды", ex.data("cl")) if nodes else None,
        ui.back("tun")))


@ex("add")
async def _ex_add(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "ex_name", "Имя ноды: латиница, цифры, _, до 6 символов (например <code>de1</code>).",
                  "ex")


@ask.on("ex_name")
async def _ex_name(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    name = ask.text_of(msg)
    if not re.fullmatch(r"[A-Za-z0-9_]{1,6}", name):
        await ask.retry(msg, state, ctx, "Имя: латиница, цифры, _, до 6 символов")
        return
    await ask.ask(msg, state, "ex_conf", f"Клиентский конфиг AWG/WG для ноды <b>{esc(name)}</b> — файлом или "
                                         "текстом. Маршрут всего сервера он не заберёт: awg2 ставит Table = off.",
                  "ex", name=name)


@ask.on("ex_conf")
async def _ex_conf(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    data = await ask.file_of(msg)
    text = data.decode(errors="replace") if data else ask.text_of(msg)
    if "[Interface]" not in text or "Endpoint" not in text:
        await ask.retry(msg, state, ctx, "Нужен клиентский конфиг с [Interface] и Endpoint")
        return
    await jobs.start(msg, f"Exit-нода {ctx['name']}", "exits", "add", ctx["name"], stdin=text, back_to="ex")


@ex("del")
async def _ex_del(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    nodes = (await api.data("exits", "status", default={}) or {}).get("nodes") or []
    await ui.render(cb, "<b>➖ Удалить ноду</b>\nЕё клиенты перейдут на общий выход.",
                    ui.kb([(f"{'🟢' if n['up'] else '🔴'} {n['name']}", ex.data("delq", n["name"])) for n in nodes],
                          ui.back("ex")))


@ex("delq")
async def _ex_del_ask(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ui.confirm(cb, f"Удалить exit-ноду <b>{esc(name)}</b>? Её клиенты перейдут на общий выход.",
                     ("🗑 Удалить", ex.data("delok", name)), ex.data("del"))


@ex("delok")
async def _ex_del_ok(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await quick(cb, f"Удаление ноды {name}", "ex", "exits", "del", name)


@ex("up")
async def _ex_up(cb: CallbackQuery, state: FSMContext, mode: str) -> None:
    await jobs.start(cb, "Маршруты через exit-ноды", "exits", "up", mode, back_to="ex")


@ex("down")
async def _ex_down(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Выключение маршрутов", "ex", "exits", "down")


@ex("bal")
async def _ex_bal(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    d = await api.data("exits", "status", default={}) or {}
    nodes = d.get("nodes") or []
    cur = "ecmp" if d.get("balancer") == "ecmp" else d.get("single") or ""
    await ui.render(cb, "<b>⚖️ Балансировка</b>\nОдна нода — весь общий трафик через неё; "
                        "ECMP — поровну между поднятыми нодами.",
                    ui.kb([(f"{'🔘' if cur == n['name'] else '⚪️'} {n['name']}",
                            ex.data("balset", f"single|{n['name']}")) for n in nodes],
                          (f"{'🔘' if cur == 'ecmp' else '⚪️'} ECMP", ex.data("balset", "ecmp|")),
                          ui.back("ex")))


@ex("balset")
async def _ex_bal_set(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    mode, _, node = arg.partition("|")
    await quick(cb, "Балансировка", "ex", "exits", "balance", mode, *([node] if node else []))


@ex("cl")
async def _ex_clients(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    rows, odd = clients.usable(await api.data("clients", "list", default=[]) or [])
    d = await api.data("exits", "status", default={}) or {}
    route = {"kind": "exits", "mode": d.get("mode") or "all"}
    label = {"off": "напрямую", "shared": "общий"}
    page = int(arg) if arg.isdigit() else 0
    text = "<b>👥 Клиенты и exit-ноды</b>\n"
    text += ("Нажми клиента, чтобы выбрать его выход." if d.get("up")
             else "Маршруты выключены — выбор вступит в силу, когда их включишь.") + clients.odd_note(odd)
    await ui.render(cb, text, ui.kb(
        ui.paged([(f"{c['name']} → {label.get(clients.exit_of(c, route), clients.exit_of(c, route))}",
                   ex.data("pick", c["name"])) for c in rows], page, lambda p: ex.data("cl", str(p))),
        ui.back("ex")))


@ex("pick")
async def _ex_pick(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    d = await api.data("exits", "status", default={}) or {}
    c = await clients.client(name)
    if c is None:
        await _ex_clients(cb, state, "")
        return
    route = {"kind": "exits", "mode": d.get("mode") or "all"}
    cur = clients.exit_of(c, route)
    opts = [("Напрямую", "off"), ("Общий выход", "shared")] + [(f"Нода {n['name']}", n["name"]) for n in d.get("nodes") or []]
    await ui.render(cb, f"<b>🚪 Выход: {esc(name)}</b>"
                        + ("\nВыбор переводит маршруты в режим «выбранные клиенты»: остальные остаются на "
                           "общем выходе." if route["mode"] != "peers" else ""),
                    ui.kb([(f"{'🔘' if cur == v else '⚪️'} {label}", ex.data("set", f"{name}|{v}")) for label, v in opts],
                          ui.back(ex.data("cl"))))


@ex("set")
async def _ex_set(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    name, _, value = arg.partition("|")
    r = await api.call("exits", "client", name, value)
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Выход клиента"), ui.kb(ui.back(ex.data("cl"))))
        return
    await _ex_pick(cb, state, name)


# ── Каскад портов ─────────────────────────────────────────
@cas()
async def cascade_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    rows = await api.data("cascade", "list", default=[]) or []
    lines = [f"{'🟢' if r['applied'] else '🔴'} {r['proto'].upper()} {r['in']} → {r['dst']}:{r['out']}"
             + (f" · {esc(r['comment'])}" if r.get("comment") else "") for r in rows]
    await ui.render(cb, "<b>🔀 Каскад портов</b>\nТрафик на порт этого сервера уходит на другой сервер.\n\n"
                        + ("\n".join(lines) + "\n\n🟢 применено · 🔴 записано, но в iptables нет" if rows
                           else "Правил нет."), ui.kb(
        ("➕ Добавить", cas.data("add")),
        ("➖ Удалить", cas.data("del")) if rows else None,
        ("🔁 Переприменить", cas.data("reapply")) if rows else None,
        ("🩺 Диагностика", cas.data("diag")),
        ("🧹 Удалить все", cas.data("clear")) if rows else None,
        ("🗑 Удалить каскад", cas.data("rm")),
        ui.back("tun")))


@cas("add")
async def _cas_add(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "<b>➕ Правило каскада</b>\nПротокол: UDP — для AWG и WireGuard.",
                    ui.kb(("UDP", cas.data("p", "udp")), ("TCP", cas.data("p", "tcp")),
                          ("UDP и TCP", cas.data("p", "both")), ui.back("cas", "✖️ Отмена")))


@cas("p")
async def _cas_proto(cb: CallbackQuery, state: FSMContext, proto: str) -> None:
    await ask.ask(cb, state, "cas_in", "Порт на этом сервере (1-65535):", "cas", proto=proto)


@ask.on("cas_in")
async def _cas_in(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not v.isdigit() or not 1 <= int(v) <= 65535:
        await ask.retry(msg, state, ctx, "Порт — число 1-65535")
        return
    await ask.ask(msg, state, "cas_dst", "Публичный IPv4 сервера назначения:", "cas", **ctx.data, port=v)


@ask.on("cas_dst")
async def _cas_dst(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not IP_RE.match(v):
        await ask.retry(msg, state, ctx, "Нужен IPv4, например 5.6.7.8")
        return
    await state.update_data(cascade=dict(ctx.data, dst=v))
    await ask.ask(msg, state, "cas_out", "Порт на сервере назначения:", "cas",
                  [(f"Тот же — {ctx['port']}", cas.data("out", ctx["port"]))], **ctx.data, dst=v)


@ask.on("cas_out")
async def _cas_out(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not v.isdigit() or not 1 <= int(v) <= 65535:
        await ask.retry(msg, state, ctx, "Порт — число 1-65535")
        return
    await _cas_comment(msg, state, dict(ctx.data, out=v))


@cas("out")
async def _cas_out_same(cb: CallbackQuery, state: FSMContext, port: str) -> None:
    rule = (await state.get_data()).get("cascade") or {}
    if not rule:
        await cascade_screen(cb, state)
        return
    await _cas_comment(cb, state, dict(rule, out=port))


async def _cas_comment(target: ui.Target, state: FSMContext, rule: dict) -> None:
    await state.update_data(cascade=rule)
    await ask.ask(target, state, "cas_cm", "Комментарий к правилу (например, имя сервера):", "cas",
                  [("Без комментария", cas.data("save"))], **rule)


@ask.on("cas_cm")
async def _cas_cm(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    await _cas_save(msg, state, dict(ctx.data, comment=ask.text_of(msg)[:60]))


@cas("save")
async def _cas_save_btn(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    rule = (await state.get_data()).get("cascade") or {}
    if not rule:
        await cascade_screen(cb, state)
        return
    await _cas_save(cb, state, rule)


async def _cas_save(target: ui.Target, state: FSMContext, rule: dict) -> None:
    await state.update_data(cascade={})
    args = ["cascade", "add", rule["proto"], rule["port"], rule["dst"], rule["out"]]
    if rule.get("comment"):
        args.append(rule["comment"])
    await quick(target, "Правило каскада", "cas", *args)


@cas("del")
async def _cas_del(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    rows = await api.data("cascade", "list", default=[]) or []
    await ui.render(cb, "<b>➖ Удалить правило</b>\n\n"
                        + "\n".join(f"{r['proto'].upper()} {r['in']} → {r['dst']}:{r['out']}" for r in rows),
                    ui.kb([(f"{r['proto'].upper()} {r['in']}", cas.data("delq", f"{r['proto']}|{r['in']}"))
                           for r in rows], ui.back("cas")))


@cas("delq")
async def _cas_del_ask(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    proto, _, port = arg.partition("|")
    await ui.confirm(cb, f"Удалить правило каскада {esc(proto.upper())} {esc(port)}?",
                     ("🗑 Удалить", cas.data("delok", arg)), cas.data("del"))


@cas("delok")
async def _cas_del_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    proto, _, port = arg.partition("|")
    await quick(cb, "Удаление правила", "cas", "cascade", "del", proto, port)


@cas("reapply")
async def _cas_reapply(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Переприменение правил", "cas", "cascade", "reapply")


@cas("diag")
async def _cas_diag(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("cascade", "diag")
    await ui.render(cb, "<b>🩺 Каскад</b>\n" + (ui.pre(r.log, 3500, tail=False) if r.ok else ui.fail(r)),
                    ui.kb(ui.back("cas")))


@cas("clear")
async def _cas_clear(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Удалить все правила каскада?", ("🧹 Удалить все", cas.data("clearok")), "cas")


@cas("clearok")
async def _cas_clear_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Удаление правил каскада", "cas", "cascade", "clear")


@cas("rm")
async def _cas_rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Удалить каскад полностью: правила и службу?", ("🗑 Удалить каскад", cas.data("rmok")), "cas")


@cas("rmok")
async def _cas_rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Удаление каскада", "tun", "cascade", "remove")


# ── Шифрованный DNS ───────────────────────────────────────
@dns()
async def dns_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    r = await api.call("dns", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "DNS"), ui.kb(ui.back("tun")))
        return
    d = r.data
    inst = d.get("installed")
    await ui.render(cb, "<b>🔐 Шифрованный DNS</b>\nЗапросы клиентов идут через dnscrypt-proxy по DoH, "
                        "DoT (853) закрыт.\n" + ui.pre(r.log, 1200, tail=False)
                        + ("" if inst else "\n<i>⚠️ Принудительно — если на сервере уже работает свой DNS "
                                           "(Pi-hole, Unbound, bind)</i>"), ui.kb(
        ("▶️ Включить", dns.data("install")) if not inst else None,
        ("⚠️ Принудительно", dns.data("force")) if not inst else None,
        ("🔄 Перезапустить", dns.data("restart")) if inst else None,
        ("🌐 Резолверы", dns.data("up")) if inst else None,
        ("📜 Журнал", "diag:log:dns|dns"),
        ("⏹ Выключить", dns.data("rm")) if inst else None,
        ui.back("tun")))


@dns("install")
async def _dns_install(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Шифрованный DNS", "dns", "install", back_to="dns")


@dns("force")
async def _dns_force(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Если на сервере работает свой DNS (Pi-hole, Unbound, bind), перехват уведёт клиентов "
                         "мимо него. Включить всё равно?",
                     ("⚠️ Включить", dns.data("forceok")), "dns")


@dns("forceok")
async def _dns_force_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Шифрованный DNS", "dns", "install", "force", back_to="dns")


@dns("restart")
async def _dns_restart(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Перезапуск DNS", "dns", "dns", "restart")


@dns("up")
async def _dns_upstream(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    d = await api.data("dns", "status", default={}) or {}
    presets = d.get("presets") or []
    await ui.remember(state, "dnsp", [p["names"] for p in presets])
    await ui.render(cb, f"<b>🌐 Резолверы</b>\nСейчас: <code>{esc(d.get('upstream') or '—')}</code>\n\n"
                        + "\n".join(f"• {esc(p['label'])}" for p in presets),
                    ui.kb([(p["label"].replace("Только ", "").split(" (")[0], dns.data("set", str(i)))
                           for i, p in enumerate(presets)],
                          ("✏️ Вручную", dns.data("manual")), ui.back("dns")))


@dns("set")
async def _dns_set(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    names = await ui.recall(state, "dnsp", idx)
    if names:
        await quick(cb, "Резолверы", "dns", "dns", "upstream", names)


@dns("manual")
async def _dns_manual(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "dns_names", "Имена резолверов через запятую — из списка "
                                          "<a href=\"https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/"
                                          "public-resolvers.md\">public-resolvers</a>.", "dns")


@ask.on("dns_names")
async def _dns_names(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not re.fullmatch(r"[A-Za-z0-9_, -]+", v):
        await ask.retry(msg, state, ctx, "Допустимы латиница, цифры, дефис и запятая")
        return
    await quick(msg, "Резолверы", "dns", "dns", "upstream", v)


@dns("rm")
async def _dns_rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "Выключить шифрованный DNS? Клиенты вернутся к DNS из своих конфигов.\n\n"
                        "<i>🗑 Удалить совсем — ещё и удалить dnscrypt-proxy</i>",
                    ui.kb(("⏹ Выключить", dns.data("rmok")), ("🗑 Удалить совсем", dns.data("rmok", "purge")),
                          ui.back("dns", "✖️ Отмена")))


@dns("rmok")
async def _dns_rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await quick(cb, "Выключение DNS", "tun", "dns", "remove", *([arg] if arg else []))
