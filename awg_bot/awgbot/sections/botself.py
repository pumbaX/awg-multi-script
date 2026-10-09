"""Telegram-бот: версия, обновление, перезапуск, журнал, прокси до Telegram,
админы и приглашения, удаление бота.

Обновление, перезапуск и удаление идут задачами awg2: они останавливают сам
бот, а задача в отдельном юните доводит дело до конца. После старта бот
дочитывает её журнал (jobs.resume) и ставит итог в то же сообщение.
"""

from __future__ import annotations

import contextlib
import re
import time

from aiogram import Router
from aiogram.exceptions import TelegramBadRequest
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import __version__, access, admins, alerts, api, ask, icons, jobs, store, ui, webapp
from ..ui import esc

router = Router()
act = ui.Actions(router, "botm")
adm = ui.Actions(router, "adm", owner="Список админов правит только владелец")
look = ui.Actions(router, "look", owner="Оформление меняет только владелец")
app = ui.Actions(router, "app", owner="Mini App настраивает только владелец")
ntf = ui.Actions(router, "ntf", owner="Уведомления настраивает только владелец")


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    d = await api.data("bot", "status", default={}) or {}
    owner = access.is_owner(cb.from_user.id)
    await ui.render(cb, "<b>🤖 Telegram-бот</b>\n\n"
                        f"Версия: <b>{esc(__version__)}</b>\n"
                        f"Прокси до Telegram: {esc(d.get('proxy') or 'нет — напрямую')}\n"
                        f"Админов: владельцев {len(access.owners())}, приглашённых {len(admins.invited_ids())}",
                    ui.kb(("⬆️ Обновить", act.data("update")),
                          ("🔄 Перезапустить", act.data("restart")),
                          ("🌐 Прокси", act.data("proxy")),
                          ("📜 Журнал", "diag:log:bot|botm"),
                          ("👮 Админы", adm.data()) if owner else None,
                          ("🎨 Оформление", look.data()) if owner else None,
                          ("📱 Mini App", app.data()) if owner else None,
                          ("🔔 Уведомления", ntf.data()) if owner else None,
                          ("🗑 Удалить бота", act.data("rm")) if owner else None,
                          ui.back()))


# ── Уведомления о сервере ─────────────────────────────────
@ntf()
async def _ntf(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    o = alerts.overview()
    lines = "\n".join(f"{'✅' if k['on'] else '⬜️'} {esc(k['label'])}" for k in o["kinds"])
    await ui.render(cb, "<b>🔔 Уведомления</b>\n\nБот пишет владельцам и админам, когда с сервером что-то "
                        f"случилось; проверка — раз в {max(1, o['interval'] // 60)} мин. Каждое событие — один раз.\n\n"
                        f"{lines}\n\n"
                        "Сроки и лимиты трафика клиентов сообщает таймер awg2 — они приходят всегда, "
                        "даже когда бот остановлен.",
                    ui.kb([(f"{'✅' if k['on'] else '⬜️'} {k['short']}", ntf.data("t", k["id"])) for k in o["kinds"]],
                          ui.back("botm")))


@ntf("t")
async def _ntf_toggle(cb: CallbackQuery, state: FSMContext, kind: str) -> None:
    if kind in alerts.KIND_IDS:
        alerts.set_enabled(kind, not alerts.enabled(kind))
    await _ntf(cb, state)


@act("update")
async def _update(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Обновить бота из канала обновлений AWG Toolza? Он перезапустится и продолжит "
                         "показывать ход обновления здесь.",
                     ("⬆️ Обновить", act.data("updateok")), "botm")


@act("updateok")
async def _update_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Обновление бота", "bot", "update", back_to="botm")


async def restart_screen(target: ui.Target, r: api.Result, text: str) -> None:
    """Бот сейчас перезапустится: экран «перезапускаюсь», который новый
    процесс бота после старта заменит итогом (см. bot.restore)."""
    if not r.ok:
        await ui.render(target, ui.fail(r, "Перезапуск бота"), ui.kb(ui.back("botm")))
        return
    msg = await ui.render(target, f"🔄 {text}\n<i>Бот перезапускается — через несколько секунд он снова на связи.</i>")
    if msg is not None:
        store.notice_set(msg.chat.id, msg.message_id, text, "botm")


@act("restart")
async def _restart(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await restart_screen(cb, await api.call("bot", "restart"), "Перезапуск бота")


# ── Прокси ────────────────────────────────────────────────
@act("proxy")
async def _proxy(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    d = await api.data("bot", "status", default={}) or {}
    cur = d.get("proxy") or ""
    await ui.render(cb, "<b>🌐 Прокси до Telegram</b>\nНужен, если Telegram у хостера заблокирован: "
                        "SOCKS5/HTTP-прокси или туннель этого сервера.\n\n"
                        f"Сейчас: <code>{esc(cur or 'нет — напрямую')}</code>",
                    ui.kb(("🔎 На сервере", act.data("pcand")),
                          ("✏️ Ввести адрес", act.data("penter")),
                          ("🩺 Проверить", act.data("pcheck")) if cur else None,
                          ("🗑 Убрать прокси", act.data("pclear")) if cur else None,
                          ui.back("botm")))


@act("pcand")
async def _pcand(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Ищу прокси и туннели на сервере, проверяю Telegram через каждый…")
    rows = await api.data("bot", "proxy", "candidates", default=[]) or []
    await ui.remember(state, "proxy", [r["url"] for r in rows])
    if not rows:
        await ui.render(cb, "Подходящих выходов на сервере нет — введи адрес вручную.",
                        ui.kb(("✏️ Ввести адрес", act.data("penter")), ui.back(act.data("proxy"))))
        return
    lines = [f"{'✅' if r['ok'] else '❌'} {esc(r['label'].split(' — ')[0])} — <code>{esc(r['url'])}</code>"
             for r in rows]
    await ui.render(cb, "<b>Выходы сервера</b>\n✅ — Telegram через него отвечает.\n\n" + "\n".join(lines),
                    ui.kb([(f"{'✅' if r['ok'] else '❌'} {r['label'].split(' — ')[0]}", act.data("pset", str(i)))
                           for i, r in enumerate(rows)], ui.back(act.data("proxy"))))


@act("pset")
async def _pset(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    url = await ui.recall(state, "proxy", idx)
    if url:
        await _apply_proxy(cb, state, url)


@act("penter")
async def _penter(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "bot_proxy", "Адрес: <code>схема://[логин:пароль@]хост:порт</code> "
                                          "(http, https, socks4, socks5, socks5h) или <code>iface://warp0</code>.",
                  act.data("proxy"))


@ask.on("bot_proxy")
async def _proxy_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    url = ask.text_of(msg).replace(" ", "")
    if "@" in url:
        # Единственное, что бот удаляет: адрес с логином и паролем прокси
        with contextlib.suppress(TelegramBadRequest):
            await msg.delete()
    await _apply_proxy(msg, state, url)


async def _apply_proxy(target: ui.Target, state: FSMContext, url: str, force: bool = False) -> None:
    await ui.render(target, "⏳ Проверяю Telegram через прокси…")
    r = await api.call("bot", "proxy", "set", url, *(["force"] if force else []))
    if r.ok:
        await state.update_data(proxy_pending="")
        await restart_screen(target, r, "Прокси до Telegram сохранён")
        return
    # Адрес для «сохранить всё равно» — только в памяти бота: в callback_data
    # ему не место (там может быть пароль)
    await state.update_data(proxy_pending=url)
    await ui.render(target, ui.fail(r, "Прокси")
                    + ("" if force else "\n\n<i>⚠️ Сохранить — записать адрес, хоть проверка и не прошла</i>"),
                    ui.kb(("⚠️ Сохранить", act.data("pforce")) if not force else None,
                          ui.back(act.data("proxy"))))


@act("pforce")
async def _pforce(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    url = (await state.get_data()).get("proxy_pending")
    if url:
        await _apply_proxy(cb, state, url, force=True)
    else:
        await _proxy(cb, state, "")


@act("pcheck")
async def _pcheck(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("bot", "proxy", "check")
    await cb.answer(("✅ " if r.ok else "❌ ") + (r.message if not r.ok else "Telegram отвечает")[:180],
                    show_alert=True)


@act("pclear")
async def _pclear(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await restart_screen(cb, await api.call("bot", "proxy", "clear"), "Прокси до Telegram убран")


# ── Удаление бота ─────────────────────────────────────────
@act("rm")
async def _rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if not access.is_owner(cb.from_user.id):
        await cb.answer("Только владелец", show_alert=True)
        return
    await ui.confirm(cb, "Удалить бота: службу, код и конфиг с токеном? AWG не затрагивается, "
                         "конфиг копируется в бэкапы.",
                     ("🗑 Удалить бота", act.data("rmok")), "botm")


@act("rmok")
async def _rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if access.is_owner(cb.from_user.id):
        await jobs.start(cb, "Удаление бота", "bot", "uninstall", back_to="main")


# ── Админы ────────────────────────────────────────────────
async def _owner_only(cb: CallbackQuery) -> bool:
    if access.is_owner(cb.from_user.id):
        return True
    await cb.answer("Список админов правит только владелец", show_alert=True)
    return False


@adm()
async def admins_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    if not await _owner_only(cb):
        return
    lines = ["<b>👮 Админы</b>", "", "Владельцы (ADMIN_ID в /etc/awg-bot.conf):"]
    lines += [f"• <code>{uid}</code>" for uid in sorted(access.owners())]
    invited = admins.list_invited()
    lines.append("\nПриглашённые:" if invited else "\nПриглашённых нет.")
    lines += [f"• <code>{a.uid}</code>" + (f" @{esc(a.username)}" if a.username else "") for a in invited]
    pending = admins.pending_invites()
    if pending:
        lines.append(f"\nНеиспользованных приглашений: {pending}")
    lines.append("\n<i>➕ Пригласить — ссылка на 15 минут · 🚫 — отозвать доступ</i>")
    await ui.render(cb, "\n".join(lines), ui.kb(
        ("➕ Пригласить", adm.data("invite")),
        ("🧯 Погасить все", adm.data("revoke")) if pending else None,
        [(f"🚫 @{a.username}" if a.username else f"🚫 {a.uid}", adm.data("rm", str(a.uid))) for a in invited],
        ui.back("botm")))


@adm("invite")
async def _invite(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if not await _owner_only(cb):
        return
    token, exp = admins.create_invite(cb.from_user.id)
    if token is None:
        await cb.answer(str(exp)[:190], show_alert=True)
        return
    me = await cb.bot.me()  # type: ignore[union-attr]
    link = f"https://t.me/{me.username}?start={admins.INVITE_PREFIX}{token}"
    await ui.render(cb, "<b>➕ Приглашение</b>\n\nПерешли ссылку тому, кому даёшь доступ. Она одноразовая и "
                        f"сгорит {ui.fmt_time(int(exp))} (через {ui.fmt_dur(int(exp) - int(time.time()))}).\n\n"
                        f"<code>{esc(link)}</code>\n\n"
                        "⚠️ Админ может всё, кроме управления списком админов: бот — это root на сервере.",
                    ui.kb(ui.back(adm.data())))


@adm("rm")
async def _adm_rm(cb: CallbackQuery, state: FSMContext, uid: str) -> None:
    if await _owner_only(cb):
        await ui.confirm(cb, f"Отозвать доступ у <code>{esc(uid)}</code>? Выданные им конфиги продолжат работать.",
                         ("🚫 Отозвать", adm.data("rmok", uid)), adm.data())


@adm("rmok")
async def _adm_rm_ok(cb: CallbackQuery, state: FSMContext, uid: str) -> None:
    if not await _owner_only(cb) or not uid.isdigit():
        return
    ok, res = admins.remove(int(uid), removed_by=cb.from_user.id)
    await cb.answer(res[:190], show_alert=not ok)
    await admins_screen(cb, state)


@adm("revoke")
async def _revoke(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if await _owner_only(cb):
        n = admins.revoke_invites()
        await cb.answer(f"Погашено приглашений: {n}")
        await admins_screen(cb, state)


# ── Оформление: цветные кнопки и иконки ───────────────────
PACK_RE = re.compile(r"(?:addemoji/)?([A-Za-z0-9_]{1,64})/?$")


def _look_text(verdict: str = "") -> str:
    m = icons.mapping()
    lines = ["<b>🎨 Оформление</b>", ""]
    if verdict:
        lines += [verdict, ""]
    lines += [
        f"Иконки вместо эмодзи: <b>{'включены' if icons.active() else 'выключены'}</b>"
        + (f" · {esc(icons.pack())}, иконок: {len(m)}" if m else ""),
        "",
        "<i>Иконки — custom emoji Telegram, монохромные значки в тексте и на кнопках. Бот может их "
        "показывать, только если у владельца бота (аккаунт, создавший его в @BotFather) есть Telegram "
        "Premium или у бота есть имя с Fragment. Перед включением бот проверяет, видны ли они; перестанут "
        "быть видны — сам вернётся к обычным эмодзи.</i>",
    ]
    return "\n".join(lines)


async def _look_screen(target: ui.Target, verdict: str = "") -> None:
    m = icons.mapping()
    await ui.render(target, _look_text(verdict), ui.kb(
        ("📥 Набор иконок", look.data("pack")),
        ("✍️ Свои иконки", look.data("own")),
        ("▶️ Включить", look.data("on")) if m and not icons.active() else None,
        ("⏹ Выключить", look.data("off")) if icons.active() else None,
        ui.back("botm")))


@look()
async def look_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await _look_screen(cb)


async def _try_icons(target: ui.Target, pack: str, mapping: dict[str, str]) -> None:
    """Включить и проверить на деле: пробный экран с иконками в тексте и на
    кнопке. Не показались — icons.Middleware их уже выключил."""
    icons.save(pack, mapping, True)
    sample = [e for e in icons.TEMPLATE if e in mapping][:8]
    await ui.render(target, "🎨 Проверяю иконки… " + " ".join(sample),
                    ui.kb((f"{sample[0]} Проверка", look.data()) if sample else None))
    if icons.active():
        have, miss = icons.coverage(mapping)
        verdict = (f"✅ Иконки включены: {len(have)} из {len(icons.TEMPLATE)} значков бота.\n"
                   f"С иконками: {' '.join(have)}"
                   + (f"\nОбычные эмодзи: {' '.join(miss)}\n<i>Их можно дополнить: ✍️ Свои иконки.</i>"
                      if miss else ""))
    else:
        verdict = ("❌ Telegram не показал иконки. Нужен Telegram Premium у владельца бота (аккаунт, "
                   "создавший его в @BotFather) или имя бота с Fragment. Набор сохранён — включить можно позже.")
    await _look_screen(target, verdict)


@look("pack")
async def _look_pack(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "look_pack", "Ссылка на набор эмодзи: <code>t.me/addemoji/ИМЯ</code> или просто имя.\n"
                                          "<i>Иконки сопоставятся с эмодзи бота по эмодзи, привязанным к ним в "
                                          "наборе (или похожим); остальные останутся обычными.</i>", look.data(),
                  [(f"📱 {icons.DEFAULT_PACK}", look.data("pk", icons.DEFAULT_PACK))])


async def pack_icons(bot, name: str) -> tuple[str, dict[str, str]]:  # type: ignore[no-untyped-def]
    """Имя и иконки набора или ("", {}) с причиной в имени при ошибке."""
    try:
        pack = await bot.get_sticker_set(name)
    except TelegramBadRequest:
        return f"Набор {name} не найден", {}
    if pack.sticker_type != "custom_emoji":
        return "Это набор стикеров, а нужен набор эмодзи (t.me/addemoji/…)", {}
    mapping = icons.from_pack(pack.stickers)
    if not any(e in mapping for e in icons.TEMPLATE):
        return "В наборе нет иконок для эмодзи бота — пришли свои (✍️ Свои иконки)", {}
    return pack.name, mapping


@ask.on("look_pack")
async def _look_pack_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    m = PACK_RE.search(ask.text_of(msg))
    if not m:
        await ask.retry(msg, state, ctx, "Нужна ссылка вида t.me/addemoji/ИМЯ")
        return
    name, mapping = await pack_icons(msg.bot, m.group(1))
    if not mapping:
        await ask.retry(msg, state, ctx, name)
        return
    await _try_icons(msg, name, mapping)


@look("pk")
async def _look_pack_btn(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    name, mapping = await pack_icons(cb.bot, arg)
    if not mapping:
        await ui.render(cb, f"❌ {esc(name)}", ui.kb(ui.back(look.data())))
        return
    await _try_icons(cb, name, mapping)


@look("own")
async def _look_own(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "look_own",
                  "Пришли одним сообщением иконки (custom emoji) по порядку — для этих эмодзи бота:\n\n"
                  + " ".join(icons.TEMPLATE)
                  + "\n\n<i>Иконки дополняют набор: обычное эмодзи на месте иконки — оставить текущую. "
                    "Можно прислать меньше — остальные останутся как есть.</i>", look.data())


@ask.on("look_own")
async def _look_own_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    own = icons.from_message(msg.text or "", msg.entities or [])
    if not own:
        await ask.retry(msg, state, ctx, "В сообщении нет custom emoji — их отправляют с Telegram Premium")
        return
    pack = icons.pack()
    await _try_icons(msg, f"{pack} + свои" if pack and not pack.endswith("свои") else pack or "свои",
                     {**icons.mapping(), **own})


@look("on")
async def _look_on(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if icons.mapping():
        await _try_icons(cb, icons.pack(), icons.mapping())
    else:
        await _look_screen(cb)


@look("off")
async def _look_off(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    icons.disable("выключены владельцем")
    await _look_screen(cb, "Иконки выключены — снова обычные эмодзи.")


# ── Mini App: HTTPS-сертификат и сервер ───────────────────
DOMAIN_RE = re.compile(r"^(?=.{4,253}$)([a-z0-9-]{1,63}\.)+[a-z]{2,63}$")


async def _owner(cb: CallbackQuery) -> bool:
    if access.is_owner(cb.from_user.id):
        return True
    await cb.answer("Mini App настраивает только владелец", show_alert=True)
    return False


async def app_screen(target: ui.Target, verdict: str = "") -> None:
    c = await api.data("cert", "status", default={}) or {}
    srv = webapp.SERVER
    lines = ["<b>📱 Mini App</b>",
             "Панель управления внутри Telegram. Telegram открывает её только по HTTPS с настоящим сертификатом.",
             ""]
    if verdict:
        lines += [verdict, ""]
    if c.get("installed") and c.get("kind") == "external":
        lines.append(f"🔐 Сертификат: <code>{esc(c.get('name') or '')}</code> (готовый, {esc(c.get('source') or '')}) · "
                     f"до {ui.fmt_time(c.get('expires'))} · продлевает {esc(c.get('source') or 'его программа')}")
    elif c.get("installed"):
        lines.append(f"🔐 Сертификат: <code>{esc(c.get('name') or '')}</code> "
                     f"({'IP' if c.get('kind') == 'ip' else 'домен'}) · до {ui.fmt_time(c.get('expires'))}"
                     + (" · продлевается сам" if c.get("renew") else " · ⚠️ таймер продления не работает"))
    else:
        lines.append("🔐 Сертификата нет")
    lines.append(f"🟢 Mini App: <code>{esc(srv.url)}</code> — и кнопка «Меню» слева от поля ввода"
                 if srv.running else f"⚪️ Mini App не запущена: {esc(srv.error or 'нет сертификата')}")
    if c.get("port80"):
        lines.append(f"⚠️ Порт 80 занят ({esc(c['port80'])}) — выпуск только с паузой службы"
                     + (f"; готовых сертификатов на сервере: {c['found']}" if c.get("found") else ""))
    lines += ["", f"<i>🔐 На IP — сертификат Let's Encrypt на {esc(c.get('ip') or 'IP сервера')}: живёт ~6 дней "
                  "и продлевается сам. Для проверки нужен свободный и открытый порт 80.\n"
                  "🌍 На домен — если у сервера есть домен с A-записью на этот IP.\n"
                  "📂 Готовые — сертификат, который уже выпустили Caddy, certbot, Marzban, 3x-ui или nginx: "
                  "порт 80 не нужен, продлевает та программа.\n"
                  "📱 Открыть панель — проверка: пустит ли Telegram Mini App по этому адресу.</i>"]
    text = "\n".join(lines)
    buttons = [("🔐 На IP", app.data("ip")), ("🌍 На домен…", app.data("dom")),
               (f"📂 Готовые ({c['found']})", app.data("found")) if c.get("found") else None,
               ("🔢 Порт", app.data("port")),
               ("🗑 Удалить", app.data("rm")) if c.get("installed") else None,
               ui.back("botm")]
    if not srv.running:
        await ui.render(target, text, ui.kb(*buttons))
        return
    try:
        await ui.render(target, text, ui.kb(ui.Row(("📱 Открыть панель", "webapp:" + srv.url)), *buttons))
    except TelegramBadRequest as e:
        # Главный вопрос шага: принимает ли Telegram адрес Mini App (IP)
        await ui.render(target, text + f"\n\n❌ Telegram не принял адрес <code>{esc(srv.url)}</code>: "
                                       f"{esc(e.message)}\nНужен домен — 🌍 На домен…", ui.kb(*buttons))


async def _app_started(bot, chat_id: int, st: dict) -> None:  # type: ignore[no-untyped-def]
    await webapp.SERVER.start(bot)


@app()
async def _app(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    if await _owner(cb):
        await app_screen(cb)


async def _busy80(target: ui.Target, c: dict, kind: str) -> None:
    """Порт 80 занят: выпуск с паузой службы или готовый сертификат сервера."""
    unit = c.get("port80_unit") or ""
    text = (f"<b>Порт 80 занят ({esc(c.get('port80') or '')})</b>\n\nLet's Encrypt проверяет адрес через порт 80. "
            "Варианты:\n")
    if unit:
        text += (f"• ⏸ Пауза — acme.sh останавливает <code>{esc(unit)}</code> на несколько секунд выпуска "
                 + ("и каждого продления (на IP — раз в 3 дня).\n" if kind == "ip" else "и каждого продления.\n"))
    if c.get("found"):
        text += f"• 📂 Готовый — сертификат, который уже есть на сервере ({c['found']}): порт 80 не нужен.\n"
    if not unit and not c.get("found"):
        text += "• Освободить порт 80 — служба не опознана, остановить её на время выпуска нельзя."
    await ui.render(target, text, ui.kb(
        ("⏸ С паузой", app.data("pause", kind)) if unit else None,
        ("📂 Готовые", app.data("found")) if c.get("found") else None,
        ui.back(app.data())))


@app("ip")
async def _app_ip(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if not await _owner(cb):
        return
    c = await api.data("cert", "status", default={}) or {}
    if c.get("port80"):
        await _busy80(cb, c, "ip")
        return
    await jobs.start(cb, "Сертификат на IP", "cert", "issue", "ip", back_to=app.data(), done=_app_started)


@app("pause")
async def _app_pause(cb: CallbackQuery, state: FSMContext, kind: str) -> None:
    if not await _owner(cb):
        return
    if kind == "ip":
        await jobs.start(cb, "Сертификат на IP", "cert", "issue", "ip", "pause", back_to=app.data(),
                         done=_app_started)
        return
    dom = (await state.get_data()).get("app_domain") or ""
    if not DOMAIN_RE.match(dom):
        await app_screen(cb)
        return
    await jobs.start(cb, f"Сертификат на {dom}", "cert", "issue", "domain", dom, "pause", back_to=app.data(),
                     done=_app_started)


@app("found")
async def _app_found(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if not await _owner(cb):
        return
    rows = await api.data("cert", "find", default=[]) or []
    await ui.remember(state, "certs", [r.get("cert") for r in rows])
    if not rows:
        await app_screen(cb, "📂 Готовых сертификатов на этот сервер не нашлось")
        return
    await ui.render(cb, "<b>📂 Готовые сертификаты сервера</b>\n\nВыписаны на этот сервер, ключ на месте, "
                        "публичные. Mini App берёт файлы ссылкой — продлевает их та программа, что выпустила.\n\n"
                        + "\n".join(f"• <code>{esc(r['name'])}</code> — {esc(r['source'])}, до "
                                     f"{ui.fmt_time(r.get('expires'))}" for r in rows),
                    ui.kb([(f"{r['name']} · {r['source']}", app.data("use", str(i))) for i, r in enumerate(rows)],
                          ui.back(app.data())))


@app("use")
async def _app_use(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    if not await _owner(cb):
        return
    path = await ui.recall(state, "certs", idx)
    if not path:
        await _app_found(cb, state, "")
        return
    r = await api.call("cert", "use", path)
    if r.ok:
        await webapp.SERVER.start(cb.bot)  # type: ignore[arg-type]
    await app_screen(cb, "✅ Готовый сертификат подключён — Mini App переехала на него" if r.ok
                     else ui.fail(r, "Готовый сертификат"))


@app("dom")
async def _app_dom(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if await _owner(cb):
        await ask.ask(cb, state, "app_dom", "Домен для Mini App, например <code>panel.example.com</code>.\n"
                                            "<i>A-запись должна указывать на этот сервер.</i>", app.data())


@ask.on("app_dom")
async def _app_dom_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    dom = ask.text_of(msg).lower()
    if not DOMAIN_RE.match(dom):
        await ask.retry(msg, state, ctx, "Нужен домен вида panel.example.com")
        return
    c = await api.data("cert", "status", default={}) or {}
    if c.get("port80"):
        await state.update_data(app_domain=dom)        # домен в callback_data не влезет
        await _busy80(msg, c, "domain")
        return
    await jobs.start(msg, f"Сертификат на {dom}", "cert", "issue", "domain", dom, back_to=app.data(),
                     done=_app_started)


@app("port")
async def _app_port(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if await _owner(cb):
        port = webapp.configured_port()
        await ask.ask(cb, state, "app_port", f"Порт Mini App — сейчас {port or 'не задан (Mini App выключена)'}.\n"
                                             "<i>1-65535, кроме 80 (он для сертификата). 443 — адрес без номера "
                                             "порта, если его не занял Xray. off — выключить.</i>", app.data(),
                      [("8443", app.data("pset", "8443")), ("443", app.data("pset", "443"))])


async def _set_port(target: ui.Target, port: str) -> str:
    r = await api.call("bot", "webapp", "port", port)
    if not r.ok:
        return ui.fail(r, "Порт Mini App")
    await webapp.SERVER.start(target.bot)  # type: ignore[arg-type]
    return f"✅ Порт Mini App: {esc(port)}"


@ask.on("app_port")
async def _app_port_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg).lower()
    if v != "off" and not (v.isdigit() and 0 < int(v) < 65536 and v != "80"):
        await ask.retry(msg, state, ctx, "Порт — число 1-65535, кроме 80, или off")
        return
    await app_screen(msg, await _set_port(msg, v))


@app("pset")
async def _app_port_btn(cb: CallbackQuery, state: FSMContext, port: str) -> None:
    if await _owner(cb):
        await app_screen(cb, await _set_port(cb, port))


@app("rm")
async def _app_rm(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if await _owner(cb):
        await ui.confirm(cb, "Удалить сертификат? Mini App перестанет открываться, продление остановится.",
                         ("🗑 Да, удалить", app.data("rmok")), app.data())


@app("rmok")
async def _app_rm_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if not await _owner(cb):
        return
    r = await api.call("cert", "remove")
    await webapp.SERVER.shutdown()
    webapp.SERVER.error = "нет сертификата"
    await app_screen(cb, "✅ Сертификат удалён" if r.ok else ui.fail(r, "Удаление сертификата"))
