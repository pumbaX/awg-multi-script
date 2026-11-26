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
#   DUMMY IDLE — max-dummy и idle-timeout основного профиля (пусто — 4 и 300)
#   P_<профиль>=ПОРТ|КЛЮЧ|МАСКИРОВКА|OBFB|DUMMY|IDLE — дополнительные профили
#   C_<клиент>=<профиль> — профиль комплекта клиента (нет — основной)
#   DEFP — профиль новых клиентов (пусто — основной)
#   IPV6=1, NET6 — IPv6 в туннеле: ULA /64, сервер ::1, клиент ::<номер в /24>
#
# Профиль обфускации — свой порт, ключ и маскировка; все профили ведут в тот
# же wgobf0. Основной — ClusterM v1.6 (маскировка STUN или NONE, чистый WG),
# служба awg-wgobf. Дополнительный — своя служба awg-wgobf-p-<профиль>:
# STUN/NONE без obfuscate-bytes — тоже ClusterM, MEDIA или obfuscate-bytes —
# форк из Phobos. Клиенту профиль задаёт только его комплект: сервер пускает
# через любой профиль, смена профиля старый комплект не ломает.

wgobf_installed() { [[ -f "$WGOBF_STATE" && -f "$WGOBF_WG_CONF" ]]; }
wgobf_get() { sed -n "s/^$1=//p" "$WGOBF_STATE" 2>/dev/null | head -1; }

wgobf_set() {
  mkdir -p "$WGOBF_DIR" && chmod 700 "$WGOBF_DIR"
  { grep -v "^$1=" "$WGOBF_STATE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } \
    | write_file "$WGOBF_STATE" 600
}

wgobf_unset() {
  [[ -f "$WGOBF_STATE" ]] || return 0
  grep -q "^$1=" "$WGOBF_STATE" || return 0
  { grep -v "^$1=" "$WGOBF_STATE" || true; } | write_file "$WGOBF_STATE" 600
}

# ── Профили обфускации ────────────────────────────────────
WGOBF_PRESET_RE='^[A-Za-z0-9_]{1,16}$'

# Дополнительные профили: только записи, прошедшие проверку (state мог прийти из бэкапа)
wgobf_presets() {
  local name
  while IFS= read -r name; do
    _wgobf_preset "$name" && echo "$name"
  done < <(sed -n 's/^P_\([A-Za-z0-9_]\{1,16\}\)=.*/\1/p' "$WGOBF_STATE" 2>/dev/null | awk '!seen[$0]++')
  return 0
}

# Профиль → PP_PORT PP_KEY PP_MASK PP_OBFB PP_DUMMY PP_IDLE и PP_EOBFB (obfuscate-bytes
# в конфигах); 1 — нет такого (или запись битая)
_wgobf_preset() {
  local name="$1" line
  if [[ "$name" == main ]]; then
    PP_PORT=$(wgobf_get PORT); PP_KEY=$(wgobf_get KEY); PP_MASK=$(wgobf_get MASKING); PP_OBFB=0
    PP_DUMMY=$(wgobf_get DUMMY); PP_IDLE=$(wgobf_get IDLE)
    [[ "$PP_DUMMY" =~ ^(0|[1-9][0-9]{0,3})$ ]] && (( PP_DUMMY <= 1024 )) || PP_DUMMY=4
    [[ "$PP_IDLE" =~ ^[1-9][0-9]{1,4}$ ]] && (( PP_IDLE <= 86400 )) || PP_IDLE=300
    [[ "$PP_MASK" =~ ^(STUN|NONE)$ ]] || PP_MASK=STUN
    PP_EOBFB=0
    return 0
  fi
  [[ "$name" =~ $WGOBF_PRESET_RE ]] || return 1
  line=$(wgobf_get "P_$name")
  [[ -n "$line" ]] || return 1
  IFS='|' read -r PP_PORT PP_KEY PP_MASK PP_OBFB PP_DUMMY PP_IDLE _ <<< "$line"
  _wgobf_preset_ok "$PP_PORT" "$PP_KEY" "$PP_MASK" "$PP_OBFB" "$PP_DUMMY" "$PP_IDLE" >/dev/null || return 1
  # Как в Phobos: obfuscate-bytes 0 у MEDIA — 16 (в конфигах — всегда явно)
  if [[ "$PP_MASK" == MEDIA ]] && (( PP_OBFB == 0 )); then PP_EOBFB=16; else PP_EOBFB="$PP_OBFB"; fi
}

# Проверка значений профиля; причина — в stdout
_wgobf_preset_ok() {  # порт ключ маскировка obfb dummy idle
  valid_port "$1" || { echo "порт — число 1-65535"; return 1; }
  [[ "$2" =~ ^[A-Za-z0-9]{16,255}$ ]] || { echo "ключ — 16-255 латинских букв и цифр"; return 1; }
  shift 2
  _wgobf_opts_ok "$@"
}

# Меняемые настройки профиля (порт и ключ основного — из его установки, их не проверяем)
_wgobf_opts_ok() {  # маскировка obfb dummy idle
  set -- "" "" "$@"           # номера аргументов — как в _wgobf_preset_ok
  [[ "$3" =~ ^(STUN|NONE|MEDIA)$ ]] || { echo "маскировка: STUN | NONE | MEDIA"; return 1; }
  # Без ведущих нулей: «016» bash счёл бы восьмеричным
  [[ "$4" =~ ^(0|[1-9][0-9]{0,3})$ ]] && (( $4 == 0 || ($4 >= 4 && $4 <= 1500) )) \
    || { echo "obfuscate-bytes: 0 (весь пакет) или 4-1500"; return 1; }
  [[ "$5" =~ ^(0|[1-9][0-9]{0,3})$ ]] && (( $5 <= 1024 )) || { echo "max-dummy: 0-1024"; return 1; }
  [[ "$6" =~ ^[1-9][0-9]{1,4}$ ]] && (( $6 <= 86400 )) || { echo "idle-timeout: 10-86400 секунд"; return 1; }
}

# Движок профиля: ClusterM — классический wg-obfuscator; phobos — форк с MEDIA и obfuscate-bytes
_wgobf_engine() {  # маскировка obfb
  if [[ "$1" == MEDIA ]] || (( ${2:-0} > 0 )); then echo phobos; else echo clusterm; fi
}

_wgobf_preset_unit() { echo "awg-wgobf-p-$1.service"; }
_wgobf_preset_conf() { echo "$WGOBF_DIR/p-$1.conf"; }
_wgobf_preset_tag() { echo "$WGOBF_TAG-p-$1"; }

wgobf_preset_exists() { [[ "$1" == main ]] || { [[ "$1" =~ $WGOBF_PRESET_RE ]] && _wgobf_preset "$1"; }; }

# Профиль клиента: заданный и существующий, иначе основной
wgobf_client_preset() {
  local p
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && p=$(wgobf_get "C_$1")
  if [[ -n "${p:-}" ]] && wgobf_preset_exists "$p"; then echo "$p"; else echo main; fi
}

# Профиль новых клиентов
wgobf_default_preset() {
  local p
  p=$(wgobf_get DEFP)
  if [[ -n "$p" ]] && wgobf_preset_exists "$p"; then echo "$p"; else echo main; fi
}

# Все порты обфускатора: основной и профилей
wgobf_ports() {
  local p
  wgobf_get PORT
  while IFS= read -r p; do _wgobf_preset "$p" && echo "$PP_PORT"; done < <(wgobf_presets)
}

# Порт закреплён за режимом, даже когда его службы остановлены.
wgobf_owns_port() {
  wgobf_installed || return 1
  [[ "$1" == "$(wgobf_get WG_PORT)" ]] && return 0
  grep -qxF -- "$1" <<< "$(wgobf_ports)"
}

wgobf_clients() { sed -n 's/^# client=//p' "$WGOBF_WG_CONF" 2>/dev/null || true; }
wgobf_bin_version() { "$WGOBF_BIN" --help 2>&1 | grep -oE 'Obfuscator v[0-9.]+' | head -1 | awk '{print $2}' || true; }
# Форк собран из закреплённого коммита — метка рядом с программой
wgobf_ph_ready() { [[ -x "$WGOBF_PH_BIN" && "$(cat "$WGOBF_PH_BIN.commit" 2>/dev/null)" == "$WGOBF_PH_COMMIT" ]]; }
wgobf_running() { unit_active "$WGOBF_UNIT" && ip link show "$WGOBF_IF" &>/dev/null; }

# Строка AllowedIPs пира клиента в wgobf0.conf: «10.x.y.z/32[, fd..::n/128]»
_wgobf_peer_allowed() {
  awk -v t="# client=$1" '$0 == t {f = 1; next} f && /^\[/ {exit}
    f && /^AllowedIPs[ \t]*=/ {sub(/^AllowedIPs[ \t]*=[ \t]*/, ""); print; exit}' "$WGOBF_WG_CONF" 2>/dev/null
}

wgobf_client_pub() {
  awk -v t="# client=$1" '$0 == t {f = 1; next} f && /^\[/ {exit}
    f && /^PublicKey[ \t]*=/ {sub(/^PublicKey[ \t]*=[ \t]*/, ""); print; exit}' "$WGOBF_WG_CONF" 2>/dev/null
}

# ── Правила iptables (PostUp / PostDown wgobf0) ───────────
# MASQUERADE через «! -o wgobf0», а не по имени аплинка: переименование
# интерфейса у хостера после перезагрузки ничего не ломает.
wgobf_fw_run() {
  local t net wg_port
  for t in filter nat; do ipt_del_tagged "$t" "$WGOBF_TAG"; ip6t_del_tagged "$t" "$WGOBF_TAG"; done
  [[ "${1:-}" == up ]] || return 0
  net=$(wgobf_get NET); wg_port=$(wgobf_get WG_PORT)
  [[ -n "$net" && -n "$wg_port" ]] || { echo "wgobf-fw: в $WGOBF_STATE нет NET/WG_PORT" >&2; return 1; }
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s "$net" ! -o "$WGOBF_IF" -j MASQUERADE -m comment --comment "$WGOBF_TAG" || return 1
  iptables -I FORWARD 1 -i "$WGOBF_IF" -j ACCEPT -m comment --comment "$WGOBF_TAG" || return 1
  iptables -I FORWARD 1 -o "$WGOBF_IF" -j ACCEPT -m comment --comment "$WGOBF_TAG" || return 1
  # Порт WireGuard — только для обфускатора, который ходит через lo. WireGuard
  # слушает и IPv6 — там он тоже закрыт (нет ip6tables — нет и правила)
  iptables -I INPUT 1 -p udp --dport "$wg_port" ! -i lo -j DROP -m comment --comment "$WGOBF_TAG" || return 1
  if command -v ip6tables &>/dev/null; then
    ip6tables -I INPUT 1 -p udp --dport "$wg_port" ! -i lo -j DROP -m comment --comment "$WGOBF_TAG" 2>/dev/null \
      || echo "wgobf-fw: ip6tables: порт WireGuard по IPv6 не закрыт" >&2
  fi
  # IPv6 клиентов — не повод не поднять wgobf0: без этих правил у них не будет только IPv6
  if [[ "$(wgobf_get IPV6)" == 1 ]] && ! wgobf_fw6_up; then
    echo "wgobf-fw: правила IPv6 не встали — у клиентов работает только IPv4" >&2
  fi
  return 0
}

# IPv6 в туннеле: NAT66 за адрес сервера, к клиентам — только ответы.
# Включённая пересылка IPv6 выключает приём RA на интерфейсах с accept_ra=1 —
# сервер с адресом по SLAAC потерял бы свой IPv6: на аплинке — accept_ra=2.
wgobf_fw6_up() {
  local net6 dev p
  net6=$(wgobf_get NET6)
  [[ "$net6" =~ ^fd[0-9a-f]{2}(:[0-9a-f]{1,4}){3}::/64$ ]] || { echo "wgobf-fw: в $WGOBF_STATE нет NET6" >&2; return 1; }
  command -v ip6tables &>/dev/null || { echo "wgobf-fw: нет ip6tables" >&2; return 1; }
  for dev in $(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u); do
    [[ "$dev" =~ ^[A-Za-z0-9_@-]{1,15}$ ]] || continue
    [[ "$(sysctl -n "net.ipv6.conf.$dev.accept_ra" 2>/dev/null)" == 1 ]] \
      && sysctl -qw "net.ipv6.conf.$dev.accept_ra=2" 2>/dev/null
  done
  sysctl -qw net.ipv6.conf.all.forwarding=1 2>/dev/null || { echo "wgobf-fw: пересылка IPv6 не включилась" >&2; return 1; }
  ip6tables -t nat -A POSTROUTING -s "$net6" ! -o "$WGOBF_IF" -j MASQUERADE -m comment --comment "$WGOBF_TAG" || return 1
  ip6tables -I FORWARD 1 -i "$WGOBF_IF" -j ACCEPT -m comment --comment "$WGOBF_TAG" || return 1
  ip6tables -I FORWARD 1 -o "$WGOBF_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT \
    -m comment --comment "$WGOBF_TAG" || return 1
  # DNS у клиентов — адреса IPv4 (их перехватывает шифрованный DNS Тулзы); DNS и
  # DoT по IPv6 шли бы мимо него — отказ сразу, система спросит по IPv4
  for p in "udp 53" "tcp 53" "tcp 853" "udp 853"; do
    ip6tables -I FORWARD 1 -i "$WGOBF_IF" -p "${p% *}" --dport "${p#* }" -j REJECT \
      -m comment --comment "$WGOBF_TAG" || return 1
  done
  wgobf_fw6_routes
}

# Адрес IPv6 клиента по его IPv4: ::<номер в /24, шестнадцатерично>
wgobf_v6_of() {  # 10.x.y.N → fd..::n
  local net6
  net6=$(wgobf_get NET6)
  [[ -n "$net6" && "$1" =~ \.([0-9]{1,3})$ ]] || return 1
  printf '%s%x\n' "${net6%/64}" "${BASH_REMATCH[1]}"
}

# Клиенты в туннелях (WARP, Xray, exit-ноды) — без IPv6: туннели ведут только
# IPv4, иначе сайты по IPv6 видели бы адрес сервера. Отказ сразу (ICMP) —
# приложение переходит на IPv4 без ожидания.
wgobf_fw6_routes() {
  local f line ip6
  ip6t_del_tagged filter "$WGOBF_TAG-v6r"
  [[ "$(wgobf_get IPV6)" == 1 ]] && command -v ip6tables &>/dev/null || return 0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      line="${line//[[:space:]]/}"
      valid_ip "${line%%|*}" && ip6=$(wgobf_v6_of "${line%%|*}") || continue
      ip6tables -I FORWARD 1 -i "$WGOBF_IF" -s "$ip6" -j REJECT --reject-with icmp6-adm-prohibited \
        -m comment --comment "$WGOBF_TAG-v6r" 2>/dev/null || echo "wgobf-fw: правило IPv6 для $ip6 не встало" >&2
    done < "$f"
  done < <(wgobf_route_files)
  return 0
}

# Ubuntu 25.10+ держит wg-quick в профиле AppArmor: хуки PostUp/PostDown
# запускают только его список (ip, iptables, sysctl…), скрипт правил wgobf0 —
# «Permission denied», и wgobf0 не поднимается. Разрешение — штатным путём, в
# дополнении профиля local/wg-quick, своим блоком (чужие строки не трогаем);
# профиль перечитывается, только если блок изменился. drop — убрать блок.
WGOBF_AA_BEGIN="# awg2-wgobf: begin — правила wgobf0 (AWG Toolza)"
WGOBF_AA_END="# awg2-wgobf: end"
_wgobf_apparmor() {  # [drop]
  local prof="$WGOBF_AA_DIR/wg-quick" loc="$WGOBF_AA_DIR/local/wg-quick" tmp
  [[ -f "$prof" ]] || return 0
  if [[ "${1:-}" == drop ]]; then
    [[ -f "$loc" ]] || return 0
  elif ! grep -q 'local/wg-quick' "$prof"; then
    warn "Профиль AppArmor $prof без local/wg-quick — правила $WGOBF_IF могут не запуститься"
    return 0
  fi
  mktmp tmp || return 1
  awk -v b="$WGOBF_AA_BEGIN" -v e="$WGOBF_AA_END" '$0 == b {s = 1; next} $0 == e {s = 0; next} !s' \
    "$loc" > "$tmp" 2>/dev/null || true
  [[ "${1:-}" == drop ]] || printf '%s\nfile PUx %s,\n%s\n' "$WGOBF_AA_BEGIN" "$WGOBF_FW" "$WGOBF_AA_END" >> "$tmp"
  cmp -s "$tmp" "$loc" && return 0
  install -D -m 644 "$tmp" "$loc" || return 1
  if ! apparmor_parser -r "$prof" &>/dev/null; then
    warn "AppArmor: профиль wg-quick не перечитался — правила $WGOBF_IF могут не запуститься"
    return 0
  fi
  [[ "${1:-}" == drop ]] || info "AppArmor: хукам $WGOBF_IF разрешён скрипт правил ($loc)"
  return 0
}

# Секция серверного конфига профиля (main — основной)
_wgobf_server_section() {  # профиль
  _wgobf_preset "$1" || return 1
  echo "[$1]"
  echo "source-if = 0.0.0.0"
  echo "source-lport = $PP_PORT"
  echo "target = 127.0.0.1:$(wgobf_get WG_PORT)"
  echo "key = $PP_KEY"
  # AUTO: сервер понимает и STUN, и голый XOR — режим выбирает клиент. MEDIA —
  # явно, obfuscate-bytes — после неё: у форка MEDIA ставит 16, только если
  # obfuscate-bytes ещё 0, и от порядка строк зависело бы, сойдутся ли стороны
  if [[ "$PP_MASK" == MEDIA ]]; then echo "masking = MEDIA"; else echo "masking = AUTO"; fi
  [[ "$(_wgobf_engine "$PP_MASK" "$PP_OBFB")" == phobos ]] && echo "obfuscate-bytes = $PP_EOBFB"
  [[ "$1" == main && "$(wgobf_get ALLOW_CLEAN)" == 1 ]] && echo "allow-clean = true"
  echo "max-dummy = $PP_DUMMY"
  echo "idle-timeout = $PP_IDLE"
  echo "verbose = INFO"
}

_wgobf_unit_text() {  # описание программа конфиг
  cat <<EOF
[Unit]
Description=$1
After=network-online.target wg-quick@$WGOBF_IF.service
Wants=network-online.target

[Service]
ExecStart=$2 -c $3
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

# Скрипт правил wgobf0 (хуки PostUp/PostDown) — работает и без awg2
_wgobf_emit_fw() {
  emit_script "$WGOBF_FW" 'wgobf_fw_run "$@"' WGOBF_STATE WGOBF_TAG WGOBF_IF WARP_PEERS XRAY_PEERS EXITS_PEERS \
    ipt_del_grep ipt_del_tagged ip6t_del_tagged valid_ip wgobf_get wgobf_route_files wgobf_v6_of \
    wgobf_fw6_routes wgobf_fw6_up wgobf_fw_run
}

_wgobf_write_service_files() {
  local p f bin
  _wgobf_emit_fw || return 1
  _wgobf_apparmor || true
  { echo "# AWG Toolza — серверный wg-obfuscator для $WGOBF_IF. Перезаписывается awg2."
    _wgobf_server_section main; } | write_file "$WGOBF_OBF_CONF" 600 || return 1
  _wgobf_unit_text "AWG Toolza — wg-obfuscator для $WGOBF_IF" "$WGOBF_BIN" "$WGOBF_OBF_CONF" | write_unit "$WGOBF_UNIT"
  while IFS= read -r p; do
    _wgobf_preset "$p" || continue
    if [[ "$(_wgobf_engine "$PP_MASK" "$PP_OBFB")" == phobos ]]; then bin="$WGOBF_PH_BIN"; else bin="$WGOBF_BIN"; fi
    { echo "# AWG Toolza — профиль обфускации $p для $WGOBF_IF. Перезаписывается awg2."
      _wgobf_server_section "$p"; } | write_file "$(_wgobf_preset_conf "$p")" 600 || return 1
    _wgobf_unit_text "AWG Toolza — обфускатор $WGOBF_IF, профиль $p" "$bin" "$(_wgobf_preset_conf "$p")" \
      | write_unit "$(_wgobf_preset_unit "$p")"
  done < <(wgobf_presets)
  # Профиля больше нет — его служба и конфиг прочь
  for f in "$WGOBF_DIR"/p-*.conf; do
    [[ -f "$f" ]] || continue
    p="${f##*/p-}"; p="${p%.conf}"
    grep -qxF -- "$p" <<< "$(wgobf_presets)" || _wgobf_preset_drop_unit "$p"
  done
  return 0
}

_wgobf_preset_drop_unit() {  # профиль
  [[ "$1" =~ $WGOBF_PRESET_RE ]] || return 0
  remove_unit "$(_wgobf_preset_unit "$1")"
  rm -f "$(_wgobf_preset_conf "$1")"
}

_wgobf_journal() { journalctl -u "$1" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'; }

# Запустить (перезапустить) обфускатор одного профиля
_wgobf_preset_start() {  # профиль
  local u
  if [[ "$1" == main ]]; then u="$WGOBF_UNIT"; else u=$(_wgobf_preset_unit "$1"); fi
  systemctl enable "$u" &>/dev/null || true
  systemctl restart "$u" &>/dev/null
  sleep 1
  unit_active "$u" && return 0
  if [[ "$1" == main ]]; then err "wg-obfuscator не запустился:"; else err "Обфускатор профиля $1 не запустился:"; fi
  _wgobf_journal "$u"
  return 1
}

wgobf_start() {
  local out p rc=0
  systemctl enable "wg-quick@$WGOBF_IF" &>/dev/null || true
  if ! out=$(systemctl restart "wg-quick@$WGOBF_IF" 2>&1) || ! ip link show "$WGOBF_IF" &>/dev/null; then
    err "$WGOBF_IF не поднялся"
    [[ -n "$out" ]] && sed 's/^/    /' <<< "$out"
    _wgobf_journal "wg-quick@$WGOBF_IF"
    return 1
  fi
  _wgobf_preset_start main || return 1
  while IFS= read -r p; do _wgobf_preset_start "$p" || rc=1; done < <(wgobf_presets)
  return "$rc"
}

# Нужен ли форк Phobos: хоть один профиль с MEDIA или obfuscate-bytes
_wgobf_need_ph() {
  local p
  while IFS= read -r p; do
    _wgobf_preset "$p" && [[ "$(_wgobf_engine "$PP_MASK" "$PP_OBFB")" == phobos ]] && return 0
  done < <(wgobf_presets)
  return 1
}

_wgobf_ph_prepare() {
  wgobf_ph_ready && return 0
  need_cmds git:git make:make gcc:gcc || return 1
  run_step "Сборка обфускатора Phobos $WGOBF_PH_VERSION" _wgobf_ph_build
}

wgobf_restart() {
  if _wgobf_need_ph && ! _wgobf_ph_prepare; then
    warn "Обфускатор Phobos не собрался — профили с MEDIA и obfuscate-bytes не заработают"
  fi
  _wgobf_write_service_files && wgobf_start
}

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

# Форк из Phobos: из большого репозитория — только каталог обфускатора (без
# готовых программ bin/) закреплённого коммита; коммит по SHA подделать нельзя.
# Старый git без частичного клона (--filter) скачает коммит целиком.
_wgobf_ph_fetch() {  # каталог
  local d="$1"
  git init -q "$d" && git -C "$d" remote add origin "$WGOBF_PH_REPO" \
    && git -C "$d" config core.sparseCheckout true \
    && printf '%s/\n!%s/bin/\n' "$WGOBF_PH_SRC" "$WGOBF_PH_SRC" > "$d/.git/info/sparse-checkout" || return 1
  git -C "$d" fetch -q --depth 1 --filter=blob:none origin "$WGOBF_PH_COMMIT" 2>/dev/null \
    || git -C "$d" fetch -q --depth 1 origin "$WGOBF_PH_COMMIT" || return 1
  git -C "$d" -c advice.detachedHead=false checkout -q FETCH_HEAD \
    && [[ "$(git -C "$d" rev-parse HEAD)" == "$WGOBF_PH_COMMIT" && -f "$d/$WGOBF_PH_SRC/Makefile" ]]
}

_wgobf_ph_build() {
  local src
  src=$(mktemp -d /tmp/awg2.wgobfph.XXXXXX) || return 1
  if _wgobf_ph_fetch "$src/s" \
     && make -C "$src/s/$WGOBF_PH_SRC" RELEASE=1 \
     && install -D -m 755 "$src/s/$WGOBF_PH_SRC/wg-obfuscator" "$WGOBF_PH_BIN.new" \
     && mv -f "$WGOBF_PH_BIN.new" "$WGOBF_PH_BIN" \
     && echo "$WGOBF_PH_COMMIT" > "$WGOBF_PH_BIN.commit"; then
    rm -rf "$src"; return 0
  fi
  echo "сборка не удалась (коммит $WGOBF_PH_COMMIT из $WGOBF_PH_REPO)"
  rm -rf "$src" "$WGOBF_PH_BIN.new"
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
  if [[ "$(wgobf_bin_version)" != "$WGOBF_VERSION" ]]; then
    run_step "Сборка wg-obfuscator $WGOBF_VERSION" _wgobf_build || return 1
  fi
  # Профили с MEDIA (из бэкапа) — без форка они не поднимутся, основной — да
  if _wgobf_need_ph && ! _wgobf_ph_prepare; then
    warn "Обфускатор Phobos не собрался — профили с MEDIA и obfuscate-bytes не заработают"
  fi
  return 0
}

# ── Комплект клиента ──────────────────────────────────────
# /root/wgobf/<имя>/. Ключи берутся из уже выпущенного wg.conf, адреса — из
# пира в wgobf0.conf, поэтому комплект можно перевыпустить после смены
# настроек, профиля или IPv6, не трогая ключи.
wgobf_write_bundle() {  # имя [приватный ключ psk]
  local name="$1" priv="${2:-}" psk="${3:-}" dir="$WGOBF_CLIENTS/$1"
  local ep preset eng mtu dns srv allowed addr
  if [[ -z "$priv" ]]; then
    priv=$(sed -n 's/^PrivateKey = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    psk=$(sed -n 's/^PresharedKey = //p' "$dir/wg.conf" 2>/dev/null | head -1)
    [[ -n "$priv" ]] || { err "Нет ключей клиента $name в $dir/wg.conf"; return 1; }
  fi
  addr=$(_wgobf_peer_allowed "$name")
  [[ -n "$addr" ]] || { err "Клиента $name нет в $WGOBF_IF.conf"; return 1; }
  preset=$(wgobf_client_preset "$name")
  _wgobf_preset "$preset" || { err "Профиль $preset недоступен"; return 1; }
  eng=$(_wgobf_engine "$PP_MASK" "$PP_OBFB")
  ep=$(wgobf_get ENDPOINT); mtu=$(wgobf_get MTU); dns=$(wgobf_get DNS); srv=$(wgobf_get SERVER_PUB)
  # «Весь интернет, кроме сервера»: пакеты обфускатора к серверу иначе
  # уйдут в сам туннель
  allowed=$(py allowed-except "$ep") || return 1
  mkdir -p "$dir" && chmod 700 "$WGOBF_CLIENTS" "$dir"
  # Локальный порт обфускатора у клиента = порт профиля на сервере: у клиента
  # с несколькими такими серверами (и профилями) порты не столкнутся
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = %s\nMTU = %s\n\n[Peer]\nPublicKey = %s\n' \
      "$priv" "$addr" "$dns" "$mtu" "$srv"
    [[ -z "$psk" ]] || printf 'PresharedKey = %s\n' "$psk"
    printf 'Endpoint = 127.0.0.1:%s\nAllowedIPs = %s\nPersistentKeepalive = 25\n' "$PP_PORT" "$allowed"
  } | write_file "$dir/wg.conf" 600 || return 1
  { echo "[main]"; _wgobf_client_instance "$ep"; } | write_file "$dir/obfuscator.conf" 600 || return 1
  rm -f "$dir/wg-direct.conf"
  # Чистый WireGuard — через порт основного профиля (allow-clean есть только там)
  if [[ "$(wgobf_get ALLOW_CLEAN)" == 1 ]]; then
    sed -e "s|^Endpoint = .*|Endpoint = $ep:$(wgobf_get PORT)|" -e 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, ::/0|' \
      "$dir/wg.conf" | write_file "$dir/wg-direct.conf" 600
  fi
  # Формат Phobos: wg.conf + [instance] со всеми обязательными полями
  { cat "$dir/wg.conf"; printf '\n[instance]\n'; _wgobf_client_instance "$ep" phobos; } | write_file "$dir/phobos.conf" 600
  py phobos-link "$dir/phobos.conf" "$name" | write_file "$dir/phobos-link.txt" 600
  _wgobf_write_keenetic "$name" "$dir" "$preset" "$eng"
  _wgobf_write_readme "$name" "$dir" "$preset" "$eng"
  _wgobf_write_installer "$name" "$dir" "$preset" "$eng"
  echo "$WGOBF_BUNDLE_V" | write_file "$dir/.v" 600
}

# Клиентская сторона обфускатора (после _wgobf_preset): для obfuscator.conf и
# секции [instance]. Порядок полей Phobos: source-if … masking, verbose,
# idle-timeout, max-dummy; obfuscate-bytes — сразу после masking.
_wgobf_client_instance() {  # адрес сервера [phobos]
  echo "source-if = 127.0.0.1"
  echo "source-lport = $PP_PORT"
  echo "target = $1:$PP_PORT"
  echo "key = $PP_KEY"
  echo "masking = $PP_MASK"
  [[ "$(_wgobf_engine "$PP_MASK" "$PP_OBFB")" == phobos ]] && echo "obfuscate-bytes = $PP_EOBFB"
  if [[ "${2:-}" == phobos ]]; then
    echo "verbose = INFO"; echo "idle-timeout = $PP_IDLE"; echo "max-dummy = $PP_DUMMY"
  else
    echo "max-dummy = $PP_DUMMY"; echo "idle-timeout = $PP_IDLE"; echo "verbose = INFO"
  fi
}

# Комплект старого формата (или его нет) — собрать заново
wgobf_bundle_fresh() {  # имя
  local dir="$WGOBF_CLIENTS/$1"
  [[ -f "$dir/phobos-link.txt" && -f "$dir/keenetic.txt" && "$(cat "$dir/.v" 2>/dev/null)" == "$WGOBF_BUNDLE_V" ]] \
    || wgobf_write_bundle "$1"
}

_wgobf_preset_label() {  # профиль → «основной» | «профиль X»
  if [[ "$1" == main ]]; then echo "основной профиль"; else echo "профиль $1"; fi
}

_wgobf_write_keenetic() {
  local name="$1" dir="$2" preset="$3" eng="$4"
  {
    echo "Keenetic + AWG Manager — клиент $name ($(_wgobf_preset_label "$preset"): $PP_MASK)"
    echo ""
    echo "Способ 1 — ссылкой установки, в ВЕРХНЕЕ поле."
    echo "Бот или панель Тулзы: карточка клиента → «Ссылка установки». AWG Manager → Новый"
    echo "туннель → «Phobos» → поле «Ссылка установки Phobos». Ссылка срабатывает один раз."
    echo ""
    echo "Способ 2 — вкладка «Phobos», одной вставкой в НИЖНЕЕ поле."
    echo "AWG Manager → Новый туннель → «Phobos» → поле «Или конфиг .conf с секцией"
    echo "[instance] / ссылка phobos://» → ссылка из phobos-link.txt (или phobos.conf)."
    if [[ "$eng" == clusterm ]]; then
      echo "Во вкладке «Обфускатор» НЕ включать obfuscate-bytes и MEDIA: этот профиль"
      echo "сервера их не понимает, связь пропадёт. MEDIA — в отдельном профиле обфускации."
      echo ""
      echo "Способ 3 — вкладка «ClusterM», поля руками:"
      echo "Сервер (host:port) обфускатора: $(wgobf_get ENDPOINT):$PP_PORT"
      echo "Ключ:                          $PP_KEY"
      echo "Маскировка:                    $PP_MASK"
      echo "max-dummy:                     $PP_DUMMY"
      echo "idle-timeout:                  $PP_IDLE"
      echo ""
      echo "Конфиг WireGuard (.conf) — всё от [Interface] до конца:"
      echo ""
      cat "$dir/wg.conf"
    else
      echo "Профиль с $([[ "$PP_MASK" == MEDIA ]] && echo "маскировкой MEDIA" || echo "obfuscate-bytes") — только вкладка «Phobos»:"
      echo "у ClusterM этих настроек нет. obfuscate-bytes = $PP_EOBFB уже в ссылке, менять не нужно."
    fi
  } | write_file "$dir/keenetic.txt" 600
}

_wgobf_write_readme() {
  local name="$1" dir="$2" preset="$3" eng="$4"
  {
    echo "WG + обфускатор — клиент $name"
    echo "Сервер: $(wgobf_get ENDPOINT):$PP_PORT (UDP), $(_wgobf_preset_label "$preset"), маскировка: $PP_MASK"
    [[ "$eng" == clusterm ]] || echo "obfuscate-bytes: $PP_EOBFB — нужен обфускатор Phobos (форк wg-obfuscator), не ClusterM"
    echo ""
    echo "Файлы:"
    echo "  wg.conf          — WireGuard (Endpoint 127.0.0.1 — там слушает обфускатор)"
    if [[ "$eng" == clusterm ]]; then echo "  obfuscator.conf  — wg-obfuscator $WGOBF_VERSION (или обфускатор Phobos)"
    else echo "  obfuscator.conf  — обфускатор Phobos $WGOBF_PH_VERSION"; fi
    echo "  install-linux.sh — всё на Debian/Ubuntu одной командой"
    echo "  keenetic.txt     — AWG Manager на Keenetic"
    echo "  phobos.conf      — формат Phobos (wg.conf + [instance])"
    echo "  phobos-link.txt  — то же ссылкой phobos://"
    [[ -f "$dir/wg-direct.conf" ]] && echo "  wg-direct.conf   — БЕЗ обфускатора (телефоны); DPI видит его как WireGuard"
    echo ""
    echo "Linux (Debian/Ubuntu): sudo bash install-linux.sh (компьютер или ноутбук, не VPN-сервер)"
    echo ""
    echo "Windows, Android: приложение Phobos (github.com/Ground-Zerro/Phobos, папки windows и mobil)"
    echo "  — импорт ссылки из phobos-link.txt."
    if [[ "$eng" == clusterm ]]; then
      echo "Или wg-obfuscator $WGOBF_VERSION (Windows, macOS):"
      echo "  1. https://github.com/ClusterM/wg-obfuscator/releases/tag/$WGOBF_VERSION"
      echo "  2. wg-obfuscator -c obfuscator.conf (окно не закрывать)"
      echo "  3. wg.conf — в приложение WireGuard"
      echo ""
      echo "OpenWrt: https://github.com/ClusterM/wg-obfuscator/blob/master/docs/OPENWRT.md"
    else
      echo "Или обфускатор Phobos из исходников (macOS, другие Linux):"
      echo "  https://github.com/Ground-Zerro/Phobos/tree/$WGOBF_PH_COMMIT/$WGOBF_PH_SRC"
      echo "  make, затем ./wg-obfuscator -c obfuscator.conf; wg.conf — в приложение WireGuard"
      echo ""
      echo "OpenWrt: готовые программы под роутеры — в bin/ того же каталога; ставятся вручную"
      echo "  (как wg-obfuscator в https://github.com/ClusterM/wg-obfuscator/blob/master/docs/OPENWRT.md)."
    fi
    echo "Android без приложения Phobos: https://github.com/ClusterM/wg-obfuscator-android + WireGuard"
    [[ "$eng" == clusterm ]] || echo "  (только для профилей без MEDIA и obfuscate-bytes — этому не подойдёт)."
    echo "iOS обфускатор не поддерживает."
  } | write_file "$dir/README.txt" 600
}

# Ответы на входящие подключения клиента Linux — мимо туннеля. Туннель берёт
# «весь интернет, кроме сервера» маршрутами в main, и ответ SSH ушёл бы в него:
# сессия рвётся, на сервере — пропадает доступ. С адресов аплинка — своя таблица
# с прежним шлюзом и сетями аплинка; исходящие (адрес не выбран) — в туннель.
# Служба — после wg-quick: её правило встаёт раньше правил wg-quick для ::/0.
_wgobf_keep_script() {
  cat <<'EOF'
#!/bin/bash
# AWG Toolza: ответы на входящие подключения (SSH и др.) — прежним путём, мимо туннеля
T=51819
down() {
  local f i
  for f in -4 -6; do
    for i in $(seq 64); do ip "$f" rule del table "$T" 2>/dev/null || break; done
    ip "$f" route flush table "$T" 2>/dev/null || true
  done
}
up() {
  local f r dev via a
  down
  for f in -4 -6; do
    r=$(ip "$f" route show table main default 2>/dev/null | head -1)
    dev=$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' <<< "$r")
    via=$(awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}' <<< "$r")
    [[ -n "$dev" ]] || continue
    if [[ "$f" == -4 ]]; then
      ip -4 route show table main dev "$dev" scope link 2>/dev/null | awk '{print $1}'
    else
      ip -6 route show table main dev "$dev" 2>/dev/null | awk '$1 != "default" && !/ via / {print $1}'
    fi | while read -r a; do ip "$f" route replace "$a" dev "$dev" table "$T" 2>/dev/null || true; done
    if [[ "$f" == -4 ]]; then
      ip -4 route replace default ${via:+via "$via" onlink} dev "$dev" table "$T" 2>/dev/null || continue
    else
      ip -6 route replace default ${via:+via "$via"} dev "$dev" table "$T" 2>/dev/null || continue
    fi
    for a in $(ip "$f" -o addr show dev "$dev" scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'); do
      ip "$f" rule add from "$a" table "$T" 2>/dev/null || true
    done
  done
}
case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "keep-in.sh up|down"; exit 1 ;;
esac
exit 0
EOF
}

# Самостоятельный установщик клиента для Debian/Ubuntu: собирает обфускатор
# профиля (ClusterM или форк Phobos) из закреплённого коммита, кладёт конфиги
# и включает автозапуск. Тело — в функции: bash читает скрипт целиком до
# запуска (и из канала: «cat … | sudo bash»), и apt не съест его остаток со stdin.
# На сервере AWG Toolza не ставится: туннель увёл бы и его клиентов.
_wgobf_write_installer() {
  local name="$1" dir="$2" preset="$3" eng="$4" ep
  ep=$(wgobf_get ENDPOINT)
  {
    cat <<EOF
#!/bin/bash
# AWG Toolza — VPN-клиент «WG + обфускатор» ($name, $(_wgobf_preset_label "$preset")) для Debian/Ubuntu.
# Ставится на устройство, которому нужен VPN (компьютер, ноутбук, Linux-роутер): весь его
# интернет пойдёт через сервер $ep. Входящие подключения (SSH и др.) — прежним путём.
# Установка: sudo bash install-linux.sh
# Удаление:  sudo bash install-linux.sh --remove   (или sudo bash /usr/local/lib/wgobf-$name/uninstall.sh)
set -euo pipefail
main() {
[[ \$EUID -eq 0 ]] || { echo "Запусти от root: sudo bash"; exit 1; }
TAG="wgobf-$name"; SERVER="$ep"
LIB="/usr/local/lib/\$TAG"; CONF_DIR="/etc/\$TAG"; UNIT="\$TAG-obfuscator.service"; KEEP="\$TAG-keep.service"
WG_IF="\$TAG"; [[ \${#WG_IF} -le 15 ]] || WG_IF="wgobf-cli"
EOF
    cat <<'EOF'
uninstall() {
  systemctl disable --now "wg-quick@$WG_IF" "$KEEP" "$UNIT" 2>/dev/null || true
  rm -rf "/etc/systemd/system/$UNIT" "/etc/systemd/system/$KEEP" "/etc/wireguard/$WG_IF.conf" "$LIB" "$CONF_DIR"
  systemctl daemon-reload
  echo "Клиент $TAG удалён"
}
if [[ "${1:-}" == --remove ]]; then uninstall; exit 0; fi

EOF
    cat <<EOF
if [[ -f "$SERVER_CONF" || -f "$WGOBF_WG_CONF" ]]; then
  echo "Здесь стоит сервер AWG Toolza — клиент сюда не ставится: туннель увёл бы через"
  echo "другой сервер весь трафик этой машины и её VPN-клиентов."
  echo "Клиент — для устройства, которому нужен VPN: компьютер, ноутбук, Linux-роутер."
  echo "Связать два сервера — awg2 → Туннели → Exit-ноды."
  exit 1
fi
command -v apt-get >/dev/null || { echo "Нужен Debian/Ubuntu. На другой системе — см. README.txt"; exit 1; }
echo "VPN-клиент «$name»: весь интернет этого устройства пойдёт через сервер \$SERVER."
echo "Входящие подключения (SSH и др.) останутся прежним путём."
need=()
for b in wg:wireguard-tools wg-quick:wireguard-tools git:git make:make gcc:gcc; do
  command -v "\${b%%:*}" >/dev/null || need+=("\${b#*:}")
done
if (( \${#need[@]} )); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q </dev/null
  apt-get install -y -q \$(printf '%s\n' "\${need[@]}" | sort -u) </dev/null
fi

src=\$(mktemp -d); trap 'rm -rf "\$src"' EXIT
EOF
    if [[ "$eng" == clusterm ]]; then
      cat <<EOF
echo "Сборка wg-obfuscator $WGOBF_VERSION…"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$WGOBF_VERSION" "$WGOBF_REPO" "\$src/s"
[[ "\$(git -C "\$src/s" rev-parse HEAD)" == "$WGOBF_COMMIT" ]] || { echo "Коммит тега $WGOBF_VERSION не совпал — сборка остановлена"; exit 1; }
build="\$src/s"
EOF
    else
      cat <<EOF
echo "Сборка обфускатора Phobos $WGOBF_PH_VERSION…"
git init -q "\$src/s"
git -C "\$src/s" remote add origin "$WGOBF_PH_REPO"
git -C "\$src/s" config core.sparseCheckout true
printf '%s/\n!%s/bin/\n' "$WGOBF_PH_SRC" "$WGOBF_PH_SRC" > "\$src/s/.git/info/sparse-checkout"
git -C "\$src/s" fetch -q --depth 1 --filter=blob:none origin "$WGOBF_PH_COMMIT" 2>/dev/null \\
  || git -C "\$src/s" fetch -q --depth 1 origin "$WGOBF_PH_COMMIT"
git -C "\$src/s" -c advice.detachedHead=false checkout -q FETCH_HEAD
[[ "\$(git -C "\$src/s" rev-parse HEAD)" == "$WGOBF_PH_COMMIT" ]] || { echo "Коммит Phobos не совпал — сборка остановлена"; exit 1; }
build="\$src/s/$WGOBF_PH_SRC"
EOF
    fi
    cat <<EOF
make -C "\$build" RELEASE=1 >/dev/null
systemctl stop "\$UNIT" 2>/dev/null || true
install -D -m 755 "\$build/wg-obfuscator" "\$LIB/wg-obfuscator"

mkdir -p "\$CONF_DIR" /etc/wireguard; chmod 700 "\$CONF_DIR" /etc/wireguard
cat > "\$CONF_DIR/obfuscator.conf" <<'OBF_EOF'
EOF
    cat "$dir/obfuscator.conf"
    echo "OBF_EOF"
    echo "cat > \"/etc/wireguard/\$WG_IF.conf\" <<'WG_EOF'"
    cat "$dir/wg.conf"
    echo "WG_EOF"
    echo "cat > \"\$LIB/keep-in.sh\" <<'KEEP_EOF'"
    _wgobf_keep_script
    echo "KEEP_EOF"
    cat <<'EOF'
chmod 755 "$LIB/keep-in.sh"
{ echo '#!/bin/bash'; declare -p TAG LIB CONF_DIR UNIT KEEP WG_IF; declare -f uninstall; echo uninstall; } > "$LIB/uninstall.sh"
chmod 700 "$LIB/uninstall.sh"
chmod 600 "$CONF_DIR/obfuscator.conf" "/etc/wireguard/$WG_IF.conf"
# DNS в wg-quick требует resolvconf; IPv6 (::/0 и адрес клиента) — включённого IPv6
command -v resolvconf >/dev/null || { sed -i '/^DNS = /d' "/etc/wireguard/$WG_IF.conf"; echo "resolvconf нет — DNS остаётся системный"; }
if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == 1 ]]; then
  sed -i -e 's#, ::/0##' -e 's#^\(Address = [^,]*\),.*#\1#' "/etc/wireguard/$WG_IF.conf"
fi

cat > "/etc/systemd/system/$UNIT" <<UNIT_EOF
[Unit]
Description=wg-obfuscator (клиент $TAG)
After=network-online.target
Wants=network-online.target
Before=wg-quick@$WG_IF.service

[Service]
ExecStart=$LIB/wg-obfuscator -c $CONF_DIR/obfuscator.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
# Ответы на входящие (SSH) — мимо туннеля: стартует сразу за wg-quick, гаснет с ним
cat > "/etc/systemd/system/$KEEP" <<UNIT_EOF
[Unit]
Description=Входящие подключения мимо туннеля $WG_IF
After=wg-quick@$WG_IF.service
PartOf=wg-quick@$WG_IF.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB/keep-in.sh up
ExecStop=$LIB/keep-in.sh down

[Install]
WantedBy=wg-quick@$WG_IF.service
UNIT_EOF
systemctl daemon-reload
systemctl enable "$UNIT" "$KEEP" >/dev/null 2>&1
systemctl restart "$UNIT"
systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1
if ! systemctl restart "wg-quick@$WG_IF"; then
  echo "WireGuard не поднялся: journalctl -u wg-quick@$WG_IF -n 20"
  echo "Частая причина («File exists») — на устройстве уже поднят другой VPN на весь трафик."
  exit 1
fi
systemctl is-active -q "$KEEP" || systemctl restart "$KEEP" \
  || echo "Внимание: входящие подключения (SSH) могут не работать — journalctl -u $KEEP"
echo "Готово: интернет этого устройства идёт через $SERVER. Проверка: wg show $WG_IF (строка latest handshake)"
echo "Выключить: systemctl stop wg-quick@$WG_IF · удалить: bash $LIB/uninstall.sh"
}
main "$@"
EOF
  } | write_file "$dir/install-linux.sh" 700
}

wgobf_show_bundle() {
  local name="$1" dir="$WGOBF_CLIENTS/$1"
  [[ -f "$dir/wg.conf" ]] || { err "Комплект $name не найден ($dir)"; return 1; }
  wgobf_bundle_fresh "$name" || return 1
  echo ""
  hdr "Клиент $name — $dir ($(_wgobf_preset_label "$(wgobf_client_preset "$name")"))"
  echo -e "${Y}# obfuscator.conf${N}"; cat "$dir/obfuscator.conf"
  echo -e "${Y}# wg.conf${N}"; cat "$dir/wg.conf"
  if [[ -f "$dir/wg-direct.conf" ]]; then
    echo -e "${Y}# wg-direct.conf (без обфускатора, виден DPI)${N}"
    share_config "$dir/wg-direct.conf" qr
  fi
  echo -e "${Y}# Keenetic, AWG Manager → «Phobos» (одной вставкой):${N}"
  cat "$dir/phobos-link.txt"
  echo -e "  ${D}Ссылка установки для AWG Manager (одноразовая) — в боте и панели${N}"
  echo -e "  ${D}Вкладка «ClusterM» и подробности — $dir/keenetic.txt${N}"
  info "Linux: install-linux.sh на устройство и sudo bash install-linux.sh"
  info "Забрать папку: scp -r root@$(wgobf_get ENDPOINT):$dir ."
}

# ── Выход клиентов через туннель ──────────────────────────
# Клиента wgobf0 можно увести в туннель так же, как клиента AWG: его адрес —
# в «<список туннеля>.wgobf» («адрес» или «адрес|выход Xray / нода»), правило
# «адрес → таблица туннеля» ставит тот же rt_up при каждом подъёме туннеля,
# после перезагрузки и в хуке usque; свой выход Xray — правило по адресу в
# конфиге Xray, своя нода — служба exit-нод. NAT и FORWARD для wgobf0 уже есть
# (MASQUERADE всего, что уходит не в wgobf0).
# Маршрут: direct | warp | xray | xray:выход | exits | exits:нода. Работает
# только туннель, который сейчас поднят; остальные — напрямую, пока он лежит.
wgobf_route_files() { printf '%s\n' "$WARP_PEERS.wgobf" "$XRAY_PEERS.wgobf" "$EXITS_PEERS.wgobf"; }

_wgobf_route_file() {  # warp|xray|exits → список
  case "$1" in
    warp) echo "$WARP_PEERS.wgobf" ;; xray) echo "$XRAY_PEERS.wgobf" ;;
    exits) echo "$EXITS_PEERS.wgobf" ;; *) return 1 ;;
  esac
}

wgobf_client_ip() {  # ИМЯ → IPv4 без /32 (с IPv6 в строке AllowedIPs — через запятую)
  local a
  a=$(_wgobf_peer_allowed "$1")
  a="${a%%,*}"; a="${a%%[[:space:]]*}"
  echo "${a%/32}"
}

wgobf_client_ip6() {  # ИМЯ → IPv6 без /128, если есть
  local a
  a=$(_wgobf_peer_allowed "$1")
  [[ "$a" == *,* ]] || return 0
  a="${a#*,}"; a="${a//[[:space:]]/}"; a="${a%%,*}"
  [[ "$a" == *:* ]] && echo "${a%/128}"
  return 0
}

wgobf_route_of() {  # адрес → маршрут
  local k line
  for k in warp xray exits; do
    line=$(grep -E "^${1//./\\.}(\||$)" "$(_wgobf_route_file "$k")" 2>/dev/null | head -1)
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"|"* ]]; then echo "$k:${line#*|}"; else echo "$k"; fi
    return
  done
  echo direct
}

_wgobf_route_label() {  # маршрут → «через …»
  case "$1" in
    warp) echo "через WARP" ;;
    xray) echo "через Xray" ;; xray:*) echo "через Xray: ${1#xray:}" ;;
    exits) echo "через exit-ноды" ;; exits:*) echo "через exit-ноду ${1#exits:}" ;;
    *) echo напрямую ;;
  esac
}

# Почему маршрут сейчас не выбрать; пусто и 0 — можно
_wgobf_route_why() {  # маршрут
  local sub="${1#*:}"
  [[ "$1" == *:* ]] || sub=""
  # Туннели включаются только при сервере AWG (их маршруты — от awg0): без него
  # выход приняли бы, а включить туннель было бы нельзя
  if [[ "${1%%:*}" =~ ^(warp|xray|exits)$ ]] && ! server_exists; then
    echo "Туннели работают только вместе с сервером AWG — сначала создай его (Сервер → Создать сервер)"; return 1
  fi
  case "${1%%:*}" in
    direct) ;;
    warp) warp_configured || { echo "WARP не настроен — Туннели → WARP"; return 1; } ;;
    xray)
      xray_installed || { echo "Xray не установлен — Туннели → Xray"; return 1; }
      [[ -z "$sub" ]] && return 0
      xray_tags | grep -qxF "$sub" || { echo "Выхода Xray $sub нет"; return 1; }
      xray_tun_supported || { echo "Свой выход Xray — только с inbound tun в самом Xray: обнови Xray"; return 1; } ;;
    exits)
      [[ -n "$(exits_nodes)" ]] || { echo "Exit-нод нет — Туннели → Exit-ноды"; return 1; }
      [[ -z "$sub" || -f "$EXITS_DIR/awg-exit-$sub.conf" ]] || { echo "Ноды $sub нет"; return 1; } ;;
    *) echo "Выход: direct | warp | xray[:выход] | exits[:нода]"; return 1 ;;
  esac
  return 0
}

# Туннель маршрута выключен (или включён другой) — что сказать
_wgobf_route_idle() {  # маршрут
  case "${1%%:*}" in
    warp) warp_is_up || echo "WARP сейчас выключен" ;;
    xray) xray_is_up || echo "Xray сейчас выключен" ;;
    exits) exits_is_up || echo "Exit-ноды сейчас выключены" ;;
  esac
  return 0
}

# Адрес — в список выбранного туннеля (из прочих — прочь), его старые правила — сняты
_wgobf_route_put() {  # адрес маршрут
  local f sub="${2#*:}"
  [[ "$2" == *:* ]] || sub=""
  # Тот же туннель и выход — списки и правила не трогаем: снятое правило exit-нод
  # вернулось бы не сразу (и без единого пакета мимо туннеля)
  [[ "$2" != direct && "$(wgobf_route_of "$1")" == "$2" ]] && return 0
  while IFS= read -r f; do peers_del "$f" "$1"; done < <(wgobf_route_files)
  f=$(_wgobf_route_file "${2%%:*}") && peers_add "$f" "$1" "$1${sub:+|$sub}"
  while ip rule del from "$1" 2>/dev/null; do :; done
}

# Правила поднятого туннеля заново по спискам. Свои выходы Xray изменились —
# конфиг Xray пересобирается и туннель перезапускается; список exit-нод
# обфускатора изменился — перезапускается их маршрутизация; не изменился —
# недостающие правила его клиентов ставятся без перезапуска нод (правило могли
# снять: выход клиента сменили туда и обратно, ip rule flush и т. п.).
_wgobf_route_refresh() {  # прежние _xray_outs и список exit-нод обфускатора
  local rules line up ip
  _tunnel_rules_refresh "$WARP_PEERS" "$WARP_IF" "$WARP_TABLE"
  if xray_is_up; then
    # Обфускатор поставлен после Xray — RETURN до его NAT ещё нет
    if grep -qx 'tun_mode=native' "$XRAY_STATE" 2>/dev/null; then rt_fw_up "$XRAY_IF" nonat || true; fi
    _tunnel_rules_refresh "$XRAY_PEERS" "$XRAY_IF" "$XRAY_TABLE"
    _xray_outs_apply "${1-}" || true
  fi
  if [[ "$(sort "$EXITS_PEERS.wgobf" 2>/dev/null)" != "${2-}" ]]; then
    exits_reapply
  elif [[ -s "$EXITS_PEERS.wgobf" ]] && exits_is_up; then
    rules=$(ip rule show 2>/dev/null)
    up=$(exits_live_nodes | tr '\n' ' ')      # живые по порядку: упавшую сторож уже вывел
    while IFS= read -r line; do
      line="${line//[[:space:]]/}"
      ip="${line%%|*}"
      valid_ip "$ip" || continue
      grep -qE "^$EXITS_TABLE:[[:space:]]+from ${ip//./\\.}[[:space:]]" <<< "$rules" \
        || exits_peer_rule "$line" "$up" 2>/dev/null
    done < "$EXITS_PEERS.wgobf"
  fi
  # IPv6 в туннеле: клиентам в туннелях — отказ по IPv6, остальным — снят
  if wgobf_installed && ip link show "$WGOBF_IF" &>/dev/null; then wgobf_fw6_routes; fi
  return 0
}

# Прежние адреса — из всех списков и правил (обфускатор удалён или ставится заново)
_wgobf_routes_clear() {
  local f line xo ex
  xo=$(_xray_outs); ex=$(sort "$EXITS_PEERS.wgobf" 2>/dev/null)
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      valid_ip "${line%%|*}" || continue
      while ip rule del from "${line%%|*}" 2>/dev/null; do :; done
    done < "$f"
    rm -f "$f"
  done < <(wgobf_route_files)
  _wgobf_route_refresh "$xo" "$ex"
}

# Выход клиента (ИМЯ) или всех (all — и новых по умолчанию):
# direct | warp | xray[:выход] | exits[:нода]
wgobf_route_set() {
  local who="${1:-}" r="${2:-}" ip name n=0 why xo ex
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  # Выход и нода — одной строкой без «|» и пробелов: они ложатся строкой в список
  [[ -n "$who" && "$r" =~ ^(direct|warp|xray(:[^|[:space:][:cntrl:]]+)?|exits(:[A-Za-z0-9_]{1,6})?)$ ]] \
    || { err "Выход: direct | warp | xray[:выход] | exits[:нода]"; return 1; }
  why=$(_wgobf_route_why "$r") || { err "$why"; return 1; }
  if [[ "$who" != all ]]; then
    grep -qxF -- "$who" <<< "$(wgobf_clients)" || { err "Клиента $who нет"; return 1; }
    ip=$(wgobf_client_ip "$who")
    valid_ip "$ip" || { err "У клиента $who нет адреса"; return 1; }
  fi
  xo=$(_xray_outs); ex=$(sort "$EXITS_PEERS.wgobf" 2>/dev/null)
  if [[ "$who" == all ]]; then
    while IFS= read -r name; do
      ip=$(wgobf_client_ip "$name")
      valid_ip "$ip" && { _wgobf_route_put "$ip" "$r"; n=$((n + 1)); }
    done < <(wgobf_clients)
    wgobf_set ROUTE "$r"
  else
    _wgobf_route_put "$ip" "$r"; n=1
  fi
  _wgobf_route_refresh "$xo" "$ex"
  log_info "wgobf: выход $who → $r"
  ok "Клиенты обфускатора $(_wgobf_route_label "$r"): $n"
  why=$(_wgobf_route_idle "$r")
  [[ -z "$why" ]] || warn "$why — пока напрямую, туда уйдут, когда туннель включится"
}

# Выбор маршрута из настроенных туннелей → CHOSEN
_wgobf_route_pick() {
  local opts=(direct) labels=(Напрямую) tags=() nodes=() t i c
  server_exists || info "Туннели — только вместе с сервером AWG: пока он не создан, выход один — напрямую"
  if server_exists && warp_configured; then opts+=(warp); labels+=("Через WARP"); fi
  if server_exists && xray_installed; then
    opts+=(xray); labels+=("Через Xray — выход по умолчанию")
    if xray_tun_supported; then
      mapfile -t tags < <(xray_tags)
      for t in "${tags[@]}"; do opts+=("xray:$t"); labels+=("Через Xray — $t"); done
    fi
  fi
  mapfile -t nodes < <(server_exists && exits_nodes)
  if (( ${#nodes[@]} )); then
    opts+=(exits); labels+=("Через exit-ноды — общий выход")
    if (( ${#nodes[@]} > 1 )); then
      for t in "${nodes[@]}"; do opts+=("exits:$t"); labels+=("Через exit-ноду $t"); done
    fi
  fi
  for i in "${!opts[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${labels[$i]}"; done
  read_choice c "${C}  Выход (0 — отмена): ${N}" 0 "${#opts[@]}" 0
  (( c )) || return 1
  CHOSEN="${opts[$((c - 1))]}"
}

wgobf_route_menu() {
  local c names=() i ip def who
  while true; do
    mapfile -t names < <(wgobf_clients)
    def=$(wgobf_get ROUTE)
    echo ""
    hdr "Выход клиентов обфускатора"
    echo -e "  Всем и новым: ${W}$(_wgobf_route_label "${def:-direct}")${N}"
    for i in "${!names[@]}"; do
      ip=$(wgobf_client_ip "${names[$i]}")
      echo -e "  ${C}$((i + 1)))${N} ${names[$i]} ${D}$ip${N}  $(_wgobf_route_label "$(wgobf_route_of "$ip")")"
    done
    echo -e "  ${C}a)${N} Всем клиентам"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер клиента или a: ${N}" 0 "${#names[@]}" 0 "a"
    case "$c" in
      0) return 0 ;;
      a) who=all ;;
      *) who="${names[$((c - 1))]}" ;;
    esac
    _wgobf_route_pick || continue
    wgobf_route_set "$who" "$CHOSEN" && _wgobf_route_offer_on "$CHOSEN"
  done
}

# Туннель выбранного выхода настроен, но выключен — включить сразу. Одновременно
# работает один туннель: другой — с подтверждением выключается
_wgobf_route_offer_on() {  # маршрут
  local k="${1%%:*}" name c m=""
  case "$k" in
    warp) warp_configured && ! warp_is_up || return 0; name=WARP ;;
    xray) xray_installed && ! xray_is_up || return 0; name=Xray ;;
    exits) [[ -n "$(exits_nodes)" ]] && ! exits_is_up || return 0; name="exit-ноды"
      m=$(exits_state_get mode); [[ "$m" == peers ]] || m=all ;;
    *) return 0 ;;
  esac
  [[ "$m" == all ]] && info "Режим exit-нод «все клиенты»: через них пойдут и клиенты AWG"
  c=$(tunnel_conflict "$k")
  if [[ -n "$c" ]]; then
    ask_yes "  Сейчас работает $c, а одновременно — один туннель. Выключить и включить $name? [y/N]: " n || return 0
    if [[ "$k" != warp ]] && warp_is_up; then warp_down; fi
    if [[ "$k" != xray ]] && xray_is_up; then xray_down; fi
    if t2s_is_up; then t2s_down; fi
    if [[ "$k" != exits ]] && exits_is_up; then exits_down; fi
  else
    ask_yes "  $name выключен — включить сейчас? [Y/n]: " y || return 0
  fi
  case "$k" in warp) warp_up ;; xray) xray_up ;; exits) exits_up "$m" ;; esac || true
}

# ── Клиенты ───────────────────────────────────────────────
wgobf_add_client() {  # имя [профиль] (без профиля — профиль новых клиентов)
  local name="$1" preset="${2:-}" base i ip="" allowed priv pub psk bak r xo ex
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя: латиница, цифры, _ и -, до 32 символов"; return 1; }
  # «all» в wgobf route — все клиенты и выход по умолчанию: клиенту с таким именем выход не задать
  [[ "$name" != all ]] || { err "Имя all занято: так в команде выхода зовутся все клиенты"; return 1; }
  grep -qxF -- "$name" <<< "$(wgobf_clients)" && { err "Клиент $name уже есть"; return 1; }
  [[ -n "$preset" ]] || preset=$(wgobf_default_preset)
  wgobf_preset_exists "$preset" || { err "Профиля $preset нет"; return 1; }
  base=$(wgobf_get NET); base="${base%.*}"
  # С IPv6 в строке AllowedIPs после адреса — запятая и адрес IPv6
  for i in $(seq 2 254); do
    grep -qE "^AllowedIPs[[:space:]]*=[[:space:]]*${base//./\\.}\.$i/32([[:space:]]*,.*)?[[:space:]]*$" "$WGOBF_WG_CONF" \
      || { ip="$base.$i"; break; }
  done
  [[ -n "$ip" ]] || { err "В подсети $(wgobf_get NET) нет свободных адресов"; return 1; }
  allowed="$ip/32"
  [[ "$(wgobf_get IPV6)" == 1 ]] && r=$(wgobf_v6_of "$ip") && allowed+=", $r/128"
  priv=$(wg genkey); pub=$(wg pubkey <<< "$priv"); psk=$(wg genpsk)
  mktmp bak || return 1
  cp -a "$WGOBF_WG_CONF" "$bak"
  printf '\n[Peer]\n# client=%s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s\n' \
    "$name" "$pub" "$psk" "$allowed" >> "$WGOBF_WG_CONF"
  if ! _wgobf_sync; then
    cp -a "$bak" "$WGOBF_WG_CONF"
    err "Клиент не применился — конфиг возвращён"
    return 1
  fi
  # Профиль — до комплекта: комплект собирается под него
  if [[ "$preset" == main ]]; then wgobf_unset "C_$name"; else wgobf_set "C_$name" "$preset"; fi
  wgobf_write_bundle "$name" "$priv" "$psk" || return 1
  ok "Клиент $name: $ip$([[ "$preset" == main ]] || echo ", профиль $preset")"
  log_info "wgobf: добавлен клиент $name ($ip, профиль $preset)"
  # Выход для новых — как у всех: выхода Xray или ноды уже нет — общий выход
  # туннеля (как у прежних клиентов), туннель не настроен — напрямую
  r=$(wgobf_get ROUTE)
  [[ "$r" == *:* ]] && ! _wgobf_route_why "$r" >/dev/null && r="${r%%:*}"
  if [[ -n "$r" && "$r" != direct ]] && _wgobf_route_why "$r" >/dev/null; then
    xo=$(_xray_outs); ex=$(sort "$EXITS_PEERS.wgobf" 2>/dev/null)
    _wgobf_route_put "$ip" "$r"; _wgobf_route_refresh "$xo" "$ex"
    info "Выход: $(_wgobf_route_label "$r")"
  else
    _wgobf_route_put "$ip" direct
  fi
  return 0
}

wgobf_delete_client() {
  local name="$1" bak ip xo ex
  grep -qxF -- "$name" <<< "$(wgobf_clients)" || { err "Клиента $name нет"; return 1; }
  ip=$(wgobf_client_ip "$name")
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
  wgobf_unset "C_$name"
  # Его адрес — из списков туннелей и правил: новый клиент на том же адресе
  # иначе унаследовал бы чужой выход
  if valid_ip "$ip"; then
    xo=$(_xray_outs); ex=$(sort "$EXITS_PEERS.wgobf" 2>/dev/null)
    _wgobf_route_put "$ip" direct; _wgobf_route_refresh "$xo" "$ex"
  fi
  ok "Клиент $name удалён"
  log_info "wgobf: удалён клиент $name"
}

# Имя — только комментарий над пиром: ключи, адрес и выход не меняются, wgobf0
# не перезапускается. Комплект и профиль переезжают к новому имени.
wgobf_rename_client() {  # старое новое
  local old="$1" new="$2" bak p
  grep -qxF -- "$old" <<< "$(wgobf_clients)" || { err "Клиента $old нет"; return 1; }
  [[ "$new" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя: латиница, цифры, _ и -, до 32 символов"; return 1; }
  [[ "$new" != all ]] || { err "Имя all занято: так в команде выхода зовутся все клиенты"; return 1; }
  [[ "$new" == "$old" ]] && return 0
  grep -qxF -- "$new" <<< "$(wgobf_clients)" && { err "Клиент $new уже есть"; return 1; }
  [[ -e "$WGOBF_CLIENTS/$new" ]] && { err "Каталог $WGOBF_CLIENTS/$new уже есть"; return 1; }
  mktmp bak || return 1
  cp -a "$WGOBF_WG_CONF" "$bak"
  awk -v o="# client=$old" -v n="# client=$new" '$0 == o {print n; next} {print}' "$bak" \
    | write_file "$WGOBF_WG_CONF" 600 || { cp -a "$bak" "$WGOBF_WG_CONF"; return 1; }
  p=$(wgobf_get "C_$old")
  wgobf_unset "C_$old"; wgobf_unset "C_$new"
  [[ -n "$p" ]] && wgobf_set "C_$new" "$p"
  if [[ -d "$WGOBF_CLIENTS/$old" ]]; then
    mv "$WGOBF_CLIENTS/$old" "$WGOBF_CLIENTS/$new" \
      && wgobf_write_bundle "$new" || warn "Комплект $new не пересобран — «Комплект клиента» соберёт его заново"
  fi
  log_info "wgobf: клиент переименован: $old → $new"
  ok "Переименован: $old → $new"
}

wgobf_list_clients() {
  local names=() dump now i name pub ip hs p
  mapfile -t names < <(wgobf_clients)
  (( ${#names[@]} )) || { info "Клиентов нет"; return 1; }
  dump=$(wg show "$WGOBF_IF" dump 2>/dev/null | tail -n +2 || true)
  now=$(date +%s)
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    pub=$(wgobf_client_pub "$name"); ip=$(wgobf_client_ip "$name")
    hs=$(awk -v k="$pub" '$1 == k {print $5; exit}' <<< "$dump")
    if [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 )); then hs="$(fmt_duration $((now - hs))) назад"; else hs="—"; fi
    p=$(wgobf_client_preset "$name"); [[ "$p" == main ]] && p="" || p="  профиль $p"
    echo -e "  ${C}$((i + 1)))${N} $name ${D}$ip${N}  рукопожатие: $hs${D}$p${N}"
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

_wgobf_regen_bundles() {  # [профиль — только его клиенты] → число перевыпущенных
  local n=0 name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ -z "${1:-}" || "$(wgobf_client_preset "$name")" == "$1" ]] || continue
    # Сообщения — в stderr: stdout этой функции — число (её зовут через $(...))
    wgobf_write_bundle "$name" >&2 && n=$((n + 1))
  done < <(wgobf_clients)
  echo "$n"
}

# Клиенты профиля
_wgobf_preset_clients() {  # профиль
  local name
  while IFS= read -r name; do
    [[ -n "$name" && "$(wgobf_client_preset "$name")" == "$1" ]] && echo "$name"
  done < <(wgobf_clients)
  return 0
}

# Ключ обфускатора — общий для профиля: после смены его клиенты отключаются,
# пока не получат новый комплект. Ключи WireGuard не меняются.
wgobf_rotate_key() {  # [профиль]
  local p="${1:-main}" old new n
  wgobf_preset_exists "$p" || { err "Профиля $p нет"; return 1; }
  new=$(py rand-key 32)
  _wgobf_preset "$p"; old="$PP_KEY"
  [[ -n "$new" && "$new" != "$old" ]] || { err "Не удалось сгенерировать ключ"; return 1; }
  _wgobf_preset_put "$p" key "$new"
  if ! _wgobf_write_service_files || ! _wgobf_preset_start "$p"; then
    _wgobf_preset_put "$p" key "$old"; _wgobf_write_service_files
    _wgobf_preset_start "$p" &>/dev/null || true
    err "Обфускатор не перезапустился — ключ оставлен прежним"
    return 1
  fi
  n=$(_wgobf_regen_bundles "$p")
  ok "Ключ $([[ "$p" == main ]] && echo обфускатора || echo "профиля $p") заменён, комплекты перевыпущены: $n"
  warn "Старые конфиги клиентов $([[ "$p" == main ]] && echo "основного профиля" || echo "профиля $p") больше не работают — раздай новые"
  log_info "wgobf: ключ обфускатора заменён (профиль $p)"
}

# ── Профили обфускации: изменение ─────────────────────────
# Записать одно поле профиля: port key mask obfb dummy idle
_wgobf_preset_put() {  # профиль поле значение
  local p="$1" f="$2" v="$3"
  if [[ "$p" == main ]]; then
    case "$f" in
      port) wgobf_set PORT "$v" ;; key) wgobf_set KEY "$v" ;; mask) wgobf_set MASKING "$v" ;;
      dummy) wgobf_set DUMMY "$v" ;; idle) wgobf_set IDLE "$v" ;; obfb) ;;
    esac
    return 0
  fi
  _wgobf_preset "$p" || return 1
  case "$f" in
    port) PP_PORT="$v" ;; key) PP_KEY="$v" ;; mask) PP_MASK="$v" ;;
    obfb) PP_OBFB="$v" ;; dummy) PP_DUMMY="$v" ;; idle) PP_IDLE="$v" ;;
  esac
  wgobf_set "P_$p" "$PP_PORT|$PP_KEY|$PP_MASK|$PP_OBFB|$PP_DUMMY|$PP_IDLE"
}

# Разбор ключ=значение профиля → OPT_PORT OPT_MASK OPT_OBFB OPT_DUMMY OPT_IDLE (пусто — не задано)
_wgobf_preset_opts() {
  local kv k v
  OPT_PORT="" OPT_MASK="" OPT_OBFB="" OPT_DUMMY="" OPT_IDLE=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [[ "$kv" == *=* ]] || { err "Параметр — ключ=значение: $kv"; return 1; }
    case "$k" in
      port) OPT_PORT="$v" ;; masking) OPT_MASK="${v^^}" ;; obfb|obfuscate-bytes) OPT_OBFB="$v" ;;
      dummy|max-dummy) OPT_DUMMY="$v" ;; idle|idle-timeout) OPT_IDLE="$v" ;;
      *) err "Неизвестный параметр: $k (port, masking, obfb, dummy, idle)"; return 1 ;;
    esac
  done
}

# Новый профиль: имя [port=] [masking=STUN|NONE|MEDIA] [obfb=0|4-1500] [dummy=0-1024] [idle=10-86400]
wgobf_preset_add() {
  local name="${1:-}" n port mask obfb dummy idle key why
  shift || true
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  [[ "$name" =~ $WGOBF_PRESET_RE ]] || { err "Имя профиля: латиница, цифры и _, до 16 символов"; return 1; }
  [[ "$name" != main && "$name" != all ]] || { err "Имя $name занято"; return 1; }
  [[ -z "$(wgobf_get "P_$name")" ]] || { err "Профиль $name уже есть"; return 1; }
  n=$(wgobf_presets | grep -c . || true)
  (( n < WGOBF_PRESETS_MAX )) || { err "Профилей уже $n — больше нельзя"; return 1; }
  _wgobf_preset_opts "$@" || return 1
  mask="${OPT_MASK:-MEDIA}"; obfb="${OPT_OBFB:-0}"; dummy="${OPT_DUMMY:-4}"; idle="${OPT_IDLE:-300}"
  if [[ -n "$OPT_PORT" ]]; then
    awg_port_ok "$OPT_PORT" || { err "Порт — 443 или 1024-65535"; return 1; }
    udp_port_busy "$OPT_PORT" && { err "UDP $OPT_PORT занят (сокет, AWG, каскад или обфускатор)"; return 1; }
    port="$OPT_PORT"
  else
    port=$(random_free_udp_port) || { err "Нет свободного порта"; return 1; }
  fi
  key=$(py rand-key 32)
  why=$(_wgobf_preset_ok "$port" "$key" "$mask" "$obfb" "$dummy" "$idle") || { err "$why"; return 1; }
  if [[ "$(_wgobf_engine "$mask" "$obfb")" == phobos ]]; then
    _wgobf_ph_prepare || { err "Обфускатор Phobos не собрался — профиль не создан"; return 1; }
  fi
  wgobf_set "P_$name" "$port|$key|$mask|$obfb|$dummy|$idle"
  if ! _wgobf_write_service_files || ! _wgobf_preset_start "$name"; then
    wgobf_unset "P_$name"
    _wgobf_write_service_files || true
    err "Профиль $name не запустился — не создан"
    return 1
  fi
  ufw_open "$port/udp" "$(_wgobf_preset_tag "$name")"
  _wgobf_preset "$name"
  ok "Профиль $name: порт $port/udp, маскировка $mask$( (( PP_EOBFB )) && echo ", obfuscate-bytes $PP_EOBFB")"
  info "Клиенту профиль — в его карточке; профиль для новых клиентов — в настройках профилей"
  log_info "wgobf: профиль $name (порт $port, $mask, obfb $obfb)"
}

# Настройки профиля: имя masking= obfb= dummy= idle= (main — основной: STUN|NONE, без obfuscate-bytes)
wgobf_preset_set() {
  local p="${1:-}" mask obfb dummy idle old_line old_conf new_conf why n chg breaking=0
  shift || true
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  wgobf_preset_exists "$p" || { err "Профиля $p нет"; return 1; }
  _wgobf_preset_opts "$@" || return 1
  [[ -z "$OPT_PORT" ]] || { err "Порт профиля не меняется — создай новый профиль"; return 1; }
  _wgobf_preset "$p"
  mask="${OPT_MASK:-$PP_MASK}"; obfb="${OPT_OBFB:-$PP_OBFB}"; dummy="${OPT_DUMMY:-$PP_DUMMY}"; idle="${OPT_IDLE:-$PP_IDLE}"
  if [[ "$p" == main ]]; then
    [[ "$mask" =~ ^(STUN|NONE)$ ]] || { err "Основной профиль: маскировка STUN | NONE (MEDIA — в отдельном профиле)"; return 1; }
    [[ "$obfb" == 0 ]] || { err "Основной профиль — без obfuscate-bytes (их понимает только отдельный профиль)"; return 1; }
  fi
  why=$(_wgobf_opts_ok "$mask" "$obfb" "$dummy" "$idle") || { err "$why"; return 1; }
  if [[ "$(_wgobf_engine "$mask" "$obfb")" == phobos ]]; then
    _wgobf_ph_prepare || { err "Обфускатор Phobos не собрался — настройки не изменены"; return 1; }
  fi
  old_conf=$(_wgobf_server_section "$p")
  if [[ "$p" == main ]]; then
    old_line="$PP_MASK|$PP_DUMMY|$PP_IDLE"
    wgobf_set MASKING "$mask"; wgobf_set DUMMY "$dummy"; wgobf_set IDLE "$idle"
  else
    old_line=$(wgobf_get "P_$p")
    wgobf_set "P_$p" "$PP_PORT|$PP_KEY|$mask|$obfb|$dummy|$idle"
  fi
  new_conf=$(_wgobf_server_section "$p")
  # Серверу менять нечего (маскировка основного — у клиентов) — без перезапуска
  if [[ "$new_conf" != "$old_conf" ]]; then
    # masking и obfuscate-bytes сервера — общие с клиентами: прежние комплекты ломаются
    [[ "$(grep -E '^(masking|obfuscate-bytes) ' <<< "$new_conf")" == "$(grep -E '^(masking|obfuscate-bytes) ' <<< "$old_conf")" ]] \
      || breaking=1
    if ! _wgobf_write_service_files || ! _wgobf_preset_start "$p"; then
      if [[ "$p" == main ]]; then
        IFS='|' read -r mask dummy idle <<< "$old_line"
        wgobf_set MASKING "$mask"; wgobf_set DUMMY "$dummy"; wgobf_set IDLE "$idle"
      else
        wgobf_set "P_$p" "$old_line"
      fi
      _wgobf_write_service_files; _wgobf_preset_start "$p" &>/dev/null || true
      err "Обфускатор не перезапустился — настройки возвращены"
      return 1
    fi
  fi
  n=$(_wgobf_regen_bundles "$p")
  chg=""
  [[ -n "$OPT_MASK" ]] && chg+=", маскировка $mask"
  [[ -n "$OPT_OBFB" ]] && chg+=", obfuscate-bytes $obfb"
  [[ -n "$OPT_DUMMY" ]] && chg+=", max-dummy $dummy"
  [[ -n "$OPT_IDLE" ]] && chg+=", idle-timeout $idle"
  ok "$(_wgobf_preset_label "$p"): ${chg#, }${chg:+; }комплекты перевыпущены: $n"
  if (( breaking )); then warn "Старые комплекты клиентов профиля больше не работают — раздай новые"
  else info "Старые комплекты продолжат работать"; fi
  log_info "wgobf: профиль $p: $*"
}

wgobf_preset_del() {  # профиль
  local p="${1:-}" moved=() c
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  [[ "$p" != main ]] || { err "Основной профиль не удаляется"; return 1; }
  [[ "$p" =~ $WGOBF_PRESET_RE && -n "$(wgobf_get "P_$p")" ]] || { err "Профиля $p нет"; return 1; }
  mapfile -t moved < <(_wgobf_preset_clients "$p")
  wgobf_unset "P_$p"
  for c in "${moved[@]}"; do wgobf_unset "C_$c"; done
  [[ "$(wgobf_get DEFP)" == "$p" ]] && wgobf_unset DEFP
  _wgobf_preset_drop_unit "$p"
  ufw_delete_comment "$(_wgobf_preset_tag "$p")"
  for c in "${moved[@]}"; do wgobf_write_bundle "$c" || true; done
  ok "Профиль $p удалён$( (( ${#moved[@]} )) && echo "; его клиенты (${#moved[@]}) — на основном, комплекты перевыпущены")"
  (( ${#moved[@]} )) && warn "Старые комплекты этих клиентов больше не работают — раздай новые: ${moved[*]}"
  log_info "wgobf: профиль $p удалён"
  return 0
}

wgobf_preset_default() {  # профиль новых клиентов
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  wgobf_preset_exists "${1:-}" || { err "Профиля ${1:-} нет"; return 1; }
  if [[ "$1" == main ]]; then wgobf_unset DEFP; else wgobf_set DEFP "$1"; fi
  ok "Новые клиенты: $(_wgobf_preset_label "$1")"
}

# Профиль комплекта клиента. Сервер пускает через любой профиль — старый
# комплект работает, пока жив его профиль.
wgobf_assign() {  # клиент профиль
  local name="${1:-}" p="${2:-}"
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  grep -qxF -- "$name" <<< "$(wgobf_clients)" || { err "Клиента $name нет"; return 1; }
  wgobf_preset_exists "$p" || { err "Профиля $p нет"; return 1; }
  if [[ "$p" == main ]]; then wgobf_unset "C_$name"; else wgobf_set "C_$name" "$p"; fi
  wgobf_write_bundle "$name" || return 1
  ok "Клиент $name: $(_wgobf_preset_label "$p"), комплект перевыпущен"
  info "Прежний комплект тоже работает, пока есть его профиль"
  log_info "wgobf: клиент $name → профиль $p"
}

# ── IPv6 в туннеле ────────────────────────────────────────
# Можно ли включить: почему нет — в stdout
wgobf_ipv6_why() {
  if rublock_on 2>/dev/null; then
    echo "Включено «РФ мимо VPN» — оно работает только для IPv4, по IPv6 клиенты ходили бы в сети России через сервер. Сначала выключи его"
    return 1
  fi
  [[ -n "$(ip -6 route show default 2>/dev/null)" ]] || { echo "У сервера нет IPv6 — нет маршрута IPv6 по умолчанию"; return 1; }
  command -v ip6tables &>/dev/null && ip6tables -t nat -S POSTROUTING &>/dev/null \
    || { echo "Нет ip6tables с таблицей nat — NAT для IPv6 не поставить"; return 1; }
  return 0
}

# Случайная частная сеть IPv6 (ULA, RFC 4193): fdXX:XXXX:XXXX:XXXX::/64
_wgobf_new_net6() {
  local h
  h=$(od -An -N7 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$h" =~ ^[0-9a-f]{14}$ ]] || return 1
  printf 'fd%s:%s:%s:%s::/64\n' "${h:0:2}" "${h:2:4}" "${h:6:4}" "${h:10:4}"
}

# Адреса IPv6 в wgobf0.conf: добавить (сервер ::1/64, пир ::<номер>/128) или снять
_wgobf_conf_v6() {  # on ПРЕФИКС | off  → stdout
  if [[ "$1" == on ]]; then
    awk -v p6="$2" '
      /^[ \t]*\[/ { sec = tolower($0) }
      sec ~ /interface/ && /^Address[ \t]*=/ && $0 !~ /:/ { $0 = $0 ", " p6 "1/64" }
      sec ~ /peer/ && /^AllowedIPs[ \t]*=/ && $0 !~ /:/ && match($0, /\.[0-9]+\/32/) {
        $0 = $0 ", " p6 sprintf("%x", substr($0, RSTART + 1, RLENGTH - 4) + 0) "/128" }
      { print }' "$WGOBF_WG_CONF"
  else
    awk '/^(Address|AllowedIPs)[ \t]*=/ { gsub(/,[ \t]*[0-9a-fA-F]*:[0-9a-fA-F:]*\/[0-9]+/, "") } { print }' "$WGOBF_WG_CONF"
  fi
}

wgobf_ipv6() {  # on|off
  local want="${1:-}" net6 bak why n
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  [[ "$want" =~ ^(on|off)$ ]] || { err "IPv6: on | off"; return 1; }
  if [[ "$want" == on ]]; then
    why=$(wgobf_ipv6_why) || { err "$why"; return 1; }
    net6=$(wgobf_get NET6)
    [[ "$net6" =~ ^fd[0-9a-f]{2}(:[0-9a-f]{1,4}){3}::/64$ ]] || net6=$(_wgobf_new_net6) || { err "Не удалось выбрать сеть IPv6"; return 1; }
  fi
  mktmp bak || return 1
  cp -a "$WGOBF_WG_CONF" "$bak"
  _wgobf_conf_v6 off | write_file "$WGOBF_WG_CONF.v6" 600 && mv -f "$WGOBF_WG_CONF.v6" "$WGOBF_WG_CONF" || return 1
  if [[ "$want" == on ]]; then
    _wgobf_conf_v6 on "${net6%/64}" | write_file "$WGOBF_WG_CONF.v6" 600 && mv -f "$WGOBF_WG_CONF.v6" "$WGOBF_WG_CONF" || return 1
    wgobf_set NET6 "$net6"; wgobf_set IPV6 1
  else
    wgobf_unset IPV6
  fi
  # Адрес wgobf0 и правила — перезапуском wg-quick (как при загрузке): клиенты
  # на несколько секунд теряют связь и переподключаются сами
  if ! systemctl restart "wg-quick@$WGOBF_IF" &>/dev/null || ! ip link show "$WGOBF_IF" &>/dev/null; then
    cp -a "$bak" "$WGOBF_WG_CONF"
    if [[ "$want" == on ]]; then wgobf_unset IPV6; else wgobf_set IPV6 1; fi
    systemctl restart "wg-quick@$WGOBF_IF" &>/dev/null || true
    err "$WGOBF_IF не поднялся — IPv6 $([[ "$want" == on ]] && echo "не включён" || echo "не выключен")"
    _wgobf_journal "wg-quick@$WGOBF_IF"
    return 1
  fi
  n=$(_wgobf_regen_bundles)
  web_vpn_changed
  if [[ "$want" == on ]]; then
    ok "IPv6 в туннеле включён: сеть $net6, комплекты перевыпущены: $n"
    info "В прежних комплектах только IPv4 — они работают, IPv6 появится с новыми"
    info "Клиенты в туннелях (WARP, Xray, exit-ноды) IPv6 не получают: туннели ведут только IPv4"
  else
    ok "IPv6 в туннеле выключен, комплекты перевыпущены: $n"
  fi
  log_info "wgobf: IPv6 $want"
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
    read_line port "${C}  UDP-порт обфускатора: 443 или 1024-65535 (Enter — случайный): ${N}"
    [[ -z "$port" ]] && break
    awg_port_ok "$port" || { warn "Порт — 443 или 1024-65535"; continue; }
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
      port) awg_port_ok "$v" || { err "port: 443 или 1024-65535"; return 1; }
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
  # Новая установка: выходы прежних клиентов (адреса в новой подсети совпадут) — прочь
  _wgobf_routes_clear
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
  ufw_open "$port/udp" "$WGOBF_TAG"
  ufw_forward_accept
  web_vpn_changed
  ok "WG + обфускатор запущен: вход $ep:$port/udp, подсеть $net"
  log_info "wgobf: установлен (порт $port, wg $wg_port, сеть $net, маскировка $mask)"
  [[ -z "$first" ]] || wgobf_add_client "$first"
}

_wgobf_teardown() {  # keep|drop — клиентские комплекты
  local port p f
  port=$(wgobf_get PORT)
  systemctl disable --now "$WGOBF_UNIT" "wg-quick@$WGOBF_IF" &>/dev/null || true
  # Службы профилей: и по state, и по их конфигам (state мог быть испорчен)
  { wgobf_presets
    for f in "$WGOBF_DIR"/p-*.conf; do [[ -f "$f" ]] && { p="${f##*/p-}"; echo "${p%.conf}"; }; done
  } | sort -u | while IFS= read -r p; do _wgobf_preset_drop_unit "$p"; done
  ip link del dev "$WGOBF_IF" &>/dev/null || true
  wgobf_fw_run down
  # Правила UFW профилей помечены «awg-wgobf-p-…» — подстрока снимает и их
  [[ -n "$port" ]] && ufw_delete_matching "$WGOBF_TAG"
  remove_unit "$WGOBF_UNIT"
  rm -f "$WGOBF_WG_CONF" "$WGOBF_BIN" "$WGOBF_FW" "$WGOBF_PH_BIN" "$WGOBF_PH_BIN.commit"
  _wgobf_apparmor drop || true
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
  _wgobf_routes_clear
  web_vpn_changed
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
  for port in $(wgobf_ports); do
    udp_listening "$port" && warn "UDP $port сейчас занят — обфускатор может не подняться"
  done
  # IPv6 из бэкапа, а у этого сервера его нет — wgobf0 поднимется, у клиентов будет только IPv4
  [[ "$(wgobf_get IPV6)" == 1 ]] && ! wgobf_ipv6_why >/dev/null \
    && warn "IPv6 в туннеле из бэкапа здесь не заработает: $(wgobf_ipv6_why)"
  wgobf_restart || { err "WG + обфускатор восстановлен, но не запустился"; return 1; }
  _wgobf_ufw_open_all
  ufw_forward_accept
  ok "WG + обфускатор восстановлен"
}

# Порты всех профилей — в UFW (UFW выключен — молча ничего)
_wgobf_ufw_open_all() {
  local p
  ufw_open "$(wgobf_get PORT)/udp" "$WGOBF_TAG"
  while IFS= read -r p; do
    _wgobf_preset "$p" && ufw_open "$PP_PORT/udp" "$(_wgobf_preset_tag "$p")"
  done < <(wgobf_presets)
  return 0
}

# ── Меню ──────────────────────────────────────────────────
wgobf_status() {  # [состояние порта в UFW и вывод ufw status — если уже узнаны]
  local s u="${1:-}" p port uout
  if (( $# > 1 )); then uout="$2"; else uout=$(ufw_status_text); fi
  if ip link show "$WGOBF_IF" &>/dev/null; then s="${G}● поднят${N}"; else s="${R}○ лежит${N}"; fi
  echo -e "  $WGOBF_IF         : $s"
  if unit_active "$WGOBF_UNIT"; then s="${G}● работает${N}"; else s="${R}○ не работает${N}"; fi
  echo -e "  wg-obfuscator  : $s ${D}($(wgobf_bin_version))${N}"
  echo -e "  Вход           : ${W}$(wgobf_get ENDPOINT):$(wgobf_get PORT)/udp${N}"
  _wgobf_preset main
  echo -e "  Маскировка     : ${W}$PP_MASK${N} ${D}(у клиентов; сервер понимает любую), max-dummy $PP_DUMMY, idle-timeout $PP_IDLE${N}"
  echo -e "  Без обфускатора: $([[ "$(wgobf_get ALLOW_CLEAN)" == 1 ]] && echo -e "${Y}да${N}" || echo нет)"
  echo -e "  Подсеть        : $(wgobf_get NET), MTU $(wgobf_get MTU), WireGuard на $(wgobf_get WG_PORT) ${D}(снаружи закрыт)${N}"
  if [[ "$(wgobf_get IPV6)" == 1 ]]; then echo -e "  IPv6 в туннеле : ${G}да${N} ${D}($(wgobf_get NET6))${N}"
  else echo -e "  IPv6 в туннеле : нет"; fi
  echo -e "  Клиентов       : $(wgobf_clients | grep -c . || true)"
  [[ -n "$u" ]] || u=$(ufw_port_state "$(wgobf_get PORT)/udp" "$uout")
  case "$u" in
    open) echo -e "  UFW            : ${G}● порт открыт${N}" ;;
    closed) echo -e "  UFW            : ${R}▲ порт $(wgobf_get PORT)/udp закрыт${N} ${D}— Сервер → Проверить и починить${N}" ;;
  esac
  while IFS= read -r p; do
    _wgobf_preset "$p" || continue
    if unit_active "$(_wgobf_preset_unit "$p")"; then s="${G}●${N}"; else s="${R}○ не работает${N}"; fi
    port="$PP_PORT/udp"
    [[ "$(ufw_port_state "$port" "$uout")" == closed ]] && port+=" ${R}закрыт в UFW${N}"
    echo -e "  Профиль $p: $s ${W}$port${N} $PP_MASK$( (( PP_EOBFB )) && echo ", obfuscate-bytes $PP_EOBFB")" \
      "${D}— клиентов: $(_wgobf_preset_clients "$p" | grep -c . || true)${N}"
  done < <(wgobf_presets)
  return 0
}

wgobf_settings() {
  local c mask clean v6
  mask=$(wgobf_get MASKING); clean=$(wgobf_get ALLOW_CLEAN); v6=$(wgobf_get IPV6)
  _wgobf_preset main
  echo -e "  ${C}1)${N} Маскировка клиентов: ${W}$mask${N} → $([[ "$mask" == STUN ]] && echo NONE || echo STUN)"
  echo -e "  ${C}2)${N} Клиенты без обфускатора: ${W}$([[ "$clean" == 1 ]] && echo да || echo нет)${N} → $([[ "$clean" == 1 ]] && echo нет || echo да)"
  echo -e "  ${C}3)${N} Сменить ключ обфускатора"
  echo -e "  ${C}4)${N} max-dummy: ${W}$PP_DUMMY${N} ${D}— до скольки байт мусора в пакет (0-1024)${N}"
  echo -e "  ${C}5)${N} idle-timeout: ${W}$PP_IDLE${N} ${D}— через сколько секунд тишины забыть клиента${N}"
  echo -e "  ${C}6)${N} IPv6 в туннеле: ${W}$([[ "$v6" == 1 ]] && echo да || echo нет)${N} → $([[ "$v6" == 1 ]] && echo нет || echo да)"
  read_choice c "${C}  Выбор (0 — назад): ${N}" 0 6 0
  case "$c" in
    1) wgobf_set_masking "$([[ "$mask" == STUN ]] && echo NONE || echo STUN)" ;;
    2) wgobf_set_clean "$([[ "$clean" == 1 ]] && echo 0 || echo 1)" ;;
    3) warn "После смены ключа клиенты основного профиля отключатся, пока не получат новый комплект"
       read_confirm "${R}  Сменить ключ? (введи yes): ${N}" && { wgobf_rotate_key main || true; } ;;
    4) read_line c "${C}  max-dummy (0-1024, Enter — отмена): ${N}"
       [[ -n "$c" ]] && { wgobf_preset_set main "dummy=$c" || true; } ;;
    5) read_line c "${C}  idle-timeout, секунд (10-86400, Enter — отмена): ${N}"
       [[ -n "$c" ]] && { wgobf_preset_set main "idle=$c" || true; } ;;
    6) wgobf_ipv6 "$([[ "$v6" == 1 ]] && echo off || echo on)" || true ;;
  esac
  return 0
}

# Маскировка у клиентов основного профиля: STUN|NONE. Сервер в режиме AUTO понимает обе.
wgobf_set_masking() {
  [[ "$1" =~ ^(STUN|NONE)$ ]] || { err "Маскировка: STUN | NONE"; return 1; }
  wgobf_preset_set main "masking=$1"
}

wgobf_set_clean() {  # 1 — пускать клиентов без обфускатора
  [[ "$1" =~ ^[01]$ ]] || { err "0 | 1"; return 1; }
  wgobf_set ALLOW_CLEAN "$1"
  _wgobf_write_service_files && systemctl restart "$WGOBF_UNIT" &>/dev/null
  ok "Клиенты без обфускатора: $([[ "$1" == 1 ]] && echo да || echo нет), комплекты перевыпущены: $(_wgobf_regen_bundles)"
}

_wgobf_preset_line() {  # профиль → «порт маскировка …» (после _wgobf_preset)
  echo "$PP_PORT/udp, $PP_MASK$( (( PP_EOBFB )) && echo ", obfuscate-bytes $PP_EOBFB"), max-dummy $PP_DUMMY, idle $PP_IDLE"
}

# Выбор профиля → CHOSEN
_wgobf_preset_pick() {  # подпись
  local names=(main) i c
  mapfile -t -O 1 names < <(wgobf_presets)
  for i in "${!names[@]}"; do
    _wgobf_preset "${names[$i]}" || continue
    echo -e "  ${C}$((i + 1)))${N} $([[ "${names[$i]}" == main ]] && echo основной || echo "${names[$i]}") ${D}$(_wgobf_preset_line)${N}"
  done
  read_choice c "${C}  ${1:-Профиль} (0 — отмена): ${N}" 0 "${#names[@]}" 0
  (( c )) || return 1
  CHOSEN="${names[$((c - 1))]}"
}

_wgobf_preset_new() {
  local name c mask=MEDIA obfb="" port
  read_line name "${C}  Имя профиля (латиница, цифры, _; до 16): ${N}"
  [[ -n "$name" ]] || return 0
  echo -e "  ${C}1)${N} MEDIA ${D}— под видеопоток RTP (форк Phobos)${N} ${C}(рекомендуется)${N}"
  echo -e "  ${C}2)${N} STUN ${D}— под видеозвонок${N}"
  echo -e "  ${C}3)${N} NONE ${D}— только XOR${N}"
  read_choice c "${C}  Маскировка [1-3] (Enter = 1): ${N}" 1 3 1
  case "$c" in 2) mask=STUN ;; 3) mask=NONE ;; esac
  if [[ "$mask" != MEDIA ]]; then
    read_line obfb "${C}  obfuscate-bytes: Enter — весь пакет (как ClusterM), или 4-1500: ${N}"
  fi
  read_line port "${C}  UDP-порт: 443 или 1024-65535 (Enter — случайный): ${N}"
  wgobf_preset_add "$name" "masking=$mask" ${obfb:+"obfb=$obfb"} ${port:+"port=$port"} || true
}

wgobf_presets_menu() {
  local c names=() i p def v name
  while true; do
    mapfile -t names < <(wgobf_presets)
    def=$(wgobf_default_preset)
    echo ""
    hdr "Профили обфускации"
    echo -e "  ${D}Профиль — свой порт, ключ и маскировка; все ведут в тот же $WGOBF_IF.${N}"
    echo -e "  ${D}Профиль клиенту задаёт только его комплект. Новые клиенты: $(_wgobf_preset_label "$def").${N}"
    _wgobf_preset main
    echo -e "  ${C}1)${N} основной ${D}$(_wgobf_preset_line)${N}"
    for i in "${!names[@]}"; do
      _wgobf_preset "${names[$i]}" || continue
      echo -e "  ${C}$((i + 2)))${N} ${names[$i]} ${D}$(_wgobf_preset_line); клиентов: $(_wgobf_preset_clients "${names[$i]}" | grep -c . || true)${N}"
    done
    echo -e "  ${C}a)${N} Новый профиль"
    echo -e "  ${C}c)${N} Профиль клиента"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Номер профиля, a или c: ${N}" 0 $(( ${#names[@]} + 1 )) 0 "a|c"
    case "$c" in
      0) return 0 ;;
      a) _wgobf_preset_new; pause; continue ;;
      c) _wgobf_pick_client && name="$CHOSEN" && _wgobf_preset_pick "Профиль для $CHOSEN" \
           && { wgobf_assign "$name" "$CHOSEN" || true; }
         pause; continue ;;
      1) p=main ;;
      *) p="${names[$((c - 2))]}" ;;
    esac
    _wgobf_preset "$p" || continue
    echo -e "  ${W}$(_wgobf_preset_label "$p")${N}: $(_wgobf_preset_line)"
    echo -e "  ${C}1)${N} Маскировка"
    echo -e "  ${C}2)${N} max-dummy"
    echo -e "  ${C}3)${N} idle-timeout"
    [[ "$p" == main ]] || echo -e "  ${C}4)${N} obfuscate-bytes"
    echo -e "  ${C}5)${N} Для новых клиентов"
    echo -e "  ${C}6)${N} Сменить ключ"
    [[ "$p" == main ]] || echo -e "  ${R}7)${N} Удалить профиль"
    read_choice c "${C}  Выбор (0 — назад): ${N}" 0 7 0
    case "$c" in
      1) if [[ "$p" == main ]]; then read_line v "${C}  STUN или NONE: ${N}"; else read_line v "${C}  MEDIA, STUN или NONE: ${N}"; fi
         [[ -n "$v" ]] && { wgobf_preset_set "$p" "masking=$v" || true; } ;;
      2) read_line v "${C}  max-dummy (0-1024): ${N}"; [[ -n "$v" ]] && { wgobf_preset_set "$p" "dummy=$v" || true; } ;;
      3) read_line v "${C}  idle-timeout, секунд (10-86400): ${N}"; [[ -n "$v" ]] && { wgobf_preset_set "$p" "idle=$v" || true; } ;;
      4) [[ "$p" == main ]] && continue
         read_line v "${C}  obfuscate-bytes: 0 — весь пакет (у MEDIA — 16), или 4-1500: ${N}"
         [[ -n "$v" ]] && { wgobf_preset_set "$p" "obfb=$v" || true; } ;;
      5) wgobf_preset_default "$p" || true ;;
      6) warn "Клиенты профиля отключатся, пока не получат новый комплект"
         read_confirm "${R}  Сменить ключ? (введи yes): ${N}" && { wgobf_rotate_key "$p" || true; } ;;
      7) [[ "$p" == main ]] && continue
         read_confirm "${R}  Удалить профиль $p? Его клиенты перейдут на основной (введи yes): ${N}" \
           && { wgobf_preset_del "$p" || true; } ;;
      *) continue ;;
    esac
    pause
  done
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
    echo -e "  ${C}5)${N} Переименовать клиента"
    echo -e "  ${C}6)${N} Статус и журнал"
    echo -e "  ${C}7)${N} Перезапустить"
    echo -e "  ${C}8)${N} Настройки"
    echo -e "  ${C}9)${N} Выход клиентов ${D}— $(_wgobf_route_label "$(wgobf_get ROUTE)")${N}"
    echo -e "  ${C}10)${N} Профили обфускации ${D}— MEDIA, obfuscate-bytes, свои порты${N}"
    echo -e "  ${R}11)${N} Удалить WG + обфускатор"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-11]: ${N}" 0 11 0
    case "$c" in
      1) read_line name "${C}  Имя клиента: ${N}"
         name="${name// /}"
         [[ -n "$name" ]] && { wgobf_add_client "$name" && wgobf_show_bundle "$name" || true; } ;;
      2) wgobf_list_clients || true ;;
      3) _wgobf_pick_client && { wgobf_show_bundle "$CHOSEN" || true; } ;;
      4) _wgobf_pick_client && read_confirm "${R}  Удалить клиента $CHOSEN? (введи yes): ${N}" \
           && { wgobf_delete_client "$CHOSEN" || true; } ;;
      5) _wgobf_pick_client && read_line name "${C}  Новое имя для $CHOSEN: ${N}" && name="${name// /}" \
           && [[ -n "$name" ]] && { wgobf_rename_client "$CHOSEN" "$name" || true; } ;;
      6) wgobf_status; journalctl -u "$WGOBF_UNIT" -n 12 --no-pager 2>/dev/null | sed 's/^/  /' || true ;;
      7) wgobf_restart && ok "Перезапущено" || true ;;
      8) wgobf_settings || true ;;
      9) wgobf_route_menu || true ;;
      10) wgobf_presets_menu || true; continue ;;
      11) wgobf_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

# awg2 --wgobf add ИМЯ [ПРОФИЛЬ] | del ИМЯ | bundle ИМЯ | rotate-key [ПРОФИЛЬ] | restart
#   | preset add|set ИМЯ ключ=значение... | preset del|default ИМЯ | assign КЛИЕНТ ПРОФИЛЬ | ipv6 on|off
wgobf_cli() {
  local cmd="${1:-}" name="${2:-}"
  wgobf_installed || { err "WG + обфускатор не установлен"; return 1; }
  case "$cmd" in
    add|del|bundle) [[ -n "$name" ]] || { err "Использование: awg2 --wgobf $cmd ИМЯ"; return 1; } ;;
    rename) [[ -n "$name" && -n "${3:-}" ]] || { err "Использование: awg2 --wgobf rename СТАРОЕ НОВОЕ"; return 1; } ;;
  esac
  case "$cmd" in
    add) wgobf_add_client "$name" "${3:-}" ;;
    del) wgobf_delete_client "$name" ;;
    rename) wgobf_rename_client "$name" "${3:-}" ;;
    bundle) grep -qxF -- "$name" <<< "$(wgobf_clients)" || { err "Клиента $name нет"; return 1; }
            wgobf_write_bundle "$name" && ok "$WGOBF_CLIENTS/$name" ;;
    rotate-key) wgobf_rotate_key "${name:-main}" ;;
    restart) wgobf_restart && ok "Перезапущено" ;;
    preset) shift 2 || true
            case "$name" in
              add) wgobf_preset_add "$@" ;; set) wgobf_preset_set "$@" ;;
              del) wgobf_preset_del "${1:-}" ;; default) wgobf_preset_default "${1:-}" ;;
              *) err "preset add|set ИМЯ ключ=значение... | preset del|default ИМЯ"; return 1 ;;
            esac ;;
    assign) wgobf_assign "$name" "${3:-}" ;;
    ipv6) wgobf_ipv6 "$name" ;;
    *) err "Команда: add ИМЯ [ПРОФИЛЬ] | del ИМЯ | rename СТАРОЕ НОВОЕ | bundle ИМЯ | rotate-key [ПРОФИЛЬ] | restart"
       err "  | preset add|set ИМЯ ключ=значение... | preset del|default ИМЯ | assign КЛИЕНТ ПРОФИЛЬ | ipv6 on|off"; return 1 ;;
  esac
}
