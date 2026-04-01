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
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
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
  CLIENT_DNS=""
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
  AWG_VERSION=""
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

choose_mimicry_profile() {
  I1=""
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}        Профили мимикрии (AmneziaWG Architect)${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}1${N}  QUIC Initial (HTTP/3) — наиболее надёжный"
  echo -e "  ${G}2${N}  Без имитации (только обфускация)"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  read -rp "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" PROFILE_CHOICE
  PROFILE_CHOICE=${PROFILE_CHOICE:-1}
  
  if [[ "$PROFILE_CHOICE" == "2" ]]; then
    I1=""
    ok "Без имитации"
    return 0
  fi
  
  local domain="google.com"
  echo -e "${C}  → Запрос I1 для $domain...${N}"
  local api_resp=$(timeout 10 curl -s --connect-timeout 5 "https://junk.web2core.workers.dev/signature?domain=$domain" 2>/dev/null || echo "")
  I1=$(echo "$api_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('i1',''))" 2>/dev/null || echo "")
  if [[ -z "$I1" ]]; then
    warn "Не удалось получить I1, продолжаем без него"
  else
    ok "I1 получен (длина: ${#I1})"
  fi
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
    local H1=$(rand_range 5 $((Q - 1)))
    local H2=$(rand_range 5 $((Q * 2 - 1)))
    local H3=$(rand_range 5 $((Q * 3 - 1)))
    local H4=$(rand_range 5 $((Q * 4 - 1)))
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
# 2. СОЗДАТЬ СЕРВЕР
# ══════════════════════════════════════════════════════════
do_gen() {
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
  echo -e "${W}  Клиент : /root/client1_awg2.conf${N}"
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
# 4. ПОКАЗАТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
do_list_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                                    КЛИЕНТЫ${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

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