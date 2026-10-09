"""Сервер: компоненты, создание, протокол 2.0/3.1, модуль ядра, ремонт,
endpoint, сброс и перезагрузка — пункты меню «Сервер» awg2."""

from __future__ import annotations

import re

from aiogram import Bot, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import api, ask, jobs, ui
from ..ui import esc
from . import clients

router = Router()
act = ui.Actions(router, "srv")
mod = ui.Actions(router, "mod")

PROFILE = {"lite": "AmneziaVPN", "pro": "Мощный", "standard": "Standard"}
DNS = [("Cloudflare", "1.1.1.1, 1.0.0.1"), ("Google", "8.8.8.8, 8.8.4.4"),
       ("Quad9", "9.9.9.9, 149.112.112.112"), ("Яндекс", "77.88.8.8, 77.88.8.1")]
DOMAIN_RE = re.compile(r"^(?=.{4,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")


# ── Экран раздела ─────────────────────────────────────────
@act()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await screen(cb)


async def screen(target: ui.Target) -> None:
    r = await api.call("server", "info")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, "Сервер"), ui.kb(ui.back()))
        return
    d = r.data
    lines = ["<b>🖥 Сервер</b>", ""]
    lines.append("Компоненты: " + ("✅ установлены" if d.get("installed") else "❌ не установлены"))
    if d.get("exists"):
        lines += [
            f"awg0: {'🟢 поднят' if d.get('up') else '🔴 не поднят'}",
            f"AWG {esc(d.get('proto', '?'))} · {esc(PROFILE.get(d.get('profile', ''), d.get('profile', '')))}"
            f" · MTU {d.get('mtu')}",
            f"Endpoint: <code>{esc(d.get('endpoint', ''))}</code>",
            f"Подсеть: <code>{esc(d.get('net', ''))}</code> · регион {esc(d.get('region', ''))}",
            f"Мимикрия: {esc(d['mimicry']) if d.get('mimicry') not in (None, '', 'none') else 'без I1-I5'}"
            + (f" ({esc(d['mimicry_domain'])})" if d.get("mimicry_domain") else ""),
            f"Клиентов: {d.get('clients', 0)}",
        ]
    else:
        lines.append("Сервер: не создан")
    if d.get("reboot"):
        lines.append(f"\n▲ {esc(d['reboot'])}")
    hint = r.log.strip()
    if hint:
        lines.append(f"\n<i>{esc(hint)}</i>")
    exists = bool(d.get("exists"))
    await ui.render(target, "\n".join(lines), ui.kb(
        ("📦 Компоненты", act.data("install")),
        ("🧩 Модуль ядра", mod.data()),
        ("✨ Создать сервер", act.data("create")) if not exists else None,
        ("🔄 Рестарт awg0", act.data("restart")) if exists else None,
        ("🔀 Протокол", act.data("proto")) if exists else None,
        ("🎛 Параметры AWG", act.data("par")) if exists else None,
        ("🌍 Endpoint", act.data("ep")) if exists else None,
        ("🛠 Починить", act.data("repair")),
        ("🛡 Антисканер", "as"),
        ("♻️ Перезагрузка", act.data("reboot")),
        ("⚠️ Сбросить", act.data("reset")) if exists else None,
        ui.back()))


@act("install")
async def _install(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "<b>📦 Установка компонентов</b>\n\nПакеты, заголовки ядра, сборка модуля AmneziaWG "
                         "и amneziawg-tools из исходников. Обычно 5-15 минут. Если ядру нет заголовков, "
                         "поставится свежее ядро — тогда понадобится перезагрузка.",
                     ("✅ Установить", act.data("installok")), "srv")


@act("installok")
async def _install_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Установка компонентов", "server", "install", back_to="srv",
                     ok_buttons=[("✨ Создать сервер", act.data("create"))])


@act("restart")
async def _restart(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Перезапускаю awg0…")
    await ui.result(cb, await api.call("server", "restart"), "Перезапуск awg0", "srv")


@act("repair")
async def _repair(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Проверка и ремонт", "server", "repair", back_to="srv")


@act("reset")
async def _reset(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "<b>⚠️ Сброс сервера</b>\n\nawg0 и все клиенты будут удалены, туннели выключены. "
                         "Перед сбросом делается авто-бэкап. Компоненты остаются.",
                     ("⚠️ Да, сбросить", act.data("resetok")), "srv")


@act("resetok")
async def _reset_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.result(cb, await api.call("server", "reset"), "Сброс сервера", "srv")


@act("reboot")
async def _reboot(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Перезагрузить сервер? Бот вернётся сам через минуту-две.",
                     ("♻️ Перезагрузить", act.data("rebootok")), "srv")


@act("rebootok")
async def _reboot_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.result(cb, await api.call("server", "reboot"), "Перезагрузка", "main")


# ── Создание сервера: мастер ──────────────────────────────
# Шаги — те же вопросы, что задаёт меню awg2. Ответы копятся в FSM (wiz).
STEPS = ("region", "profile", "mimicry", "proto", "dns", "mtu", "net", "port", "endpoint")
NET_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}/24$")


@act("create")
async def _create(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("server", "info")
    if not r.ok or not isinstance(r.data, dict):
        # Сбой чтения — не «нет компонентов»: иначе бот предложил бы переустановку
        await ui.render(cb, ui.fail(r, "Создание сервера"), ui.kb(ui.back("srv")))
        return
    if not r.data.get("installed"):
        # Без компонентов мастер дошёл бы до конца и упёрся в «не установлены»,
        # а на шаге версии честно сказал бы только «3.1 нельзя»
        await ui.confirm(cb, "<b>✨ Создание сервера</b>\n\nСначала нужны компоненты: пакеты, заголовки ядра, "
                             "модуль AmneziaWG и amneziawg-tools — сборка из исходников, обычно 5-15 минут. "
                             "Когда закончится — «✨ Создать сервер».",
                         ("📦 Установить", act.data("installok")), "srv")
        return
    await state.update_data(wiz={})
    await wizard(cb, state)


@act("wr")
async def _wizard_resume(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    """Вернуться в мастер с теми же ответами (после обновления модуля)."""
    await wizard(cb, state)


@act("upd31")
async def _upd31(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Обновление модуля и tools", "module", "all", back_to=act.data("wr"),
                     ok_buttons=[("✨ Продолжить", act.data("wr"))])


# Почему мастеру недоступна 3.1 (server info → proto31_why)
WHY31 = {
    "components": "▲ Компоненты не установлены: Сервер → 📦 Компоненты.",
    "tools": "▲ amneziawg-tools не умеют 3.1 — обнови модуль и tools (5-10 минут), затем вернёшься сюда.",
    "module": "▲ Модуль ядра собран без 3.1 — обнови модуль и tools (5-10 минут), затем вернёшься сюда.",
}


@act("w")
async def _wizard_answer(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    key, _, val = arg.partition("=")
    wiz = dict((await state.get_data()).get("wiz") or {})
    if key == "dns" and val.isdigit():
        val = DNS[int(val)][1] if int(val) < len(DNS) else ""
        if not val:
            await ask.ask(cb, state, "srv_dns", "DNS для клиентов: IPv4 через запятую", "srv")
            return
    if key == "port" and val == "ask":
        await ask.ask(cb, state, "srv_port", "UDP-порт сервера: 1024-65535", "srv")
        return
    if key == "mtu" and val == "ask":
        await ask.ask(cb, state, "srv_mtu", "MTU: число 1280-1500", "srv")
        return
    if key == "net" and val == "ask":
        await ask.ask(cb, state, "srv_net", "Подсеть клиентов — сеть /24, например <code>10.8.0.0/24</code>.\n"
                                            "<i>Не должна пересекаться с адресами и маршрутами сервера.</i>", "srv")
        return
    if key == "endpoint" and val == "ask":
        await ask.ask(cb, state, "srv_domain", "Домен для конфигов, например <code>vpn.example.com</code>\n"
                                               "<i>A-запись должна указывать на этот сервер.</i>", "srv")
        return
    wiz[key] = val
    await state.update_data(wiz=wiz)
    await wizard(cb, state)


async def _wizard_set(msg: Message, state: FSMContext, key: str, val: str) -> None:
    wiz = dict((await state.get_data()).get("wiz") or {})
    wiz[key] = val
    await state.update_data(wiz=wiz)
    await wizard(msg, state)


@ask.on("srv_dns")
async def _dns_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    ips = [x.strip() for x in v.split(",") if x.strip()]
    # Октеты до 255 без ведущих нулей — как valid_ip в awg2, иначе отказ только в конце мастера
    if not ips or not all(re.fullmatch(r"((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)", x)
                          for x in ips):
        await ask.retry(msg, state, ctx, "Нужны IPv4-адреса через запятую")
        return
    await _wizard_set(msg, state, "dns", ", ".join(ips))


@ask.on("srv_port")
async def _port_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not v.isdigit() or not 1024 <= int(v) <= 65535:
        await ask.retry(msg, state, ctx, "Порт — число 1024-65535")
        return
    await _wizard_set(msg, state, "port", v)


@ask.on("srv_mtu")
async def _mtu_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg)
    if not v.isdigit() or not 1280 <= int(v) <= 1500:
        await ask.retry(msg, state, ctx, "MTU — число 1280-1500")
        return
    await _wizard_set(msg, state, "mtu", v)


@ask.on("srv_net")
async def _net_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    m = NET_RE.match(ask.text_of(msg))
    if not m or any(int(x) > 255 for x in m.groups()):
        await ask.retry(msg, state, ctx, "Нужна сеть /24, например 10.8.0.0/24")
        return
    await _wizard_set(msg, state, "net", f"{m[1]}.{m[2]}.{m[3]}.0/24")


@ask.on("srv_domain")
async def _domain_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg).lower()
    if not DOMAIN_RE.match(v):
        await ask.retry(msg, state, ctx, "Нужно имя вида vpn.example.com")
        return
    await _wizard_set(msg, state, "endpoint", v)


def _w(key: str, val: str) -> str:
    return act.data("w", f"{key}={val}")


async def wizard(target: ui.Target, state: FSMContext) -> None:
    wiz = dict((await state.get_data()).get("wiz") or {})
    step = next((s for s in STEPS if s not in wiz), "")
    head = "<b>✨ Создание сервера</b>\n\n"
    cancel = ui.back("srv", "✖️ Отмена")
    if step == "region":
        await ui.render(target, head + "Где стоит сервер? От этого зависят пулы доменов мимикрии.",
                        ui.kb(("🌍 Мир / Европа", _w("region", "world")), ("🇷🇺 Россия", _w("region", "ru")), cancel))
    elif step == "profile":
        await ui.render(target, head + "<b>Профиль</b>\n"
                                       "• AmneziaVPN — как официальный клиент: MTU 1280, без I1-I5 (рекомендуется)\n"
                                       "• Мощный — широкие диапазоны и I1-I5, сильнее против DPI",
                        ui.kb(("AmneziaVPN", _w("profile", "lite")), ("Мощный", _w("profile", "pro")), cancel))
    elif step == "mimicry":
        if wiz["profile"] == "lite":
            await ui.render(target, head + "Добавить один компактный пакет мимикрии I1 (DNS, ~90 символов)? "
                                           "У официального клиента AmneziaVPN строк I нет.",
                            ui.kb(("Без I1-I5", _w("mimicry", "none")), ("Пакет I1 (DNS)", _w("mimicry", "dns:2")),
                                  cancel))
            return
        if "level" not in wiz:
            await ui.render(target, head + "<b>Уровень мимикрии</b>\n"
                                           "• Цепочка I1-I5 — полная (рекомендуется)\n"
                                           "• Только I1 — один пакет: Keenetic читает только его\n"
                                           "• Без I1-I5 — для WireSock, он их не читает",
                            ui.kb(("Цепочка I1-I5", _w("level", "3")), ("Только I1", _w("level", "2")),
                                  ("Без I1-I5", _w("mimicry", "none")), cancel))
            return
        profiles = await api.data("mimicry", default=[])
        await ui.render(target, head + "<b>Профиль мимикрии</b>\nПять пакетов залпом естественны для DNS, "
                                       "STUN и RTP; на высоком порту — STUN, WebRTC, RTP.\n\n" + ui.profile_hints(profiles),
                        ui.kb([(p["label"], _w("mimicry", f"{p['id']}:{wiz['level']}")) for p in profiles], cancel))
    elif step == "proto":
        info = await api.data("server", "info", default={}) or {}
        text = head + ("<b>Версия протокола</b> — на весь сервер.\n"
                       "• AWG 3.1 — быстрее, заголовки под шифром (рекомендуется); клиентам нужен "
                       "AmneziaVPN 5.0.1.5+ или AmneziaWG с 3.1\n"
                       "• AWG 2.0 — подключится любой клиент AmneziaWG")
        buttons = [("AWG 3.1", _w("proto", "3.1"))] if info.get("proto31") else []
        why = info.get("proto31_why") or ""
        if not info.get("proto31"):
            text += "\n\n" + (WHY31.get(why) or "▲ 3.1 не прошла проверку на сервере"
                                + (f": {esc(info['reboot'])}" if info.get("reboot") else " — Сервер → Модуль ядра"))
        upd = ("⬆️ Модуль и tools", act.data("upd31")) if why in ("tools", "module") else None
        await ui.render(target, text, ui.kb(upd, buttons, ("AWG 2.0", _w("proto", "2.0")), cancel))
    elif step == "dns":
        await ui.render(target, head + "<b>DNS для клиентов</b>\n"
                        + "\n".join(f"• {label} — <code>{ips}</code>" for label, ips in DNS),
                        ui.kb([(label, _w("dns", str(i))) for i, (label, _) in enumerate(DNS)],
                              ("Вручную…", _w("dns", str(len(DNS)))), cancel))
    elif step == "mtu":
        rec = "1320" if wiz["profile"] == "pro" else "1280"
        await ui.render(target, head + f"<b>MTU</b>\nРекомендуется {rec}.",
                        ui.kb((f"⭐ {rec}", _w("mtu", rec)),
                              [(v, _w("mtu", v)) for v in ("1420", "1380", "1320", "1280") if v != rec],
                              ("✏️ Вручную…", _w("mtu", "ask")), cancel))
    elif step == "net":
        await ui.render(target, head + "<b>Подсеть клиентов</b>\nСлучайная свободная 10.x.y.0/24 — рекомендуется: "
                                       "меньше шансов совпасть с домашней сетью клиента.",
                        ui.kb(("🎲 Случайная", _w("net", "")), ("✏️ Вручную…", _w("net", "ask")), cancel))
    elif step == "port":
        await ui.render(target, head + "<b>UDP-порт</b>",
                        ui.kb(("🎲 Случайный", _w("port", "")), ("✏️ Ввести…", _w("port", "ask")), cancel))
    elif step == "endpoint":
        await ui.render(target, head + "<b>Адрес в конфигах клиентов</b>\nДомен вместо IP — переезд сервера "
                                       "без перевыдачи конфигов.",
                        ui.kb(("IP этого сервера", _w("endpoint", "")), ("✏️ Домен…", _w("endpoint", "ask")), cancel))
    else:
        await ui.render(target, head + "\n".join([
            f"Регион: {'Россия' if wiz['region'] == 'ru' else 'мир'}",
            f"Профиль: {PROFILE[wiz['profile']]} · мимикрия {esc(wiz['mimicry'])}",
            f"Версия: AWG {wiz['proto']} · MTU {wiz['mtu']}",
            f"Подсеть: {esc(wiz['net'] or 'случайная 10.x.y.0/24')}",
            f"DNS: {esc(wiz['dns'])}",
            f"Порт: {wiz['port'] or 'случайный'} · endpoint: {esc(wiz['endpoint'] or 'IP сервера')}",
        ]), ui.kb(ui.Row(("✅ Создать сервер", act.data("createok")), cancel)))


async def _send_first(bot: Bot, chat_id: int, st: dict) -> None:
    name = (st.get("data") or {}).get("client")
    if name:
        await clients.send_config(bot, chat_id, name)


@act("createok")
async def _create_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    wiz = dict((await state.get_data()).get("wiz") or {})
    if any(s not in wiz for s in STEPS):
        await wizard(cb, state)
        return
    await state.update_data(wiz={})
    args = [f"profile={wiz['profile']}", f"proto={wiz['proto']}", f"region={wiz['region']}",
            f"dns={wiz['dns']}", f"mtu={wiz['mtu']}", f"mimicry={wiz['mimicry']}"]
    args += [f"net={wiz['net']}"] if wiz["net"] else []
    args += [f"port={wiz['port']}"] if wiz["port"] else []
    args += [f"endpoint={wiz['endpoint']}"] if wiz["endpoint"] else []
    await jobs.start(cb, "Создание сервера", "server", "create", *args, back_to="srv", done=_send_first)


# ── Протокол ──────────────────────────────────────────────
@act("proto")
async def _proto(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    info = await api.data("server", "info", default={}) or {}
    cur = info.get("proto", "2.0")
    n = info.get("clients", 0)
    up = "🔁 Параметры 3.1" if cur == "3.1" else "⬆️ Перейти на 3.1"
    down = "🔁 Параметры 2.0" if cur == "2.0" else "⬇️ Вернуть 2.0"
    note = "" if info.get("proto31") else "\n▲ Модуль не умеет 3.1 — при переходе он обновится (долго)."
    await ui.render(cb, f"<b>🔀 Протокол и параметры</b>\n\nСейчас: AWG {esc(cur)}, клиентов {n}.\n"
                        "• 3.1 — быстрее, заголовки под шифром; 2.0 — для старых клиентов\n"
                        "• 🔁 — новые параметры той же версии\n"
                        f"Ключи, адреса, имена и сроки сохраняются; все клиенты получают новые конфиги "
                        f"и до их замены не подключатся.{note}",
                    ui.kb((up, act.data("protogo", "3.1")), (down, act.data("protogo", "2.0")), ui.back("srv")))


@act("protogo")
async def _proto_go(cb: CallbackQuery, state: FSMContext, target: str) -> None:
    await ui.confirm(cb, f"Перегенерировать параметры на AWG {esc(target)}?\n"
                         "Все клиенты потеряют связь до получения нового конфига.",
                     ("✅ Да, выполнить", act.data("protook", target)), act.data("proto"))


@act("protook")
async def _proto_ok(cb: CallbackQuery, state: FSMContext, target: str) -> None:
    # Всем клиентам нужны новые конфиги — кнопки к ним прямо в итоге
    await jobs.start(cb, f"Переход на AWG {target}", "server", "proto", target, back_to="srv",
                     ok_buttons=[("📦 Конфиги zip", "cl:export"), ("👥 Клиенты", "cl")])


# ── Параметры AWG вручную ─────────────────────────────────
# Правки копятся в FSM (params: {ключ: значение}); каждый показ экрана
# проверяет их в awg2 (server params check) — ошибки видны сразу, а запись
# (server params set) уходит одним вызовом после подтверждения.
PSHORT = {"ContentPaddingAddition": "Паддинг", "RekeyAfterTime": "RekeyAfter", "RejectAfterTime": "RejectAfter",
          "KeepaliveTimeout": "Keepalive", "MaxHandshakeAttempts": "MaxHS", "RandomTrailers": "Trailers",
          "DisableCookies": "NoCookies"}
PSWITCH = ("RandomTrailers", "DisableCookies")
PHINT = {
    "Jc": "сколько мусорных пакетов слать перед рукопожатием: 0-128, рекомендуется 3-12",
    "Jmin": "наименьший размер мусорного пакета, байт: 0-1472",
    "Jmax": "наибольший размер мусорного пакета, байт: 0-1472, не меньше Jmin",
    "S1": "паддинг пакета инициации, байт", "S2": "паддинг пакета ответа, байт",
    "S3": "паддинг cookie-пакета, байт", "S4": "паддинг пакетов с данными, байт: до 32",
    "H1": "заголовок инициации: число или диапазон a-b", "H2": "заголовок ответа: число или диапазон a-b",
    "H3": "заголовок cookie: число или диапазон a-b", "H4": "заголовок данных: число или диапазон a-b",
    "ContentPaddingAddition": "добавка паддинга к данным: диапазон a-b, байт",
    "RekeyAfterTime": "через сколько секунд переустанавливать сессию: число или a-b",
    "RekeyTimeout": "повтор рукопожатия, секунды: число или a-b",
    "RejectAfterTime": "предел жизни сессии, секунды: целиком больше RekeyAfterTime",
    "KeepaliveTimeout": "keepalive после тишины, секунды: число или a-b",
    "MaxHandshakeAttempts": "сколько раз повторять рукопожатие: число или a-b",
}
PMATCH = "S и H обязаны совпадать у клиентов — после их правки старые конфиги не подключатся."
PVAL_RE = re.compile(r"^\d{1,10}(-\d{1,10})?$")


def _pedits_args(edits: dict) -> list[str]:
    return [f"{k}={v}" for k, v in edits.items()]


@act("par")
async def _params(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await state.update_data(params={})
    await params_screen(cb, state)


@act("pview")
async def _params_view(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await params_screen(cb, state)


async def params_screen(target: ui.Target, state: FSMContext) -> None:
    edits = (await state.get_data()).get("params") or {}
    r = await api.call("server", "params", "check", *_pedits_args(edits))
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, "Параметры AWG"), ui.kb(ui.back("srv")))
        return
    d = r.data
    vals: dict = d.get("values") or {}
    changed = set(d.get("changed") or [])
    await state.update_data(params_vals=vals)
    w = max((len(k) for k in vals), default=0)
    block = "\n".join(f"{'✎' if k in changed else ' '} {k.ljust(w)} = {v or '—'}" for k, v in vals.items())
    text = (f"<b>🎛 Параметры AWG {esc(d.get('proto', ''))}</b>\n{ui.pre(block)}\n{PMATCH} "
            "Jc/Jmin/Jmax и таймеры — не обязаны.")
    if changed:
        text += "\n\n✎ — изменено, ещё не применено."
    text += "".join(f"\n❌ {esc(e)}" for e in d.get("errors") or [])
    text += "".join(f"\n▲ {esc(x)}" for x in d.get("warnings") or [])

    def key(k: str) -> ui.Button:
        label = PSHORT.get(k, k)
        if k in PSWITCH:
            label += ": " + (vals.get(k) or "off")
        return ("✎ " + label if k in changed else label), act.data("pk", k)

    groups = [["Jc", "Jmin", "Jmax"], ["S1", "S2", "S3", "S4"], ["H1", "H2", "H3", "H4"],
              ["ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout"],
              ["RejectAfterTime", "KeepaliveTimeout", "MaxHandshakeAttempts"], list(PSWITCH)]
    rows = [ui.Row(*[key(k) for k in g if k in vals]) for g in groups]
    ready = changed and not d.get("errors")
    await ui.render(target, text, ui.kb(
        *rows,
        ("✅ Применить", act.data("pgo")) if ready else None,
        ("↩️ Сбросить правки", act.data("preset")) if changed else None,
        ui.back("srv")))


@act("pk")
async def _param_key(cb: CallbackQuery, state: FSMContext, k: str) -> None:
    data = await state.get_data()
    cur = (data.get("params_vals") or {}).get(k, "")
    if k in PSWITCH:
        edits = dict(data.get("params") or {})
        edits[k] = "off" if cur == "on" else "on"
        await state.update_data(params=edits)
        await params_screen(cb, state)
        return
    match = " Обязан совпадать у клиентов." if k[0] in "SH" else ""
    await ask.ask(cb, state, "srv_param", f"<b>{esc(k)}</b> — {esc(PHINT.get(k, ''))}.{match}\n"
                                          f"Сейчас: <code>{esc(cur or '—')}</code>\n\nНовое значение:",
                  act.data("pview"), param=k)


@ask.on("srv_param")
async def _param_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = re.sub(r"\s+", "", ask.text_of(msg))
    if not PVAL_RE.match(v):
        await ask.retry(msg, state, ctx, "Нужно число или диапазон a-b, например 5 или 100-2000")
        return
    edits = dict((await state.get_data()).get("params") or {})
    edits[ctx["param"]] = v
    await state.update_data(params=edits)
    await params_screen(msg, state)


@act("preset")
async def _params_reset(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await state.update_data(params={})
    await params_screen(cb, state)


@act("pgo")
async def _params_go(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    edits = (await state.get_data()).get("params") or {}
    r = await api.call("server", "params", "check", *_pedits_args(edits))
    d = r.data if r.ok and isinstance(r.data, dict) else {}
    if not d.get("changed") or d.get("errors"):
        await params_screen(cb, state)
        return
    lines = [f"<b>🎛 Применить параметры?</b>\nМеняются: {esc(', '.join(d['changed']))}"]
    lines += [f"▲ {esc(x)}" for x in d.get("warnings") or []]
    if d.get("breaking"):
        lines.append(f"\n⚠️ {esc(', '.join(d['breaking']))} обязаны совпадать у клиентов: все клиенты "
                     f"({d.get('clients', 0)}) потеряют связь до получения нового конфига.")
    else:
        lines.append("\nСтарые конфиги продолжат работать — эти параметры клиентам совпадать не обязаны.")
    lines.append("Перед записью — авто-бэкап; не поднимется awg0 — вернутся прежние.")
    yes = "⚠️ Применить всё равно" if d.get("warnings") else "✅ Применить"
    await ui.confirm(cb, "\n".join(lines), (yes, act.data("pok")), act.data("pview"))


@act("pok")
async def _params_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    edits = (await state.get_data()).get("params") or {}
    if not edits:
        await params_screen(cb, state)
        return
    await ui.render(cb, "⏳ Записываю параметры и перезапускаю awg0…")
    r = await api.call("server", "params", "set", "force", *_pedits_args(edits))
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Параметры AWG"), ui.kb(("✏️ К правке", act.data("pview")), ui.back("srv")))
        return
    await state.update_data(params={})
    d = r.data if isinstance(r.data, dict) else {}
    body = ui.pre("\n".join(r.log.strip().splitlines()[-8:]), 2500)
    await ui.render(cb, f"✅ <b>Параметры AWG</b>\n{body}", ui.kb(
        ("📦 Конфиги zip", "cl:export") if d.get("breaking") and d.get("clients") else None,
        ("👥 Клиенты", "cl") if d.get("breaking") else None,
        ("🎛 Параметры AWG", act.data("par")), ui.back("srv")))


# ── Endpoint ──────────────────────────────────────────────
@act("ep")
async def _ep(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    info = await api.data("server", "info", default={}) or {}
    dom = info.get("domain")
    await ui.render(cb, f"<b>🌍 Endpoint</b>\n\nВ конфигах: <code>{esc(info.get('endpoint', ''))}</code>\n"
                        + ("Домен задан — сервер можно переносить без перевыдачи конфигов." if dom
                           else "Сейчас IP. С доменом переезд сервера не требует новых конфигов."),
                    ui.kb(("✏️ Указать домен", act.data("epdom")),
                          ("🔢 Публичный IP", act.data("epset", "ip")) if dom else None,
                          ui.back("srv")))


@act("epdom")
async def _ep_domain(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ask.ask(cb, state, "srv_ep", "Домен, например <code>vpn.example.com</code>\n"
                                       "<i>A-запись должна указывать на этот сервер.</i>", act.data("ep"))


@ask.on("srv_ep")
async def _ep_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    v = ask.text_of(msg).lower()
    if not DOMAIN_RE.match(v):
        await ask.retry(msg, state, ctx, "Нужно имя вида vpn.example.com")
        return
    await _ep_rewrite(msg, state, v)


@act("epset")
async def _ep_set(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await _ep_rewrite(cb, state, "ip")


async def _ep_rewrite(target: ui.Target, state: FSMContext, value: str) -> None:
    # Домен до 253 символов — в callback_data (64 байта) не влезет, держим в FSM
    await state.update_data(endpoint=value)
    await ui.render(target, f"Endpoint → <code>{esc(value if value != 'ip' else 'публичный IP')}</code>\n"
                            "Переписать его и в уже выданных конфигах — или только для новых клиентов?",
                    ui.kb(("✅ Во всех", act.data("epgo", "all")),
                          ("🆕 Только новые", act.data("epgo", "keep")), ui.back(act.data("ep"))))


@act("epgo")
async def _ep_go(cb: CallbackQuery, state: FSMContext, mode: str) -> None:
    value = (await state.get_data()).get("endpoint")
    if not value:
        await _ep(cb, state, "")
        return
    await state.update_data(endpoint="")
    args = ["server", "endpoint", value] + (["keep"] if mode == "keep" else [])
    await ui.result(cb, await api.call(*args), "Endpoint", "srv")


# ── Модуль ядра и amneziawg-tools ─────────────────────────
@mod()
async def mod_screen(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    r = await api.call("module", "report")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(cb, ui.fail(r, "Модуль ядра"), ui.kb(ui.back("srv")))
        return
    d = r.data
    kernels = ", ".join(d.get("kernels") or []) or "—"
    lines = [
        "<b>🧩 Модуль ядра и amneziawg-tools</b>", "",
        f"Ядро: <code>{esc(d.get('kernel', ''))}</code> (установлены: {esc(kernels)})",
        f"Модуль: <code>{esc(d.get('module') or 'не установлен')}</code> "
        + ("🟢 загружен" if d.get("loaded") else "🔴 не загружен")
        + (f" · ⬆️ есть {esc(d['module_update'])}" if d.get("module_update") else ""),
        f"tools: <code>{esc(d.get('tools') or 'не установлены')}</code>"
        + (f" · ⬆️ есть {esc(d['tools_update'])}" if d.get("tools_update") else ""),
    ]
    if d.get("reboot"):
        lines.append(f"\n▲ {esc(d['reboot'])}")
    if d.get("secure_boot"):
        lines.append("▲ Secure Boot включён — неподписанный модуль ядро не загрузит")
    lines.append("\n<i>⬆️ — обновить до последней версии · 🔁 — перезагрузить модуль без ребута · "
                 "🧱 — собрать под все установленные ядра</i>")
    await ui.render(cb, "\n".join(lines), ui.kb(
        ("⬆️ Модуль", mod.data("upd")),
        ("📋 Версия модуля", mod.data("tags")),
        ("⬆️ Tools", mod.data("tools")),
        ("🔁 Перезагрузить", mod.data("reload")),
        ("🧱 Под все ядра", mod.data("rebuild")),
        ("⏪ Откат модуля", mod.data("backups")) if d.get("backups") else None,
        ("🔎 Проверить", mod.data("check")),
        ("📄 Отчёт", mod.data("report")),
        ui.back("srv")))


@mod("upd")
async def _mod_upd(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Собрать и поставить последнюю версию модуля? Туннели лягут на несколько секунд "
                         "при перезагрузке модуля.",
                     ("✅ Обновить", mod.data("updok")), mod.data())


@mod("updok")
async def _mod_upd_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Обновление модуля", "module", "update", back_to="mod")


@mod("tags")
async def _mod_tags(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Получаю список версий…")
    r = await api.call("module", "tags")
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Версии модуля"), ui.kb(ui.back("mod")))
        return
    tags = list(r.data or [])
    await ui.remember(state, "tags", tags)
    await ui.render(cb, "<b>📋 Версия модуля</b>\nСверху — новые.",
                    ui.kb([(t, mod.data("tag", str(i))) for i, t in enumerate(tags)], ui.back("mod")))


@mod("tag")
async def _mod_tag(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    tag = await ui.recall(state, "tags", idx)
    if not tag:
        await mod_screen(cb, state)
        return
    await ui.confirm(cb, f"Собрать и поставить модуль <code>{esc(tag)}</code>?",
                     ("✅ Поставить", mod.data("tagok", idx)), mod.data("tags"))


@mod("tagok")
async def _mod_tag_ok(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    tag = await ui.recall(state, "tags", idx)
    if tag:
        await jobs.start(cb, f"Модуль {tag}", "module", "update", tag, "force", back_to="mod")


@mod("tools")
async def _mod_tools(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Обновление amneziawg-tools", "module", "tools", back_to="mod")


@mod("reload")
async def _mod_reload(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Перезагрузить модуль? Туннели лягут на несколько секунд, клиенты переподключатся сами.",
                     ("🔁 Перезагрузить", mod.data("reloadok")), mod.data())


@mod("reloadok")
async def _mod_reload_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Перезагрузка модуля", "module", "reload", back_to="mod")


@mod("rebuild")
async def _mod_rebuild(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await jobs.start(cb, "Сборка модуля под все ядра", "module", "rebuild", back_to="mod")


def _bk_label(b: dict) -> str:
    """«v1.0.2 · 08.10.2026 12:00»: тег версии — из имени копии src-ТЕГ-ДАТА-ВРЕМЯ.tar.gz."""
    m = re.match(r"src-(.+)-\d{8}-\d{6}\.tar\.gz$", b.get("name") or "")
    return f"{m.group(1)} · {ui.fmt_time(b['time'])}" if m else ui.fmt_time(b["time"])


@mod("backups")
async def _mod_backups(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    rows = await api.data("module", "backups", default=[]) or []
    await ui.remember(state, "modbk", [b["path"] for b in rows])
    # По страницам: у клавиатуры Telegram есть предел числа кнопок
    await ui.render(cb, f"<b>⏪ Резервные копии исходников модуля</b>: {len(rows)}\nСверху — новые.",
                    ui.kb(ui.paged([(_bk_label(b), mod.data("rb", str(i))) for i, b in enumerate(rows)],
                                   int(arg) if arg.isdigit() else 0, lambda p: mod.data("backups", str(p))),
                          ui.back("mod")))


@mod("rb")
async def _mod_rb(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    path = await ui.recall(state, "modbk", idx)
    if path:
        await ui.confirm(cb, f"Вернуть модуль из <code>{esc(path.rsplit('/', 1)[-1])}</code>?",
                         ("⏪ Вернуть", mod.data("rbok", idx)), mod.data("backups"))


@mod("rbok")
async def _mod_rb_ok(cb: CallbackQuery, state: FSMContext, idx: str) -> None:
    path = await ui.recall(state, "modbk", idx)
    if path:
        await jobs.start(cb, "Откат модуля", "module", "rollback", path, back_to="mod")


@mod("check")
async def _mod_check(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Проверяю github.com…")
    r = await api.call("module", "check")
    if not r.ok:
        await ui.render(cb, ui.fail(r, "Проверка обновлений"), ui.kb(ui.back("mod")))
        return
    await mod_screen(cb, state)


@mod("report")
async def _mod_report(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("module", "report")
    await ui.render(cb, "<b>📄 Отчёт о компонентах</b>\n" + (ui.pre(r.log, 3500, tail=False) if r.ok else ui.fail(r)),
                    ui.kb(ui.back("mod")))
