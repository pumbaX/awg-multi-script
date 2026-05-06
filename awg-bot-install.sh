#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# AWG Toolza Bot — менеджер
# Меню: установка / удаление / обновление / логи / статус / перезапуск
# Использование: sudo bash awg-bot-install.sh
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Константы ─────────────────────────────────────────────────────────────────
BOT_PY="/usr/local/bin/awg-bot.py"
BOT_CONF="/etc/awg-bot.conf"
BOT_SERVICE="/etc/systemd/system/awg-bot.service"
BOT_LOG="/var/log/awg-bot.log"
SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"

# ── Цвета ─────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
C='\033[0;36m'; W='\033[1;37m'; D='\033[2;37m'; M='\033[0;35m'; N='\033[0m'

ok()   { echo -e "  ${G}✓${N} $*"; }
err()  { echo -e "  ${R}✗${N} $*"; }
info() { echo -e "  ${C}→${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
hdr()  { echo -e "\n${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; \
          echo -e "  ${W}$*${N}"; \
          echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }

# ── Проверка root ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { err "Нужен root: sudo bash $0"; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# Определение состояния бота
# ══════════════════════════════════════════════════════════════════════════════
bot_is_installed() {
  [[ -f "$BOT_PY" || -f "$BOT_SERVICE" || -f "$BOT_CONF" ]]
}

bot_is_running() {
  systemctl is-active --quiet awg-bot 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# Функция: УДАЛЕНИЕ бота
# ══════════════════════════════════════════════════════════════════════════════
do_uninstall_bot() {
  hdr "Удаление AWG Toolza Bot"
  echo ""
  if ! bot_is_installed; then
    warn "Бот не установлен"
    return 0
  fi

  warn "Будет удалено:"
  echo -e "  ${R}—${N} $BOT_PY"
  echo -e "  ${R}—${N} $BOT_SERVICE"
  echo -e "  ${R}—${N} $BOT_CONF (токен и chat_id)"
  echo ""
  echo -e "${G}  Сохраняется:${N}"
  echo -e "  ${G}✓${N} $BOT_LOG (история действий)"
  echo ""

  read -rp "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")" CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    warn "Отменено"
    return 0
  fi

  info "Останавливаю сервис..."
  systemctl stop awg-bot 2>/dev/null    || true
  systemctl disable awg-bot 2>/dev/null || true

  info "Удаляю файлы..."
  rm -f "$BOT_SERVICE" "$BOT_PY" "$BOT_CONF"
  systemctl daemon-reload
  ok "Бот удалён"
}

# ══════════════════════════════════════════════════════════════════════════════
# Функция: ЛОГИ бота
# ══════════════════════════════════════════════════════════════════════════════
do_logs() {
  hdr "Логи AWG Toolza Bot"
  echo ""
  if [[ ! -f "$BOT_LOG" ]]; then
    warn "Лог-файл не найден: $BOT_LOG"
    return 0
  fi
  info "Последние 50 строк ($BOT_LOG):"
  echo ""
  tail -50 "$BOT_LOG" 2>/dev/null || warn "Не удалось прочитать"
  echo ""
  info "Для live-просмотра: ${W}sudo tail -f $BOT_LOG${N}"
  info "Через journalctl:    ${W}sudo journalctl -u awg-bot -f${N}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Функция: СТАТУС бота
# ══════════════════════════════════════════════════════════════════════════════
do_status() {
  hdr "Статус AWG Toolza Bot"
  echo ""
  if ! bot_is_installed; then
    warn "Бот не установлен"
    return 0
  fi

  if [[ -f "$BOT_PY" ]];      then ok  "Скрипт:    $BOT_PY"; else err "Скрипт:    отсутствует"; fi
  if [[ -f "$BOT_CONF" ]];    then ok  "Конфиг:    $BOT_CONF"; else err "Конфиг:    отсутствует"; fi
  if [[ -f "$BOT_SERVICE" ]]; then ok  "Service:   $BOT_SERVICE"; else err "Service:   отсутствует"; fi

  if bot_is_running; then
    ok "Сервис:    работает"
    local since
    since=$(systemctl show awg-bot --property=ActiveEnterTimestamp --value 2>/dev/null || echo "—")
    info "Запущен:   $since"
  else
    warn "Сервис:    не запущен"
  fi

  if systemctl is-enabled --quiet awg-bot 2>/dev/null; then
    ok "Автозапуск: включён"
  else
    warn "Автозапуск: выключен"
  fi

  echo ""
  if [[ -f "$BOT_LOG" ]]; then
    local size
    size=$(du -h "$BOT_LOG" 2>/dev/null | awk '{print $1}')
    info "Лог:       $BOT_LOG ($size)"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Функция: ПЕРЕЗАПУСК бота
# ══════════════════════════════════════════════════════════════════════════════
do_restart() {
  hdr "Перезапуск AWG Toolza Bot"
  echo ""
  if ! bot_is_installed; then
    err "Бот не установлен"
    return 1
  fi

  info "Перезапускаю сервис..."
  if systemctl restart awg-bot; then
    sleep 1
    if bot_is_running; then
      ok "Сервис перезапущен и работает"
    else
      err "Сервис не запустился"
      info "Проверь логи: ${W}sudo tail -50 $BOT_LOG${N}"
    fi
  else
    err "Не удалось перезапустить"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Функция: ОБНОВЛЕНИЕ бота
# Сохраняет конфиг (токен/chat_id), переустанавливает только Python-код и unit
# ══════════════════════════════════════════════════════════════════════════════
do_update_bot() {
  hdr "Обновление AWG Toolza Bot"
  echo ""
  if ! bot_is_installed; then
    err "Бот не установлен. Выбери пункт 1 — Установить"
    return 1
  fi

  if [[ ! -f "$BOT_CONF" ]]; then
    err "Конфиг не найден: $BOT_CONF"
    err "Используй пункт 1 — Установить (с нуля)"
    return 1
  fi

  info "Сохраняю конфиг (токен и chat_id будут переиспользованы)..."
  ok "Конфиг найден: $BOT_CONF"

  # Парсим старые значения для переустановки
  OLD_TOKEN=$(grep -E '^BOT_TOKEN=' "$BOT_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  OLD_CHAT_ID=$(grep -E '^ADMIN_CHAT_ID=' "$BOT_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")

  if [[ -z "$OLD_TOKEN" || -z "$OLD_CHAT_ID" ]]; then
    err "В конфиге нет токена или chat_id. Используй пункт 1 — Установить"
    return 1
  fi

  info "Останавливаю сервис..."
  systemctl stop awg-bot 2>/dev/null || true

  info "Обновляю файлы бота (конфиг сохраняется)..."

  # Используем сохранённые значения автоматически
  BOT_TOKEN="$OLD_TOKEN"
  ADMIN_CHAT_ID="$OLD_CHAT_ID"
  SKIP_DEPS=1   # зависимости уже установлены
  SKIP_TOKEN_PROMPT=1
  SKIP_TEST_MSG=1

  do_install_bot

  ok "Обновление завершено"
}

# ══════════════════════════════════════════════════════════════════════════════
# Функция: УСТАНОВКА бота (тело установки)
# ══════════════════════════════════════════════════════════════════════════════
do_install_bot() {
  hdr "AWG Toolza Bot — установщик"


# ── Шаг 1: Проверка AWG Toolza ────────────────────────────────────────────────
echo ""
info "Проверяю AWG Toolza..."
if [[ ! -f "$SERVER_CONF" ]]; then
  err "Серверный конфиг не найден: $SERVER_CONF"
  err "Сначала установи и настрой AWG Toolza (sudo awg2 → пункт 2)"
  exit 1
fi
if ! command -v awg &>/dev/null; then
  err "awg не найден — установи AmneziaWG (sudo awg2 → пункт 1)"
  exit 1
fi
ok "AWG Toolza найден"

# ── Шаг 2: Зависимости ───────────────────────────────────────────────────────
echo ""
info "Устанавливаю зависимости..."

apt-get update -qq 2>/dev/null || true
apt-get install -y -qq python3 python3-pip qrencode 2>/dev/null || {
  err "Ошибка apt-get. Проверь интернет."; exit 1
}
ok "python3, pip, qrencode установлены"

info "Устанавливаю python-telegram-bot..."
pip3 install "python-telegram-bot>=20" --break-system-packages -q 2>/dev/null || \
  pip3 install "python-telegram-bot>=20" -q 2>/dev/null || {
  err "Ошибка pip. Попробуй вручную: pip3 install python-telegram-bot"
  exit 1
}
PTB_VER=$(python3 -c "import telegram; print(telegram.__version__)" 2>/dev/null || echo "?")
ok "python-telegram-bot $PTB_VER установлен"

# ── Шаг 3: Инструкция — получение токена ─────────────────────────────────────
if [[ "${SKIP_TOKEN_PROMPT:-0}" != "1" ]]; then
echo ""
hdr "Шаг 1 из 2: Создай бота в Telegram"
cat << 'MANUAL'

  Если бот уже создан — пропусти этот шаг.

  1. Открой Telegram и найди @BotFather
  2. Отправь команду: /newbot
  3. Введи название бота (например: AWG Toolza)
  4. Введи username бота (например: my_awg_toolza_bot)
     — должен заканчиваться на "bot"
  5. BotFather пришлёт токен вида:
     1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

  Скопируй токен — он понадобится сейчас.

MANUAL

read -rp "$(echo -e "  ${C}Вставь токен бота: ${N}")" BOT_TOKEN

# Валидация токена — формат: digits:string
if ! echo "$BOT_TOKEN" | grep -qP '^\d+:[A-Za-z0-9_-]{35,}$'; then
  err "Неверный формат токена. Ожидается: 1234567890:AAxxxxx..."
  err "Проверь и запусти установщик снова."
  exit 1
fi
ok "Токен принят"

# Проверяем токен через Telegram API
info "Проверяю токен через Telegram API..."
API_RESP=$(curl -sf "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || echo "")
if echo "$API_RESP" | grep -q '"ok":true'; then
  BOT_USERNAME=$(echo "$API_RESP" | grep -oP '"username":"\K[^"]+')
  ok "Бот найден: @$BOT_USERNAME"
else
  err "Токен недействителен или нет интернета."
  err "Ответ API: $API_RESP"
  exit 1
fi
else
  info "Использую сохранённый токен"
fi

# ── Шаг 4: Инструкция — получение chat_id ────────────────────────────────────
if [[ "${SKIP_TOKEN_PROMPT:-0}" != "1" ]]; then
echo ""
hdr "Шаг 2 из 2: Узнай свой Telegram chat_id"
cat << 'MANUAL'

  1. Открой Telegram и найди @userinfobot
  2. Отправь ему любое сообщение (например: /start)
  3. Он ответит твоим ID вида: Id: 123456789

  Это твой chat_id — только ты сможешь управлять ботом.

MANUAL

read -rp "$(echo -e "  ${C}Вставь свой chat_id: ${N}")" ADMIN_CHAT_ID

# Валидация chat_id — только цифры (может быть отрицательным для групп)
if ! echo "$ADMIN_CHAT_ID" | grep -qP '^-?\d+$'; then
  err "Неверный chat_id. Должно быть число вида 123456789"
  exit 1
fi
ok "chat_id принят: $ADMIN_CHAT_ID"
else
  info "Использую сохранённый chat_id: $ADMIN_CHAT_ID"
fi

# Тест — отправим приветственное сообщение
if [[ "${SKIP_TEST_MSG:-0}" != "1" ]]; then
info "Отправляю тестовое сообщение..."
TEST_RESP=$(curl -sf \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d "chat_id=${ADMIN_CHAT_ID}" \
  --data-urlencode "text=🛡 AWG Toolza Bot установлен!

Отправь /start чтобы открыть меню управления." \
  2>/dev/null || echo "")
if echo "$TEST_RESP" | grep -q '"ok":true'; then
  ok "Тестовое сообщение отправлено — проверь Telegram!"
else
  warn "Не удалось отправить тест. Возможно chat_id неверный."
  warn "Продолжаем установку, но проверь chat_id потом."
fi
fi

# ── Шаг 5: Сохраняем конфиг ──────────────────────────────────────────────────
echo ""
info "Сохраняю конфиг в $BOT_CONF..."

# Если конфиг уже есть — бекап
if [[ -f "$BOT_CONF" ]]; then
  cp "$BOT_CONF" "${BOT_CONF}.bak.$(date +%s)"
  warn "Старый конфиг сохранён как ${BOT_CONF}.bak.*"
fi

cat > "$BOT_CONF" << EOF
# AWG Toolza Bot — конфиг
# Создан: $(date '+%Y-%m-%d %H:%M:%S')
BOT_TOKEN="${BOT_TOKEN}"
ADMIN_CHAT_ID="${ADMIN_CHAT_ID}"
EOF

chmod 600 "$BOT_CONF"
ok "Конфиг сохранён (права 600)"

# ── Шаг 6: Записываем Python бот ─────────────────────────────────────────────
echo ""
info "Устанавливаю бот в $BOT_PY..."

cat > "$BOT_PY" << 'PYEOF'
#!/usr/bin/env python3
"""
AWG Toolza Bot — Telegram управление AmneziaWG сервером
Конфиг: /etc/awg-bot.conf

Улучшения по образцу Go-бота (3x-ui):
  - Кэширование статуса с TTL (StatusCache / ServerStatsCache)
  - Worker pool через asyncio.Semaphore (ограничение параллельных обработчиков)
  - Единый answerCallback со switch-like диспетчером вместо if-elif цепочки
  - Клавиатуры вынесены в класс Keyboards
  - auth-декоратор с functools.wraps
"""

import asyncio
import fcntl
import html as _html
import logging
import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass
from functools import wraps
from pathlib import Path
from typing import Optional

from telegram import (
    BotCommand, InlineKeyboardButton, InlineKeyboardMarkup,
    InputFile, ReplyKeyboardMarkup, Update,
)
from telegram.constants import ParseMode
from telegram.ext import (
    Application, CallbackQueryHandler, CommandHandler,
    ContextTypes, ConversationHandler, MessageHandler, filters,
)

# ── Конфиг ────────────────────────────────────────────────────────────────────
CONFIG_FILE  = "/etc/awg-bot.conf"
SERVER_CONF  = "/etc/amnezia/amneziawg/awg0.conf"
CLIENTS_GLOB = "/root/*_awg2.conf"
AWG_IFACE    = "awg0"
LOG_FILE     = "/var/log/awg-bot.log"
LOCK_FILE    = "/run/awg-bot.lock"   # межпроцессный лок для add_client

# WARP интеграция (awg2.sh устанавливает wgcf и ведёт список peer'ов через WARP)
WARP_IFACE   = "warp0"
WARP_PEERS   = "/etc/wgcf/peers.list"

ADD_NAME, ADD_PROFILE = range(2)

# Asyncio-примитивы создаются в main() — после старта event loop
_add_client_lock: Optional[asyncio.Lock] = None
WORKER_POOL: Optional[asyncio.Semaphore] = None

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    level=logging.INFO,
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()],
)
log = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════════════
# Кэш (аналог statusCache / serverStatsCache в Go)
# ══════════════════════════════════════════════════════════════════════════════

@dataclass
class _CacheEntry:
    """Простой TTL-кэш. В CPython присваивание ссылок атомарно (GIL),
    поэтому отдельный лок для get/set/invalidate не требуется.
    Если значение и timestamp обновляются раздельно, в худшем случае
    можно получить stale data на ~1 cycle — приемлемо для статистики.
    """
    data: object = None
    timestamp: float = 0.0

    def get(self, ttl: float):
        """Вернуть данные если они не старше ttl секунд, иначе None."""
        ts = self.timestamp
        d  = self.data
        if d is not None and (time.time() - ts) < ttl:
            return d
        return None

    def set(self, data):
        # порядок важен: сначала data, потом timestamp
        self.data = data
        self.timestamp = time.time()

    def invalidate(self):
        self.data = None
        self.timestamp = 0.0


# TTL: статус сервера — 5 сек, статистика пиров — 10 сек
_status_cache      = _CacheEntry()   # get_server_info()   TTL=5s
_live_stats_cache  = _CacheEntry()   # get_live_stats()    TTL=10s
_clients_cache     = _CacheEntry()   # get_clients()       TTL=30s

STATUS_TTL     = 5.0
LIVE_STATS_TTL = 10.0
CLIENTS_TTL    = 30.0


# ══════════════════════════════════════════════════════════════════════════════
# Утилиты
# ══════════════════════════════════════════════════════════════════════════════

def load_config() -> dict:
    cfg = {}
    for line in Path(CONFIG_FILE).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def run(cmd: list, input_str: Optional[str] = None) -> tuple:
    r = subprocess.run(cmd, capture_output=True, text=True, input=input_str, timeout=30)
    return r.returncode, r.stdout, r.stderr


def get_clients() -> list:
    """Список клиентов с кэшированием на 30 секунд."""
    cached = _clients_cache.get(CLIENTS_TTL)
    if cached is not None:
        return cached

    import glob as _glob
    clients = []
    if not Path(SERVER_CONF).exists():
        return clients

    name_map = {}
    for fpath in _glob.glob(CLIENTS_GLOB):
        fname = Path(fpath).stem.replace("_awg2", "")
        content = Path(fpath).read_text()
        for line in content.splitlines():
            if line.startswith("PrivateKey"):
                priv = line.split("=", 1)[1].strip()
                rc, pub, _ = run(["awg", "pubkey"], input_str=priv)
                if rc == 0:
                    name_map[pub.strip()] = (fname, fpath)
                break

    content = Path(SERVER_CONF).read_text()
    for peer in re.split(r"\[Peer\]", content)[1:]:
        pk_m = re.search(r"PublicKey\s*=\s*(.+)", peer)
        ip_m = re.search(r"AllowedIPs\s*=\s*(.+)", peer)
        cm_m = re.search(r"#\s*(.+)", peer)
        if not pk_m:
            continue
        pk   = pk_m.group(1).strip()
        ip   = ip_m.group(1).strip() if ip_m else "?"
        comment = cm_m.group(1).strip() if cm_m else ""
        name, fpath = name_map.get(pk, (comment or pk[:8], ""))
        clients.append({"name": name, "ip": ip, "pubkey": pk, "file": fpath})

    _clients_cache.set(clients)
    return clients


def get_live_stats() -> dict:
    """Статистика пиров с кэшированием на 10 секунд."""
    cached = _live_stats_cache.get(LIVE_STATS_TTL)
    if cached is not None:
        return cached

    rc, out, _ = run(["awg", "show", AWG_IFACE])
    if rc != 0:
        return {}

    stats = {}
    peer  = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("peer:"):
            peer = line.split(":", 1)[1].strip()
            stats[peer] = {"last_hs": 0, "rx": "—", "tx": "—"}
        elif peer:
            if "latest handshake:" in line:
                val  = line.split(":", 1)[1].strip()
                secs = 0
                for n, unit in re.findall(r"(\d+)\s+(second|minute|hour|day)", val):
                    mult = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}[unit]
                    secs += int(n) * mult
                if secs:
                    stats[peer]["last_hs"] = int(time.time()) - secs
            elif "transfer:" in line:
                parts = line.split(":", 1)[1].strip().split(",")
                for p in parts:
                    p = p.strip()
                    if "received" in p:
                        stats[peer]["rx"] = " ".join(p.split()[:2])
                    elif "sent" in p:
                        stats[peer]["tx"] = " ".join(p.split()[:2])

    _live_stats_cache.set(stats)
    return stats


def get_server_info() -> dict:
    """Инфо о сервере с кэшированием на 5 секунд."""
    cached = _status_cache.get(STATUS_TTL)
    if cached is not None:
        return cached

    info = {"ip": "?", "port": "?", "region": "world", "iface_up": False}
    if not Path(SERVER_CONF).exists():
        return info

    for line in Path(SERVER_CONF).read_text().splitlines():
        if line.startswith("ListenPort"):
            info["port"] = line.split("=", 1)[1].strip()
        if "Region:" in line:
            info["region"] = line.split(":", 1)[1].strip()

    rc, out, _ = run(["bash", "-c", "ip route get 1 2>/dev/null | awk '{print $7; exit}'"])
    if rc == 0 and out.strip():
        info["ip"] = out.strip()

    rc, out, _ = run(["ip", "link", "show", AWG_IFACE])
    info["iface_up"] = rc == 0 and "UP" in out

    _status_cache.set(info)
    return info


# ══════════════════════════════════════════════════════════════════════════════
# WARP интеграция (awg2.sh)
# ══════════════════════════════════════════════════════════════════════════════

def warp_available() -> bool:
    """WARP доступен если есть интерфейс warp0 и файл peers.list."""
    if not Path(WARP_PEERS).exists():
        return False
    rc, _, _ = run(["ip", "link", "show", WARP_IFACE])
    return rc == 0


def warp_get_peers() -> set:
    """Список IP клиентов которые роутятся через WARP."""
    if not Path(WARP_PEERS).exists():
        return set()
    try:
        return {
            line.strip() for line in Path(WARP_PEERS).read_text().splitlines()
            if line.strip() and not line.startswith("#")
        }
    except Exception as e:
        log.warning(f"warp_get_peers: {e}")
        return set()


def warp_is_enabled_for(client_ip: str) -> bool:
    """Проверка: ходит ли клиент с этим IP через WARP.
    Проверяем оба формата (с /32 и без), т.к. awg2 пишет /32, но в старых
    конфигах peers.list мог быть голый IP."""
    ip_only = client_ip.split("/")[0].strip()
    cidr_ip = f"{ip_only}/32"
    peers   = warp_get_peers()
    return cidr_ip in peers or ip_only in peers


def warp_toggle(client_ip: str, enable: bool) -> tuple:
    """Включить/выключить WARP для клиента. Возвращает (success, message).

    Не source-ит awg2.sh (он запустит главное меню в фоне).
    Дублирует минимально необходимую логику awg2.sh:
      - peers.list: одна строка "10.x.x.x/32" на клиента
      - ip rule from <ip>/32 lookup 200 — роутить через WARP-таблицу
    """
    if not warp_available():
        return False, "WARP не настроен на сервере"

    # Нормализуем формат: всегда CIDR /32 (как делает awg2)
    ip_only = client_ip.split("/")[0].strip()
    cidr_ip = f"{ip_only}/32"

    try:
        # 1. Обновляем peers.list атомарно
        existing = warp_get_peers()
        # Чистим обе формы (с /32 и без), чтобы не было дублей
        existing.discard(ip_only)
        existing.discard(cidr_ip)
        if enable:
            existing.add(cidr_ip)

        new_content = "\n".join(sorted(existing))
        if new_content:
            new_content += "\n"
        tmp = Path(WARP_PEERS + ".tmp")
        tmp.write_text(new_content)
        tmp.rename(WARP_PEERS)

        # 2. Применяем/убираем ip rule (awg2 использует lookup 200)
        if enable:
            # Сначала удалить старое правило (idempotent), потом добавить
            run(["ip", "rule", "del", "from", cidr_ip, "lookup", "200"])
            rc, _, err = run(["ip", "rule", "add", "from", cidr_ip, "lookup", "200"])
            if rc != 0:
                return False, f"ip rule add: {err.strip()[:120]}"
        else:
            # Удалить, ошибка (правила нет) — не критична
            run(["ip", "rule", "del", "from", cidr_ip, "lookup", "200"])

        return True, ("через WARP" if enable else "напрямую")
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"


def online_icon(last_hs: int) -> str:
    if not last_hs:
        return "⚫"
    elapsed = int(time.time()) - last_hs
    if elapsed < 120: return "🟢"
    if elapsed < 300: return "🟡"
    return "🔴"


def elapsed_str(last_hs: int) -> str:
    if not last_hs:
        return "никогда"
    sec = int(time.time()) - last_hs
    if sec < 60:   return f"{sec}с назад"
    if sec < 3600: return f"{sec // 60}м назад"
    return f"{sec // 3600}ч назад"


def fmt_bytes(b: int) -> str:
    if b < 1024:      return f"{b}B"
    if b < 1024 ** 2: return f"{b / 1024:.1f}KB"
    if b < 1024 ** 3: return f"{b / 1024 ** 2:.1f}MB"
    return f"{b / 1024 ** 3:.1f}GB"


# ══════════════════════════════════════════════════════════════════════════════
# Клавиатуры — отдельный класс (как tu.InlineKeyboard в Go)
# ══════════════════════════════════════════════════════════════════════════════

class Keyboards:
    @staticmethod
    def main_reply() -> ReplyKeyboardMarkup:
        """Постоянная клавиатура снизу — главное меню."""
        return ReplyKeyboardMarkup([
            ["👥 Клиенты",          "📊 Статус"],
            ["➕ Добавить клиента"],
            ["🔄 Перезапустить awg0"],
        ], resize_keyboard=True)

    @staticmethod
    def back_to_clients() -> InlineKeyboardMarkup:
        """Только для контекста карточки клиента — назад к списку."""
        return InlineKeyboardMarkup([[
            InlineKeyboardButton("◀️ К списку клиентов", callback_data="clients")
        ]])

    @staticmethod
    def clients(clients: list, stats: dict) -> InlineKeyboardMarkup:
        rows = []
        for c in clients:
            icon = online_icon(stats.get(c["pubkey"], {}).get("last_hs", 0))
            rows.append([InlineKeyboardButton(
                f"{icon} {c['name']}  {c['ip'].split('/')[0]}",
                callback_data=f"c:{c['name']}"
            )])
        return InlineKeyboardMarkup(rows)

    @staticmethod
    def client_card(name: str, warp_on: bool = False) -> InlineKeyboardMarkup:
        warp_btn = (
            InlineKeyboardButton("☁️ Выкл WARP", callback_data=f"warpoff:{name}")
            if warp_on else
            InlineKeyboardButton("🌍 Вкл WARP",  callback_data=f"warpon:{name}")
        )
        return InlineKeyboardMarkup([
            [InlineKeyboardButton("📱 QR-код",      callback_data=f"qr:{name}"),
             InlineKeyboardButton("📄 Текст",        callback_data=f"conf:{name}")],
            [InlineKeyboardButton("📁 Файл .conf",  callback_data=f"file:{name}"),
             InlineKeyboardButton("🗑 Удалить",      callback_data=f"del:{name}")],
            [warp_btn],
            [InlineKeyboardButton("◀️ К списку",    callback_data="clients")],
        ])

    @staticmethod
    def client_delete_confirm(name: str) -> InlineKeyboardMarkup:
        return InlineKeyboardMarkup([[
            InlineKeyboardButton("✅ Да, удалить", callback_data=f"delok:{name}"),
            InlineKeyboardButton("❌ Нет",         callback_data=f"c:{name}"),
        ]])

    @staticmethod
    def profile() -> InlineKeyboardMarkup:
        return InlineKeyboardMarkup([
            [InlineKeyboardButton("⚡ QUIC (рекомендуется)", callback_data="prof:quic")],
            [InlineKeyboardButton("📞 SIP (VoIP мимикрия)",  callback_data="prof:sip")],
            [InlineKeyboardButton("🌐 DNS Query",             callback_data="prof:dns")],
            [InlineKeyboardButton("🔇 Базовый (без I1-I5)",  callback_data="prof:basic")],
            [InlineKeyboardButton("❌ Отмена",               callback_data="cancel_add")],
        ])

    @staticmethod
    def status_refresh() -> InlineKeyboardMarkup:
        return InlineKeyboardMarkup([[
            InlineKeyboardButton("🔄 Обновить", callback_data="status"),
        ]])


kb = Keyboards  # короткий алиас


# ══════════════════════════════════════════════════════════════════════════════
# Тексты
# ══════════════════════════════════════════════════════════════════════════════

def text_main() -> str:
    info    = get_server_info()
    clients = get_clients()
    stats   = get_live_stats()
    online  = sum(
        1 for c in clients
        if stats.get(c["pubkey"], {}).get("last_hs", 0)
        and (time.time() - stats[c["pubkey"]]["last_hs"]) < 300
    )
    status = "🟢 активен" if info["iface_up"] else "🔴 остановлен"
    return (
        f"🛡 <b>AWG Toolza Bot</b>\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"🖥 <code>{info['ip']}:{info['port']}</code>\n"
        f"📡 {status}\n"
        f"👥 Клиентов: {len(clients)}  🟢 онлайн: {online}\n"
        f"🌍 Регион: <code>{info['region']}</code>"
    )


def text_status() -> str:
    info    = get_server_info()
    clients = get_clients()
    stats   = get_live_stats()
    online  = sum(
        1 for c in clients
        if stats.get(c["pubkey"], {}).get("last_hs", 0)
        and (time.time() - stats[c["pubkey"]]["last_hs"]) < 300
    )
    rc, out, _ = run(["awg", "show", AWG_IFACE, "transfer"])
    rx = tx = 0
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3:
            try:
                rx += int(p[1])
                tx += int(p[2])
            except ValueError:
                pass
    return (
        f"📊 <b>Статус</b>\n━━━━━━━━━━━━━━━━━━\n"
        f"🖥 <code>{info['ip']}:{info['port']}</code>\n"
        f"📡 {'🟢 активен' if info['iface_up'] else '🔴 остановлен'}\n"
        f"👥 {len(clients)} клиентов  🟢 {online} онлайн\n"
        f"↓ {fmt_bytes(rx)}  ↑ {fmt_bytes(tx)}"
    )


def text_client_card(c: dict) -> str:
    stats = get_live_stats()
    s     = stats.get(c["pubkey"], {})
    hs    = s.get("last_hs", 0)
    # WARP статус
    warp_line = ""
    if warp_available():
        if warp_is_enabled_for(c["ip"]):
            warp_line = "\n☁️ Маршрут: <b>через WARP</b>"
        else:
            warp_line = "\n🌍 Маршрут: напрямую"
    return (
        f"👤 <b>{c['name']}</b>\n━━━━━━━━━━━━━━━━━━\n"
        f"🌐 IP: <code>{c['ip']}</code>\n"
        f"{online_icon(hs)} {elapsed_str(hs)}\n"
        f"↓ {s.get('rx', '—')}  ↑ {s.get('tx', '—')}"
        f"{warp_line}"
    )


# ══════════════════════════════════════════════════════════════════════════════
# Авторизация
# ══════════════════════════════════════════════════════════════════════════════

def auth(func):
    """Декоратор: пропускает только admin_id (только пользовательские сообщения)."""
    @wraps(func)
    async def wrapper(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        user = update.effective_user
        if user is None:
            # Канальные посты, edited_channel_post и пр. — игнорируем
            log.warning("Отклонён: нет effective_user (канальный пост?)")
            return
        if str(user.id) != ctx.bot_data["admin_id"]:
            log.warning(f"Отклонён: uid={user.id}")
            return
        return await func(update, ctx)
    return wrapper


def worker(func):
    """Декоратор: ограничивает параллельность через WORKER_POOL."""
    @wraps(func)
    async def wrapper(*args, **kwargs):
        if WORKER_POOL is None:
            return await func(*args, **kwargs)
        async with WORKER_POOL:
            return await func(*args, **kwargs)
    return wrapper


# ══════════════════════════════════════════════════════════════════════════════
# /start
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# Команды
# ══════════════════════════════════════════════════════════════════════════════

@auth
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        text_main(), parse_mode=ParseMode.HTML,
        reply_markup=kb.main_reply()   # постоянная клавиатура снизу
    )


@auth
async def cmd_help(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    text = (
        "🛡 <b>AWG Toolza Bot</b>\n━━━━━━━━━━━━━━━━━━\n"
        "/start — главное меню\n"
        "/status — статус сервера\n"
        "/id — твой Telegram ID\n"
        "/help — это сообщение\n\n"
        "Используй кнопки внизу для навигации:\n"
        "• 👥 <b>Клиенты</b> — список пиров с QR/файлами\n"
        "• 📊 <b>Статус</b> — трафик и онлайн\n"
        "• ➕ <b>Добавить клиента</b> — новый пир\n"
        "• 🔄 <b>Перезапустить awg0</b>"
    )
    await update.message.reply_text(text, parse_mode=ParseMode.HTML)


@auth
async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    _status_cache.invalidate()
    _live_stats_cache.invalidate()
    await update.message.reply_text(
        text_status(), parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([[
            InlineKeyboardButton("🔄 Обновить", callback_data="status")
        ]])
    )


async def cmd_id(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Возвращает Telegram ID любому пользователю — без auth, чтобы помочь
    настроить ADMIN_CHAT_ID."""
    if update.effective_user is None:
        return
    await update.message.reply_text(
        f"🆔 Твой Telegram ID: <code>{update.effective_user.id}</code>",
        parse_mode=ParseMode.HTML
    )


# ══════════════════════════════════════════════════════════════════════════════
# Единый обработчик колбэков (аналог answerCallback в Go)
# ══════════════════════════════════════════════════════════════════════════════

@auth
@worker
async def on_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """
    Центральный диспетчер колбэков.
    Структура: сначала точные совпадения (main, clients, status…),
    затем совпадения по префиксу (c:, qr:, conf:, file:, del:, delok:, prof:).
    Аналог switch dataArray[0] { case "...": ... } в Go.
    """
    q = update.callback_query
    await q.answer()
    d = q.data

    # ── точные команды ─────────────────────────────────────────────────────
    if d == "cancel_add":
        ctx.user_data.clear()
        await q.delete_message()
        return ConversationHandler.END
    elif d == "clients":
        await _cb_clients(q)
    elif d == "status":
        await _cb_status(q)
    elif d == "restart":
        await _cb_restart(q)
    elif d == "add_start":
        # передаётся в ConversationHandler
        pass

    # ── команды с данными (prefix:payload) ────────────────────────────────
    elif ":" in d:
        prefix, payload = d.split(":", 1)
        # Внимание: "prof:" обрабатывается ТОЛЬКО в ConversationHandler.
        # Если включить его сюда — будет двойная обработка (баг с "уже существует").
        dispatch = {
            "c":       _cb_client_card,
            "qr":      _cb_client_qr,
            "conf":    _cb_client_conf,
            "file":    _cb_client_file,
            "del":     _cb_client_del_confirm,
            "delok":   _cb_client_del,
            "warpon":  _cb_warp_on,
            "warpoff": _cb_warp_off,
        }
        handler = dispatch.get(prefix)
        if handler:
            await handler(q, payload, ctx)
        elif prefix not in ("prof",):  # prof обрабатывается ConversationHandler-ом
            log.warning(f"Неизвестный callback prefix: {prefix!r}")


# ── вспомогательные колбэк-функции ────────────────────────────────────────────

def _client_card_kb(name: str) -> InlineKeyboardMarkup:
    """Клавиатура карточки клиента с актуальным WARP-статусом."""
    if not warp_available():
        return kb.client_card(name, warp_on=False)
    # Найдём IP клиента
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        return kb.client_card(name, warp_on=False)
    return kb.client_card(name, warp_on=warp_is_enabled_for(c["ip"]))


async def _cb_clients(q):
    clients = get_clients()
    if not clients:
        await q.edit_message_text(
            "👥 Клиентов нет\n\nДобавь через ➕",
            
        )
        return
    stats = get_live_stats()
    warp_active = warp_available()
    warp_ips = warp_get_peers() if warp_active else set()
    lines = ["👥 <b>Клиенты:</b>\n"]
    for c in clients:
        s    = stats.get(c["pubkey"], {})
        hs   = s.get("last_hs", 0)
        icon = online_icon(hs)
        ip_clean = c["ip"].split("/")[0]
        # ☁️ если клиент роутится через WARP
        warp_mark = " ☁️" if warp_active and (
            ip_clean in warp_ips or f"{ip_clean}/32" in warp_ips
        ) else ""
        lines.append(
            f"{icon} <b>{c['name']}</b>{warp_mark}  "
            f"<code>{ip_clean}</code>  "
            f"↓{s.get('rx', '—')} ↑{s.get('tx', '—')}"
        )
    if warp_active:
        lines.append("\n<i>☁️ — трафик через WARP</i>")
    await q.edit_message_text(
        "\n".join(lines), parse_mode=ParseMode.HTML,
        reply_markup=kb.clients(clients, stats)
    )


async def _cb_status(q):
    # Инвалидируем кэш чтобы показать актуальные данные
    _status_cache.invalidate()
    _live_stats_cache.invalidate()
    await q.edit_message_text(
        text_status(), parse_mode=ParseMode.HTML,
        reply_markup=kb.status_refresh()
    )


async def _cb_restart(q):
    await q.edit_message_text("⏳ Перезапускаю awg0...")
    await asyncio.to_thread(run, ["awg-quick", "down", SERVER_CONF])
    await asyncio.sleep(1)
    rc, _, err = await asyncio.to_thread(run, ["awg-quick", "up", SERVER_CONF])
    # После перезапуска инвалидируем кэш
    _status_cache.invalidate()
    _live_stats_cache.invalidate()
    if rc == 0:
        await q.edit_message_text("✅ awg0 перезапущен")
    else:
        await q.edit_message_text(
            f"❌ Ошибка:\n<code>{_html.escape(err[:300])}</code>",
            parse_mode=ParseMode.HTML
        )


async def _cb_client_card(q, name: str, _ctx):
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        await q.edit_message_text("❌ Клиент не найден")
        return
    await q.edit_message_text(
        text_client_card(c), parse_mode=ParseMode.HTML,
        reply_markup=_client_card_kb(name)
    )


def _safe_unlink(path: str):
    """Удалить файл, игнорируя FileNotFoundError."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    except OSError as e:
        log.warning(f"Не удалось удалить {path}: {e}")


async def _cb_client_qr(q, name: str, _ctx):
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c or not c["file"]:
        await q.edit_message_text("❌ Файл не найден")
        return

    await q.edit_message_text(
        f"⏳ Генерирую QR для <b>{name}</b>...", parse_mode=ParseMode.HTML
    )

    conf_text = Path(c["file"]).read_text()
    conf_for_qr = "\n".join(
        l for l in conf_text.splitlines()
        if not re.match(r"^I[2-5]\s*=", l)
    )
    has_i2_i5 = any(re.match(r"^I[2-5]\s*=", l) for l in conf_text.splitlines())

    tmp_path = qtmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            tmp_path = tmp.name
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as qtmp:
            qtmp.write(conf_for_qr)
            qtmp_path = qtmp.name

        rc, _, _ = await asyncio.to_thread(
            run, ["qrencode", "-t", "PNG", "-o", tmp_path,
                  "-r", qtmp_path, "--dpi=150", "-s", "4"]
        )

        if rc != 0:
            await q.edit_message_text(
                "❌ QR слишком большой даже без I2-I5\nИспользуй <b>Файл .conf</b>",
                parse_mode=ParseMode.HTML, reply_markup=_client_card_kb(name)
            )
            return

        caption = f"📱 <b>{name}</b>\nИмпортируй в AmneziaVPN"
        if has_i2_i5:
            caption += "\n\n⚠️ QR без I2-I5 (слишком большой)\nДля полного конфига → Файл .conf"

        with open(tmp_path, "rb") as f:
            await q.message.reply_photo(photo=f, caption=caption, parse_mode=ParseMode.HTML)

        await q.edit_message_text(
            text_client_card(c), parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
    finally:
        if qtmp_path:
            _safe_unlink(qtmp_path)
        if tmp_path:
            _safe_unlink(tmp_path)


async def _cb_client_conf(q, name: str, _ctx):
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c or not c["file"]:
        await q.edit_message_text("❌ Файл не найден")
        return
    text = Path(c["file"]).read_text()
    escaped = _html.escape(text)
    msg_text = f"📄 <b>{name}</b>\n<pre>{escaped}</pre>"
    # Telegram лимит — 4096 символов. Если конфиг не влезает — отправляем файлом
    if len(msg_text) > 4096:
        await q.edit_message_text(
            f"📄 <b>{name}</b>\nКонфиг слишком большой для текста — отправляю файлом.",
            parse_mode=ParseMode.HTML
        )
        with open(c["file"], "rb") as f:
            await q.message.reply_document(
                document=InputFile(f, filename=f"{name}_awg2.conf"),
                caption=f"📁 <b>{name}</b>\nИмпортируй в AmneziaVPN",
                parse_mode=ParseMode.HTML,
            )
        await q.edit_message_text(
            text_client_card(c), parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
    else:
        await q.edit_message_text(
            msg_text, parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )


async def _cb_client_file(q, name: str, _ctx):
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c or not c["file"]:
        await q.edit_message_text("❌ Файл не найден")
        return
    await q.edit_message_text(
        f"⏳ Отправляю <b>{name}.conf</b>...", parse_mode=ParseMode.HTML
    )
    with open(c["file"], "rb") as f:
        await q.message.reply_document(
            document=InputFile(f, filename=f"{name}_awg2.conf"),
            caption=f"📁 <b>{name}</b>\nИмпортируй в AmneziaVPN",
            parse_mode=ParseMode.HTML,
        )
    await q.edit_message_text(
        text_client_card(c), parse_mode=ParseMode.HTML,
        reply_markup=_client_card_kb(name)
    )


async def _cb_client_del_confirm(q, name: str, _ctx):
    await q.edit_message_text(
        f"⚠️ Удалить <b>{name}</b>?\nОтменить нельзя.",
        parse_mode=ParseMode.HTML,
        reply_markup=kb.client_delete_confirm(name)
    )


async def _cb_client_del(q, name: str, ctx):
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        await q.edit_message_text("❌ Клиент не найден")
        return

    admin_id = ctx.bot_data.get("admin_id", "")

    def _do_delete():
        # Межпроцессный лок — синхронизируется с add_client
        lock_fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            run(["awg", "set", AWG_IFACE, "peer", c["pubkey"], "remove"])

            conf_text = Path(SERVER_CONF).read_text()
            blocks    = re.split(r"(?=\[Peer\])", conf_text)
            filtered  = "".join(b for b in blocks if c["pubkey"] not in b)
            tmp = Path(SERVER_CONF + ".tmp")
            tmp.write_text(filtered)
            tmp.rename(SERVER_CONF)

            if c["file"] and Path(c["file"]).exists():
                Path(c["file"]).unlink()

            # Убираем из WARP (если был включён) — silently
            if warp_available():
                try:
                    warp_toggle(c["ip"], False)
                except Exception as e:
                    log.warning(f"warp cleanup на удалении {name}: {e}")
        finally:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(lock_fd)

    await asyncio.to_thread(_do_delete)

    _clients_cache.invalidate()

    log.info(f"Удалён: {name} admin={admin_id}")
    await q.edit_message_text(
        f"✅ <b>{name}</b> удалён", parse_mode=ParseMode.HTML,
        
    )


async def _cb_warp_on(q, name: str, ctx):
    await _cb_warp_toggle(q, name, ctx, enable=True)


async def _cb_warp_off(q, name: str, ctx):
    await _cb_warp_toggle(q, name, ctx, enable=False)


async def _cb_warp_toggle(q, name: str, ctx, enable: bool):
    """Включить/выключить WARP для клиента."""
    admin_id = ctx.bot_data.get("admin_id", "")
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        await q.edit_message_text("❌ Клиент не найден")
        return

    if not warp_available():
        await q.edit_message_text(
            "❌ <b>WARP не настроен на сервере</b>\n\n"
            "Зайди в меню awg2 (sudo awg2) → пункт WARP и установи wgcf.",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
        return

    action = "включаю" if enable else "выключаю"
    await q.edit_message_text(
        f"⏳ {action.capitalize()} WARP для <b>{name}</b>...",
        parse_mode=ParseMode.HTML
    )

    ok_flag, msg = await asyncio.to_thread(warp_toggle, c["ip"], enable)

    if ok_flag:
        log.info(f"WARP {'on' if enable else 'off'}: {name} ({c['ip']}) admin={admin_id}")
        # Показываем обновлённую карточку
        await q.edit_message_text(
            text_client_card(c), parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
    else:
        await q.edit_message_text(
            f"❌ Ошибка: {_html.escape(msg)}",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )


async def _cb_add_profile(q, profile: str, ctx):
    """Вызывается из ConversationHandler — шаг выбора профиля."""
    name = ctx.user_data.get("new_name", "")
    if not name:
        await q.edit_message_text("❌ Имя не задано")
        return ConversationHandler.END

    await q.edit_message_text(
        f"⏳ Создаю <b>{name}</b> (профиль: {profile})...",
        parse_mode=ParseMode.HTML
    )

    admin_id = ctx.bot_data.get("admin_id", "")

    # Защита на случай если post_init ещё не отработал
    global _add_client_lock
    if _add_client_lock is None:
        _add_client_lock = asyncio.Lock()

    # Двойная защита:
    #   - asyncio.Lock — от двойного клика в одном процессе (быстро)
    #   - fcntl.flock внутри add_client — от параллельных процессов
    async with _add_client_lock:
        client_path = Path(f"/root/{name}_awg2.conf")

        # Проверяем дубль: файл должен существовать И клиент должен быть
        # в серверном конфиге. Если файл есть, но в конфиге нет — это
        # "осиротевший" файл (от старой установки или сбоя), удаляем его.
        if client_path.exists():
            _clients_cache.invalidate()
            existing = {c["name"] for c in get_clients()}
            if name in existing:
                await q.edit_message_text(
                    f"❌ <b>{name}</b> уже существует.",
                    parse_mode=ParseMode.HTML
                )
                return ConversationHandler.END
            # Осиротевший файл — удаляем и продолжаем
            log.warning(f"Удаляю осиротевший файл: {client_path}")
            client_path.unlink()

        ok_flag, msg = await asyncio.to_thread(add_client, name, profile, admin_id)
        _clients_cache.invalidate()

    if ok_flag:
        await q.edit_message_text(
            f"✅ <b>{name}</b> создан!\n{msg}",
            parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("👥 К клиентам", callback_data="clients")
            ]])
        )
    else:
        await q.edit_message_text(
            f"❌ Ошибка:\n<code>{_html.escape(msg)}</code>",
            parse_mode=ParseMode.HTML,
        )
    return ConversationHandler.END


# ══════════════════════════════════════════════════════════════════════════════
# ConversationHandler — добавление клиента
# ══════════════════════════════════════════════════════════════════════════════

@auth
async def on_add_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    ctx.user_data.clear()
    text_msg = "➕ <b>Новый клиент</b>\n\nВведи имя (латиница, цифры, _):"
    cancel_kb = InlineKeyboardMarkup([[
        InlineKeyboardButton("❌ Отмена", callback_data="cancel_add")
    ]])
    if update.callback_query:
        await update.callback_query.answer()
        await update.callback_query.edit_message_text(
            text_msg, parse_mode=ParseMode.HTML, reply_markup=cancel_kb
        )
    else:
        await update.message.reply_text(
            text_msg, parse_mode=ParseMode.HTML, reply_markup=cancel_kb
        )
    return ADD_NAME


@auth
async def on_add_name(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    name = update.message.text.strip()
    if not re.match(r"^[a-zA-Z0-9_]{1,32}$", name):
        await update.message.reply_text(
            "❌ Только латиница, цифры, _ (макс 32 символа). Введи снова:"
        )
        return ADD_NAME
    # Проверяем дубли напрямую, без кэша
    _clients_cache.invalidate()
    clients = get_clients()
    if any(c["name"] == name for c in clients):
        await update.message.reply_text(
            f"❌ <b>{name}</b> уже есть. Введи другое:", parse_mode=ParseMode.HTML
        )
        return ADD_NAME
    ctx.user_data["new_name"] = name
    await update.message.reply_text(
        f"👤 Имя: <b>{name}</b>\n\nВыбери профиль мимикрии:",
        parse_mode=ParseMode.HTML, reply_markup=kb.profile()
    )
    return ADD_PROFILE


@auth
async def on_add_profile(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    profile = q.data[5:]  # "prof:quic" → "quic"
    return await _cb_add_profile(q, profile, ctx)


@auth
async def on_conv_cancel(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    ctx.user_data.clear()
    # Возвращаем reply keyboard снизу
    await q.message.reply_text(text_main(), parse_mode=ParseMode.HTML, reply_markup=kb.main_reply())
    await q.message.delete()
    return ConversationHandler.END


@auth
async def handle_any_message(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Обработчик кнопок Reply Keyboard снизу."""
    text = (update.message.text or "").strip()

    if text == "👥 Клиенты":
        clients = get_clients()
        if not clients:
            await update.message.reply_text(
                "👥 Клиентов нет\n\nДобавь через ➕ Добавить клиента",
                reply_markup=kb.main_reply()
            )
            return
        stats = get_live_stats()
        lines = ["👥 <b>Клиенты:</b>\n"]
        for c in clients:
            s    = stats.get(c["pubkey"], {})
            hs   = s.get("last_hs", 0)
            icon = online_icon(hs)
            lines.append(
                f"{icon} <b>{c['name']}</b>  "
                f"<code>{c['ip'].split('/')[0]}</code>  "
                f"↓{s.get('rx', '—')} ↑{s.get('tx', '—')}"
            )
        await update.message.reply_text(
            "\n".join(lines), parse_mode=ParseMode.HTML,
            reply_markup=kb.clients(clients, stats)
        )

    elif text == "📊 Статус":
        _status_cache.invalidate()
        _live_stats_cache.invalidate()
        rc, out, _ = await asyncio.to_thread(run, ["awg", "show", AWG_IFACE, "transfer"])
        rx = tx = 0
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 3:
                try:
                    rx += int(p[1])
                    tx += int(p[2])
                except ValueError:
                    pass
        info    = get_server_info()
        clients = get_clients()
        stats   = get_live_stats()
        online  = sum(
            1 for c in clients
            if stats.get(c["pubkey"], {}).get("last_hs", 0)
            and (time.time() - stats[c["pubkey"]]["last_hs"]) < 300
        )
        text_out = (
            f"📊 <b>Статус</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🖥 <code>{info['ip']}:{info['port']}</code>\n"
            f"📡 {'🟢 активен' if info['iface_up'] else '🔴 остановлен'}\n"
            f"👥 {len(clients)} клиентов  🟢 {online} онлайн\n"
            f"↓ {fmt_bytes(rx)}  ↑ {fmt_bytes(tx)}"
        )
        await update.message.reply_text(
            text_out, parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("🔄 Обновить", callback_data="status")
            ]])
        )

    elif text == "🔄 Перезапустить awg0":
        msg = await update.message.reply_text("⏳ Перезапускаю awg0...")
        await asyncio.to_thread(run, ["awg-quick", "down", SERVER_CONF])
        await asyncio.sleep(1)
        rc, _, err = await asyncio.to_thread(run, ["awg-quick", "up", SERVER_CONF])
        _status_cache.invalidate()
        _live_stats_cache.invalidate()
        result = "✅ awg0 перезапущен" if rc == 0 else f"❌ Ошибка:\n<code>{_html.escape(err[:200])}</code>"
        await msg.edit_text(result, parse_mode=ParseMode.HTML)


# ══════════════════════════════════════════════════════════════════════════════
# Добавление клиента (бизнес-логика)
# ══════════════════════════════════════════════════════════════════════════════

_CPS_CODE = r"""
import sys, secrets, struct, random
def rh(n): return secrets.token_bytes(n)
def ri(a,b): return random.randint(a,b)
def rc(lst): return random.choice(lst)
def u16(v): return struct.pack(">H",v&0xFFFF)
def cps(r): return "<b 0x%s>" % r.hex()
P=sys.argv[1] if len(sys.argv)>1 else "quic"
def quic_i():
    fb=rc([0xC0,0xC0,0xC0,0xC3]); pn=(fb&3)+1
    enc=1200-26-pn; pv=u16(0x4000|pn+enc)
    return bytes([fb])+b"\x00\x00\x00\x01"+bytes([8])+rh(8)+bytes([8])+rh(8)+b"\x00"+pv+rh(pn)+rh(enc)
def quic_s():
    pn=ri(1,2); fb=0x40|(ri(0,1)<<5)|(ri(0,1)<<2)|(pn-1)
    return bytes([fb])+rh(8)+rh(pn)+rh(ri(40,90))
def sip():
    h=rc(["sipgate.de","sip.ovh.net","sip.beeline.ru","sip.mts.ru"])
    u=rc(["alice","bob","100","200"])+str(ri(10,99))
    ip="10.%d.%d.%d"%(ri(0,255),ri(0,255),ri(10,200))
    br="z9hG4bK"+secrets.token_hex(7); tag=secrets.token_hex(4)
    cid="%s@%s"%(secrets.token_hex(8),h)
    return("\r\n".join(["REGISTER sip:%s SIP/2.0"%h,
        "Via: SIP/2.0/UDP %s:5060;branch=%s;rport"%(ip,br),
        "Max-Forwards: 70","From: <sip:%s@%s>;tag=%s"%(u,h,tag),
        "To: <sip:%s@%s>"%(u,h),"Call-ID: %s"%cid,
        "CSeq: %d REGISTER"%ri(1,50),
        "Contact: <sip:%s@%s:5060>"%(u,ip),
        "Expires: %d"%rc([300,600,3600]),"Content-Length: 0","",""])).encode()
def dns(d="google.com"):
    qn=b"".join(bytes([len(l)])+l.encode() for l in d.split("."))+b"\x00"
    return b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"+qn+b"\x00\x01\x00\x01"
pool=["google.com","github.com","yandex.ru","vk.com","cloudflare.com"]
random.shuffle(pool)
if P=="sip": print(cps(sip())); [print("") for _ in range(4)]
elif P=="dns": [print("<r 2><b 0x%s>"%dns(pool[i%len(pool)]).hex()) for i in range(5)]
else: print(cps(quic_i())); [print(cps(quic_s())) for _ in range(4)]
"""


def add_client(name: str, profile: str, admin_id: str = "") -> tuple:
    """Создать клиента. Использует fcntl flock для защиты от
    параллельных запусков (даже из разных процессов)."""
    import glob as _glob

    if not Path(SERVER_CONF).exists():
        return False, "Серверный конфиг не найден"

    # Межпроцессный лок: защищает от двух одновременных add_client,
    # даже если запущены два экземпляра бота.
    lock_fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)

        # Проверка дубля: файл должен существовать И быть в SERVER_CONF.
        # Иначе это осиротевший файл — удаляем и идём дальше.
        client_path = Path(f"/root/{name}_awg2.conf")
        if client_path.exists():
            srv_content = Path(SERVER_CONF).read_text()
            if f"# {name}\n" in srv_content or f"# {name}\r\n" in srv_content:
                return False, f"{name} уже существует"
            log.warning(f"Удаляю осиротевший файл (нет в SERVER_CONF): {client_path}")
            client_path.unlink()

        content = Path(SERVER_CONF).read_text()
        sp = {}
        listen_port = ""
        for line in content.splitlines():
            if "=" in line and not line.startswith("[") and not line.startswith("#"):
                k, v = line.split("=", 1)
                sp[k.strip().lower()] = v.strip()

        rc, priv, _ = run(["awg", "genkey"])
        if rc != 0: return False, "Ошибка genkey"
        priv = priv.strip()
        rc, pub, _ = run(["awg", "pubkey"], input_str=priv)
        if rc != 0: return False, "Ошибка pubkey"
        pub = pub.strip()
        rc, psk, _ = run(["awg", "genpsk"])
        if rc != 0: return False, "Ошибка genpsk"
        psk = psk.strip()

        used = {1}
        for line in content.splitlines():
            m = re.search(r"AllowedIPs\s*=\s*[\d.]+\.(\d+)/", line)
            if m:
                used.add(int(m.group(1)))
        addr  = sp.get("address", "10.0.0.1/24")
        base  = ".".join(addr.split(".")[:3]) + "."
        try:
            octet = next(i for i in range(2, 255) if i not in used)
        except StopIteration:
            return False, "Закончились свободные IP в подсети"
        client_ip = f"{base}{octet}/32"

        server_pubkey = ""
        endpoint = ""
        for line in content.splitlines():
            if line.startswith("PrivateKey"):
                priv_srv = line.split("=", 1)[1].strip()
                rc_pk, pub_srv, _ = run(["awg", "pubkey"], input_str=priv_srv)
                if rc_pk == 0:
                    server_pubkey = pub_srv.strip()
            if line.startswith("ListenPort"):
                listen_port = line.split("=", 1)[1].strip()

        rc_ip, srv_ip, _ = run(["bash", "-c", "ip route get 1 2>/dev/null | awk '{print $7; exit}'"])
        if rc_ip == 0 and srv_ip.strip():
            endpoint = f"{srv_ip.strip()}:{listen_port}" if listen_port else ""

        if not server_pubkey or not endpoint:
            for fpath in _glob.glob(CLIENTS_GLOB):
                for line in Path(fpath).read_text().splitlines():
                    if line.startswith("PublicKey") and not server_pubkey:
                        server_pubkey = line.split("=", 1)[1].strip()
                    if line.startswith("Endpoint") and not endpoint:
                        endpoint = line.split("=", 1)[1].strip()
                if server_pubkey and endpoint:
                    break

        if not server_pubkey:
            return False, "Не удалось определить PublicKey сервера"
        if not endpoint:
            return False, "Не удалось определить Endpoint"

        i_params = ""
        if profile != "basic":
            rc2, cps_out, _ = run(["python3", "-c", _CPS_CODE, profile])
            if rc2 == 0 and cps_out.strip():
                labels = ["I1", "I2", "I3", "I4", "I5"]
                for i, line in enumerate(cps_out.strip().splitlines()[:5]):
                    if line.strip():
                        i_params += f"\n{labels[i]} = {line.strip()}"

        def g(k, default=""):
            return sp.get(k, default)

        client_conf = (
            f"[Interface]\n"
            f"PrivateKey = {priv}\n"
            f"Address = {client_ip}\n"
            f"DNS = 1.1.1.1, 1.0.0.1\n"
            f"MTU = {g('mtu', '1380')}\n"
            f"Jc = {g('jc')}\nJmin = {g('jmin')}\nJmax = {g('jmax')}\n"
            f"S1 = {g('s1')}\nS2 = {g('s2')}\n"
            f"S3 = {g('s3')}\nS4 = {g('s4')}\n"
            f"H1 = {g('h1')}\nH2 = {g('h2')}\n"
            f"H3 = {g('h3')}\nH4 = {g('h4')}"
            f"{i_params}\n"
            f"[Peer]\n"
            f"PublicKey = {server_pubkey}\n"
            f"PresharedKey = {psk}\n"
            f"Endpoint = {endpoint}\n"
            f"AllowedIPs = 0.0.0.0/0, ::/0\n"
            f"PersistentKeepalive = 25\n"
        )

        # Atomic write клиентского конфига
        client_path = Path(f"/root/{name}_awg2.conf")
        tmp_client  = Path(f"/root/.{name}_awg2.conf.tmp")
        tmp_client.write_text(client_conf)
        os.chmod(tmp_client, 0o600)
        tmp_client.rename(client_path)

        # Atomic write серверного конфига: читаем + добавляем + переименовываем
        peer_block = (
            f"\n[Peer]\n# {name}\n"
            f"PublicKey = {pub}\n"
            f"PresharedKey = {psk}\n"
            f"AllowedIPs = {client_ip}\n"
        )
        new_content = content.rstrip() + "\n" + peer_block
        tmp_server = Path(SERVER_CONF + ".tmp")
        tmp_server.write_text(new_content)
        tmp_server.rename(SERVER_CONF)

        # Применяем к живому интерфейсу — проверяем rc!
        rc_set, _, err_set = run(
            ["awg", "set", AWG_IFACE, "peer", pub,
             "preshared-key", "/dev/stdin", "allowed-ips", client_ip],
            input_str=psk
        )
        if rc_set != 0:
            log.error(f"awg set провалился для {name}: {err_set}")
            return True, (f"IP: <code>{client_ip}</code>\nПрофиль: {profile}\n\n"
                          f"⚠️ <b>Требуется перезапуск awg0</b> для применения")

        log.info(f"Добавлен: {name} ({client_ip}) профиль={profile} admin={admin_id}")
        return True, f"IP: <code>{client_ip}</code>\nПрофиль: {profile}"
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


# ══════════════════════════════════════════════════════════════════════════════
# main
# ══════════════════════════════════════════════════════════════════════════════

def main():
    cfg      = load_config()
    token    = cfg.get("BOT_TOKEN", "")
    admin_id = cfg.get("ADMIN_CHAT_ID", "")
    if not token or not admin_id:
        raise SystemExit("❌ BOT_TOKEN и ADMIN_CHAT_ID не найдены в /etc/awg-bot.conf")

    log.info(f"Запуск AWG Bot, admin={admin_id}")

    app = Application.builder().token(token).build()
    app.bot_data["admin_id"] = admin_id

    conv = ConversationHandler(
        entry_points=[
            CallbackQueryHandler(on_add_start, pattern="^add_start$"),
            MessageHandler(filters.Regex("^➕ Добавить клиента$"), on_add_start),
        ],
        states={
            ADD_NAME:    [MessageHandler(filters.TEXT & ~filters.COMMAND, on_add_name)],
            ADD_PROFILE: [CallbackQueryHandler(on_add_profile, pattern="^prof:")],
        },
        fallbacks=[
            CallbackQueryHandler(on_conv_cancel, pattern="^cancel_add$"),
        ],
        per_message=False,
        per_chat=True,
    )

    # Команды
    app.add_handler(CommandHandler("start",  cmd_start))
    app.add_handler(CommandHandler("help",   cmd_help))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("id",     cmd_id))
    # ConversationHandler — раньше всего
    app.add_handler(conv, group=-1)
    # Колбэки: исключаем prof:* и cancel_add — они обрабатываются ConversationHandler-ом
    app.add_handler(
        CallbackQueryHandler(on_callback, pattern=r"^(?!prof:|cancel_add$).+"),
        group=0
    )
    app.add_handler(MessageHandler(
        filters.TEXT & ~filters.COMMAND, handle_any_message
    ), group=1)

    async def post_init(application):
        # Создаём asyncio-примитивы здесь, когда event loop уже работает (фикс #8)
        global _add_client_lock, WORKER_POOL
        _add_client_lock = asyncio.Lock()
        WORKER_POOL = asyncio.Semaphore(10)

        await application.bot.set_my_commands([
            BotCommand("start",  "Главное меню"),
            BotCommand("status", "Статус сервера"),
            BotCommand("help",   "Справка"),
            BotCommand("id",     "Твой Telegram ID"),
        ])
        from telegram import MenuButtonCommands
        await application.bot.set_chat_menu_button(menu_button=MenuButtonCommands())
        log.info("MenuButton и команды установлены")

    app.post_init = post_init
    log.info("Polling...")
    # Polling с разумным timeout-ом (фикс #14)
    app.run_polling(drop_pending_updates=True, poll_interval=1.0, timeout=30)


if __name__ == "__main__":
    main()
PYEOF

chmod +x "$BOT_PY"
ok "Бот установлен в $BOT_PY"

# ── Шаг 7: Systemd unit ──────────────────────────────────────────────────────
echo ""
info "Создаю systemd unit..."

cat > "$BOT_SERVICE" << EOF
[Unit]
Description=AWG Toolza Telegram Bot
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $BOT_PY
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable awg-bot
systemctl restart awg-bot
sleep 2

if systemctl is-active --quiet awg-bot; then
  ok "Сервис awg-bot запущен и включён в автозапуск"
else
  warn "Сервис не запустился. Проверь: journalctl -u awg-bot -n 30"
fi

# ── Итог ─────────────────────────────────────────────────────────────────────
echo ""
hdr "√ Установка завершена"
cat << INFO

  Бот: @${BOT_USERNAME}
  Конфиг: $BOT_CONF
  Лог: $BOT_LOG

  Управление:
    systemctl status awg-bot      — статус
    systemctl restart awg-bot     — перезапуск
    journalctl -u awg-bot -f      — логи в реальном времени

  Проверь Telegram — бот должен был прислать сообщение.
  Если нет — убедись что ты написал боту /start хотя бы раз.

INFO

if [[ -n "${BOT_USERNAME:-}" ]]; then
  echo -e "  ${C}Открой бота: https://t.me/${BOT_USERNAME}${N}"
fi
echo ""

}  # do_install_bot end


# ══════════════════════════════════════════════════════════════════════════════
# Главное меню
# ══════════════════════════════════════════════════════════════════════════════
show_menu() {
  clear 2>/dev/null || true
  echo ""
  echo -e "${W}╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "${W}║${N}            ${M}🛡  AWG Toolza Bot — менеджер${N}                 ${W}║${N}"
  echo -e "${W}╚══════════════════════════════════════════════════════════╝${N}"
  echo ""

  # Статусная строка
  if bot_is_installed; then
    if bot_is_running; then
      echo -e "  Статус:  ${G}● работает${N}"
    else
      echo -e "  Статус:  ${Y}● установлен но не запущен${N}"
    fi
  else
    echo -e "  Статус:  ${D}○ не установлен${N}"
  fi
  echo ""

  if bot_is_installed; then
    echo -e "  ${G}1)${N} Переустановить (с нуля, спросит токен)"
    echo -e "  ${C}2)${N} Обновить (сохраняя токен и chat_id)"
    echo -e "  ${C}3)${N} Перезапустить сервис"
    echo -e "  ${C}4)${N} Статус"
    echo -e "  ${C}5)${N} Логи (последние 50 строк)"
    echo -e "  ${R}6)${N} Удалить"
  else
    echo -e "  ${G}1)${N} Установить"
    echo -e "  ${D}2) Обновить (бот не установлен)${N}"
    echo -e "  ${D}3) Перезапустить (бот не установлен)${N}"
    echo -e "  ${D}4) Статус (бот не установлен)${N}"
    echo -e "  ${D}5) Логи (бот не установлен)${N}"
    echo -e "  ${D}6) Удалить (бот не установлен)${N}"
  fi
  echo ""
  echo -e "  ${W}0)${N} Выход"
  echo ""
  read -rp "$(echo -e "${C}  Выбор: ${N}")" CHOICE
}

# ── Главный цикл ──────────────────────────────────────────────────────────────
while true; do
  show_menu
  case "${CHOICE:-}" in
    1)
      do_install_bot
      ;;
    2)
      if bot_is_installed; then
        do_update_bot
      else
        warn "Бот не установлен — выбери пункт 1"
      fi
      ;;
    3)
      if bot_is_installed; then
        do_restart
      else
        warn "Бот не установлен"
      fi
      ;;
    4)
      do_status
      ;;
    5)
      if bot_is_installed; then
        do_logs
      else
        warn "Бот не установлен"
      fi
      ;;
    6)
      if bot_is_installed; then
        do_uninstall_bot
      else
        warn "Бот не установлен"
      fi
      ;;
    0)
      echo ""
      echo -e "${G}  До встречи!${N}"
      echo ""
      exit 0
      ;;
    *)
      warn "Неверный выбор"
      ;;
  esac
  echo ""
  read -rp "$(echo -e "${D}  Enter для возврата в меню...${N}")" _
done
