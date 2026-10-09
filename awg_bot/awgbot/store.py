"""store.py — состояние бота в /var/lib/awg-bot.

  notes.json          заметки клиентов {имя: текст}; маркер #ping в заметке
                      включает мониторинг активности (формат прежних версий);
  monitor_state.json  кто из наблюдаемых клиентов сейчас офлайн;
  jobs.json           незавершённые задачи awg2 и сообщения с их журналом —
                      после перезапуска бота он доводит их до итога;
  restart_notice.json экран, который бот поправит, когда перезапустится
                      (смена прокси, перезапуск из меню);
  admins.json         приглашённые админы (ведёт admins.py).
"""

from __future__ import annotations

import json
import logging
import os
import re
import tempfile
from pathlib import Path
from typing import Any

log = logging.getLogger("awgbot.store")

STATE_DIR = Path(os.environ.get("AWG_BOT_STATE", "/var/lib/awg-bot"))
NOTES = STATE_DIR / "notes.json"
MONITOR = STATE_DIR / "monitor_state.json"
JOBS = STATE_DIR / "jobs.json"
NOTICE = STATE_DIR / "restart_notice.json"
SETTINGS = STATE_DIR / "settings.json"
ICONS = STATE_DIR / "icons.json"

MONITOR_TAG = "#ping"
# Заметка и #ping клиента WG + обфускатора — под ключом «wgobf:имя»: имена у
# него свои и могут совпадать с клиентами AWG
WGOBF = "wgobf:"
NOTE_MAX = 200


def load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        log.error("Не читается %s: %s", path, e)
        return {}
    return data if isinstance(data, dict) else {}


def save(path: Path, data: dict) -> bool:
    """Атомарно, с правами 600: временный файл рядом и os.replace."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.stem}-", suffix=".tmp")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise
        return True
    except OSError as e:
        log.error("Не сохранил %s: %s", path, e)
        return False


# ── Заметки ───────────────────────────────────────────────
def notes() -> dict[str, str]:
    return {str(k): str(v) for k, v in load(NOTES).items()}


def note(name: str) -> str:
    return notes().get(name, "")


def set_note(name: str, text: str) -> None:
    data = notes()
    text = " ".join(text.split())[:NOTE_MAX]
    if text:
        data[name] = text
    else:
        data.pop(name, None)
    save(NOTES, data)


def rename_note(old: str, new: str) -> None:
    data = notes()
    if old in data:
        data[new] = data.pop(old)
        save(NOTES, data)


def drop_note(name: str) -> None:
    data = notes()
    if data.pop(name, None) is not None:
        save(NOTES, data)


def monitored(name: str) -> bool:
    return MONITOR_TAG in note(name).lower()


def strip_tag(text: str) -> str:
    """Заметка без служебного #ping."""
    return " ".join(re.sub(re.escape(MONITOR_TAG), " ", text or "", flags=re.I).split())


def set_monitored(name: str, on: bool) -> None:
    """Мониторинг включается маркером в заметке — как в прежних версиях."""
    base = strip_tag(note(name))
    if on:
        base = f"{base[:NOTE_MAX - len(MONITOR_TAG) - 1].rstrip()} {MONITOR_TAG}".strip()
    set_note(name, base)


# ── Настройки экранов (сортировка списка клиентов) ────────
def setting(key: str, default: str = "") -> str:
    return str(load(SETTINGS).get(key) or default)


def set_setting(key: str, value: str) -> None:
    data = load(SETTINGS)
    data[key] = value
    save(SETTINGS, data)


# ── Сообщение, которое бот поправит после своего перезапуска ──
def notice_set(chat: int, msg: int, text: str, back: str) -> None:
    save(NOTICE, {"chat": chat, "msg": msg, "text": text, "back": back})


def notice_pop() -> dict:
    data = load(NOTICE)
    NOTICE.unlink(missing_ok=True)
    return data


# ── Незавершённые задачи ──────────────────────────────────
def jobs() -> dict[str, dict[str, Any]]:
    return load(JOBS)


def job_add(job_id: str, info: dict[str, Any]) -> None:
    data = jobs()
    data[job_id] = info
    save(JOBS, data)


def job_done(job_id: str) -> None:
    data = jobs()
    if data.pop(job_id, None) is not None:
        save(JOBS, data)
