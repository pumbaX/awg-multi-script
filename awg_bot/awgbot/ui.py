"""ui.py — экраны бота: клавиатуры в два столбца, форматирование, отрисовка.

Каждый экран — текст с пояснениями и кнопки с короткими подписями.
Нажатие кнопки правит её сообщение, ответ на ввод текста приходит новым
сообщением. Бот ничего не удаляет.
"""

from __future__ import annotations

import contextlib
import html
import logging
import re
import time
from typing import Awaitable, Callable, Iterable, Union

from aiogram import Bot, F, Router
from aiogram.client.session.middlewares.base import BaseRequestMiddleware
from aiogram.exceptions import TelegramBadRequest
from aiogram.fsm.context import FSMContext
from aiogram.types import (CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup,
                           Message, WebAppInfo)

from . import access, api, icons

log = logging.getLogger("awgbot.ui")

Target = Union[CallbackQuery, Message]
Button = Union[tuple[str, str], tuple[str, str, str]]   # (текст, данные[, цвет])
TEXT_MAX = 4096

esc = html.escape


# ── Клавиатуры ────────────────────────────────────────────
# Кнопки идут в два столбца. Подписи короткие — в половину экрана телефона;
# длинная (имя клиента, например) встаёт отдельной строкой. Навигация —
# «Назад», «Отмена», «Главное меню», страницы — строкой ниже, парами между
# собой. Row — строка как есть (например, «Да» и «Отмена» рядом).
COLS = 2
WIDE = 17           # ширина подписи, после которой кнопка — во всю строку (проверено на телефоне)


class Row(tuple):
    """Кнопки одной строкой, без раскладки."""

    def __new__(cls, *buttons: Button | None) -> "Row":
        return super().__new__(cls, [b for b in buttons if b])


def width(text: str) -> int:
    """Ширина подписи в «буквах»: эмодзи — за две (и ⏹ ⬆ ▶ ◀ ⏳ тоже —
    Telegram рисует их эмодзи), селекторы вариантов — ноль."""
    n = 0
    for ch in text:
        o = ord(ch)
        if o in (0xFE0F, 0x200D):
            continue
        wide = o >= 0x1F000 or 0x2300 <= o <= 0x23FF or 0x25A0 <= o <= 0x27BF or 0x2B00 <= o <= 0x2BFF
        n += 2 if wide else 1
    return n


def _nav(text: str) -> bool:
    return text.startswith(("◀️", "🏠", "✖️")) or text.endswith("▶️")


def _page(text: str) -> bool:
    return text.startswith("◀️ Стр") or text.endswith("▶️")


# Цвет кнопки (Bot API: style): зелёная — только «Поддержать 💚», остальные
# обычные — красные, синие и зелёные разделы и действия рябили в глазах.
# Третий элемент кнопки задаёт цвет явно ("" — обычная).
def style_of(text: str) -> str:
    return "success" if text.endswith("💚") else ""


def _button(text: str, data: str, style: str | None = None) -> InlineKeyboardButton:
    """Данные вида https://… или tg://… — кнопка-ссылка, webapp:https://… —
    Mini App, иначе колбэк. Иконки включены — эмодзи из начала подписи
    становится иконкой."""
    style = style_of(text) if style is None else style
    kw: dict = {"style": style or None}
    emoji, rest = icons.lead(text)
    icon_id = icons.icon(emoji) if emoji and rest else None
    if icon_id:
        text, kw["icon_custom_emoji_id"] = rest, icon_id
    if data.startswith("webapp:"):
        return InlineKeyboardButton(text=text, web_app=WebAppInfo(url=data[7:]), **kw)
    if data.startswith(("https://", "http://", "tg://")):
        return InlineKeyboardButton(text=text, url=data, **kw)
    return InlineKeyboardButton(text=text, callback_data=data, **kw)


def kb(*items: Button | Iterable[Button] | None) -> InlineKeyboardMarkup:
    """Клавиатура в два столбца. Элемент — (текст, данные), список таких пар,
    Row или None (пропуск: удобно для условных пунктов). Порядок кнопок
    сохраняется: пары складываются слева направо, сверху вниз."""
    rows: list[list[InlineKeyboardButton]] = []
    pending: list[InlineKeyboardButton] = []
    kind = ""

    def flush() -> None:
        rows.extend(pending[i:i + COLS] for i in range(0, len(pending), COLS))
        pending.clear()

    for item in items:
        if not item:
            continue
        if isinstance(item, Row):
            flush()
            rows.append([_button(*b) for b in item])
            continue
        pairs = [item] if isinstance(item, tuple) else [p for p in item if p]
        for b in pairs:
            text = b[0]
            button = _button(*b)
            if width(text) > WIDE:
                flush()
                rows.append([button])
                continue
            k = "page" if _page(text) else "nav" if _nav(text) else "item"
            if pending and k != kind:
                flush()
            kind = k
            pending.append(button)
    flush()
    return InlineKeyboardMarkup(inline_keyboard=rows)


def paged(buttons: list[Button], page: int, nav: Callable[[int], str], size: int = 20) -> list[Button]:
    """Страница списка кнопок и переходы между страницами: у клавиатуры
    Telegram есть предел числа кнопок."""
    pages = max(1, (len(buttons) + size - 1) // size)
    page = min(max(page, 0), pages - 1)
    out = buttons[page * size:(page + 1) * size]
    if page > 0:
        out.append((f"◀️ Стр. {page}", nav(page - 1)))
    if page < pages - 1:
        out.append((f"Стр. {page + 2} ▶️", nav(page + 1)))
    return out


def back(to: str = "main", text: str = "◀️ Назад") -> Button:
    return (text, to)


HOME: Button = ("🏠 Главное меню", "main")


# ── CHANGELOG ─────────────────────────────────────────────
# Раздел версии (update changelog): первая жирная строка — суть релиза в одну
# фразу, её и показывают уведомление и «Что нового».
def _md_plain(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return re.sub(r"\*\*|`", "", text).strip()


def changelog_headline(body: str, limit: int = 160) -> str:
    m = re.search(r"^\*\*(.+?)\*\*\s*$", body or "", re.M | re.S)
    line = " ".join(_md_plain(m.group(1)).split()) if m else ""
    return line if len(line) <= limit else line[:limit - 1].rstrip() + "…"


def changelog_html(body: str) -> str:
    """Тело раздела CHANGELOG → HTML Telegram: подзаголовки — жирным,
    пункты — «•», перенос строки внутри пункта склеивается."""
    out: list[str] = []
    in_head = False                         # жирный абзац-суть: он уже в заголовке
    for raw in (body or "").split("\n"):
        line = raw.rstrip()
        if in_head or (not out and line.startswith("**")):
            in_head = not line.endswith("**") or line == "**"
            continue
        if not line.strip() or re.fullmatch(r"\s*-{3,}\s*", line):
            continue
        if raw.startswith("  ") and out and not line.strip().startswith(("- ", "* ")):
            out[-1] += " " + line.strip()
            continue
        line = line.strip()
        if line.startswith("#"):
            out.append("\n<b>" + esc(_md_plain(line.lstrip("# "))) + "</b>")
        elif line.startswith(("- ", "* ")):
            out.append("• " + line[2:])
        else:
            out.append(line)
    html_lines = []
    for line in out:
        if line.startswith("\n<b>"):
            html_lines.append(line)
            continue
        t = esc(re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line))
        t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
        html_lines.append(re.sub(r"`([^`]+)`", r"<code>\1</code>", t))
    return "\n".join(html_lines).strip()


# ── Текст ─────────────────────────────────────────────────
def pre(text: str, limit: int = 3000, tail: bool = True) -> str:
    """Моноширинный блок. Длинный текст режется: по умолчанию остаётся
    конец — в журналах важны последние строки. Лимит — по уже экранированному
    HTML: «"» становится &quot;, и вывод make/gcc с кавычками иначе вылезал
    за 4096 после esc(), а срез сырого HTML рвал <pre>."""
    text = esc((text or "").strip("\n"))
    if not text:
        return ""
    if len(text) > limit:
        if tail:
            text = text[-limit:]
            # Начать с целой строки (журналы построчные); нет переноса рядом —
            # хотя бы не с огрызка сущности вроде «uot;»
            nl = text.find("\n")
            text = text[nl + 1:] if 0 <= nl < 200 else re.sub(r"^[a-z0-9#]{0,5};", "", text)
            text = "…\n" + text
        else:
            text = re.sub(r"&[^;&]{0,6}$", "", text[:limit]) + "\n…"
    return f"<pre>{text}</pre>"


def clip(text: str, limit: int = TEXT_MAX) -> str:
    """Укоротить HTML под лимит Telegram, не разрывая тег или &сущность; и
    закрыть открытые теги. Лимит Telegram — по разобранному тексту, поэтому
    сырой HTML не длиннее лимита трогать не нужно."""
    if len(text) <= limit:
        return text
    cut = text[:limit - 16]
    lt, gt = cut.rfind("<"), cut.rfind(">")
    if lt > gt:
        cut = cut[:lt]
    amp, semi = cut.rfind("&"), cut.rfind(";")
    if amp > semi:
        cut = cut[:amp]
    open_tags: list[str] = []
    for m in re.finditer(r"<(/?)([a-z][a-z0-9-]*)[^>]*>", cut):   # и <tg-emoji …>
        if m.group(1):
            if open_tags and open_tags[-1] == m.group(2):
                open_tags.pop()
        else:
            open_tags.append(m.group(2))
    return cut + "…" + "".join(f"</{t}>" for t in reversed(open_tags))


def fmt_bytes(n: int | None) -> str:
    n = int(n or 0)
    for unit in ("Б", "КБ", "МБ", "ГБ"):
        if n < (1024 if unit == "Б" else 1023.95):      # иначе «1024.0 КБ»
            return f"{n} {unit}" if unit == "Б" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} ТБ"


def fmt_dur(sec: int | None) -> str:
    """3с / 5м / 2ч 15м / 3д 4ч."""
    s = max(0, int(sec or 0))
    if s < 60:
        return f"{s}с"
    if s < 3600:
        return f"{s // 60}м"
    if s < 86400:
        return f"{s // 3600}ч {s % 3600 // 60}м"
    return f"{s // 86400}д {s % 86400 // 3600}ч"


def fmt_time(ts: int | None) -> str:
    return time.strftime("%d.%m.%Y %H:%M", time.localtime(int(ts or 0)))


def fmt_expire(ts: int | None) -> str:
    if not ts:
        return "бессрочно"
    left = int(ts) - int(time.time())
    return f"{fmt_time(ts)} ({'через ' + fmt_dur(left) if left > 0 else 'истёк'})"


def profile_hints(profiles: list[dict]) -> str:
    """Подсказки к профилям мимикрии — текстом: на кнопке им тесно."""
    return "\n".join(f"• <b>{esc(p['label'])}</b> — {esc(p['hint'])}" for p in profiles)


def state_icon(state: str) -> str:
    """Состояние туннеля из awg2: up / off / none."""
    return {"up": "🟢", "off": "⚪️"}.get(state, "▫️")


def state_word(state: str) -> str:
    return {"up": "включён", "off": "выключен", "none": "не настроен"}.get(state, state)


# Telegram рисует клавиатуру шириной с сообщение: под коротким текстом
# («🛡 alice») кнопки сжимаются и подписи обрезаются. Такой текст дополняем в
# первой строке пустыми символами Брайля — это не пробел, Telegram его не
# срезает — до ширины, в которую кнопки влезут.
PAD = "\u2800"
PAD_MAX = 32


def fit(text: str, markup: InlineKeyboardMarkup | None) -> str:
    if not markup or not markup.inline_keyboard:
        return text
    need = min(PAD_MAX, max(len(row) * (max(width(b.text) for b in row) + 4) for row in markup.inline_keyboard))
    lines = html.unescape(re.sub(r"<[^>]+>", "", text)).split("\n")
    if max(width(line) for line in lines) >= need:
        return text
    pad = PAD * (need - width(lines[0]))
    i = text.find("\n")
    return text + pad if i < 0 else text[:i] + pad + text[i:]


def fail(r: api.Result, title: str = "") -> str:
    """Экран ошибки: причина и хвост журнала awg2."""
    head = f"❌ <b>{esc(title)}</b>\n" if title else "❌ "
    text = f"{head}{esc(r.message)}"
    log_tail = "\n".join(r.log.strip().splitlines()[-12:])
    if log_tail and log_tail.strip() != r.message.strip():
        text += "\n" + pre(log_tail, 2000)
    return text


# ── Отрисовка ─────────────────────────────────────────────
# Бот ничего не удаляет. Нажатие кнопки правит её сообщение; ответ на
# сообщение пользователя (/start, введённый текст) — новое сообщение внизу.
# Одно исключение — внутри одного ответа: «⏳ …» и итог остаются одним
# сообщением, пока после «⏳» бот ничего не присылал; поэтому файлы
# (конфиги, архивы) отправляются уже после итога, под ним. В личном чате
# номера сообщений идут подряд у обеих сторон: экран новее сообщения
# пользователя — значит, это ответ на него.
_screen: dict[int, int] = {}            # чат → последнее сообщение-экран бота
_last: dict[int, int] = {}              # чат → последнее сообщение, отправленное ботом
busy: set[tuple[int, int]] = set()      # (чат, сообщение) с идущей задачей


class TrackSent(BaseRequestMiddleware):
    """Запоминает последнее отправленное ботом сообщение в каждом чате."""

    async def __call__(self, make_request, bot, method):  # type: ignore[no-untyped-def]
        result = await make_request(bot, method)
        if isinstance(result, Message) and type(method).__name__.startswith("Send"):
            _last[result.chat.id] = result.message_id
        return result


def set_screen(chat_id: int, msg_id: int) -> None:
    _screen[chat_id] = msg_id


def is_screen(chat_id: int, msg_id: int) -> bool:
    return _screen.get(chat_id) == msg_id


async def show_new(bot: Bot, chat_id: int, text: str, markup: InlineKeyboardMarkup | None = None) -> Message:
    """Новое сообщение-экран внизу чата."""
    msg = await bot.send_message(chat_id, fit(clip(text), markup), reply_markup=markup,
                                 disable_web_page_preview=True)
    _screen[chat_id] = msg.message_id
    return msg


async def render(target: Target, text: str, markup: InlineKeyboardMarkup | None = None) -> Message | None:
    """Кнопка — правим её сообщение; сообщение пользователя — отвечаем новым.
    None — текст не изменился."""
    text = fit(clip(text), markup)
    bot = target.bot
    if bot is None:
        return None
    if isinstance(target, CallbackQuery):
        msg = target.message
        with contextlib.suppress(TelegramBadRequest):   # колбэк старше 15 минут
            await target.answer()
        if not isinstance(msg, Message):
            # Сообщение старше 48 часов (InaccessibleMessage) не правится — отвечаем новым,
            # иначе кнопка вчерашнего меню или уведомления молча ничего не делает
            return await show_new(bot, msg.chat.id, text, markup) if msg is not None else None
        try:
            out = await msg.edit_text(text, reply_markup=markup, disable_web_page_preview=True)
        except TelegramBadRequest as e:
            if "not modified" not in str(e):
                log.debug("edit_text: %s — отвечаю новым сообщением", e)
                return await show_new(bot, msg.chat.id, text, markup)
            out = msg
        _screen[msg.chat.id] = msg.message_id
        return out if isinstance(out, Message) else msg
    chat_id = target.chat.id
    mid = _screen.get(chat_id, 0)
    if mid > target.message_id and _last.get(chat_id) == mid and (chat_id, mid) not in busy:
        try:
            out = await bot.edit_message_text(text, chat_id=chat_id, message_id=mid, reply_markup=markup,
                                              disable_web_page_preview=True)
            if isinstance(out, Message):
                return out
        except TelegramBadRequest as e:
            if "not modified" in str(e):
                return None
            log.debug("edit_message_text: %s — отвечаю новым сообщением", e)
    return await show_new(bot, chat_id, text, markup)


def chat_of(target: Target) -> Message:
    """Сообщение, в чат которого отвечать."""
    return target.message if isinstance(target, CallbackQuery) else target  # type: ignore[return-value]


async def result(target: Target, r: api.Result, title: str, back_to: str,
                 ok_text: str = "") -> None:
    """Итог быстрой команды: текст awg2 при успехе, причина при ошибке."""
    if r.ok:
        body = ok_text or pre("\n".join(r.log.strip().splitlines()[-15:]), 2500)
        await render(target, f"✅ <b>{esc(title)}</b>\n{body}", kb(back(back_to)))
    else:
        await render(target, fail(r, title), kb(back(back_to)))


async def confirm(target: Target, text: str, yes: Button, no_to: str) -> None:
    await render(target, text, kb(Row(yes, back(no_to, "✖️ Отмена"))))


# ── Колбэки разделов ──────────────────────────────────────
Handler = Callable[[CallbackQuery, FSMContext, str], Awaitable[None]]


class Actions:
    """Колбэки раздела вида «префикс:действие:аргумент» → функции
    (cb, state, аргумент). Пустое действие — экран самого раздела.
    Любое нажатие отменяет незаконченный ввод текста; данные мастеров
    (ключи FSM) при этом остаются. owner — раздел только для владельцев:
    проверка на входе раздела, а не в каждой кнопке (с текстом отказа)."""

    def __init__(self, router: Router, prefix: str, owner: str = "") -> None:
        self.prefix = prefix
        self.owner = owner
        self.table: dict[str, Handler] = {}
        router.callback_query.register(
            self._dispatch, F.data.func(lambda d: d == prefix or d.startswith(prefix + ":")))

    def __call__(self, act: str = "") -> Callable[[Handler], Handler]:
        def deco(fn: Handler) -> Handler:
            self.table[act] = fn
            return fn
        return deco

    def data(self, act: str = "", arg: str = "") -> str:
        """Готовая строка колбэка. Telegram ограничивает её 64 байтами."""
        d = self.prefix + (f":{act}" if act or arg else "") + (f":{arg}" if arg else "")
        if len(d.encode()) > 64:
            raise ValueError(f"callback_data длиннее 64 байт: {d}")
        return d

    async def _dispatch(self, cb: CallbackQuery, state: FSMContext) -> None:
        _, _, rest = (cb.data or "").partition(":")
        act, _, arg = rest.partition(":")
        fn = self.table.get(act)
        if fn is None:
            await cb.answer("Кнопка устарела — открой меню заново", show_alert=True)
            return
        if self.owner and not access.is_owner(cb.from_user.id):
            await cb.answer(self.owner, show_alert=True)
            return
        if await state.get_state() is not None:
            await state.set_state(None)
        await fn(cb, state, arg)


# ── Списки за кнопками ────────────────────────────────────
# В callback_data влезает 64 байта — длинные значения (пути бэкапов, теги
# Xray) кнопка передаёт номером, а сам список лежит в данных FSM.
async def remember(state: FSMContext, key: str, items: list) -> None:
    await state.update_data({f"list:{key}": items})


async def recall(state: FSMContext, key: str, idx: str):
    items = (await state.get_data()).get(f"list:{key}") or []
    try:
        return items[int(idx)]
    except (ValueError, IndexError):
        return None
