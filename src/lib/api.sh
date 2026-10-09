# Машинный интерфейс для Telegram-бота: awg2 api КОМАНДА [аргументы].
#
# Каждый вызов печатает одну строку JSON:
#   {"ok": true, "rc": 0, "data": ..., "log": "вывод без цвета", "error": ""}
# data — результат для кнопок и списков, log — тот же текст, что видит
# пользователь меню, error — последняя строка «×» при неудаче.
# Бот вызывает те же функции-ядра, что и меню: поведение у них одно.
#
# Большие входные данные (конфиг exit-ноды, профиль WARP) идут через stdin.
# Долгое (сборка модуля, установка, обновление) запускается задачей:
#   awg2 api job start КОМАНДА...      → data.id
#   awg2 api job status ID [СМЕЩЕНИЕ]  → состояние, новый кусок журнала, итог
# Задача живёт в своём юните systemd и переживает перезапуск бота — поэтому
# через неё бот может обновить, перезапустить и удалить самого себя.
#
# Изменяющие команды выполняются по одной (flock); чтение — без очереди.

API_VERSION=1
API_MODE=0          # 1 — вызов пришёл из awg2 api (например, от бота)
API_JOBS="" API_LOCK="" API_LOG="" API_DATA="" API_IN="" API_RESULT="" API_SELF=""
API_STDIN_READ=0
API_ARGS=()

# ── JSON ──────────────────────────────────────────────────
# Строка для py json-kv: «ключ[:тип]<TAB>значение». Типы: n число, b да/нет,
# j готовый JSON, f содержимое файла; без типа — строка.
_kv() { printf '%s\t%s\n' "$1" "${2//[$'\n\r']/ }"; }
_b() { if "$@" &>/dev/null; then echo 1; else echo 0; fi; }
api_obj() { py json-kv > "$API_DATA"; }
api_rows() { py json-rows "$@" > "$API_DATA"; }
api_list() { py json-list > "$API_DATA"; }

_api_usage() { err "Использование: awg2 api $*"; return 2; }

# stdin читается только командами, которым он нужен: иначе вызов из
# скрипта с открытым, но пустым stdin ждал бы его конца вечно.
_api_wants_stdin() { [[ "$1 ${2:-}" == "exits add" || "$1 ${2:-}" == "warp import" ]]; }
_api_stdin() {
  (( API_STDIN_READ )) && return 0
  API_STDIN_READ=1
  [[ -t 4 ]] || cat <&4 > "$API_IN"
}

# «up» — работает, «off» — настроен и выключен, «none» — не настроен.
_api_tun() {
  local check="$1" f
  shift
  "$check" &>/dev/null && { echo up; return; }
  for f in "$@"; do [[ -e "$f" ]] && { echo off; return; }; done
  echo none
}

# Срок клиента: unix-время, +30d / +12h / +45m или дата для date -d.
# Значение приходит от бота и панели: в арифметику bash попадают только
# цифры, проверенные регуляркой, — bash вычисляет содержимое переменной как
# выражение, и непроверенная строка могла бы выполнить команду.
_api_ts() {
  local v="$1" n re_date='^[0-9A-Za-z :./+-]{1,40}$'
  if [[ "$v" =~ ^\+([0-9]{1,6})([dhm])$ ]]; then
    n=$((10#${BASH_REMATCH[1]}))
    case "${BASH_REMATCH[2]}" in d) n=$((n * 86400)) ;; h) n=$((n * 3600)) ;; m) n=$((n * 60)) ;; esac
    echo $(( $(date +%s) + n ))
  elif [[ "$v" =~ ^[0-9]{1,12}$ ]]; then
    echo $((10#$v))
  elif [[ "$v" =~ $re_date ]]; then
    date -d "$v" +%s 2>/dev/null
  fi
  return 0
}

# ── Сводка ────────────────────────────────────────────────
_api_status() {
  local n=0
  os_detect
  update_check_async || true
  upstream_refresh_async || true
  country_refresh_async || true
  server_exists && n=$(clients_tsv | grep -c . || true)
  {
    _kv version "$VERSION_SHOW"; _kv api:n "$API_VERSION"
    _kv channel "$UPDATE_CHANNEL"; _kv update "$(update_available || true)"
    _kv host "$(hostname)"; _kv ip "$(public_ip_cached)"; _kv country "$(server_country)"
    _kv uptime:n "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
    _kv os "$OS_LABEL"; _kv kernel "$(uname -r)"
    _kv components.installed:b "$(_b command -v awg)"
    _kv components.module "$(mod_tag)"; _kv components.tools "$(tools_tag)"
    _kv components.loaded:b "$(_b mod_loaded)"
    _kv components.module_update "$(mod_update_available)"
    _kv components.tools_update "$(tools_update_available)"
    _kv components.reboot "$(reboot_reason)"
    _kv components.kernel_gap "$(kernel_gap_line)"
    _kv server.exists:b "$(_b server_exists)"
    if server_exists; then
      _kv server.up:b "$(_b iface_up)"
      _kv server.proto "$(server_proto)"; _kv server.profile "$(server_profile)"
      _kv server.profile_label "$(profile_label)"
      _kv server.port:n "$(server_port)"; _kv server.net "$(server_net)"
      _kv server.endpoint "$(endpoint_host):$(server_port)"; _kv server.domain "$(endpoint_domain)"
      _kv server.region "$(server_region)"; _kv server.mtu:n "$(conf_iface_get MTU)"
      _kv server.mimicry "$(conf_marker AWG_MIMICRY)"; _kv server.clients:n "$n"
      # Онлайн — рукопожатие за последние 3 минуты
      _kv server.online:n "$(awg show "$AWG_IF" latest-handshakes 2>/dev/null \
        | awk -v now="$(date +%s)" '$2 > 0 && now - $2 < 180' | wc -l)"
    fi
    _kv tunnels.warp "$(_api_tun warp_is_up "$WARP_CONF" "$USQUE_CONF")"
    _kv tunnels.xray "$(_api_tun xray_is_up "$XRAY_CONF")"
    _kv tunnels.tun2socks "$(_api_tun t2s_is_up "$T2S_CONF")"
    _kv tunnels.exits "$(_api_tun exits_is_up "$EXITS_DIR"/awg-exit-*.conf)"
    _kv tunnels.cascade:n "$(cascade_count)"
    if dns_installed; then _kv tunnels.dns "$(dns_running && echo up || echo off)"
    else _kv tunnels.dns none; fi
    if wgobf_installed; then _kv wgobf "$(wgobf_running && echo up || echo off)"; else _kv wgobf none; fi
    _kv bot.installed:b "$(_b bot_installed)"; _kv bot.active:b "$(_b unit_active "$BOT_UNIT")"
    _kv bot.version "$(bot_version)"
  } | api_obj
}

# ── Сервер ────────────────────────────────────────────────
_api_server() {
  local a="${1:-}" rc=0
  shift || true
  case "$a" in
    info)
      # Поддержка 3.1 — из кэша (модуль, tools и сборка в памяти не менялись):
      # server info зовут почти все экраны бота и панели, а проба на сервере
      # 2.0 — это пробный интерфейс на каждый вызов. Сервера ещё нет — мастеру
      # нужен тот же честный ответ, что и меню.
      proto31_cached || rc=$?
      {
        _kv installed:b "$(_b command -v awg)"; _kv exists:b "$(_b server_exists)"
        _kv proto31:b "$([[ $rc == 0 ]] && echo 1 || echo 0)"
        # Почему нет 3.1: components | tools | module | check (не прошла проба)
        _kv proto31_why "$([[ $rc == 0 ]] || proto_why 3.1)"
        _kv reboot "$(reboot_reason)"
        if server_exists; then
          _kv up:b "$(_b iface_up)"; _kv proto "$(server_proto)"
          _kv profile "$(server_profile)"; _kv profile_label "$(profile_label)"
          _kv port:n "$(server_port)"; _kv net "$(server_net)"; _kv mtu:n "$(conf_iface_get MTU)"
          _kv endpoint "$(endpoint_host):$(server_port)"; _kv domain "$(endpoint_domain)"
          _kv region "$(server_region)"; _kv mimicry "$(conf_marker AWG_MIMICRY)"
          _kv mimicry_domain "$(conf_marker AWG_MIMICRY_DOMAIN)"; _kv obf_level "$(conf_marker AWG_OBF_LEVEL)"
          _kv clients:n "$(client_files | grep -c . || true)"
        fi
      } | api_obj
      server_exists && proto_upgrade_hint
      return 0 ;;
    install) do_install ;;
    create)
      server_create_opts "$@" || return 1
      { _kv client "$S_FIRST_CLIENT"; _kv file "$(client_file "$S_FIRST_CLIENT")"; } | api_obj ;;
    restart) do_restart ;;
    params)
      server_exists || { err "Сервер не создан"; return 1; }
      local sub="${1:-}" k v
      shift || true
      case "$sub" in
        ""|check)
          params_check "$@" || return 1
          {
            _kv proto "$(server_proto)"; _kv mtu:n "$(conf_iface_get MTU)"
            _kv clients:n "$(client_files | grep -c . || true)"
            while IFS=$'\t' read -r k v; do _kv "values.$k" "$v"; done <<< "$PARAMS_KEYS"
            _kv errors:j "$(py json-list <<< "$PARAMS_ERR")"; _kv warnings:j "$(py json-list <<< "$PARAMS_WARN")"
            _kv changed:j "$(py json-list <<< "$PARAMS_CHANGED")"; _kv breaking:j "$(py json-list <<< "$PARAMS_BREAKING")"
          } | api_obj ;;
        set)
          server_params_set "$@" || return 1
          { _kv changed:j "$(py json-list <<< "$PARAMS_CHANGED")"; _kv breaking:j "$(py json-list <<< "$PARAMS_BREAKING")"
            _kv clients:n "$PARAMS_CLIENTS"; } | api_obj ;;
        *) _api_usage "server params [check|set [force]] [Ключ=значение...]" ;;
      esac ;;
    proto)
      [[ "${1:-}" =~ ^(2\.0|3\.1)$ ]] || { _api_usage "server proto 2.0|3.1"; return; }
      server_exists || { err "Сервер не создан"; return 1; }
      server_regen_params "$1" ;;
    repair)
      do_repair; rc=$?
      { _kv issues:n "$REPAIR_ISSUES"; _kv fixed:n "$REPAIR_FIXED"; } | api_obj
      return "$rc" ;;
    endpoint)
      [[ -n "${1:-}" ]] || { _api_usage "server endpoint ДОМЕН|ip [keep]"; return; }
      endpoint_set "$([[ "$1" == ip ]] || echo "$1")" "$([[ "${2:-}" == keep ]] && echo 0 || echo 1)" ;;
    reset) server_reset ;;
    reboot) server_reboot ;;
    *) _api_usage "server info|install|create [ключ=значение...]|restart|params [check|set [force]] [Ключ=значение...]|proto 2.0|3.1|repair|endpoint ДОМЕН|ip [keep]|reset|reboot" ;;
  esac
}

# ── Модуль ядра и amneziawg-tools ─────────────────────────
_api_module() {
  local a="${1:-}" f
  shift || true
  case "$a" in
    report)
      {
        _kv kernel "$(uname -r)"; _kv kernels:j "$(installed_kernels | py json-list)"
        _kv module "$(mod_tag)"; _kv tools "$(tools_tag)"; _kv loaded:b "$(_b mod_loaded)"
        _kv module_update "$(mod_update_available)"; _kv tools_update "$(tools_update_available)"
        _kv module_latest "$(upstream_latest mod)"; _kv tools_latest "$(upstream_latest tools)"
        _kv reboot "$(reboot_reason)"; _kv secure_boot:b "$(_b secure_boot_on)"
        _kv kernel_gap "$(kernel_gap_line)"
        _kv backups:n "$(mod_backups | grep -c . || true)"
      } | api_obj
      components_report ;;
    check)
      upstream_refresh || { err "Нет доступа к github.com — версии не проверены"; return 1; }
      { _kv module "$(upstream_latest mod)"; _kv tools "$(upstream_latest tools)"
        _kv module_update "$(mod_update_available)"; _kv tools_update "$(tools_update_available)"; } | api_obj
      ok "Модуль: $(upstream_latest mod), tools: $(upstream_latest tools)" ;;
    tags)
      upstream_tags "$MOD_REPO" | head -15 | api_list
      [[ -s "$API_DATA" && "$(cat "$API_DATA")" != "[]" ]] || { err "Список тегов не получен (нет доступа к github.com)"; return 1; } ;;
    update)
      local tag="" force=""
      for f in "$@"; do if [[ "$f" == force ]]; then force=force; else tag="$f"; fi; done
      [[ -z "$tag" || "$tag" =~ ^v?[0-9][0-9A-Za-z._-]*$ ]] || { err "Тег вида v3.1.20260906"; return 1; }
      mod_update_flow "$tag" "$force" ;;
    tools) tools_update_flow "${1:-}" ;;
    all) components_update_flow ;;
    reload) mod_reload ;;
    rebuild) mod_rebuild_all ;;
    backups)
      while IFS= read -r f; do printf '%s\t%s\t%s\n' "$f" "${f##*/}" "$(stat -c %Y "$f")"; done < <(mod_backups) \
        | api_rows path name time:n ;;
    rollback)
      [[ -n "${1:-}" ]] || { _api_usage "module rollback ФАЙЛ"; return; }
      mod_rollback "$1" ;;
    *) _api_usage "module report|check|tags|update [ТЕГ] [force]|tools [force]|all|reload|rebuild|backups|rollback ФАЙЛ" ;;
  esac
}

# ── Клиенты ───────────────────────────────────────────────
_api_clients() {
  local a="${1:-}" dump
  shift || true
  case "$a" in
    list|"")
      server_exists || { echo '[]' > "$API_DATA"; return 0; }
      mktmp dump || return 1
      awg show "$AWG_IF" dump > "$dump" 2>/dev/null || true
      py clients-json "$SERVER_CONF" "$dump" "$CLIENT_DIR" "$WARP_PEERS" "$XRAY_PEERS" "$EXITS_PEERS" "$TRAFFIC_DB" > "$API_DATA" ;;
    bulk) _api_clients_bulk "$@" ;;
    del) _api_clients_del "$@" ;;
    export)
      clients_export || return 1
      { _kv file "$EXPORT_PATH"; } | api_obj ;;
    purge-blocked) clients_purge_blocked ;;
    clean) clients_clean ;;
    *) _api_usage "clients list|bulk ИМЕНА|ПРЕФИКС:ЧИСЛО [ключ=значение...]|del ИМЯ,ИМЯ...|export|purge-blocked|clean" ;;
  esac
}

# clients del a,b,c — как «Удалить → Несколько по именам» в меню: копия
# awg0.conf рядом, затем по одному. data — список удалённых.
_api_clients_del() {
  local n pub names=() gone=() parts=()
  [[ -n "${1:-}" ]] || { _api_usage "clients del ИМЯ,ИМЯ..."; return; }
  server_exists || { err "Сервер не создан"; return 1; }
  IFS=',' read -r -a parts <<< "$1"
  for n in "${parts[@]}"; do
    n="${n// /}"
    [[ -n "$n" ]] && names+=("$n")
  done
  cp -a "$SERVER_CONF" "${SERVER_CONF}.pre_delete.$(date +%s)"
  for n in "${names[@]}"; do
    pub=$(client_pub "$n")
    if [[ -z "$pub" ]]; then warn "Нет клиента: $n"; continue; fi
    client_delete "$pub" && gone+=("$n")
  done
  printf '%s\n' "${gone[@]}" | py json-list > "$API_DATA"
  (( ${#gone[@]} )) || { err "Никого не удалил"; return 1; }
}

# Разбор «expire= mimicry= dns= mtu=» → переменные _O_*.
_O_EXPIRE="" _O_MIM="" _O_DNS="" _O_MTU=""
_api_client_opts() {
  local kv v
  _O_EXPIRE="" _O_MIM=server _O_DNS="1.1.1.1, 1.0.0.1" _O_MTU=""
  for kv in "$@"; do
    v="${kv#*=}"
    case "${kv%%=*}" in
      expire) if [[ -n "$v" ]]; then
                _O_EXPIRE=$(_api_ts "$v")
                [[ "$_O_EXPIRE" =~ ^[0-9]+$ ]] || { err "Срок не распознан: $v"; return 1; }
                (( _O_EXPIRE > $(date +%s) + 60 )) || { err "Срок уже прошёл: $v"; return 1; }
              fi ;;
      mimicry) _O_MIM="$v" ;;
      dns) valid_dns_list "$v" || { err "dns: IPv4 через запятую"; return 1; }; _O_DNS="$v" ;;
      mtu) [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1280 && v <= 1500 )) || { err "mtu: 1280-1500"; return 1; }
           _O_MTU="$v" ;;
      *) err "Неизвестный параметр: ${kv%%=*}"; return 1 ;;
    esac
  done
}

# clients bulk a,b,c | префикс:число [опции] — мимикрия генерируется один раз.
_api_clients_bulk() {
  local spec="${1:-}" names=() parts=() n i prefix count part addr created=()
  [[ -n "$spec" ]] || { _api_usage "clients bulk ИМЯ,ИМЯ... | ПРЕФИКС:ЧИСЛО [expire=] [mimicry=] [dns=] [mtu=]"; return; }
  shift
  server_exists || { err "Сервер не создан"; return 1; }
  _api_client_opts "$@" || return 1
  if [[ "$spec" =~ ^([A-Za-z0-9_-]{1,27}):([0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"; count="${BASH_REMATCH[2]}"
    (( count >= 1 && count <= 200 )) || { err "Число клиентов: 1-200"; return 1; }
    i=1
    while (( ${#names[@]} < count && i < 10000 )); do
      printf -v n '%s-%03d' "$prefix" "$i"
      _name_free "$n" && names+=("$n")
      i=$((i + 1))
    done
  else
    IFS=',' read -r -a parts <<< "$spec"
    for part in "${parts[@]}"; do
      n="${part//[[:space:]]/}"
      [[ -n "$n" ]] || continue
      if [[ " ${names[*]} " == *" $n "* ]] || ! _name_free "$n"; then warn "Пропущено: $n (занято или недопустимо)"; continue; fi
      names+=("$n")
    done
  fi
  (( ${#names[@]} )) || { err "Нет имён для создания"; return 1; }
  [[ -n "$_O_MTU" ]] || _O_MTU=$(conf_iface_get MTU)
  mimicry_from_spec "$_O_MIM" || return 1
  for n in "${names[@]}"; do
    addr=$(free_client_ip) || { warn "Подсеть заполнена — стоп"; break; }
    client_add "$n" "$addr" "$_O_DNS" "$_O_MTU" "$_O_EXPIRE" || { warn "$n: не создан"; continue; }
    ok "$n → $addr"
    created+=("$n")
  done
  printf '%s\n' "${created[@]}" | api_list
  (( ${#created[@]} )) || { err "Ни один клиент не создан"; return 1; }
  success_box "Создано клиентов: ${#created[@]} из ${#names[@]}"
}

_api_client() {
  local a="${1:-}" name="${2:-}" f
  [[ -n "$name" ]] || { _api_usage "client add|del|rename|conf|mimicry|expire|unexpire|limit|limit-reset ИМЯ ..."; return; }
  shift 2
  case "$a" in
    add)
      _api_client_opts "$@" || return 1
      client_create "$name" "$_O_EXPIRE" "$_O_MIM" "$_O_DNS" "$_O_MTU" || return 1
      f=$(client_file "$name")
      { _kv name "$name"; _kv file "$f"; _kv text:f "$f"; } | api_obj ;;
    del) client_remove "$name" ;;
    rename)
      [[ -n "${1:-}" ]] || { _api_usage "client rename СТАРОЕ НОВОЕ"; return; }
      client_rename "$name" "$1" ;;
    conf)
      f=$(client_file "$name")
      [[ -f "$f" ]] || { err "Нет конфига клиента $name"; return 1; }
      { _kv name "$name"; _kv file "$f"; _kv size:n "$(stat -c %s "$f")"; _kv text:f "$f"; } | api_obj ;;
    mimicry)
      [[ -n "${1:-}" ]] || { _api_usage "client mimicry ИМЯ none|server|профиль[:уровень[:домен[:бюджет]]]"; return; }
      client_set_mimicry "$name" "$1" || return 1
      f=$(client_file "$name")
      { _kv name "$name"; _kv file "$f"; _kv text:f "$f"; } | api_obj ;;
    expire)
      [[ -n "${1:-}" ]] || { _api_usage "client expire ИМЯ unix-время|+30d|+12h|дата"; return; }
      client_expire_set "$name" "$(_api_ts "$1")" ;;
    unexpire) client_expire_clear "$name" ;;
    limit)
      [[ -n "${1:-}" ]] || { _api_usage "client limit ИМЯ 50G|500M|off [month|total]"; return; }
      client_limit_set "$name" "$1" "${2:-month}" ;;
    limit-reset) client_limit_reset "$name" ;;
    *) _api_usage "client add|del|rename|conf|mimicry|expire|unexpire|limit|limit-reset ИМЯ ..." ;;
  esac
}

_api_mimicry() {
  local i id label hint
  for i in "${MIMICRY_INFO[@]}"; do
    IFS='|' read -r id label hint <<< "$i"
    printf '%s\t%s\t%s\t%s\n' "$id" "$label" "$hint" "$(_profile_needs_domain "$id" && echo 1 || echo 0)"
  done | api_rows id label hint domain:b
}

# ── Трафик по дням ────────────────────────────────────────
_api_traffic() {
  local tr wtr name="" days=30
  case "${1:-}" in
    daily)
      # Два аргумента — всегда «ИМЯ|all ДНЕЙ»: имя клиента может быть числом
      if (( $# >= 3 )); then name="$2"; [[ "$3" =~ ^[0-9]+$ ]] && days="$3"
      elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then days="$2"
      else name="${2:-}"; fi
      [[ "$name" == all ]] && name=""
      server_exists || { err "Сервер не создан"; return 1; }
      mktmp tr || return 1
      awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
      py traffic-daily "$SERVER_CONF" "$TRAFFIC_DB" "$tr" "$name" "$days" > "$API_DATA" ;;
    now)
      # Счётчики прямо сейчас — панель считает по ним живую скорость:
      # клиенты awg0 и отдельно клиенты WG + обфускатора (wgobf0)
      server_exists || { err "Сервер не создан"; return 1; }
      mktmp tr || return 1
      mktmp wtr || return 1
      awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
      if wgobf_installed; then wg show "$WGOBF_IF" transfer > "$wtr" 2>/dev/null || true; fi
      py traffic-now "$SERVER_CONF" "$tr" "$WGOBF_WG_CONF" "$wtr" > "$API_DATA" ;;
    *) _api_usage "traffic daily [ИМЯ|all] [ДНЕЙ] | now" ;;
  esac
}

# ── Диагностика ───────────────────────────────────────────
_api_diag() {
  case "${1:-}" in
    status) do_status ;;
    domains) domains_check "$([[ "${2:-}" == ru ]] && echo ru || echo world)" ;;
    sniff-list) _sniff_candidates | api_rows name endpoint ;;
    sniff)
      [[ -n "${2:-}" ]] || { _api_usage "diag sniff ИМЯ"; return; }
      sniff_client "$2" ;;
    dpi-hint) do_client_dpi_hint ;;
    *) _api_usage "diag status|domains world|ru|sniff-list|sniff ИМЯ|dpi-hint" ;;
  esac
}

# ── Бэкапы ────────────────────────────────────────────────
_api_backup() {
  local a="${1:-}" p
  shift || true
  case "$a" in
    create)
      backup_create archive "${1:-}" "${2:-}" || return 1
      { _kv path "$BACKUP_PATH"; _kv size:n "$(stat -c %s "$BACKUP_PATH")"; } | api_obj ;;
    list)
      while IFS= read -r p; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$p" "${p##*/}" "$([[ -d "$p" ]] && echo 1 || echo 0)" \
          "$(stat -c %Y "$p")" "$(du -sb "$p" 2>/dev/null | cut -f1)"
      done < <(_restore_list) | api_rows path name full:b time:n size:n ;;
    inspect)
      [[ -n "${1:-}" ]] || { _api_usage "backup inspect ПУТЬ"; return; }
      _restore_prepare "$1" || return 1
      { _kv clients:n "$(find "$RESTORE_SRC" -maxdepth 1 -name '*_awg[23].conf' | grep -c . || true)"
        _kv wgobf:b "$(_b test -d "$RESTORE_SRC/wgobf/etc")"
        _kv tunnels:b "$(_b test -f "$RESTORE_SRC/tunnels.tar.gz")"
        _kv warp:b "$(_b test -d "$RESTORE_SRC/warp")"
        _kv meta:f "$RESTORE_SRC/backup_meta.txt"; } | api_obj ;;
    restore)
      [[ -n "${1:-}" ]] || { _api_usage "backup restore ПУТЬ [wgobf] [tunnels]"; return; }
      backup_restore "$@" ;;
    *) _api_usage "backup create [auto [ХРАНИТЬ]]|list|inspect ПУТЬ|restore ПУТЬ [wgobf] [tunnels]" ;;
  esac
}

# ── Туннели ───────────────────────────────────────────────
_api_tunnels() {
  local file name ip on
  case "${1:-}" in
    status|"")
      { _kv warp "$(_api_tun warp_is_up "$WARP_CONF" "$USQUE_CONF")"
        _kv xray "$(_api_tun xray_is_up "$XRAY_CONF")"
        _kv tun2socks "$(_api_tun t2s_is_up "$T2S_CONF")"
        _kv exits "$(_api_tun exits_is_up "$EXITS_DIR"/awg-exit-*.conf)"
        _kv cascade:n "$(cascade_count)"
        if dns_installed; then _kv dns "$(dns_running && echo up || echo off)"; else _kv dns none; fi
        _kv active "$(tunnel_conflict none)"; } | api_obj ;;
    panic) tunnels_panic_reset quiet; ok "Туннели выключены — клиенты идут напрямую" ;;
    clients)
      case "${2:-}" in
        warp) file="$WARP_PEERS" ;; xray) file="$XRAY_PEERS" ;;
        *) _api_usage "tunnels clients warp|xray"; return ;;
      esac
      # Списка ещё нет — туннель при включении возьмёт всех клиентов
      clients_name_ip | while IFS='|' read -r name ip; do
        if [[ ! -f "$file" ]] || peers_has "$file" "$ip"; then on=1; else on=0; fi
        printf '%s\t%s\t%s\n' "$name" "$ip" "$on"
      done | api_rows name ip on:b ;;
    client)
      [[ -n "${3:-}" ]] || { _api_usage "tunnels client warp|xray ИМЯ|all|none [on|off]"; return; }
      tunnel_client "$2" "$3" "${4:-}" ;;
    *) _api_usage "tunnels status|panic|clients warp|xray|client warp|xray ИМЯ|all|none [on|off]" ;;
  esac
}

_api_warp() {
  local a="${1:-}" be
  shift || true
  be=$(warp_backend)
  case "$a" in
    status)
      { _kv backend "$be"; _kv up:b "$(_b warp_is_up)"
        _kv configured:b "$([[ -f "$WARP_CONF" || -s "$USQUE_CONF" ]] && echo 1 || echo 0)"
        _kv failed:b "$(_b test -f "$WARP_STATE.failed")"
        _kv health:b "$(_b unit_active awg-warp-healthcheck.timer)"
        _kv wg_possible:b "$(_b warp_wg_possible)"; _kv usque_possible:b "$(_b warp_usque_possible)"; } | api_obj
      warp_status ;;
    install) if [[ "$be" == wg ]]; then warp_wg_install; else warp_usque_install; fi ;;
    up) warp_up ;;
    down) warp_down ;;
    restart) warp_down quiet; warp_up ;;
    health)
      case "${1:-}" in
        on) warp_health_on ;; off) warp_health_off; ok "Health-check выключен" ;;
        *) _api_usage "warp health on|off" ;;
      esac ;;
    license)
      [[ -n "${1:-}" ]] || { _api_usage "warp license КЛЮЧ"; return; }
      [[ "$be" == wg ]] || { err "Warp+ — только для бэкенда wg"; return 1; }
      warp_license_set "$1" ;;
    import)
      [[ "$be" == wg ]] || { err "Импорт профиля — только для бэкенда wg"; return 1; }
      _api_stdin
      [[ -s "$API_IN" ]] || { err "Профиль wgcf-profile.conf передаётся через stdin"; return 1; }
      warp_import < "$API_IN" ;;
    endpoint) warp_endpoint_best "${1:-}" ;;
    backend)
      [[ "${1:-}" =~ ^(wg|usque)$ ]] || { _api_usage "warp backend wg|usque"; return; }
      warp_set_backend "$1" ;;
    remove) warp_uninstall ;;
    *) _api_usage "warp status|install|up|down|restart|health on|off|license КЛЮЧ|import (stdin)|endpoint [СТРАНА]|backend wg|usque|remove" ;;
  esac
}

_api_xray() {
  local a="${1:-}"
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b xray_installed)"; _kv up:b "$(_b xray_is_up)"
        _kv version "$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
        _kv mode "$(xray_state_get tun_mode)"
        _kv tags:j "$(xray_tags | py json-list)"
        _kv balancer "$(xray_installed && py xray-balancer-get "$XRAY_CONF" 2>/dev/null || echo off)"
        _kv main "$(xray_installed && py xray-main-get "$XRAY_CONF" 2>/dev/null)"
        _kv per_client:b "$(xray_installed && _b xray_tun_supported || echo 0)"
        _kv clients:j "$(xray_client_outs | py json-rows name ip out)"
        _kv ru:b "$(_b xray_ru_on)"; } | api_obj
      xray_status ;;
    install) xray_install update ;;
    add)
      [[ -n "${1:-}" ]] || { _api_usage "xray add ССЫЛКА"; return; }
      xray_add_link "$1" ;;
    del)
      [[ -n "${1:-}" ]] || { _api_usage "xray del ТЕГ"; return; }
      xray_del_tag "$1" ;;
    balancer)
      [[ "${1:-}" =~ ^(random|roundRobin|leastPing|leastLoad|off)$ ]] \
        || { _api_usage "xray balancer random|roundRobin|leastPing|leastLoad|off"; return; }
      xray_installed || { err "Xray не установлен"; return 1; }
      xray_balancer "$1" ;;
    main)
      [[ -n "${1:-}" ]] || { _api_usage "xray main ТЕГ"; return; }
      xray_main_set "$1" ;;
    client)
      [[ -n "${2:-}" ]] || { _api_usage "xray client ИМЯ ТЕГ|default"; return; }
      xray_client_out "$1" "$2" ;;
    up) xray_up ;;
    down) xray_down ;;
    restart) xray_restart ;;
    ru)
      [[ "${1:-}" =~ ^(on|off)$ ]] || { _api_usage "xray ru on|off"; return; }
      xray_ru_set "$1" ;;
    ru-update) xray_ru_update ;;
    diag) xray_diagnose ;;
    fix) xray_fix ;;
    remove) xray_uninstall ;;
    *) _api_usage "xray status|install|add ССЫЛКА|del ТЕГ|balancer СТРАТЕГИЯ|main ТЕГ|client ИМЯ ТЕГ|default|up|down|restart|ru on|off|ru-update|diag|fix|remove" ;;
  esac
}

_api_t2s() {
  case "${1:-}" in
    status) { _kv up:b "$(_b t2s_is_up)"; _kv proxy "$(t2s_proxy)"; } | api_obj ;;
    up) t2s_up "${2:-}" ;;
    down) t2s_down ;;
    remove) t2s_uninstall ;;
    *) _api_usage "t2s status|up [IP:ПОРТ]|down|remove" ;;
  esac
}

_api_exits() {
  local a="${1:-}" n
  shift || true
  case "$a" in
    status)
      { _kv up:b "$(_b exits_is_up)"; _kv mode "$(exits_state_get mode)"
        _kv balancer "$(exits_state_get balancer)"; _kv single "$(exits_state_get single_exit)"
        _kv nodes:j "$(while IFS= read -r n; do
                          printf '%s\t%s\n' "$n" "$(_b ip link show "awg-exit-$n")"
                        done < <(exits_nodes) | py json-rows name up:b)"; } | api_obj
      exits_status; exits_list ;;
    add)
      [[ -n "${1:-}" ]] || { _api_usage "exits add ИМЯ < конфиг"; return; }
      _api_stdin
      [[ -s "$API_IN" ]] || { err "Конфиг ноды передаётся через stdin"; return 1; }
      exits_node_add "$1" "$API_IN" || return 1
      exits_reapply ;;
    del)
      [[ -n "${1:-}" ]] || { _api_usage "exits del ИМЯ"; return; }
      exits_node_del "$1" ;;
    up) exits_up "${1:-}" ;;
    down) exits_down ;;
    balance)
      [[ -n "${1:-}" ]] || { _api_usage "exits balance single НОДА|ecmp"; return; }
      exits_balance "$1" "${2:-}" ;;
    mode) exits_mode "${1:-}" ;;
    client)
      # all / none без второго аргумента — все клиенты; с ним — клиент с таким именем
      [[ "${1:-}" == all || "${1:-}" == none || -n "${2:-}" ]] || { _api_usage "exits client ИМЯ off|shared|НОДА | all | none"; return; }
      exits_client "$1" "${2:-}" ;;
    *) _api_usage "exits status|add ИМЯ (stdin)|del ИМЯ|up [all|peers]|down|mode all|peers|balance single НОДА|ecmp|client ИМЯ off|shared|НОДА|all|none" ;;
  esac
}

_api_cascade() {
  local a="${1:-}" p in dst out cm on
  shift || true
  case "$a" in
    list)
      cascade_rules | while IFS='|' read -r p in dst out cm; do
        on=0
        iptables-save -t nat 2>/dev/null | grep -qE -- "$(cascade_tag "$p" "$in")\"?( |$)" && on=1
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$in" "$dst" "$out" "$cm" "$on"
      done | api_rows proto in:n dst out:n comment applied:b ;;
    add)
      [[ -n "${3:-}" ]] || { _api_usage "cascade add udp|tcp|both ПОРТ IP [ПОРТ_ЦЕЛИ] [КОММЕНТАРИЙ]"; return; }
      cascade_rule_add "$1" "$2" "$3" "${4:-$2}" "${*:5}" ;;
    del)
      [[ -n "${2:-}" ]] || { _api_usage "cascade del udp|tcp ПОРТ"; return; }
      cascade_rule_del "$1" "$2" ;;
    reapply) cascade_reapply ;;
    clear) cascade_clear ;;
    remove) cascade_uninstall quiet ;;
    diag) cascade_diagnose ;;
    *) _api_usage "cascade list|add ...|del ПРОТО ПОРТ|reapply|clear|remove|diag" ;;
  esac
}

_api_dns() {
  local a="${1:-}" i
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b dns_installed)"; _kv running:b "$(_b dns_running)"
        _kv intercept:b "$(_b dns_rules_ok)"
        _kv upstream "$(sed -n 's/^server_names[[:space:]]*=[[:space:]]*//p' "$DNS_PROXY_CONF" 2>/dev/null | tr -d "[]'\"" | head -1)"
        _kv presets:j "$(for i in "${DNS_PRESETS[@]}"; do printf '%s\t%s\n' "${i%%|*}" "${i#*|}"; done | py json-rows names label)"
      } | api_obj
      dns_status ;;
    install) dns_install "${1:-}" ;;
    restart) dns_restart ;;
    upstream)
      [[ -n "${1:-}" ]] || { _api_usage "dns upstream ИМЯ[,ИМЯ...]"; return; }
      dns_set_upstream "$*" ;;
    remove) dns_uninstall "${1:-}" ;;
    *) _api_usage "dns status|install [force]|restart|upstream ИМЕНА|remove [purge]" ;;
  esac
}

_api_wgobf() {
  local a="${1:-}" name dir f dump now pub ip hs rx tx
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b wgobf_installed)"; _kv running:b "$(_b wgobf_running)"
        _kv version "$WGOBF_VERSION"
        if wgobf_installed; then
          _kv endpoint "$(wgobf_get ENDPOINT):$(wgobf_get PORT)"; _kv masking "$(wgobf_get MASKING)"
          _kv clean:b "$(wgobf_get ALLOW_CLEAN)"; _kv clients:n "$(wgobf_clients | grep -c . || true)"
        fi; } | api_obj
      wgobf_installed && wgobf_status
      return 0 ;;
    install) wgobf_install_opts "$@" ;;
    clients)
      wgobf_installed || { echo '[]' > "$API_DATA"; return 0; }
      dump=$(wg show "$WGOBF_IF" dump 2>/dev/null | tail -n +2 || true); now=$(date +%s)
      while IFS= read -r name; do
        pub=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^PublicKey = / {print $3; exit}' "$WGOBF_WG_CONF")
        ip=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^AllowedIPs = / {print $3; exit}' "$WGOBF_WG_CONF")
        # Рукопожатие и трафик с подъёма wgobf0 (счётчики WireGuard)
        hs="" rx="" tx=""          # у нового клиента строки в dump нет: прошлый не тянется
        read -r hs rx tx < <(awk -v k="$pub" '$1 == k {print $5, $6, $7; exit}' <<< "$dump") || true
        [[ "${hs:-}" =~ ^[0-9]+$ ]] && (( hs > 0 )) && hs=$((now - hs)) || hs=""
        [[ "${rx:-}" =~ ^[0-9]+$ ]] || rx=0; [[ "${tx:-}" =~ ^[0-9]+$ ]] || tx=0
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${ip%/32}" "$hs" "$rx" "$tx"
      done < <(wgobf_clients) | api_rows name ip ago:n rx:n tx:n ;;
    add|del|bundle)
      name="${1:-}"
      [[ -n "$name" ]] || { _api_usage "wgobf $a ИМЯ"; return; }
      wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
      case "$a" in
        add) wgobf_add_client "$name" || return 1 ;;
        del) wgobf_delete_client "$name"; return ;;
        bundle) wgobf_clients | grep -qxF "$name" || { err "Клиента $name нет"; return 1; } ;;
      esac
      dir="$WGOBF_CLIENTS/$name"
      [[ -f "$dir/phobos-link.txt" && -f "$dir/keenetic.txt" ]] || wgobf_write_bundle "$name" || return 1
      { _kv name "$name"; _kv dir "$dir"; _kv phobos:f "$dir/phobos-link.txt"
        _kv files:j "$(for f in wg.conf obfuscator.conf wg-direct.conf phobos.conf keenetic.txt README.txt install-linux.sh; do
                          [[ -f "$dir/$f" ]] && printf '%s\t%s\n' "$f" "$dir/$f"
                        done | py json-rows name path)"; } | api_obj ;;
    restart) wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
             wgobf_restart && ok "Перезапущено" ;;
    masking) wgobf_set_masking "${1:-}" ;;
    clean) wgobf_set_clean "${1:-}" ;;
    rotate-key) wgobf_rotate_key ;;
    remove) wgobf_remove quiet ;;
    *) _api_usage "wgobf status|install [ключ=значение...]|clients|add|del|bundle ИМЯ|restart|masking STUN|NONE|clean 0|1|rotate-key|remove" ;;
  esac
}

# ── Обновление, бот, удаление ─────────────────────────────
_api_update() {
  local a="${1:-}" v c
  shift || true
  case "$a" in
    status)
      v=$(update_available || true)
      { _kv version "$VERSION_SHOW"; _kv channel "$UPDATE_CHANNEL"; _kv repo "$UPDATE_REPO"
        _kv available "$v"; } | api_obj ;;
    check)
      v=$(update_peek) || { err "Канал обновлений недоступен ($UPDATE_REPO)"; return 1; }
      { _kv version "$VERSION_SHOW"; _kv latest "$v"; _kv channel "$UPDATE_CHANNEL"
        _kv newer:b "$( (( 10#$(ver_num "$v") > 10#$(ver_num "$VERSION") )) && echo 1 || echo 0)"; } | api_obj
      info "Текущая: $VERSION, в канале: $v" ;;
    install)
      update_fetch || return 1
      update_install "${1:-}" || return 1
      # Служебные скрипты перегенерирует уже новая версия
      v="$SCRIPT_PATH"; [[ -f "$v" ]] || v="$API_SELF"
      "$v" api version >/dev/null 2>&1 || true
      { _kv version "$UPDATE_NEW"; } | api_obj ;;
    channel)
      update_channel_set "${1:-}" || return 1
      ok "Канал: $(update_channel_label)" ;;
    changelog)
      update_changelog_fetch || { err "Список изменений недоступен ($UPDATE_REPO)"; return 1; }
      # В CHANGELOG канала версия новее, чем помнит кэш проверки (он живёт до
      # часа), — спросить канал сейчас: иначе «Доступна» и кнопка показали бы
      # прошлую версию, а обновление поставило бы новую
      v=$(grep -m1 -oE '^## v[0-9]+\.[0-9]+\.[0-9]+' <<< "$UPDATE_CHANGELOG" | cut -c4-)
      c=$(awk '{print $1; exit}' "$UPDATE_CACHE" 2>/dev/null)
      [[ "$c" =~ ^v?[0-9]+\.[0-9]+ ]] || c="v0.0.0"
      if [[ -n "$v" ]] && (( 10#$(ver_num "$v") > 10#$(ver_num "$c") )); then update_peek >/dev/null || true; fi
      py changelog-json "$VERSION" "$(update_available || true)" <<< "$UPDATE_CHANGELOG" > "$API_DATA" ;;
    *) _api_usage "update status|check|install [force]|channel stable|beta|changelog" ;;
  esac
}

_api_bot() {
  local a="${1:-}" line
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b bot_installed)"; _kv active:b "$(_b unit_active "$BOT_UNIT")"
        _kv version "$(bot_version)"; _kv proxy "$(bot_proxy_mask "$(bot_proxy_get)")"; } | api_obj ;;
    restart) unit_active "$BOT_UNIT" || { err "Бот не запущен"; return 1; }; bot_restart ;;
    update) bot_installed || { err "Бот не установлен"; return 1; }; bot_install ;;
    proxy)
      case "${1:-}" in
        get) { _kv proxy "$(bot_proxy_mask "$(bot_proxy_get)")"; } | api_obj ;;
        check)
          line=$(bot_proxy_get)
          [[ -n "$line" ]] || { info "Прокси не задан — бот ходит напрямую"; return 0; }
          if bot_proxy_probe "$line"; then ok "Через прокси Telegram отвечает"
          else err "Через прокси Telegram не отвечает"; return 1; fi ;;
        candidates)
          while IFS= read -r line; do
            printf '%s\t%s\t%s\n' "${line%%|*}" "${line#*|}" "$([[ "$line" == *"НЕ отвечает" ]] && echo 0 || echo 1)"
          done < <(_bot_proxy_candidates) | api_rows url label ok:b ;;
        set)
          [[ -n "${2:-}" ]] || { _api_usage "bot proxy set URL [force]"; return; }
          bot_proxy_set "$2" "${3:-}" ;;
        clear) bot_proxy_set "" ;;
        *) _api_usage "bot proxy get|check|candidates|set URL [force]|clear" ;;
      esac ;;
    webapp)
      case "${1:-}" in
        get) { _kv port "$(webapp_port)"; _kv url "$(webapp_url || true)"; } | api_obj ;;
        port) webapp_port_set "${2:-}" ;;
        *) _api_usage "bot webapp get|port ПОРТ|off" ;;
      esac ;;
    uninstall) bot_uninstall quiet ;;
    *) _api_usage "bot status|restart|update|proxy ...|webapp ...|uninstall" ;;
  esac
}

# ── HTTPS-сертификат ──────────────────────────────────────
_api_cert() {
  local a="${1:-status}"
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b cert_installed)"; _kv kind "$(cert_get kind)"; _kv name "$(cert_get name)"
        _kv source "$(cert_get source)"
        _kv expires:n "$(cert_expires)"; _kv renew:b "$(_b unit_enabled "$CERT_TIMER")"
        _kv port80 "$(cert_port80_holder)"; _kv port80_unit "$(cert_port80_unit)"
        _kv found:n "$(cert_find | grep -c . || true)"; _kv ip "$(public_ip_cached)"; } | api_obj ;;
    find) cert_find | api_rows name source cert key expires:n ;;
    use)
      [[ -n "${1:-}" ]] || { _api_usage "cert use ПУТЬ_СЕРТИФИКАТА (из cert find)"; return; }
      cert_use "$1" && webapp_fw ;;
    issue) cert_issue "$@" && webapp_fw ;;
    remove) cert_remove ;;
    *) _api_usage "cert status|find|use ПУТЬ|issue ip [pause]|issue domain ИМЯ [pause]|remove" ;;
  esac
}

# ── Веб-панель ────────────────────────────────────────────
# Пароль в ответе — только новый, сгенерированный здесь (install, password):
# на сервере лежит лишь его хеш, прежний показать нельзя.
_api_web_access() {
  { _kv url "$(web_url)"; _kv user "$(web_conf_get WEB_USER)"; _kv password "${WEB_PASS_SHOWN:-}"; } | api_obj
}

_api_web() {
  local a="${1:-status}"
  shift || true
  case "$a" in
    status)
      { _kv installed:b "$(_b web_installed)"; _kv active:b "$(_b web_active)"
        if web_installed; then
          _kv url "$(web_url)"; _kv user "$(web_conf_get WEB_USER)"; _kv port:n "$(web_conf_get WEB_PORT)"
        fi
        _kv cert:b "$(_b cert_installed)"; _kv cert_name "$(cert_get name)"; _kv cert_expires:n "$(cert_expires)"
      } | api_obj ;;
    install)
      web_installed && { err "Веб-панель уже установлена — новый пароль: web password"; return 1; }
      web_install_auto && _api_web_access ;;
    password) web_password_new && _api_web_access ;;
    path) web_path_new && _api_web_access ;;
    restart|start)
      web_installed || { err "Веб-панель не установлена"; return 1; }
      web_restart ;;
    stop) web_stop ;;
    remove) web_installed || { err "Веб-панель не установлена"; return 1; }; web_remove quiet ;;
    *) _api_usage "web status|install|password|path|restart|start|stop|remove" ;;
  esac
}

# ── Антисканер ────────────────────────────────────────────
_api_antiscan_lists() {  # id<TAB>подпись<TAB>включён<TAB>записей
  local id file label min n on f
  while IFS=$'\t' read -r id file label min; do
    f="$ANTISCAN_DIR/lists/$id.list" n=0 on=0
    [[ -f "$f" ]] && n=$(( $(_antiscan_parse 4 < "$f" | wc -l) + $(_antiscan_parse 6 < "$f" | wc -l) ))
    [[ " $(_antiscan_enabled_lists) " == *" $id "* ]] && on=1
    printf '%s\t%s\t%s\t%s\n' "$id" "$label" "$on" "$n"
  done < <(_antiscan_lists)
}

_api_antiscan() {
  local a="${1:-status}" e on=0
  shift || true
  case "$a" in
    status)
      read -r -a e <<< "$(_antiscan_get ENTRIES)"
      antiscan_on && on=1
      { _kv enabled:b "$on"; _kv active:b "$( (( on )) && _b antiscan_rules_ok || echo 0)"
        _kv v4:n "${e[0]:-0}"; _kv v6:n "${e[1]:-0}"
        _kv updated:n "$(_antiscan_get UPDATED)"; _kv error "$(_antiscan_get ERROR)"
        _kv dropped:n "$( (( on )) && antiscan_dropped || echo 0)"
        _kv lists:j "$(_api_antiscan_lists | py json-rows id name on:b entries:n)"
        _kv top:j "$( (( on )) && antiscan_top 5 | py json-rows packets:n net org || echo '[]')"
        _kv allow:j "$(_antiscan_allow_rows | py json-list)"
        _kv ssh:j "$(_antiscan_ssh_peers | py json-list)"
      } | api_obj ;;
    on) antiscan_enable ;;
    off) antiscan_disable ;;
    update) antiscan_update ;;
    lists) antiscan_lists_set "$@" ;;
    allow) antiscan_allow "$@" ;;
    *) _api_usage "antiscan status|on|off|update|lists scan,skipa,gov|allow add|del АДРЕС" ;;
  esac
}

_api_uninstall() {
  local o
  for o in "$@"; do [[ "$o" =~ ^(bot|wgobf|web|self)$ ]] || { _api_usage "uninstall [bot] [wgobf] [web] [self]"; return; }; done
  uninstall_all "$@"
}

# ── Журналы ───────────────────────────────────────────────
_api_log() {
  local name="${1:-}" n="${2:-60}" file="" unit=""
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 500 )) || n=60
  case "$name" in
    manager) file="$LOG_FILE" ;;         install) file="$INSTALL_LOG" ;;
    module) file="$MOD_LOG" ;;           expire) file="$EXPIRE_LOG" ;;
    cascade) file="$CASCADE_LOG" ;;      warp-health) file="$WARP_HEALTH_LOG" ;;
    dns-health) file="$DNS_HEALTH_LOG" ;; usque) file="$USQUE_LOG" ;;
    awg) unit="awg-quick@$AWG_IF" ;;     warp) unit=awg-warp.service ;;
    xray) unit="$XRAY_UNIT" ;;           xray-routing) unit="$XRAY_ROUTING_UNIT" ;;
    tun2socks) unit="$T2S_UNIT" ;;       exits) unit="$EXITS_UNIT" ;;
    dns) unit="$DNS_UNIT" ;;             wgobf) unit="$WGOBF_UNIT" ;;
    bot) unit="$BOT_UNIT" ;;             web) file="$WEB_LOG" ;;
    antiscan) file="$ANTISCAN_LOG" ;;
    *) _api_usage "log manager|install|module|expire|cascade|warp-health|dns-health|usque|awg|warp|xray|xray-routing|tun2socks|exits|dns|wgobf|bot|web|antiscan [строк]"; return ;;
  esac
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || { info "Журнала $file нет"; return 0; }
    tail -n "$n" "$file"
  else
    journalctl -u "$unit" -n "$n" --no-pager 2>/dev/null || { info "Журнал $unit недоступен"; return 0; }
  fi
}

# ── Фоновые задачи ────────────────────────────────────────
_api_job_unit() { echo "awg2-job-$1"; }

_api_job_start() {
  local id dir unit envs=()
  (( $# )) || { _api_usage "job start КОМАНДА [аргументы]"; return; }
  [[ "$1" == job ]] && { err "Задача не запускает задачи"; return 2; }
  mkdir -p "$API_JOBS" && chmod 700 "$API_JOBS"
  # Старые завершённые задачи — через 3 дня
  find "$API_JOBS" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true
  id="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $((RANDOM % 65536)))"
  dir="$API_JOBS/$id"
  mkdir -m 700 "$dir" || return 1
  printf '%s\0' "$@" > "$dir/cmd"
  if _api_wants_stdin "$@"; then _api_stdin; cp "$API_IN" "$dir/stdin"; fi
  : > "$dir/log"
  unit=$(_api_job_unit "$id")
  { _kv id "$id"; _kv cmd "$*"; _kv started:n "$(date +%s)"; _kv unit "$unit"; } | py json-kv > "$dir/meta.json"
  [[ -n "${AWG2_UPDATE_CHANNEL:-}" ]] && envs+=("--setenv=AWG2_UPDATE_CHANNEL=$AWG2_UPDATE_CHANNEL")
  if command -v systemd-run &>/dev/null \
     && systemd-run --unit="$unit" --collect --quiet --description="awg2: $*" ${envs[@]+"${envs[@]}"} \
          "$API_SELF" api job run "$id" &>/dev/null; then
    :
  else
    # Без systemd (контейнер) — отдельной сессией, чтобы пережить вызвавшего
    setsid "$API_SELF" api job run "$id" </dev/null &>/dev/null 8>&- &
    echo "$!" > "$dir/pid"
  fi
  { _kv id "$id"; _kv unit "$unit"; } | api_obj
  ok "Задача $id: $*"
}

_api_job_active() {  # id → 0, если задача ещё выполняется
  local pid
  if [[ -f "$API_JOBS/$1/pid" ]]; then
    # Не просто kill -0: после перезагрузки PID может достаться чужому процессу,
    # и задача числилась бы «идёт» вечно.
    pid=$(cat "$API_JOBS/$1/pid")
    [[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "api job run $1"
  else
    unit_active "$(_api_job_unit "$1")"
  fi
}

_api_job() {
  local a="${1:-}" id="${2:-}" active=() d
  case "$a" in
    start) shift; _api_job_start "$@" ;;
    status)
      [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ && -d "$API_JOBS/$id" ]] || { err "Задачи ${id:-?} нет"; return 1; }
      py api-job-status "$API_JOBS/$id" "${3:-0}" "$(_b _api_job_active "$id")" > "$API_DATA" ;;
    list)
      for d in "$API_JOBS"/*/; do
        d="${d%/}"; d="${d##*/}"
        [[ -d "$API_JOBS/$d" ]] || continue
        [[ -f "$API_JOBS/$d/result.json" ]] || ! _api_job_active "$d" || active+=("$d")
      done
      py api-jobs "$API_JOBS" ${active[@]+"${active[@]}"} > "$API_DATA" ;;
    *) _api_usage "job start КОМАНДА...|status ID [СМЕЩЕНИЕ]|list" ;;
  esac
}

# ── Диспетчер ─────────────────────────────────────────────
# Команды только для чтения идут мимо очереди: сводка не должна ждать,
# пока задача собирает модуль.
_api_readonly() {
  local a="${1:-}" b="${2:-}" c="${3:-}"
  # Разделы, где всё — чтение (задача job start сама идёт через замок, когда запустится)
  case "$a" in status|version|help|mimicry|log|job|diag) return 0 ;; esac
  # Дальше — точные команды по словам, а не маски по строке: лишнее слово в
  # конце или слово с пробелом внутри («allow add X info») чтением не станут.
  # Пишущие подкоманды «читающих» разделов (bot proxy set, bot webapp port,
  # server params set — правят общие файлы) сюда не попадают — в очередь.
  [[ "$a $b" != *[[:space:]]*[[:space:]]* ]] || return 1
  case "$a $b $c" in
    "server params "|"server params check"|"bot proxy get"|"bot proxy check"|"bot proxy candidates"|"bot webapp get") return 0 ;;
  esac
  case "$a $b" in
    "server info"|"module report"|"module tags"|"module check"|"module backups"|"clients "|"clients list"|\
    "client conf"|"traffic daily"|"traffic now"|"backup list"|"backup inspect"|"tunnels "|"tunnels status"|\
    "tunnels clients"|"warp status"|"xray status"|"xray diag"|"t2s status"|"exits status"|"cascade list"|\
    "cascade diag"|"dns status"|"wgobf status"|"wgobf clients"|"update status"|"update check"|"update changelog"|\
    "bot status"|"cert "|"cert status"|"cert find"|"web status"|"antiscan status") return 0 ;;
  esac
  return 1
}

_api_lock() {
  local wait="${API_LOCK_WAIT:-20}" holder
  mkdir -p "$STATE_DIR"
  exec 8>>"$API_LOCK" || return 0
  if ! flock -w "$wait" 8; then
    holder=$(cat "$API_LOCK.info" 2>/dev/null)
    err "Идёт другая операция${holder:+ ($holder)} — повтори, когда она закончится"
    return 75
  fi
  printf '%s\n' "$*" > "$API_LOCK.info" 2>/dev/null || true
}

api_dispatch() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    version) { _kv version "$VERSION_SHOW"; _kv api:n "$API_VERSION"; _kv channel "$UPDATE_CHANNEL"
               _kv update "$(update_available || true)"; } | api_obj ;;
    status) _api_status ;;
    server) _api_server "$@" ;;
    module) _api_module "$@" ;;
    clients) _api_clients "$@" ;;
    client) _api_client "$@" ;;
    mimicry) _api_mimicry ;;
    traffic) _api_traffic "$@" ;;
    diag) _api_diag "$@" ;;
    backup) _api_backup "$@" ;;
    tunnels) _api_tunnels "$@" ;;
    warp) _api_warp "$@" ;;
    xray) _api_xray "$@" ;;
    t2s) _api_t2s "$@" ;;
    exits) _api_exits "$@" ;;
    cascade) _api_cascade "$@" ;;
    dns) _api_dns "$@" ;;
    wgobf) _api_wgobf "$@" ;;
    update) _api_update "$@" ;;
    bot) _api_bot "$@" ;;
    cert) _api_cert "$@" ;;
    web) _api_web "$@" ;;
    antiscan) _api_antiscan "$@" ;;
    uninstall) _api_uninstall "$@" ;;
    log) _api_log "$@" ;;
    job) _api_job "$@" ;;
    help)
      echo "Разделы: status server module clients client mimicry traffic diag backup tunnels warp xray t2s"
      echo "         exits cascade dns wgobf update bot cert web antiscan uninstall log job version"
      echo "Подсказка по разделу: awg2 api РАЗДЕЛ" ;;
    *) err "Неизвестная команда: $cmd — awg2 api help"; return 2 ;;
  esac
}

# Подготовка задачи: команда, stdin и журнал — из её каталога.
_api_job_prepare() {
  local dir="$API_JOBS/${1:-}"
  [[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ && -f "$dir/cmd" ]] || return 1
  mapfile -d '' -t API_ARGS < "$dir/cmd"
  [[ -f "$dir/stdin" ]] && cp "$dir/stdin" "$API_IN"
  API_STDIN_READ=1
  API_LOG="$dir/log"
  API_RESULT="$dir/result.json"
  API_LOCK_WAIT=3600
}

api_main() {
  local rc=0 envelope
  AUTO_MODE=1 API_MODE=1
  API_SELF=$(readlink -f "$0")
  API_JOBS="$STATE_DIR/jobs" API_LOCK="$STATE_DIR/api.lock"
  if ! command -v python3 &>/dev/null; then
    echo '{"ok": false, "rc": 1, "data": null, "log": "", "error": "нет python3"}'
    return 1
  fi
  mktmp API_DATA && mktmp API_IN || { echo '{"ok": false, "rc": 1, "data": null, "log": "", "error": "mktemp"}'; return 1; }
  if [[ "${1:-}" == job && "${2:-}" == run ]]; then
    _api_job_prepare "${3:-}" || { echo '{"ok": false, "rc": 2, "data": null, "log": "", "error": "нет такой задачи"}'; return 2; }
  else
    mktmp API_LOG || return 1
    API_ARGS=("$@")
  fi

  # 3 — настоящий stdout для ответа, 4 — настоящий stdin для _api_stdin
  exec 3>&1 4<&0 >>"$API_LOG" 2>&1 </dev/null
  update_channel_init
  if ! need_cmds curl:curl iptables:iptables ip:iproute2 ss:iproute2 >/dev/null; then
    err "Не удалось поставить базовые пакеты (curl, iptables, iproute2)"; rc=1
  else
    helpers_refresh || true
    expire_watchdog || true
    antiscan_watchdog || true
    if _api_readonly "${API_ARGS[@]}"; then
      api_dispatch "${API_ARGS[@]}" || rc=$?
    else
      _api_lock "${API_ARGS[*]}" || rc=$?
      (( rc )) || { api_dispatch "${API_ARGS[@]}" || rc=$?; }
      log_info "api: ${API_ARGS[*]} → $rc"
    fi
  fi
  exec 1>&3 3>&- 4<&-

  envelope=$(py api-envelope "$rc" "$API_DATA" "$API_LOG")
  if [[ -n "$API_RESULT" ]]; then
    printf '%s\n' "$envelope" | write_file "$API_RESULT" 600
  else
    printf '%s\n' "$envelope"
  fi
  return "$rc"
}
