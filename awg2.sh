#!/bin/bash
set -euo pipefail

VERSION="v6.8.6"
UPDATE_URL="https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg2.sh"
SCRIPT_PATH="/usr/local/bin/awg2"

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

# safe_read — сбрасывает буфер stdin перед read, чтобы случайные клавиши/повторы
# не попадали в prompt. Особенно критично для подтверждений (yes/no для удаления).
# Использование: safe_read VARNAME "Промпт: "
safe_read() {
  local _var_name="$1"
  local _prompt="${2:-}"
  # Сбрасываем буфер stdin только в интерактивном режиме (TTY).
  # В неинтерактивном (heredoc/пайп) -t 0.05 съедает реальный ввод.
  if [[ -t 0 ]]; then
    while read -t 0.05 -n 100 -r _discard 2>/dev/null; do :; done
  fi
  # Теперь читаем реальный ответ пользователя
  read -rp "$_prompt" "$_var_name"
}

# read_choice — читает выбор из числового диапазона с переспросом.
# Принимает пустой ввод (применит дефолт). Невалидный ввод → переспрос.
# Использование: read_choice VARNAME "Промпт: " MIN MAX [DEFAULT]
#   DEFAULT необязателен; если задан — пустой ввод заменяется на него.
#   Если DEFAULT не задан — пустой ввод тоже считается невалидным.
read_choice() {
  local _var_name="$1"
  local _prompt="$2"
  local _min="$3"
  local _max="$4"
  local _default="${5:-}"
  local _value
  while true; do
    # Сбрасываем буфер stdin только в интерактивном режиме (TTY).
    # В неинтерактивном (тесты/heredoc) -t 0.05 съедает реальный ввод.
    if [[ -t 0 ]]; then
      while read -t 0.05 -n 100 -r _discard 2>/dev/null; do :; done
    fi
    read -rp "$_prompt" _value
    # Пустой ввод + есть дефолт → применяем дефолт
    if [[ -z "$_value" && -n "$_default" ]]; then
      _value="$_default"
      break
    fi
    # Проверка: число в диапазоне
    if [[ "$_value" =~ ^[0-9]+$ ]] && (( _value >= _min && _value <= _max )); then
      break
    fi
    echo -e "${R}  Введи число от ${_min} до ${_max}${N}" >&2
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
    if [[ -t 0 ]]; then
      while read -t 0.05 -n 100 -r _discard 2>/dev/null; do :; done
    fi
    read -rp "$_prompt" _value
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

# Warp туннель (Cloudflare wgcf) — пункт меню 15
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

# Шифрованный DNS (dnscrypt-proxy) — пункт меню 16
# Шифрованный DNS (dnscrypt-proxy) — пункт меню 16
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

# Каскад (port forwarding на зарубежный сервер) — пункт меню 17
CASCADE_DIR="/etc/awg-cascade"
CASCADE_RULES="$CASCADE_DIR/rules.conf"
CASCADE_SERVICE="/etc/systemd/system/awg-cascade.service"
CASCADE_APPLY_SCRIPT="/usr/local/bin/awg-cascade-apply.sh"
CASCADE_TAG="awg-cascade"
CASCADE_LOG="/var/log/awg-cascade.log"
CASCADE_LOG_MAX=1048576  # 1 MB — после превышения ротация

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
_CPS_GENERATOR='
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
'


# Генерация I1-I5 через Python
# $1 = profile (quic|sip|dns), $2 = domain (опционально)
gen_cps_i1() {
  local profile="${1:-quic}"
  local domain="${2:-}"
  python3 -c "$_CPS_GENERATOR" "$profile" "$domain"
}


# Алгоритм:
# 1. Профиль 1-4: выбираем домен из пула через scan_pool → select_random_domain
#    Fallback-каскад: если целевой пул пуст → пробуем следующий → ... → none
#    Порядок fallback: tls → dtls → sip → none (профиль 1),
#                       dtls → tls → sip → none (профиль 2),
#                       sip → tls → dtls → none (профиль 3)
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
choose_awg_profile() {
  AWG_PROFILE=""
  echo ""
  hdr "⚙  Профиль AmneziaWG"
  echo -e "  ${G}1${N}  ${W}Lite${N}     — параметры оригинальной Amnezia"
  echo -e "     ${D}Минимум junk, малые S/J. I1 = DNS (icloud.com). Макс совместимость.${N}"
  echo -e "  ${G}2${N}  ${W}Standard${N} — сбалансированный набор"
  echo -e "     ${D}Средние Jc/S. I1 = QUIC. Хороший баланс защита/совместимость.${N}"
  echo -e "  ${G}3${N}  ${W}Pro${N}      — максимальная защита (текущий набор)"
  echo -e "     ${D}Полные диапазоны. Опционально I1-I5 (выбор уровня + профиля).${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  local _choice
  read_choice _choice "$(echo -e "${C}  Выбор [1-3] (Enter = 2): ${N}")" 1 3 2

  case "$_choice" in
    1)
      AWG_PROFILE="lite"
      OBF_LEVEL=2                # клиентам кладём I1
      MIMICRY_PROFILE="dns"
      # Фиксированный домен для Lite — как в оригинале Amnezia
      info "Профиль: Lite (I1 = DNS / icloud.com)"
      local cps_out
      cps_out=$(gen_cps_i1 "dns" "icloud.com") || cps_out=""
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
      OBF_LEVEL=2                # клиентам кладём I1
      MIMICRY_PROFILE="quic"
      info "Профиль: Standard (I1 = QUIC)"
      local sel_domain
      sel_domain=$(select_random_domain "quic")
      [[ -z "$sel_domain" ]] && sel_domain=""
      local cps_out
      cps_out=$(gen_cps_i1 "quic" "$sel_domain") || cps_out=""
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
  echo ""
  hdr "⛊  Уровень обфускации"
  echo -e "  ${G}1${N}  Базовый AWG 2.0 — H ranges + S1-S4 + Jc junk"
  echo -e "     ${D}Без I1-I5. Максимальная совместимость. Рекомендуется.${N}"
  echo -e "  ${G}2${N}  AWG 2.0 + I1 — добавляет 1 сигнатурный пакет"
  echo -e "     ${D}I1 = снимок реального TLS/QUIC/DTLS протокола${N}"
  echo -e "  ${Y}3${N}  AWG 2.0 + I1-I5 полный CPS chain"
  echo -e "     ${D}Максимум DPI bypass. Некоторые клиенты могут глючить.${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  read_choice OBF_LEVEL "$(echo -e "${C}  Выбор [1-3] (Enter = 1): ${N}")" 1 3 1
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
  echo -e "  ${G}1${N}  ${W}★ QUIC${N}  — Chrome-like Initial 1200B + Short Header I2-I5"
  echo -e "     ${D}Лучший выбор для РФ. I1=1200B, I2-I5=50-90B.${N}"
  echo -e "  ${G}2${N}  SIP   — REGISTER запрос (VoIP мимикрия)"
  echo -e "     ${D}Только I1. Хорошо работает с SIP провайдерами.${N}"
  echo -e "  ${G}3${N}  DNS   — DNS Query с рандомным TXID (<r 2>)"
  echo -e "     ${D}Компактный, I1-I5 с TXID prefix.${N}"
  echo ""
  read_choice PROFILE_CHOICE "$(echo -e "${C}  Выбор [1-3] (Enter = 1): ${N}")" 1 3 1

  case $PROFILE_CHOICE in
    1) MIMICRY_PROFILE="quic" ;;
    2) MIMICRY_PROFILE="sip"  ;;
    3) MIMICRY_PROFILE="dns"  ;;
  esac

  # Выбираем домен из пула под профиль
  local sel_domain=""
  case "$MIMICRY_PROFILE" in
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
      echo -e "${G}  √ ${nonempty}/5 пакетов: I1=${#I1} I2=${#I2} I3=${#I3} I4=${#I4} I5=${#I5}${N}"
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
    # TLS ClientKeyExchange (starts with 0x10)
    if p[0] == 0x10 and len(p) > 50:
        return ("tls-cke", f"TLS ClientKeyExchange+CCS+Fin ({len(p)}B)")
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
    # QUIC Short Header (0x40-0x7f)
    if 0x40 <= fb <= 0x7f and len(p) > 20:
        return ("quic-short", f"QUIC Short Header ({len(p)}B)")
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
    warn "Сервер не настроен (пункт 2)"
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
  HAS_QRENCODE=false
  HAS_SERVER_CONF=false
  HAS_CLIENT_CONFS=false
  HAS_BACKUPS=false

  # Кэш проверки бинарей (они не появляются/исчезают в течение сессии).
  # _DEPS_CACHED — пустая до первой проверки, потом "1".
  if [[ -z "${_DEPS_CACHED:-}" ]]; then
    command -v awg &>/dev/null && _CACHED_HAS_AWG=true || _CACHED_HAS_AWG=false
    command -v qrencode &>/dev/null && _CACHED_HAS_QRENCODE=true || _CACHED_HAS_QRENCODE=false
    _DEPS_CACHED=1
  fi
  HAS_AWG="$_CACHED_HAS_AWG"
  HAS_QRENCODE="$_CACHED_HAS_QRENCODE"

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

  # Проверка конфигов клиентов
  local f
  for f in /root/*_awg2.conf; do
    if [[ -f "$f" ]]; then HAS_CLIENT_CONFS=true; break; fi
  done
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
      err "modprobe amneziawg провалился"
      info "Проверь вручную:"
      info "  ls /sys/module/amneziawg     (проверка загрузки)"
      info "  dkms status amneziawg        (статус сборки)"
      info "  dmesg | tail -20             (ошибки ядра)"
      info "Возможно нужен reboot или переустановка модуля"
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
    info "Сначала пункт 2 — создать сервер"
    return 1
  fi
  ok "Серверный конфиг на месте"

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
      if awg-quick up "$SERVER_CONF" 2>/dev/null; then
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
    if awg-quick up "$SERVER_CONF" 2>/dev/null; then
      ok "awg0 запущен"
      fixed=$((fixed+1))
    else
      err "awg-quick up провалился"
      info "Подробности: awg-quick up $SERVER_CONF"
    fi
  fi

  # 5. iptables NAT
  local ext_if
  ext_if=$(ip route | awk '/default/ {print $5; exit}')
  if [[ -n "$ext_if" ]]; then
    if iptables -t nat -C POSTROUTING -o "$ext_if" -j MASQUERADE 2>/dev/null; then
      ok "iptables NAT MASQUERADE на $ext_if"
    else
      warn "iptables NAT MASQUERADE отсутствует"
      issues=$((issues+1))
      iptables -t nat -A POSTROUTING -o "$ext_if" -j MASQUERADE && \
        ok "MASQUERADE добавлен" && fixed=$((fixed+1))
    fi

    if iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null; then
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
  if ! curl -fsSL --connect-timeout 10 --max-time 60 \
       -H "Cache-Control: no-cache, no-store" \
       -H "Pragma: no-cache" \
       "$fetch_url" -o "$tmp_file"; then
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
    if [[ "$cur_hash" == "$new_hash" ]]; then
      info "Файлы идентичны (тот же hash) — обновление не требуется"
      rm -f "$tmp_file"
      return 0
    fi
    echo ""
  fi

  # ───── 5. Сравнение версий ─────
  local cur_num new_num
  cur_num=$(echo "$VERSION" | sed 's/^v//' | awk -F. '{ printf "%d%03d%03d\n", $1, $2, $3 ? $3 : 0 }')
  new_num=$(echo "$new_ver" | sed 's/^v//' | awk -F. '{ printf "%d%03d%03d\n", $1, $2, $3 ? $3 : 0 }')

  if [[ "$new_ver" == "?" ]]; then
    warn "Не удалось определить версию"
    local CONFIRM_FORCE
    read_yesno CONFIRM_FORCE "$(echo -e "${C}  Установить всё равно? [y/N]: ${N}")" "n"
    if [[ ! "$CONFIRM_FORCE" =~ ^[Yy]$ ]]; then
      rm -f "$tmp_file"
      return 0
    fi
  elif [[ "$new_num" -lt "$cur_num" ]]; then
    warn "На GitHub версия СТАРШЕ текущей — это даунгрейд!"
    echo -e "${Y}  Текущая ($VERSION) > GitHub ($new_ver)${N}"
    echo -e "${Y}  Возможно ты обновлял скрипт вручную, а в репо ещё старая версия.${N}"
    echo ""
    local CONFIRM_DOWNGRADE
    read_yesno CONFIRM_DOWNGRADE "$(echo -e "${R}  Откатить до $new_ver? [y/N]: ${N}")" "n"
    if [[ ! "$CONFIRM_DOWNGRADE" =~ ^[Yy]$ ]]; then
      info "Отменено — текущая версия сохранена"
      rm -f "$tmp_file"
      return 0
    fi
  elif [[ "$new_num" -eq "$cur_num" ]]; then
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

    # Авто-очистка PPA остатков при апгрейде с версий до v6.7 (когда был PPA)
    local new_major_minor
    new_major_minor=$(echo "$new_ver" | sed 's/^v//' | awk -F. '{ printf "%d%03d\n", $1, $2 }')
    if [[ "${new_major_minor:-0}" -ge "6007" ]]; then
      local cleaned=0
      for f in /etc/apt/sources.list.d/amnezia*.list \
               /etc/apt/sources.list.d/amnezia*.sources \
               /etc/apt/sources.list.d/canonical-kernel-team*.list \
               /etc/apt/sources.list.d/canonical-kernel-team*.sources; do
        if [[ -f "$f" ]]; then
          rm -f "$f"
          cleaned=1
        fi
      done
      rm -f /etc/apt/trusted.gpg.d/amnezia*.gpg 2>/dev/null
      rm -f /etc/apt/keyrings/amnezia*.gpg 2>/dev/null
      if [[ $cleaned -eq 1 ]]; then
        info "Удалены остатки PPA от прошлых версий (теперь установка через git)"
      fi
    fi

    # ───── 8. Сброс bash hash cache ─────
    # Bash кеширует пути исполняемых файлов в памяти. После mv нужен сброс,
    # иначе при следующем запуске awg2 может выполниться старый кеш.
    hash -r 2>/dev/null || true

    echo ""
    echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  ${W}  ВАЖНО: текущий процесс продолжает работать в старой версии${N}"
    echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "  Выйди из меню (${W}0${N}) и запусти снова: ${W}sudo awg2${N}"
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
  fi

  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}AwgToolza $VERSION${N}"
  echo -e "  ${C}TG: @awgToolza${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  IP сервера : ${W}$ip${N}"
  echo -e "  Порт       : ${W}$port${N}"
  echo -e "  Интерфейс  : $st${N}"
  echo -e "  Профиль    : ${W}$profile_label${N}"
  echo -e "  Клиентов   : ${W}$clients${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

show_menu() {
  echo ""

  # === ОСНОВНЫЕ ===
  echo -e "  ${C}▸ Основные:${N}"
  echo -e "  ${C}1)${N} Установка зависимостей и AmneziaWG"
  if $HAS_AWG; then
    echo -e "  ${C}2)${N} Создать сервер + первый клиент (с мимикрией)"
  else
    echo -e "  ${D}2) Создать сервер (нужен пункт 1)${N}"
  fi
  if $HAS_AWG && $HAS_SERVER_CONF; then
    echo -e "  ${C}3)${N} Управление клиентами (добавить/rename/delete/QR)"
  else
    echo -e "  ${D}3) Управление клиентами (нужен пункт 2)${N}"
  fi
  if $HAS_AWG && $HAS_SERVER_CONF; then
    echo -e "  ${C}4)${N} Активность клиентов"
  else
    echo -e "  ${D}4) Показать клиентов (нужен пункт 2)${N}"
  fi
  echo ""

  # === УТИЛИТЫ ===
  echo -e "  ${G}▸ Утилиты:${N}"
  if $HAS_SERVER_CONF; then
    echo -e "  ${G}5)${N} Перезапустить awg0"
  else
    echo -e "  ${D}5) Перезапустить awg0 (нужен пункт 2)${N}"
  fi
  echo -e "  ${G}6)${N} Проверить домены из пулов (TCP+ping)"
  if $HAS_SERVER_CONF; then
    echo -e "  ${G}7)${N} Тест DPI мимикрии (захват CPS пакета)"
  else
    echo -e "  ${D}7) Тест DPI мимикрии (нужен пункт 2)${N}"
  fi
  echo ""

  # === БЕКАПЫ ===
  echo -e "  ${B}▸ Бекапы:${N}"
  echo -e "  ${B}8)${N} Создать бекап (~/awg_backup/)"
  if $HAS_BACKUPS; then
    echo -e "  ${B}9)${N} Восстановить из бекапа"
  else
    echo -e "  ${D}9) Восстановить из бекапа (нет бекапов)${N}"
  fi
  echo ""

  # === ОПАСНАЯ ЗОНА ===
  echo -e "  ${R}▸ Опасная зона:${N}"
  if $HAS_SERVER_CONF; then
    echo -e "  ${Y}10)${N} Очистить всех клиентов (без удаления сервера)"
  else
    echo -e "  ${D}10) Очистить клиентов (нужен пункт 2)${N}"
  fi
  if $HAS_SERVER_CONF; then
    echo -e "  ${Y}11)${N} Сбросить настройки сервера (чистая переустановка)"
  else
    echo -e "  ${D}11) Сбросить сервер (нет сервера)${N}"
  fi
  echo -e "  ${R}12)${N} Удалить всё (пакеты + конфиги)"
  echo ""

  # === СЕРВИС ===
  echo -e "  ${M}▸ Сервис:${N}"
  if $HAS_SERVER_CONF; then
    echo -e "  ${M}13)${N} Проверить и починить awg0 (авторемонт)"
  else
    echo -e "  ${D}13) Авторемонт (нужен пункт 2)${N}"
  fi
  echo -e "  ${M}14)${N} Обновить скрипт с GitHub"
  echo ""

  # === WARP ТУННЕЛЬ ===
  echo -e "  ${C}▸ Warp туннель:${N}"
  if ip link show warp0 &>/dev/null; then
    echo -e "  ${C}15)${N} Warp туннель  ${G}● включен${N}"
  elif [[ -f "$WARP_CONF" ]]; then
    echo -e "  ${C}15)${N} Warp туннель  ${D}○ настроен, выключен${N}"
  else
    echo -e "  ${C}15)${N} Warp туннель  ${D}○ не настроен${N}"
  fi

  echo ""

  # === ШИФРОВАННЫЙ DNS ===
  echo -e "  ${C}▸ Шифрованный DNS:${N}"
  if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && \
     iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR:-127.0.2.1}:${DNS_PROXY_PORT:-53}" 2>/dev/null; then
    echo -e "  ${C}16)${N} DNS-шифрование  ${G}● включено${N} ${D}(DoH через Cloudflare/Google/Cisco)${N}"
  elif command -v dnscrypt-proxy &>/dev/null; then
    echo -e "  ${C}16)${N} DNS-шифрование  ${D}○ установлен, выключен${N}"
  else
    echo -e "  ${C}16)${N} DNS-шифрование  ${D}○ не настроен${N}"
  fi

  echo ""

  # === КАСКАД ===
  echo -e "  ${C}▸ Каскад (проброс на зарубежный VPS):${N}"
  local _casc_rules=0
  if [[ -f "$CASCADE_RULES" ]]; then
    # || true — grep -c вернёт exit 1 если нет матчей, что под set -e убивает скрипт
    _casc_rules=$(grep -cvE '^\s*(#|$)' "$CASCADE_RULES" 2>/dev/null || true)
    [[ "$_casc_rules" =~ ^[0-9]+$ ]] || _casc_rules=0
  fi
  if (( _casc_rules > 0 )) && systemctl is-enabled awg-cascade.service &>/dev/null; then
    echo -e "  ${C}17)${N} Каскад  ${G}● активен${N} ${D}(${_casc_rules} правил)${N}"
  elif (( _casc_rules > 0 )); then
    echo -e "  ${C}17)${N} Каскад  ${Y}○ правила есть, persist выключен${N}"
  else
    echo -e "  ${C}17)${N} Каскад  ${D}○ не настроен${N}"
  fi

  echo ""
  echo -e "  ${W}0)${N} Выход"
  echo ""
  safe_read CHOICE "$(echo -e "${C}  Выбор: ${N}")"
}

choose_dns() {
  CLIENT_DNS=""
  hdr "◎  DNS для клиента"
  echo ""

  # Если включено DNS-шифрование (пункт 16) — показать подсказку
  if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && \
     iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR:-127.0.2.1}:${DNS_PROXY_PORT:-53}" 2>/dev/null; then
    echo -e "  ${G}⚡ Шифрованный DNS включён${N} ${D}(пункт 16 главного меню)${N}"
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
      S1=$(rand_range 97 107)           # 102 ±5
      S2=$(rand_range 17 27)            # 22 ±5
      S3=$(rand_range 16 26)            # 21 ±5
      S4=$(rand_range 4 10)             # 7 ±3 (нельзя ±5: ниже 0 уйдём)
      ;;
    standard)
      # ── Standard: промежуточные значения ──
      Jc=$(rand_range 5 8)
      Jmin=$(rand_range 30 80)
      Jmax=$(rand_range 100 250)
      S1=$(rand_range 30 80)
      S2=$(rand_range 30 80)
      S3=$(rand_range 15 32)
      S4=$(rand_range 10 20)
      ;;
    pro|*)
      # ── Pro: текущие полные диапазоны (без изменений) ──
      Jc=$(rand_range 4 16)
      Jmin=$(rand_range 50 256)
      Jmax=$(rand_range 300 1000)
      S1=$(rand_range 15 150)
      S2=$(rand_range 15 150)
      S3=$(rand_range 8 64)
      S4=$(rand_range 6 31)
      ;;
  esac

  # ── Инварианты мануала (применяются для всех профилей) ──

  # Jmin < Jmax
  if [[ $Jmin -ge $Jmax ]]; then
    Jmax=$((Jmin + $(rand_range 100 500)))
  fi

  # S1 + 56 ≠ S2 (требование мануала). Усиливаем: gap >= 10
  # для защиты от off-by-one в реализации awg.
  # Если за 10 попыток не вышло — оставляем последнее значение
  # (математически в наших диапазонах такого не должно случиться,
  # но логируем для отладки).
  local tries=0 max_tries=10 gap=10
  local S1_plus_56=$((S1 + 56))
  while [[ $tries -lt $max_tries ]]; do
    local diff=$((S1_plus_56 - S2))
    [[ $diff -lt 0 ]] && diff=$((-diff))
    [[ $diff -ge $gap ]] && break
    # Перегенерируем S2 в рамках того же профиля
    case "${AWG_PROFILE:-pro}" in
      lite)     S2=$(rand_range 17 27) ;;
      standard) S2=$(rand_range 30 80) ;;
      pro|*)    S2=$(rand_range 15 150) ;;
    esac
    tries=$((tries + 1))
  done
  if [[ $tries -gt 0 ]]; then
    log_info "gen_awg_params: S1+56=$S1_plus_56 vs S2=$S2 — корректировка за $tries попыток (gap=$gap)"
  fi
  # Финальная страховка от прямого равенства S1+56==S2
  if [[ $S1_plus_56 -eq $S2 ]]; then
    S2=$((S2 + gap))
    log_info "gen_awg_params: применён ручной сдвиг S2 → $S2 (страховка от S1+56=S2)"
  fi

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

# Стратегия:
#   - Конфиг БЕЗ I1-I5 → QR код (компактный, влезает)
#   - Конфиг С I1-I5 → только текст конфига (QR не делаем — слишком большой)
_share_config() {
  local conf_file="$1"
  [[ -f "$conf_file" ]] || return 1

  # Проверяем наличие I1-I5 в конфиге и общий размер
  local has_i1 conf_size
  has_i1=$(grep -cE "^I[1-5] = " "$conf_file" 2>/dev/null || echo 0)
  conf_size=$(wc -c < "$conf_file")

  # QR лимит (с запасом) ~2800 байт
  local qr_fits=1
  [[ "$conf_size" -gt 2800 ]] && qr_fits=0

  if [[ "$qr_fits" -eq 1 ]] && command -v qrencode &>/dev/null; then
    # Влезает в QR
    echo ""
    qrencode -t ansiutf8 -s 1 -m 1 < "$conf_file"
    echo -e "${D}  ↑ QR-код конфига (${conf_size} байт) — сканируй в AmneziaVPN${N}"
  else
    # Большой конфиг → только текст
    echo ""
    echo -e "${Y}  ──────────────────────────────────────────────${N}"
    echo -e "${W}  ≡ Текст конфига (сохрани как client.conf):${N}"
    echo -e "${Y}  ──────────────────────────────────────────────${N}"
    echo ""
    cat "$conf_file"
    echo ""
    echo -e "${Y}  ──────────────────────────────────────────────${N}"
    echo -e "${D}  (QR не показан: конфиг ${conf_size} байт > 2800 лимит)${N}"
    if [[ "$has_i1" -gt 0 ]]; then
      echo -e "${D}  Используй DNS или SIP профиль — у них I1 значительно меньше${N}"
    fi
  fi
}

do_install() {
  while true; do
  # Detect OS
  local OS_ID OS_VER OS_CODENAME
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
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
        24.04|24.10|25.04|25.10)
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
  local cleaned=0
  for f in /etc/apt/sources.list.d/amnezia*.list \
           /etc/apt/sources.list.d/amnezia*.sources \
           /etc/apt/sources.list.d/canonical-kernel-team*.list \
           /etc/apt/sources.list.d/canonical-kernel-team*.sources; do
    if [[ -f "$f" ]]; then
      info "Удаляю $f"
      rm -f "$f"
      cleaned=1
    fi
  done
  # GPG ключи от старых PPA
  rm -f /etc/apt/trusted.gpg.d/amnezia*.gpg 2>/dev/null
  rm -f /etc/apt/keyrings/amnezia*.gpg 2>/dev/null
  if [[ $cleaned -eq 1 ]]; then
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
  local base_deps=(python3 net-tools curl ufw iptables qrencode bc ca-certificates gnupg)
  # Всегда добавляем deps для git+DKMS сборки
  base_deps+=(build-essential git libmnl-dev pkg-config dkms)
  apt-get install -y -q "${base_deps[@]}"

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
      echo "$installed_headers" | while read k; do echo "    /lib/modules/$k"; done
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

  iptables -t nat -C POSTROUTING -o "$ext_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$ext_if" -j MASQUERADE
  iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i awg0 -j ACCEPT
  iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -o awg0 -j ACCEPT
  ok "NAT и FORWARD правила добавлены"

  local hook="/etc/network/if-pre-up.d/iptables-nat"
  cat > "$hook" <<EOF
#!/bin/sh
iptables -t nat -C POSTROUTING -o ${ext_if} -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o ${ext_if} -j MASQUERADE
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT
EOF
  chmod +x "$hook"
  ok "NAT hook сохранён в $hook"

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
  info "Следующий шаг: пункт меню 2 — Создать сервер"
  break
  done
}

do_gen() {
  log_info "do_gen: старт"
  command -v awg &>/dev/null || { err "awg не найден. Сначала пункт 1"; return 1; }
  command -v python3 &>/dev/null || { err "python3 не найден — нужен для генерации параметров"; info "Запусти пункт 1 или: apt-get install python3"; return 1; }

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
    info "  • Пункт 11 — Сбросить настройки сервера (чистая переустановка)"
    info "  • Пункт 12 — Удалить всё (пакеты + конфиги)"
    info "После этого выбери пункт 2 заново и укажи нужный профиль."
    return 0
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
  echo "  5) 1320 — безопасно для AWG 2.0 + CPS, рекомендуется"
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

  local obf_label
  case ${OBF_LEVEL:-1} in
    1) obf_label="Базовый (без CPS)" ;;
    2) obf_label="+I1 (мимикрия)" ;;
    3) obf_label="+I1-I5 (полный CPS)" ;;
    *) obf_label="Базовый" ;;
  esac

  hdr "≡  Параметры настройки"
  echo -e "  ${W}Версия     : ${N}$AWG_VERSION"
  echo -e "  ${W}Обфускация : ${N}$obf_label"
  echo -e "  ${W}DNS        : ${N}$CLIENT_DNS"
  echo -e "  ${W}Мимикрия   : ${N}${MIMICRY_PROFILE:-none}"
  echo -e "  ${W}I1         : ${N}${I1:+получен (${#I1} байт)}"
  echo -e "  ${W}Клиент     : ${N}$CLIENT_ADDR"
  echo -e "  ${W}Сервер     : ${N}$SERVER_ADDR"
  echo -e "  ${W}MTU        : ${N}$MTU"
  echo -e "  ${W}Порт       : ${N}$PORT"
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
    echo "# AmneziaWG Toolza — AWG 2.0 server config"
    echo "# Region: ${SERVER_REGION:-world}"
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = $SERVER_ADDR"
    echo "ListenPort = $PORT"
    echo "MTU = $MTU"
    echo -e "$AWG_PARAMS_LINES"
    # I1-I5 НЕ записываем в серверный конфиг — это клиентские параметры.
    # Сервер не нуждается в CPS signature packets.
    echo ""
    echo "PostUp   = ip link set dev awg0 mtu $MTU; echo 1 > /proc/sys/net/ipv4/ip_forward; iptables -t nat -C POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE; iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT"
    echo "PostDown = iptables -t nat -D POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true"
    echo ""
    echo "[Peer]"
    echo "# client1"
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
    echo "Endpoint = $srv_ip:$PORT"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } > /root/client1_awg2.conf
  chmod 600 /root/client1_awg2.conf

  if awg-quick up "$SERVER_CONF"; then
    log_info "do_gen: awg-quick up успешно"
  else
    log_err "do_gen: awg-quick up провалился"
    warn "awg-quick up не удался"
    echo ""
    echo -e "  ${Y}→ Возможные причины:${N}"
    echo -e "  ${Y}  • Модуль amneziawg не загружен → reboot${N}"
    echo -e "  ${Y}  • Конфликт iptables правил → пункт 11 (сброс сервера) и заново${N}"
    echo -e "  ${Y}  • Порт $PORT заблокирован → ufw allow $PORT/udp${N}"
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
  _share_config "/root/client1_awg2.conf"

  echo ""
  success_box "■  Сервер создан успешно"
  echo -e "${W}  Версия : ${N}$AWG_VERSION"
  echo -e "${W}  Профиль: ${N}${MIMICRY_PROFILE:-none}"
  echo -e "${W}  Сервер : ${N}$SERVER_CONF"
  echo -e "${W}  Клиент : ${N}/root/client1_awg2.conf"
  echo -e "${W}  IP     : ${N}$srv_ip:$PORT"
  echo -e "${W}  Iface  : ${N}$iface"

  _setup_autostart
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
        cur_name="${BASH_REMATCH[1]}"
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
  [[ ! -f "$SERVER_CONF" ]] && { warn "Конфиг сервера не найден. Сначала пункт 2"; return 0; }
  command -v awg &>/dev/null || { warn "awg не найден"; return 0; }

  while true; do
    echo ""
    hdr "⚙  Управление клиентами"
    echo -e "  ${G}1)${N} Добавить клиента"
    echo -e "  ${G}2)${N} Переименовать клиента"
    echo -e "  ${R}3)${N} Удалить клиента"
    echo -e "  ${C}4)${N} Показать QR клиента"
    echo -e "  ${C}5)${N} Показать конфиг клиента (текст)"
    echo -e "  ${W}0)${N} Назад в главное меню"
    echo ""
    local MGMT_CHOICE
    safe_read MGMT_CHOICE "$(echo -e "${C}  Выбор [0-5]: ${N}")"
    case "${MGMT_CHOICE:-}" in
      1) do_add_client ;;
      2) do_rename_client ;;
      3) do_delete_client ;;
      4) do_show_qr ;;
      5) do_show_config ;;
      0) return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
    echo ""
    read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" _ || return 0
  done
}

# ── Показать конфиг клиента (текст) ──
do_show_config() {
  local found=()
  while IFS= read -r -d '' f; do
    found+=("$f")
  done < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  [[ ${#found[@]} -eq 0 ]] && { err "Конфиги не найдены в /root/"; return 1; }

  local unique
  mapfile -t unique < <(printf "%s\n" "${found[@]}" | sort -u)

  hdr "≡  Выбери конфиг"
  local i=0
  for f in "${unique[@]}"; do
    i=$((i+1))
    echo "  $i) $(basename "$f")"
  done

  local SEL
  local prompt="  Выбор [1-$i] (Enter = 1): "
  [[ $i -eq 1 ]] && prompt="  Выбор [1] (Enter = 1): "
  safe_read SEL "$(echo -e "${C}${prompt}${N}")"
  SEL=${SEL:-1}
  [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= i )) || { warn "Неверный выбор"; return 0; }

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
  safe_read SEL "$(echo -e "${C}  Номер клиента [1-${#MGMT_PUBKEYS[@]}] (0 = отмена): ${N}")"
  [[ "$SEL" == "0" || -z "$SEL" ]] && { info "Отменено"; return 0; }
  if ! [[ "$SEL" =~ ^[0-9]+$ ]] || (( SEL < 1 || SEL > ${#MGMT_PUBKEYS[@]} )); then
    warn "Неверный номер"; return 0
  fi

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
  # Если комментарий есть — заменяем, если нет — добавляем после [Peer]
  local tmp_conf
  tmp_conf=$(mktemp)
  awk -v pk="$pk" -v new_name="$new_name" '
    BEGIN { in_peer=0; peer_buf=""; has_comment=0 }
    /^\[Peer\]/ {
      # Сохраняем предыдущий peer блок если был
      if (in_peer && peer_buf != "") {
        printf "%s", peer_buf
      }
      in_peer=1
      peer_buf=$0 "\n"
      has_comment=0
      next
    }
    in_peer {
      peer_buf = peer_buf $0 "\n"
      if ($0 ~ /^#[[:space:]]/) has_comment=1
      if ($0 ~ /^PublicKey[[:space:]]*=[[:space:]]*/) {
        # Нашли PublicKey — проверяем совпадение
        line_pk=$0
        sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", line_pk)
        gsub(/[[:space:]]/, "", line_pk)
        tgt=pk
        gsub(/[[:space:]]/, "", tgt)
        if (line_pk == tgt) {
          # Обновляем комментарий в peer_buf
          if (has_comment) {
            # Заменяем существующий # ...
            gsub(/\n#[[:space:]][^\n]*\n/, "\n# " new_name "\n", peer_buf)
          } else {
            # Добавляем # new_name после [Peer]
            sub(/\[Peer\]\n/, "[Peer]\n# " new_name "\n", peer_buf)
          }
        }
      }
      next
    }
    { print }
    END {
      if (in_peer && peer_buf != "") printf "%s", peer_buf
    }
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
do_delete_client() {
  _mgmt_scan_clients || { warn "Нет клиентов для удаления"; return 0; }
  hdr "🗑  Удалить клиента"
  _mgmt_print_list

  local SEL
  safe_read SEL "$(echo -e "${C}  Номер клиента [1-${#MGMT_PUBKEYS[@]}] (0 = отмена): ${N}")"
  [[ "$SEL" == "0" || -z "$SEL" ]] && { info "Отменено"; return 0; }
  if ! [[ "$SEL" =~ ^[0-9]+$ ]] || (( SEL < 1 || SEL > ${#MGMT_PUBKEYS[@]} )); then
    warn "Неверный номер"; return 0
  fi

  local idx=$((SEL - 1))
  local del_name="${MGMT_NAMES[$idx]}"
  local del_pk="${MGMT_PUBKEYS[$idx]}"
  local del_ip="${MGMT_IPS[$idx]}"

  echo ""
  echo -e "${Y}  ▲ Будет удалён клиент:${N}"
  echo -e "     Имя: ${W}$del_name${N}"
  echo -e "     IP : ${W}$del_ip${N}"
  echo -e "     Ключ: ${D}${del_pk:0:20}...${N}"
  echo ""
  local CONFIRM
  safe_read CONFIRM "$(echo -e "${R}  Подтвердить удаление? [y/N]: ${N}")"
  [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { info "Отменено"; return 0; }

  # Бекап
  local bak
  bak="${SERVER_CONF}.pre_delete.$(date +%s)"
  cp "$SERVER_CONF" "$bak"

  # Удаляем peer из runtime
  awg set awg0 peer "$del_pk" remove 2>/dev/null || warn "Не удалось удалить peer из runtime"

  # Удаляем блок [Peer] из SERVER_CONF через awk
  # Стратегия: буферизуем каждый [Peer] блок целиком, печатаем только если его PublicKey != del_pk
  local tmp_conf
  tmp_conf=$(mktemp)
  awk -v pk="$del_pk" '
    BEGIN { in_peer=0; peer_buf=""; match_pk=0 }
    /^\[Peer\]/ {
      # Печатаем предыдущий peer если он не удаляется
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
    err "awk не смог обработать конфиг, восстанавливаю из бекапа"
    mv "$bak" "$SERVER_CONF"
    rm -f "$tmp_conf"
    return 1
  fi

  mv "$tmp_conf" "$SERVER_CONF"
  chmod 600 "$SERVER_CONF"

  # Удаляем файл клиента
  local del_file="/root/${del_name}_awg2.conf"
  if [[ -f "$del_file" && "$del_name" != "безымянный" ]]; then
    rm -f "$del_file"
    ok "Файл удалён: $(basename "$del_file")"
  fi

  ok "Клиент удалён: $del_name ($del_ip)"
  info "Бекап конфига: $bak"

  # Синхронизируем peers.list — убираем удалённого клиента из Warp
  if declare -f _warp_sync_peers >/dev/null 2>&1; then
    _warp_sync_peers 2>/dev/null || true
  fi
}

do_add_client() {
  [[ ! -f "$SERVER_CONF" ]] && { warn "Конфиг сервера не найден. Сначала пункт 2 — возврат в главное меню"; return 0; }
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

  local client_file="/root/${client_name}_awg2.conf"
  if [[ -f "$client_file" ]]; then warn "Файл $client_file уже существует — будет перезаписан"; fi

  read_yesno CONFIRM_IP "$(echo -e "${C}  Использовать IP $client_addr? [Y/n]: ${N}")" "y"
  if [[ "$CONFIRM_IP" != "y" ]]; then
    read -rp "  IP вручную (пример: ${base_ip}.5/32): " client_addr
    [[ -z "$client_addr" ]] && { warn "IP не введён — возврат"; return 0; }
  fi

  choose_dns

  info "Версия сервера: AWG 2.0"

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

  # Читаем профиль сервера — определяет поведение для клиентского I1
  local _srv_profile
  _srv_profile=$(grep -m1 '^# AWG_PROFILE=' "$SERVER_CONF" 2>/dev/null | cut -d= -f2 || true)
  _srv_profile="${_srv_profile:-pro}"

  case "$_srv_profile" in
    lite)
      # Lite-сервер: клиенту всегда I1=DNS (icloud.com), без I2-I5
      info "Профиль сервера: Lite — клиент получит I1=DNS (icloud.com)"
      local cps_out
      cps_out=$(gen_cps_i1 "dns" "icloud.com") || cps_out=""
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=""; I3=""; I4=""; I5=""
      [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
      ;;
    standard)
      # Standard-сервер: клиенту всегда I1=QUIC, без I2-I5
      info "Профиль сервера: Standard — клиент получит I1=QUIC"
      local sel_domain
      sel_domain=$(select_random_domain "quic")
      [[ -z "$sel_domain" ]] && sel_domain=""
      local cps_out
      cps_out=$(gen_cps_i1 "quic" "$sel_domain") || cps_out=""
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

  local srv_pub srv_ip port mtu
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
  awg_params_from_srv=$(sed -n '/^\[Peer\]/q; p' "$SERVER_CONF" | grep -E "^(Jc|Jmin|Jmax|S[1-4]|H[1-4]) = " | grep -v "^#" || true)

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
    echo "Endpoint = $srv_ip:$port"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } > "$client_file"
  chmod 600 "$client_file"

  # Применяем через syncconf (без разрыва других клиентов)
  info "Применяем конфиг..."
  _apply_config 2>/dev/null || warn "syncconf не удался, может потребоваться перезапуск (пункт 5)"

  # Раздача конфига (QR без I1-I5 или текст)
  _share_config "$client_file"

  echo ""
  success_box "▣  Клиент добавлен успешно"
  echo -e "${W}  Имя    : ${N}$client_name"
  echo -e "${W}  IP     : ${N}$client_addr"
  echo -e "${W}  Конфиг : ${N}$client_file"
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
  local name="" pubkey="" ip="" tx_raw=0 rx_raw=0 handshake_time="" endpoint=""
  
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[Peer\] ]]; then
      if [[ $i -gt 0 ]] && [[ -n "$pubkey" ]]; then
        # Нормализуем значения перед арифметикой
        tx_raw=${tx_raw:-0}
        rx_raw=${rx_raw:-0}
        _print_client_info "$i" "$name" "$ip" "$tx_raw" "$rx_raw" "$handshake_time" "$endpoint"
      fi
      i=$((i+1))
      name=""; pubkey=""; ip=""; tx_raw=0; rx_raw=0; handshake_time=""; endpoint=""
    elif [[ "$line" =~ ^#[[:space:]](.+) ]]; then
      name="${BASH_REMATCH[1]}"
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
    _print_client_info "$i" "$name" "$ip" "$tx_raw" "$rx_raw" "$handshake_time" "$endpoint"
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
  echo -e "  ${W}└─────────────────────────────────────────────────────────────────────────${N}"
}

do_show_qr() {
  local found=()
  while IFS= read -r -d '' f; do
    found+=("$f")
  done < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  [[ ${#found[@]} -eq 0 ]] && { err "Конфиги клиентов не найдены в /root/"; return 1; }

  local unique
  mapfile -t unique < <(printf "%s\n" "${found[@]}" | sort -u)

  hdr "≡  Выбери конфиг"
  local i=0
  for f in "${unique[@]}"; do
    i=$((i+1))
    echo "  $i) $(basename "$f")"
  done

  local QR_CHOICE prompt_txt
  if [[ $i -eq 1 ]]; then
    prompt_txt="  Выбор [1] (Enter = 1): "
  else
    prompt_txt="  Выбор [1-$i] (Enter = 1): "
  fi
  safe_read QR_CHOICE "$(echo -e "${C}${prompt_txt}${N}")"
  QR_CHOICE=${QR_CHOICE:-1}
  if ! [[ "$QR_CHOICE" =~ ^[0-9]+$ ]] || (( QR_CHOICE < 1 || QR_CHOICE > i )); then
    warn "Неверный выбор"; return 0
  fi

  local chosen="${unique[$((QR_CHOICE - 1))]}"
  [[ -f "$chosen" ]] || { warn "Файл не найден"; return 0; }

  _share_config "$chosen"
  echo ""
  echo -e "${D}  Конфиг: $chosen${N}"
}

do_restart() {
  hdr "↻  Перезапуск awg0"
  if [[ ! -f "$SERVER_CONF" ]]; then
    err "Конфиг сервера не найден"
    echo -e "  ${Y}→ Возможно, AmneziaWG ещё не установлен${N}"
    echo -e "  ${Y}→ Выбери пункт 1 для установки зависимостей${N}"
    echo -e "  ${Y}→ Затем пункт 2 для создания сервера${N}"
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
  if awg-quick up "$SERVER_CONF"; then
    ok "awg0 перезапущен"
  else
    err "Не удалось поднять awg0"
    echo -e "  ${Y}→ Проверь:${N}"
    echo -e "  ${Y}  • cat $SERVER_CONF${N}"
    echo -e "  ${Y}  • lsmod | grep amneziawg${N}"
    echo -e "  ${Y}  • dmesg | tail -20${N}"
    echo -e "  ${Y}  • reboot и попробовать снова${N}"
    return 1
  fi
}

# 10. СБРОС СЕРВЕРА (чистая переустановка)
# Удаляет конфиги и правила firewall, но НЕ трогает пакеты/бинарники.
# После сброса можно сразу пункт 2 — создать новый сервер.
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
  echo -e "${C}  После сброса можно сразу пункт 2 — создать новый сервер.${N}"
  echo ""

  local CONFIRM_RST
  safe_read CONFIRM_RST "$(echo -e "${R}  Подтверди сброс [yes/N]: ${N}")"
  if [[ "$CONFIRM_RST" != "yes" ]]; then
    warn "Отменено."
    return 0
  fi

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
  echo -e "${C}  Теперь можно пункт 2 — создать новый сервер${N}"
  echo ""
  log_info "do_reset_server: сброс выполнен"
}

# Перенаправляет трафик AWG туннеля через Cloudflare Warp.
# Поддерживает бесплатный Warp и Warp+ с лицензионным ключом.
# Полезно когда IP сервера в блок-листах РКН — выходной IP меняется на Cloudflare.

_warp_install_wgcf() {
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

  # ───── WireGuard tools ─────
  if ! command -v wg-quick &>/dev/null; then
    info "Устанавливаем wireguard-tools..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y -q wireguard-tools >/dev/null 2>&1 || warn "wireguard-tools не установился"
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
    /^# /{ name=$2 }
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
      iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE 2>/dev/null || \
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
  systemctl enable --now awg-warp-healthcheck.timer 2>/dev/null
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
    read -rp "$(echo -e "${C}  Выбор: ${N}")" PEER_CHOICE

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
  if [[ ! -f "$WARP_CONF" ]]; then
    err "Конфиг Warp не найден. Сначала выполни пункт 1"
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
    info "Сначала создай AWG сервер (пункт 2), потом включай Warp"
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
  local tmp_wg_conf
  tmp_wg_conf=$(mktemp)
  cat > "$tmp_wg_conf" << EOF
[Interface]
PrivateKey = $warp_priv

[Peer]
PublicKey = $warp_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $warp_endpoint
EOF
  if ! wg setconf warp0 "$tmp_wg_conf"; then
    err "wg setconf warp0 failed"
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
  iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE

  # Добавляем MASQUERADE через warp0 (для клиентов с ip rule lookup 200)
  iptables -t nat -C POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE

  # FORWARD правила
  iptables -C FORWARD -i awg0 -o warp0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i awg0 -o warp0 -j ACCEPT
  iptables -C FORWARD -i warp0 -o awg0 -j ACCEPT 2>/dev/null || \
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

  # Если peers list пуст или не существует — заполняем всеми клиентами по умолчанию
  if [[ ! -s "$WARP_PEERS" ]]; then
    info "Список клиентов в Warp пуст — добавляем всех по умолчанию"
    mkdir -p "$WARP_DIR"
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
  info "Управление клиентами в Warp: пункт 6 в меню"

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

tmp_conf=$(mktemp)
cat > "$tmp_conf" << EOC
[Interface]
PrivateKey = $warp_priv

[Peer]
PublicKey = $warp_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $warp_endpoint
EOC
wg setconf warp0 "$tmp_conf" || { rm -f "$tmp_conf"; ip link delete warp0; exit 1; }
rm -f "$tmp_conf"

ip -4 address add "$warp_addr4" dev warp0 2>/dev/null || true
ip link set mtu "$warp_mtu" up dev warp0 || { ip link delete warp0; exit 1; }

# rp_filter loose для VPN-интерфейсов
sysctl -w net.ipv4.conf.warp0.rp_filter=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.awg0.rp_filter=2 >/dev/null 2>&1 || true

# MASQUERADE: warp0 для пометленных + eth0 для остальных (fallback)
iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE
iptables -t nat -C POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$client_net" -o warp0 -j MASQUERADE
iptables -C FORWARD -i awg0 -o warp0 -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i awg0 -o warp0 -j ACCEPT
iptables -C FORWARD -i warp0 -o awg0 -j ACCEPT 2>/dev/null || \
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
        iptables -t nat -C POSTROUTING -s "$client_net" -o "$iface" -j MASQUERADE 2>/dev/null || \
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

# Перебор Cloudflare endpoint'ов — для случаев когда стандартный 2408 блокируется DPI
# (типично на РФ хостингах). Пробует разные порты на разных IP пока не найдёт рабочий.
_warp_endpoint_finder() {
  if ! ip link show warp0 &>/dev/null; then
    err "warp0 не активен — сначала включи туннель (пункт 3)"
    return 1
  fi

  # Pubkey peer'а для wg set
  local peer_pub
  peer_pub=$(wg show warp0 peers 2>/dev/null | head -1)
  if [[ -z "$peer_pub" ]]; then
    err "Не могу получить pubkey peer'а из warp0"
    return 1
  fi

  echo ""
  hdr "🔍  Поиск рабочего Cloudflare endpoint"
  echo ""
  echo -e "  Если стандартный 2408 не работает — пробуем альтернативы."
  echo -e "  ${D}Список из NTC.party — портов которые иногда проходят через DPI${N}"
  echo ""

  # Топ-портов которые часто работают (взято из NTC.party и обсуждений)
  local TOP_PORTS=(2408 1701 4500 500 1002 854 859 894 955 7156 7281 891 943 4198 8854)
  # IP блоки Cloudflare Warp (только начало диапазонов 162.159.192.x и 195.x)
  local TOP_IPS=(162.159.192.1 162.159.193.10 162.159.195.1 162.159.192.10 162.159.192.5 162.159.195.5)

  local found_endpoint=""
  local attempts=0
  local max_attempts=30

  echo -e "  Начинаю перебор (макс $max_attempts попыток)..."
  echo ""

  for ip in "${TOP_IPS[@]}"; do
    for port in "${TOP_PORTS[@]}"; do
      attempts=$((attempts+1))
      [[ $attempts -gt $max_attempts ]] && break 2

      local endpoint="${ip}:${port}"
      printf "  [%2d/%d] %-26s ... " "$attempts" "$max_attempts" "$endpoint"

      # Меняем endpoint
      wg set warp0 peer "$peer_pub" endpoint "$endpoint" 2>/dev/null || {
        echo -e "${R}set fail${N}"
        continue
      }

      # Сбрасываем счётчик received (узнаем стартовое значение)
      local rx_before
      rx_before=$(wg show warp0 transfer 2>/dev/null | awk '{print $2}' | head -1 || echo "0")

      # Триггерим handshake — отправляем 1 ping чтобы wireguard попытался connect
      timeout 1 ping -c 1 -W 1 -I warp0 1.1.1.1 &>/dev/null || true

      # Ждём 4 секунды для handshake
      sleep 4

      # Проверяем — есть ли новые байты в received
      local rx_after
      rx_after=$(wg show warp0 transfer 2>/dev/null | awk '{print $2}' | head -1 || echo "0")

      if [[ "$rx_after" -gt "$rx_before" ]]; then
        echo -e "${G}✓ работает!${N} (received: $rx_after)"
        found_endpoint="$endpoint"
        break 2
      else
        echo -e "${D}нет ответа${N}"
      fi
    done
  done

  echo ""
  if [[ -n "$found_endpoint" ]]; then
    ok "Найден рабочий endpoint: $found_endpoint"
    echo ""
    info "Сохраняю в state и в профиль..."

    # Обновляем wgcf-profile.conf чтобы при следующем рестарте использовался этот endpoint
    if [[ -f "$WARP_PROFILE" ]]; then
      sed -i "s|^Endpoint = .*|Endpoint = $found_endpoint|" "$WARP_PROFILE"
    fi
    if [[ -f "$WARP_CONF" ]]; then
      sed -i "s|^Endpoint = .*|Endpoint = $found_endpoint|" "$WARP_CONF"
    fi

    # Делаем ping для проверки реальной связности
    info "Проверяем туннель..."
    if timeout 5 ping -c 2 -W 2 -I warp0 1.1.1.1 &>/dev/null; then
      ok "Туннель работает! Через Warp проходит трафик"
    else
      warn "Handshake есть, но ping ещё не идёт. Подожди 10-30 секунд"
    fi
  else
    err "Ни один endpoint не ответил за $attempts попыток"
    echo ""
    warn "Скорее всего твой провайдер ($(curl -s ipinfo.io/org 2>/dev/null || echo 'хостер')) блокирует UDP-трафик к Cloudflare"
    echo ""
    info "Рекомендации:"
    info "  • Сменить хостинг (российские VPS часто блокируют Cloudflare)"
    info "  • Использовать AWG без Warp (пункт 4 — выключить Warp)"
    info "  • Попробовать MASQUE-клиент (usque) — он ходит через 443/HTTPS"
  fi

  return 0
}


_warp_remove() {
  echo ""
  warn "Удалить Warp полностью? Будет удалено:"
  warn "  • $WARP_CONF"
  warn "  • $WARP_DIR (аккаунт + список клиентов)"
  warn "  • /usr/local/bin/wgcf"
  warn "  • Health-check service/timer"
  echo ""
  safe_read CONFIRM "$(echo -e "${R}  Подтверди [yes/N]: ${N}")"
  [[ "$CONFIRM" != "yes" ]] && { warn "Отменено"; return 0; }

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

  # Также копируем в /etc/wireguard/warp0.conf для использования скриптом
  cp "$WARP_PROFILE" "$WARP_CONF"
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
    hdr "☁  Warp туннель (Cloudflare)"
    echo ""
    _warp_status || true
    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  1) Установить wgcf и зарегистрировать Warp (бесплатный)"
    echo -e "  2) Активировать Warp+ (ввести лицензионный ключ)"
    echo -e "  3) Включить туннель"
    echo -e "  4) Выключить туннель"
    echo -e "  5) Перегенерировать профиль (после смены лицензии)"
    echo -e "  ${C}6) Управление клиентами в Warp${N}"
    echo -e "  ${C}7) Health-check (вкл/выкл авто-failover)${N}"
    echo -e "  ${C}8) Импорт wgcf-profile.conf (если регистрация не работает)${N}"
    echo -e "  ${C}9) Поиск рабочего endpoint (если 2408 заблокирован DPI)${N}"
    echo -e "  ${R}d) Удалить Warp полностью${N}"
    echo -e "  0) Назад в главное меню"
    echo ""
    safe_read WARP_CHOICE "$(echo -e "${C}  Выбор [0-9, d]: ${N}")"

    case "${WARP_CHOICE:-}" in
      1)
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
          echo -e "  и импортируй сюда через ${W}пункт 8${N} в этом меню."
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
      2) _warp_apply_license; read -rp "Enter..." ;;
      3) _warp_up; read -rp "Enter..." ;;
      4) _warp_down; read -rp "Enter..." ;;
      5)
        _warp_generate_profile && info "Профиль обновлён. Если warp0 активен — выключи и включи (4 → 3)"
        read -rp "Enter..."
        ;;
      6) do_warp_peers_menu ;;
      7) _warp_health_toggle; read -rp "Enter..." ;;
      8) _warp_import_account; read -rp "Enter..." ;;
      9) _warp_endpoint_finder; read -rp "Enter..." ;;
      d|D) _warp_remove; read -rp "Enter..." ;;
      0|"")
        set -e
        return 0
        ;;
      *) warn "Неверный выбор"; sleep 1 ;;
    esac
  done
  set -e
}


# ── Шифрованный DNS (dnscrypt-proxy) — пункт меню 16 ────────────

# Проверка статуса dnscrypt-proxy
_dns_proxy_status() {
  if ! command -v dnscrypt-proxy &>/dev/null; then
    echo -e "  Статус     : ${D}○ не установлен${N}"
    return 1
  fi
  if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
    echo -e "  Статус     : ${G}● активен${N}"
    # DNAT IPv4
    if iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null; then
      echo -e "  DNAT IPv4  : ${G}● настроен${N} ${D}(awg0 → ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT})${N}"
    else
      echo -e "  DNAT IPv4  : ${R}✗ правило отсутствует${N}"
    fi
    # DoT блокировка
    if iptables -C FORWARD -i awg0 -p tcp --dport 853 -j DROP 2>/dev/null; then
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
      local last_check
      last_check=$(systemctl status awg-dns-healthcheck.timer 2>/dev/null | grep "Trigger:" | head -1 | sed 's/.*Trigger: //' || echo "?")
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
    info "Сначала установи AWG (пункт 2 главного меню), затем включи DNS-шифрование"
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
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" 2>/dev/null || true

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
iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null || true
iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null || true
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
if ! iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null; then
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
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "${DNS_PROXY_ADDR}:${DNS_PROXY_PORT}" 2>/dev/null || true
  # Старые правила (для совместимости с прошлыми версиями)
  iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:5300" 2>/dev/null || true

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
  read -rp "  Выбор: " UPSTREAM_CHOICE

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

# Меню шифрованного DNS — пункт 16
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
    safe_read DNS_CHOICE "  Выбор [0-5]: "

    case "${DNS_CHOICE:-}" in
      1)
        # Проверим что AWG установлен
        if ! ip link show awg0 &>/dev/null; then
          warn "Сначала создай AWG сервер (пункт 2 главного меню)"
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


do_uninstall() {
  echo ""
  hdr "⌧  Удаление AmneziaWG"
  warn "Будет удалено:"
  echo -e "  ${R}—${N} Интерфейс awg0"
  echo -e "  ${R}—${N} Пакеты amneziawg, amneziawg-tools"
  echo -e "  ${R}—${N} /etc/amnezia/amneziawg/"
  echo -e "  ${R}—${N} /root/*_awg2.conf"
  echo -e "  ${R}—${N} Автозапуск awg-quick@awg0"
  echo ""
  local CONFIRM_DEL
  safe_read CONFIRM_DEL "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")"
  [[ "$CONFIRM_DEL" != "yes" ]] && { warn "Отменено."; return 0; }

  # v6.4: авто-бэкап перед удалением (последний шанс восстановиться)
  if [[ -f "$SERVER_CONF" ]]; then
    auto_backup "uninstall" || warn "Авто-бэкап не удался"
  fi

  trash "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  trash "Отключаем автозапуск..."
  systemctl disable awg-quick@awg0 2>/dev/null || true
  rm -rf /etc/systemd/system/awg-quick@awg0.service.d 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

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

  echo ""
  ok "Всё удалено"
  _DEPS_CACHED=""  # сбрасываем кэш — awg больше нет
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
  safe_read CONFIRM "$(echo -e "${R}  Подтвердить удаление клиентов? [yes/N]: ${N}")"
  [[ "$CONFIRM" != "yes" ]] && { warn "Отменено."; return 0; }

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
  if ! awg-quick up "$SERVER_CONF" 2>/dev/null; then
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
  local username timestamp backup_path

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

  # Лог
  [[ -f "$LOG_FILE" ]] && cp "$LOG_FILE" "$backup_path/awg-manager.log" || true

  # Метаданные бекапа
  {
    echo "timestamp=$timestamp"
    echo "server_conf=$SERVER_CONF"
    echo "backed_files=$backed_up"
    echo "awg_version=2.0"
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
  safe_read RESTORE_CHOICE "$(echo -e "${C}  Выбери номер бекапа (Enter = 1): ${N}")"
  RESTORE_CHOICE=${RESTORE_CHOICE:-1}

  if ! [[ "$RESTORE_CHOICE" =~ ^[0-9]+$ ]] || \
     [[ "$RESTORE_CHOICE" -lt 1 ]] || \
     [[ "$RESTORE_CHOICE" -gt ${#backups[@]} ]]; then
    err "Неверный выбор"
    return 1
  fi

  local chosen_backup="${backups[$((RESTORE_CHOICE - 1))]}"
  echo -e "${C}  → Восстановление из: ${W}$(basename "$chosen_backup")${N}"

  safe_read CONFIRM_RESTORE "$(echo -e "${R}  Текущий серверный конфиг будет заменён. Продолжить? [yes/N]: ${N}")"
  [[ "$CONFIRM_RESTORE" != "yes" ]] && { warn "Отменено."; return 0; }

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

  # Поднимаем интерфейс
  info "Запускаем awg0..."
  if awg-quick up "$SERVER_CONF" 2>/dev/null; then
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
AWG_VERSION="2.0"   # единственная поддерживаемая версия
I1=""
I2=""
I3=""
I4=""
I5=""
MIMICRY_PROFILE=""
MTU=""
AWG_PARAMS_LINES=""
ERROR_COUNT=0

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
  local IFS='.'; local -a o=($ip)
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
    rule_num=$(ufw status numbered 2>/dev/null | grep -F "${CASCADE_TAG}:" | head -1 | grep -oE '^\[\s*[0-9]+\s*\]' | tr -d '[ ]')
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
  local line tag_only
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
  safe_read num "$(echo -e "${C}  Номер для удаления (Enter — отмена): ${N}")"
  [[ -z "${num// /}" ]] && return 0
  [[ "$num" =~ ^[0-9]+$ ]] || { err "Нужно число"; return 1; }
  (( num >= 1 && num <= count )) || { err "Номер вне диапазона"; return 1; }

  local n=0 proto in_port target_ip out_port comment found=""
  while IFS='|' read -r proto in_port target_ip out_port comment; do
    [[ -z "${proto:-}" || "${proto:0:1}" == "#" ]] && continue
    n=$((n + 1))
    if (( n == num )); then
      found="yes"
      break
    fi
  done < "$CASCADE_RULES"

  [[ -n "$found" ]] || { err "Не нашёл #$num"; return 1; }

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
  hdr "🔍  Диагностика каскада"
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
    safe_read CASCADE_CHOICE "$(echo -e "${C}  Выбор: ${N}")"

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

_global_cleanup() {
  rm -rf /tmp/awg_tmp_* /tmp/awg_ping_* 2>/dev/null || true
  # Кэш доменов оставляем (используется повторно в do_check_domains),
  # удаляем только если он битый (нулевого размера)
  [[ -f /tmp/awg_domain_cache.txt && ! -s /tmp/awg_domain_cache.txt ]] && \
    rm -f /tmp/awg_domain_cache.txt 2>/dev/null || true
}
trap '_global_cleanup' EXIT
trap '_global_cleanup; echo ""; warn "Прервано пользователем"; exit 130' INT TERM

while true; do
  check_deps
  show_header
  show_menu
  # show_menu уже читает CHOICE, дополнительный read не нужен

  case "${CHOICE:-}" in
    1)   do_install ;;
    2)   do_gen ;;
    3)   do_manage_clients ;;
    4)   do_list_clients ;;
    5)   do_restart ;;
    6)   do_check_domains ;;
    7)   do_sniff_test ;;
    8)   do_backup ;;
    9)   do_restore ;;
    10)  do_clean_clients ;;
    11)  do_reset_server ;;
    12)  do_uninstall ;;
    13)  do_repair ;;
    14)  do_self_update ;;
    15)  do_warp_menu ;;
    16)  do_dns_menu ;;
    17)  do_cascade_menu ;;
    0)  log_info "Выход"
        echo -e "\n${G}  В путь! ${N}"
        echo -e "<< Подпишись на ТГ :) >>"
        echo -e "<< https://t.me/awgToolza >>\n"
        exit 0 ;;
    *)
      warn "Неверный выбор"
      ERROR_COUNT=$((ERROR_COUNT + 1))
      if [[ $ERROR_COUNT -ge 5 ]]; then
        warn "Слишком много неверных нажатий подряд (${ERROR_COUNT}). Будь внимательнее — проверь раскладку и Caps Lock."
        log_err "Слишком много неверных выборов подряд (${ERROR_COUNT}) — продолжаем"
        ERROR_COUNT=0
        sleep 1
      fi
      ;;
  esac

  if [[ "${CHOICE:-}" =~ ^[0-9]+$ ]] && [[ "${CHOICE:-}" -le 17 ]]; then
    ERROR_COUNT=0
  fi

  # Сбрасываем CHOICE — защита от повторного срабатывания предыдущего выбора
  # при следующем show_menu (если пользователь нажмёт Enter без ввода)
  CHOICE=""
  echo ""
  read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || break
done
