#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# AmneziaWG Manager v4.2 — полная версия
# ─────────────────────────────────────────────────────────────

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${R}Запускай от root${N}"; exit 1; }

ok()   { echo -e "${G}  ✓ $*${N}"; }
err()  { echo -e "${R}  ✗ $*${N}"; }
warn() { echo -e "${Y}  ⚠ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }
hdr()  { echo -e "\n${W}$*${N}"; }

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
LOG_FILE="/var/log/awg-manager.log"

# ── Логирование ────────────────────────────────────────────
_log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"; }
log_info() { _log "INFO" "$*"; }
log_err() { _log "ERROR" "$*"; }

# ══════════════════════════════════════════════════════════
# ДОМЕННЫЕ ПУЛЫ
# ══════════════════════════════════════════════════════════

QUIC_INITIAL_DOMAINS=(
  "yandex.net" "yastatic.net" "vk.com" "mycdn.me" "mail.ru"
  "ozon.ru" "wildberries.ru" "wbstatic.net" "sber.ru" "tbank.ru"
  "gosuslugi.ru" "gcore.com" "fastly.net" "cloudfront.net"
  "microsoft.com" "icloud.com" "github.com" "cdn.jsdelivr.net"
  "wikipedia.org" "dropbox.com" "steamstatic.com" "spotify.com"
  "akamaiedge.net" "msedge.net" "azureedge.net"
)

QUIC_0RTT_DOMAINS=(
  "yandex.net" "vk.com" "mail.ru" "ozon.ru" "wildberries.ru"
  "sber.ru" "tbank.ru" "gosuslugi.ru" "gcore.com" "fastly.net"
  "cloudfront.net" "microsoft.com" "github.com" "cdn.jsdelivr.net"
)

TLS_CLIENT_HELLO_DOMAINS=(
  "yandex.ru" "vk.com" "mail.ru" "ozon.ru" "wildberries.ru"
  "sberbank.ru" "tbank.ru" "gosuslugi.ru" "kaspersky.ru"
  "github.com" "gitlab.com" "stackoverflow.com" "microsoft.com"
  "apple.com" "amazon.com" "cloudflare.com" "google.com"
)

DTLS_DOMAINS=(
  "stun.yandex.net" "stun.vk.com" "stun.mail.ru" "stun.sber.ru"
  "stun.stunprotocol.org" "meet.jit.si" "stun.services.mozilla.com"
)

SIP_DOMAINS=(
  "sip.beeline.ru" "sip.mts.ru" "sip.megafon.ru" "sip.rostelecom.ru"
  "sip.yandex.ru" "sip.vk.com" "sip.mail.ru" "sip.sipnet.ru"
  "sip.zadarma.com" "sip.iptel.org" "sip.linphone.org"
)

select_random_domain() {
  local profile="$1"
  local domains=()
  case "$profile" in
    "quic_initial") domains=("${QUIC_INITIAL_DOMAINS[@]}") ;;
    "quic_0rtt")    domains=("${QUIC_0RTT_DOMAINS[@]}") ;;
    "tls")          domains=("${TLS_CLIENT_HELLO_DOMAINS[@]}") ;;
    "dtls")         domains=("${DTLS_DOMAINS[@]}") ;;
    "sip")          domains=("${SIP_DOMAINS[@]}") ;;
    *)              domains=("${QUIC_INITIAL_DOMAINS[@]}") ;;
  esac
  echo "${domains[$((RANDOM % ${#domains[@]}))]}"
}

fetch_i1_from_api() {
  local domain="$1"
  local api_url="https://junk.web2core.workers.dev/signature?domain=${domain}"
  local api_resp=$(timeout 10 curl -s --connect-timeout 5 "$api_url" 2>/dev/null || echo "")
  local i1_val=$(echo "$api_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('i1',''))" 2>/dev/null || echo "")
  [[ -z "$i1_val" ]] && return 1
  i1_val=$(echo "$i1_val" | tr -d '\n\r' | sed 's/^"//;s/"$//')
  [[ "$i1_val" =~ ^\<b0x ]] && i1_val="${i1_val/<b0x/<b 0x}"
  echo "$i1_val"
}

# ══════════════════════════════════════════════════════════
# 1. УСТАНОВКА
# ══════════════════════════════════════════════════════════
do_install() {
  hdr "=== Обновление системы ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

  hdr "=== Зависимости ==="
  apt-get install -y -q software-properties-common python3-launchpadlib python3 net-tools curl ufw iptables qrencode bc

  hdr "=== Kernel headers ==="
  apt-get install -y -q "linux-headers-$(uname -r)" 2>/dev/null || apt-get install -y -q linux-headers-generic || { err "не удалось установить linux-headers"; exit 1; }

  hdr "=== AmneziaWG (PPA) ==="
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -q
  apt-get install -y -q amneziawg amneziawg-tools

  command -v awg &>/dev/null || { err "awg не найден"; exit 1; }
  ok "amneziawg-tools установлен"

  hdr "=== Проверка модуля ==="
  modprobe amneziawg 2>/dev/null && ok "модуль загружен" || warn "Модуль не загрузился. Сделай reboot"

  hdr "=== IP Forwarding ==="
  sysctl -w net.ipv4.ip_forward=1 -q
  grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  hdr "=== NAT + FORWARD ==="
  local ext_if=$(ip route | awk '/default/ {print $5; exit}')
  [[ -z "$ext_if" ]] && { err "не найден default интерфейс"; exit 1; }
  ok "интерфейс: $ext_if"

  iptables -t nat -C POSTROUTING -o "$ext_if" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$ext_if" -j MASQUERADE
  iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT
  iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT

  cat > "/etc/network/if-pre-up.d/iptables-nat" <<EOF
#!/bin/sh
iptables -t nat -C POSTROUTING -o ${ext_if} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${ext_if} -j MASQUERADE
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT
EOF
  chmod +x "/etc/network/if-pre-up.d/iptables-nat"
  ok "NAT hook сохранён"

  mkdir -p /etc/amnezia/amneziawg
  chmod 700 /etc/amnezia/amneziawg

  hdr "=== Firewall ==="
  read -rp "$(echo -e "${C}  SSH порт [22]: ${N}")" ssh_port
  ssh_port=${ssh_port:-22}
  ufw allow "${ssh_port}/tcp" comment "SSH" || true
  ufw allow 80/tcp comment "HTTP" || true
  ufw allow 443/tcp comment "HTTPS" || true
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw --force enable || true

  echo ""
  ok "Установка завершена"
  info "Следующий шаг: пункт меню 2 — Создать сервер"
}

# ══════════════════════════════════════════════════════════
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════

get_public_ip() {
  timeout 5 curl -s --connect-timeout 3 -4 ifconfig.me 2>/dev/null || \
  timeout 5 curl -s --connect-timeout 3 -4 api.ipify.org 2>/dev/null || \
  echo ""
}

rand_range() { python3 -c "import random; print(random.randint($1, $2))"; }

find_free_ip() {
  local base="$1"
  for i in $(seq 2 254); do
    if ! grep -qF "${base}.${i}/32" "$SERVER_CONF" 2>/dev/null; then
      echo "${base}.${i}/32"
      return 0
    fi
  done
  return 1
}

get_status() {
  local ip=$(get_public_ip)
  [[ -z "$ip" ]] && ip="—"
  if ip link show awg0 &>/dev/null; then
    echo -e "$ip|$(awg show awg0 listen-port 2>/dev/null || echo "—")|${G}активен${N}|$(awg show awg0 peers 2>/dev/null | wc -l | tr -d ' ')"
  else
    echo -e "$ip|—|${R}не активен${N}|0"
  fi
}

show_header() {
  clear
  local s=($(get_status | tr '|' ' '))
  echo -e "${B}╔══════════════════════════════════════════════╗${N}"
  echo -e "${B}║${W}        AmneziaWG Manager v4.2                ${B}║${N}"
  echo -e "${B}║${C}     С генератором мимикрии (QUIC/TLS/DTLS)   ${B}║${N}"
  echo -e "${B}╚══════════════════════════════════════════════╝${N}"
  echo -e "${B}  IP сервера : ${W}${s[0]}${N}"
  echo -e "${B}  Порт       : ${W}${s[1]}${N}"
  echo -e "${B}  Интерфейс  : ${s[2]}${N}"
  echo -e "${B}  Клиентов   : ${W}${s[3]}${N}"
}

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
  echo -e "  ${W}9)${N} Очистить всех клиентов"
  echo -e "  ${W}0)${N} Выход"
  echo ""
  read -rp "$(echo -e "${C}  Выбор: ${N}")" CHOICE
}

choose_dns() {
  hdr "DNS для клиента:"
  echo "  1) Cloudflare  — 1.1.1.1, 1.0.0.1"
  echo "  2) Google      — 8.8.8.8, 8.8.4.4"
  echo "  3) OpenDNS     — 208.67.222.222, 208.67.220.220"
  echo "  4) Яндекс DNS  — 77.88.8.8, 77.88.8.1"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = Cloudflare): ${N}")" DNS_CHOICE
  DNS_CHOICE=${DNS_CHOICE:-1}
  case $DNS_CHOICE in
    1) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
    2) CLIENT_DNS="8.8.8.8, 8.8.4.4" ;;
    3) CLIENT_DNS="208.67.222.222, 208.67.220.220" ;;
    4) CLIENT_DNS="77.88.8.8, 77.88.8.1" ;;
  esac
}

choose_awg_version() {
  hdr "Версия протокола:"
  echo "  1) AWG 2.0  — S3/S4 + H1-H4 диапазоны + I1 (рекомендуется)"
  echo "  2) AWG 1.5  — H1-H4 одиночные + I1, без S3/S4"
  echo "  3) AWG 1.0  — Jc/Jmin/Jmax + S1/S2 + H1-H4 одиночные, без I1"
  echo "  4) WireGuard — без обфускации"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = AWG 2.0): ${N}")" VER_CHOICE
  VER_CHOICE=${VER_CHOICE:-1}
  case $VER_CHOICE in
    1) AWG_VERSION="2.0" ;;
    2) AWG_VERSION="1.5" ;;
    3) AWG_VERSION="1.0" ;;
    4) AWG_VERSION="wg" ;;
  esac
  ok "Версия: $AWG_VERSION"
}

choose_mimicry_profile() {
  I1=""
  MIMICRY_PROFILE=""
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
    1) MIMICRY_PROFILE="quic_initial"; domain=$(select_random_domain "quic_initial"); echo -e "${C}  → QUIC Initial, домен: ${W}$domain${N}" ;;
    2) MIMICRY_PROFILE="quic_0rtt"; domain=$(select_random_domain "quic_0rtt"); echo -e "${C}  → QUIC 0-RTT, домен: ${W}$domain${N}" ;;
    3) MIMICRY_PROFILE="tls"; domain=$(select_random_domain "tls"); echo -e "${C}  → TLS 1.3, домен: ${W}$domain${N}" ;;
    4) MIMICRY_PROFILE="dtls"; domain=$(select_random_domain "dtls"); echo -e "${C}  → DTLS, домен: ${W}$domain${N}" ;;
    5) MIMICRY_PROFILE="sip"; domain=$(select_random_domain "sip"); echo -e "${C}  → SIP, домен: ${W}$domain${N}" ;;
    6) local profiles=("quic_initial" "quic_0rtt" "tls" "dtls" "sip"); MIMICRY_PROFILE="${profiles[$((RANDOM % 5))]}"; domain=$(select_random_domain "$MIMICRY_PROFILE"); echo -e "${C}  → Случайный профиль: ${W}$MIMICRY_PROFILE${N}, домен: ${W}$domain${N}" ;;
    7) read -rp "$(echo -e "${C}  Введите домен: ${N}")" domain; [[ -z "$domain" ]] && { warn "Домен не введён"; return 1; }; echo -e "${C}  → Ручной ввод: ${W}$domain${N}" ;;
    8) I1=""; MIMICRY_PROFILE="none"; echo -e "${G}  ✓ Без имитации${N}"; return 0 ;;
    *) MIMICRY_PROFILE="quic_initial"; domain=$(select_random_domain "quic_initial"); echo -e "${C}  → По умолчанию: QUIC Initial, домен: ${W}$domain${N}" ;;
  esac

  if [[ "$PROFILE_CHOICE" != "8" ]] && [[ -n "$domain" ]]; then
    echo -e "${C}  → Запрос I1 для $domain...${N}"
    I1=$(fetch_i1_from_api "$domain")
    if [[ -z "$I1" ]]; then
      echo -e "${Y}  ⚠ Не удалось получить I1 для $domain${N}"
      read -rp "$(echo -e "${C}  Продолжить без I1? [y/N]: ${N}")" CONTINUE
      [[ ! "$CONTINUE" =~ ^[Yy]$ ]] && return 1
      I1=""
    else
      echo -e "${G}  ✓ I1 получен (длина: ${#I1} байт)${N}"
    fi
  fi
}

gen_awg_params() {
  local ver="$1"
  AWG_PARAMS_LINES=""
  [[ "$ver" == "wg" ]] && return 0

  local Jc Jmin Jmax S1 S2 Q=1073741823
  [[ "$ver" == "1.0" ]] && Jc=$(rand_range 4 7) || Jc=$(rand_range 3 7)
  Jmin=$(rand_range 64 256)
  Jmax=$(rand_range 576 1024)
  S1=$(rand_range 1 39)
  S2=$(rand_range 1 64)
  
  if [[ "$ver" == "2.0" ]]; then
    local S3=$(rand_range 5 64) S4=$(rand_range 1 16)
    local H1=$(rand_range 5 $((Q - 1))) H2=$(rand_range 5 $((Q * 2 - 1)))
    local H3=$(rand_range 5 $((Q * 3 - 1))) H4=$(rand_range 5 $((Q * 4 - 1)))
    AWG_PARAMS_LINES="Jc = $Jc\nJmin = $Jmin\nJmax = $Jmax\nS1 = $S1\nS2 = $S2\nS3 = $S3\nS4 = $S4\nH1 = $H1\nH2 = $H2\nH3 = $H3\nH4 = $H4"
  else
    local H1=$(rand_range 5 $((Q - 1))) H2=$(rand_range 5 $((Q * 2 - 1)))
    local H3=$(rand_range 5 $((Q * 3 - 1))) H4=$(rand_range 5 $((Q * 4 - 1)))
    AWG_PARAMS_LINES="Jc = $Jc\nJmin = $Jmin\nJmax = $Jmax\nS1 = $S1\nS2 = $S2\nH1 = $H1\nH2 = $H2\nH3 = $H3\nH4 = $H4"
  fi
}

# ══════════════════════════════════════════════════════════
# 2. СОЗДАТЬ СЕРВЕР
# ══════════════════════════════════════════════════════════
do_gen() {
  log_info "do_gen: старт"
  command -v awg &>/dev/null || { err "awg не найден. Сначала пункт 1"; return 1; }

  [[ -f "$SERVER_CONF" ]] && cp "$SERVER_CONF" "${SERVER_CONF}.bak.$(date +%s)" && info "Backup создан"

  choose_awg_version
  choose_dns
  choose_mimicry_profile || return 1

  hdr "IP подсеть сервера:"
  echo "  1) 10.100.0.0/24  2) 10.101.0.0/24  3) 10.102.0.0/24  4) Вручную"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = 10.100.0.0/24): ${N}")" ADDR_CHOICE
  ADDR_CHOICE=${ADDR_CHOICE:-1}
  case $ADDR_CHOICE in
    1) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
    2) CLIENT_ADDR="10.101.0.2/32"; SERVER_ADDR="10.101.0.1/24"; CLIENT_NET="10.101.0.0/24" ;;
    3) CLIENT_ADDR="10.102.0.2/32"; SERVER_ADDR="10.102.0.1/24"; CLIENT_NET="10.102.0.0/24" ;;
    4) read -rp "  IP клиента (X.X.X.X/32): " CLIENT_ADDR; read -rp "  IP сервера (X.X.X.X/24): " SERVER_ADDR; read -rp "  Подсеть NAT (X.X.X.0/24): " CLIENT_NET ;;
  esac

  hdr "MTU:"
  echo "  1) 1420  2) 1380 (рекомендуется)  3) 1280  4) 1500"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = 1380): ${N}")" MTU_CHOICE
  MTU_CHOICE=${MTU_CHOICE:-2}
  case $MTU_CHOICE in 1) MTU=1420 ;; 2) MTU=1380 ;; 3) MTU=1280 ;; 4) MTU=1500 ;; esac

  hdr "Порт сервера:"
  echo -e "${Y}  Для QUIC/TLS мимикрии рекомендуется порт 443${N}"
  read -rp "$(echo -e "${C}  Порт [51820 / 443 / r = случайный]: ${N}")" PORT
  [[ "${PORT:-}" == "r" ]] && PORT=$(rand_range 30001 65535)
  PORT=${PORT:-51820}

  echo ""
  echo -e "${W}  Параметры:${N}"
  echo "  Версия:   $AWG_VERSION"
  echo "  DNS:      $CLIENT_DNS"
  echo "  Мимикрия: ${MIMICRY_PROFILE:-none}"
  echo "  I1:       ${I1:+получен (${#I1} байт)}"
  echo "  MTU:      $MTU"
  echo "  Порт:     $PORT"
  read -rp "$(echo -e "${C}  Продолжить? [Y/n]: ${N}")" CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Отменено."; return 0; }

  local srv_priv=$(awg genkey)
  local srv_pub=$(echo "$srv_priv" | awg pubkey)
  local cli_priv=$(awg genkey)
  local cli_pub=$(echo "$cli_priv" | awg pubkey)
  local psk=$(awg genpsk)

  local srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }

  local iface=$(ip route | awk '/default/ {print $5; exit}')
  [[ -z "$iface" ]] && { err "не удалось определить интерфейс"; return 1; }

  gen_awg_params "$AWG_VERSION"

  awg-quick down "$SERVER_CONF" 2>/dev/null || true

  {
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = $SERVER_ADDR"
    echo "ListenPort = $PORT"
    echo "MTU = $MTU"
    echo -e "$AWG_PARAMS_LINES"
    [[ -n "$I1" && "$AWG_VERSION" != "1.0" && "$AWG_VERSION" != "wg" ]] && echo "I1 = $I1"
    echo ""
    echo "PostUp   = ip link set dev awg0 mtu $MTU; echo 1 > /proc/sys/net/ipv4/ip_forward; iptables -t nat -C POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE; iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT"
    echo "PostDown = iptables -t nat -D POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $cli_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $CLIENT_ADDR"
  } > "$SERVER_CONF"

  {
    echo "[Interface]"
    echo "PrivateKey = $cli_priv"
    echo "Address = $CLIENT_ADDR"
    echo "DNS = $CLIENT_DNS"
    echo "MTU = $MTU"
    echo -e "$AWG_PARAMS_LINES"
    [[ -n "$I1" && "$AWG_VERSION" != "1.0" && "$AWG_VERSION" != "wg" ]] && echo "I1 = $I1"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $srv_pub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $srv_ip:$PORT"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } > /root/client1_awg2.conf

  chmod 600 "$SERVER_CONF" /root/client1_awg2.conf

  if awg-quick up "$SERVER_CONF"; then
    ok "Сервер запущен"
  else
    err "Не удалось запустить сервер"
    return 1
  fi

  ufw allow "${PORT}/udp" comment "AmneziaWG" 2>/dev/null || true
  qrencode -t ansiutf8 < /root/client1_awg2.conf 2>/dev/null || true
  
  echo ""
  echo -e "${G}╔══════════════════════════════════════════════╗${N}"
  echo -e "${G}║            Сервер создан успешно             ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════╝${N}"
  echo -e "${W}  Версия : ${N}$AWG_VERSION"
  echo -e "${W}  Профиль: ${N}${MIMICRY_PROFILE:-none}"
  echo -e "${W}  Клиент : ${N}/root/client1_awg2.conf"
  echo -e "${W}  IP     : ${N}$srv_ip:$PORT"
}

# ══════════════════════════════════════════════════════════
# 3. ДОБАВИТЬ КЛИЕНТА
# ══════════════════════════════════════════════════════════
do_add_client() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  command -v awg &>/dev/null || { err "awg не найден"; return 1; }

  local server_net=$(grep "^Address" "$SERVER_CONF" | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
  local base_ip=$(echo "$server_net" | cut -d. -f1-3)
  local client_addr=$(find_free_ip "$base_ip") || { err "подсеть заполнена"; return 1; }

  info "Следующий свободный IP: $client_addr"
  read -rp "$(echo -e "${C}  Имя клиента: ${N}")" client_name
  [[ -z "$client_name" ]] && client_name="client"

  choose_dns

  local srv_pub=$(awg show awg0 public-key 2>/dev/null)
  [[ -z "$srv_pub" ]] && { err "awg0 не запущен"; return 1; }
  
  local srv_ip=$(get_public_ip)
  local port=$(grep "^ListenPort" "$SERVER_CONF" | awk -F'= ' '{print $2}')
  local mtu=$(grep "^MTU" "$SERVER_CONF" | awk -F'= ' '{print $2}')
  mtu=${mtu:-1380}
  
  local awg_params=$(grep -E "^(Jc|Jmin|Jmax|S[1-4]|H[1-4])" "$SERVER_CONF" | grep -v "^#")

  local cli_priv=$(awg genkey)
  local cli_pub=$(echo "$cli_priv" | awg pubkey)
  local psk=$(awg genpsk)

  {
    echo ""
    echo "[Peer]"
    echo "# $client_name"
    echo "PublicKey = $cli_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $client_addr"
  } >> "$SERVER_CONF"

  local psk_file=$(mktemp)
  echo "$psk" > "$psk_file"
  awg set awg0 peer "$cli_pub" preshared-key "$psk_file" allowed-ips "$client_addr"
  rm -f "$psk_file"

  local client_file="/root/${client_name}_awg2.conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $cli_priv"
    echo "Address = $client_addr"
    echo "DNS = $CLIENT_DNS"
    echo "MTU = $mtu"
    echo "$awg_params"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $srv_pub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $srv_ip:$port"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } > "$client_file"
  chmod 600 "$client_file"

  qrencode -t ansiutf8 < "$client_file" 2>/dev/null || true
  echo ""
  echo -e "${G}  ✓ Клиент $client_name добавлен${N}"
  echo -e "${W}  Конфиг: $client_file${N}"
}

# ══════════════════════════════════════════════════════════
# 4. ПОКАЗАТЬ КЛИЕНТОВ (расширенный вывод)
# ══════════════════════════════════════════════════════════
do_list_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                                    КЛИЕНТЫ${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  local transfer_cache=$(awg show awg0 transfer 2>/dev/null || true)
  local i=0 name="" pubkey="" ip="" tx_raw=0 rx_raw=0

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[Peer\] ]]; then
      if [[ $i -gt 0 ]] && [[ -n "$pubkey" ]]; then
        local tx_fmt rx_fmt
        (( tx_raw >= 1073741824 )) && tx_fmt=$(echo "scale=2; $tx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ" || \
        (( tx_raw >= 1048576 )) && tx_fmt=$(echo "scale=2; $tx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ" || \
        tx_fmt=$(echo "scale=0; $tx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
        (( rx_raw >= 1073741824 )) && rx_fmt=$(echo "scale=2; $rx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ" || \
        (( rx_raw >= 1048576 )) && rx_fmt=$(echo "scale=2; $rx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ" || \
        rx_fmt=$(echo "scale=0; $rx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
        echo -e "  ${W}$(printf '%2d' $i))${N} ${C}$(printf '%-10s' "${name:-безымянный}")${N}  IP: ${W}$(printf '%-20s' "$ip")${N}  ↑ ${G}$tx_fmt${N}  ↓ ${C}$rx_fmt${N}"
      fi
      i=$((i+1))
      name=""; pubkey=""; ip=""; tx_raw=0; rx_raw=0
    elif [[ "$line" =~ ^#[[:space:]](.+) ]]; then
      name="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^PublicKey[[:space:]]=[[:space:]](.+) ]]; then
      pubkey="${BASH_REMATCH[1]}"
      local transfer_line=$(echo "$transfer_cache" | grep -F "$pubkey" | head -1)
      tx_raw=$(echo "$transfer_line" | awk '{print $2}' 2>/dev/null || echo "0")
      rx_raw=$(echo "$transfer_line" | awk '{print $3}' 2>/dev/null || echo "0")
    elif [[ "$line" =~ ^AllowedIPs[[:space:]]=[[:space:]](.+) ]]; then
      ip="${BASH_REMATCH[1]}"
    fi
  done < "$SERVER_CONF"

  if [[ $i -gt 0 ]] && [[ -n "$pubkey" ]]; then
    local tx_fmt rx_fmt
    (( tx_raw >= 1073741824 )) && tx_fmt=$(echo "scale=2; $tx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ" || \
    (( tx_raw >= 1048576 )) && tx_fmt=$(echo "scale=2; $tx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ" || \
    tx_fmt=$(echo "scale=0; $tx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
    (( rx_raw >= 1073741824 )) && rx_fmt=$(echo "scale=2; $rx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ" || \
    (( rx_raw >= 1048576 )) && rx_fmt=$(echo "scale=2; $rx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ" || \
    rx_fmt=$(echo "scale=0; $rx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
    echo -e "  ${W}$(printf '%2d' $i))${N} ${C}$(printf '%-10s' "${name:-безымянный}")${N}  IP: ${W}$(printf '%-20s' "$ip")${N}  ↑ ${G}$tx_fmt${N}  ↓ ${C}$rx_fmt${N}"
  fi

  [[ $i -eq 0 ]] && echo -e "  ${Y}  Нет клиентов${N}"
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${C}  ↑ — выгрузка (от клиента), ↓ — загрузка (к клиенту)${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ══════════════════════════════════════════════════════════
# 5. QR КЛИЕНТА
# ══════════════════════════════════════════════════════════
do_show_qr() {
  command -v qrencode &>/dev/null || { err "qrencode не установлен"; return 1; }
  local files=(/root/*_awg2.conf)
  [[ ${#files[@]} -eq 0 || ! -f "${files[0]}" ]] && { err "нет конфигов клиентов"; return 1; }
  
  hdr "Выбери конфиг:"
  for i in "${!files[@]}"; do
    echo "  $((i+1))) $(basename "${files[$i]}")"
  done
  read -rp "$(echo -e "${C}  Выбор: ${N}")" choice
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#files[@]} ] || { err "неверный выбор"; return 1; }
  qrencode -t ansiutf8 < "${files[$((choice-1))]}"
  echo ""
  cat "${files[$((choice-1))]}"
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
  warn "Будет удалено: интерфейс awg0, пакеты amneziawg, конфиги, клиенты"
  read -rp "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")" CONFIRM
  [[ "$CONFIRM" != "yes" ]] && return 0
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  systemctl disable awg-quick@awg0 2>/dev/null || true
  apt-get remove -y amneziawg amneziawg-tools 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  rm -rf /etc/amnezia /root/*_awg2.conf
  ok "Всё удалено"
}

# ══════════════════════════════════════════════════════════
# 8. ПРОВЕРКА ДОМЕНОВ (с цветным выводом)
# ══════════════════════════════════════════════════════════
do_check_domains() {
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                     Проверка доступности доменов для мимикрии${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  local available=0 total=0

  echo -e "${C}  QUIC Initial (HTTP/3):${N}"
  for domain in yandex.net yastatic.net vk.com mail.ru ozon.ru wildberries.ru sber.ru tbank.ru; do
    total=$((total+1))
    if timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available+1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done

  echo ""
  echo -e "${C}  TLS 1.3 Client Hello (HTTPS):${N}"
  for domain in yandex.ru vk.com mail.ru github.com gitlab.com microsoft.com apple.com; do
    total=$((total+1))
    if timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available+1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${G}  ✓ Доступно: $available из $total доменов${N}"
  [[ $available -lt $total ]] && echo -e "${Y}  ⚠ Недоступные домены будут исключены из выбора${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ══════════════════════════════════════════════════════════
# 9. ОЧИСТИТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
do_clean_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  local count=$(grep -c "^\[Peer\]" "$SERVER_CONF" 2>/dev/null || echo "0")
  [[ $count -eq 0 ]] && { warn "Нет клиентов"; return 0; }
  echo ""
  echo -e "${Y}  ⚠ Будет удалено ${count} клиентов${N}"
  read -rp "$(echo -e "${R}  Подтвердить удаление? [yes/N]: ${N}")" CONFIRM
  [[ "$CONFIRM" != "yes" ]] && return 0
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  cp "$SERVER_CONF" "${SERVER_CONF}.bak.clean.$(date +%s)" 2>/dev/null || true
  sed -i '/^\[Peer\]/,$d' "$SERVER_CONF"
  rm -f /root/*_awg2.conf
  awg-quick up "$SERVER_CONF"
  ok "Удалено $count клиентов"
}

# ══════════════════════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════════════════════
CHOICE=""
CLIENT_DNS="1.1.1.1, 1.0.0.1"
AWG_VERSION="2.0"
I1=""
MIMICRY_PROFILE=""
AWG_PARAMS_LINES=""
ERROR_COUNT=0

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/awg-manager.log"
log_info "=== AWG Manager v4.2 запущен ==="

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
    9) do_clean_clients ;;
    0) log_info "Выход"; echo -e "\n${G}  Пока!${N}\n"; exit 0 ;;
    *) warn "Неверный выбор"; ERROR_COUNT=$((ERROR_COUNT+1)); [[ $ERROR_COUNT -ge 5 ]] && exit 1 ;;
  esac
  ERROR_COUNT=0
  CHOICE=""
  echo ""
  read -rp "$(echo -e "${C}  Enter для продолжения...${N}")"
done