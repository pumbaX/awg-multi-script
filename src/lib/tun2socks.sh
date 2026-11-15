# tun2socks: все клиенты AWG уходят через внешний SOCKS5-прокси.
# tun0 поднимает tun2socks, маршруты ставит скрипт из ExecStartPost —
# поэтому после перезагрузки туннель восстанавливается целиком.
# Маршрутизируется вся подсеть клиентов (таблица 100), без выбора клиентов.

t2s_proxy() { head -1 "$T2S_CONF" 2>/dev/null | tr -d '[:space:]'; }

_t2s_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;; *) echo "" ;;
  esac
}

# Бинарь нужен и туннелю tun2socks, и Xray без inbound tun.
# Флаг --version именно длинный: pflag на «-version» выходит с кодом 2.
t2s_install_bin() {
  local arch tmp bin
  "$T2S_BIN" --version &>/dev/null && return 0
  arch=$(_t2s_arch)
  [[ -n "$arch" ]] || { err "Архитектура $(uname -m) не поддерживается tun2socks"; return 1; }
  need_cmds unzip:unzip || return 1
  mktmp tmp -d || return 1
  info "Скачиваю tun2socks..."
  gh_fetch "https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-$arch.zip" \
    "$tmp/t.zip" 500000 zip || { err "tun2socks не скачался ни напрямую, ни через зеркала"; return 1; }
  unzip -qo "$tmp/t.zip" -d "$tmp/x" || { err "Архив tun2socks не распаковался"; return 1; }
  # Имя бинаря в архиве меняется от релиза к релизу
  bin=$(find "$tmp/x" -type f -name 'tun2socks*' | head -1)
  [[ -n "$bin" ]] && head -c4 "$bin" | grep -q $'\x7fELF' || { err "В архиве нет бинаря tun2socks"; return 1; }
  chmod 755 "$bin"
  "$bin" --version &>/dev/null || { err "tun2socks не запускается на этой системе"; return 1; }
  install -m 755 "$bin" "$T2S_BIN"
  ok "tun2socks: $("$T2S_BIN" --version 2>/dev/null | head -1)"
}

# Точка входа ExecStartPost / ExecStopPost.
t2s_routing_run() {
  local i
  if [[ "${1:-}" == stop ]]; then rt_down "$T2S_IF" "$T2S_TABLE"; return 0; fi
  for i in $(seq 1 20); do ip link show "$T2S_IF" &>/dev/null && break; sleep 0.5; done
  ip link show "$T2S_IF" &>/dev/null || { echo "$T2S_IF не появился" >&2; return 1; }
  ip addr add "$T2S_ADDR" dev "$T2S_IF" 2>/dev/null || true
  ip link set "$T2S_IF" up
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
  rt_up "$T2S_IF" "$T2S_TABLE" -
}

t2s_up() {
  local proxy="${1:-$(t2s_proxy)}" why i
  server_exists || { err "Сначала создай сервер"; return 1; }
  [[ "$proxy" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]] || { err "Нужен адрес вида IP:ПОРТ (сейчас: ${proxy:-пусто})"; return 1; }
  t2s_is_up && { info "tun2socks уже включён"; return 0; }
  tunnel_guard tun2socks || return 1
  t2s_install_bin || return 1
  [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null || true
  # Настоящий запрос через прокси до того, как трогать маршруты: мёртвый
  # прокси иначе оставил бы всех клиентов без интернета.
  info "Проверяю SOCKS5 $proxy..."
  if ! why=$(socks_probe "$proxy"); then
    err "Через $proxy трафик не идёт (ответ: $why) — туннель не включаю"
    [[ "$proxy" == "$XRAY_SOCKS" || "$proxy" == "localhost:${XRAY_SOCKS##*:}" ]] \
      && info "Это SOCKS-вход Xray — Xray включается в своём разделе (Туннели → Xray)"
    return 1
  fi
  mkdir -p "$T2S_DIR"
  echo "$proxy" | write_file "$T2S_CONF" 600
  emit_script "$T2S_ROUTING_SCRIPT" 't2s_routing_run "$@"' T2S_IF T2S_TABLE T2S_ADDR \
    "${RT_FUNCS[@]}" t2s_routing_run || return 1
  write_unit "$T2S_UNIT" <<EOF
[Unit]
Description=AWG Toolza — клиенты через SOCKS5 (tun2socks)
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
ExecStart=$T2S_BIN --device tun://$T2S_IF --proxy socks5://$proxy --loglevel warn
ExecStartPost=$T2S_ROUTING_SCRIPT start
ExecStopPost=$T2S_ROUTING_SCRIPT stop
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  ip link del "$T2S_IF" &>/dev/null || true
  if ! systemctl enable --now "$T2S_UNIT" &>/dev/null; then
    err "tun2socks не запустился:"
    journalctl -u "$T2S_UNIT" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    t2s_down quiet
    return 1
  fi
  for i in $(seq 1 10); do grep -q "lookup $T2S_TABLE" <<< "$(ip rule show)" && break; sleep 0.5; done
  ok "tun2socks включён: все клиенты идут через $proxy"
}

t2s_down() {
  systemctl disable --now "$T2S_UNIT" &>/dev/null || true
  systemctl reset-failed "$T2S_UNIT" &>/dev/null || true
  rt_down "$T2S_IF" "$T2S_TABLE"
  ip link del "$T2S_IF" &>/dev/null || true
  [[ "${1:-}" == quiet ]] || ok "tun2socks выключен — клиенты идут напрямую"
}

t2s_remove() {
  read_confirm "${R}  Удалить tun2socks (служба, бинарь, адрес прокси)? (введи yes): ${N}" || return 0
  t2s_uninstall
}

t2s_uninstall() {
  t2s_down quiet
  remove_unit "$T2S_UNIT"
  rm -rf "$T2S_DIR" "$T2S_ROUTING_SCRIPT"
  # Бинарь нужен и Xray без inbound tun
  [[ -f "$XRAY_STATE" && "$(xray_state_get tun_mode)" == tun2socks ]] || rm -f "$T2S_BIN"
  ok "tun2socks удалён"
}

do_tun2socks_menu() {
  local c p saved
  while true; do
    saved=$(t2s_proxy)
    echo ""
    hdr "tun2socks (все клиенты через SOCKS5)"
    if t2s_is_up; then echo -e "  Статус : ${G}● включён${N}   Прокси: ${W}$saved${N}"
    else echo -e "  Статус : ${D}○ выключен${N}${saved:+   Прокси: $saved}"; fi
    echo ""
    echo -e "  ${C}1)${N} Включить"
    echo -e "  ${C}2)${N} Выключить"
    echo -e "  ${C}3)${N} Журнал"
    echo -e "  ${R}d)${N} Удалить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 3 0 "d"
    case "$c" in
      1) echo -e "  ${D}Адрес SOCKS5-прокси, например 127.0.0.1:1080 или 5.6.7.8:1080${N}"
         read_line p "${C}  IP:ПОРТ${saved:+ (Enter = $saved)}: ${N}"
         t2s_up "${p:-$saved}" || true ;;
      2) t2s_down ;;
      3) journalctl -u "$T2S_UNIT" -n 50 --no-pager 2>/dev/null || true ;;
      d) t2s_remove || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
