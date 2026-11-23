# Почта: клиенты VPN (awg0 и WG + обфускатор) не открывают соединения на
# порт 25 — SMTP между почтовыми серверами. Через сервер не уйдёт спам, и
# хостер не заблокирует сервер за рассылку. Почтовые приложения отправляют
# письма через 465 и 587 — они работают как раньше. Соединения к адресам самого
# сервера и свой трафик сервера не трогаются.
#
# Как устроено: DROP в mangle PREROUTING по входящему интерфейсу — раньше
# FORWARD, где PostUp сервера ставит свой ACCEPT первым (см. dns.sh). Правило
# на wgobf0 стоит и без интерфейса. Служба ставит правила при загрузке (раньше
# UFW и netfilter-persistent), таймер раз в час возвращает, если их сбросили.

smtpblock_on() { [[ -f "$SMTPBLOCK_FLAG" ]]; }

_smtpblock_rule() {  # интерфейс → SMTPBLOCK_RULE
  SMTPBLOCK_RULE=(-i "$1" -p tcp --dport 25 -m addrtype ! --dst-type LOCAL
                  -m comment --comment "$SMTPBLOCK_TAG" -j DROP)
}

# Правила на месте (IPv4: у клиентов внутри туннеля только он)
smtpblock_rules_ok() {
  local dev
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _smtpblock_rule "$dev"
    iptables -t mangle -C PREROUTING "${SMTPBLOCK_RULE[@]}" 2>/dev/null || return 1
  done
}

# IPv6 — тем же правилом, если ядро умеет: появится у клиентов адрес IPv6 —
# порт 25 и по нему закрыт. Не вышло — не ошибка, IPv6 у клиентов нет.
smtpblock_up() {
  local dev
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _smtpblock_rule "$dev"
    iptables -t mangle -C PREROUTING "${SMTPBLOCK_RULE[@]}" 2>/dev/null \
      || iptables -t mangle -I PREROUTING 1 "${SMTPBLOCK_RULE[@]}" || return 1
    if command -v ip6tables &>/dev/null; then
      ip6tables -t mangle -C PREROUTING "${SMTPBLOCK_RULE[@]}" 2>/dev/null \
        || ip6tables -t mangle -I PREROUTING 1 "${SMTPBLOCK_RULE[@]}" 2>/dev/null || true
    fi
  done
}

smtpblock_down() {
  local dev t guard
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _smtpblock_rule "$dev"
    for t in iptables ip6tables; do
      command -v "$t" &>/dev/null || continue
      guard=0
      while (( guard++ < 32 )) && "$t" -t mangle -D PREROUTING "${SMTPBLOCK_RULE[@]}" 2>/dev/null; do :; done
    done
  done
  return 0
}

# Точка входа службы и таймера: apply | heal | off. Выключено — правил нет.
smtpblock_run() {
  case "${1:-heal}" in
    off) smtpblock_down ;;
    apply) if smtpblock_on; then smtpblock_up; else smtpblock_down; fi ;;
    heal)
      [[ -d "${SMTPBLOCK_FLAG%/*}" ]] && touch "${SMTPBLOCK_FLAG%/*}/.smtpblock-heal" 2>/dev/null
      if ! smtpblock_on; then smtpblock_down
      elif ! smtpblock_rules_ok; then smtpblock_up; fi ;;
    *) echo "использование: ${0##*/} apply|heal|off" >&2; return 2 ;;
  esac
}

# Отбито соединений на порт 25 с установки правил (перезагрузка сбрасывает)
smtpblock_dropped() {
  { iptables-save -c -t mangle 2>/dev/null; ip6tables-save -c -t mangle 2>/dev/null; } \
    | awk -v tag="$SMTPBLOCK_TAG" 'index($0, "--comment " tag) && /^\[/ {
        split(substr($1, 2), c, ":"); n += c[1] } END { printf "%.0f\n", n }'
}

# ── Установка ─────────────────────────────────────────────
_smtpblock_emit() {
  emit_script "$SMTPBLOCK_SCRIPT" 'smtpblock_run "$@"' SMTPBLOCK_FLAG SMTPBLOCK_TAG AWG_IF WGOBF_IF \
    smtpblock_on _smtpblock_rule smtpblock_rules_ok smtpblock_up smtpblock_down smtpblock_run || return 1
  write_unit "$SMTPBLOCK_UNIT" <<EOF
[Unit]
Description=AWG Toolza — почта: клиенты VPN не отправляют через сервер на порт 25
DefaultDependencies=no
Wants=network-pre.target local-fs.target
After=local-fs.target systemd-modules-load.service
Before=network-pre.target ufw.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SMTPBLOCK_SCRIPT apply

[Install]
WantedBy=multi-user.target
EOF
  write_unit "${SMTPBLOCK_TIMER%.timer}.service" <<EOF
[Unit]
Description=AWG Toolza — почта: правила на месте

[Service]
Type=oneshot
ExecStart=$SMTPBLOCK_SCRIPT heal
EOF
  write_unit "$SMTPBLOCK_TIMER" <<'EOF'
[Unit]
Description=AWG Toolza — почта: проверка правил раз в час

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
}

smtpblock_enable() {
  mkdir -p "${SMTPBLOCK_FLAG%/*}"
  date +%s | write_file "$SMTPBLOCK_FLAG" 600
  _smtpblock_emit || { rm -f "$SMTPBLOCK_FLAG"; err "Не удалось записать службу"; return 1; }
  if ! "$SMTPBLOCK_SCRIPT" apply || ! smtpblock_rules_ok; then
    rm -f "$SMTPBLOCK_FLAG"
    "$SMTPBLOCK_SCRIPT" off &>/dev/null || true
    err "Правила не поставились — iptables: $(iptables -V 2>/dev/null || echo нет)"
    return 1
  fi
  systemctl enable "$SMTPBLOCK_UNIT" &>/dev/null || true
  systemctl enable --now "$SMTPBLOCK_TIMER" &>/dev/null || true
  log_info "почта (порт 25): закрыта для клиентов"
  ok "Порт 25 закрыт для клиентов VPN: спам через сервер не уйдёт. Почтовые приложения работают через 465 и 587"
}

smtpblock_disable() {
  rm -f "$SMTPBLOCK_FLAG"
  remove_unit "$SMTPBLOCK_TIMER" "${SMTPBLOCK_TIMER%.timer}.service" "$SMTPBLOCK_UNIT"
  smtpblock_down
  log_info "почта (порт 25): открыта для клиентов"
  ok "Порт 25 снова открыт для клиентов VPN"
}

smtpblock_status() {
  if ! smtpblock_on; then echo -e "  Состояние : ${D}○ выключено — клиенты могут слать почту на порт 25${N}"
  elif smtpblock_rules_ok; then echo -e "  Состояние : ${G}● порт 25 закрыт для клиентов${N}"
  else echo -e "  Состояние : ${Y}▲ включено, правила не на месте${N} — вернёт таймер или «Выключить» и «Включить»"; fi
  smtpblock_on && echo -e "  Отбито    : ${W}$(smtpblock_dropped)${N} ${D}попыток на порт 25 (сбрасывается при перезагрузке)${N}"
  return 0
}

do_smtpblock_menu() {
  local c
  while true; do
    echo ""
    hdr "Почта: порт 25"
    echo -e "  ${D}Клиенты VPN не отправляют почту через сервер на порт 25 — спам с сервера не уйдёт,"
    echo -e "  хостер не заблокирует сервер. Почтовые приложения шлют через 465 и 587 — работают.${N}"
    echo ""
    smtpblock_status
    echo ""
    if smtpblock_on; then echo -e "  ${C}1)${N} Открыть порт 25"; else echo -e "  ${C}1)${N} Закрыть порт 25"; fi
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-1]: ${N}" 0 1 0
    case "$c" in
      1) if smtpblock_on; then smtpblock_disable; else smtpblock_enable || true; fi ;;
      0) return 0 ;;
    esac
    pause
  done
}

# Таймер молчит дольше трёх часов (сброшен, заглох) — перезапустить
smtpblock_watchdog() {
  local f="${SMTPBLOCK_FLAG%/*}/.smtpblock-heal" age
  smtpblock_on || return 0
  [[ -f "$f" ]] || return 0
  age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
  (( age < 10800 )) && return 0
  touch "$f"
  timer_heal "$SMTPBLOCK_TIMER"
  systemctl start --no-block "${SMTPBLOCK_TIMER%.timer}.service" &>/dev/null || true
}

smtpblock_remove() {
  remove_unit "$SMTPBLOCK_TIMER" "${SMTPBLOCK_TIMER%.timer}.service" "$SMTPBLOCK_UNIT"
  smtpblock_down
  rm -f "$SMTPBLOCK_FLAG" "${SMTPBLOCK_FLAG%/*}/.smtpblock-heal" "$SMTPBLOCK_SCRIPT"
}
