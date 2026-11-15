# Точки входа (каскад): клиент подключается не к этому серверу напрямую, а
# через сервер-вход — любой сервер, где UDP-порт проброшен сюда (каскад Тулзы,
# свой iptables, nginx stream). В конфиге такого клиента Endpoint — адрес
# входа; ключи, лимиты, скорость, сроки и выходы — как у всех, сервер разницы
# не видит. Хранение — py entry: список в шапке awg0.conf, вход клиента —
# метка его пира, поэтому всё попадает в любой бэкап вместе с клиентами.

entry_direct() { echo "$(endpoint_host):$(server_port)"; }

# Endpoint для конфига клиента: адрес его входа, без входа — сервер напрямую.
client_endpoint() {  # имя
  local a
  a=$(py entry "$SERVER_CONF" of "$1" 2>/dev/null)
  echo "${a:-$(entry_direct)}"
}

# Вход нового клиента: _O_ENTRY пусто — вход по умолчанию, direct — напрямую,
# иначе имя входа. Итог — в _ENTRY_NEW (имя, пусто — напрямую) и
# _ENTRY_NEW_ADDR (его адрес); помнится до смены списка или _O_ENTRY: пакет
# из 200 клиентов не спрашивает Python 400 раз.
_O_ENTRY="" _ENTRY_NEW="" _ENTRY_NEW_ADDR="" _ENTRY_NEW_KEY="-"
client_new_entry() {
  [[ "$_ENTRY_NEW_KEY" == "$_O_ENTRY" ]] && return 0
  _ENTRY_NEW="" _ENTRY_NEW_ADDR=""
  case "$_O_ENTRY" in
    "") _ENTRY_NEW=$(entry_default_get) ;;
    direct) ;;
    *) _ENTRY_NEW="$_O_ENTRY" ;;
  esac
  [[ -n "$_ENTRY_NEW" ]] && _ENTRY_NEW_ADDR=$(py entry "$SERVER_CONF" get "$_ENTRY_NEW" 2>/dev/null)
  [[ -n "$_ENTRY_NEW_ADDR" ]] || _ENTRY_NEW=""
  _ENTRY_NEW_KEY="$_O_ENTRY"
}
_entry_new_reset() { _ENTRY_NEW_KEY="-"; }

# py entry: вывод — в ENTRY_OUT, отказ — в err.
ENTRY_OUT=""
_entry_py() {
  _entry_new_reset
  ENTRY_OUT=$(py entry "$SERVER_CONF" "$@" 2>&1) && return 0
  err "${ENTRY_OUT##*$'\n'}"
  ENTRY_OUT=""
  return 1
}

# Строки «клиент<TAB>адрес» (пусто — напрямую) → Endpoint в их конфигах.
# У перенесённых из Amnezia файла нет — им адрес достанется при перевыпуске.
ENTRY_REWRITTEN=0
_entry_apply() {
  local n a f direct
  direct=$(entry_direct)
  ENTRY_REWRITTEN=0
  while IFS=$'\t' read -r n a; do
    [[ -n "$n" ]] || continue
    f=$(client_file "$n")
    [[ -f "$f" ]] && grep -q '^Endpoint = ' "$f" || continue
    sed -i "s|^Endpoint = .*|Endpoint = ${a:-$direct}|" "$f" && ENTRY_REWRITTEN=$((ENTRY_REWRITTEN + 1))
  done <<< "$1"
}

# ── Итоги проверок ────────────────────────────────────────
# «имя<TAB>адрес<TAB>ok|fail|unknown<TAB>время» в $STATE_DIR/entry-check:
# итог относится к адресу — новый адрес входа проверяется заново. Не в
# awg0.conf: после переезда на другой сервер вход проверяется там.
_entry_check_file() { echo "$STATE_DIR/entry-check"; }

_entry_check_save() {  # имя адрес статус
  local f
  f=$(_entry_check_file)
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  { awk -F'\t' -v n="$1" '$1 != n' "$f" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date +%s)"; } > "$f.tmp" && mv -f "$f.tmp" "$f"
}

_entry_check_get() {  # имя адрес → «статус<TAB>время» последней проверки этого адреса
  awk -F'\t' -v n="$1" -v a="$2" '$1 == n && $2 == a {print $3 "\t" $4; exit}' "$(_entry_check_file)" 2>/dev/null || true
}

# Строки py entry list + итог проверки и её время
_entry_rows_checked() {
  py entry "$SERVER_CONF" list 2>/dev/null | awk -F'\t' -v OFS='\t' -v f="$(_entry_check_file)" '
    BEGIN { while ((getline l < f) > 0) { split(l, a, "\t"); st[a[1] "\t" a[2]] = a[3]; ts[a[1] "\t" a[2]] = a[4] } }
    { k = $1 "\t" $2; print $0, st[k], ts[k] + 0 }'
}

# Можно ли выдавать вход клиентам: каскад должен доводить пакеты до сервера.
# Свежая удачная проверка (10 минут) — без новой; иначе проверка сейчас.
# Проверить нельзя (нет модуля string, адрес не найден) — выдаём с предупреждением.
ENTRY_FRESH=600
_entry_ready() {  # имя (пусто — напрямую, всегда можно)
  local a st ts
  [[ -n "${1:-}" ]] || return 0
  a=$(py entry "$SERVER_CONF" get "$1" 2>/dev/null)
  [[ -n "$a" ]] || { err "Точки входа «$1» нет"; return 1; }
  IFS=$'\t' read -r st ts <<< "$(_entry_check_get "$1" "$a")"
  [[ "$st" == ok && "${ts:-0}" =~ ^[0-9]+$ ]] && (( $(date +%s) - ts < ENTRY_FRESH )) && return 0
  entry_check "$1" quiet && return 0
  if [[ -n "$ENTRY_PROBE_WHY" ]]; then
    err "Вход «$1» не готов: $ENTRY_PROBE_WHY — клиентам его не выдаю"
    info "Исправь и нажми «Проверить»"
  else
    err "Вход «$1» не работает: через $a пакеты до сервера не доходят — клиентам его не выдаю"
    info "Проверь проброс на сервере-входе: UDP ${a##*:} → $(public_ip_cached):$(server_port), затем «Проверить»"
  fi
  return 1
}

_entry_rewritten_note() {
  (( ENTRY_REWRITTEN )) || return 0
  info "Конфигов переписано: $ENTRY_REWRITTEN — этим клиентам нужен новый конфиг или QR"
}

# «имя» или пусто/direct — напрямую
_entry_arg() { [[ "${1:-}" == direct ]] && echo "" || echo "${1:-}"; }

entry_add() {  # имя хост:порт
  server_exists || { err "Сервер не создан"; return 1; }
  _entry_py add "${1:-}" "${2:-}" || return 1
  ok "Точка входа «$1»: $(py entry "$SERVER_CONF" get "$1")"
  log_info "точка входа добавлена: $1"
  entry_check "$1" soft || true
  info "Вход клиенту — в его карточке («Вход»); всем новым — «По умолчанию»"
}

entry_set() {  # имя хост:порт — новый адрес входа; конфиги его клиентов переписываются
  server_exists || { err "Сервер не создан"; return 1; }
  _entry_py set "${1:-}" "${2:-}" || return 1
  _entry_apply "$ENTRY_OUT"
  ok "Точка входа «$1»: $(py entry "$SERVER_CONF" get "$1")"
  log_info "точка входа изменена: $1"
  _entry_rewritten_note
  entry_check "$1" soft || true
}

entry_del() {  # имя — его клиенты переходят на «напрямую»
  server_exists || { err "Сервер не создан"; return 1; }
  _entry_py del "${1:-}" || return 1
  _entry_apply "$ENTRY_OUT"
  _entry_check_save "$1" "" gone
  ok "Точка входа «$1» удалена"
  log_info "точка входа удалена: $1"
  [[ -n "$ENTRY_OUT" ]] && info "Её клиенты теперь подключаются напрямую: $(entry_direct)"
  _entry_rewritten_note
}

entry_default() {  # имя|direct — вход для новых клиентов
  local e
  server_exists || { err "Сервер не создан"; return 1; }
  e=$(_entry_arg "${1:-}")
  _entry_ready "$e" || return 1
  _entry_py default "$e" || return 1
  if [[ -n "$e" ]]; then ok "Новые клиенты — через вход «$e»"; else ok "Новые клиенты — напрямую"; fi
}

entry_default_get() { py entry "$SERVER_CONF" list 2>/dev/null | awk -F'\t' '$4 == 1 {print $1; exit}'; }

client_entry_set() {  # клиент имя|direct
  local e a
  server_exists || { err "Сервер не создан"; return 1; }
  e=$(_entry_arg "${2:-}")
  _entry_ready "$e" || return 1
  _entry_py assign "${1:-}" "$e" || return 1
  _entry_apply "$ENTRY_OUT"
  a=$(client_endpoint "$1")
  if [[ -n "$e" ]]; then ok "$1 → вход «$e» ($a)"; else ok "$1 → напрямую ($a)"; fi
  log_info "вход клиента: $1 → ${e:-напрямую}"
  (( ENTRY_REWRITTEN )) && info "Клиенту нужен новый конфиг или QR — в старом прежний Endpoint"
  return 0
}

# Выбранные клиенты (через запятую) — на вход; их имена с новым адресом — в ENTRY_OUT
entry_assign_clients() {  # имя|direct клиент,клиент...
  local e n
  server_exists || { err "Сервер не создан"; return 1; }
  e=$(_entry_arg "${1:-}")
  [[ -n "${2:-}" ]] || { err "Не выбраны клиенты"; return 1; }
  _entry_ready "$e" || return 1
  _entry_py assign-many "$e" "$2" || return 1
  while IFS= read -r n; do [[ "$n" == *$'\t'* ]] || { [[ -n "$n" ]] && warn "$n"; }; done <<< "$ENTRY_OUT"
  ENTRY_OUT=$(grep $'\t' <<< "$ENTRY_OUT" || true)
  _entry_apply "$ENTRY_OUT"
  n=$(grep -c . <<< "$ENTRY_OUT" || true)
  if [[ -n "$e" ]]; then ok "Через вход «$e»: $n клиентов"; else ok "Напрямую: $n клиентов"; fi
  log_info "вход клиентов: ${e:-напрямую} ← $2"
  _entry_rewritten_note
}

entry_assign_all() {  # имя|direct — все клиенты
  local e
  server_exists || { err "Сервер не создан"; return 1; }
  e=$(_entry_arg "${1:-}")
  _entry_ready "$e" || return 1
  _entry_py assign-all "$e" || return 1
  _entry_apply "$ENTRY_OUT"
  if [[ -n "$e" ]]; then ok "Все клиенты — через вход «$e»"; else ok "Все клиенты — напрямую"; fi
  log_info "вход всех клиентов: ${e:-напрямую}"
  _entry_rewritten_note
}

# Доходит ли пакет через вход до этого сервера: шлём с сервера UDP с меткой
# на адрес входа и ловим его на своём порту AWG (правило raw со строкой
# метки). Простой проброс порта (DNAT) возвращает пакет сюда же.
# 0 — дошёл, 1 — нет, 2 — проверить нельзя (адрес не найден, нет модуля string).
# Почему проверка не прошла, если причина известна точнее «пакеты не дошли».
ENTRY_PROBE_TAG="awg2-entry-check" ENTRY_PROBE_WHY=""
entry_probe() {  # хост:порт ([IPv6]:порт)
  local host="${1%:*}" port="${1##*:}" ip mark i n ipt=iptables rc=1
  ENTRY_PROBE_WHY=""
  host="${host#[}"; host="${host%]}"
  if [[ "$host" == *:* ]]; then
    # Свой IPv6: клиенты придут на этот сервер напрямую, каскада нет
    _own_ip6 "$host" && { _entry_ipv6_self "$host" "$port"; return; }
    ip="$host"; ipt=ip6tables
  elif valid_ip "$host"; then ip="$host"
  else ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'); fi
  [[ -n "$ip" ]] || return 2
  mark="$ENTRY_PROBE_TAG-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  _entry_probe_clean "$ipt"
  "$ipt" -t raw -I PREROUTING 1 -p udp --dport "$(server_port)" -m string --algo bm --string "$mark" \
    -m comment --comment "$ENTRY_PROBE_TAG" -j ACCEPT 2>/dev/null || return 2
  for i in 1 2 3 4; do
    { printf '%s' "$mark" > "/dev/udp/$ip/$port"; } 2>/dev/null || true
    sleep 0.5
    n=$("$ipt" -t raw -L PREROUTING -v -x -n 2>/dev/null | awk -v t="$ENTRY_PROBE_TAG" 'index($0, t) {print $1; exit}')
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && { rc=0; break; }
  done
  _entry_probe_clean "$ipt"
  return "$rc"
}

_entry_probe_clean() {  # iptables|ip6tables
  local rule
  while IFS= read -r rule; do
    printf '%s\n' "${rule/#-A /-D }" | xargs "$1" -t raw 2>/dev/null || true
  done < <("$1-save" -t raw 2>/dev/null | grep -E -- "^-A .*--comment \"?${ENTRY_PROBE_TAG}\"?( |$)" || true)
}

_own_ip6() { ip -6 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print tolower(a[1])}' | grep -qxF "${1,,}"; }

# Свой IPv6 как вход: IPv6 включён, адрес на месте, порт — порт AWG, AWG
# его слушает, UFW пускает IPv6 и у сервера есть выход в интернет по IPv6.
IPV6_SYSCTL="/proc/sys/net/ipv6/conf/all/disable_ipv6"
_entry_ipv6_self() {  # адрес порт
  local a="$1" p="$2" ls out
  [[ "$(cat "$IPV6_SYSCTL" 2>/dev/null || echo 1)" == 0 ]] \
    || { ENTRY_PROBE_WHY="IPv6 на сервере выключен (net.ipv6.conf.all.disable_ipv6)"; return 1; }
  [[ "$p" == "$(server_port)" ]] || { ENTRY_PROBE_WHY="порт $p — не порт AWG ($(server_port))"; return 1; }
  # Сокеты AWG в ядре: есть строки, а IPv6 среди них нет — AWG IPv6 не слушает
  ls=$(ss -lunH "sport = :$p" 2>/dev/null || true)
  if [[ -n "$ls" ]] && ! grep -qE '\[::\]|\*:' <<< "$ls"; then
    ENTRY_PROBE_WHY="AWG не слушает порт $p по IPv6 — перезапусти awg0"; return 1
  fi
  if ufw_active; then
    grep -qiE '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*no' "$UFW_DEFAULTS" 2>/dev/null \
      && { ENTRY_PROBE_WHY="в UFW выключен IPv6 (IPV6=no в /etc/default/ufw) — порт AWG по IPv6 закрыт"; return 1; }
    out=$(LC_ALL=C ufw status 2>/dev/null || true)
    grep -qE "^$p/udp \(v6\)[[:space:]]+ALLOW" <<< "$out" \
      || { ENTRY_PROBE_WHY="в UFW порт $p/udp открыт только для IPv4"; return 1; }
  fi
  curl -6 -fsS --max-time 6 -o /dev/null https://api64.ipify.org 2>/dev/null \
    || curl -6 -fsS --max-time 6 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    || { ENTRY_PROBE_WHY="у сервера нет выхода в интернет по IPv6 — у хостера IPv6 не работает или не маршрутизируется"; return 1; }
  return 0
}

# IPv6 этого сервера — точкой входа (по умолчанию с именем «IPv6»).
entry_add_ipv6() {  # [имя]
  local a have
  server_exists || { err "Сервер не создан"; return 1; }
  a=$(public_ip6)
  [[ -n "$a" ]] || { err "У сервера нет глобального IPv6 — его включают у хостера"; return 1; }
  a="[$a]:$(server_port)"
  have=$(py entry "$SERVER_CONF" list 2>/dev/null | awk -F'\t' -v x="$a" '$2 == x {print $1; exit}')
  if [[ -n "$have" ]]; then
    ok "IPv6 сервера уже есть: вход «$have» ($a)"
    entry_check "$have" soft || true
    ENTRY_NAME="$have"
    return 0
  fi
  ENTRY_NAME="${1:-IPv6}"
  entry_add "$ENTRY_NAME" "$a"
}
ENTRY_NAME=""

# soft — провал проверки только предупреждением; quiet — без вывода, только
# итог (его пишет _entry_ready). Итог запоминается — по нему боту и панели
# видно, можно ли выдавать вход клиентам.
entry_check() {  # имя [soft|quiet]
  local a m rc=0
  server_exists || { err "Сервер не создан"; return 1; }
  a=$(py entry "$SERVER_CONF" get "${1:-}" 2>/dev/null)
  [[ -n "$a" ]] || { err "Точки входа «${1:-}» нет"; return 1; }
  [[ "${2:-}" == quiet ]] || info "Проверяю вход «$1»: пакет с сервера на $a должен вернуться на порт AWG"
  entry_probe "$a" || rc=$?
  m=$(case "$rc" in 0) echo ok ;; 1) echo fail ;; *) echo unknown ;; esac)
  _entry_check_save "$1" "$a" "$m"
  log_info "проверка входа «$1» ($a → $(public_ip_cached):$(server_port)): $m"
  if [[ "${2:-}" == quiet ]]; then
    (( rc == 2 )) && warn "Вход «$1» проверить не удалось — выдаю как есть, проверь клиентом"
    (( rc != 1 ))
    return
  fi
  case "$rc" in
    0) ok "Вход работает: пакеты через $a доходят до этого сервера" ;;
    1) if [[ -n "$ENTRY_PROBE_WHY" ]]; then m="Вход «$1» не готов: $ENTRY_PROBE_WHY"
       else m="Через $a пакеты до сервера не дошли — проверь проброс на сервере-входе: UDP ${a##*:} → $(public_ip_cached):$(server_port)"; fi
       if [[ "${2:-}" == soft ]]; then warn "$m"; else err "$m"; fi
       [[ -n "$ENTRY_PROBE_WHY" ]] \
         || info "Вход не простым пробросом (прокси, фильтр по адресам) проверку может не пройти и рабочим — тогда проверь клиентом" ;;
    *) warn "Проверить вход не удалось (адрес не найден или нет модуля iptables string) — проверь клиентом"
       rc=0 ;;
  esac
  return "$rc"
}

# ── Меню awg2 ─────────────────────────────────────────────
_entry_rows() { py entry "$SERVER_CONF" list 2>/dev/null; }

_entry_pick() {  # [direct — с «напрямую»] → имя в CHOSEN (пусто — напрямую)
  local rows=() i c n a k d off=0
  mapfile -t rows < <(_entry_rows)
  if [[ "${1:-}" == direct ]]; then
    off=1
    echo -e "  ${G}  1)${N} Напрямую ${D}— $(entry_direct)${N}"
  else
    (( ${#rows[@]} )) || { warn "Точек входа нет"; return 1; }
  fi
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r n a k d <<< "${rows[$i]}"
    printf "  ${G}%3d)${N} %s ${D}— %s, клиентов %s%s${N}\n" "$((i + 1 + off))" "$n" "$a" "$k" "$( (( d )) && echo ', по умолчанию')"
  done
  read_choice c "${C}  Номер (0 — отмена): ${N}" 0 "$(( ${#rows[@]} + off ))" 0
  (( c == 0 )) && return 1
  CHOSEN=""
  (( c > off )) && CHOSEN=$(cut -f1 <<< "${rows[$((c - 1 - off))]}")
  return 0
}

# Клиенты номерами через пробел или запятую → имена через запятую в _ENTRY_PICKED
_ENTRY_PICKED=""
_entry_pick_clients() {
  local names=() i v picked=()
  mapfile -t names < <(clients_tsv | cut -f1 | grep .)
  (( ${#names[@]} )) || { warn "Клиентов нет"; return 1; }
  for i in "${!names[@]}"; do printf "  ${G}%3d)${N} %s ${D}— %s${N}\n" "$((i + 1))" "${names[$i]}" "$(client_endpoint "${names[$i]}")"; done
  read_line v "${C}  Номера через пробел (Enter — отмена): ${N}"
  for i in ${v//,/ }; do
    [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#names[@]} )) || { warn "Нет номера: $i"; continue; }
    picked+=("${names[$((i - 1))]}")
  done
  (( ${#picked[@]} )) || return 1
  _ENTRY_PICKED=$(IFS=,; echo "${picked[*]}")
}

do_entries_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  local c n a k d st def
  while true; do
    echo ""
    hdr "Точки входа (каскад)"
    echo -e "  ${D}Клиент подключается через сервер-вход, где UDP-порт проброшен на этот.${N}"
    echo -e "  ${D}В его конфиге Endpoint — адрес входа. Напрямую: $(entry_direct)${N}"
    while IFS=$'\t' read -r n a k d st _; do
      [[ -n "$n" ]] || continue
      case "$st" in ok) st="${G}работает${N}" ;; fail) st="${R}не доходит${N}" ;; unknown) st="${Y}не проверить${N}" ;; *) st="${D}не проверялся${N}" ;; esac
      echo -e "  ${W}•${N} $n ${D}— $a, клиентов $k$( (( d )) && echo ', по умолчанию')${N} · $st"
    done < <(_entry_rows_checked)
    def=$(entry_default_get)
    echo ""
    echo -e "  ${G}1)${N} Добавить${D}$([[ -n "$(public_ip6)" ]] && echo " — или 8) IPv6 этого сервера")${N}"
    echo -e "  ${C}2)${N} Изменить адрес"
    echo -e "  ${C}3)${N} Проверить"
    echo -e "  ${C}4)${N} Вход для новых клиентов ${D}— ${def:-напрямую}${N}"
    echo -e "  ${C}5)${N} Перевести всех клиентов"
    echo -e "  ${C}6)${N} Выбрать клиентов"
    echo -e "  ${R}7)${N} Удалить"
    [[ -n "$(public_ip6)" ]] && echo -e "  ${G}8)${N} IPv6 этого сервера ${D}— $(public_ip6)${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-8]: ${N}" 0 8 0
    case "$c" in
      1) read_line n "${C}  Название (например, Каскад NL): ${N}"
         [[ -n "$n" ]] || continue
         read_line a "${C}  Адрес входа хост:порт: ${N}"
         [[ -n "$a" ]] && { entry_add "$n" "${a// /}" || true; } ;;
      2) _entry_pick || continue
         n="$CHOSEN"
         read_line a "${C}  Новый адрес «$n» хост:порт: ${N}"
         [[ -n "$a" ]] && { entry_set "$n" "${a// /}" || true; } ;;
      3) _entry_pick && { entry_check "$CHOSEN" || true; } ;;
      4) _entry_pick direct && { entry_default "${CHOSEN:-direct}" || true; } ;;
      5) _entry_pick direct || continue
         ask_yes "  Переписать Endpoint во всех конфигах? [y/N]: " n && { entry_assign_all "${CHOSEN:-direct}" || true; } ;;
      6) _entry_pick direct || continue
         _entry_pick_clients && { entry_assign_clients "${CHOSEN:-direct}" "$_ENTRY_PICKED" || true; } ;;
      7) _entry_pick || continue
         ask_yes "  Удалить «$CHOSEN»? Его клиенты перейдут на «напрямую» [y/N]: " n && { entry_del "$CHOSEN" || true; } ;;
      8) entry_add_ipv6 || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

do_client_entry() {
  server_exists || { err "Сервер не создан"; return 1; }
  local name
  [[ -n "$(_entry_rows)" ]] || { warn "Точек входа нет — добавь: Сервер → Endpoint → Точки входа"; return 1; }
  _pick_client || return 0
  name="${CHOSEN%%$'\t'*}"
  echo -e "  Сейчас: ${W}$(client_endpoint "$name")${N}"
  _entry_pick direct || return 0
  client_entry_set "$name" "${CHOSEN:-direct}" && share_config "$(client_file "$name")" qr
}
