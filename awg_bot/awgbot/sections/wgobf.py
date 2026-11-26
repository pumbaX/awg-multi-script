"""WG + обфускатор (wg-obfuscator, как Phobos): установка, клиенты и их
комплекты, настройки, удаление."""

from __future__ import annotations

import re
import time

from aiogram import Bot, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from .. import api, ask, instlink, jobs, media, share, store, ui, webapp
from ..ui import esc

router = Router()
act = ui.Actions(router, "wo")

NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
PRESET_RE = re.compile(r"^[A-Za-z0-9_]{1,16}$")
# Маскировка профиля: MEDIA — под видеопоток RTP (обфускатор Phobos), STUN — под
# видеозвонок, NONE — только XOR. У основного профиля — только STUN и NONE
MASKS = {"MEDIA": "под видеопоток (Phobos)", "STUN": "под видеозвонок", "NONE": "только XOR"}
# DNS клиентов — те же три, что в меню awg2; кнопка перебирает их по кругу
DNS = [("Cloudflare", "1.1.1.1, 1.0.0.1"), ("Google", "8.8.8.8, 8.8.4.4"), ("Quad9", "9.9.9.9, 149.112.112.112")]
# Выход клиентов: напрямую или через туннель (WARP, Xray — выход по умолчанию или
# свой, exit-ноды — общий выход или нода). Правила ставит тот же туннель, что у AWG;
# работает только поднятый, остальные — напрямую, пока их не включат.
TUN_NAME = {"warp": "WARP", "xray": "Xray", "exits": "exit-ноды"}


def route_label(r: str) -> str:
    kind, _, sub = (r or "direct").partition(":")
    if kind == "warp":
        return "через WARP"
    if kind == "xray":
        return f"через Xray: {sub}" if sub else "через Xray"
    if kind == "exits":
        return f"через exit-ноду {sub}" if sub else "через exit-ноды"
    return "напрямую"


def route_idle(r: str, d: dict) -> str:
    """« — WARP выключен, пока напрямую», если туннель маршрута не работает."""
    kind = (r or "direct").partition(":")[0]
    st = d.get(kind) or "none"
    if kind not in TUN_NAME or st == "up":
        return ""
    if kind == "exits":
        return " — exit-ноды выключены, пока напрямую" if st == "off" else " — exit-нод нет, пока напрямую"
    return f" — {TUN_NAME[kind]} {'выключен' if st == 'off' else 'не настроен'}, пока напрямую"


def route_options(d: dict) -> list[tuple[str, str, str]]:
    """(код кнопки, маршрут, подпись) из настроенных туннелей. Код — номер
    выхода или ноды в списке: тег в 64 байта колбэка не всегда влезет."""
    opts = [("d", "direct", "Напрямую")]
    if (d.get("warp") or "none") != "none":
        opts.append(("w", "warp", "Через WARP"))
    if (d.get("xray") or "none") != "none":
        opts.append(("x", "xray", "Xray: по умолчанию"))
        opts += [(f"x{i}", f"xray:{t}", f"Xray: {t}") for i, t in enumerate(d.get("xray_tags") or [])]
    nodes = d.get("exit_nodes") or []
    if (d.get("exits") or "none") != "none":
        opts.append(("e", "exits", "Exit-ноды: общий"))
        if len(nodes) > 1:
            opts += [(f"e{i}", f"exits:{n}", f"Нода {n}") for i, n in enumerate(nodes)]
    return opts


def active_tunnel(d: dict) -> str:
    return next((TUN_NAME[k] for k in ("warp", "xray", "exits") if d.get(k) == "up"), "")


def preset_label(p: str) -> str:
    return "основной" if p == "main" else p


def preset_line(p: dict) -> str:
    s = f"{p.get('port')}/udp · {p.get('masking')}"
    if p.get("obfb"):
        s += f" · obfuscate-bytes {p['obfb']}"
    return s + f" · max-dummy {p.get('dummy')} · idle {p.get('idle')} с"


async def _status() -> dict:
    return await api.data("wgobf", "status", default={}) or {}


async def _bundle_data(bot: Bot, chat_id: int, name: str) -> dict | None:
    r = await api.call("wgobf", "bundle", name)
    if not r.ok or not isinstance(r.data, dict):
        await ui.show_new(bot, chat_id, ui.fail(r, f"Клиент {name}"), ui.kb(ui.back("wo")))
        return None
    return r.data


async def send_bundle(bot: Bot, chat_id: int, name: str) -> None:
    """Ссылка phobos:// и конфиг текстом, затем тот же конфиг одним файлом
    <имя>.conf: WireGuard и секция [instance] обфускатора (формат Phobos) —
    Keenetic (AWG Manager → «Phobos») берёт его одной вставкой."""
    d = await _bundle_data(bot, chat_id, name)
    if d is None:
        return
    paths = {f["name"]: f["path"] for f in d.get("files") or []}
    try:
        with open(paths.get("phobos.conf", ""), encoding="utf-8") as f:
            conf = f.read().strip()
    except OSError:
        conf = ""
    link = (d.get("phobos") or "").strip()
    head = f"🛡 <b>{esc(name)}</b> — WG + обфускатор\n"
    parts = []
    if link:
        parts.append(f"\n<b>Ссылка</b> — Keenetic, AWG Manager → Новый туннель → «Phobos» → <b>нижнее</b> поле "
                     "«Или конфиг .conf … / ссылка phobos://». Верхнее «Ссылка установки Phobos» — пустым: оно "
                     f"только для http(s)-ссылок панели Phobos.\n<code>{esc(link)}</code>\n")
    if conf:
        parts.append(f"\n<b>Конфиг</b> — WireGuard и [instance] обфускатора, как в файле ниже:\n<pre>{esc(conf)}</pre>")
    text = head + "".join(parts)
    if len(text) <= ui.TEXT_MAX:
        await bot.send_message(chat_id, text)
    else:                                               # длинный список AllowedIPs
        for part in parts:
            if len(head + part) <= ui.TEXT_MAX:
                await bot.send_message(chat_id, head + part)
    if conf:
        await bot.send_document(
            chat_id, BufferedInputFile((conf + "\n").encode(), filename=f"{name}.conf"),
            caption=f"📄 <b>{esc(name)}.conf</b> — всё в одном файле: WireGuard + обфускатор.\n"
                    "Linux, Windows, Android — «📦 Архив» в карточке клиента: wg.conf, obfuscator.conf "
                    "и установщик.")


async def send_archive(bot: Bot, chat_id: int, name: str) -> None:
    """Всё по отдельности: wg.conf + obfuscator.conf, установщик для Linux,
    инструкция — для устройств, где обфускатор ставят рядом с WireGuard."""
    d = await _bundle_data(bot, chat_id, name)
    if d is None:
        return
    files = [f["path"] for f in d.get("files") or []]
    await bot.send_document(chat_id, BufferedInputFile(media.zip_files(files), filename=f"wgobf-{name}.zip"),
                            caption=f"📦 <b>{esc(name)}</b>: wg.conf + obfuscator.conf, установщик для Linux, "
                                    "инструкция (README.txt)")


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    r = await api.call("wgobf", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "WG + обфускатор"), ui.kb(ui.back()))
        return
    d = r.data
    if not d.get("installed"):
        await ui.render(cb, f"<b>🛡 WG + обфускатор</b> (wg-obfuscator {esc(d.get('version', ''))})\n\n"
                            "Отдельный WireGuard за обфускатором — как Phobos. AWG не трогает. Клиентам нужен "
                            "wg-obfuscator рядом с WireGuard (роутер Keenetic, Linux) — комплект это описывает.",
                        ui.kb(("📦 Установить", act.data("install")), ui.back()))
        return
    mask = "NONE" if d.get("masking") == "STUN" else "STUN"
    route = d.get("route") or "direct"
    rline = f"🌐 Выход клиентов: <b>{esc(route_label(route))}</b>{route_idle(route, d)}"
    np = len(d.get("presets") or [])
    await ui.render(cb, "<b>🛡 WG + обфускатор</b>\n" + ui.pre(r.log, 1500, tail=False) + f"\n{rline}\n"
                    + f"\n<i>🎭 — маскировка клиентов основного профиля: {esc(d.get('masking') or '?')} → {mask}\n"
                      "🎛 Профили — свои порты и маскировка, в том числе MEDIA (под видеопоток)\n"
                      "Чистый WG — пускать и обычный WireGuard без обфускатора (iOS); его DPI видит\n"
                      "IPv6 — клиентам адрес IPv6 и выход в IPv6 через сервер\n"
                      "🌐 — выход всех клиентов (и новых): напрямую или через туннель; своему — в карточке</i>", ui.kb(
        ("➕ Добавить", act.data("add")),
        ("👥 Клиенты", act.data("list")),
        (f"🎛 Профили ({np})", act.data("pl")),
        ("🌐 Выход клиентов", act.data("rt", "*")),
        (f"🎭 → {mask}", act.data("mask", mask)),
        (f"{'✅' if d.get('clean') else '⬜️'} Чистый WG", act.data("clean", "0" if d.get("clean") else "1")),
        (f"{'✅' if d.get('ipv6') else '⬜️'} IPv6", act.data("v6", "off" if d.get("ipv6") else "on")),
        ("🔄 Перезапустить", act.data("restart")),
        ("🔑 Сменить ключ", act.data("key")),
        ("📜 Журнал", "diag:log:wgobf|wo"),
        ("🗑 Удалить", act.data("rm")),
        ui.back()))


# ── Установка ─────────────────────────────────────────────
async def _install_screen(target: ui.Target, state: FSMContext) -> None:
    o = (await state.get_data()).get("wgobf") or {}
    dns = DNS[int(o.get("dns") or 0) % len(DNS)]
    await ui.render(target, "<b>📦 Установка WG + обфускатор</b>\n\n"
                            f"Порт: {esc(o.get('port') or 'случайный')}\n"
                            f"Маскировка у клиентов: {o.get('masking', 'STUN')}\n"
                            f"Клиенты без обфускатора: {'да' if o.get('clean') == '1' else 'нет'}\n"
                            f"DNS клиентов: {dns[0]} ({dns[1]})\n"
                            f"Первый клиент: {esc(o.get('client') or 'client1')}\n\n"
                            "<i>🎭 STUN — под видеозвонок (рекомендуется), NONE — только XOR\n"
                            "Чистый WG — пускать и обычный WireGuard без обфускатора (iOS); его DPI видит</i>",
                    ui.kb(("✏️ Порт", act.data("iport")),
                          ("✏️ Первый клиент", act.data("iname")),
                          ("🎭 STUN ↔ NONE", act.data("iopt", "masking")),
                          (f"{'✅' if o.get('clean') == '1' else '⬜️'} Чистый WG", act.data("iopt", "clean")),
                          (f"🌐 {dns[0]}", act.data("iopt", "dns")),
                          ui.Row(("✅ Установить", act.data("igo")), ui.back("wo", "✖️ Отмена"))))


@act("install")
async def _install(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await state.update_data(wgobf={})
    await _install_screen(cb, state)


@act("iopt")
async def _install_opt(cb: CallbackQuery, state: FSMContext, key: str) -> None:
    o = dict((await state.get_data()).get("wgobf") or {})
    if key == "masking":
        o["masking"] = "NONE" if o.get("masking", "STUN") == "STUN" else "STUN"
    elif key == "clean":
        o["clean"] = "0" if o.get("clean") == "1" else "1"
    elif key == "dns":
        o["dns"] = str((int(o.get("dns") or 0) + 1) % len(DNS))
    await state.update_data(wgobf=o)
    await _install_screen(cb, state)


@act("iport")
async def _install_port(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "wo_port", "UDP-порт обфускатора: 443 или 1024-65535", "wo")


@ask.on("wo_port")
async def _install_port_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not ui.awg_port_ok(v):
        await ask.retry(msg, state, ctx, "Порт — 443 или число 1024-65535")
        return
    o = dict((await state.get_data()).get("wgobf") or {}, port=str(int(v)))
    await state.update_data(wgobf=o)
    await _install_screen(msg, state)


@act("iname")
async def _install_name(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "wo_iname", "Имя первого клиента: латиница, цифры, _ и -, до 32.", "wo")


@ask.on("wo_iname")
async def _install_name_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not NAME_RE.match(v):
        await ask.retry(msg, state, ctx, "Имя: латиница, цифры, _ и -, до 32 символов")
        return
    o = dict((await state.get_data()).get("wgobf") or {}, client=v)
    await state.update_data(wgobf=o)
    await _install_screen(msg, state)


@act("igo")
async def _install_go(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    o = (await state.get_data()).get("wgobf") or {}
    await state.update_data(wgobf={})
    name = o.get("client") or "client1"
    args = [f"masking={o.get('masking', 'STUN')}", f"clean={o.get('clean', '0')}", f"client={name}",
            f"dns={DNS[int(o.get('dns') or 0) % len(DNS)][1]}"]
    if o.get("port"):
        args.append(f"port={o['port']}")

    async def done(bot: Bot, chat_id: int, st: dict) -> None:
        await send_bundle(bot, chat_id, name)

    await jobs.start(cb, "Установка WG + обфускатор", "wgobf", "install", *args, back_to="wo", done=done)


# ── Клиенты ───────────────────────────────────────────────
@act("add")
async def _add(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "wo_add", "Имя клиента: латиница, цифры, _ и -, до 32.", "wo")


@ask.on("wo_add")
async def _add_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    name = ask.text_of(msg)
    if not NAME_RE.match(name):
        await ask.retry(msg, state, ctx, "Имя: латиница, цифры, _ и -, до 32 символов")
        return
    r = await api.call("wgobf", "add", name)
    if not r.ok:
        await ask.retry(msg, state, ctx, r.message)
        return
    await ui.render(msg, f"✅ Клиент <b>{esc(name)}</b> добавлен — ссылка и конфиг ниже.",
                    ui.kb(("👤 Карточка", act.data("v", name)), ("👥 Клиенты", act.data("list")), ui.back("wo")))
    await send_bundle(msg.bot, msg.chat.id, name)  # type: ignore[arg-type]


@act("list")
async def _list(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    rows = await api.data("wgobf", "clients", default=[]) or []
    page = int(arg) if arg.isdigit() else 0
    def dot(r: dict) -> str:
        return "🟢" if r.get("ago") is not None and r["ago"] < 180 else "⚪️"

    # Текст — те же клиенты, что и кнопки этой страницы (страница — как у ui.paged)
    pages = max(1, (len(rows) + 19) // 20)
    page = min(page, pages - 1)
    lines = [f"{dot(r)} <b>{esc(r['name'])}</b> <code>{esc(r['ip'])}</code>"
             + (f" · {ui.fmt_dur(r['ago'])} назад" if r.get("ago") is not None else "")
             + (f" · 🎛 {esc(r['preset'])}" if (r.get("preset") or "main") != "main" else "")
             + (f" · 🌐 {esc(route_label(r['route']))}" if (r.get("route") or "direct") != "direct" else "")
             for r in rows[page * 20:(page + 1) * 20]]
    await ui.render(cb, "<b>👥 Клиенты WG + обфускатор</b>"
                        + (f" · стр. {page + 1} из {pages}" if pages > 1 else "") + "\n\n"
                        + ("\n".join(lines) or "Клиентов нет."),
                    ui.kb(ui.paged([(f"{dot(r)} {r['name']}", act.data("v", r["name"])) for r in rows],
                                   page, lambda p: act.data("list", str(p))),
                          ui.back("wo")))


@act("v")
async def _view(cb: ui.Target, state: FSMContext, name: str) -> None:
    rows = await api.data("wgobf", "clients", default=[]) or []
    c = next((r for r in rows if r["name"] == name), None)
    if c is None:
        await ui.render(cb, f"Клиента <b>{esc(name)}</b> нет.", ui.kb(ui.back(act.data("list"))))
        return
    ago = c.get("ago")
    seen = ("не подключался" if ago is None
            else f"🟢 онлайн ({ui.fmt_dur(ago)} назад)" if ago < 180 else f"был {ui.fmt_dur(ago)} назад")
    mon = store.monitored(store.WGOBF + name)
    preset = c.get("preset") or "main"
    await ui.render(cb, f"<b>🛡 {esc(name)}</b> — WG + обфускатор\n\nIP: <code>{esc(c['ip'])}</code>"
                        + (f", <code>{esc(c['ip6'])}</code>" if c.get("ip6") else "") + "\n"
                        f"Статус: {seen}\n"
                        f"Трафик с запуска: ↓ {ui.fmt_bytes(c.get('rx'))} · ↑ {ui.fmt_bytes(c.get('tx'))}\n"
                        f"Профиль: {esc(preset_label(preset))}\n"
                        f"Выход: {esc(route_label(c.get('route') or 'direct'))}\n"
                        f"Мониторинг: {'🔔 вкл' if mon else '🔕 выкл'}\n\n"
                        "<i>📄 Конфиг — ссылка и конфиг текстом, плюс один файл .conf со всеми данными\n"
                        "📦 Архив — wg.conf, obfuscator.conf и установщик для Linux\n"
                        "🔗 Ссылка установки — одноразовая, для AWG Manager на Keenetic\n"
                        "🔔 Мониторинг — сообщу, когда клиент пропал (5 минут без связи) и вернулся</i>",
                    ui.kb(("📄 Конфиг", act.data("bundle", name)),
                          ("📦 Архив", act.data("zip", name)),
                          ("🔗 Ссылка установки", act.data("il", name)),
                          ("🎛 Профиль", act.data("cp", name)),
                          ("🔕 Выключить мониторинг" if mon else "🔔 Мониторинг", act.data("mon", name)),
                          ("🌐 Маршрут", act.data("rt", name)),
                          ("✏️ Переименовать", act.data("ren", name)),
                          ("🗑 Удалить", act.data("del", name)),
                          ui.back(act.data("list"))))


@act("ren")
async def _ren(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ask.ask(cb, state, "wo_ren", f"Новое имя для <b>{esc(name)}</b>\n<i>латиница, цифры, _ и -, до 32</i>",
                  act.data("v", name), old=name)


@ask.on("wo_ren")
async def _ren_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    new = ask.text_of(msg)
    if not NAME_RE.match(new):
        await ask.retry(msg, state, ctx, "Имя: латиница, цифры, _ и -, до 32 символов")
        return
    r = await api.call("wgobf", "rename", ctx["old"], new)
    if not r.ok:
        await ask.retry(msg, state, ctx, r.message)
        return
    # Мониторинг клиента записан под его именем — переезжает вместе с ним
    store.rename_note(store.WGOBF + ctx["old"], store.WGOBF + new)
    await _view(msg, state, new)


@act("mon")
async def _mon(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    if not NAME_RE.match(name):
        await cb.answer("Кнопка устарела — открой клиента заново", show_alert=True)
        return
    on = not store.monitored(store.WGOBF + name)
    store.set_monitored(store.WGOBF + name, on)
    await cb.answer("🔔 Мониторинг включён" if on else "🔕 Мониторинг выключен")
    await _view(cb, state, name)


@act("bundle")
async def _bundle(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await cb.answer("Отправляю…")
    await send_bundle(cb.bot, ui.chat_of(cb).chat.id, name)  # type: ignore[arg-type]


@act("zip")
async def _zip(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await cb.answer("Отправляю…")
    await send_archive(cb.bot, ui.chat_of(cb).chat.id, name)  # type: ignore[arg-type]


@act("del")
async def _del(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ui.confirm(cb, f"Удалить клиента <b>{esc(name)}</b>?", ("🗑 Удалить", act.data("delok", name)),
                     act.data("v", name))


@act("delok")
async def _del_ok(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    r = await api.call("wgobf", "del", name)
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Удаление"), ui.kb(ui.back(act.data("list"))))
        return
    await _list(cb, state, "")


# ── Настройки ─────────────────────────────────────────────
async def _quick(cb: CallbackQuery, title: str, *args: str) -> None:
    await ui.render(cb, f"⏳ {esc(title)}…")
    await ui.result(cb, await api.call(*args), title, "wo")


@act("restart")
async def _restart(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await _quick(cb, "Перезапуск", "wgobf", "restart")


# ── Выход клиентов ────────────────────────────────────────
# «*» — все клиенты и новые по умолчанию, иначе имя клиента
@act("rt")
async def _rt(cb: CallbackQuery, state: FSMContext, who: str) -> None:
    back_to = "wo" if who == "*" else act.data("v", who)
    if who != "*" and not NAME_RE.match(who):
        await cb.answer("Кнопка устарела — открой раздел заново", show_alert=True)
        return
    d = await api.data("wgobf", "status", default={}) or {}
    if who == "*":
        cur, title = d.get("route") or "direct", "все клиенты обфускатора (и новые)"
    else:
        rows = await api.data("wgobf", "clients", default=[]) or []
        c = next((r for r in rows if r.get("name") == who), None)
        if c is None:
            await ui.render(cb, f"Клиента <b>{esc(who)}</b> нет.", ui.kb(ui.back(act.data("list"))))
            return
        cur, title = c.get("route") or "direct", esc(who)
    tun = active_tunnel(d)
    buttons = [(f"{'🔘' if route == cur else '⚪️'} {label}", act.data("rs", f"{who}|{code}"))
               for code, route, label in route_options(d)]
    kind = cur.partition(":")[0]
    if kind in TUN_NAME and d.get(kind) == "off":       # туннель выхода выключен — включить отсюда
        buttons.append((f"▶️ Включить {TUN_NAME[kind]}", act.data("ton", who)))
    await ui.render(cb, f"<b>🌐 Выход: {title}</b>\n\nСейчас: <b>{esc(route_label(cur))}</b>{route_idle(cur, d)}\n"
                        + (f"Работает туннель: {tun}.\n" if tun else "Туннели выключены — все идут напрямую.\n")
                        + "\n<i>Одновременно работает один туннель: клиенты другого идут напрямую, "
                          "пока его не включат. Здесь — туннели, которые настроены.</i>",
                    ui.kb(buttons, ui.back(back_to)))


@act("rs")
async def _rs(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    who, _, code = arg.partition("|")
    route = next((r for c, r, _ in route_options(await api.data("wgobf", "status", default={}) or {}) if c == code), None)
    if route is None or (who != "*" and not NAME_RE.match(who)):
        await _rt(cb, state, who)            # выходы поменялись — экран заново
        return
    if route.startswith("xray"):
        await cb.answer("Перенастраиваю Xray…")
    r = await api.call("wgobf", "route", "all" if who == "*" else who, route)
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Выход клиентов"), ui.kb(ui.back(act.data("rt", who))))
        return
    await _rt(cb, state, who)


# Включить туннель выхода из экрана выхода. Одновременно работает один туннель:
# другой — с подтверждением выключается (как на экране «Туннели»)
TUN_DOWN = {"warp": ("warp", "down"), "xray": ("xray", "down"), "tun2socks": ("t2s", "down"), "exits": ("exits", "down")}
TUN_ANY = {**TUN_NAME, "tun2socks": "tun2socks"}


async def _route_kind(who: str) -> str:
    """Туннель текущего выхода (warp | xray | exits), если он настроен и выключен."""
    d = await api.data("wgobf", "status", default={}) or {}
    if who == "*":
        cur = d.get("route") or "direct"
    else:
        rows = await api.data("wgobf", "clients", default=[]) or []
        cur = next((r.get("route") or "direct" for r in rows if r.get("name") == who), "direct")
    kind = cur.partition(":")[0]
    return kind if kind in TUN_NAME and d.get(kind) == "off" else ""


async def _tun_plan(kind: str) -> tuple[list[str], str]:
    """(работающие другие туннели, режим exit-нод)."""
    t = await api.data("tunnels", "status", default={}) or {}
    mode = ""
    if kind == "exits":
        e = await api.data("exits", "status", default={}) or {}
        mode = "peers" if e.get("mode") == "peers" else "all"
    return [k for k in TUN_DOWN if k != kind and t.get(k) == "up"], mode


async def _tun_start(cb: CallbackQuery, kind: str, mode: str, back: str) -> None:
    if kind == "exits":
        await jobs.start(cb, "Маршруты через exit-ноды", "exits", "up", mode, back_to=back)
    else:
        await jobs.start(cb, f"Включение {TUN_NAME[kind]}", kind, "up", back_to=back)


@act("ton")
async def _ton(cb: CallbackQuery, state: FSMContext, who: str) -> None:
    back = act.data("rt", who)
    if who != "*" and not NAME_RE.match(who):
        await cb.answer("Кнопка устарела — открой раздел заново", show_alert=True)
        return
    kind = await _route_kind(who)
    if not kind:
        await _rt(cb, state, who)            # туннель уже работает или выход сменили
        return
    other, mode = await _tun_plan(kind)
    note = " Режим exit-нод «все клиенты»: через них пойдут и клиенты AWG." if mode == "all" else ""
    if not other and not note:
        await _tun_start(cb, kind, mode, back)
        return
    names = ", ".join(TUN_ANY[k] for k in other)
    text = (f"Сейчас работает <b>{esc(names)}</b>, а одновременно — только один туннель. Выключить его и включить "
            f"<b>{TUN_NAME[kind]}</b>? Кто идёт через {esc(names)}, пойдёт напрямую, пока его не включат."
            if other else f"Включить <b>{TUN_NAME[kind]}</b>?") + note
    await ui.confirm(cb, text, ("✅ " + ("Переключить" if other else "Включить"), act.data("tsw", who)), back)


@act("tsw")
async def _tsw(cb: CallbackQuery, state: FSMContext, who: str) -> None:
    back = act.data("rt", who)
    kind = await _route_kind(who) if who == "*" or NAME_RE.match(who) else ""
    if not kind:
        await _rt(cb, state, who)
        return
    other, mode = await _tun_plan(kind)
    for k in other:
        await ui.render(cb, f"⏳ Выключаю {esc(TUN_ANY[k])}…")
        r = await api.call(*TUN_DOWN[k])
        if not r.ok:
            await ui.render(cb, ui.fail(r, f"Выключение {TUN_ANY[k]}"), ui.kb(ui.back(back)))
            return
    await _tun_start(cb, kind, mode, back)


@act("mask")
async def _mask(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    await _quick(cb, f"Маскировка {v}", "wgobf", "masking", v)


@act("clean")
async def _clean(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    await _quick(cb, "Клиенты без обфускатора", "wgobf", "clean", v)


@act("key")
async def _key(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Сменить ключ основного профиля? Его клиенты отключатся, пока не получат новый комплект "
                         "(у других профилей — свои ключи).",
                     ("🔑 Сменить ключ", act.data("keyok")), "wo")


@act("keyok")
async def _key_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await _quick(cb, "Смена ключа", "wgobf", "rotate-key")


@act("rm")
async def _rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Удалить WG + обфускатор со всеми его клиентами? AWG не затрагивается; архив "
                         "на всякий случай ляжет в ~/awg_backup.",
                     ("🗑 Удалить", act.data("rmok")), "wo")


@act("rmok")
async def _rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await _quick(cb, "Удаление WG + обфускатор", "wgobf", "remove")


# ── Профили обфускации ────────────────────────────────────
@act("pl")
async def _presets(cb: ui.Target, state: FSMContext, arg: str = "") -> None:
    d = await _status()
    ps = [p for p in d.get("presets") or [] if isinstance(p, dict)]
    lines = [f"{'🟢' if p.get('running') else '🔴'} <b>{esc(preset_label(p['name']))}</b>"
             + (" ⭐" if p["name"] == d.get("default") else "")
             + f" — {esc(preset_line(p))}, клиентов: {p.get('clients') or 0}" for p in ps]
    await ui.render(cb, "<b>🎛 Профили обфускации</b>\n\n" + ("\n".join(lines) or "Нет данных.")
                    + "\n\n<i>Профиль — свой порт, ключ и маскировка; все ведут в тот же WireGuard. Клиенту профиль "
                      "задаёт его комплект — в карточке клиента. ⭐ — профиль новых клиентов.\n"
                      "MEDIA — маскировка под видеопоток: обфускатор Phobos (форк wg-obfuscator); на Keenetic — "
                      "вкладка «Phobos» в AWG Manager.</i>",
                    ui.kb([(f"{'🟢' if p.get('running') else '🔴'} {preset_label(p['name'])}", act.data("pv", p["name"]))
                           for p in ps],
                          ("➕ Новый профиль", act.data("pa")), ui.back("wo")))


@act("pv")
async def _preset_view(cb: ui.Target, state: FSMContext, name: str) -> None:
    d = await _status()
    p = next((x for x in d.get("presets") or [] if isinstance(x, dict) and x.get("name") == name), None)
    if p is None:
        await ui.render(cb, f"Профиля <b>{esc(name)}</b> нет.", ui.kb(ui.back(act.data("pl"))))
        return
    main = name == "main"
    eng = "ClusterM (wg-obfuscator)" if p.get("engine") == "clusterm" else f"Phobos {esc(d.get('ph_version') or '')}"
    ufw = {"open": "открыт", "closed": "⚠️ закрыт — Сервер → Проверить и починить"}.get(p.get("ufw") or "", "")
    masks = ["STUN", "NONE"] if main else ["MEDIA", "STUN", "NONE"]
    await ui.render(cb, f"<b>🎛 Профиль {esc(preset_label(name))}</b>"
                        + (" ⭐ для новых клиентов" if d.get("default") == name else "") + "\n\n"
                        f"Служба: {'🟢 работает' if p.get('running') else '🔴 не работает'}\n"
                        f"Вход: <code>{esc((d.get('endpoint') or '').rsplit(':', 1)[0])}:{p.get('port')}</code>/udp"
                        + (f", UFW: {ufw}" if ufw else "") + "\n"
                        f"Маскировка: <b>{esc(p.get('masking') or '?')}</b> — {MASKS.get(p.get('masking') or '', '')}\n"
                        f"obfuscate-bytes: {p.get('obfb') or 'весь пакет'}\n"
                        f"max-dummy: {p.get('dummy')} · idle-timeout: {p.get('idle')} с\n"
                        f"Обфускатор: {eng}\nКлиентов: {p.get('clients') or 0}\n\n"
                        "<i>🎭 — маскировка; у основного сервер понимает обе, у остальных смена ломает прежние "
                        "комплекты профиля\n"
                        "max-dummy — до скольки байт мусора в пакет; idle-timeout — через сколько секунд тишины "
                        "забыть клиента: их смена прежние комплекты не ломает\n"
                        "obfuscate-bytes — шифровать только начало пакета (быстрее на слабых роутерах)</i>",
                    ui.kb([(f"🎭 {m}", act.data("pm", f"{name}|{m}")) for m in masks if m != p.get("masking")],
                          ("✏️ max-dummy", act.data("pd", name)),
                          ("✏️ idle-timeout", act.data("pi", name)),
                          None if main else ("✏️ obfuscate-bytes", act.data("pob", name)),
                          None if d.get("default") == name else ("⭐ Для новых", act.data("pdef", name)),
                          ("🔑 Сменить ключ", act.data("pk", name)),
                          None if main else ("🗑 Удалить", act.data("pdel", name)),
                          ui.back(act.data("pl"))))


def _preset_ok(name: str) -> list[ui.Button]:
    """Кнопка итога задачи — на экран профиля."""
    return [(f"🎛 Профиль {preset_label(name)}", act.data("pv", name))]


@act("pa")
async def _preset_add(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "wo_pname", "Имя нового профиля: латиница, цифры и _, до 16 (например <code>media</code>).",
                  act.data("pl"))


@ask.on("wo_pname")
async def _preset_add_name(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    name = ask.text_of(msg)
    if not PRESET_RE.match(name) or name in ("main", "all"):
        await ask.retry(msg, state, ctx, "Имя: латиница, цифры и _, до 16; main и all заняты")
        return
    d = await _status()
    if any(isinstance(p, dict) and p.get("name") == name for p in d.get("presets") or []):
        await ask.retry(msg, state, ctx, f"Профиль {name} уже есть")
        return
    await ui.render(msg, f"<b>🎛 Новый профиль {esc(name)}</b>\n\nМаскировка:\n"
                         "• <b>MEDIA</b> — под видеопоток RTP (обфускатор Phobos; первый раз сервер соберёт его — "
                         "это минута-две)\n• <b>STUN</b> — под видеозвонок\n• <b>NONE</b> — только XOR\n\n"
                         "<i>Порт — случайный свободный; свой — командой awg2 --wgobf preset add.</i>",
                    ui.kb(*[(f"🎭 {m}", act.data("pam", f"{name}|{m}")) for m in MASKS], ui.back(act.data("pl"), "✖️ Отмена")))


@act("pam")
async def _preset_add_go(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    name, _, mask = arg.partition("|")
    if not PRESET_RE.match(name) or mask not in MASKS:
        await cb.answer("Кнопка устарела — открой профили заново", show_alert=True)
        return
    await jobs.start(cb, f"Профиль {name}", "wgobf", "preset", "add", name, f"masking={mask}",
                     back_to=act.data("pl"), ok_buttons=_preset_ok(name))


@act("pm")
async def _preset_mask(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    name, _, mask = arg.partition("|")
    if not (name == "main" or PRESET_RE.match(name)) or mask not in MASKS:
        await cb.answer("Кнопка устарела — открой профиль заново", show_alert=True)
        return
    # MEDIA впервые — сборка обфускатора Phobos: задачей, с журналом
    await jobs.start(cb, f"Профиль {preset_label(name)}: {mask}", "wgobf", "preset", "set", name, f"masking={mask}",
                     back_to=act.data("pv", name), ok_buttons=_preset_ok(name))


_NUM_ASK = {"pd": ("dummy", "max-dummy: 0-1024 байт (по умолчанию 4)"),
            "pi": ("idle", "idle-timeout: 10-86400 секунд (по умолчанию 300)"),
            "pob": ("obfb", "obfuscate-bytes: 0 — весь пакет (у MEDIA — 16), или 4-1500")}


async def _num_ask(cb: CallbackQuery, state: FSMContext, name: str, code: str) -> None:
    if not (name == "main" or PRESET_RE.match(name)):
        await cb.answer("Кнопка устарела — открой профиль заново", show_alert=True)
        return
    field, prompt = _NUM_ASK[code]
    await ask.ask(cb, state, "wo_pnum", f"Профиль <b>{esc(preset_label(name))}</b> — {prompt}", act.data("pv", name),
                  preset=name, field=field)


@act("pd")
async def _preset_dummy(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await _num_ask(cb, state, name, "pd")


@act("pi")
async def _preset_idle(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await _num_ask(cb, state, name, "pi")


@act("pob")
async def _preset_obfb(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await _num_ask(cb, state, name, "pob")


@ask.on("wo_pnum")
async def _preset_num_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not re.fullmatch(r"0|[1-9][0-9]{0,4}", v):
        await ask.retry(msg, state, ctx, "Нужно целое число без ведущих нулей")
        return
    name, key = ctx["preset"], ctx["field"]
    if key == "obfb":
        # Профиль может перейти на обфускатор Phobos (сборка) — задачей
        await jobs.start(msg, f"Профиль {preset_label(name)}: obfuscate-bytes {v}", "wgobf", "preset", "set", name,
                         f"obfb={v}", back_to=act.data("pv", name), ok_buttons=_preset_ok(name))
        return
    r = await api.call("wgobf", "preset", "set", name, f"{key}={v}")
    if not r.ok:
        await ask.retry(msg, state, ctx, r.message)
        return
    await _preset_view(msg, state, name)


@act("pdef")
async def _preset_default(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    r = await api.call("wgobf", "preset", "default", name)
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Профиль новых клиентов"), ui.kb(ui.back(act.data("pv", name))))
        return
    await cb.answer(f"Новые клиенты: {preset_label(name)}")
    await _preset_view(cb, state, name)


@act("pk")
async def _preset_key(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ui.confirm(cb, f"Сменить ключ профиля <b>{esc(preset_label(name))}</b>? Его клиенты отключатся, пока "
                         "не получат новый комплект.", ("🔑 Сменить", act.data("pkok", name)), act.data("pv", name))


@act("pkok")
async def _preset_key_ok(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ui.render(cb, "⏳ Смена ключа…")
    await ui.result(cb, await api.call("wgobf", "preset", "key", name), "Смена ключа", act.data("pv", name))


@act("pdel")
async def _preset_del(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ui.confirm(cb, f"Удалить профиль <b>{esc(name)}</b>? Его клиенты перейдут на основной, их прежние "
                         "комплекты перестанут работать.", ("🗑 Удалить", act.data("pdelok", name)), act.data("pv", name))


@act("pdelok")
async def _preset_del_ok(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ui.render(cb, "⏳ Удаление профиля…")
    await ui.result(cb, await api.call("wgobf", "preset", "del", name), "Удаление профиля", act.data("pl"))


# Профиль клиента: кнопка — номер профиля в списке (имя профиля и клиента в 64 байта не всегда влезут)
@act("cp")
async def _client_preset(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    if not NAME_RE.match(name):
        await cb.answer("Кнопка устарела — открой клиента заново", show_alert=True)
        return
    d = await _status()
    rows = await api.data("wgobf", "clients", default=[]) or []
    c = next((r for r in rows if r.get("name") == name), None)
    if c is None:
        await ui.render(cb, f"Клиента <b>{esc(name)}</b> нет.", ui.kb(ui.back(act.data("list"))))
        return
    cur = c.get("preset") or "main"
    ps = [p for p in d.get("presets") or [] if isinstance(p, dict)]
    await ui.render(cb, f"<b>🎛 Профиль клиента {esc(name)}</b>\n\nСейчас: <b>{esc(preset_label(cur))}</b>\n\n"
                        + "\n".join(f"• <b>{esc(preset_label(p['name']))}</b> — {esc(preset_line(p))}" for p in ps)
                        + "\n\n<i>Клиент получит новый комплект; прежний работает, пока есть его профиль.</i>",
                    ui.kb([(f"{'🔘' if p['name'] == cur else '⚪️'} {preset_label(p['name'])}",
                            act.data("cps", f"{name}|{i}")) for i, p in enumerate(ps)],
                          ui.back(act.data("v", name))))


@act("cps")
async def _client_preset_set(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    name, _, idx = arg.partition("|")
    ps = [p for p in (await _status()).get("presets") or [] if isinstance(p, dict)]
    if not NAME_RE.match(name) or not idx.isdigit() or int(idx) >= len(ps):
        await cb.answer("Кнопка устарела — открой клиента заново", show_alert=True)
        return
    preset = ps[int(idx)]["name"]
    r = await api.call("wgobf", "assign", name, preset)
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Профиль клиента"), ui.kb(ui.back(act.data("v", name))))
        return
    await cb.answer(f"Профиль {preset_label(preset)} — новый комплект готов")
    await _view(cb, state, name)


# ── IPv6 в туннеле ────────────────────────────────────────
@act("v6")
async def _v6(cb: CallbackQuery, state: FSMContext, want: str) -> None:
    if want not in ("on", "off"):
        return
    if want == "on":
        d = await _status()
        if d.get("ipv6_why"):
            await ui.render(cb, f"<b>IPv6 в туннеле</b>\n\n❌ {esc(d['ipv6_why'])}", ui.kb(ui.back("wo")))
            return
        text = ("<b>IPv6 в туннеле</b>\n\nКлиенты получат адрес IPv6 (частная сеть, наружу — через адрес сервера) "
                "и сайты по IPv6. Комплекты перевыпустятся; в прежних только IPv4 — они продолжат работать.\n"
                "Клиенты в туннелях (WARP, Xray, exit-ноды) IPv6 не получат: туннели ведут только IPv4.\n"
                "WireGuard перезапустится — клиенты на несколько секунд потеряют связь.")
    else:
        text = "<b>IPv6 в туннеле</b>\n\nВыключить? WireGuard перезапустится, комплекты перевыпустятся."
    await ui.confirm(cb, text, ("✅ Включить" if want == "on" else "⬜️ Выключить", act.data("v6ok", want)), "wo")


@act("v6ok")
async def _v6_ok(cb: CallbackQuery, state: FSMContext, want: str) -> None:
    if want not in ("on", "off"):
        return
    await _quick(cb, "IPv6 в туннеле", "wgobf", "ipv6", want)


# ── Ссылка установки ──────────────────────────────────────
async def install_base() -> str:
    """Адрес для ссылки: Mini App, без неё — веб-панель, если открыта всем."""
    if webapp.SERVER.running and webapp.SERVER.url:
        return webapp.SERVER.url
    w = await api.data("web", "status", default={}) or {}
    if w.get("active") and w.get("access") == "all" and w.get("url"):
        return str(w["url"])
    return ""


def install_text(name: str, url: str, exp: int) -> str:
    return (f"<b>🔗 Ссылка установки {esc(name)}</b>\n"
            "Для роутера Keenetic: AWG Manager настроит туннель сам, без файлов.\n"
            "AWG Manager → Новый туннель → «Phobos» → верхнее поле «Ссылка установки Phobos»:\n"
            f"<code>{esc(url)}</code>\n\n"
            f"Срабатывает один раз, действует сутки — до {time.strftime('%d.%m %H:%M', time.localtime(exp))}. "
            "Ссылка — это доступ к VPN: отправляй только тому, кому он предназначен.")


@act("il")
async def _install_link(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    rows = await api.data("wgobf", "clients", default=[]) or []
    c = next((r for r in rows if r.get("name") == name), None)
    if c is None or not c.get("pub"):
        await ui.render(cb, f"Клиента <b>{esc(name)}</b> нет.", ui.kb(ui.back(act.data("list"))))
        return
    base = await install_base()
    if not base:
        await ui.render(cb, "<b>🔗 Ссылка установки</b>\nСсылку отдаёт Mini App или веб-панель с доступом для всех — "
                            "сейчас ни одна из них не работает. Включи Mini App: Бот → 📱 Mini App.",
                        ui.kb(ui.back(act.data("v", name))))
        return
    try:
        token, rid, exp = instlink.create(name, c["pub"], f"tg:{cb.from_user.id}")
    except share.PersistenceError as e:
        await cb.answer(str(e), show_alert=True)
        return
    await ui.render(cb, install_text(name, instlink.url_for(base, token), exp),
                    ui.kb(("🚫 Отозвать", act.data("ilx", f"{name}|{rid}")), ui.back(act.data("v", name))))


@act("ilx")
async def _install_revoke(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    name, _, rid = arg.partition("|")
    try:
        revoked = instlink.revoke(rid)
    except share.PersistenceError as e:
        await cb.answer(str(e), show_alert=True)
        return
    await cb.answer("Ссылка отозвана" if revoked else "Ссылка уже не действует")
    await _view(cb, state, name)
