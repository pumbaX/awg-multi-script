"""api.py — вызовы awg2 api.

Бот ничего не знает о конфигах AWG, туннелях и systemd: всё делает awg2,
а бот зовёт его машинный интерфейс и показывает ответ. Ответ awg2 — одна
строка JSON {"ok", "rc", "data", "log", "error"}; log — тот же текст, что
видит пользователь меню awg2.

Долгие операции (сборка модуля, установка, обновления) идут задачами:
job_start возвращает id, job_status — состояние и новый кусок журнала.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import dataclass
from typing import Any

log = logging.getLogger("awgbot.api")

AWG2 = os.environ.get("AWG2_BIN", "/usr/local/bin/awg2")

# Быстрые команды отвечают за секунды; запас — на медленный диск и apt,
# который awg2 может позвать за недостающей утилитой.
DEFAULT_TIMEOUT = 180


@dataclass
class Result:
    ok: bool
    rc: int = 0
    data: Any = None
    log: str = ""
    error: str = ""

    @property
    def message(self) -> str:
        """Причина неудачи для пользователя."""
        return self.error or (self.log.strip().splitlines() or ["без подробностей"])[-1]


# Короткий кэш чтений: экраны бота и панели раз за разом просят одну и ту
# же сводку, а каждый вызов awg2 — это запуск bash и Python. Одинаковые
# одновременные запросы ждут один вызов; любая не-читающая команда (или
# задача) сбрасывает кэш, так что после изменений данные свежие.
CACHE_TTL = float(os.environ.get("AWG_API_CACHE_TTL", 5))
CACHED = {("status",), ("version",), ("server", "info"), ("tunnels", "status"), ("xray", "status"),
          ("exits", "status"), ("warp", "status"), ("dns", "status"), ("t2s", "status"), ("wgobf", "status"),
          ("clients", "list"), ("bot", "status"), ("cert", "status"), ("update", "status"), ("mimicry",),
          ("traffic", "daily"), ("backup", "list")}
_cache: dict[tuple[str, ...], tuple[float, "Result"]] = {}
_inflight: dict[tuple[str, ...], "asyncio.Task[Result]"] = {}
_gen = 0                            # растёт на каждой записи: чтение, начатое до неё, в кэш не ложится


# Чтения, которые не кэшируются, но и кэш не сбрасывают
READS = {("job", "status"), ("job", "list"), ("log",), ("module", "report"), ("module", "tags"),
         ("module", "check"), ("update", "check"), ("update", "changelog"), ("cert", "find"),
         ("diag", "status"), ("diag", "sniff-list"), ("tunnels", "clients"), ("wgobf", "clients"),
         ("xray", "diag"), ("cascade", "list"), ("module", "backups"), ("backup", "inspect"),
         ("bot", "proxy", "get"), ("bot", "webapp", "get"), ("server", "params"), ("web", "status"),
         ("traffic", "now"), ("antiscan", "status")}         # обзор панели спрашивает раз в 3 с — не запись, кэш не сбрасывает


def _cacheable(key: tuple[str, ...]) -> bool:
    return key[:2] in CACHED or key[:1] in CACHED


def _writes(key: tuple[str, ...]) -> bool:
    return not (_cacheable(key) or key[:1] in READS or key[:2] in READS or key[:3] in READS)


def invalidate() -> None:
    global _gen
    _gen += 1
    _cache.clear()
    # Чтения, начатые до записи, дождутся только те, кто их уже ждёт;
    # новые запросы идут заново и видят записанное
    _inflight.clear()


async def _cached_run(key: tuple[str, ...], args: tuple[Any, ...], timeout: float, gen: int) -> "Result":
    r = await _run(*args, timeout=timeout)
    if r.ok and gen == _gen:
        now = asyncio.get_running_loop().time()
        # Ключи с аргументами (traffic daily ИМЯ ДНЕЙ…) копились бы без конца
        for k in [k for k, (t, _) in _cache.items() if now - t >= CACHE_TTL]:
            del _cache[k]
        _cache[key] = (now, r)
    return r


def _inflight_done(key: tuple[str, ...], task: "asyncio.Task[Result]") -> None:
    if _inflight.get(key) is task:
        del _inflight[key]
    if not task.cancelled():
        task.exception()            # прочитано: без «Task exception was never retrieved»


async def call(*args: Any, stdin: str | bytes | None = None,
               timeout: float = DEFAULT_TIMEOUT, env: dict[str, str] | None = None) -> Result:
    """awg2 api АРГУМЕНТЫ... → Result. Не бросает исключений. Чтения из
    CACHED отдаются из кэша CACHE_TTL секунд, записи его сбрасывают.
    env — добавочные переменные окружения awg2 (вызов тогда мимо кэша)."""
    key = tuple(str(a) for a in args)
    if stdin is not None or env or not _cacheable(key) or CACHE_TTL <= 0:
        if _writes(key):
            invalidate()
        r = await _run(*args, stdin=stdin, timeout=timeout, env=env)
        if _writes(key):
            invalidate()                # и после: пока шла запись, кто-то мог прочитать старое
        return r
    hit = _cache.get(key)
    loop = asyncio.get_running_loop()
    if hit and loop.time() - hit[0] < CACHE_TTL:
        return hit[1]
    # Общий вызов — отдельная задача: отмена одного из ждущих (закрыли экран,
    # тайм-аут обработчика) не отменяет его остальным — раньше CancelledError
    # доставался всем, вплоть до цикла уведомлений
    task = _inflight.get(key)
    if task is None:
        task = asyncio.ensure_future(_cached_run(key, args, timeout, _gen))
        _inflight[key] = task
        task.add_done_callback(lambda t, k=key: _inflight_done(k, t))
    return await asyncio.shield(task)


async def _run(*args: Any, stdin: str | bytes | None = None,
               timeout: float = DEFAULT_TIMEOUT, env: dict[str, str] | None = None) -> Result:
    argv = [AWG2, "api", *(str(a) for a in args)]
    data = stdin.encode() if isinstance(stdin, str) else stdin
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE if data is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env={**os.environ, **env} if env else None)
    except FileNotFoundError:
        return Result(False, 127, error=f"awg2 не найден ({AWG2}) — установи AWG Toolza")
    except OSError as e:
        return Result(False, 126, error=f"awg2 не запускается: {e}")
    try:
        out, err = await asyncio.wait_for(proc.communicate(data), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        log.warning("awg2 api %s: нет ответа за %s с", " ".join(argv[2:4]), timeout)
        return Result(False, 124, error=f"awg2 не ответил за {int(timeout)} с")
    lines = out.decode(errors="replace").strip().splitlines()
    try:
        env = json.loads(lines[-1])
    except (IndexError, ValueError):
        tail = (out + err).decode(errors="replace").strip()[-500:]
        log.warning("awg2 api %s: ответ не JSON (rc=%s): %s", args[:2], proc.returncode, tail)
        if "нужен root" in tail:
            return Result(False, proc.returncode or 1, error="Бот запущен не от root — awg2 ему недоступен")
        if "api" in tail and ("Неизвестный аргумент" in tail or "--help" in tail):
            return Result(False, proc.returncode or 1,
                          error="Установленный awg2 не знает команду api — обнови AWG Toolza")
        return Result(False, proc.returncode or 1, log=tail, error="awg2 ответил не JSON")
    return Result(bool(env.get("ok")), int(env.get("rc") or 0), env.get("data"),
                  env.get("log") or "", env.get("error") or "")


async def data(*args: Any, default: Any = None, **kw: Any) -> Any:
    """Только data успешного ответа, иначе default."""
    r = await call(*args, **kw)
    return r.data if r.ok and r.data is not None else default


async def job_start(*args: Any, stdin: str | bytes | None = None) -> Result:
    """Запуск задачи. data.id — её номер."""
    invalidate()
    return await call("job", "start", *args, stdin=stdin, timeout=60)


async def job_status(job_id: str, offset: int = 0) -> Result:
    r = await call("job", "status", job_id, offset, timeout=60)
    if isinstance(r.data, dict) and r.data.get("state") != "running":
        invalidate()                    # задача что-то поменяла — экраны после неё читают заново
    return r
