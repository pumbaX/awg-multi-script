#!/bin/bash
set -euo pipefail

VERSION="v5.2"

# ─────────────────────────────────────────────────────────────
# - AmneziaWG Toolza — только AWG 2.0
# - Выбор типа I1 при ручном вводе домена (7 протоколов)
# - Бекап и восстановление конфигов AWG 2.0 (~/awg_backup/)
# ─────────────────────────────────────────────────────────────

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
  read -rp "$(echo -e "${C}  Выбор [1-2] (Enter = 2): ${N}")" RETRY_CHOICE || return 1
  RETRY_CHOICE=${RETRY_CHOICE:-2}
  if [[ "$RETRY_CHOICE" == "1" ]]; then return 0; fi
  return 1
}

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
  "sip.tele2.ru" "sip.ucoz.ru"
)
# HTTP/3 (QUIC) — реально раздают h3 в РФ сегменте или не блокируются
QUIC_DOMAINS_RU=(
  "yandex.ru" "mail.ru" "vk.com" "ya.ru" "dzen.ru"
  "www.google.com" "www.youtube.com" "www.cloudflare.com"
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
  # Глобальные SIP-провайдеры
  "sip.zadarma.com" "sip.iptel.org" "sip.linphone.org"
  "sip.antisip.com" "sip.cloudflare.com"
  # Европа — Германия
  "sipgate.de" "sip.dus.net" "sip.easybell.de" "sip.1und1.de"
  "sip.t-online.de" "sipcall.de"
  # Европа — Франция
  "sip.ovh.net" "sip.free.fr" "sip.numericable.fr"
  # Европа — Великобритания
  "sip.voipfone.co.uk" "sip.voiptalk.org" "sip.gradwell.com"
  "sip.sipgate.co.uk"
  # Европа — Нидерланды/Швейцария/Австрия
  "sip.voipgate.com" "sip.voys.nl" "sip.peoplefone.ch"
  "sip.fonira.com"
  # Италия / Испания
  "sip.messagenet.it" "sip.eutelia.it" "sip.fonyou.com"
  # Скандинавия
  "sip.bahnhof.se" "sip.com.no"
)
# HTTP/3 (QUIC) — все реально отвечают h3 на UDP/443
QUIC_DOMAINS_WORLD=(
  "www.google.com" "www.youtube.com" "www.cloudflare.com"
  "cloudflare-quic.com" "www.facebook.com" "www.instagram.com"
  "mail.google.com" "www.bing.com" "www.microsoft.com"
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
      QUIC_DOMAINS=("${QUIC_DOMAINS_RU[@]}")
      echo -e "${G}  √ Регион: Россия${N}"
      ;;
    *)
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

  # Запускаем все ping параллельно
  for domain in "${domains[@]}"; do
    (timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null 2>&1 && echo "ok" || echo "fail") > "$tmpdir/${domain//./_}" &
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

# ══════════════════════════════════════════════════════════
# CPS ГЕНЕРАТОР I1-I5 (порт из AmneziaWG Architect)
# Автор оригинала: Vadim-Khristenko (Спасибо за Идею!!) 
# I1-I5 только в клиентском конфиге — сервер не требует
# ══════════════════════════════════════════════════════════

# Единый Python генератор для всех профилей мимикрии
_CPS_GENERATOR='
import sys, random

# ── Profile target byte ranges (реалистичные размеры на проводе) ──
# QUIC Initial от Chrome/Firefox: ~1200-1280 (anti-amplification padding)
# TLS 1.3 ClientHello + ext: современный Chrome = 1200-1600 (GREASE+X25519MLKEM768)
# DTLS: 100-200 обычно
# Первый пакет — только I1, остальные I2-I5 — entropy (мелкие/средние)
# IPv6-safe cap: 1280 (min IPv6 MTU) - 40 (IPv6 hdr) - 8 (UDP) = 1232
# Не превышаем, чтобы CPS работал на 4G/IPv6/любых линках
IPV6_SAFE_CAP = 1232

BFP = {
    "quic_i":  [1100, 1232],   # QUIC Initial (Chrome-like)
    "quic_0":  [1100, 1232],   # QUIC 0-RTT
    "quic_h":  [1050, 1200],   # QUIC Handshake
    "tls":     [1000, 1232],   # TLS ClientHello Chrome-like
    "dtls":    [130,  220],    # DTLS 1.2 ClientHello
}

# Реальные QUIC версии (Wireshark dissector принимает все):
QUIC_VERSIONS = [
    "00000001",  # QUIC v1 (RFC 9000) — Chrome/FF default
    "6b3343cf",  # QUIC v2 (RFC 9369)
]


def rnd(a, b): return random.randint(a, b)
def rh(n): return "".join(f"{random.randint(0,255):02x}" for _ in range(max(0, n)))
def hex_pad(v, bl): return format(int(v), f"0{bl*2}x")[-bl*2:]


def varint(v):
    """QUIC variable-length integer (RFC 9000 §16).
    1 байт:  0-63          (2 MSB = 00)
    2 байта: 0-16383       (2 MSB = 01)
    4 байта: 0-1073741823  (2 MSB = 10)
    8 байт: ...            (2 MSB = 11)
    """
    v = int(v)
    if v < 0:
        v = 0
    if v <= 0x3f:
        return hex_pad(v, 1)
    if v <= 0x3fff:
        return hex_pad(0x4000 | v, 2)
    if v <= 0x3fffffff:
        return hex_pad(0x80000000 | v, 4)
    return hex_pad(0xc000000000000000 | v, 8)


def split_pad(n, tag="r"):
    """Разбить <r N> на куски <1000. Некоторые парсеры amneziawg-go
    глючат на границе ровно 1000 — используем 999 для безопасности."""
    n = max(0, int(n))
    if n == 0:
        return ""
    out = ""
    while n >= 999:
        out += f"<{tag} 999>"
        n -= 999
    if n > 0:
        out += f"<{tag} {n}>"
    return out


def calc_padding(header_b, extra_b, fp_range, mtu):
    """Вычислить сколько байт <r> добавить, чтобы попасть в целевой размер."""
    safe_mtu = min(mtu - 28, IPV6_SAFE_CAP)  # IPv6-safe cap
    max_pad = max(0, safe_mtu - header_b - extra_b)
    if not fp_range:
        return min(rnd(40, 160), 500, max_pad)
    c_mn, c_mx = fp_range
    target = rnd(c_mn, c_mx)
    needed = max(0, target - (header_b + extra_b))
    return min(needed, max_pad)


# ══════════════════════════════════════════════════════════════
# TLS 1.3 ClientHello fragment — реалистичный для mk_tls
# ══════════════════════════════════════════════════════════════

# Chrome cipher suites (TLS 1.3 + backward compat), порядок важен для JA3/JA4
CHROME_CIPHERS = [
    "1301",  # TLS_AES_128_GCM_SHA256
    "1302",  # TLS_AES_256_GCM_SHA384
    "1303",  # TLS_CHACHA20_POLY1305_SHA256
    "c02b",  # ECDHE-ECDSA-AES128-GCM
    "c02f",  # ECDHE-RSA-AES128-GCM
    "c02c",  # ECDHE-ECDSA-AES256-GCM
    "c030",  # ECDHE-RSA-AES256-GCM
    "cca9",  # ECDHE-ECDSA-CHACHA20
    "cca8",  # ECDHE-RSA-CHACHA20
    "c013",  # ECDHE-RSA-AES128-SHA
    "c014",  # ECDHE-RSA-AES256-SHA
    "009c",  # RSA-AES128-GCM
    "009d",  # RSA-AES256-GCM
    "002f",  # RSA-AES128-SHA
    "0035",  # RSA-AES256-SHA
]

# GREASE values (RFC 8701) — Chrome вставляет их в cipher/ext/group listы
GREASE = ["0a0a", "1a1a", "2a2a", "3a3a", "4a4a", "5a5a", "6a6a", "7a7a",
          "8a8a", "9a9a", "aaaa", "baba", "caca", "dada", "eaea", "fafa"]


def mk_tls_clienthello_body(host):
    """TLS 1.3 ClientHello body без record header.
    Реалистичный Chrome-like: GREASE, современные cipher suites, SNI, ALPN h2/http3."""
    # Legacy version
    legacy_ver = "0303"  # TLS 1.2 (для совместимости, TLS 1.3 = через extension)
    # Random (32 байта)
    client_random = rh(32)
    # Session ID: Chrome всегда шлёт 32 байта (RFC 8446 allows 0..32)
    session_id_len = "20"  # 32
    session_id = rh(32)
    # Cipher suites: GREASE + Chrome list
    grease_cs = random.choice(GREASE)
    ciphers = grease_cs + "".join(CHROME_CIPHERS)
    cs_bytes = len(ciphers) // 2
    cs_field = hex_pad(cs_bytes, 2) + ciphers
    # Compression: null
    comp = "0100"

    # Extensions (минимальный Chrome-like набор)
    def ext(tid, data):
        return tid + hex_pad(len(data) // 2, 2) + data

    grease_ext1 = random.choice(GREASE)
    exts = ""
    # GREASE ext (пустой)
    exts += ext(grease_ext1, "")
    # server_name (0x0000)
    sni_name = host.encode("idna").decode("ascii") if any(ord(c) > 127 for c in host) else host
    host_hex = "".join(f"{ord(c):02x}" for c in sni_name)
    sni_entry = "00" + hex_pad(len(sni_name), 2) + host_hex
    sni_list = hex_pad(len(sni_entry) // 2, 2) + sni_entry
    exts += ext("0000", sni_list)
    # extended_master_secret (0x0017)
    exts += ext("0017", "")
    # renegotiation_info (0xff01)
    exts += ext("ff01", "00")
    # supported_groups (0x000a): GREASE + X25519MLKEM768 (0x11ec) + X25519 + secp256r1 + secp384r1
    groups = random.choice(GREASE) + "11ec" + "001d" + "0017" + "0018"
    exts += ext("000a", hex_pad(len(groups) // 2, 2) + groups)
    # ec_point_formats (0x000b): uncompressed
    exts += ext("000b", "0100")
    # session_ticket (0x0023): empty
    exts += ext("0023", "")
    # application_layer_protocol_negotiation (0x0010): h2, http/1.1
    alpn = "02" + "6832" + "08" + "687474702f312e31"  # "h2", "http/1.1"
    exts += ext("0010", hex_pad(len(alpn) // 2, 2) + alpn)
    # status_request (0x0005)
    exts += ext("0005", "0100000000")
    # signature_algorithms (0x000d): Chrome набор
    sigalgs = "0403" "0804" "0401" "0503" "0805" "0501" "0806" "0601"
    exts += ext("000d", hex_pad(len(sigalgs) // 2, 2) + sigalgs)
    # signed_certificate_timestamp (0x0012)
    exts += ext("0012", "")
    # key_share (0x0033): GREASE (1 byte) + X25519 (32 bytes)
    ks_grease = random.choice(GREASE) + "0001" + "00"
    ks_x25519 = "001d" + "0020" + rh(32)
    ks_list = ks_grease + ks_x25519
    exts += ext("0033", hex_pad(len(ks_list) // 2, 2) + ks_list)
    # supported_versions (0x002b): GREASE + TLS 1.3
    sv = "06" + random.choice(GREASE) + "0304" + "0303"
    exts += ext("002b", sv)
    # psk_key_exchange_modes (0x002d): psk_dhe_ke
    exts += ext("002d", "0101")
    # GREASE ext (последний, 1 байт padding)
    exts += ext(random.choice(GREASE), "00")
    # padding (0x0015) — Chrome часто добавляет, чтобы ClientHello был ≥512 байт

    ext_bytes = len(exts) // 2
    ext_field = hex_pad(ext_bytes, 2) + exts

    body = legacy_ver + client_random + session_id_len + session_id + cs_field + comp + ext_field
    return body


# ══════════════════════════════════════════════════════════════
# QUIC пакеты (Chrome-like, валидные по RFC 9000 до payload)
# ══════════════════════════════════════════════════════════════

def mk_quic_long_header(packet_type_bits, host, mtu, fp_key, with_token=False):
    """Общий билдер long header QUIC пакета.
    packet_type_bits: 00=Initial, 01=0-RTT, 10=Handshake, 11=Retry
    Chrome: DCID=8, SCID=0, TokenLen=0 (Initial), PN length=4.
    """
    # First byte: 1 (long) | 1 (fixed) | type(2) | reserved(2)=00 | PN len(2)=11
    # = 11TT0011 = 0xC0 | (type << 4) | 0x03
    first_byte = 0xc0 | (packet_type_bits << 4) | 0x03
    version = random.choice(QUIC_VERSIONS)
    # Chrome: DCID = 8 bytes (рекомендация RFC 9000 §17.2)
    dcid_len = 8
    dcid = rh(dcid_len)
    # Chrome клиент: SCID = 0 (пустой)
    scid_len = 0
    scid = ""
    # Initial: Token Length varint
    token_part = ""
    if packet_type_bits == 0:  # Initial
        token_part = varint(0)  # Token Length = 0 (клиент без NEW_TOKEN)
    # Length (varint) — прикинем сначала без него, потом уточним
    # PN = 4 байта (pn_len bits = 11)
    pn_bytes = 4
    # Header до Length
    header_no_len = (
        hex_pad(first_byte, 1)
        + version
        + hex_pad(dcid_len, 1) + dcid
        + hex_pad(scid_len, 1) + scid
        + token_part
    )
    # Определяем целевой размер через fingerprint
    c_mn, c_mx = BFP[fp_key]
    target = min(rnd(c_mn, c_mx), mtu - 28, IPV6_SAFE_CAP)
    # Структура CPS: header_hex(= header_no_len + length_field + pn) + <rc N> + <r M> + <t>
    # Реальный UDP payload = header_hex_bytes + rc + r + 8 (timestamp)
    # Wireshark декодирует Length varint и проверяет: header_no_len + Length == UDP_payload_size
    # => Length == rc + r + pn_bytes + 8 (т.к. <t> уже после header в теле пакета)
    # Подбираем rc и r так, чтобы общий размер = target
    header_no_len_bytes = len(header_no_len) // 2
    sni_rc_len = min(len(host) + rnd(3, 10), 48)
    ts_bytes = 8
    length_varint_bytes = 2  # для ~1200 хватит
    # total_target = header_no_len + len_varint + pn + rc + r + ts
    r_len = target - header_no_len_bytes - length_varint_bytes - pn_bytes - sni_rc_len - ts_bytes
    r_len = max(0, r_len)
    # Length = rc + r + pn + ts (всё что идёт после Length varint в UDP теле)
    payload_len = sni_rc_len + r_len + pn_bytes + ts_bytes
    payload_len = min(payload_len, 16383)
    length_field = varint(payload_len)
    if len(length_field) // 2 != length_varint_bytes:
        # пересчёт при смене ширины varint
        length_varint_bytes = len(length_field) // 2
        r_len = max(0, target - header_no_len_bytes - length_varint_bytes - pn_bytes - sni_rc_len - ts_bytes)
        payload_len = sni_rc_len + r_len + pn_bytes + ts_bytes
        length_field = varint(payload_len)

    # Packet Number (4 bytes, в реальном пакете обфусцирован HP)
    pn = rh(pn_bytes)
    # Хедер целиком (включая PN)
    header_hex = header_no_len + length_field + pn

    return f"<b 0x{header_hex}><rc {sni_rc_len}>{split_pad(r_len)}<t>"


def mk_quic_initial(host, mtu):
    return mk_quic_long_header(0b00, host, mtu, "quic_i", with_token=False)


def mk_quic_0rtt(host, mtu):
    return mk_quic_long_header(0b01, host, mtu, "quic_0", with_token=False)


def mk_quic_handshake(host, mtu):
    """Переименованная mk_http3 → настоящий QUIC Handshake пакет (type=10).
    Отличается от Initial отсутствием Token Length field."""
    return mk_quic_long_header(0b10, host, mtu, "quic_h", with_token=False)


# ══════════════════════════════════════════════════════════════
# TLS / DTLS / SIP / DNS
# ══════════════════════════════════════════════════════════════

def mk_tls(host, mtu):
    """TLS 1.3 ClientHello с реалистичным Chrome-like телом.
    Record: 16 0301 LL LL | Handshake: 01 LL LL LL | ClientHello body."""
    body = mk_tls_clienthello_body(host)
    body_bytes = len(body) // 2
    # Handshake header: type(1=ClientHello) + length(3) + body
    hs_len = body_bytes
    hs_hdr = "01" + hex_pad(hs_len, 3)
    # Record layer: type(16=handshake) + version(0301) + length(2)
    rec_payload_bytes = 1 + 3 + body_bytes
    rec_hdr = "16" + "0301" + hex_pad(rec_payload_bytes, 2)
    # Весь ClientHello (без данных, положим как hex)
    full_hex = rec_hdr + hs_hdr + body
    full_bytes = len(full_hex) // 2

    # Целевой размер — Chrome Client Hello 1100-1600, но реальный body уже ~700-900
    target = min(rnd(1000, 1232), mtu - 28, IPV6_SAFE_CAP)
    pad = max(0, target - full_bytes - 4)  # -4 для <t>
    return f"<b 0x{full_hex}>{split_pad(pad)}<t>"


def mk_dtls(host, mtu):
    """DTLS 1.2 ClientHello (WebRTC STUN часто использует DTLS 1.2)."""
    # DTLS record: type(16) + version(fefd=DTLS 1.2) + epoch(0000) + seq(6) + length(2)
    # Handshake: type(01) + length(3) + msg_seq(2) + frag_off(3) + frag_len(3)
    rand = rh(32)
    sni_name = host
    host_hex = "".join(f"{ord(c):02x}" for c in sni_name)
    # Минимальное тело ClientHello для DTLS
    body = "fefd" + rand + "00" + "0002" + "c02b" + "0100"  # version + random + sid_len=0 + cs_len=2 + cs + comp
    # SNI ext
    sni_entry = "00" + hex_pad(len(sni_name), 2) + host_hex
    sni_list = hex_pad(len(sni_entry) // 2, 2) + sni_entry
    sni_ext = "0000" + hex_pad(len(sni_list) // 2, 2) + sni_list
    exts = sni_ext
    body += hex_pad(len(exts) // 2, 2) + exts
    body_bytes = len(body) // 2

    hs_hdr = "01" + hex_pad(body_bytes, 3) + "0000" + "000000" + hex_pad(body_bytes, 3)
    hs_total = hs_hdr + body
    rec_payload_bytes = len(hs_total) // 2
    rec_hdr = "16" + "fefd" + "0000" + rh(6) + hex_pad(rec_payload_bytes, 2)
    full_hex = rec_hdr + hs_total
    full_bytes = len(full_hex) // 2

    target = min(rnd(BFP["dtls"][0], BFP["dtls"][1]), mtu - 28, IPV6_SAFE_CAP)
    pad = max(0, target - full_bytes - 4)
    sni_rc = min(len(host) + rnd(2, 6), 40)
    return f"<b 0x{full_hex}><rc {sni_rc}>{split_pad(pad)}<t>"


def mk_sip(host, mtu):
    """SIP REGISTER (UDP 5060). Реальные SIP пакеты — текстовые, hex от ASCII."""
    reg = f"REGISTER sip:{host} SIP/2.0\r\nVia: SIP/2.0/UDP "
    hx = "".join(f"{ord(c):02x}" for c in reg) + rh(8)
    rc_val = min(len(host) + rnd(10, 30), 80)
    target = rnd(300, 600)
    hdr_bytes = len(hx) // 2
    pad = max(0, target - hdr_bytes - rc_val - 4)
    pad = min(pad, min(mtu - 28, IPV6_SAFE_CAP) - hdr_bytes - rc_val - 4)
    return f"<b 0x{hx}><rc {rc_val}><t>{split_pad(pad)}"


def mk_dns(host, mtu):
    """DNS query (UDP 53). EDNS0 OPT для реализма."""
    txid = rh(2)
    # Flags: standard query + RD
    flags = "0120"
    counts = "0001" + "0000" + "0000" + "0001"  # qd=1, ar=1 (OPT)
    q_name = "".join(f"{len(l):02x}" + "".join(f"{ord(c):02x}" for c in l) for l in host.split(".")) + "00"
    q_type = "0001"  # A
    q_class = "0001"  # IN
    # OPT pseudo-RR: name=. type=OPT(0029) udp_size=4096 rcode+ver=00 Z=0 rdlen=0
    opt = "00" + "0029" + "1000" + "0000" + "0000" + "0000"
    hx = txid + flags + counts + q_name + q_type + q_class + opt
    hdr_bytes = len(hx) // 2
    target = rnd(80, min(200, mtu - 28, IPV6_SAFE_CAP))
    pad = max(0, target - hdr_bytes - 4)
    return f"<b 0x{hx}>{split_pad(pad)}<t>"


def mk_entropy(mtu, idx):
    """Энтропийный мусор для I2-I5.
    КРИТИЧНО: все паттерны ДОЛЖНЫ начинаться с <b ...> — иначе парсер
    amneziawg-go на клиенте ломается (эмпирически проверено: handshake
    висит если первый тег <t>, <r> или <rc>). Первый байт hex — всегда
    валидный QUIC long-header (0xc0..0xef)."""
    is_big = rnd(1, 10) > 7
    if is_big:
        target = rnd(300, 700)
    else:
        target = rnd(40, 150)
    target = min(target, mtu - 28, IPV6_SAFE_CAP)

    # Первый байт: 0b11xxxxxx form=1(long), fixed=1 — валидный QUIC long header
    first_byte = rnd(0xc0, 0xef)
    b_size = rnd(5, 22)
    rest_hex = rh(b_size - 1)
    hex_data = f"{first_byte:02x}{rest_hex}"
    rc_size = rnd(4, 16)
    header = f"<b 0x{hex_data}>"
    header_bytes = b_size + rc_size + 4  # +4 для <t>
    pad_bytes = max(0, target - header_bytes)

    # ВСЕ паттерны начинаются с <b>. Варьируется только порядок остальных тегов.
    half_pad = pad_bytes // 2
    other_pad = pad_bytes - half_pad
    patterns = [
        header + split_pad(pad_bytes) + f"<rc {rc_size}>" + "<t>",
        header + f"<rc {rc_size}>" + split_pad(pad_bytes) + "<t>",
        header + "<t>" + split_pad(pad_bytes) + f"<rc {rc_size}>",
        header + f"<rc {rc_size}>" + "<t>" + split_pad(pad_bytes),
        header + split_pad(half_pad) + f"<rc {rc_size}>" + split_pad(other_pad) + "<t>",
    ]
    return patterns[(idx + rnd(0, len(patterns) - 1)) % len(patterns)] or "<b 0xc0><r 32>"


# ══════════════════════════════════════════════════════════════
# Main dispatch
# ══════════════════════════════════════════════════════════════

profile = sys.argv[1]
host = sys.argv[2]
mtu = int(sys.argv[3]) if len(sys.argv) > 3 else 1340

if profile == "quic":
    # I1=Initial, I2=0-RTT, I3=Handshake, I4-I5=entropy
    print(mk_quic_initial(host, mtu))
    print(mk_quic_0rtt(host, mtu))
    print(mk_quic_handshake(host, mtu))
    print(mk_entropy(mtu, 3))
    print(mk_entropy(mtu, 4))
elif profile == "tls":
    print(mk_tls(host, mtu))
    print(mk_quic_initial(host, mtu))
    print(mk_entropy(mtu, 2))
    print(mk_entropy(mtu, 3))
    print(mk_entropy(mtu, 4))
elif profile == "dtls":
    print(mk_dtls(host, mtu))
    print(mk_entropy(mtu, 1))
    print(mk_entropy(mtu, 2))
    print(mk_entropy(mtu, 3))
    print(mk_entropy(mtu, 4))
elif profile == "sip":
    print(mk_sip(host, mtu))
    print(mk_entropy(mtu, 1))
    print(mk_entropy(mtu, 2))
    print(mk_entropy(mtu, 3))
    print(mk_entropy(mtu, 4))
elif profile == "dns":
    print(mk_dns(host, mtu))
    print(mk_dns(host, mtu))
    print(mk_dns(host, mtu))
    print(mk_entropy(mtu, 3))
    print(mk_entropy(mtu, 4))
else:
    print(mk_tls(host, mtu))
    print(mk_entropy(mtu, 1))
    print(mk_entropy(mtu, 2))
    print(mk_entropy(mtu, 3))
    print(mk_entropy(mtu, 4))
'

# Генерация I1-I5 через Python
gen_cps_i1() {
  local profile="$1"
  local host="$2"
  local mtu="${3:-1340}"
  python3 -c "$_CPS_GENERATOR" "$profile" "$host" "$mtu"
}

# ══════════════════════════════════════════════════════════
# ВЫБОР ПРОФИЛЯ МИМИКРИИ + ГЕНЕРАЦИЯ I1-I5
# ══════════════════════════════════════════════════════════
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
# Глобальные переменные на выходе: I1, I2, I3, I4, I5, MIMICRY_PROFILE, MIMICRY_DOMAIN
# ══════════════════════════════════════════════════════════
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
  read -rp "$(echo -e "${C}  Выбор [1-3] (Enter = 1): ${N}")" OBF_LEVEL
  OBF_LEVEL=${OBF_LEVEL:-1}
  case $OBF_LEVEL in
    1|2|3) ;;
    *) OBF_LEVEL=1 ;;
  esac
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
  MIMICRY_DOMAIN=""

  # OBF_LEVEL=1 (базовый) — пропускаем мимикрию полностью
  if [[ "${OBF_LEVEL:-1}" == "1" ]]; then
    MIMICRY_PROFILE="none"
    return 0
  fi

  echo ""
  hdr "~  Профили мимикрии (AmneziaWG Architect)"
  echo -e "  ${G}1${N}  TLS 1.3 Client Hello — HTTPS (рекомендуется)"
  echo -e "  ${G}2${N}  DTLS 1.3 (WebRTC/STUN) — видеозвонки"
  echo -e "  ${G}3${N}  SIP (VoIP) — телефонные звонки"
  echo -e "  ${G}4${N}  QUIC / HTTP3 — Chrome-like Initial"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${Y}5${N}  Случайный домен из любого пула"
  echo -e "  ${Y}6${N}  Ручной ввод домена + выбор типа I1"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

  read -rp "$(echo -e "${C}  Выбор [1-6] (Enter = 1): ${N}")" PROFILE_CHOICE
  PROFILE_CHOICE=${PROFILE_CHOICE:-1}

  local domain=""
  case $PROFILE_CHOICE in
    1)
      MIMICRY_PROFILE="tls"
      domain=$(select_random_domain "tls")
      # Fallback: TLS пуст → QUIC → DTLS → SIP
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="quic"
        domain=$(select_random_domain "quic")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="dtls"
        domain=$(select_random_domain "dtls")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="sip"
        domain=$(select_random_domain "sip")
      fi
      if [[ -n "$domain" ]]; then
        echo -e "${C}  → TLS 1.3, домен: ${W}$domain${N}"
      fi
      ;;
    2)
      MIMICRY_PROFILE="dtls"
      domain=$(select_random_domain "dtls")
      # Fallback: DTLS пуст → TLS → QUIC → SIP
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="tls"
        domain=$(select_random_domain "tls")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="quic"
        domain=$(select_random_domain "quic")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="sip"
        domain=$(select_random_domain "sip")
      fi
      if [[ -n "$domain" ]]; then
        echo -e "${C}  → DTLS, домен: ${W}$domain${N}"
      fi
      ;;
    3)
      MIMICRY_PROFILE="sip"
      domain=$(select_random_domain "sip")
      # Fallback: SIP пуст → TLS → QUIC → DTLS
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="tls"
        domain=$(select_random_domain "tls")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="quic"
        domain=$(select_random_domain "quic")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="dtls"
        domain=$(select_random_domain "dtls")
      fi
      if [[ -n "$domain" ]]; then
        echo -e "${C}  → SIP, домен: ${W}$domain${N}"
      fi
      ;;
    4)
      MIMICRY_PROFILE="quic"
      domain=$(select_random_domain "quic")
      # Fallback: QUIC пуст → TLS → DTLS → SIP
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="tls"
        domain=$(select_random_domain "tls")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="dtls"
        domain=$(select_random_domain "dtls")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="sip"
        domain=$(select_random_domain "sip")
      fi
      if [[ -n "$domain" ]]; then
        echo -e "${C}  → QUIC, домен: ${W}$domain${N}"
      fi
      ;;
    5)
      # Случайный: пробуем все 4 пула, берём первый с доступными доменами
      local profiles=("tls" "quic" "dtls" "sip")
      for p in "${profiles[@]}"; do
        domain=$(select_random_domain "$p")
        if [[ -n "$domain" ]]; then
          MIMICRY_PROFILE="$p"
          break
        fi
      done
      if [[ -n "$domain" ]]; then
        echo -e "${C}  → Случайный профиль: ${W}$MIMICRY_PROFILE${N}, домен: ${W}$domain${N}"
      fi
      ;;
    6)
      read -rp "$(echo -e "${C}  Введите домен (например: cloudflare.com): ${N}")" domain
      if [[ -z "$domain" ]]; then
        warn "Домен не введён"
        return 1
      fi
      MIMICRY_DOMAIN="$domain"
      echo -e "${C}  → Ручной ввод: ${W}$domain${N}"

      # Выбор CPS-профиля для ручного домена
      echo ""
      echo -e "  ${G}1${N}  TLS 1.3 Client Hello — HTTPS (рекомендуется)"
      echo -e "  ${G}2${N}  DTLS 1.3 (WebRTC/STUN)"
      echo -e "  ${G}3${N}  SIP (VoIP)"
      echo -e "  ${G}4${N}  DNS Query (UDP 53)"
      echo -e "  ${G}5${N}  QUIC / HTTP3 — Chrome-like Initial"
      echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
      local CPS_CHOICE
      read -rp "$(echo -e "${C}  CPS-профиль [1-5] (Enter = 1): ${N}")" CPS_CHOICE
      CPS_CHOICE=${CPS_CHOICE:-1}
      case $CPS_CHOICE in
        1) MIMICRY_PROFILE="tls" ;;
        2) MIMICRY_PROFILE="dtls" ;;
        3) MIMICRY_PROFILE="sip" ;;
        4) MIMICRY_PROFILE="dns" ;;
        5) MIMICRY_PROFILE="quic" ;;
        *) MIMICRY_PROFILE="tls" ;;
      esac

      echo -e "${C}  → Генерируем CPS (${MIMICRY_PROFILE}) для $domain...${N}"
      local cps_out
      cps_out=$(gen_cps_i1 "$MIMICRY_PROFILE" "$domain" "${MTU:-1340}") || cps_out=""
      if [[ -n "$cps_out" ]]; then
        I1=$(echo "$cps_out" | sed -n '1p')
        if [[ "${OBF_LEVEL:-1}" == "3" ]]; then
          I2=$(echo "$cps_out" | sed -n '2p')
          I3=$(echo "$cps_out" | sed -n '3p')
          I4=$(echo "$cps_out" | sed -n '4p')
          I5=$(echo "$cps_out" | sed -n '5p')
          echo -e "${G}  √ I1-I5 готовы (I1: ${#I1} байт)${N}"
        else
          I2=""; I3=""; I4=""; I5=""
          echo -e "${G}  √ I1 готов (${#I1} байт)${N}"
        fi
      else
        warn "Не удалось сгенерировать CPS"
        I1=""; I2=""; I3=""; I4=""; I5=""
      fi
      return 0
      ;;
    *)
      MIMICRY_PROFILE="tls"
      domain=$(select_random_domain "tls")
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="quic"
        domain=$(select_random_domain "quic")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="dtls"
        domain=$(select_random_domain "dtls")
      fi
      if [[ -z "$domain" ]]; then
        MIMICRY_PROFILE="sip"
        domain=$(select_random_domain "sip")
      fi
      if [[ -n "$domain" ]]; then
        echo -e "${C}  → По умолчанию: TLS 1.3, домен: ${W}$domain${N}"
      fi
      ;;
  esac

  # Если все пулы пусты — fallback на без мимикрии (для автопрофилей 1-5)
  if [[ -z "$domain" ]] && [[ "$PROFILE_CHOICE" != "6" ]]; then
    warn "Нет доступных доменов ни в одном пуле — мимикрия отключена"
    MIMICRY_PROFILE="none"
    I1=""; I2=""; I3=""; I4=""; I5=""
    return 0
  fi

  # Генерация CPS-пакетов. OBF_LEVEL=2 → только I1. OBF_LEVEL=3 → I1-I5.
  # Профиль 6 (ручной) уже сгенерировал I1-I5 — до этого блока не доходит.
  if [[ -n "$domain" ]]; then
    echo -e "${C}  → Генерируем CPS (${MIMICRY_PROFILE}) для $domain...${N}"
    local cps_out
    cps_out=$(gen_cps_i1 "$MIMICRY_PROFILE" "$domain" "${MTU:-1340}") || cps_out=""
    if [[ -n "$cps_out" ]]; then
      I1=$(echo "$cps_out" | sed -n '1p')
      if [[ "${OBF_LEVEL:-1}" == "3" ]]; then
        I2=$(echo "$cps_out" | sed -n '2p')
        I3=$(echo "$cps_out" | sed -n '3p')
        I4=$(echo "$cps_out" | sed -n '4p')
        I5=$(echo "$cps_out" | sed -n '5p')
        echo -e "${G}  √ I1-I5 готовы (I1: ${#I1} байт)${N}"
      else
        I2=""; I3=""; I4=""; I5=""
        echo -e "${G}  √ I1 готов (${#I1} байт)${N}"
      fi
    else
      warn "Не удалось сгенерировать CPS"
      I1=""; I2=""; I3=""; I4=""; I5=""
    fi
  fi
}

# ══════════════════════════════════════════════════════════
# ТЕСТ DPI — захват первого CPS пакета и анализ
# ══════════════════════════════════════════════════════════

# Python-анализатор pcap (генерируется во временный файл при вызове)
_AWG_PCAP_ANALYZER='
import sys, struct

# ── Читаем pcap, возвращаем список UDP payload ──
def read_pcap(path):
    payloads = []
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24:
            return payloads
        while True:
            ph = f.read(16)
            if len(ph) < 16:
                break
            incl_len = struct.unpack("<I", ph[8:12])[0]
            pkt = f.read(incl_len)
            if len(pkt) < 42:
                continue
            eth_type = struct.unpack(">H", pkt[12:14])[0]
            if eth_type != 0x0800:
                continue
            ihl = (pkt[14] & 0x0f) * 4
            udp_off = 14 + ihl
            if udp_off + 8 > len(pkt):
                continue
            udp_len = struct.unpack(">H", pkt[udp_off+4:udp_off+6])[0]
            payload_off = udp_off + 8
            payload = pkt[payload_off:payload_off + (udp_len - 8)]
            if len(payload) >= 20:
                payloads.append(payload)
    return payloads

# ── Детектор профиля для одного payload ──
def detect(payload):
    """Возвращает (profile_name, [(level, msg)...]) или (None, []) если не распознан"""
    res = []
    def ok(m): res.append(("OK", m))
    def info(m): res.append(("INFO", m))
    def bad(m): res.append(("FAIL", m))

    # 1) SIP — текстовый ASCII в начале
    sip_methods = (b"INVITE", b"REGISTER", b"OPTIONS", b"MESSAGE",
                   b"SUBSCRIBE", b"NOTIFY", b"PUBLISH", b"BYE",
                   b"CANCEL", b"ACK ", b"INFO ", b"REFER", b"PRACK",
                   b"UPDATE", b"SIP/2.0")
    for m in sip_methods:
        if payload.startswith(m):
            ok(f"SIP пакет ({m.decode().strip()})")
            return ("sip", res)

    # 2) TLS 1.x record
    if payload[0] == 0x16 and payload[1:3] == b"\x03\x01":
        ok("TLS record (type=0x16, ver=0x0301)")
        if len(payload) >= 6 and payload[5] == 0x01:
            ok("TLS ClientHello (handshake type=01)")
        return ("tls", res)

    # 3) DTLS record (1.2 = fefd, 1.0 = feff)
    if payload[0] == 0x16 and payload[1:3] in (b"\xfe\xfd", b"\xfe\xff"):
        ver = "1.2" if payload[1:3] == b"\xfe\xfd" else "1.0"
        ok(f"DTLS {ver} record (handshake)")
        if len(payload) >= 14 and payload[13] == 0x01:
            ok("DTLS ClientHello")
        return ("dtls", res)

    # 4) DNS query
    if len(payload) >= 12:
        flags = payload[2]
        qr = (flags >> 7) & 1
        opcode = (flags >> 3) & 0xf
        qdcount = struct.unpack(">H", payload[4:6])[0]
        if qr == 0 and opcode == 0 and 1 <= qdcount <= 10 and payload[3] in (0x00, 0x20, 0x80, 0xa0):
            # Доп. проверка: первый label валиден (длина 1-63)
            label_len = payload[12]
            if 1 <= label_len <= 63:
                ok(f"DNS query (qdcount={qdcount}, EDNS возможен)")
                return ("dns", res)

    # 5) QUIC long header (form=1, fixed=1, type 0/1/2)
    # Строгий детект: первый байт + ИЗВЕСТНАЯ version + DCID в Chrome-диапазоне
    # Иначе скорее всего junk-пакет с случайным совпадением битов first byte
    first = payload[0]
    form = (first >> 7) & 1
    fixed = (first >> 6) & 1
    ptype = (first >> 4) & 3
    pn_len = (first & 3) + 1
    if form == 1 and fixed == 1 and ptype != 3 and len(payload) >= 7:
        version = payload[1:5].hex()
        known_versions = {
            "00000001": "QUIC v1 (RFC 9000)",
            "6b3343cf": "QUIC v2 (RFC 9369)",
        }
        dcid_len = payload[5]

        # Строгая проверка перед тем как объявить пакет QUIC:
        # - либо известная version
        # - либо DCID длина в реалистичном диапазоне (1-20 по RFC 9000)
        is_valid_quic = (version in known_versions) and (1 <= dcid_len <= 20)

        if not is_valid_quic:
            # Не QUIC — пропускаем, пусть анализатор смотрит следующий пакет
            return (None, [])

        ok(f"Long header (first_byte=0x{first:02x})")
        ptype_names = {0: "Initial", 1: "0-RTT", 2: "Handshake"}
        ok(f"QUIC type: {ptype_names[ptype]} (bits={ptype:02b})")
        ok(f"PN length: {pn_len} байт")
        ok(f"Version: 0x{version} ({known_versions[version]})")

        try:
            if dcid_len == 8:
                ok("DCID length: 8 (Chrome-style)")
            else:
                info(f"DCID length: {dcid_len}")

            off = 6 + dcid_len
            if off >= len(payload):
                return (None, [])
            scid_len = payload[off]
            if scid_len == 0:
                ok("SCID length: 0 (Chrome-style клиент)")
            elif scid_len <= 20:
                info(f"SCID length: {scid_len}")
            else:
                # SCID > 20 — не валидный, отбрасываем
                return (None, [])
            off += 1 + scid_len

            if ptype == 0 and off < len(payload):
                def rv(buf, pos):
                    b0 = buf[pos]; ln = 1 << (b0 >> 6); val = b0 & 0x3f
                    for i in range(1, ln): val = (val << 8) | buf[pos+i]
                    return val, pos + ln
                tok_len, off2 = rv(payload, off)
                if tok_len == 0:
                    ok("Token Length: 0 (Chrome без NEW_TOKEN)")
                elif tok_len < 100:
                    info(f"Token Length: {tok_len}")
                else:
                    # Подозрительно большой Token — не валидный QUIC
                    return (None, [])
                off2 += tok_len
                if off2 < len(payload):
                    plen, off3 = rv(payload, off2)
                    expected_total = off3 + plen
                    actual = len(payload)
                    diff = abs(expected_total - actual)
                    if diff <= 4:
                        ok(f"Payload Length varint: {plen} (Δ={diff})")
                    else:
                        info(f"Payload Length varint: {plen}, UDP: {actual} (Δ={diff})")
        except Exception as e:
            info(f"Парсинг QUIC прерван: {type(e).__name__}")
        return ("quic", res)

    # Не распознан
    return (None, [])

# ── Main ──
payloads = read_pcap(sys.argv[1])
if not payloads:
    print("FAIL|pcap пуст или нечитаем")
    print("VERDICT|FAIL|нет валидных UDP пакетов")
    sys.exit(0)

# Перебираем все пакеты, ищем первый с распознанным профилем
chosen_idx = -1
chosen_profile = None
chosen_results = []
for i, pl in enumerate(payloads):
    profile, results = detect(pl)
    if profile is not None:
        chosen_idx = i
        chosen_profile = profile
        chosen_results = results
        break

if chosen_profile is None:
    # Ни один пакет не распознан — показываем первый как неизвестный
    pl = payloads[0]
    print(f"INFO|Захвачено пакетов: {len(payloads)}")
    print(f"INFO|Размеры: {[len(p) for p in payloads]}")
    print(f"INFO|Первый пакет ({len(pl)}B): first 8 bytes = {pl[:8].hex()}")
    print("INFO|Профиль не распознан — возможно junk-пакет (Jc) или handshake init")
    print("VERDICT|CHECK|неизвестный профиль (попробуй reconnect ещё раз)")
    sys.exit(0)

# Распознали — выводим
pl = payloads[chosen_idx]
sz = len(pl)
print(f"INFO|Захвачено пакетов: {len(payloads)}, выбран #{chosen_idx+1} ({sz}B)")
for level, msg in chosen_results:
    print(f"{level}|{msg}")

if 1000 <= sz <= 1500:
    print(f"OK|UDP payload size: {sz}B (Chrome-like)")
elif 200 <= sz < 1000:
    print(f"OK|UDP payload size: {sz}B (компактный CPS)")
elif sz >= 100:
    print(f"INFO|UDP payload size: {sz}B (маленький)")
else:
    print(f"FAIL|UDP payload size: {sz}B (слишком мало)")

print()

PASS = sum(1 for r,_ in chosen_results if r == "OK")
FAIL = sum(1 for r,_ in chosen_results if r == "FAIL")

# Для маленьких протоколов (DNS, SIP) минимум размера ниже
size_min = 80 if chosen_profile in ("dns", "sip") else 200
size_ok = sz >= size_min

# Бонусный +1 если размер ок (учитываем что может быть OK от print выше тоже)
# Простое правило: если профиль распознан, есть хоть 1 OK от detect, и размер >= min — PASS
if FAIL == 0 and PASS >= 1 and size_ok:
    print(f"VERDICT|PASS|{chosen_profile}")
elif FAIL == 0:
    print(f"VERDICT|CHECK|размер {sz}B мал для {chosen_profile}")
else:
    print(f"VERDICT|CHECK|{PASS} ok, {FAIL} fail")
'

do_sniff_test() {
  echo ""
  hdr "◎  DPI тест — анализ первого CPS пакета"
  echo ""

  # 1. tcpdump?
  if ! command -v tcpdump &>/dev/null; then
    warn "tcpdump не установлен"
    echo -e "${C}  Установи: ${W}apt install -y tcpdump${N}"
    return 0
  fi

  # 2. Сервер есть?
  if [[ ! -f "$SERVER_CONF" ]]; then
    warn "Сервер не найден: $SERVER_CONF"
    echo -e "${C}  Сначала создай сервер (пункт 2)${N}"
    return 0
  fi

  # 3. ListenPort
  local listen_port
  listen_port=$(awk -F= '/^ListenPort/{gsub(/ /,"",$2); print $2}' "$SERVER_CONF")
  if [[ -z "$listen_port" ]]; then
    warn "Не удалось определить ListenPort"
    return 0
  fi
  echo -e "${C}  → AWG порт: ${W}${listen_port}${N}"

  # 4. WAN интерфейс
  local wan_if
  wan_if=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -z "$wan_if" ]] && wan_if="eth0"
  echo -e "${C}  → WAN интерфейс: ${W}${wan_if}${N}"

  # 5. Endpoint клиента — обязательное условие + выбор если несколько
  local endpoints_raw
  endpoints_raw=$(awg show awg0 endpoints 2>/dev/null | awk 'NF==2 && $2!="(none)"')
  if [[ -z "$endpoints_raw" ]]; then
    err "Нет подключённых клиентов (endpoint = none)"
    echo ""
    echo -e "${Y}  ▲ Сначала нужно хоть раз подключиться клиентом:${N}"
    echo -e "${C}    1. Импортируй .conf в AmneziaVPN${N}"
    echo -e "${C}    2. Нажми Connect (дождись успешного handshake)${N}"
    echo -e "${C}    3. Вернись сюда и запусти тест снова${N}"
    echo ""
    echo -e "${D}    (endpoint появляется в awg show только после первого handshake)${N}"
    return 0
  fi

  local -a peer_list
  local -a ep_list
  mapfile -t peer_list < <(echo "$endpoints_raw" | awk '{print $1}')
  mapfile -t ep_list < <(echo "$endpoints_raw" | awk '{print $2}')

  # Сопоставление peer pubkey → (имя файла, VPN IP)
  # Сканируем /root/*_awg2.conf, вычисляем pubkey из PrivateKey, мапим
  local -a name_list=()
  local -a vpn_ip_list=()
  declare -A pk_to_name pk_to_ip
  local cf cf_priv cf_pub cf_addr cf_basename
  for cf in /root/*_awg2.conf; do
    [[ -f "$cf" ]] || continue
    cf_priv=$(grep -E '^PrivateKey' "$cf" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r' | head -1)
    [[ -z "$cf_priv" ]] && continue
    cf_pub=$(echo "$cf_priv" | awg pubkey 2>/dev/null) || continue
    cf_addr=$(grep -E '^Address' "$cf" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r' | head -1)
    cf_basename=$(basename "$cf" .conf)
    pk_to_name["$cf_pub"]="$cf_basename"
    pk_to_ip["$cf_pub"]="${cf_addr%/*}"
  done

  local pk
  for pk in "${peer_list[@]}"; do
    name_list+=("${pk_to_name[$pk]:-неизвестен}")
    vpn_ip_list+=("${pk_to_ip[$pk]:-?}")
  done

  local client_ep client_ip sel_idx=0
  if [[ ${#ep_list[@]} -eq 1 ]]; then
    sel_idx=0
    client_ep="${ep_list[0]}"
    echo -e "${C}  → Клиент: ${W}${name_list[0]}${N} ${D}(VPN ${vpn_ip_list[0]} • ext ${client_ep})${N}"
  else
    echo ""
    echo -e "${C}  Подключённых клиентов: ${W}${#ep_list[@]}${N}"
    local k
    for k in "${!ep_list[@]}"; do
      printf "  ${G}%d)${N} %-26s ${C}%-15s${N} ${D}%s${N}\n" \
        "$((k+1))" "${name_list[$k]}" "${vpn_ip_list[$k]}" "${ep_list[$k]}"
    done
    local PEER_SEL
    read -rp "$(echo -e "${C}  Выбор клиента для теста [1-${#ep_list[@]}] (Enter = 1): ${N}")" PEER_SEL
    PEER_SEL=${PEER_SEL:-1}
    if ! [[ "$PEER_SEL" =~ ^[0-9]+$ ]] || (( PEER_SEL < 1 || PEER_SEL > ${#ep_list[@]} )); then
      warn "Неверный выбор — возврат в главное меню"
      return 0
    fi
    sel_idx=$((PEER_SEL - 1))
    client_ep="${ep_list[$sel_idx]}"
    echo -e "${C}  → Клиент: ${W}${name_list[$sel_idx]}${N} ${D}(VPN ${vpn_ip_list[$sel_idx]} • ext ${client_ep})${N}"
  fi
  client_ip="${client_ep%:*}"

  # 6. Возраст handshake для выбранного peer — в человеческом формате
  local hs_ts hs_ago hs_fmt
  hs_ts=$(awg show awg0 latest-handshakes 2>/dev/null | awk -v pk="${peer_list[$sel_idx]}" '$1==pk{print $2; exit}')
  if [[ -n "$hs_ts" && "$hs_ts" != "0" ]]; then
    hs_ago=$(( $(date +%s) - hs_ts ))
    hs_fmt=$(_fmt_duration "$hs_ago")
    echo -e "${C}  → Последний handshake: ${W}${hs_fmt} назад${N}"
  else
    echo -e "${C}  → Последний handshake: ${Y}нет${N}"
  fi

  # 7. Инструкция
  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${Y}  ! На клиенте сейчас: Disconnect → Connect${N}"
  echo -e "${Y}   (нужен новый handshake чтобы поймать CPS chain)${N}"
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  read -rp "$(echo -e "${C}  Enter когда готов (20с на реконнект)... ${N}")" _ || return 0

  # 8. Python анализатор во временный файл
  local analyzer="/tmp/awg_pcap_analyzer_$$.py"
  echo "$_AWG_PCAP_ANALYZER" > "$analyzer"

  # 9. tcpdump: ловим первые 10 пакетов >100B от клиента на ListenPort
  # CPS пакеты могут быть маленькими (SIP/DNS ~80-600B), не только >1000B
  # Анализатор переберёт все и выберет первый распознанный профиль
  local pcap="/tmp/awg_dpi_test_$$.pcap"
  echo -e "${C}  → Запускаю tcpdump (20с)...${N}"
  echo -e "${C}    Подключайся с клиента ПРЯМО СЕЙЧАС${N}"
  echo ""

  timeout 20 tcpdump -i "$wan_if" -nn -c 10 \
    "udp port ${listen_port} and src host ${client_ip} and greater 100" \
    -w "$pcap" 2>/dev/null || true

  if [[ ! -s "$pcap" ]]; then
    warn "Не поймали ни одного CPS пакета"
    echo -e "${Y}  Возможные причины:${N}"
    echo -e "${C}    • Клиент не переподключился вовремя${N}"
    echo -e "${C}    • Уровень обфускации = ${W}базовый${C} (CPS отключён)${N}"
    echo -e "${C}    • Клиент через другой WAN${N}"
    rm -f "$pcap" "$analyzer"
    return 0
  fi

  # 10. Парсинг
  echo -e "${C}  → Анализ захваченного пакета...${N}"
  echo ""

  local analysis
  analysis=$(python3 "$analyzer" "$pcap" 2>&1) || analysis="FAIL|Python parse error"

  # 11. Красивый вывод
  local verdict="" verdict_extra=""
  while IFS='|' read -r tag msg extra; do
    [[ -z "$tag" ]] && continue
    case "$tag" in
      OK)   echo -e "  ${G}√${N} $msg" ;;
      FAIL) echo -e "  ${R}×${N} $msg" ;;
      INFO) echo -e "  ${D}·${N} $msg" ;;
      VERDICT)
        verdict="$msg"
        verdict_extra="$extra"
        ;;
    esac
  done <<< "$analysis"

  echo ""
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  if [[ "$verdict" == "PASS" ]]; then
    local prof_label="${verdict_extra^^}"
    echo -e "${G}  √ Всё заебись!!! — ${prof_label} мимикрия работает${N}"
  elif [[ "$verdict" == "CHECK" ]]; then
    echo -e "${Y}  ▲ Проверь warnings выше${N}"
    [[ -n "$verdict_extra" ]] && echo -e "${D}    ${verdict_extra}${N}"
  else
    echo -e "${R}  × Анализ не удался${N}"
  fi
  echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

  rm -f "$pcap" "$analyzer"
  log_info "do_sniff_test завершён для клиента $client_ip, verdict=$verdict"
  return 0
}

# ══════════════════════════════════════════════════════════
# ПРОВЕРКА ЗАВИСИМОСТЕЙ ДЛЯ МЕНЮ
# ══════════════════════════════════════════════════════════
check_deps() {
  HAS_AWG=false
  HAS_QRENCODE=false
  HAS_SERVER_CONF=false
  HAS_CLIENT_CONFS=false
  HAS_BACKUPS=false

  command -v awg &>/dev/null && HAS_AWG=true
  command -v qrencode &>/dev/null && HAS_QRENCODE=true
  [[ -f "$SERVER_CONF" ]] && HAS_SERVER_CONF=true
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

show_header() {
  clear
  local s ip port st clients
  s=$(get_status)
  IFS='|' read -r ip port st clients <<< "$s"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}AmneziaWG Toolza $VERSION${N}"
  echo -e "  ${C}AWG 2.0 only — TLS/DTLS/SIP/DNS/QUIC${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  IP сервера : ${W}$ip${N}"
  echo -e "  Порт       : ${W}$port${N}"
  echo -e "  Интерфейс  : $st${N}"
  echo -e "  Клиентов   : ${W}$clients${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

show_menu() {
  echo ""

  # Пункт 1 — всегда доступен
  echo -e "  ${W}◇  1)${N} Установка зависимостей и AmneziaWG"

  # Пункт 2 — нужен awg
  if $HAS_AWG; then
    echo -e "  ${W}◇  2)${N} Создать сервер + первый клиент (с мимикрией)"
  else
    echo -e "  ${D}◇  2)${N} Создать сервер ${D}(нужен пункт 1)${N}"
  fi

  # Пункт 3 — нужен awg + конфиг сервера
  if $HAS_AWG && $HAS_SERVER_CONF; then
    echo -e "  ${W}◇  3)${N} Добавить клиента"
  else
    echo -e "  ${D}◇  3)${N} Добавить клиента ${D}(нужен пункт 2)${N}"
  fi

  # Пункт 4 — нужен awg + конфиг сервера
  if $HAS_AWG && $HAS_SERVER_CONF; then
    echo -e "  ${W}◇  4)${N} Показать клиентов"
  else
    echo -e "  ${D}◇  4)${N} Показать клиентов ${D}(нужен пункт 2)${N}"
  fi

  # Пункт 5 — нужен qrencode + конфиги клиентов
  if $HAS_QRENCODE && $HAS_CLIENT_CONFS; then
    echo -e "  ${W}◇  5)${N} Показать QR клиента"
  elif ! $HAS_CLIENT_CONFS; then
    echo -e "  ${D}◇  5)${N} Показать QR клиента ${D}(нет клиентов)${N}"
  else
    echo -e "  ${D}◇  5)${N} Показать QR клиента ${D}(нужен qrencode)${N}"
  fi

  # Пункт 6 — нужен конфиг сервера
  if $HAS_SERVER_CONF; then
    echo -e "  ${W}◇  6)${N} Перезапустить awg0"
  else
    echo -e "  ${D}◇  6)${N} Перезапустить awg0 ${D}(нужен пункт 2)${N}"
  fi

  # Пункт 7 — всегда доступен
  echo -e "  ${W}◇  7)${N} Удалить всё"

  # Пункт 8 — всегда доступен
  echo -e "  ${W}◇  8)${N} Проверить домены из пулов (ping)"

  # Пункт 9 — нужен конфиг сервера
  if $HAS_SERVER_CONF; then
    echo -e "  ${W}◇  9)${N} Очистить всех клиентов (без удаления сервера)"
  else
    echo -e "  ${D}◇  9)${N} Очистить клиентов ${D}(нужен пункт 2)${N}"
  fi

  # Пункт 10 — всегда доступен
  echo -e "  ${Y}◆ 10)${N} Создать бекап (~/awg_backup/)"

  # Пункт 11 — нужны бекапы
  if $HAS_BACKUPS; then
    echo -e "  ${Y}◆ 11)${N} Восстановить из бекапа"
  else
    echo -e "  ${D}◇ 11)${N} Восстановить из бекапа ${D}(нет бекапов)${N}"
  fi

  # Пункт 12 — нужен сервер + tcpdump
  if $HAS_SERVER_CONF; then
    echo -e "  ${W}◇ 12)${N} Тест DPI мимикрии (захват CPS пакета)"
  else
    echo -e "  ${D}◇ 12)${N} Тест DPI мимикрии ${D}(нужен пункт 2)${N}"
  fi

  echo -e "  ${W}   0)${N} Выход"
  echo ""
  read -rp "$(echo -e "${C}  Выбор: ${N}")" CHOICE
}

choose_dns() {
  CLIENT_DNS=""
  hdr "◎  DNS для клиента"
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
# Параметры обфускации AmneziaWG:
#   Jc/Jmin/Jmax — дробление пакетов (junk packets)
#   S1/S2        — размер специальных пакетов
#   S3/S4        — частота специальных пакетов (S3 из каждых S4)
#   H1-H4        — непересекающиеся диапазоны последовательностей по 4 квадрантам
#                  Q = 2^30 = 1073741823, квадранты: [0..Q], [Q..2Q], [2Q..3Q], [3Q..4Q]
#                  Каждый диапазон: ширина 30K-130K, начинается после предыдущего
#                  Непересечение критично — иначе сервер и клиент рассинхронизируются
# Результат: глобальная AWG_PARAMS_LINES (строки для конфига, \n-разделённые)
gen_awg_params() {
  AWG_PARAMS_LINES=""

  local Jc Jmin Jmax S1 S2 S2_OFF S3 S4 Q
  Jc=$(rand_range 3 7)
  Jmin=$(rand_range 64 256)
  Jmax=$(rand_range 576 1024)
  S1=$(rand_range 1 39)
  S2_OFF=$(rand_range 1 63)
  [[ "$S2_OFF" -eq 56 ]] && S2_OFF=57 || true   # 56 зарезервировано — избегаем
  S2=$(( S1 + S2_OFF ))
  [[ $S2 -gt 1188 ]] && S2=1188 || true
  S3=$(rand_range 5 64)
  S4=$(rand_range 1 16)
  Q=1073741823  # 2^30 - 1, базовый квадрант

  # Непересекающиеся диапазоны H1-H4 по квадрантам
  local H1_START H1_END H1 H2_START H2_END H2 H3_START H3_END H3 H4_START H4_END H4

  H1_START=$(rand_range 5 $((Q - 1)))
  H1_END=$(rand_range $((H1_START + 30000)) $((H1_START + 130000)))
  [[ $H1_END -gt $((Q - 1)) ]] && H1_END=$((Q - 1)) || true
  H1="${H1_START}-${H1_END}"

  H2_START=$(rand_range $((H1_END + 1)) $((Q * 2 - 1)))
  H2_END=$(rand_range $((H2_START + 30000)) $((H2_START + 130000)))
  [[ $H2_END -gt $((Q * 2 - 1)) ]] && H2_END=$((Q * 2 - 1)) || true
  H2="${H2_START}-${H2_END}"

  H3_START=$(rand_range $((H2_END + 1)) $((Q * 3 - 1)))
  H3_END=$(rand_range $((H3_START + 30000)) $((H3_START + 130000)))
  [[ $H3_END -gt $((Q * 3 - 1)) ]] && H3_END=$((Q * 3 - 1)) || true
  H3="${H3_START}-${H3_END}"

  H4_START=$(rand_range $((H3_END + 1)) $((Q * 4 - 1)))
  H4_END=$(rand_range $((H4_START + 30000)) $((H4_START + 130000)))
  [[ $H4_END -gt $((Q * 4 - 1)) ]] && H4_END=$((Q * 4 - 1)) || true
  H4="${H4_START}-${H4_END}"

  AWG_PARAMS_LINES="Jc = $Jc\nJmin = $Jmin\nJmax = $Jmax\nS1 = $S1\nS2 = $S2\nS3 = $S3\nS4 = $S4\nH1 = $H1\nH2 = $H2\nH3 = $H3\nH4 = $H4"
}

# ══════════════════════════════════════════════════════════
# 1. УСТАНОВКА
# ══════════════════════════════════════════════════════════
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

  local USE_PPA=0 USE_GIT_TOOLS=0
  case "$OS_ID" in
    ubuntu)
      case "$OS_VER" in
        24.04|24.10|25.04|25.10)
          USE_PPA=1
          ok "Ubuntu $OS_VER — PPA amnezia/ppa поддерживается"
          ;;
        *)
          warn "Ubuntu $OS_VER не в списке проверенных, но пробуем PPA"
          USE_PPA=1
          ;;
      esac
      ;;
    debian)
      case "$OS_VER" in
        12|13)
          USE_GIT_TOOLS=1
          ok "Debian $OS_VER — будем собирать amneziawg-tools из исходников"
          info "PPA amnezia/ppa для Debian не собирается, используем git + make"
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

  hdr "+  Обновление системы"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q || { err "Не удалось обновить репозитории"; prompt_retry || return 1; continue; }
  apt-get upgrade -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

  hdr "+  Установка зависимостей"
  local base_deps=(python3 net-tools curl ufw iptables qrencode bc ca-certificates gnupg)
  if [[ $USE_PPA -eq 1 ]]; then
    base_deps+=(software-properties-common python3-launchpadlib)
  fi
  if [[ $USE_GIT_TOOLS -eq 1 ]]; then
    base_deps+=(build-essential git libmnl-dev pkg-config dkms)
  fi
  apt-get install -y -q "${base_deps[@]}"

  hdr "+  Kernel headers"
  apt-get install -y -q "linux-headers-$(uname -r)" 2>/dev/null || \
  apt-get install -y -q linux-headers-generic || \
  apt-get install -y -q linux-headers-amd64 || \
  { err "Не удалось установить linux-headers"; info "Попробуй: apt-get install linux-headers-generic"; prompt_retry || return 1; continue; }

  if [[ $USE_PPA -eq 1 ]]; then
    hdr "+  AmneziaWG (PPA)"
    add-apt-repository -y ppa:amnezia/ppa || { err "Не удалось добавить PPA"; prompt_retry || return 1; continue; }
    apt-get update -q
    apt-get install -y -q amneziawg amneziawg-tools
  else
    # Debian: kernel module + tools из git
    hdr "+  AmneziaWG kernel module (git + DKMS)"
    local tmp_mod=/tmp/amneziawg-linux-kernel-module
    rm -rf "$tmp_mod"
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git "$tmp_mod" || {
      err "Не удалось клонировать kernel module"; prompt_retry || return 1; continue
    }
    (
      cd "$tmp_mod/src" || exit 1
      make dkms-install || exit 1
      local mod_ver
      mod_ver=$(grep -oP 'version\s*"\K[^"]+' dkms.conf 2>/dev/null || echo "1.0.0")
      dkms add -m amneziawg -v "$mod_ver" 2>/dev/null || true
      dkms build -m amneziawg -v "$mod_ver" || exit 1
      dkms install -m amneziawg -v "$mod_ver" || exit 1
    ) || { err "Сборка kernel module провалилась"; prompt_retry || return 1; continue; }
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
  fi

  if command -v awg &>/dev/null; then
    ok "amneziawg-tools: $(awg --version 2>/dev/null || echo 'установлен')"
  else
    err "awg не найден после установки"; info "Возможно, нужен reboot и повторная установка"; prompt_retry || return 1; continue;
  fi

  hdr "⌘  Проверка модуля"
  if modprobe amneziawg 2>/dev/null; then
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
  local ssh_port
  read -rp "$(echo -e "${C}  SSH порт [22]: ${N}")" ssh_port
  ssh_port=${ssh_port:-22}
  ufw allow "${ssh_port}/tcp" comment "SSH" || true
  ufw allow 80/tcp  comment "HTTP"  || true
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw --force enable || true
  ufw status verbose

  echo ""
  success_box "Установка завершена"
  info "Следующий шаг: пункт меню 2 — Создать сервер"
  break
  done
}

# ══════════════════════════════════════════════════════════
# 2. СОЗДАТЬ СЕРВЕР
# ══════════════════════════════════════════════════════════
do_gen() {
  log_info "do_gen: старт"
  command -v awg &>/dev/null || { err "awg не найден. Сначала пункт 1"; return 1; }
  command -v python3 &>/dev/null || { err "python3 не найден — нужен для генерации параметров"; info "Запусти пункт 1 или: apt-get install python3"; return 1; }

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
  echo "  2) 1380 — баланс, рекомендуется"
  echo "  3) 1360 — провайдеры с PPPoE overhead"
  echo "  4) 1340 — мобильный 4G/LTE"
  echo "  5) 1320 — безопасно для AWG 2.0 + CPS"
  echo "  6) 1280 — максимальная совместимость"
  echo "  7) 1500 — Ethernet без tunnel overhead"
  echo "  8) Вручную"
  MTU=""
  local MTU_CHOICE
  read -rp "$(echo -e "${C}  Выбор [1-8] (Enter = 1380): ${N}")" MTU_CHOICE
  MTU_CHOICE=${MTU_CHOICE:-2}
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
    *) MTU=1380 ;;
  esac

  choose_obf_level
  choose_mimicry_profile || return 1

  hdr "»  IP подсеть сервера"
  echo "  1) Случайная подсеть из пула 10.[10-55].[1-254].0/24 (рекомендуется)"
  echo "  2) 10.100.0.0/24"
  echo "  3) 10.101.0.0/24"
  echo "  4) 10.102.0.0/24"
  echo "  5) 10.44.5.0/24"
  echo "  6) Вручную"
  local CLIENT_ADDR="" SERVER_ADDR="" CLIENT_NET=""
  local ADDR_CHOICE
  read -rp "$(echo -e "${C}  Выбор [1-6] (Enter = 1 случайная): ${N}")" ADDR_CHOICE
  ADDR_CHOICE=${ADDR_CHOICE:-1}
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
      read -rp "  IP клиента (X.X.X.X/32): " CLIENT_ADDR
      read -rp "  IP сервера (X.X.X.X/24): " SERVER_ADDR
      read -rp "  Подсеть NAT (X.X.X.0/24): " CLIENT_NET
      ;;
    *)
      local rnd_octet2 rnd_octet3
      rnd_octet2=$(rand_range 10 55)
      rnd_octet3=$(rand_range 1 254)
      CLIENT_ADDR="10.${rnd_octet2}.${rnd_octet3}.2/32"
      SERVER_ADDR="10.${rnd_octet2}.${rnd_octet3}.1/24"
      CLIENT_NET="10.${rnd_octet2}.${rnd_octet3}.0/24"
      ;;
  esac

  hdr "»  Порт сервера"
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
    if [[ -n "$I1" ]]; then
      echo "I1 = $I1"
      [[ -n "$I2" ]] && echo "I2 = $I2" || true
      [[ -n "$I3" ]] && echo "I3 = $I3" || true
      [[ -n "$I4" ]] && echo "I4 = $I4" || true
      [[ -n "$I5" ]] && echo "I5 = $I5" || true
    fi
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
    echo -e "  ${Y}  • Конфликт iptables правил → пункт 7 (удалить) и заново${N}"
    echo -e "  ${Y}  • Порт $PORT заблокирован → ufw allow $PORT/udp${N}"
    if [[ -n "$bak_ts" && -f "$bak_ts" ]]; then
      echo -e "  ${Y}  • Предыдущий конфиг сохранён: $bak_ts${N}"
      read -rp "$(echo -e "${C}  Восстановить предыдущий конфиг? [y/N]: ${N}")" RESTORE_BAK || true
      if [[ "$RESTORE_BAK" =~ ^[Yy]$ ]]; then
        cp "$bak_ts" "$SERVER_CONF"
        awg-quick up "$SERVER_CONF" 2>/dev/null || true
        ok "Конфиг восстановлен"
      fi
    fi
    return 1
  fi

  if command -v ufw &>/dev/null; then
    read -rp "$(echo -e "${C}  Открыть порт $PORT/udp в UFW? [Y/n]: ${N}")" OPEN_UFW
    OPEN_UFW=${OPEN_UFW:-y}
    if [[ $OPEN_UFW =~ ^[Yy]$ ]]; then
      ufw allow "${PORT}/udp" comment "AmneziaWG" || true
      ok "Порт ${PORT}/udp открыт в файрволе"
    fi
  fi

  command -v qrencode &>/dev/null && qrencode -t ansiutf8 -s 1 -m 1 < /root/client1_awg2.conf

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
  systemctl enable awg-quick@awg0 2>/dev/null && ok "Автозапуск включён" || \
    warn "Не удалось включить автозапуск"
}

# ══════════════════════════════════════════════════════════
# 3. ДОБАВИТЬ КЛИЕНТА
# ══════════════════════════════════════════════════════════
do_add_client() {
  [[ ! -f "$SERVER_CONF" ]] && { warn "Конфиг сервера не найден. Сначала пункт 2 — возврат в главное меню"; return 0; }
  command -v awg &>/dev/null || { warn "awg не найден — возврат в главное меню"; return 0; }

  local server_net base_ip client_addr
  server_net=$(grep "^Address" "$SERVER_CONF" | awk -F'=' '{print $2}' | tr -d ' ' | head -1)
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

  read -rp "$(echo -e "${C}  Использовать IP $client_addr? [Y/n]: ${N}")" CONFIRM_IP
  CONFIRM_IP=${CONFIRM_IP:-y}
  if [[ ! $CONFIRM_IP =~ ^[Yy]$ ]]; then
    read -rp "  IP вручную (пример: ${base_ip}.5/32): " client_addr
    [[ -z "$client_addr" ]] && { warn "IP не введён — возврат"; return 0; }
  fi

  choose_dns

  info "Версия сервера: AWG 2.0"

  # MTU: по умолчанию из конфига сервера, но даём возможность override
  local srv_mtu
  srv_mtu=$(grep "^MTU = " "$SERVER_CONF" | awk -F'= ' '{print $2}' | head -1 || true)
  srv_mtu=${srv_mtu:-1380}
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
  read -rp "$(echo -e "${C}  Выбор [1-8] (Enter = 1): ${N}")" MTU_SEL
  MTU_SEL=${MTU_SEL:-1}
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
    *) MTU="$srv_mtu" ;;
  esac

  local i1_line="" i2_line="" i3_line="" i4_line="" i5_line=""
  hdr "⌘  Выбор I1 для клиента"
  echo "  1) Использовать I1-I5 из серверного конфига"
  echo "  2) Сгенерировать новый I1-I5 (выбор уровня + профиля мимикрии)"
  echo "  3) Без I1 (только H/S/Jc обфускация)"
  read -rp "$(echo -e "${C}  Выбор [1-3] (Enter = 1): ${N}")" I1_SELECT
  I1_SELECT=${I1_SELECT:-1}

  case $I1_SELECT in
    1)
      i1_line=$(grep "^I1 = " "$SERVER_CONF" | head -1 || true)
      i2_line=$(grep "^I2 = " "$SERVER_CONF" | head -1 || true)
      i3_line=$(grep "^I3 = " "$SERVER_CONF" | head -1 || true)
      i4_line=$(grep "^I4 = " "$SERVER_CONF" | head -1 || true)
      i5_line=$(grep "^I5 = " "$SERVER_CONF" | head -1 || true)
      [[ -z "$i1_line" ]] && info "I1 не найден в конфиге сервера (уровень = базовый)" || true
      ;;
    2)
      choose_obf_level
      choose_mimicry_profile
      [[ -n "$I1" ]] && i1_line="I1 = $I1" || i1_line=""
      [[ -n "$I2" ]] && i2_line="I2 = $I2" || i2_line=""
      [[ -n "$I3" ]] && i3_line="I3 = $I3" || i3_line=""
      [[ -n "$I4" ]] && i4_line="I4 = $I4" || i4_line=""
      [[ -n "$I5" ]] && i5_line="I5 = $I5" || i5_line=""
      ;;
    3)
      i1_line=""
      i2_line=""
      i3_line=""
      i4_line=""
      i5_line=""
      ;;
  esac

  local srv_pub srv_ip port mtu
  srv_pub=$(awg show awg0 public-key 2>/dev/null) \
    || { err "awg0 не поднят. Запусти: awg-quick up $SERVER_CONF"; return 1; }
  srv_ip=$(get_public_ip)
  [[ -z "$srv_ip" ]] && { err "не удалось получить внешний IP"; return 1; }
  port=$(grep "^ListenPort = " "$SERVER_CONF" | awk -F'= ' '{print $2}' | tr -d ' ')
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

  command -v qrencode &>/dev/null && qrencode -t ansiutf8 -s 1 -m 1 < "$client_file"

  echo ""
  success_box "▣  Клиент добавлен успешно"
  echo -e "${W}  Имя    : ${N}$client_name"
  echo -e "${W}  IP     : ${N}$client_addr"
  echo -e "${W}  Конфиг : ${N}$client_file"
}

# ══════════════════════════════════════════════════════════
# 4. ПОКАЗАТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
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
  echo -e "  ${W}│${N}  » IP:       ${W}$ip${N}"
  echo -e "  ${W}│${N}  ↑ Трафик:   ↑ ${G}$tx_fmt${N}  ↓ ${C}$rx_fmt${N}"
  echo -e "  ${W}│${N}  ∑ Статус:   $status_icon $status_text"
  if [[ -n "$endpoint_short" ]]; then
    echo -e "  ${W}│${N}  » Endpoint: ${Y}$endpoint_short${N}"
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

  [[ ${#found[@]} -eq 0 ]] && { err "Конфиги клиентов не найдены в /root/"; return 1; }

  local unique
  mapfile -t unique < <(printf "%s\n" "${found[@]}" | sort -u)

  hdr "≡  Выбери конфиг"
  local i=0
  for f in "${unique[@]}"; do
    i=$((i+1))
    echo "  $i) $(basename "$f")"
  done

  local QR_CHOICE
  local prompt_txt
  if [[ $i -eq 1 ]]; then
    prompt_txt="  Выбор [1] (Enter = 1): "
  else
    prompt_txt="  Выбор [1-$i] (Enter = 1): "
  fi
  read -rp "$(echo -e "${C}${prompt_txt}${N}")" QR_CHOICE
  QR_CHOICE=${QR_CHOICE:-1}
  if ! [[ "$QR_CHOICE" =~ ^[0-9]+$ ]] || \
     ! [[ "$QR_CHOICE" -ge 1 ]] || \
     ! [[ "$QR_CHOICE" -le $i ]]; then
    warn "Неверный выбор (1-$i) — возврат в главное меню"
    return 0
  fi

  local idx=$((QR_CHOICE - 1))
  local chosen="${unique[$idx]}"
  [[ -f "$chosen" ]] || { warn "Файл не найден: $chosen — возврат в главное меню"; return 0; }

  qrencode -t ansiutf8 -s 1 -m 1 < "$chosen"
  echo ""
  echo -e "${Y}  ──────────────────────────────────────────────${N}"
  echo -e "${W}  ≡  Или сохрани текст ниже в файл client.conf${N}"
  echo -e "${W}     Импортируй в AmneziaVPN: Добавить туннель → Из файла${N}"
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
  hdr "↻  Перезапуск awg0"
  if [[ ! -f "$SERVER_CONF" ]]; then
    err "Конфиг сервера не найден"
    echo -e "  ${Y}→ Возможно, AmneziaWG ещё не установлен${N}"
    echo -e "  ${Y}→ Выбери пункт 1 для установки зависимостей${N}"
    echo -e "  ${Y}→ Затем пункт 2 для создания сервера${N}"
    echo ""
    local CONFIRM_INSTALL
    read -rp "$(echo -e "${G}  Установить сейчас? [y/N]: ${N}")" CONFIRM_INSTALL
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

# ══════════════════════════════════════════════════════════
# 7. УДАЛИТЬ ВСЁ
# ══════════════════════════════════════════════════════════
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
  read -rp "$(echo -e "${R}  Подтверди удаление [yes/N]: ${N}")" CONFIRM_DEL
  [[ "$CONFIRM_DEL" != "yes" ]] && { warn "Отменено."; return 0; }

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

  trash "Удаляем UFW правила..."
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
# Параллельный пинг всех доменов из 4 пулов.
# Результаты сохраняются в кэш /tmp/awg_domain_cache.txt.
do_check_domains() {
  echo ""
  hdr "◎  Проверка доступности доменов для мимикрии"
  echo ""

  local cache_file="/tmp/awg_domain_cache.txt"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # ── Пулы доменов (порядок важен — индексы используются ниже) ──
  local tls_domains=(yandex.ru vk.com mail.ru ozon.ru wildberries.ru sberbank.ru tbank.ru gosuslugi.ru github.com google.com)
  local tls_ch_domains=(yandex.ru vk.com mail.ru github.com gitlab.com microsoft.com apple.com stackoverflow.com)
  local dtls_domains=(stun.yandex.net stun.vk.com stun.mail.ru meet.jit.si stun.stunprotocol.org)
  local sip_domains=(sip.beeline.ru sip.mts.ru sip.yandex.ru sip.iptel.org)

  # Объединяем для одного параллельного пинга
  local all_domains=("${tls_domains[@]}" "${tls_ch_domains[@]}" "${dtls_domains[@]}" "${sip_domains[@]}")
  local total=${#all_domains[@]}
  local avail_count=0
  local tmpdir="/tmp/awg_ping_$$"
  mkdir -p "$tmpdir"

  # Ловушка на прерывание — cleanup + выход
  trap 'rm -rf "$tmpdir"; exit 1' INT TERM

  # Параллельный пинг всех доменов
  for domain in "${all_domains[@]}"; do
    (timeout 2 ping -c 1 -W 1 "$domain" &>/dev/null 2>&1 && echo "ok" || echo "fail") > "$tmpdir/${domain//./_}" &
  done
  wait  # Ждём все

  # Хелпер: прочитать результат пинга одного домена
  _ping_result() {
    local domain="$1"
    local key="${domain//./_}"
    cat "$tmpdir/$key" 2>/dev/null || echo "fail"
  }

  # Хелпер: обработать пул — вывести на экран и записать в кэш
  _check_pool() {
    local pool_label="$2"
    shift 2
    local domains=("$@")
    local d
    for d in "${domains[@]}"; do
      if [[ "$(_ping_result "$d")" == "ok" ]]; then
        echo -e "    ${G}√${N} $d"
        echo "${pool_label}|$d|ok|$ts" >> "$cache_file"
        avail_count=$((avail_count + 1))
      else
        echo -e "    ${R}×${N} $d"
        echo "${pool_label}|$d|fail|$ts" >> "$cache_file"
      fi
    done
  }

  : > "$cache_file"

  # --- TLS / General ---
  echo -e "${C}  ◎ TLS / General домены:${N}"
  _check_pool "TLS" "tls" "${tls_domains[@]}"

  # --- TLS 1.3 Client Hello ---
  echo ""
  echo -e "${C}  ◎ TLS 1.3 Client Hello (HTTPS):${N}"
  _check_pool "TLS 1.3 Client Hello" "tls_ch" "${tls_ch_domains[@]}"

  # --- DTLS ---
  echo ""
  echo -e "${C}  ◎ DTLS (WebRTC/STUN):${N}"
  _check_pool "DTLS" "dtls" "${dtls_domains[@]}"

  # --- SIP ---
  echo ""
  echo -e "${C}  ◎ SIP (VoIP):${N}"
  _check_pool "SIP" "sip" "${sip_domains[@]}"

  # Cleanup
  rm -rf "$tmpdir"
  trap - INT TERM

  echo ""
  hdr "∑  Результат проверки"
  echo -e "${G}  √ Доступно: $avail_count из $total доменов${N}"
  echo -e "${C}  → Кэш сохранён: $cache_file${N}"

  if [[ $avail_count -lt $total ]]; then
    echo -e "${Y}  ! Часть доменов недоступна — при выборе мимикрии используются только доступные${N}"
  fi

  return 0
}

# ══════════════════════════════════════════════════════════
# 9. ОЧИСТИТЬ КЛИЕНТОВ
# ══════════════════════════════════════════════════════════
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
  read -rp "$(echo -e "${R}  Подтвердить удаление клиентов? [yes/N]: ${N}")" CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { warn "Отменено."; return 0; }

  trash "Останавливаем awg0..."
  awg-quick down "$SERVER_CONF" 2>/dev/null || true

  # Backup ДО изменений
  local clean_bak="${SERVER_CONF}.bak.clean.$(date +%s)"
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
}

# ══════════════════════════════════════════════════════════
# 10. БЕКАП AWG 2.0
# ══════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════
# 11. ВОССТАНОВЛЕНИЕ ИЗ БЕКАПА
# ══════════════════════════════════════════════════════════
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
MTU=""
AWG_PARAMS_LINES=""
ERROR_COUNT=0

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/awg-manager.log"
log_info "=== AWG Toolza v5.2 запущен ==="

# Trap EXIT — cleanup временных файлов
trap 'rm -rf /tmp/awg_tmp_* /tmp/awg_ping_* 2>/dev/null || true' EXIT

while true; do
  check_deps
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
   12) do_sniff_test ;;
    0) log_info "Выход"
       echo -e "\n${G}  В путь! ${N}"
       echo -e "\n▓▒░ DPI ОТСТОЙ! ░▒▓"
       echo -e "<< НЕТ КОНТРОЛЮ! >>"
       echo -e "<< VIVAT СВОБОДНЫЙ ИНТЕРНЕТ!!! >>\n"
       exit 0 ;;
    *)
      warn "Неверный выбор"
      ERROR_COUNT=$((ERROR_COUNT + 1))
      if [[ $ERROR_COUNT -ge 5 ]]; then
        err "Слишком много неверных выборов. Выход."
        log_err "Слишком много неверных выборов — выход"
        exit 1
      fi
      ;;
  esac

  if [[ "${CHOICE:-}" =~ ^[0-9]+$ ]] && [[ "${CHOICE:-}" -le 12 ]]; then
    ERROR_COUNT=0
  fi

  # Сбрасываем CHOICE — защита от повторного срабатывания предыдущего выбора
  # при следующем show_menu (если пользователь нажмёт Enter без ввода)
  CHOICE=""
  echo ""
  read -rp "$(echo -e "${C}  Enter для продолжения...${N}")" || break
done
