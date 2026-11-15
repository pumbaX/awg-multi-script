# Веб-панель: та же панель, что Mini App бота, но в браузере по логину и
# паролю (служба awg-web, код — awg_bot: python -m awgbot.web). Telegram-бот
# ей не нужен: код и venv ставит тот же установщик с --web-only.
#
# Адрес — https://IP-или-домен:порт/<секретный путь>/; всё остальное на этом
# порту — 404. Пароль хранится только хешем scrypt в $WEB_CONF (600).
# Сертификат — тот же, что у Mini App (/etc/awg2/cert: Let's Encrypt на IP или
# домен, готовый сертификат сервера); его нет — самоподписанный.

web_installed() { [[ -f "/etc/systemd/system/$WEB_UNIT" ]]; }
web_active() { unit_active "$WEB_UNIT"; }
web_code_ready() { [[ -x "$BOT_VENV_PY" && -f "$BOT_DIR/awgbot/web.py" ]]; }

web_conf_get() { sed -n "s/^$1=//p" "$WEB_CONF" 2>/dev/null | tail -1; }
web_conf_set() {  # KEY значение
  { grep -v "^$1=" "$WEB_CONF" 2>/dev/null || true; echo "$1=$2"; } | write_file "$WEB_CONF" 600
}

web_host() { if cert_installed; then cert_get name; else public_ip_cached; fi; }
web_url() {
  local p path
  p=$(web_conf_get WEB_PORT); path=$(web_conf_get WEB_PATH)
  [[ -n "$p" && -n "$path" ]] || return 1
  echo "https://$(web_host):$p/$path/"
}

web_random_path() { tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 14; }
web_port_busy() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
web_random_port() {
  local p i
  for (( i = 0; i < 50; i++ )); do
    p=$(( RANDOM % 40000 + 20000 ))
    web_port_busy "$p" || { echo "$p"; return 0; }
  done
  return 1
}

# Пароль без эха; EOF — пусто
_read_secret() {
  local __var="$1" __v=""
  _flush_stdin
  IFS= read -rs -p "$(echo -e "$2")" __v || __v=""
  echo >&2
  printf -v "$__var" '%s' "$__v"
}

# Спросить пароль (Enter — сгенерировать) → WEB_NEW_HASH; сгенерированный — в WEB_PASS_SHOWN
web_ask_password() {
  local a b
  WEB_PASS_SHOWN="" WEB_NEW_HASH=""
  while true; do
    _read_secret a "${C}  Пароль (от 10 символов, Enter — сгенерировать): ${N}"
    [[ -n "$a" ]] || { web_gen_password; return; }
    (( ${#a} >= 10 )) || { warn "Нужно не меньше 10 символов"; continue; }
    # Вход принимает до 256 символов — длиннее не войти никогда
    (( ${#a} <= 256 )) || { warn "Не больше 256 символов"; continue; }
    _read_secret b "${C}  Ещё раз: ${N}"
    [[ "$a" == "$b" ]] && break
    warn "Пароли не совпали"
  done
  WEB_NEW_HASH=$(printf '%s' "$a" | py web-hash) && [[ "$WEB_NEW_HASH" == scrypt\$* ]]
}

# Новый случайный пароль → WEB_PASS_SHOWN (показать один раз) и WEB_NEW_HASH
web_gen_password() {
  WEB_PASS_SHOWN=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 18)
  [[ ${#WEB_PASS_SHOWN} -eq 18 ]] || return 1
  WEB_NEW_HASH=$(printf '%s' "$WEB_PASS_SHOWN" | py web-hash) && [[ "$WEB_NEW_HASH" == scrypt\$* ]]
}

# Код и venv панели: из распакованного архива (рядом, /root, /home) или из
# канала обновлений. Бот при этом не ставится и не трогается.
web_code_install() {
  local src installer
  src=$(_bot_local_src || true)
  if [[ -n "$src" && -f "$src/awgbot/web.py" && -f "${src%/awg_bot}/awg-bot-install.sh" ]]; then
    info "Код панели: $(shown "$src")"
    bash "${src%/awg_bot}/awg-bot-install.sh" --src "$src" --web-only
    return
  fi
  update_offer_beta
  # Свой каталог (700): рядом с установщиком он ищет awg_bot/ (см. bot_install)
  mktmp installer -d || return 1
  installer+="/awg-bot-install.sh"
  curl -fsSL "$BOT_INSTALL_URL" -o "$installer" || { err "Не скачался установщик: $BOT_INSTALL_URL"; return 1; }
  if ! grep -q -- '--web-only' "$installer"; then
    err "В канале $(update_channel_label) веб-панели ещё нет — поставь её из архива с панелью"
    return 1
  fi
  AWG_REPO_URL="https://github.com/$UPDATE_REPO" bash "$installer" --web-only
}

# ── Доступ к панели: для всех, по адресам или только через VPN ──
# WEB_ACCESS=all|ip|vpn, WEB_ALLOW — адреса и подсети через запятую (режим ip;
# при переключении на другой режим список хранится). Свой VPN (подсети awg0 и
# WG + обфускатора) пускаем в обоих ограниченных режимах: сменился адрес дома —
# зайти можно через VPN; SSH и Telegram-бот работают всегда.
# Два слоя. Файрвол: правило DROP новых подключений к порту панели не из
# набора ipset — первым в INPUT, раньше UFW; антисканер DROP выше себя
# допускает, и оба правила друг друга не двигают. Сама панель: тот же список
# в $WEB_NETS_FILE — чужим 404, даже если правило кто-то снял (ufw reset,
# netfilter-persistent).
_web_fw_nets() {  # → подсети, которым можно, по одной на строку
  local mode e n
  mode=$(sed -n 's/^WEB_ACCESS=//p' "$WEB_CONF" 2>/dev/null | tail -1)
  if [[ "$mode" == ip ]]; then
    for e in $(sed -n 's/^WEB_ALLOW=//p' "$WEB_CONF" 2>/dev/null | tail -1 | tr ',' ' '); do
      if valid_cidr "$e" || [[ "$e" =~ ^[0-9a-f:]+/[0-9]{1,3}$ && "$e" == *:* ]]; then echo "$e"; fi
    done
  fi
  n=$(server_net 2>/dev/null) && echo "$n"
  n=$(sed -n 's/^NET=//p' "$WGOBF_STATE" 2>/dev/null | head -1)
  if valid_cidr "$n"; then echo "$n"; fi
  return 0
}

_web_fw_set() {  # набор inet|inet6 подсети — атомарно: новый под временным именем, затем swap
  local tmp="$1-new"
  { echo "create $tmp hash:net family $2 -exist"; echo "flush $tmp"
    if [[ -n "$3" ]]; then sed "s|^|add $tmp |; s|\$| -exist|" <<< "$3"; fi
  } | ipset restore || { ipset destroy "$tmp" &>/dev/null; return 1; }
  ipset create "$1" hash:net family "$2" -exist || return 1
  ipset swap "$tmp" "$1" && ipset destroy "$tmp"
}

_web_fw_del() {  # iptables|ip6tables — наши правила, с каким бы портом ни стояли
  local rule rules
  command -v "$1" &>/dev/null || return 0
  rules=$("$1" -S INPUT 2>/dev/null | grep -E -- "--comment \"?$WEB_FW_TAG\"?( |\$)") || return 0
  while IFS= read -r rule; do
    printf '%s\n' "${rule/#-A /-D }" | xargs "$1" 2>/dev/null || true
  done <<< "$rules"
}

# apply — поставить по конфигу (режим «для всех» — снять); down — снять;
# check — всё на месте (0) или надо apply (1): сама панель раз в 5 минут
# возвращает правило, если его сбросили, и обновляет список, если сменилась
# подсеть VPN (новый сервер, обфускатор поставили или удалили).
# apply и down — по одному (замок): apply из awg2 и из сторожа панели разом
# снимали бы правило друг у друга и ставили по своему — вышло бы два DROP.
web_fw_run() {  # apply|down|check
  local fd="" rc=0
  [[ "${1:-}" == check ]] && { _web_fw_run check; return; }
  if command -v flock &>/dev/null && mkdir -p "${WEB_NETS_FILE%/*}" 2>/dev/null \
     && chmod 700 "${WEB_NETS_FILE%/*}" && { exec {fd}>>"$WEB_NETS_FILE.lock"; } 2>/dev/null; then
    flock -w 60 "$fd" || echo "замок правила занят дольше 60 с — без него" >&2
  fi
  _web_fw_run "$@" || rc=$?
  [[ -z "$fd" ]] || exec {fd}>&-
  return "$rc"
}

_web_fw_run() {  # apply|down|check
  local mode port nets rule
  mode=$(sed -n 's/^WEB_ACCESS=//p' "$WEB_CONF" 2>/dev/null | tail -1)
  port=$(sed -n 's/^WEB_PORT=//p' "$WEB_CONF" 2>/dev/null | tail -1)
  rule=(! -i lo -p tcp --dport "$port" -m conntrack --ctstate NEW -m set ! --match-set)
  if [[ "${1:-}" == check ]]; then
    if [[ "$mode" != ip && "$mode" != vpn ]]; then
      [[ ! -e "$WEB_NETS_FILE" ]] && ! grep -qE -- "--comment \"?$WEB_FW_TAG\"?( |\$)" <<< "$(iptables -S INPUT 2>/dev/null)"
      return
    fi
    nets=$(_web_fw_nets | grep .)
    [[ "$(cat "$WEB_NETS_FILE" 2>/dev/null)" == "$nets" ]] || return 1
    # Нет ipset — правила нет и не будет, адреса проверяет сама панель: apply не поможет
    command -v ipset &>/dev/null || return 0
    ipset list -n "$WEB_SET" &>/dev/null \
      && iptables -C INPUT "${rule[@]}" "$WEB_SET" src -m comment --comment "$WEB_FW_TAG" -j DROP 2>/dev/null
    return
  fi
  if [[ "${1:-apply}" != apply || ( "$mode" != ip && "$mode" != vpn ) ]]; then
    _web_fw_del iptables; _web_fw_del ip6tables
    ipset destroy "$WEB_SET" &>/dev/null; ipset destroy "$WEB_SET6" &>/dev/null
    rm -f "$WEB_NETS_FILE"
    return 0
  fi
  # Сначала список для самой панели: она проверяет адрес и без файрвола
  nets=$(_web_fw_nets)
  mkdir -p "$(dirname "$WEB_NETS_FILE")" && chmod 700 "$(dirname "$WEB_NETS_FILE")"
  printf '%s\n' "$nets" | grep . | write_file "$WEB_NETS_FILE" 600
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || { echo "порт панели не задан" >&2; return 1; }
  command -v ipset &>/dev/null || { echo "нет ipset — адреса проверяет только сама панель" >&2; return 1; }
  _web_fw_set "$WEB_SET" inet "$(grep -v : <<< "$nets")" || { echo "ipset: набор не загрузился" >&2; return 1; }
  _web_fw_del iptables
  iptables -I INPUT 1 "${rule[@]}" "$WEB_SET" src -m comment --comment "$WEB_FW_TAG" -j DROP \
    || { echo "iptables: правило не поставилось" >&2; return 1; }
  # IPv6: своих адресов в списке нет — новые подключения к порту по IPv6 не пускаем вовсе
  if command -v ip6tables &>/dev/null && _web_fw_set "$WEB_SET6" inet6 "$(grep : <<< "$nets")"; then
    _web_fw_del ip6tables
    ip6tables -I INPUT 1 "${rule[@]}" "$WEB_SET6" src -m comment --comment "$WEB_FW_TAG" -j DROP 2>/dev/null \
      || echo "ip6tables: правило не поставилось" >&2
  fi
  return 0
}

_web_fw_emit() {
  emit_script "$WEB_FW_SCRIPT" 'web_fw_run "$@"' WEB_CONF WEB_NETS_FILE WEB_SET WEB_SET6 WEB_FW_TAG WGOBF_STATE \
    write_file "${RT_FUNCS[@]}" _web_fw_nets _web_fw_set _web_fw_del _web_fw_run web_fw_run || return 1
  # Как антисканер — раньше UFW и netfilter-persistent: если правило сохранили
  # в iptables-persistent, при загрузке его набор уже есть и восстановление не
  # падает целиком. После них правило возвращает сама служба панели (ExecStartPre)
  write_unit "$WEB_FW_UNIT" <<EOF
[Unit]
Description=AWG Toolza — доступ к веб-панели: по адресам или только через VPN
DefaultDependencies=no
Wants=network-pre.target local-fs.target
After=local-fs.target systemd-modules-load.service
Before=network-pre.target ufw.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-$WEB_FW_SCRIPT apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable "$WEB_FW_UNIT" &>/dev/null || true
}

# Подсети VPN сменились (сервер AWG или обфускатор поставлены, удалены,
# восстановлены): список и правило панели — сразу, а не через ≤5 минут
# проверки самой панели. Удалён последний VPN при доступе «только через VPN» —
# режим не меняется: снаружи панель закрыта, пока VPN не появится снова (новый
# сервер — и она сама откроется через него); владелец предупреждён, открыть
# раньше — из бота или SSH. Ослаблять доступ молча нельзя: «сбросить и создать
# сервер заново» тихо оставило бы панель открытой для всех.
# Сбой здесь установку и удаление не останавливает.
web_vpn_changed() {
  web_installed || return 0
  [[ "$(web_access_mode)" != all ]] || return 0
  if [[ "$(web_access_mode)" == vpn && -z "$(server_net 2>/dev/null)" ]] && ! wgobf_installed; then
    warn "Веб-панель: VPN на сервере не осталось, а доступ — «только через VPN»: снаружи она закрыта"
    warn "Появится VPN — откроется через него. Открыть раньше: бот → Веб-панель → Доступ или sudo awg2 api web access all"
    log_warn "веб-панель: VPN не осталось при доступе «только через VPN» — снаружи закрыта"
  fi
  # Не встало (нет ipset и т. п.) — список для самой панели уже записан, правило вернёт её сторож
  web_fw_run apply &>/dev/null || log_warn "веб-панель: правило доступа после смены VPN не встало"
  return 0
}

web_access_mode() {
  local m
  m=$(web_conf_get WEB_ACCESS)
  if [[ "$m" == ip || "$m" == vpn ]]; then echo "$m"; else echo all; fi
}

web_access_allow() { web_conf_get WEB_ALLOW | tr ',' '\n' | grep .; }

# Подсети своего VPN: awg0 и WG + обфускатор
web_vpn_nets() {
  local n
  n=$(server_net 2>/dev/null) && echo "$n"
  n=$(wgobf_get NET 2>/dev/null)
  if valid_cidr "$n"; then echo "$n"; fi
  return 0
}

# Адрес панели изнутри VPN: адрес awg0 (нет AWG — wgobf0) вместо внешнего
# (сертификат выписан на внешний — браузер предупредит, трафик и так внутри VPN)
web_vpn_url() {
  local a p path
  a=$(conf_iface_get Address 2>/dev/null); a="${a%%,*}"; a="${a%/*}"
  if ! valid_ip "$a"; then a=$(conf_iface_get Address "$WGOBF_WG_CONF" 2>/dev/null); a="${a%%,*}"; a="${a%/*}"; fi
  p=$(web_conf_get WEB_PORT); path=$(web_conf_get WEB_PATH)
  valid_ip "$a" && [[ -n "$p" && -n "$path" ]] || return 1
  echo "https://$a:$p/$path/"
}

web_access_label() {
  case "$(web_access_mode)" in
    ip) echo "по адресам ($(web_access_allow | grep -c . || true)) и через VPN" ;;
    vpn) echo "только через VPN" ;;
    *) echo "для всех" ;;
  esac
}

# Адреса и подсети (через запятую или пробел) → нормализованный список через
# запятую в WEB_ACCESS_LIST; неверные — в WEB_ACCESS_BAD
_web_access_parse() {
  local e n
  local -a items
  WEB_ACCESS_LIST="" WEB_ACCESS_BAD=""
  # read -a, а не $(...) без кавычек: «*» не должна раскрыться в имена файлов текущего каталога
  IFS=' ' read -ra items <<< "$(printf '%s ' "$@" | tr ',;\n\t' '    ')"
  for e in "${items[@]}"; do
    n=$(printf '%s\n' "${e,,}" | _antiscan_parse 4 1; printf '%s\n' "${e,,}" | _antiscan_parse 6 1)
    if [[ -z "$n" ]]; then WEB_ACCESS_BAD+="${WEB_ACCESS_BAD:+, }$e"
    elif [[ ",$WEB_ACCESS_LIST," != *",$n,"* ]]; then WEB_ACCESS_LIST+="${WEB_ACCESS_LIST:+,}$n"; fi
  done
}

# Адрес попадает в список (через запятую) или в свой VPN
_web_access_covers() {  # список адрес
  local raw tmp
  mktmp raw && mktmp tmp || return 1
  { server_net 2>/dev/null; sed -n 's/^NET=//p' "$WGOBF_STATE" 2>/dev/null | head -1; tr ',' '\n' <<< "$1"; } > "$raw"
  { _antiscan_parse 4 1 < "$raw"; _antiscan_parse 6 1 < "$raw"; } > "$tmp"
  _antiscan_covers "$tmp" "$2"
}

# Доступ: all | vpn | ip АДРЕС... (для ip — список целиком). Из веб-панели
# (AWG_CLIENT_IP — адрес её запроса) режим, который отрезал бы этот адрес,
# не ставится: панель закрылась бы сама от себя.
web_access_set() {
  local mode="${1:-}" me
  shift || true
  WEB_ACCESS_LIST=""
  web_installed || { err "Веб-панель не установлена"; return 1; }
  case "$mode" in
    all|vpn) ;;
    ip) _web_access_parse "$@"
        [[ -z "$WEB_ACCESS_BAD" ]] || { err "Не адрес или слишком широкая подсеть: $WEB_ACCESS_BAD"; return 1; }
        [[ -n "$WEB_ACCESS_LIST" ]] || { err "Нужен хотя бы один адрес или подсеть"; return 1; } ;;
    *) err "Доступ: all | vpn | ip АДРЕС..."; return 1 ;;
  esac
  if [[ "$mode" == vpn && -z "$(server_net 2>/dev/null)" ]] && ! wgobf_installed; then
    err "VPN на сервере ещё нет — через него панель не открыть"; return 1
  fi
  me=$(_antiscan_client_ip)
  # С самого сервера (127.0.0.1, ::1) панель открывается всегда
  [[ "$me" == 127.* || "$me" == ::1 ]] && me=""
  if [[ -n "$me" && "$mode" != all ]] && ! _web_access_covers "$([[ "$mode" != ip ]] || echo "$WEB_ACCESS_LIST")" "$me"; then
    if [[ "$mode" == vpn ]]; then err "Ты зашёл не через VPN ($me) — после этого панель для тебя закроется. Подключись к VPN и открой $(web_vpn_url || echo 'адрес awg0')"
    else err "Твой адрес $me не попадает в список — добавь его, иначе панель для тебя закроется"; fi
    return 1
  fi
  if [[ "$mode" != all ]] && ! command -v ipset &>/dev/null; then
    need_cmds ipset:ipset >/dev/null 2>&1 || warn "ipset не поставился — адреса проверяет только сама панель"
  fi
  web_conf_set WEB_ACCESS "$mode" || return 1
  [[ "$mode" != ip ]] || web_conf_set WEB_ALLOW "$WEB_ACCESS_LIST" || return 1
  _web_fw_emit || true
  web_fw_run apply || warn "Файрвол: правило не встало — адреса проверяет сама панель"
  log_info "веб-панель: доступ $mode${WEB_ACCESS_LIST:+ ($WEB_ACCESS_LIST)}"
  ok "Доступ к веб-панели: $(web_access_label)"
  [[ "$mode" == all ]] || info "Через VPN: $(web_vpn_url || echo 'адрес awg0, порт и путь панели')"
}

web_access_menu() {
  local c v me cur
  echo ""
  hdr "Доступ к веб-панели"
  echo -e "  Сейчас : ${W}$(web_access_label)${N}"
  cur=$(web_access_allow | paste -sd, - | sed 's/,/, /g')
  [[ -n "$cur" ]] && echo -e "  Адреса : ${D}$cur${N}"
  web_vpn_url &>/dev/null && echo -e "  Из VPN : ${D}$(web_vpn_url) — браузер предупредит о сертификате (он на внешний адрес)${N}"
  echo -e "  ${D}SSH и Telegram-бот работают всегда — вернуть «для всех» можно отсюда или из бота.${N}"
  echo -e "  ${C}1)${N} Для всех"
  echo -e "  ${C}2)${N} Только с моих адресов ${D}— и через VPN${N}"
  echo -e "  ${C}3)${N} Только через VPN"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор [0-3]: ${N}" 0 3 0
  case "$c" in
    1) web_access_set all ;;
    2) read_line v "${C}  Адреса и подсети через запятую${cur:+ (Enter — оставить)}: ${N}"
       [[ -n "$v" ]] || v="$cur"
       # Адрес этой SSH-сессии — предложить, если его нет в списке: так чаще всего и заходят
       me=$(_antiscan_ssh_peers | head -1)
       if [[ -n "$me" ]]; then
         _web_access_parse "$v"
         if ! _web_access_covers "$WEB_ACCESS_LIST" "$me" && ask_yes "  Добавить адрес этой SSH-сессии $me? [Y/n]: " y; then v="$v,$me"; fi
       fi
       [[ -n "${v//[ ,]/}" ]] || { warn "Список пуст"; return 0; }
       web_access_set ip "$v" ;;
    3) web_access_set vpn ;;
  esac
}

web_write_unit() {
  write_unit "$WEB_UNIT" <<EOF
[Unit]
Description=AWG Toolza — веб-панель
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
# Правило доступа — до старта панели: при загрузке оно встаёт после UFW и
# выше его. Не встало — панель всё равно стартует и проверяет адреса сама
ExecStartPre=-$WEB_FW_SCRIPT apply
ExecStart=$BOT_VENV_PY -m awgbot.web
Environment=AWG_WEB_CONF=$WEB_CONF AWG_WEB_LOG=$WEB_LOG AWG2_BIN=$SCRIPT_PATH AWG_BOT_CONF=$BOT_CONF PYTHONUNBUFFERED=1
Environment=AWG_WEB_FW=$WEB_FW_SCRIPT AWG_WEB_NETS=$WEB_NETS_FILE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

web_restart() {
  local i
  systemctl enable "$WEB_UNIT" &>/dev/null || true
  systemctl restart "$WEB_UNIT" || true
  for (( i = 0; i < 8; i++ )); do sleep 1; web_active && break; done
  if web_active; then ok "Веб-панель работает"
  else err "Веб-панель не запустилась: journalctl -u ${WEB_UNIT%.service} -n 30"; return 1; fi
}

web_show_access() {
  success_box "Веб-панель: $(web_url)"
  echo -e "  Логин : ${W}$(web_conf_get WEB_USER)${N}"
  [[ -n "${WEB_PASS_SHOWN:-}" ]] && echo -e "  Пароль: ${W}$WEB_PASS_SHOWN${N} ${D}— сохрани: на сервере только хеш, больше не покажу${N}"
  cert_installed || warn "Сертификата нет — панель на самоподписанном, браузер предупредит. Настоящий: пункты «Сертификат»"
  return 0
}

_web_code_ensure() {
  web_code_ready && return 0
  web_code_install || return 1
  web_code_ready || { err "Код веб-панели не установился (нет $BOT_DIR/awgbot/web.py)"; return 1; }
}

web_install() {
  local user v
  _web_code_ensure || return 1
  user=$(web_conf_get WEB_USER)
  while true; do
    read_line v "${C}  Логин [Enter = ${user:-admin}]: ${N}"
    v="${v:-${user:-admin}}"
    [[ "$v" =~ ^[A-Za-z0-9._-]{3,32}$ ]] && break
    warn "Логин: 3-32 символа — латиница, цифры, . _ -"
  done
  user="$v"
  web_ask_password || { err "Пароль не захеширован"; return 1; }
  _web_setup "$user" && web_show_access
}

# Без вопросов (бот): логин — прежний или admin, пароль — новый случайный,
# его показывают один раз (WEB_PASS_SHOWN).
web_install_auto() {
  local user
  _web_code_ensure || return 1
  user=$(web_conf_get WEB_USER)
  web_gen_password || { err "Пароль не захеширован"; return 1; }
  _web_setup "${user:-admin}"
}

# Логин и хеш пароля, порт и секретный путь (прежние или случайные), UFW, служба.
_web_setup() {  # логин
  local user="$1" port path
  port=$(web_conf_get WEB_PORT); [[ -n "$port" ]] || port=$(web_random_port) || { err "Нет свободного порта"; return 1; }
  path=$(web_conf_get WEB_PATH); [[ -n "$path" ]] || path=$(web_random_path)
  web_conf_set WEB_USER "$user"
  web_conf_set WEB_PASS "$WEB_NEW_HASH"
  web_conf_set WEB_PORT "$port"
  web_conf_set WEB_PATH "$path"
  ufw_allow "$port/tcp" awg-web
  _web_fw_emit || return 1
  web_write_unit
  web_restart || return 1
  log_info "веб-панель установлена: порт $port"
}

# Новый случайный пароль; все сессии завершаются (служба перезапускается).
web_password_new() {
  web_installed || { err "Веб-панель не установлена"; return 1; }
  web_gen_password || { err "Пароль не захеширован"; return 1; }
  web_conf_set WEB_PASS "$WEB_NEW_HASH" && web_restart || return 1
  log_info "веб-панель: новый пароль"
  ok "Пароль сменён, все сессии завершены"
}

# Новый секретный путь: прежний адрес перестаёт открываться.
web_path_new() {
  web_installed || { err "Веб-панель не установлена"; return 1; }
  web_conf_set WEB_PATH "$(web_random_path)" && web_restart || return 1
  log_info "веб-панель: новый путь"
}

web_stop() {
  systemctl disable --now "$WEB_UNIT" &>/dev/null || { err "Веб-панель не остановилась"; return 1; }
  ok "Веб-панель остановлена"
}

web_set_port() {
  local v old
  old=$(web_conf_get WEB_PORT)
  read_line v "${C}  Порт (1024-65535, Enter — случайный): ${N}"
  [[ -n "$v" ]] || v=$(web_random_port) || return 1
  # 10#: «010000» — не восьмеричное 4096, а 10000 (так его прочтут Python и ufw)
  [[ "$v" =~ ^[0-9]{1,9}$ ]] && v=$((10#$v)) && (( v >= 1024 && v <= 65535 )) || { err "Порт: 1024-65535"; return 1; }
  [[ "$v" == "$old" ]] && return 0
  web_port_busy "$v" && { err "Порт $v занят"; return 1; }
  [[ "$v" == "$(server_port 2>/dev/null)" || "$v" == "$(webapp_port)" ]] && { err "Порт $v занят AWG или Mini App"; return 1; }
  web_conf_set WEB_PORT "$v"
  ufw_delete_comment awg-web
  ufw_allow "$v/tcp" awg-web
  "$WEB_FW_SCRIPT" apply &>/dev/null || true
  web_restart && web_show_access
}

web_remove() {
  if [[ "${1:-}" != quiet ]]; then
    read_confirm "${R}  Удалить веб-панель? (введи yes): ${N}" || return 0
  fi
  remove_unit "$WEB_UNIT" "$WEB_FW_UNIT"
  web_fw_run down
  rm -f "$WEB_FW_SCRIPT"
  rm -rf "$WEB_CONF" "$WEB_DIR" "$WEB_LOG"
  ufw_delete_comment awg-web
  # Код и venv ставились только ради панели — бот их не использует
  if [[ ! -f "/etc/systemd/system/$BOT_UNIT" ]]; then rm -rf "$BOT_DIR" /var/lib/awg-bot; fi
  ok "Веб-панель удалена"
  log_info "веб-панель удалена"
}

do_web_menu() {
  local c v n st
  while true; do
    echo ""
    hdr "Веб-панель"
    echo -e "  ${D}Все разделы Тулзы в браузере — вход по логину и паролю, без Telegram.${N}"
    if ! web_installed; then
      echo -e "  Статус     : ${D}не установлена${N}"
      echo ""
      echo -e "  ${G}1)${N} Установить"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-1]: ${N}" 0 1 0
      case "$c" in
        1) web_install || true ;;
        0) return 0 ;;
      esac
      pause
      continue
    fi
    if web_active; then st="${G}● работает${N}"; else st="${R}○ остановлена${N}"; fi
    echo -e "  Статус     : $st"
    echo -e "  Адрес      : ${W}$(web_url)${N}"
    echo -e "  Логин      : $(web_conf_get WEB_USER)"
    echo -e "  Доступ     : $(web_access_label)"
    if cert_installed; then echo -e "  Сертификат : $(cert_state_line)"
    else echo -e "  Сертификат : ${Y}самоподписанный${N} ${D}— браузер предупреждает; настоящий — пункты 6-8${N}"; fi
    echo ""
    n=$(cert_find | grep -c . || true)
    echo -e "  ${C}1)${N} Перезапустить"
    echo -e "  ${C}2)${N} Сменить пароль"
    echo -e "  ${C}3)${N} Сменить логин"
    echo -e "  ${C}4)${N} Порт ${D}— $(web_conf_get WEB_PORT)${N}"
    echo -e "  ${C}5)${N} Новый секретный путь ${D}— старый адрес перестанет открываться${N}"
    echo -e "  ${C}6)${N} Сертификат на IP ${D}— Let's Encrypt, $(public_ip_cached)${N}"
    echo -e "  ${C}7)${N} Сертификат на домен"
    echo -e "  ${C}8)${N} Готовый сертификат сервера ${D}— найдено $n${N}"
    echo -e "  ${C}9)${N} Журнал входов"
    echo -e "  ${C}a)${N} Доступ ${D}— $(web_access_label)${N}"
    echo -e "  ${C}s)${N} $(web_active && echo "Остановить" || echo "Запустить")"
    echo -e "  ${C}u)${N} Обновить код панели ${D}— из архива или канала${N}"
    echo -e "  ${R}d)${N} Удалить веб-панель"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 9 0 "a|s|u|d"
    case "$c" in
      1) web_restart || true ;;
      2) web_ask_password && web_conf_set WEB_PASS "$WEB_NEW_HASH" && web_restart \
           && { ok "Пароль сменён, все сессии завершены"; [[ -n "$WEB_PASS_SHOWN" ]] \
           && echo -e "  Пароль: ${W}$WEB_PASS_SHOWN${N} ${D}— сохрани, больше не покажу${N}"; } ;;
      3) read_line v "${C}  Новый логин: ${N}"
         if [[ "$v" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then web_conf_set WEB_USER "$v" && web_restart && ok "Логин: $v"
         elif [[ -n "$v" ]]; then warn "Логин: 3-32 символа — латиница, цифры, . _ -"; fi ;;
      4) web_set_port || true ;;
      5) web_path_new && web_show_access ;;
      6) _cert_issue_menu ip ;;
      7) read_line v "${C}  Домен (A-запись → $(public_ip_cached)): ${N}"
         [[ -n "$v" ]] && _cert_issue_menu domain "$v" ;;
      8) _cert_use_menu ;;
      9) if [[ -s "$WEB_LOG" ]]; then tail -n 30 "$WEB_LOG"; else info "Журнал пуст"; fi ;;
      a) web_access_menu || true ;;
      s) if web_active; then web_stop || true; else web_restart || true; fi ;;
      u) web_code_install && web_restart || true ;;
      d) web_remove; return 0 ;;
      0) return 0 ;;
    esac
    pause
  done
}
