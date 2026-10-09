# Каскад портов: этот сервер принимает клиентов на порт и прозрачно
# пробрасывает трафик на другой сервер (AmneziaWG, VLESS, любой L4).
# Клиент видит IP этого сервера.
#
# Правила: /etc/awg-cascade/rules.conf, строка «proto|вход|цель|выход|комментарий».
# Все правила iptables помечены «awg-cascade:<proto>-<вход>» — сброс трогает
# только их. DNAT ловит только пакеты на адреса самого сервера: без этого
# правило «udp 443» перехватывало бы QUIC всех клиентов AWG к любым сайтам.

cascade_tag() { echo "${CASCADE_TAG}:$1-$2"; }

cascade_rules() {  # строки правил без комментариев и мусора
  [[ -f "$CASCADE_RULES" ]] || return 0
  grep -E '^(udp|tcp)\|[0-9]+\|[0-9.]+\|[0-9]+\|' "$CASCADE_RULES" || true
}

cascade_count() { cascade_rules | grep -c . || true; }

cascade_state_line() {
  local n
  n=$(cascade_count)
  if (( n )); then echo -e "${G}● правил: $n${N}"; else echo -e "${D}○ правил нет${N}"; fi
}

# ── Правила iptables (и для служебного скрипта) ───────────
cascade_log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$CASCADE_LOG" 2>/dev/null || true; }

cascade_unapply() {  # proto вход
  local t tag
  tag=$(cascade_tag "$1" "$2")
  for t in nat filter; do ipt_del_grep "$t" "--comment \"?${tag}\"?( |$)"; done
}

cascade_apply() {  # proto вход цель выход
  local p="$1" in="$2" dst="$3" out="$4" tag
  tag=$(cascade_tag "$p" "$in")
  cascade_unapply "$p" "$in"
  iptables -t nat -A PREROUTING -p "$p" --dport "$in" -m addrtype --dst-type LOCAL \
    -j DNAT --to-destination "$dst:$out" -m comment --comment "$tag" || return 1
  iptables -t nat -A POSTROUTING -p "$p" -d "$dst" --dport "$out" -j MASQUERADE -m comment --comment "$tag" || return 1
  # Туда и обратно: политика FORWARD бывает DROP (Docker, UFW) — правила
  # не должны зависеть от неё.
  iptables -I FORWARD 1 -p "$p" -d "$dst" --dport "$out" -j ACCEPT -m comment --comment "$tag" || return 1
  iptables -I FORWARD 1 -p "$p" -s "$dst" --sport "$out" -j ACCEPT -m comment --comment "$tag" || return 1
}

# Точка входа awg-cascade.service.
cascade_apply_all() {
  local p in dst out rest ok=0 bad=0
  [[ -f "$CASCADE_RULES" ]] || exit 0
  sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
  while IFS='|' read -r p in dst out rest; do
    [[ "$p" == udp || "$p" == tcp ]] && [[ -n "$in" && -n "$dst" && -n "$out" ]] || continue
    if cascade_apply "$p" "$in" "$dst" "$out"; then ok=$((ok + 1))
    else bad=$((bad + 1)); cascade_log "ERROR: $p $in -> $dst:$out не применилось"; fi
  done < "$CASCADE_RULES"
  cascade_log "применено: $ok, ошибок: $bad"
}

cascade_flush_rules() {
  local t
  for t in nat filter; do ipt_del_grep "$t" "--comment \"?${CASCADE_TAG}:"; done
}

_cascade_persist() {
  emit_script "$CASCADE_SCRIPT" 'cascade_apply_all' CASCADE_TAG CASCADE_RULES CASCADE_LOG \
    ipt_del_grep cascade_tag cascade_log cascade_unapply cascade_apply cascade_apply_all || return 1
  write_unit awg-cascade.service <<EOF
[Unit]
Description=AWG Toolza — каскад портов
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$CASCADE_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable awg-cascade.service &>/dev/null
}

# UFW-правила прежних версий: порт, route allow и политика FORWARD.
_cascade_ufw_legacy_cleanup() {
  command -v ufw &>/dev/null || return 0
  ufw_delete_matching "${CASCADE_TAG}:"
}

# ── Меню ──────────────────────────────────────────────────
_cascade_port_conflict() {  # proto порт → причина в stdout
  local p="$1" port="$2"
  grep -qE "^${p}\|${port}\|" "$CASCADE_RULES" 2>/dev/null && { echo "уже есть правило ${p^^} $port"; return 0; }
  if [[ "$p" == udp ]]; then
    [[ "$(conf_iface_get ListenPort 2>/dev/null)" == "$port" ]] && { echo "это порт AmneziaWG"; return 0; }
    wgobf_owns_port "$port" && { echo "порт занят WG + обфускатором"; return 0; }
  fi
  ss -Hln"${p:0:1}" "sport = :$port" 2>/dev/null | grep -q . && { echo "порт слушает локальный сервис — DNAT отнимет его"; return 0; }
  return 1
}

cascade_add() {
  local mode="$1" p protos in out dst comment
  echo -e "  ${D}Клиент подключается к этому серверу, трафик уходит на конечный.${N}"
  echo -e "  ${C}1)${N} UDP"
  echo -e "  ${C}2)${N} TCP"
  echo -e "  ${C}3)${N} UDP + TCP"
  read_choice p "${C}  Протокол [1-3] (Enter = 1): ${N}" 1 3 1
  case "$p" in 1) protos=udp ;; 2) protos=tcp ;; 3) protos=both ;; esac
  while true; do
    read_line dst "${C}  IP конечного сервера: ${N}"
    dst="${dst// /}"; [[ -z "$dst" ]] && return 0
    valid_ip "$dst" && ! ip_is_private "$dst" && break
    err "Нужен публичный IPv4, например 5.6.7.8"
  done
  while true; do
    read_line in "${C}  Порт на этом сервере: ${N}"
    valid_port "${in// /}" && { in="${in// /}"; break; }
    err "Порт 1-65535"
  done
  out="$in"
  if [[ "$mode" == custom ]]; then
    while true; do
      read_line out "${C}  Порт конечного сервера: ${N}"
      valid_port "${out// /}" && { out="${out// /}"; break; }
      err "Порт 1-65535"
    done
  fi
  read_line comment "${C}  Комментарий (Enter — без него): ${N}"
  cascade_rule_add "$protos" "$in" "$dst" "$out" "$comment"
}

# cascade_rule_add udp|tcp|both ВХОД ЦЕЛЬ ВЫХОД [комментарий]
# Порты и адрес цели правила; причина отказа — в stdout. Общая для
# добавления и для правил из бэкапа: те раньше проверялись только по формату
# и могли увести порт сервера во внутреннюю сеть.
_cascade_rule_invalid() {  # вход цель выход
  valid_port "$1" && valid_port "$3" || { echo "Порт 1-65535"; return 0; }
  valid_ip "$2" && ! ip_is_private "$2" || { echo "Нужен публичный IPv4, например 5.6.7.8"; return 0; }
  return 1
}

cascade_rule_add() {
  local protos=() proto in="$2" dst="$3" out="$4" comment="${5//[|$'\n\r']/ }" why added=0
  case "$1" in udp|tcp) protos=("$1") ;; both) protos=(udp tcp) ;; *) err "Протокол: udp | tcp | both"; return 1 ;; esac
  if why=$(_cascade_rule_invalid "$in" "$dst" "$out"); then err "$why"; return 1; fi
  ip_forward_enable
  mkdir -p "$CASCADE_DIR"
  for proto in "${protos[@]}"; do
    if why=$(_cascade_port_conflict "$proto" "$in"); then err "${proto^^} $in: $why"; continue; fi
    if cascade_apply "$proto" "$in" "$dst" "$out"; then
      echo "$proto|$in|$dst|$out|$comment" >> "$CASCADE_RULES"
      cascade_log "добавлено: $proto $in -> $dst:$out"
      ok "${proto^^} $in → $dst:$out"
      added=$((added + 1))
    else
      cascade_unapply "$proto" "$in"
      err "iptables не принял правило ${proto^^} $in"
    fi
  done
  (( added )) || return 1
  _cascade_persist
  info "На клиенте Endpoint: ${W}$(public_ip_cached):$in${N}"
}

cascade_list() {
  local rows=() i p in dst out cm mark
  mapfile -t rows < <(cascade_rules)
  (( ${#rows[@]} )) || { info "Правил нет"; return 1; }
  printf "  ${D}%-3s %-4s %-6s %-16s %-6s %s${N}\n" "#" "" "ВХОД" "ЦЕЛЬ" "ВЫХОД" "КОММЕНТАРИЙ"
  for i in "${!rows[@]}"; do
    IFS='|' read -r p in dst out cm <<< "${rows[$i]}"
    if iptables-save -t nat 2>/dev/null | grep -qE -- "$(cascade_tag "$p" "$in")\"?( |$)"; then mark="${G}●${N}"; else mark="${R}○${N}"; fi
    printf "  %-3s %b %-4s %-6s %-16s %-6s %s\n" "$((i + 1)))" "$mark" "${p^^}" "$in" "$dst" "$out" "${cm:-—}"
  done
  echo -e "  ${D}● применено, ○ записано, но в iptables нет (Переприменить правила)${N}"
}

cascade_delete() {
  local rows=() c p in
  cascade_list || return 0
  mapfile -t rows < <(cascade_rules)
  read_choice c "${C}  Номер для удаления (0 — отмена): ${N}" 0 "${#rows[@]}" 0
  (( c == 0 )) && return 0
  IFS='|' read -r p in _ <<< "${rows[$((c - 1))]}"
  cascade_rule_del "$p" "$in"
}

cascade_rule_del() {  # proto вход
  local p="$1" in="$2" dst out
  # Аргументы приходят и из API: без проверки «.» и «[0-9]+» стали бы регуляркой
  # и вычистили бы все правила из файла, оставив их в iptables.
  [[ "$p" =~ ^(udp|tcp)$ ]] && valid_port "$in" || { err "Правило: udp|tcp ПОРТ"; return 1; }
  IFS='|' read -r _ _ dst out _ < <(grep -E "^${p}\|${in}\|" "$CASCADE_RULES" 2>/dev/null)
  [[ -n "$dst" ]] || { err "Правила ${p^^} $in нет"; return 1; }
  cascade_unapply "$p" "$in"
  grep -vE "^${p}\|${in}\|" "$CASCADE_RULES" > "$CASCADE_RULES.tmp" || true
  mv -f "$CASCADE_RULES.tmp" "$CASCADE_RULES"
  cascade_log "удалено: $p $in -> $dst:$out"
  ok "Удалено: ${p^^} $in → $dst:$out"
}

cascade_reapply() {
  cascade_flush_rules
  (( $(cascade_count) )) || { info "Правил нет"; return 0; }
  _cascade_persist
  systemctl restart awg-cascade.service && ok "Правила переприменены" \
    || err "Не применилось: journalctl -u awg-cascade; лог $CASCADE_LOG"
}

cascade_flush() {
  (( $(cascade_count) )) || { info "Каскад пуст"; return 0; }
  read_confirm "${R}  Удалить все правила каскада? (введи yes): ${N}" || return 0
  cascade_clear
}

cascade_clear() {
  cascade_flush_rules
  _cascade_ufw_legacy_cleanup
  : > "$CASCADE_RULES"
  cascade_log "все правила удалены"
  ok "Все правила каскада удалены"
}

# $1 = quiet — без вопроса (из полного удаления).
cascade_uninstall() {
  if [[ "${1:-}" != quiet ]]; then
    read_confirm "${R}  Удалить каскад полностью (правила, служба)? (введи yes): ${N}" || return 0
  fi
  remove_unit awg-cascade.service
  rm -f "$CASCADE_SCRIPT"
  cascade_flush_rules
  _cascade_ufw_legacy_cleanup
  # Прежние версии меняли политику FORWARD в UFW. Если AWG-сервера нет,
  # вернуть её было бы некому — возвращаем здесь.
  if [[ -f "$CASCADE_UFW_BACKUP" ]] && ! server_exists; then
    cp -a "$CASCADE_UFW_BACKUP" /etc/default/ufw
    ufw_active && ufw reload &>/dev/null
  fi
  rm -rf "$CASCADE_DIR"
  [[ "${1:-}" == quiet ]] || ok "Каскад удалён"
}

cascade_diagnose() {
  local p in dst out seen=" "
  hdr "Диагностика каскада"
  echo "  Аплинк      : $(uplink_iface || echo '?')"
  echo "  IP сервера  : $(public_ip_cached)"
  echo "  ip_forward  : $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  echo "  Служба      : $(systemctl is-enabled awg-cascade.service 2>/dev/null || echo нет)"
  echo "  Правил      : $(cascade_count)"
  echo ""
  echo "── iptables ──"
  { iptables-save -t nat; iptables-save -t filter; } 2>/dev/null | grep -F "${CASCADE_TAG}:" | sed 's/^/  /' || echo "  (нет)"
  echo ""
  echo "── Доступность целей (TCP-порт или ping) ──"
  while IFS='|' read -r p in dst out _; do
    [[ "$seen" == *" $dst:$out "* ]] && continue
    seen+="$dst:$out "
    if [[ "$p" == tcp ]] && timeout 4 bash -c "exec 3<>/dev/tcp/$dst/$out" 2>/dev/null; then
      echo -e "  ${G}●${N} $dst:$out — TCP отвечает"
    elif ping -c1 -W2 "$dst" &>/dev/null; then
      echo -e "  ${G}●${N} $dst — ping есть ${D}(UDP-порт так не проверить)${N}"
    else
      echo -e "  ${Y}▲${N} $dst — не отвечает ${D}(ICMP может быть закрыт)${N}"
    fi
  done < <(cascade_rules)
  echo ""
  echo "── Журнал ($CASCADE_LOG) ──"
  tail -n 15 "$CASCADE_LOG" 2>/dev/null | sed 's/^/  /' || echo "  (пусто)"
}

cascade_export() {
  local f
  f="/root/cascade-debug-$(date +%Y%m%d-%H%M%S).txt"
  { cascade_diagnose; echo; echo "── ip route ──"; ip route; echo; iptables --version; } 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | write_file "$f" 600
  ok "Отчёт: $f"
}

do_cascade_menu() {
  local c
  while true; do
    echo ""
    hdr "Каскад портов"
    echo -e "  Правил: ${W}$(cascade_count)${N}   Служба: $(unit_enabled awg-cascade.service && echo -e "${G}● автозапуск${N}" || echo -e "${D}○ нет${N}")"
    echo ""
    echo -e "  ${C}1)${N} Добавить (один порт)"
    echo -e "  ${C}2)${N} Добавить (разные порты)"
    echo -e "  ${C}3)${N} Список"
    echo -e "  ${C}4)${N} Удалить правило"
    echo -e "  ${C}5)${N} Переприменить правила"
    echo -e "  ${C}6)${N} Диагностика"
    echo -e "  ${C}7)${N} Отчёт в файл"
    echo -e "  ${Y}8)${N} Удалить все правила"
    echo -e "  ${R}d)${N} Удалить каскад полностью"
    echo -e "  ${W}0)${N} ← Назад"
    read_choice c "${C}  Выбор: ${N}" 0 8 0 "d"
    case "$c" in
      1) cascade_add same || true ;;
      2) cascade_add custom || true ;;
      3) cascade_list || true ;;
      4) cascade_delete || true ;;
      5) cascade_reapply || true ;;
      6) cascade_diagnose ;;
      7) cascade_export ;;
      8) cascade_flush || true ;;
      d) cascade_uninstall || true ;;
      0) return 0 ;;
    esac
    pause
  done
}
