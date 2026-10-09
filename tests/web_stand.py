"""web_stand.py — веб-панель (awgbot.web) на песочнице awg2 для прогона в браузере и тестов.

Сервер, клиенты и туннели — как у panel_stand.py (PROFILE=lite|pro). Печатает
«READY порт путь логин пароль корень» и работает, пока его не остановят.
WEB_BOT=1 — как будто Telegram-бот установлен (раздел «Бот» в панели).
Сертификат — самоподписанный, свой (сертификата Тулзы на стенде нет).
"""
# ruff: noqa: F821 — TMP, ROOT, PROFILE и песочница приходят из exec(panel_stand)
import asyncio
import os
import socket

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "panel_stand.py"), encoding="utf-8").read()
src = src.replace("HERE = os.path.dirname(os.path.abspath(__file__))", f"HERE = {HERE!r}")
exec(compile(src[:src.index("class Session(BaseSession):")], "panel_stand", "exec"))
# Без Telegram-бота: конфиг бота пуст — как на сервере, где стоит только веб-панель
import awgbot.config  # noqa: E402
awgbot.config.CONF_PATH = os.path.join(TMP, "no-bot.conf")

USER, PASSWORD = "admin", "Test-password-42"
WEB = os.path.join(TMP, "web")
os.makedirs(WEB)
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    WPORT = s.getsockname()[1]
unit = os.path.join(TMP, "awg-bot.service")
if os.environ.get("WEB_BOT"):
    open(unit, "w").close()
os.environ.update(AWG_WEB_CONF=os.path.join(WEB, "awg-web.conf"), AWG_WEB_LOG=os.path.join(WEB, "awg-web.log"),
                  AWG_WEB_DIR=os.path.join(WEB, "self"), AWG_BOT_UNIT=unit,
                  AWG_BOT_CONF=os.path.join(WEB, "no-bot.conf"),       # без бота — без уведомлений в Telegram
                  AWG_CERT_FULL=os.path.join(WEB, "none.pem"), AWG_CERT_KEY=os.path.join(WEB, "none.key"))

from awgbot import store, web  # noqa: E402

with open(os.environ["AWG_WEB_CONF"], "w") as f:
    f.write(f"WEB_PORT={WPORT}\nWEB_PATH=s3cr3tPath\nWEB_USER={USER}\nWEB_PASS={web.hash_password(PASSWORD)}\n"
            "WEB_LISTEN=127.0.0.1\n")
os.chmod(os.environ["AWG_WEB_CONF"], 0o600)
web.CONF = __import__("pathlib").Path(os.environ["AWG_WEB_CONF"])
web.LOG_FILE = __import__("pathlib").Path(os.environ["AWG_WEB_LOG"])
web.SELF_DIR = __import__("pathlib").Path(os.environ["AWG_WEB_DIR"])
web.CERT_FULL = __import__("pathlib").Path(os.environ["AWG_CERT_FULL"])
web.CERT_KEY = __import__("pathlib").Path(os.environ["AWG_CERT_KEY"])


async def main():
    if PROFILE != "none":
        store.set_note("alice", "ноутбук")
    srv = web.WebPanel()
    runner = web.web.AppRunner(srv.build(), access_log=None)
    await runner.setup()
    await web.web.TCPSite(runner, "127.0.0.1", WPORT, ssl_context=srv.tls()).start()
    print("READY", WPORT, srv.base, USER, PASSWORD, ROOT, flush=True)
    await keep_handshakes()


asyncio.run(main())
