# VK и Max мимо VPN: трафик клиентов VPN в сети VK (ВКонтакте, Max,
# Одноклассники и другие сервисы VK) на сервере отбрасывается. Приложения VK
# на телефоне с VPN не видят адрес сервера и не могут сдать его как VPN.
# Сервисы VK через VPN у клиентов не откроются — их пускают мимо туннеля.
#
# Список — публичный (C24Be/AS_Network_List, blacklist-vk.txt). Проверка та
# же, что у антисканера (_antiscan_parse): частные и служебные сети и слишком
# широкие подсети отбрасываются, оборванный или раздутый ответ прежний список
# не заменяет.
#
# Как устроено: наборы ipset hash:net и DROP в mangle PREROUTING — раньше
# FORWARD, где PostUp сервера ставит свой ACCEPT первым (см. dns.sh). Ловит
# всех, чей трафик сервер пересылает: awg0, обфускатор, контейнеры Amnezia,
# клиентов, идущих через WARP, Xray или каскад. Пакеты к адресам самого
# сервера не трогаются (addrtype LOCAL) — сервер в сети VK остаётся
# доступным; свой трафик сервера (OUTPUT) — тоже.
#
# Служба awg2-vkblock.service ставит наборы и правило при загрузке (раньше
# UFW и netfilter-persistent), таймер раз в час возвращает правило, если его
# сбросили, и раз в сутки обновляет список. Без сети — на сохранённом списке.

_vkblock_get() {  # КЛЮЧ — значение из vkblock.conf (файл не исполняется)
  sed -n "s/^$1=//p" "$VKBLOCK_CONF" 2>/dev/null | tail -1
}

_vkblock_set() {  # КЛЮЧ ЗНАЧЕНИЕ
  local v="${2//[$'\n\r']/ }"
  mkdir -p "$VKBLOCK_DIR" && chmod 700 "$VKBLOCK_DIR"
  { grep -v "^$1=" "$VKBLOCK_CONF" 2>/dev/null; printf '%s=%s\n' "$1" "$v"; } | write_file "$VKBLOCK_CONF" 600
}

_vkblock_log() { mkdir -p "$(dirname "$VKBLOCK_LOG")"; echo "[$(date '+%F %T')] $*" >> "$VKBLOCK_LOG"; }

_vkblock_fail() { _vkblock_set ERROR "$1"; _vkblock_log "$1"; return 1; }

vkblock_on() { [[ "$(_vkblock_get ON)" == 1 ]]; }

# Скачать список. Оборванный, пустой или слишком широкий ответ прежний не
# заменяет; ошибка — в ERROR, время удачного обновления — в UPDATED.
_vkblock_fetch() {
  local tmp n s4 s6 keep="оставлен прежний список"
  mkdir -p "$VKBLOCK_DIR" && chmod 700 "$VKBLOCK_DIR"
  [[ -s "$VKBLOCK_DIR/vk.list" ]] || keep="список не принят"
  tmp=$(mktemp "$VKBLOCK_DIR/.dl.XXXXXX") || return 1
  if ! curl -fsS --proto '=https' --max-time 40 --max-filesize 2000000 -o "$tmp" "$VKBLOCK_SRC" 2>/dev/null; then
    rm -f "$tmp"; _vkblock_fail "список не скачался"; return 1
  fi
  read -r n s4 s6 < <({ _antiscan_parse 4 < "$tmp"; _antiscan_parse 6 < "$tmp"; } | _antiscan_span)
  if (( n < VKBLOCK_MIN || n > 20000 )); then
    rm -f "$tmp"; _vkblock_fail "в ответе $n записей — $keep"; return 1
  fi
  if (( s4 > VKBLOCK_MAX4 || s6 > VKBLOCK_MAX6 )); then
    rm -f "$tmp"; _vkblock_fail "слишком широкий охват (IPv4 $s4 адресов, IPv6 $s6 сетей /32) — $keep"; return 1
  fi
  chmod 600 "$tmp" && mv -f "$tmp" "$VKBLOCK_DIR/vk.list" || return 1
  _vkblock_set ERROR ""
  _vkblock_set UPDATED "$(date +%s)"
}

_vkblock_rule() {  # набор → VKBLOCK_RULE
  VKBLOCK_RULE=(-m set --match-set "$1" dst -m addrtype ! --dst-type LOCAL -m comment --comment "$VKBLOCK_TAG" -j DROP)
}

_vkblock_rule_up() {  # iptables|ip6tables набор
  _vkblock_rule "$2"
  "$1" -t mangle -C PREROUTING "${VKBLOCK_RULE[@]}" 2>/dev/null || "$1" -t mangle -I PREROUTING 1 "${VKBLOCK_RULE[@]}"
}

_vkblock_rule_down() {  # iptables|ip6tables набор
  local guard=0
  command -v "$1" &>/dev/null || return 0
  _vkblock_rule "$2"
  while (( guard++ < 32 )) && "$1" -t mangle -D PREROUTING "${VKBLOCK_RULE[@]}" 2>/dev/null; do :; done
  return 0
}

# Правила на месте: у каждого набора — своё правило
vkblock_rules_ok() {
  ipset list -n "$VKBLOCK_SET" &>/dev/null || return 1
  _vkblock_rule "$VKBLOCK_SET"
  iptables -t mangle -C PREROUTING "${VKBLOCK_RULE[@]}" 2>/dev/null || return 1
  ipset list -n "$VKBLOCK_SET6" &>/dev/null || return 0
  _vkblock_rule "$VKBLOCK_SET6"
  ip6tables -t mangle -C PREROUTING "${VKBLOCK_RULE[@]}" 2>/dev/null
}

# Собрать наборы из сохранённого списка и поставить правила.
_vkblock_apply() {
  local d n4 n6=0 rc=0
  # Выключили, пока качался список (выключение ждёт замок не дольше 20 с), —
  # правило обратно не ставить
  [[ "$(_vkblock_get ON)" == 1 ]] || { vkblock_down; return 0; }
  [[ -s "$VKBLOCK_DIR/vk.list" ]] || { _vkblock_log "нечего применять: список ещё не скачан"; return 3; }
  d=$(mktemp -d "$VKBLOCK_DIR/.apply.XXXXXX") || return 1
  _antiscan_parse 4 < "$VKBLOCK_DIR/vk.list" | sort -u > "$d/v4"
  _antiscan_parse 6 < "$VKBLOCK_DIR/vk.list" | sort -u > "$d/v6"
  : > "$d/none"
  if ! n4=$(_antiscan_load "$VKBLOCK_SET" inet "$d/v4" "$d/none"); then
    _vkblock_log "ipset: набор IPv4 не загрузился"; rc=5
  elif ! _vkblock_rule_up iptables "$VKBLOCK_SET"; then
    _vkblock_log "iptables: правило не поставилось"; rc=5
  else
    if [[ -s "$d/v6" ]] && command -v ip6tables &>/dev/null \
        && n6=$(_antiscan_load "$VKBLOCK_SET6" inet6 "$d/v6" "$d/none") \
        && _vkblock_rule_up ip6tables "$VKBLOCK_SET6"; then
      :
    else
      n6=0
      _vkblock_rule_down ip6tables "$VKBLOCK_SET6"
      ipset destroy "$VKBLOCK_SET6" 2>/dev/null || true
    fi
    _vkblock_set ENTRIES "$n4 $n6"
    _vkblock_log "применено: IPv4 $n4, IPv6 $n6"
  fi
  rm -rf "$d"
  return "$rc"
}

vkblock_down() {
  local s
  _vkblock_rule_down iptables "$VKBLOCK_SET"
  _vkblock_rule_down ip6tables "$VKBLOCK_SET6"
  command -v ipset &>/dev/null || return 0
  # и временные наборы замены — остаются, если загрузку прервали
  for s in "$VKBLOCK_SET" "$VKBLOCK_SET6" "$VKBLOCK_SET-new" "$VKBLOCK_SET6-new"; do
    ipset destroy "$s" 2>/dev/null || true
  done
  return 0
}

# Точка входа службы и таймера (и awg2): apply | update | heal | off.
vkblock_run() {
  local mode="${1:-heal}" rc=0 upd
  mkdir -p "$VKBLOCK_DIR" && chmod 700 "$VKBLOCK_DIR"
  exec 9>"$VKBLOCK_DIR/.lock"
  flock -w 180 9 || { _vkblock_log "$mode: занято другой операцией"; return 75; }
  if [[ "$mode" == off || "$(_vkblock_get ON)" != 1 ]]; then
    vkblock_down
    return 0
  fi
  case "$mode" in
    update) _vkblock_fetch || true; _vkblock_apply || rc=$? ;;
    apply) _vkblock_apply || rc=$? ;;
    heal)
      touch "$VKBLOCK_DIR/heal"
      upd=$(_vkblock_get UPDATED)
      if (( $(date +%s) - ${upd:-0} > 86400 )); then
        _vkblock_fetch || true
        _vkblock_apply || rc=$?
      elif ! vkblock_rules_ok; then
        _vkblock_log "правило пропало — применяю заново"
        _vkblock_apply || rc=$?
      fi ;;
    *) echo "использование: ${0##*/} apply|update|heal|off" >&2; return 2 ;;
  esac
  return "$rc"
}

# ── Установка ─────────────────────────────────────────────
_vkblock_emit() {
  emit_script "$VKBLOCK_SCRIPT" 'vkblock_run "$@"' \
    VKBLOCK_DIR VKBLOCK_CONF VKBLOCK_LOG VKBLOCK_SET VKBLOCK_SET6 VKBLOCK_TAG VKBLOCK_SRC \
    VKBLOCK_MIN VKBLOCK_MAX4 VKBLOCK_MAX6 \
    write_file _vkblock_get _vkblock_set _vkblock_log _vkblock_fail _antiscan_parse _antiscan_span _antiscan_load \
    _vkblock_fetch _vkblock_rule _vkblock_rule_up _vkblock_rule_down vkblock_rules_ok _vkblock_apply vkblock_down \
    vkblock_run || return 1
  # Раньше UFW и netfilter-persistent: восстановление iptables-persistent найдёт набор
  write_unit "$VKBLOCK_UNIT" <<EOF
[Unit]
Description=AWG Toolza — VK и Max мимо VPN: клиенты не ходят через сервер в сети VK
DefaultDependencies=no
Wants=network-pre.target local-fs.target
After=local-fs.target systemd-modules-load.service
Before=network-pre.target ufw.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$VKBLOCK_SCRIPT apply

[Install]
WantedBy=multi-user.target
EOF
  write_unit "${VKBLOCK_TIMER%.timer}.service" <<EOF
[Unit]
Description=AWG Toolza — VK и Max мимо VPN: правило на месте, список раз в сутки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$VKBLOCK_SCRIPT heal
EOF
  write_unit "$VKBLOCK_TIMER" <<'EOF'
[Unit]
Description=AWG Toolza — VK и Max мимо VPN: проверка раз в час

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
}

vkblock_enable() {
  local rc=0
  need_cmds ipset:ipset flock:util-linux || return 1
  _vkblock_set ON 1
  _vkblock_emit || { err "Не удалось записать службу"; return 1; }
  info "Скачиваю и проверяю список сетей VK..."
  "$VKBLOCK_SCRIPT" update || rc=$?
  if (( rc )); then
    _vkblock_set ON 0
    "$VKBLOCK_SCRIPT" off &>/dev/null || true
    case $rc in
      3) err "Список сетей VK не получен: $(_vkblock_get ERROR)" ;;
      75) err "Занято другой операцией — повтори через минуту" ;;
      *) err "Не удалось применить правило (код $rc) — журнал: $VKBLOCK_LOG" ;;
    esac
    return 1
  fi
  systemctl enable "$VKBLOCK_UNIT" &>/dev/null || true
  systemctl enable --now "$VKBLOCK_TIMER" &>/dev/null || true
  log_info "VK и Max мимо VPN: включено"
  ok "VK и Max мимо VPN включено: $(vkblock_summary)"
  [[ -n "$(_vkblock_get ERROR)" ]] && warn "$(_vkblock_get ERROR)"
  return 0
}

vkblock_disable() {
  local held=0
  _vkblock_set ON 0
  remove_unit "$VKBLOCK_TIMER" "${VKBLOCK_TIMER%.timer}.service" "$VKBLOCK_UNIT"
  # Замок прохода таймера: проход, уже увидевший ON=1, иначе поставил бы правило
  # обратно после нас. Не дольше 20 с — качающий проход сам увидит ON=0 перед применением
  mkdir -p "$VKBLOCK_DIR" && chmod 700 "$VKBLOCK_DIR"
  exec 9>"$VKBLOCK_DIR/.lock"
  flock -w 20 9 && held=1
  vkblock_down
  (( held )) || _vkblock_log "выключение: замок занят дольше 20 с — снято без него"
  exec 9>&-
  log_info "VK и Max мимо VPN: выключено"
  ok "VK и Max снова идут через VPN — правило и наборы сняты"
}

vkblock_update() {
  vkblock_on || { err "VK и Max мимо VPN — выключено"; return 1; }
  _vkblock_emit || return 1
  "$VKBLOCK_SCRIPT" update || { err "Не удалось применить список — журнал: $VKBLOCK_LOG"; return 1; }
  if [[ -n "$(_vkblock_get ERROR)" ]]; then warn "$(_vkblock_get ERROR)"; fi
  ok "Список обновлён: $(vkblock_summary)"
}

# Отброшено пакетов в сети VK с установки правила (перезагрузка сбрасывает)
vkblock_dropped() {
  { iptables-save -c -t mangle 2>/dev/null; ip6tables-save -c -t mangle 2>/dev/null; } \
    | awk -v tag="$VKBLOCK_TAG" 'index($0, "--comment " tag) && /^\[/ {
        split(substr($1, 2), c, ":"); n += c[1] } END { printf "%.0f\n", n }'
}

vkblock_summary() {
  local e
  read -r -a e <<< "$(_vkblock_get ENTRIES)"
  echo "подсетей IPv4 ${e[0]:-0}, IPv6 ${e[1]:-0}"
}

# ── Меню ──────────────────────────────────────────────────
_vkblock_show() {
  local upd err
  hdr "VK и Max мимо VPN"
  echo -e "  ${D}Клиенты VPN не ходят через сервер в сети VK: ВКонтакте, Max, Одноклассники."
  echo -e "  Приложения VK не видят адрес сервера и не могут сдать его как VPN. Сервисы VK"
  echo -e "  у клиентов через VPN не откроются — их пускают мимо туннеля.${N}"
  echo ""
  if vkblock_on; then
    if vkblock_rules_ok; then echo -e "  Состояние : ${G}● включено${N} — $(vkblock_summary)"
    else echo -e "  Состояние : ${Y}▲ включено, правило не на месте${N} — вернёт таймер или «Обновить список»"; fi
    echo -e "  Отбито    : ${W}$(vkblock_dropped)${N} ${D}пакетов в сети VK (сбрасывается при перезагрузке)${N}"
  else
    echo -e "  Состояние : ${D}○ выключено${N}"
  fi
  upd=$(_vkblock_get UPDATED)
  [[ -n "$upd" ]] && echo -e "  Список    : обновлён $(date -d "@$upd" '+%d.%m.%Y %H:%M' 2>/dev/null)"
  err=$(_vkblock_get ERROR)
  [[ -n "$err" ]] && echo -e "  ${Y}▲ $err${N}"
  return 0
}

do_vkblock_menu() {
  local c
  while true; do
    echo ""
    _vkblock_show
    echo ""
    if vkblock_on; then echo -e "  ${C}1)${N} Выключить"; else echo -e "  ${C}1)${N} Включить"; fi
    echo -e "  ${C}2)${N} Обновить список сейчас"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) if vkblock_on; then vkblock_disable
         else
           echo -e "  ${Y}ВКонтакте, Max и другие сервисы VK у клиентов через VPN перестанут открываться —"
           echo -e "  в приложении VPN их надо пустить мимо туннеля.${N}"
           ask_yes "  Включить? [y/N]: " n && { vkblock_enable || true; }
         fi ;;
      2) vkblock_update || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# Таймер молчит дольше трёх часов (сброшен, заглох) — перезапустить
vkblock_watchdog() {
  local age
  vkblock_on || return 0
  [[ -f "$VKBLOCK_DIR/heal" ]] || return 0
  age=$(( $(date +%s) - $(stat -c %Y "$VKBLOCK_DIR/heal" 2>/dev/null || echo 0) ))
  (( age < 10800 )) && return 0
  touch "$VKBLOCK_DIR/heal"
  timer_heal "$VKBLOCK_TIMER"
  systemctl start --no-block "${VKBLOCK_TIMER%.timer}.service" &>/dev/null || true
}

vkblock_remove() {
  remove_unit "$VKBLOCK_TIMER" "${VKBLOCK_TIMER%.timer}.service" "$VKBLOCK_UNIT"
  vkblock_down
  rm -rf "$VKBLOCK_DIR" "$VKBLOCK_SCRIPT" "$VKBLOCK_LOG"
}
