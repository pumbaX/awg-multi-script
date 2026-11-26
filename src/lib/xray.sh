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
# Сбой включённого Xray: down — Xray не запущен (xray0 нет); notraffic — запущен,
# но служба маршрутов не дождалась трафика через выход (ссылка устарела, сервер
# выхода лежит) — клиенты Xray не в туннеле. Пока маршруты ждут (при загрузке до
# минуты) — не сбой. Пусто и 1 — сбоя нет или Xray выключен.
xray_fail() {
  [[ -f "$XRAY_STATE" ]] || return 1
  if ! ip link show "$XRAY_IF" &>/dev/null && ! unit_active "$XRAY_UNIT"; then echo down; return 0; fi
  systemctl is-failed --quiet "$XRAY_ROUTING_UNIT" 2>/dev/null && { echo notraffic; return 0; }
  return 1
}
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
  local asset base tmp want rc why prev=""
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
  [[ -x "$XRAY_BIN" ]] && cp -p "$XRAY_BIN" "$tmp/xray.prev" && prev="$tmp/xray.prev"
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  ok "Xray: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  _XRAY_TUN=""
  mkdir -p "$XRAY_DIR" && chmod 700 "$XRAY_DIR"
  [[ -f "$XRAY_CONF" ]] || py xray-default "$XRAY_CONF"
  # Новые версии Xray строже к конфигу — то, что писали прежние версии Тулзы,
  # приводится к ним заранее
  py xray-compat "$XRAY_CONF"
  if xray_is_up; then
    # Конфиг, который новый Xray не примет, уронил бы работающий туннель:
    # проверяем до перезапуска и в этом случае возвращаем прежний бинарь
    if [[ -n "$prev" ]] && ! why=$(xray_test); then
      err "Новый Xray не принимает конфиг:"
      sed 's/^/      /' <<< "$why"
      install -m 755 "$prev" "$XRAY_BIN"
      _XRAY_TUN=""
      warn "Вернул прежний Xray: $("$XRAY_BIN" version 2>/dev/null | head -1) — туннель работает на нём"
      return 1
    fi
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

# Клиенты удалённых выходов (и клиенты обфускатора) — на выход по умолчанию;
# печатает, сколько их.
_xray_peers_untag() {  # тег...
  local f n=0 c
  for f in "$XRAY_PEERS" "$XRAY_PEERS.wgobf"; do
    [[ -f "$f" ]] || continue
    c=$(awk -F'|' 'NR == FNR {d[$0] = 1; next} NF > 1 && ($2 in d) {c++} END {print c + 0}' <(printf '%s\n' "$@") "$f")
    n=$((n + c))
    awk -F'|' 'NR == FNR {d[$0] = 1; next} NF > 1 && ($2 in d) {print $1; next} {print}' \
      <(printf '%s\n' "$@") "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  done
  echo "$n"
}

xray_del_tag() {  # тег
  local n
  xray_tags | grep -qxF "$1" || { err "Выхода $1 нет"; return 1; }
  py xray-del "$XRAY_CONF" "$1"
  n=$(_xray_peers_untag "$1")
  _xray_prepare
  ok "Выход $1 удалён"
  [[ "$1" == sub_* ]] && xray_sub_on && info "Это сервер подписки — при её обновлении он вернётся"
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

# Observatory (leastPing|leastLoad): URL / интервал / параллельная проверка выходов.
xray_obs_on() {
  local b
  b=$(py xray-balancer-get "$XRAY_CONF" 2>/dev/null) || return 1
  [[ "$b" == leastPing || "$b" == leastLoad ]]
}

xray_observatory() {  # url|interval|concurrency значение
  local field="${1:-}" value="${2:-}"
  [[ "$field" =~ ^(url|interval|concurrency)$ && -n "$value" ]] \
    || { err "observatory: url URL | interval 10s|15s|30s|1m|2m | concurrency on|off"; return 1; }
  xray_installed || { err "Xray не установлен"; return 1; }
  py xray-observatory-set "$XRAY_CONF" "$field" "$value" >/dev/null || return 1
  case "$field" in
    url) ok "URL проверки: $value" ;;
    interval) ok "Интервал проверки: $value" ;;
    concurrency) ok "Параллельная проверка: $value" ;;
  esac
  xray_is_up && xray_restart
  return 0
}

xray_observatory_menu() {
  local c url interval conc=0 urls ivals line
  xray_obs_on || { warn "Проверка выходов — только при leastPing или leastLoad"; return 0; }
  line=$(py xray-observatory-get "$XRAY_CONF" shell 2>/dev/null) || return 1
  IFS=$'\t' read -r url interval conc <<< "$line"
  echo -e "  URL проверки: ${W}${url:-?}${N}"
  echo -e "  Интервал    : ${W}${interval:-?}${N}"
  echo -e "  Параллельно : ${W}$( (( conc )) && echo вкл || echo выкл)${N}"
  echo -e "  ${C}1)${N} URL проверки ${D}— Google / Gstatic / Cloudflare / свой${N}"
  echo -e "  ${C}2)${N} Интервал ${D}— 10s / 15s / 30s / 1m / 2m${N}"
  echo -e "  ${C}3)${N} Параллельная проверка выходов ${D}— переключить${N}"
  read_choice c "${C}  Выбор [1-3] (0 — назад): ${N}" 0 3 0
  case "$c" in
    1)
      urls=("https://www.google.com/generate_204" "https://www.gstatic.com/generate_204"
            "http://cp.cloudflare.com/generate_204")
      echo -e "  ${C}1)${N} Google ${D}— ${urls[0]}${N}"
      echo -e "  ${C}2)${N} Gstatic ${D}— ${urls[1]}${N}"
      echo -e "  ${C}3)${N} Cloudflare ${D}— ${urls[2]}${N}"
      echo -e "  ${C}4)${N} Свой URL"
      read_choice c "${C}  URL [1-4] (0 — отмена): ${N}" 0 4 0
      (( c )) || return 0
      if (( c == 4 )); then
        read_line url "${C}  http(s)://… : ${N}"
        [[ -n "$url" ]] || return 0
      else
        url="${urls[$((c - 1))]}"
      fi
      xray_observatory url "$url" || true ;;
    2)
      ivals=(10s 15s 30s 1m 2m)
      echo -e "  ${C}1)${N} 10s  ${C}2)${N} 15s  ${C}3)${N} 30s  ${C}4)${N} 1m  ${C}5)${N} 2m"
      read_choice c "${C}  Интервал [1-5] (0 — отмена): ${N}" 0 5 0
      (( c )) || return 0
      xray_observatory interval "${ivals[$((c - 1))]}" || true ;;
    3)
      if (( conc )); then xray_observatory concurrency off || true
      else xray_observatory concurrency on || true; fi ;;
  esac
}

xray_balancer_menu() {
  local c s=(random roundRobin leastPing leastLoad off) n bal max=5
  n=$(xray_tags | grep -c . || true)
  (( n >= 2 )) || { warn "Для балансировки нужно минимум 2 выхода"; return 0; }
  bal=$(py xray-balancer-get "$XRAY_CONF")
  echo -e "  Сейчас: ${W}$bal${N}"
  echo -e "  ${C}1)${N} random ${D}— случайный выход${N}"
  echo -e "  ${C}2)${N} roundRobin ${D}— по очереди${N}"
  echo -e "  ${C}3)${N} leastPing ${D}— самый быстрый${N}"
  echo -e "  ${C}4)${N} leastLoad ${D}— наименее загружен${N}"
  echo -e "  ${C}5)${N} Выключить ${D}— первый выход${N}"
  if [[ "$bal" == leastPing || "$bal" == leastLoad ]]; then
    echo -e "  ${C}6)${N} Проверка выходов ${D}— URL / интервал / параллельно${N}"
    max=6
  fi
  read_choice c "${C}  Выбор [1-$max] (0 — отмена): ${N}" 0 "$max" 0
  (( c )) || return 0
  if (( c == 6 )); then xray_observatory_menu; return; fi
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

# ── Подписка ──────────────────────────────────────────────
# Адрес подписки — секрет (в нём ключ доступа к серверам провайдера): лежит в
# sub.conf (600), в аргументы команд и журналы не попадает — curl получает
# его конфигом через stdin, на экранах только сайт. Серверы подписки — выходы
# с тегами sub_…: обновление заменяет только их, свои выходы (ссылкой) не
# трогает. Каждый сервер проверяется на самом Xray; конфиг, который Xray не
# принял, и подписка, через новые серверы которой не пошёл трафик, —
# откатываются к прежним выходам. Таймер раз в час смотрит срок и идёт через
# замок API — не мешает правкам из бота и панели.
XSUB_WHY=""
_xsub_get() { sed -n "s/^$1=//p" "$XRAY_SUB_CONF" 2>/dev/null | tail -1; }
# Число из sub.conf (файл мог прийти из чужого бэкапа — в арифметику только цифры)
_xsub_num() { local v; v=$(_xsub_get "$1"); [[ "$v" =~ ^[0-9]{1,20}$ ]] && echo "$v" || echo 0; }

_xsub_set() {  # КЛЮЧ=ЗНАЧЕНИЕ...
  local kv keys=()
  mkdir -p "$XRAY_DIR"
  for kv in "$@"; do keys+=("${kv%%=*}"); done
  { grep -vE "^($(IFS='|'; echo "${keys[*]}"))=" "$XRAY_SUB_CONF" 2>/dev/null
    for kv in "$@"; do printf '%s\n' "${kv//[$'\n\r']/ }"; done; } | write_file "$XRAY_SUB_CONF" 600
}

_xsub_fail() { XSUB_WHY="$1"; err "$1"; return 1; }

xray_sub_on() { [[ -n "$(_xsub_get URL)" ]]; }

# Сайт подписки для показа — адрес целиком секрет
xray_sub_site() {  # [адрес]
  local a="${1:-$(_xsub_get URL)}"
  a="${a#*://}"; a="${a%%[/?#]*}"; echo "${a##*@}"
}

# Адрес: https (http — только с подтверждением insecure: его могут подменить
# по дороге), без пробелов, кавычек и обратной косой — он уходит в конфиг curl
_xsub_url_ok() {  # адрес 0|1
  local u="$1" site
  if (( ${#u} > 2048 )) || [[ -z "$u" || "$u" == *[[:space:]]* || "$u" == *[[:cntrl:]]* || "$u" == *'"'* || "$u" == *'\'* ]]; then
    _xsub_fail "Адрес подписки: без пробелов и кавычек, не длиннее 2048 знаков"; return 1
  fi
  case "$u" in
    https://*) ;;
    http://*) [[ "$2" == 1 ]] || { _xsub_fail "Подписка по http: её могут подменить по дороге — нужен https или подтверждение"; return 3; } ;;
    *) _xsub_fail "Адрес подписки начинается с https://"; return 1 ;;
  esac
  site=$(xray_sub_site "$u")
  [[ -n "${site%%:*}" && "$site" != :* ]] || { _xsub_fail "В адресе подписки нет сайта"; return 1; }
}

# Скачать подписку в каталог: body и headers. Ответ больше XRAY_SUB_MAX — отказ.
_xsub_fetch() {  # адрес 0|1 каталог
  local url="$1" dir="$3" proto='=https' rc size why
  [[ "$2" == 1 ]] && proto='=https,http'
  printf 'url = "%s"\n' "$url" \
    | curl -K - -sS -f -L --max-redirs 3 --proto "$proto" --proto-redir "$proto" --connect-timeout 15 \
        --max-time 60 -A "$XRAY_SUB_UA" -D "$dir/headers" -o - 2>"$dir/err" \
    | head -c $((XRAY_SUB_MAX + 1)) > "$dir/body"
  rc=${PIPESTATUS[1]}
  size=$(stat -c %s "$dir/body" 2>/dev/null || echo 0)
  (( size > XRAY_SUB_MAX )) && { _xsub_fail "Подписка больше 2 МБ — это не список серверов"; return 1; }
  (( rc == 0 )) && return 0
  why=$(tail -1 "$dir/err" 2>/dev/null | sed 's/^curl: ([0-9]*) //')
  why="${why//"$url"/$(xray_sub_site "$url")}"
  case "$rc" in
    1) why="перенаправление на другой протокол — запрещено" ;;
    6) why="сайт подписки не найден (DNS)" ;;
    7) why="сайт подписки недоступен" ;;
    22) why="сервер подписки ответил ошибкой ${why##*error: }" ;;
    28) why="сервер подписки не ответил за 60 с" ;;
    47) why="слишком много перенаправлений" ;;
  esac
  _xsub_fail "Подписка не скачалась: ${why:-curl $rc}"
}

_xsub_count() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$1"; }

# Серверы подписки, которых этот Xray не принимает, — убрать (печатает их имена).
# Сначала все разом; не принят конфиг — по одному.
_xsub_probe() {  # parsed.json
  local probe n i bad=()
  probe=$(mktemp --suffix=.json /tmp/awg2.XXXXXX) || return 1
  if py xray-sub-probe "$1" "$probe" && xray_test "$probe" >/dev/null; then rm -f "$probe"; return 0; fi
  n=$(_xsub_count "$1") || { rm -f "$probe"; return 1; }
  for ((i = 0; i < n; i++)); do
    { py xray-sub-probe "$1" "$probe" "$i" && xray_test "$probe" >/dev/null; } || bad+=("$i")
  done
  rm -f "$probe"
  (( ${#bad[@]} )) && py xray-sub-drop "$1" "${bad[@]}"
  return 0
}

_xsub_rollback() {  # каталог копий
  local f
  cp -a "$1/config.json" "$XRAY_CONF"
  if [[ -f "$1/sub.list" ]]; then cp -a "$1/sub.list" "$XRAY_SUB_LIST"; else rm -f "$XRAY_SUB_LIST"; fi
  for f in "$XRAY_PEERS" "$XRAY_PEERS.wgobf"; do [[ -f "$1/${f##*/}" ]] && cp -a "$1/${f##*/}" "$f"; done
  return 0
}

# Туннель Xray включён (работает или должен работать)
_xray_enabled() { [[ -f "$XRAY_STATE" ]] || xray_is_up; }

# Скачать, разобрать, проверить и применить подписку; записать её сведения.
# Работающий туннель перезапускается, только если серверы поменялись.
_xray_sub_sync() {  # адрес 0|1
  local d res changed gone=() n bad moved="" why meta=() f
  XSUB_WHY=""
  mktmp d -d || return 1
  _xsub_fetch "$1" "$2" "$d" || return 1
  if ! py xray-sub-parse "$d/body" "$d/parsed.json" 2>"$d/perr"; then
    _xsub_fail "Подписка: $(tail -1 "$d/perr")"; return 1
  fi
  bad=$(_xsub_probe "$d/parsed.json") || { _xsub_fail "Серверы подписки не проверены"; return 1; }
  [[ -n "$bad" ]] && warn "Этот Xray не принимает серверы: $(paste -sd, <<< "$bad" | sed 's/,/, /g')"
  n=$(_xsub_count "$d/parsed.json") || n=0
  (( n > 0 )) || { _xsub_fail "Ни один сервер подписки не принят этим Xray — обнови Xray (Установить / обновить)"; return 1; }
  mkdir -p "$d/bak" && cp -a "$XRAY_CONF" "$d/bak/config.json" || return 1
  for f in "$XRAY_SUB_LIST" "$XRAY_PEERS" "$XRAY_PEERS.wgobf"; do [[ -f "$f" ]] && cp -a "$f" "$d/bak/"; done
  if ! res=$(py xray-sub-apply "$XRAY_CONF" "$d/parsed.json" "$XRAY_SUB_LIST"); then
    _xsub_rollback "$d/bak"; _xsub_fail "Конфиг Xray не записан"; return 1
  fi
  changed=$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(int(d["changed"])); print("\n".join(d["gone"]))' "$res")
  mapfile -t gone < <(tail -n +2 <<< "$changed" | grep .)
  changed=$(head -1 <<< "$changed")
  (( ${#gone[@]} )) && moved=$(_xray_peers_untag "${gone[@]}")
  if ! _xray_prepare || ! why=$(xray_test); then
    _xsub_rollback "$d/bak"
    _xsub_fail "Xray не принял конфиг с подпиской — оставлены прежние выходы${why:+: $(head -1 <<< "$why")}"; return 1
  fi
  if (( changed )) && _xray_enabled; then
    info "Серверы подписки поменялись — перезапускаю туннель"
    if ! xray_restart; then
      _xsub_rollback "$d/bak"; _xray_prepare || true
      warn "Туннель с новыми серверами не поднялся — возвращаю прежние"
      xray_up || true
      _xsub_fail "Туннель с серверами подписки не поднялся (через них не идёт трафик) — оставлены прежние"; return 1
    fi
  fi
  mapfile -t meta < <(py xray-sub-meta "$d/headers")
  _xsub_set "${meta[@]}" "COUNT=$n" "SKIPPED=$(python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("skipped", 0)))' "$d/parsed.json")" \
    "UPDATED=$(date +%s)" "CHECKED=$(date +%s)" "ERROR="
  ok "Подписка: серверов $n$( (( changed )) || echo ", без изменений")"
  (( ${moved:-0} )) && info "Клиенты ушедших серверов ($moved) — на выходе по умолчанию"
  return 0
}

# Задать подписку (сменить адрес): сразу скачивается и применяется; не вышло —
# прежняя подписка остаётся как была.
xray_sub_set() {  # адрес [insecure]
  local url="$1" ins=0 rc=0
  [[ "${2:-}" == insecure ]] && ins=1
  xray_installed || { err "Сначала установи Xray"; return 1; }
  _xsub_url_ok "$url" "$ins" || return $?
  (( ins )) && warn "Подписка по http: её могут подменить по дороге"
  _xray_sub_sync "$url" "$ins" || return 1
  _xsub_set "URL=$url" "INSECURE=$ins"
  _xray_sub_timer on
  touch "$XRAY_DIR/.sub-heal" 2>/dev/null || true
  log_info "xray: подписка $(xray_sub_site "$url")"
  info "Обновляется сама раз в $(xray_sub_every) ч"
  return "$rc"
}

xray_sub_every() {
  local h; h=$(_xsub_num INTERVAL)
  (( h >= 1 && h <= 24 )) && echo "$h" || echo "$XRAY_SUB_EVERY"
}

# Срок: прошёл интервал с удачного обновления; не чаще раза в час (и после неудачи)
_xsub_due() {
  local now; now=$(date +%s)
  (( now - $(_xsub_num CHECKED) >= 3300 )) || return 1
  (( now - $(_xsub_num UPDATED) >= $(xray_sub_every) * 3600 - 300 ))
}

xray_sub_update() {  # [auto] — auto: только если подошёл срок (таймер)
  local url ins
  xray_installed || { err "Xray не установлен"; return 1; }
  if ! xray_sub_on; then [[ "${1:-}" == auto ]] && return 0; err "Подписка не задана"; return 1; fi
  if [[ "${1:-}" == auto ]]; then
    touch "$XRAY_DIR/.sub-heal" 2>/dev/null || true
    _xsub_due || return 0
  fi
  url=$(_xsub_get URL); ins=0; [[ "$(_xsub_get INSECURE)" == 1 ]] && ins=1
  if _xsub_url_ok "$url" "$ins" && _xray_sub_sync "$url" "$ins"; then return 0; fi
  _xsub_set "CHECKED=$(date +%s)" "ERROR=${XSUB_WHY:-не обновилась}"
  log_info "xray: подписка не обновилась — ${XSUB_WHY:-?}"
  return 1
}

# Убрать подписку и её серверы. Если туннель держится только на них — отказ.
xray_sub_off() {
  local res changed gone=() subs=() moved=""
  xray_installed || { err "Xray не установлен"; return 1; }
  xray_sub_on || [[ -s "$XRAY_SUB_LIST" ]] || { info "Подписки нет"; return 0; }
  if ! xray_tags | grep -qv '^sub_' && _xray_enabled; then
    err "Туннель Xray работает только на серверах подписки — сначала выключи его или добавь свой выход ссылкой"
    return 1
  fi
  res=$(py xray-sub-apply "$XRAY_CONF" - "$XRAY_SUB_LIST") || { err "Конфиг Xray не записан"; return 1; }
  changed=$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(int(d["changed"])); print("\n".join(d["gone"]))' "$res")
  mapfile -t gone < <(tail -n +2 <<< "$changed" | grep .)
  changed=$(head -1 <<< "$changed")
  # Клиенты на любом сервере подписки (и уже удалённом руками) — на выход по умолчанию
  mapfile -t subs < <(cat "$XRAY_PEERS" "$XRAY_PEERS.wgobf" 2>/dev/null | awk -F'|' '$2 ~ /^sub_/ {print $2}' | sort -u)
  (( ${#subs[@]} )) && moved=$(_xray_peers_untag "${subs[@]}")
  _xray_prepare || true
  rm -f "$XRAY_SUB_CONF" "$XRAY_SUB_LIST" "$XRAY_DIR/.sub-heal"
  _xray_sub_timer off
  log_info "xray: подписка убрана"
  ok "Подписка убрана${gone[*]:+, её серверов: ${#gone[@]}}"
  (( ${moved:-0} )) && info "Клиенты её серверов ($moved) — на выходе по умолчанию"
  if (( changed )) && _xray_enabled; then info "Перезапускаю туннель"; xray_restart || true; fi
  return 0
}

_xray_sub_timer() {  # on|off
  if [[ "$1" == off ]]; then remove_unit "$XRAY_SUB_TIMER" "${XRAY_SUB_TIMER%.timer}.service"; return 0; fi
  write_unit "${XRAY_SUB_TIMER%.timer}.service" <<EOF
[Unit]
Description=AWG Toolza — подписка Xray: обновить, если подошёл срок
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=API_LOCK_WAIT=900
TimeoutStartSec=1200
ExecStart=$SCRIPT_PATH api xray sub update auto
EOF
  write_unit "$XRAY_SUB_TIMER" <<'EOF'
[Unit]
Description=AWG Toolza — подписка Xray: проверка раз в час

[Timer]
OnBootSec=300
OnUnitActiveSec=3600
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
  systemctl enable --now "$XRAY_SUB_TIMER" &>/dev/null || warn "Таймер подписки не включился"
}

# Сторож: таймера нет (восстановили бэкап, Xray переустановлен) — поставить;
# молчит больше трёх часов — перезапустить
xray_sub_watchdog() {
  local f="$XRAY_DIR/.sub-heal" age
  xray_sub_on && xray_installed || return 0
  if ! unit_enabled "$XRAY_SUB_TIMER"; then _xray_sub_timer on; touch "$f" 2>/dev/null; return 0; fi
  [[ -f "$f" ]] || { touch "$f" 2>/dev/null; return 0; }
  age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
  (( age < 10800 )) && return 0
  touch "$f"
  timer_heal "$XRAY_SUB_TIMER"
}

xray_sub_status() {
  local upd err tot exp
  if ! xray_sub_on; then echo -e "  Подписка  : ${D}○ не задана${N}"; return 0; fi
  upd=$(_xsub_num UPDATED); err=$(_xsub_get ERROR)
  echo -e "  Подписка  : ${W}$(xray_sub_site)${N}$([[ -n "$(_xsub_get TITLE)" ]] && echo " ${D}($(_xsub_get TITLE))${N}") — серверов $(_xsub_num COUNT)"
  (( upd )) && echo -e "  ${D}  обновлена $(date -d "@$upd" '+%d.%m %H:%M'), раз в $(xray_sub_every) ч${N}"
  tot=$(_xsub_num TOTAL); exp=$(_xsub_num EXPIRE)
  (( tot )) && echo -e "  ${D}  трафик $(fmt_bytes $(( $(_xsub_num UP) + $(_xsub_num DOWN) ))) из $(fmt_bytes "$tot")${N}"
  (( exp )) && echo -e "  ${D}  действует до $(date -d "@$exp" '+%d.%m.%Y')${N}"
  [[ -n "$err" ]] && echo -e "  ${Y}  ▲ $err${N}"
  return 0
}

do_xray_sub_menu() {
  local c url
  xray_installed || { err "Сначала установи Xray"; return 1; }
  echo ""
  hdr "Подписка Xray"
  echo -e "  ${D}Адрес подписки провайдера (3x-ui, Marzban, Remnawave…): её серверы становятся выходами"
  echo -e "  Xray и обновляются сами. Свои выходы (ссылкой) не трогаются.${N}"
  echo ""
  xray_sub_status
  echo ""
  echo -e "  ${C}1)${N} $(xray_sub_on && echo "Сменить адрес" || echo "Задать адрес")"
  xray_sub_on && echo -e "  ${C}2)${N} Обновить сейчас"
  xray_sub_on && echo -e "  ${C}3)${N} Убрать подписку ${D}(и её серверы)${N}"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор: ${N}" 0 "$(xray_sub_on && echo 3 || echo 1)" 0
  case "$c" in
    1) read_line url "${C}  Адрес подписки (https://…): ${N}"
       url="${url//[[:space:]]/}"
       [[ -n "$url" ]] || return 0
       if [[ "$url" == http://* ]]; then
         warn "Адрес по http: подписку могут подменить по дороге"
         ask_yes "  Всё равно использовать? [y/N]: " n || return 0
         xray_sub_set "$url" insecure
       else
         xray_sub_set "$url"
       fi ;;
    2) xray_sub_update ;;
    3) read_confirm "${R}  Убрать подписку и её серверы? (введи yes): ${N}" || return 0
       xray_sub_off ;;
  esac
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
  echo "через Xray трафик не идёт — клиенты Xray не переведены в туннель" >&2
  echo "$XRAY_CHECK_HINT (Туннели → Xray → Диагностика)" >&2
  return 1
}

_xray_emit_routing() {
  emit_script "$XRAY_ROUTING_SCRIPT" 'xray_routing_run "$@"' XRAY_IF XRAY_TABLE XRAY_PEERS XRAY_STATE \
    XRAY_TUN_ADDR XRAY_SOCKS XRAY_CHECK_HINT socks_probe "${RT_FUNCS[@]}" xray_routing_run
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
    info "${XRAY_CHECK_HINT^}"
    info "Клиенты остались на прямом маршруте"
    xray_down quiet
    return 1
  fi
  systemctl start "$XRAY_ROUTING_UNIT" || { err "Маршруты не применились: journalctl -u $XRAY_ROUTING_UNIT"; xray_down quiet; return 1; }
  systemctl enable "${units[@]}" "$XRAY_ROUTING_UNIT" &>/dev/null
  ok "Xray включён ($mode): клиентов через туннель — $(grep -c . "$XRAY_PEERS" || true)"
}

xray_down() {
  # Состояние — раньше остановки: ExecStop маршрутов в режиме «блокировать»
  # иначе удержал бы клиентов, а ConditionPathExists не даст Xray стартовать
  rm -f "$XRAY_STATE"
  systemctl stop "$XRAY_ROUTING_UNIT" &>/dev/null || true
  systemctl disable "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl stop "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  systemctl reset-failed "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" &>/dev/null || true
  rt_down "$XRAY_IF" "$XRAY_TABLE"
  ip link del "$XRAY_IF" &>/dev/null || true
  [[ "${1:-}" == quiet ]] || ok "Xray выключен — клиенты идут напрямую"
}

xray_restart() { xray_down quiet; xray_up; }

xray_remove() {
  read_confirm "${R}  Удалить Xray (бинарь, конфиг с выходами, службы)? (введи yes): ${N}" || return 0
  xray_uninstall
}

xray_uninstall() {
  xray_down quiet
  remove_unit "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" awg-xray-rugeo.timer awg-xray-rugeo.service \
    "$XRAY_SUB_TIMER" "${XRAY_SUB_TIMER%.timer}.service"
  rm -rf "$XRAY_DIR" "$XRAY_BIN" "$XRAY_ROUTING_SCRIPT" \
    "$XRAY_ASSET_DIR"/geoip.dat "$XRAY_ASSET_DIR"/geosite.dat "$XRAY_ASSET_DIR"/geo{ip,site}_RU.dat
  ok "Xray удалён"
}

# ── Статус и диагностика ──────────────────────────────────
xray_status() {
  local tags=() n total name tag fail obs_line
  if ! xray_installed; then echo -e "  Xray      : ${D}○ не установлен${N}"; return 0; fi
  echo -e "  Версия    : $("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
  fail=$(xray_fail)
  if [[ "$fail" == notraffic ]]; then
    echo -e "  Туннель   : ${R}▲ включён, но через выход трафик не идёт${N} — клиенты Xray не в туннеле"
    echo -e "  ${D}  ${XRAY_CHECK_HINT^}${N}"
  elif ip link show "$XRAY_IF" &>/dev/null; then
    echo -e "  Туннель   : ${G}● включён${N} ${D}($(xray_state_get tun_mode))${N}"
    n=$(grep -c . "$XRAY_PEERS" 2>/dev/null || true); total=$(clients_name_ip | wc -l)
    echo -e "  Клиентов  : ${W}${n:-0}${N} из $total через Xray"
  elif [[ -f "$XRAY_STATE" ]]; then
    echo -e "  Туннель   : ${R}▲ включён, но не запущен${N} — «Перезапустить»; не поднимется — «Диагностика»"
  else
    echo -e "  Туннель   : ${D}○ выключен${N}"
  fi
  mapfile -t tags < <(xray_tags)
  echo -e "  Выходы    : ${W}${tags[*]:-нет}${N}"
  echo -e "  Балансир  : $(py xray-balancer-get "$XRAY_CONF" 2>/dev/null || echo off)"
  if xray_obs_on; then
    obs_line=$(py xray-observatory-get "$XRAY_CONF" line 2>/dev/null) || true
    [[ -n "$obs_line" ]] && echo -e "  Проверка  : ${W}$obs_line${N}"
  fi
  (( ${#tags[@]} )) && echo -e "  По умолч. : ${W}$(py xray-main-get "$XRAY_CONF" 2>/dev/null | sed 's/^balancer$/балансировщик/')${N}"
  xray_client_outs | while IFS='|' read -r name _ tag; do
    echo -e "  ${D}  $name → $tag$(xray_tags | grep -qxF "$tag" || echo " (выхода нет — по умолчанию)")${N}"
  done
  xray_ru_on && echo -e "  РФ-сайты  : ${G}напрямую${N}"
  xray_sub_on && xray_sub_status
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
    echo -e "  ${C}s)${N} Подписка $(xray_sub_on && echo -e "${G}● $(xray_sub_site)${N}" || echo -e "${D}○ нет${N}")"
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
    read_choice c "${C}  Выбор: ${N}" 0 9 0 "r|d|m|o|s"
    case "$c" in
      1) xray_install || true ;;
      2) xray_add_outbound || true ;;
      s) do_xray_sub_menu || true ;;
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
