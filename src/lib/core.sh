# Базовые примитивы: вывод, ввод, журнал, временные файлы, случайные числа,
# запуск встроенного Python и генерация самостоятельных служебных скриптов.

R='\033[38;5;203m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[1;94m'; M='\033[0;35m'; C='\033[0;36m'
W='\033[1;37m'; D='\033[0;90m'; N='\033[0m'

# Неинтерактивный режим (--auto, --add-client, вызовы из бота и таймеров):
# ни один шаг не должен ждать ввода.
AUTO_MODE=0

ok()   { echo -e "${G}  √ $*${N}"; }
err()  { echo -e "${R}  × $*${N}"; }
warn() { echo -e "${Y}  ▲ $*${N}"; }
info() { echo -e "${C}  → $*${N}"; }
dim()  { echo -e "${D}    $*${N}"; }

LINE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
hdr() {
  echo -e "${B}${LINE}${N}"
  echo -e "  ${W}$*${N}"
  echo -e "${B}${LINE}${N}"
}
success_box() {
  echo -e "${G}${LINE}${N}"
  echo -e "  ${W}$*${N}"
  echo -e "${G}${LINE}${N}"
}

# ── Журнал ────────────────────────────────────────────────
log_to() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
log_info() { log_to INFO "$@"; }
log_warn() { log_to WARN "$@"; }
log_err()  { log_to ERROR "$@"; }

log_init() {
  if ! { touch "$LOG_FILE" && chmod 600 "$LOG_FILE"; } 2>/dev/null; then
    LOG_FILE="/tmp/awg-manager.log"
    return 0
  fi
  local size
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > 5242880 )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
}

# ── Ввод ──────────────────────────────────────────────────
# Контракт всех функций ввода: Ctrl+D (EOF) = отмена и никогда не роняет
# скрипт; мусор переспрашивается; опасное подтверждается полным словом.

_flush_stdin() {
  [[ -t 0 ]] || return 0
  local _
  while read -r -t 0.05 -n 256 _ 2>/dev/null; do :; done
}

# read_line VAR "промпт" — свободный ввод, EOF = пустая строка.
read_line() {
  local __var="$1" __prompt="${2:-}" __val=""
  _flush_stdin
  if ! IFS= read -r -p "$(echo -e "$__prompt")" __val; then
    echo >&2
    __val=""
  fi
  printf -v "$__var" '%s' "$__val"
}

# read_choice VAR "промпт" MIN MAX [DEFAULT] [ДОП_КЛАВИШИ через |]
# На EOF отдаёт DEFAULT, а без него MIN (в меню это «назад»).
read_choice() {
  local __var="$1" __prompt="$2" __min="$3" __max="$4" __def="${5:-}" __extra="${6:-}"
  local __v __k __keys=()
  [[ -n "$__extra" ]] && IFS='|' read -r -a __keys <<< "$__extra"
  while true; do
    _flush_stdin
    if ! read -r -p "$(echo -e "$__prompt")" __v; then
      echo >&2
      __v="${__def:-$__min}"
      break
    fi
    __v="${__v//[[:space:]]/}"
    if [[ -z "$__v" && -n "$__def" ]]; then __v="$__def"; break; fi
    if [[ "$__v" =~ ^[0-9]+$ ]] && (( 10#$__v >= __min && 10#$__v <= __max )); then
      __v=$((10#$__v)); break
    fi
    for __k in ${__keys[@]+"${__keys[@]}"}; do
      [[ "${__v,,}" == "${__k,,}" ]] && { __v="${__k,,}"; break 2; }
    done
    if [[ -n "$__extra" ]]; then
      echo -e "${R}  Введи число от ${__min} до ${__max} или: ${__extra//|/, }${N}" >&2
    else
      echo -e "${R}  Введи число от ${__min} до ${__max}${N}" >&2
    fi
  done
  printf -v "$__var" '%s' "$__v"
}

# read_yesno VAR "промпт" [y|n] — результат y или n.
read_yesno() {
  local __var="$1" __prompt="$2" __def="${3:-}" __v
  while true; do
    _flush_stdin
    if ! read -r -p "$(echo -e "$__prompt")" __v; then
      echo >&2
      __v="${__def:-n}"
      break
    fi
    if [[ -z "$__v" && -n "$__def" ]]; then __v="$__def"; break; fi
    case "${__v,,}" in
      y|yes|д|да) __v=y; break ;;
      n|no|н|нет) __v=n; break ;;
      *) echo -e "${R}  Ответь y/да или n/нет${N}" >&2 ;;
    esac
  done
  printf -v "$__var" '%s' "$__v"
}

# Путь, подменить который может только root: он сам и все каталоги до /
# принадлежат root и закрыты на запись группе и остальным. Код оттуда можно
# запускать от root; из /tmp или домашнего каталога пользователя — нет:
# туда подложит или переименует любой пользователь сервера.
root_only_path() {  # путь
  local p m
  p=$(readlink -f -- "$1" 2>/dev/null) && [[ -e "$p" ]] || return 1
  while :; do
    [[ "$(stat -c %u -- "$p" 2>/dev/null)" == 0 ]] || return 1
    m=$(stat -c %a -- "$p" 2>/dev/null) || return 1
    (( 8#$m & 8#022 )) && return 1
    [[ "$p" == / ]] && return 0
    p=$(dirname -- "$p")
  done
}

# То же для каталога и всего, что в нём.
root_only_tree() {  # каталог
  local p
  # find — по настоящему пути: каталог-ссылку он сам не обходит
  p=$(readlink -f -- "$1" 2>/dev/null) && root_only_path "$p" || return 1
  [[ -z "$(find "$p" \( ! -user 0 -o \( ! -type l -perm /022 \) \) -print -quit 2>/dev/null)" ]]
}

# Путь для вывода через echo -e: без управляющих символов и \-последовательностей
# (имя каталога задаёт кто угодно — оно не должно перерисовать вопрос).
shown() { local s="${1//\\/\\\\}"; printf '%s' "$s" | tr '\000-\037\177' '?'; }

# ask_yes "вопрос" [y|n] — то же как условие: if ask_yes ...; then
ask_yes() {
  local __a
  if (( AUTO_MODE )); then [[ "${2:-n}" == y ]]; return; fi
  read_yesno __a "$1" "${2:-}"
  [[ "$__a" == y ]]
}

# Подтверждение необратимого действия: только слово yes или да.
read_confirm() {
  local __v
  (( AUTO_MODE )) && return 1
  _flush_stdin
  if ! read -r -p "$(echo -e "$1")" __v; then echo >&2; return 1; fi
  [[ "${__v,,}" == yes || "${__v,,}" == да ]]
}

pause() {
  (( AUTO_MODE )) && return 0
  local _
  read -r -p "$(echo -e "${C}  Enter для продолжения...${N}")" _ || true
}

# ── Долгие шаги ───────────────────────────────────────────
# apt, git, make и dkms пишут сотни строк, в которых тонет настоящая ошибка.
# run_step прячет вывод в INSTALL_LOG и оставляет одну строку на шаг, а при
# провале показывает хвост именно этого шага.
_RUN_STEP_PID=""

# Фоновый сабшелл шага не передаёт SIGINT детям (apt-get, dkms, make):
# убиваем дерево целиком, иначе сборка продолжается после «Прервано».
_kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _kill_tree "$c"; done
  kill -TERM "$1" 2>/dev/null
}

_run_step_abort() {
  [[ -n "$_RUN_STEP_PID" ]] && _kill_tree "$_RUN_STEP_PID"
  printf '\r\033[K\n'
  warn "Прервано пользователем"
  exit 130
}

run_step() {
  local title="$1"; shift
  local from=0 t0=$SECONDS rc=0 i=0 frames='-\|/' prev_trap
  [[ -f "$INSTALL_LOG" ]] && from=$(wc -l < "$INSTALL_LOG")
  printf '[%s] [STEP] %s\n' "$(date '+%F %T')" "$title" >> "$INSTALL_LOG"

  if [[ -t 1 ]]; then
    ( "$@" ) </dev/null >>"$INSTALL_LOG" 2>&1 &
    _RUN_STEP_PID=$!
    prev_trap=$(trap -p INT)
    trap _run_step_abort INT
    while kill -0 "$_RUN_STEP_PID" 2>/dev/null; do
      printf '\r  %b%s%b %s ' "$C" "${frames:i++%4:1}" "$N" "$title"
      sleep 0.2
    done
    wait "$_RUN_STEP_PID" || rc=$?
    eval "${prev_trap:-trap - INT}"
    _RUN_STEP_PID=""
    printf '\r\033[K'
  else
    ( "$@" ) </dev/null >>"$INSTALL_LOG" 2>&1 || rc=$?
  fi

  if (( rc == 0 )); then
    printf '  %b√%b %s %b(%dс)%b\n' "$G" "$N" "$title" "$D" "$((SECONDS - t0))" "$N"
    return 0
  fi
  printf '  %b×%b %s %b(код %d, %dс)%b\n' "$R" "$N" "$title" "$D" "$rc" "$((SECONDS - t0))" "$N"
  warn "Последние строки шага:"
  tail -n "+$((from + 2))" "$INSTALL_LOG" 2>/dev/null | tail -n 15 | sed 's/^/    /'
  info "Полный вывод: $INSTALL_LOG"
  return "$rc"
}

# ── Временные файлы ───────────────────────────────────────
_TMP_PATHS=()

# mktmp VAR [-d] — временный файл/каталог, удаляется при выходе.
mktmp() {  # ПЕРЕМЕННАЯ [-d | .расширение]
  local __var="$1" __p
  case "${2:-}" in
    -d) __p=$(mktemp -d /tmp/awg2.XXXXXX) ;;
    .*) __p=$(mktemp --suffix="$2" /tmp/awg2.XXXXXX) ;;
    *)  __p=$(mktemp /tmp/awg2.XXXXXX) ;;
  esac || return 1
  _TMP_PATHS+=("$__p")
  printf -v "$__var" '%s' "$__p"
}

_cleanup_tmp() {
  local p
  for p in ${_TMP_PATHS[@]+"${_TMP_PATHS[@]}"}; do rm -rf "$p" 2>/dev/null || true; done
  _TMP_PATHS=()
}

# Атомарная запись: stdin → файл с правами $2 (по умолчанию 600).
write_file() {
  local path="$1" mode="${2:-600}" tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "$(dirname "$path")/.awg2.XXXXXX") || return 1
  if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod "$mode" "$tmp" && mv -f "$tmp" "$path"
}

# ── Прочее ────────────────────────────────────────────────
# Равномерное целое в [lo, hi]. SRANDOM (bash 5.1+) — 32 бита из getrandom;
# отбраковка убирает перекос остатка от деления на больших диапазонах (H1-H4).
rand_range() {
  local lo="$1" hi="$2" span lim r
  (( hi <= lo )) && { echo "$lo"; return 0; }
  span=$(( hi - lo + 1 ))
  lim=$(( 4294967296 - 4294967296 % span ))
  while r=$SRANDOM; (( r >= lim )); do :; done
  echo $(( lo + r % span ))
}

rand_name() {  # xkqve_73
  local a='abcdefghijklmnopqrstuvwxyz' s='' i
  for i in 1 2 3 4 5; do s+="${a:$(rand_range 0 25):1}"; done
  printf '%s_%02d\n' "$s" "$(rand_range 0 99)"
}

fmt_duration() {  # 5с / 3м12с / 2ч15м / 3д4ч
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "?"; return; }
  if   (( s < 60 ));    then echo "${s}с"
  elif (( s < 3600 ));  then echo "$((s/60))м$((s%60))с"
  elif (( s < 86400 )); then echo "$((s/3600))ч$(((s%3600)/60))м"
  else echo "$((s/86400))д$(((s%86400)/3600))ч"; fi
}

fmt_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  if   (( b >= 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.2f ГБ", b/1073741824}'
  elif (( b >= 1048576 ));    then awk -v b="$b" 'BEGIN{printf "%.1f МБ", b/1048576}'
  else echo "$(( (b + 1023) / 1024 )) КБ"; fi
}

# Версия "v0.8.35" → сравнимое число. Результат начинается с нуля, поэтому
# сравнивать только через 10#.
ver_num() { echo "${1#v}" | awk -F'[.-]' '{printf "%d%03d%03d\n", $1, $2, $3}'; }

# Встроенный Python читается с дескриптора: код не упирается в предел длины
# аргумента (128 КБ), а stdin остаётся свободным для данных.
# Помощник один раз на версию кладётся файлом в $STATE_DIR/py — Python
# кэширует его байткод рядом, и запуск не компилирует ~90 КБ кода заново
# (а awg2 api зовёт помощник дважды на вызов). Нет прав или места — как
# раньше, с дескриптора. В служебных скриптах (emit_script) _py_mod нет.
_PY_MOD=""
_py_mod() {
  local d="$STATE_DIR/py/$_PY_HELPER_SUM" tmp
  [[ -n "$_PY_MOD" ]] && return 0
  [[ -n "${_PY_HELPER_SUM:-}" ]] || return 1
  if [[ ! -f "$d/awg2helper.py" ]]; then
    mkdir -p "$d" 2>/dev/null && chmod 700 "$STATE_DIR/py" "$d" 2>/dev/null || return 1
    tmp="$d/.awg2helper.$$"
    printf '%s' "$_PY_HELPER" > "$tmp" 2>/dev/null && mv -f "$tmp" "$d/awg2helper.py" || { rm -f "$tmp"; return 1; }
    find "$STATE_DIR/py" -mindepth 1 -maxdepth 1 -type d ! -name "$_PY_HELPER_SUM" -exec rm -rf {} + 2>/dev/null
  fi
  _PY_MOD="$d"
}
py() {
  if declare -F _py_mod >/dev/null && _py_mod; then
    python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv.pop(1)); import awg2helper; awg2helper.main()' "$_PY_MOD" "$@"
  else
    python3 /dev/fd/3 "$@" 3<<< "$_PY_HELPER"
  fi
}
cps() { python3 /dev/fd/3 "$@" 3<<< "$_CPS_GENERATOR"; }

# Самостоятельный служебный скрипт из функций и переменных awg2.
# Нужен для всего, что systemd вызывает без awg2: при загрузке, из таймеров
# и хуков. Логика остаётся в одном месте, а скрипт работает, даже если awg2
# удалён или заменён другой версией.
#   emit_script ПУТЬ "ТОЧКА_ВХОДА" имя...  (имя — функция или переменная)
emit_script() {
  local path="$1" entry="$2" item
  shift 2
  {
    printf '#!/bin/bash\n# Сгенерировано awg2 %s. Не редактировать: файл перезаписывается.\nset -u\n' "$VERSION"
    for item in "$@"; do
      if declare -F "$item" >/dev/null; then declare -f "$item"
      else declare -p "$item"; fi
    done
    printf '%s\n' "$entry"
  } | write_file "$path" 755
}
