# Клиенты AWG: добавление, удаление, переименование, выдача конфигов.

# QR с экрана терминала телефоны берут примерно до 2800 байт конфига.
QR_MAX=2800

share_config() {  # файл [qr]
  local f="$1" size
  [[ -f "$f" ]] || return 1
  size=$(wc -c < "$f")
  if [[ "${2:-}" == qr ]]; then
    if command -v qrencode &>/dev/null && (( size <= QR_MAX )); then
      qrencode -t ansiutf8 -m 1 < "$f"
      echo -e "${D}  ↑ QR конфига ($size байт) — сканируй в AmneziaVPN / AmneziaWG${N}"
      return 0
    fi
    warn "Конфиг $size байт — в читаемый QR не влезет, показываю текст"
  fi
  echo -e "${Y}  ── ${f##*/} ──${N}"
  cat "$f"
  echo -e "${Y}  ──────────────${N}"
}

# Добавляет клиента в awg0.conf и в работающий интерфейс, пишет его конфиг.
# Мимикрия берётся из I_LINES/MIMICRY. $5 — срок действия (unix-время), пусто — бессрочно.
client_add() {
  local name="$1" addr="$2" dns="$3" mtu="$4" expire="${5:-}" priv pub psk size
  priv=$(awg genkey) && pub=$(awg pubkey <<< "$priv") && psk=$(awg genpsk) || return 1
  size=$(stat -c%s "$SERVER_CONF")
  printf '\n[Peer]\n# %s\n# mimicry=%s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s\n' \
    "$name" "$(mimicry_tag)" "$pub" "$psk" "$addr" >> "$SERVER_CONF"
  if iface_up && ! awg set "$AWG_IF" peer "$pub" preshared-key <(printf '%s\n' "$psk") allowed-ips "$addr"; then
    truncate -s "$size" "$SERVER_CONF"
    err "Ядро не приняло пира — запись откатана"
    return 1
  fi
  write_client_conf "$(client_file "$name")" "$priv" "$addr" "$psk" "$dns" "$mtu" || return 1
  if [[ -n "$expire" ]]; then
    expire_install
    py expire-set "$SERVER_CONF" "$name" "$expire"
  fi
  log_info "клиент добавлен: $name $addr"
}

# Удаляет пира по ключу: из конфига, из ядра, файл клиента и списки туннелей.
client_delete() {
  local pub="$1" name ip
  # У заблокированного в AllowedIPs заглушка 127.0.0.2, настоящий адрес — в
  # orig_ips: иначе его строки в туннелях и ip rule оставались, а адрес
  # доставался новому клиенту — вместе с чужим туннелем и выходом Xray
  ip=$(clients_tsv | awk -F'\t' -v k="$pub" '$2 == k {split($5 != "" ? $5 : $3, a, "/"); print a[1]; exit}')
  name=$(py peer-del "$SERVER_CONF" "$pub") || return 1
  iface_up && awg set "$AWG_IF" peer "$pub" remove 2>/dev/null
  [[ -n "$name" ]] && rm -f "$CLIENT_DIR/${name}_awg2.conf" "$CLIENT_DIR/${name}_awg3.conf"
  rm -f "$EXPIRE_STATE_DIR/warn1h_${pub//[^A-Za-z0-9]/_}"
  [[ -n "$ip" ]] && tunnel_peers_forget "$ip"
  log_info "клиент удалён: ${name:-?} ($pub)"
  ok "Удалён: ${name:-без имени}"
}

# ── Ядра операций (без вопросов: меню, командная строка и бот) ──
client_pub() { clients_tsv | awk -F'\t' -v n="$1" '$1 == n {print $2; exit}'; }

# client_create ИМЯ [СРОК] [МИМИКРИЯ] [DNS] [MTU]
# МИМИКРИЯ — строка mimicry_from_spec, по умолчанию «как у сервера».
client_create() {
  local name="$1" expire="${2:-}" spec="${3:-server}" dns="${4:-1.1.1.1, 1.0.0.1}" mtu="${5:-}" addr
  server_exists || { err "Сервер не создан"; return 1; }
  _name_free "$name" || { err "Имя $name занято или недопустимо (латиница, цифры, _ -, до 32)"; return 1; }
  [[ -z "$expire" ]] || { [[ "$expire" =~ ^[0-9]+$ ]] && (( expire > $(date +%s) + 60 )); } \
    || { err "Срок — unix-время в будущем"; return 1; }
  [[ -n "$mtu" ]] || mtu=$(conf_iface_get MTU)
  addr=$(free_client_ip) || { err "В подсети нет свободных адресов"; return 1; }
  mimicry_from_spec "$spec" || return 1
  client_add "$name" "$addr" "$dns" "$mtu" "$expire" || return 1
  ok "Клиент $name: $addr"
  echo "Файл конфигурации: $(client_file "$name")"
}

client_remove() {  # имя
  local pub
  pub=$(client_pub "$1")
  [[ -n "$pub" ]] || { err "Клиента $1 нет"; return 1; }
  client_delete "$pub"
}

client_rename() {  # старое новое
  local old="$1" new="$2" pub f
  pub=$(client_pub "$old")
  [[ -n "$pub" ]] || { err "Клиента $old нет"; return 1; }
  _name_free "$new" || { err "Имя $new занято или недопустимо"; return 1; }
  py peer-rename "$SERVER_CONF" "$pub" "$new" || return 1
  f=$(client_file "$old")
  [[ -f "$f" ]] && mv -f "$f" "$CLIENT_DIR/${new}$(client_suffix).conf"
  log_info "клиент переименован: $old → $new"
  ok "Переименован: $old → $new"
}

# Мимикрия выданного клиента: меняются только его I1-I5 — сервер их не видит.
client_set_mimicry() {  # имя строка
  [[ -f "$(client_file "$1")" ]] || { err "Нет конфига клиента $1"; return 1; }
  mimicry_from_spec "$2" && _client_write_mimicry "$1"
}

_client_write_mimicry() {  # имя — записать текущие I_LINES
  local name="$1" f
  f=$(client_file "$name")
  cp -a "$f" "$f.bak.$(date +%s)"
  i_lines_block | py i-replace "$f" || return 1
  peer_meta_set "$name" mimicry "$(mimicry_tag)" || warn "Метку в awg0.conf обновить не удалось"
  ok "Мимикрия $name: $(mimicry_tag), пакетов: ${#I_LINES[@]}"
  warn "Клиенту нужен новый конфиг"
}

client_expire_set() {  # имя unix-время
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > $(date +%s) + 60 )) || { err "Срок должен быть в будущем"; return 1; }
  client_exists "$1" || { err "Клиента $1 нет"; return 1; }
  expire_install
  # Заблокированному сначала вернуть адрес: expire-set правит только метку,
  # и клиент остался бы на 127.0.0.2 с новым сроком — «заблокирован» без причины.
  # Блокировку за трафик новый срок не снимает — её снимает лимит.
  if [[ -n "$(peer_meta_get "$1" orig_ips)" && "$(peer_meta_get "$1" blocked_by)" != traffic ]]; then
    py expire-clear "$SERVER_CONF" "$1" "$EXPIRE_SUSPEND_IP" >/dev/null || return 1
    _expire_apply
  fi
  py expire-set "$SERVER_CONF" "$1" "$2" || return 1
  rm -f "$EXPIRE_STATE_DIR/warn1h_$(client_pub "$1" | tr -c 'A-Za-z0-9\n' '_')"
  ok "Срок $1: $(expire_fmt "$2")"
}

# Снять срок; заблокированный клиент получает прежний адрес.
client_expire_clear() {
  local r
  client_exists "$1" || { err "Клиента $1 нет"; return 1; }
  r=$(py expire-clear "$SERVER_CONF" "$1" "$EXPIRE_SUSPEND_IP") || return 1
  _expire_apply
  ok "$1 — бессрочный"
  [[ "$r" == traffic ]] && warn "$1 остаётся заблокирован: исчерпан лимит трафика"
  return 0
}

# Лимит трафика: РАЗМЕР (50G, 500M) за месяц или всего; off — снять.
# Применяется сразу: превысивший блокируется, уложившийся — разблокируется.
client_limit_set() {  # имя размер|off [month|total]
  local name="$1" size="$2" period="${3:-month}" v tr
  client_exists "$name" || { err "Клиента $name нет"; return 1; }
  [[ "$period" == month || "$period" == total ]] || { err "Период: month или total"; return 1; }
  expire_install
  tr=$(_traffic_snapshot) || return 1
  v=$(py limit-set "$SERVER_CONF" "$TRAFFIC_DB" "$name" "$size" "$period" "$tr" \
      "$(cat "/sys/class/net/$AWG_IF/ifindex" 2>/dev/null)") || { rm -f "$tr"; return 1; }
  rm -f "$tr"
  traffic_tick 1
  if [[ "$size" == off ]]; then ok "$name — без лимита трафика"
  else ok "Лимит $name: $v $([[ "$period" == month ]] && echo "в месяц" || echo "всего")"; fi
}

client_limit_reset() {  # имя
  local tr
  client_exists "$1" || { err "Клиента $1 нет"; return 1; }
  tr=$(_traffic_snapshot) || return 1
  py limit-reset "$SERVER_CONF" "$TRAFFIC_DB" "$1" "$tr" "$(cat "/sys/class/net/$AWG_IF/ifindex" 2>/dev/null)" \
    || { rm -f "$tr"; return 1; }
  rm -f "$tr"
  traffic_tick 1
  ok "Счётчик лимита $1 обнулён"
}

# «12.3 ГБ из 50.0 ГБ за месяц» для меню.
limit_fmt() {  # метка limit (БАЙТ/период) использовано
  local n="${1%/*}" p="${1#*/}"
  echo "$(fmt_bytes "${2:-0}") из $(fmt_bytes "$n") $([[ "$p" == month ]] && echo "за месяц" || echo "всего")"
}

# Удалить клиентов с истёкшим сроком. Заблокированных за трафик не трогает:
# они разблокируются сами в новом месяце или после смены лимита.
clients_purge_blocked() {
  local pub n=0
  while IFS= read -r pub; do client_delete "$pub" && n=$((n + 1)); done \
    < <(clients_tsv | awk -F'\t' '$5 != "" && $8 != "traffic" {print $2}')
  ok "Удалено с истёкшим сроком: $n"
}

# Архив всех конфигов → путь в EXPORT_PATH.
EXPORT_PATH=""
clients_export() {
  local files=() stamp
  mapfile -t files < <(client_files)
  (( ${#files[@]} )) || { warn "Конфигов клиентов нет"; return 1; }
  stamp=$(date +%Y%m%d_%H%M%S)
  if command -v zip &>/dev/null || apt_install zip >/dev/null 2>&1; then
    EXPORT_PATH="$CLIENT_DIR/awg_clients_$stamp.zip"
    zip -j -q "$EXPORT_PATH" "${files[@]}" || return 1
  else
    EXPORT_PATH="$CLIENT_DIR/awg_clients_$stamp.tar.gz"
    tar -czf "$EXPORT_PATH" -C "$CLIENT_DIR" "${files[@]##*/}" || return 1
  fi
  chmod 600 "$EXPORT_PATH"
  ok "Архив: $EXPORT_PATH (${#files[@]} конфигов)"
}

# Имя для нового клиента: валидное и не занятое ни пиром, ни файлом.
_name_free() { valid_client_name "$1" && ! client_exists "$1" && [[ ! -e "$CLIENT_DIR/${1}_awg2.conf" && ! -e "$CLIENT_DIR/${1}_awg3.conf" ]]; }

_ask_expire() {  # → unix-время в stdout или пусто
  local c d ts=""
  {
    echo -e "  Срок действия:"
    echo -e "  ${C}1)${N} Бессрочно"
    echo -e "  ${C}2)${N} 1 час"
    echo -e "  ${C}3)${N} 1 день"
    echo -e "  ${C}4)${N} 7 дней"
    echo -e "  ${C}5)${N} 30 дней"
    echo -e "  ${C}6)${N} До даты"
  } >&2
  read_choice c "${C}  Выбор [1-6] (Enter = 1): ${N}" 1 6 1 >&2
  case "$c" in
    2) ts=$(date -d '+1 hour' +%s) ;; 3) ts=$(date -d '+1 day' +%s) ;;
    4) ts=$(date -d '+7 days' +%s) ;; 5) ts=$(date -d '+30 days' +%s) ;;
    6) read_line d "${C}  Дата (ГГГГ-ММ-ДД ЧЧ:ММ): ${N}" >&2
       ts=$(date -d "$d" +%s 2>/dev/null) || ts=""
       [[ -n "$d" && "$ts" =~ ^[0-9]+$ ]] && (( ts > $(date +%s) + 60 )) \
         || { warn "Дата не распознана или уже прошла — бессрочно" >&2; ts=""; } ;;
  esac
  echo "$ts"
}

# Мимикрия для нового клиента по профилю сервера.
_client_mimicry() {
  local profile c
  profile=$(server_profile)
  I_LINES=(); MIMICRY=none
  case "$profile" in
    lite|standard) mimicry_from_spec server ;;
    *)
      c=$(conf_marker AWG_MIMICRY)
      echo -e "  Мимикрия I1-I5:"
      echo -e "  ${C}1)${N} Как у сервера ${D}(${c:-none})${N}"
      echo -e "  ${C}2)${N} Выбрать"
      echo -e "  ${C}3)${N} Без I1-I5"
      read_choice c "${C}  Выбор [1-3] (Enter = 1): ${N}" 1 3 1
      case "$c" in
        1) mimicry_from_spec server ;;
        2) choose_and_gen_chain || { I_LINES=(); MIMICRY=none; } ;;
      esac ;;
  esac
}

do_add_client() {
  server_exists || { err "Сервер не создан"; return 1; }
  local name addr ip expire base
  while true; do
    read_line name "${C}  Имя клиента (латиница, цифры, _ -): ${N}"
    [[ -z "$name" ]] && return 0
    _name_free "$name" && break
    valid_client_name "$name" && warn "Клиент $name уже есть" || warn "Имя: латиница, цифры, _ и -, до 32 символов"
  done
  addr=$(free_client_ip) || { err "В подсети нет свободных адресов"; return 1; }
  if ! ask_yes "  Адрес $addr? [Y/n]: " y; then
    base=$(server_net); base="${base%.*}"
    while true; do
      read_line ip "${C}  Адрес ${base}.N: ${N}"
      ip="${ip%/32}"
      [[ -z "$ip" ]] && return 0
      if [[ "$ip" =~ ^${base//./\\.}\.([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 2 && BASH_REMATCH[1] <= 254 )) \
         && ! clients_tsv | cut -f3,5 | tr '\t,' '\n\n' | grep -qx "$ip/32" \
         && [[ "$ip" != "$(conf_iface_get Address | cut -d/ -f1)" ]]; then
        addr="$ip/32"; break
      fi
      warn "Нужен свободный адрес ${base}.2-254"
    done
  fi
  S_DNS="1.1.1.1, 1.0.0.1"
  _choose_dns
  MTU=$(conf_iface_get MTU); _choose_mtu "${MTU:-1280}"
  _client_mimicry
  expire=$(_ask_expire)
  client_add "$name" "$addr" "$S_DNS" "$MTU" "$expire" || return 1
  share_config "$(client_file "$name")"
  success_box "Клиент $name: $addr"
  if [[ -n "$expire" ]]; then info "Срок действия: $(expire_fmt "$expire")"; fi
}


do_bulk_add() {
  server_exists || { err "Сервер не создан"; return 1; }
  local c raw prefix count names=() n i addr expire created=0 part
  local -a parts=()
  echo -e "  ${C}1)${N} Префикс + количество ${D}(user-001...)${N}"
  echo -e "  ${C}2)${N} Имена через запятую"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 2 ]]; then
    read_line raw "${C}  Имена через запятую: ${N}"
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
      n=$(tr -cd 'A-Za-z0-9_-' <<< "${part// /_}"); n="${n:0:32}"
      [[ -n "$n" ]] || continue
      if [[ " ${names[*]} " == *" $n "* ]] || ! _name_free "$n"; then warn "Пропущено: $n (занято)"; continue; fi
      names+=("$n")
    done
  else
    read_line prefix "${C}  Префикс: ${N}"
    valid_client_name "$prefix" && (( ${#prefix} <= 27 )) || { warn "Префикс: латиница, цифры, _ -, до 27 символов"; return 0; }
    read_line count "${C}  Сколько клиентов (1-200): ${N}"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 200 )) || { warn "Нужно число 1-200"; return 0; }
    i=1
    while (( ${#names[@]} < count && i < 10000 )); do
      printf -v n '%s-%03d' "$prefix" "$i"
      _name_free "$n" && names+=("$n")
      i=$((i + 1))
    done
  fi
  (( ${#names[@]} )) || { warn "Нет имён для создания"; return 0; }
  S_DNS="1.1.1.1, 1.0.0.1"; _choose_dns
  MTU=$(conf_iface_get MTU); _choose_mtu "${MTU:-1280}"
  _client_mimicry
  expire=$(_ask_expire)
  ask_yes "  Создать клиентов: ${#names[@]}? [Y/n]: " y || return 0
  for n in "${names[@]}"; do
    addr=$(free_client_ip) || { warn "Подсеть заполнена — стоп"; break; }
    client_add "$n" "$addr" "$S_DNS" "$MTU" "$expire" || { warn "$n: не создан"; continue; }
    echo -e "  ${G}+${N} $n → $addr"
    created=$((created + 1))
  done
  success_box "Создано клиентов: $created из ${#names[@]}"
  info "Конфиги: $CLIENT_DIR/<имя>$(client_suffix).conf; архивом — Клиенты → Экспорт"
}

# Выбор клиента из списка. Результат — «имя<TAB>ключ» в CHOSEN.
CHOSEN=""
_pick_client() {
  local rows=() i c name pub aip
  mapfile -t rows < <(clients_tsv)
  (( ${#rows[@]} )) || { warn "Клиентов нет"; return 1; }
  echo ""
  for i in "${!rows[@]}"; do
    IFS='|' read -r name pub aip _ <<< "${rows[$i]//$'\t'/|}"
    printf "  ${G}%3d)${N} %-24s ${D}%s${N}\n" "$((i + 1))" "${name:-без имени}" "$aip"
  done
  read_choice c "${C}  Номер (0 — отмена): ${N}" 0 "${#rows[@]}" 0
  (( c == 0 )) && return 1
  IFS='|' read -r name pub _ <<< "${rows[$((c - 1))]//$'\t'/|}"
  CHOSEN="$name"$'\t'"$pub"
}

do_delete_client() {
  server_exists || { err "Сервер не создан"; return 1; }
  local c raw n pubs=() names=() row pub
  local -a parts=()
  echo -e "  ${C}1)${N} Одного по номеру"
  echo -e "  ${C}2)${N} Несколько по именам"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    _pick_client || return 0
    names=("${CHOSEN%%$'\t'*}"); pubs=("${CHOSEN#*$'\t'}")
  else
    read_line raw "${C}  Имена через запятую: ${N}"
    IFS=',' read -r -a parts <<< "$raw"
    for n in "${parts[@]}"; do
      n="${n// /}"; [[ -n "$n" ]] || continue
      row=$(clients_tsv | awk -F'\t' -v n="$n" '$1 == n {print $2; exit}')
      if [[ -n "$row" ]]; then names+=("$n"); pubs+=("$row"); else warn "Нет клиента: $n"; fi
    done
    (( ${#pubs[@]} )) || return 0
  fi
  warn "Будут удалены: ${names[*]:-без имени}"
  read_confirm "${R}  Подтверди удаление (введи yes): ${N}" || { info "Отменено"; return 0; }
  cp -a "$SERVER_CONF" "${SERVER_CONF}.pre_delete.$(date +%s)"
  for pub in "${pubs[@]}"; do client_delete "$pub" || true; done
}

do_rename_client() {
  server_exists || { err "Сервер не создан"; return 1; }
  local old new
  _pick_client || return 0
  old="${CHOSEN%%$'\t'*}"
  [[ -n "$old" ]] || { warn "У клиента нет имени — переименовать можно только именованного"; return 1; }
  while true; do
    read_line new "${C}  Новое имя для $old: ${N}"
    [[ -z "$new" || "$new" == "$old" ]] && return 0
    _name_free "$new" && break
    warn "Имя недопустимо или занято"
  done
  client_rename "$old" "$new"
}

_pick_client_file() {  # → путь в CHOSEN
  local files=() i c
  mapfile -t files < <(client_files)
  (( ${#files[@]} )) || { warn "Конфигов клиентов в $CLIENT_DIR нет"; return 1; }
  for i in "${!files[@]}"; do printf "  ${G}%3d)${N} %s\n" "$((i + 1))" "${files[$i]##*/}"; done
  read_choice c "${C}  Номер (Enter = 1, 0 — отмена): ${N}" 0 "${#files[@]}" 1
  (( c == 0 )) && return 1
  CHOSEN="${files[$((c - 1))]}"
}

do_show_client()    { _pick_client_file && share_config "$CHOSEN"; }
do_show_client_qr() { _pick_client_file && share_config "$CHOSEN" qr; }

do_list_clients() {
  server_exists || { err "Сервер не создан"; return 1; }
  local dump now name pub aip exp orig _ hs rx tx ep st i=0 age lim per used month today by
  local -A tl=()
  dump=$(awg show "$AWG_IF" dump 2>/dev/null | tail -n +2)
  now=$(date +%s)
  while IFS='|' read -r name lim per used month today by; do
    [[ -n "$name" ]] && tl[x$name]="$lim|$per|$used|$month|$today|$by"
  done < <(traffic_rows)
  echo ""
  hdr "Клиенты"
  while IFS='|' read -r name pub aip exp orig _; do
    i=$((i + 1))
    ep="" hs=0 rx=0 tx=0
    read -r ep hs rx tx < <(awk -F'\t' -v k="$pub" '$1 == k {print $3, $5, $6, $7; exit}' <<< "$dump") || true
    [[ "$ep" == "(none)" ]] && ep=""
    if [[ "${hs:-0}" =~ ^[0-9]+$ ]] && (( ${hs:-0} > 0 )); then
      age=$(( now - hs ))
      if (( age < 180 )); then st="${G}● онлайн${N} ${D}($(fmt_duration "$age") назад)${N}"
      else st="${D}○ был $(fmt_duration "$age") назад${N}"; fi
    else
      st="${D}○ не подключался${N}"
    fi
    echo -e "  ${W}$i) ${name:-без имени}${N}  ${D}$aip${N}"
    echo -e "     $st  ↑ $(fmt_bytes "${tx:-0}")  ↓ $(fmt_bytes "${rx:-0}")${ep:+  ${D}${ep%:*}${N}}"
    IFS='|' read -r lim per used month today by <<< "${tl[x$name]:-0|||0|0|}"
    (( ${month:-0} )) && echo -e "     ${D}за месяц $(fmt_bytes "$month"), сегодня $(fmt_bytes "${today:-0}")${N}"
    if [[ "$by" == traffic ]]; then echo -e "     ${R}заблокирован: исчерпан лимит — $(limit_fmt "$lim/$per" "$used")${N}"
    elif [[ "${lim:-0}" != 0 ]]; then echo -e "     ${D}лимит: $(limit_fmt "$lim/$per" "$used")${N}"; fi
    if [[ -n "$exp" ]]; then
      if [[ -n "$orig" && "$by" != traffic ]]; then echo -e "     ${R}заблокирован: срок истёк $(expire_fmt "$exp")${N}"
      elif [[ -z "$orig" ]]; then echo -e "     ${Y}срок: $(expire_fmt "$exp")${N}"; fi
    fi
  done < <(clients_psv)
  (( i )) || info "Клиентов нет"
}

do_export_clients() {
  clients_export || return 0
  info "Скачать: scp root@$(public_ip_cached):$EXPORT_PATH ."
}

# Смена мимикрии у выданного клиента: меняются только его I1-I5.
do_change_mimicry() {
  local f name
  _pick_client_file || return 0
  f="$CHOSEN"; name=$(client_name_of "$f")
  echo -e "  Сейчас: ${W}$(peer_meta_get "$name" mimicry || true)${N}"
  if [[ "$(server_profile)" == pro ]]; then
    choose_and_gen_chain || return 0
  else
    OBF_LEVEL=2
    choose_mimicry || return 0
    choose_cps_domain
    mimicry_generate
  fi
  _client_write_mimicry "$name" || return 1
  share_config "$f"
}

do_clients_menu() {
  local c
  while true; do
    echo ""
    hdr "Клиенты ($(clients_tsv | wc -l))"
    echo -e "  ${G}1)${N} Добавить клиента"
    echo -e "  ${C}2)${N} Активность и трафик"
    echo -e "  ${C}3)${N} Показать конфиг"
    echo -e "  ${C}4)${N} Показать QR"
    echo -e "  ${C}5)${N} Переименовать"
    echo -e "  ${G}6)${N} Создать несколько"
    echo -e "  ${C}7)${N} Сроки и лимиты трафика"
    echo -e "  ${C}8)${N} Экспорт всех (zip)"
    echo -e "  ${C}9)${N} Сменить мимикрию"
    echo -e "  ${R}10)${N} Удалить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-10]: ${N}" 0 10 0
    case "$c" in
      1) do_add_client || true ;;     6) do_bulk_add || true ;;
      2) do_list_clients || true ;;   7) do_expire_menu || true ;;
      3) do_show_client || true ;;    8) do_export_clients || true ;;
      4) do_show_client_qr || true ;; 9) do_change_mimicry || true ;;
      5) do_rename_client || true ;;  10) do_delete_client || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
