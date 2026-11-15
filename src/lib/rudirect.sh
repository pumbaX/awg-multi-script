# РФ напрямую для всех туннелей: клиенты, уведённые в туннель (WARP, Xray,
# tun2socks, exit-ноды), ходят к сетям России мимо него — прямо с сервера.
# Полезно, когда сервер в России, а выход — за границей: российские сайты и
# банки видят российский адрес, а выход не тратится на них.
#
# Как устроено: набор ipset сетей РФ плюс свои адреса «всегда напрямую»,
# минус «всегда через туннель» (записи nomatch). Пакеты клиентов (awg0,
# wgobf0) к этим сетям помечаются в mangle PREROUTING, а правило ip rule
# с приоритетом 90 — раньше правил туннелей (100-249) — отправляет помеченные
# в main: туда же, куда идут клиенты без туннеля. Свой трафик сервера и
# пакеты к его адресам не трогаются. У Xray своё «РФ напрямую» (по доменам и
# geoip) — оно работает вместе с этим.
#
# Список — ipverse/rir-ip (по данным RIPE), запасной — ipdeny. Проверка — как
# у антисканера, плюс границы под Россию (RUDIRECT_MIN и др.): не прошёл —
# остаётся прежний. Служба ставит набор и правила при загрузке, таймер раз в
# час лечит их и перечитывает домены своих списков, раз в сутки обновляет
# список РФ. Без сети — на сохранённом.

_rud_get() { sed -n "s/^$1=//p" "$RUDIRECT_CONF" 2>/dev/null | tail -1; }

_rud_set() {  # КЛЮЧ ЗНАЧЕНИЕ
  local v="${2//[$'\n\r']/ }"
  mkdir -p "$RUDIRECT_DIR" && chmod 700 "$RUDIRECT_DIR"
  { grep -v "^$1=" "$RUDIRECT_CONF" 2>/dev/null; printf '%s=%s\n' "$1" "$v"; } | write_file "$RUDIRECT_CONF" 600
}

_rud_log() { mkdir -p "$(dirname "$RUDIRECT_LOG")"; echo "[$(date '+%F %T')] $*" >> "$RUDIRECT_LOG"; }

_rud_fail() { _rud_set ERROR "$1"; _rud_log "$1"; return 1; }

rudirect_on() { [[ "$(_rud_get ON)" == 1 ]]; }

# «Telegram напрямую»: подсети Telegram — в тот же набор, что и сети России.
# Нужно, когда выход туннеля Telegram не пропускает (WARP с сервера в России
# выходит в российской точке Cloudflare): у клиентов в туннеле Telegram висит
# на «Соединение…», а с адреса сервера работает.
rudirect_tg_on() { [[ "$(_rud_get TG)" == 1 ]]; }

# Сервер не в России: «РФ напрямую» покажет российским сайтам и приложениям
# адрес, к которому подключаются клиенты, — зарубежные адреса, по наблюдениям
# осени 2026, блокируют как раз за это. Функция задумана для сервера в России.
# Страна не определена — молчим: не гадаем.
rudirect_abroad() {  # → код страны, если сервер не в России
  local c
  c=$(server_country)
  [[ -n "$c" && "$c" != RU ]] && echo "$c"
}
_rud_abroad_text() {  # код страны
  echo "Сервер не в России ($1): российские сайты и приложения увидят адрес сервера, к которому подключаются клиенты, — зарубежные адреса блокируют как раз за это. «РФ напрямую» — для сервера в России"
}
_rud_tg_nets() { tr ' ' '\n' <<< "$RUDIRECT_TG_NETS" | _antiscan_parse 4; }

# Скачать список РФ: по очереди из источников, первый прошедший проверку.
_rud_fetch() {
  local tmp src lbl n s4 why="" keep="оставлен прежний список"
  mkdir -p "$RUDIRECT_DIR" && chmod 700 "$RUDIRECT_DIR"
  [[ -s "$RUDIRECT_DIR/ru.list" ]] || keep="список не принят"
  tmp=$(mktemp "$RUDIRECT_DIR/.dl.XXXXXX") || return 1
  for src in $RUDIRECT_SRCS; do
    # Подпись источника: ipverse (GitHub), ipdeny.com
    lbl="${src#https://}"
    if [[ "$lbl" == raw.githubusercontent.com/* ]]; then lbl="${lbl#*/}"; lbl="${lbl%%/*}"
    else lbl="${lbl%%/*}"; lbl="${lbl#www.}"; fi
    if ! curl -fsS --proto '=https' --max-time 60 --max-filesize 5000000 -o "$tmp" "$src" 2>/dev/null; then
      _rud_log "${src#https://}: не скачался"; why+="${why:+; }$lbl: не скачался"; continue
    fi
    read -r n s4 _ < <(_antiscan_parse 4 < "$tmp" | _antiscan_span)
    if (( n < RUDIRECT_MIN || n > 100000 || s4 < RUDIRECT_MINADDR || s4 > RUDIRECT_MAX4 )); then
      _rud_log "${src#https://}: $n сетей, $s4 адресов — не похоже на список РФ"
      why+="${why:+; }$lbl: $n сетей, $s4 адресов — не похоже на список РФ"; continue
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$RUDIRECT_DIR/ru.list" || return 1
    _rud_set ERROR ""
    _rud_set UPDATED "$(date +%s)"
    _rud_set SRC "$lbl"
    _rud_log "список РФ: $n сетей, $s4 адресов (${src#https://})"
    return 0
  done
  rm -f "$tmp"
  _rud_fail "список РФ не получен (${why:-нет источников}) — $keep"
}

# Свои списки: строка — IPv4, подсеть или домен (# — комментарий). Домены
# разрешаются в адреса при каждом применении — таймер перечитывает их раз в час.
_rud_user_file() { echo "$RUDIRECT_USER/$1.list"; }   # direct|tunnel

_rud_user_cidrs() {  # direct|tunnel → подсети
  local f line h
  f=$(_rud_user_file "$1")
  [[ -s "$f" ]] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^[0-9./]+$ ]]; then echo "$line"
    else
      for h in $(getent ahostsv4 "$line" 2>/dev/null | awk '{print $1}' | sort -u); do echo "$h/32"; done
    fi
  done < "$f" | _antiscan_parse 4
}

_rud_has_domains() { grep -hvE '^[[:space:]]*(#|$)|^[[:space:]]*[0-9./]+[[:space:]]*(#.*)?$' "$(_rud_user_file direct)" "$(_rud_user_file tunnel)" 2>/dev/null | grep -q .; }

_rud_rule() {  # интерфейс → RUDIRECT_RULE
  RUDIRECT_RULE=(-i "$1" -m set --match-set "$RUDIRECT_SET" dst -m addrtype ! --dst-type LOCAL
                 -m comment --comment "$RUDIRECT_TAG" -j MARK --set-xmark "$RUDIRECT_MARK")
}

# Без «ip rule show | grep -q»: grep выходит на первой строке, ip получает
# SIGPIPE, и при pipefail (awg2) длинный список правил — «правила нет».
_rud_ip_rule_on() { [[ "$(ip rule show 2>/dev/null)" == *"fwmark ${RUDIRECT_MARK} lookup main"* ]]; }

# Аплинки — устройства маршрутов по умолчанию в main, кроме своих
_rud_uplinks() {
  ip -4 route show default 2>/dev/null | awk -v own="$OWN_IFACES" '
    { for (i = 1; i < NF; i++) if ($i == "dev" && index(own, " " $(i + 1) " ") == 0 && !seen[$(i + 1)]++) print $(i + 1) }'
}

# Строгий rp_filter на аплинке (1; действует большее из all и устройства)
# молча отбрасывает ответы сайтов РФ: обратный путь к адресу клиента ядро
# ищет по правилу «from клиент lookup <туннель>» — он ведёт в туннель, а
# ответ пришёл на аплинк. Мягкий (2) проверяет только, что путь есть.
_rud_rpf_strict() {  # устройство
  local a d
  a=$(cat "$RUDIRECT_RPF/all/rp_filter" 2>/dev/null) || a=0
  d=$(cat "$RUDIRECT_RPF/$1/rp_filter" 2>/dev/null) || return 1
  (( (a > d ? a : d) == 1 ))
}

_rud_rpf_ok() {
  local dev
  for dev in $(_rud_uplinks); do ! _rud_rpf_strict "$dev" || return 1; done
  return 0
}

_rud_rpf_loose() {
  local dev
  for dev in $(_rud_uplinks); do
    _rud_rpf_strict "$dev" || continue
    if echo 2 > "$RUDIRECT_RPF/$dev/rp_filter" 2>/dev/null; then
      _rud_log "rp_filter на $dev: строгий → мягкий (иначе ответы сайтов РФ отбрасываются)"
    else
      _rud_log "rp_filter на $dev: не удалось сделать мягким — ответы сайтов РФ клиентам в туннеле не дойдут"
      return 1
    fi
  done
  return 0
}

_rud_rules_up() {
  local dev
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _rud_rule "$dev"
    iptables -t mangle -C PREROUTING "${RUDIRECT_RULE[@]}" 2>/dev/null \
      || iptables -t mangle -I PREROUTING 1 "${RUDIRECT_RULE[@]}" || return 1
  done
  _rud_ip_rule_on || ip rule add fwmark "$RUDIRECT_MARK" lookup main priority "$RUDIRECT_PRIO" || return 1
  _rud_rpf_loose || return 1
  ip route flush cache 2>/dev/null || true
}

_rud_rules_down() {
  local dev guard
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _rud_rule "$dev"; guard=0
    while (( guard++ < 32 )) && iptables -t mangle -D PREROUTING "${RUDIRECT_RULE[@]}" 2>/dev/null; do :; done
  done
  guard=0
  while (( guard++ < 32 )) && ip rule del fwmark "$RUDIRECT_MARK" lookup main priority "$RUDIRECT_PRIO" 2>/dev/null; do :; done
  return 0
}

# Правила на месте: набор, метки для awg0 и wgobf0, правило маршрутизации
# и не строгий rp_filter на аплинке
rudirect_rules_ok() {
  local dev
  ipset list -n "$RUDIRECT_SET" &>/dev/null || return 1
  for dev in "$AWG_IF" "$WGOBF_IF"; do
    _rud_rule "$dev"
    iptables -t mangle -C PREROUTING "${RUDIRECT_RULE[@]}" 2>/dev/null || return 1
  done
  _rud_ip_rule_on && _rud_rpf_ok
}

# Собрать набор из сохранённого списка и своих и поставить правила.
_rud_apply() {
  local d n nd nt nx rc=0
  # Выключили, пока качался список, — правила обратно не ставить
  [[ "$(_rud_get ON)" == 1 ]] || { rudirect_down; return 0; }
  [[ -s "$RUDIRECT_DIR/ru.list" ]] || { _rud_log "нечего применять: список РФ ещё не скачан"; return 3; }
  d=$(mktemp -d "$RUDIRECT_DIR/.apply.XXXXXX") || return 1
  _rud_user_cidrs direct | sort -u > "$d/my"
  _rud_user_cidrs tunnel | sort -u > "$d/excl"
  : > "$d/tg"
  rudirect_tg_on && _rud_tg_nets > "$d/tg"
  { _antiscan_parse 4 < "$RUDIRECT_DIR/ru.list"; cat "$d/my" "$d/tg"; } | sort -u > "$d/v4"
  nd=$(grep -c . "$d/my" || true); nt=$(grep -c . "$d/excl" || true)
  nx=$(sort -u "$d/my" "$d/tg" | grep -c . || true)       # не сети России: свои и Telegram
  if ! n=$(_antiscan_load "$RUDIRECT_SET" inet "$d/v4" "$d/excl"); then
    _rud_log "ipset: набор не загрузился"; rc=5
  elif ! _rud_rules_up; then
    _rud_log "iptables или ip rule: правило не поставилось"; rc=5
  else
    _rud_set ENTRIES "$(( n - nx )) $nd $nt"
    _rud_log "применено: сетей РФ $(( n - nx )), своих напрямую $nd, через туннель $nt$(rudirect_tg_on && echo ", Telegram напрямую")"
  fi
  rm -rf "$d"
  return "$rc"
}

rudirect_down() {
  local s
  _rud_rules_down
  command -v ipset &>/dev/null || return 0
  for s in "$RUDIRECT_SET" "$RUDIRECT_SET-new"; do ipset destroy "$s" 2>/dev/null || true; done
  ip route flush cache 2>/dev/null || true
  return 0
}

# Точка входа службы и таймера (и awg2): apply | update | heal | off.
rudirect_run() {
  local mode="${1:-heal}" rc=0 upd
  mkdir -p "$RUDIRECT_DIR" && chmod 700 "$RUDIRECT_DIR"
  exec 9>"$RUDIRECT_DIR/.lock"
  flock -w 180 9 || { _rud_log "$mode: занято другой операцией"; return 75; }
  if [[ "$mode" == off || "$(_rud_get ON)" != 1 ]]; then
    rudirect_down
    return 0
  fi
  case "$mode" in
    update) _rud_fetch || true; _rud_apply || rc=$? ;;
    apply) _rud_apply || rc=$? ;;
    heal)
      touch "$RUDIRECT_DIR/heal"
      upd=$(_rud_get UPDATED)
      if (( $(date +%s) - ${upd:-0} > 86400 )); then
        _rud_fetch || true
        _rud_apply || rc=$?
      elif ! rudirect_rules_ok; then
        _rud_log "правило пропало — применяю заново"
        _rud_apply || rc=$?
      elif _rud_has_domains; then
        _rud_apply || rc=$?           # адреса доменов из своих списков меняются
      fi ;;
    *) echo "использование: ${0##*/} apply|update|heal|off" >&2; return 2 ;;
  esac
  return "$rc"
}

# ── Установка ─────────────────────────────────────────────
_rudirect_emit() {
  emit_script "$RUDIRECT_SCRIPT" 'rudirect_run "$@"' \
    RUDIRECT_DIR RUDIRECT_CONF RUDIRECT_USER RUDIRECT_LOG RUDIRECT_SET RUDIRECT_TAG RUDIRECT_MARK RUDIRECT_PRIO \
    RUDIRECT_SRCS RUDIRECT_MIN RUDIRECT_MINADDR RUDIRECT_MAX4 RUDIRECT_RPF RUDIRECT_TG_NETS AWG_IF WGOBF_IF OWN_IFACES \
    write_file _rud_get _rud_set _rud_log _rud_fail _antiscan_parse _antiscan_span _antiscan_load rudirect_tg_on _rud_tg_nets \
    _rud_fetch _rud_user_file _rud_user_cidrs _rud_has_domains _rud_rule _rud_ip_rule_on _rud_uplinks \
    _rud_rpf_strict _rud_rpf_ok _rud_rpf_loose _rud_rules_up \
    _rud_rules_down rudirect_rules_ok _rud_apply rudirect_down rudirect_run || return 1
  write_unit "$RUDIRECT_UNIT" <<EOF
[Unit]
Description=AWG Toolza — РФ напрямую: клиенты в туннеле ходят к сетям России мимо него
DefaultDependencies=no
Wants=network-pre.target local-fs.target
After=local-fs.target systemd-modules-load.service
Before=network-pre.target ufw.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RUDIRECT_SCRIPT apply

[Install]
WantedBy=multi-user.target
EOF
  write_unit "${RUDIRECT_TIMER%.timer}.service" <<EOF
[Unit]
Description=AWG Toolza — РФ напрямую: правила на месте, домены раз в час, список раз в сутки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUDIRECT_SCRIPT heal
EOF
  write_unit "$RUDIRECT_TIMER" <<'EOF'
[Unit]
Description=AWG Toolza — РФ напрямую: проверка раз в час

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
}

rudirect_enable() {
  local rc=0 cc
  server_exists || { err "Сервер не создан"; return 1; }
  need_cmds ipset:ipset flock:util-linux || return 1
  _rud_set ON 1
  _rudirect_emit || { err "Не удалось записать службу"; return 1; }
  info "Скачиваю и проверяю список сетей России..."
  "$RUDIRECT_SCRIPT" update || rc=$?
  if (( rc )); then
    _rud_set ON 0
    "$RUDIRECT_SCRIPT" off &>/dev/null || true
    case $rc in
      3) err "Список сетей России не получен: $(_rud_get ERROR)" ;;
      75) err "Занято другой операцией — повтори через минуту" ;;
      *) err "Не удалось поставить правила (код $rc) — журнал: Журнал «РФ напрямую»" ;;
    esac
    return 1
  fi
  systemctl enable "$RUDIRECT_UNIT" &>/dev/null || true
  systemctl enable --now "$RUDIRECT_TIMER" &>/dev/null || true
  log_info "РФ напрямую: включено"
  ok "РФ напрямую включено: $(rudirect_summary)"
  cc=$(rudirect_abroad) && warn "$(_rud_abroad_text "$cc")"
  [[ -n "$(_rud_get ERROR)" ]] && warn "$(_rud_get ERROR)"
  return 0
}

rudirect_disable() {
  local held=0
  _rud_set ON 0
  remove_unit "$RUDIRECT_TIMER" "${RUDIRECT_TIMER%.timer}.service" "$RUDIRECT_UNIT"
  mkdir -p "$RUDIRECT_DIR" && chmod 700 "$RUDIRECT_DIR"
  exec 9>"$RUDIRECT_DIR/.lock"
  flock -w 20 9 && held=1
  rudirect_down
  (( held )) || _rud_log "выключение: замок занят дольше 20 с — снято без него"
  exec 9>&-
  _rud_log "выключено"
  log_info "РФ напрямую: выключено"
  ok "РФ напрямую выключено: клиенты в туннеле снова идут через него ко всем сайтам"
}

rudirect_update() {
  rudirect_on || { err "РФ напрямую — выключено"; return 1; }
  _rudirect_emit || return 1
  "$RUDIRECT_SCRIPT" update || { err "Не удалось применить список — журнал «РФ напрямую»"; return 1; }
  if [[ -n "$(_rud_get ERROR)" ]]; then warn "$(_rud_get ERROR)"; fi
  ok "Список обновлён: $(rudirect_summary)"
}

# Починить: правила и набор заново из сохранённого списка (без скачивания)
rudirect_repair() {
  rudirect_on || { err "РФ напрямую — выключено"; return 1; }
  _rudirect_emit || return 1
  systemctl enable "$RUDIRECT_UNIT" &>/dev/null || true
  systemctl enable --now "$RUDIRECT_TIMER" &>/dev/null || true
  "$RUDIRECT_SCRIPT" apply || { err "Не удалось применить — журнал «РФ напрямую»"; return 1; }
  rudirect_rules_ok || { err "Правила не на месте и после починки — журнал «РФ напрямую»"; return 1; }
  ok "Правила на месте: $(rudirect_summary)"
}

# Пакетов и байт, ушедших мимо туннеля, с установки правил (перезагрузка сбрасывает)
rudirect_counters() {
  iptables-save -c -t mangle 2>/dev/null | awk -v tag="$RUDIRECT_TAG" 'index($0, "--comment " tag) && /^\[/ {
      split(substr($1, 2), c, ":"); sub(/\].*/, "", c[2]); p += c[1]; b += c[2] }
    END { printf "%.0f %.0f\n", p, b }'
}

rudirect_summary() {
  local e
  read -r -a e <<< "$(_rud_get ENTRIES)"
  echo "сетей РФ ${e[0]:-0}, своих напрямую ${e[1]:-0}, через туннель ${e[2]:-0}$(rudirect_tg_on && echo ", Telegram напрямую")"
}

rudirect_tg_set() {  # on|off
  case "${1:-}" in
    on) _rud_set TG 1; _rud_log "Telegram напрямую: включено"
        ok "Telegram напрямую: клиенты в туннеле ходят в Telegram с адреса сервера" ;;
    off) _rud_set TG 0; _rud_log "Telegram напрямую: выключено"
         ok "Telegram напрямую выключено: Telegram — снова через туннель" ;;
    *) err "Telegram напрямую: on | off"; return 1 ;;
  esac
  _rud_reapply
}

# ── Свои списки ───────────────────────────────────────────
# Запись: IPv4, подсеть (не шире /12) или домен; из URL берётся домен.
# Частные и служебные сети не принимаются: они и так не идут через туннель.
_rud_entry_norm() {  # ввод → нормальная запись или пусто
  local raw="${1//[[:space:]]/}" v
  if [[ "$raw" =~ ^[0-9.]+(/[0-9]+)?$ ]]; then
    v=$(_antiscan_parse 4 <<< "$raw")
    [[ -n "$v" ]] || return 1
    echo "${v%/32}"     # одиночный адрес — без /32: «1.2.3.4» и «1.2.3.4/32» — одна запись
    return 0
  fi
  v="${raw,,}"; v="${v#*://}"; v="${v%%/*}"; v="${v%%:*}"
  valid_domain "$v" && echo "$v"
}

rudirect_list() {  # direct|tunnel → записи
  local f
  f=$(_rud_user_file "$1")
  [[ -f "$f" ]] && grep -vE '^[[:space:]]*(#|$)' "$f"
  return 0
}

rudirect_list_add() {  # direct|tunnel запись
  local kind="$1" v f other
  [[ "$kind" == direct || "$kind" == tunnel ]] || { err "Список: direct | tunnel"; return 1; }
  v=$(_rud_entry_norm "${2:-}") || { err "Нужен публичный IPv4, подсеть не шире /12 или домен: ${2:-пусто}"; return 1; }
  f=$(_rud_user_file "$kind")
  mkdir -p "$RUDIRECT_USER" && chmod 700 "$RUDIRECT_USER"
  grep -qxF "$v" "$f" 2>/dev/null && { info "$v уже в списке"; return 0; }
  other=$(_rud_user_file "$([[ "$kind" == direct ]] && echo tunnel || echo direct)")
  grep -qxF "$v" "$other" 2>/dev/null && { err "$v уже в другом списке — сначала убери его оттуда"; return 1; }
  (( $(rudirect_list "$kind" | grep -c . || true) < RUDIRECT_USER_MAX )) \
    || { err "В списке уже $RUDIRECT_USER_MAX записей"; return 1; }
  { cat "$f" 2>/dev/null; echo "$v"; } | write_file "$f" 600
  _rud_log "$([[ "$kind" == direct ]] && echo 'напрямую' || echo 'через туннель') + $v"
  ok "$v — $([[ "$kind" == direct ]] && echo 'всегда напрямую' || echo 'всегда через туннель')"
  _rud_reapply
}

rudirect_list_del() {  # direct|tunnel запись|all
  local kind="$1" v="${2:-}" f
  [[ "$kind" == direct || "$kind" == tunnel ]] || { err "Список: direct | tunnel"; return 1; }
  f=$(_rud_user_file "$kind")
  if [[ "$v" == all ]]; then
    rm -f "$f"; _rud_log "$kind: список очищен"; ok "Список очищен"
  else
    v=$(_rud_entry_norm "$v") || v="${2:-}"
    grep -qxF "$v" "$f" 2>/dev/null || { err "$v в списке нет"; return 1; }
    grep -vxF "$v" "$f" | write_file "$f" 600
    _rud_log "$kind − $v"; ok "Убрано: $v"
  fi
  _rud_reapply
}

_rud_reapply() {
  rudirect_on || { info "РФ напрямую выключено — вступит в силу при включении"; return 0; }
  _rudirect_emit && "$RUDIRECT_SCRIPT" apply || { err "Не удалось применить — журнал «РФ напрямую»"; return 1; }
}

# Таймер молчит дольше трёх часов (сброшен, заглох) — перезапустить
rudirect_watchdog() {
  local age
  rudirect_on || return 0
  [[ -f "$RUDIRECT_DIR/heal" ]] || return 0
  age=$(( $(date +%s) - $(stat -c %Y "$RUDIRECT_DIR/heal" 2>/dev/null || echo 0) ))
  (( age < 10800 )) && return 0
  touch "$RUDIRECT_DIR/heal"
  timer_heal "$RUDIRECT_TIMER"
  systemctl start --no-block "${RUDIRECT_TIMER%.timer}.service" &>/dev/null || true
}

rudirect_remove() {
  remove_unit "$RUDIRECT_TIMER" "${RUDIRECT_TIMER%.timer}.service" "$RUDIRECT_UNIT"
  rudirect_down
  rm -rf "$RUDIRECT_DIR" "$RUDIRECT_SCRIPT" "$RUDIRECT_LOG"
}

# ── Меню ──────────────────────────────────────────────────
_rudirect_show() {
  local upd err c
  hdr "РФ напрямую"
  echo -e "  ${D}Клиенты в туннеле (WARP, Xray, tun2socks, exit-ноды) ходят к сетям России мимо"
  echo -e "  него, прямо с сервера. Полезно, когда сервер в России, а выход — за границей.${N}"
  echo ""
  if rudirect_on; then
    if rudirect_rules_ok; then echo -e "  Состояние : ${G}● включено${N} — $(rudirect_summary)"
    else echo -e "  Состояние : ${Y}▲ включено, правило не на месте${N} — «Починить» или подождать таймер"; fi
    read -r c _ <<< "$(rudirect_counters)"
    echo -e "  Мимо туннеля: ${W}${c:-0}${N} ${D}пакетов (сбрасывается при перезагрузке)${N}"
  else
    echo -e "  Состояние : ${D}○ выключено${N}"
  fi
  if rudirect_on && c=$(rudirect_abroad); then
    echo -e "  ${Y}▲ $(_rud_abroad_text "$c").${N}"
    echo -e "  ${D}  Страна определена неверно — выбери её флагом в шапке панели.${N}"
  fi
  if rudirect_tg_on; then echo -e "  Telegram  : ${G}напрямую${N} ${D}— с адреса сервера${N}"
  else echo -e "  Telegram  : ${D}через туннель${N}"; fi
  upd=$(_rud_get UPDATED)
  [[ -n "$upd" ]] && echo -e "  Список    : обновлён $(date -d "@$upd" '+%d.%m.%Y %H:%M' 2>/dev/null) ${D}($(_rud_get SRC))${N}"
  err=$(_rud_get ERROR)
  [[ -n "$err" ]] && echo -e "  ${Y}▲ $err${N}"
  return 0
}

_rudirect_list_menu() {  # direct|tunnel
  local kind="$1" rows=() i c v title
  title=$([[ "$kind" == direct ]] && echo "Всегда напрямую" || echo "Всегда через туннель")
  while true; do
    mapfile -t rows < <(rudirect_list "$kind")
    echo ""
    hdr "$title"
    (( ${#rows[@]} )) || echo -e "  ${D}Список пуст${N}"
    for i in "${!rows[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${rows[$i]}"; done
    echo -e "  ${G}a)${N} Добавить ${D}— IPv4, подсеть или домен${N}"
    (( ${#rows[@]} )) && echo -e "  ${R}x)${N} Очистить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер — убрать: ${N}" 0 "${#rows[@]}" 0 "a|x"
    case "$c" in
      0) return 0 ;;
      a) read_line v "${C}  Адрес, подсеть или домен: ${N}"; [[ -n "$v" ]] && { rudirect_list_add "$kind" "$v" || true; } ;;
      x) ask_yes "  Очистить список? [y/N]: " n && { rudirect_list_del "$kind" all || true; } ;;
      *) rudirect_list_del "$kind" "${rows[$((c - 1))]}" || true ;;
    esac
  done
}

do_rudirect_menu() {
  local c cc
  while true; do
    echo ""
    _rudirect_show
    echo ""
    if rudirect_on; then echo -e "  ${C}1)${N} Выключить"; else echo -e "  ${C}1)${N} Включить"; fi
    echo -e "  ${C}2)${N} Обновить список сейчас"
    echo -e "  ${C}3)${N} Всегда напрямую ${D}— свои адреса: $(rudirect_list direct | grep -c . || true)${N}"
    echo -e "  ${C}4)${N} Всегда через туннель ${D}— исключения: $(rudirect_list tunnel | grep -c . || true)${N}"
    echo -e "  ${C}5)${N} Починить ${D}— поставить правила заново${N}"
    echo -e "  ${C}6)${N} Журнал"
    if rudirect_tg_on; then echo -e "  ${C}7)${N} Telegram — снова через туннель"
    else echo -e "  ${C}7)${N} Telegram напрямую ${D}— если через туннель Telegram висит на «Соединение…»${N}"; fi
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-7]: ${N}" 0 7 0
    case "$c" in
      1) if rudirect_on; then rudirect_disable
         else
           cc=$(rudirect_abroad) && warn "$(_rud_abroad_text "$cc")"
           echo -e "  ${D}Клиенты в туннеле пойдут к сайтам России с адреса сервера.${N}"
           ask_yes "  Включить? [y/N]: " n && { rudirect_enable || true; }
         fi ;;
      2) rudirect_update || true ;;
      3) _rudirect_list_menu direct; continue ;;
      4) _rudirect_list_menu tunnel; continue ;;
      5) rudirect_repair || true ;;
      6) tail -n 40 "$RUDIRECT_LOG" 2>/dev/null || info "Журнал пуст" ;;
      7) if rudirect_tg_on; then rudirect_tg_set off || true; else rudirect_tg_set on || true; fi ;;
      0) return 0 ;;
    esac
    pause
  done
}
