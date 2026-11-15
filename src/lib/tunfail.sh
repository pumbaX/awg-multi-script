# Если туннель упал: на каждый туннель (WARP, Xray, tun2socks, exit-ноды) —
# «напрямую» (как было: клиенты идут с адреса сервера) или «блокировать»
# (клиенты ждут туннель без интернета, кроме «РФ напрямую»). Режим работает в
# rt_up / rt_down (tunnels.sh): у включения и у падения туннеля. Здесь — выбор,
# применение на ходу, сторож и меню.
#
# Сторож (awg2-tunfail.service: при загрузке и по таймеру раз в минуту) держит
# клиентов включённого, но лежащего туннеля в режиме «блокировать»: после
# перезагрузки, пока туннель не поднялся, и если служба туннеля не дошла до
# своих правил (Xray не дождался выхода, exit-ноды не поднялись). Поднят другой
# туннель — лежащий не держится: его правила перехватили бы чужих клиентов.

TUNFAIL_NAMES="warp xray t2s exits"

_tunfail_table() {
  case "$1" in
    warp) echo "$WARP_TABLE" ;; xray) echo "$XRAY_TABLE" ;; t2s) echo "$T2S_TABLE" ;; exits) echo "$EXITS_TABLE" ;;
  esac
}

tunfail_label() {
  case "$1" in warp) echo WARP ;; xray) echo Xray ;; t2s) echo tun2socks ;; exits) echo "Exit-ноды WG" ;; esac
}

_tunfail_log() { mkdir -p "$(dirname "$TUNFAIL_LOG")"; echo "[$(date '+%F %T')] $*" >> "$TUNFAIL_LOG"; }

tunfail_any_block() { grep -q '=block$' "$TUNFAIL_CONF" 2>/dev/null; }
tunfail_block() { [[ "$(rt_fail_mode "$1")" == block ]]; }   # имя

# Таблицы, на которые сейчас есть правила клиентов
_tunfail_rule_tables() { ip rule show 2>/dev/null | awk '$(NF - 1) == "lookup" && $NF ~ /^[0-9]+$/ {print $NF}' | sort -un; }

_tunfail_is_exit_table() { (( $1 == EXITS_TABLE || ($1 >= EXITS_TABLE_BASE && $1 <= EXITS_TABLE_MAX) )); }

# Поднят другой туннель (у него живой маршрут)
_tunfail_other_live() {  # имя
  local t me
  me=$(_tunfail_table "$1")
  for t in $(_tunfail_rule_tables); do
    (( t == me )) && continue
    [[ "$1" == exits ]] && _tunfail_is_exit_table "$t" && continue
    (( t == T2S_TABLE || t == WARP_TABLE || t == XRAY_TABLE )) || _tunfail_is_exit_table "$t" || continue
    rt_table_live "$t" && return 0
  done
  return 1
}

# Правила клиентов туннеля — в его таблицу с «недоступно». 0 — удержание
# поставлено сейчас, 1 — правила уже были (держит сам туннель) или не вышло.
_tunfail_hold() {  # имя
  local name="$1" table net mode f line ip
  table=$(_tunfail_table "$name")
  ip route replace unreachable default metric 4096 table "$table" 2>/dev/null || return 1
  grep -qE "lookup $table\$" <<< "$(ip rule show 2>/dev/null)" && return 1
  net=$(server_net) || return 1
  case "$name" in
    warp) rt_rules_file "$WARP_PEERS" "$table" ;;
    xray) rt_rules_file "$XRAY_PEERS" "$table" ;;
    t2s) ip rule add from "$net" lookup "$table" priority "$table" ;;
    exits)
      mode=$(sed -n 's/^mode=//p' "$EXITS_STATE" 2>/dev/null | head -1)
      if [[ "${mode:-all}" == all ]]; then ip rule add from "$net" lookup "$table" priority "$table"
      else f="$EXITS_PEERS"; fi
      for f in ${f:+"$f"} "$EXITS_PEERS.wgobf"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
          ip="${line%%|*}"; ip="${ip//[[:space:]]/}"
          valid_ip "$ip" && ip rule add from "$ip" lookup "$table" priority "$table"
        done < "$f"
      done ;;
  esac
  return 0
}

# Отпустить клиентов лежащего туннеля (режим «напрямую»): правила и маршруты
# его таблиц сняты — клиенты идут напрямую. Живой туннель — только снять
# «недоступно» под его маршрутом.
_tunfail_release() {  # имя
  local name="$1" t table
  table=$(_tunfail_table "$name")
  for t in "$table" $( [[ "$name" == exits ]] && _tunfail_rule_tables ); do
    [[ "$name" == exits && "$t" != "$table" ]] && ! _tunfail_is_exit_table "$t" && continue
    if rt_table_live "$t"; then
      ip route del unreachable default metric 4096 table "$t" 2>/dev/null || true
    else
      rt_rules_clear "$t"
      ip route flush table "$t" 2>/dev/null || true
    fi
  done
  return 0
}

# Точка входа сторожа: включённый, но лежащий туннель в режиме «блокировать»
# держит своих клиентов; работающий — получает «недоступно» под маршрутом.
tunfail_guard_run() {
  local name table
  for name in $TUNFAIL_NAMES; do
    [[ "$(rt_fail_mode "$name")" == block ]] || continue
    table=$(_tunfail_table "$name")
    rt_tunnel_on "$table" || continue
    if rt_table_live "$table"; then rt_fail_route "$table"; continue; fi
    _tunfail_other_live "$name" && continue
    if _tunfail_hold "$name"; then
      _tunfail_log "$(tunfail_label "$name") включён, но не работает — клиенты удержаны до его подъёма"
    fi
  done
  return 0
}

# Удержан сейчас: включён, не работает, режим «блокировать», правила стоят
tunfail_held() {  # имя
  local table
  table=$(_tunfail_table "$1")
  [[ "$(rt_fail_mode "$1")" == block ]] && rt_tunnel_on "$table" && ! rt_table_live "$table" \
    && grep -qE "lookup $table\$" <<< "$(ip rule show 2>/dev/null)" \
    && ip route show table "$table" 2>/dev/null | grep -q '^unreachable default'
}

# ── Установка ─────────────────────────────────────────────
_tunfail_emit() {
  emit_script "$TUNFAIL_SCRIPT" 'tunfail_guard_run' WARP_PEERS XRAY_PEERS EXITS_PEERS TUNFAIL_NAMES \
    "${RT_FUNCS[@]}" _tunfail_table tunfail_label _tunfail_log _tunfail_rule_tables _tunfail_is_exit_table \
    _tunfail_other_live _tunfail_hold tunfail_guard_run || return 1
  # Один юнит: при загрузке (сразу за awg0 — раньше туннелей) и от таймера
  write_unit "$TUNFAIL_UNIT" <<EOF
[Unit]
Description=AWG Toolza — если туннель упал: клиенты туннелей в режиме «блокировать» не уходят напрямую
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$TUNFAIL_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  write_unit "$TUNFAIL_TIMER" <<'EOF'
[Unit]
Description=AWG Toolza — если туннель упал: проверка раз в минуту

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
EOF
}

_tunfail_units() {
  if tunfail_any_block; then
    _tunfail_emit || { err "Не удалось записать службу сторожа"; return 1; }
    systemctl enable "$TUNFAIL_UNIT" &>/dev/null || true
    systemctl enable --now "$TUNFAIL_TIMER" &>/dev/null || true
  else
    remove_unit "$TUNFAIL_TIMER" "$TUNFAIL_UNIT"
  fi
  return 0
}

# Режим туннелю (или всем) и сразу — на ходу.
tunfail_set() {  # warp|xray|t2s|exits|all direct|block
  local name="$1" mode="${2:-}" n list
  [[ "$mode" == direct || "$mode" == block ]] || { err "Режим: direct | block"; return 1; }
  if [[ "$name" == all ]]; then list="$TUNFAIL_NAMES"
  elif [[ " $TUNFAIL_NAMES " == *" $name "* ]]; then list="$name"
  else err "Туннель: warp | xray | t2s | exits | all"; return 1; fi
  mkdir -p "$(dirname "$TUNFAIL_CONF")"
  for n in $list; do
    { grep -v "^$n=" "$TUNFAIL_CONF" 2>/dev/null; [[ "$mode" == block ]] && echo "$n=block"; } \
      | write_file "$TUNFAIL_CONF" 644
    if [[ "$mode" == block ]]; then tunfail_guard_run; else _tunfail_release "$n"; fi
    _tunfail_log "$(tunfail_label "$n"): если упал — $([[ "$mode" == block ]] && echo блокировать || echo напрямую)"
    log_info "если туннель упал: $n → $mode"
  done
  [[ -s "$TUNFAIL_CONF" ]] || rm -f "$TUNFAIL_CONF"
  _tunfail_units || return 1
  if [[ "$mode" == block ]]; then
    ok "$([[ "$name" == all ]] && echo "Все туннели" || tunfail_label "$name"): если упадёт — клиенты ждут его без интернета (кроме «РФ напрямую»)"
  else
    ok "$([[ "$name" == all ]] && echo "Все туннели" || tunfail_label "$name"): если упадёт — клиенты идут напрямую, как раньше"
  fi
}

# Строки статуса: имя, режим, включён, работает, удержан
tunfail_rows() {
  local n table
  for n in $TUNFAIL_NAMES; do
    table=$(_tunfail_table "$n")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$(tunfail_label "$n")" "$(rt_fail_mode "$n")" \
      "$(rt_tunnel_on "$table" && echo 1 || echo 0)" "$(rt_table_live "$table" && echo 1 || echo 0)" \
      "$(tunfail_held "$n" && echo 1 || echo 0)"
  done
}

# Таймер сторожа молчит (сброшен, заглох) — вернуть
tunfail_watchdog() {
  tunfail_any_block || return 0
  systemctl is-active --quiet "$TUNFAIL_TIMER" 2>/dev/null && return 0
  _tunfail_units &>/dev/null || true
}

tunfail_remove() {
  remove_unit "$TUNFAIL_TIMER" "$TUNFAIL_UNIT"
  rm -f "$TUNFAIL_SCRIPT" "$TUNFAIL_CONF" "$TUNFAIL_LOG"
}

# ── Меню ──────────────────────────────────────────────────
do_tunfail_menu() {
  local c n mode en up st rows=()
  while true; do
    echo ""
    hdr "Если туннель упал"
    echo -e "  ${D}Напрямую — как раньше: клиенты упавшего туннеля идут с адреса сервера."
    echo -e "  Блокировать — ждут туннель без интернета (кроме «РФ напрямую»): адрес сервера"
    echo -e "  не засветится. Выключенный руками туннель клиентов отпускает в любом режиме.${N}"
    echo ""
    mapfile -t rows < <(tunfail_rows)
    for c in "${!rows[@]}"; do
      IFS=$'\t' read -r n _ mode _ _ st <<< "${rows[$c]}"
      echo -e "  ${C}$((c + 1)))${N} $(printf '%-14s' "$(tunfail_label "$n")") $([[ "$mode" == block ]] && echo "${Y}блокировать${N}" || echo "напрямую")$( (( st )) && echo " ${R}— сейчас удерживает клиентов${N}")"
    done
    echo -e "  ${C}a)${N} Всем — напрямую ${D}(как было)${N}"
    echo -e "  ${C}l)${N} Журнал"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер — переключить: ${N}" 0 4 0 "a|l"
    case "$c" in
      0) return 0 ;;
      a) tunfail_set all direct || true ;;
      l) tail -n 40 "$TUNFAIL_LOG" 2>/dev/null || info "Журнал пуст" ;;
      *) IFS=$'\t' read -r n _ mode en up _ <<< "${rows[$((c - 1))]}"
         if [[ "$mode" == block ]]; then tunfail_set "$n" direct || true
         elif (( en && ! up )); then
           # Включён, но лежит: «блокировать» сразу оставит его клиентов без интернета
           warn "$(tunfail_label "$n") сейчас не работает: его клиенты сразу останутся без интернета (кроме «РФ напрямую»)"
           if ask_yes "  Блокировать? [y/N]: " n; then tunfail_set "$n" block || true; fi
         else tunfail_set "$n" block || true; fi ;;
    esac
    pause
  done
}
