#!/bin/bash
# awg-mod-update.sh — обновление ядерного модуля amneziawg (DKMS) на нужный тег.
#
# Зачем отдельный скрипт: awg2 ставит модуль один раз при установке сервера,
# клонируя master. Апстрим же выпускает теги с фиксами (например
# v3.1.20260827 — инициализация header_protection.lock), и обновиться до
# конкретного тега, не переустанавливая сервер, было нечем.
#
# Что делает:
#   • показывает, что стоит сейчас (ядро, DKMS, версия модуля, интерфейсы);
#   • тянет список тегов с GitHub, ставит выбранный через DKMS;
#   • перед удалением старой сборки делает резервную копию исходников и
#     пробную компиляцию новых — если новый код не собирается, старая сборка
#     остаётся нетронутой;
#   • перезагружает модуль (это разрыв туннеля) отдельным подтверждаемым шагом;
#   • умеет откатиться на резервную копию.
#
# Запуск: sudo bash awg-mod-update.sh   (или awg-mod-update --status)
#
# set -e не используется намеренно: скрипт обязан переживать неудачу сборки и
# сам откатываться, а не падать посреди пересборки с удалённой старой версией.
set -uo pipefail

VERSION="v1.0.2"

REPO="amnezia-vpn/amneziawg-linux-kernel-module"
REPO_GIT="https://github.com/${REPO}.git"
API_TAGS="https://api.github.com/repos/${REPO}/tags?per_page=100"
# Запасной тег на случай, если GitHub недоступен или упёрлись в rate limit.
FALLBACK_TAG="v3.1.20260827"

DKMS_NAME="amneziawg"
# Апстрим держит PACKAGE_VERSION="1.0.0" во всех тегах, поэтому имя DKMS-версии
# одно и то же и новая сборка всегда заменяет старую. Не меняем его на номер
# тега: awg2 при переустановке сервера собирает модуль именно как 1.0.0, и две
# разные DKMS-версии одного модуля подрались бы за /lib/modules.
DKMS_VER="1.0.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VER}"
BACKUP_DIR="/var/backups/awg-mod"
STATE_DIR="/var/lib/awg2"
TAG_FILE="${STATE_DIR}/module_tag"   # какой тег поставили мы (version.h апстрим не бумпает)
# Меню перерисовывается через clear, и результат предыдущего действия с экрана
# уходит. Всё существенное дублируется в журнал, чтобы разбор был по факту.
LOG_FILE="/var/log/awg-mod-update.log"

KVER="$(uname -r)"
TMP=""

# ── Цвета и хелперы (палитра как в awg2.sh) ────────────────
R='\033[38;5;203m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[1;94m'; C='\033[0;36m'; W='\033[1;37m'; D='\033[0;90m'; N='\033[0m'

ok()   { echo -e "${G}  √ $*${N}"; }
err()  { echo -e "${R}  × $*${N}"; }
warn() { echo -e "${Y}  ▲ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }
dim()  { echo -e "${D}    $*${N}"; }
log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
hdr()  {
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}$*${N}"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT
trap 'echo; warn "Прервано пользователем"; exit 130' INT TERM

# Ввод: EOF (Ctrl+D) = отмена, мусор переспрашивается, 0 = выход/назад.
read_choice() {   # read_choice VAR "промпт" макс
  local _var="$1" _prompt="$2" _max="$3" _ans
  while true; do
    if ! read -rp "$_prompt" _ans; then echo; printf -v "$_var" '%s' "0"; return 0; fi
    _ans="${_ans//[[:space:]]/}"
    if [[ "$_ans" =~ ^[0-9]+$ ]] && (( 10#$_ans <= _max )); then
      printf -v "$_var" '%s' "$((10#$_ans))"; return 0
    fi
    err "Введи число от 0 до ${_max}"
  done
}

# Подтверждение опасного действия — только полным словом.
read_confirm() {   # read_confirm "вопрос"
  local _ans
  echo -en "${Y}  $1 [да/нет]: ${N}"
  if ! read -r _ans; then echo; return 1; fi
  [[ "${_ans,,}" =~ ^(да|yes|y)$ ]]
}

die() { err "$1"; exit "${2:-1}"; }

# ── Состояние системы ──────────────────────────────────────

# Список интерфейсов типа amneziawg. Пусто — значит туннель не поднят.
awg_ifaces() {
  ip -o link show type amneziawg 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}'
}

module_ver()  { cat /sys/module/${DKMS_NAME}/version 2>/dev/null || echo "не загружен"; }
saved_tag()   { [[ -f "$TAG_FILE" ]] && tr -d '[:space:]' < "$TAG_FILE" || echo ""; }

# Строк бывает несколько: DKMS держит сборку под каждое ядро, и показать только
# первую — значит спрятать ту, под которой система реально работает.
dkms_lines() {
  dkms status -m "$DKMS_NAME" 2>/dev/null | grep -v '^Deprecated'
}

# Собран ли модуль под текущее ядро.
dkms_installed_here() {
  dkms status -m "$DKMS_NAME" 2>/dev/null | grep -q "${KVER}.*installed"
}

show_state() {
  local tag ifaces
  tag="$(saved_tag)"
  ifaces="$(awg_ifaces | tr '\n' ' ')"
  hdr "Состояние"
  dim "ядро      : ${KVER}"
  local dkms_out first rest
  dkms_out="$(dkms_lines)"
  if [[ -z "$dkms_out" ]]; then
    dim "DKMS      : модуль не зарегистрирован"
  else
    first="$(head -1 <<<"$dkms_out")"; rest="$(tail -n +2 <<<"$dkms_out")"
    dim "DKMS      : ${first}"
    [[ -n "$rest" ]] && while read -r l; do dim "            ${l}"; done <<<"$rest"
  fi
  dim "в памяти  : $(module_ver)"
  dim "тег       : ${tag:-неизвестен (ставили не этим скриптом)}"
  dim "tools     : $(awg --version 2>/dev/null | head -1 || echo 'нет awg')"
  dim "интерфейсы: ${ifaces:-нет поднятых}"
  echo
  warn "Апстрим не обновляет version.h: «в памяти» может показывать 3.1.20260812"
  dim  "даже на более новом теге. Настоящий источник правды — строка «тег»."
}

# ── Теги ───────────────────────────────────────────────────

# Печатает теги от новых к старым. Пусто = сеть/лимит API.
tags_fetch() {
  curl -fsSL --max-time 20 "$API_TAGS" 2>/dev/null \
    | grep -oE '"name": *"[^"]+"' | sed 's/.*"name": *"//; s/"$//' \
    | grep -E '^v[0-9]' | sort -Vr
}

latest_tag() { tags_fetch | head -1; }

# ── Подготовка ─────────────────────────────────────────────

ensure_deps() {
  local missing=()
  command -v git   >/dev/null || missing+=(git)
  command -v dkms  >/dev/null || missing+=(dkms)
  command -v make  >/dev/null || missing+=(build-essential)
  [[ -d "/lib/modules/${KVER}/build" ]] || missing+=("linux-headers-${KVER}")
  (( ${#missing[@]} == 0 )) && { ok "Зависимости на месте"; return 0; }

  info "Ставлю: ${missing[*]}"
  command -v apt-get >/dev/null || {
    err "Нет apt-get — поставь вручную: ${missing[*]}"; return 1; }
  apt-get update -qq >/dev/null 2>&1
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1; then
    err "apt не смог поставить: ${missing[*]}"
    dim "Проверь сеть и вывод: apt-get install ${missing[*]}"
    return 1
  fi
  [[ -d "/lib/modules/${KVER}/build" ]] || {
    err "Нет заголовков ядра для ${KVER} даже после установки"
    dim "Возможно, ядро обновилось, но система ещё не перезагружена"
    return 1
  }
  ok "Зависимости установлены"
}

check_secureboot() {
  command -v mokutil >/dev/null || return 0
  if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Включён Secure Boot — ядро не загрузит неподписанный DKMS-модуль"
    dim "Либо подписывай модуль своим MOK, либо выключай Secure Boot в BIOS"
    read_confirm "Всё равно продолжить?" || return 1
  fi
  return 0
}

# ── Резервная копия исходников ─────────────────────────────

backup_src() {   # печатает путь к архиву
  [[ -d "$SRC_DIR" ]] || return 0
  mkdir -p "$BACKUP_DIR" || return 1
  local tag ts file
  tag="$(saved_tag)"; ts="$(date +%Y%m%d-%H%M%S)"
  file="${BACKUP_DIR}/src-${tag:-unknown}-${ts}.tar.gz"
  tar czf "$file" -C /usr/src "${DKMS_NAME}-${DKMS_VER}" 2>/dev/null || return 1
  echo "$file"
}

# Ставит модуль из уже разложенного $SRC_DIR. Общий хвост для обновления и отката.
dkms_build_install() {
  dkms add -m "$DKMS_NAME" -v "$DKMS_VER" >/dev/null 2>&1
  if ! dkms build -m "$DKMS_NAME" -v "$DKMS_VER" >/dev/null 2>&1; then
    err "dkms build не прошёл"
    dim "Лог: /var/lib/dkms/${DKMS_NAME}/${DKMS_VER}/build/make.log"
    return 1
  fi
  if ! dkms install -m "$DKMS_NAME" -v "$DKMS_VER" --force >/dev/null 2>&1; then
    err "dkms install не прошёл"
    return 1
  fi
  return 0
}

restore_backup() {   # $1 = архив
  local file="$1"
  [[ -f "$file" ]] || { err "Нет архива $file"; return 1; }
  warn "Восстанавливаю прежние исходники из $(basename "$file")"
  dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1
  rm -rf "$SRC_DIR"
  tar xzf "$file" -C /usr/src || { err "Архив не распаковался"; return 1; }
  dkms_build_install || { err "Прежняя версия тоже не собралась"; return 1; }
  ok "Прежняя версия возвращена (модуль в памяти всё это время не трогался)"
  return 0
}

# ── Обновление ─────────────────────────────────────────────

do_update() {   # $1 = тег
  local tag="$1" backup="" src
  hdr "Обновление модуля до ${tag}"
  local was; was="$(saved_tag)"
  log "=== обновление до ${tag} (ядро ${KVER}, было: ${was:-неизвестно}) ==="

  ensure_deps || return 1
  check_secureboot || return 1

  cleanup                       # хвост прошлого прохода в этом же меню
  TMP="$(mktemp -d)" || { err "mktemp не сработал"; return 1; }
  info "Клонирую ${tag}"
  if ! git clone --quiet --depth 1 --branch "$tag" "$REPO_GIT" "$TMP/mod" 2>/dev/null; then
    err "Не скачался тег ${tag} — проверь имя и сеть"
    return 1
  fi
  src="$TMP/mod/src"
  [[ -f "$src/dkms.conf" ]] || { err "В теге нет src/dkms.conf — структура репозитория изменилась"; return 1; }

  # Пробная компиляция ДО удаления старой сборки: если новый код не собирается
  # под это ядро, ничего не трогаем и выходим с рабочей системой.
  info "Пробная сборка (старая версия пока не тронута)"
  if ! make -C "$src" >"$TMP/build.log" 2>&1; then
    log "пробная сборка провалилась, обновление отменено"
    err "Новый код не собирается под ядро ${KVER} — обновление отменено"
    dim "Последние строки лога:"
    tail -15 "$TMP/build.log" | sed 's/^/      /'
    return 1
  fi
  ok "Пробная сборка прошла"

  if [[ -d "$SRC_DIR" ]]; then
    backup="$(backup_src)"
    if [[ -n "$backup" ]]; then ok "Резервная копия: $backup"
    else warn "Резервную копию сделать не вышло — откат будет только через git"; fi
  fi

  info "Убираю прежнюю DKMS-сборку"
  dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1
  rm -rf "$SRC_DIR"

  info "Раскладываю исходники в ${SRC_DIR}"
  if ! make -C "$src" dkms-install >/dev/null 2>&1; then
    err "make dkms-install не прошёл"
    [[ -n "$backup" ]] && restore_backup "$backup"
    return 1
  fi

  info "Сборка и установка через DKMS"
  if ! dkms_build_install; then
    [[ -n "$backup" ]] && restore_backup "$backup"
    return 1
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$tag" > "$TAG_FILE" 2>/dev/null
  log "установлено: ${tag} под ${KVER}"
  ok "Модуль ${tag} собран и установлен под ядро ${KVER}"
  warn "В памяти пока работает прежний модуль — нужна перезагрузка модуля"
  return 0
}

# ── Перезагрузка модуля ────────────────────────────────────

# true, если текущая SSH-сессия идёт через сам туннель: тогда inline-перезапуск
# оборвёт связь на stop, и start выполнить будет уже некому.
ssh_via_tunnel() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local srv_ip i
  srv_ip="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
  [[ -n "$srv_ip" ]] || return 1
  # Перебираем интерфейсы поимённо: фильтр «addr show type amneziawg» есть не
  # во всех версиях iproute2, а ошибиться тут — значит оборвать себе SSH.
  while read -r i; do
    [[ -n "$i" ]] || continue
    ip -o -4 addr show dev "$i" 2>/dev/null | grep -qF " ${srv_ip}/" && return 0
  done < <(awg_ifaces)
  return 1
}

# Юниты awg-quick, которые сейчас активны.
active_units() {
  systemctl list-units --type=service --state=active --no-legend --plain 'awg-quick@*' 2>/dev/null \
    | awk '{print $1}'
}

reload_module() {
  local units ifaces cmd
  units="$(active_units | tr '\n' ' ')"
  ifaces="$(awg_ifaces | tr '\n' ' ')"

  hdr "Перезагрузка модуля"
  dim "юниты     : ${units:-нет активных}"
  dim "интерфейсы: ${ifaces:-нет поднятых}"
  echo
  warn "Туннель ляжет на несколько секунд, клиенты переподключатся сами"
  # Вопрос задаём только человеку за терминалом: при запуске из cron/скрипта
  # флаг --latest без --no-reload уже означает согласие на перезапуск.
  if [[ -t 0 ]]; then
    read_confirm "Перезагружать модуль сейчас?" || { info "Отменено"; return 1; }
  fi

  # Списки уходят в команду через переменные, а не литералом: при пустом
  # списке «for u in ; do» — синтаксическая ошибка, а «for u in $EMPTY» —
  # корректный ноль итераций.
  cmd="UNITS='${units}'; IFACES='${ifaces}'; RC=0
set -x
for u in \$UNITS;  do systemctl stop \"\$u\"; done
for i in \$IFACES; do ip link show \"\$i\" >/dev/null 2>&1 || continue
  awg-quick down \"\$i\" 2>/dev/null || ip link del \"\$i\" 2>/dev/null; done
rmmod ${DKMS_NAME} || RC=3
modprobe ${DKMS_NAME} || RC=4
for u in \$UNITS;  do systemctl start \"\$u\"; done
exit \$RC"

  if ssh_via_tunnel; then
    warn "SSH идёт через сам туннель — запускаю отвязанно от сессии"
    if ! command -v systemd-run >/dev/null; then
      err "Нет systemd-run, а inline-перезапуск оборвёт эту сессию без возврата"
      dim "Зайди по внешнему IP и повтори, либо запусти вручную под screen/tmux"
      return 1
    fi
    systemd-run --unit=awg-mod-reload --collect bash -c "$cmd" >/dev/null 2>&1 \
      && ok "Запущено фоново (unit awg-mod-reload) — сессия сейчас оборвётся" \
      || { err "systemd-run не стартовал"; return 1; }
    dim "Через ~15 секунд переподключись и проверь: awg show"
    return 0
  fi

  local log rc
  log="$(mktemp)"
  bash -c "$cmd" >"$log" 2>&1; rc=$?
  sed 's/^/    /' "$log"
  { echo "--- перезагрузка модуля, rc=${rc} ---"; cat "$log"; } >> "$LOG_FILE" 2>/dev/null
  rm -f "$log"
  sleep 1

  if (( rc == 3 )); then
    log "rmmod не выгрузил модуль (rc=3)"
    err "rmmod не выгрузил модуль — в памяти остался прежний код"
    dim "Обычно мешает ещё один интерфейс (в том числе в netns):"
    dim "  ip -all netns exec ip link show type amneziawg"
    dim "Гарантированный путь — reboot: новый модуль уже лежит на диске"
    return 1
  fi
  if ! lsmod | grep -q "^${DKMS_NAME}"; then
    err "Модуль не загрузился — смотри dmesg | tail -20"
    return 1
  fi
  log "модуль перезагружен, srcversion в памяти: $(cat /sys/module/${DKMS_NAME}/srcversion 2>/dev/null)"
  ok "Модуль перезагружен, версия в памяти: $(module_ver)"
  local back
  back="$(awg_ifaces | tr '\n' ' ')"
  if [[ -n "$back" ]]; then ok "Интерфейсы подняты: ${back}"
  elif [[ -n "$ifaces" ]]; then err "Интерфейсы не вернулись: было ${ifaces}"
       dim "Подними вручную: systemctl start awg-quick@awg0"; fi
  return 0
}

verify() {
  hdr "Проверка"
  dkms_installed_here \
    && ok "DKMS: собран и установлен под ${KVER}" \
    || err "DKMS: под ${KVER} установленной сборки нет"
  if lsmod | grep -q "^${DKMS_NAME}"; then
    ok "Модуль загружен в ядро"
    # version.h апстрим не бумпает, поэтому сверяем srcversion загруженного
    # модуля с тем, что лежит на диске: разошлись — в памяти прежний код.
    local mem disk
    mem="$(cat /sys/module/${DKMS_NAME}/srcversion 2>/dev/null)"
    disk="$(modinfo -F srcversion "$DKMS_NAME" 2>/dev/null | head -1)"
    if [[ -z "$mem" || -z "$disk" ]]; then
      warn "srcversion не прочитался — сверить память и диск не вышло"
    elif [[ "$mem" == "$disk" ]]; then
      log "проверка: память=диск, srcversion ${mem}, тег $(saved_tag)"
      ok "В памяти тот же модуль, что на диске (srcversion ${mem})"
    else
      log "проверка: расхождение, память ${mem}, диск ${disk}"
      warn "В памяти прежний модуль: ${mem}, на диске ${disk}"
      dim "Нужна перезагрузка модуля (пункт 3) или сервера"
    fi
  else
    warn "Модуль не загружен (перезагрузи модуль или сервер)"
  fi
  local ifaces; ifaces="$(awg_ifaces | tr '\n' ' ')"
  [[ -n "$ifaces" ]] && ok "Интерфейсы: ${ifaces}" || warn "Поднятых интерфейсов нет"
  dmesg 2>/dev/null | grep -i 'amneziawg' | tail -3 | sed 's/^/      /'
}

# ── Меню ───────────────────────────────────────────────────

menu_pick_tag() {   # печатает выбранный тег или пусто
  local tags=() i choice
  mapfile -t tags < <(tags_fetch)
  if (( ${#tags[@]} == 0 )); then
    err "Список тегов не получен (сеть или лимит GitHub API)" >&2
    return 1
  fi
  (( ${#tags[@]} > 15 )) && tags=("${tags[@]:0:15}")
  echo >&2
  for i in "${!tags[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${tags[$i]}" >&2
  done
  echo -e "   0) Назад" >&2
  echo >&2
  read_choice choice "  Версия: " "${#tags[@]}" >&2
  (( choice == 0 )) && return 1
  echo "${tags[$((choice-1))]}"
}

menu_rollback() {
  local files=() i choice
  mapfile -t files < <(ls -1t "$BACKUP_DIR"/src-*.tar.gz 2>/dev/null)
  if (( ${#files[@]} == 0 )); then
    err "Резервных копий нет (${BACKUP_DIR})"; return 1
  fi
  hdr "Откат из резервной копии"
  for i in "${!files[@]}"; do
    printf "  %2d) %s  ${D}(%s)${N}\n" "$((i+1))" "$(basename "${files[$i]}")" \
      "$(date -r "${files[$i]}" '+%d.%m %H:%M' 2>/dev/null)"
  done
  echo -e "   0) Назад"; echo
  read_choice choice "  Копия: " "${#files[@]}"
  (( choice == 0 )) && return 1
  read_confirm "Откатить модуль на ${files[$((choice-1))]}?" || return 1
  restore_backup "${files[$((choice-1))]}" || return 1
  rm -f "$TAG_FILE" 2>/dev/null
  warn "Тег сброшен: после отката он неизвестен"
  reload_module
}

main_menu() {
  local latest="" choice tag
  while true; do
    clear 2>/dev/null
    hdr "Обновление модуля amneziawg  ${D}${VERSION}${N}"
    show_state
    # Один запрос к GitHub на весь сеанс: перерисовка меню не должна ходить в сеть.
    if [[ -z "$latest" ]]; then
      latest="$(latest_tag)"
      [[ -z "$latest" ]] && { latest="$FALLBACK_TAG"; warn "GitHub недоступен — беру запасной тег"; }
    fi
    echo
    echo -e "  ${W}1)${N} Обновить до последней версии  ${D}(${latest})${N}"
    echo -e "  ${W}2)${N} Выбрать версию из списка"
    echo -e "  ${W}3)${N} Только перезагрузить модуль"
    echo -e "  ${W}4)${N} Откат из резервной копии"
    echo -e "  ${W}5)${N} Проверка"
    echo -e "  ${W}0)${N} Выход"
    echo -e "  ${D}журнал: ${LOG_FILE}${N}"
    echo
    read_choice choice "  Пункт: " 5
    echo
    case "$choice" in
      1) if [[ "$(saved_tag)" == "$latest" ]]; then
           warn "Уже стоит ${latest}"
           read_confirm "Пересобрать всё равно?" || { read -rp "  Enter…" _; continue; }
         fi
         do_update "$latest" && { reload_module; verify; }
         read -rp "  Enter…" _ ;;
      2) tag="$(menu_pick_tag)" || { read -rp "  Enter…" _; continue; }
         [[ -n "$tag" ]] && { do_update "$tag" && { reload_module; verify; }; }
         read -rp "  Enter…" _ ;;
      3) reload_module; read -rp "  Enter…" _ ;;
      4) menu_rollback; read -rp "  Enter…" _ ;;
      5) verify; read -rp "  Enter…" _ ;;
      0) echo; info "Выход"; exit 0 ;;
    esac
  done
}

usage() {
  cat <<USAGE
awg-mod-update ${VERSION} — обновление ядерного модуля amneziawg через DKMS

  sudo awg-mod-update                 интерактивное меню
  sudo awg-mod-update --status        показать состояние и выйти
  sudo awg-mod-update --latest        обновить до последнего тега
  sudo awg-mod-update --tag vX.Y.Z    обновить до указанного тега
  sudo awg-mod-update --no-reload     не перезагружать модуль (с --latest/--tag)
  sudo awg-mod-update --list          список доступных тегов
  sudo awg-mod-update --help          эта справка

Ход работы дублируется в /var/log/awg-mod-update.log — меню перерисовывается
через clear, и с экрана результат уходит.

Перезагрузка модуля кладёт туннель на несколько секунд. Если SSH идёт через
сам туннель, скрипт уводит перезапуск в systemd-run, чтобы не потерять сервер.
USAGE
}

main() {
  local tag="" do_reload=1 action="menu"
  while (( $# )); do
    case "$1" in
      --help|-h)   usage; exit 0 ;;
      --status)    action="status" ;;
      --list)      action="list" ;;
      --latest)    action="update" ;;
      --tag)       shift; [[ -n "${1:-}" ]] || die "--tag без значения"
                   [[ "$1" =~ ^v?[0-9][0-9A-Za-z._-]*$ ]] || die "Странный тег: $1"
                   tag="$1"; action="update" ;;
      --no-reload) do_reload=0 ;;
      *)           die "Неизвестный аргумент: $1 (см. --help)" ;;
    esac
    shift
  done

  # root нужен всему, кроме справки и списка тегов.
  [[ "$action" == "list" || $EUID -eq 0 ]] || die "Запускай от root: sudo bash $0"

  case "$action" in
    status) show_state; verify; exit 0 ;;
    list)   tags_fetch || die "Список тегов не получен"; exit 0 ;;
    update)
      [[ -z "$tag" ]] && { tag="$(latest_tag)"; [[ -z "$tag" ]] && tag="$FALLBACK_TAG"; }
      do_update "$tag" || exit 1
      (( do_reload )) && { reload_module || exit 1; }
      verify; exit 0 ;;
    *) main_menu ;;
  esac
}

main "$@"
