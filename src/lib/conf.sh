# Конфиг сервера awg0.conf и файлы клиентов.
#
# Шапка awg0.conf — служебные метки «# КЛЮЧ=значение» до секции [Interface].
# Их читает и Telegram-бот, поэтому имена меток не меняются:
#   AWG_PROFILE     lite | pro | standard (устаревший)
#   AWG_PROTO       2.0 | 3.0 | 3.1 (нет метки — 2.0)
#   AWG_OBF_LEVEL   1 — без I1-I5, 2 — только I1, 3 — полная цепочка
#   AWG_MIMICRY     профиль мимикрии или none
#   AWG_MIMICRY_DOMAIN, AWG_CPS_BUDGET, AWG_ENDPOINT
#   Region: ru | world (метка с двоеточием — из самых первых версий)

# Ключи параметров AmneziaWG, которые клиент обязан получить от сервера.
AWG_PARAM_KEYS_RE="(Jc|Jmin|Jmax|S[1-4]|H[1-4]|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)"
AWG3_KEYS_RE="(HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)"
AWG31_KEYS_RE="(RandomTrailers|DisableCookies)"

server_exists() { [[ -f "$SERVER_CONF" ]]; }
iface_up() { ip link show "$AWG_IF" &>/dev/null; }

# ── Метки шапки ───────────────────────────────────────────
conf_marker() {
  [[ -f "$SERVER_CONF" ]] || return 0
  awk -v k="$1" '
    /^\[/ { exit }
    index($0, "# " k "=") == 1 { print substr($0, length(k) + 4); exit }
  ' "$SERVER_CONF"
}

conf_marker_set() {
  local key="$1" val="$2"
  [[ -f "$SERVER_CONF" ]] || return 1
  conf_marker_del "$key"
  [[ -n "$val" ]] || return 0
  # Метка — в шапке перед первой секцией. «1a» ставила бы её на вторую
  # строку, а если файл начинается с [Interface] — внутрь секции, где
  # conf_marker её не видит.
  val="${val//\\/\\\\}"; val="${val//&/\\&}"; val="${val//|/\\|}"
  if grep -q '^\[' "$SERVER_CONF"; then
    sed -i "0,/^\[/s|^\[|# ${key}=${val}\n[|" "$SERVER_CONF"
  else
    echo "# ${key}=${val}" >> "$SERVER_CONF"
  fi
}

conf_marker_del() { [[ -f "$SERVER_CONF" ]] && sed -i "/^# ${1}=/d" "$SERVER_CONF"; return 0; }

# ── [Interface] ───────────────────────────────────────────
# conf_iface_get КЛЮЧ [файл] — значение из секции [Interface].
conf_iface_get() {
  local f="${2:-$SERVER_CONF}"
  [[ -f "$f" ]] || return 0
  awk -v k="$1" '
    /^\[Interface\]/ { s = 1; next }
    /^\[/ { s = 0 }
    s && $0 ~ "^" k "[ \t]*=" { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }
  ' "$f"
}

# Параметры AmneziaWG сервера построчно («Ключ = значение»).
server_params() {
  [[ -f "$SERVER_CONF" ]] || return 0
  sed -n '/^\[Peer\]/q; p' "$SERVER_CONF" | grep -E "^${AWG_PARAM_KEYS_RE}[[:space:]]*=" || true
}

# Версия протокола: метка, а без неё — по ключам (метку могли потерять правкой).
server_proto() {
  local p
  p=$(conf_marker AWG_PROTO)
  if [[ -z "$p" ]]; then
    if server_params | grep -qE "^${AWG31_KEYS_RE}"; then p=3.1
    elif server_params | grep -qE "^${AWG3_KEYS_RE}"; then p=3.0
    else p=2.0; fi
  fi
  echo "$p"
}

server_profile() { local p; p=$(conf_marker AWG_PROFILE); echo "${p:-pro}"; }

profile_label() {
  case "${1:-$(server_profile)}" in
    lite) echo "AmneziaVPN" ;;
    pro) echo "Мощный" ;;
    standard) echo "Standard (устаревший)" ;;
    *) echo "${1:-—}" ;;
  esac
}

server_region() {
  local r
  r=$(awk '/^\[/{exit} /^#[ \t]*Region:/{sub(/^#[ \t]*Region:[ \t]*/, ""); print; exit}' "$SERVER_CONF" 2>/dev/null)
  echo "${r:-world}"
}

server_port() { conf_iface_get ListenPort | tr -dc '0-9'; }

# Подсеть клиентов (10.x.y.0/24) из Address сервера — для любого префикса.
server_net() {
  local addr ip mask a b c d n m
  addr=$(conf_iface_get Address)
  addr="${addr%%,*}"
  valid_cidr "$addr" || return 1
  ip="${addr%/*}"; mask="${addr#*/}"
  IFS=. read -r a b c d <<< "$ip"
  n=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
  m=$(( 10#$mask == 0 ? 0 : (0xFFFFFFFF << (32 - 10#$mask)) & 0xFFFFFFFF ))
  n=$(( n & m ))
  echo "$(( n >> 24 & 255 )).$(( n >> 16 & 255 )).$(( n >> 8 & 255 )).$(( n & 255 ))/$mask"
}

# Endpoint для клиентов: домен из метки, иначе публичный IP.
endpoint_domain() {
  local d
  d=$(conf_marker AWG_ENDPOINT)
  valid_domain "$d" && echo "$d"
  return 0
}

endpoint_host() {
  local d
  d=$(endpoint_domain)
  if [[ -n "$d" ]]; then echo "$d"; else public_ip_cached; fi
}

# ── Клиенты ───────────────────────────────────────────────
# Имена: латиница, цифры, _ и -. Знак «=» запрещён — по нему служебные
# метки отличаются от имени клиента.
valid_client_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

client_suffix() { [[ "$(server_proto)" == 3* ]] && echo _awg3 || echo _awg2; }

# Путь к конфигу клиента: существующий файл любой версии, иначе новый.
client_file() {
  local f
  for f in "$CLIENT_DIR/${1}_awg3.conf" "$CLIENT_DIR/${1}_awg2.conf"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  echo "$CLIENT_DIR/${1}$(client_suffix).conf"
}

client_name_of() { local b="${1##*/}"; echo "${b%_awg[23].conf}"; }

client_files() {
  local f
  for f in "$CLIENT_DIR"/*_awg[23].conf; do [[ -f "$f" ]] && echo "$f"; done
  return 0
}

# Суффиксы файлов — под текущую версию протокола (после смены версии/рестора).
client_files_sync_suffix() {
  server_exists || return 0
  local want f t
  want=$(client_suffix)
  while read -r f; do
    [[ "$f" == *"${want}.conf" ]] && continue
    t="$CLIENT_DIR/$(client_name_of "$f")${want}.conf"
    [[ -e "$t" ]] || mv -f "$f" "$t"
  done < <(client_files)
}

# Клиенты сервера: строки «имя<TAB>ключ<TAB>AllowedIPs<TAB>expires<TAB>orig_ips<TAB>mimicry
# <TAB>limit<TAB>blocked_by».
clients_tsv() { server_exists || return 0; py peers "$SERVER_CONF"; }
# То же через «|»: табуляция для read — пробельный разделитель, подряд идущие
# табы схлопываются, и пустые колонки (срок, orig_ips) сдвигают соседние.
clients_psv() { clients_tsv | tr '\t' '|'; }

# «имя|ip» для меню туннелей — только клиенты с именем. У заблокированного
# AllowedIPs — адрес-заглушка, настоящий лежит в orig_ips: без этого
# peers_sync выкидывал его из списков WARP/Xray/exit, и после разблокировки
# клиент шёл мимо туннеля.
clients_name_ip() {
  local name aip orig _
  while IFS='|' read -r name _ aip _ orig _; do
    [[ -n "$orig" ]] && aip="$orig"
    [[ -n "$name" && -n "$aip" ]] || continue
    echo "${name}|${aip%%/*}"
  done < <(clients_psv)
}

client_exists() { clients_tsv | awk -F'\t' -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

peer_meta_get() {  # имя ключ
  clients_tsv | awk -F'\t' -v n="$1" -v k="$2" '
    BEGIN { col["expires"] = 4; col["orig_ips"] = 5; col["mimicry"] = 6; col["limit"] = 7; col["blocked_by"] = 8 }
    $1 == n { print $(col[k]); exit }'
}

peer_meta_set() { py meta-set "$SERVER_CONF" "$1" "$2" "${3:-}"; }

# Первый свободный адрес клиента в /24 сервера.
free_client_ip() {
  local net base i srv used
  net=$(server_net) || return 1
  base="${net%.*}"
  srv=$(conf_iface_get Address); srv="${srv%%/*}"
  used=" $(clients_tsv | awk -F'\t' '{print $3; print $5}' | tr ',' '\n' | sed 's#/.*##; s/ //g' | tr '\n' ' ') "
  for i in $(seq 2 254); do
    [[ "$base.$i" == "$srv" || "$used" == *" $base.$i "* ]] && continue
    echo "$base.$i/32"
    return 0
  done
  return 1
}

# Применить изменения пиров без обрыва остальных; при неудаче — перезапуск.
server_apply() {
  local stripped
  if stripped=$(awg-quick strip "$AWG_IF" 2>/dev/null) && [[ -n "$stripped" ]]; then
    awg syncconf "$AWG_IF" <(printf '%s\n' "$stripped") 2>/dev/null && return 0
  fi
  server_restart >/dev/null
}

server_restart() {
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  awg_up_diag
}
