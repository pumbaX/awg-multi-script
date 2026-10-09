"""ask.py — ввод текста и файлов: имя клиента, ссылка Xray, конфиг ноды...

Кнопка просит ввод (ask), следующее сообщение пользователя уходит в
обработчик по ключу. Отмена — любая кнопка: ui.Actions сбрасывает ожидание.
Обработчик может спросить снова (retry — при ошибке ввода) или задать
следующий вопрос (ask — многошаговые мастера).
"""

from __future__ import annotations

import io
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message

from . import ui

router = Router()

FILE_MAX = 20 * 1024 * 1024     # предел скачивания файлов у Bot API


class Ask(StatesGroup):
    waiting = State()


@dataclass
class Ctx:
    key: str
    back: str
    prompt: str
    data: dict[str, Any] = field(default_factory=dict)
    buttons: list[list[str]] = field(default_factory=list)

    def __getitem__(self, k: str) -> Any:
        return self.data[k]

    def get(self, k: str, default: Any = None) -> Any:
        return self.data.get(k, default)


Answer = Callable[[Message, FSMContext, Ctx], Awaitable[None]]
_answers: dict[str, Answer] = {}


def on(key: str) -> Callable[[Answer], Answer]:
    def deco(fn: Answer) -> Answer:
        _answers[key] = fn
        return fn
    return deco


async def ask(target: ui.Target, state: FSMContext, key: str, prompt: str, back_to: str,
              buttons: list[ui.Button] | None = None, _base: str = "", **data: Any) -> None:
    """Попросить ввод. buttons — готовые ответы кнопками над «Отмена».
    _base — вопрос без предупреждения (повтор после ошибки): копятся не «⚠️», а одно."""
    await state.set_state(Ask.waiting)
    await state.update_data(ask=key, back=back_to, prompt=_base or prompt, ctx=data,
                            buttons=[list(b) for b in buttons or []])
    await ui.render(target, prompt, ui.kb(buttons, ui.back(back_to, "✖️ Отмена")))


async def retry(msg: Message, state: FSMContext, ctx: Ctx, why: str) -> None:
    """Неверный ввод: объяснить и спросить то же самое ещё раз."""
    await ask(msg, state, ctx.key, f"⚠️ {ui.esc(why)}\n\n{ctx.prompt}", ctx.back,
              [tuple(b) for b in ctx.buttons], _base=ctx.prompt, **ctx.data)


def text_of(msg: Message) -> str:
    return (msg.text or msg.caption or "").strip()


async def file_of(msg: Message) -> bytes | None:
    """Содержимое присланного документа или None (нет файла, слишком велик)."""
    doc = msg.document
    if doc is None or (doc.file_size or 0) > FILE_MAX or msg.bot is None:
        return None
    buf = io.BytesIO()
    await msg.bot.download(doc, destination=buf)
    return buf.getvalue()


@router.message(Ask.waiting)
async def _answer(msg: Message, state: FSMContext) -> None:
    data = await state.get_data()
    await state.set_state(None)
    fn = _answers.get(str(data.get("ask")))
    if fn is not None:
        await fn(msg, state, Ctx(str(data.get("ask")), str(data.get("back") or "main"),
                                 str(data.get("prompt") or ""), dict(data.get("ctx") or {}),
                                 list(data.get("buttons") or [])))
