# Сервер awg0: установка компонентов, создание, запуск, ремонт,
# перегенерация параметров и смена версии протокола.

# ── Установка компонентов ─────────────────────────────────
BASE_PKGS=(ca-certificates curl gnupg iproute2 iptables python3 python3-cryptography
           qrencode git build-essential dkms libmnl-dev pkg-config iputils-ping)

# Остатки APT-репозиториев эпохи установки через PPA ломают apt-get update.
_purge_legacy_ppa() {
  local f found=1
  for f in /etc/apt/sources.list.d/amnezia*.{list,sources} \
           /etc/apt/sources.list.d/canonical-kernel-team*.{list,sources} \
           /etc/apt/trusted.gpg.d/amnezia*.gpg /etc/apt/keyrings/amnezia*.gpg; do
    [[ -e "$f" ]] && { rm -f "$f"; found=0; }
  done
  return "$found"
}

# github.com не резолвится — чиним DNS сервера бережно: при systemd-resolved
# добавляем drop-in, а не затираем /etc/resolv.conf (там символьная ссылка).
_ensure_dns() {
  getent hosts github.com &>/dev/null && return 0
  warn "github.com не резолвится с этого сервера"
  if unit_active systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=9.9.9.9\n' \
      | write_file /etc/systemd/resolved.conf.d/awg2-dns.conf 644
    systemctl restart systemd-resolved
    info "Добавлены DNS 1.1.1.1 и 8.8.8.8 (/etc/systemd/resolved.conf.d/awg2-dns.conf)"
  elif [[ ! -L /etc/resolv.conf ]]; then
    [[ -f /etc/resolv.conf.awg-backup ]] || cp /etc/resolv.conf /etc/resolv.conf.awg-backup 2>/dev/null || true
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    info "resolv.conf заменён (копия: /etc/resolv.conf.awg-backup)"
  fi
  getent hosts github.com &>/dev/null && { ok "DNS работает"; return 0; }
  err "DNS не работает: проверь ping 1.1.1.1 и настройки сети"
  return 1
}

# Заголовков под работающее ядро в зеркале уже нет (так бывает со старыми
# облачными образами) — ставим актуальное ядро с заголовками и собираем
# модуль под него; работать всё начнёт после перезагрузки.
_install_current_kernel() {
  local arch pkgs
  os_detect
  arch=$(dpkg --print-architecture)
  if [[ "$OS_ID" == debian ]]; then
    if [[ "$(uname -r)" == *-cloud-* ]]; then pkgs=("linux-image-cloud-$arch" "linux-headers-cloud-$arch")
    else pkgs=("linux-image-$arch" "linux-headers-$arch"); fi
  else
    pkgs=(linux-generic)
    dpkg -s linux-virtual &>/dev/null && pkgs=(linux-virtual linux-headers-virtual)
  fi
  run_step "Установка ядра: ${pkgs[*]}" apt_install "${pkgs[@]}"
}

do_install() {
  local why tag cur running k
  echo ""
  hdr "Установка AmneziaWG"
  # os_supported идёт в $(…) — OS_LABEL, найденный там, до «ОС:» не дошёл бы
  os_detect
  if ! why=$(os_supported); then
    err "$why"
    [[ -n "${AWG2_ANY_OS:-}" ]] || return 1
    warn "AWG2_ANY_OS=1 — продолжаю на свой риск"
  else
    ok "ОС: $OS_LABEL"
  fi
  : > "$INSTALL_LOG"; chmod 600 "$INSTALL_LOG"
  info "Подробный вывод шагов: $INSTALL_LOG"
  _purge_legacy_ppa && ok "Удалены остатки старых PPA"
  _ensure_dns || return 1

  export DEBIAN_FRONTEND=noninteractive
  run_step "Обновление списка пакетов" apt-get update -q || return 1
  if ask_yes "  Обновить пакеты системы (apt upgrade)? [Y/n]: " y; then
    run_step "Обновление системы" apt-get upgrade -y -q -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold || warn "apt upgrade с ошибкой — продолжаю"
  fi
  run_step "Пакеты (${#BASE_PKGS[@]})" apt_install "${BASE_PKGS[@]}" || { apt_errors; return 1; }

  running=$(uname -r)
  if ! run_step "Заголовки ядра $running" ensure_headers "$running"; then
    warn "Заголовков под ядро $running в репозитории нет"
    if ask_yes "  Поставить актуальное ядро с заголовками (понадобится перезагрузка)? [Y/n]: " y; then
      _install_current_kernel || return 1
    else
      kernel_headers_help
      return 1
    fi
  fi

  if [[ -d "/lib/modules/$running/build" ]]; then
    cur=$(mod_tag)
    tag=$(resolve_tag mod)
    if [[ "${cur#≈}" == "$tag" ]] && mod_built_for "$running"; then
      ok "Модуль $tag уже установлен"
    else
      mod_install_tag "$tag" || return 1
    fi
  else
    # Собираем только под новое ядро: работающему заголовков нет
    tag=$(resolve_tag mod)
    k=$(installed_kernels | tail -1)
    info "Модуль будет собран под $k — он загрузится после перезагрузки"
    mod_install_tag "$tag" || true
  fi

  tag=$(resolve_tag tools)
  if [[ "$(tools_tag)" == "$tag" ]] && command -v awg &>/dev/null; then
    ok "amneziawg-tools $tag уже установлены"
  else
    tools_install_tag "$tag" || return 1
  fi

  modprobe "$MOD_NAME" 2>/dev/null || true
  mod_autoload
  ip_forward_enable
  mkdir -p "$AWG_DIR" && chmod 700 "$AWG_DIR"
  expire_install
  success_box "Компоненты установлены"
  components_report

  why=$(reboot_reason)
  if [[ -n "$why" && "$why" != *modprobe* ]]; then
    echo ""
    warn "Нужна перезагрузка: $why"
    if [[ "$why" == *"перезагрузка модуля"* ]]; then
      mod_reload || true
    elif (( ! AUTO_MODE )) && ask_yes "  Перезагрузить сервер сейчас? [Y/n]: " y; then
      ok "Перезагружаюсь. После — sudo awg2 → Сервер → Создать сервер"
      sleep 2; reboot
    fi
  else
    info "Следующий шаг: Сервер → Создать сервер"
  fi
}

# ── Запуск awg0 с разбором ошибки ─────────────────────────
# Сообщения awg-quick короткие, но однозначные — каждому соответствует одно
# действие. Разбор избавляет от гадания по «awg-quick up провалился».
awg_diagnose_up() {
  local out="$1" low bad p holder
  low="${out,,}"
  if [[ "$low" == *"line unrecognized"* ]]; then
    bad=$(grep -oiE 'line unrecognized: .?[A-Za-z0-9_]+' <<< "$out" | head -1 | grep -oE '[A-Za-z0-9_]+$')
    err "amneziawg-tools не знают параметра ${bad:-из конфига}"
    if [[ "$bad" =~ ^${AWG3_KEYS_RE}$ ]]; then
      info "Это параметр AWG 3.x — обнови компоненты: Сервер → Модуль ядра"
      info "или верни сервер на 2.0: Сервер → Протокол и параметры"
    fi
  elif [[ "$low" == *"invalid argument"* || "$low" == *"unable to modify interface"* ]]; then
    err "Ядро отвергло параметры интерфейса"
    bad=$(conf_hp_min_s_violations)
    if [[ -n "$bad" ]]; then
      info "AWG 3.x требует S1-S4 ≥ $AWG_HP_MIN_S, а в конфиге: $bad"
      info "Лечится перегенерацией: Сервер → Протокол и параметры"
    elif server_params | grep -qE "^${AWG3_KEYS_RE}"; then
      if mod_stale; then info "В памяти прежняя сборка модуля — Сервер → Модуль ядра → перезагрузить модуль"
      else info "Модуль не поддерживает параметры 3.x — Сервер → Модуль ядра → обновить"; fi
    else
      info "Смотри: dmesg | tail -20"
    fi
  elif [[ "$low" == *"unknown device type"* || "$low" == *"protocol not supported"* || "$low" == *"operation not supported"* ]]; then
    err "Ядро не умеет интерфейсы amneziawg — модуль не загружен или собран под другое ядро"
    info "Сервер → Модуль ядра (там же пересборка под все ядра)"
  elif [[ "$low" == *"address already in use"* ]]; then
    p=$(server_port)
    err "UDP-порт ${p:-?} занят"
    holder=$(ss -lunp 2>/dev/null | grep -E "[:.]${p}\b" || true)
    [[ -n "$holder" ]] && sed 's/^/    /' <<< "$holder"
  elif [[ "$low" == *iptables* ]]; then
    err "Правила iptables из PostUp не применились — проверь: iptables -V"
  elif [[ "$low" == *resolvconf* ]]; then
    err "В серверном конфиге строка DNS — awg-quick ищет resolvconf. Убери DNS из [Interface]"
  else
    warn "Причина не распознана — смотри вывод выше и dmesg | tail -20"
  fi
}

awg_up_diag() {
  local out rc=0
  out=$(awg-quick up "$SERVER_CONF" 2>&1) || rc=$?
  if (( rc != 0 )) && [[ "$out" == *"already exists"* ]] && iface_up; then
    awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
    rc=0; out=$(awg-quick up "$SERVER_CONF" 2>&1) || rc=$?
  fi
  (( rc == 0 )) && { log_info "awg0 поднят"; return 0; }
  log_err "awg-quick up rc=$rc: $(tr '\n' ';' <<< "$out")"
  echo -e "  ${D}── awg-quick up ──${N}"
  sed 's/^/  │ /' <<< "$out"
  awg_diagnose_up "$out"
  return "$rc"
}

setup_autostart() {
  mkdir -p "$AUTOSTART_DROPIN"
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/awg-quick up awg0\n' \
    | write_file "$AUTOSTART_DROPIN/override.conf" 644
  systemctl daemon-reload
  systemctl enable awg-quick@awg0 &>/dev/null || warn "Не удалось включить автозапуск awg0"
  mod_autoload
}

# ── Запись конфигов ───────────────────────────────────────
# Параметры создаваемого сервера (заполняются меню или --auto).
S_PROFILE=lite S_PROTO=2.0 S_REGION=world S_DNS="1.1.1.1, 1.0.0.1" MTU=1280
S_NET="" S_PORT="" S_ENDPOINT_DOMAIN="" S_FIRST_CLIENT=""

_postup_lines() {
  local net="$1" dev="$2"
  echo "PostUp = echo 1 > /proc/sys/net/ipv4/ip_forward; iptables -t nat -C POSTROUTING -s $net -o $dev -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $net -o $dev -j MASQUERADE; iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o awg0 -j ACCEPT"
  echo "PostDown = iptables -t nat -D POSTROUTING -s $net -o $dev -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true"
}

# Клиентский конфиг. $1 файл, $2 приватный ключ, $3 адрес, $4 psk, $5 DNS, $6 MTU.
write_client_conf() {
  local f="$1" priv="$2" addr="$3" psk="$4" dns="$5" mtu="$6" srv_pub
  srv_pub=$(conf_iface_get PrivateKey | awg pubkey) || return 1
  {
    echo "[Interface]"
    echo "PrivateKey = $priv"
    echo "Address = $addr"
    echo "DNS = $dns"
    echo "MTU = $mtu"
    server_params
    i_lines_block
    echo ""
    echo "[Peer]"
    echo "PublicKey = $srv_pub"
    echo "PresharedKey = $psk"
    echo "Endpoint = $(endpoint_host):$(server_port)"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = $(keepalive_for "$(server_proto)")"
  } | write_file "$f" 600
}

# Умеют ли модуль и tools AWG 3.1, когда сервера ещё нет. Проверка создаёт
# пробный интерфейс, а бот спрашивает сводку раз в минуту — ответ помнится до
# смены модуля или tools. «Не подтверждено» (модуль не загружен) не помнится.
proto31_cached() {
  local f="$STATE_DIR/proto31" bin key k v rc=0
  bin=$(command -v awg) || return 1
  key="$(mod_tag)|$(stat -c %s:%Y "$bin" 2>/dev/null)|$(cat "/sys/module/$MOD_NAME/srcversion" 2>/dev/null)"
  if [[ -f "$f" ]] && IFS=$'\t' read -r k v < "$f" && [[ "$k" == "$key" && "$v" =~ ^[01]$ ]]; then
    _PROTO_PROBE[31]=$v           # proto_upgrade_hint в том же вызове не пробует заново
    return "$v"
  fi
  proto_supported 3.1 || rc=$?
  (( rc == 2 )) || { mkdir -p "$STATE_DIR" && printf '%s\t%s\n' "$key" "$rc" > "$f"; } 2>/dev/null
  return "$rc"
}

# Внешний интерфейс в правиле NAT awg0.conf — аплинк, на котором создан сервер.
conf_uplink() {
  [[ -f "$SERVER_CONF" ]] || return 1
  sed -nE 's/^PostUp *=.*POSTROUTING -s [^ ]+ -o ([^ ]+) -j MASQUERADE.*/\1/p' "$SERVER_CONF" | head -1 | grep .
}

# Сервер восстановлен на другом VPS (или интерфейс переименован): у аплинка
# другое имя (ens3 вместо eth0) — клиенты подключаются, но без NAT остаются
# без интернета. Правило NAT в PostUp/PostDown переводится на аплинк этого
# сервера. Для «Проверить и починить» — только если прежнего интерфейса здесь
# нет: есть — значит NAT через него выбран сознательно (второй аплинк,
# туннель). Восстановление бэкапа (force) переносит всегда: интерфейс с тем
# же именем на новом VPS может быть совсем другим (приватный eth0). Поднятый
# awg0 опускается до правки — его PostDown снимает старое правило NAT, иначе
# оно оставалось в iptables — и поднимается снова. 0 — awg0.conf поправлен.
conf_uplink_sync() {  # [force]
  local old dev up=0 rc=0
  old=$(conf_uplink) || return 1
  dev=$(uplink_iface) || return 1
  [[ "$old" != "$dev" ]] || return 1
  [[ "${1:-}" != force ]] && ip link show "$old" &>/dev/null && return 1
  if iface_up; then
    up=1
    awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  fi
  sed -i -E "/^Post(Up|Down) *=/ s#(POSTROUTING -s [^ ]+ -o )${old//./\\.}( -j MASQUERADE)#\1$dev\2#g" "$SERVER_CONF" \
    && [[ "$(conf_uplink)" == "$dev" ]] || rc=1
  (( up )) && { awg_up_diag || rc=1; }
  (( rc )) && return 1
  info "Внешний интерфейс сервера: $old → $dev (NAT в $SERVER_CONF)"
  log_info "NAT awg0: $old → $dev"
}

# Создаёт awg0.conf и первого клиента из S_* и выбранной мимикрии.
server_write() {
  local net="$S_NET" base srv_priv cli_priv psk dev
  base="${net%.*}"
  dev=$(uplink_iface) || { err "Не найден интерфейс маршрута по умолчанию"; return 1; }
  gen_awg_params "$S_PROFILE" "$S_PROTO" || return 1
  srv_priv=$(awg genkey); cli_priv=$(awg genkey); psk=$(awg genpsk)
  mkdir -p "$AWG_DIR" && chmod 700 "$AWG_DIR"
  {
    echo "# AWG_PROFILE=$S_PROFILE"
    echo "# AmneziaWG Toolza — AWG $S_PROTO server config"
    echo "# Region: $S_REGION"
    echo "# AWG_PROTO=$S_PROTO"
    echo "# AWG_OBF_LEVEL=$OBF_LEVEL"
    echo "# AWG_CPS_BUDGET=$CPS_BUDGET"
    echo "# AWG_MIMICRY=$MIMICRY"
    [[ -n "$CPS_DOMAIN" && "$MIMICRY" != none ]] && echo "# AWG_MIMICRY_DOMAIN=$CPS_DOMAIN"
    [[ -n "$S_ENDPOINT_DOMAIN" ]] && echo "# AWG_ENDPOINT=$S_ENDPOINT_DOMAIN"
    echo "[Interface]"
    echo "PrivateKey = $srv_priv"
    echo "Address = ${base}.1/24"
    echo "ListenPort = $S_PORT"
    echo "MTU = $MTU"
    echo "$AWG_PARAMS"
    echo ""
    _postup_lines "$net" "$dev"
    echo ""
    echo "[Peer]"
    echo "# $S_FIRST_CLIENT"
    echo "# mimicry=$(mimicry_tag)"
    echo "PublicKey = $(awg pubkey <<< "$cli_priv")"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = ${base}.2/32"
  } | write_file "$SERVER_CONF" 600
  write_client_conf "$(client_file "$S_FIRST_CLIENT")" "$cli_priv" "${base}.2/32" "$psk" "$S_DNS" "$MTU"
}

# Поднять созданный сервер, открыть порт, включить автозапуск.
server_start_new() {
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  awg_up_diag || return 1
  if ufw_active; then
    ufw_allow "$S_PORT/udp" AmneziaWG && ok "UFW: открыт $S_PORT/udp"
    if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw 2>/dev/null; then
      sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
      ufw reload &>/dev/null || true
      info "UFW: DEFAULT_FORWARD_POLICY=ACCEPT (нужно для выхода клиентов в интернет)"
    fi
  fi
  setup_autostart
  expire_install
  log_info "сервер создан: AWG $S_PROTO, профиль $S_PROFILE, порт $S_PORT"
}

pick_awg_net() { taken_networks | py pick-net awg; }

# ── Создание сервера (меню) ───────────────────────────────
_choose_dns() {
  local c d
  echo -e "  ${C}1)${N} Cloudflare ${D}1.1.1.1${N}"
  echo -e "  ${C}2)${N} Google ${D}8.8.8.8${N}"
  echo -e "  ${C}3)${N} Quad9 ${D}9.9.9.9${N}"
  echo -e "  ${C}4)${N} Яндекс ${D}77.88.8.8${N}"
  echo -e "  ${C}5)${N} Вручную"
  read_choice c "${C}  DNS клиентов [1-5] (Enter = 1): ${N}" 1 5 1
  case "$c" in
    1) S_DNS="1.1.1.1, 1.0.0.1" ;; 2) S_DNS="8.8.8.8, 8.8.4.4" ;;
    3) S_DNS="9.9.9.9, 149.112.112.112" ;; 4) S_DNS="77.88.8.8, 77.88.8.1" ;;
    5) while true; do
         read_line d "${C}  DNS через запятую: ${N}"
         [[ -n "$d" ]] || { S_DNS="1.1.1.1, 1.0.0.1"; break; }
         valid_dns_list "$d" && { S_DNS="$d"; break; }
         warn "Нужны IPv4-адреса через запятую"
       done ;;
  esac
}

_choose_mtu() {  # $1 — значение по умолчанию
  local c v i opts=("$1")
  # Рекомендуемое — первым, остальные стандартные без повтора
  for v in 1420 1380 1320 1280; do [[ "$v" == "$1" ]] || opts+=("$v"); done
  echo ""
  hdr "MTU"
  for i in "${!opts[@]}"; do
    echo -e "  ${C}$((i + 1)))${N} ${opts[$i]}$( (( i == 0 )) && echo -e " ${C}(рекомендуется)${N}")"
  done
  echo -e "  ${C}$(( ${#opts[@]} + 1 )))${N} Вручную"
  read_choice c "${C}  MTU [1-$(( ${#opts[@]} + 1 ))] (Enter = 1): ${N}" 1 $(( ${#opts[@]} + 1 )) 1
  if (( c <= ${#opts[@]} )); then
    MTU=${opts[$((c - 1))]}
  else
    while true; do
      read_line v "${C}  MTU (1280-1500): ${N}"
      [[ -n "$v" ]] || { MTU=$1; break; }
      [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1280 && v <= 1500 )) && { MTU=$v; break; }
      warn "Число 1280-1500"
    done
  fi
}

# Версия протокола нового сервера. 3.1 по умолчанию, если компоненты её умеют.
_choose_proto() {
  local c def=2 rc=0
  proto_supported 3.1 || rc=$?
  echo ""
  hdr "Версия протокола"
  echo -e "  ${G}1${N} AWG 2.0 ${D}— любой клиент AmneziaWG${N}"
  echo -e "  ${G}2${N} AWG 3.1 ${D}— быстрее, заголовки под шифром${N}"
  echo -e "  ${Y}  Версия на весь сервер. Для 3.1 нужен AmneziaVPN 5.0.1.5+ / AmneziaWG с 3.1.${N}"
  if (( rc == 1 )); then
    def=1
    warn "Установленные модуль/tools не умеют 3.1 — Сервер → Модуль ядра → обновить"
  fi
  read_choice c "${C}  Выбор [1-2] (Enter = $def): ${N}" 1 2 "$def"
  if [[ "$c" == 2 ]]; then
    if (( rc == 1 )); then
      ask_yes "  Обновить модуль и tools сейчас? [Y/n]: " y || { S_PROTO=2.0; return 0; }
      mod_update_flow && tools_update_flow
      proto_supported 3.1 || { err "3.1 по-прежнему не поддерживается — остаюсь на 2.0"; S_PROTO=2.0; return 0; }
    fi
    S_PROTO=3.1
  else
    S_PROTO=2.0
  fi
}

# Регион — явным выбором, как в боте и панели: «Сервер в России? [y/N]»
# с Enter уходил дальше молча, и было непонятно, что выбрано.
_choose_region() {
  local c
  echo -e "  ${W}Где сервер${N}"
  echo -e "  ${G}1${N} Европа / мир"
  echo -e "  ${G}2${N} Россия"
  echo -e "  ${D}    мимикрия берёт домены, привычные для страны сервера${N}"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 2 ]]; then S_REGION=ru; else S_REGION=world; fi
  ok "Регион: $([[ "$S_REGION" == ru ]] && echo "Россия" || echo "Европа / мир")"
}

_choose_profile() {
  local c
  echo ""
  hdr "Профиль"
  echo -e "  ${G}1${N} AmneziaVPN ${C}(рекомендуется)${N}"
  echo -e "  ${D}    как официальный клиент: MTU 1280, без I1-I5${N}"
  echo -e "  ${G}2${N} Мощный"
  echo -e "  ${D}    широкие диапазоны и I1-I5, сильнее против DPI${N}"
  echo -e "  ${D}0 назад${N}"
  read_choice c "${C}  Выбор [0-2] (Enter = 1): ${N}" 0 2 1
  case "$c" in
    0) return 1 ;;
    1) S_PROFILE=lite; MIMICRY=none; OBF_LEVEL=1; CPS_BUDGET=0; CPS_DOMAIN=""; I_LINES=()
       # Один компактный I1 (DNS) — только по согласию: у официальной Amnezia строк I нет
       if ask_yes "  Добавить один компактный пакет мимикрии I1 (DNS, ~90 симв)? [y/N]: " n; then
         OBF_LEVEL=2; MIMICRY=dns
         choose_cps_domain
         gen_chain dns "$CPS_DOMAIN" --only-i1 || { MIMICRY=none; OBF_LEVEL=1; }
       fi ;;
    2) S_PROFILE=pro
       choose_and_gen_chain || return 1 ;;
  esac
}

_choose_net() {
  local c v
  echo -e "  ${C}1)${N} Случайная 10.x.y.0/24 ${C}(рекомендуется)${N}"
  echo -e "  ${C}2)${N} Вручную"
  read_choice c "${C}  Подсеть [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    S_NET=$(pick_awg_net) || { err "Не нашёл свободную /24"; return 1; }
    return 0
  fi
  while true; do
    read_line v "${C}  Подсеть вида 10.8.0.0/24 (Enter — случайная): ${N}"
    # Пусто (Enter или Ctrl+D) — как пункт 1, а не обрыв мастера и не повтор
    if [[ -z "$v" ]]; then
      S_NET=$(pick_awg_net) || { err "Не нашёл свободную /24"; return 1; }
      info "Подсеть: $S_NET"
      return 0
    fi
    if valid_cidr "$v" && [[ "${v#*/}" == 24 ]]; then
      v="${v%.*}.0/24"
      if taken_networks | py net-overlaps "$v" >/dev/null; then
        warn "Пересекается с адресами или маршрутами сервера"
      else
        S_NET="$v"; return 0
      fi
    else
      warn "Нужна сеть /24, например 10.8.0.0/24"
    fi
  done
}

_choose_port() {
  local v
  while true; do
    read_line v "${C}  UDP-порт [Enter = случайный]: ${N}"
    v="${v// /}"
    if [[ -z "$v" ]]; then S_PORT=$(random_free_udp_port) || return 1; return 0; fi
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1024 && v <= 65535 )); then
      udp_port_busy "$v" && { warn "Порт $v занят"; continue; }
      S_PORT=$v; return 0
    fi
    warn "Порт — число 1024-65535"
  done
}

_choose_endpoint() {
  local d
  S_ENDPOINT_DOMAIN=""
  ask_yes "  Использовать в конфигах домен вместо IP (переезд без перевыдачи)? [y/N]: " n || return 0
  while true; do
    read_line d "${C}  Домен (Enter — отмена): ${N}"
    d="${d// /}"
    [[ -z "$d" ]] && return 0
    valid_domain "$d" && break
    warn "Нужно имя вида vpn.example.com"
  done
  domain_points_here "$d" || ask_yes "  Всё равно использовать? [y/N]: " n || return 0
  S_ENDPOINT_DOMAIN="$d"
}

# Можно ли создавать сервер. Предупреждение о перезагрузке — в REBOOT_WHY.
REBOOT_WHY=""
server_create_ready() {
  command -v awg &>/dev/null || { err "Компоненты не установлены — Сервер → Установить компоненты"; return 1; }
  if server_exists; then
    err "Сервер уже создан (профиль $(profile_label), AWG $(server_proto))"
    info "Сменить версию или параметры: Сервер → Протокол; всё заново — сброс сервера"
    return 1
  fi
  REBOOT_WHY=$(reboot_reason)
  if [[ "$REBOOT_WHY" == *modprobe* ]]; then modprobe "$MOD_NAME" 2>/dev/null; REBOOT_WHY=$(reboot_reason); fi
  if [[ "$REBOOT_WHY" == *"не собран"* ]]; then
    err "Модуль не собран под работающее ядро $(uname -r) — Сервер → Установить компоненты"
    return 1
  fi
  return 0
}

# Создание из S_* и выбранной мимикрии.
server_create() {
  server_write || return 1
  if ! server_start_new; then
    err "Сервер не поднялся — конфиг сохранён: $SERVER_CONF"
    return 1
  fi
  success_box "Сервер создан: AWG $S_PROTO, клиент $S_FIRST_CLIENT"
  echo "Файл конфигурации: $(client_file "$S_FIRST_CLIENT")"
  mimicry_module_warnings
}

# Создание без вопросов: server_create_opts ключ=значение...
#   profile=lite|pro  proto=2.0|3.1  region=world|ru  dns="1.1.1.1, 1.0.0.1"
#   mtu=  port=  net=10.x.y.0/24  endpoint=домен  client=имя  mimicry=строка
# Не заданное — как у «AmneziaVPN»: версия 3.1, если компоненты её умеют.
server_create_opts() {
  local kv k v mim=""
  server_create_ready || return 1
  [[ -n "$REBOOT_WHY" ]] && warn "$REBOOT_WHY"
  S_PROFILE=lite; S_PROTO=""; S_REGION=world; S_DNS="1.1.1.1, 1.0.0.1"; MTU=""
  S_PORT=""; S_NET=""; S_ENDPOINT_DOMAIN=""; S_FIRST_CLIENT=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      profile) [[ "$v" =~ ^(lite|pro)$ ]] || { err "profile: lite | pro"; return 1; }; S_PROFILE="$v" ;;
      proto) [[ "$v" =~ ^(2\.0|3\.1)$ ]] || { err "proto: 2.0 | 3.1"; return 1; }; S_PROTO="$v" ;;
      region) [[ "$v" =~ ^(world|ru)$ ]] || { err "region: world | ru"; return 1; }; S_REGION="$v" ;;
      dns) valid_dns_list "$v" || { err "dns: IPv4 через запятую"; return 1; }; S_DNS="$v" ;;
      mtu) [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1280 && v <= 1500 )) || { err "mtu: 1280-1500"; return 1; }; MTU="$v" ;;
      port) valid_port "$v" && (( v >= 1024 )) || { err "port: 1024-65535"; return 1; }
            udp_port_busy "$v" && { err "UDP $v занят"; return 1; }; S_PORT="$v" ;;
      net) valid_cidr "$v" && [[ "${v#*/}" == 24 ]] || { err "net: сеть /24"; return 1; }
           v="${v%.*}.0/24"
           taken_networks | py net-overlaps "$v" >/dev/null && { err "Сеть $v пересекается с адресами сервера"; return 1; }
           S_NET="$v" ;;
      endpoint) [[ -z "$v" ]] || valid_domain "$v" || { err "endpoint: домен"; return 1; }; S_ENDPOINT_DOMAIN="${v,,}" ;;
      client) _name_free "$v" || { err "Имя клиента недопустимо"; return 1; }; S_FIRST_CLIENT="$v" ;;
      mimicry) mim="$v" ;;
      *) err "Неизвестный параметр: $k"; return 1 ;;
    esac
  done
  if [[ -z "$S_PROTO" ]]; then
    if proto_supported 3.1; then S_PROTO=3.1; else S_PROTO=2.0; fi
  elif [[ "$S_PROTO" == 3.1 ]] && ! proto_supported 3.1; then
    err "Модуль или tools не умеют AWG 3.1 — обнови их (Сервер → Модуль ядра) или выбери 2.0"
    return 1
  fi
  [[ -n "$MTU" ]] || { [[ "$S_PROFILE" == pro ]] && MTU=1320 || MTU=1280; }
  [[ -n "$mim" ]] || { [[ "$S_PROFILE" == pro ]] && mim="dns:3" || mim=none; }
  [[ -n "$S_NET" ]] || S_NET=$(pick_awg_net) || { err "Нет свободной подсети"; return 1; }
  [[ -n "$S_PORT" ]] || S_PORT=$(random_free_udp_port) || { err "Нет свободного UDP-порта"; return 1; }
  [[ -n "$S_FIRST_CLIENT" ]] || S_FIRST_CLIENT=$(rand_name)
  mimicry_from_spec "$mim" || return 1
  server_create
}

do_create_server() {
  if ! server_create_ready; then return 1; fi
  if [[ -n "$REBOOT_WHY" ]]; then
    warn "$REBOOT_WHY"
    ask_yes "  Продолжить без перезагрузки? [y/N]: " n || return 0
  fi

  echo ""
  hdr "Создание сервера"
  _choose_region
  echo ""
  hdr "DNS клиентов"
  _choose_dns
  _choose_profile || return 0
  if [[ "$S_PROFILE" == lite ]]; then _choose_mtu 1280; else _choose_mtu 1320; fi
  _choose_proto
  _choose_net || return 1
  _choose_port || { err "Нет свободного UDP-порта"; return 1; }
  _choose_endpoint
  S_FIRST_CLIENT=$(rand_name)

  echo ""
  hdr "Итог"
  echo -e "  Версия   : ${W}AWG $S_PROTO${N}, профиль ${W}$(profile_label "$S_PROFILE")${N}"
  echo -e "  Мимикрия : ${W}$MIMICRY${N}${CPS_DOMAIN:+ ($CPS_DOMAIN)}"
  echo -e "  Подсеть  : ${W}$S_NET${N}, MTU ${W}$MTU${N}, DNS ${W}$S_DNS${N}"
  echo -e "  Endpoint : ${W}${S_ENDPOINT_DOMAIN:-$(public_ip_cached)}:$S_PORT${N}"
  ask_yes "  Создать? [Y/n]: " y || { info "Отменено"; return 0; }
  server_create && share_config "$(client_file "$S_FIRST_CLIENT")"
}

# Неинтерактивная установка: компоненты, сервер и client1.
# Переменные окружения: AWG_PROFILE=lite|pro, AWG_PROTO=2.0|3.1, AWG_PORT.
do_autoinstall() {
  AUTO_MODE=1
  command -v awg &>/dev/null || do_install || exit 1
  if server_exists; then
    warn "Сервер уже создан — вывожу конфиг client1"
    [[ -f "$(client_file client1)" ]] && cat "$(client_file client1)"
    return 0
  fi
  local opts=(client=client1)
  [[ "${AWG_PROFILE:-}" == pro ]] && opts+=(profile=pro)
  [[ -n "${AWG_PROTO:-}" ]] && opts+=("proto=$AWG_PROTO")
  [[ -n "${AWG_PORT:-}" ]] && opts+=("port=$AWG_PORT")
  server_create_opts "${opts[@]}" || exit 1
  cat "$(client_file client1)"
}

# Перезагрузка через 5 секунд: вызвавший (бот) успевает получить ответ.
server_reboot() {
  systemd-run --on-active=5 --unit=awg2-reboot --collect /bin/systemctl reboot &>/dev/null \
    || { err "systemd-run не сработал"; return 1; }
  log_warn "перезагрузка сервера"
  ok "Сервер перезагрузится через 5 секунд"
}

# ── Перезапуск и ремонт ───────────────────────────────────
do_restart() {
  server_exists || { err "Сервер не создан"; return 1; }
  info "Перезапуск awg0..."
  server_restart && ok "awg0 перезапущен"
}

REPAIR_ISSUES=0 REPAIR_FIXED=0
_issue() { REPAIR_ISSUES=$((REPAIR_ISSUES + 1)); warn "$1"; }
_fixed() { REPAIR_FIXED=$((REPAIR_FIXED + 1)); ok "$1"; }

do_repair() {
  local bad conf_n live_n dev net perm rc old
  REPAIR_ISSUES=0 REPAIR_FIXED=0
  echo ""
  hdr "Проверка и ремонт"

  if mod_loaded; then ok "Модуль загружен"
  else
    _issue "Модуль не загружен"
    if modprobe "$MOD_NAME" 2>/dev/null; then _fixed "modprobe amneziawg"
    elif secure_boot_on; then err "Secure Boot отвергает неподписанный модуль"
    elif command -v dkms &>/dev/null && ensure_headers "$(uname -r)" \
         && run_step "Пересборка модуля под $(uname -r)" _mod_dkms_install_all \
         && modprobe "$MOD_NAME" 2>/dev/null; then _fixed "Модуль пересобран и загружен"
    else err "Не удалось — Сервер → Модуль ядра"; fi
  fi
  mod_stale && _issue "В памяти прежняя сборка модуля — Сервер → Модуль ядра → перезагрузить модуль"
  if [[ -n "$(kernel_gap)" ]]; then
    _issue "Ядро $(kernel_gap_line) без модуля AWG — после перезагрузки awg0 не поднимется"
    mod_rebuild_all && _fixed "Модуль собран под все ядра"
  fi
  if grep -qs "^$MOD_NAME" "$MODULES_LOAD_FILE"; then ok "Автозагрузка модуля"
  else _issue "Нет автозагрузки модуля"; mod_autoload && _fixed "Автозагрузка настроена"; fi

  server_exists || { err "Сервер не создан"; return 1; }
  if [[ -z "$(conf_marker AWG_OBF_LEVEL)" ]]; then
    # Бот по этой метке решает, сколько пакетов I1-I5 выдать клиенту
    if grep -qsE '^I[2-5] = ' "$CLIENT_DIR"/*_awg[23].conf; then conf_marker_set AWG_OBF_LEVEL 3
    elif grep -qsE '^I1 = ' "$CLIENT_DIR"/*_awg[23].conf; then conf_marker_set AWG_OBF_LEVEL 2; fi
    [[ -n "$(conf_marker AWG_OBF_LEVEL)" ]] && ok "Восстановлена метка AWG_OBF_LEVEL по конфигам клиентов"
  fi
  bad=$(conf_hp_min_s_violations)
  [[ -n "$bad" ]] && _issue "S ниже $AWG_HP_MIN_S при защите заголовков: $bad — Сервер → Протокол и параметры"
  if [[ "$(server_proto)" == 3* ]]; then
    rc=0; proto_supported "$(server_proto)" || rc=$?
    (( rc == 1 )) && _issue "Сервер на AWG $(server_proto), а компоненты её не умеют — Сервер → Модуль ядра"
  fi
  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]]; then ok "IP forwarding"
  else _issue "IP forwarding выключен"; ip_forward_enable && _fixed "IP forwarding включён"; fi

  if ! iface_up; then
    _issue "awg0 не поднят"
    awg_up_diag && _fixed "awg0 поднят"
  else
    conf_n=$(grep -c '^\[Peer\]' "$SERVER_CONF" || true)
    live_n=$(awg show "$AWG_IF" peers 2>/dev/null | wc -l)
    if [[ "$conf_n" != "$live_n" ]]; then
      _issue "Пиров в конфиге $conf_n, в ядре $live_n"
      server_restart && _fixed "awg0 перезапущен"
    else ok "awg0 работает, пиров: $live_n"; fi
  fi
  dev=$(uplink_iface || true); net=$(server_net || true)
  old=$(conf_uplink || true)
  if [[ -n "$dev" && -n "$old" && "$old" != "$dev" ]]; then
    if ip link show "$old" &>/dev/null; then
      info "NAT в awg0.conf — на $old (маршрут по умолчанию — через $dev): оставляю как настроено"
    else
      _issue "NAT в awg0.conf — на $old, такого интерфейса нет; выход сервера — $dev"
      conf_uplink_sync && _fixed "NAT перенесён на $dev"
    fi
  fi
  # NAT проверяется на интерфейсе из awg0.conf: выбранный сознательно не
  # перебивается правилом на аплинк по умолчанию
  old=$(conf_uplink || true); [[ -n "$old" ]] && ip link show "$old" &>/dev/null && dev="$old"
  if [[ -n "$dev" && -n "$net" ]]; then
    if iptables -t nat -C POSTROUTING -s "$net" -o "$dev" -j MASQUERADE 2>/dev/null; then ok "NAT на $dev"
    else _issue "Нет NAT для $net на $dev"; ipt_add -t nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE && _fixed "NAT добавлен"; fi
  fi
  perm=$(stat -c %a "$SERVER_CONF")
  [[ "$perm" == 600 ]] || { _issue "Права $SERVER_CONF = $perm"; chmod 600 "$SERVER_CONF" && _fixed "Права 600"; }
  perm=$(stat -c %a "$AWG_DIR")
  [[ "$perm" == 700 ]] || { _issue "Права $AWG_DIR = $perm"; chmod 700 "$AWG_DIR" && _fixed "Права 700"; }
  unit_enabled awg-quick@awg0 || { _issue "Нет автозапуска awg0"; setup_autostart && _fixed "Автозапуск включён"; }

  echo ""
  if (( REPAIR_ISSUES == 0 )); then success_box "Всё в порядке"
  elif (( REPAIR_FIXED == REPAIR_ISSUES )); then success_box "Найдено проблем: $REPAIR_ISSUES, все исправлены"
  else warn "Найдено проблем: $REPAIR_ISSUES, исправлено: $REPAIR_FIXED"; fi
}

# ── Протокол и параметры ──────────────────────────────────
# Предупреждения про модуль, влияющие на мимикрию I1-I5.
mimicry_module_warnings() {
  local n=0
  if [[ "$(server_proto)" == 3.1 ]] && grep -qsE '^I1 = ' "$CLIENT_DIR"/*_awg3.conf; then
    mod_trailer_fix || { [[ $? -eq 1 ]] && warn "Модуль дописывает хвост к I1-I5 — мимикрия слабее. Обнови модуль (Сервер → Модуль ядра)"; }
  fi
  # Длина цепочки — по каждому файлу отдельно, берём наибольшую.
  n=$(awk -F' = ' 'FNR == 1 {if (NR > 1) print n; n = 0} /^I[1-5] = /{n += length($2)} END{print n+0}' \
        "$CLIENT_DIR"/*_awg[23].conf 2>/dev/null | sort -n | tail -1)
  (( ${n:-0} > 3598 )) && warn "Цепочка I1-I5 длиннее $n симв — выше предела awg-tools (буфер 4 КБ)"
  return 0
}

# Подсказка для шапки: предложить переход на 3.1.
proto_upgrade_hint() {
  server_exists || return 0
  [[ "$(server_proto)" == 3.1 ]] && return 0
  if proto_supported 3.1; then
    echo -e "${G}⬆ доступен переход на AWG 3.1${N} ${D}— Сервер → Протокол${N}"
  else
    echo -e "${Y}для AWG 3.1 обнови модуль${N} ${D}— Сервер → Модуль ядра${N}"
  fi
}

# Снимок конфигов сервера и клиентов — откат, если awg0 не поднимется.
_params_snapshot() {  # ПЕРЕМЕННАЯ
  local __d f
  mktmp __d -d || return 1
  mkdir -p "$__d/clients"
  cp -a "$SERVER_CONF" "$__d/"
  while read -r f; do cp -a "$f" "$__d/clients/"; done < <(client_files)
  printf -v "$1" '%s' "$__d"
}

_params_restore() {  # КАТАЛОГ_СНИМКА
  err "awg0 не поднялся с новыми параметрами — возвращаю прежние"
  cp -a "$1/${SERVER_CONF##*/}" "$SERVER_CONF"
  rm -f "$CLIENT_DIR"/*_awg[23].conf
  cp -a "$1/clients/." "$CLIENT_DIR/"
  server_restart && ok "Прежняя конфигурация восстановлена"
}

# Перегенерация параметров обфускации с переходом на версию $1.
# Ключи, адреса, имена, сроки и I1-I5 сохраняются. Все клиенты получают
# новые конфиги — старые перестают подключаться.
server_regen_params() {
  local target="$1" cur profile snap f n=0 ka
  cur=$(server_proto)
  profile=$(server_profile)
  if [[ "$target" == 3* ]]; then
    local rc=0
    proto_supported "$target" || rc=$?
    if (( rc == 1 )); then
      warn "Установленные модуль или tools не умеют AWG $target"
      ask_yes "  Обновить компоненты сейчас? [Y/n]: " y || return 1
      mod_update_flow || return 1
      tools_update_flow || return 1
      proto_supported "$target" || { err "AWG $target всё ещё не поддерживается"; return 1; }
    fi
  fi

  auto_backup regen || warn "Авто-бэкап не удался"
  _params_snapshot snap || return 1

  MTU=$(conf_iface_get MTU)
  gen_awg_params "$profile" "$target" || return 1
  py params-replace "$SERVER_CONF" <<< "$AWG_PARAMS" || { err "Не удалось обновить $SERVER_CONF"; return 1; }
  [[ -n "$MTU" && "$MTU" != "$(conf_iface_get MTU)" ]] && sed -i "s/^MTU = .*/MTU = $MTU/" "$SERVER_CONF"
  conf_marker_set AWG_PROTO "$target"
  sed -i "s/^# AmneziaWG Toolza — AWG .* server config/# AmneziaWG Toolza — AWG $target server config/" "$SERVER_CONF"
  ka=$(keepalive_for "$target")
  while read -r f; do
    py params-replace "$f" <<< "$AWG_PARAMS" && py keepalive-set "$f" "$ka" && n=$((n + 1))
  done < <(client_files)
  client_files_sync_suffix

  # Параметры [Interface] syncconf не применяет — только down/up.
  server_restart || { _params_restore "$snap"; return 1; }
  log_info "параметры перегенерированы: $cur → $target, клиентов $n"
  success_box "AWG $target: параметры обновлены, клиентов $n"
  warn "Каждому клиенту нужен новый конфиг — до замены он не подключится"
  (( n > 0 )) && info "Все конфиги архивом: Клиенты → Экспорт; по одному — QR/текст или бот"
  [[ "$target" == 3.1 && "$cur" != 3.1 ]] && info "Клиентам нужен AmneziaVPN 5.0.1.5+ или AmneziaWG с поддержкой 3.1"
  mimicry_module_warnings
}

# ── Параметры вручную ─────────────────────────────────────
# Правки «Ключ=значение» поверх текущих параметров. Проверка — py params-check
# (пределы генератора); итог — в PARAMS_*: KEYS «ключ<TAB>значение» после
# правок, ERR и WARN построчно, CHANGED и BREAKING — ключи (BREAKING обязаны
# совпадать у клиентов), NEW — новый блок параметров.
PARAMS_KEYS="" PARAMS_ERR="" PARAMS_WARN="" PARAMS_CHANGED="" PARAMS_BREAKING="" PARAMS_NEW="" PARAMS_CLIENTS=0
params_check() {
  local out
  out=$(server_params | py params-check "$(server_proto)" "$(conf_iface_get MTU)" "$@") || return 1
  PARAMS_KEYS=$(sed -n 's/^K\t//p' <<< "$out")
  PARAMS_ERR=$(sed -n 's/^E\t//p' <<< "$out")
  PARAMS_WARN=$(sed -n 's/^W\t//p' <<< "$out")
  PARAMS_CHANGED=$(sed -n 's/^C\t//p' <<< "$out")
  PARAMS_BREAKING=$(sed -n 's/^B\t//p' <<< "$out")
  PARAMS_NEW=$(sed -n 's/^P\t//p' <<< "$out")
}

# Новый блок — в сервер и всех клиентов (как при перегенерации: у клиентов те
# же значения), рестарт; awg0 не поднялся — откат.
params_edit_apply() {
  local snap f n=0 keys
  auto_backup params || warn "Авто-бэкап не удался"
  _params_snapshot snap || return 1
  py params-replace "$SERVER_CONF" <<< "$PARAMS_NEW" || { err "Не удалось обновить $SERVER_CONF"; return 1; }
  while read -r f; do
    py params-replace "$f" <<< "$PARAMS_NEW" && n=$((n + 1))
  done < <(client_files)
  server_restart || { _params_restore "$snap"; return 1; }
  PARAMS_CLIENTS=$n
  keys=$(tr '\n' ' ' <<< "$PARAMS_CHANGED"); keys="${keys% }"
  log_info "параметры изменены вручную: $keys; клиентов $n"
  success_box "Параметры AWG обновлены: ${keys// /, }"
  if [[ -n "$PARAMS_BREAKING" ]]; then
    keys=$(tr '\n' ' ' <<< "$PARAMS_BREAKING"); keys="${keys% }"
    warn "${keys// /, } обязаны совпадать у клиентов — каждому нужен новый конфиг, до замены он не подключится"
    (( n > 0 )) && info "Все конфиги архивом: Клиенты → Экспорт; по одному — QR/текст или бот"
  else
    info "Старые конфиги продолжают работать; новые значения клиент получит с новым конфигом ($n)"
  fi
}

# awg2 api server params set [force] ПРАВКА... — предупреждения без force
# не пропускает: бот и панель сперва показывают их человеку (params check).
server_params_set() {
  local force=0 l
  [[ "${1:-}" == force ]] && { force=1; shift; }
  server_exists || { err "Сервер не создан"; return 1; }
  (( $# )) || { err "Нет правок: Ключ=значение"; return 1; }
  params_check "$@" || return 1
  if [[ -n "$PARAMS_ERR" ]]; then
    while IFS= read -r l; do err "$l"; done <<< "$PARAMS_ERR"
    return 1
  fi
  [[ -n "$PARAMS_CHANGED" ]] || { ok "Параметры не изменились"; return 0; }
  if [[ -n "$PARAMS_WARN" ]]; then
    while IFS= read -r l; do warn "$l"; done <<< "$PARAMS_WARN"
    (( force )) || { err "Есть предупреждения — чтобы сохранить всё равно, добавь force"; return 1; }
  fi
  params_edit_apply
}

do_params_edit_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  local -a edits=() keys=() vals=()
  local c i k v n mark l proto
  proto=$(server_proto)
  while true; do
    params_check "${edits[@]}" || return 1
    keys=(); vals=()
    while IFS=$'\t' read -r k v; do keys+=("$k"); vals+=("$v"); done <<< "$PARAMS_KEYS"
    n=${#keys[@]}
    echo ""
    hdr "Параметры AWG $proto вручную"
    echo -e "  ${D}S и H обязаны совпадать у сервера и клиентов: после их правки старые конфиги${N}"
    echo -e "  ${D}не подключатся. Jc/Jmin/Jmax и таймеры 3.x — не обязаны.${N}"
    for (( i = 0; i < n; i++ )); do
      mark=""
      grep -qx "${keys[i]}" <<< "$PARAMS_CHANGED" && mark=" ${Y}← изменён${N}"
      printf "  ${C}%2d)${N} %-22s %s%b\n" $((i + 1)) "${keys[i]}" "${vals[i]:-—}" "$mark"
    done
    echo -e "  ${G}$((n + 1)))${N} Проверить и применить"
    echo -e "  ${W} 0)${N} ← Назад ${D}(правки не сохраняются)${N}"
    read_choice c "${C}  Выбор [0-$((n + 1))]: ${N}" 0 $((n + 1)) 0
    (( c == 0 )) && return 0
    if (( c == n + 1 )); then
      _params_edit_confirm || continue
      params_edit_apply
      pause
      return 0
    fi
    k=${keys[c - 1]}; v=${vals[c - 1]}
    if [[ "$k" =~ ^(RandomTrailers|DisableCookies)$ ]]; then
      edits+=("$k=$([[ "$v" == on ]] && echo off || echo on)")
      continue
    fi
    read_line l "${C}  $k (сейчас ${v:-—}; Enter — без изменений): ${N}"
    l="${l// /}"
    [[ -n "$l" ]] && edits+=("$k=$l")
  done
}

# Показать итог проверки и спросить подтверждение; 1 — вернуться к правке.
_params_edit_confirm() {
  local l keys
  [[ -n "$PARAMS_CHANGED" ]] || { info "Ничего не изменено"; return 1; }
  if [[ -n "$PARAMS_ERR" ]]; then
    while IFS= read -r l; do err "$l"; done <<< "$PARAMS_ERR"
    return 1
  fi
  if [[ -n "$PARAMS_WARN" ]]; then
    while IFS= read -r l; do warn "$l"; done <<< "$PARAMS_WARN"
    ask_yes "  Сохранить всё равно? [y/N]: " n || return 1
  fi
  if [[ -n "$PARAMS_BREAKING" ]]; then
    keys=$(tr '\n' ' ' <<< "$PARAMS_BREAKING"); keys="${keys% }"
    warn "Меняются ${keys// /, } — все клиенты ($(client_files | grep -c . || true)) потеряют связь до получения нового конфига"
    read_confirm "${R}  Продолжить? (введи yes): ${N}" || { info "Отменено"; return 1; }
  else
    info "Старые конфиги продолжат работать — клиентам совпадать не обязательно"
    ask_yes "  Применить? [Y/n]: " y || return 1
  fi
}

do_proto_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  local cur c target n
  cur=$(server_proto)
  n=$(client_files | wc -l)
  echo ""
  hdr "Протокол и параметры"
  echo -e "  Сейчас: ${W}AWG $cur${N}, профиль ${W}$(profile_label)${N}, клиентов ${W}$n${N}"
  echo ""
  if [[ "$cur" != 3.1 ]]; then
    echo -e "  ${G}1)${N} Перейти на AWG 3.1 ${D}— быстрее 2.0${N}"
  else
    echo -e "  ${C}1)${N} Новые параметры AWG 3.1"
  fi
  if [[ "$cur" == 2.0 ]]; then
    echo -e "  ${C}2)${N} Перегенерировать параметры AWG 2.0"
  else
    echo -e "  ${Y}2)${N} Вернуться на AWG 2.0 ${D}— для старых клиентов${N}"
  fi
  echo -e "  ${C}3)${N} Изменить параметры вручную ${D}— Jc, S1-S4, H1-H4…${N}"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор [0-3]: ${N}" 0 3 0
  case "$c" in 1) target=3.1 ;; 2) target=2.0 ;; 3) do_params_edit_menu; return ;; *) return 0 ;; esac
  echo ""
  warn "Все клиенты ($n) потеряют связь до получения нового конфига"
  [[ "$target" != "$cur" ]] && warn "Версия меняется: AWG $cur → AWG $target"
  read_confirm "${R}  Продолжить? (введи yes): ${N}" || { info "Отменено"; return 0; }
  server_regen_params "$target"
}

# ── Endpoint ──────────────────────────────────────────────
# endpoint_set ДОМЕН|"" [переписать_выданные 1|0] — пусто = публичный IP.
endpoint_set() {
  local d="${1,,}" rw="${2:-1}" ep port f
  server_exists || { err "Сервер не создан"; return 1; }
  port=$(server_port)
  if [[ -n "$d" ]]; then
    valid_domain "$d" || { err "Нужно имя вида vpn.example.com"; return 1; }
    conf_marker_set AWG_ENDPOINT "$d"; ep="$d:$port"
  else
    conf_marker_del AWG_ENDPOINT; ep="$(public_ip_cached):$port"
  fi
  ok "Endpoint для новых конфигов: $ep"
  if [[ "$rw" == 1 ]]; then
    while read -r f; do sed -i "s|^Endpoint = .*|Endpoint = $ep|" "$f"; done < <(client_files)
    ok "Выданные конфиги обновлены — клиентам нужно забрать новые"
  fi
}

do_endpoint_menu() {
  server_exists || { err "Сервер не создан"; return 1; }
  local cur port c d rw
  cur=$(endpoint_domain); port=$(server_port)
  echo ""
  hdr "Endpoint для клиентов"
  echo -e "  Сейчас: ${W}${cur:-$(public_ip_cached)}:$port${N} ${D}(${cur:+домен}${cur:-IP})${N}"
  echo -e "  ${C}1)${N} Задать домен"
  echo -e "  ${C}2)${N} Вернуться на IP"
  echo -e "  ${W}0)${N} ← Назад"
  read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
  case "$c" in
    1) while true; do
         read_line d "${C}  Домен (Enter — отмена): ${N}"; d="${d// /}"
         [[ -z "$d" ]] && return 0
         valid_domain "$d" && break
         warn "Нужно имя вида vpn.example.com"
       done
       domain_points_here "$d" || ask_yes "  Всё равно задать? [y/N]: " n || return 0 ;;
    2) [[ -n "$cur" ]] || { info "Уже IP"; return 0; }
       d="" ;;
    *) return 0 ;;
  esac
  rw=0
  (( $(client_files | wc -l) )) && ask_yes "  Переписать Endpoint в уже выданных конфигах? [Y/n]: " y && rw=1
  endpoint_set "$d" "$rw"
}

# ── Сброс ─────────────────────────────────────────────────
do_reset_server() {
  server_exists || { info "Сервер не создан"; return 0; }
  echo ""
  hdr "Сброс сервера"
  warn "Будут удалены awg0, $SERVER_CONF и все клиенты ($(client_files | wc -l))."
  info "Компоненты и бэкапы остаются; авто-бэкап будет сделан."
  read_confirm "${R}  Подтверди сброс (введи yes): ${N}" || { info "Отменено"; return 0; }
  server_reset
}

# Удаляет сервер и клиентов (компоненты и бэкапы остаются).
server_reset() {
  server_exists || { info "Сервер не создан"; return 0; }
  auto_backup reset || warn "Авто-бэкап не удался"
  tunnels_panic_reset quiet
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  rm -f "$SERVER_CONF" "$SERVER_CONF".bak.* "$SERVER_CONF".pre_* "$CLIENT_DIR"/*_awg[23].conf
  rm -f "$TRAFFIC_DB" "$TRAFFIC_DB.lock"
  ufw_delete_matching AmneziaWG
  : > "$WARP_PEERS" 2>/dev/null || true
  : > "$XRAY_PEERS" 2>/dev/null || true
  : > "$EXITS_PEERS" 2>/dev/null || true
  # Снимок счётчиков — метка жизни таймера: старый после сброса заставил бы
  # сторож «чинить» таймер посреди создания нового сервера
  rm -f "$EXPIRE_STATE_DIR/transfer"
  ok "Сервер сброшен. Создать новый: Сервер → Создать сервер"
  log_info "сервер сброшен"
}
