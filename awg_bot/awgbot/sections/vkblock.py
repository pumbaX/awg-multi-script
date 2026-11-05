"""VK и Max мимо VPN: трафик клиентов VPN в сети VK (ВКонтакте, Max,
Одноклассники) сервер отбрасывает — приложения VK не видят его адрес. Пункт
«Сервер → VK и Max мимо VPN» awg2.

Список качает и проверяет awg2, здесь — только экран: состояние, счётчик,
включить, выключить, обновить список.
"""

from __future__ import annotations

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery

from .. import api, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "vk")
TIMEOUT = 180                       # скачать список (до 40 с) и применить; замок таймера — до 180 с
TITLE = "VK и Max мимо VPN"


def _n(v: int | None) -> str:
    return f"{int(v or 0):,}".replace(",", " ")


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await screen(cb)


async def screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("vkblock", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, TITLE), ui.kb(ui.back("srv")))
        return
    d = r.data
    on = bool(d.get("enabled"))
    lines = [f"<b>🚫 {TITLE}</b>",
             "Клиенты VPN не ходят через сервер в сети VK: ВКонтакте, Max, Одноклассники. Приложения VK не видят "
             "адрес сервера и не могут сдать его как VPN.",
             "Сервисы VK у клиентов через VPN не откроются — в приложении VPN их пускают мимо туннеля.", ""]
    if note:
        lines += [note, ""]
    if on:
        lines.append(("🟢 Включено" if d.get("active") else "🟡 Включено, правило не на месте — вернёт таймер или "
                      "«Обновить список»") + f" · подсетей {_n((d.get('v4') or 0) + (d.get('v6') or 0))}")
        lines.append(f"🚫 Отбито: {_n(d.get('dropped'))} пакетов в сети VK (сбрасывается при перезагрузке)")
    else:
        lines.append("⚪️ Выключено")
    if d.get("updated"):
        lines.append(f"🕒 Список обновлён {ui.fmt_time(d['updated'])}")
    if d.get("error"):
        lines.append(f"▲ {esc(d['error'])}")
    lines.append("\n<i>Список сетей VK — C24Be/AS_Network_List, обновляется раз в сутки. Трафик самого сервера "
                 "не трогается.</i>")
    buttons: list = [("⏹ Выключить", act.data("off")) if on else ("✅ Включить", act.data("on"))]
    if on:
        buttons.append(("🔄 Обновить список", act.data("upd")))
    buttons += [("📜 Журнал", "diag:log:vkblock|vk"), ui.back("srv")]
    await ui.render(target, "\n".join(lines), ui.kb(*buttons))


@act("on")
async def _on(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Включить? ВКонтакте, Max и другие сервисы VK у клиентов через VPN перестанут "
                     "открываться — в приложении VPN их надо пустить мимо туннеля. Выключить можно здесь, в боте.",
                     ("✅ Включить", act.data("onok")), act.data())


@act("onok")
async def _on_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Скачиваю и проверяю список сетей VK, ставлю правило…")
    r = await api.call("vkblock", "on", timeout=TIMEOUT)
    await screen(cb, "✅ Включено" if r.ok else ui.fail(r, TITLE))


@act("off")
async def _off(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Выключить? Правило и наборы снимаются — клиенты VPN снова пойдут в VK через сервер.",
                     ("⏹ Выключить", act.data("offok")), act.data())


@act("offok")
async def _off_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("vkblock", "off")
    await screen(cb, "⏹ Выключено" if r.ok else ui.fail(r, TITLE))


@act("upd")
async def _upd(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Обновляю список…")
    r = await api.call("vkblock", "update", timeout=TIMEOUT)
    await screen(cb, "✅ Список обновлён" if r.ok else ui.fail(r, "Обновление списка"))
