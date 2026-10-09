"""panel_stand.py — сервер панели Mini App на песочнице awg2 для прогона в браузере.

Запускает test_panel.py: печатает «READY порт initData ошибка корень» и работает, пока его
не остановят. PROFILE=lite|pro — профиль сервера (от него зависят экраны),
none — сервера ещё нет (мастер создания); AWG2_SH — сборка awg2 (по
умолчанию dist/awg2.sh). Telegram здесь нет: сессия бота только печатает
вызовы.
"""
import asyncio
import hashlib
import hmac
import json
import os
import socket
import subprocess
import sys
import time
from urllib.parse import urlencode

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.argv = ["panel_stand", os.environ.get("AWG2_SH") or os.path.join(HERE, "..", "dist", "awg2.sh")]
from sandbox import *  # noqa: E402,F401,F403

TOKEN = "123456:" + "A" * 35
API = api_wrapper()
fake_acme()

# Канал обновлений «отвечает»: в нём v9.9.9 (проверка — первые 4 КБ файла)
with open(os.path.join(BIN, "curl"), "w") as f:
    f.write('#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == *http_code* ]] && { echo 204; exit 0; }\n'
            '  [[ "$a" == 0-4095 ]] && { echo \'VERSION="v9.9.9"\'; exit 0; }\n'
            # CHANGELOG.md канала — для экрана «Обновление»
            '  [[ "$a" == *CHANGELOG.md* ]] && { printf \'# Изменения\\n\\n## v9.9.9 — 2027-01-01\\n\\n'
            '- **Новое**: тестовая `сборка`\\n  со второй строкой\\n\\n---\\n\\n## v1.1.1 — 2026-10-01\\n\\n- прежнее\\n\'; exit 0; }\n'
            'done\nexit 1\n')
# wg умеет ключи (клиенты WG + обфускатор), wg-quick — strip
with open(os.path.join(BIN, "wg"), "w") as f:
    f.write('#!/usr/bin/env bash\necho "wg $*" >> "$CALLS"\ncase "$1" in\n'
            '  genkey|genpsk) head -c 32 /dev/urandom | base64 ;;\n  pubkey) sha256sum | head -c 43; echo "=" ;;\n'
            # Рукопожатие «-30» — 30 с назад от момента вызова: клиент в сети, сколько бы ни шёл сценарий
            '  show) [[ -f "$WG_DUMP" ]] || exit 0\n'
            '        dump() { awk -v now="$(date +%s)" \'BEGIN {FS = OFS = "\\t"} NR > 1 && $5 ~ /^-[0-9]+$/ {$5 = now + $5} {print}\' "$WG_DUMP"; }\n'
            '        [[ "${3:-}" == dump ]] && dump\n'
            '        [[ "${3:-}" == transfer ]] && dump | awk -F\'\\t\' \'NR > 1 {print $1 "\\t" $6 "\\t" $7}\' ;;\nesac\nexit 0\n')
with open(os.path.join(BIN, "wg-quick"), "w") as f:
    f.write('#!/usr/bin/env bash\necho "wg-quick $*" >> "$CALLS"\n[[ "$1" == strip ]] && printf "[Interface]\\nPrivateKey = x\\n"\nexit 0\n')
for tool in ("wg", "wg-quick"):
    os.chmod(os.path.join(BIN, tool), 0o755)
# Модуль ядра «собран» — иначе awg2 не создаст сервер
for tool in ("modinfo", "modprobe"):
    with open(os.path.join(BIN, tool), "w") as f:
        f.write(f'#!/bin/bash\necho "{tool} $*" >> "$CALLS"; exit 0\n')
    os.chmod(os.path.join(BIN, tool), 0o755)

PROFILE = os.environ.get("PROFILE", "pro")
STATE = os.path.join(TMP, "botstate")
os.makedirs(STATE)
AWG_DIR = os.path.join(ROOT, "etc/amnezia/amneziawg")
os.makedirs(AWG_DIR, exist_ok=True)
os.makedirs(os.path.join(ROOT, "root"), exist_ok=True)
if PROFILE != "none":
    # Сервер AWG с двумя клиентами: alice онлайн, bob был два часа назад
    with open(os.path.join(AWG_DIR, "awg0.conf"), "w") as f:
        f.write(OLD20.replace("AWG_PROFILE=pro", "AWG_PROFILE=" + PROFILE))
    for n in ("alice", "bob"):
        with open(os.path.join(ROOT, "root", n + "_awg2.conf"), "w") as f:
            f.write("[Interface]\nPrivateKey = X\nAddress = 10.23.45.2/32\n")
    now = int(time.time())
    with open(AWG_DUMP, "w") as f:
        f.write(f"PRIV\tPUB\t51820\toff\n"
                f"PUBALICE=\t(none)\t5.6.7.8:4242\t10.23.45.2/32\t{now - 20}\t12345678\t987654\toff\n"
                f"PUBBOB=\t(none)\t(none)\t10.23.45.3/32\t{now - 7200}\t1024\t2048\toff\n")
    # Трафик за две недели: alice — каждый день, bob — через день
    db = {"v": 1, "saved": now, "ifindex": "", "last": {"PUBALICE=": [12345678, 987654], "PUBBOB=": [1024, 2048]},
          "total": {}, "reset": {}, "warned": {}, "days": {}}
    for i in range(14):
        day = time.strftime("%Y-%m-%d", time.localtime(now - 86400 * i))
        db["days"][day] = {"PUBALICE=": [(i % 5 + 1) * 300 * 2**20, (i % 3 + 1) * 40 * 2**20]}
        if i % 2:
            db["days"][day]["PUBBOB="] = [50 * 2**20, 10 * 2**20]
    os.makedirs(os.path.join(ROOT, "var/lib/awg2"), exist_ok=True)
    with open(os.path.join(ROOT, "var/lib/awg2/traffic.json"), "w") as f:
        json.dump(db, f)
    # Страна сервера уже известна (Cloudflare trace) — в шапке флаг Нидерландов
    with open(os.path.join(ROOT, "var/lib/awg2/country"), "w") as f:
        f.write(f"NL {now}\n")
    # Работают exit-ноды: нода n1 поднята, маршруты — «все клиенты»
    with open(os.path.join(AWG_DIR, "awg-exit-n1.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = X\nTable = off\n\n[Peer]\nEndpoint = 1.2.3.4:51820\n")
    with open(os.path.join(AWG_DIR, "exits_state"), "w") as f:
        f.write("active\nmode=all\nbalancer=single\nsingle_exit=n1\n")
    with open(LINKS, "w") as f:
        f.write("awg-exit-n1\n")
    with open(ACTIVE, "w") as f:
        f.write("awg-exits-routing.service\n")
    # Работает WG + обфускатор (STUN, чистый WG разрешён), клиентов пока нет
    os.makedirs(os.path.join(ROOT, "etc/awg-wgobf"), exist_ok=True)
    with open(os.path.join(ROOT, "etc/awg-wgobf/state"), "w") as f:
        f.write("PORT=41000\nENDPOINT=203.0.113.10\nMASKING=STUN\nALLOW_CLEAN=1\nNET=10.66.66.0/24\nKEY=s3cretObfKey\n"
                "SERVER_PUB=SRVPUBKEYxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=\nWG_PORT=51900\nMTU=1380\nDNS=1.1.1.1, 1.0.0.1\n")
    os.makedirs(os.path.join(ROOT, "etc/wireguard"), exist_ok=True)
    # Клиент обфускатора ob1 — в сети: на обзоре своя схема wgobf0 → напрямую
    with open(os.path.join(ROOT, "etc/wireguard/wgobf0.conf"), "w") as f:
        f.write("[Interface]\nPrivateKey = X\nAddress = 10.66.66.1/24\nListenPort = 51900\n\n"
                "[Peer]\n# client=ob1\nPublicKey = OBPUB=\nAllowedIPs = 10.66.66.2/32\n")
    with open(WG_DUMP, "w") as f:
        f.write(f"SRVPRIV=\tSRVPUB=\t51900\toff\nOBPUB=\t(none)\t127.0.0.1:40000\t10.66.66.2/32\t-30"
                f"\t3145728\t1048576\t25\n")
    with open(ACTIVE, "a") as f:
        f.write("awg-wgobf.service\n")
    with open(LINKS, "a") as f:
        f.write("wgobf0\n")

with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
with open(os.path.join(ROOT, "bot.conf"), "w") as f:
    f.write(f"BOT_TOKEN={TOKEN}\nADMIN_ID=111\nWEBAPP_PORT={PORT}\n")
os.environ.update(ENV)
os.environ.update(AWG2_BIN=API, AWG_BOT_STATE=STATE, AWG_ADMINS_FILE=os.path.join(STATE, "admins.json"),
                  AWG_BOT_CONF=os.path.join(ROOT, "bot.conf"),
                  AWG_CERT_FULL=os.path.join(ROOT, "etc/awg2/cert/fullchain.pem"),
                  AWG_CERT_KEY=os.path.join(ROOT, "etc/awg2/cert/key.pem"))

sys.path.insert(0, os.path.join(HERE, "..", "awg_bot"))
from aiogram import Bot  # noqa: E402
from aiogram.client.session.base import BaseSession  # noqa: E402

from datetime import datetime  # noqa: E402

from aiogram.types import Chat, Message, MessageEntity, Sticker, StickerSet, User  # noqa: E402

from awgbot import access, admins, icons, store, webapp  # noqa: E402
from awgbot.config import load_config  # noqa: E402

async def keep_handshakes():
    """Клиенты «в сети» — пока рукопожатие моложе 3 минут. Под нагрузкой тест доходит
    до шагов про «в сети» позже — рукопожатия держатся свежими, как на живом сервере."""
    ages = {"PUBALICE=": 20, "PUBBOB=": 7200, "OBPUB=": 30}
    while True:
        await asyncio.sleep(20)
        now = int(time.time())
        for path in (AWG_DUMP, WG_DUMP):
            try:
                with open(path) as f:
                    rows = [ln.split("\t") for ln in f.read().split("\n")]
            except OSError:
                continue
            for r in rows:
                if len(r) > 4 and r[0] in ages:
                    r[4] = str(now - ages[r[0]])
            with open(path + ".new", "w") as f:
                f.write("\n".join("\t".join(r) for r in rows))
            os.replace(path + ".new", path)


class Session(BaseSession):
    async def make_request(self, bot, method, timeout=None):
        name = type(method).__name__
        print("TG", name, getattr(method, "chat_id", ""), flush=True)
        if name == "GetMe":                          # ссылка-приглашение
            return User(id=123456, is_bot=True, first_name="Toolza", username="toolza_test_bot")
        if name == "GetStickerSet":                  # набор иконок: по иконке на эмодзи бота
            return StickerSet(name=method.name, title="Icons", sticker_type="custom_emoji", stickers=[
                Sticker(file_id=f"f{i}", file_unique_id=f"u{i}", type="custom_emoji", width=100, height=100,
                        is_animated=False, is_video=False, emoji=e, custom_emoji_id=str(5000 + i))
                for i, e in enumerate(icons.TEMPLATE)])
        if name == "SendMessage":                    # как Telegram: сообщение; иконки в тексте — сущности
            entities = ([MessageEntity(type="custom_emoji", offset=0, length=1, custom_emoji_id="5000")]
                        if "<tg-emoji" in (method.text or "") else None)
            return Message(message_id=int(time.time() * 1000) % 10**9, date=datetime.now(),
                           chat=Chat(id=int(method.chat_id), type="private"), text="…", entities=entities)
        return True

    async def stream_content(self, *args, **kwargs):
        raise NotImplementedError
        yield b""                                               # pragma: no cover

    async def close(self):
        pass


def init_data(uid):
    fields = {"auth_date": str(int(time.time())), "query_id": "AAH",
              "user": json.dumps({"id": uid, "first_name": "Ivan"}, separators=(",", ":"))}
    secret = hmac.new(b"WebAppData", TOKEN.encode(), hashlib.sha256).digest()
    check = "\n".join(f"{k}={v}" for k, v in sorted(fields.items()))
    fields["hash"] = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    return urlencode(fields)


async def main():
    access.setup(load_config())
    subprocess.run([API, "api", "cert", "issue", "ip"], capture_output=True)
    if PROFILE != "none":
        store.set_note("alice", "телефон Анны")
        admins.add(333, 111, "helper")
    await webapp.SERVER.start(Bot(TOKEN, session=Session()))
    print("READY", PORT, init_data(111), webapp.SERVER.error or "-", ROOT, flush=True)
    await keep_handshakes()


asyncio.run(main())
