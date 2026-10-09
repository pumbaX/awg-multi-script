# Главное меню и шапка. Нумерация разделов — как в прежних версиях.

show_header() {
  local ch="" upd n prof st hint why
  clear
  [[ "$UPDATE_CHANNEL" == beta ]] && ch=" ${Y}[beta]${N}"
  upd=$(update_available || true)
  echo -e "${B}${LINE}${N}"
  echo -e "  ${W}AWG Toolza $VERSION_SHOW${N}$ch${upd:+   ${G}⬆ есть $upd${N} ${D}— Обновление${N}}"
  echo -e "  ${C}TG: @awgToolza${N}"
  echo -e "${B}${LINE}${N}"
  why=$(os_supported) || echo -e "  ${Y}▲ $why${N}"
  echo -e "  Компоненты : $(components_summary)"
  if server_exists; then
    n=$(clients_tsv | wc -l)
    prof="AWG $(server_proto), $(profile_label "$(server_profile)")"
    if iface_up; then st="${G}● работает${N}"; else st="${R}○ не поднят${N}"; fi
    echo -e "  Сервер     : ${W}$(endpoint_host):$(server_port)${N}  $st"
    echo -e "  Профиль    : ${W}$prof${N}, клиентов ${W}$n${N}"
    hint=$(proto_upgrade_hint)
    [[ -n "$hint" ]] && echo -e "  $hint"
  else
    echo -e "  Сервер     : ${D}не создан — Сервер → Создать сервер${N}"
  fi
  echo -e "${B}${LINE}${N}"
}

do_server_menu() {
  local c ep
  while true; do
    echo ""
    hdr "Сервер"
    ep=$(endpoint_domain)
    echo -e "  ${C}1)${N} Установить компоненты"
    echo -e "  ${C}2)${N} Создать сервер"
    echo -e "  ${C}3)${N} Перезапустить awg0"
    echo -e "  ${C}4)${N} Протокол и параметры AWG"
    echo -e "  ${C}5)${N} Модуль ядра и утилиты"
    echo -e "  ${C}6)${N} Проверить и починить"
    echo -e "  ${C}7)${N} Endpoint ${D}— ${ep:-IP сервера}${N}"
    echo -e "  ${Y}8)${N} Сбросить сервер"
    echo -e "  ${C}9)${N} Антисканер ${D}— $(antiscan_on && echo "включён" || echo "сети сканеров РКН")${N}"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-9]: ${N}" 0 9 0
    case "$c" in
      1) do_install || true ;;
      2) do_create_server || true ;;
      3) do_restart || true ;;
      4) do_proto_menu || true; continue ;;
      5) do_components_menu || true; continue ;;
      6) do_repair || true ;;
      7) do_endpoint_menu || true ;;
      8) do_reset_server || true ;;
      9) do_antiscan_menu || true; continue ;;
      0) return 0 ;;
    esac
    pause
  done
}

do_backup_menu() {
  local c
  while true; do
    echo ""
    hdr "Бэкапы ${D}($BACKUP_DIR)${N}"
    echo -e "  ${C}1)${N} Создать бэкап"
    echo -e "  ${C}2)${N} Восстановить"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) do_backup || true ;;
      2) do_restore || true ;;
      0) return 0 ;;
    esac
    pause
  done
}

_need_server() {
  server_exists && return 0
  warn "Сначала создай сервер: Сервер → Создать сервер"
  pause
  return 1
}

main_menu() {
  local c post="${1:-}"
  while true; do
    show_header
    if [[ -n "$post" ]]; then
      if [[ "$post" == "$VERSION" ]]; then success_box "Скрипт перезапущен ($VERSION)"
      else success_box "Обновлено: $post → $VERSION"; fi
      post=""
    fi
    echo ""
    echo -e "  ${C}1)${N} Сервер          ${D}— установка${N}"
    echo -e "  ${C}2)${N} Клиенты         ${D}— конфиги${N}"
    echo -e "  ${C}3)${N} Диагностика     ${D}— проверки${N}"
    echo -e "  ${C}4)${N} Бэкапы          ${D}— сохранить${N}"
    echo -e "  ${C}5)${N} Туннели и DNS   ${D}— WARP, Xray${N}"
    echo -e "  ${C}6)${N} Telegram-бот    ${D}— управление${N}"
    echo -e "  ${R}7)${N} Удаление        ${D}— очистка${N}"
    echo -e "  ${M}8)${N} Обновление      ${D}— $(update_channel_label)${N}"
    echo -e "  ${C}9)${N} WG + обфускатор ${D}— $(wgobf_installed && echo "установлен" || echo "как Phobos")${N}"
    echo -e "  ${C}w)${N} Веб-панель      ${D}— $(web_installed && { web_active && echo "работает" || echo "остановлена"; } || echo "в браузере")${N}"
    echo -e "  ${W}0)${N} Выход"
    read_choice c "${C}  Выбор [0-9, w]: ${N}" 0 9 "" "w"
    case "$c" in
      1) do_server_menu ;;
      2) _need_server && { do_clients_menu || true; } ;;
      3) do_diag_menu ;;
      4) do_backup_menu ;;
      5) do_tunnels_menu ;;
      6) do_bot_menu ;;
      7) do_danger_menu ;;
      8) do_update_menu ;;
      9) do_wgobf_menu ;;
      w) do_web_menu ;;
      0) echo -e "\n  ${G}В путь!${N} ${D}t.me/awgToolza${N}\n"; return 0 ;;
    esac
  done
}
