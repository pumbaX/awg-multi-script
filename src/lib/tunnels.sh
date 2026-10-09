# Общее для туннелей: загрузка релизов, списки клиентов, маршрутизация,
# взаимоисключение и аварийный сброс.
#
# Схема у всех туннелей одна: трафик выбранных клиентов уходит в свою
# таблицу маршрутизации (ip rule from <клиент> lookup N), где маршрут по
# умолчанию ведёт в интерфейс туннеля. Трафик самого сервера и SSH идут
# напрямую — main-таблица не трогается. Таблицы: 100 tun2socks, 200 WARP,
# 201 Xray, 202 AWG exit-ноды (210-249 — персональные ноды клиентов).
# Одновременно активен только один из WARP / Xray / tun2socks / exit-нод.

# ── Загрузка релизов ──────────────────────────────────────
# GitHub в части сетей режут — пробуем зеркала. Файл потом запускается от
# root, поэтому проверяем, что пришёл именно архив/бинарь, а не HTML-заглушка.
gh_fetch() {  # url файл мин_размер zip|elf|any
  local url="$1" dest="$2" min="${3:-100000}" kind="${4:-any}" mp sz
  for mp in "${GH_MIRRORS[@]}"; do
    rm -f "$dest"
    curl -4 -fsSL --connect-timeout 8 --max-time 180 --retry 2 "${mp}${url}" -o "$dest" 2>/dev/null || continue
    sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    (( sz >= min )) || continue
    case "$kind" in
      zip) [[ "$(head -c2 "$dest")" == PK ]] || continue ;;
      elf) head -c4 "$dest" | grep -q $'\x7fELF' || continue ;;
    esac
    return 0
  done
  rm -f "$dest"
  return 1
}

# 0 — совпало, 1 — не совпало, 2 — сверять не с чем.
sha256_check() {
  local f="$1" want="${2,,}"
  [[ "$want" =~ ^[0-9a-f]{64}$ && -f "$f" ]] || return 2
  [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "$want" ]]
}

gh_latest_tag() {  # owner/repo
  GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote --tags --refs "https://github.com/$1.git" 2>/dev/null \
    | sed -n 's#.*refs/tags/##p' | grep -E '^v?[0-9]+\.[0-9]+' | sort -V | tail -1
}

go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;; *) echo "" ;;
  esac
}

# ── Списки клиентов туннеля ───────────────────────────────
# Файл — по адресу клиента на строку (у exit-нод — «адрес|нода»).
# Файла нет — туннель ещё ни разу не включали: при первом включении в него
# попадают все клиенты. Пустой файл — все сознательно выключены.
peers_has() { [[ -f "$1" ]] && grep -qE "^${2//./\\.}(\||$)" "$1"; }

peers_add() {  # файл ip [значение строки]
  mkdir -p "$(dirname "$1")"
  peers_del "$1" "$2"
  echo "${3:-$2}" >> "$1"
}

peers_del() {
  [[ -f "$1" ]] || return 0
  grep -vE "^${2//./\\.}(\||$)" "$1" > "$1.tmp" || true
  mv -f "$1.tmp" "$1"
}

# Убрать адреса, которых больше нет среди клиентов.
peers_sync() {
  local f="$1" live line
  [[ -f "$f" ]] || return 0
  live=" $(clients_name_ip | cut -d'|' -f2 | tr '\n' ' ') "
  while IFS= read -r line; do
    [[ -n "$line" && "$live" == *" ${line%%|*} "* ]] && echo "$line"
  done < "$f" > "$f.tmp" || true
  mv -f "$f.tmp" "$f"
}

# Все клиенты через туннель; строки «IP|выход» (свой выход Xray) остаются.
peers_all() {  # файл
  local ip
  mkdir -p "$(dirname "$1")"
  clients_name_ip | cut -d'|' -f2 | while IFS= read -r ip; do
    grep -E "^${ip//./\\.}(\||$)" "$1" 2>/dev/null | head -1 | grep . || echo "$ip"
  done > "$1.new"
  mv -f "$1.new" "$1"
}

# Свои выходы клиентов Xray живут в конфиге самого Xray (правила по адресу):
# изменились — без пересборки конфига клиент оставался на прежнем выходе,
# хотя список показывал «по умолчанию» или «напрямую».
_xray_outs() { grep -F '|' "$XRAY_PEERS" 2>/dev/null | sort; }
_xray_outs_apply() {  # прежний вывод _xray_outs
  [[ "$(_xray_outs)" != "$1" ]] && xray_is_up || return 0
  _xray_prepare || return 1
  info "Перезапускаю туннель"; xray_restart
}

peers_seed() {
  [[ -f "$1" ]] && return 0
  mkdir -p "$(dirname "$1")"
  clients_name_ip | cut -d'|' -f2 > "$1"
}

# Клиент удалён — убрать его из всех туннелей и снять его правила.
tunnel_peers_forget() {
  local ip="$1" f
  for f in "$WARP_PEERS" "$XRAY_PEERS" "$EXITS_PEERS"; do peers_del "$f" "$ip"; done
  while ip rule del from "$ip" 2>/dev/null; do :; done
}

# ── Маршрутизация ─────────────────────────────────────────
# Функции ниже работают и в служебных скриптах (emit_script), поэтому
# опираются только на константы и базовые помощники.
RT_FUNCS=(valid_ip valid_cidr conf_iface_get server_net ipt_add ipt_ins ipt_del
          ipt_del_grep ipt_del_tagged rp_filter_loose rt_fw_up rt_fw_down rt_up rt_down
          rt_rules_clear SERVER_CONF AWG_IF)

rt_rules_clear() {  # таблица
  local guard=0
  while (( guard++ < 256 )) && ip rule del lookup "$1" 2>/dev/null; do :; done
}

# NAT и FORWARD между awg0 и туннелем. Правила помечены «awg2-tun-<dev>».
rt_fw_up() {  # устройство [nonat]
  local dev="$1" net tag="awg2-tun-$1"
  net=$(server_net) || return 1
  # nonat — устройство должно видеть адреса клиентов (inbound tun Xray
  # выбирает выход клиента по его адресу)
  if [[ "${2:-}" == nonat ]]; then
    ipt_del -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE -m comment --comment "$tag"
  else
    ipt_add -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE -m comment --comment "$tag"
  fi
  ipt_ins FORWARD -i "$AWG_IF" -o "$dev" -j ACCEPT -m comment --comment "$tag"
  ipt_ins FORWARD -i "$dev" -o "$AWG_IF" -j ACCEPT -m comment --comment "$tag"
  # MSS по MTU маршрута: у туннеля MTU меньше, а ICMP «нужна фрагментация»
  # до клиента доходит не всегда — без клампа крупные TCP-сессии виснут.
  ipt_add -t mangle FORWARD -o "$dev" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag"
  ipt_add -t mangle FORWARD -i "$dev" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag"
  # Обратная проверка пути для адреса клиента ведёт в таблицу туннеля, а не
  # на awg0 — строгий rp_filter такие пакеты молча дропает.
  rp_filter_loose "$dev" "$AWG_IF"
}

# Снимает правила и этой версии, и прежних (те ставились без метки).
rt_fw_down() {  # устройство
  local dev="$1" net t
  for t in nat filter mangle; do ipt_del_tagged "$t" "awg2-tun-$dev"; done
  net=$(server_net 2>/dev/null) || net=""
  if [[ -n "$net" ]]; then
    ipt_del -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE
    ipt_del FORWARD -i "$AWG_IF" -o "$dev" -j ACCEPT
    ipt_del FORWARD -i "$dev" -o "$AWG_IF" -j ACCEPT
  fi
  ipt_del_grep mangle "-o $dev .*TCPMSS"
  ipt_del_grep mangle "-i $dev .*TCPMSS"
  ipt_del FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$AWG_IF" -j TCPMSS --clamp-mss-to-pmtu
  return 0
}

# rt_up УСТРОЙСТВО ТАБЛИЦА ФАЙЛ_КЛИЕНТОВ|- [SRC]
# «-» вместо файла — вся подсеть клиентов (как у tun2socks).
rt_up() {  # устройство таблица peers|- [src] [nonat]
  local dev="$1" table="$2" peers="$3" src="${4:-}" net ip line
  net=$(server_net) || return 1
  if [[ -n "$src" ]]; then
    ip route replace default dev "$dev" src "$src" table "$table" || return 1
  else
    ip route replace default dev "$dev" table "$table" || return 1
  fi
  rt_rules_clear "$table"
  if [[ "$peers" == - ]]; then
    ip rule add from "$net" lookup "$table" priority "$table" || return 1
  elif [[ -f "$peers" ]]; then
    while IFS= read -r line; do
      ip="${line%%|*}"
      valid_ip "$ip" && ip rule add from "$ip" lookup "$table" priority "$table"
    done < "$peers"
  fi
  rt_fw_up "$dev" "${5:-}"
}

rt_down() {  # устройство таблица
  rt_rules_clear "$2"
  ip route flush table "$2" 2>/dev/null || true
  rt_fw_down "$1"
}

# ── Состояние и взаимоисключение ──────────────────────────
warp_is_up()  { ip link show "$WARP_IF" &>/dev/null; }
xray_is_up()  { ip link show "$XRAY_IF" &>/dev/null || unit_active "$XRAY_UNIT"; }
t2s_is_up()   { unit_active "$T2S_UNIT"; }
exits_is_up() { unit_active "$EXITS_UNIT"; }

# Кто из туннелей уже активен (кроме $1). Пусто — никто.
tunnel_conflict() {
  local me="$1" others=()
  [[ "$me" != warp ]] && warp_is_up && others+=(WARP)
  [[ "$me" != xray ]] && xray_is_up && others+=(Xray)
  [[ "$me" != tun2socks ]] && t2s_is_up && others+=(tun2socks)
  [[ "$me" != exits ]] && exits_is_up && others+=("AWG exit-ноды")
  echo "${others[*]}"
}

tunnel_guard() {  # имя → 1, если занято другим туннелем
  local c
  c=$(tunnel_conflict "$1")
  [[ -z "$c" ]] && return 0
  err "Уже активен туннель: $c — одновременно работает только один"
  info "Выключи его или сделай аварийный сброс (Туннели → Аварийный сброс)"
  return 1
}

# Аварийный сброс: гасит все туннели и возвращает клиентов на прямой
# маршрут. Из настроек ничего не удаляется.
tunnels_panic_reset() {
  local quiet="${1:-}" u net dev
  if [[ "$quiet" != quiet ]]; then
    warn "Все туннели (WARP, Xray, tun2socks, exit-ноды) будут выключены,"
    warn "клиенты пойдут напрямую через сервер. Настройки сохранятся."
    ask_yes "  Продолжить? [Y/n]: " y || return 0
  fi
  # Автозапуск тоже снимаем: иначе после перезагрузки туннель вернётся
  for u in "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" "$T2S_UNIT" "$EXITS_UNIT" awg-usque.service awg-warp.service; do
    systemctl disable --now "$u" &>/dev/null || true
    systemctl reset-failed "$u" &>/dev/null || true
  done
  rt_down "$WARP_IF" "$WARP_TABLE"
  rt_down "$XRAY_IF" "$XRAY_TABLE"
  rt_down "$T2S_IF" "$T2S_TABLE"
  exits_rules_clear
  for dev in "$EXITS_DIR"/awg-exit-*.conf; do
    [[ -f "$dev" ]] && rt_fw_down "$(basename "$dev" .conf)"
  done
  for dev in "$XRAY_IF" "$T2S_IF" "$WARP_IF"; do ip link del "$dev" &>/dev/null || true; done
  rm -f "$XRAY_STATE" "$EXITS_STATE" "$WARP_STATE"
  net=$(server_net 2>/dev/null) || net=""
  dev=$(uplink_iface 2>/dev/null) || dev=""
  # То же, что ставит PostUp сервера — на случай, если его правила сбиты
  [[ -n "$net" && -n "$dev" ]] && ipt_add -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE
  ipt_ins FORWARD -i "$AWG_IF" -j ACCEPT
  ipt_ins FORWARD -o "$AWG_IF" -j ACCEPT
  ip_forward_enable
  [[ "$quiet" == quiet ]] || ok "Туннели выключены — клиенты идут напрямую"
  log_warn "аварийный сброс туннелей"
}

# ── Выбор клиентов для туннеля ────────────────────────────
# Правила работающего туннеля пересобираются по списку целиком.
_tunnel_rules_refresh() {  # файл устройство таблица
  local ip
  ip link show "$2" &>/dev/null || return 0
  rt_rules_clear "$3"
  while IFS= read -r ip; do
    valid_ip "${ip%%|*}" && ip rule add from "${ip%%|*}" lookup "$3" priority "$3"
  done < "$1"
  return 0
}

# tunnel_client warp|xray ИМЯ|all|none on|off
tunnel_client() {
  local file dev table ip outs
  case "$1" in
    warp) file="$WARP_PEERS"; dev="$WARP_IF"; table="$WARP_TABLE" ;;
    xray) file="$XRAY_PEERS"; dev="$XRAY_IF"; table="$XRAY_TABLE" ;;
    *) err "Туннель: warp | xray"; return 1 ;;
  esac
  mkdir -p "$(dirname "$file")"
  peers_sync "$file"
  outs=$(_xray_outs)
  # all / none без третьего аргумента — все клиенты; с ним — клиент с таким
  # именем: «tunnels client xray all off» не должно включать всех
  case "$2${3:+|}" in
    all) peers_all "$file" ;;
    none) : > "$file" ;;
    *) ip=$(clients_name_ip | awk -F'|' -v n="$2" '$1 == n {print $2; exit}')
       [[ -n "$ip" ]] || { err "Клиента $2 нет"; return 1; }
       peers_seed "$file"
       if [[ "${3:-on}" == on ]]; then peers_has "$file" "$ip" || peers_add "$file" "$ip"
       else peers_del "$file" "$ip"; fi ;;
  esac
  _tunnel_rules_refresh "$file" "$dev" "$table"
  ok "Клиенты ${1^^}: $(grep -c . "$file" || true) через туннель"
  if [[ "$1" == xray ]]; then _xray_outs_apply "$outs" || return 1; fi
  return 0
}
# tunnel_peers_menu ЗАГОЛОВОК ФАЙЛ УСТРОЙСТВО ТАБЛИЦА
tunnel_peers_menu() {
  local title="$1" file="$2" dev="$3" table="$4" rows=() i c name ip outs
  while true; do
    peers_sync "$file"
    outs=$(_xray_outs)
    mapfile -t rows < <(clients_name_ip)
    (( ${#rows[@]} )) || { warn "Клиентов нет"; return 0; }
    echo ""
    hdr "$title"
    for i in "${!rows[@]}"; do
      name="${rows[$i]%%|*}"; ip="${rows[$i]#*|}"
      if peers_has "$file" "$ip"; then echo -e "  ${G}$((i + 1)))${N} $name ${D}$ip${N}  ${C}через туннель${N}"
      else echo -e "  ${D}$((i + 1))) $name $ip  напрямую${N}"; fi
    done
    echo -e "  ${C}a)${N} Все через туннель"
    echo -e "  ${C}n)${N} Все напрямую"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер — вкл/выкл: ${N}" 0 "${#rows[@]}" 0 "a|n"
    case "$c" in
      0) return 0 ;;
      a) peers_all "$file" ;;
      n) : > "$file" ;;
      *) ip="${rows[$((c - 1))]#*|}"
         if peers_has "$file" "$ip"; then peers_del "$file" "$ip"; else peers_add "$file" "$ip"; fi ;;
    esac
    _tunnel_rules_refresh "$file" "$dev" "$table"
    [[ "$file" == "$XRAY_PEERS" ]] && { _xray_outs_apply "$outs" || true; }
  done
}

# ── Меню ──────────────────────────────────────────────────
_tun_state() {  # функция-проверка «включён» и файлы, по которым «настроен»
  local up="$1" f
  shift
  if "$up"; then echo -e "${G}● включён${N}"; return; fi
  for f in "$@"; do [[ -e "$f" ]] && { echo -e "${D}○ настроен, выключен${N}"; return; }; done
  echo -e "${D}○ не настроен${N}"
}

do_tunnels_menu() {
  local c
  while true; do
    echo ""
    hdr "Туннели и DNS"
    echo -e "  ${C}1)${N} WARP (Cloudflare)   $(_tun_state warp_is_up "$WARP_CONF" "$USQUE_CONF")"
    echo -e "  ${C}2)${N} Xray                $(_tun_state xray_is_up "$XRAY_CONF")"
    echo -e "  ${C}3)${N} tun2socks           $(_tun_state t2s_is_up "$T2S_CONF")"
    echo -e "  ${C}4)${N} AWG exit-ноды       $(_tun_state exits_is_up "$EXITS_DIR"/awg-exit-*.conf)"
    echo -e "  ${C}5)${N} Каскад портов       $(cascade_state_line)"
    echo -e "  ${C}6)${N} Шифрованный DNS     $(dns_state_line)"
    echo -e "  ${R}9)${N} Аварийный сброс ${D}— все клиенты напрямую${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 9 0
    case "$c" in
      1) do_warp_menu || true ;;
      2) do_xray_menu || true ;;
      3) do_tun2socks_menu || true ;;
      4) do_exits_menu || true ;;
      5) do_cascade_menu || true ;;
      6) do_dns_menu || true ;;
      9) tunnels_panic_reset || true; pause ;;
      0) return 0 ;;
    esac
  done
}
