# Компоненты AmneziaWG: модуль ядра (git + DKMS) и amneziawg-tools.
#
# Проверка отвечает на вопросы, из-за которых сервер «молча не работает»:
# собран ли модуль под работающее и под самое новое ядро, та ли сборка
# сейчас в памяти, что лежит на диске, умеют ли модуль и tools AWG 3.1, есть
# ли в модуле фикс хвостов RandomTrailers у пакетов I1-I5, не вышла ли
# новая версия у апстрима.

# ── Состояние ─────────────────────────────────────────────
tools_version() {
  command -v awg &>/dev/null || return 0
  awg --version 2>/dev/null | grep -oE 'v[0-9][0-9A-Za-z.-]*' | head -1
}

mod_loaded() { [[ -d /sys/module/$MOD_NAME ]]; }

# Сборка модуля по исходникам в DKMS. version.h апстрим не бумпает (у тегов
# 20260812-20260906 он один и тот же), поэтому ориентируемся на изменения,
# которые принёс каждый тег.
mod_src_fingerprint() {
  local s="$MOD_SRC_DIR"
  [[ -d "$s" ]] || return 0
  if grep -qE 'bool[[:space:]]+trailer' "$s/socket.h" 2>/dev/null; then echo "v3.1.20260906"
  elif grep -q 'wg_peer_skb_randomize_padding_addition' "$s/peer.h" 2>/dev/null; then echo "v3.1.20260828"
  elif grep -q 'down_write(&p->lock)' "$s/header_protection.c" 2>/dev/null; then echo "v3.1.20260827"
  elif grep -q 'WGDEVICE_A_RANDOM_TRAILERS' "$s/uapi/wireguard.h" 2>/dev/null; then echo "v3.1.20260812"
  elif grep -q 'WGDEVICE_A_HEADER_PROTECTION_KEY' "$s/uapi/wireguard.h" 2>/dev/null; then echo "v3.0"
  else echo "v1.0"; fi
}

# Тег модуля: записанный при сборке, а без записи — «не старше» по исходникам.
mod_tag() {
  local t
  t=$(tr -d '[:space:]' 2>/dev/null < "$MOD_TAG_FILE" || true)
  if [[ -n "$t" ]]; then echo "$t"; return 0; fi
  t=$(mod_src_fingerprint)
  [[ -n "$t" ]] && echo "≈$t"
  return 0
}

tools_tag() {
  local t
  t=$(tr -d '[:space:]' 2>/dev/null < "$TOOLS_TAG_FILE" || true)
  echo "${t:-$(tools_version)}"
}

# Семейство протокола сборки: 3.1 / 3.0 / 2.0.
tag_family() {
  local t="${1#≈}"
  case "$t" in v3.1*|3.1*) echo 3.1 ;; v3.0*|3.0*) echo 3.0 ;; "") echo "" ;; *) echo 2.0 ;; esac
}

# Фикс хвостов RandomTrailers у I1-I5 (v3.1.20260906): 0 есть, 1 нет, 2 неизвестно.
mod_trailer_fix() {
  local f="$MOD_SRC_DIR/socket.h"
  [[ -f "$f" ]] || return 2
  grep -q 'wg_socket_send_buffer_to_peer' "$f" || return 2
  grep -qE 'bool[[:space:]]+trailer' "$f"
}

mod_built_for() { modinfo -k "$1" "$MOD_NAME" &>/dev/null; }

# В памяти не та сборка, что на диске: dkms install прошёл, а ядро работает
# со старым модулем. srcversion — хеш исходников, вшитый при сборке; плюс
# случай «исходники обновили, а пересобрать забыли».
mod_stale() {
  mod_loaded || return 1
  local ko live disk newest=0 t kt
  ko=$(modinfo -n "$MOD_NAME" 2>/dev/null) || return 1
  [[ -f "$ko" ]] || return 1
  live=$(cat "/sys/module/$MOD_NAME/srcversion" 2>/dev/null || true)
  disk=$(modinfo -F srcversion "$ko" 2>/dev/null || true)
  [[ -n "$live" && -n "$disk" && "$live" != "$disk" ]] && return 0
  for t in "$MOD_SRC_DIR"/*.[ch]; do
    [[ -f "$t" ]] || continue
    t=$(stat -c %Y "$t"); (( t > newest )) && newest=$t
  done
  kt=$(stat -c %Y "$ko" 2>/dev/null || echo 0)
  (( newest > 0 && kt > 0 && newest > kt ))
}

# Ядра, в которые сервер может загрузиться (работающее и новее), без
# собранного модуля — после перезагрузки в такое ядро awg0 не поднимется.
# Так бывает, когда apt поставил новое ядро, а DKMS не смог собрать под него
# модуль (Ubuntu 7.0.0-38) или заголовков к нему нет. Строки «ядро» или
# «ядро нет-заголовков»; пусто — всё в порядке.
kernel_gap() {
  local k running
  command -v dkms &>/dev/null && [[ -d "$MOD_SRC_DIR" ]] || return 0
  running=$(uname -r)
  for k in $(installed_kernels); do
    [[ "$(printf '%s\n%s\n' "$running" "$k" | sort -V | head -1)" == "$running" ]] || continue
    mod_built_for "$k" && continue
    [[ "$k" == "$running" ]] && mod_loaded && continue
    if [[ -d "/lib/modules/$k/build" ]]; then echo "$k"; else echo "$k нет-заголовков"; fi
  done
}

# Одной строкой для сводок: «6.8.0-150» или «6.8.0-150 (нет заголовков)».
# others — без работающего ядра (о нём говорит reboot_reason).
kernel_gap_line() {  # [others]
  local skip=""
  [[ "${1:-}" == others ]] && skip=$(uname -r)
  kernel_gap | awk -v r="$skip" 'r == "" || $1 != r' | sed 's/ нет-заголовков$/ (нет заголовков)/' | paste -sd, - | sed 's/,/, /g'
}

# Почему нужна перезагрузка (сервера или модуля). Пусто — не нужна.
reboot_reason() {
  local running newest
  running=$(uname -r)
  if ! mod_loaded; then
    mod_built_for "$running" && echo "модуль собран, но не загружен (поможет modprobe)" \
      || echo "модуль не собран под работающее ядро $running"
    return 0
  fi
  newest=$(installed_kernels | tail -1)
  if [[ -n "$newest" && "$newest" != "$running" ]]; then
    echo "работает ядро $running, установлено более новое $newest"
  elif mod_stale; then
    echo "в памяти прежняя сборка модуля — нужна перезагрузка модуля"
  elif [[ -f /run/reboot-required ]]; then
    echo "система просит перезагрузку после обновления пакетов"
  fi
}

# Чего не хватает для версии $1 (3.0 | 3.1) — по надёжным признакам:
# components — awg не установлен; tools — amneziawg-tools не знают её ключа
# (они сами разбирают конфиг); module — модуль на диске собран из тега без неё;
# check — признаков «нет» нет, решает проба (proto_supported).
proto_why() {  # версия
  local key=HeaderProtectionKey fam
  [[ "$1" == 3.1 ]] && key=RandomTrailers
  command -v awg &>/dev/null || { echo components; return 0; }
  grep -qa "$key" "$(command -v awg)" || { echo tools; return 0; }
  fam=$(tag_family "$(mod_tag)")
  if [[ -n "$fam" ]] && [[ "$fam" == 2.0 || ( "$1" == 3.1 && "$fam" == 3.0 ) ]]; then echo module; return 0; fi
  echo check
}

# Умеют ли компоненты версию протокола $1 (3.0 | 3.1).
# 0 — да, 1 — точно нет, 2 — подтвердить не удалось.
# «Нет» говорим только по надёжным признакам: tools не знают ключа (они сами
# разбирают конфиг) или модуль на диске собран из тега без поддержки.
_PROTO_PROBE=()
proto_supported() {
  local proto="$1" key val rc dev tmp
  [[ -n "${_PROTO_PROBE[${proto//./}]:-}" ]] && return "${_PROTO_PROBE[${proto//./}]}"
  case "$proto" in
    3.1) key=RandomTrailers; val=on ;;
    *)   key=HeaderProtectionKey; val="" ;;
  esac
  rc=2
  if [[ "$(proto_why "$proto")" != check ]]; then
    rc=1
  elif awg showconf "$AWG_IF" 2>/dev/null | grep -q "^$key"; then
    rc=0
  else
    # Проба, прерванная раньше (тайм-аут бота, kill), оставляла интерфейс
    for dev in $(ip -o link show type amneziawg 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}'); do
      [[ "$dev" =~ ^awgprb([0-9]+)$ ]] && ! kill -0 "${BASH_REMATCH[1]}" 2>/dev/null \
        && ip link del dev "$dev" &>/dev/null
    done
    dev="awgprb$BASHPID"
    if ip link add dev "$dev" type amneziawg 2>/dev/null; then
      tmp=$(mktemp)
      [[ -n "$val" ]] || val=$(awg genkey)
      printf '[Interface]\nPrivateKey = %s\n%s = %s\n' "$(awg genkey)" "$key" "$val" > "$tmp"
      awg setconf "$dev" "$tmp" &>/dev/null && rc=0
      rm -f "$tmp"
      ip link del dev "$dev" &>/dev/null || true
    fi
  fi
  _PROTO_PROBE[${proto//./}]=$rc
  return "$rc"
}

# ── Версии апстрима ───────────────────────────────────────
# git ls-remote, а не API GitHub: у API лимит 60 запросов в час на IP, и на
# общих IP хостеров он исчерпан постоянно.
upstream_tags() {  # repo_url → теги от новых к старым
  command -v git &>/dev/null || return 0
  GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote --tags --refs "$1" 2>/dev/null \
    | sed -n 's#.*refs/tags/##p' | grep -E '^v[0-9]' | sort -Vr || true
}

upstream_refresh() {
  local m t
  m=$(upstream_tags "$MOD_REPO" | head -1)
  t=$(upstream_tags "$TOOLS_REPO" | head -1)
  [[ -n "$m" || -n "$t" ]] || return 1
  mkdir -p "$STATE_DIR"
  printf 'mod=%s\ntools=%s\nts=%s\n' "$m" "$t" "$(date +%s)" > "$UPSTREAM_CACHE"
}

upstream_refresh_async() {
  local ts=0
  [[ -n "${AWG_NO_UPDATE_CHECK:-}" ]] && return 0
  ts=$(sed -n 's/^ts=//p' "$UPSTREAM_CACHE" 2>/dev/null || echo 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  (( $(date +%s) - ts < UPSTREAM_TTL )) && return 0
  # Дескрипторы 3/4/8 открыты у awg2 api: фоновый процесс не должен держать
  # пайп ответа — иначе вызывающий ждал бы его до конца проверки
  ( upstream_refresh ) </dev/null >/dev/null 2>&1 3>&- 4>&- 8>&- &
  disown 2>/dev/null || true
}

upstream_latest() { sed -n "s/^$1=//p" "$UPSTREAM_CACHE" 2>/dev/null | head -1; }

tag_newer() {  # $1 новее $2?
  [[ -n "$1" && -n "$2" && "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# Доступное обновление модуля (тег) или пусто.
mod_update_available() {
  local cur latest
  latest=$(upstream_latest mod)
  cur=$(mod_tag); cur="${cur#≈}"
  [[ -n "$cur" && -n "$latest" ]] && tag_newer "$latest" "$cur" && echo "$latest"
  return 0
}

tools_update_available() {
  local cur latest
  latest=$(upstream_latest tools); cur=$(tools_tag)
  [[ -n "$cur" && -n "$latest" ]] && tag_newer "$latest" "$cur" && echo "$latest"
  return 0
}

# Строка состояния для шапки меню.
components_summary() {
  local tag upd reason gap
  command -v awg &>/dev/null || { echo -e "${R}не установлены${N} ${D}— Сервер → Установить компоненты${N}"; return; }
  tag=$(mod_tag)
  reason=$(reboot_reason)
  upd=$(mod_update_available)
  # Работающее ядро без модуля — это reboot_reason; но и оно не должно
  # прятать более новое ядро без модуля (раньше — проверка по префиксу)
  gap=$(kernel_gap_line others)
  if [[ -n "$gap" ]]; then
    echo -e "${R}${tag:-?} ▲ ядро $gap без модуля AWG${N} ${D}— после перезагрузки VPN не поднимется:${N}"
    echo -e "               ${D}Сервер → Модуль ядра → 5) Пересобрать${N}"
    [[ -n "$reason" ]] && echo -e "               ${Y}▲ ${reason}${N}"
  elif [[ -n "$reason" ]]; then
    echo -e "${Y}${tag:-?} ▲ ${reason}${N}"
  elif [[ -n "$upd" ]]; then
    echo -e "${W}${tag}${N} ${G}⬆ есть $upd${N} ${D}— Сервер → Модуль ядра${N}"
  else
    echo -e "${W}${tag:-?}${N} ${G}✓${N}"
  fi
}

# ── Отчёт ─────────────────────────────────────────────────
components_report() {
  local k running newest tag tt fam upd tupd s
  running=$(uname -r)
  newest=$(installed_kernels | tail -1)
  tag=$(mod_tag); tt=$(tools_tag); fam=$(tag_family "$tag")
  upd=$(mod_update_available); tupd=$(tools_update_available)

  hdr "Модуль ядра и amneziawg-tools"
  echo -e "  Ядро           : ${W}$running${N}"
  if [[ -n "$tt" ]]; then
    echo -e "  amneziawg-tools: ${W}$tt${N}${tupd:+  ${G}⬆ доступна $tupd${N}}"
  else
    echo -e "  amneziawg-tools: ${R}не установлены${N}"
  fi
  if [[ -d "$MOD_SRC_DIR" ]]; then
    s="$tag"; [[ "$tag" == ≈* ]] && s="${tag#≈} ${D}(по исходникам, не старше)${N}"
    echo -e "  Модуль (диск)  : ${W}$s${N}${upd:+  ${G}⬆ доступен $upd${N}}"
  else
    echo -e "  Модуль (диск)  : ${R}исходников в DKMS нет${N}"
  fi

  if ! mod_loaded; then
    echo -e "  Модуль (память): ${R}не загружен${N}"
  elif mod_stale; then
    echo -e "  Модуль (память): ${Y}прежняя сборка — нужна перезагрузка модуля${N}"
  else
    echo -e "  Модуль (память): ${G}загружен, совпадает с диском${N}"
  fi

  for k in $(installed_kernels); do
    s="${R}✗ не собран${N}"
    [[ -n "$(kernel_gap | awk -v k="$k" '$1 == k')" ]] && s="${R}✗ не собран — пункт 5${N}"
    mod_built_for "$k" && s="${G}✓ собран${N}"
    [[ -d "/lib/modules/$k/build" ]] || s+=" ${D}(нет заголовков)${N}"
    [[ "$k" == "$running" ]] && s+=" ${D}← работает${N}"
    [[ "$k" == "$newest" && "$k" != "$running" ]] && s+=" ${Y}← загрузится после ребута${N}"
    echo -e "  DKMS $k: $s"
  done

  if proto_supported 3.1; then s="${G}поддерживается${N}"
  else
    case $? in
      1) s="${R}нет${N} ${D}— нужны модуль и tools v3.1${N}" ;;
      *) s="${D}не подтверждено${N}" ;;
    esac
  fi
  echo -e "  AWG 3.1        : $s"
  if [[ "$fam" == 3.1 ]]; then
    if mod_trailer_fix; then s="${G}есть${N}"; else s="${Y}нет — хвосты портят I1-I5, обнови модуль${N}"; fi
    echo -e "  Фикс I1-I5     : $s"
  fi
  secure_boot_on && echo -e "  Secure Boot    : ${Y}включён — неподписанный DKMS-модуль не загрузится${N}"
  if grep -qs "^$MOD_NAME" "$MODULES_LOAD_FILE"; then s="${G}настроена${N}"; else s="${Y}нет${N}"; fi
  echo -e "  Автозагрузка   : $s"
  s=$(reboot_reason)
  [[ -n "$s" ]] && { echo ""; warn "$s"; }
  return 0
}

# ── Сборка ────────────────────────────────────────────────
mod_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$MOD_LOG" 2>/dev/null || true; }

components_deps() {
  need_cmds git:git make:build-essential gcc:build-essential dkms:dkms pkg-config:pkg-config \
    || return 1
  dpkg -s libmnl-dev &>/dev/null || apt_install libmnl-dev >/dev/null 2>&1 || { err "Не ставится libmnl-dev"; return 1; }
}

# Клон тега в каталог $2 (с проверкой, что тег существует).
_git_clone_tag() {
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$1" "$3" "$2"
}

# Ядро для пробной сборки: работающее, а без его заголовков — самое новое
# из тех, для которых заголовки есть.
build_kernel() {
  local k
  [[ -d "/lib/modules/$(uname -r)/build" ]] && { uname -r; return 0; }
  for k in $(installed_kernels | sort -Vr); do
    [[ -d "/lib/modules/$k/build" ]] && { echo "$k"; return 0; }
  done
  return 1
}

# Пробная сборка в копии исходников, до того, как трогать установленную
# версию. В копии: dkms-install забирает все *.c каталога, и сгенерированный
# сборкой amneziawg.mod.c уехал бы в DKMS.
_mod_trial_build() { cp -a "$1" "$1.trial" && make -C "$1.trial" KERNELRELEASE="$2" -j"$(nproc)"; }

# Правки исходника модуля под ядра дистрибутивов (py mod-compat-patch): в
# Ubuntu 7.0.0-38 апстрим без неё не собирается. Нет нужного места в теге —
# исходник не трогается.
_mod_src_patch() {  # каталог src тега или исходник в DKMS
  [[ -d "$1" ]] || return 0
  [[ "$(py mod-compat-patch "$1" 2>/dev/null)" == patched ]] && mod_log "исходник $1: правка udp_tunnel для ядер дистрибутивов"
  return 0
}

# Сборка под все ядра с заголовками. Ядро, поставленное раньше регистрации
# модуля в DKMS, автосборку не получит — после перезагрузки в него awg0 не
# поднялся бы. Провал под работающим ядром — ошибка, под остальными —
# предупреждение в журнале шага.
_mod_dkms_install_all() {
  local k running built=0 rc=0
  running=$(uname -r)
  _mod_src_patch "$MOD_SRC_DIR"
  dkms add -m "$MOD_NAME" -v "$MOD_DKMS_VER" >/dev/null 2>&1 || true
  for k in $(installed_kernels); do
    [[ -d "/lib/modules/$k/build" ]] || continue
    if dkms install -m "$MOD_NAME" -v "$MOD_DKMS_VER" -k "$k" --force; then
      built=$((built + 1))
    else
      echo "!!! сборка под $k не удалась"
      [[ "$k" == "$running" ]] && rc=1
    fi
  done
  (( built > 0 )) || rc=1
  return "$rc"
}

mod_backup_src() {  # → путь к архиву
  [[ -d "$MOD_SRC_DIR" ]] || return 0
  mkdir -p "$MOD_BACKUP_DIR" || return 1
  local t f
  t=$(mod_tag); t="${t#≈}"
  f="$MOD_BACKUP_DIR/src-${t:-unknown}-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar czf "$f" -C /usr/src "${MOD_NAME}-${MOD_DKMS_VER}" && echo "$f"
}

mod_restore_src() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  dkms remove -m "$MOD_NAME" -v "$MOD_DKMS_VER" --all >/dev/null 2>&1 || true
  rm -rf "$MOD_SRC_DIR"
  tar xzf "$f" -C /usr/src || return 1
  _mod_dkms_install_all
}

# Ставит модуль из тега $1. Старая сборка не трогается, пока новая не
# собралась пробно; при сбое установки — возврат из резервной копии.
mod_install_tag() {
  local tag="$1" tmp backup="" kver
  mktmp tmp -d || return 1
  mod_log "=== модуль $tag (ядро $(uname -r), было: $(mod_tag))"

  run_step "Загрузка модуля $tag" _git_clone_tag "$tag" "$tmp/mod" "$MOD_REPO" \
    || { err "Тег $tag не скачался — проверь имя тега и доступ к github.com"; return 1; }
  [[ -f "$tmp/mod/src/dkms.conf" ]] || { err "В теге нет src/dkms.conf — структура репозитория изменилась"; return 1; }
  _mod_src_patch "$tmp/mod/src"
  kver=$(build_kernel) || { err "Нет заголовков ни для одного ядра"; kernel_headers_help; return 1; }
  run_step "Пробная сборка под $kver" _mod_trial_build "$tmp/mod/src" "$kver" || {
    mod_log "пробная сборка не прошла"
    err "Модуль $tag не собирается под это ядро — установленная версия не тронута"
    return 1
  }

  if [[ -d "$MOD_SRC_DIR" ]]; then
    backup=$(mod_backup_src) && [[ -n "$backup" ]] && ok "Резервная копия исходников: $backup"
  fi
  dkms remove -m "$MOD_NAME" -v "$MOD_DKMS_VER" --all >/dev/null 2>&1 || true
  rm -rf "$MOD_SRC_DIR"

  if ! run_step "Установка исходников в DKMS" make -C "$tmp/mod/src" dkms-install \
     || ! run_step "Сборка DKMS под все ядра" _mod_dkms_install_all; then
    err "Установка модуля не удалась"
    if [[ -n "$backup" ]]; then
      run_step "Возврат прежней версии" mod_restore_src "$backup" && ok "Прежняя версия возвращена"
    fi
    return 1
  fi
  mkdir -p "$STATE_DIR"
  echo "$tag" > "$MOD_TAG_FILE"
  _PROTO_PROBE=()
  mod_log "установлен $tag"
  ok "Модуль $tag собран и установлен"
}

_tools_build_install() { make -C "$1" -j"$(nproc)" && make -C "$1" install; }

tools_install_tag() {
  local tag="$1" tmp bdir
  mktmp tmp -d || return 1
  run_step "Загрузка amneziawg-tools $tag" _git_clone_tag "$tag" "$tmp/tools" "$TOOLS_REPO" \
    || { err "Тег $tag не скачался"; return 1; }
  if command -v awg &>/dev/null; then
    bdir="$MOD_BACKUP_DIR/tools-$(tools_tag)-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bdir" && cp -a "$(command -v awg)" "$bdir/"
    command -v awg-quick &>/dev/null && cp -a "$(command -v awg-quick)" "$bdir/"
  fi
  run_step "Сборка amneziawg-tools $tag" _tools_build_install "$tmp/tools/src" || return 1
  hash -r
  mkdir -p "$STATE_DIR"
  echo "$tag" > "$TOOLS_TAG_FILE"
  _PROTO_PROBE=()
  ok "amneziawg-tools: $(tools_version)"
}

# Тег для установки: последний у апстрима, без сети — запасной.
resolve_tag() {  # mod|tools
  local t
  t=$(upstream_tags "$([[ "$1" == mod ]] && echo "$MOD_REPO" || echo "$TOOLS_REPO")" | head -1)
  if [[ -n "$t" ]]; then
    upstream_refresh >/dev/null 2>&1 || true
    echo "$t"
  elif [[ "$1" == mod ]]; then echo "$MOD_FALLBACK_TAG"
  else echo "$TOOLS_FALLBACK_TAG"; fi
}

mod_autoload() {
  grep -qs "^$MOD_NAME" "$MODULES_LOAD_FILE" || echo "$MOD_NAME" | write_file "$MODULES_LOAD_FILE" 644
}

# ── Перезагрузка модуля ───────────────────────────────────
awg_ifaces() { ip -o link show type amneziawg 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}'; }

# SSH идёт через сам туннель: перезапуск inline оборвёт сессию на stop, и
# выполнять start будет уже некому — уводим его в systemd-run.
_ssh_via_awg() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local dst i
  dst=$(awk '{print $3}' <<< "$SSH_CONNECTION")
  while read -r i; do
    [[ -n "$i" ]] && ip -o -4 addr show dev "$i" 2>/dev/null | grep -qF " ${dst}/" && return 0
  done < <(awg_ifaces)
  return 1
}

mod_reload() {
  local units ifaces cmd rc out
  units=$(systemctl list-units --type=service --state=active --no-legend --plain 'awg-quick@*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  ifaces=$(awg_ifaces | tr '\n' ' ')
  echo -e "  ${D}юниты: ${units:-нет}; интерфейсы: ${ifaces:-нет}${N}"
  warn "Туннели лягут на несколько секунд, клиенты переподключатся сами"
  (( AUTO_MODE )) || ask_yes "  Перезагрузить модуль сейчас? [Y/n]: " y || { info "Отменено"; return 1; }

  cmd="for u in $units; do systemctl stop \"\$u\"; done
for i in $ifaces; do ip link show \"\$i\" >/dev/null 2>&1 && { awg-quick down \"\$i\" 2>/dev/null || ip link del \"\$i\"; }; done
rmmod $MOD_NAME || { for u in $units; do systemctl start \"\$u\"; done; exit 3; }
modprobe $MOD_NAME || exit 4
for u in $units; do systemctl start \"\$u\"; done
exit 0"

  if _ssh_via_awg; then
    warn "SSH идёт через туннель — перезапуск отвязан от сессии (systemd-run)"
    systemd-run --unit=awg-mod-reload --collect bash -c "$cmd" >/dev/null 2>&1 \
      || { err "systemd-run не стартовал"; return 1; }
    info "Через ~15 секунд переподключись и проверь: awg show"
    return 0
  fi
  rc=0
  out=$(bash -c "$cmd" 2>&1) || rc=$?
  mod_log "перезагрузка модуля rc=$rc: $(tr '\n' ';' <<< "$out")"
  case $rc in
    0) _PROTO_PROBE=(); ok "Модуль перезагружен, в памяти новая сборка" ;;
    3) err "rmmod не выгрузил модуль — его держит ещё какой-то интерфейс; туннели подняты на прежней сборке"
       info "Проверь: ip -all netns exec ip link show type amneziawg"
       info "Надёжно — перезагрузка сервера: новая сборка уже на диске"
       return 1 ;;
    *) err "Модуль не загрузился — dmesg | tail -20"; return 1 ;;
  esac
}

# ── Действия из меню ──────────────────────────────────────
# mod_update_flow [тег] [force] — force: пересобрать, даже если тег уже стоит.
mod_update_flow() {
  local tag="${1:-}" force="${2:-}" cur
  components_deps || return 1
  ensure_headers "$(uname -r)" || { err "Нет заголовков ядра $(uname -r)"; kernel_headers_help; return 1; }
  if secure_boot_on; then
    warn "Secure Boot включён — ядро не загрузит неподписанный модуль"
    ask_yes "  Всё равно собрать? [y/N]: " n || return 1
  fi
  [[ -n "$tag" ]] || tag=$(resolve_tag mod)
  cur=$(mod_tag)
  if [[ "${cur#≈}" == "$tag" && "$force" != force ]]; then
    ask_yes "  Уже стоит $tag. Пересобрать? [y/N]: " n || { ok "Модуль $tag уже установлен"; return 0; }
  fi
  mod_install_tag "$tag" || return 1
  mod_autoload
  if mod_loaded; then mod_reload || true; else modprobe "$MOD_NAME" 2>/dev/null || true; fi
}

# Модуль и tools разом: для 3.1 нужны оба — бот и панель предлагают одну кнопку.
components_update_flow() {
  mod_update_flow || return 1
  tools_update_flow
}

tools_update_flow() {  # [force]
  local tag
  components_deps || return 1
  tag=$(resolve_tag tools)
  if [[ "$(tools_tag)" == "$tag" && "${1:-}" != force ]]; then
    ask_yes "  Уже стоит $tag. Пересобрать? [y/N]: " n || { ok "amneziawg-tools $tag уже установлены"; return 0; }
  fi
  tools_install_tag "$tag"
}

# Сборка под все ядра. Ядрам, в которые сервер может загрузиться, сначала
# ставятся недостающие заголовки — иначе их сборка молча пропускается.
mod_rebuild_all() {
  local k _
  components_deps || return 1
  while read -r k _; do
    [[ -n "$k" && ! -d "/lib/modules/$k/build" ]] || continue
    run_step "Заголовки ядра $k" ensure_headers "$k" || warn "Заголовков для $k в репозитории нет"
  done < <(kernel_gap)
  run_step "Сборка DKMS под все ядра" _mod_dkms_install_all || return 1
  if [[ -n "$(kernel_gap)" ]]; then
    warn "Модуль не собран под: $(kernel_gap_line) — после перезагрузки в это ядро awg0 не поднимется"
    info "Журнал сборки: $MOD_LOG и /var/lib/dkms/$MOD_NAME/$MOD_DKMS_VER/build/make.log"
    return 1
  fi
  ok "Модуль собран под все ядра"
}

mod_backups() { ls -1t "$MOD_BACKUP_DIR"/src-*.tar.gz 2>/dev/null || true; }

mod_rollback() {  # архив из mod_backups
  [[ -f "$1" && "$1" == "$MOD_BACKUP_DIR"/src-*.tar.gz ]] || { err "Нет такой резервной копии"; return 1; }
  run_step "Возврат модуля из ${1##*/}" mod_restore_src "$1" || return 1
  rm -f "$MOD_TAG_FILE"
  ok "Модуль возвращён из резервной копии"
  mod_reload || true
}

mod_pick_tag() {  # → тег в stdout
  local tags=() i c
  mapfile -t tags < <(upstream_tags "$MOD_REPO" | head -15)
  (( ${#tags[@]} )) || { err "Список тегов не получен (нет доступа к github.com)" >&2; return 1; }
  for i in "${!tags[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${tags[$i]}" >&2; done
  echo "   0) Назад" >&2
  read_choice c "${C}  Версия: ${N}" 0 "${#tags[@]}" "" >&2
  (( c == 0 )) && return 1
  echo "${tags[$((c-1))]}"
}

mod_rollback_flow() {
  local files=() i c
  mapfile -t files < <(mod_backups)
  (( ${#files[@]} )) || { warn "Резервных копий нет ($MOD_BACKUP_DIR)"; return 0; }
  for i in "${!files[@]}"; do
    printf "  %2d) %s ${D}(%s)${N}\n" "$((i+1))" "${files[$i]##*/}" "$(date -r "${files[$i]}" '+%d.%m %H:%M')"
  done
  echo "   0) Назад"
  read_choice c "${C}  Копия: ${N}" 0 "${#files[@]}" 0
  (( c == 0 )) && return 0
  mod_rollback "${files[$((c-1))]}"
}

kernel_headers_help() {
  local others
  others=$(installed_kernels | grep -vx "$(uname -r)" | tr '\n' ' ')
  if [[ -n "$others" ]]; then
    info "Установлены другие ядра: $others"
    info "Скорее всего ядро обновилось — перезагрузись и запусти установку снова"
  else
    info "Поставь вручную: apt-get install linux-headers-\$(uname -r)"
  fi
}

do_components_menu() {
  local c upd tupd t
  while true; do
    echo ""
    components_report
    upd=$(upstream_latest mod); tupd=$(upstream_latest tools)
    echo ""
    echo -e "  ${C}1)${N} Обновить модуль ${D}${upd:+до $upd}${N}"
    echo -e "  ${C}2)${N} Выбрать версию модуля из списка"
    echo -e "  ${C}3)${N} Обновить amneziawg-tools ${D}${tupd:+до $tupd}${N}"
    echo -e "  ${C}4)${N} Перезагрузить модуль ${D}— без ребута${N}"
    echo -e "  $([[ -n "$(kernel_gap)" ]] && echo "${Y}" || echo "${C}")5)${N} Пересобрать под все установленные ядра"
    echo -e "  ${C}6)${N} Откат модуля из резервной копии"
    echo -e "  ${C}7)${N} Проверить обновления сейчас"
    echo -e "  ${W}0)${N} ← Назад"
    echo ""
    read_choice c "${C}  Выбор [0-7]: ${N}" 0 7 0
    case "$c" in
      1) mod_update_flow || true ;;
      2) t=$(mod_pick_tag) && { mod_update_flow "$t" || true; } ;;
      3) tools_update_flow || true ;;
      4) mod_reload || true ;;
      5) mod_rebuild_all || true ;;
      6) mod_rollback_flow || true ;;
      7) if upstream_refresh; then ok "Модуль: $(upstream_latest mod), tools: $(upstream_latest tools)"
         else err "github.com недоступен"; fi ;;
      0) return 0 ;;
    esac
    pause
  done
}
