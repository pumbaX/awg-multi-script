"""
test_bot.py — сквозная проверка Telegram-бота без Telegram и без root.

Обработчики aiogram получают настоящие апдейты (dp.feed_update), бот зовёт
настоящий `awg2 api` собранного awg2 в песочнице (sandbox.py), а сеть
Telegram подменена сессией, которая записывает вызовы Bot API.

Запуск:  python3 tests/test_bot.py [путь/к/dist/awg2.sh]
         (нужен aiogram: pip install -r awg_bot/requirements.txt)
"""
import asyncio
import datetime
import hashlib
import hmac
import itertools
import json
import logging
import os
import re
import socket
import sys
import time
from urllib.parse import urlencode

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sandbox import *  # noqa: E402,F401,F403

try:
    import aiogram  # noqa: F401
except ImportError:
    print("aiogram не установлен — тест бота пропущен (pip install -r awg_bot/requirements.txt)")
    sys.exit(0)

import aiohttp  # noqa: E402
from aiogram.client.session.base import BaseSession  # noqa: E402
from aiogram.exceptions import TelegramBadRequest  # noqa: E402
from aiogram.types import (CallbackQuery, Chat, ChatMemberLeft, ChatMemberMember, ChatMemberUpdated,  # noqa: E402
                           InlineKeyboardMarkup, Message, MessageEntity, Sticker, StickerSet, Update, User)

# Как Telegram обходится с иконками (custom emoji) от бота: ok — показывает
# (Premium у владельца), strip — молча срезает, reject — отклоняет запрос
PREMIUM = {"mode": "strip"}
# Telegram не принимает адрес Mini App (например, IP вместо домена)
WEBAPP_REJECT = [False]
PACK = {"🖥": "111", "👥": "222", "🌐": "333", "🗑": "444", "⭐": "555", "💿": "666", "🟢": "777"}

# ── Окружение бота ────────────────────────────────────────
API = api_wrapper()
STATE = os.path.join(TMP, "botstate")
os.makedirs(STATE)
BOT_CONF = os.path.join(TMP, "awg-bot.conf")
with open(BOT_CONF, "w") as f:
    f.write("BOT_TOKEN=123456:" + "A" * 35 + "\nADMIN_ID=111\n")
os.environ.update(ENV)
# Кэш чтений выключен: тест меняет файлы сервера в обход awg2 между нажатиями
# (сам кэш проверяется отдельно — «Кэш вызовов awg2»)
os.environ.update(AWG_API_CACHE_TTL="0")
os.environ.update(AWG2_BIN=API, AWG_BOT_STATE=STATE, AWG_ADMINS_FILE=os.path.join(STATE, "admins.json"),
                  AWG_BOT_CONF=BOT_CONF, AWG_CERT_FULL=os.path.join(ROOT, "etc/awg2/cert/fullchain.pem"),
                  AWG_CERT_KEY=os.path.join(ROOT, "etc/awg2/cert/key.pem"))
sys.path.insert(0, os.path.join(HERE, "..", "awg_bot"))

from awgbot import admins, api as botapi, bot as botmod, jobs, store, ui, webapp  # noqa: E402

USER_NAMED = ("cl:v:", "tc:t:", "ex:pick:", "xr:delok:", "xr:delq:", "wo:v:", "adm:rm:", "diag:sn:", "mod:tag:")

logging.getLogger("aiogram").setLevel(logging.WARNING)

jobs.POLL, jobs.EDIT_EVERY = 0.2, 0.0

os.makedirs(os.path.join(ROOT, "etc/amnezia/amneziawg"), exist_ok=True)
os.makedirs(os.path.join(ROOT, "root"), exist_ok=True)
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/awg0.conf"), "w") as f:
    f.write(OLD20)
for n in ("alice", "bob"):
    with open(os.path.join(ROOT, "root", n + "_awg2.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = X\nAddress = 10.23.45.2/32\n")


# AWG_DUMP_KB=файл — все экраны с раскладкой кнопок, для глаз
DUMP = open(os.environ["AWG_DUMP_KB"], "w") if os.environ.get("AWG_DUMP_KB") else None


class FakeSession(BaseSession):
    """Bot API без сети: запоминает вызовы, ведёт «чат» (какие сообщения
    бота живы и с кнопками ли они) и отвечает правдоподобно."""

    def __init__(self):
        super().__init__()
        self.sent = []
        self.chat = {}          # id сообщения бота → "screen" | "text" | "file"
        self.text = {}          # id сообщения бота → его текущий текст
        self.deleted = set()

    async def make_request(self, bot, method, timeout=None):
        name = type(method).__name__
        self.sent.append((name, method))
        if DUMP and name in ("SendMessage", "EditMessageText") and method.reply_markup:
            DUMP.write("\n" + "═" * 60 + "\n" + (method.text or "")[:300] + "\n")
            for row in method.reply_markup.inline_keyboard:
                DUMP.write("  " + " | ".join(f"[{b.text}]" for b in row) + "\n")
        if name == "GetMe":
            return User(id=999, is_bot=True, first_name="Bot", username="testbot").as_(bot)
        if name == "DeleteMessage":
            self.deleted.add(method.message_id)
            self.chat.pop(method.message_id, None)
            return True
        if name == "SetChatMenuButton" and WEBAPP_REJECT[0] and method.menu_button.type == "web_app":
            raise TelegramBadRequest(method=method, message="Bad Request: BUTTON_URL_INVALID")
        if name == "GetStickerSet":
            return StickerSet(name=method.name, title="Icons", sticker_type="custom_emoji", stickers=[
                Sticker(file_id=f"f{i}", file_unique_id=f"u{i}", type="custom_emoji", width=100, height=100,
                        is_animated=False, is_video=False, emoji=e, custom_emoji_id=i) for e, i in PACK.items()])
        if name == "EditMessageReplyMarkup":
            if method.message_id in self.chat and not method.reply_markup:
                self.chat[method.message_id] = "text"
            return True
        if name in ("SendMessage", "EditMessageText", "SendDocument", "SendPhoto"):
            markup = getattr(method, "reply_markup", None)
            icons_in = "<tg-emoji" in (getattr(method, "text", None) or "") or (
                isinstance(markup, InlineKeyboardMarkup)
                and any(b.icon_custom_emoji_id for row in markup.inline_keyboard for b in row))
            if WEBAPP_REJECT[0] and isinstance(markup, InlineKeyboardMarkup) and any(
                    b.web_app for row in markup.inline_keyboard for b in row):
                raise TelegramBadRequest(method=method, message="Bad Request: BUTTON_URL_INVALID")
            if icons_in and PREMIUM["mode"] == "reject":
                raise TelegramBadRequest(method=method, message="Bad Request: custom emoji not allowed")
            entities, echo = None, markup
            if icons_in and PREMIUM["mode"] == "ok":
                entities = [MessageEntity(type="custom_emoji", offset=0, length=2, custom_emoji_id="111")]
            elif icons_in and isinstance(markup, InlineKeyboardMarkup):
                echo = InlineKeyboardMarkup(inline_keyboard=[
                    [b.model_copy(update={"icon_custom_emoji_id": None}) for b in row] for row in markup.inline_keyboard])
            # В личном чате номера сообщений общие для обеих сторон
            mid = getattr(method, "message_id", None) or next(MSG_IDS)
            if method.chat_id == OWNER.id:
                self.chat[mid] = ("file" if name in ("SendDocument", "SendPhoto")
                                  else "screen" if method.reply_markup else "text")
                self.text[mid] = getattr(method, "text", None) or getattr(method, "caption", None) or ""
            return Message(message_id=mid, date=datetime.datetime.now(), chat=Chat(id=method.chat_id, type="private"),
                           text=getattr(method, "text", None), entities=entities,
                           reply_markup=echo if isinstance(echo, InlineKeyboardMarkup) else None).as_(bot)
        return True

    def texts(self):
        """Живые текстовые сообщения бота у владельца (без файлов)."""
        return [m for m, kind in self.chat.items() if kind != "file"]

    def screen_id(self):
        screens = [m for m, kind in self.chat.items() if kind == "screen"]
        return max(screens) if screens else 0

    async def stream_content(self, *args, **kwargs):
        raise NotImplementedError
        yield b""                                               # pragma: no cover

    async def close(self):
        pass


MSG_IDS = itertools.count(1)
SESSION = FakeSession()
BOT, DP = botmod.build(SESSION)
OWNER = User(id=111, is_bot=False, first_name="Owner", username="owner")
STRANGER = User(id=222, is_bot=False, first_name="Stranger")
seq = itertools.count(1)


def _msg(user, text, entities=None):
    return Message(message_id=next(MSG_IDS), date=datetime.datetime.now(), chat=Chat(id=user.id, type="private"),
                   from_user=user, text=text, entities=entities)


LAST_SAID = [0]


async def say(text, user=OWNER, entities=None):
    mark = len(SESSION.sent)
    msg = _msg(user, text, entities)
    LAST_SAID[0] = msg.message_id
    await DP.feed_update(BOT, Update(update_id=next(seq), message=msg))
    return SESSION.sent[mark:]


def no_hourglass(label):
    """Ни одно сообщение бота не осталось висеть на «⏳ …»."""
    stuck = [SESSION.text[m] for m in SESSION.texts() if SESSION.text.get(m, "").startswith("⏳")]
    chk(f"{label}: нет повисших «⏳»", not stuck, stuck)


async def press(data, user=OWNER):
    """Нажатие кнопки на текущем экране (как в настоящем чате)."""
    mark = len(SESSION.sent)
    msg = _msg(user, "экран")
    if user is OWNER and SESSION.screen_id():
        msg = Message(message_id=SESSION.screen_id(), date=datetime.datetime.now(),
                      chat=Chat(id=user.id, type="private"), text="экран")
    cb = CallbackQuery(id=str(next(seq)), from_user=user, chat_instance="ci", data=data, message=msg)
    await DP.feed_update(BOT, Update(update_id=next(seq), callback_query=cb))
    return SESSION.sent[mark:]


def screen(sent):
    """Последний показанный экран: текст и кнопки (текст, данные)."""
    for name, m in reversed(sent):
        if name in ("SendMessage", "EditMessageText"):
            rows = m.reply_markup.inline_keyboard if m.reply_markup else []
            return m.text or "", [(b.text, b.callback_data or b.url or ("webapp:" + b.web_app.url if b.web_app else None))
                                  for row in rows for b in row]
    return "", []


def keyboard(sent):
    """Строки кнопок последнего экрана."""
    for name, m in reversed(sent):
        if name in ("SendMessage", "EditMessageText"):
            return m.reply_markup.inline_keyboard if m.reply_markup else []
    return []


def alerts(sent):
    return [m.text or "" for name, m in sent if name == "AnswerCallbackQuery"]


def docs(sent):
    return [m for name, m in sent if name == "SendDocument"]


async def wait_jobs(timeout=60):
    for _ in range(int(timeout / 0.1)):
        if not jobs._tasks:
            return True
        await asyncio.sleep(0.1)
    return False


async def run():
    print("Доступ")
    text, _ = screen(await say("/start", STRANGER))
    chk("чужой видит отказ и свой ID", "Доступ запрещён" in text and "222" in text, text)
    chk("чужое нажатие отклонено", "⛔️ Нет доступа" in alerts(await press("cl", STRANGER)))
    for text in ("/startfoo", "/start@otherbot", "/startinv_x"):
        sent = await say(text, STRANGER)
        shown = screen(sent)[0]
        chk(f"чужому «{text}» — не меню со сводкой сервера", "AWG Toolza" not in shown and not keyboard(sent),
            [n for n, _ in sent])

    group = Chat(id=-1001234, type="supergroup", title="Группа")
    mark = len(SESSION.sent)
    await DP.feed_update(BOT, Update(update_id=next(seq), message=Message(
        message_id=next(MSG_IDS), date=datetime.datetime.now(), chat=group, from_user=OWNER, text="/start")))
    chk("в группе бот молчит даже владельцу", not [n for n, _ in SESSION.sent[mark:]], SESSION.sent[mark:])
    mark = len(SESSION.sent)
    gmsg = Message(message_id=next(MSG_IDS), date=datetime.datetime.now(), chat=group, text="экран")
    await DP.feed_update(BOT, Update(update_id=next(seq), callback_query=CallbackQuery(
        id=str(next(seq)), from_user=OWNER, chat_instance="g", data="cl", message=gmsg)))
    chk("кнопка в группе — отказ, экран не показан",
        alerts(SESSION.sent[mark:]) == ["Бот работает только в личных сообщениях"]
        and not screen(SESSION.sent[mark:])[0], SESSION.sent[mark:])
    mark = len(SESSION.sent)
    now = datetime.datetime.now()
    await DP.feed_update(BOT, Update(update_id=next(seq), my_chat_member=ChatMemberUpdated(
        chat=group, from_user=STRANGER, date=now,
        old_chat_member=ChatMemberLeft(user=User(id=999, is_bot=True, first_name="Bot")),
        new_chat_member=ChatMemberMember(user=User(id=999, is_bot=True, first_name="Bot")))))
    left = [m for n, m in SESSION.sent[mark:] if n == "LeaveChat"]
    chk("бота добавили в группу — сам выходит", len(left) == 1 and left[0].chat_id == group.id, SESSION.sent[mark:])
    chk("выход из групп включён в получаемые апдейты", "my_chat_member" in DP.resolve_used_update_types())

    print("Главное меню")
    text, buttons = screen(await say("/start"))
    chk("сводка сервера", "AWG Toolza" in text and "AWG 2.0" in text and "2 клиента · 0 онлайн" in text, text)
    chk("шапка блоками", text.count("<blockquote>") >= 3 and "<b>vm" not in text.split("<blockquote>")[0], text)
    datas = [d for _, d in buttons]
    chk("пункты меню в порядке awg2, веб-панель — как «w»",
        datas[:10] == ["srv", "cl", "diag", "bk", "tun", "botm", "del", "upd", "wo", "web"], buttons)
    rows = keyboard(SESSION.sent)
    chk("главное меню — два столбца, «Обновить» и «Поддержать» во всю ширину",
        [len(r) for r in rows] == [2, 2, 2, 2, 2, 1, 1] and rows[-2][0].callback_data == "main",
        [[b.text for b in r] for r in rows])
    chk("в самом низу — «Поддержать 💚» во всю ширину, ссылкой",
        rows[-1][0].text == "Поддержать 💚" and rows[-1][0].url == "https://t.me/awgToolza/156/157"
        and rows[-1][0].callback_data is None, rows[-1])
    menu_id = SESSION.screen_id()
    sent = await say("/start")
    chk("повторный /start — всегда новое меню внизу, старое не трогается",
        any(n == "SendMessage" for n, _ in sent) and SESSION.screen_id() > menu_id
        and not any(n in ("DeleteMessage", "EditMessageText") for n, _ in sent), [n for n, _ in sent])
    text, _ = screen(await say("что-нибудь"))
    chk("любой текст вне ввода — меню", "AWG Toolza" in text, text)
    chk("устаревшая кнопка", any("устарела" in a for a in alerts(await press("zzz:1"))))

    print("Клиенты")
    text, buttons = screen(await press("cl"))
    chk("список клиентов", "Клиенты: 2" in text and ("cl:v:alice" in [d for _, d in buttons]), [text, buttons])
    now = int(time.time())
    with open(AWG_DUMP, "w") as f:
        f.write(f"PRIV\tPUB\t51820\toff\nPUBALICE=\t(none)\t(none)\t10.23.45.2/32\t{now - 3600}\t0\t0\toff\n"
                f"PUBBOB=\t(none)\t1.2.3.4:5555\t10.23.45.3/32\t{now - 30}\t100\t200\toff\n")
    text, buttons = screen(await press("cl:sort:activity"))
    order = [d.split(":")[2] for _, d in buttons if d.startswith("cl:v:")]
    chk("сортировка по активности: онлайн первым, с давностью",
        order == ["bob", "alice"] and "по активности" in text and any(t.startswith("🟢 bob · ") for t, _ in buttons),
        [text, buttons])
    text, buttons = screen(await press("cl:sort:name"))
    order = [d.split(":")[2] for _, d in buttons if d.startswith("cl:v:")]
    chk("сортировка по имени", order == ["alice", "bob"] and "по имени" in text
        and ("🔃 По активности", "cl:sort:activity") in buttons, [text, buttons])
    chk("сортировка запоминается", store.setting("clients_sort") == "name", store.setting("clients_sort"))
    os.remove(AWG_DUMP)
    text, buttons = screen(await press("cl:v:alice"))
    chk("карточка", "alice" in text and "10.23.45.2" in text and ("cl:conf:alice" in [d for _, d in buttons]), text)

    await press("cl:add")
    text, buttons = screen(await say("bad name!"))
    chk("неверное имя — повторный вопрос", "латиница" in text, text)
    text, buttons = screen(await say("carol"))
    chk("после имени — срок", "Срок действия" in text and "cl:ne:+1d" in [d for _, d in buttons], [text, buttons])
    text, buttons = screen(await press("cl:ne:+1d"))
    chk("профиль pro — выбор мимикрии", "cl:nm:none" in [d for _, d in buttons], [text, buttons])
    sent = await press("cl:nm:none")
    d = docs(sent)
    chk("конфиг нового клиента файлом", d and d[0].document.filename == "carol_awg2.conf", [n for n, _ in sent])
    chk("и QR", any(n == "SendPhoto" for n, _ in sent))
    text, _ = screen(sent)
    chk("карточка нового клиента со сроком", "carol" in text and "через" in text, text)
    no_hourglass("добавление клиента")
    chk("«⏳» становится карточкой, файлы — под ней, лишних экранов нет",
        not any(n == "SendMessage" for n, _ in sent) and SESSION.screen_id() < max(SESSION.chat),
        [n for n, _ in sent])
    card_id = SESSION.screen_id()
    sent = await press("cl:conf:carol")
    chk("«Конфиг и QR» — только файлы, карточка остаётся на месте",
        docs(sent) and not any(n in ("SendMessage", "EditMessageText", "DeleteMessage") for n, _ in sent)
        and SESSION.screen_id() == card_id, [n for n, _ in sent])


    await press("cl:note:carol")
    await say("домашний роутер")
    chk("ответ на вопрос остаётся в чате", LAST_SAID[0] not in SESSION.deleted)
    await press("cl:mon:carol")
    chk("заметка и мониторинг", store.note("carol") == "домашний роутер #ping" and store.monitored("carol"),
        store.notes())
    await press("cl:ren:carol")
    text, _ = screen(await say("dave"))
    chk("переименование переносит заметку", "dave" in text and store.note("dave").startswith("домашний"), text)
    text, _ = screen(await press("cl:ex:dave|none"))
    chk("снять срок", "бессрочно" in text, text)
    await press("cl:delok:dave")
    chk("удаление клиента и его заметки", not os.path.exists(os.path.join(ROOT, "root", "dave_awg2.conf"))
        and store.note("dave") == "")

    text, buttons = screen(await press("cl:bulk"))
    chk("массовое создание: выбор — префикс и количество или имена",
        [d for _, d in buttons][:2] == ["cl:bpre", "cl:bnames"], buttons)
    await press("cl:bpre")
    text, buttons = screen(await say("u"))
    chk("после префикса — количество кнопками", "cl:bn:10" in [d for _, d in buttons]
        and "cl:bn:ask" in [d for _, d in buttons], buttons)
    await press("cl:bn:2")
    sent = await press("cl:be:none")
    d = docs(sent)
    chk("несколько клиентов — zip", d and d[0].document.filename == "awg_clients.zip" and len(d[0].document.data) > 100,
        [n for n, _ in sent])
    text, buttons = screen(sent)
    chk("итог массового создания — на месте «⏳», архив под ним",
        "Создано клиентов: 2" in text and "u-001" in text and ("👥 Клиенты", "cl") in buttons
        and SESSION.screen_id() < max(SESSION.chat), [text, buttons])
    no_hourglass("массовое создание")

    await press("cl:bnames")
    await say("e1,e2")
    await press("cl:be:date")
    sent = await say("2099-01-01 10:00")
    text, _ = screen(sent)
    chk("срок датой: итог ответом на дату, архив под ним",
        "Создано клиентов: 2" in text and docs(sent)
        and [n for n, _ in sent if n in ("SendMessage", "SendDocument")] == ["SendMessage", "SendDocument"],
        [n for n, _ in sent])
    no_hourglass("массовое создание со сроком-датой")
    await press("cl:bnames")
    await say("x1, x2, x3")
    sent = await press("cl:be:none")
    chk("имена через запятую — все созданы", "Создано клиентов: 3" in screen(sent)[0]
        and "Конфиги: 3" in (docs(sent)[0].caption if docs(sent) else ""), [n for n, _ in sent])
    await press("cl:bnames")
    await say("alice zed1\nzed2")
    text, _ = screen(await press("cl:be:none"))
    chk("имена через пробел и с новой строки — отдельные; занятое названо, итог «N из M»",
        "Создано клиентов: 2 из 3" in text and "zed1, zed2" in text and "Имя уже занято: alice" in text, text)
    real_call_b = botapi.call

    async def subnet_full(*args, **kw):
        if args[:2] == ("clients", "bulk"):
            line = "━" * 20
            return botapi.Result(True, data=["q-001", "q-002"],
                                 log=f"  √ q-001 → 10.23.45.40\n  √ q-002 → 10.23.45.41\n  ▲ Подсеть заполнена — стоп\n"
                                     f"{line}\n  Создано клиентов: 2 из 5\n{line}\n")
        return await real_call_b(*args, **kw)
    await press("cl:bpre")
    await say("q")
    await press("cl:bn:5")
    botapi.call = subnet_full
    try:
        text, _ = screen(await press("cl:be:none"))
    finally:
        botapi.call = real_call_b
    chk("подсеть заполнена: «2 из 5» и предупреждение awg2 в итоге",
        "Создано клиентов: 2 из 5" in text and "▲ Подсеть заполнена — стоп" in text, text)
    await press("cl:bpre")
    await say("p")
    await press("cl:bn:ask")
    await say("25")
    await press("cl:be:none")
    text, buttons = screen(await press("cl:dsel"))
    chk("удаление нескольких: экран выбора", "Никто не отмечен" in text and "cl:ds:0|e1" in [d for _, d in buttons],
        [text, buttons[:4]])
    await press("cl:ds:0|e1")
    text, buttons = screen(await press("cl:ds:0|e2"))
    chk("отмечено двое", "Отмечено: 2" in text and ("🗑 e1", "cl:ds:0|e1") in buttons
        and ("🗑 Удалить: 2", "cl:dsgo") in buttons, [text, buttons])
    text, buttons = screen(await press("cl:ds:0|e2"))
    chk("повторное нажатие снимает отметку", "Отмечено: 1" in text and ("⬜️ e2", "cl:ds:0|e2") in buttons, text)
    await press("cl:ds:0|e2")
    text, _ = screen(await press("cl:dsgo"))
    chk("подтверждение со списком", "Удалить клиентов: <b>2</b>" in text and "e1, e2" in text, text)
    text, buttons = screen(await press("cl:dsok"))
    chk("удалены оба, конфиги тоже", "Удалено клиентов: 2" in text
        and not os.path.exists(os.path.join(ROOT, "root", "e1_awg2.conf"))
        and not os.path.exists(os.path.join(ROOT, "root", "e2_awg2.conf")), text)
    no_hourglass("удаление нескольких")
    await press("cl:dsel")
    _, buttons = screen(await press("cl:dsp:1"))
    mark_all = next((d for t, d in buttons if t == "☑️ Отметить всех"), "")
    _, buttons = screen(await press(mark_all))
    on_page2 = any(d.startswith("cl:ds:1|") for _, d in buttons) and ("◀️ Стр. 1", "cl:dsp:0") in buttons
    clear = next((d for t, d in buttons if t == "⬜️ Снять все"), "")
    _, buttons = screen(await press(clear))
    chk("«Отметить всех» и «Снять все» оставляют открытую страницу",
        on_page2 and any(d.startswith("cl:ds:1|") for _, d in buttons), [mark_all, clear, buttons[:3]])

    # п.2: «Назад» с уровня мимикрии — к выбору профиля, а не в список клиентов
    _, buttons = screen(await press("cl:mim:alice"))
    lvl = next(d for _, d in buttons if d.startswith("cl:lvl:ms|"))
    _, buttons = screen(await press(lvl))
    chk("уровень мимикрии клиента: «Назад» — к его мимикрии", ("◀️ Назад", "cl:mim:alice") in buttons, buttons)
    await press("cl:add")
    await say("lvlback")
    _, buttons = screen(await press("cl:ne:none"))
    lvl = next(d for _, d in buttons if d.startswith("cl:lvl:nm|"))
    _, buttons = screen(await press(lvl))
    back_to = next((d for t, d in buttons if t == "◀️ Назад"), "")
    text, buttons = screen(await press(back_to))
    chk("уровень мимикрии нового клиента: «Назад» — к выбору профиля мастера",
        back_to != "cl" and "lvlback" in text and "cl:nm:none" in [d for _, d in buttons], [back_to, text[:80]])
    await press("cl")

    # п.8: неверный формат и прошедшая дата — разные ответы, пример — через месяц
    await press("cl:ex:alice|date")
    text, _ = screen(await say("послезавтра"))
    example = time.strftime("%Y-%m-%d", time.localtime(time.time() + 30 * 86400))
    chk("дата не по формату — формат, пример через месяц и время сервера",
        "ГГГГ-ММ-ДД ЧЧ:ММ" in text and example in text and "время сервера" in text and "прошла" not in text, text)
    text, _ = screen(await say("2020-01-01 10:00"))
    chk("прошедшая дата — «уже прошла», а не «нужен формат»", "уже прошла" in text and "Формат" not in text, text)
    await press("cl:v:alice")

    # п.4: «Трафик» при сотнях клиентов — по страницам, никто не теряется
    real_call_a = botapi.call
    many = [{"name": f"m{i:03d}", "ip": f"10.23.{i // 250}.{i % 250 + 2}", "rx": 1, "tx": 1} for i in range(253)]

    async def many_clients(*args, **kw):
        if args[:2] == ("clients", "list"):
            return botapi.Result(True, data=many)
        return await real_call_a(*args, **kw)
    botapi.call = many_clients
    try:
        seen_names, data, pages = set(), "cl:activity", 0
        while data and pages < 50:
            text, buttons = screen(await press(data))
            seen_names |= set(re.findall(r"<b>(m\d{3})</b>", text))
            data = next((d for t, d in buttons if t.endswith("▶️")), "")
            pages += 1
    finally:
        botapi.call = real_call_a
    chk("«Трафик» при 253 клиентах — страницами, видны все", len(seen_names) == 253 and pages > 1,
        (len(seen_names), pages))
    text, buttons = screen(await press("tc::warp"))
    datas = [d for _, d in buttons]
    chk("длинный список клиентов туннеля — по страницам", "tc:pg:warp|1" in datas and len(buttons) <= 25, len(buttons))
    text, buttons = screen(await press("tc:pg:warp|1"))
    first = next(d for _, d in buttons if d.startswith("tc:t:"))
    text, buttons = screen(await press(first))
    chk("переключение клиента не сбрасывает страницу", "tc:pg:warp|0" in [d for _, d in buttons], buttons[:3])

    print("Сервер и туннели")
    text, buttons = screen(await press("srv"))
    chk("экран сервера", "AWG 2.0" in text and "srv:proto" in [d for _, d in buttons], text)
    real_call_ = botapi.call

    async def no_components(*args, **kw):
        if args[:2] == ("server", "info"):
            return botapi.Result(True, data={"installed": False, "exists": False})
        return await real_call_(*args, **kw)
    botapi.call = no_components
    text, buttons = screen(await press("srv:create"))
    botapi.call = real_call_
    chk("чистый сервер: «Создать сервер» сначала ставит компоненты, мастер не начинается",
        "Сначала нужны компоненты" in text and ("📦 Установить", "srv:installok") in buttons
        and not any(d.startswith("srv:w:") for _, d in buttons), [text, buttons])

    async def info_fails(*args, **kw):
        if args[:2] == ("server", "info"):
            return botapi.Result(False, 124, error="awg2 не ответил за 180 с")
        return await real_call_(*args, **kw)
    botapi.call = info_fails
    text, buttons = screen(await press("srv:create"))
    botapi.call = real_call_
    chk("сбой server info — ошибка, а не «нужны компоненты» с переустановкой",
        "не ответил" in text and "Сначала нужны компоненты" not in text
        and "srv:installok" not in [d for _, d in buttons] and not any(d.startswith("srv:w:") for _, d in buttons),
        [text, buttons])
    text, buttons = screen(await press("srv:create"))
    chk("мастер создания начинается с региона", "srv:w:region=ru" in [d for _, d in buttons], buttons)
    for step in ("region=ru", "profile=lite"):
        await press(f"srv:w:{step}")
    text, buttons = screen(await press("srv:w:mimicry=none"))
    chk("мастер: tools без 3.1 — так и сказано, кнопка «Модуль и tools», 3.1 не предлагается",
        "amneziawg-tools не умеют 3.1" in text and ("⬆️ Модуль и tools", "srv:upd31") in buttons
        and "srv:w:proto=3.1" not in [d for _, d in buttons], [text, buttons])
    text, buttons = screen(await press("srv:wr"))
    chk("возврат в мастер — тот же шаг с прежними ответами", "Версия протокола" in text, text)
    for step in ("proto=2.0", "dns=0"):
        await press(f"srv:w:{step}")
    text, buttons = screen(await press("srv:w:mtu=1280"))
    chk("мастер: подсеть — случайная или вручную", "Подсеть" in text and "srv:w:net=ask" in [d for _, d in buttons],
        [text, buttons])
    await press("srv:w:net=ask")
    text, _ = screen(await say("10.66.1.7/25"))
    chk("мастер: не /24 — повторный вопрос", "сеть /24" in text, text)
    text, buttons = screen(await say("10.66.1.7/24"))
    chk("мастер: после подсети — порт", "UDP-порт" in text, text)
    text, _ = screen(await press("srv:w:port=ask"))
    chk("мастер: вопрос про порт называет 443 (QUIC)", "443 или 1024-65535" in text, text)
    text, _ = screen(await say("80"))
    chk("мастер: порт 80 — повторный вопрос", "Порт — 443 или число 1024-65535" in text, text)
    text, _ = screen(await say("443"))
    chk("мастер: порт 443 принят — дальше адрес в конфигах", "Адрес в конфигах" in text, text)
    text, _ = screen(await press("srv:w:endpoint="))
    chk("мастер: итог с подсетью и портом 443", "Подсеть: 10.66.1.0/24" in text and "Порт: 443" in text, text)
    long_domain = "a" * 60 + ".example.com"
    await press("srv:epdom")
    text, buttons = screen(await say(long_domain))
    chk("длинный домен endpoint не ломает кнопки", "srv:epgo:keep" in [d for _, d in buttons], [text, buttons])
    text, _ = screen(await press("srv:epgo:keep"))
    chk("endpoint применён", "✅" in text and long_domain in text, text)

    SRV_CONF = os.path.join(ROOT, "etc/amnezia/amneziawg/awg0.conf")
    text, buttons = screen(await press("srv"))
    chk("кнопка «Параметры AWG» на экране сервера", "srv:par" in [d for _, d in buttons], buttons)
    text, buttons = screen(await press("srv:par"))
    datas = [d for _, d in buttons]
    chk("параметры: значения и кнопки ключей", "Jc" in text and "= 5" in text and "srv:pk:Jc" in datas
        and "srv:pk:H4" in datas and "srv:pk:RandomTrailers" not in datas and "srv:pgo" not in datas, [text, datas])
    text, _ = screen(await press("srv:pk:Jc"))
    chk("параметры: подсказка и текущее значение", "0-128" in text and "Сейчас: <code>5</code>" in text
        or "Сейчас: 5" in text, text)
    text, _ = screen(await say("много"))
    chk("параметры: не число — повторный вопрос", "Нужно число" in text, text)
    text, buttons = screen(await say("7"))
    chk("параметры: правка помечена, можно применить", "✎ Jc" in text and "srv:pgo" in [d for _, d in buttons], [text, buttons])
    await press("srv:pk:S2")
    text, buttons = screen(await say("96"))
    chk("параметры: ошибка видна сразу, применить нельзя", "❌" in text and "S1 и S2" in text
        and "srv:pgo" not in [d for _, d in buttons], [text, buttons])
    await press("srv:pk:S2")
    await say("61")
    text, buttons = screen(await press("srv:pgo"))
    chk("параметры: подтверждение с предупреждением про клиентов", "Меняются: Jc, S2" in text
        and "обязаны совпадать" in text and "srv:pok" in [d for _, d in buttons], [text, buttons])
    text, buttons = screen(await press("srv:pok"))
    conf_now = open(SRV_CONF).read()
    chk("параметры записаны", "✅" in text and "\nJc = 7\n" in conf_now and "\nS2 = 61\n" in conf_now
        and "cl:export" in [d for _, d in buttons], [text, buttons])
    text, buttons = screen(await press("srv:par"))
    chk("после записи правки сброшены", "✎" not in text and "= 7" in text, text)
    text, buttons = screen(await press("tun"))
    chk("экран туннелей", "warp" in [d for _, d in buttons] and "tun:panic" in [d for _, d in buttons], buttons)

    await press("cas:add")
    await press("cas:p:udp")
    await say("5555")
    await say("5.6.7.8")
    await press("cas:out:5555")
    text, _ = screen(await press("cas:save"))
    chk("мастер каскада добавляет правило", "✅" in text, text)
    text, _ = screen(await press("cas"))
    chk("правило в списке", "UDP 5555 → 5.6.7.8:5555" in text, text)
    _, buttons = screen(await press("cas:del"))
    rule = next(d for t, d in buttons if t == "UDP 5555")
    text, buttons = screen(await press(rule))
    still = screen(await press("cas"))[0]
    chk("удаление правила каскада переспрашивает", "Удалить правило" in text
        and ("🗑 Удалить", "cas:delok:udp|5555") in buttons and ("✖️ Отмена", "cas:del") in buttons
        and "UDP 5555 → 5.6.7.8:5555" in still, [text, buttons, still[-80:]])
    _, buttons = screen(await press("t2s"))
    log_btn = next(d for t, d in buttons if t == "📜 Журнал")
    text, buttons = screen(await press(log_btn))
    chk("журнал из раздела: «Назад» — туда же, «Обновить» помнит откуда",
        "tun2socks" in text and ("◀️ Назад", "t2s") in buttons and ("🔄 Обновить", log_btn) in buttons,
        [log_btn, buttons])
    _, buttons = screen(await press("diag:log:manager"))
    chk("журнал из «Журналов» (и старые кнопки без «куда») — «Назад» в «Журналы»",
        ("◀️ Назад", "diag:logs") in buttons, buttons)
    no_hourglass("мастер каскада")

    print("Маршрут клиента")
    with open(LINKS, "a") as f:
        f.write("warp0\n")
    text, _ = screen(await press("cl:v:alice"))
    chk("маршрут через работающий WARP", "Маршрут: через WARP" in text, text)
    # WARP выключили, работают exit-ноды в режиме «все клиенты»
    awg_dir = os.path.join(ROOT, "etc/amnezia/amneziawg")
    with open(os.path.join(awg_dir, "awg-exit-n1.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = X\nTable = off\n\n[Peer]\nEndpoint = 1.2.3.4:51820\n")
    with open(os.path.join(awg_dir, "exits_state"), "w") as f:
        f.write("active\nmode=all\nbalancer=single\nsingle_exit=n1\n")
    with open(LINKS, "w") as f:
        f.write("awg-exit-n1\n")
    with open(ACTIVE, "w") as f:
        f.write("awg-exits-routing.service\n")
    text, _ = screen(await press("cl:v:alice"))
    chk("WARP выключен — в карточке его нет, маршрут через exit-ноды",
        "exit-ноды, общий выход" in text and "WARP" not in text, text)
    text, buttons = screen(await press("cl:tun:alice"))
    labels = [t for t, _ in buttons]
    chk("экран маршрута: выходы exit-нод без WARP",
        "🔘 Общий выход" in labels and "⚪️ Нода n1" in labels and not any("WARP" in t for t in labels), labels)
    text, buttons = screen(await press("cl:rt:exits|alice|n1"))
    chk("клиент переведён на ноду n1", "🔘 Нода n1" in [t for t, _ in buttons], [t for t, _ in buttons])
    text, _ = screen(await press("cl:v:alice"))
    chk("карточка показывает ноду", "Маршрут: exit-нода n1" in text, text)
    text, buttons = screen(await press("ex:cl"))
    chk("exit-ноды → клиенты: у alice нода, у bob общий выход",
        any(t == "alice → n1" for t, _ in buttons) and any(t == "bob → общий" for t, _ in buttons),
        [t for t, _ in buttons][:4])
    _, buttons = screen(await press("ex:del"))
    node = next(d for t, d in buttons if t.endswith(" n1"))
    text, buttons = screen(await press(node))
    chk("удаление exit-ноды переспрашивает", "n1" in text and ("🗑 Удалить", "ex:delok:n1") in buttons
        and os.path.exists(os.path.join(awg_dir, "awg-exit-n1.conf")), [text, buttons])

    print("Xray: свой выход клиенту")
    with open(LINKS) as f:
        links_saved = f.read()
    with open(ACTIVE) as f:
        active_saved = f.read()
    with open(LINKS, "w") as f:
        f.write("xray0\n")
    with open(ACTIVE, "w") as f:
        f.write("awg-xray.service\n")
    fake_xray()
    vless = ('{"protocol": "vless", "tag": "%s", "settings": {"vnext": [{"address": "127.0.0.1", "port": 9, '
             '"users": [{"id": "d342d11e-d424-4583-b36e-524ab1f0afa4", "encryption": "none"}]}]}}')
    bash('mkdir -p "$XRAY_DIR"; py xray-default "$XRAY_CONF"; '
         f"py xray-add \"$XRAY_CONF\" <<< '{vless % 'de'}'; py xray-add \"$XRAY_CONF\" <<< '{vless % 'nl'}'; "
         'py xray-prepare "$XRAY_CONF" native "$XRAY_PEERS"')
    text, buttons = screen(await press("cl:tun:alice"))
    labels = [t for t, _ in buttons]
    chk("маршрут через Xray: по умолчанию, каждый выход, напрямую",
        labels[:4] == ["🔘 По умолчанию", "⚪️ de", "⚪️ nl", "⚪️ Напрямую"] and "по умолчанию — de" in text, [text, labels])
    text, buttons = screen(await press("cl:rt:xray|alice|x1"))
    chk("клиенту закреплён выход nl", "🔘 nl" in [t for t, _ in buttons], [t for t, _ in buttons])
    with open(os.path.join(ROOT, "xray.peers")) as f:
        peers = f.read().split()
    with open(os.path.join(ROOT, "etc/xray/config.json")) as f:
        own = [r for r in json.load(f)["routing"]["rules"] if str(r.get("ruleTag")).startswith("client-out")]
    chk("в списке «IP|выход», в конфиге Xray — правило по адресу",
        "10.23.45.2|nl" in peers and own and own[0]["source"] == ["10.23.45.2"] and own[0]["outboundTag"] == "nl",
        [peers, own])
    text, _ = screen(await press("cl:v:alice"))
    chk("карточка: маршрут через Xray, выход nl", "Маршрут: через Xray, выход nl" in text, text)
    text, buttons = screen(await press("cl:rt:xray|alice|on"))
    with open(os.path.join(ROOT, "xray.peers")) as f:
        peers = f.read().split()
    chk("обратно на выход по умолчанию", "🔘 По умолчанию" in [t for t, _ in buttons] and "10.23.45.2" in peers, peers)
    _, buttons = screen(await press("xr:del"))
    out = next(d for t, d in buttons if t == "nl")
    text, buttons = screen(await press(out))
    with open(os.path.join(ROOT, "etc/xray/config.json")) as f:
        tags_now = [o.get("tag") for o in json.load(f)["outbounds"]]
    chk("удаление выхода Xray переспрашивает", "nl" in text and any(d.startswith("xr:delok:") for _, d in buttons)
        and ("✖️ Отмена", "xr:del") in buttons and "nl" in tags_now, [text, buttons, tags_now])
    with open(LINKS, "w") as f:
        f.write(links_saved)
    with open(ACTIVE, "w") as f:
        f.write(active_saved)

    print("Прокси и перезапуск бота")
    with open(os.path.join(ROOT, "bot.conf"), "w") as f:
        f.write("BOT_TOKEN=1:A\nADMIN_ID=111\n")
    with open(ACTIVE, "a") as f:
        f.write("awg-bot.service\n")
    await press("botm:penter")
    text, _ = screen(await say("socks5://127.0.0.1:10808"))
    chk("прокси сохраняется без «awg2 ответил не JSON»", "Бот перезапускается" in text, text)
    chk("адрес прокси без пароля остаётся в чате", LAST_SAID[0] not in SESSION.deleted)

    with open(os.path.join(ROOT, "bot.conf")) as f:
        chk("BOT_PROXY записан", "BOT_PROXY=socks5://127.0.0.1:10808" in f.read())
    notice_msg = store.load(store.NOTICE).get("msg")
    chk("экран «перезапускаюсь» запомнен", notice_msg == max(SESSION.chat), store.load(store.NOTICE))
    mark = len(SESSION.sent)
    await botmod.restore(BOT)
    fixed = [m for n, m in SESSION.sent[mark:] if n == "EditMessageText" and m.message_id == notice_msg]
    chk("после перезапуска экран поправлен: бот на связи и каким путём",
        fixed and "Бот снова на связи" in fixed[0].text and "Telegram —" in fixed[0].text,
        fixed[0].text if fixed else [n for n, _ in SESSION.sent[mark:]])
    text, _ = screen(await press("botm:restart"))
    chk("перезапуск из меню — сразу, без ошибки", "Бот перезапускается" in text, text)
    await botmod.restore(BOT)
    chk("до сих пор бот ничего не удалял", not SESSION.deleted, SESSION.deleted)
    await press("botm:penter")
    await say("socks5://user:secret@127.0.0.1:10808")
    chk("адрес прокси с паролем удалён — единственное, что бот удаляет", SESSION.deleted == {LAST_SAID[0]},
        SESSION.deleted)
    await botmod.restore(BOT)
    with open(ACTIVE, "w") as f:
        f.write("awg-exits-routing.service\n")

    print("Мониторинг")
    from awgbot import monitor
    store.set_note("ghost", "старый клиент #ping")
    store.set_note("alice", "#ping")
    mark = len(SESSION.sent)
    await monitor.tick(BOT, {}, True)
    chk("заметка удалённого клиента убрана", store.note("ghost") == "", store.notes())
    chk("ни разу не подключавшийся клиент не даёт «офлайн»",
        not any(n == "SendMessage" and "офлайн" in (m.text or "") for n, m in SESSION.sent[mark:]))
    # Пустой список клиентов: сервера нет (сброс, восстановление) — заметки остаются;
    # сервер есть, но клиентов ноль (последнего удалили из меню awg2) — чистятся
    conf_path = os.path.join(ROOT, "etc/amnezia/amneziawg/awg0.conf")
    with open(conf_path) as f:
        saved_conf = f.read()
    store.set_note("ghost2", "#ping")
    os.remove(conf_path)
    await monitor.tick(BOT, {}, True)
    chk("без сервера заметки не трогаются", store.note("ghost2") == "#ping" and store.note("alice") == "#ping",
        store.notes())
    with open(conf_path, "w") as f:
        f.write(saved_conf[:saved_conf.index("[Peer]")])
    await monitor.tick(BOT, {}, True)
    chk("сервер без клиентов — заметки удалённых убраны", store.note("ghost2") == "" and store.note("alice") == "",
        store.notes())
    with open(conf_path, "w") as f:
        f.write(saved_conf)
    store.set_note("alice", "#ping")

    print("Ссылка на конфиг без Mini App")
    text, _ = screen(await press("cl:shr:alice"))
    chk("ссылку отдавать некому (Mini App выключена, веб-панели нет) — так и сказано, ссылка не создана",
        "ни одна из них не работает" in text and "/s/" not in text, text)

    print("Шкала обновления")
    from awgbot import progress as prog
    chk("шкала: обновление awg2 и бота — да, прочее — нет",
        prog.kind(("update", "install")) == "update" and prog.kind(("update", "install", "force")) == "update"
        and prog.kind(("bot", "update")) == "bot" and prog.kind(("server", "install")) == "")
    chk("шкала: этап по журналу и следующий", prog.reached("bot", "→ Скачиваю код бота\n→ Зависимости Python...") == (30, 75)
        and prog.reached("update", "") == (0, 10) and prog.reached("update", "√ Установлено: v1") == (92, 100))
    pct, steps = 0.0, []
    for _ in range(60):
        pct = prog.creep(pct, 30, 75)
        steps.append(pct)
    chk("шкала: к следующему этапу понемногу, не дальше него и не назад",
        steps[0] >= 30 and all(b >= a for a, b in zip(steps, steps[1:])) and max(steps) <= 74 and steps[-1] > 70, steps[-3:])
    chk("шкала текстом", prog.bar(50) == "▓▓▓▓▓▓░░░░░░ 50%" and prog.bar(100).startswith("▓" * 12), prog.bar(50))

    print("Случайное имя клиента")
    from awgbot.sections import clients as clmod
    names = {clmod.rand_name({"alice"}) for _ in range(50)}
    chk("случайное имя — 6 букв и цифра, разные", all(re.fullmatch(r"[a-z]{6}[0-9]", n) for n in names) and len(names) > 45,
        sorted(names)[:5])
    text, buttons = screen(await press("cl:addrnd"))
    chk("«🎲 Случайное имя» в боте — новое имя по форме и выбор срока",
        re.search(r"<b>➕ [a-z]{6}[0-9]</b>", text) is not None and "Срок действия" in text, text)
    await press("cl")

    print("Лимит трафика и трафик по дням")
    text, buttons = screen(await press("cl:lim:alice"))
    chk("экран лимита: готовые размеры, свой, период", "Лимит трафика: alice" in text and "без лимита" in text
        and "cl:ls:alice|50G|month" in [d for _, d in buttons] and "cl:lp:alice|total" in [d for _, d in buttons],
        [text, buttons])
    text, buttons = screen(await press("cl:ls:alice|50G|month"))
    chk("лимит 50 ГБ в месяц — в карточке", "Лимит: 0 Б из 50.0 ГБ за месяц (0%)" in text, text)
    await press("cl:lp:alice|total")
    text, _ = screen(await press("cl:lim:bob"))
    chk("период, выбранный у одного клиента, другому не достаётся", "Период для новых значений: <b>за месяц</b>" in text, text)
    text, _ = screen(await press("cl:lim:alice"))
    chk("у своего клиента выбранный период остаётся", "Период для новых значений: <b>всего</b>" in text, text)
    text, buttons = screen(await press("cl:ls:alice|ask|total"))
    chk("свой размер — вопрос", "1.5T" in text, text)
    text, _ = screen(await say("1,5 тб"))
    chk("свой размер «всего»", "Лимит: 0 Б из 1.5 ТБ всего" in text, text)
    sent = await press("cl:lr:alice")
    chk("обнулить счётчик", "Счётчик обнулён" in alerts(sent), alerts(sent))
    text, _ = screen(await press("cl:ls:alice|off|month"))
    chk("снять лимит", "Лимит:" not in text and "📶 Лимит трафика" in [t for t, _ in screen(SESSION.sent)[1]], text)
    text, buttons = screen(await press("cl:lim:alice"))
    chk("экран лимита: что делать при исчерпании — блок (выбран) или замедлять до 1, 2, 5 Мбит/с",
        "Исчерпал лимит — <b>блокировать</b>" in text
        and [d for _, d in buttons if d.startswith("cl:lm:")] == ["cl:lm:alice|block", "cl:lm:alice|1", "cl:lm:alice|2",
                                                                   "cl:lm:alice|5"]
        and any(t.startswith("✅") and "Блокировать" in t for t, _ in buttons), [text, buttons])
    text, buttons = screen(await press("cl:lm:alice|2"))
    chk("«замедлять до 2» — выбрано, в тексте экрана", "Исчерпал лимит — <b>замедлять до 2 Мбит/с</b>" in text
        and any(t.startswith("✅") and "2 Мбит/с" in t for t, _ in buttons), [text, buttons])
    await press("cl:ls:alice|50G|month")
    text, _ = screen(SESSION.sent)
    chk("в карточке — лимит и что при исчерпании", "Лимит: 0 Б из 50.0 ГБ за месяц (0%) · исчерпал — 🐢 до 2 Мбит/с" in text,
        text)
    await press("cl:ls:alice|off|month")
    await press("cl:lm:alice|block")
    text, buttons = screen(await press("cl:spd:alice"))
    chk("экран скорости: без ограничения, готовые 5–100 Мбит/с, своя", "Скорость: alice" in text
        and "без ограничения" in text and "cl:ss:alice|20" in [d for _, d in buttons]
        and "cl:ss:alice|ask" in [d for _, d in buttons] and "cl:ss:alice|off" not in [d for _, d in buttons],
        [text, buttons])
    text, buttons = screen(await press("cl:ss:alice|20"))
    chk("скорость 20 — в карточке", "Скорость: 20 Мбит/с" in text and "cl:spd:alice" in [d for _, d in buttons], text)
    text, buttons = screen(await press("cl:spd:alice"))
    chk("экран скорости: выбранная отмечена, «Без лимита» появилась",
        any(t.startswith("✅") and "20 Мбит/с" in t for t, _ in buttons) and "cl:ss:alice|off" in [d for _, d in buttons],
        buttons)
    text, _ = screen(await press("cl:ss:alice|ask"))
    chk("своя скорость — вопрос", "Мбит/с" in text and "10000" in text, text)
    text, _ = screen(await say("много"))
    chk("своя скорость: не число — повтор вопроса с причиной", "Мбит/с" in text and "Скорость: 20" not in text, text)
    text, _ = screen(await say("35"))
    chk("своя скорость 35", "Скорость: 35 Мбит/с" in text, text)
    text, _ = screen(await press("cl:ss:alice|off"))
    chk("снять ограничение скорости", "Скорость:" not in text, text)
    text, buttons = screen(await press("cl:tday:alice"))
    chk("трафик клиента по дням — столбиками", "трафик по дням" in text and "<pre>" in text
        and text.count("\n", text.index("<pre>")) >= 14, text)
    text, _ = screen(await press("cl:tsrv"))
    chk("трафик сервера по дням", "Трафик сервера по дням" in text and "<pre>" in text, text)

    print("Уведомления о сервере")
    from pathlib import Path
    from awgbot import alerts as al
    real_data, real_disk = al.api.data, al.disk_pct
    al.BOOT_ID = Path(TMP) / "boot_id"
    al.BOOT_ID.write_text("boot-A\n")
    al.CERT_FULL = Path(TMP) / "alert-cert.pem"
    st = {}

    def said(mark):
        return [m.text or "" for n, m in SESSION.sent[mark:] if n == "SendMessage" and m.chat_id == 111]

    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    chk("первый проход: только запоминает загрузку, awg0 — первая неудача", not said(mark)
        and st.get("boot") == "boot-A" and st.get("down") == 1, [said(mark), st])
    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    sent = said(mark)
    rep = [m for n, m in SESSION.sent[mark:] if n == "SendMessage" and "awg0 не работает" in (m.text or "")]
    chk("awg0 лежит две проверки — 🔴 с кнопкой «Починить»", len(sent) == 1 and "awg0 не работает" in sent[0]
        and rep and rep[0].reply_markup.inline_keyboard[0][0].callback_data == "srv:repair", sent)
    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    chk("пока лежит — молчит", not said(mark), said(mark))
    with open(LINKS, "a") as f:
        f.write("awg0\n")
    al.BOOT_ID.write_text("boot-B\n")
    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    sent = said(mark)
    chk("перезагрузка и awg0 вернулся — два сообщения", len(sent) == 2 and any("перезагрузился" in t for t in sent)
        and any("снова работает" in t and "Простой" in t for t in sent), sent)
    with open(LINKS) as f:
        links = f.read()
    with open(LINKS, "w") as f:
        f.write(links.replace("awg0\n", ""))
    # Сервер удалили (сброс), пока awg0 лежал: это не «снова работает»
    st2 = {"down": 2, "down_since": int(time.time()) - 60, "down_sent": True, "boot": "boot-B"}

    async def no_server(*args, **kw):
        if args[:1] == ("status",):
            return {"host": "vm1", "server": {"exists": False, "up": False}}
        return await real_data(*args, **kw)
    al.api.data = no_server
    mark = len(SESSION.sent)
    await al.tick(BOT, st2)
    chk("сервер удалён, пока awg0 лежал, — без ложного «снова работает»",
        not any("снова работает" in t for t in said(mark)) and "down_sent" not in st2, [said(mark), st2])
    # WARP: включён, а туннеля нет — две проверки подряд и кнопка «Включить»; вернулся — с простоем
    warp = {"failed": True, "state": "off", "probe": {"up": False, "health": False, "failover": False}}
    probes = []

    async def warp_status(*args, **kw):
        if args[:1] == ("status",):
            return {"host": "vm1", "server": {"exists": False, "up": False},
                    "tunnels": {"warp": warp["state"], "warp_failed": warp["failed"]}}
        if args[:2] == ("warp", "probe"):
            probes.append(args)
            return dict(warp["probe"])
        return await real_data(*args, **kw)
    al.api.data = warp_status
    st3 = {"boot": "boot-B"}

    def warp_said(mark):
        return [t for t in said(mark) if "WARP" in t]
    mark = len(SESSION.sent)
    await al.tick(BOT, st3)
    chk("WARP упал: первая проверка — молчит", not warp_said(mark), warp_said(mark))
    mark = len(SESSION.sent)
    await al.tick(BOT, st3)
    rep = [m for n, m in SESSION.sent[mark:] if n == "SendMessage" and "WARP упал" in (m.text or "")]
    chk("WARP лежит две проверки — 🟠 с кнопкой «Включить WARP»", len(rep) == 1
        and rep[0].reply_markup.inline_keyboard[0][0].callback_data == "warp:up"
        and "Туннели → WARP → ▶️ Включить" in rep[0].text, warp_said(mark))
    mark = len(SESSION.sent)
    await al.tick(BOT, st3)
    chk("пока WARP лежит — молчит", not warp_said(mark), warp_said(mark))
    warp.update(failed=False, state="up")
    mark = len(SESSION.sent)
    await al.tick(BOT, st3)
    chk("WARP снова работает — с простоем", any("WARP снова работает" in t and "Простой" in t for t in warp_said(mark))
        and "warp_sent" not in st3, [warp_said(mark), st3])
    # Выключили руками, пока лежал: это не «снова работает»
    st4 = {"boot": "boot-B", "warp_down": 2, "warp_since": int(time.time()) - 60, "warp_sent": True}
    warp.update(failed=False, state="off")
    mark = len(SESSION.sent)
    await al.tick(BOT, st4)
    chk("WARP выключили руками, пока лежал, — без ложного «снова работает»",
        not warp_said(mark) and "warp_sent" not in st4, [warp_said(mark), st4])
    # Клиентов увёл health-check (метка failover): он уже проверил трижды — сразу, и вернёт WARP сам
    st5 = {"boot": "boot-B"}
    warp.update(failed=True, state="off", probe={"up": False, "health": True, "failover": True})
    mark = len(SESSION.sent)
    await al.tick(BOT, st5)
    rep = [m for n, m in SESSION.sent[mark:] if n == "SendMessage" and "WARP упал" in (m.text or "")]
    chk("health-check увёл клиентов — уведомление с первой проверки: вернёт WARP сам",
        len(rep) == 1 and "Health-check вернёт его сам" in rep[0].text, warp_said(mark))
    warp.update(failed=False, state="up", probe={"up": True, "health": True, "failover": False, "ok": False})
    mark, n = len(SESSION.sent), len(probes)
    await al.tick(BOT, st5)
    chk("warp0 подняли, а Cloudflare молчит — не «снова работает»: пока сбой не закрыт, бот пингует и с health-check",
        not warp_said(mark) and st5.get("warp_sent") and probes[n:] == [("warp", "probe", "ping")], [warp_said(mark), probes[n:]])
    warp["probe"]["ok"] = True
    mark = len(SESSION.sent)
    await al.tick(BOT, st5)
    chk("health-check вернул WARP — «снова работает»", any("WARP снова работает" in t for t in warp_said(mark)), warp_said(mark))
    # Без health-check бот проверяет поднятый WARP сам: не отвечает — клиенты без интернета
    st6 = {"boot": "boot-B"}
    warp.update(failed=False, state="up", probe={"up": True, "health": False, "failover": False, "ok": False})
    mark = len(SESSION.sent)
    n = len(probes)
    await al.tick(BOT, st6)
    chk("WARP поднят, но не отвечает: бот проверил сам, первая проверка — молчит",
        len(probes) == n + 1 and not warp_said(mark), [probes[n:], warp_said(mark)])
    mark = len(SESSION.sent)
    await al.tick(BOT, st6)
    rep = [m for n_, m in SESSION.sent[mark:] if n_ == "SendMessage" and "WARP не отвечает" in (m.text or "")]
    cbs = [b.callback_data for row in (rep[0].reply_markup.inline_keyboard if rep else []) for b in row]
    chk("не отвечает две проверки — 🟠 «клиенты без интернета», перезапуск и health-check кнопками",
        len(rep) == 1 and "без интернета" in rep[0].text and cbs == ["warp:restart", "warp:health:on"], [warp_said(mark), cbs])
    warp["probe"]["ok"] = True
    mark = len(SESSION.sent)
    await al.tick(BOT, st6)
    chk("снова отвечает — «снова работает» с простоем",
        any("WARP снова работает" in t and "Простой" in t for t in warp_said(mark)) and "warp_sent" not in st6, warp_said(mark))
    # С health-check поднятый WARP бот не пингует: probe отвечает без ok
    warp.update(probe={"up": True, "health": True})
    mark, n = len(SESSION.sent), len(probes)
    await al.tick(BOT, st6)
    await al.tick(BOT, st6)
    chk("с health-check бот не тревожит, пока WARP поднят, и не просит пинг",
        not warp_said(mark) and "warp_down" not in st6 and probes[n:] == [("warp", "probe")] * 2, [warp_said(mark), st6, probes[n:]])
    # WARP выключен — не проверяет вовсе
    warp.update(failed=False, state="off")
    n = len(probes)
    await al.tick(BOT, st6)
    chk("WARP выключен — без проверок", len(probes) == n, probes[n:])
    al.api.data = real_data

    CL = {"newer": True, "sections": [{"version": "v1.2.1", "title": "2026-10-08",
                                        "body": "**Быстрее панель, понятнее бот.**\n\n### Панель\n\n- Переходы — сразу."}]}

    async def fake_data(*args, **kw):
        if args[:1] == ("status",):
            return {"version": "v1.2.0", "host": "vm1", "update": "v1.2.1", "channel": "beta",
                    "components": {"kernel_gap": "6.8.0-150-generic"}, "server": {"exists": True, "up": True}}
        if args[:2] == ("update", "changelog"):
            return CL
        return await real_data(*args, **kw)
    al.api.data = fake_data
    al.disk_pct = lambda: 95
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-days", "1",
                    "-nodes", "-subj", "/CN=alert", "-keyout", os.path.join(TMP, "alert-key.pem"), "-out", str(al.CERT_FULL)],
                   capture_output=True, check=True)
    al.set_enabled("disk", False)
    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    sent = said(mark)
    btns = [b.callback_data for n, m in SESSION.sent[mark:] if n == "SendMessage" and m.reply_markup
            for row in m.reply_markup.inline_keyboard for b in row]
    chk("новая версия, ядро без модуля, сертификат — по сообщению с кнопкой; диск выключен",
        len(sent) == 3 and any("v1.2.1" in t for t in sent) and any("6.8.0-150-generic" in t for t in sent)
        and any("Сертификат Mini App" in t for t in sent) and not any("диск" in t for t in sent)
        and {"upd:go", "upd:notes", "mod:rebuild", "app"} <= set(btns), [sent, btns])
    upd_text = next(t for t in sent if "v1.2.1" in t)
    chk("о новой версии — одна строка для шторки: Тулза, канал, версия",
        upd_text == "🚀 AWG Toolza бета: есть обновление <b>v1.2.1</b>", upd_text)
    text = al.update_text({"version": "v1.2.0", "channel": "stable"}, "v1.2.5")
    chk("стабильный канал — без «бета»", text == "🚀 AWG Toolza: есть обновление <b>v1.2.5</b>", text)
    CL["sections"] = [{"version": "v1.2.1", "title": "2026-10-08",
                       "body": "**Быстрее панель, понятнее бот.**\n\n### Панель\n\n- Переходы — `сразу`."}]
    real_call_n = al.api.call

    async def notes_call(*args, **kw):
        if args[:2] == ("update", "changelog"):
            return al.api.Result(True, data=CL)
        return await real_call_n(*args, **kw)
    al.api.call = notes_call
    text, buttons = screen(await press("upd:notes"))
    al.api.call = real_call_n
    chk("«Что нового»: версия, суть, разделы и пункты; «Обновить» рядом",
        "📋 Что нового" in text and "<b>v1.2.1</b>" in text and "<i>Быстрее панель, понятнее бот.</i>" in text
        and "<b>Панель</b>" in text and "• Переходы — <code>сразу</code>." in text and "**" not in text
        and ("⬆️ Обновить", "upd:go") in buttons, [text, buttons])
    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    chk("повторно о том же — молчит", not said(mark), said(mark))
    admins.add(333, 111)
    st.pop("cert", None)
    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    certs = [(m.chat_id, m.reply_markup) for n, m in SESSION.sent[mark:]
             if n == "SendMessage" and "Сертификат" in (m.text or "")]
    chk("сертификат: кнопка «Mini App» (раздел владельца) — только владельцу, админу — текст",
        sorted(c for c, _ in certs) == [111, 333] and all((k is not None) == (c == 111) for c, k in certs), certs)
    admins.remove(333, removed_by=111)
    al.set_enabled("disk", True)
    al.disk_pct = lambda: 80
    await al.tick(BOT, st)
    al.disk_pct = lambda: 93
    mark = len(SESSION.sent)
    await al.tick(BOT, st)
    chk("диск: после спада ниже 85% — снова тревога", len(said(mark)) == 1 and "93%" in said(mark)[0], said(mark))
    al.api.data, al.disk_pct = real_data, real_disk

    # Пятничное напоминание о поддержке: время — по часам сервера
    fri = int(time.mktime((2026, 10, 16, 13, 0, 0, 0, 0, -1)))     # пятница, 13:00

    def support(mark):
        return [m for n, m in SESSION.sent[mark:] if n == "SendMessage" and "донаты" in (m.text or "")]
    admins.add(333, 111)
    sst = {"support_since": fri - 10 * 86400}
    mark = len(SESSION.sent)
    await al.support_tick(BOT, sst, fri - 86400)                     # четверг
    await al.support_tick(BOT, sst, fri - 2 * 3600)                  # пятница, 11:00
    chk("о поддержке — не в четверг и не до полудня пятницы", not support(mark) and "support" not in sst, sst)
    await al.support_tick(BOT, sst, fri)
    sup = support(mark)
    rows = sup[0].reply_markup.inline_keyboard if sup and sup[0].reply_markup else []
    chk("пятница после полудня — владельцу, не админу: одна кнопка «Поддержать 💚» ссылкой, зелёная",
        [m.chat_id for m in sup] == [111] and len(rows) == 1 and len(rows[0]) == 1
        and rows[0][0].url == "https://t.me/awgToolza/156/157" and rows[0][0].style == "success", [sup, rows])
    mark = len(SESSION.sent)
    await al.support_tick(BOT, sst, fri + 3 * 3600)
    chk("в ту же пятницу — один раз", not support(mark))
    await al.support_tick(BOT, sst, fri + 7 * 86400)
    chk("через неделю — снова", len(support(mark)) == 1, support(mark))
    fresh = {}
    mark = len(SESSION.sent)
    await al.support_tick(BOT, fresh, fri)
    await al.support_tick(BOT, fresh, fri + 2 * 86400 + 3600)
    chk("сразу после установки или обновления бота — не пишет (первые 3 дня)",
        not support(mark) and fresh.get("support_since") == fri, fresh)
    await press("ntf:t:support")
    mark = len(SESSION.sent)
    await al.support_tick(BOT, sst, fri + 14 * 86400)
    chk("выключено в «Уведомлениях» — напоминаний нет", not al.enabled("support") and not support(mark), al.config())
    al.set_enabled("support", True)
    admins.remove(333, removed_by=111)

    print("Автобэкап")
    text, buttons = screen(await press("bk"))
    chk("в «Бэкапах» — строка и кнопка автобэкапа", "Автобэкап: выключен" in text and ("🕒 Автобэкап", "abk") in buttons,
        [text, buttons])
    text, buttons = screen(await press("abk"))
    chk("экран автобэкапа", "abk:m:day" in [d for _, d in buttons] and "abk:k:7" in [d for _, d in buttons], buttons)
    await press("abk:m:day")
    await press("abk:k:3")
    chk("режим и сколько хранить — сохранены", al.config()["backup"] == {"mode": "day", "keep": 3}, al.config())
    mark = len(SESSION.sent)
    done = await al.backup_due(BOT)
    d = [m for n, m in SESSION.sent[mark:] if n == "SendDocument"]
    chk("первый автобэкап — сразу, файлом владельцу", done and len(d) == 1 and d[0].chat_id == 111
        and "Автобэкап" in d[0].caption, [n for n, _ in SESSION.sent[mark:]])
    info = al.backup_info()
    chk("автобэкап записан: время, без ошибки, только архив", info["last"] and info["ok"] and not info["error"]
        and any(f.endswith("_auto.tar.gz") for f in os.listdir(os.path.join(ROOT, "awg_backup")))
        and not any(f.endswith("_auto") for f in os.listdir(os.path.join(ROOT, "awg_backup"))), info)
    mark = len(SESSION.sent)
    chk("до срока — не повторяется", not await al.backup_due(BOT) and not docs(SESSION.sent[mark:]))
    t0 = int(time.time()) - 86400 - 120
    al.store.save(al.BACKUP_STATE, {"last": t0, "slot": t0, "ok": True})
    res = await al.backup_due(BOT)
    bst = al.store.load(al.BACKUP_STATE)
    chk("расписание держится за слот, а не за момент проверки", res == "done" and bst["slot"] == t0 + 86400
        and bst["last"] > t0 + 86400, bst)
    real_deliver = al._deliver

    async def undelivered(fn, uid):
        return False
    al._deliver = undelivered
    before = al.backup_info()["last"]
    res = await al.backup_due(BOT, force=True)
    info = al.backup_info()
    al._deliver = real_deliver
    chk("автобэкап не дошёл ни до кого — неудача; время последнего удачного не тронуто, повтор через час",
        res == "fail" and info["last"] == before and not info["ok"] and "не дошёл" in info["error"]
        and info["next"] >= time.time() + 3500, [res, info])
    chk("до повтора — не повторяется", await al.backup_due(BOT) == "")
    bst = al.store.load(al.BACKUP_STATE)
    year = int(time.time()) + 365 * 86400       # записано, когда часы ушли на год вперёд
    al.store.save(al.BACKUP_STATE, {**bst, "slot": year, "retry_at": year + 3600})
    res = await al.backup_due(BOT)
    bst = al.store.load(al.BACKUP_STATE)
    chk("слот и повтор «через год» (часы уходили вперёд) — не ждём, бэкап делается, слот — сейчас",
        res == "done" and bst["slot"] <= time.time() and not bst.get("retry_at"), [res, bst])
    # Бэкап делается до 300 с раньше слота, и следующий слот ложится чуть впереди:
    # это не скачок часов, повторного бэкапа быть не должно
    al.store.save(al.BACKUP_STATE, {**bst, "slot": int(time.time()) + 200, "last": int(time.time()) - 100})
    mark = len(SESSION.sent)
    chk("слот на 200 с впереди (бэкап был чуть раньше срока) — второго бэкапа нет",
        await al.backup_due(BOT) == "" and not docs(SESSION.sent[mark:]))
    real_call = al.api.call

    async def busy_call(*a, **kw):
        return al.api.Result(False, 75, error="Идёт другая операция")
    al.api.call = busy_call
    text, _ = screen(await press("abk:now"))
    al.api.call = real_call
    chk("«Сделать сейчас», пока идёт другая операция, — так и сказано", "другая операция" in text, text)
    admin = User(id=333, is_bot=False, first_name="Admin")
    admins.add(333, 111)
    denied = [alerts(await press(x, admin)) for x in ("abk", "abk:m:off", "ntf", "ntf:t:iface")]
    chk("автобэкап и уведомления настраивает только владелец", all(a and "только владелец" in a[0] for a in denied)
        and al.config()["backup"]["mode"] == "day" and al.enabled("iface"), denied)
    text, buttons = screen(await press("bk", admin))
    chk("админу кнопки автобэкапа не видно", "abk" not in [d for _, d in buttons], buttons)
    admins.remove(333, removed_by=111)
    text, buttons = screen(await press("ntf"))
    chk("экран уведомлений", "Уведомления" in text and "ntf:t:kernel" in [d for _, d in buttons], buttons)
    await press("ntf:t:kernel")
    chk("выключение уведомления", not al.enabled("kernel") and al.enabled("update"), al.config())
    await press("ntf:t:kernel")
    await press("abk:m:off")

    print("Кэш вызовов awg2")
    from awgbot import api as apimod
    runs = []
    real_run = apimod._run

    async def counting(*args, **kw):
        runs.append(args)
        return await real_run(*args, **kw)
    apimod._run, apimod.CACHE_TTL = counting, 5.0
    try:
        apimod.invalidate()
        a, b = await asyncio.gather(apimod.call("status"), apimod.call("status"))
        chk("одновременные одинаковые чтения — один вызов awg2", a.ok and b.ok and len(runs) == 1, runs)
        await apimod.call("status")
        chk("повторное чтение в пределах TTL — из кэша", len(runs) == 1, runs)
        await apimod.call("job", "status", "20990101-000000-0000")
        await apimod.call("status")
        chk("опрос задачи кэш не сбрасывает", sum(1 for x in runs if x[:1] == ("status",)) == 1, runs)
        await apimod.call("traffic", "now")
        await apimod.call("status")
        chk("живая скорость (traffic now) кэш не сбрасывает", sum(1 for x in runs if x[:1] == ("status",)) == 1, runs)
        await apimod.call("client", "limit", "nobody", "1G")
        await apimod.call("status")
        chk("изменение сбрасывает кэш — следующее чтение свежее", sum(1 for x in runs if x[:1] == ("status",)) == 2, runs)
        # Запись во время чтения: «свежий» вызов (после записи) заканчивается раньше
        # «старого». Без счётчика поколений старый результат лёг бы в кэш поверх
        # свежего; без сброса _inflight запрос после записи получил бы старый
        evs, nums = [], []

        async def numbered(*args, **kw):
            runs.append(args)
            n = len(nums) + 1
            nums.append(n)
            ev = asyncio.Event()
            evs.append(ev)
            await ev.wait()
            return apimod.Result(True, 0, {"n": n})
        apimod._run = numbered
        apimod.invalidate()
        runs.clear()
        t1 = asyncio.ensure_future(apimod.call("status"))
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        apimod.invalidate()                 # запись, пока чтение ещё идёт
        t2 = asyncio.ensure_future(apimod.call("status"))
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        for ev in reversed(evs):            # свежий — первым, старый — следом
            ev.set()
            await asyncio.sleep(0)
            await asyncio.sleep(0)
        r1, r2 = await asyncio.gather(t1, t2)
        try:                                # лишний вызов ждал бы события вечно — это провал, а не зависание
            r3 = await asyncio.wait_for(apimod.call("status"), 5)
        except asyncio.TimeoutError:
            r3 = apimod.Result(False, 124)
        for ev in evs:
            ev.set()
        chk("чтение, начатое до записи: после неё — свой вызов, старое в кэш не легло",
            (r1.data, r2.data, r3.data) == ({"n": 1}, {"n": 2}, {"n": 2}) and len(runs) == 2,
            [r1.data, r2.data, r3.data, runs])

        async def slow(*args, **kw):
            runs.append(args)
            if args[:1] == ("status",):
                await gate.wait()
            return await real_run(*args, **kw)
        apimod._run = slow
        gate = asyncio.Event()
        apimod.invalidate()
        t1 = asyncio.ensure_future(apimod.call("status"))
        t2 = asyncio.ensure_future(apimod.call("status"))
        await asyncio.sleep(0)
        t1.cancel()
        await asyncio.sleep(0)
        gate.set()
        try:
            ok2 = (await t2).ok
        except asyncio.CancelledError:
            ok2 = False
        chk("отмена одного из ждущих не отменяет вызов остальным", t1.cancelled() and ok2)
    finally:
        apimod._run, apimod.CACHE_TTL = real_run, 0.0
        apimod.invalidate()

    print("Все экраны")
    screens = ["srv", "mod", "srv:proto", "srv:par", "srv:ep", "srv:install", "srv:reset", "srv:reboot",
               "cl:activity", "cl:exp:alice", "cl:mim:alice", "cl:tun:alice", "cl:ren:alice",
               "cl:lim:alice", "cl:spd:alice", "cl:tday:alice", "cl:tsrv", "ntf", "abk",
               "diag", "diag:status", "diag:dpi", "diag:logs", "diag:log:manager", "diag:sniff",
               "bk", "bk:list", "tun", "tc::warp", "warp", "warp:backend", "xr", "t2s", "ex", "cas", "dns",
               "botm", "botm:proxy", "adm", "del", "del:all", "upd", "wo", "wo:install", "web"]
    broken = []
    for data in screens:
        sent = await press(data)
        text, buttons = screen(sent)
        if any("Ошибка" in a for a in alerts(sent)) or not text or not buttons:
            broken.append((data, text[:80]))
    chk(f"все {len(screens)} экранов открываются, у каждого есть кнопки", not broken, broken)
    # Подписи — в половину экрана: иначе Telegram режет их многоточием.
    # Имена клиентов, нод и тегов задаёт пользователь — их не считаем.
    wide = sorted({b.text for name, m in SESSION.sent if name in ("SendMessage", "EditMessageText")
                   and m.reply_markup for row in m.reply_markup.inline_keyboard for b in row
                   if ui.width(b.text) > ui.WIDE and not (b.callback_data or "").startswith(USER_NAMED)})
    chk("все кнопки влезают в два столбца", not wide, wide)
    rows = [len(row) for name, m in SESSION.sent if name in ("SendMessage", "EditMessageText") and m.reply_markup
            for row in m.reply_markup.inline_keyboard]
    chk("в два столбца, не одним списком", rows.count(2) >= rows.count(1), (rows.count(2), rows.count(1)))

    print("Задачи")
    screen_before = SESSION.screen_id()
    sent = await press("bk:create")
    chk("задача идёт в том же экране, без новых сообщений",
        not any(n == "SendMessage" for n, _ in sent)
        and any(n == "EditMessageText" and "Бэкап" in (m.text or "") and m.message_id == screen_before
                for n, m in sent), [n for n, _ in sent])
    chk("задача завершилась", await wait_jobs())
    chk("архив бэкапа отправлен", any(n == "SendDocument" and "Бэкап" in (m.caption or "") for n, m in SESSION.sent))
    last = [m for n, m in SESSION.sent if n in ("SendMessage", "EditMessageText") and "Бэкап" in (m.text or "")][-1]
    chk("итог задачи — в том же сообщении", last.text.startswith("✅") and last.message_id == screen_before,
        last.text[:60])
    no_hourglass("после задачи")
    chk("незавершённых задач не осталось", store.jobs() == {}, store.jobs())

    print("WG + обфускатор")
    os.makedirs(os.path.join(ROOT, "etc/awg-wgobf"), exist_ok=True)
    with open(os.path.join(ROOT, "etc/awg-wgobf/state"), "w") as f:
        f.write("ENDPOINT=203.0.113.10\nPORT=45888\nKEY=obfkey\nMASKING=STUN\nMTU=1380\nDNS=1.1.1.1\n"
                "SERVER_PUB=SRVPUB=\nALLOW_CLEAN=0\n")
    os.makedirs(os.path.join(ROOT, "etc/wireguard"), exist_ok=True)
    with open(os.path.join(ROOT, "etc/wireguard/wgobf0.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = S\nListenPort = 45888\n\n[Peer]\n# client=clus\nPublicKey = CPUB=\n"
                "AllowedIPs = 10.77.1.2/32\n")
    cdir = os.path.join(ROOT, "root/wgobf/clus")
    os.makedirs(cdir, exist_ok=True)
    with open(os.path.join(cdir, "wg.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = CPRIV=\nAddress = 10.77.1.2/32\n\n[Peer]\nPresharedKey = PSK=\n")
    text, buttons = screen(await press("wo:v:clus"))
    datas = [d for _, d in buttons]
    chk("карточка клиента: IP и две кнопки выдачи", "10.77.1.2" in text and "wo:bundle:clus" in datas
        and "wo:zip:clus" in datas, [text, buttons])
    sent = await press("wo:bundle:clus")
    msgs = [m.text or "" for n, m in sent if n == "SendMessage"]
    d = docs(sent)
    chk("ссылка phobos:// и конфиг — текстом",
        any("phobos://" in t and "<pre>" in t and "[instance]" in t and "CPRIV=" in t for t in msgs), msgs)
    chk("и один файл .conf со всеми данными",
        len(d) == 1 and d[0].document.filename == "clus.conf" and b"[Interface]" in d[0].document.data
        and b"[instance]" in d[0].document.data and b"key = obfkey" in d[0].document.data,
        [x.document.filename for x in d])
    chk("файлы — после текста", [n for n, _ in sent if n in ("SendMessage", "SendDocument")]
        == ["SendMessage", "SendDocument"], [n for n, _ in sent])
    sent = await press("wo:zip:clus")
    chk("архив для Linux — отдельной кнопкой", docs(sent) and docs(sent)[0].document.filename == "wgobf-clus.zip",
        [n for n, _ in sent])

    # Выход клиентов обфускатора: на выбор — только настроенные туннели
    text, buttons = screen(await press("wo"))
    chk("обфускатор: «Выход клиентов: напрямую» и кнопка выбора выхода",
        "Выход клиентов: <b>напрямую</b>" in text and ("🌐 Выход клиентов", "wo:rt:*") in buttons, [text, buttons])
    text, buttons = screen(await press("wo:rt:*"))
    chk("на выбор — настроенные туннели (WARP не настроен — его нет), свои выходы Xray, какой туннель работает",
        ("🔘 Напрямую", "wo:rs:*|d") in buttons and not any(d == "wo:rs:*|w" for _, d in buttons)
        and ("⚪️ Xray: по умолчанию", "wo:rs:*|x") in buttons and ("⚪️ Xray: de", "wo:rs:*|x0") in buttons
        and "Работает туннель: exit-ноды." in text, [text, buttons])
    warp_conf, wl = os.path.join(ROOT, "etc/wireguard/warp0.conf"), os.path.join(ROOT, "warp.peers.wgobf")
    with open(warp_conf, "w") as f:
        f.write("[Interface]\nPrivateKey = P\nAddress = 172.16.0.2/32\n")
    text, buttons = screen(await press("wo:rt:*"))
    chk("WARP настроен — «Через WARP» на выбор", ("⚪️ Через WARP", "wo:rs:*|w") in buttons
        and ("🔘 Напрямую", "wo:rs:*|d") in buttons, buttons)
    text, buttons = screen(await press("wo:rs:*|w"))
    chk("«Через WARP» — адреса клиентов обфускатора в списке WARP, экран: выбрано, WARP выключен",
        os.path.exists(wl) and open(wl).read().split() == ["10.77.1.2"] and ("🔘 Через WARP", "wo:rs:*|w") in buttons
        and "через WARP</b> — WARP выключен, пока напрямую" in text, [text, buttons])
    text, buttons = screen(await press("wo"))
    chk("главный экран: «через WARP — WARP выключен, пока напрямую»",
        "через WARP</b> — WARP выключен, пока напрямую" in text, text)
    text, buttons = screen(await press("wo:v:clus"))
    chk("карточка клиента: выход и кнопка «Маршрут»", "Выход: через WARP" in text
        and ("🌐 Маршрут", "wo:rt:clus") in buttons, [text, buttons])
    text, buttons = screen(await press("wo:list"))
    chk("в списке клиентов — выход, если не напрямую", "🌐 через WARP" in text, text)
    text, buttons = screen(await press("wo:rs:clus|d"))
    chk("свой выход клиенту — «напрямую»: из списка WARP, экран клиента", not open(wl).read().strip()
        and "Выход: clus" in text and ("🔘 Напрямую", "wo:rs:clus|d") in buttons, [text, buttons, open(wl).read()])
    text, buttons = screen(await press("wo:rs:clus|x3"))
    chk("устаревшая кнопка (выхода нет) — экран выбора заново, без записи", ("🔘 Напрямую", "wo:rs:clus|d") in buttons
        and not open(wl).read().strip(), [text, buttons])
    # Exit-ноды есть (две) — общий выход и каждая нода на выбор
    ex_dir = os.path.join(ROOT, "etc/amnezia/amneziawg")
    for n in ("q1", "q2"):
        open(os.path.join(ex_dir, f"awg-exit-{n}.conf"), "w").close()
    text, buttons = screen(await press("wo:rt:clus"))
    chk("exit-ноды на выбор: общий выход и каждая нода", ("⚪️ Exit-ноды: общий", "wo:rs:clus|e") in buttons
        and any(d.startswith("wo:rs:clus|e") and "Нода q2" in t for t, d in buttons), buttons)
    q2 = next(d for t, d in buttons if "Нода q2" in t)
    text, buttons = screen(await press(q2))
    el = os.path.join(ex_dir, "exits_peers.list.wgobf")
    chk("клиент → нода q2: в списке exit-нод обфускатора «адрес|нода», экран: выбрано (ноды работают)",
        open(el).read().split() == ["10.77.1.2|q2"] and "через exit-ноду q2</b>\n" in text
        and any(t.startswith("🔘 Нода q2") for t, _ in buttons), [text, buttons, open(el).read()])
    await press("wo:rs:clus|d")
    for n in ("q1", "q2"):
        os.remove(os.path.join(ex_dir, f"awg-exit-{n}.conf"))
    os.remove(warp_conf)

    # Трафик и мониторинг клиента обфускатора: dump wgobf0 — рукопожатие минуту назад
    import time as _t
    from awgbot import monitor as _mon

    def wg_dump(ago):
        with open(WG_DUMP, "w") as f:
            f.write(f"SRVPRIV=\tSRVPUB=\t45888\toff\nCPUB=\tPSK=\t127.0.0.1:40000\t10.77.1.2/32\t"
                    f"{int(_t.time()) - ago}\t1048576\t2097152\t25\n")
    wg_dump(60)
    text, buttons = screen(await press("wo:v:clus"))
    chk("карточка клиента обфускатора: трафик с запуска и мониторинг выключен",
        "↓ 1.0 МБ · ↑ 2.0 МБ" in text and "🔕 выкл" in text and ("🔔 Мониторинг", "wo:mon:clus") in buttons, [text, buttons])
    text, buttons = screen(await press("wo:mon:clus"))
    chk("мониторинг включается кнопкой — своя метка, не заметка AWG-клиента с тем же именем",
        "🔔 вкл" in text and store.monitored("wgobf:clus") and not store.monitored("clus"), [text, store.notes()])
    st = {}
    await _mon.tick(BOT, st, True)
    chk("клиент в сети — молчит, метка не стёрта чисткой AWG-заметок",
        "wgobf:clus" not in st and store.monitored("wgobf:clus"), [st, store.notes()])
    wg_dump(900)
    mark = len(SESSION.sent)
    await _mon.tick(BOT, st, True)
    off = [m.text or "" for n, m in SESSION.sent[mark:] if n == "SendMessage"]
    chk("пропал больше 5 минут — «офлайн» с пометкой обфускатора", any("офлайн" in t and "clus · WG + обфускатор" in t
                                                                        for t in off) and "wgobf:clus" in st, [off, st])
    wg_dump(5)
    mark = len(SESSION.sent)
    await _mon.tick(BOT, st, True)
    back = [m.text or "" for n, m in SESSION.sent[mark:] if n == "SendMessage"]
    chk("вернулся — «снова онлайн»", any("снова онлайн" in t and "clus" in t for t in back) and "wgobf:clus" not in st,
        [back, st])
    # awg2 не ответил по обфускатору: состояние офлайн-клиента остаётся, второго 🔴 после ответа нет
    wg_dump(900)
    await _mon.tick(BOT, st, True)
    real_data = _mon.api.data

    async def no_wgobf(*a, **kw):
        return None if a[:2] == ("wgobf", "clients") else await real_data(*a, **kw)
    _mon.api.data = no_wgobf
    try:
        await _mon.tick(BOT, st, True)
    finally:
        _mon.api.data = real_data
    mark = len(SESSION.sent)
    await _mon.tick(BOT, st, True)
    again = [m.text or "" for n, m in SESSION.sent[mark:] if n == "SendMessage" and "офлайн" in (m.text or "")]
    chk("нет ответа по обфускатору — офлайн-клиент не даёт второго «офлайн»", not again and "wgobf:clus" in st,
        [again, st])
    os.remove(WG_DUMP)

    text, buttons = screen(await press("wo:v:clus"))
    chk("карточка клиента обфускатора: кнопка «Переименовать»", ("✏️ Переименовать", "wo:ren:clus") in buttons, buttons)
    text, _ = screen(await press("wo:ren:clus"))
    chk("переименование обфускатора: вопрос про новое имя", "Новое имя" in text and "clus" in text, text)
    text, _ = screen(await say("bad name"))
    chk("переименование: недопустимое имя — повторный вопрос", "латиница" in text, text)
    text, _ = screen(await say("clus2"))
    with open(os.path.join(ROOT, "etc/wireguard/wgobf0.conf")) as f:
        wgc = f.read()
    chk("переименование обфускатора: карточка с новым именем, мониторинг переехал, комплект — в новом каталоге",
        "clus2" in text and "# client=clus2\n" in wgc and "# client=clus\n" not in wgc
        and store.monitored("wgobf:clus2") and not store.monitored("wgobf:clus")
        and os.path.isfile(os.path.join(ROOT, "root/wgobf/clus2/wg.conf")), [text, wgc, store.notes()])
    await press("wo:ren:clus2")
    text, _ = screen(await say("clus"))
    chk("и обратно — карточка clus", "<b>🛡 clus</b>" in text and store.monitored("wgobf:clus"), text)

    text, buttons = screen(await press("wo:install"))
    chk("установка обфускатора: DNS по умолчанию Cloudflare", "DNS клиентов: Cloudflare" in text, text)
    text, buttons = screen(await press("wo:iopt:dns"))
    chk("кнопка DNS перебирает варианты", "DNS клиентов: Google" in text and ("🌐 Google", "wo:iopt:dns") in buttons,
        [text, buttons])

    print("Mini App")
    fake_acme()
    webapp.CONF_PATH = os.path.join(ROOT, "bot.conf")        # тот же файл, что пишет awg2
    ports = []
    for _ in range(2):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            ports.append(s.getsockname()[1])
    with open(os.path.join(ROOT, "bot.conf"), "a") as f:
        f.write(f"WEBAPP_PORT={ports[0]}\n")
    text, buttons = screen(await press("app"))
    chk("экран Mini App: сертификата нет, сервер не запущен",
        "Сертификата нет" in text and "не запущена" in text and ("🔐 На IP", "app:ip") in buttons
        and not any((d or "").startswith("webapp:") for _, d in buttons), [text, buttons])
    await press("app:ip")
    chk("сертификат на IP — задачей", await wait_jobs())
    url = f"https://203.0.113.10:{ports[0]}/"
    chk("после выпуска сервер Mini App поднялся по адресу сертификата",
        webapp.SERVER.running and webapp.SERVER.url == url, [webapp.SERVER.url, webapp.SERVER.error])

    def menus():
        return [(m.chat_id, m.menu_button.type, getattr(getattr(m.menu_button, "web_app", None), "url", None))
                for n, m in SESSION.sent if n == "SetChatMenuButton"]

    chk("кнопка «Меню» у владельца открывает панель", (111, "web_app", url) in menus(), menus())
    mark = len(SESSION.sent)
    await say("/start")
    chk("/start освежает кнопку «Меню» (приглашённым тоже)",
        any(n == "SetChatMenuButton" and m.chat_id == 111 for n, m in SESSION.sent[mark:]))
    mark = len(SESSION.sent)
    await say("/start", STRANGER)
    chk("чужому кнопку «Меню» не трогаем", not any(n == "SetChatMenuButton" for n, _ in SESSION.sent[mark:]))
    text, buttons = screen(await press("app"))
    chk("кнопка «Открыть панель» — Mini App по этому адресу",
        ("📱 Открыть панель", "webapp:" + url) in buttons and "Сертификат: <code>203.0.113.10</code> (IP)" in text,
        [text, buttons])

    token = BOT.token

    def init_data(uid, auth=None, tamper=False, signature=False, extra=None):
        fields = {"auth_date": str(int(auth or time.time())), "query_id": "AAHd",
                  "user": json.dumps({"id": uid, "first_name": "Max", **(extra or {})}, separators=(",", ":"))}
        if signature:
            fields["signature"] = "c2ln"
        secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
        fields["hash"] = hmac.new(secret, "\n".join(f"{k}={v}" for k, v in sorted(fields.items())).encode(),
                                  hashlib.sha256).hexdigest()
        if tamper:
            fields["user"] = fields["user"].replace("Max", "Eve")
        return urlencode(fields)

    chk("подпись initData: верная — пользователь", (webapp.check_init_data(init_data(111), token) or {}).get("id") == 111)
    chk("подпись с полем signature тоже принимается",
        (webapp.check_init_data(init_data(111, signature=True), token) or {}).get("id") == 111)
    chk("подделка, чужой токен и старые данные — отказ",
        webapp.check_init_data(init_data(111, tamper=True), token) is None
        and webapp.check_init_data(init_data(111), "1:other") is None
        and webapp.check_init_data(init_data(111, auth=time.time() - 3 * 86400), token) is None
        and webapp.check_init_data("", token) is None)
    chk("подпись initData: hash не из ASCII — отказ, а не исключение (500 в журнале бота)",
        webapp.check_init_data(init_data(111).split("&hash=")[0] + "&hash=%D0%BF%D1%80", token) is None
        and webapp.check_init_data(init_data(111).split("&hash=")[0] + "&hash=\udcff", token) is None
        and webapp.check_init_data("user=\udcff&auth_date=1&hash=ab", token) is None)

    base = f"https://127.0.0.1:{ports[0]}"
    async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=False)) as http:
        async with http.get(base + "/") as r:
            page = await r.text()
        chk("страница Mini App отдаётся по HTTPS", r.status == 200 and "telegram-web-app.js" in page, r.status)

        async def post(path, data=None):
            headers = {"Authorization": "tma " + data} if data is not None else {}
            async with http.post(base + path, headers=headers) as r:
                return r.status, await r.json(content_type=None)

        st, body = await post("/api/me")
        chk("API без подписи Telegram — 401", st == 401, [st, body])
        st, body = await post("/api/me", init_data(111))
        chk("владелец входит", st == 200 and body.get("id") == 111 and body.get("owner") is True, [st, body])
        st, body = await post("/api/me", init_data(222))
        chk("чужой с настоящей подписью — 403", st == 403, [st, body])
        st, body = await post("/api/me", init_data(111, tamper=True))
        chk("подделанные данные — 401", st == 401, [st, body])
        st, body = await post("/api/status", init_data(111))
        chk("сводка сервера через Mini App", st == 200 and body.get("version") and "server" in body, [st, str(body)[:200]])

        # ── API панели ──
        async def api_(path, data, uid=111, extra=None):
            async with http.post(base + path, json=data, headers={"Authorization": "tma " + init_data(uid, extra=extra)}) as r:
                return r.status, await r.json(content_type=None)

        async with http.get(base + "/app.js") as r:
            chk("скрипт панели отдаётся", r.status == 200 and "runJob" in await r.text(), r.status)
        async with http.get(base + "/icons.js") as r:
            chk("иконки панели отдаются", r.status == 200 and "const ICONS" in await r.text(), r.status)
        async with http.get(base + "/") as r:
            page, hd = await r.text(), r.headers
        m = re.search(r'src="app\.js\?v=([0-9a-f]{16})"', page)
        chk("страница Mini App: сжата gzip, скрипты — с отпечатком версии, сама — со сверкой (ETag)",
            hd.get("Content-Encoding") == "gzip" and m is not None and re.search(r'src="icons\.js\?v=[0-9a-f]{16}"', page)
            and hd.get("Cache-Control") == "no-cache" and hd.get("ETag"), dict(hd))
        async with http.get(base + "/", headers={"If-None-Match": hd.get("ETag", "")}) as r:
            chk("повторное открытие страницы — 304 без тела", r.status == 304 and not await r.read(), r.status)
        async with http.get(base + f"/app.js?v={m.group(1) if m else ''}") as r:
            chk("app.js с отпечатком — сжат и хранится браузером до новой версии", r.status == 200
                and r.headers.get("Content-Encoding") == "gzip" and "immutable" in r.headers.get("Cache-Control", ""),
                dict(r.headers))
        async with http.get(base + "/app.js?v=0123456789abcdef") as r:
            chk("чужой отпечаток — со сверкой, не «навсегда»", r.headers.get("Cache-Control") == "no-cache",
                dict(r.headers))
        # Встроенный браузер Telegram Desktop для Windows без WebView2 — Edge 18:
        # ES2017 и ни шагу дальше, иначе панель не запускается вовсе
        legacy = []
        for fn in ("app.js", "icons.js"):
            src = open(os.path.join(HERE, "..", "awg_bot", "awgbot", "webapp", fn), encoding="utf-8").read()
            code = re.sub(r'"(?:\\.|[^"\\\n])*"|`(?:\\.|[^`\\])*`|//[^\n]*|/\*.*?\*/', '""', src, flags=re.S)
            for what, pat in (("catch без переменной", r"catch\s*\{"), ("??", r"\?\?"), ("?.", r"\?\.[A-Za-z_$(\[]"),
                              ("разворот объекта", r"\{\s*\.\.\.|,\s*\.\.\.[\w.]+\s*\}"), ("\\p{} в регулярке", r"/[^/\n]*\\p\{")):
                legacy += [f"{fn}: {what}" for _ in re.findall(pat, code)]
        chk("панель — без синтаксиса новее ES2017 (Edge 18 в Telegram Desktop)", not legacy, legacy)
        async with http.get(base + "/fonts/plex-mono-latin-500.woff2") as r:
            chk("шрифт «Карточек» отдаётся: woff2, кэш на неделю", r.status == 200 and (await r.read())[:4] == b"wOF2"
                and r.headers.get("Content-Type") == "font/woff2" and r.headers.get("Cache-Control") == "public, max-age=604800",
                [r.status, dict(r.headers)])
        bad = []
        for path in ("/fonts/OFL.txt", "/fonts/none.woff2", "/fonts/..%2fapp.js", "/fonts/"):
            async with http.get(base + path) as r:
                bad += [path] if r.status != 404 else []
        chk("шрифты: только .woff2 из своего каталога", not bad, bad)
        async with http.get(base + "/panel.py") as r:
            chk("кроме страницы, скрипта, иконок и шрифтов — ничего", r.status == 404, r.status)
        print("Ссылка на конфиг на 5 минут")
        from awgbot import share as shmod
        st, d = await post("/api/client/share")
        chk("ссылку без подписи Telegram не создать", st == 401, [st, d])
        st, d = await api_("/api/client/share", {"name": "alice"})
        surl = d.get("url") or ""
        tok = surl.rsplit("/", 1)[-1]
        chk("ссылка: адрес панели без пути, 192 бита, id для отзыва, 5 минут",
            st == 200 and re.fullmatch(rf"https://127\.0\.0\.1:{ports[0]}/s/[A-Za-z0-9_-]{{32}}", surl) is not None
            and re.fullmatch(r"[0-9a-f]{12}", d.get("id") or "") and 290 <= d["exp"] - time.time() <= 300, d)
        raw = open(shmod._file()).read()
        chk("на диске — только отпечаток ссылки, права 600", tok and tok not in raw and len(json.loads(raw)) >= 1
            and oct(os.stat(shmod._file()).st_mode & 0o777) == "0o600", raw[:200])
        async with http.get(base + f"/s/{tok}") as r:
            page, hd = await r.text(), r.headers
        chk("страница по ссылке: оболочка без конфига (предпросмотр мессенджеров его не получит), без кэша, "
            "не индексируется, не во фрейм, строгий CSP, referrer — только своему адресу",
            r.status == 200 and "PrivateKey" not in page and "Показать QR и конфиг" in page
            and hd.get("Cache-Control") == "no-store" and "noindex" in hd.get("X-Robots-Tag", "")
            and hd.get("X-Frame-Options") == "DENY" and "default-src 'none'" in hd.get("Content-Security-Policy", "")
            and "frame-ancestors 'none'" in hd.get("Content-Security-Policy", "") and hd.get("Referrer-Policy") == "same-origin",
            [r.status, dict(hd)])
        chk("в шапке страницы ссылки — «Telegram» со значком слева и «Поддержать» справа, в новой вкладке, без referrer",
            'href="https://t.me/awgToolza" target="_blank" rel="noopener noreferrer"' in page
            and 'href="https://t.me/awgToolza/156/157" target="_blank" rel="noopener noreferrer"' in page
            and "Поддержать" in page and ">Telegram</a>" in page and "<svg" in page, page[:600])
        async with http.post(base + f"/s/{tok}/data", json={}) as r:
            sd = await r.json(content_type=None)
        chk("по кнопке — конфиг, QR и имя файла", r.status == 200 and "PrivateKey" in (sd.get("text") or "")
            and sd.get("file") == "alice.conf" and (sd.get("qr") is None or len(sd["qr"]) > 100), [r.status, str(sd)[:200]])
        async with http.post(base + f"/s/{tok}/file") as r:
            body_ = await r.text()
            cd = r.headers.get("Content-Disposition", "")
        chk("файл — alice.conf, вложением", r.status == 200 and cd == 'attachment; filename="alice.conf"'
            and body_ == sd.get("text"), [r.status, cd])
        async with http.get(base + "/s.js") as r:
            chk("скрипт страницы ссылки отдаётся", r.status == 200 and "Скопировать" in await r.text(), r.status)
        async with http.get(base + "/s/" + "A" * 32) as r:
            gone = await r.text()
            chk("чужая ссылка — «недействительна», 404, шапка та же", r.status == 404 and "недействительна" in gone
                and "https://t.me/awgToolza/156/157" in gone, r.status)
        st, d2 = await api_("/api/client/share/revoke", {"id": d.get("id")})
        async with http.post(base + f"/s/{tok}/data", json={}) as r:
            chk("«Отозвать» — ссылка больше не отдаёт конфиг", st == 200 and d2.get("ok") is True and r.status == 404,
                [st, d2, r.status])
        # Истекла: 5 минут прошли
        st, d = await api_("/api/client/share", {"name": "alice"})
        tok = d["url"].rsplit("/", 1)[-1]
        recs = json.loads(open(shmod._file()).read())
        for v in recs.values():
            v["exp"] = int(time.time()) - 1
        with open(shmod._file(), "w") as f:
            json.dump(recs, f)
        async with http.get(base + f"/s/{tok}") as r:
            chk("через 5 минут — недействительна", r.status == 404, r.status)
        # Под тем же именем уже другой клиент (ключ не совпадает) — ничего
        st, d = await api_("/api/client/share", {"name": "alice"})
        tok = d["url"].rsplit("/", 1)[-1]
        recs = json.loads(open(shmod._file()).read())
        for v in recs.values():
            v["pub"] = "OTHERKEY="
        with open(shmod._file(), "w") as f:
            json.dump(recs, f)
        async with http.post(base + f"/s/{tok}/file") as r:
            chk("клиент с тем же именем, но другим ключом — конфиг не отдаётся", r.status == 404, r.status)
        st, d = await api_("/api/client/share", {"name": "nobody"})
        chk("ссылка на несуществующего клиента — отказ", st == 404, [st, d])
        async with http.post(base + "/api/client/share", json={"name": "alice"},
                             headers={"Authorization": "tma " + init_data(111), "Host": "evil.example/x"}) as r:
            chk("подставной Host в адрес ссылки не попадает", r.status == 400, r.status)
        shmod._fails.clear()
        codes = []
        for i in range(shmod.FAIL_MAX + 1):
            async with http.get(base + "/s/" + f"{i:032d}") as r:
                codes.append(r.status)
        shmod._fails.clear()
        chk("перебор ссылок с одного адреса — 429", codes[:shmod.FAIL_MAX] == [404] * shmod.FAIL_MAX and codes[-1] == 429,
            codes[-3:])

        text, buttons = screen(await press("cl:shr:alice"))
        m2 = re.search(r"<code>(https://[^<]+)/s/([A-Za-z0-9_-]{32})</code>", text)
        chk("бот: «🔗 Ссылка 5 мин» — адрес Mini App, срок и «Отозвать»",
            m2 is not None and m2.group(1) + "/" == webapp.SERVER.url and "Действует 5 минут" in text
            and any(d.startswith("cl:shx:alice|") for _, d in buttons), [text, buttons])
        rid = next((d for _, d in buttons if d.startswith("cl:shx:")), "|").split("|")[1]
        sent = await press(f"cl:shx:alice|{rid}")
        async with http.get(base + f"/s/{m2.group(2) if m2 else 'x'}") as r:
            chk("бот: «Отозвать» гасит ссылку", "Ссылка отозвана" in alerts(sent) and r.status == 404, [alerts(sent), r.status])


        st, body = await api_("/api/call", {"args": ["status"]})
        chk("панель: общий вызов awg2 api", st == 200 and body["ok"] and body["data"].get("version"), [st, str(body)[:200]])
        # Неверные типы в теле — отказ или игнор, а не 500 с трейсом
        st1, _ = await api_("/api/alerts", {"backup_mode": ["x"]})
        st2, _ = await api_("/api/alerts", {"kind": ["x"], "on": True})
        st3, _ = await api_("/api/settings", {"sort": ["x"]})
        st4, _ = await api_("/api/job/status", {"id": "20250101-000000-abcd", "offset": "²"})
        chk("панель: списки и «²» вместо строк/чисел — не 500", (st1, st2, st3, st4) == (400, 200, 200, 200), [st1, st2, st3, st4])
        st, body = await api_("/api/call", {"args": ["job", "list"]})
        chk("панель: команды вне белого списка — 403", st == 403, [st, body])
        st, body = await api_("/api/call", {"args": "status"})
        chk("панель: кривые аргументы — 400", st == 400, [st, body])
        # Антисканер из панели: адрес соединения — в awg2 (AWG_CLIENT_IP), чтобы тот,
        # кто включает, не отрезал себя; подставной X-Forwarded-For не в счёт
        seen_env, real_call_e = [], botapi.call

        async def env_call(*args, **kw):
            seen_env.append((args, kw.get("env")))
            return botapi.Result(True)
        botapi.call = env_call
        try:
            for args in (["antiscan", "on"], ["antiscan", "allow", "del", "127.0.0.1"], ["status"]):
                async with http.post(base + "/api/call", json={"args": args},
                                     headers={"Authorization": "tma " + init_data(111), "X-Forwarded-For": "77.0.6.6"}) as r:
                    await r.read()
        finally:
            botapi.call = real_call_e
        chk("панель: включение антисканера получает адрес клиента панели (не X-Forwarded-For); "
            "удаление исключения и другие команды — нет (свой адрес иначе вернулся бы в исключения)",
            seen_env == [(("antiscan", "on"), {"AWG_CLIENT_IP": "127.0.0.1"}),
                         (("antiscan", "allow", "del", "127.0.0.1"), None), (("status",), None)], seen_env)
        admins.add(333, 111)
        st, body = await api_("/api/call", {"args": ["uninstall"]}, uid=333)
        chk("приглашённому админу владельческое закрыто", st == 403 and "владелец" in body.get("error", ""), [st, body])
        st, body = await api_("/api/call", {"args": ["cert", "remove"]}, uid=333)
        chk("…и сертификат тоже", st == 403, [st, body])
        st, body = await api_("/api/call", {"args": ["uninstall"]}, uid=333, extra={"owner": True, "web": True})
        chk("«owner» в данных Telegram не делает владельцем (метка только веб-панели)", st == 403, [st, body])
        st, body = await api_("/api/call", {"args": ["backup", "create", "auto", "1"]}, uid=333)
        chk("…и ротация автобэкапов («auto 1» стёрла бы все, кроме одного)", st == 403, [st, body])
        st, body = await api_("/api/call", {"args": ["log", "web", "500"]}, uid=333)
        st2, _ = await api_("/api/call", {"args": ["log", "manager", "5"]}, uid=333)
        chk("…и журнал входов веб-панели; прочие журналы — можно", (st, st2) == (403, 200), [st, st2, body])
        st, body = await api_("/api/bot/info", {}, uid=333)
        chk("панель: приглашённому — сводка бота без списка админов",
            st == 200 and body.get("owner") is False and "admins" not in body and body.get("invited") == 1, [st, body])
        st1, _ = await api_("/api/bot/invite", {}, uid=333)
        st2, _ = await api_("/api/bot/icons", {"action": "off"}, uid=333)
        st3, _ = await api_("/api/bot/webapp/restart", {}, uid=333)
        chk("панель: приглашения, иконки и сервер панели — только владельцу", (st1, st2, st3) == (403, 403, 403),
            (st1, st2, st3))
        st, body = await api_("/api/bot/info", {})
        chk("панель: владельцу — список админов с приглашённым",
            st == 200 and body["owner"] and [a["uid"] for a in body["admins"]["invited"]] == [333], [st, body])
        st, body = await api_("/api/bot/invite", {})
        chk("панель: приглашение — ссылка на бота с одноразовым токеном",
            st == 200 and f"?start={admins.INVITE_PREFIX}" in body.get("link", "") and admins.pending_invites() == 1,
            [st, body])
        st, body = await api_("/api/bot/invites/revoke", {})
        chk("панель: приглашения гасятся", st == 200 and body.get("revoked") == 1 and admins.pending_invites() == 0, body)
        st, body = await api_("/api/bot/admin/del", {"uid": 333})
        chk("панель: владелец отзывает доступ", st == 200 and 333 not in admins.invited_ids(), [st, body])
        st, body = await api_("/api/me", {})
        chk("панель: /api/me — время старта бота (панель по нему ждёт перезапуск)",
            isinstance(body.get("started"), int) and body["started"] > 0, body)
        mark = len(SESSION.sent)
        st, body = await api_("/api/bot/menu", {})
        menu = [m for n, m in SESSION.sent[mark:] if n == "SendMessage" and getattr(m, "chat_id", None) == 111]
        chk("панель: «Меню бота в чат» — главное меню новым сообщением",
            st == 200 and menu and "srv" in [b.callback_data for row in menu[-1].reply_markup.inline_keyboard for b in row],
            [st, [n for n, _ in SESSION.sent[mark:]]])
        st, body = await api_("/api/wgobf/bundle", {"name": "nobody"})
        chk("панель: комплект обфускатора без обфускатора — понятная ошибка",
            st == 200 and body["ok"] is False and body.get("error"), [st, body])

        st, body = await api_("/api/clients", {})
        alice = next((c for c in body.get("rows") or [] if c["name"] == "alice"), {})
        chk("панель: клиенты с заметками, мониторингом и маршрутом",
            st == 200 and {"note", "mon", "route"} <= set(alice) and body.get("sort"), [st, alice])
        await api_("/api/client/note", {"name": "alice", "text": "ноутбук"})
        await api_("/api/client/mon", {"name": "alice", "on": True})
        chk("панель: заметка и мониторинг — в хранилище бота",
            store.note("alice") == "ноутбук #ping" and store.monitored("alice"), store.note("alice"))
        await api_("/api/client/mon", {"name": "alice", "on": False})
        st, body = await api_("/api/client/qr", {"name": "alice"})
        chk("панель: QR картинкой и текст конфига",
            st == 200 and len(body.get("png") or "") > 100 and "[Interface]" in body.get("text", ""), [st, str(body)[:120]])
        st, body = await api_("/api/client/add", {"name": "panel1", "expire": "+1d"})
        chk("панель: новый клиент", st == 200 and body["ok"], [st, body])
        st, body = await api_("/api/client/rename", {"old": "panel1", "new": "panel2"})
        chk("панель: переименование", st == 200 and body["ok"] and os.path.exists(os.path.join(ROOT, "root", "panel2_awg2.conf")),
            [st, body])
        st, body = await api_("/api/client/add", {"name": "bad name"})
        chk("панель: имя проверяется до awg2", st == 400, [st, body])
        mark = len(SESSION.sent)
        st, body = await api_("/api/send", {"what": "conf", "name": "panel2"})
        chk("панель: «отправить в чат» — файл и QR владельцу",
            st == 200 and [n for n, m in SESSION.sent[mark:] if getattr(m, "chat_id", None) == 111]
            == ["SendDocument", "SendPhoto"], [n for n, _ in SESSION.sent[mark:]])
        st, body = await api_("/api/send", {"what": "conf_zip", "name": "panel2"})
        chk("панель: ZIP с конфигом — только скачиванием в веб-панели, не в чат", st == 400, [st, body])
        st, body = await api_("/api/job", {"args": ["clients", "bulk", "pj:2", "mimicry=none"]})
        jid = (body.get("data") or {}).get("id")
        for _ in range(100):
            st, body = await api_("/api/job/status", {"id": jid, "offset": 0})
            if (body.get("data") or {}).get("state") != "running":
                break
            await asyncio.sleep(0.3)
        chk("панель: задача с журналом — массовое создание",
            body["data"].get("ok") and body["data"].get("data") == ["pj-001", "pj-002"] and "pj-001" in body["data"].get("log", ""),
            body.get("data"))
        st, body = await api_("/api/client/del", {"names": ["panel2", "pj-001", "pj-002"]})
        chk("панель: удаление нескольких", st == 200 and body["ok"]
            and not os.path.exists(os.path.join(ROOT, "root", "pj-001_awg2.conf")), [st, body])

        # Бэкап: в чат — только из списка на сервере; архив с телефона — телом запроса
        st, body = await api_("/api/call", {"args": ["backup", "create"], "timeout": 300})
        bk_path = (body.get("data") or {}).get("path") or ""
        st, body = await api_("/api/send", {"what": "backup", "path": "/etc/passwd"})
        chk("панель: в чат уходит только бэкап из списка, не любой файл", st == 400, [st, body])
        mark = len(SESSION.sent)
        st, body = await api_("/api/send", {"what": "backup", "path": bk_path})
        chk("панель: бэкап — файлом в чат владельцу",
            st == 200 and [n for n, m in SESSION.sent[mark:] if getattr(m, "chat_id", None) == 111] == ["SendDocument"],
            [st, body, [n for n, _ in SESSION.sent[mark:]]])
        with open(bk_path, "rb") as f:
            archive = f.read()

        async def upload(data, uid=111):
            async with http.post(base + "/api/backup/upload", data=data,
                                 headers={"Authorization": "tma " + init_data(uid),
                                          "Content-Type": "application/octet-stream"}) as r:
                return r.status, await r.json(content_type=None)

        st, body = await upload(archive, uid=222)
        chk("панель: загрузка бэкапа чужим — 403", st == 403, [st, body])
        st, body = await upload(archive)
        up = body.get("path") or ""
        chk("панель: архив с телефона сохранён у бота, только для root",
            st == 200 and os.path.isfile(up) and oct(os.stat(up).st_mode & 0o777) == "0o600", [st, body])
        st, body = await api_("/api/call", {"args": ["backup", "inspect", up]})
        chk("панель: загруженный архив читается как бэкап", st == 200 and body["ok"] and body["data"]["clients"] >= 1,
            [st, str(body)[:200]])
        st, body = await upload(b"x" * (20 * 1024 * 1024 + 1))
        chk("панель: больше 20 МБ — отказ", st == 400 and "20 МБ" in body.get("error", ""), [st, body])

    text, _ = screen(await press(f"app:pset:{ports[1]}"))
    chk("смена порта перезапускает сервер", webapp.SERVER.running and webapp.SERVER.url.endswith(f":{ports[1]}/")
        and f"Порт Mini App: {ports[1]}" in text, [text[:200], webapp.SERVER.url])

    # Два перезапуска сервера разом (двойной тап «Перезапустить», порт + сертификат): оба
    # сносили сервер и поднимали свой — второй не мог занять порт, а первый слушал
    # без хозяина, и stop() его уже не закрывал
    res = await asyncio.gather(webapp.SERVER.start(BOT), webapp.SERVER.start(BOT), return_exceptions=True)
    chk("два перезапуска Mini App разом: оба прошли, сервер работает",
        all(r is None for r in res) and webapp.SERVER.running and not webapp.SERVER.error, [res, webapp.SERVER.error])
    port = int(webapp.SERVER.url.rsplit(":", 1)[1].strip("/"))
    await webapp.SERVER.stop()
    with socket.socket() as s:
        s.settimeout(2)
        listening = s.connect_ex(("127.0.0.1", port)) == 0
    chk("после stop() порт Mini App закрыт (нет бесхозного слушателя)", not listening)
    await webapp.SERVER.start(BOT)

    WEBAPP_REJECT[0] = True
    text, buttons = screen(await press("app"))
    chk("Telegram не принял адрес — понятно, что нужен домен, экран на месте",
        "Telegram не принял адрес" in text and "Нужен домен" in text and ("🌍 На домен…", "app:dom") in buttons
        and not any((d or "").startswith("webapp:") for _, d in buttons), [text[-300:], buttons])
    WEBAPP_REJECT[0] = False

    mark = len(SESSION.sent)
    await press("app:rmok")
    chk("удаление сертификата останавливает Mini App и возвращает обычное «Меню»",
        not webapp.SERVER.running and not os.path.exists(os.path.join(ROOT, "etc/awg2/cert/fullchain.pem"))
        and any(n == "SetChatMenuButton" and m.chat_id == 111 and m.menu_button.type == "default"
                for n, m in SESSION.sent[mark:]), menus()[-2:])

    print("Цвета кнопок")
    await say("/start")
    styles = {b.text: b.style for row in keyboard(SESSION.sent) for b in row}
    chk("главное меню: зелёная только «Поддержать», остальные — обычные",
        styles.get("Поддержать 💚") == "success" and all(v is None for k, v in styles.items() if k != "Поддержать 💚")
        and "🗑 Удаление" in styles and "⬆️ Обновление" in styles, styles)
    await press("cl")
    styles = {b.text: b.style for row in keyboard(SESSION.sent) for b in row}
    chk("клиенты: добавить и удалить — обычные", styles.get("➕ Добавить", "x") is None
        and styles.get("🗑 Удалить…", "x") is None and not any(styles.values()), styles)
    await press("cl:del:alice")
    styles = {b.text: b.style for row in keyboard(SESSION.sent) for b in row}
    chk("подтверждение удаления: обе кнопки обычные, в одной строке",
        styles == {"🗑 Да, удалить": None, "✖️ Отмена": None}
        and [len(r) for r in keyboard(SESSION.sent)] == [2], styles)

    print("Иконки")
    icons_mod = sys.modules["awgbot.icons"]
    text, buttons = screen(await press("look"))
    chk("экран оформления: иконки выключены, условие Premium названо",
        "выключены" in text and "Telegram Premium" in text and ("📥 Набор иконок", "look:pack") in buttons, text)
    text, buttons = screen(await press("look:pack"))
    chk("набор TgAndroidIcons — готовой кнопкой", ("📱 TgAndroidIcons", "look:pk:TgAndroidIcons") in buttons, buttons)
    text, _ = screen(await say("t.me/addemoji/SomeIcons"))
    chk("нет Premium — Telegram срезал иконки: выключены, набор сохранён",
        "не показал иконки" in text and not icons_mod.active() and icons_mod.mapping().get("🖥") == "111", text)
    chk("похожие эмодзи: 💾 — иконкой 💿; цветные значки набора не берутся",
        icons_mod.mapping().get("💾") == "666" and "🟢" not in icons_mod.mapping(), icons_mod.mapping())
    await say("/start")
    text, buttons = screen(SESSION.sent[-3:])
    rows = keyboard(SESSION.sent)
    chk("после отказа — обычные эмодзи", "<tg-emoji" not in text and rows[0][0].text == "🖥 Сервер"
        and rows[0][0].icon_custom_emoji_id is None, [text[:80], rows[0][0]])

    PREMIUM["mode"] = "ok"
    text, _ = screen(await press("look:pk:TgAndroidIcons"))
    chk("с Premium — проверка прошла, иконки включены, показано что подобралось",
        "Иконки включены: 5 из" in text and "Обычные эмодзи:" in text and icons_mod.active()
        and icons_mod.pack() == "TgAndroidIcons", text)
    sent = await say("/start")
    text, _ = screen(sent)
    rows = keyboard(sent)
    chk("иконки в тексте: эмодзи хоста — custom emoji, цветные точки — как есть",
        '<tg-emoji emoji-id="111">🖥</tg-emoji>' in text and "<tg-emoji emoji-id" in text
        and "🟢" in text and 'emoji-id="111">🟢' not in text, text[:300])
    chk("иконка на кнопке вместо эмодзи в подписи",
        rows[0][0].text == "Сервер" and rows[0][0].icon_custom_emoji_id == "111"
        and rows[0][1].text == "Клиенты" and rows[0][1].icon_custom_emoji_id == "222"
        and rows[1][0].text == "🩺 Диагностика", [rows[0], rows[1][0]])

    PREMIUM["mode"] = "reject"
    sent = await press("main")
    text, _ = screen(sent)
    chk("Telegram отклонил иконки — экран всё равно показан, с обычными эмодзи, иконки выключены",
        "AWG Toolza" in text and "<tg-emoji" not in text and not icons_mod.active()
        and keyboard(sent)[0][0].text == "🖥 Сервер", [n for n, _ in sent])

    PREMIUM["mode"] = "ok"
    await press("look:own")
    own = "🖥 🌐 👥"
    ents = [MessageEntity(type="custom_emoji", offset=0, length=2, custom_emoji_id="901"),
            MessageEntity(type="custom_emoji", offset=6, length=2, custom_emoji_id="903")]
    text, _ = screen(await say(own, entities=ents))
    m = icons_mod.mapping()
    chk("свои иконки дополняют набор; обычное эмодзи на месте — оставить",
        "Иконки включены" in text and m.get("🖥") == "901" and m.get("🩺") == "903" and m.get("👥") == "222"
        and icons_mod.pack() == "TgAndroidIcons + свои", [icons_mod.pack(), m])
    admin = User(id=333, is_bot=False, first_name="Admin")
    admins.add(333, 111)
    denied = [alerts(await press(d, admin)) for d in ("look", "look:pk:TgAndroidIcons", "look:own", "look:off",
                                                       "adm:invite", "app:rm")]
    chk("приглашённому админу оформление, админы и Mini App закрыты — каждая кнопка",
        all(len(a) == 1 and "только владелец" in a[0] for a in denied)
        and icons_mod.active() and icons_mod.pack() == "TgAndroidIcons + свои" and admins.pending_invites() == 0, denied)
    admins.remove(333, removed_by=111)

    await press("look:off")
    chk("выключение иконок", not icons_mod.active() and icons_mod.mapping(), icons_mod.mapping())
    PREMIUM["mode"] = "strip"

    print("Веб-панель")
    text, buttons = screen(await press("web"))
    chk("веб-панель не установлена — «Установить», логин admin и пароль от бота",
        "Не установлена" in text and ("📦 Установить", "web:inst") in buttons, [text, buttons])
    admin = User(id=333, is_bot=False, first_name="Admin")
    admins.add(333, 111)
    denied = [alerts(await press(d, admin)) for d in ("web", "web:pwok", "web:inst", "web:rmok")]
    chk("приглашённому админу веб-панель закрыта — каждая кнопка",
        all(len(a) == 1 and "только владелец" in a[0] for a in denied), denied)
    _, buttons = screen(await press("diag:logs", admin))
    log_web = alerts(await press("diag:log:web", admin))
    chk("журнал входов веб-панели (адреса, введённые логины) — тоже только владельцу",
        "diag:log:web" not in [d for _, d in buttons] and "diag:log:manager" in [d for _, d in buttons]
        and len(log_web) == 1 and "только владельцу" in log_web[0], [buttons, log_web])
    admins.remove(333, removed_by=111)
    real_call_ = botapi.call
    WEBST = {"installed": False}
    URL = "https://203.0.113.10:41234/AbCdEfGh123456/"
    PW = "Qw3rTy7uI9oPaS2dF4"
    web_calls = []

    async def web_call(*args, **kw):
        if args[:1] != ("web",):
            return await real_call_(*args, **kw)
        web_calls.append(args[1])
        if args[1] == "status":
            return botapi.Result(True, data=dict(WEBST))
        if args[1] in ("install", "password"):
            WEBST.update(installed=True, active=True, url=URL, user="admin")
            return botapi.Result(True, data={"url": URL, "user": "admin", "password": PW})
        if args[1] == "stop":
            WEBST["active"] = False
        if args[1] == "access":
            web_calls.append(args[2:])
            if "300.1.1.1" in args:
                return botapi.Result(False, rc=1, error="Не адрес или слишком широкая подсеть: 300.1.1.1")
            WEBST["access"] = args[2]
            if args[2] == "ip":
                WEBST["allow"] = list(args[3:])
        return botapi.Result(True)
    botapi.call = web_call
    text, buttons = screen(await press("web:inst"))
    chk("установка из бота: адрес, логин и пароль под спойлером — один раз",
        URL in text and f"<tg-spoiler><code>{PW}</code></tg-spoiler>" in text and buttons == [("✅ Сохранил", "web")],
        [text, buttons])
    pw_msg = SESSION.screen_id()
    text, buttons = screen(await press("web"))
    chk("«Сохранил» — тот же экран без пароля: адрес, логин, кнопка «Открыть»",
        SESSION.screen_id() == pw_msg and PW not in SESSION.text.get(pw_msg, "") and URL in text
        and ("🌐 Открыть", URL) in buttons and ("🔑 Новый пароль", "web:pw") in buttons
        and ("📜 Журнал входов", "diag:log:web|web") in buttons, [text, buttons])
    text, buttons = screen(await press("web:pw"))
    chk("новый пароль — с подтверждением", "Прежний перестанет подходить" in text
        and ("🔑 Новый пароль", "web:pwok") in buttons and web_calls[-1] == "status", [text, buttons])
    text, _ = screen(await press("web:pwok"))
    chk("новый пароль выдан", PW in text and web_calls[-1] == "password", [text, web_calls])
    text, buttons = screen(await press("web:stop"))
    chk("остановка: статус и кнопка «Запустить», ссылки «Открыть» нет",
        "Остановлена" in text and ("▶️ Запустить", "web:start") in buttons
        and not any(d == URL for _, d in buttons), [text, buttons])

    WEBST.update(access="all", allow=[], vpn_url="https://10.8.0.1:41234/AbCdEfGh123456/", vpn_nets=["10.8.0.0/24"])
    text, buttons = screen(await press("web"))
    chk("веб-панель: строка «Доступ: для всех» и кнопка «🛡 Доступ»",
        "🛡 Доступ: для всех" in text and ("🛡 Доступ", "web:acc") in buttons, [text, buttons])
    text, buttons = screen(await press("web:acc"))
    chk("экран доступа: три режима, текущий отмечен, адрес изнутри VPN",
        "Сейчас: <b>для всех</b>" in text and "https://10.8.0.1:41234/AbCdEfGh123456/" in text
        and ("✅ 🌍 Для всех", "web:acc_all") in buttons and ("📍 По адресам", "web:acc_ip") in buttons
        and ("🔒 Только через VPN", "web:acc_vpn") in buttons, [text, buttons])
    text, buttons = screen(await press("web:acc_ip"))
    chk("вопрос про адреса: не обещает IPv6 — панель слушает IPv4", "IPv6 тоже" not in text and "IPv4" in text, text)
    text, buttons = screen(await say("300.1.1.1, 198.51.100.7"))
    chk("неверный адрес — ошибка awg2 и тот же вопрос снова", "300.1.1.1" in text and "⚠️" in text
        and ("✖️ Отмена", "web:acc") in buttons and WEBST["access"] == "all", [text, buttons])
    text, buttons = screen(await say("198.51.100.7, 203.0.113.0/24;2001:db8::/32"))
    chk("«По адресам»: список уходит в awg2 по одному, режим отмечен",
        web_calls[-2] == ("ip", "198.51.100.7", "203.0.113.0/24", "2001:db8::/32")
        and "✅ Доступ: по адресам и через VPN" in text and "<code>203.0.113.0/24</code>" in text
        and ("✅ 📍 По адресам", "web:acc_ip") in buttons, [web_calls[-3:], text, buttons])
    text, buttons = screen(await press("web:acc_vpn"))
    chk("«Только через VPN» — с подтверждением", "Снаружи порт панели закроется" in text
        and ("🔒 Закрыть снаружи", "web:acc_vpnok") in buttons and WEBST["access"] == "ip", [text, buttons])
    text, buttons = screen(await press("web:acc_vpnok"))
    chk("«Только через VPN» включён; прежние адреса — одной кнопкой",
        "Сейчас: <b>только через VPN</b>" in text and ("📍 Прежние адреса (3)", "web:acc_old") in buttons, [text, buttons])
    text, buttons = screen(await press("web:acc_old"))
    chk("прежние адреса — снова «по адресам» тем же списком",
        web_calls[-2] == ("ip", "198.51.100.7", "203.0.113.0/24", "2001:db8::/32") and WEBST["access"] == "ip", web_calls[-3:])
    text, buttons = screen(await press("web:acc_all"))
    chk("«Для всех» — одним нажатием (бот — путь назад, если адрес сменился)",
        web_calls[-2] == ("all",) and "Сейчас: <b>для всех</b>" in text, [web_calls[-3:], text])
    admin = User(id=333, is_bot=False, first_name="Admin")
    admins.add(333, 111)
    denied = [alerts(await press(d, admin)) for d in ("web:acc", "web:acc_all", "web:acc_vpnok", "web:acc_ip")]
    chk("приглашённому админу доступ к панели не менять", all(len(a) == 1 and "только владелец" in a[0] for a in denied), denied)
    admins.remove(333, removed_by=111)
    botapi.call = real_call_

    print("Антисканер")
    text, buttons = screen(await press("srv"))
    chk("в «Сервере» — кнопка «🛡 Антисканер»", ("🛡 Антисканер", "as") in buttons, buttons)
    ASST = {"enabled": True, "active": True, "v4": 3100, "v6": 29, "updated": 1791500000, "error": "",
            "dropped": 1234, "lists": [{"id": "scan", "name": "Сканеры", "on": True, "entries": 165},
                                       {"id": "skipa", "name": "СКИПА — сканеры РКН", "on": True, "entries": 145},
                                       {"id": "gov", "name": "Сети госорганов", "on": True, "entries": 2818}],
            "top": [{"packets": 30, "net": "77.0.3.0/24", "org": "Org <MVD>"}],
            "allow": ["77.0.7.7", "2a0c:a9c7:157::/48"], "ssh": ["77.0.7.7"]}
    as_calls = []

    async def as_call(*args, **kw):
        if args[:1] != ("antiscan",):
            return await real_call_(*args, **kw)
        as_calls.append((args[1:], kw.get("timeout")))
        if args[1] == "status":
            return botapi.Result(True, data=json.loads(json.dumps(ASST)))
        if args[1] == "on":
            ASST["enabled"] = True
        if args[1] == "off":
            ASST["enabled"] = False
        return botapi.Result(True)
    botapi.call = as_call
    text, buttons = screen(await press("as"))
    chk("экран: включён, подсетей и отбито, кто стучался (организация экранирована), списки и исключения",
        "🟢 Включён · подсетей 3 129" in text and "Отбито: 1 234" in text and "<code>77.0.3.0/24</code>" in text
        and "Org &lt;MVD&gt;" in text and "✅ Сети госорганов — 2 818" in text and "Исключения: 2" in text
        and "твой SSH не блокируется" in text, text)
    chk("счётчик «Отбито» — с установки правила (обновление списков его не сбрасывает), а не «с последнего применения»",
        "с установки правила" in text and "с последнего применения" not in text, text)
    chk("кнопки: выключить, обновить, списки переключателями, исключения, журнал, назад в «Сервер»",
        ("⏹ Выключить", "as:off") in buttons and ("🔄 Обновить списки", "as:upd") in buttons
        and ("✅ Сети госорганов", "as:l:gov") in buttons and ("📝 Исключения", "as:al") in buttons
        and ("📜 Журнал", "diag:log:antiscan|as") in buttons and ("◀️ Назад", "srv") in buttons, buttons)
    await press("as:l:gov")
    chk("снять список: остальные уходят в awg2, ждёт скачивания", (("lists", "scan,skipa"), 300) in as_calls,
        as_calls[-3:])
    ASST["lists"] = [dict(x, on=x["id"] == "gov") for x in ASST["lists"]]
    n = len(as_calls)
    sent = await press("as:l:gov")
    chk("последний список не снимается", "хотя бы один" in " ".join(alerts(sent))
        and not any(c[0][0] == "lists" for c in as_calls[n:]), [alerts(sent), as_calls[n:]])
    text, buttons = screen(await press("as:off"))
    chk("выключение — с подтверждением", ("⏹ Выключить", "as:offok") in buttons, buttons)
    text, buttons = screen(await press("as:offok"))
    chk("выключен: «Включить», без «Обновить списки»", "⚪️ Выключен" in text and ("✅ Включить", "as:on") in buttons
        and not any(d == "as:upd" for _, d in buttons), [text, buttons])
    n = len(as_calls)
    text, buttons = screen(await press("as:on"))
    chk("включение — с подтверждением и предупреждением (клиенты VPN и сам админ из сетей списков не войдут)",
        ("✅ Включить", "as:onok") in buttons and ("✖️ Отмена", "as") in buttons and "клиенты VPN" in text
        and "ты сам" in text and not any(c[0][0] == "on" for c in as_calls[n:]), [text, buttons, as_calls[n:]])
    text, _ = screen(await press("as:onok"))
    chk("включение: долгий вызов (списки качаются) и снова экран", as_calls[-2] == (("on",), 300)
        and "✅ Включён" in text, [as_calls[-3:], text])
    text, buttons = screen(await press("as:al"))
    chk("исключения: список и кнопки «убрать» — и для IPv6 с двоеточиями",
        "<code>2a0c:a9c7:157::/48</code>" in text and ("❌ 2a0c:a9c7:157::/48", "as:ad:2a0c:a9c7:157::/48") in buttons
        and ("➕ Добавить", "as:aa") in buttons, [text, buttons])
    await press("as:ad:2a0c:a9c7:157::/48")
    chk("убрать IPv6-исключение — адрес целиком", (("allow", "del", "2a0c:a9c7:157::/48"), None) in as_calls, as_calls[-3:])
    await press("as:aa")
    sent = await say("abc")
    chk("исключение: не адрес — переспрашивает", "⚠️" in screen(sent)[0] and not any(c[0][:2] == ("allow", "add")
                                                                                   for c in as_calls), screen(sent))
    await say("1.2.3.0/24")
    chk("исключение: подсеть уходит в awg2", (("allow", "add", "1.2.3.0/24"), None) in as_calls, as_calls[-3:])
    no_hourglass("антисканер")
    botapi.call = real_call_

    print("VK и Max мимо VPN")
    text, buttons = screen(await press("srv"))
    chk("в «Сервере» — кнопка «🚫 VK и Max»", ("🚫 VK и Max", "vk") in buttons, buttons)
    VKST = {"enabled": False, "active": False, "v4": 0, "v6": 0, "updated": 0, "error": "", "dropped": 0}
    vk_calls = []

    async def vk_call(*args, **kw):
        if args[:1] != ("vkblock",):
            return await real_call_(*args, **kw)
        vk_calls.append((args[1:], kw.get("timeout")))
        if args[1] == "status":
            return botapi.Result(True, data=json.loads(json.dumps(VKST)))
        if args[1] == "on":
            VKST.update(enabled=True, active=True, v4=204, v6=3, updated=1791500000, dropped=4321,
                        error="Список сетей VK: в ответе 3 записей <b>")
        if args[1] == "off":
            VKST.update(enabled=False, active=False)
        return botapi.Result(True)
    botapi.call = vk_call
    text, buttons = screen(await press("vk"))
    chk("выключено: что делает и чем грозит, «Включить», журнал, назад в «Сервер»",
        "⚪️ Выключено" in text and "Max" in text and "мимо туннеля" in text and ("✅ Включить", "vk:on") in buttons
        and ("📜 Журнал", "diag:log:vkblock|vk") in buttons and ("◀️ Назад", "srv") in buttons
        and not any(d == "vk:upd" for _, d in buttons), [text, buttons])
    n = len(vk_calls)
    text, buttons = screen(await press("vk:on"))
    chk("включение — с подтверждением и предупреждением про сервисы VK у клиентов",
        ("✅ Включить", "vk:onok") in buttons and ("✖️ Отмена", "vk") in buttons and "перестанут" in text
        and not any(c[0][0] == "on" for c in vk_calls[n:]), [text, buttons])
    text, buttons = screen(await press("vk:onok"))
    chk("включено: долгий вызов, подсети, счётчик, ошибка экранирована, «Обновить» и «Выключить»",
        (("on",), 180) in vk_calls and "🟢 Включено · подсетей 207" in text and "Отбито: 4 321 пакетов" in text
        and "&lt;b&gt;" in text and ("🔄 Обновить список", "vk:upd") in buttons and ("⏹ Выключить", "vk:off") in buttons,
        [vk_calls[-3:], text, buttons])
    await press("vk:upd")
    chk("обновить список — долгий вызов", (("update",), 180) in vk_calls, vk_calls[-3:])
    text, buttons = screen(await press("vk:off"))
    chk("выключение — с подтверждением", ("⏹ Выключить", "vk:offok") in buttons, buttons)
    text, buttons = screen(await press("vk:offok"))
    chk("выключено снова", (("off",), None) in vk_calls and "⚪️ Выключено" in text, [vk_calls[-3:], text])
    text, buttons = screen(await press("diag:log:vkblock|vk"))
    chk("журнал открывается, «Назад» — на экран VK", ("◀️ Назад", "vk") in buttons, [text, buttons])
    no_hourglass("VK и Max")
    botapi.call = real_call_

    print("WARP: кнопки из уведомлений")
    started, real_job_w = [], botapi.job_start

    async def warp_job(*args, **kw):
        started.append(args)
        return botapi.Result(False, error="тест: задачу не запускаем")
    botapi.job_start = warp_job
    await press("warp:restart")
    chk("«Перезапустить WARP» — задача awg2 warp restart", ("warp", "restart") in started, started)
    botapi.job_start = real_job_w
    health_calls = []

    async def warp_health_call(*args, **kw):
        if args[:2] == ("warp", "health"):
            health_calls.append(args)
            return botapi.Result(True)
        return await real_call_(*args, **kw)
    botapi.call = warp_health_call
    await press("warp:health:on")
    chk("«Включить health-check» — awg2 warp health on", ("warp", "health", "on") in health_calls, health_calls)
    botapi.call = real_call_

    print("Перенос из Amnezia")
    AMZ = {"container": "amnezia-awg2", "running": True, "migrated": False, "proto": "3.1", "port": 51888,
           "net": "10.8.1.0/24", "clients": [{"name": "Petr", "orig": "Пётр <b>", "ip": "10.8.1.1"},
                                             {"name": "cat", "orig": "cat", "ip": "10.8.1.2"}],
           "errors": [], "warnings": ["не переносится: PostUp"], "blockers": []}
    amz_calls, amz_jobs = [], []
    real_job_ = botapi.job_start

    async def amz_call(*args, **kw):
        if args[:1] != ("amnezia",):
            return await real_call_(*args, **kw)
        amz_calls.append(args[1:])
        if args[1] in ("status", "scan"):
            return botapi.Result(True, data=json.loads(json.dumps(AMZ)))
        return botapi.Result(True, log="Контейнер amnezia-awg2 удалён")

    async def amz_job(*args, **kw):
        amz_jobs.append(args)
        return botapi.Result(False, error="тест: задачу не запускаем")
    botapi.call = amz_call
    botapi.job_start = amz_job
    text, buttons = screen(await press("srv"))
    chk("в «Сервере» — кнопка переноса, когда найден контейнер", ("🐳 Перенос из Amnezia", "amz") in buttons, buttons)
    text, buttons = screen(await press("amz"))
    chk("экран переноса: протокол, порт, клиенты с исходными именами (экранированы), предупреждения",
        "AWG 3.1 · порт 51888/udp" in text and "Petr ← Пётр &lt;b&gt;" in text and "cat ←" not in text
        and "⚠️ не переносится: PostUp" in text and "Клиентов: 2" in text, text)
    chk("кнопки: перенести, обновить, назад", ("🚚 Перенести", "amz:go") in buttons and ("◀️ Назад", "srv") in buttons, buttons)
    text, buttons = screen(await press("amz:go"))
    chk("перенос — с вопросом: контейнер остановится, вернётся сам при ошибке", "остановлен (не удалён)" in text
        and "вернётся автоматически" in text and ("🚚 Перенести", "amz:gook") in buttons, text)
    await press("amz:gook")
    chk("перенос — задачей awg2 amnezia migrate", ("amnezia", "migrate") in amz_jobs, amz_jobs)
    AMZ["blockers"] = ["components"]
    text, buttons = screen(await press("amz"))
    chk("нет компонентов — причина и кнопка установки вместо «Перенести»", "Сначала установи компоненты" in text
        and ("📦 Компоненты", "srv:install") in buttons and not any(d == "amz:go" for _, d in buttons), buttons)
    AMZ.update(migrated=True)
    text, buttons = screen(await press("amz"))
    chk("после переноса: вернуть или удалить контейнер", "Перенос сделан" in text and ("↩️ Вернуть Amnezia", "amz:rev") in buttons
        and ("🗑 Удалить контейнер", "amz:rm") in buttons, buttons)
    await press("amz:revok")
    chk("возврат — задачей amnezia revert", ("amnezia", "revert") in amz_jobs, amz_jobs)
    text, _ = screen(await press("amz:rmok"))
    chk("удаление контейнера — awg2 amnezia remove", ("remove",) in amz_calls and "удалён" in text, [amz_calls[-2:], text])
    AMZ.clear()
    AMZ.update(container="", migrated=False)
    text, buttons = screen(await press("srv"))
    chk("контейнера нет — кнопки переноса нет", not any(d == "amz" for _, d in buttons), buttons)
    botapi.job_start = real_job_

    async def imp_call(*args, **kw):
        r = await real_call_(*args, **kw)
        if args[:2] == ("clients", "list") and r.ok and isinstance(r.data, list):
            for c in r.data:
                if c.get("name") == "alice":
                    c["amnezia"] = "Алиса"
        if args[:2] == ("client", "reissue"):
            amz_calls.append(args)
            return botapi.Result(False, error="тест: перевыпуск")
        return r
    botapi.call = imp_call
    text, buttons = screen(await press("cl:v:alice"))
    chk("карточка перенесённого: пометка и исходное имя, «Перевыпустить» вместо конфига, ссылки и мимикрии",
        "Перенесён из Amnezia («Алиса»)" in text and ("🔁 Перевыпустить конфиг", "cl:rei:alice") in buttons
        and not any(d in ("cl:conf:alice", "cl:shr:alice", "cl:mim:alice") for _, d in buttons), [text, buttons])
    text, buttons = screen(await press("cl:rei:alice"))
    chk("перевыпуск — с вопросом: прежний конфиг перестанет подключаться", "перестанет" in text
        and ("🔁 Перевыпустить", "cl:reiok:alice") in buttons, text)
    text, _ = screen(await press("cl:reiok:alice"))
    chk("перевыпуск — awg2 client reissue, ошибка — экраном", ("client", "reissue", "alice") in amz_calls
        and "тест: перевыпуск" in text, text)
    text, _ = screen(await press("cl:shr:alice"))
    chk("ссылку на 5 минут перенесённому не создать — карточка", "Перенесён из Amnezia" in text, text)
    no_hourglass("перенос из Amnezia")
    botapi.call = real_call_

    print("Ширина экрана")
    short = ui.fit("<b>🛡 alice</b>", ui.kb(("📦 Комплект", "a"), ("🗑 Удалить", "b")))
    chk("короткий текст дополняется до ширины кнопок", short.startswith("<b>🛡 alice</b>")
        and ui.width(short.replace("<b>", "").replace("</b>", "")) >= 2 * (ui.width("📦 Комплект") + 4), short)
    long_text = "<b>Заголовок</b>\n" + "очень длинная строка текста экрана"
    chk("длинный текст не трогается", ui.fit(long_text, ui.kb(("📦 Комплект", "a"))) == long_text)

    print("Порт AWG и обфускатора")
    chk("ui.awg_port_ok: 443 и 1024-65535 — да; 80, 1023, 65536, мусор — нет",
        all(ui.awg_port_ok(v) for v in ("443", "1024", "51820", "65535"))
        and not any(ui.awg_port_ok(v) for v in ("80", "53", "1023", "0", "65536", "", "44x", "١٠٢٤", "000443000")))


asyncio.run(run())
asyncio.run(BOT.session.close())
summary()
