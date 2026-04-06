#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# - AmneziaWG Manager v5.1 — только AWG 2.0
# - CPS генератор I1-I5 (порт из AmneziaWG Architect)
# - I1 только в клиентском конфиге (по спецификации Amnezia)
# - Регион РФ / Мир — разные пулы доменов
# - Бекап и восстановление конфигов AWG 2.0 (~/awg_backup/)
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
# ДОМЕННЫЕ ПУЛЫ ДЛЯ МИМИКРИИ
# ══════════════════════════════════════════════════════════

# Россия
TLS_DOMAINS_RU=(
  "yandex.ru" "vk.com" "mail.ru" "ozon.ru" "wildberries.ru"
  "sberbank.ru" "tbank.ru" "gosuslugi.ru" "kaspersky.ru"
)
DTLS_DOMAINS_RU=(
  "stun.yandex.net" "stun.vk.com" "stun.mail.ru" "stun.sber.ru"
)
SIP_DOMAINS_RU=(
  "sip.beeline.ru" "sip.mts.ru" "sip.megafon.ru" "sip.rostelecom.ru"
  "sip.yandex.ru" "sip.vk.com" "sip.mail.ru" "sip.sipnet.ru"
)

# Европа / Мир
TLS_DOMAINS_WORLD=(
  "github.com" "gitlab.com" "stackoverflow.com" "microsoft.com"
  "apple.com" "amazon.com" "cloudflare.com" "google.com"
  "wikipedia.org" "netflix.com" "spotify.com" "discord.com"
)
DTLS_DOMAINS_WORLD=(
  "stun.stunprotocol.org" "meet.jit.si" "stun.services.mozilla.com"
  "stun.l.google.com" "stun1.l.google.com"
)
SIP_DOMAINS_WORLD=(
  "sip.zadarma.com" "sip.iptel.org" "sip.linphone.org"
  "sip.antisip.com" "sip.cloudflare.com"
)

# Активные пулы (устанавливаются при выборе региона)
TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_WORLD[@]}")
DTLS_DOMAINS=("${DTLS_DOMAINS_WORLD[@]}")
SIP_DOMAINS=("${SIP_DOMAINS_WORLD[@]}")

# Глобальная переменная региона
SERVER_REGION="world"

choose_region() {
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                  Регион сервера${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}1${N}  Европа / Мир  — глобальные домены (рекомендуется)"
  echo -e "  ${G}2${N}  Россия        — RU домены"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  local REGION_CHOICE
  read -rp "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" REGION_CHOICE
  REGION_CHOICE=${REGION_CHOICE:-1}
  case $REGION_CHOICE in
    2)
      SERVER_REGION="ru"
      TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_RU[@]}")
      DTLS_DOMAINS=("${DTLS_DOMAINS_RU[@]}")
      SIP_DOMAINS=("${SIP_DOMAINS_RU[@]}")
      echo -e "${G}  ✓ Регион: Россия${N}"
      ;;
    *)
      SERVER_REGION="world"
      TLS_CLIENT_HELLO_DOMAINS=("${TLS_DOMAINS_WORLD[@]}")
      DTLS_DOMAINS=("${DTLS_DOMAINS_WORLD[@]}")
      SIP_DOMAINS=("${SIP_DOMAINS_WORLD[@]}")
      echo -e "${G}  ✓ Регион: Европа / Мир${N}"
      ;;
  esac
}

select_random_domain() {
  local profile="$1"
  local domains=()
  case "$profile" in
    "tls")  domains=("${TLS_CLIENT_HELLO_DOMAINS[@]}") ;;
    "dtls") domains=("${DTLS_DOMAINS[@]}") ;;
    "sip")  domains=("${SIP_DOMAINS[@]}") ;;
    *)      domains=("${TLS_CLIENT_HELLO_DOMAINS[@]}") ;;
  esac
  echo "${domains[$((RANDOM % ${#domains[@]}))]}"
}

# ══════════════════════════════════════════════════════════
# CPS ГЕНЕРАТОР I1-I5 (порт из AmneziaWG Architect)
# Автор оригинала: Vadim-Khristenko
# I1 только в клиентском конфиге — сервер не требует
# ══════════════════════════════════════════════════════════

# Единый Python генератор для всех профилей мимикрии
_CPS_GENERATOR='
import sys, random, math

# Browser Fingerprint (BFP) как в оригинальном TS (профиль Chrome / Yandex Desktop)
BFP = {
    "qi": [1250, 1250],  # QUIC Initial всегда ровно 1250 байт
    "q0": [1250, 1350],  # QUIC 0-RTT
    "h3": [1250, 1350],  # HTTP/3 DATA
    "tls": [512, 800],   # TLS Client Hello
    "dtls": [1100, 1200] # DTLS
}

def rnd(a, b): return random.randint(a, b)
def rh(n): return "".join(f"{random.randint(0,255):02x}" for _ in range(max(0, n)))
def hex_pad(v, bl): return format(int(v), f"0{bl*2}x")[-bl*2:]
def align_128(n): return math.ceil(n / 128) * 128

def split_pad(n, tag="r"):
    n = max(0, int(n))
    if n == 0: return ""
    out = ""
    while n > 1000: 
        out += f"<{tag} 1000>"
        n -= 1000
    out += f"<{tag} {n}>"
    return out

def calc_padding(header_b, extra_b, fp_range, iv, mtu):
    max_pad = max(0, mtu - header_b - extra_b)
    if not fp_range:
        return min(rnd(20, 80) * iv, 500, max_pad)
    
    c_mn, c_mx = min(fp_range[0], mtu), min(fp_range[1], mtu)
    needed = max(0, c_mn - (header_b + extra_b))
    jitter = max(0, min(c_mx - c_mn, c_mx - (header_b + extra_b) - needed, 20))
    pad = needed + (rnd(0, jitter) if jitter > 0 else 0)
    return min(pad, max_pad)

def mk_quic_initial(host, mtu, iv=2):
    dcid, scid = rnd(8, 20), rnd(0, 20)
    tlen = 0 if rnd(0, 1) == 0 else rnd(8, 32)
    sni_rc = min(len(host) + rnd(0, 6), 64)
    hx = hex_pad(0xc0 | rnd(0, 3), 1) + "00000001" + \
         hex_pad(dcid, 1) + rh(dcid) + hex_pad(scid, 1) + rh(scid) + \
         hex_pad(tlen, 1) + rh(tlen) + rh(4)
    
    # 4 байта overhead от тега <t>
    pad = calc_padding(len(hx)//2, sni_rc + 4, BFP["qi"], iv, mtu)
    return f"<b 0x{hx}><rc {sni_rc}><t>{split_pad(pad)}"

def mk_quic_0rtt(host, mtu, iv=2):
    dcid, scid = rnd(8, 20), rnd(0, 20)
    thint = min(len(host) + rnd(4, 16), 48)
    hx = hex_pad(0xd0 | rnd(0, 3), 1) + "00000001" + \
         hex_pad(dcid, 1) + rh(dcid) + hex_pad(scid, 1) + rh(scid) + rh(4)
    
    pad = calc_padding(len(hx)//2, thint + 4, BFP["q0"], iv, mtu)
    return f"<b 0x{hx}><t>{split_pad(pad)}<rc {thint}>"

def mk_http3(host, mtu, iv=2):
    ptypes = [0xc0, 0xc1, 0xc2, 0xc3, 0xe0, 0xe1, 0xe2]
    dcid, scid = rnd(8, 20), rnd(0, 20)
    sni_rc = min(len(host) + 9 + rnd(0, 6), 64)
    hx = hex_pad(random.choice(ptypes), 1) + "00000001" + \
         hex_pad(dcid, 1) + rh(dcid) + hex_pad(scid, 1) + rh(scid) + rh(4)
    
    pad = calc_padding(len(hx)//2, sni_rc + 4, BFP["h3"], iv, mtu)
    return f"<b 0x{hx}><rc {sni_rc}>{split_pad(pad)}<t>"

def mk_tls(host, mtu, iv=2):
    sni_rc = min(2+2+2+1+2+len(host), 64)
    base_len = rnd(BFP["tls"][0], BFP["tls"][1])
    rec_len = align_128(base_len)
    hs_len = rec_len - rnd(4, 9)
    r_len = min(rnd(20, 60)*iv, 300, max(0, mtu - 44 - sni_rc - 4))
    
    hx = "160301" + hex_pad(rec_len, 2) + "01" + hex_pad(hs_len, 3) + "0303" + rh(32)
    return f"<b 0x{hx}><rc {sni_rc}>{split_pad(r_len)}<t>"

def mk_dtls(host, mtu, iv=2):
    frag_len = rnd(100, 300)
    sni_rc = min(len(host) + rnd(2, 8), 60)
    hx = "16fefd" + hex_pad(rnd(0,255), 2) + rh(6) + hex_pad(frag_len, 2) + \
         "01" + rh(6) + "fefd0000" + rh(4) + rh(32)
    
    pad = calc_padding(len(hx)//2, sni_rc + 4, BFP["dtls"], iv, mtu)
    return f"<b 0x{hx}><rc {sni_rc}><t>{split_pad(pad)}"

def mk_sip(host, mtu, iv=2):
    hx = "5245474953544552207369703a" + "".join(f"{ord(c):02x}" for c in host) + "20" + rh(4)
    rc_val = min(len(host) + rnd(8, 24)*iv, 150)
    r_len = min(rnd(5, 30)*iv, 120, max(0, mtu - (len(hx)//2) - rc_val - 4))
    return f"<b 0x{hx}><rc {rc_val}><t>{split_pad(r_len)}"

def mk_dns(host, mtu, iv=2):
    q_name = "".join(f"{len(l):02x}"+"".join(f"{ord(c):02x}" for c in l) for l in host.split(".")) + "00"
    q_type = "0001" if iv % 2 == 0 else "001c"
    hx = rh(2) + "01000001000000000000" + q_name + q_type + "0001"
    
    target_size = rnd(64, min(512, mtu - 20))
    r_len = max(0, target_size - (len(hx)//2))
    return f"<b 0x{hx}>" + (split_pad(min(r_len, 200)) if r_len > 0 else "") + "<t>"

def mk_entropy(mtu, idx, iv=2):
    is_big = rnd(1, 10) > 6
    base_len = rnd(200, 500) if is_big else rnd(4, 20)
    r_len = min(base_len*iv, 500 if is_big else 60, max(0, mtu - 20 - 4))
    
    rc_len = rnd(4, 12)
    t, r, rc = "<t>", split_pad(r_len), f"<rc {rc_len}>"
    b = f"<b 0x{rh(rnd(4, 8*iv))}>" if iv >= 2 else ""
    b2 = f"<b 0x{rh(rnd(2, 4))}>" if iv >= 3 else ""
    
    # Паттерны перестановки только поддерживаемых тегов
    pats = [
        b+r+t+rc, t+b+r+rc, rc+b+r+t, t+r+rc+b,
        r+rc+b+t, b2+t+r+b+rc, b+rc+r+t+b2, b+b2+t+rc+r
    ]
    return pats[(idx + rnd(0, len(pats)-1)) % len(pats)] or "<r 10>"

# --- Основная логика ---
profile = sys.argv[1]
host = sys.argv[2]
mtu = int(sys.argv[3]) if len(sys.argv) > 3 else 1340
iv = 2

if profile == "quic":
    print(mk_quic_initial(host, mtu, iv))
    print(mk_quic_0rtt(host, mtu, iv))
    print(mk_http3(host, mtu, iv))
    print(mk_entropy(mtu, 3, iv))
    print(mk_entropy(mtu, 4, iv))
    
elif profile == "tls":
    print(mk_tls(host, mtu, iv))
    print(mk_quic_initial(host, mtu, iv))
    print(mk_entropy(mtu, 2, iv))
    print(mk_entropy(mtu, 3, iv))
    print(mk_entropy(mtu, 4, iv))
    
elif profile == "dtls":
    print(mk_dtls(host, mtu, iv))
    print(mk_entropy(mtu, 1, iv))
    print(mk_entropy(mtu, 2, iv))
    print(mk_entropy(mtu, 3, iv))
    print(mk_entropy(mtu, 4, iv))
    
elif profile == "sip":
    print(mk_sip(host, mtu, iv))
    print(mk_entropy(mtu, 1, iv))
    print(mk_entropy(mtu, 2, iv))
    print(mk_entropy(mtu, 3, iv))
    print(mk_entropy(mtu, 4, iv))
    
elif profile == "dns":
    print(mk_dns(host, mtu, iv))
    print(mk_dns(host, mtu, iv+1))
    print(mk_dns(host, mtu, iv+2))
    print(mk_entropy(mtu, 3, iv))
    print(mk_entropy(mtu, 4, iv))
    
else:
    print(mk_tls(host, mtu, iv))
    print(mk_entropy(mtu, 1, iv))
    print(mk_entropy(mtu, 2, iv))
    print(mk_entropy(mtu, 3, iv))
    print(mk_entropy(mtu, 4, iv))
'

# Генерация I1-I5 через Python
gen_cps_i1() {
  local profile="$1"
  local host="$2"
  local mtu="${3:-1340}"
  python3 -c "$_CPS_GENERATOR" "$profile" "$host" "$mtu"
}

# ══════════════════════════════════════════════════════════
# ВЫБОР ТИПА I1 ПРИ РУЧНОМ ВВОДЕ ДОМЕНА
# ══════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════
# ВЫБОР ТИПА I1 ПРИ РУЧНОМ ВВОДЕ ДОМЕНА
# ══════════════════════════════════════════════════════════
choose_i1_type_for_domain() {
  local domain="$1"
  local cps_out profile_key

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}        Выбор типа I1 для домена: ${C}$domain${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}1${N}  TLS 1.3 Client Hello   — HTTPS (рекомендуется)"
  echo -e "  ${G}2${N}  QUIC Initial           — HTTP/3, UDP 443"
  echo -e "  ${G}3${N}  DTLS 1.3 Handshake     — WebRTC / STUN"
  echo -e "  ${G}4${N}  SIP (VoIP Signaling)   — SIP REGISTER"
  echo -e "  ${G}5${N}  DNS Query              — UDP port 53"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

  local I1_TYPE_CHOICE
  read -rp "$(echo -e "${C}  Тип I1 [1-5] (Enter = 1): ${N}")" I1_TYPE_CHOICE
  I1_TYPE_CHOICE=${I1_TYPE_CHOICE:-1}

  case $I1_TYPE_CHOICE in
    1) profile_key="tls"  ;;
    2) profile_key="quic" ;;
    3) profile_key="dtls" ;;
    4) profile_key="sip"  ;;
    5) profile_key="dns"  ;;
    *) profile_key="tls"  ;;
  esac

  info "Генерируем CPS I1-I5 (${profile_key}) для $domain..."
  cps_out=$(gen_cps_i1 "$profile_key" "$domain" "${MTU:-1340}") || cps_out=""

  if [[ -z "$cps_out" ]]; then
    warn "Не удалось сгенерировать I1"
    I1=""; I2=""; I3=""; I4=""; I5=""
    return 0
  fi

  I1=$(echo "$cps_out" | sed -n '1p')
  I2=$(echo "$cps_out" | sed -n '2p')
  I3=$(echo "$cps_out" | sed -n '3p')
  I4=$(echo "$cps_out" | sed -n '4p')
  I5=$(echo "$cps_out" | sed -n '5p')

  ok "I1 готов (${#I1} байт)"
}

# ══════════════════════════════════════════════════════════
# ВЫБОР ПРОФИЛЯ МИМИКРИИ + ГЕНЕРАЦИЯ I1
# ══════════════════════════════════════════════════════════
choose_mimicry_profile() {
  I1=""; I2=""; I3=""; I4=""; I5=""
  MIMICRY_PROFILE=""
  MIMICRY_DOMAIN=""

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}        Профили мимикрии (AmneziaWG Architect)${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}1${N}  TLS 1.3 Client Hello — HTTPS (рекомендуется)"
  echo -e "  ${G}2${N}  DTLS 1.3 (WebRTC/STUN) — видеозвонки"
  echo -e "  ${G}3${N}  SIP (VoIP) — телефонные звонки"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${Y}4${N}  Случайный домен из любого пула"
  echo -e "  ${Y}5${N}  Ручной ввод домена + выбор типа I1"
  echo -e "  ${Y}6${N}  Без имитации (только обфускация)"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

  read -rp "$(echo -e "${C}  Выбор [1-6] (Enter = 1): ${N}")" PROFILE_CHOICE
  PROFILE_CHOICE=${PROFILE_CHOICE:-1}

  local domain=""
  case $PROFILE_CHOICE in
    1)
      MIMICRY_PROFILE="tls"
      domain=$(select_random_domain "tls")
      echo -e "${C}  → TLS 1.3, домен: ${W}$domain${N}"
      ;;
    2)
      MIMICRY_PROFILE="dtls"
      domain=$(select_random_domain "dtls")
      echo -e "${C}  → DTLS, домен: ${W}$domain${N}"
      ;;
    3)
      MIMICRY_PROFILE="sip"
      domain=$(select_random_domain "sip")
      echo -e "${C}  → SIP, домен: ${W}$domain${N}"
      ;;
    4)
      local profiles=("tls" "dtls" "sip")
      MIMICRY_PROFILE="${profiles[$((RANDOM % ${#profiles[@]}))]}"
      domain=$(select_random_domain "$MIMICRY_PROFILE")
      echo -e "${C}  → Случайный профиль: ${W}$MIMICRY_PROFILE${N}, домен: ${W}$domain${N}"
      ;;
    5)
      read -rp "$(echo -e "${C}  Введите домен (например: cloudflare.com): ${N}")" domain
      if [[ -z "$domain" ]]; then
        warn "Домен не введён"
        return 1
      fi
      MIMICRY_PROFILE="manual"
      MIMICRY_DOMAIN="$domain"
      echo -e "${C}  → Ручной ввод: ${W}$domain${N}"
      choose_i1_type_for_domain "$domain"
      return 0
      ;;
    6)
      I1=""
      MIMICRY_PROFILE="none"
      echo -e "${G}  ✓ Без имитации${N}"
      return 0
      ;;
    *)
      MIMICRY_PROFILE="tls"
      domain=$(select_random_domain "tls")
      echo -e "${C}  → По умолчанию: TLS 1.3, домен: ${W}$domain${N}"
      ;;
  esac

  # Генерация I1-I5 через CPS генератор (AmneziaWG Architect порт)
  # I1 только в клиентском конфиге — сервер не требует
  if [[ "$PROFILE_CHOICE" != "6" ]] && [[ -n "$domain" ]]; then
    echo -e "${C}  → Генерируем CPS I1-I5 (${MIMICRY_PROFILE}) для $domain...${N}"
    local cps_out
    cps_out=$(gen_cps_i1 "$MIMICRY_PROFILE" "$domain" "${MTU:-1340}") || cps_out=""
    if [[ -n "$cps_out" ]]; then
      I1=$(echo "$cps_out" | sed -n '1p')
      I2=$(echo "$cps_out" | sed -n '2p')
      I3=$(echo "$cps_out" | sed -n '3p')
      I4=$(echo "$cps_out" | sed -n '4p')
      I5=$(echo "$cps_out" | sed -n '5p')
      echo -e "${G}  ✓ I1-I5 готовы (I1: ${#I1} байт)${N}"
    else
      warn "Не удалось сгенерировать I1-I5"
      I1=""; I2=""; I3=""; I4=""; I5=""
    fi
  fi
}

# ══════════════════════════════════════════════════════════
# ОСТАЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════

get_public_ip() {
  local ip=""
  ip=$(timeout 5 curl -s --connect-timeout 3 -4 ifconfig.me 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
  ip=$(timeout 5 curl -s --connect-timeout 3 -4 api.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
  ip=$(timeout 5 curl -s --connect-timeout 3 -4 ipinfo.io/ip 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
  echo ""
}

rand_range() {
  local lo="$1" hi="$2"
  python3 -c "import random; print(random.randint($lo, $hi))"
}

find_free_ip() {
  local base="$1"
  local srv_ip_oct=""
  if [[ -f "$SERVER_CONF" ]]; then
    local srv_addr
    srv_addr=$(grep "^Address" "$SERVER_CONF" | awk -F'=' '{print $2}' | tr -d ' ' | head -1)
    srv_ip_oct=$(echo "$srv_addr" | grep -oE '[0-9]+' | tail -1)
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
  [[ -z "$ip" ]] && ip="—"
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

show_header() {
  clear
  local s ip port st clients
  s=$(get_status)
  IFS='|' read -r ip port st clients <<< "$s"
  echo -e "${B}╔══════════════════════════════════════════════╗${N}"
  echo -e "${B}║${W}        AmneziaWG Manager v5.0                ${B}║${N}"
  echo -e "${B}║${C}       AWG 2.0 only — TLS/DTLS/SIP/DNS         ${B}║${N}"
  echo -e "${B}╚══════════════════════════════════════════════╝${N}"
  echo -e "${B}  IP сервера : ${W}$ip${N}"
  echo -e "${B}  Порт       : ${W}$port${N}"
  echo -e "${B}  Интерфейс  : $st${N}"
  echo -e "${B}  Клиентов   : ${W}$clients${N}"
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
  echo -e "  ${W}9)${N} Очистить всех клиентов (без удаления сервера)"
  echo -e "  ${Y}10)${N} Создать бекап (~/awg_backup/)"
  echo -e "  ${Y}11)${N} Восстановить из бекапа"
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
# ГЕНЕРАЦИЯ AWG ПАРАМЕТРОВ (AWG 2.0 only: S3/S4 + H1-H4 диапазоны)
# ══════════════════════════════════════════════════════════
gen_awg_params() {
  # AWG 2.0 only — S3/S4 + непересекающиеся H1-H4 диапазоны
  AWG_PARAMS_LINES=""

  local Jc Jmin Jmax S1 S2 S2_OFF S3 S4 Q

# J-пакеты (стабильный диапазон, без резких скачков)
Jc=$(rand_range 3 5)
Jmin=$(rand_range 100 140)
Jmax=$(rand_range 380 520)

# Handshake padding (оставляем как есть — CPS уже маскирует)
S1=$(rand_range 1 39)
S2_OFF=$(rand_range 1 63)
[[ "$S2_OFF" -eq 56 ]] && S2_OFF=57
S2=$(( S1 + S2_OFF ))
[[ $S2 -gt 1188 ]] && S2=1188

# AWG 2.0 padding (оптимальный баланс)
S3=$(rand_range 10 16)   # Cookie (редко, достаточно небольшого шума)
S4=$(rand_range 8 12)    # Data (основной трафик — ключевой параметр)

Q=1073741823

  # Непересекающиеся диапазоны H1-H4 по квадрантам
  local H1_START H1_END H1 H2_START H2_END H2 H3_START H3_END H3 H4_START H4_END H4

  H1_START=$(rand_range 5 $((Q - 1)))
  H1_END=$(rand_range $((H1_START + 30000)) $((H1_START + 130000)))
  [[ $H1_END -gt $((Q - 1)) ]] && H1_END=$((Q - 1))
  H1="${H1_START}-${H1_END}"

  H2_START=$(rand_range $((H1_END + 1)) $((Q * 2 - 1)))
  H2_END=$(rand_range $((H2_START + 30000)) $((H2_START + 130000)))
  [[ $H2_END -gt $((Q * 2 - 1)) ]] && H2_END=$((Q * 2 - 1))
  H2="${H2_START}-${H2_END}"

  H3_START=$(rand_range $((H2_END + 1)) $((Q * 3 - 1)))
  H3_END=$(rand_range $((H3_START + 30000)) $((H3_START + 130000)))
  [[ $H3_END -gt $((Q * 3 - 1)) ]] && H3_END=$((Q * 3 - 1))
  H3="${H3_START}-${H3_END}"

  H4_START=$(rand_range $((H3_END + 1)) $((Q * 4 - 1)))
  H4_END=$(rand_range $((H4_START + 30000)) $((H4_START + 130000)))
  [[ $H4_END -gt $((Q * 4 - 1)) ]] && H4_END=$((Q * 4 - 1))
  H4="${H4_START}-${H4_END}"

  AWG_PARAMS_LINES="Jc = $Jc\nJmin = $Jmin\nJmax = $Jmax\nS1 = $S1\nS2 = $S2\nS3 = $S3\nS4 = $S4\nH1 = $H1\nH2 = $H2\nH3 = $H3\nH4 = $H4"
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
  log_info "do_gen: старт"
  command -v awg &>/dev/null || { err "awg не найден. Сначала пункт 1"; return 1; }

  local bak_ts
  bak_ts="${SERVER_CONF}.bak.$(date +%s)"
  [[ -f "$SERVER_CONF" ]] && cp "$SERVER_CONF" "$bak_ts" && info "Backup: $bak_ts"

  choose_region
  choose_dns

  hdr "IP подсеть сервера:"
  echo "  1) 10.100.0.0/24"
  echo "  2) 10.101.0.0/24"
  echo "  3) 10.102.0.0/24"
  echo "  4) 10.44.5.0/24"
  echo "  5) Вручную"
  local CLIENT_ADDR="" SERVER_ADDR="" CLIENT_NET=""
  local ADDR_CHOICE
  read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = 10.100.0.0/24): ${N}")" ADDR_CHOICE
  ADDR_CHOICE=${ADDR_CHOICE:-1}
  case $ADDR_CHOICE in
    1) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
    2) CLIENT_ADDR="10.101.0.2/32"; SERVER_ADDR="10.101.0.1/24"; CLIENT_NET="10.101.0.0/24" ;;
    3) CLIENT_ADDR="10.102.0.2/32"; SERVER_ADDR="10.102.0.1/24"; CLIENT_NET="10.102.0.0/24" ;;
    4) CLIENT_ADDR="10.44.5.2/32"; SERVER_ADDR="10.44.5.1/24"; CLIENT_NET="10.44.5.0/24" ;;
    5)
      read -rp "  IP клиента (X.X.X.X/32): " CLIENT_ADDR
      read -rp "  IP сервера (X.X.X.X/24): " SERVER_ADDR
      read -rp "  Подсеть NAT (X.X.X.0/24): " CLIENT_NET
      ;;
    *) CLIENT_ADDR="10.100.0.2/32"; SERVER_ADDR="10.100.0.1/24"; CLIENT_NET="10.100.0.0/24" ;;
  esac

  hdr "MTU:"
  echo "  1) 1420 — стандартный"
  echo "  2) 1340 — лучше для мобильных (рекомендуется)"
  echo "  3) 1280 — максимальная совместимость"
  echo "  4) 1500 — Ethernet"
  echo "  5) Вручную"
  local MTU_CHOICE MTU=""
  read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = 1340): ${N}")" MTU_CHOICE
  MTU_CHOICE=${MTU_CHOICE:-2}
  case $MTU_CHOICE in
    1) MTU=1420 ;; 2) MTU=1340 ;; 3) MTU=1280 ;; 4) MTU=1500 ;;
    5) read -rp "  MTU (1280-1500): " MTU ;;
    *) MTU=1340 ;;
  esac

  choose_mimicry_profile || return 1

  hdr "Порт сервера:"
  read -rp "$(echo -e "${C}  Порт [51820 / r = случайный]: ${N}")" PORT
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
  echo "  Регион:   ${SERVER_REGION:-world}"
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
  gen_awg_params

  # Исправлено: sysctl -w вместо sysctl -p
  sysctl -w net.ipv4.ip_forward=1 -q

  mkdir -p /etc/amnezia/amneziawg

  awg-quick down "$SERVER_CONF" 2>/dev/null || \
    ip link delete dev awg0 2>/dev/null || true

  {
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = $SERVER_ADDR"
    echo "ListenPort = $PORT"
    echo "MTU = $MTU"
    echo -e "$AWG_PARAMS_LINES"
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
    echo -e "$AWG_PARAMS_LINES"
    if [[ -n "$I1" ]]; then
      echo "I1 = $I1"
    fi
    [[ -n "$I2" ]] && echo "I2 = $I2"
    [[ -n "$I3" ]] && echo "I3 = $I3"
    [[ -n "$I4" ]] && echo "I4 = $I4"
    [[ -n "$I5" ]] && echo "I5 = $I5"
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
    warn "awg-quick up не удался. Попробуй перезагрузить сервер или пункт 6 — Перезапустить"
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
ExecStart=
ExecStart=/usr/bin/awg-quick up awg0
EOF
  systemctl daemon-reload
  systemctl enable awg-quick@awg0 2>/dev/null && ok "Автозапуск включён" || \
    warn "Не удалось включить автозапуск"
}

# ══════════════════════════════════════════════════════════
# 3. ДОБАВИТЬ КЛИЕНТА
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

  # AWG 2.0 — всегда поддерживает I1
  info "Версия сервера: AWG 2.0"

  local i1_line=""
  hdr "Выбор I1 для клиента:"
  echo "  1) Сгенерировать новый I1 (CPS генератор)"
  echo "  2) Без I1"
  read -rp "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" I1_SELECT
  I1_SELECT=${I1_SELECT:-1}

  case $I1_SELECT in
    1)
      choose_region
      choose_mimicry_profile
      [[ -n "$I1" ]] && i1_line="I1 = $I1"
      ;;
    2)
      i1_line=""
      I2=""; I3=""; I4=""; I5=""
      ;;
  esac

  local srv_pub srv_ip port mtu
  srv_pub=$(awg show awg0 public-key 2>/dev/null) \
    || { err "awg0 не поднят. Запусти: awg-quick up $SERVER_CONF"; return 1; }
  srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }
  port=$(grep "^ListenPort = " "$SERVER_CONF" | awk -F'= ' '{print $2}' | tr -d ' ')
  [[ -z "$port" ]] && { err "ListenPort не найден в конфиге сервера"; return 1; }
  mtu=$(grep "^MTU = " "$SERVER_CONF" | awk -F'= ' '{print $2}' | head -1)
  mtu=${mtu:-1340}

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
    echo "MTU = $mtu"
    [[ -n "$awg_params_from_srv" ]] && echo "$awg_params_from_srv"
    [[ -n "$i1_line" ]] && echo "$i1_line"
    [[ -n "$I2" ]] && echo "I2 = $I2"
    [[ -n "$I3" ]] && echo "I3 = $I3"
    [[ -n "$I4" ]] && echo "I4 = $I4"
    [[ -n "$I5" ]] && echo "I5 = $I5"
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
# 4. ПОКАЗАТЬ КЛИЕНТОВ
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
      transfer_line=$(echo "$transfer_cache" | grep -F "$pubkey" | head -1)
      tx_raw=$(echo "$transfer_line" | awk '{print $2}' 2>/dev/null || echo "0")
      rx_raw=$(echo "$transfer_line" | awk '{print $3}' 2>/dev/null || echo "0")
      tx_raw=${tx_raw:-0}
      rx_raw=${rx_raw:-0}
      local hs_line
      hs_line=$(echo "$handshake_cache" | grep -F "$pubkey" | head -1)
      handshake_time=$(echo "$hs_line" | awk '{print $2}' 2>/dev/null || echo "")
      local ep_line
      ep_line=$(echo "$endpoint_cache" | grep -F "$pubkey" | head -1)
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
    tx_fmt=$(echo "scale=0; $tx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
  fi
  
  if (( rx_raw >= 1073741824 )); then
    rx_fmt=$(echo "scale=2; $rx_raw/1073741824" | bc 2>/dev/null || echo "0")" ГБ"
  elif (( rx_raw >= 1048576 )); then
    rx_fmt=$(echo "scale=2; $rx_raw/1048576" | bc 2>/dev/null || echo "0")" МБ"
  else
    rx_fmt=$(echo "scale=0; $rx_raw/1024" | bc 2>/dev/null || echo "0")" КБ"
  fi
  
  local status_icon=""
  local status_text=""
  if [[ -n "$handshake_time" ]] && [[ "$handshake_time" != "0" ]]; then
    local current_time diff
    current_time=$(date +%s)
    diff=$((current_time - handshake_time))
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
  
  local endpoint_short=""
  if [[ -n "$endpoint" ]]; then
    endpoint_short="${endpoint%:*}"
  fi
  
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
# 8. ПРОВЕРКА ДОМЕНОВ
# ══════════════════════════════════════════════════════════
do_check_domains() {
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${W}                     Проверка доступности доменов для мимикрии${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  local available=0
  local total=0

  echo -e "${C}  TLS / General домены:${N}"
  for domain in yandex.ru vk.com mail.ru ozon.ru wildberries.ru sberbank.ru tbank.ru gosuslugi.ru github.com google.com; do
    total=$((total + 1))
    if timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null 2>&1; then
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
    if timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null 2>&1; then
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
    if timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null 2>&1; then
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
    if timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null 2>&1; then
      echo -e "    ${G}✓${N} $domain"
      available=$((available + 1))
    else
      echo -e "    ${R}✗${N} $domain"
    fi
  done

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${G}  ✓ Доступно: $available из $total доменов${N}"
  
  if [[ $available -lt $total ]]; then
    echo -e "${Y}  ⚠ Часть доменов недоступна — выбирай профиль мимикрии вручную${N}"
  fi
  
  echo -e "${C}  → Результат проверки — справочный. Домен выбирается случайно из пула.${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  return 0
}

# ══════════════════════════════════════════════════════════
# 9. ОЧИСТИТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
do_clean_clients() {
  [[ ! -f "$SERVER_CONF" ]] && { err "конфиг сервера не найден"; return 1; }
  
  local client_count
  client_count=$(grep -c "^\[Peer\]" "$SERVER_CONF" 2>/dev/null || echo "0")
  
  if [[ $client_count -eq 0 ]]; then
    warn "Нет клиентов для удаления"
    return 0
  fi
  
  echo ""
  echo -e "${Y}  ⚠ Будет удалено ${client_count} клиентов${N}"
  echo -e "${Y}  Все конфиги клиентов из /root также будут удалены${N}"
  echo ""
  read -rp "$(echo -e "${R}  Подтвердить удаление клиентов? [yes/N]: ${N}")" CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { warn "Отменено."; return 0; }
  
  info "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || true
  
  cp "$SERVER_CONF" "${SERVER_CONF}.bak.clean.$(date +%s)" 2>/dev/null || true
  
  local temp_conf="${SERVER_CONF}.tmp"
  sed -n '/^\[Peer\]/q; p' "$SERVER_CONF" > "$temp_conf" 2>/dev/null
  
  if [[ ! -s "$temp_conf" ]] || ! grep -q "^\[Interface\]" "$temp_conf" 2>/dev/null; then
    err "Ошибка: не удалось корректно очистить конфиг"
    rm -f "$temp_conf" 2>/dev/null
    return 1
  fi
  
  mv "$temp_conf" "$SERVER_CONF"
  rm -f /root/*_awg2.conf 2>/dev/null || true
  
  info "Перезапускаем awg0..."
  if ! awg-quick up "$SERVER_CONF" 2>/dev/null; then
    err "Не удалось перезапустить awg0. Проверь конфиг: $SERVER_CONF"
    return 1
  fi
  
  echo ""
  ok "Удалено $client_count клиентов"
  info "Конфиги клиентов из /root удалены"
}

# ══════════════════════════════════════════════════════════
# 10. БЕКАП AWG 2.0
# ══════════════════════════════════════════════════════════
do_backup() {
  local username home_dir backup_dir timestamp backup_path

  # Определяем домашнюю директорию реального пользователя (не root)
  username=$(logname 2>/dev/null || echo "${SUDO_USER:-}")
  if [[ -n "$username" ]] && id "$username" &>/dev/null 2>&1; then
    home_dir=$(getent passwd "$username" | cut -d: -f6)
  else
    home_dir="/root"
  fi

  backup_dir="${home_dir}/awg_backup"
  timestamp=$(date '+%Y%m%d_%H%M%S')
  backup_path="${backup_dir}/awg2_backup_${timestamp}"

  echo ""
  hdr "Бекап AmneziaWG 2.0"
  info "Директория бекапа: $backup_path"

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
  chmod 700 "$backup_dir" "$backup_path"

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════╗${N}"
  echo -e "${G}║              Бекап создан успешно            ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════╝${N}"
  echo -e "${W}  Файлов  : ${N}$backed_up"
  echo -e "${W}  Папка   : ${N}$backup_path"
  log_info "Бекап создан: $backup_path ($backed_up файлов)"
}

# ══════════════════════════════════════════════════════════
# 11. ВОССТАНОВЛЕНИЕ ИЗ БЕКАПА
# ══════════════════════════════════════════════════════════
do_restore() {
  local username home_dir backup_dir

  username=$(logname 2>/dev/null || echo "${SUDO_USER:-}")
  if [[ -n "$username" ]] && id "$username" &>/dev/null 2>&1; then
    home_dir=$(getent passwd "$username" | cut -d: -f6)
  else
    home_dir="/root"
  fi

  backup_dir="${home_dir}/awg_backup"

  echo ""
  hdr "Восстановление AmneziaWG 2.0"

  if [[ ! -d "$backup_dir" ]]; then
    err "Директория бекапов не найдена: $backup_dir"
    return 1
  fi

  # Список доступных бекапов
  local backups=()
  while IFS= read -r d; do
    [[ -f "$d/backup_meta.txt" ]] && backups+=("$d")
  done < <(find "$backup_dir" -maxdepth 1 -type d -name "awg2_backup_*" | sort -r)

  if [[ ${#backups[@]} -eq 0 ]]; then
    err "Нет доступных бекапов в $backup_dir"
    return 1
  fi

  echo -e "${W}  Доступные бекапы:${N}"
  local i=1
  for b in "${backups[@]}"; do
    local meta="$b/backup_meta.txt"
    local ts files
    ts=$(grep "^timestamp=" "$meta" 2>/dev/null | cut -d= -f2 || basename "$b")
    files=$(grep "^backed_files=" "$meta" 2>/dev/null | cut -d= -f2 || echo "?")
    echo -e "  ${G}$i${N}) $ts  (файлов: $files)  [$(basename "$b")]"
    i=$((i + 1))
  done
  echo ""

  local RESTORE_CHOICE
  read -rp "$(echo -e "${C}  Выбери номер бекапа (Enter = 1): ${N}")" RESTORE_CHOICE
  RESTORE_CHOICE=${RESTORE_CHOICE:-1}

  if ! [[ "$RESTORE_CHOICE" =~ ^[0-9]+$ ]] || \
     [[ "$RESTORE_CHOICE" -lt 1 ]] || \
     [[ "$RESTORE_CHOICE" -gt ${#backups[@]} ]]; then
    err "Неверный выбор"
    return 1
  fi

  local chosen_backup="${backups[$((RESTORE_CHOICE - 1))]}"
  echo -e "${C}  → Восстановление из: ${W}$(basename "$chosen_backup")${N}"

  read -rp "$(echo -e "${R}  Текущий серверный конфиг будет заменён. Продолжить? [yes/N]: ${N}")" CONFIRM_RESTORE
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
    ok "awg0 запущен"
  else
    err "Не удалось поднять awg0. Проверь конфиг: $SERVER_CONF"
    return 1
  fi

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════╗${N}"
  echo -e "${G}║          Восстановление завершено            ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════╝${N}"
  echo -e "${W}  Файлов  : ${N}$restored"
  echo -e "${W}  Бекап   : ${N}$(basename "$chosen_backup")"
  log_info "Восстановление из бекапа: $chosen_backup ($restored файлов)"
}

# ══════════════════════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════════════════════
CHOICE=""
CLIENT_DNS="1.1.1.1, 1.0.0.1"
AWG_VERSION="2.0"   # единственная поддерживаемая версия
I1=""
I2=""
I3=""
I4=""
I5=""
MIMICRY_PROFILE=""
MIMICRY_DOMAIN=""
AWG_PARAMS_LINES=""
ERROR_COUNT=0
MTU=1340

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/awg-manager.log"
log_info "=== AWG Manager v5.0 запущен ==="

trap 'rm -f /tmp/awg_tmp_* 2>/dev/null || true' EXIT

while true; do
  show_header
  show_menu
  # show_menu уже читает CHOICE, дополнительный read не нужен
  
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
   10) do_backup ;;
   11) do_restore ;;
    0) log_info "Выход"
       echo -e "\n${G}  Пока!${N}"
       echo -e "${C}  For Keenetic users - ${W}https://t.me/+c9ag3eX-zaNlMjEy${N}\n"
       exit 0 ;;
    *)
      warn "Неверный выбор"
      ERROR_COUNT=$((ERROR_COUNT + 1))
      if [[ $ERROR_COUNT -ge 5 ]]; then
        err "Слишком много неверных выборов. Выход."
        exit 1
      fi
      ;;
  esac
  
  if [[ "${CHOICE:-}" =~ ^[0-9]+$ ]] && [[ "${CHOICE:-}" -le 11 ]]; then
    ERROR_COUNT=0
  fi
  
  CHOICE=""
  echo ""
  read -rp "$(echo -e "${C}  Enter для продолжения...${N}")"
done
