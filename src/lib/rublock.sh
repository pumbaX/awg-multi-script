# РФ мимо VPN: клиенты VPN (awg0 и WG + обфускатор) не ходят через сервер в
# сети России. Российские сайты и приложения на телефоне с VPN не видят адрес
# сервера и не могут сдать его как VPN — нужно зарубежному серверу. Российские
# сервисы у клиентов через VPN не откроются — их пускают мимо туннеля
# (раздельное туннелирование в приложении VPN). Противоположно «РФ напрямую»:
# включено может быть что-то одно.
#
# Как устроено: набор ipset сетей России (список и проверка — те же, что у «РФ
# напрямую»), пакеты клиентов к ним помечаются в mangle PREROUTING, а правило
# ip rule «prohibit» с приоритетом 85 — раньше «РФ напрямую» (90) и туннелей
# (100-249) — отвечает отказом (ICMP «запрещено»): соединение у клиента сразу
# обрывается, а не висит до таймаута, как при DROP. Частоту ICMP ядро
# ограничивает (на клиента ~1 в секунду после запаса) — при шквале соединений
# часть получит отказ через 1-3 с повторов; системный лимит не трогаем.
# Правила маршрутизации от порядка в FORWARD не зависят. Свой трафик сервера и
# пакеты к его адресам не трогаются.
#
# Служба ставит набор и правила при загрузке, таймер раз в час лечит их, раз в
# сутки обновляет список. Без сети — на сохранённом.

_rublock_get() { sed -n "s/^$1=//p" "$RUBLOCK_CONF" 2>/dev/null | tail -1; }

_rublock_set() {  # КЛЮЧ ЗНАЧЕНИЕ
  local v="${2//[$'\n\r']/ }"
  mkdir -p "$RUBLOCK_DIR" && chmod 700 "$RUBLOCK_DIR"
  { grep -v "^$1=" "$RUBLOCK_CONF" 2>/dev/null; printf '%s=%s\n' "$1" "$v"; } | write_file "$RUBLOCK_CONF" 600
}

_rublock_log() { mkdir -p "$(dirname "$RUBLOCK_LOG")"; echo "[$(date '+%F %T')] $*" >> "$RUBLOCK_LOG"; }

_rublock_fail() { _rublock_set ERROR "$1"; _rublock_log "$1"; return 1; }

rublock_on() { [[ "$(_rublock_get ON)" == 1 ]]; }

# Скачать список РФ: по очереди из источников «РФ напрямую», первый прошедший
# ту же проверку. Не прошёл — остаётся прежний.
_rublock_fetch() {
  local tmp src lbl n s4 why="" keep="оставлен прежний список"
  mkdir -p "$RUBLOCK_DIR" && chmod 700 "$RUBLOCK_DIR"
  [[ -s "$RUBLOCK_DIR/ru.list" ]] || keep="список не принят"
  tmp=$(mktemp "$RUBLOCK_DIR/.dl.XXXXXX") || return 1
  for src in $RUDIRECT_SRCS; do
    lbl="${src#https://}"
    if [[ "$lbl" == raw.githubusercontent.com/* ]]; then lbl="${lbl#*/}"; lbl="${lbl%%/*}"
    else lbl="${lbl%%/*}"; lbl="${lbl#www.}"; fi
    if ! curl -fsS --proto '=https' --max-time 60 --max-filesize 5000000 -o "$tmp" "$src" 2>/dev/null; then
      _rublock_log "${src#https://}: не скачался"; why+="${why:+; }$lbl: не скачался"; continue
    fi
    read -r n s4 _ < <(_antiscan_parse 4 < "$tmp" | _antiscan_span)
    if (( n < RUDIRECT_MIN || n > 100000 || s4 < RUDIRECT_MINADDR || s4 > RUDIRECT_MAX4 )); then
      _rublock_log "${src#https://}: $n сетей, $s4 адресов — не похоже на список РФ"
      why+="${why:+; }$lbl: $n сетей, $s4 адресов — не похоже на список РФ"; continue
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$RUBLOCK_DIR/ru.list" || return 1
    _rublock_set ERROR ""
    _rublock_set UPDATED "$(date +%s)"
    _rublock_set SRC "$lbl"
    _rublock_log "список РФ: $n сетей, $s4 адресов (${src#https://})"
    return 0
  done
  rm -f "$tmp"
  _rublock_fail "список РФ не получен (${why:-нет источников}) — $keep"
}

_rublock_rule() {  # интерфейс → RUBLOCK_RULE
  RUBLOCK_RULE=(-i "$1" -m set --match-set "$RUBLOCK_SET" dst -m addrtype ! --dst-type LOCAL
                -m comment --comment "$RUBLOCK_TAG" -j MARK --set-xmark "$RUBLOCK_MARK")
}

# Без «ip rule show | grep -q»: при pipefail ранний выход grep — SIGPIPE у ip
_rublock_ip_rule_on() { [[ "$(ip rule show 2>/dev/null)" == *"fwmark ${RUBLOCK_MARK} prohibit"* ]]; }

_rublock_rules_up() {
  local dev
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _rublock_rule "$dev"
    iptables -t mangle -C PREROUTING "${RUBLOCK_RULE[@]}" 2>/dev/null \
      || iptables -t mangle -I PREROUTING 1 "${RUBLOCK_RULE[@]}" || return 1
  done
  _rublock_ip_rule_on || ip rule add fwmark "$RUBLOCK_MARK" prohibit priority "$RUBLOCK_PRIO" || return 1
  ip route flush cache 2>/dev/null || true
}

_rublock_rules_down() {
  local dev guard
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _rublock_rule "$dev"; guard=0
    while (( guard++ < 32 )) && iptables -t mangle -D PREROUTING "${RUBLOCK_RULE[@]}" 2>/dev/null; do :; done
  done
  guard=0
  while (( guard++ < 32 )) && ip rule del fwmark "$RUBLOCK_MARK" prohibit priority "$RUBLOCK_PRIO" 2>/dev/null; do :; done
  return 0
}

# Правила на месте: набор, метки для awg0 и wgobf0, правило «prohibit»
rublock_rules_ok() {
  local dev
  ipset list -n "$RUBLOCK_SET" &>/dev/null || return 1
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _rublock_rule "$dev"
    iptables -t mangle -C PREROUTING "${RUBLOCK_RULE[@]}" 2>/dev/null || return 1
  done
  _rublock_ip_rule_on
}

# Собрать набор из сохранённого списка и поставить правила.
_rublock_apply() {
  local d n rc=0
  # Выключили, пока качался список, — правила обратно не ставить
  [[ "$(_rublock_get ON)" == 1 ]] || { rublock_down; return 0; }
  [[ -s "$RUBLOCK_DIR/ru.list" ]] || { _rublock_log "нечего применять: список РФ ещё не скачан"; return 3; }
  d=$(mktemp -d "$RUBLOCK_DIR/.apply.XXXXXX") || return 1
  _antiscan_parse 4 < "$RUBLOCK_DIR/ru.list" | sort -u > "$d/v4"
  : > "$d/none"
  if ! n=$(_antiscan_load "$RUBLOCK_SET" inet "$d/v4" "$d/none"); then
    _rublock_log "ipset: набор не загрузился"; rc=5
  elif ! _rublock_rules_up; then
    _rublock_log "iptables или ip rule: правило не поставилось"; rc=5
  else
    _rublock_set ENTRIES "$n"
    _rublock_log "применено: сетей РФ $n"
  fi
  rm -rf "$d"
  return "$rc"
}

rublock_down() {
  local s
  _rublock_rules_down
  command -v ipset &>/dev/null || return 0
  for s in "$RUBLOCK_SET" "$RUBLOCK_SET-new"; do ipset destroy "$s" 2>/dev/null || true; done
  ip route flush cache 2>/dev/null || true
  return 0
}

# Точка входа службы и таймера (и awg2): apply | update | heal | off.
rublock_run() {
  local mode="${1:-heal}" rc=0 upd
  mkdir -p "$RUBLOCK_DIR" && chmod 700 "$RUBLOCK_DIR"
  exec 9>"$RUBLOCK_DIR/.lock"
  flock -w 180 9 || { _rublock_log "$mode: занято другой операцией"; return 75; }
  if [[ "$mode" == off || "$(_rublock_get ON)" != 1 ]]; then
    rublock_down
    return 0
  fi
  case "$mode" in
    update) _rublock_fetch || true; _rublock_apply || rc=$? ;;
    apply) _rublock_apply || rc=$? ;;
    heal)
      touch "$RUBLOCK_DIR/heal"
      upd=$(_rublock_get UPDATED)
      if (( $(date +%s) - ${upd:-0} > 86400 )); then
        _rublock_fetch || true
        _rublock_apply || rc=$?
      elif ! rublock_rules_ok; then
        _rublock_log "правило пропало — применяю заново"
        _rublock_apply || rc=$?
      fi ;;
    *) echo "использование: ${0##*/} apply|update|heal|off" >&2; return 2 ;;
  esac
  return "$rc"
}

# ── Установка ─────────────────────────────────────────────
_rublock_emit() {
  emit_script "$RUBLOCK_SCRIPT" 'rublock_run "$@"' \
    RUBLOCK_DIR RUBLOCK_CONF RUBLOCK_LOG RUBLOCK_SET RUBLOCK_TAG RUBLOCK_MARK RUBLOCK_PRIO \
    RUDIRECT_SRCS RUDIRECT_MIN RUDIRECT_MINADDR RUDIRECT_MAX4 AWG_IF WGOBF_IF \
    write_file _rublock_get _rublock_set _rublock_log _rublock_fail _antiscan_parse _antiscan_span _antiscan_load \
    _rublock_fetch _rublock_rule _rublock_ip_rule_on _rublock_rules_up _rublock_rules_down rublock_rules_ok \
    _rublock_apply rublock_down rublock_run || return 1
  write_unit "$RUBLOCK_UNIT" <<EOF
[Unit]
Description=AWG Toolza — РФ мимо VPN: клиенты не ходят через сервер в сети России
DefaultDependencies=no
Wants=network-pre.target local-fs.target
After=local-fs.target systemd-modules-load.service
Before=network-pre.target ufw.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RUBLOCK_SCRIPT apply

[Install]
WantedBy=multi-user.target
EOF
  write_unit "${RUBLOCK_TIMER%.timer}.service" <<EOF
[Unit]
Description=AWG Toolza — РФ мимо VPN: правила на месте, список раз в сутки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUBLOCK_SCRIPT heal
EOF
  write_unit "$RUBLOCK_TIMER" <<'EOF'
[Unit]
Description=AWG Toolza — РФ мимо VPN: проверка раз в час

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
}

# Сервер в России: российские сайты и так видят российский адрес — режим не нужен
_rublock_home_text() {
  echo "Сервер в России: российские сайты и так видят российский адрес. «РФ мимо VPN» нужен зарубежному серверу; серверу в России — «РФ напрямую»"
}

rublock_enable() {
  local rc=0
  server_exists || { err "Сервер не создан"; return 1; }
  if rudirect_on; then
    err "Включено «РФ напрямую» — это противоположный режим: там сети России идут мимо туннеля прямо с сервера. Сначала выключи его"
    return 1
  fi
  need_cmds ipset:ipset flock:util-linux || return 1
  _rublock_set ON 1
  _rublock_emit || { _rublock_set ON 0; err "Не удалось записать службу"; return 1; }
  info "Скачиваю и проверяю список сетей России..."
  "$RUBLOCK_SCRIPT" update || rc=$?
  if (( rc )); then
    _rublock_set ON 0
    "$RUBLOCK_SCRIPT" off &>/dev/null || true
    case $rc in
      3) err "Список сетей России не получен: $(_rublock_get ERROR)" ;;
      75) err "Занято другой операцией — повтори через минуту" ;;
      *) err "Не удалось поставить правила (код $rc) — журнал: $RUBLOCK_LOG" ;;
    esac
    return 1
  fi
  systemctl enable "$RUBLOCK_UNIT" &>/dev/null || true
  systemctl enable --now "$RUBLOCK_TIMER" &>/dev/null || true
  log_info "РФ мимо VPN: включено"
  ok "РФ мимо VPN включено: $(rublock_summary)"
  [[ "$(server_country)" == RU ]] && warn "$(_rublock_home_text)"
  [[ -n "$(_rublock_get ERROR)" ]] && warn "$(_rublock_get ERROR)"
  return 0
}

rublock_disable() {
  local held=0
  _rublock_set ON 0
  remove_unit "$RUBLOCK_TIMER" "${RUBLOCK_TIMER%.timer}.service" "$RUBLOCK_UNIT"
  # Замок прохода таймера: проход, уже увидевший ON=1, иначе поставил бы правила
  # обратно после нас. Не дольше 20 с — качающий проход сам увидит ON=0
  mkdir -p "$RUBLOCK_DIR" && chmod 700 "$RUBLOCK_DIR"
  exec 9>"$RUBLOCK_DIR/.lock"
  flock -w 20 9 && held=1
  rublock_down
  (( held )) || _rublock_log "выключение: замок занят дольше 20 с — снято без него"
  exec 9>&-
  log_info "РФ мимо VPN: выключено"
  ok "Сети России снова доступны клиентам через VPN — правила и набор сняты"
}

rublock_update() {
  rublock_on || { err "РФ мимо VPN — выключено"; return 1; }
  _rublock_emit || return 1
  "$RUBLOCK_SCRIPT" update || { err "Не удалось применить список — журнал: $RUBLOCK_LOG"; return 1; }
  if [[ -n "$(_rublock_get ERROR)" ]]; then warn "$(_rublock_get ERROR)"; fi
  ok "Список обновлён: $(rublock_summary)"
}

# Отказано пакетам в сети России с установки правил (перезагрузка сбрасывает)
rublock_blocked() {
  iptables-save -c -t mangle 2>/dev/null \
    | awk -v tag="$RUBLOCK_TAG" 'index($0, "--comment " tag) && /^\[/ {
        split(substr($1, 2), c, ":"); n += c[1] } END { printf "%.0f\n", n }'
}

rublock_summary() { echo "сетей России $(_rublock_get ENTRIES || true)"; }

# ── Меню ──────────────────────────────────────────────────
_rublock_show() {
  local upd err
  hdr "РФ мимо VPN"
  echo -e "  ${D}Клиенты VPN не ходят через сервер в сети России. Российские сайты и приложения"
  echo -e "  не видят адрес сервера и не могут сдать его как VPN — для зарубежного сервера."
  echo -e "  Российские сервисы у клиентов через VPN сразу получат отказ — в приложении VPN"
  echo -e "  их пускают мимо туннеля.${N}"
  echo ""
  if rublock_on; then
    if rublock_rules_ok; then echo -e "  Состояние : ${G}● включено${N} — $(rublock_summary)"
    else echo -e "  Состояние : ${Y}▲ включено, правило не на месте${N} — вернёт таймер или «Обновить список»"; fi
    echo -e "  Отказано  : ${W}$(rublock_blocked)${N} ${D}пакетов в сети России (сбрасывается при перезагрузке)${N}"
    [[ "$(server_country)" == RU ]] && echo -e "  ${Y}▲ $(_rublock_home_text)${N}"
  else
    echo -e "  Состояние : ${D}○ выключено${N}"
    rudirect_on && echo -e "  ${D}Сейчас включено «РФ напрямую» — противоположный режим${N}"
  fi
  upd=$(_rublock_get UPDATED)
  [[ -n "$upd" ]] && echo -e "  Список    : обновлён $(date -d "@$upd" '+%d.%m.%Y %H:%M' 2>/dev/null)"
  err=$(_rublock_get ERROR)
  [[ -n "$err" ]] && echo -e "  ${Y}▲ $err${N}"
  return 0
}

do_rublock_menu() {
  local c
  while true; do
    echo ""
    _rublock_show
    echo ""
    if rublock_on; then echo -e "  ${C}1)${N} Выключить"; else echo -e "  ${C}1)${N} Включить"; fi
    echo -e "  ${C}2)${N} Обновить список сейчас"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) if rublock_on; then rublock_disable
         else
           echo -e "  ${Y}Российские сайты и приложения у клиентов через VPN перестанут открываться —"
           echo -e "  в приложении VPN их надо пустить мимо туннеля.${N}"
           ask_yes "  Включить? [y/N]: " n && { rublock_enable || true; }
         fi ;;
      2) rublock_update || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# Таймер молчит дольше трёх часов (сброшен, заглох) — перезапустить
rublock_watchdog() {
  local age
  rublock_on || return 0
  [[ -f "$RUBLOCK_DIR/heal" ]] || return 0
  age=$(( $(date +%s) - $(stat -c %Y "$RUBLOCK_DIR/heal" 2>/dev/null || echo 0) ))
  (( age < 10800 )) && return 0
  touch "$RUBLOCK_DIR/heal"
  timer_heal "$RUBLOCK_TIMER"
  systemctl start --no-block "${RUBLOCK_TIMER%.timer}.service" &>/dev/null || true
}

rublock_remove() {
  remove_unit "$RUBLOCK_TIMER" "${RUBLOCK_TIMER%.timer}.service" "$RUBLOCK_UNIT"
  rublock_down
  rm -rf "$RUBLOCK_DIR" "$RUBLOCK_SCRIPT" "$RUBLOCK_LOG"
}
