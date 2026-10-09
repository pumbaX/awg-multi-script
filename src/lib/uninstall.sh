# Очистка клиентов и полное удаление.

do_clean_clients() {
  local n
  server_exists || { err "Сервер не создан"; return 1; }
  n=$(grep -c '^\[Peer\]' "$SERVER_CONF" || true)
  (( n )) || { info "Клиентов нет"; return 0; }
  warn "Будут удалены все клиенты ($n) и их конфиги в $CLIENT_DIR"
  read_confirm "${R}  Подтверди (введи yes): ${N}" || return 0
  clients_clean
}

clients_clean() {
  local n
  server_exists || { err "Сервер не создан"; return 1; }
  n=$(grep -c '^\[Peer\]' "$SERVER_CONF" || true)
  auto_backup clean || warn "Авто-бэкап не удался"
  py peers-clear "$SERVER_CONF" || { err "Конфиг не изменён"; return 1; }
  rm -f "$CLIENT_DIR"/*_awg[23].conf
  : > "$WARP_PEERS" 2>/dev/null || true
  [[ -f "$XRAY_PEERS" ]] && : > "$XRAY_PEERS"
  [[ -f "$EXITS_PEERS" ]] && : > "$EXITS_PEERS"
  server_apply
  ok "Клиенты удалены: $n"
  log_info "удалены все клиенты ($n)"
}

# Все туннели: службы, правила и настройки. Бэкап делается до вызова.
tunnels_remove_all() {
  local n
  tunnels_panic_reset quiet
  for n in $(exits_nodes); do systemctl disable --now "awg-quick@awg-exit-$n" &>/dev/null || true; done
  remove_unit awg-warp.service awg-usque.service awg-warp-healthcheck.timer awg-warp-healthcheck.service \
    "$XRAY_ROUTING_UNIT" "$XRAY_TUN_UNIT" "$XRAY_UNIT" awg-xray-rugeo.timer awg-xray-rugeo.service \
    "$T2S_UNIT" "$EXITS_UNIT" awg-dns-persist.service awg-dns-healthcheck.timer awg-dns-healthcheck.service
  cascade_uninstall quiet
  if [[ -f "$DNS_PROXY_STATE" ]]; then
    dns_rules_down
    ufw_delete_matching "$DNS_TAG"
    systemctl disable --now dnscrypt-proxy.service dnscrypt-proxy.socket &>/dev/null || true
    [[ -f "$DNS_PROXY_BACKUP_CONF" ]] && cp -a "$DNS_PROXY_BACKUP_CONF" "$DNS_PROXY_CONF"
    sysctl -qw net.ipv4.conf.all.route_localnet=0 2>/dev/null || true
  fi
  rm -rf "$WARP_DIR" "$WARP_CONF" /usr/local/bin/wgcf "$WARP_BACKEND_FILE" "$WARP_HEALTH_SCRIPT" \
    "$USQUE_DIR" "$USQUE_BIN" "$USQUE_SYSCTL" "$WARPSCOUT_DIR" "$WARPSCOUT_BIN" \
    "$XRAY_DIR" "$XRAY_BIN" "$XRAY_ROUTING_SCRIPT" "$XRAY_ASSET_DIR"/geo{ip,site}.dat "$XRAY_ASSET_DIR"/geo{ip,site}_RU.dat \
    "$T2S_DIR" "$T2S_BIN" "$T2S_ROUTING_SCRIPT" "$EXITS_SCRIPT" \
    "$DNS_PROXY_STATE" "$DNS_PERSIST_SCRIPT" "$DNS_HEALTH_SCRIPT" "$DNS_SYSCTL"
}

# Файлы, которые кладёт «make install» amneziawg-tools.
_tools_files() {
  local d
  for d in /usr/bin /usr/local/bin; do echo "$d/awg" "$d/awg-quick"; done
  echo /usr/share/man/man8/awg.8 /usr/share/man/man8/awg-quick.8 \
       /usr/share/bash-completion/completions/awg /usr/share/bash-completion/completions/awg-quick \
       /lib/systemd/system/awg-quick@.service /lib/systemd/system/awg-quick.target \
       /usr/lib/systemd/system/awg-quick@.service /usr/lib/systemd/system/awg-quick.target
}

# Распакованные архивы Тулзы (с awg2.sh и awg_bot): из них «Установить бота»
# берёт локальный код, поэтому после полного удаления о них спрашиваем.
# Только свои (root_only_path) и без перевода строки в имени: список
# читается построчно, и «awg-toolza-x\nroot» дал бы rm -rf root —
# относительный путь от текущего каталога.
toolza_unpacked() {
  local d
  for d in /root/awg-toolza-*/ /home/*/awg-toolza-*/; do
    d="${d%/}"
    [[ "$d" != *$'\n'* && -d "$d" && -f "$d/awg2.sh" && -d "$d/awg_bot" ]] || continue
    root_only_path "$d" && echo "$d"
  done
  return 0
}

do_uninstall() {
  local del_bot=n del_wgobf=n del_web=n del_self=n del_src=n opts src=() d
  hdr "Удаление AWG Toolza"
  warn "Будет удалено:"
  echo -e "  ${R}—${N} сервер awg0, его клиенты и автозапуск"
  echo -e "  ${R}—${N} модуль ядра (DKMS) и утилиты awg / awg-quick"
  echo -e "  ${R}—${N} туннели: WARP, Xray, tun2socks, exit-ноды, каскад, шифрованный DNS"
  echo -e "  ${R}—${N} таймер сроков клиентов, правила UFW с меткой AmneziaWG"
  bot_installed && echo -e "  ${R}—${N} Telegram-бот ${D}(спрошу отдельно)${N}"
  wgobf_installed && echo -e "  ${R}—${N} WG + обфускатор ${D}(спрошу отдельно)${N}"
  web_installed && echo -e "  ${R}—${N} веб-панель ${D}(спрошу отдельно)${N}"
  echo -e "  ${R}—${N} сам скрипт $SCRIPT_PATH ${D}(спрошу отдельно)${N}"
  echo -e "  ${D}Перед удалением делается полный бэкап в $BACKUP_DIR — он остаётся.${N}"
  read_confirm "${R}  Подтверди удаление (введи yes): ${N}" || return 0
  bot_installed && read_yesno del_bot "  Удалить и Telegram-бота? [Y/n]: " y
  wgobf_installed && read_yesno del_wgobf "  Удалить и WG + обфускатор? [Y/n]: " y
  web_installed && read_yesno del_web "  Удалить и веб-панель? [Y/n]: " y
  read_yesno del_self "  Удалить сам скрипт awg2? [Y/n]: " y
  mapfile -t src < <(toolza_unpacked)
  if (( ${#src[@]} )); then
    echo -e "  ${D}Распакованные архивы Тулзы — из них ставится бот «из локального кода»:${N}"
    for d in "${src[@]}"; do printf "  ${D}  %s${N}\n" "$(shown "$d")"; done
    read_yesno del_src "  Удалить и их? [y/N]: " n
  fi
  opts=()
  [[ "$del_bot" == y ]] && opts+=(bot)
  [[ "$del_wgobf" == y ]] && opts+=(wgobf)
  [[ "$del_web" == y ]] && opts+=(web)
  [[ "$del_self" == y ]] && opts+=(self)
  uninstall_all "${opts[@]}"
  if [[ "$del_src" == y ]]; then
    for d in "${src[@]}"; do [[ "$d" == /* ]] && rm -rf -- "$d"; done
    ok "Распакованные архивы удалены: ${#src[@]}"
  fi
  (( UNINSTALLED_SELF )) && exit 0
  return 0
}

# uninstall_all [bot] [wgobf] [self] — без вопросов; полный бэкап делается всегда.
UNINSTALLED_SELF=0
uninstall_all() {
  local v o del_bot=n del_wgobf=n del_web=n del_self=n
  for o in "$@"; do
    case "$o" in bot) del_bot=y ;; wgobf) del_wgobf=y ;; web) del_web=y ;; self) del_self=y ;; esac
  done
  # Веб-панель работает через awg2: без него она осталась бы открытым входом,
  # который ничего не может, и убрать её было бы уже нечем
  if [[ "$del_self" == y && "$del_web" != y ]] && web_installed; then
    del_web=y
    info "Без awg2 веб-панель не работает — удаляю и её"
  fi

  server_exists && do_backup
  awg-quick down "$SERVER_CONF" &>/dev/null || ip link del "$AWG_IF" &>/dev/null || true
  expire_remove
  systemctl disable awg-quick@awg0 &>/dev/null || true
  rm -rf "$AUTOSTART_DROPIN"
  # NAT-персистентность очень старых версий
  remove_unit awg-nat.service
  rm -f /usr/local/bin/awg-nat-apply.sh /etc/network/if-pre-up.d/iptables-nat
  info "Туннели..."
  tunnels_remove_all
  info "Модуль ядра и утилиты..."
  if command -v dkms &>/dev/null; then
    for v in $(dkms status "$MOD_NAME" 2>/dev/null | sed -n "s#^$MOD_NAME/\([^,:]*\).*#\1#p" | sort -u); do
      dkms remove -m "$MOD_NAME" -v "$v" --all &>/dev/null || true
    done
  fi
  rmmod "$MOD_NAME" &>/dev/null || true
  rm -rf /usr/src/"$MOD_NAME"-* /var/lib/dkms/"$MOD_NAME" "$MOD_BACKUP_DIR" "$MODULES_LOAD_FILE" "$SYSCTL_FORWARD_FILE"
  depmod -a &>/dev/null || true
  # shellcheck disable=SC2046  # список путей — словами
  rm -f $(_tools_files)
  apt-get remove -y -q amneziawg amneziawg-tools &>/dev/null || true
  systemctl daemon-reload
  rm -rf "$AWG_DIR"
  rm -f "$CLIENT_DIR"/*_awg[23].conf "$MOD_TAG_FILE" "$TOOLS_TAG_FILE" "$UPSTREAM_CACHE" "$MOD_LOG"
  ufw_delete_matching AmneziaWG
  if [[ "$del_wgobf" == y ]]; then wgobf_remove quiet
  elif wgobf_installed; then info "WG + обфускатор оставлен и продолжит работать сам"; fi
  if [[ "$del_web" == y ]] && web_installed; then web_remove quiet
  elif web_installed; then info "Веб-панель оставлена — сервера AWG в ней больше нет"; fi
  # Антисканер работает через свой скрипт и без awg2, но управлять им без
  # awg2 нечем — уходит вместе со скриптом, иначе остаётся защищать сервер
  if [[ "$del_self" == y ]]; then antiscan_remove
  elif antiscan_on; then info "Антисканер оставлен и продолжит работать"; fi
  if [[ "$del_bot" == y ]]; then
    bot_uninstall quiet
    # Сертификат — для Mini App бота и веб-панели
    if ! web_installed; then
      [[ -f "$CERT_STATE" || -d "$CERT_DIR" ]] && cert_remove &>/dev/null
      rm -rf "$ACME_DIR" "$ACME_HOME"
    fi
  fi
  log_info "полное удаление"
  if [[ "$del_self" != y ]]; then
    ok "Удалено. Скрипт остался: $SCRIPT_PATH"
    return 0
  fi
  rm -rf "$STATE_DIR" "$LOG_FILE" "$INSTALL_LOG" /root/awg-toolza-*.run /opt/awg-toolza-*
  ok "Удалено всё, включая $SCRIPT_PATH. Бэкапы: $BACKUP_DIR"
  # bash дочитывает скрипт с диска по ходу — удаляем его из отдельного процесса
  ( sleep 1; rm -f "$SCRIPT_PATH" ) &>/dev/null &
  UNINSTALLED_SELF=1
}

do_danger_menu() {
  local c
  while true; do
    echo ""
    hdr "Удаление"
    echo -e "  ${Y}1)${N} Удалить всех клиентов ${D}(сервер остаётся)${N}"
    echo -e "  ${R}2)${N} Удалить всё"
    echo -e "  ${D}Сброс сервера с пересозданием — Сервер → Сбросить сервер${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) do_clean_clients || true ;;
      2) do_uninstall || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
