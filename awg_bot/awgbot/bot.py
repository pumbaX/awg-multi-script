"""
bot.py — Telegram-бот управления AmneziaWG (awg2).

Управление полностью кнопочное (inline). Единственная команда — /start.
Доступ: только ADMIN_ID из конфига.
"""

from __future__ import annotations

import asyncio
import html
import io
import logging
import os
import time
from datetime import datetime

from aiogram import Bot, Dispatcher, F
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.filters import CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (
    BufferedInputFile,
    CallbackQuery,
    Message,
)

from . import core, keyboards as kb, wrapper
from .config import load_config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("awgbot")

CFG = load_config()
bot = Bot(token=CFG.token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
dp = Dispatcher(storage=MemoryStorage())


# ───────────────────────── глобальный обработчик ошибок ─────────────────────────
@dp.error()
async def on_error(event) -> bool:
    """
    Глушит шумные, но безобидные ошибки:
      - "query is too old / query ID is invalid" — пользователь нажал кнопку,
        а бот ответил позже таймаута Telegram (перезапуск/лаг сети). Нажатие
        просто теряется, ничего страшного.
      - сетевые таймауты до Telegram — aiogram сам переподключится.
    Остальное логируем как ERROR, чтобы видеть реальные баги.
    """
    exc = getattr(event, "exception", None)
    msg = str(exc) if exc else ""
    exc_name = type(exc).__name__ if exc else ""
    benign_markers = (
        "query is too old", "query ID is invalid",
        "message is not modified", "Request timeout",
    )
    benign = any(m in msg for m in benign_markers) or "Timeout" in exc_name
    if benign:
        log.info("Пропущена безобидная ошибка: %s", msg[:120])
        return True  # обработано, дальше не пробрасываем
    log.exception("Необработанная ошибка: %s", msg)
    return True


# ───────────────────────── FSM ─────────────────────────
class Flow(StatesGroup):
    add_name = State()
    add_profile = State()
    rename = State()
    expire_date = State()
    note_text = State()
    await_backup = State()


# ───────────────────────── auth ─────────────────────────
def authorized(uid: int) -> bool:
    return uid in CFG.admins


async def deny(event) -> None:
    if isinstance(event, Message):
        await event.answer("⛔️ Доступ запрещён.")
    else:
        await event.answer("⛔️ Доступ запрещён.", show_alert=True)


# ───────────────────────── render helpers ─────────────────────────
def esc(s: str) -> str:
    return html.escape(str(s))


def make_qr_png(text: str) -> bytes | None:
    """
    Делает PNG QR-кода из текста. Если конфиг слишком большой для QR
    (бывает с профилями QUIC/TLS, где длинный I1) — возвращает None,
    чтобы бот предложил использовать .conf файл вместо QR.
    """
    try:
        import qrcode
        from qrcode.constants import ERROR_CORRECT_L
        # уровень L даёт максимальную вместимость данных
        qr = qrcode.QRCode(error_correction=ERROR_CORRECT_L, box_size=8, border=2)
        qr.add_data(text)
        qr.make(fit=True)  # подберёт версию; при переполнении кинет исключение
        img = qr.make_image(fill_color="black", back_color="white")
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        buf.seek(0)
        return buf.read()
    except Exception:
        # слишком большой конфиг или нет модуля — QR не делаем
        return None


def menu_text() -> str:
    info = core.get_server_info()
    if not info.installed:
        return (
            "🛡 <b>awgToolza Bot</b>\n"
            "<i>панель управления</i>\n\n"
            "⚠️ <b>Сервер ещё не установлен.</b>\n"
            "Установку выполни в консоли:\n"
            "<code>sudo awg2</code> → Сервер (1)"
        )

    peers = core.list_peers()
    online = sum(1 for p in peers if p.online)
    blocked = sum(1 for p in peers if p.blocked)
    monitored = sum(1 for p in peers if p.monitored)
    total_rx = sum(p.rx for p in peers)
    total_tx = sum(p.tx for p in peers)
    state = "🟢 работает" if info.iface_up else "🔴 остановлен"
    uptime = core.fmt_uptime(core.server_uptime()) if info.iface_up else "—"

    warp = "вкл" if core.warp_installed() and core.warp_iface_up() else (
        "выкл" if core.warp_installed() else "нет")
    rc, out, _ = core.run(["systemctl", "is-active", "dnscrypt-proxy.socket"])
    rc2, out2, _ = core.run(["systemctl", "is-active", "dnscrypt-proxy"])
    dns_on = "active" in (out + out2)
    dns = "вкл" if dns_on else "нет"

    mon_line = f"\n🔔 #ping: <b>{monitored}</b>" if monitored else ""

    return (
        "🛡 <b>awgToolza Bot</b>\n\n"
        "<b>СЕРВЕР</b>\n"
        f"{state} · профиль <code>{esc(info.profile or '—')}</code>\n"
        f"🌍 <code>{esc(info.public_ip or '—')}:{esc(info.listen_port or '—')}</code>\n"
        f"⏱ аптайм: {uptime}\n\n"
        "<b>ЗАЩИТА</b>\n"
        f"☁ WARP {warp} · 🔐 DNS {dns}\n\n"
        "<b>КЛИЕНТЫ</b>\n"
        f"👥 <b>{info.peers_count}</b>  ·  🟢 {online}  ⚪️ {info.peers_count - online - blocked}  🚫 {blocked}\n"
        f"📊 ↓{core.fmt_bytes(total_rx)}  ↑{core.fmt_bytes(total_tx)}"
        f"{mon_line}"
    )


def status_text() -> str:
    info = core.get_server_info()
    if not info.installed:
        return "Сервер не установлен."
    peers = core.list_peers()
    online = sum(1 for p in peers if p.online)
    blocked = sum(1 for p in peers if p.blocked)
    total_rx = sum(p.rx for p in peers)
    total_tx = sum(p.tx for p in peers)
    state = "🟢 запущен" if info.iface_up else "🔴 остановлен"
    return (
        "<b>📊 Статус сервера</b>\n\n"
        f"Состояние: {state}\n"
        f"Адрес сети: <code>{esc(info.address)}</code>\n"
        f"Порт: <code>{esc(info.listen_port)}</code>  MTU: <code>{esc(info.mtu)}</code>\n"
        f"Внешний IP: <code>{esc(info.public_ip or '—')}</code>\n"
        f"Регион: <code>{esc(info.region or '—')}</code>\n\n"
        f"Клиентов всего: <b>{len(peers)}</b>\n"
        f"🟢 онлайн: <b>{online}</b>   🚫 заблок.: <b>{blocked}</b>\n"
        f"Трафик (RX/TX): {core.fmt_bytes(total_rx)} / {core.fmt_bytes(total_tx)}"
    )


def client_card_text(p: core.Peer) -> str:
    if p.blocked:
        st = "🚫 заблокирован (срок истёк)"
    elif p.online:
        st = f"🟢 онлайн ({core.fmt_ago(p.last_handshake)})"
    elif p.last_handshake:
        st = f"⚪️ офлайн ({core.fmt_ago(p.last_handshake)})"
    else:
        st = "⚪️ нет подключений"
    exp = "♾ бессрочно"
    if p.expires:
        left = p.expires - int(time.time())
        when = datetime.fromtimestamp(p.expires).strftime("%Y-%m-%d %H:%M")
        exp = f"⏳ до {when}" + ("" if left > 0 else " (истёк)")
    note_line = ""
    if p.note:
        mon = " 🔔" if p.monitored else ""
        note_line = f"Заметка: {esc(p.note)}{mon}\n"
    # WARP-маршрут
    ws = core.warp_client_state(p.name)
    if ws is True:
        route = "☁ через WARP"
    elif ws is False:
        route = "→ напрямую"
    else:
        route = "→ напрямую (WARP не установлен)"
    return (
        f"<b>👤 {esc(p.name)}</b>\n\n"
        f"IP: <code>{esc(p.allowed_ips)}</code>\n"
        f"Статус: {st}\n"
        f"Маршрут: {route}\n"
        f"Срок: {exp}\n"
        f"{note_line}"
        f"Трафик ↓{core.fmt_bytes(p.rx)} ↑{core.fmt_bytes(p.tx)}\n"
        + (f"Endpoint: <code>{esc(p.endpoint)}</code>\n" if p.endpoint else "")
    )


def _card_kb(idx: int, p: core.Peer):
    """Клавиатура карточки с актуальным состоянием WARP."""
    return kb.client_card(idx, p.monitored, core.warp_client_state(p.name))


async def safe_edit(cq: CallbackQuery, text: str, markup=None) -> None:
    try:
        await cq.message.edit_text(text, reply_markup=markup)
    except Exception:
        await cq.message.answer(text, reply_markup=markup)


# ───────────────────────── /start ─────────────────────────
@dp.message(CommandStart())
async def cmd_start(msg: Message, state: FSMContext) -> None:
    if not authorized(msg.from_user.id):
        # подсказка, как узнать свой ID для настройки
        await msg.answer(
            "⛔️ Доступ запрещён.\n"
            f"Твой Telegram ID: <code>{msg.from_user.id}</code>\n"
            "Добавь его в конфиг бота (ADMIN_ID), если это твой сервер."
        )
        return
    await state.clear()
    info = core.get_server_info()
    await msg.answer(menu_text(), reply_markup=kb.main_menu(info.installed))


# ───────────────────────── навигация ─────────────────────────
@dp.callback_query(F.data == "menu")
async def cb_menu(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await state.clear()
    info = core.get_server_info()
    await safe_edit(cq, menu_text(), kb.main_menu(info.installed))
    await cq.answer()


@dp.callback_query(F.data == "not_installed")
async def cb_not_installed(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Установи сервер в консоли: awg2 → Сервер (1) → п.2", show_alert=True)


@dp.callback_query(F.data == "status")
async def cb_status(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(cq, status_text(), kb.back_button("menu"))
    await cq.answer()


# ───────────────────────── клиенты ─────────────────────────
@dp.callback_query(F.data == "clients")
async def cb_clients(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await state.clear()
    peers = core.list_peers()
    txt = f"<b>👥 Клиенты ({len(peers)})</b>\n\n🟢 онлайн · ⚪️ офлайн · 🚫 заблокирован"
    await safe_edit(cq, txt, kb.clients_menu(peers, page=0, sort_active=False))
    await cq.answer()


@dp.callback_query(F.data.startswith("clpage:"))
async def cb_clients_page(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await state.clear()
    _, page_s, sort_s = cq.data.split(":")
    page, sort_active = int(page_s), bool(int(sort_s))
    peers = core.list_peers()
    txt = f"<b>👥 Клиенты ({len(peers)})</b>\n\n🟢 онлайн · ⚪️ офлайн · 🚫 заблокирован"
    await safe_edit(cq, txt, kb.clients_menu(peers, page=page, sort_active=sort_active))
    await cq.answer()


@dp.callback_query(F.data == "noop")
async def cb_noop(cq: CallbackQuery) -> None:
    await cq.answer()  # кнопка-счётчик страниц, ничего не делает


def _peer_by_idx(idx: int) -> core.Peer | None:
    peers = core.list_peers()
    return peers[idx] if 0 <= idx < len(peers) else None


@dp.callback_query(F.data.startswith("client:"))
async def cb_client_card(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    await safe_edit(cq, client_card_text(p), _card_kb(idx, p))
    await cq.answer()


@dp.callback_query(F.data.startswith("cl_conf:"))
async def cb_client_conf(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p or not os.path.isfile(p.conf_path):
        return await cq.answer("Файл конфига не найден", show_alert=True)
    data = open(p.conf_path, "rb").read()
    await cq.message.answer_document(
        BufferedInputFile(data, filename=f"{p.name}.conf"),
        caption=f"Конфиг клиента <b>{esc(p.name)}</b>",
    )
    await cq.answer()


@dp.callback_query(F.data.startswith("cl_qr:"))
async def cb_client_qr(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p or not os.path.isfile(p.conf_path):
        return await cq.answer("Файл конфига не найден", show_alert=True)
    conf = open(p.conf_path).read()
    png = make_qr_png(conf)
    if png:
        await cq.message.answer_photo(
            BufferedInputFile(png, filename=f"{p.name}_qr.png"),
            caption=f"QR клиента <b>{esc(p.name)}</b>\nОтсканируй в приложении AmneziaWG.",
        )
    else:
        # конфиг слишком большой для QR (длинный I1) — отдаём файл
        await cq.message.answer_document(
            BufferedInputFile(conf.encode(), filename=f"{p.name}.conf"),
            caption=(f"Конфиг <b>{esc(p.name)}</b> слишком большой для QR-кода "
                     "(длинный профиль маскировки). Импортируй этот .conf файл "
                     "в приложении AmneziaWG."),
        )
    await cq.answer()


@dp.callback_query(F.data.startswith("cl_del:"))
async def cb_client_del(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    await safe_edit(
        cq,
        f"Удалить клиента <b>{esc(p.name)}</b>?\nЭто действие необратимо.",
        kb.confirm(yes_cb=f"cl_delok:{idx}", no_cb=f"client:{idx}"),
    )
    await cq.answer()


@dp.callback_query(F.data.startswith("cl_delok:"))
async def cb_client_delok(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    ok, msg = core.delete_client(p.name)
    await cq.answer(msg, show_alert=not ok)
    peers = core.list_peers()
    await safe_edit(cq, f"<b>👥 Клиенты ({len(peers)})</b>", kb.clients_menu(peers))


# ── добавление клиента (FSM) ──
@dp.callback_query(F.data == "client_add")
async def cb_client_add(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await state.set_state(Flow.add_name)
    await safe_edit(
        cq,
        "Введи имя нового клиента (буквы, цифры, <code>_</code>, <code>-</code>).\n"
        "Например: <code>phone</code>, <code>laptop_max</code>.",
        kb.back_button("clients"),
    )
    await cq.answer()


@dp.message(Flow.add_name)
async def msg_add_name(msg: Message, state: FSMContext) -> None:
    if not authorized(msg.from_user.id):
        return await deny(msg)
    name = (msg.text or "").strip()
    # базовая валидация имени до выбора профиля
    if not core.NAME_RE.match(name):
        await msg.answer("❌ Имя: только латиница, цифры, <code>_</code> и <code>-</code>. Попробуй ещё раз.")
        return
    if core.get_peer(name):
        await msg.answer(f"❌ Клиент '{esc(name)}' уже существует. Введи другое имя.")
        return
    await state.update_data(add_name=name)
    await state.set_state(Flow.add_profile)
    # профиль сервера определяет, давать ли выбор (как в awg2: Pro → выбор)
    info = core.get_server_info()
    srv_prof = (info.profile or "").lower()
    if srv_prof == "lite":
        await _create_with_profile(msg, state, name, "dns")
        return
    if srv_prof == "standard":
        await _create_with_profile(msg, state, name, "tls")
        return
    await msg.answer(
        f"👤 Имя: <b>{esc(name)}</b>\n\nВыбери профиль мимикрии:",
        reply_markup=kb.profile_choices(),
    )


@dp.callback_query(Flow.add_profile, F.data.startswith("prof:"))
async def cb_add_profile(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    profile = cq.data.split(":")[1]
    data = await state.get_data()
    name = data.get("add_name", "")
    await cq.answer()
    await _create_with_profile(cq.message, state, name, profile)


async def _create_with_profile(target, state: FSMContext, name: str, profile: str) -> None:
    """Общий код создания клиента с выбранным профилем."""
    await state.clear()
    label = {"tls": "TLS", "dns": "DNS", "sip": "SIP",
             "quic": "QUIC", "basic": "базовый"}.get(profile, profile)
    wait = await target.answer(f"⏳ Создаю <b>{esc(name)}</b> (профиль: {label})…")
    ok, text, conf_path = await asyncio.to_thread(core.add_client, name, None, profile)
    await wait.edit_text(("✅ " if ok else "❌ ") + esc(text))
    if ok and conf_path and os.path.isfile(conf_path):
        data = open(conf_path, "rb").read()
        await target.answer_document(
            BufferedInputFile(data, filename=f"{name}.conf"),
            caption=f"Конфиг <b>{esc(name)}</b> готов.",
        )
        png = make_qr_png(data.decode())
        if png:
            await target.answer_photo(
                BufferedInputFile(png, filename=f"{name}_qr.png"),
                caption="QR для AmneziaWG")
        else:
            await target.answer(
                "ℹ️ Конфиг великоват для QR-кода (длинный профиль маскировки) — "
                "импортируй .conf файл выше.")
    peers = core.list_peers()
    await target.answer(f"<b>👥 Клиенты ({len(peers)})</b>", reply_markup=kb.clients_menu(peers))


# ── переименование (FSM) ──
@dp.callback_query(F.data.startswith("cl_ren:"))
async def cb_client_ren(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    await state.set_state(Flow.rename)
    await state.update_data(old=p.name)
    await safe_edit(cq, f"Новое имя для <b>{esc(p.name)}</b>:", kb.back_button(f"client:{idx}"))
    await cq.answer()


@dp.message(Flow.rename)
async def msg_rename(msg: Message, state: FSMContext) -> None:
    if not authorized(msg.from_user.id):
        return await deny(msg)
    data = await state.get_data()
    await state.clear()
    ok, text = await asyncio.to_thread(core.rename_client, data["old"], (msg.text or "").strip())
    await msg.answer(("✅ " if ok else "❌ ") + esc(text))
    peers = core.list_peers()
    await msg.answer(f"<b>👥 Клиенты ({len(peers)})</b>", reply_markup=kb.clients_menu(peers))


# ── заметки (FSM) ──
@dp.callback_query(F.data.startswith("cl_note:"))
async def cb_client_note(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    await state.set_state(Flow.note_text)
    await state.update_data(name=p.name, idx=idx)
    cur = f"\n\nТекущая заметка: <i>{esc(p.note)}</i>" if p.note else ""
    await safe_edit(
        cq,
        f"Пришли текст заметки для <b>{esc(p.name)}</b> сообщением.\n"
        f"До 200 символов. Чтобы включить мониторинг активности, добавь "
        f"<code>{core.MONITOR_TAG}</code> в текст.\n"
        f"Пустое сообщение или <code>-</code> — очистить заметку." + cur,
        kb.back_button(f"client:{idx}"),
    )
    await cq.answer()


@dp.message(Flow.note_text)
async def msg_note(msg: Message, state: FSMContext) -> None:
    if not authorized(msg.from_user.id):
        return await deny(msg)
    data = await state.get_data()
    await state.clear()
    txt = (msg.text or "").strip()
    if txt == "-":
        txt = ""
    ok, res = await asyncio.to_thread(core.set_note, data["name"], txt)
    mon = core.MONITOR_TAG.lower() in txt.lower()
    extra = f"\n🔔 Мониторинг активности включён ({core.MONITOR_TAG})" if mon else ""
    await msg.answer(("✅ " if ok else "❌ ") + esc(res) + extra)
    p = _peer_by_idx(data["idx"])
    if p:
        await msg.answer(client_card_text(p), reply_markup=_card_kb(data["idx"], p))


# ── WARP на клиента ──
@dp.callback_query(F.data == "warp_not_installed")
async def cb_warp_not_installed(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("WARP не установлен. Установи через Туннели → WARP или sudo awg2.",
                    show_alert=True)


@dp.callback_query(F.data.startswith("cl_warp_on:"))
async def cb_warp_on(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    ok, msg = await asyncio.to_thread(core.warp_enable_client, p.name)
    await cq.answer(msg, show_alert=not ok)
    p = _peer_by_idx(idx)
    await safe_edit(cq, client_card_text(p), _card_kb(idx, p))


@dp.callback_query(F.data.startswith("cl_warp_off:"))
async def cb_warp_off(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    ok, msg = await asyncio.to_thread(core.warp_disable_client, p.name)
    await cq.answer(msg, show_alert=not ok)
    p = _peer_by_idx(idx)
    await safe_edit(cq, client_card_text(p), _card_kb(idx, p))


# ── DNS upstream (серверный DNSCrypt) ──
@dp.callback_query(F.data == "dns_upstream")
async def cb_dns_upstream(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    if not core.dnscrypt_installed():
        return await cq.answer("Шифрованный DNS не установлен. Сначала DNS: установить.",
                               show_alert=True)
    cur = core.get_dns_upstream() or "—"
    await safe_edit(cq, "<b>🔀 Резолверы DNSCrypt</b>\n\n"
                        f"Текущие: <code>{esc(cur)}</code>\n\n"
                        "Выбери upstream (применится сразу, сервис перезапустится):",
                    kb.dns_upstream_choices())
    await cq.answer()


@dp.callback_query(F.data.startswith("dns_up:"))
async def cb_dns_up_set(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    key = cq.data.split(":")[1]
    await cq.answer("Применяю и перезапускаю DNSCrypt…")
    ok, msg = await asyncio.to_thread(core.set_dns_upstream, key)
    cur = core.get_dns_upstream() or "—"
    icon = "✅" if ok else "❌"
    await safe_edit(cq, f"{icon} {esc(msg)}\n\nТекущие: <code>{esc(cur)}</code>",
                    kb.dns_upstream_choices())


@dp.callback_query(F.data == "expire")
async def cb_expire(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(cq, "<b>⏳ Сроки действия клиентов</b>", kb.expire_menu())
    await cq.answer()


@dp.callback_query(F.data == "exp_list")
async def cb_exp_list(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    peers = [p for p in core.list_peers() if p.expires]
    if not peers:
        await safe_edit(cq, "Нет клиентов со сроком — все бессрочные.", kb.expire_menu())
        return await cq.answer()
    lines = ["<b>Клиенты со сроком:</b>\n"]
    now = int(time.time())
    for p in peers:
        when = datetime.fromtimestamp(p.expires).strftime("%Y-%m-%d %H:%M")
        st = "🚫" if p.blocked else ("⏰" if p.expires > now else "❗️истёк")
        lines.append(f"{st} <b>{esc(p.name)}</b> — {when}")
    await safe_edit(cq, "\n".join(lines), kb.expire_menu())
    await cq.answer()


@dp.callback_query(F.data.startswith("cl_exp:"))
async def cb_cl_exp(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    cur = "♾ бессрочно"
    if p.expires:
        cur = "до " + datetime.fromtimestamp(p.expires).strftime("%Y-%m-%d %H:%M")
    await safe_edit(cq, f"Срок для <b>{esc(p.name)}</b> (сейчас: {cur}):",
                    kb.expire_choices(idx))
    await cq.answer()


@dp.callback_query(F.data.startswith("exp_set:"))
async def cb_exp_set(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    _, idx_s, spec = cq.data.split(":")
    idx = int(idx_s)
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    ts = core.parse_duration(spec)
    ok, msg = core.set_expire(p.name, ts)
    await cq.answer(msg, show_alert=not ok)
    p = _peer_by_idx(idx)
    await safe_edit(cq, client_card_text(p), _card_kb(idx, p))


@dp.callback_query(F.data.startswith("exp_clear:"))
async def cb_exp_clear(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    ok, msg = core.clear_expire(p.name)
    await cq.answer(msg, show_alert=not ok)
    p = _peer_by_idx(idx)
    await safe_edit(cq, client_card_text(p), _card_kb(idx, p))


@dp.callback_query(F.data.startswith("exp_custom:"))
async def cb_exp_custom(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    idx = int(cq.data.split(":")[1])
    p = _peer_by_idx(idx)
    if not p:
        return await cq.answer("Клиент не найден", show_alert=True)
    await state.set_state(Flow.expire_date)
    await state.update_data(name=p.name, idx=idx)
    await safe_edit(cq, "Введи дату в формате <code>YYYY-MM-DD HH:MM</code>\n"
                        "или длительность: <code>1h</code>, <code>3d</code>, <code>2w</code>.",
                    kb.back_button(f"cl_exp:{idx}"))
    await cq.answer()


@dp.message(Flow.expire_date)
async def msg_exp_custom(msg: Message, state: FSMContext) -> None:
    if not authorized(msg.from_user.id):
        return await deny(msg)
    data = await state.get_data()
    await state.clear()
    ts = core.parse_duration((msg.text or "").strip())
    if not ts:
        await msg.answer("❌ Не распознал дату. Пример: <code>2026-12-31 23:59</code> или <code>7d</code>.")
        return
    ok, text = core.set_expire(data["name"], ts)
    await msg.answer(("✅ " if ok else "❌ ") + esc(text))
    p = _peer_by_idx(data["idx"])
    if p:
        await msg.answer(client_card_text(p), reply_markup=_card_kb(data["idx"], p))


@dp.callback_query(F.data == "exp_purge_confirm")
async def cb_exp_purge_confirm(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    now = int(time.time())
    victims = [p for p in core.list_peers() if p.expires and p.expires <= now and p.blocked]
    if not victims:
        await cq.answer("Нет просроченных клиентов", show_alert=True)
        return
    names = "\n".join(f"• {esc(p.name)}" for p in victims)
    await safe_edit(cq, f"Удалить НАВСЕГДА просроченных:\n{names}",
                    kb.confirm(yes_cb="exp_purge_ok", no_cb="expire"))
    await cq.answer()


@dp.callback_query(F.data == "exp_purge_ok")
async def cb_exp_purge_ok(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    now = int(time.time())
    victims = [p for p in core.list_peers() if p.expires and p.expires <= now and p.blocked]
    cnt = 0
    for p in victims:
        ok, _ = core.delete_client(p.name)
        cnt += int(ok)
    await cq.answer(f"Удалено: {cnt}", show_alert=True)
    await safe_edit(cq, "<b>⏳ Сроки действия клиентов</b>", kb.expire_menu())


# ───────────────────────── рестарт ─────────────────────────
@dp.callback_query(F.data == "restart_confirm")
async def cb_restart_confirm(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(cq, "Перезапустить интерфейс awg0?\nКлиенты переподключатся автоматически.",
                    kb.confirm(yes_cb="restart_ok", no_cb="menu", danger=False))
    await cq.answer()


@dp.callback_query(F.data == "restart_ok")
async def cb_restart_ok(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Перезапускаю…")
    ok, msg = await asyncio.to_thread(core.restart_iface)
    await safe_edit(cq, ("✅ " if ok else "❌ ") + esc(msg), kb.back_button("menu"))


# ───────────────────────── туннели / обслуживание (через awg2) ─────────────────────────
@dp.callback_query(F.data == "tunnels")
async def cb_tunnels(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    note = "" if wrapper.available() else "\n\n⚠️ Модуль pexpect не установлен — операции недоступны."
    await safe_edit(cq, "<b>🛡 Туннели</b>\nWARP и шифрованный DNS." + note,
                    kb.tunnels_menu())
    await cq.answer()


TUNNEL_ACTIONS = {
    "t_warp_install": "warp_install",
    "t_warp_remove": "warp_remove", "t_dns_install": "dns_install",
    "t_dns_remove": "dns_remove",
}


@dp.callback_query(F.data == "t_warp_status")
async def cb_warp_status(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Читаю статус WARP…")
    txt = await asyncio.to_thread(core.warp_status)
    await safe_edit(cq, f"<b>🌐 WARP</b>\n\n{esc(txt)}", kb.tunnels_menu())

@dp.callback_query(F.data == "t_warp_restart")
async def cb_warp_restart(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Жёсткий рестарт WARP…")
    ok, msg = await asyncio.to_thread(core.warp_hard_restart)
    icon = "✅" if ok else "❌"
    await safe_edit(cq, f"<b>{icon} WARP рестарт</b>\n\n<pre>{esc(msg)}</pre>", kb.tunnels_menu())


@dp.callback_query(F.data == "t_dns_status")
async def cb_dns_status(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Читаю статус DNS…")
    txt = await asyncio.to_thread(core.dns_status)
    await safe_edit(cq, f"<b>🌐 Шифрованный DNS</b>\n\n{esc(txt)}", kb.tunnels_menu())


@dp.callback_query(F.data.in_(TUNNEL_ACTIONS.keys()))
async def cb_tunnel_action(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    if not wrapper.available():
        return await cq.answer("Нужен pexpect и установленный awg2", show_alert=True)
    scenario = TUNNEL_ACTIONS[cq.data]
    await cq.answer("Выполняю в awg2… до минуты.")
    keys = wrapper.SCENARIOS.get(scenario, ["0"])
    ok, out = await asyncio.to_thread(wrapper.run_menu_sequence, keys)
    tail = out[-1500:] if out else "(нет вывода)"
    note = "" if ok else "\n\n⚠️ Если не сработало — выполни в консоли: sudo awg2"
    await safe_edit(cq, f"<b>Результат:</b>\n<pre>{esc(tail)}</pre>{note}", kb.tunnels_menu())


@dp.callback_query(F.data == "maint")
async def cb_maint(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(cq, "<b>🔧 Обслуживание</b>", kb.maint_menu())
    await cq.answer()


@dp.callback_query(F.data == "show_server_conf")
async def cb_show_conf(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    if not core.server_installed():
        return await cq.answer("Конфиг не найден", show_alert=True)
    data = open(core.SERVER_CONF, "rb").read()
    await cq.message.answer_document(
        BufferedInputFile(data, filename="awg0.conf"),
        caption="⚠️ Содержит приватные ключи — храни безопасно.",
    )
    await cq.answer()


@dp.callback_query(F.data == "show_logs")
async def cb_show_logs(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    rc, out, _ = await asyncio.to_thread(core.run, ["tail", "-n", "40", "/var/log/awg-manager.log"])
    txt = out.strip() or "(лог пуст)"
    await safe_edit(cq, f"<pre>{esc(txt[-3500:])}</pre>", kb.maint_menu())
    await cq.answer()


# ───────────────────────── управление самим ботом ─────────────────────────
@dp.callback_query(F.data == "botctl")
async def cb_botctl(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(
        cq,
        "<b>🤖 Управление ботом</b>\n\n"
        "Те же действия доступны в консоли: <code>sudo awg-bot</code>.",
        kb.botctl_menu(),
    )
    await cq.answer()


@dp.callback_query(F.data == "bot_status")
async def cb_bot_status(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Читаю статус…")
    rc, out, _ = await asyncio.to_thread(core.run, ["awg-bot", "status"])
    bl = core.bot_version_local()
    a2l = core.awg2_version_local()
    head = f"🤖 Версия бота: <b>{esc(bl)}</b>\n🛠 awg2: <b>{esc(a2l)}</b>\n\n"
    body = out.strip() or "awg-bot status недоступен"
    await safe_edit(cq, head + f"<pre>{esc(body[-3000:])}</pre>", kb.botctl_menu())


@dp.callback_query(F.data == "bot_logs")
async def cb_bot_logs(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    rc, out, _ = await asyncio.to_thread(
        core.run, ["journalctl", "-u", "awg-bot.service", "--no-pager", "-n", "50"])
    txt = out.strip() or "(лог пуст)"
    await safe_edit(cq, f"<pre>{esc(txt[-3500:])}</pre>", kb.botctl_menu())
    await cq.answer()


@dp.callback_query(F.data == "bot_update")
async def cb_bot_update(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Проверяю версии…")
    # читаем версии (сетевые — в потоке, чтобы не блокировать)
    bl = core.bot_version_local()
    br = await asyncio.to_thread(core.bot_version_remote)
    a2l = core.awg2_version_local()
    a2r = await asyncio.to_thread(core.awg2_version_remote)

    def arrow(loc, rem):
        if rem in ("?", loc):
            return f"<code>{esc(loc)}</code>" + ("  (актуально)" if rem == loc else "")
        return f"<code>{esc(loc)}</code> → <code>{esc(rem)}</code>  ⬆️"

    bot_upd = br not in ("?", bl)
    txt = (
        "⬆️ <b>Обновление</b>\n\n"
        f"🤖 Бот: {arrow(bl, br)}\n"
        f"🛠 awg2: {arrow(a2l, a2r)}\n\n"
    )
    if bot_upd:
        txt += "Обновить бота до новой версии? Бот перезапустится, токен сохранится."
    else:
        txt += ("Бот уже актуален. Можно переустановить принудительно "
                "(на случай повреждённых файлов).")
    # awg2 обновляется отдельно — через консоль, мы его не трогаем
    if a2r not in ("?", a2l):
        txt += "\n\nℹ️ Для awg2 есть обновление — оно ставится в консоли: <code>sudo awg2</code> → пункт 8."
    await safe_edit(cq, txt, kb.confirm(yes_cb="bot_update_ok", no_cb="botctl", danger=False))


@dp.callback_query(F.data == "bot_update_ok")
async def cb_bot_update_ok(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Обновляю бота из GitHub…")
    await safe_edit(cq, "⏳ Тяну свежую версию и перезапускаю бота…\n"
                        "Через ~20-30 сек нажми /start — увидишь новую версию.\n\n"
                        "Если бот не ответит за минуту — подними вручную:\n"
                        "<code>sudo systemctl restart awg-bot</code>", None)
    # ВАЖНО: обновление останавливает наш же сервис в процессе. setsid не спасает —
    # systemd гасит весь cgroup сервиса. Поэтому запускаем обновление как
    # ОТДЕЛЬНЫЙ transient-юнит через systemd-run: он живёт вне cgroup awg-bot,
    # переживает остановку бота и докатывает деплой+рестарт до конца.
    ok, out, err = await asyncio.to_thread(
        core.run,
        ["systemd-run", "--collect", "--unit=awg-bot-selfupdate",
         "--property=Type=oneshot",
         "bash", "-lc", "awg-bot update >/var/log/awg-bot-update.log 2>&1"]
    )
    if not ok:
        # запасной путь, если systemd-run недоступен
        await asyncio.to_thread(
            core.run,
            ["bash", "-c", "setsid awg-bot update >/var/log/awg-bot-update.log 2>&1 &"]
        )


@dp.callback_query(F.data == "bot_restart_confirm")
async def cb_bot_restart_confirm(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(cq, "Перезапустить бота? Текущая сессия меню прервётся, "
                        "после рестарта нажми /start.",
                    kb.confirm(yes_cb="bot_restart_ok", no_cb="botctl", danger=False))
    await cq.answer()


@dp.callback_query(F.data == "bot_restart_ok")
async def cb_bot_restart_ok(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Перезапускаю бота…")
    await safe_edit(cq, "↻ Перезапуск бота… нажми /start через несколько секунд.",
                    None)
    await asyncio.to_thread(core.run, ["systemctl", "restart", "awg-bot.service"])


@dp.callback_query(F.data == "bot_uninstall_confirm")
async def cb_bot_uninstall_confirm(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(cq,
        "🗑 <b>Удалить бота полностью?</b>\n\n"
        "Будут остановлены и удалены сервис, код в /opt/awg-bot и команда awg-bot. "
        "Конфиг VPN и клиенты <b>не трогаются</b> — только бот.\n\n"
        "Токен в /etc/awg-bot.conf сохранится (на случай переустановки). "
        "После удаления бот перестанет отвечать.",
        kb.confirm(yes_cb="bot_uninstall_ok", no_cb="botctl", danger=True))
    await cq.answer()


@dp.callback_query(F.data == "bot_uninstall_ok")
async def cb_bot_uninstall_ok(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await cq.answer("Удаляю бота…")
    await safe_edit(cq,
        "🗑 Удаляю бота…\n\nСервис остановится через пару секунд. "
        "Спасибо, что пользовался! Переустановить можно через awg2 → пункт 6 "
        "или <code>sudo awg-bot</code>.", None)
    # запускаем удаление в фоне через management-скрипт (он сам остановит сервис).
    # nohup + setsid, чтобы процесс пережил остановку нашего сервиса.
    await asyncio.to_thread(
        core.run,
        ["bash", "-c", "setsid awg-bot uninstall --yes >/var/log/awg-bot-uninstall.log 2>&1 &"]
    )


@dp.callback_query(F.data == "backup")
async def cb_backup_menu(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await safe_edit(cq,
        "<b>💾 Бэкап / Восстановление</b>\n\n"
        "📥 <b>Создать</b> — бот пришлёт архив с конфигом сервера и всеми клиентами.\n"
        "📤 <b>Восстановить</b> — пришли ранее сохранённый архив, бот вернёт конфиги.\n\n"
        "⚠️ Архив содержит приватные ключи — храни в надёжном месте.",
        kb.backup_menu())
    await cq.answer()


@dp.callback_query(F.data == "backup_create")
async def cb_backup_create(cq: CallbackQuery) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    import tarfile
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        if os.path.isfile(core.SERVER_CONF):
            tar.add(core.SERVER_CONF, arcname="awg0.conf")
        for f in os.listdir(core.CLIENT_DIR):
            if f.endswith("_awg2.conf"):
                tar.add(os.path.join(core.CLIENT_DIR, f), arcname=f"clients/{f}")
    buf.seek(0)
    fname = f"awg_backup_{datetime.now():%Y%m%d_%H%M}.tar.gz"
    await cq.message.answer_document(
        BufferedInputFile(buf.read(), filename=fname),
        caption="💾 Бэкап: конфиг сервера + все клиенты.\n⚠️ Содержит приватные ключи.",
    )
    await cq.answer("Бэкап готов")


@dp.callback_query(F.data == "backup_restore")
async def cb_backup_restore(cq: CallbackQuery, state: FSMContext) -> None:
    if not authorized(cq.from_user.id):
        return await deny(cq)
    await state.set_state(Flow.await_backup)
    await safe_edit(cq,
        "📤 <b>Восстановление</b>\n\n"
        "Пришли сюда файл бэкапа <code>awg_backup_*.tar.gz</code> "
        "(тот, что бот присылал при создании).\n\n"
        "⚠️ Текущий конфиг сервера и клиенты будут заменены содержимым архива. "
        "Перед заменой бот сделает резервную копию для отката.\n\n"
        "Для отмены нажми «Назад».",
        kb.back_button("backup"))
    await cq.answer()


@dp.message(Flow.await_backup, F.document)
async def msg_backup_file(msg: Message, state: FSMContext) -> None:
    if not authorized(msg.from_user.id):
        return await deny(msg)
    await state.clear()
    doc = msg.document
    if not doc.file_name.endswith(".tar.gz"):
        await msg.answer("❌ Это не похоже на бэкап (нужен .tar.gz). Попробуй ещё раз "
                         "через Бэкап → Восстановить.")
        return
    if doc.file_size and doc.file_size > 10 * 1024 * 1024:
        await msg.answer("❌ Файл слишком большой (>10 МБ) — это вряд ли наш бэкап.")
        return
    wait = await msg.answer("⏳ Скачиваю и восстанавливаю…")
    try:
        file = await bot.get_file(doc.file_id)
        buf = io.BytesIO()
        await bot.download_file(file.file_path, buf)
        data = buf.getvalue()
    except Exception as e:
        await wait.edit_text(f"❌ Не удалось скачать файл: {esc(str(e))}")
        return
    ok, res = await asyncio.to_thread(core.restore_backup, data)
    await wait.edit_text(("✅ " if ok else "❌ ") + esc(res))
    if ok:
        peers = core.list_peers()
        await msg.answer(f"<b>👥 Клиенты ({len(peers)})</b>", reply_markup=kb.clients_menu(peers))


@dp.message(Flow.await_backup)
async def msg_backup_notfile(msg: Message, state: FSMContext) -> None:
    if not authorized(msg.from_user.id):
        return await deny(msg)
    await msg.answer("Жду файл бэкапа (.tar.gz). Пришли его как документ "
                     "или нажми «Назад» в меню бэкапа для отмены.")


# ───────────────────────── запуск ─────────────────────────
async def main() -> None:
    from . import monitor
    log.info("Бот запущен. Админы: %s", CFG.admins)
    # одноразовая чистка legacy "# note=" из конфига (баг ранних версий)
    try:
        n = core.cleanup_legacy_notes()
        if n:
            log.info("Вычищено legacy note= строк из конфига: %s", n)
    except Exception as e:
        log.warning("cleanup_legacy_notes: %s", e)
    # фоновый мониторинг активности клиентов с #ping
    asyncio.create_task(monitor.monitor_loop(bot, CFG.admins))
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
