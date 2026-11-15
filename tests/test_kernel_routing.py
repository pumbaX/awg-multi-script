"""Маршрутизация туннелей на настоящем ядре (tests/kernel_routing.sh) — в
отдельном сетевом пространстве: правила клиентов, «если туннель упал», «РФ
напрямую», «куда идёт адрес». Нет iproute2, ipset, iptables или netns
(unshare -rn / sudo) — пропуск."""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AWG2 = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "dist", "awg2.sh"))
PROBE = "ip tuntap add mode tun dev t0 && ip link add v0 type veth peer name v1 && ipset create p hash:net && iptables -t mangle -S >/dev/null"


def runner():
    if not all(shutil.which(c) for c in ("ip", "ipset", "iptables", "unshare")):
        return None
    for pre in (["unshare", "-rn"], ["sudo", "-n", "unshare", "-n"]):
        try:
            if subprocess.run(pre + ["bash", "-c", PROBE], capture_output=True, timeout=30).returncode == 0:
                return pre
        except (OSError, subprocess.TimeoutExpired):
            continue
    return None


pre = runner()
if pre is None:
    print("ПРОПУСК: нет iproute2, ipset, iptables или сетевого пространства (unshare -rn)")
    sys.exit(0)
bad = 0
for part in ("tunnels", "rudirect", "rpf", "exits"):
    tmp = tempfile.mkdtemp(prefix="awg2-kernel.")
    r = subprocess.run(pre + ["bash", os.path.join(HERE, "kernel_routing.sh"), AWG2, tmp, part],
                       capture_output=True, text=True, timeout=300)
    print(r.stdout + r.stderr)
    bad += r.returncode != 0
    shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if bad else 0)
