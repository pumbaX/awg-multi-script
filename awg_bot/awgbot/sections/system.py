"""Удаление и обновление AWG Toolza — пункты «Удаление» и «Обновление»."""

from __future__ import annotations

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery

from .. import access, api, jobs, store, ui
from ..ui import esc

router = Router()
rm = ui.Actions(router, "del")
upd = ui.Actions(router, "upd")


# ── Удаление ──────────────────────────────────────────────
@rm()
async def uninstall_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    owner = access.is_owner(cb.from_user.id)
    await ui.render(cb, "<b>🗑 Удаление</b>\n\nПеред удалением делается бэкап в <code>~/awg_backup</code>.\n\n"
                        "• Всех клиентов — сервер, параметры и туннели остаются\n"
                        + ("• Удалить всё — сервер, туннели, модуль ядра и утилиты" if owner else ""),
                    ui.kb(("🧹 Всех клиентов", rm.data("clients")),
                          ("💣 Удалить всё", rm.data("all")) if owner else None,
                          ui.back()))


@rm("clients")
async def _clients(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Удалить <b>всех</b> клиентов? Их конфиги перестанут работать; сервер, его параметры "
                         "и туннели останутся. Перед удалением — авто-бэкап.",
                     ("🧹 Да, удалить", rm.data("clientsok")), "del")


@rm("clientsok")
async def _clients_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("clients", "clean")
    if r.ok:
        store.save(store.NOTES, {})
    await ui.result(cb, r, "Клиенты удалены", "del")


async def _all_screen(target: ui.Target, state: FSMContext) -> None:
    opts = (await state.get_data()).get("uninstall") or {}
    mark = lambda k: "🗑" if opts.get(k) else "⬜️"                        # noqa: E731
    await ui.render(target, "<b>💣 Удалить всё</b>\n\nСервер AWG, клиенты, туннели, модуль ядра и утилиты. "
                            "Отметь, что удалить вместе с ними:",
                    ui.kb((f"{mark('bot')} Telegram-бот", rm.data("opt", "bot")),
                          (f"{mark('wgobf')} Обфускатор", rm.data("opt", "wgobf")),
                          (f"{mark('self')} Скрипт awg2", rm.data("opt", "self")),
                          ui.Row(("💣 Удалить", rm.data("allgo")), ui.back("del", "✖️ Отмена"))))


@rm("all")
async def _all(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if not access.is_owner(cb.from_user.id):
        await cb.answer("Только владелец", show_alert=True)
        return
    await state.update_data(uninstall={})
    await _all_screen(cb, state)


@rm("opt")
async def _opt(cb: CallbackQuery, state: FSMContext, key: str) -> None:
    opts = dict((await state.get_data()).get("uninstall") or {})
    opts[key] = not opts.get(key)
    await state.update_data(uninstall=opts)
    await _all_screen(cb, state)


@rm("allgo")
async def _all_go(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "⚠️ Это необратимо: VPN-сервер перестанет существовать. Точно удалить?",
                     ("💣 Да, удалить", rm.data("allok")), rm.data("all"))


@rm("allok")
async def _all_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    if not access.is_owner(cb.from_user.id):
        return
    opts = (await state.get_data()).get("uninstall") or {}
    await state.update_data(uninstall={})
    await jobs.start(cb, "Удаление AWG Toolza", "uninstall", *[k for k in ("bot", "wgobf", "self") if opts.get(k)],
                     back_to="main")


# ── Обновление ────────────────────────────────────────────
@upd()
async def update_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    d = await api.data("update", "status", default={}) or {}
    await _render_update(cb, d, d.get("available") or "")


async def _render_update(target: ui.Target, d: dict, latest: str, checked: bool = False) -> None:
    beta = d.get("channel") == "beta"
    text = (f"<b>⬆️ Обновление AWG Toolza</b>\n\nУстановлена: <b>{esc(d.get('version', '?'))}</b>\n"
            f"Канал: {'бета — ранние сборки' if beta else 'стабильный'}")
    if latest:
        text += f"\nДоступна: <b>{esc(latest)}</b>"
    elif checked:
        text += "\nОбновлений нет."
    text += "\n\n<i>♻️ Переустановить — заново из текущего канала, даже без новой версии</i>"
    await ui.render(target, text, ui.kb(
        ("⬆️ Обновить", upd.data("go")) if latest else None,
        ("📋 Что нового", upd.data("notes")),
        ("🔎 Проверить", upd.data("check")),
        ("♻️ Переустановить", upd.data("force")),
        ("🔀 На стабильный" if beta else "🧪 Бета-канал", upd.data("ch", "stable" if beta else "beta")),
        ui.back()))


@upd("check")
async def _check(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Проверяю канал обновлений…")
    r = await api.call("update", "check")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "Проверка обновлений"), ui.kb(ui.back("upd")))
        return
    d = r.data
    await _render_update(cb, d, d.get("latest") if d.get("newer") else "", checked=True)


NOTES_MAX = 3600                    # сообщение Telegram — до 4096 символов


@upd("notes")
async def _notes(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    """Что нового: разделы CHANGELOG новее установленной (нет новее — текущей)."""
    await ui.render(cb, "⏳ Загружаю список изменений…")
    r = await api.call("update", "changelog", timeout=60)
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "Что нового"), ui.kb(ui.back("upd")))
        return
    d = r.data
    parts = []
    for sec in d.get("sections") or []:
        head = ui.changelog_headline(str(sec.get("body") or ""))
        parts.append(f"🔹 <b>{esc(str(sec.get('version') or ''))}</b>"
                     + (f" · {esc(str(sec.get('title') or ''))}" if sec.get("title") else "")
                     + (f"\n<i>{esc(head)}</i>" if head else "")
                     + "\n" + ui.changelog_html(str(sec.get("body") or "")))
    text = "<b>📋 Что нового</b>" + ("" if d.get("newer") else " — в установленной версии")
    for p in parts:
        room = NOTES_MAX - len(text) - 2
        if len(p) <= room:
            text += "\n\n" + p
            continue
        # Не влезает — по строкам (каждая — законченный HTML), остальное — ссылкой
        cut = ""
        for ln in p.split("\n"):
            if len(cut) + len(ln) + 1 > room - 60:
                break
            cut += ("\n" if cut else "") + ln
        text += ("\n\n" + cut if cut else "") + "\n\n<i>…остальное — в CHANGELOG.md на GitHub</i>"
        break
    await ui.render(cb, text, ui.kb(("⬆️ Обновить", upd.data("go")) if d.get("newer") else None, ui.back("upd")))


AFTER_UPDATE = [("⬆️ Обновить бота", "botm:update")]


@upd("go")
async def _go(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Обновление awg2", "update", "install", back_to="upd", ok_buttons=AFTER_UPDATE)


@upd("force")
async def _force(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Поставить версию из канала поверх текущей? Если в канале версия старше — это откат.",
                     ("♻️ Переустановить", upd.data("forceok")), "upd")


@upd("forceok")
async def _force_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Переустановка awg2", "update", "install", "force", back_to="upd", ok_buttons=AFTER_UPDATE)


@upd("ch")
async def _channel(cb: CallbackQuery, state: FSMContext, ch: str) -> None:
    r = await api.call("update", "channel", ch)
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Канал"), ui.kb(ui.back("upd")))
        return
    await _check(cb, state, "")
