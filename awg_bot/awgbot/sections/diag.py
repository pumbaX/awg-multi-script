"""Диагностика: сводка, домены мимикрии, тест мимикрии, DPI у клиента,
журналы служб."""

from __future__ import annotations

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import access, api, ask, jobs, ui
from ..ui import esc
from .clients import NAME_RE

router = Router()
act = ui.Actions(router, "diag")

LOGS = [
    ("manager", "awg2 — действия"), ("install", "Компоненты"), ("module", "Сборка модуля"),
    ("awg", "awg0 (awg-quick)"), ("expire", "Сроки клиентов"), ("warp", "WARP"),
    ("warp-health", "WARP health-check"), ("xray", "Xray"), ("xray-routing", "Маршруты Xray"),
    ("tun2socks", "tun2socks"), ("exits", "Exit-ноды"), ("cascade", "Каскад"),
    ("dns", "dnscrypt-proxy"), ("dns-health", "DNS health-check"), ("wgobf", "WG + обфускатор"),
    ("bot", "Telegram-бот"), ("web", "Веб-панель"), ("antiscan", "Антисканер"),
    ("vkblock", "VK и Max мимо VPN"), ("rudirect", "РФ напрямую"), ("tunfail", "Если туннель упал"),
]
# Журнал входов веб-панели (адреса, введённые логины) — как и сам раздел «Веб-панель»
OWNER_LOGS = {"web"}

DPI_HINT = (
    "<b>🔍 DPI со стороны клиента</b>\n\n"
    "Запускать на устройстве клиента, не на сервере:\n"
    "<code>docker run --rm -it --pull=always ghcr.io/runnin4ik/dpi-detector:latest</code>\n"
    "или Python: <code>git clone https://github.com/Runnin4ik/dpi-detector.git</code>, "
    "затем <code>pip install -r requirements.txt</code> и <code>python dpi_detector.py</code>. "
    "Для Windows и macOS — готовые сборки в Releases.\n\n"
    "<b>Что делать с результатом</b>\n"
    "• рабочий у провайдера клиента домен → домен мимикрии (карточка клиента → Мимикрия)\n"
    "• подмена DNS / перехват UDP 53 → Туннели → Шифрованный DNS\n"
    "• обрыв после первых КБ → профиль «AmneziaVPN» и короче I1-I5\n\n"
    "<i>Сторонний проект (MIT), awg2 его не ставит.</i>"
)


@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await ui.render(cb, "<b>🩺 Диагностика</b>\n\n"
                        "• Домены — какие домены мимикрии отвечают (мир или Россия)\n"
                        "• Тест мимикрии — захват первых пакетов клиента\n"
                        "• DPI клиента — проверка со стороны клиента\n"
                        "• Куда идёт — через какой туннель клиент ходит на адрес или сайт", ui.kb(
        ("📋 Сводка", act.data("status")),
        ("📜 Журналы", act.data("logs")),
        ("🌍 Домены: мир", act.data("dom", "world")),
        ("🇷🇺 Домены: РФ", act.data("dom", "ru")),
        ("🎯 Тест мимикрии", act.data("sniff")),
        ("🔍 DPI клиента", act.data("dpi")),
        ("🧭 Куда идёт", act.data("rt")),
        ("🧩 Модуль ядра", "mod"),
        ui.back()))


@act("status")
async def _status(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("diag", "status")
    await ui.render(cb, "<b>📋 Сводка</b>\n" + (ui.pre(r.log, 3500, tail=False) if r.ok else ui.fail(r)),
                    ui.kb(("🔄 Обновить", act.data("status")), ui.back("diag")))


@act("dom")
async def _domains(cb: CallbackQuery, state: FSMContext, region: str) -> None:
    await jobs.start(cb, f"Домены мимикрии ({'Россия' if region == 'ru' else 'мир'})",
                     "diag", "domains", region, back_to="diag")


@act("dpi")
async def _dpi(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, DPI_HINT, ui.kb(ui.back("diag")))


@act("sniff")
async def _sniff(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    # Имя не по правилам awg2 (старый бот, правка руками) не влезет в callback_data
    rows = [r for r in (await api.data("diag", "sniff-list", default=[]) or []) if NAME_RE.match(r.get("name") or "")]
    if not rows:
        await ui.render(cb, "Нет клиентов, которые уже подключались. Подключись с устройства и вернись сюда.",
                        ui.kb(("🔄 Обновить", act.data("sniff")), ui.back("diag")))
        return
    # Все клиенты — по страницам: срез первых 40 молча прятал остальных
    page = int(arg) if arg.isdigit() else 0
    await ui.render(cb, "<b>🎯 Тест мимикрии</b>\nСервер 20 секунд слушает первые пакеты клиента и "
                        f"проверяет, видны ли пакеты мимикрии и на что они похожи.\n\nКлиент ({len(rows)}):",
                    ui.kb(ui.paged([(r["name"], act.data("sn", r["name"])) for r in rows], page,
                                   lambda p: act.data("sniff", str(p))), ui.back("diag")))


@act("sn")
async def _sniff_client(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await ui.render(cb, f"<b>🎯 {esc(name)}</b>\n\nНа устройстве клиента: отключись, нажми «Слушать» и "
                        "в течение 20 секунд подключись снова.",
                    ui.kb(("👂 Слушать 20 с", act.data("sngo", name)), ui.back(act.data("sniff"))))


@act("sngo")
async def _sniff_go(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await jobs.start(cb, f"Тест мимикрии: {name}", "diag", "sniff", name, back_to="diag")


@act("logs")
async def _logs(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    owner = access.is_owner(cb.from_user.id)
    await ui.render(cb, "<b>📜 Журналы</b>\nПоследние строки журнала службы.",
                    ui.kb([(label, act.data("log", name)) for name, label in LOGS
                           if owner or name not in OWNER_LOGS], ui.back("diag")))


@act("log")
async def _log(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    # Журнал открывают и из других разделов: «diag:log:имя|куда» — «Назад» туда,
    # откуда пришли (данные колбэка того экрана); без «|куда» — в «Журналы»
    name, _, back_to = arg.partition("|")
    if name in OWNER_LOGS and not access.is_owner(cb.from_user.id):
        await cb.answer("Журнал веб-панели — только владельцу", show_alert=True)
        return
    r = await api.call("log", name, 80)
    label = dict(LOGS).get(name, name)
    body = (ui.pre(r.log, 3600) or "<i>пусто</i>") if r.ok else ui.fail(r)
    await ui.render(cb, f"<b>📜 {esc(label)}</b>\n{body}",
                    ui.kb(("🔄 Обновить", act.data("log", arg)), ui.back(back_to or act.data("logs"))))


# ── Куда идёт адрес ───────────────────────────────────────
# Решение ядра для клиента и адреса: туннель, напрямую, «РФ напрямую»,
# удержан («блокировать»). Откуда пришли — кодом в аргументе (имя клиента до
# 32 букв, данные колбэка до 64 байт): r — «РФ напрямую», t — маршрут клиента.
ROUTE_KIND = {"warp": "🟢", "xray": "🟢", "t2s": "🟢", "exit": "🟢", "direct": "⚪️", "rudirect": "🇷🇺",
              "held": "🔴", "drop": "🚫", "blocked": "⛔️", "none": "⚠️"}


def _route_back(code: str, name: str = "") -> str:
    return {"r": "rud", "t": f"cl:tun:{name}" if name else "diag"}.get(code, "diag")


@act("rt")
async def _route(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    code, _, page = arg.partition("|")
    rows = [c for c in (await api.data("clients", "list", default=[]) or [])
            if isinstance(c, dict) and NAME_RE.match(c.get("name") or "")]
    back_to = "rud" if code == "r" else "diag"
    if not rows:
        await ui.render(cb, "Клиентов нет.", ui.kb(ui.back(back_to)))
        return
    p = int(page) if page.isdigit() else 0
    await ui.render(cb, "<b>🧭 Куда идёт адрес</b>\nЧерез какой туннель клиент ходит на адрес или сайт: "
                        "решение самого ядра — с «РФ напрямую», удержанием упавшего туннеля и «VK и Max».\n\n"
                        f"Клиент ({len(rows)}):",
                    ui.kb(ui.paged([(c["name"], act.data("rtc", f"{c['name']}|{code}")) for c in rows], p,
                                   lambda n: act.data("rt", f"{code}|{n}")), ui.back(back_to)))


@act("rtc")
async def _route_client(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    name, _, code = arg.partition("|")
    await ask.ask(cb, state, "diag_route", f"<b>🧭 {esc(name)}</b>\nАдрес, домен или ссылка: "
                                           "<code>1.1.1.1</code>, <code>ya.ru</code>, <code>https://bank.ru/login</code>",
                  act.data("rt", code) if code != "t" else _route_back(code, name), name=name, code=code)


@ask.on("diag_route")
async def _route_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    text, name, code = ask.text_of(msg), ctx.get("name", ""), ctx.get("code", "")
    if not text or len(text) > 300 or any(c.isspace() for c in text):
        await ask.retry(msg, state, ctx, "Нужен один адрес, домен или ссылка")
        return
    r = await api.call("diag", "route", name, text)
    if not r.ok or not isinstance(r.data, dict):
        await ask.retry(msg, state, ctx, r.message or "Не удалось проверить")
        return
    await ui.render(msg, route_text(r.data), ui.kb(
        ("🔄 Другой адрес", act.data("rtc", f"{name}|{code}")), ui.back(_route_back(code, name))))


def route_text(d: dict) -> str:
    rows = [x for x in d.get("rows") or [] if isinstance(x, dict)]
    lines = ["<b>🧭 Куда идёт адрес</b>",
             f"Клиент <b>{esc(d.get('client', ''))}</b>" + (f" ({esc(d['ip'])})" if d.get("ip") else "")
             + f" → <code>{esc(d.get('input', ''))}</code>", ""]
    lines += [f"{ROUTE_KIND.get(x.get('kind', ''), '▫️')} <code>{esc(x.get('ip', ''))}</code> — {esc(x.get('note', ''))}"
              for x in rows]
    kinds = {x.get("kind") for x in rows}
    hints = []
    if "held" in kinds:
        hints.append("Вернуть интернет: поднять туннель или «Туннели → 🪂 Если упал → Напрямую».")
    tg = [x for x in rows if x.get("kind") == "rudirect" and "Telegram" in (x.get("note") or "")]
    if len(tg) < sum(1 for x in rows if x.get("kind") == "rudirect"):
        hints.append("Пустить адрес через туннель: «Туннели → 🇷🇺 РФ напрямую → В туннель».")
    if tg:
        hints.append("Telegram через туннель: «Туннели → 🇷🇺 РФ напрямую → ✈️ TG в туннель».")
    if "direct" in kinds and any("не в туннеле" in (x.get("note") or "") for x in rows):
        hints.append("Пустить клиента в туннель: карточка клиента → Маршрут.")
    if "blocked" in kinds:
        hints.append("Клиент заблокирован: срок или лимит трафика — карточка клиента.")
    if hints:
        lines += [""] + [f"<i>{h}</i>" for h in hints]
    return "\n".join(lines)
