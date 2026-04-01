#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# AmneziaWG Manager v4.0 — с генератором мимикрии
# Основан на AmneziaWG Architect domain pools
# ─────────────────────────────────────────────────────────────

# ── Цвета ──────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${R}Запускай от root${N}"; exit 1; }

# ── Хелперы ────────────────────────────────────────────────
ok()   { echo -e "${G}  ✓ $*${N}"; }
err()  { echo -e "${R}  ✗ $*${N}"; }
warn() { echo -e "${Y}  ⚠ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }
hdr()  { echo -e "\n${W}$*${N}"; }

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
LOG_FILE="/var/log/awg-manager.log"

# ── Логирование ────────────────────────────────────────────
_log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_err()   { _log "ERROR" "$@"; }
log_debug() { _log "DEBUG" "$@"; }

# ══════════════════════════════════════════════════════════
# ДОМЕННЫЕ ПУЛЫ ДЛЯ МИМИКРИИ (на основе AmneziaWG Architect)
# ══════════════════════════════════════════════════════════

# QUIC Initial пул (HTTP/3, CDN) — наиболее надёжный в 2026
QUIC_INITIAL_DOMAINS=(
  "yandex.net" "yastatic.net" "vk.com" "mycdn.me" "mail.ru"
  "ozon.ru" "wildberries.ru" "wbstatic.net" "sber.ru" "tbank.ru"
  "gosuslugi.ru" "gcore.com" "fastly.net" "cloudfront.net"
  "microsoft.com" "icloud.com" "github.com" "cdn.jsdelivr.net"
  "wikipedia.org" "dropbox.com" "steamstatic.com" "spotify.com"
  "akamaiedge.net" "msedge.net" "azureedge.net"
)

# QUIC 0-RTT пул (Early Data)
QUIC_0RTT_DOMAINS=(
  "yandex.net" "vk.com" "mail.ru" "ozon.ru" "wildberries.ru"
  "sber.ru" "tbank.ru" "gosuslugi.ru" "gcore.com" "fastly.net"
  "cloudfront.net" "microsoft.com" "github.com" "cdn.jsdelivr.net"
  "wikipedia.org" "spotify.com"
)

# TLS 1.3 Client Hello пул (HTTPS)
TLS_CLIENT_HELLO_DOMAINS=(
  "yandex.ru" "vk.com" "mail.ru" "ozon.ru" "wildberries.ru"
  "sberbank.ru" "tbank.ru" "gosuslugi.ru" "kaspersky.ru"
  "github.com" "gitlab.com" "stackoverflow.com" "microsoft.com"
  "apple.com" "amazon.com" "cloudflare.com" "google.com"
  "jetbrains.com" "docker.com" "ubuntu.com" "debian.org"
)

# DTLS пул (WebRTC/STUN)
DTLS_DOMAINS=(
  "stun.yandex.net" "stun.vk.com" "stun.mail.ru" "stun.sber.ru"
  "stun.stunprotocol.org" "stun.voipbuster.com" "meet.jit.si"
  "stun.services.mozilla.com" "stun.zoiper.com" "stun.counterpath.com"
  "stun.sipgate.net" "stun.ekiga.net" "stun.ideasip.com"
)

# SIP пул (VoIP)
SIP_DOMAINS=(
  "sip.beeline.ru" "sip.mts.ru" "sip.megafon.ru" "sip.rostelecom.ru"
  "sip.yandex.ru" "sip.vk.com" "sip.mail.ru" "sip.sipnet.ru"
  "sip.zadarma.com" "sip.iptel.org" "sip.linphone.org"
  "sip.antisip.com" "sip.voipbuster.com" "sip.3cx.com"
)

# ── Выбор случайного доступного домена из пула ────────────────────────
select_random_domain() {
  local profile="$1"
  local domains=()
  local available_domains=()

  case "$profile" in
    "quic_initial")   domains=("${QUIC_INITIAL_DOMAINS[@]}") ;;
    "quic_0rtt")      domains=("${QUIC_0RTT_DOMAINS[@]}") ;;
    "tls")            domains=("${TLS_CLIENT_HELLO_DOMAINS[@]}") ;;
    "dtls")           domains=("${DTLS_DOMAINS[@]}") ;;
    "sip")            domains=("${SIP_DOMAINS[@]}") ;;
    *)                domains=("${QUIC_INITIAL_DOMAINS[@]}") ;;
  esac

  # Проверяем доступность (быстрая проверка, не вылетает)
  for domain in "${domains[@]}"; do
    if ping -c 1 -W 1 "$domain" &>/dev/null 2>&1; then
      available_domains+=("$domain")
    fi
  done

  # Если есть доступные — выбираем случайный, иначе первый из списка
  if [[ ${#available_domains[@]} -gt 0 ]]; then
    echo "${available_domains[$((RANDOM % ${#available_domains[@]}))]}"
  else
    echo "${domains[0]}"
  fi
}

# ══════════════════════════════════════════════════════════
# FETCH I1 ЧЕРЕЗ API (с улучшенной обработкой)
# ══════════════════════════════════════════════════════════
fetch_i1_from_api() {
  local domain="$1"
  local api_url="https://junk.web2core.workers.dev/signature?domain=${domain}"
  local api_resp i1_val=""

  log_info "fetch_i1_from_api: domain=$domain"

  api_resp=$(curl -s --connect-timeout 10 "$api_url" 2>/dev/null) || api_resp=""
  log_debug "API raw response (first 200): ${api_resp:0:200}"

  if [[ -n "$api_resp" ]]; then
    # Python3 парсинг
    i1_val=$(echo "$api_resp" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('i1',''))" \
      2>/dev/null) || i1_val=""

    # fallback через jq
    if [[ -z "$i1_val" ]] && command -v jq &>/dev/null; then
      i1_val=$(echo "$api_resp" | jq -r '.i1 // empty' 2>/dev/null) || i1_val=""
    fi

    # fallback через grep
    if [[ -z "$i1_val" ]]; then
      i1_val=$(echo "$api_resp" | grep -oP '"i1"\s*:\s*"\K[^"]+' 2>/dev/null) || i1_val=""
    fi
  fi

  if [[ -z "$i1_val" ]]; then
    log_warn "API не вернул I1 для $domain"
    echo ""
    return 1
  fi

  # Нормализация I1
  i1_val=$(echo "$i1_val" | sed 's/^"//;s/"$//')

  # Исправляем <b0x на <b 0x если нужно
  if [[ "$i1_val" =~ ^\<b0x ]]; then
    i1_val="${i1_val/<b0x/<b 0x}"
    log_warn "I1: добавлен пробел после <b"
  fi

  # Проверка формата (должен быть CPS цепочкой)
  if [[ ! "$i1_val" =~ ^\<b\ 0x ]]; then
    log_err "I1 неверный формат для $domain"
    echo ""
    return 1
  fi

  log_info "I1 получен для $domain (длина: ${#i1_val})"
  echo "$i1_val"
  return 0
}

# ══════════════════════════════════════════════════════════
# ВЫБОР ПРОФИЛЯ МИМИКРИИ + ГЕНЕРАЦИЯ I1 (КРАСИВОЕ МЕНЮ)
# ══════════════════════════════════════════════════════════
choose_mimicry_profile() {
  I1=""
  MIMICRY_PROFILE=""
  MIMICRY_DOMAIN=""

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}        Профили мимикрии (AmneziaWG Architect)${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}1${N}  QUIC Initial (HTTP/3) — наиболее надёжный в 2026"
  echo -e "  ${G}2${N}  QUIC 0-RTT (Early Data) — быстрый старт"
  echo -e "  ${G}3${N}  TLS 1.3 Client Hello — HTTPS (наибольшая совместимость)"
  echo -e "  ${G}4${N}  DTLS 1.3 (WebRTC/STUN) — видеозвонки"
  echo -e "  ${G}5${N}  SIP (VoIP) — телефонные звонки"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${Y}6${N}  Случайный домен из любого пула"
  echo -e "  ${Y}7${N}  Ручной ввод домена (API запрос)"
  echo -e "  ${Y}8${N}  Без имитации (только обфускация)"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

  read -rp "$(echo -e "${C}  Выбор [1-8] (Enter = 1): ${N}")" PROFILE_CHOICE
  PROFILE_CHOICE=${PROFILE_CHOICE:-1}

  local domain=""
  case $PROFILE_CHOICE in
    1)
      MIMICRY_PROFILE="quic_initial"
      domain=$(select_random_domain "quic_initial")
      echo -e "${C}  → QUIC Initial, домен: ${W}$domain${N}"
      ;;
    2)
      MIMICRY_PROFILE="quic_0rtt"
      domain=$(select_random_domain "quic_0rtt")
      echo -e "${C}  → QUIC 0-RTT, домен: ${W}$domain${N}"
      ;;
    3)
      MIMICRY_PROFILE="tls"
      domain=$(select_random_domain "tls")
      echo -e "${C}  → TLS 1.3, домен: ${W}$domain${N}"
      ;;
    4)
      MIMICRY_PROFILE="dtls"
      domain=$(select_random_domain "dtls")
      echo -e "${C}  → DTLS, домен: ${W}$domain${N}"
      ;;
    5)
      MIMICRY_PROFILE="sip"
      domain=$(select_random_domain "sip")
      echo -e "${C}  → SIP, домен: ${W}$domain${N}"
      ;;
    6)
      local profiles=("quic_initial" "quic_0rtt" "tls" "dtls" "sip")
      MIMICRY_PROFILE="${profiles[$((RANDOM % ${#profiles[@]}))]}"
      domain=$(select_random_domain "$MIMICRY_PROFILE")
      echo -e "${C}  → Случайный профиль: ${W}$MIMICRY_PROFILE${N}, домен: ${W}$domain${N}"
      ;;
    7)
      read -rp "$(echo -e "${C}  Введите домен (например: cloudflare.com): ${N}")" domain
      if [[ -z "$domain" ]]; then
        warn "Домен не введён"
        return 1
      fi
      echo -e "${C}  → Ручной ввод: ${W}$domain${N}"
      ;;
    8)
      I1=""
      MIMICRY_PROFILE="none"
      echo -e "${G}  ✓ Без имитации${N}"
      return 0
      ;;
    *)
      MIMICRY_PROFILE="quic_initial"
      domain=$(select_random_domain "quic_initial")
      echo -e "${C}  → По умолчанию: QUIC Initial, домен: ${W}$domain${N}"
      ;;
  esac

  # Если выбран не "без имитации" и есть домен — запрашиваем I1
  if [[ "$PROFILE_CHOICE" != "8" ]] && [[ -n "$domain" ]]; then
    echo -e "${C}  → Запрос I1 для $domain...${N}"
    I1=$(fetch_i1_from_api "$domain")
    if [[ -z "$I1" ]]; then
      echo -e "${Y}  ⚠ Не удалось получить I1 для $domain${N}"
      echo -e "${Y}  → API недоступен или домен не поддерживает QUIC${N}"
      read -rp "$(echo -e "${C}  Продолжить без I1? [y/N]: ${N}")" CONTINUE
      if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        return 1
      fi
      I1=""
    else
      echo -e "${G}  ✓ I1 получен (длина: ${#I1} байт)${N}"
    fi
  fi
}

# ══════════════════════════════════════════════════════════
# ОСТАЛЬНЫЕ ФУНКЦИИ (статус, IP, генерация параметров и т.д.)
# ══════════════════════════════════════════════════════════

# ── Получение публичного IP ────────────────────────────────
get_public_ip() {
  local ip=""
  ip=$(curl -s --connect-timeout 5 -4 ifconfig.me 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
  ip=$(curl -s --connect-timeout 5 -4 api.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
  ip=$(curl -s --connect-timeout 5 -4 ipinfo.io/ip 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
  echo ""
}

# ── Генерация случайного числа ─────────────────────────────
rand_range() {
  local lo="$1" hi="$2"
  python3 -c "import random; print(random.randint($lo, $hi))"
}

# ── Поиск свободного IP ────────────────────────────────────
find_free_ip() {
  local base="$1"
  local srv_ip_oct=""
  if [[ -f "$SERVER_CONF" ]]; then
    local srv_addr
    srv_addr=$(grep "^Address" "$SERVER_CONF" | awk -F'=' '{print $2}' | tr -d ' ' | head -1)
    srv_ip_oct=$(echo "$srv_addr" | grep -oE '[0-9]+' | tail -1)
  fi

  for i in $(seq 2 254); do
    [[ "$i" == "1" ]] && continue
    [[ -n "$srv_ip_oct" && "$i" == "$srv_ip_oct" ]] && continue
    if ! grep -qF "${base}.${i}/32" "$SERVER_CONF" 2>/dev/null; then
      echo "${base}.${i}/32"
      return 0
    fi
  done
  return 1
}

# ── Статус сервера ─────────────────────────────────────────
get_status() {
  local ip port status clients
  ip=$(get_public_ip)
  [[ -z "$ip" ]] && ip="—"
  if ip link show awg0 &>/dev/null; then
    status="${G}активен${N}"
    port=$(awg show awg0 listen-port 2>/dev/null) || port="—"
    clients=$(awg show awg0 peers 2>/dev/null | wc -l | tr -d ' ') || clients="0"
  else
    status="${R}не активен${N}"
    port="—"; clients="—"
  fi
  echo -e "$ip|$port|$status|$clients"
}

# ── Шапка ──────────────────────────────────────────────────
show_header() {
  clear
  local s ip port st clients
  s=$(get_status)
  IFS='|' read -r ip port st clients <<< "$s"
  echo -e "${B}╔══════════════════════════════════════════════╗${N}"
  echo -e "${B}║${W}        AmneziaWG Manager v4.0                ${B}║${N}"
  echo -e "${B}║${C}     С генератором мимикрии (QUIC/TLS/DTLS)   ${B}║${N}"
  echo -e "${B}╚══════════════════════════════════════════════╝${N}"
  echo -e "${B}  IP сервера : ${W}$ip${N}"
  echo -e "${B}  Порт       : ${W}$port${N}"
  echo -e "${B}  Интерфейс  : $st${N}"
  echo -e "${B}  Клиентов   : ${W}$clients${N}"
}

# ── Меню ───────────────────────────────────────────────────
show_menu() {
  echo ""
  echo -e "  ${W}1)${N} Установка зависимостей и AmneziaWG"
  echo -e "  ${W}2)${N} Создать сервер + первый клиент (с мимикрией)"
  echo -e "  ${W}3)${N} Добавить клиента"
  echo -e "  ${W}4)${N} Показать клиентов"
  echo -e "  ${W}5)${N} Показать QR клиента"
  echo -e "  ${W}6)${N} Перезапустить awg0"
  echo -e "  ${W}7)${N} Удалить всё"
  echo -e "  ${W}8)${N} Проверить домены из пулов (ping)"
  echo -e "  ${W}0)${N} Выход"
  echo ""
  read -rp "$(echo -e "${C}  Выбор: ${N}")" CHOICE
}

# ══════════════════════════════════════════════════════════
# ВЫБОР DNS
# ══════════════════════════════════════════════════════════
choose_dns() {
  CLIENT_DNS=""
  hdr "DNS для клиента:"
  echo "  1) Cloudflare  — 1.1.1.1, 1.0.0.1"
  echo "  2) Google      — 8.8.8.8, 8.8.4.4"
  echo "  3) OpenDNS     — 208.67.222.222, 208.67.220.220"
  echo "  4) Яндекс DNS  — 77.88.8.8, 77.88.8.1"
  echo "  5) Вручную"
  read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = Cloudflare): ${N}")" DNS_CHOICE
  DNS_CHOICE=${DNS_CHOICE:-1}
  case $DNS_CHOICE in
    1) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
    2) CLIENT_DNS="8.8.8.8, 8.8.4.4" ;;
    3) CLIENT_DNS="208.67.222.222, 208.67.220.220" ;;
    4) CLIENT_DNS="77.88.8.8, 77.88.8.1" ;;
    5) read -rp "  DNS: " CLIENT_DNS ;;
    *) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
  esac
}

# ══════════════════════════════════════════════════════════
# ВЫБОР ВЕРСИИ AWG
# ══════════════════════════════════════════════════════════
choose_awg_version() {
  AWG_VERSION=""
  hdr "Версия протокола:"
  echo "  1) AWG 2.0  — S3/S4 + H1-H4 диапазоны + I1-I5 (рекомендуется)"
  echo "  2) AWG 1.5  — H1-H4 одиночные + I1-I5, без S3/S4"
  echo "  3) AWG 1.0  — Jc/Jmin/Jmax + S1/S2 + H1-H4 одиночные, без I1-I5"
  echo "  4) WireGuard — без обфускации"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = AWG 2.0): ${N}")" VER_CHOICE
  VER_CHOICE=${VER_CHOICE:-1}
  case $VER_CHOICE in
    1) AWG_VERSION="2.0" ;;
    2) AWG_VERSION="1.5" ;;
    3) AWG_VERSION="1.0" ;;
    4) AWG_VERSION="wg"  ;;
    *) AWG_VERSION="2.0" ;;
  esac
  ok "Версия: $AWG_VERSION"
}

# ══════════════════════════════════════════════════════════
# ГЕНЕРАЦИЯ AWG ПАРАМЕТРОВ (исправлена для AWG 2.0)
# ══════════════════════════════════════════════════════════
gen_awg_params() {
  local ver="$1"
  AWG_PARAMS_LINES=""

  [[ "$ver" == "wg" ]] && return 0

  local Jc Jmin Jmax S1 S2 S2_OFF Q
  Jc=$(rand_range 3 7)  # Jc 3-7 оптимальный баланс
  Jmin=64
  Jmax=$(rand_range 576 1024)
  S1=$(rand_range 10 39)
  S2_OFF=$(rand_range 1 63)
  [[ "$S2_OFF" -eq 56 ]] && S2_OFF=57
  S2=$(( S1 + S2_OFF ))
  [[ $S2 -gt 64 ]] && S2=64
  Q=1073741823

  if [[ "$ver" == "2.0" ]]; then
    # AWG 2.0: S3, S4 и диапазоны H1-H4
    local S3 S4
    local H1_START H1_END H1
    local H2_START H2_END H2
    local H3_START H3_END H3
    local H4_START H4_END H4

    S3=$(rand_range 5 34)
    S4=$(rand_range 1 16)

    # H1: квадрант 0 [0, Q-1]
    H1_START=$(rand_range 0 $((Q - 1)))
    H1_END=$(rand_range $((H1_START + 30000)) $((H1_START + 130000)))
    [[ $H1_END -gt $((Q - 1)) ]] && H1_END=$((Q - 1))
    H1="${H1_START}-${H1_END}"

    # H2: квадрант 1 [Q, 2Q-1]
    H2_START=$(rand_range $Q $((Q * 2 - 1)))
    H2_END=$(rand_range $((H2_START + 30000)) $((H2_START + 130000)))
    [[ $H2_END -gt $((Q * 2 - 1)) ]] && H2_END=$((Q * 2 - 1))
    H2="${H2_START}-${H2_END}"

    # H3: квадрант 2 [2Q, 3Q-1]
    H3_START=$(rand_range $((Q * 2)) $((Q * 3 - 1)))
    H3_END=$(rand_range $((H3_START + 30000)) $((H3_START + 130000)))
    [[ $H3_END -gt $((Q * 3 - 1)) ]] && H3_END=$((Q * 3 - 1))
    H3="${H3_START}-${H3_END}"

    # H4: квадрант 3 [3Q, 4Q-1]
    H4_START=$(rand_range $((Q * 3)) $((Q * 4 - 1)))
    H4_END=$(rand_range $((H4_START + 30000)) $((H4_START + 130000)))
    [[ $H4_END -gt $((Q * 4 - 1)) ]] && H4_END=$((Q * 4 - 1))
    H4="${H4_START}-${H4_END}"

    AWG_PARAMS_LINES="Jc = $Jc
Jmin = $Jmin
Jmax = $Jmax
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4"

  elif [[ "$ver" == "1.5" ]]; then
    # AWG 1.5: S1, S2, одиночные H1-H4
    local H1 H2 H3 H4
    H1=$(rand_range 0 $((Q - 1)))
    H2=$(rand_range $Q $((Q * 2 - 1)))
    H3=$(rand_range $((Q * 2)) $((Q * 3 - 1)))
    H4=$(rand_range $((Q * 3)) $((Q * 4 - 1)))
    AWG_PARAMS_LINES="Jc = $Jc
Jmin = $Jmin
Jmax = $Jmax
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4"

  else # AWG 1.0
    local H1 H2 H3 H4
    H1=$(rand_range 0 $((Q - 1)))
    H2=$(rand_range $Q $((Q * 2 - 1)))
    H3=$(rand_range $((Q * 2)) $((Q * 3 - 1)))
    H4=$(rand_range $((Q * 3)) $((Q * 4 - 1)))
    AWG_PARAMS_LINES="Jc = $Jc
Jmin = $Jmin
Jmax = $Jmax
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4"
  fi
}

# ══════════════════════════════════════════════════════════
# 1. УСТАНОВКА
# ══════════════════════════════════════════════════════════
do_install() {
  hdr "=== Обновление системы ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get upgrade -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

  hdr "=== Зависимости ==="
  apt-get install -y -q \
    software-properties-common \
    python3-launchpadlib \
    python3 \
    net-tools curl ufw iptables qrencode bc

  hdr "=== Kernel headers ==="
  apt-get install -y -q "linux-headers-$(uname -r)" 2>/dev/null || \
  apt-get install -y -q linux-headers-generic || \
  { err "не удалось установить linux-headers"; exit 1; }

  hdr "=== AmneziaWG (PPA) ==="
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -q
  apt-get install -y -q amneziawg amneziawg-tools

  if command -v awg &>/dev/null; then
    ok "amneziawg-tools: $(awg --version 2>/dev/null || echo 'установлен')"
  else
    err "awg не найден после установки"; exit 1
  fi

  hdr "=== Проверка модуля ==="
  if modprobe amneziawg 2>/dev/null; then
    ok "модуль загружен"
  else
    warn "Модуль не загрузился. Сделай reboot и запусти снова"
  fi

  hdr "=== IP Forwarding ==="
  sysctl -w net.ipv4.ip_forward=1 -q
  grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  hdr "=== NAT + FORWARD ==="
  local ext_if
  ext_if=$(ip route | awk '/default/ {print $5; exit}')
  [[ -z "$ext_if" ]] && { err "не найден default интерфейс"; exit 1; }
  ok "интерфейс: $ext_if"

  iptables -t nat -C POSTROUTING -o "$ext_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$ext_if" -j MASQUERADE
  iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i awg0 -j ACCEPT
  iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -o awg0 -j ACCEPT

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

  hdr "=== Папка конфигов ==="
  mkdir -p /etc/amnezia/amneziawg
  chmod 700 /etc/amnezia/amneziawg

  hdr "=== Firewall ==="
  local ssh_port
  read -rp "$(echo -e "${C}  SSH порт [22]: ${N}")" ssh_port
  ssh_port=${ssh_port:-22}
  ufw allow "${ssh_port}/tcp" comment "SSH" || true
  ufw allow 80/tcp  comment "HTTP"  || true
  ufw allow 443/tcp comment "HTTPS" || true
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw --force enable || true
  ufw status verbose

  echo ""
  ok "Установка завершена"
  info "Следующий шаг: пункт меню 2 — Создать сервер"
}

# ══════════════════════════════════════════════════════════
# 2. СОЗДАТЬ СЕРВЕР (с мимикрией)
# ══════════════════════════════════════════════════════════
do_gen() {
  log_info "do_gen: старт"
  command -v awg &>/dev/null || { err "awg не найден. Сначала пункт 1"; log_err "awg не найден"; return 1; }
  command -v python3 &>/dev/null || { err "python3 не найден. Сначала пункт 1"; log_err "python3 не найден"; return 1; }

  local bak_ts
  bak_ts="${SERVER_CONF}.bak.$(date +%s)"
  [[ -f "$SERVER_CONF" ]] && cp "$SERVER_CONF" "$bak_ts" && info "Backup: $bak_ts"

  choose_awg_version
  choose_dns

  # Выбор профиля мимикрии
  choose_mimicry_profile || return 1

  hdr "IP подсеть сервера:"
  echo "  1) 10.100.0.0/24"
  echo "  2) 10.101.0.0/24"
  echo "  3) 10.102.0.0/24"
  echo "  4) 10.103.0.0/24"
  echo "  5) Вручную"
  local CLIENT_ADDR="" SERVER_ADDR="" CLIENT_NET=""
  local ADDR_CHOICE
  read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = 10.100.0.0/24): ${N}")" ADDR_CHOICE
  ADDR_CHOICE=${ADDR_CHOICE:-1}
  case $ADDR_CHOICE in
    1) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
    2) CLIENT_ADDR="10.101.0.2/32"; SERVER_ADDR="10.101.0.1/24"; CLIENT_NET="10.101.0.0/24" ;;
    3) CLIENT_ADDR="10.102.0.2/32"; SERVER_ADDR="10.102.0.1/24"; CLIENT_NET="10.102.0.0/24" ;;
    4) CLIENT_ADDR="10.103.0.2/32"; SERVER_ADDR="10.103.0.1/24"; CLIENT_NET="10.103.0.0/24" ;;
    5)
      read -rp "  IP клиента (X.X.X.X/32): " CLIENT_ADDR
      read -rp "  IP сервера (X.X.X.X/24): " SERVER_ADDR
      read -rp "  Подсеть NAT (X.X.X.0/24): " CLIENT_NET
      ;;
    *) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
  esac

  hdr "MTU:"
  echo "  1) 1420 — стандартный"
  echo "  2) 1380 — лучше для мобильных (рекомендуется)"
  echo "  3) 1280 — максимальная совместимость"
  echo "  4) 1500 — Ethernet"
  echo "  5) Вручную"
  local MTU_CHOICE MTU=""
  read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = 1380): ${N}")" MTU_CHOICE
  MTU_CHOICE=${MTU_CHOICE:-2}
  case $MTU_CHOICE in
    1) MTU=1420 ;; 2) MTU=1380 ;; 3) MTU=1280 ;; 4) MTU=1500 ;;
    5) read -rp "  MTU (576-1500): " MTU ;;
    *) MTU=1380 ;;
  esac

  hdr "Порт сервера:"
  echo -e "${Y}  Для QUIC/TLS мимикрии рекомендуется порт 443${N}"
  read -rp "$(echo -e "${C}  Порт [51820 / 443 / r = случайный]: ${N}")" PORT
  if [[ "${PORT:-}" == "r" || "${PORT:-}" == "R" ]]; then
    PORT=$(rand_range 30001 65535)
    ok "случайный порт: $PORT"
  else
    PORT=${PORT:-51820}
  fi
  [[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1024 && "$PORT" -le 65535 ]] || {
    err "Порт должен быть 1024-65535"; return 1
  }

  echo ""
  echo -e "${W}  Параметры:${N}"
  echo "  Версия:   $AWG_VERSION"
  echo "  DNS:      $CLIENT_DNS"
  echo "  Мимикрия: ${MIMICRY_PROFILE:-none}"
  echo "  I1:       ${I1:+получен (${#I1} байт)}"
  echo "  Клиент:   $CLIENT_ADDR"
  echo "  Сервер:   $SERVER_ADDR"
  echo "  MTU:      $MTU"
  echo "  Порт:     $PORT"
  read -rp "$(echo -e "${C}  Продолжить? [Y/n]: ${N}")" CONFIRM
  CONFIRM=${CONFIRM:-y}
  [[ $CONFIRM =~ ^[Yy]$ ]] || { warn "Отменено."; return 0; }

  local srv_priv srv_pub cli_priv cli_pub psk srv_ip iface
  srv_priv=$(awg genkey)
  srv_pub=$(echo "$srv_priv" | awg pubkey)
  cli_priv=$(awg genkey)
  cli_pub=$(echo "$cli_priv" | awg pubkey)
  psk=$(awg genpsk)

  srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }

  iface=$(ip route | awk '/default/{print $5; exit}')
  [[ -z "$iface" ]] && { err "не удалось определить интерфейс"; return 1; }

  AWG_PARAMS_LINES=""
  gen_awg_params "$AWG_VERSION"

  echo 1 > /proc/sys/net/ipv4/ip_forward
  sysctl -p 2>/dev/null || warn "sysctl содержит лишние строки"

  mkdir -p /etc/amnezia/amneziawg

  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  {
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = $SERVER_ADDR"
    echo "ListenPort = $PORT"
    [[ -n "$AWG_PARAMS_LINES" ]] && echo "$AWG_PARAMS_LINES"
    [[ -n "$I1" ]] && echo "I1 = $I1"
    echo ""
    echo "PostUp   = ip link set dev awg0 mtu $MTU; echo 1 > /proc/sys/net/ipv4/ip_forward; iptables -t nat -C POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE; iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT"
    echo "PostDown = iptables -t nat -D POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true"
    echo ""
    echo "[Peer]"
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
    [[ -n "$AWG_PARAMS_LINES" ]] && echo "$AWG_PARAMS_LINES"
    [[ -n "$I1" ]] && echo "I1 = $I1"
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
  fi

  if command -v ufw &>/dev/null; then
    read -rp "$(echo -e "${C}  Открыть порт $PORT/udp в UFW? [Y/n]: ${N}")" OPEN_UFW
    OPEN_UFW=${OPEN_UFW:-y}
    if [[ $OPEN_UFW =~ ^[Yy]$ ]]; then
      ufw allow "${PORT}/udp" comment "AmneziaWG" || true
      ok "Порт ${PORT}/udp открыт"
    fi
  fi

  command -v qrencode &>/dev/null && qrencode -t ansiutf8 -s 1 -m 1 < /root/client1_awg2.conf

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════╗${N}"
  echo -e "${G}║            Сервер создан успешно             ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════╝${N}"
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
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg
ExecStart=
ExecStart=/usr/bin/awg-quick up ${SERVER_CONF}
ExecStop=
ExecStop=/usr/bin/awg-quick down ${SERVER_CONF}
EOF
  systemctl daemon-reload
  systemctl enable awg-quick@awg0 2>/dev/null && ok "Автозапуск включён" || \
    warn "Не удалось включить автозапуск"
}

# ══════════════════════════════════════════════════════════
# 3. ДОБАВИТЬ КЛИЕНТА (с мимикрией)
# ══════════════════════════════════════════════════════════
do_add_client() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден. Сначала пункт 2"; return 1; }
  command -v awg &>/dev/null || { err "awg не найден"; return 1; }

  local server_net base_ip client_addr
  server_net=$(grep "^Address" "$SERVER_CONF" | awk -F'=' '{print $2}' | tr -d ' ' | head -1)
  base_ip=$(echo "$server_net" | cut -d. -f1-3)
  client_addr=$(find_free_ip "$base_ip") || { err "подсеть заполнена"; return 1; }

  info "Следующий свободный IP: $client_addr"

  local client_name
  read -rp "$(echo -e "${C}  Имя клиента (phone, laptop...): ${N}")" client_name
  [[ -z "$client_name" ]] && { err "имя не может быть пустым"; return 1; }

  local client_file="/root/${client_name}_awg2.conf"
  [[ -f "$client_file" ]] && warn "Файл $client_file уже существует — будет перезаписан"

  read -rp "$(echo -e "${C}  Использовать IP $client_addr? [Y/n]: ${N}")" CONFIRM_IP
  CONFIRM_IP=${CONFIRM_IP:-y}
  if [[ ! $CONFIRM_IP =~ ^[Yy]$ ]]; then
    read -rp "  IP вручную (пример: ${base_ip}.5/32): " client_addr
  fi

  choose_dns

  local detected_ver="wg"
  if grep -q "^S3 = " "$SERVER_CONF" 2>/dev/null; then
    detected_ver="2.0"
  elif grep -q "^I1 = " "$SERVER_CONF" 2>/dev/null; then
    detected_ver="1.5"
  elif grep -q "^Jc = " "$SERVER_CONF" 2>/dev/null; then
    detected_ver="1.0"
  fi
  info "Версия сервера: $detected_ver"

  local i1_line=""
  if [[ "$detected_ver" == "1.5" || "$detected_ver" == "2.0" ]]; then
    hdr "Выбор I1 для клиента:"
    echo "  1) Использовать I1 из серверного конфига"
    echo "  2) Сгенерировать новый I1 (выбор профиля мимикрии)"
    echo "  3) Без I1"
    read -rp "$(echo -e "${C}  Выбор [1-3] (Enter = 1): ${N}")" I1_SELECT
    I1_SELECT=${I1_SELECT:-1}

    case $I1_SELECT in
      1)
        i1_line=$(grep "^I1 = " "$SERVER_CONF" | head -1 || true)
        [[ -z "$i1_line" ]] && warn "I1 не найден в конфиге сервера"
        ;;
      2)
        choose_mimicry_profile
        i1_line="I1 = $I1"
        ;;
      3)
        i1_line=""
        ;;
    esac
  fi

  local srv_pub srv_ip port mtu
  srv_pub=$(awg show awg0 public-key 2>/dev/null) \
    || { err "awg0 не поднят. Запусти: awg-quick up $SERVER_CONF"; return 1; }
  srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }
  port=$(grep "^ListenPort = " "$SERVER_CONF" | awk -F'= ' '{print $2}' | tr -d ' ')
  mtu=$(grep "^PostUp" "$SERVER_CONF" | grep -oP 'mtu \K\d+' | head -1 || true)
  mtu=${mtu:-1380}

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
  trap 'rm -f "$psk_tmp"' RETURN

  awg set awg0 peer "$cli_pub" \
    preshared-key "$psk_tmp" \
    allowed-ips "$client_addr" \
    || { err "не удалось добавить peer в runtime"; return 1; }

  local awg_params_from_srv
  awg_params_from_srv=$(grep -E "^(Jc|Jmin|Jmax|S[1-4]|H[1-4]) = " "$SERVER_CONF" | grep -v "^#" || true)

  {
    echo "[Interface]"
    echo "PrivateKey = $cli_priv"
    echo "Address = $client_addr"
    echo "DNS = $CLIENT_DNS"
    echo "MTU = $mtu"
    [[ -n "$awg_params_from_srv" ]] && echo "$awg_params_from_srv"
    [[ -n "$i1_line" ]] && echo "$i1_line"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $srv_pub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $srv_ip:$port"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } > "$client_file"
  chmod 600 "$client_file"

  command -v qrencode &>/dev/null && qrencode -t ansiutf8 -s 1 -m 1 < "$client_file"

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════╗${N}"
  echo -e "${G}║           Клиент добавлен успешно            ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════╝${N}"
  echo -e "${W}  Имя    : ${N}$client_name"
  echo -e "${W}  IP     : ${N}$client_addr"
  echo -e "${W}  Конфиг : ${N}$client_file"
}

# ══════════════════════════════════════════════════════════
# 4. ПОКАЗАТЬ КЛИЕНТОВ (расширенная информация)
# ══════════════════════════════════════════════════════════
do_list_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                                    КЛИЕНТЫ${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
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
      # Выводим предыдущего клиента, если есть
      if [[ $i -gt 0 ]] && [[ -n "$pubkey" ]]; then
        _print_client_info "$i" "$name" "$ip" "$tx_raw" "$rx_raw" "$handshake_time" "$endpoint"
      fi
      i=$((i+1))
      name=""; pubkey=""; ip=""; tx_raw=0; rx_raw=0; handshake_time=""; endpoint=""
    elif [[ "$line" =~ ^#[[:space:]](.+) ]]; then
      name="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^PublicKey[[:space:]]=[[:space:]](.+) ]]; then
      pubkey="${BASH_REMATCH[1]}"
      # Получаем статистику
      local transfer_line
      transfer_line=$(echo "$transfer_cache" | grep -F "$pubkey" | head -1)
      tx_raw=$(echo "$transfer_line" | awk '{print $2}' 2>/dev/null || echo "0")
      rx_raw=$(echo "$transfer_line" | awk '{print $3}' 2>/dev/null || echo "0")
      tx_raw=${tx_raw:-0}
      rx_raw=${rx_raw:-0}
      # Получаем время последнего handshake
      local hs_line
      hs_line=$(echo "$handshake_cache" | grep -F "$pubkey" | head -1)
      handshake_time=$(echo "$hs_line" | awk '{print $2}' 2>/dev/null || echo "")
      # Получаем endpoint
      local ep_line
      ep_line=$(echo "$endpoint_cache" | grep -F "$pubkey" | head -1)
      endpoint=$(echo "$ep_line" | awk '{print $2}' 2>/dev/null || echo "")
    elif [[ "$line" =~ ^AllowedIPs[[:space:]]=[[:space:]](.+) ]]; then
      ip="${BASH_REMATCH[1]}"
    fi
  done < "$SERVER_CONF"
  
  # Выводим последнего клиента
  if [[ $i -gt 0 ]] && [[ -n "$pubkey" ]]; then
    _print_client_info "$i" "$name" "$ip" "$tx_raw" "$rx_raw" "$handshake_time" "$endpoint"
  fi

  if [[ $i -eq 0 ]]; then
    echo -e "  ${Y}╔════════════════════════════════════════════════════════════════════════════╗${N}"
    echo -e "  ${Y}║                         НЕТ АКТИВНЫХ КЛИЕНТОВ                              ║${N}"
    echo -e "  ${Y}╚════════════════════════════════════════════════════════════════════════════╝${N}"
  fi
  
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${C}  ↑ — выгрузка (от клиента), ↓ — загрузка (к клиенту)${N}"
  echo -e "${C}  Подключение: если handshake не обновляется > 2 мин — клиент офлайн${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
}

# ── Вспомогательная функция для вывода информации о клиенте ──
_print_client_info() {
  local num="$1"
  local name="$2"
  local ip="$3"
  local tx_raw="$4"
  local rx_raw="$5"
  local handshake_time="$6"
  local endpoint="$7"
  
  # Форматируем имя
  local display_name="${name:-безымянный}"
  display_name="${display_name:0:15}"
  
  # Форматируем трафик
  local tx_fmt rx_fmt
  if (( tx_raw >= 1073741824 )); then
    tx_fmt=$(echo "scale=2; $tx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ"
  elif (( tx_raw >= 1048576 )); then
    tx_fmt=$(echo "scale=2; $tx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ"
  else
    tx_fmt=$(echo "scale=0; $tx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
  fi
  
  if (( rx_raw >= 1073741824 )); then
    rx_fmt=$(echo "scale=2; $rx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ"
  elif (( rx_raw >= 1048576 )); then
    rx_fmt=$(echo "scale=2; $rx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ"
  else
    rx_fmt=$(echo "scale=0; $rx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
  fi
  
  # Определяем статус подключения
  local status_icon=""
  local status_text=""
  if [[ -n "$handshake_time" ]] && [[ "$handshake_time" != "0" ]]; then
    local current_time=$(date +%s)
    local last_hs=$handshake_time
    local diff=$((current_time - last_hs))
    if [[ $diff -lt 120 ]]; then
      status_icon="${G}●${N}"
      status_text="активен"
    elif [[ $diff -lt 300 ]]; then
      status_icon="${Y}◐${N}"
      status_text="неактивен ($((diff/60)) мин)"
    else
      status_icon="${R}○${N}"
      status_text="офлайн ($((diff/60)) мин)"
    fi
  else
    status_icon="${R}○${N}"
    status_text="нет подключения"
  fi
  
  # Форматируем endpoint (обрезаем порт если нужно)
  local endpoint_short=""
  if [[ -n "$endpoint" ]]; then
    endpoint_short="${endpoint%:*}"
  fi
  
  # Выводим информацию
  echo -e "  ${W}┌─ ${C}[${num}]${N} ${W}${display_name}${N}"
  echo -e "  ${W}│${N}  IP:        ${W}$ip${N}"
  echo -e "  ${W}│${N}  Трафик:    ↑ ${G}$tx_fmt${N}  ↓ ${C}$rx_fmt${N}"
  echo -e "  ${W}│${N}  Статус:    $status_icon $status_text"
  if [[ -n "$endpoint_short" ]]; then
    echo -e "  ${W}│${N}  Endpoint:  ${Y}$endpoint_short${N}"
  fi
  echo -e "  ${W}└─────────────────────────────────────────────────────────────────────────${N}"
}

# ══════════════════════════════════════════════════════════
# 5. QR КЛИЕНТА
# ══════════════════════════════════════════════════════════
do_show_qr() {
  command -v qrencode &>/dev/null || { err "qrencode не установлен"; return 1; }

  local found=()
  while IFS= read -r -d '' f; do
    found+=("$f")
  done < <(find /root -maxdepth 1 -name "*_awg2.conf" -print0 2>/dev/null)

  [[ ${#found[@]} -eq 0 ]] && { err "конфиги клиентов не найдены в /root/"; return 1; }

  local unique
  mapfile -t unique < <(printf "%s\n" "${found[@]}" | sort -u)

  hdr "Выбери конфиг:"
  local i=0
  for f in "${unique[@]}"; do
    i=$((i+1))
    echo "  $i) $(basename "$f")"
  done

  local QR_CHOICE
  read -rp "$(echo -e "${C}  Выбор [1-$i]: ${N}")" QR_CHOICE
  [[ "$QR_CHOICE" =~ ^[0-9]+$ ]] && \
  [[ "$QR_CHOICE" -ge 1 ]] && \
  [[ "$QR_CHOICE" -le $i ]] \
    || { err "неверный выбор (1-$i)"; return 1; }

  local idx=$((QR_CHOICE - 1))
  local chosen="${unique[$idx]}"
  [[ -f "$chosen" ]] || { err "файл не найден: $chosen"; return 1; }

  qrencode -t ansiutf8 -s 1 -m 1 < "$chosen"
  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo -e "${W}  Или сохрани текст ниже в файл client.conf${N}"
  echo -e "${W}  и импортируй в AmneziaVPN: Добавить туннель → Из файла${N}"
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo ""
  cat "$chosen"
  echo ""
  ok "$chosen"
}

# ══════════════════════════════════════════════════════════
# 6. ПЕРЕЗАПУСК
# ══════════════════════════════════════════════════════════
do_restart() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  info "Перезапуск awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  awg-quick up "$SERVER_CONF"
  ok "awg0 перезапущен"
}

# ══════════════════════════════════════════════════════════
# 7. УДАЛИТЬ ВСЁ
# ══════════════════════════════════════════════════════════
do_uninstall() {
  echo ""
  warn "Будет удалено:"
  echo "  — интерфейс awg0"
  echo "  — пакеты amneziawg, amneziawg-tools"
  echo "  — /etc/amnezia/amneziawg/"
  echo "  — /root/*_awg2.conf"
  echo "  — автозапуск awg-quick@awg0"
  echo ""
  local CONFIRM_DEL
  read -rp "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")" CONFIRM_DEL
  [[ "$CONFIRM_DEL" != "yes" ]] && { warn "Отменено."; return 0; }

  info "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  info "Отключаем автозапуск..."
  systemctl disable awg-quick@awg0 2>/dev/null || true
  rm -rf /etc/systemd/system/awg-quick@awg0.service.d 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  info "Удаляем пакеты..."
  apt-get remove -y -q amneziawg amneziawg-tools 2>/dev/null || true
  apt-get autoremove -y -q 2>/dev/null || true

  info "Удаляем конфиги..."
  rm -rf /etc/amnezia 2>/dev/null || true
  rm -f /root/*_awg2.conf 2>/dev/null || true

  info "Удаляем UFW правила..."
  if command -v ufw &>/dev/null; then
    local rule_nums
    rule_nums=$(ufw status numbered 2>/dev/null | grep -i "AmneziaWG" | grep -oE '\[[0-9]+\]' | tr -d '[]' | sort -rn)
    for num in $rule_nums; do
      echo "y" | ufw --force delete "$num" 2>/dev/null || true
    done
  fi

  echo ""
  ok "Всё удалено"
}

# ══════════════════════════════════════════════════════════
# 8. ПРОВЕРКА ДОМЕНОВ (НЕ ВЫКИДЫВАЕТ ИЗ СКРИПТА)
# ══════════════════════════════════════════════════════════
do_check_domains() {
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}        Проверка доступности доменов для мимикрии${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  local available=0
  local total=0

  # QUIC Initial (топ-10)
  echo -e "${C}  QUIC Initial (HTTP/3):${N}"
  for domain in yandex.net yastatic.net vk.com mail.ru ozon.ru wildberries.ru sber.ru tbank.ru gcore.com fastly.net; do
    total=$((total + 1))
    if ping -c 1 -W 2 "$domain" &>/dev/null 2>&1; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available + 1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done

  echo ""
  echo -e "${C}  TLS 1.3 Client Hello (HTTPS):${N}"
  for domain in yandex.ru vk.com mail.ru github.com gitlab.com microsoft.com apple.com stackoverflow.com; do
    total=$((total + 1))
    if ping -c 1 -W 2 "$domain" &>/dev/null 2>&1; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available + 1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done

  echo ""
  echo -e "${C}  DTLS (WebRTC/STUN):${N}"
  for domain in stun.yandex.net stun.vk.com stun.mail.ru meet.jit.si stun.stunprotocol.org; do
    total=$((total + 1))
    if ping -c 1 -W 2 "$domain" &>/dev/null 2>&1; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available + 1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done

  echo ""
  echo -e "${C}  SIP (VoIP):${N}"
  for domain in sip.beeline.ru sip.mts.ru sip.yandex.ru sip.iptel.org; do
    total=$((total + 1))
    if ping -c 1 -W 2 "$domain" &>/dev/null 2>&1; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available + 1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${G}  ✓ Доступно: $available из $total доменов${N}"
  echo -e "${Y}  → При генерации будут использованы только доступные домены${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  # Не выходим из скрипта, просто показываем результаты
  return 0
}

# ══════════════════════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════════════════════
CHOICE=""
CLIENT_DNS="1.1.1.1, 1.0.0.1"
AWG_VERSION="2.0"
I1=""
MIMICRY_PROFILE=""
MIMICRY_DOMAIN=""
AWG_PARAMS_LINES=""

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/awg-manager.log"
log_info "=== AWG Manager v4.0 запущен ==="

trap 'rm -f /tmp/awg_tmp_* 2>/dev/null || true' EXIT

while true; do
  show_header
  show_menu
  case "${CHOICE:-}" in
    1) do_install ;;
    2) do_gen ;;
    3) do_add_client ;;
    4) do_list_clients ;;
    5) do_show_qr ;;
    6) do_restart ;;
    7) do_uninstall ;;
    8) do_check_domains ;;
    0) log_info "Выход"; echo -e "\n${G}  Пока!${N}\n"; exit 0 ;;
    *) warn "Неверный выбор" ;;
  esac
  echo ""
  read -rp "$(echo -e "${C}  Enter для продолжения...${N}")"
done
