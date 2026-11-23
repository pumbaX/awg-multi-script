"""Подписка Xray: адрес подписки провайдера (3x-ui, Marzban, Remnawave…) —
её серверы становятся выходами Xray и обновляются сами. Пункт «Туннели →
Xray → Подписка» awg2.

Адрес — секрет (в нём ключ доступа): сообщение с ним бот сразу удаляет, в
awg2 он уходит через stdin, на экранах — только сайт. Скачивает, проверяет и
применяет awg2; здесь — экран.
"""

from __future__ import annotations

import contextlib
import time

from aiogram import Router
from aiogram.exceptions import TelegramAPIError
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import api, ask, jobs, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "xs")
TITLE = "Подписка Xray"
PROMPT = ("Пришли адрес подписки: <code>https://…</code> — ссылку «для приложения» из панели провайдера "
          "(3x-ui, Marzban, Remnawave…). Сообщение с адресом я сразу удалю: в нём ключ доступа.")


def _gb(n: int) -> str:
    return ui.fmt_bytes(int(n or 0))


def lines_of(d: dict) -> list[str]:
    """Состояние подписки строками: сайт, серверы, обновление, трафик и срок, ошибка."""
    if not d.get("set"):
        return ["⚪️ Подписка не задана"]
    out = [f"🟢 <b>{esc(d.get('site', ''))}</b>" + (f" · {esc(d['title'])}" if d.get("title") else "")
           + f" · серверов {int(d.get('count') or 0)}"
           + (f" (пропущено {int(d['skipped'])})" if d.get("skipped") else "")]
    if d.get("insecure"):
        out.append("⚠️ По http — подписку могут подменить по дороге")
    if d.get("updated"):
        out.append(f"🕒 Обновлена {ui.fmt_time(d['updated'])} · сама — раз в {int(d.get('every') or 6)} ч")
    now = time.time()
    if d.get("total"):
        used = int(d.get("up") or 0) + int(d.get("down") or 0)
        warn = " ⚠️" if used >= 0.9 * int(d["total"]) else ""
        out.append(f"📊 Трафик: {_gb(used)} из {_gb(d['total'])}{warn}")
    if d.get("expire"):
        left = int(d["expire"]) - now
        mark = " — истекла" if left <= 0 else " ⚠️" if left < 3 * 86400 else ""
        out.append(f"📅 Действует до {time.strftime('%d.%m.%Y', time.localtime(int(d['expire'])))}{mark}")
    if d.get("error"):
        out.append(f"▲ {esc(d['error'])}")
    return out


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await state.update_data(xs_pending="")          # http-адрес, не подтверждённый, — забыть
    await screen(cb)


async def screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("xray", "sub", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, TITLE), ui.kb(ui.back("xr")))
        return
    d = r.data
    on = bool(d.get("set"))
    text = [f"<b>📡 {TITLE}</b>",
            "Серверы из подписки провайдера становятся выходами Xray и обновляются сами. Свои выходы "
            "(ссылкой) не трогаются; клиенту можно закрепить сервер подписки, как обычный выход.", ""]
    if note:
        text += [note, ""]
    text += lines_of(d)
    if on and int(d.get("count") or 0) > 1:
        text.append("\n<i>Серверов несколько — ⚖️ Балансировщик (leastPing) выберет самый быстрый.</i>")
    await ui.render(target, "\n".join(text), ui.kb(
        ("🔄 Обновить сейчас", act.data("upd")) if on else None,
        ("✏️ Сменить адрес" if on else "➕ Задать адрес", act.data("set")),
        ("⚖️ Балансировщик", "xr:bal") if on and int(d.get("count") or 0) > 1 else None,
        ("🗑 Убрать", act.data("off")) if on else None,
        ui.back("xr")))


@act("set")
async def _set(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "xs_url", PROMPT, act.data())


@ask.on("xs_url")
async def _url(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    url = "".join((msg.text or "").split())
    with contextlib.suppress(TelegramAPIError):
        await msg.delete()
    low = url.lower()
    if not low.startswith(("https://", "http://")) or len(url) > 2048 or any(c in url for c in "\"\\"):
        await ask.retry(msg, state, ctx, "Нужен адрес подписки: https://…")
        return
    if low.startswith("http://"):
        # Адрес — только в памяти бота до ответа
        await state.update_data(xs_pending=url)
        await ui.confirm(msg, "⚠️ Адрес по <b>http</b>: подписку могут подменить по дороге и подсунуть свои "
                              "серверы. Лучше адрес https. Всё равно использовать?",
                         ("⚠️ Использовать http", act.data("http")), act.data())
        return
    await jobs.start(msg, TITLE, "xray", "sub", "set", stdin=url + "\n", back_to="xs")


@act("http")
async def _http(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    url = str((await state.get_data()).get("xs_pending") or "")
    await state.update_data(xs_pending="")
    if not url:
        await screen(cb)
        return
    await jobs.start(cb, TITLE, "xray", "sub", "set", "insecure", stdin=url + "\n", back_to="xs")


@act("upd")
async def _upd(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Обновление подписки", "xray", "sub", "update", back_to="xs")


@act("off")
async def _off(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Убрать подписку? Её серверы уйдут из выходов Xray, клиенты, закреплённые за ними, — на "
                         "выход по умолчанию. Свои выходы останутся.", ("🗑 Убрать", act.data("offok")), act.data())


@act("offok")
async def _off_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Подписка убирается", "xray", "sub", "off", back_to="xs")
