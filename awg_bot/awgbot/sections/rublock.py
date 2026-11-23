"""РФ мимо VPN: трафик клиентов VPN в сети России сервер не пускает — сразу
отказ. Российские сайты и приложения не видят адрес зарубежного сервера.
Пункт «Сервер → РФ мимо VPN» awg2; противоположен «РФ напрямую».

Список качает и проверяет awg2 (тот же, что у «РФ напрямую»), здесь —
только экран: состояние, счётчик, включить, выключить, обновить список.
"""

from __future__ import annotations

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery

from .. import api, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "rub")
TIMEOUT = 240                       # скачать список РФ (до 60 с с каждого источника) и применить
TITLE = "РФ мимо VPN"


def _n(v: int | None) -> str:
    return f"{int(v or 0):,}".replace(",", " ")


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await screen(cb)


async def screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("rublock", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, TITLE), ui.kb(ui.back("srv")))
        return
    d = r.data
    on = bool(d.get("enabled"))
    lines = [f"<b>🇷🇺 {TITLE}</b>",
             "Клиенты VPN не ходят через сервер в сети России. Российские сайты и приложения не видят адрес "
             "сервера и не могут сдать его как VPN — для зарубежного сервера.",
             "Российские сервисы у клиентов через VPN сразу получат отказ — в приложении VPN их пускают мимо "
             "туннеля.", ""]
    if note:
        lines += [note, ""]
    if on:
        lines.append(("🟢 Включено" if d.get("active") else "🟡 Включено, правило не на месте — вернёт таймер или "
                      "«Обновить список»") + f" · сетей России {_n(d.get('nets'))}")
        lines.append(f"🚫 Отказано: {_n(d.get('blocked'))} пакетов в сети России (сбрасывается при перезагрузке)")
        if d.get("home"):
            lines.append("⚠️ Сервер в России: российские сайты и так видят российский адрес. «РФ мимо VPN» нужен "
                         "зарубежному серверу; серверу в России — «РФ напрямую» (Туннели).")
    else:
        lines.append("⚪️ Выключено")
        if d.get("rudirect"):
            lines.append("ℹ️ Сейчас включено «РФ напрямую» (Туннели) — противоположный режим. Сначала выключи его.")
    if d.get("updated"):
        lines.append(f"🕒 Список обновлён {ui.fmt_time(d['updated'])}" + (f" ({esc(d['src'])})"
                                                                         if d.get("src") else ""))
    if d.get("error"):
        lines.append(f"▲ {esc(d['error'])}")
    lines.append("\n<i>Список сетей России — ipverse (данные RIPE), обновляется раз в сутки. Трафик самого "
                 "сервера не трогается.</i>")
    buttons: list = [("⏹ Выключить", act.data("off")) if on else ("✅ Включить", act.data("on"))]
    if on:
        buttons.append(("🔄 Обновить список", act.data("upd")))
    buttons += [("📜 Журнал", "diag:log:rublock|rub"), ui.back("srv")]
    await ui.render(target, "\n".join(lines), ui.kb(*buttons))


@act("on")
async def _on(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Включить? Российские сайты и приложения у клиентов через VPN перестанут открываться — "
                     "в приложении VPN их надо пустить мимо туннеля. Выключить можно здесь, в боте.",
                     ("✅ Включить", act.data("onok")), act.data())


@act("onok")
async def _on_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Скачиваю и проверяю список сетей России, ставлю правило…")
    r = await api.call("rublock", "on", timeout=TIMEOUT)
    await screen(cb, "✅ Включено" if r.ok else ui.fail(r, TITLE))


@act("off")
async def _off(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Выключить? Правило и набор снимаются — клиенты VPN снова пойдут в сети России через "
                     "сервер.", ("⏹ Выключить", act.data("offok")), act.data())


@act("offok")
async def _off_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Снимаю правило…")
    r = await api.call("rublock", "off", timeout=60)
    await screen(cb, "⏹ Выключено" if r.ok else ui.fail(r, TITLE))


@act("upd")
async def _upd(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Обновляю список…")
    r = await api.call("rublock", "update", timeout=TIMEOUT)
    await screen(cb, "✅ Список обновлён" if r.ok else ui.fail(r, "Обновление списка"))
