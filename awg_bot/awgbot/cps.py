"""
cps.py — генерация I1 (CPS-мимикрия) тем же кодом, что и awg2.

Путь 1: не дублируем криптологику в боте, а извлекаем Python-генератор
из установленного /usr/local/bin/awg2 (переменная _CPS_GENERATOR='...')
и выполняем его. Так I1 всегда соответствует версии awg2 на сервере и
обновляется вместе со скриптом.

Контракт генератора (как в awg2):
    python3 -c "<код>" <profile> [<domain>] [--only-i1]
    profile ∈ {tls, dns, sip, quic}
    stdout: 1 строка на пакет; с --only-i1 — только I1 (первая строка).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess

AWG2_BIN = shutil.which("awg2") or "/usr/local/bin/awg2"

# профили, которые поддерживает CPS-генератор awg2
PROFILES = ("tls", "dns", "sip", "quic")

_cached_code: str | None = None
_cache_mtime: float = 0.0


def _extract_generator() -> str | None:
    """
    Достаёт тело _CPS_GENERATOR='...' из awg2. Кэшируется по mtime файла,
    чтобы переподхватывать новый генератор после обновления скрипта.
    """
    global _cached_code, _cache_mtime
    if not os.path.isfile(AWG2_BIN):
        return None
    try:
        mtime = os.path.getmtime(AWG2_BIN)
    except OSError:
        return None
    if _cached_code is not None and mtime == _cache_mtime:
        return _cached_code

    try:
        text = open(AWG2_BIN, encoding="utf-8", errors="replace").read()
    except OSError:
        return None

    # _CPS_GENERATOR='...многострочный python...'
    # значение в одинарных кавычках; берём до закрывающей одиночной кавычки,
    # стоящей в начале строки (как оформлено в awg2).
    m = re.search(r"_CPS_GENERATOR='\n(.*?)\n'\n", text, re.S)
    if not m:
        # запасной вариант: до строки, состоящей только из закрывающей кавычки
        m = re.search(r"_CPS_GENERATOR='(.*?)'\s*$", text, re.S | re.M)
    if not m:
        return None

    _cached_code = m.group(1)
    _cache_mtime = mtime
    return _cached_code


def available() -> bool:
    return _extract_generator() is not None


def gen_i1(profile: str, domain: str = "") -> str | None:
    """
    Возвращает строку I1 (например '<b 0x...>' или '<r 2><b 0x...>')
    для указанного профиля, либо None при сбое/недоступности.
    profile='basic' → None (без мимикрии).
    """
    if profile == "basic":
        return None
    if profile not in PROFILES:
        return None
    code = _extract_generator()
    if code is None:
        return None
    args = ["python3", "-c", code, profile]
    if domain:
        args.append(domain)
    args.append("--only-i1")
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if p.returncode != 0:
        return None
    # первая непустая строка — это I1
    for line in p.stdout.splitlines():
        if line.strip():
            return line.strip()
    return None


def gen_full(profile: str, domain: str = "") -> list[str]:
    """Полный набор I1..I5 (для будущего использования). Список строк."""
    if profile == "basic" or profile not in PROFILES:
        return []
    code = _extract_generator()
    if code is None:
        return []
    args = ["python3", "-c", code, profile]
    if domain:
        args.append(domain)
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []
    if p.returncode != 0:
        return []
    return [l.strip() for l in p.stdout.splitlines() if l.strip()]
