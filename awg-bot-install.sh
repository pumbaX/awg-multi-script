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

# ── Самообновление установщика с GitHub ──────────────────────────────────────
INSTALLER_URL="https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg-bot-install.sh"

# Тянет свежую версию ЭТОГО скрипта с GitHub и, если она новее/отличается,
# перезапускает её (с флагом-предохранителем против рекурсии). Код бота вшит
# в установщик, поэтому "обновить бота" = обновить установщик и применить его.
self_update_installer() {
  # Уже перезапущены после апдейта — второй раз не качаем (анти-рекурсия)
  if [[ "${AWG_BOT_SELFUPDATED:-0}" == "1" ]]; then
    return 0
  fi

  info "Проверяю свежую версию с GitHub..."
  local tmp
  tmp=$(mktemp /tmp/awg-bot-install.XXXXXX.sh) || { warn "mktemp не сработал — пропускаю самообновление"; return 0; }

  local http_code
  http_code=$(curl -fsSL -w "%{http_code}" "$INSTALLER_URL" -o "$tmp" 2>/dev/null || echo "000")

  if [[ "$http_code" != "200" ]]; then
    warn "GitHub недоступен (HTTP $http_code) — обновляю из текущего файла"
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  # Валидация: файл непустой, это bash-скрипт и синтаксис корректен
  if [[ ! -s "$tmp" ]] || ! head -1 "$tmp" | grep -q '^#!' || ! bash -n "$tmp" 2>/dev/null; then
    warn "Скачанный файл повреждён — обновляю из текущего файла"
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  # Сравниваем с собой — если идентично, качать смысла нет
  local self_path
  self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
  if [[ -f "$self_path" ]] && cmp -s "$tmp" "$self_path"; then
    ok "Уже последняя версия"
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  ok "Найдена свежая версия — перезапускаю её"
  chmod +x "$tmp" 2>/dev/null || true
  # Перезапускаем новую версию с тем же выбором меню (пункт 2 = Обновить),
  # флаг AWG_BOT_SELFUPDATED предотвращает повторное скачивание.
  AWG_BOT_SELFUPDATED=1 AWG_BOT_AUTO_CHOICE="2" bash "$tmp"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  exit $rc
}

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

  # Сначала подтягиваем свежий установщик с GitHub (если запущена старая версия —
  # этот вызов перезапустит новую и выйдет; сюда вернёмся уже в свежей версии).
  self_update_installer

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
  # При обновлении токен уже валиден, но username нужен для финального сообщения.
  # Делаем лёгкий getMe — при сетевой ошибке оставляем плейсхолдер.
  API_RESP=$(curl -sf "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || echo "")
  if echo "$API_RESP" | grep -q '"ok":true'; then
    BOT_USERNAME=$(echo "$API_RESP" | grep -oP '"username":"\K[^"]+')
  else
    BOT_USERNAME=""
  fi
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
import base64
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

# Expire-механика (срок действия клиентов)
EXPIRE_SUSPEND_IP = "127.0.0.2/32"

# ── Watchdog: сигнал когда клиент отваливается ───────────────────────────────
# Проверяем хендшейки клиентов и орём в Telegram, если онлайн-клиент пропал.
WATCHDOG_ENABLED   = True
WATCHDOG_INTERVAL  = 30      # как часто проверять, сек
WATCHDOG_OFFLINE   = 300     # нет хендшейка дольше этого = отвалился, сек (как 🔴)
WATCHDOG_GRACE     = 90      # после старта бота молчим столько сек (прогрев)

ADD_NAME, ADD_PROFILE, ADD_EXPIRE, ADD_EXPIRE_CUSTOM, EXPIRE_CUSTOM_EXISTING = range(5)

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
    # LC_ALL=C форсит английский вывод (иначе на русской локали "latest handshake"
    # парсится неверно и все клиенты показываются оффлайн).
    env = {**os.environ, "LC_ALL": "C", "LANG": "C"}
    r = subprocess.run(cmd, capture_output=True, text=True, input=input_str,
                       timeout=30, env=env)
    return r.returncode, r.stdout, r.stderr


def get_clients() -> list:
    """Список клиентов с кэшированием на 30 секунд.
    Парсит # name, # expires=<ts>, # orig_ips=<ip>.
    """
    cached = _clients_cache.get(CLIENTS_TTL)
    if cached is not None:
        return cached

    import glob as _glob
    clients = []
    if not Path(SERVER_CONF).exists():
        return clients

    name_map = {}
    for fpath in _glob.glob(CLIENTS_GLOB):
        try:
            fname = Path(fpath).stem.replace("_awg2", "")
            content = Path(fpath).read_text()
        except (OSError, UnicodeDecodeError) as e:
            log.warning(f"Не могу прочитать {fpath}: {e}")
            continue
        for line in content.splitlines():
            if line.startswith("PrivateKey"):
                priv = line.split("=", 1)[1].strip()
                rc, pub, _ = run(["awg", "pubkey"], input_str=priv)
                if rc == 0:
                    name_map[pub.strip()] = (fname, fpath)
                break

    try:
        content = Path(SERVER_CONF).read_text()
    except OSError as e:
        log.error(f"Не могу прочитать {SERVER_CONF}: {e}")
        return clients

    for peer in re.split(r"\[Peer\]", content)[1:]:
        pk_m   = re.search(r"^PublicKey\s*=\s*(.+)$",   peer, re.M)
        ip_m   = re.search(r"^AllowedIPs\s*=\s*(.+)$",  peer, re.M)
        # Имя — первый комментарий без "="
        name_m = re.search(r"^#\s+([^=\n]+?)\s*$",      peer, re.M)
        # Срок и оригинальный IP (служебные комментарии)
        exp_m  = re.search(r"^#\s*expires=(\d+)\s*$",   peer, re.M)
        orig_m = re.search(r"^#\s*orig_ips=(.+?)\s*$",  peer, re.M)
        # Заметка админа (произвольный текст, base64 чтобы не ломать конфиг)
        note_m = re.search(r"^#\s*note=(.*?)\s*$",      peer, re.M)
        if not pk_m:
            continue
        pk      = pk_m.group(1).strip()
        ip      = ip_m.group(1).strip() if ip_m else "?"
        comment = name_m.group(1).strip() if name_m else ""
        note    = ""
        if note_m:
            try:
                note = base64.b64decode(note_m.group(1).strip()).decode("utf-8", "replace")
            except Exception:
                note = ""
        name, fpath = name_map.get(pk, (comment or pk[:8], ""))
        client = {
            "name": name, "ip": ip, "pubkey": pk, "file": fpath,
            "expires": int(exp_m.group(1)) if exp_m else 0,
            "orig_ip": orig_m.group(1).strip() if orig_m else "",
            "note": note,
        }
        clients.append(client)

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

    info = {"ip": "?", "port": "?", "region": "world", "profile": "—", "iface_up": False}
    if not Path(SERVER_CONF).exists():
        return info

    for line in Path(SERVER_CONF).read_text().splitlines():
        if line.startswith("ListenPort"):
            info["port"] = line.split("=", 1)[1].strip()
        if "Region:" in line:
            info["region"] = line.split(":", 1)[1].strip()
        if line.startswith("# AWG_PROFILE="):
            info["profile"] = line.split("=", 1)[1].strip()

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
        # 1. Обновляем peers.list атомарно.
        #    ВАЖНО: awg2.sh хранит IP БЕЗ маски (срезает /32 в _warp_list_awg_clients
        #    и сверяет через grep -qxF). Если писать "10.x/32", синхронизация awg2
        #    посчитает запись «мёртвой» и удалит клиента из WARP. Поэтому в файл
        #    кладём голый IP — как делает awg2.
        existing = warp_get_peers()
        # Чистим обе формы (с /32 и без), чтобы не было дублей
        existing.discard(ip_only)
        existing.discard(cidr_ip)
        if enable:
            existing.add(ip_only)

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


# ══════════════════════════════════════════════════════════════════════════════
# Expire-механика: установить/снять срок, разблокировать
# ══════════════════════════════════════════════════════════════════════════════

def _expire_apply_syncconf() -> bool:
    """Применить изменения серверного конфига через awg syncconf (без рестарта)."""
    rc, strip_out, _ = run(["awg-quick", "strip", AWG_IFACE])
    if rc != 0:
        return False
    rc2, _, _ = run(["awg", "syncconf", AWG_IFACE, "/dev/stdin"], input_str=strip_out)
    return rc2 == 0


def expire_set(name: str, expires_ts: int) -> tuple:
    """Поставить срок клиенту. Возвращает (ok, msg).
    Минимум — 1 час от текущего момента."""
    now = int(time.time())
    if expires_ts <= now + 3540:
        return False, "Минимум 1 час от текущего момента"
    if not Path(SERVER_CONF).exists():
        return False, "Серверный конфиг не найден"

    try:
        text = Path(SERVER_CONF).read_text()
    except OSError as e:
        return False, f"read: {e}"

    parts  = re.split(r"(?=\[Peer\])", text)
    header = parts[0]
    peers  = parts[1:]

    found = False
    out_peers = []
    for block in peers:
        nm = re.search(r"^#\s+([^=\n]+?)\s*$", block, re.M)
        if nm and nm.group(1).strip() == name:
            found = True
            # Заменить или добавить # expires=
            if re.search(r"^#\s*expires=\d+\s*$", block, re.M):
                block = re.sub(r"^#\s*expires=\d+\s*$",
                               f"# expires={expires_ts}", block, count=1, flags=re.M)
            else:
                block = re.sub(
                    r"(^#\s+" + re.escape(name) + r"\s*$)",
                    lambda m: m.group(1) + f"\n# expires={expires_ts}",
                    block, count=1, flags=re.M
                )
        out_peers.append(block)

    if not found:
        return False, f"клиент {name} не найден"

    new_text = header + "".join(out_peers)
    try:
        d = os.path.dirname(SERVER_CONF)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".awg0.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(new_text)
            os.chmod(tmp, 0o600)
            os.rename(tmp, SERVER_CONF)
        except Exception:
            try: os.unlink(tmp)
            except Exception: pass
            raise
    except Exception as e:
        return False, f"write: {e}"

    _expire_apply_syncconf()  # не критично если не получилось — таймер подхватит

    # Сбросить warn1h флаг
    state_dir = Path("/var/lib/awg2-expire")
    if state_dir.exists():
        # pubkey по name
        c = next((x for x in get_clients() if x["name"] == name), None)
        if c:
            safe = re.sub(r"[^A-Za-z0-9]", "_", c["pubkey"])
            (state_dir / f"warn1h_{safe}").unlink(missing_ok=True)

    return True, "ok"


def expire_clear(name: str) -> tuple:
    """Снять срок. Если клиент был suspended — вернуть оригинальный IP."""
    if not Path(SERVER_CONF).exists():
        return False, "Серверный конфиг не найден"
    try:
        text = Path(SERVER_CONF).read_text()
    except OSError as e:
        return False, f"read: {e}"

    parts  = re.split(r"(?=\[Peer\])", text)
    header = parts[0]
    peers  = parts[1:]

    found = False
    out_peers = []
    for block in peers:
        nm = re.search(r"^#\s+([^=\n]+?)\s*$", block, re.M)
        if nm and nm.group(1).strip() == name:
            found = True
            orig_m = re.search(r"^#\s*orig_ips=(.+?)\s*$", block, re.M)
            aip_m  = re.search(r"^AllowedIPs\s*=\s*(.+?)\s*$", block, re.M)
            if orig_m and aip_m and aip_m.group(1).strip() == EXPIRE_SUSPEND_IP:
                block = re.sub(r"^(AllowedIPs\s*=\s*).+$",
                               r"\g<1>" + orig_m.group(1).strip(),
                               block, count=1, flags=re.M)
            block = re.sub(r"^#\s*expires=\d+\s*\n",   "", block, flags=re.M)
            block = re.sub(r"^#\s*orig_ips=.+?\s*\n",  "", block, flags=re.M)
        out_peers.append(block)

    if not found:
        return False, f"клиент {name} не найден"

    new_text = header + "".join(out_peers)
    try:
        d = os.path.dirname(SERVER_CONF)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".awg0.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(new_text)
            os.chmod(tmp, 0o600)
            os.rename(tmp, SERVER_CONF)
        except Exception:
            try: os.unlink(tmp)
            except Exception: pass
            raise
    except Exception as e:
        return False, f"write: {e}"

    _expire_apply_syncconf()
    return True, "ok"


def _normalize_note(text: str) -> str:
    """Если заметка похожа на адрес без схемы — подставляем http://.
    Иначе возвращаем как есть. Делает голые IP/домены кликабельными."""
    t = (text or "").strip()
    if not t:
        return t
    # Уже есть схема — не трогаем
    if re.match(r"^[a-z][a-z0-9+.-]*://", t, re.I):
        return t
    # Чистый адрес одним "словом" (без пробелов): IP[:port][/path] или домен[:port][/path]
    if " " not in t and re.match(
        r"^("
        r"\d{1,3}(\.\d{1,3}){3}"                 # IPv4
        r"|[a-z0-9-]+(\.[a-z0-9-]+)+"            # домен с точкой (example.net)
        r")"
        r"(:\d{1,5})?(/\S*)?$",
        t, re.I
    ):
        return "http://" + t
    return t


def note_set(name: str, note_text: str) -> tuple:
    """Записать заметку клиенту (произвольный текст, до 200 симв).
    Хранится в peer-блоке как # note=<base64> чтобы не ломать конфиг.
    Адреса без схемы (192.168.1.1, my.keenetic.net) дополняются http://."""
    note_text = _normalize_note(note_text)
    if len(note_text) > 200:
        return False, "Заметка слишком длинная (макс 200 символов)"
    if not Path(SERVER_CONF).exists():
        return False, "Серверный конфиг не найден"
    try:
        text = Path(SERVER_CONF).read_text()
    except OSError as e:
        return False, f"read: {e}"

    encoded = base64.b64encode(note_text.encode("utf-8")).decode("ascii")

    parts  = re.split(r"(?=\[Peer\])", text)
    header = parts[0]
    peers  = parts[1:]

    found = False
    out_peers = []
    for block in peers:
        nm = re.search(r"^#\s+([^=\n]+?)\s*$", block, re.M)
        if nm and nm.group(1).strip() == name:
            found = True
            if re.search(r"^#\s*note=.*$", block, re.M):
                block = re.sub(r"^#\s*note=.*$", f"# note={encoded}",
                               block, count=1, flags=re.M)
            else:
                # Вставляем после комментария-имени
                block = re.sub(
                    r"(^#\s+" + re.escape(name) + r"\s*$)",
                    lambda m: m.group(1) + f"\n# note={encoded}",
                    block, count=1, flags=re.M
                )
        out_peers.append(block)

    if not found:
        return False, f"клиент {name} не найден"

    new_text = header + "".join(out_peers)
    try:
        d = os.path.dirname(SERVER_CONF)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".awg0.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(new_text)
            os.chmod(tmp, 0o600)
            os.rename(tmp, SERVER_CONF)
        except Exception:
            try: os.unlink(tmp)
            except Exception: pass
            raise
    except Exception as e:
        return False, f"write: {e}"
    # Заметка — это только комментарий, syncconf не нужен (awg его игнорирует),
    # но конфиг изменён, поэтому инвалидируем кэш на стороне вызова.
    return True, "ok"


def note_clear(name: str) -> tuple:
    """Удалить заметку у клиента."""
    if not Path(SERVER_CONF).exists():
        return False, "Серверный конфиг не найден"
    try:
        text = Path(SERVER_CONF).read_text()
    except OSError as e:
        return False, f"read: {e}"

    parts  = re.split(r"(?=\[Peer\])", text)
    header = parts[0]
    peers  = parts[1:]

    found = False
    out_peers = []
    for block in peers:
        nm = re.search(r"^#\s+([^=\n]+?)\s*$", block, re.M)
        if nm and nm.group(1).strip() == name:
            found = True
            block = re.sub(r"^#\s*note=.*\n", "", block, flags=re.M)
        out_peers.append(block)

    if not found:
        return False, f"клиент {name} не найден"

    new_text = header + "".join(out_peers)
    try:
        d = os.path.dirname(SERVER_CONF)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".awg0.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(new_text)
            os.chmod(tmp, 0o600)
            os.rename(tmp, SERVER_CONF)
        except Exception:
            try: os.unlink(tmp)
            except Exception: pass
            raise
    except Exception as e:
        return False, f"write: {e}"
    return True, "ok"


def expire_fmt(ts: int) -> str:
    """Форматирование unix-ts в "DD.MM HH:MM (через 2д 5ч)"."""
    if not ts:
        return ""
    now  = int(time.time())
    diff = ts - now
    abs_d = abs(diff)
    d  = abs_d // 86400
    h  = (abs_d % 86400) // 3600
    m  = (abs_d % 3600) // 60
    parts = []
    if d > 0: parts.append(f"{d}д")
    if h > 0: parts.append(f"{h}ч")
    if not parts or (d == 0 and h == 0):
        parts.append(f"{m}м")
    human = " ".join(parts)
    try:
        when = time.strftime("%d.%m.%Y %H:%M", time.localtime(ts))
    except Exception:
        when = f"ts={ts}"
    if diff < 0:
        return f"{when} (истёк {human} назад)"
    return f"{when} (через {human})"


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


def plural_ru(n: int, one: str, few: str, many: str) -> str:
    """Склонение русских существительных по числу.
    Пример: plural_ru(5, 'клиент', 'клиента', 'клиентов') → 'клиентов'
    """
    n = abs(int(n))
    mod10 = n % 10
    mod100 = n % 100
    if mod10 == 1 and mod100 != 11:
        return one
    if 2 <= mod10 <= 4 and not (12 <= mod100 <= 14):
        return few
    return many


# ══════════════════════════════════════════════════════════════════════════════
# Клавиатуры — отдельный класс (как tu.InlineKeyboard в Go)
# ══════════════════════════════════════════════════════════════════════════════

class Keyboards:
    @staticmethod
    def main_reply() -> ReplyKeyboardMarkup:
        """Постоянная клавиатура снизу — главное меню."""
        return ReplyKeyboardMarkup([
            ["👥 Клиенты",          "📊 Статус"],
            ["➕ Добавить клиента", "🌐 DNS статус"],
            ["🔄 Restart awg0", "🌐 Restart DNS"],
        ], resize_keyboard=True)

    @staticmethod
    def back_to_clients() -> InlineKeyboardMarkup:
        """Только для контекста карточки клиента — назад к списку."""
        return InlineKeyboardMarkup([[
            InlineKeyboardButton("◀️ К списку клиентов", callback_data="clients")
        ]])

    @staticmethod
    def clients(clients: list, stats: dict) -> InlineKeyboardMarkup:
        # Группируем кнопки по 2 в ряд — компактнее при 5+ клиентах
        buttons = []
        for c in clients:
            icon = online_icon(stats.get(c["pubkey"], {}).get("last_hs", 0))
            buttons.append(InlineKeyboardButton(
                f"{icon} {c['name']}  {c['ip'].split('/')[0]}",
                callback_data=f"c:{c['name']}"
            ))
        rows = [buttons[i:i+2] for i in range(0, len(buttons), 2)]
        return InlineKeyboardMarkup(rows)

    @staticmethod
    def client_card(name: str, warp_on: bool = False,
                    has_expire: bool = False, is_suspended: bool = False,
                    has_note: bool = False) -> InlineKeyboardMarkup:
        warp_btn = (
            InlineKeyboardButton("☁️ Выкл WARP", callback_data=f"warpoff:{name}")
            if warp_on else
            InlineKeyboardButton("🌍 Вкл WARP",  callback_data=f"warpon:{name}")
        )
        # Кнопка срока меняется в зависимости от состояния
        if is_suspended:
            expire_btn = InlineKeyboardButton("🔓 Разблокировать", callback_data=f"expunban:{name}")
        elif has_expire:
            expire_btn = InlineKeyboardButton("⏰ Срок (изменить/снять)", callback_data=f"expire:{name}")
        else:
            expire_btn = InlineKeyboardButton("⏰ Установить срок", callback_data=f"expire:{name}")
        note_btn = InlineKeyboardButton(
            "📝 Заметка (изм/удалить)" if has_note else "📝 Добавить заметку",
            callback_data=f"note:{name}")
        return InlineKeyboardMarkup([
            [InlineKeyboardButton("📱 QR-код",      callback_data=f"qr:{name}"),
             InlineKeyboardButton("📄 Текст",        callback_data=f"conf:{name}")],
            [InlineKeyboardButton("📁 Файл .conf",  callback_data=f"file:{name}"),
             InlineKeyboardButton("🗑 Удалить",      callback_data=f"del:{name}")],
            [warp_btn],
            [expire_btn],
            [note_btn],
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
    def expire_presets(name: str, has_expire: bool = False) -> InlineKeyboardMarkup:
        """Клавиатура выбора срока действия (используется и в карточке, и при создании).
        В режиме создания клиента (передаём префикс 'expnew') — name это маркер ctx.
        В режиме редактирования (префикс 'expset') — реальное имя клиента.
        """
        prefix = "expset"  # выбор для существующего клиента
        rows = [
            [InlineKeyboardButton("1 час",   callback_data=f"{prefix}:{name}:1h"),
             InlineKeyboardButton("6 ч",     callback_data=f"{prefix}:{name}:6h"),
             InlineKeyboardButton("1 день",  callback_data=f"{prefix}:{name}:1d")],
            [InlineKeyboardButton("3 дня",   callback_data=f"{prefix}:{name}:3d"),
             InlineKeyboardButton("7 дней",  callback_data=f"{prefix}:{name}:7d"),
             InlineKeyboardButton("30 дней", callback_data=f"{prefix}:{name}:30d")],
            [InlineKeyboardButton("📅 Своя дата", callback_data=f"expcustom:{name}")],
        ]
        if has_expire:
            rows.append([InlineKeyboardButton("🚫 Снять срок (бессрочно)",
                                              callback_data=f"expclear:{name}")])
        rows.append([InlineKeyboardButton("◀️ Назад", callback_data=f"c:{name}")])
        return InlineKeyboardMarkup(rows)

    @staticmethod
    def expire_presets_at_creation() -> InlineKeyboardMarkup:
        """При создании клиента (после выбора профиля) — спрашиваем срок.
        callback prefix 'expnew' — без имени, обрабатывается через ctx.user_data."""
        return InlineKeyboardMarkup([
            [InlineKeyboardButton("♾ Бессрочно", callback_data="expnew:none")],
            [InlineKeyboardButton("1 час",  callback_data="expnew:1h"),
             InlineKeyboardButton("1 день", callback_data="expnew:1d"),
             InlineKeyboardButton("7 дней", callback_data="expnew:7d")],
            [InlineKeyboardButton("30 дней", callback_data="expnew:30d")],
            [InlineKeyboardButton("📅 Своя дата", callback_data="expnew:custom")],
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


def _parse_xfer_to_bytes(s: str) -> int:
    """'1.2 GiB' / '800 MiB' / '—' → байты (для сортировки топа)."""
    if not s or s == "—":
        return 0
    parts = s.split()
    if len(parts) < 2:
        return 0
    try:
        num = float(parts[0])
    except ValueError:
        return 0
    unit = parts[1].lower()
    mult = {
        "b": 1, "byte": 1, "bytes": 1,
        "kib": 1024, "kb": 1000,
        "mib": 1024**2, "mb": 1000**2,
        "gib": 1024**3, "gb": 1000**3,
        "tib": 1024**4, "tb": 1000**4,
    }.get(unit, 1)
    return int(num * mult)


def _fmt_short(b: int) -> str:
    """Компактный формат для топа: 1.2G / 800M / 450K."""
    if b >= 1024**3:
        return f"{b/1024**3:.1f}G"
    if b >= 1024**2:
        return f"{b/1024**2:.0f}M"
    if b >= 1024:
        return f"{b/1024:.0f}K"
    return f"{b}B"


def _status_system() -> dict:
    """Диск/RAM/load/uptime интерфейса awg0. Всё опционально."""
    d = {"disk": "—", "ram": "—", "load": "—", "awg_uptime": "—"}
    # Диск корня
    rc, out, _ = run(["bash", "-c",
        "df -h / | awk 'NR==2{print $3\" / \"$2\" · \"$5}'"])
    if rc == 0 and out.strip():
        d["disk"] = out.strip()
    # RAM
    rc, out, _ = run(["bash", "-c",
        "free -m | awk 'NR==2{printf \"%dM / %.0fG\", $3, $2/1024}'"])
    if rc == 0 and out.strip():
        d["ram"] = out.strip()
    # Load average (1 мин)
    rc, out, _ = run(["bash", "-c",
        "cut -d' ' -f1 /proc/loadavg"])
    if rc == 0 and out.strip():
        d["load"] = out.strip()
    # Аптайм интерфейса awg0 (по времени создания /sys)
    rc, out, _ = run(["bash", "-c",
        "awk '{u=$1} END{d=int(u/86400);h=int((u%86400)/3600);"
        "printf (d>0?\"%dд %dч\":\"%dч\"), (d>0?d:h), h}' /proc/uptime"])
    if rc == 0 and out.strip():
        d["awg_uptime"] = out.strip()
    return d


def _status_version() -> str:
    """Версия awg2 с сервера (/usr/local/bin/awg2)."""
    for p in ("/usr/local/bin/awg2", "/usr/bin/awg2"):
        try:
            for line in Path(p).read_text().splitlines()[:10]:
                if line.startswith("VERSION="):
                    return line.split("=", 1)[1].strip().strip('"')
        except OSError:
            continue
    return "—"


def _status_dns() -> str:
    """Краткий DNS-чек по образцу awg2: жив ли dnscrypt-proxy + есть ли DNAT.
    Резолвер awg2 слушает на 127.0.2.1:53 (не 127.0.0.1)."""
    # dnscrypt-proxy активен?
    rc, _, _ = run(["systemctl", "is-active", "--quiet", "dnscrypt-proxy"])
    if rc == 0:
        resolver = "✓"
    else:
        # Возможно резолвер вообще не настроен — проверим что хоть кто-то на :53
        rc2, out2, _ = run(["bash", "-c", "ss -ulnp 2>/dev/null | grep -c ':53 '"])
        resolver = "✓" if (rc2 == 0 and out2.strip() not in ("", "0")) else "✗"
    # DNAT-правило awg0 → резолвер
    rc, out, _ = run(["bash", "-c",
        "iptables -t nat -S PREROUTING 2>/dev/null | grep -c 'dport 53'"])
    dnat = "✓" if (rc == 0 and out.strip() not in ("", "0")) else "—"
    return f"резолвер {resolver} · DNAT {dnat}"


def text_status() -> str:
    info    = get_server_info()
    clients = get_clients()
    stats   = get_live_stats()
    now     = int(time.time())

    online  = sum(
        1 for c in clients
        if stats.get(c["pubkey"], {}).get("last_hs", 0)
        and (now - stats[c["pubkey"]]["last_hs"]) < 300
    )

    # Суммарный трафик
    rc, out, _ = run(["awg", "show", AWG_IFACE, "transfer"])
    rx = tx = 0
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3:
            try:
                rx += int(p[1]); tx += int(p[2])
            except ValueError:
                pass

    # Сроки: всего со сроком / заблокировано / истекает за 24ч
    n_exp = n_blocked = n_soon = 0
    for c in clients:
        e = c.get("expires", 0)
        if not e:
            continue
        n_exp += 1
        if c.get("orig_ip"):
            n_blocked += 1
        elif 0 < (e - now) <= 86400:
            n_soon += 1

    # Топ-3 по трафику (rx+tx) из live-статы
    traf = []
    for c in clients:
        s = stats.get(c["pubkey"], {})
        total = _parse_xfer_to_bytes(s.get("rx", "—")) + _parse_xfer_to_bytes(s.get("tx", "—"))
        if total > 0:
            traf.append((c["name"], total))
    traf.sort(key=lambda x: x[1], reverse=True)
    top = traf[:3]

    # WARP
    if warp_available():
        warp_line = f"{len(warp_get_peers())} кл · warp0 ✓"
    else:
        warp_line = "не настроен"

    sysd = _status_system()
    ver  = _status_version()
    dns  = _status_dns()

    # Индикатор здоровья
    health = "🟢 всё ок"
    disk_pct = 0
    m = re.search(r"(\d+)%", sysd.get("disk", ""))
    if m:
        disk_pct = int(m.group(1))
    if not info["iface_up"] or disk_pct >= 90 or (online == 0 and len(clients) > 0):
        health = "🔴 проблема"
    elif disk_pct >= 75 or n_soon > 0 or "✗" in dns:
        health = "🟡 внимание"

    status_word = "активен" if info["iface_up"] else "остановлен"
    prof_raw = info.get("profile", "—")
    prof_label = {"lite": "Lite", "standard": "Standard", "pro": "Pro"}.get(
        prof_raw, prof_raw if prof_raw != "—" else "—")

    # Сборка карточки (эмодзи слева, моноширинный блок)
    lines = []
    lines.append(f"📊 Статус · {health}")
    lines.append("━━━━━━━━━━━━━━━━━━━━━")
    lines.append(f"🖥 Сервер   {info['ip']}:{info['port']}")
    lines.append(f"📡 awg0     {status_word} · {sysd['awg_uptime']}")
    lines.append(f"🎭 Профиль  {prof_label}")
    lines.append("")
    lines.append(f"👥 Клиенты  {len(clients)} · {online} онлайн")
    if n_exp:
        lines.append(f"⏰ Срок     {n_exp} · 🚫{n_blocked} · ⚠️{n_soon} за 24ч")
    lines.append("")
    lines.append(f"📈 Трафик   ↓ {fmt_bytes(rx)} · ↑ {fmt_bytes(tx)}")
    if top:
        first = top[0]
        lines.append(f"🔝 Топ      {first[0]} {_fmt_short(first[1])}")
        for name, b in top[1:]:
            lines.append(f"            {name} {_fmt_short(b)}")
    lines.append("")
    lines.append(f"☁️ WARP     {warp_line}")
    lines.append(f"🌐 DNS      {dns}")
    lines.append("")
    lines.append(f"💾 Диск     {sysd['disk']}")
    lines.append(f"🧠 RAM      {sysd['ram']} · LB {sysd['load']}")
    lines.append(f"🔖 Версия   {ver}")

    body = "\n".join(lines)
    return f"<pre>{_html.escape(body)}</pre>"


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
    # Срок действия
    expire_line = ""
    exp_ts  = c.get("expires", 0)
    orig_ip = c.get("orig_ip", "")
    if exp_ts:
        if orig_ip:
            # Заблокирован
            expire_line = f"\n🚫 <b>Заблокирован</b> (срок истёк)\n   {expire_fmt(exp_ts)}"
        else:
            expire_line = f"\n⏰ Истекает: {expire_fmt(exp_ts)}"
    # Заметка админа
    note_line = ""
    note = c.get("note", "")
    if note:
        esc = _html.escape(note)
        # Если заметка — это URL, делаем кликабельной
        if re.match(r"^https?://\S+$", note):
            note_line = f'\n📝 <a href="{esc}">{esc}</a>'
        else:
            note_line = f"\n📝 {esc}"
    return (
        f"👤 <b>{c['name']}</b>\n━━━━━━━━━━━━━━━━━━\n"
        f"🌐 IP: <code>{c['ip']}</code>\n"
        f"{online_icon(hs)} {elapsed_str(hs)}\n"
        f"↓ {s.get('rx', '—')}  ↑ {s.get('tx', '—')}"
        f"{warp_line}"
        f"{expire_line}"
        f"{note_line}"
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
        "• 🔄 <b>Restart awg0</b> — рестарт VPN-туннеля\n"
        "• 🌐 <b>Restart DNS</b> — рестарт dnscrypt-proxy\n"
        "• 🌐 <b>DNS статус</b> — резолверы, DNAT, persistence"
    )
    await update.message.reply_text(text, parse_mode=ParseMode.HTML)


@auth
async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    _status_cache.invalidate()
    _live_stats_cache.invalidate()
    msg = await update.message.reply_text("⏳ Собираю статус...")
    text_out = await asyncio.to_thread(text_status)
    await msg.edit_text(
        text_out, parse_mode=ParseMode.HTML,
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
            "c":        _cb_client_card,
            "qr":       _cb_client_qr,
            "conf":     _cb_client_conf,
            "file":     _cb_client_file,
            "del":      _cb_client_del_confirm,
            "delok":    _cb_client_del,
            "warpon":   _cb_warp_on,
            "warpoff":  _cb_warp_off,
            "expire":   _cb_expire_menu,
            "expset":   _cb_expire_set,       # payload = "NAME:DURATION"
            "expclear": _cb_expire_clear,
            "expunban": _cb_expire_unban,
            "expcustom": _cb_expire_custom_start,
            "note":      _cb_note_menu,
            "noteclear": _cb_note_clear,
        }
        handler = dispatch.get(prefix)
        if handler:
            await handler(q, payload, ctx)
        # expnew:* — обрабатывается через ConversationHandler (ADD_EXPIRE / ADD_EXPIRE_CUSTOM)
        elif prefix == "expnew":
            pass
        elif prefix not in ("prof",):  # prof обрабатывается ConversationHandler-ом
            log.warning(f"Неизвестный callback prefix: {prefix!r}")


# ── вспомогательные колбэк-функции ────────────────────────────────────────────

def _client_card_kb(name: str) -> InlineKeyboardMarkup:
    """Клавиатура карточки клиента с актуальным WARP-статусом и состоянием срока."""
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        return kb.client_card(name, warp_on=False, has_expire=False, is_suspended=False)
    warp_on = warp_available() and warp_is_enabled_for(c["ip"])
    has_expire   = bool(c.get("expires", 0))
    is_suspended = has_expire and bool(c.get("orig_ip", ""))
    has_note     = bool(c.get("note", ""))
    return kb.client_card(name, warp_on=warp_on,
                          has_expire=has_expire, is_suspended=is_suspended,
                          has_note=has_note)


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
    await q.edit_message_text("⏳ Собираю статус...")
    text_out = await asyncio.to_thread(text_status)
    await q.edit_message_text(
        text_out, parse_mode=ParseMode.HTML,
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


async def _cb_client_card(q, name: str, ctx):
    # Сбросить флаги ожидания ввода, если пользователь вернулся в карточку
    if ctx and hasattr(ctx, "user_data"):
        ctx.user_data.pop("awaiting_custom_expire", None)
        ctx.user_data.pop("awaiting_note", None)
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


# ══════════════════════════════════════════════════════════════════════════════
# Expire-колбэки
# ══════════════════════════════════════════════════════════════════════════════

_DURATION_MAP = {
    "1h":  3600,
    "6h":  6 * 3600,
    "1d":  86400,
    "3d":  3 * 86400,
    "7d":  7 * 86400,
    "30d": 30 * 86400,
}


def parse_custom_expire(text: str) -> Optional[int]:
    """Парсит пользовательский ввод и возвращает unix-ts (>= now+1h, <= now+2y).
    Принимаемые форматы:
      Относительные: "+2h", "2h", "+90m", "+3d", "+2w"
      Дата+время:    "2026-05-28 18:30", "28.05.2026 18:30", "28.05 18:30" (текущий год)
    Возвращает None если не распознано или вне диапазона.
    """
    s = (text or "").strip().lower().replace("в ", " ")
    if not s:
        return None
    now = int(time.time())
    min_ts = now + 3540          # +1 час минус буфер 1 мин
    max_ts = now + 2 * 365 * 86400  # +2 года максимум

    # Относительное: +Nh / +Nd / +Nw / +Nm (минуты)
    m = re.match(r"^\+?\s*(\d+)\s*([mhdw])$", s)
    if m:
        n = int(m.group(1))
        unit = m.group(2)
        mult = {"m": 60, "h": 3600, "d": 86400, "w": 7 * 86400}[unit]
        ts = now + n * mult
        return ts if min_ts <= ts <= max_ts else None

    # Дата+время в нескольких форматах
    fmts = [
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%d.%m.%Y %H:%M",
        "%d.%m.%Y %H:%M:%S",
        "%d.%m %H:%M",
        "%d/%m/%Y %H:%M",
    ]
    cur_year = time.localtime(now).tm_year
    for fmt in fmts:
        try:
            t = time.strptime(s, fmt)
            # Если в формате нет года — подставляем текущий
            if "%Y" not in fmt:
                t = time.struct_time((cur_year, t.tm_mon, t.tm_mday,
                                      t.tm_hour, t.tm_min, t.tm_sec,
                                      0, 0, -1))
            ts = int(time.mktime(t))
            if min_ts <= ts <= max_ts:
                return ts
        except (ValueError, OverflowError):
            continue
    return None


async def _cb_expire_menu(q, name: str, _ctx):
    """Открыть меню срока для существующего клиента."""
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        await q.edit_message_text("❌ Клиент не найден")
        return
    has_expire = bool(c.get("expires", 0))
    if has_expire:
        text = (
            f"⏰ <b>Срок действия: {name}</b>\n"
            f"━━━━━━━━━━━━━━━━━━\n"
            f"Текущий: {expire_fmt(c['expires'])}\n\n"
            f"Выбери новый или сними срок:"
        )
    else:
        text = (
            f"⏰ <b>Установить срок: {name}</b>\n"
            f"━━━━━━━━━━━━━━━━━━\n"
            f"Сейчас клиент бессрочный.\n"
            f"Выбери срок действия:"
        )
    await q.edit_message_text(
        text, parse_mode=ParseMode.HTML,
        reply_markup=kb.expire_presets(name, has_expire=has_expire)
    )


async def _cb_expire_set(q, payload: str, ctx):
    """payload = 'NAME:DURATION' (например 'alice:7d')."""
    if ":" not in payload:
        await q.edit_message_text("❌ Неверный payload")
        return
    name, duration = payload.split(":", 1)
    duration = duration.strip()
    sec = _DURATION_MAP.get(duration)
    if not sec:
        await q.edit_message_text(f"❌ Неизвестный пресет: {duration}")
        return
    ts = int(time.time()) + sec
    admin_id = ctx.bot_data.get("admin_id", "")

    await q.edit_message_text(
        f"⏳ Ставлю срок {duration} для <b>{name}</b>...",
        parse_mode=ParseMode.HTML
    )
    ok_flag, msg = await asyncio.to_thread(expire_set, name, ts)
    _clients_cache.invalidate()

    if not ok_flag:
        await q.edit_message_text(
            f"❌ Ошибка: {_html.escape(msg)}",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
        return

    log.info(f"expire set: {name} → {expire_fmt(ts)} admin={admin_id}")
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if c:
        await q.edit_message_text(
            text_client_card(c), parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
    else:
        await q.edit_message_text(f"✅ Срок установлен: {expire_fmt(ts)}")


async def _cb_expire_clear(q, name: str, ctx):
    """Снять срок с клиента."""
    admin_id = ctx.bot_data.get("admin_id", "")
    await q.edit_message_text(
        f"⏳ Снимаю срок с <b>{name}</b>...",
        parse_mode=ParseMode.HTML
    )
    ok_flag, msg = await asyncio.to_thread(expire_clear, name)
    _clients_cache.invalidate()

    if not ok_flag:
        await q.edit_message_text(
            f"❌ Ошибка: {_html.escape(msg)}",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
        return

    log.info(f"expire clear: {name} admin={admin_id}")
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if c:
        await q.edit_message_text(
            text_client_card(c), parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
    else:
        await q.edit_message_text("✅ Срок снят — клиент бессрочный")


async def _cb_expire_unban(q, name: str, ctx):
    """Разблокировать просроченного клиента (вернуть IP)."""
    admin_id = ctx.bot_data.get("admin_id", "")
    await q.edit_message_text(
        f"⏳ Разблокирую <b>{name}</b>...",
        parse_mode=ParseMode.HTML
    )
    # Разблокировка = clear (вернёт orig_ips, удалит expires)
    ok_flag, msg = await asyncio.to_thread(expire_clear, name)
    _clients_cache.invalidate()

    if not ok_flag:
        await q.edit_message_text(
            f"❌ Ошибка: {_html.escape(msg)}",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
        return

    log.info(f"expire unban: {name} admin={admin_id}")
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if c:
        await q.edit_message_text(
            f"🔓 <b>{name}</b> разблокирован\nIP: <code>{c['ip']}</code>",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
    else:
        await q.edit_message_text("🔓 Разблокирован")


async def _cb_expire_custom_start(q, name: str, ctx):
    """Запрос ввода своей даты для существующего клиента.
    Дальше сообщение поймает handle_any_message через флаг user_data."""
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        await q.edit_message_text("❌ Клиент не найден")
        return
    # Ставим флаг — следующее текстовое сообщение интерпретируем как дату
    ctx.user_data["awaiting_custom_expire"] = name
    cancel_kb = InlineKeyboardMarkup([[
        InlineKeyboardButton("❌ Отмена", callback_data=f"c:{name}")
    ]])
    await q.edit_message_text(
        f"📅 <b>Своя дата для {name}</b>\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"Введи срок в одном из форматов:\n\n"
        f"<b>Относительный:</b>\n"
        f"  <code>+2h</code> — через 2 часа\n"
        f"  <code>+90m</code> — через 90 минут\n"
        f"  <code>+3d</code> — через 3 дня\n"
        f"  <code>+2w</code> — через 2 недели\n\n"
        f"<b>Точная дата (МСК):</b>\n"
        f"  <code>28.05.2026 18:30</code>\n"
        f"  <code>2026-05-28 18:30</code>\n"
        f"  <code>28.05 18:30</code> (текущий год)\n\n"
        f"<i>Минимум — 1 час от сейчас, максимум — 2 года.</i>",
        parse_mode=ParseMode.HTML,
        reply_markup=cancel_kb
    )


async def _cb_note_menu(q, name: str, ctx):
    """Меню заметки: показать текущую + кнопки изменить/удалить, либо запрос ввода."""
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if not c:
        await q.edit_message_text("❌ Клиент не найден")
        return
    cur = c.get("note", "")
    # Ставим флаг ожидания ввода текста заметки
    if ctx and hasattr(ctx, "user_data"):
        ctx.user_data["awaiting_note"] = name

    if cur:
        rows = [
            [InlineKeyboardButton("🗑 Удалить заметку", callback_data=f"noteclear:{name}")],
            [InlineKeyboardButton("◀️ Отмена", callback_data=f"c:{name}")],
        ]
        body = (
            f"📝 <b>Заметка: {name}</b>\n"
            f"━━━━━━━━━━━━━━━━━━\n"
            f"Текущая:\n{_html.escape(cur)}\n\n"
            f"Чтобы изменить — пришли новый текст сообщением.\n"
            f"Или удали / отмени кнопкой ниже."
        )
    else:
        rows = [[InlineKeyboardButton("◀️ Отмена", callback_data=f"c:{name}")]]
        body = (
            f"📝 <b>Заметка: {name}</b>\n"
            f"━━━━━━━━━━━━━━━━━━\n"
            f"Пришли текст заметки сообщением.\n"
            f"Например: <code>http://192.168.1.1</code> или "
            f"<code>Кинетик, admin/12345</code>\n\n"
            f"<i>До 200 символов. URL станет кликабельным.</i>"
        )
    await q.edit_message_text(
        body, parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(rows),
        disable_web_page_preview=True
    )


async def _cb_note_clear(q, name: str, ctx):
    """Удалить заметку."""
    if ctx and hasattr(ctx, "user_data"):
        ctx.user_data.pop("awaiting_note", None)
    ok_flag, msg = await asyncio.to_thread(note_clear, name)
    _clients_cache.invalidate()
    if not ok_flag:
        await q.edit_message_text(
            f"❌ Ошибка: {_html.escape(msg)}",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
        return
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if c:
        await q.edit_message_text(
            text_client_card(c), parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name),
            disable_web_page_preview=True
        )
    else:
        await q.edit_message_text("🗑 Заметка удалена")


async def _apply_custom_expire_to_existing(update: Update, name: str, ts: int):
    """Применить дату ts к существующему клиенту name."""
    ok_flag, msg = await asyncio.to_thread(expire_set, name, ts)
    _clients_cache.invalidate()
    if not ok_flag:
        await update.message.reply_text(
            f"❌ Ошибка: {_html.escape(msg)}",
            parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
        return
    log.info(f"expire custom set: {name} → {expire_fmt(ts)}")
    clients = get_clients()
    c = next((x for x in clients if x["name"] == name), None)
    if c:
        await update.message.reply_text(
            text_client_card(c), parse_mode=ParseMode.HTML,
            reply_markup=_client_card_kb(name)
        )
    else:
        await update.message.reply_text(
            f"✅ Срок установлен: {expire_fmt(ts)}", parse_mode=ParseMode.HTML
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
        # Запоминаем имя для следующего шага и показываем выбор срока
        ctx.user_data["new_name"] = name
        await q.edit_message_text(
            f"✅ <b>{name}</b> создан!\n{msg}\n\n"
            f"⏰ <b>Срок действия?</b>",
            parse_mode=ParseMode.HTML,
            reply_markup=kb.expire_presets_at_creation()
        )
        return ADD_EXPIRE
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

    # Читаем профиль сервера — для Lite/Standard выбор мимикрии фиксирован
    srv_profile = get_server_info().get("profile", "—")
    auto_profile = None
    if srv_profile == "lite":
        auto_profile = "dns"       # Lite: I1 = DNS (как в скрипте)
    elif srv_profile == "standard":
        auto_profile = "quic"      # Standard: I1 = QUIC

    if auto_profile is not None:
        # Создаём сразу без меню — профиль зашит в серверный пресет
        msg_obj = await update.message.reply_text(
            f"👤 Имя: <b>{name}</b>\n"
            f"⚙ Сервер: <b>{srv_profile.capitalize()}</b> → мимикрия зафиксирована\n"
            f"⏳ Создаю...",
            parse_mode=ParseMode.HTML,
        )
        admin_id = ctx.bot_data.get("admin_id", "")

        global _add_client_lock
        if _add_client_lock is None:
            _add_client_lock = asyncio.Lock()

        async with _add_client_lock:
            client_path = Path(f"/root/{name}_awg2.conf")
            if client_path.exists():
                _clients_cache.invalidate()
                existing = {c["name"] for c in get_clients()}
                if name in existing:
                    await msg_obj.edit_text(
                        f"❌ <b>{name}</b> уже существует.",
                        parse_mode=ParseMode.HTML,
                    )
                    return ConversationHandler.END
                log.warning(f"Удаляю осиротевший файл: {client_path}")
                client_path.unlink()

            ok_flag, result_msg = await asyncio.to_thread(
                add_client, name, auto_profile, admin_id
            )
            _clients_cache.invalidate()

        if ok_flag:
            # Запоминаем имя для шага выбора срока
            ctx.user_data["new_name"] = name
            await msg_obj.edit_text(
                f"✅ <b>{name}</b> создан!\n{result_msg}\n\n"
                f"⏰ <b>Срок действия?</b>",
                parse_mode=ParseMode.HTML,
                reply_markup=kb.expire_presets_at_creation()
            )
            return ADD_EXPIRE
        else:
            await msg_obj.edit_text(
                f"❌ Ошибка:\n<code>{_html.escape(result_msg)}</code>",
                parse_mode=ParseMode.HTML,
            )
            return ConversationHandler.END

    # Pro / неизвестный профиль — показываем меню как раньше
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
async def on_add_expire_choice(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Выбор срока при создании клиента. payload: expnew:none|1h|...|custom"""
    q = update.callback_query
    await q.answer()
    name = ctx.user_data.get("new_name", "")
    if not name:
        ctx.user_data.clear()
        await q.edit_message_text("❌ Имя не задано")
        return ConversationHandler.END

    payload = q.data.split(":", 1)[1] if ":" in q.data else "none"

    final_kb = InlineKeyboardMarkup([[
        InlineKeyboardButton("👥 К клиентам", callback_data="clients")
    ]])

    if payload == "custom":
        # Запрашиваем ввод даты — переходим в новый state
        cancel_kb = InlineKeyboardMarkup([[
            InlineKeyboardButton("♾ Бессрочно", callback_data="expnew:none")
        ]])
        await q.edit_message_text(
            f"📅 <b>Своя дата для {name}</b>\n"
            f"━━━━━━━━━━━━━━━━━━\n"
            f"Введи срок в одном из форматов:\n\n"
            f"<b>Относительный:</b>\n"
            f"  <code>+2h</code> — через 2 часа\n"
            f"  <code>+90m</code> — через 90 минут\n"
            f"  <code>+3d</code> — через 3 дня\n"
            f"  <code>+2w</code> — через 2 недели\n\n"
            f"<b>Точная дата (МСК):</b>\n"
            f"  <code>28.05.2026 18:30</code>\n"
            f"  <code>2026-05-28 18:30</code>\n"
            f"  <code>28.05 18:30</code> (текущий год)\n\n"
            f"<i>Минимум — 1 час, максимум — 2 года.</i>\n"
            f"Или жми «Бессрочно» чтобы пропустить:",
            parse_mode=ParseMode.HTML,
            reply_markup=cancel_kb
        )
        return ADD_EXPIRE_CUSTOM

    # Остальные пресеты — как раньше
    ctx.user_data.clear()

    if payload == "none":
        await q.edit_message_text(
            f"✅ <b>{name}</b> создан\n♾ Срок: бессрочно",
            parse_mode=ParseMode.HTML,
            reply_markup=final_kb
        )
        return ConversationHandler.END

    sec = _DURATION_MAP.get(payload)
    if not sec:
        await q.edit_message_text(
            f"⚠️ <b>{name}</b> создан, но срок не распознан ({payload})\nКлиент бессрочный.",
            parse_mode=ParseMode.HTML,
            reply_markup=final_kb
        )
        return ConversationHandler.END

    ts = int(time.time()) + sec
    ok_flag, msg = await asyncio.to_thread(expire_set, name, ts)
    _clients_cache.invalidate()

    if ok_flag:
        log.info(f"new client {name} → expire {expire_fmt(ts)}")
        await q.edit_message_text(
            f"✅ <b>{name}</b> создан\n⏰ Срок: {expire_fmt(ts)}",
            parse_mode=ParseMode.HTML,
            reply_markup=final_kb
        )
    else:
        await q.edit_message_text(
            f"⚠️ <b>{name}</b> создан, но срок не установлен:\n<code>{_html.escape(msg)}</code>\n"
            f"Клиент будет бессрочным.",
            parse_mode=ParseMode.HTML,
            reply_markup=final_kb
        )
    return ConversationHandler.END


@auth
async def on_add_expire_custom_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Пользователь ввёл текст с датой во время создания клиента (ADD_EXPIRE_CUSTOM)."""
    name = ctx.user_data.get("new_name", "")
    if not name:
        ctx.user_data.clear()
        await update.message.reply_text("❌ Сессия потеряна")
        return ConversationHandler.END

    text = (update.message.text or "").strip()
    ts = parse_custom_expire(text)

    final_kb = InlineKeyboardMarkup([[
        InlineKeyboardButton("👥 К клиентам", callback_data="clients")
    ]])

    if ts is None:
        retry_kb = InlineKeyboardMarkup([[
            InlineKeyboardButton("♾ Бессрочно (пропустить)", callback_data="expnew:none")
        ]])
        await update.message.reply_text(
            f"❌ Не распознано: <code>{_html.escape(text)}</code>\n"
            f"Попробуй ещё раз (или нажми Бессрочно):\n\n"
            f"Примеры: <code>+2h</code>, <code>+3d</code>, "
            f"<code>28.05.2026 18:30</code>",
            parse_mode=ParseMode.HTML,
            reply_markup=retry_kb
        )
        return ADD_EXPIRE_CUSTOM

    ctx.user_data.clear()
    ok_flag, msg = await asyncio.to_thread(expire_set, name, ts)
    _clients_cache.invalidate()

    if ok_flag:
        log.info(f"new client {name} → expire custom {expire_fmt(ts)}")
        await update.message.reply_text(
            f"✅ <b>{name}</b> создан\n⏰ Срок: {expire_fmt(ts)}",
            parse_mode=ParseMode.HTML,
            reply_markup=final_kb
        )
    else:
        await update.message.reply_text(
            f"⚠️ <b>{name}</b> создан, но срок не установлен:\n<code>{_html.escape(msg)}</code>",
            parse_mode=ParseMode.HTML,
            reply_markup=final_kb
        )
    return ConversationHandler.END


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
    """Обработчик кнопок Reply Keyboard снизу + ввод своей даты для срока."""
    text = (update.message.text or "").strip()

    # Перехват ввода даты для существующего клиента (см. _cb_expire_custom_start)
    pending_name = ctx.user_data.get("awaiting_custom_expire")
    if pending_name:
        ts = parse_custom_expire(text)
        if ts is None:
            await update.message.reply_text(
                f"❌ Не распознано: <code>{_html.escape(text)}</code>\n"
                f"Примеры: <code>+2h</code>, <code>+3d</code>, "
                f"<code>28.05.2026 18:30</code>\n"
                f"Жми отмену в карточке клиента чтобы выйти.",
                parse_mode=ParseMode.HTML
            )
            return
        # Применяем
        ctx.user_data.pop("awaiting_custom_expire", None)
        await _apply_custom_expire_to_existing(update, pending_name, ts)
        return

    # Перехват ввода текста заметки (см. _cb_note_menu)
    note_name = ctx.user_data.get("awaiting_note")
    if note_name:
        ctx.user_data.pop("awaiting_note", None)
        if len(text) > 200:
            await update.message.reply_text(
                "❌ Заметка слишком длинная (макс 200 символов). Попробуй короче.",
            )
            ctx.user_data["awaiting_note"] = note_name  # остаёмся в режиме ввода
            return
        ok_flag, msg = await asyncio.to_thread(note_set, note_name, text)
        _clients_cache.invalidate()
        if not ok_flag:
            await update.message.reply_text(
                f"❌ Ошибка: {_html.escape(msg)}",
                parse_mode=ParseMode.HTML,
                reply_markup=_client_card_kb(note_name)
            )
            return
        clients = get_clients()
        c = next((x for x in clients if x["name"] == note_name), None)
        if c:
            await update.message.reply_text(
                text_client_card(c), parse_mode=ParseMode.HTML,
                reply_markup=_client_card_kb(note_name),
                disable_web_page_preview=True
            )
        else:
            await update.message.reply_text("✅ Заметка сохранена")
        return

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
        msg = await update.message.reply_text("⏳ Собираю статус...")
        text_out = await asyncio.to_thread(text_status)
        await msg.edit_text(
            text_out, parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("🔄 Обновить", callback_data="status")
            ]])
        )

    elif text == "🔄 Restart awg0":
        msg = await update.message.reply_text("⏳ Перезапускаю awg0...")
        await asyncio.to_thread(run, ["awg-quick", "down", SERVER_CONF])
        await asyncio.sleep(1)
        rc, _, err = await asyncio.to_thread(run, ["awg-quick", "up", SERVER_CONF])
        _status_cache.invalidate()
        _live_stats_cache.invalidate()
        result = "✅ awg0 перезапущен" if rc == 0 else f"❌ Ошибка:\n<code>{_html.escape(err[:200])}</code>"
        await msg.edit_text(result, parse_mode=ParseMode.HTML)

    elif text == "🌐 Restart DNS":
        msg = await update.message.reply_text("⏳ Перезагружаю dnscrypt-proxy...")
        # Проверяем что сервис существует (dnscrypt-proxy опционален — пункт 16 awg2)
        rc_check, _, _ = await asyncio.to_thread(
            run, ["systemctl", "is-active", "--quiet", "dnscrypt-proxy"]
        )
        if rc_check != 0:
            await msg.edit_text(
                "⚠️ dnscrypt-proxy не запущен или не установлен.\n"
                "Включи его в <code>awg2</code> → пункт 16.",
                parse_mode=ParseMode.HTML
            )
            return
        # Перезапуск
        rc, _, err = await asyncio.to_thread(
            run, ["systemctl", "restart", "dnscrypt-proxy"]
        )
        await asyncio.sleep(2)
        # Контроль что поднялся
        rc_after, _, _ = await asyncio.to_thread(
            run, ["systemctl", "is-active", "--quiet", "dnscrypt-proxy"]
        )
        if rc == 0 and rc_after == 0:
            await msg.edit_text("✅ DNS перезагружен")
        else:
            err_text = err[:200] if err else "сервис не поднялся после перезапуска"
            await msg.edit_text(
                f"❌ Ошибка:\n<code>{_html.escape(err_text)}</code>",
                parse_mode=ParseMode.HTML
            )

    elif text == "🌐 DNS статус":
        msg = await update.message.reply_text("⏳ Собираю статус DNS...")
        # 1. Установлен ли вообще
        rc_inst, _, _ = await asyncio.to_thread(
            run, ["which", "dnscrypt-proxy"]
        )
        if rc_inst != 0:
            await msg.edit_text(
                "🌐 <b>DNS статус</b>\n━━━━━━━━━━━━━━━━━━\n"
                "○ <b>не установлен</b>\n\n"
                "Активные DNS — из awg0 (DNS=… в конфиге, обычно 1.1.1.1).\n"
                "Чтобы включить шифрованный DNS — <code>awg2</code> → пункт 16.",
                parse_mode=ParseMode.HTML
            )
            return
        # 2. Активен ли
        rc_act, _, _ = await asyncio.to_thread(
            run, ["systemctl", "is-active", "--quiet", "dnscrypt-proxy"]
        )
        active = rc_act == 0
        # 3. Резолверы из конфига
        servers = "—"
        try:
            with open("/etc/dnscrypt-proxy/dnscrypt-proxy.toml") as f:
                for line in f:
                    s = line.strip()
                    if s.startswith("server_names"):
                        # server_names = ['cloudflare', 'quad9-dnscrypt-ip4-nofilter-pri']
                        val = s.split("=", 1)[1].strip()
                        val = val.strip("[]").replace("'", "").replace('"', "")
                        servers = val.strip()
                        break
        except (OSError, IndexError):
            pass
        # 4. DNAT правило (iptables)
        rc_dnat, _, _ = await asyncio.to_thread(run, [
            "iptables", "-t", "nat", "-C", "PREROUTING",
            "-i", "awg0", "-p", "udp", "--dport", "53",
            "-j", "DNAT", "--to-destination", "127.0.2.1:53"
        ])
        dnat_ok = rc_dnat == 0
        # 5. Persistence (переживёт reboot)
        rc_persist, _, _ = await asyncio.to_thread(
            run, ["systemctl", "is-enabled", "--quiet", "awg-dns-persist.service"]
        )
        persist_ok = rc_persist == 0
        # 6. Healthcheck timer
        rc_hc, _, _ = await asyncio.to_thread(
            run, ["systemctl", "is-active", "--quiet", "awg-dns-healthcheck.timer"]
        )
        hc_ok = rc_hc == 0
        # Сборка ответа
        out = "🌐 <b>DNS статус</b>\n━━━━━━━━━━━━━━━━━━\n"
        out += f"Сервис      : {'🟢 активен' if active else '🔴 выключен'}\n"
        out += f"Резолверы   : <code>{_html.escape(servers)}</code>\n"
        out += f"DNAT awg0   : {'✅' if dnat_ok else '❌ нет правила'}\n"
        out += f"Persistence : {'✅ переживёт reboot' if persist_ok else '⚠️ исчезнет после reboot'}\n"
        out += f"Healthcheck : {'✅ каждые 2 мин' if hc_ok else '○ выключен'}"
        await msg.edit_text(out, parse_mode=ParseMode.HTML)


# ══════════════════════════════════════════════════════════════════════════════
# Добавление клиента (бизнес-логика)
# ══════════════════════════════════════════════════════════════════════════════

_CPS_CODE = r"""
import sys, secrets, struct, random

# ── Утилиты ────────────────────────────────────────────
def rh(n):  return secrets.token_bytes(n)
# Криптостойкий int [a..b] — заменяет random.randint для всех параметров
# где предсказуемость нежелательна (pn_len, ports, expires и т.д.)
def ri(a, b):
    if a > b: a, b = b, a
    span = b - a + 1
    return a + secrets.randbelow(span)
def rc(lst): return lst[secrets.randbelow(len(lst))]
def u16(v): return struct.pack(">H", v & 0xFFFF)
def u32(v): return struct.pack(">I", v & 0xFFFFFFFF)
def u24(v): return struct.pack(">I", v)[1:]
def qv(v):
    if v < 64:    return bytes([v])
    elif v < 16384: return bytes([0x40|(v>>8)&0x3f, v&0xff])
    else:         return bytes([0x80|(v>>24)&0x3f,(v>>16)&0xff,(v>>8)&0xff,v&0xff])
def to_cps(raw): return "<b 0x%s>" % raw.hex()

# Криптостойкий shuffle (Fisher-Yates) — заменяет random.shuffle
def secure_shuffle(lst):
    for i in range(len(lst) - 1, 0, -1):
        j = secrets.randbelow(i + 1)
        lst[i], lst[j] = lst[j], lst[i]
    return lst

# Случайный приватный IP — три варианта подсетей (10/8, 172.16/12, 192.168/16)
def rand_private_ip():
    kind = secrets.randbelow(3)
    if kind == 0:
        return "10.%d.%d.%d" % (ri(1, 254), ri(0, 255), ri(2, 254))
    elif kind == 1:
        return "172.%d.%d.%d" % (ri(16, 31), ri(0, 255), ri(2, 254))
    else:
        return "192.168.%d.%d" % (ri(0, 255), ri(2, 254))

# ── Аргументы ──────────────────────────────────────────
# argv[1] = profile: quic|sip|dns
# argv[2] = domain (опционально, иначе из пула)
ALLOWED_PROFILES = ("quic", "sip", "dns")
PROFILE = sys.argv[1] if len(sys.argv) > 1 else "quic"
DOMAIN  = sys.argv[2] if len(sys.argv) > 2 else ""

# Валидация PROFILE — защита от опечатки в вызывающем коде.
# При неизвестном профиле фоллбэк на "quic" + warn в stderr (не прерываем,
# чтобы не сломать пайплайн, но даём диагностику).
if PROFILE not in ALLOWED_PROFILES:
    sys.stderr.write("[CPS] WARN: unknown profile \"%s\", fallback=quic\n" % PROFILE)
    PROFILE = "quic"

DOMAIN_POOL = [
    "google.com","github.com","gitlab.com","stackoverflow.com",
    "microsoft.com","apple.com","amazon.com","wikipedia.org",
    "mozilla.org","cdn.jsdelivr.net","unpkg.com","pypi.org",
    "ubuntu.com","debian.org","hetzner.com","ovhcloud.com",
    "digitalocean.com",
]
if not DOMAIN:
    DOMAIN = rc(DOMAIN_POOL)

SIP_POOL = [
    "sipgate.de","sip.ovh.net","sip.voipfone.co.uk","sip.linphone.org",
    "sip.zadarma.com","sip.dus.net","sip.easybell.de","sip.1und1.de",
    "sip.voys.nl","sip.antisip.com","sip.iptel.org","sip.voipgate.com",
]

# ── I1: QUIC Long Header Initial, строго 1200 байт ─────
# Chrome fingerprint: fb=0xC0/0xC3, DCID=8B, SCID=8B, token=0, pad до 1200
def gen_quic_initial(domain=None):
    TARGET = 1200
    fb     = rc([0xC0, 0xC0, 0xC0, 0xC3])   # Chrome чаще шлёт 0xC0
    pn_len = (fb & 0x03) + 1
    dcid   = rh(8)
    scid   = rh(8)
    # header = 1+4+1+8+1+8+1(tok)+2(varint plen) = 26
    enc_size  = TARGET - 26 - pn_len
    # Защита от отрицательного размера (на текущих параметрах невозможно,
    # но защищаемся от будущих правок констант)
    if enc_size < 1:
        enc_size = 1
    plen_val  = pn_len + enc_size
    pl_varint = u16(0x4000 | plen_val)
    pn      = rh(pn_len)
    # Payload: полностью случайный (имитация зашифрованного ClientHello)
    # Chrome Initial не содержит блоков нулей — всё выглядит как шифротекст
    payload = rh(enc_size)
    pkt = (bytes([fb]) + b"\x00\x00\x00\x01" +
           bytes([8]) + dcid + bytes([8]) + scid +
           b"\x00" + pl_varint + pn + payload)
    # Защита размера — без assert (assert удаляется при python3 -O)
    if len(pkt) != TARGET:
        # Достраиваем или обрезаем до TARGET
        if len(pkt) < TARGET:
            pkt += rh(TARGET - len(pkt))
        else:
            pkt = pkt[:TARGET]
    return pkt

# ── I2-I5: QUIC Short Header (1-RTT) ───────────────────
# Chrome после Initial шлёт 1-RTT пакеты: Short Header 0x40-0x7F.
# ВАЖНО: в реальном QUIC v1 биты spin/key_phase/pn_len МАСКИРУЮТСЯ
# header protection (RFC 9001 §5.4) — DPI видит их как случайные.
# Здесь они и так случайные, поэтому корректно имитируется HP-masked байт.
# pn_len теперь 1-4 (Chrome чаще шлёт 2-4) для большей реалистичности.
def gen_quic_short():
    pn_len = ri(1, 4)
    # Биты второго уровня — после HP они выглядят случайно для DPI
    spin   = ri(0, 1) << 5
    key    = ri(0, 1) << 2
    fb     = 0x40 | spin | key | (pn_len - 1)
    dcid   = rh(8)
    pn     = rh(pn_len)
    data   = rh(ri(40, 90))
    return bytes([fb]) + dcid + pn + data

# ── SIP REGISTER ────────────────────────────────────────
# Полный реалистичный набор заголовков как у Linphone / Zoiper / MicroSIP.
# Минималистичный REGISTER без User-Agent/Allow/Supported характерен
# для сканеров и легко детектится SIP-aware DPI.
SIP_UA_POOL = [
    "Linphone/5.2.5 (belle-sip/5.2.0)",
    "Zoiper rv2.10.20.4",
    "MicroSIP/3.21.4",
    "Bria 6.5.1",
    "PortSIP UA 16.4",
]
def gen_sip():
    host   = rc(SIP_POOL)
    user   = rc(["alice","bob","100","200","sip","user","client"]) + str(ri(10,9999))
    lip    = rand_private_ip()
    lport  = rc([5060, 5062, 5080, 5160, ri(10000, 65000)])
    branch = "z9hG4bK" + secrets.token_hex(7)
    tag    = secrets.token_hex(4)
    callid = "%s@%s" % (secrets.token_hex(8), host)
    cseq   = ri(1, 50)
    # transport чаще UDP (исторически), реже TCP/TLS
    transport = rc(["udp","udp","udp","udp","tcp"])
    user_agent = rc(SIP_UA_POOL)
    lines  = [
        "REGISTER sip:%s SIP/2.0" % host,
        "Via: SIP/2.0/%s %s:%d;branch=%s;rport" % (transport.upper(), lip, lport, branch),
        "Max-Forwards: 70",
        "From: <sip:%s@%s>;tag=%s" % (user, host, tag),
        "To: <sip:%s@%s>" % (user, host),
        "Call-ID: %s" % callid,
        "CSeq: %d REGISTER" % cseq,
        "Contact: <sip:%s@%s:%d;transport=%s>" % (user, lip, lport, transport),
        "User-Agent: %s" % user_agent,
        "Allow: INVITE, ACK, CANCEL, BYE, REFER, OPTIONS, NOTIFY, SUBSCRIBE, PRACK, MESSAGE, INFO, UPDATE",
        "Supported: replaces, outbound, gruu, path",
        "Expires: %d" % rc([300,600,1800,3600]),
        "Content-Length: 0",
        "", ""
    ]
    return "\r\n".join(lines).encode()

# ── DNS Query c EDNS0 ───────────────────────────────────
# Современные клиенты (systemd-resolved, Chrome, dnsmasq) всегда шлют
# EDNS0 OPT-RR с advertised buffer size. Без него запрос выглядит как
# legacy-резолвер — редкий паттерн в современном трафике.
# I1 начинается с <r 2> (TXID), остальные — тоже с TXID.
def gen_dns(domain=None):
    host  = domain or DOMAIN
    flags = b"\x01\x00"   # QR=0 Query, RD=1
    # counts: QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=1 (для OPT-RR)
    counts = b"\x00\x01\x00\x00\x00\x00\x00\x01"
    qn    = b""
    for lbl in host.split("."):
        # Защита от лейблов > 63 байт (DNS RFC 1035)
        lbl_b = lbl.encode()[:63]
        qn += bytes([len(lbl_b)]) + lbl_b
    qn += b"\x00"
    qtype  = b"\x00\x01"   # A record
    qclass = b"\x00\x01"   # IN
    # EDNS0 OPT-RR (RFC 6891):
    #   NAME=root(0x00), TYPE=OPT(41=0x29), CLASS=UDP_size (1232/4096),
    #   TTL=ext_rcode(0)+version(0)+flags(0/DO=0x8000), RDLEN=0
    udp_size = rc([1232, 4096])   # 1232 — systemd-resolved, 4096 — bind/dnsmasq
    do_bit   = rc([0x0000, 0x8000])  # DO=0 чаще, DO=1 для DNSSEC-aware
    opt_rr   = (b"\x00" + b"\x00\x29" + u16(udp_size) +
                b"\x00\x00" + u16(do_bit) + b"\x00\x00")
    return flags + counts + qn + qtype + qclass + opt_rr

# ── Dispatch ─────────────────────────────────────────────
if PROFILE == "sip":
    print(to_cps(gen_sip()))
    print(""); print(""); print(""); print("")

elif PROFILE == "dns":
    # DNS wire format: TXID(2b) + flags(2b) + counts(8b) + QNAME + QTYPE + QCLASS + OPT
    # TXID рандомный через <r 2> — в начале каждого пакета
    # Разные домены для I1-I5 чтобы не было паттерна
    pool = DOMAIN_POOL.copy()
    secure_shuffle(pool)
    for i in range(5):
        dom = pool[i % len(pool)]
        print("<r 2><b 0x%s>" % gen_dns(dom).hex())

else:  # quic (default)
    print(to_cps(gen_quic_initial(DOMAIN)))
    for _ in range(4):
        print(to_cps(gen_quic_short()))
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
                # Читаем профиль сервера: для Lite/Standard нужен только I1
                # (как делает do_add_client в awg2.sh для этих профилей).
                # Для Pro и неизвестных профилей — полный I1-I5.
                srv_profile_marker = ""
                try:
                    for ln in Path(SERVER_CONF).read_text().splitlines():
                        if ln.startswith("# AWG_PROFILE="):
                            srv_profile_marker = ln.split("=", 1)[1].strip()
                            break
                except Exception:
                    pass
                max_i_packets = 1 if srv_profile_marker in ("lite", "standard") else 5
                labels = ["I1", "I2", "I3", "I4", "I5"]
                for i, line in enumerate(cps_out.strip().splitlines()[:max_i_packets]):
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

async def client_watchdog(app):
    """Фоновый сторож: следит за хендшейками и орёт, когда клиент отваливается.

    Клиент считается «отвалившимся» только если он БЫЛ онлайн (видели свежий
    хендшейк), а затем хендшейк перестал обновляться дольше WATCHDOG_OFFLINE сек.
    Это исключает ложный ор по клиентам, которые просто выключены или никогда
    не подключались (⚫).
    """
    admin_id = app.bot_data.get("admin_id", "")
    if not admin_id:
        log.warning("watchdog: нет admin_id, мониторинг не запущен")
        return

    # pubkey -> "online"/"offline". Первый проход — без оров (прогрев).
    state: dict = {}
    started = time.time()
    log.info("watchdog: запущен (interval=%ss, offline=%ss)",
             WATCHDOG_INTERVAL, WATCHDOG_OFFLINE)

    while True:
        try:
            await asyncio.sleep(WATCHDOG_INTERVAL)

            # Сбрасываем кэш статистики ради свежих хендшейков
            _live_stats_cache.invalidate()
            clients = await asyncio.to_thread(get_clients)
            stats   = await asyncio.to_thread(get_live_stats)
            now     = time.time()
            warmup  = (now - started) < WATCHDOG_GRACE

            for c in clients:
                pk      = c["pubkey"]
                note    = c.get("note", "")

                # Мониторим только клиентов с тегом #watch в заметке
                if "#watch" not in note.lower():
                    state.pop(pk, None)   # чистим если тег убрали
                    continue

                last_hs = stats.get(pk, {}).get("last_hs", 0)

                if not last_hs:
                    is_online = False           # ⚫ — не трекаем как отвал
                else:
                    is_online = (now - last_hs) < WATCHDOG_OFFLINE

                prev = state.get(pk)

                # Переход online -> offline = клиент отвалился
                if prev == "online" and not is_online and not warmup:
                    name = _html.escape(c.get("name", pk[:8]))
                    ip   = _html.escape(c.get("ip", "?").split("/")[0])
                    # Показываем заметку без служебного тега #watch
                    note_clean = note.replace("#watch", "").replace("#WATCH", "").strip()
                    note_line = f"📝 {_html.escape(note_clean)}\n" if note_clean else ""
                    text = (
                        "🚨 <b>КЛИЕНТ ОТВАЛИЛСЯ!</b>\n\n"
                        f"❗️ <b>{name}</b>  ({ip})\n"
                        f"{note_line}"
                        f"🔴 нет связи: {elapsed_str(last_hs)}\n\n"
                        "Проверь клиента или сервер!"
                    )
                    try:
                        await app.bot.send_message(
                            chat_id=admin_id, text=text,
                            parse_mode=ParseMode.HTML,
                            disable_notification=False,
                        )
                        log.warning("watchdog: ОТВАЛ %s (%s)", c.get("name"), ip)
                    except Exception as e:
                        log.error("watchdog: не смог отправить алерт: %s", e)

                if prev == "offline" and is_online and not warmup:
                    log.info("watchdog: %s снова онлайн", c.get("name"))

                state[pk] = "online" if is_online else "offline"

            # Чистим из state удалённых клиентов
            live_pks = {c["pubkey"] for c in clients}
            for dead in [k for k in state if k not in live_pks]:
                state.pop(dead, None)

        except asyncio.CancelledError:
            log.info("watchdog: остановлен")
            raise
        except Exception as e:
            # Никогда не роняем цикл — иначе мониторинг молча умрёт
            log.error("watchdog: ошибка цикла: %s", e)


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
            ADD_EXPIRE:  [CallbackQueryHandler(on_add_expire_choice, pattern="^expnew:")],
            ADD_EXPIRE_CUSTOM: [
                CallbackQueryHandler(on_add_expire_choice, pattern="^expnew:"),
                MessageHandler(filters.TEXT & ~filters.COMMAND, on_add_expire_custom_text),
            ],
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
        CallbackQueryHandler(on_callback, pattern=r"^(?!prof:|expnew:|cancel_add$).+"),
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

        # Запускаем сторожа отвалов клиентов (фоновая задача)
        if WATCHDOG_ENABLED:
            application.bot_data["_watchdog_task"] = asyncio.create_task(
                client_watchdog(application)
            )

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

  Бот: @${BOT_USERNAME:-неизвестно}
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
# Если пришли сюда после самообновления (новая версия запущена с флагом) —
# сразу выполняем обновление бота без меню и выходим.
if [[ "${AWG_BOT_SELFUPDATED:-0}" == "1" && "${AWG_BOT_AUTO_CHOICE:-}" == "2" ]]; then
  do_update_bot
  exit 0
fi

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
