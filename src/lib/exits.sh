# AWG exit-ноды: клиенты выходят в интернет через другие AWG/WG-серверы.
# Каждая нода — клиентский конфиг awg-exit-<имя>.conf с «Table = off»
# (без него awg-quick увёл бы в ноду весь сервер вместе с SSH), поднимается
# своим awg-quick@awg-exit-<имя>.
#
# Маршруты: общая таблица 202 (одна нода или ECMP между всеми), плюс
# персональные таблицы 210-249 — клиенту можно назначить свою ноду.
# Номер персональной таблицы — порядок ноды в отсортированном списке: между
# остановкой и запуском правила пересоздаются целиком, поэтому сдвиг номера
# после добавления ноды ничего не ломает.
#
# exits_state: «active|inactive», mode=all|peers, balancer=single|ecmp, single_exit=
# exits_peers.list: «IP» — общий выход, «IP|нода» — персональная нода.

exits_nodes() {
  local f n
  for f in "$EXITS_DIR"/awg-exit-*.conf; do
    [[ -f "$f" ]] || continue
    n="${f##*/awg-exit-}"; echo "${n%.conf}"
  done | LC_ALL=C sort
}

exits_up_nodes() {
  local n
  while IFS= read -r n; do
    if ip link show "awg-exit-$n" &>/dev/null; then echo "$n"; fi
  done < <(exits_nodes)
}

exits_state_get() { sed -n "s/^$1=//p" "$EXITS_STATE" 2>/dev/null | head -1; }

# exits_state_set ключ значение ... — ключи: state mode balancer single_exit
exits_state_set() {
  local st mode bal single
  st=$(head -1 "$EXITS_STATE" 2>/dev/null || true)
  [[ "$st" == active ]] || st=inactive
  mode=$(exits_state_get mode); bal=$(exits_state_get balancer); single=$(exits_state_get single_exit)
  while (( $# >= 2 )); do
    case "$1" in
      state) st="$2" ;; mode) mode="$2" ;; balancer) bal="$2" ;; single_exit) single="$2" ;;
    esac
    shift 2
  done
  mkdir -p "$EXITS_DIR"
  printf '%s\nmode=%s\nbalancer=%s\nsingle_exit=%s\n' "$st" "${mode:-all}" "${bal:-single}" "$single" \
    | write_file "$EXITS_STATE" 600
}

exits_table_for() {  # нода → номер персональной таблицы
  local n i=0
  while IFS= read -r n; do
    if [[ "$n" == "$1" ]]; then
      (( EXITS_TABLE_BASE + i <= EXITS_TABLE_MAX )) || return 1
      echo $(( EXITS_TABLE_BASE + i )); return 0
    fi
    i=$((i + 1))
  done < <(exits_nodes)
  return 1
}

exits_rules_clear() {
  local t
  for t in "$EXITS_TABLE" $(seq "$EXITS_TABLE_BASE" "$EXITS_TABLE_MAX"); do
    rt_rules_clear "$t"
    ip route flush table "$t" 2>/dev/null || true
  done
}

# ── Маршрутизация (awg-exits-routing.service) ─────────────
exits_routing_start() {
  local mode balancer single up=() n i routed="" net line pip pnode table t args
  mode=$(exits_state_get mode); mode="${mode:-all}"
  balancer=$(exits_state_get balancer)
  single=$(exits_state_get single_exit)
  # При загрузке интерфейсы нод появляются не сразу
  for i in $(seq 1 20); do
    mapfile -t up < <(exits_up_nodes)
    (( ${#up[@]} == $(exits_nodes | grep -c .) )) && break
    sleep 0.5
  done
  (( ${#up[@]} )) || { echo "ни одна exit-нода не поднята" >&2; return 1; }
  net=$(server_net) || return 1
  exits_rules_clear
  [[ " ${up[*]} " == *" $single "* ]] || single="${up[0]}"
  if [[ "$balancer" == ecmp ]] && (( ${#up[@]} > 1 )); then
    args=()
    for n in "${up[@]}"; do args+=(nexthop dev "awg-exit-$n" weight 1); done
    if ip route replace default table "$EXITS_TABLE" "${args[@]}" 2>/dev/null; then
      # Хеш по L4: соединение держится одной ноды, а не разъезжается по всем
      sysctl -qw net.ipv4.fib_multipath_hash_policy=1 2>/dev/null || true
      routed=1
    else
      echo "ядро не приняло ECMP — одна нода: $single" >&2
    fi
  fi
  [[ -n "$routed" ]] || ip route replace default dev "awg-exit-$single" table "$EXITS_TABLE" \
    || { echo "не удалось поставить маршрут в таблицу $EXITS_TABLE" >&2; return 1; }
  for n in "${up[@]}"; do rt_fw_up "awg-exit-$n"; done
  if [[ "$mode" == all ]]; then
    ip rule add from "$net" lookup "$EXITS_TABLE" priority "$EXITS_TABLE"
    return 0
  fi
  [[ -f "$EXITS_PEERS" ]] || return 0
  while IFS= read -r line; do
    line="${line//[[:space:]]/}"
    pip="${line%%|*}"; pnode=""
    [[ "$line" == *"|"* ]] && pnode="${line#*|}"
    valid_ip "$pip" || continue
    table="$EXITS_TABLE"
    # Лежащая или удалённая нода — клиент идёт общим выходом, а не в пустоту
    if [[ -n "$pnode" && " ${up[*]} " == *" $pnode "* ]] && t=$(exits_table_for "$pnode") \
       && ip route replace default dev "awg-exit-$pnode" table "$t" 2>/dev/null; then
      table="$t"
    fi
    ip rule add from "$pip" lookup "$table" priority "$EXITS_TABLE" || true
  done < "$EXITS_PEERS"
}

exits_routing_stop() {
  local n
  exits_rules_clear
  while IFS= read -r n; do rt_fw_down "awg-exit-$n"; done < <(exits_nodes)
  return 0
}

exits_routing_run() {
  if [[ "${1:-}" == stop ]]; then exits_routing_stop; else exits_routing_start; fi
}

_exits_write_unit() {
  emit_script "$EXITS_SCRIPT" 'exits_routing_run "$@"' EXITS_DIR EXITS_STATE EXITS_PEERS EXITS_TABLE \
    EXITS_TABLE_BASE EXITS_TABLE_MAX exits_nodes exits_up_nodes exits_state_get exits_table_for \
    exits_rules_clear exits_routing_start exits_routing_stop exits_routing_run "${RT_FUNCS[@]}" || return 1
  write_unit "$EXITS_UNIT" <<EOF
[Unit]
Description=AWG Toolza — маршруты клиентов через exit-ноды
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$EXITS_SCRIPT start
ExecStop=$EXITS_SCRIPT stop

[Install]
WantedBy=multi-user.target
EOF
}

# Список «выбранных» при переходе в них из режима «все клиенты». all —
# действие над одним клиентом относительно «все» (exits_client, меню): в
# списке все клиенты. Иначе («выбранные» кнопкой, exits up peers) — прежний
# выбор, а если его нет или он пуст (после «никто», сброса сервера) — тоже
# все: пустой список увёл бы мимо нод вообще всех. В режиме «выбранные»
# пустой список — сознательное «никто», его не трогаем.
_exits_seed_peers() {  # [all]
  mkdir -p "$(dirname "$EXITS_PEERS")"
  peers_sync "$EXITS_PEERS"
  if [[ "$(exits_state_get mode)" == peers ]]; then peers_seed "$EXITS_PEERS"; return 0; fi
  if [[ "${1:-}" == all ]] || ! grep -q . "$EXITS_PEERS" 2>/dev/null; then peers_all "$EXITS_PEERS"; fi
  return 0
}

exits_reapply() { exits_is_up && systemctl restart "$EXITS_UNIT" &>/dev/null; return 0; }

# ── Включение / выключение ────────────────────────────────
exits_up() {  # all|peers
  local mode="${1:-$(exits_state_get mode)}"
  mode="${mode:-all}"
  server_exists || { err "Сначала создай сервер"; return 1; }
  [[ -n "$(exits_up_nodes)" ]] || { err "Ни одна exit-нода не поднята — добавь или перезапусти ноду"; return 1; }
  # Список клиентов режима peers — до проверки «уже включено»: иначе при
  # переключении all → peers на ходу файла нет, и маршруты не получает никто.
  if [[ "$mode" == peers ]]; then _exits_seed_peers; fi
  if exits_is_up; then exits_state_set mode "$mode"; exits_reapply; ok "Режим: $mode"; return 0; fi
  tunnel_guard exits || return 1
  exits_state_set state active mode "$mode"
  _exits_write_unit || return 1
  if ! systemctl enable --now "$EXITS_UNIT" &>/dev/null; then
    err "Маршрутизация не запустилась:"
    journalctl -u "$EXITS_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    exits_down quiet
    return 1
  fi
  if [[ "$mode" == all ]]; then ok "Exit-ноды включены: все клиенты идут через них"
  else ok "Exit-ноды включены: клиентов в списке — $(grep -c . "$EXITS_PEERS" || true)"; fi
}

exits_down() {
  systemctl disable --now "$EXITS_UNIT" &>/dev/null || true
  systemctl reset-failed "$EXITS_UNIT" &>/dev/null || true
  exits_routing_stop
  [[ -f "$EXITS_STATE" ]] && exits_state_set state inactive
  [[ "${1:-}" == quiet ]] || ok "Exit-ноды выключены — клиенты идут напрямую"
}

# ── Ноды ──────────────────────────────────────────────────
exits_add() {
  local name c tmp path
  read_line name "${C}  Имя ноды (латиница/цифры/_, до 6 символов): ${N}"
  [[ -n "$name" ]] || return 0
  mktmp tmp || return 1
  echo -e "  ${C}1)${N} Вставить текст конфига"
  echo -e "  ${C}2)${N} Путь к файлу .conf"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    echo -e "  Вставь клиентский конфиг AWG/WG целиком, затем Enter и Ctrl+D:"
    cat > "$tmp"
  else
    read_line path "${C}  Путь: ${N}"
    [[ -f "$path" ]] || { err "Файла нет: $path"; return 1; }
    cat "$path" > "$tmp"
  fi
  exits_node_add "$name" "$tmp" || return 1
  if ask_yes "  Сделать её основным выходом? [Y/n]: " y; then exits_balance single "$name"; else exits_reapply; fi
}

# exits_node_add ИМЯ ФАЙЛ — поставить ноду из клиентского конфига AWG/WG.
exits_node_add() {
  local name="$1" tmp f i
  [[ "$name" =~ ^[A-Za-z0-9_]{1,6}$ ]] || { err "Имя ноды: латиница, цифры, _, до 6 символов"; return 1; }
  f="$EXITS_DIR/awg-exit-$name.conf"
  [[ -f "$f" ]] && { err "Нода $name уже есть"; return 1; }
  [[ -s "$2" ]] || { err "Пустой конфиг"; return 1; }
  mktmp tmp || return 1
  cat "$2" > "$tmp"
  grep -qiE '^\s*\[Interface\]' "$tmp" || { err "Нет секции [Interface]"; return 1; }
  grep -qiE '^\s*Endpoint\s*=' "$tmp" || { err "Нет Endpoint — это не клиентский конфиг"; return 1; }
  # Table = off (иначе через ноду уйдёт весь сервер) и без DNS (awg-quick
  # переписал бы resolv.conf сервера или упал без resolvconf)
  py exit-conf-fix "$tmp" && grep -qiE '^\s*Table\s*=\s*off' "$tmp" \
    || { err "Не удалось подготовить конфиг — ноду не ставлю"; return 1; }
  install -m 600 "$tmp" "$f"
  systemctl enable --now "awg-quick@awg-exit-$name" &>/dev/null || true
  for i in $(seq 1 10); do ip link show "awg-exit-$name" &>/dev/null && break; sleep 0.5; done
  if ! ip link show "awg-exit-$name" &>/dev/null; then
    err "Нода не поднялась:"
    journalctl -u "awg-quick@awg-exit-$name" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    systemctl disable --now "awg-quick@awg-exit-$name" &>/dev/null || true
    rm -f "$f"
    return 1
  fi
  ok "Нода $name поднята"
}

_exits_node_line() {  # нода → строка статуса
  local n="$1" dev="awg-exit-$1" hs now ago rx tx
  if ! ip link show "$dev" &>/dev/null; then echo -e "${R}○ лежит${N}"; return; fi
  hs=$(awg show "$dev" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  now=$(date +%s)
  read -r rx tx < <(awg show "$dev" transfer 2>/dev/null | awk '{print $2, $3; exit}')
  if [[ -z "$hs" || "$hs" == 0 ]]; then echo -e "${Y}● поднята, рукопожатия нет${N}"
  else
    ago=$(( now - hs ))
    if (( ago < 180 )); then echo -e "${G}● связь $(fmt_duration "$ago") назад${N} ${D}↓$(fmt_bytes "${rx:-0}") ↑$(fmt_bytes "${tx:-0}")${N}"
    else echo -e "${Y}● последнее рукопожатие $(fmt_duration "$ago") назад${N}"; fi
  fi
}

exits_list() {
  local nodes=() n ip sample
  mapfile -t nodes < <(exits_nodes)
  (( ${#nodes[@]} )) || { info "Нод нет"; return 0; }
  for n in "${nodes[@]}"; do
    echo -e "  ${W}$n${N}  $(_exits_node_line "$n")"
    if ip link show "awg-exit-$n" &>/dev/null; then
      ip=$(iface_egress_ip "awg-exit-$n" 5)
      if [[ -n "$ip" ]]; then echo -e "      выход в интернет: ${G}$ip${N}"; else echo -e "      ${R}выхода в интернет нет${N}"; fi
    fi
  done
  if exits_is_up; then
    sample=$(clients_name_ip | head -1 | cut -d'|' -f2)
    [[ -n "$sample" ]] && echo -e "  ${D}Маршрут клиента $sample: $(ip route get 1.1.1.1 from "$sample" iif "$AWG_IF" 2>/dev/null | head -1)${N}"
  fi
}

exits_delete() {
  local nodes=() c n
  mapfile -t nodes < <(exits_nodes)
  (( ${#nodes[@]} )) || { info "Нод нет"; return 0; }
  for c in "${!nodes[@]}"; do echo -e "  ${C}$((c + 1)))${N} ${nodes[$c]}"; done
  read_choice c "${C}  Удалить ноду (0 — отмена): ${N}" 0 "${#nodes[@]}" 0
  (( c )) || return 0
  n="${nodes[$((c - 1))]}"
  ask_yes "  Удалить ноду $n? [y/N]: " n || return 0
  exits_node_del "$n"
}

exits_node_del() {  # имя
  local n="$1"
  [[ -f "$EXITS_DIR/awg-exit-$n.conf" ]] || { err "Ноды $n нет"; return 1; }
  exits_is_up && exits_routing_stop
  systemctl disable --now "awg-quick@awg-exit-$n" &>/dev/null || true
  rm -f "$EXITS_DIR/awg-exit-$n.conf"
  # Клиенты этой ноды переходят на общий выход
  [[ -f "$EXITS_PEERS" ]] && sed -i "s/|$n\$//" "$EXITS_PEERS"
  [[ "$(exits_state_get single_exit)" == "$n" ]] && exits_state_set single_exit ""
  ok "Нода $n удалена"
  if exits_is_up; then
    if [[ -n "$(exits_up_nodes)" ]]; then exits_reapply; else warn "Нод не осталось"; exits_down; fi
  fi
}

exits_balancer_menu() {
  local up=() c i
  mapfile -t up < <(exits_up_nodes)
  (( ${#up[@]} )) || { warn "Ни одна нода не поднята"; return 0; }
  echo -e "  Сейчас: ${W}$(exits_state_get balancer)${N} $(exits_state_get single_exit)"
  echo -e "  ${C}1)${N} Одна нода"
  if (( ${#up[@]} > 1 )); then echo -e "  ${C}2)${N} ECMP ${D}— все поднятые ноды${N}"
  else echo -e "  ${D}2) ECMP — нужны две поднятые ноды${N}"; fi
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 2 0
  case "$c" in
    1) for i in "${!up[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${up[$i]}"; done
       read_choice i "${C}  Нода: ${N}" 1 "${#up[@]}"
       exits_balance single "${up[$((i - 1))]}" ;;
    2) (( ${#up[@]} > 1 )) && exits_balance ecmp ;;
  esac
  return 0
}

# exits_balance single НОДА | ecmp
exits_balance() {
  case "$1" in
    single) [[ -f "$EXITS_DIR/awg-exit-${2:-}.conf" ]] || { err "Ноды ${2:-?} нет"; return 1; }
            exits_state_set balancer single single_exit "$2" ;;
    ecmp) (( $(exits_up_nodes | grep -c . || true) > 1 )) || { err "Для ECMP нужны две поднятые ноды"; return 1; }
          exits_state_set balancer ecmp ;;
    *) err "Балансировка: single НОДА | ecmp"; return 1 ;;
  esac
  ok "Балансировка: $1${2:+ $2}"
  exits_reapply
}

# Клиент и exit-ноды: exits_client ИМЯ off|shared|НОДА. Переводит в выборочный режим.
# exits_client ИМЯ|all|none off|shared|НОДА — выход клиента; all — все клиенты
# через ноды (у кого своя нода, она остаётся), none — никто: все напрямую.
# Режим при этом — «выбранные клиенты»; маршруты перезапускаются один раз.
# Массовая форма — только без второго аргумента: клиент может называться
# «all» или «none», и «exits client all off» — про него, а не про всех.
exits_client() {
  local ip
  if [[ ( "$1" == all || "$1" == none ) && -z "${2:-}" ]]; then
    mkdir -p "$(dirname "$EXITS_PEERS")"
    peers_sync "$EXITS_PEERS"
    if [[ "$1" == all ]]; then
      peers_all "$EXITS_PEERS"
    else
      : > "$EXITS_PEERS"
    fi
    exits_state_set mode peers
    exits_reapply
    ok "Через exit-ноды: $(grep -c . "$EXITS_PEERS" || true) из $(clients_name_ip | grep -c . || true)"
    return 0
  fi
  ip=$(clients_name_ip | awk -F'|' -v n="$1" '$1 == n {print $2; exit}')
  [[ -n "$ip" ]] || { err "Клиента $1 нет"; return 1; }
  # Из «все клиенты» в «выбранные»: список — все клиенты (свои ноды остаются),
  # а не то, что лежало в файле. После «никто» или сброса сервера он пуст, и
  # «alice — напрямую» уводило мимо нод вообще всех.
  if [[ "$(exits_state_get mode)" != peers ]]; then
    _exits_seed_peers all
    exits_state_set mode peers
  fi
  case "$2" in
    off) peers_del "$EXITS_PEERS" "$ip" ;;
    shared) peers_add "$EXITS_PEERS" "$ip" ;;
    *) [[ -f "$EXITS_DIR/awg-exit-$2.conf" ]] || { err "Ноды $2 нет"; return 1; }
       peers_add "$EXITS_PEERS" "$ip" "$ip|$2" ;;
  esac
  exits_reapply
  ok "$1: ${2/shared/общий выход}"
}

# exits_mode all|peers — кого вести через ноды, не включая и не выключая их
exits_mode() {
  [[ "${1:-}" == all || "${1:-}" == peers ]] || { err "Режим: all | peers"; return 1; }
  if [[ "$1" == peers ]]; then _exits_seed_peers; fi
  exits_state_set mode "$1"
  exits_reapply
  if [[ "$1" == all ]]; then ok "Через exit-ноды — все клиенты"
  else ok "Через exit-ноды — выбранные: $(grep -c . "$EXITS_PEERS" || true)"; fi
}

exits_toggle() {
  local c
  if exits_is_up; then exits_down; return; fi
  echo -e "  ${C}1)${N} Все клиенты"
  echo -e "  ${C}2)${N} Выборочно"
  read_choice c "${C}  Кого вести через exit-ноды [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then exits_up all; else exits_up peers; fi
}

# ── Клиенты ───────────────────────────────────────────────
_exits_peer_node() { grep -E "^${1//./\\.}\|" "$EXITS_PEERS" 2>/dev/null | head -1 | cut -d'|' -f2; }

_exits_assign() {  # ip имя
  local nodes=() i c cur
  mapfile -t nodes < <(exits_nodes)
  (( ${#nodes[@]} > 1 )) || { info "Нода одна — назначать нечего"; return 0; }
  cur=$(_exits_peer_node "$1")
  echo -e "  Клиент ${W}$2${N}: ${cur:+нода $cur}${cur:-общий выход}"
  for i in "${!nodes[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${nodes[$i]}"; done
  echo -e "  ${C}$(( ${#nodes[@]} + 1 )))${N} общий выход"
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 $(( ${#nodes[@]} + 1 )) 0
  (( c )) || return 0
  if (( c > ${#nodes[@]} )); then peers_add "$EXITS_PEERS" "$1"
  else peers_add "$EXITS_PEERS" "$1" "$1|${nodes[$((c - 1))]}"; fi
}

exits_peers_menu() {
  local rows=() i c name ip node sel
  # Выбор клиентов имеет смысл только в режиме «выборочно»
  if [[ "$(exits_state_get mode)" != peers ]]; then
    info "Сейчас через exit-ноды идут все клиенты — переключаю на выборочный режим"
    _exits_seed_peers all
    exits_state_set mode peers
    exits_reapply
  fi
  while true; do
    peers_sync "$EXITS_PEERS"
    mapfile -t rows < <(clients_name_ip)
    (( ${#rows[@]} )) || { warn "Клиентов нет"; return 0; }
    echo ""
    hdr "Клиенты через exit-ноды"
    for i in "${!rows[@]}"; do
      name="${rows[$i]%%|*}"; ip="${rows[$i]#*|}"
      if peers_has "$EXITS_PEERS" "$ip"; then
        node=$(_exits_peer_node "$ip")
        echo -e "  ${G}$((i + 1)))${N} $name ${D}$ip${N}  ${C}${node:+нода $node}${node:-общий выход}${N}"
      else
        echo -e "  ${D}$((i + 1))) $name $ip  напрямую${N}"
      fi
    done
    echo -e "  ${C}e)${N} Назначить ноду"
    echo -e "  ${C}a)${N} Все через exit-ноды"
    echo -e "  ${C}n)${N} Все напрямую"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер — вкл/выкл: ${N}" 0 "${#rows[@]}" 0 "e|a|n"
    case "$c" in
      0) return 0 ;;
      a) peers_all "$EXITS_PEERS" ;;          # свои ноды клиентов остаются
      n) : > "$EXITS_PEERS" ;;
      e) read_choice sel "${C}  Номер клиента: ${N}" 1 "${#rows[@]}"
         _exits_assign "${rows[$((sel - 1))]#*|}" "${rows[$((sel - 1))]%%|*}" ;;
      *) ip="${rows[$((c - 1))]#*|}"
         if peers_has "$EXITS_PEERS" "$ip"; then peers_del "$EXITS_PEERS" "$ip"; else peers_add "$EXITS_PEERS" "$ip"; fi ;;
    esac
    exits_reapply
  done
}

exits_status() {
  local mode bal n
  n=$(exits_nodes | grep -c . || true)
  echo -e "  Ноды      : ${W}$n${N} (поднято $(exits_up_nodes | grep -c . || true))"
  if exits_is_up; then
    mode=$(exits_state_get mode); bal=$(exits_state_get balancer)
    echo -e "  Маршруты  : ${G}● включены${N} — $([[ "$mode" == peers ]] && echo "выборочно, $(n=$(grep -c . "$EXITS_PEERS" 2>/dev/null); echo "${n:-0}") кл." || echo "все клиенты")"
    if [[ "$bal" == ecmp ]]; then echo -e "  Балансир  : ECMP"
    else echo -e "  Балансир  : одна нода ($(exits_state_get single_exit))"; fi
  elif unit_enabled "$EXITS_UNIT"; then
    echo -e "  Маршруты  : ${R}▲ служба не запущена${N} — journalctl -u $EXITS_UNIT"
  else
    echo -e "  Маршруты  : ${D}○ выключены${N}"
  fi
}

do_exits_menu() {
  local c
  while true; do
    echo ""
    hdr "AWG exit-ноды"
    exits_status
    echo ""
    echo -e "  ${C}1)${N} Добавить ноду"
    echo -e "  ${C}2)${N} Список и проверка"
    echo -e "  ${C}3)${N} Удалить ноду"
    echo -e "  ${C}4)${N} Вкл/выкл маршруты"
    echo -e "  ${C}5)${N} Балансировка"
    echo -e "  ${C}6)${N} Клиенты"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-6]: ${N}" 0 6 0
    case "$c" in
      1) exits_add || true ;;
      2) exits_list ;;
      3) exits_delete || true ;;
      4) exits_toggle || true ;;
      5) exits_balancer_menu || true ;;
      6) exits_peers_menu; continue ;;
      0) return 0 ;;
    esac
    pause
  done
}
