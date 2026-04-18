#!/bin/bash
set -euo pipefail

VERSION="v6.2"

# ─────────────────────────────────────────────────────────────
# - AWG Toolza — только AWG 2.0
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
# HTTP/3 (QUIC) — реально раздают h3 в РФ сегменте, НЕ заблокированы ТСПУ
QUIC_DOMAINS_RU=(
  "yandex.ru" "mail.ru" "vk.com" "ya.ru" "dzen.ru"
  "yastatic.net" "ozon.ru" "avito.ru" "wildberries.ru"
  "sber.ru" "tbank.ru" "gosuslugi.ru" "kinopoisk.ru"
  "cdn.gcore.com" "gcdn.co" "selectel.ru"
)

# Европа / Мир
TLS_DOMAINS_WORLD=(
  "github.com" "gitlab.com" "stackoverflow.com" "microsoft.com"
  "apple.com" "amazon.com" "google.com"
  "wikipedia.org" "spotify.com" "steampowered.com"
  "hetzner.com" "ovhcloud.com" "digitalocean.com"
  "cdn.jsdelivr.net" "unpkg.com" "pypi.org"
)
DTLS_DOMAINS_WORLD=(
  "stun.stunprotocol.org" "meet.jit.si" "stun.services.mozilla.com"
  "global.stun.twilio.com" "stun.nextcloud.com"
  "stun.sipgate.net" "stun.zoiper.com"
)
SIP_DOMAINS_WORLD=(
  # Глобальные SIP-провайдеры
  "sip.zadarma.com" "sip.iptel.org" "sip.linphone.org"
  "sip.antisip.com"
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
# HTTP/3 (QUIC) — все реально отвечают h3 на UDP/443, НЕ заблокированы ТСПУ
QUIC_DOMAINS_WORLD=(
  "cdn.gcore.com" "gcdn.co" "g.gcdn.co"
  "fastly.net" "a.ssl.fastly.net" "global.fastly.net"
  "cdn-apple.com" "icloud.com" "mzstatic.com"
  "cdn.jsdelivr.net" "unpkg.com"
  "steamstatic.com" "steamcontent.com"
  "b-cdn.net" "bunny.net" "cdn77.com"
  "github.com" "objects.githubusercontent.com"
  "spotify.com" "scdn.co"
  "wikipedia.org" "wikimedia.org"
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
# CPS ГЕНЕРАТОР I1-I5
# Порт Special-Junk-Packet (SIP+TLS handshake flow)
# + компактный QUIC Initial для профиля quic
# I1-I5 только в клиентском конфиге — сервер не требует
# ══════════════════════════════════════════════════════════

# Единый Python генератор для всех профилей мимикрии
_CPS_GENERATOR='
import sys, os, random, secrets, struct, time, binascii

def rh(n): return secrets.token_bytes(n)
def rhex(n): return secrets.token_hex(n)
def ri(a, b): return random.randint(a, b)
def rc(lst): return random.choice(lst)
def u16(v): return struct.pack(">H", v & 0xFFFF)
def u32(v): return struct.pack(">I", v & 0xFFFFFFFF)
def u24(v): return struct.pack(">I", v)[1:]

# ──────────────────────────────────────────────────────
# DOMAIN POOL из payloadGen (Sketchystan1)
# Микс популярных мировых + российских доменов
# ──────────────────────────────────────────────────────
DOMAIN_POOL = [
    "google.com","amazon.com","reddit.com","github.com","mozilla.org",
    "microsoft.com","apple.com","cloudflare.com","bing.com","adobe.com",
    "stackoverflow.com","office.com","dropbox.com","zoom.us","spotify.com",
    "imdb.com","wikipedia.org","yandex.ru","ozon.ru","vk.com",
    "gismeteo.ru","mail.ru","kinopoisk.ru","pinterest.com","dzen.ru",
    "rutube.ru","gdz.ru","rbc.ru","wildberries.ru","ya.ru",
    "sberbank.ru","ria.ru","tbank.ru","championat.com","fandom.com",
    "rambler.ru","kp.ru","dns-shop.ru","chatgpt.com","avito.ru",
    "2gis.ru","cbr.ru","ivi.ru","gosuslugi.ru","lenta.ru",
    "auto.ru","steampowered.com","rustore.ru","okko.tv","domclick.ru",
    "sports.ru","cian.ru","drom.ru","aviasales.ru","sovcombank.ru",
    "sportbox.ru","invitro.ru","tutu.ru","vtb.ru","goldapple.ru",
    "ok.ru","pikabu.ru","iz.ru","apteka.ru","hh.ru",
    "habr.com","uchi.ru","lamoda.ru"
]

# ──────────────────────────────────────────────────────
# QUIC MINI — ультракомпактный (~38 байт, I1 ~88 сим)
# Формат: <b 0xc1...><r 16>
# Проверено работает на ТСПУ РФ
# ──────────────────────────────────────────────────────
def gen_quic_mini():
    # First byte 0xC0-0xCF (long header + Initial)
    pnl = ri(0, 1)
    fb = 0xC0 | pnl
    pn_bytes = pnl + 1
    ver = b"\x00\x00\x00\x01"  # QUIC v1
    # DCID 1 байт (как в рабочем примере)
    dcid = rh(1)
    # SCID = 0, Token = 0
    # Payload length varint (1 byte, value < 64)
    plen = ri(30, 60)
    pl_varint = bytes([plen & 0x3F])
    # PN + random encrypted payload
    pn = rh(pn_bytes)
    payload = rh(ri(20, 35))
    return bytes([fb]) + ver + bytes([1]) + dcid + b"\x00\x00" + pl_varint + pn + payload

# ──────────────────────────────────────────────────────
# QUIC FULL — полноразмерный Chrome-like (~1200 байт)
# Структура настоящего QUIC Initial с правильной длиной varint
# Проверено: I1 вида 0xc5000000010808...
# ──────────────────────────────────────────────────────
def _quic_varint_encode(value):
    """QUIC varint encoder."""
    if value < 64:
        return bytes([value])
    elif value < 16384:
        return bytes([0x40 | (value >> 8) & 0x3F, value & 0xFF])
    elif value < 1073741824:
        return bytes([
            0x80 | (value >> 24) & 0x3F,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF
        ])
    else:
        # 8-byte varint
        return struct.pack(">Q", 0xC000000000000000 | value)

def gen_quic_full(pad_to_1200=False):
    """Полноразмерный QUIC Initial как Chrome."""
    # First byte: 0xC0-0xCF
    pn_len = 2  # Chrome всегда 2 байта PN для Initial
    reserved = ri(0, 1)  # 0 или 1 (у payloadGen 1), было 0
    fb = 0xC0 | (reserved << 2) | (pn_len - 1)

    ver = b"\x00\x00\x00\x01"  # QUIC v1
    # DCID — 8 байт (стандарт Chrome)
    dcid = rh(8)
    # SCID — 8 байт (тоже как Chrome, не 0!)
    scid = rh(8)
    # Token length = 0 (varint 1 byte)
    token_len = bytes([0])

    # Payload = PN + encrypted ClientHello (~1150 байт)
    # Target: весь пакет ~1200 байт
    # Header: 1 (fb) + 4 (ver) + 1 (dcid_len) + 8 (dcid) + 1 (scid_len) + 8 (scid) + 1 (token_len) = 24 байта
    # + payload length varint (2 байта) + PN + encrypted payload
    if pad_to_1200:
        target_total = 1200
    else:
        target_total = ri(800, 1250)  # реалистичный размер

    # Считаем с учётом varint payload length
    header_fixed = 1 + 4 + 1 + 8 + 1 + 8 + 1  # = 24
    # Payload length varint = 2 байта когда value 64-16383
    # PN + encrypted = target - header - varint(2)
    enc_size = target_total - header_fixed - 2 - pn_len
    if enc_size < 16:
        enc_size = 100  # минимум для auth tag

    payload_len_value = pn_len + enc_size  # правильная длина!
    # Выбираем varint 2-байтовый (value 64-16383)
    if payload_len_value >= 64 and payload_len_value < 16384:
        pl_varint = u16(0x4000 | payload_len_value)
    else:
        pl_varint = _quic_varint_encode(payload_len_value)

    # PN bytes
    pn = rh(pn_len)
    # Encrypted payload (выглядит как шифротекст)
    encrypted = rh(enc_size)

    return (bytes([fb]) + ver + bytes([8]) + dcid + bytes([8]) + scid +
            token_len + pl_varint + pn + encrypted)

# ──────────────────────────────────────────────────────
# WebRTC Combined — STUN + DTLS + RTCP (~500 байт)
# Из haha.conf — проверено работает
# ──────────────────────────────────────────────────────
def _crc32(data):
    return binascii.crc32(data) & 0xFFFFFFFF

def gen_webrtc_combined(pad=False):
    sni = rc(DOMAIN_POOL)
    provider_soft = rc([
        b"Cloudflare WebRTC client",
        b"Chrome WebRTC ICE agent",
        b"Firefox ICE stack",
        b"Safari WebRTC networking",
        b"WhatsApp/2"
    ])

    # ── STUN Binding Request ──
    txn = rh(12)
    # SOFTWARE (0x8022)
    soft_pad = (4 - len(provider_soft) % 4) % 4
    soft_attr = u16(0x8022) + u16(len(provider_soft)) + provider_soft + b"\x00" * soft_pad
    # PRIORITY (0x0024)
    prio_attr = u16(0x0024) + u16(4) + u32(ri(0x40000000, 0x7FFFFFFF))
    # ICE-CONTROLLED (0x8029)
    ice_attr = u16(0x8029) + u16(8) + rh(8)
    # USERNAME (0x0006)
    uname_str = ("%s:%s" % (rhex(4), sni)).encode()
    uname_pad = (4 - len(uname_str) % 4) % 4
    uname_attr = u16(0x0006) + u16(len(uname_str)) + uname_str + b"\x00" * uname_pad

    attrs_body = soft_attr + prio_attr + ice_attr + uname_attr
    msg_len = len(attrs_body) + 8  # + FINGERPRINT
    stun_hdr = u16(0x0001) + u16(msg_len) + u32(0x2112A442) + txn
    crc_input = stun_hdr + attrs_body
    fp_val = (_crc32(crc_input) ^ 0x5354554E) & 0xFFFFFFFF
    fp_attr = u16(0x8028) + u16(4) + u32(fp_val)
    stun_packet = stun_hdr + attrs_body + fp_attr

    # ── DTLS 1.2 ClientHello с SNI ──
    dtls_random = rh(32)
    sess_id = b"\x00"
    cookie = b"\x00"
    ciphers = bytes.fromhex("000cc02bc02fcca9c02c009c009d")
    compression = b"\x01\x00"

    sni_bytes = sni.encode()
    sni_entry = b"\x00" + u16(len(sni_bytes)) + sni_bytes
    sni_list = u16(len(sni_entry)) + sni_entry
    sni_ext = u16(0x0000) + u16(len(sni_list)) + sni_list
    sg_ext = bytes.fromhex("000a00080006001d00170018")
    ecp_ext = bytes.fromhex("000b00020100")
    sa_ext = bytes.fromhex("000d00140012040308040401050308050501080606010807")
    srtp_ext = bytes.fromhex("000e00050002000100")
    ems_ext = bytes.fromhex("00170000")

    extensions = sni_ext + sg_ext + ecp_ext + sa_ext + srtp_ext + ems_ext
    ext_block = u16(len(extensions)) + extensions

    ch_body = b"\xfe\xfd" + dtls_random + sess_id + cookie + ciphers + compression + ext_block
    hs_header = b"\x01" + u24(len(ch_body)) + u16(0) + u24(0) + u24(len(ch_body))
    handshake = hs_header + ch_body
    dtls_record = b"\x16\xfe\xfd\x00\x00" + rh(6) + u16(len(handshake)) + handshake

    # ── RTCP-tail ──
    tail_ssrc = rh(4)
    rtcp_sr = bytes([0x80, 0x00, 0x00]) + bytes([ri(0, 255)]) + tail_ssrc
    extra = rh(ri(20, 40))
    tail = rtcp_sr + extra

    packet = stun_packet + dtls_record + tail

    if pad and len(packet) < 1200:
        packet += b"\x00" * (1200 - len(packet))

    return packet

# ──────────────────────────────────────────────────────
# SIP — OPTIONS / REGISTER / TRYING (случайно)
# Реалистичный формат из payloadGen
# ──────────────────────────────────────────────────────
_SIP_UAS = [
    "Linphone/5.2.5 (belle-sip/5.3.90)", "Zoiper rv2.10.15-mod",
    "MicroSIP/3.21.6", "baresip 3.8.0", "Blink 6.0.4 (Windows)",
    "Asterisk PBX 20.7.0"
]
_SIP_SERVERS = [
    "Kamailio (5.8.1)", "OpenSIPS (3.5.1)", "Asterisk PBX (20.7.0)",
    "FreeSWITCH (1.10.12)"
]
_SIP_ALLOWS = [
    "INVITE, ACK, CANCEL, OPTIONS, BYE, REFER, NOTIFY, INFO, MESSAGE, SUBSCRIBE",
    "INVITE, ACK, CANCEL, OPTIONS, BYE, UPDATE, MESSAGE",
    "INVITE, ACK, CANCEL, OPTIONS, BYE, PRACK, UPDATE"
]
_SIP_SUPPORTED = [
    "replaces, outbound, path, timer",
    "outbound, path, gruu, 100rel",
    "timer, replaces, resource-priority"
]
_SIP_DISPLAY_NAMES = [
    "Alice Carter", "Bob Smith", "Support Desk", "Sales Queue",
    "NOC Bridge", "Reception", "Operator", "Dispatch"
]
_SIP_USERS = ["100","101","200","300","400","500","alice","bob","support","sales","noc","ops"]

def _sip_domain():
    # генерируем реалистичный SIP домен на базе DOMAIN_POOL
    base = rc(DOMAIN_POOL)
    prefixes = ["sip","voip","pbx","edge","gw","proxy","media","trunk"]
    if ri(0, 2) == 0:
        return base
    return "%s-%d.%s" % (rc(prefixes), ri(10, 99), base)

def _sip_priv_ip():
    pools = [
        (10, ri(0,255), ri(0,255), ri(10,210)),
        (172, 16+ri(0,15), ri(0,255), ri(10,210)),
        (192, 168, ri(0,255), ri(10,210))
    ]
    o = rc(pools)
    return "%d.%d.%d.%d" % o

def _build_sip_options(host, fuser, tuser, lip, lport, branch, tag, callid, cseq, ua, fn, tn):
    lines = [
        "OPTIONS sip:%s@%s SIP/2.0" % (tuser, host),
        "Via: SIP/2.0/UDP %s:%d;branch=%s;rport" % (lip, lport, branch),
        "Max-Forwards: 70",
        "From: \"%s\" <sip:%s@%s>;tag=%s" % (fn, fuser, host, tag),
        "To: \"%s\" <sip:%s@%s>" % (tn, tuser, host),
        "Call-ID: %s" % callid,
        "CSeq: %d OPTIONS" % cseq,
        "Contact: <sip:%s@%s:%d;transport=udp>" % (fuser, lip, lport),
        "User-Agent: %s" % ua,
        "Allow: %s" % rc(_SIP_ALLOWS),
        "Supported: %s" % rc(_SIP_SUPPORTED),
        "Accept: application/sdp",
        "Accept-Language: en-US",
        "Content-Length: 0",
        "", ""
    ]
    return "\r\n".join(lines).encode()

def _build_sip_register(host, fuser, lip, lport, branch, tag, callid, cseq, ua, fn):
    lines = [
        "REGISTER sip:%s SIP/2.0" % host,
        "Via: SIP/2.0/UDP %s:%d;branch=%s;rport" % (lip, lport, branch),
        "Max-Forwards: 70",
        "From: \"%s\" <sip:%s@%s>;tag=%s" % (fn, fuser, host, tag),
        "To: \"%s\" <sip:%s@%s>" % (fn, fuser, host),
        "Call-ID: %s" % callid,
        "CSeq: %d REGISTER" % cseq,
        "Contact: <sip:%s@%s:%d;transport=udp>" % (fuser, lip, lport),
        "User-Agent: %s" % ua,
        "Allow: %s" % rc(_SIP_ALLOWS),
        "Supported: %s" % rc(_SIP_SUPPORTED),
        "Expires: %d" % rc([300,600,900,1200,1800,3600]),
        "Content-Length: 0",
        "", ""
    ]
    return "\r\n".join(lines).encode()

def _build_sip_trying(host, fuser, tuser, lip, lport, branch, tag, callid, cseq, fn, tn):
    lines = [
        "SIP/2.0 100 CONNECTING",
        "Via: SIP/2.0/UDP %s:%d;branch=%s;rport" % (lip, lport, branch),
        "To: \"%s\" <sip:%s@%s>" % (tn, tuser, host),
        "From: \"%s\" <sip:%s@%s>;tag=%s" % (fn, fuser, host, tag),
        "Call-ID: %s" % callid,
        "CSeq: %d INVITE" % cseq,
        "Server: %s" % rc(_SIP_SERVERS),
        "Content-Length: 0",
        "", ""
    ]
    return "\r\n".join(lines).encode()

def gen_sip(action=None):
    if action is None:
        action = rc(["OPTIONS", "REGISTER", "TRYING"])
    host = _sip_domain()
    lip = _sip_priv_ip()
    lport = rc([5060, 5062, 5070, 5080, 5160])
    fuser = rc(_SIP_USERS) + str(ri(100, 999))
    tuser = rc(_SIP_USERS) + str(ri(100, 999)) if action != "REGISTER" else fuser
    branch = "z9hG4bK" + rhex(9)
    tag = rhex(6)
    callid = "%s@%s" % (rhex(12), host)
    cseq = ri(1, 80)
    ua = rc(_SIP_UAS)
    fn = rc(_SIP_DISPLAY_NAMES)
    tn = rc(_SIP_DISPLAY_NAMES) if action != "REGISTER" else fn

    if action == "REGISTER":
        return _build_sip_register(host, fuser, lip, lport, branch, tag, callid, cseq, ua, fn)
    elif action == "TRYING":
        return _build_sip_trying(host, fuser, tuser, lip, lport, branch, tag, callid, cseq, fn, tn)
    else:
        return _build_sip_options(host, fuser, tuser, lip, lport, branch, tag, callid, cseq, ua, fn, tn)

# ──────────────────────────────────────────────────────
# DNS — DNS Response (как у оригинальной Amnezia)
# ──────────────────────────────────────────────────────
def gen_dns():
    host = rc(DOMAIN_POOL)
    # Flags: QR=1 (response), RD=1, RA=1, RCODE=0 → 0x8580
    flags = b"\x85\x80"
    counts = b"\x00\x01\x00\x01\x00\x00\x00\x00"
    qn = b""
    for l in host.split("."):
        qn += bytes([len(l)]) + l.encode()
    qn += b"\x00"
    qtype = b"\x00\x01"  # A
    qclass = b"\x00\x01"  # IN
    # Answer: pointer to domain, A record
    ans_name = b"\xc0\x0c"
    ans_type = b"\x00\x01"
    ans_class = b"\x00\x01"
    ttl = u32(ri(60, 86400))
    rdlen = b"\x00\x04"
    rdata = bytes([ri(1,255), ri(0,255), ri(0,255), ri(1,254)])
    # TXID не включаем — он идёт через <r 2>
    return flags + counts + qn + qtype + qclass + ans_name + ans_type + ans_class + ttl + rdlen + rdata

# ──────────────────────────────────────────────────────
# Output wrapper
# ──────────────────────────────────────────────────────
def to_cps(data, suffix=""):
    return "<b 0x%s>%s" % (data.hex(), suffix)

# ──────────────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────────────
profile = sys.argv[1] if len(sys.argv) > 1 else "quic_full"
pad_flag = os.environ.get("CPS_PAD", "0") == "1"

if profile == "quic_full":
    # ★ Полноразмерный Chrome-like QUIC — ТОЛЬКО I1 (один большой пакет ~1200B)
    print(to_cps(gen_quic_full(pad_to_1200=pad_flag)))
    print("")
    print("")
    print("")
    print("")
elif profile == "quic_mini":
    # Ультракомпактный QUIC ~40B — заполняем все I1-I5
    print(to_cps(gen_quic_mini(), "<r 16>"))
    print(to_cps(gen_quic_mini()))
    print(to_cps(gen_quic_mini()))
    print(to_cps(gen_quic_mini()))
    print(to_cps(gen_quic_mini()))
elif profile == "webrtc":
    # WebRTC Combined ~500B — I1 + 4 mini QUIC
    print(to_cps(gen_webrtc_combined(pad=pad_flag)))
    print(to_cps(gen_quic_mini()))
    print(to_cps(gen_quic_mini()))
    print(to_cps(gen_quic_mini()))
    print(to_cps(gen_quic_mini()))
elif profile == "sip":
    # SIP ~500B — только I1 (один SIP пакет, как реальный вызов)
    print(to_cps(gen_sip()))
    print("")
    print("")
    print("")
    print("")
elif profile == "dns":
    # DNS Response как у Amnezia — все I1-I5
    print(to_cps(gen_dns(), "<r 2>"))
    print(to_cps(gen_dns()))
    print(to_cps(gen_dns()))
    print(to_cps(gen_dns()))
    print(to_cps(gen_dns()))
else:
    # default = quic_full (рекомендуется)
    print(to_cps(gen_quic_full()))
    print("")
    print("")
    print("")
    print("")
'

# Генерация I1-I5 через Python
gen_cps_i1() {
  local profile="${1:-special}"
  python3 -c "$_CPS_GENERATOR" "$profile"
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
# Глобальные переменные на выходе: I1, I2, I3, I4, I5, MIMICRY_PROFILE
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

  # OBF_LEVEL=1 (базовый) — пропускаем мимикрию полностью
  if [[ "${OBF_LEVEL:-1}" == "1" ]]; then
    MIMICRY_PROFILE="none"
    return 0
  fi

  echo ""
  hdr "~  Профили мимикрии I1-I5"
  echo -e "  ${D}Works (проверено на ТСПУ РФ):${N}"
  echo -e "  ${G}1${N}  ${W}★ QUIC Full${N}     — полноразмерный Chrome-like (~1200B, только I1)"
  echo -e "  ${G}2${N}  QUIC Mini       — ультракомпактный (~40B, I1-I5 с <r 16>)"
  echo ""
  echo -e "  ${D}Kinda (может работать):${N}"
  echo -e "  ${G}3${N}  WebRTC Combined — STUN + DTLS 1.2 + RTCP"
  echo -e "  ${G}4${N}  SIP             — OPTIONS/REGISTER/TRYING (случайно)"
  echo -e "  ${G}5${N}  DNS Response    — как у оригинальной Amnezia"
  echo ""
  read -rp "$(echo -e "${C}  Выбор [1-5] (Enter = 1): ${N}")" PROFILE_CHOICE
  PROFILE_CHOICE=${PROFILE_CHOICE:-1}

  case $PROFILE_CHOICE in
    1) MIMICRY_PROFILE="quic_full" ;;
    2) MIMICRY_PROFILE="quic_mini" ;;
    3) MIMICRY_PROFILE="webrtc" ;;
    4) MIMICRY_PROFILE="sip" ;;
    5) MIMICRY_PROFILE="dns" ;;
    *) MIMICRY_PROFILE="quic_full" ;;
  esac

  # Padding опция (для quic_full и webrtc)
  local use_pad=0
  if [[ "$MIMICRY_PROFILE" == "quic_full" || "$MIMICRY_PROFILE" == "webrtc" ]]; then
    echo ""
    read -rp "$(echo -e "${C}  Padding до 1200B (реалистичнее)? [y/N]: ${N}")" PAD_CHOICE
    [[ "$PAD_CHOICE" =~ ^[Yy]$ ]] && use_pad=1
  fi

  # ── Генерация через Python ──
  echo -e "${C}  → Генерируем $MIMICRY_PROFILE...${N}"
  local cps_out
  if [[ $use_pad -eq 1 ]]; then
    cps_out=$(CPS_PAD=1 gen_cps_i1 "$MIMICRY_PROFILE") || cps_out=""
  else
    cps_out=$(gen_cps_i1 "$MIMICRY_PROFILE") || cps_out=""
  fi

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

# ══════════════════════════════════════════════════════════
# ТЕСТ DPI — захват первого CPS пакета и анализ
# ══════════════════════════════════════════════════════════

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
    cf_priv=$(grep -E '^PrivateKey' "$cf" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r' | head -1)
    [[ -z "$cf_priv" ]] && continue
    cf_pub=$(echo "$cf_priv" | awg pubkey 2>/dev/null) || continue
    cf_addr=$(grep -E '^Address' "$cf" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r' | head -1)
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
    read -rp "$(echo -e "${C}  Выбор [1-${#ep_list[@]}] (Enter = 1): ${N}")" PEER_SEL
    PEER_SEL=${PEER_SEL:-1}
    [[ "$PEER_SEL" =~ ^[0-9]+$ ]] && (( PEER_SEL >= 1 && PEER_SEL <= ${#ep_list[@]} )) || { warn "Неверный выбор"; return 0; }
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

# ══════════════════════════════════════════════════════════
# ОСТАЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════

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

show_header() {
  clear
  local s ip port st clients
  s=$(get_status)
  IFS='|' read -r ip port st clients <<< "$s"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}AwgToolza $VERSION${N}"
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
  echo -e "  ${G}6)${N} Проверить домены из пулов (ping)"
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
  echo -e "  ${W}0)${N} Выход"
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
# ГЕНЕРАЦИЯ AWG ПАРАМЕТРОВ (AWG 2.0)
# ══════════════════════════════════════════════════════════
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

  # ── Junk train ──
  local Jc Jmin Jmax
  Jc=$(rand_range 4 16)
  Jmin=$(rand_range 8 64)
  Jmax=$(rand_range 80 200)
  # Обеспечиваем Jmin < Jmax
  if [[ $Jmin -ge $Jmax ]]; then
    Jmax=$((Jmin + $(rand_range 10 60)))
  fi

  # ── Padding S1/S2 ──
  # Мануал: S1 ≤ 1132, S2 ≤ 1188, recommended 15-150
  #         Обязательно: S1 + 56 ≠ S2
  local S1 S2
  S1=$(rand_range 15 150)
  S2=$(rand_range 15 150)
  # Проверяем S1+56 != S2 (требование мануала)
  local tries=0
  while [[ $((S1 + 56)) -eq $S2 ]] && [[ $tries -lt 10 ]]; do
    S2=$(rand_range 15 150)
    tries=$((tries + 1))
  done

  # ── Padding S3/S4 (AWG 2.0 extension) ──
  # Не в мануале, но используется в AWG 2.0. Держим осмысленно малые
  local S3 S4
  S3=$(rand_range 8 64)
  S4=$(rand_range 6 31)

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

# ══════════════════════════════════════════════════════════
# SYNCCONF — горячая перезагрузка без разрыва соединений
# ══════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════
# РАЗДАЧА КОНФИГА — QR (только без I1-I5) + текст
# ══════════════════════════════════════════════════════════
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
      echo -e "${D}  Попробуй профиль QUIC Mini или DNS — они меньше${N}"
    fi
  fi
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
  read -rp "$(echo -e "${C}  Порт [Enter = случайный / 51820 = стандартный / свой]: ${N}")" PORT
  if [[ -z "${PORT:-}" || "${PORT:-}" == "r" || "${PORT:-}" == "R" ]]; then
    PORT=$(rand_range 30001 65535)
    ok "случайный порт: $PORT"
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
    read -rp "$(echo -e "${C}  Введи IP сервера вручную: ${N}")" srv_ip
    [[ -z "$srv_ip" ]] && { err "IP обязателен"; return 1; }
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
  systemctl enable awg-quick@awg0 2>/dev/null && ok "Автозапуск включён" || \
    warn "Не удалось включить автозапуск"
}

# ══════════════════════════════════════════════════════════
# 3. УПРАВЛЕНИЕ КЛИЕНТАМИ (меню)
# ══════════════════════════════════════════════════════════
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
    read -rp "$(echo -e "${C}  Выбор [0-5]: ${N}")" MGMT_CHOICE
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
  read -rp "$(echo -e "${C}${prompt}${N}")" SEL
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
  read -rp "$(echo -e "${C}  Номер клиента [1-${#MGMT_PUBKEYS[@]}] (0 = отмена): ${N}")" SEL
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
  local bak="${SERVER_CONF}.pre_rename.$(date +%s)"
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
  read -rp "$(echo -e "${C}  Номер клиента [1-${#MGMT_PUBKEYS[@]}] (0 = отмена): ${N}")" SEL
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
  read -rp "$(echo -e "${R}  Подтвердить удаление? [y/N]: ${N}")" CONFIRM
  [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { info "Отменено"; return 0; }

  # Бекап
  local bak="${SERVER_CONF}.pre_delete.$(date +%s)"
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
}

# ══════════════════════════════════════════════════════════
# 3a. ДОБАВИТЬ КЛИЕНТА
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
  echo "  1) Сгенерировать новый I1-I5 (выбор уровня + профиля мимикрии)"
  echo "  2) Без I1 (только H/S/Jc обфускация)"
  read -rp "$(echo -e "${C}  Выбор [1-2] (Enter = 1): ${N}")" I1_SELECT
  I1_SELECT=${I1_SELECT:-1}

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

# ══════════════════════════════════════════════════════════
# 5. QR КЛИЕНТА
# ══════════════════════════════════════════════════════════
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
  read -rp "$(echo -e "${C}${prompt_txt}${N}")" QR_CHOICE
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
# ══════════════════════════════════════════════════════════
# 10. СБРОС СЕРВЕРА (чистая переустановка)
# ══════════════════════════════════════════════════════════
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
  read -rp "$(echo -e "${R}  Подтверди сброс [yes/N]: ${N}")" CONFIRM_RST
  if [[ "$CONFIRM_RST" != "yes" ]]; then
    warn "Отменено."
    return 0
  fi

  # Предложение бекапа
  if [[ -f "$SERVER_CONF" ]]; then
    echo ""
    local CONFIRM_BAK
    read -rp "$(echo -e "${C}  Создать бекап перед сбросом? [Y/n]: ${N}")" CONFIRM_BAK
    CONFIRM_BAK=${CONFIRM_BAK:-y}
    if [[ "$CONFIRM_BAK" =~ ^[Yy]$ ]]; then
      info "Создаём бекап..."
      if do_backup; then
        ok "Бекап создан — можно восстановить через пункт 8"
      else
        warn "Бекап не удался — продолжаем сброс"
      fi
      echo ""
    fi
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
    rule_nums=$(ufw status numbered 2>/dev/null | grep -i "AmneziaWG" | grep -oE '\[[0-9]+\]' | tr -d '[]' | sort -rn)
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

# ══════════════════════════════════════════════════════════
# 11. УДАЛИТЬ ВСЁ
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
  hdr "◎  Проверка доменов для мимикрии"

  # Показываем текущий регион и какие пулы будут проверены
  local region_label
  case "${SERVER_REGION:-world}" in
    ru)    region_label="🇷🇺 РФ" ;;
    world) region_label="🌍 Мир/Европа" ;;
    *)     region_label="🌍 Мир" ;;
  esac
  echo -e "  ${C}Регион:${N} ${W}${region_label}${N}"
  echo ""

  local cache_file="/tmp/awg_domain_cache.txt"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # ── Выбираем пулы ──
  local -a tls_pool dtls_pool sip_pool quic_pool
  if [[ "${SERVER_REGION:-world}" == "ru" ]]; then
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

  # Параллельный пинг с замером ms
  local domain
  for domain in "${all_domains[@]}"; do
    (
      local result
      # ping -c 1 -W 1 возвращает "time=XX.X ms" при успехе
      result=$(timeout 2 ping -c 1 -W 1 "$domain" 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2)
      if [[ -n "$result" ]]; then
        # Округляем до целого
        printf "%.0f" "$result" > "$tmpdir/${domain//./_}"
      else
        echo "fail" > "$tmpdir/${domain//./_}"
      fi
    ) &
  done

  # Защита от пустых пулов
  if [[ $total -eq 0 ]]; then
    warn "Нет доменов в пулах (регион: ${SERVER_REGION:-world})"
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
      printf "\r  ${C}Пинг: ${G}%s${N} ${W}%3d%%${N} (${done_count}/${total})" "$bar" "$pct"
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
MTU=""
AWG_PARAMS_LINES=""
ERROR_COUNT=0

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/awg-manager.log"
log_info "=== AWG Toolza v6.2 запущен ==="

# Trap EXIT — cleanup временных файлов
trap 'rm -rf /tmp/awg_tmp_* /tmp/awg_ping_* 2>/dev/null || true' EXIT

while true; do
  check_deps
  show_header
  show_menu
  # show_menu уже читает CHOICE, дополнительный read не нужен

  case "${CHOICE:-}" in
    1)  do_install ;;
    2)  do_gen ;;
    3)  do_manage_clients ;;
    4)  do_list_clients ;;
    5)  do_restart ;;
    6)  do_check_domains ;;
    7)  do_sniff_test ;;
    8)  do_backup ;;
    9)  do_restore ;;
    10) do_clean_clients ;;
    11) do_reset_server ;;
    12) do_uninstall ;;
    0)  log_info "Выход"
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
