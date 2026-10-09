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

web_write_unit() {
  write_unit "$WEB_UNIT" <<EOF
[Unit]
Description=AWG Toolza — веб-панель
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_VENV_PY -m awgbot.web
Environment=AWG_WEB_CONF=$WEB_CONF AWG_WEB_LOG=$WEB_LOG AWG2_BIN=$SCRIPT_PATH AWG_BOT_CONF=$BOT_CONF PYTHONUNBUFFERED=1
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
  web_restart && web_show_access
}

web_remove() {
  if [[ "${1:-}" != quiet ]]; then
    read_confirm "${R}  Удалить веб-панель? (введи yes): ${N}" || return 0
  fi
  remove_unit "$WEB_UNIT"
  systemctl daemon-reload
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
    echo -e "  ${C}s)${N} $(web_active && echo "Остановить" || echo "Запустить")"
    echo -e "  ${C}u)${N} Обновить код панели ${D}— из архива или канала${N}"
    echo -e "  ${R}d)${N} Удалить веб-панель"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 9 0 "s|u|d"
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
      s) if web_active; then web_stop || true; else web_restart || true; fi ;;
      u) web_code_install && web_restart || true ;;
      d) web_remove; return 0 ;;
      0) return 0 ;;
    esac
    pause
  done
}
