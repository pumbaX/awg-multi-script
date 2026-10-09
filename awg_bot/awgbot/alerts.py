"""alerts.py — уведомления о сервере и автобэкапы в Telegram.

Раз в CHECK_INTERVAL бот смотрит сводку awg2 и сам сервер и пишет
владельцам и админам, когда что-то случилось:

  iface   awg0 упал (две проверки подряд) и снова поднялся — с временем простоя;
  reboot  сервер перезагрузился (сменился boot_id);
  cert    сертификат Mini App скоро истечёт — значит, продление не сработало;
  disk    диск заполнен на DISK_WARN% (повтор — только после спада ниже DISK_OK%);
  update  вышла новая версия AWG Toolza — одной строкой, «Обновить» и «Что нового»;
  kernel  установлено ядро без модуля AWG — после перезагрузки VPN не поднимется.

Каждое событие — один раз, пока не сменится (новая версия, другое ядро).
Сроки и лимиты трафика клиентов сообщает таймер awg2: он работает и без бота.

Автобэкап: полный бэкап раз в день или неделю — файлом в чат, только
владельцам (в нём приватные ключи). На сервере остаются последние keep.

  alerts.json        настройки: выключенные уведомления, режим автобэкапа;
  alerts_state.json  что уже сообщено (ведёт только цикл);
  autobackup.json    последний автобэкап и его ошибка.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import ssl
import time
from pathlib import Path
from typing import Any

from aiogram import Bot
from aiogram.exceptions import TelegramAPIError, TelegramForbiddenError, TelegramRetryAfter
from aiogram.types import FSInputFile, InlineKeyboardMarkup

from . import access, api, store, ui
from .ui import esc

log = logging.getLogger("awgbot.alerts")

CONFIG = store.STATE_DIR / "alerts.json"
STATE = store.STATE_DIR / "alerts_state.json"
BACKUP_STATE = store.STATE_DIR / "autobackup.json"

CHECK_INTERVAL = int(os.environ.get("AWG_ALERTS_INTERVAL", 120))
IFACE_STRIKES = 2
DISK_WARN, DISK_OK = 90, 85
BOOT_ID = Path(os.environ.get("AWG_BOOT_ID", "/proc/sys/kernel/random/boot_id"))
CERT_FULL = Path(os.environ.get("AWG_CERT_FULL", "/etc/awg2/cert/fullchain.pem"))
DISK_PATH = os.environ.get("AWG_DISK_PATH", "/")
SEND_MAX = 49 * 1024 * 1024                     # документ бота — до 50 МБ

# id, подпись кнопки (полстроки в боте), полное название
KINDS = [("iface", "awg0 упал", "awg0 упал и поднялся"), ("reboot", "Перезагрузка", "Сервер перезагрузился"),
         ("update", "Новая версия", "Новая версия Тулзы"), ("kernel", "Ядро без AWG", "Ядро без модуля AWG"),
         ("cert", "Сертификат", "Сертификат Mini App истекает"), ("disk", f"Диск {DISK_WARN}%", f"Диск заполнен на {DISK_WARN}%")]
KIND_IDS = {k for k, _, _ in KINDS}
BACKUP_MODES = {"off": "выключен", "day": "ежедневно", "week": "еженедельно"}
BACKUP_PERIOD = {"day": 86400, "week": 7 * 86400}
BACKUP_KEEP = (3, 7, 14, 30)


# ── Настройки ─────────────────────────────────────────────
def config() -> dict[str, Any]:
    data = store.load(CONFIG)
    off = data.get("off") if isinstance(data.get("off"), list) else []
    bk = data.get("backup") if isinstance(data.get("backup"), dict) else {}
    mode = bk.get("mode") if bk.get("mode") in BACKUP_MODES else "off"
    keep = bk.get("keep") if bk.get("keep") in BACKUP_KEEP else 7
    return {"off": [k for k in off if isinstance(k, str)], "backup": {"mode": mode, "keep": keep}}


def enabled(kind: str) -> bool:
    return kind not in config()["off"]


def set_enabled(kind: str, on: bool) -> None:
    cfg = config()
    off = [k for k in cfg["off"] if k != kind] + ([] if on else [kind])
    store.save(CONFIG, {"off": off, "backup": cfg["backup"]})


def set_backup(mode: str | None = None, keep: int | None = None) -> None:
    """Включение автобэкапа (или смена режима) — первый бэкап на ближайшей
    проверке: сразу видно, что файлы до чата доходят."""
    cfg = config()
    bk = dict(cfg["backup"])
    if mode in BACKUP_MODES:
        if mode != bk["mode"] and mode != "off":
            store.save(BACKUP_STATE, {})
        bk["mode"] = mode
    if keep in BACKUP_KEEP:
        bk["keep"] = keep
    store.save(CONFIG, {"off": cfg["off"], "backup": bk})


def backup_info() -> dict[str, Any]:
    """last — когда бэкап последний раз удался; next — следующая попытка
    (после неудачи — повтор через час)."""
    st = store.load(BACKUP_STATE)
    bk = config()["backup"]
    last = int(st.get("last") or 0)
    slot = int(st.get("slot") or last)
    nxt = None
    if bk["mode"] in BACKUP_PERIOD:
        nxt = int(st.get("retry_at") or 0) or (slot + BACKUP_PERIOD[bk["mode"]] if slot else None)
    return {**bk, "last": last or None, "ok": bool(st.get("ok")), "error": str(st.get("error") or ""),
            "next": nxt}


def overview() -> dict[str, Any]:
    """Для экранов бота и панели."""
    off = config()["off"]
    return {"kinds": [{"id": k, "short": short, "label": label, "on": k not in off} for k, short, label in KINDS],
            "backup": backup_info(), "interval": CHECK_INTERVAL}


# ── Отправка ──────────────────────────────────────────────
async def _deliver(fn, uid: int) -> bool:                     # type: ignore[no-untyped-def]
    for attempt in (1, 2):
        try:
            await fn(uid)
            return True
        except TelegramRetryAfter as e:
            if attempt == 2:
                return False
            await asyncio.sleep(min(int(e.retry_after) + 1, 60))
        except TelegramForbiddenError:
            log.warning("%s заблокировал бота — уведомления ему не доходят", uid)
            return False
        except TelegramAPIError as e:
            log.warning("Уведомление %s не ушло: %s", uid, e)
            return False
    return False


async def notify(bot: Bot, text: str, markup: InlineKeyboardMarkup | None = None,
                 owner_markup: bool = False) -> None:
    """Владельцам и приглашённым админам. owner_markup — кнопка ведёт в раздел
    владельца: админу она ответила бы только «настраивает владелец»."""
    owners = access.owners()
    for uid in sorted(access.all_ids()):
        kb = markup if not owner_markup or uid in owners else None
        await _deliver(lambda u, kb=kb: bot.send_message(u, text, reply_markup=kb), uid)


# ── Проверки ──────────────────────────────────────────────
def _read(path: Path) -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def _uptime() -> int:
    try:
        return int(float(Path("/proc/uptime").read_text().split()[0]))
    except (OSError, ValueError, IndexError):
        return 0


def disk_pct() -> int:
    try:
        u = shutil.disk_usage(DISK_PATH)
    except OSError:
        return 0
    return int(u.used * 100 / u.total) if u.total else 0


def cert_dates() -> tuple[int, int] | None:
    """(выдан, истекает) сертификата Mini App; None — его нет."""
    if not CERT_FULL.is_file():
        return None
    try:
        info = ssl._ssl._test_decode_cert(str(CERT_FULL))      # type: ignore[attr-defined]
        return int(ssl.cert_time_to_seconds(info["notBefore"])), int(ssl.cert_time_to_seconds(info["notAfter"]))
    except (OSError, ValueError, KeyError, ssl.SSLError):
        return None


def update_text(d: dict[str, Any], upd: str) -> str:
    """Уведомление о новой версии — одна строка: в шторке телефона виден весь
    текст сообщения. Что вошло в релиз — за кнопкой «Что нового»."""
    beta = " бета" if d.get("channel") == "beta" else ""
    return f"🚀 AWG Toolza{beta}: есть обновление <b>{esc(upd)}</b>"


async def tick(bot: Bot, st: dict[str, Any]) -> bool:
    """Один проход. False — сводка awg2 не получена."""
    d = await api.data("status")
    if not isinstance(d, dict):
        return False
    now = int(time.time())
    host = esc(d.get("host") or "сервер")

    # Перезагрузка: boot_id меняется при каждой загрузке ядра
    boot = _read(BOOT_ID)
    if boot:
        if st.get("boot") and st["boot"] != boot and enabled("reboot"):
            s = d.get("server") or {}
            awg = ("🟢 awg0 работает" if s.get("up") else "🔴 awg0 не поднялся") if s.get("exists") else ""
            await notify(bot, f"🔄 <b>{host}</b> перезагрузился — работает {ui.fmt_dur(_uptime())}"
                              + (f"\n{awg}" if awg else ""),
                         None if not s.get("exists") or s.get("up") else ui.kb(("🛠 Починить", "srv:repair")))
        st["boot"] = boot

    # awg0: две проверки подряд — перезапуск из меню или бота не тревога
    s = d.get("server") or {}
    if s.get("exists") and not s.get("up"):
        st["down"] = int(st.get("down") or 0) + 1
        if st["down"] == 1:
            st["down_since"] = now
        if st["down"] == IFACE_STRIKES and enabled("iface"):
            await notify(bot, f"🔴 <b>{host}: awg0 не работает</b> — клиенты без связи.\n"
                              "Сервер → 🛠 Починить.", ui.kb(("🛠 Починить", "srv:repair")))
            st["down_sent"] = True
    else:
        # «Снова работает» — только если awg0 и правда поднят: сервер могли
        # удалить (сброс) — это не восстановление
        if st.get("down_sent") and s.get("exists") and s.get("up"):
            gone = ui.fmt_dur(now - int(st.get("down_since") or now))
            await notify(bot, f"🟢 <b>{host}: awg0 снова работает</b>\nПростой: около {gone}")
        for k in ("down", "down_since", "down_sent"):
            st.pop(k, None)

    # Новая версия: один раз на версию
    upd = d.get("update") or ""
    if upd and upd != st.get("update"):
        if enabled("update"):
            await notify(bot, update_text(d, upd),
                         ui.kb(ui.Row(("⬆️ Обновить", "upd:go"), ("📋 Что нового", "upd:notes"))))
        st["update"] = upd

    # Ядро без модуля: один раз на набор ядер
    gap = (d.get("components") or {}).get("kernel_gap") or ""
    if gap and gap != st.get("kernel") and enabled("kernel"):
        await notify(bot, f"⚠️ <b>{host}: ядро {esc(gap)} без модуля AWG</b>\n"
                          "Сервер загрузится в него после перезагрузки — и VPN не поднимется. "
                          "Пересобери модуль заранее.", ui.kb(("🧱 Пересобрать", "mod:rebuild")))
    st["kernel"] = gap

    # Диск
    pct = disk_pct()
    if pct >= DISK_WARN and not st.get("disk"):
        if enabled("disk"):
            await notify(bot, f"💽 <b>{host}: диск заполнен на {pct}%</b>\n"
                              "Когда место кончится, перестанут писаться конфиги, журналы и бэкапы.")
        st["disk"] = True
    elif pct and pct < DISK_OK:
        st.pop("disk", None)

    # Сертификат Mini App: на IP живёт ~6 дней (тревога за 2 дня), на домен — 90 (за 10)
    dates = cert_dates()
    if dates:
        issued, expires = dates
        threshold = 2 * 86400 if expires - issued < 10 * 86400 else 10 * 86400
        if expires - now < threshold and st.get("cert") != expires:
            if enabled("cert"):
                left = "истёк" if expires <= now else f"истекает через {ui.fmt_dur(expires - now)}"
                await notify(bot, f"🔐 <b>Сертификат Mini App {left}</b>\n"
                                  "Автопродление не сработало: Telegram-бот → 📱 Mini App → 🔐 На IP или 🌍 На домен…",
                             ui.kb(("📱 Mini App", "app")), owner_markup=True)
            st["cert"] = expires
    return True


# ── Автобэкап ─────────────────────────────────────────────
BACKUP_RETRY = 3600
BACKUP_UPLOAD_TIMEOUT = 300         # файл до 50 МБ: стандартных 60 с на медленном канале мало


async def _backup_failed(bot: Bot, st: dict[str, Any], now: int, error: str) -> str:
    """Неудача: время последнего удачного бэкапа остаётся, повтор — через час."""
    store.save(BACKUP_STATE, {**st, "ok": False, "error": error, "retry_at": now + BACKUP_RETRY})
    log.warning("Автобэкап не удался: %s", error)
    await notify(bot, f"⚠️ <b>Автобэкап не удался</b>\n{esc(error)}\nПовторю через час.")
    return "fail"


async def backup_due(bot: Bot, force: bool = False) -> str:
    """Бэкап, если подошёл срок. "done" — сделан и дошёл до владельцев,
    "busy" — идёт другая операция (попробую на следующей проверке),
    "fail" — не удался (повтор через час), "" — срок не подошёл."""
    bk = config()["backup"]
    if bk["mode"] not in BACKUP_PERIOD and not force:
        return ""
    period = BACKUP_PERIOD.get(bk["mode"], 86400)
    st = store.load(BACKUP_STATE)
    now = int(time.time())
    slot = int(st.get("slot") or st.get("last") or 0)
    # Часы уходили вперёд: «будущий» слот не ждём. До 300 с вперёд — законно:
    # бэкап делается на 300 с раньше слота, и следующий слот ложится чуть впереди
    if slot > now + 300:
        slot = 0
    if not force:
        retry = int(st.get("retry_at") or 0)
        if retry > now + BACKUP_RETRY:      # то же для повтора
            retry = 0
        if (retry and now < retry) or (not retry and now - slot < period - 300):
            return ""
    r = await api.call("backup", "create", "auto", bk["keep"], timeout=900)
    if not r.ok and r.rc == 75:
        return "busy"
    path = (r.data or {}).get("path") if r.ok and isinstance(r.data, dict) else None
    if not path or not os.path.isfile(path):
        return await _backup_failed(bot, st, now, r.message if not r.ok else "нет файла")
    size = os.path.getsize(path)
    when = time.strftime("%d.%m.%Y %H:%M")
    caption = (f"💾 <b>Автобэкап</b> · {when} · {ui.fmt_bytes(size)}\n"
               "В нём приватные ключи — храни как пароль. Восстановление: Бэкапы → Из файла.")
    sent = 0
    for uid in sorted(access.owners()):
        if size <= SEND_MAX:
            sent += await _deliver(lambda u: bot.send_document(u, FSInputFile(path), caption=caption,
                                                               request_timeout=BACKUP_UPLOAD_TIMEOUT), uid)
        else:
            sent += await _deliver(lambda u: bot.send_message(
                u, f"💾 Автобэкап {when}: {ui.fmt_bytes(size)} — больше 50 МБ, в чат не влезает.\n"
                   f"На сервере: <code>{esc(path)}</code>"), uid)
    if not sent:
        return await _backup_failed(bot, st, now, "файл не дошёл ни до одного владельца")
    # Расписание держится за слот, а не за момент проверки: иначе бэкап
    # каждый раз сдвигался на время до ближайшей проверки
    slot = slot + period if slot and not force and -300 <= now - slot - period < period else now
    store.save(BACKUP_STATE, {"last": now, "slot": slot, "ok": True, "error": "", "path": path})
    log.info("Автобэкап: %s (%s)", path, ui.fmt_bytes(size))
    return "done"


async def loop(bot: Bot) -> None:
    log.info("Уведомления о сервере: проверка раз в %d с", CHECK_INTERVAL)
    st = store.load(STATE)
    await asyncio.sleep(min(30, CHECK_INTERVAL))
    while True:
        try:
            if await tick(bot, st):
                store.save(STATE, st)
            await backup_due(bot)
        except asyncio.CancelledError:
            raise
        except Exception:                                   # noqa: BLE001
            log.exception("Ошибка в цикле уведомлений")
        await asyncio.sleep(CHECK_INTERVAL)
