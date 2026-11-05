# Сеть: проверка адресов, аплинк, публичный IP, порты, домены.

# Октеты без ведущих нулей, как у портов и масок: «010.0.0.1» iptables
# отвергает, а ip_is_private (по тексту) счёл бы его публичным.
valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
}

# DNS для клиентов: IPv4 через запятую (и/или пробел), каждый — настоящий адрес:
# «999.999.999.999» иначе уходил в конфиги всех клиентов
valid_dns_list() {  # «1.1.1.1, 1.0.0.1»
  local -a a
  local d
  # Одна строка из цифр, точек, запятых и пробелов: перевод строки дописал бы в конфиг
  # клиента свои строки, а read ниже проверяет только первую
  [[ "$1" =~ ^[0-9.,\ ]+$ ]] || return 1
  IFS=', ' read -ra a <<< "$1"
  (( ${#a[@]} )) || return 1
  for d in "${a[@]}"; do valid_ip "$d" || return 1; done
}

valid_cidr() {
  [[ "$1" == */* ]] || return 1
  local mask="${1#*/}"
  valid_ip "${1%/*}" && [[ "$mask" =~ ^(0|[1-9][0-9]?)$ ]] && (( mask <= 32 ))
}

# Без ведущих нулей: «0080» и «/08» — не восьмеричные числа и не ошибка
# арифметики, а отказ; иначе такое значение легло бы в конфиги как есть.
valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
# Порт AWG и обфускатора: 1024-65535 или 443 — там, где ждут QUIC (HTTP/3).
# Остальные ниже 1024 — системные: 53 перехватывает DNS Тулзы, 123 — NTP и т.п.
awg_port_ok() { valid_port "$1" && (( $1 >= 1024 || $1 == 443 )); }

# Имя хоста (не IP): метки из букв, цифр и дефисов, минимум одна точка.
valid_domain() {
  local d="$1"
  [[ -n "$d" && ${#d} -le 253 ]] || return 1
  # Одни цифры и точки — это адрес, а не домен: и «010.0.0.1», который
  # valid_ip (без ведущих нулей) не принимает, тоже
  [[ "$d" =~ ^[0-9.]+$ ]] && return 1
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# 10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, 100.64/10 (CGNAT у хостеров).
ip_is_private() {
  local ip="$1"
  [[ "$ip" =~ ^10\. || "$ip" =~ ^192\.168\. || "$ip" =~ ^127\. || "$ip" =~ ^169\.254\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  return 1
}

# Первый интерфейс маршрута по умолчанию, не считая наших туннелей.
uplink_iface() {
  local dev
  while read -r dev; do
    [[ -n "$dev" && "$OWN_IFACES" != *" $dev "* ]] && { echo "$dev"; return 0; }
  done < <(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  return 1
}

# Публичный IPv4 сервера. Сначала адрес самого аплинка; если он приватный
# (сервер за NAT) — спрашиваем внешний сервис, прибив curl к аплинку: при
# поднятом туннеле иначе вернётся адрес туннеля.
public_ip() {
  local dev ip svc
  dev=$(uplink_iface || true)
  if [[ -n "$dev" ]]; then
    ip=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
    valid_ip "$ip" && ! ip_is_private "$ip" && { echo "$ip"; return 0; }
  fi
  for svc in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
    ip=$(curl -4 -fsS --max-time 5 ${dev:+--interface "$dev"} "$svc" 2>/dev/null || true)
    [[ -z "$ip" && -n "$dev" ]] && ip=$(curl -4 -fsS --max-time 5 "$svc" 2>/dev/null || true)
    valid_ip "$ip" && ! ip_is_private "$ip" && { echo "$ip"; return 0; }
  done
  # Сервер без выхода наружу: лучше показать локальный адрес, чем ничего
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
  valid_ip "$ip" && echo "$ip"
}

# Кэш на время одного запуска: адрес дёргается из шапки меню и генераторов.
_PUBLIC_IP=""
public_ip_cached() {
  [[ -n "$_PUBLIC_IP" ]] || _PUBLIC_IP=$(public_ip || true)
  echo "$_PUBLIC_IP"
}

# Страна сервера — флаг в шапке панели. Одному геосервису верить нельзя: по
# адресам хостеров базы расходятся (сервер в Нидерландах «оказывается» в
# Германии, у другого сервиса страна вовсе не определилась). Поэтому спрашиваем
# несколько независимых сервисов разом и берём страну, на которой сошлись
# большинство; при равенстве — тот, кто выше в списке. Все отвечают про один и
# тот же адрес сервера (Cloudflare — про адрес, с которого пришёл запрос).
# В кэше на сутки (не узнали — повтор через час), обновляется в фоне: статус
# сеть не ждёт. Формат кэша: «КОД время версия голоса» — «NL 1791500000 2 NL=4,DE=1».
#
# «имя|URL с {IP}|URL без адреса» (пусто — без адреса не спрашиваем)
COUNTRY_SOURCES=(
  "cloudflare|https://cloudflare.com/cdn-cgi/trace|https://cloudflare.com/cdn-cgi/trace"
  "ipinfo|https://ipinfo.io/{IP}/country|https://ipinfo.io/country"
  "ipapi|https://ipapi.co/{IP}/country/|https://ipapi.co/country/"
  "countryis|https://api.country.is/{IP}|https://api.country.is/"
  "geojs|https://get.geojs.io/v1/ip/country/{IP}.json|https://get.geojs.io/v1/ip/country.json"
  "ipwhois|https://ipwho.is/{IP}?fields=country_code|"
  "ifconfig|https://ifconfig.co/country-iso|https://ifconfig.co/country-iso"
)

# Страна по геосервисам (кэш) и выбранная вручную. Флаг — по ручной, если она есть:
# геобазы бывают дружно неправы (сервер в Вене, а адрес «нидерландский»).
country_auto() { awk 'NR == 1 && $1 ~ /^[A-Z][A-Z]$/ {print $1}' "$COUNTRY_CACHE" 2>/dev/null || true; }
country_manual() { awk 'NR == 1 && $1 ~ /^[A-Z][A-Z]$/ {print $1}' "$COUNTRY_MANUAL" 2>/dev/null || true; }
country_is_manual() { [[ -n "$(country_manual)" ]]; }
server_country() {
  local c
  c=$(country_manual)
  [[ -n "$c" ]] && { echo "$c"; return 0; }
  country_auto
}
# Голоса последней проверки: «NL=4,DE=1» (или пусто)
country_votes() {
  local v
  v=$(awk 'NR == 1 {print $4}' "$COUNTRY_CACHE" 2>/dev/null)
  [[ "$v" =~ ^[A-Z]{2}=[0-9]+(,[A-Z]{2}=[0-9]+)*$ ]] && echo "$v"
  return 0
}

# Страна вручную: код из двух латинских букв или auto — снова по геосервисам.
country_set() {  # КОД|auto
  local c="${1^^}" a
  if [[ "$c" == AUTO ]]; then
    rm -f "$COUNTRY_MANUAL"
    a=$(country_auto)
    log_info "страна сервера: снова по геосервисам (${a:-не определена})"
    ok "Страна сервера — по геосервисам: ${a:-пока не определена}"
    return 0
  fi
  [[ "$c" =~ ^[A-Z]{2}$ ]] || { err "Код страны — две латинские буквы (AT, NL, DE) или auto"; return 1; }
  printf '%s\n' "$c" | write_file "$COUNTRY_MANUAL" 644 || return 1
  log_info "страна сервера: $c (вручную)"
  ok "Страна сервера: $c (вручную)"
}

# Тело ответа сервиса → двухбуквенный код страны или пусто. Понимает «loc=NL»
# (Cloudflare), простой текст «NL» и JSON с полем country / country_code.
# Ошибки сервисов («Too many requests», страница HTML), XX, EU и прочие
# «не страна» отбрасываются.
country_parse() {
  local body c
  body=$(head -c 4000 | tr -d '\r')
  c=$(sed -n 's/^loc=\([A-Za-z][A-Za-z]\)$/\1/p; s/.*"country[_a-z]*"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' <<< "$body" | head -1)
  [[ -n "$c" ]] || c=$(tr -d '[:space:]' <<< "$body")
  c=${c^^}
  [[ "$c" == UK ]] && c=GB
  [[ "$c" =~ ^[A-Z]{2}$ && ! "$c" =~ ^(XX|ZZ|EU|AP|AA|QM|QZ)$ ]] && echo "$c"
  return 0
}

# Голосование: коды по одному в строке, по порядку источников → «КОД<tab>голосов»
# победителя. Побеждает страна с наибольшим числом голосов; при равенстве — та,
# что встретилась раньше (выше в списке источников). Нет ни одного кода — пусто.
country_vote() {
  awk '{ n[$1]++; if (!($1 in first)) first[$1] = NR }
       END { best = ""
             for (c in n) if (best == "" || n[c] > n[best] || (n[c] == n[best] && first[c] < first[best])) best = c
             if (best != "") printf "%s\t%d\n", best, n[best] }'
}

country_refresh() {
  local ip="" src name u1 u2 url d i=0 body code winner cnt ts prev tally
  local -a codes=() pids=()
  command -v curl &>/dev/null || return 0
  ip=$(public_ip_cached 2>/dev/null || true)
  valid_ip "$ip" && ! ip_is_private "$ip" || ip=""
  d=$(mktemp -d /tmp/awg2.country.XXXXXX) || return 0
  # Все сервисы — одновременно: ждём самого медленного, а не сумму
  for src in "${COUNTRY_SOURCES[@]}"; do
    IFS='|' read -r name u1 u2 <<< "$src"
    if [[ -n "$ip" ]]; then url="${u1//\{IP\}/$ip}"; else url="$u2"; fi
    [[ -n "$url" ]] || continue
    ( curl -4 -fsS --max-time 6 -A awg2-toolza "$url" 2>/dev/null | head -c 4000 > "$d/$(printf '%02d' "$i").$name" ) &
    pids+=("$!"); i=$((i + 1))
  done
  # Только свои запросы: чужие фоновые задачи (обновление кэшей) не ждём
  (( ${#pids[@]} )) && wait "${pids[@]}" 2>/dev/null
  # Ответы — по порядку источников (имена файлов начинаются с номера)
  for body in "$d"/*; do
    [[ -f "$body" ]] || continue
    code=$(country_parse < "$body")
    [[ -n "$code" ]] && codes+=("$code")
  done
  [[ "$d" == /tmp/awg2.country.* ]] && rm -rf "$d"
  ts=$(date +%s); prev=$(country_auto); winner=""
  if (( ${#codes[@]} )); then
    IFS=$'\t' read -r winner cnt < <(printf '%s\n' "${codes[@]}" | country_vote)
    tally=$(printf '%s\n' "${codes[@]}" | sort | uniq -c | sort -k1,1nr -k2 | awk '{printf "%s%s=%s", s, $2, $1; s=","}')
    # Два и больше ответа, а двух одинаковых нет: «большинства» нет — прежняя
    # страна не перебивается случайным ответом одного сервиса
    if (( ${#codes[@]} > 1 && cnt < 2 )) && [[ -n "$prev" ]]; then winner=""; fi
  fi
  if [[ "$winner" =~ ^[A-Z]{2}$ ]]; then
    # Кто за кого — в журнал (при смене страны) и в кэш: видно, если сервисы расходятся
    [[ "$winner" == "$prev" ]] || log_info "страна сервера: $winner (голоса: $tally)"
    printf '%s %s 2 %s\n' "$winner" "$ts" "$tally" | write_file "$COUNTRY_CACHE" 644
    return 0
  fi
  # Не ответили (или не сошлись): прежняя страна остаётся (флаг не пропадает на
  # час из-за одного сбоя), метка сдвинута так, чтобы повтор был через час
  winner="$prev"; ts=$(( ts - 86400 + 3600 ))
  [[ -n "$winner" ]] || { winner="-"; ts=$(date +%s); }
  printf '%s %s 2\n' "$winner" "$ts" | write_file "$COUNTRY_CACHE" 644
}

country_refresh_async() {
  local cc="" ts=0 ver="" ttl=86400
  [[ -n "${AWG_NO_UPDATE_CHECK:-}" ]] && return 0
  read -r cc ts ver _ 2>/dev/null < "$COUNTRY_CACHE" || true
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  [[ "$cc" =~ ^[A-Z]{2}$ ]] || ttl=3600
  # Кэш прежнего формата (один сервис, без голосования) — пересчитать сразу
  [[ "$ver" == 2 ]] || ttl=0
  (( $(date +%s) - ts < ttl )) && return 0
  ( country_refresh ) </dev/null >/dev/null 2>&1 3>&- 4>&- 8>&- &
  disown 2>/dev/null || true
}

udp_listening() { ss -lunH "sport = :$1" 2>/dev/null | grep -q .; }

# Занят ли UDP-порт кем угодно из известных: сокет, AWG, каскад, обфускатор.
udp_port_busy() {
  local p="$1"
  valid_port "$p" || return 0
  udp_listening "$p" && return 0
  [[ "$(conf_iface_get ListenPort)" == "$p" ]] && return 0
  grep -qE "^udp\|${p}\|" "$CASCADE_RULES" 2>/dev/null && return 0
  wgobf_owns_port "$p" && return 0
  return 1
}

random_free_udp_port() {
  local p i avoid="${1:-}"
  for i in {1..40}; do
    p=$(rand_range 30001 65535)
    [[ "$p" == "$avoid" ]] && continue
    udp_port_busy "$p" || { echo "$p"; return 0; }
  done
  return 1
}

# Сверяет A-запись домена с IP сервера. Не запрет, а предупреждение:
# DNS могли ещё не прописать.
domain_points_here() {
  local d="$1" ips srv
  ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z "$ips" ]]; then
    warn "Домен $d не резолвится с этого сервера"
    return 1
  fi
  srv=$(public_ip_cached)
  if [[ -n "$srv" && " $ips" != *" $srv "* ]]; then
    warn "Домен ведёт на ${ips% }, а IP сервера — $srv"
    info "Нужна прямая A-запись на IP сервера (без прокси Cloudflare)"
    return 1
  fi
  ok "Домен ведёт на этот сервер (${ips% })"
}

# Доходит ли трафик через SOCKS5. Настоящий запрос наружу: прокси может
# принимать соединения и никуда их не отправлять. В stdout — код ответа.
socks_probe() {
  local addr="$1" code opt
  command -v curl &>/dev/null || return 0
  for opt in --socks5-hostname --socks5; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$opt" "$addr" \
             http://cp.cloudflare.com/generate_204 2>/dev/null || true)
    [[ "$code" == 204 || "$code" == 200 ]] && return 0
  done
  echo "${code:-нет ответа}"
  return 1
}

# Внешний IP через интерфейс (проверка туннеля). Пусто — трафик не идёт.
iface_egress_ip() {
  curl -4 -fsS --max-time "${2:-6}" --interface "$1" https://api.ipify.org 2>/dev/null || true
}

# Все адреса и маршруты сервера — для выбора подсети без пересечений.
# Адреса туннелей добавлены явно: пока туннель выключен, их в системе нет.
taken_networks() {
  ip -4 -o addr show 2>/dev/null || true
  ip -4 route show table all 2>/dev/null || true
  conf_iface_get Address
  echo "$T2S_ADDR 172.16.0.0/24 $XRAY_TUN_ADDR"
}
