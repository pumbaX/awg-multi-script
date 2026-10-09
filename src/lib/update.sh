# Самообновление. Канал stable — основной репозиторий, beta — ранние сборки.
# Выбор хранится в /var/lib/awg2/channel; AWG2_UPDATE_CHANNEL=beta — разовый
# запуск на другом канале. У каналов раздельные кэши проверки версии.

UPDATE_CHANNEL="" UPDATE_REPO="" UPDATE_URL="" UPDATE_CACHE="" BOT_INSTALL_URL=""

update_channel_apply() {
  if [[ "${1:-}" == beta ]]; then
    UPDATE_CHANNEL=beta; UPDATE_REPO="$UPDATE_REPO_BETA"; UPDATE_CACHE="$STATE_DIR/update_check.beta"
  else
    UPDATE_CHANNEL=stable; UPDATE_REPO="$UPDATE_REPO_STABLE"; UPDATE_CACHE="$STATE_DIR/update_check"
  fi
  UPDATE_URL="https://raw.githubusercontent.com/$UPDATE_REPO/main/awg2.sh"
  BOT_INSTALL_URL="https://raw.githubusercontent.com/$UPDATE_REPO/main/awg-bot-install.sh"
}

update_channel_read() {
  [[ "$(tr -d '[:space:]' 2>/dev/null < "$UPDATE_CHANNEL_FILE")" == beta ]] && echo beta || echo stable
}

update_channel_label() { [[ "$UPDATE_CHANNEL" == beta ]] && echo "бета" || echo "стабильный"; }

update_channel_init() { update_channel_apply "${AWG2_UPDATE_CHANNEL:-$(update_channel_read)}"; }

# Фоновая проверка раз в час (бета — раз в 20 минут): шапка меню и сводка
# для бота читают только кэш и сеть не ждут.
# Качаем первые 4 КБ — VERSION= стоит в начале файла.
update_check_async() {
  local ts now ttl="$UPDATE_CHECK_TTL"
  [[ -n "${AWG_NO_UPDATE_CHECK:-}" ]] && return 0
  [[ "$UPDATE_CHANNEL" == beta ]] && ttl="$UPDATE_CHECK_TTL_BETA"
  now=$(date +%s)
  ts=$(awk '{print $2 + 0; exit}' "$UPDATE_CACHE" 2>/dev/null || echo 0)
  (( now - ${ts:-0} < ttl )) && return 0
  mkdir -p "$STATE_DIR"
  update_peek </dev/null &>/dev/null 3>&- 4>&- 8>&- &
  disown 2>/dev/null || true
}

# Версия в канале по первым 4 КБ файла (напрямую и через зеркала) → в кэш.
update_peek() {
  local mp v
  for mp in "${GH_MIRRORS[@]}"; do
    v=$(curl -fsSL --connect-timeout 5 --max-time 10 -r 0-4095 -H 'Cache-Control: no-cache' \
          "${mp}${UPDATE_URL}?nocache=$(date +%s)" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2)
    if [[ "$v" =~ ^v?[0-9]+\.[0-9]+ ]]; then
      printf '%s %s\n' "$v" "$(date +%s)" > "$UPDATE_CACHE" 2>/dev/null || true
      echo "$v"
      return 0
    fi
  done
  return 1
}

# CHANGELOG.md канала (лежит рядом с awg2.sh) → UPDATE_CHANGELOG; напрямую и
# через зеркала, как и сам скрипт.
UPDATE_CHANGELOG=""
update_changelog_fetch() {
  local mp out url="${UPDATE_URL%/*}/CHANGELOG.md"
  UPDATE_CHANGELOG=""
  for mp in "${GH_MIRRORS[@]}"; do
    out=$(curl -fsSL --connect-timeout 5 --max-time 15 --max-filesize 1048576 -H 'Cache-Control: no-cache' \
            "${mp}${url}?nocache=$(date +%s)" 2>/dev/null) || continue
    [[ "$out" == *"## v"* ]] || continue
    UPDATE_CHANGELOG="$out"
    return 0
  done
  return 1
}

update_available() {  # → версия, если новее текущей
  local v
  v=$(awk '{print $1; exit}' "$UPDATE_CACHE" 2>/dev/null)
  [[ "$v" =~ ^v?[0-9]+\.[0-9]+ ]] || return 1
  (( 10#$(ver_num "$v") > 10#$(ver_num "$VERSION") )) || return 1
  echo "$v"
}

_update_download() {  # файл
  local mp url
  url="$UPDATE_URL?nocache=$(date +%s)"
  for mp in "${GH_MIRRORS[@]}"; do
    [[ -n "$mp" ]] && info "Через зеркало ${mp}"
    curl -fL --connect-timeout 10 --max-time 120 --progress-bar -H 'Cache-Control: no-cache' \
      "${mp}${url}" -o "$1" && return 0
  done
  return 1
}

# Подпись awg2.sh.sig — напрямую и через зеркала: подделать её зеркало не может.
_update_download_sig() {  # файл
  local mp url
  url="${UPDATE_URL%/*}/awg2.sh.sig?nocache=$(date +%s)"
  for mp in "${GH_MIRRORS[@]}"; do
    curl -fsSL --connect-timeout 10 --max-time 30 --max-filesize 16384 -H 'Cache-Control: no-cache' \
      "${mp}${url}" -o "$1" 2>/dev/null || continue
    grep -q 'BEGIN SSH SIGNATURE' "$1" && return 0
  done
  return 1
}

# Проверка подписи файла $1 подписью $2 ключом релизов. 0 — верна.
update_sig_ok() {
  local allowed s
  (( ${#UPDATE_SIGNERS[@]} )) || return 1
  command -v ssh-keygen &>/dev/null || need_cmds ssh-keygen:openssh-client >/dev/null || return 1
  mktmp allowed || return 1
  for s in "${UPDATE_SIGNERS[@]}"; do
    printf '%s namespaces="%s" %s\n' "$UPDATE_SIGNER" "$UPDATE_SIG_NS" "$s"
  done > "$allowed"
  ssh-keygen -Y verify -f "$allowed" -I "$UPDATE_SIGNER" -n "$UPDATE_SIG_NS" -s "$2" < "$1" &>/dev/null
}

# Подпись скачанной сборки. Без подписи ставится только сборка старше
# UPDATE_SIG_SINCE (откат на старую версию) и только из меню, после «yes»:
# новая сборка без подписи — это подмена или сбой, а не выпуск.
update_verify() {  # файл
  local sig
  # Ключ вшивается в каждую выпущенную сборку (тест сборки это проверяет);
  # без него — только локальная тестовая сборка, ей проверять нечем
  if (( ${#UPDATE_SIGNERS[@]} == 0 )); then
    warn "Тестовая сборка без ключа релизов — подпись обновления не проверяется"
    return 0
  fi
  mktmp sig || return 1
  if ! _update_download_sig "$sig"; then
    if (( 10#$(ver_num "$UPDATE_NEW") >= 10#$(ver_num "$UPDATE_SIG_SINCE") )); then
      err "У сборки $UPDATE_NEW нет подписи (awg2.sh.sig) — не ставлю. Повтори через пару минут"
      return 1
    fi
    warn "Сборка $UPDATE_NEW вышла до подписей ($UPDATE_SIG_SINCE) — подлинность не проверить"
    if ! read_confirm "${Y}  Поставить без проверки подписи? (введи yes): ${N}"; then
      (( AUTO_MODE )) && err "Сборку без подписи ставлю только из меню awg2 — Обновление"
      return 1
    fi
    return 0
  fi
  if ! update_sig_ok "$1" "$sig"; then
    err "Подпись сборки $UPDATE_NEW не сходится — файл изменён по пути (зеркало?) или только что выложен."
    info "Повтори через пару минут; не помогло — напиши в t.me/awgToolza"
    log_info "обновление $UPDATE_NEW отклонено: подпись не сходится"
    return 1
  fi
  ok "Подпись сборки верна"
}

# Скачать сборку из канала и проверить её → UPDATE_FILE, UPDATE_NEW.
UPDATE_FILE="" UPDATE_NEW=""
update_fetch() {
  mktmp UPDATE_FILE || return 1
  info "Канал: $(update_channel_label) ${D}($UPDATE_REPO)${N}"
  _update_download "$UPDATE_FILE" || { err "Не удалось скачать обновление"; return 1; }
  if (( $(stat -c%s "$UPDATE_FILE") < 50000 )) || ! head -1 "$UPDATE_FILE" | grep -q '^#!.*bash' \
     || ! bash -n "$UPDATE_FILE" 2>/dev/null; then
    err "Скачанный файл повреждён (не bash или синтаксическая ошибка) — повтори позже"
    return 1
  fi
  UPDATE_NEW=$(head -c 4096 "$UPDATE_FILE" | grep -m1 '^VERSION=' | cut -d'"' -f2)
  [[ "$UPDATE_NEW" =~ ^v?[0-9]+\.[0-9]+ ]] || { err "В скачанном файле нет VERSION"; return 1; }
  echo "Текущая: $VERSION, в канале: $UPDATE_NEW"
  update_verify "$UPDATE_FILE" || return 1
  printf '%s %s\n' "$UPDATE_NEW" "$(date +%s)" > "$UPDATE_CACHE" 2>/dev/null || true
}

# Поставить скачанное. Замена через rename: работающие копии awg2 дочитывают
# свой файл, а не новый. «force» — разрешить откат на старшую версию.
update_install() {
  local target="$SCRIPT_PATH"
  [[ -f "$target" ]] || target=$(readlink -f "$0")
  if (( 10#$(ver_num "$UPDATE_NEW") < 10#$(ver_num "$VERSION") )); then
    # Подпись не привязана к версии: зеркало может отдать старую, но верно
    # подписанную сборку. Из бота и панели («Переустановить» = force) откат
    # не ставится никогда — только из меню awg2, где он назван откатом.
    if (( API_MODE )); then
      err "В канале версия старше текущей ($UPDATE_NEW) — откат только из меню awg2"
      return 1
    fi
    if [[ "${1:-}" != force ]]; then
      err "В канале версия старше текущей ($UPDATE_NEW) — откат только явно"
      return 1
    fi
  fi
  if cmp -s "$target" "$UPDATE_FILE"; then ok "Уже последняя версия ($VERSION)"; return 0; fi
  cp -a "$target" "$target.bak" 2>/dev/null && info "Прежняя версия: $target.bak"
  install -m 755 "$UPDATE_FILE" "$target.new" && mv -f "$target.new" "$target" \
    || { err "Не удалось заменить $target"; return 1; }
  hash -r
  ok "Установлено: $UPDATE_NEW"
  log_info "самообновление $VERSION → $UPDATE_NEW"
}

_script_ver() {  # файл awg2 → v1.2.0d (версия и буква тестовой сборки)
  head -c 4096 "$1" 2>/dev/null | awk -F'"' '/^VERSION="/ && !v {v=$2} /^BUILD="/ && !b {b=$2; nb=1}
    END {printf "%s%s", v, (nb ? b : "")}'
}

# Запуск из распакованного архива (sudo bash awg2.sh): бот, таймеры и команда
# awg2 работают с установленной копией $SCRIPT_PATH — предложить заменить её.
self_install_offer() {
  local self cur def=y
  # $0 без «/» — не путь к файлу («bash» при запуске через curl | bash):
  # readlink нашёл бы ./bash в текущем каталоге и предложил поставить его
  [[ "$0" == */* ]] || return 0
  self=$(readlink -f "$0" 2>/dev/null) || return 0
  [[ -f "$self" && "$self" != "$(readlink -f "$SCRIPT_PATH" 2>/dev/null)" ]] || return 0
  head -c 4096 "$self" | grep -q '^VERSION="' || return 0
  cmp -s "$self" "$SCRIPT_PATH" && return 0
  echo ""
  if [[ ! -f "$SCRIPT_PATH" ]]; then
    warn "Команда awg2 не установлена: бот и таймеры ищут $SCRIPT_PATH"
  else
    cur=$(_script_ver "$SCRIPT_PATH")
    warn "Запущена копия $(shown "$self") ($VERSION_SHOW), а установлена ${cur:-другая} в $SCRIPT_PATH"
    info "Бот, панель и команда awg2 работают с установленной"
    if [[ "$cur" =~ ^v?[0-9] ]] && (( 10#$(ver_num "$cur") > 10#$(ver_num "$VERSION") )); then
      warn "Установленная новее — замена будет откатом"
      def=n
    fi
  fi
  ask_yes "  Установить эту копию ($(shown "$self")) в $SCRIPT_PATH? [$([[ $def == y ]] && echo Y/n || echo y/N)]: " "$def" || return 0
  [[ -f "$SCRIPT_PATH" ]] && cp -a "$SCRIPT_PATH" "$SCRIPT_PATH.bak" 2>/dev/null \
    && info "Прежняя копия: $SCRIPT_PATH.bak"
  # Через rename: работающие копии awg2 дочитывают свой файл, а не новый
  install -m 755 "$self" "$SCRIPT_PATH.new" && mv -f "$SCRIPT_PATH.new" "$SCRIPT_PATH" \
    || { rm -f "$SCRIPT_PATH.new"; err "Не удалось записать $SCRIPT_PATH"; return 0; }
  hash -r
  ok "Установлено: $SCRIPT_PATH ($VERSION_SHOW)"
  log_info "awg2 $VERSION_SHOW установлен из $self"
}

do_self_update() {
  local cur_n new_n target="$SCRIPT_PATH"
  [[ -f "$target" ]] || target=$(readlink -f "$0")
  update_fetch || return 1
  cur_n=$(ver_num "$VERSION"); new_n=$(ver_num "$UPDATE_NEW")
  if (( 10#$new_n < 10#$cur_n )); then
    warn "В канале версия старше текущей — это откат"
    read_confirm "${R}  Откатиться до $UPDATE_NEW? (введи yes): ${N}" || return 0
  elif (( 10#$new_n == 10#$cur_n )); then
    cmp -s "$target" "$UPDATE_FILE" && { ok "Уже последняя версия"; return 0; }
    ask_yes "  Версия та же, но файл отличается. Перезаписать? [y/N]: " n || return 0
  else
    ask_yes "  Установить $UPDATE_NEW? [Y/n]: " y || return 0
  fi
  update_install force || return 1
  # В памяти старый код, а bash дочитывает файл по ходу — продолжать здесь нельзя
  info "Перезапускаюсь..."
  exec "$target" --post-update "$VERSION"
}

update_channel_set() {  # stable|beta
  [[ "$1" == stable || "$1" == beta ]] || { err "Канал: stable | beta"; return 1; }
  mkdir -p "$STATE_DIR"
  echo "$1" | write_file "$UPDATE_CHANNEL_FILE" 644
  update_channel_apply "$1"
  ok "Канал: $(update_channel_label)"
}

do_switch_channel() {
  local to=beta
  [[ "$UPDATE_CHANNEL" == beta ]] && to=stable
  if [[ "$to" == beta ]]; then
    warn "Бета — ранние сборки: правки приезжают раньше, но могут быть сырыми"
    ask_yes "  Переключиться на бета-канал? [y/N]: " n || return 0
  fi
  update_channel_set "$to"
  ask_yes "  Обновиться с этого канала сейчас? [Y/n]: " y && do_self_update
  return 0
}

# Служебные скрипты (автозапуск туннелей, таймеры) генерируются из кода awg2.
# После смены версии перегенерируем их у уже включённых компонентов — иначе
# при загрузке работала бы логика прежней версии.
helpers_refresh() {
  # Отметка — версия и хеш сборки: тестовые сборки одной версии (v1.2.0c → d)
  # тоже перегенерируют скрипты
  local mark="$STATE_DIR/version" stamp="$VERSION_SHOW ${_BUILD_SUM:-}"
  [[ "$(cat "$mark" 2>/dev/null)" == "$stamp" ]] && return 0
  mkdir -p "$STATE_DIR"
  server_exists && expire_install &>/dev/null
  # Исходник модуля в DKMS поставила прежняя версия: без правки автосборка
  # DKMS при обновлении ядра (Ubuntu 7.0.0-38) упала бы
  _mod_src_patch "$MOD_SRC_DIR"
  if [[ -f "$WARP_AUTOSTART_SCRIPT" ]]; then
    emit_script "$WARP_AUTOSTART_SCRIPT" 'warp_wg_bringup' \
      WARP_CONF WARP_IF WARP_TABLE WARP_PEERS "${RT_FUNCS[@]}" warp_wg_bringup
  fi
  if [[ -f "$WARP_HEALTH_SCRIPT" ]]; then
    emit_script "$WARP_HEALTH_SCRIPT" 'warp_health_run' WARP_IF WARP_TABLE WARP_STATE \
      WARP_BACKEND_FILE WARP_HEALTH_LOG "${RT_FUNCS[@]}" warp_health_run
  fi
  [[ -f "$USQUE_UP_HOOK" ]] && _usque_write &>/dev/null
  if [[ -f "$DNS_PROXY_STATE" ]]; then
    _dns_emit_helpers &>/dev/null
    # Прежние версии ставили блок DoT в FORWARD ниже ACCEPT — он не работал
    iface_up && { dns_rules_down; dns_rules_up; }
  fi
  if (( $(cascade_count) )); then
    _cascade_persist && cascade_apply_all
  fi
  [[ -f "$T2S_ROUTING_SCRIPT" ]] && emit_script "$T2S_ROUTING_SCRIPT" 't2s_routing_run "$@"' \
    T2S_IF T2S_TABLE T2S_ADDR "${RT_FUNCS[@]}" t2s_routing_run
  [[ -f "$EXITS_SCRIPT" ]] && _exits_write_unit
  antiscan_on && _antiscan_emit &>/dev/null
  # Маршруты Xray: с v1.2.0 перед inbound tun нет NAT (свой выход клиенту)
  [[ -f "$XRAY_ROUTING_SCRIPT" ]] && _xray_emit_routing
  # Xray прежних версий жил во временных юнитах и перезагрузку не переживал
  [[ -f "$XRAY_STATE" && ! -f "/etc/systemd/system/$XRAY_UNIT" ]] && ! xray_is_up && rm -f "$XRAY_STATE"
  wgobf_installed && _wgobf_write_service_files
  echo "$stamp" > "$mark"
  log_info "служебные скрипты обновлены под $VERSION_SHOW"
}

do_update_menu() {
  local c upd
  while true; do
    echo ""
    hdr "Обновление скрипта"
    echo -e "  Версия : ${W}$VERSION_SHOW${N}"
    echo -e "  Канал  : $([[ "$UPDATE_CHANNEL" == beta ]] && echo -e "${Y}бета${N}" || echo -e "${G}стабильный${N}") ${D}($UPDATE_REPO)${N}"
    upd=$(update_available || true)
    [[ -n "$upd" ]] && echo -e "  Доступна: ${G}$upd${N}"
    echo ""
    echo -e "  ${C}1)${N} Обновить скрипт"
    if [[ "$UPDATE_CHANNEL" == beta ]]; then echo -e "  ${C}2)${N} Вернуться на стабильный канал"
    else echo -e "  ${C}2)${N} Бета-канал ${D}(ранние сборки)${N}"; fi
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор [0-2]: ${N}" 0 2 0
    case "$c" in
      1) do_self_update || true ;;
      2) do_switch_channel || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
