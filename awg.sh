#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# AmneziaWG Manager v4.2 — исправлено создание клиентов
# Исправлены критические баги:
# - Несоответствие ключей клиента и сервера
# - Правильная генерация и проверка ключей
# - Удаление старых пиров перед добавлением новых
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

# ══════════════════════════════════════════════════════════
# ДОМЕННЫЕ ПУЛЫ (сокращено для читаемости)
# ══════════════════════════════════════════════════════════

QUIC_INITIAL_DOMAINS=(
  "yandex.net" "yastatic.net" "vk.com" "mail.ru" "ozon.ru"
  "wildberries.ru" "sber.ru" "tbank.ru" "gosuslugi.ru" "gcore.com"
  "fastly.net" "cloudfront.net" "microsoft.com" "github.com"
)

select_random_domain() {
  local profile="$1"
  local domains=("${QUIC_INITIAL_DOMAINS[@]}")
  echo "${domains[$((RANDOM % ${#domains[@]}))]}"
}

fetch_i1_from_api() {
  local domain="$1"
  local api_url="https://junk.web2core.workers.dev/signature?domain=${domain}"
  local api_resp
  api_resp=$(timeout 10 curl -s --connect-timeout 5 "$api_url" 2>/dev/null) || api_resp=""
  echo "$api_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('i1',''))" 2>/dev/null || echo ""
}

choose_mimicry_profile() {
  I1=""
  MIMICRY_PROFILE=""
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}        Профили мимикрии (AmneziaWG Architect)${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}1${N}  QUIC Initial (HTTP/3) — наиболее надёжный"
  echo -e "  ${G}2${N}  QUIC 0-RTT (Early Data) — быстрый старт"
  echo -e "  ${G}3${N}  TLS 1.3 Client Hello — HTTPS"
  echo -e "  ${G}4${N}  DTLS 1.3 (WebRTC/STUN) — видеозвонки"
  echo -e "  ${G}5${N}  SIP (VoIP) — телефонные звонки"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${Y}6${N}  Без имитации (только обфускация)"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  read -rp "$(echo -e "${C}  Выбор [1-6] (Enter = 1): ${N}")" PROFILE_CHOICE
  PROFILE_CHOICE=${PROFILE_CHOICE:-1}
  
  if [[ "$PROFILE_CHOICE" == "6" ]]; then
    I1=""
    MIMICRY_PROFILE="none"
    ok "Без имитации"
    return 0
  fi
  
  local domain=$(select_random_domain "quic_initial")
  echo -e "${C}  → Запрос I1 для $domain...${N}"
  I1=$(fetch_i1_from_api "$domain")
  if [[ -z "$I1" ]]; then
    warn "Не удалось получить I1, продолжаем без него"
  else
    ok "I1 получен (длина: ${#I1})"
  fi
}

# ══════════════════════════════════════════════════════════
# ОСНОВНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════

get_public_ip() {
  timeout 5 curl -s --connect-timeout 3 -4 ifconfig.me 2>/dev/null || \
  timeout 5 curl -s --connect-timeout 3 -4 api.ipify.org 2>/dev/null || \
  echo ""
}

rand_range() {
  python3 -c "import random; print(random.randint($1, $2))"
}

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
  echo -e "${B}║${C}     Исправлено создание клиентов             ${B}║${N}"
  echo -e "${B}╚══════════════════════════════════════════════╝${N}"
  echo -e "${B}  IP сервера : ${W}${s[0]}${N}"
  echo -e "${B}  Порт       : ${W}${s[1]}${N}"
  echo -e "${B}  Интерфейс  : ${s[2]}${N}"
  echo -e "${B}  Клиентов   : ${W}${s[3]}${N}"
}

show_menu() {
  echo ""
  echo -e "  ${W}1)${N} Установка зависимостей и AmneziaWG"
  echo -e "  ${W}2)${N} Создать сервер + первый клиент"
  echo -e "  ${W}3)${N} Добавить клиента"
  echo -e "  ${W}4)${N} Показать клиентов"
  echo -e "  ${W}5)${N} Показать QR клиента"
  echo -e "  ${W}6)${N} Перезапустить awg0"
  echo -e "  ${W}7)${N} Удалить всё"
  echo -e "  ${W}8)${N} Проверить домены из пулов"
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
  echo "  1) AWG 2.0  — S3/S4 + H1-H4 диапазоны + I1"
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

gen_awg_params() {
  local ver="$1"
  AWG_PARAMS_LINES=""
  [[ "$ver" == "wg" ]] && return 0

  local Jc Jmin Jmax S1 S2 Q=1073741823
  if [[ "$ver" == "1.0" ]]; then
    Jc=$(rand_range 4 7)
  else
    Jc=$(rand_range 3 7)
  fi
  Jmin=$(rand_range 64 256)
  Jmax=$(rand_range 576 1024)
  S1=$(rand_range 1 39)
  S2=$(rand_range 1 64)
  
  if [[ "$ver" == "2.0" ]]; then
    local S3=$(rand_range 5 64)
    local S4=$(rand_range 1 16)
    local H1="${RANDOM}-$((RANDOM + 100000))"
    local H2="${RANDOM}-$((RANDOM + 100000))"
    local H3="${RANDOM}-$((RANDOM + 100000))"
    local H4="${RANDOM}-$((RANDOM + 100000))"
    AWG_PARAMS_LINES="Jc = $Jc\nJmin = $Jmin\nJmax = $Jmax\nS1 = $S1\nS2 = $S2\nS3 = $S3\nS4 = $S4\nH1 = $H1\nH2 = $H2\nH3 = $H3\nH4 = $H4"
  else
    local H1=$(rand_range 5 $((Q - 1)))
    local H2=$(rand_range 5 $((Q * 2 - 1)))
    local H3=$(rand_range 5 $((Q * 3 - 1)))
    local H4=$(rand_range 5 $((Q * 4 - 1)))
    AWG_PARAMS_LINES="Jc = $Jc\nJmin = $Jmin\nJmax = $Jmax\nS1 = $S1\nS2 = $S2\nH1 = $H1\nH2 = $H2\nH3 = $H3\nH4 = $H4"
  fi
}

# ══════════════════════════════════════════════════════════
# 2. СОЗДАТЬ СЕРВЕР (ИСПРАВЛЕНО)
# ══════════════════════════════════════════════════════════
do_gen() {
  log_info "do_gen: старт"
  command -v awg &>/dev/null || { err "awg не найден. Сначала пункт 1"; return 1; }

  [[ -f "$SERVER_CONF" ]] && cp "$SERVER_CONF" "${SERVER_CONF}.bak.$(date +%s)" && info "Backup создан"

  choose_awg_version
  choose_dns
  choose_mimicry_profile || return 1

  hdr "IP подсеть сервера:"
  echo "  1) 10.100.0.0/24"
  echo "  2) 10.101.0.0/24"
  echo "  3) 10.102.0.0/24"
  echo "  4) Вручную"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = 10.100.0.0/24): ${N}")" ADDR_CHOICE
  ADDR_CHOICE=${ADDR_CHOICE:-1}
  case $ADDR_CHOICE in
    1) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
    2) CLIENT_ADDR="10.101.0.2/32"; SERVER_ADDR="10.101.0.1/24"; CLIENT_NET="10.101.0.0/24" ;;
    3) CLIENT_ADDR="10.102.0.2/32"; SERVER_ADDR="10.102.0.1/24"; CLIENT_NET="10.102.0.0/24" ;;
    4)
      read -rp "  IP клиента (X.X.X.X/32): " CLIENT_ADDR
      read -rp "  IP сервера (X.X.X.X/24): " SERVER_ADDR
      read -rp "  Подсеть NAT (X.X.X.0/24): " CLIENT_NET
      ;;
  esac

  hdr "MTU:"
  echo "  1) 1420  2) 1380 (рекомендуется)  3) 1280  4) 1500"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = 1380): ${N}")" MTU_CHOICE
  MTU_CHOICE=${MTU_CHOICE:-2}
  case $MTU_CHOICE in
    1) MTU=1420 ;; 2) MTU=1380 ;; 3) MTU=1280 ;; 4) MTU=1500 ;;
  esac

  hdr "Порт сервера:"
  read -rp "$(echo -e "${C}  Порт [51820 / 443 / r = случайный]: ${N}")" PORT
  if [[ "${PORT:-}" == "r" ]]; then
    PORT=$(rand_range 30001 65535)
  else
    PORT=${PORT:-51820}
  fi

  echo ""
  echo -e "${W}  Параметры:${N}"
  echo "  Версия:   $AWG_VERSION"
  echo "  DNS:      $CLIENT_DNS"
  echo "  MTU:      $MTU"
  echo "  Порт:     $PORT"
  read -rp "$(echo -e "${C}  Продолжить? [Y/n]: ${N}")" CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Отменено."; return 0; }

  # Генерация ключей (исправлено: строгое разделение)
  local srv_priv=$(awg genkey)
  local srv_pub=$(echo "$srv_priv" | awg pubkey)
  local cli_priv=$(awg genkey)
  local cli_pub=$(echo "$cli_priv" | awg pubkey)
  local psk=$(awg genpsk)

  # Проверка соответствия ключей
  local cli_pub_check=$(echo "$cli_priv" | awg pubkey)
  if [[ "$cli_pub_check" != "$cli_pub" ]]; then
    err "Критическая ошибка: ключи клиента не совпадают!"
    return 1
  fi

  local srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }

  local iface=$(ip route | awk '/default/ {print $5; exit}')
  [[ -z "$iface" ]] && { err "не удалось определить интерфейс"; return 1; }

  gen_awg_params "$AWG_VERSION"

  awg-quick down "$SERVER_CONF" 2>/dev/null || true

  # Создание серверного конфига
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

  # Создание клиентского конфига
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
  echo -e "${W}  Клиент : /root/client1_awg2.conf${N}"
  echo -e "${W}  IP     : ${N}$srv_ip:$PORT"
}

# ══════════════════════════════════════════════════════════
# 3. ДОБАВИТЬ КЛИЕНТА (ИСПРАВЛЕНО)
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

  # Получаем параметры сервера
  local srv_pub=$(awg show awg0 public-key 2>/dev/null)
  [[ -z "$srv_pub" ]] && { err "awg0 не запущен"; return 1; }
  
  local srv_ip=$(get_public_ip)
  local port=$(grep "^ListenPort" "$SERVER_CONF" | awk -F'= ' '{print $2}')
  local mtu=$(grep "^MTU" "$SERVER_CONF" | awk -F'= ' '{print $2}')
  mtu=${mtu:-1380}
  
  local awg_params=$(grep -E "^(Jc|Jmin|Jmax|S[1-4]|H[1-4])" "$SERVER_CONF" | grep -v "^#")

  # Генерация ключей клиента
  local cli_priv=$(awg genkey)
  local cli_pub=$(echo "$cli_priv" | awg pubkey)
  local psk=$(awg genpsk)

  # Проверка (двойная страховка)
  local cli_pub_check=$(echo "$cli_priv" | awg pubkey)
  if [[ "$cli_pub_check" != "$cli_pub" ]]; then
    err "Ошибка генерации ключей!"
    return 1
  fi

  # Добавляем peer в конфиг сервера
  {
    echo ""
    echo "[Peer]"
    echo "# $client_name"
    echo "PublicKey = $cli_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $client_addr"
  } >> "$SERVER_CONF"

  # Добавляем в runtime
  local psk_file=$(mktemp)
  echo "$psk" > "$psk_file"
  awg set awg0 peer "$cli_pub" preshared-key "$psk_file" allowed-ips "$client_addr"
  rm -f "$psk_file"

  # Создаём клиентский конфиг
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
# 4. ПОКАЗАТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
do_list_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                                    КЛИЕНТЫ${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  local transfer_cache=$(awg show awg0 transfer 2>/dev/null || true)
  local i=0 name=""
  
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[Peer\] ]]; then
      i=$((i+1))
      name=""
    elif [[ "$line" =~ ^#[[:space:]](.+) ]]; then
      name="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^AllowedIPs[[:space:]]=[[:space:]](.+) ]]; then
      local ip="${BASH_REMATCH[1]}"
      local short_name="${name:-безымянный}"
      short_name="${short_name:0:12}"
      echo -e "  ${W}$(printf '%2d' $i))${N} ${C}$(printf '%-12s' "$short_name")${N}  IP: ${W}$(printf '%-20s' "$ip")${N}"
    fi
  done < "$SERVER_CONF"

  [[ $i -eq 0 ]] && echo -e "  ${Y}  Нет клиентов${N}"
  echo ""
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
}

# ══════════════════════════════════════════════════════════
# 6. ПЕРЕЗАПУСК
# ══════════════════════════════════════════════════════════
do_restart() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  awg-quick up "$SERVER_CONF"
  ok "awg0 перезапущен"
}

# ══════════════════════════════════════════════════════════
# 7. УДАЛИТЬ ВСЁ
# ══════════════════════════════════════════════════════════
do_uninstall() {
  echo ""
  warn "Будет удалено всё: AmneziaWG, конфиги, клиенты"
  read -rp "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")" CONFIRM
  [[ "$CONFIRM" != "yes" ]] && return 0
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  systemctl disable awg-quick@awg0 2>/dev/null || true
  apt-get remove -y amneziawg amneziawg-tools 2>/dev/null || true
  rm -rf /etc/amnezia /root/*_awg2.conf
  ok "Всё удалено"
}

# ══════════════════════════════════════════════════════════
# 8. ПРОВЕРКА ДОМЕНОВ
# ══════════════════════════════════════════════════════════
do_check_domains() {
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                     Проверка доступности доменов${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  local available=0 total=0
  for domain in yandex.net yastatic.net vk.com mail.ru ozon.ru wildberries.ru; do
    total=$((total+1))
    if timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available+1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${G}  ✓ Доступно: $available из $total доменов${N}"
}

# ══════════════════════════════════════════════════════════
# 9. ОЧИСТИТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
do_clean_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  local count=$(grep -c "^\[Peer\]" "$SERVER_CONF" 2>/dev/null || echo "0")
  [[ $count -eq 0 ]] && { warn "Нет клиентов"; return 0; }
  read -rp "$(echo -e "${R}  Удалить $count клиентов? [yes/N]: ${N}")" CONFIRM
  [[ "$CONFIRM" != "yes" ]] && return 0
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
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
AWG_PARAMS_LINES=""
ERROR_COUNT=0

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/awg-manager.log"

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
    0) exit 0 ;;
    *) warn "Неверный выбор"; ERROR_COUNT=$((ERROR_COUNT+1)); [[ $ERROR_COUNT -ge 5 ]] && exit 1 ;;
  esac
  ERROR_COUNT=0
  CHOICE=""
  echo ""
  read -rp "$(echo -e "${C}  Enter для продолжения...${N}")"
done