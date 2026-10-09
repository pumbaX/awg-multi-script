#!/usr/bin/env bash
# AWG Toolza — менеджер сервера AmneziaWG 2.0 / 3.1 для Ubuntu 24.04+ и Debian 12+.
# Файл собран из src/ скриптом build.sh — правки вносить в исходники.
# Без -e: каждый шаг проверяется явно. С -e любая безобидная
# ненулевая команда обрывала бы скрипт посреди настройки сети.
set -uo pipefail

VERSION="v1.2.28"
# Буква тестовой сборки (AWG_BUILD=b ./build.sh): видна в меню, боте и панели,
# в сравнении версий не участвует. У выпущенной сборки пусто.
BUILD=""
VERSION_SHOW="$VERSION$BUILD"

# ═════ core ═════
# Базовые примитивы: вывод, ввод, журнал, временные файлы, случайные числа,
# запуск встроенного Python и генерация самостоятельных служебных скриптов.

R='\033[38;5;203m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[1;94m'; M='\033[0;35m'; C='\033[0;36m'
W='\033[1;37m'; D='\033[0;90m'; N='\033[0m'

# Неинтерактивный режим (--auto, --add-client, вызовы из бота и таймеров):
# ни один шаг не должен ждать ввода.
AUTO_MODE=0

ok()   { echo -e "${G}  √ $*${N}"; }
err()  { echo -e "${R}  × $*${N}"; }
warn() { echo -e "${Y}  ▲ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }
dim()  { echo -e "${D}    $*${N}"; }

LINE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
hdr() {
  echo -e "${B}${LINE}${N}"
  echo -e "  ${W}$*${N}"
  echo -e "${B}${LINE}${N}"
}
success_box() {
  echo -e "${G}${LINE}${N}"
  echo -e "  ${W}$*${N}"
  echo -e "${G}${LINE}${N}"
}

# ── Журнал ────────────────────────────────────────────────
log_to() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
log_info() { log_to INFO "$@"; }
log_warn() { log_to WARN "$@"; }
log_err()  { log_to ERROR "$@"; }

log_init() {
  if ! { touch "$LOG_FILE" && chmod 600 "$LOG_FILE"; } 2>/dev/null; then
    LOG_FILE="/tmp/awg-manager.log"
    return 0
  fi
  local size
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > 5242880 )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
}

# ── Ввод ──────────────────────────────────────────────────
# Контракт всех функций ввода: Ctrl+D (EOF) = отмена и никогда не роняет
# скрипт; мусор переспрашивается; опасное подтверждается полным словом.

_flush_stdin() {
  [[ -t 0 ]] || return 0
  local _
  while read -r -t 0.05 -n 256 _ 2>/dev/null; do :; done
}

# read_line VAR "промпт" — свободный ввод, EOF = пустая строка.
read_line() {
  local __var="$1" __prompt="${2:-}" __val=""
  _flush_stdin
  if ! IFS= read -r -p "$(echo -e "$__prompt")" __val; then
    echo >&2
    __val=""
  fi
  printf -v "$__var" '%s' "$__val"
}

# read_choice VAR "промпт" MIN MAX [DEFAULT] [ДОП_КЛАВИШИ через |]
# На EOF отдаёт DEFAULT, а без него MIN (в меню это «назад»).
read_choice() {
  local __var="$1" __prompt="$2" __min="$3" __max="$4" __def="${5:-}" __extra="${6:-}"
  local __v __k __keys=()
  [[ -n "$__extra" ]] && IFS='|' read -r -a __keys <<< "$__extra"
  while true; do
    _flush_stdin
    if ! read -r -p "$(echo -e "$__prompt")" __v; then
      echo >&2
      __v="${__def:-$__min}"
      break
    fi
    __v="${__v//[[:space:]]/}"
    if [[ -z "$__v" && -n "$__def" ]]; then __v="$__def"; break; fi
    if [[ "$__v" =~ ^[0-9]+$ ]] && (( 10#$__v >= __min && 10#$__v <= __max )); then
      __v=$((10#$__v)); break
    fi
    for __k in ${__keys[@]+"${__keys[@]}"}; do
      [[ "${__v,,}" == "${__k,,}" ]] && { __v="${__k,,}"; break 2; }
    done
    if [[ -n "$__extra" ]]; then
      echo -e "${R}  Введи число от ${__min} до ${__max} или: ${__extra//|/, }${N}" >&2
    else
      echo -e "${R}  Введи число от ${__min} до ${__max}${N}" >&2
    fi
  done
  printf -v "$__var" '%s' "$__v"
}

# read_yesno VAR "промпт" [y|n] — результат y или n.
read_yesno() {
  local __var="$1" __prompt="$2" __def="${3:-}" __v
  while true; do
    _flush_stdin
    if ! read -r -p "$(echo -e "$__prompt")" __v; then
      echo >&2
      __v="${__def:-n}"
      break
    fi
    if [[ -z "$__v" && -n "$__def" ]]; then __v="$__def"; break; fi
    case "${__v,,}" in
      y|yes|д|да) __v=y; break ;;
      n|no|н|нет) __v=n; break ;;
      *) echo -e "${R}  Ответь y/да или n/нет${N}" >&2 ;;
    esac
  done
  printf -v "$__var" '%s' "$__v"
}

# Путь, подменить который может только root: он сам и все каталоги до /
# принадлежат root и закрыты на запись группе и остальным. Код оттуда можно
# запускать от root; из /tmp или домашнего каталога пользователя — нет:
# туда подложит или переименует любой пользователь сервера.
root_only_path() {  # путь
  local p m
  p=$(readlink -f -- "$1" 2>/dev/null) && [[ -e "$p" ]] || return 1
  while :; do
    [[ "$(stat -c %u -- "$p" 2>/dev/null)" == 0 ]] || return 1
    m=$(stat -c %a -- "$p" 2>/dev/null) || return 1
    (( 8#$m & 8#022 )) && return 1
    [[ "$p" == / ]] && return 0
    p=$(dirname -- "$p")
  done
}

# То же для каталога и всего, что в нём.
root_only_tree() {  # каталог
  local p
  # find — по настоящему пути: каталог-ссылку он сам не обходит
  p=$(readlink -f -- "$1" 2>/dev/null) && root_only_path "$p" || return 1
  [[ -z "$(find "$p" \( ! -user 0 -o \( ! -type l -perm /022 \) \) -print -quit 2>/dev/null)" ]]
}

# Путь для вывода через echo -e: без управляющих символов и \-последовательностей
# (имя каталога задаёт кто угодно — оно не должно перерисовать вопрос).
shown() { local s="${1//\\/\\\\}"; printf '%s' "$s" | tr '\000-\037\177' '?'; }

# ask_yes "вопрос" [y|n] — то же как условие: if ask_yes ...; then
ask_yes() {
  local __a
  if (( AUTO_MODE )); then [[ "${2:-n}" == y ]]; return; fi
  read_yesno __a "$1" "${2:-}"
  [[ "$__a" == y ]]
}

# Подтверждение необратимого действия: только слово yes или да.
read_confirm() {
  local __v
  (( AUTO_MODE )) && return 1
  _flush_stdin
  if ! read -r -p "$(echo -e "$1")" __v; then echo >&2; return 1; fi
  [[ "${__v,,}" == yes || "${__v,,}" == да ]]
}

pause() {
  (( AUTO_MODE )) && return 0
  local _
  read -r -p "$(echo -e "${C}  Enter для продолжения...${N}")" _ || true
}

# ── Долгие шаги ───────────────────────────────────────────
# apt, git, make и dkms пишут сотни строк, в которых тонет настоящая ошибка.
# run_step прячет вывод в INSTALL_LOG и оставляет одну строку на шаг, а при
# провале показывает хвост именно этого шага.
_RUN_STEP_PID=""

# Фоновый сабшелл шага не передаёт SIGINT детям (apt-get, dkms, make):
# убиваем дерево целиком, иначе сборка продолжается после «Прервано».
_kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _kill_tree "$c"; done
  kill -TERM "$1" 2>/dev/null
}

_run_step_abort() {
  [[ -n "$_RUN_STEP_PID" ]] && _kill_tree "$_RUN_STEP_PID"
  printf '\r\033[K\n'
  warn "Прервано пользователем"
  exit 130
}

run_step() {
  local title="$1"; shift
  local from=0 t0=$SECONDS rc=0 i=0 frames='-\|/' prev_trap
  [[ -f "$INSTALL_LOG" ]] && from=$(wc -l < "$INSTALL_LOG")
  printf '[%s] [STEP] %s\n' "$(date '+%F %T')" "$title" >> "$INSTALL_LOG"

  if [[ -t 1 ]]; then
    ( "$@" ) </dev/null >>"$INSTALL_LOG" 2>&1 &
    _RUN_STEP_PID=$!
    prev_trap=$(trap -p INT)
    trap _run_step_abort INT
    while kill -0 "$_RUN_STEP_PID" 2>/dev/null; do
      printf '\r  %b%s%b %s ' "$C" "${frames:i++%4:1}" "$N" "$title"
      sleep 0.2
    done
    wait "$_RUN_STEP_PID" || rc=$?
    eval "${prev_trap:-trap - INT}"
    _RUN_STEP_PID=""
    printf '\r\033[K'
  else
    ( "$@" ) </dev/null >>"$INSTALL_LOG" 2>&1 || rc=$?
  fi

  if (( rc == 0 )); then
    printf '  %b√%b %s %b(%dс)%b\n' "$G" "$N" "$title" "$D" "$((SECONDS - t0))" "$N"
    return 0
  fi
  printf '  %b×%b %s %b(код %d, %dс)%b\n' "$R" "$N" "$title" "$D" "$rc" "$((SECONDS - t0))" "$N"
  warn "Последние строки шага:"
  tail -n "+$((from + 2))" "$INSTALL_LOG" 2>/dev/null | tail -n 15 | sed 's/^/    /'
  info "Полный вывод: $INSTALL_LOG"
  return "$rc"
}

# ── Временные файлы ───────────────────────────────────────
_TMP_PATHS=()

# mktmp VAR [-d] — временный файл/каталог, удаляется при выходе.
mktmp() {  # ПЕРЕМЕННАЯ [-d | .расширение]
  local __var="$1" __p
  case "${2:-}" in
    -d) __p=$(mktemp -d /tmp/awg2.XXXXXX) ;;
    .*) __p=$(mktemp --suffix="$2" /tmp/awg2.XXXXXX) ;;
    *)  __p=$(mktemp /tmp/awg2.XXXXXX) ;;
  esac || return 1
  _TMP_PATHS+=("$__p")
  printf -v "$__var" '%s' "$__p"
}

_cleanup_tmp() {
  local p
  for p in ${_TMP_PATHS[@]+"${_TMP_PATHS[@]}"}; do rm -rf "$p" 2>/dev/null || true; done
  _TMP_PATHS=()
}

# Атомарная запись: stdin → файл с правами $2 (по умолчанию 600).
write_file() {
  local path="$1" mode="${2:-600}" tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "$(dirname "$path")/.awg2.XXXXXX") || return 1
  if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod "$mode" "$tmp" && mv -f "$tmp" "$path"
}

# ── Прочее ────────────────────────────────────────────────
# Равномерное целое в [lo, hi]. SRANDOM (bash 5.1+) — 32 бита из getrandom;
# отбраковка убирает перекос остатка от деления на больших диапазонах (H1-H4).
rand_range() {
  local lo="$1" hi="$2" span lim r
  (( hi <= lo )) && { echo "$lo"; return 0; }
  span=$(( hi - lo + 1 ))
  lim=$(( 4294967296 - 4294967296 % span ))
  while r=$SRANDOM; (( r >= lim )); do :; done
  echo $(( lo + r % span ))
}

rand_name() {  # xkqve_73
  local a='abcdefghijklmnopqrstuvwxyz' s='' i
  for i in 1 2 3 4 5; do s+="${a:$(rand_range 0 25):1}"; done
  printf '%s_%02d\n' "$s" "$(rand_range 0 99)"
}

fmt_duration() {  # 5с / 3м12с / 2ч15м / 3д4ч
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "?"; return; }
  if   (( s < 60 ));    then echo "${s}с"
  elif (( s < 3600 ));  then echo "$((s/60))м$((s%60))с"
  elif (( s < 86400 )); then echo "$((s/3600))ч$(((s%3600)/60))м"
  else echo "$((s/86400))д$(((s%86400)/3600))ч"; fi
}

fmt_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  if   (( b >= 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.2f ГБ", b/1073741824}'
  elif (( b >= 1048576 ));    then awk -v b="$b" 'BEGIN{printf "%.1f МБ", b/1048576}'
  else echo "$(( (b + 1023) / 1024 )) КБ"; fi
}

# Версия "v0.8.35" → сравнимое число. Результат начинается с нуля, поэтому
# сравнивать только через 10#.
ver_num() { echo "${1#v}" | awk -F'[.-]' '{printf "%d%03d%03d\n", $1, $2, $3}'; }

# Встроенный Python читается с дескриптора: код не упирается в предел длины
# аргумента (128 КБ), а stdin остаётся свободным для данных.
# Помощник один раз на версию кладётся файлом в $STATE_DIR/py — Python
# кэширует его байткод рядом, и запуск не компилирует ~90 КБ кода заново
# (а awg2 api зовёт помощник дважды на вызов). Нет прав или места — как
# раньше, с дескриптора. В служебных скриптах (emit_script) _py_mod нет.
_PY_MOD=""
_py_mod() {
  local d="$STATE_DIR/py/$_PY_HELPER_SUM" tmp
  [[ -n "$_PY_MOD" ]] && return 0
  [[ -n "${_PY_HELPER_SUM:-}" ]] || return 1
  if [[ ! -f "$d/awg2helper.py" ]]; then
    mkdir -p "$d" 2>/dev/null && chmod 700 "$STATE_DIR/py" "$d" 2>/dev/null || return 1
    tmp="$d/.awg2helper.$$"
    printf '%s' "$_PY_HELPER" > "$tmp" 2>/dev/null && mv -f "$tmp" "$d/awg2helper.py" || { rm -f "$tmp"; return 1; }
    find "$STATE_DIR/py" -mindepth 1 -maxdepth 1 -type d ! -name "$_PY_HELPER_SUM" -exec rm -rf {} + 2>/dev/null
  fi
  _PY_MOD="$d"
}
py() {
  if declare -F _py_mod >/dev/null && _py_mod; then
    python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv.pop(1)); import awg2helper; awg2helper.main()' "$_PY_MOD" "$@"
  else
    python3 /dev/fd/3 "$@" 3<<< "$_PY_HELPER"
  fi
}
cps() { python3 /dev/fd/3 "$@" 3<<< "$_CPS_GENERATOR"; }

# Самостоятельный служебный скрипт из функций и переменных awg2.
# Нужен для всего, что systemd вызывает без awg2: при загрузке, из таймеров
# и хуков. Логика остаётся в одном месте, а скрипт работает, даже если awg2
# удалён или заменён другой версией.
#   emit_script ПУТЬ "ТОЧКА_ВХОДА" имя...  (имя — функция или переменная)
emit_script() {
  local path="$1" entry="$2" item
  shift 2
  {
    printf '#!/bin/bash\n# Сгенерировано awg2 %s. Не редактировать: файл перезаписывается.\nset -u\n' "$VERSION"
    for item in "$@"; do
      if declare -F "$item" >/dev/null; then declare -f "$item"
      else declare -p "$item"; fi
    done
    printf '%s\n' "$entry"
  } | write_file "$path" 755
}

# ═════ const ═════
# Пути и константы. Все имена файлов совпадают с прежними версиями awg2:
# новая версия подхватывает уже работающий сервер без миграции.

SCRIPT_PATH="/usr/local/bin/awg2"
STATE_DIR="/var/lib/awg2"
LOG_FILE="/var/log/awg-manager.log"
INSTALL_LOG="/var/log/awg2-install.log"

# ── AmneziaWG ─────────────────────────────────────────────
AWG_DIR="/etc/amnezia/amneziawg"
SERVER_CONF="$AWG_DIR/awg0.conf"
AWG_IF="awg0"
CLIENT_DIR="/root"                 # клиенты: /root/<имя>_awg2.conf | _awg3.conf
AUTOSTART_DROPIN="/etc/systemd/system/awg-quick@awg0.service.d"
MODULES_LOAD_FILE="/etc/modules-load.d/amneziawg.conf"
SYSCTL_FORWARD_FILE="/etc/sysctl.d/99-awg2.conf"

# Компоненты собираются из исходников апстрима через git + DKMS.
MOD_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
MOD_NAME="amneziawg"
MOD_DKMS_VER="1.0.0"               # апстрим держит 1.0.0 во всех тегах
MOD_SRC_DIR="/usr/src/${MOD_NAME}-${MOD_DKMS_VER}"
MOD_TAG_FILE="$STATE_DIR/module_tag"
TOOLS_TAG_FILE="$STATE_DIR/tools_tag"
MOD_BACKUP_DIR="/var/backups/awg-mod"
MOD_LOG="/var/log/awg-mod-update.log"
MOD_FALLBACK_TAG="v3.1.20260906"
TOOLS_FALLBACK_TAG="v3.1.20260812"
UPSTREAM_CACHE="$STATE_DIR/upstream_tags"
COUNTRY_CACHE="$STATE_DIR/country"     # «NL 1791500000»: страна сервера (флаг в шапке панели)
UPSTREAM_TTL=21600

# ── Обновление скрипта ────────────────────────────────────
UPDATE_REPO_STABLE="pumbaX/awg-multi-script"
UPDATE_REPO_BETA="genaRijoff/awg-multi-script"
UPDATE_CHANNEL_FILE="$STATE_DIR/channel"
# Проверка версии в канале (4 КБ файла): бета выходит по нескольку раз в день —
# раз в 6 часов уведомление бота о новой версии запаздывало на полдня
UPDATE_CHECK_TTL=3600 UPDATE_CHECK_TTL_BETA=1200
# Подпись сборок: awg2.sh.sig рядом с awg2.sh (ssh-keygen -Y sign, ставит
# GitHub Actions). Ключ релизов вшит сюда — подменить сборку на зеркале
# или по пути без закрытого ключа нельзя. Сборки старше UPDATE_SIG_SINCE
# выходили без подписи.
UPDATE_SIG_NS="awg-toolza"
UPDATE_SIGNER="awg-toolza-release"
UPDATE_SIG_SINCE="v1.2.0"
UPDATE_SIGNERS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMSoLr9/XltV/DHvw8sMTsKqMkxxGQRezmGJgBKczeAk"   # awg-toolza-release, 2026-10
)

# ── Бэкапы ────────────────────────────────────────────────
# В домашнем каталоге того, кто запустил sudo: так было всегда, и уже
# сделанные бэкапы лежат именно там.
_real_home() {
  local u home=""
  u=$(logname 2>/dev/null || echo "${SUDO_USER:-}")
  [[ -n "$u" ]] && home=$(getent passwd "$u" | cut -d: -f6)
  echo "${home:-/root}"
}
BACKUP_DIR="$(_real_home)/awg_backup"

# ── Туннели ───────────────────────────────────────────────
# Номера таблиц маршрутизации — общие для всех версий awg2.
T2S_TABLE=100
WARP_TABLE=200
XRAY_TABLE=201
EXITS_TABLE=202
EXITS_TABLE_BASE=210
EXITS_TABLE_MAX=249

WARP_IF="warp0"
WARP_DIR="/etc/wgcf"
WARP_CONF="/etc/wireguard/warp0.conf"
WARP_ACCOUNT="$WARP_DIR/wgcf-account.toml"
WARP_PROFILE="$WARP_DIR/wgcf-profile.conf"
WARP_STATE="$WARP_DIR/state"
WARP_PEERS="$WARP_DIR/peers.list"
WARP_BACKEND_FILE="/etc/awg-warp-backend"
WARP_AUTOSTART_SCRIPT="$WARP_DIR/warp-autostart.sh"
WARP_HEALTH_SCRIPT="/usr/local/bin/awg-warp-healthcheck.sh"
WARP_HEALTH_LOG="/var/log/awg-warp-health.log"
WARPSCOUT_BIN="/usr/local/bin/warpscout"
WARPSCOUT_DIR="/etc/warpscout"
WARPSCOUT_ACCOUNT="$WARPSCOUT_DIR/warpscout-account.json"
USQUE_DIR="/etc/usque"
USQUE_CONF="$USQUE_DIR/config.json"
USQUE_BIN="/usr/local/bin/usque"
USQUE_UP_HOOK="$USQUE_DIR/on-connect.sh"
USQUE_DOWN_HOOK="$USQUE_DIR/on-disconnect.sh"
USQUE_SYSCTL="/etc/sysctl.d/99-awg-usque.conf"
USQUE_LOG="/var/log/awg-usque.log"
USQUE_FALLBACK_VER="4.2.1"
WGCF_FALLBACK_VERS=(2.2.30 2.2.29 2.2.28)

DNS_PROXY_ADDR="127.0.2.1"
DNS_PROXY_PORT=53
DNS_PROXY_CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNS_PROXY_STATE="/etc/dnscrypt-proxy/awg.state"
DNS_PROXY_BACKUP_CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml.awg-backup"
DNS_PERSIST_SCRIPT="/usr/local/bin/awg-dns-persist.sh"
DNS_HEALTH_SCRIPT="/usr/local/bin/awg-dns-healthcheck.sh"
DNS_HEALTH_LOG="/var/log/awg-dns-health.log"
DNS_SYSCTL="/etc/sysctl.d/99-awg-dns.conf"

CASCADE_DIR="/etc/awg-cascade"
CASCADE_RULES="$CASCADE_DIR/rules.conf"
CASCADE_TAG="awg-cascade"
CASCADE_SCRIPT="/usr/local/bin/awg-cascade-apply.sh"
CASCADE_LOG="/var/log/awg-cascade.log"
CASCADE_UFW_BACKUP="$CASCADE_DIR/ufw-backup/ufw.default.original"

XRAY_DIR="/etc/xray"
XRAY_CONF="$XRAY_DIR/config.json"
XRAY_STATE="$XRAY_DIR/state"
XRAY_PEERS="$XRAY_DIR/peers.list"
XRAY_BIN="/usr/local/bin/xray"
XRAY_ASSET_DIR="/usr/local/bin"
XRAY_IF="xray0"
XRAY_TUN_ADDR="172.16.250.1/30"
XRAY_SOCKS="127.0.0.1:10808"
XRAY_UNIT="awg-xray.service"
XRAY_TUN_UNIT="awg-xray-tun.service"
XRAY_ROUTING_UNIT="awg-xray-routing.service"
XRAY_ROUTING_SCRIPT="/usr/local/bin/awg2-xray-routing.sh"
XRAY_RUGEO_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"

T2S_BIN="/usr/local/bin/tun2socks"
T2S_DIR="/etc/tun2socks"
T2S_CONF="$T2S_DIR/proxy.txt"
T2S_IF="tun0"
T2S_ADDR="10.30.1.1/24"
T2S_UNIT="awg-tun2socks.service"
T2S_ROUTING_SCRIPT="/usr/local/bin/awg2-tun2socks-routing.sh"

EXITS_DIR="$AWG_DIR"
EXITS_PEERS="$EXITS_DIR/exits_peers.list"
EXITS_STATE="$EXITS_DIR/exits_state"
EXITS_UNIT="awg-exits-routing.service"
EXITS_SCRIPT="/usr/local/bin/awg2-exits-routing.sh"

# ── Срок действия клиентов ────────────────────────────────
EXPIRE_BIN="/usr/local/bin/awg2-expire-check"
EXPIRE_STATE_DIR="/var/lib/awg2-expire"
EXPIRE_LOG="/var/log/awg2-expire.log"
EXPIRE_SUSPEND_IP="127.0.0.2/32"
TRAFFIC_DB="$STATE_DIR/traffic.json"          # трафик клиентов по дням (таймер сроков)

# ── WG + обфускатор ───────────────────────────────────────
WGOBF_VERSION="v1.6"
WGOBF_COMMIT="6440304054a27158b6d373545925880f0e51bafb"
WGOBF_REPO="https://github.com/ClusterM/wg-obfuscator.git"
WGOBF_IF="wgobf0"
WGOBF_DIR="/etc/awg-wgobf"
WGOBF_STATE="$WGOBF_DIR/state"
WGOBF_OBF_CONF="$WGOBF_DIR/obfuscator.conf"
WGOBF_WG_CONF="/etc/wireguard/${WGOBF_IF}.conf"
WGOBF_LIB="/usr/local/lib/awg2"
WGOBF_BIN="$WGOBF_LIB/wg-obfuscator"
WGOBF_FW="$WGOBF_LIB/wgobf-fw.sh"
WGOBF_UNIT="awg-wgobf.service"
WGOBF_CLIENTS="/root/wgobf"
WGOBF_TAG="awg-wgobf"
WGOBF_MTU=1380

# ── Telegram-бот ──────────────────────────────────────────
BOT_CONF="/etc/awg-bot.conf"
BOT_ADMINS="/var/lib/awg-bot/admins.json"   # приглашённые админы (ведёт бот)
BOT_DIR="/opt/awg-bot"
BOT_UNIT="awg-bot.service"
# Веб-панель (awgbot.web): конфиг с хешем пароля, журнал входов, самоподписанный сертификат
WEB_CONF="/etc/awg-web.conf"
WEB_UNIT="awg-web.service"
WEB_LOG="/var/log/awg-web.log"
WEB_DIR="/etc/awg-web"
BOT_PROXY_SCHEMES="http https socks4 socks5 socks5h iface"
WEBAPP_PORT_DEFAULT=8443                    # Mini App бота (WEBAPP_PORT в BOT_CONF)

# ── HTTPS-сертификат (Let's Encrypt через acme.sh) ───────
CERT_DIR="/etc/awg2/cert"
CERT_FULL="$CERT_DIR/fullchain.pem"
CERT_KEY="$CERT_DIR/key.pem"
CERT_STATE="$STATE_DIR/cert"                # kind=ip|domain, name=адрес
ACME_DIR="/usr/local/lib/awg2/acme.sh"      # код acme.sh
ACME_HOME="/var/lib/awg2/acme"              # аккаунт и сертификаты acme.sh
CERT_SERVICE="awg2-cert.service"
CERT_TIMER="awg2-cert.timer"
CERT_TAG="awg2-cert"

# ── Антисканер (сети сканеров РКН и госорганов — DROP новых входящих) ──
ANTISCAN_DIR="$STATE_DIR/antiscan"          # списки, исключения, состояние
ANTISCAN_CONF="$ANTISCAN_DIR/antiscan.conf" # ON, LISTS, UPDATED, ERROR, ENTRIES, ADDRS
ANTISCAN_ALLOW="$ANTISCAN_DIR/allow"        # исключения: адрес или подсеть в строке
ANTISCAN_SCRIPT="/usr/local/bin/awg2-antiscan"
ANTISCAN_LOG="/var/log/awg2-antiscan.log"
ANTISCAN_SET="awg2-antiscan" ANTISCAN_SET6="awg2-antiscan6" ANTISCAN_TAG="awg2-antiscan"
ANTISCAN_UNIT="awg2-antiscan.service" ANTISCAN_TIMER="awg2-antiscan-update.timer"
ANTISCAN_SRC="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
# Предел охвата одного списка. Настоящие: ~310 тыс. адресов IPv4 (самая широкая
# запись /19) и ~20 сетей /32 IPv6. Подменённый источник с тысячами /12 прошёл бы
# проверку записей, но закрыл бы почти весь IPv4 — такой список не принимается
ANTISCAN_MAX4=16777216 ANTISCAN_MAX6=4096   # 2^24 адресов IPv4; 2^12 сетей /32 IPv6 (записи /32 и шире)

# Интерфейсы, которые поднимает сам awg2: их адрес не может быть Endpoint
# клиента, и маршрут через них — не аплинк сервера.
OWN_IFACES=" awg0 warp0 xray0 tun0 wgcf wgobf0 "
# GitHub в части сетей режут — релизы качаются и через зеркала.
GH_MIRRORS=("" "https://ghproxy.net/" "https://gh-proxy.com/" "https://mirror.ghproxy.com/")

# ═════ sys ═════
# Система: проверка ОС, пакеты, systemd, sysctl, iptables, UFW.

# ── ОС ────────────────────────────────────────────────────
# Поддерживаются Ubuntu 24.04+ и Debian 12+. На них проверена сборка модуля
# через DKMS, наличие нужных заголовков ядра и поведение iptables (nft).
OS_ID="" OS_VER="" OS_CODENAME="" OS_LABEL=""

os_detect() {
  [[ -n "$OS_ID" ]] && return 0
  [[ -r /etc/os-release ]] || return 1
  # В os-release свой VERSION — читаем его только в подоболочке
  # shellcheck source=/dev/null
  IFS='|' read -r OS_ID OS_VER OS_CODENAME < <(. /etc/os-release \
    && printf '%s|%s|%s\n' "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}")
  OS_LABEL="${OS_ID^} ${OS_VER:-${OS_CODENAME:-?}}"
  [[ -n "$OS_CODENAME" && -n "$OS_VER" ]] && OS_LABEL+=" ($OS_CODENAME)"
  return 0
}

# 0 — поддерживается; 1 — нет (причина в stdout).
os_supported() {
  os_detect || { echo "не удалось прочитать /etc/os-release"; return 1; }
  local major="${OS_VER%%.*}"
  case "$OS_ID" in
    ubuntu)
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 24 )) && return 0
      echo "$OS_LABEL — нужна Ubuntu 24.04 или новее"
      ;;
    debian)
      # testing/sid живут без VERSION_ID — это заведомо новее 12
      [[ -z "$OS_VER" ]] && return 0
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 12 )) && return 0
      echo "$OS_LABEL — нужен Debian 12 или новее"
      ;;
    *) echo "$OS_LABEL — поддерживаются только Ubuntu 24.04+ и Debian 12+" ;;
  esac
  return 1
}

# ── Пакеты ────────────────────────────────────────────────
APT_LAST_OUTPUT=""

# apt-get install с одной повторной попыткой после обновления индексов:
# на давно не обновлявшемся сервере первый отказ — 404 на .deb из старого индекса.
apt_install() {
  local rc=0
  export DEBIAN_FRONTEND=noninteractive
  APT_LAST_OUTPUT=$(apt-get install -y -q "$@" 2>&1) || rc=$?
  (( rc == 0 )) && return 0
  apt-get update -q >/dev/null 2>&1 || true
  rc=0
  APT_LAST_OUTPUT=$(apt-get install -y -q "$@" 2>&1) || rc=$?
  return "$rc"
}

apt_errors() { printf '%s\n' "$APT_LAST_OUTPUT" | grep -E '^E:' | head -3 | sed 's/^/      /' || true; }

# need_cmds "команда:пакет" ... — ставит пакеты для отсутствующих команд.
need_cmds() {
  local pair missing=()
  for pair in "$@"; do
    command -v "${pair%%:*}" &>/dev/null || missing+=("${pair#*:}")
  done
  (( ${#missing[@]} == 0 )) && return 0
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  info "Ставлю пакеты: ${missing[*]}"
  if ! apt_install "${missing[@]}"; then
    err "Не удалось установить: ${missing[*]}"
    apt_errors
    return 1
  fi
}

# Пакеты заголовков для ядра $1 в порядке предпочтения. Точный пакет под
# работающее ядро есть почти всегда; мета-пакеты — на случай облачных ядер,
# у которых точный пакет уже убран из зеркала.
headers_candidates() {
  local k="$1" arch flavor
  echo "linux-headers-$k"
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  os_detect
  if [[ "$OS_ID" == debian ]]; then
    [[ "$k" == *-cloud-* ]] && echo "linux-headers-cloud-$arch"
    echo "linux-headers-$arch"
  else
    flavor="${k##*-}"
    [[ "$flavor" =~ ^[a-z]+$ ]] && echo "linux-headers-$flavor"
    echo "linux-headers-generic"
  fi
}

# Ставит заголовки под ядро $1. 0 — каталог build для него появился.
ensure_headers() {
  local k="$1" pkg
  [[ -d "/lib/modules/$k/build" ]] && return 0
  while read -r pkg; do
    apt_install "$pkg" >/dev/null 2>&1 || continue
    [[ -d "/lib/modules/$k/build" ]] && return 0
  done < <(headers_candidates "$k")
  [[ -d "/lib/modules/$k/build" ]]
}

# Установленные ядра (есть vmlinuz), от старых к новым — по версии, не по алфавиту.
installed_kernels() {
  local k
  for k in /lib/modules/*/; do
    k=${k%/}; k=${k##*/}
    [[ -e "/boot/vmlinuz-$k" ]] && echo "$k"
  done | sort -V
}

secure_boot_on() {
  command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled
}

# ── systemd ───────────────────────────────────────────────
unit_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

# write_unit ИМЯ < содержимое — пишет /etc/systemd/system/ИМЯ и перечитывает.
write_unit() {
  write_file "/etc/systemd/system/$1" 644 && systemctl daemon-reload
}

# Таймер в состоянии «active (elapsed)» больше не сработает никогда, хотя
# is-active отвечает «active». Так глох таймер сроков и лимитов (v1.2.0-1.2.2):
# с Persistent=true systemd при старте таймера берёт время прошлого запуска
# из метки в /var/lib/systemd/timers, считает OnBootSec прошедшим, а
# OnUnitActiveSec отсчитывать не от чего — служба после переустановки ещё не
# запускалась. Такой таймер — перезапустить без метки: сработает сразу,
# дальше по расписанию.
timer_heal() {
  local u st
  for u in "$@"; do
    st=$(systemctl show -p SubState --value "$u" 2>/dev/null)
    [[ "$st" == waiting || "$st" == running ]] && continue
    rm -f "/var/lib/systemd/timers/stamp-$u"
    systemctl restart "$u" &>/dev/null || true
  done
}

remove_unit() {
  local u
  for u in "$@"; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u" "/var/lib/systemd/timers/stamp-$u"
  done
  systemctl daemon-reload 2>/dev/null || true
}

# ── sysctl ────────────────────────────────────────────────
# net.ipv4.ip_forward=1 сейчас и после перезагрузки. В Ubuntu 26.04 нет
# /etc/sysctl.conf — пишем drop-in, но уважаем строку, если она уже там.
ip_forward_enable() {
  local re='^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1'
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  grep -qsE "$re" /etc/sysctl.conf /etc/sysctl.d/*.conf && return 0
  echo "net.ipv4.ip_forward=1" | write_file "$SYSCTL_FORWARD_FILE" 644
}

rp_filter_loose() {
  local dev
  for dev in "$@"; do sysctl -qw "net.ipv4.conf.${dev}.rp_filter=2" >/dev/null 2>&1 || true; done
}

# ── iptables ──────────────────────────────────────────────
# ipt_add [-t табл] ЦЕПЬ правило... — добавить в конец, если такого нет.
ipt_add() {
  local t=filter
  [[ "$1" == -t ]] && { t="$2"; shift 2; }
  local chain="$1"; shift
  iptables -t "$t" -C "$chain" "$@" 2>/dev/null || iptables -t "$t" -A "$chain" "$@"
}

# ipt_ins — то же, но вставить первым (для ACCEPT перед чужими DROP).
ipt_ins() {
  local t=filter
  [[ "$1" == -t ]] && { t="$2"; shift 2; }
  local chain="$1"; shift
  iptables -t "$t" -C "$chain" "$@" 2>/dev/null || iptables -t "$t" -I "$chain" 1 "$@"
}

# ipt_del — удалить все копии правила.
ipt_del() {
  local t=filter guard=0
  [[ "$1" == -t ]] && { t="$2"; shift 2; }
  local chain="$1"; shift
  while (( guard++ < 64 )) && iptables -t "$t" -D "$chain" "$@" 2>/dev/null; do :; done
  return 0
}

# Удалить все правила таблицы с комментарием, начинающимся с $2.
# iptables-save выдаёт правило одной строкой (iptables -S на nft-бэкенде
# длинные правила переносит). Комментарий с символами вне [A-Za-z0-9_-]
# (например «awg-cascade:udp-443») он берёт в кавычки — поэтому строку
# разбирает xargs, который кавычки понимает, а не word splitting.
ipt_del_tagged() { ipt_del_grep "$1" "--comment \"?${2}"; }

# Удалить все правила таблицы $1, строка которых в iptables-save
# совпадает с расширенным регулярным выражением $2.
ipt_del_grep() {
  local t="$1" re="$2" rule
  while IFS= read -r rule; do
    printf '%s\n' "${rule/#-A /-D }" | xargs iptables -t "$t" 2>/dev/null || true
  done < <(iptables-save -t "$t" 2>/dev/null | grep -E -- "^-A .*${re}" || true)
}

# ── UFW ───────────────────────────────────────────────────
ufw_active() { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]*active'; }

ufw_allow() {  # порт/протокол комментарий
  ufw_active || return 0
  ufw allow "$1" comment "$2" >/dev/null 2>&1
}

# Снять правила UFW с комментарием ровно $1. ufw_delete_matching ищет подстроку —
# «awg-web» (веб-панель) задевал и «awg-webapp» (порт Mini App).
ufw_delete_comment() {
  command -v ufw &>/dev/null || return 0
  local n guard=0
  while (( guard++ < 64 )); do
    n=$(ufw status numbered 2>/dev/null | awk -v c="$1" '{
          s = $0; sub(/[ \t]+$/, "", s); i = index(s, "# ")
          if (i && substr(s, i + 2) == c && match(s, /^\[ *[0-9]+ *\]/)) {
            n = substr(s, 2, RLENGTH - 2); gsub(/ /, "", n); print n; exit } }')
    [[ -n "$n" ]] || break
    ufw --force delete "$n" >/dev/null 2>&1 || break
  done
}

# Снять все правила UFW, в комментарии которых есть $1.
ufw_delete_matching() {
  command -v ufw &>/dev/null || return 0
  local n guard=0
  while (( guard++ < 64 )); do
    n=$(ufw status numbered 2>/dev/null | grep -F -- "$1" | head -1 | grep -oE '^\[ *[0-9]+ *\]' | tr -d '[] ')
    [[ -n "$n" ]] || break
    ufw --force delete "$n" >/dev/null 2>&1 || break
  done
}

# ═════ net ═════
# Сеть: проверка адресов, аплинк, публичный IP, порты, домены.

# Октеты без ведущих нулей, как у портов и масок: «010.0.0.1» iptables
# отвергает, а ip_is_private (по тексту) счёл бы его публичным.
valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
}

# DNS для клиентов: IPv4 через запятую (и/или пробел), каждый — настоящий адрес:
# «999.999.999.999» иначе уходил в конфиги всех клиентов
valid_dns_list() {  # «1.1.1.1, 1.0.0.1»
  local -a a
  local d
  # Одна строка из цифр, точек, запятых и пробелов: перевод строки дописал бы в конфиг
  # клиента свои строки, а read ниже проверяет только первую
  [[ "$1" =~ ^[0-9.,\ ]+$ ]] || return 1
  IFS=', ' read -ra a <<< "$1"
  (( ${#a[@]} )) || return 1
  for d in "${a[@]}"; do valid_ip "$d" || return 1; done
}

valid_cidr() {
  [[ "$1" == */* ]] || return 1
  local mask="${1#*/}"
  valid_ip "${1%/*}" && [[ "$mask" =~ ^(0|[1-9][0-9]?)$ ]] && (( mask <= 32 ))
}

# Без ведущих нулей: «0080» и «/08» — не восьмеричные числа и не ошибка
# арифметики, а отказ; иначе такое значение легло бы в конфиги как есть.
valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }

# Имя хоста (не IP): метки из букв, цифр и дефисов, минимум одна точка.
valid_domain() {
  local d="$1"
  [[ -n "$d" && ${#d} -le 253 ]] || return 1
  # Одни цифры и точки — это адрес, а не домен: и «010.0.0.1», который
  # valid_ip (без ведущих нулей) не принимает, тоже
  [[ "$d" =~ ^[0-9.]+$ ]] && return 1
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# 10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, 100.64/10 (CGNAT у хостеров).
ip_is_private() {
  local ip="$1"
  [[ "$ip" =~ ^10\. || "$ip" =~ ^192\.168\. || "$ip" =~ ^127\. || "$ip" =~ ^169\.254\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  return 1
}

# Первый интерфейс маршрута по умолчанию, не считая наших туннелей.
uplink_iface() {
  local dev
  while read -r dev; do
    [[ -n "$dev" && "$OWN_IFACES" != *" $dev "* ]] && { echo "$dev"; return 0; }
  done < <(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  return 1
}

# Публичный IPv4 сервера. Сначала адрес самого аплинка; если он приватный
# (сервер за NAT) — спрашиваем внешний сервис, прибив curl к аплинку: при
# поднятом туннеле иначе вернётся адрес туннеля.
public_ip() {
  local dev ip svc
  dev=$(uplink_iface || true)
  if [[ -n "$dev" ]]; then
    ip=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
    valid_ip "$ip" && ! ip_is_private "$ip" && { echo "$ip"; return 0; }
  fi
  for svc in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
    ip=$(curl -4 -fsS --max-time 5 ${dev:+--interface "$dev"} "$svc" 2>/dev/null || true)
    [[ -z "$ip" && -n "$dev" ]] && ip=$(curl -4 -fsS --max-time 5 "$svc" 2>/dev/null || true)
    valid_ip "$ip" && ! ip_is_private "$ip" && { echo "$ip"; return 0; }
  done
  # Сервер без выхода наружу: лучше показать локальный адрес, чем ничего
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
  valid_ip "$ip" && echo "$ip"
}

# Кэш на время одного запуска: адрес дёргается из шапки меню и генераторов.
_PUBLIC_IP=""
public_ip_cached() {
  [[ -n "$_PUBLIC_IP" ]] || _PUBLIC_IP=$(public_ip || true)
  echo "$_PUBLIC_IP"
}

# Страна сервера — флаг в шапке панели. Код страны IP сервера по геобазе
# Cloudflare (cdn-cgi/trace, строка «loc=»): без ключей и своих баз. В кэше
# на сутки (не узнали — повтор через час), обновляется в фоне: статус сеть не ждёт.
server_country() { awk 'NR == 1 && $1 ~ /^[A-Z][A-Z]$/ {print $1}' "$COUNTRY_CACHE" 2>/dev/null || true; }

country_refresh() {
  local loc="" ts
  command -v curl &>/dev/null || return 0
  loc=$(curl -s --max-time 6 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=//p' | head -1 || true)
  ts=$(date +%s)
  if ! [[ "$loc" =~ ^[A-Z]{2}$ && "$loc" != XX ]]; then
    # Не ответили: прежняя страна остаётся (флаг не пропадает на час из-за одного сбоя),
    # метка сдвинута так, чтобы повтор был через час, а не через сутки
    loc=$(server_country); ts=$(( ts - 86400 + 3600 ))
    [[ -n "$loc" ]] || { loc="-"; ts=$(date +%s); }
  fi
  printf '%s %s\n' "$loc" "$ts" | write_file "$COUNTRY_CACHE" 644
}

country_refresh_async() {
  local cc="" ts=0 ttl=86400
  [[ -n "${AWG_NO_UPDATE_CHECK:-}" ]] && return 0
  read -r cc ts 2>/dev/null < "$COUNTRY_CACHE" || true
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  [[ "$cc" =~ ^[A-Z]{2}$ ]] || ttl=3600
  (( $(date +%s) - ts < ttl )) && return 0
  ( country_refresh ) </dev/null >/dev/null 2>&1 3>&- 4>&- 8>&- &
  disown 2>/dev/null || true
}

udp_listening() { ss -lunH "sport = :$1" 2>/dev/null | grep -q .; }

# Занят ли UDP-порт кем угодно из известных: сокет, AWG, каскад, обфускатор.
udp_port_busy() {
  local p="$1"
  valid_port "$p" || return 0
  udp_listening "$p" && return 0
  [[ "$(conf_iface_get ListenPort)" == "$p" ]] && return 0
  grep -qE "^udp\|${p}\|" "$CASCADE_RULES" 2>/dev/null && return 0
  wgobf_owns_port "$p" && return 0
  return 1
}

random_free_udp_port() {
  local p i avoid="${1:-}"
  for i in {1..40}; do
    p=$(rand_range 30001 65535)
    [[ "$p" == "$avoid" ]] && continue
    udp_port_busy "$p" || { echo "$p"; return 0; }
  done
  return 1
}

# Сверяет A-запись домена с IP сервера. Не запрет, а предупреждение:
# DNS могли ещё не прописать.
domain_points_here() {
  local d="$1" ips srv
  ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z "$ips" ]]; then
    warn "Домен $d не резолвится с этого сервера"
    return 1
  fi
  srv=$(public_ip_cached)
  if [[ -n "$srv" && " $ips" != *" $srv "* ]]; then
    warn "Домен ведёт на ${ips% }, а IP сервера — $srv"
    info "Нужна прямая A-запись на IP сервера (без прокси Cloudflare)"
    return 1
  fi
  ok "Домен ведёт на этот сервер (${ips% })"
}

# Доходит ли трафик через SOCKS5. Настоящий запрос наружу: прокси может
# принимать соединения и никуда их не отправлять. В stdout — код ответа.
socks_probe() {
  local addr="$1" code opt
  command -v curl &>/dev/null || return 0
  for opt in --socks5-hostname --socks5; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$opt" "$addr" \
             http://cp.cloudflare.com/generate_204 2>/dev/null || true)
    [[ "$code" == 204 || "$code" == 200 ]] && return 0
  done
  echo "${code:-нет ответа}"
  return 1
}

# Внешний IP через интерфейс (проверка туннеля). Пусто — трафик не идёт.
iface_egress_ip() {
  curl -4 -fsS --max-time "${2:-6}" --interface "$1" https://api.ipify.org 2>/dev/null || true
}

# Все адреса и маршруты сервера — для выбора подсети без пересечений.
# Адреса туннелей добавлены явно: пока туннель выключен, их в системе нет.
taken_networks() {
  ip -4 -o addr show 2>/dev/null || true
  ip -4 route show table all 2>/dev/null || true
  conf_iface_get Address
  echo "$T2S_ADDR 172.16.0.0/24 $XRAY_TUN_ADDR"
}

# ═════ conf ═════
# Конфиг сервера awg0.conf и файлы клиентов.
#
# Шапка awg0.conf — служебные метки «# КЛЮЧ=значение» до секции [Interface].
# Их читает и Telegram-бот, поэтому имена меток не меняются:
#   AWG_PROFILE     lite | pro | standard (устаревший)
#   AWG_PROTO       2.0 | 3.0 | 3.1 (нет метки — 2.0)
#   AWG_OBF_LEVEL   1 — без I1-I5, 2 — только I1, 3 — полная цепочка
#   AWG_MIMICRY     профиль мимикрии или none
#   AWG_MIMICRY_DOMAIN, AWG_CPS_BUDGET, AWG_ENDPOINT
#   Region: ru | world (метка с двоеточием — из самых первых версий)

# Ключи параметров AmneziaWG, которые клиент обязан получить от сервера.
AWG_PARAM_KEYS_RE="(Jc|Jmin|Jmax|S[1-4]|H[1-4]|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)"
AWG3_KEYS_RE="(HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)"
AWG31_KEYS_RE="(RandomTrailers|DisableCookies)"

server_exists() { [[ -f "$SERVER_CONF" ]]; }
iface_up() { ip link show "$AWG_IF" &>/dev/null; }

# ── Метки шапки ───────────────────────────────────────────
conf_marker() {
  [[ -f "$SERVER_CONF" ]] || return 0
  awk -v k="$1" '
    /^\[/ { exit }
    index($0, "# " k "=") == 1 { print substr($0, length(k) + 4); exit }
  ' "$SERVER_CONF"
}

conf_marker_set() {
  local key="$1" val="$2"
  [[ -f "$SERVER_CONF" ]] || return 1
  conf_marker_del "$key"
  [[ -n "$val" ]] || return 0
  # Метка — в шапке перед первой секцией. «1a» ставила бы её на вторую
  # строку, а если файл начинается с [Interface] — внутрь секции, где
  # conf_marker её не видит.
  val="${val//\\/\\\\}"; val="${val//&/\\&}"; val="${val//|/\\|}"
  if grep -q '^\[' "$SERVER_CONF"; then
    sed -i "0,/^\[/s|^\[|# ${key}=${val}\n[|" "$SERVER_CONF"
  else
    echo "# ${key}=${val}" >> "$SERVER_CONF"
  fi
}

conf_marker_del() { [[ -f "$SERVER_CONF" ]] && sed -i "/^# ${1}=/d" "$SERVER_CONF"; return 0; }

# ── [Interface] ───────────────────────────────────────────
# conf_iface_get КЛЮЧ [файл] — значение из секции [Interface].
conf_iface_get() {
  local f="${2:-$SERVER_CONF}"
  [[ -f "$f" ]] || return 0
  awk -v k="$1" '
    /^\[Interface\]/ { s = 1; next }
    /^\[/ { s = 0 }
    s && $0 ~ "^" k "[ \t]*=" { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }
  ' "$f"
}

# Параметры AmneziaWG сервера построчно («Ключ = значение»).
server_params() {
  [[ -f "$SERVER_CONF" ]] || return 0
  sed -n '/^\[Peer\]/q; p' "$SERVER_CONF" | grep -E "^${AWG_PARAM_KEYS_RE}[[:space:]]*=" || true
}

# Версия протокола: метка, а без неё — по ключам (метку могли потерять правкой).
server_proto() {
  local p
  p=$(conf_marker AWG_PROTO)
  if [[ -z "$p" ]]; then
    if server_params | grep -qE "^${AWG31_KEYS_RE}"; then p=3.1
    elif server_params | grep -qE "^${AWG3_KEYS_RE}"; then p=3.0
    else p=2.0; fi
  fi
  echo "$p"
}

server_profile() { local p; p=$(conf_marker AWG_PROFILE); echo "${p:-pro}"; }

profile_label() {
  case "${1:-$(server_profile)}" in
    lite) echo "AmneziaVPN" ;;
    pro) echo "Мощный" ;;
    standard) echo "Standard (устаревший)" ;;
    *) echo "${1:-—}" ;;
  esac
}

server_region() {
  local r
  r=$(awk '/^\[/{exit} /^#[ \t]*Region:/{sub(/^#[ \t]*Region:[ \t]*/, ""); print; exit}' "$SERVER_CONF" 2>/dev/null)
  echo "${r:-world}"
}

server_port() { conf_iface_get ListenPort | tr -dc '0-9'; }

# Подсеть клиентов (10.x.y.0/24) из Address сервера — для любого префикса.
server_net() {
  local addr ip mask a b c d n m
  addr=$(conf_iface_get Address)
  addr="${addr%%,*}"
  valid_cidr "$addr" || return 1
  ip="${addr%/*}"; mask="${addr#*/}"
  IFS=. read -r a b c d <<< "$ip"
  n=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
  m=$(( 10#$mask == 0 ? 0 : (0xFFFFFFFF << (32 - 10#$mask)) & 0xFFFFFFFF ))
  n=$(( n & m ))
  echo "$(( n >> 24 & 255 )).$(( n >> 16 & 255 )).$(( n >> 8 & 255 )).$(( n & 255 ))/$mask"
}

# Endpoint для клиентов: домен из метки, иначе публичный IP.
endpoint_domain() {
  local d
  d=$(conf_marker AWG_ENDPOINT)
  valid_domain "$d" && echo "$d"
  return 0
}

endpoint_host() {
  local d
  d=$(endpoint_domain)
  if [[ -n "$d" ]]; then echo "$d"; else public_ip_cached; fi
}

# ── Клиенты ───────────────────────────────────────────────
# Имена: латиница, цифры, _ и -. Знак «=» запрещён — по нему служебные
# метки отличаются от имени клиента.
valid_client_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

client_suffix() { [[ "$(server_proto)" == 3* ]] && echo _awg3 || echo _awg2; }

# Путь к конфигу клиента: существующий файл любой версии, иначе новый.
client_file() {
  local f
  for f in "$CLIENT_DIR/${1}_awg3.conf" "$CLIENT_DIR/${1}_awg2.conf"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  echo "$CLIENT_DIR/${1}$(client_suffix).conf"
}

client_name_of() { local b="${1##*/}"; echo "${b%_awg[23].conf}"; }

client_files() {
  local f
  for f in "$CLIENT_DIR"/*_awg[23].conf; do [[ -f "$f" ]] && echo "$f"; done
  return 0
}

# Суффиксы файлов — под текущую версию протокола (после смены версии/рестора).
client_files_sync_suffix() {
  server_exists || return 0
  local want f t
  want=$(client_suffix)
  while read -r f; do
    [[ "$f" == *"${want}.conf" ]] && continue
    t="$CLIENT_DIR/$(client_name_of "$f")${want}.conf"
    [[ -e "$t" ]] || mv -f "$f" "$t"
  done < <(client_files)
}

# Клиенты сервера: строки «имя<TAB>ключ<TAB>AllowedIPs<TAB>expires<TAB>orig_ips<TAB>mimicry
# <TAB>limit<TAB>blocked_by».
clients_tsv() { server_exists || return 0; py peers "$SERVER_CONF"; }
# То же через «|»: табуляция для read — пробельный разделитель, подряд идущие
# табы схлопываются, и пустые колонки (срок, orig_ips) сдвигают соседние.
clients_psv() { clients_tsv | tr '\t' '|'; }

# «имя|ip» для меню туннелей — только клиенты с именем. У заблокированного
# AllowedIPs — адрес-заглушка, настоящий лежит в orig_ips: без этого
# peers_sync выкидывал его из списков WARP/Xray/exit, и после разблокировки
# клиент шёл мимо туннеля.
clients_name_ip() {
  local name aip orig _
  while IFS='|' read -r name _ aip _ orig _; do
    [[ -n "$orig" ]] && aip="$orig"
    [[ -n "$name" && -n "$aip" ]] || continue
    echo "${name}|${aip%%/*}"
  done < <(clients_psv)
}

client_exists() { clients_tsv | awk -F'\t' -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

peer_meta_get() {  # имя ключ
  clients_tsv | awk -F'\t' -v n="$1" -v k="$2" '
    BEGIN { col["expires"] = 4; col["orig_ips"] = 5; col["mimicry"] = 6; col["limit"] = 7; col["blocked_by"] = 8 }
    $1 == n { print $(col[k]); exit }'
}

peer_meta_set() { py meta-set "$SERVER_CONF" "$1" "$2" "${3:-}"; }

# Первый свободный адрес клиента в /24 сервера.
free_client_ip() {
  local net base i srv used
  net=$(server_net) || return 1
  base="${net%.*}"
  srv=$(conf_iface_get Address); srv="${srv%%/*}"
  used=" $(clients_tsv | awk -F'\t' '{print $3; print $5}' | tr ',' '\n' | sed 's#/.*##; s/ //g' | tr '\n' ' ') "
  for i in $(seq 2 254); do
    [[ "$base.$i" == "$srv" || "$used" == *" $base.$i "* ]] && continue
    echo "$base.$i/32"
    return 0
  done
  return 1
}

# Применить изменения пиров без обрыва остальных; при неудаче — перезапуск.
server_apply() {
  local stripped
  if stripped=$(awg-quick strip "$AWG_IF" 2>/dev/null) && [[ -n "$stripped" ]]; then
    awg syncconf "$AWG_IF" <(printf '%s\n' "$stripped") 2>/dev/null && return 0
  fi
  server_restart >/dev/null
}

server_restart() {
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  awg_up_diag
}

# ═════ module ═════
# Компоненты AmneziaWG: модуль ядра (git + DKMS) и amneziawg-tools.
#
# Проверка отвечает на вопросы, из-за которых сервер «молча не работает»:
# собран ли модуль под работающее и под самое новое ядро, та ли сборка
# сейчас в памяти, что лежит на диске, умеют ли модуль и tools AWG 3.1, есть
# ли в модуле фикс хвостов RandomTrailers у пакетов I1-I5, не вышла ли
# новая версия у апстрима.

# ── Состояние ─────────────────────────────────────────────
tools_version() {
  command -v awg &>/dev/null || return 0
  awg --version 2>/dev/null | grep -oE 'v[0-9][0-9A-Za-z.-]*' | head -1
}

mod_loaded() { [[ -d /sys/module/$MOD_NAME ]]; }

# Сборка модуля по исходникам в DKMS. version.h апстрим не бумпает (у тегов
# 20260812-20260906 он один и тот же), поэтому ориентируемся на изменения,
# которые принёс каждый тег.
mod_src_fingerprint() {
  local s="$MOD_SRC_DIR"
  [[ -d "$s" ]] || return 0
  if grep -qE 'bool[[:space:]]+trailer' "$s/socket.h" 2>/dev/null; then echo "v3.1.20260906"
  elif grep -q 'wg_peer_skb_randomize_padding_addition' "$s/peer.h" 2>/dev/null; then echo "v3.1.20260828"
  elif grep -q 'down_write(&p->lock)' "$s/header_protection.c" 2>/dev/null; then echo "v3.1.20260827"
  elif grep -q 'WGDEVICE_A_RANDOM_TRAILERS' "$s/uapi/wireguard.h" 2>/dev/null; then echo "v3.1.20260812"
  elif grep -q 'WGDEVICE_A_HEADER_PROTECTION_KEY' "$s/uapi/wireguard.h" 2>/dev/null; then echo "v3.0"
  else echo "v1.0"; fi
}

# Тег модуля: записанный при сборке, а без записи — «не старше» по исходникам.
mod_tag() {
  local t
  t=$(tr -d '[:space:]' 2>/dev/null < "$MOD_TAG_FILE" || true)
  if [[ -n "$t" ]]; then echo "$t"; return 0; fi
  t=$(mod_src_fingerprint)
  [[ -n "$t" ]] && echo "≈$t"
  return 0
}

tools_tag() {
  local t
  t=$(tr -d '[:space:]' 2>/dev/null < "$TOOLS_TAG_FILE" || true)
  echo "${t:-$(tools_version)}"
}

# Семейство протокола сборки: 3.1 / 3.0 / 2.0.
tag_family() {
  local t="${1#≈}"
  case "$t" in v3.1*|3.1*) echo 3.1 ;; v3.0*|3.0*) echo 3.0 ;; "") echo "" ;; *) echo 2.0 ;; esac
}

# Фикс хвостов RandomTrailers у I1-I5 (v3.1.20260906): 0 есть, 1 нет, 2 неизвестно.
mod_trailer_fix() {
  local f="$MOD_SRC_DIR/socket.h"
  [[ -f "$f" ]] || return 2
  grep -q 'wg_socket_send_buffer_to_peer' "$f" || return 2
  grep -qE 'bool[[:space:]]+trailer' "$f"
}

mod_built_for() { modinfo -k "$1" "$MOD_NAME" &>/dev/null; }

# В памяти не та сборка, что на диске: dkms install прошёл, а ядро работает
# со старым модулем. srcversion — хеш исходников, вшитый при сборке; плюс
# случай «исходники обновили, а пересобрать забыли».
mod_stale() {
  mod_loaded || return 1
  local ko live disk newest=0 t kt
  ko=$(modinfo -n "$MOD_NAME" 2>/dev/null) || return 1
  [[ -f "$ko" ]] || return 1
  live=$(cat "/sys/module/$MOD_NAME/srcversion" 2>/dev/null || true)
  disk=$(modinfo -F srcversion "$ko" 2>/dev/null || true)
  [[ -n "$live" && -n "$disk" && "$live" != "$disk" ]] && return 0
  for t in "$MOD_SRC_DIR"/*.[ch]; do
    [[ -f "$t" ]] || continue
    t=$(stat -c %Y "$t"); (( t > newest )) && newest=$t
  done
  kt=$(stat -c %Y "$ko" 2>/dev/null || echo 0)
  (( newest > 0 && kt > 0 && newest > kt ))
}

# Ядра, в которые сервер может загрузиться (работающее и новее), без
# собранного модуля — после перезагрузки в такое ядро awg0 не поднимется.
# Так бывает, когда apt поставил новое ядро, а DKMS не смог собрать под него
# модуль (Ubuntu 7.0.0-38) или заголовков к нему нет. Строки «ядро» или
# «ядро нет-заголовков»; пусто — всё в порядке.
kernel_gap() {
  local k running
  command -v dkms &>/dev/null && [[ -d "$MOD_SRC_DIR" ]] || return 0
  running=$(uname -r)
  for k in $(installed_kernels); do
    [[ "$(printf '%s\n%s\n' "$running" "$k" | sort -V | head -1)" == "$running" ]] || continue
    mod_built_for "$k" && continue
    [[ "$k" == "$running" ]] && mod_loaded && continue
    if [[ -d "/lib/modules/$k/build" ]]; then echo "$k"; else echo "$k нет-заголовков"; fi
  done
}

# Одной строкой для сводок: «6.8.0-150» или «6.8.0-150 (нет заголовков)».
# others — без работающего ядра (о нём говорит reboot_reason).
kernel_gap_line() {  # [others]
  local skip=""
  [[ "${1:-}" == others ]] && skip=$(uname -r)
  kernel_gap | awk -v r="$skip" 'r == "" || $1 != r' | sed 's/ нет-заголовков$/ (нет заголовков)/' | paste -sd, - | sed 's/,/, /g'
}

# Почему нужна перезагрузка (сервера или модуля). Пусто — не нужна.
reboot_reason() {
  local running newest
  running=$(uname -r)
  if ! mod_loaded; then
    mod_built_for "$running" && echo "модуль собран, но не загружен (поможет modprobe)" \
      || echo "модуль не собран под работающее ядро $running"
    return 0
  fi
  newest=$(installed_kernels | tail -1)
  if [[ -n "$newest" && "$newest" != "$running" ]]; then
    echo "работает ядро $running, установлено более новое $newest"
  elif mod_stale; then
    echo "в памяти прежняя сборка модуля — нужна перезагрузка модуля"
  elif [[ -f /run/reboot-required ]]; then
    echo "система просит перезагрузку после обновления пакетов"
  fi
}

# Чего не хватает для версии $1 (3.0 | 3.1) — по надёжным признакам:
# components — awg не установлен; tools — amneziawg-tools не знают её ключа
# (они сами разбирают конфиг); module — модуль на диске собран из тега без неё;
# check — признаков «нет» нет, решает проба (proto_supported).
proto_why() {  # версия
  local key=HeaderProtectionKey fam
  [[ "$1" == 3.1 ]] && key=RandomTrailers
  command -v awg &>/dev/null || { echo components; return 0; }
  grep -qa "$key" "$(command -v awg)" || { echo tools; return 0; }
  fam=$(tag_family "$(mod_tag)")
  if [[ -n "$fam" ]] && [[ "$fam" == 2.0 || ( "$1" == 3.1 && "$fam" == 3.0 ) ]]; then echo module; return 0; fi
  echo check
}

# Умеют ли компоненты версию протокола $1 (3.0 | 3.1).
# 0 — да, 1 — точно нет, 2 — подтвердить не удалось.
# «Нет» говорим только по надёжным признакам: tools не знают ключа (они сами
# разбирают конфиг) или модуль на диске собран из тега без поддержки.
_PROTO_PROBE=()
proto_supported() {
  local proto="$1" key val rc dev tmp
  [[ -n "${_PROTO_PROBE[${proto//./}]:-}" ]] && return "${_PROTO_PROBE[${proto//./}]}"
  case "$proto" in
    3.1) key=RandomTrailers; val=on ;;
    *)   key=HeaderProtectionKey; val="" ;;
  esac
  rc=2
  if [[ "$(proto_why "$proto")" != check ]]; then
    rc=1
  elif awg showconf "$AWG_IF" 2>/dev/null | grep -q "^$key"; then
    rc=0
  else
    # Проба, прерванная раньше (тайм-аут бота, kill), оставляла интерфейс
    for dev in $(ip -o link show type amneziawg 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}'); do
      [[ "$dev" =~ ^awgprb([0-9]+)$ ]] && ! kill -0 "${BASH_REMATCH[1]}" 2>/dev/null \
        && ip link del dev "$dev" &>/dev/null
    done
    dev="awgprb$BASHPID"
    if ip link add dev "$dev" type amneziawg 2>/dev/null; then
      tmp=$(mktemp)
      [[ -n "$val" ]] || val=$(awg genkey)
      printf '[Interface]\nPrivateKey = %s\n%s = %s\n' "$(awg genkey)" "$key" "$val" > "$tmp"
      awg setconf "$dev" "$tmp" &>/dev/null && rc=0
      rm -f "$tmp"
      ip link del dev "$dev" &>/dev/null || true
    fi
  fi
  _PROTO_PROBE[${proto//./}]=$rc
  return "$rc"
}

# ── Версии апстрима ───────────────────────────────────────
# git ls-remote, а не API GitHub: у API лимит 60 запросов в час на IP, и на
# общих IP хостеров он исчерпан постоянно.
upstream_tags() {  # repo_url → теги от новых к старым
  command -v git &>/dev/null || return 0
  GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote --tags --refs "$1" 2>/dev/null \
    | sed -n 's#.*refs/tags/##p' | grep -E '^v[0-9]' | sort -Vr || true
}

upstream_refresh() {
  local m t
  m=$(upstream_tags "$MOD_REPO" | head -1)
  t=$(upstream_tags "$TOOLS_REPO" | head -1)
  [[ -n "$m" || -n "$t" ]] || return 1
  mkdir -p "$STATE_DIR"
  printf 'mod=%s\ntools=%s\nts=%s\n' "$m" "$t" "$(date +%s)" > "$UPSTREAM_CACHE"
}

upstream_refresh_async() {
  local ts=0
  [[ -n "${AWG_NO_UPDATE_CHECK:-}" ]] && return 0
  ts=$(sed -n 's/^ts=//p' "$UPSTREAM_CACHE" 2>/dev/null || echo 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  (( $(date +%s) - ts < UPSTREAM_TTL )) && return 0
  # Дескрипторы 3/4/8 открыты у awg2 api: фоновый процесс не должен держать
  # пайп ответа — иначе вызывающий ждал бы его до конца проверки
  ( upstream_refresh ) </dev/null >/dev/null 2>&1 3>&- 4>&- 8>&- &
  disown 2>/dev/null || true
}

upstream_latest() { sed -n "s/^$1=//p" "$UPSTREAM_CACHE" 2>/dev/null | head -1; }

tag_newer() {  # $1 новее $2?
  [[ -n "$1" && -n "$2" && "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# Доступное обновление модуля (тег) или пусто.
mod_update_available() {
  local cur latest
  latest=$(upstream_latest mod)
  cur=$(mod_tag); cur="${cur#≈}"
  [[ -n "$cur" && -n "$latest" ]] && tag_newer "$latest" "$cur" && echo "$latest"
  return 0
}

tools_update_available() {
  local cur latest
  latest=$(upstream_latest tools); cur=$(tools_tag)
  [[ -n "$cur" && -n "$latest" ]] && tag_newer "$latest" "$cur" && echo "$latest"
  return 0
}

# Строка состояния для шапки меню.
components_summary() {
  local tag upd reason gap
  command -v awg &>/dev/null || { echo -e "${R}не установлены${N} ${D}— Сервер → Установить компоненты${N}"; return; }
  tag=$(mod_tag)
  reason=$(reboot_reason)
  upd=$(mod_update_available)
  # Работающее ядро без модуля — это reboot_reason; но и оно не должно
  # прятать более новое ядро без модуля (раньше — проверка по префиксу)
  gap=$(kernel_gap_line others)
  if [[ -n "$gap" ]]; then
    echo -e "${R}${tag:-?} ▲ ядро $gap без модуля AWG${N} ${D}— после перезагрузки VPN не поднимется:${N}"
    echo -e "               ${D}Сервер → Модуль ядра → 5) Пересобрать${N}"
    [[ -n "$reason" ]] && echo -e "               ${Y}▲ ${reason}${N}"
  elif [[ -n "$reason" ]]; then
    echo -e "${Y}${tag:-?} ▲ ${reason}${N}"
  elif [[ -n "$upd" ]]; then
    echo -e "${W}${tag}${N} ${G}⬆ есть $upd${N} ${D}— Сервер → Модуль ядра${N}"
  else
    echo -e "${W}${tag:-?}${N} ${G}✓${N}"
  fi
}

# ── Отчёт ─────────────────────────────────────────────────
components_report() {
  local k running newest tag tt fam upd tupd s
  running=$(uname -r)
  newest=$(installed_kernels | tail -1)
  tag=$(mod_tag); tt=$(tools_tag); fam=$(tag_family "$tag")
  upd=$(mod_update_available); tupd=$(tools_update_available)

  hdr "Модуль ядра и amneziawg-tools"
  echo -e "  Ядро           : ${W}$running${N}"
  if [[ -n "$tt" ]]; then
    echo -e "  amneziawg-tools: ${W}$tt${N}${tupd:+  ${G}⬆ доступна $tupd${N}}"
  else
    echo -e "  amneziawg-tools: ${R}не установлены${N}"
  fi
  if [[ -d "$MOD_SRC_DIR" ]]; then
    s="$tag"; [[ "$tag" == ≈* ]] && s="${tag#≈} ${D}(по исходникам, не старше)${N}"
    echo -e "  Модуль (диск)  : ${W}$s${N}${upd:+  ${G}⬆ доступен $upd${N}}"
  else
    echo -e "  Модуль (диск)  : ${R}исходников в DKMS нет${N}"
  fi

  if ! mod_loaded; then
    echo -e "  Модуль (память): ${R}не загружен${N}"
  elif mod_stale; then
    echo -e "  Модуль (память): ${Y}прежняя сборка — нужна перезагрузка модуля${N}"
  else
    echo -e "  Модуль (память): ${G}загружен, совпадает с диском${N}"
  fi

  for k in $(installed_kernels); do
    s="${R}✗ не собран${N}"
    [[ -n "$(kernel_gap | awk -v k="$k" '$1 == k')" ]] && s="${R}✗ не собран — пункт 5${N}"
    mod_built_for "$k" && s="${G}✓ собран${N}"
    [[ -d "/lib/modules/$k/build" ]] || s+=" ${D}(нет заголовков)${N}"
    [[ "$k" == "$running" ]] && s+=" ${D}← работает${N}"
    [[ "$k" == "$newest" && "$k" != "$running" ]] && s+=" ${Y}← загрузится после ребута${N}"
    echo -e "  DKMS $k: $s"
  done

  if proto_supported 3.1; then s="${G}поддерживается${N}"
  else
    case $? in
      1) s="${R}нет${N} ${D}— нужны модуль и tools v3.1${N}" ;;
      *) s="${D}не подтверждено${N}" ;;
    esac
  fi
  echo -e "  AWG 3.1        : $s"
  if [[ "$fam" == 3.1 ]]; then
    if mod_trailer_fix; then s="${G}есть${N}"; else s="${Y}нет — хвосты портят I1-I5, обнови модуль${N}"; fi
    echo -e "  Фикс I1-I5     : $s"
  fi
  secure_boot_on && echo -e "  Secure Boot    : ${Y}включён — неподписанный DKMS-модуль не загрузится${N}"
  if grep -qs "^$MOD_NAME" "$MODULES_LOAD_FILE"; then s="${G}настроена${N}"; else s="${Y}нет${N}"; fi
  echo -e "  Автозагрузка   : $s"
  s=$(reboot_reason)
  [[ -n "$s" ]] && { echo ""; warn "$s"; }
  return 0
}

# ── Сборка ────────────────────────────────────────────────
mod_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$MOD_LOG" 2>/dev/null || true; }

components_deps() {
  need_cmds git:git make:build-essential gcc:build-essential dkms:dkms pkg-config:pkg-config \
    || return 1
  dpkg -s libmnl-dev &>/dev/null || apt_install libmnl-dev >/dev/null 2>&1 || { err "Не ставится libmnl-dev"; return 1; }
}

# Клон тега в каталог $2 (с проверкой, что тег существует).
_git_clone_tag() {
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$1" "$3" "$2"
}

# Ядро для пробной сборки: работающее, а без его заголовков — самое новое
# из тех, для которых заголовки есть.
build_kernel() {
  local k
  [[ -d "/lib/modules/$(uname -r)/build" ]] && { uname -r; return 0; }
  for k in $(installed_kernels | sort -Vr); do
    [[ -d "/lib/modules/$k/build" ]] && { echo "$k"; return 0; }
  done
  return 1
}

# Пробная сборка в копии исходников, до того, как трогать установленную
# версию. В копии: dkms-install забирает все *.c каталога, и сгенерированный
# сборкой amneziawg.mod.c уехал бы в DKMS.
_mod_trial_build() { cp -a "$1" "$1.trial" && make -C "$1.trial" KERNELRELEASE="$2" -j"$(nproc)"; }

# Правки исходника модуля под ядра дистрибутивов (py mod-compat-patch): в
# Ubuntu 7.0.0-38 апстрим без неё не собирается. Нет нужного места в теге —
# исходник не трогается.
_mod_src_patch() {  # каталог src тега или исходник в DKMS
  [[ -d "$1" ]] || return 0
  [[ "$(py mod-compat-patch "$1" 2>/dev/null)" == patched ]] && mod_log "исходник $1: правка udp_tunnel для ядер дистрибутивов"
  return 0
}

# Сборка под все ядра с заголовками. Ядро, поставленное раньше регистрации
# модуля в DKMS, автосборку не получит — после перезагрузки в него awg0 не
# поднялся бы. Провал под работающим ядром — ошибка, под остальными —
# предупреждение в журнале шага.
_mod_dkms_install_all() {
  local k running built=0 rc=0
  running=$(uname -r)
  _mod_src_patch "$MOD_SRC_DIR"
  dkms add -m "$MOD_NAME" -v "$MOD_DKMS_VER" >/dev/null 2>&1 || true
  for k in $(installed_kernels); do
    [[ -d "/lib/modules/$k/build" ]] || continue
    if dkms install -m "$MOD_NAME" -v "$MOD_DKMS_VER" -k "$k" --force; then
      built=$((built + 1))
    else
      echo "!!! сборка под $k не удалась"
      [[ "$k" == "$running" ]] && rc=1
    fi
  done
  (( built > 0 )) || rc=1
  return "$rc"
}

mod_backup_src() {  # → путь к архиву
  [[ -d "$MOD_SRC_DIR" ]] || return 0
  mkdir -p "$MOD_BACKUP_DIR" || return 1
  local t f
  t=$(mod_tag); t="${t#≈}"
  f="$MOD_BACKUP_DIR/src-${t:-unknown}-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar czf "$f" -C /usr/src "${MOD_NAME}-${MOD_DKMS_VER}" && echo "$f"
}

mod_restore_src() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  dkms remove -m "$MOD_NAME" -v "$MOD_DKMS_VER" --all >/dev/null 2>&1 || true
  rm -rf "$MOD_SRC_DIR"
  tar xzf "$f" -C /usr/src || return 1
  _mod_dkms_install_all
}

# Ставит модуль из тега $1. Старая сборка не трогается, пока новая не
# собралась пробно; при сбое установки — возврат из резервной копии.
mod_install_tag() {
  local tag="$1" tmp backup="" kver
  mktmp tmp -d || return 1
  mod_log "=== модуль $tag (ядро $(uname -r), было: $(mod_tag))"

  run_step "Загрузка модуля $tag" _git_clone_tag "$tag" "$tmp/mod" "$MOD_REPO" \
    || { err "Тег $tag не скачался — проверь имя тега и доступ к github.com"; return 1; }
  [[ -f "$tmp/mod/src/dkms.conf" ]] || { err "В теге нет src/dkms.conf — структура репозитория изменилась"; return 1; }
  _mod_src_patch "$tmp/mod/src"
  kver=$(build_kernel) || { err "Нет заголовков ни для одного ядра"; kernel_headers_help; return 1; }
  run_step "Пробная сборка под $kver" _mod_trial_build "$tmp/mod/src" "$kver" || {
    mod_log "пробная сборка не прошла"
    err "Модуль $tag не собирается под это ядро — установленная версия не тронута"
    return 1
  }

  if [[ -d "$MOD_SRC_DIR" ]]; then
    backup=$(mod_backup_src) && [[ -n "$backup" ]] && ok "Резервная копия исходников: $backup"
  fi
  dkms remove -m "$MOD_NAME" -v "$MOD_DKMS_VER" --all >/dev/null 2>&1 || true
  rm -rf "$MOD_SRC_DIR"

  if ! run_step "Установка исходников в DKMS" make -C "$tmp/mod/src" dkms-install \
     || ! run_step "Сборка DKMS под все ядра" _mod_dkms_install_all; then
    err "Установка модуля не удалась"
    if [[ -n "$backup" ]]; then
      run_step "Возврат прежней версии" mod_restore_src "$backup" && ok "Прежняя версия возвращена"
    fi
    return 1
  fi
  mkdir -p "$STATE_DIR"
  echo "$tag" > "$MOD_TAG_FILE"
  _PROTO_PROBE=()
  mod_log "установлен $tag"
  ok "Модуль $tag собран и установлен"
}

_tools_build_install() { make -C "$1" -j"$(nproc)" && make -C "$1" install; }

tools_install_tag() {
  local tag="$1" tmp bdir
  mktmp tmp -d || return 1
  run_step "Загрузка amneziawg-tools $tag" _git_clone_tag "$tag" "$tmp/tools" "$TOOLS_REPO" \
    || { err "Тег $tag не скачался"; return 1; }
  if command -v awg &>/dev/null; then
    bdir="$MOD_BACKUP_DIR/tools-$(tools_tag)-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bdir" && cp -a "$(command -v awg)" "$bdir/"
    command -v awg-quick &>/dev/null && cp -a "$(command -v awg-quick)" "$bdir/"
  fi
  run_step "Сборка amneziawg-tools $tag" _tools_build_install "$tmp/tools/src" || return 1
  hash -r
  mkdir -p "$STATE_DIR"
  echo "$tag" > "$TOOLS_TAG_FILE"
  _PROTO_PROBE=()
  ok "amneziawg-tools: $(tools_version)"
}

# Тег для установки: последний у апстрима, без сети — запасной.
resolve_tag() {  # mod|tools
  local t
  t=$(upstream_tags "$([[ "$1" == mod ]] && echo "$MOD_REPO" || echo "$TOOLS_REPO")" | head -1)
  if [[ -n "$t" ]]; then
    upstream_refresh >/dev/null 2>&1 || true
    echo "$t"
  elif [[ "$1" == mod ]]; then echo "$MOD_FALLBACK_TAG"
  else echo "$TOOLS_FALLBACK_TAG"; fi
}

mod_autoload() {
  grep -qs "^$MOD_NAME" "$MODULES_LOAD_FILE" || echo "$MOD_NAME" | write_file "$MODULES_LOAD_FILE" 644
}

# ── Перезагрузка модуля ───────────────────────────────────
awg_ifaces() { ip -o link show type amneziawg 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}'; }

# SSH идёт через сам туннель: перезапуск inline оборвёт сессию на stop, и
# выполнять start будет уже некому — уводим его в systemd-run.
_ssh_via_awg() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local dst i
  dst=$(awk '{print $3}' <<< "$SSH_CONNECTION")
  while read -r i; do
    [[ -n "$i" ]] && ip -o -4 addr show dev "$i" 2>/dev/null | grep -qF " ${dst}/" && return 0
  done < <(awg_ifaces)
  return 1
}

mod_reload() {
  local units ifaces cmd rc out
  units=$(systemctl list-units --type=service --state=active --no-legend --plain 'awg-quick@*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  ifaces=$(awg_ifaces | tr '\n' ' ')
  echo -e "  ${D}юниты: ${units:-нет}; интерфейсы: ${ifaces:-нет}${N}"
  warn "Туннели лягут на несколько секунд, клиенты переподключатся сами"
  (( AUTO_MODE )) || ask_yes "  Перезагрузить модуль сейчас? [Y/n]: " y || { info "Отменено"; return 1; }

  cmd="for u in $units; do systemctl stop \"\$u\"; done
for i in $ifaces; do ip link show \"\$i\" >/dev/null 2>&1 && { awg-quick down \"\$i\" 2>/dev/null || ip link del \"\$i\"; }; done
rmmod $MOD_NAME || { for u in $units; do systemctl start \"\$u\"; done; exit 3; }
modprobe $MOD_NAME || exit 4
for u in $units; do systemctl start \"\$u\"; done
exit 0"

  if _ssh_via_awg; then
    warn "SSH идёт через туннель — перезапуск отвязан от сессии (systemd-run)"
    systemd-run --unit=awg-mod-reload --collect bash -c "$cmd" >/dev/null 2>&1 \
      || { err "systemd-run не стартовал"; return 1; }
    info "Через ~15 секунд переподключись и проверь: awg show"
    return 0
  fi
  rc=0
  out=$(bash -c "$cmd" 2>&1) || rc=$?
  mod_log "перезагрузка модуля rc=$rc: $(tr '\n' ';' <<< "$out")"
  case $rc in
    0) _PROTO_PROBE=(); ok "Модуль перезагружен, в памяти новая сборка" ;;
    3) err "rmmod не выгрузил модуль — его держит ещё какой-то интерфейс; туннели подняты на прежней сборке"
       info "Проверь: ip -all netns exec ip link show type amneziawg"
       info "Надёжно — перезагрузка сервера: новая сборка уже на диске"
       return 1 ;;
    *) err "Модуль не загрузился — dmesg | tail -20"; return 1 ;;
  esac
}

# ── Действия из меню ──────────────────────────────────────
# mod_update_flow [тег] [force] — force: пересобрать, даже если тег уже стоит.
mod_update_flow() {
  local tag="${1:-}" force="${2:-}" cur
  components_deps || return 1
  ensure_headers "$(uname -r)" || { err "Нет заголовков ядра $(uname -r)"; kernel_headers_help; return 1; }
  if secure_boot_on; then
    warn "Secure Boot включён — ядро не загрузит неподписанный модуль"
    ask_yes "  Всё равно собрать? [y/N]: " n || return 1
  fi
  [[ -n "$tag" ]] || tag=$(resolve_tag mod)
  cur=$(mod_tag)
  if [[ "${cur#≈}" == "$tag" && "$force" != force ]]; then
    ask_yes "  Уже стоит $tag. Пересобрать? [y/N]: " n || { ok "Модуль $tag уже установлен"; return 0; }
  fi
  mod_install_tag "$tag" || return 1
  mod_autoload
  if mod_loaded; then mod_reload || true; else modprobe "$MOD_NAME" 2>/dev/null || true; fi
}

# Модуль и tools разом: для 3.1 нужны оба — бот и панель предлагают одну кнопку.
components_update_flow() {
  mod_update_flow || return 1
  tools_update_flow
}

tools_update_flow() {  # [force]
  local tag
  components_deps || return 1
  tag=$(resolve_tag tools)
  if [[ "$(tools_tag)" == "$tag" && "${1:-}" != force ]]; then
    ask_yes "  Уже стоит $tag. Пересобрать? [y/N]: " n || { ok "amneziawg-tools $tag уже установлены"; return 0; }
  fi
  tools_install_tag "$tag"
}

# Сборка под все ядра. Ядрам, в которые сервер может загрузиться, сначала
# ставятся недостающие заголовки — иначе их сборка молча пропускается.
mod_rebuild_all() {
  local k _
  components_deps || return 1
  while read -r k _; do
    [[ -n "$k" && ! -d "/lib/modules/$k/build" ]] || continue
    run_step "Заголовки ядра $k" ensure_headers "$k" || warn "Заголовков для $k в репозитории нет"
  done < <(kernel_gap)
  run_step "Сборка DKMS под все ядра" _mod_dkms_install_all || return 1
  if [[ -n "$(kernel_gap)" ]]; then
    warn "Модуль не собран под: $(kernel_gap_line) — после перезагрузки в это ядро awg0 не поднимется"
    info "Журнал сборки: $MOD_LOG и /var/lib/dkms/$MOD_NAME/$MOD_DKMS_VER/build/make.log"
    return 1
  fi
  ok "Модуль собран под все ядра"
}

mod_backups() { ls -1t "$MOD_BACKUP_DIR"/src-*.tar.gz 2>/dev/null || true; }

mod_rollback() {  # архив из mod_backups
  [[ -f "$1" && "$1" == "$MOD_BACKUP_DIR"/src-*.tar.gz ]] || { err "Нет такой резервной копии"; return 1; }
  run_step "Возврат модуля из ${1##*/}" mod_restore_src "$1" || return 1
  rm -f "$MOD_TAG_FILE"
  ok "Модуль возвращён из резервной копии"
  mod_reload || true
}

mod_pick_tag() {  # → тег в stdout
  local tags=() i c
  mapfile -t tags < <(upstream_tags "$MOD_REPO" | head -15)
  (( ${#tags[@]} )) || { err "Список тегов не получен (нет доступа к github.com)" >&2; return 1; }
  for i in "${!tags[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${tags[$i]}" >&2; done
  echo "   0) Назад" >&2
  read_choice c "${C}  Версия: ${N}" 0 "${#tags[@]}" "" >&2
  (( c == 0 )) && return 1
  echo "${tags[$((c-1))]}"
}

mod_rollback_flow() {
  local files=() i c
  mapfile -t files < <(mod_backups)
  (( ${#files[@]} )) || { warn "Резервных копий нет ($MOD_BACKUP_DIR)"; return 0; }
  for i in "${!files[@]}"; do
    printf "  %2d) %s ${D}(%s)${N}\n" "$((i+1))" "${files[$i]##*/}" "$(date -r "${files[$i]}" '+%d.%m %H:%M')"
  done
  echo "   0) Назад"
  read_choice c "${C}  Копия: ${N}" 0 "${#files[@]}" 0
  (( c == 0 )) && return 0
  mod_rollback "${files[$((c-1))]}"
}

kernel_headers_help() {
  local others
  others=$(installed_kernels | grep -vx "$(uname -r)" | tr '\n' ' ')
  if [[ -n "$others" ]]; then
    info "Установлены другие ядра: $others"
    info "Скорее всего ядро обновилось — перезагрузись и запусти установку снова"
  else
    info "Поставь вручную: apt-get install linux-headers-\$(uname -r)"
  fi
}

do_components_menu() {
  local c upd tupd t
  while true; do
    echo ""
    components_report
    upd=$(upstream_latest mod); tupd=$(upstream_latest tools)
    echo ""
    echo -e "  ${C}1)${N} Обновить модуль ${D}${upd:+до $upd}${N}"
    echo -e "  ${C}2)${N} Выбрать версию модуля из списка"
    echo -e "  ${C}3)${N} Обновить amneziawg-tools ${D}${tupd:+до $tupd}${N}"
    echo -e "  ${C}4)${N} Перезагрузить модуль ${D}— без ребута${N}"
    echo -e "  $([[ -n "$(kernel_gap)" ]] && echo "${Y}" || echo "${C}")5)${N} Пересобрать под все установленные ядра"
    echo -e "  ${C}6)${N} Откат модуля из резервной копии"
    echo -e "  ${C}7)${N} Проверить обновления сейчас"
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice c "${C}  Выбор [0-7]: ${N}" 0 7 0
    case "$c" in
      1) mod_update_flow || true ;;
      2) t=$(mod_pick_tag) && { mod_update_flow "$t" || true; } ;;
      3) tools_update_flow || true ;;
      4) mod_reload || true ;;
      5) mod_rebuild_all || true ;;
      6) mod_rollback_flow || true ;;
      7) if upstream_refresh; then ok "Модуль: $(upstream_latest mod), tools: $(upstream_latest tools)"
         else err "github.com недоступен"; fi ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ params ═════
# Параметры обфускации AmneziaWG.
#
# Версия протокола — на весь сервер: параметры 3.x уровня устройства
# (WGDEVICE_A_* в модуле), клиент 2.0 к серверу 3.1 не подключится.
# Профиль задаёт ширину диапазонов:
#   lite («AmneziaVPN») — вокруг значений официального клиента: Jc=4,
#        Jmin=10, Jmax=50, S1=86, S2=48, S3=16, S4=12;
#   pro («Мощный») — полные рекомендованные диапазоны;
#   standard — устаревший, распознаётся у старых серверов.

# S1-S4 >= 12 при HeaderProtectionKey — требование ядра (netlink.c): первые
# 12 байт паддинга уходят nonce'ом защиты заголовков. Меньше — setconf
# отвечает «Invalid argument».
AWG_HP_MIN_S=12
# Базовые длины сообщений WireGuard: 148 (initiation), 92 (response),
# 64 (cookie). S прибавляется к ним, и два типа сообщений становятся одной
# длины при разнице S ровно 56, 84 или 28 — такие совпадения разводим.
AWG_S_DELTAS=(56 84 28)
AWG_S_GAP=10
AWG_S4_MAX=32     # потолок amneziawg-tools (config.c)
AWG_JC_MAX=128    # модуль больше не примет
# Внешний пакет = MTU + 16 (заголовок) + 16 (Poly1305) + S4 + паддинг 3.x
# + 28 (IPv4+UDP). 24 байта запаса — под хвост RandomTrailers и туннель по пути.
AWG_MTU_OVERHEAD=60
AWG_MTU_SAFETY=24

_rand_s() {  # профиль S1|S2|S3|S4
  case "$1:$2" in
    lite:S1) rand_range 80 92 ;;     lite:S2) rand_range 42 54 ;;
    lite:S3) rand_range 14 20 ;;     lite:S4) rand_range 12 18 ;;
    standard:S1|standard:S2) rand_range 30 80 ;;
    standard:S3) rand_range 15 32 ;; standard:S4) rand_range 10 20 ;;
    *:S1|*:S2) rand_range 15 150 ;;
    *:S3) rand_range 8 64 ;;         *:S4) rand_range 6 31 ;;
  esac
}

_too_close() { local d=$(( $1 - $2 )); (( (d < 0 ? -d : d) < AWG_S_GAP )); }

_s_collide() {  # есть ли совпадение длин при текущих S1-S3
  _too_close $(( S1 + AWG_S_DELTAS[0] )) "$S2" ||
  _too_close $(( S1 + AWG_S_DELTAS[1] )) "$S3" ||
  _too_close $(( S2 + AWG_S_DELTAS[2] )) "$S3"
}

_s_raise_min() {  # только для 3.x: S1-S4 не ниже AWG_HP_MIN_S
  local n
  for n in S1 S2 S3 S4; do
    (( ${!n} >= AWG_HP_MIN_S )) || printf -v "$n" '%s' "$(rand_range "$AWG_HP_MIN_S" $((AWG_HP_MIN_S + 12)))"
  done
}

# Пара «lo-hi» в диапазоне [min, max]: нижний конец в первой трети, верхний
# в последней, ширина не меньше 1000.
_h_pair() {
  local min="$1" max="$2" span lo hi
  span=$(( max - min ))
  lo=$(rand_range "$min" $(( min + span / 3 )))
  hi=$(rand_range $(( min + 2 * span / 3 )) "$max")
  (( hi - lo < 1000 )) && hi=$(( lo + 1000 ))
  echo "${lo}-${hi}"
}

# Параметры 3.x. Модуль значения не проверяет, поэтому диапазоны строятся
# вокруг протокольных констант WireGuard (REKEY_AFTER_TIME 120, REJECT_AFTER_TIME
# 180, KEEPALIVE_TIMEOUT 10, REKEY_TIMEOUT 5). Инвариант: RejectAfterTime
# строго больше RekeyAfterTime, иначе сессия умрёт раньше, чем переустановится.
_gen_awg3_lines() {
  local proto="$1" hp cpa_lo cpa_hi rat_lo rat_hi rjt_lo rjt_hi rkt_lo
  hp=$(awg genkey) || return 1
  cpa_lo=$(rand_range 8 24); cpa_hi=$(rand_range 48 96)
  rat_lo=$(rand_range 110 125); rat_hi=$(rand_range 140 160)
  rjt_lo=$(rand_range 175 190); rjt_hi=$(rand_range 200 215)
  (( rjt_lo <= rat_hi )) && rjt_lo=$(( rat_hi + 15 ))
  (( rjt_hi <= rjt_lo )) && rjt_hi=$(( rjt_lo + 20 ))
  # Повтор рукопожатия не константой 5 с (стабильная временная подпись), но и
  # не быстрее 5 с; при MaxHandshakeAttempts 16-20 отказ наступит за ~3 мин.
  rkt_lo=$(rand_range 5 6)
  printf 'HeaderProtectionKey = %s\n' "$hp"
  printf 'ContentPaddingAddition = %s-%s\n' "$cpa_lo" "$cpa_hi"
  printf 'RekeyAfterTime = %s-%s\n' "$rat_lo" "$rat_hi"
  printf 'RekeyTimeout = %s-%s\n' "$rkt_lo" $(( rkt_lo + $(rand_range 2 3) ))
  printf 'RejectAfterTime = %s-%s\n' "$rjt_lo" "$rjt_hi"
  printf 'KeepaliveTimeout = %s-%s\n' "$(rand_range 9 14)" "$(rand_range 20 30)"
  printf 'MaxHandshakeAttempts = %s\n' "$(rand_range 16 20)"
  # RandomTrailers обязан совпадать на обоих концах: с ним приёмник принимает
  # рукопожатие длиннее ожидаемого, без него — отбросит. DisableCookies
  # локален: сервер не отвечает cookie-пакетом под нагрузкой.
  if [[ "$proto" == 3.1 ]]; then
    printf 'RandomTrailers = on\nDisableCookies = on\n'
  fi
}

# gen_awg_params ПРОФИЛЬ ВЕРСИЯ → AWG_PARAMS (строки «Ключ = значение»).
# Может снизить глобальный MTU, если внешний пакет не влезает в 1500.
AWG_PARAMS="" AWG3_CPA_MAX=0
gen_awg_params() {
  local profile="$1" proto="$2" Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 tries=0 p3=""
  case "$profile" in
    lite)     Jc=$(rand_range 3 5);  Jmin=$(rand_range 8 12); Jmax=$(rand_range 70 90) ;;
    standard) Jc=$(rand_range 5 8);  Jmin=$(rand_range 8 16); Jmax=$(rand_range 70 100) ;;
    *)        Jc=$(rand_range 4 12); Jmin=$(rand_range 8 24); Jmax=$(rand_range 80 120) ;;
  esac
  S1=$(_rand_s "$profile" S1); S2=$(_rand_s "$profile" S2)
  S3=$(_rand_s "$profile" S3); S4=$(_rand_s "$profile" S4)
  [[ "$proto" == 3* ]] && _s_raise_min

  # Разведение длин: сперва перебор в рамках профиля, затем сдвиг вверх
  while _s_collide && (( tries++ < 20 )); do
    S2=$(_rand_s "$profile" S2); S3=$(_rand_s "$profile" S3)
    [[ "$proto" == 3* ]] && _s_raise_min
  done
  tries=0
  while _too_close $(( S1 + AWG_S_DELTAS[0] )) "$S2" && (( tries++ < 30 )); do S2=$(( S2 + AWG_S_GAP )); done
  tries=0
  while { _too_close $(( S1 + AWG_S_DELTAS[1] )) "$S3" || _too_close $(( S2 + AWG_S_DELTAS[2] )) "$S3"; } \
        && (( tries++ < 30 )); do S3=$(( S3 + AWG_S_GAP )); done
  (( S4 > AWG_S4_MAX )) && S4=$AWG_S4_MAX
  (( Jc > AWG_JC_MAX )) && Jc=$AWG_JC_MAX
  (( Jmin < Jmax )) || Jmax=$(( Jmin + 50 ))

  # H1-H4: на 3.x заголовок целиком под шифром (HeaderProtectionKey), и подмена
  # типа пакета ничего не скрывает — официальный клиент тоже оставляет 1-4.
  # На 2.0 заголовок открыт: 1-4 — прямой признак WireGuard, нужны диапазоны,
  # не пересекающиеся и не выше 2^31-1 (старый Windows-клиент выше не принимал).
  if [[ "$proto" == 3* ]]; then
    H1=1; H2=2; H3=3; H4=4
    p3=$(_gen_awg3_lines "$proto") || { err "awg genkey не сработал"; return 1; }
    AWG3_CPA_MAX=$(sed -n 's/^ContentPaddingAddition = [0-9]*-//p' <<< "$p3")
  else
    AWG3_CPA_MAX=0
    H1=$(_h_pair 5 536870911)
    H2=$(_h_pair 536870912 1073741823)
    H3=$(_h_pair 1073741824 1610612735)
    H4=$(_h_pair 1610612736 2147483647)
  fi

  AWG_PARAMS=$(printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n%s' \
    "$Jc" "$Jmin" "$Jmax" "$S1" "$S2" "$S3" "$S4" "$H1" "$H2" "$H3" "$H4" "$p3")
  AWG_PARAMS="${AWG_PARAMS%$'\n'}"
  _check_mtu_headroom "$S4"
}

# MTU без запаса до пути в 1500 даёт не обрыв, а загадочную просадку скорости:
# крупные пакеты режутся, а PMTU discovery по UDP работает не везде.
_check_mtu_headroom() {
  local s4="$1" outer limit safe
  [[ "${MTU:-}" =~ ^[0-9]+$ ]] || return 0
  outer=$(( MTU + AWG_MTU_OVERHEAD + s4 + AWG3_CPA_MAX ))
  limit=$(( 1500 - AWG_MTU_SAFETY ))
  (( outer <= limit )) && return 0
  safe=$(( (limit - AWG_MTU_OVERHEAD - s4 - AWG3_CPA_MAX) / 10 * 10 ))
  (( safe > 1420 )) && safe=1420
  (( safe < 1280 )) && safe=1280
  warn "MTU $MTU не оставляет запаса: внешний пакет до $outer Б при пути 1500"
  if (( AUTO_MODE )) || ask_yes "  Снизить MTU до $safe? [Y/n]: " y; then
    MTU=$safe
    ok "MTU: $MTU"
  fi
}

# PersistentKeepalive клиента. На 3.x — диапазон вокруг 25 с (ядро выбирает
# значение на каждой отправке, константа — стабильная временная подпись),
# в официальных границах 22-30: выше 30 с роутеры забывают UDP-сессию.
keepalive_for() {
  if [[ "$1" == 3* ]]; then echo "$(rand_range 22 25)-$(rand_range 27 30)"
  else echo 25; fi
}

# Нарушения S >= 12 в конфиге с HeaderProtectionKey (для диагностики).
conf_hp_min_s_violations() {
  local k v bad=""
  grep -q '^HeaderProtectionKey' "$SERVER_CONF" 2>/dev/null || return 0
  for k in S1 S2 S3 S4; do
    v=$(conf_iface_get "$k")
    [[ "$v" =~ ^[0-9]+$ ]] && (( v < AWG_HP_MIN_S )) && bad+=" $k=$v"
  done
  echo "${bad# }"
}

# ═════ mimicry ═════
# Мимикрия I1-I5 (CPS): пакеты-приманки перед рукопожатием, собранные
# генератором (порт payloadGen, встроен как _CPS_GENERATOR).
#
# Цепочка I1-I5 — клиентская: у каждого устройства своя, сервер её не видит.
# Поэтому у выданного клиента профиль мимикрии можно сменить, не трогая сервер.

# Пулы доменов — по региону сервера: российские сайты для сервера в РФ,
# мировые — для остальных. Проверяются на доступность перед выдачей.
CPS_DOMAINS=(
  yastatic.net mc.yandex.ru avatars.mds.yandex.net ok.ru st.mycdn.me vk.ru
  kinopoisk.ru hh.ru 2gis.ru lenta.ru mos.ru citilink.ru
)
# Только те, что реально отвечают по HTTP/3: QUIC-снимок к хосту без QUIC
# недостоверен сам по себе.
QUIC_DOMAINS=(
  google.com youtube.com cdn.jsdelivr.net unpkg.com icloud.com mzstatic.com
  fastly.net a.ssl.fastly.net b-cdn.net github.com objects.githubusercontent.com
)
QUIC_DOMAINS_RU=(ozon.ru)
SIP_DOMAINS=(
  sip.zadarma.com sip.iptel.org sip.linphone.org sip.antisip.com sip.dus.net
  sip.easybell.de sip.voys.nl sip.peoplefone.ch sip.messagenet.it
)
STUN_DOMAINS=(meet.jit.si stun.nextcloud.com stun.sipgate.net stun.zoiper.com stun.l.google.com)
TLS_DOMAINS=(
  google.com github.com gitlab.com stackoverflow.com microsoft.com apple.com amazon.com
  mozilla.org kernel.org debian.org ubuntu.com cdn.jsdelivr.net unpkg.com pypi.org
  hetzner.com ovhcloud.com digitalocean.com steampowered.com spotify.com
)
TLS_DOMAINS_RU=(ya.ru vk.com mail.ru ozon.ru wildberries.ru rutube.ru gosuslugi.ru)

# Предел суммарной длины I1-I5: атрибуты уровня устройства amneziawg-tools
# пишет в netlink-буфер 4 КБ без проверки границ (issue #69). До ~3600
# символов всё работает, дальше `awg show` виснет, от ~3870 `awg set` падает.
CPS_HARD_LIMIT=3500
MIMICRY_PROFILES=(quic curl_quic dns stun webrtc sip ntp rtp ssdp)
# Подписи профилей для меню и бота: «профиль|название|пояснение».
MIMICRY_INFO=(
  "quic|QUIC|Chrome, HTTP/3"          "curl_quic|cURL QUIC|curl, SNI в ECH"
  "dns|DNS|короткий, плотный QR"      "stun|STUN|ICE-провайдер"
  "webrtc|WebRTC|начало звонка"       "sip|SIP|открытый текст"
  "ntp|NTP|48 байт, мало деталей"     "rtp|RTP|медиа без сигналинга"
  "ssdp|SSDP|наружу ходит редко"
)

# Результат выбора — глобальные переменные (их же пишем метками в шапку):
MIMICRY="none" OBF_LEVEL=1 CPS_BUDGET=0 CPS_DOMAIN="" I_LINES=()

# ── Доступность доменов ───────────────────────────────────
# tls — TCP-коннект к :443 (ICMP часто режут), остальное — ping.
probe_host() {  # профиль хост → «ok МС» | fail
  local t0 t1 ms
  if [[ "$1" == tls ]]; then
    t0=$EPOCHREALTIME
    if timeout 2 bash -c "exec 3<>/dev/tcp/$2/443" 2>/dev/null; then
      t1=$EPOCHREALTIME
      ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{v=(b-a)*1000; printf "%d", v < 1 ? 1 : v}')
      echo "ok $ms"; return 0
    fi
  else
    ms=$(timeout 3 ping -c1 -W2 "$2" 2>/dev/null | grep -oE 'time=[0-9.]+' | cut -d= -f2)
    [[ -n "$ms" ]] && { printf 'ok %.0f\n' "$ms"; return 0; }
  fi
  echo fail
}

# Параллельная проверка. Результат — массив SCAN_OK (доступные домены).
SCAN_OK=()
scan_domains() {
  local kind="$1" d dir
  shift
  mktmp dir -d || return 1
  for d in "$@"; do probe_host "$kind" "$d" > "$dir/$d" & done
  wait
  SCAN_OK=()
  for d in "$@"; do [[ "$(cat "$dir/$d" 2>/dev/null)" == ok* ]] && SCAN_OK+=("$d"); done
  rm -rf "$dir"
}

# ── Генерация ─────────────────────────────────────────────
# gen_chain ПРОФИЛЬ ДОМЕН [--only-i1] → I_LINES (до пяти строк).
# Бюджет режет цепочку целыми пакетами: обрубок пакета выдаёт подделку вернее,
# чем отсутствие мимикрии. Первый пакет выдаётся всегда.
gen_chain() {
  local profile="$1" domain="${2:-}" only="${3:-}" budget="${CPS_BUDGET:-0}" out
  (( budget <= 0 || budget > CPS_HARD_LIMIT )) && budget=$CPS_HARD_LIMIT
  out=$(cps "$profile" "$domain" ${only:+"$only"} --budget "$budget" 2>>"$LOG_FILE") || out=""
  mapfile -t I_LINES < <(printf '%s\n' "$out" | sed '/^$/d' | head -5)
  (( ${#I_LINES[@]} > 0 ))
}

i_lines_block() {  # «I1 = ...» построчно
  local i
  for i in "${!I_LINES[@]}"; do printf 'I%d = %s\n' "$((i + 1))" "${I_LINES[$i]}"; done
}

i_chain_len() { local s="" l; for l in ${I_LINES[@]+"${I_LINES[@]}"}; do s+="$l"; done; echo "${#s}"; }

# Цепочка по меткам сервера: так же, как её выдаёт бот, — клиенты одного
# сервера получают одинаковый профиль и домен.
gen_chain_from_server() {  # [УРОВЕНЬ] — вместо уровня сервера
  local level mim dom
  I_LINES=()
  level=${1:-$(conf_marker AWG_OBF_LEVEL)}; mim=$(conf_marker AWG_MIMICRY)
  dom=$(conf_marker AWG_MIMICRY_DOMAIN)
  CPS_BUDGET=$(conf_marker AWG_CPS_BUDGET); CPS_BUDGET="${CPS_BUDGET:-0}"
  MIMICRY="${mim:-none}"
  [[ -z "$mim" || "$mim" == none || "${level:-1}" == 1 ]] && { MIMICRY=none; return 0; }
  if [[ "$level" == 2 ]]; then gen_chain "$mim" "$dom" --only-i1
  else gen_chain "$mim" "$dom"; fi
}

# ── Выбор в меню ──────────────────────────────────────────
_profile_needs_domain() { [[ "$1" =~ ^(quic|curl_quic|dns|sip)$ ]]; }

_cps_pkt_len() {  # ориентировочная длина одного пакета в символах
  case "$1" in
    quic) echo 2400 ;; curl_quic) echo 2500 ;; sip) echo 1200 ;; webrtc) echo 950 ;;
    ssdp) echo 450 ;; dtls) echo 380 ;; rtp) echo 300 ;; stun) echo 280 ;;
    ntp) echo 100 ;; dns) echo 90 ;; *) echo 500 ;;
  esac
}

choose_obf_level() {
  echo ""
  hdr "Уровень мимикрии"
  echo -e "  ${G}3${N}  I1-I5 — полная цепочка ${C}(рекомендуется)${N}"
  echo -e "  ${G}2${N}  Только I1 — один пакет-снимок"
  echo -e "  ${G}1${N}  Без I1-I5 — любые клиенты, короткий конфиг"
  echo -e "  ${Y}  WireSock не читает I1-I5 → уровень 1. Keenetic → уровень 2.${N}"
  read_choice OBF_LEVEL "${C}  Выбор [1-3] (Enter = 3): ${N}" 1 3 3
}

choose_mimicry() {
  local c def=1 i label hint
  MIMICRY=none
  (( OBF_LEVEL == 1 )) && return 0
  echo ""
  hdr "Профиль мимикрии"
  for i in "${!MIMICRY_INFO[@]}"; do
    IFS='|' read -r _ label hint <<< "${MIMICRY_INFO[$i]}"
    printf "  %b%d%b %-10s %b%s%b\n" "$( (( i < 5 )) && echo "$G" || echo "$Y")" "$((i + 1))" "$N" "$label" "$D" "$hint" "$N"
  done
  echo -e "  ${D}0 назад${N}"
  # Цепочка уходит залпом за микросекунды. Пять пакетов подряд естественны
  # для DNS (A/AAAA/HTTPS), RTP и ICE-сбора STUN; пять QUIC Initial в одну
  # точку — это пять одновременных соединений, так браузер не делает.
  if (( OBF_LEVEL == 3 )); then
    def=3
    echo -e "  ${D}  Пять пакетов залпом естественны для DNS (3), STUN (4), RTP (8).${N}"
  else
    echo -e "  ${D}  Для одного I1 самый достоверный — QUIC (1).${N}"
  fi
  echo -e "  ${D}  На высоком порту естественны STUN, WebRTC, RTP; DNS/NTP/SSDP — нет.${N}"
  read_choice c "${C}  Выбор [0-9] (Enter = $def): ${N}" 0 9 "$def"
  (( c == 0 )) && return 1
  MIMICRY="${MIMICRY_PROFILES[$((c - 1))]}"
}

# Сколько пакетов профиля влезет в бюджет (минимум один — он выдаётся всегда).
_cps_fit() { local n=$(( $1 / $2 )); (( n < 1 )) && n=1; (( n > 5 )) && n=5; echo "$n"; }

# Бюджет по умолчанию: компактный, если в него влезают все пять пакетов.
cps_default_budget() {
  if (( $(_cps_fit 1500 "$(_cps_pkt_len "$1")") < 5 )); then echo "$CPS_HARD_LIMIT"; else echo 1500; fi
}

choose_cps_budget() {
  local pkt c def=1
  CPS_BUDGET=0
  (( OBF_LEVEL == 3 )) || return 0
  pkt=$(_cps_pkt_len "$MIMICRY")
  [[ "$(cps_default_budget "$MIMICRY")" == 1500 ]] || def=3
  echo ""
  hdr "Длина цепочки I1-I5"
  echo -e "  ${D}Профиль $MIMICRY: пакет ~$pkt символов, режется целыми пакетами.${N}"
  echo -e "  ${G}1${N} Компактная ~1500 — влезает в QR → $(_cps_fit 1500 "$pkt") из 5"
  echo -e "  ${G}2${N} Средняя ~3000 → $(_cps_fit 3000 "$pkt") из 5"
  echo -e "  ${G}3${N} Максимум $CPS_HARD_LIMIT → $(_cps_fit "$CPS_HARD_LIMIT" "$pkt") из 5"
  read_choice c "${C}  Выбор [1-3] (Enter = $def): ${N}" 1 3 "$def"
  case "$c" in 1) CPS_BUDGET=1500 ;; 2) CPS_BUDGET=3000 ;; *) CPS_BUDGET=$CPS_HARD_LIMIT ;; esac
}

# Регион для пула доменов: при создании сервера — выбранный в мастере
# (конфига ещё нет), потом — из конфига.
mimicry_region() {
  if server_exists; then server_region; else echo "${S_REGION:-world}"; fi
}

# Один домен на всю цепочку: настоящий клиент за одно рукопожатие ходит на
# один хост. Результат — CPS_DOMAIN (пусто = генератор возьмёт свой).
choose_cps_domain() {
  local c d ask_own=1
  CPS_DOMAIN=""
  if ! _profile_needs_domain "$MIMICRY"; then
    [[ "$MIMICRY" =~ ^(stun|webrtc)$ ]] || return 0
    echo -e "  ${D}STUN/WebRTC берут адреса своего ICE-провайдера; свой домен уйдёт в USERNAME и SNI DTLS.${N}"
    ask_yes "  Задать свой домен? [y/N]: " n || return 0
  else
    echo ""
    hdr "Домен мимикрии (один на все I1-I5)"
    echo -e "  ${G}1${N} Автоматически ${C}(рекомендуется)${N}"
    echo -e "  ${D}    доступный сайт из пула: $([[ "$(mimicry_region)" == ru ]] && echo "российские" || echo "мировые") — по региону сервера${N}"
    echo -e "  ${G}2${N} Ввести свой"
    echo -e "  ${D}    живой сайт, куда ходят с устройства клиента${N}"
    [[ "$MIMICRY" == *quic ]] && echo -e "  ${Y}  Для QUIC сайт должен отдавать HTTP/3.${N}"
    read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
    [[ "$c" == 1 ]] && ask_own=0
  fi
  if (( ask_own )); then
    while true; do
      read_line d "${C}  Домен (Enter — встроенный пул): ${N}"
      d="${d// /}"
      [[ -z "$d" ]] && break
      valid_domain "$d" && { CPS_DOMAIN="${d,,}"; ok "Домен: $CPS_DOMAIN"; return 0; }
      warn "Не похоже на домен"
    done
  fi
  # STUN/WebRTC без своего домена обходятся адресами ICE-провайдера — как
  # в mimicry_from_spec; пул TLS-доменов им не подставляем.
  _profile_needs_domain "$MIMICRY" && mimicry_pool_domain
  return 0
}

# Случайный доступный домен из встроенного пула профиля → CPS_DOMAIN.
mimicry_pool_domain() {
  local kind pool=()
  case "$MIMICRY" in
    quic|curl_quic) kind=quic; pool=("${QUIC_DOMAINS[@]}")
                    [[ "$(mimicry_region)" == ru ]] && pool+=("${QUIC_DOMAINS_RU[@]}") ;;
    sip) kind=sip; pool=("${SIP_DOMAINS[@]}") ;;
    *) kind=tls
       if [[ "$(mimicry_region)" == ru ]]; then pool=("${CPS_DOMAINS[@]}"); else pool=("${TLS_DOMAINS[@]}"); fi ;;
  esac
  info "Проверяю доступность доменов пула..."
  scan_domains "$kind" "${pool[@]}"
  if (( ${#SCAN_OK[@]} )); then
    CPS_DOMAIN="${SCAN_OK[$(rand_range 0 $(( ${#SCAN_OK[@]} - 1 )))]}"
    ok "Домен: $CPS_DOMAIN ${D}(доступно ${#SCAN_OK[@]} из ${#pool[@]})${N}"
  else
    warn "Ни один домен пула не ответил — генератор возьмёт свой"
  fi
}

# Генерация I1-I5 по выбранным MIMICRY / OBF_LEVEL / CPS_BUDGET / CPS_DOMAIN.
mimicry_generate() {
  I_LINES=()
  if (( OBF_LEVEL == 1 )) || [[ "$MIMICRY" == none ]]; then MIMICRY=none; OBF_LEVEL=1; return 0; fi
  info "Генерирую $MIMICRY${CPS_DOMAIN:+ ($CPS_DOMAIN)}..."
  if (( OBF_LEVEL == 2 )); then gen_chain "$MIMICRY" "$CPS_DOMAIN" --only-i1
  else gen_chain "$MIMICRY" "$CPS_DOMAIN"; fi || { warn "Генератор не выдал пакетов — без мимикрии"; MIMICRY=none; OBF_LEVEL=1; return 0; }
  ok "Пакетов: ${#I_LINES[@]}, символов: $(i_chain_len)"
  (( $(i_chain_len) > 2500 )) && warn "Цепочка длинная — в QR не влезет, выдавать файлом"
  return 0
}

# Полный выбор мимикрии для профиля «Мощный» и генерация. 1 — отмена.
choose_and_gen_chain() {
  I_LINES=()
  choose_obf_level
  choose_mimicry || return 1
  (( OBF_LEVEL == 1 )) && return 0
  choose_cps_budget
  choose_cps_domain
  mimicry_generate
}

# Мимикрия по строке без вопросов (бот, командная строка):
#   server — как у сервера (у «Standard» — свежий QUIC I1);  none — без I1-I5;
#   server:2 | server:3 — профиль и домен сервера, но свой уровень;
#   ПРОФИЛЬ[:УРОВЕНЬ[:ДОМЕН[:БЮДЖЕТ]]] — уровень 2 (только I1) или 3 (цепочка),
#   без домена — случайный доступный из пула, без бюджета — по профилю.
mimicry_from_spec() {
  local spec="${1:-server}" p lvl dom bud
  I_LINES=()
  case "$spec" in
    none) MIMICRY=none; OBF_LEVEL=1; CPS_BUDGET=0; CPS_DOMAIN=""; return 0 ;;
    server)
      if [[ "$(server_profile)" == standard ]]; then spec="quic:2"
      else gen_chain_from_server; return 0; fi ;;
    server:2|server:3)
      if [[ "$(server_profile)" == standard ]]; then spec="quic:${spec#server:}"
      else gen_chain_from_server "${spec#server:}"; return 0; fi ;;
  esac
  IFS=: read -r p lvl dom bud <<< "$spec"
  [[ " ${MIMICRY_PROFILES[*]} " == *" $p "* ]] || { err "Профиль мимикрии: ${MIMICRY_PROFILES[*]}"; return 1; }
  [[ -z "$dom" ]] || valid_domain "$dom" || { err "Недопустимый домен: $dom"; return 1; }
  MIMICRY="$p"; OBF_LEVEL=3; CPS_DOMAIN="${dom,,}"; CPS_BUDGET=0
  [[ "$lvl" == 2 ]] && OBF_LEVEL=2
  if (( OBF_LEVEL == 3 )); then
    if [[ "$bud" =~ ^[0-9]+$ ]] && (( bud > 0 )); then CPS_BUDGET=$bud; else CPS_BUDGET=$(cps_default_budget "$p"); fi
  fi
  [[ -z "$CPS_DOMAIN" ]] && _profile_needs_domain "$p" && mimicry_pool_domain
  mimicry_generate
}

# Метка профиля выданного клиента (пишется в его блок [Peer]).
mimicry_tag() { (( ${#I_LINES[@]} )) && echo "$MIMICRY" || echo none; }

# ═════ server ═════
# Сервер awg0: установка компонентов, создание, запуск, ремонт,
# перегенерация параметров и смена версии протокола.

# ── Установка компонентов ─────────────────────────────────
BASE_PKGS=(ca-certificates curl gnupg iproute2 iptables python3 python3-cryptography
           qrencode git build-essential dkms libmnl-dev pkg-config iputils-ping)

# Остатки APT-репозиториев эпохи установки через PPA ломают apt-get update.
_purge_legacy_ppa() {
  local f found=1
  for f in /etc/apt/sources.list.d/amnezia*.{list,sources} \
           /etc/apt/sources.list.d/canonical-kernel-team*.{list,sources} \
           /etc/apt/trusted.gpg.d/amnezia*.gpg /etc/apt/keyrings/amnezia*.gpg; do
    [[ -e "$f" ]] && { rm -f "$f"; found=0; }
  done
  return "$found"
}

# github.com не резолвится — чиним DNS сервера бережно: при systemd-resolved
# добавляем drop-in, а не затираем /etc/resolv.conf (там символьная ссылка).
_ensure_dns() {
  getent hosts github.com &>/dev/null && return 0
  warn "github.com не резолвится с этого сервера"
  if unit_active systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=9.9.9.9\n' \
      | write_file /etc/systemd/resolved.conf.d/awg2-dns.conf 644
    systemctl restart systemd-resolved
    info "Добавлены DNS 1.1.1.1 и 8.8.8.8 (/etc/systemd/resolved.conf.d/awg2-dns.conf)"
  elif [[ ! -L /etc/resolv.conf ]]; then
    [[ -f /etc/resolv.conf.awg-backup ]] || cp /etc/resolv.conf /etc/resolv.conf.awg-backup 2>/dev/null || true
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    info "resolv.conf заменён (копия: /etc/resolv.conf.awg-backup)"
  fi
  getent hosts github.com &>/dev/null && { ok "DNS работает"; return 0; }
  err "DNS не работает: проверь ping 1.1.1.1 и настройки сети"
  return 1
}

# Заголовков под работающее ядро в зеркале уже нет (так бывает со старыми
# облачными образами) — ставим актуальное ядро с заголовками и собираем
# модуль под него; работать всё начнёт после перезагрузки.
_install_current_kernel() {
  local arch pkgs
  os_detect
  arch=$(dpkg --print-architecture)
  if [[ "$OS_ID" == debian ]]; then
    if [[ "$(uname -r)" == *-cloud-* ]]; then pkgs=("linux-image-cloud-$arch" "linux-headers-cloud-$arch")
    else pkgs=("linux-image-$arch" "linux-headers-$arch"); fi
  else
    pkgs=(linux-generic)
    dpkg -s linux-virtual &>/dev/null && pkgs=(linux-virtual linux-headers-virtual)
  fi
  run_step "Установка ядра: ${pkgs[*]}" apt_install "${pkgs[@]}"
}

do_install() {
  local why tag cur running k
  echo ""
  hdr "Установка AmneziaWG"
  # os_supported идёт в $(…) — OS_LABEL, найденный там, до «ОС:» не дошёл бы
  os_detect
  if ! why=$(os_supported); then
    err "$why"
    [[ -n "${AWG2_ANY_OS:-}" ]] || return 1
    warn "AWG2_ANY_OS=1 — продолжаю на свой риск"
  else
    ok "ОС: $OS_LABEL"
  fi
  : > "$INSTALL_LOG"; chmod 600 "$INSTALL_LOG"
  info "Подробный вывод шагов: $INSTALL_LOG"
  _purge_legacy_ppa && ok "Удалены остатки старых PPA"
  _ensure_dns || return 1

  export DEBIAN_FRONTEND=noninteractive
  run_step "Обновление списка пакетов" apt-get update -q || return 1
  if ask_yes "  Обновить пакеты системы (apt upgrade)? [Y/n]: " y; then
    run_step "Обновление системы" apt-get upgrade -y -q -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold || warn "apt upgrade с ошибкой — продолжаю"
  fi
  run_step "Пакеты (${#BASE_PKGS[@]})" apt_install "${BASE_PKGS[@]}" || { apt_errors; return 1; }

  running=$(uname -r)
  if ! run_step "Заголовки ядра $running" ensure_headers "$running"; then
    warn "Заголовков под ядро $running в репозитории нет"
    if ask_yes "  Поставить актуальное ядро с заголовками (понадобится перезагрузка)? [Y/n]: " y; then
      _install_current_kernel || return 1
    else
      kernel_headers_help
      return 1
    fi
  fi

  if [[ -d "/lib/modules/$running/build" ]]; then
    cur=$(mod_tag)
    tag=$(resolve_tag mod)
    if [[ "${cur#≈}" == "$tag" ]] && mod_built_for "$running"; then
      ok "Модуль $tag уже установлен"
    else
      mod_install_tag "$tag" || return 1
    fi
  else
    # Собираем только под новое ядро: работающему заголовков нет
    tag=$(resolve_tag mod)
    k=$(installed_kernels | tail -1)
    info "Модуль будет собран под $k — он загрузится после перезагрузки"
    mod_install_tag "$tag" || true
  fi

  tag=$(resolve_tag tools)
  if [[ "$(tools_tag)" == "$tag" ]] && command -v awg &>/dev/null; then
    ok "amneziawg-tools $tag уже установлены"
  else
    tools_install_tag "$tag" || return 1
  fi

  modprobe "$MOD_NAME" 2>/dev/null || true
  mod_autoload
  ip_forward_enable
  mkdir -p "$AWG_DIR" && chmod 700 "$AWG_DIR"
  expire_install
  success_box "Компоненты установлены"
  components_report

  why=$(reboot_reason)
  if [[ -n "$why" && "$why" != *modprobe* ]]; then
    echo ""
    warn "Нужна перезагрузка: $why"
    if [[ "$why" == *"перезагрузка модуля"* ]]; then
      mod_reload || true
    elif (( ! AUTO_MODE )) && ask_yes "  Перезагрузить сервер сейчас? [Y/n]: " y; then
      ok "Перезагружаюсь. После — sudo awg2 → Сервер → Создать сервер"
      sleep 2; reboot
    fi
  else
    info "Следующий шаг: Сервер → Создать сервер"
  fi
}

# ── Запуск awg0 с разбором ошибки ─────────────────────────
# Сообщения awg-quick короткие, но однозначные — каждому соответствует одно
# действие. Разбор избавляет от гадания по «awg-quick up провалился».
awg_diagnose_up() {
  local out="$1" low bad p holder
  low="${out,,}"
  if [[ "$low" == *"line unrecognized"* ]]; then
    bad=$(grep -oiE 'line unrecognized: .?[A-Za-z0-9_]+' <<< "$out" | head -1 | grep -oE '[A-Za-z0-9_]+$')
    err "amneziawg-tools не знают параметра ${bad:-из конфига}"
    if [[ "$bad" =~ ^${AWG3_KEYS_RE}$ ]]; then
      info "Это параметр AWG 3.x — обнови компоненты: Сервер → Модуль ядра"
      info "или верни сервер на 2.0: Сервер → Протокол и параметры"
    fi
  elif [[ "$low" == *"invalid argument"* || "$low" == *"unable to modify interface"* ]]; then
    err "Ядро отвергло параметры интерфейса"
    bad=$(conf_hp_min_s_violations)
    if [[ -n "$bad" ]]; then
      info "AWG 3.x требует S1-S4 ≥ $AWG_HP_MIN_S, а в конфиге: $bad"
      info "Лечится перегенерацией: Сервер → Протокол и параметры"
    elif server_params | grep -qE "^${AWG3_KEYS_RE}"; then
      if mod_stale; then info "В памяти прежняя сборка модуля — Сервер → Модуль ядра → перезагрузить модуль"
      else info "Модуль не поддерживает параметры 3.x — Сервер → Модуль ядра → обновить"; fi
    else
      info "Смотри: dmesg | tail -20"
    fi
  elif [[ "$low" == *"unknown device type"* || "$low" == *"protocol not supported"* || "$low" == *"operation not supported"* ]]; then
    err "Ядро не умеет интерфейсы amneziawg — модуль не загружен или собран под другое ядро"
    info "Сервер → Модуль ядра (там же пересборка под все ядра)"
  elif [[ "$low" == *"address already in use"* ]]; then
    p=$(server_port)
    err "UDP-порт ${p:-?} занят"
    holder=$(ss -lunp 2>/dev/null | grep -E "[:.]${p}\b" || true)
    [[ -n "$holder" ]] && sed 's/^/    /' <<< "$holder"
  elif [[ "$low" == *iptables* ]]; then
    err "Правила iptables из PostUp не применились — проверь: iptables -V"
  elif [[ "$low" == *resolvconf* ]]; then
    err "В серверном конфиге строка DNS — awg-quick ищет resolvconf. Убери DNS из [Interface]"
  else
    warn "Причина не распознана — смотри вывод выше и dmesg | tail -20"
  fi
}

awg_up_diag() {
  local out rc=0
  out=$(awg-quick up "$SERVER_CONF" 2>&1) || rc=$?
  if (( rc != 0 )) && [[ "$out" == *"already exists"* ]] && iface_up; then
    awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
    rc=0; out=$(awg-quick up "$SERVER_CONF" 2>&1) || rc=$?
  fi
  (( rc == 0 )) && { log_info "awg0 поднят"; return 0; }
  log_err "awg-quick up rc=$rc: $(tr '\n' ';' <<< "$out")"
  echo -e "  ${D}── awg-quick up ──${N}"
  sed 's/^/  │ /' <<< "$out"
  awg_diagnose_up "$out"
  return "$rc"
}

setup_autostart() {
  mkdir -p "$AUTOSTART_DROPIN"
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/awg-quick up awg0\n' \
    | write_file "$AUTOSTART_DROPIN/override.conf" 644
  systemctl daemon-reload
  systemctl enable awg-quick@awg0 &>/dev/null || warn "Не удалось включить автозапуск awg0"
  mod_autoload
}

# ── Запись конфигов ───────────────────────────────────────
# Параметры создаваемого сервера (заполняются меню или --auto).
S_PROFILE=lite S_PROTO=2.0 S_REGION=world S_DNS="1.1.1.1, 1.0.0.1" MTU=1280
S_NET="" S_PORT="" S_ENDPOINT_DOMAIN="" S_FIRST_CLIENT=""

_postup_lines() {
  local net="$1" dev="$2"
  echo "PostUp = echo 1 > /proc/sys/net/ipv4/ip_forward; iptables -t nat -C POSTROUTING -s $net -o $dev -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $net -o $dev -j MASQUERADE; iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o awg0 -j ACCEPT"
  echo "PostDown = iptables -t nat -D POSTROUTING -s $net -o $dev -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true"
}

# Клиентский конфиг. $1 файл, $2 приватный ключ, $3 адрес, $4 psk, $5 DNS, $6 MTU.
write_client_conf() {
  local f="$1" priv="$2" addr="$3" psk="$4" dns="$5" mtu="$6" srv_pub
  srv_pub=$(conf_iface_get PrivateKey | awg pubkey) || return 1
  {
    echo "[Interface]"
    echo "PrivateKey = $priv"
    echo "Address = $addr"
    echo "DNS = $dns"
    echo "MTU = $mtu"
    server_params
    i_lines_block
    echo ""
    echo "[Peer]"
    echo "PublicKey = $srv_pub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $(endpoint_host):$(server_port)"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = $(keepalive_for "$(server_proto)")"
  } | write_file "$f" 600
}

# Умеют ли модуль и tools AWG 3.1, когда сервера ещё нет. Проверка создаёт
# пробный интерфейс, а бот спрашивает сводку раз в минуту — ответ помнится до
# смены модуля или tools. «Не подтверждено» (модуль не загружен) не помнится.
proto31_cached() {
  local f="$STATE_DIR/proto31" bin key k v rc=0
  bin=$(command -v awg) || return 1
  key="$(mod_tag)|$(stat -c %s:%Y "$bin" 2>/dev/null)|$(cat "/sys/module/$MOD_NAME/srcversion" 2>/dev/null)"
  if [[ -f "$f" ]] && IFS=$'\t' read -r k v < "$f" && [[ "$k" == "$key" && "$v" =~ ^[01]$ ]]; then
    _PROTO_PROBE[31]=$v           # proto_upgrade_hint в том же вызове не пробует заново
    return "$v"
  fi
  proto_supported 3.1 || rc=$?
  (( rc == 2 )) || { mkdir -p "$STATE_DIR" && printf '%s\t%s\n' "$key" "$rc" > "$f"; } 2>/dev/null
  return "$rc"
}

# Внешний интерфейс в правиле NAT awg0.conf — аплинк, на котором создан сервер.
conf_uplink() {
  [[ -f "$SERVER_CONF" ]] || return 1
  sed -nE 's/^PostUp *=.*POSTROUTING -s [^ ]+ -o ([^ ]+) -j MASQUERADE.*/\1/p' "$SERVER_CONF" | head -1 | grep .
}

# Сервер восстановлен на другом VPS (или интерфейс переименован): у аплинка
# другое имя (ens3 вместо eth0) — клиенты подключаются, но без NAT остаются
# без интернета. Правило NAT в PostUp/PostDown переводится на аплинк этого
# сервера. Для «Проверить и починить» — только если прежнего интерфейса здесь
# нет: есть — значит NAT через него выбран сознательно (второй аплинк,
# туннель). Восстановление бэкапа (force) переносит всегда: интерфейс с тем
# же именем на новом VPS может быть совсем другим (приватный eth0). Поднятый
# awg0 опускается до правки — его PostDown снимает старое правило NAT, иначе
# оно оставалось в iptables — и поднимается снова. 0 — awg0.conf поправлен.
conf_uplink_sync() {  # [force]
  local old dev up=0 rc=0
  old=$(conf_uplink) || return 1
  dev=$(uplink_iface) || return 1
  [[ "$old" != "$dev" ]] || return 1
  [[ "${1:-}" != force ]] && ip link show "$old" &>/dev/null && return 1
  if iface_up; then
    up=1
    awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  fi
  sed -i -E "/^Post(Up|Down) *=/ s#(POSTROUTING -s [^ ]+ -o )${old//./\\.}( -j MASQUERADE)#\1$dev\2#g" "$SERVER_CONF" \
    && [[ "$(conf_uplink)" == "$dev" ]] || rc=1
  (( up )) && { awg_up_diag || rc=1; }
  (( rc )) && return 1
  info "Внешний интерфейс сервера: $old → $dev (NAT в $SERVER_CONF)"
  log_info "NAT awg0: $old → $dev"
}

# Создаёт awg0.conf и первого клиента из S_* и выбранной мимикрии.
server_write() {
  local net="$S_NET" base srv_priv cli_priv psk dev
  base="${net%.*}"
  dev=$(uplink_iface) || { err "Не найден интерфейс маршрута по умолчанию"; return 1; }
  gen_awg_params "$S_PROFILE" "$S_PROTO" || return 1
  srv_priv=$(awg genkey); cli_priv=$(awg genkey); psk=$(awg genpsk)
  mkdir -p "$AWG_DIR" && chmod 700 "$AWG_DIR"
  {
    echo "# AWG_PROFILE=$S_PROFILE"
    echo "# AmneziaWG Toolza — AWG $S_PROTO server config"
    echo "# Region: $S_REGION"
    echo "# AWG_PROTO=$S_PROTO"
    echo "# AWG_OBF_LEVEL=$OBF_LEVEL"
    echo "# AWG_CPS_BUDGET=$CPS_BUDGET"
    echo "# AWG_MIMICRY=$MIMICRY"
    [[ -n "$CPS_DOMAIN" && "$MIMICRY" != none ]] && echo "# AWG_MIMICRY_DOMAIN=$CPS_DOMAIN"
    [[ -n "$S_ENDPOINT_DOMAIN" ]] && echo "# AWG_ENDPOINT=$S_ENDPOINT_DOMAIN"
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = ${base}.1/24"
    echo "ListenPort = $S_PORT"
    echo "MTU = $MTU"
    echo "$AWG_PARAMS"
    echo ""
    _postup_lines "$net" "$dev"
    echo ""
    echo "[Peer]"
    echo "# $S_FIRST_CLIENT"
    echo "# mimicry=$(mimicry_tag)"
    echo "PublicKey = $(awg pubkey <<< "$cli_priv")"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = ${base}.2/32"
  } | write_file "$SERVER_CONF" 600
  write_client_conf "$(client_file "$S_FIRST_CLIENT")" "$cli_priv" "${base}.2/32" "$psk" "$S_DNS" "$MTU"
}

# Поднять созданный сервер, открыть порт, включить автозапуск.
server_start_new() {
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  awg_up_diag || return 1
  if ufw_active; then
    ufw_allow "$S_PORT/udp" AmneziaWG && ok "UFW: открыт $S_PORT/udp"
    if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw 2>/dev/null; then
      sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
      ufw reload &>/dev/null || true
      info "UFW: DEFAULT_FORWARD_POLICY=ACCEPT (нужно для выхода клиентов в интернет)"
    fi
  fi
  setup_autostart
  expire_install
  log_info "сервер создан: AWG $S_PROTO, профиль $S_PROFILE, порт $S_PORT"
}

pick_awg_net() { taken_networks | py pick-net awg; }

# ── Создание сервера (меню) ───────────────────────────────
_choose_dns() {
  local c d
  echo -e "  ${C}1)${N} Cloudflare ${D}1.1.1.1${N}"
  echo -e "  ${C}2)${N} Google ${D}8.8.8.8${N}"
  echo -e "  ${C}3)${N} Quad9 ${D}9.9.9.9${N}"
  echo -e "  ${C}4)${N} Яндекс ${D}77.88.8.8${N}"
  echo -e "  ${C}5)${N} Вручную"
  read_choice c "${C}  DNS клиентов [1-5] (Enter = 1): ${N}" 1 5 1
  case "$c" in
    1) S_DNS="1.1.1.1, 1.0.0.1" ;; 2) S_DNS="8.8.8.8, 8.8.4.4" ;;
    3) S_DNS="9.9.9.9, 149.112.112.112" ;; 4) S_DNS="77.88.8.8, 77.88.8.1" ;;
    5) while true; do
         read_line d "${C}  DNS через запятую: ${N}"
         [[ -n "$d" ]] || { S_DNS="1.1.1.1, 1.0.0.1"; break; }
         valid_dns_list "$d" && { S_DNS="$d"; break; }
         warn "Нужны IPv4-адреса через запятую"
       done ;;
  esac
}

_choose_mtu() {  # $1 — значение по умолчанию
  local c v i opts=("$1")
  # Рекомендуемое — первым, остальные стандартные без повтора
  for v in 1420 1380 1320 1280; do [[ "$v" == "$1" ]] || opts+=("$v"); done
  echo ""
  hdr "MTU"
  for i in "${!opts[@]}"; do
    echo -e "  ${C}$((i + 1)))${N} ${opts[$i]}$( (( i == 0 )) && echo -e " ${C}(рекомендуется)${N}")"
  done
  echo -e "  ${C}$(( ${#opts[@]} + 1 )))${N} Вручную"
  read_choice c "${C}  MTU [1-$(( ${#opts[@]} + 1 ))] (Enter = 1): ${N}" 1 $(( ${#opts[@]} + 1 )) 1
  if (( c <= ${#opts[@]} )); then
    MTU=${opts[$((c - 1))]}
  else
    while true; do
      read_line v "${C}  MTU (1280-1500): ${N}"
      [[ -n "$v" ]] || { MTU=$1; break; }
      [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1280 && v <= 1500 )) && { MTU=$v; break; }
      warn "Число 1280-1500"
    done
  fi
}

# Версия протокола нового сервера. 3.1 по умолчанию, если компоненты её умеют.
_choose_proto() {
  local c def=2 rc=0
  proto_supported 3.1 || rc=$?
  echo ""
  hdr "Версия протокола"
  echo -e "  ${G}1${N} AWG 2.0 ${D}— любой клиент AmneziaWG${N}"
  echo -e "  ${G}2${N} AWG 3.1 ${D}— быстрее, заголовки под шифром${N}"
  echo -e "  ${Y}  Версия на весь сервер. Для 3.1 нужен AmneziaVPN 5.0.1.5+ / AmneziaWG с 3.1.${N}"
  if (( rc == 1 )); then
    def=1
    warn "Установленные модуль/tools не умеют 3.1 — Сервер → Модуль ядра → обновить"
  fi
  read_choice c "${C}  Выбор [1-2] (Enter = $def): ${N}" 1 2 "$def"
  if [[ "$c" == 2 ]]; then
    if (( rc == 1 )); then
      ask_yes "  Обновить модуль и tools сейчас? [Y/n]: " y || { S_PROTO=2.0; return 0; }
      mod_update_flow && tools_update_flow
      proto_supported 3.1 || { err "3.1 по-прежнему не поддерживается — остаюсь на 2.0"; S_PROTO=2.0; return 0; }
    fi
    S_PROTO=3.1
  else
    S_PROTO=2.0
  fi
}

# Регион — явным выбором, как в боте и панели: «Сервер в России? [y/N]»
# с Enter уходил дальше молча, и было непонятно, что выбрано.
_choose_region() {
  local c
  echo -e "  ${W}Где сервер${N}"
  echo -e "  ${G}1${N} Европа / мир"
  echo -e "  ${G}2${N} Россия"
  echo -e "  ${D}    мимикрия берёт домены, привычные для страны сервера${N}"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 2 ]]; then S_REGION=ru; else S_REGION=world; fi
  ok "Регион: $([[ "$S_REGION" == ru ]] && echo "Россия" || echo "Европа / мир")"
}

_choose_profile() {
  local c
  echo ""
  hdr "Профиль"
  echo -e "  ${G}1${N} AmneziaVPN ${C}(рекомендуется)${N}"
  echo -e "  ${D}    как официальный клиент: MTU 1280, без I1-I5${N}"
  echo -e "  ${G}2${N} Мощный"
  echo -e "  ${D}    широкие диапазоны и I1-I5, сильнее против DPI${N}"
  echo -e "  ${D}0 назад${N}"
  read_choice c "${C}  Выбор [0-2] (Enter = 1): ${N}" 0 2 1
  case "$c" in
    0) return 1 ;;
    1) S_PROFILE=lite; MIMICRY=none; OBF_LEVEL=1; CPS_BUDGET=0; CPS_DOMAIN=""; I_LINES=()
       # Один компактный I1 (DNS) — только по согласию: у официальной Amnezia строк I нет
       if ask_yes "  Добавить один компактный пакет мимикрии I1 (DNS, ~90 симв)? [y/N]: " n; then
         OBF_LEVEL=2; MIMICRY=dns
         choose_cps_domain
         gen_chain dns "$CPS_DOMAIN" --only-i1 || { MIMICRY=none; OBF_LEVEL=1; }
       fi ;;
    2) S_PROFILE=pro
       choose_and_gen_chain || return 1 ;;
  esac
}

_choose_net() {
  local c v
  echo -e "  ${C}1)${N} Случайная 10.x.y.0/24 ${C}(рекомендуется)${N}"
  echo -e "  ${C}2)${N} Вручную"
  read_choice c "${C}  Подсеть [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    S_NET=$(pick_awg_net) || { err "Не нашёл свободную /24"; return 1; }
    return 0
  fi
  while true; do
    read_line v "${C}  Подсеть вида 10.8.0.0/24 (Enter — случайная): ${N}"
    # Пусто (Enter или Ctrl+D) — как пункт 1, а не обрыв мастера и не повтор
    if [[ -z "$v" ]]; then
      S_NET=$(pick_awg_net) || { err "Не нашёл свободную /24"; return 1; }
      info "Подсеть: $S_NET"
      return 0
    fi
    if valid_cidr "$v" && [[ "${v#*/}" == 24 ]]; then
      v="${v%.*}.0/24"
      if taken_networks | py net-overlaps "$v" >/dev/null; then
        warn "Пересекается с адресами или маршрутами сервера"
      else
        S_NET="$v"; return 0
      fi
    else
      warn "Нужна сеть /24, например 10.8.0.0/24"
    fi
  done
}

_choose_port() {
  local v
  while true; do
    read_line v "${C}  UDP-порт [Enter = случайный]: ${N}"
    v="${v// /}"
    if [[ -z "$v" ]]; then S_PORT=$(random_free_udp_port) || return 1; return 0; fi
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1024 && v <= 65535 )); then
      udp_port_busy "$v" && { warn "Порт $v занят"; continue; }
      S_PORT=$v; return 0
    fi
    warn "Порт — число 1024-65535"
  done
}

_choose_endpoint() {
  local d
  S_ENDPOINT_DOMAIN=""
  ask_yes "  Использовать в конфигах домен вместо IP (переезд без перевыдачи)? [y/N]: " n || return 0
  while true; do
    read_line d "${C}  Домен (Enter — отмена): ${N}"
    d="${d// /}"
    [[ -z "$d" ]] && return 0
    valid_domain "$d" && break
    warn "Нужно имя вида vpn.example.com"
  done
  domain_points_here "$d" || ask_yes "  Всё равно использовать? [y/N]: " n || return 0
  S_ENDPOINT_DOMAIN="$d"
}

# Можно ли создавать сервер. Предупреждение о перезагрузке — в REBOOT_WHY.
REBOOT_WHY=""
server_create_ready() {
  command -v awg &>/dev/null || { err "Компоненты не установлены — Сервер → Установить компоненты"; return 1; }
  if server_exists; then
    err "Сервер уже создан (профиль $(profile_label), AWG $(server_proto))"
    info "Сменить версию или параметры: Сервер → Протокол; всё заново — сброс сервера"
    return 1
  fi
  REBOOT_WHY=$(reboot_reason)
  if [[ "$REBOOT_WHY" == *modprobe* ]]; then modprobe "$MOD_NAME" 2>/dev/null; REBOOT_WHY=$(reboot_reason); fi
  if [[ "$REBOOT_WHY" == *"не собран"* ]]; then
    err "Модуль не собран под работающее ядро $(uname -r) — Сервер → Установить компоненты"
    return 1
  fi
  return 0
}

# Создание из S_* и выбранной мимикрии.
server_create() {
  server_write || return 1
  if ! server_start_new; then
    err "Сервер не поднялся — конфиг сохранён: $SERVER_CONF"
    return 1
  fi
  success_box "Сервер создан: AWG $S_PROTO, клиент $S_FIRST_CLIENT"
  echo "Файл конфигурации: $(client_file "$S_FIRST_CLIENT")"
  mimicry_module_warnings
}

# Создание без вопросов: server_create_opts ключ=значение...
#   profile=lite|pro  proto=2.0|3.1  region=world|ru  dns="1.1.1.1, 1.0.0.1"
#   mtu=  port=  net=10.x.y.0/24  endpoint=домен  client=имя  mimicry=строка
# Не заданное — как у «AmneziaVPN»: версия 3.1, если компоненты её умеют.
server_create_opts() {
  local kv k v mim=""
  server_create_ready || return 1
  [[ -n "$REBOOT_WHY" ]] && warn "$REBOOT_WHY"
  S_PROFILE=lite; S_PROTO=""; S_REGION=world; S_DNS="1.1.1.1, 1.0.0.1"; MTU=""
  S_PORT=""; S_NET=""; S_ENDPOINT_DOMAIN=""; S_FIRST_CLIENT=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      profile) [[ "$v" =~ ^(lite|pro)$ ]] || { err "profile: lite | pro"; return 1; }; S_PROFILE="$v" ;;
      proto) [[ "$v" =~ ^(2\.0|3\.1)$ ]] || { err "proto: 2.0 | 3.1"; return 1; }; S_PROTO="$v" ;;
      region) [[ "$v" =~ ^(world|ru)$ ]] || { err "region: world | ru"; return 1; }; S_REGION="$v" ;;
      dns) valid_dns_list "$v" || { err "dns: IPv4 через запятую"; return 1; }; S_DNS="$v" ;;
      mtu) [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1280 && v <= 1500 )) || { err "mtu: 1280-1500"; return 1; }; MTU="$v" ;;
      port) valid_port "$v" && (( v >= 1024 )) || { err "port: 1024-65535"; return 1; }
            udp_port_busy "$v" && { err "UDP $v занят"; return 1; }; S_PORT="$v" ;;
      net) valid_cidr "$v" && [[ "${v#*/}" == 24 ]] || { err "net: сеть /24"; return 1; }
           v="${v%.*}.0/24"
           taken_networks | py net-overlaps "$v" >/dev/null && { err "Сеть $v пересекается с адресами сервера"; return 1; }
           S_NET="$v" ;;
      endpoint) [[ -z "$v" ]] || valid_domain "$v" || { err "endpoint: домен"; return 1; }; S_ENDPOINT_DOMAIN="${v,,}" ;;
      client) _name_free "$v" || { err "Имя клиента недопустимо"; return 1; }; S_FIRST_CLIENT="$v" ;;
      mimicry) mim="$v" ;;
      *) err "Неизвестный параметр: $k"; return 1 ;;
    esac
  done
  if [[ -z "$S_PROTO" ]]; then
    if proto_supported 3.1; then S_PROTO=3.1; else S_PROTO=2.0; fi
  elif [[ "$S_PROTO" == 3.1 ]] && ! proto_supported 3.1; then
    err "Модуль или tools не умеют AWG 3.1 — обнови их (Сервер → Модуль ядра) или выбери 2.0"
    return 1
  fi
  [[ -n "$MTU" ]] || { [[ "$S_PROFILE" == pro ]] && MTU=1320 || MTU=1280; }
  [[ -n "$mim" ]] || { [[ "$S_PROFILE" == pro ]] && mim="dns:3" || mim=none; }
  [[ -n "$S_NET" ]] || S_NET=$(pick_awg_net) || { err "Нет свободной подсети"; return 1; }
  [[ -n "$S_PORT" ]] || S_PORT=$(random_free_udp_port) || { err "Нет свободного UDP-порта"; return 1; }
  [[ -n "$S_FIRST_CLIENT" ]] || S_FIRST_CLIENT=$(rand_name)
  mimicry_from_spec "$mim" || return 1
  server_create
}

do_create_server() {
  if ! server_create_ready; then return 1; fi
  if [[ -n "$REBOOT_WHY" ]]; then
    warn "$REBOOT_WHY"
    ask_yes "  Продолжить без перезагрузки? [y/N]: " n || return 0
  fi

  echo ""
  hdr "Создание сервера"
  _choose_region
  echo ""
  hdr "DNS клиентов"
  _choose_dns
  _choose_profile || return 0
  if [[ "$S_PROFILE" == lite ]]; then _choose_mtu 1280; else _choose_mtu 1320; fi
  _choose_proto
  _choose_net || return 1
  _choose_port || { err "Нет свободного UDP-порта"; return 1; }
  _choose_endpoint
  S_FIRST_CLIENT=$(rand_name)

  echo ""
  hdr "Итог"
  echo -e "  Версия   : ${W}AWG $S_PROTO${N}, профиль ${W}$(profile_label "$S_PROFILE")${N}"
  echo -e "  Мимикрия : ${W}$MIMICRY${N}${CPS_DOMAIN:+ ($CPS_DOMAIN)}"
  echo -e "  Подсеть  : ${W}$S_NET${N}, MTU ${W}$MTU${N}, DNS ${W}$S_DNS${N}"
  echo -e "  Endpoint : ${W}${S_ENDPOINT_DOMAIN:-$(public_ip_cached)}:$S_PORT${N}"
  ask_yes "  Создать? [Y/n]: " y || { info "Отменено"; return 0; }
  server_create && share_config "$(client_file "$S_FIRST_CLIENT")"
}

# Неинтерактивная установка: компоненты, сервер и client1.
# Переменные окружения: AWG_PROFILE=lite|pro, AWG_PROTO=2.0|3.1, AWG_PORT.
do_autoinstall() {
  AUTO_MODE=1
  command -v awg &>/dev/null || do_install || exit 1
  if server_exists; then
    warn "Сервер уже создан — вывожу конфиг client1"
    [[ -f "$(client_file client1)" ]] && cat "$(client_file client1)"
    return 0
  fi
  local opts=(client=client1)
  [[ "${AWG_PROFILE:-}" == pro ]] && opts+=(profile=pro)
  [[ -n "${AWG_PROTO:-}" ]] && opts+=("proto=$AWG_PROTO")
  [[ -n "${AWG_PORT:-}" ]] && opts+=("port=$AWG_PORT")
  server_create_opts "${opts[@]}" || exit 1
  cat "$(client_file client1)"
}

# Перезагрузка через 5 секунд: вызвавший (бот) успевает получить ответ.
server_reboot() {
  systemd-run --on-active=5 --unit=awg2-reboot --collect /bin/systemctl reboot &>/dev/null \
    || { err "systemd-run не сработал"; return 1; }
  log_warn "перезагрузка сервера"
  ok "Сервер перезагрузится через 5 секунд"
}

# ── Перезапуск и ремонт ───────────────────────────────────
do_restart() {
  server_exists || { err "Сервер не создан"; return 1; }
  info "Перезапуск awg0..."
  server_restart && ok "awg0 перезапущен"
}

REPAIR_ISSUES=0 REPAIR_FIXED=0
_issue() { REPAIR_ISSUES=$((REPAIR_ISSUES + 1)); warn "$1"; }
_fixed() { REPAIR_FIXED=$((REPAIR_FIXED + 1)); ok "$1"; }

do_repair() {
  local bad conf_n live_n dev net perm rc old
  REPAIR_ISSUES=0 REPAIR_FIXED=0
  echo ""
  hdr "Проверка и ремонт"

  if mod_loaded; then ok "Модуль загружен"
  else
    _issue "Модуль не загружен"
    if modprobe "$MOD_NAME" 2>/dev/null; then _fixed "modprobe amneziawg"
    elif secure_boot_on; then err "Secure Boot отвергает неподписанный модуль"
    elif command -v dkms &>/dev/null && ensure_headers "$(uname -r)" \
         && run_step "Пересборка модуля под $(uname -r)" _mod_dkms_install_all \
         && modprobe "$MOD_NAME" 2>/dev/null; then _fixed "Модуль пересобран и загружен"
    else err "Не удалось — Сервер → Модуль ядра"; fi
  fi
  mod_stale && _issue "В памяти прежняя сборка модуля — Сервер → Модуль ядра → перезагрузить модуль"
  if [[ -n "$(kernel_gap)" ]]; then
    _issue "Ядро $(kernel_gap_line) без модуля AWG — после перезагрузки awg0 не поднимется"
    mod_rebuild_all && _fixed "Модуль собран под все ядра"
  fi
  if grep -qs "^$MOD_NAME" "$MODULES_LOAD_FILE"; then ok "Автозагрузка модуля"
  else _issue "Нет автозагрузки модуля"; mod_autoload && _fixed "Автозагрузка настроена"; fi

  server_exists || { err "Сервер не создан"; return 1; }
  if [[ -z "$(conf_marker AWG_OBF_LEVEL)" ]]; then
    # Бот по этой метке решает, сколько пакетов I1-I5 выдать клиенту
    if grep -qsE '^I[2-5] = ' "$CLIENT_DIR"/*_awg[23].conf; then conf_marker_set AWG_OBF_LEVEL 3
    elif grep -qsE '^I1 = ' "$CLIENT_DIR"/*_awg[23].conf; then conf_marker_set AWG_OBF_LEVEL 2; fi
    [[ -n "$(conf_marker AWG_OBF_LEVEL)" ]] && ok "Восстановлена метка AWG_OBF_LEVEL по конфигам клиентов"
  fi
  bad=$(conf_hp_min_s_violations)
  [[ -n "$bad" ]] && _issue "S ниже $AWG_HP_MIN_S при защите заголовков: $bad — Сервер → Протокол и параметры"
  if [[ "$(server_proto)" == 3* ]]; then
    rc=0; proto_supported "$(server_proto)" || rc=$?
    (( rc == 1 )) && _issue "Сервер на AWG $(server_proto), а компоненты её не умеют — Сервер → Модуль ядра"
  fi
  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]]; then ok "IP forwarding"
  else _issue "IP forwarding выключен"; ip_forward_enable && _fixed "IP forwarding включён"; fi

  if ! iface_up; then
    _issue "awg0 не поднят"
    awg_up_diag && _fixed "awg0 поднят"
  else
    conf_n=$(grep -c '^\[Peer\]' "$SERVER_CONF" || true)
    live_n=$(awg show "$AWG_IF" peers 2>/dev/null | wc -l)
    if [[ "$conf_n" != "$live_n" ]]; then
      _issue "Пиров в конфиге $conf_n, в ядре $live_n"
      server_restart && _fixed "awg0 перезапущен"
    else ok "awg0 работает, пиров: $live_n"; fi
  fi
  dev=$(uplink_iface || true); net=$(server_net || true)
  old=$(conf_uplink || true)
  if [[ -n "$dev" && -n "$old" && "$old" != "$dev" ]]; then
    if ip link show "$old" &>/dev/null; then
      info "NAT в awg0.conf — на $old (маршрут по умолчанию — через $dev): оставляю как настроено"
    else
      _issue "NAT в awg0.conf — на $old, такого интерфейса нет; выход сервера — $dev"
      conf_uplink_sync && _fixed "NAT перенесён на $dev"
    fi
  fi
  # NAT проверяется на интерфейсе из awg0.conf: выбранный сознательно не
  # перебивается правилом на аплинк по умолчанию
  old=$(conf_uplink || true); [[ -n "$old" ]] && ip link show "$old" &>/dev/null && dev="$old"
  if [[ -n "$dev" && -n "$net" ]]; then
    if iptables -t nat -C POSTROUTING -s "$net" -o "$dev" -j MASQUERADE 2>/dev/null; then ok "NAT на $dev"
    else _issue "Нет NAT для $net на $dev"; ipt_add -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE && _fixed "NAT добавлен"; fi
  fi
  perm=$(stat -c %a "$SERVER_CONF")
  [[ "$perm" == 600 ]] || { _issue "Права $SERVER_CONF = $perm"; chmod 600 "$SERVER_CONF" && _fixed "Права 600"; }
  perm=$(stat -c %a "$AWG_DIR")
  [[ "$perm" == 700 ]] || { _issue "Права $AWG_DIR = $perm"; chmod 700 "$AWG_DIR" && _fixed "Права 700"; }
  unit_enabled awg-quick@awg0 || { _issue "Нет автозапуска awg0"; setup_autostart && _fixed "Автозапуск включён"; }

  echo ""
  if (( REPAIR_ISSUES == 0 )); then success_box "Всё в порядке"
  elif (( REPAIR_FIXED == REPAIR_ISSUES )); then success_box "Найдено проблем: $REPAIR_ISSUES, все исправлены"
  else warn "Найдено проблем: $REPAIR_ISSUES, исправлено: $REPAIR_FIXED"; fi
}

# ── Протокол и параметры ──────────────────────────────────
# Предупреждения про модуль, влияющие на мимикрию I1-I5.
mimicry_module_warnings() {
  local n=0
  if [[ "$(server_proto)" == 3.1 ]] && grep -qsE '^I1 = ' "$CLIENT_DIR"/*_awg3.conf; then
    mod_trailer_fix || { [[ $? -eq 1 ]] && warn "Модуль дописывает хвост к I1-I5 — мимикрия слабее. Обнови модуль (Сервер → Модуль ядра)"; }
  fi
  # Длина цепочки — по каждому файлу отдельно, берём наибольшую.
  n=$(awk -F' = ' 'FNR == 1 {if (NR > 1) print n; n = 0} /^I[1-5] = /{n += length($2)} END{print n+0}' \
        "$CLIENT_DIR"/*_awg[23].conf 2>/dev/null | sort -n | tail -1)
  (( ${n:-0} > 3598 )) && warn "Цепочка I1-I5 длиннее $n симв — выше предела awg-tools (буфер 4 КБ)"
  return 0
}

# Подсказка для шапки: предложить переход на 3.1.
proto_upgrade_hint() {
  server_exists || return 0
  [[ "$(server_proto)" == 3.1 ]] && return 0
  if proto_supported 3.1; then
    echo -e "${G}⬆ доступен переход на AWG 3.1${N} ${D}— Сервер → Протокол${N}"
  else
    echo -e "${Y}для AWG 3.1 обнови модуль${N} ${D}— Сервер → Модуль ядра${N}"
  fi
}

# Снимок конфигов сервера и клиентов — откат, если awg0 не поднимется.
_params_snapshot() {  # ПЕРЕМЕННАЯ
  local __d f
  mktmp __d -d || return 1
  mkdir -p "$__d/clients"
  cp -a "$SERVER_CONF" "$__d/"
  while read -r f; do cp -a "$f" "$__d/clients/"; done < <(client_files)
  printf -v "$1" '%s' "$__d"
}

_params_restore() {  # КАТАЛОГ_СНИМКА
  err "awg0 не поднялся с новыми параметрами — возвращаю прежние"
  cp -a "$1/${SERVER_CONF##*/}" "$SERVER_CONF"
  rm -f "$CLIENT_DIR"/*_awg[23].conf
  cp -a "$1/clients/." "$CLIENT_DIR/"
  server_restart && ok "Прежняя конфигурация восстановлена"
}

# Перегенерация параметров обфускации с переходом на версию $1.
# Ключи, адреса, имена, сроки и I1-I5 сохраняются. Все клиенты получают
# новые конфиги — старые перестают подключаться.
server_regen_params() {
  local target="$1" cur profile snap f n=0 ka
  cur=$(server_proto)
  profile=$(server_profile)
  if [[ "$target" == 3* ]]; then
    local rc=0
    proto_supported "$target" || rc=$?
    if (( rc == 1 )); then
      warn "Установленные модуль или tools не умеют AWG $target"
      ask_yes "  Обновить компоненты сейчас? [Y/n]: " y || return 1
      mod_update_flow || return 1
      tools_update_flow || return 1
      proto_supported "$target" || { err "AWG $target всё ещё не поддерживается"; return 1; }
    fi
  fi

  auto_backup regen || warn "Авто-бэкап не удался"
  _params_snapshot snap || return 1

  MTU=$(conf_iface_get MTU)
  gen_awg_params "$profile" "$target" || return 1
  py params-replace "$SERVER_CONF" <<< "$AWG_PARAMS" || { err "Не удалось обновить $SERVER_CONF"; return 1; }
  [[ -n "$MTU" && "$MTU" != "$(conf_iface_get MTU)" ]] && sed -i "s/^MTU = .*/MTU = $MTU/" "$SERVER_CONF"
  conf_marker_set AWG_PROTO "$target"
  sed -i "s/^# AmneziaWG Toolza — AWG .* server config/# AmneziaWG Toolza — AWG $target server config/" "$SERVER_CONF"
  ka=$(keepalive_for "$target")
  while read -r f; do
    py params-replace "$f" <<< "$AWG_PARAMS" && py keepalive-set "$f" "$ka" && n=$((n + 1))
  done < <(client_files)
  client_files_sync_suffix

  # Параметры [Interface] syncconf не применяет — только down/up.
  server_restart || { _params_restore "$snap"; return 1; }
  log_info "параметры перегенерированы: $cur → $target, клиентов $n"
  success_box "AWG $target: параметры обновлены, клиентов $n"
  warn "Каждому клиенту нужен новый конфиг — до замены он не подключится"
  (( n > 0 )) && info "Все конфиги архивом: Клиенты → Экспорт; по одному — QR/текст или бот"
  [[ "$target" == 3.1 && "$cur" != 3.1 ]] && info "Клиентам нужен AmneziaVPN 5.0.1.5+ или AmneziaWG с поддержкой 3.1"
  mimicry_module_warnings
}

# ── Параметры вручную ─────────────────────────────────────
# Правки «Ключ=значение» поверх текущих параметров. Проверка — py params-check
# (пределы генератора); итог — в PARAMS_*: KEYS «ключ<TAB>значение» после
# правок, ERR и WARN построчно, CHANGED и BREAKING — ключи (BREAKING обязаны
# совпадать у клиентов), NEW — новый блок параметров.
PARAMS_KEYS="" PARAMS_ERR="" PARAMS_WARN="" PARAMS_CHANGED="" PARAMS_BREAKING="" PARAMS_NEW="" PARAMS_CLIENTS=0
params_check() {
  local out
  out=$(server_params | py params-check "$(server_proto)" "$(conf_iface_get MTU)" "$@") || return 1
  PARAMS_KEYS=$(sed -n 's/^K\t//p' <<< "$out")
  PARAMS_ERR=$(sed -n 's/^E\t//p' <<< "$out")
  PARAMS_WARN=$(sed -n 's/^W\t//p' <<< "$out")
  PARAMS_CHANGED=$(sed -n 's/^C\t//p' <<< "$out")
  PARAMS_BREAKING=$(sed -n 's/^B\t//p' <<< "$out")
  PARAMS_NEW=$(sed -n 's/^P\t//p' <<< "$out")
}

# Новый блок — в сервер и всех клиентов (как при перегенерации: у клиентов те
# же значения), рестарт; awg0 не поднялся — откат.
params_edit_apply() {
  local snap f n=0 keys
  auto_backup params || warn "Авто-бэкап не удался"
  _params_snapshot snap || return 1
  py params-replace "$SERVER_CONF" <<< "$PARAMS_NEW" || { err "Не удалось обновить $SERVER_CONF"; return 1; }
  while read -r f; do
    py params-replace "$f" <<< "$PARAMS_NEW" && n=$((n + 1))
  done < <(client_files)
  server_restart || { _params_restore "$snap"; return 1; }
  PARAMS_CLIENTS=$n
  keys=$(tr '\n' ' ' <<< "$PARAMS_CHANGED"); keys="${keys% }"
  log_info "параметры изменены вручную: $keys; клиентов $n"
  success_box "Параметры AWG обновлены: ${keys// /, }"
  if [[ -n "$PARAMS_BREAKING" ]]; then
    keys=$(tr '\n' ' ' <<< "$PARAMS_BREAKING"); keys="${keys% }"
    warn "${keys// /, } обязаны совпадать у клиентов — каждому нужен новый конфиг, до замены он не подключится"
    (( n > 0 )) && info "Все конфиги архивом: Клиенты → Экспорт; по одному — QR/текст или бот"
  else
    info "Старые конфиги продолжают работать; новые значения клиент получит с новым конфигом ($n)"
  fi
}

# awg2 api server params set [force] ПРАВКА... — предупреждения без force
# не пропускает: бот и панель сперва показывают их человеку (params check).
server_params_set() {
  local force=0 l
  [[ "${1:-}" == force ]] && { force=1; shift; }
  server_exists || { err "Сервер не создан"; return 1; }
  (( $# )) || { err "Нет правок: Ключ=значение"; return 1; }
  params_check "$@" || return 1
  if [[ -n "$PARAMS_ERR" ]]; then
    while IFS= read -r l; do err "$l"; done <<< "$PARAMS_ERR"
    return 1
  fi
  [[ -n "$PARAMS_CHANGED" ]] || { ok "Параметры не изменились"; return 0; }
  if [[ -n "$PARAMS_WARN" ]]; then
    while IFS= read -r l; do warn "$l"; done <<< "$PARAMS_WARN"
    (( force )) || { err "Есть предупреждения — чтобы сохранить всё равно, добавь force"; return 1; }
  fi
  params_edit_apply
}

do_params_edit_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  local -a edits=() keys=() vals=()
  local c i k v n mark l proto
  proto=$(server_proto)
  while true; do
    params_check "${edits[@]}" || return 1
    keys=(); vals=()
    while IFS=$'\t' read -r k v; do keys+=("$k"); vals+=("$v"); done <<< "$PARAMS_KEYS"
    n=${#keys[@]}
    echo ""
    hdr "Параметры AWG $proto вручную"
    echo -e "  ${D}S и H обязаны совпадать у сервера и клиентов: после их правки старые конфиги${N}"
    echo -e "  ${D}не подключатся. Jc/Jmin/Jmax и таймеры 3.x — не обязаны.${N}"
    for (( i = 0; i < n; i++ )); do
      mark=""
      grep -qx "${keys[i]}" <<< "$PARAMS_CHANGED" && mark=" ${Y}← изменён${N}"
      printf "  ${C}%2d)${N} %-22s %s%b\n" $((i + 1)) "${keys[i]}" "${vals[i]:-—}" "$mark"
    done
    echo -e "  ${G}$((n + 1)))${N} Проверить и применить"
    echo -e "  ${W} 0)${N} ← Назад ${D}(правки не сохраняются)${N}"
    read_choice c "${C}  Выбор [0-$((n + 1))]: ${N}" 0 $((n + 1)) 0
    (( c == 0 )) && return 0
    if (( c == n + 1 )); then
      _params_edit_confirm || continue
      params_edit_apply
      pause
      return 0
    fi
    k=${keys[c - 1]}; v=${vals[c - 1]}
    if [[ "$k" =~ ^(RandomTrailers|DisableCookies)$ ]]; then
      edits+=("$k=$([[ "$v" == on ]] && echo off || echo on)")
      continue
    fi
    read_line l "${C}  $k (сейчас ${v:-—}; Enter — без изменений): ${N}"
    l="${l// /}"
    [[ -n "$l" ]] && edits+=("$k=$l")
  done
}

# Показать итог проверки и спросить подтверждение; 1 — вернуться к правке.
_params_edit_confirm() {
  local l keys
  [[ -n "$PARAMS_CHANGED" ]] || { info "Ничего не изменено"; return 1; }
  if [[ -n "$PARAMS_ERR" ]]; then
    while IFS= read -r l; do err "$l"; done <<< "$PARAMS_ERR"
    return 1
  fi
  if [[ -n "$PARAMS_WARN" ]]; then
    while IFS= read -r l; do warn "$l"; done <<< "$PARAMS_WARN"
    ask_yes "  Сохранить всё равно? [y/N]: " n || return 1
  fi
  if [[ -n "$PARAMS_BREAKING" ]]; then
    keys=$(tr '\n' ' ' <<< "$PARAMS_BREAKING"); keys="${keys% }"
    warn "Меняются ${keys// /, } — все клиенты ($(client_files | grep -c . || true)) потеряют связь до получения нового конфига"
    read_confirm "${R}  Продолжить? (введи yes): ${N}" || { info "Отменено"; return 1; }
  else
    info "Старые конфиги продолжат работать — клиентам совпадать не обязательно"
    ask_yes "  Применить? [Y/n]: " y || return 1
  fi
}

do_proto_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  local cur c target n
  cur=$(server_proto)
  n=$(client_files | wc -l)
  echo ""
  hdr "Протокол и параметры"
  echo -e "  Сейчас: ${W}AWG $cur${N}, профиль ${W}$(profile_label)${N}, клиентов ${W}$n${N}"
  echo ""
  if [[ "$cur" != 3.1 ]]; then
    echo -e "  ${G}1)${N} Перейти на AWG 3.1 ${D}— быстрее 2.0${N}"
  else
    echo -e "  ${C}1)${N} Новые параметры AWG 3.1"
  fi
  if [[ "$cur" == 2.0 ]]; then
    echo -e "  ${C}2)${N} Перегенерировать параметры AWG 2.0"
  else
    echo -e "  ${Y}2)${N} Вернуться на AWG 2.0 ${D}— для старых клиентов${N}"
  fi
  echo -e "  ${C}3)${N} Изменить параметры вручную ${D}— Jc, S1-S4, H1-H4…${N}"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор [0-3]: ${N}" 0 3 0
  case "$c" in 1) target=3.1 ;; 2) target=2.0 ;; 3) do_params_edit_menu; return ;; *) return 0 ;; esac
  echo ""
  warn "Все клиенты ($n) потеряют связь до получения нового конфига"
  [[ "$target" != "$cur" ]] && warn "Версия меняется: AWG $cur → AWG $target"
  read_confirm "${R}  Продолжить? (введи yes): ${N}" || { info "Отменено"; return 0; }
  server_regen_params "$target"
}

# ── Endpoint ──────────────────────────────────────────────
# endpoint_set ДОМЕН|"" [переписать_выданные 1|0] — пусто = публичный IP.
endpoint_set() {
  local d="${1,,}" rw="${2:-1}" ep port f
  server_exists || { err "Сервер не создан"; return 1; }
  port=$(server_port)
  if [[ -n "$d" ]]; then
    valid_domain "$d" || { err "Нужно имя вида vpn.example.com"; return 1; }
    conf_marker_set AWG_ENDPOINT "$d"; ep="$d:$port"
  else
    conf_marker_del AWG_ENDPOINT; ep="$(public_ip_cached):$port"
  fi
  ok "Endpoint для новых конфигов: $ep"
  if [[ "$rw" == 1 ]]; then
    while read -r f; do sed -i "s|^Endpoint = .*|Endpoint = $ep|" "$f"; done < <(client_files)
    ok "Выданные конфиги обновлены — клиентам нужно забрать новые"
  fi
}

do_endpoint_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  local cur port c d rw
  cur=$(endpoint_domain); port=$(server_port)
  echo ""
  hdr "Endpoint для клиентов"
  echo -e "  Сейчас: ${W}${cur:-$(public_ip_cached)}:$port${N} ${D}(${cur:+домен}${cur:-IP})${N}"
  echo -e "  ${C}1)${N} Задать домен"
  echo -e "  ${C}2)${N} Вернуться на IP"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
  case "$c" in
    1) while true; do
         read_line d "${C}  Домен (Enter — отмена): ${N}"; d="${d// /}"
         [[ -z "$d" ]] && return 0
         valid_domain "$d" && break
         warn "Нужно имя вида vpn.example.com"
       done
       domain_points_here "$d" || ask_yes "  Всё равно задать? [y/N]: " n || return 0 ;;
    2) [[ -n "$cur" ]] || { info "Уже IP"; return 0; }
       d="" ;;
    *) return 0 ;;
  esac
  rw=0
  (( $(client_files | wc -l) )) && ask_yes "  Переписать Endpoint в уже выданных конфигах? [Y/n]: " y && rw=1
  endpoint_set "$d" "$rw"
}

# ── Сброс ─────────────────────────────────────────────────
do_reset_server() {
  server_exists || { info "Сервер не создан"; return 0; }
  echo ""
  hdr "Сброс сервера"
  warn "Будут удалены awg0, $SERVER_CONF и все клиенты ($(client_files | wc -l))."
  info "Компоненты и бэкапы остаются; авто-бэкап будет сделан."
  read_confirm "${R}  Подтверди сброс (введи yes): ${N}" || { info "Отменено"; return 0; }
  server_reset
}

# Удаляет сервер и клиентов (компоненты и бэкапы остаются).
server_reset() {
  server_exists || { info "Сервер не создан"; return 0; }
  auto_backup reset || warn "Авто-бэкап не удался"
  tunnels_panic_reset quiet
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  rm -f "$SERVER_CONF" "$SERVER_CONF".bak.* "$SERVER_CONF".pre_* "$CLIENT_DIR"/*_awg[23].conf
  rm -f "$TRAFFIC_DB" "$TRAFFIC_DB.lock"
  ufw_delete_matching AmneziaWG
  : > "$WARP_PEERS" 2>/dev/null || true
  : > "$XRAY_PEERS" 2>/dev/null || true
  : > "$EXITS_PEERS" 2>/dev/null || true
  # Снимок счётчиков — метка жизни таймера: старый после сброса заставил бы
  # сторож «чинить» таймер посреди создания нового сервера
  rm -f "$EXPIRE_STATE_DIR/transfer"
  ok "Сервер сброшен. Создать новый: Сервер → Создать сервер"
  log_info "сервер сброшен"
}

# ═════ clients ═════
# Клиенты AWG: добавление, удаление, переименование, выдача конфигов.

# QR с экрана терминала телефоны берут примерно до 2800 байт конфига.
QR_MAX=2800

share_config() {  # файл [qr]
  local f="$1" size
  [[ -f "$f" ]] || return 1
  size=$(wc -c < "$f")
  if [[ "${2:-}" == qr ]]; then
    if command -v qrencode &>/dev/null && (( size <= QR_MAX )); then
      qrencode -t ansiutf8 -m 1 < "$f"
      echo -e "${D}  ↑ QR конфига ($size байт) — сканируй в AmneziaVPN / AmneziaWG${N}"
      return 0
    fi
    warn "Конфиг $size байт — в читаемый QR не влезет, показываю текст"
  fi
  echo -e "${Y}  ── ${f##*/} ──${N}"
  cat "$f"
  echo -e "${Y}  ──────────────${N}"
}

# Добавляет клиента в awg0.conf и в работающий интерфейс, пишет его конфиг.
# Мимикрия берётся из I_LINES/MIMICRY. $5 — срок действия (unix-время), пусто — бессрочно.
client_add() {
  local name="$1" addr="$2" dns="$3" mtu="$4" expire="${5:-}" priv pub psk size
  priv=$(awg genkey) && pub=$(awg pubkey <<< "$priv") && psk=$(awg genpsk) || return 1
  size=$(stat -c%s "$SERVER_CONF")
  printf '\n[Peer]\n# %s\n# mimicry=%s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s\n' \
    "$name" "$(mimicry_tag)" "$pub" "$psk" "$addr" >> "$SERVER_CONF"
  if iface_up && ! awg set "$AWG_IF" peer "$pub" preshared-key <(printf '%s\n' "$psk") allowed-ips "$addr"; then
    truncate -s "$size" "$SERVER_CONF"
    err "Ядро не приняло пира — запись откатана"
    return 1
  fi
  write_client_conf "$(client_file "$name")" "$priv" "$addr" "$psk" "$dns" "$mtu" || return 1
  if [[ -n "$expire" ]]; then
    expire_install
    py expire-set "$SERVER_CONF" "$name" "$expire"
  fi
  log_info "клиент добавлен: $name $addr"
}

# Удаляет пира по ключу: из конфига, из ядра, файл клиента и списки туннелей.
client_delete() {
  local pub="$1" name ip
  # У заблокированного в AllowedIPs заглушка 127.0.0.2, настоящий адрес — в
  # orig_ips: иначе его строки в туннелях и ip rule оставались, а адрес
  # доставался новому клиенту — вместе с чужим туннелем и выходом Xray
  ip=$(clients_tsv | awk -F'\t' -v k="$pub" '$2 == k {split($5 != "" ? $5 : $3, a, "/"); print a[1]; exit}')
  name=$(py peer-del "$SERVER_CONF" "$pub") || return 1
  iface_up && awg set "$AWG_IF" peer "$pub" remove 2>/dev/null
  [[ -n "$name" ]] && rm -f "$CLIENT_DIR/${name}_awg2.conf" "$CLIENT_DIR/${name}_awg3.conf"
  rm -f "$EXPIRE_STATE_DIR/warn1h_${pub//[^A-Za-z0-9]/_}"
  [[ -n "$ip" ]] && tunnel_peers_forget "$ip"
  log_info "клиент удалён: ${name:-?} ($pub)"
  ok "Удалён: ${name:-без имени}"
}

# ── Ядра операций (без вопросов: меню, командная строка и бот) ──
client_pub() { clients_tsv | awk -F'\t' -v n="$1" '$1 == n {print $2; exit}'; }

# client_create ИМЯ [СРОК] [МИМИКРИЯ] [DNS] [MTU]
# МИМИКРИЯ — строка mimicry_from_spec, по умолчанию «как у сервера».
client_create() {
  local name="$1" expire="${2:-}" spec="${3:-server}" dns="${4:-1.1.1.1, 1.0.0.1}" mtu="${5:-}" addr
  server_exists || { err "Сервер не создан"; return 1; }
  _name_free "$name" || { err "Имя $name занято или недопустимо (латиница, цифры, _ -, до 32)"; return 1; }
  [[ -z "$expire" ]] || { [[ "$expire" =~ ^[0-9]+$ ]] && (( expire > $(date +%s) + 60 )); } \
    || { err "Срок — unix-время в будущем"; return 1; }
  [[ -n "$mtu" ]] || mtu=$(conf_iface_get MTU)
  addr=$(free_client_ip) || { err "В подсети нет свободных адресов"; return 1; }
  mimicry_from_spec "$spec" || return 1
  client_add "$name" "$addr" "$dns" "$mtu" "$expire" || return 1
  ok "Клиент $name: $addr"
  echo "Файл конфигурации: $(client_file "$name")"
}

client_remove() {  # имя
  local pub
  pub=$(client_pub "$1")
  [[ -n "$pub" ]] || { err "Клиента $1 нет"; return 1; }
  client_delete "$pub"
}

client_rename() {  # старое новое
  local old="$1" new="$2" pub f
  pub=$(client_pub "$old")
  [[ -n "$pub" ]] || { err "Клиента $old нет"; return 1; }
  _name_free "$new" || { err "Имя $new занято или недопустимо"; return 1; }
  py peer-rename "$SERVER_CONF" "$pub" "$new" || return 1
  f=$(client_file "$old")
  [[ -f "$f" ]] && mv -f "$f" "$CLIENT_DIR/${new}$(client_suffix).conf"
  log_info "клиент переименован: $old → $new"
  ok "Переименован: $old → $new"
}

# Мимикрия выданного клиента: меняются только его I1-I5 — сервер их не видит.
client_set_mimicry() {  # имя строка
  [[ -f "$(client_file "$1")" ]] || { err "Нет конфига клиента $1"; return 1; }
  mimicry_from_spec "$2" && _client_write_mimicry "$1"
}

_client_write_mimicry() {  # имя — записать текущие I_LINES
  local name="$1" f
  f=$(client_file "$name")
  cp -a "$f" "$f.bak.$(date +%s)"
  i_lines_block | py i-replace "$f" || return 1
  peer_meta_set "$name" mimicry "$(mimicry_tag)" || warn "Метку в awg0.conf обновить не удалось"
  ok "Мимикрия $name: $(mimicry_tag), пакетов: ${#I_LINES[@]}"
  warn "Клиенту нужен новый конфиг"
}

client_expire_set() {  # имя unix-время
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > $(date +%s) + 60 )) || { err "Срок должен быть в будущем"; return 1; }
  client_exists "$1" || { err "Клиента $1 нет"; return 1; }
  expire_install
  # Заблокированному сначала вернуть адрес: expire-set правит только метку,
  # и клиент остался бы на 127.0.0.2 с новым сроком — «заблокирован» без причины.
  # Блокировку за трафик новый срок не снимает — её снимает лимит.
  if [[ -n "$(peer_meta_get "$1" orig_ips)" && "$(peer_meta_get "$1" blocked_by)" != traffic ]]; then
    py expire-clear "$SERVER_CONF" "$1" "$EXPIRE_SUSPEND_IP" >/dev/null || return 1
    _expire_apply
  fi
  py expire-set "$SERVER_CONF" "$1" "$2" || return 1
  rm -f "$EXPIRE_STATE_DIR/warn1h_$(client_pub "$1" | tr -c 'A-Za-z0-9\n' '_')"
  ok "Срок $1: $(expire_fmt "$2")"
}

# Снять срок; заблокированный клиент получает прежний адрес.
client_expire_clear() {
  local r
  client_exists "$1" || { err "Клиента $1 нет"; return 1; }
  r=$(py expire-clear "$SERVER_CONF" "$1" "$EXPIRE_SUSPEND_IP") || return 1
  _expire_apply
  ok "$1 — бессрочный"
  [[ "$r" == traffic ]] && warn "$1 остаётся заблокирован: исчерпан лимит трафика"
  return 0
}

# Лимит трафика: РАЗМЕР (50G, 500M) за месяц или всего; off — снять.
# Применяется сразу: превысивший блокируется, уложившийся — разблокируется.
client_limit_set() {  # имя размер|off [month|total]
  local name="$1" size="$2" period="${3:-month}" v tr
  client_exists "$name" || { err "Клиента $name нет"; return 1; }
  [[ "$period" == month || "$period" == total ]] || { err "Период: month или total"; return 1; }
  expire_install
  tr=$(_traffic_snapshot) || return 1
  v=$(py limit-set "$SERVER_CONF" "$TRAFFIC_DB" "$name" "$size" "$period" "$tr" \
      "$(cat "/sys/class/net/$AWG_IF/ifindex" 2>/dev/null)") || { rm -f "$tr"; return 1; }
  rm -f "$tr"
  traffic_tick 1
  if [[ "$size" == off ]]; then ok "$name — без лимита трафика"
  else ok "Лимит $name: $v $([[ "$period" == month ]] && echo "в месяц" || echo "всего")"; fi
}

client_limit_reset() {  # имя
  local tr
  client_exists "$1" || { err "Клиента $1 нет"; return 1; }
  tr=$(_traffic_snapshot) || return 1
  py limit-reset "$SERVER_CONF" "$TRAFFIC_DB" "$1" "$tr" "$(cat "/sys/class/net/$AWG_IF/ifindex" 2>/dev/null)" \
    || { rm -f "$tr"; return 1; }
  rm -f "$tr"
  traffic_tick 1
  ok "Счётчик лимита $1 обнулён"
}

# «12.3 ГБ из 50.0 ГБ за месяц» для меню.
limit_fmt() {  # метка limit (БАЙТ/период) использовано
  local n="${1%/*}" p="${1#*/}"
  echo "$(fmt_bytes "${2:-0}") из $(fmt_bytes "$n") $([[ "$p" == month ]] && echo "за месяц" || echo "всего")"
}

# Удалить клиентов с истёкшим сроком. Заблокированных за трафик не трогает:
# они разблокируются сами в новом месяце или после смены лимита.
clients_purge_blocked() {
  local pub n=0
  while IFS= read -r pub; do client_delete "$pub" && n=$((n + 1)); done \
    < <(clients_tsv | awk -F'\t' '$5 != "" && $8 != "traffic" {print $2}')
  ok "Удалено с истёкшим сроком: $n"
}

# Архив всех конфигов → путь в EXPORT_PATH.
EXPORT_PATH=""
clients_export() {
  local files=() stamp
  mapfile -t files < <(client_files)
  (( ${#files[@]} )) || { warn "Конфигов клиентов нет"; return 1; }
  stamp=$(date +%Y%m%d_%H%M%S)
  if command -v zip &>/dev/null || apt_install zip >/dev/null 2>&1; then
    EXPORT_PATH="$CLIENT_DIR/awg_clients_$stamp.zip"
    zip -j -q "$EXPORT_PATH" "${files[@]}" || return 1
  else
    EXPORT_PATH="$CLIENT_DIR/awg_clients_$stamp.tar.gz"
    tar -czf "$EXPORT_PATH" -C "$CLIENT_DIR" "${files[@]##*/}" || return 1
  fi
  chmod 600 "$EXPORT_PATH"
  ok "Архив: $EXPORT_PATH (${#files[@]} конфигов)"
}

# Имя для нового клиента: валидное и не занятое ни пиром, ни файлом.
_name_free() { valid_client_name "$1" && ! client_exists "$1" && [[ ! -e "$CLIENT_DIR/${1}_awg2.conf" && ! -e "$CLIENT_DIR/${1}_awg3.conf" ]]; }

_ask_expire() {  # → unix-время в stdout или пусто
  local c d ts=""
  {
    echo -e "  Срок действия:"
    echo -e "  ${C}1)${N} Бессрочно"
    echo -e "  ${C}2)${N} 1 час"
    echo -e "  ${C}3)${N} 1 день"
    echo -e "  ${C}4)${N} 7 дней"
    echo -e "  ${C}5)${N} 30 дней"
    echo -e "  ${C}6)${N} До даты"
  } >&2
  read_choice c "${C}  Выбор [1-6] (Enter = 1): ${N}" 1 6 1 >&2
  case "$c" in
    2) ts=$(date -d '+1 hour' +%s) ;; 3) ts=$(date -d '+1 day' +%s) ;;
    4) ts=$(date -d '+7 days' +%s) ;; 5) ts=$(date -d '+30 days' +%s) ;;
    6) read_line d "${C}  Дата (ГГГГ-ММ-ДД ЧЧ:ММ): ${N}" >&2
       ts=$(date -d "$d" +%s 2>/dev/null) || ts=""
       [[ -n "$d" && "$ts" =~ ^[0-9]+$ ]] && (( ts > $(date +%s) + 60 )) \
         || { warn "Дата не распознана или уже прошла — бессрочно" >&2; ts=""; } ;;
  esac
  echo "$ts"
}

# Мимикрия для нового клиента по профилю сервера.
_client_mimicry() {
  local profile c
  profile=$(server_profile)
  I_LINES=(); MIMICRY=none
  case "$profile" in
    lite|standard) mimicry_from_spec server ;;
    *)
      c=$(conf_marker AWG_MIMICRY)
      echo -e "  Мимикрия I1-I5:"
      echo -e "  ${C}1)${N} Как у сервера ${D}(${c:-none})${N}"
      echo -e "  ${C}2)${N} Выбрать"
      echo -e "  ${C}3)${N} Без I1-I5"
      read_choice c "${C}  Выбор [1-3] (Enter = 1): ${N}" 1 3 1
      case "$c" in
        1) mimicry_from_spec server ;;
        2) choose_and_gen_chain || { I_LINES=(); MIMICRY=none; } ;;
      esac ;;
  esac
}

do_add_client() {
  server_exists || { err "Сервер не создан"; return 1; }
  local name addr ip expire base
  while true; do
    read_line name "${C}  Имя клиента (латиница, цифры, _ -): ${N}"
    [[ -z "$name" ]] && return 0
    _name_free "$name" && break
    valid_client_name "$name" && warn "Клиент $name уже есть" || warn "Имя: латиница, цифры, _ и -, до 32 символов"
  done
  addr=$(free_client_ip) || { err "В подсети нет свободных адресов"; return 1; }
  if ! ask_yes "  Адрес $addr? [Y/n]: " y; then
    base=$(server_net); base="${base%.*}"
    while true; do
      read_line ip "${C}  Адрес ${base}.N: ${N}"
      ip="${ip%/32}"
      [[ -z "$ip" ]] && return 0
      if [[ "$ip" =~ ^${base//./\\.}\.([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 2 && BASH_REMATCH[1] <= 254 )) \
         && ! clients_tsv | cut -f3,5 | tr '\t,' '\n\n' | grep -qx "$ip/32" \
         && [[ "$ip" != "$(conf_iface_get Address | cut -d/ -f1)" ]]; then
        addr="$ip/32"; break
      fi
      warn "Нужен свободный адрес ${base}.2-254"
    done
  fi
  S_DNS="1.1.1.1, 1.0.0.1"
  _choose_dns
  MTU=$(conf_iface_get MTU); _choose_mtu "${MTU:-1280}"
  _client_mimicry
  expire=$(_ask_expire)
  client_add "$name" "$addr" "$S_DNS" "$MTU" "$expire" || return 1
  share_config "$(client_file "$name")"
  success_box "Клиент $name: $addr"
  if [[ -n "$expire" ]]; then info "Срок действия: $(expire_fmt "$expire")"; fi
}


do_bulk_add() {
  server_exists || { err "Сервер не создан"; return 1; }
  local c raw prefix count names=() n i addr expire created=0 part
  local -a parts=()
  echo -e "  ${C}1)${N} Префикс + количество ${D}(user-001...)${N}"
  echo -e "  ${C}2)${N} Имена через запятую"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 2 ]]; then
    read_line raw "${C}  Имена через запятую: ${N}"
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
      n=$(tr -cd 'A-Za-z0-9_-' <<< "${part// /_}"); n="${n:0:32}"
      [[ -n "$n" ]] || continue
      if [[ " ${names[*]} " == *" $n "* ]] || ! _name_free "$n"; then warn "Пропущено: $n (занято)"; continue; fi
      names+=("$n")
    done
  else
    read_line prefix "${C}  Префикс: ${N}"
    valid_client_name "$prefix" && (( ${#prefix} <= 27 )) || { warn "Префикс: латиница, цифры, _ -, до 27 символов"; return 0; }
    read_line count "${C}  Сколько клиентов (1-200): ${N}"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 200 )) || { warn "Нужно число 1-200"; return 0; }
    i=1
    while (( ${#names[@]} < count && i < 10000 )); do
      printf -v n '%s-%03d' "$prefix" "$i"
      _name_free "$n" && names+=("$n")
      i=$((i + 1))
    done
  fi
  (( ${#names[@]} )) || { warn "Нет имён для создания"; return 0; }
  S_DNS="1.1.1.1, 1.0.0.1"; _choose_dns
  MTU=$(conf_iface_get MTU); _choose_mtu "${MTU:-1280}"
  _client_mimicry
  expire=$(_ask_expire)
  ask_yes "  Создать клиентов: ${#names[@]}? [Y/n]: " y || return 0
  for n in "${names[@]}"; do
    addr=$(free_client_ip) || { warn "Подсеть заполнена — стоп"; break; }
    client_add "$n" "$addr" "$S_DNS" "$MTU" "$expire" || { warn "$n: не создан"; continue; }
    echo -e "  ${G}+${N} $n → $addr"
    created=$((created + 1))
  done
  success_box "Создано клиентов: $created из ${#names[@]}"
  info "Конфиги: $CLIENT_DIR/<имя>$(client_suffix).conf; архивом — Клиенты → Экспорт"
}

# Выбор клиента из списка. Результат — «имя<TAB>ключ» в CHOSEN.
CHOSEN=""
_pick_client() {
  local rows=() i c name pub aip
  mapfile -t rows < <(clients_tsv)
  (( ${#rows[@]} )) || { warn "Клиентов нет"; return 1; }
  echo ""
  for i in "${!rows[@]}"; do
    IFS='|' read -r name pub aip _ <<< "${rows[$i]//$'\t'/|}"
    printf "  ${G}%3d)${N} %-24s ${D}%s${N}\n" "$((i + 1))" "${name:-без имени}" "$aip"
  done
  read_choice c "${C}  Номер (0 — отмена): ${N}" 0 "${#rows[@]}" 0
  (( c == 0 )) && return 1
  IFS='|' read -r name pub _ <<< "${rows[$((c - 1))]//$'\t'/|}"
  CHOSEN="$name"$'\t'"$pub"
}

do_delete_client() {
  server_exists || { err "Сервер не создан"; return 1; }
  local c raw n pubs=() names=() row pub
  local -a parts=()
  echo -e "  ${C}1)${N} Одного по номеру"
  echo -e "  ${C}2)${N} Несколько по именам"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    _pick_client || return 0
    names=("${CHOSEN%%$'\t'*}"); pubs=("${CHOSEN#*$'\t'}")
  else
    read_line raw "${C}  Имена через запятую: ${N}"
    IFS=',' read -r -a parts <<< "$raw"
    for n in "${parts[@]}"; do
      n="${n// /}"; [[ -n "$n" ]] || continue
      row=$(clients_tsv | awk -F'\t' -v n="$n" '$1 == n {print $2; exit}')
      if [[ -n "$row" ]]; then names+=("$n"); pubs+=("$row"); else warn "Нет клиента: $n"; fi
    done
    (( ${#pubs[@]} )) || return 0
  fi
  warn "Будут удалены: ${names[*]:-без имени}"
  read_confirm "${R}  Подтверди удаление (введи yes): ${N}" || { info "Отменено"; return 0; }
  cp -a "$SERVER_CONF" "${SERVER_CONF}.pre_delete.$(date +%s)"
  for pub in "${pubs[@]}"; do client_delete "$pub" || true; done
}

do_rename_client() {
  server_exists || { err "Сервер не создан"; return 1; }
  local old new
  _pick_client || return 0
  old="${CHOSEN%%$'\t'*}"
  [[ -n "$old" ]] || { warn "У клиента нет имени — переименовать можно только именованного"; return 1; }
  while true; do
    read_line new "${C}  Новое имя для $old: ${N}"
    [[ -z "$new" || "$new" == "$old" ]] && return 0
    _name_free "$new" && break
    warn "Имя недопустимо или занято"
  done
  client_rename "$old" "$new"
}

_pick_client_file() {  # → путь в CHOSEN
  local files=() i c
  mapfile -t files < <(client_files)
  (( ${#files[@]} )) || { warn "Конфигов клиентов в $CLIENT_DIR нет"; return 1; }
  for i in "${!files[@]}"; do printf "  ${G}%3d)${N} %s\n" "$((i + 1))" "${files[$i]##*/}"; done
  read_choice c "${C}  Номер (Enter = 1, 0 — отмена): ${N}" 0 "${#files[@]}" 1
  (( c == 0 )) && return 1
  CHOSEN="${files[$((c - 1))]}"
}

do_show_client()    { _pick_client_file && share_config "$CHOSEN"; }
do_show_client_qr() { _pick_client_file && share_config "$CHOSEN" qr; }

do_list_clients() {
  server_exists || { err "Сервер не создан"; return 1; }
  local dump now name pub aip exp orig _ hs rx tx ep st i=0 age lim per used month today by
  local -A tl=()
  dump=$(awg show "$AWG_IF" dump 2>/dev/null | tail -n +2)
  now=$(date +%s)
  while IFS='|' read -r name lim per used month today by; do
    [[ -n "$name" ]] && tl[x$name]="$lim|$per|$used|$month|$today|$by"
  done < <(traffic_rows)
  echo ""
  hdr "Клиенты"
  while IFS='|' read -r name pub aip exp orig _; do
    i=$((i + 1))
    ep="" hs=0 rx=0 tx=0
    read -r ep hs rx tx < <(awk -F'\t' -v k="$pub" '$1 == k {print $3, $5, $6, $7; exit}' <<< "$dump") || true
    [[ "$ep" == "(none)" ]] && ep=""
    if [[ "${hs:-0}" =~ ^[0-9]+$ ]] && (( ${hs:-0} > 0 )); then
      age=$(( now - hs ))
      if (( age < 180 )); then st="${G}● онлайн${N} ${D}($(fmt_duration "$age") назад)${N}"
      else st="${D}○ был $(fmt_duration "$age") назад${N}"; fi
    else
      st="${D}○ не подключался${N}"
    fi
    echo -e "  ${W}$i) ${name:-без имени}${N}  ${D}$aip${N}"
    echo -e "     $st  ↑ $(fmt_bytes "${tx:-0}")  ↓ $(fmt_bytes "${rx:-0}")${ep:+  ${D}${ep%:*}${N}}"
    IFS='|' read -r lim per used month today by <<< "${tl[x$name]:-0|||0|0|}"
    (( ${month:-0} )) && echo -e "     ${D}за месяц $(fmt_bytes "$month"), сегодня $(fmt_bytes "${today:-0}")${N}"
    if [[ "$by" == traffic ]]; then echo -e "     ${R}заблокирован: исчерпан лимит — $(limit_fmt "$lim/$per" "$used")${N}"
    elif [[ "${lim:-0}" != 0 ]]; then echo -e "     ${D}лимит: $(limit_fmt "$lim/$per" "$used")${N}"; fi
    if [[ -n "$exp" ]]; then
      if [[ -n "$orig" && "$by" != traffic ]]; then echo -e "     ${R}заблокирован: срок истёк $(expire_fmt "$exp")${N}"
      elif [[ -z "$orig" ]]; then echo -e "     ${Y}срок: $(expire_fmt "$exp")${N}"; fi
    fi
  done < <(clients_psv)
  (( i )) || info "Клиентов нет"
}

do_export_clients() {
  clients_export || return 0
  info "Скачать: scp root@$(public_ip_cached):$EXPORT_PATH ."
}

# Смена мимикрии у выданного клиента: меняются только его I1-I5.
do_change_mimicry() {
  local f name
  _pick_client_file || return 0
  f="$CHOSEN"; name=$(client_name_of "$f")
  echo -e "  Сейчас: ${W}$(peer_meta_get "$name" mimicry || true)${N}"
  if [[ "$(server_profile)" == pro ]]; then
    choose_and_gen_chain || return 0
  else
    OBF_LEVEL=2
    choose_mimicry || return 0
    choose_cps_domain
    mimicry_generate
  fi
  _client_write_mimicry "$name" || return 1
  share_config "$f"
}

do_clients_menu() {
  local c
  while true; do
    echo ""
    hdr "Клиенты ($(clients_tsv | wc -l))"
    echo -e "  ${G}1)${N} Добавить клиента"
    echo -e "  ${C}2)${N} Активность и трафик"
    echo -e "  ${C}3)${N} Показать конфиг"
    echo -e "  ${C}4)${N} Показать QR"
    echo -e "  ${C}5)${N} Переименовать"
    echo -e "  ${G}6)${N} Создать несколько"
    echo -e "  ${C}7)${N} Сроки и лимиты трафика"
    echo -e "  ${C}8)${N} Экспорт всех (zip)"
    echo -e "  ${C}9)${N} Сменить мимикрию"
    echo -e "  ${R}10)${N} Удалить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-10]: ${N}" 0 10 0
    case "$c" in
      1) do_add_client || true ;;     6) do_bulk_add || true ;;
      2) do_list_clients || true ;;   7) do_expire_menu || true ;;
      3) do_show_client || true ;;    8) do_export_clients || true ;;
      4) do_show_client_qr || true ;; 9) do_change_mimicry || true ;;
      5) do_rename_client || true ;;  10) do_delete_client || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ expire ═════
# Срок действия клиентов. Истёкший клиент не удаляется, а блокируется:
# его AllowedIPs меняется на 127.0.0.2/32, исходный адрес сохраняется меткой
# «# orig_ips=» — разблокировка возвращает его на место. Метку «# expires=»
# ставит и Telegram-бот, поэтому таймер нужен независимо от того, кто
# назначил срок.

# Уведомление владельцам и админам бота — напрямую в Telegram, через прокси
# бота: таймер работает и тогда, когда сам бот остановлен.
_expire_notify() {
  local token="" proxy="" id ids=() via=()
  # Проход таймера под замком API: сообщения — после замка (curl до 8 с на
  # каждого админа держал бы замок, и правки из бота и панели получали отказ)
  if [[ -n "${EXPIRE_DEFER:-}" ]]; then EXPIRE_QUEUE+=("$1"); return 0; fi
  [[ -f "$BOT_CONF" ]] || return 0
  { read -r token; read -r proxy; mapfile -t ids; } < <(py tg-targets "$BOT_CONF" "$BOT_ADMINS" 2>/dev/null)
  [[ -n "$token" ]] && (( ${#ids[@]} )) || return 0
  case "$proxy" in
    iface://*) via=(--interface "${proxy#iface://}") ;;
    ?*) via=(--proxy "$proxy") ;;
  esac
  for id in "${ids[@]}"; do
    # Токен не попадает в argv (его видно в списке процессов) — curl читает конфиг со stdin
    curl -sf --max-time 8 ${via[@]+"${via[@]}"} --config - >/dev/null 2>&1 <<EOF || true
url = "https://api.telegram.org/bot${token}/sendMessage"
data = "chat_id=${id}"
data = "parse_mode=HTML"
data-urlencode = "text=$1"
EOF
  done
}

# Имя клиента в HTML-сообщении Telegram: конфиг, правленный руками, может
# нести в имени что угодно.
_expire_esc() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }

_expire_sync() {
  local stripped
  stripped=$(awg-quick strip "$AWG_IF" 2>/dev/null) \
    && awg syncconf "$AWG_IF" <(printf '%s\n' "$stripped") 2>>"$EXPIRE_LOG"
}

# Трафик клиентов: прирост счётчиков — в базу по дням, превысившие лимит
# блокируются, в новом месяце (или после смены лимита) — разблокируются.
# Снимок счётчиков — свой файл на каждый вызов: таймер и команда из меню
# или API, писавшие в один файл, читали бы недописанные строки друг друга.
_traffic_snapshot() {  # → путь к снимку в stdout
  local tr
  mkdir -p "$EXPIRE_STATE_DIR"
  tr=$(mktemp "$EXPIRE_STATE_DIR/transfer.XXXXXX") || return 1
  awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || : > "$tr"
  printf '%s\n' "$tr"
}

traffic_tick() {  # [1 — записать базу сейчас]
  local out ev name arg text tr ifx=""
  [[ -f "$SERVER_CONF" ]] || return 0
  tr=$(_traffic_snapshot) || return 0
  ifx=$(cat "/sys/class/net/$AWG_IF/ifindex" 2>/dev/null || true)
  out=$(py traffic-tick "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$TRAFFIC_DB" "$tr" "$ifx" "${1:-0}" 2>>"$EXPIRE_LOG") || out=""
  # Прочитанный снимок — на место $EXPIRE_STATE_DIR/transfer одним rename:
  # по его времени expire_watchdog видит, что таймер жив
  mv -f "$tr" "$EXPIRE_STATE_DIR/transfer" 2>/dev/null || rm -f "$tr"
  while IFS=$'\t' read -r ev name arg text; do
    case "$ev" in
      CHANGED) _expire_sync ;;
      LIMIT)
        echo "$(date '+%F %T') limit: $name ($text)" >> "$EXPIRE_LOG"
        command -v conntrack >/dev/null && conntrack -D -s "${arg%%/*}" >/dev/null 2>&1
        _expire_notify "🚫 Клиент <b>$(_expire_esc "$name")</b> заблокирован: исчерпан лимит трафика — ${text}." ;;
      WARN90)
        echo "$(date '+%F %T') limit90: $name ($arg)" >> "$EXPIRE_LOG"
        _expire_notify "⚠️ Клиент <b>$(_expire_esc "$name")</b> израсходовал 90% лимита трафика: ${arg}." ;;
      UNLIMIT)
        echo "$(date '+%F %T') unlimit: $name ($arg)" >> "$EXPIRE_LOG"
        _expire_notify "✅ Клиент <b>$(_expire_esc "$name")</b> разблокирован — трафик в пределах лимита: ${arg}." ;;
    esac
  done <<< "$out"
  return 0
}

# Точка входа таймера (awg2-expire-check). Конфиг сервера правят и вызовы
# API (бот, панель) — под их замком; занят дольше 10 с — проход пропускается,
# следующий через 15 с. Таймер при этом жив — сторожу это видно по времени
# снимка. Долгая задача API (сборка модуля, установка) держит замок минутами:
# сроки и лимиты ждут её не дольше EXPIRE_LOCK_MAX, дальше проход идёт без замка.
EXPIRE_LOCK_MAX=120
expire_check_run() {
  local out ev name arg busy="$EXPIRE_STATE_DIR/lock_busy"
  local EXPIRE_DEFER=1 EXPIRE_QUEUE=()
  [[ -f "$SERVER_CONF" ]] || return 0
  mkdir -p "$STATE_DIR" "$EXPIRE_STATE_DIR"
  exec 9>>"$STATE_DIR/api.lock" || return 0
  if flock -w "${EXPIRE_LOCK_WAIT:-10}" 9; then
    rm -f "$busy"
  else
    [[ -f "$busy" ]] || : > "$busy"
    if (( $(date +%s) - $(stat -c %Y "$busy" 2>/dev/null || date +%s) < ${EXPIRE_LOCK_MAX:-120} )); then
      [[ -f "$EXPIRE_STATE_DIR/transfer" ]] && touch "$EXPIRE_STATE_DIR/transfer"
      return 0
    fi
  fi
  out=$(py expire-check "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$EXPIRE_STATE_DIR" 2>>"$EXPIRE_LOG") || out=""
  while IFS=$'\t' read -r ev name arg; do
    case "$ev" in
      CHANGED) _expire_sync ;;
      EXPIRED)
        echo "$(date '+%F %T') expired: $name (было $arg)" >> "$EXPIRE_LOG"
        command -v conntrack >/dev/null && conntrack -D -s "${arg%%/*}" >/dev/null 2>&1
        _expire_notify "🚫 Клиент <b>$(_expire_esc "$name")</b> заблокирован: срок действия истёк." ;;
      WARN1H)
        echo "$(date '+%F %T') warn1h: $name ($arg мин)" >> "$EXPIRE_LOG"
        _expire_notify "⚠️ Клиент <b>$(_expire_esc "$name")</b> истекает через ${arg} мин." ;;
    esac
  done <<< "$out"
  traffic_tick
  exec 9>&-
  EXPIRE_DEFER=""
  # Telegram недоступен: curl по 8 с на каждого админа — бюджет 60 с, чтобы
  # проход не затягивался; не ушедшее — в журнале
  local i t0=$SECONDS
  for (( i = 0; i < ${#EXPIRE_QUEUE[@]}; i++ )); do
    if (( SECONDS - t0 >= ${EXPIRE_NOTIFY_BUDGET:-60} )); then
      echo "$(date '+%F %T') уведомления: не отправлено $(( ${#EXPIRE_QUEUE[@]} - i )) — Telegram не отвечает" >> "$EXPIRE_LOG"
      break
    fi
    _expire_notify "${EXPIRE_QUEUE[$i]}"
  done
  return 0
}

expire_install() {
  mkdir -p "$EXPIRE_STATE_DIR"
  emit_script "$EXPIRE_BIN" 'expire_check_run' \
    SERVER_CONF AWG_IF EXPIRE_SUSPEND_IP EXPIRE_STATE_DIR EXPIRE_LOG BOT_CONF BOT_ADMINS TRAFFIC_DB _PY_HELPER STATE_DIR EXPIRE_LOCK_MAX \
    py _expire_notify _expire_esc _expire_sync _traffic_snapshot traffic_tick expire_check_run || return 1
  write_unit awg2-expire.service <<EOF
[Unit]
Description=AWG Toolza — сроки и трафик клиентов
After=awg-quick@awg0.service network-online.target

[Service]
Type=oneshot
ExecStart=$EXPIRE_BIN
# У oneshot тайм-аута нет: зависший проход (awg show, syncconf) навсегда
# останавливал бы и таймер — сторож его перезапуском не снимает
TimeoutStartSec=120
# Запуск каждые 15 с: «Starting/Finished» в журнал не пишем, сбои — пишем
LogLevelMax=notice
EOF
  # Каждые 15 секунд по часам: превысивший лимит блокируется не позже чем
  # через 15 с (что успеет скачать за это время — перерасход). Прежний
  # OnUnitActiveSec отсчитывал от прошлого запуска службы и после
  # переустановки сервера мог не сработать больше никогда (см. timer_heal);
  # расписание по часам от истории не зависит.
  write_unit awg2-expire.timer <<'EOF'
[Unit]
Description=AWG Toolza — таймер сроков и трафика клиентов

[Timer]
OnCalendar=*-*-* *:*:00/15
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
  systemctl enable --now awg2-expire.timer &>/dev/null || warn "Таймер сроков не запустился: systemctl status awg2-expire.timer"
  timer_heal awg2-expire.timer
}

# Сторож таймера: каждый проход таймера пишет счётчики в $EXPIRE_STATE_DIR/transfer.
# Файл старше 5 минут — таймер молчит, и сроки с лимитами не блокируют: поставить
# таймер заново, перезапустить и сразу сделать проход. Зовётся при каждом запуске
# awg2 (меню, бот, панель) — стоит одного stat.
EXPIRE_STALE=300
expire_watchdog() {
  local tr="$EXPIRE_STATE_DIR/transfer" age
  server_exists || return 0
  [[ -f "$tr" ]] || return 0            # таймер ещё ни разу не проходил — поставит expire_install
  age=$(( $(date +%s) - $(stat -c %Y "$tr" 2>/dev/null || echo 0) ))
  (( age < EXPIRE_STALE )) && return 0
  mkdir -p "$(dirname "$EXPIRE_LOG")"
  echo "$(date '+%F %T') watchdog: таймер молчал ${age}с — перезапуск" >> "$EXPIRE_LOG"
  log_warn "таймер сроков и лимитов молчал ${age}с — перезапуск"
  touch "$tr"                           # параллельные вызовы awg2 не перезапускают его разом
  expire_install &>/dev/null
  systemctl restart awg2-expire.timer &>/dev/null || true
  systemctl start --no-block awg2-expire.service &>/dev/null || true
}

expire_remove() {
  remove_unit awg2-expire.timer awg2-expire.service
  rm -f "$EXPIRE_BIN" "$TRAFFIC_DB" "$TRAFFIC_DB.lock"
  rm -rf "$EXPIRE_STATE_DIR"
}

expire_fmt() {  # unix-время → «31.12.2026 23:59 (через 3д 4ч)»
  local ts="$1" d abs s="" when
  d=$(( ts - $(date +%s) )); abs=${d#-}
  (( abs >= 86400 )) && s+="$((abs / 86400))д "
  (( abs % 86400 >= 3600 )) && s+="$((abs % 86400 / 3600))ч "
  (( abs < 86400 )) && s+="$((abs % 3600 / 60))м"
  s="${s% }"
  when=$(date -d "@$ts" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "$ts")
  if (( d >= 0 )); then echo "$when (через $s)"; else echo "$when (истёк $s назад)"; fi
}

_expire_apply() {
  local stripped
  iface_up || return 0
  stripped=$(awg-quick strip "$AWG_IF" 2>/dev/null) && awg syncconf "$AWG_IF" <(printf '%s\n' "$stripped")
}

# Строки трафика для меню: «имя|лимит|период|по лимиту|за месяц|сегодня|причина».
traffic_rows() {
  local tr
  server_exists || return 0
  mktmp tr || return 1
  awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
  py traffic-rows "$SERVER_CONF" "$TRAFFIC_DB" "$tr" | tr '\t' '|'
}

_ask_limit() {  # → «РАЗМЕР ПЕРИОД» в stdout или пусто
  local v p
  echo -e "  ${D}Размер: 50G, 500M, 1.5T; число без буквы — гигабайты${N}" >&2
  read -rp "  Лимит: " v
  [[ -n "$v" ]] || return 0
  py size-parse "$v" >/dev/null 2>&1 || { warn "Размер не распознан: $v" >&2; return 0; }
  echo -e "  ${C}1)${N} В месяц ${D}— счётчик обнуляется 1-го числа, клиент разблокируется сам${N}" >&2
  echo -e "  ${C}2)${N} Всего ${D}— без сброса, с этой минуты${N}" >&2
  read_choice p "${C}  Период [1-2]: ${N}" 1 2 1
  echo "$v $([[ "$p" == 2 ]] && echo total || echo month)"
}

do_traffic_days() {
  local tr
  server_exists || { err "Сервер не создан"; return 1; }
  mktmp tr || return 1
  awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
  echo ""
  hdr "Трафик по дням"
  py traffic-report "$SERVER_CONF" "$TRAFFIC_DB" "$tr" 14 | sed 's/^/  /'
  [[ -f "$TRAFFIC_DB" ]] || info "Учёт идёт с момента установки $VERSION — данные копятся каждые 15 секунд"
}

do_expire_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  expire_install
  local c name pub ts rows=() n=0 exp orig lim per used month _ by ans
  local -A tl=()
  while true; do
    echo ""
    hdr "Сроки и лимиты трафика"
    tl=()
    while IFS='|' read -r name lim per used month _ by; do
      [[ -n "$name" && "$lim" != 0 ]] && tl[x$name]="$lim/$per|$used|$by"
    done < <(traffic_rows)
    while IFS='|' read -r name pub _ exp orig _; do
      [[ -n "$exp" || -n "${tl[x$name]:-}" ]] || continue
      n=$((n + 1))
      by="${tl[x$name]:-}"; by="${by##*|}"
      if [[ -n "$orig" && "$by" == traffic ]]; then echo -e "  ${R}🚫 ${name}${N} ${D}— заблокирован: исчерпан лимит${N}"
      elif [[ -n "$orig" ]]; then echo -e "  ${R}🚫 ${name}${N} ${D}— заблокирован, $(expire_fmt "$exp")${N}"
      elif [[ -n "$exp" ]]; then echo -e "  ${Y}⏰ ${name}${N} ${D}— $(expire_fmt "$exp")${N}"
      else echo -e "  ${C}📶 ${name}${N}"; fi
      if [[ -n "${tl[x$name]:-}" ]]; then
        IFS='|' read -r lim used _ <<< "${tl[x$name]}"
        echo -e "     ${D}трафик: $(limit_fmt "$lim" "$used")${N}"
      fi
    done < <(clients_psv)
    (( n )) || echo -e "  ${D}Сроков и лимитов нет — все клиенты бессрочные и без лимита${N}"
    n=0
    echo ""
    echo -e "  ${C}1)${N} Поставить срок"
    echo -e "  ${C}2)${N} Снять срок / разблокировать"
    echo -e "  ${C}3)${N} Лимит трафика"
    echo -e "  ${C}4)${N} Снять лимит трафика"
    echo -e "  ${C}5)${N} Обнулить счётчик лимита"
    echo -e "  ${C}6)${N} Трафик по дням"
    echo -e "  ${R}7)${N} Удалить с истёкшим сроком"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-7]: ${N}" 0 7 0
    case "$c" in
      1) _pick_client || continue
         name="${CHOSEN%%$'\t'*}"
         [[ -n "$name" ]] || { warn "У клиента нет имени"; continue; }
         ts=$(_ask_expire)
         [[ -n "$ts" ]] && { client_expire_set "$name" "$ts" || true; } ;;
      2) _pick_client || continue
         client_expire_clear "${CHOSEN%%$'\t'*}" || true ;;
      3) _pick_client || continue
         name="${CHOSEN%%$'\t'*}"
         [[ -n "$name" ]] || { warn "У клиента нет имени"; continue; }
         ans=$(_ask_limit)
         [[ -n "$ans" ]] && { client_limit_set "$name" "${ans% *}" "${ans#* }" || true; } ;;
      4) _pick_client || continue
         client_limit_set "${CHOSEN%%$'\t'*}" off || true ;;
      5) _pick_client || continue
         client_limit_reset "${CHOSEN%%$'\t'*}" || true ;;
      6) do_traffic_days || true; pause ;;
      7) mapfile -t rows < <(clients_tsv | awk -F'\t' '$5 != "" && $8 != "traffic" {print $1}')
         (( ${#rows[@]} )) || { info "Клиентов с истёкшим сроком нет"; continue; }
         warn "Будут удалены навсегда: ${rows[*]}"
         read_confirm "${R}  Подтверди (введи yes): ${N}" && clients_purge_blocked ;;
      0) return 0 ;;
    esac
  done
}

# ═════ tunnels ═════
# Общее для туннелей: загрузка релизов, списки клиентов, маршрутизация,
# взаимоисключение и аварийный сброс.
#
# Схема у всех туннелей одна: трафик выбранных клиентов уходит в свою
# таблицу маршрутизации (ip rule from <клиент> lookup N), где маршрут по
# умолчанию ведёт в интерфейс туннеля. Трафик самого сервера и SSH идут
# напрямую — main-таблица не трогается. Таблицы: 100 tun2socks, 200 WARP,
# 201 Xray, 202 AWG exit-ноды (210-249 — персональные ноды клиентов).
# Одновременно активен только один из WARP / Xray / tun2socks / exit-нод.

# ── Загрузка релизов ──────────────────────────────────────
# GitHub в части сетей режут — пробуем зеркала. Файл потом запускается от
# root, поэтому проверяем, что пришёл именно архив/бинарь, а не HTML-заглушка.
gh_fetch() {  # url файл мин_размер zip|elf|any
  local url="$1" dest="$2" min="${3:-100000}" kind="${4:-any}" mp sz
  for mp in "${GH_MIRRORS[@]}"; do
    rm -f "$dest"
    curl -4 -fsSL --connect-timeout 8 --max-time 180 --retry 2 "${mp}${url}" -o "$dest" 2>/dev/null || continue
    sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    (( sz >= min )) || continue
    case "$kind" in
      zip) [[ "$(head -c2 "$dest")" == PK ]] || continue ;;
      elf) head -c4 "$dest" | grep -q $'\x7fELF' || continue ;;
    esac
    return 0
  done
  rm -f "$dest"
  return 1
}

# 0 — совпало, 1 — не совпало, 2 — сверять не с чем.
sha256_check() {
  local f="$1" want="${2,,}"
  [[ "$want" =~ ^[0-9a-f]{64}$ && -f "$f" ]] || return 2
  [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "$want" ]]
}

gh_latest_tag() {  # owner/repo
  GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote --tags --refs "https://github.com/$1.git" 2>/dev/null \
    | sed -n 's#.*refs/tags/##p' | grep -E '^v?[0-9]+\.[0-9]+' | sort -V | tail -1
}

go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;; *) echo "" ;;
  esac
}

# ── Списки клиентов туннеля ───────────────────────────────
# Файл — по адресу клиента на строку (у exit-нод — «адрес|нода»).
# Файла нет — туннель ещё ни разу не включали: при первом включении в него
# попадают все клиенты. Пустой файл — все сознательно выключены.
peers_has() { [[ -f "$1" ]] && grep -qE "^${2//./\\.}(\||$)" "$1"; }

peers_add() {  # файл ip [значение строки]
  mkdir -p "$(dirname "$1")"
  peers_del "$1" "$2"
  echo "${3:-$2}" >> "$1"
}

peers_del() {
  [[ -f "$1" ]] || return 0
  grep -vE "^${2//./\\.}(\||$)" "$1" > "$1.tmp" || true
  mv -f "$1.tmp" "$1"
}

# Убрать адреса, которых больше нет среди клиентов.
peers_sync() {
  local f="$1" live line
  [[ -f "$f" ]] || return 0
  live=" $(clients_name_ip | cut -d'|' -f2 | tr '\n' ' ') "
  while IFS= read -r line; do
    [[ -n "$line" && "$live" == *" ${line%%|*} "* ]] && echo "$line"
  done < "$f" > "$f.tmp" || true
  mv -f "$f.tmp" "$f"
}

# Все клиенты через туннель; строки «IP|выход» (свой выход Xray) остаются.
peers_all() {  # файл
  local ip
  mkdir -p "$(dirname "$1")"
  clients_name_ip | cut -d'|' -f2 | while IFS= read -r ip; do
    grep -E "^${ip//./\\.}(\||$)" "$1" 2>/dev/null | head -1 | grep . || echo "$ip"
  done > "$1.new"
  mv -f "$1.new" "$1"
}

# Свои выходы клиентов Xray живут в конфиге самого Xray (правила по адресу):
# изменились — без пересборки конфига клиент оставался на прежнем выходе,
# хотя список показывал «по умолчанию» или «напрямую».
_xray_outs() { grep -F '|' "$XRAY_PEERS" 2>/dev/null | sort; }
_xray_outs_apply() {  # прежний вывод _xray_outs
  [[ "$(_xray_outs)" != "$1" ]] && xray_is_up || return 0
  _xray_prepare || return 1
  info "Перезапускаю туннель"; xray_restart
}

peers_seed() {
  [[ -f "$1" ]] && return 0
  mkdir -p "$(dirname "$1")"
  clients_name_ip | cut -d'|' -f2 > "$1"
}

# Клиент удалён — убрать его из всех туннелей и снять его правила.
tunnel_peers_forget() {
  local ip="$1" f
  for f in "$WARP_PEERS" "$XRAY_PEERS" "$EXITS_PEERS"; do peers_del "$f" "$ip"; done
  while ip rule del from "$ip" 2>/dev/null; do :; done
}

# ── Маршрутизация ─────────────────────────────────────────
# Функции ниже работают и в служебных скриптах (emit_script), поэтому
# опираются только на константы и базовые помощники.
RT_FUNCS=(valid_ip valid_cidr conf_iface_get server_net ipt_add ipt_ins ipt_del
          ipt_del_grep ipt_del_tagged rp_filter_loose rt_fw_up rt_fw_down rt_up rt_down
          rt_rules_clear SERVER_CONF AWG_IF)

rt_rules_clear() {  # таблица
  local guard=0
  while (( guard++ < 256 )) && ip rule del lookup "$1" 2>/dev/null; do :; done
}

# NAT и FORWARD между awg0 и туннелем. Правила помечены «awg2-tun-<dev>».
rt_fw_up() {  # устройство [nonat]
  local dev="$1" net tag="awg2-tun-$1"
  net=$(server_net) || return 1
  # nonat — устройство должно видеть адреса клиентов (inbound tun Xray
  # выбирает выход клиента по его адресу)
  if [[ "${2:-}" == nonat ]]; then
    ipt_del -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE -m comment --comment "$tag"
  else
    ipt_add -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE -m comment --comment "$tag"
  fi
  ipt_ins FORWARD -i "$AWG_IF" -o "$dev" -j ACCEPT -m comment --comment "$tag"
  ipt_ins FORWARD -i "$dev" -o "$AWG_IF" -j ACCEPT -m comment --comment "$tag"
  # MSS по MTU маршрута: у туннеля MTU меньше, а ICMP «нужна фрагментация»
  # до клиента доходит не всегда — без клампа крупные TCP-сессии виснут.
  ipt_add -t mangle FORWARD -o "$dev" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag"
  ipt_add -t mangle FORWARD -i "$dev" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag"
  # Обратная проверка пути для адреса клиента ведёт в таблицу туннеля, а не
  # на awg0 — строгий rp_filter такие пакеты молча дропает.
  rp_filter_loose "$dev" "$AWG_IF"
}

# Снимает правила и этой версии, и прежних (те ставились без метки).
rt_fw_down() {  # устройство
  local dev="$1" net t
  for t in nat filter mangle; do ipt_del_tagged "$t" "awg2-tun-$dev"; done
  net=$(server_net 2>/dev/null) || net=""
  if [[ -n "$net" ]]; then
    ipt_del -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE
    ipt_del FORWARD -i "$AWG_IF" -o "$dev" -j ACCEPT
    ipt_del FORWARD -i "$dev" -o "$AWG_IF" -j ACCEPT
  fi
  ipt_del_grep mangle "-o $dev .*TCPMSS"
  ipt_del_grep mangle "-i $dev .*TCPMSS"
  ipt_del FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$AWG_IF" -j TCPMSS --clamp-mss-to-pmtu
  return 0
}

# rt_up УСТРОЙСТВО ТАБЛИЦА ФАЙЛ_КЛИЕНТОВ|- [SRC]
# «-» вместо файла — вся подсеть клиентов (как у tun2socks).
rt_up() {  # устройство таблица peers|- [src] [nonat]
  local dev="$1" table="$2" peers="$3" src="${4:-}" net ip line
  net=$(server_net) || return 1
  if [[ -n "$src" ]]; then
    ip route replace default dev "$dev" src "$src" table "$table" || return 1
  else
    ip route replace default dev "$dev" table "$table" || return 1
  fi
  rt_rules_clear "$table"
  if [[ "$peers" == - ]]; then
    ip rule add from "$net" lookup "$table" priority "$table" || return 1
  elif [[ -f "$peers" ]]; then
    while IFS= read -r line; do
      ip="${line%%|*}"
      valid_ip "$ip" && ip rule add from "$ip" lookup "$table" priority "$table"
    done < "$peers"
  fi
  rt_fw_up "$dev" "${5:-}"
}

rt_down() {  # устройство таблица
  rt_rules_clear "$2"
  ip route flush table "$2" 2>/dev/null || true
  rt_fw_down "$1"
}

# ── Состояние и взаимоисключение ──────────────────────────
warp_is_up()  { ip link show "$WARP_IF" &>/dev/null; }
xray_is_up()  { ip link show "$XRAY_IF" &>/dev/null || unit_active "$XRAY_UNIT"; }
t2s_is_up()   { unit_active "$T2S_UNIT"; }
exits_is_up() { unit_active "$EXITS_UNIT"; }

# Кто из туннелей уже активен (кроме $1). Пусто — никто.
tunnel_conflict() {
  local me="$1" others=()
  [[ "$me" != warp ]] && warp_is_up && others+=(WARP)
  [[ "$me" != xray ]] && xray_is_up && others+=(Xray)
  [[ "$me" != tun2socks ]] && t2s_is_up && others+=(tun2socks)
  [[ "$me" != exits ]] && exits_is_up && others+=("AWG exit-ноды")
  echo "${others[*]}"
}

tunnel_guard() {  # имя → 1, если занято другим туннелем
  local c
  c=$(tunnel_conflict "$1")
  [[ -z "$c" ]] && return 0
  err "Уже активен туннель: $c — одновременно работает только один"
  info "Выключи его или сделай аварийный сброс (Туннели → Аварийный сброс)"
  return 1
}

# Аварийный сброс: гасит все туннели и возвращает клиентов на прямой
# маршрут. Из настроек ничего не удаляется.
tunnels_panic_reset() {
  local quiet="${1:-}" u net dev
  if [[ "$quiet" != quiet ]]; then
    warn "Все туннели (WARP, Xray, tun2socks, exit-ноды) будут выключены,"
    warn "клиенты пойдут напрямую через сервер. Настройки сохранятся."
    ask_yes "  Продолжить? [Y/n]: " y || return 0
  fi
  # Автозапуск тоже снимаем: иначе после перезагрузки туннель вернётся
  for u in "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" "$T2S_UNIT" "$EXITS_UNIT" awg-usque.service awg-warp.service; do
    systemctl disable --now "$u" &>/dev/null || true
    systemctl reset-failed "$u" &>/dev/null || true
  done
  rt_down "$WARP_IF" "$WARP_TABLE"
  rt_down "$XRAY_IF" "$XRAY_TABLE"
  rt_down "$T2S_IF" "$T2S_TABLE"
  exits_rules_clear
  for dev in "$EXITS_DIR"/awg-exit-*.conf; do
    [[ -f "$dev" ]] && rt_fw_down "$(basename "$dev" .conf)"
  done
  for dev in "$XRAY_IF" "$T2S_IF" "$WARP_IF"; do ip link del "$dev" &>/dev/null || true; done
  rm -f "$XRAY_STATE" "$EXITS_STATE" "$WARP_STATE"
  net=$(server_net 2>/dev/null) || net=""
  dev=$(uplink_iface 2>/dev/null) || dev=""
  # То же, что ставит PostUp сервера — на случай, если его правила сбиты
  [[ -n "$net" && -n "$dev" ]] && ipt_add -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE
  ipt_ins FORWARD -i "$AWG_IF" -j ACCEPT
  ipt_ins FORWARD -o "$AWG_IF" -j ACCEPT
  ip_forward_enable
  [[ "$quiet" == quiet ]] || ok "Туннели выключены — клиенты идут напрямую"
  log_warn "аварийный сброс туннелей"
}

# ── Выбор клиентов для туннеля ────────────────────────────
# Правила работающего туннеля пересобираются по списку целиком.
_tunnel_rules_refresh() {  # файл устройство таблица
  local ip
  ip link show "$2" &>/dev/null || return 0
  rt_rules_clear "$3"
  while IFS= read -r ip; do
    valid_ip "${ip%%|*}" && ip rule add from "${ip%%|*}" lookup "$3" priority "$3"
  done < "$1"
  return 0
}

# tunnel_client warp|xray ИМЯ|all|none on|off
tunnel_client() {
  local file dev table ip outs
  case "$1" in
    warp) file="$WARP_PEERS"; dev="$WARP_IF"; table="$WARP_TABLE" ;;
    xray) file="$XRAY_PEERS"; dev="$XRAY_IF"; table="$XRAY_TABLE" ;;
    *) err "Туннель: warp | xray"; return 1 ;;
  esac
  mkdir -p "$(dirname "$file")"
  peers_sync "$file"
  outs=$(_xray_outs)
  # all / none без третьего аргумента — все клиенты; с ним — клиент с таким
  # именем: «tunnels client xray all off» не должно включать всех
  case "$2${3:+|}" in
    all) peers_all "$file" ;;
    none) : > "$file" ;;
    *) ip=$(clients_name_ip | awk -F'|' -v n="$2" '$1 == n {print $2; exit}')
       [[ -n "$ip" ]] || { err "Клиента $2 нет"; return 1; }
       peers_seed "$file"
       if [[ "${3:-on}" == on ]]; then peers_has "$file" "$ip" || peers_add "$file" "$ip"
       else peers_del "$file" "$ip"; fi ;;
  esac
  _tunnel_rules_refresh "$file" "$dev" "$table"
  ok "Клиенты ${1^^}: $(grep -c . "$file" || true) через туннель"
  if [[ "$1" == xray ]]; then _xray_outs_apply "$outs" || return 1; fi
  return 0
}
# tunnel_peers_menu ЗАГОЛОВОК ФАЙЛ УСТРОЙСТВО ТАБЛИЦА
tunnel_peers_menu() {
  local title="$1" file="$2" dev="$3" table="$4" rows=() i c name ip outs
  while true; do
    peers_sync "$file"
    outs=$(_xray_outs)
    mapfile -t rows < <(clients_name_ip)
    (( ${#rows[@]} )) || { warn "Клиентов нет"; return 0; }
    echo ""
    hdr "$title"
    for i in "${!rows[@]}"; do
      name="${rows[$i]%%|*}"; ip="${rows[$i]#*|}"
      if peers_has "$file" "$ip"; then echo -e "  ${G}$((i + 1)))${N} $name ${D}$ip${N}  ${C}через туннель${N}"
      else echo -e "  ${D}$((i + 1))) $name $ip  напрямую${N}"; fi
    done
    echo -e "  ${C}a)${N} Все через туннель"
    echo -e "  ${C}n)${N} Все напрямую"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер — вкл/выкл: ${N}" 0 "${#rows[@]}" 0 "a|n"
    case "$c" in
      0) return 0 ;;
      a) peers_all "$file" ;;
      n) : > "$file" ;;
      *) ip="${rows[$((c - 1))]#*|}"
         if peers_has "$file" "$ip"; then peers_del "$file" "$ip"; else peers_add "$file" "$ip"; fi ;;
    esac
    _tunnel_rules_refresh "$file" "$dev" "$table"
    [[ "$file" == "$XRAY_PEERS" ]] && { _xray_outs_apply "$outs" || true; }
  done
}

# ── Меню ──────────────────────────────────────────────────
_tun_state() {  # функция-проверка «включён» и файлы, по которым «настроен»
  local up="$1" f
  shift
  if "$up"; then echo -e "${G}● включён${N}"; return; fi
  for f in "$@"; do [[ -e "$f" ]] && { echo -e "${D}○ настроен, выключен${N}"; return; }; done
  echo -e "${D}○ не настроен${N}"
}

do_tunnels_menu() {
  local c
  while true; do
    echo ""
    hdr "Туннели и DNS"
    echo -e "  ${C}1)${N} WARP (Cloudflare)   $(_tun_state warp_is_up "$WARP_CONF" "$USQUE_CONF")"
    echo -e "  ${C}2)${N} Xray                $(_tun_state xray_is_up "$XRAY_CONF")"
    echo -e "  ${C}3)${N} tun2socks           $(_tun_state t2s_is_up "$T2S_CONF")"
    echo -e "  ${C}4)${N} AWG exit-ноды       $(_tun_state exits_is_up "$EXITS_DIR"/awg-exit-*.conf)"
    echo -e "  ${C}5)${N} Каскад портов       $(cascade_state_line)"
    echo -e "  ${C}6)${N} Шифрованный DNS     $(dns_state_line)"
    echo -e "  ${R}9)${N} Аварийный сброс ${D}— все клиенты напрямую${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 9 0
    case "$c" in
      1) do_warp_menu || true ;;
      2) do_xray_menu || true ;;
      3) do_tun2socks_menu || true ;;
      4) do_exits_menu || true ;;
      5) do_cascade_menu || true ;;
      6) do_dns_menu || true ;;
      9) tunnels_panic_reset || true; pause ;;
      0) return 0 ;;
    esac
  done
}

# ═════ warp ═════
# WARP (Cloudflare): выход клиентов через Cloudflare, когда IP сервера в
# блок-листах. Два бэкенда с одним интерфейсом warp0 — поэтому список
# клиентов, правила и статус в боте от бэкенда не зависят:
#   wg    — kernel WireGuard, профиль от wgcf. Быстрый, нужен модуль wireguard.
#   usque — MASQUE поверх QUIC в userspace. Без модулей ядра, дороже по CPU.

warp_backend() {
  local b
  b=$(tr -d '[:space:]' 2>/dev/null < "$WARP_BACKEND_FILE" || true)
  [[ "$b" == usque ]] && echo usque || echo wg
}

warp_wg_possible()    { modprobe wireguard 2>/dev/null || [[ -d /sys/module/wireguard ]]; }
warp_usque_possible() {
  [[ -n "$(go_arch)" ]] || return 1
  [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null
  [[ -c /dev/net/tun ]]
}

_warp_deps() {
  need_cmds wg:wireguard-tools ping:iputils-ping || return 1
  mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
}

_warp_state_write() {  # бэкенд
  mkdir -p "$WARP_DIR"
  printf 'active\nbackend=%s\nclient_net=%s\niface=%s\n' "$1" "$(server_net)" "$(uplink_iface)" > "$WARP_STATE"
}

# ── Бэкенд wg ─────────────────────────────────────────────
_wgcf_install() {
  local arch vers=() v tmp
  command -v wgcf &>/dev/null && wgcf --help &>/dev/null && return 0
  arch=$(go_arch)
  [[ -n "$arch" ]] || { err "Архитектура $(uname -m) не поддерживается wgcf"; return 1; }
  v=$(gh_latest_tag ViRb3/wgcf)
  [[ -n "$v" ]] && vers+=("${v#v}")
  vers+=("${WGCF_FALLBACK_VERS[@]}")
  mktmp tmp || return 1
  for v in "${vers[@]}"; do
    info "Скачиваю wgcf v$v..."
    if gh_fetch "https://github.com/ViRb3/wgcf/releases/download/v$v/wgcf_${v}_linux_${arch}" "$tmp" 1000000 elf; then
      install -m 755 "$tmp" /usr/local/bin/wgcf
      wgcf --help &>/dev/null && { ok "wgcf v$v установлен"; return 0; }
    fi
  done
  err "wgcf не скачался ни напрямую, ни через зеркала"
  return 1
}

_wgcf_register() {
  local i delay=3 out
  mkdir -p "$WARP_DIR"
  [[ -f "$WARP_ACCOUNT" ]] && { info "Аккаунт WARP уже зарегистрирован"; return 0; }
  for i in 1 2 3; do
    info "Регистрация в Cloudflare, попытка $i/3..."
    if out=$(cd "$WARP_DIR" && wgcf register --accept-tos 2>&1) && [[ -f "$WARP_ACCOUNT" ]]; then
      chmod 600 "$WARP_ACCOUNT"
      ok "Аккаунт WARP зарегистрирован"
      return 0
    fi
    (( i < 3 )) && { sleep "$delay"; delay=$(( delay * 2 )); }
  done
  err "Регистрация не удалась: $(tail -1 <<< "$out")"
  info "С российских VPS API Cloudflare часто недоступен — зарегистрируй профиль"
  info "в другом месте и импортируй его: пункт «Импорт wgcf-profile.conf»"
  return 1
}

_wgcf_generate() {
  (cd "$WARP_DIR" && wgcf generate) >/dev/null 2>&1 && [[ -f "$WARP_PROFILE" ]] \
    || { err "wgcf generate не сработал"; return 1; }
  install -m 600 "$WARP_PROFILE" "$WARP_CONF"
  ok "Профиль: $WARP_CONF"
}

warp_wg_install() { _warp_deps && _wgcf_install && _wgcf_register && _wgcf_generate; }

warp_license() {
  local key
  info "Ключ Warp+ — в приложении 1.1.1.1: Аккаунт → Ключ (формат xxxx-xxxx-xxxx)"
  read_line key "${C}  Ключ (Enter — отмена): ${N}"
  [[ -z "$key" ]] && return 0
  warp_license_set "$key"
}

warp_license_set() {  # ключ
  local key="$1" type
  [[ -f "$WARP_ACCOUNT" ]] && grep -q '^license_key\|^access_token\|^device_id' "$WARP_ACCOUNT" \
    || { err "Сначала зарегистрируй аккаунт WARP"; return 1; }
  [[ "$key" =~ ^[A-Za-z0-9]+-[A-Za-z0-9]+-[A-Za-z0-9]+$ ]] || { err "Неверный формат ключа"; return 1; }
  if grep -q '^license_key' "$WARP_ACCOUNT"; then sed -i "s|^license_key = .*|license_key = \"$key\"|" "$WARP_ACCOUNT"
  else echo "license_key = \"$key\"" >> "$WARP_ACCOUNT"; fi
  (cd "$WARP_DIR" && wgcf update) &>/dev/null || { err "Cloudflare не принял ключ"; return 1; }
  type=$(cd "$WARP_DIR" && wgcf status 2>/dev/null | grep -oP 'Account type\s*:\s*\K\S+' || true)
  case "$type" in
    unlimited|limited|premium) ok "Warp+ активирован ($type)"; echo "$type" > "$WARP_DIR/account_type" ;;
    *) warn "Ключ применён, но Warp+ не активен (${type:-тип неизвестен})"; rm -f "$WARP_DIR/account_type" ;;
  esac
  _wgcf_generate || return 1
  warp_is_up && info "Туннель работает на старом профиле — перезапусти его"
  return 0
}

# Импорт готового wgcf-profile.conf (регистрация с сервера не проходит).
warp_import() {
  local content k
  _warp_deps || return 1
  echo -e "  Зарегистрируй профиль там, где Cloudflare доступен (например, shell.cloud.google.com):"
  echo -e "  ${G}curl -fsSL -o wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.30/wgcf_2.2.30_linux_amd64 && chmod +x wgcf && ./wgcf register --accept-tos && ./wgcf generate && cat wgcf-profile.conf${N}"
  echo -e "  Вставь вывод целиком, затем Enter и Ctrl+D:"
  content=$(cat)
  for k in '^\[Interface\]' '^PrivateKey' '^Address' '^\[Peer\]' '^PublicKey' '^Endpoint'; do
    grep -q "$k" <<< "$content" || { err "Не похоже на wgcf-profile.conf: нет ${k//[\\^]/}"; return 1; }
  done
  mkdir -p "$WARP_DIR"
  [[ -f "$WARP_PROFILE" ]] && cp -a "$WARP_PROFILE" "$WARP_PROFILE.bak.$(date +%s)"
  printf '%s\n' "$content" | write_file "$WARP_PROFILE" 600
  install -m 600 "$WARP_PROFILE" "$WARP_CONF"
  [[ -f "$WARP_ACCOUNT" ]] || printf '# импортирован готовый профиль\nimported = true\n' | write_file "$WARP_ACCOUNT" 600
  ok "Профиль импортирован — включай туннель"
}

# Поднимает warp0 из профиля и уводит в него клиентов. Работает и в
# скрипте автозапуска, поэтому без вывода в интерфейс пользователя.
warp_wg_bringup() {
  local priv pub ep mtu addr a tmp
  [[ -f "$WARP_CONF" && -f "$SERVER_CONF" ]] || return 1
  ip link show "$WARP_IF" &>/dev/null && return 0
  priv=$(awk -F' = ' '/^PrivateKey/{print $2; exit}' "$WARP_CONF")
  pub=$(awk -F' = ' '/^PublicKey/{print $2; exit}' "$WARP_CONF")
  ep=$(awk -F' = ' '/^Endpoint/{print $2; exit}' "$WARP_CONF")
  mtu=$(awk -F' = ' '/^MTU/{print $2; exit}' "$WARP_CONF")
  # Только IPv4-адрес: IPv6 в туннель не пускаем (утечки, IPv6 часто выключен)
  for a in $(awk -F' = ' '/^Address/{print $2}' "$WARP_CONF" | tr ',' ' '); do
    [[ "$a" == *.* ]] && addr="$a"
  done
  [[ -n "$priv" && -n "$pub" && -n "$ep" && -n "${addr:-}" ]] || { echo "профиль WARP не разобран" >&2; return 1; }
  ip link add dev "$WARP_IF" type wireguard || return 1
  # Временный файл — в /etc/wireguard: пакетный wg на Ubuntu 26.04 не читает
  # из /tmp (AppArmor), а /etc/wireguard — каталог root:700.
  tmp="/etc/wireguard/.warp0.$$"
  printf '[Interface]\nPrivateKey = %s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = %s\n' \
    "$priv" "$pub" "$ep" > "$tmp"
  chmod 600 "$tmp"
  if ! wg setconf "$WARP_IF" "$tmp"; then rm -f "$tmp"; ip link del "$WARP_IF"; return 1; fi
  rm -f "$tmp"
  ip -4 addr add "$addr" dev "$WARP_IF"
  ip link set mtu "${mtu:-1280}" up dev "$WARP_IF" || { ip link del "$WARP_IF"; return 1; }
  rt_up "$WARP_IF" "$WARP_TABLE" "$WARP_PEERS" "${addr%/*}"
}

_warp_autostart_install() {
  emit_script "$WARP_AUTOSTART_SCRIPT" 'warp_wg_bringup' \
    WARP_CONF WARP_IF WARP_TABLE WARP_PEERS "${RT_FUNCS[@]}" warp_wg_bringup || return 1
  write_unit awg-warp.service <<EOF
[Unit]
Description=AWG Toolza — WARP для клиентов AWG
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=$WARP_STATE
ConditionPathExists=$WARP_CONF

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$WARP_AUTOSTART_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable awg-warp.service &>/dev/null
}

# ── Бэкенд usque ──────────────────────────────────────────
_usque_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo linux_amd64 ;; aarch64|arm64) echo linux_arm64 ;;
    armv7l|armv7) echo linux_armv7 ;; *) echo "" ;;
  esac
}

_usque_install_bin() {
  local arch ver tmp asset want
  "$USQUE_BIN" version &>/dev/null && return 0
  arch=$(_usque_arch)
  need_cmds unzip:unzip || return 1
  ver=$(gh_latest_tag Diniboy1123/usque); ver="${ver#v}"
  ver="${ver:-$USQUE_FALLBACK_VER}"
  mktmp tmp -d || return 1
  asset="usque_${ver}_${arch}.zip"
  info "Скачиваю usque v$ver..."
  gh_fetch "https://github.com/Diniboy1123/usque/releases/download/v$ver/$asset" "$tmp/u.zip" 100000 zip \
    || { err "usque не скачался"; return 1; }
  if gh_fetch "https://github.com/Diniboy1123/usque/releases/download/v$ver/checksums.txt" "$tmp/sums" 64 any; then
    want=$(awk -v a="$asset" '$2 == a {print $1; exit}' "$tmp/sums")
    sha256_check "$tmp/u.zip" "$want" || { [[ $? == 1 ]] && { err "Контрольная сумма usque не совпала"; return 1; }; }
  fi
  unzip -oq "$tmp/u.zip" usque -d "$tmp" && install -m 755 "$tmp/usque" "$USQUE_BIN" || return 1
  "$USQUE_BIN" version &>/dev/null || { rm -f "$USQUE_BIN"; err "usque не запускается"; return 1; }
  ok "usque v$ver установлен"
}

_usque_register() {
  local i delay=5 out
  mkdir -p "$USQUE_DIR" && chmod 700 "$USQUE_DIR"
  [[ -s "$USQUE_CONF" ]] && return 0
  for i in 1 2 3 4; do
    info "Регистрация usque, попытка $i/4..."
    out=$("$USQUE_BIN" register --accept-tos --config "$USQUE_CONF" 2>&1) && [[ -s "$USQUE_CONF" ]] \
      && { chmod 600 "$USQUE_CONF"; ok "Устройство зарегистрировано"; return 0; }
    # Лимит частоты регистраций — не ошибка, а «приходи позже»
    grep -qiE '429|rate.?limit|too many' <<< "$out" && warn "Cloudflare ограничил частоту регистраций"
    (( i < 4 )) && { sleep "$delay"; delay=$(( delay * 3 )); }
  done
  err "Регистрация usque не удалась — подожди 10-15 минут и повтори"
  return 1
}

# Хук on-connect: usque вызывает его при каждом (пере)подключении и передаёт
# USQUE_IFACE, USQUE_IPV4, USQUE_ENDPOINT. main-таблицу не трогаем: пример из
# документации usque заворачивает туда default и отрезает сервер от SSH.
usque_on_connect() {
  local dev="${USQUE_IFACE:-$WARP_IF}" src="${USQUE_IPV4:-}" ep gw up
  ep="${USQUE_ENDPOINT:-}"; ep="${ep#[}"; ep="${ep%%]*}"; ep="${ep%%:*}"
  read -r gw up < <(ip -4 route show default | awk '{for(i=1;i<NF;i++){if($i=="via")g=$(i+1); if($i=="dev")d=$(i+1)} print g, d; exit}')
  [[ "$ep" =~ ^[0-9.]+$ && -n "$gw" ]] && ip route replace "$ep/32" via "$gw" dev "$up" 2>/dev/null
  rt_up "$dev" "$WARP_TABLE" "$WARP_PEERS" "${src%%/*}"
  echo "$(date '+%F %T') on-connect: $dev ${src:-?} ${USQUE_ENDPOINT:-?}" >> "$USQUE_LOG"
}

_usque_write() {
  emit_script "$USQUE_UP_HOOK" 'usque_on_connect' WARP_IF WARP_TABLE WARP_PEERS USQUE_LOG \
    "${RT_FUNCS[@]}" usque_on_connect || return 1
  # При обрыве правила не снимаем: usque сам переподключается, а снос правил
  # на каждый разрыв по простою дал бы мигание маршрутов.
  printf '#!/bin/sh\necho "$(date "+%%F %%T") on-disconnect: ${USQUE_EVENT:-?}" >> %s\n' "$USQUE_LOG" \
    | write_file "$USQUE_DOWN_HOOK" 755
  printf 'net.core.rmem_max = 7500000\nnet.core.wmem_max = 7500000\n' | write_file "$USQUE_SYSCTL" 644
  sysctl -q -p "$USQUE_SYSCTL" &>/dev/null || true
  # --no-tunnel-ipv6: IPv6 в туннель не пускаем, а на хостах с выключенным
  # IPv6 usque без него не может создать TUN вообще.
  write_unit awg-usque.service <<EOF
[Unit]
Description=AWG Toolza — WARP через usque (MASQUE)
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=$USQUE_CONF

[Service]
ExecStart=$USQUE_BIN nativetun --config $USQUE_CONF --interface-name $WARP_IF --no-tunnel-ipv6 --always-reconnect --on-connect $USQUE_UP_HOOK --on-disconnect $USQUE_DOWN_HOOK
Restart=always
RestartSec=5
StandardOutput=append:$USQUE_LOG
StandardError=append:$USQUE_LOG

[Install]
WantedBy=multi-user.target
EOF
}

warp_usque_install() { _usque_install_bin && _usque_register && _usque_write; }

# ── Включение / выключение ────────────────────────────────
warp_up() {
  local be i
  server_exists || { err "Сначала создай сервер"; return 1; }
  tunnel_guard warp || return 1
  warp_is_up && { info "WARP уже включён"; return 0; }
  be=$(warp_backend)
  peers_sync "$WARP_PEERS"; peers_seed "$WARP_PEERS"
  if [[ "$be" == usque ]]; then
    [[ -s "$USQUE_CONF" && -x "$USQUE_BIN" ]] || { err "usque не установлен — «Установить и зарегистрировать»"; return 1; }
    _usque_write || return 1
    systemctl enable awg-usque.service &>/dev/null
    systemctl restart awg-usque.service || { err "awg-usque не стартовал: journalctl -u awg-usque"; return 1; }
    for i in {1..20}; do warp_is_up && break; sleep 1; done
  else
    _warp_deps || return 1
    [[ -f "$WARP_CONF" ]] || { err "Нет профиля WARP — «Установить и зарегистрировать» или импорт"; return 1; }
    warp_wg_bringup || { err "warp0 не поднялся"; return 1; }
  fi
  info "Проверяю выход через Cloudflare..."
  for i in 1 2 3; do
    [[ -n "$(iface_egress_ip "$WARP_IF" 5)" ]] && break
    (( i == 3 )) && {
      err "Через WARP трафик не идёт — выключаю, клиенты остаются напрямую"
      [[ "$be" == wg ]] && info "Попробуй найти рабочий endpoint (warpscout) или импортировать профиль"
      warp_down quiet
      return 1
    }
    sleep 2
  done
  _warp_state_write "$be"
  rm -f "$WARP_STATE.failed"
  [[ "$be" == wg ]] && _warp_autostart_install
  ok "WARP включён: клиентов через туннель — $(grep -c . "$WARP_PEERS" || true)"
  info "SSH и трафик самого сервера идут напрямую"
}

warp_down() {
  rt_down "$WARP_IF" "$WARP_TABLE"
  if [[ "$(warp_backend)" == usque ]]; then
    systemctl stop awg-usque.service &>/dev/null || true
    systemctl disable awg-usque.service &>/dev/null || true
  fi
  ip link del "$WARP_IF" &>/dev/null || true
  systemctl disable awg-warp.service &>/dev/null || true
  rm -f "$WARP_STATE" "$WARP_STATE.failed"
  [[ "${1:-}" == quiet ]] || ok "WARP выключен — клиенты идут напрямую"
}

# ── Health-check ──────────────────────────────────────────
# Три провала подряд — клиенты возвращаются на прямой маршрут.
warp_health_run() {
  local f=/tmp/awg-warp-fails n
  ip link show "$WARP_IF" &>/dev/null || exit 0
  command -v ping >/dev/null || exit 0
  if ping -c1 -W3 -I "$WARP_IF" 1.1.1.1 &>/dev/null; then echo 0 > "$f"; exit 0; fi
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$f"
  echo "$(date '+%F %T') FAIL $n/3" >> "$WARP_HEALTH_LOG"
  (( n >= 3 )) || exit 0
  rt_down "$WARP_IF" "$WARP_TABLE"
  # usque держит warp0 сам: гасим службу, иначе warp_is_up остаётся истинным,
  # warp_up отвечает «уже включён», а хук usque при реконнекте вернёт правила.
  if [[ "$(cat "$WARP_BACKEND_FILE" 2>/dev/null)" == usque ]]; then systemctl stop awg-usque.service 2>/dev/null
  else ip link del "$WARP_IF" 2>/dev/null; fi
  echo failed > "$WARP_STATE.failed"
  echo "$(date '+%F %T') FAILOVER: клиенты идут напрямую" >> "$WARP_HEALTH_LOG"
}

warp_health_on() {
  emit_script "$WARP_HEALTH_SCRIPT" 'warp_health_run' WARP_IF WARP_TABLE WARP_STATE \
    WARP_BACKEND_FILE WARP_HEALTH_LOG "${RT_FUNCS[@]}" warp_health_run || return 1
  write_unit awg-warp-healthcheck.service <<EOF
[Unit]
Description=AWG Toolza — проверка WARP

[Service]
Type=oneshot
ExecStart=$WARP_HEALTH_SCRIPT
EOF
  write_unit awg-warp-healthcheck.timer <<'EOF'
[Unit]
Description=AWG Toolza — проверка WARP раз в минуту

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
EOF
  systemctl enable --now awg-warp-healthcheck.timer &>/dev/null && ok "Health-check включён (раз в минуту)"
}

warp_health_off() {
  remove_unit awg-warp-healthcheck.timer awg-warp-healthcheck.service
  rm -f "$WARP_HEALTH_SCRIPT" /tmp/awg-warp-fails
}

# ── warpscout: поиск рабочего endpoint ────────────────────
_warpscout_ready() {
  if ! "$WARPSCOUT_BIN" version &>/dev/null; then
    [[ "$(go_arch)" =~ ^(amd64|arm64)$ ]] || { err "warpscout — только amd64/arm64"; return 1; }
    info "Ставлю warpscout..."
    curl -4 -fsSL --max-time 60 https://raw.githubusercontent.com/vernette/warpscout/master/install.sh \
      | INSTALL_DIR="${WARPSCOUT_BIN%/*}" sh -s -- -y >/dev/null 2>&1
    "$WARPSCOUT_BIN" version &>/dev/null || { err "warpscout не установился"; return 1; }
  fi
  mkdir -p "$WARPSCOUT_DIR" && chmod 700 "$WARPSCOUT_DIR"
  [[ -s "$WARPSCOUT_ACCOUNT" ]] || "$WARPSCOUT_BIN" register -a "$WARPSCOUT_ACCOUNT" >/dev/null 2>&1 \
    || { err "Регистрация warpscout не удалась"; return 1; }
}

# Лучший endpoint по замерам warpscout → сразу в профиль. $1 — страна (DE, NL...).
warp_endpoint_best() {
  local best
  [[ "$(warp_backend)" == wg ]] || { err "Только для бэкенда wg"; return 1; }
  [[ -z "${1:-}" || "$1" =~ ^[A-Za-z]{2}$ ]] || { err "Страна — две буквы (DE, NL)"; return 1; }
  _warpscout_ready || return 1
  info "Сканирую (до минуты)..."
  best=$("$WARPSCOUT_BIN" scan -p awg -a "$WARPSCOUT_ACCOUNT" -best ${1:+-country "${1^^}"} 2>/dev/null | tail -1)
  warp_endpoint_set "$best"
}

warp_endpoint_set() {  # ip:порт
  local pub
  [[ "$1" =~ ^[0-9.]+:[0-9]+$ ]] || { err "Ни один endpoint не прошёл проверку — UDP к Cloudflare, похоже, режут"; return 1; }
  sed -i "s|^Endpoint = .*|Endpoint = $1|" "$WARP_CONF" "$WARP_PROFILE" 2>/dev/null
  if warp_is_up; then
    pub=$(wg show "$WARP_IF" peers | head -1)
    [[ -n "$pub" ]] && wg set "$WARP_IF" peer "$pub" endpoint "$1"
  fi
  ok "Endpoint: $1"
}

warp_find_endpoint() {
  local c country rep lines=() i
  [[ "$(warp_backend)" == wg ]] || { warn "Только для бэкенда wg"; return 0; }
  echo -e "  ${C}1)${N} Найти лучший и применить"
  echo -e "  ${C}2)${N} Показать список и выбрать"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    read_line country "${C}  Страна выхода (DE,NL..., Enter — любая): ${N}"
    warp_endpoint_best "$country"
    return
  fi
  _warpscout_ready || return 1
  info "Сканирую (до минуты)..."
  mktmp rep || return 1
  "$WARPSCOUT_BIN" scan -p awg -a "$WARPSCOUT_ACCOUNT" -plain -o "$rep" 2>/dev/null
  mapfile -t lines < <(grep -oE '[0-9.]+:[0-9]+' "$rep" | sort -u)
  (( ${#lines[@]} )) || { err "Рабочих endpoint не найдено"; return 1; }
  for i in "${!lines[@]}"; do printf "  %2d) %s\n" "$((i + 1))" "${lines[$i]}"; done
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 "${#lines[@]}" 0
  (( c == 0 )) && return 0
  warp_endpoint_set "${lines[$((c - 1))]}"
}

# ── Бэкенд, статус, удаление ──────────────────────────────
warp_switch_backend() {
  local target=wg
  [[ "$(warp_backend)" == wg ]] && target=usque
  ask_yes "  Переключить бэкенд $(warp_backend) → $target? Туннель прервётся на несколько секунд [y/N]: " n || return 0
  warp_set_backend "$target"
}

warp_set_backend() {  # wg|usque — с установкой, если нужно
  local cur target="$1" was_up=0
  cur=$(warp_backend)
  [[ "$target" == wg || "$target" == usque ]] || { err "Бэкенд: wg | usque"; return 1; }
  [[ "$target" == "$cur" ]] && { ok "Бэкенд уже $cur"; return 0; }
  if [[ "$target" == wg ]] && ! warp_wg_possible; then err "Нет модуля ядра wireguard"; return 1; fi
  if [[ "$target" == usque ]] && ! warp_usque_possible; then err "usque здесь не работает (нет /dev/net/tun или архитектура)"; return 1; fi
  warp_is_up && { was_up=1; warp_down quiet; }
  echo "$target" | write_file "$WARP_BACKEND_FILE" 644
  if ! "warp_${target}_install"; then
    err "Установка $target не удалась — возвращаю $cur"
    echo "$cur" | write_file "$WARP_BACKEND_FILE" 644
    (( was_up )) && warp_up
    return 1
  fi
  (( was_up )) && warp_up
  ok "Бэкенд WARP: $(warp_backend)"
}

warp_status() {
  local be trace st colo wip n total
  be=$(warp_backend)
  echo -e "  Бэкенд    : ${W}$be${N}"
  if warp_is_up; then
    trace=$(curl -4 -s --max-time 4 --interface "$WARP_IF" https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    st=$(sed -n 's/^warp=//p' <<< "$trace"); colo=$(sed -n 's/^colo=//p' <<< "$trace"); wip=$(sed -n 's/^ip=//p' <<< "$trace")
    case "$st" in
      plus) echo -e "  Туннель   : ${G}● Warp+${N} ${D}$colo${N}" ;;
      on)   echo -e "  Туннель   : ${G}● WARP${N} ${D}$colo${N}" ;;
      "")   echo -e "  Туннель   : ${R}▲ Cloudflare не отвечает${N}" ;;
      *)    echo -e "  Туннель   : ${Y}▲ интерфейс есть, трафик мимо WARP ($st)${N}" ;;
    esac
    [[ -n "$wip" ]] && echo -e "  Внешний IP: ${C}$wip${N}"
    n=$(grep -c . "$WARP_PEERS" 2>/dev/null || true); total=$(clients_name_ip | wc -l)
    echo -e "  Клиентов  : ${W}${n:-0}${N} из $total через WARP"
  elif [[ -f "$WARP_STATE.failed" ]]; then
    echo -e "  Туннель   : ${R}выключен health-check'ом (WARP не отвечал)${N}"
  else
    echo -e "  Туннель   : ${D}○ выключен${N}"
  fi
  if unit_active awg-warp-healthcheck.timer; then echo -e "  Health    : ${G}● вкл${N}"
  else echo -e "  Health    : ${D}○ выкл${N}"; fi
}

warp_remove() {
  read_confirm "${R}  Удалить WARP (аккаунт, профиль, службы)? (введи yes): ${N}" || return 0
  warp_uninstall
}

warp_uninstall() {
  warp_down quiet
  warp_health_off
  remove_unit awg-warp.service awg-usque.service
  rm -rf "$WARP_DIR" "$WARP_CONF" /usr/local/bin/wgcf "$WARP_AUTOSTART_SCRIPT" \
         "$USQUE_BIN" "$USQUE_UP_HOOK" "$USQUE_DOWN_HOOK" "$USQUE_SYSCTL" "$WARP_BACKEND_FILE"
  # Регистрация usque упирается в лимит Cloudflare — её конфиг не удаляем молча
  [[ -s "$USQUE_CONF" ]] && info "Регистрация usque оставлена: $USQUE_CONF"
  ok "WARP удалён"
}

do_warp_menu() {
  local c be
  while true; do
    be=$(warp_backend)
    echo ""
    hdr "WARP (Cloudflare)"
    warp_status
    echo ""
    echo -e "  ${C}1)${N} Установить и зарегистрировать ($be)"
    echo -e "  ${C}2)${N} Включить туннель"
    echo -e "  ${C}3)${N} Выключить туннель"
    echo -e "  ${C}4)${N} Клиенты в WARP"
    echo -e "  ${C}5)${N} Health-check вкл/выкл"
    if [[ "$be" == wg ]]; then
      echo -e "  ${C}6)${N} Warp+ (ключ)"
      echo -e "  ${C}7)${N} Импорт wgcf-profile.conf"
      echo -e "  ${C}8)${N} Поиск рабочего endpoint (warpscout)"
    fi
    echo -e "  ${C}b)${N} Сменить бэкенд (wg ↔ usque)"
    echo -e "  ${R}d)${N} Удалить WARP"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 8 0 "b|d"
    case "$c" in
      1) if [[ "$be" == wg ]]; then warp_wg_install || true; else warp_usque_install || true; fi ;;
      2) warp_up || true ;;
      3) warp_down ;;
      4) tunnel_peers_menu "Клиенты в WARP" "$WARP_PEERS" "$WARP_IF" "$WARP_TABLE"; continue ;;
      5) if unit_active awg-warp-healthcheck.timer; then warp_health_off; ok "Health-check выключен"; else warp_health_on; fi ;;
      6) [[ "$be" == wg ]] && { warp_license || true; } ;;
      7) [[ "$be" == wg ]] && { warp_import || true; } ;;
      8) [[ "$be" == wg ]] && { warp_find_endpoint || true; } ;;
      b) warp_switch_backend || true ;;
      d) warp_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ dns ═════
# Шифрованный DNS: dnscrypt-proxy на 127.0.2.1:53 (systemd-сокет пакета
# Debian/Ubuntu), DNS-запросы клиентов перехватываются DNAT'ом с awg0 и уходят
# наружу по DoH. DNS в конфигах клиентов не меняется — перехват прозрачный.
#
# DoT (853) режется в mangle PREROUTING, а не в FORWARD: PostUp сервера
# вставляет «FORWARD -i awg0 -j ACCEPT» первым правилом при каждом подъёме
# awg0, и DROP ниже него никогда не срабатывал бы.

DNS_TAG="awg2-dns"
DNS_UNIT="dnscrypt-proxy.service"
DNS_SOCKET="dnscrypt-proxy.socket"
DNS_PRESETS=(
  "cloudflare google cisco-doh|Cloudflare + Google + Cisco (рекомендуется)"
  "cloudflare|Только Cloudflare"
  "yandex-safe|Яндекс Safe (фильтрующий)"
  "cisco-doh|Только Cisco OpenDNS"
  "google|Только Google"
)

dns_installed() { command -v dnscrypt-proxy &>/dev/null && [[ -f "$DNS_PROXY_STATE" ]]; }
dns_running()   { unit_active "$DNS_UNIT" || unit_active "$DNS_SOCKET"; }

dns_resolves() {
  command -v dig &>/dev/null || return 0
  timeout 4 dig "@$DNS_PROXY_ADDR" -p "$DNS_PROXY_PORT" cloudflare.com +short +tries=1 +time=2 2>/dev/null \
    | grep -qE '^[0-9]+\.'
}

dns_state_line() {
  if ! dns_installed; then echo -e "${D}○ не настроен${N}"
  elif dns_running; then echo -e "${G}● включён${N}"
  else echo -e "${R}▲ настроен, служба не работает${N}"; fi
}

# ── Правила ───────────────────────────────────────────────
# Работают и в служебных скриптах (emit_script).
dns_rules_up() {
  local p to="$DNS_PROXY_ADDR:$DNS_PROXY_PORT"
  # DNAT в 127.0.0.0/8 ядро пропускает только с route_localnet
  sysctl -qw net.ipv4.conf.all.route_localnet=1 2>/dev/null || true
  for p in udp tcp; do
    ipt_add -t nat PREROUTING -i "$AWG_IF" -p "$p" --dport 53 -j DNAT --to-destination "$to" -m comment --comment "$DNS_TAG"
    ipt_ins INPUT -i "$AWG_IF" -d "$DNS_PROXY_ADDR" -p "$p" --dport "$DNS_PROXY_PORT" -j ACCEPT -m comment --comment "$DNS_TAG"
    ipt_add -t mangle PREROUTING -i "$AWG_IF" -p "$p" --dport 853 -j DROP -m comment --comment "$DNS_TAG"
  done
}

# Снимает и правила прежних версий — они ставились без метки.
dns_rules_down() {
  local t p to="$DNS_PROXY_ADDR:$DNS_PROXY_PORT"
  for t in nat filter mangle; do ipt_del_tagged "$t" "$DNS_TAG"; done
  for p in udp tcp; do
    ipt_del -t nat PREROUTING -i "$AWG_IF" -p "$p" --dport 53 -j DNAT --to-destination "$to"
    ipt_del -t nat PREROUTING -i "$AWG_IF" -p "$p" --dport 53 -j DNAT --to-destination 127.0.0.1:5300
    ipt_del INPUT -i "$AWG_IF" -d "$DNS_PROXY_ADDR" -p "$p" --dport "$DNS_PROXY_PORT" -j ACCEPT
    ipt_del FORWARD -i "$AWG_IF" -p "$p" --dport 853 -j DROP
  done
  if command -v ip6tables &>/dev/null; then
    for p in "udp 53" "tcp 53" "tcp 853"; do
      while ip6tables -D FORWARD -i "$AWG_IF" -p "${p% *}" --dport "${p#* }" -j DROP 2>/dev/null; do :; done
    done
  fi
}

dns_rules_ok() {
  iptables -t nat -C PREROUTING -i "$AWG_IF" -p udp --dport 53 -j DNAT \
    --to-destination "$DNS_PROXY_ADDR:$DNS_PROXY_PORT" -m comment --comment "$DNS_TAG" 2>/dev/null
}

# Точка входа awg-dns-persist.service: ждёт awg0 и ставит правила.
dns_persist_run() {
  local i
  for i in $(seq 1 30); do ip link show "$AWG_IF" &>/dev/null && break; sleep 2; done
  ip link show "$AWG_IF" &>/dev/null || { echo "awg-dns-persist: $AWG_IF не появился за 60 с" >&2; exit 1; }
  dns_rules_up
}

# Точка входа таймера awg-dns-healthcheck.
dns_health_run() {
  local ts
  ts=$(date '+%F %T')
  if ! systemctl is-active --quiet dnscrypt-proxy.service && ! systemctl is-active --quiet dnscrypt-proxy.socket; then
    echo "[$ts] FAIL: dnscrypt-proxy не работает — перезапускаю" >> "$DNS_HEALTH_LOG"
    systemctl restart dnscrypt-proxy.socket dnscrypt-proxy.service 2>/dev/null || true
  fi
  if command -v dig >/dev/null && ! timeout 4 dig "@$DNS_PROXY_ADDR" -p "$DNS_PROXY_PORT" cloudflare.com \
      +short +tries=1 +time=2 2>/dev/null | grep -qE '^[0-9]+\.'; then
    echo "[$ts] FAIL: резолв через $DNS_PROXY_ADDR не отвечает" >> "$DNS_HEALTH_LOG"
  fi
  if ip link show "$AWG_IF" &>/dev/null && ! dns_rules_ok; then
    echo "[$ts] FAIL: правила перехвата пропали — восстанавливаю" >> "$DNS_HEALTH_LOG"
    dns_rules_up
  fi
  return 0
}

_dns_emit_helpers() {
  local common=(AWG_IF DNS_TAG DNS_PROXY_ADDR DNS_PROXY_PORT ipt_add ipt_ins dns_rules_up dns_rules_ok)
  emit_script "$DNS_PERSIST_SCRIPT" 'dns_persist_run' "${common[@]}" dns_persist_run || return 1
  emit_script "$DNS_HEALTH_SCRIPT" 'dns_health_run' "${common[@]}" DNS_HEALTH_LOG dns_health_run || return 1
  write_unit awg-dns-persist.service <<EOF
[Unit]
Description=AWG Toolza — перехват DNS клиентов в dnscrypt-proxy
After=network-online.target awg-quick@awg0.service $DNS_UNIT
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DNS_PERSIST_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  write_unit awg-dns-healthcheck.service <<EOF
[Unit]
Description=AWG Toolza — проверка шифрованного DNS
After=$DNS_UNIT

[Service]
Type=oneshot
ExecStart=$DNS_HEALTH_SCRIPT
EOF
  write_unit awg-dns-healthcheck.timer <<'EOF'
[Unit]
Description=AWG Toolza — проверка шифрованного DNS раз в 2 минуты

[Timer]
OnBootSec=60
OnUnitActiveSec=120

[Install]
WantedBy=timers.target
EOF
  systemctl enable awg-dns-persist.service &>/dev/null
  systemctl enable --now awg-dns-healthcheck.timer &>/dev/null
}

_dns_write_conf() {
  write_file "$DNS_PROXY_CONF" 644 <<EOF
# AWG Toolza — шифрованный DNS для клиентов AWG.
# Слушает ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT} через systemd-сокет пакета, поэтому
# listen_addresses пуст: свой адрес конфликтовал бы с сокетом.
listen_addresses = []

server_names = ['cloudflare', 'google', 'cisco-doh']
require_dnssec = true
require_nolog = true
require_nofilter = true
dnscrypt_servers = false
doh_servers = true
ipv4_servers = true
ipv6_servers = false

cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
timeout = 5000
keepalive = 30

[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 73
    prefix = ''
EOF
  mkdir -p /var/cache/dnscrypt-proxy
  chown -R _dnscrypt-proxy:_dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null \
    || chown -R nobody:nogroup /var/cache/dnscrypt-proxy 2>/dev/null || true
}

_dns_wait_ready() {
  local i
  for i in $(seq 1 15); do
    dns_running && dns_resolves && return 0
    sleep 1
  done
  return 1
}

dns_install() {  # [force] — включить поверх стороннего DNS-сервиса
  local busy
  server_exists && iface_up || { err "Сначала создай и запусти сервер"; return 1; }
  # Сторонний DNS на 53/853 (Pi-hole, Unbound, bind) — перехват уведёт клиентов мимо него
  busy=$(ss -Htulpn 2>/dev/null | awk '$5 ~ /:(53|853)$/' | grep -vE '127\.0\.0\.5[34]|127\.0\.2\.1|127\.0\.0\.1' | head -3 || true)
  if [[ -n "$busy" && "${1:-}" != force ]]; then
    warn "На сервере уже работает DNS-сервис:"
    sed 's/^/    /' <<< "$busy"
    if ! ask_yes "  Всё равно включить перехват? [y/N]: " n; then
      (( AUTO_MODE )) && { err "Порт 53/853 занят другим DNS — перехват не включён"; return 1; }
      return 0
    fi
  fi
  need_cmds dnscrypt-proxy:dnscrypt-proxy dig:dnsutils || return 1
  if [[ -f "$DNS_PROXY_CONF" && ! -f "$DNS_PROXY_BACKUP_CONF" ]]; then
    cp -a "$DNS_PROXY_CONF" "$DNS_PROXY_BACKUP_CONF"
  fi
  systemctl stop "$DNS_UNIT" &>/dev/null || true
  _dns_write_conf
  systemctl daemon-reload
  systemctl enable "$DNS_SOCKET" "$DNS_UNIT" &>/dev/null || true
  systemctl restart "$DNS_SOCKET" "$DNS_UNIT" &>/dev/null || true
  info "Жду, пока загрузятся резолверы..."
  if ! _dns_wait_ready; then
    err "dnscrypt-proxy не отвечает на $DNS_PROXY_ADDR:$DNS_PROXY_PORT"
    info "С некоторых хостингов DoH Cloudflare недоступен — попробуй другие резолверы"
    journalctl -u "$DNS_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  dns_rules_down
  dns_rules_up
  if ufw_active; then
    ufw allow in on "$AWG_IF" to "$DNS_PROXY_ADDR" port "$DNS_PROXY_PORT" proto udp comment "$DNS_TAG" &>/dev/null || true
    ufw allow in on "$AWG_IF" to "$DNS_PROXY_ADDR" port "$DNS_PROXY_PORT" proto tcp comment "$DNS_TAG" &>/dev/null || true
  fi
  echo "net.ipv4.conf.all.route_localnet=1" | write_file "$DNS_SYSCTL" 644
  _dns_emit_helpers || return 1
  printf 'enabled=true\naddr=%s\nport=%s\ninstalled_at=%s\n' "$DNS_PROXY_ADDR" "$DNS_PROXY_PORT" "$(date +%s)" \
    | write_file "$DNS_PROXY_STATE" 644
  ok "Шифрованный DNS включён: запросы клиентов идут по DoH, DoT (853) закрыт"
  info "Проверка с клиента: https://1.1.1.1/help → «Using DNS over HTTPS: Yes»"
  log_info "dnscrypt-proxy включён"
}

dns_restart() {
  dns_installed || { err "Шифрованный DNS не настроен"; return 1; }
  systemctl restart "$DNS_SOCKET" "$DNS_UNIT" &>/dev/null || true
  iface_up && dns_rules_up
  if _dns_wait_ready; then ok "dnscrypt-proxy перезапущен и отвечает"
  else err "dnscrypt-proxy не отвечает: journalctl -u $DNS_UNIT -n 20"; return 1; fi
}

dns_status() {
  local names
  if ! command -v dnscrypt-proxy &>/dev/null; then echo -e "  Статус    : ${D}○ не установлен${N}"; return 0; fi
  if ! dns_running; then echo -e "  Статус    : ${D}○ служба остановлена${N}"
  elif dns_resolves; then echo -e "  Статус    : ${G}● работает${N} ${D}($DNS_PROXY_ADDR:$DNS_PROXY_PORT)${N}"
  else echo -e "  Статус    : ${Y}▲ служба запущена, но не резолвит${N}"; fi
  if dns_rules_ok; then echo -e "  Перехват  : ${G}● DNS клиентов идёт через DoH, DoT закрыт${N}"
  elif dns_installed; then echo -e "  Перехват  : ${R}▲ правил нет — Перезапустить (2)${N}"
  else echo -e "  Перехват  : ${D}○ выключен${N}"; fi
  unit_active awg-dns-healthcheck.timer && echo -e "  Health    : ${G}● раз в 2 минуты${N}"
  names=$(sed -n 's/^server_names[[:space:]]*=[[:space:]]*//p' "$DNS_PROXY_CONF" 2>/dev/null | tr -d "[]'\"" | head -1)
  [[ -n "$names" ]] && echo -e "  Резолверы : ${C}$names${N}"
  return 0
}

dns_change_upstream() {
  local c i names="" manual
  [[ -f "$DNS_PROXY_CONF" ]] || { err "Сначала включи шифрованный DNS"; return 1; }
  for i in "${!DNS_PRESETS[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${DNS_PRESETS[$i]#*|}"; done
  echo -e "  ${C}$(( ${#DNS_PRESETS[@]} + 1 )))${N} Вручную ${D}(имена из public-resolvers.md)${N}"
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 $(( ${#DNS_PRESETS[@]} + 1 )) 0
  (( c == 0 )) && return 0
  if (( c <= ${#DNS_PRESETS[@]} )); then
    names="${DNS_PRESETS[$((c - 1))]%%|*}"
  else
    echo -e "  ${D}Список: https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/public-resolvers.md${N}"
    read_line manual "${C}  Резолверы через запятую: ${N}"
    [[ -n "$manual" ]] || return 0
    names="$manual"
  fi
  dns_set_upstream "$names"
}

# Резолверы dnscrypt-proxy по именам из public-resolvers.md (через пробел или запятую).
dns_set_upstream() {
  _dns_upstream_write "$1" || return 1
  ok "Резолверы: ${1//,/ }"
  dns_restart || info "Проверь имена резолверов: journalctl -u $DNS_UNIT -n 20"
}

_dns_upstream_write() {  # имена — в конфиг, без перезапуска
  local names="${1//,/ }" nofilter=true toml="" n
  [[ -f "$DNS_PROXY_CONF" ]] || { err "Шифрованный DNS не настроен"; return 1; }
  [[ "$names" =~ ^[A-Za-z0-9_\ -]+$ && -n "${names// /}" ]] || { err "Допустимы латиница, цифры, дефис и запятая"; return 1; }
  # Фильтрующий резолвер при require_nofilter=true dnscrypt-proxy молча
  # отбрасывает — и остаётся без серверов вообще.
  [[ " $names " == *safe* || " $names " == *filter* || " $names " == *family* || " $names " == *adguard* ]] && nofilter=false
  for n in $names; do toml+="${toml:+, }'$n'"; done
  sed -i "s|^server_names[[:space:]]*=.*|server_names = [$toml]|; s|^require_nofilter[[:space:]]*=.*|require_nofilter = $nofilter|" "$DNS_PROXY_CONF"
}

dns_remove() {
  local purge=n
  read_confirm "${R}  Выключить шифрованный DNS? Клиенты пойдут на DNS из своих конфигов (введи yes): ${N}" || return 0
  read_yesno purge "  Удалить и пакет dnscrypt-proxy? [y/N]: " n
  dns_uninstall "$([[ "$purge" == y ]] && echo purge)"
}

dns_uninstall() {  # [purge] — удалить и пакет
  local purge="${1:-}"
  remove_unit awg-dns-healthcheck.timer awg-dns-healthcheck.service awg-dns-persist.service
  rm -f "$DNS_HEALTH_SCRIPT" "$DNS_PERSIST_SCRIPT" "$DNS_SYSCTL"
  dns_rules_down
  if command -v ufw &>/dev/null; then
    ufw_delete_matching "$DNS_TAG"
    ufw delete allow in on "$AWG_IF" to "$DNS_PROXY_ADDR" port "$DNS_PROXY_PORT" proto udp &>/dev/null || true
    ufw delete allow in on "$AWG_IF" to "$DNS_PROXY_ADDR" port "$DNS_PROXY_PORT" proto tcp &>/dev/null || true
  fi
  sysctl -qw net.ipv4.conf.all.route_localnet=0 2>/dev/null || true
  systemctl disable --now "$DNS_UNIT" "$DNS_SOCKET" &>/dev/null || true
  if [[ "$purge" == purge ]]; then
    apt-get purge -y -q dnscrypt-proxy &>/dev/null || true
    rm -rf /var/cache/dnscrypt-proxy
  elif [[ -f "$DNS_PROXY_BACKUP_CONF" ]]; then
    cp -a "$DNS_PROXY_BACKUP_CONF" "$DNS_PROXY_CONF"
  fi
  rm -f "$DNS_PROXY_STATE"
  ok "Шифрованный DNS выключен"
  log_info "dnscrypt-proxy выключен"
}

do_dns_menu() {
  local c
  while true; do
    echo ""
    hdr "Шифрованный DNS (dnscrypt-proxy)"
    dns_status
    echo ""
    echo -e "  ${C}1)${N} Включить"
    echo -e "  ${C}2)${N} Перезапустить"
    echo -e "  ${C}3)${N} Журнал"
    echo -e "  ${C}4)${N} Резолверы"
    echo -e "  ${R}5)${N} Выключить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-5]: ${N}" 0 5 0
    case "$c" in
      1) dns_install || true ;;
      2) dns_restart || true ;;
      3) journalctl -u "$DNS_UNIT" -n 50 --no-pager 2>/dev/null || warn "Журнал недоступен" ;;
      4) dns_change_upstream || true ;;
      5) dns_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ cascade ═════
# Каскад портов: этот сервер принимает клиентов на порт и прозрачно
# пробрасывает трафик на другой сервер (AmneziaWG, VLESS, любой L4).
# Клиент видит IP этого сервера.
#
# Правила: /etc/awg-cascade/rules.conf, строка «proto|вход|цель|выход|комментарий».
# Все правила iptables помечены «awg-cascade:<proto>-<вход>» — сброс трогает
# только их. DNAT ловит только пакеты на адреса самого сервера: без этого
# правило «udp 443» перехватывало бы QUIC всех клиентов AWG к любым сайтам.

cascade_tag() { echo "${CASCADE_TAG}:$1-$2"; }

cascade_rules() {  # строки правил без комментариев и мусора
  [[ -f "$CASCADE_RULES" ]] || return 0
  grep -E '^(udp|tcp)\|[0-9]+\|[0-9.]+\|[0-9]+\|' "$CASCADE_RULES" || true
}

cascade_count() { cascade_rules | grep -c . || true; }

cascade_state_line() {
  local n
  n=$(cascade_count)
  if (( n )); then echo -e "${G}● правил: $n${N}"; else echo -e "${D}○ правил нет${N}"; fi
}

# ── Правила iptables (и для служебного скрипта) ───────────
cascade_log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$CASCADE_LOG" 2>/dev/null || true; }

cascade_unapply() {  # proto вход
  local t tag
  tag=$(cascade_tag "$1" "$2")
  for t in nat filter; do ipt_del_grep "$t" "--comment \"?${tag}\"?( |$)"; done
}

cascade_apply() {  # proto вход цель выход
  local p="$1" in="$2" dst="$3" out="$4" tag
  tag=$(cascade_tag "$p" "$in")
  cascade_unapply "$p" "$in"
  iptables -t nat -A PREROUTING -p "$p" --dport "$in" -m addrtype --dst-type LOCAL \
    -j DNAT --to-destination "$dst:$out" -m comment --comment "$tag" || return 1
  iptables -t nat -A POSTROUTING -p "$p" -d "$dst" --dport "$out" -j MASQUERADE -m comment --comment "$tag" || return 1
  # Туда и обратно: политика FORWARD бывает DROP (Docker, UFW) — правила
  # не должны зависеть от неё.
  iptables -I FORWARD 1 -p "$p" -d "$dst" --dport "$out" -j ACCEPT -m comment --comment "$tag" || return 1
  iptables -I FORWARD 1 -p "$p" -s "$dst" --sport "$out" -j ACCEPT -m comment --comment "$tag" || return 1
}

# Точка входа awg-cascade.service.
cascade_apply_all() {
  local p in dst out rest ok=0 bad=0
  [[ -f "$CASCADE_RULES" ]] || exit 0
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
  while IFS='|' read -r p in dst out rest; do
    [[ "$p" == udp || "$p" == tcp ]] && [[ -n "$in" && -n "$dst" && -n "$out" ]] || continue
    if cascade_apply "$p" "$in" "$dst" "$out"; then ok=$((ok + 1))
    else bad=$((bad + 1)); cascade_log "ERROR: $p $in -> $dst:$out не применилось"; fi
  done < "$CASCADE_RULES"
  cascade_log "применено: $ok, ошибок: $bad"
}

cascade_flush_rules() {
  local t
  for t in nat filter; do ipt_del_grep "$t" "--comment \"?${CASCADE_TAG}:"; done
}

_cascade_persist() {
  emit_script "$CASCADE_SCRIPT" 'cascade_apply_all' CASCADE_TAG CASCADE_RULES CASCADE_LOG \
    ipt_del_grep cascade_tag cascade_log cascade_unapply cascade_apply cascade_apply_all || return 1
  write_unit awg-cascade.service <<EOF
[Unit]
Description=AWG Toolza — каскад портов
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$CASCADE_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable awg-cascade.service &>/dev/null
}

# UFW-правила прежних версий: порт, route allow и политика FORWARD.
_cascade_ufw_legacy_cleanup() {
  command -v ufw &>/dev/null || return 0
  ufw_delete_matching "${CASCADE_TAG}:"
}

# ── Меню ──────────────────────────────────────────────────
_cascade_port_conflict() {  # proto порт → причина в stdout
  local p="$1" port="$2"
  grep -qE "^${p}\|${port}\|" "$CASCADE_RULES" 2>/dev/null && { echo "уже есть правило ${p^^} $port"; return 0; }
  if [[ "$p" == udp ]]; then
    [[ "$(conf_iface_get ListenPort 2>/dev/null)" == "$port" ]] && { echo "это порт AmneziaWG"; return 0; }
    wgobf_owns_port "$port" && { echo "порт занят WG + обфускатором"; return 0; }
  fi
  ss -Hln"${p:0:1}" "sport = :$port" 2>/dev/null | grep -q . && { echo "порт слушает локальный сервис — DNAT отнимет его"; return 0; }
  return 1
}

cascade_add() {
  local mode="$1" p protos in out dst comment
  echo -e "  ${D}Клиент подключается к этому серверу, трафик уходит на конечный.${N}"
  echo -e "  ${C}1)${N} UDP"
  echo -e "  ${C}2)${N} TCP"
  echo -e "  ${C}3)${N} UDP + TCP"
  read_choice p "${C}  Протокол [1-3] (Enter = 1): ${N}" 1 3 1
  case "$p" in 1) protos=udp ;; 2) protos=tcp ;; 3) protos=both ;; esac
  while true; do
    read_line dst "${C}  IP конечного сервера: ${N}"
    dst="${dst// /}"; [[ -z "$dst" ]] && return 0
    valid_ip "$dst" && ! ip_is_private "$dst" && break
    err "Нужен публичный IPv4, например 5.6.7.8"
  done
  while true; do
    read_line in "${C}  Порт на этом сервере: ${N}"
    valid_port "${in// /}" && { in="${in// /}"; break; }
    err "Порт 1-65535"
  done
  out="$in"
  if [[ "$mode" == custom ]]; then
    while true; do
      read_line out "${C}  Порт конечного сервера: ${N}"
      valid_port "${out// /}" && { out="${out// /}"; break; }
      err "Порт 1-65535"
    done
  fi
  read_line comment "${C}  Комментарий (Enter — без него): ${N}"
  cascade_rule_add "$protos" "$in" "$dst" "$out" "$comment"
}

# cascade_rule_add udp|tcp|both ВХОД ЦЕЛЬ ВЫХОД [комментарий]
# Порты и адрес цели правила; причина отказа — в stdout. Общая для
# добавления и для правил из бэкапа: те раньше проверялись только по формату
# и могли увести порт сервера во внутреннюю сеть.
_cascade_rule_invalid() {  # вход цель выход
  valid_port "$1" && valid_port "$3" || { echo "Порт 1-65535"; return 0; }
  valid_ip "$2" && ! ip_is_private "$2" || { echo "Нужен публичный IPv4, например 5.6.7.8"; return 0; }
  return 1
}

cascade_rule_add() {
  local protos=() proto in="$2" dst="$3" out="$4" comment="${5//[|$'\n\r']/ }" why added=0
  case "$1" in udp|tcp) protos=("$1") ;; both) protos=(udp tcp) ;; *) err "Протокол: udp | tcp | both"; return 1 ;; esac
  if why=$(_cascade_rule_invalid "$in" "$dst" "$out"); then err "$why"; return 1; fi
  ip_forward_enable
  mkdir -p "$CASCADE_DIR"
  for proto in "${protos[@]}"; do
    if why=$(_cascade_port_conflict "$proto" "$in"); then err "${proto^^} $in: $why"; continue; fi
    if cascade_apply "$proto" "$in" "$dst" "$out"; then
      echo "$proto|$in|$dst|$out|$comment" >> "$CASCADE_RULES"
      cascade_log "добавлено: $proto $in -> $dst:$out"
      ok "${proto^^} $in → $dst:$out"
      added=$((added + 1))
    else
      cascade_unapply "$proto" "$in"
      err "iptables не принял правило ${proto^^} $in"
    fi
  done
  (( added )) || return 1
  _cascade_persist
  info "На клиенте Endpoint: ${W}$(public_ip_cached):$in${N}"
}

cascade_list() {
  local rows=() i p in dst out cm mark
  mapfile -t rows < <(cascade_rules)
  (( ${#rows[@]} )) || { info "Правил нет"; return 1; }
  printf "  ${D}%-3s %-4s %-6s %-16s %-6s %s${N}\n" "#" "" "ВХОД" "ЦЕЛЬ" "ВЫХОД" "КОММЕНТАРИЙ"
  for i in "${!rows[@]}"; do
    IFS='|' read -r p in dst out cm <<< "${rows[$i]}"
    if iptables-save -t nat 2>/dev/null | grep -qE -- "$(cascade_tag "$p" "$in")\"?( |$)"; then mark="${G}●${N}"; else mark="${R}○${N}"; fi
    printf "  %-3s %b %-4s %-6s %-16s %-6s %s\n" "$((i + 1)))" "$mark" "${p^^}" "$in" "$dst" "$out" "${cm:-—}"
  done
  echo -e "  ${D}● применено, ○ записано, но в iptables нет (Переприменить правила)${N}"
}

cascade_delete() {
  local rows=() c p in
  cascade_list || return 0
  mapfile -t rows < <(cascade_rules)
  read_choice c "${C}  Номер для удаления (0 — отмена): ${N}" 0 "${#rows[@]}" 0
  (( c == 0 )) && return 0
  IFS='|' read -r p in _ <<< "${rows[$((c - 1))]}"
  cascade_rule_del "$p" "$in"
}

cascade_rule_del() {  # proto вход
  local p="$1" in="$2" dst out
  # Аргументы приходят и из API: без проверки «.» и «[0-9]+» стали бы регуляркой
  # и вычистили бы все правила из файла, оставив их в iptables.
  [[ "$p" =~ ^(udp|tcp)$ ]] && valid_port "$in" || { err "Правило: udp|tcp ПОРТ"; return 1; }
  IFS='|' read -r _ _ dst out _ < <(grep -E "^${p}\|${in}\|" "$CASCADE_RULES" 2>/dev/null)
  [[ -n "$dst" ]] || { err "Правила ${p^^} $in нет"; return 1; }
  cascade_unapply "$p" "$in"
  grep -vE "^${p}\|${in}\|" "$CASCADE_RULES" > "$CASCADE_RULES.tmp" || true
  mv -f "$CASCADE_RULES.tmp" "$CASCADE_RULES"
  cascade_log "удалено: $p $in -> $dst:$out"
  ok "Удалено: ${p^^} $in → $dst:$out"
}

cascade_reapply() {
  cascade_flush_rules
  (( $(cascade_count) )) || { info "Правил нет"; return 0; }
  _cascade_persist
  systemctl restart awg-cascade.service && ok "Правила переприменены" \
    || err "Не применилось: journalctl -u awg-cascade; лог $CASCADE_LOG"
}

cascade_flush() {
  (( $(cascade_count) )) || { info "Каскад пуст"; return 0; }
  read_confirm "${R}  Удалить все правила каскада? (введи yes): ${N}" || return 0
  cascade_clear
}

cascade_clear() {
  cascade_flush_rules
  _cascade_ufw_legacy_cleanup
  : > "$CASCADE_RULES"
  cascade_log "все правила удалены"
  ok "Все правила каскада удалены"
}

# $1 = quiet — без вопроса (из полного удаления).
cascade_uninstall() {
  if [[ "${1:-}" != quiet ]]; then
    read_confirm "${R}  Удалить каскад полностью (правила, служба)? (введи yes): ${N}" || return 0
  fi
  remove_unit awg-cascade.service
  rm -f "$CASCADE_SCRIPT"
  cascade_flush_rules
  _cascade_ufw_legacy_cleanup
  # Прежние версии меняли политику FORWARD в UFW. Если AWG-сервера нет,
  # вернуть её было бы некому — возвращаем здесь.
  if [[ -f "$CASCADE_UFW_BACKUP" ]] && ! server_exists; then
    cp -a "$CASCADE_UFW_BACKUP" /etc/default/ufw
    ufw_active && ufw reload &>/dev/null
  fi
  rm -rf "$CASCADE_DIR"
  [[ "${1:-}" == quiet ]] || ok "Каскад удалён"
}

cascade_diagnose() {
  local p in dst out seen=" "
  hdr "Диагностика каскада"
  echo "  Аплинк      : $(uplink_iface || echo '?')"
  echo "  IP сервера  : $(public_ip_cached)"
  echo "  ip_forward  : $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  echo "  Служба      : $(systemctl is-enabled awg-cascade.service 2>/dev/null || echo нет)"
  echo "  Правил      : $(cascade_count)"
  echo ""
  echo "── iptables ──"
  { iptables-save -t nat; iptables-save -t filter; } 2>/dev/null | grep -F "${CASCADE_TAG}:" | sed 's/^/  /' || echo "  (нет)"
  echo ""
  echo "── Доступность целей (TCP-порт или ping) ──"
  while IFS='|' read -r p in dst out _; do
    [[ "$seen" == *" $dst:$out "* ]] && continue
    seen+="$dst:$out "
    if [[ "$p" == tcp ]] && timeout 4 bash -c "exec 3<>/dev/tcp/$dst/$out" 2>/dev/null; then
      echo -e "  ${G}●${N} $dst:$out — TCP отвечает"
    elif ping -c1 -W2 "$dst" &>/dev/null; then
      echo -e "  ${G}●${N} $dst — ping есть ${D}(UDP-порт так не проверить)${N}"
    else
      echo -e "  ${Y}▲${N} $dst — не отвечает ${D}(ICMP может быть закрыт)${N}"
    fi
  done < <(cascade_rules)
  echo ""
  echo "── Журнал ($CASCADE_LOG) ──"
  tail -n 15 "$CASCADE_LOG" 2>/dev/null | sed 's/^/  /' || echo "  (пусто)"
}

cascade_export() {
  local f
  f="/root/cascade-debug-$(date +%Y%m%d-%H%M%S).txt"
  { cascade_diagnose; echo; echo "── ip route ──"; ip route; echo; iptables --version; } 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | write_file "$f" 600
  ok "Отчёт: $f"
}

do_cascade_menu() {
  local c
  while true; do
    echo ""
    hdr "Каскад портов"
    echo -e "  Правил: ${W}$(cascade_count)${N}   Служба: $(unit_enabled awg-cascade.service && echo -e "${G}● автозапуск${N}" || echo -e "${D}○ нет${N}")"
    echo ""
    echo -e "  ${C}1)${N} Добавить (один порт)"
    echo -e "  ${C}2)${N} Добавить (разные порты)"
    echo -e "  ${C}3)${N} Список"
    echo -e "  ${C}4)${N} Удалить правило"
    echo -e "  ${C}5)${N} Переприменить правила"
    echo -e "  ${C}6)${N} Диагностика"
    echo -e "  ${C}7)${N} Отчёт в файл"
    echo -e "  ${Y}8)${N} Удалить все правила"
    echo -e "  ${R}d)${N} Удалить каскад полностью"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 8 0 "d"
    case "$c" in
      1) cascade_add same || true ;;
      2) cascade_add custom || true ;;
      3) cascade_list || true ;;
      4) cascade_delete || true ;;
      5) cascade_reapply || true ;;
      6) cascade_diagnose ;;
      7) cascade_export ;;
      8) cascade_flush || true ;;
      d) cascade_uninstall || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ xray ═════
# Xray: клиенты AWG выходят через VLESS/VMess/Hysteria2-сервер.
#
# Интерфейс xray0 поднимает сам Xray (inbound tun), а если сборка его не
# умеет — tun2socks поверх SOCKS-входа Xray на 127.0.0.1:10808. Дальше
# маршрутизация одна: клиенты из peers.list → таблица 201 → xray0.
#
# Клиенту можно назначить свой выход: строка «IP|выход» в peers.list, в
# конфиге Xray — правило по адресу клиента (source) перед общим. Адрес
# клиента виден только inbound tun самого Xray — поэтому перед xray0 в этом
# режиме нет NAT; через tun2socks все соединения приходят с 127.0.0.1.
#
# Три постоянных юнита, чтобы туннель переживал перезагрузку:
#   awg-xray.service          — сам Xray;
#   awg-xray-tun.service      — tun2socks (только если нет inbound tun);
#   awg-xray-routing.service  — маршруты клиентов; перед ними проверяет, что
#                               трафик через Xray действительно идёт.

xray_installed() { [[ -x "$XRAY_BIN" && -f "$XRAY_CONF" ]]; }
xray_state_get() { sed -n "s/^$1=//p" "$XRAY_STATE" 2>/dev/null | head -1; }
xray_tags()      { [[ -f "$XRAY_CONF" ]] && py xray-tags "$XRAY_CONF" 2>/dev/null; }
xray_ru_on()     { [[ -f "$XRAY_CONF" ]] && grep -q '"ruleTag": "ru-direct"' "$XRAY_CONF"; }

_xray_asset() {
  case "$(uname -m)" in
    x86_64|amd64) echo Xray-linux-64 ;; aarch64|arm64) echo Xray-linux-arm64-v8a ;;
    armv7l|armv7) echo Xray-linux-arm32-v7a ;; *) echo "" ;;
  esac
}

# Текст ошибки Xray по конфигу. 0 — принят.
# Проверяется копия: формат Xray берёт из расширения (без «.json» отказ
# «Failed to get format»), а inbound tun при проверке создаёт устройство —
# у копии оно своё, иначе при работающем Xray «device or resource busy».
xray_test() {
  local out copy rc=0
  # Не mktmp: xray_test зовут и внутри $(...), где ловушка EXIT не убирает файлы
  copy=$(mktemp --suffix=.json /tmp/awg2.XXXXXX) || return 1
  if py xray-test-copy "${1:-$XRAY_CONF}" "$copy" 2>/dev/null; then
    out=$("$XRAY_BIN" run -test -c "$copy" 2>&1) || rc=1
  else
    out="конфиг Xray — не JSON"; rc=1
  fi
  rm -f "$copy"
  (( rc )) || return 0
  printf '%s\n' "$out" | grep -iE 'failed|error|invalid|unknown|not found|JSON' | head -5
  return 1
}

# Умеет ли бинарь inbound tun. Апстримный XTLS/Xray-core долго его не имел,
# поэтому спрашиваем сам бинарь, а не гадаем по версии.
# Ответ запоминается и в $STATE_DIR/xray_tun до смены бинаря: проба
# запускает сам Xray, а спрашивают её на каждом экране клиента в боте.
_XRAY_TUN=""
xray_tun_supported() {
  local probe key cache="$STATE_DIR/xray_tun"
  if [[ -z "$_XRAY_TUN" ]]; then
    key=$(stat -c '%Y:%s' "$XRAY_BIN" 2>/dev/null || true)
    if [[ -n "$key" && "$(cut -d' ' -f1 "$cache" 2>/dev/null)" == "$key" ]]; then
      _XRAY_TUN=$(cut -d' ' -f2 "$cache")
    else
      _XRAY_TUN=0
      mktmp probe .json || return 1
      py xray-tun-probe "$probe" && xray_test "$probe" >/dev/null && _XRAY_TUN=1
      [[ -n "$key" ]] && mkdir -p "$STATE_DIR" && echo "$key $_XRAY_TUN" > "$cache" 2>/dev/null
    fi
  fi
  [[ "$_XRAY_TUN" == 1 ]]
}

# Кто слушает SOCKS-порт Xray: «имя (pid N)» построчно.
xray_port_owners() {
  ss -lntpH "sport = :${XRAY_SOCKS##*:}" 2>/dev/null \
    | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 (pid \2)/p' | sort -u || true
}

# ── Установка ─────────────────────────────────────────────
xray_install() {  # [update] — без вопроса обновить уже установленный
  local asset base tmp want rc
  if xray_installed; then
    info "Установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
    [[ "${1:-}" == update ]] || ask_yes "  Обновить до последней версии? [y/N]: " n || return 0
  fi
  asset=$(_xray_asset)
  [[ -n "$asset" ]] || { err "Архитектура $(uname -m) не поддерживается Xray"; return 1; }
  need_cmds unzip:unzip || return 1
  mktmp tmp -d || return 1
  base="https://github.com/XTLS/Xray-core/releases/latest/download"
  info "Скачиваю Xray ($asset)..."
  gh_fetch "$base/$asset.zip" "$tmp/x.zip" 1000000 zip || { err "Xray не скачался ни напрямую, ни через зеркала"; return 1; }
  # .dgst рядом с архивом: строка «SHA2-256= <хеш>»
  if gh_fetch "$base/$asset.zip.dgst" "$tmp/dgst" 16 any; then
    want=$(grep -iE 'sha2?-?256' "$tmp/dgst" | grep -oE '[0-9a-fA-F]{64}' | head -1)
    rc=0; sha256_check "$tmp/x.zip" "$want" || rc=$?
    (( rc == 1 )) && { err "Контрольная сумма Xray не совпала"; return 1; }
    (( rc == 0 )) && ok "Контрольная сумма совпала"
  else
    warn "Файла с контрольной суммой нет — ставлю без проверки"
  fi
  unzip -qo "$tmp/x.zip" xray -d "$tmp" || { err "Архив не распаковался"; return 1; }
  unzip -qo "$tmp/x.zip" geoip.dat geosite.dat -d "$XRAY_ASSET_DIR" 2>/dev/null || true
  "$tmp/xray" version &>/dev/null || { err "Скачанный xray не запускается"; return 1; }
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  ok "Xray: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  _XRAY_TUN=""
  mkdir -p "$XRAY_DIR" && chmod 700 "$XRAY_DIR"
  [[ -f "$XRAY_CONF" ]] || py xray-default "$XRAY_CONF"
  if xray_is_up; then
    info "Перезапускаю туннель на новой версии"
    xray_restart
  fi
}

# ── Выходы (outbounds) ────────────────────────────────────
xray_add_outbound() {
  local link
  xray_installed || { err "Сначала установи Xray"; return 1; }
  read_line link "${C}  Ссылка (vless:// vmess:// trojan:// ss:// hysteria2://): ${N}"
  link="${link//[[:space:]]/}"
  [[ -n "$link" ]] || return 0
  xray_add_link "$link"
}

xray_add_link() {  # ссылка
  local link="$1" ob msgs tag probe why rc=0
  xray_installed || { err "Сначала установи Xray"; return 1; }
  mktmp msgs || return 1
  ob=$(py xray-link "$link" 2>"$msgs") || { err "Ссылка не разобрана: $(tail -1 "$msgs")"; return 1; }
  grep -q '^NOTE:' "$msgs" && sed -n 's/^NOTE:/  /p' "$msgs"
  grep -q '^UNSUPPORTED:' "$msgs" && { err "Транспорт $(sed -n 's/^UNSUPPORTED://p' "$msgs") не поддерживается"; return 1; }
  tag=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["tag"])' "$ob")
  # Проверяем outbound на самом бинаре до записи: неподдерживаемый протокол
  # (hysteria2 в апстримном Xray) иначе ломает весь конфиг.
  mktmp probe .json || return 1
  py xray-probe "$probe" <<< "$ob"
  if ! why=$(xray_test "$probe"); then
    err "Этот Xray не принимает такой выход:"
    sed 's/^/      /' <<< "$why"
    [[ "$link" =~ ^(hysteria2|hy2):// ]] && info "Hysteria2 есть в Xray 26 и новее — обнови Xray: Установить / обновить"
    return 1
  fi
  py xray-add "$XRAY_CONF" <<< "$ob" 2>/dev/null || rc=$?
  (( rc == 3 )) && { err "Выход $tag уже есть"; return 1; }
  (( rc == 0 )) || { err "Не удалось записать конфиг"; return 1; }
  ok "Выход $tag добавлен и выбран активным"
  if xray_is_up; then info "Туннель работает на прежнем выходе — перезапусти его"; fi
}

_xray_pick_tag() {  # → CHOSEN
  local tags=() i c
  mapfile -t tags < <(xray_tags)
  (( ${#tags[@]} )) || { warn "Выходов нет — добавь выход ссылкой"; return 1; }
  for i in "${!tags[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${tags[$i]}"; done
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 "${#tags[@]}" 0
  (( c )) || return 1
  CHOSEN="${tags[$((c - 1))]}"
}

xray_del_outbound() {
  xray_installed || { err "Xray не установлен"; return 1; }
  _xray_pick_tag || return 0
  xray_del_tag "$CHOSEN"
}

# Клиенты удалённых выходов — на выход по умолчанию; печатает, сколько их.
_xray_peers_untag() {  # тег...
  local f="$XRAY_PEERS"
  [[ -f "$f" ]] || { echo 0; return 0; }
  awk -F'|' 'NR == FNR {d[$0] = 1; next} NF > 1 && ($2 in d) {c++} END {print c + 0}' \
    <(printf '%s\n' "$@") "$f"
  awk -F'|' 'NR == FNR {d[$0] = 1; next} NF > 1 && ($2 in d) {print $1; next} {print}' \
    <(printf '%s\n' "$@") "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

xray_del_tag() {  # тег
  local n
  xray_tags | grep -qxF "$1" || { err "Выхода $1 нет"; return 1; }
  py xray-del "$XRAY_CONF" "$1"
  n=$(_xray_peers_untag "$1")
  _xray_prepare
  ok "Выход $1 удалён"
  (( ${n:-0} )) && info "Его клиенты ($n) — теперь на выходе по умолчанию"
  xray_is_up && xray_restart
  return 0
}

# Режим входа Xray: native — свой inbound tun, tun2socks — через SOCKS.
xray_mode() { if xray_tun_supported; then echo native; else echo tun2socks; fi; }

_xray_prepare() { py xray-prepare "$XRAY_CONF" "$(xray_mode)" "$XRAY_PEERS"; }

# Выход по умолчанию — для клиентов без своего выхода. Балансировщик выключается.
xray_main_set() {  # тег
  xray_installed || { err "Xray не установлен"; return 1; }
  xray_tags | grep -qxF "$1" || { err "Выхода $1 нет"; return 1; }
  py xray-main "$XRAY_CONF" "$1" || return 1
  ok "Выход по умолчанию: $1"
  if xray_is_up; then info "Перезапускаю туннель"; xray_restart; fi
  return 0
}

# Выход клиента: тег или default (выход по умолчанию / балансировщик).
# Клиент заодно включается в Xray.
xray_client_out() {  # имя тег|default
  local name="$1" tag="$2" ip old new
  xray_installed || { err "Xray не установлен"; return 1; }
  ip=$(clients_name_ip | awk -F'|' -v n="$name" '$1 == n {print $2; exit}')
  [[ -n "$ip" ]] || { err "Клиента $name нет"; return 1; }
  if [[ "$tag" != default ]]; then
    xray_tags | grep -qxF "$tag" || { err "Выхода $tag нет"; return 1; }
    if ! xray_tun_supported; then
      err "Свой выход клиенту — только с inbound tun в самом Xray, а эта сборка его не умеет"
      info "Обнови Xray: Туннели → Xray → Установить / обновить"
      return 1
    fi
  fi
  peers_sync "$XRAY_PEERS"; peers_seed "$XRAY_PEERS"
  old=$(grep -E "^${ip//./\\.}(\||$)" "$XRAY_PEERS" | head -1)
  new="$ip"; [[ "$tag" == default ]] || new="$ip|$tag"
  peers_add "$XRAY_PEERS" "$ip" "$new"
  ok "$name → $([[ "$tag" == default ]] && echo "выход по умолчанию" || echo "$tag")"
  xray_is_up || return 0
  # Правила по адресу в конфиге Xray меняются, только если выход клиента был
  # или стал своим; иначе хватает маршрута клиента в xray0
  if [[ "$old" != "$new" && ( "$old" == *"|"* || "$new" == *"|"* ) ]]; then
    _xray_prepare
    info "Перезапускаю туннель"; xray_restart
  else
    _tunnel_rules_refresh "$XRAY_PEERS" "$XRAY_IF" "$XRAY_TABLE"
  fi
  return 0
}

# «имя|ip|выход» клиентов Xray со своим выходом.
xray_client_outs() {
  local name ip line
  [[ -f "$XRAY_PEERS" ]] || return 0
  while IFS='|' read -r name ip; do
    line=$(grep -E "^${ip//./\\.}\|" "$XRAY_PEERS" | head -1)
    [[ -n "$line" ]] && echo "$name|$ip|${line#*|}"
  done < <(clients_name_ip)
  return 0
}

xray_main_menu() {
  local tags=() i c
  mapfile -t tags < <(xray_tags)
  (( ${#tags[@]} )) || { warn "Выходов нет — добавь выход ссылкой"; return 0; }
  echo -e "  Сейчас: ${W}$(py xray-main-get "$XRAY_CONF" | sed 's/^balancer$/балансировщик/')${N}"
  _xray_pick_tag || return 0
  xray_main_set "$CHOSEN"
}

xray_client_menu() {
  local tags=() i c name cur
  xray_installed || { err "Xray не установлен"; return 1; }
  mapfile -t tags < <(xray_tags)
  (( ${#tags[@]} >= 2 )) || { warn "Свой выход клиенту — когда выходов хотя бы два"; return 0; }
  _pick_client || return 0
  name="${CHOSEN%%$'\t'*}"
  [[ -n "$name" ]] || { warn "У клиента нет имени"; return 0; }
  cur=$(xray_client_outs | awk -F'|' -v n="$name" '$1 == n {print $3}')
  echo -e "  Сейчас: ${W}${cur:-выход по умолчанию}${N}"
  echo -e "  ${C}0)${N} Выход по умолчанию ${D}($(py xray-main-get "$XRAY_CONF" | sed 's/^balancer$/балансировщик/'))${N}"
  for i in "${!tags[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${tags[$i]}"; done
  read_choice c "${C}  Выход [0-${#tags[@]}]: ${N}" 0 "${#tags[@]}" 0
  if (( c == 0 )); then xray_client_out "$name" default; else xray_client_out "$name" "${tags[$((c - 1))]}"; fi
}

xray_balancer() {  # стратегия
  py xray-balancer "$XRAY_CONF" "$1" || return 1
  if [[ "$1" == off ]]; then ok "Балансировщик выключен"; else ok "Балансировщик: $1"; fi
  xray_is_up && xray_restart
  return 0
}

xray_balancer_menu() {
  local c s=(random roundRobin leastPing leastLoad off) n
  n=$(xray_tags | grep -c . || true)
  (( n >= 2 )) || { warn "Для балансировки нужно минимум 2 выхода"; return 0; }
  echo -e "  Сейчас: ${W}$(py xray-balancer-get "$XRAY_CONF")${N}"
  echo -e "  ${C}1)${N} random ${D}— случайный выход${N}"
  echo -e "  ${C}2)${N} roundRobin ${D}— по очереди${N}"
  echo -e "  ${C}3)${N} leastPing ${D}— самый быстрый${N}"
  echo -e "  ${C}4)${N} leastLoad ${D}— наименее загружен${N}"
  echo -e "  ${C}5)${N} Выключить ${D}— первый выход${N}"
  read_choice c "${C}  Выбор [1-5] (0 — отмена): ${N}" 0 5 0
  (( c )) || return 0
  xray_balancer "${s[$((c - 1))]}"
}

# ── РФ-сайты напрямую ─────────────────────────────────────
# Базы runetfreedom лежат рядом с xray: ext:geoip_RU.dat / ext:geosite_RU.dat.
xray_ru_update() {
  local tmp f want rc bak="" why
  mktmp tmp -d || return 1
  for f in geoip geosite; do
    gh_fetch "$XRAY_RUGEO_URL/$f.dat" "$tmp/$f.dat" 100000 any || { err "Не скачался $f.dat"; return 1; }
    want=""
    gh_fetch "$XRAY_RUGEO_URL/$f.dat.sha256sum" "$tmp/$f.sha" 64 any && want=$(awk '{print $1; exit}' "$tmp/$f.sha")
    rc=0; sha256_check "$tmp/$f.dat" "$want" || rc=$?
    (( rc == 1 )) && { err "$f.dat: контрольная сумма не совпала"; return 1; }
  done
  if [[ -f "$XRAY_ASSET_DIR/geoip_RU.dat" ]]; then
    bak="$tmp/bak"; mkdir -p "$bak"
    cp -a "$XRAY_ASSET_DIR"/geo{ip,site}_RU.dat "$bak/" 2>/dev/null || true
  fi
  install -m 644 "$tmp/geoip.dat" "$XRAY_ASSET_DIR/geoip_RU.dat"
  install -m 644 "$tmp/geosite.dat" "$XRAY_ASSET_DIR/geosite_RU.dat"
  if xray_ru_on && ! why=$(xray_test); then
    err "Xray не принял новые базы: $why"
    [[ -n "$bak" ]] && cp -a "$bak"/* "$XRAY_ASSET_DIR/" && warn "Возвращены прежние базы"
    return 1
  fi
  ok "РФ-базы обновлены"
}

_xray_ru_timer() {
  if [[ "$1" == off ]]; then remove_unit awg-xray-rugeo.timer awg-xray-rugeo.service; return 0; fi
  write_unit awg-xray-rugeo.service <<EOF
[Unit]
Description=AWG Toolza — обновление РФ-баз Xray
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --xray-ru-update
EOF
  write_unit awg-xray-rugeo.timer <<'EOF'
[Unit]
Description=AWG Toolza — обновление РФ-баз Xray раз в неделю

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl enable --now awg-xray-rugeo.timer &>/dev/null || warn "Таймер обновления баз не включился"
}

xray_ru_toggle() {
  xray_installed || { err "Xray не установлен"; return 1; }
  if xray_ru_on; then xray_ru_set off
  else
    echo -e "  ${D}.ru/.su/.рф, сервисы «только из РФ» и РФ-IP пойдут с сервера напрямую —${N}"
    echo -e "  ${D}нужно, когда сервер в РФ, а Xray ведёт за границу.${N}"
    xray_ru_set on
  fi
}

# РФ-сайты напрямую: on|off. Работающий туннель перезапускается.
xray_ru_set() {
  local bak why
  xray_installed || { err "Xray не установлен"; return 1; }
  if [[ "$1" == off ]]; then
    xray_ru_on && { py xray-ru "$XRAY_CONF" off && _xray_ru_timer off; }
    ok "РФ-сайты идут через туннель"
  else
    [[ -f "$XRAY_ASSET_DIR/geoip_RU.dat" && -f "$XRAY_ASSET_DIR/geosite_RU.dat" ]] || xray_ru_update || return 1
    mktmp bak || return 1
    cp -a "$XRAY_CONF" "$bak"
    py xray-ru "$XRAY_CONF" on || return 1
    if ! why=$(xray_test); then
      cp -a "$bak" "$XRAY_CONF"
      err "Xray отверг правила — конфиг возвращён: $why"
      return 1
    fi
    _xray_ru_timer on
    ok "РФ-сайты идут напрямую, базы обновляются раз в неделю"
  fi
  if xray_is_up; then info "Перезапускаю туннель"; xray_restart; fi
  return 0
}

# ── Маршрутизация (awg-xray-routing.service) ──────────────
xray_routing_run() {
  local i nat=""
  if [[ "${1:-}" == stop ]]; then rt_down "$XRAY_IF" "$XRAY_TABLE"; return 0; fi
  # Inbound tun самого Xray выбирает выход клиента по его адресу — без NAT
  grep -qx 'tun_mode=native' "$XRAY_STATE" 2>/dev/null && nat=nonat
  for i in $(seq 1 40); do ip link show "$XRAY_IF" &>/dev/null && break; sleep 0.5; done
  ip link show "$XRAY_IF" &>/dev/null || { echo "$XRAY_IF не появился" >&2; return 1; }
  ip addr add "$XRAY_TUN_ADDR" dev "$XRAY_IF" 2>/dev/null || true
  ip link set "$XRAY_IF" up
  # Мёртвый выход — не повод оставить клиентов без интернета: ждём до
  # минуты (при загрузке сеть поднимается не сразу), потом идём напрямую.
  for i in $(seq 1 8); do
    socks_probe "$XRAY_SOCKS" >/dev/null && { rt_up "$XRAY_IF" "$XRAY_TABLE" "$XRAY_PEERS" "" "$nat"; return; }
    sleep 5
  done
  echo "через Xray трафик не идёт — клиенты остаются на прямом маршруте" >&2
  return 1
}

_xray_emit_routing() {
  emit_script "$XRAY_ROUTING_SCRIPT" 'xray_routing_run "$@"' XRAY_IF XRAY_TABLE XRAY_PEERS XRAY_STATE \
    XRAY_TUN_ADDR XRAY_SOCKS socks_probe "${RT_FUNCS[@]}" xray_routing_run
}

_xray_write_units() {  # режим
  local mode="$1" after="$XRAY_UNIT"
  _xray_emit_routing || return 1
  write_unit "$XRAY_UNIT" <<EOF
[Unit]
Description=AWG Toolza — Xray
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=$XRAY_STATE

[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CONF
# После перезапуска Xray (в том числе автоматического) xray0 создаётся
# заново, а маршрут в таблице 201 умирает вместе со старым интерфейсом.
ExecStartPost=-/usr/bin/systemctl --no-block restart $XRAY_ROUTING_UNIT
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  if [[ "$mode" == tun2socks ]]; then
    after="$XRAY_UNIT $XRAY_TUN_UNIT"
    # Флаги только в длинной форме: pflag на «-device» печатает usage и
    # выходит с кодом 0 — юнит «работает» без интерфейса.
    write_unit "$XRAY_TUN_UNIT" <<EOF
[Unit]
Description=AWG Toolza — xray0 через tun2socks
After=$XRAY_UNIT
PartOf=$XRAY_UNIT

[Service]
ExecStart=$T2S_BIN --device tun://$XRAY_IF --proxy socks5://$XRAY_SOCKS --loglevel warn
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  else
    remove_unit "$XRAY_TUN_UNIT"
  fi
  write_unit "$XRAY_ROUTING_UNIT" <<EOF
[Unit]
Description=AWG Toolza — маршруты клиентов в Xray
After=$after awg-quick@awg0.service
PartOf=$XRAY_UNIT

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
ExecStart=$XRAY_ROUTING_SCRIPT start
ExecStop=$XRAY_ROUTING_SCRIPT stop

[Install]
WantedBy=multi-user.target
EOF
}

# ── Включение / выключение ────────────────────────────────
xray_up() {
  local mode=native why owners i units
  server_exists || { err "Сначала создай сервер"; return 1; }
  xray_installed || { err "Сначала установи Xray"; return 1; }
  xray_is_up && { info "Xray уже включён"; return 0; }
  [[ -n "$(xray_tags)" ]] || { err "Нет ни одного выхода — добавь выход ссылкой"; return 1; }
  tunnel_guard xray || return 1
  if ! xray_tun_supported; then
    mode=tun2socks
    info "Эта сборка Xray без inbound tun — xray0 поднимет tun2socks"
    t2s_install_bin || return 1
  fi
  peers_sync "$XRAY_PEERS"; peers_seed "$XRAY_PEERS"
  py xray-prepare "$XRAY_CONF" "$mode" "$XRAY_PEERS" || { err "Не удалось подготовить конфиг"; return 1; }
  # Прежние версии запускали Xray временными юнитами с теми же именами
  systemctl stop "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl reset-failed "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  owners=$(xray_port_owners)
  if [[ -n "$owners" ]]; then
    err "$XRAY_SOCKS уже занят — Xray не запустится:"
    sed 's/^/      /' <<< "$owners"
    info "Если это забытый ручной запуск: pkill -f 'xray run'"
    return 1
  fi
  if ! why=$(xray_test); then
    err "Xray отверг конфиг:"
    sed 's/^/      /' <<< "$why"
    info "Разбор по выходам — «Диагностика»"
    return 1
  fi
  printf 'active\nclient_net=%s\niface=%s\ntun_dev=%s\ntun_mode=%s\n' \
    "$(server_net)" "$(uplink_iface)" "$XRAY_IF" "$mode" | write_file "$XRAY_STATE" 644
  _xray_write_units "$mode" || return 1
  units=("$XRAY_UNIT")
  [[ "$mode" == tun2socks ]] && units+=("$XRAY_TUN_UNIT")
  systemctl start "${units[@]}" &>/dev/null
  for i in $(seq 1 20); do ip link show "$XRAY_IF" &>/dev/null && break; sleep 0.5; done
  if ! unit_active "$XRAY_UNIT" || ! ip link show "$XRAY_IF" &>/dev/null; then
    err "Xray не поднял $XRAY_IF: journalctl -u $XRAY_UNIT -n 30"
    xray_down quiet
    return 1
  fi
  info "Проверяю, идёт ли трафик через Xray..."
  if ! why=$(socks_probe "$XRAY_SOCKS"); then
    err "Через Xray трафик не идёт (ответ: $why) — туннель не включаю"
    info "Клиенты остались на прямом маршруте. Логи: journalctl -u $XRAY_UNIT -n 30"
    xray_down quiet
    return 1
  fi
  systemctl start "$XRAY_ROUTING_UNIT" || { err "Маршруты не применились: journalctl -u $XRAY_ROUTING_UNIT"; xray_down quiet; return 1; }
  systemctl enable "${units[@]}" "$XRAY_ROUTING_UNIT" &>/dev/null
  ok "Xray включён ($mode): клиентов через туннель — $(grep -c . "$XRAY_PEERS" || true)"
}

xray_down() {
  systemctl stop "$XRAY_ROUTING_UNIT" &>/dev/null || true
  systemctl disable "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl stop "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl reset-failed "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  rt_down "$XRAY_IF" "$XRAY_TABLE"
  ip link del "$XRAY_IF" &>/dev/null || true
  rm -f "$XRAY_STATE"
  [[ "${1:-}" == quiet ]] || ok "Xray выключен — клиенты идут напрямую"
}

xray_restart() { xray_down quiet; xray_up; }

xray_remove() {
  read_confirm "${R}  Удалить Xray (бинарь, конфиг с выходами, службы)? (введи yes): ${N}" || return 0
  xray_uninstall
}

xray_uninstall() {
  xray_down quiet
  remove_unit "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" awg-xray-rugeo.timer awg-xray-rugeo.service
  rm -rf "$XRAY_DIR" "$XRAY_BIN" "$XRAY_ROUTING_SCRIPT" \
    "$XRAY_ASSET_DIR"/geoip.dat "$XRAY_ASSET_DIR"/geosite.dat "$XRAY_ASSET_DIR"/geo{ip,site}_RU.dat
  ok "Xray удалён"
}

# ── Статус и диагностика ──────────────────────────────────
xray_status() {
  local tags=() n total name tag
  if ! xray_installed; then echo -e "  Xray      : ${D}○ не установлен${N}"; return 0; fi
  echo -e "  Версия    : $("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
  if ip link show "$XRAY_IF" &>/dev/null; then
    echo -e "  Туннель   : ${G}● включён${N} ${D}($(xray_state_get tun_mode))${N}"
    n=$(grep -c . "$XRAY_PEERS" 2>/dev/null || true); total=$(clients_name_ip | wc -l)
    echo -e "  Клиентов  : ${W}${n:-0}${N} из $total через Xray"
  elif [[ -f "$XRAY_STATE" ]]; then
    echo -e "  Туннель   : ${R}▲ включён, но $XRAY_IF нет${N} ${D}— journalctl -u $XRAY_UNIT${N}"
  else
    echo -e "  Туннель   : ${D}○ выключен${N}"
  fi
  mapfile -t tags < <(xray_tags)
  echo -e "  Выходы    : ${W}${tags[*]:-нет}${N}"
  echo -e "  Балансир  : $(py xray-balancer-get "$XRAY_CONF" 2>/dev/null || echo off)"
  (( ${#tags[@]} )) && echo -e "  По умолч. : ${W}$(py xray-main-get "$XRAY_CONF" 2>/dev/null | sed 's/^balancer$/балансировщик/')${N}"
  xray_client_outs | while IFS='|' read -r name _ tag; do
    echo -e "  ${D}  $name → $tag$(xray_tags | grep -qxF "$tag" || echo " (выхода нет — по умолчанию)")${N}"
  done
  xray_ru_on && echo -e "  РФ-сайты  : ${G}напрямую${N}"
  return 0
}

# Выходы, которых эта сборка Xray не принимает (по тегу в строке).
xray_bad_outbounds() {
  local t probe
  mktmp probe .json || return 1
  while IFS= read -r t; do
    py xray-probe-tag "$XRAY_CONF" "$t" "$probe" && ! xray_test "$probe" >/dev/null && echo "$t"
  done < <(xray_tags)
  return 0
}

xray_fix() {
  local bad=()
  mapfile -t bad < <(xray_bad_outbounds)
  if (( ${#bad[@]} )); then
    py xray-del "$XRAY_CONF" "${bad[@]}"
    _xray_peers_untag "${bad[@]}" >/dev/null
  fi
  _xray_prepare
  if xray_test >/dev/null; then ok "Конфиг принят Xray${bad[*]:+, убраны: ${bad[*]}}"
  else err "Конфиг всё ещё отвергается"; return 1; fi
}

xray_diagnose() {
  local owners why bad=()
  xray_installed || { err "Xray не установлен"; return 1; }
  info "Бинарь: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  if xray_tun_supported; then info "Inbound tun: есть — xray0 поднимает сам Xray"
  else info "Inbound tun: нет — xray0 поднимает tun2socks через $XRAY_SOCKS"; fi
  owners=$(xray_port_owners)
  if (( $(grep -c . <<< "$owners") > 1 )); then
    err "На $XRAY_SOCKS слушают несколько процессов — трафик делится между ними:"
    sed 's/^/      /' <<< "$owners"
  elif [[ -n "$owners" ]]; then
    info "$XRAY_SOCKS слушает: $owners"
  fi
  if why=$(xray_test); then ok "Конфиг принят Xray"; return 0; fi
  err "Конфиг отвергнут:"
  sed 's/^/      /' <<< "$why"
  mapfile -t bad < <(xray_bad_outbounds)
  if (( ${#bad[@]} )); then
    warn "Эта сборка Xray не принимает выходы: ${bad[*]}"
    if (( AUTO_MODE )); then info "Убрать их — «Починить конфиг»"
    elif ask_yes "  Удалить их из конфига? [Y/n]: " y; then xray_fix; fi
  else
    info "Выходы по отдельности принимаются — дело в маршрутизации."
    info "Включение туннеля само чинит ссылки на удалённые выходы."
  fi
}

do_xray_menu() {
  local c
  while true; do
    echo ""
    hdr "Xray"
    xray_status
    echo ""
    echo -e "  ${C}1)${N} Установить / обновить"
    echo -e "  ${C}2)${N} Добавить выход (ссылка)"
    echo -e "  ${C}3)${N} Удалить выход"
    echo -e "  ${C}4)${N} Балансировщик"
    echo -e "  ${C}m)${N} Выход по умолчанию"
    echo -e "  ${C}o)${N} Свой выход клиенту"
    echo -e "  ${C}5)${N} Включить туннель"
    echo -e "  ${C}6)${N} Выключить туннель"
    echo -e "  ${C}7)${N} Перезапустить туннель"
    echo -e "  ${C}8)${N} Клиенты в Xray"
    echo -e "  ${C}9)${N} Диагностика"
    echo -e "  ${C}r)${N} РФ-сайты напрямую $(xray_ru_on && echo -e "${G}● вкл${N}" || echo -e "${D}○ выкл${N}")"
    echo -e "  ${R}d)${N} Удалить Xray"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 9 0 "r|d|m|o"
    case "$c" in
      1) xray_install || true ;;
      2) xray_add_outbound || true ;;
      3) xray_del_outbound || true ;;
      4) xray_balancer_menu || true ;;
      m) xray_main_menu || true ;;
      o) xray_client_menu || true ;;
      5) xray_up || true ;;
      6) xray_down ;;
      7) xray_restart || true ;;
      8) tunnel_peers_menu "Клиенты в Xray" "$XRAY_PEERS" "$XRAY_IF" "$XRAY_TABLE"; continue ;;
      9) xray_diagnose || true ;;
      r) xray_ru_toggle || true ;;
      d) xray_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ tun2socks ═════
# tun2socks: все клиенты AWG уходят через внешний SOCKS5-прокси.
# tun0 поднимает tun2socks, маршруты ставит скрипт из ExecStartPost —
# поэтому после перезагрузки туннель восстанавливается целиком.
# Маршрутизируется вся подсеть клиентов (таблица 100), без выбора клиентов.

t2s_proxy() { head -1 "$T2S_CONF" 2>/dev/null | tr -d '[:space:]'; }

_t2s_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;; *) echo "" ;;
  esac
}

# Бинарь нужен и туннелю tun2socks, и Xray без inbound tun.
# Флаг --version именно длинный: pflag на «-version» выходит с кодом 2.
t2s_install_bin() {
  local arch tmp bin
  "$T2S_BIN" --version &>/dev/null && return 0
  arch=$(_t2s_arch)
  [[ -n "$arch" ]] || { err "Архитектура $(uname -m) не поддерживается tun2socks"; return 1; }
  need_cmds unzip:unzip || return 1
  mktmp tmp -d || return 1
  info "Скачиваю tun2socks..."
  gh_fetch "https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-$arch.zip" \
    "$tmp/t.zip" 500000 zip || { err "tun2socks не скачался ни напрямую, ни через зеркала"; return 1; }
  unzip -qo "$tmp/t.zip" -d "$tmp/x" || { err "Архив tun2socks не распаковался"; return 1; }
  # Имя бинаря в архиве меняется от релиза к релизу
  bin=$(find "$tmp/x" -type f -name 'tun2socks*' | head -1)
  [[ -n "$bin" ]] && head -c4 "$bin" | grep -q $'\x7fELF' || { err "В архиве нет бинаря tun2socks"; return 1; }
  chmod 755 "$bin"
  "$bin" --version &>/dev/null || { err "tun2socks не запускается на этой системе"; return 1; }
  install -m 755 "$bin" "$T2S_BIN"
  ok "tun2socks: $("$T2S_BIN" --version 2>/dev/null | head -1)"
}

# Точка входа ExecStartPost / ExecStopPost.
t2s_routing_run() {
  local i
  if [[ "${1:-}" == stop ]]; then rt_down "$T2S_IF" "$T2S_TABLE"; return 0; fi
  for i in $(seq 1 20); do ip link show "$T2S_IF" &>/dev/null && break; sleep 0.5; done
  ip link show "$T2S_IF" &>/dev/null || { echo "$T2S_IF не появился" >&2; return 1; }
  ip addr add "$T2S_ADDR" dev "$T2S_IF" 2>/dev/null || true
  ip link set "$T2S_IF" up
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
  rt_up "$T2S_IF" "$T2S_TABLE" -
}

t2s_up() {
  local proxy="${1:-$(t2s_proxy)}" why i
  server_exists || { err "Сначала создай сервер"; return 1; }
  [[ "$proxy" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]] || { err "Нужен адрес вида IP:ПОРТ (сейчас: ${proxy:-пусто})"; return 1; }
  t2s_is_up && { info "tun2socks уже включён"; return 0; }
  tunnel_guard tun2socks || return 1
  t2s_install_bin || return 1
  [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null || true
  # Настоящий запрос через прокси до того, как трогать маршруты: мёртвый
  # прокси иначе оставил бы всех клиентов без интернета.
  info "Проверяю SOCKS5 $proxy..."
  if ! why=$(socks_probe "$proxy"); then
    err "Через $proxy трафик не идёт (ответ: $why) — туннель не включаю"
    [[ "$proxy" == "$XRAY_SOCKS" || "$proxy" == "localhost:${XRAY_SOCKS##*:}" ]] \
      && info "Это SOCKS-вход Xray — Xray включается в своём разделе (Туннели → Xray)"
    return 1
  fi
  mkdir -p "$T2S_DIR"
  echo "$proxy" | write_file "$T2S_CONF" 600
  emit_script "$T2S_ROUTING_SCRIPT" 't2s_routing_run "$@"' T2S_IF T2S_TABLE T2S_ADDR \
    "${RT_FUNCS[@]}" t2s_routing_run || return 1
  write_unit "$T2S_UNIT" <<EOF
[Unit]
Description=AWG Toolza — клиенты через SOCKS5 (tun2socks)
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
ExecStart=$T2S_BIN --device tun://$T2S_IF --proxy socks5://$proxy --loglevel warn
ExecStartPost=$T2S_ROUTING_SCRIPT start
ExecStopPost=$T2S_ROUTING_SCRIPT stop
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  ip link del "$T2S_IF" &>/dev/null || true
  if ! systemctl enable --now "$T2S_UNIT" &>/dev/null; then
    err "tun2socks не запустился:"
    journalctl -u "$T2S_UNIT" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    t2s_down quiet
    return 1
  fi
  for i in $(seq 1 10); do ip rule show | grep -q "lookup $T2S_TABLE" && break; sleep 0.5; done
  ok "tun2socks включён: все клиенты идут через $proxy"
}

t2s_down() {
  systemctl disable --now "$T2S_UNIT" &>/dev/null || true
  systemctl reset-failed "$T2S_UNIT" &>/dev/null || true
  rt_down "$T2S_IF" "$T2S_TABLE"
  ip link del "$T2S_IF" &>/dev/null || true
  [[ "${1:-}" == quiet ]] || ok "tun2socks выключен — клиенты идут напрямую"
}

t2s_remove() {
  read_confirm "${R}  Удалить tun2socks (служба, бинарь, адрес прокси)? (введи yes): ${N}" || return 0
  t2s_uninstall
}

t2s_uninstall() {
  t2s_down quiet
  remove_unit "$T2S_UNIT"
  rm -rf "$T2S_DIR" "$T2S_ROUTING_SCRIPT"
  # Бинарь нужен и Xray без inbound tun
  [[ -f "$XRAY_STATE" && "$(xray_state_get tun_mode)" == tun2socks ]] || rm -f "$T2S_BIN"
  ok "tun2socks удалён"
}

do_tun2socks_menu() {
  local c p saved
  while true; do
    saved=$(t2s_proxy)
    echo ""
    hdr "tun2socks (все клиенты через SOCKS5)"
    if t2s_is_up; then echo -e "  Статус : ${G}● включён${N}   Прокси: ${W}$saved${N}"
    else echo -e "  Статус : ${D}○ выключен${N}${saved:+   Прокси: $saved}"; fi
    echo ""
    echo -e "  ${C}1)${N} Включить"
    echo -e "  ${C}2)${N} Выключить"
    echo -e "  ${C}3)${N} Журнал"
    echo -e "  ${R}d)${N} Удалить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 3 0 "d"
    case "$c" in
      1) echo -e "  ${D}Адрес SOCKS5-прокси, например 127.0.0.1:1080 или 5.6.7.8:1080${N}"
         read_line p "${C}  IP:ПОРТ${saved:+ (Enter = $saved)}: ${N}"
         t2s_up "${p:-$saved}" || true ;;
      2) t2s_down ;;
      3) journalctl -u "$T2S_UNIT" -n 50 --no-pager 2>/dev/null || true ;;
      d) t2s_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ exits ═════
# AWG exit-ноды: клиенты выходят в интернет через другие AWG/WG-серверы.
# Каждая нода — клиентский конфиг awg-exit-<имя>.conf с «Table = off»
# (без него awg-quick увёл бы в ноду весь сервер вместе с SSH), поднимается
# своим awg-quick@awg-exit-<имя>.
#
# Маршруты: общая таблица 202 (одна нода или ECMP между всеми), плюс
# персональные таблицы 210-249 — клиенту можно назначить свою ноду.
# Номер персональной таблицы — порядок ноды в отсортированном списке: между
# остановкой и запуском правила пересоздаются целиком, поэтому сдвиг номера
# после добавления ноды ничего не ломает.
#
# exits_state: «active|inactive», mode=all|peers, balancer=single|ecmp, single_exit=
# exits_peers.list: «IP» — общий выход, «IP|нода» — персональная нода.

exits_nodes() {
  local f n
  for f in "$EXITS_DIR"/awg-exit-*.conf; do
    [[ -f "$f" ]] || continue
    n="${f##*/awg-exit-}"; echo "${n%.conf}"
  done | LC_ALL=C sort
}

exits_up_nodes() {
  local n
  while IFS= read -r n; do
    if ip link show "awg-exit-$n" &>/dev/null; then echo "$n"; fi
  done < <(exits_nodes)
}

exits_state_get() { sed -n "s/^$1=//p" "$EXITS_STATE" 2>/dev/null | head -1; }

# exits_state_set ключ значение ... — ключи: state mode balancer single_exit
exits_state_set() {
  local st mode bal single
  st=$(head -1 "$EXITS_STATE" 2>/dev/null || true)
  [[ "$st" == active ]] || st=inactive
  mode=$(exits_state_get mode); bal=$(exits_state_get balancer); single=$(exits_state_get single_exit)
  while (( $# >= 2 )); do
    case "$1" in
      state) st="$2" ;; mode) mode="$2" ;; balancer) bal="$2" ;; single_exit) single="$2" ;;
    esac
    shift 2
  done
  mkdir -p "$EXITS_DIR"
  printf '%s\nmode=%s\nbalancer=%s\nsingle_exit=%s\n' "$st" "${mode:-all}" "${bal:-single}" "$single" \
    | write_file "$EXITS_STATE" 600
}

exits_table_for() {  # нода → номер персональной таблицы
  local n i=0
  while IFS= read -r n; do
    if [[ "$n" == "$1" ]]; then
      (( EXITS_TABLE_BASE + i <= EXITS_TABLE_MAX )) || return 1
      echo $(( EXITS_TABLE_BASE + i )); return 0
    fi
    i=$((i + 1))
  done < <(exits_nodes)
  return 1
}

exits_rules_clear() {
  local t
  for t in "$EXITS_TABLE" $(seq "$EXITS_TABLE_BASE" "$EXITS_TABLE_MAX"); do
    rt_rules_clear "$t"
    ip route flush table "$t" 2>/dev/null || true
  done
}

# ── Маршрутизация (awg-exits-routing.service) ─────────────
exits_routing_start() {
  local mode balancer single up=() n i routed="" net line pip pnode table t args
  mode=$(exits_state_get mode); mode="${mode:-all}"
  balancer=$(exits_state_get balancer)
  single=$(exits_state_get single_exit)
  # При загрузке интерфейсы нод появляются не сразу
  for i in $(seq 1 20); do
    mapfile -t up < <(exits_up_nodes)
    (( ${#up[@]} == $(exits_nodes | grep -c .) )) && break
    sleep 0.5
  done
  (( ${#up[@]} )) || { echo "ни одна exit-нода не поднята" >&2; return 1; }
  net=$(server_net) || return 1
  exits_rules_clear
  [[ " ${up[*]} " == *" $single "* ]] || single="${up[0]}"
  if [[ "$balancer" == ecmp ]] && (( ${#up[@]} > 1 )); then
    args=()
    for n in "${up[@]}"; do args+=(nexthop dev "awg-exit-$n" weight 1); done
    if ip route replace default table "$EXITS_TABLE" "${args[@]}" 2>/dev/null; then
      # Хеш по L4: соединение держится одной ноды, а не разъезжается по всем
      sysctl -qw net.ipv4.fib_multipath_hash_policy=1 2>/dev/null || true
      routed=1
    else
      echo "ядро не приняло ECMP — одна нода: $single" >&2
    fi
  fi
  [[ -n "$routed" ]] || ip route replace default dev "awg-exit-$single" table "$EXITS_TABLE" \
    || { echo "не удалось поставить маршрут в таблицу $EXITS_TABLE" >&2; return 1; }
  for n in "${up[@]}"; do rt_fw_up "awg-exit-$n"; done
  if [[ "$mode" == all ]]; then
    ip rule add from "$net" lookup "$EXITS_TABLE" priority "$EXITS_TABLE"
    return 0
  fi
  [[ -f "$EXITS_PEERS" ]] || return 0
  while IFS= read -r line; do
    line="${line//[[:space:]]/}"
    pip="${line%%|*}"; pnode=""
    [[ "$line" == *"|"* ]] && pnode="${line#*|}"
    valid_ip "$pip" || continue
    table="$EXITS_TABLE"
    # Лежащая или удалённая нода — клиент идёт общим выходом, а не в пустоту
    if [[ -n "$pnode" && " ${up[*]} " == *" $pnode "* ]] && t=$(exits_table_for "$pnode") \
       && ip route replace default dev "awg-exit-$pnode" table "$t" 2>/dev/null; then
      table="$t"
    fi
    ip rule add from "$pip" lookup "$table" priority "$EXITS_TABLE" || true
  done < "$EXITS_PEERS"
}

exits_routing_stop() {
  local n
  exits_rules_clear
  while IFS= read -r n; do rt_fw_down "awg-exit-$n"; done < <(exits_nodes)
  return 0
}

exits_routing_run() {
  if [[ "${1:-}" == stop ]]; then exits_routing_stop; else exits_routing_start; fi
}

_exits_write_unit() {
  emit_script "$EXITS_SCRIPT" 'exits_routing_run "$@"' EXITS_DIR EXITS_STATE EXITS_PEERS EXITS_TABLE \
    EXITS_TABLE_BASE EXITS_TABLE_MAX exits_nodes exits_up_nodes exits_state_get exits_table_for \
    exits_rules_clear exits_routing_start exits_routing_stop exits_routing_run "${RT_FUNCS[@]}" || return 1
  write_unit "$EXITS_UNIT" <<EOF
[Unit]
Description=AWG Toolza — маршруты клиентов через exit-ноды
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$EXITS_SCRIPT start
ExecStop=$EXITS_SCRIPT stop

[Install]
WantedBy=multi-user.target
EOF
}

# Список «выбранных» при переходе в них из режима «все клиенты». all —
# действие над одним клиентом относительно «все» (exits_client, меню): в
# списке все клиенты. Иначе («выбранные» кнопкой, exits up peers) — прежний
# выбор, а если его нет или он пуст (после «никто», сброса сервера) — тоже
# все: пустой список увёл бы мимо нод вообще всех. В режиме «выбранные»
# пустой список — сознательное «никто», его не трогаем.
_exits_seed_peers() {  # [all]
  mkdir -p "$(dirname "$EXITS_PEERS")"
  peers_sync "$EXITS_PEERS"
  if [[ "$(exits_state_get mode)" == peers ]]; then peers_seed "$EXITS_PEERS"; return 0; fi
  if [[ "${1:-}" == all ]] || ! grep -q . "$EXITS_PEERS" 2>/dev/null; then peers_all "$EXITS_PEERS"; fi
  return 0
}

exits_reapply() { exits_is_up && systemctl restart "$EXITS_UNIT" &>/dev/null; return 0; }

# ── Включение / выключение ────────────────────────────────
exits_up() {  # all|peers
  local mode="${1:-$(exits_state_get mode)}"
  mode="${mode:-all}"
  server_exists || { err "Сначала создай сервер"; return 1; }
  [[ -n "$(exits_up_nodes)" ]] || { err "Ни одна exit-нода не поднята — добавь или перезапусти ноду"; return 1; }
  # Список клиентов режима peers — до проверки «уже включено»: иначе при
  # переключении all → peers на ходу файла нет, и маршруты не получает никто.
  if [[ "$mode" == peers ]]; then _exits_seed_peers; fi
  if exits_is_up; then exits_state_set mode "$mode"; exits_reapply; ok "Режим: $mode"; return 0; fi
  tunnel_guard exits || return 1
  exits_state_set state active mode "$mode"
  _exits_write_unit || return 1
  if ! systemctl enable --now "$EXITS_UNIT" &>/dev/null; then
    err "Маршрутизация не запустилась:"
    journalctl -u "$EXITS_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    exits_down quiet
    return 1
  fi
  if [[ "$mode" == all ]]; then ok "Exit-ноды включены: все клиенты идут через них"
  else ok "Exit-ноды включены: клиентов в списке — $(grep -c . "$EXITS_PEERS" || true)"; fi
}

exits_down() {
  systemctl disable --now "$EXITS_UNIT" &>/dev/null || true
  systemctl reset-failed "$EXITS_UNIT" &>/dev/null || true
  exits_routing_stop
  [[ -f "$EXITS_STATE" ]] && exits_state_set state inactive
  [[ "${1:-}" == quiet ]] || ok "Exit-ноды выключены — клиенты идут напрямую"
}

# ── Ноды ──────────────────────────────────────────────────
exits_add() {
  local name c tmp path
  read_line name "${C}  Имя ноды (латиница/цифры/_, до 6 символов): ${N}"
  [[ -n "$name" ]] || return 0
  mktmp tmp || return 1
  echo -e "  ${C}1)${N} Вставить текст конфига"
  echo -e "  ${C}2)${N} Путь к файлу .conf"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    echo -e "  Вставь клиентский конфиг AWG/WG целиком, затем Enter и Ctrl+D:"
    cat > "$tmp"
  else
    read_line path "${C}  Путь: ${N}"
    [[ -f "$path" ]] || { err "Файла нет: $path"; return 1; }
    cat "$path" > "$tmp"
  fi
  exits_node_add "$name" "$tmp" || return 1
  if ask_yes "  Сделать её основным выходом? [Y/n]: " y; then exits_balance single "$name"; else exits_reapply; fi
}

# exits_node_add ИМЯ ФАЙЛ — поставить ноду из клиентского конфига AWG/WG.
exits_node_add() {
  local name="$1" tmp f i
  [[ "$name" =~ ^[A-Za-z0-9_]{1,6}$ ]] || { err "Имя ноды: латиница, цифры, _, до 6 символов"; return 1; }
  f="$EXITS_DIR/awg-exit-$name.conf"
  [[ -f "$f" ]] && { err "Нода $name уже есть"; return 1; }
  [[ -s "$2" ]] || { err "Пустой конфиг"; return 1; }
  mktmp tmp || return 1
  cat "$2" > "$tmp"
  grep -qiE '^\s*\[Interface\]' "$tmp" || { err "Нет секции [Interface]"; return 1; }
  grep -qiE '^\s*Endpoint\s*=' "$tmp" || { err "Нет Endpoint — это не клиентский конфиг"; return 1; }
  # Table = off (иначе через ноду уйдёт весь сервер) и без DNS (awg-quick
  # переписал бы resolv.conf сервера или упал без resolvconf)
  py exit-conf-fix "$tmp" && grep -qiE '^\s*Table\s*=\s*off' "$tmp" \
    || { err "Не удалось подготовить конфиг — ноду не ставлю"; return 1; }
  install -m 600 "$tmp" "$f"
  systemctl enable --now "awg-quick@awg-exit-$name" &>/dev/null || true
  for i in $(seq 1 10); do ip link show "awg-exit-$name" &>/dev/null && break; sleep 0.5; done
  if ! ip link show "awg-exit-$name" &>/dev/null; then
    err "Нода не поднялась:"
    journalctl -u "awg-quick@awg-exit-$name" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    systemctl disable --now "awg-quick@awg-exit-$name" &>/dev/null || true
    rm -f "$f"
    return 1
  fi
  ok "Нода $name поднята"
}

_exits_node_line() {  # нода → строка статуса
  local n="$1" dev="awg-exit-$1" hs now ago rx tx
  if ! ip link show "$dev" &>/dev/null; then echo -e "${R}○ лежит${N}"; return; fi
  hs=$(awg show "$dev" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  now=$(date +%s)
  read -r rx tx < <(awg show "$dev" transfer 2>/dev/null | awk '{print $2, $3; exit}')
  if [[ -z "$hs" || "$hs" == 0 ]]; then echo -e "${Y}● поднята, рукопожатия нет${N}"
  else
    ago=$(( now - hs ))
    if (( ago < 180 )); then echo -e "${G}● связь $(fmt_duration "$ago") назад${N} ${D}↓$(fmt_bytes "${rx:-0}") ↑$(fmt_bytes "${tx:-0}")${N}"
    else echo -e "${Y}● последнее рукопожатие $(fmt_duration "$ago") назад${N}"; fi
  fi
}

exits_list() {
  local nodes=() n ip sample
  mapfile -t nodes < <(exits_nodes)
  (( ${#nodes[@]} )) || { info "Нод нет"; return 0; }
  for n in "${nodes[@]}"; do
    echo -e "  ${W}$n${N}  $(_exits_node_line "$n")"
    if ip link show "awg-exit-$n" &>/dev/null; then
      ip=$(iface_egress_ip "awg-exit-$n" 5)
      if [[ -n "$ip" ]]; then echo -e "      выход в интернет: ${G}$ip${N}"; else echo -e "      ${R}выхода в интернет нет${N}"; fi
    fi
  done
  if exits_is_up; then
    sample=$(clients_name_ip | head -1 | cut -d'|' -f2)
    [[ -n "$sample" ]] && echo -e "  ${D}Маршрут клиента $sample: $(ip route get 1.1.1.1 from "$sample" iif "$AWG_IF" 2>/dev/null | head -1)${N}"
  fi
}

exits_delete() {
  local nodes=() c n
  mapfile -t nodes < <(exits_nodes)
  (( ${#nodes[@]} )) || { info "Нод нет"; return 0; }
  for c in "${!nodes[@]}"; do echo -e "  ${C}$((c + 1)))${N} ${nodes[$c]}"; done
  read_choice c "${C}  Удалить ноду (0 — отмена): ${N}" 0 "${#nodes[@]}" 0
  (( c )) || return 0
  n="${nodes[$((c - 1))]}"
  ask_yes "  Удалить ноду $n? [y/N]: " n || return 0
  exits_node_del "$n"
}

exits_node_del() {  # имя
  local n="$1"
  [[ -f "$EXITS_DIR/awg-exit-$n.conf" ]] || { err "Ноды $n нет"; return 1; }
  exits_is_up && exits_routing_stop
  systemctl disable --now "awg-quick@awg-exit-$n" &>/dev/null || true
  rm -f "$EXITS_DIR/awg-exit-$n.conf"
  # Клиенты этой ноды переходят на общий выход
  [[ -f "$EXITS_PEERS" ]] && sed -i "s/|$n\$//" "$EXITS_PEERS"
  [[ "$(exits_state_get single_exit)" == "$n" ]] && exits_state_set single_exit ""
  ok "Нода $n удалена"
  if exits_is_up; then
    if [[ -n "$(exits_up_nodes)" ]]; then exits_reapply; else warn "Нод не осталось"; exits_down; fi
  fi
}

exits_balancer_menu() {
  local up=() c i
  mapfile -t up < <(exits_up_nodes)
  (( ${#up[@]} )) || { warn "Ни одна нода не поднята"; return 0; }
  echo -e "  Сейчас: ${W}$(exits_state_get balancer)${N} $(exits_state_get single_exit)"
  echo -e "  ${C}1)${N} Одна нода"
  if (( ${#up[@]} > 1 )); then echo -e "  ${C}2)${N} ECMP ${D}— все поднятые ноды${N}"
  else echo -e "  ${D}2) ECMP — нужны две поднятые ноды${N}"; fi
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 2 0
  case "$c" in
    1) for i in "${!up[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${up[$i]}"; done
       read_choice i "${C}  Нода: ${N}" 1 "${#up[@]}"
       exits_balance single "${up[$((i - 1))]}" ;;
    2) (( ${#up[@]} > 1 )) && exits_balance ecmp ;;
  esac
  return 0
}

# exits_balance single НОДА | ecmp
exits_balance() {
  case "$1" in
    single) [[ -f "$EXITS_DIR/awg-exit-${2:-}.conf" ]] || { err "Ноды ${2:-?} нет"; return 1; }
            exits_state_set balancer single single_exit "$2" ;;
    ecmp) (( $(exits_up_nodes | grep -c . || true) > 1 )) || { err "Для ECMP нужны две поднятые ноды"; return 1; }
          exits_state_set balancer ecmp ;;
    *) err "Балансировка: single НОДА | ecmp"; return 1 ;;
  esac
  ok "Балансировка: $1${2:+ $2}"
  exits_reapply
}

# Клиент и exit-ноды: exits_client ИМЯ off|shared|НОДА. Переводит в выборочный режим.
# exits_client ИМЯ|all|none off|shared|НОДА — выход клиента; all — все клиенты
# через ноды (у кого своя нода, она остаётся), none — никто: все напрямую.
# Режим при этом — «выбранные клиенты»; маршруты перезапускаются один раз.
# Массовая форма — только без второго аргумента: клиент может называться
# «all» или «none», и «exits client all off» — про него, а не про всех.
exits_client() {
  local ip
  if [[ ( "$1" == all || "$1" == none ) && -z "${2:-}" ]]; then
    mkdir -p "$(dirname "$EXITS_PEERS")"
    peers_sync "$EXITS_PEERS"
    if [[ "$1" == all ]]; then
      peers_all "$EXITS_PEERS"
    else
      : > "$EXITS_PEERS"
    fi
    exits_state_set mode peers
    exits_reapply
    ok "Через exit-ноды: $(grep -c . "$EXITS_PEERS" || true) из $(clients_name_ip | grep -c . || true)"
    return 0
  fi
  ip=$(clients_name_ip | awk -F'|' -v n="$1" '$1 == n {print $2; exit}')
  [[ -n "$ip" ]] || { err "Клиента $1 нет"; return 1; }
  # Из «все клиенты» в «выбранные»: список — все клиенты (свои ноды остаются),
  # а не то, что лежало в файле. После «никто» или сброса сервера он пуст, и
  # «alice — напрямую» уводило мимо нод вообще всех.
  if [[ "$(exits_state_get mode)" != peers ]]; then
    _exits_seed_peers all
    exits_state_set mode peers
  fi
  case "$2" in
    off) peers_del "$EXITS_PEERS" "$ip" ;;
    shared) peers_add "$EXITS_PEERS" "$ip" ;;
    *) [[ -f "$EXITS_DIR/awg-exit-$2.conf" ]] || { err "Ноды $2 нет"; return 1; }
       peers_add "$EXITS_PEERS" "$ip" "$ip|$2" ;;
  esac
  exits_reapply
  ok "$1: ${2/shared/общий выход}"
}

# exits_mode all|peers — кого вести через ноды, не включая и не выключая их
exits_mode() {
  [[ "${1:-}" == all || "${1:-}" == peers ]] || { err "Режим: all | peers"; return 1; }
  if [[ "$1" == peers ]]; then _exits_seed_peers; fi
  exits_state_set mode "$1"
  exits_reapply
  if [[ "$1" == all ]]; then ok "Через exit-ноды — все клиенты"
  else ok "Через exit-ноды — выбранные: $(grep -c . "$EXITS_PEERS" || true)"; fi
}

exits_toggle() {
  local c
  if exits_is_up; then exits_down; return; fi
  echo -e "  ${C}1)${N} Все клиенты"
  echo -e "  ${C}2)${N} Выборочно"
  read_choice c "${C}  Кого вести через exit-ноды [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then exits_up all; else exits_up peers; fi
}

# ── Клиенты ───────────────────────────────────────────────
_exits_peer_node() { grep -E "^${1//./\\.}\|" "$EXITS_PEERS" 2>/dev/null | head -1 | cut -d'|' -f2; }

_exits_assign() {  # ip имя
  local nodes=() i c cur
  mapfile -t nodes < <(exits_nodes)
  (( ${#nodes[@]} > 1 )) || { info "Нода одна — назначать нечего"; return 0; }
  cur=$(_exits_peer_node "$1")
  echo -e "  Клиент ${W}$2${N}: ${cur:+нода $cur}${cur:-общий выход}"
  for i in "${!nodes[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${nodes[$i]}"; done
  echo -e "  ${C}$(( ${#nodes[@]} + 1 )))${N} общий выход"
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 $(( ${#nodes[@]} + 1 )) 0
  (( c )) || return 0
  if (( c > ${#nodes[@]} )); then peers_add "$EXITS_PEERS" "$1"
  else peers_add "$EXITS_PEERS" "$1" "$1|${nodes[$((c - 1))]}"; fi
}

exits_peers_menu() {
  local rows=() i c name ip node sel
  # Выбор клиентов имеет смысл только в режиме «выборочно»
  if [[ "$(exits_state_get mode)" != peers ]]; then
    info "Сейчас через exit-ноды идут все клиенты — переключаю на выборочный режим"
    _exits_seed_peers all
    exits_state_set mode peers
    exits_reapply
  fi
  while true; do
    peers_sync "$EXITS_PEERS"
    mapfile -t rows < <(clients_name_ip)
    (( ${#rows[@]} )) || { warn "Клиентов нет"; return 0; }
    echo ""
    hdr "Клиенты через exit-ноды"
    for i in "${!rows[@]}"; do
      name="${rows[$i]%%|*}"; ip="${rows[$i]#*|}"
      if peers_has "$EXITS_PEERS" "$ip"; then
        node=$(_exits_peer_node "$ip")
        echo -e "  ${G}$((i + 1)))${N} $name ${D}$ip${N}  ${C}${node:+нода $node}${node:-общий выход}${N}"
      else
        echo -e "  ${D}$((i + 1))) $name $ip  напрямую${N}"
      fi
    done
    echo -e "  ${C}e)${N} Назначить ноду"
    echo -e "  ${C}a)${N} Все через exit-ноды"
    echo -e "  ${C}n)${N} Все напрямую"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер — вкл/выкл: ${N}" 0 "${#rows[@]}" 0 "e|a|n"
    case "$c" in
      0) return 0 ;;
      a) peers_all "$EXITS_PEERS" ;;          # свои ноды клиентов остаются
      n) : > "$EXITS_PEERS" ;;
      e) read_choice sel "${C}  Номер клиента: ${N}" 1 "${#rows[@]}"
         _exits_assign "${rows[$((sel - 1))]#*|}" "${rows[$((sel - 1))]%%|*}" ;;
      *) ip="${rows[$((c - 1))]#*|}"
         if peers_has "$EXITS_PEERS" "$ip"; then peers_del "$EXITS_PEERS" "$ip"; else peers_add "$EXITS_PEERS" "$ip"; fi ;;
    esac
    exits_reapply
  done
}

exits_status() {
  local mode bal n
  n=$(exits_nodes | grep -c . || true)
  echo -e "  Ноды      : ${W}$n${N} (поднято $(exits_up_nodes | grep -c . || true))"
  if exits_is_up; then
    mode=$(exits_state_get mode); bal=$(exits_state_get balancer)
    echo -e "  Маршруты  : ${G}● включены${N} — $([[ "$mode" == peers ]] && echo "выборочно, $(n=$(grep -c . "$EXITS_PEERS" 2>/dev/null); echo "${n:-0}") кл." || echo "все клиенты")"
    if [[ "$bal" == ecmp ]]; then echo -e "  Балансир  : ECMP"
    else echo -e "  Балансир  : одна нода ($(exits_state_get single_exit))"; fi
  elif unit_enabled "$EXITS_UNIT"; then
    echo -e "  Маршруты  : ${R}▲ служба не запущена${N} — journalctl -u $EXITS_UNIT"
  else
    echo -e "  Маршруты  : ${D}○ выключены${N}"
  fi
}

do_exits_menu() {
  local c
  while true; do
    echo ""
    hdr "AWG exit-ноды"
    exits_status
    echo ""
    echo -e "  ${C}1)${N} Добавить ноду"
    echo -e "  ${C}2)${N} Список и проверка"
    echo -e "  ${C}3)${N} Удалить ноду"
    echo -e "  ${C}4)${N} Вкл/выкл маршруты"
    echo -e "  ${C}5)${N} Балансировка"
    echo -e "  ${C}6)${N} Клиенты"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-6]: ${N}" 0 6 0
    case "$c" in
      1) exits_add || true ;;
      2) exits_list ;;
      3) exits_delete || true ;;
      4) exits_toggle || true ;;
      5) exits_balancer_menu || true ;;
      6) exits_peers_menu; continue ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ wgobf ═════
# WG + обфускатор: отдельный WireGuard-сервер (wgobf0) за wg-obfuscator
# (github.com/ClusterM/wg-obfuscator, GPL-3.0; собирается из закреплённого
# коммита отдельной программой, его код в скрипт не копируется).
#
# Клиент → [wg-obfuscator клиента] → порт обфускатора на сервере →
# 127.0.0.1:<порт WG> → wgobf0. Порт самого WireGuard снаружи закрыт
# (WireGuard не умеет слушать только lo), открыт лишь порт обфускатора.
#
# С AWG не пересекается: свой интерфейс и /24, туннели тулзы маршрутизируют
# только подсеть awg0, правила iptables и UFW помечены «awg-wgobf», клиенты
# лежат в /root/wgobf/<имя>/ и под маску *_awg[23].conf не попадают.
#
# state (KEY=VAL): PORT WG_PORT KEY MASKING ALLOW_CLEAN NET MTU DNS ENDPOINT SERVER_PUB

wgobf_installed() { [[ -f "$WGOBF_STATE" && -f "$WGOBF_WG_CONF" ]]; }
wgobf_get() { sed -n "s/^$1=//p" "$WGOBF_STATE" 2>/dev/null | head -1; }

wgobf_set() {
  mkdir -p "$WGOBF_DIR" && chmod 700 "$WGOBF_DIR"
  { grep -v "^$1=" "$WGOBF_STATE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } \
    | write_file "$WGOBF_STATE" 600
}

# Порт закреплён за режимом, даже когда его службы остановлены.
wgobf_owns_port() {
  wgobf_installed || return 1
  [[ "$1" == "$(wgobf_get PORT)" || "$1" == "$(wgobf_get WG_PORT)" ]]
}

wgobf_clients() { sed -n 's/^# client=//p' "$WGOBF_WG_CONF" 2>/dev/null || true; }
wgobf_bin_version() { "$WGOBF_BIN" --help 2>&1 | grep -oE 'Obfuscator v[0-9.]+' | head -1 | awk '{print $2}' || true; }
wgobf_running() { unit_active "$WGOBF_UNIT" && ip link show "$WGOBF_IF" &>/dev/null; }

# ── Правила iptables (PostUp / PostDown wgobf0) ───────────
# MASQUERADE через «! -o wgobf0», а не по имени аплинка: переименование
# интерфейса у хостера после перезагрузки ничего не ломает.
wgobf_fw_run() {
  local t net wg_port
  for t in filter nat; do ipt_del_tagged "$t" "$WGOBF_TAG"; done
  [[ "${1:-}" == up ]] || return 0
  net=$(wgobf_get NET); wg_port=$(wgobf_get WG_PORT)
  [[ -n "$net" && -n "$wg_port" ]] || { echo "wgobf-fw: в $WGOBF_STATE нет NET/WG_PORT" >&2; return 1; }
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s "$net" ! -o "$WGOBF_IF" -j MASQUERADE -m comment --comment "$WGOBF_TAG" || return 1
  iptables -I FORWARD 1 -i "$WGOBF_IF" -j ACCEPT -m comment --comment "$WGOBF_TAG" || return 1
  iptables -I FORWARD 1 -o "$WGOBF_IF" -j ACCEPT -m comment --comment "$WGOBF_TAG" || return 1
  # Порт WireGuard — только для обфускатора, который ходит через lo
  iptables -I INPUT 1 -p udp --dport "$wg_port" ! -i lo -j DROP -m comment --comment "$WGOBF_TAG" || return 1
}

_wgobf_write_service_files() {
  local clean
  emit_script "$WGOBF_FW" 'wgobf_fw_run "$@"' WGOBF_STATE WGOBF_TAG WGOBF_IF \
    ipt_del_grep ipt_del_tagged wgobf_get wgobf_fw_run || return 1
  clean=$(wgobf_get ALLOW_CLEAN)
  # masking = AUTO: сервер понимает и STUN, и голый XOR — режим выбирает клиент
  write_file "$WGOBF_OBF_CONF" 600 <<EOF
# AWG Toolza — серверный wg-obfuscator для $WGOBF_IF. Перезаписывается awg2.
[main]
source-if = 0.0.0.0
source-lport = $(wgobf_get PORT)
target = 127.0.0.1:$(wgobf_get WG_PORT)
key = $(wgobf_get KEY)
masking = AUTO
$([[ "$clean" == 1 ]] && echo "allow-clean = true")
verbose = INFO
EOF
  write_unit "$WGOBF_UNIT" <<EOF
[Unit]
Description=AWG Toolza — wg-obfuscator для $WGOBF_IF
After=network-online.target wg-quick@$WGOBF_IF.service
Wants=network-online.target

[Service]
ExecStart=$WGOBF_BIN -c $WGOBF_OBF_CONF
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
}

wgobf_start() {
  local out
  systemctl enable "wg-quick@$WGOBF_IF" "$WGOBF_UNIT" &>/dev/null || true
  if ! out=$(systemctl restart "wg-quick@$WGOBF_IF" 2>&1) || ! ip link show "$WGOBF_IF" &>/dev/null; then
    err "$WGOBF_IF не поднялся"
    [[ -n "$out" ]] && sed 's/^/    /' <<< "$out"
    journalctl -u "wg-quick@$WGOBF_IF" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  systemctl restart "$WGOBF_UNIT" &>/dev/null
  sleep 1
  unit_active "$WGOBF_UNIT" && return 0
  err "wg-obfuscator не запустился:"
  journalctl -u "$WGOBF_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

wgobf_restart() { _wgobf_write_service_files && wgobf_start; }

# Изменения пиров — без обрыва подключённых клиентов.
_wgobf_sync() {
  local stripped
  ip link show "$WGOBF_IF" &>/dev/null || return 0
  stripped=$(wg-quick strip "$WGOBF_IF" 2>/dev/null) || { wgobf_start; return; }
  wg syncconf "$WGOBF_IF" <(printf '%s\n' "$stripped")
}

# ── Сборка и зависимости ──────────────────────────────────
_wgobf_build() {
  local src
  src=$(mktemp -d /tmp/awg2.wgobf.XXXXXX) || return 1
  # Тег можно перевесить, коммит — нет: сверяем после клона
  if git -c advice.detachedHead=false clone -q --depth 1 --branch "$WGOBF_VERSION" "$WGOBF_REPO" "$src/s" \
     && [[ "$(git -C "$src/s" rev-parse HEAD)" == "$WGOBF_COMMIT" ]] \
     && make -C "$src/s" RELEASE=1 \
     && install -D -m 755 "$src/s/wg-obfuscator" "$WGOBF_BIN"; then
    rm -rf "$src"; return 0
  fi
  echo "сборка не удалась (или коммит тега $WGOBF_VERSION не $WGOBF_COMMIT)"
  rm -rf "$src"
  return 1
}

_wgobf_prepare() {
  need_cmds wg:wireguard-tools wg-quick:wireguard-tools git:git make:make gcc:gcc || return 1
  command -v qrencode &>/dev/null || apt_install qrencode &>/dev/null || true
  mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
  modprobe wireguard 2>/dev/null || true
  if ! ip link add dev wgobfchk type wireguard 2>/dev/null && ! command -v wireguard-go &>/dev/null; then
    err "Ядро $(uname -r) не умеет WireGuard, и wireguard-go не установлен"
    return 1
  fi
  ip link del dev wgobfchk 2>/dev/null || true
  [[ "$(wgobf_bin_version)" == "$WGOBF_VERSION" ]] && return 0
  run_step "Сборка wg-obfuscator $WGOBF_VERSION" _wgobf_build
}

# ── Комплект клиента ──────────────────────────────────────
# /root/wgobf/<имя>/. Ключи берутся из уже выпущенного wg.conf, поэтому
# комплект можно перевыпустить после смены настроек, не трогая ключи.
wgobf_write_bundle() {  # имя [priv addr psk]
  local name="$1" priv="${2:-}" addr="${3:-}" psk="${4:-}" dir="$WGOBF_CLIENTS/$1"
  local ep port key mask mtu dns srv allowed
  if [[ -z "$priv" ]]; then
    priv=$(sed -n 's/^PrivateKey = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    addr=$(sed -n 's/^Address = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    psk=$(sed -n 's/^PresharedKey = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    [[ -n "$priv" && -n "$addr" ]] || { err "Нет ключей клиента $name в $dir/wg.conf"; return 1; }
  fi
  ep=$(wgobf_get ENDPOINT); port=$(wgobf_get PORT); key=$(wgobf_get KEY)
  mask=$(wgobf_get MASKING); mtu=$(wgobf_get MTU); dns=$(wgobf_get DNS); srv=$(wgobf_get SERVER_PUB)
  # «Весь интернет, кроме сервера»: пакеты обфускатора к серверу иначе
  # уйдут в сам туннель
  allowed=$(py allowed-except "$ep") || return 1
  mkdir -p "$dir" && chmod 700 "$WGOBF_CLIENTS" "$dir"
  # Локальный порт обфускатора у клиента = порт сервера: у клиента с
  # несколькими такими серверами порты не столкнутся
  write_file "$dir/wg.conf" 600 <<EOF
[Interface]
PrivateKey = $priv
Address = $addr
DNS = $dns
MTU = $mtu

[Peer]
PublicKey = $srv
PresharedKey = $psk
Endpoint = 127.0.0.1:$port
AllowedIPs = $allowed
PersistentKeepalive = 25
EOF
  write_file "$dir/obfuscator.conf" 600 <<EOF
[main]
source-if = 127.0.0.1
source-lport = $port
target = $ep:$port
key = $key
masking = $mask
verbose = INFO
EOF
  rm -f "$dir/wg-direct.conf"
  if [[ "$(wgobf_get ALLOW_CLEAN)" == 1 ]]; then
    sed -e "s|^Endpoint = .*|Endpoint = $ep:$port|" -e 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, ::/0|' \
      "$dir/wg.conf" | write_file "$dir/wg-direct.conf" 600
  fi
  # Формат Phobos: без obfuscate-bytes и маскировки MEDIA — их сервер
  # ClusterM не понимает (проверено вживую)
  { cat "$dir/wg.conf"; printf '\n[instance]\ntarget = %s:%s\nkey = %s\nmasking = %s\nmax-dummy = 4\n' \
      "$ep" "$port" "$key" "$mask"; } | write_file "$dir/phobos.conf" 600
  py phobos-link "$dir/phobos.conf" "$name" | write_file "$dir/phobos-link.txt" 600
  _wgobf_write_keenetic "$name" "$dir"
  _wgobf_write_readme "$name" "$dir"
  _wgobf_write_installer "$name" "$dir"
}

_wgobf_write_keenetic() {
  local name="$1" dir="$2"
  {
    echo "Keenetic + AWG Manager — клиент $name"
    echo ""
    echo "Способ 1 — вкладка «Phobos», одной вставкой в НИЖНЕЕ поле."
    echo "AWG Manager → Новый туннель → «Phobos» → поле «Или конфиг .conf с секцией"
    echo "[instance] / ссылка phobos://» → ссылка из phobos-link.txt (или phobos.conf)."
    echo "Поле «Ссылка установки Phobos» — пустым. Во вкладке «Обфускатор» НЕ включать"
    echo "obfuscate-bytes и MEDIA: сервер их не понимает, связь пропадёт."
    echo ""
    echo "Способ 2 — вкладка «ClusterM», поля руками:"
    echo "Сервер (host:port) обфускатора: $(wgobf_get ENDPOINT):$(wgobf_get PORT)"
    echo "Ключ:                          $(wgobf_get KEY)"
    echo "Маскировка:                    $(wgobf_get MASKING)"
    echo "max-dummy:                     4"
    echo "idle-timeout:                  0"
    echo ""
    echo "Конфиг WireGuard (.conf) — всё от [Interface] до конца:"
    echo ""
    cat "$dir/wg.conf"
  } | write_file "$dir/keenetic.txt" 600
}

_wgobf_write_readme() {
  local name="$1" dir="$2"
  {
    echo "WG + обфускатор — клиент $name"
    echo "Сервер: $(wgobf_get ENDPOINT):$(wgobf_get PORT) (UDP), маскировка: $(wgobf_get MASKING)"
    echo ""
    echo "Файлы:"
    echo "  wg.conf          — WireGuard (Endpoint 127.0.0.1 — там слушает обфускатор)"
    echo "  obfuscator.conf  — wg-obfuscator $WGOBF_VERSION"
    echo "  install-linux.sh — всё на Debian/Ubuntu одной командой"
    echo "  keenetic.txt     — AWG Manager на Keenetic"
    echo "  phobos.conf      — формат Phobos (wg.conf + [instance])"
    echo "  phobos-link.txt  — то же ссылкой phobos://"
    [[ -f "$dir/wg-direct.conf" ]] && echo "  wg-direct.conf   — БЕЗ обфускатора (телефоны); DPI видит его как WireGuard"
    echo ""
    echo "Linux (Debian/Ubuntu): sudo bash install-linux.sh"
    echo ""
    echo "Windows / macOS:"
    echo "  1. wg-obfuscator $WGOBF_VERSION: https://github.com/ClusterM/wg-obfuscator/releases/tag/$WGOBF_VERSION"
    echo "  2. wg-obfuscator -c obfuscator.conf (окно не закрывать)"
    echo "  3. wg.conf — в приложение WireGuard"
    echo ""
    echo "OpenWrt: https://github.com/ClusterM/wg-obfuscator/blob/master/docs/OPENWRT.md"
    echo "Android: https://github.com/ClusterM/wg-obfuscator-android + приложение WireGuard."
    echo "iOS обфускатор не поддерживает."
  } | write_file "$dir/README.txt" 600
}

# Самостоятельный установщик клиента для Debian/Ubuntu: собирает тот же
# коммит обфускатора, кладёт конфиги и включает автозапуск.
_wgobf_write_installer() {
  local name="$1" dir="$2"
  {
    cat <<EOF
#!/bin/bash
# AWG Toolza — клиент «WG + обфускатор» ($name) для Debian/Ubuntu.
# Установка: sudo bash install-linux.sh     Удаление: sudo bash install-linux.sh --remove
set -euo pipefail
[[ \$EUID -eq 0 ]] || { echo "Запусти от root: sudo bash \$0"; exit 1; }
TAG="wgobf-$name"
LIB="/usr/local/lib/\$TAG"; CONF_DIR="/etc/\$TAG"; UNIT="\$TAG-obfuscator.service"
WG_IF="\$TAG"; [[ \${#WG_IF} -le 15 ]] || WG_IF="wgobf-cli"

if [[ "\${1:-}" == --remove ]]; then
  systemctl disable --now "wg-quick@\$WG_IF" "\$UNIT" 2>/dev/null || true
  rm -rf "/etc/systemd/system/\$UNIT" "/etc/wireguard/\$WG_IF.conf" "\$LIB" "\$CONF_DIR"
  systemctl daemon-reload
  echo "Клиент удалён"; exit 0
fi

command -v apt-get >/dev/null || { echo "Нужен Debian/Ubuntu. На другой системе — см. README.txt"; exit 1; }
need=()
for b in wg:wireguard-tools wg-quick:wireguard-tools git:git make:make gcc:gcc; do
  command -v "\${b%%:*}" >/dev/null || need+=("\${b#*:}")
done
if (( \${#need[@]} )); then apt-get update -q; apt-get install -y -q \$(printf '%s\n' "\${need[@]}" | sort -u); fi

src=\$(mktemp -d); trap 'rm -rf "\$src"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 --branch "$WGOBF_VERSION" "$WGOBF_REPO" "\$src/s"
[[ "\$(git -C "\$src/s" rev-parse HEAD)" == "$WGOBF_COMMIT" ]] || { echo "Коммит тега $WGOBF_VERSION не совпал — сборка остановлена"; exit 1; }
make -C "\$src/s" RELEASE=1 >/dev/null
install -D -m 755 "\$src/s/wg-obfuscator" "\$LIB/wg-obfuscator"

mkdir -p "\$CONF_DIR" /etc/wireguard; chmod 700 "\$CONF_DIR" /etc/wireguard
cat > "\$CONF_DIR/obfuscator.conf" <<'OBF_EOF'
EOF
    cat "$dir/obfuscator.conf"
    echo "OBF_EOF"
    echo "cat > \"/etc/wireguard/\$WG_IF.conf\" <<'WG_EOF'"
    cat "$dir/wg.conf"
    cat <<EOF
WG_EOF
chmod 600 "\$CONF_DIR/obfuscator.conf" "/etc/wireguard/\$WG_IF.conf"
# DNS в wg-quick требует resolvconf; ::/0 — включённого IPv6
command -v resolvconf >/dev/null || { sed -i '/^DNS = /d' "/etc/wireguard/\$WG_IF.conf"; echo "resolvconf нет — DNS остаётся системный"; }
if [[ "\$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == 1 ]]; then
  sed -i 's#, ::/0##' "/etc/wireguard/\$WG_IF.conf"
fi

cat > "/etc/systemd/system/\$UNIT" <<UNIT_EOF
[Unit]
Description=wg-obfuscator (клиент \$TAG)
After=network-online.target
Wants=network-online.target
Before=wg-quick@\$WG_IF.service

[Service]
ExecStart=\$LIB/wg-obfuscator -c \$CONF_DIR/obfuscator.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable --now "\$UNIT"
systemctl enable "wg-quick@\$WG_IF"
if ! systemctl restart "wg-quick@\$WG_IF"; then
  echo "WireGuard не поднялся: journalctl -u wg-quick@\$WG_IF -n 20"
  echo "Частая причина («File exists») — на устройстве уже поднят другой VPN на весь трафик."
  exit 1
fi
echo "Готово. Проверка: wg show \$WG_IF (строка latest handshake)"
EOF
  } | write_file "$dir/install-linux.sh" 700
}

wgobf_show_bundle() {
  local name="$1" dir="$WGOBF_CLIENTS/$1"
  [[ -f "$dir/wg.conf" ]] || { err "Комплект $name не найден ($dir)"; return 1; }
  # Комплекты старых версий — без файлов Phobos/Keenetic
  [[ -f "$dir/phobos-link.txt" && -f "$dir/keenetic.txt" ]] || wgobf_write_bundle "$name"
  echo ""
  hdr "Клиент $name — $dir"
  echo -e "${Y}# obfuscator.conf${N}"; cat "$dir/obfuscator.conf"
  echo -e "${Y}# wg.conf${N}"; cat "$dir/wg.conf"
  if [[ -f "$dir/wg-direct.conf" ]]; then
    echo -e "${Y}# wg-direct.conf (без обфускатора, виден DPI)${N}"
    share_config "$dir/wg-direct.conf" qr
  fi
  echo -e "${Y}# Keenetic, AWG Manager → «Phobos» (одной вставкой):${N}"
  cat "$dir/phobos-link.txt"
  echo -e "  ${D}Вкладка «ClusterM» и подробности — $dir/keenetic.txt${N}"
  info "Linux: install-linux.sh на устройство и sudo bash install-linux.sh"
  info "Забрать папку: scp -r root@$(wgobf_get ENDPOINT):$dir ."
}

# ── Клиенты ───────────────────────────────────────────────
wgobf_add_client() {
  local name="$1" base i ip="" priv pub psk bak
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя: латиница, цифры, _ и -, до 32 символов"; return 1; }
  wgobf_clients | grep -qxF "$name" && { err "Клиент $name уже есть"; return 1; }
  base=$(wgobf_get NET); base="${base%.*}"
  for i in $(seq 2 254); do
    grep -qE "^AllowedIPs = ${base//./\\.}\.$i/32$" "$WGOBF_WG_CONF" || { ip="$base.$i"; break; }
  done
  [[ -n "$ip" ]] || { err "В подсети $(wgobf_get NET) нет свободных адресов"; return 1; }
  priv=$(wg genkey); pub=$(wg pubkey <<< "$priv"); psk=$(wg genpsk)
  mktmp bak || return 1
  cp -a "$WGOBF_WG_CONF" "$bak"
  printf '\n[Peer]\n# client=%s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
    "$name" "$pub" "$psk" "$ip" >> "$WGOBF_WG_CONF"
  if ! _wgobf_sync; then
    cp -a "$bak" "$WGOBF_WG_CONF"
    err "Клиент не применился — конфиг возвращён"
    return 1
  fi
  wgobf_write_bundle "$name" "$priv" "$ip/32" "$psk" || return 1
  ok "Клиент $name: $ip"
  log_info "wgobf: добавлен клиент $name ($ip)"
}

wgobf_delete_client() {
  local name="$1" bak
  wgobf_clients | grep -qxF "$name" || { err "Клиента $name нет"; return 1; }
  mktmp bak || return 1
  cp -a "$WGOBF_WG_CONF" "$bak"
  awk -v target="# client=$name" '
    function flush() { if (blk != "" && !drop) printf "%s", blk; blk = ""; drop = 0 }
    /^\[/ { flush() }
    { blk = blk $0 "\n"; if ($0 == target) drop = 1 }
    END { flush() }
  ' "$bak" | cat -s | write_file "$WGOBF_WG_CONF" 600
  if ! _wgobf_sync; then
    cp -a "$bak" "$WGOBF_WG_CONF"
    err "Удаление не применилось — конфиг возвращён"
    return 1
  fi
  rm -rf "${WGOBF_CLIENTS:?}/$name"
  ok "Клиент $name удалён"
  log_info "wgobf: удалён клиент $name"
}

wgobf_list_clients() {
  local names=() dump now i name pub ip hs
  mapfile -t names < <(wgobf_clients)
  (( ${#names[@]} )) || { info "Клиентов нет"; return 1; }
  dump=$(wg show "$WGOBF_IF" dump 2>/dev/null | tail -n +2 || true)
  now=$(date +%s)
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    pub=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^PublicKey = / {print $3; exit}' "$WGOBF_WG_CONF")
    ip=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^AllowedIPs = / {print $3; exit}' "$WGOBF_WG_CONF")
    hs=$(awk -v k="$pub" '$1 == k {print $5; exit}' <<< "$dump")
    if [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 )); then hs="$(fmt_duration $((now - hs))) назад"; else hs="—"; fi
    echo -e "  ${C}$((i + 1)))${N} $name ${D}${ip%/32}${N}  рукопожатие: $hs"
  done
}

_wgobf_pick_client() {  # → CHOSEN
  local names=() c
  mapfile -t names < <(wgobf_clients)
  wgobf_list_clients || return 1
  read_choice c "${C}  Номер клиента (0 — отмена): ${N}" 0 "${#names[@]}" 0
  (( c )) || return 1
  CHOSEN="${names[$((c - 1))]}"
}

_wgobf_regen_bundles() {  # → число перевыпущенных
  local n=0 name
  while IFS= read -r name; do
    [[ -n "$name" ]] && wgobf_write_bundle "$name" && n=$((n + 1))
  done < <(wgobf_clients)
  echo "$n"
}

# Ключ обфускатора общий для сервера и всех клиентов: после смены ВСЕ
# отключаются, пока не получат новый комплект. Ключи WireGuard не меняются.
wgobf_rotate_key() {
  local old new n
  old=$(wgobf_get KEY); new=$(py rand-key 32)
  [[ -n "$new" && "$new" != "$old" ]] || { err "Не удалось сгенерировать ключ"; return 1; }
  wgobf_set KEY "$new"
  _wgobf_write_service_files
  if ! systemctl restart "$WGOBF_UNIT" 2>/dev/null; then
    wgobf_set KEY "$old"; _wgobf_write_service_files
    systemctl restart "$WGOBF_UNIT" &>/dev/null || true
    err "Обфускатор не перезапустился — ключ оставлен прежним"
    return 1
  fi
  n=$(_wgobf_regen_bundles)
  ok "Ключ заменён, комплекты перевыпущены: $n"
  warn "Старые конфиги клиентов больше не работают — раздай новые"
  log_info "wgobf: ключ обфускатора заменён"
}

# ── Установка / удаление ──────────────────────────────────
wgobf_install() {
  local ep port c mask clean dns first
  wgobf_installed && { warn "Уже установлен"; return 0; }
  echo -e "  ${D}Отдельный WireGuard ($WGOBF_IF) за wg-obfuscator $WGOBF_VERSION. AWG не затрагивается.${N}"
  echo -e "  ${D}Клиентам нужен обфускатор на устройстве: роутер, Linux, Windows, macOS.${N}"
  ep=$(public_ip_cached)
  if [[ -z "$ep" ]] || ip_is_private "$ep"; then
    while true; do
      read_line ep "${C}  Публичный IPv4 сервера: ${N}"
      [[ -n "$ep" ]] || return 0
      valid_ip "$ep" && break
      warn "Нужен IPv4 (обфускатор не умеет IPv6)"
    done
  fi
  while true; do
    read_line port "${C}  UDP-порт обфускатора (Enter — случайный): ${N}"
    [[ -z "$port" ]] && break
    valid_port "$port" && (( port >= 1024 )) || { warn "Порт 1024-65535"; continue; }
    udp_port_busy "$port" && { warn "UDP $port занят (сокет, AWG или каскад)"; continue; }
    break
  done
  echo -e "  ${C}1)${N} STUN ${D}— под видеозвонок${N} ${C}(рекомендуется)${N}"
  echo -e "  ${C}2)${N} Без маскировки ${D}— только XOR${N}"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 2 ]]; then mask=NONE; else mask=STUN; fi
  echo -e "  ${D}Клиенты без обфускатора (iOS) могут подключаться обычным WireGuard —${N}"
  echo -e "  ${D}но такой трафик DPI видит как WireGuard.${N}"
  clean=0; ask_yes "  Пускать клиентов без обфускатора? [y/N]: " n && clean=1
  echo -e "  ${C}1)${N} Cloudflare"
  echo -e "  ${C}2)${N} Google"
  echo -e "  ${C}3)${N} Quad9"
  read_choice c "${C}  DNS клиентов [1-3] (Enter = 1): ${N}" 1 3 1
  case "$c" in 2) dns="8.8.8.8, 8.8.4.4" ;; 3) dns="9.9.9.9, 149.112.112.112" ;; *) dns="1.1.1.1, 1.0.0.1" ;; esac
  read_line first "${C}  Имя первого клиента (Enter = client1): ${N}"
  first="${first// /}"
  wgobf_install_opts "endpoint=$ep" ${port:+"port=$port"} "masking=$mask" "clean=$clean" "dns=$dns" "client=${first:-client1}" \
    && wgobf_show_bundle "${first:-client1}"
  return 0
}

# Установка без вопросов: wgobf_install_opts ключ=значение...
#   port= (случайный)  masking=STUN|NONE  clean=0|1  dns="1.1.1.1, 1.0.0.1"
#   endpoint=публичный IPv4  client=имя первого клиента (пусто — без клиента)
wgobf_install_opts() {
  local kv k v ep="" port="" mask=STUN clean=0 dns="1.1.1.1, 1.0.0.1" first="" wg_port net priv
  wgobf_installed && { err "Уже установлен"; return 1; }
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      port) valid_port "$v" && (( v >= 1024 )) || { err "port: 1024-65535"; return 1; }
            udp_port_busy "$v" && { err "UDP $v занят"; return 1; }; port="$v" ;;
      masking) [[ "$v" =~ ^(STUN|NONE)$ ]] || { err "masking: STUN | NONE"; return 1; }; mask="$v" ;;
      clean) [[ "$v" =~ ^[01]$ ]] || { err "clean: 0 | 1"; return 1; }; clean="$v" ;;
      dns) valid_dns_list "$v" || { err "dns: IPv4 через запятую"; return 1; }; dns="$v" ;;
      endpoint) valid_ip "$v" || { err "endpoint: IPv4"; return 1; }; ep="$v" ;;
      client) [[ -z "$v" || "$v" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя клиента недопустимо"; return 1; }; first="$v" ;;
      *) err "Неизвестный параметр: $k"; return 1 ;;
    esac
  done
  [[ -n "$ep" ]] || ep=$(public_ip_cached)
  valid_ip "$ep" && ! ip_is_private "$ep" || { err "Публичный IPv4 не определился — задай endpoint="; return 1; }
  [[ -n "$port" ]] || port=$(random_free_udp_port) || { err "Нет свободного порта"; return 1; }
  _wgobf_prepare || return 1
  wg_port=$(random_free_udp_port "$port") || { err "Нет свободного порта для WireGuard"; return 1; }
  net=$(taken_networks | py pick-net) || { err "Нет свободной /24"; return 1; }
  priv=$(wg genkey)
  rm -f "$WGOBF_STATE"
  wgobf_set PORT "$port"; wgobf_set WG_PORT "$wg_port"; wgobf_set KEY "$(py rand-key 32)"
  wgobf_set MASKING "$mask"; wgobf_set ALLOW_CLEAN "$clean"; wgobf_set NET "$net"
  wgobf_set MTU "$WGOBF_MTU"; wgobf_set DNS "$dns"; wgobf_set ENDPOINT "$ep"
  wgobf_set SERVER_PUB "$(wg pubkey <<< "$priv")"
  write_file "$WGOBF_WG_CONF" 600 <<EOF
# AWG Toolza — WG + обфускатор. Снаружи порт закрыт, вход — через
# wg-obfuscator на $port/udp. Клиенты — блоки [Peer] с «# client=имя».
[Interface]
PrivateKey = $priv
Address = ${net%.*}.1/24
ListenPort = $wg_port
MTU = $WGOBF_MTU
PostUp = $WGOBF_FW up
PostDown = $WGOBF_FW down
EOF
  if ! wgobf_restart; then
    err "Запуск не удался — откатываю установку"
    _wgobf_teardown keep
    return 1
  fi
  ufw_allow "$port/udp" "$WGOBF_TAG"
  ok "WG + обфускатор запущен: вход $ep:$port/udp, подсеть $net"
  log_info "wgobf: установлен (порт $port, wg $wg_port, сеть $net, маскировка $mask)"
  [[ -z "$first" ]] || wgobf_add_client "$first"
}

_wgobf_teardown() {  # keep|drop — клиентские комплекты
  local port
  port=$(wgobf_get PORT)
  systemctl disable --now "$WGOBF_UNIT" "wg-quick@$WGOBF_IF" &>/dev/null || true
  ip link del dev "$WGOBF_IF" &>/dev/null || true
  wgobf_fw_run down
  [[ -n "$port" ]] && ufw_delete_matching "$WGOBF_TAG"
  remove_unit "$WGOBF_UNIT"
  rm -f "$WGOBF_WG_CONF" "$WGOBF_BIN" "$WGOBF_FW"
  rmdir "$WGOBF_LIB" 2>/dev/null || true
  rm -rf "$WGOBF_DIR"
  [[ "${1:-keep}" == drop ]] && rm -rf "$WGOBF_CLIENTS"
  return 0
}

# $1 = quiet — без вопроса (из полного удаления).
wgobf_remove() {
  local arch items=()
  wgobf_installed || { info "WG + обфускатор не установлен"; return 0; }
  if [[ "${1:-}" != quiet ]]; then
    warn "Будут удалены $WGOBF_IF, обфускатор, их правила и все клиенты режима. AWG не затрагивается."
    read_confirm "${R}  Подтверди удаление (введи yes): ${N}" || return 0
  fi
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  arch="$BACKUP_DIR/auto_wgobf_remove_$(date +%Y%m%d_%H%M%S).tar.gz"
  items=("$WGOBF_DIR" "$WGOBF_WG_CONF")
  [[ -d "$WGOBF_CLIENTS" ]] && items+=("$WGOBF_CLIENTS")
  tar -czf "$arch" "${items[@]}" 2>/dev/null && chmod 600 "$arch" && info "Архив на всякий случай: $arch"
  _wgobf_teardown drop
  ok "WG + обфускатор удалён"
  log_info "wgobf: удалён"
}

# Хуки wgobf0 — ровно «$WGOBF_FW up/down». Конфиг из бэкапа мог прийти
# чужой: прочее убирается, о командах не из Тулзы — предупреждение.
_wgobf_hooks_reset() {
  local bad
  bad=$(py conf-hooks "$WGOBF_WG_CONF" check "$WGOBF_FW up" "$WGOBF_FW down" 2>/dev/null) || true
  if [[ -n "$bad" ]]; then
    warn "В $WGOBF_IF.conf из бэкапа были чужие команды — заменены правилами Тулзы:"
    sed 's/^/    /; s/\t/ = /' <<< "$bad"
  fi
  sed -i -E '/^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=/Id' "$WGOBF_WG_CONF"
  # Заголовок секции — в канонический вид: awg-quick примет и « [interface]»
  # и CRLF, а вставка ниже ищет ровно «[Interface]» — иначе файрвол не встал бы
  sed -i -E 's/\r$//; s/^[[:space:]]*\[[[:space:]]*interface[[:space:]]*\][[:space:]]*$/[Interface]/I' "$WGOBF_WG_CONF"
  sed -i "0,/^\[Interface\]/s|^\[Interface\]|[Interface]\nPostUp = $WGOBF_FW up\nPostDown = $WGOBF_FW down|" "$WGOBF_WG_CONF"
  grep -qxF "PostUp = $WGOBF_FW up" "$WGOBF_WG_CONF" || { err "В $WGOBF_IF.conf из бэкапа нет секции [Interface]"; return 1; }
}

# Из папки бэкапа (<бэкап>/wgobf): ключи, настройки и клиенты — из бэкапа,
# служебные файлы — заново текущим кодом.
wgobf_restore() {
  local src="$1" port
  _wgobf_prepare || return 1
  wgobf_installed && _wgobf_teardown drop
  mkdir -p "$WGOBF_DIR" && chmod 700 "$WGOBF_DIR"
  # Из каталога настроек — только state: конфиг обфускатора и скрипт
  # файрвола wgobf_restart пишет из него заново.
  [[ -f "$src/etc/${WGOBF_STATE##*/}" ]] || { err "В бэкапе нет настроек обфускатора"; return 1; }
  install -m 600 "$src/etc/${WGOBF_STATE##*/}" "$WGOBF_STATE"
  install -m 600 "$src/$WGOBF_IF.conf" "$WGOBF_WG_CONF"
  # Хуки wgobf0 пишет только Тулза: чужие команды из бэкапа — прочь, свои — на место
  _wgobf_hooks_reset || return 1
  if [[ -d "$src/clients" ]]; then
    mkdir -p "$WGOBF_CLIENTS" && cp -a "$src/clients/." "$WGOBF_CLIENTS/" && chmod 700 "$WGOBF_CLIENTS"
  fi
  port=$(wgobf_get PORT)
  udp_listening "$port" && warn "UDP $port сейчас занят — обфускатор может не подняться"
  wgobf_restart || { err "WG + обфускатор восстановлен, но не запустился"; return 1; }
  ufw_allow "$port/udp" "$WGOBF_TAG"
  ok "WG + обфускатор восстановлен"
}

# ── Меню ──────────────────────────────────────────────────
wgobf_status() {
  local s
  if ip link show "$WGOBF_IF" &>/dev/null; then s="${G}● поднят${N}"; else s="${R}○ лежит${N}"; fi
  echo -e "  $WGOBF_IF         : $s"
  if unit_active "$WGOBF_UNIT"; then s="${G}● работает${N}"; else s="${R}○ не работает${N}"; fi
  echo -e "  wg-obfuscator  : $s ${D}($(wgobf_bin_version))${N}"
  echo -e "  Вход           : ${W}$(wgobf_get ENDPOINT):$(wgobf_get PORT)/udp${N}"
  echo -e "  Маскировка     : ${W}$(wgobf_get MASKING)${N} ${D}(у клиентов; сервер понимает любую)${N}"
  echo -e "  Без обфускатора: $([[ "$(wgobf_get ALLOW_CLEAN)" == 1 ]] && echo -e "${Y}да${N}" || echo нет)"
  echo -e "  Подсеть        : $(wgobf_get NET), MTU $(wgobf_get MTU), WireGuard на $(wgobf_get WG_PORT) ${D}(снаружи закрыт)${N}"
  echo -e "  Клиентов       : $(wgobf_clients | grep -c . || true)"
}

wgobf_settings() {
  local c mask clean
  mask=$(wgobf_get MASKING); clean=$(wgobf_get ALLOW_CLEAN)
  echo -e "  ${C}1)${N} Маскировка клиентов: ${W}$mask${N} → $([[ "$mask" == STUN ]] && echo NONE || echo STUN)"
  echo -e "  ${C}2)${N} Клиенты без обфускатора: ${W}$([[ "$clean" == 1 ]] && echo да || echo нет)${N} → $([[ "$clean" == 1 ]] && echo нет || echo да)"
  echo -e "  ${C}3)${N} Сменить ключ обфускатора"
  read_choice c "${C}  Выбор (0 — назад): ${N}" 0 3 0
  case "$c" in
    1) wgobf_set_masking "$([[ "$mask" == STUN ]] && echo NONE || echo STUN)" ;;
    2) wgobf_set_clean "$([[ "$clean" == 1 ]] && echo 0 || echo 1)" ;;
    3) warn "После смены ключа ВСЕ клиенты отключатся, пока не получат новый комплект"
       read_confirm "${R}  Сменить ключ? (введи yes): ${N}" && { wgobf_rotate_key || true; } ;;
  esac
  return 0
}

# Маскировка у клиентов: STUN|NONE. Сервер в режиме AUTO понимает обе.
wgobf_set_masking() {
  [[ "$1" =~ ^(STUN|NONE)$ ]] || { err "Маскировка: STUN | NONE"; return 1; }
  wgobf_set MASKING "$1"
  ok "Маскировка $1, комплекты перевыпущены: $(_wgobf_regen_bundles)"
  info "Старые комплекты продолжат работать"
}

wgobf_set_clean() {  # 1 — пускать клиентов без обфускатора
  [[ "$1" =~ ^[01]$ ]] || { err "0 | 1"; return 1; }
  wgobf_set ALLOW_CLEAN "$1"
  _wgobf_write_service_files && systemctl restart "$WGOBF_UNIT" &>/dev/null
  ok "Клиенты без обфускатора: $([[ "$1" == 1 ]] && echo да || echo нет), комплекты перевыпущены: $(_wgobf_regen_bundles)"
}

do_wgobf_menu() {
  local c name
  while true; do
    echo ""
    hdr "WG + обфускатор (wg-obfuscator $WGOBF_VERSION)"
    if ! wgobf_installed; then
      echo -e "  ${D}Отдельный WireGuard за обфускатором, AWG не трогает.${N}"
      echo -e "  ${C}1)${N} Установить"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-1]: ${N}" 0 1 0
      (( c )) || return 0
      wgobf_install || true
      pause
      continue
    fi
    if wgobf_running; then echo -e "  ${G}● работает${N}  ${D}вход $(wgobf_get ENDPOINT):$(wgobf_get PORT)/udp${N}"
    else echo -e "  ${R}○ не работает${N} ${D}— «Перезапустить»${N}"; fi
    echo ""
    echo -e "  ${C}1)${N} Добавить клиента"
    echo -e "  ${C}2)${N} Список"
    echo -e "  ${C}3)${N} Комплект клиента"
    echo -e "  ${C}4)${N} Удалить клиента"
    echo -e "  ${C}5)${N} Статус и журнал"
    echo -e "  ${C}6)${N} Перезапустить"
    echo -e "  ${C}7)${N} Настройки"
    echo -e "  ${R}8)${N} Удалить WG + обфускатор"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-8]: ${N}" 0 8 0
    case "$c" in
      1) read_line name "${C}  Имя клиента: ${N}"
         name="${name// /}"
         [[ -n "$name" ]] && { wgobf_add_client "$name" && wgobf_show_bundle "$name" || true; } ;;
      2) wgobf_list_clients || true ;;
      3) _wgobf_pick_client && { wgobf_show_bundle "$CHOSEN" || true; } ;;
      4) _wgobf_pick_client && read_confirm "${R}  Удалить клиента $CHOSEN? (введи yes): ${N}" \
           && { wgobf_delete_client "$CHOSEN" || true; } ;;
      5) wgobf_status; journalctl -u "$WGOBF_UNIT" -n 12 --no-pager 2>/dev/null | sed 's/^/  /' || true ;;
      6) wgobf_restart && ok "Перезапущено" || true ;;
      7) wgobf_settings || true ;;
      8) wgobf_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# awg2 --wgobf add ИМЯ | del ИМЯ | bundle ИМЯ | rotate-key | restart
wgobf_cli() {
  local cmd="${1:-}" name="${2:-}"
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  case "$cmd" in
    add|del|bundle) [[ -n "$name" ]] || { err "Использование: awg2 --wgobf $cmd ИМЯ"; return 1; } ;;
  esac
  case "$cmd" in
    add) wgobf_add_client "$name" ;;
    del) wgobf_delete_client "$name" ;;
    bundle) wgobf_clients | grep -qxF "$name" || { err "Клиента $name нет"; return 1; }
            wgobf_write_bundle "$name" && ok "$WGOBF_CLIENTS/$name" ;;
    rotate-key) wgobf_rotate_key ;;
    restart) wgobf_restart && ok "Перезапущено" ;;
    *) err "Команда: add ИМЯ | del ИМЯ | bundle ИМЯ | rotate-key | restart"; return 1 ;;
  esac
}

# ═════ cert ═════
# HTTPS-сертификат сервера — Let's Encrypt через acme.sh: на IP (профиль
# shortlived, ~6 дней, продление каждые 3 дня) или на домен (90 дней).
#
# Нужен Mini App бота: Telegram открывает её только по HTTPS с настоящим
# сертификатом. Владение адресом проверяется по http-01: на время выпуска и
# продления acme.sh сам слушает 80-й порт (standalone), поэтому порт должен
# быть свободен и открыт снаружи. Для IP другого способа нет — DNS-проверка
# у Let's Encrypt только для доменов.
#
# Файлы для потребителей — $CERT_FULL и $CERT_KEY: acme.sh кладёт туда
# сертификат при выпуске и после каждого продления (таймер $CERT_TIMER).
#
# Порт 80 занят (Caddy, nginx…) — два выхода. Готовый сертификат сервера:
# его уже выпустила та программа, $CERT_FULL и $CERT_KEY становятся ссылками
# на её файлы, а продлевает она сама (kind=external). Или выпуск с паузой:
# acme.sh останавливает занявшую порт службу на секунды выпуска и каждого
# продления (хуки он запоминает сам).

cert_installed() { [[ -s "$CERT_FULL" && -s "$CERT_KEY" ]]; }
cert_get() { sed -n "s/^$1=//p" "$CERT_STATE" 2>/dev/null | head -1; }

# Срок действия (unixtime) или пусто.
cert_expires() {
  local end
  end=$(openssl x509 -enddate -noout -in "$CERT_FULL" 2>/dev/null) || return 0
  date -d "${end#notAfter=}" +%s 2>/dev/null || true
}

# Кто слушает TCP 80 — пусто, если никто.
cert_port80_holder() {
  ss -ltnpH 'sport = :80' 2>/dev/null | grep -oE 'users:\(\("[^"]+' | head -1 | sed 's/.*"//' || true
}

# Служба systemd, которая держит TCP 80, — её можно останавливать на время выпуска.
cert_port80_unit() {
  local pid unit
  pid=$(ss -ltnpH 'sport = :80' 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  unit=$(grep -oE '[A-Za-z0-9@._-]+\.service' "/proc/$pid/cgroup" 2>/dev/null | tail -1)
  [[ "$unit" =~ ^[A-Za-z0-9@._-]+\.service$ ]] && echo "$unit"
  return 0
}

# Готовые сертификаты сервера: «имя<TAB>источник<TAB>сертификат<TAB>ключ<TAB>до».
cert_find() {
  py cert-find "$(public_ip_cached)" "${CERT_FIND_ROOT:-/}" "$ACME_HOME" "$CERT_DIR"
}

# cert_use СЕРТИФИКАТ — взять готовый: только из найденных, не любой путь.
cert_use() {
  local want="$1" name src crt key exp old
  while IFS=$'\t' read -r name src crt key exp; do
    [[ "$crt" == "$want" ]] && break
    crt=""
  done < <(cert_find)
  [[ -n "$crt" ]] || { err "Такого готового сертификата на сервере нет"; return 1; }
  old=$(cert_get name)
  if [[ "$(cert_get kind)" =~ ^(ip|domain)$ && -n "$old" && -x "$ACME_DIR/acme.sh" ]]; then
    acme --remove -d "$old" --ecc &>/dev/null
  fi
  remove_unit "$CERT_TIMER" "$CERT_SERVICE"
  ufw_delete_matching "$CERT_TAG"
  mkdir -p "$CERT_DIR" && chmod 700 "$CERT_DIR"
  ln -sfn "$crt" "$CERT_FULL" && ln -sfn "$key" "$CERT_KEY" || { err "Не удалось сослаться на $crt"; return 1; }
  printf 'kind=external\nname=%s\nsource=%s\n' "$name" "$src" | write_file "$CERT_STATE" 600
  log_info "сертификат: готовый $src $name"
  ok "Сертификат $src на $name до $(date -d "@$exp" '+%d.%m.%Y'), продлевает $src"
}

acme() { "$ACME_DIR/acme.sh" --home "$ACME_HOME" --config-home "$ACME_HOME" "$@"; }

# acme.sh — последний тег с GitHub (или зеркал), без установки в систему:
# скрипт запускается из своего каталога, всё состояние — в $ACME_HOME.
acme_install() {
  [[ -x "$ACME_DIR/acme.sh" ]] && return 0
  local tag ref tmp
  mktmp tmp -d || return 1
  tag=$(gh_latest_tag acmesh-official/acme.sh || true)
  ref=${tag:+tags/$tag}
  gh_fetch "https://github.com/acmesh-official/acme.sh/archive/refs/${ref:-heads/master}.tar.gz" "$tmp/a.tgz" 100000 any \
    || { err "acme.sh не скачался ни напрямую, ни через зеркала"; return 1; }
  [[ "$(head -c2 "$tmp/a.tgz" | od -An -tx1 | tr -d ' \n')" == 1f8b ]] \
    || { err "Вместо архива acme.sh пришло что-то другое"; return 1; }
  mkdir -p "$ACME_DIR" "$ACME_HOME" && chmod 700 "$ACME_HOME"
  tar -xzf "$tmp/a.tgz" -C "$ACME_DIR" --strip-components=1 || { err "Архив acme.sh не распаковался"; return 1; }
  chmod 755 "$ACME_DIR/acme.sh"
  # standalone-режиму нужен socat или python3; socat надёжнее
  command -v socat &>/dev/null || apt_install socat || true
  ok "acme.sh ${tag:-master}"
}

cert_timer_install() {
  write_unit "$CERT_SERVICE" <<UNIT
[Unit]
Description=AWG Toolza — продление HTTPS-сертификата (acme.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ACME_DIR/acme.sh --cron --home $ACME_HOME --config-home $ACME_HOME
UNIT
  write_unit "$CERT_TIMER" <<'UNIT'
[Unit]
Description=AWG Toolza — таймер продления HTTPS-сертификата

[Timer]
OnCalendar=*-*-* 04,16:20:00
RandomizedDelaySec=45min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl enable --now "$CERT_TIMER" &>/dev/null || warn "Таймер продления не запустился: systemctl status $CERT_TIMER"
}

# cert_issue ip [pause] | domain ИМЯ [pause] — pause: если порт 80 занят
# службой, она останавливается на время выпуска и каждого продления.
cert_issue() {
  local kind="${1:-}" name="${2:-}" args=() ip pub holder unit pause="" rc=0 old out n
  [[ "${*: -1}" == pause ]] && pause=1
  [[ "$kind" == ip ]] && name=""
  case "$kind" in
    ip)
      name=$(public_ip)
      valid_ip "$name" && ! ip_is_private "$name" || { err "У сервера нет публичного IPv4 — сертификат на IP не выпустить"; return 1; }
      # Сертификаты на IP Let's Encrypt выдаёт только с профилем shortlived
      args=(--cert-profile shortlived --days 3) ;;
    domain)
      name="${name,,}"
      valid_domain "$name" || { err "Нужен домен вида panel.example.com"; return 1; }
      ip=$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR == 1 {print $1}')
      pub=$(public_ip)
      [[ -n "$ip" ]] || { err "Домен $name не резолвится — проверь A-запись"; return 1; }
      [[ "$ip" == "$pub" ]] || { err "A-запись $name ведёт на $ip, а IP сервера — $pub: Let's Encrypt не проверит владение"; return 1; } ;;
    *) err "Сертификат: ip | domain ИМЯ"; return 1 ;;
  esac
  holder=$(cert_port80_holder)
  if [[ -n "$holder" ]]; then
    unit=$(cert_port80_unit)
    if [[ -n "$pause" && -n "$unit" ]]; then
      args+=(--pre-hook "systemctl stop $unit" --post-hook "systemctl start $unit")
      warn "Порт 80 занят $unit — остановлю его на время выпуска (несколько секунд) и так же при каждом продлении"
    else
      err "Порт 80 занят ($holder): acme.sh слушает его сам на время выпуска и продления"
      n=$(cert_find | grep -c . || true)
      (( n > 0 )) && info "На сервере есть готовые сертификаты ($n) — их можно взять без порта 80"
      [[ -n "$unit" ]] && info "Или выпуск с паузой $unit: служба останавливается на секунды выпуска и продления"
      return 1
    fi
  fi
  acme_install || return 1
  ufw_allow 80/tcp "$CERT_TAG"
  info "Let's Encrypt: сертификат на $name…"
  mkdir -p "$ACME_HOME"
  out=$(acme --issue --server letsencrypt -d "$name" --standalone --httpport 80 --keylength ec-256 "${args[@]}" 2>&1) || rc=$?
  # Без самого сертификата и путей к файлам acme.sh — только ход выпуска
  printf '%s\n' "$out" | sed -e 's/^\[[^]]*\] //' -e '/-----BEGIN/,/-----END/d' \
    | grep -vE '^$|^(Your cert|The intermediate|And the full-chain|ARI suggestedWindow|It is later than|[0-9]{4}-[0-9]{2}-[0-9]{2}T)' \
    | tail -n 8
  # 2 — сертификат уже выпущен и продлевать его рано
  if (( rc != 0 && rc != 2 )); then
    err "Let's Encrypt не выдал сертификат — проверь, что порт 80 открыт снаружи (и в файрволе хостера)"
    return 1
  fi
  mkdir -p "$CERT_DIR" && chmod 700 "$CERT_DIR"
  # Был готовый сертификат — здесь ссылки на чужие файлы: acme.sh записал бы
  # прямо в них и затёр сертификат той программы
  rm -f "$CERT_FULL" "$CERT_KEY"
  acme --install-cert -d "$name" --ecc --key-file "$CERT_KEY" --fullchain-file "$CERT_FULL" &>/dev/null
  cert_installed || { err "Сертификат выпущен, но не скопирован в $CERT_DIR"; return 1; }
  chmod 600 "$CERT_KEY"
  # Прежний адрес больше не продлеваем — иначе таймер дёргал бы 80-й порт зря
  old=$(cert_get name)
  [[ "$(cert_get kind)" != external && -n "$old" && "$old" != "$name" ]] && acme --remove -d "$old" --ecc &>/dev/null
  printf 'kind=%s\nname=%s\n' "$kind" "$name" | write_file "$CERT_STATE" 600
  cert_timer_install
  log_info "сертификат: $kind $name"
  ok "Сертификат на $name до $(date -d "@$(cert_expires)" '+%d.%m.%Y %H:%M'), продлевается сам"
}

cert_remove() {
  local name
  name=$(cert_get name)
  # Готовый сертификат чужой — убираем только свои ссылки на него
  [[ "$(cert_get kind)" != external && -n "$name" && -x "$ACME_DIR/acme.sh" ]] && acme --remove -d "$name" --ecc &>/dev/null
  remove_unit "$CERT_TIMER" "$CERT_SERVICE"
  rm -rf "$CERT_DIR" "$CERT_STATE"
  ufw_delete_matching "$CERT_TAG"
  log_info "сертификат удалён"
  ok "Сертификат удалён"
}

cert_state_line() {
  local exp k
  cert_installed || { echo -e "${D}нет${N}"; return; }
  exp=$(cert_expires)
  case "$(cert_get kind)" in
    ip) k=IP ;; external) k="готовый, $(cert_get source)" ;; *) k=домен ;;
  esac
  echo -e "${W}$(cert_get name)${N} ${D}($k, до $(date -d "@${exp:-0}" '+%d.%m %H:%M'))${N}"
}

# ═════ backup ═════
# Бэкапы в ~/awg_backup (домашний каталог того, кто запустил sudo):
#   awg2_backup_<время>/        — полный: сервер, клиенты, WARP, WG + обфускатор,
#                                 настройки туннелей (tunnels.tar.gz);
#   auto_<причина>_<время>.tar.gz — перед опасными операциями: сервер и клиенты.

# Настройки туннелей: сами туннели при восстановлении не включаются.
_BACKUP_TUNNEL_PATHS=()
_backup_tunnel_paths() {
  local p
  _BACKUP_TUNNEL_PATHS=()
  for p in "$XRAY_DIR" "$EXITS_STATE" "$EXITS_PEERS" "$CASCADE_RULES" "$T2S_CONF" "$DNS_PROXY_CONF" \
           "$EXITS_DIR"/awg-exit-*.conf; do
    [[ -e "$p" ]] && _BACKUP_TUNNEL_PATHS+=("${p#/}")
  done
  return 0
}

auto_backup() {  # причина
  local files=() arch f
  [[ -f "$SERVER_CONF" ]] || return 0
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  arch="$BACKUP_DIR/auto_${1:-operation}_$(date +%Y%m%d_%H%M%S).tar.gz"
  files=("${SERVER_CONF#/}")
  while IFS= read -r f; do files+=("${f#/}"); done < <(client_files)
  tar -czf "$arch" -C / "${files[@]}" 2>/dev/null || return 1
  chmod 600 "$arch"
  info "Авто-бэкап: ${arch##*/}"
}

do_backup() { backup_create; }

# Полный бэкап → каталог в BACKUP_PATH; с «archive» ещё и .tar.gz рядом (для бота).
# «archive auto [N]» — автобэкап бота по расписанию: только архив
# awg2_backup_<время>_auto.tar.gz, из таких хранятся N последних (по умолчанию 7).
BACKUP_PATH=""
backup_create() {
  local ts dir n=0 f auto=0 keep=7
  if [[ "${2:-}" == auto ]]; then
    auto=1
    [[ "${3:-}" =~ ^[0-9]{1,3}$ ]] && (( 10#$3 >= 1 )) && keep=$((10#$3))
  fi
  # Имя — по секундам: второй бэкап в ту же секунду писал бы в тот же архив
  while :; do
    ts=$(date +%Y%m%d_%H%M%S)
    dir="$BACKUP_DIR/awg2_backup_$ts"
    (( auto )) && dir+="_auto"
    [[ -e "$dir" || -e "$dir.tar.gz" ]] || break
    sleep 1
  done
  mkdir -p "$dir" && chmod 700 "$BACKUP_DIR" "$dir"
  if [[ -f "$SERVER_CONF" ]]; then cp -a "$SERVER_CONF" "$dir/awg0.conf"; n=$((n + 1)); ok "Сервер: awg0.conf"
  else warn "Серверного конфига нет"; fi
  while IFS= read -r f; do cp -a "$f" "$dir/"; n=$((n + 1)); done < <(client_files)
  (( n > 1 )) && ok "Клиентов: $((n - 1))"
  iface_up && awg show "$AWG_IF" > "$dir/awg_show_dump.txt" 2>/dev/null
  # WARP: перерегистрация упирается в лимиты Cloudflare — аккаунт бережём
  if [[ -d "$WARP_DIR" ]]; then
    mkdir -p "$dir/warp" && cp -a "$WARP_DIR" "$dir/warp/wgcf" && ok "WARP (wg): аккаунт"
    [[ -f "$WARP_CONF" ]] && cp -a "$WARP_CONF" "$dir/warp/warp0.conf"
  fi
  if [[ -f "$USQUE_CONF" ]]; then
    mkdir -p "$dir/warp/usque" && cp -a "$USQUE_CONF" "$dir/warp/usque/config.json" && ok "WARP (usque): регистрация"
  fi
  if wgobf_installed; then
    mkdir -p "$dir/wgobf"
    cp -a "$WGOBF_DIR" "$dir/wgobf/etc" && cp -a "$WGOBF_WG_CONF" "$dir/wgobf/$WGOBF_IF.conf" && ok "WG + обфускатор"
    [[ -d "$WGOBF_CLIENTS" ]] && cp -a "$WGOBF_CLIENTS" "$dir/wgobf/clients"
  fi
  _backup_tunnel_paths
  if (( ${#_BACKUP_TUNNEL_PATHS[@]} )); then
    tar -czf "$dir/tunnels.tar.gz" -C / "${_BACKUP_TUNNEL_PATHS[@]}" 2>/dev/null && ok "Настройки туннелей"
  fi
  [[ -f "$LOG_FILE" ]] && cp -a "$LOG_FILE" "$dir/awg-manager.log"
  {
    echo "timestamp=$ts"
    echo "server_conf=$SERVER_CONF"
    echo "backed_files=$n"
    echo "awg_version=$(server_proto 2>/dev/null)"
    echo "warp_backend=$(warp_backend)"
    echo "toolza=$VERSION"
    echo "hostname=$(hostname)"
  } > "$dir/backup_meta.txt"
  chmod -R go-rwx "$dir"
  BACKUP_PATH="$dir"
  if [[ "${1:-}" == archive ]]; then
    # Архив не записался (кончилось место) — обрезок не оставлять: в нём
    # приватные ключи, а среди автобэкапов он вытеснил бы целые при ротации
    if ! (umask 077 && tar -czf "$dir.tar.gz" -C "$BACKUP_DIR" "${dir##*/}"); then
      rm -f "$dir.tar.gz"
      (( auto )) && rm -rf "$dir"
      err "Архив бэкапа не записан — проверь место на диске: df -h $BACKUP_DIR"
      return 1
    fi
    chmod 600 "$dir.tar.gz"
    BACKUP_PATH="$dir.tar.gz"
  fi
  if (( auto )) && [[ "$BACKUP_PATH" == *.tar.gz ]]; then
    rm -rf "$dir"
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'awg2_backup_*_auto.tar.gz' -printf '%f\n' 2>/dev/null \
      | sort -r | tail -n +$((keep + 1)) | while IFS= read -r f; do rm -f "${BACKUP_DIR:?}/$f"; done
  fi
  success_box "Бэкап: $BACKUP_PATH"
  log_info "бэкап: $BACKUP_PATH"
}

_restore_list() {  # → строки «путь» (новые сверху)
  find "$BACKUP_DIR" -maxdepth 1 \( -type d -name 'awg2_backup_*' -o -type f -name '*.tar.gz' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

# Каталог с awg0.conf из любого бэкапа: каталог полного бэкапа, его архив,
# авто-бэкап (пути от корня) или архив бота прежних версий (awg0.conf + clients/).
RESTORE_SRC=""
_restore_prepare() {
  local src="$1" tmp d
  RESTORE_SRC=""
  if [[ -d "$src" ]]; then
    [[ -f "$src/awg0.conf" ]] || { err "В бэкапе нет awg0.conf"; return 1; }
    RESTORE_SRC="$src"; return 0
  fi
  [[ -f "$src" ]] || { err "Нет файла $src"; return 1; }
  mktmp tmp -d || return 1
  py safe-untar "$src" "$tmp/x" || { err "Архив не распаковался"; return 1; }
  if [[ -f "$tmp/x/awg0.conf" ]]; then d="$tmp/x"
  elif [[ -f "$tmp/x$SERVER_CONF" ]]; then d="$tmp/x"; cp -a "$tmp/x$SERVER_CONF" "$d/awg0.conf"
  else d=$(find "$tmp/x" -mindepth 2 -maxdepth 2 -name awg0.conf -printf '%h\n' | head -1); fi
  [[ -n "$d" && -f "$d/awg0.conf" ]] || { err "В архиве нет awg0.conf — это не бэкап awg2"; return 1; }
  # Клиенты у разных форматов лежат по-разному — собираем рядом с awg0.conf
  find "$tmp/x" -name '*_awg[23].conf' ! -path "$d/*_awg[23].conf" -exec cp -a {} "$d/" \;
  RESTORE_SRC="$d"
}

_restore_awg_files() {  # каталог бэкапа
  local src="$1" f keep
  install -D -m 600 "$src/awg0.conf" "$SERVER_CONF"
  # Конфиги клиентов, которых нет в восстановленном awg0.conf, иначе остаются
  # сиротами: видны в «Показать конфиг», занимают имя и попадают в архив.
  # Конфиги пиров, которые в awg0 есть, не трогаем: бэкап мог прийти без них.
  # awg0.conf не разобрался — не трогаем ничего: пустой список стёр бы всех.
  if keep=$(clients_tsv | cut -f1 | tr '\n' ' '); then
    keep=" $keep "
    for f in "$CLIENT_DIR"/*_awg[23].conf; do
      [[ -f "$f" && "$keep" != *" $(client_name_of "$f") "* ]] && rm -f "$f"
    done
  else
    warn "awg0.conf из бэкапа не разобран — конфиги клиентов на сервере не трогаю"
  fi
  while IFS= read -r -d '' f; do
    rm -f "$CLIENT_DIR/$(client_name_of "$f")"_awg[23].conf
    install -m 600 "$f" "$CLIENT_DIR/${f##*/}"
  done < <(find "$src" -maxdepth 1 -name '*_awg[23].conf' -print0)
}

_restore_warp() {  # каталог бэкапа
  local src="$1/warp" be f
  [[ -d "$src" ]] || return 0
  if [[ -d "$src/wgcf" ]]; then
    # Только данные аккаунта: в каталоге лежит и скрипт автозапуска, который
    # служба выполняет от root, — его Тулза пишет сама, из бэкапа не берём.
    # Состояние «включён» тоже не переносим — туннель включают руками.
    mkdir -p "$WARP_DIR" && chmod 700 "$WARP_DIR"
    for f in "$WARP_ACCOUNT" "$WARP_PROFILE" "$WARP_PEERS" "$WARP_DIR/account_type"; do
      [[ -f "$src/wgcf/${f##*/}" ]] && install -D -m 600 "$src/wgcf/${f##*/}" "$f"
    done
    rm -f "$WARP_STATE" "$WARP_STATE.failed"
    ok "WARP (wg): аккаунт"
  fi
  [[ -f "$src/warp0.conf" ]] && install -D -m 600 "$src/warp0.conf" "$WARP_CONF"
  if [[ -f "$src/usque/config.json" ]]; then
    install -D -m 600 "$src/usque/config.json" "$USQUE_CONF" && chmod 700 "$USQUE_DIR" && ok "WARP (usque): регистрация"
  fi
  be=$(sed -n 's/^warp_backend=//p' "$1/backup_meta.txt" 2>/dev/null)
  [[ "$be" == wg || "$be" == usque ]] && echo "$be" | write_file "$WARP_BACKEND_FILE" 644
  info "WARP восстановлен выключенным — включи его в меню туннелей"
}

# Настройки туннелей. Бэкап мог прийти чужой (присланный в бота), поэтому
# архив не распаковывается в / — иначе он переписал бы любой файл системы.
# Он идёт во временный каталог, а на место ложатся только файлы, которые
# кладёт в бэкап сама Тулза, и с проверкой: конфиги exit-нод — без хуков,
# правила каскада и адрес tun2socks — по формату, конфиг dnscrypt-proxy —
# шаблон Тулзы, из бэкапа берутся только имена резолверов.
_restore_tunnels() {  # каталог бэкапа
  local arch="$1/tunnels.tar.gz" x f n names
  [[ -f "$arch" ]] || return 0
  mktmp x -d || return 1
  py safe-untar "$arch" "$x" || { warn "Настройки туннелей не распаковались"; return 0; }
  if [[ -f "$x$XRAY_CONF" ]]; then
    # Xray работает от root: из чужого конфига — только выходы и маршруты,
    # входы (SOCKS на 0.0.0.0, API) и журналы Тулза пишет сама
    if n=$(py xray-restore-clean "$x$XRAY_CONF" 2>/dev/null); then
      install -D -m 600 "$x$XRAY_CONF" "$XRAY_CONF"
      [[ -n "$n" ]] && warn "Из конфига Xray бэкапа убрано: $n"
    else warn "Конфиг Xray из бэкапа не разобран — пропущен"; fi
  fi
  [[ -f "$x$XRAY_PEERS" ]] && install -D -m 600 "$x$XRAY_PEERS" "$XRAY_PEERS"
  for f in "$EXITS_STATE" "$EXITS_PEERS"; do
    [[ -f "$x$f" ]] && install -D -m 600 "$x$f" "$f"
  done
  for f in "$x$EXITS_DIR"/awg-exit-*.conf; do
    [[ -f "$f" ]] || continue
    n="${f##*/awg-exit-}"; n="${n%.conf}"
    [[ "$n" =~ ^[A-Za-z0-9_]{1,6}$ ]] || { warn "Пропущен конфиг exit-ноды: ${f##*/}"; continue; }
    py exit-conf-fix "$f" && install -m 600 "$f" "$EXITS_DIR/awg-exit-$n.conf"
  done
  [[ -f "$x$CASCADE_RULES" ]] && _restore_cascade_rules "$x$CASCADE_RULES"
  if [[ -f "$x$T2S_CONF" ]]; then
    n=$(head -1 "$x$T2S_CONF" | tr -d '[:space:]')
    [[ "$n" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] && echo "$n" | write_file "$T2S_CONF" 600
  fi
  if [[ -f "$x$DNS_PROXY_CONF" ]]; then
    names=$(sed -n 's/^server_names[[:space:]]*=[[:space:]]*//p' "$x$DNS_PROXY_CONF" | tr -d "[]'\"" | head -1)
    _dns_write_conf
    [[ -n "$names" ]] && { _dns_upstream_write "$names" || warn "Резолверы DNS из бэкапа не приняты — стоят по умолчанию"; }
  fi
  rm -f "$XRAY_STATE"
  [[ -f "$EXITS_STATE" ]] && exits_state_set state inactive
  for n in $(exits_nodes); do systemctl enable --now "awg-quick@awg-exit-$n" &>/dev/null || warn "Нода $n не поднялась"; done
  (( $(cascade_count) )) && { _cascade_persist; systemctl restart awg-cascade.service &>/dev/null; }
  ok "Настройки туннелей восстановлены; маршрутизация клиентов выключена"
}

# Правила каскада из бэкапа — с теми же проверками, что при добавлении:
# публичный адрес цели, порты 1-65535, вход не занят AmneziaWG, обфускатором
# или локальным сервисом. Не прошедшее — пропускается с причиной.
_restore_cascade_rules() {  # файл правил из бэкапа
  local p in dst out comment why seen=" " kept=()
  # || [[ -n $p ]]: последняя строка без перевода строки (файл правили руками)
  # иначе молча терялась
  while IFS='|' read -r p in dst out comment || [[ -n "$p" ]]; do
    [[ "$p" == udp || "$p" == tcp ]] || continue
    out="${out//[$'\r']/}" comment="${comment//[$'\r']/}"
    # Поля из чужого файла идут в warn (echo -e) — без управляющих символов и \\
    in="${in//[$'\001'-$'\037'$'\177'\\]/?}" dst="${dst//[$'\001'-$'\037'$'\177'\\]/?}"
    out="${out//[$'\001'-$'\037'$'\177'\\]/?}"
    if why=$(_cascade_rule_invalid "$in" "$dst" "$out"); then
      warn "Каскад из бэкапа: пропущено ${p^^} $in → $dst:$out — $why"; continue
    fi
    [[ "$seen" == *" $p|$in "* ]] && continue
    if why=$(CASCADE_RULES=/dev/null _cascade_port_conflict "$p" "$in"); then
      warn "Каскад из бэкапа: пропущено ${p^^} $in — $why"; continue
    fi
    seen+="$p|$in "
    kept+=("$p|$in|$dst|$out|$comment")
  done < "$1"
  if (( ${#kept[@]} )); then printf '%s\n' "${kept[@]}" | write_file "$CASCADE_RULES" 600
  else rm -f "$CASCADE_RULES"; fi
}

# Хуки конфига из бэкапа (PostUp и т. п.) выполняются от root при подъёме
# интерфейса. Команды не из Тулзы (не iptables, ip_forward, MTU) в меню —
# показать и спросить, в боте и панели — убрать с предупреждением в итоге.
_restore_hooks() {  # конфиг [разрешённые команды…]
  local conf="$1" bad
  shift
  bad=$(py conf-hooks "$conf" check "$@") || { err "${conf##*/} из бэкапа не читается"; return 1; }
  [[ -n "$bad" ]] || return 0
  warn "В ${conf##*/} из бэкапа — команды, которые выполнятся от root при запуске:"
  sed 's/^/    /; s/\t/ = /' <<< "$bad"
  if (( ! AUTO_MODE )) && ask_yes "  Оставить их? Только если ты сам их туда вписал [y/N]: " n; then
    warn "Команды оставлены"
    return 0
  fi
  py conf-hooks "$conf" fix "$@" >/dev/null || return 1
  warn "Команды убраны из ${conf##*/}"
}

do_restore() {
  local list=() i c src name opts=()
  mapfile -t list < <(_restore_list)
  (( ${#list[@]} )) || { err "Бэкапов нет в $BACKUP_DIR"; return 1; }
  for i in "${!list[@]}"; do
    name="${list[$i]##*/}"
    if [[ -d "${list[$i]}" ]]; then echo -e "  ${C}$((i + 1)))${N} $name ${D}(полный)${N}"
    else echo -e "  ${C}$((i + 1)))${N} $name"; fi
  done
  read_choice c "${C}  Бэкап (Enter = 1, 0 — отмена): ${N}" 0 "${#list[@]}" 1
  (( c )) || return 0
  src="${list[$((c - 1))]}"
  _restore_prepare "$src" || return 1
  read_confirm "${R}  Текущий сервер будет заменён. Продолжить? (введи yes): ${N}" || return 0
  [[ -d "$RESTORE_SRC/wgobf/etc" ]] && ask_yes "  В бэкапе есть WG + обфускатор — восстановить? [Y/n]: " y && opts+=(wgobf)
  [[ -f "$RESTORE_SRC/tunnels.tar.gz" ]] \
    && ask_yes "  Восстановить настройки туннелей (Xray, exit-ноды, каскад, tun2socks, DNS)? [Y/n]: " y && opts+=(tunnels)
  backup_restore "$src" "${opts[@]}"
}

# backup_restore БЭКАП [wgobf] [tunnels] — сервер и клиенты всегда, остальное по флагам.
backup_restore() {
  local src="$1" label="${1##*/}" port f
  shift
  command -v awg-quick &>/dev/null || { err "Нет awg-quick — сначала установи компоненты (Сервер → Установить компоненты)"; return 1; }
  _restore_prepare "$src" || return 1
  src="$RESTORE_SRC"
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  [[ -f "$SERVER_CONF" ]] && cp -a "$SERVER_CONF" "$SERVER_CONF.pre_restore.$(date +%s)"
  _restore_awg_files "$src"
  _restore_hooks "$SERVER_CONF" || return 1
  # Бэкап с другого VPS: NAT — на аплинк этого сервера
  conf_uplink_sync force || true
  client_files_sync_suffix
  ok "Сервер и клиенты: $(client_files | wc -l) кл."
  _restore_warp "$src"
  for f in "$@"; do
    case "$f" in
      wgobf) [[ -f "$src/wgobf/$WGOBF_IF.conf" && -d "$src/wgobf/etc" ]] && { wgobf_restore "$src/wgobf" || true; } ;;
      tunnels) _restore_tunnels "$src" ;;
    esac
  done
  # Восстановление на чистый сервер: автозапуск, форвардинг и порт в UFW
  ip_forward_enable
  setup_autostart
  port=$(server_port)
  [[ -n "$port" ]] && ufw_allow "$port/udp" AmneziaWG
  expire_install
  if awg_up_diag; then ok "awg0 поднят"; else err "awg0 не поднялся — конфиг: $SERVER_CONF"; return 1; fi
  success_box "Восстановлено из $label"
  log_info "восстановление из $label"
}

# ═════ update ═════
# Самообновление. Канал stable — основной репозиторий, beta — ранние сборки.
# Выбор хранится в /var/lib/awg2/channel; AWG2_UPDATE_CHANNEL=beta — разовый
# запуск на другом канале. У каналов раздельные кэши проверки версии.

UPDATE_CHANNEL="" UPDATE_REPO="" UPDATE_URL="" UPDATE_CACHE="" BOT_INSTALL_URL=""

update_channel_apply() {
  if [[ "${1:-}" == beta ]]; then
    UPDATE_CHANNEL=beta; UPDATE_REPO="$UPDATE_REPO_BETA"; UPDATE_CACHE="$STATE_DIR/update_check.beta"
  else
    UPDATE_CHANNEL=stable; UPDATE_REPO="$UPDATE_REPO_STABLE"; UPDATE_CACHE="$STATE_DIR/update_check"
  fi
  UPDATE_URL="https://raw.githubusercontent.com/$UPDATE_REPO/main/awg2.sh"
  BOT_INSTALL_URL="https://raw.githubusercontent.com/$UPDATE_REPO/main/awg-bot-install.sh"
}

update_channel_read() {
  [[ "$(tr -d '[:space:]' 2>/dev/null < "$UPDATE_CHANNEL_FILE")" == beta ]] && echo beta || echo stable
}

update_channel_label() { [[ "$UPDATE_CHANNEL" == beta ]] && echo "бета" || echo "стабильный"; }

update_channel_init() { update_channel_apply "${AWG2_UPDATE_CHANNEL:-$(update_channel_read)}"; }

# Фоновая проверка раз в час (бета — раз в 20 минут): шапка меню и сводка
# для бота читают только кэш и сеть не ждут.
# Качаем первые 4 КБ — VERSION= стоит в начале файла.
update_check_async() {
  local ts now ttl="$UPDATE_CHECK_TTL"
  [[ -n "${AWG_NO_UPDATE_CHECK:-}" ]] && return 0
  [[ "$UPDATE_CHANNEL" == beta ]] && ttl="$UPDATE_CHECK_TTL_BETA"
  now=$(date +%s)
  ts=$(awk '{print $2 + 0; exit}' "$UPDATE_CACHE" 2>/dev/null || echo 0)
  (( now - ${ts:-0} < ttl )) && return 0
  mkdir -p "$STATE_DIR"
  update_peek </dev/null &>/dev/null 3>&- 4>&- 8>&- &
  disown 2>/dev/null || true
}

# Версия в канале по первым 4 КБ файла (напрямую и через зеркала) → в кэш.
update_peek() {
  local mp v
  for mp in "${GH_MIRRORS[@]}"; do
    v=$(curl -fsSL --connect-timeout 5 --max-time 10 -r 0-4095 -H 'Cache-Control: no-cache' \
          "${mp}${UPDATE_URL}?nocache=$(date +%s)" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2)
    if [[ "$v" =~ ^v?[0-9]+\.[0-9]+ ]]; then
      printf '%s %s\n' "$v" "$(date +%s)" > "$UPDATE_CACHE" 2>/dev/null || true
      echo "$v"
      return 0
    fi
  done
  return 1
}

# CHANGELOG.md канала (лежит рядом с awg2.sh) → UPDATE_CHANGELOG; напрямую и
# через зеркала, как и сам скрипт.
UPDATE_CHANGELOG=""
update_changelog_fetch() {
  local mp out url="${UPDATE_URL%/*}/CHANGELOG.md"
  UPDATE_CHANGELOG=""
  for mp in "${GH_MIRRORS[@]}"; do
    out=$(curl -fsSL --connect-timeout 5 --max-time 15 --max-filesize 1048576 -H 'Cache-Control: no-cache' \
            "${mp}${url}?nocache=$(date +%s)" 2>/dev/null) || continue
    [[ "$out" == *"## v"* ]] || continue
    UPDATE_CHANGELOG="$out"
    return 0
  done
  return 1
}

update_available() {  # → версия, если новее текущей
  local v
  v=$(awk '{print $1; exit}' "$UPDATE_CACHE" 2>/dev/null)
  [[ "$v" =~ ^v?[0-9]+\.[0-9]+ ]] || return 1
  (( 10#$(ver_num "$v") > 10#$(ver_num "$VERSION") )) || return 1
  echo "$v"
}

_update_download() {  # файл
  local mp url
  url="$UPDATE_URL?nocache=$(date +%s)"
  for mp in "${GH_MIRRORS[@]}"; do
    [[ -n "$mp" ]] && info "Через зеркало ${mp}"
    curl -fL --connect-timeout 10 --max-time 120 --progress-bar -H 'Cache-Control: no-cache' \
      "${mp}${url}" -o "$1" && return 0
  done
  return 1
}

# Подпись awg2.sh.sig — напрямую и через зеркала: подделать её зеркало не может.
_update_download_sig() {  # файл
  local mp url
  url="${UPDATE_URL%/*}/awg2.sh.sig?nocache=$(date +%s)"
  for mp in "${GH_MIRRORS[@]}"; do
    curl -fsSL --connect-timeout 10 --max-time 30 --max-filesize 16384 -H 'Cache-Control: no-cache' \
      "${mp}${url}" -o "$1" 2>/dev/null || continue
    grep -q 'BEGIN SSH SIGNATURE' "$1" && return 0
  done
  return 1
}

# Проверка подписи файла $1 подписью $2 ключом релизов. 0 — верна.
update_sig_ok() {
  local allowed s
  (( ${#UPDATE_SIGNERS[@]} )) || return 1
  command -v ssh-keygen &>/dev/null || need_cmds ssh-keygen:openssh-client >/dev/null || return 1
  mktmp allowed || return 1
  for s in "${UPDATE_SIGNERS[@]}"; do
    printf '%s namespaces="%s" %s\n' "$UPDATE_SIGNER" "$UPDATE_SIG_NS" "$s"
  done > "$allowed"
  ssh-keygen -Y verify -f "$allowed" -I "$UPDATE_SIGNER" -n "$UPDATE_SIG_NS" -s "$2" < "$1" &>/dev/null
}

# Подпись скачанной сборки. Без подписи ставится только сборка старше
# UPDATE_SIG_SINCE (откат на старую версию) и только из меню, после «yes»:
# новая сборка без подписи — это подмена или сбой, а не выпуск.
update_verify() {  # файл
  local sig
  # Ключ вшивается в каждую выпущенную сборку (тест сборки это проверяет);
  # без него — только локальная тестовая сборка, ей проверять нечем
  if (( ${#UPDATE_SIGNERS[@]} == 0 )); then
    warn "Тестовая сборка без ключа релизов — подпись обновления не проверяется"
    return 0
  fi
  mktmp sig || return 1
  if ! _update_download_sig "$sig"; then
    if (( 10#$(ver_num "$UPDATE_NEW") >= 10#$(ver_num "$UPDATE_SIG_SINCE") )); then
      err "У сборки $UPDATE_NEW нет подписи (awg2.sh.sig) — не ставлю. Повтори через пару минут"
      return 1
    fi
    warn "Сборка $UPDATE_NEW вышла до подписей ($UPDATE_SIG_SINCE) — подлинность не проверить"
    if ! read_confirm "${Y}  Поставить без проверки подписи? (введи yes): ${N}"; then
      (( AUTO_MODE )) && err "Сборку без подписи ставлю только из меню awg2 — Обновление"
      return 1
    fi
    return 0
  fi
  if ! update_sig_ok "$1" "$sig"; then
    err "Подпись сборки $UPDATE_NEW не сходится — файл изменён по пути (зеркало?) или только что выложен."
    info "Повтори через пару минут; не помогло — напиши в t.me/awgToolza"
    log_info "обновление $UPDATE_NEW отклонено: подпись не сходится"
    return 1
  fi
  ok "Подпись сборки верна"
}

# Скачать сборку из канала и проверить её → UPDATE_FILE, UPDATE_NEW.
UPDATE_FILE="" UPDATE_NEW=""
update_fetch() {
  mktmp UPDATE_FILE || return 1
  info "Канал: $(update_channel_label) ${D}($UPDATE_REPO)${N}"
  _update_download "$UPDATE_FILE" || { err "Не удалось скачать обновление"; return 1; }
  if (( $(stat -c%s "$UPDATE_FILE") < 50000 )) || ! head -1 "$UPDATE_FILE" | grep -q '^#!.*bash' \
     || ! bash -n "$UPDATE_FILE" 2>/dev/null; then
    err "Скачанный файл повреждён (не bash или синтаксическая ошибка) — повтори позже"
    return 1
  fi
  UPDATE_NEW=$(head -c 4096 "$UPDATE_FILE" | grep -m1 '^VERSION=' | cut -d'"' -f2)
  [[ "$UPDATE_NEW" =~ ^v?[0-9]+\.[0-9]+ ]] || { err "В скачанном файле нет VERSION"; return 1; }
  echo "Текущая: $VERSION, в канале: $UPDATE_NEW"
  update_verify "$UPDATE_FILE" || return 1
  printf '%s %s\n' "$UPDATE_NEW" "$(date +%s)" > "$UPDATE_CACHE" 2>/dev/null || true
}

# Поставить скачанное. Замена через rename: работающие копии awg2 дочитывают
# свой файл, а не новый. «force» — разрешить откат на старшую версию.
update_install() {
  local target="$SCRIPT_PATH"
  [[ -f "$target" ]] || target=$(readlink -f "$0")
  if (( 10#$(ver_num "$UPDATE_NEW") < 10#$(ver_num "$VERSION") )); then
    # Подпись не привязана к версии: зеркало может отдать старую, но верно
    # подписанную сборку. Из бота и панели («Переустановить» = force) откат
    # не ставится никогда — только из меню awg2, где он назван откатом.
    if (( API_MODE )); then
      err "В канале версия старше текущей ($UPDATE_NEW) — откат только из меню awg2"
      return 1
    fi
    if [[ "${1:-}" != force ]]; then
      err "В канале версия старше текущей ($UPDATE_NEW) — откат только явно"
      return 1
    fi
  fi
  if cmp -s "$target" "$UPDATE_FILE"; then ok "Уже последняя версия ($VERSION)"; return 0; fi
  cp -a "$target" "$target.bak" 2>/dev/null && info "Прежняя версия: $target.bak"
  install -m 755 "$UPDATE_FILE" "$target.new" && mv -f "$target.new" "$target" \
    || { err "Не удалось заменить $target"; return 1; }
  hash -r
  ok "Установлено: $UPDATE_NEW"
  log_info "самообновление $VERSION → $UPDATE_NEW"
}

_script_ver() {  # файл awg2 → v1.2.0d (версия и буква тестовой сборки)
  head -c 4096 "$1" 2>/dev/null | awk -F'"' '/^VERSION="/ && !v {v=$2} /^BUILD="/ && !b {b=$2; nb=1}
    END {printf "%s%s", v, (nb ? b : "")}'
}

# Запуск из распакованного архива (sudo bash awg2.sh): бот, таймеры и команда
# awg2 работают с установленной копией $SCRIPT_PATH — предложить заменить её.
self_install_offer() {
  local self cur def=y
  # $0 без «/» — не путь к файлу («bash» при запуске через curl | bash):
  # readlink нашёл бы ./bash в текущем каталоге и предложил поставить его
  [[ "$0" == */* ]] || return 0
  self=$(readlink -f "$0" 2>/dev/null) || return 0
  [[ -f "$self" && "$self" != "$(readlink -f "$SCRIPT_PATH" 2>/dev/null)" ]] || return 0
  head -c 4096 "$self" | grep -q '^VERSION="' || return 0
  cmp -s "$self" "$SCRIPT_PATH" && return 0
  echo ""
  if [[ ! -f "$SCRIPT_PATH" ]]; then
    warn "Команда awg2 не установлена: бот и таймеры ищут $SCRIPT_PATH"
  else
    cur=$(_script_ver "$SCRIPT_PATH")
    warn "Запущена копия $(shown "$self") ($VERSION_SHOW), а установлена ${cur:-другая} в $SCRIPT_PATH"
    info "Бот, панель и команда awg2 работают с установленной"
    if [[ "$cur" =~ ^v?[0-9] ]] && (( 10#$(ver_num "$cur") > 10#$(ver_num "$VERSION") )); then
      warn "Установленная новее — замена будет откатом"
      def=n
    fi
  fi
  ask_yes "  Установить эту копию ($(shown "$self")) в $SCRIPT_PATH? [$([[ $def == y ]] && echo Y/n || echo y/N)]: " "$def" || return 0
  [[ -f "$SCRIPT_PATH" ]] && cp -a "$SCRIPT_PATH" "$SCRIPT_PATH.bak" 2>/dev/null \
    && info "Прежняя копия: $SCRIPT_PATH.bak"
  # Через rename: работающие копии awg2 дочитывают свой файл, а не новый
  install -m 755 "$self" "$SCRIPT_PATH.new" && mv -f "$SCRIPT_PATH.new" "$SCRIPT_PATH" \
    || { rm -f "$SCRIPT_PATH.new"; err "Не удалось записать $SCRIPT_PATH"; return 0; }
  hash -r
  ok "Установлено: $SCRIPT_PATH ($VERSION_SHOW)"
  log_info "awg2 $VERSION_SHOW установлен из $self"
}

do_self_update() {
  local cur_n new_n target="$SCRIPT_PATH"
  [[ -f "$target" ]] || target=$(readlink -f "$0")
  update_fetch || return 1
  cur_n=$(ver_num "$VERSION"); new_n=$(ver_num "$UPDATE_NEW")
  if (( 10#$new_n < 10#$cur_n )); then
    warn "В канале версия старше текущей — это откат"
    read_confirm "${R}  Откатиться до $UPDATE_NEW? (введи yes): ${N}" || return 0
  elif (( 10#$new_n == 10#$cur_n )); then
    cmp -s "$target" "$UPDATE_FILE" && { ok "Уже последняя версия"; return 0; }
    ask_yes "  Версия та же, но файл отличается. Перезаписать? [y/N]: " n || return 0
  else
    ask_yes "  Установить $UPDATE_NEW? [Y/n]: " y || return 0
  fi
  update_install force || return 1
  # В памяти старый код, а bash дочитывает файл по ходу — продолжать здесь нельзя
  info "Перезапускаюсь..."
  exec "$target" --post-update "$VERSION"
}

update_channel_set() {  # stable|beta
  [[ "$1" == stable || "$1" == beta ]] || { err "Канал: stable | beta"; return 1; }
  mkdir -p "$STATE_DIR"
  echo "$1" | write_file "$UPDATE_CHANNEL_FILE" 644
  update_channel_apply "$1"
  ok "Канал: $(update_channel_label)"
}

do_switch_channel() {
  local to=beta
  [[ "$UPDATE_CHANNEL" == beta ]] && to=stable
  if [[ "$to" == beta ]]; then
    warn "Бета — ранние сборки: правки приезжают раньше, но могут быть сырыми"
    ask_yes "  Переключиться на бета-канал? [y/N]: " n || return 0
  fi
  update_channel_set "$to"
  ask_yes "  Обновиться с этого канала сейчас? [Y/n]: " y && do_self_update
  return 0
}

# Служебные скрипты (автозапуск туннелей, таймеры) генерируются из кода awg2.
# После смены версии перегенерируем их у уже включённых компонентов — иначе
# при загрузке работала бы логика прежней версии.
helpers_refresh() {
  # Отметка — версия и хеш сборки: тестовые сборки одной версии (v1.2.0c → d)
  # тоже перегенерируют скрипты
  local mark="$STATE_DIR/version" stamp="$VERSION_SHOW ${_BUILD_SUM:-}"
  [[ "$(cat "$mark" 2>/dev/null)" == "$stamp" ]] && return 0
  mkdir -p "$STATE_DIR"
  server_exists && expire_install &>/dev/null
  # Исходник модуля в DKMS поставила прежняя версия: без правки автосборка
  # DKMS при обновлении ядра (Ubuntu 7.0.0-38) упала бы
  _mod_src_patch "$MOD_SRC_DIR"
  if [[ -f "$WARP_AUTOSTART_SCRIPT" ]]; then
    emit_script "$WARP_AUTOSTART_SCRIPT" 'warp_wg_bringup' \
      WARP_CONF WARP_IF WARP_TABLE WARP_PEERS "${RT_FUNCS[@]}" warp_wg_bringup
  fi
  if [[ -f "$WARP_HEALTH_SCRIPT" ]]; then
    emit_script "$WARP_HEALTH_SCRIPT" 'warp_health_run' WARP_IF WARP_TABLE WARP_STATE \
      WARP_BACKEND_FILE WARP_HEALTH_LOG "${RT_FUNCS[@]}" warp_health_run
  fi
  [[ -f "$USQUE_UP_HOOK" ]] && _usque_write &>/dev/null
  if [[ -f "$DNS_PROXY_STATE" ]]; then
    _dns_emit_helpers &>/dev/null
    # Прежние версии ставили блок DoT в FORWARD ниже ACCEPT — он не работал
    iface_up && { dns_rules_down; dns_rules_up; }
  fi
  if (( $(cascade_count) )); then
    _cascade_persist && cascade_apply_all
  fi
  [[ -f "$T2S_ROUTING_SCRIPT" ]] && emit_script "$T2S_ROUTING_SCRIPT" 't2s_routing_run "$@"' \
    T2S_IF T2S_TABLE T2S_ADDR "${RT_FUNCS[@]}" t2s_routing_run
  [[ -f "$EXITS_SCRIPT" ]] && _exits_write_unit
  antiscan_on && _antiscan_emit &>/dev/null
  # Маршруты Xray: с v1.2.0 перед inbound tun нет NAT (свой выход клиенту)
  [[ -f "$XRAY_ROUTING_SCRIPT" ]] && _xray_emit_routing
  # Xray прежних версий жил во временных юнитах и перезагрузку не переживал
  [[ -f "$XRAY_STATE" && ! -f "/etc/systemd/system/$XRAY_UNIT" ]] && ! xray_is_up && rm -f "$XRAY_STATE"
  wgobf_installed && _wgobf_write_service_files
  echo "$stamp" > "$mark"
  log_info "служебные скрипты обновлены под $VERSION_SHOW"
}

do_update_menu() {
  local c upd
  while true; do
    echo ""
    hdr "Обновление скрипта"
    echo -e "  Версия : ${W}$VERSION_SHOW${N}"
    echo -e "  Канал  : $([[ "$UPDATE_CHANNEL" == beta ]] && echo -e "${Y}бета${N}" || echo -e "${G}стабильный${N}") ${D}($UPDATE_REPO)${N}"
    upd=$(update_available || true)
    [[ -n "$upd" ]] && echo -e "  Доступна: ${G}$upd${N}"
    echo ""
    echo -e "  ${C}1)${N} Обновить скрипт"
    if [[ "$UPDATE_CHANNEL" == beta ]]; then echo -e "  ${C}2)${N} Вернуться на стабильный канал"
    else echo -e "  ${C}2)${N} Бета-канал ${D}(ранние сборки)${N}"; fi
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) do_self_update || true ;;
      2) do_switch_channel || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ bot ═════
# Telegram-бот управления: установка (awg-bot-install.sh из того же канала,
# что и awg2), запуск, журнал, прокси до Telegram API, полное удаление.
# Сам бот — отдельная программа (awg_bot/), с awg2 он общается через CLI.

BOT_ARTIFACTS=(/opt/awg-bot /var/lib/awg-bot /usr/local/bin/awg-bot /usr/local/bin/awg-bot.py
               /etc/systemd/system/awg-bot.service /etc/awg-bot.conf)
BOT_VENV_PY="$BOT_DIR/venv/bin/python"

# Любой след бота, а не только маркер: после частичного удаления его
# остатки тоже надо уметь добить.
# Код в $BOT_DIR ставит и веб-панель (--web-only) — при ней это ещё не бот
bot_installed() {
  [[ -f /usr/local/bin/awg-bot.py || -f "/etc/systemd/system/$BOT_UNIT" ]] && return 0
  [[ -d "$BOT_DIR" ]] && ! web_installed
}

bot_version() { _bot_src_version "$BOT_DIR"; }

# ── Прокси до Telegram ────────────────────────────────────
# Значение ключа из конфига бота (кавычки и пробелы по краям снимаются).
bot_conf_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$BOT_CONF" 2>/dev/null | tail -1 \
    | sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//"
}

# KEY=значение в конфиге бота; пустое значение — убрать ключ.
bot_conf_set() {
  [[ -f "$BOT_CONF" ]] || { err "Нет $BOT_CONF — сначала установи бота"; return 1; }
  { grep -vE "^[[:space:]]*$1[[:space:]]*=" "$BOT_CONF" || true
    if [[ -n "$2" ]]; then echo "$1=$2"; fi; } | write_file "$BOT_CONF" 600
}

bot_proxy_get() { bot_conf_get BOT_PROXY; }

# Пароль прокси весит как токен бота, а меню снимают на скриншоты
bot_proxy_mask() { if [[ "$1" == *@* ]]; then echo "${1%%://*}://***@${1##*@}"; else echo "$1"; fi; }

bot_proxy_valid() {
  local url="$1" scheme="${1%%://*}"
  [[ "$url" == *://?* ]] || return 1
  [[ "$scheme" == iface ]] && { [[ "${url#iface://}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; return; }
  [[ " $BOT_PROXY_SCHEMES " == *" $scheme "* ]]
}

# Любой HTTP-ответ api.telegram.org значит «прокси работает» (на / там 404)
bot_proxy_probe() {
  local code via=(--proxy "$1")
  [[ "$1" == iface://* ]] && via=(--interface "${1#iface://}")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${via[@]}" https://api.telegram.org/ 2>/dev/null) || code=000
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]
}

_bot_proxy_write() { bot_conf_set BOT_PROXY "$1"; }  # url (пусто — убрать)

# ── Mini App ──────────────────────────────────────────────
# HTTPS-сервер Mini App живёт в самом боте; awg2 задаёт порт (WEBAPP_PORT в
# конфиге бота, off — выключена) и выпускает сертификат (cert.sh).
webapp_port() {
  local p
  p=$(bot_conf_get WEBAPP_PORT)
  echo "${p:-$WEBAPP_PORT_DEFAULT}"
}

webapp_fw() {
  local p
  [[ -f "/etc/systemd/system/$BOT_UNIT" ]] || return 0
  p=$(webapp_port)
  [[ "$p" == off ]] || ufw_allow "$p/tcp" awg-webapp
  return 0
}

webapp_port_set() {  # порт | off
  local p="${1:-}"
  if [[ "$p" != off ]]; then
    valid_port "$p" && (( p != 80 )) || { err "Порт Mini App: 1-65535, кроме 80 — он для сертификата"; return 1; }
  fi
  bot_conf_set WEBAPP_PORT "$p" || return 1
  webapp_fw
  ok "Mini App: $([[ "$p" == off ]] && echo "выключена" || echo "порт $p")"
}

webapp_url() {
  local p
  p=$(webapp_port)
  cert_installed && [[ "$p" != off ]] || return 1
  echo "https://$(cert_get name)$([[ "$p" == 443 ]] || echo ":$p")/"
}

# Выпуск из меню: порт 80 занят — готовый сертификат сервера или пауза службы.
_cert_issue_menu() {
  local holder unit n c
  holder=$(cert_port80_holder)
  if [[ -z "$holder" ]]; then cert_issue "$@" && webapp_fw && bot_restart; return; fi
  unit=$(cert_port80_unit)
  n=$(cert_find | grep -c . || true)
  warn "Порт 80 занят ($holder) — acme.sh нужен он на время выпуска и продления"
  echo -e "  ${C}1)${N} Взять готовый сертификат сервера ${D}— найдено $n${N}"
  [[ -n "$unit" ]] && echo -e "  ${C}2)${N} Останавливать $unit на время выпуска и продления ${D}— секунды простоя$([[ "$1" == ip ]] && echo ', раз в 3 дня')${N}"
  echo -e "  ${W}0)${N} ← Отмена"
  read_choice c "${C}  Выбор: ${N}" 0 2 0
  case "$c" in
    1) _cert_use_menu ;;
    2) [[ -n "$unit" ]] && cert_issue "$@" pause && webapp_fw && bot_restart ;;
  esac
}

_cert_use_menu() {
  local rows=() i c name src crt key exp
  mapfile -t rows < <(cert_find)
  if (( ${#rows[@]} == 0 )); then
    info "Готовых сертификатов на этот сервер не нашлось (Caddy, certbot, acme.sh, Marzban, 3x-ui, nginx)"
    return 1
  fi
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r name src crt key exp <<< "${rows[$i]}"
    echo -e "  ${C}$((i + 1)))${N} $name ${D}— $src, до $(date -d "@$exp" '+%d.%m.%Y')${N}"
    echo -e "     ${D}$crt${N}"
  done
  echo -e "  ${W}0)${N} ← Отмена"
  read_choice c "${C}  Сертификат [0-${#rows[@]}]: ${N}" 0 "${#rows[@]}" 0
  (( c )) || return 0
  IFS=$'\t' read -r name src crt key exp <<< "${rows[$((c - 1))]}"
  cert_use "$crt" && webapp_fw && bot_restart
}

do_webapp_menu() {
  local c v p url n
  while true; do
    echo ""
    hdr "Mini App и HTTPS-сертификат"
    p=$(webapp_port)
    echo -e "  Сертификат : $(cert_state_line)"
    if url=$(webapp_url); then
      echo -e "  Mini App   : ${W}$url${N} ${D}— открывается кнопкой в боте${N}"
    else
      echo -e "  Mini App   : ${D}$([[ "$p" == off ]] && echo "выключена" || echo "нужен сертификат")${N}"
    fi
    echo -e "  ${D}Telegram открывает Mini App только по HTTPS. Let's Encrypt проверяет адрес через${N}"
    echo -e "  ${D}порт 80 — он должен быть свободен и открыт; сертификат на IP живёт ~6 дней и${N}"
    echo -e "  ${D}продлевается сам. Порт занят (Caddy, nginx) — возьми готовый сертификат сервера.${N}"
    echo ""
    n=$(cert_find | grep -c . || true)
    echo -e "  ${C}1)${N} Сертификат на IP ${D}— $(public_ip_cached)${N}"
    echo -e "  ${C}2)${N} Сертификат на домен"
    echo -e "  ${C}3)${N} Готовый сертификат сервера ${D}— найдено $n${N}"
    echo -e "  ${C}4)${N} Порт Mini App ${D}— $p${N}"
    echo -e "  ${R}5)${N} Удалить сертификат"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-5]: ${N}" 0 5 0
    case "$c" in
      1) _cert_issue_menu ip ;;
      2) read_line v "${C}  Домен (A-запись → $(public_ip_cached)): ${N}"
         [[ -n "$v" ]] && _cert_issue_menu domain "$v" ;;
      3) _cert_use_menu ;;
      4) read_line v "${C}  Порт (1-65535, off — выключить): ${N}"
         [[ -n "$v" ]] && webapp_port_set "$v" && bot_restart ;;
      5) ask_yes "  Удалить сертификат? Mini App перестанет открываться [y/N]: " n && cert_remove && bot_restart ;;
      0) return 0 ;;
    esac
    pause
  done
}

# Выходы этого сервера, годные боту, строки «url|описание».
_bot_proxy_candidates() {
  local list=() dev line url
  [[ -n "$(xray_port_owners)" ]] && list+=("socks5://$XRAY_SOCKS|SOCKS-вход Xray")
  url=$(t2s_proxy)
  [[ -n "$url" ]] && list+=("socks5://$url|прокси tun2socks")
  for dev in /sys/class/net/*; do
    dev="${dev##*/}"
    case "$dev" in
      warp0) list+=("iface://$dev|WARP") ;;
      awg-exit-*) list+=("iface://$dev|exit-нода ${dev#awg-exit-}") ;;
      xray0) list+=("iface://$dev|TUN Xray") ;;
      tun0) list+=("iface://$dev|TUN tun2socks") ;;
    esac
  done
  for line in ${list[@]+"${list[@]}"}; do
    if bot_proxy_probe "${line%%|*}"; then echo "$line — Telegram отвечает"
    else echo "$line — Telegram НЕ отвечает"; fi
  done
}

bot_proxy_menu() {
  local cur c cands=() i url
  cur=$(bot_proxy_get)
  echo -e "  Сейчас: ${W}$([[ -n "$cur" ]] && bot_proxy_mask "$cur" || echo "нет — напрямую")${N}"
  echo -e "  ${D}Нужен, если Telegram заблокирован: SOCKS5/HTTP или туннель сервера.${N}"
  echo -e "  ${C}1)${N} Задать прокси"
  echo -e "  ${C}2)${N} Проверить"
  echo -e "  ${R}3)${N} Убрать"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор [0-3]: ${N}" 0 3 0
  case "$c" in
    1) info "Ищу прокси и туннели на сервере..."
       mapfile -t cands < <(_bot_proxy_candidates)
       for i in "${!cands[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${W}${cands[$i]%%|*}${N} ${D}${cands[$i]#*|}${N}"; done
       url=""
       if (( ${#cands[@]} )); then
         read_choice c "${C}  Выбор (0 — ввести адрес): ${N}" 0 "${#cands[@]}" 0
         (( c )) && url="${cands[$((c - 1))]%%|*}"
       fi
       if [[ -z "$url" ]]; then
         echo -e "  ${D}Формат: схема://[логин:пароль@]хост:порт или iface://warp0${N}"
         read_line url "${C}  Адрес: ${N}"
         url="${url//[[:space:]]/}"
         [[ -n "$url" ]] || return 0
       fi
       bot_proxy_valid "$url" || { err "Нужна схема: ${BOT_PROXY_SCHEMES// /, }"; return 1; }
       if bot_proxy_probe "$url"; then bot_proxy_set "$url" || return 1
       else ask_yes "  Telegram через него не отвечает. Всё равно сохранить? [y/N]: " n || return 0
            bot_proxy_set "$url" force || return 1; fi ;;
    2) [[ -n "$cur" ]] || { info "Прокси не задан"; return 0; }
       if bot_proxy_probe "$cur"; then ok "Telegram отвечает"; else err "Через прокси Telegram не отвечает"; fi
       return 0 ;;
    3) [[ -n "$cur" ]] || return 0
       bot_proxy_set "" ;;
  esac
  return 0
}

# bot_proxy_set URL [force] — пусто убирает прокси. Без force сохраняет,
# только если Telegram через прокси отвечает. Бот перезапускается.
bot_proxy_set() {
  local url="${1//[[:space:]]/}"
  if [[ -n "$url" ]]; then
    bot_proxy_valid "$url" || { err "Нужна схема: ${BOT_PROXY_SCHEMES// /, }"; return 1; }
    if bot_proxy_probe "$url"; then ok "Через прокси Telegram отвечает"
    elif [[ "${2:-}" != force ]]; then err "Через $(bot_proxy_mask "$url") Telegram не отвечает — не сохраняю"; return 1
    else warn "Через прокси Telegram не отвечает — сохраняю по требованию"; fi
    # На давно установленном боте в venv может не быть нужных модулей
    if [[ "$url" == socks* && -x "$BOT_VENV_PY" ]] && ! "$BOT_VENV_PY" -c 'import aiohttp_socks' 2>/dev/null; then
      "$BOT_DIR/venv/bin/pip" install -q aiohttp-socks &>/dev/null || warn "Не поставился aiohttp-socks — обнови бота"
    fi
    if [[ "$url" == iface://* && -x "$BOT_VENV_PY" ]] && ! "$BOT_VENV_PY" -c \
       'import inspect,aiohttp; assert "socket_factory" in inspect.signature(aiohttp.TCPConnector).parameters' 2>/dev/null; then
      "$BOT_DIR/venv/bin/pip" install -q -U aiogram aiohttp &>/dev/null || warn "Не обновился aiohttp (нужен 3.12+) — обнови бота"
    fi
  fi
  _bot_proxy_write "$url" || return 1
  if [[ -n "$url" ]]; then
    ok "Прокси: $(bot_proxy_mask "$url")"
    [[ "$url" == iface://* || "$url" == *127.0.0.1* ]] && info "Туннель лёг — бот пойдёт напрямую; поднял — systemctl restart awg-bot"
  else
    ok "Прокси убран"
  fi
  bot_restart
  return 0
}

# Перезапуск бота. Если зовёт сам бот (awg2 api), этот процесс живёт в его
# cgroup: мгновенный restart убил бы его раньше ответа («awg2 ответил не
# JSON»). Тогда перезапуск откладывается на 2 секунды в отдельный юнит.
bot_restart() {
  unit_active "$BOT_UNIT" || return 0
  if (( ! API_MODE )); then
    systemctl restart "$BOT_UNIT" && ok "Бот перезапущен"
    return
  fi
  if ! systemd-run --on-active=2 --unit="awg2-bot-restart-$(date +%s%N)" --collect --quiet \
       /bin/systemctl restart "$BOT_UNIT" &>/dev/null; then
    # Без systemd-run: отдельная сессия без дескрипторов ответа
    setsid bash -c "sleep 2; systemctl restart $BOT_UNIT" </dev/null &>/dev/null 3>&- 4>&- 8>&- &
  fi
  ok "Бот перезапустится через пару секунд"
}

# ── Установка / удаление ──────────────────────────────────
# Код бота из распакованного архива рядом: при проверке правок на GitHub
# ещё старая версия.
# Версия кода бота в каталоге с awgbot/ (как __version__ у установленного).
_bot_src_version() {
  sed -n "s/^__version__[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" \
    "$1/awgbot/__init__.py" 2>/dev/null | head -1
}

# Локальный код бота из распакованного архива Тулзы: рядом с awg2, в
# текущем каталоге, в /opt, /root и /home/*. Из нескольких — самая новая
# версия бота (дата файла после распаковки ни о чём не говорит), при
# равных — найденная раньше. Только каталоги, которые может менять лишь
# root (root_only_tree): установщик и код бота из них запускаются от root,
# а из бота и панели — ещё и без вопроса. Иначе любой пользователь сервера
# подложил бы ~/awg-toolza-x с версией побольше и получил root.
_bot_local_src() {
  local d best="" bv="" v
  for d in "$(dirname "$(readlink -f "$0")")" "$PWD" /opt/awg-toolza-*/ /root/awg-toolza-*/ \
           /home/*/awg-toolza-*/ /opt/awg-toolza/; do
    # Дальше — только настоящий путь: проверенный каталог-ссылку подменили
    # бы между проверкой и запуском установщика
    [[ "$d" != *$'\n'* ]] && d=$(readlink -f -- "$d" 2>/dev/null) || continue
    [[ -n "$d" && "$d" != *$'\n'* && -d "$d/awg_bot/awgbot" && -f "$d/awg_bot/run.py" ]] || continue
    root_only_tree "$d/awg_bot" || continue
    [[ ! -e "$d/awg-bot-install.sh" ]] || root_only_path "$d/awg-bot-install.sh" || continue
    v=$(_bot_src_version "$d/awg_bot")
    if [[ -z "$best" ]] || [[ "$v" != "$bv" && "$(printf '%s\n%s\n' "$bv" "$v" | sort -V | tail -1)" == "$v" ]]; then
      best="$d/awg_bot"; bv="$v"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
}

bot_install() {
  local src installer
  src=$(_bot_local_src || true)
  # Установщик — в своём каталоге (700): рядом с ним он ищет awg_bot/, и в
  # общем /tmp его мог подложить любой пользователь
  mktmp installer -d || return 1
  installer+="/awg-bot-install.sh"
  local lv iv
  lv=$(_bot_src_version "$src"); iv=$(bot_version)
  if [[ -n "$src" ]] && ask_yes "  Найден локальный код бота $(shown "${lv:-?}") ($(shown "$src"))${iv:+, установлен $iv}. Ставить из него? [Y/n]: " y; then
    if [[ -f "${src%/awg_bot}/awg-bot-install.sh" ]]; then
      bash "${src%/awg_bot}/awg-bot-install.sh" --src "$src"
      return
    fi
    curl -fsSL "$BOT_INSTALL_URL" -o "$installer" || { err "Не скачался установщик"; return 1; }
    bash "$installer" --src "$src"
    return
  fi
  info "Установщик бота — канал $(update_channel_label)"
  curl -fsSL "$BOT_INSTALL_URL" -o "$installer" || { err "Не скачался установщик: $BOT_INSTALL_URL"; return 1; }
  # Бот и awg2 — из одного репозитория, иначе на бете они разъедутся
  AWG_REPO_URL="https://github.com/$UPDATE_REPO" bash "$installer"
}

# $1 = quiet — без вопроса. Токен перед удалением копируется в бэкапы.
bot_uninstall() {
  local p saved="" left=()
  if [[ "${1:-}" != quiet ]]; then
    warn "Будут удалены служба, код, venv и конфиг с токеном. AWG не затрагивается."
    read_confirm "${R}  Удалить бота? (введи yes): ${N}" || return 0
  fi
  if [[ -f "$BOT_CONF" ]]; then
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    saved="$BACKUP_DIR/awg-bot.conf.$(date +%Y%m%d_%H%M%S)"
    cp -a "$BOT_CONF" "$saved" || saved=""
  fi
  systemctl disable --now "$BOT_UNIT" &>/dev/null || true
  local arts=("${BOT_ARTIFACTS[@]}")
  # Код, venv и заметки нужны веб-панели — с ней остаются
  if web_installed; then
    arts=(); for p in "${BOT_ARTIFACTS[@]}"; do [[ "$p" == "$BOT_DIR" || "$p" == /var/lib/awg-bot ]] || arts+=("$p"); done
    info "Код бота остаётся — на нём работает веб-панель"
    rm -f "$BOT_ADMINS"           # приглашённые админы — бота, а не панели
  fi
  for p in "${arts[@]}"; do rm -rf "$p"; done
  systemctl daemon-reload
  systemctl reset-failed "$BOT_UNIT" &>/dev/null || true
  for p in "${arts[@]}"; do [[ -e "$p" ]] && left+=("$p"); done
  if (( ${#left[@]} )); then warn "Не удалось удалить: ${left[*]}"; else ok "Бот удалён"; fi
  [[ -n "$saved" ]] && info "Конфиг с токеном сохранён: $saved"
  log_info "бот удалён"
}

do_bot_menu() {
  local c v px
  while true; do
    echo ""
    hdr "Telegram-бот"
    if bot_installed; then
      if unit_active "$BOT_UNIT"; then echo -e "  Статус : ${G}● работает${N}"; else echo -e "  Статус : ${Y}○ остановлен${N}"; fi
      v=$(bot_version); px=$(bot_proxy_get)
      echo -e "  Версия : ${W}${v:-?}${N}"
      echo -e "  Прокси : $([[ -n "$px" ]] && bot_proxy_mask "$px" || echo "нет — напрямую")"
      echo ""
      echo -e "  ${C}1)${N} Обновить / переустановить"
      echo -e "  ${C}2)${N} Запустить"
      echo -e "  ${C}3)${N} Остановить"
      echo -e "  ${C}4)${N} Перезапустить"
      echo -e "  ${C}5)${N} Журнал"
      echo -e "  ${C}6)${N} Прокси до Telegram"
      echo -e "  ${R}7)${N} Удалить бота"
      echo -e "  ${C}8)${N} Mini App и HTTPS-сертификат"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-8]: ${N}" 0 8 0
    else
      echo -e "  ${D}Клиенты, сроки, туннели и статус из Telegram.${N}"
      echo -e "  ${C}1)${N} Установить бота"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-1]: ${N}" 0 1 0
    fi
    case "$c" in
      1) bot_install || warn "Установщик завершился с ошибкой" ;;
      2) systemctl start "$BOT_UNIT" && ok "Запущен" || err "Не запустился: journalctl -u $BOT_UNIT" ;;
      3) systemctl stop "$BOT_UNIT" && ok "Остановлен" || true ;;
      4) systemctl restart "$BOT_UNIT" && ok "Перезапущен" || err "Не запустился: journalctl -u $BOT_UNIT" ;;
      5) journalctl -u "$BOT_UNIT" -n 40 --no-pager 2>/dev/null || true ;;
      6) bot_proxy_menu || true ;;
      7) bot_uninstall || true ;;
      8) do_webapp_menu || true; continue ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ web ═════
# Веб-панель: та же панель, что Mini App бота, но в браузере по логину и
# паролю (служба awg-web, код — awg_bot: python -m awgbot.web). Telegram-бот
# ей не нужен: код и venv ставит тот же установщик с --web-only.
#
# Адрес — https://IP-или-домен:порт/<секретный путь>/; всё остальное на этом
# порту — 404. Пароль хранится только хешем scrypt в $WEB_CONF (600).
# Сертификат — тот же, что у Mini App (/etc/awg2/cert: Let's Encrypt на IP или
# домен, готовый сертификат сервера); его нет — самоподписанный.

web_installed() { [[ -f "/etc/systemd/system/$WEB_UNIT" ]]; }
web_active() { unit_active "$WEB_UNIT"; }
web_code_ready() { [[ -x "$BOT_VENV_PY" && -f "$BOT_DIR/awgbot/web.py" ]]; }

web_conf_get() { sed -n "s/^$1=//p" "$WEB_CONF" 2>/dev/null | tail -1; }
web_conf_set() {  # KEY значение
  { grep -v "^$1=" "$WEB_CONF" 2>/dev/null || true; echo "$1=$2"; } | write_file "$WEB_CONF" 600
}

web_host() { if cert_installed; then cert_get name; else public_ip_cached; fi; }
web_url() {
  local p path
  p=$(web_conf_get WEB_PORT); path=$(web_conf_get WEB_PATH)
  [[ -n "$p" && -n "$path" ]] || return 1
  echo "https://$(web_host):$p/$path/"
}

web_random_path() { tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 14; }
web_port_busy() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
web_random_port() {
  local p i
  for (( i = 0; i < 50; i++ )); do
    p=$(( RANDOM % 40000 + 20000 ))
    web_port_busy "$p" || { echo "$p"; return 0; }
  done
  return 1
}

# Пароль без эха; EOF — пусто
_read_secret() {
  local __var="$1" __v=""
  _flush_stdin
  IFS= read -rs -p "$(echo -e "$2")" __v || __v=""
  echo >&2
  printf -v "$__var" '%s' "$__v"
}

# Спросить пароль (Enter — сгенерировать) → WEB_NEW_HASH; сгенерированный — в WEB_PASS_SHOWN
web_ask_password() {
  local a b
  WEB_PASS_SHOWN="" WEB_NEW_HASH=""
  while true; do
    _read_secret a "${C}  Пароль (от 10 символов, Enter — сгенерировать): ${N}"
    [[ -n "$a" ]] || { web_gen_password; return; }
    (( ${#a} >= 10 )) || { warn "Нужно не меньше 10 символов"; continue; }
    # Вход принимает до 256 символов — длиннее не войти никогда
    (( ${#a} <= 256 )) || { warn "Не больше 256 символов"; continue; }
    _read_secret b "${C}  Ещё раз: ${N}"
    [[ "$a" == "$b" ]] && break
    warn "Пароли не совпали"
  done
  WEB_NEW_HASH=$(printf '%s' "$a" | py web-hash) && [[ "$WEB_NEW_HASH" == scrypt\$* ]]
}

# Новый случайный пароль → WEB_PASS_SHOWN (показать один раз) и WEB_NEW_HASH
web_gen_password() {
  WEB_PASS_SHOWN=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 18)
  [[ ${#WEB_PASS_SHOWN} -eq 18 ]] || return 1
  WEB_NEW_HASH=$(printf '%s' "$WEB_PASS_SHOWN" | py web-hash) && [[ "$WEB_NEW_HASH" == scrypt\$* ]]
}

# Код и venv панели: из распакованного архива (рядом, /root, /home) или из
# канала обновлений. Бот при этом не ставится и не трогается.
web_code_install() {
  local src installer
  src=$(_bot_local_src || true)
  if [[ -n "$src" && -f "$src/awgbot/web.py" && -f "${src%/awg_bot}/awg-bot-install.sh" ]]; then
    info "Код панели: $(shown "$src")"
    bash "${src%/awg_bot}/awg-bot-install.sh" --src "$src" --web-only
    return
  fi
  # Свой каталог (700): рядом с установщиком он ищет awg_bot/ (см. bot_install)
  mktmp installer -d || return 1
  installer+="/awg-bot-install.sh"
  curl -fsSL "$BOT_INSTALL_URL" -o "$installer" || { err "Не скачался установщик: $BOT_INSTALL_URL"; return 1; }
  if ! grep -q -- '--web-only' "$installer"; then
    err "В канале $(update_channel_label) веб-панели ещё нет — поставь её из архива с панелью"
    return 1
  fi
  AWG_REPO_URL="https://github.com/$UPDATE_REPO" bash "$installer" --web-only
}

web_write_unit() {
  write_unit "$WEB_UNIT" <<EOF
[Unit]
Description=AWG Toolza — веб-панель
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_VENV_PY -m awgbot.web
Environment=AWG_WEB_CONF=$WEB_CONF AWG_WEB_LOG=$WEB_LOG AWG2_BIN=$SCRIPT_PATH AWG_BOT_CONF=$BOT_CONF PYTHONUNBUFFERED=1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

web_restart() {
  local i
  systemctl enable "$WEB_UNIT" &>/dev/null || true
  systemctl restart "$WEB_UNIT" || true
  for (( i = 0; i < 8; i++ )); do sleep 1; web_active && break; done
  if web_active; then ok "Веб-панель работает"
  else err "Веб-панель не запустилась: journalctl -u ${WEB_UNIT%.service} -n 30"; return 1; fi
}

web_show_access() {
  success_box "Веб-панель: $(web_url)"
  echo -e "  Логин : ${W}$(web_conf_get WEB_USER)${N}"
  [[ -n "${WEB_PASS_SHOWN:-}" ]] && echo -e "  Пароль: ${W}$WEB_PASS_SHOWN${N} ${D}— сохрани: на сервере только хеш, больше не покажу${N}"
  cert_installed || warn "Сертификата нет — панель на самоподписанном, браузер предупредит. Настоящий: пункты «Сертификат»"
  return 0
}

_web_code_ensure() {
  web_code_ready && return 0
  web_code_install || return 1
  web_code_ready || { err "Код веб-панели не установился (нет $BOT_DIR/awgbot/web.py)"; return 1; }
}

web_install() {
  local user v
  _web_code_ensure || return 1
  user=$(web_conf_get WEB_USER)
  while true; do
    read_line v "${C}  Логин [Enter = ${user:-admin}]: ${N}"
    v="${v:-${user:-admin}}"
    [[ "$v" =~ ^[A-Za-z0-9._-]{3,32}$ ]] && break
    warn "Логин: 3-32 символа — латиница, цифры, . _ -"
  done
  user="$v"
  web_ask_password || { err "Пароль не захеширован"; return 1; }
  _web_setup "$user" && web_show_access
}

# Без вопросов (бот): логин — прежний или admin, пароль — новый случайный,
# его показывают один раз (WEB_PASS_SHOWN).
web_install_auto() {
  local user
  _web_code_ensure || return 1
  user=$(web_conf_get WEB_USER)
  web_gen_password || { err "Пароль не захеширован"; return 1; }
  _web_setup "${user:-admin}"
}

# Логин и хеш пароля, порт и секретный путь (прежние или случайные), UFW, служба.
_web_setup() {  # логин
  local user="$1" port path
  port=$(web_conf_get WEB_PORT); [[ -n "$port" ]] || port=$(web_random_port) || { err "Нет свободного порта"; return 1; }
  path=$(web_conf_get WEB_PATH); [[ -n "$path" ]] || path=$(web_random_path)
  web_conf_set WEB_USER "$user"
  web_conf_set WEB_PASS "$WEB_NEW_HASH"
  web_conf_set WEB_PORT "$port"
  web_conf_set WEB_PATH "$path"
  ufw_allow "$port/tcp" awg-web
  web_write_unit
  web_restart || return 1
  log_info "веб-панель установлена: порт $port"
}

# Новый случайный пароль; все сессии завершаются (служба перезапускается).
web_password_new() {
  web_installed || { err "Веб-панель не установлена"; return 1; }
  web_gen_password || { err "Пароль не захеширован"; return 1; }
  web_conf_set WEB_PASS "$WEB_NEW_HASH" && web_restart || return 1
  log_info "веб-панель: новый пароль"
  ok "Пароль сменён, все сессии завершены"
}

# Новый секретный путь: прежний адрес перестаёт открываться.
web_path_new() {
  web_installed || { err "Веб-панель не установлена"; return 1; }
  web_conf_set WEB_PATH "$(web_random_path)" && web_restart || return 1
  log_info "веб-панель: новый путь"
}

web_stop() {
  systemctl disable --now "$WEB_UNIT" &>/dev/null || { err "Веб-панель не остановилась"; return 1; }
  ok "Веб-панель остановлена"
}

web_set_port() {
  local v old
  old=$(web_conf_get WEB_PORT)
  read_line v "${C}  Порт (1024-65535, Enter — случайный): ${N}"
  [[ -n "$v" ]] || v=$(web_random_port) || return 1
  # 10#: «010000» — не восьмеричное 4096, а 10000 (так его прочтут Python и ufw)
  [[ "$v" =~ ^[0-9]{1,9}$ ]] && v=$((10#$v)) && (( v >= 1024 && v <= 65535 )) || { err "Порт: 1024-65535"; return 1; }
  [[ "$v" == "$old" ]] && return 0
  web_port_busy "$v" && { err "Порт $v занят"; return 1; }
  [[ "$v" == "$(server_port 2>/dev/null)" || "$v" == "$(webapp_port)" ]] && { err "Порт $v занят AWG или Mini App"; return 1; }
  web_conf_set WEB_PORT "$v"
  ufw_delete_comment awg-web
  ufw_allow "$v/tcp" awg-web
  web_restart && web_show_access
}

web_remove() {
  if [[ "${1:-}" != quiet ]]; then
    read_confirm "${R}  Удалить веб-панель? (введи yes): ${N}" || return 0
  fi
  remove_unit "$WEB_UNIT"
  systemctl daemon-reload
  rm -rf "$WEB_CONF" "$WEB_DIR" "$WEB_LOG"
  ufw_delete_comment awg-web
  # Код и venv ставились только ради панели — бот их не использует
  if [[ ! -f "/etc/systemd/system/$BOT_UNIT" ]]; then rm -rf "$BOT_DIR" /var/lib/awg-bot; fi
  ok "Веб-панель удалена"
  log_info "веб-панель удалена"
}

do_web_menu() {
  local c v n st
  while true; do
    echo ""
    hdr "Веб-панель"
    echo -e "  ${D}Все разделы Тулзы в браузере — вход по логину и паролю, без Telegram.${N}"
    if ! web_installed; then
      echo -e "  Статус     : ${D}не установлена${N}"
      echo ""
      echo -e "  ${G}1)${N} Установить"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-1]: ${N}" 0 1 0
      case "$c" in
        1) web_install || true ;;
        0) return 0 ;;
      esac
      pause
      continue
    fi
    if web_active; then st="${G}● работает${N}"; else st="${R}○ остановлена${N}"; fi
    echo -e "  Статус     : $st"
    echo -e "  Адрес      : ${W}$(web_url)${N}"
    echo -e "  Логин      : $(web_conf_get WEB_USER)"
    if cert_installed; then echo -e "  Сертификат : $(cert_state_line)"
    else echo -e "  Сертификат : ${Y}самоподписанный${N} ${D}— браузер предупреждает; настоящий — пункты 6-8${N}"; fi
    echo ""
    n=$(cert_find | grep -c . || true)
    echo -e "  ${C}1)${N} Перезапустить"
    echo -e "  ${C}2)${N} Сменить пароль"
    echo -e "  ${C}3)${N} Сменить логин"
    echo -e "  ${C}4)${N} Порт ${D}— $(web_conf_get WEB_PORT)${N}"
    echo -e "  ${C}5)${N} Новый секретный путь ${D}— старый адрес перестанет открываться${N}"
    echo -e "  ${C}6)${N} Сертификат на IP ${D}— Let's Encrypt, $(public_ip_cached)${N}"
    echo -e "  ${C}7)${N} Сертификат на домен"
    echo -e "  ${C}8)${N} Готовый сертификат сервера ${D}— найдено $n${N}"
    echo -e "  ${C}9)${N} Журнал входов"
    echo -e "  ${C}s)${N} $(web_active && echo "Остановить" || echo "Запустить")"
    echo -e "  ${C}u)${N} Обновить код панели ${D}— из архива или канала${N}"
    echo -e "  ${R}d)${N} Удалить веб-панель"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 9 0 "s|u|d"
    case "$c" in
      1) web_restart || true ;;
      2) web_ask_password && web_conf_set WEB_PASS "$WEB_NEW_HASH" && web_restart \
           && { ok "Пароль сменён, все сессии завершены"; [[ -n "$WEB_PASS_SHOWN" ]] \
           && echo -e "  Пароль: ${W}$WEB_PASS_SHOWN${N} ${D}— сохрани, больше не покажу${N}"; } ;;
      3) read_line v "${C}  Новый логин: ${N}"
         if [[ "$v" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then web_conf_set WEB_USER "$v" && web_restart && ok "Логин: $v"
         elif [[ -n "$v" ]]; then warn "Логин: 3-32 символа — латиница, цифры, . _ -"; fi ;;
      4) web_set_port || true ;;
      5) web_path_new && web_show_access ;;
      6) _cert_issue_menu ip ;;
      7) read_line v "${C}  Домен (A-запись → $(public_ip_cached)): ${N}"
         [[ -n "$v" ]] && _cert_issue_menu domain "$v" ;;
      8) _cert_use_menu ;;
      9) if [[ -s "$WEB_LOG" ]]; then tail -n 30 "$WEB_LOG"; else info "Журнал пуст"; fi ;;
      s) if web_active; then web_stop || true; else web_restart || true; fi ;;
      u) web_code_install && web_restart || true ;;
      d) web_remove; return 0 ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ antiscan ═════
# Антисканер: новые входящие подключения из сетей сканеров (РКН, СКИПА) и
# госорганов отбрасываются до служб сервера — SSH, Xray, панелей, Mini App.
# Сервер реже попадает в базы, которые собирают по итогам сканирований.
#
# Списки — публичные (shadow-netlab/traffic-guard-lists). Чужому списку на
# слово не верим: каждая запись проверяется, частные и служебные сети и
# слишком широкие подсети отбрасываются, короткий (оборванный) список не
# заменяет прежний.
#
# Как устроено: наборы ipset hash:net (IPv4 и IPv6) и одно правило первым в
# INPUT — DROP только НОВЫХ соединений: уже открытые (текущий SSH) не рвутся.
# Трафик клиентов через VPN (FORWARD) не трогается. Исключения — записи
# nomatch: адрес внутри подсети списка остаётся доступным. SSH-адрес, с
# которого включают, и адреса самого сервера попадают в исключения сами.
#
# Служба awg2-antiscan.service ставит наборы и правило при загрузке (раньше
# UFW и netfilter-persistent), таймер раз в час возвращает правило на место,
# если его сбросили или подвинули, и раз в сутки обновляет списки. Без сети
# работает на сохранённых списках. iptables-persistent не нужен.

# id<TAB>файл в репозитории списков<TAB>подпись<TAB>минимум записей
_antiscan_lists() {
  printf '%s\t%s\t%s\t%s\n' \
    scan antiscanner.list "Сканеры" 20 \
    skipa skipa.list "СКИПА — сканеры РКН" 20 \
    gov government_networks.list "Сети госорганов" 300
}

_antiscan_get() {  # КЛЮЧ — значение из antiscan.conf (файл не исполняется)
  sed -n "s/^$1=//p" "$ANTISCAN_CONF" 2>/dev/null | tail -1
}

_antiscan_set() {  # КЛЮЧ ЗНАЧЕНИЕ
  local v="${2//[$'\n\r']/ }"
  mkdir -p "$ANTISCAN_DIR" && chmod 700 "$ANTISCAN_DIR"
  { grep -v "^$1=" "$ANTISCAN_CONF" 2>/dev/null; printf '%s=%s\n' "$1" "$v"; } | write_file "$ANTISCAN_CONF" 600
}

_antiscan_log() { mkdir -p "$(dirname "$ANTISCAN_LOG")"; echo "[$(date '+%F %T')] $*" >> "$ANTISCAN_LOG"; }

# Включённые списки: id через пробел, только известные (по умолчанию все)
_antiscan_enabled_lists() {
  local want id out=()
  want=" $(_antiscan_get LISTS) "
  [[ "$want" == "  " ]] && want=" scan skipa gov "
  while IFS=$'\t' read -r id _; do
    [[ "$want" == *" $id "* ]] && out+=("$id")
  done < <(_antiscan_lists)
  echo "${out[*]}"
}

# Записи списка → нормализованные подсети одного семейства (4 или 6).
# allow=1 — для исключений: без запрета частных сетей и ширины.
_antiscan_parse() {  # 4|6 [allow]
  awk -v fam="$1" -v allow="${2:-0}" '
    function ip2n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
    function n2ip(n,  a, i) { for (i = 4; i >= 1; i--) { a[i] = n % 256; n = int(n / 256) }
                              return a[1] "." a[2] "." a[3] "." a[4] }
    BEGIN {
      # Частные, служебные, документационные и multicast: там сети самого
      # сервера и клиентов VPN, блокировать их нельзя ни при каком списке
      split("0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 " \
            "192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 " \
            "203.0.113.0/24 224.0.0.0/3", res, " ")
      for (i in res) { split(res[i], q, "/"); rs[i] = ip2n(q[1]); re[i] = rs[i] + 2 ^ (32 - q[2]) - 1 }
    }
    { sub(/#.*/, ""); gsub(/[ \t\r]/, "") }
    $0 == "" { next }
    fam == 4 && /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {
      split($0, p, "/"); len = (p[2] == "" ? 32 : p[2] + 0); split(p[1], o, ".")
      for (i = 1; i <= 4; i++) if (o[i] + 0 > 255 || o[i] ~ /^0[0-9]/) next
      if (len > 32 || (!allow && len < 12) || len < 8) next
      size = 2 ^ (32 - len); s = ip2n(p[1]); s -= s % size; e = s + size - 1
      if (!allow) for (i in rs) if (s <= re[i] && e >= rs[i]) next
      print n2ip(s) "/" len; next
    }
    fam == 6 && /:/ {
      if (split(tolower($0), p, "/") > 2) next
      ip = p[1]; len = (p[2] == "" ? 128 : p[2] + 0)
      if (p[2] != "" && p[2] !~ /^[0-9]+$/) next
      if (ip !~ /^[0-9a-f:]+$/ || ip ~ /:::/ || len > 128 || (!allow && len < 24) || len < 16) next
      t = ip; dbl = gsub(/::/, "", t)
      if (dbl > 1 || ip ~ /^:[^:]/ || ip ~ /[^:]:$/) next   # одинокое «:» с краю — не адрес, ipset restore упал бы целиком
      n = split(ip, g, ":"); cnt = 0
      for (i = 1; i <= n; i++) { if (length(g[i]) > 4) next; if (g[i] != "") cnt++ }
      if ((dbl == 0 && (n != 8 || cnt != 8)) || (dbl == 1 && cnt > 7)) next
      # Только глобальные адреса 2000::/3, без документационной 2001:db8::/32
      if (!allow && (g[1] !~ /^[23][0-9a-f][0-9a-f][0-9a-f]$/ || ip ~ /^2001:0?db8:/)) next
      print ip "/" len; next
    }
  '
}

# Подписи сетей из комментариев списка госсетей: «подсеть<TAB>организация».
_antiscan_names() {
  awk '
    /^# Networks announced by/ { org = ""; asn = ""; next }
    /^# AS-Name:/ { asn = $0; sub(/^# AS-Name:[ \t]*/, "", asn); next }
    /^#/ { if (org == "" && asn != "") { org = $0; sub(/^#[ \t]*/, "", org) } next }
    NF { n = $1; sub(/\/(32|128)$/, "", n); print n "\t" substr(org != "" ? org : asn, 1, 80) }
  ' | tr -d '\000-\010\013-\037\177'
}

# Адреса, которые не блокируются никогда: адреса сервера и SSH-сессии
# (текущая — из SSH_CONNECTION, остальные — установленные соединения sshd).
_antiscan_server_addrs() { ip -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'; }

# Отпечаток адресов сервера: на загрузке (служба раньше сети) их ещё нет, а при
# смене адреса исключения устаревают — таймер пересобирает набор, если он другой
_antiscan_addr_sig() { _antiscan_server_addrs | sort -u | cksum | cut -d' ' -f1; }

_antiscan_auto_allow() {
  {
    _antiscan_server_addrs
    [[ -n "${SSH_CONNECTION:-}" ]] && echo "${SSH_CONNECTION%% *}"
    ss -tnpH state established 2>/dev/null | awk '/"sshd/ {print $4}' | sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/'
  } | sed 's/^::ffff://' | grep -E '^[0-9a-fA-F.:]+$' | sort -u
}

_antiscan_ssh_peers() {
  {
    [[ -n "${SSH_CONNECTION:-}" ]] && echo "${SSH_CONNECTION%% *}"
    ss -tnpH state established 2>/dev/null | awk '/"sshd/ {print $4}' | sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/'
  } | sed 's/^::ffff://' | grep -E '^[0-9a-fA-F.:]+$' | sort -u
}

# Адрес, с которого включают из панели или Mini App: бот передаёт в
# AWG_CLIENT_IP адрес самого соединения (не X-Forwarded-For). Не адрес — пропуск.
_antiscan_client_ip() {
  local a="${AWG_CLIENT_IP:-}"
  a="${a#::ffff:}"
  [[ "$a" =~ ^[0-9A-Fa-f.:]{2,39}$ ]] || return 0
  if valid_ip "$a" || [[ -n "$(printf '%s\n' "$a" | _antiscan_parse 6 1)" ]]; then echo "${a,,}"; fi
}

# Записей, охват IPv4 (адресов) и IPv6 (сетей /32 — по записям /32 и шире)
# в разобранном списке. %.0f, а не %d: mawk обрезал бы большие числа до 2^31
_antiscan_span() {
  awk -F/ '{ n++; if ($1 ~ /:/) { if ($2 <= 32) s6 += 2 ^ (32 - $2) } else s4 += 2 ^ (32 - $2) }
    END { printf "%d %.0f %.0f\n", n, s4, s6 }'
}

# Скачать включённые списки. Оборванный или пустой ответ прежний список не
# заменяет. Ошибки — в ERROR, время удачного обновления — в UPDATED.
_antiscan_fetch_all() {
  local id file label min tmp n s4 s6 errs=() ok=0
  mkdir -p "$ANTISCAN_DIR/lists"
  while IFS=$'\t' read -r id file label min; do
    [[ " $(_antiscan_enabled_lists) " == *" $id "* ]] || continue
    tmp=$(mktemp "$ANTISCAN_DIR/.dl.XXXXXX") || return 1
    if ! curl -fsS --proto '=https' --max-time 40 --max-filesize 8000000 -o "$tmp" "$ANTISCAN_SRC/$file" 2>/dev/null; then
      errs+=("$label: не скачался"); rm -f "$tmp"; continue
    fi
    read -r n s4 s6 < <({ _antiscan_parse 4 < "$tmp"; _antiscan_parse 6 < "$tmp"; } | _antiscan_span)
    if (( n < min || n > 200000 )); then   # 200000 — предел _antiscan_apply_in: раздутый список прежний не вытесняет
      errs+=("$label: в ответе $n записей — оставлен прежний"); rm -f "$tmp"; continue
    fi
    if (( s4 > ANTISCAN_MAX4 || s6 > ANTISCAN_MAX6 )); then
      errs+=("$label: слишком широкий охват (IPv4 $s4 адресов, IPv6 $s6 сетей /32) — оставлен прежний"); rm -f "$tmp"; continue
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$ANTISCAN_DIR/lists/$id.list"
    ok=$((ok + 1))
  done < <(_antiscan_lists)
  if (( ${#errs[@]} )); then
    _antiscan_set ERROR "${errs[*]}"
    _antiscan_log "списки: ${errs[*]}"
  else
    _antiscan_set ERROR ""
    _antiscan_set UPDATED "$(date +%s)"
  fi
  (( ok > 0 ))
}

_antiscan_rule() {  # набор → ANTISCAN_RULE
  ANTISCAN_RULE=(-m conntrack --ctstate NEW -m set --match-set "$1" src -m comment --comment "$ANTISCAN_TAG" -j DROP)
}

# Правило — выше всего, что может пропустить снаружи: ACCEPT и переходы в
# чужие цепочки (UFW, fail2ban), вставленные позже, иначе пропускали бы сканер
# раньше него. Сдвинуто ниже — снимается и ставится первым.
_antiscan_rule_up() {  # iptables|ip6tables набор
  local ipt="$1"
  _antiscan_rule "$2"
  if "$ipt" -C INPUT "${ANTISCAN_RULE[@]}" 2>/dev/null; then
    _antiscan_rule_first "$ipt" && return 0
    while "$ipt" -D INPUT "${ANTISCAN_RULE[@]}" 2>/dev/null; do :; done
  fi
  "$ipt" -I INPUT 1 "${ANTISCAN_RULE[@]}"
}

_antiscan_rule_down() {  # iptables|ip6tables набор
  local guard=0
  command -v "$1" &>/dev/null || return 0
  _antiscan_rule "$2"
  while (( guard++ < 32 )) && "$1" -D INPUT "${ANTISCAN_RULE[@]}" 2>/dev/null; do :; done
  return 0
}

# Выше нашего правила можно только то, что сканер не пропускает: DROP и
# REJECT (порт WireGuard обфускатора) и правила для своих интерфейсов Тулзы
# (ACCEPT DNS с awg0) — их трафик и так не из внешних сетей.
_antiscan_rule_first() {  # iptables|ip6tables
  "$1" -S INPUT 2>/dev/null | awk -v tag="$ANTISCAN_TAG" -v own=" $OWN_IFACES lo " '
    $1 != "-A" { next }
    {
      for (i = 1; i <= NF; i++) if ($i == "--comment" && ($(i + 1) == tag || $(i + 1) == "\"" tag "\"")) { ok = 1; exit }
      for (i = 1; i <= NF; i++) if ($i == "-j" && ($(i + 1) == "DROP" || $(i + 1) == "REJECT")) next
      for (i = 2; i < NF; i++) if ($i == "-i" && $(i - 1) != "!" && index(own, " " $(i + 1) " ")) next
      exit
    }
    END { exit !ok }'
}

# Правила на месте: есть набор — правило выше всего, что пропускает снаружи
antiscan_rules_ok() {
  ipset list -n "$ANTISCAN_SET" &>/dev/null && _antiscan_rule_first iptables || return 1
  if ipset list -n "$ANTISCAN_SET6" &>/dev/null; then _antiscan_rule_first ip6tables || return 1; fi
  return 0
}

# Загрузить набор атомарно: новый под временным именем, затем swap —
# правило не остаётся без набора ни на миг.
_antiscan_load() {  # набор inet|inet6 файл_записей файл_исключений
  local set="$1" family="$2" tmpset="${1}-new" n
  n=$(wc -l < "$3")
  {
    echo "create $tmpset hash:net family $family hashsize 4096 maxelem 262144 counters -exist"
    echo "flush $tmpset"
    sed "s|^|add $tmpset |; s|$| -exist|" "$3"
    sed "s|^|add $tmpset |; s|$| nomatch -exist|" "$4"
  } | ipset restore || { ipset destroy "$tmpset" 2>/dev/null; return 1; }
  ipset create "$set" hash:net family "$family" hashsize 4096 maxelem 262144 counters -exist || return 1
  ipset swap "$tmpset" "$set" && ipset destroy "$tmpset"
  echo "$n"
}

# Подсети со входа (нормализованные _antiscan_parse), которые лежат целиком
# внутри (in) или не внутри (out) какой-нибудь подсети из файла. Сравнение по
# префиксу группами по 16 бит (IPv4 — две, IPv6 — восемь): без чисел больше
# 2^16 — mawk считает в double. Каждая длина префикса из файла — один поиск.
_antiscan_inside() {  # in|out файл
  awk -v mode="$1" -v f="$2" '
    function hex(h,  i, v) { v = 0; for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return v }
    function net(s,  p, a, b, i, n, hn, tn) {   # → F (4|6), L, G[1..8]
      split(s, p, "/")
      if (p[1] ~ /:/) {
        F = 6; L = (p[2] == "" ? 128 : p[2] + 0); s = tolower(p[1]); i = index(s, "::")
        if (i) { hn = (i > 1 ? split(substr(s, 1, i - 1), a, ":") : 0); tn = (substr(s, i + 2) != "" ? split(substr(s, i + 2), b, ":") : 0) }
        else { hn = split(s, a, ":"); tn = 0 }
        for (n = 1; n <= hn; n++) G[n] = hex(a[n])
        for (; n <= 8 - tn; n++) G[n] = 0
        for (i = 1; i <= tn; i++) G[n++] = hex(b[i])
      } else {
        F = 4; L = (p[2] == "" ? 32 : p[2] + 0); split(p[1], a, ".")
        G[1] = a[1] * 256 + a[2]; G[2] = a[3] * 256 + a[4]
      }
    }
    function key(len,  k, i) {
      k = F
      for (i = 1; i <= int(len / 16); i++) k = k ":" G[i]
      if (len % 16) k = k ":" int(G[i] / 2 ^ (16 - len % 16))
      return k
    }
    BEGIN {
      while ((getline l < f) > 0) {
        if (l == "") continue
        net(l); nets[key(L)] = 1
        if (!((F, L) in seen)) { seen[F, L] = 1; nl[F]++; ll[F, nl[F]] = L }
      }
    }
    NF {
      net($1); hit = 0
      for (j = 1; j <= nl[F] && !hit; j++) if (ll[F, j] <= L && (key(ll[F, j]) in nets)) hit = 1
      if (hit == (mode == "in")) print
    }'
}

# Адрес (IPv4 или IPv6) внутри какой-нибудь подсети из файла?
_antiscan_covers() {  # файл адрес
  local n
  [[ "$2" != */* ]] || return 1
  n=$(printf '%s\n' "$2" | _antiscan_parse 4 1; printf '%s\n' "$2" | _antiscan_parse 6 1)
  [[ -n "$n" && -n "$(printf '%s\n' "$n" | _antiscan_inside in "$1")" ]]
}

# Собрать наборы из сохранённых списков и поставить правила.
_antiscan_apply() {
  local d rc=0
  # Выключили, пока качались списки (выключение ждёт замок не дольше 20 с), —
  # правило обратно не ставить
  [[ "$(_antiscan_get ON)" == 1 ]] || { antiscan_down; return 0; }
  d=$(mktemp -d "$ANTISCAN_DIR/.apply.XXXXXX") || return 1
  _antiscan_apply_in "$d" || rc=$?
  rm -rf "$d"
  return "$rc"
}

_antiscan_apply_in() {  # временный каталог
  local d="$1" id ip who n4 n6=0
  : > "$d/v4"; : > "$d/v6"
  for id in $(_antiscan_enabled_lists); do
    [[ -f "$ANTISCAN_DIR/lists/$id.list" ]] || continue
    _antiscan_parse 4 < "$ANTISCAN_DIR/lists/$id.list" >> "$d/v4"
    _antiscan_parse 6 < "$ANTISCAN_DIR/lists/$id.list" >> "$d/v6"
  done
  sort -u -o "$d/v4" "$d/v4"; sort -u -o "$d/v6" "$d/v6"
  if [[ ! -s "$d/v4" && ! -s "$d/v6" ]]; then
    _antiscan_log "нечего применять: списки ещё не скачаны"
    return 3
  fi
  if (( $(wc -l < "$d/v4") + $(wc -l < "$d/v6") > 200000 )); then
    _antiscan_log "в списках больше 200000 записей — не применяю"
    return 4
  fi
  [[ -f "$ANTISCAN_DIR/lists/gov.list" ]] && _antiscan_names < "$ANTISCAN_DIR/lists/gov.list" > "$ANTISCAN_DIR/names"
  # Адрес админа внутри списка — SSH-сессии и того, кто включает из панели, —
  # в исключения насовсем: иначе после следующего обновления он бы не вошёл
  _antiscan_allow_rows > "$d/allow"
  { _antiscan_parse 4 1 < "$d/allow"; _antiscan_parse 6 1 < "$d/allow"; } > "$d/al"
  while read -r ip who; do
    _antiscan_covers "$d/v4" "$ip" || _antiscan_covers "$d/v6" "$ip" || continue
    _antiscan_covers "$d/al" "$ip" && continue
    printf '%s # %s — добавлен сам %s\n' "$ip" "$who" "$(date '+%F')" >> "$ANTISCAN_ALLOW"
    chmod 600 "$ANTISCAN_ALLOW"
    printf '%s\n' "$ip" | _antiscan_parse 4 1 >> "$d/al"; printf '%s\n' "$ip" | _antiscan_parse 6 1 >> "$d/al"
    _antiscan_log "$who: адрес $ip есть в списке — добавлен в исключения"
  done < <(_antiscan_ssh_peers | sed 's/$/ SSH/'; _antiscan_client_ip | sed 's/$/ панель/')
  { _antiscan_allow_rows; _antiscan_auto_allow; } > "$d/allow"
  _antiscan_parse 4 1 < "$d/allow" | sort -u > "$d/a4"
  _antiscan_parse 6 1 < "$d/allow" | sort -u > "$d/a6"
  # Запись списка целиком внутри исключения в набор не идёт: в hash:net
  # побеждает самый узкий префикс, и «1.2.3.77/32» из списка перекрыла бы
  # исключение «1.2.3.0/24 nomatch». Записи шире исключения остаются.
  _antiscan_inside out "$d/a4" < "$d/v4" > "$d/v4.f" && mv -f "$d/v4.f" "$d/v4"
  _antiscan_inside out "$d/a6" < "$d/v6" > "$d/v6.f" && mv -f "$d/v6.f" "$d/v6"
  n4=$(_antiscan_load "$ANTISCAN_SET" inet "$d/v4" "$d/a4") || { _antiscan_log "ipset: набор IPv4 не загрузился"; return 5; }
  _antiscan_rule_up iptables "$ANTISCAN_SET" || { _antiscan_log "iptables: правило не поставилось"; return 5; }
  if [[ -s "$d/v6" ]] && command -v ip6tables &>/dev/null \
      && n6=$(_antiscan_load "$ANTISCAN_SET6" inet6 "$d/v6" "$d/a6") \
      && _antiscan_rule_up ip6tables "$ANTISCAN_SET6"; then
    :
  else
    n6=0
    _antiscan_rule_down ip6tables "$ANTISCAN_SET6"
    ipset destroy "$ANTISCAN_SET6" 2>/dev/null || true
  fi
  _antiscan_set ENTRIES "$n4 $n6"
  _antiscan_set ADDRS "$(_antiscan_addr_sig)"
  _antiscan_log "применено: IPv4 $n4, IPv6 $n6"
  return 0
}

_antiscan_allow_rows() { grep -v '^\s*#' "$ANTISCAN_ALLOW" 2>/dev/null | awk 'NF {print $1}'; }

antiscan_down() {
  _antiscan_rule_down iptables "$ANTISCAN_SET"
  _antiscan_rule_down ip6tables "$ANTISCAN_SET6"
  command -v ipset &>/dev/null || return 0
  ipset destroy "$ANTISCAN_SET" 2>/dev/null || true
  ipset destroy "$ANTISCAN_SET6" 2>/dev/null || true
  # временные наборы замены — остаются, если загрузку прервали
  ipset destroy "$ANTISCAN_SET-new" 2>/dev/null || true
  ipset destroy "$ANTISCAN_SET6-new" 2>/dev/null || true
  return 0
}

# Точка входа службы и таймера (и awg2): apply | update | heal | off.
antiscan_run() {
  local mode="${1:-heal}" rc=0 upd
  mkdir -p "$ANTISCAN_DIR" && chmod 700 "$ANTISCAN_DIR"
  exec 9>"$ANTISCAN_DIR/.lock"
  flock -w 180 9 || { _antiscan_log "$mode: занято другой операцией"; return 75; }
  if [[ "$mode" == off || "$(_antiscan_get ON)" != 1 ]]; then
    antiscan_down
    return 0
  fi
  case "$mode" in
    update) _antiscan_fetch_all || true; _antiscan_apply || rc=$? ;;
    apply) _antiscan_apply || rc=$? ;;
    heal)
      touch "$ANTISCAN_DIR/heal"
      upd=$(_antiscan_get UPDATED)
      if (( $(date +%s) - ${upd:-0} > 86400 )); then
        _antiscan_fetch_all || true
        _antiscan_apply || rc=$?
      elif ! antiscan_rules_ok || [[ "$(_antiscan_addr_sig)" != "$(_antiscan_get ADDRS)" ]]; then
        _antiscan_log "правило пропало или сдвинуто, либо адреса сервера сменились — применяю заново"
        _antiscan_apply || rc=$?
      fi ;;
    *) echo "использование: ${0##*/} apply|update|heal|off" >&2; return 2 ;;
  esac
  return "$rc"
}

# ── Установка ─────────────────────────────────────────────
_antiscan_emit() {
  emit_script "$ANTISCAN_SCRIPT" 'antiscan_run "$@"' \
    ANTISCAN_DIR ANTISCAN_CONF ANTISCAN_ALLOW ANTISCAN_LOG ANTISCAN_SET ANTISCAN_SET6 ANTISCAN_TAG ANTISCAN_SRC \
    OWN_IFACES \
    ANTISCAN_MAX4 ANTISCAN_MAX6 \
    write_file valid_ip _antiscan_lists _antiscan_get _antiscan_set _antiscan_log _antiscan_enabled_lists _antiscan_parse \
    _antiscan_names _antiscan_server_addrs _antiscan_addr_sig _antiscan_auto_allow _antiscan_ssh_peers _antiscan_client_ip \
    _antiscan_span _antiscan_fetch_all _antiscan_rule _antiscan_rule_up \
    _antiscan_rule_down _antiscan_rule_first antiscan_rules_ok _antiscan_load _antiscan_inside _antiscan_covers _antiscan_allow_rows \
    _antiscan_apply _antiscan_apply_in antiscan_down \
    antiscan_run || return 1
  # Раньше UFW и netfilter-persistent, как сам ufw.service: их правила
  # встанут после нашего, а восстановление iptables-persistent найдёт набор
  write_unit "$ANTISCAN_UNIT" <<EOF
[Unit]
Description=AWG Toolza — антисканер: сети сканеров не доходят до служб сервера
DefaultDependencies=no
Wants=network-pre.target local-fs.target
After=local-fs.target systemd-modules-load.service
Before=network-pre.target ufw.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ANTISCAN_SCRIPT apply

[Install]
WantedBy=multi-user.target
EOF
  write_unit "${ANTISCAN_TIMER%.timer}.service" <<EOF
[Unit]
Description=AWG Toolza — антисканер: правило на месте, списки раз в сутки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ANTISCAN_SCRIPT heal
EOF
  write_unit "$ANTISCAN_TIMER" <<'EOF'
[Unit]
Description=AWG Toolza — антисканер: проверка раз в час

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
}

antiscan_on() { [[ "$(_antiscan_get ON)" == 1 ]]; }

antiscan_enable() {
  local rc=0
  need_cmds ipset:ipset flock:util-linux || return 1
  [[ -n "$(_antiscan_get LISTS)" ]] || _antiscan_set LISTS "scan skipa gov"
  _antiscan_set ON 1
  _antiscan_emit || { err "Не удалось записать службу антисканера"; return 1; }
  info "Скачиваю и проверяю списки..."
  "$ANTISCAN_SCRIPT" update || rc=$?
  if (( rc )); then
    _antiscan_set ON 0
    "$ANTISCAN_SCRIPT" off &>/dev/null || true
    case $rc in
      3) err "Списки не скачались: $(_antiscan_get ERROR)" ;;
      75) err "Антисканер занят другой операцией — повтори через минуту" ;;
      *) err "Не удалось применить правила (код $rc) — журнал: $ANTISCAN_LOG" ;;
    esac
    return 1
  fi
  systemctl enable "$ANTISCAN_UNIT" &>/dev/null || true
  systemctl enable --now "$ANTISCAN_TIMER" &>/dev/null || true
  log_info "антисканер включён"
  ok "Антисканер включён: $(antiscan_summary)"
  [[ -n "$(_antiscan_get ERROR)" ]] && warn "$(_antiscan_get ERROR)"
  return 0
}

antiscan_disable() {
  local held=0
  _antiscan_set ON 0
  remove_unit "$ANTISCAN_TIMER" "${ANTISCAN_TIMER%.timer}.service" "$ANTISCAN_UNIT"
  # Замок прохода таймера: проход, уже увидевший ON=1, иначе поставил бы правило
  # обратно после нас. Не дольше 20 с — качающий проход сам увидит ON=0 перед применением
  mkdir -p "$ANTISCAN_DIR" && chmod 700 "$ANTISCAN_DIR"
  exec 9>"$ANTISCAN_DIR/.lock"
  flock -w 20 9 && held=1
  antiscan_down
  (( held )) || _antiscan_log "выключение: замок занят дольше 20 с — снято без него"
  exec 9>&-
  log_info "антисканер выключен"
  ok "Антисканер выключен — правила и наборы сняты"
}

antiscan_update() {
  antiscan_on || { err "Антисканер выключен"; return 1; }
  _antiscan_emit || return 1
  "$ANTISCAN_SCRIPT" update || { err "Не удалось применить списки — журнал: $ANTISCAN_LOG"; return 1; }
  if [[ -n "$(_antiscan_get ERROR)" ]]; then warn "$(_antiscan_get ERROR)"; fi
  ok "Списки обновлены: $(antiscan_summary)"
}

# Какие списки блокировать: id через запятую или пробел (хотя бы один)
antiscan_lists_set() {
  local want=" ${*//,/ } " id out=()
  while IFS=$'\t' read -r id _; do [[ "$want" == *" $id "* ]] && out+=("$id"); done < <(_antiscan_lists)
  (( ${#out[@]} )) || { err "Нужен хотя бы один список: scan, skipa, gov"; return 1; }
  _antiscan_set LISTS "${out[*]}"
  antiscan_on || { ok "Списки: ${out[*]}"; return 0; }
  if ! { _antiscan_emit && "$ANTISCAN_SCRIPT" update; }; then err "Не удалось применить — журнал: $ANTISCAN_LOG"; return 1; fi
  ok "Списки: ${out[*]} — $(antiscan_summary)"
}

# Исключение — адрес или подсеть IPv4/IPv6
antiscan_allow() {  # add|del АДРЕС
  local op="${1:-}" v="${2:-}" norm short m
  norm=$(printf '%s\n' "$v" | _antiscan_parse 4 1)
  [[ -n "$norm" ]] || norm=$(printf '%s\n' "$v" | _antiscan_parse 6 1)
  # Верный адрес со слишком широкой маской — своим текстом, а не «нужен адрес»
  if [[ -z "$norm" && "$v" =~ ^[0-9A-Fa-f.:]+/([0-9]{1,3})$ ]]; then
    m=$((10#${BASH_REMATCH[1]}))
    if { (( m < 8 )) && valid_ip "${v%/*}"; } || { (( m < 16 )) && [[ -n "$(printf '%s\n' "${v%/*}" | _antiscan_parse 6 1)" ]]; }; then
      err "Слишком широкая подсеть $(shown "$v"): исключение — не шире /8 для IPv4 и /16 для IPv6"; return 1
    fi
  fi
  [[ -n "$norm" && "$v" != *[[:space:]]* && "$norm" != *$'\n'* ]] \
    || { err "Нужен IPv4 или IPv6 адрес (можно с /маской): $(shown "$v")"; return 1; }
  short="${norm%/32}"; short="${short%/128}"
  mkdir -p "$ANTISCAN_DIR" && chmod 700 "$ANTISCAN_DIR"
  touch "$ANTISCAN_ALLOW" && chmod 600 "$ANTISCAN_ALLOW"
  case "$op" in
    add) _antiscan_allow_rows | grep -qxF -e "$norm" -e "$short" || echo "$norm" >> "$ANTISCAN_ALLOW" ;;
    del) _antiscan_allow_rows | grep -qxF -e "$norm" -e "$short" || { err "Такого исключения нет: $norm"; return 1; }
         awk -v n="$norm" -v s="$short" '$1 != n && $1 != s' "$ANTISCAN_ALLOW" > "$ANTISCAN_ALLOW.new"
         mv -f "$ANTISCAN_ALLOW.new" "$ANTISCAN_ALLOW"; chmod 600 "$ANTISCAN_ALLOW" ;;
    *) err "allow add|del АДРЕС"; return 2 ;;
  esac
  if antiscan_on; then
    if ! { _antiscan_emit && "$ANTISCAN_SCRIPT" apply; }; then err "Не удалось применить — журнал: $ANTISCAN_LOG"; return 1; fi
  fi
  ok "Исключения: $([[ "$op" == add ]] && echo "добавлен" || echo "убран") $norm"
}

# Отбито пакетов новых подключений с установки правила: обновление списков счётчик не
# сбрасывает, перезагрузка и переустановка правила — сбрасывают
antiscan_dropped() {
  { iptables-save -c -t filter 2>/dev/null; ip6tables-save -c -t filter 2>/dev/null; } \
    | awk -v tag="$ANTISCAN_TAG" 'index($0, "--comment " tag) && /^\[/ {
        split(substr($1, 2), c, ":"); n += c[1] } END { print n + 0 }'
}

# Чаще всего стучавшиеся подсети: «пакетов<TAB>подсеть<TAB>организация»
antiscan_top() {
  local n="${1:-5}"
  { ipset list "$ANTISCAN_SET" 2>/dev/null; ipset list "$ANTISCAN_SET6" 2>/dev/null; } \
    | awk '$2 == "packets" && $3 > 0 {print $3 "\t" $1}' | sort -t$'\t' -k1,1nr | head -n "$n" \
    | awk -F'\t' -v names="$ANTISCAN_DIR/names" '
        BEGIN { while ((getline l < names) > 0) { split(l, a, "\t"); org[a[1]] = a[2] } }
        { k = $2; sub(/\/(32|128)$/, "", k); print $1 "\t" $2 "\t" org[k] }'
}

antiscan_summary() {
  local e
  read -r -a e <<< "$(_antiscan_get ENTRIES)"
  echo "подсетей IPv4 ${e[0]:-0}, IPv6 ${e[1]:-0}"
}

# ── Меню ──────────────────────────────────────────────────
_antiscan_show() {
  local id file label min on n upd err ssh
  hdr "Антисканер"
  echo -e "  ${D}Новые входящие подключения из сетей сканеров РКН и госорганов"
  echo -e "  отбрасываются до SSH, Xray и панелей. VPN-трафик клиентов не трогается.${N}"
  echo ""
  if antiscan_on; then
    if antiscan_rules_ok; then echo -e "  Состояние : ${G}● включён${N} — $(antiscan_summary)"
    else echo -e "  Состояние : ${Y}▲ включён, правило не на месте${N} — вернёт таймер или «Обновить списки»"; fi
    echo -e "  Отбито    : ${W}$(antiscan_dropped)${N} ${D}новых подключений с установки правила (сбрасывается при перезагрузке)${N}"
  else
    echo -e "  Состояние : ${D}○ выключен${N}"
  fi
  upd=$(_antiscan_get UPDATED)
  [[ -n "$upd" ]] && echo -e "  Списки    : обновлены $(date -d "@$upd" '+%d.%m.%Y %H:%M' 2>/dev/null)"
  err=$(_antiscan_get ERROR)
  [[ -n "$err" ]] && echo -e "  ${Y}▲ $err${N}"
  while IFS=$'\t' read -r id file label min; do
    on="${D}○${N}"; [[ " $(_antiscan_enabled_lists) " == *" $id "* ]] && on="${G}●${N}"
    n=0; [[ -f "$ANTISCAN_DIR/lists/$id.list" ]] && n=$(( $(_antiscan_parse 4 < "$ANTISCAN_DIR/lists/$id.list" | wc -l) + $(_antiscan_parse 6 < "$ANTISCAN_DIR/lists/$id.list" | wc -l) ))
    echo -e "    $on $label ${D}— $n подсетей${N}"
  done < <(_antiscan_lists)
  n=$(_antiscan_allow_rows | wc -l)
  echo -e "  Исключения: ${W}$n${N}${D} + адреса сервера и SSH-сессий${N}"
  ssh=$(_antiscan_ssh_peers | head -3 | tr '\n' ' ')
  [[ -n "$ssh" ]] && echo -e "  ${D}Твой SSH: $ssh— не блокируется${N}"
}

do_antiscan_menu() {
  local c v id file label min
  while true; do
    echo ""
    _antiscan_show
    echo ""
    if antiscan_on; then echo -e "  ${C}1)${N} Выключить"; else echo -e "  ${C}1)${N} Включить"; fi
    echo -e "  ${C}2)${N} Обновить списки сейчас"
    echo -e "  ${C}3)${N} Списки — что блокировать"
    echo -e "  ${C}4)${N} Исключения — добавить адрес"
    echo -e "  ${C}5)${N} Исключения — убрать адрес"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-5]: ${N}" 0 5 0
    case "$c" in
      1) if antiscan_on; then antiscan_disable
         else
           # Включение отрезает целые сети — сначала сказать, кого это заденет
           echo -e "  ${Y}Новые подключения из сетей списков не пройдут — и клиентов VPN, и, может быть, тебя"
           echo -e "  самого с другого адреса. Адрес этой SSH-сессии попадёт в исключения сам.${N}"
           echo -e "  ${D}Выключить можно здесь или в боте: «Сервер → Антисканер».${N}"
           ask_yes "  Включить антисканер? [y/N]: " n && { antiscan_enable || true; }
         fi ;;
      2) antiscan_update || true ;;
      3) echo ""
         while IFS=$'\t' read -r id file label min; do echo -e "  ${C}$id${N} — $label"; done < <(_antiscan_lists)
         read_line v "${C}  Какие блокировать (через пробел) [$(_antiscan_enabled_lists)]: ${N}"
         [[ -n "$v" ]] && { antiscan_lists_set "$v" || true; } ;;
      4) read_line v "${C}  Адрес или подсеть (1.2.3.4 или 1.2.3.0/24): ${N}"
         [[ -n "$v" ]] && { antiscan_allow add "$v" || true; } ;;
      5) _antiscan_allow_rows | sed 's/^/    /'
         read_line v "${C}  Какой убрать: ${N}"
         [[ -n "$v" ]] && { antiscan_allow del "$v" || true; } ;;
      0) return 0 ;;
    esac
    pause
  done
}

# Таймер молчит дольше трёх часов (сброшен, заглох) — перезапустить
antiscan_watchdog() {
  local age
  antiscan_on || return 0
  [[ -f "$ANTISCAN_DIR/heal" ]] || return 0
  age=$(( $(date +%s) - $(stat -c %Y "$ANTISCAN_DIR/heal" 2>/dev/null || echo 0) ))
  (( age < 10800 )) && return 0
  touch "$ANTISCAN_DIR/heal"
  timer_heal "$ANTISCAN_TIMER"
  systemctl start --no-block "${ANTISCAN_TIMER%.timer}.service" &>/dev/null || true
}

antiscan_remove() {
  remove_unit "$ANTISCAN_TIMER" "${ANTISCAN_TIMER%.timer}.service" "$ANTISCAN_UNIT"
  antiscan_down
  rm -rf "$ANTISCAN_DIR" "$ANTISCAN_SCRIPT" "$ANTISCAN_LOG"
}

# ═════ uninstall ═════
# Очистка клиентов и полное удаление.

do_clean_clients() {
  local n
  server_exists || { err "Сервер не создан"; return 1; }
  n=$(grep -c '^\[Peer\]' "$SERVER_CONF" || true)
  (( n )) || { info "Клиентов нет"; return 0; }
  warn "Будут удалены все клиенты ($n) и их конфиги в $CLIENT_DIR"
  read_confirm "${R}  Подтверди (введи yes): ${N}" || return 0
  clients_clean
}

clients_clean() {
  local n
  server_exists || { err "Сервер не создан"; return 1; }
  n=$(grep -c '^\[Peer\]' "$SERVER_CONF" || true)
  auto_backup clean || warn "Авто-бэкап не удался"
  py peers-clear "$SERVER_CONF" || { err "Конфиг не изменён"; return 1; }
  rm -f "$CLIENT_DIR"/*_awg[23].conf
  : > "$WARP_PEERS" 2>/dev/null || true
  [[ -f "$XRAY_PEERS" ]] && : > "$XRAY_PEERS"
  [[ -f "$EXITS_PEERS" ]] && : > "$EXITS_PEERS"
  server_apply
  ok "Клиенты удалены: $n"
  log_info "удалены все клиенты ($n)"
}

# Все туннели: службы, правила и настройки. Бэкап делается до вызова.
tunnels_remove_all() {
  local n
  tunnels_panic_reset quiet
  for n in $(exits_nodes); do systemctl disable --now "awg-quick@awg-exit-$n" &>/dev/null || true; done
  remove_unit awg-warp.service awg-usque.service awg-warp-healthcheck.timer awg-warp-healthcheck.service \
    "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" awg-xray-rugeo.timer awg-xray-rugeo.service \
    "$T2S_UNIT" "$EXITS_UNIT" awg-dns-persist.service awg-dns-healthcheck.timer awg-dns-healthcheck.service
  cascade_uninstall quiet
  if [[ -f "$DNS_PROXY_STATE" ]]; then
    dns_rules_down
    ufw_delete_matching "$DNS_TAG"
    systemctl disable --now dnscrypt-proxy.service dnscrypt-proxy.socket &>/dev/null || true
    [[ -f "$DNS_PROXY_BACKUP_CONF" ]] && cp -a "$DNS_PROXY_BACKUP_CONF" "$DNS_PROXY_CONF"
    sysctl -qw net.ipv4.conf.all.route_localnet=0 2>/dev/null || true
  fi
  rm -rf "$WARP_DIR" "$WARP_CONF" /usr/local/bin/wgcf "$WARP_BACKEND_FILE" "$WARP_HEALTH_SCRIPT" \
    "$USQUE_DIR" "$USQUE_BIN" "$USQUE_SYSCTL" "$WARPSCOUT_DIR" "$WARPSCOUT_BIN" \
    "$XRAY_DIR" "$XRAY_BIN" "$XRAY_ROUTING_SCRIPT" "$XRAY_ASSET_DIR"/geo{ip,site}.dat "$XRAY_ASSET_DIR"/geo{ip,site}_RU.dat \
    "$T2S_DIR" "$T2S_BIN" "$T2S_ROUTING_SCRIPT" "$EXITS_SCRIPT" \
    "$DNS_PROXY_STATE" "$DNS_PERSIST_SCRIPT" "$DNS_HEALTH_SCRIPT" "$DNS_SYSCTL"
}

# Файлы, которые кладёт «make install» amneziawg-tools.
_tools_files() {
  local d
  for d in /usr/bin /usr/local/bin; do echo "$d/awg" "$d/awg-quick"; done
  echo /usr/share/man/man8/awg.8 /usr/share/man/man8/awg-quick.8 \
       /usr/share/bash-completion/completions/awg /usr/share/bash-completion/completions/awg-quick \
       /lib/systemd/system/awg-quick@.service /lib/systemd/system/awg-quick.target \
       /usr/lib/systemd/system/awg-quick@.service /usr/lib/systemd/system/awg-quick.target
}

# Распакованные архивы Тулзы (с awg2.sh и awg_bot): из них «Установить бота»
# берёт локальный код, поэтому после полного удаления о них спрашиваем.
# Только свои (root_only_path) и без перевода строки в имени: список
# читается построчно, и «awg-toolza-x\nroot» дал бы rm -rf root —
# относительный путь от текущего каталога.
toolza_unpacked() {
  local d
  for d in /root/awg-toolza-*/ /home/*/awg-toolza-*/; do
    d="${d%/}"
    [[ "$d" != *$'\n'* && -d "$d" && -f "$d/awg2.sh" && -d "$d/awg_bot" ]] || continue
    root_only_path "$d" && echo "$d"
  done
  return 0
}

do_uninstall() {
  local del_bot=n del_wgobf=n del_web=n del_self=n del_src=n opts src=() d
  hdr "Удаление AWG Toolza"
  warn "Будет удалено:"
  echo -e "  ${R}—${N} сервер awg0, его клиенты и автозапуск"
  echo -e "  ${R}—${N} модуль ядра (DKMS) и утилиты awg / awg-quick"
  echo -e "  ${R}—${N} туннели: WARP, Xray, tun2socks, exit-ноды, каскад, шифрованный DNS"
  echo -e "  ${R}—${N} таймер сроков клиентов, правила UFW с меткой AmneziaWG"
  bot_installed && echo -e "  ${R}—${N} Telegram-бот ${D}(спрошу отдельно)${N}"
  wgobf_installed && echo -e "  ${R}—${N} WG + обфускатор ${D}(спрошу отдельно)${N}"
  web_installed && echo -e "  ${R}—${N} веб-панель ${D}(спрошу отдельно)${N}"
  echo -e "  ${R}—${N} сам скрипт $SCRIPT_PATH ${D}(спрошу отдельно)${N}"
  echo -e "  ${D}Перед удалением делается полный бэкап в $BACKUP_DIR — он остаётся.${N}"
  read_confirm "${R}  Подтверди удаление (введи yes): ${N}" || return 0
  bot_installed && read_yesno del_bot "  Удалить и Telegram-бота? [Y/n]: " y
  wgobf_installed && read_yesno del_wgobf "  Удалить и WG + обфускатор? [Y/n]: " y
  web_installed && read_yesno del_web "  Удалить и веб-панель? [Y/n]: " y
  read_yesno del_self "  Удалить сам скрипт awg2? [Y/n]: " y
  mapfile -t src < <(toolza_unpacked)
  if (( ${#src[@]} )); then
    echo -e "  ${D}Распакованные архивы Тулзы — из них ставится бот «из локального кода»:${N}"
    for d in "${src[@]}"; do printf "  ${D}  %s${N}\n" "$(shown "$d")"; done
    read_yesno del_src "  Удалить и их? [y/N]: " n
  fi
  opts=()
  [[ "$del_bot" == y ]] && opts+=(bot)
  [[ "$del_wgobf" == y ]] && opts+=(wgobf)
  [[ "$del_web" == y ]] && opts+=(web)
  [[ "$del_self" == y ]] && opts+=(self)
  uninstall_all "${opts[@]}"
  if [[ "$del_src" == y ]]; then
    for d in "${src[@]}"; do [[ "$d" == /* ]] && rm -rf -- "$d"; done
    ok "Распакованные архивы удалены: ${#src[@]}"
  fi
  (( UNINSTALLED_SELF )) && exit 0
  return 0
}

# uninstall_all [bot] [wgobf] [self] — без вопросов; полный бэкап делается всегда.
UNINSTALLED_SELF=0
uninstall_all() {
  local v o del_bot=n del_wgobf=n del_web=n del_self=n
  for o in "$@"; do
    case "$o" in bot) del_bot=y ;; wgobf) del_wgobf=y ;; web) del_web=y ;; self) del_self=y ;; esac
  done
  # Веб-панель работает через awg2: без него она осталась бы открытым входом,
  # который ничего не может, и убрать её было бы уже нечем
  if [[ "$del_self" == y && "$del_web" != y ]] && web_installed; then
    del_web=y
    info "Без awg2 веб-панель не работает — удаляю и её"
  fi

  server_exists && do_backup
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  expire_remove
  systemctl disable awg-quick@awg0 &>/dev/null || true
  rm -rf "$AUTOSTART_DROPIN"
  # NAT-персистентность очень старых версий
  remove_unit awg-nat.service
  rm -f /usr/local/bin/awg-nat-apply.sh /etc/network/if-pre-up.d/iptables-nat
  info "Туннели..."
  tunnels_remove_all
  info "Модуль ядра и утилиты..."
  if command -v dkms &>/dev/null; then
    for v in $(dkms status "$MOD_NAME" 2>/dev/null | sed -n "s#^$MOD_NAME/\([^,:]*\).*#\1#p" | sort -u); do
      dkms remove -m "$MOD_NAME" -v "$v" --all &>/dev/null || true
    done
  fi
  rmmod "$MOD_NAME" &>/dev/null || true
  rm -rf /usr/src/"$MOD_NAME"-* /var/lib/dkms/"$MOD_NAME" "$MOD_BACKUP_DIR" "$MODULES_LOAD_FILE" "$SYSCTL_FORWARD_FILE"
  depmod -a &>/dev/null || true
  # shellcheck disable=SC2046  # список путей — словами
  rm -f $(_tools_files)
  apt-get remove -y -q amneziawg amneziawg-tools &>/dev/null || true
  systemctl daemon-reload
  rm -rf "$AWG_DIR"
  rm -f "$CLIENT_DIR"/*_awg[23].conf "$MOD_TAG_FILE" "$TOOLS_TAG_FILE" "$UPSTREAM_CACHE" "$MOD_LOG"
  ufw_delete_matching AmneziaWG
  if [[ "$del_wgobf" == y ]]; then wgobf_remove quiet
  elif wgobf_installed; then info "WG + обфускатор оставлен и продолжит работать сам"; fi
  if [[ "$del_web" == y ]] && web_installed; then web_remove quiet
  elif web_installed; then info "Веб-панель оставлена — сервера AWG в ней больше нет"; fi
  # Антисканер работает через свой скрипт и без awg2, но управлять им без
  # awg2 нечем — уходит вместе со скриптом, иначе остаётся защищать сервер
  if [[ "$del_self" == y ]]; then antiscan_remove
  elif antiscan_on; then info "Антисканер оставлен и продолжит работать"; fi
  if [[ "$del_bot" == y ]]; then
    bot_uninstall quiet
    # Сертификат — для Mini App бота и веб-панели
    if ! web_installed; then
      [[ -f "$CERT_STATE" || -d "$CERT_DIR" ]] && cert_remove &>/dev/null
      rm -rf "$ACME_DIR" "$ACME_HOME"
    fi
  fi
  log_info "полное удаление"
  if [[ "$del_self" != y ]]; then
    ok "Удалено. Скрипт остался: $SCRIPT_PATH"
    return 0
  fi
  rm -rf "$STATE_DIR" "$LOG_FILE" "$INSTALL_LOG" /root/awg-toolza-*.run /opt/awg-toolza-*
  ok "Удалено всё, включая $SCRIPT_PATH. Бэкапы: $BACKUP_DIR"
  # bash дочитывает скрипт с диска по ходу — удаляем его из отдельного процесса
  ( sleep 1; rm -f "$SCRIPT_PATH" ) &>/dev/null &
  UNINSTALLED_SELF=1
}

do_danger_menu() {
  local c
  while true; do
    echo ""
    hdr "Удаление"
    echo -e "  ${Y}1)${N} Удалить всех клиентов ${D}(сервер остаётся)${N}"
    echo -e "  ${R}2)${N} Удалить всё"
    echo -e "  ${D}Сброс сервера с пересозданием — Сервер → Сбросить сервер${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) do_clean_clients || true ;;
      2) do_uninstall || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ diag ═════
# Диагностика: доступность доменов мимикрии, захват пакетов мимикрии с
# сервера, подсказка для проверки DPI со стороны клиента, сводка состояния.

do_check_domains() {
  local c
  echo -e "  ${C}1)${N} Мир / Европа"
  echo -e "  ${C}2)${N} Россия"
  read_choice c "${C}  Регион [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 2 ]]; then domains_check ru; else domains_check world; fi
}

domains_check() {  # world|ru
  local ru=0 pool kind d r ok=0 total=0 dir
  local -a pools=(
    "tls|TLS / HTTPS"          "quic|QUIC / HTTP/3"
    "sip|SIP / VoIP"           "stun|STUN / WebRTC"
    "cps|Российские сервисы (CPS)"
  )
  [[ "${1:-world}" == ru ]] && ru=1
  mktmp dir -d || return 1
  info "Проверяю доступность с этого сервера..."
  for pool in "${pools[@]}"; do
    kind="${pool%%|*}"
    for d in $(_diag_pool "$kind" "$ru"); do
      probe_host "$([[ "$kind" == tls ]] && echo tls || echo ping)" "$d" > "$dir/$kind.$d" &
    done
  done
  wait
  for pool in "${pools[@]}"; do
    kind="${pool%%|*}"
    [[ -n "$(_diag_pool "$kind" "$ru")" ]] || continue
    echo -e "  ${C}${pool#*|}${N}"
    for d in $(_diag_pool "$kind" "$ru"); do
      r=$(cat "$dir/$kind.$d" 2>/dev/null)
      total=$((total + 1))
      if [[ "$r" == ok* ]]; then
        ok=$((ok + 1))
        printf "    ${G}√${N} %-34s %5s мс\n" "$d" "${r#ok }"
      else
        printf "    ${R}×${N} %-34s ${R}нет ответа${N}\n" "$d"
      fi
    done
  done
  echo ""
  echo -e "  Доступно: ${W}$ok из $total${N}. Недоступные домены при выдаче мимикрии пропускаются."
}

_diag_pool() {  # вид ru(0|1)
  case "$1" in
    tls)  if (( $2 )); then echo "${TLS_DOMAINS_RU[*]}"; else echo "${TLS_DOMAINS[*]}"; fi ;;
    quic) if (( $2 )); then echo "${QUIC_DOMAINS_RU[*]} ${QUIC_DOMAINS[*]}"; else echo "${QUIC_DOMAINS[*]}"; fi ;;
    sip)  echo "${SIP_DOMAINS[*]}" ;;
    stun) echo "${STUN_DOMAINS[*]}" ;;
    cps)  (( $2 )) && echo "${CPS_DOMAINS[*]}" ;;
  esac
  return 0
}

# Захват первых пакетов переподключившегося клиента и разбор: видны ли
# пакеты мимикрии и под какой протокол они похожи.
# «имя<TAB>ip:порт» клиентов, у которых есть endpoint (были на связи).
_sniff_candidates() {
  local pub ep name
  while read -r pub ep; do
    [[ "$ep" == "(none)" ]] && continue
    name=$(clients_tsv | awk -F'\t' -v k="$pub" '$2 == k {print $1; exit}')
    printf '%s\t%s\n' "${name:-?}" "$ep"
  done < <(awg show "$AWG_IF" endpoints 2>/dev/null)
}

do_sniff_test() {
  local rows=() i c
  server_exists || { err "Сервер не создан"; return 1; }
  mapfile -t rows < <(_sniff_candidates)
  (( ${#rows[@]} )) || { warn "Нет подключённых клиентов — подключись и вернись сюда"; return 0; }
  for i in "${!rows[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${rows[$i]%%$'\t'*} ${D}${rows[$i]#*$'\t'}${N}"; done
  read_choice c "${C}  Клиент (Enter = 1): ${N}" 1 "${#rows[@]}" 1
  echo -e "  ${Y}На клиенте: отключись, подожди 3 секунды и подключись снова${N}"
  pause
  sniff_client "${rows[$((c - 1))]%%$'\t'*}"
}

# Захват первых пакетов переподключившегося клиента (20 с) и разбор.
sniff_client() {  # имя
  local port dev ep verdict pcap tag msg extra
  server_exists || { err "Сервер не создан"; return 1; }
  need_cmds tcpdump:tcpdump || return 1
  ep=$(_sniff_candidates | awk -F'\t' -v n="$1" '$1 == n {print $2; exit}')
  [[ -n "$ep" ]] || { err "Клиент $1 ещё не подключался — адреса нет"; return 1; }
  mimicry_module_warnings
  port=$(server_port)
  dev=$(uplink_iface) || { err "Не определился внешний интерфейс"; return 1; }
  mktmp pcap || return 1
  info "Слушаю 20 секунд..."
  timeout 20 tcpdump -i "$dev" -nn -c 30 "udp port $port and src host ${ep%:*}" -w "$pcap" &>/dev/null || true
  [[ -s "$pcap" ]] || { warn "Ничего не поймано — клиент не переподключился или сменил IP"; return 0; }
  while IFS='|' read -r tag msg extra; do
    case "$tag" in
      OK) echo -e "  ${G}√${N} $msg" ;;
      INFO) echo -e "  ${D}· $msg${N}" ;;
      VERDICT) verdict="$msg|$extra" ;;
    esac
  done < <(py pcap-analyze "$pcap" 2>&1)
  case "${verdict%%|*}" in
    PASS|OK) success_box "${verdict#*|}" ;;
    *) warn "${verdict#*|}" ;;
  esac
  log_info "DPI-тест: ${ep%:*} → ${verdict:-?}"
}

do_client_dpi_hint() {
  hdr "DPI со стороны клиента"
  echo -e "  ${Y}Запускать на устройстве клиента, не на сервере.${N}"
  echo -e "  ${W}Docker:${N}  ${G}docker run --rm -it --pull=always ghcr.io/runnin4ik/dpi-detector:latest${N}"
  echo -e "  ${W}Python:${N}  ${G}git clone https://github.com/Runnin4ik/dpi-detector.git${N}"
  echo -e "           ${G}cd dpi-detector && python -m pip install -r requirements.txt && python dpi_detector.py${N}"
  echo -e "  ${D}Windows и macOS — готовые сборки в Releases репозитория.${N}"
  echo ""
  echo -e "  ${W}Что делать с результатом:${N}"
  echo -e "  • рабочий у провайдера клиента домен → домен мимикрии (Клиенты → Сменить мимикрию)"
  echo -e "  • подмена DNS / перехват UDP/53 → Туннели → Шифрованный DNS"
  echo -e "  • обрыв после первых КБ → профиль «AmneziaVPN» и короче I1-I5"
  echo -e "  ${D}Сторонний проект (MIT), awg2 его не ставит.${N}"
}

# Сводка для «awg2 --status» и меню диагностики.
do_status() {
  local n
  hdr "AWG Toolza $VERSION_SHOW"
  os_detect
  echo -e "  Система   : $OS_LABEL, ядро $(uname -r)"
  echo -e "  Компоненты: $(components_summary)"
  if server_exists; then
    n=$(clients_tsv | wc -l)
    echo -e "  Сервер    : AWG $(server_proto), $(profile_label "$(server_profile)"), порт $(server_port), клиентов $n"
    if iface_up; then echo -e "  awg0      : ${G}● поднят${N}"; else echo -e "  awg0      : ${R}○ не поднят${N}"; fi
  else
    echo -e "  Сервер    : ${D}не создан${N}"
  fi
  echo -e "  WARP      : $(_tun_state warp_is_up "$WARP_CONF" "$USQUE_CONF")"
  echo -e "  Xray      : $(_tun_state xray_is_up "$XRAY_CONF")"
  echo -e "  tun2socks : $(_tun_state t2s_is_up "$T2S_CONF")"
  echo -e "  Exit-ноды : $(_tun_state exits_is_up "$EXITS_DIR"/awg-exit-*.conf)"
  echo -e "  Каскад    : $(cascade_state_line)"
  echo -e "  DNS       : $(dns_state_line)"
  wgobf_installed && echo -e "  WG+обф.   : $(wgobf_running && echo -e "${G}● работает${N}" || echo -e "${R}○ не работает${N}")"
  bot_installed && echo -e "  Бот       : $(unit_active "$BOT_UNIT" && echo -e "${G}● работает${N}" || echo -e "${Y}○ остановлен${N}")"
  return 0
}

do_diag_menu() {
  local c
  while true; do
    echo ""
    hdr "Диагностика"
    echo -e "  ${C}1)${N} Сводка состояния"
    echo -e "  ${C}2)${N} Домены мимикрии ${D}— доступность с этого сервера${N}"
    echo -e "  ${C}3)${N} Тест мимикрии ${D}— захват пакетов клиента${N}"
    echo -e "  ${C}4)${N} DPI со стороны клиента"
    echo -e "  ${C}5)${N} Модуль ядра и утилиты ${D}— подробный отчёт${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-5]: ${N}" 0 5 0
    case "$c" in
      1) do_status ;;
      2) do_check_domains || true ;;
      3) do_sniff_test || true ;;
      4) do_client_dpi_hint ;;
      5) components_report || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ═════ menu ═════
# Главное меню и шапка. Нумерация разделов — как в прежних версиях.

show_header() {
  local ch="" upd n prof st hint why
  clear
  [[ "$UPDATE_CHANNEL" == beta ]] && ch=" ${Y}[beta]${N}"
  upd=$(update_available || true)
  echo -e "${B}${LINE}${N}"
  echo -e "  ${W}AWG Toolza $VERSION_SHOW${N}$ch${upd:+   ${G}⬆ есть $upd${N} ${D}— Обновление${N}}"
  echo -e "  ${C}TG: @awgToolza${N}"
  echo -e "${B}${LINE}${N}"
  why=$(os_supported) || echo -e "  ${Y}▲ $why${N}"
  echo -e "  Компоненты : $(components_summary)"
  if server_exists; then
    n=$(clients_tsv | wc -l)
    prof="AWG $(server_proto), $(profile_label "$(server_profile)")"
    if iface_up; then st="${G}● работает${N}"; else st="${R}○ не поднят${N}"; fi
    echo -e "  Сервер     : ${W}$(endpoint_host):$(server_port)${N}  $st"
    echo -e "  Профиль    : ${W}$prof${N}, клиентов ${W}$n${N}"
    hint=$(proto_upgrade_hint)
    [[ -n "$hint" ]] && echo -e "  $hint"
  else
    echo -e "  Сервер     : ${D}не создан — Сервер → Создать сервер${N}"
  fi
  echo -e "${B}${LINE}${N}"
}

do_server_menu() {
  local c ep
  while true; do
    echo ""
    hdr "Сервер"
    ep=$(endpoint_domain)
    echo -e "  ${C}1)${N} Установить компоненты"
    echo -e "  ${C}2)${N} Создать сервер"
    echo -e "  ${C}3)${N} Перезапустить awg0"
    echo -e "  ${C}4)${N} Протокол и параметры AWG"
    echo -e "  ${C}5)${N} Модуль ядра и утилиты"
    echo -e "  ${C}6)${N} Проверить и починить"
    echo -e "  ${C}7)${N} Endpoint ${D}— ${ep:-IP сервера}${N}"
    echo -e "  ${Y}8)${N} Сбросить сервер"
    echo -e "  ${C}9)${N} Антисканер ${D}— $(antiscan_on && echo "включён" || echo "сети сканеров РКН")${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-9]: ${N}" 0 9 0
    case "$c" in
      1) do_install || true ;;
      2) do_create_server || true ;;
      3) do_restart || true ;;
      4) do_proto_menu || true; continue ;;
      5) do_components_menu || true; continue ;;
      6) do_repair || true ;;
      7) do_endpoint_menu || true ;;
      8) do_reset_server || true ;;
      9) do_antiscan_menu || true; continue ;;
      0) return 0 ;;
    esac
    pause
  done
}

do_backup_menu() {
  local c
  while true; do
    echo ""
    hdr "Бэкапы ${D}($BACKUP_DIR)${N}"
    echo -e "  ${C}1)${N} Создать бэкап"
    echo -e "  ${C}2)${N} Восстановить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) do_backup || true ;;
      2) do_restore || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

_need_server() {
  server_exists && return 0
  warn "Сначала создай сервер: Сервер → Создать сервер"
  pause
  return 1
}

main_menu() {
  local c post="${1:-}"
  while true; do
    show_header
    if [[ -n "$post" ]]; then
      if [[ "$post" == "$VERSION" ]]; then success_box "Скрипт перезапущен ($VERSION)"
      else success_box "Обновлено: $post → $VERSION"; fi
      post=""
    fi
    echo ""
    echo -e "  ${C}1)${N} Сервер          ${D}— установка${N}"
    echo -e "  ${C}2)${N} Клиенты         ${D}— конфиги${N}"
    echo -e "  ${C}3)${N} Диагностика     ${D}— проверки${N}"
    echo -e "  ${C}4)${N} Бэкапы          ${D}— сохранить${N}"
    echo -e "  ${C}5)${N} Туннели и DNS   ${D}— WARP, Xray${N}"
    echo -e "  ${C}6)${N} Telegram-бот    ${D}— управление${N}"
    echo -e "  ${R}7)${N} Удаление        ${D}— очистка${N}"
    echo -e "  ${M}8)${N} Обновление      ${D}— $(update_channel_label)${N}"
    echo -e "  ${C}9)${N} WG + обфускатор ${D}— $(wgobf_installed && echo "установлен" || echo "как Phobos")${N}"
    echo -e "  ${C}w)${N} Веб-панель      ${D}— $(web_installed && { web_active && echo "работает" || echo "остановлена"; } || echo "в браузере")${N}"
    echo -e "  ${W}0)${N} Выход"
    read_choice c "${C}  Выбор [0-9, w]: ${N}" 0 9 "" "w"
    case "$c" in
      1) do_server_menu ;;
      2) _need_server && { do_clients_menu || true; } ;;
      3) do_diag_menu ;;
      4) do_backup_menu ;;
      5) do_tunnels_menu ;;
      6) do_bot_menu ;;
      7) do_danger_menu ;;
      8) do_update_menu ;;
      9) do_wgobf_menu ;;
      w) do_web_menu ;;
      0) echo -e "\n  ${G}В путь!${N} ${D}t.me/awgToolza${N}\n"; return 0 ;;
    esac
  done
}

# ═════ api ═════
# Машинный интерфейс для Telegram-бота: awg2 api КОМАНДА [аргументы].
#
# Каждый вызов печатает одну строку JSON:
#   {"ok": true, "rc": 0, "data": ..., "log": "вывод без цвета", "error": ""}
# data — результат для кнопок и списков, log — тот же текст, что видит
# пользователь меню, error — последняя строка «×» при неудаче.
# Бот вызывает те же функции-ядра, что и меню: поведение у них одно.
#
# Большие входные данные (конфиг exit-ноды, профиль WARP) идут через stdin.
# Долгое (сборка модуля, установка, обновление) запускается задачей:
#   awg2 api job start КОМАНДА...      → data.id
#   awg2 api job status ID [СМЕЩЕНИЕ]  → состояние, новый кусок журнала, итог
# Задача живёт в своём юните systemd и переживает перезапуск бота — поэтому
# через неё бот может обновить, перезапустить и удалить самого себя.
#
# Изменяющие команды выполняются по одной (flock); чтение — без очереди.

API_VERSION=1
API_MODE=0          # 1 — вызов пришёл из awg2 api (например, от бота)
API_JOBS="" API_LOCK="" API_LOG="" API_DATA="" API_IN="" API_RESULT="" API_SELF=""
API_STDIN_READ=0
API_ARGS=()

# ── JSON ──────────────────────────────────────────────────
# Строка для py json-kv: «ключ[:тип]<TAB>значение». Типы: n число, b да/нет,
# j готовый JSON, f содержимое файла; без типа — строка.
_kv() { printf '%s\t%s\n' "$1" "${2//[$'\n\r']/ }"; }
_b() { if "$@" &>/dev/null; then echo 1; else echo 0; fi; }
api_obj() { py json-kv > "$API_DATA"; }
api_rows() { py json-rows "$@" > "$API_DATA"; }
api_list() { py json-list > "$API_DATA"; }

_api_usage() { err "Использование: awg2 api $*"; return 2; }

# stdin читается только командами, которым он нужен: иначе вызов из
# скрипта с открытым, но пустым stdin ждал бы его конца вечно.
_api_wants_stdin() { [[ "$1 ${2:-}" == "exits add" || "$1 ${2:-}" == "warp import" ]]; }
_api_stdin() {
  (( API_STDIN_READ )) && return 0
  API_STDIN_READ=1
  [[ -t 4 ]] || cat <&4 > "$API_IN"
}

# «up» — работает, «off» — настроен и выключен, «none» — не настроен.
_api_tun() {
  local check="$1" f
  shift
  "$check" &>/dev/null && { echo up; return; }
  for f in "$@"; do [[ -e "$f" ]] && { echo off; return; }; done
  echo none
}

# Срок клиента: unix-время, +30d / +12h / +45m или дата для date -d.
# Значение приходит от бота и панели: в арифметику bash попадают только
# цифры, проверенные регуляркой, — bash вычисляет содержимое переменной как
# выражение, и непроверенная строка могла бы выполнить команду.
_api_ts() {
  local v="$1" n re_date='^[0-9A-Za-z :./+-]{1,40}$'
  if [[ "$v" =~ ^\+([0-9]{1,6})([dhm])$ ]]; then
    n=$((10#${BASH_REMATCH[1]}))
    case "${BASH_REMATCH[2]}" in d) n=$((n * 86400)) ;; h) n=$((n * 3600)) ;; m) n=$((n * 60)) ;; esac
    echo $(( $(date +%s) + n ))
  elif [[ "$v" =~ ^[0-9]{1,12}$ ]]; then
    echo $((10#$v))
  elif [[ "$v" =~ $re_date ]]; then
    date -d "$v" +%s 2>/dev/null
  fi
  return 0
}

# ── Сводка ────────────────────────────────────────────────
_api_status() {
  local n=0
  os_detect
  update_check_async || true
  upstream_refresh_async || true
  country_refresh_async || true
  server_exists && n=$(clients_tsv | grep -c . || true)
  {
    _kv version "$VERSION_SHOW"; _kv api:n "$API_VERSION"
    _kv channel "$UPDATE_CHANNEL"; _kv update "$(update_available || true)"
    _kv host "$(hostname)"; _kv ip "$(public_ip_cached)"; _kv country "$(server_country)"
    _kv uptime:n "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
    _kv os "$OS_LABEL"; _kv kernel "$(uname -r)"
    _kv components.installed:b "$(_b command -v awg)"
    _kv components.module "$(mod_tag)"; _kv components.tools "$(tools_tag)"
    _kv components.loaded:b "$(_b mod_loaded)"
    _kv components.module_update "$(mod_update_available)"
    _kv components.tools_update "$(tools_update_available)"
    _kv components.reboot "$(reboot_reason)"
    _kv components.kernel_gap "$(kernel_gap_line)"
    _kv server.exists:b "$(_b server_exists)"
    if server_exists; then
      _kv server.up:b "$(_b iface_up)"
      _kv server.proto "$(server_proto)"; _kv server.profile "$(server_profile)"
      _kv server.profile_label "$(profile_label)"
      _kv server.port:n "$(server_port)"; _kv server.net "$(server_net)"
      _kv server.endpoint "$(endpoint_host):$(server_port)"; _kv server.domain "$(endpoint_domain)"
      _kv server.region "$(server_region)"; _kv server.mtu:n "$(conf_iface_get MTU)"
      _kv server.mimicry "$(conf_marker AWG_MIMICRY)"; _kv server.clients:n "$n"
      # Онлайн — рукопожатие за последние 3 минуты
      _kv server.online:n "$(awg show "$AWG_IF" latest-handshakes 2>/dev/null \
        | awk -v now="$(date +%s)" '$2 > 0 && now - $2 < 180' | wc -l)"
    fi
    _kv tunnels.warp "$(_api_tun warp_is_up "$WARP_CONF" "$USQUE_CONF")"
    _kv tunnels.xray "$(_api_tun xray_is_up "$XRAY_CONF")"
    _kv tunnels.tun2socks "$(_api_tun t2s_is_up "$T2S_CONF")"
    _kv tunnels.exits "$(_api_tun exits_is_up "$EXITS_DIR"/awg-exit-*.conf)"
    _kv tunnels.cascade:n "$(cascade_count)"
    if dns_installed; then _kv tunnels.dns "$(dns_running && echo up || echo off)"
    else _kv tunnels.dns none; fi
    if wgobf_installed; then _kv wgobf "$(wgobf_running && echo up || echo off)"; else _kv wgobf none; fi
    _kv bot.installed:b "$(_b bot_installed)"; _kv bot.active:b "$(_b unit_active "$BOT_UNIT")"
    _kv bot.version "$(bot_version)"
  } | api_obj
}

# ── Сервер ────────────────────────────────────────────────
_api_server() {
  local a="${1:-}" rc=0
  shift || true
  case "$a" in
    info)
      # Поддержка 3.1 — из кэша (модуль, tools и сборка в памяти не менялись):
      # server info зовут почти все экраны бота и панели, а проба на сервере
      # 2.0 — это пробный интерфейс на каждый вызов. Сервера ещё нет — мастеру
      # нужен тот же честный ответ, что и меню.
      proto31_cached || rc=$?
      {
        _kv installed:b "$(_b command -v awg)"; _kv exists:b "$(_b server_exists)"
        _kv proto31:b "$([[ $rc == 0 ]] && echo 1 || echo 0)"
        # Почему нет 3.1: components | tools | module | check (не прошла проба)
        _kv proto31_why "$([[ $rc == 0 ]] || proto_why 3.1)"
        _kv reboot "$(reboot_reason)"
        if server_exists; then
          _kv up:b "$(_b iface_up)"; _kv proto "$(server_proto)"
          _kv profile "$(server_profile)"; _kv profile_label "$(profile_label)"
          _kv port:n "$(server_port)"; _kv net "$(server_net)"; _kv mtu:n "$(conf_iface_get MTU)"
          _kv endpoint "$(endpoint_host):$(server_port)"; _kv domain "$(endpoint_domain)"
          _kv region "$(server_region)"; _kv mimicry "$(conf_marker AWG_MIMICRY)"
          _kv mimicry_domain "$(conf_marker AWG_MIMICRY_DOMAIN)"; _kv obf_level "$(conf_marker AWG_OBF_LEVEL)"
          _kv clients:n "$(client_files | grep -c . || true)"
        fi
      } | api_obj
      server_exists && proto_upgrade_hint
      return 0 ;;
    install) do_install ;;
    create)
      server_create_opts "$@" || return 1
      { _kv client "$S_FIRST_CLIENT"; _kv file "$(client_file "$S_FIRST_CLIENT")"; } | api_obj ;;
    restart) do_restart ;;
    params)
      server_exists || { err "Сервер не создан"; return 1; }
      local sub="${1:-}" k v
      shift || true
      case "$sub" in
        ""|check)
          params_check "$@" || return 1
          {
            _kv proto "$(server_proto)"; _kv mtu:n "$(conf_iface_get MTU)"
            _kv clients:n "$(client_files | grep -c . || true)"
            while IFS=$'\t' read -r k v; do _kv "values.$k" "$v"; done <<< "$PARAMS_KEYS"
            _kv errors:j "$(py json-list <<< "$PARAMS_ERR")"; _kv warnings:j "$(py json-list <<< "$PARAMS_WARN")"
            _kv changed:j "$(py json-list <<< "$PARAMS_CHANGED")"; _kv breaking:j "$(py json-list <<< "$PARAMS_BREAKING")"
          } | api_obj ;;
        set)
          server_params_set "$@" || return 1
          { _kv changed:j "$(py json-list <<< "$PARAMS_CHANGED")"; _kv breaking:j "$(py json-list <<< "$PARAMS_BREAKING")"
            _kv clients:n "$PARAMS_CLIENTS"; } | api_obj ;;
        *) _api_usage "server params [check|set [force]] [Ключ=значение...]" ;;
      esac ;;
    proto)
      [[ "${1:-}" =~ ^(2\.0|3\.1)$ ]] || { _api_usage "server proto 2.0|3.1"; return; }
      server_exists || { err "Сервер не создан"; return 1; }
      server_regen_params "$1" ;;
    repair)
      do_repair; rc=$?
      { _kv issues:n "$REPAIR_ISSUES"; _kv fixed:n "$REPAIR_FIXED"; } | api_obj
      return "$rc" ;;
    endpoint)
      [[ -n "${1:-}" ]] || { _api_usage "server endpoint ДОМЕН|ip [keep]"; return; }
      endpoint_set "$([[ "$1" == ip ]] || echo "$1")" "$([[ "${2:-}" == keep ]] && echo 0 || echo 1)" ;;
    reset) server_reset ;;
    reboot) server_reboot ;;
    *) _api_usage "server info|install|create [ключ=значение...]|restart|params [check|set [force]] [Ключ=значение...]|proto 2.0|3.1|repair|endpoint ДОМЕН|ip [keep]|reset|reboot" ;;
  esac
}

# ── Модуль ядра и amneziawg-tools ─────────────────────────
_api_module() {
  local a="${1:-}" f
  shift || true
  case "$a" in
    report)
      {
        _kv kernel "$(uname -r)"; _kv kernels:j "$(installed_kernels | py json-list)"
        _kv module "$(mod_tag)"; _kv tools "$(tools_tag)"; _kv loaded:b "$(_b mod_loaded)"
        _kv module_update "$(mod_update_available)"; _kv tools_update "$(tools_update_available)"
        _kv module_latest "$(upstream_latest mod)"; _kv tools_latest "$(upstream_latest tools)"
        _kv reboot "$(reboot_reason)"; _kv secure_boot:b "$(_b secure_boot_on)"
        _kv kernel_gap "$(kernel_gap_line)"
        _kv backups:n "$(mod_backups | grep -c . || true)"
      } | api_obj
      components_report ;;
    check)
      upstream_refresh || { err "Нет доступа к github.com — версии не проверены"; return 1; }
      { _kv module "$(upstream_latest mod)"; _kv tools "$(upstream_latest tools)"
        _kv module_update "$(mod_update_available)"; _kv tools_update "$(tools_update_available)"; } | api_obj
      ok "Модуль: $(upstream_latest mod), tools: $(upstream_latest tools)" ;;
    tags)
      upstream_tags "$MOD_REPO" | head -15 | api_list
      [[ -s "$API_DATA" && "$(cat "$API_DATA")" != "[]" ]] || { err "Список тегов не получен (нет доступа к github.com)"; return 1; } ;;
    update)
      local tag="" force=""
      for f in "$@"; do if [[ "$f" == force ]]; then force=force; else tag="$f"; fi; done
      [[ -z "$tag" || "$tag" =~ ^v?[0-9][0-9A-Za-z._-]*$ ]] || { err "Тег вида v3.1.20260906"; return 1; }
      mod_update_flow "$tag" "$force" ;;
    tools) tools_update_flow "${1:-}" ;;
    all) components_update_flow ;;
    reload) mod_reload ;;
    rebuild) mod_rebuild_all ;;
    backups)
      while IFS= read -r f; do printf '%s\t%s\t%s\n' "$f" "${f##*/}" "$(stat -c %Y "$f")"; done < <(mod_backups) \
        | api_rows path name time:n ;;
    rollback)
      [[ -n "${1:-}" ]] || { _api_usage "module rollback ФАЙЛ"; return; }
      mod_rollback "$1" ;;
    *) _api_usage "module report|check|tags|update [ТЕГ] [force]|tools [force]|all|reload|rebuild|backups|rollback ФАЙЛ" ;;
  esac
}

# ── Клиенты ───────────────────────────────────────────────
_api_clients() {
  local a="${1:-}" dump
  shift || true
  case "$a" in
    list|"")
      server_exists || { echo '[]' > "$API_DATA"; return 0; }
      mktmp dump || return 1
      awg show "$AWG_IF" dump > "$dump" 2>/dev/null || true
      py clients-json "$SERVER_CONF" "$dump" "$CLIENT_DIR" "$WARP_PEERS" "$XRAY_PEERS" "$EXITS_PEERS" "$TRAFFIC_DB" > "$API_DATA" ;;
    bulk) _api_clients_bulk "$@" ;;
    del) _api_clients_del "$@" ;;
    export)
      clients_export || return 1
      { _kv file "$EXPORT_PATH"; } | api_obj ;;
    purge-blocked) clients_purge_blocked ;;
    clean) clients_clean ;;
    *) _api_usage "clients list|bulk ИМЕНА|ПРЕФИКС:ЧИСЛО [ключ=значение...]|del ИМЯ,ИМЯ...|export|purge-blocked|clean" ;;
  esac
}

# clients del a,b,c — как «Удалить → Несколько по именам» в меню: копия
# awg0.conf рядом, затем по одному. data — список удалённых.
_api_clients_del() {
  local n pub names=() gone=() parts=()
  [[ -n "${1:-}" ]] || { _api_usage "clients del ИМЯ,ИМЯ..."; return; }
  server_exists || { err "Сервер не создан"; return 1; }
  IFS=',' read -r -a parts <<< "$1"
  for n in "${parts[@]}"; do
    n="${n// /}"
    [[ -n "$n" ]] && names+=("$n")
  done
  cp -a "$SERVER_CONF" "${SERVER_CONF}.pre_delete.$(date +%s)"
  for n in "${names[@]}"; do
    pub=$(client_pub "$n")
    if [[ -z "$pub" ]]; then warn "Нет клиента: $n"; continue; fi
    client_delete "$pub" && gone+=("$n")
  done
  printf '%s\n' "${gone[@]}" | py json-list > "$API_DATA"
  (( ${#gone[@]} )) || { err "Никого не удалил"; return 1; }
}

# Разбор «expire= mimicry= dns= mtu=» → переменные _O_*.
_O_EXPIRE="" _O_MIM="" _O_DNS="" _O_MTU=""
_api_client_opts() {
  local kv v
  _O_EXPIRE="" _O_MIM=server _O_DNS="1.1.1.1, 1.0.0.1" _O_MTU=""
  for kv in "$@"; do
    v="${kv#*=}"
    case "${kv%%=*}" in
      expire) if [[ -n "$v" ]]; then
                _O_EXPIRE=$(_api_ts "$v")
                [[ "$_O_EXPIRE" =~ ^[0-9]+$ ]] || { err "Срок не распознан: $v"; return 1; }
                (( _O_EXPIRE > $(date +%s) + 60 )) || { err "Срок уже прошёл: $v"; return 1; }
              fi ;;
      mimicry) _O_MIM="$v" ;;
      dns) valid_dns_list "$v" || { err "dns: IPv4 через запятую"; return 1; }; _O_DNS="$v" ;;
      mtu) [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1280 && v <= 1500 )) || { err "mtu: 1280-1500"; return 1; }
           _O_MTU="$v" ;;
      *) err "Неизвестный параметр: ${kv%%=*}"; return 1 ;;
    esac
  done
}

# clients bulk a,b,c | префикс:число [опции] — мимикрия генерируется один раз.
_api_clients_bulk() {
  local spec="${1:-}" names=() parts=() n i prefix count part addr created=()
  [[ -n "$spec" ]] || { _api_usage "clients bulk ИМЯ,ИМЯ... | ПРЕФИКС:ЧИСЛО [expire=] [mimicry=] [dns=] [mtu=]"; return; }
  shift
  server_exists || { err "Сервер не создан"; return 1; }
  _api_client_opts "$@" || return 1
  if [[ "$spec" =~ ^([A-Za-z0-9_-]{1,27}):([0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"; count="${BASH_REMATCH[2]}"
    (( count >= 1 && count <= 200 )) || { err "Число клиентов: 1-200"; return 1; }
    i=1
    while (( ${#names[@]} < count && i < 10000 )); do
      printf -v n '%s-%03d' "$prefix" "$i"
      _name_free "$n" && names+=("$n")
      i=$((i + 1))
    done
  else
    IFS=',' read -r -a parts <<< "$spec"
    for part in "${parts[@]}"; do
      n="${part//[[:space:]]/}"
      [[ -n "$n" ]] || continue
      if [[ " ${names[*]} " == *" $n "* ]] || ! _name_free "$n"; then warn "Пропущено: $n (занято или недопустимо)"; continue; fi
      names+=("$n")
    done
  fi
  (( ${#names[@]} )) || { err "Нет имён для создания"; return 1; }
  [[ -n "$_O_MTU" ]] || _O_MTU=$(conf_iface_get MTU)
  mimicry_from_spec "$_O_MIM" || return 1
  for n in "${names[@]}"; do
    addr=$(free_client_ip) || { warn "Подсеть заполнена — стоп"; break; }
    client_add "$n" "$addr" "$_O_DNS" "$_O_MTU" "$_O_EXPIRE" || { warn "$n: не создан"; continue; }
    ok "$n → $addr"
    created+=("$n")
  done
  printf '%s\n' "${created[@]}" | api_list
  (( ${#created[@]} )) || { err "Ни один клиент не создан"; return 1; }
  success_box "Создано клиентов: ${#created[@]} из ${#names[@]}"
}

_api_client() {
  local a="${1:-}" name="${2:-}" f
  [[ -n "$name" ]] || { _api_usage "client add|del|rename|conf|mimicry|expire|unexpire|limit|limit-reset ИМЯ ..."; return; }
  shift 2
  case "$a" in
    add)
      _api_client_opts "$@" || return 1
      client_create "$name" "$_O_EXPIRE" "$_O_MIM" "$_O_DNS" "$_O_MTU" || return 1
      f=$(client_file "$name")
      { _kv name "$name"; _kv file "$f"; _kv text:f "$f"; } | api_obj ;;
    del) client_remove "$name" ;;
    rename)
      [[ -n "${1:-}" ]] || { _api_usage "client rename СТАРОЕ НОВОЕ"; return; }
      client_rename "$name" "$1" ;;
    conf)
      f=$(client_file "$name")
      [[ -f "$f" ]] || { err "Нет конфига клиента $name"; return 1; }
      { _kv name "$name"; _kv file "$f"; _kv size:n "$(stat -c %s "$f")"; _kv text:f "$f"; } | api_obj ;;
    mimicry)
      [[ -n "${1:-}" ]] || { _api_usage "client mimicry ИМЯ none|server|профиль[:уровень[:домен[:бюджет]]]"; return; }
      client_set_mimicry "$name" "$1" || return 1
      f=$(client_file "$name")
      { _kv name "$name"; _kv file "$f"; _kv text:f "$f"; } | api_obj ;;
    expire)
      [[ -n "${1:-}" ]] || { _api_usage "client expire ИМЯ unix-время|+30d|+12h|дата"; return; }
      client_expire_set "$name" "$(_api_ts "$1")" ;;
    unexpire) client_expire_clear "$name" ;;
    limit)
      [[ -n "${1:-}" ]] || { _api_usage "client limit ИМЯ 50G|500M|off [month|total]"; return; }
      client_limit_set "$name" "$1" "${2:-month}" ;;
    limit-reset) client_limit_reset "$name" ;;
    *) _api_usage "client add|del|rename|conf|mimicry|expire|unexpire|limit|limit-reset ИМЯ ..." ;;
  esac
}

_api_mimicry() {
  local i id label hint
  for i in "${MIMICRY_INFO[@]}"; do
    IFS='|' read -r id label hint <<< "$i"
    printf '%s\t%s\t%s\t%s\n' "$id" "$label" "$hint" "$(_profile_needs_domain "$id" && echo 1 || echo 0)"
  done | api_rows id label hint domain:b
}

# ── Трафик по дням ────────────────────────────────────────
_api_traffic() {
  local tr wtr name="" days=30
  case "${1:-}" in
    daily)
      # Два аргумента — всегда «ИМЯ|all ДНЕЙ»: имя клиента может быть числом
      if (( $# >= 3 )); then name="$2"; [[ "$3" =~ ^[0-9]+$ ]] && days="$3"
      elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then days="$2"
      else name="${2:-}"; fi
      [[ "$name" == all ]] && name=""
      server_exists || { err "Сервер не создан"; return 1; }
      mktmp tr || return 1
      awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
      py traffic-daily "$SERVER_CONF" "$TRAFFIC_DB" "$tr" "$name" "$days" > "$API_DATA" ;;
    now)
      # Счётчики прямо сейчас — панель считает по ним живую скорость:
      # клиенты awg0 и отдельно клиенты WG + обфускатора (wgobf0)
      server_exists || { err "Сервер не создан"; return 1; }
      mktmp tr || return 1
      mktmp wtr || return 1
      awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
      if wgobf_installed; then wg show "$WGOBF_IF" transfer > "$wtr" 2>/dev/null || true; fi
      py traffic-now "$SERVER_CONF" "$tr" "$WGOBF_WG_CONF" "$wtr" > "$API_DATA" ;;
    *) _api_usage "traffic daily [ИМЯ|all] [ДНЕЙ] | now" ;;
  esac
}

# ── Диагностика ───────────────────────────────────────────
_api_diag() {
  case "${1:-}" in
    status) do_status ;;
    domains) domains_check "$([[ "${2:-}" == ru ]] && echo ru || echo world)" ;;
    sniff-list) _sniff_candidates | api_rows name endpoint ;;
    sniff)
      [[ -n "${2:-}" ]] || { _api_usage "diag sniff ИМЯ"; return; }
      sniff_client "$2" ;;
    dpi-hint) do_client_dpi_hint ;;
    *) _api_usage "diag status|domains world|ru|sniff-list|sniff ИМЯ|dpi-hint" ;;
  esac
}

# ── Бэкапы ────────────────────────────────────────────────
_api_backup() {
  local a="${1:-}" p
  shift || true
  case "$a" in
    create)
      backup_create archive "${1:-}" "${2:-}" || return 1
      { _kv path "$BACKUP_PATH"; _kv size:n "$(stat -c %s "$BACKUP_PATH")"; } | api_obj ;;
    list)
      while IFS= read -r p; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$p" "${p##*/}" "$([[ -d "$p" ]] && echo 1 || echo 0)" \
          "$(stat -c %Y "$p")" "$(du -sb "$p" 2>/dev/null | cut -f1)"
      done < <(_restore_list) | api_rows path name full:b time:n size:n ;;
    inspect)
      [[ -n "${1:-}" ]] || { _api_usage "backup inspect ПУТЬ"; return; }
      _restore_prepare "$1" || return 1
      { _kv clients:n "$(find "$RESTORE_SRC" -maxdepth 1 -name '*_awg[23].conf' | grep -c . || true)"
        _kv wgobf:b "$(_b test -d "$RESTORE_SRC/wgobf/etc")"
        _kv tunnels:b "$(_b test -f "$RESTORE_SRC/tunnels.tar.gz")"
        _kv warp:b "$(_b test -d "$RESTORE_SRC/warp")"
        _kv meta:f "$RESTORE_SRC/backup_meta.txt"; } | api_obj ;;
    restore)
      [[ -n "${1:-}" ]] || { _api_usage "backup restore ПУТЬ [wgobf] [tunnels]"; return; }
      backup_restore "$@" ;;
    *) _api_usage "backup create [auto [ХРАНИТЬ]]|list|inspect ПУТЬ|restore ПУТЬ [wgobf] [tunnels]" ;;
  esac
}

# ── Туннели ───────────────────────────────────────────────
_api_tunnels() {
  local file name ip on
  case "${1:-}" in
    status|"")
      { _kv warp "$(_api_tun warp_is_up "$WARP_CONF" "$USQUE_CONF")"
        _kv xray "$(_api_tun xray_is_up "$XRAY_CONF")"
        _kv tun2socks "$(_api_tun t2s_is_up "$T2S_CONF")"
        _kv exits "$(_api_tun exits_is_up "$EXITS_DIR"/awg-exit-*.conf)"
        _kv cascade:n "$(cascade_count)"
        if dns_installed; then _kv dns "$(dns_running && echo up || echo off)"; else _kv dns none; fi
        _kv active "$(tunnel_conflict none)"; } | api_obj ;;
    panic) tunnels_panic_reset quiet; ok "Туннели выключены — клиенты идут напрямую" ;;
    clients)
      case "${2:-}" in
        warp) file="$WARP_PEERS" ;; xray) file="$XRAY_PEERS" ;;
        *) _api_usage "tunnels clients warp|xray"; return ;;
      esac
      # Списка ещё нет — туннель при включении возьмёт всех клиентов
      clients_name_ip | while IFS='|' read -r name ip; do
        if [[ ! -f "$file" ]] || peers_has "$file" "$ip"; then on=1; else on=0; fi
        printf '%s\t%s\t%s\n' "$name" "$ip" "$on"
      done | api_rows name ip on:b ;;
    client)
      [[ -n "${3:-}" ]] || { _api_usage "tunnels client warp|xray ИМЯ|all|none [on|off]"; return; }
      tunnel_client "$2" "$3" "${4:-}" ;;
    *) _api_usage "tunnels status|panic|clients warp|xray|client warp|xray ИМЯ|all|none [on|off]" ;;
  esac
}

_api_warp() {
  local a="${1:-}" be
  shift || true
  be=$(warp_backend)
  case "$a" in
    status)
      { _kv backend "$be"; _kv up:b "$(_b warp_is_up)"
        _kv configured:b "$([[ -f "$WARP_CONF" || -s "$USQUE_CONF" ]] && echo 1 || echo 0)"
        _kv failed:b "$(_b test -f "$WARP_STATE.failed")"
        _kv health:b "$(_b unit_active awg-warp-healthcheck.timer)"
        _kv wg_possible:b "$(_b warp_wg_possible)"; _kv usque_possible:b "$(_b warp_usque_possible)"; } | api_obj
      warp_status ;;
    install) if [[ "$be" == wg ]]; then warp_wg_install; else warp_usque_install; fi ;;
    up) warp_up ;;
    down) warp_down ;;
    restart) warp_down quiet; warp_up ;;
    health)
      case "${1:-}" in
        on) warp_health_on ;; off) warp_health_off; ok "Health-check выключен" ;;
        *) _api_usage "warp health on|off" ;;
      esac ;;
    license)
      [[ -n "${1:-}" ]] || { _api_usage "warp license КЛЮЧ"; return; }
      [[ "$be" == wg ]] || { err "Warp+ — только для бэкенда wg"; return 1; }
      warp_license_set "$1" ;;
    import)
      [[ "$be" == wg ]] || { err "Импорт профиля — только для бэкенда wg"; return 1; }
      _api_stdin
      [[ -s "$API_IN" ]] || { err "Профиль wgcf-profile.conf передаётся через stdin"; return 1; }
      warp_import < "$API_IN" ;;
    endpoint) warp_endpoint_best "${1:-}" ;;
    backend)
      [[ "${1:-}" =~ ^(wg|usque)$ ]] || { _api_usage "warp backend wg|usque"; return; }
      warp_set_backend "$1" ;;
    remove) warp_uninstall ;;
    *) _api_usage "warp status|install|up|down|restart|health on|off|license КЛЮЧ|import (stdin)|endpoint [СТРАНА]|backend wg|usque|remove" ;;
  esac
}

_api_xray() {
  local a="${1:-}"
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b xray_installed)"; _kv up:b "$(_b xray_is_up)"
        _kv version "$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
        _kv mode "$(xray_state_get tun_mode)"
        _kv tags:j "$(xray_tags | py json-list)"
        _kv balancer "$(xray_installed && py xray-balancer-get "$XRAY_CONF" 2>/dev/null || echo off)"
        _kv main "$(xray_installed && py xray-main-get "$XRAY_CONF" 2>/dev/null)"
        _kv per_client:b "$(xray_installed && _b xray_tun_supported || echo 0)"
        _kv clients:j "$(xray_client_outs | py json-rows name ip out)"
        _kv ru:b "$(_b xray_ru_on)"; } | api_obj
      xray_status ;;
    install) xray_install update ;;
    add)
      [[ -n "${1:-}" ]] || { _api_usage "xray add ССЫЛКА"; return; }
      xray_add_link "$1" ;;
    del)
      [[ -n "${1:-}" ]] || { _api_usage "xray del ТЕГ"; return; }
      xray_del_tag "$1" ;;
    balancer)
      [[ "${1:-}" =~ ^(random|roundRobin|leastPing|leastLoad|off)$ ]] \
        || { _api_usage "xray balancer random|roundRobin|leastPing|leastLoad|off"; return; }
      xray_installed || { err "Xray не установлен"; return 1; }
      xray_balancer "$1" ;;
    main)
      [[ -n "${1:-}" ]] || { _api_usage "xray main ТЕГ"; return; }
      xray_main_set "$1" ;;
    client)
      [[ -n "${2:-}" ]] || { _api_usage "xray client ИМЯ ТЕГ|default"; return; }
      xray_client_out "$1" "$2" ;;
    up) xray_up ;;
    down) xray_down ;;
    restart) xray_restart ;;
    ru)
      [[ "${1:-}" =~ ^(on|off)$ ]] || { _api_usage "xray ru on|off"; return; }
      xray_ru_set "$1" ;;
    ru-update) xray_ru_update ;;
    diag) xray_diagnose ;;
    fix) xray_fix ;;
    remove) xray_uninstall ;;
    *) _api_usage "xray status|install|add ССЫЛКА|del ТЕГ|balancer СТРАТЕГИЯ|main ТЕГ|client ИМЯ ТЕГ|default|up|down|restart|ru on|off|ru-update|diag|fix|remove" ;;
  esac
}

_api_t2s() {
  case "${1:-}" in
    status) { _kv up:b "$(_b t2s_is_up)"; _kv proxy "$(t2s_proxy)"; } | api_obj ;;
    up) t2s_up "${2:-}" ;;
    down) t2s_down ;;
    remove) t2s_uninstall ;;
    *) _api_usage "t2s status|up [IP:ПОРТ]|down|remove" ;;
  esac
}

_api_exits() {
  local a="${1:-}" n
  shift || true
  case "$a" in
    status)
      { _kv up:b "$(_b exits_is_up)"; _kv mode "$(exits_state_get mode)"
        _kv balancer "$(exits_state_get balancer)"; _kv single "$(exits_state_get single_exit)"
        _kv nodes:j "$(while IFS= read -r n; do
                          printf '%s\t%s\n' "$n" "$(_b ip link show "awg-exit-$n")"
                        done < <(exits_nodes) | py json-rows name up:b)"; } | api_obj
      exits_status; exits_list ;;
    add)
      [[ -n "${1:-}" ]] || { _api_usage "exits add ИМЯ < конфиг"; return; }
      _api_stdin
      [[ -s "$API_IN" ]] || { err "Конфиг ноды передаётся через stdin"; return 1; }
      exits_node_add "$1" "$API_IN" || return 1
      exits_reapply ;;
    del)
      [[ -n "${1:-}" ]] || { _api_usage "exits del ИМЯ"; return; }
      exits_node_del "$1" ;;
    up) exits_up "${1:-}" ;;
    down) exits_down ;;
    balance)
      [[ -n "${1:-}" ]] || { _api_usage "exits balance single НОДА|ecmp"; return; }
      exits_balance "$1" "${2:-}" ;;
    mode) exits_mode "${1:-}" ;;
    client)
      # all / none без второго аргумента — все клиенты; с ним — клиент с таким именем
      [[ "${1:-}" == all || "${1:-}" == none || -n "${2:-}" ]] || { _api_usage "exits client ИМЯ off|shared|НОДА | all | none"; return; }
      exits_client "$1" "${2:-}" ;;
    *) _api_usage "exits status|add ИМЯ (stdin)|del ИМЯ|up [all|peers]|down|mode all|peers|balance single НОДА|ecmp|client ИМЯ off|shared|НОДА|all|none" ;;
  esac
}

_api_cascade() {
  local a="${1:-}" p in dst out cm on
  shift || true
  case "$a" in
    list)
      cascade_rules | while IFS='|' read -r p in dst out cm; do
        on=0
        iptables-save -t nat 2>/dev/null | grep -qE -- "$(cascade_tag "$p" "$in")\"?( |$)" && on=1
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$in" "$dst" "$out" "$cm" "$on"
      done | api_rows proto in:n dst out:n comment applied:b ;;
    add)
      [[ -n "${3:-}" ]] || { _api_usage "cascade add udp|tcp|both ПОРТ IP [ПОРТ_ЦЕЛИ] [КОММЕНТАРИЙ]"; return; }
      cascade_rule_add "$1" "$2" "$3" "${4:-$2}" "${*:5}" ;;
    del)
      [[ -n "${2:-}" ]] || { _api_usage "cascade del udp|tcp ПОРТ"; return; }
      cascade_rule_del "$1" "$2" ;;
    reapply) cascade_reapply ;;
    clear) cascade_clear ;;
    remove) cascade_uninstall quiet ;;
    diag) cascade_diagnose ;;
    *) _api_usage "cascade list|add ...|del ПРОТО ПОРТ|reapply|clear|remove|diag" ;;
  esac
}

_api_dns() {
  local a="${1:-}" i
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b dns_installed)"; _kv running:b "$(_b dns_running)"
        _kv intercept:b "$(_b dns_rules_ok)"
        _kv upstream "$(sed -n 's/^server_names[[:space:]]*=[[:space:]]*//p' "$DNS_PROXY_CONF" 2>/dev/null | tr -d "[]'\"" | head -1)"
        _kv presets:j "$(for i in "${DNS_PRESETS[@]}"; do printf '%s\t%s\n' "${i%%|*}" "${i#*|}"; done | py json-rows names label)"
      } | api_obj
      dns_status ;;
    install) dns_install "${1:-}" ;;
    restart) dns_restart ;;
    upstream)
      [[ -n "${1:-}" ]] || { _api_usage "dns upstream ИМЯ[,ИМЯ...]"; return; }
      dns_set_upstream "$*" ;;
    remove) dns_uninstall "${1:-}" ;;
    *) _api_usage "dns status|install [force]|restart|upstream ИМЕНА|remove [purge]" ;;
  esac
}

_api_wgobf() {
  local a="${1:-}" name dir f dump now pub ip hs rx tx
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b wgobf_installed)"; _kv running:b "$(_b wgobf_running)"
        _kv version "$WGOBF_VERSION"
        if wgobf_installed; then
          _kv endpoint "$(wgobf_get ENDPOINT):$(wgobf_get PORT)"; _kv masking "$(wgobf_get MASKING)"
          _kv clean:b "$(wgobf_get ALLOW_CLEAN)"; _kv clients:n "$(wgobf_clients | grep -c . || true)"
        fi; } | api_obj
      wgobf_installed && wgobf_status
      return 0 ;;
    install) wgobf_install_opts "$@" ;;
    clients)
      wgobf_installed || { echo '[]' > "$API_DATA"; return 0; }
      dump=$(wg show "$WGOBF_IF" dump 2>/dev/null | tail -n +2 || true); now=$(date +%s)
      while IFS= read -r name; do
        pub=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^PublicKey = / {print $3; exit}' "$WGOBF_WG_CONF")
        ip=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^AllowedIPs = / {print $3; exit}' "$WGOBF_WG_CONF")
        # Рукопожатие и трафик с подъёма wgobf0 (счётчики WireGuard)
        hs="" rx="" tx=""          # у нового клиента строки в dump нет: прошлый не тянется
        read -r hs rx tx < <(awk -v k="$pub" '$1 == k {print $5, $6, $7; exit}' <<< "$dump") || true
        [[ "${hs:-}" =~ ^[0-9]+$ ]] && (( hs > 0 )) && hs=$((now - hs)) || hs=""
        [[ "${rx:-}" =~ ^[0-9]+$ ]] || rx=0; [[ "${tx:-}" =~ ^[0-9]+$ ]] || tx=0
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${ip%/32}" "$hs" "$rx" "$tx"
      done < <(wgobf_clients) | api_rows name ip ago:n rx:n tx:n ;;
    add|del|bundle)
      name="${1:-}"
      [[ -n "$name" ]] || { _api_usage "wgobf $a ИМЯ"; return; }
      wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
      case "$a" in
        add) wgobf_add_client "$name" || return 1 ;;
        del) wgobf_delete_client "$name"; return ;;
        bundle) wgobf_clients | grep -qxF "$name" || { err "Клиента $name нет"; return 1; } ;;
      esac
      dir="$WGOBF_CLIENTS/$name"
      [[ -f "$dir/phobos-link.txt" && -f "$dir/keenetic.txt" ]] || wgobf_write_bundle "$name" || return 1
      { _kv name "$name"; _kv dir "$dir"; _kv phobos:f "$dir/phobos-link.txt"
        _kv files:j "$(for f in wg.conf obfuscator.conf wg-direct.conf phobos.conf keenetic.txt README.txt install-linux.sh; do
                          [[ -f "$dir/$f" ]] && printf '%s\t%s\n' "$f" "$dir/$f"
                        done | py json-rows name path)"; } | api_obj ;;
    restart) wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
             wgobf_restart && ok "Перезапущено" ;;
    masking) wgobf_set_masking "${1:-}" ;;
    clean) wgobf_set_clean "${1:-}" ;;
    rotate-key) wgobf_rotate_key ;;
    remove) wgobf_remove quiet ;;
    *) _api_usage "wgobf status|install [ключ=значение...]|clients|add|del|bundle ИМЯ|restart|masking STUN|NONE|clean 0|1|rotate-key|remove" ;;
  esac
}

# ── Обновление, бот, удаление ─────────────────────────────
_api_update() {
  local a="${1:-}" v c
  shift || true
  case "$a" in
    status)
      v=$(update_available || true)
      { _kv version "$VERSION_SHOW"; _kv channel "$UPDATE_CHANNEL"; _kv repo "$UPDATE_REPO"
        _kv available "$v"; } | api_obj ;;
    check)
      v=$(update_peek) || { err "Канал обновлений недоступен ($UPDATE_REPO)"; return 1; }
      { _kv version "$VERSION_SHOW"; _kv latest "$v"; _kv channel "$UPDATE_CHANNEL"
        _kv newer:b "$( (( 10#$(ver_num "$v") > 10#$(ver_num "$VERSION") )) && echo 1 || echo 0)"; } | api_obj
      info "Текущая: $VERSION, в канале: $v" ;;
    install)
      update_fetch || return 1
      update_install "${1:-}" || return 1
      # Служебные скрипты перегенерирует уже новая версия
      v="$SCRIPT_PATH"; [[ -f "$v" ]] || v="$API_SELF"
      "$v" api version >/dev/null 2>&1 || true
      { _kv version "$UPDATE_NEW"; } | api_obj ;;
    channel)
      update_channel_set "${1:-}" || return 1
      ok "Канал: $(update_channel_label)" ;;
    changelog)
      update_changelog_fetch || { err "Список изменений недоступен ($UPDATE_REPO)"; return 1; }
      # В CHANGELOG канала версия новее, чем помнит кэш проверки (он живёт до
      # часа), — спросить канал сейчас: иначе «Доступна» и кнопка показали бы
      # прошлую версию, а обновление поставило бы новую
      v=$(grep -m1 -oE '^## v[0-9]+\.[0-9]+\.[0-9]+' <<< "$UPDATE_CHANGELOG" | cut -c4-)
      c=$(awk '{print $1; exit}' "$UPDATE_CACHE" 2>/dev/null)
      [[ "$c" =~ ^v?[0-9]+\.[0-9]+ ]] || c="v0.0.0"
      if [[ -n "$v" ]] && (( 10#$(ver_num "$v") > 10#$(ver_num "$c") )); then update_peek >/dev/null || true; fi
      py changelog-json "$VERSION" "$(update_available || true)" <<< "$UPDATE_CHANGELOG" > "$API_DATA" ;;
    *) _api_usage "update status|check|install [force]|channel stable|beta|changelog" ;;
  esac
}

_api_bot() {
  local a="${1:-}" line
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b bot_installed)"; _kv active:b "$(_b unit_active "$BOT_UNIT")"
        _kv version "$(bot_version)"; _kv proxy "$(bot_proxy_mask "$(bot_proxy_get)")"; } | api_obj ;;
    restart) unit_active "$BOT_UNIT" || { err "Бот не запущен"; return 1; }; bot_restart ;;
    update) bot_installed || { err "Бот не установлен"; return 1; }; bot_install ;;
    proxy)
      case "${1:-}" in
        get) { _kv proxy "$(bot_proxy_mask "$(bot_proxy_get)")"; } | api_obj ;;
        check)
          line=$(bot_proxy_get)
          [[ -n "$line" ]] || { info "Прокси не задан — бот ходит напрямую"; return 0; }
          if bot_proxy_probe "$line"; then ok "Через прокси Telegram отвечает"
          else err "Через прокси Telegram не отвечает"; return 1; fi ;;
        candidates)
          while IFS= read -r line; do
            printf '%s\t%s\t%s\n' "${line%%|*}" "${line#*|}" "$([[ "$line" == *"НЕ отвечает" ]] && echo 0 || echo 1)"
          done < <(_bot_proxy_candidates) | api_rows url label ok:b ;;
        set)
          [[ -n "${2:-}" ]] || { _api_usage "bot proxy set URL [force]"; return; }
          bot_proxy_set "$2" "${3:-}" ;;
        clear) bot_proxy_set "" ;;
        *) _api_usage "bot proxy get|check|candidates|set URL [force]|clear" ;;
      esac ;;
    webapp)
      case "${1:-}" in
        get) { _kv port "$(webapp_port)"; _kv url "$(webapp_url || true)"; } | api_obj ;;
        port) webapp_port_set "${2:-}" ;;
        *) _api_usage "bot webapp get|port ПОРТ|off" ;;
      esac ;;
    uninstall) bot_uninstall quiet ;;
    *) _api_usage "bot status|restart|update|proxy ...|webapp ...|uninstall" ;;
  esac
}

# ── HTTPS-сертификат ──────────────────────────────────────
_api_cert() {
  local a="${1:-status}"
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b cert_installed)"; _kv kind "$(cert_get kind)"; _kv name "$(cert_get name)"
        _kv source "$(cert_get source)"
        _kv expires:n "$(cert_expires)"; _kv renew:b "$(_b unit_enabled "$CERT_TIMER")"
        _kv port80 "$(cert_port80_holder)"; _kv port80_unit "$(cert_port80_unit)"
        _kv found:n "$(cert_find | grep -c . || true)"; _kv ip "$(public_ip_cached)"; } | api_obj ;;
    find) cert_find | api_rows name source cert key expires:n ;;
    use)
      [[ -n "${1:-}" ]] || { _api_usage "cert use ПУТЬ_СЕРТИФИКАТА (из cert find)"; return; }
      cert_use "$1" && webapp_fw ;;
    issue) cert_issue "$@" && webapp_fw ;;
    remove) cert_remove ;;
    *) _api_usage "cert status|find|use ПУТЬ|issue ip [pause]|issue domain ИМЯ [pause]|remove" ;;
  esac
}

# ── Веб-панель ────────────────────────────────────────────
# Пароль в ответе — только новый, сгенерированный здесь (install, password):
# на сервере лежит лишь его хеш, прежний показать нельзя.
_api_web_access() {
  { _kv url "$(web_url)"; _kv user "$(web_conf_get WEB_USER)"; _kv password "${WEB_PASS_SHOWN:-}"; } | api_obj
}

_api_web() {
  local a="${1:-status}"
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b web_installed)"; _kv active:b "$(_b web_active)"
        if web_installed; then
          _kv url "$(web_url)"; _kv user "$(web_conf_get WEB_USER)"; _kv port:n "$(web_conf_get WEB_PORT)"
        fi
        _kv cert:b "$(_b cert_installed)"; _kv cert_name "$(cert_get name)"; _kv cert_expires:n "$(cert_expires)"
      } | api_obj ;;
    install)
      web_installed && { err "Веб-панель уже установлена — новый пароль: web password"; return 1; }
      web_install_auto && _api_web_access ;;
    password) web_password_new && _api_web_access ;;
    path) web_path_new && _api_web_access ;;
    restart|start)
      web_installed || { err "Веб-панель не установлена"; return 1; }
      web_restart ;;
    stop) web_stop ;;
    remove) web_installed || { err "Веб-панель не установлена"; return 1; }; web_remove quiet ;;
    *) _api_usage "web status|install|password|path|restart|start|stop|remove" ;;
  esac
}

# ── Антисканер ────────────────────────────────────────────
_api_antiscan_lists() {  # id<TAB>подпись<TAB>включён<TAB>записей
  local id file label min n on f
  while IFS=$'\t' read -r id file label min; do
    f="$ANTISCAN_DIR/lists/$id.list" n=0 on=0
    [[ -f "$f" ]] && n=$(( $(_antiscan_parse 4 < "$f" | wc -l) + $(_antiscan_parse 6 < "$f" | wc -l) ))
    [[ " $(_antiscan_enabled_lists) " == *" $id "* ]] && on=1
    printf '%s\t%s\t%s\t%s\n' "$id" "$label" "$on" "$n"
  done < <(_antiscan_lists)
}

_api_antiscan() {
  local a="${1:-status}" e on=0
  shift || true
  case "$a" in
    status)
      read -r -a e <<< "$(_antiscan_get ENTRIES)"
      antiscan_on && on=1
      { _kv enabled:b "$on"; _kv active:b "$( (( on )) && _b antiscan_rules_ok || echo 0)"
        _kv v4:n "${e[0]:-0}"; _kv v6:n "${e[1]:-0}"
        _kv updated:n "$(_antiscan_get UPDATED)"; _kv error "$(_antiscan_get ERROR)"
        _kv dropped:n "$( (( on )) && antiscan_dropped || echo 0)"
        _kv lists:j "$(_api_antiscan_lists | py json-rows id name on:b entries:n)"
        _kv top:j "$( (( on )) && antiscan_top 5 | py json-rows packets:n net org || echo '[]')"
        _kv allow:j "$(_antiscan_allow_rows | py json-list)"
        _kv ssh:j "$(_antiscan_ssh_peers | py json-list)"
      } | api_obj ;;
    on) antiscan_enable ;;
    off) antiscan_disable ;;
    update) antiscan_update ;;
    lists) antiscan_lists_set "$@" ;;
    allow) antiscan_allow "$@" ;;
    *) _api_usage "antiscan status|on|off|update|lists scan,skipa,gov|allow add|del АДРЕС" ;;
  esac
}

_api_uninstall() {
  local o
  for o in "$@"; do [[ "$o" =~ ^(bot|wgobf|web|self)$ ]] || { _api_usage "uninstall [bot] [wgobf] [web] [self]"; return; }; done
  uninstall_all "$@"
}

# ── Журналы ───────────────────────────────────────────────
_api_log() {
  local name="${1:-}" n="${2:-60}" file="" unit=""
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 500 )) || n=60
  case "$name" in
    manager) file="$LOG_FILE" ;;         install) file="$INSTALL_LOG" ;;
    module) file="$MOD_LOG" ;;           expire) file="$EXPIRE_LOG" ;;
    cascade) file="$CASCADE_LOG" ;;      warp-health) file="$WARP_HEALTH_LOG" ;;
    dns-health) file="$DNS_HEALTH_LOG" ;; usque) file="$USQUE_LOG" ;;
    awg) unit="awg-quick@$AWG_IF" ;;     warp) unit=awg-warp.service ;;
    xray) unit="$XRAY_UNIT" ;;           xray-routing) unit="$XRAY_ROUTING_UNIT" ;;
    tun2socks) unit="$T2S_UNIT" ;;       exits) unit="$EXITS_UNIT" ;;
    dns) unit="$DNS_UNIT" ;;             wgobf) unit="$WGOBF_UNIT" ;;
    bot) unit="$BOT_UNIT" ;;             web) file="$WEB_LOG" ;;
    antiscan) file="$ANTISCAN_LOG" ;;
    *) _api_usage "log manager|install|module|expire|cascade|warp-health|dns-health|usque|awg|warp|xray|xray-routing|tun2socks|exits|dns|wgobf|bot|web|antiscan [строк]"; return ;;
  esac
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || { info "Журнала $file нет"; return 0; }
    tail -n "$n" "$file"
  else
    journalctl -u "$unit" -n "$n" --no-pager 2>/dev/null || { info "Журнал $unit недоступен"; return 0; }
  fi
}

# ── Фоновые задачи ────────────────────────────────────────
_api_job_unit() { echo "awg2-job-$1"; }

_api_job_start() {
  local id dir unit envs=()
  (( $# )) || { _api_usage "job start КОМАНДА [аргументы]"; return; }
  [[ "$1" == job ]] && { err "Задача не запускает задачи"; return 2; }
  mkdir -p "$API_JOBS" && chmod 700 "$API_JOBS"
  # Старые завершённые задачи — через 3 дня
  find "$API_JOBS" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true
  id="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $((RANDOM % 65536)))"
  dir="$API_JOBS/$id"
  mkdir -m 700 "$dir" || return 1
  printf '%s\0' "$@" > "$dir/cmd"
  if _api_wants_stdin "$@"; then _api_stdin; cp "$API_IN" "$dir/stdin"; fi
  : > "$dir/log"
  unit=$(_api_job_unit "$id")
  { _kv id "$id"; _kv cmd "$*"; _kv started:n "$(date +%s)"; _kv unit "$unit"; } | py json-kv > "$dir/meta.json"
  [[ -n "${AWG2_UPDATE_CHANNEL:-}" ]] && envs+=("--setenv=AWG2_UPDATE_CHANNEL=$AWG2_UPDATE_CHANNEL")
  if command -v systemd-run &>/dev/null \
     && systemd-run --unit="$unit" --collect --quiet --description="awg2: $*" ${envs[@]+"${envs[@]}"} \
          "$API_SELF" api job run "$id" &>/dev/null; then
    :
  else
    # Без systemd (контейнер) — отдельной сессией, чтобы пережить вызвавшего
    setsid "$API_SELF" api job run "$id" </dev/null &>/dev/null 8>&- &
    echo "$!" > "$dir/pid"
  fi
  { _kv id "$id"; _kv unit "$unit"; } | api_obj
  ok "Задача $id: $*"
}

_api_job_active() {  # id → 0, если задача ещё выполняется
  local pid
  if [[ -f "$API_JOBS/$1/pid" ]]; then
    # Не просто kill -0: после перезагрузки PID может достаться чужому процессу,
    # и задача числилась бы «идёт» вечно.
    pid=$(cat "$API_JOBS/$1/pid")
    [[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "api job run $1"
  else
    unit_active "$(_api_job_unit "$1")"
  fi
}

_api_job() {
  local a="${1:-}" id="${2:-}" active=() d
  case "$a" in
    start) shift; _api_job_start "$@" ;;
    status)
      [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ && -d "$API_JOBS/$id" ]] || { err "Задачи ${id:-?} нет"; return 1; }
      py api-job-status "$API_JOBS/$id" "${3:-0}" "$(_b _api_job_active "$id")" > "$API_DATA" ;;
    list)
      for d in "$API_JOBS"/*/; do
        d="${d%/}"; d="${d##*/}"
        [[ -d "$API_JOBS/$d" ]] || continue
        [[ -f "$API_JOBS/$d/result.json" ]] || ! _api_job_active "$d" || active+=("$d")
      done
      py api-jobs "$API_JOBS" ${active[@]+"${active[@]}"} > "$API_DATA" ;;
    *) _api_usage "job start КОМАНДА...|status ID [СМЕЩЕНИЕ]|list" ;;
  esac
}

# ── Диспетчер ─────────────────────────────────────────────
# Команды только для чтения идут мимо очереди: сводка не должна ждать,
# пока задача собирает модуль.
_api_readonly() {
  local a="${1:-}" b="${2:-}" c="${3:-}"
  # Разделы, где всё — чтение (задача job start сама идёт через замок, когда запустится)
  case "$a" in status|version|help|mimicry|log|job|diag) return 0 ;; esac
  # Дальше — точные команды по словам, а не маски по строке: лишнее слово в
  # конце или слово с пробелом внутри («allow add X info») чтением не станут.
  # Пишущие подкоманды «читающих» разделов (bot proxy set, bot webapp port,
  # server params set — правят общие файлы) сюда не попадают — в очередь.
  [[ "$a $b" != *[[:space:]]*[[:space:]]* ]] || return 1
  case "$a $b $c" in
    "server params "|"server params check"|"bot proxy get"|"bot proxy check"|"bot proxy candidates"|"bot webapp get") return 0 ;;
  esac
  case "$a $b" in
    "server info"|"module report"|"module tags"|"module check"|"module backups"|"clients "|"clients list"|\
    "client conf"|"traffic daily"|"traffic now"|"backup list"|"backup inspect"|"tunnels "|"tunnels status"|\
    "tunnels clients"|"warp status"|"xray status"|"xray diag"|"t2s status"|"exits status"|"cascade list"|\
    "cascade diag"|"dns status"|"wgobf status"|"wgobf clients"|"update status"|"update check"|"update changelog"|\
    "bot status"|"cert "|"cert status"|"cert find"|"web status"|"antiscan status") return 0 ;;
  esac
  return 1
}

_api_lock() {
  local wait="${API_LOCK_WAIT:-20}" holder
  mkdir -p "$STATE_DIR"
  exec 8>>"$API_LOCK" || return 0
  if ! flock -w "$wait" 8; then
    holder=$(cat "$API_LOCK.info" 2>/dev/null)
    err "Идёт другая операция${holder:+ ($holder)} — повтори, когда она закончится"
    return 75
  fi
  printf '%s\n' "$*" > "$API_LOCK.info" 2>/dev/null || true
}

api_dispatch() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    version) { _kv version "$VERSION_SHOW"; _kv api:n "$API_VERSION"; _kv channel "$UPDATE_CHANNEL"
               _kv update "$(update_available || true)"; } | api_obj ;;
    status) _api_status ;;
    server) _api_server "$@" ;;
    module) _api_module "$@" ;;
    clients) _api_clients "$@" ;;
    client) _api_client "$@" ;;
    mimicry) _api_mimicry ;;
    traffic) _api_traffic "$@" ;;
    diag) _api_diag "$@" ;;
    backup) _api_backup "$@" ;;
    tunnels) _api_tunnels "$@" ;;
    warp) _api_warp "$@" ;;
    xray) _api_xray "$@" ;;
    t2s) _api_t2s "$@" ;;
    exits) _api_exits "$@" ;;
    cascade) _api_cascade "$@" ;;
    dns) _api_dns "$@" ;;
    wgobf) _api_wgobf "$@" ;;
    update) _api_update "$@" ;;
    bot) _api_bot "$@" ;;
    cert) _api_cert "$@" ;;
    web) _api_web "$@" ;;
    antiscan) _api_antiscan "$@" ;;
    uninstall) _api_uninstall "$@" ;;
    log) _api_log "$@" ;;
    job) _api_job "$@" ;;
    help)
      echo "Разделы: status server module clients client mimicry traffic diag backup tunnels warp xray t2s"
      echo "         exits cascade dns wgobf update bot cert web antiscan uninstall log job version"
      echo "Подсказка по разделу: awg2 api РАЗДЕЛ" ;;
    *) err "Неизвестная команда: $cmd — awg2 api help"; return 2 ;;
  esac
}

# Подготовка задачи: команда, stdin и журнал — из её каталога.
_api_job_prepare() {
  local dir="$API_JOBS/${1:-}"
  [[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ && -f "$dir/cmd" ]] || return 1
  mapfile -d '' -t API_ARGS < "$dir/cmd"
  [[ -f "$dir/stdin" ]] && cp "$dir/stdin" "$API_IN"
  API_STDIN_READ=1
  API_LOG="$dir/log"
  API_RESULT="$dir/result.json"
  API_LOCK_WAIT=3600
}

api_main() {
  local rc=0 envelope
  AUTO_MODE=1 API_MODE=1
  API_SELF=$(readlink -f "$0")
  API_JOBS="$STATE_DIR/jobs" API_LOCK="$STATE_DIR/api.lock"
  if ! command -v python3 &>/dev/null; then
    echo '{"ok": false, "rc": 1, "data": null, "log": "", "error": "нет python3"}'
    return 1
  fi
  mktmp API_DATA && mktmp API_IN || { echo '{"ok": false, "rc": 1, "data": null, "log": "", "error": "mktemp"}'; return 1; }
  if [[ "${1:-}" == job && "${2:-}" == run ]]; then
    _api_job_prepare "${3:-}" || { echo '{"ok": false, "rc": 2, "data": null, "log": "", "error": "нет такой задачи"}'; return 2; }
  else
    mktmp API_LOG || return 1
    API_ARGS=("$@")
  fi

  # 3 — настоящий stdout для ответа, 4 — настоящий stdin для _api_stdin
  exec 3>&1 4<&0 >>"$API_LOG" 2>&1 </dev/null
  update_channel_init
  if ! need_cmds curl:curl iptables:iptables ip:iproute2 ss:iproute2 >/dev/null; then
    err "Не удалось поставить базовые пакеты (curl, iptables, iproute2)"; rc=1
  else
    helpers_refresh || true
    expire_watchdog || true
    antiscan_watchdog || true
    if _api_readonly "${API_ARGS[@]}"; then
      api_dispatch "${API_ARGS[@]}" || rc=$?
    else
      _api_lock "${API_ARGS[*]}" || rc=$?
      (( rc )) || { api_dispatch "${API_ARGS[@]}" || rc=$?; }
      log_info "api: ${API_ARGS[*]} → $rc"
    fi
  fi
  exec 1>&3 3>&- 4<&-

  envelope=$(py api-envelope "$rc" "$API_DATA" "$API_LOG")
  if [[ -n "$API_RESULT" ]]; then
    printf '%s\n' "$envelope" | write_file "$API_RESULT" 600
  else
    printf '%s\n' "$envelope"
  fi
  return "$rc"
}

# ═════ cli ═════
# Точка входа: аргументы командной строки (их вызывают бот и таймеры) и меню.

usage() {
  cat <<EOF
awg2 $VERSION — AmneziaWG 2.0 / 3.1 для Ubuntu 24.04+ и Debian 12+

  awg2                          меню
  awg2 --auto                   установка сервера без вопросов (AWG_PROFILE, AWG_PROTO, AWG_PORT)
  awg2 --add-client ИМЯ         добавить клиента
  awg2 --tunnel Т up|down|restart
                                Т: warp | xray | tun2socks | exits | dns
  awg2 --xray-balancer С        С: random | roundRobin | leastPing | leastLoad | off
  awg2 --xray-ru-update         обновить РФ-базы Xray
  awg2 --wgobf add|del|bundle ИМЯ | rotate-key | restart
  awg2 --status                 сводка состояния
  awg2 api КОМАНДА              JSON-интерфейс для Telegram-бота (awg2 api help)
  awg2 --version

Переменные: AUTOINSTALL=1 — то же, что --auto; AWG2_UPDATE_CHANNEL=beta — разовый запуск на бета-канале.
EOF
}

# Команды, без которых не работает ни один раздел.
base_deps() {
  need_cmds python3:python3 curl:curl iptables:iptables ip:iproute2 ss:iproute2 >/dev/null \
    || { err "Не удалось поставить базовые пакеты (python3, curl, iptables, iproute2)"; exit 1; }
}

tunnel_cli() {  # туннель действие
  local t="$1" a="$2" up down
  [[ "$a" =~ ^(up|down|restart)$ ]] || { err "Действие: up | down | restart"; return 1; }
  case "$t" in
    warp) up=warp_up; down=warp_down ;;
    xray) up=xray_up; down=xray_down ;;
    tun2socks) up=t2s_up; down=t2s_down ;;
    exits) up=exits_up; down=exits_down ;;
    dns) [[ "$a" == down ]] && { err "DNS: только up | restart"; return 1; }
         dns_restart; return ;;
    *) err "Туннель: warp | xray | tun2socks | exits | dns"; return 1 ;;
  esac
  case "$a" in
    up) "$up" ;;
    down) "$down" ;;
    restart) "$down" quiet; "$up" ;;
  esac
}

_on_interrupt() {
  _cleanup_tmp
  echo ""
  warn "Прервано"
  exit 130
}

main() {
  local post=""
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "awg2 $VERSION_SHOW"; exit 0 ;;
  esac
  (( EUID == 0 )) || { echo "awg2: нужен root — sudo awg2" >&2; exit 1; }
  log_init
  trap _cleanup_tmp EXIT
  trap _on_interrupt INT TERM
  # Машинный интерфейс бота: весь вывод — внутри одного JSON-ответа
  [[ "${1:-}" == api ]] && { shift; api_main "$@"; exit; }
  update_channel_init
  base_deps
  helpers_refresh || true
  expire_watchdog || true

  case "${1:-}" in
    --status) do_status; exit 0 ;;
    --post-update) post="${2:-?}" ;;
    --interactive) ;;
    --auto|-auto) AUTO_MODE=1; do_autoinstall; exit ;;
    --add-client)
      [[ -n "${2:-}" ]] || { err "Использование: awg2 --add-client ИМЯ"; exit 1; }
      AUTO_MODE=1
      client_create "$2" && exit 0 || exit 1 ;;
    --tunnel) AUTO_MODE=1; tunnel_cli "${2:-}" "${3:-}" && exit 0 || exit 1 ;;
    --xray-balancer)
      [[ -n "${2:-}" ]] || { err "Использование: awg2 --xray-balancer random|roundRobin|leastPing|leastLoad|off"; exit 1; }
      AUTO_MODE=1
      xray_installed || { err "Xray не установлен"; exit 1; }
      xray_balancer "$2" && exit 0 || exit 1 ;;
    --xray-ru-update)
      xray_ru_on || { info "РФ-правила Xray выключены — обновлять нечего"; exit 0; }
      xray_ru_update || exit 1
      info "Новые базы подхватятся при перезапуске туннеля Xray"
      exit 0 ;;
    --wgobf) AUTO_MODE=1; wgobf_cli "${2:-}" "${3:-}" && exit 0 || exit 1 ;;
    "") [[ "${AUTOINSTALL:-}" == 1 ]] && { AUTO_MODE=1; do_autoinstall; exit; } ;;
    *) err "Неизвестный аргумент: $1"; info "awg2 --help — список аргументов"; exit 1 ;;
  esac

  log_info "=== AWG Toolza $VERSION_SHOW ==="
  [[ -z "$post" ]] && { self_install_offer || true; }
  update_check_async || true
  upstream_refresh_async || true
  client_files_sync_suffix || true
  main_menu "$post"
}

# ═════ встроенный Python ═════
# CPS_GENERATOR_BEGIN v2 — генератор I1-I5 (порт payloadGen). Бот вырезает
# этот блок из установленного awg2: якоря не переименовывать.
_CPS_GENERATOR='
import sys, os, struct, secrets, signal, time

try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)  # чистое поведение при обрыве пайпа
except Exception:
    pass

# ================================================================
# Порт payloadGen (github.com/Sketchystan1/payloadGen) на Python.
# Соответствие файлам оригинала:
#   app.js       -> CONFIG, DOMAIN_POOL, chunk_payload, формат вывода
#   generators.js-> генераторы пакетов и сборка TLS ClientHello
#   crypto.js    -> HPKE (ECH) и защита QUIC Initial (RFC 9001)
# Структура пакетов и порядок полей повторяют оригинал байт в байт;
# отличается только источник случайности (secrets вместо WebCrypto).
# ================================================================

_WARNED = set()

def _warn_once(msg):
    # Генератор строит до 5 пакетов за запуск, причина деградации у них общая:
    # один и тот же дефект не должен засорять stderr пять раз.
    if msg in _WARNED:
        return
    _WARNED.add(msg)
    sys.stderr.write("[CPS] WARN: %s\n" % msg)

# == Utilities (generators.js: randomBytes/u16/u24/u32/concatBytes) ==
def rb(n):
    return secrets.token_bytes(max(0, int(n)))

def zeros(n):
    return b"\x00" * max(0, int(n))

def ri(max_exclusive):
    # randomIntExclusive: 0 <= x < max_exclusive
    if max_exclusive <= 1:
        return 0
    return secrets.randbelow(int(max_exclusive))

def rr(a, b):
    # включительный диапазон [a, b]
    if a > b:
        a, b = b, a
    return a + secrets.randbelow(b - a + 1)

def rc(items):
    return items[ri(len(items))]

def ru32():
    return int.from_bytes(rb(4), "big")

def u16(v):
    return struct.pack(">H", v & 0xFFFF)

def u24(v):
    return struct.pack(">I", v & 0xFFFFFF)[1:]

def u32(v):
    return struct.pack(">I", v & 0xFFFFFFFF)

def enc_text(s):
    return str(s).encode("utf-8")

def to_hex(b):
    return b.hex()

def read_u16(b, off):
    return (b[off] << 8) | b[off + 1]

# == Динамические поля пакета мимикрии (теги <r>/<rc>/<rd>) ==
#
# Строка I, собранная только из <b 0x...>, — это замороженный снимок: модуль
# кладёт его в буфер один раз при setconf и шлёт БАЙТ В БАЙТ при каждой попытке
# рукопожатия (send.c: jp_spec_applymods + wg_socket_send_buffer_to_peer, раз в
# ~120 с). Повторяющийся один и тот же UDP-пакет — ровно тот статистический
# признак, против которого делалась 3.1.
#
# Теги <r N> / <rc N> / <rd N> модуль пересчитывает на КАЖДОЙ отправке
# (junk.c: random_byte_modifier / random_char_modifier / random_digit_modifier,
# вызываются из jp_spec_applymods перед каждым send), то есть поле становится
# заново случайным. Порядок тегов в строке сохраняется: jp_parse_tags кладёт их
# через list_add (в обратном порядке), а сборка идёт list_for_each_entry_reverse
# — на выходе порядок написания.
#
# Помечать можно ДАЛЕКО не всё. Поле годится, только если оно случайно в самом
# протоколе и от него ничего не считается:
#   • нельзя всё, что покрыто контрольной суммой или AEAD (STUN FINGERPRINT
#     CRC32, QUIC Initial — ключи выводятся из DCID, заголовок входит в AAD);
#   • нельзя поле, встречающееся в пакете дважды (SIP Call-ID в двух заголовках,
#     RTCP SSRC): теги независимы, и две копии разъедутся. Это ловится
#     автоматически — помечается только уникальное вхождение;
#   • в текстовых протоколах нельзя <r> (двоичный мусор внутри текста) — только
#     <rc>/<rd>.
# Длина поля тегом сохраняется, поэтому длины и Content-Length остаются верными.
#
# Ограничение движка: длина <r/rc/rd> не больше 1000 байт.
DYN_TAG_MAX = 1000

_DYN = []

def dyn_reset():
    del _DYN[:]

def dyn(value, tag="r"):
    """Помечает поле как заново случайное при каждой отправке. Возвращает его же."""
    token = value if isinstance(value, bytes) else enc_text(value)
    if 2 <= len(token) <= DYN_TAG_MAX:
        _DYN.append((token, tag))
    return value

def dyn_all_unique(payload):
    """Все ли помеченные поля встречаются в пакете ровно один раз."""
    return all(payload.count(token) == 1 for token, _ in _DYN)


def build_tagged_line(payload):
    """Строка I: статические куски <b 0x..> вперемешку с тегами помеченных полей."""
    holes = []
    for token, tag in _DYN:
        # Неуникальное вхождение пропускаем: разные вхождения одного поля
        # обязаны совпадать, а два тега дали бы разные значения.
        if payload.count(token) != 1:
            continue
        holes.append((payload.find(token), len(token), tag))
    holes.sort()
    out = []
    pos = 0
    for start, length, tag in holes:
        if start < pos:                 # перекрытие с уже вставленным тегом
            continue
        if start > pos:
            out.append("<b 0x%s>" % to_hex(payload[pos:start]))
        out.append("<%s %d>" % (tag, length))
        pos = start + length
    if pos < len(payload):
        out.append("<b 0x%s>" % to_hex(payload[pos:]))
    return "".join(out)

def quic_varint(value):
    # encodeQuicVarInt (RFC 9000 §16)
    if value < 0:
        raise ValueError("QUIC varint cannot encode a negative value")
    if value < 64:
        return bytes([value])
    if value < 16384:
        return bytes([0x40 | ((value >> 8) & 0x3F), value & 0xFF])
    if value < 1073741824:
        return bytes([0x80 | ((value >> 24) & 0x3F), (value >> 16) & 0xFF,
                      (value >> 8) & 0xFF, value & 0xFF])
    raise ValueError("QUIC value is too large to encode in this utility")

def crc32_stun(data):
    # crc32 из generators.js (полином 0xEDB88320, тот же, что в zlib)
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
    return (~crc) & 0xFFFFFFFF

def ntp_timestamp(epoch_seconds=None):
    # encodeNtpTimestamp: секунды с 1900 + дробная часть в 2^-32
    ms = int((epoch_seconds if epoch_seconds is not None else time.time()) * 1000)
    seconds = (ms // 1000) + 2208988800
    fraction = int(((ms % 1000) / 1000.0) * 0x100000000) & 0xFFFFFFFF
    return u32(seconds) + u32(fraction)

def random_private_ipv4():
    pools = [
        [10, ri(256), ri(256), 10 + ri(200)],
        [172, 16 + ri(16), ri(256), 10 + ri(200)],
        [192, 168, ri(256), 10 + ri(200)],
    ]
    return ".".join(str(x) for x in rc(pools))

# == Константы (app.js: CONFIG / CHROME_BROWSER_DATA, generators.js: пулы) ==
DEFAULT_HOST = "yastatic.net"          # запасной хост, если домен не передали
DEFAULT_MTU = 1280                     # CONFIG.defaultMtu
MAX_OUTPUT_LINES = 5                   # CONFIG.maxOutputLines (I1-I5)

# Резервный пул на случай, когда домен не передали (например, вызов из бота).
# Список payloadGen (ya.ru, gosuslugi.ru, vk.com, ...) отсюда убран намеренно:
# он одинаков у всех пользователей того генератора, поэтому сам является
# признаком. Здесь — инфраструктурные хосты с постоянным фоновым трафиком.
# Тот же список продублирован в awg2 как CPS_RU_DOMAINS, где он ещё и
# проверяется на доступность перед генерацией.
RU_DOMAIN_POOL = [
    "yastatic.net", "mc.yandex.ru", "avatars.mds.yandex.net",
    "ok.ru", "st.mycdn.me", "vk.ru",
    "kinopoisk.ru", "hh.ru", "2gis.ru", "lenta.ru", "mos.ru", "citilink.ru",
]

CHROME_DEFAULT_VERSION = "147.0.7727.50"   # CHROME_BROWSER_DATA.defaultVersion

SSDP_SEARCH_TARGETS = [
    "ssdp:all",
    "upnp:rootdevice",
    "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:device:MediaServer:1",
]
SSDP_USER_AGENTS = [
    "Microsoft-Windows/10.0 UPnP/1.0 SSDP-Discovery/1.0",
    "macOS/14.7.6 UPnP/1.1 ControlPoint/1.0",
    "Linux/6.8 UPnP/1.1 Portable SDK for UPnP devices/1.14.18",
]

DNS_QUERY_TYPES = [0x0001, 0x001C, 0x0041]

TWILIO_STUN_SERVERS = ["global.stun.twilio.com"]
TWILIO_TURN_SERVERS = [
    "global.turn.twilio.com", "de01-1.turn.twilio.com", "de01-2.turn.twilio.com",
    "sg01-1.turn.twilio.com", "sg01-2.turn.twilio.com", "us1-1.turn.twilio.com",
    "us1-2.turn.twilio.com", "us2-1.turn.twilio.com", "us2-2.turn.twilio.com",
    "ie01-1.turn.twilio.com", "ie01-2.turn.twilio.com", "jp01-1.turn.twilio.com",
    "jp01-2.turn.twilio.com", "au01-1.turn.twilio.com", "br01-1.turn.twilio.com",
    "in01-1.turn.twilio.com",
]
TWILIO_REALM = "twilio.com"
GOOGLE_STUN_SERVERS = [
    "stun.l.google.com", "stun1.l.google.com", "stun2.l.google.com",
    "stun3.l.google.com", "stun4.l.google.com", "stun.services.googleapis.com",
    "stun.phonebox.google.com", "stun.stunprotocol.org",
]
CLOUDFLARE_WEBRTC_SERVERS = [
    "turn.cloudflare.com", "webrtc.cloudflare.net",
    "spectrum.cloudflare.com", "calls.cloudflare.com",
]
CLOUDFLARE_REALM = "cloudflare.com"
META_WEBRTC_SERVERS = [
    "turn.instagram.com", "stun.whatsapp.com", "edge-turn.whatsapp.com",
    "turn-messenger.whatsapp.com", "star.c10r.facebook.com",
    "turn.dnsalias.com", "edge-chat.facebook.com",
]
META_REALM = "facebook.com"

SIP_USER_AGENTS = [
    "Linphone/5.2.5 (belle-sip/5.3.90)", "Zoiper rv2.10.15-mod",
    "MicroSIP/3.21.6", "baresip 3.8.0", "Blink 6.0.4 (Windows)",
    "Asterisk PBX 20.7.0",
]
SIP_SERVER_NAMES = [
    "Kamailio (5.8.1)", "OpenSIPS (3.5.1)", "Asterisk PBX (20.7.0)",
    "FreeSWITCH (1.10.12)", "Yate SIP Router (7.0.0)",
]
SIP_DISPLAY_NAMES = [
    "Alice Carter", "Bob Smith", "Support Desk", "Sales Queue",
    "NOC Bridge", "Reception", "Operator", "Dispatch",
]
SIP_ACCEPT_LANGUAGES = [
    "en", "en-US", "en-US,en;q=0.9",
    "tr-TR,tr;q=0.9,en;q=0.7", "de-DE,de;q=0.8,en;q=0.6",
]
SIP_SUPPORTED_HEADERS = [
    "replaces, outbound, path, timer",
    "outbound, path, gruu, 100rel",
    "timer, replaces, resource-priority",
    "gruu, outbound, path, sec-agree",
]
SIP_ALLOW_HEADERS = [
    "INVITE, ACK, CANCEL, OPTIONS, BYE, REFER, NOTIFY, INFO, MESSAGE, SUBSCRIBE",
    "INVITE, ACK, CANCEL, OPTIONS, BYE, UPDATE, MESSAGE",
    "INVITE, ACK, CANCEL, OPTIONS, BYE, PRACK, UPDATE",
]
SIP_ALLOW_EVENTS_HEADERS = [
    "presence, message-summary, refer",
    "dialog, presence, refer",
    "presence, kpml, talk",
]
SIP_DOMAIN_PREFIXES = ["sip", "voip", "pbx", "edge", "gw", "proxy", "media", "trunk"]
SIP_DOMAIN_BASES = ["biloxi", "atlanta", "voicehub", "carriernet", "softswitch",
                    "callbridge", "telecloud", "voiplab"]
SIP_DOMAIN_SUFFIXES = ["com", "net", "org", "io", "cloud"]
SIP_LOCAL_PORTS = [5060, 5062, 5070, 5080, 5160]
SIP_AUDIO_CODEC_PROFILES = [
    {"payloads": ["0 PCMU/8000", "8 PCMA/8000", "96 opus/48000/2",
                  "101 telephone-event/8000"], "formatList": "0 8 96 101"},
    {"payloads": ["0 PCMU/8000", "18 G729/8000", "101 telephone-event/8000"],
     "formatList": "0 18 101"},
    {"payloads": ["8 PCMA/8000", "97 iLBC/8000", "101 telephone-event/8000"],
     "formatList": "8 97 101"},
]

# QUIC v1 (RFC 9000/9001): версия на проводе и база первого байта Initial
QUIC_WIRE_VERSION = 0x00000001
QUIC_INITIAL_HEADER_BASE = 0xC0
QUIC_V1_INITIAL_SALT = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
CURL_QUIC_PROFILE_ID = "curl_h3"

# ================================================================
# Криптография (порт crypto.js). Всё опционально: без python3-cryptography
# генератор продолжает работать, но QUIC Initial уходит без шифрования,
# а ECH — без реального HPKE. Об этом честно пишется в stderr.
# ================================================================
_CRYPTO_OK = True
try:
    import hmac as _hmac
    import hashlib as _hashlib
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey, X25519PublicKey)
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
# BaseException, а не Exception: при поломанной сборке python3-cryptography
# (нет _cffi_backend, рассинхрон с pyo3 после частичного обновления) импорт
# падает с PanicException, а она наследуется напрямую от BaseException и мимо
# "except Exception" проходит насквозь. Тогда умирал ВЕСЬ генератор, и клиенты
# оставались без I1-I5 вообще — вместо честной деградации «QUIC без шифрования».
except BaseException:
    _CRYPTO_OK = False

def crypto_available():
    if not _CRYPTO_OK:
        _warn_once("нет python3-cryptography: QUIC Initial уйдёт без шифрования, "
                   "ECH — без HPKE. Ставится так: apt-get install -y python3-cryptography")
    return _CRYPTO_OK

def hkdf_extract(salt, ikm):
    return _hmac.new(salt, ikm, _hashlib.sha256).digest()

def hkdf_expand(prk, info, length):
    # RFC 5869 HKDF-Expand на SHA-256
    out = b""
    block = b""
    counter = 1
    while len(out) < length:
        block = _hmac.new(prk, block + info + bytes([counter]), _hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]

def hkdf_expand_label(secret, label, context, length):
    # RFC 8446 §7.1 HKDF-Expand-Label
    label_bytes = enc_text("tls13 " + label)
    info = u16(length) + bytes([len(label_bytes)]) + label_bytes + \
           bytes([len(context)]) + context
    return hkdf_expand(secret, info, length)

def aes_gcm_encrypt(key, nonce, plaintext, aad):
    return AESGCM(key).encrypt(nonce, plaintext, aad)

def aes_ecb_encrypt_block(key, block):
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return (enc.update(block) + enc.finalize())[:16]

# -- HPKE (RFC 9180), режим base, DHKEM(X25519, HKDF-SHA256) --
HPKE_VERSION_LABEL = b"HPKE-v1"
HPKE_SUITE_PREFIX = b"HPKE"
HPKE_KEM_PREFIX = b"KEM"
HPKE_MODE_BASE = 0x00

def _hpke_aead_params(aead_id):
    if aead_id == 0x0001:
        return 16, 12, 16     # AES-128-GCM
    if aead_id == 0x0002:
        return 32, 12, 16     # AES-256-GCM
    raise ValueError("unsupported HPKE AEAD id: %s" % aead_id)

def _hpke_labeled_extract(salt, suite_id, label, ikm):
    return hkdf_extract(salt, HPKE_VERSION_LABEL + suite_id + enc_text(label) + ikm)

def _hpke_labeled_expand(prk, suite_id, label, info, length):
    return hkdf_expand(prk, u16(length) + HPKE_VERSION_LABEL + suite_id +
                       enc_text(label) + info, length)

def hpke_setup_base_sender(recipient_public_key, info, kem_id, kdf_id, aead_id):
    """
    Возвращает контекст отправителя: enc (эфемерный публичный ключ), key,
    base_nonce. Порт hpkeSetupBaseSender из crypto.js.
    """
    if kem_id != 0x0020 or kdf_id != 0x0001:
        raise ValueError("unsupported HPKE KEM/KDF: %s/%s" % (kem_id, kdf_id))
    key_len, nonce_len, tag_len = _hpke_aead_params(aead_id)
    suite_id = HPKE_SUITE_PREFIX + u16(kem_id) + u16(kdf_id) + u16(aead_id)
    kem_suite_id = HPKE_KEM_PREFIX + u16(kem_id)

    private_key = X25519PrivateKey.generate()
    enc = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    shared = private_key.exchange(
        X25519PublicKey.from_public_bytes(recipient_public_key))

    eae_prk = _hpke_labeled_extract(b"", kem_suite_id, "eae_prk", shared)
    shared_secret = _hpke_labeled_expand(eae_prk, kem_suite_id, "shared_secret",
                                         enc + recipient_public_key, 32)
    psk_id_hash = _hpke_labeled_extract(b"", suite_id, "psk_id_hash", b"")
    info_hash = _hpke_labeled_extract(b"", suite_id, "info_hash", info)
    key_schedule_context = bytes([HPKE_MODE_BASE]) + psk_id_hash + info_hash
    secret = _hpke_labeled_extract(shared_secret, suite_id, "secret", b"")

    return {
        "enc": enc,
        "key": _hpke_labeled_expand(secret, suite_id, "key", key_schedule_context, key_len),
        "base_nonce": _hpke_labeled_expand(secret, suite_id, "base_nonce",
                                           key_schedule_context, nonce_len),
        "tag_length": tag_len,
    }

def hpke_seal(context, aad, plaintext):
    return aes_gcm_encrypt(context["key"], context["base_nonce"], plaintext, aad)

# ================================================================
# TLS ClientHello (generators.js: buildClientHelloBody + build*Extension)
# Порядок расширений задаётся отпечатком (extensionOrder) — именно он и есть
# JA3/JA4 клиента, поэтому переставлять их нельзя.
# ================================================================
GREASE_VALUES = [
    0x0A0A, 0x1A1A, 0x2A2A, 0x3A3A, 0x4A4A, 0x5A5A, 0x6A6A, 0x7A7A,
    0x8A8A, 0x9A9A, 0xAAAA, 0xBABA, 0xCACA, 0xDADA, 0xEAEA, 0xFAFA,
]

def select_grease_value(excluded=None):
    filtered = [v for v in GREASE_VALUES if v != excluded] or GREASE_VALUES
    return rc(filtered)

def chrome_fingerprint(is_quic):
    # resolveTlsFingerprint: профиль Chrome (браузерный ClientHello)
    return {
        "useGrease": True,
        "useSecondaryGrease": True,
        "cipherSuites": [0x1301, 0x1302, 0x1303] if is_quic else [
            0x1301, 0x1302, 0x1303, 0xC02B, 0xC02F, 0xC02C, 0xC030, 0xCCA9,
            0xCCA8, 0xC013, 0xC014, 0x009C, 0x009D, 0x002F, 0x0035],
        "extensionOrder": [
            "grease", "sni", "supported_groups", "alpn", "status_request",
            "signature_algorithms", "sct", "supported_versions", "key_share",
            "psk_modes", "quic_transport_parameters", "compress_certificate",
            "secondary_grease", "padding",
        ] if is_quic else [
            "grease", "sni", "extended_master_secret", "renegotiation_info",
            "supported_groups", "ec_point_formats", "session_ticket", "alpn",
            "status_request", "signature_algorithms", "sct", "supported_versions",
            "key_share", "psk_modes", "compress_certificate",
            "application_settings", "secondary_grease", "padding",
        ],
        "supportedGroups": [0x001D, 0x0017, 0x0018],
        "signatureAlgorithms": [0x0403, 0x0804, 0x0401, 0x0503, 0x0805,
                                0x0501, 0x0806, 0x0601, 0x0807],
        "supportedVersions": [0x0304] if is_quic else [0x0304, 0x0303],
        "keyShares": [0x001D],
        "compressCertificateAlgorithms": [0x0002],
        "includeApplicationSettings": True,
        "paddingTarget": 512,
        "encryptedClientHello": None,
        "maxUdpPayloadSize": 1472,
        "activeConnectionIdLimit": 8,
    }

def curl_quic_fingerprint():
    # createCapturedCurlQuicFingerprint: снятый с curl --http3 ClientHello.
    # Без GREASE и с другим порядком transport parameters — это отдельный
    # отпечаток, а не вариация Chrome.
    return {
        "useGrease": False,
        "useSecondaryGrease": False,
        "cipherSuites": [0x1301],
        "extensionOrder": [
            "sni", "supported_versions", "supported_groups",
            "signature_algorithms", "alpn", "key_share", "psk_modes",
            "quic_transport_parameters", "compress_certificate",
            "encrypted_client_hello",
        ],
        "supportedGroups": [0x001D, 0x0017, 0x0018],
        "signatureAlgorithms": [0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806],
        "supportedVersions": [0x0304],
        "keyShares": [0x001D],
        "compressCertificateAlgorithms": [0x0002],
        "includeApplicationSettings": False,
        "paddingTarget": 0,
        "encryptedClientHello": None,
        "quicTransportParameterOrder": [0x03, 0x07, 0x05, 0x09, 0x01,
                                        0x08, 0x0F, 0x0E, 0x06, 0x04],
        "maxIdleTimeout": 30000,
        "maxUdpPayloadSize": 1472,
        "initialMaxData": 10485760,
        "initialMaxStreamDataBidiLocal": 5242880,
        "initialMaxStreamDataBidiRemote": 5242880,
        "initialMaxStreamDataUni": 5242880,
        "initialMaxStreamsBidi": 100,
        "initialMaxStreamsUni": 100,
        "activeConnectionIdLimit": 2,
    }

def resolve_tls_fingerprint(is_quic, profile_id=None):
    if is_quic and profile_id == CURL_QUIC_PROFILE_ID:
        return curl_quic_fingerprint()
    return chrome_fingerprint(is_quic)

def _fp_num(fingerprint, key, default_value):
    value = fingerprint.get(key)
    return value if isinstance(value, int) else default_value

def ext(ext_type, data):
    return u16(ext_type) + u16(len(data)) + data

def ext_server_name(host):
    host_bytes = enc_text(host)
    server_name = b"\x00" + u16(len(host_bytes)) + host_bytes
    return ext(0x0000, u16(len(server_name)) + server_name)

def ext_alpn(protocols):
    entries = b""
    for protocol in protocols:
        pb = enc_text(protocol)
        entries += bytes([len(pb)]) + pb
    return ext(0x0010, u16(len(entries)) + entries)

def ext_supported_versions(grease_value, versions):
    body = b""
    if grease_value is not None:
        body += u16(grease_value)
    for version in (versions or [0x0304, 0x0303]):
        body += u16(version)
    return u16(0x002B) + u16(len(body) + 1) + bytes([len(body)]) + body

def ext_supported_groups(grease_value, groups):
    body = b""
    if grease_value is not None:
        body += u16(grease_value)
    for group in (groups or [0x001D, 0x0017, 0x0018]):
        body += u16(group)
    return u16(0x000A) + u16(len(body) + 2) + u16(len(body)) + body

def ext_signature_algorithms(signature_algorithms=None):
    body = b""
    for algorithm in (signature_algorithms or [0x0403, 0x0804, 0x0401, 0x0503,
                                               0x0805, 0x0501, 0x0806, 0x0601, 0x0807]):
        body += u16(algorithm)
    return u16(0x000D) + u16(len(body) + 2) + u16(len(body)) + body

def ext_ec_point_formats():
    return u16(0x000B) + u16(2) + b"\x01\x00"

def ext_psk_modes():
    return u16(0x002D) + u16(2) + b"\x01\x01"

def key_share_value(group):
    if group == 0x0017:
        return b"\x04" + rb(64)
    if group == 0x0018:
        return b"\x04" + rb(96)
    return rb(32)

def ext_key_share(grease_value, groups):
    entries = b""
    if grease_value is not None:
        entries += u16(grease_value) + u16(1) + b"\x00"
    for group in (groups or [0x001D]):
        kb = key_share_value(group)
        entries += u16(group) + u16(len(kb)) + kb
    return u16(0x0033) + u16(len(entries) + 2) + u16(len(entries)) + entries

def ext_extended_master_secret():
    return u16(0x0017) + u16(0)

def ext_renegotiation_info():
    return u16(0xFF01) + u16(1) + b"\x00"

def ext_session_ticket():
    return u16(0x0023) + u16(0)

def ext_status_request():
    return ext(0x0005, b"\x01" + u16(0) + u16(0))

def ext_sct():
    return u16(0x0012) + u16(0)

def ext_compress_certificate(algorithms):
    encoded = b""
    for algorithm in (algorithms or [0x0002]):
        encoded += u16(algorithm)
    return ext(0x001B, bytes([len(encoded)]) + encoded)

def ext_application_settings(protocols):
    entries = b""
    for protocol in protocols:
        pb = enc_text(protocol)
        entries += bytes([len(pb)]) + pb
    return u16(0x4469) + u16(len(entries) + 2) + u16(len(entries)) + entries

def ext_encrypted_client_hello(config):
    # buildEncryptedClientHelloExtension: inner ClientHello несёт один байт
    # типа, outer — полный набор (kdf/aead/config_id/enc/payload).
    if config and config.get("clientHelloType") == 0x01:
        return u16(0xFE0D) + u16(1) + b"\x01"
    enc_key = config.get("enc") or b"" if config else b""
    payload = config.get("payload") or b"" if config else b""
    data = (bytes([config.get("clientHelloType", 0x00) if config else 0x00]) +
            u16(config.get("kdfId", 0x0001) if config else 0x0001) +
            u16(config.get("aeadId", 0x0001) if config else 0x0001) +
            bytes([config.get("configId", 0x00) if config else 0x00]) +
            u16(len(enc_key)) + enc_key +
            u16(len(payload)) + payload)
    return ext(0xFE0D, data)

def ext_quic_transport_parameters(source_connection_id, fingerprint):
    order = fingerprint.get("quicTransportParameterOrder") or [
        0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0E, 0x0F]
    values = {
        0x01: quic_varint(_fp_num(fingerprint, "maxIdleTimeout", 30000)),
        0x03: quic_varint(_fp_num(fingerprint, "maxUdpPayloadSize", 1472)),
        0x04: quic_varint(_fp_num(fingerprint, "initialMaxData", 15728640)),
        0x05: quic_varint(_fp_num(fingerprint, "initialMaxStreamDataBidiLocal", 6291456)),
        0x06: quic_varint(_fp_num(fingerprint, "initialMaxStreamDataBidiRemote", 6291456)),
        0x07: quic_varint(_fp_num(fingerprint, "initialMaxStreamDataUni", 6291456)),
        0x08: quic_varint(_fp_num(fingerprint, "initialMaxStreamsBidi", 100)),
        0x09: quic_varint(_fp_num(fingerprint, "initialMaxStreamsUni", 100)),
        0x0A: quic_varint(_fp_num(fingerprint, "ackDelayExponent", 3)),
        0x0B: quic_varint(_fp_num(fingerprint, "maxAckDelay", 25)),
        0x0E: quic_varint(_fp_num(fingerprint, "activeConnectionIdLimit", 8)),
        0x0F: source_connection_id,
    }
    parameters = b""
    for parameter_id in order:
        value = b"" if parameter_id == 0x0C else values[parameter_id]
        parameters += quic_varint(parameter_id) + quic_varint(len(value)) + value
    return ext(0x0039, parameters)

def ext_padding(padding_length):
    if padding_length <= 0:
        return b""
    return u16(0x0015) + u16(padding_length) + zeros(padding_length)

def ext_grease(grease_value):
    return u16(grease_value) + u16(0)

def ext_use_srtp():
    profiles = u16(2) + u16(0x0001) + b"\x00"
    return ext(0x000E, profiles)

def calculate_tls_padding_length(parts, target_size):
    # calculateTlsPaddingLength: формула оригинала, константа 4+2+32+1+32+2+32+2+2
    if not target_size:
        return 0
    current = sum(len(p) for p in parts)
    return max(0, target_size - (4 + 2 + 32 + 1 + 32 + 2 + 32 + 2 + 2) - current - 4)

def resolve_alpn_protocols(protocol, is_quic):
    if is_quic:
        return [protocol]
    if protocol == "h2":
        return ["h2", "http/1.1"]
    return [protocol]

def build_tls_extensions(host, opts):
    fingerprint = opts["fingerprint"]
    is_quic = opts.get("isQuic", False)
    grease_value = opts.get("greaseValue")
    parts = []

    for name in fingerprint["extensionOrder"]:
        if name == "grease" and grease_value is not None:
            parts.append(ext_grease(grease_value))
        elif name == "sni":
            parts.append(ext_server_name(host))
        elif name == "extended_master_secret":
            parts.append(ext_extended_master_secret())
        elif name == "renegotiation_info":
            parts.append(ext_renegotiation_info())
        elif name == "supported_groups":
            parts.append(ext_supported_groups(grease_value, fingerprint["supportedGroups"]))
        elif name == "ec_point_formats":
            parts.append(ext_ec_point_formats())
        elif name == "session_ticket":
            parts.append(ext_session_ticket())
        elif name == "alpn" and opts.get("alpnProtocol"):
            parts.append(ext_alpn(resolve_alpn_protocols(opts["alpnProtocol"], is_quic)))
        elif name == "status_request":
            parts.append(ext_status_request())
        elif name == "signature_algorithms":
            parts.append(ext_signature_algorithms(fingerprint["signatureAlgorithms"]))
        elif name == "sct":
            parts.append(ext_sct())
        elif name == "supported_versions" and opts.get("withTls13"):
            parts.append(ext_supported_versions(grease_value, fingerprint["supportedVersions"]))
        elif name == "key_share":
            parts.append(ext_key_share(grease_value, fingerprint["keyShares"]))
        elif name == "psk_modes":
            parts.append(ext_psk_modes())
        elif name == "quic_transport_parameters" and opts.get("withQuicTransportParameters"):
            parts.append(ext_quic_transport_parameters(
                opts.get("quicSourceConnectionId") or b"", fingerprint))
        elif name == "compress_certificate" and opts.get("withTls13") and \
                fingerprint["compressCertificateAlgorithms"]:
            parts.append(ext_compress_certificate(fingerprint["compressCertificateAlgorithms"]))
        elif name == "application_settings" and not is_quic and \
                opts.get("alpnProtocol") == "h2" and fingerprint["includeApplicationSettings"]:
            parts.append(ext_application_settings(["h2"]))
        elif name == "encrypted_client_hello" and fingerprint.get("encryptedClientHello"):
            parts.append(ext_encrypted_client_hello(fingerprint["encryptedClientHello"]))
        elif name == "secondary_grease" and opts.get("secondaryGreaseValue") is not None:
            parts.append(ext_grease(opts["secondaryGreaseValue"]))
        elif name == "padding":
            padding_length = calculate_tls_padding_length(parts, fingerprint["paddingTarget"])
            if padding_length > 0:
                parts.append(ext_padding(padding_length))

    return b"".join(parts)

def build_client_hello_body(host, opts):
    """
    Возвращает handshake-сообщение ClientHello целиком: 0x01 + длина + тело.
    Порт buildClientHelloBody.
    """
    is_quic = bool(opts.get("withQuicTransportParameters"))
    fingerprint = opts.get("fingerprintOverride") or \
        resolve_tls_fingerprint(is_quic, opts.get("tlsFingerprintProfile"))
    grease_value = opts["greaseValue"] if "greaseValue" in opts else (
        select_grease_value() if fingerprint["useGrease"] else None)
    secondary_grease = opts["secondaryGreaseValue"] if "secondaryGreaseValue" in opts else (
        select_grease_value(grease_value) if fingerprint["useSecondaryGrease"] else None)
    session_id = opts["sessionIdBytes"] if opts.get("sessionIdBytes") is not None else rb(32)
    client_random = opts.get("clientRandom") or rb(32)

    extensions = build_tls_extensions(host, {
        "withTls13": bool(opts.get("withTls13")),
        "alpnProtocol": opts.get("alpnProtocol"),
        "greaseValue": grease_value,
        "secondaryGreaseValue": secondary_grease,
        "isQuic": is_quic,
        "withQuicTransportParameters": bool(opts.get("withQuicTransportParameters")),
        "quicSourceConnectionId": opts.get("quicSourceConnectionId") or b"",
        "fingerprint": fingerprint,
    })

    cipher_suites = b""
    if grease_value is not None:
        cipher_suites += u16(grease_value)
    for suite in fingerprint["cipherSuites"]:
        cipher_suites += u16(suite)

    body = (u16(opts["legacyVersion"]) + client_random +
            bytes([len(session_id)]) + session_id +
            u16(len(cipher_suites)) + cipher_suites +
            b"\x01\x00" + u16(len(extensions)) + extensions)
    return b"\x01" + u24(len(body)) + body

# ================================================================
# ECHConfig (generators.js: parseEchConfig* / serializeEchConfig)
# ================================================================
def serialize_ech_config(definition):
    public_key = definition["publicKey"]
    public_name_bytes = enc_text(definition["publicName"])
    cipher_suites = b""
    for suite in definition["cipherSuites"]:
        cipher_suites += u16(suite["kdfId"]) + u16(suite["aeadId"])
    contents = (bytes([definition["configId"] & 0xFF]) +
                u16(definition["kemId"]) +
                u16(len(public_key)) + public_key +
                u16(len(cipher_suites)) + cipher_suites +
                bytes([min(255, definition.get("maximumNameLength") or len(public_name_bytes))]) +
                bytes([len(public_name_bytes)]) + public_name_bytes +
                u16(0))
    return u16(0xFE0D) + u16(len(contents)) + contents

def build_ech_config_descriptor(definition):
    suites = definition.get("cipherSuites") or [{"kdfId": 0x0001, "aeadId": 0x0001}]
    selected = select_supported_cipher_suite(suites) or {"kdfId": 0x0001, "aeadId": 0x0001}
    return {
        "configId": definition["configId"],
        "kemId": definition["kemId"],
        "kdfId": selected["kdfId"],
        "aeadId": selected["aeadId"],
        "publicKey": definition["publicKey"],
        "maximumNameLength": definition["maximumNameLength"],
        "publicName": definition["publicName"],
        "rawBytes": serialize_ech_config({
            "configId": definition["configId"],
            "kemId": definition["kemId"],
            "publicKey": definition["publicKey"],
            "maximumNameLength": definition["maximumNameLength"],
            "publicName": definition["publicName"],
            "cipherSuites": suites,
        }),
    }

def select_supported_cipher_suite(cipher_suites):
    for suite in cipher_suites or []:
        if suite.get("kdfId") == 0x0001 and suite.get("aeadId") in (0x0001, 0x0002):
            return suite
    return None

def parse_ech_config_list(data):
    configs = []
    if len(data) < 2:
        return configs
    total_length = read_u16(data, 0)
    end = min(len(data), 2 + total_length)
    offset = 2
    while offset + 4 <= end:
        config_start = offset
        version = read_u16(data, offset)
        content_length = read_u16(data, offset + 2)
        content_start = offset + 4
        content_end = content_start + content_length
        if content_end > end:
            break
        if version == 0xFE0D:
            config = parse_ech_config(data, config_start, content_start, content_end)
            if config:
                configs.append(config)
        offset = content_end
    return configs

def parse_ech_config(data, config_start, content_start, content_end):
    offset = content_start
    if offset + 5 > content_end:
        return None
    config_id = data[offset]
    offset += 1
    kem_id = read_u16(data, offset)
    offset += 2
    public_key_length = read_u16(data, offset)
    offset += 2
    if offset + public_key_length > content_end:
        return None
    public_key = data[offset:offset + public_key_length]
    offset += public_key_length
    if offset + 2 > content_end:
        return None
    cipher_suites_length = read_u16(data, offset)
    offset += 2
    suite_end = offset + cipher_suites_length
    if suite_end > content_end:
        return None
    cipher_suites = []
    while offset + 4 <= suite_end:
        cipher_suites.append({"kdfId": read_u16(data, offset),
                              "aeadId": read_u16(data, offset + 2)})
        offset += 4
    if offset + 2 > content_end:
        return None
    maximum_name_length = data[offset]
    offset += 1
    public_name_length = data[offset]
    offset += 1
    if offset + public_name_length > content_end:
        return None
    public_name = data[offset:offset + public_name_length].decode("utf-8", "replace")
    selected = select_supported_cipher_suite(cipher_suites)
    if not selected:
        return None
    return {
        "configId": config_id,
        "kemId": kem_id,
        "kdfId": selected["kdfId"],
        "aeadId": selected["aeadId"],
        "publicKey": public_key,
        "maximumNameLength": maximum_name_length,
        "publicName": public_name,
        "rawBytes": data[config_start:content_end],
    }

def select_supported_ech_config(configs):
    for config in configs or []:
        if config["kemId"] == 0x0020 and config["kdfId"] == 0x0001 and \
                config["aeadId"] in (0x0001, 0x0002):
            return config
    return None

def create_synthetic_ech_config(host):
    """
    Синтетический ECHConfig: ключ генерируем сами. Для наблюдателя структура
    расширения неотличима от настоящего ECH — расшифровать его всё равно может
    только владелец приватного ключа, и им никто не пользуется.
    """
    private_key = X25519PrivateKey.generate()
    public_key = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return build_ech_config_descriptor({
        "configId": rb(1)[0],
        "kemId": 0x0020,
        "publicKey": public_key,
        "maximumNameLength": min(255, len(host)),
        "publicName": host,
        "cipherSuites": [{"kdfId": 0x0001, "aeadId": 0x0001}],
    })

def fetch_published_ech_config(host, timeout=2.0):
    """
    Настоящий ECHConfig из HTTPS RR через DoH (как fetchPublishedEchConfig).
    Включается флагом --ech-doh или AWG_CPS_ECH_DOH=1: запрос уходит наружу,
    поэтому по умолчанию выключен, а при любой ошибке/таймауте возвращается
    None и берётся синтетический конфиг.
    """
    import base64, json, re, urllib.parse, urllib.request
    url = "https://dns.google/resolve?name=%s&type=HTTPS" % urllib.parse.quote(host)
    request = urllib.request.Request(url, headers={"accept": "application/dns-json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except Exception as exc:
        _warn_once("DoH-запрос ECHConfig не удался (%s) — берём синтетический ECH"
                   % type(exc).__name__)
        return None
    for answer in payload.get("Answer") or []:
        match = re.search(r"\bech=\"?([^\"\s]+)\"?", str(answer.get("data") or ""), re.I)
        if not match:
            continue
        try:
            raw = base64.b64decode(match.group(1) + "==")
        except Exception:
            continue
        config = select_supported_ech_config(parse_ech_config_list(raw))
        if config:
            return config
    return None

def resolve_ech_config(host, use_doh):
    if use_doh:
        config = fetch_published_ech_config(host)
        if config:
            return config
    return create_synthetic_ech_config(host)

# ================================================================
# QUIC Initial (generators.js: generateQuicPayload* + crypto.js)
# ================================================================
def build_quic_client_hello(host, options, scid):
    return build_client_hello_body(host, {
        "legacyVersion": 0x0303,
        "withTls13": True,
        "alpnProtocol": "h3",
        "withQuicTransportParameters": True,
        "quicSourceConnectionId": scid,
        "tlsFingerprintProfile": options.get("tlsFingerprintProfile"),
    })

def build_ech_quic_client_hello(host, options, scid):
    """
    ClientHello с настоящим ECH: внутренний ClientHello (реальный SNI)
    шифруется HPKE и кладётся во внешний, где SNI — public_name конфига.
    Порт buildDynamicEchQuicClientHello.
    """
    ech_config = options["echConfig"]
    base_fingerprint = resolve_tls_fingerprint(True, options.get("tlsFingerprintProfile"))

    inner_fingerprint = dict(base_fingerprint)
    inner_fingerprint["extensionOrder"] = list(base_fingerprint["extensionOrder"])
    if "encrypted_client_hello" not in inner_fingerprint["extensionOrder"]:
        inner_fingerprint["extensionOrder"].append("encrypted_client_hello")
    inner_fingerprint["encryptedClientHello"] = {"clientHelloType": 0x01}

    encoded_inner = build_client_hello_body(host, {
        "legacyVersion": 0x0303,
        "withTls13": True,
        "alpnProtocol": "h3",
        "withQuicTransportParameters": True,
        "quicSourceConnectionId": scid,
        "fingerprintOverride": inner_fingerprint,
        "sessionIdBytes": b"",
    })[4:]

    host_length = len(enc_text(host))
    max_name_length = ech_config["maximumNameLength"] or host_length
    padding_length = max(0, max_name_length - host_length)
    padded_length = len(encoded_inner) + padding_length
    padding_length += (32 - (padded_length % 32)) % 32
    padded_inner = encoded_inner + zeros(padding_length)

    context = hpke_setup_base_sender(
        ech_config["publicKey"],
        b"tls ech" + b"\x00" + ech_config["rawBytes"],
        ech_config["kemId"], ech_config["kdfId"], ech_config["aeadId"])

    outer_fingerprint = dict(base_fingerprint)
    outer_fingerprint["extensionOrder"] = list(base_fingerprint["extensionOrder"])
    if "encrypted_client_hello" not in outer_fingerprint["extensionOrder"]:
        outer_fingerprint["extensionOrder"].append("encrypted_client_hello")
    outer_fingerprint["encryptedClientHello"] = {
        "clientHelloType": 0x00,
        "kdfId": ech_config["kdfId"],
        "aeadId": ech_config["aeadId"],
        "configId": ech_config["configId"],
        "enc": context["enc"],
        "payload": zeros(len(padded_inner) + context["tag_length"]),
    }

    outer = build_client_hello_body(ech_config["publicName"] or host, {
        "legacyVersion": 0x0303,
        "withTls13": True,
        "alpnProtocol": "h3",
        "withQuicTransportParameters": True,
        "quicSourceConnectionId": scid,
        "fingerprintOverride": outer_fingerprint,
    })

    ech_payload = hpke_seal(context, outer[4:], padded_inner)
    return replace_ech_payload(outer, ech_payload)

def find_ech_payload_offset(client_hello):
    offset = 4 + 2 + 32
    session_id_length = client_hello[offset]
    offset += 1 + session_id_length
    cipher_suites_length = read_u16(client_hello, offset)
    offset += 2 + cipher_suites_length
    compression_methods_length = client_hello[offset]
    offset += 1 + compression_methods_length
    extensions_length = read_u16(client_hello, offset)
    offset += 2
    extensions_end = offset + extensions_length
    while offset + 4 <= extensions_end:
        extension_type = read_u16(client_hello, offset)
        extension_length = read_u16(client_hello, offset + 2)
        data_offset = offset + 4
        if extension_type == 0xFE0D:
            enc_length = read_u16(client_hello, data_offset + 1 + 2 + 2 + 1)
            payload_length_offset = data_offset + 1 + 2 + 2 + 1 + 2 + enc_length
            payload_length = read_u16(client_hello, payload_length_offset)
            return payload_length_offset + 2, payload_length
        offset = data_offset + extension_length
    raise ValueError("ECH extension was not found in ClientHello")

def replace_ech_payload(client_hello, ech_payload):
    offset, length = find_ech_payload_offset(client_hello)
    if length != len(ech_payload):
        raise ValueError("ECH payload length mismatch")
    data = bytearray(client_hello)
    data[offset:offset + length] = ech_payload
    return bytes(data)

def quic_crypto_frame(data, offset=0):
    return b"\x06" + quic_varint(offset) + quic_varint(len(data)) + data

def quic_initial_first_byte(packet_number_length):
    return QUIC_INITIAL_HEADER_BASE | ((packet_number_length - 1) & 0x03)

def resolve_quic_target_packet_size(options):
    if options.get("quicPadToMtu") and options.get("quicMtu"):
        return max(1200, int(options["quicMtu"]))
    if options.get("quicTargetPacketSize"):
        return max(1200, int(options["quicTargetPacketSize"]))
    return 1200

def calculate_quic_initial_padding(payload_length, dcid_length, scid_length,
                                   pn_length, target_packet_size, auth_tag_length):
    # RFC 9000 §14.1: датаграмма клиента с Initial обязана быть >= 1200 байт.
    # Длина поля length зависит от паддинга, поэтому считаем итеративно —
    # ровно как calculateQuicInitialPaddingLength в оригинале.
    target = max(1200, int(target_packet_size or 1200))
    header_prefix = 1 + 4 + 1 + dcid_length + 1 + scid_length + 1
    protected_length = pn_length + payload_length + max(0, int(auth_tag_length or 0))
    length_field_size = len(quic_varint(protected_length))
    previous = -1
    padding = 0
    while length_field_size != previous:
        previous = length_field_size
        padding = max(0, target - (header_prefix + length_field_size + protected_length))
        length_field_size = len(quic_varint(protected_length + padding))
    return max(0, target - (header_prefix + length_field_size + protected_length))

def pad_quic_initial_payload(payload, dcid, scid, packet_number, options, auth_tag_length):
    padding = calculate_quic_initial_padding(
        len(payload), len(dcid), len(scid), len(packet_number),
        resolve_quic_target_packet_size(options), auth_tag_length)
    return payload + zeros(padding) if padding > 0 else payload

def build_plain_quic_initial(dcid, scid, packet_number, payload):
    packet_length = len(packet_number) + len(payload)
    return (bytes([quic_initial_first_byte(len(packet_number))]) +
            u32(QUIC_WIRE_VERSION) +
            bytes([len(dcid)]) + dcid +
            bytes([len(scid)]) + scid +
            quic_varint(0) + quic_varint(packet_length) +
            packet_number + payload)

def build_protected_quic_initial(dcid, scid, packet_number, payload):
    # RFC 9001: ключи Initial выводятся из DCID, затем AEAD и header protection.
    initial_secret = hkdf_extract(QUIC_V1_INITIAL_SALT, dcid)
    client_secret = hkdf_expand_label(initial_secret, "client in", b"", 32)
    key = hkdf_expand_label(client_secret, "quic key", b"", 16)
    iv = hkdf_expand_label(client_secret, "quic iv", b"", 12)
    hp = hkdf_expand_label(client_secret, "quic hp", b"", 16)

    first_byte = quic_initial_first_byte(len(packet_number))
    packet_length = len(packet_number) + len(payload) + 16
    header = (bytes([first_byte]) + u32(QUIC_WIRE_VERSION) +
              bytes([len(dcid)]) + dcid +
              bytes([len(scid)]) + scid +
              quic_varint(0) + quic_varint(packet_length) + packet_number)

    nonce = bytearray(iv)
    for i, byte in enumerate(packet_number):
        nonce[len(nonce) - len(packet_number) + i] ^= byte
    encrypted = aes_gcm_encrypt(key, bytes(nonce), payload, header)

    sample_offset = 4 - len(packet_number)
    if sample_offset < 0 or len(encrypted) < sample_offset + 16:
        return header + encrypted
    mask = aes_ecb_encrypt_block(hp, encrypted[sample_offset:sample_offset + 16])
    protected = bytearray(header)
    protected[0] = first_byte ^ (mask[0] & 0x0F)
    for i in range(len(packet_number)):
        protected[len(protected) - len(packet_number) + i] = packet_number[i] ^ mask[i + 1]
    return bytes(protected) + encrypted

def generate_quic_payload(options):
    """
    QUIC Initial с ClientHello в CRYPTO-фрейме. С доступной криптографией
    пакет шифруется по RFC 9001 — тогда его содержимое для DPI неотличимо
    от шифротекста Chrome; без неё уходит нешифрованный Initial (fallback
    generateQuicPayload из оригинала).
    """
    dcid = rb(int(options.get("quicDcidLength", 8)))
    scid = rb(int(options.get("quicScidLength", 8)))
    packet_number = options.get("quicPacketNumber") or rb(int(options.get("quicPacketNumberLength", 4)))

    if options.get("echConfig") and crypto_available():
        try:
            client_hello = build_ech_quic_client_hello(options["host"], options, scid)
        except Exception as exc:
            _warn_once("сбой ECH (%s) — ClientHello уйдёт без него" % type(exc).__name__)
            client_hello = build_quic_client_hello(options["host"], options, scid)
    else:
        client_hello = build_quic_client_hello(options["host"], options, scid)

    crypto_frame = quic_crypto_frame(client_hello, 0)

    if not crypto_available():
        payload = pad_quic_initial_payload(crypto_frame, dcid, scid, packet_number, options, 0)
        return build_plain_quic_initial(dcid, scid, packet_number, payload)

    try:
        payload = pad_quic_initial_payload(crypto_frame, dcid, scid, packet_number, options, 16)
        return build_protected_quic_initial(dcid, scid, packet_number, payload)
    except Exception as exc:
        _warn_once("сбой шифрования QUIC (%s: %s) — Initial уйдёт без защиты"
                   % (type(exc).__name__, exc))
        payload = pad_quic_initial_payload(crypto_frame, dcid, scid, packet_number, options, 0)
        return build_plain_quic_initial(dcid, scid, packet_number, payload)

def generate_curl_quic_payload(options):
    # withCapturedCurlQuicProfile: curl шлёт пустой SCID, целевой размер 1250,
    # номер пакета 0x00 и ClientHello с ECH.
    merged = dict(options)
    merged.setdefault("tlsFingerprintProfile", CURL_QUIC_PROFILE_ID)
    merged["quicScidLength"] = merged.get("quicScidLength", 0)
    merged["quicTargetPacketSize"] = merged.get("quicTargetPacketSize", 1250)
    merged["quicPacketNumber"] = merged.get("quicPacketNumber", b"\x00")
    if crypto_available() and not merged.get("echConfig"):
        try:
            merged["echConfig"] = resolve_ech_config(merged["host"], merged.get("echDoh", False))
        except Exception as exc:
            _warn_once("не удалось подготовить ECHConfig (%s) — ClientHello без ECH"
                       % type(exc).__name__)
    return generate_quic_payload(merged)

# ================================================================
# DNS / SSDP / NTP / RTP / RTCP (generators.js)
# ================================================================
def encode_dns_name(name):
    trimmed = (name or DEFAULT_HOST).rstrip(".")
    out = b""
    for label in trimmed.split("."):
        label_bytes = enc_text(label)
        if not label_bytes or len(label_bytes) > 63:
            raise ValueError("each DNS label must be between 1 and 63 bytes")
        out += bytes([len(label_bytes)]) + label_bytes
    return out + b"\x00"

def build_dns_opt_record(udp_payload_size=1232):
    return b"\x00" + u16(0x0029) + u16(udp_payload_size) + u32(0) + u16(0)

def build_dns_question(query_id, flags, name_bytes, type_value, class_value,
                       additional_record=b""):
    additional_count = 1 if additional_record else 0
    return (u16(query_id) + u16(flags) + u16(1) + u16(0) + u16(0) +
            u16(additional_count) + name_bytes + u16(type_value) +
            u16(class_value) + additional_record)

def next_dns_query_type(options):
    """Тип запроса для очередного пакета цепочки — без повторов подряд.

    Живой stub-резолвер по одному имени спрашивает разное (A, AAAA, у
    браузеров ещё HTTPS), а повторяет только при потере ответа. Типы раздаются
    по кругу с перемешиванием на каждом проходе: типов три, пакетов пять, и
    два повтора выглядят как обычный ретрай (идентификатор запроса у каждого
    пакета свой).
    """
    queue = options.get("_dnsQueue")
    if not queue:
        queue = list(DNS_QUERY_TYPES)
        # Перемешивание Фишера-Йетса на нашем источнике случайности
        for i in range(len(queue) - 1, 0, -1):
            j = ri(i + 1)
            queue[i], queue[j] = queue[j], queue[i]
        # Стык проходов: типов три, пакетов пять, поэтому круг начинается
        # заново — и может начаться тем же типом, которым кончился прошлый.
        # Два одинаковых запроса ПОДРЯД — это уже не ретрай (тот приходит
        # через таймаут, а не встык), поэтому такой стык разводим.
        last = options.get("_dnsLast")
        if last is not None and len(queue) > 1 and queue[0] == last:
            queue[0], queue[-1] = queue[-1], queue[0]
        options["_dnsQueue"] = queue
    qtype = queue.pop(0)
    options["_dnsLast"] = qtype
    return qtype

def generate_dns_payload(options):
    # Идентификатор запроса резолвер выбирает случайно на каждый запрос — это
    # штатная защита от подделки ответа (RFC 5452), поэтому тег здесь не только
    # безопасен, но и правдоподобнее фиксированного значения.
    query_id = ri(65535)
    payload = build_dns_question(query_id, 0x0100, encode_dns_name(options["host"]),
                                 next_dns_query_type(options), 0x0001,
                                 build_dns_opt_record(1232))
    dyn(u16(query_id))
    return payload

def generate_ssdp_payload(options):
    message = "\r\n".join([
        "M-SEARCH * HTTP/1.1",
        "HOST: 239.255.255.250:1900",
        "MAN: \"ssdp:discover\"",
        "ST: " + rc(SSDP_SEARCH_TARGETS),
        "MX: %d" % (1 + ri(5)),
        "USER-AGENT: " + rc(SSDP_USER_AGENTS),
        "ACCEPT-LANGUAGE: en-US,en;q=0.9",
        "",
        "",
    ])
    return enc_text(message)

def generate_ntp_payload(options):
    now = time.time()
    payload = bytearray(48)
    payload[0] = 0x23          # LI=0, VN=4, Mode=3 (client)
    payload[1] = 0x00
    payload[2] = 0x06
    payload[3] = 0xEC
    payload[4:8] = u32(0x00000100)
    payload[8:12] = u32(0x00000100)
    payload[12:16] = enc_text("INIT")
    # Reference Timestamp — момент последней синхронизации клиента, у живого
    # клиента это минуты назад, а не ровно секунда. Секундный сдвиг был ещё и
    # вреден технически: дробные части обеих меток совпадали байт в байт, и
    # уникальности для тега не оставалось.
    # Сдвиг обязан быть дробным: ntp_timestamp считает дробь от миллисекунд, и
    # при целом числе секунд обе метки получили бы одинаковые младшие 4 байта.
    reference = ntp_timestamp(now - rr(30, 900) - ri(1000) / 1000.0)
    transmit = ntp_timestamp(now)
    payload[16:24] = reference
    payload[40:48] = transmit
    # Секунды не трогаем: случайные 4 байта дали бы дату вне текущей эпохи NTP,
    # то есть подделку виднее, чем повтор. Дробная часть (младшие 4 байта
    # метки) в реальных клиентах равномерно случайна — её и помечаем.
    dyn(reference[4:])
    dyn(transmit[4:])
    return bytes(payload)

def generate_rtp_payload(options=None):
    payload_type = rc([0x00, 0x08, 0x60])
    body = rb(96) if payload_type == 0x60 else rb(160)
    sequence = u16(ri(65535))
    timestamp = u32(ru32())
    ssrc = u32(ru32())
    # Внутри RTP ничего не считается от этих полей: заголовок без контрольной
    # суммы, тело — сжатый звук, для наблюдателя неотличимый от случайного.
    # Поэтому весь пакет, кроме двух байт версии/типа, может быть динамическим.
    dyn(sequence); dyn(timestamp); dyn(ssrc); dyn(body)
    return bytes([0x80, payload_type]) + sequence + timestamp + ssrc + body

def generate_rtcp_payload(options=None):
    ssrc = ru32()
    sender_report = (bytes([0x80, 0xC8]) + u16(0x0006) + u32(ssrc) +
                     ntp_timestamp() + u32(ru32()) + u32(1 + ri(64)) +
                     u32(160 + ri(4096)))
    cname = enc_text("webrtc@" + DEFAULT_HOST)
    sdes_value = (u32(ssrc) + bytes([0x01, len(cname)]) + cname + b"\x00" +
                  zeros((4 - ((4 + 2 + len(cname) + 1) % 4)) % 4))
    sdes = bytes([0x81, 0xCA]) + u16(((4 + len(sdes_value)) // 4) - 1) + sdes_value
    return sender_report + sdes

# ================================================================
# SIP (generators.js: generateSipPayload)
# ================================================================
def random_sip_user_part():
    prefix = rc(["100", "101", "200", "300", "400", "500",
                 "alice", "bob", "support", "sales", "noc", "ops"])
    return prefix + str(100 + ri(900))

def format_sip_address(display_name, user, host):
    return "\"%s\" <sip:%s@%s>" % (display_name, user, host)

def generate_random_sip_domain():
    base = rc(SIP_DOMAIN_BASES)
    suffix = rc(SIP_DOMAIN_SUFFIXES)
    if ri(3) == 0:
        return base + "." + suffix
    return "%s-%d.%s.%s" % (rc(SIP_DOMAIN_PREFIXES), 10 + ri(90), base, suffix)

def resolve_sip_host(options):
    # resolveSipHost: без флага sipCustomMessage домен всегда CONFIG.defaultHost
    if not options.get("sipCustomMessage"):
        return DEFAULT_HOST
    if options.get("hasCustomHost"):
        return options["host"]
    return generate_random_sip_domain()

def build_sip_invite_body(origin_user, host):
    media_ip = random_private_ipv4()
    audio_port = 12000 + ri(20000)
    session_id = 1000000000 + ri(900000000)
    codec_profile = rc(SIP_AUDIO_CODEC_PROFILES)
    fingerprint = ":".join(to_hex(rb(32))[i:i + 2] for i in range(0, 64, 2)).upper()
    lines = [
        "v=0",
        "o=%s %d %d IN IP4 %s" % (origin_user, session_id, session_id + 1, media_ip),
        "s=Call",
        "c=IN IP4 " + media_ip,
        "t=0 0",
        "m=audio %d RTP/AVP %s" % (audio_port, codec_profile["formatList"]),
        "a=rtcp:%d IN IP4 %s" % (audio_port + 1, media_ip),
        "a=sendrecv",
        "a=ptime:%d" % rc([20, 30, 40]),
        "a=maxptime:%d" % rc([60, 80, 120]),
        "a=rtcp-mux",
        # ICE-креденшелы генерируются заново на каждую сессию (RFC 5245 §15.4)
        # и состоят из ice-char = ALPHA / DIGIT / + / — буквы от <rc> подходят.
        "a=ice-ufrag:" + dyn(to_hex(rb(4)), "rc"),
        "a=ice-pwd:" + dyn(to_hex(rb(12)), "rc"),
        "a=fingerprint:sha-256 " + fingerprint,
        "a=setup:actpass",
        "a=msid-semantic: WMS " + origin_user,
        "a=rtcp-fb:* transport-cc",
    ]
    lines += ["a=rtpmap:" + p for p in codec_profile["payloads"]]
    lines += ["a=ssrc:%d cname:%s@%s" % (ru32(), origin_user, host)]
    return "\r\n".join(lines)

def generate_sip_payload(options):
    action = str(options.get("sipAction") or "OPTIONS").strip().upper()
    if action == "RANDOM":
        action = rc(["OPTIONS", "REGISTER", "INVITE", "TRYING"])
    if action not in ("REGISTER", "INVITE", "TRYING"):
        action = "OPTIONS"

    host = resolve_sip_host(options)
    local_ip = random_private_ipv4()
    local_port = rc(SIP_LOCAL_PORTS)
    from_user = random_sip_user_part()
    to_user = from_user if action == "REGISTER" else random_sip_user_part()
    from_display = rc(SIP_DISPLAY_NAMES)
    to_display = from_display if action == "REGISTER" else rc(SIP_DISPLAY_NAMES)
    # Идентификаторы транзакции SIP: branch, tag и Call-ID уникальны для каждого
    # запроса по самой спецификации (RFC 3261 §8.1.1.7, §19.3) — повтор одного и
    # того же Call-ID выглядел бы куда подозрительнее случайных букв. Тег <rc>,
    # а не <r>: протокол текстовый, двоичный мусор внутри заголовка недопустим.
    # Префикс z9hG4bK остаётся статикой — это обязательный магический маркер.
    branch = "z9hG4bK" + dyn(to_hex(rb(9)), "rc")
    tag = dyn(to_hex(rb(6)), "rc")
    call_id = dyn(to_hex(rb(12)), "rc") + "@" + host
    cseq = 1 + ri(50)
    user_agent = rc(SIP_USER_AGENTS)
    allow_header = rc(SIP_ALLOW_HEADERS)
    supported_header = rc(SIP_SUPPORTED_HEADERS)
    to_uri = format_sip_address(to_display, to_user, host)
    from_uri = format_sip_address(from_display, from_user, host)
    request_uri = "sip:" + host if action == "REGISTER" else "sip:%s@%s" % (to_user, host)
    via = "Via: SIP/2.0/UDP %s:%d;branch=%s;rport" % (local_ip, local_port, branch)
    contact = "Contact: <sip:%s@%s:%d;transport=udp>" % (from_user, local_ip, local_port)

    if action == "TRYING":
        lines = [
            "SIP/2.0 100 CONNECTING", via,
            "To: " + to_uri,
            "From: %s;tag=%s" % (from_uri, tag),
            "Call-ID: " + call_id,
            "CSeq: %d INVITE" % cseq,
            "Server: " + rc(SIP_SERVER_NAMES),
            "Content-Length: 0", "", "",
        ]
    elif action == "REGISTER":
        lines = [
            "REGISTER %s SIP/2.0" % request_uri, via,
            "Max-Forwards: 70",
            "From: %s;tag=%s" % (from_uri, tag),
            "To: " + to_uri,
            "Call-ID: " + call_id,
            "CSeq: %d REGISTER" % cseq,
            contact,
            "User-Agent: " + user_agent,
            "Allow: " + allow_header,
            "Supported: " + supported_header,
            "Allow-Events: " + rc(SIP_ALLOW_EVENTS_HEADERS),
            "Expires: %d" % rc([300, 600, 900, 1200, 1800, 3600]),
            "Content-Length: 0", "", "",
        ]
    elif action == "INVITE":
        body = build_sip_invite_body(from_user, host)
        lines = [
            "INVITE %s SIP/2.0" % request_uri, via,
            "Max-Forwards: 70",
            "From: %s;tag=%s" % (from_uri, tag),
            "To: " + to_uri,
            "Call-ID: " + call_id,
            "CSeq: %d INVITE" % cseq,
            contact,
            "User-Agent: " + user_agent,
            "Allow: " + allow_header,
            "Supported: " + supported_header,
            "Content-Type: application/sdp",
            "Content-Length: %d" % len(enc_text(body)),
            "", body,
        ]
    else:
        lines = [
            "OPTIONS %s SIP/2.0" % request_uri, via,
            "Max-Forwards: 70",
            "From: %s;tag=%s" % (from_uri, tag),
            "To: " + to_uri,
            "Call-ID: " + call_id,
            "CSeq: %d OPTIONS" % cseq,
            contact,
            "User-Agent: " + user_agent,
            "Allow: " + allow_header,
            "Supported: " + supported_header,
            "Accept: application/sdp",
            "Accept-Language: " + rc(SIP_ACCEPT_LANGUAGES),
            "Content-Length: 0", "", "",
        ]
    return enc_text("\r\n".join(lines))

# ================================================================
# DTLS (generators.js: generateDtlsPayload)
# ================================================================
def build_dtls_client_hello_body(host):
    session_id = rb(32)
    extensions = (ext_server_name(host) +
                  ext_supported_groups(None, [0x001D, 0x0017, 0x0018]) +
                  ext_ec_point_formats() +
                  ext_signature_algorithms() +
                  ext_use_srtp() +
                  ext_extended_master_secret())
    cipher_suites = b"".join(u16(c) for c in
                             [0xC02B, 0xC02F, 0xCCA9, 0xC02C, 0x009C, 0x009D])
    # ClientHello в DTLS ничем не подписан и не зашифрован (MAC появляется
    # только после смены шифра), а client_random и session_id по спецификации
    # случайны — оба поля можно отдать тегам. ECH здесь нет, так что связывания
    # с внешним ClientHello, которое сломалось бы, тоже нет.
    client_random = rb(32)
    dyn(client_random); dyn(session_id)
    return (b"\xFE\xFD" + client_random + bytes([len(session_id)]) + session_id +
            b"\x00" + u16(len(cipher_suites)) + cipher_suites + b"\x01\x00" +
            u16(len(extensions)) + extensions)

def generate_dtls_payload(options):
    body = build_dtls_client_hello_body(options["host"])
    handshake = (b"\x01" + u24(len(body)) + u16(0) + u24(0) + u24(len(body)) + body)
    return (b"\x16\xFE\xFD" + u16(0) + zeros(6) + u16(len(handshake)) + handshake)

# ================================================================
# STUN / TURN и WebRTC (generators.js: generateUnifiedStunTurnPayload)
# ================================================================
def build_stun_attribute(attr_type, value):
    padding = (4 - (len(value) % 4)) % 4
    return u16(attr_type) + u16(len(value)) + value + zeros(padding)

def build_stun_message_with_fingerprint(message_type, attrs):
    """
    STUN-сообщение с атрибутом FINGERPRINT (RFC 5389 §15.5).

    Отличие от payloadGen: там CRC32 считается по сообщению ВМЕСТЕ с четырьмя
    байтами заголовка самого FINGERPRINT, а RFC требует считать до атрибута,
    не включая его. С расчётом оригинала любой разбирающий STUN наблюдатель
    видит несходящуюся контрольную сумму — то есть ровно ту аномалию, ради
    сокрытия которой мимикрия и делается, поэтому здесь взят вариант RFC.
    Длина сообщения при этом, как и требуется, учитывает FINGERPRINT.
    """
    transaction_id = rb(12)
    attr_bytes = b"".join(attrs)
    total_length = len(attr_bytes) + 8      # + FINGERPRINT (4 байта заголовка + 4 значения)
    prefix = u16(message_type) + u16(total_length) + u32(0x2112A442) + transaction_id
    crc_value = (crc32_stun(prefix + attr_bytes) ^ 0x5354554E) & 0xFFFFFFFF
    return prefix + attr_bytes + build_stun_attribute(0x8028, u32(crc_value))

# Провайдеры ICE, из которых выбирает режим random. Список нужен и здесь, и в
# build_options: разыгрывать провайдера обязаны ОДИН раз на всю цепочку I1-I5.
STUN_PROVIDERS = ["google", "cloudflare", "meta", "twilio", "twilio_stun"]

def resolve_stun_turn_profile(provider):
    provider = str(provider or "").strip().lower()
    if provider == "random":
        provider = rc(STUN_PROVIDERS)
    if provider == "twilio_stun":
        return {"id": "twilio", "serverPool": TWILIO_STUN_SERVERS, "realm": TWILIO_REALM,
                "softwareName": "Twilio WebRTC ICE agent", "preferredMode": "binding",
                "autoAllocateProbability": 0.0, "supportsAllocate": False,
                "lifetimeRange": [300, 600]}
    if provider in ("twilio", "twilio_turn"):
        return {"id": "twilio", "serverPool": TWILIO_TURN_SERVERS, "realm": TWILIO_REALM,
                "softwareName": "Twilio WebRTC ICE agent", "preferredMode": "allocate",
                "autoAllocateProbability": 0.67, "supportsAllocate": True,
                "lifetimeRange": [300, 600]}
    if provider == "cloudflare":
        return {"id": "cloudflare", "serverPool": CLOUDFLARE_WEBRTC_SERVERS,
                "realm": CLOUDFLARE_REALM, "softwareName": "Cloudflare WebRTC client",
                "preferredMode": None, "autoAllocateProbability": 0.67,
                "supportsAllocate": True, "lifetimeRange": [600, 1200]}
    if provider == "meta":
        return {"id": "meta", "serverPool": META_WEBRTC_SERVERS, "realm": META_REALM,
                "softwareName": None, "preferredMode": None,
                "autoAllocateProbability": 0.75, "supportsAllocate": True,
                "lifetimeRange": [180, 600]}
    return {"id": "google", "serverPool": GOOGLE_STUN_SERVERS, "realm": "google.com",
            "softwareName": "Google STUN client", "preferredMode": None,
            "autoAllocateProbability": 0.0, "supportsAllocate": False,
            "lifetimeRange": [300, 600]}

def resolve_stun_turn_mode(options, profile):
    requested = str(options.get("iceMode") or "auto")
    if requested == "binding":
        return "binding"
    if requested == "allocate":
        return "allocate" if profile["supportsAllocate"] else "binding"
    if profile["preferredMode"] == "binding":
        return "binding"
    if profile["preferredMode"] == "allocate":
        return "allocate" if profile["supportsAllocate"] else "binding"
    if not profile["supportsAllocate"]:
        return "binding"
    return "allocate" if (ri(1000) / 1000.0) < profile["autoAllocateProbability"] else "binding"

# Приложения Meta, которыми может представиться профиль meta. Выбор — один на
# цепочку: WhatsApp не превращается в Instagram от пакета к пакету.
META_SOFTWARE_NAMES = ["WhatsApp/2", "Instagram/2", "Messenger WebRTC"]

def stun_software_name(profile, options=None):
    if profile["id"] != "meta":
        return profile["softwareName"]
    if options is None:
        return rc(META_SOFTWARE_NAMES)
    name = options.get("_metaSoftware")
    if not name:
        name = rc(META_SOFTWARE_NAMES)
        options["_metaSoftware"] = name
    return name

def twilio_username_token():
    """Временный креденшел Twilio: 20 hex-символов.

    Форма (длина и алфавит) как у настоящего, содержимое случайное: любой
    фиксированный литерал стал бы сигнатурой всех, кто пользуется профилем.
    """
    return to_hex(rb(10))

def build_stun_binding_username(profile, server_host):
    if profile["id"] == "meta":
        return enc_text("WA-%d:%s" % (1000000000 + ri(9000000000), server_host))
    if profile["id"] == "twilio":
        return enc_text("%s:%s" % (twilio_username_token(), server_host))
    return enc_text("%s:%s" % (to_hex(rb(4)), server_host))

def build_stun_allocate_username(profile, server_host):
    if profile["id"] == "meta":
        return enc_text("WA-%d@%s" % (1000000000 + ri(9000000000), server_host))
    suffix = str(ri(9000) + 1000)
    if profile["id"] == "twilio":
        return enc_text("%s%s@%s" % (twilio_username_token(), suffix, server_host))
    return enc_text("%s%s@%s" % (to_hex(rb(8)), suffix, server_host))

def generate_stun_payload(options):
    """
    STUN Binding или TURN Allocate под выбранного провайдера ICE.
    Реальный WebRTC-клиент шлёт ровно такие пакеты в начале звонка.
    """
    profile = resolve_stun_turn_profile(options.get("iceProvider") or "google")
    mode = resolve_stun_turn_mode(options, profile)
    server_host = options.get("iceServerHost") or rc(profile["serverPool"])

    # Свой домен пользователя и провайдерская маркировка вместе не живут:
    # клиент, который представляется Cloudflare, а ходит к чужому хосту, —
    # противоречие. Поэтому realm становится тем же доменом, а вендорские
    # имена уходят (SOFTWARE в STUN необязателен, RFC 5389 §15.10).
    if options.get("iceServerHost"):
        profile = dict(profile, id="generic", realm=server_host, softwareName=None)

    attrs = []

    if mode == "allocate":
        lifetime = profile["lifetimeRange"][0] + \
            ri(profile["lifetimeRange"][1] - profile["lifetimeRange"][0])
        attrs.append(build_stun_attribute(0x0014, enc_text(profile["realm"])))
        attrs.append(build_stun_attribute(0x000D, u32(lifetime)))
        attrs.append(build_stun_attribute(0x0019, u32(0x00000011) + zeros(4)))
        # REQUESTED-ADDRESS-FAMILY (0x0017, RFC 6156 §4.1.1): байт семейства,
        # затем три зарезервированных нуля.
        attrs.append(build_stun_attribute(
            0x0017, bytes([0x01 if ri(2) == 0 else 0x02, 0x00, 0x00, 0x00])))
        username = build_stun_allocate_username(profile, server_host)
    else:
        username = build_stun_binding_username(profile, server_host)

    software = stun_software_name(profile, options)
    if software:
        attrs.append(build_stun_attribute(0x8022, enc_text(software)))
    attrs.append(build_stun_attribute(0x0024, u32(ru32() | 0x40000000)))
    attrs.append(build_stun_attribute(0x8029 if ri(2) == 0 else 0x802A,
                                      u32(ru32()) + u32(ru32())))
    attrs.append(build_stun_attribute(0x0006, username))

    return build_stun_message_with_fingerprint(0x000A if mode == "allocate" else 0x0001, attrs)

def generate_webrtc_payload(options):
    """
    Связка первых пакетов WebRTC-сессии: STUN Binding, DTLS ClientHello,
    RTP и RTCP. Порт generateWebrtcCombinedPayload.
    """
    stun_options = dict(options)
    stun_options["iceMode"] = "binding"
    stun_payload = generate_stun_payload(stun_options)
    dtls_host = options.get("iceServerHost") or options.get("host") or "stun.l.google.com"
    return (stun_payload + generate_dtls_payload({"host": dtls_host}) +
            generate_rtp_payload() + generate_rtcp_payload())

# ================================================================
# Диспетчер профилей и вывод (app.js: appendChunkLines/chunkPayload)
# ================================================================
# Динамические поля (теги <r>/<rc>/<rd>) есть не у всех профилей — и это не
# недоделка, а свойство самих протоколов:
#   dns, ntp, rtp, sip, dtls — помечены (см. dyn() в соответствующих функциях);
#   webrtc — помечены только его DTLS/RTP-части, STUN внутри неприкосновенен;
#   stun   — весь пакет накрыт FINGERPRINT (CRC32 по всему сообщению), любое
#            динамическое поле сделало бы контрольную сумму несходящейся;
#   quic, curl_quic — ключи Initial выводятся из DCID, а заголовок целиком
#            входит в AAD (RFC 9001 §5.2): подменив байт, мы получаем пакет,
#            который не расшифрует никто, включая DPI, который как раз и лезет
#            в Initial за SNI. Повторный идентичный Initial выглядит обычной
#            ретрансмиссией, битый — аномалией. Поэтому статика;
#   ssdp   — M-SEARCH реального устройства и в жизни повторяется дословно.
PROTOCOL_GENERATORS = {
    "dns": generate_dns_payload,
    "quic": generate_quic_payload,
    "curl_quic": generate_curl_quic_payload,
    "stun": generate_stun_payload,
    "webrtc": generate_webrtc_payload,
    "sip": generate_sip_payload,
    "ntp": generate_ntp_payload,
    "rtp": generate_rtp_payload,
    "ssdp": generate_ssdp_payload,
    "dtls": generate_dtls_payload,
}

# Устаревшие имена профилей awg2 до перехода на payloadGen. TLS-запись поверх
# UDP не существует как протокол, поэтому профиль tls заменён на quic — это
# настоящий UDP-протокол с тем же Chrome-подобным ClientHello внутри.
PROFILE_ALIASES = {"tls": "quic"}

def chunk_payload(payload, mtu):
    if not payload:
        return [payload]
    return [payload[i:i + mtu] for i in range(0, len(payload), mtu)]

def build_options(profile, domain, domain_is_explicit, args):
    options = {"host": domain or DEFAULT_HOST}
    if profile in ("quic", "curl_quic"):
        options["quicMtu"] = args["mtu"]
        options["quicPadToMtu"] = False
        options["echDoh"] = args["ech_doh"]
    elif profile == "sip":
        # sipCustomMessage=True заставляет использовать наш домен, иначе
        # оригинал подставил бы CONFIG.defaultHost во все пять пакетов.
        options["sipCustomMessage"] = True
        options["hasCustomHost"] = True
        options["sipAction"] = args["sip_action"]
    elif profile in ("stun", "webrtc"):
        # random разыгрываем ЗДЕСЬ, один раз на цепочку, а не внутри
        # resolve_stun_turn_profile на каждый пакет. Атрибут SOFTWARE описывает
        # клиентскую реализацию, а не сервер: пять пакетов подряд, где клиент
        # называется то «Google STUN client», то «Twilio WebRTC ICE agent»,
        # то «Cloudflare WebRTC client», — это один браузер, объявивший себя
        # тремя разными. Такого не бывает, и заметно это без всякой статистики.
        provider = str(args["ice_provider"] or "").strip().lower()
        if provider == "random":
            provider = rc(STUN_PROVIDERS)
        options["iceProvider"] = provider
        options["iceMode"] = args["ice_mode"]
        # Имя приложения Meta фиксируем здесь же, а не лениво при первом
        # пакете: профиль webrtc собирает STUN на КОПИИ options
        # (dict(options)), и запомненное внутри копии значение до следующего
        # пакета не доживает — цепочка снова представлялась бы тремя разными
        # приложениями сразу.
        options["_metaSoftware"] = rc(META_SOFTWARE_NAMES)
        # Домен подставляем в ICE только если его ввёл пользователь: при
        # автогенерации правдоподобнее пул серверов самого провайдера.
        options["iceServerHost"] = domain if domain_is_explicit else ""
    return options

def main(argv):
    args = {
        "mtu": DEFAULT_MTU,
        # Бюджет длины всей цепочки в символах конфига (0 = без лимита).
        "budget": 0,
        "ech_doh": os.environ.get("AWG_CPS_ECH_DOH", "") not in ("", "0"),
        "sip_action": "OPTIONS",
        "ice_provider": "random",
        "ice_mode": "auto",
        # --static возвращает поведение до динамических тегов: строка целиком из
        # <b 0x..>. Нужен для сравнения в тестах и как аварийный откат, если
        # клиент окажется без поддержки <r>/<rc>.
        "static": False,
    }
    only_i1 = False
    positional = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--only-i1":
            only_i1 = True
        elif arg == "--static":
            args["static"] = True
        elif arg == "--ech-doh":
            args["ech_doh"] = True
        elif arg == "--full":
            # Флаг компактного режима старого генератора: размеры пакетов теперь
            # задаёт payloadGen, поэтому флаг принимается и ничего не меняет.
            pass
        elif arg == "--mtu" and index + 1 < len(argv):
            index += 1
            try:
                args["mtu"] = max(1200, min(1500, int(argv[index])))
            except ValueError:
                _warn_once("значение --mtu не число, беру %d" % DEFAULT_MTU)
        elif arg == "--budget" and index + 1 < len(argv):
            index += 1
            try:
                args["budget"] = max(0, int(argv[index]))
            except ValueError:
                _warn_once("значение --budget не число, лимит длины снят")
        elif arg == "--sip-action" and index + 1 < len(argv):
            index += 1
            args["sip_action"] = argv[index]
        elif arg == "--ice-provider" and index + 1 < len(argv):
            index += 1
            args["ice_provider"] = argv[index]
        elif arg == "--ice-mode" and index + 1 < len(argv):
            index += 1
            args["ice_mode"] = argv[index]
        elif arg.startswith("--"):
            _warn_once("неизвестный флаг %s пропущен" % arg)
        else:
            positional.append(arg)
        index += 1

    profile = positional[0] if positional else "quic"
    domain = positional[1].strip() if len(positional) > 1 else ""
    profile = PROFILE_ALIASES.get(profile, profile)
    if profile not in PROTOCOL_GENERATORS:
        _warn_once("неизвестный профиль %s, беру quic" % profile)
        profile = "quic"

    domain_is_explicit = bool(domain)
    if not domain:
        domain = rc(RU_DOMAIN_POOL)

    generator = PROTOCOL_GENERATORS[profile]
    options = build_options(profile, domain, domain_is_explicit, args)

    # Бюджет применяется ЦЕЛЫМИ пакетами. Обрезать пакет на середине нельзя:
    # получится не снимок протокола, а обрубок, по которому DPI отличает нас
    # быстрее, чем по отсутствию мимикрии вовсе. Поэтому сколько пакетов
    # поместится — зависит от профиля: DNS укладывает все пять в ~370 символов,
    # один QUIC Initial занимает ~2400. Первый пакет выдаётся всегда, иначе
    # слишком маленький бюджет молча оставил бы конфиг без мимикрии.
    budget = args["budget"]
    lines = []
    used = 0
    for _ in range(MAX_OUTPUT_LINES):
        if len(lines) >= MAX_OUTPUT_LINES:
            break
        # Помеченное поле выбрасывается из строки, если случайно встретилось в
        # пакете дважды: два тега разъехались бы, а копии обязаны совпадать.
        # Для коротких полей это не теория — Transaction ID в DNS занимает 2
        # байта, и примерно раз на 1600 пакетов они попадаются в теле ещё раз.
        # Тогда у пакета не остаётся ни одного динамического поля, и строка I
        # уходит в эфир БАЙТ В БАЙТ при каждом рукопожатии — ровно та статичная
        # сигнатура, против которой всё и делается. Пакет случайный, поэтому
        # достаточно сгенерировать заново.
        payload = None
        for _attempt in range(8):
            try:
                dyn_reset()
                payload = generator(options)
            except Exception as exc:
                _warn_once("сбой генерации %s (%s: %s)" % (profile, type(exc).__name__, exc))
                payload = None
                break
            if not _DYN or dyn_all_unique(payload):
                break
        if payload is None:
            break
        room = MAX_OUTPUT_LINES - len(lines)
        chunks = chunk_payload(payload, args["mtu"])
        if args["static"] or len(chunks) > 1:
            # Разрезанный на несколько строк пакет помечать нечем: смещения
            # полей уезжают в соседний кусок. Такое бывает только у QUIC при
            # маленьком --mtu, а там динамических полей всё равно нет.
            piece = ["<b 0x%s>" % to_hex(chunk) for chunk in chunks[:room]]
        else:
            piece = [build_tagged_line(payload)]
        cost = sum(len(item) for item in piece)
        if budget and lines and used + cost > budget:
            break
        lines.extend(piece)
        used += cost
        if only_i1:
            break

    if not lines:
        return 1
    for line in (lines[:1] if only_i1 else lines):
        print(line)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
'
# CPS_GENERATOR_END v2

_PY_HELPER_SUM=53b71a375d926f57
IFS= read -r -d '' _PY_HELPER <<'__AWG2_PY_HELPER__' || true
"""Встроенный помощник awg2: разбор и атомарная правка конфигов, JSON Xray,
расчёты подсетей, разбор pcap. Вызывается как `py <команда> [аргументы]`.

Коды выхода: 0 — успех, 1 — ошибка (текст в stderr), 2 — не найдено,
3 — дубликат. Всё, что пишется в файлы, пишется через временный файл рядом
с целевым и os.replace: обрыв на середине не оставляет битый конфиг.
"""
import base64
import importlib
import json
import os
import re
import struct
import sys
import time
import urllib.parse


class _Lazy:
    """Модуль, который загружается при первом обращении: большинство команд
    его не трогает, а awg2 api зовёт помощник дважды на каждый вызов."""

    def __init__(self, name):
        self._name, self._mod = name, None

    def __getattr__(self, attr):
        if self._mod is None:
            self._mod = importlib.import_module(self._name)
        return getattr(self._mod, attr)


ipaddress = _Lazy("ipaddress")
random = _Lazy("random")
secrets = _Lazy("secrets")
shutil = _Lazy("shutil")
string = _Lazy("string")
tempfile = _Lazy("tempfile")


def die(msg, code=1):
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(code)


def read(path):
    # surrogateescape: один не-UTF-8 байт в правленном руками конфиге иначе
    # останавливал все команды (peers, expire-check…), а байты так проходят
    # через чтение и запись без изменений.
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write_atomic(path, text, mode=0o600):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".awg2.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ════════════════════════ awg0.conf ════════════════════════
# Блок [Peer] может нести служебные комментарии «# ключ=значение»
# (mimicry, expires, orig_ips, note — последнюю пишет бот). Имя клиента —
# первый комментарий без «=»: валидатор имён этот знак не пропускает.

# Как парсер wireguard-tools: заголовок и ключи без учёта регистра, с
# пробелами по краям и комментарием «# …» в конце строки — такой пир живой
# для awg, значит и для нас.
PEER_SPLIT = re.compile(r"(?=^[ \t]*\[[ \t]*peer[ \t]*\][ \t]*(?:#.*)?$)", re.M | re.I)


def split_peers(text):
    parts = PEER_SPLIT.split(text)
    return parts[0], parts[1:]


def peer_name(block):
    lines = block.splitlines()
    # «[Peer] # alice» — имя в заголовке, как пишут руками и другие менеджеры
    m = re.match(r"^[ \t]*\[[ \t]*peer[ \t]*\][ \t]*#[ \t]*(.+?)[ \t]*$", lines[0] if lines else "", re.I)
    if m and "=" not in m.group(1):
        return m.group(1)
    for line in lines[1:]:
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m and "=" not in m.group(1):
            return m.group(1)
    return ""


def peer_field(block, key):
    m = re.search(r"^[ \t]*%s[ \t]*=[ \t]*([^#\r\n]*?)[ \t]*(?:#.*)?$" % re.escape(key), block, re.M | re.I)
    return m.group(1) if m else ""


def peer_meta(block, key):
    m = re.search(r"^#\s*%s=(.*?)\s*$" % re.escape(key), block, re.M)
    return m.group(1) if m else ""


def find_peer(peers, name=None, pubkey=None):
    for i, b in enumerate(peers):
        if pubkey is not None and peer_field(b, "PublicKey") == pubkey:
            return i
        if name is not None and peer_name(b) == name:
            return i
    return -1


def set_meta(block, key, value):
    block = re.sub(r"^#\s*%s=.*\n?" % re.escape(key), "", block, flags=re.M)
    if not value:
        return block
    lines = block.split("\n")
    # Метка встаёт сразу после имени, а без имени — после [Peer]
    at = 1
    for i, line in enumerate(lines[1:], 1):
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m and "=" not in m.group(1):
            at = i + 1
            break
    lines.insert(at, "# %s=%s" % (key, value))
    return "\n".join(lines)


def cmd_peers(conf):
    _, peers = split_peers(read(conf))
    for b in peers:
        pub = peer_field(b, "PublicKey")
        if not pub:
            continue
        print("\t".join([peer_name(b), pub, peer_field(b, "AllowedIPs"),
                         peer_meta(b, "expires"), peer_meta(b, "orig_ips"),
                         peer_meta(b, "mimicry"), peer_meta(b, "limit"), peer_meta(b, "blocked_by")]))


def cmd_meta_set(conf, name, key, value):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    peers[i] = set_meta(peers[i], key, value)
    write_atomic(conf, head + "".join(peers))


def cmd_peer_del(conf, pubkey):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, pubkey=pubkey)
    if i < 0:
        die("пир не найден", 2)
    name = peer_name(peers[i])
    del peers[i]
    text = head + "".join(peers)
    write_atomic(conf, re.sub(r"\n{3,}", "\n\n", text))
    print(name)


def cmd_peer_rename(conf, pubkey, new):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, pubkey=pubkey)
    if i < 0:
        die("пир не найден", 2)
    lines = peers[i].split("\n")
    for j, line in enumerate(lines[1:], 1):
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m and "=" not in m.group(1):
            lines[j] = "# " + new
            break
    else:
        lines.insert(1, "# " + new)
    peers[i] = "\n".join(lines)
    write_atomic(conf, head + "".join(peers))


def cmd_peers_clear(conf):
    head, _ = split_peers(read(conf))
    write_atomic(conf, head.rstrip("\n") + "\n")


AWG_PARAM_KEYS = ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
                  "HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime",
                  "RekeyTimeout", "RejectAfterTime", "KeepaliveTimeout",
                  "MaxHandshakeAttempts", "RandomTrailers", "DisableCookies")
PARAM_RE = re.compile(r"^(%s)\s*=" % "|".join(AWG_PARAM_KEYS))


def cmd_params_replace(path):
    """Заменить параметры AmneziaWG в [Interface] на строки из stdin.

    Ключи, адреса, I1-I5, DNS, MTU и секции [Peer] не трогаются: меняется
    только то, что обязано совпадать у сервера и всех клиентов.
    """
    params = [l for l in sys.stdin.read().splitlines() if l.strip()]
    if not params:
        die("пустой набор параметров")
    out, in_iface, done = [], False, False
    for line in read(path).split("\n"):
        if re.match(r"^\[Interface\]", line):
            in_iface = True
            out.append(line)
            continue
        if line.startswith("["):
            if in_iface and not done:
                if out and out[-1] == "":
                    out.pop()
                    out.extend(params)
                    out.append("")
                else:
                    out.extend(params)
                done = True
            in_iface = False
        if in_iface and PARAM_RE.match(line):
            if not done:
                out.extend(params)
                done = True
            continue
        out.append(line)
    if not done:
        out.extend(params)
    write_atomic(path, "\n".join(out))


# ── Правка параметров вручную ─────────────────────────────
# Пределы — те же, что соблюдает генератор (params.sh); здесь они проверяют
# то, что ввёл человек. Совпадать у сервера и клиентов обязаны S1-S4, H1-H4,
# HeaderProtectionKey и RandomTrailers; мусорные пакеты, ContentPaddingAddition
# и таймеры — нет (README amneziawg-go: «client-side»).
U32 = 0xFFFFFFFF
HP_MIN_S, S4_MAX, JC_MAX, S_GAP = 12, 32, 128, 10
MTU_OVERHEAD, MTU_SAFETY = 60, 24
BREAKING = ("S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "HeaderProtectionKey", "RandomTrailers")
EDIT_BASE = ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4")
EDIT_3X = ("ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime",
           "KeepaliveTimeout", "MaxHandshakeAttempts")
EDIT_31 = ("RandomTrailers", "DisableCookies")
SWITCHES = ("RandomTrailers", "DisableCookies")


def params_editable(proto):
    keys = list(EDIT_BASE)
    if proto.startswith("3"):
        keys += EDIT_3X
    if proto == "3.1":
        keys += EDIT_31
    return keys


def _prange(v):
    """«a» или «a-b» (a ≤ b ≤ 2^32-1) → (a, b); иначе None."""
    m = re.fullmatch(r"(\d{1,10})(?:-(\d{1,10}))?", v or "")
    if not m:
        return None
    a = int(m[1])
    b = int(m[2]) if m[2] else a
    return (a, b) if a <= b <= U32 else None


def _pnum(v):
    return int(v) if re.fullmatch(r"\d{1,10}", v or "") and int(v) <= U32 else None


def _params_norm(key, val):
    val = re.sub(r"\s+", "", val or "")
    if key in SWITCHES:
        low = val.lower()
        if low in ("on", "1", "yes", "true", "да", "вкл"):
            return "on"
        if low in ("off", "0", "no", "false", "нет", "выкл", ""):
            return "off"
    return val


def params_check(proto, mtu, old, edits):
    """old — {ключ: значение} из конфига, edits — [(ключ, значение)].
    → (ошибки, предупреждения, изменённые, новый словарь)."""
    errs, warns = [], []
    editable = params_editable(proto)
    by_low = {k.lower(): k for k in AWG_PARAM_KEYS}
    new = dict(old)
    for key, val in edits:
        k = by_low.get(key.strip().lower())
        if k is None:
            errs.append(f"{key}: нет такого параметра AmneziaWG")
        elif k == "HeaderProtectionKey":
            errs.append("HeaderProtectionKey меняется перегенерацией: Протокол → новые параметры")
        elif k not in editable:
            errs.append(f"{k}: параметр AWG 3.x, а сервер на {proto}")
        else:
            new[k] = _params_norm(k, val)
    for k in SWITCHES:
        if new.get(k) == "off":
            del new[k]
    changed = [k for k in AWG_PARAM_KEYS if old.get(k, "") != new.get(k, "")]
    ch = set(changed)
    is3 = proto.startswith("3")

    def num(k, lo, hi, what):
        v = _pnum(new.get(k, ""))
        if v is None or not lo <= v <= hi:
            errs.append(f"{k} = {new.get(k, '') or 'пусто'}: нужно {what}")
            return None
        return v

    jc = num("Jc", 0, JC_MAX, f"целое 0-{JC_MAX}")
    jmin = num("Jmin", 0, 1472, "целое 0-1472")
    jmax = num("Jmax", 0, 1472, "целое 0-1472 — больше не влезет в пакет 1500, а фрагменты заметны цензору")
    if jmin is not None and jmax is not None and jmin > jmax:
        errs.append(f"Jmin ({jmin}) больше Jmax ({jmax})")
    if jc is not None and "Jc" in ch and not 3 <= jc <= 12:
        warns.append(f"Jc = {jc}: рекомендуется 3-12" + (" — без мусорных пакетов" if jc == 0 else ""))

    # Рукопожатия с паддингом обязаны влезать в 1280 — минимальный MTU IPv6
    smin = HP_MIN_S if is3 else 0
    s = {}
    for k, base, hi in (("S1", 148, 1132), ("S2", 92, 1188), ("S3", 64, 1216), ("S4", 32, S4_MAX)):
        what = f"целое {smin}-{hi}" + (" (AWG 3.x требует ≥ 12)" if is3 else "") + (" — предел amneziawg-tools" if k == "S4" else "")
        s[k] = num(k, smin, hi, what)
    if None not in (s["S1"], s["S2"], s["S3"]):
        lens = {"S1": 148 + s["S1"], "S2": 92 + s["S2"], "S3": 64 + s["S3"]}
        names = {"S1": "инициации", "S2": "ответа", "S3": "cookie"}
        pairs = (("S1", "S2"), ("S1", "S3"), ("S2", "S3"))
        for a, b in pairs:
            d = abs(lens[a] - lens[b])
            if d == 0:
                errs.append(f"{a} и {b}: пакеты {names[a]} и {names[b]} выйдут одной длины ({lens[a]} Б) — "
                            "сервер не отличит их")
            elif d < S_GAP and ({a, b} & ch):
                warns.append(f"{a} и {b}: длины пакетов {names[a]} и {names[b]} почти совпадают "
                             f"({lens[a]} и {lens[b]} Б) — генератор разводит их на {S_GAP}+")

    h = {}
    for k in ("H1", "H2", "H3", "H4"):
        r = _prange(new.get(k, ""))
        if r is None:
            errs.append(f"{k} = {new.get(k, '') or 'пусто'}: нужно число или диапазон a-b (a ≤ b ≤ {U32})")
        else:
            h[k] = r
    keys = sorted(h)
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            if h[a][0] <= h[b][1] and h[b][0] <= h[a][1]:
                errs.append(f"{a} и {b} пересекаются — сервер не отличит типы пакетов")
    if not is3:
        for k, (lo, hi) in h.items():
            if k not in ch:
                continue
            if lo <= 4:
                warns.append(f"{k}: задевает 1-4 — стандартные типы WireGuard, прямой признак для DPI")
            if hi > 0x7FFFFFFF:
                warns.append(f"{k}: выше 2147483647 — старый клиент AmneziaVPN для Windows не примет")
            if hi - lo < 1000:
                warns.append(f"{k}: узкий диапазон — заголовок почти постоянный, это подпись для DPI")

    cpa = 0
    if is3:
        for k in EDIT_3X:
            if k not in new:
                continue
            r = _prange(new[k])
            if r is None or r[0] < (0 if k == "ContentPaddingAddition" else 1):
                errs.append(f"{k} = {new[k] or 'пусто'}: нужно число или диапазон a-b"
                            + ("" if k == "ContentPaddingAddition" else ", от 1"))
            elif k == "ContentPaddingAddition":
                cpa = r[1]
        rat, rjt = _prange(new.get("RekeyAfterTime", "")), _prange(new.get("RejectAfterTime", ""))
        if rat and rjt and rjt[0] <= rat[1]:
            errs.append("RejectAfterTime должен быть целиком больше RekeyAfterTime — иначе сессия умрёт "
                        "раньше, чем переустановится")
        rkt = _prange(new.get("RekeyTimeout", ""))
        if rkt and rkt[0] < 5 and "RekeyTimeout" in ch:
            warns.append("RekeyTimeout меньше 5 с — лишние повторы рукопожатия")
        for k in SWITCHES:
            if k in new and new[k] != "on":
                errs.append(f"{k}: только on или off")

    # Запас до пути 1500: тот же расчёт, что у генератора (_check_mtu_headroom)
    if str(mtu).isdigit() and s.get("S4") is not None and ({"S4", "ContentPaddingAddition"} & ch):
        outer = int(mtu) + MTU_OVERHEAD + s["S4"] + cpa
        if outer > 1500 - MTU_SAFETY:
            warns.append(f"MTU {mtu}: внешний пакет до {outer} Б — не остаётся запаса до 1500; "
                         "уменьши S4" + (" или ContentPaddingAddition" if is3 else ""))
    return errs, warns, changed, new


def cmd_params_check(proto, mtu, *edits):
    """stdin — параметры сервера («Ключ = значение»), аргументы — правки
    «Ключ=значение». Вывод построчно: K ключ значение (редактируемые, после
    правок), E ошибка, W предупреждение, C изменённый ключ, B изменённый ключ,
    который обязан совпадать у клиентов, P строка нового блока параметров."""
    old = {}
    for line in sys.stdin.read().splitlines():
        m = re.match(r"^(\w+)\s*=\s*(.*?)\s*$", line)
        if m and m[1] in AWG_PARAM_KEYS:
            old[m[1]] = m[2]
    pairs = []
    for e in edits:
        if "=" not in e:
            die(f"правка «{e}»: нужно Ключ=значение")
        k, v = e.split("=", 1)
        pairs.append((k, v))
    errs, warns, changed, new = params_check(proto, mtu, old, pairs)
    out = [f"K\t{k}\t{new.get(k, 'off' if k in SWITCHES else '')}" for k in params_editable(proto)]
    out += [f"E\t{x}" for x in errs] + [f"W\t{x}" for x in warns]
    out += [f"C\t{k}" for k in changed] + [f"B\t{k}" for k in changed if k in BREAKING]
    out += [f"P\t{k} = {new[k]}" for k in AWG_PARAM_KEYS if k in new]
    print("\n".join(out))


def cmd_keepalive_set(path, value):
    text = read(path)
    new = re.sub(r"^PersistentKeepalive\s*=.*$", "PersistentKeepalive = " + value, text, flags=re.M)
    if new != text:
        write_atomic(path, new)


def cmd_i_replace(path):
    """Заменить строки I1-I5 клиента на строки из stdin (пусто — убрать)."""
    lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
    out, inserted = [], False
    for line in read(path).split("\n"):
        if re.match(r"^I[1-5]\s*=", line):
            continue
        if PEER_SPLIT.match(line) and not inserted:
            while out and out[-1] == "":
                out.pop()
            out.extend(lines)
            out.append("")
            inserted = True
        out.append(line)
    write_atomic(path, "\n".join(out))


# ── Срок действия клиентов ──
def cmd_expire_set(conf, name, ts):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    peers[i] = set_meta(peers[i], "expires", ts)
    write_atomic(conf, head + "".join(peers))


def cmd_expire_clear(conf, name, suspend):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    b = peers[i]
    if peer_meta(b, "blocked_by") == "traffic":
        # Блокировку держит лимит трафика: снимается только срок
        peers[i] = set_meta(b, "expires", "")
        write_atomic(conf, head + "".join(peers))
        print("traffic")
        return
    orig = peer_meta(b, "orig_ips")
    if orig and peer_field(b, "AllowedIPs") == suspend:
        b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + orig, b, count=1, flags=re.M | re.I)
    b = set_meta(set_meta(set_meta(b, "expires", ""), "orig_ips", ""), "blocked_by", "")
    peers[i] = b
    write_atomic(conf, head + "".join(peers))
    print(orig)


def cmd_expire_check(conf, suspend, state_dir):
    """Блокирует истёкших (AllowedIPs → suspend, исходный адрес в orig_ips)
    и предупреждает за час до срока. Печатает события построчно:
    CHANGED; EXPIRED<TAB>имя<TAB>адрес; WARN1H<TAB>имя<TAB>минут."""
    try:
        text = read(conf)
    except OSError:
        return
    now = int(time.time())
    head, peers = split_peers(text)
    events, changed = [], False
    for i, b in enumerate(peers):
        exp, pub, aip = peer_meta(b, "expires"), peer_field(b, "PublicKey"), peer_field(b, "AllowedIPs")
        if not (exp.isdigit() and pub and aip):
            continue
        exp = int(exp)
        name = peer_name(b) or pub[:8]
        if now >= exp and aip != suspend:
            if not peer_meta(b, "orig_ips"):
                b = set_meta(b, "orig_ips", aip)
            b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + suspend, b, count=1, flags=re.M | re.I)
            peers[i] = b
            changed = True
            events.append("EXPIRED\t%s\t%s" % (name, aip))
        elif aip != suspend and 0 < exp - now <= 3600:
            lock = os.path.join(state_dir, "warn1h_" + re.sub(r"[^A-Za-z0-9]", "_", pub))
            if not os.path.exists(lock):
                events.append("WARN1H\t%s\t%d" % (name, max(1, (exp - now) // 60)))
                try:
                    os.makedirs(state_dir, exist_ok=True)
                    with open(lock, "w") as f:
                        f.write(str(now))
                except OSError:
                    pass
    if changed:
        write_atomic(conf, head + "".join(peers))
        print("CHANGED")
    for e in events:
        print(e)


# ── Трафик клиентов и лимиты ──
# Счётчики `awg show transfer` живут, пока поднят интерфейс, поэтому таймер
# каждые 15 с складывает их прирост в базу: по дням (DAYS_KEEP дней) и за
# всё время. Ключ — публичный ключ: переименование историю не теряет.
# Лимит — метка пира «# limit=БАЙТ/month|total»; превысивший блокируется
# как истёкший (AllowedIPs → suspend), с меткой «# blocked_by=traffic» — по
# ней таймер разблокирует его в новом месяце или после смены лимита.
DAYS_KEEP = 92
TRAFFIC_SAVE_EVERY = 300
SIZE_UNITS = {"": 1024 ** 3, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
SIZE_MAX = 1024 ** 5


def fmt_bytes(n):
    n = float(n or 0)
    for unit in ("Б", "КБ", "МБ", "ГБ"):
        if n < 1024:
            return "%d %s" % (n, unit) if unit == "Б" else "%.1f %s" % (n, unit)
        n /= 1024
    return "%.1f ТБ" % n


def parse_size(text):
    """«50G», «500M», «1.5T», «50» (гигабайты) → байты; None — не размер.
    «500B» без K/M/G/T — не гигабайты, а ошибка; больше 1 ПБ — тоже."""
    m = re.match(r"^\s*(\d{1,7}(?:[.,]\d{1,3})?)\s*([KMGT]?)(i?B)?\s*$", text or "", re.I | re.A)
    if not m or (m.group(3) and not m.group(2)):
        return None
    n = int(float(m.group(1).replace(",", ".")) * SIZE_UNITS[m.group(2).upper()])
    return n if 0 < n <= SIZE_MAX else None


def parse_limit(value):
    """Метка «БАЙТ/период» → (байт, период) или (0, "")."""
    m = re.match(r"^(\d+)/(month|total)$", value or "")
    return (int(m.group(1)), m.group(2)) if m else (0, "")


def _read_transfer(path):
    out = {}
    try:
        for line in read(path).splitlines():
            f = line.split("\t")
            if len(f) >= 3 and f[1].isdigit() and f[2].isdigit():
                out[f[0]] = (int(f[1]), int(f[2]))
    except OSError:
        pass
    return out


class Traffic:
    """База трафика: {"v", "ifindex", "saved", "last": {pub: [rx, tx]},
    "total": {pub: n}, "days": {"ГГГГ-ММ-ДД": {pub: [rx, tx]}},
    "reset": {pub: {"p": период, "b": байт}}, "warned": {pub: "период:лимит"}}."""

    def __init__(self, path):
        self.path = path
        try:
            data = json.loads(read(path))
        except (OSError, ValueError):
            data = {}
        self.fresh = not isinstance(data, dict) or "last" not in data
        if not isinstance(data, dict):
            data = {}
        self.d = {k: data.get(k) if isinstance(data.get(k), dict) else {}
                  for k in ("last", "total", "days", "reset", "warned")}
        self.ifindex = str(data.get("ifindex") or "")
        self.saved = int(data.get("saved") or 0)

    def apply(self, counters, ifindex=""):
        """Прирост счётчиков с прошлого раза — в сегодняшний день. Новый
        интерфейс (другой ifindex — awg0 пересоздан) или счётчик меньше
        прежнего — отсчёт с нуля. Самый первый проход только запоминает
        счётчики: накопленное до учёта к сегодняшнему дню не относится."""
        if self.fresh and not counters:
            # Счётчиков нет (интерфейс лежит) — запоминать нечего: иначе
            # следующий проход посчитал бы всё накопленное до учёта
            return
        today = time.strftime("%Y-%m-%d")
        last, total = self.d["last"], self.d["total"]
        reborn = bool(ifindex) and bool(self.ifindex) and ifindex != self.ifindex
        day = self.d["days"].setdefault(today, {})
        for pub, (rx, tx) in counters.items():
            prev = last.get(pub)
            if self.fresh:
                drx = dtx = 0
            elif reborn or not isinstance(prev, list) or len(prev) != 2 or rx < prev[0] or tx < prev[1]:
                drx, dtx = rx, tx
            else:
                drx, dtx = rx - prev[0], tx - prev[1]
            last[pub] = [rx, tx]
            if drx or dtx:
                cur = day.get(pub) or [0, 0]
                day[pub] = [cur[0] + drx, cur[1] + dtx]
                total[pub] = int(total.get(pub) or 0) + drx + dtx
        if ifindex:
            self.ifindex = ifindex
        self.fresh = False

    @staticmethod
    def period_key(period):
        return time.strftime("%Y-%m") if period == "month" else "total"

    def raw_used(self, pub, period):
        if period == "month":
            month = time.strftime("%Y-%m")
            return sum(sum(v.get(pub) or [0, 0]) for d, v in self.d["days"].items() if d.startswith(month))
        return int(self.d["total"].get(pub) or 0)

    def used(self, pub, period):
        raw = self.raw_used(pub, period)
        r = self.d["reset"].get(pub)
        if isinstance(r, dict) and r.get("p") == self.period_key(period):
            return max(0, raw - int(r.get("b") or 0))
        return raw

    def reset(self, pub, period):
        self.d["reset"][pub] = {"p": self.period_key(period), "b": self.raw_used(pub, period)}
        self.d["warned"].pop(pub, None)

    def series(self, pubs, days):
        """Последние days дней (от старых к новым): даты, rx и tx по списку ключей."""
        dates = [time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400 * i)) for i in range(days - 1, -1, -1)]
        rx, tx = [], []
        for d in dates:
            v = self.d["days"].get(d) or {}
            rx.append(sum((v.get(p) or [0, 0])[0] for p in pubs))
            tx.append(sum((v.get(p) or [0, 0])[1] for p in pubs))
        return dates, rx, tx

    def save(self, alive=None):
        """Старше DAYS_KEEP дней — прочь; у удалённых клиентов остаётся
        только история по дням (она входит в общий трафик сервера)."""
        cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400 * DAYS_KEEP))
        self.d["days"] = {k: v for k, v in self.d["days"].items() if k >= cutoff and v}
        if alive is not None:
            for k in ("last", "total", "reset", "warned"):
                self.d[k] = {p: v for p, v in self.d[k].items() if p in alive}
        self.saved = int(time.time())
        data = dict(self.d, v=1, ifindex=self.ifindex, saved=self.saved)
        if self.fresh:
            # Счётчики ещё не запомнены: следующий проход — снова первый
            del data["last"]
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        write_atomic(self.path, json.dumps(data, separators=(",", ":")))


def _block(b, suspend, aip, reason):
    if not peer_meta(b, "orig_ips"):
        b = set_meta(b, "orig_ips", aip)
    b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + suspend, b, count=1, flags=re.M | re.I)
    return set_meta(b, "blocked_by", reason)


def _unblock(b, suspend):
    orig = peer_meta(b, "orig_ips")
    if orig and peer_field(b, "AllowedIPs") == suspend:
        b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + orig, b, count=1, flags=re.M | re.I)
    return set_meta(set_meta(b, "orig_ips", ""), "blocked_by", "")


PERIOD_WORD = {"month": "за месяц", "total": "всего"}


def cmd_traffic_tick(conf, suspend, db, transfer, ifindex="", force_save="0"):
    """Проход таймера: прирост трафика в базу и проверка лимитов. События:
    CHANGED; LIMIT<TAB>имя<TAB>адрес<TAB>текст; WARN90<TAB>имя<TAB>текст;
    UNLIMIT<TAB>имя<TAB>текст."""
    lock = _traffic_lock(db)
    try:
        text = read(conf)
    except OSError:
        return
    t = Traffic(db)
    t.apply(_read_transfer(transfer), ifindex)
    now = int(time.time())
    head, peers = split_peers(text)
    events, changed, alive = [], False, set()
    for i, b in enumerate(peers):
        pub, aip = peer_field(b, "PublicKey"), peer_field(b, "AllowedIPs")
        if not (pub and aip):
            continue
        alive.add(pub)
        name = peer_name(b) or pub[:8]
        limit, period = parse_limit(peer_meta(b, "limit"))
        by_traffic = peer_meta(b, "blocked_by") == "traffic"
        exp = peer_meta(b, "expires")
        expired = exp.isdigit() and now >= int(exp)
        used = t.used(pub, period) if limit else 0
        word = "%s из %s %s" % (fmt_bytes(used), fmt_bytes(limit), PERIOD_WORD.get(period, "")) if limit else ""
        if by_traffic and (not limit or used < limit):
            if expired:
                # Лимит отпустил, но истёк срок: блокировку держит уже он,
                # и снимается она сроком
                peers[i] = set_meta(b, "blocked_by", "")
            else:
                peers[i] = _unblock(b, suspend)
                events.append("UNLIMIT\t%s\t%s" % (name, word or "лимит снят"))
            changed = True
        elif limit and used >= limit and aip != suspend:
            peers[i] = _block(b, suspend, aip, "traffic")
            changed = True
            events.append("LIMIT\t%s\t%s\t%s" % (name, aip, word))
        elif limit and used >= limit * 0.9 and aip != suspend:
            mark = "%s:%d" % (t.period_key(period), limit)
            if t.d["warned"].get(pub) != mark:
                t.d["warned"][pub] = mark
                events.append("WARN90\t%s\t%s" % (name, word))
    if changed:
        write_atomic(conf, head + "".join(peers))
        print("CHANGED")
    day_changed = time.strftime("%Y-%m-%d", time.localtime(t.saved)) != time.strftime("%Y-%m-%d")
    if events or changed or day_changed or force_save == "1" or now - t.saved >= TRAFFIC_SAVE_EVERY:
        t.save(alive)
    del lock
    for e in events:
        print(e)


def _traffic_lock(db):
    """Таймер и вызовы API правят базу по очереди."""
    import fcntl
    try:
        os.makedirs(os.path.dirname(os.path.abspath(db)), exist_ok=True)
        f = open(db + ".lock", "a")
        fcntl.flock(f, fcntl.LOCK_EX)
        return f
    except OSError:
        return None


def cmd_limit_set(conf, db, name, size, period="month", transfer="", ifindex=""):
    """Лимит клиенту: размер («50G»), off — снять. Лимит «всего» считается
    с этой минуты; «за месяц» — с начала месяца. transfer — снимок
    `awg show transfer`: прирост до этой минуты в новый отсчёт не попадает."""
    if size != "off":
        n = parse_size(size)
        if n is None:
            die("размер не распознан: %s (пример: 50G, 500M)" % size)
        if period not in PERIOD_WORD:
            die("период: month или total")
    lock = _traffic_lock(db)
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    if size == "off":
        peers[i] = set_meta(peers[i], "limit", "")
        write_atomic(conf, head + "".join(peers))
        return
    pub = peer_field(peers[i], "PublicKey")
    t = Traffic(db)
    if transfer:
        t.apply(_read_transfer(transfer), ifindex)
    old, old_period = parse_limit(peer_meta(peers[i], "limit"))
    if period == "total" and old_period != "total":
        t.reset(pub, "total")
    t.d["warned"].pop(pub, None)
    t.save()
    peers[i] = set_meta(peers[i], "limit", "%d/%s" % (n, period))
    write_atomic(conf, head + "".join(peers))
    del lock
    print(fmt_bytes(n))


def cmd_limit_reset(conf, db, name, transfer="", ifindex=""):
    """Обнулить счётчик лимита (до конца периода)."""
    lock = _traffic_lock(db)
    _, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    limit, period = parse_limit(peer_meta(peers[i], "limit"))
    if not limit:
        die("у клиента %s нет лимита" % name)
    t = Traffic(db)
    if transfer:
        t.apply(_read_transfer(transfer), ifindex)
    t.reset(peer_field(peers[i], "PublicKey"), period)
    t.save()
    del lock


def cmd_traffic_daily(conf, db, transfer, name="", days="30"):
    """Трафик по дням: сервер целиком (с разбивкой по клиентам) или один
    клиент. Несохранённый прирост счётчиков учитывается, база не пишется."""
    try:
        days = max(1, min(DAYS_KEEP, int(days)))
    except ValueError:
        days = 30
    _, peers = split_peers(read(conf))
    names = {peer_field(b, "PublicKey"): peer_name(b) for b in peers if peer_field(b, "PublicKey")}
    t = Traffic(db)
    t.apply(_read_transfer(transfer))
    if name:
        pubs = [p for p, n in names.items() if n == name]
        if not pubs:
            die("клиент %s не найден" % name, 2)
    else:
        pubs = sorted({p for v in t.d["days"].values() for p in v} | set(names))
    dates, rx, tx = t.series(pubs, days)
    out = {"name": name, "days": dates, "rx": rx, "tx": tx, "total": sum(rx) + sum(tx)}
    if not name:
        rows = []
        for p, n in names.items():
            _, r, s = t.series([p], days)
            if sum(r) + sum(s):
                rows.append({"name": n or p[:8], "rx": sum(r), "tx": sum(s)})
        out["clients"] = sorted(rows, key=lambda c: -(c["rx"] + c["tx"]))
    print(json.dumps(out, ensure_ascii=False))


def _wgobf_names(conf):
    """wgobf0.conf: ключ клиента → имя из «# client=имя» в его [Peer]."""
    names, name = {}, None
    for line in read(conf).splitlines():
        line = line.strip()
        if line == "[Peer]":
            name = None
        elif line.startswith("# client="):
            name = line[len("# client="):]
        elif name and line.startswith("PublicKey") and "=" in line:
            names[line.split("=", 1)[1].strip()] = name
    return names


def cmd_traffic_now(conf, transfer, wconf="", wtransfer=""):
    """Счётчики awg0 сейчас — для живой скорости в панели: время (с долями
    секунды) и {имя: [приём, отдача]}; клиенты WG + обфускатора (wgobf0) —
    отдельно в wpeers, имена у них свои. Только чтение, база трафика не трогается."""
    _, peers = split_peers(read(conf))
    names = {peer_field(b, "PublicKey"): peer_name(b) for b in peers if peer_field(b, "PublicKey")}
    out = {}
    for pub, (rx, tx) in _read_transfer(transfer).items():
        if pub in names:
            out[names[pub] or pub[:8]] = [rx, tx]
    wout = {}
    if wconf and wtransfer and os.path.isfile(wconf):
        wnames = _wgobf_names(wconf)
        for pub, (rx, tx) in _read_transfer(wtransfer).items():
            if pub in wnames:
                wout[wnames[pub]] = [rx, tx]
    print(json.dumps({"ts": round(time.time(), 3), "peers": out, "wpeers": wout}, ensure_ascii=False))


def cmd_traffic_rows(conf, db, transfer):
    """Для меню: имя, лимит (байт), период, использовано по лимиту, за
    месяц, сегодня, причина блокировки — построчно через табуляцию."""
    _, peers = split_peers(read(conf))
    t = Traffic(db)
    t.apply(_read_transfer(transfer))
    today = time.strftime("%Y-%m-%d")
    for b in peers:
        pub = peer_field(b, "PublicKey")
        if not pub:
            continue
        limit, period = parse_limit(peer_meta(b, "limit"))
        by = peer_meta(b, "blocked_by") or ("expire" if peer_meta(b, "orig_ips") else "")
        print("\t".join(str(x) for x in (
            peer_name(b), limit, period, t.used(pub, period) if limit else 0, t.raw_used(pub, "month"),
            sum((t.d["days"].get(today) or {}).get(pub) or [0, 0]), by)))


def cmd_traffic_report(conf, db, transfer, days="14"):
    """Трафик сервера по дням столбиками и клиенты за 30 дней — для меню."""
    try:
        days = max(1, min(DAYS_KEEP, int(days)))
    except ValueError:
        days = 14
    _, peers = split_peers(read(conf))
    names = {peer_field(b, "PublicKey"): peer_name(b) for b in peers if peer_field(b, "PublicKey")}
    t = Traffic(db)
    t.apply(_read_transfer(transfer))
    pubs = sorted({p for v in t.d["days"].values() for p in v} | set(names))
    dates, rx, tx = t.series(pubs, days)
    top = max([a + b for a, b in zip(rx, tx)] + [1])
    print("По дням (↓ от клиентов + ↑ к клиентам):")
    for d, a, b in zip(dates, rx, tx):
        bar = "▇" * int(round(28 * (a + b) / top)) if a + b else ""
        print("  %s.%s  %-28s %s" % (d[8:], d[5:7], bar, fmt_bytes(a + b) if a + b else "—"))
    print("  Итого за %d дн.: %s" % (days, fmt_bytes(sum(rx) + sum(tx))))
    rows = []
    for p, n in names.items():
        _, r, s = t.series([p], 30)
        if sum(r) + sum(s):
            rows.append((sum(r) + sum(s), n or p[:8]))
    if rows:
        print("")
        print("Клиенты за 30 дней:")
        for total, n in sorted(rows, reverse=True)[:15]:
            print("  %-24s %s" % (n, fmt_bytes(total)))


def cmd_size_parse(text):
    n = parse_size(text)
    if n is None:
        die("размер не распознан: %s" % text)
    print(n)


# ════════════════════════ сети ════════════════════════
def cmd_net_of(cidr):
    print(ipaddress.ip_network(cidr.split(",")[0].strip(), strict=False))


def cmd_pick_net(pool="wgobf"):
    """Свободная /24, не пересекающаяся ни с одним адресом и маршрутом из stdin.
    pool=awg — 10.[10-55].x (как всегда выбирался AWG), иначе пулы
    WG+обфускатора: 10.[60-99].x, 172.16-31.x, 192.168.x."""
    taken = []
    for tok in re.findall(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?(?![\d.])", sys.stdin.read()):
        try:
            n = ipaddress.ip_network(tok, strict=False)
        except ValueError:
            continue
        if n.prefixlen:
            taken.append(n)
    pools = [lambda: "10.%d.%d.0/24" % (random.randint(60, 99), random.randint(1, 254)),
             lambda: "172.%d.%d.0/24" % (random.randint(16, 31), random.randint(1, 254)),
             lambda: "192.168.%d.0/24" % random.randint(100, 250)]
    if pool == "awg":
        pools.insert(0, lambda: "10.%d.%d.0/24" % (random.randint(10, 55), random.randint(1, 254)))
    for pick in pools:
        for _ in range(300):
            net = ipaddress.ip_network(pick())
            if not any(net.overlaps(t) for t in taken):
                print(net)
                return
    die("свободной /24 нет")


def cmd_net_overlaps(cidr):
    """0 — сеть cidr пересекается с чем-то из stdin, 1 — свободна."""
    net = ipaddress.ip_network(cidr, strict=False)
    for tok in re.findall(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?(?![\d.])", sys.stdin.read()):
        try:
            n = ipaddress.ip_network(tok, strict=False)
        except ValueError:
            continue
        if n.prefixlen and net.overlaps(n):
            print(n)
            return
    sys.exit(1)


def cmd_allowed_except(ip):
    """AllowedIPs «весь IPv4, кроме сервера»: иначе пакеты обфускатора клиента
    к серверу уйдут в сам туннель. Работает на любой платформе, в отличие от FwMark."""
    srv = ipaddress.ip_network(ip + "/32")
    nets = sorted(ipaddress.ip_network("0.0.0.0/0").address_exclude(srv))
    print(", ".join(str(n) for n in nets) + ", ::/0")


def cmd_rand_key(n="32"):
    alphabet = string.ascii_letters + string.digits
    print("".join(secrets.choice(alphabet) for _ in range(int(n))))


def cmd_phobos_link(path, name):
    conf = open(path, "rb").read()
    print("phobos://" + base64.urlsafe_b64encode(conf).decode().rstrip("=")
          + "#" + urllib.parse.quote(name))


def cmd_exit_conf_fix(path):
    """Конфиг клиента к exit-ноде: Table = off обязателен (иначе awg-quick
    уведёт в туннель весь сервер вместе с SSH), DNS выбрасываем (awg-quick
    перепишет resolv.conf сервера или упадёт без resolvconf). PreUp/PostUp/
    PreDown/PostDown тоже: awg-quick выполняет их через bash от root, а конфиг
    приходит снаружи (вставка, бот, чужой бэкап) — это данные, не скрипт.
    SaveConfig — чтобы awg-quick не переписывал файл при остановке."""
    out, in_iface, added = [], False, False
    for line in read(path).replace("\r", "").split("\n"):
        if re.match(r"^\s*\[\s*interface\s*\]", line, re.I):
            in_iface = True
            out.append("[Interface]")
            out.append("Table = off")
            added = True
            continue
        if re.match(r"^\s*\[", line):
            in_iface = False
        if in_iface and re.match(r"^\s*(table|dns|preup|postup|predown|postdown|saveconfig)\s*=", line, re.I):
            continue
        out.append(line)
    if not added:
        die("нет секции [Interface]")
    write_atomic(path, "\n".join(out))


# Хуки awg-quick/wg-quick (PreUp/PostUp/PreDown/PostDown) выполняются через
# eval от root. Конфиг сервера из бэкапа мог прийти чужой — пропускаем только
# команды, какие пишет сама Тулза и её прежние версии: iptables/ip6tables,
# включение ip_forward, MTU интерфейса, true; плюс точные команды из allow.
HOOK_LINE = re.compile(r"^\s*(preup|postup|predown|postdown|saveconfig)\s*=\s*(.*?)\s*$", re.I)
_HOOK_REDIR = r"(?:\s+(?:2>/dev/null|>/dev/null(?:\s+2>&1)?|2>&1))*"
_HOOK_TOKEN = r"""(?:[A-Za-z0-9_.:/,!=+%@-]+|"[A-Za-z0-9_.:/,!=+%@ -]*"|'[A-Za-z0-9_.:/,!=+%@ -]*')"""
HOOK_SAFE = [
    re.compile(r"^(?:iptables|ip6tables)(?:\s+%s)+%s$" % (_HOOK_TOKEN, _HOOK_REDIR)),
    re.compile(r"^echo\s+1\s*>\s*/proc/sys/net/ipv4/ip_forward$"),
    re.compile(r"^sysctl\s+(?:-q\s+)?-q?w\s+net\.ipv4\.ip_forward=1%s$" % _HOOK_REDIR),
    re.compile(r"^ip\s+link\s+set\s+(?:dev\s+)?[A-Za-z0-9_.%%-]{1,15}\s+mtu\s+\d{3,5}%s$" % _HOOK_REDIR),
    re.compile(r"^true$"),
]


def _hook_cmd_safe(cmd, allow):
    if cmd in allow:
        return True
    if not any(r.match(cmd) for r in HOOK_SAFE):
        return False
    # iptables --modprobe=ПРОГРАММА (и сокращения getopt: --mod, --modp…)
    # запускает любую программу — такой «iptables» не пропускаем
    for tok in cmd.split():
        name = tok.strip("\"'").split("=", 1)[0]
        if name == "-M" or (len(name) > 3 and "--modprobe".startswith(name)) or name.startswith("--modprobe"):
            return False
    return True


def cmd_conf_hooks(path, mode, *allow):
    """Хуки конфига сервера: check — напечатать недопустимые команды
    («ключ<TAB>команда»), fix — убрать их из файла (допустимые остаются,
    SaveConfig — всегда). Команды делятся по «;», «||» и «&&»: недопустима
    хоть одна ветка — убирается вся команда."""
    if mode not in ("check", "fix"):
        die("режим: check | fix")
    out, bad, in_iface = [], [], False
    for line in read(path).split("\n"):
        if re.match(r"^\s*\[", line):
            in_iface = bool(re.match(r"^\s*\[\s*interface\s*\]", line, re.I))
        m = HOOK_LINE.match(line) if in_iface else None
        if not m:
            out.append(line)
            continue
        key, value = m.group(1), m.group(2)
        if key.lower() == "saveconfig":
            bad.append((key, line.strip()))
            continue
        keep = []
        for cmd in (c.strip() for c in value.split(";")):
            if not cmd:
                continue
            if all(_hook_cmd_safe(alt.strip(), allow) for alt in re.split(r"\|\||&&", cmd)):
                keep.append(cmd)
            else:
                bad.append((key, cmd))
        if keep:
            out.append(line if len(keep) == len([c for c in value.split(";") if c.strip()])
                       else "%s = %s" % (key, "; ".join(keep)))
    for key, cmd in bad:
        print("%s\t%s" % (key, cmd))
    if mode == "fix" and bad:
        write_atomic(path, "\n".join(out))


# ════════════════════════ Xray ════════════════════════
SKIP_PROTO = ("freedom", "blackhole", "dns")
KNOWN_IN = {"xray0", "tun-in", "tun-probe", "socks-in"}
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"]}


def jload(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def jsave(path, conf):
    write_atomic(path, json.dumps(conf, indent=2, ensure_ascii=False) + "\n", 0o600)


def proxy_tags(conf):
    return [o["tag"] for o in conf.get("outbounds", [])
            if o.get("tag") and o.get("protocol") not in SKIP_PROTO]


def apply_transport(ss, net, get):
    if net == "ws":
        cfg = {}
        if get("path"):
            cfg["path"] = get("path")
        if get("host"):
            cfg["headers"] = {"Host": get("host")}
        ss["wsSettings"] = cfg
    elif net == "grpc":
        cfg = {}
        svc = get("serviceName") or get("svc") or get("path")
        if svc:
            cfg["serviceName"] = svc
        if get("mode") == "multi":
            cfg["multiMode"] = True
        ss["grpcSettings"] = cfg
    elif net in ("xhttp", "splithttp"):
        # Без path сервер отдаёт 404 на корень: TLS проходит, трафика нет
        cfg = {k: get(k) for k in ("path", "host", "mode") if get(k)}
        if get("extra"):
            try:
                cfg["extra"] = json.loads(get("extra"))
            except ValueError:
                pass
        ss["xhttpSettings" if net == "xhttp" else "splithttpSettings"] = cfg
    elif net == "httpupgrade":
        ss["httpupgradeSettings"] = {k: get(k) for k in ("path", "host") if get(k)}
    elif net in ("h2", "http"):
        # Транспорт HTTP/2 из Xray убран в пользу XHTTP stream-one
        cfg = {"mode": "stream-one"}
        if get("path"):
            cfg["path"] = get("path")
        if get("host"):
            cfg["host"] = get("host").split(",")[0]
        ss["network"] = "xhttp"
        ss["xhttpSettings"] = cfg
        sys.stderr.write("NOTE:транспорт h2 переведён на XHTTP stream-one\n")
    elif net not in ("tcp", "raw", "", None):
        sys.stderr.write("UNSUPPORTED:%s\n" % net)


def apply_tls(ss, get, fallback_sni):
    sec = ss.get("security") or "none"
    if sec in ("", "none", "0"):
        ss["security"] = "none"
        return
    tls = {"serverName": get("sni") or get("host") or fallback_sni or "",
           "fingerprint": get("fp") or "chrome"}
    for src, dst in (("pbk", "publicKey"), ("sid", "shortId"), ("spx", "spiderX")):
        if get(src):
            tls[dst] = get(src)
    if get("alpn"):
        tls["alpn"] = get("alpn").split(",")
    if str(get("allowInsecure") or get("insecure") or "").lower() in ("1", "true"):
        _note_insecure()
    ss["realitySettings" if sec == "reality" else "tlsSettings"] = tls


def _note_insecure():
    """Xray 26 убрал allowInsecure: с ним отвергается весь конфиг. Вместо
    него — pinSHA256 (отпечаток сертификата сервера) или настоящий сертификат."""
    sys.stderr.write("NOTE:allowInsecure пропущен — Xray 26 его не принимает; самоподписанному "
                     "сертификату нужен pinSHA256 в ссылке\n")


def _port_num(value, proto):
    """Порт из ссылки: только ASCII-цифры, 1–65535; пусто — 443. Иначе
    Xray получал порт 0 или 99999 (и отвергал весь конфиг), а «443» из
    не-ASCII цифр падал трассировкой."""
    if value in (None, ""):
        return 443
    if isinstance(value, float) and value.is_integer():     # vmess: "port": 443.0
        value = int(value)
    value = str(value)
    if not re.fullmatch(r"[0-9]{1,9}", value) or not 1 <= int(value) <= 65535:
        die("%s: неверный порт: %s" % (proto, value))
    return int(value)


def _url_port(u, proto):
    """Порт из urlparse; «:0», «:99999» и не-цифры — ошибка, а не 443."""
    _, sep, port = u.netloc.rpartition("@")[2].rpartition(":")
    if not sep or "]" in port:
        return 443
    return _port_num(port, proto)


def tag_for(host):
    return "proxy_" + re.sub(r"[^A-Za-z0-9]", "_", host or "server")


def _hy2_outbound(link):
    """hysteria2:// → outbound Xray 26+: protocol hysteria (version 2) и
    транспорт hysteria; пароль — auth, TLS — SNI, ALPN (h3), ECH, pinSHA256.
    Обфускация salamander — finalmask, порт-хоппинг (mport) не переносится."""
    u = urllib.parse.urlparse(link)
    qs = urllib.parse.parse_qs(u.query)

    def get(k):
        return qs[k][0] if qs.get(k) else None
    host = u.hostname or ""
    auth = urllib.parse.unquote(u.username or "")
    if u.password is not None:
        auth += ":" + urllib.parse.unquote(u.password)
    if not host or not auth:
        die("hysteria2: в ссылке нет адреса или пароля")
    port = _url_port(u, "hysteria2")
    tls = {"serverName": get("sni") or host, "alpn": (get("alpn") or "h3").split(",")}
    if get("pinSHA256"):
        tls["pinnedPeerCertSha256"] = get("pinSHA256")
    if get("ech"):
        tls["echConfigList"] = get("ech")
    if str(get("insecure") or "").lower() in ("1", "true") and not get("pinSHA256"):
        _note_insecure()
    ss = {"network": "hysteria", "hysteriaSettings": {"version": 2, "auth": auth},
          "security": "tls", "tlsSettings": tls}
    if get("obfs"):
        if get("obfs") != "salamander":
            sys.stderr.write("UNSUPPORTED:obfs=%s\n" % get("obfs"))
            die("hysteria2: обфускация %s не поддерживается" % get("obfs"))
        if not get("obfs-password"):
            die("hysteria2: для salamander нужен obfs-password")
        ss["finalmask"] = {"udp": [{"type": "salamander", "settings": {"password": get("obfs-password")}}]}
    if get("mport"):
        sys.stderr.write("NOTE:порт-хоппинг (mport=%s) не переносится — только порт %d\n" % (get("mport"), port))
    return {"protocol": "hysteria", "tag": tag_for(host),
            "settings": {"version": 2, "address": host, "port": port}, "streamSettings": ss}


def _ss_outbound(link):
    """ss:// — SIP002 (метод:пароль в base64 или открыто @хост:порт) и
    старый формат (всё в base64). Плагины (obfs, v2ray-plugin) не переносятся."""
    body = link[5:].split("#", 1)[0]
    body, _, query = body.partition("?")
    body = body.rstrip("/")

    def b64(text):
        text = urllib.parse.unquote(text)
        try:
            return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None
    if "@" in body:
        userinfo, hostport = body.rsplit("@", 1)
        dec = b64(userinfo)
        cred = dec if dec and ":" in dec else urllib.parse.unquote(userinfo)
    else:
        dec = b64(body) or ""
        if "@" not in dec:
            die("ss: ссылка не разобрана")
        cred, hostport = dec.rsplit("@", 1)
    method, _, password = cred.partition(":")
    host, _, port = hostport.rpartition(":")
    host = host.strip("[]")
    if not (method and password and host and port):
        die("ss: нужен метод, пароль, адрес и порт")
    port = _port_num(port, "ss")
    if "plugin=" in query:
        sys.stderr.write("UNSUPPORTED:ss-plugin\n")
        die("ss: плагины (obfs, v2ray-plugin) не поддерживаются")
    return {"protocol": "shadowsocks", "tag": tag_for(host),
            "settings": {"servers": [{"address": host, "port": port, "method": method, "password": password}]}}


def cmd_xray_link(link):
    link = link.strip()
    if link.startswith("vless://"):
        u = urllib.parse.urlparse(link)
        qs = urllib.parse.parse_qs(u.query)

        def get(k):
            return qs[k][0] if qs.get(k) else None
        host = u.hostname or ""
        ob = {"protocol": "vless", "tag": tag_for(host),
              "settings": {"vnext": [{"address": host, "port": _url_port(u, "vless"),
                                      "users": [{"id": urllib.parse.unquote(u.username or ""),
                                                 "encryption": get("encryption") or "none",
                                                 "flow": get("flow") or ""}]}]},
              "streamSettings": {"network": get("type") or "tcp",
                                 "security": get("security") or "none"}}
    elif link.startswith("vmess://"):
        raw = link[8:]
        data = json.loads(base64.b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8"))
        if not isinstance(data, dict):
            die("vmess: внутри ссылки ожидался JSON-объект")

        def get(k):
            v = data.get(k)
            return str(v) if v not in (None, "") else None
        host = str(data.get("add") or "")
        ob = {"protocol": "vmess", "tag": tag_for(host),
              "settings": {"vnext": [{"address": host, "port": _port_num(data.get("port"), "vmess"),
                                      "users": [{"id": data.get("id"),
                                                 "alterId": int(data.get("aid") or 0),
                                                 "security": data.get("scy") or "auto"}]}]},
              "streamSettings": {"network": data.get("net") or "tcp",
                                 "security": data.get("tls") or "none"}}
    elif link.startswith("trojan://"):
        u = urllib.parse.urlparse(link)
        qs = urllib.parse.parse_qs(u.query)

        def get(k):
            return qs[k][0] if qs.get(k) else None
        host = u.hostname or ""
        # Пароль trojan — вся часть до «@»: «p:a@host» — это пароль «p:a»
        password = urllib.parse.unquote(u.username or "")
        if u.password is not None:
            password += ":" + urllib.parse.unquote(u.password)
        ob = {"protocol": "trojan", "tag": tag_for(host),
              "settings": {"servers": [{"address": host, "port": _url_port(u, "trojan"),
                                        "password": password}]},
              "streamSettings": {"network": get("type") or "tcp", "security": get("security") or "tls"}}
    elif link.startswith("ss://"):
        print(json.dumps(_ss_outbound(link)))
        return
    elif link.startswith(("hysteria2://", "hy2://")):
        print(json.dumps(_hy2_outbound(link)))
        return
    else:
        die("поддерживаются vless://, vmess://, trojan://, ss://, hysteria2://")
    apply_transport(ob["streamSettings"], ob["streamSettings"]["network"], get)
    apply_tls(ob["streamSettings"], get, host)
    print(json.dumps(ob))


def cmd_xray_default(path):
    """Начальный конфиг. listen 127.0.0.1 у socks обязателен: иначе на сервере
    появляется открытый SOCKS5-релей без авторизации."""
    jsave(path, {
        "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                      "tag": "socks-in", "settings": {"auth": "noauth", "udp": True},
                      "sniffing": SNIFF}],
        "outbounds": [{"protocol": "freedom", "tag": "direct"}],
        "routing": {"domainStrategy": "AsIs", "rules": []},
    })


def cmd_xray_add(path):
    ob = json.loads(sys.stdin.read())
    conf = jload(path)
    outs = conf.setdefault("outbounds", [])
    if any(o.get("tag") == ob.get("tag") for o in outs):
        die("outbound %s уже есть" % ob.get("tag"), 3)
    at = next((i for i, o in enumerate(outs) if o.get("protocol") == "freedom"), len(outs))
    outs.insert(at, ob)
    # Новая ссылка становится выходом по умолчанию, если балансировщик не
    # включён; клиенты со своим выходом остаются на нём
    for r in conf.get("routing", {}).get("rules", []):
        if set(r.get("inboundTag") or []) & KNOWN_IN and not r.get("balancerTag") \
                and r.get("ruleTag") != XRAY_CLIENT_RULE:
            r["outboundTag"] = ob["tag"]
    jsave(path, conf)


def cmd_xray_del(path, *tags):
    conf = jload(path)
    conf["outbounds"] = [o for o in conf.get("outbounds", []) if o.get("tag") not in tags]
    jsave(path, conf)


XRAY_RESTORE_KEEP = ("outbounds", "routing", "observatory")


def _shown(v, n=40):
    """Имя из чужого файла — для вывода в терминал и бот: без управляющих
    символов и обратной косой (warn печатает через echo -e)."""
    return re.sub(r"[\x00-\x1f\x7f\\]", "?", str(v))[:n]


def cmd_xray_restore_clean(path):
    """Конфиг Xray из бэкапа (бэкап мог прийти чужой, Xray работает от root):
    остаются выходы, маршрутизация и observatory — то, что пишет сама Тулза.
    Входы пересоберёт xray-prepare (SOCKS только на 127.0.0.1); api, stats,
    reverse, log и прочие разделы, правила чужих входов и правила на
    несуществующие выходы — убираются. Правила своего входа tun с чужим тегом
    переводятся на tun-in: входов в конфиге уже нет, и xray-prepare их бы не
    узнал. Кривые записи (не объект, тег — не строка) — тоже убираются, а не
    роняют разбор всего конфига. Печатает, что убрано."""
    conf = jload(path)
    if not isinstance(conf, dict):
        die("не объект JSON")
    is_tag = lambda v: isinstance(v, str) and v != ""          # noqa: E731
    as_list = lambda v: v if isinstance(v, list) else []       # noqa: E731
    outs = [o for o in as_list(conf.get("outbounds"))
            if isinstance(o, dict) and (o.get("tag") is None or is_tag(o.get("tag")))]
    tags = {o["tag"] for o in outs if is_tag(o.get("tag"))}
    if not any(is_tag(o.get("tag")) and o.get("protocol") not in SKIP_PROTO for o in outs):
        die("нет выходов")
    inbounds = [i for i in as_list(conf.get("inbounds")) if isinstance(i, dict)]
    tun_tags = {i["tag"] for i in inbounds if i.get("protocol") == "tun" and is_tag(i.get("tag"))}
    known = KNOWN_IN | tun_tags
    routing = conf.get("routing") if isinstance(conf.get("routing"), dict) else {}
    balancers = [b for b in as_list(routing.get("balancers")) if isinstance(b, dict) and is_tag(b.get("tag"))]
    btags = {b["tag"] for b in balancers}
    rules, dropped_rules = [], 0
    for r in as_list(routing.get("rules")):
        inb = r.get("inboundTag") if isinstance(r, dict) else None
        ot = r.get("outboundTag") if isinstance(r, dict) else None
        bt = r.get("balancerTag") if isinstance(r, dict) else None
        if (not isinstance(r, dict)
                or (inb and not (isinstance(inb, list) and all(is_tag(t) for t in inb) and set(inb) & known))
                or (ot and not (is_tag(ot) and ot in tags))
                or (bt and not (is_tag(bt) and bt in btags))):
            dropped_rules += 1
            continue
        if inb:
            r["inboundTag"] = list(dict.fromkeys("tun-in" if t in tun_tags else t for t in inb))
        rules.append(r)
    clean = {"inbounds": [], "outbounds": outs,
             "routing": {"domainStrategy": routing.get("domainStrategy") if is_tag(routing.get("domainStrategy"))
                         else "AsIs", "rules": rules}}
    if balancers:
        clean["routing"]["balancers"] = balancers
    if isinstance(conf.get("observatory"), dict):
        clean["observatory"] = conf["observatory"]
    foreign = [_shown(i.get("tag") or i.get("protocol") or "?") for i in inbounds
               if not (is_tag(i.get("tag")) and i["tag"] in KNOWN_IN) and i.get("protocol") != "tun"]
    gone = ["входы: " + ", ".join(foreign)] if foreign else []
    gone += sorted(_shown(k) for k in conf if k not in XRAY_RESTORE_KEEP + ("inbounds",))
    if dropped_rules:
        gone.append("правил: %d" % dropped_rules)
    jsave(path, clean)
    print("; ".join(gone))


def cmd_xray_tags(path):
    for t in proxy_tags(jload(path)):
        print(t)


def probe_conf(outbound):
    return {"log": {"loglevel": "none"},
            "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                          "tag": "probe-in", "settings": {"auth": "noauth"}}],
            "outbounds": [outbound, {"protocol": "freedom", "tag": "direct"}]}


def cmd_xray_probe(out):
    """Конфиг для `xray run -test` из одного outbound (stdin)."""
    jsave(out, probe_conf(json.loads(sys.stdin.read())))


def cmd_xray_probe_tag(path, tag, out):
    ob = next((o for o in jload(path).get("outbounds", []) if o.get("tag") == tag), None)
    if ob is None:
        die("нет outbound %s" % tag, 2)
    jsave(out, probe_conf(ob))


def cmd_xray_test_copy(src, dst):
    """Копия конфига для `xray run -test`. Проверка с inbound tun создаёт
    устройство, а xray0 занят работающим Xray («device or resource busy») —
    у копии tun получает своё имя и адрес."""
    conf = jload(src)
    for i, ib in enumerate(x for x in conf.get("inbounds") or [] if x.get("protocol") == "tun"):
        st = ib.setdefault("settings", {})
        st["name"] = "xrt" + secrets.token_hex(3)
        st["address"] = ["198.18.%d.1/30" % (250 + i % 4)]
    jsave(dst, conf)


def cmd_xray_tun_probe(out):
    jsave(out, {"log": {"loglevel": "none"},
                "inbounds": [{"protocol": "tun", "tag": "tun-probe",
                              "settings": {"mtu": 1500, "stack": "gvisor",
                                           "address": ["172.16.250.1/30"]}}],
                "outbounds": [{"protocol": "freedom", "tag": "direct"}]})


def cmd_xray_balancer(path, strategy):
    if strategy not in ("random", "roundRobin", "leastPing", "leastLoad", "off"):
        die("стратегия: random|roundRobin|leastPing|leastLoad|off")
    conf = jload(path)
    tags = proxy_tags(conf)
    routing = conf.setdefault("routing", {})
    rules = routing.setdefault("rules", [])
    rule = next((r for r in rules if r.get("balancerTag") == "balancer"), None) or _xray_main_rule(rules)
    if strategy == "off":
        routing.pop("balancers", None)
        conf.pop("observatory", None)
        for r in rules:
            if r.pop("balancerTag", None) and tags:
                r["outboundTag"] = tags[0]
    else:
        if len(tags) < 2:
            die("нужно минимум 2 proxy-outbound")
        routing["balancers"] = [{"tag": "balancer", "selector": tags,
                                 "strategy": {"type": strategy}}]
        if rule is None:
            rule = {"type": "field", "inboundTag": ["socks-in"]}
            rules.append(rule)
        rule.pop("outboundTag", None)
        rule["balancerTag"] = "balancer"
        # leastPing/leastLoad выбирают по замерам observatory
        if strategy in ("leastPing", "leastLoad"):
            conf["observatory"] = {"subjectSelector": tags,
                                   "probeUrl": "https://www.google.com/generate_204",
                                   "probeInterval": "1m"}
        else:
            conf.pop("observatory", None)
    jsave(path, conf)


def cmd_xray_balancer_get(path):
    b = jload(path).get("routing", {}).get("balancers") or []
    print(b[0].get("strategy", {}).get("type", "random") if b else "off")


def cmd_xray_ru(path, mode):
    """РФ-сайты напрямую: .ru/.su/.рф, «только из РФ» и РФ-IP идут в direct.
    Правила встают над первым правилом, ведущим в туннель, — блокировки выше
    остаются выше."""
    conf = jload(path)
    routing = conf.setdefault("routing", {})
    rules = [r for r in routing.get("rules", []) if r.get("ruleTag") != "ru-direct"]
    if mode == "on":
        outs = conf.setdefault("outbounds", [])
        if not any(o.get("tag") == "direct" for o in outs):
            outs.append({"protocol": "freedom", "tag": "direct"})
        proxy = set(proxy_tags(conf))
        at = next((i for i, r in enumerate(rules)
                   if r.get("balancerTag") or r.get("outboundTag") in proxy
                   or r.get("outboundTag") == "proxy"), len(rules))
        rules[at:at] = [
            {"type": "field", "ruleTag": "ru-direct", "outboundTag": "direct",
             "domain": ["domain:ru", "domain:su", "domain:xn--p1ai",
                        "ext:geosite_RU.dat:ru-available-only-inside"]},
            {"type": "field", "ruleTag": "ru-direct", "outboundTag": "direct",
             "ip": ["ext:geoip_RU.dat:ru"]},
        ]
    routing["rules"] = rules
    jsave(path, conf)


XRAY_CLIENT_RULE = "client-out"


def _xray_main_rule(rules):
    """Правило, ведущее весь вход туннеля в выход по умолчанию или балансировщик."""
    return next((r for r in rules if set(r.get("inboundTag") or []) & KNOWN_IN
                 and r.get("ruleTag") != XRAY_CLIENT_RULE), None)


def cmd_xray_main(path, tag):
    """Выход по умолчанию для клиентов без своего выхода; балансировщик выключается."""
    conf = jload(path)
    if tag not in proxy_tags(conf):
        die("выхода %s нет" % tag, 2)
    routing = conf.setdefault("routing", {})
    rules = routing.setdefault("rules", [])
    routing.pop("balancers", None)
    conf.pop("observatory", None)
    rule = _xray_main_rule(rules)
    if rule is None:
        rule = {"type": "field", "inboundTag": ["socks-in"]}
        rules.append(rule)
    rule.pop("balancerTag", None)
    rule["outboundTag"] = tag
    jsave(path, conf)


def cmd_xray_main_get(path):
    rule = _xray_main_rule(jload(path).get("routing", {}).get("rules", []))
    print("balancer" if rule and rule.get("balancerTag") else (rule or {}).get("outboundTag", ""))


def cmd_xray_prepare(path, mode, peers=""):
    """Привести конфиг к режиму входа: native (inbound tun в самом Xray) или
    tun2socks (только SOCKS на 127.0.0.1:10808, xray0 поднимает tun2socks).
    Заодно чинит висячие ссылки на удалённые outbounds и балансировщик —
    с ними Xray отвергает конфиг целиком.

    peers — список клиентов Xray («IP» или «IP|выход»): клиентам со своим
    выходом — правила по адресу (source) перед общим правилом. Только для
    native: inbound tun видит адрес клиента (перед xray0 нет NAT), а через
    tun2socks все соединения приходят с 127.0.0.1."""
    conf = jload(path)
    conf.setdefault("routing", {})["rules"] = [r for r in conf["routing"].get("rules") or []
                                               if r.get("ruleTag") != XRAY_CLIENT_RULE]
    inb = [i for i in conf.get("inbounds") or []
           if not (i.get("tag") == "xray0" and i.get("protocol") == "dokodemo-door")]
    socks = next((i for i in inb if i.get("tag") == "socks-in"), None)
    if socks is None:
        socks = {"protocol": "socks", "tag": "socks-in",
                 "settings": {"auth": "noauth", "udp": True}, "sniffing": SNIFF}
        inb.append(socks)
    socks["listen"] = "127.0.0.1"
    socks["port"] = socks.get("port") or 10808
    tun = next((i for i in inb if i.get("protocol") == "tun"), None)
    # Тег входа tun — всегда свой: с чужим («tun» из правленного руками или
    # восстановленного конфига) общее правило переставало узнаваться, и
    # каждый проход дописывал новое, а старое продолжало вести в прежний выход
    known = set(KNOWN_IN)
    if tun is not None and tun.get("tag"):
        known.add(tun["tag"])
    if mode == "native":
        if tun is None:
            tun = {"protocol": "tun", "tag": "tun-in",
                   "settings": {"mtu": 1200, "stack": "gvisor", "address": ["172.16.250.1/30"]},
                   "sniffing": SNIFF}
            inb.insert(0, tun)
        tun["tag"] = "tun-in"
        want = tun["tag"]
    else:
        inb = [i for i in inb if i.get("protocol") != "tun"]
        want = "socks-in"
    conf["inbounds"] = inb

    routing = conf.setdefault("routing", {})
    routing.setdefault("domainStrategy", "AsIs")
    rules = routing.setdefault("rules", [])
    touched = False
    for r in rules:
        tags = r.get("inboundTag")
        if isinstance(tags, list) and any(t in known for t in tags):
            r["inboundTag"] = [want]
            touched = True
    ptags = proxy_tags(conf)
    if not touched:
        rules.append({"type": "field", "inboundTag": [want],
                      "outboundTag": ptags[0] if ptags else "proxy"})

    existing = {o.get("tag") for o in conf.get("outbounds", []) if o.get("tag")}
    balancers = routing.get("balancers") or []
    for b in balancers:
        b["selector"] = [t for t in (b.get("selector") or []) if t in existing]
    # Балансировать между одним выходом нечего
    balancers = [b for b in balancers if len(b["selector"]) >= 2]
    if balancers:
        routing["balancers"] = balancers
    else:
        routing.pop("balancers", None)
    obs = conf.get("observatory")
    if obs and balancers:
        obs["subjectSelector"] = [t for t in obs.get("subjectSelector") or [] if t in existing]
    elif obs:
        conf.pop("observatory")
    btags = {b.get("tag") for b in balancers}
    for r in rules:
        if r.get("balancerTag") and r["balancerTag"] not in btags:
            r.pop("balancerTag")
        ot = r.get("outboundTag")
        if not r.get("balancerTag") and (not ot or ot not in existing):
            if ptags:
                r["outboundTag"] = ptags[0]
            else:
                r.pop("outboundTag", None)
    rules = [r for r in rules if r.get("outboundTag") or r.get("balancerTag")]
    lst = _peers_list(peers) if peers and mode == "native" else None
    if lst:
        by_tag = {}
        for ip, tag in lst.items():
            if tag in existing and tag in ptags:
                by_tag.setdefault(tag, []).append(ip)
        main = _xray_main_rule(rules)
        at = rules.index(main) if main in rules else len(rules)
        rules[at:at] = [{"type": "field", "ruleTag": XRAY_CLIENT_RULE, "inboundTag": [want],
                         "source": sorted(ips, key=lambda x: [int(p) for p in x.split(".")] if x.count(".") == 3 else [0]),
                         "outboundTag": tag} for tag, ips in by_tag.items()]
    routing["rules"] = rules
    jsave(path, conf)


# ════════════════════════ DPI-тест ════════════════════════
def pcap_payloads(path):
    out = []
    with open(path, "rb") as f:
        if len(f.read(24)) < 24:
            return out
        while True:
            ph = f.read(16)
            if len(ph) < 16:
                break
            pkt = f.read(struct.unpack("<I", ph[8:12])[0])
            if len(pkt) < 42 or struct.unpack(">H", pkt[12:14])[0] != 0x0800:
                continue
            udp = 14 + (pkt[14] & 0x0F) * 4
            if udp + 8 > len(pkt):
                continue
            ln = struct.unpack(">H", pkt[udp + 4:udp + 6])[0]
            p = pkt[udp + 8:udp + ln]
            if len(p) >= 10:
                out.append(p)
    return out


def detect(p):
    for m in (b"REGISTER", b"INVITE", b"OPTIONS", b"SIP/2.0"):
        if p.startswith(m):
            return "sip", "SIP %s (%dB)" % (m.decode(), len(p))
    if p[0] == 0x16 and p[1:3] in (b"\xfe\xfd", b"\xfe\xff"):
        return "dtls", "DTLS handshake (%dB)" % len(p)
    if p.startswith(b"M-SEARCH"):
        return "ssdp", "SSDP M-SEARCH (%dB)" % len(p)
    if len(p) >= 20 and p[4:8] == b"\x21\x12\xa4\x42":
        mt = struct.unpack(">H", p[0:2])[0]
        if mt in (0x0001, 0x000A):
            kind = "TURN Allocate" if mt == 0x000A else "STUN Binding"
            ml = struct.unpack(">H", p[2:4])[0]
            if 20 + ml < len(p) and p[20 + ml] == 0x16:
                return "webrtc", "WebRTC: %s + DTLS (%dB)" % (kind, len(p))
            return "stun", "%s (%dB)" % (kind, len(p))
    if len(p) == 48 and p[0] == 0x23 and p[12:16] == b"INIT":
        return "ntp", "NTP client (%dB)" % len(p)
    if len(p) >= 13 and (p[2] >> 7) == 0 and ((p[2] >> 3) & 0xF) == 0 \
            and 1 <= struct.unpack(">H", p[4:6])[0] <= 10 and 1 <= p[12] <= 63:
        return "dns", "DNS query (%dB)" % len(p)
    fb = p[0]
    if (fb >> 6) == 3 and len(p) >= 7 and p[1:5].hex() in ("00000001", "6b3343cf") and 1 <= p[5] <= 20:
        return "quic", "QUIC Initial (%dB)" % len(p)
    # Узко по длинам генератора: 0x80 в первом байте бывает и у данных AWG
    if len(p) in (172, 108) and p[0] == 0x80 and (p[1] & 0x7F) in (0, 8, 96):
        return "rtp", "RTP pt=%d (%dB)" % (p[1] & 0x7F, len(p))
    return None, None


def cmd_pcap_analyze(path):
    payloads = pcap_payloads(path)
    if not payloads:
        print("VERDICT|EMPTY|Пакетов не захвачено")
        return
    found, other = [], 0
    for p in payloads:
        t, d = detect(p)
        if t:
            found.append((t, d))
        else:
            other += 1
    print("INFO|Захвачено пакетов: %d" % len(payloads))
    seen = []
    for t, d in found:
        if t not in seen:
            seen.append(t)
            print("OK|" + d)
    if other:
        print("INFO|Прочих пакетов AWG: %d (не распознаются как WireGuard)" % other)
    if found:
        print("VERDICT|PASS|Цепочка мимикрии: %d пакет(ов) — %s" % (len(found), ", ".join(seen)))
    else:
        print("VERDICT|OK|Обфускация работает; пакеты мимикрии прошли до начала захвата")


# ════════════════════════ машинный API ════════════════════════
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _typed(val, typ):
    """Значение по типу ключа: s строка, n число, b да/нет, j JSON, f файл."""
    if typ == "n":
        try:
            return int(val)
        except ValueError:
            try:
                return float(val)
            except ValueError:
                return None
    if typ == "b":
        return val.strip().lower() in ("1", "true", "yes", "on", "y")
    if typ == "j":
        return json.loads(val) if val.strip() else None
    if typ == "f":
        try:
            return ANSI.sub("", read(val))
        except OSError:
            return ""
    return val


def _stdin_lines():
    """Строки stdin по \\n. splitlines() делил бы и по \\r, \\x1c-\\x1e, U+2028 —
    и свободный текст (комментарий, команда задачи) распадался на две строки."""
    return [l[:-1] if l.endswith("\r") else l for l in sys.stdin.read().split("\n")]


def _split_key(key):
    name, _, typ = key.partition(":")
    return name, typ or "s"


def cmd_json_kv():
    """Строки «ключ[:тип]<TAB>значение» → объект; точки в ключе — вложенность."""
    out = {}
    for line in _stdin_lines():
        if "\t" not in line:
            continue
        key, val = line.split("\t", 1)
        name, typ = _split_key(key)
        cur = out
        parts = name.split(".")
        for part in parts[:-1]:
            cur = cur.setdefault(part, {})
        cur[parts[-1]] = _typed(val, typ)
    print(json.dumps(out, ensure_ascii=False))


def cmd_json_rows(*cols):
    """Строки TSV → список объектов по колонкам «имя[:тип]»."""
    spec = [_split_key(c) for c in cols]
    rows = []
    for line in _stdin_lines():
        if not line:
            continue
        vals = line.split("\t")
        vals += [""] * (len(spec) - len(vals))
        rows.append({name: _typed(v, typ) for (name, typ), v in zip(spec, vals)})
    print(json.dumps(rows, ensure_ascii=False))


def cmd_json_list():
    """Непустые строки stdin → JSON-массив строк."""
    print(json.dumps([l for l in _stdin_lines() if l], ensure_ascii=False))


def _peers_list(path):
    """peers.list туннеля → {ip: нода или ""}; None — файла нет."""
    try:
        text = read(path)
    except OSError:
        return None
    out = {}
    for line in text.splitlines():
        ip, _, node = line.strip().partition("|")
        if ip:
            out[ip] = node
    return out


def _first_ip(value):
    return value.split(",")[0].split("/")[0].strip()


def cmd_clients_json(conf, dump, client_dir, warp, xray, exits, db=""):
    """Клиенты awg0 со статистикой `awg show dump`, туннелями и трафиком за
    месяц и по лимиту — для бота."""
    _, peers = split_peers(read(conf))
    stats = {}
    try:
        for line in read(dump).splitlines()[1:]:
            f = line.split("\t")
            if len(f) >= 7:
                stats[f[0]] = f
    except OSError:
        pass
    traffic = Traffic(db) if db else None
    if traffic:
        traffic.apply({k: (int(f[5]), int(f[6])) for k, f in stats.items() if f[5].isdigit() and f[6].isdigit()})
    today = time.strftime("%Y-%m-%d")
    now = int(time.time())
    tunnels = {"warp": _peers_list(warp), "xray": _peers_list(xray), "exit": _peers_list(exits)}
    rows = []
    for b in peers:
        pub = peer_field(b, "PublicKey")
        if not pub:
            continue
        name = peer_name(b)
        orig = peer_meta(b, "orig_ips")
        ip = _first_ip(orig or peer_field(b, "AllowedIPs"))
        exp = peer_meta(b, "expires")
        s = stats.get(pub) or ["", "", "", "", "0", "0", "0"]
        hs = int(s[4]) if s[4].isdigit() else 0
        path = ""
        for suf in ("_awg3.conf", "_awg2.conf"):
            p = os.path.join(client_dir, name + suf)
            if name and os.path.isfile(p):
                path = p
                break
        row = {
            "name": name, "ip": ip, "pub": pub,
            "expires": int(exp) if exp.isdigit() else None, "blocked": bool(orig),
            "mimicry": peer_meta(b, "mimicry") or "none",
            "handshake": hs, "ago": now - hs if hs else None,
            "online": bool(hs) and now - hs < 180,
            "rx": int(s[5]) if s[5].isdigit() else 0, "tx": int(s[6]) if s[6].isdigit() else 0,
            "endpoint": "" if s[2] in ("", "(none)") else s[2], "file": path,
        }
        limit, period = parse_limit(peer_meta(b, "limit"))
        by = peer_meta(b, "blocked_by")
        row.update(limit=limit or None, period=period or None,
                   blocked_by=(by or "expire") if orig else None,
                   used=traffic.used(pub, period) if traffic and limit else None,
                   month=traffic.raw_used(pub, "month") if traffic else None,
                   today=sum((traffic.d["days"].get(today) or {}).get(pub) or [0, 0]) if traffic else None)
        for t, lst in tunnels.items():
            if lst is None:
                row[t] = None
            elif t == "exit":
                row[t] = (lst[ip] or "shared") if ip in lst else "off"
            else:
                row[t] = ip in lst
        # Свой выход Xray клиента (пусто — выход по умолчанию)
        row["xray_out"] = (tunnels["xray"] or {}).get(ip) or ""
        rows.append(row)
    print(json.dumps(rows, ensure_ascii=False))


def _job_info(jdir, active):
    try:
        meta = json.loads(read(os.path.join(jdir, "meta.json")))
    except (OSError, ValueError):
        meta = {"id": os.path.basename(jdir)}
    try:
        res = json.loads(read(os.path.join(jdir, "result.json")))
    except (OSError, ValueError):
        res = None
    if res is not None:
        meta["state"] = "done"
        meta.update({k: res.get(k) for k in ("ok", "rc", "data", "error")})
        try:
            meta["finished"] = int(os.path.getmtime(os.path.join(jdir, "result.json")))
        except OSError:
            pass
    else:
        meta["state"] = "running" if active == "1" else "lost"
    return meta


def cmd_api_job_status(jdir, offset, active):
    """Состояние задачи и новый кусок журнала с байта offset. Кусок режется
    по концу строки: следующий опрос продолжит с целой строки."""
    info = _job_info(jdir, active)
    try:
        off = max(0, int(offset))
    except ValueError:
        off = 0
    try:
        with open(os.path.join(jdir, "log"), "rb") as f:
            f.seek(off)
            chunk = f.read(256 * 1024)
    except OSError:
        chunk = b""
    if info["state"] == "running":
        cut = chunk.rfind(b"\n") + 1
        chunk = chunk[:cut]
    info["offset"] = off + len(chunk)
    info["log"] = ANSI.sub("", chunk.decode("utf-8", "replace"))
    print(json.dumps(info, ensure_ascii=False))


def cmd_api_jobs(jobs_dir, *active_ids):
    """Последние 20 задач, новые сверху; active_ids — задачи с живым юнитом."""
    try:
        ids = sorted(os.listdir(jobs_dir), reverse=True)[:20]
    except OSError:
        ids = []
    rows = []
    for i in ids:
        info = _job_info(os.path.join(jobs_dir, i), "1" if i in active_ids else "0")
        info.pop("data", None)
        rows.append(info)
    print(json.dumps(rows, ensure_ascii=False))


def cmd_tg_targets(conf, admins_json):
    """Кому слать уведомления от таймеров: токен, прокси бота и ID
    владельцев (ADMIN_ID, у старых ботов ADMIN_CHAT_ID) и приглашённых
    админов — построчно. Пустой вывод — бот не настроен."""
    vals = {}
    try:
        for line in read(conf).splitlines():
            k, sep, v = line.strip().partition("=")
            if sep and not k.startswith("#"):
                vals[k.strip().upper()] = v.strip().strip("\"'")
    except OSError:
        return
    ids = []
    for part in re.split(r"[,;\s]+", vals.get("ADMIN_ID") or vals.get("ADMIN_CHAT_ID", "")):
        if part.isdigit() and part not in ids:
            ids.append(part)
    try:
        for k in (json.loads(read(admins_json)).get("admins") or {}):
            if str(k).isdigit() and str(k) not in ids:
                ids.append(str(k))
    except (OSError, ValueError, AttributeError):
        pass
    token = vals.get("BOT_TOKEN", "")
    if token and ids:
        print("\n".join([token, vals.get("BOT_PROXY", "")] + ids))


def cmd_api_envelope(rc, data_file, log_file):
    try:
        raw = read(data_file).strip()
    except OSError:
        raw = ""
    try:
        data = json.loads(raw) if raw else None
    except ValueError:
        data = None
    try:
        log = ANSI.sub("", read(log_file))
    except OSError:
        log = ""
    log = "\n".join(line.rstrip() for line in log.splitlines()).strip("\n")
    error = ""
    if rc != "0":
        errs = [l.strip()[1:].strip() for l in log.splitlines() if l.strip().startswith("×")]
        error = errs[-1] if errs else (log.splitlines()[-1].strip() if log else "код %s" % rc)
    print(json.dumps({"ok": rc == "0", "rc": int(rc), "data": data, "log": log, "error": error},
                     ensure_ascii=False))


# ════════════════════════ архивы ════════════════════════
# ── Готовые сертификаты сервера ───────────────────────────
# Сертификаты, которые уже выпустили другие программы (Caddy, certbot,
# acme.sh, Marzban, 3x-ui, nginx), — Mini App может взять их, не трогая
# порт 80: продлевает их тот, кто выпустил. Подходит только публичный
# сертификат (не самоподписанный), с ключом от него, не истекающий в
# ближайшие сутки и выписанный на этот сервер — IP сервера или домен,
# который ведёт на него.
CERT_GLOBS = (
    ("Caddy", "var/lib/caddy/.local/share/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "root/.local/share/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "home/*/.local/share/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "var/lib/docker/volumes/*/_data/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "var/lib/docker/volumes/*/_data/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("certbot", "etc/letsencrypt/live/*/fullchain.pem", "{dir}/privkey.pem"),
    ("acme.sh", "root/.acme.sh/*/fullchain.cer", "{dir}/{dirname}.key"),
    ("Marzban", "var/lib/marzban/certs/*/fullchain.pem", "{dir}/key.pem"),
    ("Marzban", "var/lib/marzban/certs/fullchain.pem", "{dir}/key.pem"),
    ("3x-ui", "root/cert/*/fullchain.pem", "{dir}/privkey.pem"),
    ("3x-ui", "root/cert/fullchain.pem", "{dir}/privkey.pem"),
)
NGINX_GLOBS = ("etc/nginx/nginx.conf", "etc/nginx/conf.d/*.conf", "etc/nginx/sites-enabled/*")


def _openssl(*args, data=None):
    import subprocess
    try:
        r = subprocess.run(["openssl", *args], input=data, capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def _cert_candidates(root):
    import glob
    seen = set()
    for source, pat, key_tpl in CERT_GLOBS:
        for crt in sorted(glob.glob(os.path.join(root, pat))):
            d = os.path.dirname(crt)
            stem = os.path.basename(crt).rsplit(".", 1)[0]
            dirname = os.path.basename(d).removesuffix("_ecc")
            key = key_tpl.format(dir=d, stem=stem, dirname=dirname)
            if (crt, key) not in seen:
                seen.add((crt, key))
                yield source, crt, key
    # nginx: пары ssl_certificate / ssl_certificate_key в порядке появления
    for pat in NGINX_GLOBS:
        for conf in sorted(glob.glob(os.path.join(root, pat))):
            try:
                text = read(conf)
            except (OSError, UnicodeDecodeError):
                continue
            crt = None
            for m in re.finditer(r"^\s*(ssl_certificate(?:_key)?)\s+([^;\s]+)\s*;", text, re.M):
                path = m[2].strip("'\"")
                if not path.startswith("/") or "$" in path:
                    continue
                path = os.path.join(root, path.lstrip("/"))
                if m[1] == "ssl_certificate":
                    crt = path
                elif crt and (crt, path) not in seen:
                    seen.add((crt, path))
                    yield "nginx", crt, path
                    crt = None


def _cert_info(crt, key):
    """{names, ips, expires} публичного сертификата с подходящим ключом; иначе None."""
    try:
        if not (os.path.isfile(crt) and os.path.isfile(key)) or os.path.getsize(crt) > 1 << 20:
            return None
    except OSError:
        return None
    out = _openssl("x509", "-in", crt, "-noout", "-enddate", "-subject", "-issuer", "-ext", "subjectAltName",
                   "-nameopt", "RFC2253")
    if out is None:
        return None
    text = out.decode("utf-8", "replace")
    sub = re.search(r"^subject=(.*)$", text, re.M)
    iss = re.search(r"^issuer=(.*)$", text, re.M)
    if not sub or not iss or sub[1].strip() == iss[1].strip():
        return None                               # самоподписанный — Telegram не примет
    end = re.search(r"^notAfter=(.*)$", text, re.M)
    if not end:
        return None
    # «Dec  3 12:00:00 2026 GMT» — месяц по-английски при любой локали сервера
    m = re.match(r"([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})", end[1].strip())
    months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
    if not m or m[1] not in months:
        return None
    import calendar
    expires = calendar.timegm((int(m[6]), months.index(m[1]) + 1, int(m[2]), int(m[3]), int(m[4]), int(m[5]), 0, 0, 0))
    if expires < time.time() + 86400:
        return None
    pub_c = _openssl("x509", "-in", crt, "-noout", "-pubkey")
    pub_k = _openssl("pkey", "-in", key, "-pubout")
    if not pub_c or not pub_k or pub_c.strip() != pub_k.strip():
        return None                               # ключ не от этого сертификата
    names = re.findall(r"DNS:([^,\s]+)", text)
    ips = re.findall(r"IP Address:([0-9.]+)", text)
    return {"names": [n.lower() for n in names if not n.startswith("*.")], "ips": ips, "expires": expires}


def _resolves_to(name, ip):
    import socket
    try:
        return ip in {a[4][0] for a in socket.getaddrinfo(name, None, socket.AF_INET)}
    except (OSError, UnicodeError):
        return False


def cmd_cert_find(pub_ip, root="/", *exclude):
    """Готовые сертификаты для Mini App: строки «имя<TAB>источник<TAB>сертификат
    <TAB>ключ<TAB>до (unix)», свежие сверху; одно имя — один, самый долгий."""
    skip = tuple(os.path.realpath(e) for e in exclude if e)
    best = {}
    for source, crt, key in _cert_candidates(root):
        if skip and os.path.realpath(crt).startswith(skip):
            continue
        info = _cert_info(crt, key)
        if not info:
            continue
        name = pub_ip if pub_ip in info["ips"] else next(
            (n for n in info["names"] if _resolves_to(n, pub_ip)), "")
        if name and (name not in best or info["expires"] > best[name][4]):
            best[name] = (name, source, crt, key, info["expires"])
    for row in sorted(best.values(), key=lambda r: -r[4]):
        print("\t".join(map(str, row)))


# ── Список изменений ──────────────────────────────────────
CL_HEAD = re.compile(r"^##\s+(v\d+(?:\.\d+){1,3})\b\s*(.*)$")


def _ver_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:4])


# Модуль ядра: смена API udp_tunnel (struct socket → struct sock) пришла в
# 7.1.5, и апстрим выбирает вызов по номеру версии. Ядра дистрибутивов
# переносят её в старые версии частично: в Ubuntu 7.0.0-38 setup_udp_tunnel_sock
# уже берёт struct sock, а udp_tunnel_sock_release — ещё struct socket, и
# модуль не собирается. Для ядер < 7.1.5 вызов выбирается по заголовкам.
MOD_UDP_OLD = """#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 5)
#include <net/udp_tunnel.h>
#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)
#define udp_tunnel_sock_release(sk) udp_tunnel_sock_release(sk->sk_socket)
#endif"""
MOD_UDP_NEW = """#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 5)
#include <net/udp_tunnel.h>
/* awg2: перенос смены API в старые ядра — по заголовкам (compat/Kbuild.include) */
#ifndef COMPAT_UDP_TUNNEL_SETUP_SK
#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)
#endif
#ifndef COMPAT_UDP_TUNNEL_RELEASE_SK
#define udp_tunnel_sock_release(sk) udp_tunnel_sock_release(sk->sk_socket)
#endif
#endif"""
MOD_UDP_KBUILD = """
# awg2: смена API udp_tunnel, перенесённая в ядро дистрибутива до 7.1.5.
# Без запятых и скобок в шаблоне — для ifneq они разделители («.» — любой символ)
ifneq ($(shell grep -s "setup_udp_tunnel_sock.struct net .net. struct sock .sk" "$(srctree)/include/net/udp_tunnel.h"),)
ccflags-y += -DCOMPAT_UDP_TUNNEL_SETUP_SK
endif
ifneq ($(shell grep -s "udp_tunnel_sock_release.struct sock ." "$(srctree)/include/net/udp_tunnel.h"),)
ccflags-y += -DCOMPAT_UDP_TUNNEL_RELEASE_SK
endif
"""


def cmd_mod_compat_patch(src):
    """Правка исходников модуля перед сборкой (каталог src тега). Печатает
    patched | already | skip — skip, если в теге этого места нет (апстрим
    поправил сам или переписал): тогда исходник не трогаем."""
    compat, kbuild = os.path.join(src, "compat/compat.h"), os.path.join(src, "compat/Kbuild.include")
    if not (os.path.isfile(compat) and os.path.isfile(kbuild)):
        print("skip")
        return
    text = read(compat)
    if "COMPAT_UDP_TUNNEL_SETUP_SK" in text:
        print("already")
        return
    if MOD_UDP_OLD not in text:
        print("skip")
        return
    with open(compat, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text.replace(MOD_UDP_OLD, MOD_UDP_NEW, 1))
    with open(kbuild, "a", encoding="utf-8") as f:
        f.write(MOD_UDP_KBUILD)
    print("patched")


def cmd_changelog_json(current, available=None):
    """CHANGELOG.md из stdin → разделы для экрана «Обновление»: новее
    установленной версии (сверху самая новая, не больше десяти), а если
    новее нет — раздел текущей. Заголовок раздела: «## v1.1.1 — дата (бот 3.1.0)».
    available — версия к обновлению по свежему кэшу проверки (пусто — новее нет)."""
    sections, cur = [], None
    for line in sys.stdin.read().replace("\r", "").split("\n"):
        m = CL_HEAD.match(line)
        if m:
            cur = {"version": m[1], "title": m[2].strip(" —–-"), "lines": []}
            sections.append(cur)
        elif line.startswith("## "):
            cur = None
        elif cur is not None:
            cur["lines"].append(line)
    for s in sections:
        body = "\n".join(s.pop("lines")).strip()
        s["body"] = re.sub(r"(?:\n\s*-{3,}\s*)+$", "", body).strip()[:20000]
    now = _ver_tuple(current)
    newer = sorted((s for s in sections if _ver_tuple(s["version"]) > now),
                   key=lambda s: _ver_tuple(s["version"]), reverse=True)[:10]
    shown = newer or [s for s in sections if _ver_tuple(s["version"]) == now][:1]
    out = {"current": current, "newer": bool(newer), "sections": shown}
    if available is not None:
        out["available"] = available
    print(json.dumps(out, ensure_ascii=False))


def cmd_safe_untar(archive, dest):
    """Распаковать только обычные файлы и каталоги без выхода за dest:
    архив может прийти от пользователя (бэкап, загруженный в бота)."""
    import tarfile
    root = os.path.realpath(dest)
    os.makedirs(root, exist_ok=True)
    n = 0
    try:
        tar = tarfile.open(archive, "r:*")
    except (tarfile.TarError, OSError):
        die("это не архив tar.gz")
    with tar:
        for m in tar.getmembers():
            parts = [p for p in m.name.replace("\\", "/").split("/") if p not in ("", ".")]
            if not parts or ".." in parts or not (m.isfile() or m.isdir()):
                continue
            path = os.path.join(root, *parts)
            if m.isdir():
                os.makedirs(path, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(path), exist_ok=True)
            src = tar.extractfile(m)
            with open(path, "wb") as f:
                shutil.copyfileobj(src, f)
            os.chmod(path, 0o600)
            n += 1
    if not n:
        die("в архиве нет файлов")


def cmd_web_hash():
    """Пароль веб-панели (stdin) → scrypt-хеш в формате awgbot.web.hash_password."""
    import base64
    import hashlib
    pw = sys.stdin.read()
    if not pw:
        die("пустой пароль")
    salt = os.urandom(16)
    dk = hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)
    print("scrypt$%d$%d$%d$%s$%s" % (2 ** 14, 8, 1, base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))


COMMANDS = {
    "peers": cmd_peers, "meta-set": cmd_meta_set, "peer-del": cmd_peer_del,
    "peer-rename": cmd_peer_rename, "peers-clear": cmd_peers_clear,
    "params-replace": cmd_params_replace, "keepalive-set": cmd_keepalive_set, "params-check": cmd_params_check,
    "i-replace": cmd_i_replace,
    "expire-set": cmd_expire_set, "expire-clear": cmd_expire_clear,
    "expire-check": cmd_expire_check,
    "traffic-tick": cmd_traffic_tick, "traffic-daily": cmd_traffic_daily, "traffic-now": cmd_traffic_now,
    "traffic-rows": cmd_traffic_rows, "traffic-report": cmd_traffic_report,
    "limit-set": cmd_limit_set, "limit-reset": cmd_limit_reset, "size-parse": cmd_size_parse,
    "web-hash": cmd_web_hash,
    "net-of": cmd_net_of, "pick-net": cmd_pick_net, "net-overlaps": cmd_net_overlaps,
    "allowed-except": cmd_allowed_except,
    "rand-key": cmd_rand_key, "phobos-link": cmd_phobos_link, "exit-conf-fix": cmd_exit_conf_fix,
    "conf-hooks": cmd_conf_hooks, "mod-compat-patch": cmd_mod_compat_patch,
    "xray-link": cmd_xray_link, "xray-default": cmd_xray_default, "xray-add": cmd_xray_add,
    "xray-del": cmd_xray_del, "xray-tags": cmd_xray_tags, "xray-restore-clean": cmd_xray_restore_clean, "xray-probe": cmd_xray_probe,
    "xray-probe-tag": cmd_xray_probe_tag, "xray-tun-probe": cmd_xray_tun_probe,
    "xray-test-copy": cmd_xray_test_copy,
    "xray-balancer": cmd_xray_balancer, "xray-balancer-get": cmd_xray_balancer_get,
    "xray-main": cmd_xray_main, "xray-main-get": cmd_xray_main_get,
    "xray-ru": cmd_xray_ru, "xray-prepare": cmd_xray_prepare,
    "pcap-analyze": cmd_pcap_analyze, "safe-untar": cmd_safe_untar,
    "cert-find": cmd_cert_find, "changelog-json": cmd_changelog_json,
    "json-kv": cmd_json_kv, "json-rows": cmd_json_rows, "json-list": cmd_json_list,
    "clients-json": cmd_clients_json, "api-envelope": cmd_api_envelope,
    "api-job-status": cmd_api_job_status, "api-jobs": cmd_api_jobs,
    "tg-targets": cmd_tg_targets,
}

def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die("команда: " + ", ".join(sorted(COMMANDS)))
    # Байты не-UTF-8 из конфига (surrogateescape в read) печатаем как «?», а не падаем
    sys.stdout.reconfigure(errors="replace")
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except TypeError as e:
        die("неверные аргументы %s: %s" % (sys.argv[1], e))
    except (OSError, ValueError) as e:
        die("%s: %s" % (sys.argv[1], e))


if __name__ == "__main__":
    main()
__AWG2_PY_HELPER__

_BUILD_SUM=9235d926916ea39f
main "$@"
