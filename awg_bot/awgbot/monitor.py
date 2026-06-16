"""
monitor.py — фоновый мониторинг активности клиентов с маркером #ping в заметке.

Логика (по выбору пользователя): уведомляем ОДИН раз при переходе клиента
в офлайн. Пока он не вернётся онлайн, повторно не пишем. Когда вернётся —
сбрасываем флаг, чтобы при следующем уходе снова уведомить.

Состояние (кто уже помечен офлайн) храним в JSON, чтобы переживать рестарт бота.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from pathlib import Path

from . import core

log = logging.getLogger("awgbot.monitor")

STATE_FILE = os.environ.get("AWG_MON_STATE", "/var/lib/awg-bot/monitor_state.json")
OFFLINE_AFTER = 5 * 60          # секунд без handshake → считаем офлайн
CHECK_INTERVAL = 60             # как часто проверять (сек)


def _load_state() -> dict:
    try:
        return json.loads(Path(STATE_FILE).read_text())
    except Exception:
        return {}


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


async def monitor_loop(bot, admin_ids: set[int]) -> None:
    """Бесконечный цикл мониторинга. Запускается как фоновая asyncio-задача."""
    log.info("Мониторинг активности запущен (маркер %s, порог %d мин)",
             core.MONITOR_TAG, OFFLINE_AFTER // 60)
    state = _load_state()  # {name: "offline"} — кому уже отправили
    # первый прогон без уведомлений: фиксируем текущее состояние, чтобы не
    # завалить чат уведомлениями обо всех, кто офлайн прямо сейчас на старте.
    primed = False

    while True:
        try:
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
                was_notified = state.get(p.name) == "offline"

                if off and not was_notified:
                    state[p.name] = "offline"
                    if primed:
                        await _notify(bot, admin_ids, p)
                elif not off and was_notified:
                    # вернулся онлайн — сбрасываем, чтобы при след. уходе уведомить
                    state.pop(p.name, None)

            # подчистим состояние от удалённых/размониторенных клиентов
            names = {p.name for p in monitored}
            for stale in [k for k in state if k not in names]:
                state.pop(stale, None)

            _save_state(state)
            primed = True
        except Exception as e:  # мониторинг не должен ронять бота
            log.exception("Ошибка в цикле мониторинга: %s", e)

        await asyncio.sleep(CHECK_INTERVAL)


async def _notify(bot, admin_ids: set[int], p: core.Peer) -> None:
    last = core.fmt_ago(p.last_handshake) if p.last_handshake else "никогда"
    text = (
        f"🔴 <b>Клиент офлайн</b>\n\n"
        f"👤 {p.name}\n"
        f"IP: <code>{p.allowed_ips}</code>\n"
        f"Последняя активность: {last}\n"
        f"Заметка: {p.note or '—'}"
    )
    for uid in admin_ids:
        try:
            await bot.send_message(uid, text)
        except Exception as e:
            log.warning("Не смог отправить уведомление %s: %s", uid, e)


async def _notify_expired(bot, admin_ids: set[int], name: str) -> None:
    text = (f"⏳ <b>Срок истёк — клиент заблокирован</b>\n\n👤 {name}\n"
            "Доступ закрыт. Снять блокировку: карточка клиента → Срок → Бессрочно.")
    for uid in admin_ids:
        try:
            await bot.send_message(uid, text)
        except Exception as e:
            log.warning("Не смог отправить уведомление %s: %s", uid, e)
