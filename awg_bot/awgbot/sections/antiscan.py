"""Антисканер: новые входящие подключения из сетей сканеров РКН, СКИПА и
госорганов отбрасываются до служб сервера — пункт «Сервер → Антисканер» awg2.

Списки качает и проверяет awg2, здесь — только экран: состояние, счётчик,
кто чаще стучался, какие списки блокировать и исключения.
"""

from __future__ import annotations

import ipaddress

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import api, ask, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "as")
TIMEOUT = 300                       # скачать три списка (до 40 с каждый) и применить
ALLOW_SHOWN = 20                    # исключений кнопками на экране


def _n(v: int | None) -> str:
    return f"{int(v or 0):,}".replace(",", " ")


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await screen(cb)


async def screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("antiscan", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, "Антисканер"), ui.kb(ui.back("srv")))
        return
    d = r.data
    on = bool(d.get("enabled"))
    lines = ["<b>🛡 Антисканер</b>",
             "Новые подключения из сетей сканеров РКН и госорганов отбрасываются до SSH, Xray и панелей. "
             "VPN-трафик клиентов не трогается.", ""]
    if note:
        lines += [note, ""]
    if on:
        lines.append(("🟢 Включён" if d.get("active") else "🟡 Включён, правило не на месте — вернёт таймер или "
                      "«Обновить списки»") + f" · подсетей {_n((d.get('v4') or 0) + (d.get('v6') or 0))}")
        lines.append(f"🚫 Отбито: {_n(d.get('dropped'))} новых подключений с установки правила (сбрасывается при перезагрузке)")
    else:
        lines.append("⚪️ Выключен")
    if d.get("updated"):
        lines.append(f"🕒 Списки обновлены {ui.fmt_time(d['updated'])}")
    if d.get("error"):
        lines.append(f"▲ {esc(d['error'])}")
    top = [t for t in d.get("top") or [] if isinstance(t, dict)]
    if top:
        lines += ["", "<b>Чаще всего стучались</b>"]
        lines += [f"• <code>{esc(t.get('net', ''))}</code> — {_n(t.get('packets'))}"
                  + (f" · {esc(t['org'])}" if t.get("org") else "") for t in top]
    lines += ["", "<b>Списки</b>"]
    lists = [x for x in d.get("lists") or [] if isinstance(x, dict)]
    lines += [f"{'✅' if x.get('on') else '▫️'} {esc(x.get('name', ''))} — {_n(x.get('entries'))}" for x in lists]
    allow = d.get("allow") or []
    ssh = d.get("ssh") or []
    lines.append(f"\nИсключения: {len(allow)}" + (" · твой SSH не блокируется" if ssh else ""))
    lines.append("\n<i>Клиенты VPN, которые подключаются из этих сетей, тоже не подключатся — для них есть "
                 "исключения.</i>")
    buttons: list = [("⏹ Выключить", act.data("off")) if on else ("✅ Включить", act.data("on"))]
    if on:
        buttons.append(("🔄 Обновить списки", act.data("upd")))
    buttons.append(ui.Row(*[(f"{'✅' if x.get('on') else '▫️'} {x.get('name', '').split(' — ')[0]}",
                             act.data("l", x.get("id", ""))) for x in lists]))
    buttons += [("📝 Исключения", act.data("al")), ("📜 Журнал", "diag:log:antiscan|as"), ui.back("srv")]
    await ui.render(target, "\n".join(lines), ui.kb(*buttons))


@act("on")
async def _on(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    # Адреса админа бот не знает (в отличие от панели и SSH) — только предупреждение
    await ui.confirm(cb, "Включить антисканер? Новые подключения из сетей списков не пройдут — в том числе клиенты "
                     "VPN и, возможно, ты сам: SSH, панель, Mini App. Открытые соединения не рвутся, выключить "
                     "можно здесь, в боте.", ("✅ Включить", act.data("onok")), act.data())


@act("onok")
async def _on_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Скачиваю и проверяю списки, ставлю правило…")
    r = await api.call("antiscan", "on", timeout=TIMEOUT)
    await screen(cb, "✅ Включён" if r.ok else ui.fail(r, "Антисканер"))


@act("off")
async def _off(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Выключить антисканер? Правило и наборы снимаются, сканеры снова увидят порты сервера.",
                     ("⏹ Выключить", act.data("offok")), act.data())


@act("offok")
async def _off_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("antiscan", "off")
    await screen(cb, "⏹ Выключен" if r.ok else ui.fail(r, "Антисканер"))


@act("upd")
async def _upd(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Обновляю списки…")
    r = await api.call("antiscan", "update", timeout=TIMEOUT)
    await screen(cb, "✅ Списки обновлены" if r.ok else ui.fail(r, "Обновление списков"))


@act("l")
async def _toggle_list(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("antiscan", "status")
    lists = [x for x in (r.data or {}).get("lists") or [] if isinstance(x, dict)] if r.ok else []
    want = [x["id"] for x in lists if bool(x.get("on")) != (x.get("id") == arg)]
    if not want:
        await cb.answer("Нужен хотя бы один список", show_alert=True)
        return
    await ui.render(cb, "⏳ Применяю списки…")
    r = await api.call("antiscan", "lists", ",".join(want), timeout=TIMEOUT)
    await screen(cb, "" if r.ok else ui.fail(r, "Списки"))


# ── Исключения ────────────────────────────────────────────
@act("al")
async def _allow(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await allow_screen(cb)


async def allow_screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("antiscan", "status")
    d = r.data if r.ok and isinstance(r.data, dict) else {}
    allow = [str(a) for a in d.get("allow") or []]
    lines = ["<b>📝 Исключения антисканера</b>",
             "Адрес или подсеть из исключений не блокируется, даже если она внутри списка. Адреса сервера "
             "и открытых SSH-сессий в исключениях всегда — сами.", ""]
    if note:
        lines += [note, ""]
    lines += [f"• <code>{esc(a)}</code>" for a in allow[:50]] or ["<i>пока пусто</i>"]
    if len(allow) > 50:
        lines.append(f"…и ещё {len(allow) - 50}")
    dels = [(f"❌ {a}", act.data("ad", a)) for a in allow[:ALLOW_SHOWN] if len(act.prefix) + len(a) + 4 <= 64]
    await ui.render(target, "\n".join(lines), ui.kb(("➕ Добавить", act.data("aa")), *dels, ui.back(act.data())))


@act("aa")
async def _allow_add(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "as_allow", "Адрес или подсеть: <code>1.2.3.4</code> или <code>1.2.3.0/24</code> "
                                         "(IPv6 тоже можно)", act.data("al"))


@ask.on("as_allow")
async def _allow_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    text = ask.text_of(msg)
    try:
        ipaddress.ip_network(text, strict=False)
    except ValueError:
        await ask.retry(msg, state, ctx, "Нужен IPv4 или IPv6 адрес, можно с маской: 1.2.3.0/24")
        return
    r = await api.call("antiscan", "allow", "add", text)
    if not r.ok:
        await ask.retry(msg, state, ctx, r.message)
        return
    await allow_screen(msg, f"✅ Добавлен <code>{esc(text)}</code>")


@act("ad")
async def _allow_del(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("antiscan", "allow", "del", arg)
    await allow_screen(cb, f"✅ Убран <code>{esc(arg)}</code>" if r.ok else ui.fail(r, "Исключение"))
