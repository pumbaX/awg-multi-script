"""Почта: порт 25 — клиенты VPN не отправляют почту через сервер на порт 25
(SMTP между почтовыми серверами): спам с сервера не уйдёт, хостер не
заблокирует сервер. Пункт «Сервер → Почта: порт 25» awg2.
"""

from __future__ import annotations

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery

from .. import api, ui

router = Router()
act = ui.Actions(router, "smtp")
TITLE = "Почта: порт 25"


def _n(v: int | None) -> str:
    return f"{int(v or 0):,}".replace(",", " ")


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await screen(cb)


async def screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("smtpblock", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, TITLE), ui.kb(ui.back("srv")))
        return
    d = r.data
    on = bool(d.get("enabled"))
    lines = [f"<b>✉️ {TITLE}</b>",
             "Клиенты VPN не отправляют почту через сервер на порт 25 — спам с сервера не уйдёт, хостер не "
             "заблокирует сервер. Почтовые приложения шлют письма через 465 и 587 — они работают.", ""]
    if note:
        lines += [note, ""]
    if on:
        lines.append("🟢 Порт 25 закрыт для клиентов" if d.get("active")
                     else "🟡 Включено, правила не на месте — вернёт таймер или «Открыть» и «Закрыть»")
        lines.append(f"🚫 Отбито: {_n(d.get('dropped'))} попыток на порт 25 (сбрасывается при перезагрузке)")
    else:
        lines.append("⚪️ Открыт — клиенты могут слать почту на порт 25")
    lines.append("\n<i>Соединения к самому серверу и его собственная почта не трогаются.</i>")
    await ui.render(target, "\n".join(lines), ui.kb(
        ("🔓 Открыть порт 25", act.data("off")) if on else ("🔒 Закрыть порт 25", act.data("on")),
        ui.back("srv")))


@act("on")
async def _on(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("smtpblock", "on", timeout=60)
    await screen(cb, "✅ Порт 25 закрыт" if r.ok else ui.fail(r, TITLE))


@act("off")
async def _off(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Открыть порт 25? Клиенты VPN снова смогут слать почту через сервер напрямую "
                     "почтовым серверам — и спам тоже.", ("🔓 Открыть", act.data("offok")), act.data())


@act("offok")
async def _off_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("smtpblock", "off", timeout=60)
    await screen(cb, "🔓 Порт 25 открыт" if r.ok else ui.fail(r, TITLE))
