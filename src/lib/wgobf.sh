# WG + обфускатор: отдельный WireGuard-сервер (wgobf0) за wg-obfuscator
# (github.com/ClusterM/wg-obfuscator, GPL-3.0; собирается из закреплённого
# коммита отдельной программой, его код в скрипт не копируется).
#
# Клиент → [wg-obfuscator клиента] → порт обфускатора на сервере →
# 127.0.0.1:<порт WG> → wgobf0. Порт самого WireGuard снаружи закрыт
# (WireGuard не умеет слушать только lo), открыт лишь порт обфускатора.
#
# С AWG не пересекается: свой интерфейс и /24, туннели тулзы маршрутизируют
# только подсеть awg0, правила iptables и UFW помечены «awg-wgobf», клиенты
# лежат в /root/wgobf/<имя>/ и под маску *_awg[23].conf не попадают.
#
# state (KEY=VAL): PORT WG_PORT KEY MASKING ALLOW_CLEAN NET MTU DNS ENDPOINT SERVER_PUB

wgobf_installed() { [[ -f "$WGOBF_STATE" && -f "$WGOBF_WG_CONF" ]]; }
wgobf_get() { sed -n "s/^$1=//p" "$WGOBF_STATE" 2>/dev/null | head -1; }

wgobf_set() {
  mkdir -p "$WGOBF_DIR" && chmod 700 "$WGOBF_DIR"
  { grep -v "^$1=" "$WGOBF_STATE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } \
    | write_file "$WGOBF_STATE" 600
}

# Порт закреплён за режимом, даже когда его службы остановлены.
wgobf_owns_port() {
  wgobf_installed || return 1
  [[ "$1" == "$(wgobf_get PORT)" || "$1" == "$(wgobf_get WG_PORT)" ]]
}

wgobf_clients() { sed -n 's/^# client=//p' "$WGOBF_WG_CONF" 2>/dev/null || true; }
wgobf_bin_version() { "$WGOBF_BIN" --help 2>&1 | grep -oE 'Obfuscator v[0-9.]+' | head -1 | awk '{print $2}' || true; }
wgobf_running() { unit_active "$WGOBF_UNIT" && ip link show "$WGOBF_IF" &>/dev/null; }

# ── Правила iptables (PostUp / PostDown wgobf0) ───────────
# MASQUERADE через «! -o wgobf0», а не по имени аплинка: переименование
# интерфейса у хостера после перезагрузки ничего не ломает.
wgobf_fw_run() {
  local t net wg_port
  for t in filter nat; do ipt_del_tagged "$t" "$WGOBF_TAG"; done
  [[ "${1:-}" == up ]] || return 0
  net=$(wgobf_get NET); wg_port=$(wgobf_get WG_PORT)
  [[ -n "$net" && -n "$wg_port" ]] || { echo "wgobf-fw: в $WGOBF_STATE нет NET/WG_PORT" >&2; return 1; }
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s "$net" ! -o "$WGOBF_IF" -j MASQUERADE -m comment --comment "$WGOBF_TAG" || return 1
  iptables -I FORWARD 1 -i "$WGOBF_IF" -j ACCEPT -m comment --comment "$WGOBF_TAG" || return 1
  iptables -I FORWARD 1 -o "$WGOBF_IF" -j ACCEPT -m comment --comment "$WGOBF_TAG" || return 1
  # Порт WireGuard — только для обфускатора, который ходит через lo
  iptables -I INPUT 1 -p udp --dport "$wg_port" ! -i lo -j DROP -m comment --comment "$WGOBF_TAG" || return 1
}

_wgobf_write_service_files() {
  local clean
  emit_script "$WGOBF_FW" 'wgobf_fw_run "$@"' WGOBF_STATE WGOBF_TAG WGOBF_IF \
    ipt_del_grep ipt_del_tagged wgobf_get wgobf_fw_run || return 1
  clean=$(wgobf_get ALLOW_CLEAN)
  # masking = AUTO: сервер понимает и STUN, и голый XOR — режим выбирает клиент
  write_file "$WGOBF_OBF_CONF" 600 <<EOF
# AWG Toolza — серверный wg-obfuscator для $WGOBF_IF. Перезаписывается awg2.
[main]
source-if = 0.0.0.0
source-lport = $(wgobf_get PORT)
target = 127.0.0.1:$(wgobf_get WG_PORT)
key = $(wgobf_get KEY)
masking = AUTO
$([[ "$clean" == 1 ]] && echo "allow-clean = true")
verbose = INFO
EOF
  write_unit "$WGOBF_UNIT" <<EOF
[Unit]
Description=AWG Toolza — wg-obfuscator для $WGOBF_IF
After=network-online.target wg-quick@$WGOBF_IF.service
Wants=network-online.target

[Service]
ExecStart=$WGOBF_BIN -c $WGOBF_OBF_CONF
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
}

wgobf_start() {
  local out
  systemctl enable "wg-quick@$WGOBF_IF" "$WGOBF_UNIT" &>/dev/null || true
  if ! out=$(systemctl restart "wg-quick@$WGOBF_IF" 2>&1) || ! ip link show "$WGOBF_IF" &>/dev/null; then
    err "$WGOBF_IF не поднялся"
    [[ -n "$out" ]] && sed 's/^/    /' <<< "$out"
    journalctl -u "wg-quick@$WGOBF_IF" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  systemctl restart "$WGOBF_UNIT" &>/dev/null
  sleep 1
  unit_active "$WGOBF_UNIT" && return 0
  err "wg-obfuscator не запустился:"
  journalctl -u "$WGOBF_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

wgobf_restart() { _wgobf_write_service_files && wgobf_start; }

# Изменения пиров — без обрыва подключённых клиентов.
_wgobf_sync() {
  local stripped
  ip link show "$WGOBF_IF" &>/dev/null || return 0
  stripped=$(wg-quick strip "$WGOBF_IF" 2>/dev/null) || { wgobf_start; return; }
  wg syncconf "$WGOBF_IF" <(printf '%s\n' "$stripped")
}

# ── Сборка и зависимости ──────────────────────────────────
_wgobf_build() {
  local src
  src=$(mktemp -d /tmp/awg2.wgobf.XXXXXX) || return 1
  # Тег можно перевесить, коммит — нет: сверяем после клона
  if git -c advice.detachedHead=false clone -q --depth 1 --branch "$WGOBF_VERSION" "$WGOBF_REPO" "$src/s" \
     && [[ "$(git -C "$src/s" rev-parse HEAD)" == "$WGOBF_COMMIT" ]] \
     && make -C "$src/s" RELEASE=1 \
     && install -D -m 755 "$src/s/wg-obfuscator" "$WGOBF_BIN"; then
    rm -rf "$src"; return 0
  fi
  echo "сборка не удалась (или коммит тега $WGOBF_VERSION не $WGOBF_COMMIT)"
  rm -rf "$src"
  return 1
}

_wgobf_prepare() {
  need_cmds wg:wireguard-tools wg-quick:wireguard-tools git:git make:make gcc:gcc || return 1
  command -v qrencode &>/dev/null || apt_install qrencode &>/dev/null || true
  mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
  modprobe wireguard 2>/dev/null || true
  if ! ip link add dev wgobfchk type wireguard 2>/dev/null && ! command -v wireguard-go &>/dev/null; then
    err "Ядро $(uname -r) не умеет WireGuard, и wireguard-go не установлен"
    return 1
  fi
  ip link del dev wgobfchk 2>/dev/null || true
  [[ "$(wgobf_bin_version)" == "$WGOBF_VERSION" ]] && return 0
  run_step "Сборка wg-obfuscator $WGOBF_VERSION" _wgobf_build
}

# ── Комплект клиента ──────────────────────────────────────
# /root/wgobf/<имя>/. Ключи берутся из уже выпущенного wg.conf, поэтому
# комплект можно перевыпустить после смены настроек, не трогая ключи.
wgobf_write_bundle() {  # имя [priv addr psk]
  local name="$1" priv="${2:-}" addr="${3:-}" psk="${4:-}" dir="$WGOBF_CLIENTS/$1"
  local ep port key mask mtu dns srv allowed
  if [[ -z "$priv" ]]; then
    priv=$(sed -n 's/^PrivateKey = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    addr=$(sed -n 's/^Address = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    psk=$(sed -n 's/^PresharedKey = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    [[ -n "$priv" && -n "$addr" ]] || { err "Нет ключей клиента $name в $dir/wg.conf"; return 1; }
  fi
  ep=$(wgobf_get ENDPOINT); port=$(wgobf_get PORT); key=$(wgobf_get KEY)
  mask=$(wgobf_get MASKING); mtu=$(wgobf_get MTU); dns=$(wgobf_get DNS); srv=$(wgobf_get SERVER_PUB)
  # «Весь интернет, кроме сервера»: пакеты обфускатора к серверу иначе
  # уйдут в сам туннель
  allowed=$(py allowed-except "$ep") || return 1
  mkdir -p "$dir" && chmod 700 "$WGOBF_CLIENTS" "$dir"
  # Локальный порт обфускатора у клиента = порт сервера: у клиента с
  # несколькими такими серверами порты не столкнутся
  write_file "$dir/wg.conf" 600 <<EOF
[Interface]
PrivateKey = $priv
Address = $addr
DNS = $dns
MTU = $mtu

[Peer]
PublicKey = $srv
PresharedKey = $psk
Endpoint = 127.0.0.1:$port
AllowedIPs = $allowed
PersistentKeepalive = 25
EOF
  write_file "$dir/obfuscator.conf" 600 <<EOF
[main]
source-if = 127.0.0.1
source-lport = $port
target = $ep:$port
key = $key
masking = $mask
verbose = INFO
EOF
  rm -f "$dir/wg-direct.conf"
  if [[ "$(wgobf_get ALLOW_CLEAN)" == 1 ]]; then
    sed -e "s|^Endpoint = .*|Endpoint = $ep:$port|" -e 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, ::/0|' \
      "$dir/wg.conf" | write_file "$dir/wg-direct.conf" 600
  fi
  # Формат Phobos: без obfuscate-bytes и маскировки MEDIA — их сервер
  # ClusterM не понимает (проверено вживую)
  { cat "$dir/wg.conf"; printf '\n[instance]\ntarget = %s:%s\nkey = %s\nmasking = %s\nmax-dummy = 4\n' \
      "$ep" "$port" "$key" "$mask"; } | write_file "$dir/phobos.conf" 600
  py phobos-link "$dir/phobos.conf" "$name" | write_file "$dir/phobos-link.txt" 600
  _wgobf_write_keenetic "$name" "$dir"
  _wgobf_write_readme "$name" "$dir"
  _wgobf_write_installer "$name" "$dir"
}

_wgobf_write_keenetic() {
  local name="$1" dir="$2"
  {
    echo "Keenetic + AWG Manager — клиент $name"
    echo ""
    echo "Способ 1 — вкладка «Phobos», одной вставкой в НИЖНЕЕ поле."
    echo "AWG Manager → Новый туннель → «Phobos» → поле «Или конфиг .conf с секцией"
    echo "[instance] / ссылка phobos://» → ссылка из phobos-link.txt (или phobos.conf)."
    echo "Поле «Ссылка установки Phobos» — пустым. Во вкладке «Обфускатор» НЕ включать"
    echo "obfuscate-bytes и MEDIA: сервер их не понимает, связь пропадёт."
    echo ""
    echo "Способ 2 — вкладка «ClusterM», поля руками:"
    echo "Сервер (host:port) обфускатора: $(wgobf_get ENDPOINT):$(wgobf_get PORT)"
    echo "Ключ:                          $(wgobf_get KEY)"
    echo "Маскировка:                    $(wgobf_get MASKING)"
    echo "max-dummy:                     4"
    echo "idle-timeout:                  0"
    echo ""
    echo "Конфиг WireGuard (.conf) — всё от [Interface] до конца:"
    echo ""
    cat "$dir/wg.conf"
  } | write_file "$dir/keenetic.txt" 600
}

_wgobf_write_readme() {
  local name="$1" dir="$2"
  {
    echo "WG + обфускатор — клиент $name"
    echo "Сервер: $(wgobf_get ENDPOINT):$(wgobf_get PORT) (UDP), маскировка: $(wgobf_get MASKING)"
    echo ""
    echo "Файлы:"
    echo "  wg.conf          — WireGuard (Endpoint 127.0.0.1 — там слушает обфускатор)"
    echo "  obfuscator.conf  — wg-obfuscator $WGOBF_VERSION"
    echo "  install-linux.sh — всё на Debian/Ubuntu одной командой"
    echo "  keenetic.txt     — AWG Manager на Keenetic"
    echo "  phobos.conf      — формат Phobos (wg.conf + [instance])"
    echo "  phobos-link.txt  — то же ссылкой phobos://"
    [[ -f "$dir/wg-direct.conf" ]] && echo "  wg-direct.conf   — БЕЗ обфускатора (телефоны); DPI видит его как WireGuard"
    echo ""
    echo "Linux (Debian/Ubuntu): sudo bash install-linux.sh"
    echo ""
    echo "Windows / macOS:"
    echo "  1. wg-obfuscator $WGOBF_VERSION: https://github.com/ClusterM/wg-obfuscator/releases/tag/$WGOBF_VERSION"
    echo "  2. wg-obfuscator -c obfuscator.conf (окно не закрывать)"
    echo "  3. wg.conf — в приложение WireGuard"
    echo ""
    echo "OpenWrt: https://github.com/ClusterM/wg-obfuscator/blob/master/docs/OPENWRT.md"
    echo "Android: https://github.com/ClusterM/wg-obfuscator-android + приложение WireGuard."
    echo "iOS обфускатор не поддерживает."
  } | write_file "$dir/README.txt" 600
}

# Самостоятельный установщик клиента для Debian/Ubuntu: собирает тот же
# коммит обфускатора, кладёт конфиги и включает автозапуск.
_wgobf_write_installer() {
  local name="$1" dir="$2"
  {
    cat <<EOF
#!/bin/bash
# AWG Toolza — клиент «WG + обфускатор» ($name) для Debian/Ubuntu.
# Установка: sudo bash install-linux.sh     Удаление: sudo bash install-linux.sh --remove
set -euo pipefail
[[ \$EUID -eq 0 ]] || { echo "Запусти от root: sudo bash \$0"; exit 1; }
TAG="wgobf-$name"
LIB="/usr/local/lib/\$TAG"; CONF_DIR="/etc/\$TAG"; UNIT="\$TAG-obfuscator.service"
WG_IF="\$TAG"; [[ \${#WG_IF} -le 15 ]] || WG_IF="wgobf-cli"

if [[ "\${1:-}" == --remove ]]; then
  systemctl disable --now "wg-quick@\$WG_IF" "\$UNIT" 2>/dev/null || true
  rm -rf "/etc/systemd/system/\$UNIT" "/etc/wireguard/\$WG_IF.conf" "\$LIB" "\$CONF_DIR"
  systemctl daemon-reload
  echo "Клиент удалён"; exit 0
fi

command -v apt-get >/dev/null || { echo "Нужен Debian/Ubuntu. На другой системе — см. README.txt"; exit 1; }
need=()
for b in wg:wireguard-tools wg-quick:wireguard-tools git:git make:make gcc:gcc; do
  command -v "\${b%%:*}" >/dev/null || need+=("\${b#*:}")
done
if (( \${#need[@]} )); then apt-get update -q; apt-get install -y -q \$(printf '%s\n' "\${need[@]}" | sort -u); fi

src=\$(mktemp -d); trap 'rm -rf "\$src"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 --branch "$WGOBF_VERSION" "$WGOBF_REPO" "\$src/s"
[[ "\$(git -C "\$src/s" rev-parse HEAD)" == "$WGOBF_COMMIT" ]] || { echo "Коммит тега $WGOBF_VERSION не совпал — сборка остановлена"; exit 1; }
make -C "\$src/s" RELEASE=1 >/dev/null
install -D -m 755 "\$src/s/wg-obfuscator" "\$LIB/wg-obfuscator"

mkdir -p "\$CONF_DIR" /etc/wireguard; chmod 700 "\$CONF_DIR" /etc/wireguard
cat > "\$CONF_DIR/obfuscator.conf" <<'OBF_EOF'
EOF
    cat "$dir/obfuscator.conf"
    echo "OBF_EOF"
    echo "cat > \"/etc/wireguard/\$WG_IF.conf\" <<'WG_EOF'"
    cat "$dir/wg.conf"
    cat <<EOF
WG_EOF
chmod 600 "\$CONF_DIR/obfuscator.conf" "/etc/wireguard/\$WG_IF.conf"
# DNS в wg-quick требует resolvconf; ::/0 — включённого IPv6
command -v resolvconf >/dev/null || { sed -i '/^DNS = /d' "/etc/wireguard/\$WG_IF.conf"; echo "resolvconf нет — DNS остаётся системный"; }
if [[ "\$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == 1 ]]; then
  sed -i 's#, ::/0##' "/etc/wireguard/\$WG_IF.conf"
fi

cat > "/etc/systemd/system/\$UNIT" <<UNIT_EOF
[Unit]
Description=wg-obfuscator (клиент \$TAG)
After=network-online.target
Wants=network-online.target
Before=wg-quick@\$WG_IF.service

[Service]
ExecStart=\$LIB/wg-obfuscator -c \$CONF_DIR/obfuscator.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable --now "\$UNIT"
systemctl enable "wg-quick@\$WG_IF"
if ! systemctl restart "wg-quick@\$WG_IF"; then
  echo "WireGuard не поднялся: journalctl -u wg-quick@\$WG_IF -n 20"
  echo "Частая причина («File exists») — на устройстве уже поднят другой VPN на весь трафик."
  exit 1
fi
echo "Готово. Проверка: wg show \$WG_IF (строка latest handshake)"
EOF
  } | write_file "$dir/install-linux.sh" 700
}

wgobf_show_bundle() {
  local name="$1" dir="$WGOBF_CLIENTS/$1"
  [[ -f "$dir/wg.conf" ]] || { err "Комплект $name не найден ($dir)"; return 1; }
  # Комплекты старых версий — без файлов Phobos/Keenetic
  [[ -f "$dir/phobos-link.txt" && -f "$dir/keenetic.txt" ]] || wgobf_write_bundle "$name"
  echo ""
  hdr "Клиент $name — $dir"
  echo -e "${Y}# obfuscator.conf${N}"; cat "$dir/obfuscator.conf"
  echo -e "${Y}# wg.conf${N}"; cat "$dir/wg.conf"
  if [[ -f "$dir/wg-direct.conf" ]]; then
    echo -e "${Y}# wg-direct.conf (без обфускатора, виден DPI)${N}"
    share_config "$dir/wg-direct.conf" qr
  fi
  echo -e "${Y}# Keenetic, AWG Manager → «Phobos» (одной вставкой):${N}"
  cat "$dir/phobos-link.txt"
  echo -e "  ${D}Вкладка «ClusterM» и подробности — $dir/keenetic.txt${N}"
  info "Linux: install-linux.sh на устройство и sudo bash install-linux.sh"
  info "Забрать папку: scp -r root@$(wgobf_get ENDPOINT):$dir ."
}

# ── Клиенты ───────────────────────────────────────────────
wgobf_add_client() {
  local name="$1" base i ip="" priv pub psk bak
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя: латиница, цифры, _ и -, до 32 символов"; return 1; }
  wgobf_clients | grep -qxF "$name" && { err "Клиент $name уже есть"; return 1; }
  base=$(wgobf_get NET); base="${base%.*}"
  for i in $(seq 2 254); do
    grep -qE "^AllowedIPs = ${base//./\\.}\.$i/32$" "$WGOBF_WG_CONF" || { ip="$base.$i"; break; }
  done
  [[ -n "$ip" ]] || { err "В подсети $(wgobf_get NET) нет свободных адресов"; return 1; }
  priv=$(wg genkey); pub=$(wg pubkey <<< "$priv"); psk=$(wg genpsk)
  mktmp bak || return 1
  cp -a "$WGOBF_WG_CONF" "$bak"
  printf '\n[Peer]\n# client=%s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
    "$name" "$pub" "$psk" "$ip" >> "$WGOBF_WG_CONF"
  if ! _wgobf_sync; then
    cp -a "$bak" "$WGOBF_WG_CONF"
    err "Клиент не применился — конфиг возвращён"
    return 1
  fi
  wgobf_write_bundle "$name" "$priv" "$ip/32" "$psk" || return 1
  ok "Клиент $name: $ip"
  log_info "wgobf: добавлен клиент $name ($ip)"
}

wgobf_delete_client() {
  local name="$1" bak
  wgobf_clients | grep -qxF "$name" || { err "Клиента $name нет"; return 1; }
  mktmp bak || return 1
  cp -a "$WGOBF_WG_CONF" "$bak"
  awk -v target="# client=$name" '
    function flush() { if (blk != "" && !drop) printf "%s", blk; blk = ""; drop = 0 }
    /^\[/ { flush() }
    { blk = blk $0 "\n"; if ($0 == target) drop = 1 }
    END { flush() }
  ' "$bak" | cat -s | write_file "$WGOBF_WG_CONF" 600
  if ! _wgobf_sync; then
    cp -a "$bak" "$WGOBF_WG_CONF"
    err "Удаление не применилось — конфиг возвращён"
    return 1
  fi
  rm -rf "${WGOBF_CLIENTS:?}/$name"
  ok "Клиент $name удалён"
  log_info "wgobf: удалён клиент $name"
}

wgobf_list_clients() {
  local names=() dump now i name pub ip hs
  mapfile -t names < <(wgobf_clients)
  (( ${#names[@]} )) || { info "Клиентов нет"; return 1; }
  dump=$(wg show "$WGOBF_IF" dump 2>/dev/null | tail -n +2 || true)
  now=$(date +%s)
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    pub=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^PublicKey = / {print $3; exit}' "$WGOBF_WG_CONF")
    ip=$(awk -v t="# client=$name" '$0 == t {f = 1; next} f && /^AllowedIPs = / {print $3; exit}' "$WGOBF_WG_CONF")
    hs=$(awk -v k="$pub" '$1 == k {print $5; exit}' <<< "$dump")
    if [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 )); then hs="$(fmt_duration $((now - hs))) назад"; else hs="—"; fi
    echo -e "  ${C}$((i + 1)))${N} $name ${D}${ip%/32}${N}  рукопожатие: $hs"
  done
}

_wgobf_pick_client() {  # → CHOSEN
  local names=() c
  mapfile -t names < <(wgobf_clients)
  wgobf_list_clients || return 1
  read_choice c "${C}  Номер клиента (0 — отмена): ${N}" 0 "${#names[@]}" 0
  (( c )) || return 1
  CHOSEN="${names[$((c - 1))]}"
}

_wgobf_regen_bundles() {  # → число перевыпущенных
  local n=0 name
  while IFS= read -r name; do
    [[ -n "$name" ]] && wgobf_write_bundle "$name" && n=$((n + 1))
  done < <(wgobf_clients)
  echo "$n"
}

# Ключ обфускатора общий для сервера и всех клиентов: после смены ВСЕ
# отключаются, пока не получат новый комплект. Ключи WireGuard не меняются.
wgobf_rotate_key() {
  local old new n
  old=$(wgobf_get KEY); new=$(py rand-key 32)
  [[ -n "$new" && "$new" != "$old" ]] || { err "Не удалось сгенерировать ключ"; return 1; }
  wgobf_set KEY "$new"
  _wgobf_write_service_files
  if ! systemctl restart "$WGOBF_UNIT" 2>/dev/null; then
    wgobf_set KEY "$old"; _wgobf_write_service_files
    systemctl restart "$WGOBF_UNIT" &>/dev/null || true
    err "Обфускатор не перезапустился — ключ оставлен прежним"
    return 1
  fi
  n=$(_wgobf_regen_bundles)
  ok "Ключ заменён, комплекты перевыпущены: $n"
  warn "Старые конфиги клиентов больше не работают — раздай новые"
  log_info "wgobf: ключ обфускатора заменён"
}

# ── Установка / удаление ──────────────────────────────────
wgobf_install() {
  local ep port c mask clean dns first
  wgobf_installed && { warn "Уже установлен"; return 0; }
  echo -e "  ${D}Отдельный WireGuard ($WGOBF_IF) за wg-obfuscator $WGOBF_VERSION. AWG не затрагивается.${N}"
  echo -e "  ${D}Клиентам нужен обфускатор на устройстве: роутер, Linux, Windows, macOS.${N}"
  ep=$(public_ip_cached)
  if [[ -z "$ep" ]] || ip_is_private "$ep"; then
    while true; do
      read_line ep "${C}  Публичный IPv4 сервера: ${N}"
      [[ -n "$ep" ]] || return 0
      valid_ip "$ep" && break
      warn "Нужен IPv4 (обфускатор не умеет IPv6)"
    done
  fi
  while true; do
    read_line port "${C}  UDP-порт обфускатора (Enter — случайный): ${N}"
    [[ -z "$port" ]] && break
    valid_port "$port" && (( port >= 1024 )) || { warn "Порт 1024-65535"; continue; }
    udp_port_busy "$port" && { warn "UDP $port занят (сокет, AWG или каскад)"; continue; }
    break
  done
  echo -e "  ${C}1)${N} STUN ${D}— под видеозвонок${N} ${C}(рекомендуется)${N}"
  echo -e "  ${C}2)${N} Без маскировки ${D}— только XOR${N}"
  read_choice c "${C}  Выбор [1-2] (Enter = 1): ${N}" 1 2 1
  if [[ "$c" == 2 ]]; then mask=NONE; else mask=STUN; fi
  echo -e "  ${D}Клиенты без обфускатора (iOS) могут подключаться обычным WireGuard —${N}"
  echo -e "  ${D}но такой трафик DPI видит как WireGuard.${N}"
  clean=0; ask_yes "  Пускать клиентов без обфускатора? [y/N]: " n && clean=1
  echo -e "  ${C}1)${N} Cloudflare"
  echo -e "  ${C}2)${N} Google"
  echo -e "  ${C}3)${N} Quad9"
  read_choice c "${C}  DNS клиентов [1-3] (Enter = 1): ${N}" 1 3 1
  case "$c" in 2) dns="8.8.8.8, 8.8.4.4" ;; 3) dns="9.9.9.9, 149.112.112.112" ;; *) dns="1.1.1.1, 1.0.0.1" ;; esac
  read_line first "${C}  Имя первого клиента (Enter = client1): ${N}"
  first="${first// /}"
  wgobf_install_opts "endpoint=$ep" ${port:+"port=$port"} "masking=$mask" "clean=$clean" "dns=$dns" "client=${first:-client1}" \
    && wgobf_show_bundle "${first:-client1}"
  return 0
}

# Установка без вопросов: wgobf_install_opts ключ=значение...
#   port= (случайный)  masking=STUN|NONE  clean=0|1  dns="1.1.1.1, 1.0.0.1"
#   endpoint=публичный IPv4  client=имя первого клиента (пусто — без клиента)
wgobf_install_opts() {
  local kv k v ep="" port="" mask=STUN clean=0 dns="1.1.1.1, 1.0.0.1" first="" wg_port net priv
  wgobf_installed && { err "Уже установлен"; return 1; }
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      port) valid_port "$v" && (( v >= 1024 )) || { err "port: 1024-65535"; return 1; }
            udp_port_busy "$v" && { err "UDP $v занят"; return 1; }; port="$v" ;;
      masking) [[ "$v" =~ ^(STUN|NONE)$ ]] || { err "masking: STUN | NONE"; return 1; }; mask="$v" ;;
      clean) [[ "$v" =~ ^[01]$ ]] || { err "clean: 0 | 1"; return 1; }; clean="$v" ;;
      dns) valid_dns_list "$v" || { err "dns: IPv4 через запятую"; return 1; }; dns="$v" ;;
      endpoint) valid_ip "$v" || { err "endpoint: IPv4"; return 1; }; ep="$v" ;;
      client) [[ -z "$v" || "$v" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя клиента недопустимо"; return 1; }; first="$v" ;;
      *) err "Неизвестный параметр: $k"; return 1 ;;
    esac
  done
  [[ -n "$ep" ]] || ep=$(public_ip_cached)
  valid_ip "$ep" && ! ip_is_private "$ep" || { err "Публичный IPv4 не определился — задай endpoint="; return 1; }
  [[ -n "$port" ]] || port=$(random_free_udp_port) || { err "Нет свободного порта"; return 1; }
  _wgobf_prepare || return 1
  wg_port=$(random_free_udp_port "$port") || { err "Нет свободного порта для WireGuard"; return 1; }
  net=$(taken_networks | py pick-net) || { err "Нет свободной /24"; return 1; }
  priv=$(wg genkey)
  rm -f "$WGOBF_STATE"
  wgobf_set PORT "$port"; wgobf_set WG_PORT "$wg_port"; wgobf_set KEY "$(py rand-key 32)"
  wgobf_set MASKING "$mask"; wgobf_set ALLOW_CLEAN "$clean"; wgobf_set NET "$net"
  wgobf_set MTU "$WGOBF_MTU"; wgobf_set DNS "$dns"; wgobf_set ENDPOINT "$ep"
  wgobf_set SERVER_PUB "$(wg pubkey <<< "$priv")"
  write_file "$WGOBF_WG_CONF" 600 <<EOF
# AWG Toolza — WG + обфускатор. Снаружи порт закрыт, вход — через
# wg-obfuscator на $port/udp. Клиенты — блоки [Peer] с «# client=имя».
[Interface]
PrivateKey = $priv
Address = ${net%.*}.1/24
ListenPort = $wg_port
MTU = $WGOBF_MTU
PostUp = $WGOBF_FW up
PostDown = $WGOBF_FW down
EOF
  if ! wgobf_restart; then
    err "Запуск не удался — откатываю установку"
    _wgobf_teardown keep
    return 1
  fi
  ufw_allow "$port/udp" "$WGOBF_TAG"
  ok "WG + обфускатор запущен: вход $ep:$port/udp, подсеть $net"
  log_info "wgobf: установлен (порт $port, wg $wg_port, сеть $net, маскировка $mask)"
  [[ -z "$first" ]] || wgobf_add_client "$first"
}

_wgobf_teardown() {  # keep|drop — клиентские комплекты
  local port
  port=$(wgobf_get PORT)
  systemctl disable --now "$WGOBF_UNIT" "wg-quick@$WGOBF_IF" &>/dev/null || true
  ip link del dev "$WGOBF_IF" &>/dev/null || true
  wgobf_fw_run down
  [[ -n "$port" ]] && ufw_delete_matching "$WGOBF_TAG"
  remove_unit "$WGOBF_UNIT"
  rm -f "$WGOBF_WG_CONF" "$WGOBF_BIN" "$WGOBF_FW"
  rmdir "$WGOBF_LIB" 2>/dev/null || true
  rm -rf "$WGOBF_DIR"
  [[ "${1:-keep}" == drop ]] && rm -rf "$WGOBF_CLIENTS"
  return 0
}

# $1 = quiet — без вопроса (из полного удаления).
wgobf_remove() {
  local arch items=()
  wgobf_installed || { info "WG + обфускатор не установлен"; return 0; }
  if [[ "${1:-}" != quiet ]]; then
    warn "Будут удалены $WGOBF_IF, обфускатор, их правила и все клиенты режима. AWG не затрагивается."
    read_confirm "${R}  Подтверди удаление (введи yes): ${N}" || return 0
  fi
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  arch="$BACKUP_DIR/auto_wgobf_remove_$(date +%Y%m%d_%H%M%S).tar.gz"
  items=("$WGOBF_DIR" "$WGOBF_WG_CONF")
  [[ -d "$WGOBF_CLIENTS" ]] && items+=("$WGOBF_CLIENTS")
  tar -czf "$arch" "${items[@]}" 2>/dev/null && chmod 600 "$arch" && info "Архив на всякий случай: $arch"
  _wgobf_teardown drop
  ok "WG + обфускатор удалён"
  log_info "wgobf: удалён"
}

# Хуки wgobf0 — ровно «$WGOBF_FW up/down». Конфиг из бэкапа мог прийти
# чужой: прочее убирается, о командах не из Тулзы — предупреждение.
_wgobf_hooks_reset() {
  local bad
  bad=$(py conf-hooks "$WGOBF_WG_CONF" check "$WGOBF_FW up" "$WGOBF_FW down" 2>/dev/null) || true
  if [[ -n "$bad" ]]; then
    warn "В $WGOBF_IF.conf из бэкапа были чужие команды — заменены правилами Тулзы:"
    sed 's/^/    /; s/\t/ = /' <<< "$bad"
  fi
  sed -i -E '/^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=/Id' "$WGOBF_WG_CONF"
  # Заголовок секции — в канонический вид: awg-quick примет и « [interface]»
  # и CRLF, а вставка ниже ищет ровно «[Interface]» — иначе файрвол не встал бы
  sed -i -E 's/\r$//; s/^[[:space:]]*\[[[:space:]]*interface[[:space:]]*\][[:space:]]*$/[Interface]/I' "$WGOBF_WG_CONF"
  sed -i "0,/^\[Interface\]/s|^\[Interface\]|[Interface]\nPostUp = $WGOBF_FW up\nPostDown = $WGOBF_FW down|" "$WGOBF_WG_CONF"
  grep -qxF "PostUp = $WGOBF_FW up" "$WGOBF_WG_CONF" || { err "В $WGOBF_IF.conf из бэкапа нет секции [Interface]"; return 1; }
}

# Из папки бэкапа (<бэкап>/wgobf): ключи, настройки и клиенты — из бэкапа,
# служебные файлы — заново текущим кодом.
wgobf_restore() {
  local src="$1" port
  _wgobf_prepare || return 1
  wgobf_installed && _wgobf_teardown drop
  mkdir -p "$WGOBF_DIR" && chmod 700 "$WGOBF_DIR"
  # Из каталога настроек — только state: конфиг обфускатора и скрипт
  # файрвола wgobf_restart пишет из него заново.
  [[ -f "$src/etc/${WGOBF_STATE##*/}" ]] || { err "В бэкапе нет настроек обфускатора"; return 1; }
  install -m 600 "$src/etc/${WGOBF_STATE##*/}" "$WGOBF_STATE"
  install -m 600 "$src/$WGOBF_IF.conf" "$WGOBF_WG_CONF"
  # Хуки wgobf0 пишет только Тулза: чужие команды из бэкапа — прочь, свои — на место
  _wgobf_hooks_reset || return 1
  if [[ -d "$src/clients" ]]; then
    mkdir -p "$WGOBF_CLIENTS" && cp -a "$src/clients/." "$WGOBF_CLIENTS/" && chmod 700 "$WGOBF_CLIENTS"
  fi
  port=$(wgobf_get PORT)
  udp_listening "$port" && warn "UDP $port сейчас занят — обфускатор может не подняться"
  wgobf_restart || { err "WG + обфускатор восстановлен, но не запустился"; return 1; }
  ufw_allow "$port/udp" "$WGOBF_TAG"
  ok "WG + обфускатор восстановлен"
}

# ── Меню ──────────────────────────────────────────────────
wgobf_status() {
  local s
  if ip link show "$WGOBF_IF" &>/dev/null; then s="${G}● поднят${N}"; else s="${R}○ лежит${N}"; fi
  echo -e "  $WGOBF_IF         : $s"
  if unit_active "$WGOBF_UNIT"; then s="${G}● работает${N}"; else s="${R}○ не работает${N}"; fi
  echo -e "  wg-obfuscator  : $s ${D}($(wgobf_bin_version))${N}"
  echo -e "  Вход           : ${W}$(wgobf_get ENDPOINT):$(wgobf_get PORT)/udp${N}"
  echo -e "  Маскировка     : ${W}$(wgobf_get MASKING)${N} ${D}(у клиентов; сервер понимает любую)${N}"
  echo -e "  Без обфускатора: $([[ "$(wgobf_get ALLOW_CLEAN)" == 1 ]] && echo -e "${Y}да${N}" || echo нет)"
  echo -e "  Подсеть        : $(wgobf_get NET), MTU $(wgobf_get MTU), WireGuard на $(wgobf_get WG_PORT) ${D}(снаружи закрыт)${N}"
  echo -e "  Клиентов       : $(wgobf_clients | grep -c . || true)"
}

wgobf_settings() {
  local c mask clean
  mask=$(wgobf_get MASKING); clean=$(wgobf_get ALLOW_CLEAN)
  echo -e "  ${C}1)${N} Маскировка клиентов: ${W}$mask${N} → $([[ "$mask" == STUN ]] && echo NONE || echo STUN)"
  echo -e "  ${C}2)${N} Клиенты без обфускатора: ${W}$([[ "$clean" == 1 ]] && echo да || echo нет)${N} → $([[ "$clean" == 1 ]] && echo нет || echo да)"
  echo -e "  ${C}3)${N} Сменить ключ обфускатора"
  read_choice c "${C}  Выбор (0 — назад): ${N}" 0 3 0
  case "$c" in
    1) wgobf_set_masking "$([[ "$mask" == STUN ]] && echo NONE || echo STUN)" ;;
    2) wgobf_set_clean "$([[ "$clean" == 1 ]] && echo 0 || echo 1)" ;;
    3) warn "После смены ключа ВСЕ клиенты отключатся, пока не получат новый комплект"
       read_confirm "${R}  Сменить ключ? (введи yes): ${N}" && { wgobf_rotate_key || true; } ;;
  esac
  return 0
}

# Маскировка у клиентов: STUN|NONE. Сервер в режиме AUTO понимает обе.
wgobf_set_masking() {
  [[ "$1" =~ ^(STUN|NONE)$ ]] || { err "Маскировка: STUN | NONE"; return 1; }
  wgobf_set MASKING "$1"
  ok "Маскировка $1, комплекты перевыпущены: $(_wgobf_regen_bundles)"
  info "Старые комплекты продолжат работать"
}

wgobf_set_clean() {  # 1 — пускать клиентов без обфускатора
  [[ "$1" =~ ^[01]$ ]] || { err "0 | 1"; return 1; }
  wgobf_set ALLOW_CLEAN "$1"
  _wgobf_write_service_files && systemctl restart "$WGOBF_UNIT" &>/dev/null
  ok "Клиенты без обфускатора: $([[ "$1" == 1 ]] && echo да || echo нет), комплекты перевыпущены: $(_wgobf_regen_bundles)"
}

do_wgobf_menu() {
  local c name
  while true; do
    echo ""
    hdr "WG + обфускатор (wg-obfuscator $WGOBF_VERSION)"
    if ! wgobf_installed; then
      echo -e "  ${D}Отдельный WireGuard за обфускатором, AWG не трогает.${N}"
      echo -e "  ${C}1)${N} Установить"
      echo -e "  ${W}0)${N} ← Назад"
      read_choice c "${C}  Выбор [0-1]: ${N}" 0 1 0
      (( c )) || return 0
      wgobf_install || true
      pause
      continue
    fi
    if wgobf_running; then echo -e "  ${G}● работает${N}  ${D}вход $(wgobf_get ENDPOINT):$(wgobf_get PORT)/udp${N}"
    else echo -e "  ${R}○ не работает${N} ${D}— «Перезапустить»${N}"; fi
    echo ""
    echo -e "  ${C}1)${N} Добавить клиента"
    echo -e "  ${C}2)${N} Список"
    echo -e "  ${C}3)${N} Комплект клиента"
    echo -e "  ${C}4)${N} Удалить клиента"
    echo -e "  ${C}5)${N} Статус и журнал"
    echo -e "  ${C}6)${N} Перезапустить"
    echo -e "  ${C}7)${N} Настройки"
    echo -e "  ${R}8)${N} Удалить WG + обфускатор"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-8]: ${N}" 0 8 0
    case "$c" in
      1) read_line name "${C}  Имя клиента: ${N}"
         name="${name// /}"
         [[ -n "$name" ]] && { wgobf_add_client "$name" && wgobf_show_bundle "$name" || true; } ;;
      2) wgobf_list_clients || true ;;
      3) _wgobf_pick_client && { wgobf_show_bundle "$CHOSEN" || true; } ;;
      4) _wgobf_pick_client && read_confirm "${R}  Удалить клиента $CHOSEN? (введи yes): ${N}" \
           && { wgobf_delete_client "$CHOSEN" || true; } ;;
      5) wgobf_status; journalctl -u "$WGOBF_UNIT" -n 12 --no-pager 2>/dev/null | sed 's/^/  /' || true ;;
      6) wgobf_restart && ok "Перезапущено" || true ;;
      7) wgobf_settings || true ;;
      8) wgobf_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# awg2 --wgobf add ИМЯ | del ИМЯ | bundle ИМЯ | rotate-key | restart
wgobf_cli() {
  local cmd="${1:-}" name="${2:-}"
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  case "$cmd" in
    add|del|bundle) [[ -n "$name" ]] || { err "Использование: awg2 --wgobf $cmd ИМЯ"; return 1; } ;;
  esac
  case "$cmd" in
    add) wgobf_add_client "$name" ;;
    del) wgobf_delete_client "$name" ;;
    bundle) wgobf_clients | grep -qxF "$name" || { err "Клиента $name нет"; return 1; }
            wgobf_write_bundle "$name" && ok "$WGOBF_CLIENTS/$name" ;;
    rotate-key) wgobf_rotate_key ;;
    restart) wgobf_restart && ok "Перезапущено" ;;
    *) err "Команда: add ИМЯ | del ИМЯ | bundle ИМЯ | rotate-key | restart"; return 1 ;;
  esac
}
