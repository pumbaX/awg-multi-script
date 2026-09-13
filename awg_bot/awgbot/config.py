"""config.py — конфигурация бота.

Читает /etc/awg-bot.conf (тот же путь, что awg2 использует для уведомлений),
либо переменные окружения BOT_TOKEN / ADMIN_ID. Формат файла — простые KEY=VALUE:

    BOT_TOKEN=123456:ABC...
    ADMIN_ID=111111111
    # можно несколько через запятую: ADMIN_ID=111,222
    # прокси до Telegram API, если он блокируется у провайдера:
    # BOT_PROXY=socks5://127.0.0.1:10808
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from . import net

CONF_PATH = os.environ.get("AWG_BOT_CONF", "/etc/awg-bot.conf")


@dataclass
class Config:
    token: str
    admins: set[int] = field(default_factory=set)
    proxy: str = ""     # BOT_PROXY: прокси до Telegram API, пусто = напрямую


def _read_file(path: str) -> dict[str, str]:
    data: dict[str, str] = {}
    p = Path(path)
    if not p.is_file():
        return data
    try:
        text = p.read_text()
    except OSError as e:
        # Файл есть, а прочитать нельзя: чаще всего конфиг с токеном лежит с
        # правами root:root 600, а бота запустили не от root. Трейс на пол-экрана
        # тут ничего не объясняет, поэтому падаем с внятной строкой.
        raise SystemExit(
            f"{path} не читается ({e.strerror}). "
            "Запусти бота от пользователя, которому доступен конфиг, "
            "или передай BOT_TOKEN и ADMIN_ID переменными окружения."
        ) from e
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip().upper()] = v.strip().strip('"').strip("'")
    return data


def load_config() -> Config:
    fileconf = _read_file(CONF_PATH)
    token = os.environ.get("BOT_TOKEN") or fileconf.get("BOT_TOKEN", "")
    # ADMIN_ID — наше имя; ADMIN_CHAT_ID — имя из старого бота pumbaX (миграция).
    raw_admin = (os.environ.get("ADMIN_ID")
                 or fileconf.get("ADMIN_ID")
                 or fileconf.get("ADMIN_CHAT_ID", ""))

    if not token:
        raise SystemExit(
            f"BOT_TOKEN не задан. Укажи его в {CONF_PATH} или env BOT_TOKEN."
        )
    admins: set[int] = set()
    for part in raw_admin.replace(";", ",").split(","):
        part = part.strip()
        if part.isdigit():
            admins.add(int(part))
    if not admins:
        raise SystemExit(
            f"ADMIN_ID не задан. Укажи свой Telegram ID в {CONF_PATH} или env ADMIN_ID.\n"
            "Узнать ID можно у @userinfobot."
        )
    proxy = (os.environ.get("BOT_PROXY") or fileconf.get("BOT_PROXY", "")).strip()
    if proxy and not net.valid_proxy(proxy):
        raise SystemExit(
            f"BOT_PROXY='{proxy}' не похож на адрес прокси. "
            f"Ожидается схема из {', '.join(net.PROXY_SCHEMES)}, "
            "например socks5://127.0.0.1:10808."
        )

    return Config(token=token, admins=admins, proxy=proxy)
