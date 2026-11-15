"""РФ напрямую и «Если туннель упал» — пункты «Туннели» awg2.

РФ напрямую: клиенты в туннеле (WARP, Xray, tun2socks, exit-ноды) ходят к
сетям России мимо него, прямо с сервера. Список РФ качает и проверяет awg2,
здесь — экран: состояние, свои списки «всегда напрямую» и «всегда через
туннель», «Telegram напрямую», починить, журнал.

Если туннель упал: на каждый туннель — «напрямую» (как было) или
«блокировать» (клиенты ждут туннель без интернета, адрес сервера не светится).
"""

from __future__ import annotations

from aiogram import Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import api, ask, ui
from ..ui import esc

router = Router()
rud = ui.Actions(router, "rud")
tf = ui.Actions(router, "tf")
TIMEOUT = 240                       # скачать список РФ (до 60 с с каждого источника) и применить
TITLE = "РФ напрямую"
LISTS = {"direct": ("Всегда напрямую", "мимо туннеля, даже если адрес не в списке России"),
         "tunnel": ("Всегда через туннель", "в туннель, даже если адрес в сетях России")}
SHOWN = 20                          # записей кнопками на экране списка


def _n(v: int | None) -> str:
    return f"{int(v or 0):,}".replace(",", " ")


def abroad_text(cc: str) -> str:
    """Сервер не в России: «РФ напрямую» светит адрес входа российским приложениям."""
    return (f"⚠️ Сервер не в России ({esc(cc)}): российские сайты и приложения увидят адрес сервера, к которому "
            "подключаются клиенты, — зарубежные адреса блокируют как раз за это. «РФ напрямую» — для сервера в России.")


# ── РФ напрямую ───────────────────────────────────────────
@rud()
async def show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await screen(cb)


async def screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("rudirect", "status")
    if not r.ok or not isinstance(r.data, dict):
        await ui.render(target, ui.fail(r, TITLE), ui.kb(ui.back("tun")))
        return
    d = r.data
    on = bool(d.get("enabled"))
    direct, tunnel = d.get("direct") or [], d.get("tunnel") or []
    lines = [f"<b>🇷🇺 {TITLE}</b>",
             "Клиенты в туннеле (WARP, Xray, tun2socks, exit-ноды) ходят к сайтам России мимо него — прямо с "
             "сервера. Полезно, когда сервер в России, а выход за границей: банки и госсервисы видят российский "
             "адрес, а выход не тратится на них.", ""]
    if note:
        lines += [note, ""]
    if on:
        lines.append(("🟢 Включено" if d.get("active") else "🟡 Включено, правило не на месте — «Починить» или "
                      "подождать таймер") + f" · сетей РФ {_n(d.get('ru'))}")
        lines.append(f"↪️ Мимо туннеля: {_n(d.get('packets'))} пакетов (сбрасывается при перезагрузке)")
        if d.get("abroad"):
            lines += [abroad_text(str(d["abroad"])), "<i>Страна определена неверно — выбери её флагом в шапке панели.</i>"]
    else:
        lines.append("⚪️ Выключено")
    lines.append(f"📝 Свои: напрямую {len(direct)}, через туннель {len(tunnel)}")
    tg = bool(d.get("tg"))
    lines.append("✈️ Telegram: напрямую с адреса сервера" if tg else "✈️ Telegram: через туннель")
    if d.get("updated"):
        lines.append(f"🕒 Список обновлён {ui.fmt_time(d['updated'])}" + (f" ({esc(d['src'])})"
                                                                         if d.get("src") else ""))
    if d.get("error"):
        lines.append(f"▲ {esc(d['error'])}")
    if d.get("xray_ru"):
        lines.append("ℹ️ У Xray своё «РФ напрямую» (по доменам) — работает вместе с этим.")
    lines.append("\n<i>Список сетей России — ipverse (данные RIPE), обновляется раз в сутки. Клиенты без туннеля "
                 "и трафик самого сервера не трогаются.</i>")
    if not tg:
        lines.append("<i>«✈️ TG напрямую» — если через туннель Telegram висит на «Соединение…», а с сервера "
                     "работает (WARP с сервера в России).</i>")
    buttons: list = [("⏹ Выключить", rud.data("off")) if on else ("✅ Включить", rud.data("on"))]
    if on:
        buttons += [("🔄 Обновить", rud.data("upd")), ("🛠 Починить", rud.data("fix"))]
    buttons.append(("✈️ TG в туннель", rud.data("tg", "off")) if tg else ("✈️ TG напрямую", rud.data("tg", "on")))
    buttons += [(f"📝 Напрямую: {len(direct)}", rud.data("l", "direct")),
                (f"📝 В туннель: {len(tunnel)}", rud.data("l", "tunnel")),
                ("🧭 Куда идёт", "diag:rt:r"), ("📜 Журнал", "diag:log:rudirect|rud"), ui.back("tun")]
    await ui.render(target, "\n".join(lines), ui.kb(*buttons))


@rud("on")
async def _on(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("rudirect", "status")
    cc = r.data.get("abroad") if r.ok and isinstance(r.data, dict) else ""
    await ui.confirm(cb, (abroad_text(str(cc)) + "\n\n" if cc else "")
                     + "Включить? Клиенты в туннеле пойдут к сайтам России с адреса сервера, а не выхода "
                     "туннеля. Выключить можно здесь, в боте.", ("✅ Включить", rud.data("onok")), rud.data())


@rud("onok")
async def _on_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Скачиваю и проверяю список сетей России, ставлю правило…")
    r = await api.call("rudirect", "on", timeout=TIMEOUT)
    await screen(cb, "✅ Включено" if r.ok else ui.fail(r, TITLE))


@rud("off")
async def _off(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.confirm(cb, "Выключить? Правило снимается — клиенты в туннеле снова пойдут через него ко всем "
                     "сайтам. Свои списки сохранятся.", ("⏹ Выключить", rud.data("offok")), rud.data())


@rud("offok")
async def _off_ok(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    r = await api.call("rudirect", "off")
    await screen(cb, "⏹ Выключено" if r.ok else ui.fail(r, TITLE))


@rud("upd")
async def _upd(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Обновляю список…")
    r = await api.call("rudirect", "update", timeout=TIMEOUT)
    await screen(cb, "✅ Список обновлён" if r.ok else ui.fail(r, "Обновление списка"))


@rud("tg")
async def _tg(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    on = arg == "on"
    await ui.render(cb, "⏳ Применяю…")
    r = await api.call("rudirect", "tg", "on" if on else "off", timeout=TIMEOUT)
    note = ("✅ Telegram напрямую: клиенты в туннеле ходят в Telegram с адреса сервера" if on
            else "✅ Telegram — снова через туннель") if r.ok else ui.fail(r, "Telegram напрямую")
    await screen(cb, note)


@rud("fix")
async def _fix(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await ui.render(cb, "⏳ Ставлю набор и правила заново…")
    r = await api.call("rudirect", "repair", timeout=TIMEOUT)
    await screen(cb, "✅ Правила на месте" if r.ok else ui.fail(r, "Починить"))


# ── Свои списки ───────────────────────────────────────────
@rud("l")
async def _list(cb: CallbackQuery, state: FSMContext, kind: str) -> None:
    await list_screen(cb, kind)


async def list_screen(target: ui.Target, kind: str, note: str = "") -> None:
    if kind not in LISTS:
        kind = "direct"
    title, what = LISTS[kind]
    r = await api.call("rudirect", "status")
    d = r.data if r.ok and isinstance(r.data, dict) else {}
    items = [str(x) for x in d.get(kind) or []]
    lines = [f"<b>📝 {title}</b>", f"Адрес, подсеть или домен — {what}. Домен перечитывается раз в час: "
             "адреса сайтов меняются.", ""]
    if note:
        lines += [note, ""]
    lines += [f"• <code>{esc(x)}</code>" for x in items[:50]] or ["<i>пока пусто</i>"]
    if len(items) > 50:
        lines.append(f"…и ещё {len(items) - 50}")
    if not d.get("enabled"):
        lines.append("\n<i>РФ напрямую выключено — список заработает при включении.</i>")
    dels = [(f"❌ {x}", rud.data("d", f"{kind[0]}|{x}")) for x in items[:SHOWN]
            if len(rud.data("d", f"{kind[0]}|")) + len(x.encode()) <= 64]
    await ui.render(target, "\n".join(lines), ui.kb(
        ("➕ Добавить", rud.data("a", kind)), *dels,
        ("🧹 Очистить", rud.data("x", kind)) if items else None, ui.back(rud.data())))


@rud("a")
async def _add(cb: CallbackQuery, state: FSMContext, kind: str) -> None:
    await ask.ask(cb, state, "rud_add", "Адрес, подсеть или домен: <code>91.200.1.5</code>, "
                                        "<code>91.200.0.0/16</code>, <code>bank.ru</code> (можно ссылкой)",
                  rud.data("l", kind), kind=kind)


@ask.on("rud_add")
async def _add_answer(msg: Message, state: FSMContext, ctx: ask.Ctx) -> None:
    text, kind = ask.text_of(msg), ctx.get("kind", "direct")
    if not text or len(text) > 253 or any(c.isspace() for c in text):
        await ask.retry(msg, state, ctx, "Нужен один адрес, подсеть или домен")
        return
    r = await api.call("rudirect", "add", kind, text, timeout=TIMEOUT)
    if not r.ok:
        await ask.retry(msg, state, ctx, r.message)
        return
    await list_screen(msg, kind, "✅ Добавлено")


@rud("d")
async def _del(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    k, _, item = arg.partition("|")
    kind = "tunnel" if k == "t" else "direct"
    r = await api.call("rudirect", "del", kind, item, timeout=TIMEOUT)
    await list_screen(cb, kind, f"✅ Убрано <code>{esc(item)}</code>" if r.ok else ui.fail(r, "Список"))


@rud("x")
async def _clear(cb: CallbackQuery, state: FSMContext, kind: str) -> None:
    await ui.confirm(cb, f"Очистить список «{LISTS.get(kind, LISTS['direct'])[0]}»?",
                     ("🧹 Очистить", rud.data("xok", kind)), rud.data("l", kind))


@rud("xok")
async def _clear_ok(cb: CallbackQuery, state: FSMContext, kind: str) -> None:
    r = await api.call("rudirect", "del", kind, "all", timeout=TIMEOUT)
    await list_screen(cb, kind, "✅ Список очищен" if r.ok else ui.fail(r, "Список"))


# ── Если туннель упал ─────────────────────────────────────
def tf_state(row: dict) -> str:
    if not row.get("enabled"):
        return "⚪️ выключен"
    if row.get("up"):
        return "🟢 работает"
    if row.get("held"):
        return "🔴 упал — клиенты ждут его без интернета"
    return "🟡 не работает" + (" — клиенты идут напрямую" if row.get("mode") != "block" else "")


@tf()
async def tf_show(cb: CallbackQuery, state: FSMContext, arg: str = "") -> None:
    await tf_screen(cb)


async def tf_screen(target: ui.Target, note: str = "") -> None:
    r = await api.call("tunnels", "fail", "list")
    if not r.ok or not isinstance(r.data, list):
        await ui.render(target, ui.fail(r, "Если туннель упал"), ui.kb(ui.back("tun")))
        return
    rows = [x for x in r.data if isinstance(x, dict)]
    lines = ["<b>🪂 Если туннель упал</b>",
             "Что делать клиентам туннеля, когда он упал: не отвечает, служба остановилась, сервер "
             "перезагрузился, а туннель не поднялся.",
             "➡️ <b>Напрямую</b> — как было: клиенты идут с адреса сервера, интернет не пропадает.",
             "🛑 <b>Блокировать</b> — ждут туннель без интернета (кроме «РФ напрямую»): адрес сервера не "
             "засветится. Вернётся туннель — вернётся и интернет.", ""]
    if note:
        lines += [note, ""]
    lines += [f"{'🛑' if x.get('mode') == 'block' else '➡️'} <b>{esc(x.get('label', ''))}</b> — "
              f"{'блокировать' if x.get('mode') == 'block' else 'напрямую'} · {tf_state(x)}" for x in rows]
    lines.append("\n<i>Нажатие переключает режим. Выключенный руками туннель отпускает клиентов в любом "
                 "режиме.</i>")
    buttons: list = [(f"{'🛑' if x.get('mode') == 'block' else '➡️'} {x.get('label', '')}",
                      tf.data("t", x.get("name", ""))) for x in rows]
    if any(x.get("mode") == "block" for x in rows):
        buttons.append(("↪️ Всем напрямую", tf.data("all")))
    buttons += [("📜 Журнал", "diag:log:tunfail|tf"), ui.back("tun")]
    await ui.render(target, "\n".join(lines), ui.kb(*buttons))


async def _tf_set(target: ui.Target, name: str, mode: str) -> None:
    r = await api.call("tunnels", "fail", "set", name, mode)
    label = {"warp": "WARP", "xray": "Xray", "t2s": "tun2socks", "exits": "Exit-ноды WG"}.get(name, "Все туннели")
    await tf_screen(target, ("✅ " + ("Напрямую, как было" if mode == "direct" else "Блокировать"))
                    if r.ok else ui.fail(r, label))


@tf("t")
async def _tf_toggle(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    rows = await api.data("tunnels", "fail", "list", default=[]) or []
    row = next((x for x in rows if isinstance(x, dict) and x.get("name") == name), None)
    if row is None:
        await cb.answer("Кнопка устарела — открой меню заново", show_alert=True)
        return
    if row.get("mode") == "block":
        await _tf_set(cb, name, "direct")
        return
    if row.get("enabled") and not row.get("up"):
        # Туннель включён, но лежит: «блокировать» сразу оставит его клиентов без интернета
        await ui.confirm(cb, f"{esc(row.get('label', name))} сейчас не работает. В режиме «блокировать» его "
                         "клиенты сразу останутся без интернета (кроме «РФ напрямую»), пока он не поднимется. "
                         "Включить?", ("🛑 Блокировать", tf.data("bok", name)), tf.data())
        return
    await _tf_set(cb, name, "block")


@tf("bok")
async def _tf_block_ok(cb: CallbackQuery, state: FSMContext, name: str) -> None:
    await _tf_set(cb, name, "block")


@tf("all")
async def _tf_all(cb: CallbackQuery, state: FSMContext, arg: str) -> None:
    await _tf_set(cb, "all", "direct")
