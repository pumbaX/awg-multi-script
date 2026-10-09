# Telegram-бот управления: установка (awg-bot-install.sh из того же канала,
# что и awg2), запуск, журнал, прокси до Telegram API, полное удаление.
# Сам бот — отдельная программа (awg_bot/), с awg2 он общается через CLI.

BOT_ARTIFACTS=(/opt/awg-bot /var/lib/awg-bot /usr/local/bin/awg-bot /usr/local/bin/awg-bot.py
               /etc/systemd/system/awg-bot.service /etc/awg-bot.conf)
BOT_VENV_PY="$BOT_DIR/venv/bin/python"

# Любой след бота, а не только маркер: после частичного удаления его
# остатки тоже надо уметь добить.
# Код в $BOT_DIR ставит и веб-панель (--web-only) — при ней это ещё не бот
bot_installed() {
  [[ -f /usr/local/bin/awg-bot.py || -f "/etc/systemd/system/$BOT_UNIT" ]] && return 0
  [[ -d "$BOT_DIR" ]] && ! web_installed
}

bot_version() { _bot_src_version "$BOT_DIR"; }

# ── Прокси до Telegram ────────────────────────────────────
# Значение ключа из конфига бота (кавычки и пробелы по краям снимаются).
bot_conf_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$BOT_CONF" 2>/dev/null | tail -1 \
    | sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//"
}

# KEY=значение в конфиге бота; пустое значение — убрать ключ.
bot_conf_set() {
  [[ -f "$BOT_CONF" ]] || { err "Нет $BOT_CONF — сначала установи бота"; return 1; }
  { grep -vE "^[[:space:]]*$1[[:space:]]*=" "$BOT_CONF" || true
    if [[ -n "$2" ]]; then echo "$1=$2"; fi; } | write_file "$BOT_CONF" 600
}

bot_proxy_get() { bot_conf_get BOT_PROXY; }

# Пароль прокси весит как токен бота, а меню снимают на скриншоты
bot_proxy_mask() { if [[ "$1" == *@* ]]; then echo "${1%%://*}://***@${1##*@}"; else echo "$1"; fi; }

bot_proxy_valid() {
  local url="$1" scheme="${1%%://*}"
  [[ "$url" == *://?* ]] || return 1
  [[ "$scheme" == iface ]] && { [[ "${url#iface://}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; return; }
  [[ " $BOT_PROXY_SCHEMES " == *" $scheme "* ]]
}

# Любой HTTP-ответ api.telegram.org значит «прокси работает» (на / там 404)
bot_proxy_probe() {
  local code via=(--proxy "$1")
  [[ "$1" == iface://* ]] && via=(--interface "${1#iface://}")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${via[@]}" https://api.telegram.org/ 2>/dev/null) || code=000
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]
}

_bot_proxy_write() { bot_conf_set BOT_PROXY "$1"; }  # url (пусто — убрать)

# ── Mini App ──────────────────────────────────────────────
# HTTPS-сервер Mini App живёт в самом боте; awg2 задаёт порт (WEBAPP_PORT в
# конфиге бота, off — выключена) и выпускает сертификат (cert.sh).
webapp_port() {
  local p
  p=$(bot_conf_get WEBAPP_PORT)
  echo "${p:-$WEBAPP_PORT_DEFAULT}"
}

webapp_fw() {
  local p
  [[ -f "/etc/systemd/system/$BOT_UNIT" ]] || return 0
  p=$(webapp_port)
  [[ "$p" == off ]] || ufw_allow "$p/tcp" awg-webapp
  return 0
}

webapp_port_set() {  # порт | off
  local p="${1:-}"
  if [[ "$p" != off ]]; then
    valid_port "$p" && (( p != 80 )) || { err "Порт Mini App: 1-65535, кроме 80 — он для сертификата"; return 1; }
  fi
  bot_conf_set WEBAPP_PORT "$p" || return 1
  webapp_fw
  ok "Mini App: $([[ "$p" == off ]] && echo "выключена" || echo "порт $p")"
}

webapp_url() {
  local p
  p=$(webapp_port)
  cert_installed && [[ "$p" != off ]] || return 1
  echo "https://$(cert_get name)$([[ "$p" == 443 ]] || echo ":$p")/"
}

# Выпуск из меню: порт 80 занят — готовый сертификат сервера или пауза службы.
_cert_issue_menu() {
  local holder unit n c
  holder=$(cert_port80_holder)
  if [[ -z "$holder" ]]; then cert_issue "$@" && webapp_fw && bot_restart; return; fi
  unit=$(cert_port80_unit)
  n=$(cert_find | grep -c . || true)
  warn "Порт 80 занят ($holder) — acme.sh нужен он на время выпуска и продления"
  echo -e "  ${C}1)${N} Взять готовый сертификат сервера ${D}— найдено $n${N}"
  [[ -n "$unit" ]] && echo -e "  ${C}2)${N} Останавливать $unit на время выпуска и продления ${D}— секунды простоя$([[ "$1" == ip ]] && echo ', раз в 3 дня')${N}"
  echo -e "  ${W}0)${N} ← Отмена"
  read_choice c "${C}  Выбор: ${N}" 0 2 0
  case "$c" in
    1) _cert_use_menu ;;
    2) [[ -n "$unit" ]] && cert_issue "$@" pause && webapp_fw && bot_restart ;;
  esac
}

_cert_use_menu() {
  local rows=() i c name src crt key exp
  mapfile -t rows < <(cert_find)
  if (( ${#rows[@]} == 0 )); then
    info "Готовых сертификатов на этот сервер не нашлось (Caddy, certbot, acme.sh, Marzban, 3x-ui, nginx)"
    return 1
  fi
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r name src crt key exp <<< "${rows[$i]}"
    echo -e "  ${C}$((i + 1)))${N} $name ${D}— $src, до $(date -d "@$exp" '+%d.%m.%Y')${N}"
    echo -e "     ${D}$crt${N}"
  done
  echo -e "  ${W}0)${N} ← Отмена"
  read_choice c "${C}  Сертификат [0-${#rows[@]}]: ${N}" 0 "${#rows[@]}" 0
  (( c )) || return 0
  IFS=$'\t' read -r name src crt key exp <<< "${rows[$((c - 1))]}"
  cert_use "$crt" && webapp_fw && bot_restart
}

do_webapp_menu() {
  local c v p url n
  while true; do
    echo ""
    hdr "Mini App и HTTPS-сертификат"
    p=$(webapp_port)
    echo -e "  Сертификат : $(cert_state_line)"
    if url=$(webapp_url); then
      echo -e "  Mini App   : ${W}$url${N} ${D}— открывается кнопкой в боте${N}"
    else
      echo -e "  Mini App   : ${D}$([[ "$p" == off ]] && echo "выключена" || echo "нужен сертификат")${N}"
    fi
    echo -e "  ${D}Telegram открывает Mini App только по HTTPS. Let's Encrypt проверяет адрес через${N}"
    echo -e "  ${D}порт 80 — он должен быть свободен и открыт; сертификат на IP живёт ~6 дней и${N}"
    echo -e "  ${D}продлевается сам. Порт занят (Caddy, nginx) — возьми готовый сертификат сервера.${N}"
    echo ""
    n=$(cert_find | grep -c . || true)
    echo -e "  ${C}1)${N} Сертификат на IP ${D}— $(public_ip_cached)${N}"
    echo -e "  ${C}2)${N} Сертификат на домен"
    echo -e "  ${C}3)${N} Готовый сертификат сервера ${D}— найдено $n${N}"
    echo -e "  ${C}4)${N} Порт Mini App ${D}— $p${N}"
    echo -e "  ${R}5)${N} Удалить сертификат"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-5]: ${N}" 0 5 0
    case "$c" in
      1) _cert_issue_menu ip ;;
      2) read_line v "${C}  Домен (A-запись → $(public_ip_cached)): ${N}"
         [[ -n "$v" ]] && _cert_issue_menu domain "$v" ;;
      3) _cert_use_menu ;;
      4) read_line v "${C}  Порт (1-65535, off — выключить): ${N}"
         [[ -n "$v" ]] && webapp_port_set "$v" && bot_restart ;;
      5) ask_yes "  Удалить сертификат? Mini App перестанет открываться [y/N]: " n && cert_remove && bot_restart ;;
      0) return 0 ;;
    esac
    pause
  done
}

# Выходы этого сервера, годные боту, строки «url|описание».
_bot_proxy_candidates() {
  local list=() dev line url
  [[ -n "$(xray_port_owners)" ]] && list+=("socks5://$XRAY_SOCKS|SOCKS-вход Xray")
  url=$(t2s_proxy)
  [[ -n "$url" ]] && list+=("socks5://$url|прокси tun2socks")
  for dev in /sys/class/net/*; do
    dev="${dev##*/}"
    case "$dev" in
      warp0) list+=("iface://$dev|WARP") ;;
      awg-exit-*) list+=("iface://$dev|exit-нода ${dev#awg-exit-}") ;;
      xray0) list+=("iface://$dev|TUN Xray") ;;
      tun0) list+=("iface://$dev|TUN tun2socks") ;;
    esac
  done
  for line in ${list[@]+"${list[@]}"}; do
    if bot_proxy_probe "${line%%|*}"; then echo "$line — Telegram отвечает"
    else echo "$line — Telegram НЕ отвечает"; fi
  done
}

bot_proxy_menu() {
  local cur c cands=() i url
  cur=$(bot_proxy_get)
  echo -e "  Сейчас: ${W}$([[ -n "$cur" ]] && bot_proxy_mask "$cur" || echo "нет — напрямую")${N}"
  echo -e "  ${D}Нужен, если Telegram заблокирован: SOCKS5/HTTP или туннель сервера.${N}"
  echo -e "  ${C}1)${N} Задать прокси"
  echo -e "  ${C}2)${N} Проверить"
  echo -e "  ${R}3)${N} Убрать"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор [0-3]: ${N}" 0 3 0
  case "$c" in
    1) info "Ищу прокси и туннели на сервере..."
       mapfile -t cands < <(_bot_proxy_candidates)
       for i in "${!cands[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${W}${cands[$i]%%|*}${N} ${D}${cands[$i]#*|}${N}"; done
       url=""
       if (( ${#cands[@]} )); then
         read_choice c "${C}  Выбор (0 — ввести адрес): ${N}" 0 "${#cands[@]}" 0
         (( c )) && url="${cands[$((c - 1))]%%|*}"
       fi
       if [[ -z "$url" ]]; then
         echo -e "  ${D}Формат: схема://[логин:пароль@]хост:порт или iface://warp0${N}"
         read_line url "${C}  Адрес: ${N}"
         url="${url//[[:space:]]/}"
         [[ -n "$url" ]] || return 0
       fi
       bot_proxy_valid "$url" || { err "Нужна схема: ${BOT_PROXY_SCHEMES// /, }"; return 1; }
       if bot_proxy_probe "$url"; then bot_proxy_set "$url" || return 1
       else ask_yes "  Telegram через него не отвечает. Всё равно сохранить? [y/N]: " n || return 0
            bot_proxy_set "$url" force || return 1; fi ;;
    2) [[ -n "$cur" ]] || { info "Прокси не задан"; return 0; }
       if bot_proxy_probe "$cur"; then ok "Telegram отвечает"; else err "Через прокси Telegram не отвечает"; fi
       return 0 ;;
    3) [[ -n "$cur" ]] || return 0
       bot_proxy_set "" ;;
  esac
  return 0
}

# bot_proxy_set URL [force] — пусто убирает прокси. Без force сохраняет,
# только если Telegram через прокси отвечает. Бот перезапускается.
bot_proxy_set() {
  local url="${1//[[:space:]]/}"
  if [[ -n "$url" ]]; then
    bot_proxy_valid "$url" || { err "Нужна схема: ${BOT_PROXY_SCHEMES// /, }"; return 1; }
    if bot_proxy_probe "$url"; then ok "Через прокси Telegram отвечает"
    elif [[ "${2:-}" != force ]]; then err "Через $(bot_proxy_mask "$url") Telegram не отвечает — не сохраняю"; return 1
    else warn "Через прокси Telegram не отвечает — сохраняю по требованию"; fi
    # На давно установленном боте в venv может не быть нужных модулей
    if [[ "$url" == socks* && -x "$BOT_VENV_PY" ]] && ! "$BOT_VENV_PY" -c 'import aiohttp_socks' 2>/dev/null; then
      "$BOT_DIR/venv/bin/pip" install -q aiohttp-socks &>/dev/null || warn "Не поставился aiohttp-socks — обнови бота"
    fi
    if [[ "$url" == iface://* && -x "$BOT_VENV_PY" ]] && ! "$BOT_VENV_PY" -c \
       'import inspect,aiohttp; assert "socket_factory" in inspect.signature(aiohttp.TCPConnector).parameters' 2>/dev/null; then
      "$BOT_DIR/venv/bin/pip" install -q -U aiogram aiohttp &>/dev/null || warn "Не обновился aiohttp (нужен 3.12+) — обнови бота"
    fi
  fi
  _bot_proxy_write "$url" || return 1
  if [[ -n "$url" ]]; then
    ok "Прокси: $(bot_proxy_mask "$url")"
    [[ "$url" == iface://* || "$url" == *127.0.0.1* ]] && info "Туннель лёг — бот пойдёт напрямую; поднял — systemctl restart awg-bot"
  else
    ok "Прокси убран"
  fi
  bot_restart
  return 0
}

# Перезапуск бота. Если зовёт сам бот (awg2 api), этот процесс живёт в его
# cgroup: мгновенный restart убил бы его раньше ответа («awg2 ответил не
# JSON»). Тогда перезапуск откладывается на 2 секунды в отдельный юнит.
bot_restart() {
  unit_active "$BOT_UNIT" || return 0
  if (( ! API_MODE )); then
    systemctl restart "$BOT_UNIT" && ok "Бот перезапущен"
    return
  fi
  if ! systemd-run --on-active=2 --unit="awg2-bot-restart-$(date +%s%N)" --collect --quiet \
       /bin/systemctl restart "$BOT_UNIT" &>/dev/null; then
    # Без systemd-run: отдельная сессия без дескрипторов ответа
    setsid bash -c "sleep 2; systemctl restart $BOT_UNIT" </dev/null &>/dev/null 3>&- 4>&- 8>&- &
  fi
  ok "Бот перезапустится через пару секунд"
}

# ── Установка / удаление ──────────────────────────────────
# Код бота из распакованного архива рядом: при проверке правок на GitHub
# ещё старая версия.
# Версия кода бота в каталоге с awgbot/ (как __version__ у установленного).
_bot_src_version() {
  sed -n "s/^__version__[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" \
    "$1/awgbot/__init__.py" 2>/dev/null | head -1
}

# Локальный код бота из распакованного архива Тулзы: рядом с awg2, в
# текущем каталоге, в /opt, /root и /home/*. Из нескольких — самая новая
# версия бота (дата файла после распаковки ни о чём не говорит), при
# равных — найденная раньше. Только каталоги, которые может менять лишь
# root (root_only_tree): установщик и код бота из них запускаются от root,
# а из бота и панели — ещё и без вопроса. Иначе любой пользователь сервера
# подложил бы ~/awg-toolza-x с версией побольше и получил root.
_bot_local_src() {
  local d best="" bv="" v
  for d in "$(dirname "$(readlink -f "$0")")" "$PWD" /opt/awg-toolza-*/ /root/awg-toolza-*/ \
           /home/*/awg-toolza-*/ /opt/awg-toolza/; do
    # Дальше — только настоящий путь: проверенный каталог-ссылку подменили
    # бы между проверкой и запуском установщика
    [[ "$d" != *$'\n'* ]] && d=$(readlink -f -- "$d" 2>/dev/null) || continue
    [[ -n "$d" && "$d" != *$'\n'* && -d "$d/awg_bot/awgbot" && -f "$d/awg_bot/run.py" ]] || continue
    root_only_tree "$d/awg_bot" || continue
    [[ ! -e "$d/awg-bot-install.sh" ]] || root_only_path "$d/awg-bot-install.sh" || continue
    v=$(_bot_src_version "$d/awg_bot")
    if [[ -z "$best" ]] || [[ "$v" != "$bv" && "$(printf '%s\n%s\n' "$bv" "$v" | sort -V | tail -1)" == "$v" ]]; then
      best="$d/awg_bot"; bv="$v"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
}

bot_install() {
  local src installer
  src=$(_bot_local_src || true)
  # Установщик — в своём каталоге (700): рядом с ним он ищет awg_bot/, и в
  # общем /tmp его мог подложить любой пользователь
  mktmp installer -d || return 1
  installer+="/awg-bot-install.sh"
  local lv iv
  lv=$(_bot_src_version "$src"); iv=$(bot_version)
  if [[ -n "$src" ]] && ask_yes "  Найден локальный код бота $(shown "${lv:-?}") ($(shown "$src"))${iv:+, установлен $iv}. Ставить из него? [Y/n]: " y; then
    if [[ -f "${src%/awg_bot}/awg-bot-install.sh" ]]; then
      bash "${src%/awg_bot}/awg-bot-install.sh" --src "$src"
      return
    fi
    curl -fsSL "$BOT_INSTALL_URL" -o "$installer" || { err "Не скачался установщик"; return 1; }
    bash "$installer" --src "$src"
    return
  fi
  info "Установщик бота — канал $(update_channel_label)"
  curl -fsSL "$BOT_INSTALL_URL" -o "$installer" || { err "Не скачался установщик: $BOT_INSTALL_URL"; return 1; }
  # Бот и awg2 — из одного репозитория, иначе на бете они разъедутся
  AWG_REPO_URL="https://github.com/$UPDATE_REPO" bash "$installer"
}

# $1 = quiet — без вопроса. Токен перед удалением копируется в бэкапы.
bot_uninstall() {
  local p saved="" left=()
  if [[ "${1:-}" != quiet ]]; then
    warn "Будут удалены служба, код, venv и конфиг с токеном. AWG не затрагивается."
    read_confirm "${R}  Удалить бота? (введи yes): ${N}" || return 0
  fi
  if [[ -f "$BOT_CONF" ]]; then
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    saved="$BACKUP_DIR/awg-bot.conf.$(date +%Y%m%d_%H%M%S)"
    cp -a "$BOT_CONF" "$saved" || saved=""
  fi
  systemctl disable --now "$BOT_UNIT" &>/dev/null || true
  local arts=("${BOT_ARTIFACTS[@]}")
  # Код, venv и заметки нужны веб-панели — с ней остаются
  if web_installed; then
    arts=(); for p in "${BOT_ARTIFACTS[@]}"; do [[ "$p" == "$BOT_DIR" || "$p" == /var/lib/awg-bot ]] || arts+=("$p"); done
    info "Код бота остаётся — на нём работает веб-панель"
    rm -f "$BOT_ADMINS"           # приглашённые админы — бота, а не панели
  fi
  for p in "${arts[@]}"; do rm -rf "$p"; done
  systemctl daemon-reload
  systemctl reset-failed "$BOT_UNIT" &>/dev/null || true
  for p in "${arts[@]}"; do [[ -e "$p" ]] && left+=("$p"); done
  if (( ${#left[@]} )); then warn "Не удалось удалить: ${left[*]}"; else ok "Бот удалён"; fi
  [[ -n "$saved" ]] && info "Конфиг с токеном сохранён: $saved"
  log_info "бот удалён"
}

do_bot_menu() {
  local c v px
  while true; do
    echo ""
    hdr "Telegram-бот"
    if bot_installed; then
      if unit_active "$BOT_UNIT"; then echo -e "  Статус : ${G}● работает${N}"; else echo -e "  Статус : ${Y}○ остановлен${N}"; fi
      v=$(bot_version); px=$(bot_proxy_get)
      echo -e "  Версия : ${W}${v:-?}${N}"
      echo -e "  Прокси : $([[ -n "$px" ]] && bot_proxy_mask "$px" || echo "нет — напрямую")"
      echo ""
      echo -e "  ${C}1)${N} Обновить / переустановить"
      echo -e "  ${C}2)${N} Запустить"
      echo -e "  ${C}3)${N} Остановить"
      echo -e "  ${C}4)${N} Перезапустить"
      echo -e "  ${C}5)${N} Журнал"
      echo -e "  ${C}6)${N} Прокси до Telegram"
      echo -e "  ${R}7)${N} Удалить бота"
      echo -e "  ${C}8)${N} Mini App и HTTPS-сертификат"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-8]: ${N}" 0 8 0
    else
      echo -e "  ${D}Клиенты, сроки, туннели и статус из Telegram.${N}"
      echo -e "  ${C}1)${N} Установить бота"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-1]: ${N}" 0 1 0
    fi
    case "$c" in
      1) bot_install || warn "Установщик завершился с ошибкой" ;;
      2) systemctl start "$BOT_UNIT" && ok "Запущен" || err "Не запустился: journalctl -u $BOT_UNIT" ;;
      3) systemctl stop "$BOT_UNIT" && ok "Остановлен" || true ;;
      4) systemctl restart "$BOT_UNIT" && ok "Перезапущен" || err "Не запустился: journalctl -u $BOT_UNIT" ;;
      5) journalctl -u "$BOT_UNIT" -n 40 --no-pager 2>/dev/null || true ;;
      6) bot_proxy_menu || true ;;
      7) bot_uninstall || true ;;
      8) do_webapp_menu || true; continue ;;
      0) return 0 ;;
    esac
    pause
  done
}
