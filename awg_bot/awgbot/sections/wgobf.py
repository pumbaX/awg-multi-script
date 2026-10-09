"""WG + обфускатор (wg-obfuscator, как Phobos): установка, клиенты и их
комплекты, настройки, удаление."""

from __future__ import annotations

import re

from aiogram import Bot, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from .. import api, ask, jobs, media, store, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "wo")

NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
# DNS клиентов — те же три, что в меню awg2; кнопка перебирает их по кругу
DNS = [("Cloudflare", "1.1.1.1, 1.0.0.1"), ("Google", "8.8.8.8, 8.8.4.4"), ("Quad9", "9.9.9.9, 149.112.112.112")]


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
    await ui.render(cb, "<b>🛡 WG + обфускатор</b>\n" + ui.pre(r.log, 1500, tail=False)
                    + f"\n<i>🎭 — маскировка клиентов: {esc(d.get('masking') or '?')} → {mask}\n"
                      "Чистый WG — пускать и обычный WireGuard без обфускатора (iOS); его DPI видит</i>", ui.kb(
        ("➕ Добавить", act.data("add")),
        ("👥 Клиенты", act.data("list")),
        (f"🎭 → {mask}", act.data("mask", mask)),
        (f"{'✅' if d.get('clean') else '⬜️'} Чистый WG", act.data("clean", "0" if d.get("clean") else "1")),
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
    await ask.ask(cb, state, "wo_port", "UDP-порт обфускатора (1024-65535):", "wo")


@ask.on("wo_port")
async def _install_port_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not v.isdigit() or not 1024 <= int(v) <= 65535:
        await ask.retry(msg, state, ctx, "Порт — число 1024-65535")
        return
    o = dict((await state.get_data()).get("wgobf") or {}, port=v)
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
    await ui.render(cb, f"<b>🛡 {esc(name)}</b> — WG + обфускатор\n\nIP: <code>{esc(c['ip'])}</code>\n"
                        f"Статус: {seen}\n"
                        f"Трафик с запуска: ↓ {ui.fmt_bytes(c.get('rx'))} · ↑ {ui.fmt_bytes(c.get('tx'))}\n"
                        f"Мониторинг: {'🔔 вкл' if mon else '🔕 выкл'}\n\n"
                        "<i>📄 Конфиг — ссылка и конфиг текстом, плюс один файл .conf со всеми данными\n"
                        "📦 Архив — wg.conf, obfuscator.conf и установщик для Linux\n"
                        "🔔 Мониторинг — сообщу, когда клиент пропал (5 минут без связи) и вернулся</i>",
                    ui.kb(("📄 Конфиг", act.data("bundle", name)),
                          ("📦 Архив", act.data("zip", name)),
                          ("🔕 Выключить мониторинг" if mon else "🔔 Мониторинг", act.data("mon", name)),
                          ("🗑 Удалить", act.data("del", name)),
                          ui.back(act.data("list"))))


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


@act("mask")
async def _mask(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    await _quick(cb, f"Маскировка {v}", "wgobf", "masking", v)


@act("clean")
async def _clean(cb: CallbackQuery, state: FSMContext, v: str) -> None:
    await _quick(cb, "Клиенты без обфускатора", "wgobf", "clean", v)


@act("key")
async def _key(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Сменить ключ обфускатора? <b>Все</b> клиенты отключатся, пока не получат новый комплект.",
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
