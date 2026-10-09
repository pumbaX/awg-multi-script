# Система: проверка ОС, пакеты, systemd, sysctl, iptables, UFW.

# ── ОС ────────────────────────────────────────────────────
# Поддерживаются Ubuntu 24.04+ и Debian 12+. На них проверена сборка модуля
# через DKMS, наличие нужных заголовков ядра и поведение iptables (nft).
OS_ID="" OS_VER="" OS_CODENAME="" OS_LABEL=""

os_detect() {
  [[ -n "$OS_ID" ]] && return 0
  [[ -r /etc/os-release ]] || return 1
  # В os-release свой VERSION — читаем его только в подоболочке
  # shellcheck source=/dev/null
  IFS='|' read -r OS_ID OS_VER OS_CODENAME < <(. /etc/os-release \
    && printf '%s|%s|%s\n' "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}")
  OS_LABEL="${OS_ID^} ${OS_VER:-${OS_CODENAME:-?}}"
  [[ -n "$OS_CODENAME" && -n "$OS_VER" ]] && OS_LABEL+=" ($OS_CODENAME)"
  return 0
}

# 0 — поддерживается; 1 — нет (причина в stdout).
os_supported() {
  os_detect || { echo "не удалось прочитать /etc/os-release"; return 1; }
  local major="${OS_VER%%.*}"
  case "$OS_ID" in
    ubuntu)
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 24 )) && return 0
      echo "$OS_LABEL — нужна Ubuntu 24.04 или новее"
      ;;
    debian)
      # testing/sid живут без VERSION_ID — это заведомо новее 12
      [[ -z "$OS_VER" ]] && return 0
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 12 )) && return 0
      echo "$OS_LABEL — нужен Debian 12 или новее"
      ;;
    *) echo "$OS_LABEL — поддерживаются только Ubuntu 24.04+ и Debian 12+" ;;
  esac
  return 1
}

# ── Пакеты ────────────────────────────────────────────────
APT_LAST_OUTPUT=""

# apt-get install с одной повторной попыткой после обновления индексов:
# на давно не обновлявшемся сервере первый отказ — 404 на .deb из старого индекса.
apt_install() {
  local rc=0
  export DEBIAN_FRONTEND=noninteractive
  APT_LAST_OUTPUT=$(apt-get install -y -q "$@" 2>&1) || rc=$?
  (( rc == 0 )) && return 0
  apt-get update -q >/dev/null 2>&1 || true
  rc=0
  APT_LAST_OUTPUT=$(apt-get install -y -q "$@" 2>&1) || rc=$?
  return "$rc"
}

apt_errors() { printf '%s\n' "$APT_LAST_OUTPUT" | grep -E '^E:' | head -3 | sed 's/^/      /' || true; }

# need_cmds "команда:пакет" ... — ставит пакеты для отсутствующих команд.
need_cmds() {
  local pair missing=()
  for pair in "$@"; do
    command -v "${pair%%:*}" &>/dev/null || missing+=("${pair#*:}")
  done
  (( ${#missing[@]} == 0 )) && return 0
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  info "Ставлю пакеты: ${missing[*]}"
  if ! apt_install "${missing[@]}"; then
    err "Не удалось установить: ${missing[*]}"
    apt_errors
    return 1
  fi
}

# Пакеты заголовков для ядра $1 в порядке предпочтения. Точный пакет под
# работающее ядро есть почти всегда; мета-пакеты — на случай облачных ядер,
# у которых точный пакет уже убран из зеркала.
headers_candidates() {
  local k="$1" arch flavor
  echo "linux-headers-$k"
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  os_detect
  if [[ "$OS_ID" == debian ]]; then
    [[ "$k" == *-cloud-* ]] && echo "linux-headers-cloud-$arch"
    echo "linux-headers-$arch"
  else
    flavor="${k##*-}"
    [[ "$flavor" =~ ^[a-z]+$ ]] && echo "linux-headers-$flavor"
    echo "linux-headers-generic"
  fi
}

# Ставит заголовки под ядро $1. 0 — каталог build для него появился.
ensure_headers() {
  local k="$1" pkg
  [[ -d "/lib/modules/$k/build" ]] && return 0
  while read -r pkg; do
    apt_install "$pkg" >/dev/null 2>&1 || continue
    [[ -d "/lib/modules/$k/build" ]] && return 0
  done < <(headers_candidates "$k")
  [[ -d "/lib/modules/$k/build" ]]
}

# Установленные ядра (есть vmlinuz), от старых к новым — по версии, не по алфавиту.
installed_kernels() {
  local k
  for k in /lib/modules/*/; do
    k=${k%/}; k=${k##*/}
    [[ -e "/boot/vmlinuz-$k" ]] && echo "$k"
  done | sort -V
}

secure_boot_on() {
  command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled
}

# ── systemd ───────────────────────────────────────────────
unit_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

# write_unit ИМЯ < содержимое — пишет /etc/systemd/system/ИМЯ и перечитывает.
write_unit() {
  write_file "/etc/systemd/system/$1" 644 && systemctl daemon-reload
}

# Таймер в состоянии «active (elapsed)» больше не сработает никогда, хотя
# is-active отвечает «active». Так глох таймер сроков и лимитов (v1.2.0-1.2.2):
# с Persistent=true systemd при старте таймера берёт время прошлого запуска
# из метки в /var/lib/systemd/timers, считает OnBootSec прошедшим, а
# OnUnitActiveSec отсчитывать не от чего — служба после переустановки ещё не
# запускалась. Такой таймер — перезапустить без метки: сработает сразу,
# дальше по расписанию.
timer_heal() {
  local u st
  for u in "$@"; do
    st=$(systemctl show -p SubState --value "$u" 2>/dev/null)
    [[ "$st" == waiting || "$st" == running ]] && continue
    rm -f "/var/lib/systemd/timers/stamp-$u"
    systemctl restart "$u" &>/dev/null || true
  done
}

remove_unit() {
  local u
  for u in "$@"; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u" "/var/lib/systemd/timers/stamp-$u"
  done
  systemctl daemon-reload 2>/dev/null || true
}

# ── sysctl ────────────────────────────────────────────────
# net.ipv4.ip_forward=1 сейчас и после перезагрузки. В Ubuntu 26.04 нет
# /etc/sysctl.conf — пишем drop-in, но уважаем строку, если она уже там.
ip_forward_enable() {
  local re='^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1'
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  grep -qsE "$re" /etc/sysctl.conf /etc/sysctl.d/*.conf && return 0
  echo "net.ipv4.ip_forward=1" | write_file "$SYSCTL_FORWARD_FILE" 644
}

rp_filter_loose() {
  local dev
  for dev in "$@"; do sysctl -qw "net.ipv4.conf.${dev}.rp_filter=2" >/dev/null 2>&1 || true; done
}

# ── iptables ──────────────────────────────────────────────
# ipt_add [-t табл] ЦЕПЬ правило... — добавить в конец, если такого нет.
ipt_add() {
  local t=filter
  [[ "$1" == -t ]] && { t="$2"; shift 2; }
  local chain="$1"; shift
  iptables -t "$t" -C "$chain" "$@" 2>/dev/null || iptables -t "$t" -A "$chain" "$@"
}

# ipt_ins — то же, но вставить первым (для ACCEPT перед чужими DROP).
ipt_ins() {
  local t=filter
  [[ "$1" == -t ]] && { t="$2"; shift 2; }
  local chain="$1"; shift
  iptables -t "$t" -C "$chain" "$@" 2>/dev/null || iptables -t "$t" -I "$chain" 1 "$@"
}

# ipt_del — удалить все копии правила.
ipt_del() {
  local t=filter guard=0
  [[ "$1" == -t ]] && { t="$2"; shift 2; }
  local chain="$1"; shift
  while (( guard++ < 64 )) && iptables -t "$t" -D "$chain" "$@" 2>/dev/null; do :; done
  return 0
}

# Удалить все правила таблицы с комментарием, начинающимся с $2.
# iptables-save выдаёт правило одной строкой (iptables -S на nft-бэкенде
# длинные правила переносит). Комментарий с символами вне [A-Za-z0-9_-]
# (например «awg-cascade:udp-443») он берёт в кавычки — поэтому строку
# разбирает xargs, который кавычки понимает, а не word splitting.
ipt_del_tagged() { ipt_del_grep "$1" "--comment \"?${2}"; }

# Удалить все правила таблицы $1, строка которых в iptables-save
# совпадает с расширенным регулярным выражением $2.
ipt_del_grep() {
  local t="$1" re="$2" rule
  while IFS= read -r rule; do
    printf '%s\n' "${rule/#-A /-D }" | xargs iptables -t "$t" 2>/dev/null || true
  done < <(iptables-save -t "$t" 2>/dev/null | grep -E -- "^-A .*${re}" || true)
}

# ── UFW ───────────────────────────────────────────────────
ufw_active() { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]*active'; }

ufw_allow() {  # порт/протокол комментарий
  ufw_active || return 0
  ufw allow "$1" comment "$2" >/dev/null 2>&1
}

# Снять правила UFW с комментарием ровно $1. ufw_delete_matching ищет подстроку —
# «awg-web» (веб-панель) задевал и «awg-webapp» (порт Mini App).
ufw_delete_comment() {
  command -v ufw &>/dev/null || return 0
  local n guard=0
  while (( guard++ < 64 )); do
    n=$(ufw status numbered 2>/dev/null | awk -v c="$1" '{
          s = $0; sub(/[ \t]+$/, "", s); i = index(s, "# ")
          if (i && substr(s, i + 2) == c && match(s, /^\[ *[0-9]+ *\]/)) {
            n = substr(s, 2, RLENGTH - 2); gsub(/ /, "", n); print n; exit } }')
    [[ -n "$n" ]] || break
    ufw --force delete "$n" >/dev/null 2>&1 || break
  done
}

# Снять все правила UFW, в комментарии которых есть $1.
ufw_delete_matching() {
  command -v ufw &>/dev/null || return 0
  local n guard=0
  while (( guard++ < 64 )); do
    n=$(ufw status numbered 2>/dev/null | grep -F -- "$1" | head -1 | grep -oE '^\[ *[0-9]+ *\]' | tr -d '[] ')
    [[ -n "$n" ]] || break
    ufw --force delete "$n" >/dev/null 2>&1 || break
  done
}
