"""Бэкапы: создать и скачать, список на сервере, восстановление — в том
числе из присланного в чат архива. Пароль бэкапов: файлы, которые уходят с
сервера, awg2 шифрует им; зашифрованный бэкап без своего пароля на сервере
восстанавливается с паролем, присланным сообщением (оно сразу удаляется)."""

from __future__ import annotations

import contextlib
import os
import re
import time
from pathlib import Path

from aiogram import Bot, Router
from aiogram.exceptions import TelegramAPIError
from aiogram.fsm.context import FSMContext
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from .. import access, alerts, api, ask, jobs, store, ui
from ..ui import esc

router = Router()
act = ui.Actions(router, "bk")
abk = ui.Actions(router, "abk", owner="Автобэкап настраивает только владелец")
bkp = ui.Actions(router, "bkp", owner="Пароль бэкапов задаёт только владелец")

UPLOADS = store.STATE_DIR / "uploads"


def auto_line(b: dict) -> str:
    """«ежедневно · хранить 7 · последний 02.10 04:00»."""
    if b["mode"] == "off":
        return "выключен"
    last = time.strftime("%d.%m %H:%M", time.localtime(b["last"])) if b.get("last") else "ещё не было"
    tail = f" · ⚠️ {b['error']}" if b.get("error") else ""
    return f"{alerts.BACKUP_MODES[b['mode']]} · хранить {b['keep']} · последний {last}{tail}"


async def key_set() -> bool | None:
    """Задан ли пароль бэкапов; None — awg2 не ответил."""
    d = await api.data("backup", "key", "status")
    return bool(d.get("set")) if isinstance(d, dict) else None


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    owner = access.is_owner(cb.from_user.id)
    key = await key_set()
    key_line = ("🔐 Пароль: задан — файлы бэкапов с сервера зашифрованы" if key
                else "🔓 Пароль: не задан — файлы бэкапов с сервера не зашифрованы" if key is False else "")
    await ui.render(cb, "<b>💾 Бэкапы</b>\n\nПолный бэкап: сервер и клиенты, аккаунт WARP, WG + обфускатор, "
                        "настройки туннелей. Хранятся в <code>~/awg_backup</code> на сервере.\n\n"
                        "• Создать — бэкап сразу приходит сюда файлом\n"
                        "• Сохранённые — скачать или восстановить бэкап с сервера\n"
                        "• Из файла — восстановить из присланного архива\n\n"
                        f"🕒 Автобэкап: {esc(auto_line(alerts.backup_info()))}" + (f"\n{key_line}" if key_line else ""),
                    ui.kb(("💾 Создать", act.data("create")),
                          ("📂 Сохранённые", act.data("list")),
                          ("📤 Из файла", act.data("upload")),
                          ("🕒 Автобэкап", abk.data()) if owner else None,
                          ("🔐 Пароль", bkp.data()) if owner else None,
                          ui.back()))


# ── Пароль бэкапов ────────────────────────────────────────
@bkp()
async def _key(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await state.update_data(ctx={})          # «Отмена» на повторе пароля: первый ввод не хранить
    await key_screen(cb)


async def key_screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("backup", "key", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, "Пароль бэкапов"), ui.kb(ui.back("bk")))
        return
    on = bool(r.data.get("set"))
    it = int(r.data.get("iter") or 200000)
    lines = ["<b>🔐 Пароль бэкапов</b>",
             "Файлы бэкапов, которые уходят с сервера — сюда в чат, автобэкап, скачивание в панели, — "
             "шифруются этим паролем (AES-256). Бэкапы в <code>~/awg_backup</code> на сервере остаются как есть.",
             "На этом сервере зашифрованный бэкап восстанавливается без ввода пароля, на другом — бот его спросит.",
             f"На компьютере: <code>openssl enc -d -aes-256-cbc -pbkdf2 -iter {it} -md sha256 -in ФАЙЛ.enc "
             "-out бэкап.tar.gz</code>",
             "⚠️ Забудешь пароль — зашифрованные файлы не открыть.", ""]
    if note:
        lines += [note, ""]
    lines.append("🟢 Пароль задан" if on else "⚪️ Пароль не задан — файлы уходят без шифрования")
    await ui.render(target, "\n".join(lines), ui.kb(
        ("✏️ Сменить пароль" if on else "✏️ Задать пароль", bkp.data("set")),
        ("🗑 Убрать пароль", bkp.data("clr")) if on else None,
        ui.back("bk")))


KEY_PROMPT = ("Пришли пароль бэкапов: 8–128 символов — латиница, цифры, знаки, без пробелов по краям. "
              "Сообщение с паролем я сразу удалю.")
KEY_AGAIN = "Пришли пароль ещё раз — для проверки: опечатку в нём потом не исправить. Это сообщение тоже удалю."
KEY_RE = re.compile(r"[!-~](?:[ -~]*[!-~])?")


def key_problem(pw: str) -> str:
    """Та же проверка, что у awg2, — сразу, до повтора пароля."""
    if not 8 <= len(pw) <= 128:
        return "Пароль — от 8 до 128 символов"
    if not KEY_RE.fullmatch(pw):
        return "В пароле — только латиница, цифры и знаки, без пробелов по краям"
    return ""


async def _drop_secret(msg: Message, state: FSMContext) -> bool:
    """Удалить сообщение с паролем и забыть ввод; False — пишет не владелец."""
    with contextlib.suppress(TelegramAPIError):
        await msg.delete()
    await state.update_data(ctx={})
    return access.is_owner(msg.from_user.id if msg.from_user else 0)


@bkp("set")
async def _key_set(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "bk_key", KEY_PROMPT, bkp.data())


@ask.on("bk_key")
async def _key_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    pw = msg.text or ""
    if not await _drop_secret(msg, state):
        return
    why = key_problem(pw)
    if why:
        await ask.retry(msg, state, ctx, why)
        return
    # Ввод не виден (сообщение удалено) — повтор ловит опечатку
    await ask.ask(msg, state, "bk_key2", KEY_AGAIN, bkp.data(), first=pw)


@ask.on("bk_key2")
async def _key_again(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    pw, first = msg.text or "", str(ctx.get("first") or "")
    if not await _drop_secret(msg, state):
        return
    if not first or pw != first:
        await ask.ask(msg, state, "bk_key", f"⚠️ Пароли не совпали — начнём заново.\n\n{KEY_PROMPT}", bkp.data(),
                      _base=KEY_PROMPT)
        return
    r = await api.call("backup", "key", "set", stdin=pw + "\n")
    if not r.ok:
        await ask.ask(msg, state, "bk_key", f"⚠️ {esc(r.message)}\n\n{KEY_PROMPT}", bkp.data(), _base=KEY_PROMPT)
        return
    await key_screen(msg, "✅ Пароль задан. Запиши его — без него зашифрованные бэкапы не открыть.")


@bkp("clr")
async def _key_clear(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Убрать пароль? Новые файлы бэкапов будут уходить с сервера без шифрования. Уже "
                         "зашифрованные открываются только прежним паролем.",
                     ("🗑 Убрать", bkp.data("clrok")), bkp.data())


@bkp("clrok")
async def _key_clear_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("backup", "key", "clear")
    await key_screen(cb, "🗑 Пароль убран" if r.ok else ui.fail(r, "Пароль бэкапов"))


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


def caption(p: api.Packed) -> str:
    return ("🔐 Бэкап зашифрован паролем бэкапов" if p.encrypted
            else "💾 Бэкап — в нём приватные ключи, храни как пароль")


async def _send_backup(bot: Bot, chat_id: int, st: dict) -> None:
    path = (st.get("data") or {}).get("path")
    if not path:
        return
    p = await api.pack_backup(path)
    if isinstance(p, api.Packed):
        await bot.send_document(chat_id, BufferedInputFile(p.data, filename=p.name), caption=caption(p))
    else:
        await bot.send_message(chat_id, ui.fail(p, "Файл бэкапа не отправлен"))


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


@act("get")
async def _get(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    path = await ui.recall(state, "bk", idx)
    if not path or not os.path.exists(path):
        await cb.answer("Бэкапа уже нет", show_alert=True)
        return
    await cb.answer("Отправляю…")
    p = await api.pack_backup(path)
    if not isinstance(p, api.Packed):
        await ui.chat_of(cb).answer(ui.fail(p, "Файл бэкапа не отправлен"))
        return
    await ui.chat_of(cb).answer_document(BufferedInputFile(p.data, filename=p.name), caption=caption(p))


@act("rs")
async def _restore_saved(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    path = await ui.recall(state, "bk", idx)
    if path:
        await _inspect(cb, state, path)


# ── Восстановление ────────────────────────────────────────
@act("upload")
async def _upload(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "bk_file", "Пришли архив бэкапа (<code>.tar.gz</code> или зашифрованный "
                                        "<code>.enc</code>) — awg2 или прежнего бота.", "bk")


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
    ext = ".tar.gz.enc" if data[:8] == b"Salted__" else ".tar.gz"
    path = UPLOADS / f"backup-{time.time_ns()}{ext}"
    path.write_bytes(data)
    os.chmod(path, 0o600)
    return path


PASS_PROMPT = ("🔐 Бэкап зашифрован, а пароль бэкапов на этом сервере к нему не подходит. Пришли пароль, которым "
               "он зашифрован, — сообщение я сразу удалю.")


async def _inspect(target: ui.Target, state: FSMContext, path: str, pw: str = "") -> None:
    r = await api.call("backup", "inspect", path, *(["pass"] if pw else []), stdin=pw + "\n" if pw else None)
    if r.rc == 4 and isinstance(target, Message) and pw:
        await ask.ask(target, state, "bk_pass", f"⚠️ {esc(r.message)}\n\n{PASS_PROMPT}", "bk", _base=PASS_PROMPT,
                      path=path)
        return
    if r.rc == 4:
        await ask.ask(target, state, "bk_pass", PASS_PROMPT, "bk", path=path)
        return
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, "Это не бэкап awg2"), ui.kb(ui.back("bk")))
        return
    d = r.data
    # Пароль — только в памяти бота до запуска восстановления
    await state.update_data(restore={"path": path, "wgobf": bool(d.get("wgobf")),
                                     "tunnels": bool(d.get("tunnels")), "pw": pw,
                                     "has_wgobf": bool(d.get("wgobf")), "has_tunnels": bool(d.get("tunnels"))})
    await _options(target, state)


@ask.on("bk_pass")
async def _pass_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    pw = (msg.text or "").strip()
    with contextlib.suppress(TelegramAPIError):
        await msg.delete()
    if not pw:
        await ask.retry(msg, state, ctx, "Нужен пароль текстом")
        return
    await _inspect(msg, state, str(ctx.get("path") or ""), pw)


async def _options(target: ui.Target, state: FSMContext) -> None:
    rs = (await state.get_data()).get("restore") or {}
    if not rs:
        await ui.render(target, "Бэкап не выбран.", ui.kb(ui.back("bk")))
        return
    lines = [f"<b>♻️ Восстановление</b>\n<code>{esc(os.path.basename(rs['path']))}</code>"
             + (" 🔐" if rs.get("pw") else "") + "\n",
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
    pw = rs.get("pw") or ""
    await jobs.start(cb, "Восстановление из бэкапа", "backup", "restore", rs["path"], *opts, *(["pass"] if pw else []),
                     stdin=pw + "\n" if pw else None, back_to="bk")
