"""
monitor.py — фоновый мониторинг активности клиентов с маркером #ping в заметке.

Логика: уведомляем ОДИН раз при переходе клиента в офлайн (🔴) и один раз
при возвращении в онлайн (🟢, с длительностью отсутствия). Пока состояние не
изменилось — молчим.

🟢 отправляется только если по этому клиенту реально уходило 🔴. Иначе после
рестарта бота (когда офлайн-клиенты просто фиксируются, без уведомлений)
возвращение давало бы «зелёное» без парного «красного».

Состояние храним в JSON, чтобы переживать рестарт бота:
    {name: {"since": <unix-ts последней активности>, "notified": <bool>}}
"since" — момент, когда клиента видели в последний раз (last_handshake), от
него считается длительность отсутствия. "notified" — отправляли ли мы 🔴.
"""

from __future__ import annotations

import asyncio
import html
import json
import logging
import os
import time
from pathlib import Path

from aiogram.exceptions import (
    TelegramAPIError,
    TelegramForbiddenError,
    TelegramRetryAfter,
)

from . import core

log = logging.getLogger("awgbot.monitor")

STATE_FILE = os.environ.get("AWG_MON_STATE", "/var/lib/awg-bot/monitor_state.json")

# Порог «клиент офлайн». 5 минут, а не привычные 3 — сознательно.
# Клиентские конфиги идут с PersistentKeepalive = 25, из-за чего WireGuard
# переустанавливает handshake примерно раз в 2 минуты. Порог 3 минуты оставляет
# запас всего в один цикл: одна потеря пакета или смена NAT-порта — и приходит
# ложное 🔴. 5 минут дают запас в ~2.5 цикла. Для алерта о упавшем резервировании
# ложное срабатывание дороже, чем лишние 2 минуты задержки.
# Не путать с core.Peer.online (120 с) — там индикатор в списке, а не алерт.
OFFLINE_AFTER = int(os.environ.get("AWG_MON_OFFLINE_AFTER", 5 * 60))
CHECK_INTERVAL = 60             # как часто проверять (сек)


def _load_state() -> dict:
    """Читает состояние, переваривая формат старых версий."""
    try:
        raw = json.loads(Path(STATE_FILE).read_text())
    except Exception:
        return {}
    if not isinstance(raw, dict):
        return {}

    state: dict = {}
    for name, val in raw.items():
        if isinstance(val, dict):
            since = val.get("since")
            state[name] = {
                "since": int(since) if isinstance(since, (int, float)) else 0,
                "notified": bool(val.get("notified", True)),
            }
        elif val == "offline":
            # Старый формат {name: "offline"}: момент ухода неизвестен, поэтому
            # длительность в 🟢 не покажем. Считаем, что 🔴 было отправлено —
            # старый код записывал имя ровно в этом случае.
            state[name] = {"since": 0, "notified": True}
    return state


def _save_state(state: dict) -> None:
    try:
        Path(STATE_FILE).parent.mkdir(parents=True, exist_ok=True)
        Path(STATE_FILE).write_text(json.dumps(state))
    except OSError as e:
        log.warning("Не удалось сохранить состояние мониторинга: %s", e)


def _is_offline(p: core.Peer) -> bool:
    if not p.last_handshake:
        return True
    return (time.time() - p.last_handshake) >= OFFLINE_AFTER


async def monitor_loop(bot, admins_src) -> None:
    """
    Бесконечный цикл мониторинга. Запускается как фоновая asyncio-задача.

    admins_src — набор ID получателей либо функция, возвращающая такой набор.
    Функция нужна, чтобы приглашённый админ начал получать уведомления сразу,
    без перезапуска бота.
    """
    log.info("Мониторинг активности запущен (маркер %s, порог %d мин)",
             core.MONITOR_TAG, OFFLINE_AFTER // 60)
    state = _load_state()
    # Первый прогон без уведомлений — и 🔴, и 🟢. Фиксируем текущую картину,
    # чтобы на старте не завалить чат ни теми, кто офлайн прямо сейчас, ни
    # теми, кто вернулся, пока бот был выключен.
    primed = False

    while True:
        try:
            try:
                admin_ids = admins_src() if callable(admins_src) else admins_src
            except Exception as e:
                log.warning("Не смог получить список админов: %s", e)
                admin_ids = set()

            # 0) применяем истёкшие сроки (блокируем просроченных)
            try:
                blocked = await asyncio.to_thread(core.enforce_expirations)
                for nm in blocked:
                    await _notify_expired(bot, admin_ids, nm)
            except Exception as e:
                log.warning("enforce_expirations: %s", e)

            peers = await asyncio.to_thread(core.list_peers, True)
            monitored = [p for p in peers if p.monitored]

            for p in monitored:
                off = _is_offline(p)
                entry = state.get(p.name)

                if off and entry is None:
                    # ушёл в офлайн — запоминаем, когда его видели в последний раз
                    notified = False
                    if primed:
                        await _notify_offline(bot, admin_ids, p)
                        notified = True
                    state[p.name] = {
                        "since": p.last_handshake or int(time.time()),
                        "notified": notified,
                    }
                elif not off and entry is not None:
                    # вернулся онлайн — сбрасываем, чтобы при след. уходе уведомить
                    state.pop(p.name, None)
                    if primed and entry.get("notified"):
                        await _notify_back(bot, admin_ids, p, int(entry.get("since") or 0))

            # подчистим состояние от удалённых/размониторенных клиентов
            names = {p.name for p in monitored}
            for stale in [k for k in state if k not in names]:
                state.pop(stale, None)

            _save_state(state)
            primed = True
        except Exception as e:  # мониторинг не должен ронять бота
            log.exception("Ошибка в цикле мониторинга: %s", e)

        await asyncio.sleep(CHECK_INTERVAL)


async def _send(bot, admin_ids: set[int], text: str) -> None:
    """Рассылает уведомление админам, разбирая причины недоставки по типам.

    Раньше здесь был один `except Exception` на всё, и в логе оставалась строка
    без понятной причины. Разница существенная: заблокировавший бота админ —
    это навсегда (и лечится только с его стороны), а flood control — это
    «через N секунд можно», и алерт мониторинга стоит того, чтобы дождаться.
    """
    for uid in admin_ids:
        for attempt in (1, 2):
            try:
                await bot.send_message(uid, text)
                break
            except TelegramRetryAfter as e:
                if attempt == 2:
                    log.warning("Уведомление %s не ушло даже после ожидания", uid)
                    break
                # Ждём столько, сколько просит Telegram, и пробуем ещё раз.
                # Потолок на случай абсурдного значения: висеть в цикле
                # мониторинга дольше его периода нельзя.
                delay = min(int(e.retry_after) + 1, 60)
                log.warning("Flood control на %s: жду %s с", uid, delay)
                await asyncio.sleep(delay)
            except TelegramForbiddenError:
                log.warning("Админ %s заблокировал бота — уведомления ему не доходят", uid)
                break
            except TelegramAPIError as e:
                log.warning("Не смог отправить уведомление %s: %s", uid, e)
                break


async def _notify_offline(bot, admin_ids: set[int], p: core.Peer) -> None:
    last = core.fmt_ago(p.last_handshake) if p.last_handshake else "никогда"
    await _send(bot, admin_ids, (
        f"🔴 <b>Клиент офлайн</b>\n\n"
        f"👤 {html.escape(p.name)}\n"
        f"IP: <code>{html.escape(p.allowed_ips)}</code>\n"
        f"Последняя активность: {last}\n"
        f"Заметка: {html.escape(core.strip_monitor_tag(p.note) or '—')}"
    ))


async def _notify_back(bot, admin_ids: set[int], p: core.Peer, since: int) -> None:
    """🟢 при возвращении. since — момент последней активности перед уходом
    (0, если состояние приехало из старого формата и момент неизвестен)."""
    gone = ""
    if since:
        gone = f"Отсутствовал: {core.fmt_uptime(int(time.time()) - since)}\n"
    await _send(bot, admin_ids, (
        f"🟢 <b>Клиент снова онлайн</b>\n\n"
        f"👤 {html.escape(p.name)}\n"
        f"IP: <code>{html.escape(p.allowed_ips)}</code>\n"
        f"{gone}"
        f"Заметка: {html.escape(core.strip_monitor_tag(p.note) or '—')}"
    ))


async def _notify_expired(bot, admin_ids: set[int], name: str) -> None:
    await _send(bot, admin_ids, (
        f"⏳ <b>Срок истёк — клиент заблокирован</b>\n\n👤 {html.escape(name)}\n"
        "Доступ закрыт. Снять блокировку: карточка клиента → Срок → Бессрочно."
    ))
