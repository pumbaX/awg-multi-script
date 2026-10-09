"""Главное меню — те же девять пунктов, что в меню awg2, и сводка сервера."""

from __future__ import annotations

from aiogram import Bot, Router
from aiogram.filters import CommandObject, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import access, admins, api, ui, webapp
from ..ui import esc

router = Router()
act = ui.Actions(router, "main")

PROFILE = {"lite": "AmneziaVPN", "pro": "Мощный", "standard": "Standard"}
SUPPORT_URL = "https://t.me/awgToolza/156/157"


def plural(n: int, one: str, few: str, many: str) -> str:
    """1 клиент, 2 клиента, 5 клиентов."""
    n = abs(int(n))
    if n % 10 == 1 and n % 100 != 11:
        return one
    return few if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14 else many


def block(*lines: str) -> str:
    """Блок-цитата Telegram: цветная полоса слева, пустые строки пропускаются."""
    body = "\n".join(line for line in lines if line)
    return f"<blockquote>{body}</blockquote>" if body else ""


def _attention(d: dict) -> str:
    """То, что требует действий: только когда есть что сказать."""
    c, s = d.get("components") or {}, d.get("server") or {}
    return block(
        "⚠️ awg0 не поднят — <i>Сервер → 🛠 Починить</i>" if s.get("exists") and not s.get("up") else "",
        f"▲ {esc(c['reboot'])}" if c.get("installed") and c.get("reboot") else "",
        f"⚠️ Ядро {esc(c['kernel_gap'])} без модуля AWG — после перезагрузки VPN не поднимется: "
        "<i>Сервер → Модуль ядра → Под все ядра</i>" if c.get("kernel_gap") else "",
        f"⬆️ Доступна {esc(d['update'])} — <i>Обновление</i>" if d.get("update") else "",
    )


def _server(d: dict) -> str:
    c, s = d.get("components") or {}, d.get("server") or {}
    if not c.get("installed"):
        return block("❌ Компоненты не установлены", "<i>Сервер → 📦 Компоненты</i>")
    module = f"🧩 модуль <code>{esc(c.get('module') or '?')}</code> " + (
        f"· ⬆️ есть {esc(c['module_update'])}" if c.get("module_update") else "✓")
    if not s.get("exists"):
        return block("⚪️ Сервер не создан — <i>Сервер → Создать сервер</i>", module)
    n, online = int(s.get("clients") or 0), int(s.get("online") or 0)
    return block(
        f"{'🟢' if s.get('up') else '🔴'} AWG {esc(s.get('proto', '?'))} · "
        f"{esc(PROFILE.get(s.get('profile', ''), s.get('profile', '')))} · порт {s.get('port')}",
        f"👥 {n} {plural(n, 'клиент', 'клиента', 'клиентов')} · {online} онлайн",
        module,
    )


def _tunnels(d: dict) -> str:
    """Работающие туннели первыми, затем настроенные и выключенные."""
    t = d.get("tunnels") or {}
    names = [("warp", "WARP"), ("xray", "Xray"), ("tun2socks", "tun2socks"),
             ("exits", "Exit-ноды WG"), ("dns", "DNS")]
    items = [(t[k], n) for k, n in names if t.get(k, "none") != "none"]
    if d.get("wgobf", "none") != "none":
        items.append((d["wgobf"], "WG+обф."))
    items.sort(key=lambda it: it[0] != "up")
    parts = [f"{ui.state_icon(st)} {n}" for st, n in items]
    if t.get("cascade"):
        parts.append(f"🔀 каскад {t['cascade']}")
    return block("  ·  ".join(parts) or "Туннели не настроены")


def status_text(d: dict) -> str:
    channel = "бета" if d.get("channel") == "beta" else "стабильный"
    return "\n".join(filter(None, [
        f"<b>AWG Toolza</b>  {esc(d.get('version', ''))} · {channel}",
        _attention(d),
        block(f"🖥 <b>{esc(d.get('host', ''))}</b> · <code>{esc(d.get('ip', ''))}</code>", esc(d.get("os", ""))),
        _server(d),
        _tunnels(d),
    ]))


def menu_kb(d: dict) -> ui.InlineKeyboardMarkup:
    """Разделы awg2 в два столбца, в том же порядке (и веб-панель — «w» в
    меню awg2); ниже — «Обновить» и «Поддержать» во всю ширину."""
    return ui.kb(
        ("🖥 Сервер", "srv"),
        ("👥 Клиенты", "cl"),
        ("🩺 Диагностика", "diag"),
        ("💾 Бэкапы", "bk"),
        ("🌐 Туннели и DNS", "tun"),
        ("🤖 Telegram-бот", "botm"),
        ("🗑 Удаление", "del"),
        (f"⬆️ Есть {d['update']}" if d.get("update") else "⬆️ Обновление", "upd"),
        ("🛡 Обфускатор", "wo"),
        ("💻 Веб-панель", "web"),
        ui.Row(("🔄 Обновить", "main")),
        ui.Row(("Поддержать 💚", SUPPORT_URL)),
    )


async def show_menu(target: ui.Target) -> None:
    r = await api.call("status")
    if not r.ok or not isinstance(r.data, dict):
        # Без awg2 остаётся управление самим ботом — через него его и чинят
        await ui.render(target, ui.fail(r, "awg2 недоступен"),
                        ui.kb(("🤖 Telegram-бот", "botm"), ("🔄 Повторить", "main")))
        return
    await ui.render(target, status_text(r.data), menu_kb(r.data))


async def send_menu(bot: Bot, chat_id: int) -> None:
    """Главное меню новым сообщением внизу чата — из панели («Меню бота в
    чат»), когда оно утонуло под конфигами."""
    r = await api.call("status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.show_new(bot, chat_id, ui.fail(r, "awg2 недоступен"),
                          ui.kb(("🤖 Telegram-бот", "botm"), ("🔄 Повторить", "main")))
        return
    await ui.show_new(bot, chat_id, status_text(r.data), menu_kb(r.data))


@act()
async def _menu(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await show_menu(cb)


@router.message(CommandStart())
async def cmd_start(msg: Message, state: FSMContext, command: CommandObject) -> None:
    user = msg.from_user
    if user is None:
        return
    payload = (command.args or "").strip()
    # Приглашение t.me/<бот>?start=inv_<токен>. Действующему админу ссылку не
    # гасим — пусть достанется тому, кого звали.
    if payload.startswith(admins.INVITE_PREFIX) and not access.authorized(user.id):
        ok, res = admins.consume_invite(payload[len(admins.INVITE_PREFIX):], user.id, user.username or "")
        if not ok:
            await msg.answer(f"⛔️ {esc(res)}")
            return
        who = f"@{esc(user.username)}" if user.username else f"<code>{user.id}</code>"
        for owner in access.owners():
            try:
                await msg.bot.send_message(owner, f"👮 Новый админ по приглашению: {who}")  # type: ignore[union-attr]
            except Exception:                                   # noqa: BLE001
                pass
        await msg.answer("✅ Приглашение принято — доступ к боту выдан.")
    if not access.authorized(user.id):
        await msg.answer("⛔️ Доступ запрещён.\n"
                         f"Твой Telegram ID: <code>{user.id}</code>\n"
                         "Владелец сервера может добавить его в ADMIN_ID или прислать приглашение.")
        return
    await state.clear()
    if webapp.SERVER.running and msg.bot:
        # Приглашённый недавно админ тоже получает панель в «Меню»
        await webapp.SERVER.menu_for(msg.bot, user.id)
    await show_menu(msg)
