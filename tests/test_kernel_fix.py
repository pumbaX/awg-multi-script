#!/usr/bin/env python3
"""
test_kernel_fix.py — автосборка модуля AWG под новые ядра.

Поддельные ядра в песочнице: каталоги KMODS_DIR (заголовки — build внутри),
работающее ядро — файл running, собран ли модуль — built/<ядро>, загружен —
файл loaded. dkms пишет вызовы в журнал и «собирает» (fail/<ядро> — сборка
падает и пишет make.log с ошибкой), apt ставит заголовки, если они есть в
«репозитории» (repo/<ядро>), dpkg «работает», пока есть файл busy.

Запуск:  python3 tests/test_kernel_fix.py [путь/к/awg2.sh]
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sandbox import *  # noqa: E402,F401,F403

KD = os.path.join(TMP, "kfake")
KM = os.path.join(ROOT, "lib/modules")
for d in ("built", "fail", "repo"):
    os.makedirs(os.path.join(KD, d), exist_ok=True)
os.makedirs(KM, exist_ok=True)
ENV["KD"] = KD
STATE = os.path.join(ROOT, "var/lib/awg2/kernel-fix")
UNITS = os.path.join(ROOT, "units")
K90, K100, K110, K120 = (f"6.8.0-{n}-generic" for n in (90, 100, 110, 120))

EXTRA = r'''
MOD_SRC_DIR="$STATE_DIR/modsrc"; mkdir -p "$MOD_SRC_DIR"
uname() { case "$1" in -r) cat "$KD/running" ;; *) command uname "$@" ;; esac; }
installed_kernels() { ls "$KMODS_DIR" 2>/dev/null | sort -V; }
mod_built_for() { [[ -f "$KD/built/$1" ]]; }
mod_loaded() { [[ -f "$KD/loaded" ]]; }
_mod_src_patch() { :; }
dkms() {
  echo "dkms $*" >> "$CALLS"
  local k=""
  case "$1" in
    install)
      while (( $# )); do [[ "$1" == -k ]] && k="$2"; shift; done
      if [[ -f "$KD/fail/$k" ]]; then
        mkdir -p "$DKMS_DIR/amneziawg/1.0.0/$k/$(command uname -m)/log"
        printf 'make -C /lib/modules/%s/build M=/var/lib/dkms/amneziawg/1.0.0/build modules\n/var/lib/dkms/amneziawg/1.0.0/build/socket.c:42:5: error: implicit declaration of function udp_tunnel_xmit_skb\n' "$k" \
          > "$DKMS_DIR/amneziawg/1.0.0/$k/$(command uname -m)/log/make.log"
        echo "Error! Bad return status for module build on kernel: $k"; return 10
      fi
      touch "$KD/built/$k" ;;
  esac
  return 0
}
apt_install() {
  echo "apt_install $*" >> "$CALLS"
  local k="${1#linux-headers-}"
  [[ -f "$KD/repo/$k" ]] || return 100
  mkdir -p "$KMODS_DIR/$k/build"
}
pgrep() { [[ -f "$KD/busy" && " $* " == *" dpkg "* ]]; }
do_repair() { echo "do_repair" >> "$CALLS"; touch "$KD/loaded"; }
server_exists() { return 0; }
iface_up() { [[ -f "$KD/loaded" ]]; }
'''
WRAP = os.path.join(TMP, "awg2-api-kfix")
with open(WRAP, "w") as f:
    f.write("#!/usr/bin/env bash\n" + PRELUDE + EXTRA + '[[ "${1:-}" == api ]] && shift\napi_main "$@"\n')
os.chmod(WRAP, 0o755)
with open(os.path.join(BIN, "systemd-run"), "w") as f:
    f.write("#!/usr/bin/env bash\nexit 1\n")
os.chmod(os.path.join(BIN, "systemd-run"), 0o755)
os.makedirs(os.path.join(ROOT, "etc/amnezia/amneziawg"), exist_ok=True)
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/awg0.conf"), "w") as f:
    f.write(OLD20)


def api(*args):
    r = subprocess.run([WRAP, *args], input="", capture_output=True, text=True, env=ENV, timeout=120)
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        res = {"raw": r.stdout + r.stderr}
    return res


def sh(code):
    return bash(EXTRA + code)


def kernels(running, *others, headers=None, built=(), loaded=True):
    """Ядра: работающее и остальные; headers — у каких есть заголовки (по умолчанию у всех)."""
    for d in os.listdir(KM):
        shutil.rmtree(os.path.join(KM, d))
    for sub in ("built", "fail", "repo"):
        for f in os.listdir(os.path.join(KD, sub)):
            os.remove(os.path.join(KD, sub, f))
    for k in (running, *others):
        os.makedirs(os.path.join(KM, k, "build") if headers is None or k in headers else os.path.join(KM, k))
    for k in built:
        open(os.path.join(KD, "built", k), "w").close()
    open(os.path.join(KD, "running"), "w").write(running)
    for f in ("loaded", "busy"):
        p = os.path.join(KD, f)
        if os.path.exists(p):
            os.remove(p)
    if loaded:
        open(os.path.join(KD, "loaded"), "w").close()


def state():
    out = {}
    if os.path.exists(STATE):
        for line in open(STATE):
            k, _, v = line.rstrip("\n").partition("=")
            out[k] = v
    return out


def autofix(*args):
    reset_calls()
    rc, out, err = sh("mod_autofix " + " ".join(args) + '; echo "rc=$?"')
    return out + err


def comp():
    return (api("status").get("data") or {}).get("components") or {}


print("── Автосборка модуля под новые ядра ──")
kernels(K100, K90, built=(K90, K100))
out = autofix()
chk("все ядра с модулем — ничего не собирается", "rc=0" in out and "dkms" not in calls() and not state(), out)
rc, out, _ = sh('MOD_SRC_DIR=/nonexistent; mod_autofix; echo "rc=$?"')
chk("модуль ставила не Тулза (нет исходников в DKMS) — автосборка молчит", "rc=0" in out and "dkms" not in calls(), out)

kernels(K100, K110, built=(K100,))
c = comp()
chk("новое ядро без модуля: в сводке — ядро, «готово к перезагрузке» — пусто",
    c.get("kernel_gap") == K110 and c.get("kernel_new") == "" and c.get("kernel_fix") == "", c)
out = autofix()
st = state()
chk("новое ядро (заголовки есть) — модуль собран только под него, итог «ok»",
    "rc=0" in out and f"dkms install -m amneziawg -v 1.0.0 -k {K110} --force" in calls()
    and f"-k {K100}" not in calls() and st.get("RESULT") == "ok" and st.get("BUILT") == K110
    and "собран под ядро" in out, [out, calls(), st])
c = comp()
chk("после сборки: ядра без модуля нет, новое ядро готово — нужна перезагрузка",
    c.get("kernel_gap") == "" and c.get("kernel_new") == K110 and c.get("kernel_fix") == "", c)
chk("сервер сам не перезагружается, ремонт не нужен", "reboot" not in calls() and "do_repair" not in calls(), calls())

kernels(K100, K110, headers=(K100,), built=(K100,))
open(os.path.join(KD, "repo", K110), "w").close()
out = autofix()
chk("нет заголовков, но они есть в репозитории — ставятся, модуль собирается",
    f"apt_install linux-headers-{K110}" in calls() and os.path.exists(os.path.join(KD, "built", K110))
    and state().get("RESULT") == "ok", [out, calls()])

kernels(K100, K110, headers=(K100,), built=(K100,))
out = autofix()
st = state()
chk("заголовков нигде нет — неудача с причиной, сборка не запускается",
    "rc=1" in out and st.get("RESULT") == "fail" and st.get("GAP") == K110 and "заголовки ядра не поставились" in st.get("WHY", "")
    and "dkms install" not in calls(), [out, st, calls()])
c = comp()
chk("сводка: автосборка не справилась — и почему", c.get("kernel_fix") == "fail" and "заголовки" in c.get("kernel_fix_why", ""), c)
out = autofix()
chk("тот же набор ядер — повтор не раньше чем через 6 часов (ни apt, ни dkms)",
    "rc=0" in out and "apt_install" not in calls() and "dkms" not in calls() and "повтор позже" in out, [out, calls()])
out = autofix("force")
chk("force — сразу, без паузы", "apt_install" in calls(), calls())
rc, out, _ = sh(f'_kfix_set "AT=$(( $(date +%s) - 22000 ))"')
out = autofix()
chk("прошло 6 часов — пробует снова", "apt_install" in calls(), calls())
open(os.path.join(KD, "repo", K110), "w").close()
os.makedirs(os.path.join(KM, K120))
open(os.path.join(KD, "repo", K120), "w").close()
out = autofix()
chk("пришло ещё одно ядро (набор сменился) — пробует сразу, оба собраны",
    st.get("RESULT") == "fail" and state().get("RESULT") == "ok" and all(os.path.exists(os.path.join(KD, "built", k)) for k in (K110, K120))
    and comp().get("kernel_new") == K120, [out, state()])

kernels(K100, K110, built=(K100,))
open(os.path.join(KD, "fail", K110), "w").close()
out = autofix()
st = state()
chk("сборка упала — причина: первая ошибка make.log, без каталогов пути",
    "rc=1" in out and st.get("RESULT") == "fail"
    and "сборка не удалась — socket.c:42:5: error: implicit declaration of function udp_tunnel_xmit_skb" in st.get("WHY", "")
    and "/var/lib" not in st.get("WHY", ""), st)
os.remove(os.path.join(KD, "fail", K110))
open(os.path.join(KD, "built", K110), "w").close()
c = comp()
chk("модуль пересобрали руками — «не справилась» в сводке пропадает", c.get("kernel_fix") == "" and c.get("kernel_gap") == "", c)
autofix()
chk("…и следующий проход убирает отметку неудачи", state().get("RESULT") == "", state())

kernels(K100, K110, built=(K100,))
open(os.path.join(KD, "busy"), "w").close()
out = autofix()
chk("идёт установка пакетов (dpkg) — проход пропущен, без ожидания и без отметки неудачи",
    "rc=0" in out and "dkms" not in calls() and "apt_install" not in calls() and state().get("RESULT") != "fail"
    and "при следующей проверке" in out, [out, calls()])
os.remove(os.path.join(KD, "busy"))

kernels(K110, K100, built=(K100,), loaded=False)
out = autofix()
chk("сервер уже загрузился в ядро без модуля — модуль собран, ремонт загрузил его и поднял awg0",
    "rc=0" in out and os.path.exists(os.path.join(KD, "built", K110)) and "do_repair" in calls()
    and "Модуль загружен" in out and "awg0 поднят" in out, [out, calls()])

print("── Таймер и API ──")
reset_calls()
rc, out, _ = sh('kfix_install; echo "rc=$?"; kfix_on && echo ON')
svc = open(os.path.join(UNITS, "awg2-kernel-fix.service")).read()
tmr = open(os.path.join(UNITS, "awg2-kernel-fix.timer")).read()
chk("таймер: раз в 30 минут и через 2 минуты после загрузки, служба — через API с ожиданием замка, с низким приоритетом",
    "rc=0" in out and "ON" in out and "api module autofix" in svc and "API_LOCK_WAIT=600" in svc and "Nice=10" in svc
    and "OnUnitActiveSec=1800" in tmr and "OnBootSec=120" in tmr
    and "systemctl enable --now awg2-kernel-fix.timer" in calls(), [svc, tmr])
os.remove(os.path.join(UNITS, "awg2-kernel-fix.timer"))
rc, out, _ = sh('MOD_SRC_DIR=/nonexistent; rm -f "$KFIX_ON"; kfix_install; kfix_on && echo ON || echo OFF')
chk("без исходников модуля в DKMS таймер не ставится", "OFF" in out and not os.path.exists(os.path.join(UNITS, "awg2-kernel-fix.timer")), out)
rc, out, _ = sh('rm -f "$STATE_DIR/version"; helpers_refresh; kfix_on && echo ON')
chk("обновление Тулзы ставит таймер и тем, у кого модуль стоял раньше", "ON" in out
    and os.path.exists(os.path.join(UNITS, "awg2-kernel-fix.timer")), out)
heal = os.path.join(ROOT, "var/lib/awg2/kernel-fix.heal")
os.utime(heal, (time.time() - 4 * 3600,) * 2)
reset_calls()
sh("kfix_watchdog")
chk("таймер молчит больше трёх часов — сторож перезапускает", "awg2-kernel-fix.timer" in calls(), calls())
kernels(K100, K110, built=(K100,))
r = api("module", "autofix")
c = api("status")["data"]["components"]
chk("api module autofix и сводка: собран, новое ядро готово, автосборка включена",
    r.get("ok") and c.get("kernel_new") == K110 and c.get("kernel_auto") is True and c.get("kernel_fix") == "", [r.get("log"), c])
r = api("module", "report")
chk("module report — те же поля", r.get("ok") and r["data"].get("kernel_new") == K110 and r["data"].get("kernel_auto") is True,
    r.get("data"))
rc, out, _ = sh("components_report")
chk("отчёт модуля: строка «Автосборка — включена»", "Автосборка" in out and "включена" in out, out)
rc, out, _ = sh("kfix_remove; kfix_on && echo ON || echo OFF")
chk("удаление Тулзы снимает таймер и отметки", "OFF" in out and not os.path.exists(STATE), out)

summary()
