#!/bin/bash
set -euo pipefail

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

# ── Получение публичного IP ────────────────────────────────
get_public_ip() {
  curl -s --connect-timeout 5 -4 ifconfig.me 2>/dev/null || \
  curl -s --connect-timeout 5 api.ipify.org 2>/dev/null || \
  curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || \
  echo ""
}

# ── Поиск свободного IP ────────────────────────────────────
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

# ── Статус сервера ─────────────────────────────────────────
get_status() {
  local ip port status clients
  ip=$(get_public_ip)
  [[ -z "$ip" ]] && ip="—"
  if ip link show awg0 &>/dev/null 2>&1; then
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
  local s
  s=$(get_status)
  local ip port st clients
  IFS='|' read -r ip port st clients <<< "$s"
  echo -e "${B}╔══════════════════════════════════════════════╗${N}"
  echo -e "${B}║${W}        AmneziaWG 2.0 Manager                ${B}║${N}"
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
  echo -e "  ${W}2)${N} Создать сервер + первый клиент"
  echo -e "  ${W}3)${N} Добавить клиента"
  echo -e "  ${W}4)${N} Показать клиентов"
  echo -e "  ${W}5)${N} Показать QR клиента"
  echo -e "  ${W}6)${N} Перезапустить awg0"
  echo -e "  ${W}7)${N} Удалить всё"
  echo -e "  ${W}0)${N} Выход"
  echo ""
  read -rp "$(echo -e "${C}  Выбор: ${N}")" CHOICE
}

# ══════════════════════════════════════════════════════════
# ОБЩИЕ: выбор DNS
# ══════════════════════════════════════════════════════════
choose_dns() {
  hdr "DNS для клиента:"
  echo "  1) Cloudflare  — 1.1.1.1, 1.0.0.1"
  echo "  2) Google      — 8.8.8.8, 8.8.4.4"
  echo "  3) OpenDNS     — 208.67.222.222, 208.67.220.220"
  echo "  4) Вручную"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = Cloudflare): ${N}")" DNS_CHOICE
  DNS_CHOICE=${DNS_CHOICE:-1}
  case $DNS_CHOICE in
    1) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
    2) CLIENT_DNS="8.8.8.8, 8.8.4.4" ;;
    3) CLIENT_DNS="208.67.222.222, 208.67.220.220" ;;
    4) read -rp "  DNS: " CLIENT_DNS ;;
    *) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
  esac
}

# ══════════════════════════════════════════════════════════
# ОБЩИЕ: выбор версии AWG
# Устанавливает глобальную AWG_VERSION: "wg" | "1.0" | "1.5" | "2.0"
# ══════════════════════════════════════════════════════════
choose_awg_version() {
  hdr "Версия протокола:"
  echo "  1) AWG 2.0  — S3/S4 + H1-H4 диапазоны + I1-I5  (рекомендуется)"
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
# ОБЩИЕ: генерация AWG параметров → глобальные переменные
# AWG_PARAMS_LINES — строки для записи в конфиг
# ══════════════════════════════════════════════════════════
gen_awg_params() {
  local ver="$1"
  AWG_PARAMS_LINES=""

  [[ "$ver" == "wg" ]] && return 0

  local Jc=$((RANDOM % 9 + 2))         # 2-10
  local Jmin=64
  local Jmax=$((RANDOM % 449 + 576))  # 576-1024
  local S1=$((RANDOM % 30 + 10))
  local S2_OFF=$((RANDOM % 63 + 1))
  [[ $S2_OFF -eq 56 ]] && S2_OFF=57
  local S2=$((S1 + S2_OFF))
  [[ $S2 -gt 64 ]] && S2=64
  local Q=1073741823

  if [[ "$ver" == "2.0" ]]; then
    local S3=$((RANDOM % 30 + 5))
    local S4=$((RANDOM % 16 + 1))
    local H1_S=$(( RANDOM * RANDOM % Q )); local H1_W=$(( RANDOM % 100000 + 30000 ))
    local H1="${H1_S}-$((H1_S + H1_W))"
    local H2_S=$(( Q + RANDOM * RANDOM % Q )); local H2_W=$(( RANDOM % 100000 + 30000 ))
    local H2="${H2_S}-$((H2_S + H2_W))"
    local H3_S=$(( Q * 2 + RANDOM * RANDOM % Q )); local H3_W=$(( RANDOM % 100000 + 30000 ))
    local H3="${H3_S}-$((H3_S + H3_W))"
    local H4_S=$(( Q * 3 + RANDOM * RANDOM % Q )); local H4_W=$(( RANDOM % 100000 + 30000 ))
    local H4="${H4_S}-$((H4_S + H4_W))"
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
  else
    local H1=$(( RANDOM * RANDOM % Q ))
    local H2=$(( Q + RANDOM * RANDOM % Q ))
    local H3=$(( Q * 2 + RANDOM * RANDOM % Q ))
    local H4=$(( Q * 3 + RANDOM * RANDOM % Q ))
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
# ОБЩИЕ: выбор I1 (только для AWG 1.5 и 2.0)
# ══════════════════════════════════════════════════════════
choose_i1() {
  hdr "Имитация протокола (I1):"
  echo "  1) Google DNS — статический (совместим со всеми)"
  echo "  2) Яндекс/Кинопоиск DNS — статический"
  echo "  3) API по домену — QUIC реальный пакет"
  echo "  4) Без имитации"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = Google): ${N}")" I1_CHOICE
  I1_CHOICE=${I1_CHOICE:-1}
  I1=""
  case $I1_CHOICE in
    2)
      I1='<b 0x084481800001000300000000077469636b65747306776964676574096b696e6f706f69736b0272750000010001c00c0005000100000039001806776964676574077469636b6574730679616e646578c025c0390005000100000039002b1765787465726e616c2d7469636b6574732d776964676574066166697368610679616e646578036e657400c05d000100010000001c000457fafe25>'
      ;;
    3)
      read -rp "  Домен (Enter = google.com): " API_DOMAIN
      API_DOMAIN=${API_DOMAIN:-google.com}
      info "запрос к API для $API_DOMAIN..."
      local api_resp
      api_resp=$(curl -s --connect-timeout 10 "https://junk.web2core.workers.dev/signature?domain=${API_DOMAIN}")
      I1=$(echo "$api_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('i1',''))" 2>/dev/null || true)
      if [[ -z "$I1" ]]; then
        warn "API недоступен, используем Google DNS"
        I1='<b 0x84050100000100000000000006676f6f676c6503636f6d0000010001>'
      else
        ok "I1 получен с API"
      fi
      ;;
    4) I1="" ;;
    *) I1='<b 0x84050100000100000000000006676f6f676c6503636f6d0000010001>' ;;
  esac
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
    net-tools curl ufw iptables qrencode </dev/null

  hdr "=== Kernel headers ==="
  apt-get install -y -q "linux-headers-$(uname -r)" 2>/dev/null || \
  apt-get install -y -q linux-headers-generic || \
  { err "не удалось установить linux-headers"; exit 1; }

  hdr "=== AmneziaWG (PPA) ==="
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -q
  apt-get install -y -q amneziawg amneziawg-tools

  if command -v awg &>/dev/null; then
    ok "amneziawg-tools: $(awg --version)"
  else
    err "awg не найден после установки"; exit 1
  fi

  hdr "=== Проверка модуля ==="
  if modprobe amneziawg; then
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
iptables -t nat -C POSTROUTING -o $ext_if -j MASQUERADE 2>/dev/null || \\
iptables -t nat -A POSTROUTING -o $ext_if -j MASQUERADE
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
# 2. СОЗДАТЬ СЕРВЕР
# ══════════════════════════════════════════════════════════
do_gen() {
  command -v awg &>/dev/null || { err "awg не найден. Сначала пункт 1"; return 1; }

  # Backup
  local bak_ts
  bak_ts="${SERVER_CONF}.bak.$(date +%s)"
  [[ -f "$SERVER_CONF" ]] && cp "$SERVER_CONF" "$bak_ts" && info "Backup: $bak_ts"

  choose_awg_version
  choose_dns

  # I1 только для 1.5 и 2.0
  I1=""
  if [[ "$AWG_VERSION" == "1.5" || "$AWG_VERSION" == "2.0" ]]; then
    choose_i1
  fi

  hdr "IP подсеть сервера:"
  echo "  1) 10.100.0.0/24"
  echo "  2) 10.101.0.0/24"
  echo "  3) 10.102.0.0/24"
  echo "  4) 10.103.0.0/24"
  echo "  5) Вручную"
  read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = 10.100.0): ${N}")" ADDR_CHOICE
  ADDR_CHOICE=${ADDR_CHOICE:-1}
  case $ADDR_CHOICE in
    1) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
    2) CLIENT_ADDR="10.101.0.2/32"; SERVER_ADDR="10.101.0.1/24"; CLIENT_NET="10.101.0.0/24" ;;
    3) CLIENT_ADDR="10.102.0.2/32"; SERVER_ADDR="10.102.0.1/24"; CLIENT_NET="10.102.0.0/24" ;;
    4) CLIENT_ADDR="10.103.0.2/32"; SERVER_ADDR="10.103.0.1/24"; CLIENT_NET="10.103.0.0/24" ;;
    5)
      read -rp "  IP клиента: " CLIENT_ADDR
      read -rp "  IP сервера: " SERVER_ADDR
      read -rp "  Подсеть NAT: " CLIENT_NET
      ;;
    *) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
  esac

  [[ "$CLIENT_NET" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || {
    err "только private сети (10.x, 192.168.x, 172.16-31.x)"
    return 1
  }

  hdr "MTU:"
  echo "  1) 1420 — стандартный"
  echo "  2) 1380 — лучше для мобильных"
  echo "  3) 1280 — максимальная совместимость"
  echo "  4) Вручную"
  read -rp "$(echo -e "${C}  Выбор [1-4] (Enter = 1380): ${N}")" MTU_CHOICE
  MTU_CHOICE=${MTU_CHOICE:-2}
  case $MTU_CHOICE in
    1) MTU=1420 ;; 2) MTU=1380 ;; 3) MTU=1280 ;;
    4) read -rp "  MTU: " MTU ;;
    *) MTU=1380 ;;
  esac

  hdr "Порт сервера:"
  read -rp "$(echo -e "${C}  Порт [51820 / r = случайный]: ${N}")" PORT
  if [[ "${PORT:-}" == "r" || "${PORT:-}" == "R" ]]; then
    PORT=$(( RANDOM % 35500 + 30001 ))
    ok "случайный порт: $PORT"
  else
    PORT=${PORT:-51820}
  fi

  echo ""
  echo -e "${W}  Параметры:${N}"
  echo "  Версия: $AWG_VERSION"
  echo "  DNS:    $CLIENT_DNS"
  echo "  Клиент: $CLIENT_ADDR"
  echo "  Сервер: $SERVER_ADDR"
  echo "  MTU:    $MTU"
  echo "  Порт:   $PORT"
  read -rp "$(echo -e "${C}  Продолжить? [Y/n]: ${N}")" CONFIRM
  CONFIRM=${CONFIRM:-y}
  [[ $CONFIRM != "y" && $CONFIRM != "Y" ]] && { warn "Отменено."; return 0; }

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

  # Генерируем параметры один раз — сервер и клиент должны совпадать
  AWG_PARAMS_LINES=""
  gen_awg_params "$AWG_VERSION"

  echo 1 > /proc/sys/net/ipv4/ip_forward
  grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p 2>/dev/null || warn "sysctl содержит лишние строки — проверь /etc/sysctl.conf"

  mkdir -p /etc/amnezia/amneziawg

  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  # Конфиг сервера
  {
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = $SERVER_ADDR"
    echo "ListenPort = $PORT"
    [[ -n "$AWG_PARAMS_LINES" ]] && echo "$AWG_PARAMS_LINES"
    [[ -n "$I1" ]] && echo "I1 = $I1"
    echo ""
    echo "PostUp   = ip link set dev awg0 mtu $MTU; echo 1 > /proc/sys/net/ipv4/ip_forward; iptables -t nat -C POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE; iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT"
    echo "PostDown = iptables -t nat -D POSTROUTING -s $CLIENT_NET -o $iface -j MASQUERADE; iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $cli_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $CLIENT_ADDR"
  } > "$SERVER_CONF"
  chmod 600 "$SERVER_CONF"

  # Конфиг клиента
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

  awg-quick up "$SERVER_CONF"

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
  echo -e "${W}  Сервер : ${N}$SERVER_CONF"
  echo -e "${W}  Клиент : ${N}/root/client1_awg2.conf"
  echo -e "${W}  IP     : ${N}$srv_ip:$PORT"
  echo -e "${W}  Iface  : ${N}$iface"

  systemctl enable awg-quick@awg0 2>/dev/null && ok "Автозапуск awg-quick@awg0 включён" || true
}

# ══════════════════════════════════════════════════════════
# 3. ДОБАВИТЬ КЛИЕНТА
# ══════════════════════════════════════════════════════════
do_add_client() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден. Сначала пункт 2"; return 1; }
  command -v awg  &>/dev/null || { err "awg не найден"; return 1; }
  command -v curl &>/dev/null || { err "curl не найден"; return 1; }

  local server_net base_ip client_addr
  server_net=$(grep "^Address" "$SERVER_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  base_ip=$(echo "$server_net" | cut -d. -f1-3)
  client_addr=$(find_free_ip "$base_ip") || { err "подсеть заполнена"; return 1; }

  echo ""
  info "Следующий свободный IP: $client_addr"

  local client_name
  read -rp "$(echo -e "${C}  Имя клиента (phone, laptop...): ${N}")" client_name
  [[ -z "$client_name" ]] && { err "имя не может быть пустым"; return 1; }
  [[ ! "$client_name" =~ ^[a-zA-Z0-9_-]+$ ]] && { err "только буквы, цифры, _ и -"; return 1; }

  read -rp "$(echo -e "${C}  Использовать IP $client_addr? [Y/n]: ${N}")" CONFIRM_IP
  CONFIRM_IP=${CONFIRM_IP:-y}
  if [[ ! $CONFIRM_IP =~ ^[Yy]$ ]]; then
    read -rp "  IP вручную (пример: ${base_ip}.5/32): " client_addr
  fi

  choose_dns

  # Определяем версию из серверного конфига автоматически
  local detected_ver="wg"
  if grep -q "^S3 " "$SERVER_CONF" 2>/dev/null; then
    detected_ver="2.0"
  elif grep -q "^I1 " "$SERVER_CONF" 2>/dev/null; then
    detected_ver="1.5"
  elif grep -q "^Jc " "$SERVER_CONF" 2>/dev/null; then
    detected_ver="1.0"
  fi
  info "Версия сервера: $detected_ver — клиент будет совместим"

  # I1 только для 1.5 и 2.0
  local i1_line=""
  if [[ "$detected_ver" == "1.5" || "$detected_ver" == "2.0" ]]; then
    hdr "Имитация протокола (I1):"
    echo "  1) Google DNS — статический (совместим со всеми)"
    echo "  2) Яндекс/Кинопоиск DNS — статический"
    echo "  3) API по домену — QUIC реальный пакет"
    echo "  4) Из серверного конфига"
    echo "  5) Без имитации"
    read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = Google): ${N}")" I1_CHOICE
    I1_CHOICE=${I1_CHOICE:-1}
    case $I1_CHOICE in
      1) i1_line="I1 = <b 0x84050100000100000000000006676f6f676c6503636f6d0000010001>" ;;
      2) i1_line="I1 = <b 0x084481800001000300000000077469636b65747306776964676574096b696e6f706f69736b0272750000010001c00c0005000100000039001806776964676574077469636b6574730679616e646578c025c0390005000100000039002b1765787465726e616c2d7469636b6574732d776964676574066166697368610679616e646578036e657400c05d000100010000001c000457fafe25>" ;;
      3)
        read -rp "  Домен (Enter = google.com): " API_DOMAIN
        API_DOMAIN=${API_DOMAIN:-google.com}
        info "запрос к API для $API_DOMAIN..."
        local api_resp i1_val
        api_resp=$(curl -s --connect-timeout 10 "https://junk.web2core.workers.dev/signature?domain=${API_DOMAIN}")
        i1_val=$(echo "$api_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('i1',''))" 2>/dev/null || true)
        if [[ -z "$i1_val" ]]; then
          warn "API недоступен, используем Google DNS"
          i1_line="I1 = <b 0x84050100000100000000000006676f6f676c6503636f6d0000010001>"
        else
          i1_line="I1 = ${i1_val}"
          ok "I1 получен с API"
        fi
        ;;
      4) i1_line=$(grep "^I1 " "$SERVER_CONF" || true) ;;
      5) i1_line="" ;;
      *) i1_line="I1 = <b 0x84050100000100000000000006676f6f676c6503636f6d0000010001>" ;;
    esac
  fi

  local srv_pub srv_ip port mtu
  srv_pub=$(awg show awg0 public-key 2>/dev/null) \
    || { err "awg0 не поднят. Запусти: awg-quick up $SERVER_CONF"; return 1; }
  srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }
  port=$(grep "^ListenPort" "$SERVER_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  [[ -z "$port" ]] && { err "не найден ListenPort в конфиге"; return 1; }
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

  awg set awg0 peer "$cli_pub" \
    preshared-key <(echo "$psk") \
    allowed-ips "$client_addr" \
    || { err "не удалось добавить peer в runtime"; return 1; }

  local client_file="/root/${client_name}_awg2.conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $cli_priv"
    echo "Address = $client_addr"
    echo "DNS = $CLIENT_DNS"
    echo "MTU = $mtu"
    grep -E "^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4) " "$SERVER_CONF" | head -12 || true
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
  echo -e "${W}  DNS    : ${N}$CLIENT_DNS"
  echo -e "${W}  Конфиг : ${N}$client_file"
}

# ══════════════════════════════════════════════════════════
# 4. ПОКАЗАТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
do_list_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  hdr "Клиенты:"
  echo ""

  local i=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[Peer\] ]]; then
      i=$((i+1))
      local name="" pubkey="" ip="" tx="" rx=""
    elif [[ "$line" =~ ^#\ (.+) ]]; then
      name="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^PublicKey\ =\ (.+) ]]; then
      pubkey="${BASH_REMATCH[1]}"
      local tx_raw rx_raw
      tx_raw=$(awg show awg0 transfer 2>/dev/null | grep "$pubkey" | awk '{print $2}' || echo "0")
      rx_raw=$(awg show awg0 transfer 2>/dev/null | grep "$pubkey" | awk '{print $3}' || echo "0")
      tx=$(awk "BEGIN {printf \"%.2f МБ\", $tx_raw/1048576}")
      rx=$(awk "BEGIN {printf \"%.2f МБ\", $rx_raw/1048576}")
    elif [[ "$line" =~ ^AllowedIPs\ =\ (.+) ]]; then
      ip="${BASH_REMATCH[1]}"
      local short_name
      short_name="${name:-безымянный}"
      short_name="${short_name:0:7}"
      local tx_fmt rx_fmt
      if awk "BEGIN {exit !($tx_raw >= 1073741824)}"; then
        tx_fmt=$(awk "BEGIN {printf \"%.2f ГБ\", $tx_raw/1073741824}")
      else
        tx_fmt=$(awk "BEGIN {printf \"%.2f МБ\", $tx_raw/1048576}")
      fi
      if awk "BEGIN {exit !($rx_raw >= 1073741824)}"; then
        rx_fmt=$(awk "BEGIN {printf \"%.2f ГБ\", $rx_raw/1073741824}")
      else
        rx_fmt=$(awk "BEGIN {printf \"%.2f МБ\", $rx_raw/1048576}")
      fi
      echo -e "  ${W}$(printf '%2d' $i))${N} ${C}$(printf '%-7s' "$short_name")${N}  IP: ${W}$(printf '%-20s' "$ip")${N}  ↑ $(printf '%-12s' "$tx_fmt")  ↓ $rx_fmt"
    fi
  done < "$SERVER_CONF"

  [[ $i -eq 0 ]] && warn "Клиентов нет"
  echo ""
}

# ══════════════════════════════════════════════════════════
# 5. QR КЛИЕНТА
# ══════════════════════════════════════════════════════════
do_show_qr() {
  command -v qrencode &>/dev/null || { err "qrencode не установлен"; return 1; }
  local files=(/root/*_awg2.conf /root/client1_awg2.conf)
  local found=()
  for f in "${files[@]}"; do
    [[ -f "$f" ]] && found+=("$f")
  done
  local unique
  mapfile -t unique < <(printf "%s\n" "${found[@]}" | sort -u)

  [[ ${#unique[@]} -eq 0 ]] && { err "конфиги клиентов не найдены в /root/"; return 1; }

  hdr "Выбери конфиг:"
  local i=0
  for f in "${unique[@]}"; do
    i=$((i+1))
    echo "  $i) $(basename "$f")"
  done
  read -rp "$(echo -e "${C}  Выбор [1-$i]: ${N}")" QR_CHOICE
  [[ "$QR_CHOICE" =~ ^[0-9]+$ ]] && [[ "$QR_CHOICE" -ge 1 ]] && [[ "$QR_CHOICE" -le $i ]] \
    || { err "неверный выбор (1-$i)"; return 1; }
  local idx=$((QR_CHOICE - 1))
  local chosen="${unique[$idx]}"
  [[ ! -f "$chosen" ]] && { err "неверный выбор"; return 1; }

  qrencode -t ansiutf8 -s 1 -m 1 < "$chosen"
  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo -e "${W}  Или сохрани текст ниже в файл client.conf${N}"
  echo -e "${W}  и импортируй в AmneziaVPN: Добавить туннель → Из файла${N}"
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo ""
  cat "$chosen"
  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  ok "$chosen"
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
  echo "  — /root/*_awg2.conf, /root/client1_awg2.conf"
  echo "  — /etc/network/if-pre-up.d/iptables-nat"
  echo "  — автозапуск awg-quick@awg0"
  echo "  — UFW правила AmneziaWG"
  echo ""
  read -rp "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")" CONFIRM_DEL
  [[ "$CONFIRM_DEL" != "yes" ]] && { warn "Отменено."; return 0; }

  info "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  info "Отключаем автозапуск..."
  systemctl disable awg-quick@awg0 2>/dev/null || true

  info "Удаляем пакеты..."
  apt-get remove -y -q amneziawg amneziawg-tools 2>/dev/null || true
  apt-get autoremove -y -q 2>/dev/null || true

  info "Удаляем конфиги сервера..."
  rm -rf /etc/amnezia 2>/dev/null || true

  info "Удаляем конфиги клиентов..."
  rm -f /root/*_awg2.conf /root/client1_awg2.conf 2>/dev/null || true

  info "Удаляем NAT hook..."
  rm -f /etc/network/if-pre-up.d/iptables-nat 2>/dev/null || true

  info "Удаляем UFW правила AmneziaWG..."
  ufw status numbered 2>/dev/null | grep -i "AmneziaWG" | \
    awk -F'[][]' '{print $2}' | sort -rn | \
    while read -r num; do
      ufw --force delete "$num" 2>/dev/null || true
    done || true

  info "Удаляем NAT iptables правила..."
  local ext_if
  ext_if=$(ip route | awk '/default/ {print $5; exit}' 2>/dev/null) || true
  if [[ -n "$ext_if" ]]; then
    iptables -t nat -D POSTROUTING -o "$ext_if" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true
  fi

  echo ""
  ok "Всё удалено"
}


do_restart() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  info "Перезапуск awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  awg-quick up "$SERVER_CONF"
  ok "awg0 перезапущен"
}

# ══════════════════════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════════════════════
while true; do
  show_header
  show_menu
  case ${CHOICE:-} in
    1) do_install ;;
    2) do_gen ;;
    3) do_add_client ;;
    4) do_list_clients ;;
    5) do_show_qr ;;
    6) do_restart ;;
    7) do_uninstall ;;
    0) echo -e "\n${G}  Пока!${N}\n"; exit 0 ;;
    *) warn "Неверный выбор" ;;
  esac
  echo ""
  read -rp "$(echo -e "${C}  Enter для продолжения...${N}")"
done
