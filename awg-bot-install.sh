#!/usr/bin/env bash
# awg-bot-install.sh — установщик бота awgToolza для пункта 6 awg2.
#
# Этот файл лежит в КОРНЕ репозитория awg-multi-script и качается самим awg2
# (пункт 6 → «Установить/Переустановить бота») по URL:
#   https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg-bot-install.sh
#
# Запускается в терминале awg2 (read работает), от root. Делает:
#   1. клонирует репо, берёт код бота из подпапки awg_bot/
#   2. ставит зависимости в venv, настраивает systemd-сервис awg-bot
#   3. спрашивает токен и Telegram ID (если ещё не заданы)
#   4. ставит management-скрипт awg-bot и маркер /usr/local/bin/awg-bot.py
#      (awg2 проверяет именно его, чтобы показать «бот установлен»)
set -euo pipefail

REPO_URL="https://github.com/pumbaX/awg-multi-script"
REPO_SUBDIR="awg_bot"
DEST="/opt/awg-bot"
CONF="/etc/awg-bot.conf"
MARKER="/usr/local/bin/awg-bot.py"   # маркер для awg2 (пункт 6)

R='\033[38;5;203m'; G='\033[0;32m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'
ok(){ echo -e "${G}  √ $*${N}"; }; err(){ echo -e "${R}  × $*${N}"; }
info(){ echo -e "${C}  → $*${N}"; }

[[ $EUID -ne 0 ]] && { err "Нужен root (запусти через sudo awg2)"; exit 1; }

echo -e "${W}━━━ Установка awgToolza Bot (через awg2) ━━━${N}"

# 1. зависимости
info "Проверяю зависимости (git, python3-venv)…"
command -v git >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq git; }
command -v python3 >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq python3 python3-venv; }
dpkg -s python3-venv >/dev/null 2>&1 || apt-get install -y -qq python3-venv
ok "Зависимости готовы"

# 2. клон и деплой кода
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
info "Скачиваю код бота из ${REPO_URL} (${REPO_SUBDIR}/)…"
if ! git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null 2>&1; then
  err "git clone не удался. Проверь доступ к GitHub."
  exit 1
fi
SRC="$TMP/repo/$REPO_SUBDIR"
if [[ ! -d "$SRC/awgbot" || ! -f "$SRC/run.py" ]]; then
  err "В репозитории нет кода бота в папке ${REPO_SUBDIR}/ (awgbot/, run.py)."
  exit 1
fi

systemctl stop awg-bot 2>/dev/null || true

# 2b. Чистая миграция со старого бота pumbaX (если стоял).
#  - старый код был одним файлом /usr/local/bin/awg-bot.py — удалим (заменим маркером ниже)
#  - старый конфиг использует ADMIN_CHAT_ID; наш бот понимает оба имени, но
#    на всякий случай продублируем в ADMIN_ID, если его ещё нет.
if [[ -f /usr/local/bin/awg-bot.py ]] && grep -q 'ADMIN_CHAT_ID\|awg-bot.py' /usr/local/bin/awg-bot.py 2>/dev/null; then
  info "Обнаружен старый бот — выполняю чистую замену"
fi
if [[ -f "$CONF" ]]; then
  if grep -q '^ADMIN_CHAT_ID=' "$CONF" 2>/dev/null && ! grep -q '^ADMIN_ID=' "$CONF" 2>/dev/null; then
    old_id=$(grep -m1 '^ADMIN_CHAT_ID=' "$CONF" | cut -d= -f2- | tr -d '"'"'"' ')
    [[ -n "$old_id" ]] && echo "ADMIN_ID=${old_id}" >> "$CONF" && info "Перенёс ADMIN_CHAT_ID → ADMIN_ID"
  fi
fi

mkdir -p "$DEST"
rm -rf "$DEST/awgbot"
cp -r "$SRC/awgbot" "$DEST/"
cp "$SRC/run.py" "$SRC/requirements.txt" "$DEST/"
ok "Код развёрнут в ${DEST}"

# 3. venv
info "Ставлю Python-зависимости…"
[[ -d "$DEST/venv" ]] || python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install -q --upgrade pip
"$DEST/venv/bin/pip" install -q -r "$DEST/requirements.txt"
ok "Зависимости установлены"

# 4. токен и ID (спрашиваем, если ещё нет в конфиге)
if [[ ! -f "$CONF" ]] || ! grep -q '^BOT_TOKEN=' "$CONF" 2>/dev/null; then
  echo ""
  echo -e "${W}  Нужен Telegram-бот. Создай его у @BotFather и вставь токен.${N}"
  read -rp "$(echo -e "${C}  Токен бота: ${N}")" BOT_TOKEN
  read -rp "$(echo -e "${C}  Твой Telegram ID (узнать у @userinfobot): ${N}")" ADMIN_ID
  touch "$CONF"; chmod 600 "$CONF"
  sed -i '/^BOT_TOKEN=/d;/^ADMIN_ID=/d' "$CONF"
  { echo "BOT_TOKEN=${BOT_TOKEN}"; echo "ADMIN_ID=${ADMIN_ID}"; } >> "$CONF"
  ok "Конфиг записан (${CONF}, chmod 600)"
else
  ok "Конфиг ${CONF} уже содержит токен — оставляю как есть"
fi

# 5. management-скрипт awg-bot
if [[ -f "$SRC/awg-bot" ]]; then
  cp "$SRC/awg-bot" /usr/local/bin/awg-bot
  chmod +x /usr/local/bin/awg-bot
  ok "Установлен awg-bot (управление: sudo awg-bot)"
fi

# 6. каталог состояния мониторинга
mkdir -p /var/lib/awg-bot

# 7. systemd-сервис (имя awg-bot — совпадает с тем, что ждёт awg2)
cat > /etc/systemd/system/awg-bot.service << EOF
[Unit]
Description=awgToolza Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DEST}
ExecStart=${DEST}/venv/bin/python ${DEST}/run.py
Restart=on-failure
RestartSec=5
Environment=AWG_BOT_CONF=${CONF}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable awg-bot >/dev/null 2>&1 || true

# 8. маркер для awg2 (пункт 6 проверяет наличие /usr/local/bin/awg-bot.py)
cat > "$MARKER" << EOF
#!/usr/bin/env python3
# Маркер установки бота awgToolza для awg2 (пункт 6).
# Реальный код бота — в ${DEST}, запускается systemd-сервисом awg-bot.
# Запуск вручную: systemctl start awg-bot  (или sudo awg-bot)
import os, sys
os.execv("${DEST}/venv/bin/python", ["${DEST}/venv/bin/python", "${DEST}/run.py"])
EOF
chmod +x "$MARKER"

# 9. старт
systemctl restart awg-bot
sleep 2
if systemctl is-active --quiet awg-bot; then
  ok "Бот запущен"
  echo -e "${G}━━━ Готово! Открой бота в Telegram и нажми /start ━━━${N}"
else
  err "Сервис не запустился. Логи: journalctl -u awg-bot -n 30"
  exit 1
fi
