#!/usr/bin/env python3
"""run_all.py — все наборы тестов разом, параллельно.

Наборы независимы: у каждого своя песочница во временном каталоге, свои
порты и браузер. Самые долгие стартуют первыми; браузерные (панель и
веб-панель) — по одному, чтобы не отнимать друг у друга процессор и не
ловить таймауты ожиданий.

Запуск:  python3 tests/run_all.py [путь/к/awg2.sh] [-j N] [--only a,b] [--skip a,b]
         без пути — dist/awg2.sh; -j — сколько наборов разом (по умолчанию —
         число ядер); имена — без «test_» (toolza, bot, panel…)
Итог — строка на набор со временем; у упавшего — его строки FAIL и хвост журнала.
"""
import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# По убыванию длительности: долгие — первыми, короткие заполняют промежутки
# (веб-панель — в конце: ей всё равно ждать, пока браузер занят панелью)
SUITES = ["panel", "toolza", "bot", "regress_f2f3", "kernel_routing", "amnezia", "share_persistence",
          "meta_menu", "cps", "deep_robustness", "api_lock", "net", "admins", "web"]
BROWSER = {"panel", "web"}

ap = argparse.ArgumentParser(description="Все тесты параллельно")
ap.add_argument("awg2", nargs="?", default=os.path.join(HERE, "..", "dist", "awg2.sh"))
ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 2)
ap.add_argument("--only", default="")
ap.add_argument("--skip", default="")
ap.add_argument("--timeout", type=int, default=1500)
opt = ap.parse_args()

names = [s.strip().removeprefix("test_") for s in opt.only.split(",") if s.strip()] or SUITES
skip = {s.strip().removeprefix("test_") for s in opt.skip.split(",") if s.strip()}
unknown = [n for n in names if n not in SUITES]
if unknown:
    sys.exit(f"нет таких наборов: {', '.join(unknown)} (есть: {', '.join(SUITES)})")
names = [n for n in SUITES if n in names and n not in skip]
awg2 = os.path.abspath(opt.awg2)
if not os.path.isfile(awg2):
    sys.exit(f"нет {awg2} — собери: ./build.sh")

logdir = tempfile.mkdtemp(prefix="awg2-tests.")
browser = threading.Semaphore(1)
lock = threading.Lock()
start = time.time()


# Набор (или его часть) пропущен целиком — нет зависимостей; это видно в итоге
SKIPS = ("ПРОПУСК", "тест бота пропущен", "Панель в браузере пропущена", "Веб-панель пропущена", "Браузер пропущен")


def summary(text):
    lines = [ln.strip() for ln in text.splitlines() if re.match(r"(проверок:|провалов:|Ran \d+|OK$|FAILED)", ln.strip())]
    skipped = [ln.strip() for ln in text.splitlines() if any(k in ln for k in SKIPS)]
    return " · ".join(lines[-2:] + ["ПРОПУЩЕНО: " + skipped[0][:80]] if skipped else lines[-2:])


def run(name):
    def go():
        t = time.time()
        log = os.path.join(logdir, name + ".log")
        try:
            with open(log, "w") as f:
                rc = subprocess.run([sys.executable, os.path.join(HERE, f"test_{name}.py"), awg2], stdout=f,
                                    stderr=subprocess.STDOUT, timeout=opt.timeout).returncode
        except subprocess.TimeoutExpired:
            rc = "таймаут"
        return rc, time.time() - t, log
    if name in BROWSER:
        with browser:
            rc, took, log = go()
    else:
        rc, took, log = go()
    text = open(log, errors="replace").read()
    with lock:
        mark = "OK  " if rc == 0 else "FAIL"
        print(f"{mark} {name:<18} {took:6.0f} с  {summary(text)}", flush=True)
        if rc != 0:
            fails = [ln for ln in text.splitlines() if "FAIL" in ln][:15]
            print("\n".join("     " + ln.strip() for ln in fails) or text[-1500:], flush=True)
            print(f"     журнал: {log}", flush=True)
            if os.environ.get("GITHUB_ACTIONS"):
                print(f"::group::{name} — журнал целиком\n{text}\n::endgroup::", flush=True)
    return rc == 0


print(f"{len(names)} наборов, по {opt.jobs} разом, {os.path.relpath(awg2)}", flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, opt.jobs)) as pool:
    ok = list(pool.map(run, names))
bad = len(ok) - sum(ok)
print(f"\nвсего {time.time() - start:.0f} с, наборов: {len(ok)}, упало: {bad}" + ("" if bad else f"  (журналы: {logdir})"))
sys.exit(1 if bad else 0)
