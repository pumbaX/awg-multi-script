"""keyboards.py — все инлайн-клавиатуры. Управление только кнопками."""

from __future__ import annotations

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup
from aiogram.utils.keyboard import InlineKeyboardBuilder

from . import core


def profile_choices() -> InlineKeyboardMarkup:
    """Выбор профиля мимикрии при создании клиента (как в awg2 Pro)."""
    b = InlineKeyboardBuilder()
    b.button(text="🔐 TLS ClientHello (рекомендуется)", callback_data="prof:tls")
    b.button(text="🌐 DNS Query", callback_data="prof:dns")
    b.button(text="📞 SIP (VoIP)", callback_data="prof:sip")
    b.button(text="⚡ QUIC", callback_data="prof:quic")
    b.button(text="🔇 Базовый (без I1-I5)", callback_data="prof:basic")
    b.button(text="‹ Отмена", callback_data="clients")
    b.adjust(1, 1, 1, 1, 1, 1)
    return b.as_markup()


def main_menu(installed: bool) -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    if installed:
        b.button(text="👥 Клиенты", callback_data="clients")
        b.button(text="📊 Статус сервера", callback_data="status")
        b.button(text="⏳ Сроки действия", callback_data="expire")
        b.button(text="🛡 Туннели (WARP/DNS)", callback_data="tunnels")
        b.button(text="💾 Бэкап / Рестор", callback_data="backup")
        b.button(text="↻ Перезапуск awg0", callback_data="restart_confirm")
        b.button(text="🔧 Обслуживание", callback_data="maint")
        b.button(text="❤️ Поддержать", url="https://t.me/awgToolza/156/157")
        b.adjust(2, 2, 2, 2)
    else:
        b.button(text="⚙️ Сервер не установлен — открыть консоль awg2",
                 callback_data="not_installed")
        b.adjust(1)
    return b.as_markup()


def back_button(to: str = "menu") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="‹ Назад", callback_data=to)]
    ])


CLIENTS_PER_PAGE = 12  # по 6 строк в 2 столбца


def clients_menu(peers: list[core.Peer], page: int = 0,
                 sort_active: bool = False) -> InlineKeyboardMarkup:
    """
    Список клиентов в 2 столбца с пагинацией.
    Индекс в callback ссылается на позицию в ИСХОДНОМ списке core.list_peers(),
    чтобы открывался правильный клиент независимо от сортировки/страницы.
    """
    b = InlineKeyboardBuilder()
    b.button(text="➕ Добавить", callback_data="client_add")
    b.button(text="🔄 Обновить", callback_data=f"clpage:{page}:{int(sort_active)}")

    # порядок отображения: с сохранением реального индекса
    indexed = list(enumerate(peers))  # (real_idx, peer)
    if sort_active:
        # сначала онлайн, потом офлайн, потом заблокированные
        def rank(ip):
            p = ip[1]
            return (0 if p.online else (2 if p.blocked else 1), p.name.lower())
        indexed = sorted(indexed, key=rank)

    total = len(indexed)
    pages = max(1, (total + CLIENTS_PER_PAGE - 1) // CLIENTS_PER_PAGE)
    page = max(0, min(page, pages - 1))
    chunk = indexed[page * CLIENTS_PER_PAGE:(page + 1) * CLIENTS_PER_PAGE]

    # кнопка переключения сортировки
    sort_label = "✓ Активные сверху" if sort_active else "↕️ Сорт. по активным"
    b.button(text=sort_label, callback_data=f"clpage:{page}:{0 if sort_active else 1}")

    for real_idx, p in chunk:
        dot = "🟢" if p.online else ("🚫" if p.blocked else "⚪️")
        b.button(text=f"{dot} {p.name}", callback_data=f"client:{real_idx}")

    # навигация по страницам (если больше одной)
    nav = []
    if pages > 1:
        if page > 0:
            b.button(text="‹ Назад", callback_data=f"clpage:{page-1}:{int(sort_active)}")
            nav.append(1)
        b.button(text=f"{page+1}/{pages}", callback_data="noop")
        nav.append(1)
        if page < pages - 1:
            b.button(text="Вперёд ›", callback_data=f"clpage:{page+1}:{int(sort_active)}")
            nav.append(1)

    b.button(text="‹ В меню", callback_data="menu")

    # раскладка: [Добавить|Обновить], [сортировка], клиенты по 2,
    # затем навигация в ряд, затем В меню
    n_clients = len(chunk)
    rows = [2, 1]
    rows += [2] * (n_clients // 2)
    if n_clients % 2:
        rows += [1]
    if nav:
        rows += [len(nav)]
    rows += [1]
    b.adjust(*rows)
    return b.as_markup()


def client_card(idx: int, monitored: bool = False, warp_state=None) -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.button(text="📥 Скачать .conf", callback_data=f"cl_conf:{idx}")
    b.button(text="📱 QR-код", callback_data=f"cl_qr:{idx}")
    b.button(text="⏳ Срок", callback_data=f"cl_exp:{idx}")
    # WARP-кнопка: текст зависит от состояния (None = WARP не установлен)
    if warp_state is True:
        b.button(text="☁ WARP: выкл", callback_data=f"cl_warp_off:{idx}")
    elif warp_state is False:
        b.button(text="☁ WARP: вкл", callback_data=f"cl_warp_on:{idx}")
    else:
        b.button(text="☁ WARP (не установлен)", callback_data="warp_not_installed")
    note_label = "📝 Заметка" + (" 🔔" if monitored else "")
    b.button(text=note_label, callback_data=f"cl_note:{idx}")
    b.button(text="✏️ Переименовать", callback_data=f"cl_ren:{idx}")
    b.button(text="🗑 Удалить", callback_data=f"cl_del:{idx}")
    b.button(text="‹ К списку", callback_data="clients")
    b.adjust(2, 2, 2, 1, 1)
    return b.as_markup()


def dns_upstream_choices() -> InlineKeyboardMarkup:
    """Выбор upstream-резолверов DNSCrypt (серверный шифрованный DNS)."""
    from . import core
    b = InlineKeyboardBuilder()
    for key, (label, _servers, _nf) in core.DNS_UPSTREAMS.items():
        b.button(text=label, callback_data=f"dns_up:{key}")
    b.button(text="‹ Назад", callback_data="tunnels")
    b.adjust(1, 1, 1, 1, 1, 1)
    return b.as_markup()


def confirm(yes_cb: str, no_cb: str = "menu", danger: bool = True) -> InlineKeyboardMarkup:
    yes = "❌ Да, удалить" if danger else "✓ Да"
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text=yes, callback_data=yes_cb),
        InlineKeyboardButton(text="‹ Отмена", callback_data=no_cb),
    ]])


def expire_choices(idx: int) -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    for label, spec in [("1 час", "1h"), ("1 день", "1d"),
                        ("7 дней", "7d"), ("30 дней", "30d")]:
        b.button(text=label, callback_data=f"exp_set:{idx}:{spec}")
    b.button(text="♾ Бессрочно (снять срок)", callback_data=f"exp_clear:{idx}")
    b.button(text="📅 Своя дата", callback_data=f"exp_custom:{idx}")
    b.button(text="‹ Назад", callback_data=f"client:{idx}")
    b.adjust(2, 2, 1, 1, 1)
    return b.as_markup()


def expire_menu() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.button(text="📋 Список со сроками", callback_data="exp_list")
    b.button(text="🧹 Удалить просроченные", callback_data="exp_purge_confirm")
    b.button(text="‹ Назад", callback_data="menu")
    b.adjust(1, 1, 1)
    return b.as_markup()


def tunnels_menu() -> InlineKeyboardMarkup:
    # Две колонки по 3 кнопки: слева DNS, справа WARP.
    # adjust(2,2,2,1) даёт пары построчно: [DNS статус | WARP статус],
    # [DNS установить | WARP установить], [DNS удалить | WARP удалить], [Назад].
    b = InlineKeyboardBuilder()
    b.button(text="🌐 DNS: статус", callback_data="t_dns_status")
    b.button(text="🛡 WARP: статус", callback_data="t_warp_status")
    b.button(text="🌐 DNS: установить", callback_data="t_dns_install")
    b.button(text="🛡 WARP: установить", callback_data="t_warp_install")
    b.button(text="🌐 DNS: удалить", callback_data="t_dns_remove")
    b.button(text="🛡 WARP: удалить", callback_data="t_warp_remove")
    b.button(text="🔄 WARP Hard Restart", callback_data="t_warp_restart")
    b.button(text="🔀 DNS: сменить резолверы", callback_data="dns_upstream")
    b.button(text="‹ Назад", callback_data="menu")
    b.adjust(2, 2, 2, 1, 1, 1)
    return b.as_markup()


def backup_menu() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.button(text="📥 Создать бэкап", callback_data="backup_create")
    b.button(text="📤 Восстановить из файла", callback_data="backup_restore")
    b.button(text="‹ Назад", callback_data="menu")
    b.adjust(1, 1, 1)
    return b.as_markup()


def maint_menu() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.button(text="📄 Конфиг сервера (скачать)", callback_data="show_server_conf")
    b.button(text="📜 Логи awg2", callback_data="show_logs")
    b.button(text="🤖 Управление ботом", callback_data="botctl")
    b.button(text="‹ Назад", callback_data="menu")
    b.adjust(1, 1, 1, 1)
    return b.as_markup()


def botctl_menu() -> InlineKeyboardMarkup:
    """Меню управления самим ботом (аналог консольного awg-bot)."""
    b = InlineKeyboardBuilder()
    b.button(text="⬆️ Обновить бота (сохранив токен)", callback_data="bot_update")
    b.button(text="📊 Статус бота", callback_data="bot_status")
    b.button(text="📜 Логи бота (50 строк)", callback_data="bot_logs")
    b.button(text="↻ Перезапустить бота", callback_data="bot_restart_confirm")
    b.button(text="🗑 Удалить бота", callback_data="bot_uninstall_confirm")
    b.button(text="‹ Назад", callback_data="maint")
    b.adjust(1, 1, 1, 1, 1, 1)
    return b.as_markup()
