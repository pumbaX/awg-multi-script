"""Точки входа (каскад): клиент подключается не к серверу напрямую, а через
сервер-вход — любой сервер, где UDP-порт проброшен на этот (каскад Тулзы,
iptables, nginx stream). В конфиге такого клиента Endpoint — адрес входа.
Пункт «Сервер → Endpoint → Точки входа» awg2.

Здесь — список, добавление, адрес, проверка, вход для новых клиентов,
перевод всех клиентов и удаление. Вход одного клиента — кнопкой «📍 Вход» в
его карточке (clients.py).
"""

from __future__ import annotations

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

import asyncio
import time

from .. import api, ask, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "ent")
TITLE = "Точки входа"
NAME_MAX = 24


async def entries() -> list[dict] | None:
    """Строки awg2 api entry list; первая — «напрямую» (name пустое)."""
    r = await api.call("entry", "list")
    return r.data if r.ok and isinstance(r.data, list) else None


def label(e: dict) -> str:
    return e.get("name") or "Напрямую"


def arg(name: str) -> str:
    """Имя для awg2: «напрямую» — direct."""
    return name or "direct"


def usable(e: dict) -> bool:
    """Можно ли выдавать вход клиентам: «напрямую» — всегда; вход — если
    проверка прошла или проверить нельзя. Не прошёл или не проверялся —
    кнопки выдачи заперты, awg2 перед выдачей и сам проверит ещё раз."""
    return not e.get("name") or e.get("check") in ("ok", "unknown")


def status(e: dict) -> str:
    if not e.get("name"):
        return "✅ этот сервер"
    ago = int(time.time()) - int(e.get("checked") or 0)
    when = (f" · {ago // 60} мин назад" if ago < 3600 else f" · {ago // 3600} ч назад" if ago < 86400 * 2 else "")
    return {"ok": "✅ работает" + when, "fail": "❌ пакеты не доходят до сервера" + when,
            "unknown": "❔ проверить нельзя — проверь клиентом"}.get(e.get("check") or "", "⚪️ не проверялся")


LOCKED = ("Вход не прошёл проверку: через него пакеты не доходят до сервера. Проверь проброс на сервере-входе "
          "и нажми «🩺 Проверить» — после удачной проверки выдать его клиентам можно.")


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg_: str = "") -> None:
    await screen(cb, state)


async def screen(target: ui.Target, state: FSMContext) -> None:
    rows, info = await asyncio.gather(entries(), api.data("server", "info", default={}))
    if rows is None:
        r = await api.call("entry", "list")
        await ui.render(target, ui.fail(r, TITLE), ui.kb(ui.back("srv")))
        return
    # Имена — в FSM: в callback_data (64 байта) кириллица длиной 24 не влезет
    await ui.remember(state, "entry", [e["name"] for e in rows])
    lines = [f"<b>📍 {TITLE}</b>", "",
             "Клиент подключается через сервер-вход — любой сервер, где UDP-порт проброшен на этот "
             "(каскад). В конфиге и QR такого клиента Endpoint — адрес входа, остальное как у всех.", ""]
    for e in rows:
        lines.append(f"{'⭐' if e.get('default') else '•'} <b>{esc(label(e))}</b> — "
                     f"<code>{esc(e.get('addr', ''))}</code>, клиентов {e.get('clients', 0)}"
                     + ("" if not e.get("name") else f"\n   {status(e)}"))
    lines += ["", "⭐ — вход для новых клиентов. Вход клиента — «📍 Вход» в его карточке."]
    # IPv6 этого сервера — входом в одно нажатие, если его ещё нет
    v6 = (info or {}).get("ipv6") or ""
    v6_new = bool(v6) and not any(str(e.get("addr", "")).startswith(f"[{v6}]") for e in rows)
    if v6_new:
        lines.append(f"🌐 У сервера есть IPv6 <code>{esc(v6)}</code> — клиентов можно подключать по нему.")
    await ui.render(target, "\n".join(lines), ui.kb(
        [(("⭐ " if e.get("default") else "") + label(e), act.data("e", str(i))) for i, e in enumerate(rows)],
        ("➕ Добавить", act.data("add")) if len(rows) <= 20 else None,
        ("🌐 IPv6 сервера", act.data("v6")) if v6_new and len(rows) <= 20 else None,
        ui.back("srv")))


@act("v6")
async def _add_v6(cb: CallbackQuery, state: FSMContext, arg_: str) -> None:
    await ui.render(cb, "⏳ Добавляю IPv6 сервера и проверяю…")
    await ui.result(cb, await api.call("entry", "add-ipv6"), "IPv6 сервера", act.data())


async def _entry(state: FSMContext, idx: str) -> tuple[str, dict] | None:
    name = await ui.recall(state, "entry", idx)
    if name is None:
        return None
    rows = await entries() or []
    e = next((r for r in rows if r.get("name") == name), None)
    return (name, e) if e else None


async def _gone(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer("Точки входа уже нет — список обновлён")
    await screen(cb, state)


@act("e")
async def _card(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    await card(cb, state, idx)


async def card(target: ui.Target, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None:
        await ui.render(target, "Точки входа уже нет.", ui.kb(ui.back(act.data())))
        return
    name, e = got
    ok = usable(e)
    lines = [f"<b>📍 {esc(label(e))}</b>", "",
             f"Адрес: <code>{esc(e.get('addr', ''))}</code>",
             f"Клиентов: {e.get('clients', 0)}",
             "Для новых клиентов: " + ("⭐ да" if e.get("default") else "нет")]
    if name:
        lines.append(f"Проверка: {status(e)}")
    else:
        lines += ["", "<i>Напрямую — этот сервер: IP или домен из «🌍 Endpoint».</i>"]
    if not ok:
        lines += ["", "🔒 Выдать клиентам нельзя, пока вход не пройдёт проверку."]
    lock = act.data("lock", idx)
    await ui.render(target, "\n".join(lines), ui.kb(
        ("🩺 Проверить", act.data("chk", idx)) if name else None,
        ("✏️ Адрес", act.data("addr", idx)) if name else None,
        ("👥 Выбрать" if ok else "🔒 Выбрать", act.data("pick", idx) if ok else lock),
        ("👥 Всех сюда" if ok else "🔒 Всех сюда", act.data("all", idx) if ok else lock),
        (("⭐ Для новых" if ok else "🔒 Для новых", act.data("def", idx) if ok else lock))
        if not e.get("default") else None,
        ("🗑 Удалить", act.data("del", idx)) if name else None,
        ui.back(act.data())))


@act("lock")
async def _lock(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    await cb.answer(LOCKED, show_alert=True)


@act("chk")
async def _check(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None:
        await _gone(cb, state)
        return
    await ui.render(cb, f"⏳ Проверяю вход «{esc(got[0])}»…")
    await ui.result(cb, await api.call("entry", "check", got[0]), f"Проверка «{got[0]}»", act.data("e", idx))


@act("def")
async def _default(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None:
        await _gone(cb, state)
        return
    if not usable(got[1]):
        await cb.answer(LOCKED, show_alert=True)
        return
    r = await api.call("entry", "default", arg(got[0]))
    if not r.ok:
        await ui.render(cb, ui.fail(r, TITLE), ui.kb(ui.back(act.data("e", idx))))
        return
    await cb.answer(f"Новые клиенты — {'напрямую' if not got[0] else 'через «' + got[0] + '»'}")
    await card(cb, state, idx)


@act("all")
async def _all(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None:
        await _gone(cb, state)
        return
    if not usable(got[1]):
        await cb.answer(LOCKED, show_alert=True)
        return
    await ui.confirm(cb, f"<b>👥 Все клиенты → {esc(label(got[1]))}</b>\n\nEndpoint перепишется во всех "
                         f"конфигах на <code>{esc(got[1].get('addr', ''))}</code>. Каждому клиенту нужен новый "
                         "конфиг или QR — в старом прежний адрес.",
                     ("✅ Перевести", act.data("allok", idx)), act.data("e", idx))


@act("allok")
async def _all_ok(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None:
        await _gone(cb, state)
        return
    await ui.result(cb, await api.call("entry", "all", arg(got[0]), timeout=300), TITLE, act.data())


# ── Выбрать клиентов ──────────────────────────────────────
# Отмеченные имена — в данных FSM (ent_sel): в callback_data их не уложить.
SEND_MAX = 20                       # больше — архивом: в чат по одному сотню файлов не шлём


async def _clients() -> list[dict]:
    from . import clients as cl     # clients импортирует этот модуль — здесь лениво
    rows = await cl.clients() or []
    rows, _ = cl.usable(rows)
    return sorted([c for c in rows if c.get("name")], key=lambda c: c["name"].lower())


async def pick_screen(target: ui.Target, state: FSMContext, idx: str, page: int = 0) -> None:
    got = await _entry(state, idx)
    if got is None:
        await ui.render(target, "Точки входа уже нет.", ui.kb(ui.back(act.data())))
        return
    name, e = got
    rows = await _clients()
    names = {c["name"] for c in rows}
    sel = [n for n in (await state.get_data()).get("ent_sel") or [] if n in names]
    await state.update_data(ent_sel=sel)
    here = sum(1 for c in rows if (c.get("entry") or "") == name)
    buttons = [(f"{'☑️' if c['name'] in sel else '⬜️'} {c['name']}" + (" 📍" if (c.get("entry") or "") == name else ""),
                act.data("t", f"{idx}|{page}|{c['name']}")) for c in rows]
    await ui.render(target, f"<b>👥 Вход «{esc(label(e))}»</b> — <code>{esc(e.get('addr', ''))}</code>\n"
                            "Отметь клиентов: им выдаётся адрес этого входа, затем — новые конфиги и QR.\n"
                            f"📍 — уже на этом входе ({here}).\n\n"
                            + (f"Отмечено: {len(sel)}" if sel else "Никто не отмечен."),
                    ui.kb(ui.paged(buttons, page, lambda p: act.data("pp", f"{idx}|{p}")),
                          ("☑️ Всех", act.data("pa", f"{idx}|{page}|all")) if len(sel) < len(rows) else None,
                          ("⬜️ Снять все", act.data("pa", f"{idx}|{page}|none")) if sel else None,
                          (f"✅ Выдать: {len(sel)}", act.data("go", idx)) if sel else None,
                          ui.back(act.data("e", idx))))


@act("pick")
async def _pick(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is not None and not usable(got[1]):
        await cb.answer(LOCKED, show_alert=True)
        return
    await state.update_data(ent_sel=[])
    await pick_screen(cb, state, idx)


@act("pp")
async def _pick_page(cb: CallbackQuery, state: FSMContext, arg_: str) -> None:
    idx, _, page = arg_.partition("|")
    await pick_screen(cb, state, idx, int(page) if page.isdigit() else 0)


@act("t")
async def _pick_toggle(cb: CallbackQuery, state: FSMContext, arg_: str) -> None:
    idx, page, name = (arg_.split("|", 2) + ["", ""])[:3]
    sel = list((await state.get_data()).get("ent_sel") or [])
    if name in sel:
        sel.remove(name)
    else:
        sel.append(name)
    await state.update_data(ent_sel=sel)
    await pick_screen(cb, state, idx, int(page) if page.isdigit() else 0)


@act("pa")
async def _pick_all(cb: CallbackQuery, state: FSMContext, arg_: str) -> None:
    idx, page, what = (arg_.split("|", 2) + ["", ""])[:3]
    rows = await _clients()
    await state.update_data(ent_sel=[c["name"] for c in rows] if what == "all" else [])
    await pick_screen(cb, state, idx, int(page) if page.isdigit() else 0)


@act("go")
async def _pick_go(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    sel = (await state.get_data()).get("ent_sel") or []
    if got is None or not sel:
        await pick_screen(cb, state, idx)
        return
    shown = ", ".join(sel[:30]) + (f" и ещё {len(sel) - 30}" if len(sel) > 30 else "")
    await ui.confirm(cb, f"<b>Вход «{esc(label(got[1]))}» — клиентам: {len(sel)}</b>\n{esc(shown)}\n\n"
                         f"Endpoint в их конфигах станет <code>{esc(got[1].get('addr', ''))}</code>. "
                         "В старых конфигах прежний адрес — клиентам нужны новые.",
                     ("✅ Выдать", act.data("gook", idx)), act.data("pp", f"{idx}|0"))


@act("gook")
async def _pick_ok(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    sel = (await state.get_data()).get("ent_sel") or []
    if got is None or not sel:
        await screen(cb, state)
        return
    await ui.render(cb, f"⏳ Выдаю вход клиентам: {len(sel)}…")
    r = await api.call("entry", "clients", arg(got[0]), ",".join(sel), timeout=300)
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Выдача входа"), ui.kb(ui.back(act.data("e", idx))))
        return
    done = list(r.data or []) if isinstance(r.data, list) else sel
    await state.update_data(ent_sel=[], ent_sent=done)
    await done_screen(cb, label(got[1]), got[1].get("addr", ""), done, idx)


async def done_screen(target: ui.Target, title: str, addr: str, done: list[str], idx: str) -> None:
    shown = ", ".join(done[:30]) + (f" и ещё {len(done) - 30}" if len(done) > 30 else "")
    await ui.render(target, f"✅ <b>Вход «{esc(title)}»: {len(done)}</b>\n{esc(shown)}\n\n"
                            f"Endpoint: <code>{esc(addr)}</code>. Отправь клиентам новые конфиги или QR.",
                    ui.kb((f"📨 Конфиги: {len(done)}", act.data("send")) if 0 < len(done) <= SEND_MAX else None,
                          ("📦 Конфиги zip", "cl:export") if len(done) > SEND_MAX else None,
                          ui.back(act.data("e", idx))))


@act("send")
async def _send(cb: CallbackQuery, state: FSMContext, arg_: str) -> None:
    from . import clients as cl
    names = ((await state.get_data()).get("ent_sent") or [])[:SEND_MAX]
    await cb.answer(f"Отправляю конфиги: {len(names)}")
    for n in names:
        await cl.send_config(cb.bot, ui.chat_of(cb).chat.id, n)  # type: ignore[arg-type]
    await state.update_data(ent_sent=[])


@act("del")
async def _del(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None or not got[0]:
        await _gone(cb, state)
        return
    n = got[1].get("clients", 0)
    await ui.confirm(cb, f"Удалить точку входа <b>{esc(got[0])}</b>?"
                         + (f"\n\nЕё клиенты ({n}) перейдут на «напрямую» — им нужен новый конфиг." if n else ""),
                     ("🗑 Удалить", act.data("delok", idx)), act.data("e", idx))


@act("delok")
async def _del_ok(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None or not got[0]:
        await _gone(cb, state)
        return
    await ui.result(cb, await api.call("entry", "del", got[0], timeout=300), TITLE, act.data())


ADDR_HINT = ("Адрес сервера-входа и порт, который проброшен на этот сервер: "
             "<code>203.0.113.5:443</code>, <code>vpn.example.com:443</code> или <code>[2001:db8::1]:443</code>")


@act("addr")
async def _addr(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    got = await _entry(state, idx)
    if got is None or not got[0]:
        await _gone(cb, state)
        return
    await ask.ask(cb, state, "ent_set", f"Новый адрес «{esc(got[0])}».\n{ADDR_HINT}", act.data("e", idx),
                  name=got[0], idx=idx)


@ask.on("ent_set")
async def _addr_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg).replace(" ", "")
    if ":" not in v:
        await ask.retry(msg, state, ctx, "Нужен хост:порт")
        return
    await ui.render(msg, "⏳ Меняю адрес и проверяю вход…")
    await ui.result(msg, await api.call("entry", "set", ctx["name"], v, timeout=300), TITLE, act.data("e", ctx["idx"]))


@act("add")
async def _add(cb: CallbackQuery, state: FSMContext, arg_: str) -> None:
    await ask.ask(cb, state, "ent_name", "Название точки входа, например <code>Каскад NL</code> — "
                                         f"буквы, цифры, пробел, точка, _ и -, до {NAME_MAX} символов.",
                  act.data())


@ask.on("ent_name")
async def _add_name(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    name = " ".join(ask.text_of(msg).split())
    if not name or len(name) > NAME_MAX or any(ch in name for ch in "|,=#"):
        await ask.retry(msg, state, ctx, f"Название — до {NAME_MAX} символов: буквы, цифры, пробел, точка, _ и -")
        return
    await ask.ask(msg, state, "ent_add", f"Вход «{esc(name)}».\n{ADDR_HINT}", act.data(), name=name)


@ask.on("ent_add")
async def _add_addr(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg).replace(" ", "")
    if ":" not in v:
        await ask.retry(msg, state, ctx, "Нужен хост:порт")
        return
    await ui.render(msg, "⏳ Добавляю и проверяю вход…")
    await ui.result(msg, await api.call("entry", "add", ctx["name"], v), TITLE, act.data())
