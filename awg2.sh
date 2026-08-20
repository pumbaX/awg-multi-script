#!/bin/bash
set -euo pipefail

VERSION="v0.7.18"
SCRIPT_PATH="/usr/local/bin/awg2"

# ── Канал обновлений ───────────────────────────────────────
# stable — основной репозиторий проекта, оттуда обновляются все по умолчанию.
# beta   — репозиторий с ранними сборками: правки приезжают туда раньше и могут
#          быть сырыми. Переключается в меню «Обновить скрипт» (пункт 8).
# Выбор хранится в файле, чтобы переживать перезапуск и само обновление.
UPDATE_REPO_STABLE="pumbaX/awg-multi-script"
UPDATE_REPO_BETA="genaRijoff/awg-multi-script"
UPDATE_CHANNEL_FILE="/var/lib/awg2/channel"

# Кэш фоновой проверки версии — свой у каждого канала. Общий кэш после
# переключения сравнивал бы текущую версию с версией чужого репозитория
# (см. update_check_async).
UPDATE_CACHE_STABLE="/var/lib/awg2/update_check"
UPDATE_CACHE_BETA="/var/lib/awg2/update_check.beta"

# Выставляет UPDATE_CHANNEL и все производные от него URL. Единственное место,
# где собираются адреса репозитория, — менять источник надо здесь.
update_channel_apply() {
  case "${1:-stable}" in
    beta)
      UPDATE_CHANNEL="beta"
      UPDATE_REPO="$UPDATE_REPO_BETA"
      UPDATE_CACHE="$UPDATE_CACHE_BETA"
      ;;
    *)
      UPDATE_CHANNEL="stable"
      UPDATE_REPO="$UPDATE_REPO_STABLE"
      UPDATE_CACHE="$UPDATE_CACHE_STABLE"
      ;;
  esac
  UPDATE_REPO_GIT="https://github.com/${UPDATE_REPO}"
  UPDATE_URL="https://raw.githubusercontent.com/${UPDATE_REPO}/main/awg2.sh"
  BOT_INSTALL_URL="https://raw.githubusercontent.com/${UPDATE_REPO}/main/awg-bot-install.sh"
}

# Читает сохранённый канал. Любое неизвестное/битое значение — stable.
update_channel_read() {
  local ch=""
  if [[ -f "$UPDATE_CHANNEL_FILE" ]]; then
    ch=$(tr -d '[:space:]' < "$UPDATE_CHANNEL_FILE" 2>/dev/null || true)
  fi
  [[ "$ch" == "beta" ]] && echo "beta" || echo "stable"
}

# Сохраняет канал на диск и сразу применяет его в текущем процессе.
update_channel_set() {
  local ch="$1"
  [[ "$ch" == "beta" || "$ch" == "stable" ]] || return 1
  mkdir -p "$(dirname "$UPDATE_CHANNEL_FILE")" 2>/dev/null || return 1
  printf '%s\n' "$ch" > "$UPDATE_CHANNEL_FILE" 2>/dev/null || return 1
  update_channel_apply "$ch"
}

# Человекочитаемое имя канала для меню и шапки.
update_channel_label() {
  [[ "${1:-$UPDATE_CHANNEL}" == "beta" ]] && echo "бета" || echo "стабильный"
}

# AWG2_UPDATE_CHANNEL=beta — разовый запуск на другом канале, без записи файла.
update_channel_apply "${AWG2_UPDATE_CHANNEL:-$(update_channel_read)}"

# ── Цвета ──────────────────────────────────────────────────
# shellcheck disable=SC2034  # цветовая палитра — часть публичного API функций
R='\033[38;5;203m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[1;94m'; M='\033[0;35m'; C='\033[0;36m'
W='\033[1;37m'; D='\033[0;90m'; N='\033[0m'

# ── Константы ──────────────────────────────────────────────
# Определяем домашнюю директорию реального пользователя
_real_user=$(logname 2>/dev/null || echo "${SUDO_USER:-}")
if [[ -n "$_real_user" ]] && getent passwd "$_real_user" &>/dev/null 2>&1; then
  REAL_HOME=$(getent passwd "$_real_user" | cut -d: -f6)
else
  REAL_HOME="/root"
fi
BACKUP_DIR="${REAL_HOME}/awg_backup"

# ── Expire-механика (срок действия клиентов) ───────────────
EXPIRE_CHECK_BIN="/usr/local/bin/awg2-expire-check"
EXPIRE_SERVICE="/etc/systemd/system/awg2-expire.service"
EXPIRE_TIMER="/etc/systemd/system/awg2-expire.timer"
EXPIRE_SUSPEND_IP="127.0.0.2/32"        # AllowedIPs у заблокированных
EXPIRE_STATE_DIR="/var/lib/awg2-expire" # флаги "уже уведомили" по pubkey
EXPIRE_LOG="/var/log/awg2-expire.log"

[[ $EUID -ne 0 ]] && { echo -e "${R}× Запускай от root${N}"; exit 1; }

# ── Хелперы ────────────────────────────────────────────────
ok()   { echo -e "${G}  √ $*${N}"; }
err()  { echo -e "${R}  × $*${N}"; }
warn() { echo -e "${Y}  ▲ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }
hdr()  {
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}$*${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ── Единые правила ввода ───────────────────────────────────
# Во всём скрипте ввод читается только через хелперы ниже. Общий контракт:
#   • Ctrl+D (EOF) = «отмена/назад». Никогда не роняет скрипт и не зацикливает
#     переспрос — раньше read_choice/read_yesno на EOF крутили бесконечный цикл,
#     а safe_read под set -e убивал весь скрипт.
#   • Мусорный ввод переспрашивается, а не проваливается дальше.
#   • В меню принимаются только цифры (плюс явно объявленные буквенные пункты),
#     0 = назад или выход.
#   • Опасные действия подтверждаются через read_confirm — полным словом.

# _flush_stdin — сбрасывает буфер stdin, чтобы случайные клавиши/повторы
# не попадали в следующий prompt. Только в интерактивном режиме (TTY):
# в неинтерактивном (heredoc/пайп) -t 0.05 съел бы реальный ввод.
_flush_stdin() {
  if [[ -t 0 ]]; then
    while read -t 0.05 -n 100 -r _discard 2>/dev/null; do :; done
  fi
}

# safe_read — свободный ввод (имена, IP, комментарии). Валидацию делает вызывающий.
# EOF → пустое значение и rc=0: вызывающие трактуют пустую строку как отмену,
# а ненулевой код возврата под set -e снёс бы весь скрипт.
# Использование: safe_read VARNAME "Промпт: "
safe_read() {
  local _var_name="$1"
  local _prompt="${2:-}"
  _flush_stdin
  # shellcheck disable=SC2229  # читаем в переменную по имени — это намеренно
  if ! read -rp "$_prompt" "$_var_name"; then
    printf -v "$_var_name" '%s' ""
    echo "" >&2
  fi
  return 0
}

# read_choice — единая функция чтения выбора: числовой диапазон с переспросом.
# Использование: read_choice VARNAME "Промпт: " MIN MAX [DEFAULT] [EXTRA]
#   DEFAULT — что подставить на пустой Enter. Без него пустой ввод невалиден.
#   EXTRA   — дополнительные буквенные пункты через '|' (например "d" или "d|r").
#             Регистр не важен, результат отдаётся в нижнем регистре.
# MIN должен быть значением «назад/отмена» (в меню это 0): именно его получает
# вызывающий на Ctrl+D, если не задан DEFAULT.
read_choice() {
  local _var_name="$1"
  local _prompt="$2"
  local _min="$3"
  local _max="$4"
  local _default="${5:-}"
  local _extra="${6:-}"
  local _value _lc _k _matched
  local _keys=()
  [[ -n "$_extra" ]] && IFS='|' read -ra _keys <<< "$_extra"

  while true; do
    _flush_stdin
    if ! read -rp "$_prompt" _value; then
      # Ctrl+D / закрытый stdin: читать больше нечего. Раньше здесь крутился
      # бесконечный цикл переспроса. Отдаём безопасный вариант.
      echo "" >&2
      _value="${_default:-$_min}"
      break
    fi
    # Пустой ввод + есть дефолт → применяем дефолт
    if [[ -z "$_value" && -n "$_default" ]]; then
      _value="$_default"
      break
    fi
    # Число в диапазоне. 10# обязателен: без него ввод "08" ломает арифметику
    # bash (трактуется как восьмеричное) и вываливает сырую ошибку в терминал.
    if [[ "$_value" =~ ^[0-9]+$ ]] && (( 10#$_value >= _min && 10#$_value <= _max )); then
      _value="$((10#$_value))"
      break
    fi
    # Буквенные пункты меню
    _matched=0
    _lc="${_value,,}"
    for _k in ${_keys[@]+"${_keys[@]}"}; do
      if [[ "$_lc" == "${_k,,}" ]]; then
        _value="${_k,,}"; _matched=1; break
      fi
    done
    [[ $_matched -eq 1 ]] && break

    if [[ -n "$_extra" ]]; then
      echo -e "${R}  Введи число от ${_min} до ${_max} или: ${_extra//|/, }${N}" >&2
    else
      echo -e "${R}  Введи число от ${_min} до ${_max}${N}" >&2
    fi
  done
  # Присваиваем результат вызывающей переменной
  printf -v "$_var_name" '%s' "$_value"
}

# read_yesno — читает yes/no с переспросом при невалидном вводе.
# Принимает: y, yes, д, да, н, n, no, нет (любой регистр).
# Пустой ввод применяет дефолт (если задан).
# Использование: read_yesno VARNAME "Промпт" DEFAULT
#   DEFAULT — "y" или "n" (что вернётся при пустом Enter). Опционально.
# Результат: переменная получает "y" или "n".
read_yesno() {
  local _var_name="$1"
  local _prompt="$2"
  local _default="${3:-}"
  local _value _lc
  while true; do
    _flush_stdin
    if ! read -rp "$_prompt" _value; then
      # Ctrl+D: раньше здесь был бесконечный цикл переспроса.
      # Отдаём дефолт, а без него — отказ.
      echo "" >&2
      _value="${_default:-n}"
      break
    fi
    # Пустой ввод + есть дефолт
    if [[ -z "$_value" && -n "$_default" ]]; then
      _value="$_default"
      break
    fi
    # Приводим к нижнему регистру
    _lc="${_value,,}"
    case "$_lc" in
      y|yes|д|да)  _value="y"; break ;;
      n|no|н|нет)  _value="n"; break ;;
      *) echo -e "${R}  Ответь y/yes/да или n/no/нет${N}" >&2 ;;
    esac
  done
  printf -v "$_var_name" '%s' "$_value"
}

# read_confirm — подтверждение НЕОБРАТИМОГО действия (удаление клиента, снос
# интерфейса, переустановка, восстановление из бекапа).
# Требует полное слово: yes или да. Одной буквы 'y' СОЗНАТЕЛЬНО недостаточно —
# чтобы случайное нажатие не снесло рабочую конфигурацию.
# Переспроса нет: на опасном действии неверный ответ должен отменять операцию,
# а не удерживать пользователя в цикле. Пустой ввод и Ctrl+D = отказ.
# Использование: read_confirm "Промпт" || { warn "Отменено"; return 0; }
read_confirm() {
  local _prompt="$1"
  local _value
  _flush_stdin
  if ! read -rp "$_prompt" _value; then
    echo "" >&2
    return 1
  fi
  case "${_value,,}" in
    yes|да) return 0 ;;
    *)      return 1 ;;
  esac
}

# Тематические хелперы
restart()   { echo -e "${C}  ↻ $*${N}"; }
trash()     { echo -e "${C}  ⌧ $*${N}"; }
bkup()      { echo -e "${C}  ◈ $*${N}"; }

# Рамка успеха: ширина 48, текст по центру
success_box() {
  echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}$*${N}"
  echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# Меню после ошибки: «Попробовать снова / Вернуться в меню»
prompt_retry() {
  echo ""
  echo -e "  ${Y}↩ 1) Попробовать снова${N}"
  echo -e "  ${Y}↵ 2) Вернуться в меню${N}"
  echo ""
  local RETRY_CHOICE
  read_choice RETRY_CHOICE "$(echo -e "${C}  Выбор [1-2] (Enter = 2): ${N}")" 1 2 2
  if [[ "$RETRY_CHOICE" == "1" ]]; then return 0; fi
  return 1
}

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
LOG_FILE="/var/log/awg-manager.log"

# Warp туннель (Cloudflare wgcf) — Туннели (5)
WARP_DIR="/etc/wgcf"
WARP_CONF="/etc/wireguard/warp0.conf"
WARP_ACCOUNT="$WARP_DIR/wgcf-account.toml"
WARP_PROFILE="$WARP_DIR/wgcf-profile.conf"
WARP_STATE="$WARP_DIR/state"
WARP_PEERS="$WARP_DIR/peers.list"
WARP_HEALTH_LOG="/var/log/awg-warp-health.log"
WARP_HEALTH_SCRIPT="/usr/local/bin/awg-warp-healthcheck.sh"
WARP_HEALTH_TIMER="/etc/systemd/system/awg-warp-healthcheck.timer"
WARP_HEALTH_SERVICE="/etc/systemd/system/awg-warp-healthcheck.service"

# warpscout (https://github.com/vernette/warpscout) — сканер эндпоинтов Cloudflare
# WARP для бэкенда wg. Отдельный аккаунт от wgcf-account.toml выше — своя
# регистрация в Cloudflare, не путать одно с другим.
WARPSCOUT_BIN="/usr/local/bin/warpscout"
WARPSCOUT_DIR="/etc/warpscout"
WARPSCOUT_ACCOUNT="$WARPSCOUT_DIR/warpscout-account.json"

# Шифрованный DNS (dnscrypt-proxy) — Туннели (5)
# Используем системный сокет Debian/Ubuntu: 127.0.2.1:53 (socket activation)
# Это работает "из коробки" — не боремся с systemd
DNS_PROXY_ADDR="127.0.2.1"
DNS_PROXY_PORT=53
DNS_PROXY_CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNS_PROXY_STATE="/etc/dnscrypt-proxy/awg.state"
DNS_PROXY_BACKUP_CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml.awg-backup"
DNS_PERSIST_SERVICE="/etc/systemd/system/awg-dns-persist.service"
DNS_PERSIST_SCRIPT="/usr/local/bin/awg-dns-persist.sh"
DNS_HEALTH_SERVICE="/etc/systemd/system/awg-dns-healthcheck.service"
DNS_HEALTH_TIMER="/etc/systemd/system/awg-dns-healthcheck.timer"
DNS_HEALTH_SCRIPT="/usr/local/bin/awg-dns-healthcheck.sh"
DNS_HEALTH_LOG="/var/log/awg-dns-health.log"

# Каскад (port forwarding на зарубежный сервер) — Туннели (5)
CASCADE_DIR="/etc/awg-cascade"
CASCADE_RULES="$CASCADE_DIR/rules.conf"
CASCADE_SERVICE="/etc/systemd/system/awg-cascade.service"
CASCADE_APPLY_SCRIPT="/usr/local/bin/awg-cascade-apply.sh"
CASCADE_TAG="awg-cascade"
CASCADE_LOG="/var/log/awg-cascade.log"
CASCADE_LOG_MAX=1048576  # 1 MB — после превышения ротация

# NAT-персистентность (do_install) — fallback для образов без ifupdown
NAT_PERSIST_SERVICE="/etc/systemd/system/awg-nat.service"
NAT_PERSIST_SCRIPT="/usr/local/bin/awg-nat-apply.sh"

# ── Логирование ────────────────────────────────────────────
_log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_err()   { _log "ERROR" "$@"; }

# Универсальный пул — домены работают И в РФ (не в реестре РКН), И в мире.
# Используются как для SNI/мимикри TLS, так и для QUIC/SIP/DTLS.
# RU и WORLD массивы оставлены идентичными — choose_region сохранён для совместимости
# со старыми конфигами (метка "# Region: ru" в шапке awg0.conf).

# TLS SNI (ClientHello) — крупные мировые сайты + РФ-сайты для RU-региона
# RU = WORLD + домены крупных российских сервисов (открытые в РФ, отвечают на ping)
TLS_DOMAINS_RU=(
  # WORLD-набор (мировые сайты, открытые в РФ)
  "google.com" "github.com" "gitlab.com" "stackoverflow.com"
  "microsoft.com" "apple.com" "amazon.com"
  "mozilla.org" "kernel.org" "debian.org" "ubuntu.com"
  "cdn.jsdelivr.net" "unpkg.com" "pypi.org"
  "hetzner.com" "ovhcloud.com" "digitalocean.com"
  "steampowered.com" "spotify.com"
  # РФ-набор (массовый трафик внутри страны, TCP/443 + ping OK)
  "ya.ru" "vk.com" "mail.ru" "ozon.ru" "wildberries.ru"
  "rutube.ru" "gosuslugi.ru"
)
DTLS_DOMAINS_RU=(
  # Только домены, реально отвечающие на ICMP ping.
  # Удалены: stun.stunprotocol.org (мёртв), stun.services.mozilla.com (закрыт
  # в 2023), global.stun.twilio.com (требует API-ключ, дропает ICMP).
  "meet.jit.si" "stun.nextcloud.com" "stun.sipgate.net"
  "stun.zoiper.com" "stun.l.google.com"
)
SIP_DOMAINS_RU=(
  # Глобальные
  "sip.zadarma.com" "sip.iptel.org" "sip.linphone.org" "sip.antisip.com"
  # Германия
  "sip.dus.net" "sip.easybell.de"
  # NL / CH / IT
  "sip.voys.nl" "sip.peoplefone.ch" "sip.messagenet.it"
  # UDP-only серверы убраны: sipgate.de, sip.1und1.de, sip.ovh.net,
  # sip.voipfone.co.uk, sip.voiptalk.org, sip.gradwell.com,
  # sip.voipgate.com, sip.bahnhof.se — все они слушают только UDP/5060
  # и блокируют ICMP, поэтому фоллбэк на ping тоже не работает.
)
# HTTP/3 (QUIC) — реально отвечают h3 на UDP/443, не заблокированы ТСПУ
QUIC_DOMAINS_RU=(
  # Удалены ICMP-блокирующие: cdn-apple.com, steamstatic.com, steamcontent.com.
  # (h3 у них работает, но ping-проверка систематически даёт fail.)
  # Удалены HTTP/3-нерабочие: wikipedia.org, wikimedia.org, bunny.net, cdn77.com,
  # gcdn.co, g.gcdn.co (TCP/ping OK, но h3 не отвечает или офлайн).
  "google.com" "youtube.com"
  "cdn.jsdelivr.net" "unpkg.com"
  "icloud.com" "mzstatic.com"
  "fastly.net" "a.ssl.fastly.net"
  "b-cdn.net"
  "github.com" "objects.githubusercontent.com"
  # РФ-домены с подтверждённой поддержкой HTTP/3
  "ozon.ru"
)

# WORLD — универсальный пул (мировые сайты без РФ-специфики)
TLS_DOMAINS_WORLD=(
  "google.com" "github.com" "gitlab.com" "stackoverflow.com"
  "microsoft.com" "apple.com" "amazon.com"
  "mozilla.org" "kernel.org" "debian.org" "ubuntu.com"
  "cdn.jsdelivr.net" "unpkg.com" "pypi.org"
  "hetzner.com" "ovhcloud.com" "digitalocean.com"
  "steampowered.com" "spotify.com"
)
DTLS_DOMAINS_WORLD=("${DTLS_DOMAINS_RU[@]}")
SIP_DOMAINS_WORLD=("${SIP_DOMAINS_RU[@]}")
QUIC_DOMAINS_WORLD=(
  "google.com" "youtube.com"
  "cdn.jsdelivr.net" "unpkg.com"
  "icloud.com" "mzstatic.com"
  "fastly.net" "a.ssl.fastly.net"
  "b-cdn.net"
  "github.com" "objects.githubusercontent.com"
)

# Активные пулы (устанавливаются при выборе региона)
TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_WORLD[@]}")
DTLS_DOMAINS=("${DTLS_DOMAINS_WORLD[@]}")
SIP_DOMAINS=("${SIP_DOMAINS_WORLD[@]}")
QUIC_DOMAINS=("${QUIC_DOMAINS_WORLD[@]}")

# Глобальная переменная региона
# shellcheck disable=SC2034  # используется в будущих расширениях и логах
SERVER_REGION="world"

choose_region() {
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                  Регион сервера${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}1${N}  Европа / Мир "
  echo -e "  ${G}2${N}  Россия — RU "
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  local REGION_CHOICE
  read_choice REGION_CHOICE "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" 1 2 1
  case $REGION_CHOICE in
    2)
      SERVER_REGION="ru"
      TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_RU[@]}")
      DTLS_DOMAINS=("${DTLS_DOMAINS_RU[@]}")
      SIP_DOMAINS=("${SIP_DOMAINS_RU[@]}")
      QUIC_DOMAINS=("${QUIC_DOMAINS_RU[@]}")
      echo -e "${G}  √ Регион: Россия${N}"
      ;;
    1)
      SERVER_REGION="world"
      TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_WORLD[@]}")
      DTLS_DOMAINS=("${DTLS_DOMAINS_WORLD[@]}")
      SIP_DOMAINS=("${SIP_DOMAINS_WORLD[@]}")
      QUIC_DOMAINS=("${QUIC_DOMAINS_WORLD[@]}")
      echo -e "${G}  √ Регион: Европа / Мир${N}"
      ;;
  esac
}

# Сканирование пула доменов — параллельный пинг
# Возвращает результат через глобальную переменную SCAN_POOL_RESULT (массив доступных доменов)
# ВАЖНО: не вызывать в subshell (| или $(...)) — массив потеряется
SCAN_POOL_RESULT=()

# Универсальная проверка доступности хоста.
# Профиль tls → TCP-connect через /dev/tcp на :443 (быстро, обходит ICMP-блок).
# Профили sip/dtls/quic → ICMP ping (для SIP — потому что большинство серверов
# слушают UDP/5060, а не TCP/5060; для STUN/QUIC — UDP-only сервисы).
# Вывод stdout:
#   "ok <ms>" при успехе (ms = округлённое время отклика)
#   "fail"    при недоступности
# Аргументы: $1 = profile (tls|sip|dtls|quic), $2 = host
_probe_host() {
  local profile="$1" host="$2"
  local port="" use_tcp=0
  case "$profile" in
    tls)  port=443;  use_tcp=1 ;;
    sip|dtls|quic|*) use_tcp=0 ;;
  esac

  if [[ $use_tcp -eq 1 ]]; then
    # TCP-connect через /dev/tcp с замером времени.
    # ВАЖНО: SECONDS — bash-builtin, секундная точность; для ms используем EPOCHREALTIME (bash 5+)
    local t0 t1 ms_int
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
      t0=$EPOCHREALTIME
      if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        t1=$EPOCHREALTIME
        exec 3<&- 3>&- 2>/dev/null || true
        # Разница в секундах с дробной частью → миллисекунды
        ms_int=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d", (b-a)*1000}')
        [[ $ms_int -lt 1 ]] && ms_int=1
        echo "ok $ms_int"
      else
        echo "fail"
      fi
    else
      # Bash < 5: без точного ms — отдаём фиктивные 50мс при успехе
      if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        exec 3<&- 3>&- 2>/dev/null || true
        echo "ok 50"
      else
        echo "fail"
      fi
    fi
  else
    # ICMP ping для UDP-only сервисов (STUN/QUIC) — fallback
    local ms
    ms=$(timeout 2 ping -c 1 -W 1 "$host" 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2 || true)
    if [[ -n "$ms" ]]; then
      printf "ok %.0f\n" "$ms"
    else
      echo "fail"
    fi
  fi
}

scan_pool() {
  # shellcheck disable=SC2034  # pool_name для отладки/логов
  local pool_name="$1"
  shift
  local domains=("$@")
  local available=()
  local domain
  local tmpdir="/tmp/awg_ping_$$"
  mkdir -p "$tmpdir"

  # Ловушка на прерывание — cleanup + выход
  trap 'rm -rf "$tmpdir"; exit 1' INT TERM

  # Профиль для проверки: tls/sip → TCP-connect, dtls/quic → ping
  # pool_name приходит как "tls"|"sip"|"dtls"|"quic" из select_random_domain
  local probe_profile="$pool_name"

  # Запускаем все проверки параллельно
  for domain in "${domains[@]}"; do
    (
      result=$(_probe_host "$probe_profile" "$domain")
      if [[ "$result" == ok* ]]; then echo "ok"; else echo "fail"; fi
    ) > "$tmpdir/${domain//./_}" &
  done
  wait  # Ждём завершения всех

  # Собираем результаты
  for domain in "${domains[@]}"; do
    local key="${domain//./_}"
    local result
    result=$(cat "$tmpdir/$key" 2>/dev/null || echo "fail")
    if [[ "$result" == "ok" ]]; then
      available+=("$domain")
    fi
  done

  # Cleanup при нормальном завершении
  rm -rf "$tmpdir"
  trap - INT TERM
  SCAN_POOL_RESULT=("${available[@]+"${available[@]}"}")
}

# Выбор случайного домена из пула.
# Если пул полностью недоступен — возвращает пустую строку.
# Caller должен реализовать fallback на следующий пул.
select_random_domain() {
  local profile="$1"
  local domains=()
  case "$profile" in
    "tls")  domains=("${TLS_CLIENT_HELLO_DOMAINS[@]}") ;;
    "dtls") domains=("${DTLS_DOMAINS[@]}") ;;
    "sip")  domains=("${SIP_DOMAINS[@]}") ;;
    "quic") domains=("${QUIC_DOMAINS[@]}") ;;
    *)      domains=("${TLS_CLIENT_HELLO_DOMAINS[@]}") ;;
  esac

  # Сканируем пул — выбираем только из доступных
  scan_pool "$profile" "${domains[@]}"
  local available=("${SCAN_POOL_RESULT[@]}")

  if [[ ${#available[@]} -gt 0 ]]; then
    echo "${available[$((RANDOM % ${#available[@]}))]}"
  else
    echo ""
  fi
}

# Единый Python генератор для всех профилей мимикрии
# [PATCHED v3] TLS+QUIC из payloadGen: GREASE, Chrome-fingerprint, реальное
# шифрование QUIC (RFC9001+fallback), лёгкий TLS-паддинг (доставка I5),
# --only-i1 распознаётся в любой позиции argv. Контракт вывода не изменён.
#
# [v4] Компактный режим по умолчанию. I1-I5 уходят перед КАЖДЫМ рукопожатием,
# поэтому лишние сотни байт — это и трафик, и время установки, и раздутый
# клиентский конфиг (плотный QR). Урезано только то, что не ломает разбор
# пакета его же протоколом:
#   TLS  ~340 → ~220 Б: пустой legacy_session_id (разрешён TLS 1.3), без
#        padding-расширения и Chrome-специфики (ALPS, compress_certificate,
#        status_request, SCT), без legacy-шифров. SNI, key_share x25519,
#        supported_versions, sigalgs, ALPN и GREASE на месте.
#   SIP  ~540 → ~390 Б: остаётся обязательный минимум RFC 3261 плюс Contact и
#        Expires; выброшены необязательные Allow/Supported и длинный User-Agent.
#   QUIC ~1800 → ~1500 Б суммарно: I1 остаётся 1200 Б — RFC 9000 §14.1 требует
#        этого от любой клиентской датаграммы с Initial, короткий Initial
#        сервер обязан отбросить, а для DPI это готовая аномалия. Вместо
#        второго Initial (был 300-600 Б, то есть невалидный) идёт 1-RTT пакет.
#   DNS  без изменений — 39-46 Б и так минимум.
# AWG_CPS_FULL=1 возвращает прежние размеры (флаг --full генератору).
#
# CPS_GENERATOR_BEGIN v1 — якорь для awg_bot/awgbot/cps.py: бот вырезает тело
# генератора из установленного awg2, чтобы не дублировать криптологику у себя.
# Маркеры BEGIN/END не удалять и не переименовывать; при несовместимом
# изменении контракта вывода поднимать номер версии в обоих маркерах.
_CPS_GENERATOR='
import sys, secrets, struct, random, signal
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)  # чистое поведение при обрыве пайпа
except Exception:
    pass

# == Utilities ==
_WARNED = set()
def _warn_once(msg):
    # Один и тот же дефект не должен засорять вывод: генератор строит до 5
    # пакетов за запуск, а причина деградации у них общая.
    if msg in _WARNED:
        return
    _WARNED.add(msg)
    sys.stderr.write("[CPS] WARN: %s\n" % msg)

def rh(n):  return secrets.token_bytes(n)
def ri(a, b):
    if a > b: a, b = b, a
    return a + secrets.randbelow(b - a + 1)
def rc(lst): return lst[secrets.randbelow(len(lst))]
def u16(v): return struct.pack(">H", v & 0xFFFF)
def u32(v): return struct.pack(">I", v & 0xFFFFFFFF)
def u24(v): return struct.pack(">I", v)[1:]
def to_cps(raw): return "<b 0x%s>" % raw.hex()

def to_cps_parts(parts):
    """
    Собирает цепочку I-пакета из кусков. Кусок — это либо bytes (уходит как
    <b 0x..>), либо ("r"|"rc"|"rd", n) — модификатор, который КЛИЕНТ заполняет
    заново при каждой отправке: <r> случайными байтами, <rc> латинскими
    буквами, <rd> цифрами.

    Зачем: пакет, целиком записанный как <b 0x..>, уходит байт в байт одинаковым
    перед каждым рукопожатием — это межсессионная сигнатура, ровно то, от чего
    мимикрия и защищает. Модификаторы делают его каждый раз другим, не меняя ни
    длины, ни структуры, и попутно резко укорачивают строку в конфиге: <r 900>
    вместо 1800 hex-символов.

    Теги b/r/rc/rd понимают оба известных движка (amneziawg-go device/obf.go и
    ядерный модуль src/junk.c). <c> есть только у ядра, <d>/<ds>/<dz> только у
    go, поэтому здесь их нет: незнакомый тег отвергается вместе со всем пакетом,
    а не сам по себе. Порядок кусков сохраняется (jp_spec_setup собирает список
    в обратном порядке вставки, то есть в порядке записи).
    """
    out = []
    for p in parts:
        if isinstance(p, tuple):
            out.append("<%s %d>" % (p[0], p[1]))
        elif p:
            out.append("<b 0x%s>" % p.hex())
    return "".join(out)


# Смещение поля random в ClientHello: record(5) + handshake(4) + legacy_version(2).
# 32 байта, которые настоящий клиент разыгрывает на каждое соединение.
_TLS_RANDOM_OFFSET = 11
_TLS_RANDOM_LEN = 32

def tls_chain(domain=None):
    pkt = gen_tls_clienthello(domain)
    head = _TLS_RANDOM_OFFSET
    tail = head + _TLS_RANDOM_LEN
    return to_cps_parts([pkt[:head], ("r", _TLS_RANDOM_LEN), pkt[tail:]])

def secure_shuffle(lst):
    for i in range(len(lst) - 1, 0, -1):
        j = secrets.randbelow(i + 1)
        lst[i], lst[j] = lst[j], lst[i]
    return lst

def rand_private_ip():
    kind = secrets.randbelow(3)
    if kind == 0:
        return "10.%d.%d.%d" % (ri(1, 254), ri(0, 255), ri(2, 254))
    elif kind == 1:
        return "172.%d.%d.%d" % (ri(16, 31), ri(0, 255), ri(2, 254))
    else:
        return "192.168.%d.%d" % (ri(0, 255), ri(2, 254))

def _weighted_choice(items, weights):
    total = sum(weights)
    r = secrets.randbelow(total)
    acc = 0
    for item, w in zip(items, weights):
        acc += w
        if r < acc:
            return item
    return items[-1]

# == Args ==
# profile = argv[1]; --only-i1 может прийти в любой позиции (Тулза шлёт argv[3],
# бот шлёт argv[2] без domain). Domain = первый позиционный аргумент после
# profile, который не является флагом --only-i1.
ALLOWED_PROFILES = ("quic", "sip", "dns", "tls")
_args = sys.argv[1:]
ONLY_I1 = "--only-i1" in _args
# Компактный режим — по умолчанию: пакеты короче, но остаются валидными для
# своего протокола. --full возвращает прежние «толстые» пакеты.
COMPACT = "--full" not in _args
_pos = [a for a in _args if not a.startswith("--")]
PROFILE = _pos[0] if len(_pos) > 0 else "dns"
DOMAIN  = _pos[1] if len(_pos) > 1 else ""

if PROFILE not in ALLOWED_PROFILES:
    sys.stderr.write("[CPS] WARN: unknown profile %s, fallback=dns\n" % PROFILE)
    PROFILE = "dns"

DOMAIN_POOL = [
    "google.com","github.com","gitlab.com","stackoverflow.com",
    "microsoft.com","apple.com","amazon.com",
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

# GREASE values (RFC 8701) - Chrome inserts these to keep middleboxes honest
GREASE_VALUES = [
    0x0A0A, 0x1A1A, 0x2A2A, 0x3A3A, 0x4A4A, 0x5A5A, 0x6A6A, 0x7A7A,
    0x8A8A, 0x9A9A, 0xAAAA, 0xBABA, 0xCACA, 0xDADA, 0xEAEA, 0xFAFA,
]
def grease(excluded=None):
    pool = [v for v in GREASE_VALUES if v != excluded] or GREASE_VALUES
    return rc(pool)

# ================================================================
# TLS 1.3 ClientHello - Chrome-like fingerprint (ported from payloadGen)
# Upgrades over the legacy engine: GREASE in ciphers + first/last ext,
# full Chrome extension set in Chrome order, padding to 512B.
# ================================================================
def _ext(etype, data):
    return u16(etype) + u16(len(data)) + data

def gen_tls_clienthello(domain=None):
    host = (domain or DOMAIN).encode()
    g1 = grease()
    g2 = grease(g1)

    # ClientHello ciphers: GREASE first, then Chrome real order
    cipher_list = [0x1301,0x1302,0x1303,0xC02B,0xC02F,0xC02C,0xC030,
                   0xCCA9,0xCCA8,0xC013,0xC014,0x009C,0x009D,0x002F,0x0035]
    if COMPACT:
        # только TLS 1.3 + современные ECDHE-наборы: клиент без legacy-шифров
        # выглядит обычно и экономит 12 байт
        cipher_list = [0x1301,0x1302,0x1303,0xC02B,0xC02F,0xCCA9,0xCCA8]
    ciphers = u16(g1)
    for c in cipher_list:
        ciphers += u16(c)

    # --- build extensions in Chrome order ---
    exts = b""
    # grease (empty)
    exts += _ext(g1, b"")
    # sni
    sni_entry = b"\x00" + u16(len(host)) + host
    exts += _ext(0x0000, u16(len(sni_entry)) + sni_entry)
    # extended_master_secret (empty)
    exts += _ext(0x0017, b"")
    # renegotiation_info (1 byte len=0)
    exts += _ext(0xff01, b"\x00")
    # supported_groups: GREASE + x25519 + secp256r1 + secp384r1
    groups = u16(grease()) + b"\x00\x1d" + b"\x00\x17"
    if not COMPACT:
        groups += b"\x00\x18"
    exts += _ext(0x000a, u16(len(groups)) + groups)
    # ec_point_formats: uncompressed
    exts += _ext(0x000b, b"\x01\x00")
    # session_ticket (empty)
    exts += _ext(0x0023, b"")
    # alpn: h2, http/1.1
    alpn_protos = b"\x02h2\x08http/1.1"
    exts += _ext(0x0010, u16(len(alpn_protos)) + alpn_protos)
    # status_request: OCSP (Chrome-only, в компактном режиме не нужен)
    if not COMPACT:
        exts += _ext(0x0005, b"\x01\x00\x00\x00\x00")
    # signature_algorithms
    _sig_list = [0x0403,0x0804,0x0401,0x0503,0x0805,0x0501,0x0806,0x0601]
    if COMPACT:
        _sig_list = _sig_list[:5]
    sigs = b""
    for s in _sig_list:
        sigs += u16(s)
    exts += _ext(0x000d, u16(len(sigs)) + sigs)
    # signed_certificate_timestamp (empty)
    if not COMPACT:
        exts += _ext(0x0012, b"")
    # supported_versions: GREASE + TLS1.3 + TLS1.2
    sv = u16(grease()) + b"\x03\x04" + b"\x03\x03"
    exts += _ext(0x002b, bytes([len(sv)]) + sv)
    # key_share: GREASE(empty) + x25519(32B)
    gks = u16(grease()) + u16(0)
    ks_entry = b"\x00\x1d" + u16(32) + rh(32)
    ks_list = gks + ks_entry
    exts += _ext(0x0033, u16(len(ks_list)) + ks_list)
    # psk_key_exchange_modes: psk_dhe_ke
    exts += _ext(0x002d, b"\x01\x01")
    if not COMPACT:
        # compress_certificate: brotli
        exts += _ext(0x001b, b"\x02\x00\x02")
        # application_settings (ALPS): h2
        exts += _ext(0x4469, b"\x03\x02h2")
    # secondary grease (empty)
    exts += _ext(g2, b"")
    # Light padding (like real Chrome): small random, NO fill to 512.
    # Filling to 512 produced ~200 zero bytes per packet -> large I packets
    # that mobile AWG does not always deliver (especially I5), plus the long
    # zero tail is itself a signature. Chrome only pads slightly.
    pad_len = 0 if COMPACT else ri(0, 48)
    if pad_len > 0:
        exts += _ext(0x0015, b"\x00" * pad_len)

    legacy_version = b"\x03\x03"
    random_bytes   = rh(32)
    # TLS 1.3 разрешает пустой legacy_session_id; 32 байта Chrome шлёт ради
    # режима совместимости с 1.2. В компактном режиме экономим 32 байта.
    session_id     = b"" if COMPACT else rh(32)
    sid            = bytes([len(session_id)]) + session_id
    comp = b"\x01\x00"
    body = legacy_version + random_bytes + sid + u16(len(ciphers)) + ciphers + comp + u16(len(exts)) + exts
    hs   = b"\x01" + u24(len(body)) + body
    rec  = b"\x16" + b"\x03\x01" + u16(len(hs)) + hs
    return rec

# ================================================================
# QUIC Initial - ported from payloadGen (real CRYPTO frame + ClientHello)
# Optional real encryption if the cryptography lib is present, else masked payload.
# ================================================================
_QUIC_VERSION = b"\x00\x00\x00\x01"  # QUIC v1 (RFC 9000)

def _quic_varint(v):
    if v < 64:
        return bytes([v])
    elif v < 16384:
        return bytes([0x40 | ((v >> 8) & 0x3f), v & 0xff])
    elif v < 1073741824:
        return bytes([0x80 | ((v >> 24) & 0x3f), (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff])
    else:
        return bytes([0xc0 | ((v >> 56) & 0x3f)]) + struct.pack(">Q", v)[1:]

def _quic_crypto_frame(ch):
    # CRYPTO frame: type=0x06, offset=0, length, data
    return b"\x06" + _quic_varint(0) + _quic_varint(len(ch)) + ch

def _try_quic_encrypt(dcid, header_wo_pn, pn, pn_len, payload):
    # Real QUIC Initial protection (RFC 9001). Returns protected packet or None.
    try:
        from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        import hmac as _hmac, hashlib as _hashlib
    except Exception:
        _warn_once("нет python3-cryptography — QUIC Initial уйдёт БЕЗ шифрования "
                   "(payload не похож на шифротекст, DPI отличит от Chrome). "
                   "Ставится так: apt-get install -y python3-cryptography")
        return None
    try:
        INITIAL_SALT = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
        def hkdf_extract(salt, ikm):
            return _hmac.new(salt, ikm, _hashlib.sha256).digest()
        def hkdf_expand_label(secret, label, length):
            full = b"tls13 " + label
            info = u16(length) + bytes([len(full)]) + full + b"\x00"
            hk = HKDFExpand(algorithm=hashes.SHA256(), length=length, info=info)
            return hk.derive(secret)
        initial_secret = hkdf_extract(INITIAL_SALT, dcid)
        client_secret = hkdf_expand_label(initial_secret, b"client in", 32)
        key = hkdf_expand_label(client_secret, b"quic key", 16)
        iv  = hkdf_expand_label(client_secret, b"quic iv", 12)
        hp  = hkdf_expand_label(client_secret, b"quic hp", 16)
        # nonce = iv XOR pn (pn right-aligned)
        pn_int = int.from_bytes(pn, "big")
        nonce = bytearray(iv)
        pn_bytes_full = pn_int.to_bytes(12, "big")
        nonce = bytes(a ^ b for a, b in zip(nonce, pn_bytes_full))
        aad = header_wo_pn + pn
        ct = AESGCM(key).encrypt(nonce, payload, aad)
        # header protection
        sample = ct[4 - pn_len:4 - pn_len + 16]
        enc = Cipher(algorithms.AES(hp), modes.ECB()).encryptor()
        mask = enc.update(sample) + enc.finalize()
        first = header_wo_pn[0] ^ (mask[0] & 0x0f)
        prot_pn = bytes(pn[i] ^ mask[1 + i] for i in range(pn_len))
        return bytes([first]) + header_wo_pn[1:] + prot_pn + ct
    except Exception as e:
        _warn_once("сбой QUIC-шифрования (%s: %s) — Initial уйдёт БЕЗ шифрования, "
                   "мимикрия слабее" % (type(e).__name__, e))
        return None

def gen_quic_initial(domain=None):
    TARGET = 1200
    ch = gen_tls_clienthello(domain)        # reuse Chrome ClientHello as QUIC CRYPTO
    crypto_frame = _quic_crypto_frame(ch)
    dcid = rh(8)
    scid = rh(8)
    pn_len = 4
    pn = rh(pn_len)
    # header before length+pn:  first | ver | dcidlen | dcid | scidlen | scid | tokenlen
    pre = bytes([0xC0 | (pn_len - 1)]) + _QUIC_VERSION + bytes([8]) + dcid + bytes([8]) + scid + b"\x00"
    # pad CRYPTO frame with PADDING(0x00) to fill the 1200B datagram
    overhead = len(pre) + 2 + pn_len + 16  # +2 varint length, +16 AEAD tag
    pad = TARGET - overhead - len(crypto_frame)
    payload = crypto_frame + (b"\x00" * pad if pad > 0 else b"")
    length_field = pn_len + len(payload) + 16
    header_wo_pn = pre + u16(0x4000 | length_field)
    enc = _try_quic_encrypt(dcid, header_wo_pn, pn, pn_len, payload)
    if enc is not None:
        pkt = enc
    else:
        # masked fallback: plain header + pn + payload, random-padded to TARGET
        pkt = header_wo_pn + pn + payload
    if len(pkt) < TARGET:
        pkt = pkt + rh(TARGET - len(pkt))
    elif len(pkt) > TARGET:
        pkt = pkt[:TARGET]
    return pkt, dcid, _QUIC_VERSION

def gen_quic_second_initial(dcid, version):
    # RFC 9000 §14.1: любая клиентская датаграмма с Initial-пакетом обязана
    # быть не меньше 1200 байт, иначе сервер её отбрасывает, а DPI видит
    # аномалию. Раньше здесь было 300-600 байт — то есть заведомо неправильный
    # пакет. Дополняем до 1200 (в компактном режиме этот пакет не шлётся вовсе).
    fb = rc([0xC0, 0xC0, 0xC3])
    pn_len = (fb & 0x03) + 1
    scid = rh(8)
    TARGET2 = 1200
    enc_size = TARGET2 - 26 - pn_len
    if enc_size < 1:
        enc_size = 1
    plen_val = pn_len + enc_size
    pl_varint = u16(0x4000 | plen_val)
    pn = rh(pn_len)
    payload = rh(enc_size)
    pkt = bytes([fb]) + version + bytes([8]) + dcid + bytes([8]) + scid + b"\x00" + pl_varint + pn + payload
    if len(pkt) != TARGET2:
        pkt = pkt[:TARGET2] if len(pkt) > TARGET2 else pkt + rh(TARGET2 - len(pkt))
    return pkt

def gen_quic_short():
    pn_len = ri(1, 4)
    spin = ri(0, 1) << 5
    key  = ri(0, 1) << 2
    fb   = 0x40 | spin | key | (pn_len - 1)
    return bytes([fb]) + rh(8) + rh(pn_len) + rh(ri(40, 90))

# ================================================================
# SIP REGISTER (unchanged from legacy engine)
# ================================================================
SIP_UA_POOL = [
    "Linphone/5.2.5 (belle-sip/5.2.0)", "Zoiper rv2.10.20.4",
    "MicroSIP/3.21.4", "Bria 6.5.1", "PortSIP UA 16.4",
]
# Плейсхолдер под тег-модификатор внутри текстового сообщения. Байт 0x01 в
# SIP-запросе появиться не может, поэтому по нему безопасно резать.
_SIP_MARK = "\x01"

def gen_sip():
    host = rc(SIP_POOL)
    user = rc(["alice","bob","100","200","sip","user","client"]) + str(ri(10,9999))
    lip = rand_private_ip()
    lport = rc([5060, 5062, 5080, 5160, ri(10000, 65000)])
    # branch, tag и Call-ID — токены, уникальные для каждой транзакции. Если
    # запечь их в <b 0x..>, клиент будет слать один и тот же Call-ID перед
    # каждым рукопожатием: для наблюдателя это отпечаток устройства, заметный
    # лучше, чем сам факт VPN. Уходят тегами <rc N> — буквы допустимы в token
    # по RFC 3261 §25.1.
    branch_len, tag_len, callid_len = 14, 8, 16
    branch = "z9hG4bK" + _SIP_MARK
    tag = _SIP_MARK
    callid = "%s@%s" % (_SIP_MARK, host)
    cseq = ri(1, 50)
    transport = rc(["udp","udp","udp","udp","tcp"])
    ua = rc(SIP_UA_POOL)
    # Обязательный минимум RFC 3261 §8.1.1 для REGISTER: request-line, Via с
    # branch, Max-Forwards, From с tag, To, Call-ID, CSeq, Content-Length.
    # Contact и Expires тоже оставляем — без них REGISTER бессмысленный и
    # выглядит поддельным. Allow/Supported/длинный User-Agent — необязательные
    # заголовки: в компактном режиме их не шлём, экономя ~170 байт.
    lines = [
        "REGISTER sip:%s SIP/2.0" % host,
        "Via: SIP/2.0/%s %s:%d;branch=%s;rport" % (transport.upper(), lip, lport, branch),
        "Max-Forwards: 70",
        "From: <sip:%s@%s>;tag=%s" % (user, host, tag),
        "To: <sip:%s@%s>" % (user, host),
        "Call-ID: %s" % callid,
        "CSeq: %d REGISTER" % cseq,
        "Contact: <sip:%s@%s:%d;transport=%s>" % (user, lip, lport, transport),
    ]
    if COMPACT:
        lines += [
            "User-Agent: %s" % ua.split("/")[0],
            "Expires: %d" % rc([300,600,1800,3600]),
        ]
    else:
        lines += [
            "User-Agent: %s" % ua,
            "Allow: INVITE, ACK, CANCEL, BYE, REFER, OPTIONS, NOTIFY, SUBSCRIBE, PRACK, MESSAGE, INFO, UPDATE",
            "Supported: replaces, outbound, gruu, path",
            "Expires: %d" % rc([300,600,1800,3600]),
        ]
    # Тело из случайных букв: клиент заполняет его заново на каждую отправку,
    # поэтому одинаковых REGISTER подряд не бывает. Длина объявлена в
    # Content-Length честно, иначе сообщение перестанет быть валидным.
    body_len = ri(16, 48)
    lines += ["Content-Length: %d" % body_len, "", ""]

    # Режем текст по плейсхолдерам и вставляем модификаторы на их места.
    # Порядок совпадает с порядком появления: branch, tag, Call-ID.
    text = "\r\n".join(lines)
    specs = [("rc", branch_len), ("rc", tag_len), ("rc", callid_len)]
    chunks = text.split(_SIP_MARK)
    if len(chunks) != len(specs) + 1:
        # плейсхолдер потерялся — отдаём сообщение целиком, без модификаторов
        return [text.replace(_SIP_MARK, "").encode(), ("rc", body_len)]
    parts = []
    for i, chunk in enumerate(chunks):
        parts.append(chunk.encode())
        if i < len(specs):
            parts.append(specs[i])
    parts.append(("rc", body_len))
    return parts

# ================================================================
# DNS Query w/ EDNS0 (unchanged from legacy engine)
# ================================================================
def gen_dns(domain=None):
    host = domain or DOMAIN
    flags = b"\x01\x00"
    counts = b"\x00\x01\x00\x00\x00\x00\x00\x01"
    qn = b""
    for lbl in host.split("."):
        lbl_b = lbl.encode()[:63]
        qn += bytes([len(lbl_b)]) + lbl_b
    qn += b"\x00"
    qtype = u16(_weighted_choice([1, 28, 16], [60, 30, 10]))
    qclass = b"\x00\x01"
    udp_size = rc([1232, 4096])
    do_bit = rc([0x0000, 0x8000])
    opt_rr = b"\x00" + b"\x00\x29" + u16(udp_size) + b"\x00\x00" + u16(do_bit) + b"\x00\x00"
    return flags + counts + qn + qtype + qclass + opt_rr

# == Dispatch (identical contract: 1 line per packet, up to 5) ==
if PROFILE == "sip":
    def _sip_line():
        return to_cps_parts(gen_sip())
    print(_sip_line())
    if not ONLY_I1:
        for _ in range(4):
            print(_sip_line())

elif PROFILE == "dns":
    print("<r 2><b 0x%s>" % gen_dns(DOMAIN).hex())
    if not ONLY_I1:
        pool = DOMAIN_POOL.copy()
        secure_shuffle(pool)
        for i in range(4):
            print("<r 2><b 0x%s>" % gen_dns(pool[i % len(pool)]).hex())

elif PROFILE == "tls":
    print(tls_chain(DOMAIN))
    if not ONLY_I1:
        pool = DOMAIN_POOL.copy()
        secure_shuffle(pool)
        for i in range(4):
            print(tls_chain(pool[i % len(pool)]))

else:  # quic
    def _quic_initial_line(pkt):
        # Всё после заголовка и первых байт шифротекста — для наблюдателя
        # неразличимый шум (AEAD), поэтому хвост отдаём тегом <r>: пакет
        # остаётся ровно 1200 байт и валидным по RFC 9000 §14.1, но каждый раз
        # другим, а строка в конфиге короче примерно вчетверо.
        tail = ri(700, 1000)
        return to_cps_parts([pkt[:len(pkt) - tail], ("r", tail)])

    def _quic_short_line():
        # У короткого заголовка структурный только первый байт (fixed bit,
        # spin, key phase, длина номера пакета) — остальное шум.
        pkt = gen_quic_short()
        return to_cps_parts([pkt[:1], ("r", len(pkt) - 1)])

    i1_pkt, dcid, ver = gen_quic_initial(DOMAIN)
    print(_quic_initial_line(i1_pkt))
    if not ONLY_I1:
        # RFC 9000 §14.1: КЛИЕНТСКАЯ датаграмма с Initial-пакетом обязана быть
        # не меньше 1200 байт. Короткий второй Initial — не «экономия», а
        # заметная аномалия: раньше здесь уходили 300-600 байт. В компактном
        # режиме вместо него идёт 1-RTT пакет с коротким заголовком: он
        # валиден при любой длине и вчетверо короче.
        if COMPACT:
            print(_quic_short_line())
        else:
            print(_quic_initial_line(gen_quic_second_initial(dcid, ver)))
        for _ in range(3):
            print(_quic_short_line())
'
# CPS_GENERATOR_END v1


# Генерация I1-I5 через Python
# $1 = profile (quic|sip|dns), $2 = domain (опционально), $3 = --only-i1 (опционально)
gen_cps_i1() {
  local profile="${1:-quic}"
  local domain="${2:-}"
  local only_i1="${3:-}"
  # AWG_CPS_FULL=1 — прежние «толстые» пакеты (см. [v4] выше)
  local full=""
  [[ -n "${AWG_CPS_FULL:-}" ]] && full="--full"
  python3 -c "$_CPS_GENERATOR" "$profile" "$domain" ${only_i1:+"$only_i1"} ${full:+"$full"}
}


# Алгоритм:
# 1. Профиль 1-4: выбираем домен из пула через scan_pool → select_random_domain
#    Fallback при пустом пуле: домен НЕ подменяется на другой профиль — в
#    генератор уходит пустая строка, и он берёт случайный домен из своего
#    встроенного DOMAIN_POOL. Профиль мимикрии (tls/dtls/sip/quic) при этом
#    сохраняется: смена профиля из-за недоступности пула поменяла бы сигнатуру
#    на протокол, который пользователь не выбирал.
# 2. Профиль 5: ручной ввод домена + выбор CPS-профиля (tls/dtls/sip/dns)
# 3. OBF_LEVEL=1 отключает мимикрию (I1="", MIMICRY_PROFILE="none")
#
# Все профили генерируют I1-I5 через CPS-генератор (_CPS_GENERATOR).
# Глобальные переменные на выходе: I1, I2, I3, I4, I5, MIMICRY_PROFILE
# ── Профили AWG (Lite / Standard / Pro) ──────────────────
# AWG_PROFILE определяет ВСЁ:
#   - параметры Jc/Jmin/Jmax/S1-S4/H1-H4 (gen_awg_params)
#   - уровень обфускации (OBF_LEVEL)
#   - профиль мимикрии (MIMICRY_PROFILE)
# Маркер пишется первой строкой awg0.conf: "# AWG_PROFILE=<value>"
# ── Целевой клиент ────────────────────────────────────────
# От клиента зависит не «сколько параметров он потянет», а что он вообще
# читает. Здесь только проверенное:
#  • WireSock (форк BoringTun под Windows) не читает I1-I5 совсем. По
#    документации вендора поля «silently ignored»: туннель поднимется, мимикрии
#    в трафике не будет, ошибки тоже не будет. Худший вид поломки — тихий.
#  • Keenetic OS 4.x: чем именно разбирается цепочка, по исходникам установить
#    не удалось, поэтому цепочку держим короткой (I1, профиль DNS).
#  • AmneziaWG для Windows до v2.0.2 не принимал H выше 2^31-1. Мы и так
#    генерируем внутри этой границы, отдельного действия не нужно.
#  • Теги b/r/rc/rd читают оба известных движка (amneziawg-go device/obf.go и
#    модуль ядра src/junk.c), поэтому цепочка переносима между всеми
#    клиентами, которые её вообще разбирают.
# Диапазоны Jc/S/H — параметры УСТРОЙСТВА: они одинаковы у сервера и всех
# клиентов, поэтому клиентом их не сузить. Выбор влияет только на I1-I5.
TARGET_CLIENT="amnezia"

_target_client_label() {
  case "${1:-${TARGET_CLIENT:-amnezia}}" in
    kmod)     echo "Linux / OpenWrt (модуль ядра)" ;;
    keenetic) echo "Keenetic (нативный AmneziaWG)" ;;
    wiresock) echo "WireSock (Windows)" ;;
    mixed)    echo "разные клиенты" ;;
    *)        echo "Amnezia VPN / AmneziaWG" ;;
  esac
}

# Ложь, если выбранный клиент цепочку I1-I5 не читает.
_target_client_reads_cps() {
  [[ "${TARGET_CLIENT:-amnezia}" != "wiresock" ]]
}

# Печатает предупреждение и возвращает 0, если CPS для этого клиента бесполезен.
# Вызывающий в этом случае обязан оставить конфиг без I1-I5. Текст печатается
# один раз на выбор клиента: он длинный, а проверка стоит в нескольких местах.
_warn_cps_unsupported() {
  _target_client_reads_cps && return 1
  [[ -n "${_CPS_UNSUPPORTED_WARNED:-}" ]] && return 0
  _CPS_UNSUPPORTED_WARNED=1
  echo ""
  warn "WireSock не читает I1-I5 — по документации вендора поля молча игнорируются"
  warn "Туннель поднимется, мимикрии в трафике не будет, и об этом никто не сообщит"
  info "Поэтому конфиг делается без CPS. Обфускация H/S/Jc у WireSock работает полностью"
  return 0
}

# Спрашивает, куда поедет конфиг. Влияет только на цепочку I1-I5.
choose_target_client() {
  TARGET_CLIENT="amnezia"
  _CPS_UNSUPPORTED_WARNED=""
  echo ""
  hdr "▣  Куда поедет конфиг"
  echo -e "  ${G}1${N}  ${W}Amnezia VPN / AmneziaWG${N} ${D}— Android, iOS, Windows, macOS, Linux${N} ${C}(по умолчанию)${N}"
  echo -e "  ${G}2${N}  ${W}Linux / OpenWrt${N} ${D}— модуль ядра amneziawg${N}"
  echo -e "  ${G}3${N}  ${W}Keenetic${N} ${D}— нативный AmneziaWG в KeeneticOS 4.x${N}"
  echo -e "  ${R}4${N}  ${W}WireSock${N} ${D}— Windows; мимикрию I1-I5 не поддерживает${N}"
  echo -e "  ${G}5${N}  Не знаю / разные клиенты"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  local _tc
  read_choice _tc "$(echo -e "${C}  Выбор [1-5] (Enter = 1): ${N}")" 1 5 1
  case "$_tc" in
    2) TARGET_CLIENT="kmod" ;;
    3) TARGET_CLIENT="keenetic" ;;
    4) TARGET_CLIENT="wiresock" ;;
    5) TARGET_CLIENT="mixed" ;;
    *) TARGET_CLIENT="amnezia" ;;
  esac
  ok "Клиент: $(_target_client_label)"

  case "$TARGET_CLIENT" in
    keenetic)
      info "Длинная цепочка на Keenetic ненадёжна — предложу I1 и профиль DNS"
      ;;
    wiresock)
      _warn_cps_unsupported || true
      ;;
    mixed)
      info "Цепочка будет из тегов, которые читают оба движка — она переносима"
      ;;
  esac
  log_info "TARGET_CLIENT=$TARGET_CLIENT"
  return 0
}

choose_awg_profile() {
  AWG_PROFILE=""
  choose_target_client
  echo ""
  hdr "⚙  Профиль AmneziaWG"
  echo -e "  ${G}3${N}  ${W}Pro${N}      — максимальная защита, I1-I5 на выбор ${C}(рекомендуется)${N}"
  echo -e "  ${D}1   Lite     — параметры как у оригинальной Amnezia, DNS мимикрия${N}"
  echo -e "  ${D}2   Standard — усечённые диапазоны, TLS мимикрия${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  local _choice
  read_choice _choice "$(echo -e "${C}  Выбор [1-3] (Enter = 3 Pro): ${N}")" 1 3 3

  case "$_choice" in
    1)
      AWG_PROFILE="lite"
      if _warn_cps_unsupported; then
        OBF_LEVEL=1; MIMICRY_PROFILE="none"
        I1=""; I2=""; I3=""; I4=""; I5=""
        info "Профиль: Lite без CPS (клиент его не читает)"
        return 0
      fi
      OBF_LEVEL=2                # клиентам кладём I1
      MIMICRY_PROFILE="dns"
      # Домен не передаём — Python выбирает случайный из DOMAIN_POOL
      info "Профиль: Lite (I1 = DNS / случайный домен)"
      local cps_out
      cps_out=$(gen_cps_i1 "dns" "" "--only-i1") || cps_out=""
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=""; I3=""; I4=""; I5=""
      if [[ -z "$I1" ]]; then
        warn "Не удалось сгенерировать I1 для Lite — клиенты пойдут без CPS"
      else
        ok "I1 готов (${#I1} сим)"
      fi
      ;;
    2)
      AWG_PROFILE="standard"
      if _warn_cps_unsupported; then
        OBF_LEVEL=1; MIMICRY_PROFILE="none"
        I1=""; I2=""; I3=""; I4=""; I5=""
        info "Профиль: Standard без CPS (клиент его не читает)"
        return 0
      fi
      OBF_LEVEL=2                # клиентам кладём I1
      MIMICRY_PROFILE="tls"
      info "Профиль: Standard (I1 = TLS ClientHello)"
      local sel_domain
      sel_domain=$(select_random_domain "tls")
      [[ -z "$sel_domain" ]] && sel_domain=""
      local cps_out
      cps_out=$(gen_cps_i1 "tls" "$sel_domain") || cps_out=""
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=""; I3=""; I4=""; I5=""
      if [[ -z "$I1" ]]; then
        warn "Не удалось сгенерировать I1 для Standard — клиенты пойдут без CPS"
      else
        ok "I1 готов (${#I1} сим${sel_domain:+, $sel_domain})"
      fi
      ;;
    3)
      AWG_PROFILE="pro"
      info "Профиль: Pro — выбор уровня I1-I5 и мимикрии"
      choose_obf_level
      choose_mimicry_profile || return 1
      ;;
  esac
  return 0
}

choose_obf_level() {
  # Глобальная переменная OBF_LEVEL:
  #   1 = basic (без I1-I5) — max совместимость, рекомендуется
  #   2 = +I1 — добавить только I1 (снимок протокола)
  #   3 = +I1-I5 — полный CPS chain (максимум DPI bypass)
  OBF_LEVEL=""

  # У WireSock цепочки не будет вовсе, у Keenetic длинная ненадёжна — меняем
  # предложение по умолчанию, но выбор оставляем за человеком.
  local _lvl_default=3
  if _warn_cps_unsupported; then
    OBF_LEVEL=1; MIMICRY_PROFILE="none"
    I1=""; I2=""; I3=""; I4=""; I5=""
    ok "Уровень обфускации: Базовый (H/S/Jc), без I1-I5"
    return 0
  fi
  if [[ "${TARGET_CLIENT:-amnezia}" == "keenetic" ]]; then
    _lvl_default=2
  fi

  echo ""
  hdr "⛊  Уровень обфускации"
  echo -e "  ${G}3${N}  + I1-I5 полный CPS chain ${C}(рекомендуется)${N}"
  echo -e "     ${D}Максимум DPI bypass. Конфиг длинный — в QR может не влезть.${N}"
  echo -e "  ${D}2   + I1 — добавляет 1 сигнатурный пакет${N}"
  echo -e "     ${D}I1 = снимок реального TLS/QUIC/DTLS протокола${N}"
  echo -e "  ${D}1   Базовый — H ranges + S1-S4 + Jc junk, без I1-I5${N}"
  echo -e "     ${D}Максимальная совместимость со старыми клиентами.${N}"
  if [[ "${TARGET_CLIENT:-amnezia}" == "keenetic" ]]; then
    echo -e "  ${Y}  Keenetic: чем он разбирает цепочку — по исходникам неизвестно.${N}"
    echo -e "  ${Y}  Надёжнее уровень 2 (один I1), поэтому он и предложен.${N}"
  fi
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  read_choice OBF_LEVEL "$(echo -e "${C}  Выбор [1-3] (Enter = ${_lvl_default}): ${N}")" 1 3 "$_lvl_default"
  local label
  case $OBF_LEVEL in
    1) label="Базовый (без CPS)" ;;
    2) label="+I1 (мимикрия)" ;;
    3) label="+I1-I5 (полный CPS)" ;;
  esac
  echo -e "${G}  √ Уровень обфускации: ${W}${label}${N}"
  return 0
}
choose_mimicry_profile() {
  I1=""
  I2=""
  I3=""
  I4=""
  I5=""
  MIMICRY_PROFILE=""

  # OBF_LEVEL=1 (базовый) — пропускаем мимикрию полностью
  if [[ "${OBF_LEVEL:-1}" == "1" ]]; then
    MIMICRY_PROFILE="none"
    return 0
  fi

  echo ""
  hdr "~  Профили мимикрии I1-I5"
  echo -e "  ${G}1${N}  ${W}QUIC${N}  — Initial 1200 Б по RFC 9000 + короткие заголовки"
  echo -e "     ${D}Единственный из четырёх, где содержимое — шифротекст: смотреть${N}"
  echo -e "     ${D}DPI не на что. По UDP это настоящий протокол.${N}"
  echo -e "  ${G}2${N}  ${W}DNS${N}   — DNS Query с EDNS0 + случайный TXID"
  echo -e "     ${D}Тоже настоящий UDP-протокол и самый компактный: 40 байт.${N}"
  echo -e "  ${Y}3${N}  ${W}TLS${N}   — ClientHello (Chrome-подобный)"
  echo -e "     ${D}⚠ TLS-записи поверх UDP не существует: настоящий UDP-TLS — это${N}"
  echo -e "     ${D}DTLS, а у него другой формат. Плюс SNI уходит открытым текстом${N}"
  echo -e "     ${D}и не совпадает с IP сервера. Сообщение из поля: конфиг с этим${N}"
  echo -e "     ${D}профилем не работал в РФ, но работал в ЕС.${N}"
  echo -e "  ${Y}4${N}  SIP   — REGISTER-запрос (VoIP)"
  echo -e "     ${D}Настоящий UDP-протокол, но целиком открытый текст.${N}"
  echo ""
  local _mim_default=1
  if [[ "${TARGET_CLIENT:-amnezia}" == "keenetic" ]]; then
    # Keenetic чувствителен к длинному I1, а DNS — самый короткий пакет
    _mim_default=2
    echo -e "  ${Y}  Keenetic чувствителен к I1: DNS — самый короткий пакет${N}"
    echo -e "  ${Y}  из четырёх, поэтому он и предложен.${N}"
    echo ""
  fi
  read_choice PROFILE_CHOICE "$(echo -e "${C}  Выбор [1-4] (Enter = ${_mim_default}): ${N}")" 1 4 "$_mim_default"

  case $PROFILE_CHOICE in
    1) MIMICRY_PROFILE="quic" ;;
    2) MIMICRY_PROFILE="dns"  ;;
    3) MIMICRY_PROFILE="tls"  ;;
    4) MIMICRY_PROFILE="sip"  ;;
  esac

  # Выбираем домен из пула под профиль
  local sel_domain=""
  case "$MIMICRY_PROFILE" in
    tls)  sel_domain=$(select_random_domain "tls")  ;;
    quic) sel_domain=$(select_random_domain "quic") ;;
    sip)  sel_domain=$(select_random_domain "sip")  ;;
    dns)  sel_domain=$(select_random_domain "tls")  ;;
  esac
  [[ -z "$sel_domain" ]] && sel_domain=""

  # ── Генерация через Python ──
  echo -e "${C}  → Генерируем $MIMICRY_PROFILE${sel_domain:+ ($sel_domain)}...${N}"
  local cps_out
  cps_out=$(gen_cps_i1 "$MIMICRY_PROFILE" "$sel_domain") || cps_out=""

  if [[ -n "$cps_out" ]]; then
    I1=$(echo "$cps_out" | sed -n '1p')
    if [[ "${OBF_LEVEL:-1}" == "3" ]]; then
      I2=$(echo "$cps_out" | sed -n '2p')
      I3=$(echo "$cps_out" | sed -n '3p')
      I4=$(echo "$cps_out" | sed -n '4p')
      I5=$(echo "$cps_out" | sed -n '5p')
      # Считаем непустые
      local nonempty=1
      [[ -n "$I2" ]] && nonempty=$((nonempty+1))
      [[ -n "$I3" ]] && nonempty=$((nonempty+1))
      [[ -n "$I4" ]] && nonempty=$((nonempty+1))
      [[ -n "$I5" ]] && nonempty=$((nonempty+1))
      echo -e "${G}  √ ${nonempty}/5 пакетов ${D}(символов строки)${G}: I1=${#I1} I2=${#I2} I3=${#I3} I4=${#I4} I5=${#I5}${N}"
    else
      I2=""; I3=""; I4=""; I5=""
      echo -e "${G}  √ I1 готов (${#I1} сим)${N}"
    fi
  else
    warn "Не удалось сгенерировать CPS"
    I1=""; I2=""; I3=""; I4=""; I5=""
  fi
}

# Python-анализатор pcap (генерируется во временный файл при вызове)
_AWG_PCAP_ANALYZER='
import sys, struct

def read_pcap(path):
    payloads = []
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24: return payloads
        while True:
            ph = f.read(16)
            if len(ph) < 16: break
            incl_len = struct.unpack("<I", ph[8:12])[0]
            pkt = f.read(incl_len)
            if len(pkt) < 42: continue
            eth_type = struct.unpack(">H", pkt[12:14])[0]
            if eth_type != 0x0800: continue
            ihl = (pkt[14] & 0x0f) * 4
            udp_off = 14 + ihl
            if udp_off + 8 > len(pkt): continue
            udp_len = struct.unpack(">H", pkt[udp_off+4:udp_off+6])[0]
            payload = pkt[udp_off+8:udp_off+8+(udp_len-8)]
            if len(payload) >= 10: payloads.append(payload)
    return payloads

def detect(p):
    """Определяет тип пакета. Возвращает (тип, описание) или (None, None)"""
    if len(p) < 10: return (None, None)
    # SIP
    for m in (b"REGISTER",b"INVITE",b"OPTIONS",b"SIP/2.0",b"BYE",b"CANCEL",b"ACK "):
        if p.startswith(m):
            return ("sip", f"SIP {m.decode().strip()} ({len(p)}B)")
    # TLS Handshake (0x16 + version 0x0301 or 0x0303)
    if p[0] == 0x16 and p[1] == 0x03 and p[2] in (0x01, 0x03):
        hs = {1:"ClientHello",2:"ServerHello",4:"NewSessionTicket",11:"Certificate",16:"ClientKeyExchange"}.get(p[5],"unknown") if len(p) > 5 else "?"
        return ("tls", f"TLS Handshake: {hs} ({len(p)}B)")
    # TLS Application Data (0x17)
    if p[0] == 0x17 and p[1] == 0x03 and p[2] in (0x01, 0x03):
        return ("tls-data", f"TLS Application Data ({len(p)}B)")
    # TLS ChangeCipherSpec (0x14)
    if p[0] == 0x14 and p[1] == 0x03 and p[2] in (0x01, 0x03):
        return ("tls-ccs", f"TLS ChangeCipherSpec ({len(p)}B)")
    # (Правило tls-cke по одному байту 0x10 убрано: ловило ~1/256 случайных
    #  AWG data-пакетов ложно; наш CPS-генератор CKE не создаёт.)
    # DTLS
    if p[0] == 0x16 and p[1:3] in (b"\xfe\xfd", b"\xfe\xff"):
        return ("dtls", f"DTLS handshake ({len(p)}B)")
    # DNS
    if len(p) >= 12:
        flags = p[2]; qr = (flags >> 7) & 1; opcode = (flags >> 3) & 0xf
        qdcount = struct.unpack(">H", p[4:6])[0]
        if qr == 0 and opcode == 0 and 1 <= qdcount <= 10:
            if 12 < len(p) and 1 <= p[12] <= 63:
                return ("dns", f"DNS query ({len(p)}B)")
    # QUIC Long Header
    fb = p[0]
    if (fb >> 6) == 3 and len(p) >= 7:
        ver = p[1:5].hex()
        known = {"00000001":"v1","6b3343cf":"v2"}
        dcid_len = p[5]
        if ver in known and 1 <= dcid_len <= 20:
            pt = {0:"Initial",1:"0-RTT",2:"Handshake"}.get((fb>>4)&3,"?")
            return ("quic", f"QUIC {pt} {known[ver]} ({len(p)}B)")
    # QUIC Short Header (0x40-0x7f) — ПРЕДВАРИТЕЛЬНО (см. пост-обработку):
    # ~25% случайных AWG data-пакетов попадают сюда из-за H-обфускации.
    if 0x40 <= fb <= 0x7f and len(p) > 20:
        return ("quic-short?", f"QUIC Short Header? ({len(p)}B)")
    return (None, None)

# ── Main ──
payloads = read_pcap(sys.argv[1])
if not payloads:
    print("RESULT|EMPTY|Не захвачено пакетов")
    sys.exit(0)

# Классифицируем все пакеты
detected = []
awg_data = 0
for i, p in enumerate(payloads):
    typ, desc = detect(p)
    if typ:
        detected.append((i, typ, desc))
    else:
        awg_data += 1

# Пост-обработка: quic-short? подтверждаем только если есть настоящий
# QUIC Initial (Long Header) — иначе это AWG data, ложно попавший в 0x40-0x7F.
has_quic_long = any(t == "quic" for _, t, _ in detected)
_resolved = []
for i, t, d in detected:
    if t == "quic-short?":
        if has_quic_long:
            _resolved.append((i, "quic-short", d.replace("?", "")))
        else:
            awg_data += 1
    else:
        _resolved.append((i, t, d))
detected = _resolved

# Собираем уникальные типы CPS
cps_types = []
cps_descs = []
for _, typ, desc in detected:
    if typ not in cps_types:
        cps_types.append(typ)
        cps_descs.append(desc)

total = len(payloads)
cps_count = len(detected)

# Формируем вердикт
if cps_count > 0:
    print(f"INFO|Захвачено: {total} пакетов, из них CPS: {cps_count}")
    for desc in cps_descs:
        print(f"OK|{desc}")
    if awg_data > 0:
        print(f"INFO|AWG data-пакетов: {awg_data} (обфусцированные, H-заголовки)")
    # Оценка
    if cps_count >= 3:
        types_str = ", ".join(cps_types)
        print(f"VERDICT|PASS|CPS chain из {cps_count} пакетов ({types_str})")
    elif cps_count >= 1:
        types_str = ", ".join(cps_types)
        print(f"VERDICT|PASS|Поймали {cps_count} CPS ({types_str})")
    else:
        print(f"VERDICT|PASS|{cps_types[0]}")
elif awg_data > 0:
    # Все пакеты — AWG data. Значит CPS уже пролетели или уровень = базовый
    sizes = sorted(set(len(p) for p in payloads))
    print(f"INFO|Захвачено: {total} AWG data-пакетов (размеры: {sizes[:5]})")
    print(f"INFO|CPS пакеты не пойманы — они уже пролетели до захвата")
    print(f"OK|AWG обфускация активна — пакеты не распознаются как WireGuard")
    print(f"VERDICT|OK|Обфускация работает (CPS уже прошли)")
else:
    print(f"INFO|Захвачено: {total}, ничего не распознано")
    print(f"VERDICT|OK|Пакеты полностью обфусцированы")
'

do_sniff_test() {
  echo ""
  hdr "◎  DPI тест"
  echo ""

  if ! command -v tcpdump &>/dev/null; then
    warn "tcpdump не установлен"
    echo -e "${C}  Установи: ${W}apt install -y tcpdump${N}"
    return 0
  fi

  if [[ ! -f "$SERVER_CONF" ]]; then
    warn "Сервер не настроен (Сервер → п.2)"
    return 0
  fi

  local listen_port
  listen_port=$(awk -F= '/^ListenPort/{gsub(/ /,"",$2); print $2}' "$SERVER_CONF")
  [[ -z "$listen_port" ]] && { warn "ListenPort не найден"; return 0; }

  local wan_if
  wan_if=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -z "$wan_if" ]] && wan_if="eth0"

  # Выбор клиента
  local endpoints_raw
  endpoints_raw=$(awg show awg0 endpoints 2>/dev/null | awk 'NF==2 && $2!="(none)"')
  if [[ -z "$endpoints_raw" ]]; then
    warn "Нет подключённых клиентов"
    echo -e "${C}  Сначала подключись клиентом и вернись сюда${N}"
    return 0
  fi

  local -a peer_list ep_list name_list vpn_ip_list
  mapfile -t peer_list < <(echo "$endpoints_raw" | awk '{print $1}')
  mapfile -t ep_list < <(echo "$endpoints_raw" | awk '{print $2}')

  declare -A pk_to_name pk_to_ip
  local cf
  for cf in /root/*_awg2.conf; do
    [[ -f "$cf" ]] || continue
    local cf_priv cf_pub cf_addr
    cf_priv=$(grep -E '^PrivateKey' "$cf" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r' | head -1 || true)
    [[ -z "$cf_priv" ]] && continue
    cf_pub=$(echo "$cf_priv" | awg pubkey 2>/dev/null) || continue
    cf_addr=$(grep -E '^Address' "$cf" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r' | head -1 || true)
    pk_to_name["$cf_pub"]="$(basename "$cf" .conf)"
    pk_to_ip["$cf_pub"]="${cf_addr%/*}"
  done

  local pk
  for pk in "${peer_list[@]}"; do
    name_list+=("${pk_to_name[$pk]:-?}")
    vpn_ip_list+=("${pk_to_ip[$pk]:-?}")
  done

  local sel_idx=0 client_ep client_ip
  if [[ ${#ep_list[@]} -gt 1 ]]; then
    echo -e "${C}  Клиенты:${N}"
    local k
    for k in "${!ep_list[@]}"; do
      printf "  ${G}%d)${N} %-24s ${D}%s${N}\n" "$((k+1))" "${name_list[$k]}" "${ep_list[$k]}"
    done
    local PEER_SEL
    read_choice PEER_SEL "$(echo -e "${C}  Выбор [1-${#ep_list[@]}] (Enter = 1): ${N}")" 1 "${#ep_list[@]}" 1
    sel_idx=$((PEER_SEL - 1))
  fi
  client_ep="${ep_list[$sel_idx]}"
  client_ip="${client_ep%:*}"
  echo -e "${C}  → ${W}${name_list[$sel_idx]}${N} ${D}(${client_ep})${N}"

  # Инструкция
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${Y}  На клиенте: Disconnect → подожди 3 сек → Connect${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  read -rp "$(echo -e "${C}  Enter когда готов... ${N}")" _ || return 0

  local analyzer="/tmp/awg_analyzer_$$.py"
  echo "$_AWG_PCAP_ANALYZER" > "$analyzer"

  local pcap="/tmp/awg_dpi_$$.pcap"
  echo -e "${C}  → Слушаю 20 секунд... Подключайся!${N}"

  timeout 20 tcpdump -i "$wan_if" -nn -c 30 \
    "udp port ${listen_port} and src host ${client_ip}" \
    -w "$pcap" 2>/dev/null || true

  if [[ ! -s "$pcap" ]]; then
    echo ""
    echo -e "${Y}  Ничего не поймали. Возможные причины:${N}"
    echo -e "${C}  • Клиент не переподключился вовремя${N}"
    echo -e "${C}  • Другой IP клиента (мобильная сеть сменила)${N}"
    echo -e "${C}  • Попробуй ещё раз${N}"
    rm -f "$pcap" "$analyzer"
    return 0
  fi

  echo -e "${C}  → Анализ...${N}"
  echo ""

  local analysis verdict="" verdict_msg=""
  analysis=$(python3 "$analyzer" "$pcap" 2>&1) || analysis="RESULT|FAIL|Python error"

  while IFS='|' read -r tag msg extra; do
    [[ -z "$tag" ]] && continue
    case "$tag" in
      OK)      echo -e "  ${G}√${N} $msg" ;;
      INFO)    echo -e "  ${D}·${N} $msg" ;;
      FAIL)    echo -e "  ${R}×${N} $msg" ;;
      VERDICT|RESULT)
        verdict="$msg"
        verdict_msg="$extra"
        ;;
    esac
  done <<< "$analysis"

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  case "$verdict" in
    PASS)
      echo -e "${G}  ✓ DPI тест пройден — $verdict_msg${N}" ;;
    OK)
      echo -e "${G}  ✓ $verdict_msg${N}" ;;
    EMPTY)
      echo -e "${Y}  ○ $verdict_msg${N}" ;;
    *)
      echo -e "${Y}  ○ Попробуй переподключиться и запустить тест снова${N}" ;;
  esac
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

  rm -f "$pcap" "$analyzer"
  log_info "DPI тест: клиент=$client_ip verdict=$verdict"
}

check_deps() {
  HAS_AWG=false
  HAS_SERVER_CONF=false
  HAS_BACKUPS=false

  # Кэш проверки бинарей (они не появляются/исчезают в течение сессии).
  # _DEPS_CACHED — пустая до первой проверки, потом "1".
  if [[ -z "${_DEPS_CACHED:-}" ]]; then
    command -v awg &>/dev/null && _CACHED_HAS_AWG=true || _CACHED_HAS_AWG=false
    _DEPS_CACHED=1
  fi
  HAS_AWG="$_CACHED_HAS_AWG"

  [[ -f "$SERVER_CONF" ]] && HAS_SERVER_CONF=true

  # Восстанавливаем SERVER_REGION из шапки конфига если сервер создан
  if [[ -f "$SERVER_CONF" ]]; then
    local saved_region
    saved_region=$(grep -oP '^#\s*Region:\s*\K\w+' "$SERVER_CONF" 2>/dev/null | head -1 || true)
    if [[ -n "$saved_region" ]]; then
      SERVER_REGION="$saved_region"
      # Пересобираем активные пулы под регион
      if [[ "$saved_region" == "ru" ]]; then
        TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_RU[@]}")
        DTLS_DOMAINS=("${DTLS_DOMAINS_RU[@]}")
        SIP_DOMAINS=("${SIP_DOMAINS_RU[@]}")
        QUIC_DOMAINS=("${QUIC_DOMAINS_RU[@]}")
      else
        TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_WORLD[@]}")
        DTLS_DOMAINS=("${DTLS_DOMAINS_WORLD[@]}")
        SIP_DOMAINS=("${SIP_DOMAINS_WORLD[@]}")
        QUIC_DOMAINS=("${QUIC_DOMAINS_WORLD[@]}")
      fi
    fi
  fi

  # Проверка бекапов
  if [[ -d "$BACKUP_DIR" ]]; then
    local d
    for d in "$BACKUP_DIR"/*/; do
      if [[ -f "$d/backup_meta.txt" ]]; then HAS_BACKUPS=true; break; fi
    done
  fi
}

get_public_ip() {
  local ip=""
  # Использую explicit check вместо chain с set -e
  ip=$(timeout 5 curl -s --connect-timeout 3 -4 ifconfig.me 2>/dev/null || true)
  if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$ip"; return 0
  fi

  ip=$(timeout 5 curl -s --connect-timeout 3 -4 api.ipify.org 2>/dev/null || true)
  if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$ip"; return 0
  fi

  ip=$(timeout 5 curl -s --connect-timeout 3 -4 ipinfo.io/ip 2>/dev/null || true)
  if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$ip"; return 0
  fi

  # Fallback — локальный IP через ip route
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  if [[ -n "$ip" ]]; then
    echo "$ip"; return 0
  fi

  echo ""
  return 0
}

# ── Endpoint для клиентских конфигов: IP или домен ──
#
# По умолчанию в конфиг пишется публичный IP. Если у сервера есть доменное имя,
# его удобнее держать в Endpoint: при смене IP (переезд, смена провайдера)
# достаточно поправить DNS-запись, а не перевыпускать все клиентские конфиги.
# Домен хранится маркером «# AWG_ENDPOINT=<host>» в шапке awg0.conf, чтобы его
# видели и скрипт, и бот.

# Проверяет, похоже ли $1 на доменное имя. Заодно отсекает IP: для него домен
# задавать бессмысленно, а путаницу создаёт.
valid_domain() {
  local d="$1"
  [[ -n "$d" && ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
  [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] || return 1
  return 0
}

# Домен из маркера в конфиге сервера. Пусто — значит используется IP.
endpoint_domain() {
  local conf="${1:-$SERVER_CONF}" d=""
  [[ -f "$conf" ]] || { echo ""; return 0; }
  d=$(grep -m1 '^# AWG_ENDPOINT=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d ' ' || true)
  valid_domain "$d" && echo "$d" || echo ""
  return 0
}

# Что писать в Endpoint клиентам: домен, если задан, иначе публичный IP.
# $1 — публичный IP, если он уже известен вызывающему (чтобы не дёргать сеть).
endpoint_host() {
  local known_ip="${1:-}" d
  d=$(endpoint_domain)
  if [[ -n "$d" ]]; then echo "$d"; return 0; fi
  if [[ -n "$known_ip" ]]; then echo "$known_ip"; return 0; fi
  get_public_ip
}

# Спрашивает домен при создании сервера. Результат — глобальная ENDPOINT_DOMAIN
# (пусто = писать IP). Сервера ещё нет, поэтому маркер здесь не пишем.
ask_endpoint_domain() {
  ENDPOINT_DOMAIN=""
  echo ""
  hdr "◈  Endpoint для клиентов"
  echo ""
  echo -e "  ${D}Что клиенты увидят в строке Endpoint: адрес сервера.${N}"
  echo -e "  ${D}С доменом переезд на другой IP не требует новых конфигов —${N}"
  echo -e "  ${D}достаточно поправить DNS-запись.${N}"
  echo ""
  local _use
  read_yesno _use "$(echo -e "${C}  Использовать домен вместо IP? [y/N]: ${N}")" "n"
  [[ "$_use" == "y" ]] || { info "Endpoint: IP сервера"; return 0; }

  local d
  while true; do
    read -rp "$(echo -e "${C}  Домен (например vpn.example.com, пусто = отмена): ${N}")" d
    d=$(echo "${d:-}" | tr -d ' ')
    [[ -z "$d" ]] && { info "Endpoint: IP сервера"; return 0; }
    if valid_domain "$d"; then break; fi
    warn "Не похоже на домен. Нужно имя вида vpn.example.com, не IP."
  done

  check_domain_resolves "$d" || {
    local _go
    read_yesno _go "$(echo -e "${Y}  Всё равно использовать этот домен? [y/N]: ${N}")" "n"
    [[ "$_go" == "y" ]] || { info "Endpoint: IP сервера"; return 0; }
  }

  ENDPOINT_DOMAIN="$d"
  ok "Endpoint: $d"
  return 0
}

# Сверяет A-запись домена с публичным IP сервера. Возвращает 1, если домен не
# резолвится или ведёт не сюда — это не запрет, а предупреждение: DNS могли
# ещё не прописать, а за Cloudflare-прокси адрес и вовсе будет чужой.
check_domain_resolves() {
  local d="$1" ips srv_ip
  info "Проверяю DNS для $d..."
  ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z "$ips" ]]; then
    warn "Домен $d не резолвится с этого сервера"
    info "Клиенты не смогут подключиться, пока не появится A-запись"
    return 1
  fi
  srv_ip=$(get_public_ip 2>/dev/null || true)
  if [[ -n "$srv_ip" ]] && ! grep -qw "$srv_ip" <<< "$ips"; then
    warn "Домен ведёт на ${ips% }, а публичный IP сервера — $srv_ip"
    info "Так бывает за Cloudflare-прокси; для WireGuard/AWG проксирование UDP"
    info "не работает — нужна A-запись прямо на IP сервера (DNS only)"
    return 1
  fi
  ok "Домен ведёт на этот сервер (${ips% })"
  return 0
}

# Записывает (или убирает) маркер домена в конфиге сервера.
# $1 = домен либо пустая строка для возврата к IP.
set_endpoint_domain() {
  local d="$1"
  [[ -f "$SERVER_CONF" ]] || { err "Сервер не создан"; return 1; }
  sed -i '/^# AWG_ENDPOINT=/d' "$SERVER_CONF" || return 1
  if [[ -n "$d" ]]; then
    sed -i "1a # AWG_ENDPOINT=${d}" "$SERVER_CONF" || return 1
  fi
  return 0
}

rand_range() {
  local lo="$1" hi="$2"
  # Защита: если lo > hi, возвращаем lo (избегаем ошибки python randint)
  if [[ "$lo" -gt "$hi" ]]; then echo "$lo"; return 0; fi
  python3 -c "import random; print(random.randint($lo, $hi))"
}

# Форматирует секунды в человеческий вид: 5с / 3м12с / 2ч15м / 3д4ч
_fmt_duration() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "?"; return; }
  if (( s < 60 )); then
    echo "${s}с"
  elif (( s < 3600 )); then
    echo "$((s/60))м$((s%60))с"
  elif (( s < 86400 )); then
    echo "$((s/3600))ч$(( (s%3600)/60 ))м"
  else
    echo "$((s/86400))д$(( (s%86400)/3600 ))ч"
  fi
}

find_free_ip() {
  local base="$1"
  local srv_ip_oct=""
  if [[ -f "$SERVER_CONF" ]]; then
    local srv_addr
    srv_addr=$(grep "^Address" "$SERVER_CONF" | awk -F'=' '{print $2}' | tr -d ' ' | head -1 || true)
    srv_ip_oct=$(echo "$srv_addr" | cut -d/ -f1 | awk -F. '{print $4}' || true)
  fi

  for i in $(seq 2 254); do
    [[ -n "$srv_ip_oct" && "$i" == "$srv_ip_oct" ]] && continue
    if ! grep -qF "${base}.${i}/32" "$SERVER_CONF" 2>/dev/null; then
      echo "${base}.${i}/32"
      return 0
    fi
  done
  return 1
}

get_status() {
  local ip port status clients
  ip=$(get_public_ip)
  if [[ -z "$ip" ]]; then ip="—"; fi
  if ip link show awg0 &>/dev/null; then
    status="${G}активен${N}"
    port=$(awg show awg0 listen-port 2>/dev/null || echo "—")
    clients=$(awg show awg0 peers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  else
    status="${R}не активен${N}"
    port="—"; clients="—"
  fi
  echo -e "$ip|$port|$status|$clients"
}

# Создаёт быстрый автоматический бэкап с префиксом "auto_<reason>_"
# в ~/awg_backup/. Не задаёт вопросов. Используется do_reset_server,
# do_clean_clients, do_uninstall.
auto_backup() {
  local reason="${1:-operation}"
  [[ ! -f "$SERVER_CONF" ]] && return 0  # нечего бэкапить

  mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
  local stamp
  stamp=$(date +%Y%m%d_%H%M%S)
  local archive="${BACKUP_DIR}/auto_${reason}_${stamp}.tar.gz"

  # Архивируем серверный конфиг + все клиентские
  local files=("$SERVER_CONF")
  shopt -s nullglob
  local clients=( /root/*_awg2.conf )
  shopt -u nullglob
  [[ ${#clients[@]} -gt 0 ]] && files+=("${clients[@]}")

  if tar -czf "$archive" "${files[@]}" 2>/dev/null; then
    chmod 600 "$archive"
    bkup "Авто-бэкап: $(basename "$archive")"
    return 0
  fi
  return 1
}

# Печатает причину, по которой сервер надо перезагрузить, и возвращает 0.
# Если перезагрузка не нужна — печатает пустую строку и возвращает 1.
#
# Проверяем три вещи, каждая из которых валит подъём awg0:
#   • модуль не загружен в текущее ядро;
#   • работает ядро старее самого нового установленного (apt upgrade из п.1
#     принёс новое, модуль DKMS собран под него);
#   • сама система просит перезагрузку (/run/reboot-required).
awg_reboot_reason() {
  local running newest k
  running="$(uname -r)"

  if [[ ! -d /sys/module/amneziawg ]] && \
     ! grep -qE '^amneziawg\s' /proc/modules 2>/dev/null; then
    echo "модуль amneziawg не загружен в текущее ядро ($running)"
    return 0
  fi

  # Самое новое установленное ядро: берём только те, для которых есть vmlinuz
  newest=$(for k in /lib/modules/*/; do
             k=${k%/}; k=${k##*/}
             [[ -e "/boot/vmlinuz-$k" ]] && echo "$k"
           done | sort -V | tail -1)
  if [[ -n "$newest" && "$newest" != "$running" ]]; then
    echo "работает ядро $running, а установлено более новое $newest"
    return 0
  fi

  if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
    echo "система сообщает о необходимости перезагрузки (обновлялось ядро или libc)"
    return 0
  fi

  # Модуль на диске пересобран уже ПОСЛЕ того, как он был вставлен в текущее
  # ядро (например, повторной установкой/пересборкой в рамках этой же сессии).
  # dkms install кладёт новый .ko на диск, но в память ядра его никто не
  # переподгружает — awg-quick up продолжает работать со старым модулем и
  # падает на параметрах, которых старая версия не знает ("Invalid argument").
  # Ловим это по времени: /sys/module/amneziawg появляется в момент insmod,
  # а mtime файла .ko — в момент последней сборки/установки.
  if awg_module_stale; then
    echo "модуль amneziawg на диске новее, чем загруженный в ядро (пересобирался после загрузки)"
    return 0
  fi

  echo ""
  return 1
}

# Возвращает 0 (true), если файл .ko модуля amneziawg на диске новее момента
# его последней загрузки в ядро — то есть в памяти сидит устаревшая версия.
# Возвращает 1 (false), если сравнить не удалось или модуль актуален.
awg_module_stale() {
  [[ -d /sys/module/amneziawg ]] || return 1

  local ko_path load_time mod_time
  ko_path=$(modinfo -n amneziawg 2>/dev/null) || return 1
  [[ -n "$ko_path" && -f "$ko_path" ]] || return 1

  load_time=$(stat -c %Y /sys/module/amneziawg 2>/dev/null) || return 1
  mod_time=$(stat -c %Y "$ko_path" 2>/dev/null) || return 1

  (( mod_time > load_time ))
}

# Кто держит UDP-порт $1. Пустой вывод — держатель неизвестен (нет ss или
# порт свободен). Отдельной функцией, чтобы диагностику можно было проверять
# без живого сокета.
_port_holder() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  command -v ss &>/dev/null || return 0
  ss -lunp 2>/dev/null | grep -E "[:.]${p}\b" || true
}

# Возвращает список S-параметров конфига, нарушающих требование ядра
# (S1-S4 >= AWG_HP_MIN_S при заданном HeaderProtectionKey). Пусто = всё в
# порядке. Код возврата 1, если нарушения есть — удобно для if.
awg_check_hp_min_s() {
  local conf="${1:-$SERVER_CONF}" key val bad=""
  [[ -f "$conf" ]] || return 0
  grep -q '^HeaderProtectionKey = ' "$conf" 2>/dev/null || return 0
  for key in S1 S2 S3 S4; do
    val=$(grep -m1 "^${key} = " "$conf" 2>/dev/null | awk '{print $3}')
    [[ "$val" =~ ^[0-9]+$ ]] || continue
    (( val < AWG_HP_MIN_S )) && bad+=" ${key}=${val}"
  done
  [[ -z "$bad" ]] && return 0
  echo "$bad"
  return 1
}

# Разбирает вывод неудавшегося awg-quick up и называет причину.
#
# Смысл в том, чтобы человек не гадал: сообщения awg-quick короткие, но
# однозначные, и каждому соответствует ровно одно действие. $1 = вывод
# команды (stdout+stderr), $2 = конфиг.
awg_diagnose_up_failure() {
  local out="$1" conf="${2:-$SERVER_CONF}"
  local low; low=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')

  echo ""

  # Установленные tools не знают строку из конфига. Типовой случай: сервер
  # переведён на 3.0, а awg собран из версии, где этих ключей ещё нет.
  if [[ "$low" == *"line unrecognized"* ]]; then
    local bad
    bad=$(printf '%s' "$out" | grep -oiE 'line unrecognized: .?([A-Za-z0-9_]+)' \
          | head -1 | grep -oE '[A-Za-z0-9_]+$' || true)
    err "amneziawg-tools не понимает параметр ${bad:-из конфига}"
    if [[ -n "$bad" ]] && [[ "$bad" =~ ^${AWG3_KEYS_RE}$ ]]; then
      if [[ "$bad" =~ ^${AWG31_KEYS_RE}$ ]]; then
        info "Это параметр AWG 3.1 — установленный awg собран без его поддержки"
        info "Нужны amneziawg-tools/модуль v3.1.20260812 или новее"
      else
        info "Это параметр AWG 3.0 — установленный awg собран без его поддержки"
      fi
      info "Варианты:"
      info "  • обновить компоненты: Сервер (1) → п.1 (пересборка tools и модуля)"
      info "  • понизить версию: Сервер (1) → п.5 → выбрать AWG 3.0 или 2.0"
    else
      info "Смотри строку в конфиге: grep -n '${bad:-=}' $conf"
    fi
    return 0
  fi

  # Ядро отвергло параметры: tools их отправили, модуль о них не знает.
  # Так выглядит рассинхрон «tools из master + модуль от прошлой установки».
  if [[ "$low" == *"unable to modify interface"* || "$low" == *"invalid argument"* ]]; then
    err "Ядро отвергло параметры интерфейса"

    # Первая по частоте причина, и она не про версию модуля: при заданном
    # HeaderProtectionKey ядро требует S1-S4 >= AWG_HP_MIN_S. Проверяем до
    # разговоров о пересборке — иначе человек идёт пересобирать исправный DKMS.
    local _bad_s
    _bad_s=$(awg_check_hp_min_s "$conf" || true)
    if [[ -n "$_bad_s" ]]; then
      info "Причина: при защите заголовков (AWG 3.x) ядро требует"
      info "S1-S4 не меньше ${AWG_HP_MIN_S} — в этот паддинг прячется nonce."
      info "В конфиге меньше:${_bad_s}"
      info "Лечится перегенерацией параметров: Сервер (1) → п.5"
      info "(в версиях до v0.7.14 генератор мог выдать S ниже границы)"
      return 0
    fi

    if grep -qE "^${AWG3_KEYS_RE} " "$conf" 2>/dev/null; then
      info "В конфиге параметры AWG 3.x, а загруженный модуль их не поддерживает"
      if awg_module_stale 2>/dev/null; then
        info "На диске модуль новее того, что сейчас в памяти ядра — быстрее всего:"
        info "  rmmod amneziawg && modprobe amneziawg"
        info "Если rmmod не даёт (интерфейс занят): ip link delete dev awg0 ; затем rmmod"
      else
        info "Модуль в DKMS мог остаться от прошлой установки — пересобери его:"
        info "  Сервер (1) → п.1 (переустановка компонентов)"
      fi
      info "Либо понизь версию: Сервер (1) → п.5 → выбрать AWG 3.0 или 2.0"
    else
      info "Проверь параметры обфускации в $conf (Jc/Jmin/Jmax, S1-S4, H1-H4)"
      info "Подробности ядра: dmesg | tail -20"
    fi
    return 0
  fi

  # Тип устройства amneziawg ядру неизвестен — модуль не тот или не загружен
  if [[ "$low" == *"protocol not supported"* || "$low" == *"unknown device type"* || \
        "$low" == *"operation not supported"* ]]; then
    err "Ядро не умеет создавать интерфейсы amneziawg"
    info "Модуль не загружен или собран под другое ядро ($(uname -r))"
    info "Проверь:  dkms status ; uname -r ; dmesg | tail -20"
    info "Пересборка: dkms autoinstall && modprobe amneziawg"
    return 0
  fi

  # Порт занят: чаще всего висит второй интерфейс или старый wg
  if [[ "$low" == *"address already in use"* ]]; then
    local p holder="" _l
    p=$(grep -m1 '^ListenPort' "$conf" 2>/dev/null | tr -dc '0-9' || true)
    err "Порт ${p:-из конфига} уже занят другим процессом"
    # Показываем держателя сразу: подсказать команду мало — её всё равно
    # запускают следующим шагом, а имя процесса и есть ответ.
    holder=$(_port_holder "$p")
    if [[ -n "$holder" ]]; then
      info "Держит порт:"
      while IFS= read -r _l; do
        [[ -n "$_l" ]] && echo -e "  ${D}│ ${_l}${N}"
      done <<< "$holder"
    else
      info "Кто держит: ss -lunp | grep ':${p:-порт}'"
    fi
    info "Если это старый интерфейс — сними его: awg-quick down awg0 ; wg-quick down wg0"
    return 0
  fi

  # PostUp с iptables упал — awg-quick в этом случае откатывает интерфейс
  if [[ "$low" == *"iptables"* ]]; then
    err "Правила iptables из PostUp не применились"
    info "Проверь бэкенд: iptables -V (на Ubuntu 24.04 это nf_tables)"
    info "Пакеты: apt-get install -y iptables"
    return 0
  fi

  if [[ "$low" == *"resolvconf"* ]]; then
    err "awg-quick не нашёл resolvconf (строка DNS в конфиге)"
    info "Поставь: apt-get install -y openresolv"
    return 0
  fi

  if [[ "$low" == *"command not found"* ]]; then
    err "Не найдены бинарники amneziawg (awg / awg-quick)"
    info "Переустанови компоненты: Сервер (1) → п.1"
    return 0
  fi

  # Ничего не распознали — не выдумываем причину, а даём точки проверки
  warn "Причина не распознана по выводу — смотри строки выше"
  info "Дополнительно: dmesg | tail -20 ; awg-quick up $conf"
  return 0
}

# Поднимает интерфейс из $1 (по умолчанию серверный конфиг) и, если не
# получилось, ПОКАЗЫВАЕТ вывод awg-quick и разбирает причину.
#
# До этого все вызовы глушили stderr в /dev/null, и на руках оставалось только
# «awg-quick up провалился» — по такому сообщению чинить нечего. Возвращает код
# awg-quick.
awg_up_diag() {
  local conf="${1:-$SERVER_CONF}" out rc line
  out=$(awg-quick up "$conf" 2>&1); rc=$?

  # Остаток предыдущего запуска: интерфейс есть, но конфиг к нему не применён.
  # Единственный случай, когда повтор осмысленно делать самим.
  if [[ $rc -ne 0 && "$out" == *"File exists"* ]] && ip link show awg0 &>/dev/null; then
    log_info "awg_up_diag: снимаю остаточный awg0 и пробую снова"
    info "Интерфейс awg0 остался с прошлого запуска — снимаю и пробую снова"
    awg-quick down "$conf" &>/dev/null || ip link del awg0 &>/dev/null || true
    out=$(awg-quick up "$conf" 2>&1); rc=$?
  fi

  if [[ $rc -eq 0 ]]; then
    log_info "awg_up_diag: awg-quick up успешно ($conf)"
    return 0
  fi

  log_err "awg_up_diag: awg-quick up rc=$rc: $(printf '%s' "$out" | tr '\n' ';')"
  echo ""
  echo -e "  ${D}── вывод awg-quick up ──${N}"
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo -e "  ${D}│ ${line}${N}"
  done <<< "$out"
  echo -e "  ${D}────────────────────────${N}"
  awg_diagnose_up_failure "$out" "$conf"
  return "$rc"
}

# Проверяет, тянет ли текущая пара tools+модуль параметры AWG 3.0 или 3.1.
# $1 = версия ("3.0" по умолчанию, "3.1"). Результат кэшируется на запуск:
# проба создаёт временный интерфейс, дёргать её из меню в цикле нельзя.
#
# Коды: 0 — поддерживает, 1 — точно НЕ поддерживает, 2 — проверить не удалось.
#
# Единственный признак, по которому можно уверенно сказать «нет» — бинарник awg
# не знает ключа версии (3.0 — HeaderProtectionKey, 3.1 — RandomTrailers): он
# парсит конфиг сам, и без ключа в нём такой сервер не поднимется. Всё
# остальное — свидетельства в пользу «да»:
#   • работающий awg0, в котором эти параметры уже применены;
#   • успешный setconf на временном интерфейсе.
# Неудача этих проверок означает ровно «не смогли убедиться» (код 2), а не
# «не поддерживает»: временный интерфейс может не создаться, setconf — упасть
# по причинам, к версии протокола отношения не имеющим. Ошибочное «не
# поддерживает» пугает на пустом месте, поэтому этот вывод здесь запрещён.
awg_probe_proto() {
  local proto="${1:-3.0}" key val cache_var cached
  case "$proto" in
    3.1) key="RandomTrailers";     val="on"  ; cache_var="_AWG31_PROBE" ;;
    *)   proto="3.0"; key="HeaderProtectionKey"; val=""; cache_var="_AWG3_PROBE" ;;
  esac
  cached="${!cache_var:-}"
  [[ -n "$cached" ]] && return "$cached"

  # Имя интерфейса ограничено 15 символами — короткий префикс плюс PID влезает
  local awg_bin dev="awgprb$$" tmp pkey out rc
  awg_bin=$(command -v awg 2>/dev/null) || { printf -v "$cache_var" '%s' 2; return 2; }

  # 1. Знает ли сам бинарник ключ этой версии — единственный надёжный «нет»
  if ! grep -qa "$key" "$awg_bin" 2>/dev/null; then
    log_info "awg_probe_proto $proto: в $awg_bin нет $key → tools без $proto"
    printf -v "$cache_var" '%s' 1; return 1
  fi

  # 2. Живой awg0 с применёнными параметрами — доказательство сильнее пробы
  if awg showconf awg0 2>/dev/null | grep -qE "^${key}"; then
    log_info "awg_probe_proto $proto: awg0 уже работает с параметрами $proto"
    printf -v "$cache_var" '%s' 0; return 0
  fi

  # 3. Проба на временном интерфейсе
  if ! ip link add dev "$dev" type amneziawg 2>/dev/null; then
    log_info "awg_probe_proto $proto: не удалось создать $dev — проверка невозможна"
    printf -v "$cache_var" '%s' 2; return 2
  fi
  tmp=$(mktemp) || { ip link del "$dev" &>/dev/null; printf -v "$cache_var" '%s' 2; return 2; }
  pkey=$(awg genkey 2>/dev/null) || pkey=""
  # У 3.0 значение ключа — сам ключ (32 байта base64), у 3.1 — булево "on"
  [[ -n "$val" ]] || val=$(awg genkey 2>/dev/null) || val=""
  printf '[Interface]\nPrivateKey = %s\n%s = %s\n' "$pkey" "$key" "$val" > "$tmp"
  out=$(awg setconf "$dev" "$tmp" 2>&1) && rc=0 || rc=2
  rm -f "$tmp"
  ip link del "$dev" &>/dev/null || true

  # Причину неудачи пишем в лог: она понадобится, если сервер потом не встанет
  if [[ $rc -ne 0 ]]; then
    log_info "awg_probe_proto $proto: setconf не прошёл — $(printf '%s' "$out" | tr '\n' ';')"
    # «Line unrecognized» на ключе версии — уже приговор, а не неясность
    if [[ "$out" == *"Line unrecognized"* && "$out" == *"$key"* ]]; then
      printf -v "$cache_var" '%s' 1; return 1
    fi
  else
    log_info "awg_probe_proto $proto: setconf прошёл — $proto поддерживается"
  fi
  printf -v "$cache_var" '%s' "$rc"
  return "$rc"
}

# Обратно совместимые обёртки: 3.0 проверяется в нескольких местах.
awg_probe_awg3()  { awg_probe_proto "3.0"; }
awg_probe_awg31() { awg_probe_proto "3.1"; }

# Предупреждает, если сервер собираются переводить на 3.x на компонентах,
# которые этого точно не умеют. $1 = версия. Возвращает 1, если пользователь
# отказался продолжать.
awg_compat_gate() {
  local proto="${1:-3.0}" hint="" rc=0
  # Голый вызов не годится: под set -e код 1/2 завершил бы весь скрипт — то
  # есть ровно в том случае, ради которого проба и написана.
  awg_probe_proto "$proto" || rc=$?
  case $rc in
    0) return 0 ;;
    2)
      # Проверить не смогли — это не повод пугать: серверы на 3.x поднимаются
      # и там, где проба не сработала. Если что-то пойдёт не так, причину
      # назовёт awg_up_diag при подъёме.
      log_info "awg_compat_gate: поддержка $proto не подтверждена, продолжаем молча"
      return 0
      ;;
  esac

  [[ "$proto" == "3.1" ]] && hint="Нужны amneziawg-tools и модуль v3.1.20260812 или новее"

  echo ""
  err "Установленный awg не знает параметров AWG ${proto}"
  info "Он сам разбирает конфиг, поэтому сервер ${proto} с ним не поднимется"
  [[ -n "$hint" ]] && info "$hint"
  info "Обнови компоненты: Сервер (1) → п.1 (пересборка tools и модуля)"
  echo ""
  local _go
  read_yesno _go "$(echo -e "${Y}  Всё равно продолжить с ${proto}? [y/N]: ${N}")" "n"
  [[ "$_go" == "y" ]] && return 0
  return 1
}

awg3_compat_gate() { awg_compat_gate "3.0"; }

# Проверяет состояние awg0 и пытается починить:
#   - конфиг есть, но интерфейс не запущен → awg-quick up
#   - конфиг есть и интерфейс запущен, но peer'ов нет → reload
#   - модуль не загружен → modprobe
do_repair() {
  echo ""
  hdr "🔧 Проверка и авторемонт awg0"

  local issues=0 fixed=0

  # 1. Модуль ядра — проверяем 3 способами для надёжности
  # На некоторых VPS lsmod может глючить, /sys/module/ — самый надёжный
  local mod_loaded=0
  if [[ -d /sys/module/amneziawg ]]; then
    mod_loaded=1
  elif lsmod 2>/dev/null | grep -qE '^amneziawg\s'; then
    mod_loaded=1
  elif grep -qE '^amneziawg\s' /proc/modules 2>/dev/null; then
    mod_loaded=1
  fi

  if [[ $mod_loaded -eq 1 ]]; then
    ok "Модуль amneziawg загружен"
  else
    warn "Модуль amneziawg НЕ загружен"
    issues=$((issues+1))
    info "Пробую: modprobe amneziawg"
    if modprobe amneziawg 2>/dev/null; then
      # Проверяем результат опять через /sys
      if [[ -d /sys/module/amneziawg ]]; then
        ok "Модуль загружен"
        fixed=$((fixed+1))
      else
        warn "modprobe вернул успех, но модуль не виден — попробуй reboot"
      fi
    else
      # Типовая причина: apt подтянул новое ядро, машину перезагрузили, а
      # модуль собран под прежнее. Пробуем пересобрать, а не советовать.
      warn "modprobe не сработал — пробую пересобрать модуль под $(uname -r)"

      # Secure Boot: пересборка не поможет, неподписанный модуль всё равно
      # не загрузится. Говорим об этом сразу, а не после долгой сборки.
      local _sb=""
      if command -v mokutil &>/dev/null; then
        _sb=$(mokutil --sb-state 2>/dev/null | grep -io 'enabled' || true)
      fi
      if [[ -n "$_sb" ]]; then
        err "Включён Secure Boot — ядро отвергает неподписанные DKMS-модули"
        info "Варианты: подписать модуль своим MOK-ключом либо выключить"
        info "Secure Boot в настройках сервера/BIOS"
      elif ! command -v dkms &>/dev/null; then
        err "dkms не установлен — пересобрать нечем"
        info "Переустанови: Сервер (1) → п.1"
      else
        if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
          info "Ставлю заголовки: linux-headers-$(uname -r)"
          apt-get install -y -q "linux-headers-$(uname -r)" >/dev/null 2>&1 || \
            warn "Заголовки под $(uname -r) не установились"
        fi
        info "Запускаю: dkms autoinstall (это займёт минуту)"
        if dkms autoinstall >/dev/null 2>&1 && modprobe amneziawg 2>/dev/null && \
           [[ -d /sys/module/amneziawg ]]; then
          ok "Модуль пересобран под $(uname -r) и загружен"
          fixed=$((fixed+1))
        else
          err "Пересборка не помогла"
          info "Проверь вручную:"
          info "  dkms status                  (под какие ядра собран модуль)"
          info "  uname -r                     (какое ядро загружено)"
          info "  dmesg | tail -20             (ошибки ядра)"
          info "Если dkms status пуст — переустанови: Сервер (1) → п.1"
        fi
      fi
    fi
  fi

  # 1.5. Автозагрузка модуля при старте системы
  if [[ -f /etc/modules-load.d/amneziawg.conf ]] && \
     grep -q "^amneziawg" /etc/modules-load.d/amneziawg.conf; then
    ok "Автозагрузка модуля настроена"
  else
    warn "Автозагрузка модуля НЕ настроена (после reboot модуль не поднимется сам)"
    issues=$((issues+1))
    if echo "amneziawg" > /etc/modules-load.d/amneziawg.conf 2>/dev/null; then
      ok "Автозагрузка настроена: /etc/modules-load.d/amneziawg.conf"
      fixed=$((fixed+1))
    else
      err "Не удалось записать /etc/modules-load.d/amneziawg.conf"
    fi
  fi

  # 2. Конфиг
  if [[ ! -f "$SERVER_CONF" ]]; then
    err "Серверный конфиг не найден: $SERVER_CONF"
    info "Сначала Сервер (1) → п.2 — создать сервер"
    return 1
  fi
  ok "Серверный конфиг на месте"

  # 2.2. Маркер уровня CPS: по нему бот решает, сколько пакетов I1-I5 положить
  # клиенту. У серверов, созданных до появления маркера, его нет — восстановим
  # по уже выданным конфигам, иначе бот выдаёт один I1 там, где скрипт даёт пять.
  if ! grep -q '^# AWG_OBF_LEVEL=' "$SERVER_CONF" 2>/dev/null; then
    local _lvl=0
    if grep -qE '^I[2-5] = ' /root/*_awg2.conf 2>/dev/null; then
      _lvl=3
    elif grep -qE '^I1 = ' /root/*_awg2.conf 2>/dev/null; then
      _lvl=2
    fi
    if [[ $_lvl -gt 0 ]]; then
      if sed -i "1a # AWG_OBF_LEVEL=$_lvl" "$SERVER_CONF" 2>/dev/null; then
        ok "Восстановлен маркер уровня CPS по клиентским конфигам (=$_lvl)"
      else
        warn "Не удалось записать маркер уровня CPS в $SERVER_CONF"
      fi
    else
      info "Уровень CPS определить не по чему — клиентских конфигов с I1 нет"
    fi
  else
    ok "Маркер уровня CPS на месте ($(grep -m1 '^# AWG_OBF_LEVEL=' "$SERVER_CONF" | cut -d= -f2))"
  fi

  # 2.4. S1-S4 против требования ядра к защите заголовков. Конфиг с таким
  # нарушением не поднимется никогда — и по сообщению awg-quick это не видно.
  local _hp_bad
  _hp_bad=$(awg_check_hp_min_s "$SERVER_CONF" || true)
  if [[ -n "$_hp_bad" ]]; then
    err "S-параметры ниже минимума для AWG 3.x:${_hp_bad} (нужно >= ${AWG_HP_MIN_S})"
    issues=$((issues+1))
    info "Ядро отвергнет такой конфиг: в паддинг S1-S4 прячется nonce защиты заголовков"
    info "Починка: Сервер (1) → п.5 (перегенерировать параметры)"
  else
    [[ -f "$SERVER_CONF" ]] && grep -q '^HeaderProtectionKey = ' "$SERVER_CONF" 2>/dev/null && \
      ok "S1-S4 не ниже минимума для защиты заголовков (${AWG_HP_MIN_S})"
  fi

  # 2.5. Конфиг просит 3.x — умеют ли это установленные tools и модуль?
  # Проверяем до попытки подъёма: иначе видно только «awg-quick up провалился»,
  # а настоящая причина — что модуль или awg старее конфига. Версию берём из
  # самих ключей, а не из маркера: маркер могли потерять при ручной правке.
  if grep -qE "^${AWG3_KEYS_RE} " "$SERVER_CONF" 2>/dev/null; then
    local _need="3.0" _rc=0
    grep -qE "^${AWG31_KEYS_RE} " "$SERVER_CONF" 2>/dev/null && _need="3.1"
    awg_probe_proto "$_need" || _rc=$?
    case $_rc in
      0) ok "Компоненты поддерживают AWG ${_need} (как в конфиге)" ;;
      1)
        err "Конфиг на AWG ${_need}, но установленный awg не знает его параметров"
        issues=$((issues+1))
        info "Интерфейс с такими параметрами не поднимется. Варианты:"
        info "  • обновить компоненты: Сервер (1) → п.1 (пересборка tools и модуля)"
        info "  • понизить версию: Сервер (1) → п.5 → выбрать AWG 3.0 или 2.0"
        ;;
      # Проверить не смогли — молчим: ложная тревога здесь хуже пропущенной
      *) log_info "do_repair: поддержка AWG ${_need} не подтверждена пробой" ;;
    esac
  fi

  # 3. IP forwarding
  local ipfwd
  ipfwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
  if [[ "$ipfwd" == "1" ]]; then
    ok "IP forwarding включён"
  else
    warn "IP forwarding выключён"
    issues=$((issues+1))
    sysctl -w net.ipv4.ip_forward=1 -q
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
      echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    ok "IP forwarding включён"
    fixed=$((fixed+1))
  fi

  # 4. Интерфейс
  if ip link show awg0 &>/dev/null; then
    ok "Интерфейс awg0 присутствует"

    # Проверка состояния (UP/DOWN)
    if ip link show awg0 | grep -q "state UP\|UP,"; then
      ok "awg0 в состоянии UP"
    else
      warn "awg0 существует, но не UP"
      issues=$((issues+1))
      ip link set awg0 up 2>/dev/null && ok "awg0 поднят" && fixed=$((fixed+1)) || \
        warn "Не удалось поднять, попробуем перезапуск"
    fi

    # Сверяем количество peer'ов в конфиге и в ядре
    local conf_peers live_peers
    conf_peers=$(grep -c "^\[Peer\]" "$SERVER_CONF" 2>/dev/null || echo "0")
    live_peers=$(awg show awg0 peers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$conf_peers" != "$live_peers" ]]; then
      warn "Расхождение: в конфиге $conf_peers пиров, в ядре $live_peers"
      issues=$((issues+1))
      info "Перезапуск awg0 для синхронизации..."
      awg-quick down "$SERVER_CONF" 2>/dev/null || true
      sleep 1
      if awg_up_diag "$SERVER_CONF"; then
        ok "awg0 перезапущен — пиры синхронизированы"
        fixed=$((fixed+1))
      else
        err "Не удалось перезапустить awg0"
      fi
    else
      ok "Пиры синхронизированы ($conf_peers)"
    fi
  else
    warn "Интерфейс awg0 НЕ существует"
    issues=$((issues+1))
    info "Запускаю: awg-quick up $SERVER_CONF"
    if awg_up_diag "$SERVER_CONF"; then
      ok "awg0 запущен"
      fixed=$((fixed+1))
    else
      err "awg-quick up провалился — причина выше"
    fi
  fi

  # 5. iptables NAT
  local ext_if
  ext_if=$(ip route | awk '/default/ {print $5; exit}')
  if [[ -n "$ext_if" ]]; then
    if iptables -t nat -C POSTROUTING -o "$ext_if" -j MASQUERADE >/dev/null 2>&1; then
      ok "iptables NAT MASQUERADE на $ext_if"
    else
      warn "iptables NAT MASQUERADE отсутствует"
      issues=$((issues+1))
      iptables -t nat -A POSTROUTING -o "$ext_if" -j MASQUERADE && \
        ok "MASQUERADE добавлен" && fixed=$((fixed+1))
    fi

    if iptables -C FORWARD -i awg0 -j ACCEPT >/dev/null 2>&1; then
      ok "iptables FORWARD -i awg0 ACCEPT"
    else
      warn "iptables FORWARD -i awg0 отсутствует"
      issues=$((issues+1))
      iptables -A FORWARD -i awg0 -j ACCEPT && \
        ok "FORWARD -i awg0 добавлен" && fixed=$((fixed+1))
    fi
  fi

  # Права на конфиги (если случайно сменили — клиенты могут не подняться)
  if [[ -d /etc/amnezia/amneziawg ]]; then
    local dir_perm
    dir_perm=$(stat -c '%a' /etc/amnezia/amneziawg 2>/dev/null || echo "")
    if [[ "$dir_perm" != "700" ]]; then
      warn "Папка /etc/amnezia/amneziawg имеет права $dir_perm (должно быть 700)"
      issues=$((issues+1))
      chmod 700 /etc/amnezia/amneziawg 2>/dev/null && \
        ok "Права 700 восстановлены" && fixed=$((fixed+1))
    else
      ok "Права /etc/amnezia/amneziawg = 700"
    fi
  fi

  if [[ -f "$SERVER_CONF" ]]; then
    local conf_perm
    conf_perm=$(stat -c '%a' "$SERVER_CONF" 2>/dev/null || echo "")
    if [[ "$conf_perm" != "600" ]]; then
      warn "Серверный конфиг имеет права $conf_perm (должно быть 600)"
      issues=$((issues+1))
      chmod 600 "$SERVER_CONF" 2>/dev/null && \
        ok "Права 600 восстановлены" && fixed=$((fixed+1))
    else
      ok "Права $SERVER_CONF = 600"
    fi
  fi

  # Итог
  echo ""
  if [[ $issues -eq 0 ]]; then
    success_box "✓ Всё в порядке — ремонт не требуется"
  elif [[ $fixed -eq $issues ]]; then
    success_box "✓ Найдено $issues проблем(ы), все исправлены"
  else
    hdr "⚠ Найдено $issues проблем(ы), исправлено $fixed"
    info "Часть проблем требует ручного вмешательства"
  fi
}

# Версия в сравниваемое число: "v0.7.5" → "0007005".
# Ведущий ноль делает строку восьмеричной для bash, поэтому все сравнения с
# результатом обязаны идти через 10# — см. tests/test_version.sh.
ver_num() {
  echo "${1#v}" | awk -F. '{ printf "%d%03d%03d\n", $1, $2, $3 ? $3 : 0 }'
}

# ── Уведомление о новой версии ──
#
# Про релизы узнавали только из телеграма. Теперь скрипт сам раз в 6 часов
# смотрит версию на GitHub — в фоне, чтобы запуск не ждал сеть, — и кладёт
# ответ в кэш. Шапка читает кэш, никуда не обращаясь.
# UPDATE_CACHE ("<версия> <unixtime>") задаётся update_channel_apply в шапке —
# у каждого канала обновлений свой файл кэша.
UPDATE_CHECK_TTL=21600                      # 6 часов

update_check_async() {
  [[ -n "${AWG_NO_UPDATE_CHECK:-}" ]] && return 0
  command -v curl &>/dev/null || return 0

  local ts=0 now
  now=$(date +%s)
  [[ -f "$UPDATE_CACHE" ]] && ts=$(awk '{print $2+0; exit}' "$UPDATE_CACHE" 2>/dev/null || echo 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  (( now - ts < UPDATE_CHECK_TTL )) && return 0

  mkdir -p "$(dirname "$UPDATE_CACHE")" 2>/dev/null || return 0

  # Тянем только начало файла: VERSION= стоит в первых строках, качать ради
  # него полмегабайта незачем. Если сервер не понял Range — придёт всё, но
  # это фон, никто не ждёт.
  (
    local v
    v=$(curl -fsSL --connect-timeout 5 --max-time 10 -r 0-4095 \
          -H "Cache-Control: no-cache" "${UPDATE_URL}?nocache=${now}" 2>/dev/null \
        | grep -m1 '^VERSION=' | cut -d'"' -f2)
    [[ -n "$v" ]] && printf '%s %s\n' "$v" "$(date +%s)" > "$UPDATE_CACHE"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# Печатает версию из кэша, если она новее текущей. Иначе молчит и возвращает 1.
update_available() {
  [[ -f "$UPDATE_CACHE" ]] || return 1
  local v cur new
  v=$(awk '{print $1; exit}' "$UPDATE_CACHE" 2>/dev/null || true)
  [[ -n "$v" && "$v" != "?" ]] || return 1
  cur=$(ver_num "$VERSION"); new=$(ver_num "$v")
  [[ "$cur" =~ ^[0-9]+$ && "$new" =~ ^[0-9]+$ ]] || return 1
  (( 10#$new > 10#$cur )) || return 1
  echo "$v"
}

# Запоминает версию как актуальную — чтобы бейдж «доступно обновление» исчез
# сразу после установки, а не жил до следующей фоновой проверки.
update_cache_set() {
  local v="$1"
  [[ -n "$v" ]] || return 0
  mkdir -p "$(dirname "$UPDATE_CACHE")" 2>/dev/null || return 0
  printf '%s %s\n' "$v" "$(date +%s)" > "$UPDATE_CACHE" 2>/dev/null || true
}

# Скачивает $1 в $2, рисуя шкалу прогресса.
#
# curl уходит в фон, а размер на диске сверяется с Content-Length из заголовков
# ЭТОГО ЖЕ ответа (--dump-header), а не отдельного HEAD-запроса: на HEAD сервер
# может ответить иначе, и тогда шкала считает проценты от чужой длины —
# показывала 100% на первых килобайтах.
#
# Своя шкала, а не `curl --progress-bar`: та не знает про наши отступы и цвета.
# Если Content-Length не пришёл (chunked), показываем накопленные килобайты без
# процентов — качать в полной тишине хуже.
# Возвращает код curl.
download_with_progress() {
  local url="$1" dest="$2"
  local total=0 pid rc got pct filled width=32 bar
  local hdr="${dest}.hdr"
  : > "$hdr"

  curl -fsSL --connect-timeout 10 --max-time 60 \
    -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" \
    -D "$hdr" "$url" -o "$dest" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    # Заголовки приходят раньше тела, поэтому длину пробуем читать до неё
    if [[ $total -eq 0 && -s "$hdr" ]]; then
      total=$(awk 'BEGIN{IGNORECASE=1}
                   /^HTTP\// {code=$2}
                   /^content-length:/ {v=$2}
                   END{gsub(/\r/,"",v); gsub(/\r/,"",code)
                       if (code ~ /^2/) print v+0; else print 0}' "$hdr" 2>/dev/null)
      [[ "$total" =~ ^[0-9]+$ ]] || total=0
    fi
    got=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [[ $total -gt 0 ]]; then
      pct=$(( got * 100 / total ))
      (( pct > 100 )) && pct=100
      filled=$(( pct * width / 100 ))
      bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $(( width - filled )) '' | tr ' ' '.')
      printf '\r  %b[%s]%b %3d%%  %s KB' "$G" "$bar" "$N" "$pct" \
        "$(awk -v b="$got" 'BEGIN{printf "%.0f", b/1024}')"
    else
      printf '\r  %bСкачано: %s KB%b' "$C" \
        "$(awk -v b="$got" 'BEGIN{printf "%.0f", b/1024}')" "$N"
    fi
    sleep 0.2
  done
  wait "$pid"; rc=$?
  rm -f "$hdr"

  # Финальная отрисовка: при успехе шкала должна остаться полной, а не на 97%
  got=$(stat -c%s "$dest" 2>/dev/null || echo 0)
  if [[ $rc -eq 0 ]]; then
    bar=$(printf '%*s' "$width" '' | tr ' ' '#')
    printf '\r  %b[%s]%b 100%%  %s KB\n' "$G" "$bar" "$N" \
      "$(awk -v b="$got" 'BEGIN{printf "%.0f", b/1024}')"
  else
    printf '\r%*s\r' 60 ''   # стираем недорисованную шкалу
  fi
  return "$rc"
}

do_self_update() {
  echo ""
  hdr "⬇  Обновление скрипта"

  # ───── 1. Проверка прав ─────
  if [[ $EUID -ne 0 ]]; then
    err "Обновление требует root прав"
    info "Запусти: ${W}sudo awg2${N}"
    return 1
  fi

  # Куда установлен awg2 — ищем динамически
  local target="$SCRIPT_PATH"
  if [[ ! -f "$target" ]]; then
    # Резервный путь — текущий запущенный скрипт
    target=$(readlink -f "$0" 2>/dev/null || echo "$0")
  fi

  # Проверка возможности записи в target
  if [[ ! -w "$target" ]] && [[ ! -w "$(dirname "$target")" ]]; then
    err "Нет прав на запись в $target"
    info "Проверь: ls -la $target"
    return 1
  fi

  info "Канал: $(update_channel_label) ${D}(${UPDATE_REPO})${N}"
  info "URL: $UPDATE_URL"
  info "Файл: $target"
  echo ""

  # ───── 2. Скачивание с обходом CDN кеша ─────
  local tmp_file
  tmp_file=$(mktemp /tmp/awg2.new.XXXXXX) || { err "mktemp провалился"; return 1; }

  # Добавляем nocache параметр чтобы обойти GitHub CDN
  # GitHub raw кеширует на 5 минут — без этого новый код не виден сразу после push
  local fetch_url
  fetch_url="${UPDATE_URL}?nocache=$(date +%s)"
  info "Скачиваем (с обходом CDN кеша)..."
  if ! download_with_progress "$fetch_url" "$tmp_file"; then
    err "Не удалось скачать обновление"
    info "Проверь соединение или URL"
    rm -f "$tmp_file"
    return 1
  fi

  # ───── 3. Валидация скачанного ─────
  # Проверка размера (минимум 50 КБ — наш скрипт ~200 КБ)
  local tmp_size
  tmp_size=$(stat -c%s "$tmp_file" 2>/dev/null || echo 0)
  if [[ $tmp_size -lt 50000 ]]; then
    err "Скачанный файл слишком мал ($tmp_size байт)"
    info "Возможно сетевой сбой или GitHub отдал ошибку"
    rm -f "$tmp_file"
    return 1
  fi
  info "Скачано: $(echo "$tmp_size" | awk '{printf "%.1f KB", $1/1024}')"

  # Должен быть bash-скрипт
  if ! head -1 "$tmp_file" | grep -q '^#!.*bash'; then
    err "Скачанный файл не похож на bash-скрипт"
    rm -f "$tmp_file"
    return 1
  fi

  # Проверка синтаксиса
  if ! bash -n "$tmp_file" 2>/dev/null; then
    err "Скачанный скрипт содержит синтаксические ошибки"
    info "Возможно сетевой сбой при скачивании, попробуй ещё раз"
    rm -f "$tmp_file"
    return 1
  fi

  # ───── 4. Извлечение версии ─────
  local new_ver
  new_ver=$(grep -m1 '^VERSION=' "$tmp_file" 2>/dev/null | cut -d'"' -f2 || true)
  if [[ -z "$new_ver" ]]; then
    warn "Не удалось определить версию в скачанном файле"
    new_ver="?"
  fi

  echo -e "  ${W}Текущая  : ${N}$VERSION"
  echo -e "  ${W}Новая    : ${N}$new_ver"
  echo ""

  # Хеш для отладки (помогает понять — реально ли разные версии)
  if command -v sha256sum &>/dev/null; then
    local cur_hash new_hash
    cur_hash=$(sha256sum "$target" 2>/dev/null | cut -c1-12)
    new_hash=$(sha256sum "$tmp_file" 2>/dev/null | cut -c1-12)
    echo -e "  ${D}Хеши:    $cur_hash → $new_hash${N}"
    echo ""
  fi

  # ───── 5. Сравнение версий ─────
  # Версия → число вида МАЖОР|МИНОР(3)|ПАТЧ(3). У схемы 0.x мажор нулевой, поэтому
  # строка получается с ведущим нулём ("0007001") — сравнивать её обычной
  # арифметикой нельзя: bash считает такое восьмеричным и на 0.7.9 / 0.8.x
  # падает с "value too great for base", проваливаясь не в ту ветку.
  # Отсюда 10# во всех сравнениях ниже.
  local cur_num new_num
  cur_num=$(ver_num "$VERSION")
  new_num=$(ver_num "$new_ver")
  cur_num=${cur_num:-0}; new_num=${new_num:-0}

  if [[ "$new_ver" == "?" ]]; then
    warn "Не удалось определить версию"
    local CONFIRM_FORCE
    read_yesno CONFIRM_FORCE "$(echo -e "${C}  Установить всё равно? [y/N]: ${N}")" "n"
    if [[ ! "$CONFIRM_FORCE" =~ ^[Yy]$ ]]; then
      rm -f "$tmp_file"
      return 0
    fi
  elif (( 10#$new_num < 10#$cur_num )); then
    warn "На GitHub версия СТАРШЕ текущей — это даунгрейд!"
    echo -e "${Y}  Текущая ($VERSION) > GitHub ($new_ver)${N}"
    echo -e "${Y}  Возможно ты обновлял скрипт вручную, а в репо ещё старая версия,${N}"
    echo -e "${Y}  либо в проекте сменилась схема нумерации.${N}"
    echo ""
    if ! read_confirm "$(echo -e "${R}  Откатить до $new_ver? (введи yes): ${N}")"; then
      info "Отменено — текущая версия сохранена"
      rm -f "$tmp_file"
      return 0
    fi
  elif (( 10#$new_num == 10#$cur_num )); then
    # Версии равны. Если содержимое тоже идентично — обновление не нужно.
    if cmp -s "$target" "$tmp_file"; then
      ok "У тебя уже последняя версия ($VERSION) — обновление не требуется"
      rm -f "$tmp_file"
      return 0
    fi
    info "Версия совпадает, но содержимое отличается (обновление через git без bump VERSION?)"
    local CONFIRM_FORCE
    read_yesno CONFIRM_FORCE "$(echo -e "${C}  Всё равно перезаписать? [y/N]: ${N}")" "n"
    if [[ ! "$CONFIRM_FORCE" =~ ^[Yy]$ ]]; then
      rm -f "$tmp_file"
      return 0
    fi
  else
    ok "Доступно обновление: $VERSION → $new_ver"
    echo ""
    local CONFIRM_UPDATE
    read_yesno CONFIRM_UPDATE "$(echo -e "${C}  Установить обновление? [Y/n]: ${N}")" "y"
    if [[ ! "$CONFIRM_UPDATE" =~ ^[Yy]$ ]]; then
      info "Отменено — текущая версия сохранена"
      rm -f "$tmp_file"
      return 0
    fi
  fi

  # ───── 6. Бэкап текущего скрипта ─────
  local backup
  backup="${target}.bak.$(date +%s)"
  if cp "$target" "$backup" 2>/dev/null; then
    info "Резервная копия: $backup"
  else
    warn "Не удалось создать резервную копию (продолжаем)"
  fi

  # ───── 7. Atomic replace ─────
  chmod +x "$tmp_file"
  if mv "$tmp_file" "$target"; then
    ok "Скрипт обновлён до $new_ver"
    # Бейдж «доступно обновление» должен исчезнуть сразу, не дожидаясь
    # следующей фоновой проверки
    update_cache_set "$new_ver"

    # Раньше здесь стоял гейт "новая версия >= 6.7". После смены схемы нумерации
    # на 0.x он стал бы навсегда ложным — и чистка отключилась бы ровно у тех,
    # кто приезжает со старых 6.x и кому она нужна. Гейт убран.
    if _purge_legacy_ppa; then
      info "Удалены остатки PPA от прошлых версий (теперь установка через git)"
    fi

    # ───── 8. Сброс bash hash cache ─────
    # Bash кеширует пути исполняемых файлов в памяти. После mv нужен сброс,
    # иначе при следующем запуске awg2 может выполниться старый кеш.
    hash -r 2>/dev/null || true

    # ───── 9. Перезапуск ─────
    # Файл на диске уже новый, а в памяти живёт прежний код: bash дочитывает
    # скрипт по ходу исполнения, поэтому продолжать работу в этом процессе
    # нельзя — часть функций будет старой, часть новой. Предлагаем exec: он
    # заменяет процесс на месте, и человеку не надо ничего набирать заново.
    echo ""
    echo -e "  ${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  ${W}  Нужен перезапуск: этот процесс всё ещё работает на старой${N}"
    echo -e "  ${W}  версии, новая лежит в ${target}${N}"
    echo -e "  ${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""

    local _restart
    read_yesno _restart "$(echo -e "${G}  Перезапустить сейчас? [Y/n]: ${N}")" "y"
    if [[ "$_restart" == "y" ]]; then
      # --post-update передаёт прежнюю версию новому процессу: иначе после
      # мгновенного обновления в шапке видна прежняя версия и непонятно,
      # случилось ли что-нибудь вообще.
      if [[ -x "$target" ]]; then
        log_info "do_self_update: exec $target после обновления до $new_ver"
        info "Перезапускаюсь..."
        sleep 1
        exec "$target" --post-update "$VERSION"
      fi
      # На всякий случай: файл не исполняемый — запускаем через bash
      log_info "do_self_update: exec bash $target (нет +x)"
      exec bash "$target" --post-update "$VERSION"
    fi

    warn "Перезапуск отложен — до него меню работает на старой версии"
    info "Запусти заново: ${W}sudo awg2${N}"
    echo ""
    return 0
  else
    err "Не удалось заменить файл (нет прав?)"
    info "Скачанная версия: $tmp_file"
    return 1
  fi
}

show_header() {
  clear
  local s ip port st clients
  s=$(get_status)
  IFS='|' read -r ip port st clients <<< "$s"

  # Читаем профиль из awg0.conf (Lite / Standard / Pro / —)
  local profile_raw="—"
  local profile_label="—"
  if [[ -f "$SERVER_CONF" ]]; then
    profile_raw=$(grep -m1 '^# AWG_PROFILE=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
    case "$profile_raw" in
      lite)     profile_label="Lite" ;;
      standard) profile_label="Standard" ;;
      pro)      profile_label="Pro" ;;
      "")       profile_label="—" ;;
      *)        profile_label="$profile_raw" ;;
    esac
    # Версия протокола: маркера нет у серверов, созданных до 0.7.3 — там 2.0
    local proto_raw
    proto_raw=$(grep -m1 '^# AWG_PROTO=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
    profile_label="${profile_label} ${D}/ AWG ${proto_raw:-2.0}${N}"
  fi

  # Бейдж новой версии — из кэша, без обращения к сети (см. update_check_async)
  local _upd _ver_line _ch_badge=""
  # На бета-канале это должно быть видно с первого экрана — иначе непонятно,
  # откуда приехала версия, которой нет у остальных.
  [[ "$UPDATE_CHANNEL" == "beta" ]] && _ch_badge=" ${Y}[beta]${N}"
  _upd=$(update_available || true)
  if [[ -n "$_upd" ]]; then
    _ver_line="  ${W}AwgToolza $VERSION${N}${_ch_badge}   ${G}⬆ есть $_upd${N} ${D}— пункт 8${N}"
  else
    _ver_line="  ${W}AwgToolza $VERSION${N}${_ch_badge}"
  fi

  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "$_ver_line"
  echo -e "  ${C}TG: @awgToolza${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  IP сервера : ${W}$ip${N}"
  echo -e "  Порт       : ${W}$port${N}"
  echo -e "  Интерфейс  : $st${N}"
  echo -e "  Профиль    : ${W}$profile_label${N}"
  echo -e "  Клиентов   : ${W}$clients${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ══════════════════════════════════════════════════════════
# ДВУХУРОВНЕВОЕ МЕНЮ
# Уровень 1: show_menu      — 7 категорий (CHOICE)
# Уровень 2: show_submenu_N — пункты внутри категории (SUB_CHOICE)
# Выход из подменю: 0 → возврат в главное меню (не exit)
# Выход из главного меню: 0 → exit 0
# ══════════════════════════════════════════════════════════

show_menu() {
  echo ""
  echo -e "  ${C}1)${N}  Сервер          ${D}— установка${N}"
  echo -e "  ${C}2)${N}  Клиенты         ${D}— управление${N}"
  echo -e "  ${C}3)${N}  Диагностика     ${D}— тест, домены${N}"
  echo -e "  ${C}4)${N}  Бекапы          ${D}— создать, восстановить${N}"
  echo -e "  ${C}5)${N}  Туннели и DNS   ${D}— Warp, DNS, каскад${N}"
  echo -e "  ${C}6)${N}  Telegram-бот    ${D}— управление ботом${N}"
  echo -e "  ${R}7)${N}  Удаление и сброс ${D}—  вроде понятно${N}"
  if [[ "$UPDATE_CHANNEL" == "beta" ]]; then
    echo -e "  ${M}8)${N}  Обновить скрипт  ${D}— GitHub, канал:${N} ${Y}бета${N}"
  else
    echo -e "  ${M}8)${N}  Обновить скрипт  ${D}— загрузить с GitHub${N}"
  fi
  echo ""
  echo -e "  ${W}0)${N}  Выход"
  echo ""
  # Без DEFAULT: пустой Enter переспрашивает, а не выходит из скрипта.
  # Ctrl+D отдаёт 0 → штатный выход.
  read_choice CHOICE "$(echo -e "${C}  Выбор [0-8]: ${N}")" 0 8
}

# ── Подменю 1: Сервер ──────────────────────────────────
show_submenu_1() {
  while true; do
    check_deps
    show_header
    echo ""
    hdr "Сервер"
    echo ""
    echo -e "  ${C}1)${N} Установка зависимостей и AmneziaWG"
    if $HAS_AWG; then
      echo -e "  ${C}2)${N} Создать сервер + первый клиент (с мимикрией)"
    else
      echo -e "  ${D}2) Создать сервер (нужен пункт 1)${N}"
    fi
    if $HAS_SERVER_CONF; then
      echo -e "  ${C}3)${N} Перезапустить awg0"
    else
      echo -e "  ${D}3) Перезапустить awg0 (нужен пункт 2)${N}"
    fi
    if $HAS_SERVER_CONF; then
      echo -e "  ${C}4)${N} Проверить и починить awg0 (авторемонт)"
    else
      echo -e "  ${D}4) Авторемонт (нужен пункт 2)${N}"
    fi
    if $HAS_SERVER_CONF; then
      echo -e "  ${C}5)${N} Перегенерировать параметры обфускации"
      local _ep_now
      _ep_now=$(endpoint_domain)
      echo -e "  ${C}6)${N} Endpoint для клиентов  ${D}${_ep_now:-IP сервера}${N}"
      echo -e "  ${Y}7)${N} Сбросить настройки сервера (чистая переустановка)"
    else
      echo -e "  ${D}5) Перегенерировать параметры (нужен пункт 2)${N}"
      echo -e "  ${D}6) Endpoint для клиентов (нужен пункт 2)${N}"
      echo -e "  ${D}7) Сбросить сервер (нет сервера)${N}"
    fi
    echo ""
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice SUB_CHOICE "$(echo -e "${C}  Выбор [0-7]: ${N}")" 0 7 "0"
    case "${SUB_CHOICE:-}" in
      1) do_install || true ;;
      2) do_gen || true ;;
      3) do_restart || true ;;
      4) do_repair || true ;;
      5) do_rotate_awg_params || true ;;
      6) do_endpoint_menu || true ;;
      7) do_reset_server || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || return 0
  done
}

# ── Подменю 2: Клиенты ─────────────────────────────────
show_submenu_2() {
  while true; do
    check_deps
    show_header
    echo ""
    hdr "Клиенты"
    echo ""
    if $HAS_AWG && $HAS_SERVER_CONF; then
      echo -e "  ${C}1)${N} Управление клиентами (добавить/rename/delete/QR)"
    else
      echo -e "  ${D}1) Управление клиентами (нужен пункт Сервер → 2)${N}"
    fi
    if $HAS_AWG && $HAS_SERVER_CONF; then
      echo -e "  ${C}2)${N} Активность клиентов"
    else
      echo -e "  ${D}2) Активность клиентов (нужен пункт Сервер → 2)${N}"
    fi
    echo ""
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice SUB_CHOICE "$(echo -e "${C}  Выбор [0-2]: ${N}")" 0 2 "0"
    case "${SUB_CHOICE:-}" in
      1) do_manage_clients || true ;;
      2) do_list_clients || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || return 0
  done
}

# ── Подменю 3: Диагностика ─────────────────────────────
show_submenu_3() {
  while true; do
    check_deps
    show_header
    echo ""
    hdr "Диагностика"
    echo ""
    echo -e "  ${G}1)${N} Проверить домены из пулов (TCP+ping)"
    if $HAS_SERVER_CONF; then
      echo -e "  ${G}2)${N} Тест DPI мимикрии (захват CPS пакета)"
    else
      echo -e "  ${D}2) Тест DPI мимикрии (нужен пункт Сервер → 2)${N}"
    fi
    echo ""
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice SUB_CHOICE "$(echo -e "${C}  Выбор [0-2]: ${N}")" 0 2 "0"
    case "${SUB_CHOICE:-}" in
      1) do_check_domains || true ;;
      2) do_sniff_test || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || return 0
  done
}

# ── Подменю 4: Бекапы ──────────────────────────────────
show_submenu_4() {
  while true; do
    check_deps
    show_header
    echo ""
    hdr "Бекапы"
    echo ""
    echo -e "  ${B}1)${N} Создать бекап (~/awg_backup/)"
    if $HAS_BACKUPS; then
      echo -e "  ${B}2)${N} Восстановить из бекапа"
    else
      echo -e "  ${D}2) Восстановить из бекапа (нет бекапов)${N}"
    fi
    echo ""
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice SUB_CHOICE "$(echo -e "${C}  Выбор [0-2]: ${N}")" 0 2 "0"
    case "${SUB_CHOICE:-}" in
      1) do_backup || true ;;
      2) do_restore || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || return 0
  done
}

# ── Подменю 5: Туннели и DNS ───────────────────────────
show_submenu_5() {
  while true; do
    check_deps
    show_header
    echo ""
    hdr "Туннели и DNS"
    echo ""
    # Warp статус
    if ip link show warp0 &>/dev/null; then
      echo -e "  ${C}1)${N} Warp туннель  ${G}● включен${N}"
    elif [[ -f "$WARP_CONF" ]]; then
      echo -e "  ${C}1)${N} Warp туннель  ${D}○ настроен, выключен${N}"
    else
      echo -e "  ${C}1)${N} Warp туннель  ${D}○ не настроен${N}"
    fi
    # DNS статус
    if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && \
       iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT \
         --to-destination "${DNS_PROXY_ADDR:-127.0.2.1}:${DNS_PROXY_PORT:-53}" >/dev/null 2>&1; then
      echo -e "  ${C}2)${N} DNS-шифрование  ${G}● включено${N}"
    elif command -v dnscrypt-proxy &>/dev/null; then
      echo -e "  ${C}2)${N} DNS-шифрование  ${D}○ установлен, выключен${N}"
    else
      echo -e "  ${C}2)${N} DNS-шифрование  ${D}○ не настроен${N}"
    fi
    # Каскад статус
    local _casc_rules=0
    if [[ -f "$CASCADE_RULES" ]]; then
      _casc_rules=$(grep -cvE '^\s*(#|$)' "$CASCADE_RULES" 2>/dev/null || true)
      [[ "$_casc_rules" =~ ^[0-9]+$ ]] || _casc_rules=0
    fi
    if (( _casc_rules > 0 )) && systemctl is-enabled awg-cascade.service &>/dev/null; then
      echo -e "  ${C}3)${N} Каскад  ${G}● активен${N} ${D}(${_casc_rules} правил)${N}"
    elif (( _casc_rules > 0 )); then
      echo -e "  ${C}3)${N} Каскад  ${Y}○ правила есть, persist выключен${N}"
    else
      echo -e "  ${C}3)${N} Каскад  ${D}○ не настроен${N}"
    fi
    echo ""
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice SUB_CHOICE "$(echo -e "${C}  Выбор [0-3]: ${N}")" 0 3 "0"
    case "${SUB_CHOICE:-}" in
      1) do_warp_menu || true ;;
      2) do_dns_menu || true ;;
      3) do_cascade_menu || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    # do_warp_menu / do_dns_menu / do_cascade_menu имеют свой loop,
    # после выхода из них мы уже здесь — не нужен read
  done
}

# ── Подменю 6: Telegram-бот ────────────────────────────
show_submenu_6() {
  # BOT_INSTALL_URL — глобальный, зависит от канала обновлений (см. шапку)
  local BOT_PY="/usr/local/bin/awg-bot.py"

  while true; do
    check_deps
    show_header
    echo ""
    hdr "Telegram-бот управления"
    echo ""

    # Считаем ботом любые его следы, а не только маркер: после частичного
    # удаления маркера может не быть, а сервис и код в /opt остаются — и их
    # надо чем-то добить, иначе пункт удаления недоступен.
    local installed=false
    if [[ -f "$BOT_PY" || -d /opt/awg-bot ]] || \
       [[ -f /etc/systemd/system/awg-bot.service ]]; then
      installed=true
    fi

    if $installed; then
      if systemctl is-active --quiet awg-bot 2>/dev/null; then
        echo -e "  Статус: ${G}● запущен${N}"
      else
        echo -e "  Статус: ${Y}○ установлен, остановлен${N}"
      fi
    else
      echo -e "  Статус: ${D}○ не установлен${N}"
    fi
    echo ""

    if $installed; then
      echo -e "  ${C}1)${N} Переустановить / обновить бота"
      echo -e "  ${G}2)${N} Запустить"
      echo -e "  ${G}3)${N} Остановить"
      echo -e "  ${G}4)${N} Перезапустить"
      echo -e "  ${C}5)${N} Логи (последние 40 строк)"
      echo -e "  ${R}6)${N} Полностью удалить бота ${D}(сервис, код, venv, токен)${N}"
    else
      echo -e "  ${C}1)${N} Установить бота"
    fi
    echo -e "  ${W}0)${N} ← Назад"
    echo ""

    # Набор пунктов зависит от того, установлен ли бот
    local _bc _bc_max=1
    $installed && _bc_max=6
    read_choice _bc "$(echo -e "${C}  Выбор [0-${_bc_max}]: ${N}")" 0 "$_bc_max" "0"

    case "${_bc:-}" in
      1)
        if [[ $EUID -ne 0 ]]; then
          err "Установка требует root. Запусти: ${W}sudo awg2${N}"
        else
          # Локальная копия рядом (распакованный архив awg-toolza) важнее
          # GitHub: при проверке правок в репозитории ещё старый код бота.
          local _local_src _use_local="n"
          _local_src=$(_find_local_bot_src || true)
          if [[ -n "$_local_src" ]]; then
            echo ""
            info "Найден локальный код бота: ${W}${_local_src}${N}"
            read_yesno _use_local "$(echo -e "${G}  Ставить из него (иначе с GitHub)? [Y/n]: ${N}")" "y"
          fi

          if [[ "$_use_local" == "y" ]]; then
            local _local_installer="${_local_src%/awg_bot}/awg-bot-install.sh"
            if [[ -f "$_local_installer" ]]; then
              bash "$_local_installer" --src "$_local_src" || \
                warn "Установщик завершился с ошибкой"
            else
              # Установщик рядом не лежит — берём с GitHub, но код из копии
              info "Локального установщика нет, беру его с GitHub (код бота — локальный)"
              if curl -fsSL "$BOT_INSTALL_URL" -o /tmp/awg-bot-install.sh; then
                bash /tmp/awg-bot-install.sh --src "$_local_src" || \
                  warn "Установщик завершился с ошибкой"
                rm -f /tmp/awg-bot-install.sh 2>/dev/null || true
              else
                err "Не удалось скачать установщик с GitHub"
              fi
            fi
          else
            info "Скачиваю и запускаю установщик бота... ${D}(канал: $(update_channel_label))${N}"
            if curl -fsSL "$BOT_INSTALL_URL" -o /tmp/awg-bot-install.sh; then
              # Код бота берём из того же репозитория, что и сам скрипт: иначе на
              # бета-канале бот приедет из стабильного репо и разъедется с awg2.
              AWG_REPO_URL="$UPDATE_REPO_GIT" bash /tmp/awg-bot-install.sh || \
                warn "Установщик завершился с ошибкой"
              rm -f /tmp/awg-bot-install.sh 2>/dev/null || true
            else
              err "Не удалось скачать установщик с GitHub"
              info "Проверь интернет/доступ к raw.githubusercontent.com"
              [[ -n "$_local_src" ]] && \
                info "Локальная копия рядом: bash ${_local_src%/awg_bot}/awg-bot-install.sh --src $_local_src"
            fi
          fi
        fi
        ;;
      2)
        if $installed; then
          systemctl start awg-bot 2>/dev/null && ok "Запущен" || err "Не удалось запустить"
        else
          warn "Бот не установлен — сначала пункт 1"
        fi
        ;;
      3)
        if $installed; then
          systemctl stop awg-bot 2>/dev/null && ok "Остановлен" || err "Не удалось остановить"
        else
          warn "Бот не установлен"
        fi
        ;;
      4)
        if $installed; then
          systemctl restart awg-bot 2>/dev/null && ok "Перезапущен" || err "Не удалось перезапустить"
        else
          warn "Бот не установлен"
        fi
        ;;
      5)
        if $installed; then
          echo ""
          journalctl -u awg-bot -n 40 --no-pager 2>/dev/null || \
            tail -n 40 /var/log/awg-bot.log 2>/dev/null || \
            warn "Логи недоступны"
        else
          warn "Бот не установлен"
        fi
        ;;
      6)
        if $installed; then
          do_bot_uninstall || true
        else
          warn "Бот не установлен"
        fi
        ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac

    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || return 0
  done
}

# ── Подменю 7: Опасная зона ────────────────────────────
show_submenu_7() {
  while true; do
    check_deps
    show_header
    echo ""
    hdr "Удаление и сброс"
    echo ""
    if $HAS_SERVER_CONF; then
      echo -e "  ${Y}1)${N} Очистить всех клиентов (без удаления сервера)"
    else
      echo -e "  ${D}1) Очистить клиентов (нужен пункт Сервер → 2)${N}"
    fi
    echo -e "  ${R}2)${N} Удалить всё ${D}(пакеты, конфиги, бот, сам awg2)${N}"
    echo ""
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice SUB_CHOICE "$(echo -e "${C}  Выбор [0-2]: ${N}")" 0 2 "0"
    case "${SUB_CHOICE:-}" in
      1) do_clean_clients || true ;;
      2) do_uninstall || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || return 0
  done
}

# ── Подменю 8: Обновление скрипта ──────────────────────
# Раньше пункт 8 сразу качал обновление. Теперь здесь же переключается канал
# источника — чтобы не плодить пункты в главном меню.
do_switch_update_channel() {
  local target label
  if [[ "$UPDATE_CHANNEL" == "beta" ]]; then target="stable"; else target="beta"; fi
  label=$(update_channel_label "$target")

  echo ""
  if [[ "$target" == "beta" ]]; then
    warn "Бета-канал — ранние сборки из ${UPDATE_REPO_BETA}"
    warn "Они не проходят полный цикл проверки: на боевом сервере — на свой риск"
    echo ""
    if ! read_confirm "$(echo -e "${Y}  Переключиться на бета-канал? (введи yes): ${N}")"; then
      info "Отменено — канал прежний ($(update_channel_label))"
      return 0
    fi
  else
    local _yn
    read_yesno _yn "$(echo -e "${C}  Вернуться на стабильный канал? [Y/n]: ${N}")" "y"
    if [[ ! "$_yn" =~ ^[Yy]$ ]]; then
      info "Отменено — канал прежний ($(update_channel_label))"
      return 0
    fi
  fi

  if update_channel_set "$target"; then
    ok "Канал обновлений: ${label} ${D}(${UPDATE_REPO})${N}"
    log_info "Канал обновлений переключён на ${target} (${UPDATE_REPO})"
    if [[ "$target" == "stable" ]]; then
      info "Если текущая версия новее стабильной — обновление предложит откат"
    fi
    # Кэш у каждого канала свой, поэтому бейдж в шапке обновится только после
    # проверки нового канала — запускаем её сразу, в фоне.
    update_check_async || true
  else
    err "Не удалось сохранить канал в ${UPDATE_CHANNEL_FILE}"
    info "Проверь права на /var/lib/awg2"
    return 1
  fi
  return 0
}

show_submenu_8() {
  while true; do
    check_deps
    show_header
    echo ""
    hdr "Обновление скрипта"
    echo ""
    echo -e "  Текущая версия : ${W}${VERSION}${N}"
    if [[ "$UPDATE_CHANNEL" == "beta" ]]; then
      echo -e "  Канал          : ${Y}бета${N} ${D}(${UPDATE_REPO})${N}"
    else
      echo -e "  Канал          : ${G}стабильный${N} ${D}(${UPDATE_REPO})${N}"
    fi
    local _upd
    _upd=$(update_available || true)
    [[ -n "$_upd" ]] && echo -e "  Доступна       : ${G}${_upd}${N}"
    echo ""
    echo -e "  ${C}1)${N} Обновить скрипт ${D}— скачать с GitHub${N}"
    if [[ "$UPDATE_CHANNEL" == "beta" ]]; then
      echo -e "  ${C}2)${N} Вернуться на стабильный канал"
    else
      echo -e "  ${C}2)${N} Переключиться на бета-канал ${D}(ранние сборки)${N}"
    fi
    echo ""
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    local _uc
    read_choice _uc "$(echo -e "${C}  Выбор [0-2]: ${N}")" 0 2 "0"
    case "${_uc:-}" in
      1) do_self_update || true ;;
      2) do_switch_update_channel || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || return 0
  done
}

choose_dns() {
  CLIENT_DNS=""
  hdr "◎  DNS для клиента"
  echo ""

  # Если включено DNS-шифрование (п.5 → Туннели и DNS) — показать подсказку
  if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && \
     iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR:-127.0.2.1}:${DNS_PROXY_PORT:-53}" >/dev/null 2>&1; then
    echo -e "  ${G}⚡ Шифрованный DNS включён${N} ${D}(п.5 → Туннели и DNS)${N}"
    echo -e "  ${D}→ Любой выбор будет автоматически перенаправлен через DoH${N}"
    echo -e "  ${D}→ Реальные запросы пойдут через Cloudflare/Google/Cisco${N}"
    echo ""
  fi

  echo "  1) Cloudflare  — 1.1.1.1, 1.0.0.1"
  echo "  2) Google      — 8.8.8.8, 8.8.4.4"
  echo "  3) OpenDNS     — 208.67.222.222, 208.67.220.220"
  echo "  4) Яндекс DNS  — 77.88.8.8, 77.88.8.1"
  echo "  5) Вручную"
  read_choice DNS_CHOICE "$(echo -e "${C}  Выбор [1-5] (Enter = Cloudflare): ${N}")" 1 5 1
  case $DNS_CHOICE in
    1) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
    2) CLIENT_DNS="8.8.8.8, 8.8.4.4" ;;
    3) CLIENT_DNS="208.67.222.222, 208.67.220.220" ;;
    4) CLIENT_DNS="77.88.8.8, 77.88.8.1" ;;
    5) read -rp "  DNS: " CLIENT_DNS ;;
  esac
}

# H1-H4: 8 random + sort алгоритм (из amneziawg-installer)
#   Гарантирует непересечение без квадрантов.
#   Ограничение 2^31-1 для совместимости с Windows клиентом.
# Jc/Jmax: снижены для мобильных сетей (Yota/Tele2/МТС).
# Результат: глобальная AWG_PARAMS_LINES
# Выбор версии протокола AmneziaWG при создании сервера.
#
# Параметры 3.0 — уровня УСТРОЙСТВА (в модуле это WGDEVICE_A_*), то есть
# действуют на весь интерфейс сразу. Отдельному клиенту свою версию выдать
# нельзя: включив 3.0, сервер перестаёт принимать клиентов на 2.0. Поэтому
# спрашиваем один раз при создании и пишем маркер в awg0.conf.
# Результат: глобальная AWG_PROTO = "2.0" | "3.0" | "3.1"
choose_awg_proto() {
  AWG_PROTO="2.0"
  echo ""
  hdr "▤  Версия протокола AmneziaWG"
  echo ""
  echo -e "  ${G}1)${N} ${W}AWG 2.0${N} ${D}(по умолчанию, максимальная совместимость)${N}"
  echo -e "     ${D}Обфускация Jc/Jmin/Jmax, S1-S4, H1-H4 плюс мимикрия I1-I5.${N}"
  echo -e "     ${D}Работает со всеми клиентами AmneziaWG.${N}"
  echo ""
  echo -e "  ${G}2)${N} ${W}AWG 3.0${N} ${C}(сильнее против анализа трафика)${N}"
  echo -e "     ${D}Дополнительно: защита заголовков ключом, случайный паддинг${N}"
  echo -e "     ${D}содержимого и рандомизация таймингов рукопожатий —${N}"
  echo -e "     ${D}то есть скрывает не только размеры, но и временные паттерны.${N}"
  echo ""
  echo -e "  ${G}3)${N} ${W}AWG 3.1${N} ${C}(новейшая, самая узкая совместимость)${N}"
  echo -e "     ${D}Всё из 3.0 плюс RandomTrailers — случайный «хвост» у пакетов${N}"
  echo -e "     ${D}рукопожатия, из-за чего их длина перестаёт быть постоянной,${N}"
  echo -e "     ${D}и DisableCookies — сервер не отвечает cookie-пакетами.${N}"
  echo -e "     ${D}Нужны amneziawg-tools и модуль v3.1.20260812 или новее${N}"
  echo -e "     ${D}И НА СЕРВЕРЕ, И НА КЛИЕНТЕ: старый клиент такой конфиг${N}"
  echo -e "     ${D}даже не прочитает.${N}"
  echo ""
  echo -e "  ${Y}  Требует клиента с поддержкой выбранной версии. Версия задаётся${N}"
  echo -e "  ${Y}  на ВЕСЬ сервер: клиенты на 2.0 к серверу 3.x не подключатся.${N}"
  echo ""
  local _proto_choice
  read_choice _proto_choice "$(echo -e "${C}  Выбор [1-3] (Enter = 1): ${N}")" 1 3 "1"
  case "$_proto_choice" in
    2|3)
      # Проверяем до генерации конфигов: с несовместимыми tools/модулем
      # сервер 3.x просто не поднимется, а конфиги уже будут перезаписаны.
      local _want="3.0"
      [[ "$_proto_choice" == "3" ]] && _want="3.1"
      if awg_compat_gate "$_want"; then
        AWG_PROTO="$_want"; ok "Выбран AmneziaWG $_want"
      else
        AWG_PROTO="2.0"; info "Остаёмся на AmneziaWG 2.0"
      fi
      ;;
    *) AWG_PROTO="2.0"; ok "Выбран AmneziaWG 2.0" ;;
  esac
  log_info "AWG_PROTO=$AWG_PROTO"
}

# Заменяет блок параметров AmneziaWG в секции [Interface] файла.
# Работает и для серверного конфига, и для клиентских: строки I1-I5, ключи,
# адреса, DNS, MTU и секция [Peer] не трогаются — меняются только параметры
# обфускации, а они у сервера и всех клиентов обязаны совпадать.
# $1 = файл, $2 = новые строки параметров (с реальными переводами строк)
_replace_awg_params() {
  local file="$1" params="$2" tmp rc
  [[ -f "$file" ]] || return 1
  tmp=$(mktemp) || return 1

  awk -v params="$params" -v re="^${AWG_PARAM_KEYS_RE} = " '
    BEGIN { in_iface = 0; inserted = 0 }
    /^\[Interface\]/ { in_iface = 1; print; next }
    /^\[/ {
      # начало любой другой секции — параметры вставляем до неё
      if (in_iface && !inserted) { print params; inserted = 1 }
      in_iface = 0; print; next
    }
    {
      if (in_iface && $0 ~ re) {
        # старый параметр: первый заменяем блоком, остальные выбрасываем
        if (!inserted) { print params; inserted = 1 }
        next
      }
      print
    }
    END { if (in_iface && !inserted) print params }
  ' "$file" > "$tmp"
  rc=$?

  if [[ $rc -ne 0 || ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi
  # Проверяем, что параметры действительно на месте — иначе не подменяем файл
  if ! grep -qE "^${AWG_PARAM_KEYS_RE} = " "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp" > "$file" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
  return 0
}

# Значение PersistentKeepalive для клиентского конфига.
#
# На 2.0 — фиксированные 25 секунд, как было: старые клиенты диапазон могут не
# понять, а выигрыша там всё равно нет.
#
# На 3.0 и 3.1 — диапазон. Это не косметика: ядро выбирает значение заново на каждой
# отправке (u16_range_pick_one в timers.c), а фиксированные 25 дают пакет ровно
# раз в 25 секунд — идеально стабильную временную сигнатуру. Рандомизировать
# рекеи и оставить keepalive константой значит наполовину обесценить 3.0.
# Диапазон держим вокруг привычных 25 с, чтобы не ломать проход через NAT:
# слишком редкий keepalive рвёт сессию у домашних роутеров.
awg_keepalive_value() {
  local proto="${AWG_PROTO:-}"
  # Клиента могли добавлять уже после создания сервера — тогда AWG_PROTO в
  # этой сессии не задана, и версию надо взять из конфига сервера. Без этого
  # такой клиент получил бы фиксированные 25 на сервере 3.0.
  if [[ -z "$proto" && -f "$SERVER_CONF" ]]; then
    proto=$(grep -m1 '^# AWG_PROTO=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  fi
  if [[ "${proto:-2.0}" == "3.0" || "${proto:-2.0}" == "3.1" ]]; then
    echo "$(rand_range 18 24)-$(rand_range 26 34)"
  else
    echo "25"
  fi
}

# Ключи параметров AmneziaWG уровня УСТРОЙСТВА, появившиеся в 3.x. Они обязаны
# совпадать у сервера и всех клиентов, и по ним же диагностика понимает, что
# конфиг требует компонентов новее.
#   3.0 — HeaderProtectionKey, ContentPaddingAddition и таймеры;
#   3.1 — RandomTrailers и DisableCookies (amneziawg-tools v3.1.20260812).
AWG3_KEYS_RE="(HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)"
# Ключи, которые отличают именно 3.1: по ним выбирается версия пробы.
AWG31_KEYS_RE="(RandomTrailers|DisableCookies)"

# Нижняя граница S1-S4 при включённой защите заголовков.
# Ядро (netlink.c модуля: «S1 must be more then %d to use headerProtection»)
# отвергает setconf, если при заданном HeaderProtectionKey хоть одно из S1-S4
# меньше HEADER_PROTECTION_NONCE_SIZE — в этот паддинг прячется nonce защиты
# заголовков (header_protection.h: NONCE_SIZE = 12). Наружу это выглядит как
# «Unable to modify interface: Invalid argument» при подъёме awg0.
AWG_HP_MIN_S=12

# Размеры сообщений WireGuard до паддинга (messages.h модуля). S1-S3
# прибавляются к ним, поэтому два типа сообщений становятся ОДНОЙ длины, когда
# S отличаются ровно на разницу базовых размеров:
#   148 + S1 == 92 + S2  →  S2 = S1 + 56   (initiation против response)
#   148 + S1 == 64 + S3  →  S3 = S1 + 84   (initiation против cookie)
#    92 + S2 == 64 + S3  →  S3 = S2 + 28   (response против cookie)
# Совпавшая длина возвращает наблюдателю ровно то, что паддинг прятал, — тип
# пакета. Раньше проверялось только первое совпадение, а третье достижимо в
# профиле Pro примерно в одной генерации из 350.
AWG_S_DELTA_INIT_RESP=56
AWG_S_DELTA_INIT_COOKIE=84
AWG_S_DELTA_RESP_COOKIE=28
AWG_S_GAP=10                # запас с каждой стороны от совпадения

# Потолки из реализаций, а не из советов:
#   S4  — amneziawg-tools src/config.c
#   Jc  — модуль принимает 0..128; свыше 64 рукопожатие заметно медленнее,
#         потому что все junk-пакеты уходят перед initiation
AWG_S4_MAX=32
AWG_JC_MAX=128
AWG_JC_SLOW=64

# Все ключи параметров AmneziaWG, которые клиент обязан получить от сервера.
# Единый источник: любой новый параметр добавляется здесь, а не в трёх местах.
# 2.0 — Jc/Jmin/Jmax, S1-S4, H1-H4. 3.x — см. AWG3_KEYS_RE.
AWG_PARAM_KEYS_RE="(Jc|Jmin|Jmax|S[1-4]|H[1-4]|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)"

# Диапазон S по профилю — единственное место, где эти числа записаны.
# Раньше они дублировались: один набор в блоке профиля, второй — в цикле
# коррекции S2, и разойтись им ничто не мешало.
_awg_rand_s() {
  case "${AWG_PROFILE:-pro}" in
    lite)
      # Образец оригинальной Amnezia: S1=102, S2=22, S3=21, S4=7 (±5)
      case "$1" in
        S1) rand_range 97 107 ;; S2) rand_range 17 27 ;;
        S3) rand_range 16 26 ;;  S4) rand_range 4 10 ;;
      esac ;;
    standard)
      case "$1" in
        S1) rand_range 30 80 ;; S2) rand_range 30 80 ;;
        S3) rand_range 15 32 ;; S4) rand_range 10 20 ;;
      esac ;;
    pro|*)
      case "$1" in
        S1) rand_range 15 150 ;; S2) rand_range 15 150 ;;
        S3) rand_range 8 64 ;;  S4) rand_range 6 31 ;;
      esac ;;
  esac
}

# Истина, если два числа ближе друг к другу, чем AWG_S_GAP.
_s_too_close() {
  local d=$(( $1 - $2 ))
  (( d < 0 )) && d=$(( -d ))
  (( d < AWG_S_GAP ))
}

# Разводит S1-S3 от всех трёх совпадений длин (см. AWG_S_DELTA_*).
# Сначала перебор в рамках профиля — так значения остаются характерными для
# него; если за 20 попыток не сошлось (узкие диапазоны Lite/Standard), доводим
# детерминированным сдвигом вверх. Порядок важен: сперва S2 относительно S1,
# потом S3 относительно обоих, иначе правка S2 ломает уже разведённый S3.
_awg_fix_s_collisions() {
  local tries=0
  while (( tries < 20 )); do
    _s_too_close $(( S1 + AWG_S_DELTA_INIT_RESP ))   "$S2" || \
    _s_too_close $(( S1 + AWG_S_DELTA_INIT_COOKIE )) "$S3" || \
    _s_too_close $(( S2 + AWG_S_DELTA_RESP_COOKIE )) "$S3" || break
    S2=$(_awg_rand_s S2)
    S3=$(_awg_rand_s S3)
    _awg_apply_hp_min_s
    tries=$(( tries + 1 ))
  done

  local guard=0 shifted=""
  while (( guard < 30 )) && _s_too_close $(( S1 + AWG_S_DELTA_INIT_RESP )) "$S2"; do
    S2=$(( S2 + AWG_S_GAP )); guard=$(( guard + 1 )); shifted="S2=$S2"
  done
  guard=0
  while (( guard < 30 )) && \
        { _s_too_close $(( S1 + AWG_S_DELTA_INIT_COOKIE )) "$S3" || \
          _s_too_close $(( S2 + AWG_S_DELTA_RESP_COOKIE )) "$S3"; }; do
    S3=$(( S3 + AWG_S_GAP )); guard=$(( guard + 1 )); shifted="${shifted} S3=$S3"
  done

  if (( tries > 0 )) || [[ -n "$shifted" ]]; then
    log_info "gen_awg_params: разведение длин (попыток=$tries${shifted:+, сдвиг: $shifted}) — S1=$S1 S2=$S2 S3=$S3"
  fi
  return 0
}

# Прижимает параметры к потолкам реализаций. Наши диапазоны в них укладываются,
# но правка диапазона не должна тихо выпускать конфиг, который отвергнет клиент.
_awg_clamp_limits() {
  if (( S4 > AWG_S4_MAX )); then
    log_info "gen_awg_params: S4=$S4 выше потолка tools ($AWG_S4_MAX) — прижат"
    S4=$AWG_S4_MAX
  fi
  if (( Jc > AWG_JC_MAX )); then
    log_info "gen_awg_params: Jc=$Jc выше потолка модуля ($AWG_JC_MAX) — прижат"
    Jc=$AWG_JC_MAX
  elif (( Jc > AWG_JC_SLOW )); then
    log_info "gen_awg_params: Jc=$Jc — рукопожатие будет заметно медленнее (>$AWG_JC_SLOW)"
  fi
  # Jmax больше MTU означает фрагментацию junk-пакетов: на части маршрутов это
  # рвёт связь и само по себе заметно.
  local _mtu="${MTU:-1280}"
  if [[ "$_mtu" =~ ^[0-9]+$ ]] && (( Jmax >= _mtu )); then
    log_info "gen_awg_params: Jmax=$Jmax не меньше MTU=$_mtu — junk будет фрагментироваться"
  fi
  return 0
}

# Поднимает S1-S4 до минимума, который требует ядро при защите заголовков.
# Работает только на 3.x: на 2.0 HeaderProtectionKey нет и ограничения тоже.
# Значение не прибивается к 12 гвоздями — иначе у всех серверов 3.x получался
# бы одинаковый паддинг, то есть сигнатура. Берём случайное из [12; 24].
_awg_apply_hp_min_s() {
  case "${AWG_PROTO:-2.0}" in
    3.0|3.1) ;;
    *) return 0 ;;
  esac
  local name val raised=""
  for name in S1 S2 S3 S4; do
    val="${!name}"
    [[ "$val" =~ ^[0-9]+$ ]] || continue
    if (( val < AWG_HP_MIN_S )); then
      printf -v "$name" '%s' "$(rand_range "$AWG_HP_MIN_S" $((AWG_HP_MIN_S + 12)))"
      raised+=" ${name}: ${val}→${!name}"
    fi
  done
  [[ -n "$raised" ]] && \
    log_info "gen_awg_params: S под 3.x подняты до >= ${AWG_HP_MIN_S} —${raised}"
  return 0
}

gen_awg_params() {
  AWG_PARAMS_LINES=""

  # ══════════════════════════════════════════════════════════
  # Параметры AmneziaWG по ОФИЦИАЛЬНОМУ МАНУАЛУ
  # https://docs.amnezia.org/documentation/amnezia-wg/
  # ══════════════════════════════════════════════════════════
  # Ветвление по AWG_PROFILE: lite / standard / pro
  # Pro = текущая логика без изменений (полные диапазоны).

  local Jc Jmin Jmax S1 S2 S3 S4

  case "${AWG_PROFILE:-pro}" in
    lite)
      # ── Lite: параметры как у оригинальной Amnezia, ±5 рандом ──
      # Образец оригинала: Jc=4, Jmin=10, Jmax=50, S1=102, S2=22, S3=21, S4=7
      Jc=$(rand_range 3 5)              # 4 ±1
      Jmin=$(rand_range 5 15)           # 10 ±5
      Jmax=$(rand_range 45 55)          # 50 ±5
      S1=$(_awg_rand_s S1); S2=$(_awg_rand_s S2)
      S3=$(_awg_rand_s S3); S4=$(_awg_rand_s S4)
      ;;
    standard)
      # ── Standard: промежуточные значения ──
      Jc=$(rand_range 5 8)
      Jmin=$(rand_range 30 80)
      Jmax=$(rand_range 100 250)
      S1=$(_awg_rand_s S1); S2=$(_awg_rand_s S2)
      S3=$(_awg_rand_s S3); S4=$(_awg_rand_s S4)
      ;;
    pro|*)
      # ── Pro: текущие полные диапазоны (без изменений) ──
      Jc=$(rand_range 4 16)
      Jmin=$(rand_range 50 256)
      Jmax=$(rand_range 300 1000)
      S1=$(_awg_rand_s S1); S2=$(_awg_rand_s S2)
      S3=$(_awg_rand_s S3); S4=$(_awg_rand_s S4)
      ;;
  esac

  # ── Инварианты мануала (применяются для всех профилей) ──

  # Нижняя граница S1-S4 для 3.x — жёсткое требование ядра, а не рекомендация.
  # Диапазоны профилей его не гарантировали: Pro брал S3 от 8 и S4 от 6, Lite —
  # S4 в 4..10. То есть сервер 3.x создавался через раз, а на Lite не
  # создавался вовсе: awg-quick падал на «Invalid argument» уже после того, как
  # конфиги записаны.
  _awg_apply_hp_min_s

  # Jmin < Jmax
  if [[ $Jmin -ge $Jmax ]]; then
    Jmax=$((Jmin + $(rand_range 100 500)))
  fi

  # Длины сообщений не должны совпадать ни в одной из трёх пар (см.
  # AWG_S_DELTA_*). Раньше проверялась только пара initiation/response.
  _awg_fix_s_collisions

  # Разведение перегенерировало S2/S3 — граница ядра проверяется ещё раз,
  # чтобы правка диапазонов профиля не вернула ошибку setconf незаметно.
  _awg_apply_hp_min_s

  # Потолки реализаций (S4, Jc) и фрагментация junk по MTU
  _awg_clamp_limits

  # ── H1-H4: уникальные диапазоны в рамках recommended [5 .. 2^31-1] ──
  # Мануал: H1/H2/H3/H4 must be unique, recommended range 5 ≤ H ≤ 2147483647
  # Разделяем весь recommended диапазон на 4 подсегмента (~2^29 каждый)
  # Sub-Q1: [5 .. 2^29-1]            (5 .. 536,870,911)
  # Sub-Q2: [2^29 .. 2^30-1]         (536,870,912 .. 1,073,741,823)
  # Sub-Q3: [2^30 .. 3*2^29-1]       (1,073,741,824 .. 1,610,612,735)
  # Sub-Q4: [3*2^29 .. 2^31-1]       (1,610,612,736 .. 2,147,483,647)
  local SQ1_MAX=536870911       # 2^29 - 1
  local SQ2_MIN=536870912       # 2^29
  local SQ2_MAX=1073741823      # 2^30 - 1
  local SQ3_MIN=1073741824      # 2^30
  local SQ3_MAX=1610612735      # 3*2^29 - 1
  local SQ4_MIN=1610612736      # 3*2^29
  local SQ4_MAX=2147483647      # 2^31 - 1 (мануальный лимит)

  # Генерация пары [lo, hi] в подсегменте, шириной >= 1000
  _gen_quadrant_pair() {
    local qmin="$1" qmax="$2"
    local span=$((qmax - qmin))
    local lo hi
    lo=$(rand_range "$qmin" $((qmin + span / 3)))
    hi=$(rand_range $((qmin + 2 * span / 3)) "$qmax")
    if (( hi - lo < 1000 )); then
      hi=$((lo + 1000 + RANDOM % 10000))
      (( hi > qmax )) && hi=$qmax
    fi
    echo "${lo}-${hi}"
  }

  local H1 H2 H3 H4
  H1=$(_gen_quadrant_pair 5 "$SQ1_MAX")
  H2=$(_gen_quadrant_pair "$SQ2_MIN" "$SQ2_MAX")
  H3=$(_gen_quadrant_pair "$SQ3_MIN" "$SQ3_MAX")
  H4=$(_gen_quadrant_pair "$SQ4_MIN" "$SQ4_MAX")

  AWG_PARAMS_LINES="Jc = $Jc\nJmin = $Jmin\nJmax = $Jmax\nS1 = $S1\nS2 = $S2\nS3 = $S3\nS4 = $S4\nH1 = $H1\nH2 = $H2\nH3 = $H3\nH4 = $H4"

  # ── AWG 3.x: защита заголовков и рандомизация таймингов ──
  # Включается на AWG_PROTO=3.0 и 3.1. Параметры уровня УСТРОЙСТВА, то есть
  # действуют на весь интерфейс сразу — клиент на 2.0 к такому серверу уже не
  # подключится. Отсюда выбор версии при создании сервера, а не на клиента.
  if [[ "${AWG_PROTO:-2.0}" == "3.0" || "${AWG_PROTO:-2.0}" == "3.1" ]]; then
    local _p3
    _p3=$(gen_awg3_params) || { err "Не удалось сгенерировать параметры AWG ${AWG_PROTO}"; return 1; }
    [[ -n "$_p3" ]] || { err "Параметры AWG ${AWG_PROTO} пусты"; return 1; }
    AWG_PARAMS_LINES+="\n${_p3}"
  fi
}

# Параметры AmneziaWG 3.0.
#
# Форматы сняты с исходников amneziawg-tools и ядерного модуля, а не по памяти:
#  • HeaderProtectionKey — ChaCha-ключ 32 байта (HEADER_PROTECTION_KEY_SIZE =
#    CHACHA_KEY_SIZE), то есть обычный awg genkey;
#  • остальные — u16_range_from_string: либо "N", либо "LO-HI" при HI >= LO,
#    оба конца uint16.
#
# ВАЖНО: модуль эти значения НЕ валидирует — принимает любой u32 и молча
# применяет. Осмысленность целиком на нас, поэтому диапазоны строятся вокруг
# протокольных дефолтов WireGuard (они же в messages.h модуля):
#   REKEY_AFTER_TIME 120, REJECT_AFTER_TIME 180, KEEPALIVE_TIMEOUT 10,
#   REKEY_TIMEOUT 5, MAX_TIMER_HANDSHAKES 18.
# Инвариант, который нельзя нарушать: RejectAfterTime > RekeyAfterTime, иначе
# сессия будет отвергнута раньше, чем сторона успеет её переустановить.
gen_awg3_params() {
  local hp_key cpa rat_lo rat_hi rjt_lo rjt_hi ka_lo ka_hi rkt mha

  # Ключ защиты заголовков — обязан совпадать на обоих концах
  hp_key=$(awg genkey 2>/dev/null || true)
  if [[ -z "$hp_key" ]]; then
    log_err "gen_awg3_params: awg genkey не сработал"
    echo ""
    return 1
  fi

  # Добавка к паддингу содержимого: 0 = выключено, поэтому берём от 8
  cpa="$(rand_range 8 24)-$(rand_range 48 96)"

  # Рекей: вокруг 120 с. Верх держим ниже нижней границы RejectAfterTime.
  rat_lo=$(rand_range 110 125)
  rat_hi=$(rand_range 140 160)

  # Отклонение сессии: строго выше рекея, вокруг 180 с
  rjt_lo=$(rand_range 175 190)
  rjt_hi=$(rand_range 200 215)
  # Страховка инварианта на случай неудачного розыгрыша
  (( rjt_lo <= rat_hi )) && rjt_lo=$((rat_hi + 15))
  (( rjt_hi <= rjt_lo )) && rjt_hi=$((rjt_lo + 20))

  # Keepalive: вокруг 10 с
  ka_lo=$(rand_range 9 14)
  ka_hi=$(rand_range 20 30)

  # Таймаут повтора рукопожатия оставляем фиксированным: разброс тут даёт
  # мало маскировки, зато заметно влияет на скорость восстановления связи.
  rkt=5
  mha=$(rand_range 16 20)

  # ── Добавка AWG 3.1 ──
  # RandomTrailers — параметр устройства, обязан совпадать на обоих концах:
  # при нём приёмник принимает пакеты рукопожатия длиннее ожидаемой (в
  # receive.c проверка длины становится >= вместо ==), а сторона без него
  # такой пакет отбросит. На транспортные пакеты он влияет только когда
  # ContentPaddingAddition нулевой (send.c: CPA имеет приоритет), поэтому у
  # нас эффект остаётся на рукопожатиях — так же, как в конфигах Amnezia,
  # где заданы оба.
  # DisableCookies — сервер не отвечает cookie-пакетом на рукопожатие под
  # нагрузкой. Эффект односторонний, но это отключает штатную защиту
  # WireGuard от флуда рукопожатиями: платим ей за то, что в трафике не
  # появляется отдельный тип пакета.
  local extra=""
  if [[ "${AWG_PROTO:-}" == "3.1" ]]; then
    extra=$'\nRandomTrailers = on\nDisableCookies = on'
  fi

  printf 'HeaderProtectionKey = %s\nContentPaddingAddition = %s\nRekeyAfterTime = %s-%s\nRekeyTimeout = %s\nRejectAfterTime = %s-%s\nKeepaliveTimeout = %s-%s\nMaxHandshakeAttempts = %s%s' \
    "$hp_key" "$cpa" "$rat_lo" "$rat_hi" "$rkt" "$rjt_lo" "$rjt_hi" "$ka_lo" "$ka_hi" "$mha" "$extra"
}

_apply_config() {
  # Попытка syncconf (без разрыва соединений)
  local strip_out
  strip_out=$(timeout 10 awg-quick strip awg0 2>/dev/null) || strip_out=""
  if [[ -n "$strip_out" ]]; then
    if echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null; then
      return 0
    fi
  fi
  # Fallback: полный restart
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  awg-quick up "$SERVER_CONF" 2>/dev/null
}

# Выдаёт готовый конфиг. $1 = файл, $2 = "qr" — показать QR вместо текста.
#
# По умолчанию печатается ТЕКСТ: после создания клиента нужен именно он —
# скопировать, положить в файл, отправить. QR остаётся отдельным осознанным
# действием (Клиенты → «Показать QR клиента»), а не тем, что заслоняет собой
# конфиг в половине случаев.
_share_config() {
  local conf_file="$1" mode="${2:-text}"
  [[ -f "$conf_file" ]] || return 1

  local conf_size
  conf_size=$(wc -c < "$conf_file")

  if [[ "$mode" == "qr" ]]; then
    # QR-лимит (с запасом) ~2800 байт: выше начинается версия символа, которую
    # камеры телефонов уже не берут с экрана терминала.
    if [[ "$conf_size" -le 2800 ]] && command -v qrencode &>/dev/null; then
      echo ""
      qrencode -t ansiutf8 -s 1 -m 1 < "$conf_file"
      echo -e "${D}  ↑ QR-код конфига (${conf_size} байт) — сканируй в AmneziaVPN${N}"
      return 0
    fi
    echo ""
    if ! command -v qrencode &>/dev/null; then
      warn "qrencode не установлен — показываю текст конфига"
    else
      warn "Конфиг ${conf_size} байт > 2800 — в читаемый QR не влезет, показываю текст"
      local has_i1
      has_i1=$(grep -cE "^I[1-5] = " "$conf_file" 2>/dev/null || echo 0)
      [[ "$has_i1" -gt 0 ]] && \
        info "Уменьшить: профиль DNS или уровень «+I1» — цепочка станет короче"
    fi
  fi

  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo -e "${W}  ≡ Текст конфига (сохрани как client.conf):${N}"
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo ""
  cat "$conf_file"
  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
}

# Удаляет остатки APT-репозиториев от версий, когда установка шла через PPA.
# Идемпотентна: путей, которых нет, rm -f не замечает.
# Возвращает 0, если что-то удалила, 1 — если чистить было нечего.
_purge_legacy_ppa() {
  local f cleaned=1
  for f in /etc/apt/sources.list.d/amnezia*.list \
           /etc/apt/sources.list.d/amnezia*.sources \
           /etc/apt/sources.list.d/canonical-kernel-team*.list \
           /etc/apt/sources.list.d/canonical-kernel-team*.sources; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      cleaned=0
    fi
  done
  rm -f /etc/apt/trusted.gpg.d/amnezia*.gpg 2>/dev/null || true
  rm -f /etc/apt/keyrings/amnezia*.gpg 2>/dev/null || true
  return $cleaned
}

# Делает правила NAT/FORWARD переживающими ребут.
# Классический путь — hook ifupdown (/etc/network/if-pre-up.d). На минимальных
# образах Ubuntu 26.04 / Debian 13 ifupdown не ставится и каталога нет — раньше
# запись туда молча падала, и после перезагрузки клиенты теряли интернет.
# Если каталога нет — поднимаем собственный systemd-юнит.
# $1 = внешний интерфейс (на момент установки)
_nat_install_persist() {
  local ext_if="$1"
  local hook="/etc/network/if-pre-up.d/iptables-nat"

  if [[ -d /etc/network/if-pre-up.d ]]; then
    cat > "$hook" <<EOF
#!/bin/sh
iptables -t nat -C POSTROUTING -o ${ext_if} -j MASQUERADE >/dev/null 2>&1 || \
iptables -t nat -A POSTROUTING -o ${ext_if} -j MASQUERADE
iptables -C FORWARD -i awg0 -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -o awg0 -j ACCEPT
EOF
    if [[ -s "$hook" ]]; then
      chmod +x "$hook"
      ok "NAT hook сохранён в $hook"
      return 0
    fi
    warn "Не удалось записать $hook — ставим systemd-юнит"
  else
    info "ifupdown не используется — NAT через systemd-юнит"
  fi

  # ── Fallback: systemd-юнит ──
  cat > "$NAT_PERSIST_SCRIPT" <<EOF
#!/bin/sh
set -u
# AWG Toolza — восстановление NAT/FORWARD при загрузке.
# Generated by _nat_install_persist, do not edit manually.
# Интерфейс определяем на лету: в облаке имя может смениться после ребута.
IFACE=\$(ip -4 route show default 2>/dev/null | awk '/default/ {print \$5; exit}')
[ -z "\$IFACE" ] && IFACE="${ext_if}"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
iptables -t nat -C POSTROUTING -o "\$IFACE" -j MASQUERADE >/dev/null 2>&1 || \\
  iptables -t nat -A POSTROUTING -o "\$IFACE" -j MASQUERADE
iptables -C FORWARD -i awg0 -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -o awg0 -j ACCEPT
exit 0
EOF
  chmod +x "$NAT_PERSIST_SCRIPT"

  cat > "$NAT_PERSIST_SERVICE" <<EOF
[Unit]
Description=AWG Toolza — NAT/FORWARD rules for awg0
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$NAT_PERSIST_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  if systemctl enable awg-nat.service >/dev/null 2>&1; then
    ok "NAT-правила переживут ребут (systemd: awg-nat.service)"
  else
    warn "systemctl enable awg-nat.service не сработал"
    warn "После перезагрузки NAT придётся вернуть вручную: sudo awg2 → Сервер (1) → п.1"
  fi
  return 0
}

do_install() {
  while true; do
  # Detect OS
  local OS_ID OS_VER OS_CODENAME
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    local _SAVED_VERSION="$VERSION"
    . /etc/os-release
    VERSION="$_SAVED_VERSION"
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-0}"
    OS_CODENAME="${VERSION_CODENAME:-}"
  else
    err "Не удалось определить ОС (/etc/os-release отсутствует)"; return 1
  fi

  hdr "▬  Обнаружена ОС"
  echo -e "  ${W}ID${N}       : $OS_ID"
  echo -e "  ${W}Version${N}  : $OS_VER"
  echo -e "  ${W}Codename${N} : ${OS_CODENAME:-n/a}"
  echo ""

  case "$OS_ID" in
    ubuntu)
      case "$OS_VER" in
        24.04|24.10|25.04|25.10|26.04)
          ok "Ubuntu $OS_VER — будем собирать amneziawg через git+DKMS"
          ;;
        *)
          warn "Ubuntu $OS_VER не в списке проверенных, но пробуем git+DKMS"
          ;;
      esac
      ;;
    debian)
      case "$OS_VER" in
        12|13)
          ok "Debian $OS_VER — будем собирать amneziawg через git+DKMS"
          ;;
        *)
          err "Debian $OS_VER не поддерживается. Нужен 12 или 13"
          return 1
          ;;
      esac
      ;;
    *)
      err "ОС $OS_ID не поддерживается. Только Ubuntu 24+ или Debian 12/13"
      return 1
      ;;
  esac

  # ───────────── Очистка остатков PPA от прошлых попыток установки
  # Чтобы apt-get update не плевался ошибками типа "Temporary failure resolving"
  # при наличии висящих PPA от прошлой версии скрипта
  hdr "✂  Очистка старых PPA"
  if _purge_legacy_ppa; then
    ok "Старые PPA удалены"
  else
    ok "Чисто — PPA остатков нет"
  fi

  # ───────────── Проверка DNS
  hdr "⌘  Проверка DNS"
  if ! getent hosts github.com &>/dev/null; then
    warn "DNS не работает — github.com не резолвится"
    info "Применяю Cloudflare + Google DNS как fallback..."
    if [[ -L /etc/resolv.conf ]]; then
      # systemd-resolved — добавляем DNS через resolvectl
      resolvectl dns 2>/dev/null | head -5 || true
      info "Если есть systemd-resolved, проверь: resolvectl status"
    fi
    cat > /tmp/resolv.conf.fix << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF
    # Бекапим существующий resolv.conf
    [[ -f /etc/resolv.conf && ! -f /etc/resolv.conf.awg-backup ]] && \
      cp /etc/resolv.conf /etc/resolv.conf.awg-backup 2>/dev/null
    cp /tmp/resolv.conf.fix /etc/resolv.conf
    rm -f /tmp/resolv.conf.fix

    if getent hosts github.com &>/dev/null; then
      ok "DNS работает (Cloudflare + Google)"
    else
      err "DNS всё ещё не работает. Проверь сетевую настройку сервера"
      info "Команды для диагностики:"
      info "  ping 1.1.1.1            (проверка интернета)"
      info "  cat /etc/resolv.conf    (текущие DNS)"
      info "  resolvectl status       (если systemd-resolved)"
      prompt_retry || return 1
      continue
    fi
  else
    ok "DNS работает"
  fi

  hdr "+  Обновление системы"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q || { err "Не удалось обновить репозитории"; prompt_retry || return 1; continue; }
  apt-get upgrade -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

  hdr "+  Установка зависимостей"
  # iputils-ping — ping не входит в минимальные облачные образы Ubuntu 26.04 /
  # Debian 13, а на нём держатся scan_pool, _probe_host и WARP health-check.
  local base_deps=(python3 net-tools curl ufw iptables qrencode bc ca-certificates gnupg iputils-ping)
  # Всегда добавляем deps для git+DKMS сборки
  base_deps+=(build-essential git libmnl-dev pkg-config dkms)
  # do_install вызывается как «do_install || true», то есть errexit внутри не
  # работает. Без явной проверки провал apt проходил молча, а ломалось потом —
  # на сборке DKMS или на отсутствии git, и уже без внятной причины.
  if ! apt-get install -y -q "${base_deps[@]}"; then
    err "Не удалось установить зависимости"
    info "Проверь вывод выше — обычно это битое зеркало или нет места на диске"
    info "Повтори вручную: apt-get update && apt-get install -y ${base_deps[*]}"
    prompt_retry || return 1; continue
  fi

  hdr "+  Kernel headers"
  local running_kernel
  running_kernel="$(uname -r)"
  info "Running kernel: $running_kernel"

  # Проверяем — есть ли headers для running kernel
  local headers_ok=0
  if [[ -d "/lib/modules/${running_kernel}/build" ]]; then
    info "Headers уже установлены"
    headers_ok=1
  else
    # Пытаемся установить headers под running kernel
    info "Устанавливаем linux-headers-${running_kernel}..."
    if apt-get install -y -q "linux-headers-${running_kernel}" 2>&1 | tail -3; then
      if [[ -d "/lib/modules/${running_kernel}/build" ]]; then
        ok "Headers установлены"
        headers_ok=1
      fi
    fi
  fi

  # Если headers всё ещё нет — пробуем мета-пакеты
  if [[ $headers_ok -eq 0 ]]; then
    apt-get install -y -q linux-headers-amd64 2>/dev/null || \
    apt-get install -y -q linux-headers-generic 2>/dev/null || true

    if [[ -d "/lib/modules/${running_kernel}/build" ]]; then
      headers_ok=1
    fi
  fi

  # Если headers всё равно нет — возможно ядро обновилось, нужен reboot
  if [[ $headers_ok -eq 0 ]]; then
    err "Kernel headers для ${running_kernel} не найдены"
    echo ""
    # Проверяем — есть ли headers под ДРУГУЮ версию ядра (значит был upgrade)
    local installed_headers=""
    local _k _count=0
    for _k in /lib/modules/*/; do
      [[ -d "$_k" ]] || continue
      _k=${_k%/}
      _k=${_k##*/}
      [[ "$_k" == "$running_kernel" ]] && continue
      installed_headers+="${_k}"$'\n'
      _count=$((_count + 1))
      [[ $_count -ge 3 ]] && break
    done
    installed_headers="${installed_headers%$'\n'}"
    if [[ -n "$installed_headers" ]]; then
      warn "Обнаружены headers под другие ядра:"
      echo "$installed_headers" | while read -r k; do echo "    /lib/modules/$k"; done
      echo ""
      warn "Скорее всего ядро было обновлено через apt upgrade"
      warn "Нужен REBOOT чтобы загрузилось новое ядро с headers"
      echo ""
      info "Команды для решения:"
      info "  1) sudo reboot          # перезагрузка"
      info "  2) sudo awg2 → 1        # повторить установку после reboot"
    else
      info "Попробуй вручную:"
      info "  sudo apt update"
      info "  sudo apt install linux-headers-\$(uname -r)"
      info "  sudo apt install linux-headers-amd64"
    fi
    prompt_retry || return 1; continue
  fi
  ok "Kernel headers готовы для ${running_kernel}"

  # AmneziaWG kernel module + tools через git+DKMS (стабильнее PPA)
  hdr "+  AmneziaWG kernel module (git + DKMS)"
  local tmp_mod=/tmp/amneziawg-linux-kernel-module
  rm -rf "$tmp_mod"
  git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git "$tmp_mod" || {
    err "Не удалось клонировать kernel module"
    info "Проверь интернет: ping github.com"
    prompt_retry || return 1; continue
  }
  (
    cd "$tmp_mod/src" || exit 1
    make dkms-install || exit 1
    local mod_ver
    mod_ver=$(grep -oP 'version\s*"\K[^"]+' dkms.conf 2>/dev/null || echo "1.0.0")
    dkms add -m amneziawg -v "$mod_ver" 2>/dev/null || true
    dkms build -m amneziawg -v "$mod_ver" || exit 1
    dkms install -m amneziawg -v "$mod_ver" || exit 1
  ) || {
    err "Сборка kernel module провалилась"
    echo ""
    info "Возможные причины:"
    info "  • Headers не соответствуют running kernel ($(uname -r))"
    info "  • Ядро было обновлено, требуется reboot"
    info "  • Нет интернета для git clone"
    echo ""
    info "Проверка:"
    info "  ls /lib/modules/$(uname -r)/build  # должна существовать"
    info "  uname -r                            # текущее ядро"
    info "  dkms status                         # состояние DKMS"
    prompt_retry || return 1; continue
  }
  rm -rf "$tmp_mod"

  # ── Сборка под ВСЕ установленные ядра, не только под работающее ──
  # apt-get upgrade выше мог принести новое ядро. DKMS собирает модуль под
  # текущее (uname -r), а хук автопересборки для нового ядра не отработал —
  # модуль регистрируется в DKMS уже ПОСЛЕ его установки. Без этого шага
  # всё живо до первой перезагрузки, а после неё грузится новое ядро,
  # modprobe amneziawg падает и awg0 не поднимается.
  local running_k newest_k k
  running_k="$(uname -r)"
  newest_k=""
  local _kernels=()
  for k in /lib/modules/*/; do
    k=${k%/}; k=${k##*/}
    [[ -e "/boot/vmlinuz-$k" ]] || continue
    # заголовки нужны, иначе DKMS не соберёт
    [[ -d "/lib/modules/$k/build" ]] || apt-get install -y -q "linux-headers-$k" >/dev/null 2>&1 || true
    _kernels+=("$k")
  done
  # Самое новое ядро — по ВЕРСИИ, а не по алфавиту. Раньше брался последний
  # элемент glob: "6.8.0-31-generic" сортируется строкой после "6.8.0-137",
  # и скрипт объявлял старое ядро новым, а заодно не замечал настоящее новое.
  if (( ${#_kernels[@]} > 0 )); then
    newest_k=$(printf '%s\n' "${_kernels[@]}" | sort -V | tail -1)
  fi
  if dkms autoinstall >/dev/null 2>&1; then
    ok "Модуль собран под все установленные ядра"
  else
    warn "dkms autoinstall отработал с ошибкой — проверь: dkms status"
  fi

  # autoinstall молча пропускает ядро без заголовков, поэтому «всё собрано»
  # проверяем по факту, а не по коду возврата
  if [[ -n "$newest_k" ]] && ! dkms status 2>/dev/null | grep -q "$newest_k"; then
    if dkms autoinstall -k "$newest_k" >/dev/null 2>&1; then
      ok "Модуль дособран под $newest_k"
    else
      warn "Модуль под $newest_k собрать не удалось (нет linux-headers-$newest_k?)"
    fi
  fi

  # Если загружено не самое новое ядро — предупреждаем прямо, а не постфактум
  if [[ -n "$newest_k" && "$newest_k" != "$running_k" ]]; then
    echo ""
    warn "Установлено более новое ядро: $newest_k (сейчас работает $running_k)"
    if dkms status 2>/dev/null | grep -q "$newest_k"; then
      info "Модуль под него собран — после reboot awg0 поднимется сам"
    else
      err "Модуль под $newest_k НЕ собран — после reboot awg0 не поднимется"
      info "Собери вручную: dkms autoinstall -k $newest_k"
    fi
    echo ""
  fi

  hdr "+  amneziawg-tools (git + make)"
  local tmp_tools=/tmp/amneziawg-tools
  rm -rf "$tmp_tools"
  git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git "$tmp_tools" || {
    err "Не удалось клонировать tools"; prompt_retry || return 1; continue
  }
  (
    cd "$tmp_tools/src" || exit 1
    make && make install
  ) || { err "Сборка tools провалилась"; prompt_retry || return 1; continue; }
  rm -rf "$tmp_tools"

  if command -v awg &>/dev/null; then
    ok "amneziawg-tools: $(awg --version 2>/dev/null || echo 'установлен')"
  else
    err "awg не найден после установки"; info "Возможно, нужен reboot и повторная установка"; prompt_retry || return 1; continue;
  fi

  hdr "⌘  Проверка модуля"
  modprobe amneziawg 2>/dev/null || true
  # Проверка через /sys для надёжности
  if [[ -d /sys/module/amneziawg ]] || lsmod 2>/dev/null | grep -qE '^amneziawg\s'; then
    ok "Модуль загружен"
  else
    warn "Модуль не загрузился. Сделай reboot и запусти снова"
  fi

  hdr "»  IP Forwarding"
  sysctl -w net.ipv4.ip_forward=1 -q
  grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  hdr "»  NAT + FORWARD"
  local ext_if
  ext_if=$(ip route | awk '/default/ {print $5; exit}')
  [[ -z "$ext_if" ]] && { err "Не найден default интерфейс"; info "Проверь: ip route | grep default"; prompt_retry || return 1; continue; }
  ok "Интерфейс: $ext_if"

  iptables -t nat -C POSTROUTING -o "$ext_if" -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -o "$ext_if" -j MASQUERADE
  iptables -C FORWARD -i awg0 -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -i awg0 -j ACCEPT
  iptables -C FORWARD -o awg0 -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -o awg0 -j ACCEPT
  ok "NAT и FORWARD правила добавлены"

  _nat_install_persist "$ext_if"

  hdr "›  Папка конфигов"
  mkdir -p /etc/amnezia/amneziawg
  chmod 700 /etc/amnezia/amneziawg

  hdr "◼  Firewall (UFW)"
  if command -v ufw &>/dev/null; then
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1 || true)
    info "Текущее состояние UFW: ${ufw_status:-неизвестно}"
    # Только подготовка forward policy (нужно для NAT клиентов AWG).
    # НЕ открываем SSH/HTTP — не нашего ума дело.
    # НЕ включаем UFW принудительно — пользователь сам решит.
    # Порт AWG/WARP/DNS откроется на соответствующих шагах,
    # только если UFW активен на тот момент.
    if [[ -f /etc/default/ufw ]]; then
      sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
      info "DEFAULT_FORWARD_POLICY=ACCEPT (требуется для NAT клиентов)"
    fi
    if echo "$ufw_status" | grep -qi "inactive"; then
      echo ""
      echo -e "  ${Y}!${N} UFW сейчас выключен. Скрипт его не включает автоматически —"
      echo -e "    чтобы не отрезать тебе SSH-доступ. Если используешь UFW —"
      echo -e "    включи сам: ${W}ufw allow <твой SSH порт>/tcp && ufw enable${N}"
    else
      info "UFW активен — порты AWG/WARP/DNS будут открыты на соответствующих шагах"
    fi
  else
    info "UFW не установлен — пропускаем"
  fi

  echo ""
  success_box "Установка завершена"
  _DEPS_CACHED=""  # сбрасываем кэш — теперь awg доступен

  # Поднимаем expire-таймер (срок действия клиентов работает с момента установки)
  _expire_install || true

  # ── Перезагрузка после сборки модуля ──
  # Установка делает apt upgrade, а он приносит новое ядро. Модуль DKMS собран
  # под него, но работает пока прежнее — и создание сервера падает на пустом
  # месте. Говорим об этом прямо здесь, а не оставляем выяснять по ошибке.
  echo ""
  local _rb_reason
  _rb_reason=$(awg_reboot_reason || true)
  if [[ -n "$_rb_reason" ]]; then
    hdr "⟳  Нужна перезагрузка"
    warn "Причина: $_rb_reason"
    echo -e "  ${Y}Без неё awg0 может не подняться: в памяти ядра сидит модуль,${N}"
    echo -e "  ${Y}не совпадающий с тем, что сейчас на диске.${N}"
    echo ""
    info "После перезагрузки: awg2 → Сервер (1) → п.2 — Создать сервер"
    echo ""
    local _do_rb
    read_yesno _do_rb "$(echo -e "${G}  Перезагрузить сейчас? [Y/n]: ${N}")" "y"
    if [[ "$_do_rb" == "y" ]]; then
      ok "Перезагружаюсь. Заходи через минуту и запускай: awg2"
      log_info "do_install: reboot по согласию пользователя ($_rb_reason)"
      sleep 2
      reboot
      return 0
    fi
    warn "Перезагрузка отложена — если создание сервера упадёт, сделай reboot"
    info "Быстрее без ребута: rmmod amneziawg && modprobe amneziawg"
  else
    hdr "⟳  Перезагрузка"
    ok "Не требуется: модуль загружен под текущее ядро $(uname -r)"
    info "Если создание сервера всё же упадёт — reboot и повтори п.2"
  fi

  echo ""
  info "Следующий шаг: Сервер (1) → п.2 — Создать сервер"
  break
  done
}

do_gen() {
  log_info "do_gen: старт"
  command -v awg &>/dev/null || { err "awg не найден. Сначала Сервер (1) → п.1"; return 1; }
  command -v python3 &>/dev/null || { err "python3 не найден — нужен для генерации параметров"; info "Запусти Сервер (1) → п.1 или: apt-get install python3"; return 1; }

  # ── Защита: сервер уже установлен? ──
  if [[ -f "$SERVER_CONF" ]]; then
    local _current_profile
    _current_profile=$(grep -m1 '^# AWG_PROFILE=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
    [[ -z "$_current_profile" ]] && _current_profile="custom (старый сервер без маркера)"
    echo ""
    warn "Сервер AmneziaWG уже установлен."
    warn "Текущий профиль: ${W}${_current_profile}${N}"
    echo ""
    info "Для смены профиля сначала удали текущий сервер:"
    info "  • Сервер (1) → п.7 — Сбросить настройки сервера (чистая переустановка)"
    info "  • Удаление (7) → п.2 — Удалить всё (пакеты + конфиги)"
    info "После этого выбери Сервер (1) → п.2 заново и укажи нужный профиль."
    return 0
  fi

  # Ставили компоненты и не перезагрузились — awg-quick up ляжет на модуле,
  # собранном под другое ядро. Спрашиваем до генерации ключей и конфигов.
  local _rb_reason
  _rb_reason=$(awg_reboot_reason || true)
  if [[ -n "$_rb_reason" ]]; then
    echo ""
    warn "Сервер не перезагружен после установки: $_rb_reason"
    info "Обычно именно из-за этого awg0 не поднимается сразу после п.1"
    echo ""
    local _rb_now
    read_yesno _rb_now "$(echo -e "${G}  Перезагрузить сейчас (создать сервер после)? [Y/n]: ${N}")" "y"
    if [[ "$_rb_now" == "y" ]]; then
      ok "Перезагружаюсь. Заходи через минуту: awg2 → Сервер (1) → п.2"
      log_info "do_gen: reboot по согласию пользователя ($_rb_reason)"
      sleep 2
      reboot
      return 0
    fi
    warn "Продолжаю без перезагрузки — если подъём упадёт, причину назову"
  fi

  local bak_ts
  bak_ts="${SERVER_CONF}.bak.$(date +%s)"
  if [[ -f "$SERVER_CONF" ]]; then
    cp "$SERVER_CONF" "$bak_ts"
    info "Резервная копия: $bak_ts"
  fi

  choose_region
  choose_dns

  # MTU выбираем ДО мимикрии — CPS-генератору нужен актуальный MTU
  hdr "▬  MTU"
  echo "  1) 1420 — стандартный WireGuard"
  echo "  2) 1380 — баланс"
  echo "  3) 1360 — провайдеры с PPPoE overhead"
  echo "  4) 1340 — мобильный 4G/LTE"
  echo "  5) 1320 — безопасно для AWG + CPS, рекомендуется"
  echo "  6) 1280 — максимальная совместимость"
  echo "  7) 1500 — Ethernet без tunnel overhead"
  echo "  8) Вручную"
  MTU=""
  local MTU_CHOICE
  read_choice MTU_CHOICE "$(echo -e "${C}  Выбор [1-8] (Enter = 1320): ${N}")" 1 8 5
  case $MTU_CHOICE in
    1) MTU=1420 ;;
    2) MTU=1380 ;;
    3) MTU=1360 ;;
    4) MTU=1340 ;;
    5) MTU=1320 ;;
    6) MTU=1280 ;;
    7) MTU=1500 ;;
    8)
      while true; do
        read -rp "  MTU (1280-1500): " MTU
        if [[ "$MTU" =~ ^[0-9]+$ ]] && (( MTU >= 1280 && MTU <= 1500 )); then
          break
        fi
        warn "Некорректный MTU. Должно быть число 1280-1500"
      done
      ;;
  esac

  choose_awg_profile || return 1
  choose_awg_proto   || return 1

  hdr "»  IP подсеть сервера"
  echo "  1) Случайная подсеть из пула 10.[10-55].[1-254].0/24 (рекомендуется)"
  echo "  2) 10.100.0.0/24"
  echo "  3) 10.101.0.0/24"
  echo "  4) 10.102.0.0/24"
  echo "  5) 10.44.5.0/24"
  echo "  6) Вручную"
  local CLIENT_ADDR="" SERVER_ADDR="" CLIENT_NET=""
  local ADDR_CHOICE
  read_choice ADDR_CHOICE "$(echo -e "${C}  Выбор [1-6] (Enter = 1 случайная): ${N}")" 1 6 1
  case $ADDR_CHOICE in
    1)
      local rnd_octet2 rnd_octet3
      rnd_octet2=$(rand_range 10 55)
      rnd_octet3=$(rand_range 1 254)
      CLIENT_ADDR="10.${rnd_octet2}.${rnd_octet3}.2/32"
      SERVER_ADDR="10.${rnd_octet2}.${rnd_octet3}.1/24"
      CLIENT_NET="10.${rnd_octet2}.${rnd_octet3}.0/24"
      ok "Случайная подсеть: $CLIENT_NET"
      ;;
    2) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
    3) CLIENT_ADDR="10.101.0.2/32"; SERVER_ADDR="10.101.0.1/24"; CLIENT_NET="10.101.0.0/24" ;;
    4) CLIENT_ADDR="10.102.0.2/32"; SERVER_ADDR="10.102.0.1/24"; CLIENT_NET="10.102.0.0/24" ;;
    5) CLIENT_ADDR="10.44.5.2/32"; SERVER_ADDR="10.44.5.1/24"; CLIENT_NET="10.44.5.0/24" ;;
    6)
      local _ip_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'
      while true; do
        read -rp "  IP клиента (X.X.X.X/32): " CLIENT_ADDR
        [[ "$CLIENT_ADDR" =~ $_ip_re ]] && break
        warn "Формат: 10.1.2.3/32"
      done
      while true; do
        read -rp "  IP сервера (X.X.X.X/24): " SERVER_ADDR
        [[ "$SERVER_ADDR" =~ $_ip_re ]] && break
        warn "Формат: 10.1.2.1/24"
      done
      while true; do
        read -rp "  Подсеть NAT (X.X.X.0/24): " CLIENT_NET
        [[ "$CLIENT_NET" =~ $_ip_re ]] && break
        warn "Формат: 10.1.2.0/24"
      done
      ;;
  esac

  hdr "»  Порт сервера"
  while true; do
    read -rp "$(echo -e "${C}  Порт [Enter = случайный / 51820 = стандартный / свой]: ${N}")" PORT
    if [[ -z "${PORT:-}" || "${PORT:-}" == "r" || "${PORT:-}" == "R" ]]; then
      PORT=$(rand_range 30001 65535)
      ok "случайный порт: $PORT"
      break
    fi
    if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )); then
      break
    fi
    warn "Порт должен быть числом 1024-65535. Попробуй ещё раз."
  done

  # Домен вместо IP в Endpoint — спрашиваем здесь, рядом с портом: вместе они
  # и составляют Endpoint клиентского конфига.
  ask_endpoint_domain

  local obf_label
  case ${OBF_LEVEL:-1} in
    1) obf_label="Базовый (без CPS)" ;;
    2) obf_label="+I1 (мимикрия)" ;;
    3) obf_label="+I1-I5 (полный CPS)" ;;
    *) obf_label="Базовый" ;;
  esac

  hdr "≡  Параметры настройки"
  echo -e "  ${W}Версия     : ${N}AWG ${AWG_PROTO:-2.0}"
  echo -e "  ${W}Обфускация : ${N}$obf_label"
  echo -e "  ${W}DNS        : ${N}$CLIENT_DNS"
  echo -e "  ${W}Мимикрия   : ${N}${MIMICRY_PROFILE:-none}"
  echo -e "  ${W}I1         : ${N}${I1:+получен (${#I1} симв. ≈ $(( (${#I1} - 8) / 2 )) байт пакета)}"
  echo -e "  ${W}Клиент     : ${N}$CLIENT_ADDR"
  echo -e "  ${W}Сервер     : ${N}$SERVER_ADDR"
  echo -e "  ${W}MTU        : ${N}$MTU"
  echo -e "  ${W}Порт       : ${N}$PORT"
  echo -e "  ${W}Endpoint   : ${N}${ENDPOINT_DOMAIN:-IP сервера}:$PORT"
  echo ""
  read_yesno CONFIRM "$(echo -e "${C}  Продолжить? [Y/n]: ${N}")" "y"
  [[ "$CONFIRM" == "y" ]] || { warn "Отменено."; return 0; }

  local srv_priv srv_pub cli_priv cli_pub psk srv_ip iface

  # Генерация ключей с диагностикой
  info "Генерация ключей..."
  srv_priv=$(awg genkey 2>/dev/null) || { err "awg genkey failed — awg не работает?"; return 1; }
  srv_pub=$(echo "$srv_priv" | awg pubkey 2>/dev/null) || { err "awg pubkey failed"; return 1; }
  cli_priv=$(awg genkey 2>/dev/null) || { err "awg genkey failed (client)"; return 1; }
  cli_pub=$(echo "$cli_priv" | awg pubkey 2>/dev/null) || { err "awg pubkey failed (client)"; return 1; }
  # Имя первого клиента: рандом 5 строчных букв + "_" + 2 цифры (напр. xkqve_73)
  FIRST_CLIENT_NAME="$(tr -dc 'a-z' </dev/urandom | head -c5)_$(tr -dc '0-9' </dev/urandom | head -c2)"
  [[ "$FIRST_CLIENT_NAME" =~ ^[a-z]{5}_[0-9]{2}$ ]] || FIRST_CLIENT_NAME="client1"
  psk=$(awg genpsk 2>/dev/null) || { err "awg genpsk failed"; return 1; }

  info "Определение внешнего IP..."
  srv_ip=$(get_public_ip 2>/dev/null || echo "")
  if [[ -z "$srv_ip" ]]; then
    err "Не удалось получить внешний IP (нет интернета?)"
    while true; do
      read -rp "$(echo -e "${C}  Введи IP сервера вручную: ${N}")" srv_ip
      if [[ -n "$srv_ip" ]]; then
        # Базовая валидация — IPv4 или домен
        if [[ "$srv_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$srv_ip" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
          break
        fi
        warn "Некорректный IP/домен. Пример: 1.2.3.4 или example.com"
      else
        warn "IP обязателен. Введи или нажми Ctrl+C для отмены."
      fi
    done
  fi
  ok "IP сервера: $srv_ip"

  info "Определение сетевого интерфейса..."
  iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}' || echo "")
  if [[ -z "$iface" ]]; then
    err "Не удалось определить default интерфейс"
    iface=$(ip link 2>/dev/null | awk -F: '/^[0-9]+: e/{print $2; exit}' | tr -d ' ' || echo "eth0")
    warn "Использую интерфейс по умолчанию: $iface"
  fi
  ok "Интерфейс: $iface"

  info "Генерация параметров AWG..."
  AWG_PARAMS_LINES=""
  gen_awg_params || { err "gen_awg_params failed"; return 1; }
  [[ -z "$AWG_PARAMS_LINES" ]] && { err "AWG_PARAMS_LINES пустой"; return 1; }

  # sysctl может падать в LXC/OpenVZ — не критично, но предупреждаем
  if ! sysctl -w net.ipv4.ip_forward=1 -q 2>/dev/null; then
    warn "sysctl -w не сработал (LXC/OpenVZ?) — пробуем /proc"
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || \
      warn "IP forwarding не включился — возможно, нужны права хоста"
  fi

  mkdir -p /etc/amnezia/amneziawg

  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  {
    echo "# AWG_PROFILE=${AWG_PROFILE:-pro}"
    echo "# AmneziaWG Toolza — AWG ${AWG_PROTO:-2.0} server config"
    echo "# Region: ${SERVER_REGION:-world}"
    echo "# AWG_PROTO=${AWG_PROTO:-2.0}"
    # Сколько CPS-пакетов получает клиент (1 = без I1-I5, 2 = только I1,
    # 3 = полный I1-I5) и какой профиль мимикрии. Сами I1-I5 в серверный
    # конфиг не пишутся — они клиентские, поэтому без этих маркеров бот не
    # знает, что выдавать, и раньше давал один I1 на сервере с полным CPS.
    echo "# AWG_OBF_LEVEL=${OBF_LEVEL:-1}"
    echo "# AWG_MIMICRY=${MIMICRY_PROFILE:-none}"
    # Домен для Endpoint: строку пишем только если он задан, иначе клиентам
    # уходит IP (см. endpoint_host)
    [[ -n "${ENDPOINT_DOMAIN:-}" ]] && echo "# AWG_ENDPOINT=${ENDPOINT_DOMAIN}"
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = $SERVER_ADDR"
    echo "ListenPort = $PORT"
    echo "MTU = $MTU"
    echo -e "$AWG_PARAMS_LINES"
    # I1-I5 НЕ записываем в серверный конфиг — это клиентские параметры.
    # Сервер не нуждается в CPS signature packets.
    echo ""
    echo "PostUp   = ip link set dev awg0 mtu $MTU; echo 1 > /proc/sys/net/ipv4/ip_forward; iptables -t nat -C POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE; iptables -C FORWARD -i awg0 -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -o awg0 -j ACCEPT"
    echo "PostDown = iptables -t nat -D POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true"
    echo ""
    echo "[Peer]"
    echo "# $FIRST_CLIENT_NAME"
    echo "PublicKey = $cli_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $CLIENT_ADDR"
  } > "$SERVER_CONF"
  chmod 600 "$SERVER_CONF"

  {
    echo "[Interface]"
    echo "PrivateKey = $cli_priv"
    echo "Address = $CLIENT_ADDR"
    echo "DNS = $CLIENT_DNS"
    echo "MTU = $MTU"
    echo -e "$AWG_PARAMS_LINES"
    if [[ -n "$I1" ]]; then
      echo "I1 = $I1"
      [[ -n "$I2" ]] && echo "I2 = $I2" || true
      [[ -n "$I3" ]] && echo "I3 = $I3" || true
      [[ -n "$I4" ]] && echo "I4 = $I4" || true
      [[ -n "$I5" ]] && echo "I5 = $I5" || true
    fi
    echo ""
    echo "[Peer]"
    echo "PublicKey = $srv_pub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $(endpoint_host "$srv_ip"):$PORT"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = $(awg_keepalive_value)"
  } > "/root/${FIRST_CLIENT_NAME}_awg2.conf"
  chmod 600 "/root/${FIRST_CLIENT_NAME}_awg2.conf"

  if awg_up_diag "$SERVER_CONF"; then
    log_info "do_gen: awg-quick up успешно"
  else
    log_err "do_gen: awg-quick up провалился"
    warn "awg-quick up не удался"
    if [[ -n "$bak_ts" && -f "$bak_ts" ]]; then
      echo -e "  ${Y}  • Предыдущий конфиг сохранён: $bak_ts${N}"
      read_yesno RESTORE_BAK "$(echo -e "${C}  Восстановить предыдущий конфиг? [y/N]: ${N}")" "n"
      if [[ "$RESTORE_BAK" == "y" ]]; then
        cp "$bak_ts" "$SERVER_CONF"
        awg-quick up "$SERVER_CONF" 2>/dev/null || true
        ok "Конфиг восстановлен"
      fi
    fi
    return 1
  fi

  if command -v ufw &>/dev/null; then
    read_yesno OPEN_UFW "$(echo -e "${C}  Открыть порт $PORT/udp в UFW? [Y/n]: ${N}")" "y"
    if [[ "$OPEN_UFW" == "y" ]]; then
      ufw allow "${PORT}/udp" comment "AmneziaWG" || true
      ok "Порт ${PORT}/udp открыт в файрволе"
    fi
  fi

  # Раздача конфига
  _share_config "/root/${FIRST_CLIENT_NAME}_awg2.conf"

  echo ""
  success_box "■  Сервер создан успешно"
  echo -e "${W}  Версия : ${N}AWG ${AWG_PROTO:-2.0}"
  echo -e "${W}  Профиль: ${N}${MIMICRY_PROFILE:-none}"
  echo -e "${W}  Сервер : ${N}$SERVER_CONF"
  echo -e "${W}  Клиент : ${N}/root/${FIRST_CLIENT_NAME}_awg2.conf"
  echo -e "${W}  IP     : ${N}$srv_ip:$PORT"
  echo -e "${W}  Iface  : ${N}$iface"

  _setup_autostart
  _warn_bot_needs_update
}


_setup_autostart() {
  local unit_dir="/etc/systemd/system/awg-quick@awg0.service.d"
  mkdir -p "$unit_dir"
  cat > "${unit_dir}/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/awg-quick up awg0
EOF
  systemctl daemon-reload
  systemctl enable awg-quick@awg0 2>/dev/null && ok "Автозапуск awg0 включён" || \
    warn "Не удалось включить автозапуск awg0"

  # Автозагрузка модуля ядра при старте системы
  if echo "amneziawg" > /etc/modules-load.d/amneziawg.conf 2>/dev/null; then
    ok "Автозагрузка модуля amneziawg настроена"
  else
    warn "Не удалось настроить автозагрузку модуля"
  fi
}

# Бот выдаёт клиентов сам, копируя параметры из awg0.conf своим списком ключей.
# Версия бота до 0.7.3 про поля 3.0 не знает: выданный ею конфиг молча окажется
# 2.0 и к серверу 3.0 не подключится — без ошибки, клиент просто не встанет.
# Скрипт и бот обновляются раздельно, так что рассинхрон — обычное дело.
#
# Проверяем не факт установки, а реальную поддержку: у обновлённого бота
# предупреждать не о чем, а лишний алярм после каждого создания сервера злит.
_warn_bot_needs_update() {
  local proto="${AWG_PROTO:-2.0}" need_key
  case "$proto" in
    3.0) need_key="HeaderProtectionKey" ;;
    3.1) need_key="RandomTrailers" ;;
    *)   return 0 ;;
  esac
  [[ -f "/usr/local/bin/awg-bot.py" ]] || return 0   # маркер установленного бота

  local bot_core="/opt/awg-bot/awgbot/core.py"
  [[ -f "$bot_core" ]] || return 0
  grep -q "$need_key" "$bot_core" 2>/dev/null && return 0

  echo ""
  warn "Telegram-бот установлен, но его версия не знает про AWG ${proto}."
  warn "Клиенты, выданные ботом, получат неполный конфиг и НЕ подключатся."
  info "Обнови: главное меню → 6) Telegram-бот → Обновить"
}

# Вспомогательная функция: выводит нумерованный список клиентов из SERVER_CONF
# Заполняет глобальные массивы:
#   MGMT_NAMES[]   — имена клиентов (из # comment или "безымянный")
#   MGMT_PUBKEYS[] — PublicKey каждого
#   MGMT_IPS[]     — AllowedIPs (VPN IP)
# Возвращает 0 при успехе, 1 если клиентов нет
_mgmt_scan_clients() {
  MGMT_NAMES=()
  MGMT_PUBKEYS=()
  MGMT_IPS=()
  local in_peer=0 cur_name="" cur_pk="" cur_ip=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[Peer\] ]]; then
      # Сохраняем предыдущего если был
      if [[ $in_peer -eq 1 && -n "$cur_pk" ]]; then
        MGMT_NAMES+=("${cur_name:-безымянный}")
        MGMT_PUBKEYS+=("$cur_pk")
        MGMT_IPS+=("${cur_ip:-?}")
      fi
      in_peer=1
      cur_name=""; cur_pk=""; cur_ip=""
    elif [[ $in_peer -eq 1 ]]; then
      if [[ "$line" =~ ^#[[:space:]](.+) ]]; then
        local _cmt="${BASH_REMATCH[1]}"
        # Пропускаем служебные метки expires= и orig_ips=
        if [[ "$_cmt" != expires=* && "$_cmt" != orig_ips=* ]]; then
          cur_name="$_cmt"
        fi
      elif [[ "$line" =~ ^PublicKey[[:space:]]=[[:space:]](.+) ]]; then
        cur_pk="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^AllowedIPs[[:space:]]=[[:space:]](.+) ]]; then
        cur_ip="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$SERVER_CONF"
  # Последний клиент
  if [[ $in_peer -eq 1 && -n "$cur_pk" ]]; then
    MGMT_NAMES+=("${cur_name:-безымянный}")
    MGMT_PUBKEYS+=("$cur_pk")
    MGMT_IPS+=("${cur_ip:-?}")
  fi
  [[ ${#MGMT_PUBKEYS[@]} -gt 0 ]]
}

# Выводит список клиентов с нумерацией
_mgmt_print_list() {
  local i
  echo ""
  echo -e "${C}  Клиентов: ${W}${#MGMT_PUBKEYS[@]}${N}"
  for i in "${!MGMT_PUBKEYS[@]}"; do
    printf "  ${G}%d)${N} %-26s ${C}%s${N}\n" "$((i+1))" "${MGMT_NAMES[$i]}" "${MGMT_IPS[$i]}"
  done
  echo ""
}

do_manage_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { warn "Конфиг сервера не найден. Сначала Сервер (1) → п.2"; return 0; }
  command -v awg &>/dev/null || { warn "awg не найден"; return 0; }

  while true; do
    echo ""
    hdr "⚙  Управление клиентами"
    echo -e "  ${G}1)${N} Добавить клиента"
    echo -e "  ${G}2)${N} Переименовать клиента"
    echo -e "  ${R}3)${N} Удалить клиента"
    echo -e "  ${C}4)${N} Показать QR клиента"
    echo -e "  ${C}5)${N} Показать конфиг клиента (текст)"
    echo -e "  ${G}6)${N} Создать N клиентов (массово)"
    echo -e "  ${C}7)${N} Срок действия клиента"
    echo -e "  ${C}8)${N} Активность клиентов"
    echo -e "  ${C}9)${N} Экспорт конфигов (zip)"
    echo -e "  ${C}10)${N} Сменить мимикрию у клиента ${D}— если конфиг не проходит у провайдера${N}"
    echo -e "  ${W}0)${N} Назад в главное меню"
    echo ""
    local MGMT_CHOICE
    read_choice MGMT_CHOICE "$(echo -e "${C}  Выбор [0-10]: ${N}")" 0 10 "0"
    case "${MGMT_CHOICE:-}" in
      1) do_add_client || true ;;
      2) do_rename_client || true ;;
      3) do_delete_client || true ;;
      4) do_show_qr || true ;;
      5) do_show_config || true ;;
      6) do_bulk_add_clients || true ;;
      7) do_expire_menu || true ;;
      8) do_list_clients || true ;;
      9) do_export_configs || true ;;
      10) do_change_client_mimicry || true ;;
      0) return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" _ || return 0
  done
}

# ── Показать конфиг клиента (текст) ──
do_show_config() {
  # found_files, а не found: в других функциях found — скалярный счётчик,
  # и от одноимённого массива shellcheck путает области видимости.
  local found_files=()
  while IFS= read -r -d '' f; do
    found_files+=("$f")
  done < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  [[ ${#found_files[@]} -eq 0 ]] && { err "Конфиги не найдены в /root/"; return 1; }

  local unique
  mapfile -t unique < <(printf "%s\n" "${found_files[@]}" | sort -u)

  hdr "≡  Выбери конфиг"
  local i=0
  for f in "${unique[@]}"; do
    i=$((i+1))
    echo "  $i) $(basename "$f")"
  done

  local SEL
  local prompt="  Выбор [1-$i] (Enter = 1, 0 = отмена): "
  [[ $i -eq 1 ]] && prompt="  Выбор [1] (Enter = 1, 0 = отмена): "
  read_choice SEL "$(echo -e "${C}${prompt}${N}")" 0 "$i" "1"
  [[ "$SEL" == "0" ]] && { info "Отменено"; return 0; }

  local chosen="${unique[$((SEL - 1))]}"
  [[ -f "$chosen" ]] || { warn "Файл не найден"; return 0; }

  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo -e "${W}  ≡ Конфиг: $(basename "$chosen")${N}"
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo ""
  cat "$chosen"
  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo -e "${D}  Скопируй текст выше или: scp root@$(get_public_ip 2>/dev/null):$chosen .${N}"
}

# ── Переименование клиента ──
do_rename_client() {
  _mgmt_scan_clients || { warn "Нет клиентов для переименования"; return 0; }
  hdr "✎  Переименовать клиента"
  _mgmt_print_list

  local SEL
  read_choice SEL "$(echo -e "${C}  Номер клиента [1-${#MGMT_PUBKEYS[@]}] (0 = отмена): ${N}")" 0 "${#MGMT_PUBKEYS[@]}" "0"
  [[ "$SEL" == "0" ]] && { info "Отменено"; return 0; }

  local idx=$((SEL - 1))
  local old_name="${MGMT_NAMES[$idx]}"
  local pk="${MGMT_PUBKEYS[$idx]}"

  echo -e "${C}  Текущее имя: ${W}$old_name${N}"
  local new_name
  read -rp "$(echo -e "${C}  Новое имя: ${N}")" new_name
  if [[ -z "$new_name" ]]; then
    warn "Имя не может быть пустым"; return 0
  fi
  if ! [[ "$new_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    warn "Имя содержит недопустимые символы (только A-Z a-z 0-9 _ -)"; return 0
  fi
  if [[ "$new_name" == "$old_name" ]]; then
    info "Имя не изменилось"; return 0
  fi

  # Бекап + обновление SERVER_CONF
  local bak
  bak="${SERVER_CONF}.pre_rename.$(date +%s)"
  cp "$SERVER_CONF" "$bak"

  # Ищем блок [Peer] с нужным PublicKey и обновляем комментарий
  # Заменяем ТОЛЬКО комментарий-имя (первый # без = после [Peer]),
  # служебные комментарии (# expires=, # orig_ips=) НЕ трогаем.
  local tmp_conf
  tmp_conf=$(mktemp)
  awk -v pk="$pk" -v new_name="$new_name" '
    function flush_peer() {
      if (in_peer && peer_buf != "") {
        if (match_pk) {
          if (name_replaced) {
            printf "%s", peer_buf
          } else {
            # Имя-комментария не было — вставляем сразу после [Peer]
            sub(/\[Peer\][[:space:]]*\n/, "[Peer]\n# " new_name "\n", peer_buf)
            printf "%s", peer_buf
          }
        } else {
          printf "%s", peer_buf
        }
      }
    }
    BEGIN { in_peer=0; peer_buf=""; match_pk=0; name_replaced=0 }
    /^\[Peer\]/ {
      flush_peer()
      in_peer=1
      peer_buf=$0 "\n"
      match_pk=0
      name_replaced=0
      next
    }
    in_peer {
      # Если эта строка — комментарий-имя (# something без знака =), и мы ещё не заменили
      if (!name_replaced && match_pk && $0 ~ /^#[[:space:]]+[^=]+$/) {
        peer_buf = peer_buf "# " new_name "\n"
        name_replaced=1
        next
      }
      peer_buf = peer_buf $0 "\n"
      if ($0 ~ /^PublicKey[[:space:]]*=[[:space:]]*/) {
        line_pk=$0
        sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", line_pk)
        gsub(/[[:space:]]/, "", line_pk)
        tgt=pk
        gsub(/[[:space:]]/, "", tgt)
        if (line_pk == tgt) {
          match_pk=1
          # Ретроактивно ищем комментарий-имя в уже накопленном peer_buf
          if (!name_replaced) {
            n = split(peer_buf, lines, "\n")
            new_buf=""
            for (i=1; i<=n; i++) {
              if (!name_replaced && lines[i] ~ /^#[[:space:]]+[^=]+$/) {
                new_buf = new_buf "# " new_name (i<n ? "\n" : "")
                name_replaced=1
              } else {
                new_buf = new_buf lines[i] (i<n ? "\n" : "")
              }
            }
            peer_buf = new_buf
          }
        }
      }
      next
    }
    { print }
    END { flush_peer() }
  ' "$SERVER_CONF" > "$tmp_conf"

  if [[ ! -s "$tmp_conf" ]]; then
    err "awk не смог обработать конфиг, восстанавливаю из бекапа"
    mv "$bak" "$SERVER_CONF"
    rm -f "$tmp_conf"
    return 1
  fi

  mv "$tmp_conf" "$SERVER_CONF"
  chmod 600 "$SERVER_CONF"

  # Переименование файла клиента если он существует
  local old_file="/root/${old_name}_awg2.conf"
  local new_file="/root/${new_name}_awg2.conf"
  if [[ -f "$old_file" && "$old_name" != "безымянный" ]]; then
    mv "$old_file" "$new_file"
    ok "Файл переименован: $(basename "$old_file") → $(basename "$new_file")"
  fi

  ok "Клиент переименован: $old_name → $new_name"
  info "Бекап конфига: $bak"
}

# ── Удаление клиента ──
# ─────────────────────────────────────────────────────────────
# _delete_one_peer — удаляет ОДНОГО пира по pubkey+name.
#   Делает: awg remove (runtime) + вырезание [Peer] из SERVER_CONF (awk)
#           + удаление файла клиента + чистка expire-флага.
#   НЕ делает: backup, _apply_config, _warp_sync_peers — это задача вызывающего
#              (чтобы при массовом удалении делать их один раз).
#   Аргументы: $1=name  $2=pubkey  $3=ip(для лога)
#   Возврат: 0 — ок, 1 — awk-ошибка (конфиг не тронут)
# ─────────────────────────────────────────────────────────────
_delete_one_peer() {
  local del_name="$1" del_pk="$2" del_ip="${3:-?}"

  # Удаляем peer из runtime
  awg set awg0 peer "$del_pk" remove 2>/dev/null || warn "[$del_name] не удалось удалить peer из runtime"

  # Вырезаем блок [Peer] из SERVER_CONF через awk (буферизуем блок, печатаем если PublicKey != del_pk)
  local tmp_conf
  tmp_conf=$(mktemp)
  awk -v pk="$del_pk" '
    BEGIN { in_peer=0; peer_buf=""; match_pk=0 }
    /^\[Peer\]/ {
      if (in_peer && !match_pk) printf "%s", peer_buf
      in_peer=1
      peer_buf=$0 "\n"
      match_pk=0
      next
    }
    in_peer {
      peer_buf = peer_buf $0 "\n"
      if ($0 ~ /^PublicKey[[:space:]]*=[[:space:]]*/) {
        line_pk=$0
        sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", line_pk)
        gsub(/[[:space:]]/, "", line_pk)
        tgt=pk
        gsub(/[[:space:]]/, "", tgt)
        if (line_pk == tgt) match_pk=1
      }
      next
    }
    { print }
    END {
      if (in_peer && !match_pk) printf "%s", peer_buf
    }
  ' "$SERVER_CONF" > "$tmp_conf"

  if [[ ! -s "$tmp_conf" ]]; then
    err "[$del_name] awk не смог обработать конфиг — пропуск (конфиг не тронут)"
    rm -f "$tmp_conf"
    return 1
  fi

  mv "$tmp_conf" "$SERVER_CONF"
  chmod 600 "$SERVER_CONF"

  # Удаляем файл клиента
  local del_file="/root/${del_name}_awg2.conf"
  if [[ -f "$del_file" && "$del_name" != "безымянный" ]]; then
    rm -f "$del_file"
  fi

  # Чистим expire-warn флаг если был
  if [[ -d "$EXPIRE_STATE_DIR" ]]; then
    local safe_pk
    safe_pk=$(echo "$del_pk" | tr -c 'A-Za-z0-9' '_')
    rm -f "${EXPIRE_STATE_DIR}/warn1h_${safe_pk}" 2>/dev/null || true
  fi

  ok "Удалён: $del_name ($del_ip)"
  return 0
}

do_delete_client() {
  _mgmt_scan_clients || { warn "Нет клиентов для удаления"; return 0; }
  hdr "🗑  Удалить клиента"
  _mgmt_print_list

  # ── Режим удаления ──
  echo -e "  ${C}1)${N} По номеру (один клиент)"
  echo -e "  ${C}2)${N} Список имён через запятую (массово)"
  local DEL_MODE
  read_choice DEL_MODE "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" 1 2 1

  # Индексы клиентов к удалению (0-based в MGMT_*)
  local _del_idx=()

  if (( DEL_MODE == 2 )); then
    # ── Массово: список имён через запятую ──
    local _raw
    read -rp "$(echo -e "${C}  Имена через запятую: ${N}")" _raw
    [[ -z "$_raw" ]] && { info "Отменено"; return 0; }

    local _oldifs="$IFS"
    IFS=','
    # shellcheck disable=SC2206
    local _arr=($_raw)
    IFS="$_oldifs"

    local _part _name _i _found _seen=" " _missing=()
    for _part in "${_arr[@]}"; do
      # trim
      _name="${_part#"${_part%%[![:space:]]*}"}"
      _name="${_name%"${_name##*[![:space:]]}"}"
      [[ -z "$_name" ]] && continue
      # дубль в вводе
      [[ "$_seen" == *" ${_name} "* ]] && continue
      _seen+="${_name} "
      # ищем по имени среди MGMT_NAMES
      _found=-1
      for _i in "${!MGMT_NAMES[@]}"; do
        if [[ "${MGMT_NAMES[$_i]}" == "$_name" ]]; then _found=$_i; break; fi
      done
      if (( _found >= 0 )); then
        _del_idx+=("$_found")
      else
        _missing+=("$_name")
      fi
    done

    if (( ${#_missing[@]} > 0 )); then
      warn "Не найдены (пропущены): ${_missing[*]}"
    fi
    if (( ${#_del_idx[@]} == 0 )); then
      warn "Ни одно имя не совпало с существующими клиентами — возврат"
      return 0
    fi

    echo ""
    echo -e "${Y}  ▲ Будут удалены (${#_del_idx[@]}):${N}"
    local _x
    for _x in "${_del_idx[@]}"; do
      echo -e "     • ${W}${MGMT_NAMES[$_x]}${N} ${D}(${MGMT_IPS[$_x]})${N}"
    done
  else
    # ── Один по номеру ──
    local SEL
    read_choice SEL "$(echo -e "${C}  Номер клиента [1-${#MGMT_PUBKEYS[@]}] (0 = отмена): ${N}")" 0 "${#MGMT_PUBKEYS[@]}" "0"
    [[ "$SEL" == "0" ]] && { info "Отменено"; return 0; }
    local idx=$((SEL - 1))
    _del_idx=("$idx")

    echo ""
    echo -e "${Y}  ▲ Будет удалён клиент:${N}"
    echo -e "     Имя: ${W}${MGMT_NAMES[$idx]}${N}"
    echo -e "     IP : ${W}${MGMT_IPS[$idx]}${N}"
    echo -e "     Ключ: ${D}${MGMT_PUBKEYS[$idx]:0:20}...${N}"
  fi

  echo ""
  read_confirm "$(echo -e "${R}  Подтвердить удаление? (введи yes): ${N}")" || \
    { info "Отменено"; return 0; }

  # Один общий бекап перед серией удалений
  local bak
  bak="${SERVER_CONF}.pre_delete.$(date +%s)"
  cp "$SERVER_CONF" "$bak"

  # Удаляем по очереди
  local _x _deleted=0 _failed=0
  for _x in "${_del_idx[@]}"; do
    if _delete_one_peer "${MGMT_NAMES[$_x]}" "${MGMT_PUBKEYS[$_x]}" "${MGMT_IPS[$_x]}"; then
      _deleted=$((_deleted+1))
    else
      _failed=$((_failed+1))
    fi
  done

  echo ""
  ok "Удалено: ${_deleted}$( ((_failed>0)) && echo ", ошибок: ${_failed}")"
  info "Бекап конфига: $bak"

  # Один sync в конце — убираем удалённых из Warp
  if declare -f _warp_sync_peers >/dev/null 2>&1; then
    _warp_sync_peers 2>/dev/null || true
  fi
}

do_add_client() {
  [[ ! -f "$SERVER_CONF" ]] && { warn "Конфиг сервера не найден. Сначала Сервер (1) → п.2"; return 0; }
  command -v awg &>/dev/null || { warn "awg не найден — возврат в главное меню"; return 0; }

  local server_net base_ip client_addr
  server_net=$(grep "^Address" "$SERVER_CONF" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' | head -1 || true)
  base_ip=$(echo "$server_net" | cut -d. -f1-3)
  client_addr=$(find_free_ip "$base_ip") || { warn "Подсеть заполнена — возврат в главное меню"; return 0; }

  info "Следующий свободный IP: $client_addr"

  local client_name
  read -rp "$(echo -e "${C}  Имя клиента (phone, laptop...): ${N}")" client_name
  if [[ -z "$client_name" ]]; then
    warn "Имя не может быть пустым — возврат в главное меню"
    return 0
  fi
  # Валидация: только буквы/цифры/дефис/подчёркивание
  if ! [[ "$client_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    warn "Имя содержит недопустимые символы (только A-Z, a-z, 0-9, _, -) — возврат"
    return 0
  fi
  # Запрет дублей: имя уже есть среди клиентов сервера (комментарий "# имя")
  if grep -qx "# ${client_name}" "$SERVER_CONF" 2>/dev/null; then
    warn "Клиент с именем '${client_name}' уже существует — выбери другое имя"
    return 0
  fi

  local client_file="/root/${client_name}_awg2.conf"
  if [[ -f "$client_file" ]]; then warn "Файл $client_file уже существует — будет перезаписан"; fi

  read_yesno CONFIRM_IP "$(echo -e "${C}  Использовать IP $client_addr? [Y/n]: ${N}")" "y"
  if [[ "$CONFIRM_IP" != "y" ]]; then
    # Ручной ввод IP с валидацией формата, подсети, занятости и адреса сервера
    local _srv_oct=""
    local _srv_addr
    _srv_addr=$(grep "^Address" "$SERVER_CONF" | awk -F"=" "{print \$2}" | tr -d " " | head -1 || true)
    _srv_oct=$(echo "$_srv_addr" | cut -d/ -f1 | awk -F. "{print \$4}" || true)
    local _manual=""
    while true; do
      read -rp "  IP вручную (пример: ${base_ip}.5/32): " _manual
      [[ -z "$_manual" ]] && { warn "IP не введён — возврат"; return 0; }
      # Дописываем /32 если пользователь ввёл без маски
      [[ "$_manual" != */* ]] && _manual="${_manual}/32"
      # Формат: X.X.X.X/32
      if ! [[ "$_manual" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
        warn "Неверный формат. Нужно вида ${base_ip}.5/32 — попробуй ещё раз"
        continue
      fi
      local _ip_only _o1 _o2 _o3 _o4
      _ip_only="${_manual%/32}"
      IFS=. read -r _o1 _o2 _o3 _o4 <<< "$_ip_only"
      # Все октеты 0-255
      if (( _o1>255 || _o2>255 || _o3>255 || _o4>255 )); then
        warn "Октеты должны быть 0-255 — попробуй ещё раз"; continue
      fi
      # Должен попадать в подсеть base_ip (первые три октета)
      if [[ "${_o1}.${_o2}.${_o3}" != "$base_ip" ]]; then
        warn "IP вне подсети сервера (${base_ip}.x) — попробуй ещё раз"; continue
      fi
      # Не .0, не .1 (шлюз/сеть), не .255 (broadcast)
      if (( _o4<2 || _o4>254 )); then
        warn "Последний октет должен быть 2-254 — попробуй ещё раз"; continue
      fi
      # Не адрес сервера
      if [[ -n "$_srv_oct" && "$_o4" == "$_srv_oct" ]]; then
        warn "Этот IP занят сервером — попробуй другой"; continue
      fi
      # Не занят другим клиентом
      if grep -qF "$_manual" "$SERVER_CONF" 2>/dev/null; then
        warn "IP $_manual уже используется другим клиентом — попробуй другой"; continue
      fi
      client_addr="$_manual"
      break
    done
  fi

  choose_dns

  # Версию берём из маркера в конфиге сервера, а не печатаем константу:
  # раньше здесь всегда было «AWG 2.0», независимо от того, на чём сервер.
  local _srv_proto
  _srv_proto=$(grep -m1 '^# AWG_PROTO=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  info "Версия сервера: AWG ${_srv_proto:-2.0}"

  # MTU: по умолчанию из конфига сервера, но даём возможность override
  local srv_mtu
  srv_mtu=$(grep "^MTU = " "$SERVER_CONF" | awk -F'= ' '{print $2}' | head -1 || true)
  srv_mtu=${srv_mtu:-1320}
  echo ""
  hdr "▬  MTU для клиента"
  echo "  1) $srv_mtu — как у сервера (рекомендуется)"
  echo "  2) 1420"
  echo "  3) 1380"
  echo "  4) 1360 (PPPoE)"
  echo "  5) 1340 (мобильный)"
  echo "  6) 1320"
  echo "  7) 1280 (макс. совместимость)"
  echo "  8) Вручную"
  local MTU_SEL
  read_choice MTU_SEL "$(echo -e "${C}  Выбор [1-8] (Enter = 1): ${N}")" 1 8 1
  case $MTU_SEL in
    1) MTU="$srv_mtu" ;;
    2) MTU=1420 ;;
    3) MTU=1380 ;;
    4) MTU=1360 ;;
    5) MTU=1340 ;;
    6) MTU=1320 ;;
    7) MTU=1280 ;;
    8)
      while true; do
        read -rp "  MTU (1280-1500): " MTU
        if [[ "$MTU" =~ ^[0-9]+$ ]] && (( MTU >= 1280 && MTU <= 1500 )); then break; fi
        warn "Некорректный MTU. Нужно число 1280-1500"
      done
      ;;
  esac

  local i1_line="" i2_line="" i3_line="" i4_line="" i5_line=""

  # Цепочка I1-I5 — клиентская: у каждого устройства она своя, поэтому
  # спрашиваем на каждого клиента, а не один раз на сервер.
  choose_target_client

  # Читаем профиль сервера — определяет поведение для клиентского I1
  local _srv_profile
  _srv_profile=$(grep -m1 '^# AWG_PROFILE=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  _srv_profile="${_srv_profile:-pro}"

  # Клиент, который цепочку не читает, делает профиль сервера неважным:
  # генерировать I1-I5 не для кого.
  if ! _target_client_reads_cps; then
    _warn_cps_unsupported || true
    _srv_profile="nocps"
  fi

  case "$_srv_profile" in
    nocps)
      I1=""; I2=""; I3=""; I4=""; I5=""
      i1_line=""; i2_line=""; i3_line=""; i4_line=""; i5_line=""
      ;;
    lite)
      # Lite-сервер: клиенту всегда I1=DNS (icloud.com), без I2-I5
      info "Профиль сервера: Lite — клиент получит I1=DNS (icloud.com)"
      local cps_out
      cps_out=$(gen_cps_i1 "dns" "icloud.com" "--only-i1") || cps_out=""
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=""; I3=""; I4=""; I5=""
      [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
      ;;
    standard)
      # Standard-сервер: клиенту I1=TLS ClientHello, без I2-I5
      info "Профиль сервера: Standard — клиент получит I1=TLS"
      local sel_domain
      sel_domain=$(select_random_domain "tls")
      [[ -z "$sel_domain" ]] && sel_domain=""
      local cps_out
      cps_out=$(gen_cps_i1 "tls" "$sel_domain") || cps_out=""
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=""; I3=""; I4=""; I5=""
      [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
      ;;
    pro|*)
      # Pro-сервер: интерактивный выбор уровня + профиля мимикрии
      hdr "⌘  Выбор I1 для клиента"
      echo "  1) Сгенерировать новый I1-I5 (выбор уровня + профиля мимикрии)"
      echo "  2) Без I1 (только H/S/Jc обфускация)"
      read_choice I1_SELECT "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" 1 2 1

      case $I1_SELECT in
        1)
          choose_obf_level
          choose_mimicry_profile
          [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
          [[ -n "$I2" ]] && i2_line="I2 = $I2" || i2_line=""
          [[ -n "$I3" ]] && i3_line="I3 = $I3" || i3_line=""
          [[ -n "$I4" ]] && i4_line="I4 = $I4" || i4_line=""
          [[ -n "$I5" ]] && i5_line="I5 = $I5" || i5_line=""
          ;;
        2)
          i1_line=""
          i2_line=""
          i3_line=""
          i4_line=""
          i5_line=""
          ;;
      esac
      ;;
  esac

  local srv_pub srv_ip port
  srv_pub=$(awg show awg0 public-key 2>/dev/null) \
    || { err "awg0 не поднят. Запусти: awg-quick up $SERVER_CONF"; return 1; }
  srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }
  port=$(grep "^ListenPort = " "$SERVER_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ' || true)
  [[ -z "$port" ]] && { err "ListenPort не найден в конфиге сервера"; return 1; }

  local cli_priv cli_pub psk
  cli_priv=$(awg genkey)
  cli_pub=$(echo "$cli_priv" | awg pubkey)
  psk=$(awg genpsk)

  {
    echo ""
    echo "[Peer]"
    echo "# $client_name"
    echo "PublicKey = $cli_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $client_addr"
  } >> "$SERVER_CONF"

  local psk_tmp
  psk_tmp=$(mktemp)
  chmod 600 "$psk_tmp"
  echo "$psk" > "$psk_tmp"

  local awg_set_ok=0
  awg set awg0 peer "$cli_pub" \
    preshared-key "$psk_tmp" \
    allowed-ips "$client_addr" && awg_set_ok=1
  rm -f "$psk_tmp"
  if [[ $awg_set_ok -eq 0 ]]; then
    err "не удалось добавить peer в runtime"; return 1
  fi

  # Исправлено: читаем параметры только из секции [Interface]
  local awg_params_from_srv
  # Список включает и параметры AWG 3.x (HeaderProtectionKey, паддинг,
  # таймеры). Без них клиент, добавленный к серверу 3.0 уже после создания,
  # молча получил бы конфиг 2.0 и не подключился бы вовсе.
  awg_params_from_srv=$(sed -n '/^\[Peer\]/q; p' "$SERVER_CONF" | grep -E "^${AWG_PARAM_KEYS_RE} = " | grep -v "^#" || true)

  {
    echo "[Interface]"
    echo "PrivateKey = $cli_priv"
    echo "Address = $client_addr"
    echo "DNS = $CLIENT_DNS"
    echo "MTU = $MTU"
    if [[ -n "$awg_params_from_srv" ]]; then echo "$awg_params_from_srv"; fi
    if [[ -n "$i1_line" ]]; then echo "$i1_line"; fi
    if [[ -n "$i2_line" ]]; then echo "$i2_line"; fi
    if [[ -n "$i3_line" ]]; then echo "$i3_line"; fi
    if [[ -n "$i4_line" ]]; then echo "$i4_line"; fi
    if [[ -n "$i5_line" ]]; then echo "$i5_line"; fi
    echo ""
    echo "[Peer]"
    echo "PublicKey = $srv_pub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $(endpoint_host "$srv_ip"):$port"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = $(awg_keepalive_value)"
  } > "$client_file"
  chmod 600 "$client_file"

  # Применяем через syncconf (без разрыва других клиентов)
  info "Применяем конфиг..."
  _apply_config 2>/dev/null || warn "syncconf не удался, может потребоваться перезапуск (Сервер → п.3)"

  # Срок действия (после создания, по согласованному UX)
  local _expire_ts
  _expire_ts=$(_expire_ask_at_creation)
  if [[ -n "$_expire_ts" ]]; then
    _expire_install
    if _expire_set_client "$client_name" "$_expire_ts"; then
      _expire_apply >/dev/null 2>&1 || true
      ok "Срок действия: $(_expire_fmt "$_expire_ts")"
    else
      warn "Не удалось записать срок (клиент создан, но бессрочный)"
    fi
  fi

  # Выдаём текст конфига; QR — отдельным пунктом меню, если понадобится
  _share_config "$client_file"

  echo ""
  success_box "▣  Клиент добавлен успешно"
  echo -e "${W}  Имя    : ${N}$client_name"
  echo -e "${W}  IP     : ${N}$client_addr"
  echo -e "${W}  Конфиг : ${N}$client_file"
}

# ─────────────────────────────────────────────────────────────
# Массовое создание клиентов (п.6 меню клиентов)
# - Префикс + N клиентов, имя <prefix>-NNN (3 цифры)
# - DNS, MTU, профиль I1 спрашиваются ОДИН раз
# - В цикле: find_free_ip, ключи, запись в SERVER_CONF, awg set, файл клиента
# - _apply_config вызывается ОДИН раз в самом конце (быстро, без гонок)
# - QR/печать конфигов не выводим (тихо)
# - SIGINT корректно прерывает и применяет накопленное
# ─────────────────────────────────────────────────────────────
do_bulk_add_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { warn "Конфиг сервера не найден. Сначала Сервер (1) → п.2"; return 0; }
  command -v awg &>/dev/null || { warn "awg не найден — возврат"; return 0; }
  awg show awg0 public-key &>/dev/null || { err "awg0 не поднят. Запусти: awg-quick up $SERVER_CONF"; return 1; }

  # ── Базовые данные сервера ──
  local server_net base_ip srv_pub srv_ip port srv_mtu _srv_profile
  server_net=$(grep "^Address" "$SERVER_CONF" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' | head -1 || true)
  base_ip=$(echo "$server_net" | cut -d. -f1-3)
  [[ -z "$base_ip" ]] && { err "Не удалось определить подсеть сервера"; return 1; }

  srv_pub=$(awg show awg0 public-key 2>/dev/null) || { err "awg0 не поднят"; return 1; }
  srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }
  port=$(grep "^ListenPort = " "$SERVER_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ' || true)
  [[ -z "$port" ]] && { err "ListenPort не найден в конфиге сервера"; return 1; }

  srv_mtu=$(grep "^MTU = " "$SERVER_CONF" | awk -F'= ' '{print $2}' | head -1 || true)
  srv_mtu=${srv_mtu:-1320}

  _srv_profile=$(grep -m1 '^# AWG_PROFILE=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  _srv_profile="${_srv_profile:-pro}"

  # ── Подсчёт свободных IP в подсети ──
  local free_count=0 srv_ip_oct=""
  srv_ip_oct=$(echo "$server_net" | cut -d/ -f1 | awk -F. '{print $4}' || true)
  local i
  for i in $(seq 2 254); do
    [[ -n "$srv_ip_oct" && "$i" == "$srv_ip_oct" ]] && continue
    if ! grep -qF "${base_ip}.${i}/32" "$SERVER_CONF" 2>/dev/null; then
      free_count=$((free_count+1))
    fi
  done
  [[ $free_count -eq 0 ]] && { warn "Свободных IP нет в подсети ${base_ip}.0/24 — возврат"; return 0; }

  echo ""
  hdr "▣  Массовое создание клиентов"
  echo -e "  ${D}Подсеть    : ${base_ip}.0/24${N}"
  echo -e "  ${D}Свободно IP: ${free_count}${N}"
  echo -e "  ${D}Профиль    : ${_srv_profile}${N}"
  echo ""

  # ── Режим именования ──
  #   1) Префикс + N   → prefix-001, prefix-002 ...
  #   2) Список имён   → iPhone, Mama, MacOS ... (через запятую)
  local NAME_MODE prefix count
  local max_count=$free_count
  (( max_count > 200 )) && max_count=200

  # _names[] заполняется только в режиме списка; пусто = режим префикса
  local _names=()

  hdr "≡  Способ именования"
  echo "  1) Префикс + количество  (prefix-001, prefix-002 ...)"
  echo "  2) Список имён через запятую  (iPhone, Mama, MacOS ...)"
  read_choice NAME_MODE "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" 1 2 1

  if (( NAME_MODE == 2 )); then
    # ── Список имён через запятую ──
    local _raw _seen=" "
    read -rp "$(echo -e "${C}  Имена через запятую: ${N}")" _raw
    if [[ -z "$_raw" ]]; then warn "Список пуст — возврат"; return 0; fi

    local _part _name _skipped_names=0
    local _oldifs="$IFS"
    IFS=','
    # shellcheck disable=SC2206  # намеренное разбиение по запятой
    local _arr=($_raw)
    IFS="$_oldifs"

    for _part in "${_arr[@]}"; do
      # trim пробелов по краям
      _name="${_part#"${_part%%[![:space:]]*}"}"
      _name="${_name%"${_name##*[![:space:]]}"}"
      [[ -z "$_name" ]] && continue
      # пробелы внутри → _
      _name="${_name// /_}"
      # выкидываем всё, кроме A-Za-z0-9_-
      _name="$(printf '%s' "$_name" | tr -cd 'A-Za-z0-9_-')"
      [[ -z "$_name" ]] && { warn "Пропущено: '$_part' (нет валидных символов)"; _skipped_names=$((_skipped_names+1)); continue; }
      # обрезка до 15 символов
      _name="${_name:0:15}"

      # дубль внутри введённого списка?
      if [[ "$_seen" == *" ${_name} "* ]]; then
        warn "Пропущено: '$_name' (дубль в списке)"
        _skipped_names=$((_skipped_names+1))
        continue
      fi
      # дубль среди существующих клиентов?
      if grep -qx "# ${_name}" "$SERVER_CONF" 2>/dev/null || [[ -f "/root/${_name}_awg2.conf" ]]; then
        warn "Пропущено: '$_name' (клиент уже существует)"
        _skipped_names=$((_skipped_names+1))
        continue
      fi
      _names+=("$_name")
      _seen+="${_name} "
    done

    if (( ${#_names[@]} == 0 )); then warn "После очистки не осталось имён — возврат"; return 0; fi

    # не больше свободных IP
    if (( ${#_names[@]} > max_count )); then
      warn "Имён ${#_names[@]}, но свободно только ${max_count} IP — лишние будут отброшены"
      _names=("${_names[@]:0:max_count}")
    fi

    count=${#_names[@]}
    echo ""
    info "К созданию (${count}): ${_names[*]}"
    (( _skipped_names > 0 )) && warn "Отброшено при разборе: ${_skipped_names}"
  else
    # ── Префикс ──
    read -rp "$(echo -e "${C}  Префикс имени (напр. bulk, user, phone): ${N}")" prefix
    if [[ -z "$prefix" ]]; then warn "Префикс не может быть пустым — возврат"; return 0; fi
    if ! [[ "$prefix" =~ ^[A-Za-z0-9_-]+$ ]]; then
      warn "Префикс содержит недопустимые символы (только A-Z, a-z, 0-9, _, -) — возврат"
      return 0
    fi
    # 15-символьный лимит на имя: prefix + "-NNN" (4 символа)
    if (( ${#prefix} > 11 )); then
      warn "Префикс длиннее 11 символов — имена prefix-NNN превысят 15 символов. Возврат"
      return 0
    fi

    # ── Количество ──
    while true; do
      read -rp "$(echo -e "${C}  Сколько клиентов создать [1-${max_count}]: ${N}")" count
      [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 && count <= max_count )) && break
      warn "Нужно число 1-${max_count}"
    done
  fi

  # ── Пауза ──
  local pause
  read -rp "$(echo -e "${C}  Пауза между клиентами, сек (Enter = 1): ${N}")" pause
  pause=${pause:-1}
  if ! [[ "$pause" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then warn "Некорректная пауза, ставлю 1"; pause=1; fi

  # ── DNS (один раз для всех) ──
  choose_dns
  [[ -z "$CLIENT_DNS" ]] && CLIENT_DNS="1.1.1.1, 1.0.0.1"

  # ── MTU (один раз для всех) ──
  echo ""
  hdr "▬  MTU для всех клиентов"
  echo "  1) $srv_mtu — как у сервера (рекомендуется)"
  echo "  2) 1420"
  echo "  3) 1380"
  echo "  4) 1280 (макс. совместимость)"
  local MTU_SEL MTU
  read_choice MTU_SEL "$(echo -e "${C}  Выбор [1-4] (Enter = 1): ${N}")" 1 4 1
  case $MTU_SEL in
    1) MTU="$srv_mtu" ;;
    2) MTU=1420 ;;
    3) MTU=1380 ;;
    4) MTU=1280 ;;
  esac

  # ── I1 (один раз для всех) ──
  local i1_line="" i2_line="" i3_line="" i4_line="" i5_line=""

  choose_target_client
  if ! _target_client_reads_cps; then
    _warn_cps_unsupported || true
    _srv_profile="nocps"
  fi

  case "$_srv_profile" in
    nocps)
      I1=""; I2=""; I3=""; I4=""; I5=""
      i1_line=""; i2_line=""; i3_line=""; i4_line=""; i5_line=""
      ;;
    lite)
      info "Профиль сервера Lite — клиенты получат I1=DNS (icloud.com)"
      local cps_out
      cps_out=$(gen_cps_i1 "dns" "icloud.com" "--only-i1") || cps_out=""
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=""; I3=""; I4=""; I5=""
      [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
      ;;
    standard)
      info "Профиль сервера Standard — клиенты получат I1=TLS"
      local sel_domain cps_out
      sel_domain=$(select_random_domain "tls")
      [[ -z "$sel_domain" ]] && sel_domain=""
      cps_out=$(gen_cps_i1 "tls" "$sel_domain") || cps_out=""
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=""; I3=""; I4=""; I5=""
      [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
      ;;
    pro|*)
      hdr "⌘  Выбор I1 для всех клиентов"
      echo "  1) Сгенерировать I1 (выбор уровня + профиля мимикрии)"
      echo "  2) Без I1 (только H/S/Jc обфускация, рекомендуется для bulk)"
      local I1_SELECT
      read_choice I1_SELECT "$(echo -e "${C}  Выбор [1-2] (Enter = 2): ${N}")" 1 2 2
      case $I1_SELECT in
        1)
          choose_obf_level
          choose_mimicry_profile
          [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
          [[ -n "$I2" ]] && i2_line="I2 = $I2" || i2_line=""
          [[ -n "$I3" ]] && i3_line="I3 = $I3" || i3_line=""
          [[ -n "$I4" ]] && i4_line="I4 = $I4" || i4_line=""
          [[ -n "$I5" ]] && i5_line="I5 = $I5" || i5_line=""
          ;;
        2)
          i1_line=""; i2_line=""; i3_line=""; i4_line=""; i5_line=""
          ;;
      esac
      ;;
  esac

  # ── Срок действия (общий для всей пачки) ──
  local _bulk_expire_ts
  _bulk_expire_ts=$(_expire_ask_at_creation)

  # ── Подтверждение ──
  echo ""
  hdr "≡  Готов к запуску"
  if (( NAME_MODE == 2 )); then
    echo -e "  ${W}Режим     : ${N}список имён"
    echo -e "  ${W}Имена     : ${N}${_names[*]}"
  else
    echo -e "  ${W}Префикс   : ${N}${prefix}-NNN"
  fi
  echo -e "  ${W}Количество: ${N}${count}"
  echo -e "  ${W}Пауза     : ${N}${pause} сек"
  echo -e "  ${W}DNS       : ${N}${CLIENT_DNS}"
  echo -e "  ${W}MTU       : ${N}${MTU}"
  if [[ -n "$i1_line" ]]; then
    echo -e "  ${W}I1        : ${N}есть (${#I1} сим)"
  else
    echo -e "  ${W}I1        : ${N}нет (базовая обфускация)"
  fi
  if [[ -n "$_bulk_expire_ts" ]]; then
    echo -e "  ${W}Срок      : ${N}$(_expire_fmt "$_bulk_expire_ts")"
  else
    echo -e "  ${W}Срок      : ${N}бессрочно"
  fi
  echo ""
  local CONFIRM
  read_yesno CONFIRM "$(echo -e "${C}  Создать ${count} клиентов? [Y/n]: ${N}")" "y"
  [[ "$CONFIRM" != "y" ]] && { info "Отменено"; return 0; }

  # awg-параметры из секции [Interface] сервера — считаем один раз
  local awg_params_from_srv
  # Список включает и параметры AWG 3.x (HeaderProtectionKey, паддинг,
  # таймеры). Без них клиент, добавленный к серверу 3.0 уже после создания,
  # молча получил бы конфиг 2.0 и не подключился бы вовсе.
  awg_params_from_srv=$(sed -n '/^\[Peer\]/q; p' "$SERVER_CONF" | grep -E "^${AWG_PARAM_KEYS_RE} = " | grep -v "^#" || true)

  # ── SIGINT handler ──
  _bulk_interrupted=0
  trap '_bulk_interrupted=1' INT

  # ── Цикл создания ──
  echo ""
  local _bulk_created=()
  local idx=1 created=0 skipped=0
  local name client_addr client_file cli_priv cli_pub psk psk_tmp suffix candidate candidate_file
  local name_idx=1

  while (( created < count )); do
    if (( _bulk_interrupted == 1 )); then
      warn "Прерывание получено — останавливаю цикл"
      break
    fi

    # Имя: из списка (режим 2) либо prefix-NNN (режим 1)
    name=""
    if (( NAME_MODE == 2 )); then
      name="${_names[created]}"
    else
      while (( name_idx <= 9999 )); do
        printf -v suffix "%03d" "$name_idx"
        candidate="${prefix}-${suffix}"
        candidate_file="/root/${candidate}_awg2.conf"
        if [[ ! -f "$candidate_file" ]] && ! grep -qE "^# ${candidate}$" "$SERVER_CONF" 2>/dev/null; then
          name="$candidate"
          name_idx=$((name_idx+1))
          break
        fi
        name_idx=$((name_idx+1))
      done
    fi

    if [[ -z "$name" ]]; then
      warn "Не удалось подобрать свободное имя — стоп"
      break
    fi

    # Свободный IP (учитывает уже добавленных в этом же цикле)
    client_addr=$(find_free_ip "$base_ip") || { warn "Подсеть заполнена — стоп"; break; }

    # Ключи
    cli_priv=$(awg genkey)
    cli_pub=$(echo "$cli_priv" | awg pubkey)
    psk=$(awg genpsk)

    # Дописываем [Peer] в SERVER_CONF (6 строк: пустая, [Peer], #name, PublicKey, PresharedKey, AllowedIPs)
    {
      echo ""
      echo "[Peer]"
      echo "# $name"
      echo "PublicKey = $cli_pub"
      echo "PresharedKey = $psk"
      echo "AllowedIPs = $client_addr"
    } >> "$SERVER_CONF"

    # Добавляем peer в runtime
    psk_tmp=$(mktemp)
    chmod 600 "$psk_tmp"
    echo "$psk" > "$psk_tmp"
    if ! awg set awg0 peer "$cli_pub" preshared-key "$psk_tmp" allowed-ips "$client_addr" 2>/dev/null; then
      rm -f "$psk_tmp"
      warn "[${idx}/${count}] ${name}: awg set не удался, откат записи"
      # Откат: удаляем последние 6 строк из SERVER_CONF
      local total_lines
      total_lines=$(wc -l < "$SERVER_CONF")
      if (( total_lines > 6 )); then
        head -n $((total_lines - 6)) "$SERVER_CONF" > "${SERVER_CONF}.tmp" && mv "${SERVER_CONF}.tmp" "$SERVER_CONF"
      fi
      skipped=$((skipped+1))
      idx=$((idx+1))
      sleep "$pause"
      continue
    fi
    rm -f "$psk_tmp"

    # Файл клиента
    client_file="/root/${name}_awg2.conf"
    {
      echo "[Interface]"
      echo "PrivateKey = $cli_priv"
      echo "Address = $client_addr"
      echo "DNS = $CLIENT_DNS"
      echo "MTU = $MTU"
      if [[ -n "$awg_params_from_srv" ]]; then echo "$awg_params_from_srv"; fi
      [[ -n "$i1_line" ]] && echo "$i1_line"
      [[ -n "$i2_line" ]] && echo "$i2_line"
      [[ -n "$i3_line" ]] && echo "$i3_line"
      [[ -n "$i4_line" ]] && echo "$i4_line"
      [[ -n "$i5_line" ]] && echo "$i5_line"
      echo ""
      echo "[Peer]"
      echo "PublicKey = $srv_pub"
      echo "PresharedKey = $psk"
      echo "Endpoint = $(endpoint_host "$srv_ip"):$port"
      echo "AllowedIPs = 0.0.0.0/0, ::/0"
      echo "PersistentKeepalive = $(awg_keepalive_value)"
    } > "$client_file"
    chmod 600 "$client_file"

    _bulk_created+=("$name")
    created=$((created+1))
    echo -e "  ${G}[${idx}/${count}]${N} ${name} → ${client_addr}"
    idx=$((idx+1))

    # Пауза между итерациями (не на последней)
    if (( created < count )); then
      sleep "$pause"
    fi
  done

  # Снимаем trap
  trap - INT

  # ── Один apply в конце ──
  echo ""
  info "Применяем конфиг (один раз для всех)..."
  _apply_config 2>/dev/null || warn "syncconf не удался, может потребоваться перезапуск (Сервер → п.3)"

  # Применяем срок ко всем созданным (если указан)
  if [[ -n "$_bulk_expire_ts" && ${#_bulk_created[@]} -gt 0 ]]; then
    _expire_install
    local _n
    for _n in "${_bulk_created[@]}"; do
      _expire_set_client "$_n" "$_bulk_expire_ts" >/dev/null 2>&1 || true
    done
    _expire_apply >/dev/null 2>&1 || true
    info "Срок применён ко всем: $(_expire_fmt "$_bulk_expire_ts")"
  fi

  # ── Итоги (тихо: только список + путь) ──
  echo ""
  success_box "▣  Готово: создано ${#_bulk_created[@]} из ${count}"
  if (( skipped > 0 )); then
    echo -e "${Y}  Пропущено: ${skipped}${N}"
  fi
  echo -e "${W}  Папка     : ${N}/root/"
  echo -e "${W}  Имена     :${N}"
  local n
  for n in "${_bulk_created[@]}"; do
    echo "    • $n"
  done
}

# ─────────────────────────────────────────────────────────────
# do_export_configs — собирает все клиентские *_awg2.conf из /root
# в один архив. Приоритет zip, fallback tar.gz (zip не везде есть).
# Серверный конфиг (awg0.conf) НЕ включается — только клиенты.
# ─────────────────────────────────────────────────────────────
do_export_configs() {
  hdr "📦  Экспорт конфигов клиентов"

  # Собираем список клиентских конфигов (без серверного awg0/SERVER_CONF)
  local srv_base
  srv_base=$(basename "${SERVER_CONF:-/etc/amnezia/amneziawg/awg0.conf}")
  local files=() f
  for f in /root/*_awg2.conf; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "$srv_base" ]] && continue
    files+=("$f")
  done

  if (( ${#files[@]} == 0 )); then
    warn "Клиентских конфигов (*_awg2.conf) в /root не найдено — возврат"
    return 0
  fi

  echo -e "  ${C}Найдено конфигов: ${W}${#files[@]}${N}"
  local _bn
  for f in "${files[@]}"; do _bn=$(basename "$f"); echo -e "    ${D}• ${_bn}${N}"; done
  echo ""

  local CONFIRM
  read_yesno CONFIRM "$(echo -e "${C}  Создать архив? [Y/n]: ${N}")" "y"
  [[ "$CONFIRM" != "y" ]] && { info "Отменено"; return 0; }

  local stamp out base_names=()
  stamp=$(date +%Y%m%d_%H%M%S)
  for f in "${files[@]}"; do base_names+=("$(basename "$f")"); done

  # zip приоритетно (запароленный архив с -e? — нет, без интерактива, просто zip)
  if command -v zip &>/dev/null; then
    out="/root/awg_clients_${stamp}.zip"
    # -j: без путей внутри архива (только имена файлов)
    if (cd /root && zip -j -q "$out" "${base_names[@]}"); then
      chmod 600 "$out"
      success_box "📦  Готово: $(basename "$out")"
      echo -e "${W}  Путь   : ${N}${out}"
      echo -e "${W}  Файлов : ${N}${#files[@]}"
      info "Скачать: scp root@SERVER:${out} ."
      return 0
    fi
    warn "zip не сработал — пробую tar.gz"
  fi

  # Fallback: tar.gz
  if command -v tar &>/dev/null; then
    out="/root/awg_clients_${stamp}.tar.gz"
    if (cd /root && tar -czf "$out" "${base_names[@]}" 2>/dev/null); then
      chmod 600 "$out"
      success_box "📦  Готово: $(basename "$out")"
      echo -e "${W}  Путь   : ${N}${out}"
      echo -e "${W}  Файлов : ${N}${#files[@]}"
      info "Скачать: scp root@SERVER:${out} ."
      info "Распаковать: tar -xzf $(basename "$out")"
      return 0
    fi
  fi

  err "Ни zip, ни tar не доступны — установи: apt-get install zip"
  return 1
}

do_list_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "Конфиг сервера не найден"; return 1; }

  echo ""
  hdr "▣  КЛИЕНТЫ"
  echo ""

  local transfer_cache
  transfer_cache=$(awg show awg0 transfer 2>/dev/null || true)
  
  local handshake_cache
  handshake_cache=$(awg show awg0 latest-handshakes 2>/dev/null || true)
  
  local endpoint_cache
  endpoint_cache=$(awg show awg0 endpoints 2>/dev/null || true)

  local i=0
  local name="" pubkey="" ip="" tx_raw=0 rx_raw=0 handshake_time="" endpoint="" expire_ts=""
  
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[Peer\] ]]; then
      if [[ $i -gt 0 ]] && [[ -n "$pubkey" ]]; then
        # Нормализуем значения перед арифметикой
        tx_raw=${tx_raw:-0}
        rx_raw=${rx_raw:-0}
        _print_client_info "$i" "$name" "$ip" "$tx_raw" "$rx_raw" "$handshake_time" "$endpoint" "$expire_ts"
      fi
      i=$((i+1))
      name=""; pubkey=""; ip=""; tx_raw=0; rx_raw=0; handshake_time=""; endpoint=""; expire_ts=""
    elif [[ "$line" =~ ^#[[:space:]]*expires=([0-9]+) ]]; then
      expire_ts="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^#[[:space:]](.+) ]]; then
      _cmt="${BASH_REMATCH[1]}"
      # Пропускаем служебные метки expires= и orig_ips=
      if [[ "$_cmt" != expires=* && "$_cmt" != orig_ips=* ]]; then
        name="$_cmt"
      fi
    elif [[ "$line" =~ ^PublicKey[[:space:]]=[[:space:]](.+) ]]; then
      pubkey="${BASH_REMATCH[1]}"
      local transfer_line
      transfer_line=$(echo "$transfer_cache" | grep -F "$pubkey" | head -1 || true)
      tx_raw=$(echo "$transfer_line" | awk '{print $2}' 2>/dev/null || echo "0")
      rx_raw=$(echo "$transfer_line" | awk '{print $3}' 2>/dev/null || echo "0")
      tx_raw=${tx_raw:-0}
      rx_raw=${rx_raw:-0}
      local hs_line
      hs_line=$(echo "$handshake_cache" | grep -F "$pubkey" | head -1 || true)
      handshake_time=$(echo "$hs_line" | awk '{print $2}' 2>/dev/null || echo "")
      local ep_line
      ep_line=$(echo "$endpoint_cache" | grep -F "$pubkey" | head -1 || true)
      endpoint=$(echo "$ep_line" | awk '{print $2}' 2>/dev/null || echo "")
    elif [[ "$line" =~ ^AllowedIPs[[:space:]]=[[:space:]](.+) ]]; then
      ip="${BASH_REMATCH[1]}"
    fi
  done < "$SERVER_CONF"
  
  if [[ $i -gt 0 ]] && [[ -n "$pubkey" ]]; then
    tx_raw=${tx_raw:-0}
    rx_raw=${rx_raw:-0}
    _print_client_info "$i" "$name" "$ip" "$tx_raw" "$rx_raw" "$handshake_time" "$endpoint" "$expire_ts"
  fi

  if [[ $i -eq 0 ]]; then
    hdr "▣  НЕТ АКТИВНЫХ КЛИЕНТОВ"
  fi

  echo ""
  hdr "∑  КЛИЕНТЫ — Справка"
  echo -e "${C}  Подключение: если handshake не обновляется > 2 мин — клиент офлайн"
  echo ""
}

_print_client_info() {
  local num="$1"
  local name="$2"
  local ip="$3"
  local tx_raw="$4"
  local rx_raw="$5"
  # Защита от пустых/нечисловых значений (set -euo pipefail + арифметика)
  [[ "$tx_raw" =~ ^[0-9]+$ ]] || tx_raw=0
  [[ "$rx_raw" =~ ^[0-9]+$ ]] || rx_raw=0
  local handshake_time="$6"
  local endpoint="$7"
  local expire_ts="$8"
  
  local display_name="${name:-безымянный}"
  display_name="${display_name:0:15}"
  
  local tx_fmt rx_fmt
  if (( tx_raw >= 1073741824 )); then
    tx_fmt=$(echo "scale=2; $tx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ"
  elif (( tx_raw >= 1048576 )); then
    tx_fmt=$(echo "scale=2; $tx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ"
  else
    local kb_val
    kb_val=$(echo "scale=0; $tx_raw/1024" | bc 2>/dev/null || echo "0")
    [[ "$kb_val" == "0" && "$tx_raw" -gt 0 ]] && kb_val=1 || true
    tx_fmt="${kb_val} КБ"
  fi

  if (( rx_raw >= 1073741824 )); then
    rx_fmt=$(echo "scale=2; $rx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ"
  elif (( rx_raw >= 1048576 )); then
    rx_fmt=$(echo "scale=2; $rx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ"
  else
    local kb_val
    kb_val=$(echo "scale=0; $rx_raw/1024" | bc 2>/dev/null || echo "0")
    [[ "$kb_val" == "0" && "$rx_raw" -gt 0 ]] && kb_val=1 || true
    rx_fmt="${kb_val} КБ"
  fi
  
  local status_icon=""
  local status_text=""
  if [[ -n "$handshake_time" ]] && [[ "$handshake_time" != "0" ]]; then
    local current_time diff
    current_time=$(date +%s)
    diff=$((current_time - handshake_time))
    local time_str
    time_str=$(_fmt_duration "$diff")
    if [[ $diff -lt 120 ]]; then
      status_icon="${G}●${N}"
      status_text="активен (${time_str} назад)"
    elif [[ $diff -lt 300 ]]; then
      status_icon="${Y}◐${N}"
      status_text="неактивен (${time_str})"
    else
      status_icon="${R}○${N}"
      status_text="офлайн (${time_str})"
    fi
  else
    status_icon="${R}○${N}"
    status_text="нет подключения"
  fi
  
  local endpoint_short=""
  if [[ -n "$endpoint" ]]; then
    endpoint_short="${endpoint%:*}"
  fi
  
  echo -e "  ${W}┌─ ${C}[${num}]${N} ${W}${display_name}${N}"
  echo -e "  ${W}│${N}  » IP:       ${W}$ip${N}"
  echo -e "  ${W}│${N}  ↑ Трафик:   ↑ ${G}$tx_fmt${N}  ↓ ${C}$rx_fmt${N}"
  echo -e "  ${W}│${N}  ∑ Статус:   $status_icon $status_text"
  if [[ -n "$endpoint_short" ]]; then
    echo -e "  ${W}│${N}  » Endpoint: ${Y}$endpoint_short${N}"
  fi
  # Срок действия (expire), если задан
  if [[ -n "$expire_ts" && "$expire_ts" =~ ^[0-9]+$ ]]; then
    local _now_ts _exp_str _exp_color
    _now_ts=$(date +%s)
    _exp_str=$(_expire_fmt "$expire_ts" 2>/dev/null || echo "ts=$expire_ts")
    if (( expire_ts <= _now_ts )); then
      _exp_color="$R"        # истёк
    elif (( expire_ts - _now_ts < 86400 )); then
      _exp_color="$Y"        # меньше суток
    else
      _exp_color="$G"
    fi
    echo -e "  ${W}│${N}  ⌛ Срок:     ${_exp_color}${_exp_str}${N}"
  fi
  echo -e "  ${W}└─────────────────────────────────────────────────────────────────────────${N}"
}

# Смена мимикрии у уже выданного клиента.
#
# I1-I5 живут только в клиентском конфиге, поэтому профиль меняется у одного
# устройства, не задевая сервер и остальных клиентов. Это нужная операция, а не
# удобство: один и тот же конфиг проходит у одного провайдера и не проходит у
# другого, и перебрать профиль должно быть дешевле, чем пересоздавать клиента.
_detect_mimicry() {           # $1 = строка I1
  local line="$1"
  case "$line" in
    *"<b 0x16"*)        echo "tls" ;;
    *"<b 0x52454749"*)  echo "sip" ;;      # "REGI" в hex
    *"<b 0xc"*|*"<b 0x4"*) echo "quic" ;;
    *"<r 2><b 0x"*)     echo "dns" ;;
    "")                 echo "нет" ;;
    *)                  echo "неизвестно" ;;
  esac
}

do_change_client_mimicry() {
  local found_files=()
  while IFS= read -r -d '' f; do
    found_files+=("$f")
  done < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)
  [[ ${#found_files[@]} -eq 0 ]] && { err "Конфиги клиентов не найдены в /root/"; return 1; }

  local unique
  mapfile -t unique < <(printf "%s\n" "${found_files[@]}" | sort -u)

  hdr "~  Сменить мимикрию у клиента"
  echo ""
  echo -e "  ${D}Меняются только I1-I5 в конфиге этого клиента.${N}"
  echo -e "  ${D}Сервер и другие клиенты не затрагиваются — переподключать их не надо.${N}"
  echo ""
  local i=0 f
  for f in "${unique[@]}"; do
    i=$((i+1))
    local _cur
    _cur=$(_detect_mimicry "$(grep -m1 '^I1 = ' "$f" 2>/dev/null | cut -d' ' -f3-)")
    printf "  %d) %-28s ${D}сейчас: %s${N}\n" "$i" "$(basename "$f")" "$_cur"
  done
  echo ""
  local _sel
  read_choice _sel "$(echo -e "${C}  Выбор [1-${i}] (0 = отмена): ${N}")" 0 "$i" "0"
  [[ "$_sel" == "0" ]] && { info "Отменено"; return 0; }
  local chosen="${unique[$((_sel - 1))]}"
  [[ -f "$chosen" ]] || { warn "Файл не найден"; return 0; }

  # Профиль сервера (Lite/Standard) фиксирует уровень, Pro даёт выбор
  local _srv_profile
  _srv_profile=$(grep -m1 '^# AWG_PROFILE=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  _srv_profile="${_srv_profile:-pro}"

  I1=""; I2=""; I3=""; I4=""; I5=""
  choose_target_client
  if ! _target_client_reads_cps; then
    _warn_cps_unsupported || true
  else
    if [[ "$_srv_profile" == "pro" ]]; then
      choose_obf_level
    else
      OBF_LEVEL=2
      info "Профиль сервера ${_srv_profile}: у клиента только I1"
    fi
    choose_mimicry_profile || return 1
  fi

  # Собираем новые строки. Пустые не пишем: строка «I2 = » ломает разбор.
  local new_lines="" k v
  for k in I1 I2 I3 I4 I5; do
    v="${!k}"
    [[ -n "$v" ]] || continue
    new_lines+="${k} = ${v}"$'\n'
  done
  new_lines="${new_lines%$'\n'}"

  local bak tmp
  bak="${chosen}.bak.$(date +%s)"
  cp "$chosen" "$bak" 2>/dev/null || warn "Резервную копию сделать не удалось"
  tmp=$(mktemp) || { err "mktemp провалился"; return 1; }

  # Старые I-строки выбрасываем, новые вставляем перед [Peer] — там же, где
  # они стояли, и внутри секции [Interface], которой они принадлежат.
  awk -v ins="$new_lines" '
    /^\[Peer\]/ && !inserted { if (ins != "") print ins; inserted = 1 }
    !/^I[1-5] = / { print }
    END { if (!inserted && ins != "") print ins }
  ' "$chosen" > "$tmp"

  if [[ ! -s "$tmp" ]] || ! grep -q '^\[Interface\]' "$tmp"; then
    err "Перезапись конфига не удалась — файл не тронут"
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$chosen" && rm -f "$tmp"
  chmod 600 "$chosen" 2>/dev/null || true

  local _n
  _n=$(grep -cE '^I[1-5] = ' "$chosen" 2>/dev/null || echo 0)
  ok "Мимикрия обновлена: ${MIMICRY_PROFILE:-нет}, пакетов I: ${_n}"
  info "Резервная копия: $bak"
  echo ""
  warn "Клиенту нужен НОВЫЙ конфиг — до замены он подключается по старому"
  _share_config "$chosen"
  echo ""
  echo -e "${D}  Конфиг: $chosen${N}"
  return 0
}

do_show_qr() {
  # found_files, а не found: в других функциях found — скалярный счётчик,
  # и от одноимённого массива shellcheck путает области видимости.
  local found_files=()
  while IFS= read -r -d '' f; do
    found_files+=("$f")
  done < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  [[ ${#found_files[@]} -eq 0 ]] && { err "Конфиги клиентов не найдены в /root/"; return 1; }

  local unique
  mapfile -t unique < <(printf "%s\n" "${found_files[@]}" | sort -u)

  hdr "≡  Выбери конфиг"
  local i=0
  for f in "${unique[@]}"; do
    i=$((i+1))
    echo "  $i) $(basename "$f")"
  done

  local QR_CHOICE prompt_txt
  if [[ $i -eq 1 ]]; then
    prompt_txt="  Выбор [1] (Enter = 1, 0 = отмена): "
  else
    prompt_txt="  Выбор [1-$i] (Enter = 1, 0 = отмена): "
  fi
  read_choice QR_CHOICE "$(echo -e "${C}${prompt_txt}${N}")" 0 "$i" "1"
  [[ "$QR_CHOICE" == "0" ]] && { info "Отменено"; return 0; }

  local chosen="${unique[$((QR_CHOICE - 1))]}"
  [[ -f "$chosen" ]] || { warn "Файл не найден"; return 0; }

  # Пункт меню «Показать QR» — единственное место, где QR запрашивают явно
  _share_config "$chosen" qr
  echo ""
  echo -e "${D}  Конфиг: $chosen${N}"
}

do_restart() {
  hdr "↻  Перезапуск awg0"
  if [[ ! -f "$SERVER_CONF" ]]; then
    err "Конфиг сервера не найден"
    echo -e "  ${Y}→ Возможно, AmneziaWG ещё не установлен${N}"
    echo -e "  ${Y}→ Сервер (1) → п.1 — установка зависимостей${N}"
    echo -e "  ${Y}→ Сервер (1) → п.2 — создать сервер${N}"
    echo ""
    local CONFIRM_INSTALL
    read_yesno CONFIRM_INSTALL "$(echo -e "${G}  Установить сейчас? [y/N]: ${N}")" "n"
    case "$CONFIRM_INSTALL" in
      [yY]|[yY][eE][sS])
        do_install
        do_gen
        return $?
        ;;
      *)
        warn "Отменено. Установи компоненты вручную."
        return 1
        ;;
    esac
  fi
  restart "Перезапуск awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  if awg_up_diag "$SERVER_CONF"; then
    ok "awg0 перезапущен"
  else
    err "Не удалось поднять awg0"
    return 1
  fi
}

# Endpoint для клиентов: показать текущий, задать домен или вернуть IP.
#
# Смена не трогает ключи и не требует перезапуска интерфейса: Endpoint живёт
# только в клиентских конфигах. Поэтому здесь же предлагаем переписать уже
# выданные — иначе старые клиенты останутся на IP, новые на домене, и понять,
# что у кого, потом сложно.
do_endpoint_menu() {
  [[ -f "$SERVER_CONF" ]] || { err "Сервер не создан"; return 1; }

  local cur srv_ip port
  cur=$(endpoint_domain)
  srv_ip=$(get_public_ip 2>/dev/null || true)
  port=$(grep -m1 '^ListenPort' "$SERVER_CONF" 2>/dev/null | tr -dc '0-9' || true)

  echo ""
  hdr "◈  Endpoint для клиентов"
  echo ""
  if [[ -n "$cur" ]]; then
    echo -e "  Сейчас: ${W}${cur}:${port}${N} ${D}(домен)${N}"
  else
    echo -e "  Сейчас: ${W}${srv_ip:-?}:${port}${N} ${D}(IP сервера)${N}"
  fi
  echo ""
  echo -e "  ${D}Домен удобнее при переезде: меняешь A-запись, а конфиги${N}"
  echo -e "  ${D}у клиентов остаются рабочими. Требуется прямая A-запись${N}"
  echo -e "  ${D}на IP сервера — проксирование UDP через Cloudflare не работает.${N}"
  echo ""
  echo -e "  ${C}1)${N} Задать домен"
  [[ -n "$cur" ]] && echo -e "  ${C}2)${N} Вернуться на IP сервера" \
                  || echo -e "  ${D}2) Вернуться на IP (уже IP)${N}"
  echo -e "  ${W}0)${N} ← Назад"
  echo ""

  local _c
  read_choice _c "$(echo -e "${C}  Выбор [0-2]: ${N}")" 0 2 "0"
  case "$_c" in
    1)
      local d
      while true; do
        read -rp "$(echo -e "${C}  Домен (пусто = отмена): ${N}")" d
        d=$(echo "${d:-}" | tr -d ' ')
        [[ -z "$d" ]] && { info "Отменено"; return 0; }
        valid_domain "$d" && break
        warn "Нужно имя вида vpn.example.com (не IP)"
      done
      check_domain_resolves "$d" || {
        local _go
        read_yesno _go "$(echo -e "${Y}  Всё равно задать? [y/N]: ${N}")" "n"
        [[ "$_go" == "y" ]] || { info "Отменено"; return 0; }
      }
      set_endpoint_domain "$d" || { err "Не удалось записать домен в конфиг"; return 1; }
      ok "Endpoint для новых конфигов: ${d}:${port}"
      _endpoint_rewrite_clients "${d}:${port}"
      ;;
    2)
      [[ -n "$cur" ]] || { info "Уже используется IP"; return 0; }
      set_endpoint_domain "" || { err "Не удалось убрать домен из конфига"; return 1; }
      ok "Endpoint для новых конфигов: ${srv_ip:-IP сервера}:${port}"
      [[ -n "$srv_ip" ]] && _endpoint_rewrite_clients "${srv_ip}:${port}"
      ;;
    *) info "Отменено" ;;
  esac
  return 0
}

# Предлагает переписать Endpoint в уже выданных конфигах. $1 = "host:port".
_endpoint_rewrite_clients() {
  local ep="$1" files=() f
  shopt -s nullglob
  files=( /root/*_awg2.conf )
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || return 0

  echo ""
  info "Уже выданных конфигов: ${#files[@]}"
  echo -e "  ${D}Они продолжат работать со старым Endpoint, пока он доступен.${N}"
  echo ""
  local _upd
  read_yesno _upd "$(echo -e "${C}  Переписать Endpoint в них на ${ep}? [Y/n]: ${N}")" "y"
  [[ "$_upd" == "y" ]] || { info "Файлы не тронуты"; return 0; }

  local done_n=0 fail_n=0
  for f in "${files[@]}"; do
    if sed -i "s|^Endpoint = .*|Endpoint = ${ep}|" "$f" 2>/dev/null; then
      done_n=$((done_n+1))
    else
      warn "Не удалось обновить $(basename "$f")"
      fail_n=$((fail_n+1))
    fi
  done
  ok "Обновлено конфигов: $done_n"
  [[ $fail_n -gt 0 ]] && warn "Не обновлено: $fail_n"
  echo -e "  ${Y}Клиентам нужно забрать новый конфиг — старый Endpoint у них${N}"
  echo -e "  ${Y}останется до замены файла на устройстве.${N}"
  return 0
}

# 10. СБРОС СЕРВЕРА (чистая переустановка)
# Удаляет конфиги и правила firewall, но НЕ трогает пакеты/бинарники.
# После сброса можно сразу Сервер (1) → п.2 — создать новый сервер.
# Перегенерация параметров обфускации на работающем сервере.
#
# Зачем: H1-H4 и S1-S4 — это и есть то, что отличает трафик сервера от обычного
# WireGuard. Утёк один клиентский конфиг — и у цензора сигнатура ВСЕГО сервера,
# при целых ключах. Раньше лечилось только пересозданием сервера с потерей всех
# клиентов; теперь параметры меняются на месте.
#
# Ключи, PSK, IP, имена, сроки и I1-I5 не трогаются — меняется только обрамление,
# которое обязано совпадать у сервера и всех клиентов. Заодно здесь же можно
# сменить версию протокола: раз уж все конфиги всё равно переписываются.
do_rotate_awg_params() {
  [[ -f "$SERVER_CONF" ]] || { err "Сервер не создан — нечего перегенерировать"; return 1; }

  local cur_proto new_proto
  cur_proto=$(grep -m1 '^# AWG_PROTO=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  cur_proto="${cur_proto:-2.0}"

  echo ""
  hdr "↻  Перегенерация параметров обфускации"
  echo ""
  echo -e "  Текущая версия протокола: ${W}AWG ${cur_proto}${N}"
  echo ""
  echo -e "  ${D}Меняются Jc/Jmin/Jmax, S1-S4, H1-H4${N}"
  [[ "$cur_proto" == "3.0" || "$cur_proto" == "3.1" ]] && \
    echo -e "  ${D}плюс HeaderProtectionKey, паддинг и таймеры 3.0${N}"
  [[ "$cur_proto" == "3.1" ]] && \
    echo -e "  ${D}плюс RandomTrailers/DisableCookies 3.1${N}"
  echo -e "  ${D}Ключи, IP, имена, сроки и мимикрия I1-I5 сохраняются.${N}"
  echo ""

  # Раз конфиги всё равно переписываются — предлагаем сменить и версию
  echo -e "  ${W}Версия протокола после перегенерации:${N}"
  echo -e "  ${G}1)${N} AWG 2.0 ${D}(шире совместимость клиентов)${N}"
  echo -e "  ${G}2)${N} AWG 3.0 ${D}(защита заголовков, паддинг, таймеры)${N}"
  echo -e "  ${G}3)${N} AWG 3.1 ${D}(плюс RandomTrailers/DisableCookies, нужен свежий клиент)${N}"
  echo -e "  ${D}Enter — оставить текущую (AWG ${cur_proto})${N}"
  echo ""
  local _pc _def
  case "$cur_proto" in
    3.1) _def="3" ;;
    3.0) _def="2" ;;
    *)   _def="1" ;;
  esac
  read_choice _pc "$(echo -e "${C}  Выбор [1-3] (Enter = ${_def}): ${N}")" 1 3 "$_def"
  case "$_pc" in
    3) new_proto="3.1" ;;
    2) new_proto="3.0" ;;
    *) new_proto="2.0" ;;
  esac

  # Переход на 3.x на несовместимых компонентах положит рабочий сервер:
  # конфиги перепишутся, а awg-quick up на них упадёт. Проверяем заранее.
  # Переход 3.0 → 3.1 тоже проверяем: 3.1-ключей старые tools не знают.
  if [[ "$new_proto" != "2.0" && "$new_proto" != "$cur_proto" ]]; then
    awg_compat_gate "$new_proto" || { info "Отменено — сервер остался на AWG ${cur_proto}"; return 0; }
  fi

  # Считаем клиентов, которых это заденет
  local clients=() f
  while IFS= read -r -d '' f; do clients+=("$f"); done     < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  echo ""
  echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  warn "ВСЕ клиенты потеряют связь до получения нового конфига"
  echo -e "  ${Y}Затронуто клиентов: ${W}${#clients[@]}${N}"
  echo -e "  ${Y}Файлы в /root будут обновлены автоматически, но доставить${N}"
  echo -e "  ${Y}их на устройства придётся вручную — или выдать через бота.${N}"
  [[ "$new_proto" != "$cur_proto" ]] &&     echo -e "  ${R}Версия меняется: AWG ${cur_proto} → AWG ${new_proto}${N}"
  echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  read_confirm "$(echo -e "${R}  Перегенерировать параметры? (введи yes): ${N}")" ||     { info "Отменено"; return 0; }

  auto_backup "rotate" || warn "Авто-бэкап не удался — продолжаем"

  # Генерируем новый набор под выбранную версию
  local AWG_PROTO="$new_proto"
  local _saved_profile
  _saved_profile=$(grep -m1 '^# AWG_PROFILE=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  AWG_PROFILE="${_saved_profile:-pro}"
  gen_awg_params || { err "Не удалось сгенерировать параметры"; return 1; }

  local params
  params=$(echo -e "$AWG_PARAMS_LINES")
  [[ -n "$params" ]] || { err "Параметры пусты — отмена"; return 1; }

  info "Обновляю серверный конфиг..."
  if ! _replace_awg_params "$SERVER_CONF" "$params"; then
    err "Не удалось обновить $SERVER_CONF"
    info "Восстановись из бекапа: Бекапы (4) → восстановить"
    return 1
  fi
  # Маркер версии
  if grep -q '^# AWG_PROTO=' "$SERVER_CONF"; then
    sed -i "s|^# AWG_PROTO=.*|# AWG_PROTO=${new_proto}|" "$SERVER_CONF"
  else
    sed -i "1a # AWG_PROTO=${new_proto}" "$SERVER_CONF"
  fi
  ok "Серверный конфиг обновлён"

  # Клиентские конфиги
  local updated=0 failed=0 ka
  ka=$(awg_keepalive_value)
  for f in ${clients[@]+"${clients[@]}"}; do
    if _replace_awg_params "$f" "$params"; then
      # PersistentKeepalive живёт в секции [Peer] и зависит от версии:
      # на 3.x это диапазон, на 2.0 — фиксированные 25.
      sed -i "s|^PersistentKeepalive = .*|PersistentKeepalive = ${ka}|" "$f"
      updated=$((updated + 1))
    else
      warn "Не удалось обновить $(basename "$f")"
      failed=$((failed + 1))
    fi
  done
  ok "Клиентских конфигов обновлено: ${updated}"
  [[ $failed -gt 0 ]] && warn "Не обновлено: ${failed}"

  info "Перезапускаю awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  if awg_up_diag "$SERVER_CONF"; then
    ok "Интерфейс поднят с новыми параметрами"
  else
    err "awg0 не поднялся"
    info "Откат: Бекапы (4) → восстановить"
    return 1
  fi

  echo ""
  success_box "Параметры перегенерированы"
  echo -e "  ${W}Версия  : ${N}AWG ${new_proto}"
  echo -e "  ${W}Клиентов: ${N}${updated}"
  echo ""
  echo -e "${Y}  Каждому клиенту нужен НОВЫЙ конфиг — до этого связи не будет.${N}"
  echo ""
  if [[ ${#clients[@]} -gt 0 ]]; then
    echo -e "  ${W}Кому раздать:${N}"
    for f in "${clients[@]}"; do
      echo -e "    ${D}$(basename "$f" _awg2.conf)${N}"
    done
    echo ""
    echo -e "  ${C}Собрать всё в архив: Клиенты (2) → Экспорт конфигов${N}"
    echo -e "  ${C}Либо выдать по одному через Telegram-бота${N}"
  fi
  # Сюда попадают и те, кто переключил сервер с 2.0 на 3.0 — ловушка та же.
  _warn_bot_needs_update
  log_info "Параметры перегенерированы, версия $new_proto, клиентов $updated"
  return 0
}

do_reset_server() {
  echo ""
  hdr "↺  Сброс настроек сервера (чистая переустановка)"
  echo ""
  warn "Будет удалено:"
  echo -e "  ${R}—${N} Интерфейс awg0 (awg-quick down)"
  echo -e "  ${R}—${N} Серверный конфиг: ${W}$SERVER_CONF${N}"
  echo -e "  ${R}—${N} Все клиентские конфиги: ${W}/root/*_awg2.conf${N}"
  echo -e "  ${R}—${N} UFW правила AmneziaWG"
  echo -e "  ${R}—${N} iptables правила NAT/FORWARD для awg0"
  echo ""
  echo -e "${G}  Сохраняется:${N}"
  echo -e "  ${G}✓${N} Пакеты amneziawg, amneziawg-tools"
  echo -e "  ${G}✓${N} Kernel module"
  echo -e "  ${G}✓${N} Лог /var/log/awg-Toolza.log"
  echo -e "  ${G}✓${N} Бекапы в ~/awg_backup/"
  echo ""
  echo -e "${C}  После сброса: Сервер (1) → п.2 — создать новый сервер.${N}"
  echo ""

  read_confirm "$(echo -e "${R}  Подтверди сброс (введи yes): ${N}")" || \
    { warn "Отменено."; return 0; }

  # Авто-бэкап (всегда создаём перед сбросом)
  if [[ -f "$SERVER_CONF" ]]; then
    auto_backup "reset" || warn "Авто-бэкап не удался"
  fi

  # === Сброс ===
  trash "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  # Убираем iptables правила явно — PostDown мог не отработать
  trash "Очищаем iptables NAT/FORWARD..."
  # Вытаскиваем CLIENT_NET из конфига пока он ещё есть
  local client_net=""
  if [[ -f "$SERVER_CONF" ]]; then
    local srv_addr
    srv_addr=$(grep "^Address = " "$SERVER_CONF" | head -1 | awk -F'= ' '{print $2}' | tr -d ' ' || true)
    if [[ -n "$srv_addr" ]]; then
      # 10.45.12.1/24 → 10.45.12.0/24
      local base
      base=$(echo "$srv_addr" | cut -d/ -f1 | awk -F. '{printf "%s.%s.%s.0", $1, $2, $3}')
      client_net="${base}/24"
    fi
  fi
  local iface
  iface=$(ip route | awk '/default/{print $5; exit}')
  if [[ -n "$client_net" && -n "$iface" ]]; then
    iptables -t nat -D POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE 2>/dev/null || true
  fi
  iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true

  trash "Удаляем серверный конфиг..."
  rm -f "$SERVER_CONF" 2>/dev/null || true
  # Также снимаем все .bak файлы рядом чтобы избежать путаницы при восстановлении
  rm -f "${SERVER_CONF}".bak.* 2>/dev/null || true
  rm -f "${SERVER_CONF}".pre_rename.* 2>/dev/null || true
  rm -f "${SERVER_CONF}".pre_delete.* 2>/dev/null || true

  trash "Удаляем клиентские конфиги..."
  rm -f /root/*_awg2.conf 2>/dev/null || true

  trash "Удаляем UFW правила..."
  if command -v ufw &>/dev/null; then
    local rule_nums
    rule_nums=$(ufw status numbered 2>/dev/null | grep -i "AmneziaWG" | grep -oE '\[[0-9]+\]' | tr -d '[]' | sort -rn || true)
    for num in $rule_nums; do
      echo "y" | ufw --force delete "$num" 2>/dev/null || true
    done
  fi

  # Сброс кеша доменов (опционально)
  rm -f /tmp/awg_domain_cache.txt 2>/dev/null || true

  # Сброс SERVER_REGION к дефолту — конфига больше нет
  SERVER_REGION="world"

  echo ""
  hdr "√ Сервер сброшен"
  echo -e "${G}  Конфиги удалены, пакеты сохранены${N}"
  echo -e "${C}  Теперь можно Сервер (1) → п.2 — создать новый сервер${N}"
  echo ""
  log_info "do_reset_server: сброс выполнен"
}

# Перенаправляет трафик AWG туннеля через Cloudflare Warp.
# Поддерживает бесплатный Warp и Warp+ с лицензионным ключом.
# Полезно когда IP сервера в блок-листах РКН — выходной IP меняется на Cloudflare.

# ═══════════════════════════════════════════════════════════════
#  Слой абстракции бэкендов WARP
# ═══════════════════════════════════════════════════════════════
# У WARP два способа реализации, и меню, per-client тумблер, бот и бэкап
# обязаны работать только через этот контракт, не зная, какой из них активен:
#
#   wg    — kernel WireGuard. Профиль генерируется wgcf, интерфейс поднимается
#           вручную через ip link + wg setconf. Быстрый (в ядре), но требует
#           модуль wireguard и пакет wireguard-tools.
#   usque — MASQUE поверх QUIC, статический Go-бинарь в userspace. Не нужен
#           ни kernel-модуль, ни apt-репозиторий. Медленнее и ест CPU.
#
# Контракт (реализация = функция warp_<backend>_<метод>):
#   probe     можно ли поставить на этой ОС/ядре  → 0 да, 1 нет
#   install   установка                           → 0 успех
#   uninstall полное снятие                       → 0 успех
#   up/down   поднять/опустить туннель            → 0 успех
#   iface     имя интерфейса для policy routing   → stdout
#   health    жив ли туннель                      → 0 жив, stdout = внешний IP
#   status    строки для меню и бота              → stdout
#
# ВАЖНО: оба бэкенда используют ОДНО имя интерфейса — warp0. Благодаря этому
# peers.list, все "ip rule ... lookup 200", MASQUERADE -o warp0, FORWARD,
# health-check и статус в боте одинаковы для обоих, а смена бэкенда не требует
# пересоздавать клиентов и трогать их правила.
WARP_IFACE_NAME="warp0"
WARP_BACKEND_FILE="/etc/awg-warp-backend"
WARP_BACKENDS=(wg usque)

# Какой бэкенд активен. Существующие установки файла не имеют — для них wg,
# то есть обратная совместимость сохраняется без миграции.
# Известен ли такой бэкенд. Единственное место со списком — WARP_BACKENDS.
warp_backend_known() {
  local b="$1" known
  for known in "${WARP_BACKENDS[@]}"; do
    [[ "$b" == "$known" ]] && return 0
  done
  return 1
}

warp_backend_current() {
  local b=""
  [[ -f "$WARP_BACKEND_FILE" ]] && b=$(tr -d '[:space:]' < "$WARP_BACKEND_FILE" 2>/dev/null || true)
  if warp_backend_known "$b"; then echo "$b"; else echo "${WARP_BACKENDS[0]}"; fi
}

warp_backend_set() {
  local b="$1"
  warp_backend_known "$b" || { err "Неизвестный бэкенд WARP: $b"; return 1; }
  if ! printf '%s\n' "$b" > "$WARP_BACKEND_FILE" 2>/dev/null; then
    err "Не удалось записать $WARP_BACKEND_FILE"
    return 1
  fi
  chmod 644 "$WARP_BACKEND_FILE" 2>/dev/null || true
  log_info "WARP backend = $b"
  return 0
}

# Диспетчер контракта. Держим его единственной точкой вызова, чтобы добавление
# третьего бэкенда не требовало правок в меню и боте.
_warp_dispatch() {
  local method="$1"; shift
  local backend fn
  backend=$(warp_backend_current)
  fn="warp_${backend}_${method}"
  if ! declare -F "$fn" >/dev/null; then
    err "Бэкенд '$backend' не реализует метод '$method'"
    log_err "warp dispatch: нет функции $fn"
    return 1
  fi
  "$fn" "$@"
}

# Автовыбор бэкенда. Порядок в WARP_BACKENDS не случаен: wg первым, потому что
# kernel-WireGuard быстрее и заметно дешевле по CPU, чем userspace-QUIC. usque
# берётся там, где wg не может — нет модуля ядра, Secure Boot режет неподписанный
# DKMS, контейнер без wireguard. Пишет выбранный бэкенд в stdout, диагностику —
# в stderr, чтобы вызывающий мог показать её пользователю.
warp_backend_autoselect() {
  local b reason
  for b in "${WARP_BACKENDS[@]}"; do
    if declare -F "warp_${b}_probe" >/dev/null; then
      if reason=$("warp_${b}_probe" 2>/dev/null); then
        echo "$b"
        return 0
      fi
      echo "  $b: ${reason:-недоступен}" >&2
    fi
  done
  return 1
}

# Методы контракта аргументов не принимают — состояние берётся из конфигов и
# из активного бэкенда. Понадобятся аргументы — добавим тогда, а не заранее.
warp_probe()     { _warp_dispatch probe;     }
warp_install()   { _warp_dispatch install;   }
warp_uninstall() { _warp_dispatch uninstall; }
warp_up()        { _warp_dispatch up;        }
warp_down()      { _warp_dispatch down;      }
warp_iface()     { _warp_dispatch iface;     }
warp_health()    { _warp_dispatch health;    }
warp_status()    { _warp_dispatch status;    }

# ── Реализация бэкенда wg (существующая, поведение не меняется) ──
# Это тонкие адаптеры над уже работающими _warp_* функциями. Никакой логики
# здесь нет намеренно: задача этапа — вынести под контракт, ничего не сломав.

warp_wg_iface() { echo "$WARP_IFACE_NAME"; }

# Ставится везде, где есть kernel-модуль wireguard и wireguard-tools.
# _warp_ensure_deps сама доставит пакет; проверяем то, что доставить нельзя.
warp_wg_probe() {
  if ! modprobe wireguard 2>/dev/null && [[ ! -d /sys/module/wireguard ]]; then
    echo "нет модуля ядра wireguard"
    return 1
  fi
  return 0
}

warp_wg_install()   { _warp_install_wgcf && _warp_register && _warp_generate_profile; }
warp_wg_uninstall() { _warp_remove; }
warp_wg_up()        { _warp_up; }
warp_wg_down()      { _warp_down; }
warp_wg_status()    { _warp_status; }

# Жив ли туннель. stdout — внешний IP, по которому видно, что выход через
# Cloudflare. Возврат 1 = туннеля нет или он не отвечает.
warp_wg_health() {
    local ip
    ip link show "$WARP_IFACE_NAME" &>/dev/null || return 1
    ip=$(timeout 5 curl -s --interface "$WARP_IFACE_NAME" -4 https://api.ipify.org 2>/dev/null || true)
    [[ -n "$ip" ]] || return 1
    echo "$ip"
    return 0
}

# ── Реализация бэкенда usque (MASQUE поверх QUIC, userspace) ──
# https://github.com/Diniboy1123/usque — статический Go-бинарь, без apt и без
# kernel-модулей. Нужен только /dev/net/tun. Медленнее kernel-WireGuard и
# заметно дороже по CPU (весь QUIC в userspace), поэтому это резервный путь.
USQUE_DIR="/etc/usque"
USQUE_CONF="$USQUE_DIR/config.json"
USQUE_BIN="/usr/local/bin/usque"
USQUE_UP_HOOK="$USQUE_DIR/on-connect.sh"
USQUE_DOWN_HOOK="$USQUE_DIR/on-disconnect.sh"
USQUE_SERVICE="/etc/systemd/system/awg-usque.service"
USQUE_SYSCTL="/etc/sysctl.d/99-awg-usque.conf"
USQUE_LOG="/var/log/awg-usque.log"
# Версия на случай недоступного GitHub API. Сверена с последним релизом
# Diniboy1123/usque 2026-08-13. Проверять при каждом релизе awg2:
#   curl -s https://api.github.com/repos/Diniboy1123/usque/releases/latest | jq -r .tag_name
# Протухшее значение здесь не ломает установку сразу, но тянет старый бинарь.
USQUE_FALLBACK_VER="4.2.1"

warp_usque_iface() { echo "$WARP_IFACE_NAME"; }

# uname -m → суффикс релиза usque. Пустой вывод = архитектура не поддержана.
_usque_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "linux_amd64"   ;;
    aarch64|arm64)  echo "linux_arm64"   ;;
    armv7l|armv7)   echo "linux_armv7"   ;;
    armv6l|armv6)   echo "linux_armv6"   ;;
    armv5*)         echo "linux_armv5"   ;;
    mips64el|mips64le) echo "linux_mips64le" ;;
    mips64)         echo "linux_mips64"  ;;
    mipsel|mipsle)  echo "linux_mipsle"  ;;
    mips)           echo "linux_mips"    ;;
    *) echo "" ;;
  esac
}

# Можно ли поставить usque на этой машине. В отличие от wg, kernel-модуль
# wireguard не нужен — достаточно tun.
warp_usque_probe() {
  if [[ -z "$(_usque_arch)" ]]; then
    echo "архитектура $(uname -m) не поддерживается usque"
    return 1
  fi
  if [[ ! -c /dev/net/tun ]]; then
    modprobe tun 2>/dev/null || true
    if [[ ! -c /dev/net/tun ]]; then
      echo "нет /dev/net/tun (в контейнере он может быть недоступен)"
      return 1
    fi
  fi
  return 0
}

# Сверяет sha256 файла со строкой из checksums.txt.
# $1 = файл, $2 = checksums.txt, $3 = имя ассета в списке.
# Возврат: 0 совпало, 1 не совпало, 2 записи для ассета нет.
#
# Сравниваем хеши напрямую, а не через "sha256sum -c": тот ищет файл по имени
# из checksums.txt, а скачиваем мы во временный u.zip — из-за этого проверка
# падала с «не совпала», хотя сумма была верной.
_usque_verify_sha256() {
  local file="$1" sums="$2" asset="$3" expected actual
  [[ -f "$file" && -f "$sums" ]] || return 2
  expected=$(awk -v f="$asset" '$2 == f { print $1; exit }' "$sums" 2>/dev/null || true)
  [[ -n "$expected" ]] || return 2
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  [[ "$expected" == "$actual" ]] && return 0
  echo "ожидалось: $expected" >&2
  echo "получено:  $actual"  >&2
  return 1
}

# Скачивание бинаря с проверкой sha256 из checksums.txt релиза.
# Без проверки суммы не ставим: это исполняемый файл, работающий от root.
_usque_install_bin() {
  local arch tag ver url tmpd
  arch=$(_usque_arch)
  [[ -n "$arch" ]] || { err "Архитектура $(uname -m) не поддерживается"; return 1; }

  if command -v "$USQUE_BIN" &>/dev/null && "$USQUE_BIN" version &>/dev/null; then
    info "usque уже установлен: $("$USQUE_BIN" version 2>/dev/null | tail -1)"
    return 0
  fi

  command -v unzip &>/dev/null || {
    info "Ставлю unzip (релизы usque — zip-архивы)"
    apt-get install -y -q unzip >/dev/null 2>&1 || { err "unzip не установился"; return 1; }
  }

  info "Узнаём последнюю версию usque..."
  tag=$(curl -4 -fsSL --connect-timeout 8 --max-time 15 \
    "https://api.github.com/repos/Diniboy1123/usque/releases/latest" 2>/dev/null \
    | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1 || true)
  ver="${tag#v}"
  [[ -n "$ver" ]] || { ver="$USQUE_FALLBACK_VER"; warn "GitHub API недоступен, беру версию $ver"; }

  tmpd=$(mktemp -d) || return 1
  url="https://github.com/Diniboy1123/usque/releases/download/v${ver}/usque_${ver}_${arch}.zip"
  info "Скачиваю usque v${ver} (${arch})..."
  if ! curl -4 -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$tmpd/u.zip"; then
    err "Не удалось скачать usque"
    info "Проверь вручную: $url"
    rm -rf "$tmpd"; return 1
  fi

  # Проверка контрольной суммы
  local asset="usque_${ver}_${arch}.zip" vrc
  if curl -4 -fsSL --max-time 30 \
       "https://github.com/Diniboy1123/usque/releases/download/v${ver}/checksums.txt" \
       -o "$tmpd/checksums.txt" 2>/dev/null; then
    _usque_verify_sha256 "$tmpd/u.zip" "$tmpd/checksums.txt" "$asset"; vrc=$?
    case $vrc in
      0) ok "Контрольная сумма совпала" ;;
      2) warn "В checksums.txt нет строки для $asset — ставим без проверки" ;;
      *) err "Контрольная сумма НЕ совпала — файл повреждён или подменён"
         rm -rf "$tmpd"; return 1 ;;
    esac
  else
    warn "checksums.txt не скачался — ставим без проверки суммы"
  fi

  if ! unzip -oq "$tmpd/u.zip" usque -d "$tmpd"; then
    err "Не удалось распаковать архив"; rm -rf "$tmpd"; return 1
  fi
  install -m 0755 "$tmpd/usque" "$USQUE_BIN" || { err "Не удалось установить $USQUE_BIN"; rm -rf "$tmpd"; return 1; }
  rm -rf "$tmpd"

  if ! "$USQUE_BIN" version &>/dev/null; then
    err "Бинарь usque не запускается"; rm -f "$USQUE_BIN"; return 1
  fi
  ok "usque установлен: $("$USQUE_BIN" version 2>/dev/null | tail -1)"
  return 0
}

# Регистрация устройства в Cloudflare. Ключевая ловушка: rate-limit — это НЕ
# ошибка установки, а «приходи позже». Отличаем её от настоящего отказа и
# повторяем с экспоненциальным бэкоффом.
_usque_register() {
  mkdir -p "$USQUE_DIR" && chmod 700 "$USQUE_DIR"

  if [[ -s "$USQUE_CONF" ]]; then
    info "Конфиг usque уже есть — регистрацию пропускаем"
    chmod 600 "$USQUE_CONF" 2>/dev/null || true
    return 0
  fi

  local attempt=0 max=4 delay=5 out rc
  while (( attempt < max )); do
    attempt=$((attempt+1))
    info "Регистрация в Cloudflare, попытка ${attempt}/${max}..."
    out=$("$USQUE_BIN" register --accept-tos --config "$USQUE_CONF" 2>&1); rc=$?

    if [[ $rc -eq 0 && -s "$USQUE_CONF" ]]; then
      chmod 600 "$USQUE_CONF"
      ok "Устройство зарегистрировано, конфиг: $USQUE_CONF"
      return 0
    fi

    if echo "$out" | grep -qiE '429|rate.?limit|too many requests'; then
      warn "Cloudflare ограничил частоту регистраций — это не ошибка установки"
      if (( attempt < max )); then
        info "Жду ${delay}с и пробую снова..."
        sleep "$delay"; delay=$((delay*3))
        continue
      fi
      err "Лимит не снялся за ${max} попыток"
      info "Подожди 10-15 минут и повтори установку — конфиг сохранится"
      return 1
    fi

    warn "Регистрация не удалась: $(echo "$out" | tail -2 | tr '\n' ' ')"
    if (( attempt < max )); then sleep "$delay"; delay=$((delay*3)); fi
  done

  err "Регистрация usque не удалась"
  info "Диагностика: $USQUE_BIN register --accept-tos --config $USQUE_CONF"
  return 1
}

# Хуки on-connect / on-disconnect. usque вызывает их БЕЗ аргументов, контекст
# приходит через окружение: USQUE_EVENT, USQUE_IFACE, USQUE_IPV4, USQUE_IPV6,
# USQUE_ENDPOINT (проверено по usque --help и README v4.2.1).
#
# ГЛАВНОЕ ПРАВИЛО: работаем ТОЛЬКО в таблице 200. Пример из документации самого
# usque делает "ip route del default" и заворачивает default в туннель в main —
# для сервера это означает мгновенную потерю SSH и обрыв AWG. Мы так не делаем.
_usque_write_hooks() {
  mkdir -p "$USQUE_DIR" && chmod 700 "$USQUE_DIR"

  cat > "$USQUE_UP_HOOK" << 'USQUEUPEOF'
#!/bin/bash
# AWG Toolza — usque on-connect. Generated, do not edit manually.
# Идемпотентен: вызывается при каждом реконнекте, поэтому только route replace
# и проверка перед добавлением правил iptables.
set -u

IFACE="${USQUE_IFACE:-warp0}"
SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
PEERS="/etc/wgcf/peers.list"
TABLE=200
LOG="/var/log/awg-usque.log"

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null || true; }

log "on-connect: iface=$IFACE ipv4=${USQUE_IPV4:-?} endpoint=${USQUE_ENDPOINT:-?}"

# Без AWG-сервера split-tunnel бессмысленен
[[ -f "$SERVER_CONF" ]] || { log "нет $SERVER_CONF — выходим"; exit 0; }

addr=$(awk '/^Address/{print $3; exit}' "$SERVER_CONF")
if [[ "$addr" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/([0-9]+)$ ]]; then
  client_net="${BASH_REMATCH[1]}.0/${BASH_REMATCH[2]}"
else
  log "не разобрал Address из $SERVER_CONF — выходим"; exit 0
fi

ext_if=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')

# 1) Маршрут до endpoint Cloudflare — принудительно через ОСНОВНОЙ шлюз.
# В нашей схеме петли и так нет (в main мы не лезем, трафик самого usque идёт
# штатным маршрутом), но это дешёвая страховка на случай более широких правил.
ep="${USQUE_ENDPOINT:-}"
ep="${ep%\]*}"; ep="${ep#[}"        # срезаем скобки IPv6-формы
ep_ip="${ep%%:*}"                    # host из host:port
if [[ "$ep_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && -n "$gw" && -n "$ext_if" ]]; then
  ip route replace "${ep_ip}/32" via "$gw" dev "$ext_if" 2>/dev/null &&     log "endpoint $ep_ip закреплён через $gw dev $ext_if"
fi

# 2) MTU снимаем с живого интерфейса, а не угадываем
mtu=$(cat "/sys/class/net/${IFACE}/mtu" 2>/dev/null || echo "")
log "MTU интерфейса $IFACE = ${mtu:-неизвестен}"

# 2a) Ограничение MSS. Без него мелкие пакеты (DNS, ping) ходят, а TLS-хендшейк
# виснет: клиент шлёт пакеты под СВОЙ MTU, они не влезают в туннель, а PMTU
# discovery через userspace-QUIC часто не работает — ICMP "Fragmentation Needed"
# до клиента не доходит, и получается чёрная дыра. Снаружи выглядит как
# «интернет есть, а сайты не открываются».
# У kernel-WireGuard этой беды нет, поэтому в бэкенде wg клампа и не было.
if [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu > 100 )); then
  mss=$((mtu - 40))   # IPv4 (20) + TCP (20)
  iptables -t mangle -C FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$mss" >/dev/null 2>&1 || \
  iptables -t mangle -A FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$mss" 2>/dev/null && log "MSS ограничен до $mss"
  # Обратное направление: ответы из туннеля клиенту
  iptables -t mangle -C FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$mss" >/dev/null 2>&1 || \
  iptables -t mangle -A FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$mss" 2>/dev/null || true
fi

# 3) Только своя таблица. main НЕ трогаем — иначе теряется доступ к VPS.
src4="${USQUE_IPV4:-}"; src4="${src4%%/*}"
if [[ -n "$src4" ]]; then
  ip route replace default dev "$IFACE" src "$src4" table "$TABLE" 2>/dev/null ||     ip route replace default dev "$IFACE" table "$TABLE"
else
  ip route replace default dev "$IFACE" table "$TABLE"
fi

# 4) NAT: клиенты сидят в приватной подсети, у туннеля внутренний CGNAT-адрес,
# без MASQUERADE их пакеты уйдут наружу с приватным src и будут отброшены.
iptables -t nat -C POSTROUTING -s "$client_net" -o "$IFACE" -j MASQUERADE >/dev/null 2>&1 ||   iptables -t nat -A POSTROUTING -s "$client_net" -o "$IFACE" -j MASQUERADE
# Fallback наружу для клиентов ВНЕ WARP — они идут по main через ext_if
if [[ -n "$ext_if" ]]; then
  iptables -t nat -C POSTROUTING -s "$client_net" -o "$ext_if" -j MASQUERADE >/dev/null 2>&1 ||     iptables -t nat -A POSTROUTING -s "$client_net" -o "$ext_if" -j MASQUERADE
fi
iptables -C FORWARD -i awg0 -o "$IFACE" -j ACCEPT >/dev/null 2>&1 ||   iptables -A FORWARD -i awg0 -o "$IFACE" -j ACCEPT
iptables -C FORWARD -i "$IFACE" -o awg0 -j ACCEPT >/dev/null 2>&1 ||   iptables -A FORWARD -i "$IFACE" -o awg0 -j ACCEPT

# rp_filter loose только на VPN-интерфейсах; all.rp_filter не трогаем, иначе
# ослабнет защита от спуфинга на внешнем интерфейсе.
sysctl -w "net.ipv4.conf.${IFACE}.rp_filter=2" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.awg0.rp_filter=2 >/dev/null 2>&1 || true

# 5) Правила клиентов. Список общий с бэкендом wg — при смене бэкенда
# per-client тумблер не требует пересоздания клиентов.
if [[ -s "$PEERS" ]]; then
  n=0
  while IFS= read -r peer_ip; do
    [[ -z "$peer_ip" ]] && continue
    ip rule del from "$peer_ip" lookup "$TABLE" 2>/dev/null || true
    ip rule add from "$peer_ip" lookup "$TABLE" 2>/dev/null && n=$((n+1))
  done < "$PEERS"
  log "правил для клиентов применено: $n"
fi

log "on-connect: готово"
exit 0
USQUEUPEOF
  chmod 700 "$USQUE_UP_HOOK"

  cat > "$USQUE_DOWN_HOOK" << 'USQUEDOWNEOF'
#!/bin/bash
# AWG Toolza — usque on-disconnect. Generated, do not edit manually.
# ВАЖНО: при обрыве НЕ снимаем правила клиентов. usque запущен с
# --always-reconnect, разрыв H3_NO_ERROR при простое — штатное поведение, и
# снос правил на каждом таком разрыве только устроил бы мигание маршрутов.
# Реальная уборка делается при остановке сервиса (warp_usque_down).
set -u
LOG="/var/log/awg-usque.log"
echo "$(date '+%F %T') on-disconnect: event=${USQUE_EVENT:-?} iface=${USQUE_IFACE:-?}" >> "$LOG" 2>/dev/null || true
exit 0
USQUEDOWNEOF
  chmod 700 "$USQUE_DOWN_HOOK"
  ok "Хуки on-connect / on-disconnect записаны"
  return 0
}

# systemd-юнит. Type=simple: usque держит туннель в foreground.
#
# --no-tunnel-ipv6 обязателен, и сразу по двум причинам:
#  1) IPv6 в туннель мы принципиально не пускаем — у бэкенда wg ровно так же
#     («только IPv4, избегаем утечек»), и таблица 200 содержит только
#     IPv4-маршрут, так что IPv6 внутри туннеля не даёт ничего;
#  2) на хостах с отключённым IPv6 (типовая настройка VPS) ядро отвечает
#     "permission denied" на попытку назначить IPv6-адрес, и usque не может
#     создать TUN вообще. В логе это выглядит как "Are you root?", хотя сервис
#     и так работает от root — сообщение сбивает с толку.
_usque_write_unit() {
  # quic-go упирается в размеры буферов UDP — без этого скорость режется.
  cat > "$USQUE_SYSCTL" << 'EOF'
# AWG Toolza — буферы UDP для quic-go (usque). Без этого скорость режется.
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF
  sysctl -p "$USQUE_SYSCTL" >/dev/null 2>&1 || true

  cat > "$USQUE_SERVICE" << EOF
[Unit]
Description=AWG Toolza — WARP через usque (MASQUE)
Documentation=https://github.com/Diniboy1123/usque
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=${USQUE_CONF}

[Service]
Type=simple
ExecStartPre=-/sbin/sysctl -q -w net.core.rmem_max=7500000 -w net.core.wmem_max=7500000
ExecStart=${USQUE_BIN} nativetun \
  --config ${USQUE_CONF} \
  --interface-name ${WARP_IFACE_NAME} \
  --no-tunnel-ipv6 \
  --always-reconnect \
  --on-connect ${USQUE_UP_HOOK} \
  --on-disconnect ${USQUE_DOWN_HOOK}
Restart=always
RestartSec=5
StandardOutput=append:${USQUE_LOG}
StandardError=append:${USQUE_LOG}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "systemd-юнит записан: awg-usque.service"
  return 0
}

warp_usque_install() {
  hdr "☁  Установка WARP через usque"
  _usque_install_bin || return 1
  _usque_register    || return 1
  _usque_write_hooks || return 1
  _usque_write_unit  || return 1
  systemctl enable awg-usque.service >/dev/null 2>&1 || \
    warn "Автозапуск awg-usque не включился"
  ok "Бэкенд usque готов. Включить туннель — пункт 3"
  return 0
}

warp_usque_up() {
  [[ -s "$USQUE_CONF" ]] || { err "Нет $USQUE_CONF — сначала установка (пункт 1)"; return 1; }
  [[ -x "$USQUE_BIN"  ]] || { err "Нет $USQUE_BIN — сначала установка (пункт 1)"; return 1; }

  # Хуки и юнит перезаписываем на каждом подъёме. Они сгенерированы из этого
  # скрипта, и без перезаписи обновление awg2 не доезжало бы до уже записанных
  # файлов: пользователь ставит новую версию, а на диске остаётся хук от
  # старой. Именно так после обновления терялось ограничение MSS.
  _usque_write_hooks >/dev/null || return 1
  _usque_write_unit  >/dev/null || return 1

  # Первый запуск (файла ещё нет) — включаем всех клиентов по умолчанию.
  # Проверяем именно ОТСУТСТВИЕ файла, а не пустоту: пустой список означает
  # обратное — пользователь сознательно выключил WARP последнему клиенту, и
  # подъём туннеля не должен возвращать всех назад.
  if [[ ! -f "$WARP_PEERS" ]]; then
    info "Список клиентов в Warp не создан — добавляем всех по умолчанию"
    mkdir -p "$WARP_DIR"
    : > "$WARP_PEERS"
    while IFS='|' read -r _name ip; do
      [[ -z "$ip" ]] && continue
      echo "$ip" >> "$WARP_PEERS"
    done < <(_warp_list_awg_clients)
  fi

  info "Запускаю awg-usque.service..."
  systemctl restart awg-usque.service || { err "Сервис не стартовал"; info "Логи: journalctl -u awg-usque -n 40"; return 1; }

  # Ждём появления интерфейса — хук on-connect отработает уже после подключения
  local i
  for i in $(seq 1 20); do
    ip link show "$WARP_IFACE_NAME" &>/dev/null && break
    sleep 1
  done
  if ! ip link show "$WARP_IFACE_NAME" &>/dev/null; then
    err "Интерфейс $WARP_IFACE_NAME не появился за 20 с"
    info "Логи: journalctl -u awg-usque -n 40  и  $USQUE_LOG"
    return 1
  fi

  echo "active" > "$WARP_STATE"
  echo "backend=usque" >> "$WARP_STATE"
  ok "Туннель usque поднят на $WARP_IFACE_NAME"
  info "SSH и серверный трафик идут напрямую"
  return 0
}

warp_usque_down() {
  info "Останавливаю awg-usque.service..."
  systemctl stop awg-usque.service 2>/dev/null || true

  # Уборка ровно того, что ставил хук. main не трогаем — там ничего нашего нет.
  local client_net ext_if
  client_net=$(_warp_get_client_net 2>/dev/null || echo "")
  ext_if=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')

  if [[ -s "$WARP_PEERS" ]]; then
    while IFS= read -r peer_ip; do
      [[ -z "$peer_ip" ]] && continue
      ip rule del from "$peer_ip" lookup 200 2>/dev/null || true
    done < "$WARP_PEERS"
  fi
  ip route flush table 200 2>/dev/null || true

  # Правила ограничения MSS — снимаем все, сколько бы их ни накопилось
  while iptables -t mangle -D FORWARD -o "$WARP_IFACE_NAME" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$(cat "/sys/class/net/${WARP_IFACE_NAME}/mtu" 2>/dev/null || echo 1240)" 2>/dev/null; do :; done
  iptables -t mangle -S FORWARD 2>/dev/null | grep -oP '(?<=^-A FORWARD ).*TCPMSS.*' | while read -r rule; do
    [[ "$rule" == *"$WARP_IFACE_NAME"* ]] || continue
    # shellcheck disable=SC2086
    iptables -t mangle -D FORWARD $rule 2>/dev/null || true
  done

  if [[ -n "$client_net" ]]; then
    iptables -t nat -D POSTROUTING -s "$client_net" -o "$WARP_IFACE_NAME" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i awg0 -o "$WARP_IFACE_NAME" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$WARP_IFACE_NAME" -o awg0 -j ACCEPT 2>/dev/null || true
    # Прямой выход клиентам оставляем — иначе они потеряют интернет совсем
    if [[ -n "$ext_if" ]]; then
      iptables -t nat -C POSTROUTING -s "$client_net" -o "$ext_if" -j MASQUERADE >/dev/null 2>&1 || \
        iptables -t nat -A POSTROUTING -s "$client_net" -o "$ext_if" -j MASQUERADE
    fi
  fi

  rm -f "$WARP_STATE" 2>/dev/null || true
  ok "Туннель usque опущен, клиенты идут напрямую"
  return 0
}

# Жив ли туннель. Отдельно от wg: разрыв H3_NO_ERROR при простое — штатное
# поведение MASQUE, реконнект идёт по исходящему трафику. Поэтому пока сервис
# активен, кратковременное отсутствие ответа падением НЕ считаем.
warp_usque_health() {
  systemctl is-active --quiet awg-usque.service 2>/dev/null || return 1
  ip link show "$WARP_IFACE_NAME" &>/dev/null || return 1
  local ip
  ip=$(timeout 8 curl -s --interface "$WARP_IFACE_NAME" -4 https://api.ipify.org 2>/dev/null || true)
  [[ -n "$ip" ]] || return 1
  echo "$ip"
  return 0
}

warp_usque_status() {
  _warp_sync_peers 2>/dev/null || true

  if [[ -x "$USQUE_BIN" ]]; then
    echo -e "  usque      : ${G}$("$USQUE_BIN" version 2>/dev/null | tail -1)${N}"
  else
    echo -e "  usque      : ${D}не установлен${N}"
    return 0
  fi

  if [[ -s "$USQUE_CONF" ]]; then
    echo -e "  Аккаунт    : ${G}$USQUE_CONF${N}"
  else
    echo -e "  Аккаунт    : ${D}не зарегистрирован${N}"
  fi

  local svc
  svc=$(systemctl is-active awg-usque.service 2>/dev/null || echo "inactive")
  if [[ "$svc" == "active" ]]; then
    echo -e "  Сервис     : ${G}● активен${N}"
  else
    echo -e "  Сервис     : ${D}○ $svc${N}"
  fi

  if ip link show "$WARP_IFACE_NAME" &>/dev/null; then
    local mtu ext
    mtu=$(cat "/sys/class/net/${WARP_IFACE_NAME}/mtu" 2>/dev/null || echo "?")
    echo -e "  Интерфейс  : ${G}● $WARP_IFACE_NAME активен${N} ${D}(MTU $mtu)${N}"
    ext=$(timeout 5 curl -s --interface "$WARP_IFACE_NAME" -4 https://api.ipify.org 2>/dev/null || true)
    [[ -n "$ext" ]] && echo -e "  Внешний IP : ${G}$ext${N}" || \
                       echo -e "  Внешний IP : ${Y}нет ответа${N} ${D}(идёт реконнект?)${N}"
  else
    echo -e "  Интерфейс  : ${D}○ $WARP_IFACE_NAME выключен${N}"
  fi

  local cnt=0
  [[ -f "$WARP_PEERS" ]] && cnt=$(grep -c . "$WARP_PEERS" 2>/dev/null || echo 0)
  echo -e "  Клиентов   : ${W}${cnt}${N} ${D}через Warp${N}"
  return 0
}

# Переключение бэкенда. Клиенты, peers.list и правила не трогаем: имя
# интерфейса общее, поэтому per-client тумблер переживает смену без изменений.
_warp_switch_backend() {
  local target="$1" current was_up=0
  current=$(warp_backend_current)

  if [[ "$target" == "$current" ]]; then
    info "Бэкенд уже $target"
    return 0
  fi

  if ! declare -F "warp_${target}_probe" >/dev/null; then
    err "Бэкенд $target не реализован"; return 1
  fi
  local reason
  if ! reason=$("warp_${target}_probe" 2>/dev/null); then
    err "Бэкенд $target недоступен на этой машине: ${reason:-причина неизвестна}"
    return 1
  fi

  echo ""
  warn "Переключение $current → $target"
  echo -e "  ${D}Клиенты и их настройки WARP сохранятся: список общий,${N}"
  echo -e "  ${D}имя интерфейса тоже. Туннель прервётся на несколько секунд.${N}"
  echo ""
  read_confirm "$(echo -e "${R}  Переключить бэкенд? (введи yes): ${N}")" || \
    { info "Отменено"; return 0; }

  ip link show "$WARP_IFACE_NAME" &>/dev/null && was_up=1

  if [[ $was_up -eq 1 ]]; then
    info "Опускаю туннель на бэкенде $current..."
    warp_down || warn "Не удалось чисто опустить $current — продолжаем"
  fi

  warp_backend_set "$target" || return 1
  ok "Активный бэкенд: $target"

  # Ставим целевой бэкенд, если он ещё не установлен
  if ! warp_install; then
    err "Установка бэкенда $target не удалась"
    warn "Возвращаю активным $current"
    warp_backend_set "$current"
    # Туннель мы опустили выше — обязаны поднять обратно, иначе пользователь
    # остаётся без WARP из-за неудачной попытки переключения.
    if [[ $was_up -eq 1 ]]; then
      info "Поднимаю туннель обратно на бэкенде $current..."
      if warp_up; then
        ok "Туннель восстановлен на бэкенде $current"
      else
        err "Не удалось вернуть туннель — подними вручную: меню Warp → п.3"
      fi
    fi
    return 1
  fi

  if [[ $was_up -eq 1 ]]; then
    info "Поднимаю туннель на бэкенде $target..."
    warp_up || { err "Туннель не поднялся"; return 1; }
  else
    info "Туннель был выключен — включи его пунктом 3"
  fi
  return 0
}

# Меню выбора бэкенда
do_warp_backend_menu() {
  set +e
  while true; do
    clear
    echo ""
    hdr "⚙  Бэкенд WARP"
    echo ""
    local cur; cur=$(warp_backend_current)
    echo -e "  Активный: ${G}${cur}${N}"
    echo ""
    echo -e "  ${W}wg${N}    — kernel WireGuard через wgcf"
    echo -e "         ${D}быстрый, в ядре; нужен модуль wireguard${N}"
    if reason=$(warp_wg_probe 2>/dev/null); then
      echo -e "         ${G}доступен${N}"
    else
      echo -e "         ${R}недоступен:${N} ${D}${reason:-?}${N}"
    fi
    echo ""
    echo -e "  ${W}usque${N} — MASQUE поверх QUIC, userspace"
    echo -e "         ${D}без модулей ядра и DKMS, проходит там где режут WG;${N}"
    echo -e "         ${D}дороже по CPU — на 1 vCPU упрётся в процессор${N}"
    if reason=$(warp_usque_probe 2>/dev/null); then
      echo -e "         ${G}доступен${N}"
    else
      echo -e "         ${R}недоступен:${N} ${D}${reason:-?}${N}"
    fi
    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  1) Переключить на wg"
    echo -e "  2) Переключить на usque"
    echo -e "  3) Выбрать автоматически"
    echo -e "  0) Назад"
    echo ""
    read_choice BE_CHOICE "$(echo -e "${C}  Выбор [0-3]: ${N}")" 0 3 "0"
    case "${BE_CHOICE:-}" in
      1) _warp_switch_backend wg;    read -rp "Enter..." ;;
      2) _warp_switch_backend usque; read -rp "Enter..." ;;
      3)
        local auto
        if auto=$(warp_backend_autoselect 2>/dev/null); then
          info "Автовыбор: $auto"
          _warp_switch_backend "$auto"
        else
          err "Ни один бэкенд не доступен на этой машине"
        fi
        read -rp "Enter..." ;;
      0|"") set -e; return 0 ;;
    esac
  done
  set -e
}

warp_usque_uninstall() {
  warp_usque_down 2>/dev/null || true
  systemctl disable --now awg-usque.service >/dev/null 2>&1 || true
  rm -f "$USQUE_SERVICE" "$USQUE_SYSCTL" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$USQUE_UP_HOOK" "$USQUE_DOWN_HOOK" 2>/dev/null || true
  rm -f "$USQUE_BIN" 2>/dev/null || true
  # config.json НЕ удаляем молча: повторная регистрация тратит лимит Cloudflare
  if [[ -s "$USQUE_CONF" ]]; then
    warn "Аккаунт $USQUE_CONF оставлен"
    info "Повторная регистрация упирается в лимит Cloudflare — если он точно"
    info "не нужен, удали вручную: rm -rf $USQUE_DIR"
  fi
  ok "Бэкенд usque снят"
  return 0
}

# Гарантирует, что есть всё, на чём держится WARP: бинарь wg, ping и каталог
# /etc/wireguard. Раньше wireguard-tools ставились только внутри
# _warp_install_wgcf (пункт 1 меню), а документированный для РФ-хостинга путь
# «импорт профиля (8) → включить туннель (3)» проходил мимо. На минимальных
# образах Ubuntu 26.04 / Debian 13 wireguard-tools не предустановлены — не было
# ни /etc/wireguard (cp профиля падал молча), ни самого wg.
# Идемпотентна: на уже настроенной машине не делает ничего.
_warp_ensure_deps() {
  local missing=()
  command -v wg   &>/dev/null || missing+=("wireguard-tools")
  # ping нужен health-check'у; без него он копит фейлы и сносит рабочий туннель
  command -v ping &>/dev/null || missing+=("iputils-ping")

  if [[ ${#missing[@]} -gt 0 ]]; then
    info "Ставим зависимости WARP: ${missing[*]}"
    apt-get update -y >/dev/null 2>&1 || \
      warn "apt-get update завершился с ошибкой — пробуем ставить как есть"
    if ! apt-get install -y -q "${missing[@]}" >/dev/null 2>&1; then
      err "Не удалось установить: ${missing[*]}"
      info "Поставь вручную и повтори:"
      info "  apt-get update && apt-get install -y ${missing[*]}"
      return 1
    fi
  fi

  # Проверяем результат, а не код возврата apt — пакет мог «успешно»
  # приехать из битого зеркала.
  if ! command -v wg &>/dev/null; then
    err "Бинарь wg недоступен даже после установки wireguard-tools"
    info "WARP поднимает интерфейс через 'wg setconf' — без него никак"
    return 1
  fi

  # /etc/wireguard приходит из пакета wireguard-tools, но создаём и сами —
  # сюда кладётся warp0.conf.
  if [[ ! -d /etc/wireguard ]]; then
    mkdir -p /etc/wireguard || { err "Не удалось создать /etc/wireguard"; return 1; }
    chmod 700 /etc/wireguard
  fi

  # Модуль ядра: warp0 создаётся как 'ip link ... type wireguard'.
  # Обычно автозагружается, но на кастомных ядрах лучше попросить явно.
  modprobe wireguard 2>/dev/null || true

  return 0
}

_warp_install_wgcf() {
  # Зависимости нужны независимо от того, стоит уже wgcf или нет — иначе
  # ранний return ниже увёл бы нас мимо установки wireguard-tools.
  _warp_ensure_deps || return 1

  if command -v wgcf &>/dev/null && wgcf --help &>/dev/null; then
    info "wgcf уже установлен"
    return 0
  fi

  info "Устанавливаем wgcf..."

  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l)  arch="armv7" ;;
    *) err "Неподдерживаемая архитектура: $(uname -m)"; return 1 ;;
  esac

  # ───── версия ─────
  local latest_tag=""
  info "Узнаём последнюю версию wgcf..."
  latest_tag=$(curl -4 -fsSL --connect-timeout 8 --max-time 12 \
    "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null \
    | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1 || echo "")

  local versions=()
  [[ -n "$latest_tag" ]] && versions+=("${latest_tag#v}")
  versions+=("2.2.30" "2.2.29" "2.2.28" "2.2.27" "2.2.26")

  # ───── зеркала ─────
  local mirrors=(
    ""
    "https://ghproxy.net/"
    "https://gh-proxy.com/"
    "https://mirror.ghproxy.com/"
  )

  local downloaded=0

  for ver in "${versions[@]}"; do
    info "Пробуем версию v${ver}..."

    for mp in "${mirrors[@]}"; do
      local url="${mp}https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"

      [[ -z "$mp" ]] && info "  curl ${url:0:80}..." || info "  via ${mp:0:35}..."

      local ok_dl=0

      # ───── CURL ─────
      if curl -4 -L --fail --silent --show-error \
        --connect-timeout 8 \
        --max-time 60 \
        --retry 2 --retry-delay 2 \
        "$url" -o /tmp/wgcf_dl 2>/dev/null; then
        ok_dl=1
      fi

      # ───── WGET fallback ─────
      if [[ $ok_dl -eq 0 ]]; then
        warn "  curl → wget"
        if wget -4 --tries=2 --timeout=10 \
          "$url" -O /tmp/wgcf_dl 2>/dev/null; then
          ok_dl=1
        fi
      fi

      # ───── проверка ─────
      if [[ $ok_dl -eq 1 ]]; then
        local sz
        sz=$(wc -c < /tmp/wgcf_dl 2>/dev/null || echo 0)

        if [[ $sz -lt 1000000 ]]; then
          warn "  файл слишком маленький ($sz)"
          rm -f /tmp/wgcf_dl
          continue
        fi

        # быстрая проверка ELF (без file!)
        if ! head -c 4 /tmp/wgcf_dl | grep -q $'\x7fELF'; then
          warn "  не ELF бинарник"
          rm -f /tmp/wgcf_dl
          continue
        fi

        mv -f /tmp/wgcf_dl /usr/local/bin/wgcf
        chmod +x /usr/local/bin/wgcf

        if /usr/local/bin/wgcf --help &>/dev/null; then
          ok "wgcf установлен (v${ver})"
          downloaded=1
          break
        else
          warn "  бинарь не запускается"
          rm -f /usr/local/bin/wgcf
        fi
      else
        warn "  загрузка не удалась"
        rm -f /tmp/wgcf_dl 2>/dev/null
      fi
    done

    [[ $downloaded -eq 1 ]] && break
  done

  if [[ $downloaded -eq 0 ]]; then
    err "Не удалось скачать wgcf"
    echo ""
    info "Ручная установка:"
    info "  curl -L -o /usr/local/bin/wgcf \\"
    info "    https://github.com/ViRb3/wgcf/releases/download/v2.2.30/wgcf_2.2.30_linux_${arch}"
    info "  chmod +x /usr/local/bin/wgcf"
    return 1
  fi

  return 0
}

_warp_register() {
  mkdir -p "$WARP_DIR"
  cd "$WARP_DIR" || return 1

  if [[ -f "$WARP_ACCOUNT" ]]; then
    info "Аккаунт Warp уже зарегистрирован: $WARP_ACCOUNT"
    return 0
  fi

  info "Регистрируем новый Warp аккаунт..."
  info "Сервер: api.cloudflareclient.com"

  # Pre-check: доступен ли API Cloudflare с этого сервера?
  # Российские VPS часто блокируют api.cloudflareclient.com
  local api_check
  api_check=$(curl -4 -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 8 \
    "https://api.cloudflareclient.com/v0a1922/" 2>/dev/null || echo "000")

  if [[ "$api_check" == "000" ]]; then
    warn "API Cloudflare недоступен с этого сервера"
    info "Это типично для российских VPS — Cloudflare API часто блокируется"
    echo ""
    info "Возможные решения:"
    info "  1. Использовать VPS вне РФ (Hetzner, OVH, DigitalOcean)"
    info "  2. Прописать proxy для wgcf через переменные окружения:"
    info "     export HTTPS_PROXY=http://proxy.example.com:8080"
    info "  3. Использовать готовый wgcf-account.toml с другого сервера"
    echo ""
    read_yesno CONT "$(echo -e "${C}  Продолжить попытку регистрации? [y/N]: ${N}")" "n"
    [[ ! "$CONT" =~ ^[Yy]$ ]] && { warn "Отменено"; return 1; }
  fi

  # Retry с экспоненциальной задержкой — TLS handshake timeout часто решается повтором
  local attempt=0
  local max_attempts=3
  local delay=3

  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt + 1))
    info "Попытка $attempt/$max_attempts..."

    if wgcf register --accept-tos 2>/tmp/wgcf_reg_err; then
      if [[ -f "wgcf-account.toml" ]]; then
        chmod 600 wgcf-account.toml
        ok "Warp аккаунт зарегистрирован (бесплатный)"
        rm -f /tmp/wgcf_reg_err
        return 0
      fi
    fi

    # Анализируем ошибку
    local err_msg
    err_msg=$(grep -E "TLS handshake timeout|connection refused|i/o timeout|no such host" /tmp/wgcf_reg_err 2>/dev/null | head -1 || true)

    if [[ -n "$err_msg" ]] && [[ $attempt -lt $max_attempts ]]; then
      warn "  $err_msg"
      info "  Жду ${delay}с перед повтором..."
      sleep "$delay"
      delay=$((delay * 2))
    elif [[ $attempt -lt $max_attempts ]]; then
      warn "  Регистрация не удалась, повторяю через ${delay}с..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done

  err "Регистрация не удалась после $max_attempts попыток"
  echo ""
  if grep -qE "TLS handshake timeout|connection refused|i/o timeout" /tmp/wgcf_reg_err 2>/dev/null; then
    warn "Cloudflare API недоступен — скорее всего блокировка на уровне ВПС"
    info "Решение: использовать VPS вне РФ или wgcf-account.toml с другого сервера"
  else
    info "Лог ошибки:"
    cat /tmp/wgcf_reg_err 2>/dev/null | head -20
  fi
  rm -f /tmp/wgcf_reg_err
  return 1
}

_warp_apply_license() {
  if [[ ! -f "$WARP_ACCOUNT" ]]; then
    err "Сначала зарегистрируй аккаунт Warp (пункт 1)"
    return 1
  fi

  echo ""
  hdr "★  Активация Warp+"
  echo ""
  echo -e "  ${W}Где взять лицензионный ключ:${N}"
  echo ""
  echo -e "  ${G}1)${N} ${W}Приложение 1.1.1.1${N} (Cloudflare WARP)"
  echo -e "     ${D}→ Шестерёнка → Аккаунт → Ключ${N}"
  echo -e "     ${D}→ Через покупку Warp+ в приложении${N}"
  echo ""
  echo -e "  ${G}2)${N} ${W}Реферальная программа${N} (если ещё работает)"
  echo -e "     ${D}→ В приложении 1.1.1.1 → пригласи друзей${N}"
  echo -e "     ${D}→ +1 ГБ за каждого, до 25 ГБ Warp+ бесплатно${N}"
  echo ""
  echo -e "  ${D}Формат ключа: xxxxxxxx-xxxxxxxx-xxxxxxxx${N}"
  echo ""
  read -rp "$(echo -e "${C}  Лицензионный ключ (Enter = отмена): ${N}")" LICENSE_KEY

  if [[ -z "$LICENSE_KEY" ]]; then
    warn "Отменено — Warp+ не активирован"
    return 0
  fi

  if [[ ! "$LICENSE_KEY" =~ ^[a-zA-Z0-9]+-[a-zA-Z0-9]+-[a-zA-Z0-9]+$ ]]; then
    err "Некорректный формат ключа (должен быть xxxx-xxxx-xxxx)"
    return 1
  fi

  cd "$WARP_DIR" || return 1

  if grep -q "^license_key" wgcf-account.toml; then
    sed -i "s|^license_key = .*|license_key = \"$LICENSE_KEY\"|" wgcf-account.toml
  else
    echo "license_key = \"$LICENSE_KEY\"" >> wgcf-account.toml
  fi
  chmod 600 wgcf-account.toml

  info "Применяем лицензию..."
  if ! wgcf update; then
    err "Не удалось применить лицензию"
    warn "Возможно ключ невалиден или Warp+ уже на другом устройстве"
    return 1
  fi

  # Проверяем что лицензия реально дала Warp+ квоту.
  # wgcf не пишет account_type в toml — нужно запрашивать у Cloudflare через `wgcf status`.
  local account_type status_out
  status_out=$(wgcf status 2>/dev/null || true)
  account_type=$(echo "$status_out" | grep -m1 -oP 'Account type\s*:\s*\K\S+' || true)

  echo ""
  case "$account_type" in
    unlimited)
      ok "Warp+ Unlimited активирован"
      echo "unlimited" > "$WARP_DIR/account_type" 2>/dev/null || true
      ;;
    limited|premium)
      ok "Warp+ активирован (тип: $account_type)"
      echo "$account_type" > "$WARP_DIR/account_type" 2>/dev/null || true
      ;;
    free|"")
      warn "Лицензия применилась, но Warp+ не активен (тип аккаунта: ${account_type:-неизвестно})"
      warn "Возможные причины:"
      warn "  • Ключ уже использован на другом устройстве"
      warn "  • Ключ невалиден или истёк"
      warn "  • Cloudflare временно недоступен"
      rm -f "$WARP_DIR/account_type" 2>/dev/null || true
      ;;
    *)
      ok "Warp+ активирован (тип: $account_type)"
      echo "$account_type" > "$WARP_DIR/account_type" 2>/dev/null || true
      ;;
  esac

  info "Перегенерируем профиль..."
  wgcf generate 2>/dev/null && cp "$WARP_DIR/wgcf-profile.conf" "$WARP_CONF" 2>/dev/null
  return 0
}

_warp_generate_profile() {
  cd "$WARP_DIR" || return 1

  if [[ ! -f "$WARP_ACCOUNT" ]]; then
    err "Нет wgcf-account.toml — сначала зарегистрируйся (пункт 1)"
    return 1
  fi

  info "Генерируем wgcf-profile.conf..."
  if ! wgcf generate; then
    err "wgcf generate провалился"
    return 1
  fi

  if [[ ! -f "wgcf-profile.conf" ]]; then
    err "wgcf-profile.conf не создан"
    return 1
  fi

  cp "wgcf-profile.conf" "$WARP_CONF"
  chmod 600 "$WARP_CONF"

  ok "Профиль создан: $WARP_CONF"
  return 0
}

_warp_get_client_net() {
  if [[ ! -f "$SERVER_CONF" ]]; then
    echo ""
    return 1
  fi
  local addr
  addr=$(awk '/^Address/{print $3; exit}' "$SERVER_CONF")
  if [[ "$addr" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}.0/${BASH_REMATCH[2]}"
    return 0
  fi
  echo ""
  return 1
}

# ── Helpers для выборочного Warp по клиентам ────────────────────

# Возвращает список всех клиентов AWG в формате "name|ip"
_warp_list_awg_clients() {
  [[ ! -f "$SERVER_CONF" ]] && return 0
  awk '
    /^# /{ if ($2 !~ /^expires=/ && $2 !~ /^orig_ips=/) name=$2 }
    /^AllowedIPs/{
      if (name) {
        gsub(/\/32.*/, "", $3)
        print name "|" $3
        name=""
      }
    }
  ' "$SERVER_CONF"
}

# Проверяет включён ли клиент в Warp (по IP)
_warp_peer_enabled() {
  local ip="$1"
  [[ ! -f "$WARP_PEERS" ]] && return 1
  grep -qxF "$ip" "$WARP_PEERS"
}

# Добавляет клиента в Warp
_warp_peer_add() {
  local ip="$1"
  mkdir -p "$WARP_DIR"
  touch "$WARP_PEERS"
  if ! _warp_peer_enabled "$ip"; then
    echo "$ip" >> "$WARP_PEERS"
  fi
}

# Удаляет клиента из Warp
_warp_peer_remove() {
  local ip="$1"
  [[ ! -f "$WARP_PEERS" ]] && return 0
  grep -vxF "$ip" "$WARP_PEERS" > "$WARP_PEERS.tmp" 2>/dev/null || true
  mv "$WARP_PEERS.tmp" "$WARP_PEERS" 2>/dev/null || true
}

# Применить ip rules для всех включённых клиентов
_warp_apply_peer_rules() {
  [[ ! -f "$WARP_PEERS" ]] && return 0
  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    # Удаляем старое правило (если есть) и добавляем заново
    ip rule del from "$ip" lookup 200 2>/dev/null || true
    ip rule add from "$ip" lookup 200
  done < "$WARP_PEERS"
}

# Удалить все ip rules клиентов
_warp_remove_peer_rules() {
  [[ ! -f "$WARP_PEERS" ]] && return 0
  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    ip rule del from "$ip" lookup 200 2>/dev/null || true
  done < "$WARP_PEERS"
}

# Синхронизирует peers.list с реальным server.conf
# Убирает из peers.list те IP'ы, которые уже не существуют в AWG
# (когда клиент был удалён через пункт 3)
# Возвращает количество удалённых "мёртвых" IP'шников
_warp_sync_peers() {
  [[ ! -f "$WARP_PEERS" ]] && return 0
  [[ ! -f "$SERVER_CONF" ]] && {
    # Сервер удалён — чистим всё
    : > "$WARP_PEERS"
    return 0
  }

  # Собираем все живые IP клиентов (без CIDR)
  local live_ips
  live_ips=$(_warp_list_awg_clients | awk -F'|' '{print $2}' | sort -u)

  if [[ -z "$live_ips" ]]; then
    : > "$WARP_PEERS"
    return 0
  fi

  # Перезаписываем peers.list только теми IP, что есть в live_ips
  local tmp="${WARP_PEERS}.tmp"
  : > "$tmp"
  local removed=0
  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    if echo "$live_ips" | grep -qxF "$ip"; then
      echo "$ip" >> "$tmp"
    else
      # Этого IP больше нет в server.conf — убираем правило если warp активен
      if ip link show warp0 &>/dev/null; then
        ip rule del from "$ip" lookup 200 2>/dev/null || true
      fi
      removed=$((removed + 1))
    fi
  done < "$WARP_PEERS"
  mv "$tmp" "$WARP_PEERS"

  return 0
}

# ── Health-check Warp ────────────────────────────────────────────

_warp_health_status() {
  if systemctl is-active --quiet awg-warp-healthcheck.timer 2>/dev/null; then
    echo -e "  Health-check: ${G}● включен${N}"
    if [[ -f "$WARP_HEALTH_LOG" ]]; then
      local last_5
      last_5=$(tail -5 "$WARP_HEALTH_LOG" 2>/dev/null | awk '{print $NF}' | tr '\n' ' ')
      [[ -n "$last_5" ]] && echo -e "  Последние 5: ${C}$last_5${N}"
    fi
  else
    echo -e "  Health-check: ${D}○ выключен${N}"
  fi
}

_warp_health_install() {
  info "Создаём health-check скрипт..."

  cat > "$WARP_HEALTH_SCRIPT" << 'EOSCRIPT'
#!/bin/bash
# AWG Toolza Warp health-check
# Проверяет что warp0 жив, при 3 фейлах подряд — опускает Warp
set -u

LOG="/var/log/awg-warp-health.log"
STATE="/etc/wgcf/state"
FAIL_COUNTER="/tmp/awg-warp-fails"
MAX_FAILS=3

log() { echo "$(date +'%F %T') $*" >> "$LOG"; }

# Если warp0 не существует — health-check бессмысленен
if ! ip link show warp0 &>/dev/null; then
  log "warp0 не существует - skip"
  exit 0
fi

# Без ping проверять нечем. Раньше это молча копило фейлы и через 3 цикла
# сносило РАБОЧИЙ туннель. Отсутствие утилиты — не отказ Warp: выходим.
if ! command -v ping >/dev/null 2>&1; then
  log "ping недоступен (нет iputils-ping) - skip, failover НЕ выполняется"
  exit 0
fi

# Ping через warp0
if ping -c1 -W2 -I warp0 1.1.1.1 &>/dev/null; then
  log "OK"
  echo "0" > "$FAIL_COUNTER"
  exit 0
fi

# Fail
fails=$(cat "$FAIL_COUNTER" 2>/dev/null || echo "0")
fails=$((fails + 1))
echo "$fails" > "$FAIL_COUNTER"
log "FAIL ($fails/$MAX_FAILS)"

if [[ $fails -ge $MAX_FAILS ]]; then
  log "ALERT: Warp недоступен $MAX_FAILS раз подряд — failover"

  # Читаем state для отката
  client_net=$(grep "^client_net=" "$STATE" 2>/dev/null | cut -d= -f2 || true)
  iface=$(grep "^iface=" "$STATE" 2>/dev/null | cut -d= -f2 || true)

  # Удаляем правила для всех включённых клиентов
  if [[ -f /etc/wgcf/peers.list ]]; then
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      ip rule del from "$ip" lookup 200 2>/dev/null
    done < /etc/wgcf/peers.list
  fi
  # На случай если есть правило для всей подсети
  [[ -n "$client_net" ]] && ip rule del from "$client_net" lookup 200 2>/dev/null

  ip route flush table 200 2>/dev/null

  # Убираем iptables правила warp0
  if [[ -n "$client_net" ]]; then
    iptables -t nat -D POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i awg0 -o warp0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i warp0 -o awg0 -j ACCEPT 2>/dev/null

    # Восстанавливаем MASQUERADE через основной интерфейс
    if [[ -n "$iface" ]]; then
      iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE >/dev/null 2>&1 || \
        iptables -t nat -A POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE
    fi
  fi

  # Опускаем warp0
  ip link delete warp0 2>/dev/null

  log "FAILOVER завершён — трафик AWG идёт напрямую"
  echo "failed" > "$STATE.failed"
fi

exit 0
EOSCRIPT
  chmod +x "$WARP_HEALTH_SCRIPT"

  cat > "$WARP_HEALTH_SERVICE" << EOF
[Unit]
Description=AWG Toolza Warp health-check
After=network.target

[Service]
Type=oneshot
ExecStart=$WARP_HEALTH_SCRIPT
EOF

  cat > "$WARP_HEALTH_TIMER" << EOF
[Unit]
Description=AWG Toolza Warp health-check timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
Unit=awg-warp-healthcheck.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  if ! systemctl enable --now awg-warp-healthcheck.timer >/dev/null 2>&1; then
    err "Не удалось включить awg-warp-healthcheck.timer"
    info "Проверь: systemctl status awg-warp-healthcheck.timer"
    return 1
  fi
  ok "Health-check установлен (проверка каждые 60 сек)"
  return 0
}

_warp_health_remove() {
  systemctl disable --now awg-warp-healthcheck.timer 2>/dev/null || true
  rm -f "$WARP_HEALTH_SCRIPT" "$WARP_HEALTH_TIMER" "$WARP_HEALTH_SERVICE"
  systemctl daemon-reload 2>/dev/null
  ok "Health-check удалён"
  return 0
}

_warp_health_toggle() {
  if systemctl is-active --quiet awg-warp-healthcheck.timer 2>/dev/null; then
    info "Выключаем health-check..."
    _warp_health_remove
  else
    info "Включаем health-check..."
    _warp_health_install
  fi
}

# ── Меню управления клиентами в Warp ────────────────────────────

do_warp_peers_menu() {
  set +e
  while true; do
    # Синхронизируем при каждом входе — на случай если клиенты были удалены
    _warp_sync_peers 2>/dev/null || true

    clear
    echo ""
    hdr "⚙ Клиенты в Warp туннеле"
    echo ""

    local clients=()
    while IFS='|' read -r name ip; do
      [[ -z "$name" || -z "$ip" ]] && continue
      clients+=("$name|$ip")
    done < <(_warp_list_awg_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
      warn "AWG клиентов нет — добавь через пункт 3"
      read -rp "Enter..."
      set -e
      return 0
    fi

    local i=1
    for entry in "${clients[@]}"; do
      local name="${entry%|*}"
      local ip="${entry##*|}"
      if _warp_peer_enabled "$ip"; then
        echo -e "  ${G}[$i]${N} $name  ${D}$ip${N}  ${C}☁ через Warp${N}"
      else
        echo -e "  ${G}[$i]${N} $name  ${D}$ip${N}  → напрямую"
      fi
      i=$((i + 1))
    done

    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  Введи номер клиента для переключения"
    echo -e "  a — все через Warp, n — все напрямую"
    echo -e "  0 — назад"
    echo ""
    local _peer_max=${#clients[@]}
    read_choice PEER_CHOICE "$(echo -e "${C}  Выбор [0-${_peer_max}, a, n]: ${N}")" \
      0 "$_peer_max" "0" "a|n"

    case "${PEER_CHOICE:-}" in
      0|"") set -e; return 0 ;;
      a|A)
        for entry in "${clients[@]}"; do
          local ip="${entry##*|}"
          _warp_peer_add "$ip"
        done
        # Если warp0 активен — применить правила сейчас
        if ip link show warp0 &>/dev/null; then
          _warp_apply_peer_rules
        fi
        ok "Все клиенты включены в Warp"
        sleep 1
        ;;
      n|N)
        for entry in "${clients[@]}"; do
          local ip="${entry##*|}"
          _warp_peer_remove "$ip"
        done
        if ip link show warp0 &>/dev/null; then
          _warp_remove_peer_rules
        fi
        ok "Все клиенты идут напрямую"
        sleep 1
        ;;
      *)
        if [[ "$PEER_CHOICE" =~ ^[0-9]+$ ]] && [[ $PEER_CHOICE -ge 1 && $PEER_CHOICE -le ${#clients[@]} ]]; then
          local idx=$((PEER_CHOICE - 1))
          local entry="${clients[$idx]}"
          local name="${entry%|*}"
          local ip="${entry##*|}"
          if _warp_peer_enabled "$ip"; then
            _warp_peer_remove "$ip"
            if ip link show warp0 &>/dev/null; then
              ip rule del from "$ip" lookup 200 2>/dev/null || true
            fi
            ok "$name → напрямую"
          else
            _warp_peer_add "$ip"
            if ip link show warp0 &>/dev/null; then
              ip rule del from "$ip" lookup 200 2>/dev/null || true
              ip rule add from "$ip" lookup 200
            fi
            ok "$name → через Warp"
          fi
          sleep 1
        else
          warn "Неверный выбор"
          sleep 1
        fi
        ;;
    esac
  done
  set -e
}

_warp_up() {
  # warp0 поднимается через 'wg setconf' — без wireguard-tools дальше нет смысла.
  # Проверяем здесь, а не полагаемся на то, что пользователь прошёл пункт 1.
  _warp_ensure_deps || return 1

  if [[ ! -f "$WARP_CONF" ]]; then
    err "Конфиг Warp не найден ($WARP_CONF)"
    info "Зарегистрируй аккаунт (пункт 1) либо импортируй готовый профиль (пункт 8)"
    return 1
  fi

  if ip link show warp0 &>/dev/null; then
    info "warp0 уже активен"
    return 0
  fi

  # Получаем CLIENT_NET ДО поднятия интерфейса — без AWG нет смысла делать split-tunnel
  local client_net iface
  client_net=$(_warp_get_client_net 2>/dev/null || echo "")
  iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}' || echo "eth0")

  if [[ -z "$client_net" ]]; then
    err "AWG сервер не настроен"
    info "Сначала создай AWG сервер (Сервер → п.2), потом включай Warp"
    return 1
  fi

  info "Парсим конфиг Warp..."
  # Извлекаем поля из wgcf-profile.conf для ручной настройки
  local warp_priv warp_pub warp_endpoint warp_addr4 warp_mtu addr_line
  warp_priv=$(awk -F' = ' '/^PrivateKey/{print $2; exit}' "$WARP_CONF")
  warp_pub=$(awk -F' = ' '/^PublicKey/{print $2; exit}' "$WARP_CONF")
  warp_endpoint=$(awk -F' = ' '/^Endpoint/{print $2; exit}' "$WARP_CONF")
  warp_mtu=$(awk -F' = ' '/^MTU/{print $2; exit}' "$WARP_CONF")
  [[ -z "$warp_mtu" ]] && warp_mtu=1280

  # Address строка типа: "172.16.0.2/32, 2606:4700:110:8419::/128"
  # Берём ТОЛЬКО IPv4 — IPv6 от Cloudflare нам не нужен (избегаем утечек)
  addr_line=$(awk -F' = ' '/^Address/{print $2; exit}' "$WARP_CONF")
  warp_addr4=""
  local IFS=','
  for a in $addr_line; do
    a="${a#"${a%%[![:space:]]*}"}"
    a="${a%"${a##*[![:space:]]}"}"
    if [[ "$a" =~ \. ]] && [[ ! "$a" =~ : ]]; then
      warp_addr4="$a"
    fi
  done
  unset IFS

  if [[ -z "$warp_priv" || -z "$warp_pub" || -z "$warp_endpoint" || -z "$warp_addr4" ]]; then
    err "Не удалось распарсить конфиг Warp"
    info "PrivateKey: ${warp_priv:+есть} ${warp_priv:-нет}"
    info "PublicKey: ${warp_pub:+есть} ${warp_pub:-нет}"
    info "Endpoint: ${warp_endpoint:-нет}"
    info "Address4: ${warp_addr4:-нет}"
    return 1
  fi

  info "Поднимаем warp0 (split-tunnel: только $client_net)..."
  info "  IP4: $warp_addr4"
  info "  Endpoint: $warp_endpoint"
  info "  MTU: $warp_mtu"

  # Создаём интерфейс
  ip link add dev warp0 type wireguard 2>&1 || { err "Не удалось создать warp0"; return 1; }

  # Конфигурируем приватный ключ + peer
  # ВАЖНО: AllowedIPs = 0.0.0.0/0 нужен только на стороне peer config wireguard
  # это значит "куда МЫ шлём трафик через peer", НЕ маршрутизация ОС
  # Временный конфиг кладём в /etc/wireguard, а НЕ в /tmp. На Ubuntu 26.04
  # пакетный wg не смог прочитать файл из /tmp — "fopen: Permission denied",
  # при том что собранный из исходников awg тот же /tmp читает спокойно
  # (похоже на AppArmor-профиль пакета wireguard-tools). Каталог /etc/wireguard
  # создаётся с правами 700 и принадлежит root — не менее строго, чем /tmp,
  # и это канонический путь, откуда wg читает конфиги.
  local tmp_wg_conf="/etc/wireguard/.warp0.setconf.$$"
  rm -f "$tmp_wg_conf"
  cat > "$tmp_wg_conf" << EOF
[Interface]
PrivateKey = $warp_priv

[Peer]
PublicKey = $warp_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $warp_endpoint
EOF
  chmod 600 "$tmp_wg_conf" 2>/dev/null || true
  if ! wg setconf warp0 "$tmp_wg_conf"; then
    err "wg setconf warp0 failed (конфиг: $tmp_wg_conf)"
    info "Проверь: wg setconf warp0 $tmp_wg_conf"
    info "Если тут 'fopen: Permission denied' — смотри dmesg | grep -i apparmor"
    rm -f "$tmp_wg_conf"
    ip link delete warp0 2>/dev/null
    return 1
  fi
  rm -f "$tmp_wg_conf"

  # Только IPv4 — IPv6 от Warp нам не нужен (избегаем утечек)
  ip -4 address add "$warp_addr4" dev warp0 2>&1

  # MTU и UP
  ip link set mtu "$warp_mtu" up dev warp0 || { err "ip link set up warp0 failed"; ip link delete warp0; return 1; }

  ok "warp0 активен"

  # ── SPLIT-TUNNEL: маршруты только для AWG подсети ──
  # БЕЗ policy routing (fwmark) — тогда SSH не сломается
  # MASQUERADE на warp0 для трафика из AWG подсети

  info "Настраиваем split-tunnel для $client_net..."

  # ВАЖНО: НЕ удаляем eth0-MASQUERADE — оно нужно как fallback
  # для клиентов которые НЕ в warp_peers (идут через main table → eth0).
  # Иначе их пакеты уйдут наружу с приватным src (10.x.x.x) → дропнутся провайдером.
  # Гарантируем что eth0-MASQUERADE существует:
  iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE

  # Добавляем MASQUERADE через warp0 (для клиентов с ip rule lookup 200)
  iptables -t nat -C POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE

  # FORWARD правила
  iptables -C FORWARD -i awg0 -o warp0 -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -i awg0 -o warp0 -j ACCEPT
  iptables -C FORWARD -i warp0 -o awg0 -j ACCEPT >/dev/null 2>&1 || \
    iptables -A FORWARD -i warp0 -o awg0 -j ACCEPT

  # rp_filter loose mode только для VPN интерфейсов
  # ВАЖНО: НЕ трогаем .all.rp_filter — иначе eth0 тоже станет loose, ослабнет защита от spoofing
  # Linux применяет max(all.rp_filter, iface.rp_filter), значит для warp0/awg0 будет loose, для eth0 — strict
  sysctl -w net.ipv4.conf.warp0.rp_filter=2 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.awg0.rp_filter=2 >/dev/null 2>&1 || true

  # Policy routing: создаём отдельную таблицу 200 для трафика выбранных клиентов
  # ВАЖНО: src обязательно указать иначе kernel не сможет маршрутизировать (warp0 имеет /32)
  ip route flush table 200 2>/dev/null || true
  ip route add default dev warp0 src "${warp_addr4%/*}" table 200

  # Сначала синхронизируем — убираем мёртвые IP (удалённых клиентов)
  _warp_sync_peers 2>/dev/null || true

  # Первый запуск (файла ещё нет) — заполняем всеми клиентами по умолчанию.
  # Именно отсутствие файла, а не пустота: пустой список значит, что WARP
  # сознательно выключен всем, и подъём не должен это отменять.
  if [[ ! -f "$WARP_PEERS" ]]; then
    info "Список клиентов в Warp не создан — добавляем всех по умолчанию"
    mkdir -p "$WARP_DIR"
    : > "$WARP_PEERS"
    while IFS='|' read -r name ip; do
      [[ -z "$ip" ]] && continue
      echo "$ip" >> "$WARP_PEERS"
    done < <(_warp_list_awg_clients)
  fi

  # Убираем старое правило для всей подсети (если осталось от прошлых версий)
  ip rule del from "$client_net" lookup 200 2>/dev/null || true

  # Применяем правила для каждого включённого клиента
  _warp_apply_peer_rules

  local peer_count
  peer_count=$(wc -l < "$WARP_PEERS" 2>/dev/null || echo 0)

  # Сохраняем состояние
  echo "active" > "$WARP_STATE"
  echo "client_net=$client_net" >> "$WARP_STATE"
  echo "iface=$iface" >> "$WARP_STATE"

  ok "Split-tunnel активен: $peer_count клиент(ов) через Warp"
  info "SSH и серверный трафик идут напрямую"
  info "Управление клиентами в Warp: Туннели (5) → Warp → п.6"

  # ── Автозапуск после ребута ──────────────────────────────
  # Создаём systemd-юнит который при загрузке вызовет awg2 и тот
  # увидит state=active → выполнит _warp_up автоматически.
  # Юнит зависит от awg-quick@awg0 — WARP может подняться только
  # после AWG-сервера (нужен client_net).
  _warp_install_autostart 2>/dev/null || warn "Автозапуск WARP не настроен (не критично)"

  return 0
}

# Создаёт и включает systemd-юнит для автозапуска WARP при ребуте.
# Юнит запускает /etc/wgcf/warp-autostart.sh — лёгкий скрипт-обёртка,
# который проверяет state и вызывает основной awg2 для поднятия.
_warp_install_autostart() {
  local script_path="/etc/wgcf/warp-autostart.sh"
  local unit_path="/etc/systemd/system/awg-warp.service"

  mkdir -p /etc/wgcf

  # Скрипт-обёртка — повторяет логику _warp_up, читая state с диска.
  # Самодостаточный (не зависит от awg2.sh) чтобы при удалении/обновлении
  # скрипта автозапуск продолжал работать.
  cat > "$script_path" << 'WARPAUTOEOF'
#!/bin/bash
# AWG Toolza — WARP autostart at boot
# Generated by _warp_install_autostart, do not edit manually.
set -u

WARP_CONF="/etc/wireguard/warp0.conf"
WARP_STATE="/etc/wgcf/state"
WARP_PEERS="/etc/wgcf/peers.list"
SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"

# Если WARP не был активен до ребута — выходим
[[ ! -f "$WARP_STATE" ]] && exit 0
[[ "$(head -1 "$WARP_STATE" 2>/dev/null)" != "active" ]] && exit 0

# WARP конфиг обязателен
[[ ! -f "$WARP_CONF" ]] && { echo "warp0.conf missing" >&2; exit 1; }

# Получаем client_net из awg0.conf (свежее чем из state)
[[ ! -f "$SERVER_CONF" ]] && { echo "awg0.conf missing — WARP requires AWG" >&2; exit 1; }
addr=$(awk -F'=' '/^Address/{gsub(/ /,"",$2); print $2; exit}' "$SERVER_CONF")
[[ -z "$addr" ]] && { echo "cannot parse Address from awg0.conf" >&2; exit 1; }
# 10.x.x.1/24 → 10.x.x.0/24
ip_part="${addr%/*}"
mask="${addr#*/}"
client_net="$(echo "$ip_part" | awk -F. '{print $1"."$2"."$3".0/'"$mask"'"}')"

# Главный интерфейс (eth0/ens3/etc) — берём из default route
iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
[[ -z "$iface" ]] && iface="eth0"

# Парсим WARP-конфиг
warp_priv=$(awk -F' = ' '/^PrivateKey/{print $2; exit}' "$WARP_CONF")
warp_pub=$(awk -F' = ' '/^PublicKey/{print $2; exit}' "$WARP_CONF")
warp_endpoint=$(awk -F' = ' '/^Endpoint/{print $2; exit}' "$WARP_CONF")
warp_mtu=$(awk -F' = ' '/^MTU/{print $2; exit}' "$WARP_CONF")
[[ -z "$warp_mtu" ]] && warp_mtu=1280

addr_line=$(awk -F' = ' '/^Address/{print $2; exit}' "$WARP_CONF")
warp_addr4=""
IFS=','
for a in $addr_line; do
  a="${a#"${a%%[![:space:]]*}"}"
  a="${a%"${a##*[![:space:]]}"}"
  if [[ "$a" =~ \. ]] && [[ ! "$a" =~ : ]]; then warp_addr4="$a"; fi
done
unset IFS

[[ -z "$warp_priv" || -z "$warp_pub" || -z "$warp_endpoint" || -z "$warp_addr4" ]] && {
  echo "warp config parse failed" >&2; exit 1; }

# Если warp0 уже существует — выходим (повторный запуск)
ip link show warp0 &>/dev/null && exit 0

# Поднимаем warp0
ip link add dev warp0 type wireguard || exit 1

# Не /tmp: пакетный wg на Ubuntu 26.04 не читает оттуда конфиг
# ("fopen: Permission denied"). /etc/wireguard — каталог root:700.
tmp_conf="/etc/wireguard/.warp0.setconf.boot.$$"
rm -f "$tmp_conf"
cat > "$tmp_conf" << EOC
[Interface]
PrivateKey = $warp_priv

[Peer]
PublicKey = $warp_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $warp_endpoint
EOC
chmod 600 "$tmp_conf" 2>/dev/null || true
wg setconf warp0 "$tmp_conf" || { rm -f "$tmp_conf"; ip link delete warp0; exit 1; }
rm -f "$tmp_conf"

ip -4 address add "$warp_addr4" dev warp0 2>/dev/null || true
ip link set mtu "$warp_mtu" up dev warp0 || { ip link delete warp0; exit 1; }

# rp_filter loose для VPN-интерфейсов
sysctl -w net.ipv4.conf.warp0.rp_filter=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.awg0.rp_filter=2 >/dev/null 2>&1 || true

# MASQUERADE: warp0 для пометленных + eth0 для остальных (fallback)
iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE >/dev/null 2>&1 || \
  iptables -t nat -A POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE
iptables -t nat -C POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE >/dev/null 2>&1 || \
  iptables -t nat -A POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE
iptables -C FORWARD -i awg0 -o warp0 -j ACCEPT >/dev/null 2>&1 || \
  iptables -A FORWARD -i awg0 -o warp0 -j ACCEPT
iptables -C FORWARD -i warp0 -o awg0 -j ACCEPT >/dev/null 2>&1 || \
  iptables -A FORWARD -i warp0 -o awg0 -j ACCEPT

# Policy routing — таблица 200
ip route flush table 200 2>/dev/null || true
ip route add default dev warp0 src "${warp_addr4%/*}" table 200

# Восстанавливаем peer-rules для клиентов из peers.list
if [[ -s "$WARP_PEERS" ]]; then
  while IFS= read -r peer_ip; do
    [[ -z "$peer_ip" ]] && continue
    ip rule add from "$peer_ip" lookup 200 2>/dev/null || true
  done < "$WARP_PEERS"
fi

exit 0
WARPAUTOEOF
  chmod +x "$script_path"

  # systemd unit — стартует после awg-quick@awg0 (нужен client_net)
  cat > "$unit_path" << EOF
[Unit]
Description=AWG Toolza — WARP split-tunnel autostart
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=/etc/wgcf/state
ConditionPathExists=/etc/wireguard/warp0.conf
ConditionPathExists=/etc/amnezia/amneziawg/awg0.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${script_path}
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload 2>/dev/null
  systemctl enable awg-warp.service >/dev/null 2>&1 && \
    info "Автозапуск WARP включён (systemd: awg-warp.service)"
}

_warp_down() {
  if [[ -f "$WARP_STATE" ]]; then
    local client_net iface
    client_net=$(grep "^client_net=" "$WARP_STATE" 2>/dev/null | cut -d= -f2 || true)
    iface=$(grep "^iface=" "$WARP_STATE" 2>/dev/null | cut -d= -f2 || true)

    # Убираем правила для всех включённых клиентов
    _warp_remove_peer_rules

    if [[ -n "$client_net" ]]; then
      # Убираем legacy правила (если остались)
      ip rule del from "$client_net" lookup 200 2>/dev/null || true
      ip rule del from "$client_net" table 200 2>/dev/null || true
      ip route flush table 200 2>/dev/null || true

      # Убираем iptables правила warp0
      iptables -t nat -D POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE 2>/dev/null || true
      iptables -D FORWARD -i awg0 -o warp0 -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i warp0 -o awg0 -j ACCEPT 2>/dev/null || true

      # Восстанавливаем MASQUERADE через основной интерфейс
      if [[ -n "$iface" ]]; then
        iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE >/dev/null 2>&1 || \
          iptables -t nat -A POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE
      fi
    fi
  fi

  # Опускаем интерфейс
  if ip link show warp0 &>/dev/null; then
    info "Удаляем warp0..."
    ip link delete warp0 2>/dev/null || true
  fi

  # Отключаем автозапуск (юнит остаётся на диске для быстрого re-enable)
  if systemctl is-enabled --quiet awg-warp.service 2>/dev/null; then
    systemctl disable awg-warp.service >/dev/null 2>&1 || true
    info "Автозапуск WARP отключён"
  fi

  rm -f "$WARP_STATE" 2>/dev/null
  ok "Warp выключен — трафик AWG идёт напрямую"
  return 0
}

# ── warpscout: сканер эндпоинтов Cloudflare WARP ──────────────────
# Заменяет прежний перебор фиксированного списка IP:порт (проверка «пришли ли
# байты» после ping) на настоящий сканер: реальный handshake на каждый
# эндпоинт, определение видимой страны выхода (SEEN AS) и edge-узла Cloudflare
# (NODE), с фильтрами по стране/узлу. https://github.com/vernette/warpscout

_warpscout_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "" ;;
  esac
}

# Ставит/обновляет warpscout через официальный install.sh проекта (сам
# определяет ОС/архитектуру и качает нужный релиз с GitHub) — не дублируем
# эту логику руками, чтобы не разойтись с апстримом при новых архитектурах.
_warpscout_install_bin() {
  if [[ -z "$(_warpscout_arch)" ]]; then
    err "Архитектура $(uname -m) не поддерживается warpscout (нужна amd64 или arm64)"
    return 1
  fi

  if command -v "$WARPSCOUT_BIN" &>/dev/null && "$WARPSCOUT_BIN" version &>/dev/null; then
    info "warpscout уже установлен: $("$WARPSCOUT_BIN" version 2>/dev/null)"
    return 0
  fi

  info "Ставлю warpscout в $WARPSCOUT_BIN..."
  # INSTALL_DIR должен быть в окружении sh, а не curl — раздельные команды
  # в пайпе не делят env между собой, поэтому переменную ставим перед всей
  # конструкцией, а не префиксом к curl.
  if ! (export INSTALL_DIR="$(dirname "$WARPSCOUT_BIN")"
        curl -4 -fsSL --connect-timeout 10 --max-time 60 \
          https://raw.githubusercontent.com/vernette/warpscout/master/install.sh \
          | sh -s -- -y); then
    err "Установка warpscout не удалась"
    info "Вручную: curl -fsSL https://raw.githubusercontent.com/vernette/warpscout/master/install.sh | sh"
    return 1
  fi

  if ! "$WARPSCOUT_BIN" version &>/dev/null; then
    # install.sh мог всё же положить бинарь в свой собственный дефолт
    # (например, если export не сработал в каком-то экзотическом shell) —
    # прежде чем падать, поищем его по PATH и переиспользуем найденный путь.
    local _found
    _found=$(command -v warpscout 2>/dev/null || true)
    if [[ -n "$_found" && "$_found" != "$WARPSCOUT_BIN" ]]; then
      warn "Бинарь встал в $_found, а не в $WARPSCOUT_BIN — использую найденный путь"
      WARPSCOUT_BIN="$_found"
    fi
  fi

  if ! "$WARPSCOUT_BIN" version &>/dev/null; then
    err "Бинарь warpscout не запускается после установки"
    info "Проверь вручную: command -v warpscout && warpscout version"
    return 1
  fi
  ok "warpscout установлен: $("$WARPSCOUT_BIN" version 2>/dev/null)"
  return 0
}

# Отдельный WARP-аккаунт для сканера — не тот же, что wgcf-account.toml выше.
_warpscout_register() {
  mkdir -p "$WARPSCOUT_DIR" && chmod 700 "$WARPSCOUT_DIR"

  if [[ -s "$WARPSCOUT_ACCOUNT" ]]; then
    info "Аккаунт warpscout уже есть — регистрацию пропускаем"
    chmod 600 "$WARPSCOUT_ACCOUNT" 2>/dev/null || true
    return 0
  fi

  info "Регистрирую аккаунт warpscout в Cloudflare..."
  if ! "$WARPSCOUT_BIN" register -a "$WARPSCOUT_ACCOUNT"; then
    err "Регистрация warpscout не удалась"
    return 1
  fi
  chmod 600 "$WARPSCOUT_ACCOUNT" 2>/dev/null || true
  ok "Аккаунт создан: $WARPSCOUT_ACCOUNT"
  return 0
}

# Убеждается, что бинарь и аккаунт на месте — ставит/регистрирует при
# необходимости. Возврат 1 = продолжать нельзя, вызывающий должен выйти.
_warpscout_ensure_ready() {
  command -v "$WARPSCOUT_BIN" &>/dev/null || _warpscout_install_bin || return 1
  [[ -s "$WARPSCOUT_ACCOUNT" ]] || _warpscout_register || return 1
  return 0
}

# Применяет найденный warpscout'ом endpoint к живому warp0 + сохраняет
# в профиль/конфиг, чтобы он пережил рестарт — тем же способом, что раньше
# делал _warp_endpoint_finder.
_warpscout_apply_endpoint() {
  local found_endpoint="$1"
  [[ -n "$found_endpoint" ]] || { err "Пустой endpoint — нечего применять"; return 1; }

  if [[ -f "$WARP_PROFILE" ]]; then
    sed -i "s|^Endpoint = .*|Endpoint = $found_endpoint|" "$WARP_PROFILE"
  fi
  if [[ -f "$WARP_CONF" ]]; then
    sed -i "s|^Endpoint = .*|Endpoint = $found_endpoint|" "$WARP_CONF"
  fi

  if ip link show warp0 &>/dev/null; then
    local peer_pub
    peer_pub=$(wg show warp0 peers 2>/dev/null | head -1)
    if [[ -n "$peer_pub" ]]; then
      wg set warp0 peer "$peer_pub" endpoint "$found_endpoint" 2>/dev/null || true
    fi
  fi

  ok "Endpoint применён: $found_endpoint"
  info "Проверяем туннель..."
  if timeout 5 ping -c 2 -W 2 -I warp0 1.1.1.1 &>/dev/null; then
    ok "Туннель работает! Через Warp проходит трафик"
  else
    warn "Handshake есть, но ping ещё не идёт. Подожди 10-30 секунд, либо перезапусти (4 → 3)"
  fi
  return 0
}

# Режим 1: сканирует и сразу применяет лучший найденный endpoint (-best).
_warpscout_scan_auto() {
  _warpscout_ensure_ready || return 1

  echo ""
  hdr "🛰  warpscout — автовыбор лучшего endpoint"
  echo ""
  local _filters=()
  local _country
  read -rp "$(echo -e "${C}  Ограничить страной выхода (напр. DE,NL, Enter — без фильтра): ${N}")" _country
  [[ -n "$_country" ]] && _filters+=(-country "$_country")

  info "Сканирую (может занять минуту)..."
  local best
  best=$("$WARPSCOUT_BIN" scan -p awg -a "$WARPSCOUT_ACCOUNT" -best "${_filters[@]}" 2>/dev/null)
  if [[ -z "$best" ]]; then
    err "Ни один endpoint не прошёл сканирование"
    warn "Скорее всего провайдер блокирует UDP-трафик к Cloudflare, либо фильтр отсёк всё"
    info "Попробуй без фильтра по стране, либо: п.4 — выключить Warp"
    return 1
  fi

  ok "Лучший endpoint: $best"
  _warpscout_apply_endpoint "$best"
}

# Режим 2: показывает таблицу всех рабочих endpoint'ов, даёт выбрать вручную.
_warpscout_scan_manual() {
  _warpscout_ensure_ready || return 1

  echo ""
  hdr "🛰  warpscout — сканирование, ручной выбор"
  echo ""
  info "Сканирую (может занять минуту)..."
  echo ""

  local report
  report=$(mktemp) || return 1
  if ! "$WARPSCOUT_BIN" scan -p awg -a "$WARPSCOUT_ACCOUNT" -plain -o "$report" 2>/dev/null; then
    err "Сканирование не удалось"
    rm -f "$report"
    return 1
  fi

  # Живой построчный вывод -plain уже показан на экране самим warpscout;
  # из файла отчёта строим нумерованный список ip:port для выбора.
  mapfile -t _lines < <(grep -oE '[0-9.]+:[0-9]+' "$report" | sort -u)
  rm -f "$report"

  if [[ ${#_lines[@]} -eq 0 ]]; then
    err "В отчёте нет рабочих endpoint'ов"
    return 1
  fi

  echo ""
  hdr "Рабочие endpoint'ы"
  local i
  for i in "${!_lines[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${_lines[$i]}"
  done
  echo ""

  local _sel
  read -rp "$(echo -e "${C}  Выбор [1-${#_lines[@]}, 0 — отмена]: ${N}")" _sel
  [[ "$_sel" == "0" || -z "$_sel" ]] && { info "Отменено"; return 0; }
  if ! [[ "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > ${#_lines[@]} )); then
    err "Неверный выбор"
    return 1
  fi

  _warpscout_apply_endpoint "${_lines[$((_sel-1))]}"
}

# Подменю: выбор между автовыбором и ручным выбором из таблицы.
_warpscout_endpoint_finder() {
  if ! ip link show warp0 &>/dev/null; then
    err "warp0 не активен — сначала включи туннель (пункт 3)"
    return 1
  fi

  echo ""
  hdr "🔍  Поиск рабочего Cloudflare endpoint (warpscout)"
  echo ""
  echo -e "  1) Автовыбор  ${D}— найти лучший и сразу применить${N}"
  echo -e "  2) Вручную    ${D}— показать таблицу, выбрать самому${N}"
  echo -e "  0) Отмена"
  echo ""
  local _mode
  read -rp "$(echo -e "${C}  Выбор [0-2]: ${N}")" _mode
  case "$_mode" in
    1) _warpscout_scan_auto ;;
    2) _warpscout_scan_manual ;;
    0|"") info "Отменено"; return 0 ;;
    *) warn "Неверный выбор"; return 1 ;;
  esac
}


_warp_remove() {
  echo ""
  warn "Удалить Warp полностью? Будет удалено:"
  warn "  • $WARP_CONF"
  warn "  • $WARP_DIR (аккаунт + список клиентов)"
  warn "  • /usr/local/bin/wgcf"
  warn "  • Health-check service/timer"
  echo ""
  read_confirm "$(echo -e "${R}  Подтверди (введи yes): ${N}")" || \
    { warn "Отменено"; return 0; }

  _warp_down
  _warp_health_remove 2>/dev/null || true

  # Удаляем юнит автозапуска и скрипт (на случай если они остались)
  if [[ -f /etc/systemd/system/awg-warp.service ]]; then
    systemctl disable awg-warp.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/awg-warp.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  rm -f /etc/wgcf/warp-autostart.sh 2>/dev/null

  rm -rf "$WARP_DIR" "$WARP_CONF" 2>/dev/null
  rm -f /usr/local/bin/wgcf 2>/dev/null
  rm -f "$WARP_HEALTH_LOG" /tmp/awg-warp-fails 2>/dev/null
  ok "Warp удалён полностью"
  return 0
}

_warp_status() {
  # Сначала синхронизируем — убираем мёртвые IP из peers.list
  _warp_sync_peers 2>/dev/null || true

  if command -v wgcf &>/dev/null && wgcf --help &>/dev/null; then
    echo -e "  wgcf       : ${G}установлен${N}"
  else
    echo -e "  wgcf       : ${D}не установлен${N}"
    return 0
  fi

  # Профиль
  if [[ -f "$WARP_CONF" ]]; then
    echo -e "  Профиль    : ${G}$WARP_CONF${N}"
  else
    echo -e "  Профиль    : ${D}не создан${N}"
  fi

  if ip link show warp0 &>/dev/null; then
    echo -e "  Интерфейс  : ${G}● warp0 активен${N}"

    # Один запрос — получаем сразу trace (warp+colo+ip)
    local trace warp_state warp_colo warp_ip
    trace=$(timeout 3 curl -s --interface warp0 -4 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    warp_state=$(echo "$trace" | awk -F= '/^warp=/{print $2}' | head -1 | tr -d '\r\n ' || true)
    warp_colo=$(echo "$trace" | awk -F= '/^colo=/{print $2}' | head -1 | tr -d '\r\n ' || true)
    warp_ip=$(echo "$trace" | awk -F= '/^ip=/{print $2}' | head -1 | tr -d '\r\n ' || true)

    # Кешированный тип аккаунта (для отображения Warp+ unlimited)
    local acc_type=""
    [[ -f "$WARP_DIR/account_type" ]] && \
      acc_type=$(cat "$WARP_DIR/account_type" 2>/dev/null | tr -d '[:space:]' || true)

    # Туннель — фактическое состояние из trace
    local tun_label
    case "$warp_state" in
      plus)
        case "$acc_type" in
          unlimited) tun_label="${G}● Warp+ unlimited${N}" ;;
          *)         tun_label="${G}● Warp+${N}" ;;
        esac
        [[ -n "$warp_colo" ]] && tun_label+=" ${D}· ${warp_colo}${N}"
        ;;
      on)
        tun_label="${G}● WARP${N}"
        [[ -n "$warp_colo" ]] && tun_label+=" ${D}· ${warp_colo}${N}"
        ;;
      off)
        tun_label="${Y}▲ туннель есть, но трафик мимо WARP${N}"
        ;;
      "")
        tun_label="${R}▲ Cloudflare недоступен${N}"
        ;;
      *)
        tun_label="${Y}● ${warp_state}${N}"
        ;;
    esac
    echo -e "  Туннель    : $tun_label"

    [[ -n "$warp_ip" ]] && echo -e "  Warp IP    : ${C}$warp_ip${N}"

    # Подсчёт включённых клиентов
    local peer_count=0
    if [[ -f "$WARP_PEERS" ]]; then
      peer_count=$(grep -c '^[0-9]' "$WARP_PEERS" 2>/dev/null)
      peer_count="${peer_count:-0}"
      peer_count=$(echo "$peer_count" | tr -d '\n\r ')
      [[ -z "$peer_count" ]] && peer_count=0
    fi
    local total_clients
    total_clients=$(_warp_list_awg_clients 2>/dev/null | grep -c '^' || echo "0")
    total_clients=$(echo "$total_clients" | tr -d '\n\r ')
    [[ -z "$total_clients" ]] && total_clients=0
    local pc_color="$G"
    [[ "$peer_count" == "0" ]] && pc_color="$D"
    echo -e "  Через Warp : ${pc_color}${peer_count}${N} из ${C}${total_clients}${N} клиент(ов)"
  else
    echo -e "  Интерфейс  : ${D}○ warp0 выключен${N}"
  fi

  # Health-check статус
  _warp_health_status

  return 0
}

# ── Импорт готового wgcf-account.toml с другого VPS ─────────────

_warp_import_account() {
  # Импорт — документированный путь для РФ-хостинга (README: 8 → 3), и он идёт
  # мимо пункта 1. Зависимости доставляем здесь, до того как пользователь
  # вставит длинный конфиг — чтобы не потерять его на ошибке apt.
  _warp_ensure_deps || return 1

  echo ""
  hdr "★  Импорт готового профиля Warp"
  echo ""
  echo -e "  ${W}Когда нужен импорт:${N}"
  echo -e "  Когда твой VPS не может подключиться к Cloudflare API"
  echo -e "  (TLS handshake timeout — типично для российских VPS)"
  echo ""
  echo -e "  ${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}⚡ ИНСТРУКЦИЯ: Google Cloud Shell${N} ${G}(бесплатно, 1 минута)${N}"
  echo -e "  ${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  echo -e "  ${Y}⚠ Из РФ — открывать через VPN${N} ${D}(Cloud Shell заблокирован)${N}"
  echo ""
  echo -e "  ${W}1.${N} Открой ${C}https://shell.cloud.google.com${N} (нужен Google аккаунт)"
  echo -e "  ${W}2.${N} Выполни команду (одну):"
  echo ""
  echo -e "${G}  rm -f wgcf-account.toml wgcf-profile.conf && curl -fsSL -o wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.30/wgcf_2.2.30_linux_amd64 && chmod +x wgcf && ./wgcf register --accept-tos && ./wgcf generate && cat wgcf-profile.conf${N}"
  echo ""
  echo -e "  ${W}3.${N} Скопируй ${C}весь вывод${N} от ${D}[Interface]${N} до конца"
  echo -e "     ${D}(должно быть содержимое wgcf-profile.conf — Address, PrivateKey, Endpoint и т.д.)${N}"
  echo ""
  echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}Альтернативы:${N} GitHub Codespaces, Replit, любой VPS не из РФ"
  echo -e "  ${R}✗ НЕ работают:${N} aeza, timeweb, beget — Cloudflare блокирует РФ"
  echo ""
  echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}Вставь сюда содержимое wgcf-profile.conf:${N}"
  echo ""
  echo -e "  ${D}Когда закончишь — нажми Enter, затем Ctrl+D${N}"
  echo -e "  ${D}Для отмены — Ctrl+C${N}"
  echo ""
  echo -e "${C}━━━━━━ начало вставки ━━━━━━${N}"

  # Читаем multiline ввод до EOF (Ctrl+D)
  local content
  content=$(cat)

  echo -e "${C}━━━━━━ конец вставки ━━━━━━${N}"
  echo ""

  if [[ -z "$content" ]]; then
    err "Пусто — отменено"
    return 1
  fi

  # Валидация — это должен быть wgcf-profile.conf (формат WireGuard)
  # Обязательные поля: [Interface], PrivateKey, Address, [Peer], PublicKey, Endpoint
  if ! echo "$content" | grep -q '^\[Interface\]'; then
    err "Не похоже на wgcf-profile.conf — нет секции [Interface]"
    info ""
    info "Ожидался формат WireGuard конфига:"
    info "  [Interface]"
    info "  PrivateKey = ..."
    info "  Address = 172.16.0.2/32"
    info "  [Peer]"
    info "  PublicKey = ..."
    info "  Endpoint = engage.cloudflareclient.com:2408"
    return 1
  fi
  if ! echo "$content" | grep -q '^PrivateKey'; then
    err "Нет поля PrivateKey — некорректный файл"
    return 1
  fi
  if ! echo "$content" | grep -q '^\[Peer\]'; then
    err "Нет секции [Peer] — некорректный файл"
    return 1
  fi
  if ! echo "$content" | grep -q '^PublicKey'; then
    err "Нет поля PublicKey — некорректный файл"
    return 1
  fi
  if ! echo "$content" | grep -q '^Endpoint'; then
    err "Нет поля Endpoint — некорректный файл"
    return 1
  fi

  # Бекапим существующий профиль если есть
  mkdir -p "$WARP_DIR"
  if [[ -f "$WARP_PROFILE" ]]; then
    local bak
    bak="${WARP_PROFILE}.bak.$(date +%s)"
    cp "$WARP_PROFILE" "$bak"
    info "Старый профиль сохранён: $bak"
  fi

  # Записываем профиль
  echo "$content" > "$WARP_PROFILE"
  chmod 600 "$WARP_PROFILE"

  # Также копируем в /etc/wireguard/warp0.conf — отсюда его читает _warp_up.
  # Код возврата проверяем: раньше cp падал молча (нет /etc/wireguard), а ниже
  # всё равно печаталось «импортирован» — ложный успех, из-за которого пункт 3
  # потом жаловался на отсутствующий конфиг.
  if ! cp "$WARP_PROFILE" "$WARP_CONF"; then
    err "Не удалось скопировать профиль в $WARP_CONF"
    info "Профиль сохранён в $WARP_PROFILE — импорт можно повторить"
    return 1
  fi
  chmod 600 "$WARP_CONF"

  ok "wgcf-profile.conf импортирован"

  # Если есть wgcf — устанавливаем фейковый account.toml для совместимости со статусом
  # (чтобы в _warp_status показывалось "Аккаунт: импортирован")
  if [[ ! -f "$WARP_ACCOUNT" ]]; then
    cat > "$WARP_ACCOUNT" << 'EOF'
# Account info imported via wgcf-profile.conf
# Original account.toml not available (network blocked from this server)
imported = true
EOF
    chmod 600 "$WARP_ACCOUNT"
  fi

  echo ""
  ok "Готово! Теперь пункт 3 — включить туннель"
  return 0
}


do_warp_menu() {
  # Отключаем set -e внутри меню чтобы один сбой не убивал весь скрипт
  set +e
  while true; do
    clear
    echo ""
    local _be; _be=$(warp_backend_current)
    hdr "☁  Warp туннель (Cloudflare) — бэкенд: ${_be}"
    echo ""
    warp_status || true
    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    if [[ "$_be" == "wg" ]]; then
      echo -e "  1) Установить wgcf и зарегистрировать Warp (бесплатный)"
    else
      echo -e "  1) Установить usque и зарегистрировать Warp"
    fi
    # Пункты 2, 5, 8, 9 специфичны для wgcf и на usque неприменимы
    if [[ "$_be" == "wg" ]]; then
      echo -e "  2) Активировать Warp+ (ввести лицензионный ключ)"
    else
      echo -e "  ${D}2) Активировать Warp+ (только для бэкенда wg)${N}"
    fi
    echo -e "  3) Включить туннель"
    echo -e "  4) Выключить туннель"
    if [[ "$_be" == "wg" ]]; then
      echo -e "  5) Перегенерировать профиль (после смены лицензии)"
    else
      echo -e "  ${D}5) Перегенерировать профиль (только для бэкенда wg)${N}"
    fi
    echo -e "  ${C}6) Управление клиентами в Warp${N}"
    echo -e "  ${C}7) Health-check (вкл/выкл авто-failover)${N}"
    if [[ "$_be" == "wg" ]]; then
      echo -e "  ${C}8) Импорт wgcf-profile.conf (если регистрация не работает)${N}"
      echo -e "  ${C}9) Поиск рабочего endpoint (warpscout)${N}"
    else
      echo -e "  ${D}8) Импорт wgcf-profile.conf (только для бэкенда wg)${N}"
      echo -e "  ${D}9) Поиск рабочего endpoint (только для бэкенда wg)${N}"
    fi
    echo -e "  ${W}b) Сменить бэкенд WARP${N} ${D}(сейчас ${_be})${N}"
    echo -e "  ${R}d) Удалить Warp полностью${N}"
    echo -e "  0) Назад в главное меню"
    echo ""
    read_choice WARP_CHOICE "$(echo -e "${C}  Выбор [0-9, b, d]: ${N}")" 0 9 "0" "b|d"

    case "${WARP_CHOICE:-}" in
      1)
        if [[ "$_be" != "wg" ]]; then
          warp_install || warn "Установка бэкенда $_be не удалась"
          read -rp "Enter..."
          continue
        fi
        _warp_install_wgcf || { read -rp "Enter..."; continue; }
        if ! _warp_register; then
          echo ""
          echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
          echo -e "${W}  💡 Регистрация не удалась — что делать дальше:${N}"
          echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
          echo ""
          echo -e "  Это типичная проблема российских VPS — Cloudflare API"
          echo -e "  блокирует регистрацию с российских IP-адресов."
          echo ""
          echo -e "  ${G}Решение:${N} зарегистрируй аккаунт на другом сервере"
          echo -e "  и импортируй сюда через ${W}п.8${N} в этом меню."
          echo ""
          echo -e "  ${C}Подробная инструкция:${N} меню 15 → ${W}8${N}"
          echo ""
          read -rp "Enter..."
          continue
        fi
        _warp_generate_profile || { read -rp "Enter..."; continue; }
        ok "Готово! Теперь пункт 3 — включить туннель"
        read -rp "Enter..."
        ;;
      2)
        if [[ "$_be" == "wg" ]]; then _warp_apply_license
        else warn "Warp+ лицензия применима только к бэкенду wg"; fi
        read -rp "Enter..." ;;
      3) warp_up;   read -rp "Enter..." ;;
      4) warp_down; read -rp "Enter..." ;;
      5)
        if [[ "$_be" == "wg" ]]; then
          _warp_generate_profile && info "Профиль обновлён. Если warp0 активен — выключи и включи (4 → 3)"
        else
          warn "Перегенерация профиля применима только к бэкенду wg"
        fi
        read -rp "Enter..."
        ;;
      6) do_warp_peers_menu || true ;;
      7) _warp_health_toggle; read -rp "Enter..." ;;
      8)
        if [[ "$_be" == "wg" ]]; then _warp_import_account
        else warn "Импорт wgcf-profile.conf применим только к бэкенду wg"; fi
        read -rp "Enter..." ;;
      9)
        if [[ "$_be" == "wg" ]]; then _warpscout_endpoint_finder
        else warn "Поиск endpoint применим только к бэкенду wg"; fi
        read -rp "Enter..." ;;
      b|B) do_warp_backend_menu || true ;;
      d|D) warp_uninstall; read -rp "Enter..." ;;
      0|"")
        set -e
        return 0
        ;;
      *) warn "Неверный выбор"; sleep 1 ;;
    esac
  done
  set -e
}


# ── Шифрованный DNS (dnscrypt-proxy) — Туннели (5) ─────────────

# Проверка статуса dnscrypt-proxy
_dns_proxy_status() {
  if ! command -v dnscrypt-proxy &>/dev/null; then
    echo -e "  Статус     : ${D}○ не установлен${N}"
    return 1
  fi
  if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
    echo -e "  Статус     : ${G}● активен${N}"
    # DNAT IPv4
    if iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1; then
      echo -e "  DNAT IPv4  : ${G}● настроен${N} ${D}(awg0 → ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT})${N}"
    else
      echo -e "  DNAT IPv4  : ${R}✗ правило отсутствует${N}"
    fi
    # DoT блокировка
    if iptables -C FORWARD -i awg0 -p tcp --dport 853 -j DROP >/dev/null 2>&1; then
      echo -e "  DoT block  : ${G}● заблокирован${N} ${D}(порт 853)${N}"
    else
      echo -e "  DoT block  : ${D}○ не настроен${N}"
    fi
    # IPv6 блокировка
    if command -v ip6tables &>/dev/null && ip6tables -C FORWARD -i awg0 -p udp --dport 53 -j DROP 2>/dev/null; then
      echo -e "  IPv6 leak  : ${G}● закрыт${N}"
    else
      echo -e "  IPv6 leak  : ${D}○ не настроен${N}"
    fi
    # Persistence
    if systemctl is-enabled --quiet awg-dns-persist.service 2>/dev/null; then
      echo -e "  Persist    : ${G}● переживёт reboot${N}"
    else
      echo -e "  Persist    : ${R}✗ DNAT исчезнет после reboot${N}"
    fi
    # Healthcheck
    if systemctl is-active --quiet awg-dns-healthcheck.timer 2>/dev/null; then
      echo -e "  Healthcheck: ${G}● включён${N} ${D}(каждые 2 мин)${N}"
    else
      echo -e "  Healthcheck: ${D}○ выключен${N}"
    fi
    # Резолвер
    if [[ -f "$DNS_PROXY_CONF" ]]; then
      local servers
      servers=$(grep -E "^server_names" "$DNS_PROXY_CONF" 2>/dev/null | head -1 | sed "s/server_names\s*=\s*//; s/\[//; s/\]//" | tr -d "'\"" || true)
      [[ -n "$servers" ]] && echo -e "  Резолверы  : ${C}${servers}${N}"
    fi
  else
    echo -e "  Статус     : ${D}○ выключен (установлен)${N}"
  fi
  return 0
}

# Установка и настройка dnscrypt-proxy
_dns_proxy_install() {
  echo ""
  hdr "+  Установка dnscrypt-proxy"

  # ───── PRE-CHECKS — проверки перед установкой ─────
  info "Выполняем pre-checks..."

  # 1. AWG интерфейс существует
  if ! ip link show awg0 &>/dev/null; then
    err "Интерфейс awg0 не найден"
    info "Сначала установи AWG (Сервер → п.2), затем включи DNS-шифрование"
    return 1
  fi

  # 2. Проверка конфликтующих DNS-сервисов на 53 порту
  # Игнорируем systemd-resolved subsystems (127.0.0.53, 127.0.0.54) — они не мешают
  # И наш собственный 127.0.2.1 (dnscrypt-proxy)
  # Реальные конфликты: pi-hole, unbound, bind, powerdns на 0.0.0.0:53 или public IP
  local conflicting_dns=""
  conflicting_dns=$(ss -tulpn 2>/dev/null | grep -E ':(53|853)\s' | \
    grep -vE "127\.0\.0\.5[34]|127\.0\.2\.1|127\.0\.0\.1" | head -3)

  if [[ -n "$conflicting_dns" ]]; then
    warn "На сервере уже работают DNS-сервисы (могут конфликтовать):"
    echo "$conflicting_dns" | while read -r line; do echo "    $line"; done
    echo ""
    warn "Возможные причины:"
    info "  • Pi-hole / Unbound / BIND / PowerDNS"
    info "  • Другая инсталляция dnscrypt-proxy"
    echo ""
    read_yesno CONT_INSTALL "$(echo -e "  ${Y}Продолжить установку всё равно? [y/N]: ${N}")" "n"
    if [[ ! "${CONT_INSTALL,,}" =~ ^y ]]; then
      warn "Отменено"
      return 1
    fi
  fi

  ok "Pre-checks пройдены"
  echo ""

  # ───── 1. Установка пакета ─────
  if ! command -v dnscrypt-proxy &>/dev/null; then
    info "Устанавливаем dnscrypt-proxy + dnsutils..."
    if ! apt-get install -y -q dnscrypt-proxy dnsutils 2>&1 | grep -E "^(Setting up|E:)" | head -5; then
      err "Не удалось установить dnscrypt-proxy"
      info "Попробуй: apt-get update && apt-get install dnscrypt-proxy"
      return 1
    fi
    ok "dnscrypt-proxy установлен"
  else
    info "dnscrypt-proxy уже установлен"
    if ! command -v dig &>/dev/null; then
      apt-get install -y -q dnsutils 2>&1 | grep -E "^(Setting up|E:)" | head -3 || true
    fi
  fi

  # ───── 2. Бекап оригинального конфига ─────
  if [[ -f "$DNS_PROXY_CONF" ]] && [[ ! -f "$DNS_PROXY_BACKUP_CONF" ]]; then
    cp "$DNS_PROXY_CONF" "$DNS_PROXY_BACKUP_CONF"
    info "Оригинальный конфиг сохранён: $DNS_PROXY_BACKUP_CONF"
  fi

  systemctl stop dnscrypt-proxy 2>/dev/null || true

  # 4. Создаём наш конфиг
  # Важно: НЕ задаём listen_addresses — на Debian/Ubuntu используется
  # systemd socket activation (127.0.2.1:53). Если задать listen_addresses,
  # появляется конфликт с сокетом и сервис может не работать.
  info "Создаём конфиг с DoH резолверами..."
  mkdir -p /etc/dnscrypt-proxy

  cat > "$DNS_PROXY_CONF" << EOF
# AWG Toolza — шифрованный DNS через DoH
# Адрес: ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT} (через systemd socket activation)

# listen_addresses пустой — используем systemd сокет (Debian/Ubuntu default)
listen_addresses = []

# Параметры безопасности
require_dnssec = true
require_nolog = true
require_nofilter = true

# Резолверы (DoH only — стабильнее DNSCrypt)
server_names = ['cloudflare', 'google', 'cisco-doh']

dnscrypt_servers = false
doh_servers = true

# IPv4 only
ipv4_servers = true
ipv6_servers = false

# Кеш
cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400

# Тайминги
timeout = 5000
keepalive = 30

# Источники
[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 73
    prefix = ''
EOF

  chmod 644 "$DNS_PROXY_CONF"
  mkdir -p /var/cache/dnscrypt-proxy
  chown -R _dnscrypt-proxy:_dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null || \
    chown -R nobody:nogroup /var/cache/dnscrypt-proxy 2>/dev/null || true

  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    info "systemd-resolved активен — это OK (мы на ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT})"
  fi

  # 5. Запускаем dnscrypt-proxy через systemd socket
  info "Запускаем dnscrypt-proxy..."
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable dnscrypt-proxy.socket 2>/dev/null || true
  systemctl enable dnscrypt-proxy 2>/dev/null || true
  systemctl start dnscrypt-proxy.socket 2>/dev/null || true
  systemctl start dnscrypt-proxy 2>/dev/null || true

  # 6. Ждём пока резолверы загрузятся (до 15 секунд)
  info "Ждём пока загрузятся резолверы..."
  local waited=0
  local ready=0
  while [[ $waited -lt 15 ]]; do
    sleep 1
    waited=$((waited+1))
    if ! systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
      continue
    fi
    # Тестовый запрос на адрес сокета
    if timeout 3 dig "@${DNS_PROXY_ADDR}" -p "${DNS_PROXY_PORT}" cloudflare.com +short +tries=1 +time=2 2>/dev/null | grep -qE '^[0-9]+\.'; then
      ready=1
      break
    fi
    printf "."
  done
  echo ""

  # 7. Проверка результата
  if ! systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
    err "dnscrypt-proxy не запустился"
    echo ""
    info "Последние строки лога:"
    journalctl -u dnscrypt-proxy -n 15 --no-pager 2>/dev/null | tail -15
    return 1
  fi

  if [[ $ready -eq 0 ]]; then
    err "Резолвер не отвечает после 15 секунд"
    echo ""
    info "Возможные причины:"
    info "  • Cloudflare DoH недоступен с этого сервера (РФ хостинги)"
    info "  • Bootstrap DNS (9.9.9.9 / 8.8.8.8) не отвечает"
    echo ""
    info "Лог:"
    journalctl -u dnscrypt-proxy -n 15 --no-pager 2>/dev/null | tail -15
    echo ""
    info "Проверь вручную:"
    info "  dig @${DNS_PROXY_ADDR} cloudflare.com"
    info "  ss -tulpn | grep ':${DNS_PROXY_PORT} '"
    return 1
  fi

  ok "dnscrypt-proxy запущен и отвечает на ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT} (за ${waited} сек)"

  # ───── 8. iptables DNAT (IPv4) ─────
  info "Настраиваем iptables DNAT IPv4 для awg0 → ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}..."

  # Удаляем старые правила (если были)
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" >/dev/null 2>&1 || true

  # Добавляем DNAT
  iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}"
  iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}"

  # ───── 8.5. Разрешаем DNAT-перенаправленные пакеты к dnscrypt ─────
  # КРИТИЧНО: UFW по умолчанию блокирует пакеты awg0 → 127.0.2.1:53
  info "Разрешаем DNAT-пакеты к dnscrypt..."
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    # UFW активен — используем родные UFW правила (persist автоматически)
    ufw allow in on awg0 to "${DNS_PROXY_ADDR}" port "${DNS_PROXY_PORT}" proto udp >/dev/null 2>&1
    ufw allow in on awg0 to "${DNS_PROXY_ADDR}" port "${DNS_PROXY_PORT}" proto tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    info "  → Используется UFW (правила сохранятся автоматически)"
  else
    # UFW не активен — обычный iptables -I INPUT
    while iptables -D INPUT -i awg0 -d "${DNS_PROXY_ADDR}" -p udp --dport "${DNS_PROXY_PORT}" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D INPUT -i awg0 -d "${DNS_PROXY_ADDR}" -p tcp --dport "${DNS_PROXY_PORT}" -j ACCEPT 2>/dev/null; do :; done
    iptables -I INPUT 1 -i awg0 -d "${DNS_PROXY_ADDR}" -p udp --dport "${DNS_PROXY_PORT}" -j ACCEPT
    iptables -I INPUT 1 -i awg0 -d "${DNS_PROXY_ADDR}" -p tcp --dport "${DNS_PROXY_PORT}" -j ACCEPT
    info "  → Используется iptables (UFW не активен)"
  fi
  ok "DNAT-пакеты разрешены"

  # ───── 9. iptables DROP — блокировка обхода ─────
  info "Блокируем обход DNS-шифрования (DoT 853, нестандартные DoH)..."
  # DoT (DNS-over-TLS) — порт 853 — блокируем чтобы клиент не обошёл
  iptables -D FORWARD -i awg0 -p tcp --dport 853 -j DROP 2>/dev/null || true
  iptables -D FORWARD -i awg0 -p udp --dport 853 -j DROP 2>/dev/null || true
  iptables -A FORWARD -i awg0 -p tcp --dport 853 -j DROP
  iptables -A FORWARD -i awg0 -p udp --dport 853 -j DROP

  # ───── 10. ip6tables — IPv6 закрытие leak ─────
  if command -v ip6tables &>/dev/null; then
    info "Закрываем IPv6 DNS-leak..."
    # Блокируем весь IPv6 DNS трафик из awg0 (у нас VPN IPv4-only)
    ip6tables -D FORWARD -i awg0 -p udp --dport 53 -j DROP 2>/dev/null || true
    ip6tables -D FORWARD -i awg0 -p tcp --dport 53 -j DROP 2>/dev/null || true
    ip6tables -D FORWARD -i awg0 -p tcp --dport 853 -j DROP 2>/dev/null || true
    ip6tables -A FORWARD -i awg0 -p udp --dport 53 -j DROP
    ip6tables -A FORWARD -i awg0 -p tcp --dport 53 -j DROP
    ip6tables -A FORWARD -i awg0 -p tcp --dport 853 -j DROP
  fi

  # route_localnet=1 — обязательно для DNAT в 127.0.0.0/8
  sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true

  cat > /etc/sysctl.d/99-awg-dns.conf << EOF
# AWG Toolza: route_localnet для DNAT 53 → ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}
net.ipv4.conf.all.route_localnet=1
EOF

  ok "iptables правила добавлены (DNAT + DoT block + IPv6 block)"

  # ───── 11. Persist iptables через systemd unit ─────
  info "Настраиваем persistence для iptables (переживёт reboot)..."

  cat > "$DNS_PERSIST_SCRIPT" << EOF
#!/usr/bin/env bash
# AWG Toolza — восстановление iptables правил для DNS-шифрования при старте
# Создан автоматически: $(date '+%Y-%m-%d %H:%M:%S')

set -e

# Ждём пока awg0 поднимется
for i in {1..30}; do
  if ip link show awg0 &>/dev/null; then
    break
  fi
  sleep 2
done

if ! ip link show awg0 &>/dev/null; then
  echo "[awg-dns-persist] awg0 не появился за 60 секунд, выход" >&2
  exit 1
fi

# Удаляем старые правила (на случай если уже есть)
iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1 || true
iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1 || true
iptables -D FORWARD -i awg0 -p tcp --dport 853 -j DROP 2>/dev/null || true
iptables -D FORWARD -i awg0 -p udp --dport 853 -j DROP 2>/dev/null || true
while iptables -D INPUT -i awg0 -d "${DNS_PROXY_ADDR}" -p udp --dport "${DNS_PROXY_PORT}" -j ACCEPT 2>/dev/null; do :; done
while iptables -D INPUT -i awg0 -d "${DNS_PROXY_ADDR}" -p tcp --dport "${DNS_PROXY_PORT}" -j ACCEPT 2>/dev/null; do :; done

# IPv4 DNAT
iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}"
iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}"

# INPUT allow — обход UFW для DNAT-перенаправленных пакетов
# Если UFW активен — он сам сохраняет свои правила, скипаем
if ! (command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"); then
  iptables -I INPUT 1 -i awg0 -d "${DNS_PROXY_ADDR}" -p udp --dport "${DNS_PROXY_PORT}" -j ACCEPT
  iptables -I INPUT 1 -i awg0 -d "${DNS_PROXY_ADDR}" -p tcp --dport "${DNS_PROXY_PORT}" -j ACCEPT
fi

# DoT block
iptables -A FORWARD -i awg0 -p tcp --dport 853 -j DROP
iptables -A FORWARD -i awg0 -p udp --dport 853 -j DROP

# IPv6 block (DNS + DoT)
if command -v ip6tables &>/dev/null; then
  ip6tables -D FORWARD -i awg0 -p udp --dport 53 -j DROP 2>/dev/null || true
  ip6tables -D FORWARD -i awg0 -p tcp --dport 53 -j DROP 2>/dev/null || true
  ip6tables -D FORWARD -i awg0 -p tcp --dport 853 -j DROP 2>/dev/null || true
  ip6tables -A FORWARD -i awg0 -p udp --dport 53 -j DROP
  ip6tables -A FORWARD -i awg0 -p tcp --dport 53 -j DROP
  ip6tables -A FORWARD -i awg0 -p tcp --dport 853 -j DROP
fi

echo "[awg-dns-persist] DNS iptables правила восстановлены"
EOF
  chmod +x "$DNS_PERSIST_SCRIPT"

  cat > "$DNS_PERSIST_SERVICE" << EOF
[Unit]
Description=AWG Toolza — DNS iptables persistence
After=network-online.target dnscrypt-proxy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DNS_PERSIST_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable awg-dns-persist.service 2>/dev/null

  ok "Persistence настроена (правила восстановятся после reboot)"

  # ───── 12. Healthcheck timer ─────
  info "Настраиваем healthcheck (мониторинг dnscrypt-proxy)..."

  cat > "$DNS_HEALTH_SCRIPT" << EOF
#!/usr/bin/env bash
# AWG Toolza — healthcheck для dnscrypt-proxy
# Проверяет что сервис активен и резолвит. Если упал — пишет в лог.
set -u

LOG="$DNS_HEALTH_LOG"
TIMESTAMP=\$(date '+%Y-%m-%d %H:%M:%S')

# 1. Проверка сервиса
if ! systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
  echo "[\$TIMESTAMP] FAIL: dnscrypt-proxy сервис не активен" >> "\$LOG"
  # Пробуем перезапустить
  systemctl restart dnscrypt-proxy 2>/dev/null && \\
    echo "[\$TIMESTAMP] RECOVERY: автоматически перезапустили dnscrypt-proxy" >> "\$LOG"
  exit 1
fi

# 2. Проверка реального резолва (через dig)
if command -v dig &>/dev/null; then
  if ! timeout 3 dig "@${DNS_PROXY_ADDR}" -p "${DNS_PROXY_PORT}" cloudflare.com +short +tries=1 +time=2 2>/dev/null | grep -qE '^[0-9]+\.'; then
    echo "[\$TIMESTAMP] FAIL: dnscrypt-proxy не резолвит cloudflare.com" >> "\$LOG"
    exit 1
  fi
fi

# 3. Проверка DNAT правил
if ! iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1; then
  echo "[\$TIMESTAMP] FAIL: DNAT правило отсутствует — восстанавливаю" >> "\$LOG"
  $DNS_PERSIST_SCRIPT 2>&1 | tee -a "\$LOG" >/dev/null
fi

exit 0
EOF
  chmod +x "$DNS_HEALTH_SCRIPT"

  cat > "$DNS_HEALTH_SERVICE" << EOF
[Unit]
Description=AWG Toolza — DNS healthcheck
After=dnscrypt-proxy.service

[Service]
Type=oneshot
ExecStart=$DNS_HEALTH_SCRIPT
EOF

  cat > "$DNS_HEALTH_TIMER" << EOF
[Unit]
Description=AWG Toolza — DNS healthcheck (каждые 2 мин)

[Timer]
OnBootSec=60
OnUnitActiveSec=120
Unit=awg-dns-healthcheck.service

[Install]
WantedBy=timers.target
EOF

  touch "$DNS_HEALTH_LOG"
  systemctl daemon-reload
  systemctl enable --now awg-dns-healthcheck.timer 2>/dev/null

  ok "Healthcheck настроен (проверка каждые 2 минуты, лог: $DNS_HEALTH_LOG)"

  # ───── 13. State ─────
  cat > "$DNS_PROXY_STATE" << EOF
enabled=true
addr=${DNS_PROXY_ADDR}
port=${DNS_PROXY_PORT}
ipv6_blocked=true
dot_blocked=true
persist_enabled=true
healthcheck_enabled=true
installed_at=$(date +%s)
EOF

  echo ""
  ok "Шифрованный DNS активен!"
  info "Защита от DNS-leak:"
  info "  ✓ DNAT перехват UDP/TCP 53 на awg0"
  info "  ✓ DoT (порт 853) заблокирован"
  info "  ✓ IPv6 DNS заблокирован"
  info "  ✓ Persistence через systemd (переживёт reboot)"
  info "  ✓ Healthcheck каждые 2 минуты"
  echo ""
  info "Проверка с клиента: https://1.1.1.1/help → 'Using DNS over HTTPS' = Yes"
  return 0
}


# Удаление DNAT и (опционально) пакета
_dns_proxy_remove() {
  echo ""
  hdr "−  Удаление шифрованного DNS"
  echo ""
  echo -e "  Что будет удалено:"
  echo -e "  ${R}•${N} DNAT правила для awg0 (DNS снова напрямую к 1.1.1.1)"
  echo -e "  ${R}•${N} Блокировка DoT (порт 853)"
  echo -e "  ${R}•${N} Блокировка IPv6 DNS"
  echo -e "  ${R}•${N} Sysctl правило route_localnet"
  echo -e "  ${R}•${N} Persistence (systemd unit) и Healthcheck (timer)"
  echo -e "  ${R}•${N} Сервис dnscrypt-proxy будет ${Y}остановлен${N}"
  echo ""
  read_yesno REMOVE_PKG "$(echo -e "  Также ${R}полностью удалить пакет${N} dnscrypt-proxy? [y/N]: ")" "n"

  # 1. Healthcheck timer
  systemctl disable --now awg-dns-healthcheck.timer 2>/dev/null || true
  systemctl stop awg-dns-healthcheck.service 2>/dev/null || true
  rm -f "$DNS_HEALTH_TIMER" "$DNS_HEALTH_SERVICE" "$DNS_HEALTH_SCRIPT" "$DNS_HEALTH_LOG"

  # 2. Persist service
  systemctl disable awg-dns-persist.service 2>/dev/null || true
  rm -f "$DNS_PERSIST_SERVICE" "$DNS_PERSIST_SCRIPT"

  systemctl daemon-reload 2>/dev/null || true

  # 3. iptables IPv4 DNAT — убираем все варианты
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" >/dev/null 2>&1 || true
  # Старые правила (для совместимости с прошлыми версиями)
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" >/dev/null 2>&1 || true

  # 4. iptables — DoT блокировка
  iptables -D FORWARD -i awg0 -p tcp --dport 853 -j DROP 2>/dev/null || true
  iptables -D FORWARD -i awg0 -p udp --dport 853 -j DROP 2>/dev/null || true

  # 4.5. INPUT allow rules — убираем и UFW и iptables варианты
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow in on awg0 to "${DNS_PROXY_ADDR}" port "${DNS_PROXY_PORT}" proto udp >/dev/null 2>&1 || true
    ufw delete allow in on awg0 to "${DNS_PROXY_ADDR}" port "${DNS_PROXY_PORT}" proto tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
  fi
  # И iptables на всякий случай (если правила были добавлены до активации UFW)
  while iptables -D INPUT -i awg0 -d "${DNS_PROXY_ADDR}" -p udp --dport "${DNS_PROXY_PORT}" -j ACCEPT 2>/dev/null; do :; done
  while iptables -D INPUT -i awg0 -d "${DNS_PROXY_ADDR}" -p tcp --dport "${DNS_PROXY_PORT}" -j ACCEPT 2>/dev/null; do :; done

  # 5. ip6tables — IPv6 блокировка
  if command -v ip6tables &>/dev/null; then
    ip6tables -D FORWARD -i awg0 -p udp --dport 53 -j DROP 2>/dev/null || true
    ip6tables -D FORWARD -i awg0 -p tcp --dport 53 -j DROP 2>/dev/null || true
    ip6tables -D FORWARD -i awg0 -p tcp --dport 853 -j DROP 2>/dev/null || true
  fi

  ok "Все iptables правила удалены"

  # 6. Sysctl
  rm -f /etc/sysctl.d/99-awg-dns.conf
  sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true

  # 7. Сервис
  systemctl stop dnscrypt-proxy 2>/dev/null || true
  systemctl disable dnscrypt-proxy 2>/dev/null || true
  ok "Сервис dnscrypt-proxy остановлен"

  # 8. Полное удаление пакета (если запросил)
  if [[ "${REMOVE_PKG,,}" =~ ^y ]]; then
    info "Удаляем пакет dnscrypt-proxy..."
    apt-get purge -y -q dnscrypt-proxy 2>&1 | tail -3
    rm -rf /var/cache/dnscrypt-proxy
    ok "Пакет удалён"
  else
    # 9. Восстанавливаем оригинальный конфиг если есть бекап
    if [[ -f "$DNS_PROXY_BACKUP_CONF" ]]; then
      cp "$DNS_PROXY_BACKUP_CONF" "$DNS_PROXY_CONF" 2>/dev/null
      info "Оригинальный конфиг восстановлен из $DNS_PROXY_BACKUP_CONF"
    fi
  fi

  # 10. State
  rm -f "$DNS_PROXY_STATE"

  echo ""
  ok "Шифрованный DNS отключён"
  info "DNS клиентов снова идёт напрямую (DNS из их конфига)"
  return 0
}

# Перезапуск сервиса
_dns_proxy_restart() {
  if ! systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
    err "dnscrypt-proxy не запущен"
    return 1
  fi
  info "Перезапускаем dnscrypt-proxy..."
  systemctl restart dnscrypt-proxy
  sleep 2
  if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
    ok "Сервис перезапущен"
  else
    err "Сервис упал — проверь journalctl -u dnscrypt-proxy"
    return 1
  fi
  return 0
}

# Просмотр логов
_dns_proxy_logs() {
  echo ""
  hdr "📜  Логи dnscrypt-proxy (последние 50 строк)"
  echo ""
  journalctl -u dnscrypt-proxy -n 50 --no-pager 2>/dev/null || warn "Логи недоступны"
}

# Смена upstream резолверов
_dns_proxy_change_upstream() {
  if [[ ! -f "$DNS_PROXY_CONF" ]]; then
    err "Конфиг не найден — сначала установи (пункт 1)"
    return 1
  fi

  echo ""
  hdr "↻  Сменить upstream резолверы"
  echo ""
  echo -e "  ${G}1)${N} Cloudflare + Google + Cisco ${D}(по умолчанию, рекомендуется)${N}"
  echo -e "  ${G}2)${N} Только Cloudflare ${D}(быстрее, один источник)${N}"
  echo -e "  ${G}3)${N} Yandex Safe ${D}(российский, без РКН блокировок)${N}"
  echo -e "  ${G}4)${N} Только Cisco ${D}(OpenDNS, надёжный)${N}"
  echo -e "  ${G}5)${N} Только Google ${D}(если другие заблокированы)${N}"
  echo -e "  ${C}6) Ввести вручную${N} ${D}(произвольный список из public-resolvers.md)${N}"
  echo -e "  ${G}0)${N} Отмена"
  echo ""
  read_choice UPSTREAM_CHOICE "$(echo -e "${C}  Выбор [0-6]: ${N}")" 0 6 "0"

  local servers=""
  # Флаг: нужно ли резолверам быть без фильтрации.
  # true  = пресет содержит только nofilter-резолверы → require_nofilter=true (защита от случайного фильтра)
  # false = пресет содержит filter-резолвер (yandex-safe) → require_nofilter=false (иначе сервис не запустится)
  # ""    = пресет ручной (case 6), там логика своя
  local need_nofilter=""
  case "${UPSTREAM_CHOICE:-}" in
    1) servers="['cloudflare', 'google', 'cisco-doh']"; need_nofilter="true" ;;
    2) servers="['cloudflare']";                        need_nofilter="true" ;;
    3) servers="['yandex-safe']";                       need_nofilter="false" ;;
    4) servers="['cisco-doh']";                         need_nofilter="true" ;;
    5) servers="['google']";                            need_nofilter="true" ;;
    6)
      echo ""
      echo -e "  ${W}Доступные резолверы:${N} полный список в public-resolvers.md"
      echo -e "  ${D}https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/public-resolvers.md${N}"
      echo ""
      echo -e "  ${W}Примеры популярных DoH серверов:${N}"
      echo -e "  ${C}cloudflare${N}                   — 1.1.1.1 / 1.0.0.1"
      echo -e "  ${C}cloudflare-security${N}          — Cloudflare с фильтром malware"
      echo -e "  ${C}cloudflare-family${N}            — Cloudflare с фильтром adult"
      echo -e "  ${C}google${N}                       — 8.8.8.8 / 8.8.4.4"
      echo -e "  ${C}cisco-doh${N}                    — Cisco OpenDNS"
      echo -e "  ${C}adguard-dns-doh${N}              — AdGuard (фильтр рекламы)"
      echo -e "  ${C}yandex-safe${N}                  — Yandex Safe"
      echo -e "  ${C}controld-uncensored${N}          — Control D"
      echo ""
      echo -e "  ${Y}⚠ Внимание:${N} если выбрать ${R}filter${N}-резолвер,"
      echo -e "  отключи ${C}require_nofilter${N} в конфиге, иначе сервер не запустится."
      echo ""
      echo -e "  ${W}Введи через запятую:${N} ${D}cloudflare,google${N}"
      echo -e "  ${W}Или один:${N} ${D}cisco-doh${N}"
      echo ""
      read -rp "  Резолверы: " MANUAL_INPUT

      if [[ -z "$MANUAL_INPUT" ]]; then
        warn "Пусто — отменено"
        return 0
      fi

      # Валидация: только буквы/цифры/дефисы/запятые/пробелы
      if [[ ! "$MANUAL_INPUT" =~ ^[a-zA-Z0-9_,\ -]+$ ]]; then
        err "Недопустимые символы. Разрешены: a-z, 0-9, дефис, запятая"
        return 1
      fi

      # Разбираем CSV → массив → TOML список
      local IFS_OLD="$IFS"
      IFS=','
      local arr=()
      for srv in $MANUAL_INPUT; do
        # Убираем пробелы по краям
        srv="${srv## }"; srv="${srv%% }"
        srv="${srv#"${srv%%[![:space:]]*}"}"
        srv="${srv%"${srv##*[![:space:]]}"}"
        [[ -n "$srv" ]] && arr+=("'$srv'")
      done
      IFS="$IFS_OLD"

      if [[ ${#arr[@]} -eq 0 ]]; then
        err "Не удалось распарсить список"
        return 1
      fi

      # Собираем TOML формат: ['srv1', 'srv2']
      servers="[$(IFS=', '; echo "${arr[*]}")]"

      # Если в списке есть filter-резолвер — предупреждаем про require_nofilter
      if echo "$MANUAL_INPUT" | grep -q "filter"; then
        warn "В списке есть фильтрующий резолвер."
        warn "Меняю require_nofilter с true на false (иначе сервер не запустится)"
        sed -i 's|^require_nofilter\s*=.*|require_nofilter = false|' "$DNS_PROXY_CONF"
      fi
      ;;
    0|"") return 0 ;;
    *) warn "Неверный выбор"; return 1 ;;
  esac

  # Применяем require_nofilter для пресетов 1-5 (только если он отличается от текущего)
  if [[ -n "$need_nofilter" ]]; then
    local current_nofilter
    current_nofilter=$(grep -E '^require_nofilter\s*=' "$DNS_PROXY_CONF" 2>/dev/null | awk -F'=' '{gsub(/[[:space:]]/,"",$2); print $2}' || true)
    if [[ "$current_nofilter" != "$need_nofilter" ]]; then
      sed -i "s|^require_nofilter\s*=.*|require_nofilter = $need_nofilter|" "$DNS_PROXY_CONF"
      if [[ "$need_nofilter" == "true" ]]; then
        info "Восстановлено require_nofilter=true (защита от фильтр-резолверов)"
      else
        info "Установлено require_nofilter=false (пресет содержит фильтрующий резолвер)"
      fi
    fi
  fi

  sed -i "s|^server_names\s*=.*|server_names = $servers|" "$DNS_PROXY_CONF"
  ok "Upstream обновлён: $servers"

  _dns_proxy_restart
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo ""
    err "Сервис не запустился — возможно неверное имя резолвера"
    info "Проверь имена в public-resolvers.md и попробуй снова"
    info "Или сделай 'sudo journalctl -u dnscrypt-proxy -n 20' чтобы увидеть лог"
  fi
  return $rc
}

# Меню шифрованного DNS — п.5 → Туннели и DNS
do_dns_menu() {
  set +e
  while true; do
    clear
    echo ""
    hdr "☁  Шифрованный DNS (DNSCrypt-proxy)"
    echo ""
    _dns_proxy_status || true
    echo ""
    echo -e "  ${D}При включении: все DNS-запросы клиентов идут через DoH${N}"
    echo -e "  ${D}к Cloudflare / Google / Cisco (DNSSEC + no-logging)${N}"
    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  1) Включить (установить + настроить)"
    echo -e "  2) Перезапустить сервис"
    echo -e "  3) Логи (последние 50 строк)"
    echo -e "  4) Сменить upstream (Cloudflare / Google / Cisco)"
    echo -e "  ${R}5) Выключить и удалить${N}"
    echo -e "  0) Назад в главное меню"
    echo ""
    read_choice DNS_CHOICE "$(echo -e "${C}  Выбор [0-5]: ${N}")" 0 5 "0"

    case "${DNS_CHOICE:-}" in
      1)
        # Проверим что AWG установлен
        if ! ip link show awg0 &>/dev/null; then
          warn "Сначала создай AWG сервер (Сервер → п.2)"
          read -rp "Enter..."
          continue
        fi
        _dns_proxy_install
        read -rp "Enter..."
        ;;
      2) _dns_proxy_restart; read -rp "Enter..." ;;
      3) _dns_proxy_logs; read -rp "Enter..." ;;
      4) _dns_proxy_change_upstream; read -rp "Enter..." ;;
      5) _dns_proxy_remove; read -rp "Enter..." ;;
      0|"")
        set -e
        return 0
        ;;
      *) warn "Неверный выбор"; sleep 1 ;;
    esac
  done
  set -e
}


# Ищет код бота в распакованном рядом архиве awg-toolza.
#
# Зачем: установщик бота клонирует репозиторий с GitHub, и пока правки не
# запушены, оттуда приезжает старый код. В распакованном .run код бота лежит
# в awg_bot/ — его и берём. Печатает путь к каталогу с awgbot/ и run.py.
_find_local_bot_src() {
  local d cand=""
  # Сначала каталог самого скрипта: если awg2.sh запущен прямо из распаковки
  d=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")")" 2>/dev/null && pwd) || d=""
  [[ -n "$d" && -d "$d/awg_bot/awgbot" && -f "$d/awg_bot/run.py" ]] && { echo "$d/awg_bot"; return 0; }

  # Затем типовые места распаковки — берём самую свежую версию
  shopt -s nullglob
  local dirs=( /opt/awg-toolza-*/ /root/awg-toolza-*/ /opt/awg-toolza/ )
  shopt -u nullglob
  local best="" best_ts=0 ts
  for d in "${dirs[@]}"; do
    d="${d%/}"
    [[ -d "$d/awg_bot/awgbot" && -f "$d/awg_bot/run.py" ]] || continue
    ts=$(stat -c %Y "$d/awg_bot/run.py" 2>/dev/null || echo 0)
    if [[ "$ts" -ge "$best_ts" ]]; then best="$d/awg_bot"; best_ts="$ts"; fi
  done
  cand="$best"

  [[ -n "$cand" ]] || return 1
  echo "$cand"
  return 0
}

# Все следы Telegram-бота. Единый список: удаление и проверка «а он вообще
# стоит?» должны смотреть в одно место, иначе после «удалено» остаётся venv на
# сотню мегабайт или мёртвый сервис.
_bot_artifacts() {
  cat <<'EOF'
/opt/awg-bot
/var/lib/awg-bot
/usr/local/bin/awg-bot
/usr/local/bin/awg-bot.py
/etc/systemd/system/awg-bot.service
/etc/awg-bot.conf
EOF
}

# Полное удаление бота: сервис, код, venv, management-скрипт, состояние
# мониторинга и конфиг с токеном.
#
# Токен перед удалением копируется в папку бэкапов: терять его больно (новый
# у @BotFather заводить не надо, но старый уже не вернуть), а удаление «фул»
# по определению сносит /etc/awg-bot.conf.
# $1 = "quiet" — без вопросов, вызывается из do_uninstall, где подтверждение
# уже получено.
do_bot_uninstall() {
  local quiet="${1:-}"
  local conf="/etc/awg-bot.conf" p saved=""

  if [[ "$quiet" != "quiet" ]]; then
    echo ""
    hdr "⌧  Полное удаление Telegram-бота"
    warn "Будет удалено:"
    while IFS= read -r p; do
      [[ -e "$p" ]] && echo -e "  ${R}—${N} $p" || echo -e "  ${D}—${N} ${D}$p (нет)${N}"
    done < <(_bot_artifacts)
    echo ""
    echo -e "  ${D}Токен будет сохранён в папку бэкапов, если конфиг на месте.${N}"
    echo -e "  ${D}Сервер AmneziaWG и клиенты не затрагиваются.${N}"
    echo ""
    read_confirm "$(echo -e "${R}  Подтверди удаление бота (введи yes): ${N}")" || \
      { warn "Отменено."; return 0; }
  fi

  # Токен в бэкап — до того, как что-то удаляем
  if [[ -f "$conf" ]]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    saved="${BACKUP_DIR}/awg-bot.conf.$(date +%Y%m%d_%H%M%S)"
    if cp "$conf" "$saved" 2>/dev/null; then
      chmod 600 "$saved" 2>/dev/null || true
    else
      saved=""
      warn "Не удалось сохранить копию конфига — токен будет потерян"
    fi
  fi

  trash "Останавливаем сервис awg-bot..."
  systemctl stop awg-bot 2>/dev/null || true
  systemctl disable awg-bot 2>/dev/null || true

  trash "Удаляем файлы бота..."
  while IFS= read -r p; do
    rm -rf "$p" 2>/dev/null || true
  done < <(_bot_artifacts)

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed awg-bot 2>/dev/null || true

  # Проверяем, что действительно ничего не осталось
  local left=()
  while IFS= read -r p; do
    [[ -e "$p" ]] && left+=("$p")
  done < <(_bot_artifacts)

  if [[ ${#left[@]} -eq 0 ]]; then
    ok "Бот удалён полностью"
  else
    warn "Осталось удалить вручную:"
    for p in "${left[@]}"; do echo -e "  ${Y}—${N} $p"; done
  fi
  [[ -n "$saved" ]] && info "Токен сохранён: $saved"
  log_info "do_bot_uninstall: осталось ${#left[@]} путей"
  return 0
}

do_uninstall() {
  echo ""
  hdr "⌧  Удаление AmneziaWG"
  # Что тут вообще есть — считаем до вопросов, чтобы список был честным
  local bot_present=false
  if [[ -f /usr/local/bin/awg-bot.py || -d /opt/awg-bot ]] || \
     [[ -f /etc/systemd/system/awg-bot.service ]]; then
    bot_present=true
  fi

  warn "Будет удалено:"
  echo -e "  ${R}—${N} Интерфейс awg0"
  echo -e "  ${R}—${N} Пакеты amneziawg, amneziawg-tools"
  echo -e "  ${R}—${N} DKMS-модуль (dkms remove, /usr/src, /var/lib/dkms)"
  echo -e "  ${R}—${N} /etc/amnezia/amneziawg/"
  echo -e "  ${R}—${N} /root/*_awg2.conf"
  echo -e "  ${R}—${N} Автозапуск awg-quick@awg0"
  echo -e "  ${R}—${N} NAT-персистентность (hook / awg-nat.service)"
  $bot_present && echo -e "  ${R}—${N} Telegram-бот целиком (спрошу отдельно)"
  echo -e "  ${R}—${N} Сам скрипт ${W}${SCRIPT_PATH}${N} — команда awg2 (спрошу отдельно)"
  echo ""
  echo -e "  ${D}Бэкапы в ${BACKUP_DIR} остаются — их удаляй руками.${N}"
  echo ""
  read_confirm "$(echo -e "${R}  Подтверди удаление (введи yes): ${N}")" || \
    { warn "Отменено."; return 0; }

  # Бот — отдельным вопросом: его могли ставить не ради этого сервера
  local _del_bot="n"
  if $bot_present; then
    echo ""
    read_yesno _del_bot "$(echo -e "${R}  Удалить и Telegram-бота (сервис, код, venv, токен)? [Y/n]: ${N}")" "y"
  fi

  # Сам скрипт: после удаления команды awg2 больше не будет
  echo ""
  local _del_self
  read_yesno _del_self "$(echo -e "${R}  Удалить сам скрипт ${SCRIPT_PATH} и следы установки? [Y/n]: ${N}")" "y"

  # v6.4: авто-бэкап перед удалением (последний шанс восстановиться)
  if [[ -f "$SERVER_CONF" ]]; then
    auto_backup "uninstall" || warn "Авто-бэкап не удался"
  fi

  trash "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  trash "Удаляем expire-таймер..."
  _expire_remove || true

  trash "Отключаем автозапуск..."
  systemctl disable awg-quick@awg0 2>/dev/null || true
  rm -rf /etc/systemd/system/awg-quick@awg0.service.d 2>/dev/null || true

  trash "Удаляем NAT-персистентность..."
  systemctl disable --now awg-nat.service >/dev/null 2>&1 || true
  rm -f "$NAT_PERSIST_SERVICE" "$NAT_PERSIST_SCRIPT" 2>/dev/null || true
  rm -f /etc/network/if-pre-up.d/iptables-nat 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  # Модуль ставится через git+DKMS, а не apt — apt-get remove его не видит.
  # Без явного dkms remove в /var/lib/dkms и /usr/src остаётся старая сборка,
  # и следующая установка молча переиспользует её ("already built, skip")
  # вместо актуального кода из свежего git-клона.
  trash "Удаляем DKMS-модуль..."
  if command -v dkms &>/dev/null; then
    local _dkms_ver
    _dkms_ver=$(dkms status 2>/dev/null | grep -oP '^amneziawg/\K[0-9.]+' | head -1)
    [[ -z "$_dkms_ver" ]] && _dkms_ver="1.0.0"
    dkms remove -m amneziawg -v "$_dkms_ver" --all 2>/dev/null || true
  fi
  rmmod amneziawg 2>/dev/null || true
  rm -rf /usr/src/amneziawg-* 2>/dev/null || true
  rm -rf /var/lib/dkms/amneziawg 2>/dev/null || true
  rm -rf /tmp/amneziawg-linux-kernel-module /tmp/amneziawg-tools 2>/dev/null || true
  depmod -a 2>/dev/null || true

  trash "Удаляем пакеты..."
  apt-get remove -y -q amneziawg amneziawg-tools 2>/dev/null || true
  apt-get autoremove -y -q 2>/dev/null || true

  trash "Удаляем конфиги..."
  rm -rf /etc/amnezia 2>/dev/null || true
  rm -f /root/*_awg2.conf 2>/dev/null || true
  rm -f /etc/modules-load.d/amneziawg.conf 2>/dev/null || true

  trash "Удаляем UFW правила..."
  if command -v ufw &>/dev/null; then
    local rule_nums
    rule_nums=$(ufw status numbered 2>/dev/null | grep -i "AmneziaWG" | grep -oE '\[[0-9]+\]' | tr -d '[]' | sort -rn || true)
    for num in $rule_nums; do
      echo "y" | ufw --force delete "$num" 2>/dev/null || true
    done
  fi

  if [[ "$_del_bot" == "y" ]]; then
    echo ""
    trash "Удаляем Telegram-бота..."
    do_bot_uninstall quiet || warn "Бот удалён не полностью — смотри вывод выше"
  fi

  _DEPS_CACHED=""  # сбрасываем кэш — awg больше нет

  if [[ "$_del_self" != "y" ]]; then
    echo ""
    ok "Всё удалено"
    info "Скрипт остался: ${SCRIPT_PATH} (команда awg2)"
    return 0
  fi

  # ── Удаление самого скрипта ──
  # Следы доставки: распакованные каталоги и self-extract архивы, которые
  # приезжали на сервер. Без них после «удалить всё» в /root и /opt остаётся
  # мусор, из которого awg2 запускается снова и выглядит как «не удалилось».
  trash "Удаляем лог и следы установки..."
  rm -f "$LOG_FILE" 2>/dev/null || true
  rm -rf /var/lib/awg2 2>/dev/null || true   # кэш проверки обновлений и канал
  rm -f /root/awg-toolza-*.run 2>/dev/null || true
  rm -rf /opt/awg-toolza-* 2>/dev/null || true
  rm -f /tmp/awg_domain_cache.txt 2>/dev/null || true

  echo ""
  ok "Всё удалено, включая ${SCRIPT_PATH}"
  echo -e "  ${D}Бэкапы остались: ${BACKUP_DIR}${N}"
  echo -e "  ${D}Установить снова: curl -fsSL <URL>/awg2.sh -o ${SCRIPT_PATH} && chmod +x ${SCRIPT_PATH}${N}"
  echo ""
  log_info "do_uninstall: удаляю себя ($SCRIPT_PATH) и выхожу"

  # Файл сносим из отдельного процесса: bash дочитывает скрипт с диска по ходу
  # исполнения, и удалить его «под собой» — верный способ получить синтаксис-
  # ошибку вместо чистого выхода.
  ( sleep 1; rm -f "$SCRIPT_PATH" ) >/dev/null 2>&1 &
  exit 0
}

# Параллельный пинг всех доменов из 4 пулов.
# Результаты сохраняются в кэш /tmp/awg_domain_cache.txt.
do_check_domains() {
  echo ""
  hdr "◎  Проверка доменов для мимикрии"
  echo ""

  # Спрашиваем регион (не зависит от установленного сервера)
  echo -e "  ${G}1${N}  Европа / Мир"
  echo -e "  ${G}2${N}  Россия — RU"
  echo ""
  local CHECK_REGION_CHOICE check_region
  read_choice CHECK_REGION_CHOICE "$(echo -e "${C}  Выбор региона для проверки [1-2] (Enter = 1): ${N}")" 1 2 1
  case "$CHECK_REGION_CHOICE" in
    2) check_region="ru" ;;
    *) check_region="world" ;;
  esac

  # Показываем текущий регион и какие пулы будут проверены
  local region_label
  case "$check_region" in
    ru)    region_label="🇷🇺 РФ" ;;
    world) region_label="🌍 Мир/Европа" ;;
    *)     region_label="🌍 Мир" ;;
  esac
  echo ""
  echo -e "  ${C}Регион:${N} ${W}${region_label}${N}"
  echo ""

  local cache_file="/tmp/awg_domain_cache.txt"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # ── Выбираем пулы (по выбору юзера, а не по установленному серверу) ──
  local -a tls_pool dtls_pool sip_pool quic_pool
  if [[ "$check_region" == "ru" ]]; then
    tls_pool=("${TLS_DOMAINS_RU[@]}")
    dtls_pool=("${DTLS_DOMAINS_RU[@]}")
    sip_pool=("${SIP_DOMAINS_RU[@]}")
    quic_pool=("${QUIC_DOMAINS_RU[@]}")
  else
    tls_pool=("${TLS_DOMAINS_WORLD[@]}")
    dtls_pool=("${DTLS_DOMAINS_WORLD[@]}")
    sip_pool=("${SIP_DOMAINS_WORLD[@]}")
    quic_pool=("${QUIC_DOMAINS_WORLD[@]}")
  fi

  local all_domains=("${tls_pool[@]}" "${dtls_pool[@]}" "${sip_pool[@]}" "${quic_pool[@]}")
  local total=${#all_domains[@]}
  local avail_count=0
  local tmpdir="/tmp/awg_ping_$$"
  mkdir -p "$tmpdir"

  trap 'rm -rf "$tmpdir"; exit 1' INT TERM

  # Параллельная проверка через _probe_host (профиль определяет метод: TCP vs ping)
  local domain
  _spawn_probe() {
    local prof="$1" d="$2"
    (
      local r ms
      r=$(_probe_host "$prof" "$d")
      if [[ "$r" == ok* ]]; then
        ms=${r#ok }
        # Защита от "0 мс"
        [[ -z "$ms" || "$ms" == "0" ]] && ms=1
        echo "$ms" > "$tmpdir/${d//./_}"
      else
        echo "fail" > "$tmpdir/${d//./_}"
      fi
    ) &
  }
  for domain in "${tls_pool[@]}";  do _spawn_probe tls  "$domain"; done
  for domain in "${dtls_pool[@]}"; do _spawn_probe dtls "$domain"; done
  for domain in "${sip_pool[@]}";  do _spawn_probe sip  "$domain"; done
  for domain in "${quic_pool[@]}"; do _spawn_probe quic "$domain"; done

  # Защита от пустых пулов
  if [[ $total -eq 0 ]]; then
    warn "Нет доменов в пулах (регион: $check_region)"
    rm -rf "$tmpdir"
    return 1
  fi

  # Прогресс-бар пока пинги выполняются
  local bar_width=40
  local last_done=-1
  while true; do
    local running
    running=$(jobs -r 2>/dev/null | wc -l)
    local done_count=$((total - running))
    [[ $done_count -lt 0 ]] && done_count=0

    if [[ $done_count -ne $last_done ]]; then
      local pct=$((done_count * 100 / total))
      local filled=$((done_count * bar_width / total))
      [[ $filled -gt $bar_width ]] && filled=$bar_width
      local bar=""
      local i
      for ((i=0; i<filled; i++)); do bar+="█"; done
      for ((i=filled; i<bar_width; i++)); do bar+="░"; done
      printf "\r  ${C}Проверка: ${G}%s${N} ${W}%3d%%${N} (${done_count}/${total})" "$bar" "$pct"
      last_done=$done_count
    fi

    [[ $running -eq 0 ]] && break
    sleep 0.1
  done
  wait 2>/dev/null || true
  printf "\r                                                                                   \r"

  # Хелпер получить результат
  _ping_result() {
    cat "$tmpdir/${1//./_}" 2>/dev/null || echo "fail"
  }

  # Хелпер обработать пул — показать с ms
  _show_pool() {
    local label="$1" icon="$2" cache_label="$3"
    shift 3
    local domains=("$@")
    local pool_ok=0
    local d ms

    echo -e "${C}  $icon $label${N} ${D}(${#domains[@]})${N}"
    for d in "${domains[@]}"; do
      ms=$(_ping_result "$d")
      if [[ "$ms" == "fail" ]]; then
        printf "    ${R}×${N}  %-32s  ${R}offline${N}\n" "$d"
        echo "${cache_label}|$d|fail|$ts" >> "$cache_file"
      else
        local color="${G}"
        [[ $ms -gt 100 ]] && color="${Y}"
        [[ $ms -gt 300 ]] && color="${R}"
        printf "    ${G}√${N}  %-32s  ${color}%4d мс${N}\n" "$d" "$ms"
        echo "${cache_label}|$d|ok|$ts|$ms" >> "$cache_file"
        pool_ok=$((pool_ok + 1))
        avail_count=$((avail_count + 1))
      fi
    done
    echo -e "    ${D}───────────────────────────────────${N}"
    echo -e "    ${D}${pool_ok}/${#domains[@]} доступно${N}"
    echo ""
  }

  : > "$cache_file"

  _show_pool "TLS 1.3 / HTTPS"     "◎" "TLS"  "${tls_pool[@]}"
  _show_pool "DTLS / STUN / WebRTC" "◇" "DTLS" "${dtls_pool[@]}"
  _show_pool "SIP / VoIP"           "◈" "SIP"  "${sip_pool[@]}"
  _show_pool "QUIC / HTTP/3"        "◆" "QUIC" "${quic_pool[@]}"

  rm -rf "$tmpdir"
  trap - INT TERM

  hdr "∑  Итог"
  local pct=$((avail_count * 100 / total))
  local status_color="${G}"
  [[ $pct -lt 70 ]] && status_color="${Y}"
  [[ $pct -lt 40 ]] && status_color="${R}"
  echo -e "  ${C}Регион    :${N} ${W}${region_label}${N}"
  echo -e "  ${C}Доступно  :${N} ${status_color}${avail_count}/${total} (${pct}%)${N}"
  echo -e "  ${C}Кэш       :${N} ${D}${cache_file}${N}"

  if [[ $avail_count -lt $total ]]; then
    echo ""
    echo -e "${Y}  ! Недоступные домены не будут использоваться при выборе мимикрии${N}"
  fi

  return 0
}

do_clean_clients() {
  hdr "⌧  Очистка всех клиентов"
  [[ ! -f "$SERVER_CONF" ]] && { err "Конфиг сервера не найден"; return 1; }

  local client_count
  client_count=$(grep -c "^\[Peer\]" "$SERVER_CONF" 2>/dev/null || echo "0")

  if [[ $client_count -eq 0 ]]; then
    warn "Нет клиентов для удаления"
    return 0
  fi

  echo ""
  echo -e "${Y}  ! Будет удалено ${client_count} клиентов${N}"
  echo -e "${Y}    Все конфиги клиентов из /root также будут удалены${N}"
  echo ""
  read_confirm "$(echo -e "${R}  Подтвердить удаление клиентов? (введи yes): ${N}")" || \
    { warn "Отменено."; return 0; }

  # v6.4: авто-бэкап перед опасной операцией
  auto_backup "clean" || warn "Авто-бэкап не удался"

  trash "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || true

  # Backup ДО изменений
  local clean_bak
  clean_bak="${SERVER_CONF}.bak.clean.$(date +%s)"
  cp "$SERVER_CONF" "$clean_bak" || { err "Не удалось создать backup"; return 1; }
  ok "Резервная копия: $clean_bak"

  local temp_conf="${SERVER_CONF}.tmp"
  # sed: печатает всё до первой [Peer] секции включительно (q = quit, p = print)
  # Результат — только [Interface] без клиентов
  sed -n '/^\[Peer\]/q; p' "$SERVER_CONF" > "$temp_conf" 2>/dev/null

  # Проверяем что временный конфиг валиден
  if [[ ! -s "$temp_conf" ]] || ! grep -q "^\[Interface\]" "$temp_conf" 2>/dev/null; then
    err "Ошибка: не удалось корректно очистить конфиг"
    warn "Восстанавливаем из backup..."
    cp "$clean_bak" "$SERVER_CONF"
    rm -f "$temp_conf" 2>/dev/null
    awg-quick up "$SERVER_CONF" 2>/dev/null || true
    return 1
  fi

  mv "$temp_conf" "$SERVER_CONF"
  rm -f /root/*_awg2.conf 2>/dev/null || true
  
  info "Перезапускаем awg0..."
  if ! awg_up_diag "$SERVER_CONF"; then
    err "Не удалось перезапустить awg0"
    warn "Восстанавливаем из backup..."
    cp "$clean_bak" "$SERVER_CONF"
    awg-quick up "$SERVER_CONF" 2>/dev/null || true
    ok "Конфиг восстановлен из $clean_bak"
    return 1
  fi

  echo ""
  ok "Удалено $client_count клиентов"
  info "Конфиги клиентов из /root удалены"

  # Все клиенты удалены — очищаем Warp peers.list
  if declare -f _warp_sync_peers >/dev/null 2>&1; then
    _warp_sync_peers 2>/dev/null || true
  fi
}

do_backup() {
  local timestamp backup_path

  timestamp=$(date '+%Y%m%d_%H%M%S')
  backup_path="${BACKUP_DIR}/awg2_backup_${timestamp}"

  echo ""
  hdr "◈  Бекап AmneziaWG 2.0"
  bkup "Директория бекапа: $backup_path"

  mkdir -p "$backup_path" || { err "Не удалось создать директорию $backup_path"; return 1; }

  local backed_up=0

  # Серверный конфиг
  if [[ -f "$SERVER_CONF" ]]; then
    cp "$SERVER_CONF" "$backup_path/awg0.conf"
    ok "Серверный конфиг: awg0.conf"
    backed_up=$((backed_up + 1))
  else
    warn "Серверный конфиг не найден: $SERVER_CONF"
  fi

  # Все клиентские конфиги из /root/ (find -print0 — безопасно для имён с пробелами)
  while IFS= read -r -d '' cfile; do
    cp "$cfile" "$backup_path/" && ok "Клиент: $(basename "$cfile")"
    backed_up=$((backed_up + 1))
  done < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  # AWG параметры (текущие, live dump)
  if ip link show awg0 &>/dev/null 2>&1; then
    awg show awg0 > "$backup_path/awg_show_dump.txt" 2>/dev/null || true
    ok "Live dump awg show awg0"
  fi

  # ── Состояние WARP ──
  # Раньше в бэкап не попадало вовсе: при потере сервера аккаунт Cloudflare
  # приходилось регистрировать заново, а он упирается в лимиты.
  local warp_backend
  warp_backend=$(warp_backend_current)
  mkdir -p "$backup_path/warp"
  # Бэкенд wg: аккаунт и профиль wgcf
  if [[ -d "$WARP_DIR" ]]; then
    cp -a "$WARP_DIR" "$backup_path/warp/wgcf" 2>/dev/null &&       { ok "WARP (wg): аккаунт и список клиентов"; backed_up=$((backed_up + 1)); }
  fi
  [[ -f "$WARP_CONF" ]] && cp "$WARP_CONF" "$backup_path/warp/warp0.conf" 2>/dev/null || true
  # Бэкенд usque: config.json — это и есть зарегистрированное устройство
  if [[ -f "$USQUE_CONF" ]]; then
    mkdir -p "$backup_path/warp/usque"
    cp "$USQUE_CONF" "$backup_path/warp/usque/config.json" 2>/dev/null &&       { ok "WARP (usque): регистрация устройства"; backed_up=$((backed_up + 1)); }
  fi
  rmdir "$backup_path/warp" 2>/dev/null || true

  # Лог
  [[ -f "$LOG_FILE" ]] && cp "$LOG_FILE" "$backup_path/awg-manager.log" || true

  # Метаданные бекапа
  {
    echo "timestamp=$timestamp"
    echo "server_conf=$SERVER_CONF"
    echo "backed_files=$backed_up"
    echo "awg_version=2.0"
    echo "warp_backend=$warp_backend"
    echo "hostname=$(hostname)"
  } > "$backup_path/backup_meta.txt"

  chmod -R 600 "$backup_path"
  chmod 700 "$BACKUP_DIR" "$backup_path"

  echo ""
  success_box "◈  Бекап создан успешно"
  echo -e "${W}  Файлов  : ${N}$backed_up"
  echo -e "${W}  Папка   : ${N}$backup_path"
  log_info "Бекап создан: $backup_path ($backed_up файлов)"
}

do_restore() {
  echo ""
  hdr "◈  Восстановление AmneziaWG 2.0"

  if [[ ! -d "$BACKUP_DIR" ]]; then
    err "Директория бекапов не найдена: $BACKUP_DIR"
    return 1
  fi

  # Список доступных бекапов
  local backups=()
  while IFS= read -r d; do
    [[ -f "$d/backup_meta.txt" ]] && backups+=("$d")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "awg2_backup_*" | sort -r)

  if [[ ${#backups[@]} -eq 0 ]]; then
    err "Нет доступных бекапов в $BACKUP_DIR"
    return 1
  fi

  echo -e "${W}  Доступные бекапы:${N}"
  local i=1
  for b in "${backups[@]}"; do
    local meta="$b/backup_meta.txt"
    local ts files
    ts=$(grep "^timestamp=" "$meta" 2>/dev/null | cut -d= -f2 || true)
    [[ -z "$ts" ]] && ts=$(basename "$b")
    files=$(grep "^backed_files=" "$meta" 2>/dev/null | cut -d= -f2 || echo "?")
    echo -e "  ${G}$i${N}) $ts  (файлов: $files)  [$(basename "$b")]"
    i=$((i + 1))
  done
  echo ""

  local RESTORE_CHOICE
  read_choice RESTORE_CHOICE "$(echo -e "${C}  Выбери номер бекапа (Enter = 1, 0 = отмена): ${N}")" 0 "${#backups[@]}" "1"

  if [[ "$RESTORE_CHOICE" == "0" ]]; then
    info "Отменено"
    return 0
  fi

  local chosen_backup="${backups[$((RESTORE_CHOICE - 1))]}"
  echo -e "${C}  → Восстановление из: ${W}$(basename "$chosen_backup")${N}"

  read_confirm "$(echo -e "${R}  Текущий серверный конфиг будет заменён. Продолжить? (введи yes): ${N}")" || \
    { warn "Отменено."; return 0; }

  # Останавливаем интерфейс
  info "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  # Бекап текущего конфига перед заменой
  if [[ -f "$SERVER_CONF" ]]; then
    cp "$SERVER_CONF" "${SERVER_CONF}.pre_restore.$(date +%s)" 2>/dev/null || true
    info "Текущий конфиг сохранён как pre_restore"
  fi

  mkdir -p /etc/amnezia/amneziawg
  local restored=0

  # Восстанавливаем серверный конфиг
  if [[ -f "$chosen_backup/awg0.conf" ]]; then
    cp "$chosen_backup/awg0.conf" "$SERVER_CONF"
    chmod 600 "$SERVER_CONF"
    ok "Серверный конфиг восстановлен"
    restored=$((restored + 1))
  else
    warn "awg0.conf не найден в бекапе"
  fi

  # Восстанавливаем клиентские конфиги (find -print0 — безопасно для имён с пробелами)
  while IFS= read -r -d '' cfile; do
    cp "$cfile" "/root/$(basename "$cfile")"
    chmod 600 "/root/$(basename "$cfile")"
    ok "Клиент восстановлен: $(basename "$cfile")"
    restored=$((restored + 1))
  done < <(find "$chosen_backup" -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  # ── Состояние WARP ──
  # Восстанавливаем аккаунты обоих бэкендов: перерегистрация упирается в лимиты
  # Cloudflare, а список клиентов в WARP иначе пришлось бы собирать заново.
  if [[ -d "$chosen_backup/warp" ]]; then
    if [[ -d "$chosen_backup/warp/wgcf" ]]; then
      mkdir -p "$(dirname "$WARP_DIR")"
      cp -a "$chosen_backup/warp/wgcf/." "$WARP_DIR/" 2>/dev/null &&         { ok "WARP (wg): аккаунт и список клиентов"; restored=$((restored + 1)); }
      chmod 700 "$WARP_DIR" 2>/dev/null || true
    fi
    if [[ -f "$chosen_backup/warp/warp0.conf" ]]; then
      mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
      cp "$chosen_backup/warp/warp0.conf" "$WARP_CONF" 2>/dev/null &&         chmod 600 "$WARP_CONF" 2>/dev/null || true
    fi
    if [[ -f "$chosen_backup/warp/usque/config.json" ]]; then
      mkdir -p "$USQUE_DIR" && chmod 700 "$USQUE_DIR"
      cp "$chosen_backup/warp/usque/config.json" "$USQUE_CONF" 2>/dev/null &&         { chmod 600 "$USQUE_CONF"; ok "WARP (usque): регистрация устройства"; restored=$((restored + 1)); }
    fi
    # Возвращаем тот бэкенд, который был активен на момент бэкапа
    local saved_be
    saved_be=$(grep -oP '^warp_backend=\K\S+' "$chosen_backup/backup_meta.txt" 2>/dev/null || true)
    if [[ -n "$saved_be" ]] && warp_backend_known "$saved_be"; then
      warp_backend_set "$saved_be" && info "Активный бэкенд WARP: $saved_be"
    fi
    info "Туннель WARP не поднимается автоматически — включи его в меню Туннели"
  fi

  # Поднимаем интерфейс
  info "Запускаем awg0..."
  if awg_up_diag "$SERVER_CONF"; then
    ok "Интерфейс awg0 запущен"
  else
    err "Не удалось поднять awg0. Проверь конфиг: $SERVER_CONF"
    return 1
  fi

  echo ""
  success_box "◈  Восстановление завершено"
  echo -e "${W}  Файлов  : ${N}$restored"
  echo -e "${W}  Бекап   : ${N}$(basename "$chosen_backup")"
  log_info "Восстановление из бекапа: $chosen_backup ($restored файлов)"
}

CHOICE=""
CLIENT_DNS="1.1.1.1, 1.0.0.1"
I1=""
I2=""
I3=""
I4=""
I5=""
MIMICRY_PROFILE=""
MTU=""
AWG_PARAMS_LINES=""

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/awg-manager.log"

# Ротация лога: если >5MB — переименовываем в .old (оставляем 1 архивный)
if [[ -f "$LOG_FILE" ]]; then
  _log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( _log_size > 5242880 )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
  unset _log_size
fi

log_info "=== AWG Toolza ${VERSION} запущен ==="

# Trap EXIT/INT/TERM — cleanup временных файлов и кэшей
# ═══════════════════════════════════════════════════════════════════
# 🌉 КАСКАД — port forwarding на промежуточный сервер
# ═══════════════════════════════════════════════════════════════════
# РУ VPS принимает клиентов и форвардит трафик на ЕВРО VPS
# (AmneziaWG / VLESS / любой L4-сервис). Клиент видит РУ IP.
#
# Persist: собственный systemd-сервис awg-cascade.service
# Изоляция: все правила помечены comment "$CASCADE_TAG:<proto>-<port>"
#   → flush трогает только свои, AWG/WARP/DNS не задеваются.
# ═══════════════════════════════════════════════════════════════════

_cascade_valid_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  # shellcheck disable=SC2206  # сплит по точкам; регулярка выше уже гарантирует цифры
  local -a o=($ip)
  local i
  for i in 0 1 2 3; do
    [[ "${o[$i]}" =~ ^[0-9]+$ ]] || return 1
    (( ${o[$i]} <= 255 )) || return 1
  done
  return 0
}

_cascade_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

_cascade_rule_tag() {
  local proto="$1" in_port="$2"
  echo "${CASCADE_TAG}:${proto}-${in_port}"
}

# ── Логирование каскада ────────────────────────────────────
# Уровни: INFO / WARN / ERROR. Пишет в $CASCADE_LOG с ротацией при >1MB.
_cascade_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  # Ротация
  if [[ -f "$CASCADE_LOG" ]]; then
    local size
    size=$(stat -c%s "$CASCADE_LOG" 2>/dev/null || echo 0)
    if (( size > CASCADE_LOG_MAX )); then
      mv "$CASCADE_LOG" "${CASCADE_LOG}.old" 2>/dev/null || true
    fi
  fi
  # Создаём с правами 600 если ещё нет
  if [[ ! -f "$CASCADE_LOG" ]]; then
    touch "$CASCADE_LOG" 2>/dev/null && chmod 600 "$CASCADE_LOG" 2>/dev/null || true
  fi
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$CASCADE_LOG" 2>/dev/null || true
}
_cascade_log_info()  { _cascade_log "INFO"  "$@"; }
_cascade_log_warn()  { _cascade_log "WARN"  "$@"; }
_cascade_log_error() { _cascade_log "ERROR" "$@"; }

_cascade_get_iface() {
  local iface=""
  iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  if [[ -z "$iface" ]]; then
    iface=$(ip -4 route show 2>/dev/null | awk '/^default|^0\.0\.0\.0/ {print $5; exit}')
  fi
  echo "${iface:-eth0}"
}

# ── UFW интеграция ─────────────────────────────────────────
# Если UFW активен — каскад должен через него проходить, иначе
# его правила FORWARD будут конфликтовать с нашими, особенно
# после ufw reload или перезагрузки.

_cascade_ufw_active() {
  # Возвращает 0 если UFW установлен И активен
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | grep -qiE '^Status:\s*active' || return 1
  return 0
}

_cascade_ufw_backup_dir() {
  echo "${CASCADE_DIR}/ufw-backup"
}

# Сохраняет /etc/default/ufw перед изменениями (один раз)
_cascade_ufw_backup_config() {
  local bdir; bdir=$(_cascade_ufw_backup_dir)
  mkdir -p "$bdir"
  if [[ ! -f "$bdir/ufw.default.original" && -f /etc/default/ufw ]]; then
    cp /etc/default/ufw "$bdir/ufw.default.original"
    chmod 600 "$bdir/ufw.default.original"
    _cascade_log_info "ufw: backed up /etc/default/ufw"
  fi
}

# Меняет DEFAULT_FORWARD_POLICY на ACCEPT (нужно для NAT forwarding)
# Возвращает 0 если изменили, 1 если уже было ACCEPT (ничего не делали)
_cascade_ufw_enable_forward_policy() {
  [[ -f /etc/default/ufw ]] || return 1
  local current
  current=$(grep -oE '^DEFAULT_FORWARD_POLICY="[^"]*"' /etc/default/ufw 2>/dev/null | head -1)
  if [[ "$current" == 'DEFAULT_FORWARD_POLICY="ACCEPT"' ]]; then
    return 1  # уже ACCEPT, ничего не меняли
  fi
  _cascade_ufw_backup_config
  sed -i 's|^DEFAULT_FORWARD_POLICY="[^"]*"|DEFAULT_FORWARD_POLICY="ACCEPT"|' /etc/default/ufw
  _cascade_log_info "ufw: DEFAULT_FORWARD_POLICY set to ACCEPT"
  return 0
}

# Открывает входящий порт через ufw
_cascade_ufw_allow_port() {
  local proto="$1" port="$2"
  if ufw status 2>/dev/null | grep -qE "^${port}/${proto}\s+ALLOW"; then
    return 0  # уже открыт
  fi
  if ufw allow "${port}/${proto}" comment "${CASCADE_TAG}:${proto}-${port}" >/dev/null 2>&1; then
    _cascade_log_info "ufw: allow ${port}/${proto}"
    return 0
  fi
  _cascade_log_error "ufw: failed to allow ${port}/${proto}"
  return 1
}

# Удаляет правило входящего порта
_cascade_ufw_revoke_port() {
  local proto="$1" port="$2"
  ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
  _cascade_log_info "ufw: revoke ${port}/${proto}"
}

# Разрешает форвардинг к target через ufw route
_cascade_ufw_allow_route() {
  local proto="$1" target_ip="$2" out_port="$3"
  # ufw route добавляет правило в FORWARD цепочку
  if ufw route allow proto "$proto" from any to "$target_ip" port "$out_port" \
       comment "${CASCADE_TAG}:route-${proto}-${out_port}" >/dev/null 2>&1; then
    _cascade_log_info "ufw: route allow ${proto} -> ${target_ip}:${out_port}"
    return 0
  fi
  _cascade_log_warn "ufw: route allow failed (старая версия ufw? попробую без comment)"
  ufw route allow proto "$proto" from any to "$target_ip" port "$out_port" >/dev/null 2>&1 || true
}

_cascade_ufw_revoke_route() {
  local proto="$1" target_ip="$2" out_port="$3"
  ufw route delete allow proto "$proto" from any to "$target_ip" port "$out_port" >/dev/null 2>&1 || true
  _cascade_log_info "ufw: revoke route ${proto} -> ${target_ip}:${out_port}"
}

# Главный entrypoint: интегрировать одно правило каскада с UFW
# Вызывать ПОСЛЕ _cascade_save_to_file (нужны данные правила)
_cascade_ufw_integrate_rule() {
  local proto="$1" in_port="$2" target_ip="$3" out_port="$4"
  if ! _cascade_ufw_active; then
    return 0  # UFW не активен — нечего делать
  fi
  _cascade_ufw_enable_forward_policy
  _cascade_ufw_allow_port "$proto" "$in_port"
  _cascade_ufw_allow_route "$proto" "$target_ip" "$out_port"
  # Применяем изменения политики (если поменяли)
  ufw reload >/dev/null 2>&1 || true
}

# Откатить интеграцию одного правила
_cascade_ufw_revoke_rule() {
  local proto="$1" in_port="$2" target_ip="$3" out_port="$4"
  if ! _cascade_ufw_active; then
    return 0
  fi
  _cascade_ufw_revoke_port "$proto" "$in_port"
  _cascade_ufw_revoke_route "$proto" "$target_ip" "$out_port"
}

# Полный откат UFW-интеграции (вызывается при uninstall модуля)
_cascade_ufw_full_revoke() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  # Снести все port allow с нашим comment
  local rule_num
  while true; do
    rule_num=$(ufw status numbered 2>/dev/null | grep -F "${CASCADE_TAG}:" | head -1 | grep -oE '^\[\s*[0-9]+\s*\]' | tr -d '[] ')
    [[ -z "$rule_num" ]] && break
    echo "y" | ufw --force delete "$rule_num" >/dev/null 2>&1 || break
  done

  # Восстановить /etc/default/ufw из бэкапа
  local bdir; bdir=$(_cascade_ufw_backup_dir)
  if [[ -f "$bdir/ufw.default.original" ]]; then
    cp "$bdir/ufw.default.original" /etc/default/ufw
    _cascade_log_info "ufw: restored /etc/default/ufw from backup"
  fi

  if _cascade_ufw_active; then
    ufw reload >/dev/null 2>&1 || true
  fi
}


# БЕЗОПАСНЫЕ счётчики — через wc -l + явный echo "0" fallback.
# Старая версия с grep -c | echo 0 давала многострочный "0\n0" → (( )) падал.
_cascade_count_iptables() {
  local n
  n=$(iptables-save -t nat 2>/dev/null | grep -c "^-A PREROUTING.*${CASCADE_TAG}:" 2>/dev/null || true)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

_cascade_count_file() {
  local n=0
  if [[ -f "$CASCADE_RULES" ]]; then
    n=$(grep -cvE '^\s*(#|$)' "$CASCADE_RULES" 2>/dev/null || true)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
  fi
  echo "$n"
}

_cascade_has_inport() {
  local proto="$1" port="$2"
  [[ -f "$CASCADE_RULES" ]] || return 1
  grep -qE "^${proto}\|${port}\|" "$CASCADE_RULES" 2>/dev/null
}

_cascade_enable_forward() {
  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  fi
  if ! grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/sysctl.conf 2>/dev/null && \
     ! grep -rqE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/sysctl.d/ 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
}

_cascade_apply_one() {
  local proto="$1" in_port="$2" target_ip="$3" out_port="$4"
  local tag iface
  tag=$(_cascade_rule_tag "$proto" "$in_port")
  iface=$(_cascade_get_iface)

  _cascade_log_info "apply: ${proto} ${in_port} -> ${target_ip}:${out_port} (iface=${iface}, tag=${tag})"

  # АНТИ-ДУБЛЬ: сначала удаляем все существующие правила с этим тегом
  # (в любом из 3 наборов: nat PREROUTING, filter FORWARD, nat POSTROUTING).
  # Используем iptables-save (однострочный вывод) вместо iptables -S
  # — последний в nf_tables-бэкенде ломает длинные правила на несколько строк.
  local line del_cmd
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"$tag"* ]] && continue
    del_cmd="${line/-A /-D }"
    # shellcheck disable=SC2086
    iptables -t nat $del_cmd 2>/dev/null || true
  done < <(iptables-save -t nat 2>/dev/null | grep -F "$tag" || true)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"$tag"* ]] && continue
    del_cmd="${line/-A /-D }"
    # shellcheck disable=SC2086
    iptables $del_cmd 2>/dev/null || true
  done < <(iptables-save 2>/dev/null | grep -F "$tag" || true)

  # Теперь чисто — добавляем
  if ! iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" \
       -j DNAT --to-destination "${target_ip}:${out_port}" \
       -m comment --comment "$tag" 2>/dev/null; then
    _cascade_log_error "iptables DNAT failed: ${proto} ${in_port} -> ${target_ip}:${out_port}"
    return 1
  fi

  if ! iptables -I FORWARD 1 -p "$proto" -d "$target_ip" --dport "$out_port" \
       -j ACCEPT -m comment --comment "$tag" 2>/dev/null; then
    _cascade_log_error "iptables FORWARD failed: ${proto} ${target_ip}:${out_port}"
    return 1
  fi

  if ! iptables -t nat -A POSTROUTING -o "$iface" -p "$proto" -d "$target_ip" --dport "$out_port" \
       -j MASQUERADE -m comment --comment "$tag" 2>/dev/null; then
    _cascade_log_error "iptables MASQUERADE failed: ${proto} ${iface} ${target_ip}:${out_port}"
    return 1
  fi

  _cascade_log_info "apply OK: ${tag}"
  return 0
}

_cascade_remove_one() {
  local proto="$1" in_port="$2"
  local tag
  tag=$(_cascade_rule_tag "$proto" "$in_port")
  local removed=0

  _cascade_log_info "remove: ${proto} ${in_port} (tag=${tag})"

  # Достаём актуальные параметры правила из файла (target_ip, out_port)
  # чтобы удалить ТОЧНО теми же аргументами что были при добавлении.
  local target_ip="" out_port=""
  if [[ -f "$CASCADE_RULES" ]]; then
    local fp fin ftgt fout frest
    # shellcheck disable=SC2034  # frest — приёмник остатка строки, нужен для корректного сплита
    while IFS='|' read -r fp fin ftgt fout frest; do
      if [[ "$fp" == "$proto" && "$fin" == "$in_port" ]]; then
        target_ip="$ftgt"
        out_port="$fout"
        break
      fi
    done < "$CASCADE_RULES"
  fi

  local iface
  iface=$(_cascade_get_iface)

  # Если знаем параметры — удаляем ТОЧНО как добавляли (idempotent, в цикле пока удаляется)
  if [[ -n "$target_ip" && -n "$out_port" ]]; then
    while iptables -t nat -D PREROUTING -p "$proto" --dport "$in_port" \
        -j DNAT --to-destination "${target_ip}:${out_port}" \
        -m comment --comment "$tag" 2>/dev/null; do
      removed=$((removed + 1))
    done
    while iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$out_port" \
        -j ACCEPT -m comment --comment "$tag" 2>/dev/null; do
      removed=$((removed + 1))
    done
    while iptables -t nat -D POSTROUTING -o "$iface" -p "$proto" -d "$target_ip" --dport "$out_port" \
        -j MASQUERADE -m comment --comment "$tag" 2>/dev/null; do
      removed=$((removed + 1))
    done
  fi

  # Fallback: если параметров нет (файл уже пуст) или таргет/порт изменились —
  # ищем по тегу через iptables-save (одна строка = одно правило, в отличие от -S)
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"$tag"* ]] && continue
    local del_cmd="${line/-A /-D }"
    # shellcheck disable=SC2086
    if iptables -t nat $del_cmd 2>/dev/null; then
      removed=$((removed + 1))
    fi
  done < <(iptables-save -t nat 2>/dev/null | grep -F "$tag" || true)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"$tag"* ]] && continue
    local del_cmd="${line/-A /-D }"
    # shellcheck disable=SC2086
    if iptables $del_cmd 2>/dev/null; then
      removed=$((removed + 1))
    fi
  done < <(iptables-save 2>/dev/null | grep -F "$tag" || true)

  _cascade_log_info "remove result: tag=${tag}, removed=${removed}"
  [[ $removed -gt 0 ]]
}

_cascade_flush_iptables() {
  local removed=0
  local iface; iface=$(_cascade_get_iface)

  # ШАГ 1: если файл правил ещё существует — удаляем детерминированно
  # (точные команды с теми же аргументами что использовали при добавлении)
  if [[ -f "$CASCADE_RULES" ]]; then
    local fp fin ftgt fout frest tag
    # shellcheck disable=SC2034  # frest — приёмник остатка строки, нужен для корректного сплита
    while IFS='|' read -r fp fin ftgt fout frest; do
      [[ -z "${fp:-}" || "${fp:0:1}" == "#" ]] && continue
      [[ "$fp" != "tcp" && "$fp" != "udp" ]] && continue
      [[ -z "${fin:-}" || -z "${ftgt:-}" || -z "${fout:-}" ]] && continue
      tag="${CASCADE_TAG}:${fp}-${fin}"
      while iptables -t nat -D PREROUTING -p "$fp" --dport "$fin" \
          -j DNAT --to-destination "${ftgt}:${fout}" \
          -m comment --comment "$tag" 2>/dev/null; do
        removed=$((removed + 1))
      done
      while iptables -D FORWARD -p "$fp" -d "$ftgt" --dport "$fout" \
          -j ACCEPT -m comment --comment "$tag" 2>/dev/null; do
        removed=$((removed + 1))
      done
      while iptables -t nat -D POSTROUTING -o "$iface" -p "$fp" -d "$ftgt" --dport "$fout" \
          -j MASQUERADE -m comment --comment "$tag" 2>/dev/null; do
        removed=$((removed + 1))
      done
    done < "$CASCADE_RULES"
  fi

  # ШАГ 2: fallback — убираем всё что осталось с нашим тегом, парся iptables-save
  # (iptables-save выводит правила однострочно, в отличие от iptables -S который в nftables-бэкенде ломает строки)
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"${CASCADE_TAG}:"* ]] && continue
    # Строка вида: -A POSTROUTING -d 1.2.3.4/32 -o eth0 ... --comment "awg-cascade:udp-45172" -j MASQUERADE
    # Преобразуем -A в -D и выполняем
    local del_cmd="${line/-A /-D }"
    # shellcheck disable=SC2086
    iptables -t nat $del_cmd 2>/dev/null && removed=$((removed + 1)) || true
  done < <(iptables-save -t nat 2>/dev/null | grep -F "${CASCADE_TAG}:" || true)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"${CASCADE_TAG}:"* ]] && continue
    local del_cmd="${line/-A /-D }"
    # shellcheck disable=SC2086
    iptables $del_cmd 2>/dev/null && removed=$((removed + 1)) || true
  done < <(iptables-save 2>/dev/null | grep -F "${CASCADE_TAG}:" || true)

  _cascade_log_warn "flush all: removed=${removed}"
  echo "$removed"
}

_cascade_save_to_file() {
  local proto="$1" in_port="$2" target_ip="$3" out_port="$4" comment="${5:-}"
  mkdir -p "$CASCADE_DIR"
  touch "$CASCADE_RULES"
  echo "${proto}|${in_port}|${target_ip}|${out_port}|${comment}" >> "$CASCADE_RULES"
  _cascade_log_info "saved to file: ${proto}|${in_port}|${target_ip}|${out_port}|${comment}"
}

_cascade_delete_from_file() {
  local proto="$1" in_port="$2"
  [[ -f "$CASCADE_RULES" ]] || return 0
  local tmp
  tmp=$(mktemp) || return 1
  grep -vE "^${proto}\|${in_port}\|" "$CASCADE_RULES" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$CASCADE_RULES"
}

_cascade_install_persist() {
  mkdir -p "$CASCADE_DIR"

  cat > "$CASCADE_APPLY_SCRIPT" << 'APPLY_EOF'
#!/bin/bash
# Авто-применение правил каскада при старте системы
# Намеренно НЕ используем set -u — внутри while-read могут возникать
# временно неинициализированные переменные на пустых выводах iptables.
set +u
RULES="/etc/awg-cascade/rules.conf"
TAG_PREFIX="awg-cascade"
LOG="/var/log/awg-cascade.log"

# Хелпер логирования (с ротацией >1MB)
_log() {
  local level="$1"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -f "$LOG" ]]; then
    local sz; sz=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    [[ "$sz" -gt 1048576 ]] && mv "$LOG" "${LOG}.old" 2>/dev/null
  fi
  [[ -f "$LOG" ]] || { touch "$LOG" 2>/dev/null && chmod 600 "$LOG" 2>/dev/null; }
  printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >> "$LOG" 2>/dev/null || true
}

_log INFO "=== systemd apply-script started ==="

[[ -f "$RULES" ]] || { _log INFO "no rules file, exit"; exit 0; }

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

get_iface() {
  local i
  i=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  echo "${i:-eth0}"
}
IFACE=$(get_iface)
_log INFO "iface=${IFACE}"

applied=0
failed=0
while IFS='|' read -r proto in_port target_ip out_port comment; do
  [[ -z "$proto" || "${proto:0:1}" == "#" ]] && continue
  [[ -z "$in_port" || -z "$target_ip" || -z "$out_port" ]] && continue
  TAG="${TAG_PREFIX}:${proto}-${in_port}"

  # АНТИ-ДУБЛЬ: чистим все старые правила с этим тегом (если есть).
  # Используем iptables-save (одна строка = одно правило) вместо iptables -S
  # — последний в nf_tables-бэкенде ломает длинные правила на несколько строк.
  line=""
  del_cmd=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"$TAG"* ]] && continue
    del_cmd="${line/-A /-D }"
    iptables -t nat $del_cmd 2>/dev/null || true
  done < <(iptables-save -t nat 2>/dev/null | grep -F "$TAG" || true)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *"$TAG"* ]] && continue
    del_cmd="${line/-A /-D }"
    iptables $del_cmd 2>/dev/null || true
  done < <(iptables-save 2>/dev/null | grep -F "$TAG" || true)

  # Применяем
  err_count=0
  if ! iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" \
       -j DNAT --to-destination "${target_ip}:${out_port}" \
       -m comment --comment "$TAG" 2>/dev/null; then
    _log ERROR "DNAT failed: ${proto} ${in_port} -> ${target_ip}:${out_port}"
    err_count=$((err_count + 1))
  fi
  if ! iptables -I FORWARD 1 -p "$proto" -d "$target_ip" --dport "$out_port" \
       -j ACCEPT -m comment --comment "$TAG" 2>/dev/null; then
    _log ERROR "FORWARD failed: ${proto} ${target_ip}:${out_port}"
    err_count=$((err_count + 1))
  fi
  if ! iptables -t nat -A POSTROUTING -o "$IFACE" -p "$proto" -d "$target_ip" --dport "$out_port" \
       -j MASQUERADE -m comment --comment "$TAG" 2>/dev/null; then
    _log ERROR "MASQUERADE failed: ${proto} ${IFACE} ${target_ip}:${out_port}"
    err_count=$((err_count + 1))
  fi

  if [[ $err_count -eq 0 ]]; then
    _log INFO "applied: ${TAG} -> ${target_ip}:${out_port}"
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
  fi
done < "$RULES"

_log INFO "=== apply done: applied=${applied} failed=${failed} ==="

exit 0
APPLY_EOF
  chmod +x "$CASCADE_APPLY_SCRIPT"

  cat > "$CASCADE_SERVICE" << SERVICE_EOF
[Unit]
Description=AmneziaWG Cascade (port forwarding rules)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CASCADE_APPLY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable awg-cascade.service >/dev/null 2>&1 || true
}

_cascade_status() {
  local active file_count iface
  active=$(_cascade_count_iptables)
  file_count=$(_cascade_count_file)
  iface=$(_cascade_get_iface)

  echo -e "  ${D}Egress интерфейс:${N}  ${W}${iface}${N}"
  echo -e "  ${D}Правил в файле:${N}    ${W}${file_count}${N}"
  echo -e "  ${D}Правил в iptables:${N} ${W}${active}${N}"

  # Сравнение БЕЗОПАСНО — счётчики гарантированно числа
  if (( file_count != active )); then
    echo -e "  ${Y}⚠ рассинхрон файла и iptables (пересоздать: меню → 5 → 1)${N}"
  fi

  if systemctl is-enabled awg-cascade.service &>/dev/null; then
    echo -e "  ${D}Persist (systemd):${N}  ${G}● включён${N}"
  else
    echo -e "  ${D}Persist (systemd):${N}  ${D}○ выключен${N}"
  fi

  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
    echo -e "  ${D}IP forwarding:${N}     ${G}● включён${N}"
  else
    echo -e "  ${D}IP forwarding:${N}     ${R}○ выключен (требуется!)${N}"
  fi

  if command -v ufw >/dev/null 2>&1; then
    if _cascade_ufw_active; then
      local fwpol
      fwpol=$(grep -oE '^DEFAULT_FORWARD_POLICY="[^"]*"' /etc/default/ufw 2>/dev/null | grep -oE '"[^"]*"' | tr -d '"')
      if [[ "$fwpol" == "ACCEPT" ]]; then
        echo -e "  ${D}UFW:${N}              ${G}● активен, FORWARD=ACCEPT (ок)${N}"
      else
        echo -e "  ${D}UFW:${N}              ${Y}⚠ активен, FORWARD=${fwpol:-?} (нужно ACCEPT)${N}"
      fi
    else
      echo -e "  ${D}UFW:${N}              ${D}○ установлен, не активен${N}"
    fi
  fi
}

# Универсальный поток добавления правила
# $1 = "standard" (один порт на вход/выход) | "custom" (разные)
_cascade_add_rule_flow() {
  local mode="$1"
  local proto in_port target_ip out_port comment pchoice

  echo ""
  hdr "➕  Добавить правило каскада ($([[ "$mode" == "standard" ]] && echo "один порт" || echo "разные порты"))"
  echo ""
  echo -e "  ${D}→ Клиент будет подключаться к этому серверу на указанный порт,${N}"
  echo -e "  ${D}→ а трафик прозрачно уйдёт на зарубежный сервер.${N}"
  echo ""

  # ─── Протокол: явный цикл с read, БЕЗ read_choice (там min/max диапазон) ───
  while true; do
    safe_read pchoice "$(echo -e "${C}  Протокол [udp/tcp/both] (Enter=udp): ${N}")"
    pchoice="${pchoice,,}"
    pchoice="${pchoice// /}"
    [[ -z "$pchoice" ]] && pchoice="udp"
    case "$pchoice" in
      udp|u)    proto="udp"; break ;;
      tcp|t)    proto="tcp"; break ;;
      both|b|2) proto="both"; break ;;
      *) err "Введи 'udp', 'tcp' или 'both'" ;;
    esac
  done

  # ─── IP назначения ───
  while true; do
    safe_read target_ip "$(echo -e "${C}  IP конечного сервера: ${N}")"
    target_ip="${target_ip// /}"
    if _cascade_valid_ip "$target_ip"; then break; fi
    err "Невалидный IPv4. Пример: 5.6.7.8"
  done

  # ─── Порты ───
  if [[ "$mode" == "standard" ]]; then
    while true; do
      safe_read in_port "$(echo -e "${C}  Порт (одинаковый вход и выход): ${N}")"
      in_port="${in_port// /}"
      if _cascade_valid_port "$in_port"; then break; fi
      err "Невалидный порт (1-65535)"
    done
    out_port="$in_port"
  else
    while true; do
      safe_read in_port "$(echo -e "${C}  Локальный порт (на этом сервере): ${N}")"
      in_port="${in_port// /}"
      if _cascade_valid_port "$in_port"; then break; fi
      err "Невалидный порт (1-65535)"
    done
    while true; do
      safe_read out_port "$(echo -e "${C}  Порт конечного сервера: ${N}")"
      out_port="${out_port// /}"
      if _cascade_valid_port "$out_port"; then break; fi
      err "Невалидный порт (1-65535)"
    done
  fi

  # ─── Комментарий ───
  safe_read comment "$(echo -e "${D}  Комментарий (Enter — пропустить): ${N}")"
  comment="${comment//|/ }"

  # ─── Применение ───
  local protos=()
  if [[ "$proto" == "both" ]]; then
    protos=("udp" "tcp")
  else
    protos=("$proto")
  fi

  echo ""
  _cascade_enable_forward

  local p added=0 skipped=0 failed=0
  for p in "${protos[@]}"; do
    if _cascade_has_inport "$p" "$in_port"; then
      warn "${p^^} ${in_port} → уже есть в файле, пропускаю"
      skipped=$((skipped + 1))
      continue
    fi
    if _cascade_apply_one "$p" "$in_port" "$target_ip" "$out_port"; then
      _cascade_save_to_file "$p" "$in_port" "$target_ip" "$out_port" "$comment"
      _cascade_ufw_integrate_rule "$p" "$in_port" "$target_ip" "$out_port"
      ok "Правило добавлено: ${p} ${in_port} → ${target_ip}:${out_port}"
      added=$((added + 1))
    else
      err "Не удалось применить ${p^^} ${in_port}"
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [[ $added -gt 0 ]]; then
    _cascade_install_persist
    local pub_ip
    pub_ip=$(get_public_ip 2>/dev/null || echo "<IP_этого_сервера>")
    info "На клиенте в Endpoint укажи: ${W}${pub_ip}:${in_port}${N}"
    if _cascade_ufw_active; then
      info "UFW: открыт порт ${in_port}/${proto}, route allow добавлен"
    fi
  fi
  if [[ $skipped -gt 0 || $failed -gt 0 ]]; then
    echo -e "  ${D}Добавлено: ${added} | Пропущено: ${skipped} | Ошибок: ${failed}${N}"
  fi
}

_cascade_add_standard() { _cascade_add_rule_flow "standard"; }
_cascade_add_custom()   { _cascade_add_rule_flow "custom"; }

_cascade_list() {
  echo ""
  hdr "📋  Активные маршруты"
  echo ""

  local file_count
  file_count=$(_cascade_count_file)
  if (( file_count == 0 )); then
    info "Маршрутов нет"
    return 0
  fi

  printf "  ${D}%-4s %-6s %-7s %-18s %-7s %s${N}\n" "#" "PROTO" "IN" "→ TARGET" "OUT" "COMMENT"
  echo -e "  ${D}────────────────────────────────────────────────────────────────${N}"
  local n=0 proto in_port target_ip out_port comment mark tag
  while IFS='|' read -r proto in_port target_ip out_port comment; do
    [[ -z "${proto:-}" || "${proto:0:1}" == "#" ]] && continue
    n=$((n + 1))
    tag=$(_cascade_rule_tag "$proto" "$in_port")
    if iptables-save -t nat 2>/dev/null | grep -qF "$tag"; then
      mark="${G}●${N}"
    else
      mark="${R}○${N}"
    fi
    printf "  %b %-2s %-6s %-7s %-18s %-7s %s\n" \
      "$mark" "$n" "${proto^^}" "$in_port" "$target_ip" "$out_port" "${comment:-—}"
  done < "$CASCADE_RULES"
  echo ""
  echo -e "  ${D}${G}●${D} — применено в iptables, ${R}○${D} — записано но не активно${N}"
}

_cascade_delete_one() {
  _cascade_list
  local count
  count=$(_cascade_count_file)
  (( count == 0 )) && return 0

  echo ""
  local num
  read_choice num "$(echo -e "${C}  Номер для удаления (0 = отмена): ${N}")" 0 "$count" "0"
  [[ "$num" == "0" ]] && { info "Отменено"; return 0; }

  local n=0 proto in_port target_ip out_port comment found_rule=""
  while IFS='|' read -r proto in_port target_ip out_port comment; do
    [[ -z "${proto:-}" || "${proto:0:1}" == "#" ]] && continue
    n=$((n + 1))
    if (( n == num )); then
      found_rule="yes"
      break
    fi
  done < "$CASCADE_RULES"

  [[ -n "$found_rule" ]] || { err "Не нашёл #$num"; return 1; }

  echo ""
  local confirm
  read_yesno confirm "Удалить ${proto^^} ${in_port} → ${target_ip}:${out_port}? [y/N]: " "n"
  [[ "$confirm" == "y" ]] || { info "Отмена"; return 0; }

  if _cascade_remove_one "$proto" "$in_port"; then
    _cascade_delete_from_file "$proto" "$in_port"
    _cascade_ufw_revoke_rule "$proto" "$in_port" "$target_ip" "$out_port"
    ok "Удалено"
  else
    _cascade_delete_from_file "$proto" "$in_port"
    _cascade_ufw_revoke_rule "$proto" "$in_port" "$target_ip" "$out_port"
    warn "В iptables не нашлось — почистил только файл"
  fi
}

_cascade_flush() {
  local file_count active
  file_count=$(_cascade_count_file)
  active=$(_cascade_count_iptables)

  if (( file_count == 0 && active == 0 )); then
    info "Каскад пуст"
    return 0
  fi

  echo ""
  warn "Будут удалены ВСЕ правила каскада (файл: ${file_count}, iptables: ${active})"
  warn "AmneziaWG / WARP / DNS — НЕ затрагиваются"
  echo ""
  local confirm
  read_yesno confirm "Точно сбросить все маршруты? [y/N]: " "n"
  [[ "$confirm" == "y" ]] || { info "Отмена"; return 0; }

  local removed
  removed=$(_cascade_flush_iptables)
  : > "$CASCADE_RULES" 2>/dev/null || true
  # Снести все UFW-правила каскада
  _cascade_ufw_full_revoke
  ok "Удалено правил из iptables: $removed"
  ok "Файл правил очищен"
  if _cascade_ufw_active; then
    ok "UFW-правила каскада удалены"
  fi
}

_cascade_uninstall() {
  echo ""
  warn "Полное удаление модуля Каскад:"
  echo -e "    • все правила iptables (с тегом ${CASCADE_TAG})"
  echo -e "    • $CASCADE_RULES"
  echo -e "    • systemd-сервис awg-cascade.service"
  echo -e "    • $CASCADE_APPLY_SCRIPT"
  echo ""
  warn "AmneziaWG / WARP / DNS — НЕ затрагиваются"
  echo ""
  local confirm
  read_yesno confirm "Удалить модуль полностью? [y/N]: " "n"
  [[ "$confirm" == "y" ]] || { info "Отмена"; return 0; }

  systemctl disable --now awg-cascade.service >/dev/null 2>&1 || true
  rm -f "$CASCADE_SERVICE" "$CASCADE_APPLY_SCRIPT"
  systemctl daemon-reload >/dev/null 2>&1 || true

  local removed
  removed=$(_cascade_flush_iptables)

  # UFW: откат интеграции (восстановит /etc/default/ufw из бэкапа, если был)
  _cascade_ufw_full_revoke

  rm -rf "$CASCADE_DIR"

  _cascade_log_warn "module uninstalled (removed=${removed})"

  ok "Удалено правил из iptables: $removed"
  if _cascade_ufw_active; then
    ok "UFW-правила каскада удалены, /etc/default/ufw восстановлен"
  fi
  ok "Модуль Каскад снесён"
}

# ── Диагностика ────────────────────────────────────────────
# Полный дамп состояния каскада. Удобно показать клиенту в чате
# или одной командой собрать всё для отправки в поддержку.
_cascade_diagnose() {
  echo ""
  hdr "Диагностика каскада"
  echo ""

  echo -e "${W}── Окружение ──${N}"
  echo -e "  Hostname     : $(hostname 2>/dev/null || echo '?')"
  echo -e "  IP сервера   : $(get_public_ip 2>/dev/null || echo '?')"
  echo -e "  Интерфейс    : $(_cascade_get_iface)"
  echo -e "  IP forward   : $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
  echo -e "  Дата/время   : $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  echo -e "${W}── Systemd сервис ──${N}"
  if systemctl is-enabled awg-cascade.service &>/dev/null; then
    echo -e "  Enabled      : ${G}да${N}"
  else
    echo -e "  Enabled      : ${R}нет${N}"
  fi
  local active_status
  active_status=$(systemctl is-active awg-cascade.service 2>/dev/null | tr -d '\n\r ' || echo "inactive")
  [[ -z "$active_status" ]] && active_status="inactive"
  echo -e "  Active       : $active_status (для oneshot 'inactive' = норма после отработки)"
  echo ""

  echo -e "${W}── Файл правил ($CASCADE_RULES) ──${N}"
  if [[ -f "$CASCADE_RULES" ]]; then
    local cnt; cnt=$(_cascade_count_file)
    echo -e "  Правил       : $cnt"
    if (( cnt > 0 )); then
      echo -e "  ${D}Содержимое:${N}"
      sed 's/^/    /' "$CASCADE_RULES"
    fi
  else
    echo -e "  ${Y}Файл отсутствует${N}"
  fi
  echo ""

  echo -e "${W}── iptables: nat PREROUTING (DNAT) ──${N}"
  local nat_pre
  nat_pre=$(iptables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null | grep -E "Chain|awg-cascade" || true)
  if [[ -n "$nat_pre" ]]; then
    echo "$nat_pre" | sed 's/^/  /'
  else
    echo -e "  ${D}(нет правил каскада)${N}"
  fi
  echo ""

  echo -e "${W}── iptables: nat POSTROUTING (MASQUERADE) ──${N}"
  local nat_post
  nat_post=$(iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null | grep -E "Chain|awg-cascade" || true)
  if [[ -n "$nat_post" ]]; then
    echo "$nat_post" | sed 's/^/  /'
  else
    echo -e "  ${D}(нет правил каскада)${N}"
  fi
  echo ""

  echo -e "${W}── iptables: filter FORWARD ──${N}"
  local fwd
  fwd=$(iptables -L FORWARD -n -v --line-numbers 2>/dev/null | grep -E "Chain|awg-cascade" || true)
  if [[ -n "$fwd" ]]; then
    echo "$fwd" | sed 's/^/  /'
  else
    echo -e "  ${D}(нет правил каскада)${N}"
  fi
  echo ""

  echo -e "${W}── Достижимость target IP ──${N}"
  if [[ -f "$CASCADE_RULES" ]]; then
    local checked=""
    while IFS='|' read -r _p _ip ftgt _ _rest; do
      [[ -z "${_p:-}" || "${_p:0:1}" == "#" ]] && continue
      [[ -z "${ftgt:-}" ]] && continue
      # пропускаем повторы
      [[ ",${checked}," == *",${ftgt},"* ]] && continue
      checked="${checked},${ftgt}"
      if ping -c 1 -W 2 "$ftgt" >/dev/null 2>&1; then
        echo -e "  ${G}●${N} $ftgt — ping OK"
      else
        echo -e "  ${R}✗${N} $ftgt — ping не отвечает (это норма если на target отключен ICMP)"
      fi
    done < "$CASCADE_RULES"
    [[ -z "$checked" ]] && echo -e "  ${D}(нет target IP для проверки)${N}"
  else
    echo -e "  ${D}(нет правил)${N}"
  fi
  echo ""

  echo -e "${W}── UFW (если установлен) ──${N}"
  if command -v ufw >/dev/null 2>&1; then
    local ufw_st; ufw_st=$(ufw status 2>/dev/null | head -1)
    echo -e "  $ufw_st"
    if _cascade_ufw_active; then
      local fwpol
      fwpol=$(grep -oE '^DEFAULT_FORWARD_POLICY="[^"]*"' /etc/default/ufw 2>/dev/null | head -1)
      echo -e "  ${fwpol:-DEFAULT_FORWARD_POLICY=<не найден>}"
      echo -e "  ${D}Правила UFW связанные с каскадом:${N}"
      ufw status 2>/dev/null | grep -E "${CASCADE_TAG}:|^[0-9]+/" | grep -E "${CASCADE_TAG}:|ALLOW" | sed 's/^/    /' || echo "    (нет)"
    fi
  else
    echo -e "  ${D}(UFW не установлен)${N}"
  fi
  echo ""

  echo -e "${W}── Лог-файл ($CASCADE_LOG) ──${N}"
  if [[ -f "$CASCADE_LOG" ]]; then
    local lsz; lsz=$(stat -c%s "$CASCADE_LOG" 2>/dev/null || echo 0)
    echo -e "  Размер       : ${lsz} байт"
    echo -e "  ${D}Последние 20 строк:${N}"
    tail -n 20 "$CASCADE_LOG" 2>/dev/null | sed 's/^/    /' || echo "    (пусто)"
  else
    echo -e "  ${D}(лог-файл ещё не создан)${N}"
  fi
  echo ""
}

# Экспорт диагностики в файл для отправки в поддержку
_cascade_export_debug() {
  local outfile="/tmp/cascade-debug-$(date +%Y%m%d-%H%M%S).txt"
  echo ""
  hdr "📤  Экспорт диагностики"
  echo ""
  info "Собираю информацию в $outfile..."

  {
    echo "═══════════════════════════════════════════════════════"
    echo "  AWG Cascade — Debug Report"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    # Прогоним диагностику и снимем ANSI коды для чистого текста
    _cascade_diagnose 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Полный лог-файл (если есть)"
    echo "═══════════════════════════════════════════════════════"
    if [[ -f "$CASCADE_LOG" ]]; then
      cat "$CASCADE_LOG"
    else
      echo "(нет лог-файла)"
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  systemctl status awg-cascade.service"
    echo "═══════════════════════════════════════════════════════"
    systemctl status awg-cascade.service --no-pager 2>&1 || true
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  journalctl -u awg-cascade.service (последние 50)"
    echo "═══════════════════════════════════════════════════════"
    journalctl -u awg-cascade.service -n 50 --no-pager 2>&1 || echo "(journalctl недоступен)"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  ip route"
    echo "═══════════════════════════════════════════════════════"
    ip route 2>&1 || true
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Версия iptables"
    echo "═══════════════════════════════════════════════════════"
    iptables --version 2>&1 || true
    echo ""
    echo "=== END OF REPORT ==="
  } > "$outfile" 2>&1

  chmod 600 "$outfile" 2>/dev/null || true
  local sz
  sz=$(stat -c%s "$outfile" 2>/dev/null || echo "?")
  ok "Готово: $outfile (${sz} байт)"
  echo ""
  info "Покажи файл командой:"
  echo -e "  ${W}cat $outfile${N}"
  info "Или скачай через scp / отправь содержимое в поддержку."
  _cascade_log_info "exported debug report to $outfile"
}

do_cascade_menu() {
  set +e
  while true; do
    clear
    echo ""
    hdr "🌉  Каскад (проброс портов на зарубежный VPS)"
    echo ""
    _cascade_status
    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  1) Добавить правило ${D}(один порт)${N}"
    echo -e "  2) Добавить кастомное правило ${D}(разные порты)${N}"
    echo -e "  3) Список правил"
    echo -e "  4) Удалить одно правило"
    echo -e "  ${Y}5) Сбросить все правила каскада${N}"
    echo -e "  ${C}6) Диагностика${N} ${D}(полный дамп для отладки)${N}"
    echo -e "  ${C}7) Экспорт для поддержки${N} ${D}(собрать всё в один файл)${N}"
    echo -e "  ${R}d) Удалить модуль каскада полностью${N}"
    echo -e "  0) Назад в главное меню"
    echo ""
    local CASCADE_CHOICE
    read_choice CASCADE_CHOICE "$(echo -e "${C}  Выбор [0-7, d]: ${N}")" 0 7 "0" "d"

    case "${CASCADE_CHOICE:-}" in
      1) _cascade_add_standard; read -rp "Enter..." ;;
      2) _cascade_add_custom;   read -rp "Enter..." ;;
      3) _cascade_list;         read -rp "Enter..." ;;
      4) _cascade_delete_one;   read -rp "Enter..." ;;
      5) _cascade_flush;        read -rp "Enter..." ;;
      6) _cascade_diagnose;     read -rp "Enter..." ;;
      7) _cascade_export_debug; read -rp "Enter..." ;;
      d|D) _cascade_uninstall;  read -rp "Enter..." ;;
      0|"")
        set -e
        return 0
        ;;
      *) warn "Неверный выбор"; sleep 1 ;;
    esac
  done
  set -e
}

# ═══════════════════════════════════════════════════════════
# Expire-механика: срок действия клиентов
# ═══════════════════════════════════════════════════════════

# Установить expire-инфраструктуру (timer + проверочный скрипт)
_expire_install() {
  # Идемпотентность
  if systemctl is-active --quiet awg2-expire.timer 2>/dev/null && \
     [[ -x "$EXPIRE_CHECK_BIN" ]]; then
    return 0
  fi

  mkdir -p "$EXPIRE_STATE_DIR" 2>/dev/null || true
  touch "$EXPIRE_LOG" 2>/dev/null || true
  chmod 600 "$EXPIRE_LOG" 2>/dev/null || true

  cat > "$EXPIRE_CHECK_BIN" << 'EXPIRE_EOF'
#!/bin/bash
# awg2-expire-check — проверяет peer'ы со сроком действия
# Запускается из awg2-expire.timer раз в минуту.
set -uo pipefail

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
SUSPEND_IP="127.0.0.2/32"
BOT_CONF="/etc/awg-bot.conf"
LOG="/var/log/awg2-expire.log"
STATE_DIR="/var/lib/awg2-expire"

[[ ! -f "$SERVER_CONF" ]] && exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

notify_tg() {
  # Опциональное уведомление — молча выходим если бот не настроен
  [[ ! -f "$BOT_CONF" ]] && return 0
  local token chat_id text="$1"
  token=$(grep -E '^BOT_TOKEN=' "$BOT_CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  chat_id=$(grep -E '^ADMIN_CHAT_ID=' "$BOT_CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  [[ -z "$token" || -z "$chat_id" ]] && return 0
  # Токен НЕ передаём в argv (иначе виден в `ps`/списке процессов).
  # Отдаём url и data в curl через --config со stdin — argv остаётся чистым.
  curl -sf --max-time 5 --config - >/dev/null 2>&1 <<CURLCFG || true
url = "https://api.telegram.org/bot${token}/sendMessage"
data = "chat_id=${chat_id}"
data = "parse_mode=HTML"
data-urlencode = "text=${text}"
CURLCFG
}

# Питон делает всю работу: парсит, мутирует конфиг атомарно, syncconf, conntrack
events=$(python3 - "$SERVER_CONF" "$SUSPEND_IP" "$STATE_DIR" << 'PYEOF' 2>>"$LOG"
import sys, re, os, time, subprocess, pathlib, tempfile

conf_path, suspend, state_dir = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time())

try:
    text = pathlib.Path(conf_path).read_text()
except Exception as e:
    print(f"# read failed: {e}", file=sys.stderr)
    sys.exit(0)

# Header (до первого [Peer]) + список peer-блоков
parts  = re.split(r'(?=\[Peer\])', text)
header = parts[0]
peers  = parts[1:]

changed = False
events_expired = []   # (name, orig_ip)
events_warn1h  = []   # (name, mins_left)

new_peers = []
for block in peers:
    name_m   = re.search(r'^#\s+(\S+)\s*$', block, re.M)
    expire_m = re.search(r'^#\s*expires=(\d+)\s*$', block, re.M)
    orig_m   = re.search(r'^#\s*orig_ips=(.+?)\s*$', block, re.M)
    pk_m     = re.search(r'^PublicKey\s*=\s*(\S+)', block, re.M)
    aip_m    = re.search(r'^AllowedIPs\s*=\s*(.+?)\s*$', block, re.M)

    if not (expire_m and pk_m and aip_m):
        new_peers.append(block); continue

    expires    = int(expire_m.group(1))
    pubkey     = pk_m.group(1)
    current_ip = aip_m.group(1).strip()
    name       = name_m.group(1) if name_m else pubkey[:8]
    is_suspended = (current_ip == suspend)

    # Истёк и ещё не заблокирован → блокируем
    if now >= expires and not is_suspended:
        # Сохраняем оригинальный IP, если ещё не сохранён
        if not orig_m:
            block = re.sub(
                r'(^#\s*expires=\d+\s*$)',
                lambda m: m.group(1) + '\n# orig_ips=' + current_ip,
                block, count=1, flags=re.M
            )
        # Меняем AllowedIPs на suspend
        block = re.sub(
            r'^(AllowedIPs\s*=\s*).+$',
            r'\g<1>' + suspend,
            block, count=1, flags=re.M
        )
        changed = True
        events_expired.append((name, pubkey, current_ip))

    # Не истёк, осталось <= 60 мин → предупреждение (один раз на peer)
    elif not is_suspended and 0 < (expires - now) <= 3600:
        safe_pk   = re.sub(r'[^A-Za-z0-9]', '_', pubkey)
        lock_file = os.path.join(state_dir, f"warn1h_{safe_pk}")
        if not os.path.exists(lock_file):
            mins_left = max(1, (expires - now) // 60)
            events_warn1h.append((name, mins_left))
            try:
                pathlib.Path(lock_file).write_text(str(now))
            except Exception:
                pass

    new_peers.append(block)

# Атомарная запись конфига если были изменения
if changed:
    new_text = header + ''.join(new_peers)
    try:
        d   = os.path.dirname(conf_path)
        fd, tmp = tempfile.mkstemp(dir=d, prefix='.awg0.', suffix='.tmp')
        try:
            with os.fdopen(fd, 'w') as f:
                f.write(new_text)
            os.chmod(tmp, 0o600)
            os.rename(tmp, conf_path)
        except Exception:
            try: os.unlink(tmp)
            except Exception: pass
            raise
    except Exception as e:
        print(f"# write failed: {e}", file=sys.stderr)
        sys.exit(0)

    # syncconf — применяет без рестарта (другие peer'ы не рвутся)
    try:
        r = subprocess.run(['awg-quick', 'strip', 'awg0'],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            subprocess.run(['awg', 'syncconf', 'awg0', '/dev/stdin'],
                           input=r.stdout, text=True, timeout=10,
                           capture_output=True)
    except Exception as e:
        print(f"# syncconf failed: {e}", file=sys.stderr)

    # conntrack flush для каждого истёкшего (если conntrack доступен)
    if subprocess.run(['which', 'conntrack'], capture_output=True).returncode == 0:
        for name, pk, ip in events_expired:
            ip_only = ip.split('/')[0].split(',')[0].strip()
            if ip_only:
                try:
                    subprocess.run(['conntrack', '-D', '-s', ip_only],
                                   capture_output=True, timeout=5)
                except Exception:
                    pass

# События для bash-обёртки (TAB-separated)
for name, pk, ip in events_expired:
    print(f"EXPIRED\t{name}\t{ip}")
for name, mins in events_warn1h:
    print(f"WARN1H\t{name}\t{mins}")
PYEOF
)

# Шлём уведомления и пишем в лог
if [[ -n "$events" ]]; then
  while IFS=$'\t' read -r evt name arg; do
    case "$evt" in
      EXPIRED)
        log "expired: $name (was $arg)"
        notify_tg "🚫 Клиент <b>${name}</b> заблокирован: срок действия истёк."
        ;;
      WARN1H)
        log "warn1h: $name (${arg} min left)"
        notify_tg "⚠️ Клиент <b>${name}</b> истекает через ${arg} мин."
        ;;
    esac
  done <<< "$events"
fi

exit 0
EXPIRE_EOF

  chmod +x "$EXPIRE_CHECK_BIN"

  cat > "$EXPIRE_SERVICE" << EOF
[Unit]
Description=AWG Toolza — проверка сроков клиентов
After=awg-quick@awg0.service network-online.target

[Service]
Type=oneshot
ExecStart=$EXPIRE_CHECK_BIN
EOF

  cat > "$EXPIRE_TIMER" << 'EOF'
[Unit]
Description=AWG Toolza — таймер проверки сроков

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now awg2-expire.timer >/dev/null 2>&1
  if systemctl is-active --quiet awg2-expire.timer 2>/dev/null; then
    ok "Expire-таймер установлен (проверка раз в минуту)"
  else
    warn "Expire-таймер не запустился — проверь: systemctl status awg2-expire.timer"
  fi
}

# Удаление expire-инфраструктуры (вызывается из do_uninstall)
_expire_remove() {
  systemctl disable --now awg2-expire.timer >/dev/null 2>&1 || true
  rm -f "$EXPIRE_SERVICE" "$EXPIRE_TIMER" "$EXPIRE_CHECK_BIN"
  rm -rf "$EXPIRE_STATE_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# Конвертация "1h" / "6h" / "1d" / "7d" / "30d" / "YYYY-MM-DD HH:MM" в unix-ts
# Возвращает unix-ts на stdout, либо пустую строку при ошибке.
_expire_parse_duration() {
  local input="$1" ts=""
  input="${input// /}"
  if [[ "$input" =~ ^([0-9]+)h$ ]]; then
    ts=$(date -d "+${BASH_REMATCH[1]} hours" +%s 2>/dev/null || true)
  elif [[ "$input" =~ ^([0-9]+)d$ ]]; then
    ts=$(date -d "+${BASH_REMATCH[1]} days" +%s 2>/dev/null || true)
  elif [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2})?$ ]]; then
    # Заменяем T на пробел для date
    ts=$(date -d "${input/T/ }" +%s 2>/dev/null || true)
  fi
  echo "$ts"
}

# Прочитать у клиента expire_ts и orig_ips. Stdout: "<expire_ts>|<orig_ips>"
# Если нет expires — пустая строка.
_expire_get_client() {
  local name="$1"
  python3 - "$SERVER_CONF" "$name" << 'PYEOF' 2>/dev/null
import sys, re, pathlib
conf, target = sys.argv[1], sys.argv[2]
try:
    text = pathlib.Path(conf).read_text()
except Exception:
    sys.exit(0)
for block in re.split(r'(?=\[Peer\])', text)[1:]:
    nm = re.search(r'^#\s+(\S+)\s*$', block, re.M)
    if not nm or nm.group(1) != target: continue
    exp = re.search(r'^#\s*expires=(\d+)\s*$', block, re.M)
    orig = re.search(r'^#\s*orig_ips=(.+?)\s*$', block, re.M)
    print(f"{exp.group(1) if exp else ''}|{orig.group(1).strip() if orig else ''}")
    break
PYEOF
}

# Установить срок действия клиенту: вписать # expires=<ts> в peer-блок.
# Если строка уже есть — заменить. Если нет — вставить после "# <name>".
# Аргументы: client_name expire_ts
_expire_set_client() {
  local name="$1" ts="$2"
  python3 - "$SERVER_CONF" "$name" "$ts" << 'PYEOF'
import sys, re, os, pathlib, tempfile
conf, target, ts = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = pathlib.Path(conf).read_text()
except Exception as e:
    print(f"read failed: {e}", file=sys.stderr); sys.exit(1)

parts  = re.split(r'(?=\[Peer\])', text)
header, peers = parts[0], parts[1:]

found = False
out_peers = []
for block in peers:
    nm = re.search(r'^#\s+(\S+)\s*$', block, re.M)
    if nm and nm.group(1) == target:
        found = True
        if re.search(r'^#\s*expires=\d+\s*$', block, re.M):
            block = re.sub(r'^#\s*expires=\d+\s*$', f'# expires={ts}', block, count=1, flags=re.M)
        else:
            # Вставляем после "# <name>"
            block = re.sub(
                r'(^#\s+' + re.escape(target) + r'\s*$)',
                lambda m: m.group(1) + f'\n# expires={ts}',
                block, count=1, flags=re.M
            )
    out_peers.append(block)

if not found:
    print("client not found", file=sys.stderr); sys.exit(2)

new_text = header + ''.join(out_peers)
d  = os.path.dirname(conf)
fd, tmp = tempfile.mkstemp(dir=d, prefix='.awg0.', suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f: f.write(new_text)
    os.chmod(tmp, 0o600)
    os.rename(tmp, conf)
except Exception as e:
    try: os.unlink(tmp)
    except: pass
    print(f"write failed: {e}", file=sys.stderr); sys.exit(3)
PYEOF
}

# Снять срок действия (удалить # expires= и # orig_ips=).
# Если клиент был suspended — также вернуть оригинальный IP.
_expire_clear_client() {
  local name="$1"
  python3 - "$SERVER_CONF" "$name" "$EXPIRE_SUSPEND_IP" << 'PYEOF'
import sys, re, os, pathlib, tempfile
conf, target, suspend = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = pathlib.Path(conf).read_text()
except Exception as e:
    print(f"read failed: {e}", file=sys.stderr); sys.exit(1)

parts  = re.split(r'(?=\[Peer\])', text)
header, peers = parts[0], parts[1:]

found = False
out_peers = []
for block in peers:
    nm = re.search(r'^#\s+(\S+)\s*$', block, re.M)
    if nm and nm.group(1) == target:
        found = True
        # Восстановить IP, если был suspended
        orig_m = re.search(r'^#\s*orig_ips=(.+?)\s*$', block, re.M)
        aip_m  = re.search(r'^AllowedIPs\s*=\s*(.+?)\s*$', block, re.M)
        if orig_m and aip_m and aip_m.group(1).strip() == suspend:
            block = re.sub(
                r'^(AllowedIPs\s*=\s*).+$',
                r'\g<1>' + orig_m.group(1).strip(),
                block, count=1, flags=re.M
            )
        # Удалить служебные комментарии
        block = re.sub(r'^#\s*expires=\d+\s*\n', '', block, flags=re.M)
        block = re.sub(r'^#\s*orig_ips=.+?\s*\n', '', block, flags=re.M)
    out_peers.append(block)

if not found:
    print("client not found", file=sys.stderr); sys.exit(2)

new_text = header + ''.join(out_peers)
d = os.path.dirname(conf)
fd, tmp = tempfile.mkstemp(dir=d, prefix='.awg0.', suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f: f.write(new_text)
    os.chmod(tmp, 0o600)
    os.rename(tmp, conf)
except Exception as e:
    try: os.unlink(tmp)
    except: pass
    print(f"write failed: {e}", file=sys.stderr); sys.exit(3)
PYEOF
}

# Применить изменения серверного конфига через syncconf (без рестарта awg0)
_expire_apply() {
  local strip_out
  strip_out=$(awg-quick strip awg0 2>/dev/null) || return 1
  echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null
}

# Форматирование unix-ts в человеческий вид (TZ сервера) + сколько осталось
_expire_fmt() {
  local ts="$1" now diff abs_diff sign
  now=$(date +%s)
  diff=$((ts - now))
  if (( diff >= 0 )); then
    sign="через"; abs_diff=$diff
  else
    sign="истёк"; abs_diff=$(( -diff ))
  fi
  local d=$(( abs_diff / 86400 ))
  local h=$(( (abs_diff % 86400) / 3600 ))
  local m=$(( (abs_diff % 3600) / 60 ))
  local human=""
  (( d > 0 )) && human="${d}д "
  (( h > 0 )) && human="${human}${h}ч "
  (( m > 0 || (d == 0 && h == 0) )) && human="${human}${m}м"
  human="${human% }"
  local when
  when=$(date -d "@$ts" '+%d.%m.%Y %H:%M %Z' 2>/dev/null || echo "ts=$ts")
  if [[ "$sign" == "истёк" ]]; then
    echo "$when (истёк ${human} назад)"
  else
    echo "$when (через ${human})"
  fi
}

# Меню срока действия клиента (п.7 в do_manage_clients)
do_expire_menu() {
  [[ ! -f "$SERVER_CONF" ]] && { warn "Конфиг сервера не найден"; return 0; }

  # Гарантируем что инфраструктура установлена
  _expire_install

  while true; do
    echo ""
    hdr "⏰  Срок действия клиента"
    echo -e "  ${G}1)${N} Поставить срок клиенту"
    echo -e "  ${G}2)${N} Снять срок (сделать бессрочным)"
    echo -e "  ${C}3)${N} Разблокировать просроченного (вернуть IP)"
    echo -e "  ${C}4)${N} Показать всех со сроками"
    echo -e "  ${R}5)${N} Удалить всех просроченных навсегда"
    echo -e "  ${W}0)${N} Назад"
    echo ""
    local EXP_CHOICE
    read_choice EXP_CHOICE "$(echo -e "${C}  Выбор [0-5]: ${N}")" 0 5 "0"
    case "${EXP_CHOICE:-}" in
      1) _expire_action_set || true ;;
      2) _expire_action_clear || true ;;
      3) _expire_action_unban || true ;;
      4) _expire_action_list || true ;;
      5) _expire_action_purge || true ;;
      0) return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" _ || return 0
  done
}

# Выбор клиента из списка → echo в stdout. Возвращает 1 если отменено.
_expire_pick_client() {
  local names=()
  mapfile -t names < <(
    grep -E '^#\s+\S+\s*$' "$SERVER_CONF" 2>/dev/null | \
      awk '{print $2}' | awk 'NF' | sort -u
  )
  if [[ ${#names[@]} -eq 0 ]]; then
    warn "Клиентов не найдено" >&2
    return 1
  fi
  echo "" >&2
  echo -e "${W}  Клиенты:${N}" >&2
  local i=0
  for n in "${names[@]}"; do
    i=$((i+1))
    # Статус: бессрочный / с дедлайном / заблокирован
    local info_line
    info_line=$(_expire_get_client "$n")
    if [[ -z "$info_line" ]]; then
      echo -e "  ${C}$i)${N} $n  ${D}(бессрочный)${N}" >&2
    else
      local exp_ts="${info_line%%|*}"
      local orig_ip="${info_line#*|}"
      if [[ -n "$exp_ts" ]]; then
        if [[ -n "$orig_ip" ]]; then
          echo -e "  ${C}$i)${N} $n  ${R}🚫 заблокирован${N} ${D}($(_expire_fmt "$exp_ts"))${N}" >&2
        else
          echo -e "  ${C}$i)${N} $n  ${Y}⏰${N} ${D}$(_expire_fmt "$exp_ts")${N}" >&2
        fi
      else
        echo -e "  ${C}$i)${N} $n  ${D}(бессрочный)${N}" >&2
      fi
    fi
  done
  echo "" >&2
  local SEL
  read_choice SEL "$(echo -e "${C}  Номер клиента [1-$i] (0 = отмена): ${N}")" 0 "$i" "0" >&2
  [[ "$SEL" == "0" ]] && return 1
  echo "${names[$((SEL-1))]}"
  return 0
}

_expire_action_set() {
  local client
  client=$(_expire_pick_client) || return 0

  echo ""
  echo -e "  ${W}На сколько поставить срок?${N}"
  echo -e "  ${C}1)${N} 1 час"
  echo -e "  ${C}2)${N} 6 часов"
  echo -e "  ${C}3)${N} 1 день"
  echo -e "  ${C}4)${N} 3 дня"
  echo -e "  ${C}5)${N} 7 дней"
  echo -e "  ${C}6)${N} 30 дней"
  echo -e "  ${C}7)${N} Своя дата (YYYY-MM-DD HH:MM)"
  echo ""
  local PRESET
  read_choice PRESET "$(echo -e "${C}  Выбор [1-7] (0 = отмена): ${N}")" 0 7 "0"

  local ts=""
  case "${PRESET:-}" in
    0) info "Отменено"; return 0 ;;
    1) ts=$(_expire_parse_duration "1h") ;;
    2) ts=$(_expire_parse_duration "6h") ;;
    3) ts=$(_expire_parse_duration "1d") ;;
    4) ts=$(_expire_parse_duration "3d") ;;
    5) ts=$(_expire_parse_duration "7d") ;;
    6) ts=$(_expire_parse_duration "30d") ;;
    7)
       local CUSTOM
       safe_read CUSTOM "$(echo -e "${C}  Дата (например: 2025-12-31 23:59): ${N}")"
       ts=$(date -d "$CUSTOM" +%s 2>/dev/null || true)
       ;;
    *) warn "Неверный выбор"; return 0 ;;
  esac

  if [[ -z "$ts" ]]; then
    warn "Не удалось определить дату — отмена"
    return 0
  fi

  local now_ts; now_ts=$(date +%s)
  if (( ts <= now_ts + 3540 )); then
    warn "Минимум 1 час от текущего времени"
    return 0
  fi

  if _expire_set_client "$client" "$ts"; then
    ok "Срок установлен: $client → $(_expire_fmt "$ts")"
    _expire_apply >/dev/null 2>&1 || warn "syncconf не удался — нужен restart awg0"
    # Сбрасываем флаг "уже предупредили за 1ч" если был
    local safe_pk
    safe_pk=$(grep -A2 "^#\s\+$client\s*$" "$SERVER_CONF" 2>/dev/null | \
              grep "^PublicKey" | head -1 | awk -F= '{print $2}' | tr -d ' ' | tr -c 'A-Za-z0-9' '_' || true)
    [[ -n "$safe_pk" ]] && rm -f "${EXPIRE_STATE_DIR}/warn1h_${safe_pk}" 2>/dev/null || true
  else
    err "Не удалось установить срок"
  fi
}

_expire_action_clear() {
  local client
  client=$(_expire_pick_client) || return 0

  if _expire_clear_client "$client"; then
    ok "Срок снят: $client теперь бессрочный"
    _expire_apply >/dev/null 2>&1 || warn "syncconf не удался — нужен restart awg0"
  else
    err "Не удалось снять срок"
  fi
}

_expire_action_unban() {
  local client info_line exp_ts orig_ip
  client=$(_expire_pick_client) || return 0
  info_line=$(_expire_get_client "$client")
  exp_ts="${info_line%%|*}"
  orig_ip="${info_line#*|}"

  if [[ -z "$exp_ts" || -z "$orig_ip" ]]; then
    warn "$client не заблокирован сроком (нет orig_ips)"
    return 0
  fi

  # Разблокировка = просто снять срок (вернёт оригинальный IP)
  if _expire_clear_client "$client"; then
    ok "Разблокирован: $client (IP восстановлен: $orig_ip)"
    _expire_apply >/dev/null 2>&1 || warn "syncconf не удался — нужен restart awg0"
  else
    err "Не удалось разблокировать"
  fi
}

_expire_action_list() {
  echo ""
  echo -e "${W}  Клиенты со сроком действия:${N}"
  echo ""
  local names=() found=0
  mapfile -t names < <(
    grep -E '^#\s+\S+\s*$' "$SERVER_CONF" 2>/dev/null | \
      awk '{print $2}' | awk 'NF' | sort -u
  )
  printf "  %-20s  %-10s  %s\n" "ИМЯ" "СТАТУС" "ДЕДЛАЙН"
  printf "  %-20s  %-10s  %s\n" "────────────────────" "──────────" "──────────────────────────────"
  for n in "${names[@]}"; do
    local info_line exp_ts orig_ip status
    info_line=$(_expire_get_client "$n")
    [[ -z "$info_line" ]] && continue
    exp_ts="${info_line%%|*}"
    orig_ip="${info_line#*|}"
    [[ -z "$exp_ts" ]] && continue
    found=$((found+1))
    if [[ -n "$orig_ip" ]]; then
      status="🚫 blocked"
    else
      status="⏰ active"
    fi
    printf "  %-20s  %-10s  %s\n" "$n" "$status" "$(_expire_fmt "$exp_ts")"
  done
  echo ""
  if [[ $found -eq 0 ]]; then
    info "Нет клиентов со сроком действия — все бессрочные"
  else
    info "Всего со сроком: $found"
  fi
}

_expire_action_purge() {
  local names=() to_remove=()
  mapfile -t names < <(
    grep -E '^#\s+\S+\s*$' "$SERVER_CONF" 2>/dev/null | \
      awk '{print $2}' | awk 'NF' | sort -u
  )
  local now_ts; now_ts=$(date +%s)
  for n in "${names[@]}"; do
    local info_line exp_ts orig_ip
    info_line=$(_expire_get_client "$n")
    [[ -z "$info_line" ]] && continue
    exp_ts="${info_line%%|*}"
    orig_ip="${info_line#*|}"
    [[ -z "$exp_ts" ]] && continue
    if (( exp_ts <= now_ts )) && [[ -n "$orig_ip" ]]; then
      to_remove+=("$n")
    fi
  done

  if [[ ${#to_remove[@]} -eq 0 ]]; then
    info "Нет просроченных клиентов для удаления"
    return 0
  fi

  echo ""
  warn "Будут удалены НАВСЕГДА:"
  for n in "${to_remove[@]}"; do
    echo -e "  ${R}—${N} $n"
  done
  echo ""
  local CONFIRM
  read_yesno CONFIRM "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")" "n"
  [[ "$CONFIRM" != "y" ]] && { warn "Отменено"; return 0; }

  # Используем существующую do_delete_client логику если возможно,
  # но проще удалить напрямую через python (peer-блок + клиентский файл)
  for n in "${to_remove[@]}"; do
    python3 - "$SERVER_CONF" "$n" << 'PYEOF'
import sys, re, os, pathlib, tempfile
conf, target = sys.argv[1], sys.argv[2]
try:
    text = pathlib.Path(conf).read_text()
except Exception:
    sys.exit(1)
parts  = re.split(r'(?=\[Peer\])', text)
header, peers = parts[0], parts[1:]
new_peers = []
removed_pubkey = None
for block in peers:
    nm = re.search(r'^#\s+(\S+)\s*$', block, re.M)
    if nm and nm.group(1) == target:
        pk = re.search(r'^PublicKey\s*=\s*(\S+)', block, re.M)
        if pk: removed_pubkey = pk.group(1)
        continue
    new_peers.append(block)
new_text = header + ''.join(new_peers)
d = os.path.dirname(conf)
fd, tmp = tempfile.mkstemp(dir=d, prefix='.awg0.', suffix='.tmp')
with os.fdopen(fd, 'w') as f: f.write(new_text)
os.chmod(tmp, 0o600)
os.rename(tmp, conf)
if removed_pubkey:
    print(removed_pubkey)
PYEOF
    local cli_file="/root/${n}_awg2.conf"
    [[ -f "$cli_file" ]] && rm -f "$cli_file"
    ok "Удалён: $n"
  done

  _expire_apply >/dev/null 2>&1 || warn "syncconf не удался — нужен restart awg0"
  ok "Удалено: ${#to_remove[@]}"
}

# Спросить срок при создании клиента (вызывается из do_add_client/do_bulk_add_clients)
# Stdout: unix-ts (или пусто = бессрочный)
_expire_ask_at_creation() {
  echo "" >&2
  echo -e "${W}  Срок действия клиента:${N}" >&2
  echo -e "  ${C}1)${N} Бессрочно (по умолчанию)" >&2
  echo -e "  ${C}2)${N} 1 час" >&2
  echo -e "  ${C}3)${N} 1 день" >&2
  echo -e "  ${C}4)${N} 7 дней" >&2
  echo -e "  ${C}5)${N} 30 дней" >&2
  echo -e "  ${C}6)${N} Своя дата (YYYY-MM-DD HH:MM)" >&2
  echo "" >&2
  local CH
  read_choice CH "$(echo -e "${C}  Выбор [1-6] (Enter = 1): ${N}")" 1 6 "1" >&2
  local ts=""
  case "$CH" in
    1) echo ""; return 0 ;;
    2) ts=$(_expire_parse_duration "1h") ;;
    3) ts=$(_expire_parse_duration "1d") ;;
    4) ts=$(_expire_parse_duration "7d") ;;
    5) ts=$(_expire_parse_duration "30d") ;;
    6)
       local CUSTOM
       safe_read CUSTOM "$(echo -e "${C}  Дата (YYYY-MM-DD HH:MM): ${N}")" >&2
       ts=$(date -d "$CUSTOM" +%s 2>/dev/null || true)
       ;;
    *) echo ""; return 0 ;;
  esac
  [[ -z "$ts" ]] && { warn "Не удалось распознать дату — клиент будет бессрочный" >&2; echo ""; return 0; }
  echo "$ts"
}




_global_cleanup() {
  rm -rf /tmp/awg_tmp_* /tmp/awg_ping_* 2>/dev/null || true
  # Кэш доменов оставляем (используется повторно в do_check_domains),
  # удаляем только если он битый (нулевого размера)
  [[ -f /tmp/awg_domain_cache.txt && ! -s /tmp/awg_domain_cache.txt ]] && \
    rm -f /tmp/awg_domain_cache.txt 2>/dev/null || true
}
trap '_global_cleanup' EXIT
trap '_global_cleanup; echo ""; warn "Прервано пользователем"; exit 130' INT TERM

# --post-update <прежняя версия> — скрипт сам себя перезапустил после
# обновления. Показываем это один раз: обновление занимает секунду, и без
# явного сообщения непонятно, произошло ли оно.
POST_UPDATE_FROM=""
case "${1:-}" in
  --post-update) POST_UPDATE_FROM="${2:-}" ;;
esac

# Фоновая проверка новой версии — один раз за запуск, результат в кэш.
# Шапка читает кэш и в сеть не ходит, поэтому меню не ждёт ничего.
update_check_async || true

while true; do
  check_deps
  show_header

  if [[ -n "$POST_UPDATE_FROM" ]]; then
    echo ""
    if [[ "$POST_UPDATE_FROM" == "$VERSION" ]]; then
      success_box "✓ Скрипт обновлён и перезапущен ($VERSION)"
    else
      success_box "✓ Обновление установлено: $POST_UPDATE_FROM → $VERSION"
    fi
    POST_UPDATE_FROM=""
  fi

  show_menu
  # show_menu читает CHOICE через read_choice — валидация внутри

  case "${CHOICE:-}" in
    1) show_submenu_1 ;;
    2) do_manage_clients || true ;;
    3) show_submenu_3 ;;
    4) show_submenu_4 ;;
    5) show_submenu_5 ;;
    6) show_submenu_6 ;;
    7) show_submenu_7 ;;
    8) show_submenu_8 ;;
    0)
      log_info "Выход"
      echo -e "\n${G}  В путь! ${N}"
      echo -e "<< Подпишись на ТГ :) >>"
      echo -e "<< https://t.me/awgToolza >>\n"
      exit 0 ;;
    # read_choice наружу ничего кроме 0-8 не выпускает: пустой Enter и мусор
    # переспрашиваются внутри него, Ctrl+D отдаёт 0. Ветка оставлена как
    # страховка на случай правок валидатора.
    *) warn "Неверный выбор" ;;
  esac

  # Сбрасываем CHOICE — защита от повторного срабатывания
  CHOICE=""
done
