"""
wrapper.py — вызов интерактивного awg2 для тяжёлых/редких операций
(WARP, DNS, каскад, install/uninstall, бэкап, обновление).

Эти куски логики в awg2 — тысячи строк, переписывать их в боте смысла нет.
Вместо этого запускаем awg2 в pty и отвечаем на его меню-промпты по сценарию.

ВАЖНО: последовательности пунктов меню привязаны к конкретной версии awg2.
Все «сценарии» собраны здесь в одном месте — если меню скрипта изменится,
правится только этот файл. Базовый функционал (клиенты/статус/сроки) от этого
НЕ зависит — он работает через core.py напрямую.
"""

from __future__ import annotations

import os
import shutil

AWG2_BIN = shutil.which("awg2") or "/usr/local/bin/awg2"

try:
    import pexpect
    HAS_PEXPECT = True
except ImportError:
    HAS_PEXPECT = False


def available() -> bool:
    return HAS_PEXPECT and os.path.isfile(AWG2_BIN)


def run_menu_sequence(keys: list[str], timeout: int = 180) -> tuple[bool, str]:
    """
    Запускает awg2 и «нажимает» пункты меню по списку keys
    (например ['5', '1', '1', '0'] — Туннели → WARP → установить → выход).

    Скрипт после каждого действия перерисовывает меню и ждёт ввод через
    safe_read/read_choice. Мы шлём строки с \\n; в конце шлём '0' для выхода.
    Возвращаем (успех, полный лог вывода скрипта).
    """
    if not available():
        return False, "Недоступно: нет pexpect или не найден awg2"

    # awg2 рисует меню через clear/tput и читает safe_read. В pty без нормального
    # TERM скрипт падает на старте (set -euo pipefail). Даём xterm и размер окна.
    child = pexpect.spawn(
        AWG2_BIN, encoding="utf-8", timeout=timeout,
        dimensions=(40, 120),
        env={**os.environ, "TERM": "xterm-256color", "NO_COLOR": "1"},
    )
    log_buf: list[str] = []
    import time as _t
    try:
        for key in keys:
            # ждём приглашение к выбору; EOF/таймаут — не падаем, просто фиксируем
            try:
                child.expect([r"Выбор", r"\[\d+-\d+\]", r":\s*$"], timeout=12)
            except (pexpect.TIMEOUT, pexpect.EOF):
                log_buf.append(child.before or "")
                break
            log_buf.append(child.before or "")
            _t.sleep(0.3)
            child.sendline(key)
        # финальный сбор вывода
        try:
            child.expect(pexpect.EOF, timeout=timeout)
        except pexpect.TIMEOUT:
            try:
                child.sendline("0")
                child.expect(pexpect.EOF, timeout=20)
            except (pexpect.TIMEOUT, pexpect.EOF):
                child.terminate(force=True)
        except pexpect.EOF:
            pass
        log_buf.append(child.before or "")
    finally:
        if child.isalive():
            child.terminate(force=True)
    out = "".join(b for b in log_buf if b)
    if not out.strip():
        return False, ("awg2 не отдал вывод в неинтерактивном режиме. "
                       "Эту операцию надёжнее сделать в консоли: sudo awg2")
    return True, out


# Готовые сценарии (пункты меню awg2 v6.9.x).
# Сверь нумерацию с актуальным show_menu/show_submenu_* при обновлении скрипта.
SCENARIOS: dict[str, list[str]] = {
    # Главное меню: 5 = Туннели
    "warp_install":   ["5", "1", "1", "0", "0"],
    "warp_status":    ["5", "1", "2", "0", "0"],
    "warp_remove":    ["5", "1", "3", "y", "0", "0"],
    "dns_install":    ["5", "2", "1", "0", "0"],
    "dns_status":     ["5", "2", "2", "0", "0"],
    "dns_remove":     ["5", "2", "3", "y", "0", "0"],
}
