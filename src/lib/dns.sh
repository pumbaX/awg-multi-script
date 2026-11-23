# Шифрованный DNS: dnscrypt-proxy на 127.0.2.1:53 (systemd-сокет пакета
# Debian/Ubuntu), DNS-запросы клиентов перехватываются DNAT'ом с awg0 и wgobf0
# (WG + обфускатор) и уходят наружу по DoH. DNS в конфигах клиентов не
# меняется — перехват прозрачный. Правила на wgobf0 ставятся и без него:
# iptables не требует интерфейса, обфускатор поднимут — перехват уже на месте.
#
# DoT (853) режется в mangle PREROUTING, а не в FORWARD: PostUp сервера
# вставляет «FORWARD -i awg0 -j ACCEPT» первым правилом при каждом подъёме
# awg0, и DROP ниже него никогда не срабатывал бы.

DNS_TAG="awg2-dns"
DNS_UNIT="dnscrypt-proxy.service"
DNS_SOCKET="dnscrypt-proxy.socket"
DNS_PRESETS=(
  "cloudflare google cisco-doh|Cloudflare + Google + Cisco (рекомендуется)"
  "cloudflare|Только Cloudflare"
  "yandex-safe|Яндекс Safe (фильтрующий)"
  "cisco-doh|Только Cisco OpenDNS"
  "google|Только Google"
)
# Подсказка к «Вручную»: только DoH по IPv4 — других этот dnscrypt-proxy не берёт
# (dnscrypt_servers = false, ipv6_servers = false)
DNS_POPULAR=(
  "cloudflare|Cloudflare 1.1.1.1"
  "google|Google 8.8.8.8"
  "quad9-doh-ip4-port443-nofilter-pri|Quad9 без фильтра"
  "adguard-dns-doh|AdGuard — режет рекламу и трекеры"
  "adguard-dns-unfiltered-doh|AdGuard без фильтра"
  "mullvad-doh|Mullvad"
  "controld-uncensored|Control D без фильтра"
  "dns.sb|DNS.SB"
  "yandex|Яндекс 77.88.8.1"
  "cloudflare-family|Cloudflare Family — без вредоносных и 18+"
)

dns_installed() { command -v dnscrypt-proxy &>/dev/null && [[ -f "$DNS_PROXY_STATE" ]]; }
dns_running()   { unit_active "$DNS_UNIT" || unit_active "$DNS_SOCKET"; }

# Интерфейсы клиентов, чей DNS перехватывается
dns_ifaces() { echo "$AWG_IF" "$WGOBF_IF"; }

dns_resolves() {
  command -v dig &>/dev/null || return 0
  timeout 4 dig "@$DNS_PROXY_ADDR" -p "$DNS_PROXY_PORT" cloudflare.com +short +tries=1 +time=2 2>/dev/null \
    | grep -qE '^[0-9]+\.'
}

dns_state_line() {
  if ! dns_installed; then echo -e "${D}○ не настроен${N}"
  elif dns_running; then echo -e "${G}● включён${N}"
  else echo -e "${R}▲ настроен, служба не работает${N}"; fi
}

# ── Правила ───────────────────────────────────────────────
# Работают и в служебных скриптах (emit_script).
dns_rules_up() {
  local p i to="$DNS_PROXY_ADDR:$DNS_PROXY_PORT"
  # DNAT в 127.0.0.0/8 ядро пропускает только с route_localnet (all — для всех интерфейсов)
  sysctl -qw net.ipv4.conf.all.route_localnet=1 2>/dev/null || true
  for i in $(dns_ifaces); do
    for p in udp tcp; do
      ipt_add -t nat PREROUTING -i "$i" -p "$p" --dport 53 -j DNAT --to-destination "$to" -m comment --comment "$DNS_TAG"
      ipt_ins INPUT -i "$i" -d "$DNS_PROXY_ADDR" -p "$p" --dport "$DNS_PROXY_PORT" -j ACCEPT -m comment --comment "$DNS_TAG"
      ipt_add -t mangle PREROUTING -i "$i" -p "$p" --dport 853 -j DROP -m comment --comment "$DNS_TAG"
    done
  done
}

# Снимает и правила прежних версий — они ставились без метки.
dns_rules_down() {
  local t p to="$DNS_PROXY_ADDR:$DNS_PROXY_PORT"
  for t in nat filter mangle; do ipt_del_tagged "$t" "$DNS_TAG"; done
  for p in udp tcp; do
    ipt_del -t nat PREROUTING -i "$AWG_IF" -p "$p" --dport 53 -j DNAT --to-destination "$to"
    ipt_del -t nat PREROUTING -i "$AWG_IF" -p "$p" --dport 53 -j DNAT --to-destination 127.0.0.1:5300
    ipt_del INPUT -i "$AWG_IF" -d "$DNS_PROXY_ADDR" -p "$p" --dport "$DNS_PROXY_PORT" -j ACCEPT
    ipt_del FORWARD -i "$AWG_IF" -p "$p" --dport 853 -j DROP
  done
  if command -v ip6tables &>/dev/null; then
    for p in "udp 53" "tcp 53" "tcp 853"; do
      while ip6tables -D FORWARD -i "$AWG_IF" -p "${p% *}" --dport "${p#* }" -j DROP 2>/dev/null; do :; done
    done
  fi
}

# Перехват на месте на всех интерфейсах клиентов (после обновления со старой
# версии правил wgobf0 нет — сторож их доставит)
dns_rules_ok() {
  local i
  for i in $(dns_ifaces); do
    iptables -t nat -C PREROUTING -i "$i" -p udp --dport 53 -j DNAT \
      --to-destination "$DNS_PROXY_ADDR:$DNS_PROXY_PORT" -m comment --comment "$DNS_TAG" 2>/dev/null || return 1
  done
}

# UFW: вход к dnscrypt-proxy с интерфейсов клиентов (ufw allow не дублирует)
dns_ufw_allow() {
  local i p
  ufw_active || return 0
  for i in $(dns_ifaces); do
    for p in udp tcp; do
      ufw allow in on "$i" to "$DNS_PROXY_ADDR" port "$DNS_PROXY_PORT" proto "$p" comment "$DNS_TAG" &>/dev/null || true
    done
  done
}

# Точка входа awg-dns-persist.service: ждёт awg0 и ставит правила.
dns_persist_run() {
  local i
  for i in $(seq 1 30); do ip link show "$AWG_IF" &>/dev/null && break; sleep 2; done
  ip link show "$AWG_IF" &>/dev/null || { echo "awg-dns-persist: $AWG_IF не появился за 60 с" >&2; exit 1; }
  dns_rules_up
}

# Точка входа таймера awg-dns-healthcheck.
dns_health_run() {
  local ts
  ts=$(date '+%F %T')
  if ! systemctl is-active --quiet dnscrypt-proxy.service && ! systemctl is-active --quiet dnscrypt-proxy.socket; then
    echo "[$ts] FAIL: dnscrypt-proxy не работает — перезапускаю" >> "$DNS_HEALTH_LOG"
    systemctl restart dnscrypt-proxy.socket dnscrypt-proxy.service 2>/dev/null || true
  fi
  if command -v dig >/dev/null && ! timeout 4 dig "@$DNS_PROXY_ADDR" -p "$DNS_PROXY_PORT" cloudflare.com \
      +short +tries=1 +time=2 2>/dev/null | grep -qE '^[0-9]+\.'; then
    echo "[$ts] FAIL: резолв через $DNS_PROXY_ADDR не отвечает" >> "$DNS_HEALTH_LOG"
  fi
  if ip link show "$AWG_IF" &>/dev/null && ! dns_rules_ok; then
    echo "[$ts] FAIL: правила перехвата пропали — восстанавливаю" >> "$DNS_HEALTH_LOG"
    dns_rules_up
  fi
  return 0
}

_dns_emit_helpers() {
  local common=(AWG_IF WGOBF_IF DNS_TAG DNS_PROXY_ADDR DNS_PROXY_PORT ipt_add ipt_ins dns_ifaces dns_rules_up dns_rules_ok)
  emit_script "$DNS_PERSIST_SCRIPT" 'dns_persist_run' "${common[@]}" dns_persist_run || return 1
  emit_script "$DNS_HEALTH_SCRIPT" 'dns_health_run' "${common[@]}" DNS_HEALTH_LOG dns_health_run || return 1
  write_unit awg-dns-persist.service <<EOF
[Unit]
Description=AWG Toolza — перехват DNS клиентов в dnscrypt-proxy
After=network-online.target awg-quick@awg0.service $DNS_UNIT
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DNS_PERSIST_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  write_unit awg-dns-healthcheck.service <<EOF
[Unit]
Description=AWG Toolza — проверка шифрованного DNS
After=$DNS_UNIT

[Service]
Type=oneshot
ExecStart=$DNS_HEALTH_SCRIPT
EOF
  write_unit awg-dns-healthcheck.timer <<'EOF'
[Unit]
Description=AWG Toolza — проверка шифрованного DNS раз в 2 минуты

[Timer]
OnBootSec=60
OnUnitActiveSec=120

[Install]
WantedBy=timers.target
EOF
  systemctl enable awg-dns-persist.service &>/dev/null
  systemctl enable --now awg-dns-healthcheck.timer &>/dev/null
}

_dns_write_conf() {
  write_file "$DNS_PROXY_CONF" 644 <<EOF
# AWG Toolza — шифрованный DNS для клиентов AWG.
# Слушает ${DNS_PROXY_ADDR}:${DNS_PROXY_PORT} через systemd-сокет пакета, поэтому
# listen_addresses пуст: свой адрес конфликтовал бы с сокетом.
listen_addresses = []

server_names = ['cloudflare', 'google', 'cisco-doh']
require_dnssec = true
require_nolog = true
require_nofilter = true
dnscrypt_servers = false
doh_servers = true
ipv4_servers = true
ipv6_servers = false

cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
timeout = 5000
keepalive = 30

[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 73
    prefix = ''
EOF
  mkdir -p /var/cache/dnscrypt-proxy
  chown -R _dnscrypt-proxy:_dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null \
    || chown -R nobody:nogroup /var/cache/dnscrypt-proxy 2>/dev/null || true
}

_dns_wait_ready() {
  local i
  for i in $(seq 1 15); do
    dns_running && dns_resolves && return 0
    sleep 1
  done
  return 1
}

dns_install() {  # [force] — включить поверх стороннего DNS-сервиса
  local busy
  server_exists && iface_up || { err "Сначала создай и запусти сервер"; return 1; }
  # Сторонний DNS на 53/853 (Pi-hole, Unbound, bind) — перехват уведёт клиентов мимо него
  busy=$(ss -Htulpn 2>/dev/null | awk '$5 ~ /:(53|853)$/' | grep -vE '127\.0\.0\.5[34]|127\.0\.2\.1|127\.0\.0\.1' | head -3 || true)
  if [[ -n "$busy" && "${1:-}" != force ]]; then
    warn "На сервере уже работает DNS-сервис:"
    sed 's/^/    /' <<< "$busy"
    if ! ask_yes "  Всё равно включить перехват? [y/N]: " n; then
      (( AUTO_MODE )) && { err "Порт 53/853 занят другим DNS — перехват не включён"; return 1; }
      return 0
    fi
  fi
  need_cmds dnscrypt-proxy:dnscrypt-proxy dig:dnsutils || return 1
  if [[ -f "$DNS_PROXY_CONF" && ! -f "$DNS_PROXY_BACKUP_CONF" ]]; then
    cp -a "$DNS_PROXY_CONF" "$DNS_PROXY_BACKUP_CONF"
  fi
  systemctl stop "$DNS_UNIT" &>/dev/null || true
  _dns_write_conf
  systemctl daemon-reload
  systemctl enable "$DNS_SOCKET" "$DNS_UNIT" &>/dev/null || true
  # после череды падений systemd не даёт запустить службу («start request repeated too quickly»)
  systemctl reset-failed "$DNS_UNIT" &>/dev/null || true
  systemctl restart "$DNS_SOCKET" "$DNS_UNIT" &>/dev/null || true
  info "Жду, пока загрузятся резолверы..."
  if ! _dns_wait_ready; then
    err "dnscrypt-proxy не отвечает на $DNS_PROXY_ADDR:$DNS_PROXY_PORT"
    info "С некоторых хостингов DoH Cloudflare недоступен — попробуй другие резолверы"
    journalctl -u "$DNS_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  dns_rules_down
  dns_rules_up
  dns_ufw_allow
  echo "net.ipv4.conf.all.route_localnet=1" | write_file "$DNS_SYSCTL" 644
  _dns_emit_helpers || return 1
  printf 'enabled=true\naddr=%s\nport=%s\ninstalled_at=%s\n' "$DNS_PROXY_ADDR" "$DNS_PROXY_PORT" "$(date +%s)" \
    | write_file "$DNS_PROXY_STATE" 644
  ok "Шифрованный DNS включён: запросы клиентов (AWG и WG + обфускатор) идут по DoH, DoT (853) закрыт"
  info "Проверка с клиента: https://1.1.1.1/help → «Using DNS over HTTPS: Yes»"
  log_info "dnscrypt-proxy включён"
}

dns_restart() {
  dns_installed || { err "Шифрованный DNS не настроен"; return 1; }
  # после череды падений systemd не даёт запустить службу («start request repeated too quickly»)
  systemctl reset-failed "$DNS_UNIT" &>/dev/null || true
  systemctl restart "$DNS_SOCKET" "$DNS_UNIT" &>/dev/null || true
  iface_up && dns_rules_up
  if _dns_wait_ready; then ok "dnscrypt-proxy перезапущен и отвечает"
  else err "dnscrypt-proxy не отвечает: journalctl -u $DNS_UNIT -n 20"; return 1; fi
}

dns_status() {
  local names
  if ! command -v dnscrypt-proxy &>/dev/null; then echo -e "  Статус    : ${D}○ не установлен${N}"; return 0; fi
  if ! dns_running; then echo -e "  Статус    : ${D}○ служба остановлена${N}"
  elif dns_resolves; then echo -e "  Статус    : ${G}● работает${N} ${D}($DNS_PROXY_ADDR:$DNS_PROXY_PORT)${N}"
  else echo -e "  Статус    : ${Y}▲ служба запущена, но не резолвит${N}"; fi
  if dns_rules_ok; then echo -e "  Перехват  : ${G}● DNS клиентов AWG и WG + обфускатора — через DoH, DoT закрыт${N}"
  elif dns_installed; then echo -e "  Перехват  : ${R}▲ правил нет — Перезапустить (2)${N}"
  else echo -e "  Перехват  : ${D}○ выключен${N}"; fi
  unit_active awg-dns-healthcheck.timer && echo -e "  Health    : ${G}● раз в 2 минуты${N}"
  names=$(sed -n 's/^server_names[[:space:]]*=[[:space:]]*//p' "$DNS_PROXY_CONF" 2>/dev/null | tr -d "[]'\"" | head -1)
  [[ -n "$names" ]] && echo -e "  Резолверы : ${C}$names${N}"
  return 0
}

dns_change_upstream() {
  local c i names="" manual
  [[ -f "$DNS_PROXY_CONF" ]] || { err "Сначала включи шифрованный DNS"; return 1; }
  for i in "${!DNS_PRESETS[@]}"; do echo -e "  ${C}$((i + 1)))${N} ${DNS_PRESETS[$i]#*|}"; done
  echo -e "  ${C}$(( ${#DNS_PRESETS[@]} + 1 )))${N} Вручную ${D}(имена из public-resolvers.md)${N}"
  read_choice c "${C}  Выбор (0 — отмена): ${N}" 0 $(( ${#DNS_PRESETS[@]} + 1 )) 0
  (( c == 0 )) && return 0
  if (( c <= ${#DNS_PRESETS[@]} )); then
    names="${DNS_PRESETS[$((c - 1))]%%|*}"
  else
    echo -e "  ${D}Популярные (DoH):${N}"
    for i in "${DNS_POPULAR[@]}"; do printf "    ${C}%-36s${N} ${D}%s${N}\n" "${i%%|*}" "${i#*|}"; done
    echo -e "  ${D}Весь список: https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/public-resolvers.md${N}"
    read_line manual "${C}  Резолверы через запятую: ${N}"
    [[ -n "$manual" ]] || return 0
    names="$manual"
  fi
  dns_set_upstream "$names"
}

# Резолверы dnscrypt-proxy по именам из public-resolvers.md (через пробел или
# запятую). Не поднялся с новыми — возвращаются прежние.
dns_set_upstream() {
  local names="${1//,/ }" old
  _dns_upstream_check "$names" || return 1
  old=$(sed -n 's/^server_names[[:space:]]*=[[:space:]]*//p' "$DNS_PROXY_CONF" 2>/dev/null | head -1)
  _dns_upstream_write "$names" || return 1
  if dns_restart; then ok "Резолверы: $names"; return 0; fi
  if [[ "$old" =~ ^\[[A-Za-z0-9._\ \',-]*\]$ ]]; then
    sed -i "s|^server_names[[:space:]]*=.*|server_names = $old|" "$DNS_PROXY_CONF"
    warn "С новыми резолверами dnscrypt-proxy не поднялся — вернул прежние: $(tr -d "[]'" <<< "$old")"
    dns_restart || true
  fi
  return 1
}

# Имена — в кэше списка, DoH, IPv4: иначе dnscrypt-proxy их молча отбросит и,
# не найдя ни одного, упадёт. Списка ещё нет — проверит сам перезапуск.
_dns_upstream_check() {
  local out
  [[ -s "$DNS_RESOLVERS_MD" && "$1" =~ ^[A-Za-z0-9._\ -]+$ ]] || return 0   # формат проверит запись
  out=$(py dns-check "$DNS_RESOLVERS_MD" $1) && return 0
  while IFS= read -r out; do err "$out"; done <<< "$out"
  return 1
}

_dns_upstream_write() {  # имена — в конфиг, без перезапуска
  local names="${1//,/ }" toml="" n
  [[ -f "$DNS_PROXY_CONF" ]] || { err "Шифрованный DNS не настроен"; return 1; }
  [[ "$names" =~ ^[A-Za-z0-9._\ -]+$ && -n "${names// /}" ]] || { err "Допустимы латиница, цифры, точка, дефис и запятая"; return 1; }
  # require_* при явном server_names dnscrypt-proxy не смотрит — только протокол и IPv4/IPv6
  for n in $names; do toml+="${toml:+, }'$n'"; done
  sed -i "s|^server_names[[:space:]]*=.*|server_names = [$toml]|" "$DNS_PROXY_CONF"
}

dns_remove() {
  local purge=n
  read_confirm "${R}  Выключить шифрованный DNS? Клиенты пойдут на DNS из своих конфигов (введи yes): ${N}" || return 0
  read_yesno purge "  Удалить и пакет dnscrypt-proxy? [y/N]: " n
  dns_uninstall "$([[ "$purge" == y ]] && echo purge)"
}

dns_uninstall() {  # [purge] — удалить и пакет
  local purge="${1:-}" i
  remove_unit awg-dns-healthcheck.timer awg-dns-healthcheck.service awg-dns-persist.service
  rm -f "$DNS_HEALTH_SCRIPT" "$DNS_PERSIST_SCRIPT" "$DNS_SYSCTL"
  dns_rules_down
  if command -v ufw &>/dev/null; then
    ufw_delete_matching "$DNS_TAG"
    for i in $(dns_ifaces); do
      ufw delete allow in on "$i" to "$DNS_PROXY_ADDR" port "$DNS_PROXY_PORT" proto udp &>/dev/null || true
      ufw delete allow in on "$i" to "$DNS_PROXY_ADDR" port "$DNS_PROXY_PORT" proto tcp &>/dev/null || true
    done
  fi
  sysctl -qw net.ipv4.conf.all.route_localnet=0 2>/dev/null || true
  systemctl disable --now "$DNS_UNIT" "$DNS_SOCKET" &>/dev/null || true
  if [[ "$purge" == purge ]]; then
    apt-get purge -y -q dnscrypt-proxy &>/dev/null || true
    rm -rf /var/cache/dnscrypt-proxy
  elif [[ -f "$DNS_PROXY_BACKUP_CONF" ]]; then
    cp -a "$DNS_PROXY_BACKUP_CONF" "$DNS_PROXY_CONF"
  fi
  rm -f "$DNS_PROXY_STATE"
  ok "Шифрованный DNS выключен"
  log_info "dnscrypt-proxy выключен"
}

do_dns_menu() {
  local c
  while true; do
    echo ""
    hdr "Шифрованный DNS (dnscrypt-proxy)"
    dns_status
    echo ""
    echo -e "  ${C}1)${N} Включить"
    echo -e "  ${C}2)${N} Перезапустить"
    echo -e "  ${C}3)${N} Журнал"
    echo -e "  ${C}4)${N} Резолверы"
    echo -e "  ${R}5)${N} Выключить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-5]: ${N}" 0 5 0
    case "$c" in
      1) dns_install || true ;;
      2) dns_restart || true ;;
      3) journalctl -u "$DNS_UNIT" -n 50 --no-pager 2>/dev/null || warn "Журнал недоступен" ;;
      4) dns_change_upstream || true ;;
      5) dns_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
