#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# AWG Toolza Bot — установщик
# Устанавливает Telegram бот для управления AmneziaWG сервером
# Требует: Ubuntu 22/24/Debian 12, root, уже установленный AWG Toolza
# Использование: sudo bash awg-bot-install.sh
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Константы ─────────────────────────────────────────────────────────────────
BOT_PY="/usr/local/bin/awg-bot.py"
BOT_CONF="/etc/awg-bot.conf"
BOT_SERVICE="/etc/systemd/system/awg-bot.service"
BOT_LOG="/var/log/awg-bot.log"
SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"

# ── Цвета ─────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
C='\033[0;36m'; W='\033[1;37m'; D='\033[2;37m'; N='\033[0m'

ok()   { echo -e "  ${G}✓${N} $*"; }
err()  { echo -e "  ${R}✗${N} $*"; }
info() { echo -e "  ${C}→${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
hdr()  { echo -e "\n${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; \
          echo -e "  ${W}$*${N}"; \
          echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }

# ── Проверка root ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { err "Нужен root: sudo bash $0"; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
hdr "AWG Toolza Bot — установщик"
# ══════════════════════════════════════════════════════════════════════════════

# ── Шаг 1: Проверка AWG Toolza ────────────────────────────────────────────────
echo ""
info "Проверяю AWG Toolza..."
if [[ ! -f "$SERVER_CONF" ]]; then
  err "Серверный конфиг не найден: $SERVER_CONF"
  err "Сначала установи и настрой AWG Toolza (sudo awg2 → пункт 2)"
  exit 1
fi
if ! command -v awg &>/dev/null; then
  err "awg не найден — установи AmneziaWG (sudo awg2 → пункт 1)"
  exit 1
fi
ok "AWG Toolza найден"

# ── Шаг 2: Зависимости ───────────────────────────────────────────────────────
echo ""
info "Устанавливаю зависимости..."

apt-get update -qq 2>/dev/null || true
apt-get install -y -qq python3 python3-pip qrencode 2>/dev/null || {
  err "Ошибка apt-get. Проверь интернет."; exit 1
}
ok "python3, pip, qrencode установлены"

info "Устанавливаю python-telegram-bot..."
pip3 install "python-telegram-bot>=20" --break-system-packages -q 2>/dev/null || \
  pip3 install "python-telegram-bot>=20" -q 2>/dev/null || {
  err "Ошибка pip. Попробуй вручную: pip3 install python-telegram-bot"
  exit 1
}
PTB_VER=$(python3 -c "import telegram; print(telegram.__version__)" 2>/dev/null || echo "?")
ok "python-telegram-bot $PTB_VER установлен"

# ── Шаг 3: Инструкция — получение токена ─────────────────────────────────────
echo ""
hdr "Шаг 1 из 2: Создай бота в Telegram"
cat << 'MANUAL'

  Если бот уже создан — пропусти этот шаг.

  1. Открой Telegram и найди @BotFather
  2. Отправь команду: /newbot
  3. Введи название бота (например: AWG Toolza)
  4. Введи username бота (например: my_awg_toolza_bot)
     — должен заканчиваться на "bot"
  5. BotFather пришлёт токен вида:
     1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

  Скопируй токен — он понадобится сейчас.

MANUAL

read -rp "$(echo -e "  ${C}Вставь токен бота: ${N}")" BOT_TOKEN

# Валидация токена — формат: digits:string
if ! echo "$BOT_TOKEN" | grep -qP '^\d+:[A-Za-z0-9_-]{35,}$'; then
  err "Неверный формат токена. Ожидается: 1234567890:AAxxxxx..."
  err "Проверь и запусти установщик снова."
  exit 1
fi
ok "Токен принят"

# Проверяем токен через Telegram API
info "Проверяю токен через Telegram API..."
API_RESP=$(curl -sf "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || echo "")
if echo "$API_RESP" | grep -q '"ok":true'; then
  BOT_USERNAME=$(echo "$API_RESP" | grep -oP '"username":"\K[^"]+')
  ok "Бот найден: @$BOT_USERNAME"
else
  err "Токен недействителен или нет интернета."
  err "Ответ API: $API_RESP"
  exit 1
fi

# ── Шаг 4: Инструкция — получение chat_id ────────────────────────────────────
echo ""
hdr "Шаг 2 из 2: Узнай свой Telegram chat_id"
cat << 'MANUAL'

  1. Открой Telegram и найди @userinfobot
  2. Отправь ему любое сообщение (например: /start)
  3. Он ответит твоим ID вида: Id: 123456789

  Это твой chat_id — только ты сможешь управлять ботом.

MANUAL

read -rp "$(echo -e "  ${C}Вставь свой chat_id: ${N}")" ADMIN_CHAT_ID

# Валидация chat_id — только цифры (может быть отрицательным для групп)
if ! echo "$ADMIN_CHAT_ID" | grep -qP '^-?\d+$'; then
  err "Неверный chat_id. Должно быть число вида 123456789"
  exit 1
fi
ok "chat_id принят: $ADMIN_CHAT_ID"

# Тест — отправим приветственное сообщение
info "Отправляю тестовое сообщение..."
TEST_RESP=$(curl -sf \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d "chat_id=${ADMIN_CHAT_ID}" \
  --data-urlencode "text=🛡 AWG Toolza Bot установлен!

Нажми кнопку ниже чтобы открыть меню управления:" \
  -d "reply_markup={\"inline_keyboard\":[[{\"text\":\"🚀 Открыть меню\",\"callback_data\":\"main\"}]]}" \
  2>/dev/null || echo "")
if echo "$TEST_RESP" | grep -q '"ok":true'; then
  ok "Тестовое сообщение отправлено — проверь Telegram!"
else
  warn "Не удалось отправить тест. Возможно chat_id неверный."
  warn "Продолжаем установку, но проверь chat_id потом."
fi

# ── Шаг 5: Сохраняем конфиг ──────────────────────────────────────────────────
echo ""
info "Сохраняю конфиг в $BOT_CONF..."

# Если конфиг уже есть — бекап
if [[ -f "$BOT_CONF" ]]; then
  cp "$BOT_CONF" "${BOT_CONF}.bak.$(date +%s)"
  warn "Старый конфиг сохранён как ${BOT_CONF}.bak.*"
fi

cat > "$BOT_CONF" << EOF
# AWG Toolza Bot — конфиг
# Создан: $(date '+%Y-%m-%d %H:%M:%S')
BOT_TOKEN="${BOT_TOKEN}"
ADMIN_CHAT_ID="${ADMIN_CHAT_ID}"
EOF

chmod 600 "$BOT_CONF"
ok "Конфиг сохранён (права 600)"

# ── Шаг 6: Записываем Python бот ─────────────────────────────────────────────
echo ""
info "Устанавливаю бот в $BOT_PY..."

cat > "$BOT_PY" << 'PYEOF'
#!/usr/bin/env python3
"""
AWG Toolza Bot — Telegram управление AmneziaWG сервером
Конфиг: /etc/awg-bot.conf
"""

import asyncio
import html as _html
import logging
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

from telegram import (
    BotCommand, InlineKeyboardButton, InlineKeyboardMarkup,
    InputFile, KeyboardButton, ReplyKeyboardMarkup,
    ReplyKeyboardRemove, Update,
)
from telegram.constants import ChatAction
from telegram.constants import ParseMode
from telegram.ext import (
    Application, CallbackQueryHandler, ContextTypes,
    ConversationHandler, MessageHandler, CommandHandler, filters,
)

# ── Конфиг ────────────────────────────────────────────────────────────────────
CONFIG_FILE  = "/etc/awg-bot.conf"
SERVER_CONF  = "/etc/amnezia/amneziawg/awg0.conf"
CLIENTS_GLOB = "/root/*_awg2.conf"
AWG_IFACE    = "awg0"
LOG_FILE     = "/var/log/awg-bot.log"

ADD_NAME, ADD_PROFILE = range(2)

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    level=logging.INFO,
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()],
)
log = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════════════
# Утилиты
# ══════════════════════════════════════════════════════════════════════════════

def load_config() -> dict:
    cfg = {}
    for line in Path(CONFIG_FILE).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def run(cmd: list, input_str: str | None = None) -> tuple:
    r = subprocess.run(cmd, capture_output=True, text=True, input=input_str, timeout=30)
    return r.returncode, r.stdout, r.stderr


def get_clients() -> list:
    import glob as _glob
    clients = []
    if not Path(SERVER_CONF).exists():
        return clients

    name_map = {}
    for fpath in _glob.glob(CLIENTS_GLOB):
        fname = Path(fpath).stem.replace("_awg2", "")
        content = Path(fpath).read_text()
        for line in content.splitlines():
            if line.startswith("PrivateKey"):
                priv = line.split("=", 1)[1].strip()
                rc, pub, _ = run(["awg", "pubkey"], input_str=priv)
                if rc == 0:
                    name_map[pub.strip()] = (fname, fpath)
                break

    content = Path(SERVER_CONF).read_text()
    for peer in re.split(r"\[Peer\]", content)[1:]:
        pk_m = re.search(r"PublicKey\s*=\s*(.+)", peer)
        ip_m = re.search(r"AllowedIPs\s*=\s*(.+)", peer)
        cm_m = re.search(r"#\s*(.+)", peer)
        if not pk_m:
            continue
        pk = pk_m.group(1).strip()
        ip = ip_m.group(1).strip() if ip_m else "?"
        comment = cm_m.group(1).strip() if cm_m else ""
        name, fpath = name_map.get(pk, (comment or pk[:8], ""))
        clients.append({"name": name, "ip": ip, "pubkey": pk, "file": fpath})
    return clients


def get_live_stats() -> dict:
    rc, out, _ = run(["awg", "show", AWG_IFACE])
    if rc != 0:
        return {}
    stats = {}
    peer = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("peer:"):
            peer = line.split(":", 1)[1].strip()
            stats[peer] = {"last_hs": 0, "rx": "—", "tx": "—"}
        elif peer:
            if "latest handshake:" in line:
                val = line.split(":", 1)[1].strip()
                secs = 0
                for n, unit in re.findall(r"(\d+)\s+(second|minute|hour|day)", val):
                    mult = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}[unit]
                    secs += int(n) * mult
                if secs:
                    stats[peer]["last_hs"] = int(time.time()) - secs
            elif "transfer:" in line:
                parts = line.split(":", 1)[1].strip().split(",")
                for p in parts:
                    p = p.strip()
                    if "received" in p:
                        stats[peer]["rx"] = " ".join(p.split()[:2])
                    elif "sent" in p:
                        stats[peer]["tx"] = " ".join(p.split()[:2])
    return stats


def online_icon(last_hs: int) -> str:
    if not last_hs:
        return "⚫"
    elapsed = int(time.time()) - last_hs
    if elapsed < 120:  return "🟢"
    if elapsed < 300:  return "🟡"
    return "🔴"


def elapsed_str(last_hs: int) -> str:
    if not last_hs:
        return "никогда"
    sec = int(time.time()) - last_hs
    if sec < 60:   return f"{sec}с назад"
    if sec < 3600: return f"{sec//60}м назад"
    return f"{sec//3600}ч назад"


def get_server_info() -> dict:
    info = {"ip": "?", "port": "?", "region": "world", "iface_up": False}
    if not Path(SERVER_CONF).exists():
        return info
    for line in Path(SERVER_CONF).read_text().splitlines():
        if line.startswith("ListenPort"):
            info["port"] = line.split("=", 1)[1].strip()
        if "Region:" in line:
            info["region"] = line.split(":", 1)[1].strip()
    rc, out, _ = run(["bash", "-c", "ip route get 1 2>/dev/null | awk '{print $7; exit}'"])
    if rc == 0 and out.strip():
        info["ip"] = out.strip()
    rc, out, _ = run(["ip", "link", "show", AWG_IFACE])
    info["iface_up"] = rc == 0 and "UP" in out
    return info


# ══════════════════════════════════════════════════════════════════════════════
# Клавиатуры
# ══════════════════════════════════════════════════════════════════════════════

def kb_main() -> ReplyKeyboardMarkup:
    """Постоянная клавиатура снизу — главное меню."""
    return ReplyKeyboardMarkup([
        ["👥 Клиенты",        "📊 Статус"],
        ["➕ Добавить клиента"],
        ["🔄 Перезапустить awg0"],
    ], resize_keyboard=True)

def kb_back() -> InlineKeyboardMarkup:
    """Inline кнопка назад — для использования в edit_message_text."""
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("◀️ Главное меню", callback_data="main")
    ]])

def kb_clients(clients: list) -> InlineKeyboardMarkup:
    rows = []
    stats = get_live_stats()
    for c in clients:
        icon = online_icon(stats.get(c["pubkey"], {}).get("last_hs", 0))
        rows.append([InlineKeyboardButton(
            f"{icon} {c['name']}  {c['ip'].split('/')[0]}",
            callback_data=f"c:{c['name']}"
        )])
    rows.append([InlineKeyboardButton("◀️ Назад", callback_data="main")])
    return InlineKeyboardMarkup(rows)

def kb_client(name: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📱 QR-код",       callback_data=f"qr:{name}"),
         InlineKeyboardButton("📄 Текст",         callback_data=f"conf:{name}")],
        [InlineKeyboardButton("📁 Файл .conf",   callback_data=f"file:{name}"),
         InlineKeyboardButton("🗑 Удалить",       callback_data=f"del:{name}")],
        [InlineKeyboardButton("◀️ К списку",     callback_data="clients")],
    ])

def kb_profile() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("⚡ QUIC (рекомендуется)", callback_data="prof:quic")],
        [InlineKeyboardButton("📞 SIP (VoIP мимикрия)",  callback_data="prof:sip")],
        [InlineKeyboardButton("🌐 DNS Query",             callback_data="prof:dns")],
        [InlineKeyboardButton("🔇 Базовый (без I1-I5)",  callback_data="prof:basic")],
        [InlineKeyboardButton("❌ Отмена",               callback_data="main")],
    ])


# ══════════════════════════════════════════════════════════════════════════════
# Авторизация
# ══════════════════════════════════════════════════════════════════════════════

def auth(func):
    async def wrapper(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        uid = str((update.effective_user or update.effective_chat).id)
        if uid != ctx.bot_data["admin_id"]:
            log.warning(f"Отклонён: uid={uid}")
            return
        return await func(update, ctx)
    return wrapper


# ══════════════════════════════════════════════════════════════════════════════
# Сборка главного меню
# ══════════════════════════════════════════════════════════════════════════════

def main_text() -> str:
    info = get_server_info()
    clients = get_clients()
    stats = get_live_stats()
    online = sum(
        1 for c in clients
        if stats.get(c["pubkey"], {}).get("last_hs", 0)
        and (time.time() - stats[c["pubkey"]]["last_hs"]) < 300
    )
    status = "🟢 активен" if info["iface_up"] else "🔴 остановлен"
    return (
        f"🛡 <b>AWG Toolza Bot</b>\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"🖥 `{info['ip']}:{info['port']}`\n"
        f"📡 {status}\n"
        f"👥 Клиентов: {len(clients)}  🟢 онлайн: {online}\n"
        f"🌍 Регион: `{info['region']}`"
    )


# ══════════════════════════════════════════════════════════════════════════════
# Handlers
# ══════════════════════════════════════════════════════════════════════════════

@auth
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "🛡 <b>AWG Toolza Bot</b>\nГлавное меню:",
        parse_mode=ParseMode.HTML,
        reply_markup=kb_main()
    )


@auth
async def on_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    d = q.data

    # Главное меню
    if d == "cancel_add":
        ctx.user_data.clear()
        await q.message.reply_text(main_text(), parse_mode=ParseMode.HTML, reply_markup=kb_main())
        await q.message.delete()
        return ConversationHandler.END

    if d == "main":
        await q.message.reply_text("🛡 <b>AWG Toolza Bot</b>\nГлавное меню:", parse_mode=ParseMode.HTML, reply_markup=kb_main())
        await q.message.delete()
        return

    # Список клиентов
    if d == "clients":
        clients = get_clients()
        if not clients:
            await q.edit_message_text("👥 Клиентов нет\n\nДобавь через ➕", reply_markup=kb_back())
            return
        stats = get_live_stats()
        lines = ["👥 <b>Клиенты:</b>\n"]
        for c in clients:
            s = stats.get(c["pubkey"], {})
            hs = s.get("last_hs", 0)
            icon = online_icon(hs)
            lines.append(f"{icon} <b>{c['name']}</b>  <code>{c['ip'].split('/')[0]}</code>  ↓{s.get('rx','—')} ↑{s.get('tx','—')}")
        await q.edit_message_text(
            "\n".join(lines), parse_mode=ParseMode.HTML,
            reply_markup=kb_clients(clients)
        )
        return

    # Карточка клиента
    if d.startswith("c:"):
        name = d[2:]
        clients = get_clients()
        c = next((x for x in clients if x["name"] == name), None)
        if not c:
            await q.edit_message_text("❌ Клиент не найден", reply_markup=kb_back())
            return
        stats = get_live_stats()
        s = stats.get(c["pubkey"], {})
        hs = s.get("last_hs", 0)
        text = (
            f"👤 <b>{name}</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🌐 IP: `{c['ip']}`\n"
            f"{online_icon(hs)} {elapsed_str(hs)}\n"
            f"↓ {s.get('rx','—')}  ↑ {s.get('tx','—')}"
        )
        await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_client(name))
        return

    # QR-код
    if d.startswith("qr:"):
        name = d[3:]
        clients = get_clients()
        c = next((x for x in clients if x["name"] == name), None)
        if not c or not c["file"]:
            await q.edit_message_text("❌ Файл не найден", reply_markup=kb_back())
            return
        await q.edit_message_text(f"⏳ Генерирую QR для <b>{name}</b>...", parse_mode=ParseMode.HTML)
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            tmp_path = tmp.name
        # Для QR убираем I2-I5 — они слишком большие, QR не вмещает
        conf_text = Path(c["file"]).read_text()
        conf_for_qr = "\n".join(
            l for l in conf_text.splitlines()
            if not re.match(r"^I[2-5]\s*=", l)
        )
        has_i2_i5 = any(re.match(r"^I[2-5]\s*=", l) for l in conf_text.splitlines())
        with tempfile.NamedTemporaryFile(mode='w', suffix=".conf", delete=False) as qtmp:
            qtmp.write(conf_for_qr)
            qtmp_path = qtmp.name
        rc, _, err = await asyncio.to_thread(
            run, ["qrencode", "-t", "PNG", "-o", tmp_path,
                  "-r", qtmp_path, "--dpi=150", "-s", "4"]
        )
        os.unlink(qtmp_path)
        if rc != 0:
            os.unlink(tmp_path)
            await q.edit_message_text(
                "❌ QR слишком большой даже без I2-I5\nИспользуй <b>Файл .conf</b> для импорта",
                parse_mode=ParseMode.HTML, reply_markup=kb_client(name)
            )
            return
        caption = f"📱 <b>{name}</b>\nИмпортируй в AmneziaVPN"
        if has_i2_i5:
            caption += "\n\n⚠️ QR без I2-I5 (слишком большой)\nДля полного конфига → Файл .conf"
        with open(tmp_path, "rb") as f:
            await q.message.reply_photo(photo=f, caption=caption, parse_mode=ParseMode.HTML)
        os.unlink(tmp_path)
        stats = get_live_stats()
        s = stats.get(c["pubkey"], {})
        hs = s.get("last_hs", 0)
        card = (
            f"👤 <b>{name}</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🌐 IP: <code>{c['ip']}</code>\n"
            f"{online_icon(hs)} {elapsed_str(hs)}\n"
            f"↓ {s.get('rx','—')}  ↑ {s.get('tx','—')}"
        )
        await q.edit_message_text(card, parse_mode=ParseMode.HTML, reply_markup=kb_client(name))
        return

    # Текст конфига
    if d.startswith("conf:"):
        name = d[5:]
        clients = get_clients()
        c = next((x for x in clients if x["name"] == name), None)
        if not c or not c["file"]:
            await q.edit_message_text("❌ Файл не найден", reply_markup=kb_back())
            return
        import html as _html
        text = Path(c["file"]).read_text()
        if len(text) > 3500:
            text = text[:3500] + "\n...(обрезано)"
        # Экранируем < > & чтобы HTML parser Telegram не падал
        text_escaped = _html.escape(text)
        await q.edit_message_text(
            f"📄 <b>{name}</b>\n<pre>{text_escaped}</pre>",
            parse_mode=ParseMode.HTML,
            reply_markup=kb_client(name)
        )
        return

    # Файл .conf
    if d.startswith("file:"):
        name = d[5:]
        clients = get_clients()
        c = next((x for x in clients if x["name"] == name), None)
        if not c or not c["file"]:
            await q.edit_message_text("❌ Файл не найден", reply_markup=kb_back())
            return
        await q.edit_message_text(f"⏳ Отправляю <b>{name}.conf</b>...", parse_mode=ParseMode.HTML)
        with open(c["file"], "rb") as f:
            await q.message.reply_document(
                document=InputFile(f, filename=f"{name}_awg2.conf"),
                caption=f"📁 <b>{name}</b>\nИмпортируй в AmneziaVPN",
                parse_mode=ParseMode.HTML,
            )
        # Редактируем обратно в карточку клиента
        stats = get_live_stats()
        s = stats.get(c["pubkey"], {})
        hs = s.get("last_hs", 0)
        card = (
            f"👤 <b>{name}</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🌐 IP: `{c['ip']}`\n"
            f"{online_icon(hs)} {elapsed_str(hs)}\n"
            f"↓ {s.get('rx','—')}  ↑ {s.get('tx','—')}"
        )
        await q.edit_message_text(card, parse_mode=ParseMode.HTML, reply_markup=kb_client(name))
        return

    # Подтверждение удаления
    if d.startswith("del:"):
        name = d[4:]
        await q.edit_message_text(
            f"⚠️ Удалить <b>{name}</b>?\nОтменить нельзя.",
            parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("✅ Да", callback_data=f"delok:{name}"),
                 InlineKeyboardButton("❌ Нет", callback_data=f"c:{name}")],
            ])
        )
        return

    # Удаление
    if d.startswith("delok:"):
        name = d[6:]
        clients = get_clients()
        c = next((x for x in clients if x["name"] == name), None)
        if not c:
            await q.edit_message_text("❌ Клиент не найден", reply_markup=kb_back())
            return
        await asyncio.to_thread(run, ["awg", "set", AWG_IFACE, "peer", c["pubkey"], "remove"])
        # Удаляем блок [Peer] из серверного конфига
        conf_text = Path(SERVER_CONF).read_text()
        blocks = re.split(r"(?=\[Peer\])", conf_text)
        filtered = "".join(b for b in blocks if c["pubkey"] not in b)
        tmp = Path(SERVER_CONF + ".tmp")
        tmp.write_text(filtered)
        tmp.rename(SERVER_CONF)
        if c["file"] and Path(c["file"]).exists():
            Path(c["file"]).unlink()
        log.info(f"Удалён: {name}")
        await q.edit_message_text(f"✅ <b>{name}</b> удалён", parse_mode=ParseMode.HTML, reply_markup=kb_back())
        return

    # Статус из inline кнопки "Обновить"
    if d == "status_msg":
        info = get_server_info()
        clients = get_clients()
        stats = get_live_stats()
        online = sum(
            1 for c in clients
            if stats.get(c["pubkey"], {}).get("last_hs", 0)
            and (time.time() - stats[c["pubkey"]]["last_hs"]) < 300
        )
        rc, out, _ = await asyncio.to_thread(run, ["awg", "show", AWG_IFACE, "transfer"])
        rx = tx = 0
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 3:
                try: rx += int(p[1]); tx += int(p[2])
                except: pass
        def hb2(b):
            if b < 1024: return f"{b}B"
            if b < 1024**2: return f"{b/1024:.1f}KB"
            if b < 1024**3: return f"{b/1024**2:.1f}MB"
            return f"{b/1024**3:.1f}GB"
        text_s = (
            f"📊 <b>Статус</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🖥 <code>{info['ip']}:{info['port']}</code>\n"
            f"📡 {'🟢 активен' if info['iface_up'] else '🔴 остановлен'}\n"
            f"👥 {len(clients)} клиентов  🟢 {online} онлайн\n"
            f"↓ {hb2(rx)}  ↑ {hb2(tx)}"
        )
        await q.edit_message_text(
            text_s, parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("🔄 Обновить", callback_data="status_msg")]
            ])
        )
        return

    # Статус из on_callback (legacy)
    if d == "status":
        info = get_server_info()
        clients = get_clients()
        stats = get_live_stats()
        online = sum(
            1 for c in clients
            if stats.get(c["pubkey"], {}).get("last_hs", 0)
            and (time.time() - stats[c["pubkey"]]["last_hs"]) < 300
        )
        rc, out, _ = await asyncio.to_thread(run, ["awg", "show", AWG_IFACE, "transfer"])
        rx = tx = 0
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 3:
                try: rx += int(p[1]); tx += int(p[2])
                except: pass
        def hb(b):
            if b < 1024: return f"{b}B"
            if b < 1024**2: return f"{b/1024:.1f}KB"
            if b < 1024**3: return f"{b/1024**2:.1f}MB"
            return f"{b/1024**3:.1f}GB"
        text = (
            f"📊 <b>Статус</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🖥 `{info['ip']}:{info['port']}`\n"
            f"📡 {'🟢 активен' if info['iface_up'] else '🔴 остановлен'}\n"
            f"👥 {len(clients)} клиентов  🟢 {online} онлайн\n"
            f"↓ {hb(rx)}  ↑ {hb(tx)}"
        )
        await q.edit_message_text(
            text, parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("🔄 Обновить", callback_data="status")],
                [InlineKeyboardButton("◀️ Назад",    callback_data="main")],
            ])
        )
        return

    # Перезапуск
    if d == "restart":
        await q.edit_message_text("⏳ Перезапускаю awg0...")
        await asyncio.to_thread(run, ["awg-quick", "down", SERVER_CONF])
        await asyncio.sleep(1)
        rc, _, err = await asyncio.to_thread(run, ["awg-quick", "up", SERVER_CONF])
        if rc == 0:
            await q.edit_message_text("✅ awg0 перезапущен", reply_markup=kb_back())
        else:
            await q.edit_message_text(
                f"❌ Ошибка:\n`{err[:300]}`",
                parse_mode=ParseMode.HTML, reply_markup=kb_back()
            )
        return


@auth
async def on_add_name(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    name = update.message.text.strip()
    if not re.match(r"^[a-zA-Z0-9_]{1,32}$", name):
        await update.message.reply_text(
            "❌ Только латиница, цифры, _ (макс 32 символа). Введи снова:"
        )
        return ADD_NAME
    clients = get_clients()
    if any(c["name"] == name for c in clients):
        await update.message.reply_text(f"❌ <b>{name}</b> уже есть. Введи другое:", parse_mode=ParseMode.HTML)
        return ADD_NAME
    ctx.user_data["new_name"] = name
    await update.message.reply_text(
        f"👤 Имя: <b>{name}</b>\n\nВыбери профиль мимикрии:",
        parse_mode=ParseMode.HTML, reply_markup=kb_profile()
    )
    return ADD_PROFILE


# ══════════════════════════════════════════════════════════════════════════════
# Добавление клиента
# ══════════════════════════════════════════════════════════════════════════════

_CPS_CODE = r"""
import sys, secrets, struct, random
def rh(n): return secrets.token_bytes(n)
def ri(a,b): return random.randint(a,b)
def rc(lst): return random.choice(lst)
def u16(v): return struct.pack(">H",v&0xFFFF)
def cps(r): return "<b 0x%s>" % r.hex()
P=sys.argv[1] if len(sys.argv)>1 else "quic"
def quic_i():
    fb=rc([0xC0,0xC0,0xC0,0xC3]); pn=(fb&3)+1
    enc=1200-26-pn; pv=u16(0x4000|pn+enc)
    return bytes([fb])+b"\x00\x00\x00\x01"+bytes([8])+rh(8)+bytes([8])+rh(8)+b"\x00"+pv+rh(pn)+rh(enc)
def quic_s():
    pn=ri(1,2); fb=0x40|(ri(0,1)<<5)|(ri(0,1)<<2)|(pn-1)
    return bytes([fb])+rh(8)+rh(pn)+rh(ri(40,90))
def sip():
    h=rc(["sipgate.de","sip.ovh.net","sip.beeline.ru","sip.mts.ru"])
    u=rc(["alice","bob","100","200"])+str(ri(10,99))
    ip="10.%d.%d.%d"%(ri(0,255),ri(0,255),ri(10,200))
    br="z9hG4bK"+secrets.token_hex(7); tag=secrets.token_hex(4)
    cid="%s@%s"%(secrets.token_hex(8),h)
    return("\r\n".join(["REGISTER sip:%s SIP/2.0"%h,
        "Via: SIP/2.0/UDP %s:5060;branch=%s;rport"%(ip,br),
        "Max-Forwards: 70","From: <sip:%s@%s>;tag=%s"%(u,h,tag),
        "To: <sip:%s@%s>"%(u,h),"Call-ID: %s"%cid,
        "CSeq: %d REGISTER"%ri(1,50),
        "Contact: <sip:%s@%s:5060>"%(u,ip),
        "Expires: %d"%rc([300,600,3600]),"Content-Length: 0","",""])).encode()
def dns(d="google.com"):
    qn=b"".join(bytes([len(l)])+l.encode() for l in d.split("."))+b"\x00"
    return b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"+qn+b"\x00\x01\x00\x01"
pool=["google.com","github.com","yandex.ru","vk.com","cloudflare.com"]
random.shuffle(pool)
if P=="sip": print(cps(sip())); [print("") for _ in range(4)]
elif P=="dns": [print("<r 2><b 0x%s>"%dns(pool[i%len(pool)]).hex()) for i in range(5)]
else: print(cps(quic_i())); [print(cps(quic_s())) for _ in range(4)]
"""


def add_client(name: str, profile: str) -> tuple:
    import glob as _glob

    if not Path(SERVER_CONF).exists():
        return False, "Серверный конфиг не найден"

    content = Path(SERVER_CONF).read_text()
    sp = {}
    listen_port = ""
    for line in content.splitlines():
        if "=" in line and not line.startswith("[") and not line.startswith("#"):
            k, v = line.split("=", 1)
            sp[k.strip().lower()] = v.strip()

    # Генерация ключей
    rc, priv, _ = run(["awg", "genkey"])
    if rc != 0: return False, "Ошибка genkey"
    priv = priv.strip()
    rc, pub, _ = run(["awg", "pubkey"], input_str=priv)
    if rc != 0: return False, "Ошибка pubkey"
    pub = pub.strip()
    rc, psk, _ = run(["awg", "genpsk"])
    if rc != 0: return False, "Ошибка genpsk"
    psk = psk.strip()

    # IP для клиента
    used = {1}
    for line in content.splitlines():
        m = re.search(r"AllowedIPs\s*=\s*[\d.]+\.(\d+)/", line)
        if m: used.add(int(m.group(1)))
    addr = sp.get("address", "10.0.0.1/24")
    base = ".".join(addr.split(".")[:3]) + "."
    octet = next(i for i in range(2, 255) if i not in used)
    client_ip = f"{base}{octet}/32"

    # Endpoint определён выше вместе с server_pubkey

    # Публичный ключ сервера — генерируем из серверного PrivateKey
    server_pubkey = ""
    endpoint = ""
    for line in content.splitlines():
        if line.startswith("PrivateKey"):
            priv_srv = line.split("=", 1)[1].strip()
            rc_pk, pub_srv, _ = run(["awg", "pubkey"], input_str=priv_srv)
            if rc_pk == 0:
                server_pubkey = pub_srv.strip()
        if line.startswith("ListenPort"):
            listen_port = line.split("=", 1)[1].strip()

    # Endpoint — из IP сервера + ListenPort
    rc_ip, srv_ip, _ = run(["bash", "-c", "ip route get 1 2>/dev/null | awk '{print $7; exit}'"])
    if rc_ip == 0 and srv_ip.strip():
        endpoint = f"{srv_ip.strip()}:{listen_port}" if listen_port else ""
    
    # Fallback — из существующих клиентских конфигов
    if not server_pubkey or not endpoint:
        for fpath in _glob.glob(CLIENTS_GLOB):
            for line in Path(fpath).read_text().splitlines():
                if line.startswith("PublicKey") and not server_pubkey:
                    server_pubkey = line.split("=", 1)[1].strip()
                if line.startswith("Endpoint") and not endpoint:
                    endpoint = line.split("=", 1)[1].strip()
            if server_pubkey and endpoint: break

    # CPS
    i_params = ""
    if profile != "basic":
        rc2, cps_out, _ = run(["python3", "-c", _CPS_CODE, profile])
        if rc2 == 0 and cps_out.strip():
            labels = ["I1", "I2", "I3", "I4", "I5"]
            for i, line in enumerate(cps_out.strip().splitlines()[:5]):
                if line.strip():
                    i_params += f"\n{labels[i]} = {line.strip()}"

    def g(k, default=""):
        return sp.get(k, default)

    client_conf = (
        f"[Interface]\n"
        f"PrivateKey = {priv}\n"
        f"Address = {client_ip}\n"
        f"DNS = 1.1.1.1, 1.0.0.1\n"
        f"MTU = {g('mtu','1380')}\n"
        f"Jc = {g('jc')}\n"
        f"Jmin = {g('jmin')}\n"
        f"Jmax = {g('jmax')}\n"
        f"S1 = {g('s1')}\nS2 = {g('s2')}\n"
        f"S3 = {g('s3')}\nS4 = {g('s4')}\n"
        f"H1 = {g('h1')}\nH2 = {g('h2')}\n"
        f"H3 = {g('h3')}\nH4 = {g('h4')}"
        f"{i_params}\n"
        f"[Peer]\n"
        f"PublicKey = {server_pubkey}\n"
        f"PresharedKey = {psk}\n"
        f"Endpoint = {endpoint}\n"
        f"AllowedIPs = 0.0.0.0/0, ::/0\n"
        f"PersistentKeepalive = 25\n"
    )

    Path(f"/root/{name}_awg2.conf").write_text(client_conf)

    peer_block = (
        f"\n[Peer]\n# {name}\n"
        f"PublicKey = {pub}\n"
        f"PresharedKey = {psk}\n"
        f"AllowedIPs = {client_ip}\n"
    )
    with open(SERVER_CONF, "a") as f:
        f.write(peer_block)

    run(["awg", "set", AWG_IFACE, "peer", pub,
         "preshared-key", "/dev/stdin", "allowed-ips", client_ip],
        input_str=psk)

    log.info(f"Добавлен: {name} ({client_ip}) профиль={profile}")
    return True, f"IP: `{client_ip}`\nПрофиль: {profile}"


# ══════════════════════════════════════════════════════════════════════════════
# main
# ══════════════════════════════════════════════════════════════════════════════


# ══════════════════════════════════════════════════════════════════════════════
# ConversationHandler — отдельные функции (не смешивать с on_callback!)
# ══════════════════════════════════════════════════════════════════════════════

@auth
async def on_add_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Entry point — нажатие кнопки Добавить клиента (Inline или Reply KB)."""
    ctx.user_data.clear()
    text_msg = "➕ <b>Новый клиент</b>\n\nВведи имя (латиница, цифры, _):"
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("❌ Отмена", callback_data="cancel_add")]])

    if update.callback_query:
        q = update.callback_query
        await q.answer()
        await q.edit_message_text(text_msg, parse_mode=ParseMode.HTML, reply_markup=kb)
    else:
        await update.message.reply_text(text_msg, parse_mode=ParseMode.HTML, reply_markup=kb)
    return ADD_NAME


@auth
async def on_add_profile(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Выбор профиля мимикрии."""
    q = update.callback_query
    await q.answer()
    profile = q.data[5:]  # убираем "prof:"
    name = ctx.user_data.get("new_name", "")
    if not name:
        await q.edit_message_text("❌ Имя не задано", reply_markup=kb_back())
        return ConversationHandler.END
    await q.edit_message_text(
        f"⏳ Создаю <b>{name}</b> (профиль: {profile})...",
        parse_mode=ParseMode.HTML
    )
    ok_flag, msg = await asyncio.to_thread(add_client, name, profile)
    if ok_flag:
        await q.edit_message_text(
            f"✅ <b>{name}</b> создан!\n{msg}\n\nВыбери в списке клиентов для получения QR/файла.",
            parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("👥 К клиентам", callback_data="clients")],
                [InlineKeyboardButton("◀️ Главное меню", callback_data="main")],
            ])
        )
    else:
        await q.edit_message_text(
            f"❌ Ошибка:\n`{msg}`",
            parse_mode=ParseMode.HTML,
            reply_markup=kb_back()
        )
    return ConversationHandler.END


async def on_conv_cancel(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Отмена — возврат в главное меню."""
    q = update.callback_query
    await q.answer()
    ctx.user_data.clear()
    await q.message.reply_text(main_text(), parse_mode=ParseMode.HTML, reply_markup=kb_main())
    await q.message.delete()
    return ConversationHandler.END


@auth
async def handle_any_message(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Обработка кнопок Reply Keyboard и любых других сообщений."""
    text = (update.message.text or "").strip()

    if text == "👥 Клиенты":
        clients = get_clients()
        if not clients:
            await update.message.reply_text(
                "👥 Клиентов нет\n\nДобавь через ➕ Добавить клиента",
                reply_markup=kb_main()
            )
            return
        stats = get_live_stats()
        lines = ["👥 <b>Клиенты:</b>\n"]
        for c in clients:
            s = stats.get(c["pubkey"], {})
            hs = s.get("last_hs", 0)
            icon = online_icon(hs)
            lines.append(f"{icon} <b>{c['name']}</b>  <code>{c['ip'].split('/')[0]}</code>  ↓{s.get('rx','—')} ↑{s.get('tx','—')}")
        await update.message.reply_text(
            "\n".join(lines),
            parse_mode=ParseMode.HTML,
            reply_markup=kb_clients(clients)
        )

    elif text == "📊 Статус":
        info = get_server_info()
        clients = get_clients()
        stats = get_live_stats()
        online = sum(
            1 for c in clients
            if stats.get(c["pubkey"], {}).get("last_hs", 0)
            and (time.time() - stats[c["pubkey"]]["last_hs"]) < 300
        )
        rc, out, _ = await asyncio.to_thread(run, ["awg", "show", AWG_IFACE, "transfer"])
        rx = tx = 0
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 3:
                try: rx += int(p[1]); tx += int(p[2])
                except: pass
        def hb(b):
            if b < 1024: return f"{b}B"
            if b < 1024**2: return f"{b/1024:.1f}KB"
            if b < 1024**3: return f"{b/1024**2:.1f}MB"
            return f"{b/1024**3:.1f}GB"
        text_out = (
            f"📊 <b>Статус</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🖥 <code>{info['ip']}:{info['port']}</code>\n"
            f"📡 {'🟢 активен' if info['iface_up'] else '🔴 остановлен'}\n"
            f"👥 {len(clients)} клиентов  🟢 {online} онлайн\n"
            f"↓ {hb(rx)}  ↑ {hb(tx)}"
        )
        await update.message.reply_text(
            text_out, parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("🔄 Обновить", callback_data="status_msg")]
            ])
        )

    elif text == "🔄 Перезапустить awg0":
        msg = await update.message.reply_text("⏳ Перезапускаю awg0...")
        await asyncio.to_thread(run, ["awg-quick", "down", SERVER_CONF])
        await asyncio.sleep(1)
        rc, _, err = await asyncio.to_thread(run, ["awg-quick", "up", SERVER_CONF])
        result = "✅ awg0 перезапущен" if rc == 0 else f"❌ Ошибка:\n<code>{_html.escape(err[:200])}</code>"
        await msg.edit_text(result, parse_mode=ParseMode.HTML)

    # else: игнорируем неизвестные сообщения — не спамим меню


def main():
    cfg = load_config()
    token = cfg.get("BOT_TOKEN", "")
    admin_id = cfg.get("ADMIN_CHAT_ID", "")
    if not token or not admin_id:
        raise SystemExit("❌ BOT_TOKEN и ADMIN_CHAT_ID не найдены в /etc/awg-bot.conf")
    log.info(f"Запуск AWG Bot, admin={admin_id}")
    app = Application.builder().token(token).build()
    app.bot_data["admin_id"] = admin_id

    # ConversationHandler — строго для добавления клиента
    # Важно: group=-1 чтобы обрабатывался РАНЬШЕ основного on_callback
    conv = ConversationHandler(
        entry_points=[
            CallbackQueryHandler(on_add_start, pattern="^add_start$"),
            MessageHandler(filters.Regex("^➕ Добавить клиента$"), on_add_start),
        ],
        states={
            ADD_NAME:    [MessageHandler(filters.TEXT & ~filters.COMMAND, on_add_name)],
            ADD_PROFILE: [CallbackQueryHandler(on_add_profile, pattern="^prof:")],
        },
        fallbacks=[
            CallbackQueryHandler(on_conv_cancel, pattern="^main$"),
        ],
        per_message=False,
        per_chat=True,
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(conv, group=-1)
    app.add_handler(CallbackQueryHandler(on_callback), group=0)
    app.add_handler(MessageHandler(
        filters.TEXT & ~filters.COMMAND, handle_any_message
    ), group=1)

    async def post_init(application):
        # Устанавливаем кнопку Menu и команды
        await application.bot.set_my_commands([
            BotCommand("start", "Главное меню"),
        ])
        from telegram import MenuButtonCommands
        await application.bot.set_chat_menu_button(
            menu_button=MenuButtonCommands()
        )
        log.info("MenuButton и команды установлены")

    app.post_init = post_init
    log.info("Polling...")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
PYEOF

chmod +x "$BOT_PY"
ok "Бот установлен в $BOT_PY"

# ── Шаг 7: Systemd unit ──────────────────────────────────────────────────────
echo ""
info "Создаю systemd unit..."

cat > "$BOT_SERVICE" << EOF
[Unit]
Description=AWG Toolza Telegram Bot
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $BOT_PY
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable awg-bot
systemctl restart awg-bot
sleep 2

if systemctl is-active --quiet awg-bot; then
  ok "Сервис awg-bot запущен и включён в автозапуск"
else
  warn "Сервис не запустился. Проверь: journalctl -u awg-bot -n 30"
fi

# ── Итог ─────────────────────────────────────────────────────────────────────
echo ""
hdr "√ Установка завершена"
cat << INFO

  Бот: @${BOT_USERNAME}
  Конфиг: $BOT_CONF
  Лог: $BOT_LOG

  Управление:
    systemctl status awg-bot      — статус
    systemctl restart awg-bot     — перезапуск
    journalctl -u awg-bot -f      — логи в реальном времени

  Проверь Telegram — бот должен был прислать сообщение.
  Если нет — убедись что ты написал боту /start хотя бы раз.

INFO

echo -e "  ${C}Открой бота: https://t.me/${BOT_USERNAME}${N}"
echo ""
