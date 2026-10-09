# Точка входа: аргументы командной строки (их вызывают бот и таймеры) и меню.

usage() {
  cat <<EOF
awg2 $VERSION — AmneziaWG 2.0 / 3.1 для Ubuntu 24.04+ и Debian 12+

  awg2                          меню
  awg2 --auto                   установка сервера без вопросов (AWG_PROFILE, AWG_PROTO, AWG_PORT)
  awg2 --add-client ИМЯ         добавить клиента
  awg2 --tunnel Т up|down|restart
                                Т: warp | xray | tun2socks | exits | dns
  awg2 --xray-balancer С        С: random | roundRobin | leastPing | leastLoad | off
  awg2 --xray-ru-update         обновить РФ-базы Xray
  awg2 --wgobf add|del|bundle ИМЯ | rotate-key | restart
  awg2 --status                 сводка состояния
  awg2 api КОМАНДА              JSON-интерфейс для Telegram-бота (awg2 api help)
  awg2 --version

Переменные: AUTOINSTALL=1 — то же, что --auto; AWG2_UPDATE_CHANNEL=beta — разовый запуск на бета-канале.
EOF
}

# Команды, без которых не работает ни один раздел.
base_deps() {
  need_cmds python3:python3 curl:curl iptables:iptables ip:iproute2 ss:iproute2 >/dev/null \
    || { err "Не удалось поставить базовые пакеты (python3, curl, iptables, iproute2)"; exit 1; }
}

tunnel_cli() {  # туннель действие
  local t="$1" a="$2" up down
  [[ "$a" =~ ^(up|down|restart)$ ]] || { err "Действие: up | down | restart"; return 1; }
  case "$t" in
    warp) up=warp_up; down=warp_down ;;
    xray) up=xray_up; down=xray_down ;;
    tun2socks) up=t2s_up; down=t2s_down ;;
    exits) up=exits_up; down=exits_down ;;
    dns) [[ "$a" == down ]] && { err "DNS: только up | restart"; return 1; }
         dns_restart; return ;;
    *) err "Туннель: warp | xray | tun2socks | exits | dns"; return 1 ;;
  esac
  case "$a" in
    up) "$up" ;;
    down) "$down" ;;
    restart) "$down" quiet; "$up" ;;
  esac
}

_on_interrupt() {
  _cleanup_tmp
  echo ""
  warn "Прервано"
  exit 130
}

main() {
  local post=""
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "awg2 $VERSION_SHOW"; exit 0 ;;
  esac
  (( EUID == 0 )) || { echo "awg2: нужен root — sudo awg2" >&2; exit 1; }
  log_init
  trap _cleanup_tmp EXIT
  trap _on_interrupt INT TERM
  # Машинный интерфейс бота: весь вывод — внутри одного JSON-ответа
  [[ "${1:-}" == api ]] && { shift; api_main "$@"; exit; }
  update_channel_init
  base_deps
  helpers_refresh || true
  expire_watchdog || true

  case "${1:-}" in
    --status) do_status; exit 0 ;;
    --post-update) post="${2:-?}" ;;
    --interactive) ;;
    --auto|-auto) AUTO_MODE=1; do_autoinstall; exit ;;
    --add-client)
      [[ -n "${2:-}" ]] || { err "Использование: awg2 --add-client ИМЯ"; exit 1; }
      AUTO_MODE=1
      client_create "$2" && exit 0 || exit 1 ;;
    --tunnel) AUTO_MODE=1; tunnel_cli "${2:-}" "${3:-}" && exit 0 || exit 1 ;;
    --xray-balancer)
      [[ -n "${2:-}" ]] || { err "Использование: awg2 --xray-balancer random|roundRobin|leastPing|leastLoad|off"; exit 1; }
      AUTO_MODE=1
      xray_installed || { err "Xray не установлен"; exit 1; }
      xray_balancer "$2" && exit 0 || exit 1 ;;
    --xray-ru-update)
      xray_ru_on || { info "РФ-правила Xray выключены — обновлять нечего"; exit 0; }
      xray_ru_update || exit 1
      info "Новые базы подхватятся при перезапуске туннеля Xray"
      exit 0 ;;
    --wgobf) AUTO_MODE=1; wgobf_cli "${2:-}" "${3:-}" && exit 0 || exit 1 ;;
    "") [[ "${AUTOINSTALL:-}" == 1 ]] && { AUTO_MODE=1; do_autoinstall; exit; } ;;
    *) err "Неизвестный аргумент: $1"; info "awg2 --help — список аргументов"; exit 1 ;;
  esac

  log_info "=== AWG Toolza $VERSION_SHOW ==="
  [[ -z "$post" ]] && { self_install_offer || true; }
  update_check_async || true
  upstream_refresh_async || true
  client_files_sync_suffix || true
  main_menu "$post"
}
