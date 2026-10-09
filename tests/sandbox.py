"""
sandbox.py — песочница для тестов awg2 и бота: собранный awg2 подключается
как библиотека, пути состояния уходят во временный каталог, системные
команды (ip, iptables, systemctl, awg...) подменены заглушками с журналом.

  from sandbox import *   — chk(), bash(), api_wrapper() и остальное
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

__all__ = ["fake_xray", "HERE", "AWG2", "chk", "summary", "TMP", "BIN", "CALLS", "LINKS", "ACTIVE", "IPT_SAVE", "AWG_DUMP", "WG_DUMP",
           "ROOT", "LIB",
           "PRELUDE", "ENV", "bash", "run_script", "calls", "reset_calls", "kv", "OLD20", "api_wrapper", "fake_acme",
           "json", "os", "re", "shutil", "subprocess", "sys"]

HERE = os.path.dirname(os.path.abspath(__file__))
AWG2 = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "dist", "awg2.sh"))

fails = 0
checks = 0


def chk(label, cond, detail=""):
    global fails, checks
    checks += 1
    if cond:
        print(f"  OK   {label}")
    else:
        fails += 1
        print(f"  FAIL {label}" + (f"\n       {detail}" if detail else ""))


# ── Песочница ─────────────────────────────────────────────
TMP = tempfile.mkdtemp(prefix="awg2-test.")
BIN = os.path.join(TMP, "bin")
os.makedirs(BIN)
CALLS = os.path.join(TMP, "calls.log")
LINKS = os.path.join(TMP, "links")          # «поднятые» интерфейсы, по строке
ACTIVE = os.path.join(TMP, "active")        # «работающие» юниты systemd, по строке
IPT_SAVE = os.path.join(TMP, "iptables-save.txt")
AWG_DUMP = os.path.join(TMP, "awg-dump")      # вывод `awg show awg0 dump`, если файл есть
WG_DUMP = os.path.join(TMP, "wg-dump")        # вывод `wg show wgobf0 dump` (WG + обфускатор), если файл есть
open(LINKS, "w").close()
open(ACTIVE, "w").close()
open(IPT_SAVE, "w").close()

STUBS = {
    # ip link show X — успех, если X в файле links; остальное — только журнал
    "ip": r'''echo "ip $*" >> "$CALLS"
if [[ "$1" == link && "$2" == show ]]; then grep -qx "${3:-}" "$LINKS"; exit; fi
if [[ "$1" == -4 && "$2" == route && "$3" == show ]]; then echo "default via 192.0.2.1 dev eth0"; exit 0; fi
if [[ "$1" == -4 && "$2" == -o && "$3" == addr ]]; then echo "2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0"; exit 0; fi
if [[ "$1" == rule && "$2" == del ]]; then exit 1; fi
if [[ "$1" == rule && "$2" == show ]]; then exit 0; fi
exit 0''',
    "iptables": r'''echo "iptables $*" >> "$CALLS"
for a in "$@"; do [[ "$a" == -C ]] && exit 1; [[ "$a" == -D ]] && exit 1; done
exit 0''',
    "iptables-save": r'''cat "$IPT_SAVE"''',
    "ip6tables": r'''echo "ip6tables $*" >> "$CALLS"; exit 1''',
    "systemctl": r'''echo "systemctl $*" >> "$CALLS"
if [[ "$1" == is-active || "$1" == is-enabled ]]; then
  for a in "$@"; do grep -qxF -- "$a" "$ACTIVE" && exit 0; done
  exit 1
fi
exit 0''',
    "sysctl": r'''echo "sysctl $*" >> "$CALLS"; exit 0''',
    "awg": r'''case "$1" in
  genkey|genpsk) head -c 32 /dev/urandom | base64 ;;
  pubkey) sha256sum | head -c 43; echo "=" ;;
  show) echo "awg $*" >> "$CALLS"
        [[ -f "$AWG_DUMP" ]] || exit 0
        [[ "${3:-}" == dump ]] && cat "$AWG_DUMP"
        [[ "${3:-}" == transfer ]] && awk -F'\t' 'NR > 1 {print $1 "\t" $6 "\t" $7}' "$AWG_DUMP"
        [[ "${3:-}" == endpoints ]] && awk -F'\t' 'NR > 1 {print $1 "\t" $3}' "$AWG_DUMP" ;;
  *) echo "awg $*" >> "$CALLS" ;;
esac
exit 0''',
    "awg-quick": r'''echo "awg-quick $*" >> "$CALLS"
[[ "$1" == strip ]] && printf '[Interface]\nPrivateKey = x\n'
exit 0''',
    "wg": r'''echo "wg $*" >> "$CALLS"
[[ "$1" == show && "${3:-}" == dump && -f "$WG_DUMP" ]] && cat "$WG_DUMP"
[[ "$1" == show && "${3:-}" == transfer && -f "$WG_DUMP" ]] && awk -F'\t' 'NR > 1 {print $1 "\t" $6 "\t" $7}' "$WG_DUMP"
exit 0''',
    "conntrack": r'''exit 0''',
    "ss": r'''exit 0''',
    "curl": r'''for a in "$@"; do [[ "$a" == *http_code* ]] && { echo 204; exit 0; }; done
exit 1''',
    "ufw": r'''exit 1''',
    "modprobe": r'''exit 0''',
}
for name, body in STUBS.items():
    p = os.path.join(BIN, name)
    with open(p, "w") as f:
        f.write("#!/usr/bin/env bash\n" + body + "\n")
    os.chmod(p, 0o755)

LIB = os.path.join(TMP, "lib.sh")
with open(AWG2, encoding="utf-8") as f:
    src = f.read()
assert src.rstrip().endswith('main "$@"'), "последняя строка сборки — main"
with open(LIB, "w", encoding="utf-8") as f:
    f.write(src.rstrip()[: -len('main "$@"')])

ROOT = os.path.join(TMP, "root")
os.makedirs(ROOT)
# Все пути состояния — в песочницу; юниты пишутся в каталог вместо /etc/systemd.
PRELUDE = f'''
source "{LIB}"
AWG_DIR="{ROOT}/etc/amnezia/amneziawg"; SERVER_CONF="$AWG_DIR/awg0.conf"
CLIENT_DIR="{ROOT}/root"; STATE_DIR="{ROOT}/var/lib/awg2"; LOG_FILE="{ROOT}/awg.log"
INSTALL_LOG="{ROOT}/install.log"; EXITS_DIR="$AWG_DIR"
EXITS_PEERS="$EXITS_DIR/exits_peers.list"; EXITS_STATE="$EXITS_DIR/exits_state"
for v in DNS_PERSIST_SCRIPT DNS_HEALTH_SCRIPT CASCADE_SCRIPT T2S_ROUTING_SCRIPT XRAY_ROUTING_SCRIPT \\
         EXITS_SCRIPT EXPIRE_BIN WARP_AUTOSTART_SCRIPT WARP_HEALTH_SCRIPT WGOBF_FW USQUE_UP_HOOK ANTISCAN_SCRIPT; do
  printf -v "$v" '%s' "{ROOT}/scripts/$v"
done
CASCADE_DIR="{ROOT}/etc/awg-cascade"; CASCADE_RULES="$CASCADE_DIR/rules.conf"; CASCADE_LOG="{ROOT}/cascade.log"
WGOBF_DIR="{ROOT}/etc/awg-wgobf"; WGOBF_STATE="$WGOBF_DIR/state"
WGOBF_WG_CONF="{ROOT}/etc/wireguard/wgobf0.conf"; WGOBF_CLIENTS="{ROOT}/root/wgobf"
CERT_DIR="{ROOT}/etc/awg2/cert"; CERT_FULL="$CERT_DIR/fullchain.pem"; CERT_KEY="$CERT_DIR/key.pem"
CERT_STATE="{ROOT}/var/lib/awg2/cert"; ACME_DIR="{ROOT}/acme.sh"; ACME_HOME="{ROOT}/var/lib/awg2/acme"
CERT_FIND_ROOT="{ROOT}"
EXPIRE_STATE_DIR="{ROOT}/var/lib/awg2-expire"; EXPIRE_LOG="{ROOT}/expire.log"; BOT_CONF="{ROOT}/bot.conf"
BOT_ADMINS="{ROOT}/admins.json"; TRAFFIC_DB="$STATE_DIR/traffic.json"
EXPIRE_STALE=999999999      # сторож таймера в песочнице молчит; его проверка — отдельно
BACKUP_DIR="{ROOT}/awg_backup"; MOD_BACKUP_DIR="{ROOT}/mod-backups"; UPDATE_CHANNEL_FILE="$STATE_DIR/channel"
MOD_TAG_FILE="$STATE_DIR/module_tag"; TOOLS_TAG_FILE="$STATE_DIR/tools_tag"; UPSTREAM_CACHE="$STATE_DIR/upstream_tags"; COUNTRY_CACHE="$STATE_DIR/country"
WARP_PEERS="{ROOT}/warp.peers"; XRAY_PEERS="{ROOT}/xray.peers"; USQUE_LOG="{ROOT}/usque.log"
XRAY_DIR="{ROOT}/etc/xray"; XRAY_CONF="$XRAY_DIR/config.json"; XRAY_STATE="$XRAY_DIR/state"
XRAY_BIN="{ROOT}/bin/xray"; XRAY_ASSET_DIR="{ROOT}/xray-assets"
T2S_DIR="{ROOT}/etc/tun2socks"; T2S_CONF="$T2S_DIR/proxy.txt"
DNS_PROXY_CONF="{ROOT}/etc/dnscrypt-proxy/dnscrypt-proxy.toml"; DNS_PROXY_STATE="{ROOT}/etc/dnscrypt-proxy/awg.state"
DNS_PROXY_BACKUP_CONF="$DNS_PROXY_CONF.awg-backup"
WARP_DIR="{ROOT}/etc/wgcf"; WARP_ACCOUNT="$WARP_DIR/wgcf-account.toml"; WARP_PROFILE="$WARP_DIR/wgcf-profile.conf"
WARP_STATE="$WARP_DIR/state"; WARP_CONF="{ROOT}/etc/wireguard/warp0.conf"; WARP_BACKEND_FILE="{ROOT}/etc/awg-warp-backend"
USQUE_DIR="{ROOT}/etc/usque"; USQUE_CONF="$USQUE_DIR/config.json"
ANTISCAN_DIR="$STATE_DIR/antiscan"; ANTISCAN_CONF="$ANTISCAN_DIR/antiscan.conf"; ANTISCAN_ALLOW="$ANTISCAN_DIR/allow"
ANTISCAN_LOG="{ROOT}/antiscan.log"
write_unit() {{ mkdir -p "{ROOT}/units"; cat > "{ROOT}/units/$1"; }}
remove_unit() {{ :; }}
mkdir -p "$AWG_DIR" "$CLIENT_DIR" "$STATE_DIR" "{ROOT}/scripts"
'''

ENV = dict(os.environ, PATH=BIN + ":" + os.environ["PATH"], CALLS=CALLS, LINKS=LINKS, ACTIVE=ACTIVE,
           IPT_SAVE=IPT_SAVE, AWG_DUMP=AWG_DUMP, WG_DUMP=WG_DUMP, LC_ALL="C.UTF-8")


def bash(code, stdin=None):
    r = subprocess.run(["bash", "-c", PRELUDE + code], input=stdin, capture_output=True,
                       text=True, env=ENV, timeout=300)
    return r.returncode, r.stdout, r.stderr


def run_script(path, *args):
    r = subprocess.run(["bash", path, *args], capture_output=True, text=True, env=ENV, timeout=60)
    return r.returncode, r.stdout, r.stderr


def calls():
    with open(CALLS) as f:
        return f.read()


def reset_calls():
    open(CALLS, "w").close()


def kv(text):
    out = {}
    for line in text.splitlines():
        if " = " in line:
            k, v = line.split(" = ", 1)
            out[k.strip()] = v.strip()
    return out


# Сервер «прежней версии»: профиль pro, AWG 2.0, два клиента, у bob — срок.
OLD20 = """# AWG_PROFILE=pro
# AmneziaWG Toolza — AWG 2.0 server config
# Region: ru
# AWG_MIMICRY=quic
[Interface]
PrivateKey = sPRIV=
Address = 10.23.45.1/24
ListenPort = 51820
MTU = 1320
Jc = 5
Jmin = 10
Jmax = 90
S1 = 40
S2 = 60
S3 = 20
S4 = 10
H1 = 100-2000
H2 = 536870912-536880000
H3 = 1073741824-1073750000
H4 = 1610612736-1610620000
PostUp = true
PostDown = true

[Peer]
# alice
PublicKey = PUBALICE=
PresharedKey = PSK=
AllowedIPs = 10.23.45.2/32

[Peer]
# bob
# expires=1
PublicKey = PUBBOB=
AllowedIPs = 10.23.45.3/32
"""


def api_wrapper():
    """Исполняемая обёртка «awg2» для API: те же функции, пути — песочница.
    systemd-run «нет» — задачи идут запасным путём через setsid."""
    path = os.path.join(TMP, "awg2-api")
    with open(path, "w") as f:
        f.write("#!/usr/bin/env bash\n" + PRELUDE + '[[ "${1:-}" == api ]] && shift\napi_main "$@"\n')
    os.chmod(path, 0o755)
    stub = os.path.join(BIN, "systemd-run")
    with open(stub, "w") as f:
        f.write("#!/usr/bin/env bash\nexit 1\n")
    os.chmod(stub, 0o755)
    return path


def fake_xray(tun=True):
    """xray-заглушка в XRAY_BIN: version и `run -test` (конфиг принят; без
    tun=True отвергает inbound tun — как сборка без него)."""
    d = os.path.join(ROOT, "bin")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "xray")
    with open(path, "w") as f:
        f.write("#!/usr/bin/env bash\n"
                'case "$1" in\n'
                '  version) echo "Xray 26.3.27 (stub)" ;;\n'
                '  run) ' + ('' if tun else 'grep -q \'"protocol": "tun"\' "$4" && { echo "failed: unknown protocol tun"; exit 1; }; ')
                + 'echo "Configuration OK." ;;\n'
                "esac\n")
    os.chmod(path, 0o755)
    return path


def fake_acme():
    """acme.sh-заглушка: пишет вызовы в журнал, на --issue выпускает
    самоподписанный сертификат (openssl) на -d, на --install-cert копирует его."""
    d = os.path.join(ROOT, "acme.sh")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "acme.sh")
    with open(path, "w") as f:
        f.write(r'''#!/usr/bin/env bash
echo "acme.sh $*" >> "$CALLS"
home="" name="" key="" full="" cmd=""
while (( $# )); do
  case "$1" in
    --home) home="$2"; shift ;;
    -d) name="$2"; shift ;;
    --key-file) key="$2"; shift ;;
    --fullchain-file) full="$2"; shift ;;
    --issue|--install-cert|--remove|--cron) cmd="$1" ;;
  esac
  shift
done
dir="$home/${name}_ecc"
case "$cmd" in
  --issue)
    [[ -f "$dir/fullchain.cer" ]] && { echo "Skip, Next renewal time is: soon"; exit 2; }
    mkdir -p "$dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 6 -subj "/CN=$name" \
      -keyout "$dir/$name.key" -out "$dir/fullchain.cer" 2>/dev/null || exit 1
    echo "Cert success." ;;
  --install-cert) cp "$dir/$name.key" "$key" && cp "$dir/fullchain.cer" "$full" ;;
  --remove) rm -rf "$dir" ;;
esac
exit 0
''')
    os.chmod(path, 0o755)
    return path


def summary():
    shutil.rmtree(TMP, ignore_errors=True)
    print(f"\nпроверок: {checks}, провалов: {fails}")
    sys.exit(1 if fails else 0)
