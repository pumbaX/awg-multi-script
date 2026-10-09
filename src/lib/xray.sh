# Xray: клиенты AWG выходят через VLESS/VMess/Hysteria2-сервер.
#
# Интерфейс xray0 поднимает сам Xray (inbound tun), а если сборка его не
# умеет — tun2socks поверх SOCKS-входа Xray на 127.0.0.1:10808. Дальше
# маршрутизация одна: клиенты из peers.list → таблица 201 → xray0.
#
# Клиенту можно назначить свой выход: строка «IP|выход» в peers.list, в
# конфиге Xray — правило по адресу клиента (source) перед общим. Адрес
# клиента виден только inbound tun самого Xray — поэтому перед xray0 в этом
# режиме нет NAT; через tun2socks все соединения приходят с 127.0.0.1.
#
# Три постоянных юнита, чтобы туннель переживал перезагрузку:
#   awg-xray.service          — сам Xray;
#   awg-xray-tun.service      — tun2socks (только если нет inbound tun);
#   awg-xray-routing.service  — маршруты клиентов; перед ними проверяет, что
#                               трафик через Xray действительно идёт.

xray_installed() { [[ -x "$XRAY_BIN" && -f "$XRAY_CONF" ]]; }
xray_state_get() { sed -n "s/^$1=//p" "$XRAY_STATE" 2>/dev/null | head -1; }
xray_tags()      { [[ -f "$XRAY_CONF" ]] && py xray-tags "$XRAY_CONF" 2>/dev/null; }
xray_ru_on()     { [[ -f "$XRAY_CONF" ]] && grep -q '"ruleTag": "ru-direct"' "$XRAY_CONF"; }

_xray_asset() {
  case "$(uname -m)" in
    x86_64|amd64) echo Xray-linux-64 ;; aarch64|arm64) echo Xray-linux-arm64-v8a ;;
    armv7l|armv7) echo Xray-linux-arm32-v7a ;; *) echo "" ;;
  esac
}

# Текст ошибки Xray по конфигу. 0 — принят.
# Проверяется копия: формат Xray берёт из расширения (без «.json» отказ
# «Failed to get format»), а inbound tun при проверке создаёт устройство —
# у копии оно своё, иначе при работающем Xray «device or resource busy».
xray_test() {
  local out copy rc=0
  # Не mktmp: xray_test зовут и внутри $(...), где ловушка EXIT не убирает файлы
  copy=$(mktemp --suffix=.json /tmp/awg2.XXXXXX) || return 1
  if py xray-test-copy "${1:-$XRAY_CONF}" "$copy" 2>/dev/null; then
    out=$("$XRAY_BIN" run -test -c "$copy" 2>&1) || rc=1
  else
    out="конфиг Xray — не JSON"; rc=1
  fi
  rm -f "$copy"
  (( rc )) || return 0
  printf '%s\n' "$out" | grep -iE 'failed|error|invalid|unknown|not found|JSON' | head -5
  return 1
}

# Умеет ли бинарь inbound tun. Апстримный XTLS/Xray-core долго его не имел,
# поэтому спрашиваем сам бинарь, а не гадаем по версии.
# Ответ запоминается и в $STATE_DIR/xray_tun до смены бинаря: проба
# запускает сам Xray, а спрашивают её на каждом экране клиента в боте.
_XRAY_TUN=""
xray_tun_supported() {
  local probe key cache="$STATE_DIR/xray_tun"
  if [[ -z "$_XRAY_TUN" ]]; then
    key=$(stat -c '%Y:%s' "$XRAY_BIN" 2>/dev/null || true)
    if [[ -n "$key" && "$(cut -d' ' -f1 "$cache" 2>/dev/null)" == "$key" ]]; then
      _XRAY_TUN=$(cut -d' ' -f2 "$cache")
    else
      _XRAY_TUN=0
      mktmp probe .json || return 1
      py xray-tun-probe "$probe" && xray_test "$probe" >/dev/null && _XRAY_TUN=1
      [[ -n "$key" ]] && mkdir -p "$STATE_DIR" && echo "$key $_XRAY_TUN" > "$cache" 2>/dev/null
    fi
  fi
  [[ "$_XRAY_TUN" == 1 ]]
}

# Кто слушает SOCKS-порт Xray: «имя (pid N)» построчно.
xray_port_owners() {
  ss -lntpH "sport = :${XRAY_SOCKS##*:}" 2>/dev/null \
    | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 (pid \2)/p' | sort -u || true
}

# ── Установка ─────────────────────────────────────────────
xray_install() {  # [update] — без вопроса обновить уже установленный
  local asset base tmp want rc
  if xray_installed; then
    info "Установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
    [[ "${1:-}" == update ]] || ask_yes "  Обновить до последней версии? [y/N]: " n || return 0
  fi
  asset=$(_xray_asset)
  [[ -n "$asset" ]] || { err "Архитектура $(uname -m) не поддерживается Xray"; return 1; }
  need_cmds unzip:unzip || return 1
  mktmp tmp -d || return 1
  base="https://github.com/XTLS/Xray-core/releases/latest/download"
  info "Скачиваю Xray ($asset)..."
  gh_fetch "$base/$asset.zip" "$tmp/x.zip" 1000000 zip || { err "Xray не скачался ни напрямую, ни через зеркала"; return 1; }
  # .dgst рядом с архивом: строка «SHA2-256= <хеш>»
  if gh_fetch "$base/$asset.zip.dgst" "$tmp/dgst" 16 any; then
    want=$(grep -iE 'sha2?-?256' "$tmp/dgst" | grep -oE '[0-9a-fA-F]{64}' | head -1)
    rc=0; sha256_check "$tmp/x.zip" "$want" || rc=$?
    (( rc == 1 )) && { err "Контрольная сумма Xray не совпала"; return 1; }
    (( rc == 0 )) && ok "Контрольная сумма совпала"
  else
    warn "Файла с контрольной суммой нет — ставлю без проверки"
  fi
  unzip -qo "$tmp/x.zip" xray -d "$tmp" || { err "Архив не распаковался"; return 1; }
  unzip -qo "$tmp/x.zip" geoip.dat geosite.dat -d "$XRAY_ASSET_DIR" 2>/dev/null || true
  "$tmp/xray" version &>/dev/null || { err "Скачанный xray не запускается"; return 1; }
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  ok "Xray: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  _XRAY_TUN=""
  mkdir -p "$XRAY_DIR" && chmod 700 "$XRAY_DIR"
  [[ -f "$XRAY_CONF" ]] || py xray-default "$XRAY_CONF"
  if xray_is_up; then
    info "Перезапускаю туннель на новой версии"
    xray_restart
  fi
}

# ── Выходы (outbounds) ────────────────────────────────────
xray_add_outbound() {
  local link
  xray_installed || { err "Сначала установи Xray"; return 1; }
  read_line link "${C}  Ссылка (vless:// vmess:// trojan:// ss:// hysteria2://): ${N}"
  link="${link//[[:space:]]/}"
  [[ -n "$link" ]] || return 0
  xray_add_link "$link"
}

xray_add_link() {  # ссылка
  local link="$1" ob msgs tag probe why rc=0
  xray_installed || { err "Сначала установи Xray"; return 1; }
  mktmp msgs || return 1
  ob=$(py xray-link "$link" 2>"$msgs") || { err "Ссылка не разобрана: $(tail -1 "$msgs")"; return 1; }
  grep -q '^NOTE:' "$msgs" && sed -n 's/^NOTE:/  /p' "$msgs"
  grep -q '^UNSUPPORTED:' "$msgs" && { err "Транспорт $(sed -n 's/^UNSUPPORTED://p' "$msgs") не поддерживается"; return 1; }
  tag=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["tag"])' "$ob")
  # Проверяем outbound на самом бинаре до записи: неподдерживаемый протокол
  # (hysteria2 в апстримном Xray) иначе ломает весь конфиг.
  mktmp probe .json || return 1
  py xray-probe "$probe" <<< "$ob"
  if ! why=$(xray_test "$probe"); then
    err "Этот Xray не принимает такой выход:"
    sed 's/^/      /' <<< "$why"
    [[ "$link" =~ ^(hysteria2|hy2):// ]] && info "Hysteria2 есть в Xray 26 и новее — обнови Xray: Установить / обновить"
    return 1
  fi
  py xray-add "$XRAY_CONF" <<< "$ob" 2>/dev/null || rc=$?
  (( rc == 3 )) && { err "Выход $tag уже есть"; return 1; }
  (( rc == 0 )) || { err "Не удалось записать конфиг"; return 1; }
  ok "Выход $tag добавлен и выбран активным"
  if xray_is_up; then info "Туннель работает на прежнем выходе — перезапусти его"; fi
}

_xray_pick_tag() {  # → CHOSEN
  local tags=() i c
  mapfile -t tags < <(xray_tags)
  (( ${#tags[@]} )) || { warn "Выходов нет — добавь выход ссылкой"; return 1; }
  for i in "${!tags[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${tags[$i]}"; done
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 "${#tags[@]}" 0
  (( c )) || return 1
  CHOSEN="${tags[$((c - 1))]}"
}

xray_del_outbound() {
  xray_installed || { err "Xray не установлен"; return 1; }
  _xray_pick_tag || return 0
  xray_del_tag "$CHOSEN"
}

# Клиенты удалённых выходов — на выход по умолчанию; печатает, сколько их.
_xray_peers_untag() {  # тег...
  local f="$XRAY_PEERS"
  [[ -f "$f" ]] || { echo 0; return 0; }
  awk -F'|' 'NR == FNR {d[$0] = 1; next} NF > 1 && ($2 in d) {c++} END {print c + 0}' \
    <(printf '%s\n' "$@") "$f"
  awk -F'|' 'NR == FNR {d[$0] = 1; next} NF > 1 && ($2 in d) {print $1; next} {print}' \
    <(printf '%s\n' "$@") "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

xray_del_tag() {  # тег
  local n
  xray_tags | grep -qxF "$1" || { err "Выхода $1 нет"; return 1; }
  py xray-del "$XRAY_CONF" "$1"
  n=$(_xray_peers_untag "$1")
  _xray_prepare
  ok "Выход $1 удалён"
  (( ${n:-0} )) && info "Его клиенты ($n) — теперь на выходе по умолчанию"
  xray_is_up && xray_restart
  return 0
}

# Режим входа Xray: native — свой inbound tun, tun2socks — через SOCKS.
xray_mode() { if xray_tun_supported; then echo native; else echo tun2socks; fi; }

_xray_prepare() { py xray-prepare "$XRAY_CONF" "$(xray_mode)" "$XRAY_PEERS"; }

# Выход по умолчанию — для клиентов без своего выхода. Балансировщик выключается.
xray_main_set() {  # тег
  xray_installed || { err "Xray не установлен"; return 1; }
  xray_tags | grep -qxF "$1" || { err "Выхода $1 нет"; return 1; }
  py xray-main "$XRAY_CONF" "$1" || return 1
  ok "Выход по умолчанию: $1"
  if xray_is_up; then info "Перезапускаю туннель"; xray_restart; fi
  return 0
}

# Выход клиента: тег или default (выход по умолчанию / балансировщик).
# Клиент заодно включается в Xray.
xray_client_out() {  # имя тег|default
  local name="$1" tag="$2" ip old new
  xray_installed || { err "Xray не установлен"; return 1; }
  ip=$(clients_name_ip | awk -F'|' -v n="$name" '$1 == n {print $2; exit}')
  [[ -n "$ip" ]] || { err "Клиента $name нет"; return 1; }
  if [[ "$tag" != default ]]; then
    xray_tags | grep -qxF "$tag" || { err "Выхода $tag нет"; return 1; }
    if ! xray_tun_supported; then
      err "Свой выход клиенту — только с inbound tun в самом Xray, а эта сборка его не умеет"
      info "Обнови Xray: Туннели → Xray → Установить / обновить"
      return 1
    fi
  fi
  peers_sync "$XRAY_PEERS"; peers_seed "$XRAY_PEERS"
  old=$(grep -E "^${ip//./\\.}(\||$)" "$XRAY_PEERS" | head -1)
  new="$ip"; [[ "$tag" == default ]] || new="$ip|$tag"
  peers_add "$XRAY_PEERS" "$ip" "$new"
  ok "$name → $([[ "$tag" == default ]] && echo "выход по умолчанию" || echo "$tag")"
  xray_is_up || return 0
  # Правила по адресу в конфиге Xray меняются, только если выход клиента был
  # или стал своим; иначе хватает маршрута клиента в xray0
  if [[ "$old" != "$new" && ( "$old" == *"|"* || "$new" == *"|"* ) ]]; then
    _xray_prepare
    info "Перезапускаю туннель"; xray_restart
  else
    _tunnel_rules_refresh "$XRAY_PEERS" "$XRAY_IF" "$XRAY_TABLE"
  fi
  return 0
}

# «имя|ip|выход» клиентов Xray со своим выходом.
xray_client_outs() {
  local name ip line
  [[ -f "$XRAY_PEERS" ]] || return 0
  while IFS='|' read -r name ip; do
    line=$(grep -E "^${ip//./\\.}\|" "$XRAY_PEERS" | head -1)
    [[ -n "$line" ]] && echo "$name|$ip|${line#*|}"
  done < <(clients_name_ip)
  return 0
}

xray_main_menu() {
  local tags=() i c
  mapfile -t tags < <(xray_tags)
  (( ${#tags[@]} )) || { warn "Выходов нет — добавь выход ссылкой"; return 0; }
  echo -e "  Сейчас: ${W}$(py xray-main-get "$XRAY_CONF" | sed 's/^balancer$/балансировщик/')${N}"
  _xray_pick_tag || return 0
  xray_main_set "$CHOSEN"
}

xray_client_menu() {
  local tags=() i c name cur
  xray_installed || { err "Xray не установлен"; return 1; }
  mapfile -t tags < <(xray_tags)
  (( ${#tags[@]} >= 2 )) || { warn "Свой выход клиенту — когда выходов хотя бы два"; return 0; }
  _pick_client || return 0
  name="${CHOSEN%%$'\t'*}"
  [[ -n "$name" ]] || { warn "У клиента нет имени"; return 0; }
  cur=$(xray_client_outs | awk -F'|' -v n="$name" '$1 == n {print $3}')
  echo -e "  Сейчас: ${W}${cur:-выход по умолчанию}${N}"
  echo -e "  ${C}0)${N} Выход по умолчанию ${D}($(py xray-main-get "$XRAY_CONF" | sed 's/^balancer$/балансировщик/'))${N}"
  for i in "${!tags[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${tags[$i]}"; done
  read_choice c "${C}  Выход [0-${#tags[@]}]: ${N}" 0 "${#tags[@]}" 0
  if (( c == 0 )); then xray_client_out "$name" default; else xray_client_out "$name" "${tags[$((c - 1))]}"; fi
}

xray_balancer() {  # стратегия
  py xray-balancer "$XRAY_CONF" "$1" || return 1
  if [[ "$1" == off ]]; then ok "Балансировщик выключен"; else ok "Балансировщик: $1"; fi
  xray_is_up && xray_restart
  return 0
}

xray_balancer_menu() {
  local c s=(random roundRobin leastPing leastLoad off) n
  n=$(xray_tags | grep -c . || true)
  (( n >= 2 )) || { warn "Для балансировки нужно минимум 2 выхода"; return 0; }
  echo -e "  Сейчас: ${W}$(py xray-balancer-get "$XRAY_CONF")${N}"
  echo -e "  ${C}1)${N} random ${D}— случайный выход${N}"
  echo -e "  ${C}2)${N} roundRobin ${D}— по очереди${N}"
  echo -e "  ${C}3)${N} leastPing ${D}— самый быстрый${N}"
  echo -e "  ${C}4)${N} leastLoad ${D}— наименее загружен${N}"
  echo -e "  ${C}5)${N} Выключить ${D}— первый выход${N}"
  read_choice c "${C}  Выбор [1-5] (0 — отмена): ${N}" 0 5 0
  (( c )) || return 0
  xray_balancer "${s[$((c - 1))]}"
}

# ── РФ-сайты напрямую ─────────────────────────────────────
# Базы runetfreedom лежат рядом с xray: ext:geoip_RU.dat / ext:geosite_RU.dat.
xray_ru_update() {
  local tmp f want rc bak="" why
  mktmp tmp -d || return 1
  for f in geoip geosite; do
    gh_fetch "$XRAY_RUGEO_URL/$f.dat" "$tmp/$f.dat" 100000 any || { err "Не скачался $f.dat"; return 1; }
    want=""
    gh_fetch "$XRAY_RUGEO_URL/$f.dat.sha256sum" "$tmp/$f.sha" 64 any && want=$(awk '{print $1; exit}' "$tmp/$f.sha")
    rc=0; sha256_check "$tmp/$f.dat" "$want" || rc=$?
    (( rc == 1 )) && { err "$f.dat: контрольная сумма не совпала"; return 1; }
  done
  if [[ -f "$XRAY_ASSET_DIR/geoip_RU.dat" ]]; then
    bak="$tmp/bak"; mkdir -p "$bak"
    cp -a "$XRAY_ASSET_DIR"/geo{ip,site}_RU.dat "$bak/" 2>/dev/null || true
  fi
  install -m 644 "$tmp/geoip.dat" "$XRAY_ASSET_DIR/geoip_RU.dat"
  install -m 644 "$tmp/geosite.dat" "$XRAY_ASSET_DIR/geosite_RU.dat"
  if xray_ru_on && ! why=$(xray_test); then
    err "Xray не принял новые базы: $why"
    [[ -n "$bak" ]] && cp -a "$bak"/* "$XRAY_ASSET_DIR/" && warn "Возвращены прежние базы"
    return 1
  fi
  ok "РФ-базы обновлены"
}

_xray_ru_timer() {
  if [[ "$1" == off ]]; then remove_unit awg-xray-rugeo.timer awg-xray-rugeo.service; return 0; fi
  write_unit awg-xray-rugeo.service <<EOF
[Unit]
Description=AWG Toolza — обновление РФ-баз Xray
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --xray-ru-update
EOF
  write_unit awg-xray-rugeo.timer <<'EOF'
[Unit]
Description=AWG Toolza — обновление РФ-баз Xray раз в неделю

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl enable --now awg-xray-rugeo.timer &>/dev/null || warn "Таймер обновления баз не включился"
}

xray_ru_toggle() {
  xray_installed || { err "Xray не установлен"; return 1; }
  if xray_ru_on; then xray_ru_set off
  else
    echo -e "  ${D}.ru/.su/.рф, сервисы «только из РФ» и РФ-IP пойдут с сервера напрямую —${N}"
    echo -e "  ${D}нужно, когда сервер в РФ, а Xray ведёт за границу.${N}"
    xray_ru_set on
  fi
}

# РФ-сайты напрямую: on|off. Работающий туннель перезапускается.
xray_ru_set() {
  local bak why
  xray_installed || { err "Xray не установлен"; return 1; }
  if [[ "$1" == off ]]; then
    xray_ru_on && { py xray-ru "$XRAY_CONF" off && _xray_ru_timer off; }
    ok "РФ-сайты идут через туннель"
  else
    [[ -f "$XRAY_ASSET_DIR/geoip_RU.dat" && -f "$XRAY_ASSET_DIR/geosite_RU.dat" ]] || xray_ru_update || return 1
    mktmp bak || return 1
    cp -a "$XRAY_CONF" "$bak"
    py xray-ru "$XRAY_CONF" on || return 1
    if ! why=$(xray_test); then
      cp -a "$bak" "$XRAY_CONF"
      err "Xray отверг правила — конфиг возвращён: $why"
      return 1
    fi
    _xray_ru_timer on
    ok "РФ-сайты идут напрямую, базы обновляются раз в неделю"
  fi
  if xray_is_up; then info "Перезапускаю туннель"; xray_restart; fi
  return 0
}

# ── Маршрутизация (awg-xray-routing.service) ──────────────
xray_routing_run() {
  local i nat=""
  if [[ "${1:-}" == stop ]]; then rt_down "$XRAY_IF" "$XRAY_TABLE"; return 0; fi
  # Inbound tun самого Xray выбирает выход клиента по его адресу — без NAT
  grep -qx 'tun_mode=native' "$XRAY_STATE" 2>/dev/null && nat=nonat
  for i in $(seq 1 40); do ip link show "$XRAY_IF" &>/dev/null && break; sleep 0.5; done
  ip link show "$XRAY_IF" &>/dev/null || { echo "$XRAY_IF не появился" >&2; return 1; }
  ip addr add "$XRAY_TUN_ADDR" dev "$XRAY_IF" 2>/dev/null || true
  ip link set "$XRAY_IF" up
  # Мёртвый выход — не повод оставить клиентов без интернета: ждём до
  # минуты (при загрузке сеть поднимается не сразу), потом идём напрямую.
  for i in $(seq 1 8); do
    socks_probe "$XRAY_SOCKS" >/dev/null && { rt_up "$XRAY_IF" "$XRAY_TABLE" "$XRAY_PEERS" "" "$nat"; return; }
    sleep 5
  done
  echo "через Xray трафик не идёт — клиенты остаются на прямом маршруте" >&2
  return 1
}

_xray_emit_routing() {
  emit_script "$XRAY_ROUTING_SCRIPT" 'xray_routing_run "$@"' XRAY_IF XRAY_TABLE XRAY_PEERS XRAY_STATE \
    XRAY_TUN_ADDR XRAY_SOCKS socks_probe "${RT_FUNCS[@]}" xray_routing_run
}

_xray_write_units() {  # режим
  local mode="$1" after="$XRAY_UNIT"
  _xray_emit_routing || return 1
  write_unit "$XRAY_UNIT" <<EOF
[Unit]
Description=AWG Toolza — Xray
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=$XRAY_STATE

[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CONF
# После перезапуска Xray (в том числе автоматического) xray0 создаётся
# заново, а маршрут в таблице 201 умирает вместе со старым интерфейсом.
ExecStartPost=-/usr/bin/systemctl --no-block restart $XRAY_ROUTING_UNIT
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  if [[ "$mode" == tun2socks ]]; then
    after="$XRAY_UNIT $XRAY_TUN_UNIT"
    # Флаги только в длинной форме: pflag на «-device» печатает usage и
    # выходит с кодом 0 — юнит «работает» без интерфейса.
    write_unit "$XRAY_TUN_UNIT" <<EOF
[Unit]
Description=AWG Toolza — xray0 через tun2socks
After=$XRAY_UNIT
PartOf=$XRAY_UNIT

[Service]
ExecStart=$T2S_BIN --device tun://$XRAY_IF --proxy socks5://$XRAY_SOCKS --loglevel warn
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  else
    remove_unit "$XRAY_TUN_UNIT"
  fi
  write_unit "$XRAY_ROUTING_UNIT" <<EOF
[Unit]
Description=AWG Toolza — маршруты клиентов в Xray
After=$after awg-quick@awg0.service
PartOf=$XRAY_UNIT

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
ExecStart=$XRAY_ROUTING_SCRIPT start
ExecStop=$XRAY_ROUTING_SCRIPT stop

[Install]
WantedBy=multi-user.target
EOF
}

# ── Включение / выключение ────────────────────────────────
xray_up() {
  local mode=native why owners i units
  server_exists || { err "Сначала создай сервер"; return 1; }
  xray_installed || { err "Сначала установи Xray"; return 1; }
  xray_is_up && { info "Xray уже включён"; return 0; }
  [[ -n "$(xray_tags)" ]] || { err "Нет ни одного выхода — добавь выход ссылкой"; return 1; }
  tunnel_guard xray || return 1
  if ! xray_tun_supported; then
    mode=tun2socks
    info "Эта сборка Xray без inbound tun — xray0 поднимет tun2socks"
    t2s_install_bin || return 1
  fi
  peers_sync "$XRAY_PEERS"; peers_seed "$XRAY_PEERS"
  py xray-prepare "$XRAY_CONF" "$mode" "$XRAY_PEERS" || { err "Не удалось подготовить конфиг"; return 1; }
  # Прежние версии запускали Xray временными юнитами с теми же именами
  systemctl stop "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl reset-failed "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  owners=$(xray_port_owners)
  if [[ -n "$owners" ]]; then
    err "$XRAY_SOCKS уже занят — Xray не запустится:"
    sed 's/^/      /' <<< "$owners"
    info "Если это забытый ручной запуск: pkill -f 'xray run'"
    return 1
  fi
  if ! why=$(xray_test); then
    err "Xray отверг конфиг:"
    sed 's/^/      /' <<< "$why"
    info "Разбор по выходам — «Диагностика»"
    return 1
  fi
  printf 'active\nclient_net=%s\niface=%s\ntun_dev=%s\ntun_mode=%s\n' \
    "$(server_net)" "$(uplink_iface)" "$XRAY_IF" "$mode" | write_file "$XRAY_STATE" 644
  _xray_write_units "$mode" || return 1
  units=("$XRAY_UNIT")
  [[ "$mode" == tun2socks ]] && units+=("$XRAY_TUN_UNIT")
  systemctl start "${units[@]}" &>/dev/null
  for i in $(seq 1 20); do ip link show "$XRAY_IF" &>/dev/null && break; sleep 0.5; done
  if ! unit_active "$XRAY_UNIT" || ! ip link show "$XRAY_IF" &>/dev/null; then
    err "Xray не поднял $XRAY_IF: journalctl -u $XRAY_UNIT -n 30"
    xray_down quiet
    return 1
  fi
  info "Проверяю, идёт ли трафик через Xray..."
  if ! why=$(socks_probe "$XRAY_SOCKS"); then
    err "Через Xray трафик не идёт (ответ: $why) — туннель не включаю"
    info "Клиенты остались на прямом маршруте. Логи: journalctl -u $XRAY_UNIT -n 30"
    xray_down quiet
    return 1
  fi
  systemctl start "$XRAY_ROUTING_UNIT" || { err "Маршруты не применились: journalctl -u $XRAY_ROUTING_UNIT"; xray_down quiet; return 1; }
  systemctl enable "${units[@]}" "$XRAY_ROUTING_UNIT" &>/dev/null
  ok "Xray включён ($mode): клиентов через туннель — $(grep -c . "$XRAY_PEERS" || true)"
}

xray_down() {
  systemctl stop "$XRAY_ROUTING_UNIT" &>/dev/null || true
  systemctl disable "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl stop "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl reset-failed "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  rt_down "$XRAY_IF" "$XRAY_TABLE"
  ip link del "$XRAY_IF" &>/dev/null || true
  rm -f "$XRAY_STATE"
  [[ "${1:-}" == quiet ]] || ok "Xray выключен — клиенты идут напрямую"
}

xray_restart() { xray_down quiet; xray_up; }

xray_remove() {
  read_confirm "${R}  Удалить Xray (бинарь, конфиг с выходами, службы)? (введи yes): ${N}" || return 0
  xray_uninstall
}

xray_uninstall() {
  xray_down quiet
  remove_unit "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" awg-xray-rugeo.timer awg-xray-rugeo.service
  rm -rf "$XRAY_DIR" "$XRAY_BIN" "$XRAY_ROUTING_SCRIPT" \
    "$XRAY_ASSET_DIR"/geoip.dat "$XRAY_ASSET_DIR"/geosite.dat "$XRAY_ASSET_DIR"/geo{ip,site}_RU.dat
  ok "Xray удалён"
}

# ── Статус и диагностика ──────────────────────────────────
xray_status() {
  local tags=() n total name tag
  if ! xray_installed; then echo -e "  Xray      : ${D}○ не установлен${N}"; return 0; fi
  echo -e "  Версия    : $("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
  if ip link show "$XRAY_IF" &>/dev/null; then
    echo -e "  Туннель   : ${G}● включён${N} ${D}($(xray_state_get tun_mode))${N}"
    n=$(grep -c . "$XRAY_PEERS" 2>/dev/null || true); total=$(clients_name_ip | wc -l)
    echo -e "  Клиентов  : ${W}${n:-0}${N} из $total через Xray"
  elif [[ -f "$XRAY_STATE" ]]; then
    echo -e "  Туннель   : ${R}▲ включён, но $XRAY_IF нет${N} ${D}— journalctl -u $XRAY_UNIT${N}"
  else
    echo -e "  Туннель   : ${D}○ выключен${N}"
  fi
  mapfile -t tags < <(xray_tags)
  echo -e "  Выходы    : ${W}${tags[*]:-нет}${N}"
  echo -e "  Балансир  : $(py xray-balancer-get "$XRAY_CONF" 2>/dev/null || echo off)"
  (( ${#tags[@]} )) && echo -e "  По умолч. : ${W}$(py xray-main-get "$XRAY_CONF" 2>/dev/null | sed 's/^balancer$/балансировщик/')${N}"
  xray_client_outs | while IFS='|' read -r name _ tag; do
    echo -e "  ${D}  $name → $tag$(xray_tags | grep -qxF "$tag" || echo " (выхода нет — по умолчанию)")${N}"
  done
  xray_ru_on && echo -e "  РФ-сайты  : ${G}напрямую${N}"
  return 0
}

# Выходы, которых эта сборка Xray не принимает (по тегу в строке).
xray_bad_outbounds() {
  local t probe
  mktmp probe .json || return 1
  while IFS= read -r t; do
    py xray-probe-tag "$XRAY_CONF" "$t" "$probe" && ! xray_test "$probe" >/dev/null && echo "$t"
  done < <(xray_tags)
  return 0
}

xray_fix() {
  local bad=()
  mapfile -t bad < <(xray_bad_outbounds)
  if (( ${#bad[@]} )); then
    py xray-del "$XRAY_CONF" "${bad[@]}"
    _xray_peers_untag "${bad[@]}" >/dev/null
  fi
  _xray_prepare
  if xray_test >/dev/null; then ok "Конфиг принят Xray${bad[*]:+, убраны: ${bad[*]}}"
  else err "Конфиг всё ещё отвергается"; return 1; fi
}

xray_diagnose() {
  local owners why bad=()
  xray_installed || { err "Xray не установлен"; return 1; }
  info "Бинарь: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  if xray_tun_supported; then info "Inbound tun: есть — xray0 поднимает сам Xray"
  else info "Inbound tun: нет — xray0 поднимает tun2socks через $XRAY_SOCKS"; fi
  owners=$(xray_port_owners)
  if (( $(grep -c . <<< "$owners") > 1 )); then
    err "На $XRAY_SOCKS слушают несколько процессов — трафик делится между ними:"
    sed 's/^/      /' <<< "$owners"
  elif [[ -n "$owners" ]]; then
    info "$XRAY_SOCKS слушает: $owners"
  fi
  if why=$(xray_test); then ok "Конфиг принят Xray"; return 0; fi
  err "Конфиг отвергнут:"
  sed 's/^/      /' <<< "$why"
  mapfile -t bad < <(xray_bad_outbounds)
  if (( ${#bad[@]} )); then
    warn "Эта сборка Xray не принимает выходы: ${bad[*]}"
    if (( AUTO_MODE )); then info "Убрать их — «Починить конфиг»"
    elif ask_yes "  Удалить их из конфига? [Y/n]: " y; then xray_fix; fi
  else
    info "Выходы по отдельности принимаются — дело в маршрутизации."
    info "Включение туннеля само чинит ссылки на удалённые выходы."
  fi
}

do_xray_menu() {
  local c
  while true; do
    echo ""
    hdr "Xray"
    xray_status
    echo ""
    echo -e "  ${C}1)${N} Установить / обновить"
    echo -e "  ${C}2)${N} Добавить выход (ссылка)"
    echo -e "  ${C}3)${N} Удалить выход"
    echo -e "  ${C}4)${N} Балансировщик"
    echo -e "  ${C}m)${N} Выход по умолчанию"
    echo -e "  ${C}o)${N} Свой выход клиенту"
    echo -e "  ${C}5)${N} Включить туннель"
    echo -e "  ${C}6)${N} Выключить туннель"
    echo -e "  ${C}7)${N} Перезапустить туннель"
    echo -e "  ${C}8)${N} Клиенты в Xray"
    echo -e "  ${C}9)${N} Диагностика"
    echo -e "  ${C}r)${N} РФ-сайты напрямую $(xray_ru_on && echo -e "${G}● вкл${N}" || echo -e "${D}○ выкл${N}")"
    echo -e "  ${R}d)${N} Удалить Xray"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 9 0 "r|d|m|o"
    case "$c" in
      1) xray_install || true ;;
      2) xray_add_outbound || true ;;
      3) xray_del_outbound || true ;;
      4) xray_balancer_menu || true ;;
      m) xray_main_menu || true ;;
      o) xray_client_menu || true ;;
      5) xray_up || true ;;
      6) xray_down ;;
      7) xray_restart || true ;;
      8) tunnel_peers_menu "Клиенты в Xray" "$XRAY_PEERS" "$XRAY_IF" "$XRAY_TABLE"; continue ;;
      9) xray_diagnose || true ;;
      r) xray_ru_toggle || true ;;
      d) xray_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
