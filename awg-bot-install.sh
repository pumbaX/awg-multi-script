#!/usr/bin/env bash
# awg-bot-install.sh — установка и обновление Telegram-бота AWG Toolza.
#
# Запускает его awg2 (Telegram-бот → Установить / Обновить), в том числе из
# самого бота — тогда без терминала. Делает:
#   1. берёт код бота: --src КАТАЛОГ, awg_bot/ рядом с установщиком или
#      git clone репозитория (AWG_REPO_URL — канал обновлений awg2);
#   2. ставит зависимости в venv /opt/awg-bot/venv;
#   3. спрашивает токен и Telegram ID, если их ещё нет в /etc/awg-bot.conf
#      (без терминала — ошибка: спросить некого);
#   4. пишет службу awg-bot и запускает её.
# Настройки, админы, заметки и мониторинг (/var/lib/awg-bot) сохраняются.
#
# --web-only — только код и venv для веб-панели (awg-web): без токена, без
# службы бота. Бот, если он уже стоит, перезапускается на новом коде.
set -euo pipefail

REPO_URL="${AWG_REPO_URL:-https://github.com/pumbaX/awg-multi-script}"
DEST="/opt/awg-bot"
CONF="/etc/awg-bot.conf"
STATE="/var/lib/awg-bot"
UNIT="/etc/systemd/system/awg-bot.service"
AWG2="/usr/local/bin/awg2"

R='\033[38;5;203m'; G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'
ok()   { echo -e "${G}  √ $*${N}"; }
err()  { echo -e "${R}  × $*${N}"; }
warn() { echo -e "${Y}  ▲ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }

(( EUID == 0 )) || { err "Нужен root: sudo awg2 → Telegram-бот"; exit 1; }

SRC="${BOT_SRC:-}"
WEB_ONLY=0
while (( $# )); do
  case "$1" in
    --web-only) WEB_ONLY=1; shift ;;
    --src) SRC="${2:-}"; shift 2 ;;
    --src=*) SRC="${1#--src=}"; shift ;;
    *) shift ;;
  esac
done

# Каталог с awgbot/ и run.py: сам awg_bot/ или корень репозитория.
bot_dir() {
  local d="${1%/}"
  [[ -n "$d" ]] || return 1
  if [[ -d "$d/awgbot" && -f "$d/run.py" ]]; then echo "$d"
  elif [[ -d "$d/awg_bot/awgbot" && -f "$d/awg_bot/run.py" ]]; then echo "$d/awg_bot"
  else return 1; fi
}

# Код рядом с установщиком берётся, только если подменить его может лишь
# root: всё от каталога до / принадлежит root и закрыто на запись группе и
# остальным. Установщик, скачанный в общий /tmp, иначе взял бы
# /tmp/awg_bot, подложенный любым пользователем, и запустил его от root.
root_only() {
  local p m
  p=$(readlink -f -- "$1" 2>/dev/null) && [[ -e "$p" ]] || return 1
  [[ -z "$(find "$p" \( ! -user 0 -o \( ! -type l -perm /022 \) \) -print -quit 2>/dev/null)" ]] || return 1
  while :; do
    [[ "$(stat -c %u -- "$p" 2>/dev/null)" == 0 ]] || return 1
    m=$(stat -c %a -- "$p" 2>/dev/null) || return 1
    (( 8#$m & 8#022 )) && return 1
    [[ "$p" == / ]] && return 0
    p=$(dirname -- "$p")
  done
}

if (( WEB_ONLY )); then echo -e "${W}━━━ Веб-панель AWG Toolza: код и зависимости ━━━${N}"
else echo -e "${W}━━━ Telegram-бот AWG Toolza ━━━${N}"; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [[ -n "$SRC" ]]; then
  SRC=$(bot_dir "$SRC") || { err "В каталоге нет кода бота (awgbot/, run.py)"; exit 1; }
  ok "Код бота: $SRC"
elif SRC=$(bot_dir "$(dirname "$(readlink -f "$0")")") && root_only "$SRC"; then
  ok "Код бота: $SRC"
else
  command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git >/dev/null; }
  info "Скачиваю код бота из $REPO_URL"
  git clone -q --depth 1 "$REPO_URL" "$TMP/repo" || { err "git clone не удался — нет доступа к GitHub?"; exit 1; }
  SRC=$(bot_dir "$TMP/repo") || { err "В репозитории нет кода бота"; exit 1; }
fi

info "Зависимости Python..."
if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
  if ! { apt-get update -qq && apt-get install -y -qq python3 python3-venv >/dev/null; }; then
    err "Не поставился python3-venv"; exit 1
  fi
fi

(( WEB_ONLY )) || systemctl stop awg-bot 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/awgbot"
cp -r "$SRC/awgbot" "$DEST/"
cp "$SRC/run.py" "$SRC/requirements.txt" "$DEST/"
find "$DEST/awgbot" -name __pycache__ -prune -exec rm -rf {} +
[[ -x "$DEST/venv/bin/python" ]] || python3 -m venv "$DEST/venv"
# Свежий pip не нужен — без самообновления на PyPI ходим, только если
# зависимостей не хватает. Повторы и ретраи — в журнал, на экран — только
# итог: соединение с PyPI с серверов в РФ рвётся, и pip его переживает.
PIP_LOG="$STATE/pip.log"
mkdir -p "$STATE"; chmod 700 "$STATE"
if ! "$DEST/venv/bin/pip" install -q --disable-pip-version-check --retries 10 --timeout 30 \
     -r "$DEST/requirements.txt" >"$PIP_LOG" 2>&1; then
  err "pip install не удался:"
  tail -n 8 "$PIP_LOG" | sed 's/^/    /'
  exit 1
fi
ok "Код и зависимости: $DEST"

# Веб-панель живёт на том же коде — перезапуск на новом
restart_web() {
  if systemctl is-enabled --quiet awg-web 2>/dev/null; then
    systemctl restart awg-web && ok "Веб-панель перезапущена на новом коде"
  fi
  return 0
}
if (( WEB_ONLY )); then
  if [[ -f "$UNIT" ]]; then systemctl restart awg-bot && ok "Бот перезапущен на новом коде"; fi
  restart_web
  exit 0
fi

touch "$CONF"; chmod 600 "$CONF"
# Бот старого образца писал ADMIN_CHAT_ID — переносим в ADMIN_ID
if ! grep -q '^ADMIN_ID=' "$CONF" && grep -q '^ADMIN_CHAT_ID=' "$CONF"; then
  echo "ADMIN_ID=$(sed -n 's/^ADMIN_CHAT_ID=//p' "$CONF" | tr -d "\"' " | head -1)" >> "$CONF"
fi
if ! grep -q '^BOT_TOKEN=.' "$CONF" || ! grep -q '^ADMIN_ID=.' "$CONF"; then
  [[ -t 0 ]] || { err "В $CONF нет BOT_TOKEN/ADMIN_ID — запусти установку из меню awg2"; exit 1; }
  echo -e "  Создай бота у ${W}@BotFather${N} и вставь токен."
  read -rp "$(echo -e "${C}  Токен бота: ${N}")" token
  read -rp "$(echo -e "${C}  Твой Telegram ID (@userinfobot; несколько — через запятую): ${N}")" ids
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { err "Токен не похож на токен бота"; exit 1; }
  [[ "$ids" =~ ^[0-9]+([,[:space:]]+[0-9]+)*$ ]] || { err "ID — числа через запятую"; exit 1; }
  sed -i '/^BOT_TOKEN=/d;/^ADMIN_ID=/d' "$CONF"
  printf 'BOT_TOKEN=%s\nADMIN_ID=%s\n' "$token" "${ids// /}" >> "$CONF"
  ok "Конфиг: $CONF"
fi
# Ключи прежнего скрипта управления awg-bot: источник обновлений теперь — awg2
sed -i '/^LOCAL_SRC=/d;/^REPO_URL=/d;/^UPDATE_CHANNEL=/d' "$CONF"
rm -f /usr/local/bin/awg-bot /usr/local/bin/awg-bot.py

cat > "$UNIT" <<EOF
[Unit]
Description=AWG Toolza — Telegram-бот
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DEST
ExecStart=$DEST/venv/bin/python $DEST/run.py
Environment=AWG_BOT_CONF=$CONF AWG2_BIN=$AWG2 PYTHONUNBUFFERED=1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable awg-bot >/dev/null 2>&1 || true

if ! "$AWG2" api version 2>/dev/null | grep -q '"ok": true'; then
  warn "Установленный awg2 не отвечает на «awg2 api» — обнови AWG Toolza, иначе бот не сможет управлять сервером"
fi

systemctl restart awg-bot
sleep 3
if systemctl is-active --quiet awg-bot; then
  ok "Бот запущен — открой его в Telegram и нажми /start"
  restart_web
else
  err "Бот не запустился: journalctl -u awg-bot -n 30"
  exit 1
fi
