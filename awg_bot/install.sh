#!/usr/bin/env bash
# install.sh — развёртывание AmneziaWG-бота на сервере (Debian/Ubuntu).
# Запускать от root на том же сервере, где стоит awg2.
set -euo pipefail

R='\033[38;5;203m'; G='\033[0;32m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'
ok()   { echo -e "${G}  √ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }
err()  { echo -e "${R}  × $*${N}"; }

[[ $EUID -ne 0 ]] && { err "Запускай от root"; exit 1; }

DEST="/opt/awg-bot"
CONF="/etc/awg-bot.conf"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${W}━━━ Установка awgToolza Bot ━━━${N}"

# 1. Зависимости системы
info "Ставлю python3-venv и системные пакеты…"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip >/dev/null
ok "Системные пакеты готовы"

# 2. Копируем файлы
info "Копирую бота в ${DEST}…"
mkdir -p "$DEST"
cp -r "$SRC_DIR/awgbot" "$DEST/"
cp "$SRC_DIR/run.py" "$SRC_DIR/requirements.txt" "$DEST/"
ok "Файлы скопированы"

# 3. venv + pip
info "Создаю venv и ставлю зависимости…"
python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install -q --upgrade pip
"$DEST/venv/bin/pip" install -q -r "$DEST/requirements.txt"
ok "Python-зависимости установлены (aiogram, qrcode, pexpect)"

# 3b. management-скрипт awg-bot в PATH
if [[ -f "$SRC_DIR/awg-bot" ]]; then
  cp "$SRC_DIR/awg-bot" /usr/local/bin/awg-bot
  chmod +x /usr/local/bin/awg-bot
  ok "Установлен awg-bot (управление: sudo awg-bot)"
fi

# 3c. каталог состояния мониторинга
mkdir -p /var/lib/awg-bot
ok "Каталог состояния: /var/lib/awg-bot"

# 3d. маркер для awg2 (пункт 6 проверяет наличие /usr/local/bin/awg-bot.py)
cat > /usr/local/bin/awg-bot.py << EOF
#!/usr/bin/env python3
# Маркер установки бота awgToolza для awg2 (пункт 6).
# Реальный код — в ${DEST}, запускается systemd-сервисом awg-bot.
import os
os.execv("${DEST}/venv/bin/python", ["${DEST}/venv/bin/python", "${DEST}/run.py"])
EOF
chmod +x /usr/local/bin/awg-bot.py

# 4. Конфиг с токеном и admin id
if [[ ! -f "$CONF" ]] || ! grep -q '^BOT_TOKEN=' "$CONF" 2>/dev/null; then
  echo ""
  read -rp "$(echo -e "${C}  Вставь токен бота от @BotFather: ${N}")" BOT_TOKEN
  read -rp "$(echo -e "${C}  Твой Telegram ID (@userinfobot; несколько — через запятую): ${N}")" ADMIN_ID
  # сохраняем, не затирая возможные awg2-настройки уведомлений
  touch "$CONF"; chmod 600 "$CONF"
  sed -i '/^BOT_TOKEN=/d;/^ADMIN_ID=/d' "$CONF"
  {
    echo "BOT_TOKEN=${BOT_TOKEN}"
    echo "ADMIN_ID=${ADMIN_ID}"
  } >> "$CONF"
  ok "Конфиг записан в ${CONF} (chmod 600)"
else
  ok "Конфиг ${CONF} уже содержит BOT_TOKEN — оставляю как есть"
fi

# 5. systemd
info "Настраиваю systemd-сервис…"
cp "$SRC_DIR/awg-bot.service" /etc/systemd/system/awg-bot.service
systemctl daemon-reload
systemctl enable awg-bot.service >/dev/null 2>&1
systemctl restart awg-bot.service
sleep 2

if systemctl is-active --quiet awg-bot.service; then
  ok "Бот запущен и добавлен в автозагрузку"
  echo ""
  echo -e "${G}━━━ Готово! ━━━${N}"
  echo -e "  Открой бота в Telegram и нажми /start"
  echo -e "  Логи:    ${W}journalctl -u awg-bot -f${N}"
  echo -e "  Рестарт: ${W}systemctl restart awg-bot${N}"
  echo -e "  Стоп:    ${W}systemctl stop awg-bot${N}"
else
  err "Сервис не запустился. Смотри: journalctl -u awg-bot -n 30"
  exit 1
fi
