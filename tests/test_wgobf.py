#!/usr/bin/env python3
"""
test_wgobf.py — WG + обфускатор: профили обфускации (ClusterM и форк Phobos),
полная секция [instance], max-dummy/idle-timeout, IPv6 в туннеле, комплекты
клиентов и установщик.

Программы обфускаторов не запускаются: ключи конфигов сверяются со списками
опций, которые понимают ClusterM v1.6 и форк из Phobos (config.c обоих).

Запуск:  python3 tests/test_wgobf.py [путь/к/awg2.sh]
"""
import base64
import json
import os
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sandbox import *  # noqa: E402,F401,F403

# Опции конфига (config.c): неизвестный ключ — оба завершаются с ошибкой
CLUSTERM = {"source-if", "source", "source-lport", "target-if", "target", "target-lport", "key", "masking",
            "static-bindings", "max-clients", "idle-timeout", "in-timeout", "max-dummy", "fwmark", "allow-clean",
            "verbose", "log-file", "log-timestamps", "resolve-interval"}
PHOBOS = {"mode", "role", "source-if", "source-lport", "target", "key", "masking", "static-bindings", "socks5-users",
          "socks5-stats", "max-clients", "idle-timeout", "max-dummy", "obfuscate-bytes", "media-pt", "media-ssrc",
          "media-clock", "fwmark", "verbose", "threads"}
# Обязательные поля [instance] для WireGuard (docs/phobos-link-format.md, §2.3)
INSTANCE_REQ = ["source-if", "source-lport", "target", "key", "masking", "verbose", "idle-timeout", "max-dummy"]

STATE = os.path.join(ROOT, "etc/awg-wgobf/state")
WG = os.path.join(ROOT, "etc/wireguard/wgobf0.conf")
WDIR = os.path.join(ROOT, "etc/awg-wgobf")
CL = os.path.join(ROOT, "root/wgobf")
UNITS = os.path.join(ROOT, "units")
LIBD = os.path.join(ROOT, "usr/local/lib/awg2")

# Песочница: службы «работают», если нет файла dead.<юнит>; сборки нет — форк «собран»
EXTRA = f'''
WGOBF_LIB="{LIBD}"; WGOBF_BIN="$WGOBF_LIB/wg-obfuscator"; WGOBF_PH_BIN="$WGOBF_LIB/phobos-obfuscator"
sleep() {{ :; }}
unit_active() {{ [[ ! -f "{TMP}/dead.$1" ]]; }}
_wgobf_ph_prepare() {{ echo "ph_prepare" >> "$CALLS"; }}
ufw_open() {{ echo "ufw_open $*" >> "$CALLS"; }}
ufw_delete_comment() {{ echo "ufw_delete_comment $*" >> "$CALLS"; }}
ufw_port_state() {{ echo off; }}
udp_listening() {{ return 1; }}
web_vpn_changed() {{ echo "web_vpn_changed" >> "$CALLS"; }}
wg() {{
  case "$1" in
    genkey|genpsk) head -c 32 /dev/urandom | base64 ;;
    pubkey) sha256sum | head -c 43; echo "=" ;;
    *) echo "wg $*" >> "$CALLS" ;;
  esac
}}
'''


def sh(code, stdin=None):
    return bash(EXTRA + code, stdin)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def ini(text):
    """[секция] → {ключ: значение} по порядку; ключи — для сверки с опциями."""
    out, cur = {}, None
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1]
            out[cur] = {}
        elif "=" in s and cur is not None:
            k, v = s.split("=", 1)
            out[cur][k.strip()] = v.strip()
    return out


def keys_in_order(text, section):
    keys, cur = [], None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1]
        elif cur == section and "=" in s:
            keys.append(s.split("=", 1)[0].strip())
    return keys


def state():
    out = {}
    for line in read(STATE).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def reset():
    """Установленный обфускатор: основной профиль, ни одного клиента."""
    for d in (WDIR, CL, UNITS):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(WDIR)
    os.makedirs(os.path.dirname(WG), exist_ok=True)
    with open(STATE, "w") as f:
        f.write("PORT=40000\nWG_PORT=40001\nKEY=MainKeyMainKeyMainKeyMainKey1234\nMASKING=STUN\nALLOW_CLEAN=0\n"
                "NET=10.77.1.0/24\nMTU=1380\nDNS=1.1.1.1, 1.0.0.1\nENDPOINT=203.0.113.10\nSERVER_PUB=SRVPUB=\n")
    with open(WG, "w") as f:
        f.write("[Interface]\nPrivateKey = S\nAddress = 10.77.1.1/24\nListenPort = 40001\nMTU = 1380\n")
    for f in os.listdir(TMP):
        if f.startswith("dead."):
            os.remove(os.path.join(TMP, f))
    reset_calls()


def unit(name):
    p = os.path.join(UNITS, name)
    return read(p) if os.path.isfile(p) else ""


def bundle(name, f):
    p = os.path.join(CL, name, f)
    return read(p) if os.path.isfile(p) else ""


def decode_link(link):
    link = link.strip()
    assert link.startswith("phobos://")
    body, _, frag = link[len("phobos://"):].partition("#")
    return base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode(), urllib.parse.unquote(frag)


# ── Основной профиль: серверный конфиг ────────────────────
print("── Основной профиль")
reset()
rc, out, err = sh('_wgobf_write_service_files && echo OK')
main = read(os.path.join(WDIR, "obfuscator.conf"))
m = ini(main).get("main", {})
chk("основной: [main] ClusterM — порт, цель, ключ, AUTO, max-dummy 4 и idle-timeout 300 по умолчанию",
    "OK" in out and m.get("source-lport") == "40000" and m.get("target") == "127.0.0.1:40001"
    and m.get("masking") == "AUTO" and m.get("max-dummy") == "4" and m.get("idle-timeout") == "300"
    and "obfuscate-bytes" not in m and set(m) <= CLUSTERM, [main, out, err])
chk("основной: служба awg-wgobf — программа ClusterM", "ExecStart=" + LIBD + "/wg-obfuscator -c" in unit("awg-wgobf.service"),
    unit("awg-wgobf.service"))
rc, out, _ = sh('wgobf_set ALLOW_CLEAN 1; wgobf_set DUMMY 40; wgobf_set IDLE 120; _wgobf_write_service_files; '
                'cat "$WGOBF_OBF_CONF"')
m = ini(out).get("main", {})
chk("основной: allow-clean, свои max-dummy и idle-timeout", m.get("allow-clean") == "true" and m.get("max-dummy") == "40"
    and m.get("idle-timeout") == "120" and set(m) <= CLUSTERM, out)
rc, out, _ = sh('wgobf_set DUMMY 016; wgobf_set IDLE 5; _wgobf_preset main; echo "$PP_DUMMY $PP_IDLE"')
chk("основной: битые max-dummy (016) и idle (5) из state — значения по умолчанию", out.split() == ["4", "300"], out)

# ── Профили: создание ─────────────────────────────────────
print("── Профили: создание")
reset()
sh("_wgobf_write_service_files")
rc, out, err = sh('wgobf_preset_add media port=41000 masking=MEDIA 2>&1; echo "rc=$?"')
st = state()
pconf = read(os.path.join(WDIR, "p-media.conf")) if os.path.isfile(os.path.join(WDIR, "p-media.conf")) else ""
s = ini(pconf).get("media", {})
chk("MEDIA: профиль записан, форк собран (подготовлен), служба запущена, порт открыт в UFW с меткой профиля",
    "rc=0" in out and st.get("P_media", "").startswith("41000|") and st["P_media"].split("|")[2] == "MEDIA"
    and "ph_prepare" in calls() and "systemctl restart awg-wgobf-p-media.service" in calls()
    and "ufw_open 41000/udp awg-wgobf-p-media" in calls(), [out, err, calls()])
chk("MEDIA на сервере: masking = MEDIA и obfuscate-bytes = 16 явно и после неё; только опции форка",
    s.get("masking") == "MEDIA" and s.get("obfuscate-bytes") == "16"
    and keys_in_order(pconf, "media").index("obfuscate-bytes") > keys_in_order(pconf, "media").index("masking")
    and s.get("target") == "127.0.0.1:40001" and s.get("source-lport") == "41000" and set(s) <= PHOBOS, pconf)
chk("MEDIA: служба awg-wgobf-p-media — программа форка Phobos",
    f"ExecStart={LIBD}/phobos-obfuscator -c {WDIR}/p-media.conf" in unit("awg-wgobf-p-media.service"),
    unit("awg-wgobf-p-media.service"))
rc, out, _ = sh('wgobf_preset_add stun2 port=41001 masking=stun 2>&1; echo "rc=$?"; cat "$WGOBF_DIR/p-stun2.conf"')
s = ini(out).get("stun2", {})
chk("STUN без obfuscate-bytes — ClusterM: masking AUTO, без obfuscate-bytes; маскировка без учёта регистра",
    "rc=0" in out and s.get("masking") == "AUTO" and "obfuscate-bytes" not in s and set(s) <= CLUSTERM
    and f"ExecStart={LIBD}/wg-obfuscator -c" in unit("awg-wgobf-p-stun2.service"), out)
rc, out, _ = sh('wgobf_preset_add part port=41002 masking=STUN obfb=8 dummy=0 idle=60 2>&1; echo "rc=$?"; '
                'cat "$WGOBF_DIR/p-part.conf"')
s = ini(out).get("part", {})
chk("STUN + obfuscate-bytes 8 — форк: AUTO, obfuscate-bytes 8, max-dummy 0, idle-timeout 60",
    "rc=0" in out and s.get("masking") == "AUTO" and s.get("obfuscate-bytes") == "8" and s.get("max-dummy") == "0"
    and s.get("idle-timeout") == "60" and set(s) <= PHOBOS
    and "phobos-obfuscator" in unit("awg-wgobf-p-part.service"), out)

bad = [("bad-name", "port=41010"), ("main", "port=41010"), ("all", "port=41010"), ("media", "port=41010"),
       ("x1", "port=40000"), ("x2", "port=41000"), ("x3", "port=40001"), ("x4", "port=80"),
       ("x5", "obfb=2"), ("x6", "obfb=016"), ("x7", "dummy=2000"), ("x8", "idle=5"), ("x9", "masking=TLS"),
       ("x10", "foo=1"), ("x11", "obfb=1501"), ("x12", "idle=086400")]
res = []
for name, arg in bad:
    rc, out, _ = sh(f'wgobf_preset_add {name} {arg} >/dev/null 2>&1; echo $?')
    res.append(out.strip())
st = state()
chk("отказ: имя с «-», main, all, повтор; порт основного, профиля, WireGuard, ниже 1024; obfb 2, 016, 1501; "
    "max-dummy 2000, idle 5 и 086400, маскировка TLS, неизвестный ключ",
    res == ["1"] * len(bad) and sorted(k for k in st if k.startswith("P_")) == ["P_media", "P_part", "P_stun2"], [res, st])
rc, out, _ = sh('for p in 40000 40001 41000 41001 41002 41003; do wgobf_owns_port $p && echo "$p"; done; '
                'udp_port_busy 41002 && echo busy')
chk("порты профилей закреплены за обфускатором (заняты для AWG, каскадов и новых профилей)",
    out.split() == ["40000", "40001", "41000", "41001", "41002", "busy"], out)

rc, out, _ = sh(f'touch "{TMP}/dead.awg-wgobf-p-dead1.service"; wgobf_preset_add dead1 port=41020 2>&1; echo "rc=$?"; '
                'grep -c "^P_dead1=" "$WGOBF_STATE"; ls "$WGOBF_DIR"')
chk("профиль не запустился — не создан: ни записи, ни конфига", "rc=1" in out and "\n0\n" in out
    and "p-dead1.conf" not in out and "не запустился" in out, out)
os.remove(os.path.join(TMP, "dead.awg-wgobf-p-dead1.service"))
rc, out, _ = sh('for i in 1 2 3 4 5; do wgobf_preset_add "f$i" >/dev/null 2>&1; done; wgobf_presets | wc -l; '
                'wgobf_preset_add f6 2>&1; echo "rc=$?"')
chk(f"больше {8} профилей сверх основного — нельзя", out.split()[0] == "8" and "rc=1" in out and "больше нельзя" in out, out)
rc, out, _ = sh('for i in 1 2 3 4 5; do wgobf_preset_del "f$i" >/dev/null 2>&1; done; wgobf_presets | tr "\\n" " "')
chk("список профилей — по порядку создания", out.split() == ["media", "stun2", "part"], out)
rc, out, _ = sh('echo "P_evil=1|short|MEDIA|0|4|300" >> "$WGOBF_STATE"; echo "P_x-y=41030|$(printf "K%.0s" {1..20})|STUN|0|4|300" '
                '>> "$WGOBF_STATE"; wgobf_presets | tr "\\n" " "; wgobf_preset_exists evil || echo nope')
chk("битые записи профилей (короткий ключ, имя с «-») — не профили", out.split() == ["media", "stun2", "part", "nope"], out)
sh("sed -i '/^P_evil=\\|^P_x-y=/d' \"$WGOBF_STATE\"")

# ── Клиенты и комплекты ───────────────────────────────────
print("── Клиенты и комплекты")
rc, out, err = sh('wgobf_add_client alice 2>&1; wgobf_add_client bob media 2>&1; wgobf_add_client carl part 2>&1; '
                  'wgobf_preset_default media >/dev/null; wgobf_add_client dan 2>&1; echo "rc=$?"')
st = state()
chk("клиенты: основной, media, part и новый по умолчанию (профиль новых — media)",
    "rc=0" in out and "C_alice" not in st and st.get("C_bob") == "media" and st.get("C_carl") == "part"
    and st.get("C_dan") == "media" and st.get("DEFP") == "media", [out, err, st])
for who, port, prof, eng in (("alice", "40000", "main", "clusterm"), ("bob", "41000", "media", "phobos"),
                             ("carl", "41002", "part", "phobos")):
    ph = bundle(who, "phobos.conf")
    inst = ini(ph).get("instance", {})
    obf = ini(bundle(who, "obfuscator.conf")).get("main", {})
    order = keys_in_order(ph, "instance")
    wg_ = ini(bundle(who, "wg.conf"))
    ok_keys = set(inst) <= PHOBOS and (set(obf) <= (CLUSTERM if eng == "clusterm" else PHOBOS))
    chk(f"{who} ({prof}): [instance] — все обязательные поля Phobos, порт профиля, только опции {eng}",
        all(k in inst for k in INSTANCE_REQ) and inst.get("source-if") == "127.0.0.1"
        and inst.get("source-lport") == port and inst.get("target") == f"203.0.113.10:{port}"
        and wg_.get("Peer", {}).get("Endpoint") == f"127.0.0.1:{port}" and ok_keys
        and order[:5] == ["source-if", "source-lport", "target", "key", "masking"]
        and order[-3:] == ["verbose", "idle-timeout", "max-dummy"], [ph, bundle(who, "obfuscator.conf")])
inst_b = ini(bundle("bob", "phobos.conf"))["instance"]
inst_a = ini(bundle("alice", "phobos.conf"))["instance"]
inst_c = ini(bundle("carl", "phobos.conf"))["instance"]
chk("MEDIA у клиента: masking MEDIA, obfuscate-bytes 16 сразу после неё; основной — без obfuscate-bytes; part — 8",
    inst_b.get("masking") == "MEDIA" and inst_b.get("obfuscate-bytes") == "16" and "obfuscate-bytes" not in inst_a
    and inst_c.get("obfuscate-bytes") == "8" and inst_c.get("max-dummy") == "0" and inst_c.get("idle-timeout") == "60"
    and keys_in_order(bundle("bob", "phobos.conf"), "instance")[5] == "obfuscate-bytes", [inst_a, inst_b, inst_c])
conf, frag = decode_link(bundle("bob", "phobos-link.txt"))
chk("ссылка phobos:// — base64url без «=» того же phobos.conf, имя во фрагменте",
    conf == bundle("bob", "phobos.conf") and frag == "bob" and "=" not in bundle("bob", "phobos-link.txt").split("#")[0][9:], frag)
kb, ka = bundle("bob", "keenetic.txt"), bundle("alice", "keenetic.txt")
chk("Keenetic: ссылка установки в верхнее поле; MEDIA — только вкладка Phobos, основному — ClusterM руками",
    "Ссылка установки Phobos" in kb and "только вкладка «Phobos»" in kb and "ClusterM», поля руками" not in kb
    and "ClusterM», поля руками" in ka and "НЕ включать obfuscate-bytes и MEDIA" in ka, [ka, kb])
rb = bundle("bob", "README.txt")
chk("README профиля MEDIA: нужен обфускатор Phobos, ссылка на закреплённый коммит",
    "нужен обфускатор Phobos" in rb and "22aedefda053062dc58c036072d2da6e216d5a34/src/phobos-obfuscator" in rb, rb)
for who, eng in (("alice", "clusterm"), ("bob", "phobos")):
    inst_sh = os.path.join(CL, who, "install-linux.sh")
    r = subprocess.run(["bash", "-n", inst_sh], capture_output=True, text=True)
    body = read(inst_sh)
    want = ("--branch \"v1.6\"" in body and "Ground-Zerro" not in body) if eng == "clusterm" else (
        "fetch -q --depth 1 --filter=blob:none origin \"22aedefda053062dc58c036072d2da6e216d5a34\"" in body
        and "!%s/bin/" in body and 'build="$src/s/src/phobos-obfuscator"' in body)
    chk(f"установщик {who} ({eng}): синтаксис, тело в main, apt без stdin, обфускатор перезапускается",
        r.returncode == 0 and want and body.rstrip().endswith('main "$@"') and "apt-get update -q </dev/null" in body
        and 'systemctl restart "$UNIT"' in body and 'systemctl stop "$UNIT"' in body
        and "masking = " + ("MEDIA" if eng == "phobos" else "STUN") in body, r.stderr + body[:300])
inst_b = bundle("bob", "install-linux.sh")
keep = inst_b.split("<<'KEEP_EOF'\n", 1)[-1].split("\nKEEP_EOF\n", 1)[0]
rc, out, _ = sh("_wgobf_keep_script")
r = subprocess.run(["bash", "-n"], input=keep, capture_output=True, text=True)
chk("установщик: ответы на входящие (SSH) — служба сразу за wg-quick, гаснет с ним; скрипт — тот же, синтаксис цел",
    keep.strip() == out.strip() and r.returncode == 0 and "T=51819" in keep
    and "After=wg-quick@$WG_IF.service\nPartOf=wg-quick@$WG_IF.service" in inst_b
    and "WantedBy=wg-quick@$WG_IF.service" in inst_b and 'systemctl enable "$UNIT" "$KEEP"' in inst_b
    and "declare -f uninstall" in inst_b and 'systemctl disable --now "wg-quick@$WG_IF" "$KEEP" "$UNIT"' in inst_b,
    [r.stderr, inst_b[-1500:]])
# На сервере AWG Toolza (wgobf0.conf песочницы есть) — отказ до apt и сборки
stub = os.path.join(TMP, "inst-bin")
os.makedirs(stub, exist_ok=True)
for b in ("apt-get", "git", "make", "systemctl"):
    with open(os.path.join(stub, b), "w") as f:
        f.write(f"#!/bin/sh\necho CALLED-{b}\nexit 1\n")
    os.chmod(os.path.join(stub, b), 0o755)
r = subprocess.run(["bash", "-c", inst_b.replace("[[ $EUID -eq 0 ]] ||", "true ||")], capture_output=True, text=True,
                   env=dict(os.environ, PATH=stub + ":" + os.environ.get("PATH", "")))
chk("установщик на сервере AWG Toolza: отказ с объяснением, ни apt, ни сборки; про ссылку установки — ни слова",
    r.returncode == 1 and "Здесь стоит сервер AWG Toolza" in r.stdout and "Exit-ноды" in r.stdout
    and "curl" not in inst_b and "сылк" not in r.stdout and "curl" not in bundle("bob", "README.txt")
    and "CALLED-" not in r.stdout + r.stderr, r.stdout + r.stderr)
chk("версия комплекта записана (.v)", bundle("alice", ".v").strip() == "3", bundle("alice", ".v"))
os.remove(os.path.join(CL, "alice", ".v"))
rc, out, _ = sh('wgobf_bundle_fresh alice && cat "$WGOBF_CLIENTS/alice/.v"; wgobf_bundle_fresh alice && echo again')
chk("комплект старого формата (без .v) — пересобирается при показе", out.split() == ["3", "again"], out)

# Назначение профиля, переименование, удаление
rc, out, _ = sh('wgobf_assign alice media 2>&1; echo "rc=$?"; wgobf_assign bob main >/dev/null 2>&1; '
                'wgobf_assign nobody media >/dev/null 2>&1 || echo r1; wgobf_assign alice nope >/dev/null 2>&1 || echo r2')
st = state()
chk("профиль клиента: комплект под новый профиль; основной — запись снята; чужой клиент и профиль — отказ",
    "rc=0" in out and st.get("C_alice") == "media" and "C_bob" not in st and "r1" in out and "r2" in out
    and ini(bundle("alice", "phobos.conf"))["instance"]["source-lport"] == "41000"
    and ini(bundle("bob", "phobos.conf"))["instance"]["source-lport"] == "40000", [out, st])
rc, out, _ = sh('wgobf_rename_client alice alisa >/dev/null 2>&1; wgobf_client_preset alisa; wgobf_delete_client carl >/dev/null 2>&1; '
                'grep -c "^C_" "$WGOBF_STATE"')
st = state()
chk("переименование уносит профиль, удаление снимает его запись",
    out.split()[0] == "media" and st.get("C_alisa") == "media" and "C_alice" not in st and "C_carl" not in st, [out, st])

# ── Профили: настройки, ключ, удаление ────────────────────
print("── Профили: настройки")
reset_calls()
rc, out, _ = sh('wgobf_preset_set main masking=NONE 2>&1; echo "rc=$?"')
chk("маскировка основного: без перезапуска сервера (AUTO), комплекты перевыпущены, старые работают",
    "rc=0" in out and state().get("MASKING") == "NONE" and "restart awg-wgobf.service" not in calls()
    and "продолжат работать" in out and ini(bundle("bob", "obfuscator.conf"))["main"]["masking"] == "NONE", [out, calls()])
rc, out, _ = sh('k=$(wgobf_get KEY); wgobf_set KEY obfkey; wgobf_preset_set main dummy=5 >/dev/null 2>&1; echo "rc=$?"; '
                'wgobf_get DUMMY; wgobf_set KEY "$k"; wgobf_preset_set main dummy=4 >/dev/null 2>&1')
chk("основной со старым коротким ключом — max-dummy меняется (ключ основного не проверяется)",
    out.split() == ["rc=0", "5"], out)
rc, out, _ = sh('wgobf_preset_set main masking=MEDIA 2>&1; echo "rc=$?"; wgobf_preset_set main obfb=16 2>&1; echo "rc=$?"; '
                'wgobf_preset_set media port=42000 2>&1; echo "rc=$?"')
chk("основной — только STUN/NONE и без obfuscate-bytes; порт профиля не меняется",
    out.count("rc=1") == 3 and state().get("MASKING") == "NONE", out)
reset_calls()
rc, out, _ = sh('wgobf_preset_set media dummy=100 idle=600 2>&1; echo "rc=$?"; cat "$WGOBF_DIR/p-media.conf"')
s = ini(out).get("media", {})
chk("max-dummy и idle-timeout профиля: сервер перезапущен, старые комплекты работают",
    "rc=0" in out and s.get("max-dummy") == "100" and s.get("idle-timeout") == "600"
    and "systemctl restart awg-wgobf-p-media.service" in calls() and "продолжат работать" in out
    and ini(bundle("alisa", "phobos.conf"))["instance"]["max-dummy"] == "100", out)
rc, out, _ = sh('wgobf_preset_set media masking=STUN 2>&1; echo "rc=$?"; cat "$WGOBF_DIR/p-media.conf"; '
                'grep ExecStart "' + UNITS + '/awg-wgobf-p-media.service"')
s = ini(out).get("media", {})
chk("MEDIA → STUN (obfuscate-bytes 0): движок ClusterM, прежние комплекты не работают — предупреждение",
    "rc=0" in out and s.get("masking") == "AUTO" and "obfuscate-bytes" not in s and LIBD + "/wg-obfuscator -c" in out
    and "больше не работают" in out and "obfuscate-bytes" not in ini(bundle("alisa", "phobos.conf"))["instance"], out)
sh('wgobf_preset_set media masking=MEDIA >/dev/null 2>&1')
line_before = state()["P_media"]
rc, out, _ = sh(f'touch "{TMP}/dead.awg-wgobf-p-media.service"; wgobf_preset_set media obfb=32 2>&1; echo "rc=$?"; '
                'grep obfuscate "$WGOBF_DIR/p-media.conf"')
os.remove(os.path.join(TMP, "dead.awg-wgobf-p-media.service"))
chk("профиль не перезапустился — настройки и конфиг возвращены", "rc=1" in out and state()["P_media"] == line_before
    and "obfuscate-bytes = 16" in out and "возвращены" in out, out)
old_alisa, old_bob = ini(bundle("alisa", "phobos.conf"))["instance"]["key"], ini(bundle("bob", "phobos.conf"))["instance"]["key"]
rc, out, _ = sh('wgobf_rotate_key media 2>&1; echo "rc=$?"')
new_alisa, new_bob = ini(bundle("alisa", "phobos.conf"))["instance"]["key"], ini(bundle("bob", "phobos.conf"))["instance"]["key"]
chk("смена ключа профиля: новые ключ и комплекты его клиентов, у основного — прежние",
    "rc=0" in out and new_alisa != old_alisa and new_bob == old_bob
    and state()["P_media"].split("|")[1] == new_alisa and len(new_alisa) == 32, out)
reset_calls()
rc, out, _ = sh('wgobf_preset_del media 2>&1; echo "rc=$?"; wgobf_preset_del main 2>&1; echo "rc=$?"; ls "$WGOBF_DIR"')
st = state()
chk("удаление профиля: клиенты — на основной (комплекты перевыпущены), профиль новых — основной, служба и правило UFW сняты",
    "rc=0" in out and "rc=1" in out and "P_media" not in st and "C_alisa" not in st and "C_dan" not in st
    and "DEFP" not in st and "p-media.conf" not in out and "ufw_delete_comment awg-wgobf-p-media" in calls()
    and ini(bundle("alisa", "phobos.conf"))["instance"]["source-lport"] == "40000" and "раздай новые" in out, [out, st])

# ── Устаревшие службы профилей ────────────────────────────
with open(os.path.join(WDIR, "p-ghost.conf"), "w") as f:
    f.write("[ghost]\n")
rc, out, _ = sh('_wgobf_write_service_files; ls "$WGOBF_DIR"')
chk("конфиг профиля, которого нет в state, — убирается вместе со службой", "p-ghost.conf" not in out, out)

# ── IPv6 в туннеле ────────────────────────────────────────
print("── IPv6 в туннеле")
IP6 = os.path.join(TMP, "ip6tables.log")
stubs = {
    "ip6tables": f'echo "ip6tables $*" >> "{IP6}"\nfor a in "$@"; do [[ "$a" == -C || "$a" == -D ]] && exit 1; done\nexit 0',
    "ip6tables-save": f'cat "{TMP}/ip6tables-save.txt" 2>/dev/null; exit 0',
    "sysctl": f'echo "sysctl $*" >> "$CALLS"\n[[ "$1" == -n && "$2" == net.ipv6.conf.eth0.accept_ra ]] && echo 1\nexit 0',
    "wg-quick": 'echo "wg-quick $*" >> "$CALLS"\n[[ "$1" == strip ]] && printf "[Interface]\\nPrivateKey = x\\n"\nexit 0',
}
for n, body in stubs.items():
    with open(os.path.join(BIN, n), "w") as f:
        f.write("#!/usr/bin/env bash\n" + body + "\n")
    os.chmod(os.path.join(BIN, n), 0o755)
V6ROUTE = 'ip() { if [[ "$1" == -6 && "$2" == route ]]; then echo "default via fe80::1 dev eth0 proto ra metric 100"; return 0; fi; command ip "$@"; }; '
reset()
with open(LINKS, "w") as f:
    f.write("wgobf0\n")            # wgobf0 «поднят»
sh("_wgobf_write_service_files")
sh('wgobf_add_client a1 >/dev/null; wgobf_add_client a2 >/dev/null')
rc, out, _ = sh('rublock_on() { return 0; }; ' + V6ROUTE + 'wgobf_ipv6 on 2>&1; echo "rc=$?"')
chk("IPv6 при «РФ мимо VPN» — отказ (список России только IPv4)", "rc=1" in out and "РФ мимо VPN" in out
    and "IPV6" not in state(), out)
rc, out, _ = sh('wgobf_ipv6 on 2>&1; echo "rc=$?"')
chk("IPv6 без маршрута IPv6 у сервера — отказ", "rc=1" in out and "нет IPv6" in out, out)
reset_calls()
rc, out, err = sh(V6ROUTE + 'wgobf_ipv6 on 2>&1; echo "rc=$?"')
st, wgc = state(), read(WG)
net6 = st.get("NET6", "")
p6 = net6[:-len("/64")] if net6.endswith("::/64") else "?"
chk("IPv6 включён: случайная ULA /64, адрес сервера ::1, пиры ::2 и ::3, wg-quick перезапущен, панель — новые сети",
    "rc=0" in out and st.get("IPV6") == "1" and re.match(r"^fd[0-9a-f]{2}(:[0-9a-f]{1,4}){3}::/64$", net6)
    and f"Address = 10.77.1.1/24, {p6}1/64" in wgc and f"AllowedIPs = 10.77.1.2/32, {p6}2/128" in wgc
    and f"AllowedIPs = 10.77.1.3/32, {p6}3/128" in wgc and "systemctl restart wg-quick@wgobf0" in calls()
    and "web_vpn_changed" in calls(), [out, err, wgc])
chk("комплекты с IPv6: адрес клиента v4 + v6, AllowedIPs с ::/0", f"Address = 10.77.1.2/32, {p6}2/128" in bundle("a1", "wg.conf")
    and bundle("a1", "wg.conf").count("::/0") == 1, bundle("a1", "wg.conf"))
inst = bundle("a1", "install-linux.sh")
line = next((l for l in inst.splitlines() if "s#, ::/0##" in l), "")
sample = os.path.join(TMP, "client-wg.conf")
with open(sample, "w") as f:
    f.write(bundle("a1", "wg.conf"))
subprocess.run(["bash", "-c", line.replace('"/etc/wireguard/$WG_IF.conf"', f'"{sample}"')], check=False)
fixed = read(sample)
chk("установщик на устройстве без IPv6: адрес IPv6 и ::/0 убираются, IPv4 остаётся",
    line and "Address = 10.77.1.2/32\n" in fixed and "::/0" not in fixed and p6 not in fixed, [line, fixed])
rc, out, _ = sh('wgobf_add_client a3 >/dev/null 2>&1; wgobf_delete_client a1 >/dev/null 2>&1; wgobf_add_client a4 >/dev/null 2>&1; '
                'for c in a2 a3 a4; do echo "$(wgobf_client_ip $c) $(wgobf_client_ip6 $c)"; done')
chk("свободный адрес ищется и в строках с IPv6: новый — .4, освободившийся .2 — следующему; IPv6 — по номеру",
    out.split("\n")[:3] == [f"10.77.1.3 {p6}3", f"10.77.1.4 {p6}4", f"10.77.1.2 {p6}2"], out)
rc, out, _ = sh('wgobf_v6_of 10.77.1.200')
chk("номер в /24 — шестнадцатерично (200 → c8)", out.strip() == p6 + "c8", out)

# Правила IPv6 (скрипт wgobf0, как при загрузке)
for f in ("warp.peers.wgobf",):
    with open(os.path.join(ROOT, f), "w") as fh:
        fh.write("10.77.1.3\n")
with open(os.path.join(ROOT, "xray.peers.wgobf"), "w") as fh:
    fh.write("10.77.1.4|out1\n")
open(IP6, "w").close()
reset_calls()
ENV2 = dict(ENV)
r = subprocess.run(["bash", "-c", f'ip() {{ if [[ "$1" == -6 ]]; then echo "default via fe80::1 dev eth0 proto ra"; return 0; fi; '
                    f'command ip "$@"; }}; export -f ip; bash "{ROOT}/scripts/WGOBF_FW" up'],
                   capture_output=True, text=True, env=ENV2)
log6 = read(IP6)
c = calls()
chk("скрипт wgobf0 up: accept_ra=2 на аплинке до пересылки IPv6, NAT66 сети, вход и ответы (conntrack)",
    r.returncode == 0 and "sysctl -qw net.ipv6.conf.eth0.accept_ra=2" in c
    and c.index("net.ipv6.conf.eth0.accept_ra=2") < c.index("net.ipv6.conf.all.forwarding=1")
    and f"-t nat -A POSTROUTING -s {net6} ! -o wgobf0 -j MASQUERADE -m comment --comment awg-wgobf" in log6
    and "-I FORWARD 1 -i wgobf0 -j ACCEPT -m comment --comment awg-wgobf" in log6
    and "-I FORWARD 1 -o wgobf0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" in log6, [r.stderr, log6, c])
chk("IPv6: порт WireGuard закрыт снаружи, DNS и DoT по IPv6 — отказ (DNS клиентов — IPv4)",
    "-I INPUT 1 -p udp --dport 40001 ! -i lo -j DROP -m comment --comment awg-wgobf" in log6
    and all(f"-I FORWARD 1 -i wgobf0 -p {p} --dport {d} -j REJECT -m comment --comment awg-wgobf" in log6
            for p, d in (("udp", 53), ("tcp", 53), ("tcp", 853), ("udp", 853))), log6)
chk("клиенты в туннелях (WARP, Xray) — отказ по IPv6, остальные — нет",
    f"-I FORWARD 1 -i wgobf0 -s {p6}3 -j REJECT --reject-with icmp6-adm-prohibited -m comment --comment awg-wgobf-v6r" in log6
    and f"-s {p6}4 -j REJECT" in log6 and f"-s {p6}2 -j REJECT" not in log6, log6)
os.remove(os.path.join(ROOT, "warp.peers.wgobf"))
os.remove(os.path.join(ROOT, "xray.peers.wgobf"))
rc, out, _ = sh('server_exists() { return 0; }; rudirect_on() { return 1; }; rublock_enable 2>&1; echo "rc=$?"')
chk("«РФ мимо VPN» при IPv6 в туннеле — отказ", "rc=1" in out and "IPv6" in out, out)
rc, out, _ = sh('_web_fw_nets')
chk("веб-панель «только через VPN»: и сеть IPv6 обфускатора", net6 in out.split() and "10.77.1.0/24" in out.split(), out)
reset_calls()
rc, out, _ = sh('wgobf_ipv6 off 2>&1; echo "rc=$?"')
wgc = read(WG)
chk("IPv6 выключен: адреса IPv6 сняты, сеть запомнена (при новом включении — та же), комплекты без IPv6",
    "rc=0" in out and ":" not in "".join(l for l in wgc.splitlines() if l.startswith(("Address", "AllowedIPs")))
    and "IPV6" not in state() and state().get("NET6") == net6 and "Address = 10.77.1.3/32\n" in bundle("a2", "wg.conf"),
    [out, wgc])
rc, out, _ = sh(V6ROUTE + f'touch "{TMP}/x"; systemctl() {{ echo "systemctl $*" >> "$CALLS"; [[ "$1 $2" != "restart wg-quick@wgobf0" ]]; }}; '
                'wgobf_ipv6 on 2>&1; echo "rc=$?"')
chk("wgobf0 не поднялся с IPv6 — конфиг и состояние возвращены", "rc=1" in out and "IPV6" not in state()
    and ":" not in "".join(l for l in read(WG).splitlines() if l.startswith("AllowedIPs")), out)
open(LINKS, "w").close()

# ── Выборочная загрузка форка (git, без сети) ─────────────
print("── Загрузка форка Phobos")
REPO = os.path.join(TMP, "phrepo")
os.makedirs(os.path.join(REPO, "src/phobos-obfuscator/bin"))
os.makedirs(os.path.join(REPO, "windows"))
for p, body in (("src/phobos-obfuscator/Makefile", "all:\n"), ("src/phobos-obfuscator/config.c", "int x;\n"),
                ("src/phobos-obfuscator/bin/wg-obfuscator-x86_64", "BIN\n"), ("windows/app.exe", "EXE\n"), ("README.md", "r\n")):
    with open(os.path.join(REPO, p), "w") as f:
        f.write(body)
g = dict(ENV, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
subprocess.run(["git", "init", "-q", REPO], check=True, env=g)
subprocess.run(["git", "-C", REPO, "add", "."], check=True, env=g)
subprocess.run(["git", "-C", REPO, "commit", "-qm", "x"], check=True, env=g)
subprocess.run(["git", "-C", REPO, "config", "uploadpack.allowAnySHA1InWant", "true"], check=True, env=g)
sha = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True, env=g).stdout.strip()
rc, out, err = sh(f'WGOBF_PH_REPO="file://{REPO}"; WGOBF_PH_COMMIT="{sha}"; _wgobf_ph_fetch "{TMP}/fetch1" && echo FETCHED; '
                  f'find "{TMP}/fetch1" -path "*/.git" -prune -o -type f -print | sed "s|{TMP}/fetch1/||" | sort')
chk("форк: коммит по SHA, только каталог обфускатора, без bin/ и прочего репозитория",
    "FETCHED" in out and "src/phobos-obfuscator/Makefile" in out and "src/phobos-obfuscator/config.c" in out
    and "bin/" not in out and "windows" not in out and "README.md" not in out, [out, err])
rc, out, err = sh(f'WGOBF_PH_REPO="file://{REPO}"; WGOBF_PH_COMMIT="{"0" * 40}"; _wgobf_ph_fetch "{TMP}/fetch2" && echo FETCHED || echo FAILED')
chk("форк: чужой коммит — отказ", "FAILED" in out and "FETCHED" not in out, out)

# ── API ───────────────────────────────────────────────────
print("── API")
reset()
sh("_wgobf_write_service_files; wgobf_preset_add media port=41000 masking=MEDIA >/dev/null 2>&1; "
   "wgobf_add_client c1 media >/dev/null 2>&1; wgobf_add_client c2 >/dev/null 2>&1; wgobf_preset_default media >/dev/null")
rc, out, _ = sh(f'API_DATA="{TMP}/st.json"; _api_wgobf status >/dev/null 2>&1; cat "$API_DATA"')
try:
    d = json.loads(out)
except ValueError:
    d = {}
pr = d.get("presets") or []
chk("api wgobf status: профили (основной первым), профиль новых, IPv6 и причина, max-dummy и idle основного",
    [p.get("name") for p in pr] == ["main", "media"]
    and pr[1] == {"name": "media", "port": 41000, "masking": "MEDIA", "obfb": 16, "dummy": 4, "idle": 300,
                  "engine": "phobos", "running": True, "clients": 1, "ufw": "off"}
    and pr[0].get("engine") == "clusterm" and pr[0].get("clients") == 1 and d.get("default") == "media"
    and d.get("ipv6") is False and "нет IPv6" in (d.get("ipv6_why") or "") and d.get("dummy") == 4
    and d.get("idle") == 300 and d.get("ph_version") == "1.4.1", out[-600:])
rc, out, _ = sh(f'API_DATA="{TMP}/cl.json"; _api_wgobf clients >/dev/null 2>&1; cat "$API_DATA"')
try:
    rows = {r["name"]: r for r in json.loads(out)}
except (ValueError, KeyError, TypeError):
    rows = {}
chk("api wgobf clients: профиль, ключ и IPv6 клиента", rows.get("c1", {}).get("preset") == "media"
    and rows.get("c2", {}).get("preset") == "main" and rows.get("c1", {}).get("pub", "").endswith("=")
    and rows.get("c1", {}).get("ip") == "10.77.1.2" and rows.get("c1", {}).get("ip6") == "", out[-400:])
rc, out, _ = sh(f'API_DATA="{TMP}/b.json"; _api_wgobf bundle c1 >/dev/null 2>&1; cat "$API_DATA"')
try:
    b = json.loads(out)
except ValueError:
    b = {}
chk("api wgobf bundle: профиль, ключ клиента (привязка ссылки установки), установщик среди файлов",
    b.get("preset") == "media" and b.get("pub") == rows.get("c1", {}).get("pub")
    and any(f.get("name") == "install-linux.sh" for f in b.get("files") or []), out[-400:])
rc, out, _ = sh('journalctl() { echo "journalctl $*"; }; _api_log wgobf 20')
chk("журнал обфускатора — основной и службы профилей одним журналом",
    "-u awg-wgobf.service -u awg-wgobf-p-media.service -n 20" in out, out)
rc, out, _ = sh('_api_readonly wgobf presets && echo RO; _api_readonly wgobf preset add x || echo RW; '
                '_api_readonly wgobf ipv6 on || echo RW2; _api_readonly wgobf assign c1 main || echo RW3')
chk("api: wgobf presets — чтение без очереди; preset, ipv6, assign — через замок", out.split() == ["RO", "RW", "RW2", "RW3"], out)

rc, out, _ = sh('wgobf_cli preset add cli1 masking=STUN port=41050 dummy=8 >/dev/null 2>&1; echo "rc=$?"; '
                'wgobf_get P_cli1 | cut -d"|" -f1,3-; wgobf_cli assign c2 cli1 >/dev/null 2>&1; wgobf_client_preset c2; '
                'wgobf_cli preset del cli1 >/dev/null 2>&1; wgobf_presets | tr "\\n" " "')
chk("awg2 --wgobf preset add … со всеми ключами, assign, preset del", out.split() == [
    "rc=0", "41050|STUN|0|8|300", "cli1", "media"], out)
cli = read(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src/lib/cli.sh"))
chk("--wgobf передаёт обфускатору все аргументы (preset add — больше трёх)", 'wgobf_cli "${@:2}"' in cli)

# ── Удаление ──────────────────────────────────────────────
print("── Удаление")
reset()
sh("_wgobf_write_service_files; wgobf_preset_add m1 masking=MEDIA >/dev/null 2>&1")
os.makedirs(LIBD, exist_ok=True)
for f in ("phobos-obfuscator", "phobos-obfuscator.commit", "wg-obfuscator"):
    open(os.path.join(LIBD, f), "w").close()
rc, out, _ = sh('remove_unit() { echo "remove_unit $*" >> "$CALLS"; }; ufw_delete_matching() { echo "ufw_delete_matching $*" >> "$CALLS"; }; '
                '_wgobf_routes_clear() { :; }; _wgobf_teardown drop; ls "$WGOBF_LIB" 2>/dev/null; echo END')
chk("удаление: службы профилей, правила UFW (по подстроке — и профилей), форк с меткой коммита",
    "remove_unit awg-wgobf-p-m1.service" in calls() and "ufw_delete_matching awg-wgobf" in calls()
    and out.strip() == "END" and not os.path.exists(WDIR), [out, calls()])

summary()
