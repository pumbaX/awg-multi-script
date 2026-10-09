# Бэкапы в ~/awg_backup (домашний каталог того, кто запустил sudo):
#   awg2_backup_<время>/        — полный: сервер, клиенты, WARP, WG + обфускатор,
#                                 настройки туннелей (tunnels.tar.gz);
#   auto_<причина>_<время>.tar.gz — перед опасными операциями: сервер и клиенты.

# Настройки туннелей: сами туннели при восстановлении не включаются.
_BACKUP_TUNNEL_PATHS=()
_backup_tunnel_paths() {
  local p
  _BACKUP_TUNNEL_PATHS=()
  for p in "$XRAY_DIR" "$EXITS_STATE" "$EXITS_PEERS" "$CASCADE_RULES" "$T2S_CONF" "$DNS_PROXY_CONF" \
           "$EXITS_DIR"/awg-exit-*.conf; do
    [[ -e "$p" ]] && _BACKUP_TUNNEL_PATHS+=("${p#/}")
  done
  return 0
}

auto_backup() {  # причина
  local files=() arch f
  [[ -f "$SERVER_CONF" ]] || return 0
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  arch="$BACKUP_DIR/auto_${1:-operation}_$(date +%Y%m%d_%H%M%S).tar.gz"
  files=("${SERVER_CONF#/}")
  while IFS= read -r f; do files+=("${f#/}"); done < <(client_files)
  tar -czf "$arch" -C / "${files[@]}" 2>/dev/null || return 1
  chmod 600 "$arch"
  info "Авто-бэкап: ${arch##*/}"
}

do_backup() { backup_create; }

# Полный бэкап → каталог в BACKUP_PATH; с «archive» ещё и .tar.gz рядом (для бота).
# «archive auto [N]» — автобэкап бота по расписанию: только архив
# awg2_backup_<время>_auto.tar.gz, из таких хранятся N последних (по умолчанию 7).
BACKUP_PATH=""
backup_create() {
  local ts dir n=0 f auto=0 keep=7
  if [[ "${2:-}" == auto ]]; then
    auto=1
    [[ "${3:-}" =~ ^[0-9]{1,3}$ ]] && (( 10#$3 >= 1 )) && keep=$((10#$3))
  fi
  # Имя — по секундам: второй бэкап в ту же секунду писал бы в тот же архив
  while :; do
    ts=$(date +%Y%m%d_%H%M%S)
    dir="$BACKUP_DIR/awg2_backup_$ts"
    (( auto )) && dir+="_auto"
    [[ -e "$dir" || -e "$dir.tar.gz" ]] || break
    sleep 1
  done
  mkdir -p "$dir" && chmod 700 "$BACKUP_DIR" "$dir"
  if [[ -f "$SERVER_CONF" ]]; then cp -a "$SERVER_CONF" "$dir/awg0.conf"; n=$((n + 1)); ok "Сервер: awg0.conf"
  else warn "Серверного конфига нет"; fi
  while IFS= read -r f; do cp -a "$f" "$dir/"; n=$((n + 1)); done < <(client_files)
  (( n > 1 )) && ok "Клиентов: $((n - 1))"
  iface_up && awg show "$AWG_IF" > "$dir/awg_show_dump.txt" 2>/dev/null
  # WARP: перерегистрация упирается в лимиты Cloudflare — аккаунт бережём
  if [[ -d "$WARP_DIR" ]]; then
    mkdir -p "$dir/warp" && cp -a "$WARP_DIR" "$dir/warp/wgcf" && ok "WARP (wg): аккаунт"
    [[ -f "$WARP_CONF" ]] && cp -a "$WARP_CONF" "$dir/warp/warp0.conf"
  fi
  if [[ -f "$USQUE_CONF" ]]; then
    mkdir -p "$dir/warp/usque" && cp -a "$USQUE_CONF" "$dir/warp/usque/config.json" && ok "WARP (usque): регистрация"
  fi
  if wgobf_installed; then
    mkdir -p "$dir/wgobf"
    cp -a "$WGOBF_DIR" "$dir/wgobf/etc" && cp -a "$WGOBF_WG_CONF" "$dir/wgobf/$WGOBF_IF.conf" && ok "WG + обфускатор"
    [[ -d "$WGOBF_CLIENTS" ]] && cp -a "$WGOBF_CLIENTS" "$dir/wgobf/clients"
  fi
  _backup_tunnel_paths
  if (( ${#_BACKUP_TUNNEL_PATHS[@]} )); then
    tar -czf "$dir/tunnels.tar.gz" -C / "${_BACKUP_TUNNEL_PATHS[@]}" 2>/dev/null && ok "Настройки туннелей"
  fi
  [[ -f "$LOG_FILE" ]] && cp -a "$LOG_FILE" "$dir/awg-manager.log"
  {
    echo "timestamp=$ts"
    echo "server_conf=$SERVER_CONF"
    echo "backed_files=$n"
    echo "awg_version=$(server_proto 2>/dev/null)"
    echo "warp_backend=$(warp_backend)"
    echo "toolza=$VERSION"
    echo "hostname=$(hostname)"
  } > "$dir/backup_meta.txt"
  chmod -R go-rwx "$dir"
  BACKUP_PATH="$dir"
  if [[ "${1:-}" == archive ]]; then
    # Архив не записался (кончилось место) — обрезок не оставлять: в нём
    # приватные ключи, а среди автобэкапов он вытеснил бы целые при ротации
    if ! (umask 077 && tar -czf "$dir.tar.gz" -C "$BACKUP_DIR" "${dir##*/}"); then
      rm -f "$dir.tar.gz"
      (( auto )) && rm -rf "$dir"
      err "Архив бэкапа не записан — проверь место на диске: df -h $BACKUP_DIR"
      return 1
    fi
    chmod 600 "$dir.tar.gz"
    BACKUP_PATH="$dir.tar.gz"
  fi
  if (( auto )) && [[ "$BACKUP_PATH" == *.tar.gz ]]; then
    rm -rf "$dir"
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'awg2_backup_*_auto.tar.gz' -printf '%f\n' 2>/dev/null \
      | sort -r | tail -n +$((keep + 1)) | while IFS= read -r f; do rm -f "${BACKUP_DIR:?}/$f"; done
  fi
  success_box "Бэкап: $BACKUP_PATH"
  log_info "бэкап: $BACKUP_PATH"
}

_restore_list() {  # → строки «путь» (новые сверху)
  find "$BACKUP_DIR" -maxdepth 1 \( -type d -name 'awg2_backup_*' -o -type f -name '*.tar.gz' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

# Каталог с awg0.conf из любого бэкапа: каталог полного бэкапа, его архив,
# авто-бэкап (пути от корня) или архив бота прежних версий (awg0.conf + clients/).
RESTORE_SRC=""
_restore_prepare() {
  local src="$1" tmp d
  RESTORE_SRC=""
  if [[ -d "$src" ]]; then
    [[ -f "$src/awg0.conf" ]] || { err "В бэкапе нет awg0.conf"; return 1; }
    RESTORE_SRC="$src"; return 0
  fi
  [[ -f "$src" ]] || { err "Нет файла $src"; return 1; }
  mktmp tmp -d || return 1
  py safe-untar "$src" "$tmp/x" || { err "Архив не распаковался"; return 1; }
  if [[ -f "$tmp/x/awg0.conf" ]]; then d="$tmp/x"
  elif [[ -f "$tmp/x$SERVER_CONF" ]]; then d="$tmp/x"; cp -a "$tmp/x$SERVER_CONF" "$d/awg0.conf"
  else d=$(find "$tmp/x" -mindepth 2 -maxdepth 2 -name awg0.conf -printf '%h\n' | head -1); fi
  [[ -n "$d" && -f "$d/awg0.conf" ]] || { err "В архиве нет awg0.conf — это не бэкап awg2"; return 1; }
  # Клиенты у разных форматов лежат по-разному — собираем рядом с awg0.conf
  find "$tmp/x" -name '*_awg[23].conf' ! -path "$d/*_awg[23].conf" -exec cp -a {} "$d/" \;
  RESTORE_SRC="$d"
}

_restore_awg_files() {  # каталог бэкапа
  local src="$1" f keep
  install -D -m 600 "$src/awg0.conf" "$SERVER_CONF"
  # Конфиги клиентов, которых нет в восстановленном awg0.conf, иначе остаются
  # сиротами: видны в «Показать конфиг», занимают имя и попадают в архив.
  # Конфиги пиров, которые в awg0 есть, не трогаем: бэкап мог прийти без них.
  # awg0.conf не разобрался — не трогаем ничего: пустой список стёр бы всех.
  if keep=$(clients_tsv | cut -f1 | tr '\n' ' '); then
    keep=" $keep "
    for f in "$CLIENT_DIR"/*_awg[23].conf; do
      [[ -f "$f" && "$keep" != *" $(client_name_of "$f") "* ]] && rm -f "$f"
    done
  else
    warn "awg0.conf из бэкапа не разобран — конфиги клиентов на сервере не трогаю"
  fi
  while IFS= read -r -d '' f; do
    rm -f "$CLIENT_DIR/$(client_name_of "$f")"_awg[23].conf
    install -m 600 "$f" "$CLIENT_DIR/${f##*/}"
  done < <(find "$src" -maxdepth 1 -name '*_awg[23].conf' -print0)
}

_restore_warp() {  # каталог бэкапа
  local src="$1/warp" be f
  [[ -d "$src" ]] || return 0
  if [[ -d "$src/wgcf" ]]; then
    # Только данные аккаунта: в каталоге лежит и скрипт автозапуска, который
    # служба выполняет от root, — его Тулза пишет сама, из бэкапа не берём.
    # Состояние «включён» тоже не переносим — туннель включают руками.
    mkdir -p "$WARP_DIR" && chmod 700 "$WARP_DIR"
    for f in "$WARP_ACCOUNT" "$WARP_PROFILE" "$WARP_PEERS" "$WARP_DIR/account_type"; do
      [[ -f "$src/wgcf/${f##*/}" ]] && install -D -m 600 "$src/wgcf/${f##*/}" "$f"
    done
    rm -f "$WARP_STATE" "$WARP_STATE.failed"
    ok "WARP (wg): аккаунт"
  fi
  [[ -f "$src/warp0.conf" ]] && install -D -m 600 "$src/warp0.conf" "$WARP_CONF"
  if [[ -f "$src/usque/config.json" ]]; then
    install -D -m 600 "$src/usque/config.json" "$USQUE_CONF" && chmod 700 "$USQUE_DIR" && ok "WARP (usque): регистрация"
  fi
  be=$(sed -n 's/^warp_backend=//p' "$1/backup_meta.txt" 2>/dev/null)
  [[ "$be" == wg || "$be" == usque ]] && echo "$be" | write_file "$WARP_BACKEND_FILE" 644
  info "WARP восстановлен выключенным — включи его в меню туннелей"
}

# Настройки туннелей. Бэкап мог прийти чужой (присланный в бота), поэтому
# архив не распаковывается в / — иначе он переписал бы любой файл системы.
# Он идёт во временный каталог, а на место ложатся только файлы, которые
# кладёт в бэкап сама Тулза, и с проверкой: конфиги exit-нод — без хуков,
# правила каскада и адрес tun2socks — по формату, конфиг dnscrypt-proxy —
# шаблон Тулзы, из бэкапа берутся только имена резолверов.
_restore_tunnels() {  # каталог бэкапа
  local arch="$1/tunnels.tar.gz" x f n names
  [[ -f "$arch" ]] || return 0
  mktmp x -d || return 1
  py safe-untar "$arch" "$x" || { warn "Настройки туннелей не распаковались"; return 0; }
  if [[ -f "$x$XRAY_CONF" ]]; then
    # Xray работает от root: из чужого конфига — только выходы и маршруты,
    # входы (SOCKS на 0.0.0.0, API) и журналы Тулза пишет сама
    if n=$(py xray-restore-clean "$x$XRAY_CONF" 2>/dev/null); then
      install -D -m 600 "$x$XRAY_CONF" "$XRAY_CONF"
      [[ -n "$n" ]] && warn "Из конфига Xray бэкапа убрано: $n"
    else warn "Конфиг Xray из бэкапа не разобран — пропущен"; fi
  fi
  [[ -f "$x$XRAY_PEERS" ]] && install -D -m 600 "$x$XRAY_PEERS" "$XRAY_PEERS"
  for f in "$EXITS_STATE" "$EXITS_PEERS"; do
    [[ -f "$x$f" ]] && install -D -m 600 "$x$f" "$f"
  done
  for f in "$x$EXITS_DIR"/awg-exit-*.conf; do
    [[ -f "$f" ]] || continue
    n="${f##*/awg-exit-}"; n="${n%.conf}"
    [[ "$n" =~ ^[A-Za-z0-9_]{1,6}$ ]] || { warn "Пропущен конфиг exit-ноды: ${f##*/}"; continue; }
    py exit-conf-fix "$f" && install -m 600 "$f" "$EXITS_DIR/awg-exit-$n.conf"
  done
  [[ -f "$x$CASCADE_RULES" ]] && _restore_cascade_rules "$x$CASCADE_RULES"
  if [[ -f "$x$T2S_CONF" ]]; then
    n=$(head -1 "$x$T2S_CONF" | tr -d '[:space:]')
    [[ "$n" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] && echo "$n" | write_file "$T2S_CONF" 600
  fi
  if [[ -f "$x$DNS_PROXY_CONF" ]]; then
    names=$(sed -n 's/^server_names[[:space:]]*=[[:space:]]*//p' "$x$DNS_PROXY_CONF" | tr -d "[]'\"" | head -1)
    _dns_write_conf
    [[ -n "$names" ]] && { _dns_upstream_write "$names" || warn "Резолверы DNS из бэкапа не приняты — стоят по умолчанию"; }
  fi
  rm -f "$XRAY_STATE"
  [[ -f "$EXITS_STATE" ]] && exits_state_set state inactive
  for n in $(exits_nodes); do systemctl enable --now "awg-quick@awg-exit-$n" &>/dev/null || warn "Нода $n не поднялась"; done
  (( $(cascade_count) )) && { _cascade_persist; systemctl restart awg-cascade.service &>/dev/null; }
  ok "Настройки туннелей восстановлены; маршрутизация клиентов выключена"
}

# Правила каскада из бэкапа — с теми же проверками, что при добавлении:
# публичный адрес цели, порты 1-65535, вход не занят AmneziaWG, обфускатором
# или локальным сервисом. Не прошедшее — пропускается с причиной.
_restore_cascade_rules() {  # файл правил из бэкапа
  local p in dst out comment why seen=" " kept=()
  # || [[ -n $p ]]: последняя строка без перевода строки (файл правили руками)
  # иначе молча терялась
  while IFS='|' read -r p in dst out comment || [[ -n "$p" ]]; do
    [[ "$p" == udp || "$p" == tcp ]] || continue
    out="${out//[$'\r']/}" comment="${comment//[$'\r']/}"
    # Поля из чужого файла идут в warn (echo -e) — без управляющих символов и \\
    in="${in//[$'\001'-$'\037'$'\177'\\]/?}" dst="${dst//[$'\001'-$'\037'$'\177'\\]/?}"
    out="${out//[$'\001'-$'\037'$'\177'\\]/?}"
    if why=$(_cascade_rule_invalid "$in" "$dst" "$out"); then
      warn "Каскад из бэкапа: пропущено ${p^^} $in → $dst:$out — $why"; continue
    fi
    [[ "$seen" == *" $p|$in "* ]] && continue
    if why=$(CASCADE_RULES=/dev/null _cascade_port_conflict "$p" "$in"); then
      warn "Каскад из бэкапа: пропущено ${p^^} $in — $why"; continue
    fi
    seen+="$p|$in "
    kept+=("$p|$in|$dst|$out|$comment")
  done < "$1"
  if (( ${#kept[@]} )); then printf '%s\n' "${kept[@]}" | write_file "$CASCADE_RULES" 600
  else rm -f "$CASCADE_RULES"; fi
}

# Хуки конфига из бэкапа (PostUp и т. п.) выполняются от root при подъёме
# интерфейса. Команды не из Тулзы (не iptables, ip_forward, MTU) в меню —
# показать и спросить, в боте и панели — убрать с предупреждением в итоге.
_restore_hooks() {  # конфиг [разрешённые команды…]
  local conf="$1" bad
  shift
  bad=$(py conf-hooks "$conf" check "$@") || { err "${conf##*/} из бэкапа не читается"; return 1; }
  [[ -n "$bad" ]] || return 0
  warn "В ${conf##*/} из бэкапа — команды, которые выполнятся от root при запуске:"
  sed 's/^/    /; s/\t/ = /' <<< "$bad"
  if (( ! AUTO_MODE )) && ask_yes "  Оставить их? Только если ты сам их туда вписал [y/N]: " n; then
    warn "Команды оставлены"
    return 0
  fi
  py conf-hooks "$conf" fix "$@" >/dev/null || return 1
  warn "Команды убраны из ${conf##*/}"
}

do_restore() {
  local list=() i c src name opts=()
  mapfile -t list < <(_restore_list)
  (( ${#list[@]} )) || { err "Бэкапов нет в $BACKUP_DIR"; return 1; }
  for i in "${!list[@]}"; do
    name="${list[$i]##*/}"
    if [[ -d "${list[$i]}" ]]; then echo -e "  ${C}$((i + 1)))${N} $name ${D}(полный)${N}"
    else echo -e "  ${C}$((i + 1)))${N} $name"; fi
  done
  read_choice c "${C}  Бэкап (Enter = 1, 0 — отмена): ${N}" 0 "${#list[@]}" 1
  (( c )) || return 0
  src="${list[$((c - 1))]}"
  _restore_prepare "$src" || return 1
  read_confirm "${R}  Текущий сервер будет заменён. Продолжить? (введи yes): ${N}" || return 0
  [[ -d "$RESTORE_SRC/wgobf/etc" ]] && ask_yes "  В бэкапе есть WG + обфускатор — восстановить? [Y/n]: " y && opts+=(wgobf)
  [[ -f "$RESTORE_SRC/tunnels.tar.gz" ]] \
    && ask_yes "  Восстановить настройки туннелей (Xray, exit-ноды, каскад, tun2socks, DNS)? [Y/n]: " y && opts+=(tunnels)
  backup_restore "$src" "${opts[@]}"
}

# backup_restore БЭКАП [wgobf] [tunnels] — сервер и клиенты всегда, остальное по флагам.
backup_restore() {
  local src="$1" label="${1##*/}" port f
  shift
  command -v awg-quick &>/dev/null || { err "Нет awg-quick — сначала установи компоненты (Сервер → Установить компоненты)"; return 1; }
  _restore_prepare "$src" || return 1
  src="$RESTORE_SRC"
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  [[ -f "$SERVER_CONF" ]] && cp -a "$SERVER_CONF" "$SERVER_CONF.pre_restore.$(date +%s)"
  _restore_awg_files "$src"
  _restore_hooks "$SERVER_CONF" || return 1
  # Бэкап с другого VPS: NAT — на аплинк этого сервера
  conf_uplink_sync force || true
  client_files_sync_suffix
  ok "Сервер и клиенты: $(client_files | wc -l) кл."
  _restore_warp "$src"
  for f in "$@"; do
    case "$f" in
      wgobf) [[ -f "$src/wgobf/$WGOBF_IF.conf" && -d "$src/wgobf/etc" ]] && { wgobf_restore "$src/wgobf" || true; } ;;
      tunnels) _restore_tunnels "$src" ;;
    esac
  done
  # Восстановление на чистый сервер: автозапуск, форвардинг и порт в UFW
  ip_forward_enable
  setup_autostart
  port=$(server_port)
  [[ -n "$port" ]] && ufw_allow "$port/udp" AmneziaWG
  expire_install
  if awg_up_diag; then ok "awg0 поднят"; else err "awg0 не поднялся — конфиг: $SERVER_CONF"; return 1; fi
  success_box "Восстановлено из $label"
  log_info "восстановление из $label"
}
