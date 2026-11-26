#!/usr/bin/env bash
# Маршрутизация туннелей на настоящем ядре: правила клиентов, «если туннель
# упал» (unreachable под маршрутом), метка и правило «РФ напрямую», «куда идёт
# адрес» — настоящими ip, ipset и iptables в отдельном сетевом пространстве.
# Запуск: unshare -rn bash tests/kernel_routing.sh dist/awg2.sh КАТАЛОГ tunnels|rudirect|rpf|exits|dns|blocks|wgobf6|wgobfcli
# (или через tests/test_kernel_routing.py — он сам пропустит, если netns нет).
# shellcheck disable=SC2034  # пути — для функций awg2, подключённых через eval
set -u
LIB="$1"; T="$2"; PART="${3:-tunnels}"
src=$(cat "$LIB"); src="${src%main \"\$@\"*}"
eval "$src"
STATE_DIR="$T/state"; mkdir -p "$STATE_DIR"
SERVER_CONF="$T/awg0.conf"; printf '[Interface]
Address = 10.23.45.1/24
ListenPort = 51820
' > "$SERVER_CONF"
WARP_PEERS="$T/warp.peers"; echo "10.23.45.2" > "$WARP_PEERS"
WARP_STATE="$T/warp.state"; touch "$WARP_STATE"; XRAY_STATE="$T/xray.state"; EXITS_STATE="$T/exits.state"; XRAY_PEERS="$T/xray.peers"
TUNFAIL_CONF="$T/tunnel-fail.conf"; TUNFAIL_LOG="$T/tunfail.log"; WGOBF_STATE="$T/wgobf"; VKBLOCK_CONF="$T/vk.conf"
RUDIRECT_DIR="$T/rud"; RUDIRECT_CONF="$RUDIRECT_DIR/rudirect.conf"; RUDIRECT_USER="$T/user"; RUDIRECT_LOG="$T/rud.log"
DIAG_FWD=/proc/sys/net/ipv4/ip_forward
ipt_add() { :; }; ipt_ins() { :; }; ipt_del() { :; }; ipt_del_grep() { :; }; ipt_del_tagged() { :; }
systemctl() { return 1; }
server_exists() { return 0; }; clients_tsv() { printf 'alice	pub	10.23.45.2/32			
bob	pub	10.23.45.3/32			
'; }
xray_ru_on() { return 1; }
pass=0 fail=0
ok() { if eval "$2"; then echo "  OK   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
rg() { ip -4 route get "$1" from "$2" iif awg0 ${3:+mark $3} 2>&1; }

ip link set lo up
if [[ "$PART" == rpf ]]; then
  # Настоящий трафик: клиент и «интернет» — свои сетевые пространства
  for c in nsenter python3; do command -v "$c" &>/dev/null || { echo "ПРОПУСК rpf: нет $c"; exit 0; }; done
  unshare -n sleep 600 & CLI=$!; unshare -n sleep 600 & NET=$!; sleep 0.3
  trap 'kill $CLI $NET 2>/dev/null' EXIT
  ip link add awg0 type veth peer name c0; ip link set c0 netns "$CLI"
  ip link add eth0 type veth peer name i0; ip link set i0 netns "$NET"
  ip addr add 10.23.45.1/24 dev awg0; ip link set awg0 up
  ip addr add 203.0.113.10/24 dev eth0; ip link set eth0 up
  nsenter -t "$CLI" -n sh -c 'ip link set lo up; ip addr add 10.23.45.2/24 dev c0; ip link set c0 up; ip route add default via 10.23.45.1'
  nsenter -t "$NET" -n sh -c 'ip link set lo up; ip addr add 203.0.113.1/24 dev i0; ip link set i0 up; ip addr add 77.1.1.1/32 dev lo'
  cat > "$T/srv.py" <<'PY'
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0", 443)); s.listen(8)
while True:
    c, _ = s.accept(); c.recv(4096); c.sendall(b"OK"); c.close()
PY
  cat > "$T/cl.py" <<'PY'
import socket, sys
try:
    c = socket.create_connection((sys.argv[1], 443), timeout=2); c.sendall(b"x" * 3000)
    sys.exit(0 if c.recv(10) == b"OK" else 1)
except OSError:
    sys.exit(1)
PY
  nsenter -t "$NET" -n python3 -I "$T/srv.py" & SRV=$!
  trap 'kill $CLI $NET $SRV 2>/dev/null' EXIT
  iptables -t nat -A POSTROUTING -s 10.23.45.0/24 -o eth0 -j MASQUERADE
  reach() { nsenter -t "$CLI" -n python3 -I "$T/cl.py" "$1"; }
elif [[ "$PART" == blocks ]]; then
  # Ограничения клиентов: порт 25 (почта) и «РФ мимо VPN». Клиенты за awg0 и
  # wgobf0, «интернет» — свой netns: 1.1.1.1 и российский 77.88.8.8, порты 25, 587, 443
  for c in nsenter python3 ipset; do command -v "$c" &>/dev/null || { echo "ПРОПУСК blocks: нет $c"; exit 0; }; done
  unshare -n sleep 600 & CA=$!; unshare -n sleep 600 & CW=$!; unshare -n sleep 600 & NET=$!; sleep 0.3
  trap 'kill $CA $CW $NET 2>/dev/null' EXIT
  ip link add awg0 type veth peer name c0; ip link set c0 netns "$CA"
  ip link add wgobf0 type veth peer name w0; ip link set w0 netns "$CW"
  ip link add eth0 type veth peer name i0; ip link set i0 netns "$NET"
  ip addr add 10.23.45.1/24 dev awg0; ip link set awg0 up
  ip addr add 10.66.66.1/24 dev wgobf0; ip link set wgobf0 up
  ip addr add 203.0.113.10/24 dev eth0; ip link set eth0 up
  nsenter -t "$CA" -n sh -c 'ip link set lo up; ip addr add 10.23.45.2/24 dev c0; ip link set c0 up; ip route add default via 10.23.45.1'
  nsenter -t "$CW" -n sh -c 'ip link set lo up; ip addr add 10.66.66.2/24 dev w0; ip link set w0 up; ip route add default via 10.66.66.1'
  nsenter -t "$NET" -n sh -c 'ip link set lo up; ip addr add 203.0.113.1/24 dev i0; ip link set i0 up
    ip addr add 1.1.1.1/32 dev lo; ip addr add 77.88.8.8/32 dev lo; ip route add 10.0.0.0/8 via 203.0.113.10'
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  # Как PostUp сервера: ACCEPT первым в FORWARD — правила в mangle и ip rule от него не зависят
  iptables -I FORWARD 1 -i awg0 -j ACCEPT; iptables -I FORWARD 1 -i wgobf0 -j ACCEPT
  cat > "$T/srv.py" <<'PY'
import socket, sys, threading
def serve(host, port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((host, port)); s.listen(16)
    while True:
        c, _ = s.accept(); c.sendall(b"HI"); c.close()
for spec in sys.argv[1:]:
    h, p = spec.rsplit(":", 1)
    threading.Thread(target=serve, args=(h, int(p)), daemon=True).start()
threading.Event().wait()
PY
  cat > "$T/conn.py" <<'PY'
import socket, sys, time
t = time.time()
try:
    c = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3); r = c.recv(2); c.close()
    print("OK" if r == b"HI" else "BAD", round(time.time() - t, 2))
except socket.timeout:
    print("TIMEOUT", round(time.time() - t, 2))
except OSError as e:
    print("ERR", round(time.time() - t, 2), e.strerror)
PY
  nsenter -t "$NET" -n python3 -I "$T/srv.py" 1.1.1.1:25 1.1.1.1:587 1.1.1.1:443 77.88.8.8:443 & S1=$!
  python3 -I "$T/srv.py" 10.23.45.1:25 & S2=$!            # почта самого сервера — её не трогаем
  trap 'kill $CA $CW $NET $S1 $S2 2>/dev/null' EXIT
  sleep 0.5
  cn() { nsenter -t "$1" -n python3 -I "$T/conn.py" "$2" "$3"; }
  sh_cn() { python3 -I "$T/conn.py" "$1" "$2"; }           # сам сервер
elif [[ "$PART" == dns ]]; then
  # Шифрованный DNS: клиенты за awg0 и за wgobf0 (WG + обфускатор), «интернет» — свой
  # netns: его DNS на 1.1.1.1 отвечает «LEAK», а dnscrypt сервера на 127.0.2.1 — «DNSCRYPT»
  for c in nsenter python3; do command -v "$c" &>/dev/null || { echo "ПРОПУСК dns: нет $c"; exit 0; }; done
  unshare -n sleep 600 & CA=$!; unshare -n sleep 600 & CW=$!; unshare -n sleep 600 & NET=$!; sleep 0.3
  trap 'kill $CA $CW $NET 2>/dev/null' EXIT
  ip link add awg0 type veth peer name c0; ip link set c0 netns "$CA"
  ip link add eth0 type veth peer name i0; ip link set i0 netns "$NET"
  ip addr add 10.23.45.1/24 dev awg0; ip link set awg0 up
  ip addr add 203.0.113.10/24 dev eth0; ip link set eth0 up; ip route add default via 203.0.113.1
  sysctl -qw net.ipv4.ip_forward=1
  nsenter -t "$CA" -n sh -c 'ip link set lo up; ip addr add 10.23.45.2/24 dev c0; ip link set c0 up; ip route add default via 10.23.45.1'
  nsenter -t "$NET" -n sh -c 'ip link set lo up; ip addr add 203.0.113.1/24 dev i0; ip link set i0 up; ip addr add 1.1.1.1/32 dev lo'
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  wgobf_link() {  # wgobf0 и его клиент — заново (обфускатор подняли после DNS)
    ip link del wgobf0 2>/dev/null
    ip link add wgobf0 type veth peer name w0; ip link set w0 netns "$CW"
    ip addr add 10.66.66.1/24 dev wgobf0; ip link set wgobf0 up
    nsenter -t "$CW" -n sh -c 'ip link set lo up; ip addr add 10.66.66.2/24 dev w0; ip link set w0 up; ip route add default via 10.66.66.1'
  }
  wgobf_link
  cat > "$T/dns.py" <<'PY'
import socket, sys, threading
host, tag = sys.argv[1], sys.argv[2].encode()
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind((host, 53))
if len(sys.argv) > 3:          # «интернет»: ещё и DoT на 853
    t = socket.socket(); t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); t.bind((host, 853)); t.listen(8)
    threading.Thread(target=lambda: [t.accept()[0].close() for _ in iter(int, 1)], daemon=True).start()
while True:
    q, a = u.recvfrom(512); u.sendto(tag + b":" + q, a)
PY
  cat > "$T/q.py" <<'PY'
import socket, sys
kind = sys.argv[1]
try:
    if kind == "dot":
        socket.create_connection(("1.1.1.1", 853), timeout=2).close(); print("DOT-OPEN")
    else:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(2); u.sendto(b"q", ("1.1.1.1", 53))
        d, a = u.recvfrom(512); print(d.decode().split(":")[0], a[0])
except OSError as e:
    print("NO", type(e).__name__)
PY
  nsenter -t "$NET" -n python3 -I "$T/dns.py" 1.1.1.1 LEAK dot & S1=$!
  python3 -I "$T/dns.py" 127.0.2.1 DNSCRYPT & S2=$!
  trap 'kill $CA $CW $NET $S1 $S2 2>/dev/null' EXIT
  sleep 0.5
  q() { nsenter -t "$1" -n python3 -I "$T/q.py" "$2"; }
  eval "$(sed -n '/^ipt_add() {/,/^}/p;/^ipt_ins() {/,/^}/p;/^ipt_del() {/,/^}/p;/^ipt_del_tagged() {/,/^}/p;/^ipt_del_grep() {/,/^}/p' "$LIB")"
  DNS_PROXY_ADDR=127.0.2.1 DNS_PROXY_PORT=53
else
  ip tuntap add mode tun dev awg0; ip addr add 10.23.45.1/24 dev awg0; ip link set awg0 up
  ip link add eth0 type veth peer name eth0p; ip addr add 203.0.113.10/24 dev eth0; ip link set eth0 up; ip link set eth0p up
fi
ip route add default via 203.0.113.1 dev eth0
echo 1 > /proc/sys/net/ipv4/ip_forward
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "$f" 2>/dev/null; done
mkwarp() { ip tuntap add mode tun dev warp0; ip addr add 172.16.0.2/32 dev warp0; ip link set warp0 up; }

if [[ "$PART" == tunnels ]]; then
echo "── напрямую (по умолчанию) ──"
mkwarp; rt_up warp0 200 "$WARP_PEERS"
ok "клиент WARP — в warp0" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev warp0"* ]]'
ok "клиент без туннеля — eth0" '[[ "$(rg 1.1.1.1 10.23.45.3)" == *"dev eth0"* ]]'
ok "rt_table_live видит живой маршрут" 'rt_table_live 200'
ok "_tunfail_rule_tables читает таблицу из ip rule show" '[[ "$(_tunfail_rule_tables)" == 200 ]]'
ok "ip rule show: «lookup 200» в конце строки (на этом держатся проверки)" 'grep -qE "lookup 200$" <<< "$(ip rule show)"'
ip link del warp0
ok "WARP упал (устройство пропало): маршрут ушёл сам — клиент идёт напрямую (eth0)" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev eth0"* ]]'
rt_down warp0 200
ok "rt_down в «напрямую» снимает правила" '! grep -q "lookup 200" <<< "$(ip rule show)"'

echo "── РФ напрямую: метка и правило 90 ──"
mkwarp; rt_up warp0 200 "$WARP_PEERS"
_rud_ip_rule_on || ip rule add fwmark "$RUDIRECT_MARK" lookup main priority "$RUDIRECT_PRIO"
ok "правило 90 найдено проверкой _rud_ip_rule_on" '_rud_ip_rule_on'
ok "помеченный пакет клиента WARP — мимо туннеля (eth0)" '[[ "$(rg 77.88.8.8 10.23.45.2 0x52550000)" == *"dev eth0"* ]]'
ok "метка с чужими младшими битами (wg-quick 0xca6c) — тоже мимо туннеля" '[[ "$(rg 77.88.8.8 10.23.45.2 0x5255ca6c)" == *"dev eth0"* ]]'
ok "без метки — в туннель" '[[ "$(rg 77.88.8.8 10.23.45.2)" == *"dev warp0"* ]]'
ok "чужая метка — в туннель" '[[ "$(rg 77.88.8.8 10.23.45.2 0x00010000)" == *"dev warp0"* ]]'

echo "── блокировать ──"
echo "warp=block" > "$TUNFAIL_CONF"
rt_fail_route 200
ok "«недоступно» лежит под живым маршрутом — трафик по-прежнему в warp0" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev warp0"* ]]'
ok "ip route show: «unreachable default metric 4096» (на этом держится tunfail_held)" 'grep -q "^unreachable default" <<< "$(ip route show table 200)"'
ip link del warp0
r=$(rg 1.1.1.1 10.23.45.2)
ok "WARP упал сам (устройство пропало, rt_down ещё не было) — клиент без маршрута: $r" '[[ "$r" == *"No route to host"* || "$r" == *"nreachable"* ]]'
ok "…а сеть России у него — напрямую" '[[ "$(rg 77.88.8.8 10.23.45.2 0x52550000)" == *"dev eth0"* ]]'
ok "клиент без туннеля не задет" '[[ "$(rg 1.1.1.1 10.23.45.3)" == *"dev eth0"* ]]'
rt_down warp0 200
ok "rt_down в «блокировать»: правило осталось, таблица — «недоступно»" 'grep -q "lookup 200" <<< "$(ip rule show)" && ! rt_table_live 200 && tunfail_held warp'
mkwarp; rt_up warp0 200 "$WARP_PEERS"
ok "WARP вернулся — клиент снова в warp0" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev warp0"* ]]'
ok "правило клиента одно (без дублей)" '(( $(ip rule show | grep -c "lookup 200") == 1 ))'
ip link del warp0; rt_down warp0 200
rm -f "$WARP_STATE"; rt_down warp0 200
ok "выключили руками (состояния нет) — отпущен напрямую" '! grep -q "lookup 200" <<< "$(ip rule show)" && [[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev eth0"* ]]'

echo "── сторож после перезагрузки ──"
touch "$WARP_STATE"; tunfail_guard_run >/dev/null
ok "WARP включён, не поднялся — сторож удержал клиента" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"No route"* ]]'
ip tuntap add mode tun dev tun0; ip addr add 198.18.0.1/30 dev tun0; ip link set tun0 up
rt_up tun0 100 -
ok "поднят tun2socks — удержание WARP снято, клиент в tun0" '! grep -q "lookup 200" <<< "$(ip rule show)" && [[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev tun0"* ]]'
tunfail_guard_run >/dev/null
ok "сторож при живом tun2socks WARP не держит" '! grep -q "lookup 200" <<< "$(ip rule show)"'
elif [[ "$PART" == rudirect ]]; then
mkwarp; rt_up warp0 200 "$WARP_PEERS"
mkdir -p "$RUDIRECT_DIR" "$RUDIRECT_USER"
for b in $(seq 0 255); do for c in 0 64 128 192; do echo "77.$b.$c.0/18"; done; done > "$RUDIRECT_DIR/ru.list"
echo "77.88.8.0/24" > "$RUDIRECT_USER/tunnel.list"; echo "5.255.255.5" > "$RUDIRECT_USER/direct.list"
_rud_set ON 1
echo "── РФ напрямую на настоящих ipset, iptables и ip rule ──"
rudirect_run apply; rc=$?; ok "apply: код 0" '(( rc == 0 ))'
ok "набор: сеть России, свой адрес, исключение nomatch" 'ipset test awg2-ru 77.1.1.1 2>/dev/null && ipset test awg2-ru 5.255.255.5 2>/dev/null && ! ipset test awg2-ru 77.88.8.8 2>/dev/null'
ok "правила: метка для awg0 и wgobf0, правило 90" 'rudirect_rules_ok && (( $(iptables-save -t mangle | grep -c awg2-rudirect) == 2 ))'
_rud_rule "$WGOBF_IF"; iptables -t mangle -D PREROUTING "${RUDIRECT_RULE[@]}"
ok "без метки wgobf0 состояние неисправно" '! rudirect_rules_ok'
rudirect_run heal >/dev/null
ok "таймер возвращает обе метки" 'rudirect_rules_ok && (( $(iptables-save -t mangle | grep -c awg2-rudirect) == 2 ))'
ok "сводка: $(rudirect_summary)" '[[ "$(rudirect_summary)" == "сетей РФ 1024, своих напрямую 1, через туннель 1" ]]'
rudirect_run apply >/dev/null
ok "повтор apply — без дублей правил" '(( $(iptables-save -t mangle | grep -c awg2-rudirect) == 2 && $(ip rule show | grep -c "fwmark 0x52550000") == 1 ))'
ok "счётчики читаются: $(rudirect_counters)" '[[ "$(rudirect_counters)" =~ ^[0-9]+\ [0-9]+$ ]]'
# Много клиентов в туннелях — длинный «ip rule show»: при pipefail «… | grep -q»
# ловил SIGPIPE и правило «пропадало»
for i in $(seq 1 250); do ip rule add from "10.99.$((i / 200)).$((i % 200 + 1))" lookup 300 priority 300; done
f=0; for i in $(seq 1 40); do rudirect_rules_ok || f=$((f + 1)); done
ok "250 правил клиентов, pipefail — правила на месте 40 раз из 40 (ложных: $f)" '(( f == 0 ))'
f=0; for i in $(seq 1 40); do tunfail_held warp && f=$((f + 1)); done
ok "…и удержание WARP не мерещится" '(( f == 0 ))'
while ip rule del lookup 300 2>/dev/null; do :; done
echo "── Куда идёт адрес (ядро) ──"
rudirect_on() { [[ "$(_rud_get ON)" == 1 ]]; }
out=$(diag_route alice 77.1.1.1); ok "сеть России — rudirect: $out" '[[ "$out" == *$'"'"'\trudirect\teth0\t'"'"'* ]]'
_rud_set TG 1; rudirect_run apply >/dev/null
out=$(diag_route alice 149.154.167.51)
ok "Telegram напрямую: подсети Telegram в наборе, адрес Telegram — rudirect «Telegram напрямую»: $out" \
  'ipset test awg2-ru 149.154.167.51 2>/dev/null && [[ "$out" == *$'"'"'\trudirect\teth0\t'"'"'*"Telegram напрямую"* ]]'
_rud_set TG 0; rudirect_run apply >/dev/null
out=$(diag_route alice 149.154.167.51); ok "…выключили — Telegram снова через WARP" '[[ "$out" == *$'"'"'\twarp\twarp0\t'"'"'* ]]'
out=$(diag_route alice 77.88.8.8); ok "исключение — через WARP: $out" '[[ "$out" == *$'"'"'\twarp\twarp0\t'"'"'* ]]'
out=$(diag_route alice 1.1.1.1); ok "прочее — через WARP" '[[ "$out" == *$'"'"'\twarp\t'"'"'* ]]'
out=$(diag_route bob 1.1.1.1); ok "клиент без туннеля — direct: $out" '[[ "$out" == *$'"'"'\tdirect\teth0\t'"'"'* ]]'
echo "warp=block" > "$TUNFAIL_CONF"; rt_fail_route 200; ip link del warp0; rt_down warp0 200
out=$(diag_route alice 1.1.1.1); ok "WARP упал, «блокировать» — held: $out" '[[ "$out" == *$'"'"'\theld\t'"'"'* ]]'
out=$(diag_route alice 77.1.1.1); ok "…сеть России у удержанного — rudirect" '[[ "$out" == *$'"'"'\trudirect\t'"'"'* ]]'
echo 0 > /proc/sys/net/ipv4/ip_forward
out=$(diag_route alice 1.1.1.1); ok "пересылка выключена — none с подсказкой: $out" '[[ "$out" == *$'"'"'\tnone\t'"'"'*ip_forward* ]]'
echo 1 > /proc/sys/net/ipv4/ip_forward
_rud_set ON 0; rudirect_run off
ok "off: правила и набор сняты" '! ipset list -n awg2-ru &>/dev/null && ! grep -q awg2-rudirect <<< "$(iptables-save -t mangle)" && ! grep -q fwmark <<< "$(ip rule show)"'
elif [[ "$PART" == rpf ]]; then
echo "── РФ напрямую: настоящий трафик и строгий rp_filter на аплинке ──"
mkwarp; rt_up warp0 200 "$WARP_PEERS"
mkdir -p "$RUDIRECT_DIR" "$RUDIRECT_USER"
for b in $(seq 0 255); do for c in 0 64 128 192; do echo "77.$b.$c.0/18"; done; done > "$RUDIRECT_DIR/ru.list"
rpf() { cat "/proc/sys/net/ipv4/conf/$1/rp_filter"; }
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter; echo 1 > /proc/sys/net/ipv4/conf/eth0/rp_filter
ok "без «РФ напрямую» сеть России — в WARP (выхода у него нет): ответа нет" '! reach 77.1.1.1'
_rud_set ON 1; rudirect_run apply; rc=$?
ok "apply: код 0, rp_filter на eth0 строгий → мягкий" '(( rc == 0 )) && [[ "$(rpf eth0)" == 2 ]] && grep -q "rp_filter на eth0: строгий → мягкий" "$RUDIRECT_LOG"'
ok "клиент в WARP получил ответ из сети России напрямую" 'reach 77.1.1.1'
echo 1 > /proc/sys/net/ipv4/conf/eth0/rp_filter
ok "rp_filter снова строгий — ответа нет (то, что ломало сайты РФ)" '! reach 77.1.1.1'
ok "…правила не на месте" '! rudirect_rules_ok'
out=$(diag_route alice 77.1.1.1); ok "куда идёт: подсказка про rp_filter: $out" '[[ "$out" == *$'"'"'\tnone\teth0\t'"'"'*rp_filter* ]]'
rudirect_run heal
ok "таймер вернул мягкий — ответ есть" '[[ "$(rpf eth0)" == 2 ]] && rudirect_rules_ok && reach 77.1.1.1'
out=$(diag_route alice 77.1.1.1); ok "куда идёт: снова rudirect" '[[ "$out" == *$'"'"'\trudirect\teth0\t'"'"'* ]]'
echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter; echo 0 > /proc/sys/net/ipv4/conf/eth0/rp_filter
ok "all=1, eth0=0 — тоже строгий" '! rudirect_rules_ok && ! reach 77.1.1.1'
rudirect_run heal
ok "…починен (eth0=2 сильнее all=1) — ответ есть" '[[ "$(rpf eth0)" == 2 ]] && rudirect_rules_ok && reach 77.1.1.1'
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter; echo 1 > /proc/sys/net/ipv4/conf/eth0/rp_filter
out=$(diag_route bob 77.1.1.1); ok "клиент без туннеля при строгом — rudirect без подсказки (обратный путь и так eth0)" '[[ "$out" == *$'"'"'\trudirect\teth0\t'"'"'* ]]'
elif [[ "$PART" == blocks ]]; then
echo "── Почта: порт 25 клиентов закрыт ──"
SMTPBLOCK_FLAG="$T/smtpblock"
ok "до включения порт 25 у клиентов открыт" '[[ "$(cn "$CA" 1.1.1.1 25)" == OK* && "$(cn "$CW" 1.1.1.1 25)" == OK* ]]'
touch "$SMTPBLOCK_FLAG"; smtpblock_run apply
ok "закрыт: клиент AWG и клиент обфускатора не открывают порт 25" \
  '[[ "$(cn "$CA" 1.1.1.1 25)" != OK* && "$(cn "$CW" 1.1.1.1 25)" != OK* ]]'
ok "587 и 443 (почтовые приложения, сайты) работают" '[[ "$(cn "$CA" 1.1.1.1 587)" == OK* && "$(cn "$CW" 1.1.1.1 443)" == OK* ]]'
ok "почта самого сервера (его адрес) клиенту доступна" '[[ "$(cn "$CA" 10.23.45.1 25)" == OK* ]]'
ok "свой трафик сервера на 25 не трогается" '[[ "$(sh_cn 1.1.1.1 25)" == OK* ]]'
ok "правила на месте (smtpblock_rules_ok), повтор apply — без дублей" \
  'smtpblock_rules_ok && smtpblock_run apply && [[ "$(iptables -t mangle -S PREROUTING | grep -c awg2-smtpblock)" == 2 ]]'
iptables -t mangle -D PREROUTING -i wgobf0 -p tcp --dport 25 -m addrtype ! --dst-type LOCAL -m comment --comment awg2-smtpblock -j DROP
ok "правило сбросили — heal видит и возвращает" '! smtpblock_rules_ok && smtpblock_run heal && smtpblock_rules_ok && [[ "$(cn "$CW" 1.1.1.1 25)" != OK* ]]'
rm -f "$SMTPBLOCK_FLAG"; smtpblock_run heal
ok "выключили — правила сняты, порт 25 снова открыт" \
  '! grep -q awg2-smtpblock <<< "$(iptables-save -t mangle)" && [[ "$(cn "$CA" 1.1.1.1 25)" == OK* ]]'

echo "── РФ мимо VPN: клиентам отказ в сетях России ──"
RUBLOCK_DIR="$T/rublock"; RUBLOCK_CONF="$RUBLOCK_DIR/rublock.conf"; RUBLOCK_LOG="$T/rublock.log"
mkdir -p "$RUBLOCK_DIR"; printf '77.88.0.0/18\n5.255.255.0/24\n' > "$RUBLOCK_DIR/ru.list"
ok "до включения сеть России у клиента открыта" '[[ "$(cn "$CA" 77.88.8.8 443)" == OK* ]]'
_rublock_set ON 1; _rublock_apply
r=$(cn "$CA" 77.88.8.8 443)
ok "клиент AWG: сеть России — сразу отказ, а не ожидание: $r" '[[ "$r" == ERR* ]] && (( $(cut -d" " -f2 <<< "$r" | tr -d .) < 100 ))'
ok "клиент обфускатора: тоже отказ" '[[ "$(cn "$CW" 77.88.8.8 443)" == ERR* ]]'
ok "не Россия (1.1.1.1) — как обычно" '[[ "$(cn "$CA" 1.1.1.1 443)" == OK* && "$(cn "$CW" 1.1.1.1 443)" == OK* ]]'
ok "свой трафик сервера в сеть России не трогается" '[[ "$(sh_cn 77.88.8.8 443)" == OK* ]]'
# Клиент в туннеле (WARP: правило 200 и маршрут в warp0) — отказ раньше туннеля
ip tuntap add mode tun dev warp0; ip addr add 172.16.0.2/32 dev warp0; ip link set warp0 up
ip route add default dev warp0 table 200; ip rule add from 10.23.45.2 lookup 200 priority 200
ok "клиент в туннеле (WARP) — тоже сразу отказ: правило раньше туннелей, а 1.1.1.1 уходит в туннель" \
  '[[ "$(cn "$CA" 77.88.8.8 443)" == ERR* && "$(ip -4 route get 1.1.1.1 from 10.23.45.2 iif awg0 2>&1)" == *"dev warp0"* ]]'
ip rule del from 10.23.45.2 lookup 200 priority 200; ip link del warp0
ok "правила на месте (rublock_rules_ok), повтор apply — без дублей" \
  'rublock_rules_ok && _rublock_apply && [[ "$(grep -c "fwmark 0x52420000/0xffff0000 prohibit" <<< "$(ip rule show)")" == 1 ]]'
ip rule del fwmark 0x52420000/0xffff0000 prohibit priority 85
# Отказ — ICMP, а их частоту ядро ограничивает (на клиента ~1 в секунду после запаса):
# здесь важно «не открылось», мгновенность проверена на первом соединении
ok "правило маршрутизации пропало — rublock_rules_ok видит, heal возвращает" \
  '! rublock_rules_ok && rublock_run heal && rublock_rules_ok && [[ "$(cn "$CA" 77.88.8.8 443)" != OK* ]]'
_rublock_set ON 0; rublock_run heal
ok "выключили — правила и набор сняты, сеть России снова открыта" \
  '! ipset list -n awg2-rublock &>/dev/null && ! grep -q 0x52420000 <<< "$(ip rule show)" && [[ "$(cn "$CA" 77.88.8.8 443)" == OK* ]]'
elif [[ "$PART" == dns ]]; then
echo "── Шифрованный DNS: перехват с awg0 и wgobf0 на настоящем трафике ──"
ok "без перехвата DNS клиента обфускатора уходит в интернет открыто, DoT открыт" \
  '[[ "$(q "$CW" dns)" == "LEAK 1.1.1.1" && "$(q "$CW" dot)" == DOT-OPEN ]]'
dns_rules_down; dns_rules_up
ok "клиент AWG: запрос на 1.1.1.1 ответил dnscrypt сервера, адрес ответа — 1.1.1.1" '[[ "$(q "$CA" dns)" == "DNSCRYPT 1.1.1.1" ]]'
ok "клиент WG + обфускатора: то же — DNS не уходит открыто" '[[ "$(q "$CW" dns)" == "DNSCRYPT 1.1.1.1" ]]'
ok "DoT (853) закрыт у обоих" '[[ "$(q "$CA" dot)" == NO* && "$(q "$CW" dot)" == NO* ]]'
ok "правила перехвата на месте (dns_rules_ok)" 'dns_rules_ok'
# Старая версия: перехват был только на awg0 — сторож увидит дыру и доставит правила
iptables -t nat -D PREROUTING -i wgobf0 -p udp --dport 53 -j DNAT --to-destination 127.0.2.1:53 -m comment --comment awg2-dns
ok "правила wgobf0 нет (обновление со старой версии) — dns_rules_ok это видит" '! dns_rules_ok'
dns_rules_up
ok "dns_rules_up доставил его — снова dnscrypt, без дублей" \
  '[[ "$(q "$CW" dns)" == "DNSCRYPT 1.1.1.1" && "$(iptables -t nat -S PREROUTING | grep -c "wgobf0.*dport 53")" == 2 ]]'
# Обфускатор подняли уже после DNS: правила на wgobf0 стоят без интерфейса
ip link del wgobf0; dns_rules_down; dns_rules_up; wgobf_link
ok "wgobf0 появился после включения DNS — перехват сразу работает" '[[ "$(q "$CW" dns)" == "DNSCRYPT 1.1.1.1" && "$(q "$CW" dot)" == NO* ]]'
dns_rules_down
ok "выключили DNS — правила сняты, клиенты снова ходят к своему DNS" \
  '! grep -q awg2-dns <<< "$(iptables-save)" && [[ "$(q "$CW" dns)" == "LEAK 1.1.1.1" && "$(q "$CW" dot)" == DOT-OPEN ]]'
elif [[ "$PART" == wgobf6 ]]; then
echo "── WG + обфускатор: правила IPv6 в туннеле — настоящие iptables и ip6tables ──"
ip6tables -t nat -S POSTROUTING &>/dev/null || { echo "ПРОПУСК wgobf6: нет ip6tables с таблицей nat"; exit 0; }
eval "$(sed -n '/^ipt_del_tagged() {/,/^}/p;/^ipt_del_grep() {/,/^}/p;/^ip6t_del_tagged() {/,/^}/p' "$LIB")"
ip link add wgobf0 type veth peer name w0; ip link set wgobf0 up
printf 'NET=10.66.66.0/24\nWG_PORT=51900\nIPV6=1\nNET6=fd12:3456:789a:1::/64\n' > "$WGOBF_STATE"
WARP_PEERS="$T/warp.peers"; echo 10.66.66.3 > "$WARP_PEERS.wgobf"
EXITS_PEERS="$T/exits.peers"; echo "10.66.66.200|n1" > "$EXITS_PEERS.wgobf"
# IPv6 в ядре песочницы может быть выключен: sysctl — без него, сами правила проверяются
sysctl() { echo "sysctl $*" >> "$T/sysctl.log"; [[ "$1" == -n ]] && echo 1; return 0; }
ip() { if [[ "$1 $2" == "-6 route" ]]; then echo "default via fe80::1 dev eth0 proto ra"; return 0; fi; command ip "$@"; }
err=$(wgobf_fw_run up 2>&1); rc=$?
s6=$(ip6tables-save)
ok "wgobf_fw_run up: без ошибок ($err)" '(( rc == 0 )) && [[ -z "$err" ]]'
ok "NAT66 сети клиентов, вход из wgobf0, ответы по conntrack" \
  'grep -q -- "-A POSTROUTING -s fd12:3456:789a:1::/64 ! -o wgobf0 -m comment --comment awg-wgobf -j MASQUERADE" <<< "$s6" \
   && grep -q -- "-A FORWARD -i wgobf0 -m comment --comment awg-wgobf -j ACCEPT" <<< "$s6" \
   && grep -qE -- "-A FORWARD -o wgobf0 -m conntrack --ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED) -m comment --comment awg-wgobf -j ACCEPT" <<< "$s6"'
ok "DNS и DoT по IPv6 — отказ раньше ACCEPT; клиенты в туннелях (WARP .3 → ::3, нода .200 → ::c8) — отказ ещё раньше" \
  '[[ "$(ip6tables -S FORWARD | grep -c -- "-i wgobf0 -p .* --dport \(53\|853\) .*-j REJECT")" == 4 ]] \
   && ip6tables -S FORWARD | sed -n 2,3p | grep -q "icmp6-adm-prohibited" \
   && ip6tables -S FORWARD | grep -q -- "-s fd12:3456:789a:1::3/128 -i wgobf0 .*awg-wgobf-v6r -j REJECT --reject-with icmp6-adm-prohibited" \
   && ip6tables -S FORWARD | grep -q -- "-s fd12:3456:789a:1::c8/128 " \
   && [[ "$(ip6tables -S FORWARD | sed -n 2p)" == *"awg-wgobf-v6r"* ]]'
ok "порт WireGuard закрыт снаружи и по IPv6, accept_ra=2 до пересылки IPv6" \
  'ip6tables -S INPUT | grep -q -- "-p udp -m udp --dport 51900 .*-j DROP" \
   && grep -n "accept_ra=2\|forwarding=1" "$T/sysctl.log" | head -1 | grep -q accept_ra'
wgobf_fw_run up 2>/dev/null
ok "повторный up — без дублей" '[[ "$(ip6tables-save | grep -c awg-wgobf)" == "$(grep -c awg-wgobf <<< "$s6")" ]]'
rm -f "$WARP_PEERS.wgobf"; wgobf_fw6_routes
ok "клиент ушёл из туннеля — его отказ снят, остальное на месте" \
  '! ip6tables -S FORWARD | grep -q "fd12:3456:789a:1::3/128" && ip6tables -S FORWARD | grep -q "::c8/128" \
   && ip6tables -t nat -S POSTROUTING | grep -q awg-wgobf'
wgobf_fw_run down
ok "down — ни одного правила обфускатора ни в iptables, ни в ip6tables" \
  '! grep -q awg-wgobf <<< "$(iptables-save; ip6tables-save)"'
sed -i '/^IPV6=/d' "$WGOBF_STATE"; wgobf_fw_run up 2>/dev/null
ok "IPv6 в туннеле выключен — в ip6tables только закрытый порт WireGuard" \
  '[[ "$(ip6tables-save | grep -c awg-wgobf)" == 1 ]] && [[ "$(iptables-save | grep -c awg-wgobf)" == 4 ]]'
elif [[ "$PART" == wgobfcli ]]; then
echo "── Клиент обфускатора на Linux: ответы на входящие (SSH) — мимо туннеля, настоящие ip rule ──"
_wgobf_keep_script > "$T/keep.sh"
# Аплинк — общий eth0 (203.0.113.10/24, шлюз .1). Туннель «весь интернет, кроме сервера» — маршрутами в main, как у wg-quick
ip link add wgc type veth peer name wgc1; ip link set wgc up; ip link set wgc1 up; ip addr add 10.70.1.2/32 dev wgc
ip route add 0.0.0.0/1 dev wgc; ip route add 128.0.0.0/1 dev wgc
ok "без службы ответ SSH с адреса аплинка ушёл бы в туннель (сессия рвётся)" \
  '[[ "$(ip -4 route get 198.51.100.7 from 203.0.113.10)" == *"dev wgc"* ]]'
bash "$T/keep.sh" up
ok "ответ с адреса аплинка — прежним шлюзом, соседям по сети — напрямую" \
  '[[ "$(ip -4 route get 198.51.100.7 from 203.0.113.10)" == *"via 203.0.113.1 dev eth0"* ]] \
   && r=$(ip -4 route get 203.0.113.50 from 203.0.113.10) && [[ "$r" == *"dev eth0"* && "$r" != *via* ]]'
ok "исходящие (адрес не выбран) — по-прежнему в туннель" '[[ "$(ip -4 route get 198.51.100.7)" == *"dev wgc"* ]]'
bash "$T/keep.sh" up
ok "повторный up — правило одно" '[[ "$(ip -4 rule show | grep -c "lookup 51819")" == 1 ]]'
bash "$T/keep.sh" down
ok "down — ни правил, ни таблицы; ответ снова как без службы" \
  '! ip -4 rule show | grep -q 51819 && [[ -z "$(ip -4 route show table 51819 2>/dev/null)" ]] \
   && [[ "$(ip -4 route get 198.51.100.7 from 203.0.113.10)" == *"dev wgc"* ]]'
elif [[ "$PART" == exits ]]; then
echo "── Сторож exit-нод: ноды — настоящие сетевые пространства, проба — настоящий ping ──"
command -v ping &>/dev/null || { echo "ПРОПУСК exits: нет ping"; exit 0; }
EXITS_DIR="$T/exits"; mkdir -p "$EXITS_DIR"; EXITS_PEERS="$EXITS_DIR/exits_peers.list"
EXITS_HEALTH_DIR="$T/health"; EXITS_LOCK="$T/exits.lock"; EXITS_HEALTH_LOG="$T/health.log"
# Проба — через «интернет» ноды (одна цель): живая нода отвечает на ping, без
# интернета — отказ сразу, молчащая — ping ждёт таймаута; HTTP-проба — отказ сразу
EXITS_HC_TARGETS="1.1.1.1"; EXITS_HC_URL="http://1.1.1.1:9/"
awg() { :; }                                   # рукопожатий нет — «не отвечает»
NS=()
for n in a b; do
  unshare -n sleep 600 & NS+=($!); sleep 0.2
  : > "$EXITS_DIR/awg-exit-$n.conf"
done
trap 'kill "${NS[@]}" 2>/dev/null' EXIT
# «Интернет» ноды — адреса 1.1.1.1 и 8.8.8.8 на её стороне; сбой — правилами на входе
node_fw() {  # нода правила...
  local p="${NS[$([[ $1 == a ]] && echo 0 || echo 1)]}"
  shift
  nsenter -t "$p" -n sh -c "ip addr add 1.1.1.1/32 dev n0 2>/dev/null; ip addr add 8.8.8.8/32 dev n0 2>/dev/null
    iptables -F INPUT; $*"
}
node_on() { node_fw "$1" true; }                           # проба проходит
node_off() { node_fw "$1" iptables -A INPUT -i n0 -j REJECT; }  # без интернета: отказ — проба падает сразу
node_silent() {  # молчит: ping ждёт таймаута, как с настоящей мёртвой нодой; HTTP — отказ сразу
  node_fw "$1" "iptables -A INPUT -i n0 -p icmp -j DROP; iptables -A INPUT -i n0 -p tcp -j REJECT --reject-with tcp-reset"
}
mknode() {  # нода → veth awg-exit-<нода> ↔ n0 в её пространстве
  local i=$([[ $1 == a ]] && echo 1 || echo 2) p="${NS[$([[ $1 == a ]] && echo 0 || echo 1)]}"
  ip link add "awg-exit-$1" type veth peer name n0 netns "$p"
  ip addr add "10.200.$i.1/30" dev "awg-exit-$1"; ip link set "awg-exit-$1" up
  # Без лимита ICMP-ошибок: иначе отказ на частые пробы ядро глушит и ping ждёт таймаута
  nsenter -t "$p" -n sh -c "ip link set lo up; ip addr add 10.200.$i.2/30 dev n0; ip link set n0 up
    sysctl -qw net.ipv4.icmp_ratelimit=0"
  node_on "$1"
}
mknode a; mknode b
printf 'active\nmode=peers\nbalancer=single\nsingle_exit=a\norder=b\n' > "$EXITS_STATE"
printf '10.23.45.2\n10.23.45.3|b\n' > "$EXITS_PEERS"
echo "exits=block" > "$TUNFAIL_CONF"
hc() { local i; for i in $(seq 1 "$1"); do exits_routing_run health; done; }
exits_routing_run start
ok "старт: общий выход — основная a, персональная нода клиента — b" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-a"* && "$(rg 1.1.1.1 10.23.45.3)" == *"dev awg-exit-b"* ]]'
hc 1
ok "проба через ноду настоящим ping: обе живы — ничего не меняется, «up» у обеих" \
  '[[ "$(exits_shared_now)" == a && "$(_exits_hstate a)" == "up 0 1 "* && "$(_exits_hstate b)" == "up 0 1 "* ]]'
node_silent a; hc 1                            # молчит совсем: проба ждёт таймаутов
node_off a; hc 1
ok "a молчит 2 проверки — ещё основная (упала — после 3)" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-a"* ]]'
hc 1
ok "a молчит 3 проверки — общий выход переключён на запасную b, правило клиента прежнее" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-b"* && "$(ip rule show | grep -c "from 10.23.45.2 lookup 202")" == 1 ]]'
ok "журнал: нода a не отвечает, общий выход a → b" 'grep -q "нода a: не отвечает" "$EXITS_HEALTH_LOG" && grep -q "общий выход: a → b" "$EXITS_HEALTH_LOG"'
node_off b
orig_online=$(declare -f _exits_server_online)
_exits_server_online() { return 0; }          # у сервера интернет есть: молчат именно ноды
hc 3
ok "обе молчат, «блокировать» — клиенты удержаны: «недоступно», правила на месте" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"No route"* && "$(rg 1.1.1.1 10.23.45.3)" == *"No route"* ]] && grep -q "from 10.23.45.3 lookup 211" <<< "$(ip rule show)"'
node_on a; hc 1
ok "a ответила 1 раз — ещё не вернулась (нужно 2)" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"No route"* ]]'
hc 1
ok "a вернулась — общий выход снова через неё; клиент лежащей b — через общий выход" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-a"* && "$(rg 1.1.1.1 10.23.45.3)" == *"dev awg-exit-a"* ]]'
node_on b; hc 2
ok "b вернулась — её клиент снова через b" '[[ "$(rg 1.1.1.1 10.23.45.3)" == *"dev awg-exit-b"* ]]'
printf 'active\nmode=peers\nbalancer=single\nsingle_exit=b\norder=a\n' > "$EXITS_STATE"
exits_routing_run refresh
ok "порядок поменяли (основная b) — общий выход на ходу через b" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-b"* ]]'
ip link del awg-exit-b; hc 1
ok "интерфейс b пропал — сразу, без трёх проверок: общий выход на a" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-a"* && "$(_exits_hstate b)" == "down "*" link" ]]'
mknode b; hc 2
ok "b снова поднята и отвечает — основная b снова общий выход" '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-b"* ]]'
printf 'active\nmode=peers\nbalancer=ecmp\nsingle_exit=a\norder=b\n' > "$EXITS_STATE"
exits_routing_run start
ok "ECMP: обе живы — общий выход по обеим" '[[ "$(ip route show table 202)" == *"nexthop dev awg-exit-a"*"nexthop dev awg-exit-b"* ]]'
node_off a; hc 3
ok "ECMP: a упала — выпала, общий выход только через b" \
  '[[ "$(ip route show table 202 | grep default | grep -v unreachable)" == "default dev awg-exit-b"* && "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-b"* ]]'
node_on a; hc 2
echo "exits=direct" > "$TUNFAIL_CONF"
node_off a; node_off b; hc 3
ok "обе молчат, «напрямую» — правила сняты, клиенты идут с адреса сервера" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev eth0"* ]] && ! grep -q "lookup 202" <<< "$(ip rule show)"'
node_on a; hc 2
ok "a вернулась после «напрямую» — правила клиентов снова на месте, общий выход через a" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-a"* ]] && grep -q "from 10.23.45.2 lookup 202" <<< "$(ip rule show)"'
eval "$orig_online"                           # настоящая проверка: у сервера в тесте интернета нет
iptables -I OUTPUT -o eth0 -j REJECT          # и не ждём таймаутов — отказ сразу
node_off a; node_off b
hc 3
ok "все молчат, у сервера нет интернета — ноды не трогаем" \
  '[[ "$(rg 1.1.1.1 10.23.45.2)" == *"dev awg-exit-a"* ]] && grep -q "у сервера нет выхода в интернет" "$EXITS_HEALTH_LOG"'
fi
echo "проверок: $((pass+fail)), провалов: $fail"
(( fail == 0 ))
