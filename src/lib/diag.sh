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
    echo -e "  ${C}6)${N} Куда идёт адрес ${D}— туннель, нода или напрямую для клиента${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-6]: ${N}" 0 6 0
    case "$c" in
      1) do_status ;;
      2) do_check_domains || true ;;
      3) do_sniff_test || true ;;
      4) do_client_dpi_hint ;;
      5) components_report || true ;;
      6) do_diag_route || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# ── Куда идёт адрес ───────────────────────────────────────
# Для клиента и адреса (IP, домен или ссылка): каждый IPv4 адреса — решение
# самого ядра (ip route get от имени клиента, с меткой «РФ напрямую», если
# адрес в её наборе) и что раньше маршрута: «VK и Max» отбрасывает, клиент
# заблокирован. Строки «ip<TAB>вид<TAB>устройство<TAB>пояснение»; вид:
# warp | xray | t2s | exit | direct | rudirect | held | drop | blocked | none.
# Ничего не меняет — только читает.
DIAG_FWD="/proc/sys/net/ipv4/ip_forward"
diag_route() {  # клиент адрес
  local name="${1:-}" addr="${2:-}" row cip orig host ips=() ip kind dev note out mark tun xo
  server_exists || { err "Сервер не создан"; return 1; }
  row=$(clients_tsv | awk -F'\t' -v n="$name" '$1 == n {print; exit}')
  [[ -n "$row" ]] || { err "Клиента $name нет"; return 1; }
  # Через «|»: подряд идущие табы read схлопнул бы, и пустой срок сдвинул бы колонки
  IFS='|' read -r _ _ cip _ orig _ <<< "${row//$'\t'/|}"
  cip="${orig:-$cip}"; cip="${cip%%,*}"; cip="${cip%%/*}"; cip="${cip//[[:space:]]/}"
  host="${addr//[[:space:]]/}"; host="${host,,}"
  host="${host#*://}"; host="${host%%/*}"; host="${host%%\?*}"
  [[ "$host" == *:* && "$host" != *:*:* ]] && host="${host%%:*}"
  if valid_ip "$host"; then ips=("$host")
  elif valid_domain "$host"; then
    mapfile -t ips < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | head -8)
    (( ${#ips[@]} )) || { err "Домен $host не разрешается в IPv4 с этого сервера"; return 1; }
  else
    err "Нужен IPv4, домен или ссылка: $addr"; return 1
  fi
  tun=$(tunnel_conflict none)
  for ip in "${ips[@]}"; do
    kind="" dev="" note="" mark=""
    if [[ -n "$orig" ]]; then
      kind=blocked note="клиент заблокирован (срок или лимит трафика) — его трафик не идёт никуда"
    elif vkblock_on && ipset test "$VKBLOCK_SET" "$ip" &>/dev/null; then
      kind=drop note="сеть VK — отбрасывается («VK и Max мимо VPN»)"
    else
      rudirect_on && ipset test "$RUDIRECT_SET" "$ip" &>/dev/null && mark="${RUDIRECT_MARK%%/*}"
      if ! ip link show "$AWG_IF" &>/dev/null; then
        kind=none note="awg0 не поднят — проверить маршрут нельзя"
      elif ! out=$(ip -4 route get "$ip" from "$cip" iif "$AWG_IF" ${mark:+mark "$mark"} 2>&1); then
        if [[ "$(cat "$DIAG_FWD" 2>/dev/null)" == 0 ]]; then
          kind=none note="пересылка пакетов на сервере выключена (ip_forward) — «Сервер → Починить»"
        elif [[ "$out" == *nreachable* || "$out" == *"No route"* ]] && tunfail_any_block; then
          kind=held note="туннель лежит, режим «блокировать» — клиент ждёт его без интернета"
        elif [[ "$out" == *nreachable* || "$out" == *"No route"* ]]; then
          kind=none note="у ядра нет маршрута для клиента — «Туннели → Аварийный сброс» вернёт прямой"
        else
          kind=none note="ядро не ответило: ${out##*: }"
        fi
      else
        dev=$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<< "$out")
        case "$dev" in
          "$WARP_IF") kind=warp note="через WARP" ;;
          "$T2S_IF") kind=t2s note="через tun2socks ($(t2s_proxy))" ;;
          "$XRAY_IF")
            kind=xray
            xo=$(grep -E "^${cip//./\\.}\|" "$XRAY_PEERS" 2>/dev/null | head -1 | cut -d'|' -f2)
            note="через Xray$([[ -n "$xo" ]] && echo ", свой выход $xo" || echo ", выход по умолчанию")"
            xray_ru_on && note+="; внутри Xray РФ-сайты — напрямую по его правилам" ;;
          awg-exit-*) kind=exit note="через exit-ноду ${dev#awg-exit-}"
            [[ "$(exits_state_get balancer)" == ecmp ]] && ip route show table "$EXITS_TABLE" 2>/dev/null | grep -q nexthop \
              && note+=" (балансировка: соединения делятся между нодами)" ;;
          *)
            if [[ -n "$mark" ]] && _rud_rpf_strict "$dev" \
                 && [[ "$(ip -4 route get "$ip" from "$cip" iif "$AWG_IF" 2>/dev/null)" != *" dev $dev "* ]]; then
              # Без метки клиент идёт в туннель: обратный путь — туда же, ответ на $dev отбросят
              kind=none note="сеть России, но ответы отбросит строгий rp_filter на $dev — «РФ напрямую → Починить»"
            elif [[ -n "$mark" ]] && rudirect_tg_on && _antiscan_covers <(_rud_tg_nets) "$ip"; then
              kind=rudirect note="напрямую с сервера — Telegram («Telegram напрямую»)"
            elif [[ -n "$mark" ]]; then kind=rudirect note="напрямую с сервера — сеть России («РФ напрямую»)"
            elif [[ -n "$tun" ]]; then kind=direct note="напрямую с сервера — клиент не в туннеле ($tun)"
            else kind=direct note="напрямую с сервера — туннели выключены"; fi ;;
        esac
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$ip" "$kind" "$dev" "$note"
  done
}

do_diag_route() {
  local name addr ip kind dev note
  _pick_client || return 0
  name="${CHOSEN%%$'\t'*}"
  read_line addr "${C}  Адрес, домен или ссылка: ${N}"
  [[ -n "$addr" ]] || return 0
  echo ""
  hdr "Куда идёт $addr у $name"
  while IFS=$'\t' read -r ip kind dev note; do
    case "$kind" in
      warp|xray|t2s|exit) echo -e "  ${G}●${N} $ip — $note" ;;
      direct|rudirect) echo -e "  ${C}●${N} $ip — $note" ;;
      *) echo -e "  ${Y}▲${N} $ip — $note" ;;
    esac
  done < <(diag_route "$name" "$addr")
}
