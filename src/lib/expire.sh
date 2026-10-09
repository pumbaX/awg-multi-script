# Срок действия клиентов. Истёкший клиент не удаляется, а блокируется:
# его AllowedIPs меняется на 127.0.0.2/32, исходный адрес сохраняется меткой
# «# orig_ips=» — разблокировка возвращает его на место. Метку «# expires=»
# ставит и Telegram-бот, поэтому таймер нужен независимо от того, кто
# назначил срок.

# Уведомление владельцам и админам бота — напрямую в Telegram, через прокси
# бота: таймер работает и тогда, когда сам бот остановлен.
_expire_notify() {
  local token="" proxy="" id ids=() via=()
  # Проход таймера под замком API: сообщения — после замка (curl до 8 с на
  # каждого админа держал бы замок, и правки из бота и панели получали отказ)
  if [[ -n "${EXPIRE_DEFER:-}" ]]; then EXPIRE_QUEUE+=("$1"); return 0; fi
  [[ -f "$BOT_CONF" ]] || return 0
  { read -r token; read -r proxy; mapfile -t ids; } < <(py tg-targets "$BOT_CONF" "$BOT_ADMINS" 2>/dev/null)
  [[ -n "$token" ]] && (( ${#ids[@]} )) || return 0
  case "$proxy" in
    iface://*) via=(--interface "${proxy#iface://}") ;;
    ?*) via=(--proxy "$proxy") ;;
  esac
  for id in "${ids[@]}"; do
    # Токен не попадает в argv (его видно в списке процессов) — curl читает конфиг со stdin
    curl -sf --max-time 8 ${via[@]+"${via[@]}"} --config - >/dev/null 2>&1 <<EOF || true
url = "https://api.telegram.org/bot${token}/sendMessage"
data = "chat_id=${id}"
data = "parse_mode=HTML"
data-urlencode = "text=$1"
EOF
  done
}

# Имя клиента в HTML-сообщении Telegram: конфиг, правленный руками, может
# нести в имени что угодно.
_expire_esc() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }

_expire_sync() {
  local stripped
  stripped=$(awg-quick strip "$AWG_IF" 2>/dev/null) \
    && awg syncconf "$AWG_IF" <(printf '%s\n' "$stripped") 2>>"$EXPIRE_LOG"
}

# Трафик клиентов: прирост счётчиков — в базу по дням, превысившие лимит
# блокируются, в новом месяце (или после смены лимита) — разблокируются.
# Снимок счётчиков — свой файл на каждый вызов: таймер и команда из меню
# или API, писавшие в один файл, читали бы недописанные строки друг друга.
_traffic_snapshot() {  # → путь к снимку в stdout
  local tr
  mkdir -p "$EXPIRE_STATE_DIR"
  tr=$(mktemp "$EXPIRE_STATE_DIR/transfer.XXXXXX") || return 1
  awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || : > "$tr"
  printf '%s\n' "$tr"
}

traffic_tick() {  # [1 — записать базу сейчас]
  local out ev name arg text tr ifx=""
  [[ -f "$SERVER_CONF" ]] || return 0
  tr=$(_traffic_snapshot) || return 0
  ifx=$(cat "/sys/class/net/$AWG_IF/ifindex" 2>/dev/null || true)
  out=$(py traffic-tick "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$TRAFFIC_DB" "$tr" "$ifx" "${1:-0}" 2>>"$EXPIRE_LOG") || out=""
  # Прочитанный снимок — на место $EXPIRE_STATE_DIR/transfer одним rename:
  # по его времени expire_watchdog видит, что таймер жив
  mv -f "$tr" "$EXPIRE_STATE_DIR/transfer" 2>/dev/null || rm -f "$tr"
  while IFS=$'\t' read -r ev name arg text; do
    case "$ev" in
      CHANGED) _expire_sync ;;
      LIMIT)
        echo "$(date '+%F %T') limit: $name ($text)" >> "$EXPIRE_LOG"
        command -v conntrack >/dev/null && conntrack -D -s "${arg%%/*}" >/dev/null 2>&1
        _expire_notify "🚫 Клиент <b>$(_expire_esc "$name")</b> заблокирован: исчерпан лимит трафика — ${text}." ;;
      WARN90)
        echo "$(date '+%F %T') limit90: $name ($arg)" >> "$EXPIRE_LOG"
        _expire_notify "⚠️ Клиент <b>$(_expire_esc "$name")</b> израсходовал 90% лимита трафика: ${arg}." ;;
      UNLIMIT)
        echo "$(date '+%F %T') unlimit: $name ($arg)" >> "$EXPIRE_LOG"
        _expire_notify "✅ Клиент <b>$(_expire_esc "$name")</b> разблокирован — трафик в пределах лимита: ${arg}." ;;
    esac
  done <<< "$out"
  return 0
}

# Точка входа таймера (awg2-expire-check). Конфиг сервера правят и вызовы
# API (бот, панель) — под их замком; занят дольше 10 с — проход пропускается,
# следующий через 15 с. Таймер при этом жив — сторожу это видно по времени
# снимка. Долгая задача API (сборка модуля, установка) держит замок минутами:
# сроки и лимиты ждут её не дольше EXPIRE_LOCK_MAX, дальше проход идёт без замка.
EXPIRE_LOCK_MAX=120
expire_check_run() {
  local out ev name arg busy="$EXPIRE_STATE_DIR/lock_busy"
  local EXPIRE_DEFER=1 EXPIRE_QUEUE=()
  [[ -f "$SERVER_CONF" ]] || return 0
  mkdir -p "$STATE_DIR" "$EXPIRE_STATE_DIR"
  exec 9>>"$STATE_DIR/api.lock" || return 0
  if flock -w "${EXPIRE_LOCK_WAIT:-10}" 9; then
    rm -f "$busy"
  else
    [[ -f "$busy" ]] || : > "$busy"
    if (( $(date +%s) - $(stat -c %Y "$busy" 2>/dev/null || date +%s) < ${EXPIRE_LOCK_MAX:-120} )); then
      [[ -f "$EXPIRE_STATE_DIR/transfer" ]] && touch "$EXPIRE_STATE_DIR/transfer"
      return 0
    fi
  fi
  out=$(py expire-check "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$EXPIRE_STATE_DIR" 2>>"$EXPIRE_LOG") || out=""
  while IFS=$'\t' read -r ev name arg; do
    case "$ev" in
      CHANGED) _expire_sync ;;
      EXPIRED)
        echo "$(date '+%F %T') expired: $name (было $arg)" >> "$EXPIRE_LOG"
        command -v conntrack >/dev/null && conntrack -D -s "${arg%%/*}" >/dev/null 2>&1
        _expire_notify "🚫 Клиент <b>$(_expire_esc "$name")</b> заблокирован: срок действия истёк." ;;
      WARN1H)
        echo "$(date '+%F %T') warn1h: $name ($arg мин)" >> "$EXPIRE_LOG"
        _expire_notify "⚠️ Клиент <b>$(_expire_esc "$name")</b> истекает через ${arg} мин." ;;
    esac
  done <<< "$out"
  traffic_tick
  exec 9>&-
  EXPIRE_DEFER=""
  # Telegram недоступен: curl по 8 с на каждого админа — бюджет 60 с, чтобы
  # проход не затягивался; не ушедшее — в журнале
  local i t0=$SECONDS
  for (( i = 0; i < ${#EXPIRE_QUEUE[@]}; i++ )); do
    if (( SECONDS - t0 >= ${EXPIRE_NOTIFY_BUDGET:-60} )); then
      echo "$(date '+%F %T') уведомления: не отправлено $(( ${#EXPIRE_QUEUE[@]} - i )) — Telegram не отвечает" >> "$EXPIRE_LOG"
      break
    fi
    _expire_notify "${EXPIRE_QUEUE[$i]}"
  done
  return 0
}

expire_install() {
  mkdir -p "$EXPIRE_STATE_DIR"
  emit_script "$EXPIRE_BIN" 'expire_check_run' \
    SERVER_CONF AWG_IF EXPIRE_SUSPEND_IP EXPIRE_STATE_DIR EXPIRE_LOG BOT_CONF BOT_ADMINS TRAFFIC_DB _PY_HELPER STATE_DIR EXPIRE_LOCK_MAX \
    py _expire_notify _expire_esc _expire_sync _traffic_snapshot traffic_tick expire_check_run || return 1
  write_unit awg2-expire.service <<EOF
[Unit]
Description=AWG Toolza — сроки и трафик клиентов
After=awg-quick@awg0.service network-online.target

[Service]
Type=oneshot
ExecStart=$EXPIRE_BIN
# У oneshot тайм-аута нет: зависший проход (awg show, syncconf) навсегда
# останавливал бы и таймер — сторож его перезапуском не снимает
TimeoutStartSec=120
# Запуск каждые 15 с: «Starting/Finished» в журнал не пишем, сбои — пишем
LogLevelMax=notice
EOF
  # Каждые 15 секунд по часам: превысивший лимит блокируется не позже чем
  # через 15 с (что успеет скачать за это время — перерасход). Прежний
  # OnUnitActiveSec отсчитывал от прошлого запуска службы и после
  # переустановки сервера мог не сработать больше никогда (см. timer_heal);
  # расписание по часам от истории не зависит.
  write_unit awg2-expire.timer <<'EOF'
[Unit]
Description=AWG Toolza — таймер сроков и трафика клиентов

[Timer]
OnCalendar=*-*-* *:*:00/15
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
  systemctl enable --now awg2-expire.timer &>/dev/null || warn "Таймер сроков не запустился: systemctl status awg2-expire.timer"
  timer_heal awg2-expire.timer
}

# Сторож таймера: каждый проход таймера пишет счётчики в $EXPIRE_STATE_DIR/transfer.
# Файл старше 5 минут — таймер молчит, и сроки с лимитами не блокируют: поставить
# таймер заново, перезапустить и сразу сделать проход. Зовётся при каждом запуске
# awg2 (меню, бот, панель) — стоит одного stat.
EXPIRE_STALE=300
expire_watchdog() {
  local tr="$EXPIRE_STATE_DIR/transfer" age
  server_exists || return 0
  [[ -f "$tr" ]] || return 0            # таймер ещё ни разу не проходил — поставит expire_install
  age=$(( $(date +%s) - $(stat -c %Y "$tr" 2>/dev/null || echo 0) ))
  (( age < EXPIRE_STALE )) && return 0
  mkdir -p "$(dirname "$EXPIRE_LOG")"
  echo "$(date '+%F %T') watchdog: таймер молчал ${age}с — перезапуск" >> "$EXPIRE_LOG"
  log_warn "таймер сроков и лимитов молчал ${age}с — перезапуск"
  touch "$tr"                           # параллельные вызовы awg2 не перезапускают его разом
  expire_install &>/dev/null
  systemctl restart awg2-expire.timer &>/dev/null || true
  systemctl start --no-block awg2-expire.service &>/dev/null || true
}

expire_remove() {
  remove_unit awg2-expire.timer awg2-expire.service
  rm -f "$EXPIRE_BIN" "$TRAFFIC_DB" "$TRAFFIC_DB.lock"
  rm -rf "$EXPIRE_STATE_DIR"
}

expire_fmt() {  # unix-время → «31.12.2026 23:59 (через 3д 4ч)»
  local ts="$1" d abs s="" when
  d=$(( ts - $(date +%s) )); abs=${d#-}
  (( abs >= 86400 )) && s+="$((abs / 86400))д "
  (( abs % 86400 >= 3600 )) && s+="$((abs % 86400 / 3600))ч "
  (( abs < 86400 )) && s+="$((abs % 3600 / 60))м"
  s="${s% }"
  when=$(date -d "@$ts" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "$ts")
  if (( d >= 0 )); then echo "$when (через $s)"; else echo "$when (истёк $s назад)"; fi
}

_expire_apply() {
  local stripped
  iface_up || return 0
  stripped=$(awg-quick strip "$AWG_IF" 2>/dev/null) && awg syncconf "$AWG_IF" <(printf '%s\n' "$stripped")
}

# Строки трафика для меню: «имя|лимит|период|по лимиту|за месяц|сегодня|причина».
traffic_rows() {
  local tr
  server_exists || return 0
  mktmp tr || return 1
  awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
  py traffic-rows "$SERVER_CONF" "$TRAFFIC_DB" "$tr" | tr '\t' '|'
}

_ask_limit() {  # → «РАЗМЕР ПЕРИОД» в stdout или пусто
  local v p
  echo -e "  ${D}Размер: 50G, 500M, 1.5T; число без буквы — гигабайты${N}" >&2
  read -rp "  Лимит: " v
  [[ -n "$v" ]] || return 0
  py size-parse "$v" >/dev/null 2>&1 || { warn "Размер не распознан: $v" >&2; return 0; }
  echo -e "  ${C}1)${N} В месяц ${D}— счётчик обнуляется 1-го числа, клиент разблокируется сам${N}" >&2
  echo -e "  ${C}2)${N} Всего ${D}— без сброса, с этой минуты${N}" >&2
  read_choice p "${C}  Период [1-2]: ${N}" 1 2 1
  echo "$v $([[ "$p" == 2 ]] && echo total || echo month)"
}

do_traffic_days() {
  local tr
  server_exists || { err "Сервер не создан"; return 1; }
  mktmp tr || return 1
  awg show "$AWG_IF" transfer > "$tr" 2>/dev/null || true
  echo ""
  hdr "Трафик по дням"
  py traffic-report "$SERVER_CONF" "$TRAFFIC_DB" "$tr" 14 | sed 's/^/  /'
  [[ -f "$TRAFFIC_DB" ]] || info "Учёт идёт с момента установки $VERSION — данные копятся каждые 15 секунд"
}

do_expire_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  expire_install
  local c name pub ts rows=() n=0 exp orig lim per used month _ by ans
  local -A tl=()
  while true; do
    echo ""
    hdr "Сроки и лимиты трафика"
    tl=()
    while IFS='|' read -r name lim per used month _ by; do
      [[ -n "$name" && "$lim" != 0 ]] && tl[x$name]="$lim/$per|$used|$by"
    done < <(traffic_rows)
    while IFS='|' read -r name pub _ exp orig _; do
      [[ -n "$exp" || -n "${tl[x$name]:-}" ]] || continue
      n=$((n + 1))
      by="${tl[x$name]:-}"; by="${by##*|}"
      if [[ -n "$orig" && "$by" == traffic ]]; then echo -e "  ${R}🚫 ${name}${N} ${D}— заблокирован: исчерпан лимит${N}"
      elif [[ -n "$orig" ]]; then echo -e "  ${R}🚫 ${name}${N} ${D}— заблокирован, $(expire_fmt "$exp")${N}"
      elif [[ -n "$exp" ]]; then echo -e "  ${Y}⏰ ${name}${N} ${D}— $(expire_fmt "$exp")${N}"
      else echo -e "  ${C}📶 ${name}${N}"; fi
      if [[ -n "${tl[x$name]:-}" ]]; then
        IFS='|' read -r lim used _ <<< "${tl[x$name]}"
        echo -e "     ${D}трафик: $(limit_fmt "$lim" "$used")${N}"
      fi
    done < <(clients_psv)
    (( n )) || echo -e "  ${D}Сроков и лимитов нет — все клиенты бессрочные и без лимита${N}"
    n=0
    echo ""
    echo -e "  ${C}1)${N} Поставить срок"
    echo -e "  ${C}2)${N} Снять срок / разблокировать"
    echo -e "  ${C}3)${N} Лимит трафика"
    echo -e "  ${C}4)${N} Снять лимит трафика"
    echo -e "  ${C}5)${N} Обнулить счётчик лимита"
    echo -e "  ${C}6)${N} Трафик по дням"
    echo -e "  ${R}7)${N} Удалить с истёкшим сроком"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-7]: ${N}" 0 7 0
    case "$c" in
      1) _pick_client || continue
         name="${CHOSEN%%$'\t'*}"
         [[ -n "$name" ]] || { warn "У клиента нет имени"; continue; }
         ts=$(_ask_expire)
         [[ -n "$ts" ]] && { client_expire_set "$name" "$ts" || true; } ;;
      2) _pick_client || continue
         client_expire_clear "${CHOSEN%%$'\t'*}" || true ;;
      3) _pick_client || continue
         name="${CHOSEN%%$'\t'*}"
         [[ -n "$name" ]] || { warn "У клиента нет имени"; continue; }
         ans=$(_ask_limit)
         [[ -n "$ans" ]] && { client_limit_set "$name" "${ans% *}" "${ans#* }" || true; } ;;
      4) _pick_client || continue
         client_limit_set "${CHOSEN%%$'\t'*}" off || true ;;
      5) _pick_client || continue
         client_limit_reset "${CHOSEN%%$'\t'*}" || true ;;
      6) do_traffic_days || true; pause ;;
      7) mapfile -t rows < <(clients_tsv | awk -F'\t' '$5 != "" && $8 != "traffic" {print $1}')
         (( ${#rows[@]} )) || { info "Клиентов с истёкшим сроком нет"; continue; }
         warn "Будут удалены навсегда: ${rows[*]}"
         read_confirm "${R}  Подтверди (введи yes): ${N}" && clients_purge_blocked ;;
      0) return 0 ;;
    esac
  done
}
