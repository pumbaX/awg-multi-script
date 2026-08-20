"""
cps.py — генерация I1 (CPS-мимикрия) тем же кодом, что и awg2.

Путь 1: не дублируем криптологику в боте, а извлекаем Python-генератор
из установленного /usr/local/bin/awg2 (переменная _CPS_GENERATOR='...')
и выполняем его. Так I1 всегда соответствует версии awg2 на сервере и
обновляется вместе со скриптом.

Границы блока awg2 размечает якорями «# CPS_GENERATOR_BEGIN v1» /
«# CPS_GENERATOR_END v1» — это контракт между двумя файлами, а не догадка
по кавычкам. Для awg2 старее v0.7.9 остались прежние эвристики, а любой
извлечённый блок проверяется compile() перед запуском.

Контракт генератора (как в awg2):
    python3 -c "<код>" <profile> [<domain>] [--only-i1]
    profile ∈ {tls, dns, sip, quic}
    stdout: 1 строка на пакет; с --only-i1 — только I1 (первая строка).
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess

log = logging.getLogger("awgbot.cps")

AWG2_BIN = shutil.which("awg2") or "/usr/local/bin/awg2"

# профили, которые поддерживает CPS-генератор awg2
PROFILES = ("tls", "dns", "sip", "quic")

# Якоря, которые awg2 (v0.7.9+) ставит вокруг генератора специально для нас.
# Версия в маркере поднимается вместе с несовместимым изменением контракта
# вывода — тогда старый бот честно не найдёт блок вместо генерации мусора.
_MARKER_RE = re.compile(
    r"# CPS_GENERATOR_BEGIN v1\b.*?^_CPS_GENERATOR='\n(.*?)\n'\n# CPS_GENERATOR_END v1\b",
    re.S | re.M,
)

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

    # Порядок важен: сначала явные якоря awg2 (v0.7.9+), они не зависят от
    # оформления кавычек; затем — старые эвристики, чтобы бот продолжал
    # работать с уже установленными на серверах версиями awg2 без маркеров.
    m = _MARKER_RE.search(text)
    if not m:
        # _CPS_GENERATOR='...многострочный python...'
        # значение в одинарных кавычках; берём до закрывающей одиночной кавычки,
        # стоящей в начале строки (как оформлено в awg2).
        m = re.search(r"_CPS_GENERATOR='\n(.*?)\n'\n", text, re.S)
    if not m:
        # запасной вариант: до строки, состоящей только из закрывающей кавычки
        m = re.search(r"_CPS_GENERATOR='(.*?)'\s*$", text, re.S | re.M)
    if not m:
        log.warning("CPS: в %s не найден блок _CPS_GENERATOR — I1 генерироваться не будет", AWG2_BIN)
        return None

    code = m.group(1)
    # Захват мог зацепить лишнее (чужая кавычка, обрезанный файл). Выполнять
    # такой код нельзя: лучше остаться без мимикрии, чем скормить python мусор.
    try:
        compile(code, "<awg2:_CPS_GENERATOR>", "exec")
    except SyntaxError as exc:
        log.warning("CPS: блок из %s не компилируется (%s) — I1 отключён", AWG2_BIN, exc)
        return None

    _cached_code = code
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
    """
    Полный набор I1..I5 одним вызовом генератора. Нужен для серверов уровня
    «полный CPS»: клиент от бота должен получать столько же пакетов, сколько
    выдаёт awg2, иначе конфиги одного сервера различаются.
    """
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
