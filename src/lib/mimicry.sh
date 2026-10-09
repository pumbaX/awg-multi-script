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
