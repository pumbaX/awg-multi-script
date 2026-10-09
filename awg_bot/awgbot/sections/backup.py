"""Бэкапы: создать и скачать, список на сервере, восстановление — в том
числе из присланного в чат архива."""

from __future__ import annotations

import io
import os
import tarfile
import time
from pathlib import Path

from aiogram import Bot, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import BufferedInputFile, CallbackQuery, FSInputFile, Message

from .. import access, alerts, api, ask, jobs, store, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "bk")
abk = ui.Actions(router, "abk", owner="Автобэкап настраивает только владелец")

UPLOADS = store.STATE_DIR / "uploads"


def auto_line(b: dict) -> str:
    """«ежедневно · хранить 7 · последний 02.10 04:00»."""
    if b["mode"] == "off":
        return "выключен"
    last = time.strftime("%d.%m %H:%M", time.localtime(b["last"])) if b.get("last") else "ещё не было"
    tail = f" · ⚠️ {b['error']}" if b.get("error") else ""
    return f"{alerts.BACKUP_MODES[b['mode']]} · хранить {b['keep']} · последний {last}{tail}"


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    owner = access.is_owner(cb.from_user.id)
    await ui.render(cb, "<b>💾 Бэкапы</b>\n\nПолный бэкап: сервер и клиенты, аккаунт WARP, WG + обфускатор, "
                        "настройки туннелей. Хранятся в <code>~/awg_backup</code> на сервере.\n\n"
                        "• Создать — бэкап сразу приходит сюда файлом\n"
                        "• Сохранённые — скачать или восстановить бэкап с сервера\n"
                        "• Из файла — восстановить из присланного архива\n\n"
                        f"🕒 Автобэкап: {esc(auto_line(alerts.backup_info()))}",
                    ui.kb(("💾 Создать", act.data("create")),
                          ("📂 Сохранённые", act.data("list")),
                          ("📤 Из файла", act.data("upload")),
                          ("🕒 Автобэкап", abk.data()) if owner else None,
                          ui.back()))


# ── Автобэкап ─────────────────────────────────────────────
@abk()
async def _auto(cb: CallbackQuery, state: FSMContext, arg: str = "", note: str = "") -> None:
    b = alerts.backup_info()
    mark = lambda ok: "🔘" if ok else "⚪️"                                  # noqa: E731
    # Ряд чисел без подписи непонятен — подпись текстом, как в Mini App
    await ui.render(cb, "<b>🕒 Автобэкап</b>\n\nПолный бэкап по расписанию — файлом сюда, в чат, и только "
                        "владельцам: в нём приватные ключи.\n\n"
                        f"Сейчас: {esc(auto_line(b))}\n\n"
                        "• Первый ряд — расписание\n"
                        f"• Второй — хранить на сервере: последние {b['keep']} автобэкапов "
                        "(сделанные вручную не трогаются)" + (f"\n\n{note}" if note else ""),
                    ui.kb(ui.Row(*[(f"{mark(b['mode'] == m)} {label}", abk.data("m", m))
                                   for m, label in (("off", "Выкл"), ("day", "День"), ("week", "Неделя"))]),
                          ui.Row(*[(f"{mark(b['keep'] == n)} {n}", abk.data("k", str(n))) for n in alerts.BACKUP_KEEP]),
                          ("💾 Сделать сейчас", abk.data("now")) if b["mode"] != "off" else None,
                          ui.back("bk")))


@abk("m")
async def _auto_mode(cb: CallbackQuery, state: FSMContext, mode: str) -> None:
    alerts.set_backup(mode=mode)
    if mode != "off":
        await cb.answer("Первый автобэкап придёт в течение пары минут")
    await _auto(cb, state)


@abk("k")
async def _auto_keep(cb: CallbackQuery, state: FSMContext, n: str) -> None:
    alerts.set_backup(keep=int(n) if n.isdigit() else None)
    await _auto(cb, state)


BACKUP_NOW = {"done": "✅ Автобэкап сделан — файл в чате",
              "busy": "⏳ Сейчас идёт другая операция — нажми ещё раз, когда она закончится",
              "fail": "❌ Не удался — причина выше, повтор через час"}


@abk("now")
async def _auto_now(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await cb.answer("Делаю автобэкап…")
    res = await alerts.backup_due(cb.bot, force=True)               # type: ignore[arg-type]
    await _auto(cb, state, note=BACKUP_NOW.get(res, ""))


async def _send_backup(bot: Bot, chat_id: int, st: dict) -> None:
    path = (st.get("data") or {}).get("path")
    if path and os.path.isfile(path):
        await bot.send_document(chat_id, FSInputFile(path),
                                caption="💾 Бэкап — в нём приватные ключи, храни как пароль")


@act("create")
async def _create(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Бэкап", "backup", "create", back_to="bk", done=_send_backup)


@act("list")
async def _list(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    rows = await api.data("backup", "list", default=[]) or []
    rows = rows[:20]
    await ui.remember(state, "bk", [b["path"] for b in rows])
    if not rows:
        await ui.render(cb, "Бэкапов на сервере нет.", ui.kb(ui.back("bk")))
        return
    await ui.render(cb, "<b>📂 Бэкапы на сервере</b>\nСверху — новые. 📁 — полный, 🗜 — архив.",
                    ui.kb([(f"{'📁' if b['full'] else '🗜'} {time.strftime('%d.%m %H:%M', time.localtime(b['time']))}",
                            act.data("v", str(i))) for i, b in enumerate(rows)], ui.back("bk")))


@act("v")
async def _view(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    path = await ui.recall(state, "bk", idx)
    if not path:
        await _list(cb, state, "")
        return
    await _view_screen(cb, path, idx)


async def _view_screen(target: ui.Target, path: str, idx: str) -> None:
    size = sum(f.stat().st_size for f in Path(path).rglob("*") if f.is_file()) if os.path.isdir(path) \
        else os.path.getsize(path) if os.path.exists(path) else 0
    await ui.render(target, f"<b>{esc(os.path.basename(path))}</b>\n{ui.fmt_bytes(size)}",
                    ui.kb(("📥 Скачать", act.data("get", idx)),
                          ("♻️ Восстановить", act.data("rs", idx)),
                          ui.back(act.data("list"))))


def pack(path: str) -> tuple[bytes, str]:
    """Каталог полного бэкапа — в tar.gz на лету, архив — как есть."""
    if os.path.isfile(path):
        with open(path, "rb") as f:
            return f.read(), os.path.basename(path)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        tar.add(path, arcname=os.path.basename(path))
    return buf.getvalue(), os.path.basename(path) + ".tar.gz"


@act("get")
async def _get(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    path = await ui.recall(state, "bk", idx)
    if not path or not os.path.exists(path):
        await cb.answer("Бэкапа уже нет", show_alert=True)
        return
    await cb.answer("Отправляю…")
    data, name = pack(path)
    await ui.chat_of(cb).answer_document(BufferedInputFile(data, filename=name),
                                         caption="💾 В бэкапе приватные ключи — храни как пароль")


@act("rs")
async def _restore_saved(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    path = await ui.recall(state, "bk", idx)
    if path:
        await _inspect(cb, state, path)


# ── Восстановление ────────────────────────────────────────
@act("upload")
async def _upload(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "bk_file", "Пришли архив бэкапа (<code>.tar.gz</code>) — awg2 или прежнего бота.",
                  "bk")


@ask.on("bk_file")
async def _upload_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    data = await ask.file_of(msg)
    if not data:
        await ask.retry(msg, state, ctx, "Нужен файл-архив до 20 МБ")
        return
    await _inspect(msg, state, str(save_upload(data)))


def save_upload(data: bytes) -> Path:
    """Присланный архив — в каталог загрузок бота (только root), прежние
    загрузки старше суток удаляются."""
    UPLOADS.mkdir(parents=True, exist_ok=True)
    os.chmod(UPLOADS, 0o700)
    for old in UPLOADS.iterdir():                      # прежние загрузки больше не нужны
        if time.time() - old.stat().st_mtime > 86400:
            old.unlink(missing_ok=True)
    path = UPLOADS / f"backup-{time.time_ns()}.tar.gz"
    path.write_bytes(data)
    os.chmod(path, 0o600)
    return path


async def _inspect(target: ui.Target, state: FSMContext, path: str) -> None:
    r = await api.call("backup", "inspect", path)
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, "Это не бэкап awg2"), ui.kb(ui.back("bk")))
        return
    d = r.data
    await state.update_data(restore={"path": path, "wgobf": bool(d.get("wgobf")),
                                     "tunnels": bool(d.get("tunnels")),
                                     "has_wgobf": bool(d.get("wgobf")), "has_tunnels": bool(d.get("tunnels"))})
    await _options(target, state)


async def _options(target: ui.Target, state: FSMContext) -> None:
    rs = (await state.get_data()).get("restore") or {}
    if not rs:
        await ui.render(target, "Бэкап не выбран.", ui.kb(ui.back("bk")))
        return
    lines = [f"<b>♻️ Восстановление</b>\n<code>{esc(os.path.basename(rs['path']))}</code>\n",
             "Сервер и клиенты восстанавливаются всегда — <b>текущий сервер будет заменён</b>; "
             "его awg0.conf сохраняется рядом.",
             "Туннели восстанавливаются выключенными — их включают вручную."]
    if rs["has_tunnels"]:
        lines.append("Туннели — настройки Xray, exit-нод, каскада и DNS.")
    await ui.render(target, "\n".join(lines), ui.kb(
        (f"{'✅' if rs['wgobf'] else '⬜️'} Обфускатор", act.data("opt", "wgobf")) if rs["has_wgobf"] else None,
        (f"{'✅' if rs['tunnels'] else '⬜️'} Туннели", act.data("opt", "tunnels")) if rs["has_tunnels"] else None,
        ui.Row(("♻️ Восстановить", act.data("go")), ui.back("bk", "✖️ Отмена"))))


@act("opt")
async def _opt(cb: CallbackQuery, state: FSMContext, key: str) -> None:
    rs = dict((await state.get_data()).get("restore") or {})
    if key in ("wgobf", "tunnels") and rs:
        rs[key] = not rs.get(key)
        await state.update_data(restore=rs)
    await _options(cb, state)


@act("go")
async def _go(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    rs = (await state.get_data()).get("restore") or {}
    if not rs:
        await show(cb, state)
        return
    await state.update_data(restore={})
    opts = [k for k in ("wgobf", "tunnels") if rs.get(k)]
    await jobs.start(cb, "Восстановление из бэкапа", "backup", "restore", rs["path"], *opts, back_to="bk")
