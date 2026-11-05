# WARP (Cloudflare): выход клиентов через Cloudflare, когда IP сервера в
# блок-листах. Два бэкенда с одним интерфейсом warp0 — поэтому список
# клиентов, правила и статус в боте от бэкенда не зависят:
#   wg    — kernel WireGuard, профиль от wgcf. Быстрый, нужен модуль wireguard.
#   usque — MASQUE поверх QUIC в userspace. Без модулей ядра, дороже по CPU.

warp_backend() {
  local b
  b=$(tr -d '[:space:]' 2>/dev/null < "$WARP_BACKEND_FILE" || true)
  [[ "$b" == usque ]] && echo usque || echo wg
}

warp_wg_possible()    { modprobe wireguard 2>/dev/null || [[ -d /sys/module/wireguard ]]; }
# Профиль есть (wg или usque) — WARP можно включать
warp_configured()     { [[ -f "$WARP_CONF" || -s "$USQUE_CONF" ]]; }
warp_usque_possible() {
  [[ -n "$(go_arch)" ]] || return 1
  [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null
  [[ -c /dev/net/tun ]]
}

_warp_deps() {
  need_cmds wg:wireguard-tools ping:iputils-ping || return 1
  mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
}

_warp_state_write() {  # бэкенд
  mkdir -p "$WARP_DIR"
  printf 'active\nbackend=%s\nclient_net=%s\niface=%s\n' "$1" "$(server_net)" "$(uplink_iface)" > "$WARP_STATE"
}

# ── Бэкенд wg ─────────────────────────────────────────────
_wgcf_install() {
  local arch vers=() v tmp
  command -v wgcf &>/dev/null && wgcf --help &>/dev/null && return 0
  arch=$(go_arch)
  [[ -n "$arch" ]] || { err "Архитектура $(uname -m) не поддерживается wgcf"; return 1; }
  v=$(gh_latest_tag ViRb3/wgcf)
  [[ -n "$v" ]] && vers+=("${v#v}")
  vers+=("${WGCF_FALLBACK_VERS[@]}")
  mktmp tmp || return 1
  for v in "${vers[@]}"; do
    info "Скачиваю wgcf v$v..."
    if gh_fetch "https://github.com/ViRb3/wgcf/releases/download/v$v/wgcf_${v}_linux_${arch}" "$tmp" 1000000 elf; then
      install -m 755 "$tmp" /usr/local/bin/wgcf
      wgcf --help &>/dev/null && { ok "wgcf v$v установлен"; return 0; }
    fi
  done
  err "wgcf не скачался ни напрямую, ни через зеркала"
  return 1
}

_wgcf_register() {
  local i delay=3 out
  mkdir -p "$WARP_DIR"
  [[ -f "$WARP_ACCOUNT" ]] && { info "Аккаунт WARP уже зарегистрирован"; return 0; }
  for i in 1 2 3; do
    info "Регистрация в Cloudflare, попытка $i/3..."
    if out=$(cd "$WARP_DIR" && wgcf register --accept-tos 2>&1) && [[ -f "$WARP_ACCOUNT" ]]; then
      chmod 600 "$WARP_ACCOUNT"
      ok "Аккаунт WARP зарегистрирован"
      return 0
    fi
    (( i < 3 )) && { sleep "$delay"; delay=$(( delay * 2 )); }
  done
  err "Регистрация не удалась: $(tail -1 <<< "$out")"
  info "С российских VPS API Cloudflare часто недоступен — зарегистрируй профиль"
  info "в другом месте и импортируй его: пункт «Импорт wgcf-profile.conf»"
  return 1
}

_wgcf_generate() {
  (cd "$WARP_DIR" && wgcf generate) >/dev/null 2>&1 && [[ -f "$WARP_PROFILE" ]] \
    || { err "wgcf generate не сработал"; return 1; }
  install -m 600 "$WARP_PROFILE" "$WARP_CONF"
  ok "Профиль: $WARP_CONF"
}

warp_wg_install() { _warp_deps && _wgcf_install && _wgcf_register && _wgcf_generate; }

warp_license() {
  local key
  info "Ключ Warp+ — в приложении 1.1.1.1: Аккаунт → Ключ (формат xxxx-xxxx-xxxx)"
  read_line key "${C}  Ключ (Enter — отмена): ${N}"
  [[ -z "$key" ]] && return 0
  warp_license_set "$key"
}

warp_license_set() {  # ключ
  local key="$1" type
  [[ -f "$WARP_ACCOUNT" ]] && grep -q '^license_key\|^access_token\|^device_id' "$WARP_ACCOUNT" \
    || { err "Сначала зарегистрируй аккаунт WARP"; return 1; }
  [[ "$key" =~ ^[A-Za-z0-9]+-[A-Za-z0-9]+-[A-Za-z0-9]+$ ]] || { err "Неверный формат ключа"; return 1; }
  if grep -q '^license_key' "$WARP_ACCOUNT"; then sed -i "s|^license_key = .*|license_key = \"$key\"|" "$WARP_ACCOUNT"
  else echo "license_key = \"$key\"" >> "$WARP_ACCOUNT"; fi
  (cd "$WARP_DIR" && wgcf update) &>/dev/null || { err "Cloudflare не принял ключ"; return 1; }
  type=$(cd "$WARP_DIR" && wgcf status 2>/dev/null | grep -oP 'Account type\s*:\s*\K\S+' || true)
  case "$type" in
    unlimited|limited|premium) ok "Warp+ активирован ($type)"; echo "$type" > "$WARP_DIR/account_type" ;;
    *) warn "Ключ применён, но Warp+ не активен (${type:-тип неизвестен})"; rm -f "$WARP_DIR/account_type" ;;
  esac
  _wgcf_generate || return 1
  warp_is_up && info "Туннель работает на старом профиле — перезапусти его"
  return 0
}

# Импорт готового wgcf-profile.conf (регистрация с сервера не проходит).
warp_import() {
  local content k
  _warp_deps || return 1
  echo -e "  Зарегистрируй профиль там, где Cloudflare доступен (например, shell.cloud.google.com):"
  echo -e "  ${G}curl -fsSL -o wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.30/wgcf_2.2.30_linux_amd64 && chmod +x wgcf && ./wgcf register --accept-tos && ./wgcf generate && cat wgcf-profile.conf${N}"
  echo -e "  Вставь вывод целиком, затем Enter и Ctrl+D:"
  content=$(cat)
  for k in '^\[Interface\]' '^PrivateKey' '^Address' '^\[Peer\]' '^PublicKey' '^Endpoint'; do
    grep -q "$k" <<< "$content" || { err "Не похоже на wgcf-profile.conf: нет ${k//[\\^]/}"; return 1; }
  done
  mkdir -p "$WARP_DIR"
  [[ -f "$WARP_PROFILE" ]] && cp -a "$WARP_PROFILE" "$WARP_PROFILE.bak.$(date +%s)"
  printf '%s\n' "$content" | write_file "$WARP_PROFILE" 600
  install -m 600 "$WARP_PROFILE" "$WARP_CONF"
  [[ -f "$WARP_ACCOUNT" ]] || printf '# импортирован готовый профиль\nimported = true\n' | write_file "$WARP_ACCOUNT" 600
  [[ -n "$(warp_awg_params)" ]] && info "В профиле параметры AmneziaWG — WARP поднимется через AmneziaWG"
  ok "Профиль импортирован — включай туннель"
}

# Параметры AmneziaWG из профиля WARP (Jc, Jmin, Jmax, S1-S4, H1-H4, I1-I5),
# строками «Ключ = значение». Их несут готовые профили «WARP для России»:
# с российских серверов чистый WireGuard к Cloudflare режут, а с мусорными
# пакетами AmneziaWG рукопожатие проходит.
warp_awg_params() {
  sed -nE 's/^[[:space:]]*(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5])[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1 = \2/p' \
    "$WARP_CONF" 2>/dev/null
}

# wg или awg — чем говорить с warp0: из профиля с параметрами AWG он amneziawg
warp_tool() { if ip -d link show "$WARP_IF" 2>/dev/null | grep -q amneziawg; then echo awg; else echo wg; fi; }

# Поднимает warp0 из профиля и уводит в него клиентов. Работает и в
# скрипте автозапуска, поэтому без вывода в интерфейс пользователя.
warp_wg_bringup() {
  local priv pub ep mtu addr a tmp obf kind=wireguard tool=wg
  [[ -f "$WARP_CONF" && -f "$SERVER_CONF" ]] || return 1
  ip link show "$WARP_IF" &>/dev/null && return 0
  priv=$(awk -F' = ' '/^PrivateKey/{print $2; exit}' "$WARP_CONF")
  pub=$(awk -F' = ' '/^PublicKey/{print $2; exit}' "$WARP_CONF")
  ep=$(awk -F' = ' '/^Endpoint/{print $2; exit}' "$WARP_CONF")
  mtu=$(awk -F' = ' '/^MTU/{print $2; exit}' "$WARP_CONF")
  # Только IPv4-адрес: IPv6 в туннель не пускаем (утечки, IPv6 часто выключен)
  for a in $(awk -F' = ' '/^Address/{print $2}' "$WARP_CONF" | tr ',' ' '); do
    [[ "$a" == *.* ]] && addr="$a"
  done
  [[ -n "$priv" && -n "$pub" && -n "$ep" && -n "${addr:-}" ]] || { echo "профиль WARP не разобран" >&2; return 1; }
  # Профиль с параметрами AmneziaWG — через AmneziaWG: wg их не знает и отверг бы
  obf=$(warp_awg_params)
  if [[ -n "$obf" ]] && command -v awg >/dev/null; then kind=amneziawg; tool=awg; else obf=""; fi
  ip link add dev "$WARP_IF" type "$kind" || return 1
  # Временный файл — в /etc/wireguard: пакетный wg на Ubuntu 26.04 не читает
  # из /tmp (AppArmor), а /etc/wireguard — каталог root:700.
  tmp="/etc/wireguard/.warp0.$$"
  printf '[Interface]\nPrivateKey = %s\n%s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = %s\n' \
    "$priv" "$obf" "$pub" "$ep" > "$tmp"
  chmod 600 "$tmp"
  if ! "$tool" setconf "$WARP_IF" "$tmp"; then rm -f "$tmp"; ip link del "$WARP_IF"; return 1; fi
  rm -f "$tmp"
  ip -4 addr add "$addr" dev "$WARP_IF"
  ip link set mtu "${mtu:-1280}" up dev "$WARP_IF" || { ip link del "$WARP_IF"; return 1; }
  # Health-check возвращает WARP без клиентов: маршруты — только после ответа Cloudflare
  [[ -n "${WARP_NO_RT:-}" ]] && return 0
  rt_up "$WARP_IF" "$WARP_TABLE" "$WARP_PEERS" "${addr%/*}"
}

_warp_autostart_install() {
  emit_script "$WARP_AUTOSTART_SCRIPT" 'warp_wg_bringup' \
    WARP_CONF WARP_IF WARP_TABLE WARP_PEERS "${RT_FUNCS[@]}" warp_awg_params warp_wg_bringup || return 1
  write_unit awg-warp.service <<EOF
[Unit]
Description=AWG Toolza — WARP для клиентов AWG
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=$WARP_STATE
ConditionPathExists=$WARP_CONF

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$WARP_AUTOSTART_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable awg-warp.service &>/dev/null
}

# ── Бэкенд usque ──────────────────────────────────────────
_usque_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo linux_amd64 ;; aarch64|arm64) echo linux_arm64 ;;
    armv7l|armv7) echo linux_armv7 ;; *) echo "" ;;
  esac
}

_usque_install_bin() {
  local arch ver tmp asset want
  "$USQUE_BIN" version &>/dev/null && return 0
  arch=$(_usque_arch)
  need_cmds unzip:unzip || return 1
  ver=$(gh_latest_tag Diniboy1123/usque); ver="${ver#v}"
  ver="${ver:-$USQUE_FALLBACK_VER}"
  mktmp tmp -d || return 1
  asset="usque_${ver}_${arch}.zip"
  info "Скачиваю usque v$ver..."
  gh_fetch "https://github.com/Diniboy1123/usque/releases/download/v$ver/$asset" "$tmp/u.zip" 100000 zip \
    || { err "usque не скачался"; return 1; }
  if gh_fetch "https://github.com/Diniboy1123/usque/releases/download/v$ver/checksums.txt" "$tmp/sums" 64 any; then
    want=$(awk -v a="$asset" '$2 == a {print $1; exit}' "$tmp/sums")
    sha256_check "$tmp/u.zip" "$want" || { [[ $? == 1 ]] && { err "Контрольная сумма usque не совпала"; return 1; }; }
  fi
  unzip -oq "$tmp/u.zip" usque -d "$tmp" && install -m 755 "$tmp/usque" "$USQUE_BIN" || return 1
  "$USQUE_BIN" version &>/dev/null || { rm -f "$USQUE_BIN"; err "usque не запускается"; return 1; }
  ok "usque v$ver установлен"
}

_usque_register() {
  local i delay=5 out
  mkdir -p "$USQUE_DIR" && chmod 700 "$USQUE_DIR"
  [[ -s "$USQUE_CONF" ]] && return 0
  for i in 1 2 3 4; do
    info "Регистрация usque, попытка $i/4..."
    out=$("$USQUE_BIN" register --accept-tos --config "$USQUE_CONF" 2>&1) && [[ -s "$USQUE_CONF" ]] \
      && { chmod 600 "$USQUE_CONF"; ok "Устройство зарегистрировано"; return 0; }
    # Лимит частоты регистраций — не ошибка, а «приходи позже»
    grep -qiE '429|rate.?limit|too many' <<< "$out" && warn "Cloudflare ограничил частоту регистраций"
    (( i < 4 )) && { sleep "$delay"; delay=$(( delay * 3 )); }
  done
  err "Регистрация usque не удалась — подожди 10-15 минут и повтори"
  return 1
}

# Хук on-connect: usque вызывает его при каждом (пере)подключении и передаёт
# USQUE_IFACE, USQUE_IPV4, USQUE_ENDPOINT. main-таблицу не трогаем: пример из
# документации usque заворачивает туда default и отрезает сервер от SSH.
usque_on_connect() {
  local dev="${USQUE_IFACE:-$WARP_IF}" src="${USQUE_IPV4:-}" ep gw up
  ep="${USQUE_ENDPOINT:-}"; ep="${ep#[}"; ep="${ep%%]*}"; ep="${ep%%:*}"
  read -r gw up < <(ip -4 route show default | awk '{for(i=1;i<NF;i++){if($i=="via")g=$(i+1); if($i=="dev")d=$(i+1)} print g, d; exit}')
  [[ "$ep" =~ ^[0-9.]+$ && -n "$gw" ]] && ip route replace "$ep/32" via "$gw" dev "$up" 2>/dev/null
  rt_up "$dev" "$WARP_TABLE" "$WARP_PEERS" "${src%%/*}"
  echo "$(date '+%F %T') on-connect: $dev ${src:-?} ${USQUE_ENDPOINT:-?}" >> "$USQUE_LOG"
}

_usque_write() {
  emit_script "$USQUE_UP_HOOK" 'usque_on_connect' WARP_IF WARP_TABLE WARP_PEERS USQUE_LOG \
    "${RT_FUNCS[@]}" usque_on_connect || return 1
  # При обрыве правила не снимаем: usque сам переподключается, а снос правил
  # на каждый разрыв по простою дал бы мигание маршрутов.
  printf '#!/bin/sh\necho "$(date "+%%F %%T") on-disconnect: ${USQUE_EVENT:-?}" >> %s\n' "$USQUE_LOG" \
    | write_file "$USQUE_DOWN_HOOK" 755
  printf 'net.core.rmem_max = 7500000\nnet.core.wmem_max = 7500000\n' | write_file "$USQUE_SYSCTL" 644
  sysctl -q -p "$USQUE_SYSCTL" &>/dev/null || true
  # --no-tunnel-ipv6: IPv6 в туннель не пускаем, а на хостах с выключенным
  # IPv6 usque без него не может создать TUN вообще.
  write_unit awg-usque.service <<EOF
[Unit]
Description=AWG Toolza — WARP через usque (MASQUE)
After=network-online.target awg-quick@awg0.service
Wants=network-online.target
ConditionPathExists=$USQUE_CONF

[Service]
ExecStart=$USQUE_BIN nativetun --config $USQUE_CONF --interface-name $WARP_IF --no-tunnel-ipv6 --always-reconnect --on-connect $USQUE_UP_HOOK --on-disconnect $USQUE_DOWN_HOOK
Restart=always
RestartSec=5
StandardOutput=append:$USQUE_LOG
StandardError=append:$USQUE_LOG

[Install]
WantedBy=multi-user.target
EOF
}

warp_usque_install() { _usque_install_bin && _usque_register && _usque_write; }

# ── Включение / выключение ────────────────────────────────
warp_up() {
  local be i had=""
  server_exists || { err "Сначала создай сервер"; return 1; }
  [[ -f "$WARP_STATE" ]] && had=1
  tunnel_guard warp || return 1
  warp_is_up && { info "WARP уже включён"; return 0; }
  be=$(warp_backend)
  peers_sync "$WARP_PEERS"; peers_seed "$WARP_PEERS"
  if [[ "$be" == usque ]]; then
    [[ -s "$USQUE_CONF" && -x "$USQUE_BIN" ]] || { err "usque не установлен — «Установить и зарегистрировать»"; return 1; }
    _usque_write || return 1
    systemctl enable awg-usque.service &>/dev/null
    systemctl restart awg-usque.service || { err "awg-usque не стартовал: journalctl -u awg-usque"; return 1; }
    for i in {1..20}; do warp_is_up && break; sleep 1; done
  else
    _warp_deps || return 1
    [[ -f "$WARP_CONF" ]] || { err "Нет профиля WARP — «Установить и зарегистрировать» или импорт"; return 1; }
    warp_wg_bringup || { err "warp0 не поднялся"; return 1; }
  fi
  info "Проверяю выход через Cloudflare..."
  for i in 1 2 3; do
    [[ -n "$(iface_egress_ip "$WARP_IF" 5)" ]] && break
    (( i == 3 )) && {
      err "Через WARP трафик не идёт — выключаю, клиенты остаются напрямую"
      [[ "$be" == wg ]] && info "Попробуй найти рабочий endpoint (warpscout) или импортировать профиль"
      [[ "$be" == wg && -z "$(warp_awg_params)" ]] && info "С российских серверов чистый WireGuard к Cloudflare часто режут — помогает профиль с параметрами AmneziaWG (Jc, Jmin, Jmax)"
      # WARP упал раньше, а health-check включён — он и дальше пробует вернуть его сам
      if [[ -n "$had" ]] && unit_active awg-warp-healthcheck.timer; then
        warp_failover
        info "Health-check продолжит пробовать сам и вернёт WARP, когда Cloudflare ответит"
      else
        warp_down quiet
      fi
      return 1
    }
    sleep 2
  done
  _warp_state_write "$be"
  rm -f "$WARP_STATE.failed"
  [[ "$be" == wg ]] && _warp_autostart_install
  ok "WARP включён: клиентов через туннель — $(grep -c . "$WARP_PEERS" || true)"
  info "SSH и трафик самого сервера идут напрямую"
}

warp_down() {
  rt_down "$WARP_IF" "$WARP_TABLE"
  if [[ "$(warp_backend)" == usque ]]; then
    systemctl stop awg-usque.service &>/dev/null || true
    systemctl disable awg-usque.service &>/dev/null || true
  fi
  ip link del "$WARP_IF" &>/dev/null || true
  systemctl disable awg-warp.service &>/dev/null || true
  rm -f "$WARP_STATE" "$WARP_STATE.failed"
  [[ "${1:-}" == quiet ]] || ok "WARP выключен — клиенты идут напрямую"
}

# ── Health-check ──────────────────────────────────────────
# Раз в минуту — пинг 1.1.1.1 через warp0. Три провала подряд — клиенты WARP
# уходят напрямую (warp_failover), а WARP остаётся включённым. Дальше
# health-check сам возвращает его, пока не вернёт или пока WARP либо
# health-check не выключат: первые 10 попыток — раз в минуту, потом раз в
# 5 минут (сеть хостера может лежать часами). Пробует без клиентов: warp0
# поднимается без их маршрутов, и только ответ Cloudflare возвращает их в туннель.
warp_ping() { ping -c3 -i0.5 -W2 -I "$WARP_IF" 1.1.1.1 &>/dev/null; }

# Клиенты WARP — напрямую, WARP остаётся включённым с меткой .failed.
warp_failover() {
  rt_down "$WARP_IF" "$WARP_TABLE"
  # usque держит warp0 сам: гасим службу, иначе warp_is_up остаётся истинным,
  # warp_up отвечает «уже включён», а хук usque при реконнекте вернёт правила.
  if [[ "$(cat "$WARP_BACKEND_FILE" 2>/dev/null)" == usque ]]; then systemctl stop awg-usque.service 2>/dev/null
  else ip link del "$WARP_IF" 2>/dev/null; fi
  echo failed > "$WARP_STATE.failed"
}

warp_health_recover() {
  local r="$WARP_HEALTH_RETRY" n i src
  n=$(( $(cat "$r" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$r"
  (( n <= 10 || n % 5 == 0 )) || return 0
  # Пока WARP лежал, включили другой туннель — ему не мешаем
  [[ -z "$(tunnel_conflict warp)" ]] || return 0
  if (( n == 1 || n % 60 == 0 )); then echo "$(date '+%F %T') RETRY $n: пробую вернуть WARP" >> "$WARP_HEALTH_LOG"; fi
  if [[ "$(cat "$WARP_BACKEND_FILE" 2>/dev/null)" == usque ]]; then
    # usque поднимает warp0 и маршруты клиентов сам, когда достучится до Cloudflare
    systemctl start awg-usque.service 2>/dev/null || return 0
    for i in {1..15}; do ip link show "$WARP_IF" &>/dev/null && break; sleep 1; done
    if ! { ip link show "$WARP_IF" &>/dev/null && warp_ping; }; then warp_failover; return 0; fi
  else
    WARP_NO_RT=1 warp_wg_bringup 2>/dev/null || return 0
    if ! warp_ping; then ip link del "$WARP_IF" 2>/dev/null; return 0; fi
    src=$(ip -4 -o addr show dev "$WARP_IF" 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}')
    rt_up "$WARP_IF" "$WARP_TABLE" "$WARP_PEERS" "$src" || { warp_failover; return 0; }
  fi
  rm -f "$WARP_STATE.failed" "$r"
  echo 0 > "$WARP_HEALTH_FAILS"
  echo "$(date '+%F %T') RECOVERED: WARP снова работает, клиенты WARP — в туннеле (попытка $n)" >> "$WARP_HEALTH_LOG"
}

warp_health_run() {
  local f="$WARP_HEALTH_FAILS" n src
  command -v ping >/dev/null || exit 0
  if ! ip link show "$WARP_IF" &>/dev/null; then
    # WARP включён, а туннеля нет: health-check увёл клиентов или warp0 не поднялся при загрузке
    [[ -f "$WARP_STATE" ]] && warp_health_recover
    exit 0
  fi
  if warp_ping; then
    echo 0 > "$f"
    # Попытку вернуть WARP прервали между подъёмом warp0 и маршрутами — доставить маршруты
    if [[ -f "$WARP_STATE" ]] && ! ip route show table "$WARP_TABLE" 2>/dev/null | grep -q '^default'; then
      src=$(ip -4 -o addr show dev "$WARP_IF" 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}')
      rt_up "$WARP_IF" "$WARP_TABLE" "$WARP_PEERS" "$src"
    fi
    exit 0
  fi
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$f"
  echo "$(date '+%F %T') FAIL $n/3" >> "$WARP_HEALTH_LOG"
  (( n >= 3 )) || exit 0
  warp_failover
  rm -f "$WARP_HEALTH_RETRY"
  echo "$(date '+%F %T') FAILOVER: клиенты идут напрямую, WARP вернётся сам" >> "$WARP_HEALTH_LOG"
}

_warp_health_emit() {
  emit_script "$WARP_HEALTH_SCRIPT" 'warp_health_run' WARP_IF WARP_TABLE WARP_STATE WARP_CONF WARP_PEERS \
    WARP_BACKEND_FILE WARP_HEALTH_LOG WARP_HEALTH_FAILS WARP_HEALTH_RETRY XRAY_IF XRAY_UNIT T2S_UNIT EXITS_UNIT "${RT_FUNCS[@]}" \
    unit_active warp_is_up xray_is_up t2s_is_up exits_is_up tunnel_conflict \
    warp_awg_params warp_wg_bringup warp_ping warp_failover warp_health_recover warp_health_run
}

warp_health_on() {
  _warp_health_emit || return 1
  write_unit awg-warp-healthcheck.service <<EOF
[Unit]
Description=AWG Toolza — проверка WARP

[Service]
Type=oneshot
ExecStart=$WARP_HEALTH_SCRIPT
EOF
  write_unit awg-warp-healthcheck.timer <<'EOF'
[Unit]
Description=AWG Toolza — проверка WARP раз в минуту

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
EOF
  systemctl enable --now awg-warp-healthcheck.timer &>/dev/null \
    && ok "Health-check включён: раз в минуту; WARP не отвечает — клиенты напрямую, WARP вернётся сам"
}

warp_health_off() {
  remove_unit awg-warp-healthcheck.timer awg-warp-healthcheck.service
  rm -f "$WARP_HEALTH_SCRIPT" "$WARP_HEALTH_FAILS" "$WARP_HEALTH_RETRY"
}

# ── warpscout: поиск рабочего endpoint ────────────────────
_warpscout_ready() {
  if ! "$WARPSCOUT_BIN" version &>/dev/null; then
    [[ "$(go_arch)" =~ ^(amd64|arm64)$ ]] || { err "warpscout — только amd64/arm64"; return 1; }
    info "Ставлю warpscout..."
    curl -4 -fsSL --max-time 60 https://raw.githubusercontent.com/vernette/warpscout/master/install.sh \
      | INSTALL_DIR="${WARPSCOUT_BIN%/*}" sh -s -- -y >/dev/null 2>&1
    "$WARPSCOUT_BIN" version &>/dev/null || { err "warpscout не установился"; return 1; }
  fi
  mkdir -p "$WARPSCOUT_DIR" && chmod 700 "$WARPSCOUT_DIR"
  [[ -s "$WARPSCOUT_ACCOUNT" ]] || "$WARPSCOUT_BIN" register -a "$WARPSCOUT_ACCOUNT" >/dev/null 2>&1 \
    || { err "Регистрация warpscout не удалась"; return 1; }
}

# Лучший endpoint по замерам warpscout → сразу в профиль. $1 — страна (DE, NL...).
warp_endpoint_best() {
  local best
  [[ "$(warp_backend)" == wg ]] || { err "Только для бэкенда wg"; return 1; }
  [[ -z "${1:-}" || "$1" =~ ^[A-Za-z]{2}$ ]] || { err "Страна — две буквы (DE, NL)"; return 1; }
  _warpscout_ready || return 1
  info "Сканирую (до минуты)..."
  best=$("$WARPSCOUT_BIN" scan -p awg -a "$WARPSCOUT_ACCOUNT" -best ${1:+-country "${1^^}"} 2>/dev/null | tail -1)
  warp_endpoint_set "$best"
}

warp_endpoint_set() {  # ip:порт
  local pub
  [[ "$1" =~ ^[0-9.]+:[0-9]+$ ]] || { err "Ни один endpoint не прошёл проверку — UDP к Cloudflare, похоже, режут"; return 1; }
  sed -i "s|^Endpoint = .*|Endpoint = $1|" "$WARP_CONF" "$WARP_PROFILE" 2>/dev/null
  if warp_is_up; then
    pub=$("$(warp_tool)" show "$WARP_IF" peers | head -1)
    [[ -n "$pub" ]] && "$(warp_tool)" set "$WARP_IF" peer "$pub" endpoint "$1"
  fi
  ok "Endpoint: $1"
}

warp_find_endpoint() {
  local c country rep lines=() i
  [[ "$(warp_backend)" == wg ]] || { warn "Только для бэкенда wg"; return 0; }
  echo -e "  ${C}1)${N} Найти лучший и применить"
  echo -e "  ${C}2)${N} Показать список и выбрать"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 1 ]]; then
    read_line country "${C}  Страна выхода (DE,NL..., Enter — любая): ${N}"
    warp_endpoint_best "$country"
    return
  fi
  _warpscout_ready || return 1
  info "Сканирую (до минуты)..."
  mktmp rep || return 1
  "$WARPSCOUT_BIN" scan -p awg -a "$WARPSCOUT_ACCOUNT" -plain -o "$rep" 2>/dev/null
  mapfile -t lines < <(grep -oE '[0-9.]+:[0-9]+' "$rep" | sort -u)
  (( ${#lines[@]} )) || { err "Рабочих endpoint не найдено"; return 1; }
  for i in "${!lines[@]}"; do printf "  %2d) %s\n" "$((i + 1))" "${lines[$i]}"; done
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 "${#lines[@]}" 0
  (( c == 0 )) && return 0
  warp_endpoint_set "${lines[$((c - 1))]}"
}

# ── Бэкенд, статус, удаление ──────────────────────────────
warp_switch_backend() {
  local target=wg
  [[ "$(warp_backend)" == wg ]] && target=usque
  ask_yes "  Переключить бэкенд $(warp_backend) → $target? Туннель прервётся на несколько секунд [y/N]: " n || return 0
  warp_set_backend "$target"
}

warp_set_backend() {  # wg|usque — с установкой, если нужно
  local cur target="$1" was_up=0
  cur=$(warp_backend)
  [[ "$target" == wg || "$target" == usque ]] || { err "Бэкенд: wg | usque"; return 1; }
  [[ "$target" == "$cur" ]] && { ok "Бэкенд уже $cur"; return 0; }
  if [[ "$target" == wg ]] && ! warp_wg_possible; then err "Нет модуля ядра wireguard"; return 1; fi
  if [[ "$target" == usque ]] && ! warp_usque_possible; then err "usque здесь не работает (нет /dev/net/tun или архитектура)"; return 1; fi
  warp_is_up && { was_up=1; warp_down quiet; }
  echo "$target" | write_file "$WARP_BACKEND_FILE" 644
  if ! "warp_${target}_install"; then
    err "Установка $target не удалась — возвращаю $cur"
    echo "$cur" | write_file "$WARP_BACKEND_FILE" 644
    (( was_up )) && warp_up
    return 1
  fi
  (( was_up )) && warp_up
  ok "Бэкенд WARP: $(warp_backend)"
}

warp_status() {
  local be trace st colo wip n total
  be=$(warp_backend)
  echo -e "  Бэкенд    : ${W}$be${N}"
  if warp_is_up; then
    trace=$(curl -4 -s --max-time 4 --interface "$WARP_IF" https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    st=$(sed -n 's/^warp=//p' <<< "$trace"); colo=$(sed -n 's/^colo=//p' <<< "$trace"); wip=$(sed -n 's/^ip=//p' <<< "$trace")
    case "$st" in
      plus) echo -e "  Туннель   : ${G}● Warp+${N} ${D}$colo${N}" ;;
      on)   echo -e "  Туннель   : ${G}● WARP${N} ${D}$colo${N}" ;;
      "")   echo -e "  Туннель   : ${R}▲ Cloudflare не отвечает${N}" ;;
      *)    echo -e "  Туннель   : ${Y}▲ интерфейс есть, трафик мимо WARP ($st)${N}" ;;
    esac
    [[ -n "$wip" ]] && echo -e "  Внешний IP: ${C}$wip${N}"
    n=$(grep -c . "$WARP_PEERS" 2>/dev/null || true); total=$(clients_name_ip | wc -l)
    echo -e "  Клиентов  : ${W}${n:-0}${N} из $total через WARP"
  elif [[ -f "$WARP_STATE.failed" ]]; then
    echo -e "  Туннель   : ${R}выключен health-check'ом (WARP не отвечал)${N}"
  else
    echo -e "  Туннель   : ${D}○ выключен${N}"
  fi
  if unit_active awg-warp-healthcheck.timer; then echo -e "  Health    : ${G}● вкл${N}"
  else echo -e "  Health    : ${D}○ выкл${N}"; fi
}

warp_remove() {
  read_confirm "${R}  Удалить WARP (аккаунт, профиль, службы)? (введи yes): ${N}" || return 0
  warp_uninstall
}

warp_uninstall() {
  warp_down quiet
  warp_health_off
  remove_unit awg-warp.service awg-usque.service
  rm -rf "$WARP_DIR" "$WARP_CONF" /usr/local/bin/wgcf "$WARP_AUTOSTART_SCRIPT" \
         "$USQUE_BIN" "$USQUE_UP_HOOK" "$USQUE_DOWN_HOOK" "$USQUE_SYSCTL" "$WARP_BACKEND_FILE"
  # Регистрация usque упирается в лимит Cloudflare — её конфиг не удаляем молча
  [[ -s "$USQUE_CONF" ]] && info "Регистрация usque оставлена: $USQUE_CONF"
  ok "WARP удалён"
}

do_warp_menu() {
  local c be
  while true; do
    be=$(warp_backend)
    echo ""
    hdr "WARP (Cloudflare)"
    warp_status
    echo ""
    echo -e "  ${C}1)${N} Установить и зарегистрировать ($be)"
    echo -e "  ${C}2)${N} Включить туннель"
    echo -e "  ${C}3)${N} Выключить туннель"
    echo -e "  ${C}4)${N} Клиенты в WARP"
    echo -e "  ${C}5)${N} Health-check вкл/выкл"
    if [[ "$be" == wg ]]; then
      echo -e "  ${C}6)${N} Warp+ (ключ)"
      echo -e "  ${C}7)${N} Импорт wgcf-profile.conf"
      echo -e "  ${C}8)${N} Поиск рабочего endpoint (warpscout)"
    fi
    echo -e "  ${C}b)${N} Сменить бэкенд (wg ↔ usque)"
    echo -e "  ${R}d)${N} Удалить WARP"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 8 0 "b|d"
    case "$c" in
      1) if [[ "$be" == wg ]]; then warp_wg_install || true; else warp_usque_install || true; fi ;;
      2) warp_up || true ;;
      3) warp_down ;;
      4) tunnel_peers_menu "Клиенты в WARP" "$WARP_PEERS" "$WARP_IF" "$WARP_TABLE"; continue ;;
      5) if unit_active awg-warp-healthcheck.timer; then warp_health_off; ok "Health-check выключен"; else warp_health_on; fi ;;
      6) [[ "$be" == wg ]] && { warp_license || true; } ;;
      7) [[ "$be" == wg ]] && { warp_import || true; } ;;
      8) [[ "$be" == wg ]] && { warp_find_endpoint || true; } ;;
      b) warp_switch_backend || true ;;
      d) warp_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
