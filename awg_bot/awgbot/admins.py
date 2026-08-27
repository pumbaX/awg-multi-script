"""admins.py — кто имеет доступ к боту: владельцы из конфига + приглашённые.

Два уровня, и это принципиально:

  • владелец (owner) — ID из ADMIN_ID в /etc/awg-bot.conf. Снять владельца
    из бота нельзя, только правкой конфига. Иначе приглашённый админ смог бы
    разжаловать пригласившего, а бот — это фактически root на сервере
    (бэкап с приватными ключами, рестарт, удаление бота);
  • админ (admin) — приглашённый, хранится здесь. Может всё то же самое,
    кроме управления списком админов.

Файл со списком держим отдельно от /etc/awg-bot.conf: там лежит токен, и
переписывать его на каждое добавление админа — лишний риск (его же бэкапят
awg-bot и awg2 при переустановке). Формат — тот же json в /var/lib/awg-bot,
что уже используют notes.json и monitor_state.json.

Приглашение — одноразовая deep-link вида t.me/<bot>?start=inv_<token>.
На диске лежит только sha256 токена: сам токен уходит в переписку, и по
файлу его восстановить нельзя. Живёт INVITE_TTL, сгорает при активации.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("awgbot.admins")

ADMINS_FILE = os.environ.get("AWG_ADMINS_FILE", "/var/lib/awg-bot/admins.json")

# Telegram user id — положительное число; верхняя граница с запасом (Bot API
# гарантирует влезание в 52 бита). Всё остальное — мусор или чужой chat_id.
MAX_USER_ID = 1 << 52
MAX_ADMINS = 20          # приглашённых, не считая владельцев
MAX_INVITES = 5          # одновременно живых приглашений
INVITE_TTL = 15 * 60     # секунд
INVITE_PREFIX = "inv_"


@dataclass(frozen=True)
class Admin:
    uid: int
    username: str = ""
    added_by: int = 0
    added_at: int = 0


# ───────────────────────── хранилище ─────────────────────────
def _empty() -> dict:
    return {"version": 1, "admins": {}, "invites": {}}


def _load() -> dict:
    try:
        data = json.loads(Path(ADMINS_FILE).read_text())
    except FileNotFoundError:
        return _empty()
    except Exception as e:
        # битый файл не должен закрывать владельцу доступ к боту: он читает
        # свой ID из конфига и работает дальше, а мы громко пишем в лог.
        log.error("Не читается %s (%s) — список приглашённых админов пуст", ADMINS_FILE, e)
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    data.setdefault("admins", {})
    data.setdefault("invites", {})
    if not isinstance(data["admins"], dict) or not isinstance(data["invites"], dict):
        return _empty()
    return data


def _save(data: dict) -> bool:
    """Атомарная запись 0600: временный файл рядом + os.replace."""
    path = Path(ADMINS_FILE)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".admins-", suffix=".tmp")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except Exception:
            Path(tmp).unlink(missing_ok=True)
            raise
        return True
    except OSError as e:
        log.error("Не сохранил %s: %s", ADMINS_FILE, e)
        return False


def _prune_invites(data: dict) -> bool:
    """Выкидывает просроченные приглашения. True — если что-то удалили."""
    now = int(time.time())
    dead = [k for k, v in data["invites"].items()
            if not isinstance(v, dict) or int(v.get("exp") or 0) <= now]
    for k in dead:
        data["invites"].pop(k, None)
    return bool(dead)


# ───────────────────────── админы ─────────────────────────
def valid_uid(uid: int) -> bool:
    return isinstance(uid, int) and 0 < uid < MAX_USER_ID


def invited_ids() -> set[int]:
    """ID приглашённых админов (без владельцев из конфига)."""
    out: set[int] = set()
    for k in _load()["admins"]:
        try:
            out.add(int(k))
        except (TypeError, ValueError):
            continue
    return out


def list_invited() -> list[Admin]:
    """Приглашённые админы, старые сверху."""
    out: list[Admin] = []
    for k, v in _load()["admins"].items():
        try:
            uid = int(k)
        except (TypeError, ValueError):
            continue
        v = v if isinstance(v, dict) else {}
        out.append(Admin(
            uid=uid,
            username=str(v.get("username") or "")[:64],
            added_by=int(v.get("added_by") or 0),
            added_at=int(v.get("added_at") or 0),
        ))
    out.sort(key=lambda a: a.added_at)
    return out


def add(uid: int, added_by: int, username: str = "") -> tuple[bool, str]:
    """Добавляет приглашённого админа. Владельцев сюда писать не нужно."""
    if not valid_uid(uid):
        return False, "Это не похоже на Telegram ID пользователя."
    data = _load()
    if str(uid) in data["admins"]:
        return False, "Этот пользователь уже админ."
    if len(data["admins"]) >= MAX_ADMINS:
        return False, f"Достигнут предел — {MAX_ADMINS} приглашённых админов."
    data["admins"][str(uid)] = {
        "username": str(username or "")[:64],
        "added_by": int(added_by),
        "added_at": int(time.time()),
    }
    _prune_invites(data)
    if not _save(data):
        return False, f"Не смог записать {ADMINS_FILE} — проверь права и место на диске."
    log.info("Админ добавлен: %s (%s), пригласил %s", uid, username or "без username", added_by)
    return True, "Админ добавлен."


def remove(uid: int, removed_by: int = 0) -> tuple[bool, str]:
    data = _load()
    if str(uid) not in data["admins"]:
        return False, "Такого админа в списке нет."
    data["admins"].pop(str(uid), None)
    if not _save(data):
        return False, f"Не смог записать {ADMINS_FILE} — проверь права и место на диске."
    log.info("Админ удалён: %s (удалил %s)", uid, removed_by)
    return True, "Доступ отозван."


# ───────────────────────── приглашения ─────────────────────────
def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create_invite(created_by: int) -> tuple[str, int] | tuple[None, str]:
    """
    Делает одноразовый токен приглашения.
    Возвращает (token, expires_at) либо (None, причина).
    """
    data = _load()
    _prune_invites(data)
    if len(data["invites"]) >= MAX_INVITES:
        return None, (f"Уже есть {MAX_INVITES} неиспользованных приглашений. "
                      "Отзови старые или дождись, пока они сгорят.")
    token = secrets.token_urlsafe(16)   # 22 символа [A-Za-z0-9_-] — влезает в deep-link
    exp = int(time.time()) + INVITE_TTL
    data["invites"][_hash(token)] = {"by": int(created_by), "exp": exp}
    if not _save(data):
        return None, f"Не смог записать {ADMINS_FILE} — проверь права и место на диске."
    log.info("Создано приглашение (действует до %s), автор %s", exp, created_by)
    return token, exp


def pending_invites() -> int:
    data = _load()
    if _prune_invites(data):
        _save(data)
    return len(data["invites"])


def revoke_invites() -> int:
    """Гасит все неиспользованные приглашения. Возвращает, сколько погасили."""
    data = _load()
    _prune_invites(data)
    n = len(data["invites"])
    if n:
        data["invites"] = {}
        if not _save(data):
            return 0
        log.info("Отозвано приглашений: %s", n)
    return n


def consume_invite(token: str, uid: int, username: str = "") -> tuple[bool, str]:
    """
    Активирует приглашение: проверяет токен, гасит его и заводит админа.
    Гашение и добавление — в одной записи файла, чтобы одна ссылка не
    сработала дважды при двух одновременных нажатиях.
    """
    if not valid_uid(uid):
        return False, "Некорректный Telegram ID."
    if not token or len(token) > 64:
        return False, "Ссылка недействительна."
    data = _load()
    _prune_invites(data)
    key = _hash(token)
    inv = data["invites"].pop(key, None)
    if inv is None:
        # сохраняем чистку просроченных, даже если токен не подошёл
        _save(data)
        return False, "Ссылка недействительна или уже использована."
    if str(uid) in data["admins"]:
        _save(data)
        return False, "Ты уже админ этого бота."
    if len(data["admins"]) >= MAX_ADMINS:
        _save(data)
        return False, f"Достигнут предел — {MAX_ADMINS} приглашённых админов."
    data["admins"][str(uid)] = {
        "username": str(username or "")[:64],
        "added_by": int(inv.get("by") or 0),
        "added_at": int(time.time()),
    }
    if not _save(data):
        return False, f"Не смог записать {ADMINS_FILE} — проверь права и место на диске."
    log.info("Приглашение активировано: %s (%s), пригласил %s",
             uid, username or "без username", inv.get("by"))
    return True, "Доступ выдан."
