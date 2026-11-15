#!/usr/bin/env python3
"""test_panel.py — панель Mini App в настоящем браузере (Chromium через Playwright).

Поднимает panel_stand.py (сервер панели на песочнице awg2) с профилями
сервера lite и pro и без сервера и гоняет panel_drive.js: клиенты, сервер,
туннели, диагностика, бэкапы, обновление, мастер создания сервера, ошибки в
консоли, текст «null» на экранах. Нет node, Playwright или
Chromium — тест пропускается.

Запуск:  python3 tests/test_panel.py [путь/к/dist/awg2.sh]
         (python с aiogram; AWG_PANEL_SHOTS=каталог — оставить скриншоты)
"""
import concurrent.futures
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
fails = checks = 0


def chk(label, cond, detail=""):
    global fails, checks
    checks += 1
    if cond:
        print(f"  OK   {label}")
    else:
        fails += 1
        print(f"  FAIL {label}" + (f"\n       {detail}" if detail else ""))


def skip(why):
    print(f"Панель в браузере пропущена: {why}")
    sys.exit(0)


node = shutil.which("node") or skip("нет node")
npm = shutil.which("npm") or skip("нет npm")
env = dict(os.environ)
env["NODE_PATH"] = subprocess.run([npm, "root", "-g"], capture_output=True, text=True).stdout.strip()
if subprocess.run([node, "-e", "require('playwright')"], env=env, capture_output=True).returncode:
    skip("нет Playwright для node (npm i -g playwright)")
try:
    import aiogram  # noqa: F401
except ImportError:
    skip("нет aiogram (pip install -r awg_bot/requirements.txt)")
if len(sys.argv) > 1:
    env["AWG2_SH"] = os.path.abspath(sys.argv[1])

keep = os.environ.get("AWG_PANEL_SHOTS")
# Кэш вызовов awg2 у стенда — 1 с, а не 5: сценарий ждёт его, когда меняет файлы мимо awg2
env.setdefault("AWG_API_CACHE_TTL", "1")
THEMES = {"lite": "light", "pro": "dark", "none": "light"}      # обе темы Telegram


def run_profile(profile):
    """Стенд и сценарий одного профиля; итог — строки для отчёта (печать — по порядку)."""
    rows = []
    out = os.path.join(keep, profile) if keep else tempfile.mkdtemp(prefix="panel-shots.")
    os.makedirs(out, exist_ok=True)
    stand = subprocess.Popen([sys.executable, os.path.join(HERE, "panel_stand.py")], env=dict(env, PROFILE=profile),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        ready = ""
        for line in stand.stdout:
            if line.startswith("READY"):
                ready = line.split()
                break
        if not ready:
            rows.append(("стенд панели поднялся", False, stand.stdout.read()[-800:] if stand.stdout else ""))
            return rows
        _, port, init, err, root = ready[:5]
        rows.append(("стенд панели поднялся", err == "-", err))
        try:
            run = subprocess.run([node, os.path.join(HERE, "panel_drive.js"), port, init, out, THEMES[profile], profile, root],
                                 env=env, capture_output=True, text=True, timeout=900)
            output = run.stdout + run.stderr
        except subprocess.TimeoutExpired:
            output = "сценарий не уложился в 900 с"
        log = os.path.join(out, "run.log")
        lines = open(log).read().splitlines() if os.path.exists(log) else []
        rows.append(("сценарий браузера отработал", bool(lines), output[-800:]))
        # Итог (ERRORS) сценарий пишет последним: нет его — оборвался на полпути
        rows.append(("сценарий дошёл до конца", any(ln.startswith("ERRORS") for ln in lines), output[-800:]))
        for line in lines:
            if line.startswith(("OK", "FAIL")):
                status, _, rest = line.partition(" ")
                rows.append((rest.strip(), status == "OK", rest))
            elif line.startswith("ALERTS"):
                rows.append(("без неожиданных окон с ошибкой", line.strip() == "ALERTS []", line[:600]))
            elif line.startswith("ERRORS"):
                rows.append(("без ошибок в консоли страницы", line.strip() == "ERRORS []", line[:600]))
        return rows
    finally:
        stand.terminate()
        stand.wait(timeout=20)
        if not keep:
            shutil.rmtree(out, ignore_errors=True)


# Профили независимы (свои песочница, порт и браузер) — идут разом;
# AWG_PANEL_JOBS=1 — по одному, как раньше
PROFILES = ("lite", "pro", "none")
jobs = max(1, int(os.environ.get("AWG_PANEL_JOBS") or len(PROFILES)))
with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    results = list(pool.map(run_profile, PROFILES))
for profile, rows in zip(PROFILES, results):
    print(f"Профиль сервера: {profile}, тема {THEMES[profile]}")
    for label, ok, detail in rows:
        chk(label, ok, detail)

print(f"\nпроверок: {checks}, провалов: {fails}")
sys.exit(1 if fails else 0)
